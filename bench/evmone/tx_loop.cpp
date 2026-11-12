// Transaction-level lane: one complete transaction per call on evmone's state-test harness.
//
// Mirrors `bench/src/tx_loop.zig`. The addresses, fees and setup transactions below must stay
// identical in both files.
//
// evmone ships no block executor. `test::transition` is the transaction entry point of its
// state-test tooling: it validates, runs the transaction on a fresh `state::State` over a
// `std::map` world state, and applies the returned `StateDiff`. Callee code is copied out of the
// world state and analyzed again on every transaction.
#include <evmc/evmc.hpp>
#include <evmone/create_address.hpp>
#include <test/state/hash_utils.hpp>
#include <test/state/state.hpp>
#include <test/utils/test_state.hpp>

#include <chrono>
#include <cstdint>
#include <cstdio>
#include <fstream>
#include <limits>
#include <optional>
#include <sstream>
#include <stdexcept>
#include <string>
#include <string_view>
#include <system_error>
#include <variant>

extern "C" evmc_vm* evmc_create_evmone() noexcept;

namespace
{
using evmc::address;
using evmc::bytes;
using evmc::bytes32;
using intx::uint256;
using namespace evmc::literals;
namespace state = evmone::state;
namespace test = evmone::test;

constexpr auto sender = 0x1000000000000000000000000000000000000001_address;
constexpr auto recipient = 0x3000000000000000000000000000000000000003_address;
constexpr auto coinbase = 0xc000000000000000000000000000000000000000_address;

constexpr uint64_t base_fee = 7;
constexpr uint64_t gas_price = 10;
constexpr int64_t block_gas_limit = 60'000'000;
/// Below the EIP-7825 transaction gas cap of 2^24.
constexpr int64_t setup_gas_limit = 16'000'000;
/// Covers every workload on every fork, including forks that reprice the intrinsic cost.
constexpr int64_t workload_gas_limit = 100'000;

constexpr uint32_t selector_benchmark = 0x30627b7c;
constexpr uint32_t selector_balance_of = 0x70a08231;
constexpr uint32_t selector_transfer = 0xa9059cbb;

enum class Case
{
    /// 1 wei legacy transfer to an existing codeless account. Never enters the interpreter.
    eth_transfer,
    /// Zero-value call to a contract whose runtime is `STOP`.
    stop_call,
    /// One `transfer(address,uint256)` on the evm-bench ERC-20, both balance slots non-zero.
    erc20_transfer,
};

struct Options
{
    Case test_case = Case::eth_transfer;
    evmc_revision spec = EVMC_OSAKA;
    size_t repeats = 5;
    size_t warmups = 1;
    size_t txs = 1000;
    std::string fixtures_dir = "fixtures/vm-loop";
    bool header = true;
    bool summary = false;

    [[nodiscard]] uint64_t measured_transactions() const noexcept
    {
        return static_cast<uint64_t>(warmups + repeats) * txs;
    }
};

struct Call
{
    std::optional<address> to;
    uint64_t value = 0;
    bytes input;
    int64_t gas_limit = 0;
};

/// The transaction every timed call repeats. Only the nonce changes.
struct Workload
{
    state::Transaction tx;
    address target;
    /// Gas used by one steady-state transaction, measured by the last setup transaction.
    int64_t gas_per_tx = 0;
    /// Recipient balance the timed transactions must add to, checked after the run.
    uint256 expected_before;
};

/// Encodes `selector(address)` or `selector(address,uint256)`.
bytes abi_call(uint32_t selector, const address& account, std::optional<uint64_t> amount)
{
    bytes data(amount.has_value() ? 68 : 36, 0);
    for (size_t i = 0; i < 4; ++i)
        data[i] = static_cast<uint8_t>(selector >> (24 - 8 * i));
    for (size_t i = 0; i < sizeof(account.bytes); ++i)
        data[16 + i] = account.bytes[i];
    if (amount.has_value())
    {
        for (size_t i = 0; i < 8; ++i)
            data[60 + i] = static_cast<uint8_t>(*amount >> (56 - 8 * i));
    }
    return data;
}

/// Storage key of `holder` in the token's `mapping(address => uint256)` at slot 0.
bytes32 token_balance_key(const address& holder) noexcept
{
    uint8_t preimage[64] = {};
    for (size_t i = 0; i < sizeof(holder.bytes); ++i)
        preimage[12 + i] = holder.bytes[i];
    return evmone::keccak256({preimage, sizeof(preimage)});
}

bytes read_hex_file(const std::string& path)
{
    std::ifstream file{path};
    if (!file)
        throw std::runtime_error(path + ": cannot open");
    std::stringstream text;
    text << file.rdbuf();
    auto hex = text.str();
    while (!hex.empty() && std::isspace(static_cast<unsigned char>(hex.back())))
        hex.pop_back();
    auto decoded = evmc::from_hex(hex);
    if (!decoded.has_value())
        throw std::runtime_error(path + ": invalid hex");
    return *decoded;
}

struct Runner
{
    evmc::VM vm{evmc_create_evmone()};
    test::TestState world;
    test::TestBlockHashes block_hashes;
    state::BlockInfo block;
    evmc_revision spec;
    uint64_t nonce = 0;

    explicit Runner(evmc_revision rev) : spec{rev}
    {
        if (!vm)
            throw std::runtime_error("failed to create evmone VM");
        world[sender].balance = uint256{1} << 100;
        block.number = 1;
        block.timestamp = 1;
        block.gas_limit = block_gas_limit;
        block.coinbase = coinbase;
        block.base_fee = base_fee;
        if (spec >= EVMC_AMSTERDAM)
            block.slot_number = 0;
    }

    [[nodiscard]] state::Transaction transaction(const Call& call) const
    {
        state::Transaction tx;
        tx.type = state::Transaction::Type::legacy;
        tx.data = call.input;
        tx.gas_limit = call.gas_limit;
        tx.max_gas_price = gas_price;
        tx.max_priority_gas_price = gas_price;
        tx.sender = sender;
        tx.to = call.to;
        tx.value = call.value;
        tx.nonce = nonce;
        return tx;
    }

    /// Executes one transaction, requires success, and applies its state diff.
    int64_t send(const state::Transaction& tx)
    {
        // A fresh block allowance per transaction, as the other runners apply no block limit.
        const auto outcome = test::transition(world, block, block_hashes, tx, spec, vm,
            block_gas_limit, std::numeric_limits<int64_t>::max(), 0);
        if (const auto* error = std::get_if<std::error_code>(&outcome))
            throw std::runtime_error("transaction rejected: " + error->message());
        const auto& receipt = std::get<state::TransactionReceipt>(outcome);
        if (receipt.status != EVMC_SUCCESS)
        {
            throw std::runtime_error(
                "transaction failed with status " + std::to_string(receipt.status));
        }
        ++nonce;
        return receipt.gas_used;
    }

    int64_t call(const Call& call) { return send(transaction(call)); }

    address deploy(const std::string& fixtures_dir, const std::string& name)
    {
        const auto created = evmone::compute_create_address(sender, nonce);
        call({.to = std::nullopt,
            .input = read_hex_file(fixtures_dir + "/" + name + "/init.hex"),
            .gas_limit = setup_gas_limit});
        const auto it = world.find(created);
        if (it == world.end() || it->second.code.empty())
            throw std::runtime_error("missing created address");
        return created;
    }

    /// Sends the `balanceOf` transaction the other runners send, then reads the balance from the
    /// world state: evmone's receipt carries no return data.
    uint256 token_balance(const address& token, const address& holder)
    {
        call({.to = token,
            .input = abi_call(selector_balance_of, holder, std::nullopt),
            .gas_limit = workload_gas_limit});
        return intx::be::load<uint256>(world.get_storage(token, token_balance_key(holder)));
    }

    /// Brings state to the steady point the timed loop repeats and measures its gas.
    Workload prepare(const Options& options)
    {
        Call workload_call;
        switch (options.test_case)
        {
        case Case::eth_transfer:
            workload_call = {.to = recipient, .value = 1, .gas_limit = workload_gas_limit};
            break;
        case Case::stop_call:
            workload_call = {
                .to = deploy(options.fixtures_dir, "stop-target"), .gas_limit = workload_gas_limit};
            break;
        case Case::erc20_transfer:
        {
            const auto token = deploy(options.fixtures_dir, "erc20-transfer");
            // `Benchmark()` mints to the caller before its own transfer loop.
            bytes selector(4, 0);
            for (size_t i = 0; i < 4; ++i)
                selector[i] = static_cast<uint8_t>(selector_benchmark >> (24 - 8 * i));
            call({.to = token, .input = selector, .gas_limit = setup_gas_limit});
            // Two priming transfers follow, then the timed ones.
            if (token_balance(token, sender) < options.measured_transactions() + 2)
                throw std::runtime_error("insufficient token balance");
            workload_call = {.to = token,
                .input = abi_call(selector_transfer, recipient, 1),
                .gas_limit = workload_gas_limit};
            break;
        }
        }
        // The first call creates the recipient account or balance slot and the coinbase
        // account, which forks with state gas price far above the workload limit. The
        // second already runs in the steady state, so its gas is the reference.
        auto first = workload_call;
        first.gas_limit = setup_gas_limit;
        call(first);
        Workload workload;
        workload.gas_per_tx = call(workload_call);
        workload.target = *workload_call.to;
        workload.expected_before = recipient_balance(options.test_case, workload.target);
        workload.tx = transaction(workload_call);
        return workload;
    }

    uint256 recipient_balance(Case test_case, const address& target)
    {
        switch (test_case)
        {
        case Case::eth_transfer:
        {
            const auto it = world.find(recipient);
            return it == world.end() ? uint256{} : it->second.balance;
        }
        case Case::stop_call:
            return 0;
        case Case::erc20_transfer:
            return token_balance(target, recipient);
        }
        return 0;
    }

    /// Runs `txs` workload transactions and returns the elapsed nanoseconds.
    uint64_t run_batch(Workload& workload, size_t txs)
    {
        int64_t gas_used = 0;
        const auto start = std::chrono::steady_clock::now();
        for (size_t i = 0; i < txs; ++i)
        {
            workload.tx.nonce = nonce;
            gas_used += send(workload.tx);
        }
        const auto end = std::chrono::steady_clock::now();
        if (gas_used != workload.gas_per_tx * static_cast<int64_t>(txs))
            throw std::runtime_error("unsteady gas");
        return static_cast<uint64_t>(
            std::chrono::duration_cast<std::chrono::nanoseconds>(end - start).count());
    }
};

Case parse_case(std::string_view value)
{
    if (value == "eth-transfer")
        return Case::eth_transfer;
    if (value == "stop-call")
        return Case::stop_call;
    if (value == "erc20-transfer")
        return Case::erc20_transfer;
    throw std::runtime_error("unknown case: " + std::string{value});
}

const char* case_name(Case test_case) noexcept
{
    switch (test_case)
    {
    case Case::eth_transfer:
        return "eth-transfer";
    case Case::stop_call:
        return "stop-call";
    case Case::erc20_transfer:
        return "erc20-transfer";
    }
    return "";
}

evmc_revision parse_spec(std::string_view value)
{
    if (value == "latest" || value == "amsterdam")
        return EVMC_AMSTERDAM;
    if (value == "osaka")
        return EVMC_OSAKA;
    if (value == "prague")
        return EVMC_PRAGUE;
    if (value == "cancun")
        return EVMC_CANCUN;
    if (value == "shanghai")
        return EVMC_SHANGHAI;
    throw std::runtime_error("unsupported spec: " + std::string{value});
}

const char* spec_name(evmc_revision spec) noexcept
{
    switch (spec)
    {
    case EVMC_AMSTERDAM:
        return "amsterdam";
    case EVMC_OSAKA:
        return "osaka";
    case EVMC_PRAGUE:
        return "prague";
    case EVMC_CANCUN:
        return "cancun";
    default:
        return "shanghai";
    }
}

size_t parse_count(const std::string& value, bool allow_zero)
{
    size_t consumed = 0;
    const auto count = std::stoull(value, &consumed);
    if (consumed != value.size() || (!allow_zero && count == 0))
        throw std::runtime_error("invalid count: " + value);
    return count;
}

void print_usage()
{
    std::fputs(
        "evmone transaction loop: [options]\n"
        "  --case <eth-transfer|stop-call|erc20-transfer>\n"
        "  --spec <fork> --repeats <n> --warmups <n> --txs <n>\n"
        "  --fixtures-dir <path> --no-header --summary\n"
        "\n"
        "Runs evmone's baseline interpreter under its state-test transition harness.\n",
        stderr);
}

/// Returns false when the arguments only asked for the usage text.
bool parse_options(int argc, char** argv, Options& options)
{
    for (int i = 1; i < argc; ++i)
    {
        const std::string_view arg{argv[i]};
        if (arg == "--help" || arg == "-h")
        {
            print_usage();
            return false;
        }
        if (arg == "--no-header")
        {
            options.header = false;
            continue;
        }
        if (arg == "--summary")
        {
            options.summary = true;
            continue;
        }
        std::string flag{arg};
        std::string value;
        if (const auto split = arg.find('='); split != std::string_view::npos)
        {
            flag = arg.substr(0, split);
            value = arg.substr(split + 1);
        }
        else if (flag == "--case" || flag == "--spec" || flag == "--repeats" ||
                 flag == "--warmups" || flag == "--txs" || flag == "--fixtures-dir")
        {
            if (++i == argc)
                throw std::runtime_error("missing " + flag + " value");
            value = argv[i];
        }
        if (flag == "--case")
            options.test_case = parse_case(value);
        else if (flag == "--spec")
            options.spec = parse_spec(value);
        else if (flag == "--repeats")
            options.repeats = parse_count(value, false);
        else if (flag == "--warmups")
            options.warmups = parse_count(value, true);
        else if (flag == "--txs")
            options.txs = parse_count(value, false);
        else if (flag == "--fixtures-dir")
            options.fixtures_dir = value;
        else
            throw std::runtime_error("unknown argument: " + flag);
    }
    return true;
}

void run(const Options& options)
{
    Runner runner{options.spec};
    auto workload = runner.prepare(options);

    for (size_t i = 0; i < options.warmups; ++i)
        runner.run_batch(workload, options.txs);

    if (options.header)
    {
        std::puts(
            "suite,engine,case,spec,code_cache,repeat,txs,elapsed_ns,ns_per_tx,gas_per_tx");
    }
    for (size_t repeat = 0; repeat < options.repeats; ++repeat)
    {
        const auto elapsed_ns = runner.run_batch(workload, options.txs);
        // The harness copies and analyzes callee code on every transaction.
        std::printf("tx-loop,evmone-baseline,%s,%s,false,%zu,%zu,%llu,%.3f,%lld\n",
            case_name(options.test_case), spec_name(options.spec), repeat, options.txs,
            static_cast<unsigned long long>(elapsed_ns),
            static_cast<double>(elapsed_ns) / static_cast<double>(options.txs),
            static_cast<long long>(workload.gas_per_tx));
    }

    // Each timed transaction moves one unit to the recipient, so a lost state transition shows.
    if (options.test_case != Case::stop_call)
    {
        const auto balance = runner.recipient_balance(options.test_case, workload.target);
        if (balance != workload.expected_before + options.measured_transactions())
            throw std::runtime_error("recipient balance mismatch");
    }

    if (options.summary)
    {
        std::fprintf(stderr,
            "engine=evmone-baseline case=%s spec=%s code_cache=false warmups=%zu repeats=%zu "
            "txs=%zu gas_per_tx=%lld\n",
            case_name(options.test_case), spec_name(options.spec), options.warmups,
            options.repeats, options.txs, static_cast<long long>(workload.gas_per_tx));
    }
}
}  // namespace

int main(int argc, char** argv)
{
    try
    {
        Options options;
        if (!parse_options(argc, argv, options))
            return 0;
        run(options);
        return 0;
    }
    catch (const std::exception& error)
    {
        std::fprintf(stderr, "%s\n", error.what());
        return 1;
    }
}
