const std = @import("std");
const evmz = @import("../../evm.zig");
const Interpreter = @import("../../Interpreter.zig");
const AccessStatus = evmz.execution.AccessStatus;
const StorageStatus = evmz.execution.StorageStatus;

const cold_sload_cost = evmz.eth.eip2929.cold_sload_cost;

test "transient storage opcodes are only enabled from Cancun" {
    try evmz.t.expectBytecodeStatusByRevision(.{ .PUSH1, 0x00, .TLOAD }, .shanghai, .invalid);
    try evmz.t.expectBytecodeStackTopByRevision(.{ .PUSH1, 0x00, .TLOAD }, .cancun, 1);

    try evmz.t.expectBytecodeStatusByRevision(.{ .PUSH1, 0x01, .PUSH1, 0x00, .TSTORE }, .shanghai, .invalid);
    try evmz.t.expectBytecodeStatusByRevision(.{ .PUSH1, 0x01, .PUSH1, 0x00, .TSTORE }, .cancun, .success);
}

test "SLOAD cold storage access gas comes from the exact spec" {
    if (comptime !evmz.t.forkEnabled(.frontier)) return error.SkipZigTest;
    const spec = evmz.eth.frontier.extend(.{
        .storage = .{ .sload_cold_access_gas = .{ .replace = 11 } },
    });

    var mock_host = evmz.t.MockHost.init(std.testing.allocator, null);
    defer mock_host.deinit();
    var host = mock_host.host();
    var msg = evmz.t.defaultMessage();
    const code = [_]u8{@intFromEnum(evmz.Opcode.SLOAD)};

    var frame = try Interpreter.Interpreter(spec).OwnedCallFrame.init(std.testing.allocator, .{
        .host = &host,
        .execution_context = &mock_host.execution_context,
        .msg = &msg,
        .source = .{ .code = &code },
    });
    defer frame.deinit();

    frame.frame.stack.push(0);
    var intpr = frame.interpreter();
    const result = try intpr.execute();

    try std.testing.expectEqual(Interpreter.Status.success, result.status());
    try std.testing.expectEqual(@as(i64, 99_939), frame.frame.gas_left);
    try std.testing.expectEqual(@as(u64, 1), mock_host.storage_loads);
    try std.testing.expectEqual(@as(u64, 0), mock_host.access_storage_reads);
    try std.testing.expectEqual(@as(u64, 0), mock_host.storage_reads);
    try std.testing.expectEqual(@as(u256, 0), frame.frame.stack.pop());
}

test "SSTORE gas and state gas come from the exact spec" {
    if (comptime !evmz.t.forkEnabled(.frontier)) return error.SkipZigTest;
    const semantics = struct {
        fn sstoreAccessGas(_: AccessStatus) ?i64 {
            return null;
        }

        fn sstoreGas(_: StorageStatus) evmz.execution.StorageGas {
            return .{ .cost = 7, .refund = 3 };
        }

        fn sstoreStateGas(_: StorageStatus) evmz.execution.StorageStateGas {
            return .{ .charge = 5 };
        }
    };
    const spec = evmz.eth.frontier.extend(.{
        .storage = .{
            .sstoreAccessGas = semantics.sstoreAccessGas,
            .sstoreGas = semantics.sstoreGas,
            .sstoreStateGas = semantics.sstoreStateGas,
        },
    });

    var mock_host = evmz.t.MockHost.init(std.testing.allocator, null);
    defer mock_host.deinit();
    var host = mock_host.host();
    var msg = evmz.t.defaultMessage();
    msg.gas_reservoir = 5;
    const code = [_]u8{@intFromEnum(evmz.Opcode.SSTORE)};

    var frame = try Interpreter.Interpreter(spec).OwnedCallFrame.init(std.testing.allocator, .{
        .host = &host,
        .execution_context = &mock_host.execution_context,
        .msg = &msg,
        .source = .{ .code = &code },
    });
    defer frame.deinit();

    frame.frame.stack.push(42);
    frame.frame.stack.push(0);
    var intpr = frame.interpreter();
    const result = try intpr.execute();

    try std.testing.expectEqual(Interpreter.Status.success, result.status());
    try std.testing.expectEqual(@as(i64, 99_993), frame.frame.gas_left);
    try std.testing.expectEqual(@as(i64, 0), frame.frame.gas_reservoir);
    try std.testing.expectEqual(@as(i64, 3), frame.frame.gas_refund);
    try std.testing.expectEqual(@as(i64, 5), frame.frame.state_gas_spent);
    try std.testing.expectEqual(@as(i64, 0), frame.frame.state_gas_from_gas_left);
    try std.testing.expectEqual(@as(u256, 42), mock_host.storageValue(0));
}

test "cold SSTORE charges full cold SLOAD cost from Berlin" {
    var mock_host = evmz.t.MockHost.init(std.testing.allocator, null);
    defer mock_host.deinit();
    var host = mock_host.host();
    const msg = evmz.t.defaultMessage();
    const code = &.{ 0x60, 0x2a, 0x60, 0x00, 0x55 };
    var bytecode = try evmz.Bytecode.init(std.testing.allocator, code);
    defer bytecode.deinit(std.testing.allocator);

    const Berlin = evmz.t.Vm(.berlin) orelse return error.SkipZigTest;
    var frame = try Berlin.Interpreter.OwnedCallFrame.init(std.testing.allocator, .{
        .host = &host,
        .execution_context = &mock_host.execution_context,
        .msg = &msg,
        .source = .{ .bytecode = bytecode.view() },
    });
    defer frame.deinit();
    var interpreter = frame.interpreter();

    const result = try interpreter.execute();
    try std.testing.expectEqual(evmz.Interpreter.Status.success, result.status());
    try std.testing.expectEqual(@as(i64, 100_000 - 3 - 3 - cold_sload_cost - 20_000), result.gas_left);
    try std.testing.expectEqual(@as(u64, 1), mock_host.storage_stores);
    try std.testing.expectEqual(@as(u64, 0), mock_host.access_storage_reads);
}

test "Amsterdam cold new SSTORE charges state gas from reservoir" {
    var mock_host = evmz.t.MockHost.init(std.testing.allocator, null);
    defer mock_host.deinit();
    var host = mock_host.host();
    var msg = evmz.t.defaultMessage();
    msg.gas_reservoir = @intCast(evmz.eth.eip8037.storage_set_state_gas);
    const code = &.{ 0x60, 0x2a, 0x60, 0x00, 0x55 };
    var bytecode = try evmz.Bytecode.init(std.testing.allocator, code);
    defer bytecode.deinit(std.testing.allocator);

    const Amsterdam = evmz.t.Vm(.amsterdam) orelse return error.SkipZigTest;
    var frame = try Amsterdam.Interpreter.OwnedCallFrame.init(std.testing.allocator, .{
        .host = &host,
        .execution_context = &mock_host.execution_context,
        .msg = &msg,
        .source = .{ .bytecode = bytecode.view() },
    });
    defer frame.deinit();
    var interpreter = frame.interpreter();

    const result = try interpreter.execute();
    try std.testing.expectEqual(evmz.Interpreter.Status.success, result.status());
    try std.testing.expectEqual(
        @as(i64, 100_000 - 3 - 3 - evmz.eth.eip8038.cold_storage_access_cost - evmz.eth.eip8038.storage_write_cost),
        result.gas_left,
    );
    try std.testing.expectEqual(@as(i64, 0), result.gas_reservoir);
    try std.testing.expectEqual(@as(i64, @intCast(evmz.eth.eip8037.storage_set_state_gas)), result.state_gas_spent);
    try std.testing.expectEqual(@as(i64, 0), result.state_gas_from_gas_left);
    try std.testing.expectEqual(@as(u64, 1), mock_host.storage_stores);
    try std.testing.expectEqual(@as(u64, 0), mock_host.access_storage_reads);
}

test "prepared cold Amsterdam SSTORE at stipend stops before storage access" {
    var mock_host = evmz.t.MockHost.init(std.testing.allocator, null);
    defer mock_host.deinit();
    var host = mock_host.host();
    var msg = evmz.t.defaultMessage();
    msg.gas = 3 + 3 + evmz.eth.gas.call_stipend;
    const code = &.{ 0x60, 0x2a, 0x60, 0x00, 0x55 };
    var bytecode = try evmz.Bytecode.init(std.testing.allocator, code);
    defer bytecode.deinit(std.testing.allocator);

    const Amsterdam = evmz.t.Vm(.amsterdam) orelse return error.SkipZigTest;
    var frame = try Amsterdam.Interpreter.OwnedCallFrame.init(std.testing.allocator, .{
        .host = &host,
        .execution_context = &mock_host.execution_context,
        .msg = &msg,
        .source = .{ .bytecode = bytecode.view() },
    });
    defer frame.deinit();
    var interpreter = frame.interpreter();

    const result = try interpreter.execute();
    try std.testing.expectEqual(evmz.Interpreter.Status.out_of_gas, result.status());
    try std.testing.expectEqual(@as(u64, 0), mock_host.access_storage_reads);
    try std.testing.expectEqual(@as(u64, 0), mock_host.storage_stores);
    try std.testing.expectEqual(@as(u256, 0), mock_host.storageValue(0));
}

test "prepared SSTORE rejects static context before host access" {
    var mock_host = evmz.t.MockHost.init(std.testing.allocator, null);
    defer mock_host.deinit();
    var host = mock_host.host();
    var msg = evmz.t.defaultMessage();
    msg.is_static = true;
    const code = &.{ 0x60, 0x2a, 0x60, 0x00, 0x55 };
    var bytecode = try evmz.Bytecode.init(std.testing.allocator, code);
    defer bytecode.deinit(std.testing.allocator);

    const Osaka = evmz.t.Vm(.osaka) orelse return error.SkipZigTest;
    var frame = try Osaka.Interpreter.OwnedCallFrame.init(std.testing.allocator, .{
        .host = &host,
        .execution_context = &mock_host.execution_context,
        .msg = &msg,
        .source = .{ .bytecode = bytecode.view() },
    });
    defer frame.deinit();
    var interpreter = frame.interpreter();

    const result = try interpreter.execute();
    try std.testing.expectEqual(evmz.Interpreter.Status.invalid, result.status());
    try std.testing.expectEqual(@as(u64, 0), mock_host.access_storage_reads);
    try std.testing.expectEqual(@as(u64, 0), mock_host.storage_stores);
    try std.testing.expectEqual(@as(u256, 0), mock_host.storageValue(0));
}

test "prepared cold SLOAD out of gas stops before storage read" {
    var mock_host = evmz.t.MockHost.init(std.testing.allocator, null);
    defer mock_host.deinit();
    var host = mock_host.host();
    var msg = evmz.t.defaultMessage();
    msg.gas = 3 + cold_sload_cost - 1;
    const code = &.{ 0x60, 0x00, 0x54 };
    var bytecode = try evmz.Bytecode.init(std.testing.allocator, code);
    defer bytecode.deinit(std.testing.allocator);

    const Berlin = evmz.t.Vm(.berlin) orelse return error.SkipZigTest;
    var frame = try Berlin.Interpreter.OwnedCallFrame.init(std.testing.allocator, .{
        .host = &host,
        .execution_context = &mock_host.execution_context,
        .msg = &msg,
        .source = .{ .bytecode = bytecode.view() },
    });
    defer frame.deinit();
    var interpreter = frame.interpreter();

    const result = try interpreter.execute();
    try std.testing.expectEqual(evmz.Interpreter.Status.out_of_gas, result.status());
    try std.testing.expectEqual(@as(u64, 1), mock_host.access_storage_reads);
    try std.testing.expectEqual(@as(u64, 0), mock_host.storage_reads);
    try std.testing.expectEqual(@as(u64, 0), mock_host.storage_loads);
}
