const std = @import("std");
const evmz = @import("evmz");
const common = @import("common.zig");

const Host = evmz.Host;
const Interpreter = evmz.Interpreter;
const evmc = evmz.c_api.evmc;
const evmc_common = evmz.c_api.common;
const host2c = evmz.c_api.host2c;

pub const default_iterations = 100_000;

pub const Operation = enum {
    host_storage_read,
    host_storage_write,
    host_access_storage,
    host_account_exists,
    host_balance,
    host_code_size,
    host_code_hash,
    host_copy_code,
    host_tx_context,
    host_call,
    host_log,
    bytecode_sload,
    bytecode_sstore,
};

pub const Boundary = enum {
    zig,
    evmc,
};

const Options = struct {
    op: Operation = .host_storage_read,
    boundary: Boundary = .zig,
    iterations: usize = default_iterations,
    revision: evmz.eth.Revision = .latest,
    summary: bool = false,
};

pub const Measurement = struct {
    elapsed_ns: u64,
    counters: common.HostCounters,
    boundary: []const u8,
};

pub const RunOptions = struct {
    op: Operation,
    boundary: Boundary,
    iterations: usize,
    revision: evmz.eth.Revision,
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

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
        } else if (std.mem.eql(u8, arg, "--op")) {
            const value = args.next() orelse return error.MissingOp;
            options.op = parseOperation(value) orelse return error.InvalidOp;
        } else if (common.stripPrefix(arg, "--op=")) |value| {
            options.op = parseOperation(value) orelse return error.InvalidOp;
        } else if (std.mem.eql(u8, arg, "--boundary")) {
            const value = args.next() orelse return error.MissingBoundary;
            options.boundary = parseBoundary(value) orelse return error.InvalidBoundary;
        } else if (common.stripPrefix(arg, "--boundary=")) |value| {
            options.boundary = parseBoundary(value) orelse return error.InvalidBoundary;
        } else if (std.mem.eql(u8, arg, "--iterations") or std.mem.eql(u8, arg, "-n")) {
            const value = args.next() orelse return error.MissingIterations;
            options.iterations = try common.parseNonZeroUsize(value);
        } else if (common.stripPrefix(arg, "--iterations=")) |value| {
            options.iterations = try common.parseNonZeroUsize(value);
        } else if (std.mem.eql(u8, arg, "--spec")) {
            const value = args.next() orelse return error.MissingSpec;
            options.revision = common.parseSpec(value) orelse return error.InvalidSpec;
        } else if (common.stripPrefix(arg, "--spec=")) |value| {
            options.revision = common.parseSpec(value) orelse return error.InvalidSpec;
        } else if (std.mem.eql(u8, arg, "--summary")) {
            options.summary = true;
        } else {
            return error.UnknownArgument;
        }
    }

    const measurement = try run(allocator, .{
        .op = options.op,
        .boundary = options.boundary,
        .iterations = options.iterations,
        .revision = options.revision,
    });

    try printMeasurement(stdout, options.op, options.iterations, measurement);
    try stdout.flush();

    if (options.summary) {
        measurement.counters.print("host");
    }
}

pub fn run(allocator: std.mem.Allocator, options: RunOptions) !Measurement {
    return switch (options.op) {
        .host_storage_read,
        .host_storage_write,
        .host_access_storage,
        .host_account_exists,
        .host_balance,
        .host_code_size,
        .host_code_hash,
        .host_copy_code,
        .host_tx_context,
        .host_call,
        .host_log,
        => try runDirectHostOp(allocator, options.op, options.boundary, options.iterations),
        .bytecode_sload,
        .bytecode_sstore,
        => blk: {
            if (options.boundary != .zig) return error.InvalidBoundaryForBytecodeOp;
            break :blk try runBytecodeHostOp(allocator, options.op, options.iterations, options.revision);
        },
    };
}

pub fn printMeasurement(
    stdout: anytype,
    op: Operation,
    iterations: usize,
    measurement: Measurement,
) !void {
    const ns_per_op = @as(f64, @floatFromInt(measurement.elapsed_ns)) /
        @as(f64, @floatFromInt(iterations));
    try stdout.print(
        "op={s} boundary={s} iterations={d} elapsed_ns={d} ns_per_op={d:.3} host_calls={d}\n",
        .{
            @tagName(op),
            measurement.boundary,
            iterations,
            measurement.elapsed_ns,
            ns_per_op,
            measurement.counters.total(),
        },
    );
}

fn printUsage() void {
    std.debug.print(
        \\Usage:
        \\  zig build host-boundary -- --op <operation> --iterations <n>
        \\
        \\Operations:
        \\  host-storage-read       direct Zig Host.getStorage loop
        \\  host-storage-write      direct Zig Host.setStorage loop
        \\  host-access-storage     direct Zig Host.accessStorage loop
        \\  host-account-exists     direct Zig Host.accountExists loop
        \\  host-balance            direct Zig Host.getBalance loop
        \\  host-code-size          direct Zig Host.getCodeSize loop
        \\  host-code-hash          direct Zig Host.getCodeHash loop
        \\  host-copy-code          direct Zig Host.copyCode loop
        \\  host-tx-context         direct Zig Host.getTxContext loop
        \\  host-call               direct Zig Host.call loop
        \\  host-log                direct Zig Host.emitLog loop
        \\  bytecode-sload          interpreter loop with repeated SLOAD
        \\  bytecode-sstore         interpreter loop with repeated SSTORE
        \\
        \\Options:
        \\  --boundary <zig|evmc>   direct host boundary, default zig
        \\  --iterations, -n <n>    operation count, default 100000
        \\  --spec <name>           fork spec for bytecode operations, default latest
        \\  --summary               print per-callback counters to stderr
        \\
    , .{});
}

fn runDirectHostOp(
    allocator: std.mem.Allocator,
    op: Operation,
    boundary: Boundary,
    iterations: usize,
) !Measurement {
    return switch (boundary) {
        .zig => try runZigHostOp(allocator, op, iterations),
        .evmc => try runEvmcHostOp(allocator, op, iterations),
    };
}

fn runZigHostOp(allocator: std.mem.Allocator, op: Operation, iterations: usize) !Measurement {
    var counting_host = common.CountingHost.init(allocator, .mock);
    defer counting_host.deinit();
    try counting_host.seedStorage(common.contract_address, 0, 1);
    var host = makeHost(&counting_host);
    var code_buffer: [32]u8 = undefined;
    var msg = Host.Message{
        .depth = 1,
        .kind = .call,
        .gas = common.max_gas,
        .recipient = common.contract_address,
        .sender = common.caller_address,
        .input_data = &.{},
        .value = 0,
        .code_address = common.contract_address,
    };

    counting_host.resetCounters();
    const start_ns = try common.monotonicNowNs();
    var i: usize = 0;
    while (i < iterations) : (i += 1) {
        switch (op) {
            .host_storage_read => std.mem.doNotOptimizeAway(host.getStorage(common.contract_address, 0)),
            .host_storage_write => std.mem.doNotOptimizeAway(try host.setStorage(common.contract_address, 0, 1)),
            .host_access_storage => std.mem.doNotOptimizeAway(try host.accessStorage(common.contract_address, 0)),
            .host_account_exists => std.mem.doNotOptimizeAway(try host.accountExists(common.contract_address)),
            .host_balance => std.mem.doNotOptimizeAway(try host.getBalance(common.contract_address)),
            .host_code_size => std.mem.doNotOptimizeAway(try host.getCodeSize(common.contract_address)),
            .host_code_hash => std.mem.doNotOptimizeAway(try host.getCodeHash(common.contract_address)),
            .host_copy_code => std.mem.doNotOptimizeAway(try host.copyCode(common.contract_address, 0, &code_buffer)),
            .host_tx_context => std.mem.doNotOptimizeAway(try host.getTxContext()),
            .host_call => {
                msg.gas = common.max_gas - @as(i64, @intCast(i & 0xff));
                std.mem.doNotOptimizeAway(try host.call(msg));
            },
            .host_log => std.mem.doNotOptimizeAway(try host.emitLog(.{
                .address = common.contract_address,
                .topics = &.{},
                .data = &.{},
            })),
            .bytecode_sload, .bytecode_sstore => unreachable,
        }
    }
    const end_ns = try common.monotonicNowNs();

    return .{
        .elapsed_ns = end_ns - start_ns,
        .counters = counting_host.counters,
        .boundary = "zig-host-vtable",
    };
}

fn runEvmcHostOp(allocator: std.mem.Allocator, op: Operation, iterations: usize) !Measurement {
    var counting_host = common.CountingHost.init(allocator, .mock);
    defer counting_host.deinit();
    try counting_host.seedStorage(common.contract_address, 0, 1);
    var host = makeHost(&counting_host);
    var bridge = host2c.HostContext.borrowed(&host);
    const context = bridge.toContext();
    const interface = makeEvmcInterface();
    var code_buffer: [32]u8 = undefined;
    const address = evmc_common.toEvmcAddress(common.contract_address);
    const sender = evmc_common.toEvmcAddress(common.caller_address);
    const key = evmc_common.toEvmcBytes32(0);
    const value = evmc_common.toEvmcBytes32(1);
    var log_data = [_]u8{0};
    var log_topics = [_]evmc.evmc_bytes32{evmc_common.toEvmcBytes32(0)};
    var msg = evmc.evmc_message{
        .kind = @intFromEnum(Host.CallKind.call),
        .flags = 0,
        .depth = 1,
        .gas = common.max_gas,
        .recipient = address,
        .sender = sender,
        .input_data = null,
        .input_size = 0,
        .value = evmc_common.toEvmcBytes32(0),
        .create2_salt = evmc_common.toEvmcBytes32(0),
        .code_address = address,
    };

    counting_host.resetCounters();
    const start_ns = try common.monotonicNowNs();
    var i: usize = 0;
    while (i < iterations) : (i += 1) {
        switch (op) {
            .host_storage_read => std.mem.doNotOptimizeAway(interface.get_storage.?(context, &address, &key)),
            .host_storage_write => std.mem.doNotOptimizeAway(interface.set_storage.?(context, &address, &key, &value)),
            .host_access_storage => std.mem.doNotOptimizeAway(interface.access_storage.?(context, &address, &key)),
            .host_account_exists => std.mem.doNotOptimizeAway(interface.account_exists.?(context, &address)),
            .host_balance => std.mem.doNotOptimizeAway(interface.get_balance.?(context, &address)),
            .host_code_size => std.mem.doNotOptimizeAway(interface.get_code_size.?(context, &address)),
            .host_code_hash => std.mem.doNotOptimizeAway(interface.get_code_hash.?(context, &address)),
            .host_copy_code => std.mem.doNotOptimizeAway(interface.copy_code.?(context, &address, 0, &code_buffer, code_buffer.len)),
            .host_tx_context => std.mem.doNotOptimizeAway(interface.get_tx_context.?(context)),
            .host_call => {
                msg.gas = common.max_gas - @as(i64, @intCast(i & 0xff));
                var result = interface.call.?(context, &msg);
                deferResult(&result);
                std.mem.doNotOptimizeAway(result);
            },
            .host_log => {
                interface.emit_log.?(context, &address, &log_data, 0, &log_topics, 0);
            },
            .bytecode_sload, .bytecode_sstore => unreachable,
        }
    }
    const end_ns = try common.monotonicNowNs();

    return .{
        .elapsed_ns = end_ns - start_ns,
        .counters = counting_host.counters,
        .boundary = "evmc-host-to-zig",
    };
}

noinline fn makeHost(counting_host: *common.CountingHost) Host {
    return counting_host.host();
}

noinline fn makeEvmcInterface() evmc.evmc_host_interface {
    return host2c.getInterface();
}

fn deferResult(result: *const evmc.evmc_result) void {
    if (result.release) |release| release(result);
}

fn runBytecodeHostOp(
    allocator: std.mem.Allocator,
    op: Operation,
    iterations: usize,
    revision: evmz.eth.Revision,
) !Measurement {
    const bytecode = try storageBytecode(allocator, op, iterations);
    defer allocator.free(bytecode);

    var counting_host = common.CountingHost.init(allocator, .mock);
    defer counting_host.deinit();
    try counting_host.seedStorage(common.contract_address, 0, 1);
    var host = counting_host.host();

    const msg = Host.Message{
        .depth = 0,
        .kind = .call,
        .gas = common.max_gas,
        .recipient = common.contract_address,
        .sender = common.caller_address,
        .input_data = &.{},
        .value = 0,
        .code_address = common.contract_address,
    };

    var frame = try Interpreter.OwnedCallFrame(evmz.EthProtocol).init(allocator, .{
        .host = &host,
        .msg = &msg,
        .code = bytecode,
        .revision = revision,
    });
    errdefer frame.deinit();
    var interpreter = frame.interpreter();

    counting_host.resetCounters();
    const start_ns = try common.monotonicNowNs();
    const result = try interpreter.execute();
    const end_ns = try common.monotonicNowNs();
    frame.deinit();

    if (result.status != .success) return error.BytecodeFailed;
    return .{
        .elapsed_ns = end_ns - start_ns,
        .counters = counting_host.counters,
        .boundary = "evmz-interpreter-zig-host",
    };
}

fn storageBytecode(allocator: std.mem.Allocator, op: Operation, iterations: usize) ![]u8 {
    const pattern = switch (op) {
        .bytecode_sload => &[_]u8{ 0x60, 0x00, 0x54, 0x50 },
        .bytecode_sstore => &[_]u8{ 0x60, 0x01, 0x60, 0x00, 0x55 },
        else => return error.InvalidBytecodeOperation,
    };
    const code = try allocator.alloc(u8, pattern.len * iterations + 1);
    var offset: usize = 0;
    var i: usize = 0;
    while (i < iterations) : (i += 1) {
        @memcpy(code[offset..][0..pattern.len], pattern);
        offset += pattern.len;
    }
    code[offset] = 0x00;
    return code;
}

pub fn parseOperation(value: []const u8) ?Operation {
    inline for (std.meta.fields(Operation)) |field| {
        if (tagNameMatches(value, field.name)) return @enumFromInt(field.value);
    }
    return null;
}

pub fn parseBoundary(value: []const u8) ?Boundary {
    inline for (std.meta.fields(Boundary)) |field| {
        if (std.mem.eql(u8, value, field.name)) return @enumFromInt(field.value);
    }
    return null;
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

pub fn isBytecodeOperation(op: Operation) bool {
    return switch (op) {
        .bytecode_sload, .bytecode_sstore => true,
        else => false,
    };
}

test "operation parser accepts dashed names" {
    try std.testing.expectEqual(Operation.host_storage_read, parseOperation("host-storage-read").?);
    try std.testing.expectEqual(Operation.host_log, parseOperation("host-log").?);
    try std.testing.expectEqual(Operation.bytecode_sstore, parseOperation("bytecode-sstore").?);
}

test "boundary parser accepts evmc" {
    try std.testing.expectEqual(Boundary.evmc, parseBoundary("evmc").?);
}

test "storage bytecode generation repeats operation and stops" {
    const code = try storageBytecode(std.testing.allocator, .bytecode_sload, 2);
    defer std.testing.allocator.free(code);
    try std.testing.expectEqualSlices(u8, &.{ 0x60, 0x00, 0x54, 0x50, 0x60, 0x00, 0x54, 0x50, 0x00 }, code);
}

test "evmc direct boundary increments host counters" {
    const measurement = try runDirectHostOp(std.testing.allocator, .host_storage_read, .evmc, 3);
    try std.testing.expectEqual(@as(u64, 3), measurement.counters.storage_read);
}
