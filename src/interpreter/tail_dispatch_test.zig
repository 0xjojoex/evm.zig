const std = @import("std");
const evmz = @import("../evm.zig");
const Interpreter = @import("../Interpreter.zig");
const Opcode = @import("../opcode.zig").Opcode;

const Case = struct {
    opcode: Opcode,
    gas: i64 = 100_000,
    input_data: []const u8 = &.{},
    return_data: []const u8 = &.{},
    memory: []const u8 = &.{},
    stack: []const u256,
    is_static: bool = false,
    expected_status: Interpreter.Status,
};

test "copy, terminal, and log handlers match owned and borrowed preparation" {
    const huge = std.math.maxInt(u256);
    const cases = [_]Case{
        .{
            .opcode = .CALLDATACOPY,
            .input_data = &.{ 0xaa, 0xbb, 0xcc },
            .stack = &.{ 4, 1, 0 },
            .expected_status = .success,
        },
        .{
            .opcode = .CODECOPY,
            .stack = &.{ 4, 1, 31 },
            .expected_status = .success,
        },
        .{
            .opcode = .CALLDATACOPY,
            .stack = &.{ 0, huge, huge },
            .expected_status = .success,
        },
        .{
            .opcode = .RETURNDATACOPY,
            .return_data = &.{ 0x11, 0x22, 0x33 },
            .stack = &.{ 2, 1, 0 },
            .expected_status = .success,
        },
        .{
            .opcode = .RETURNDATACOPY,
            .return_data = &.{ 0x11, 0x22, 0x33 },
            .stack = &.{ 2, 2, 0 },
            .expected_status = .invalid,
        },
        .{
            .opcode = .CALLDATACOPY,
            .gas = 6,
            .stack = &.{ 32, 0, 0 },
            .expected_status = .out_of_gas,
        },
        .{
            .opcode = .RETURN,
            .memory = &.{ 0xaa, 0xbb, 0xcc },
            .stack = &.{ 3, 0 },
            .expected_status = .success,
        },
        .{
            .opcode = .REVERT,
            .memory = &.{ 0xaa, 0xbb, 0xcc },
            .stack = &.{ 2, 1 },
            .expected_status = .revert,
        },
        .{
            .opcode = .RETURN,
            .stack = &.{ 0, huge },
            .expected_status = .success,
        },
        .{
            .opcode = .RETURN,
            .gas = 2,
            .stack = &.{ 32, 0 },
            .expected_status = .out_of_gas,
        },
        .{
            .opcode = .LOG0,
            .memory = &([_]u8{0xaa} ** 32),
            .stack = &.{ 32, 0 },
            .expected_status = .success,
        },
        .{
            .opcode = .LOG4,
            .memory = &.{ 0xaa, 0xbb, 0xcc },
            .stack = &.{ 1, 2, 3, 4, 3, 0 },
            .expected_status = .success,
        },
        .{
            .opcode = .LOG0,
            .gas = 400,
            .stack = &.{ 32, 0 },
            .expected_status = .out_of_gas,
        },
        .{
            .opcode = .LOG4,
            .stack = &.{ 1, 2, 3, 4, 0, 0 },
            .is_static = true,
            .expected_status = .invalid,
        },
    };

    inline for (cases) |case| {
        try expectOwnedBorrowedEquivalent(case);
    }
}

fn expectOwnedBorrowedEquivalent(case: Case) !void {
    const code = [_]u8{ @intFromEnum(case.opcode), @intFromEnum(Opcode.STOP) };
    var bytecode = try evmz.Bytecode.init(std.testing.allocator, &code);
    defer bytecode.deinit(std.testing.allocator);

    var owned_host_state = evmz.t.MockHost.init(std.testing.allocator, null);
    defer owned_host_state.deinit();
    var owned_host = owned_host_state.host();
    var borrowed_host_state = evmz.t.MockHost.init(std.testing.allocator, null);
    defer borrowed_host_state.deinit();
    var borrowed_host = borrowed_host_state.host();

    var owned_msg = evmz.t.defaultMessage();
    owned_msg.gas = case.gas;
    owned_msg.input_data = case.input_data;
    owned_msg.is_static = case.is_static;
    var borrowed_msg = owned_msg;

    var owned_frame = try evmz.Evm.Interpreter.OwnedCallFrame.init(std.testing.allocator, .{
        .host = &owned_host,
        .msg = &owned_msg,
        .code = &code,
    });
    defer owned_frame.deinit();
    var borrowed_frame = try evmz.Evm.Interpreter.OwnedCallFrame.init(std.testing.allocator, .{
        .host = &borrowed_host,
        .msg = &borrowed_msg,
        .bytecode = &bytecode,
    });
    defer borrowed_frame.deinit();

    try seedFrame(owned_frame.frame, case);
    try seedFrame(borrowed_frame.frame, case);

    var owned_interpreter = owned_frame.interpreter();
    const owned_result = try owned_interpreter.execute();
    var borrowed_interpreter = borrowed_frame.interpreter();
    const borrowed_result = try borrowed_interpreter.execute();

    try std.testing.expectEqual(case.expected_status, owned_result.status);
    try std.testing.expectEqual(owned_result.status, borrowed_result.status);
    try std.testing.expectEqual(owned_result.terminalCause(), borrowed_result.terminalCause());
    try std.testing.expectEqual(owned_result.gas_left, borrowed_result.gas_left);
    try std.testing.expectEqual(owned_result.gas_refund, borrowed_result.gas_refund);
    try std.testing.expectEqual(owned_result.gas_reservoir, borrowed_result.gas_reservoir);
    try std.testing.expectEqual(owned_result.state_gas_spent, borrowed_result.state_gas_spent);
    try std.testing.expectEqual(owned_result.state_gas_from_gas_left, borrowed_result.state_gas_from_gas_left);
    try std.testing.expectEqualSlices(u8, owned_result.output_data, borrowed_result.output_data);

    const owned_call_frame = owned_interpreter.call_frame;
    const borrowed_call_frame = borrowed_interpreter.call_frame;
    try std.testing.expectEqual(owned_call_frame.stack.len, borrowed_call_frame.stack.len);
    try std.testing.expectEqualSlices(
        u256,
        owned_call_frame.stack.asSlice(),
        borrowed_call_frame.stack.asSlice(),
    );
    try std.testing.expectEqual(owned_call_frame.memory.len(), borrowed_call_frame.memory.len());
    try std.testing.expectEqualSlices(
        u8,
        owned_call_frame.memory.readBytes(0, owned_call_frame.memory.len()),
        borrowed_call_frame.memory.readBytes(0, borrowed_call_frame.memory.len()),
    );
    try expectLogsEqual(owned_host_state.logs.items, borrowed_host_state.logs.items);
}

fn seedFrame(frame: *Interpreter.CallFrame, case: Case) !void {
    try frame.replaceReturnData(case.return_data);
    if (case.memory.len != 0) {
        try frame.memory.expandToFit(0, case.memory.len);
        frame.memory.writeBytes(0, case.memory);
    }
    for (case.stack) |value| try frame.stack.push(value);
}

fn expectLogsEqual(expected: []const evmz.Host.Log, actual: []const evmz.Host.Log) !void {
    try std.testing.expectEqual(expected.len, actual.len);
    for (expected, actual) |expected_log, actual_log| {
        try std.testing.expectEqual(expected_log.address, actual_log.address);
        try std.testing.expectEqualSlices(u256, expected_log.topics, actual_log.topics);
        try std.testing.expectEqualSlices(u8, expected_log.data, actual_log.data);
    }
}

test "prepared tail dispatch executes promoted binary and shift opcodes" {
    const negative_one: u256 = @bitCast(@as(i256, -1));
    const negative_seven: u256 = @bitCast(@as(i256, -7));
    const negative_three: u256 = @bitCast(@as(i256, -3));
    const negative_four: u256 = @bitCast(@as(i256, -4));
    const cases = [_]struct {
        opcode: Opcode,
        below: u256,
        top: u256,
        expected: u256,
    }{
        .{ .opcode = .SDIV, .below = 2, .top = negative_seven, .expected = negative_three },
        .{ .opcode = .SLT, .below = 1, .top = negative_one, .expected = 1 },
        .{ .opcode = .SGT, .below = negative_one, .top = 1, .expected = 1 },
        .{ .opcode = .SMOD, .below = 3, .top = negative_seven, .expected = negative_one },
        .{ .opcode = .BYTE, .below = @as(u256, 0xab) << 248, .top = 0, .expected = 0xab },
        .{ .opcode = .SAR, .below = negative_seven, .top = 1, .expected = negative_four },
    };

    for (cases) |case| {
        const code = [_]u8{ @intFromEnum(case.opcode), @intFromEnum(Opcode.STOP) };
        var bytecode = try evmz.Bytecode.init(std.testing.allocator, &code);
        defer bytecode.deinit(std.testing.allocator);

        var mock_host = evmz.t.MockHost.init(std.testing.allocator, null);
        defer mock_host.deinit();
        var host = mock_host.host();
        var msg = evmz.t.defaultMessage();
        var frame = try evmz.Evm.Interpreter.OwnedCallFrame.init(std.testing.allocator, .{
            .host = &host,
            .msg = &msg,
            .bytecode = &bytecode,
        });
        defer frame.deinit();
        try frame.frame.stack.push(case.below);
        try frame.frame.stack.push(case.top);
        var interpreter = frame.interpreter();

        const result = try interpreter.execute();

        try std.testing.expectEqual(Interpreter.Status.success, result.status);
        try std.testing.expectEqual(@as(u16, 1), interpreter.call_frame.stack.len);
        try std.testing.expectEqual(case.expected, interpreter.call_frame.stack.peek().?);
    }
}

test "prepared tail dispatch executes promoted transient storage, mcopy, and exp" {
    // TSTORE then TLOAD; MockHost transient storage is canned (get always
    // returns 1), so this checks handler plumbing/gas, not value round-trip.
    const transient_code = evmz.t.bytecode(.{
        .PUSH1,  42,     .PUSH1, 7,
        .TSTORE, .PUSH1, 7,      .TLOAD,
    });
    // Store 0xaa..bb word at 0, MCOPY 2 bytes from offset 30 to 64, MLOAD 64.
    const mcopy_code = evmz.t.bytecode(.{
        .PUSH2, 0xaa,    0xbb,   .PUSH1,
        0x00,   .MSTORE, .PUSH1, 2,
        .PUSH1, 30,      .PUSH1, 64,
        .MCOPY, .PUSH1,  64,     .MLOAD,
    });
    const exp_code = evmz.t.bytecode(.{ .PUSH1, 5, .PUSH1, 3, .EXP });

    const cases = [_]struct {
        code: []const u8,
        expected: u256,
    }{
        .{ .code = &transient_code, .expected = 1 },
        .{ .code = &mcopy_code, .expected = @as(u256, 0xaabb) << 240 },
        .{ .code = &exp_code, .expected = 243 },
    };

    for (cases) |case| {
        var bytecode = try evmz.Bytecode.init(std.testing.allocator, case.code);
        defer bytecode.deinit(std.testing.allocator);

        var mock_host = evmz.t.MockHost.init(std.testing.allocator, null);
        defer mock_host.deinit();
        var host = mock_host.host();
        var msg = evmz.t.defaultMessage();
        var frame = try evmz.Evm.Interpreter.OwnedCallFrame.init(std.testing.allocator, .{
            .host = &host,
            .msg = &msg,
            .bytecode = &bytecode,
        });
        defer frame.deinit();
        var interpreter = frame.interpreter();

        const result = try interpreter.execute();

        try std.testing.expectEqual(Interpreter.Status.success, result.status);
        try std.testing.expectEqual(@as(u16, 1), interpreter.call_frame.stack.len);
        try std.testing.expectEqual(case.expected, interpreter.call_frame.stack.peek().?);
    }
}

test "prepared tail dispatch gates promoted Cancun opcodes and static TSTORE" {
    const tstore_code = evmz.t.bytecode(.{ .PUSH1, 1, .PUSH1, 0, .TSTORE });
    const mcopy_code = evmz.t.bytecode(.{ .PUSH0, .PUSH0, .PUSH0, .MCOPY });
    try expectPreparedStatus(&tstore_code, .shanghai, false, .invalid);
    try expectPreparedStatus(&tstore_code, .cancun, true, .invalid);
    try expectPreparedStatus(&tstore_code, .cancun, false, .success);
    try expectPreparedStatus(&mcopy_code, .shanghai, false, .invalid);
    try expectPreparedStatus(&mcopy_code, .cancun, false, .success);
}

fn expectPreparedStatus(
    code: []const u8,
    comptime revision: evmz.eth.Revision,
    is_static: bool,
    expected_status: Interpreter.Status,
) !void {
    var bytecode = try evmz.Bytecode.init(std.testing.allocator, code);
    defer bytecode.deinit(std.testing.allocator);

    var mock_host = evmz.t.MockHost.init(std.testing.allocator, null);
    defer mock_host.deinit();
    var host = mock_host.host();
    var msg = evmz.t.defaultMessage();
    msg.is_static = is_static;
    const Exact = evmz.Vm(evmz.eth.specAt(revision));
    var frame = try Exact.Interpreter.OwnedCallFrame.init(std.testing.allocator, .{
        .host = &host,
        .msg = &msg,
        .bytecode = &bytecode,
    });
    defer frame.deinit();
    var interpreter = frame.interpreter();

    const result = try interpreter.execute();

    try std.testing.expectEqual(expected_status, result.status);
}

test "prepared tail dispatch rejects SAR before Constantinople" {
    const code = [_]u8{ @intFromEnum(Opcode.SAR), @intFromEnum(Opcode.STOP) };
    var bytecode = try evmz.Bytecode.init(std.testing.allocator, &code);
    defer bytecode.deinit(std.testing.allocator);

    var mock_host = evmz.t.MockHost.init(std.testing.allocator, null);
    defer mock_host.deinit();
    var host = mock_host.host();
    var msg = evmz.t.defaultMessage();
    const Byzantium = evmz.Vm(evmz.eth.byzantium);
    var frame = try Byzantium.Interpreter.OwnedCallFrame.init(std.testing.allocator, .{
        .host = &host,
        .msg = &msg,
        .bytecode = &bytecode,
    });
    defer frame.deinit();
    try frame.frame.stack.push(1);
    try frame.frame.stack.push(1);
    var interpreter = frame.interpreter();

    const result = try interpreter.execute();

    try std.testing.expectEqual(Interpreter.Status.invalid, result.status);
}

test "prepared tail dispatch reads frame-local values" {
    const input = [_]u8{ 1, 2, 3 };
    const returned = [_]u8{ 4, 5, 6, 7 };
    const recipient = evmz.addr(0x1234);
    const sender = evmz.addr(0x5678);
    const cases = [_]struct {
        opcode: Opcode,
        expected: u256,
    }{
        .{ .opcode = .ADDRESS, .expected = evmz.address.toU256(recipient) },
        .{ .opcode = .CALLER, .expected = evmz.address.toU256(sender) },
        .{ .opcode = .CALLVALUE, .expected = 42 },
        .{ .opcode = .CALLDATASIZE, .expected = input.len },
        .{ .opcode = .CODESIZE, .expected = 2 },
        .{ .opcode = .RETURNDATASIZE, .expected = returned.len },
    };

    for (cases) |case| {
        const code = [_]u8{ @intFromEnum(case.opcode), @intFromEnum(Opcode.STOP) };
        var bytecode = try evmz.Bytecode.init(std.testing.allocator, &code);
        defer bytecode.deinit(std.testing.allocator);

        var mock_host = evmz.t.MockHost.init(std.testing.allocator, null);
        defer mock_host.deinit();
        var host = mock_host.host();
        var msg = evmz.t.defaultMessage();
        msg.recipient = recipient;
        msg.sender = sender;
        msg.value = 42;
        msg.input_data = &input;
        var frame = try evmz.Evm.Interpreter.OwnedCallFrame.init(std.testing.allocator, .{
            .host = &host,
            .msg = &msg,
            .bytecode = &bytecode,
        });
        defer frame.deinit();
        try frame.frame.replaceReturnData(&returned);
        var interpreter = frame.interpreter();

        const result = try interpreter.execute();

        try std.testing.expectEqual(Interpreter.Status.success, result.status);
        try std.testing.expectEqual(@as(u16, 1), interpreter.call_frame.stack.len);
        try std.testing.expectEqual(case.expected, interpreter.call_frame.stack.peek().?);
    }
}

test "prepared tail dispatch copies frame-local byte slices" {
    const input = [_]u8{ 0xaa, 0xbb, 0xcc };
    const returned = [_]u8{ 0x11, 0x22, 0x33 };
    const cases = [_]struct {
        opcode: Opcode,
        source_offset: u256,
        size: u256,
        expected: []const u8,
    }{
        .{ .opcode = .CALLDATACOPY, .source_offset = 1, .size = 4, .expected = &.{ 0xbb, 0xcc, 0, 0 } },
        .{ .opcode = .CODECOPY, .source_offset = 0, .size = 2, .expected = &.{ @intFromEnum(Opcode.CODECOPY), @intFromEnum(Opcode.STOP) } },
        .{ .opcode = .RETURNDATACOPY, .source_offset = 1, .size = 2, .expected = &.{ 0x22, 0x33 } },
    };

    for (cases) |case| {
        const code = [_]u8{ @intFromEnum(case.opcode), @intFromEnum(Opcode.STOP) };
        var bytecode = try evmz.Bytecode.init(std.testing.allocator, &code);
        defer bytecode.deinit(std.testing.allocator);

        var mock_host = evmz.t.MockHost.init(std.testing.allocator, null);
        defer mock_host.deinit();
        var host = mock_host.host();
        var msg = evmz.t.defaultMessage();
        msg.input_data = &input;
        var frame = try evmz.Evm.Interpreter.OwnedCallFrame.init(std.testing.allocator, .{
            .host = &host,
            .msg = &msg,
            .bytecode = &bytecode,
        });
        defer frame.deinit();
        try frame.frame.replaceReturnData(&returned);
        try frame.frame.stack.push(case.size);
        try frame.frame.stack.push(case.source_offset);
        try frame.frame.stack.push(0);
        var interpreter = frame.interpreter();

        const result = try interpreter.execute();

        try std.testing.expectEqual(Interpreter.Status.success, result.status);
        try std.testing.expectEqualSlices(u8, case.expected, interpreter.call_frame.memory.readBytes(0, case.expected.len));
    }
}

test "prepared tail dispatch rejects out-of-bounds RETURNDATACOPY" {
    const code = [_]u8{ @intFromEnum(Opcode.RETURNDATACOPY), @intFromEnum(Opcode.STOP) };
    var bytecode = try evmz.Bytecode.init(std.testing.allocator, &code);
    defer bytecode.deinit(std.testing.allocator);

    var mock_host = evmz.t.MockHost.init(std.testing.allocator, null);
    defer mock_host.deinit();
    var host = mock_host.host();
    var msg = evmz.t.defaultMessage();
    var frame = try evmz.Evm.Interpreter.OwnedCallFrame.init(std.testing.allocator, .{
        .host = &host,
        .msg = &msg,
        .bytecode = &bytecode,
    });
    defer frame.deinit();
    try frame.frame.replaceReturnData(&.{ 1, 2 });
    try frame.frame.stack.push(2);
    try frame.frame.stack.push(1);
    try frame.frame.stack.push(0);
    var interpreter = frame.interpreter();

    const result = try interpreter.execute();

    try std.testing.expectEqual(Interpreter.Status.invalid, result.status);
}

test "prepared tail dispatch returns and reverts frame-local output" {
    const output = [_]u8{ 0xaa, 0xbb, 0xcc };
    const cases = [_]struct {
        opcode: Opcode,
        expected_status: Interpreter.Status,
    }{
        .{ .opcode = .RETURN, .expected_status = .success },
        .{ .opcode = .REVERT, .expected_status = .revert },
    };

    for (cases) |case| {
        const code = [_]u8{@intFromEnum(case.opcode)};
        var bytecode = try evmz.Bytecode.init(std.testing.allocator, &code);
        defer bytecode.deinit(std.testing.allocator);

        var mock_host = evmz.t.MockHost.init(std.testing.allocator, null);
        defer mock_host.deinit();
        var host = mock_host.host();
        var msg = evmz.t.defaultMessage();
        var frame = try evmz.Evm.Interpreter.OwnedCallFrame.init(std.testing.allocator, .{
            .host = &host,
            .msg = &msg,
            .bytecode = &bytecode,
        });
        defer frame.deinit();
        try frame.frame.memory.expandToFit(0, output.len);
        frame.frame.memory.writeBytes(0, &output);
        try frame.frame.stack.push(output.len);
        try frame.frame.stack.push(0);
        var interpreter = frame.interpreter();

        const result = try interpreter.execute();

        try std.testing.expectEqual(case.expected_status, result.status);
        try std.testing.expectEqualSlices(u8, &output, result.output_data);
    }
}

test "prepared tail dispatch rejects Byzantium opcodes before activation" {
    const opcodes = [_]Opcode{ .RETURNDATASIZE, .RETURNDATACOPY, .REVERT };
    for (opcodes) |opcode| {
        const code = [_]u8{ @intFromEnum(opcode), @intFromEnum(Opcode.STOP) };
        var bytecode = try evmz.Bytecode.init(std.testing.allocator, &code);
        defer bytecode.deinit(std.testing.allocator);

        var mock_host = evmz.t.MockHost.init(std.testing.allocator, null);
        defer mock_host.deinit();
        var host = mock_host.host();
        var msg = evmz.t.defaultMessage();
        const Homestead = evmz.Vm(evmz.eth.homestead);
        var frame = try Homestead.Interpreter.OwnedCallFrame.init(std.testing.allocator, .{
            .host = &host,
            .msg = &msg,
            .bytecode = &bytecode,
        });
        defer frame.deinit();
        var interpreter = frame.interpreter();

        const result = try interpreter.execute();

        try std.testing.expectEqual(Interpreter.Status.invalid, result.status);
    }
}

test "prepared tail dispatch emits LOG4 data and rejects static context" {
    const code = [_]u8{
        @intFromEnum(Opcode.PUSH1), 1,
        @intFromEnum(Opcode.PUSH1), 2,
        @intFromEnum(Opcode.PUSH1), 3,
        @intFromEnum(Opcode.PUSH1), 4,
        @intFromEnum(Opcode.PUSH1), 32,
        @intFromEnum(Opcode.PUSH0), @intFromEnum(Opcode.LOG4),
    };
    var bytecode = try evmz.Bytecode.init(std.testing.allocator, &code);
    defer bytecode.deinit(std.testing.allocator);

    var mock_host = evmz.t.MockHost.init(std.testing.allocator, null);
    defer mock_host.deinit();
    var host = mock_host.host();
    var msg = evmz.t.defaultMessage();

    var frame = try evmz.Evm.Interpreter.OwnedCallFrame.init(std.testing.allocator, .{
        .host = &host,
        .msg = &msg,
        .bytecode = &bytecode,
    });
    defer frame.deinit();
    var interpreter = frame.interpreter();

    const result = try interpreter.execute();

    try std.testing.expectEqual(Interpreter.Status.success, result.status);
    try std.testing.expectEqual(@as(usize, 1), mock_host.logs.items.len);
    const event_log = mock_host.logs.items[0];
    try std.testing.expectEqualSlices(u256, &.{ 4, 3, 2, 1 }, event_log.topics);
    try std.testing.expectEqualSlices(u8, &([_]u8{0} ** 32), event_log.data);

    var static_host_state = evmz.t.MockHost.init(std.testing.allocator, null);
    defer static_host_state.deinit();
    var static_host = static_host_state.host();
    var static_msg = evmz.t.defaultMessage();
    static_msg.is_static = true;

    var static_frame = try evmz.Evm.Interpreter.OwnedCallFrame.init(std.testing.allocator, .{
        .host = &static_host,
        .msg = &static_msg,
        .bytecode = &bytecode,
    });
    defer static_frame.deinit();
    var static_interpreter = static_frame.interpreter();

    const static_result = try static_interpreter.execute();

    try std.testing.expectEqual(Interpreter.Status.invalid, static_result.status);
    try std.testing.expectEqual(@as(usize, 0), static_host_state.logs.items.len);
}
