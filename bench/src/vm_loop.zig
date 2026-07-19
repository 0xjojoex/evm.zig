const std = @import("std");
const evmz = @import("evmz");
const build_options = @import("build_options");
const common = @import("common.zig");

const Host = evmz.Host;
const Interpreter = evmz.interpreter;
const BenchVM = evmz.EvmWith(.{
    .support = .{
        .min = parseBuildSpec(build_options.support_min),
        .max = parseBuildSpec(build_options.support_max),
    },
});
const BenchExecutionProtocol = BenchVM.ExecutionProtocol;
const Executor = BenchVM.Executor;
const CountingHost = common.CountingHost;
const HostCounters = common.HostCounters;
const HostProfile = common.HostProfile;

const max_contract_code_size = 256 * 1024 * 1024;
const default_warmup_ms = 100;
const proxy_target_address = evmz.addr(0x3000000000000000000000000000000000000003);

const Options = struct {
    fixture_dir: ?[]const u8 = null,
    contract_code_path: ?[]const u8 = null,
    proxy_target_code_path: ?[]const u8 = null,
    call_data_hex: ?[]const u8 = null,
    num_runs: ?usize = null,
    warmup_ms: usize = default_warmup_ms,
    gas_limit: ?u64 = null,
    revision: evmz.eth.Revision = .latest,
    engine: Engine = .evmz,
    executor_resources: ExecutorResources = .growable,
    host_profile: ?HostProfile = null,
    summary: bool = false,
};

const ResolvedOptions = struct {
    fixture_dir: ?[]const u8,
    contract_code_path: []const u8,
    proxy_target_code_path: ?[]const u8 = null,
    call_data_hex: []const u8,
    num_runs: usize,
    warmup_ms: usize,
    gas_limit: u64,
    revision: evmz.eth.Revision,
    engine: Engine,
    executor_resources: ExecutorResources,
    host_profile: HostProfile,
    summary: bool,
};

const Engine = enum {
    evmz,
    evmz_executor,
};

const ExecutorResources = enum {
    growable,
    bounded_frames,
    bounded_frame_memory,
    bounded_scratch,
    bounded_access,
    bounded_journal,
    bounded_state,
    bounded_state_small,
    bounded_logs,
    bounded_overlay,
    bounded_overlay_small,
    bounded_small,
    bounded,
};

const WarmupStats = struct {
    calls: usize = 0,
    elapsed_ns: u64 = 0,
};

const RuntimeMeasurement = struct {
    elapsed_ns: u64,
    counters: HostCounters,
};

const ExecutorRuntimeRunner = struct {
    allocator: std.mem.Allocator,
    executor: Executor,
    bytecode: evmz.Bytecode,
    baseline: Executor.Snapshot,

    fn init(
        allocator: std.mem.Allocator,
        runtime_code: []const u8,
        proxy_target_runtime_code: ?[]const u8,
        revision: evmz.eth.Revision,
        executor_resources: ExecutorResources,
    ) !ExecutorRuntimeRunner {
        var executor = switch (executor_resources) {
            .growable => Executor.init(allocator, .{ .revision = revision }),
            else => try Executor.initWithRuntimeResources(allocator, .{
                .revision = revision,
            }, .{ .bounded = benchBoundedRuntimeResources(executor_resources) }),
        };
        errdefer executor.deinit();

        const sender = try executor.getOrCreateAccount(common.caller_address);
        sender.balance = std.math.maxInt(u256);

        _ = try executor.getOrCreateAccount(common.contract_address);
        try executor.state.setCode(common.contract_address, runtime_code);
        if (proxy_target_runtime_code) |target_code| {
            _ = try executor.getOrCreateAccount(proxy_target_address);
            try executor.state.setCode(proxy_target_address, target_code);
        }

        var bytecode = try executor.prepareBytecode(runtime_code);
        errdefer bytecode.deinit(allocator);

        var baseline = try executor.snapshot();
        errdefer baseline.deinit(allocator);

        return .{
            .allocator = allocator,
            .executor = executor,
            .bytecode = bytecode,
            .baseline = baseline,
        };
    }

    fn deinit(self: *ExecutorRuntimeRunner) void {
        self.baseline.deinit(self.allocator);
        self.bytecode.deinit(self.allocator);
        self.executor.deinit();
    }

    fn timeRuntimeCall(self: *ExecutorRuntimeRunner, call_data: []const u8, gas_limit: u64) !u64 {
        try self.executor.restore(&self.baseline);
        try self.executor.beginTransaction(executorTxContext(gas_limit), common.caller_address, common.contract_address);

        var pre_execution = try self.executor.snapshot();
        defer pre_execution.deinit(self.allocator);

        const start_ns = try common.monotonicNowNs();
        const call_options = Executor.PreparedCallTransaction{
            .bytecode = &self.bytecode,
            .sender = common.caller_address,
            .recipient = common.contract_address,
            .input = call_data,
            .gas = gas_limit,
            .value = 0,
        };
        const result = try self.executor.executePreparedCallTransaction(call_options);
        const end_ns = try common.monotonicNowNs();

        if (Executor.executionRolledBack(result.status)) {
            try self.executor.restore(&pre_execution);
        } else {
            try self.executor.commitTransaction();
        }
        if (result.status != .success) return error.CallFailed;

        return end_ns - start_ns;
    }
};

pub fn main(init: std.process.Init) !void {
    const allocator = try common.benchmarkAllocator(init);
    const arena = init.arena.allocator();

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(init.io, &stdout_buffer);
    const stdout = &stdout_writer.interface;

    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, allocator);
    defer args.deinit();
    _ = args.next();

    var options = Options{};
    while (args.next()) |arg_z| {
        const arg = arg_z[0..arg_z.len];
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            printUsage();
            return;
        } else if (std.mem.eql(u8, arg, "--fixture")) {
            const value = args.next() orelse return error.MissingFixture;
            options.fixture_dir = try arena.dupe(u8, value);
        } else if (common.stripPrefix(arg, "--fixture=")) |value| {
            options.fixture_dir = try arena.dupe(u8, value);
        } else if (std.mem.eql(u8, arg, "--contract-code-path")) {
            const value = args.next() orelse return error.MissingContractCodePath;
            options.contract_code_path = try arena.dupe(u8, value);
        } else if (common.stripPrefix(arg, "--contract-code-path=")) |value| {
            options.contract_code_path = try arena.dupe(u8, value);
        } else if (std.mem.eql(u8, arg, "--proxy-target-code-path")) {
            const value = args.next() orelse return error.MissingProxyTargetCodePath;
            options.proxy_target_code_path = try arena.dupe(u8, value);
        } else if (common.stripPrefix(arg, "--proxy-target-code-path=")) |value| {
            options.proxy_target_code_path = try arena.dupe(u8, value);
        } else if (std.mem.eql(u8, arg, "--call-data")) {
            const value = args.next() orelse return error.MissingCallData;
            options.call_data_hex = try arena.dupe(u8, value);
        } else if (common.stripPrefix(arg, "--call-data=")) |value| {
            options.call_data_hex = try arena.dupe(u8, value);
        } else if (std.mem.eql(u8, arg, "--num-runs") or std.mem.eql(u8, arg, "-n")) {
            const value = args.next() orelse return error.MissingNumRuns;
            options.num_runs = try common.parseNonZeroUsize(value);
        } else if (common.stripPrefix(arg, "--num-runs=")) |value| {
            options.num_runs = try common.parseNonZeroUsize(value);
        } else if (std.mem.eql(u8, arg, "--warmup-ms")) {
            const value = args.next() orelse return error.MissingWarmupMs;
            options.warmup_ms = try common.parseUsize(value);
        } else if (common.stripPrefix(arg, "--warmup-ms=")) |value| {
            options.warmup_ms = try common.parseUsize(value);
        } else if (std.mem.eql(u8, arg, "--gas-limit")) {
            const value = args.next() orelse return error.MissingGasLimit;
            options.gas_limit = try parseNonZeroU64(value);
        } else if (common.stripPrefix(arg, "--gas-limit=")) |value| {
            options.gas_limit = try parseNonZeroU64(value);
        } else if (std.mem.eql(u8, arg, "--spec")) {
            const value = args.next() orelse return error.MissingSpec;
            options.revision = common.parseSpec(value) orelse return error.InvalidSpec;
        } else if (common.stripPrefix(arg, "--spec=")) |value| {
            options.revision = common.parseSpec(value) orelse return error.InvalidSpec;
        } else if (std.mem.eql(u8, arg, "--engine")) {
            const value = args.next() orelse return error.MissingEngine;
            options.engine = parseEngine(value) orelse return error.InvalidEngine;
        } else if (common.stripPrefix(arg, "--engine=")) |value| {
            options.engine = parseEngine(value) orelse return error.InvalidEngine;
        } else if (std.mem.eql(u8, arg, "--executor-resources")) {
            const value = args.next() orelse return error.MissingExecutorResources;
            options.executor_resources = parseExecutorResources(value) orelse return error.InvalidExecutorResources;
        } else if (common.stripPrefix(arg, "--executor-resources=")) |value| {
            options.executor_resources = parseExecutorResources(value) orelse return error.InvalidExecutorResources;
        } else if (std.mem.eql(u8, arg, "--host-profile")) {
            const value = args.next() orelse return error.MissingHostProfile;
            options.host_profile = common.parseHostProfile(value) orelse return error.InvalidHostProfile;
        } else if (common.stripPrefix(arg, "--host-profile=")) |value| {
            options.host_profile = common.parseHostProfile(value) orelse return error.InvalidHostProfile;
        } else if (std.mem.eql(u8, arg, "--summary")) {
            options.summary = true;
        } else {
            return error.UnknownArgument;
        }
    }

    const resolved = resolveOptions(init.io, arena, options) catch |err| switch (err) {
        error.MissingContractCodePath => {
            printUsage();
            return err;
        },
        else => return err,
    };

    const contract_code_path = resolved.contract_code_path;
    if (contract_code_path.len == 0) {
        printUsage();
        return error.MissingContractCodePath;
    }
    if (!BenchExecutionProtocol.support.contains(resolved.revision)) {
        std.debug.print(
            "spec {s} is outside compiled support range {s}..{s}\n",
            .{ @tagName(resolved.revision), @tagName(BenchExecutionProtocol.support.min), @tagName(BenchExecutionProtocol.support.max) },
        );
        return error.SpecOutsideSupportRange;
    }

    const call_data = try common.decodeHexAlloc(allocator, resolved.call_data_hex);
    defer allocator.free(call_data);

    var deploy_host = CountingHost.init(allocator, resolved.host_profile);
    defer deploy_host.deinit();
    var deploy_host_iface = deploy_host.host();
    const runtime_code = try loadRuntimeCode(init.io, allocator, &deploy_host_iface, contract_code_path, resolved.revision);
    defer allocator.free(runtime_code);
    const proxy_target_runtime_code = if (resolved.proxy_target_code_path) |target_path|
        try loadRuntimeCode(init.io, allocator, &deploy_host_iface, target_path, resolved.revision)
    else
        null;
    defer if (proxy_target_runtime_code) |target_code| allocator.free(target_code);
    try common.rejectNullHostTouches(resolved.host_profile, deploy_host.counters);

    var executor_runner: ?ExecutorRuntimeRunner = if (isExecutorEngine(resolved.engine))
        try ExecutorRuntimeRunner.init(allocator, runtime_code, proxy_target_runtime_code, resolved.revision, resolved.executor_resources)
    else
        null;
    defer {
        if (executor_runner) |*runner| runner.deinit();
    }

    const warmup = try warmRuntimeCalls(
        allocator,
        if (executor_runner) |*runner| runner else null,
        runtime_code,
        call_data,
        resolved,
    );

    var timed_counters = HostCounters{};
    var run_index: usize = 0;
    while (run_index < resolved.num_runs) : (run_index += 1) {
        const measurement = try measureRuntimeCall(
            allocator,
            if (executor_runner) |*runner| runner else null,
            runtime_code,
            call_data,
            resolved,
        );
        timed_counters.add(measurement.counters);

        const elapsed_ms = @as(f64, @floatFromInt(measurement.elapsed_ns)) / @as(f64, @floatFromInt(std.time.ns_per_ms));
        try stdout.print("{d:.6}\n", .{elapsed_ms});
    }
    try stdout.flush();

    if (resolved.summary) {
        std.debug.print(
            "fixture={s} engine={s} scope={s} host_profile={s} spec={s} support={s}..{s} gas_limit={d} runtime_bytes={d} proxy_target_runtime_bytes={d} deploy_host_calls={d} timed_host_calls={d} logs={d} warmup_ms={d} warmup_calls={d} warmup_elapsed_ms={d:.3}\n",
            .{
                resolved.fixture_dir orelse "",
                engineName(resolved.engine),
                measureScopeName(resolved),
                @tagName(resolved.host_profile),
                @tagName(resolved.revision),
                @tagName(BenchExecutionProtocol.support.min),
                @tagName(BenchExecutionProtocol.support.max),
                resolved.gas_limit,
                runtime_code.len,
                if (proxy_target_runtime_code) |target_code| target_code.len else 0,
                deploy_host.counters.total(),
                timed_counters.total(),
                timed_counters.log,
                resolved.warmup_ms,
                warmup.calls,
                @as(f64, @floatFromInt(warmup.elapsed_ns)) / @as(f64, @floatFromInt(std.time.ns_per_ms)),
            },
        );
        timed_counters.print("timed");
    }
}

fn printUsage() void {
    std.debug.print(
        \\Usage:
        \\  zig build vm-loop -- --fixture <dir>
        \\  zig build vm-loop -- --contract-code-path <hex-file> --call-data <hex> --num-runs <n>
        \\
        \\Options:
        \\  --fixture <dir>              fixture dir containing init.hex plus optional metadata
        \\  --contract-code-path <path>   init-code hex file to deploy once
        \\  --proxy-target-code-path <path>  optional executor-only proxy target init-code
        \\  --call-data <hex>             calldata hex for each runtime call
        \\  --num-runs, -n <n>            number of timed calls
        \\  --warmup-ms <n>               discarded warmup duration in milliseconds, default 100; 0 disables
        \\  --gas-limit <n>               finite gas for each timed runtime call, default maxInt(i64)
        \\  --spec <name>                 fork spec, default latest; must be inside compiled support range
        \\  --engine <name>               evmz, evmz-executor
        \\  --executor-resources <mode>   growable, bounded, or bounded-* probe mode; evmz-executor only
        \\  --host-profile <null|mock>    host boundary, default null
        \\  --summary                     print host callback counts to stderr
        \\  EVMZ_BENCH_ALLOCATOR=smp      opt into std.heap.smp_allocator for allocator probes
        \\
        \\Build options:
        \\  -Dbench-support-min=<name>    compiled support range minimum, default frontier
        \\  -Dbench-support-max=<name>    compiled support range maximum, default latest
        \\
        \\Scopes:
        \\  evmz times direct Interpreter.execute with metadata prepared before timing
        \\  evmz-executor is the transaction/executor diagnostic with tx setup/reset outside timing
        \\
    , .{});
}

fn resolveOptions(io: std.Io, allocator: std.mem.Allocator, options: Options) !ResolvedOptions {
    var contract_code_path = options.contract_code_path;
    var call_data_hex = options.call_data_hex;
    var num_runs = options.num_runs;
    var gas_limit = options.gas_limit;
    var host_profile = options.host_profile;

    if (options.engine != .evmz_executor and options.executor_resources != .growable) {
        return error.ExecutorResourcesRequireExecutorEngine;
    }
    if (options.engine != .evmz_executor and options.proxy_target_code_path != null) {
        return error.ProxyTargetRequiresExecutorEngine;
    }

    if (options.fixture_dir) |fixture_dir| {
        if (contract_code_path == null) {
            contract_code_path = try fixturePath(allocator, fixture_dir, "init.hex");
        }
        if (call_data_hex == null) {
            call_data_hex = try readOptionalFixtureText(io, allocator, fixture_dir, "calldata.hex") orelse "";
        }
        if (num_runs == null) {
            if (try readOptionalFixtureText(io, allocator, fixture_dir, "num-runs.txt")) |text| {
                num_runs = try parseFixtureUsize(text);
            }
        }
        if (gas_limit == null) {
            if (try readOptionalFixtureText(io, allocator, fixture_dir, "gas-limit.txt")) |text| {
                gas_limit = try parseFixtureU64(text);
            }
        }
        if (host_profile == null) {
            if (try readOptionalFixtureText(io, allocator, fixture_dir, "host-profile.txt")) |text| {
                host_profile = common.parseHostProfile(trimFixtureText(text)) orelse return error.InvalidHostProfile;
            }
        }
    }

    return .{
        .fixture_dir = options.fixture_dir,
        .contract_code_path = contract_code_path orelse return error.MissingContractCodePath,
        .proxy_target_code_path = options.proxy_target_code_path,
        .call_data_hex = call_data_hex orelse "",
        .num_runs = num_runs orelse 1,
        .warmup_ms = options.warmup_ms,
        .gas_limit = gas_limit orelse defaultGasLimit(),
        .revision = options.revision,
        .engine = options.engine,
        .executor_resources = options.executor_resources,
        .host_profile = host_profile orelse .null,
        .summary = options.summary,
    };
}

fn parseEngine(value: []const u8) ?Engine {
    inline for (std.meta.fields(Engine)) |field| {
        if (tagNameMatches(value, field.name)) return @enumFromInt(field.value);
    }
    return null;
}

fn parseExecutorResources(value: []const u8) ?ExecutorResources {
    inline for (std.meta.fields(ExecutorResources)) |field| {
        if (tagNameMatches(value, field.name)) return @enumFromInt(field.value);
    }
    return null;
}

fn engineName(engine: Engine) []const u8 {
    return switch (engine) {
        .evmz => "evmz",
        .evmz_executor => "evmz-executor",
    };
}

fn isExecutorEngine(engine: Engine) bool {
    return switch (engine) {
        .evmz_executor => true,
        else => false,
    };
}

fn measureScopeName(options: ResolvedOptions) []const u8 {
    return switch (options.engine) {
        .evmz => "interpreter-prepared-execute",
        .evmz_executor => switch (options.executor_resources) {
            .growable => "executor-prepared-call-growable",
            .bounded_frames => "executor-prepared-call-bounded-frames",
            .bounded_frame_memory => "executor-prepared-call-bounded-frame-memory",
            .bounded_scratch => "executor-prepared-call-bounded-scratch",
            .bounded_access => "executor-prepared-call-bounded-access",
            .bounded_journal => "executor-prepared-call-bounded-journal",
            .bounded_state => "executor-prepared-call-bounded-state",
            .bounded_state_small => "executor-prepared-call-bounded-state-small",
            .bounded_logs => "executor-prepared-call-bounded-logs",
            .bounded_overlay => "executor-prepared-call-bounded-overlay",
            .bounded_overlay_small => "executor-prepared-call-bounded-overlay-small",
            .bounded_small => "executor-prepared-call-bounded-small",
            .bounded => "executor-prepared-call-bounded",
        },
    };
}

fn benchBoundedRuntimeResources(resources: ExecutorResources) Executor.BoundedRuntimeResources {
    var bounded = Executor.BoundedRuntimeResources{
        .max_live_frames = Executor.default_max_live_frames,
    };

    switch (resources) {
        .growable => unreachable,
        .bounded_frames => {},
        .bounded_frame_memory => {
            bounded.memory_bytes_per_frame = 16 * 1024;
            bounded.io_bytes_per_frame = 16 * 1024;
            bounded.result_bytes = 16 * 1024;
        },
        .bounded_scratch => {
            bounded.scratch_bytes_per_frame = 64 * 1024;
        },
        .bounded_access => {
            bounded.access = broadAccessResources();
        },
        .bounded_journal => {
            bounded.journal_entries = 64 * 1024;
        },
        .bounded_state => {
            bounded.state = broadStateResources();
        },
        .bounded_state_small => {
            bounded.state = smallStateResources();
        },
        .bounded_logs => {
            bounded.logs = broadLogResources();
        },
        .bounded_overlay => {
            bounded.logs = broadLogResources();
            bounded.journal_entries = 64 * 1024;
            bounded.access = broadAccessResources();
            bounded.state = broadStateResources();
            bounded.transient_storage_entries = 64 * 1024;
        },
        .bounded_overlay_small => {
            bounded.logs = smallLogResources();
            bounded.journal_entries = 32 * 1024;
            bounded.access = smallAccessResources();
            bounded.state = smallStateResources();
            bounded.transient_storage_entries = 8 * 1024;
        },
        .bounded_small => {
            bounded.memory_bytes_per_frame = 16 * 1024;
            bounded.io_bytes_per_frame = 16 * 1024;
            bounded.scratch_bytes_per_frame = 64 * 1024;
            bounded.logs = smallLogResources();
            bounded.journal_entries = 32 * 1024;
            bounded.access = smallAccessResources();
            bounded.state = smallStateResources();
            bounded.transient_storage_entries = 8 * 1024;
            bounded.result_bytes = 16 * 1024;
        },
        .bounded => {
            bounded.memory_bytes_per_frame = 16 * 1024;
            bounded.io_bytes_per_frame = 16 * 1024;
            bounded.scratch_bytes_per_frame = 64 * 1024;
            bounded.logs = broadLogResources();
            bounded.journal_entries = 64 * 1024;
            bounded.access = broadAccessResources();
            bounded.state = broadStateResources();
            bounded.transient_storage_entries = 64 * 1024;
            bounded.result_bytes = 16 * 1024;
        },
    }

    return bounded;
}

fn broadLogResources() evmz.state.Overlay.LogResources {
    return .{
        .entries = 16 * 1024,
        .data_bytes = 4 * 1024 * 1024,
    };
}

fn smallLogResources() evmz.state.Overlay.LogResources {
    return .{
        .entries = 8 * 1024,
        .data_bytes = 2 * 1024 * 1024,
    };
}

fn broadAccessResources() evmz.state.Overlay.AccessResources {
    return .{
        .accounts = 16 * 1024,
        .storage_keys = 64 * 1024,
    };
}

fn smallAccessResources() evmz.state.Overlay.AccessResources {
    return .{
        .accounts = 1024,
        .storage_keys = 8 * 1024,
    };
}

fn broadStateResources() evmz.state.Overlay.StateResources {
    return .{
        .accounts = 16 * 1024,
        .original_storage_entries = 64 * 1024,
        .storage_overlay_entries = 64 * 1024,
        .selfdestructed_accounts = 16 * 1024,
        .created_contracts = 16 * 1024,
        .deleted_accounts = 16 * 1024,
        .dirty_accounts = 16 * 1024,
    };
}

fn smallStateResources() evmz.state.Overlay.StateResources {
    return .{
        .accounts = 1024,
        .original_storage_entries = 8 * 1024,
        .storage_overlay_entries = 8 * 1024,
        .selfdestructed_accounts = 1024,
        .created_contracts = 1024,
        .deleted_accounts = 1024,
        .dirty_accounts = 1024,
    };
}

fn executorTxContext(gas_limit: u64) Host.TxContext {
    return .{
        .chain_id = 1,
        .gas_price = 0,
        .origin = common.caller_address,
        .coinbase = evmz.addr(0),
        .number = 0,
        .timestamp = 0,
        .gas_limit = gas_limit,
        .prev_randao = 0,
        .base_fee = 0,
        .blob_base_fee = 0,
        .blob_hashes = &.{},
    };
}

fn tagNameMatches(value: []const u8, tag_name: []const u8) bool {
    if (value.len != tag_name.len) return false;
    for (value, tag_name) |lhs, rhs| {
        if (lhs == rhs) continue;
        if (lhs == '-' and rhs == '_') continue;
        return false;
    }
    return true;
}

fn fixturePath(allocator: std.mem.Allocator, fixture_dir: []const u8, name: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ fixture_dir, name });
}

fn readOptionalFixtureText(
    io: std.Io,
    allocator: std.mem.Allocator,
    fixture_dir: []const u8,
    name: []const u8,
) !?[]const u8 {
    const path = try fixturePath(allocator, fixture_dir, name);
    return std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(16 * 1024)) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
}

fn trimFixtureText(text: []const u8) []const u8 {
    return std.mem.trim(u8, text, " \t\r\n");
}

fn parseFixtureUsize(text: []const u8) !usize {
    return common.parseNonZeroUsize(trimFixtureText(text));
}

fn parseFixtureU64(text: []const u8) !u64 {
    return parseNonZeroU64(trimFixtureText(text));
}

fn parseNonZeroU64(value: []const u8) !u64 {
    const parsed = try std.fmt.parseUnsigned(u64, value, 10);
    if (parsed == 0) return error.InvalidNumber;
    if (parsed > std.math.maxInt(i64)) return error.GasLimitTooLarge;
    return parsed;
}

fn defaultGasLimit() u64 {
    return @intCast(common.max_gas);
}

fn parseBuildSpec(comptime value: []const u8) evmz.eth.Revision {
    inline for (std.meta.fields(evmz.eth.Revision)) |field| {
        if (comptime tagNameMatches(value, field.name)) return @enumFromInt(field.value);
    }
    if (comptime std.mem.eql(u8, value, "latest")) return .latest;
    @compileError("invalid VM-loop support revision: " ++ value);
}

fn deployRuntime(
    allocator: std.mem.Allocator,
    host: *Host,
    contract_code: []const u8,
    revision: evmz.eth.Revision,
) ![]u8 {
    return deployRuntimeForProtocol(BenchExecutionProtocol, allocator, host, contract_code, revision);
}

fn loadRuntimeCode(
    io: std.Io,
    allocator: std.mem.Allocator,
    host: *Host,
    init_code_path: []const u8,
    revision: evmz.eth.Revision,
) ![]u8 {
    const init_code_hex = try std.Io.Dir.cwd().readFileAlloc(
        io,
        init_code_path,
        allocator,
        .limited(max_contract_code_size * 2),
    );
    defer allocator.free(init_code_hex);

    const init_code = try common.decodeHexAlloc(allocator, init_code_hex);
    defer allocator.free(init_code);
    return deployRuntime(allocator, host, init_code, revision);
}

fn deployRuntimeForProtocol(
    comptime Protocol: type,
    allocator: std.mem.Allocator,
    host: *Host,
    contract_code: []const u8,
    revision: Protocol.Revision,
) ![]u8 {
    const msg = Host.Message{
        .depth = 0,
        .kind = .create,
        .gas = common.max_gas,
        .recipient = common.contract_address,
        .sender = common.caller_address,
        .input_data = &.{},
        .value = 0,
        .code_address = common.contract_address,
    };

    var frame = try Interpreter.OwnedCallFrame(Protocol).init(allocator, .{
        .host = host,
        .msg = &msg,
        .code = contract_code,
        .revision = revision,
    });
    defer frame.deinit();
    var interpreter = frame.interpreter();

    const result = try interpreter.execute();
    if (result.status != .success) return error.DeployFailed;
    return allocator.dupe(u8, result.output_data);
}

fn timeRuntimeCall(
    allocator: std.mem.Allocator,
    host: *Host,
    runtime_code: []const u8,
    call_data: []const u8,
    revision: evmz.eth.Revision,
    gas_limit: u64,
) !u64 {
    return timeRuntimeCallForProtocol(BenchExecutionProtocol, allocator, host, runtime_code, call_data, revision, gas_limit);
}

fn warmRuntimeCalls(
    allocator: std.mem.Allocator,
    executor_runner: ?*ExecutorRuntimeRunner,
    runtime_code: []const u8,
    call_data: []const u8,
    options: ResolvedOptions,
) !WarmupStats {
    if (options.warmup_ms == 0) return .{};

    const warmup_ms = std.math.cast(u64, options.warmup_ms) orelse return error.WarmupDurationOverflow;
    const target_ns = std.math.mul(u64, warmup_ms, std.time.ns_per_ms) catch return error.WarmupDurationOverflow;
    const start_ns = try common.monotonicNowNs();
    var stats = WarmupStats{};
    while (stats.elapsed_ns < target_ns) {
        _ = try measureRuntimeCall(allocator, executor_runner, runtime_code, call_data, options);
        stats.calls = std.math.add(usize, stats.calls, 1) catch return error.WarmupCallCountOverflow;
        stats.elapsed_ns = (try common.monotonicNowNs()) - start_ns;
    }
    return stats;
}

fn measureRuntimeCall(
    allocator: std.mem.Allocator,
    executor_runner: ?*ExecutorRuntimeRunner,
    runtime_code: []const u8,
    call_data: []const u8,
    options: ResolvedOptions,
) !RuntimeMeasurement {
    if (executor_runner) |runner| {
        return .{
            .elapsed_ns = try runner.timeRuntimeCall(call_data, options.gas_limit),
            .counters = .{},
        };
    }

    var run_host = CountingHost.init(allocator, options.host_profile);
    defer run_host.deinit();
    var run_host_iface = run_host.host();

    const elapsed_ns = try timeRuntimeCall(allocator, &run_host_iface, runtime_code, call_data, options.revision, options.gas_limit);
    try common.rejectNullHostTouches(options.host_profile, run_host.counters);

    return .{
        .elapsed_ns = elapsed_ns,
        .counters = run_host.counters,
    };
}

fn timeRuntimeCallForProtocol(
    comptime Protocol: type,
    allocator: std.mem.Allocator,
    host: *Host,
    runtime_code: []const u8,
    call_data: []const u8,
    revision: Protocol.Revision,
    gas_limit: u64,
) !u64 {
    const msg = Host.Message{
        .depth = 0,
        .kind = .call,
        .gas = @intCast(gas_limit),
        .recipient = common.contract_address,
        .sender = common.caller_address,
        .input_data = call_data,
        .value = 0,
        .code_address = common.contract_address,
    };

    var bytecode = try evmz.Bytecode.init(allocator, runtime_code);
    defer bytecode.deinit(allocator);

    var frame = try Interpreter.OwnedCallFrame(Protocol).init(allocator, .{
        .host = host,
        .msg = &msg,
        .bytecode = &bytecode,
        .revision = revision,
    });
    errdefer frame.deinit();
    var interpreter = frame.interpreter();

    const start_ns = try common.monotonicNowNs();
    const result = try interpreter.execute();
    const end_ns = try common.monotonicNowNs();
    frame.deinit();

    if (result.status != .success) return error.CallFailed;
    return end_ns - start_ns;
}

test "engine parser accepts aliases" {
    try std.testing.expectEqual(Engine.evmz, parseEngine("evmz").?);
    try std.testing.expectEqual(Engine.evmz_executor, parseEngine("evmz-executor").?);
    try std.testing.expect(parseEngine("evmone") == null);
    try std.testing.expect(parseEngine("evmone-baseline") == null);
    try std.testing.expect(parseEngine("evmz-call-total") == null);
    try std.testing.expect(parseEngine("evmz-advanced") == null);
    try std.testing.expect(parseEngine("evmz-advanced-executor") == null);
    try std.testing.expectEqual(ExecutorResources.growable, parseExecutorResources("growable").?);
    try std.testing.expectEqual(ExecutorResources.bounded, parseExecutorResources("bounded").?);
    try std.testing.expectEqual(ExecutorResources.bounded_frames, parseExecutorResources("bounded-frames").?);
    try std.testing.expectEqual(ExecutorResources.bounded_frame_memory, parseExecutorResources("bounded-frame-memory").?);
    try std.testing.expectEqual(ExecutorResources.bounded_overlay, parseExecutorResources("bounded-overlay").?);
    try std.testing.expectEqual(ExecutorResources.bounded_state_small, parseExecutorResources("bounded-state-small").?);
    try std.testing.expectEqual(ExecutorResources.bounded_small, parseExecutorResources("bounded-small").?);
}

test "compiled support range accepts default latest spec" {
    try std.testing.expect(BenchExecutionProtocol.support.contains(.latest));
}

test "build support spec parser accepts latest and hyphen aliases" {
    try std.testing.expectEqual(evmz.eth.Revision.latest, parseBuildSpec("latest"));
    try std.testing.expectEqual(evmz.eth.Revision.tangerine_whistle, parseBuildSpec("tangerine-whistle"));
}

test "engine scope names make benchmark boundary explicit" {
    try std.testing.expectEqualStrings("interpreter-prepared-execute", measureScopeName(.{
        .fixture_dir = null,
        .contract_code_path = "x",
        .call_data_hex = "",
        .num_runs = 1,
        .warmup_ms = 0,
        .gas_limit = defaultGasLimit(),
        .revision = .latest,
        .engine = .evmz,
        .executor_resources = .growable,
        .host_profile = .null,
        .summary = false,
    }));
    try std.testing.expectEqualStrings("executor-prepared-call-growable", measureScopeName(.{
        .fixture_dir = null,
        .contract_code_path = "x",
        .call_data_hex = "",
        .num_runs = 1,
        .warmup_ms = 0,
        .gas_limit = defaultGasLimit(),
        .revision = .latest,
        .engine = .evmz_executor,
        .executor_resources = .growable,
        .host_profile = .null,
        .summary = false,
    }));
    try std.testing.expectEqualStrings("executor-prepared-call-bounded", measureScopeName(.{
        .fixture_dir = null,
        .contract_code_path = "x",
        .call_data_hex = "",
        .num_runs = 1,
        .warmup_ms = 0,
        .gas_limit = defaultGasLimit(),
        .revision = .latest,
        .engine = .evmz_executor,
        .executor_resources = .bounded,
        .host_profile = .null,
        .summary = false,
    }));
}

test "deploys runtime and runs empty bytecode under null host" {
    const init_code = [_]u8{ 0x60, 0x01, 0x60, 0x0c, 0x60, 0x00, 0x39, 0x60, 0x01, 0x60, 0x00, 0xf3, 0x00 };

    var deploy_host = CountingHost.init(std.testing.allocator, .null);
    defer deploy_host.deinit();
    var deploy_host_iface = deploy_host.host();
    const runtime = try deployRuntime(std.testing.allocator, &deploy_host_iface, &init_code, .latest);
    defer std.testing.allocator.free(runtime);

    try std.testing.expectEqualSlices(u8, &.{0x00}, runtime);

    var run_host = CountingHost.init(std.testing.allocator, .null);
    defer run_host.deinit();
    var run_host_iface = run_host.host();
    _ = try timeRuntimeCall(std.testing.allocator, &run_host_iface, runtime, &.{}, .latest, defaultGasLimit());
    try std.testing.expectEqual(@as(u64, 0), run_host.counters.total());

    var executor_runner = try ExecutorRuntimeRunner.init(std.testing.allocator, runtime, null, .latest, .growable);
    defer executor_runner.deinit();
    _ = try executor_runner.timeRuntimeCall(&.{}, defaultGasLimit());
}

test "resolves fixture defaults with CLI overrides" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const resolved = try resolveOptions(std.testing.io, arena.allocator(), .{
        .fixture_dir = "fixtures/vm-loop/ten-thousand-hashes",
        .num_runs = 2,
    });

    try std.testing.expectEqualSlices(u8, "fixtures/vm-loop/ten-thousand-hashes/init.hex", resolved.contract_code_path);
    try std.testing.expectEqualSlices(u8, "30627b7c", trimFixtureText(resolved.call_data_hex));
    try std.testing.expectEqual(@as(usize, 2), resolved.num_runs);
    try std.testing.expectEqual(@as(usize, default_warmup_ms), resolved.warmup_ms);
    try std.testing.expectEqual(defaultGasLimit(), resolved.gas_limit);
    try std.testing.expectEqual(HostProfile.null, resolved.host_profile);
}

test "resolves explicit zero warmup for cold diagnostics" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const resolved = try resolveOptions(std.testing.io, arena.allocator(), .{
        .fixture_dir = "fixtures/vm-loop/arithmetic-loop",
        .warmup_ms = 0,
    });

    try std.testing.expectEqual(@as(usize, 0), resolved.warmup_ms);
}

test "proxy target is executor-only" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    try std.testing.expectError(error.ProxyTargetRequiresExecutorEngine, resolveOptions(std.testing.io, arena.allocator(), .{
        .fixture_dir = "fixtures/vm-loop/ten-thousand-hashes",
        .proxy_target_code_path = "fixtures/vm-loop/erc20-transfer/init.hex",
    }));
}
