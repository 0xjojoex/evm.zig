const std = @import("std");
const evmz = @import("../evm.zig");
const Interpreter = @import("../Interpreter.zig");
const Opcode = @import("../opcode.zig").Opcode;

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
            .source = .{ .bytecode = bytecode.view() },
        });
        defer frame.deinit();
        frame.frame.stack.push(case.below);
        frame.frame.stack.push(case.top);
        var interpreter = frame.interpreter();

        const result = try interpreter.execute();

        try std.testing.expectEqual(Interpreter.Status.success, result.status());
        try std.testing.expectEqual(@as(u16, 1), interpreter.call_frame.stack.len);
        try std.testing.expectEqual(case.expected, interpreter.call_frame.stack.peek().?);
    }
}

test "prepared tail dispatch executes promoted mcopy and exp" {
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
            .source = .{ .bytecode = bytecode.view() },
        });
        defer frame.deinit();
        var interpreter = frame.interpreter();

        const result = try interpreter.execute();

        try std.testing.expectEqual(Interpreter.Status.success, result.status());
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
    if (comptime !evmz.t.forkEnabled(revision)) return error.SkipZigTest;
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
        .source = .{ .bytecode = bytecode.view() },
    });
    defer frame.deinit();
    var interpreter = frame.interpreter();

    const result = try interpreter.execute();

    try std.testing.expectEqual(expected_status, result.status());
}

test "prepared tail dispatch rejects SAR before Constantinople" {
    const code = [_]u8{ @intFromEnum(Opcode.SAR), @intFromEnum(Opcode.STOP) };
    var bytecode = try evmz.Bytecode.init(std.testing.allocator, &code);
    defer bytecode.deinit(std.testing.allocator);

    var mock_host = evmz.t.MockHost.init(std.testing.allocator, null);
    defer mock_host.deinit();
    var host = mock_host.host();
    var msg = evmz.t.defaultMessage();
    const Byzantium = evmz.t.Vm(.byzantium) orelse return error.SkipZigTest;
    var frame = try Byzantium.Interpreter.OwnedCallFrame.init(std.testing.allocator, .{
        .host = &host,
        .msg = &msg,
        .source = .{ .bytecode = bytecode.view() },
    });
    defer frame.deinit();
    frame.frame.stack.push(1);
    frame.frame.stack.push(1);
    var interpreter = frame.interpreter();

    const result = try interpreter.execute();

    try std.testing.expectEqual(Interpreter.Status.invalid, result.status());
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
            .source = .{ .bytecode = bytecode.view() },
        });
        defer frame.deinit();
        try frame.frame.replaceReturnData(&returned);
        var interpreter = frame.interpreter();

        const result = try interpreter.execute();

        try std.testing.expectEqual(Interpreter.Status.success, result.status());
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
            .source = .{ .bytecode = bytecode.view() },
        });
        defer frame.deinit();
        try frame.frame.replaceReturnData(&returned);
        frame.frame.stack.push(case.size);
        frame.frame.stack.push(case.source_offset);
        frame.frame.stack.push(0);
        var interpreter = frame.interpreter();

        const result = try interpreter.execute();

        try std.testing.expectEqual(Interpreter.Status.success, result.status());
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
        .source = .{ .bytecode = bytecode.view() },
    });
    defer frame.deinit();
    try frame.frame.replaceReturnData(&.{ 1, 2 });
    frame.frame.stack.push(2);
    frame.frame.stack.push(1);
    frame.frame.stack.push(0);
    var interpreter = frame.interpreter();

    const result = try interpreter.execute();

    try std.testing.expectEqual(Interpreter.Status.invalid, result.status());
}

test "prepared tail dispatch halts once on unrepresentable memory operands" {
    // Tail helpers that halt the frame themselves must report `.done`. Reporting
    // `.out_of_gas` sends the outer dispatch loop through a second
    // `frame.halt(.out_of_gas)`, which `CallFrame.halt` rejects because the frame
    // is no longer running. Running these in a Debug build is the guard.
    const cases = [_]struct {
        name: []const u8,
        code: []const u8,
    }{
        // Operand wider than usize: wordToUsizeOrOog halts.
        .{ .name = "MSTORE offset", .code = &evmz.t.bytecode(.{ .PUSH1, 0x2a, .PUSH0, .NOT, .MSTORE }) },
        .{ .name = "MSTORE8 offset", .code = &evmz.t.bytecode(.{ .PUSH1, 0x2a, .PUSH0, .NOT, .MSTORE8 }) },
        .{ .name = "MLOAD offset", .code = &evmz.t.bytecode(.{ .PUSH0, .NOT, .MLOAD }) },
        .{ .name = "KECCAK256 size", .code = &evmz.t.bytecode(.{ .PUSH0, .NOT, .PUSH0, .KECCAK256 }) },
        // memoryOffsetToUsizeOrOog halts once the size is representable.
        .{ .name = "KECCAK256 offset", .code = &evmz.t.bytecode(.{ .PUSH1, 0x20, .PUSH0, .NOT, .KECCAK256 }) },
        .{ .name = "RETURN size", .code = &evmz.t.bytecode(.{ .PUSH0, .NOT, .PUSH0, .RETURN }) },
        // Representable offset whose end overflows: expandMemory halts, so
        // memoryFailureStatus must not claim the frame still needs halting.
        .{ .name = "MSTORE range end", .code = &evmz.t.bytecode(.{
            .PUSH1, 0x2a, .PUSH8, 0xff, 0xff, 0xff,
            0xff,   0xff, 0xff,   0xff, 0xff, .MSTORE,
        }) },
        .{ .name = "MLOAD range end", .code = &evmz.t.bytecode(.{
            .PUSH8, 0xff, 0xff, 0xff,   0xff, 0xff,
            0xff,   0xff, 0xff, .MLOAD,
        }) },
    };

    for (cases) |case| {
        errdefer std.debug.print("case: {s}\n", .{case.name});
        var bytecode = try evmz.Bytecode.init(std.testing.allocator, case.code);
        defer bytecode.deinit(std.testing.allocator);

        var mock_host = evmz.t.MockHost.init(std.testing.allocator, null);
        defer mock_host.deinit();
        var host = mock_host.host();
        var msg = evmz.t.defaultMessage();
        msg.gas = 100_000;
        var frame = try evmz.Evm.Interpreter.OwnedCallFrame.init(std.testing.allocator, .{
            .host = &host,
            .msg = &msg,
            .source = .{ .bytecode = bytecode.view() },
        });
        defer frame.deinit();
        var interpreter = frame.interpreter();

        const result = try interpreter.execute();

        try std.testing.expectEqual(Interpreter.Status.out_of_gas, result.status());
        try std.testing.expectEqual(evmz.execution.FrameHalt.out_of_gas, result.halt);
        try std.testing.expectEqual(@as(i64, 0), result.gas_left);
    }
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
            .source = .{ .bytecode = bytecode.view() },
        });
        defer frame.deinit();
        try frame.frame.memory.expandToFit(0, output.len);
        frame.frame.memory.writeBytes(0, &output);
        frame.frame.stack.push(output.len);
        frame.frame.stack.push(0);
        var interpreter = frame.interpreter();

        const result = try interpreter.execute();

        try std.testing.expectEqual(case.expected_status, result.status());
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
        const Homestead = evmz.t.Vm(.homestead) orelse return error.SkipZigTest;
        var frame = try Homestead.Interpreter.OwnedCallFrame.init(std.testing.allocator, .{
            .host = &host,
            .msg = &msg,
            .source = .{ .bytecode = bytecode.view() },
        });
        defer frame.deinit();
        var interpreter = frame.interpreter();

        const result = try interpreter.execute();

        try std.testing.expectEqual(Interpreter.Status.invalid, result.status());
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
        .source = .{ .bytecode = bytecode.view() },
    });
    defer frame.deinit();
    var interpreter = frame.interpreter();

    const result = try interpreter.execute();

    try std.testing.expectEqual(Interpreter.Status.success, result.status());
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
        .source = .{ .bytecode = bytecode.view() },
    });
    defer static_frame.deinit();
    var static_interpreter = static_frame.interpreter();

    const static_result = try static_interpreter.execute();

    try std.testing.expectEqual(Interpreter.Status.invalid, static_result.status());
    try std.testing.expectEqual(@as(usize, 0), static_host_state.logs.items.len);
}
