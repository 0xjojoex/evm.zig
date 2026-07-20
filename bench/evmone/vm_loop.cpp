#include <evmc/evmc.h>
#include <evmone/advanced_analysis.hpp>
#include <evmone/advanced_execution.hpp>
#include <evmone/baseline.hpp>
#include <evmone/vm.hpp>

#include <algorithm>
#include <array>
#include <chrono>
#include <cctype>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <iostream>
#include <limits>
#include <map>
#include <optional>
#include <sstream>
#include <stdexcept>
#include <string>
#include <string_view>
#include <vector>

extern "C" evmc_vm* evmc_create_evmone() noexcept;

namespace
{
constexpr auto max_gas = std::numeric_limits<int64_t>::max();
constexpr size_t default_warmup_ms = 100;

enum class Mode
{
    baseline,
    advanced,
};

enum class HostProfile
{
    null,
    mock,
};

struct Options
{
    std::optional<std::string> fixture_dir;
    std::optional<std::string> contract_code_path;
    std::optional<std::string> call_data_hex;
    std::optional<size_t> num_runs;
    size_t warmup_ms = default_warmup_ms;
    evmc_revision spec = EVMC_OSAKA;
    HostProfile host_profile = HostProfile::null;
    Mode mode = Mode::advanced;
    bool summary = false;
};

struct ResolvedOptions
{
    std::optional<std::string> fixture_dir;
    std::string contract_code_path;
    std::string call_data_hex;
    size_t num_runs = 1;
    size_t warmup_ms = default_warmup_ms;
    evmc_revision spec = EVMC_OSAKA;
    HostProfile host_profile = HostProfile::null;
    Mode mode = Mode::advanced;
    bool summary = false;
};

struct HostCounters
{
    size_t total = 0;
    size_t logs = 0;
};

using StorageKey = std::array<uint8_t, 52>;

struct StorageSlot
{
    evmc_bytes32 value{};
    bool warm = false;
};

struct BenchHost
{
    std::map<StorageKey, StorageSlot> storage;
    HostCounters counters;

    void record_host_call() noexcept { ++counters.total; }

    void record_log() noexcept
    {
        ++counters.total;
        ++counters.logs;
    }
};

struct VmHandle
{
    evmc_vm* ptr = nullptr;

    explicit VmHandle(Mode mode) : ptr(evmc_create_evmone())
    {
        if (ptr == nullptr)
            throw std::runtime_error("failed to create evmone VM");
        if (mode == Mode::advanced)
        {
            const auto result = ptr->set_option(ptr, "advanced", "");
            if (result != EVMC_SET_OPTION_SUCCESS)
                throw std::runtime_error("failed to enable evmone advanced mode");
        }
    }

    VmHandle(const VmHandle&) = delete;
    VmHandle& operator=(const VmHandle&) = delete;

    ~VmHandle()
    {
        if (ptr != nullptr)
            ptr->destroy(ptr);
    }
};

struct ExecutionOutput
{
    std::vector<uint8_t> output;
    uint64_t elapsed_ns = 0;
    HostCounters counters;
};

bool is_zero(const evmc_bytes32& value) noexcept
{
    return std::all_of(std::begin(value.bytes), std::end(value.bytes), [](uint8_t byte) {
        return byte == 0;
    });
}

StorageKey make_storage_key(const evmc_address& address, const evmc_bytes32& key)
{
    StorageKey result{};
    std::copy(std::begin(address.bytes), std::end(address.bytes), result.begin());
    std::copy(std::begin(key.bytes), std::end(key.bytes), result.begin() + 20);
    return result;
}

BenchHost& host_from_context(evmc_host_context* context)
{
    return *reinterpret_cast<BenchHost*>(context);
}

evmc_host_context* host_context(BenchHost& host)
{
    return reinterpret_cast<evmc_host_context*>(&host);
}

evmc_bytes32 zero_bytes32() noexcept
{
    return evmc_bytes32{};
}

evmc_uint256be uint256_one() noexcept
{
    evmc_uint256be value{};
    value.bytes[31] = 1;
    return value;
}

evmc_address caller_address() noexcept
{
    evmc_address address{};
    address.bytes[0] = 0x10;
    address.bytes[19] = 0x01;
    return address;
}

evmc_address contract_address() noexcept
{
    evmc_address address{};
    address.bytes[0] = 0x20;
    address.bytes[19] = 0x02;
    return address;
}

bool account_exists(evmc_host_context* context, const evmc_address*) noexcept
{
    host_from_context(context).record_host_call();
    return false;
}

evmc_bytes32 get_storage(evmc_host_context* context, const evmc_address* address, const evmc_bytes32* key) noexcept
{
    auto& host = host_from_context(context);
    host.record_host_call();
    const auto storage_key = make_storage_key(*address, *key);
    const auto it = host.storage.find(storage_key);
    return it == host.storage.end() ? zero_bytes32() : it->second.value;
}

evmc_storage_status set_storage(
    evmc_host_context* context,
    const evmc_address* address,
    const evmc_bytes32* key,
    const evmc_bytes32* value) noexcept
{
    auto& host = host_from_context(context);
    host.record_host_call();
    const auto storage_key = make_storage_key(*address, *key);
    auto& slot = host.storage[storage_key];
    const auto previous = slot.value;
    slot.value = *value;

    if (is_zero(previous) && !is_zero(*value))
        return EVMC_STORAGE_ADDED;
    if (!is_zero(previous) && is_zero(*value))
        return EVMC_STORAGE_DELETED;
    if (std::memcmp(previous.bytes, value->bytes, sizeof(previous.bytes)) == 0)
        return EVMC_STORAGE_ASSIGNED;
    return EVMC_STORAGE_MODIFIED;
}

evmc_bytes32 get_balance(evmc_host_context* context, const evmc_address*) noexcept
{
    host_from_context(context).record_host_call();
    return zero_bytes32();
}

uint64_t get_nonce(evmc_host_context* context, const evmc_address*) noexcept
{
    host_from_context(context).record_host_call();
    return 0;
}

size_t get_code_size(evmc_host_context* context, const evmc_address*) noexcept
{
    host_from_context(context).record_host_call();
    return 0;
}

evmc_bytes32 get_code_hash(evmc_host_context* context, const evmc_address*) noexcept
{
    host_from_context(context).record_host_call();
    return zero_bytes32();
}

size_t copy_code(evmc_host_context* context, const evmc_address*, size_t, uint8_t*, size_t) noexcept
{
    host_from_context(context).record_host_call();
    return 0;
}

bool selfdestruct(evmc_host_context* context, const evmc_address*, const evmc_address*) noexcept
{
    host_from_context(context).record_host_call();
    return false;
}

evmc_result call(evmc_host_context* context, const evmc_message* message) noexcept
{
    host_from_context(context).record_host_call();
    evmc_result result{};
    result.status_code = EVMC_SUCCESS;
    result.gas_left = message->gas;
    return result;
}

evmc_tx_context get_tx_context(evmc_host_context* context) noexcept
{
    host_from_context(context).record_host_call();
    evmc_tx_context tx{};
    tx.tx_origin = caller_address();
    tx.block_gas_limit = max_gas;
    tx.chain_id = uint256_one();
    return tx;
}

evmc_bytes32 get_block_hash(evmc_host_context* context, int64_t) noexcept
{
    host_from_context(context).record_host_call();
    return zero_bytes32();
}

void emit_log(evmc_host_context* context, const evmc_address*, const uint8_t*, size_t, const evmc_bytes32[], size_t) noexcept
{
    host_from_context(context).record_log();
}

evmc_access_status access_account(evmc_host_context* context, const evmc_address*) noexcept
{
    host_from_context(context).record_host_call();
    return EVMC_ACCESS_COLD;
}

evmc_access_status access_storage(evmc_host_context* context, const evmc_address* address, const evmc_bytes32* key) noexcept
{
    auto& host = host_from_context(context);
    host.record_host_call();
    auto& slot = host.storage[make_storage_key(*address, *key)];
    const auto was_warm = slot.warm;
    slot.warm = true;
    return was_warm ? EVMC_ACCESS_WARM : EVMC_ACCESS_COLD;
}

evmc_bytes32 get_transient_storage(evmc_host_context* context, const evmc_address*, const evmc_bytes32*) noexcept
{
    host_from_context(context).record_host_call();
    return zero_bytes32();
}

void set_transient_storage(evmc_host_context* context, const evmc_address*, const evmc_bytes32*, const evmc_bytes32*) noexcept
{
    host_from_context(context).record_host_call();
}

const evmc_host_interface& host_interface() noexcept
{
    static const evmc_host_interface interface = {
        .account_exists = account_exists,
        .get_storage = get_storage,
        .set_storage = set_storage,
        .get_balance = get_balance,
        .get_nonce = get_nonce,
        .get_code_size = get_code_size,
        .get_code_hash = get_code_hash,
        .copy_code = copy_code,
        .selfdestruct = selfdestruct,
        .call = call,
        .get_tx_context = get_tx_context,
        .get_block_hash = get_block_hash,
        .emit_log = emit_log,
        .access_account = access_account,
        .access_storage = access_storage,
        .get_transient_storage = get_transient_storage,
        .set_transient_storage = set_transient_storage,
    };
    return interface;
}

void release_result(evmc_result& result) noexcept
{
    if (result.release != nullptr)
        result.release(&result);
}

ExecutionOutput execute(
    evmc_vm* vm,
    evmc_call_kind kind,
    const std::vector<uint8_t>& code,
    const std::vector<uint8_t>& input,
    evmc_revision spec,
    bool timed)
{
    BenchHost host;
    evmc_message message{};
    message.kind = kind;
    message.gas = max_gas;
    message.recipient = contract_address();
    message.sender = caller_address();
    message.code_address = contract_address();
    message.input_data = input.empty() ? nullptr : input.data();
    message.input_size = input.size();

    const auto* code_ptr = code.empty() ? nullptr : code.data();
    const auto start = std::chrono::steady_clock::now();
    auto result = vm->execute(
        vm,
        &host_interface(),
        host_context(host),
        spec,
        &message,
        code_ptr,
        code.size());
    const auto end = std::chrono::steady_clock::now();

    if (result.status_code != EVMC_SUCCESS)
    {
        const auto status = result.status_code;
        release_result(result);
        throw std::runtime_error("evmone execution failed with status " + std::to_string(status));
    }

    std::vector<uint8_t> output;
    if (result.output_size != 0)
        output.assign(result.output_data, result.output_data + result.output_size);
    release_result(result);

    const auto elapsed = std::chrono::duration_cast<std::chrono::nanoseconds>(end - start).count();
    return ExecutionOutput{
        std::move(output),
        timed ? static_cast<uint64_t>(elapsed) : 0,
        host.counters,
    };
}

ExecutionOutput execute_analyzed(
    const evmone::advanced::AdvancedCodeAnalysis& analysis,
    const std::vector<uint8_t>& code,
    const std::vector<uint8_t>& input,
    evmc_revision spec)
{
    BenchHost host;
    evmc_message message{};
    message.kind = EVMC_CALL;
    message.gas = max_gas;
    message.recipient = contract_address();
    message.sender = caller_address();
    message.code_address = contract_address();
    message.input_data = input.empty() ? nullptr : input.data();
    message.input_size = input.size();

    const evmone::bytes_view code_view{code.data(), code.size()};
    evmone::advanced::AdvancedExecutionState state{
        message,
        spec,
        host_interface(),
        host_context(host),
        code_view,
    };

    const auto start = std::chrono::steady_clock::now();
    auto result = evmone::advanced::execute(state, analysis);
    const auto end = std::chrono::steady_clock::now();

    if (result.status_code != EVMC_SUCCESS)
    {
        const auto status = result.status_code;
        release_result(result);
        throw std::runtime_error("evmone analyzed execution failed with status " + std::to_string(status));
    }

    release_result(result);

    const auto elapsed = std::chrono::duration_cast<std::chrono::nanoseconds>(end - start).count();
    return ExecutionOutput{
        {},
        static_cast<uint64_t>(elapsed),
        host.counters,
    };
}

ExecutionOutput execute_baseline_analyzed(
    evmone::VM& vm,
    const evmone::baseline::CodeAnalysis& analysis,
    const std::vector<uint8_t>& input,
    evmc_revision spec)
{
    BenchHost host;
    evmc_message message{};
    message.kind = EVMC_CALL;
    message.gas = max_gas;
    message.recipient = contract_address();
    message.sender = caller_address();
    message.code_address = contract_address();
    message.input_data = input.empty() ? nullptr : input.data();
    message.input_size = input.size();

    const auto start = std::chrono::steady_clock::now();
    auto result = evmone::baseline::execute(
        vm,
        host_interface(),
        host_context(host),
        spec,
        message,
        analysis);
    const auto end = std::chrono::steady_clock::now();

    if (result.status_code != EVMC_SUCCESS)
    {
        const auto status = result.status_code;
        release_result(result);
        throw std::runtime_error("evmone baseline analyzed execution failed with status " + std::to_string(status));
    }

    release_result(result);

    const auto elapsed = std::chrono::duration_cast<std::chrono::nanoseconds>(end - start).count();
    return ExecutionOutput{
        {},
        static_cast<uint64_t>(elapsed),
        host.counters,
    };
}

std::string read_file(const std::string& path)
{
    std::ifstream file(path);
    if (!file)
        throw std::runtime_error("failed to read '" + path + "'");
    std::ostringstream buffer;
    buffer << file.rdbuf();
    return buffer.str();
}

std::optional<std::string> read_optional_file(const std::string& path)
{
    std::ifstream file(path);
    if (!file)
        return std::nullopt;
    std::ostringstream buffer;
    buffer << file.rdbuf();
    return buffer.str();
}

std::string trim(std::string value)
{
    const auto first = std::find_if_not(value.begin(), value.end(), [](unsigned char ch) {
        return std::isspace(ch);
    });
    const auto last = std::find_if_not(value.rbegin(), value.rend(), [](unsigned char ch) {
        return std::isspace(ch);
    }).base();
    if (first >= last)
        return "";
    return std::string(first, last);
}

int hex_value(char ch)
{
    if (ch >= '0' && ch <= '9')
        return ch - '0';
    if (ch >= 'a' && ch <= 'f')
        return ch - 'a' + 10;
    if (ch >= 'A' && ch <= 'F')
        return ch - 'A' + 10;
    throw std::runtime_error("invalid hex digit");
}

std::vector<uint8_t> decode_hex(std::string source)
{
    std::string hex;
    hex.reserve(source.size());
    for (const auto ch : source)
    {
        if (!std::isspace(static_cast<unsigned char>(ch)))
            hex.push_back(ch);
    }
    if (hex.starts_with("0x") || hex.starts_with("0X"))
        hex = hex.substr(2);
    if (hex.size() % 2 != 0)
        throw std::runtime_error("invalid hex length");

    std::vector<uint8_t> bytes(hex.size() / 2);
    for (size_t i = 0; i < bytes.size(); ++i)
        bytes[i] = static_cast<uint8_t>((hex_value(hex[i * 2]) << 4) | hex_value(hex[i * 2 + 1]));
    return bytes;
}

std::string fixture_path(const std::string& fixture_dir, const std::string& name)
{
    if (fixture_dir.ends_with('/'))
        return fixture_dir + name;
    return fixture_dir + "/" + name;
}

size_t parse_nonzero_usize(const std::string& value)
{
    size_t parsed_index = 0;
    const auto parsed = std::stoull(value, &parsed_index, 10);
    if (parsed_index != value.size() || parsed == 0)
        throw std::runtime_error("invalid non-zero integer '" + value + "'");
    return static_cast<size_t>(parsed);
}

size_t parse_usize(const std::string& value)
{
    if (value.empty() || !std::all_of(value.begin(), value.end(), [](unsigned char ch) { return std::isdigit(ch); }))
        throw std::runtime_error("invalid non-negative integer '" + value + "'");
    size_t parsed_index = 0;
    const auto parsed = std::stoull(value, &parsed_index, 10);
    if (parsed_index != value.size() || parsed > std::numeric_limits<size_t>::max())
        throw std::runtime_error("invalid non-negative integer '" + value + "'");
    return static_cast<size_t>(parsed);
}

std::optional<evmc_revision> parse_spec(std::string_view value) noexcept
{
    if (value == "frontier")
        return EVMC_FRONTIER;
    if (value == "homestead")
        return EVMC_HOMESTEAD;
    if (value == "tangerine_whistle")
        return EVMC_TANGERINE_WHISTLE;
    if (value == "spurious_dragon")
        return EVMC_SPURIOUS_DRAGON;
    if (value == "byzantium")
        return EVMC_BYZANTIUM;
    if (value == "petersburg")
        return EVMC_PETERSBURG;
    if (value == "istanbul")
        return EVMC_ISTANBUL;
    if (value == "berlin")
        return EVMC_BERLIN;
    if (value == "london")
        return EVMC_LONDON;
    if (value == "paris" || value == "merge")
        return EVMC_PARIS;
    if (value == "shanghai")
        return EVMC_SHANGHAI;
    if (value == "cancun")
        return EVMC_CANCUN;
    if (value == "prague")
        return EVMC_PRAGUE;
    if (value == "osaka" || value == "latest")
        return EVMC_OSAKA;
    return std::nullopt;
}

const char* spec_name(evmc_revision spec) noexcept
{
    switch (spec)
    {
    case EVMC_FRONTIER:
        return "frontier";
    case EVMC_HOMESTEAD:
        return "homestead";
    case EVMC_TANGERINE_WHISTLE:
        return "tangerine_whistle";
    case EVMC_SPURIOUS_DRAGON:
        return "spurious_dragon";
    case EVMC_BYZANTIUM:
        return "byzantium";
    case EVMC_PETERSBURG:
        return "petersburg";
    case EVMC_ISTANBUL:
        return "istanbul";
    case EVMC_BERLIN:
        return "berlin";
    case EVMC_LONDON:
        return "london";
    case EVMC_PARIS:
        return "paris";
    case EVMC_SHANGHAI:
        return "shanghai";
    case EVMC_CANCUN:
        return "cancun";
    case EVMC_PRAGUE:
        return "prague";
    case EVMC_OSAKA:
        return "osaka";
    default:
        return "unknown";
    }
}

std::optional<HostProfile> parse_host_profile(std::string_view value) noexcept
{
    if (value == "null")
        return HostProfile::null;
    if (value == "mock")
        return HostProfile::mock;
    return std::nullopt;
}

const char* host_profile_name(HostProfile profile) noexcept
{
    return profile == HostProfile::null ? "null" : "mock";
}

std::optional<Mode> parse_mode(std::string_view value) noexcept
{
    if (value == "baseline")
        return Mode::baseline;
    if (value == "advanced" || value == "evmone")
        return Mode::advanced;
    return std::nullopt;
}

const char* engine_name(Mode mode) noexcept
{
    return mode == Mode::baseline ? "evmone-baseline" : "evmone-advanced";
}

void print_usage()
{
    std::cerr
        << "Usage:\n"
        << "  zig build evmone-vm-loop -- --fixture <dir>\n"
        << "  zig build evmone-vm-loop -- --contract-code-path <hex-file> --call-data <hex> --num-runs <n>\n"
        << "\nOptions:\n"
        << "  --fixture <dir>              fixture dir containing init.hex plus optional metadata\n"
        << "  --contract-code-path <path>  init-code hex file to deploy once\n"
        << "  --call-data <hex>            calldata hex for each runtime call\n"
        << "  --num-runs, -n <n>           number of timed calls\n"
        << "  --warmup-ms <n>              discarded warmup duration in milliseconds, default 100; 0 disables\n"
        << "  --spec <name>                osaka, prague, cancun, shanghai, latest; default osaka\n"
        << "  --host-profile <null|mock>   fixture host profile label, default null\n"
        << "  --mode <advanced|baseline>   evmone mode, default advanced\n"
        << "  --summary                    print fixture metadata to stderr\n";
}

ResolvedOptions resolve_options(Options options)
{
    if (options.fixture_dir)
    {
        const auto& fixture_dir = *options.fixture_dir;
        if (!options.contract_code_path)
            options.contract_code_path = fixture_path(fixture_dir, "init.hex");
        if (!options.call_data_hex)
            options.call_data_hex = read_optional_file(fixture_path(fixture_dir, "calldata.hex")).value_or("");
        if (!options.num_runs)
        {
            if (const auto text = read_optional_file(fixture_path(fixture_dir, "num-runs.txt")))
                options.num_runs = parse_nonzero_usize(trim(*text));
        }
        if (const auto text = read_optional_file(fixture_path(fixture_dir, "host-profile.txt")))
        {
            const auto parsed = parse_host_profile(trim(*text));
            if (!parsed)
                throw std::runtime_error("invalid fixture host profile");
            options.host_profile = *parsed;
        }
    }

    if (!options.contract_code_path)
        throw std::runtime_error("missing contract code path");

    return ResolvedOptions{
        options.fixture_dir,
        *options.contract_code_path,
        options.call_data_hex.value_or(""),
        options.num_runs.value_or(1),
        options.warmup_ms,
        options.spec,
        options.host_profile,
        options.mode,
        options.summary,
    };
}

void reject_null_host_touches(HostProfile profile, const HostCounters& counters)
{
    if (profile == HostProfile::null && counters.total != 0)
        throw std::runtime_error("null host fixture touched " + std::to_string(counters.total) + " evmone host callbacks");
}

Options parse_args(int argc, char** argv)
{
    Options options;
    for (int index = 1; index < argc; ++index)
    {
        const std::string_view arg(argv[index]);
        auto require_value = [&](const char* name) -> std::string {
            if (++index >= argc)
                throw std::runtime_error(std::string("missing ") + name + " value");
            return argv[index];
        };

        if (arg == "--help" || arg == "-h")
        {
            print_usage();
            std::exit(0);
        }
        if (arg == "--fixture")
            options.fixture_dir = require_value("--fixture");
        else if (arg.starts_with("--fixture="))
            options.fixture_dir = std::string(arg.substr(10));
        else if (arg == "--contract-code-path")
            options.contract_code_path = require_value("--contract-code-path");
        else if (arg.starts_with("--contract-code-path="))
            options.contract_code_path = std::string(arg.substr(21));
        else if (arg == "--call-data")
            options.call_data_hex = require_value("--call-data");
        else if (arg.starts_with("--call-data="))
            options.call_data_hex = std::string(arg.substr(12));
        else if (arg == "--num-runs" || arg == "-n")
            options.num_runs = parse_nonzero_usize(require_value("--num-runs"));
        else if (arg.starts_with("--num-runs="))
            options.num_runs = parse_nonzero_usize(std::string(arg.substr(11)));
        else if (arg == "--warmup-ms")
            options.warmup_ms = parse_usize(require_value("--warmup-ms"));
        else if (arg.starts_with("--warmup-ms="))
            options.warmup_ms = parse_usize(std::string(arg.substr(12)));
        else if (arg == "--spec")
        {
            const auto parsed = parse_spec(require_value("--spec"));
            if (!parsed)
                throw std::runtime_error("invalid spec");
            options.spec = *parsed;
        }
        else if (arg.starts_with("--spec="))
        {
            const auto parsed = parse_spec(arg.substr(7));
            if (!parsed)
                throw std::runtime_error("invalid spec");
            options.spec = *parsed;
        }
        else if (arg == "--host-profile")
        {
            const auto parsed = parse_host_profile(require_value("--host-profile"));
            if (!parsed)
                throw std::runtime_error("invalid host profile");
            options.host_profile = *parsed;
        }
        else if (arg.starts_with("--host-profile="))
        {
            const auto parsed = parse_host_profile(arg.substr(15));
            if (!parsed)
                throw std::runtime_error("invalid host profile");
            options.host_profile = *parsed;
        }
        else if (arg == "--mode")
        {
            const auto parsed = parse_mode(require_value("--mode"));
            if (!parsed)
                throw std::runtime_error("invalid mode");
            options.mode = *parsed;
        }
        else if (arg.starts_with("--mode="))
        {
            const auto parsed = parse_mode(arg.substr(7));
            if (!parsed)
                throw std::runtime_error("invalid mode");
            options.mode = *parsed;
        }
        else if (arg == "--summary")
            options.summary = true;
        else
            throw std::runtime_error("unknown argument: " + std::string(arg));
    }
    return options;
}
}

int main(int argc, char** argv)
{
    try
    {
        const auto options = resolve_options(parse_args(argc, argv));
        const auto init_code = decode_hex(read_file(options.contract_code_path));
        const auto call_data = decode_hex(options.call_data_hex);

        VmHandle vm(options.mode);
        const auto deploy = execute(vm.ptr, EVMC_CREATE, init_code, {}, options.spec, false);
        reject_null_host_touches(options.host_profile, deploy.counters);
        const evmone::bytes_view runtime_view{deploy.output.data(), deploy.output.size()};
        const auto baseline_analysis = evmone::baseline::analyze(runtime_view);
        const auto advanced_analysis = evmone::advanced::analyze(options.spec, runtime_view);
        auto& evmone_vm = *static_cast<evmone::VM*>(vm.ptr);

        const auto run_runtime_call = [&]() {
            return options.mode == Mode::advanced ?
                execute_analyzed(advanced_analysis, deploy.output, call_data, options.spec) :
                execute_baseline_analyzed(evmone_vm, baseline_analysis, call_data, options.spec);
        };

        size_t warmup_calls = 0;
        uint64_t warmup_elapsed_ns = 0;
        if (options.warmup_ms != 0)
        {
            if (options.warmup_ms > std::numeric_limits<uint64_t>::max() / 1'000'000)
                throw std::runtime_error("warmup duration is too large");
            const auto warmup_target_ns = static_cast<uint64_t>(options.warmup_ms) * 1'000'000;
            const auto warmup_start = std::chrono::steady_clock::now();
            do
            {
                const auto measurement = run_runtime_call();
                reject_null_host_touches(options.host_profile, measurement.counters);
                if (warmup_calls == std::numeric_limits<size_t>::max())
                    throw std::runtime_error("warmup call count overflow");
                ++warmup_calls;
                warmup_elapsed_ns = static_cast<uint64_t>(
                    std::chrono::duration_cast<std::chrono::nanoseconds>(
                        std::chrono::steady_clock::now() - warmup_start)
                        .count());
            } while (warmup_elapsed_ns < warmup_target_ns);
        }

        HostCounters timed_counters;
        for (size_t run = 0; run < options.num_runs; ++run)
        {
            const auto measurement = run_runtime_call();
            reject_null_host_touches(options.host_profile, measurement.counters);
            timed_counters.total += measurement.counters.total;
            timed_counters.logs += measurement.counters.logs;
            std::cout << (static_cast<double>(measurement.elapsed_ns) / 1'000'000.0) << "\n";
        }

        if (options.summary)
        {
            std::cerr
                << "fixture=" << options.fixture_dir.value_or("")
                << " engine=" << engine_name(options.mode)
                << " scope=" << (options.mode == Mode::advanced ? "advanced-analyzed-execute" : "baseline-analyzed-execute")
                << " host_profile=" << host_profile_name(options.host_profile)
                << " spec=" << spec_name(options.spec)
                << " runtime_bytes=" << deploy.output.size()
                << " deploy_host_calls=" << deploy.counters.total
                << " timed_host_calls=" << timed_counters.total
                << " logs=" << timed_counters.logs
                << " warmup_ms=" << options.warmup_ms
                << " warmup_calls=" << warmup_calls
                << " warmup_elapsed_ms=" << (static_cast<double>(warmup_elapsed_ns) / 1'000'000.0)
                << "\n";
        }
    }
    catch (const std::exception& err)
    {
        std::cerr << "error: " << err.what() << "\n";
        return 1;
    }
    return 0;
}
