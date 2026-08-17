const std = @import("std");
const evmz = @import("../../evm.zig");

test "DIV and SDIV with one operand fail as invalid instructions" {
    try evmz.t.expectLatestForkBytecodeStatus(.{ .PUSH1, 0x01, .DIV }, .invalid);
    try evmz.t.expectLatestForkBytecodeStatus(.{ .PUSH1, 0x01, .SDIV }, .invalid);
}

test "DIV and SDIV by zero push zero" {
    try evmz.t.expectLatestForkBytecodeStackTop(.{ .PUSH0, .PUSH1, 0x02, .DIV }, 0);
    try evmz.t.expectLatestForkBytecodeStackTop(.{ .PUSH0, .PUSH1, 0x02, .SDIV }, 0);
}

test "KECCAK256 of empty input returns the empty hash" {
    try evmz.t.expectLatestForkBytecodeStackTop(.{ .PUSH0, .PUSH0, .KECCAK256 }, evmz.uint256.fromBytes32(&evmz.crypto.keccak256_empty));
}

test "EXP byte gas comes from the exact spec" {
    const exact = comptime exact: {
        var result = evmz.eth.spurious_dragon.instruction;
        result.exp_byte_gas = 1;
        break :exact result;
    };
    const Exact = evmz.t.CustomVm(.spurious_dragon, .{ .instruction = exact }) orelse return error.SkipZigTest;

    var mock_host = evmz.t.MockHost.init(std.testing.allocator, null);
    defer mock_host.deinit();
    var host = mock_host.host();
    var msg = evmz.t.defaultMessage();
    const code = [_]u8{@intFromEnum(evmz.Opcode.EXP)};

    var frame = try Exact.Interpreter.OwnedCallFrame.init(std.testing.allocator, .{
        .host = &host,
        .execution_context = &mock_host.execution_context,
        .msg = &msg,
        .source = .{ .code = &code },
    });
    defer frame.deinit();
    frame.frame.stack.push(0x0100);
    frame.frame.stack.push(2);

    var intpr = frame.interpreter();
    const result = try intpr.execute();

    try std.testing.expectEqual(evmz.Interpreter.Status.success, result.status());
    try std.testing.expectEqual(
        msg.gas - Exact.specification.instruction.entry(@intFromEnum(evmz.Opcode.EXP)).info.static_gas - 2,
        frame.frame.gas_left,
    );
    try std.testing.expectEqual(@as(u256, 0), frame.frame.stack.pop());
}
