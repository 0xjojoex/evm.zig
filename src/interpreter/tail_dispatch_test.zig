const std = @import("std");
const evmz = @import("../evm.zig");
const Interpreter = @import("../Interpreter.zig");
const Opcode = @import("../opcode.zig").Opcode;
const ExactSpec = @import("../spec.zig").Spec;
const Stack = @import("../Stack.zig");
const instruction = @import("../instruction.zig");
const trace = @import("../trace.zig");

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

test "prepared tail dispatch executes promoted modular and fork arithmetic" {
    try evmz.t.expectLatestForkBytecodeStackTop(.{
        .PUSH1, 5, .PUSH1, 4, .PUSH1, 3, .ADDMOD,
    }, 2);
    try evmz.t.expectLatestForkBytecodeStackTop(.{
        .PUSH1, 5, .PUSH1, 4, .PUSH1, 3, .MULMOD,
    }, 2);
    try evmz.t.expectLatestForkBytecodeStackTop(.{
        .PUSH1, 0x80, .PUSH0, .SIGNEXTEND,
    }, std.math.maxInt(u256) - 0x7f);
    try evmz.t.expectBytecodeStackTopByRevision(.{ .PUSH1, 1, .CLZ }, .osaka, 255);
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
        .{ .opcode = .ADDRESS, .expected = recipient.toU256() },
        .{ .opcode = .CALLER, .expected = sender.toU256() },
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

test "prepared tail dispatch reads execution-context values" {
    const origin = evmz.addr(0x1001);
    const coinbase = evmz.addr(0x1002);
    const execution_context: evmz.execution.ExecutionContext = .{
        .chain = .{ .chain_id = 41 },
        .block = .{
            .coinbase = coinbase,
            .number = 42,
            .slot_number = 43,
            .timestamp = 44,
            .gas_limit = 45,
            .difficulty_or_prev_randao = 46,
            .base_fee = 47,
            .blob_base_fee = 48,
        },
        .transaction = .{ .origin = origin, .gas_price = 49 },
    };
    const cases = [_]struct {
        opcode: Opcode,
        expected: u256,
    }{
        .{ .opcode = .ORIGIN, .expected = origin.toU256() },
        .{ .opcode = .GASPRICE, .expected = 49 },
        .{ .opcode = .BASEFEE, .expected = 47 },
        .{ .opcode = .COINBASE, .expected = coinbase.toU256() },
        .{ .opcode = .TIMESTAMP, .expected = 44 },
        .{ .opcode = .NUMBER, .expected = 42 },
        .{ .opcode = .SLOTNUM, .expected = 43 },
        .{ .opcode = .PREVRANDAO, .expected = 46 },
        .{ .opcode = .GASLIMIT, .expected = 45 },
        .{ .opcode = .CHAINID, .expected = 41 },
        .{ .opcode = .BLOBBASEFEE, .expected = 48 },
    };

    for (cases) |case| {
        const code = [_]u8{ @intFromEnum(case.opcode), @intFromEnum(Opcode.STOP) };
        var bytecode = try evmz.Bytecode.init(std.testing.allocator, &code);
        defer bytecode.deinit(std.testing.allocator);

        var mock_host = evmz.t.MockHost.init(std.testing.allocator, execution_context);
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
        try std.testing.expectEqual(case.expected, interpreter.call_frame.stack.peek().?);
    }
}

test "prepared tail dispatch reads host account values" {
    const target = evmz.addr(0x1234);
    var target_code = [_]u8{0xaa} ** 1024;
    const cases = [_]struct {
        opcode: Opcode,
        expected: u256,
        takes_address: bool,
    }{
        .{ .opcode = .BALANCE, .expected = 51, .takes_address = true },
        .{ .opcode = .EXTCODESIZE, .expected = target_code.len, .takes_address = true },
        .{ .opcode = .EXTCODEHASH, .expected = evmz.uint256.fromBytes32(&evmz.crypto.keccak256(&target_code)), .takes_address = true },
        .{ .opcode = .SELFBALANCE, .expected = 51, .takes_address = false },
    };

    for (cases) |case| {
        const code = [_]u8{ @intFromEnum(case.opcode), @intFromEnum(Opcode.STOP) };
        var bytecode = try evmz.Bytecode.init(std.testing.allocator, &code);
        defer bytecode.deinit(std.testing.allocator);

        var mock_host = evmz.t.MockHost.init(std.testing.allocator, null);
        defer mock_host.deinit();
        try mock_host.local_account.put(target, .{ .balance = 51 });
        try mock_host.code.put(target, &target_code);
        var host = mock_host.host();
        var msg = evmz.t.defaultMessage();
        msg.recipient = target;
        var frame = try evmz.Evm.Interpreter.OwnedCallFrame.init(std.testing.allocator, .{
            .host = &host,
            .msg = &msg,
            .source = .{ .bytecode = bytecode.view() },
        });
        defer frame.deinit();
        if (case.takes_address) frame.frame.stack.push(target.toU256());
        var interpreter = frame.interpreter();

        const result = try interpreter.execute();

        try std.testing.expectEqual(Interpreter.Status.success, result.status());
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

test "prepared tail dispatch uses exact instruction availability" {
    if (comptime !evmz.t.forkEnabled(.frontier)) return error.SkipZigTest;
    try expectOpcodeHalt(evmz.eth.frontier, .BASEFEE, .invalid_opcode);
}

test "prepared tail dispatch uses resolved dispatch target for hot opcodes" {
    const spec = instructionOverrideSpec(.ADD, .invalid);

    var mock_host = evmz.t.MockHost.init(std.testing.allocator, null);
    defer mock_host.deinit();
    var host = mock_host.host();
    var msg = evmz.t.defaultMessage();
    const code = [_]u8{@intFromEnum(Opcode.ADD)};

    var frame = try Interpreter.Interpreter(spec).OwnedCallFrame.init(std.testing.allocator, .{
        .host = &host,
        .msg = &msg,
        .source = .{ .code = &code },
    });
    defer frame.deinit();

    frame.frame.stack.push(2);
    frame.frame.stack.push(3);
    try executeFrame(spec, frame.frame);
    try std.testing.expectEqual(Interpreter.FrameHalt.invalid_opcode, frame.frame.haltReason().?);
}

test "untraced interpreter tail dispatch respects resolved dispatch target" {
    const spec = instructionOverrideSpec(.ADD, .invalid);

    var mock_host = evmz.t.MockHost.init(std.testing.allocator, null);
    defer mock_host.deinit();
    var host = mock_host.host();
    var msg = evmz.t.defaultMessage();
    const code = [_]u8{
        @intFromEnum(Opcode.PUSH1),
        2,
        @intFromEnum(Opcode.PUSH1),
        3,
        @intFromEnum(Opcode.ADD),
    };
    var bytecode = try evmz.Bytecode.init(std.testing.allocator, &code);
    defer bytecode.deinit(std.testing.allocator);

    var frame = try Interpreter.Interpreter(spec).OwnedCallFrame.init(std.testing.allocator, .{
        .host = &host,
        .msg = &msg,
        .source = .{ .bytecode = bytecode.view() },
    });
    defer frame.deinit();
    var intpr = frame.interpreter();

    const result = try intpr.execute();

    try std.testing.expectEqual(Interpreter.Status.invalid, result.status());
}

test "untraced interpreter tail dispatch rejects invalid and undefined bytes" {
    inline for (.{ @intFromEnum(Opcode.INVALID), 0x0c }) |opcode_byte| {
        var mock_host = evmz.t.MockHost.init(std.testing.allocator, null);
        defer mock_host.deinit();
        var host = mock_host.host();
        var msg = evmz.t.defaultMessage();
        const code = [_]u8{opcode_byte};
        var bytecode = try evmz.Bytecode.init(std.testing.allocator, &code);
        defer bytecode.deinit(std.testing.allocator);

        var frame = try Interpreter.Interpreter(evmz.eth.amsterdam).OwnedCallFrame.init(std.testing.allocator, .{
            .host = &host,
            .msg = &msg,
            .source = .{ .bytecode = bytecode.view() },
        });
        defer frame.deinit();
        var intpr = frame.interpreter();

        const result = try intpr.execute();

        try std.testing.expectEqual(Interpreter.Status.invalid, result.status());
        try std.testing.expectEqual(@as(i64, 0), frame.frame.gas_left);
    }
}

test "builtin enforces the final derived stack minimum" {
    const spec = comptime spec: {
        var exact = evmz.eth.amsterdam.instruction;
        exact.table[@intFromEnum(Opcode.ADD)].info.stack_in = 3;
        break :spec evmz.eth.amsterdam.extend(.{ .instruction = exact });
    };

    var mock_host = evmz.t.MockHost.init(std.testing.allocator, null);
    defer mock_host.deinit();
    var host = mock_host.host();
    var msg = evmz.t.defaultMessage();
    const code = evmz.t.bytecode(.{ .PUSH1, 7, .PUSH1, 2, .ADD, .STOP });
    var bytecode = try evmz.Bytecode.init(std.testing.allocator, &code);
    defer bytecode.deinit(std.testing.allocator);

    var frame = try Interpreter.Interpreter(spec).OwnedCallFrame.init(std.testing.allocator, .{
        .host = &host,
        .msg = &msg,
        .source = .{ .bytecode = bytecode.view() },
    });
    defer frame.deinit();
    var intpr = frame.interpreter();

    _ = try intpr.execute();

    try std.testing.expectEqual(Interpreter.FrameHalt.stack_underflow, frame.frame.haltReason().?);
}

test "specialized builtins use final gas and stack metadata in normal and captured execution" {
    const spec = specializedMetadataSpec();
    inline for (.{
        Opcode.STOP,
        Opcode.PUSH1,
        Opcode.ADDRESS,
        Opcode.RETURN,
        Opcode.SSTORE,
        Opcode.JUMPDEST,
    }) |opcode| {
        inline for (.{ false, true }) |captured| {
            try expectSpecializedAdmission(spec, opcode, 6, false, captured, .out_of_gas, .out_of_gas);
            try expectSpecializedAdmission(spec, opcode, 7, false, captured, .invalid, .stack_underflow);
        }
    }
}

test "SSTORE admission faults before host storage callbacks" {
    const spec = specializedMetadataSpec();
    inline for (.{ false, true }) |captured| {
        try expectSpecializedAdmission(spec, .SSTORE, 6, true, captured, .out_of_gas, .out_of_gas);
        try expectSpecializedAdmission(spec, .SSTORE, 7, true, captured, .invalid, .write_protection);
    }
}

test "custom target receives and charges the final derived spec" {
    const custom_gas = 7;
    const CustomHandler = struct {
        var called = false;
        var saw_derived_spec = false;

        pub inline fn execute(comptime exact: ExactSpec, frame: *Interpreter.CallFrame) anyerror!void {
            called = true;
            saw_derived_spec = exact.instruction.entry(@intFromEnum(Opcode.ADD)).info.static_gas == custom_gas;
            _ = frame.push(42);
        }
    };
    const base_spec = comptime spec: {
        var exact = evmz.eth.amsterdam.instruction;
        const entry = &exact.table[@intFromEnum(Opcode.ADD)];
        entry.info.stack_in = 0;
        entry.target = .{ .custom = CustomHandler };
        break :spec evmz.eth.amsterdam.extend(.{ .instruction = exact });
    };
    const spec = comptime spec: {
        var exact = base_spec.instruction;
        exact.table[@intFromEnum(Opcode.ADD)].info.static_gas = custom_gas;
        break :spec base_spec.extend(.{ .instruction = exact });
    };

    var mock_host = evmz.t.MockHost.init(std.testing.allocator, null);
    defer mock_host.deinit();
    var host = mock_host.host();
    var msg = evmz.t.defaultMessage();
    const code = evmz.t.bytecode(.{ .ADD, .STOP });
    var bytecode = try evmz.Bytecode.init(std.testing.allocator, &code);
    defer bytecode.deinit(std.testing.allocator);

    var frame = try Interpreter.Interpreter(spec).OwnedCallFrame.init(std.testing.allocator, .{
        .host = &host,
        .msg = &msg,
        .source = .{ .bytecode = bytecode.view() },
    });
    defer frame.deinit();
    var intpr = frame.interpreter();

    const result = try intpr.execute();

    try std.testing.expectEqual(Interpreter.Status.success, result.status());
    try std.testing.expect(CustomHandler.called);
    try std.testing.expect(CustomHandler.saw_derived_spec);
    try std.testing.expectEqual(@as(u256, 42), frame.frame.stack.pop());
    try std.testing.expectEqual(msg.gas - custom_gas, frame.frame.gas_left);

    CustomHandler.called = false;
    msg.gas = custom_gas - 1;
    var out_of_gas_frame = try Interpreter.Interpreter(spec).OwnedCallFrame.init(std.testing.allocator, .{
        .host = &host,
        .msg = &msg,
        .source = .{ .bytecode = bytecode.view() },
    });
    defer out_of_gas_frame.deinit();
    var out_of_gas_interpreter = out_of_gas_frame.interpreter();

    const out_of_gas = try out_of_gas_interpreter.execute();

    try std.testing.expectEqual(Interpreter.Status.out_of_gas, out_of_gas.status());
    try std.testing.expect(!CustomHandler.called);
}

test "custom target enforces the final derived stack minimum" {
    const CustomHandler = struct {
        var called = false;

        pub inline fn execute(comptime _: ExactSpec, _: *Interpreter.CallFrame) anyerror!void {
            called = true;
        }
    };
    const base_spec = comptime spec: {
        var exact = evmz.eth.amsterdam.instruction;
        const entry = &exact.table[@intFromEnum(Opcode.ADD)];
        entry.info.stack_in = 0;
        entry.target = .{ .custom = CustomHandler };
        break :spec evmz.eth.amsterdam.extend(.{ .instruction = exact });
    };
    const spec = comptime spec: {
        var exact = base_spec.instruction;
        exact.table[@intFromEnum(Opcode.ADD)].info.stack_in = 1;
        break :spec base_spec.extend(.{ .instruction = exact });
    };

    var mock_host = evmz.t.MockHost.init(std.testing.allocator, null);
    defer mock_host.deinit();
    var host = mock_host.host();
    var msg = evmz.t.defaultMessage();
    const code = evmz.t.bytecode(.{ .ADD, .STOP });
    var bytecode = try evmz.Bytecode.init(std.testing.allocator, &code);
    defer bytecode.deinit(std.testing.allocator);

    var frame = try Interpreter.Interpreter(spec).OwnedCallFrame.init(std.testing.allocator, .{
        .host = &host,
        .msg = &msg,
        .source = .{ .bytecode = bytecode.view() },
    });
    defer frame.deinit();
    var intpr = frame.interpreter();

    _ = try intpr.execute();

    try std.testing.expectEqual(Interpreter.FrameHalt.stack_underflow, frame.frame.haltReason().?);
    try std.testing.expect(!CustomHandler.called);
}

test "captured custom MSTORE handler retains inherited trace effects" {
    const CustomMstore = struct {
        pub inline fn execute(comptime _: ExactSpec, frame: *Interpreter.CallFrame) anyerror!void {
            const offset, const value = frame.popN(2) orelse return;
            const offset_usize = frame.memoryOffsetToUsizeOrOog(offset, 32) orelse return;
            if (!try frame.expandMemory(offset_usize, 32)) return;
            frame.memory.write(offset_usize, value);
        }
    };
    const spec = instructionOverrideSpec(.MSTORE, .{ .custom = CustomMstore });
    const code = evmz.t.bytecode(.{ .PUSH1, 0x2a, .PUSH0, .MSTORE, .STOP });

    var mock_host = evmz.t.MockHost.init(std.testing.allocator, null);
    defer mock_host.deinit();
    var host = mock_host.host();
    var msg = evmz.t.defaultMessage();
    msg.gas = 100;
    var frame = try Interpreter.Interpreter(spec).OwnedCallFrame.init(std.testing.allocator, .{
        .host = &host,
        .msg = &msg,
        .source = .{ .code = &code },
    });
    defer frame.deinit();
    var intpr = frame.interpreter();
    var tape = trace.TraceTape.initGrowable(std.testing.allocator);
    defer tape.deinit();

    const captured = try intpr.capture(&tape, .{ .memory = .writes });
    defer tape.resolve(captured.span) catch unreachable;
    try std.testing.expectEqual(Interpreter.Status.success, captured.result.status());

    var cursor = trace.TraceCursor.init(captured.span);
    cursor.enterFrame(captured.span.frames[0]);
    const writes = for (captured.span.steps) |row| {
        cursor.finishStep(row);
        if (row.opcode == @intFromEnum(Opcode.MSTORE)) break try cursor.memoryWrites();
    } else unreachable;
    try std.testing.expectEqual(@as(usize, 1), writes.len);
    const bytes = cursor.memoryWriteBytes(writes[0]);
    try std.testing.expectEqual(@as(usize, 32), bytes.len);
    try std.testing.expectEqual(@as(u8, 0x2a), bytes[31]);
}

fn instructionOverrideSpec(
    comptime opcode: Opcode,
    comptime target: instruction.Target,
) evmz.eth.Spec {
    var exact = evmz.eth.amsterdam.instruction;
    exact.table[@intFromEnum(opcode)].target = target;
    return evmz.eth.amsterdam.extend(.{
        .instruction = exact,
    });
}

fn specializedMetadataSpec() evmz.eth.Spec {
    @setEvalBranchQuota(100_000);
    var exact = evmz.eth.amsterdam.instruction;
    inline for (.{
        .{ Opcode.STOP, 1 },
        .{ Opcode.PUSH1, 1 },
        .{ Opcode.ADDRESS, 1 },
        .{ Opcode.RETURN, 3 },
        .{ Opcode.SSTORE, 3 },
        .{ Opcode.JUMPDEST, 1 },
    }) |entry| {
        const info = &exact.table[@intFromEnum(entry[0])].info;
        info.static_gas = 7;
        info.stack_in = entry[1];
    }
    return evmz.eth.amsterdam.extend(.{ .instruction = exact });
}

fn expectSpecializedAdmission(
    comptime spec: evmz.eth.Spec,
    comptime opcode: Opcode,
    gas: i64,
    is_static: bool,
    comptime captured: bool,
    expected_status: Interpreter.Status,
    expected_halt: Interpreter.FrameHalt,
) !void {
    var mock_host = evmz.t.MockHost.init(std.testing.allocator, null);
    defer mock_host.deinit();
    var host = mock_host.host();
    var msg = evmz.t.defaultMessage();
    msg.gas = gas;
    msg.is_static = is_static;
    const code = [_]u8{@intFromEnum(opcode)};
    var frame = try Interpreter.Interpreter(spec).OwnedCallFrame.init(std.testing.allocator, .{
        .host = &host,
        .msg = &msg,
        .source = .{ .code = &code },
    });
    defer frame.deinit();
    var intpr = frame.interpreter();

    const status = if (captured) status: {
        var tape = trace.TraceTape.initGrowable(std.testing.allocator);
        defer tape.deinit();
        const result = try intpr.capture(&tape, .{});
        defer tape.resolve(result.span) catch unreachable;
        break :status result.result.status();
    } else (try intpr.execute()).status();

    try std.testing.expectEqual(expected_status, status);
    try std.testing.expectEqual(expected_halt, frame.frame.haltReason().?);
    try std.testing.expectEqual(@as(u64, 0), mock_host.storage_stores);
}

fn expectOpcodeHalt(comptime spec: evmz.eth.Spec, opcode: Opcode, expected: Interpreter.FrameHalt) !void {
    var mock_host = evmz.t.MockHost.init(std.testing.allocator, null);
    defer mock_host.deinit();
    var host = mock_host.host();
    var msg = evmz.t.defaultMessage();
    const code = [_]u8{@intFromEnum(opcode)};

    var frame = try Interpreter.Interpreter(spec).OwnedCallFrame.init(std.testing.allocator, .{
        .host = &host,
        .msg = &msg,
        .source = .{ .code = &code },
    });
    defer frame.deinit();

    try executeFrame(spec, frame.frame);
    try std.testing.expectEqual(expected, frame.frame.haltReason().?);
}

test "instruction boundary resolves EVM faults without throwing" {
    const cases = [_]struct {
        opcode: u8,
        is_static: bool = false,
        expected: Interpreter.FrameHalt,
    }{
        .{ .opcode = @intFromEnum(Opcode.ADD), .expected = .stack_underflow },
        .{ .opcode = 0x0c, .expected = .invalid_opcode },
        .{ .opcode = @intFromEnum(Opcode.SSTORE), .is_static = true, .expected = .write_protection },
    };

    inline for (cases) |case| {
        var mock_host = evmz.t.MockHost.init(std.testing.allocator, null);
        defer mock_host.deinit();
        var host = mock_host.host();
        var msg = evmz.t.defaultMessage();
        msg.is_static = case.is_static;
        const code = [_]u8{case.opcode};

        var frame = try Interpreter.Interpreter(evmz.eth.cancun).OwnedCallFrame.init(std.testing.allocator, .{
            .host = &host,
            .msg = &msg,
            .source = .{ .code = &code },
        });
        defer frame.deinit();

        try executeFrame(evmz.eth.cancun, frame.frame);
        try std.testing.expectEqual(case.expected, frame.frame.haltReason().?);
    }

    var mock_host = evmz.t.MockHost.init(std.testing.allocator, null);
    defer mock_host.deinit();
    var host = mock_host.host();
    var msg = evmz.t.defaultMessage();
    const code = [_]u8{@intFromEnum(Opcode.PUSH0)};
    var frame = try Interpreter.Interpreter(evmz.eth.cancun).OwnedCallFrame.init(std.testing.allocator, .{
        .host = &host,
        .msg = &msg,
        .source = .{ .code = &code },
    });
    defer frame.deinit();
    for (0..Stack.capacity) |_| frame.frame.stack.push(0);

    try executeFrame(evmz.eth.cancun, frame.frame);
    try std.testing.expectEqual(Interpreter.FrameHalt.stack_overflow, frame.frame.haltReason().?);
}

fn executeFrame(comptime spec: ExactSpec, frame: *Interpreter.CallFrame) !void {
    var intpr = Interpreter.Interpreter(spec).init(frame);
    _ = try intpr.execute();
}
