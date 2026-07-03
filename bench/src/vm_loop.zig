const std = @import("std");
const evmz = @import("evmz");
const common = @import("common.zig");

const Host = evmz.Host;
const Interpreter = evmz.Interpreter;
const Executor = evmz.executor;
const CountingHost = common.CountingHost;
const HostCounters = common.HostCounters;
const HostProfile = common.HostProfile;

const max_contract_code_size = 256 * 1024 * 1024;

const Options = struct {
    fixture_dir: ?[]const u8 = null,
    contract_code_path: ?[]const u8 = null,
    call_data_hex: ?[]const u8 = null,
    num_runs: ?usize = null,
    spec: evmz.Spec = .latest,
    engine: Engine = .evmz,
    host_profile: ?HostProfile = null,
    summary: bool = false,
};

const ResolvedOptions = struct {
    fixture_dir: ?[]const u8,
    contract_code_path: []const u8,
    call_data_hex: []const u8,
    num_runs: usize,
    spec: evmz.Spec,
    engine: Engine,
    host_profile: HostProfile,
    summary: bool,
};

const Engine = enum {
    evmz,
    evmz_executor,
};

const ExecutorRuntimeRunner = struct {
    allocator: std.mem.Allocator,
    executor: Executor,
    bytecode: evmz.Bytecode,
    baseline: Executor.Snapshot,

    fn init(
        allocator: std.mem.Allocator,
        runtime_code: []const u8,
        spec: evmz.Spec,
    ) !ExecutorRuntimeRunner {
        var executor = Executor.init(allocator, .{
            .spec = spec,
            .config = .base,
        });
        errdefer executor.deinit();

        const sender = try executor.getOrCreateAccount(common.caller_address);
        sender.balance = std.math.maxInt(u256);

        const contract = try executor.getOrCreateAccount(common.contract_address);
        try contract.setCode(allocator, runtime_code);

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

    fn timeRuntimeCall(self: *ExecutorRuntimeRunner, call_data: []const u8) !u64 {
        try self.executor.restore(&self.baseline);
        try self.executor.beginTransaction(executorTxContext(), common.caller_address, common.contract_address);

        var pre_execution = try self.executor.snapshot();
        defer pre_execution.deinit(self.allocator);

        const start_ns = try common.monotonicNowNs();
        const call_options = Executor.PreparedCallTransaction{
            .bytecode = &self.bytecode,
            .sender = common.caller_address,
            .recipient = common.contract_address,
            .input = call_data,
            .gas = @intCast(common.max_gas),
            .value = 0,
        };
        const result = try self.executor.executePreparedCallTransaction(call_options);
        const end_ns = try common.monotonicNowNs();

        if (Executor.executionRolledBack(result.status)) {
            try self.executor.restore(&pre_execution);
        } else {
            try self.executor.finalizeTransaction();
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
        } else if (std.mem.eql(u8, arg, "--spec")) {
            const value = args.next() orelse return error.MissingSpec;
            options.spec = common.parseSpec(value) orelse return error.InvalidSpec;
        } else if (common.stripPrefix(arg, "--spec=")) |value| {
            options.spec = common.parseSpec(value) orelse return error.InvalidSpec;
        } else if (std.mem.eql(u8, arg, "--engine")) {
            const value = args.next() orelse return error.MissingEngine;
            options.engine = parseEngine(value) orelse return error.InvalidEngine;
        } else if (common.stripPrefix(arg, "--engine=")) |value| {
            options.engine = parseEngine(value) orelse return error.InvalidEngine;
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

    const contract_code_hex = try std.Io.Dir.cwd().readFileAlloc(
        init.io,
        contract_code_path,
        allocator,
        .limited(max_contract_code_size * 2),
    );
    defer allocator.free(contract_code_hex);

    const contract_code = try common.decodeHexAlloc(allocator, contract_code_hex);
    defer allocator.free(contract_code);

    const call_data = try common.decodeHexAlloc(allocator, resolved.call_data_hex);
    defer allocator.free(call_data);

    var deploy_host = CountingHost.init(allocator, resolved.host_profile);
    defer deploy_host.deinit();
    var deploy_host_iface = deploy_host.host();
    const runtime_code = try deployRuntime(allocator, &deploy_host_iface, contract_code, resolved.spec, resolved.engine);
    defer allocator.free(runtime_code);
    try common.rejectNullHostTouches(resolved.host_profile, deploy_host.counters);

    var executor_runner: ?ExecutorRuntimeRunner = if (isExecutorEngine(resolved.engine))
        try ExecutorRuntimeRunner.init(allocator, runtime_code, resolved.spec)
    else
        null;
    defer {
        if (executor_runner) |*runner| runner.deinit();
    }

    var timed_counters = HostCounters{};
    var run_index: usize = 0;
    while (run_index < resolved.num_runs) : (run_index += 1) {
        var run_host = CountingHost.init(allocator, resolved.host_profile);
        defer run_host.deinit();
        var run_host_iface = run_host.host();

        const elapsed_ns = if (executor_runner) |*runner|
            try runner.timeRuntimeCall(call_data)
        else
            try timeRuntimeCall(allocator, &run_host_iface, runtime_code, call_data, resolved.spec, resolved.engine);
        try common.rejectNullHostTouches(resolved.host_profile, run_host.counters);
        timed_counters.add(run_host.counters);

        const elapsed_ms = @as(f64, @floatFromInt(elapsed_ns)) / @as(f64, @floatFromInt(std.time.ns_per_ms));
        try stdout.print("{d:.6}\n", .{elapsed_ms});
    }
    try stdout.flush();

    if (resolved.summary) {
        std.debug.print(
            "fixture={s} engine={s} scope={s} host_profile={s} spec={s} runtime_bytes={d} deploy_host_calls={d} timed_host_calls={d} logs={d}\n",
            .{
                resolved.fixture_dir orelse "",
                engineName(resolved.engine),
                measureScopeName(resolved.engine),
                @tagName(resolved.host_profile),
                @tagName(resolved.spec),
                runtime_code.len,
                deploy_host.counters.total(),
                timed_counters.total(),
                timed_counters.log,
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
        \\  --call-data <hex>             calldata hex for each runtime call
        \\  --num-runs, -n <n>            number of timed calls
        \\  --spec <name>                 fork spec, default latest
        \\  --engine <name>               evmz, evmz-executor
        \\  --host-profile <null|mock>    host boundary, default null
        \\  --summary                     print host callback counts to stderr
        \\  EVMZ_BENCH_ALLOCATOR=smp      opt into std.heap.smp_allocator for allocator probes
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
    var host_profile = options.host_profile;

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
        if (host_profile == null) {
            if (try readOptionalFixtureText(io, allocator, fixture_dir, "host-profile.txt")) |text| {
                host_profile = common.parseHostProfile(trimFixtureText(text)) orelse return error.InvalidHostProfile;
            }
        }
    }

    return .{
        .fixture_dir = options.fixture_dir,
        .contract_code_path = contract_code_path orelse return error.MissingContractCodePath,
        .call_data_hex = call_data_hex orelse "",
        .num_runs = num_runs orelse 1,
        .spec = options.spec,
        .engine = options.engine,
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

fn evmzConfig(engine: Engine) evmz.Config {
    return switch (engine) {
        .evmz, .evmz_executor => .base,
    };
}

fn measureScopeName(engine: Engine) []const u8 {
    return switch (engine) {
        .evmz => "interpreter-prepared-execute",
        .evmz_executor => "executor-prepared-call",
    };
}

fn executorTxContext() Host.TxContext {
    return .{
        .chain_id = 1,
        .gas_price = 0,
        .origin = common.caller_address,
        .coinbase = evmz.addr(0),
        .number = 0,
        .timestamp = 0,
        .gas_limit = @intCast(common.max_gas),
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

fn deployRuntime(
    allocator: std.mem.Allocator,
    host: *Host,
    contract_code: []const u8,
    spec: evmz.Spec,
    engine: Engine,
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

    var frame = try Interpreter.OwnedCallFrame.init(allocator, .{
        .host = host,
        .msg = &msg,
        .code = contract_code,
        .spec = spec,
        .config = evmzConfig(engine),
    });
    defer frame.deinit();
    var interpreter = frame.interpreter();

    const result = interpreter.execute();
    if (result.status != .success) return error.DeployFailed;
    return allocator.dupe(u8, result.output_data);
}

fn timeRuntimeCall(
    allocator: std.mem.Allocator,
    host: *Host,
    runtime_code: []const u8,
    call_data: []const u8,
    spec: evmz.Spec,
    engine: Engine,
) !u64 {
    const msg = Host.Message{
        .depth = 0,
        .kind = .call,
        .gas = common.max_gas,
        .recipient = common.contract_address,
        .sender = common.caller_address,
        .input_data = call_data,
        .value = 0,
        .code_address = common.contract_address,
    };

    var frame = try Interpreter.OwnedCallFrame.init(allocator, .{
        .host = host,
        .msg = &msg,
        .code = runtime_code,
        .spec = spec,
        .config = evmzConfig(engine),
    });
    errdefer frame.deinit();
    var interpreter = frame.interpreter();

    try prepareTimedMetadata(allocator, &interpreter, runtime_code, engine);

    const start_ns = try common.monotonicNowNs();
    const result = interpreter.execute();
    const end_ns = try common.monotonicNowNs();
    frame.deinit();

    if (result.status != .success) return error.CallFailed;
    return end_ns - start_ns;
}

fn prepareTimedMetadata(
    allocator: std.mem.Allocator,
    interpreter: *Interpreter,
    runtime_code: []const u8,
    engine: Engine,
) !void {
    return switch (engine) {
        .evmz => try interpreter.call_frame.analysis.jumpdests.analyze(allocator, runtime_code),

        .evmz_executor => unreachable,
    };
}

test "engine parser accepts aliases" {
    try std.testing.expectEqual(Engine.evmz, parseEngine("evmz").?);
    try std.testing.expectEqual(Engine.evmz_executor, parseEngine("evmz-executor").?);
    try std.testing.expect(parseEngine("evmone") == null);
    try std.testing.expect(parseEngine("evmone-baseline") == null);
    try std.testing.expect(parseEngine("evmz-call-total") == null);
    try std.testing.expect(parseEngine("evmz-advanced") == null);
    try std.testing.expect(parseEngine("evmz-advanced-executor") == null);
}

test "engine scope names make benchmark boundary explicit" {
    try std.testing.expectEqualStrings("interpreter-prepared-execute", measureScopeName(.evmz));
    try std.testing.expectEqualStrings("executor-prepared-call", measureScopeName(.evmz_executor));
}

test "deploys runtime and runs empty bytecode under null host" {
    const init_code = [_]u8{ 0x60, 0x01, 0x60, 0x0c, 0x60, 0x00, 0x39, 0x60, 0x01, 0x60, 0x00, 0xf3, 0x00 };

    var deploy_host = CountingHost.init(std.testing.allocator, .null);
    defer deploy_host.deinit();
    var deploy_host_iface = deploy_host.host();
    const runtime = try deployRuntime(std.testing.allocator, &deploy_host_iface, &init_code, .latest, .evmz);
    defer std.testing.allocator.free(runtime);

    try std.testing.expectEqualSlices(u8, &.{0x00}, runtime);

    var run_host = CountingHost.init(std.testing.allocator, .null);
    defer run_host.deinit();
    var run_host_iface = run_host.host();
    _ = try timeRuntimeCall(std.testing.allocator, &run_host_iface, runtime, &.{}, .latest, .evmz);
    try std.testing.expectEqual(@as(u64, 0), run_host.counters.total());

    var executor_runner = try ExecutorRuntimeRunner.init(std.testing.allocator, runtime, .latest);
    defer executor_runner.deinit();
    _ = try executor_runner.timeRuntimeCall(&.{});
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
    try std.testing.expectEqual(HostProfile.null, resolved.host_profile);
}
