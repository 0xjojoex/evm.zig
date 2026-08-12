const std = @import("std");
const evmz = @import("../evm.zig");

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

pub inline fn wrapExp(a: u256, expo: u256) u256 {
    if (expo == 0) return 1;
    if (a == 0) return 0;
    if (a == 1) return 1;
    if (a == 2) {
        if (expo >= 256) return 0;
        return std.math.shl(u256, 1, @as(u16, @intCast(expo)));
    }

    const trailing_zero_bits: u16 = @intCast(@ctz(a));
    if (trailing_zero_bits != 0) {
        const zero_threshold = std.math.divCeil(u16, 256, trailing_zero_bits) catch unreachable;
        if (expo >= zero_threshold) return 0;
    }

    var value = a;
    var exponent = expo;
    var result: u256 = 1;
    while (exponent > 0) : (exponent >>= 1) {
        if ((exponent & 1) == 1) {
            result *%= value;
        }
        value *%= value;
    }

    return result;
}

test wrapExp {
    try std.testing.expectEqual(@as(u256, 1), wrapExp(0, 0));
    try std.testing.expectEqual(@as(u256, 0), wrapExp(0, 3));
    try std.testing.expectEqual(@as(u256, 1), wrapExp(1, std.math.maxInt(u256)));
    try std.testing.expectEqual(wrapExp(2, 2), 4);
    try std.testing.expectEqual(@as(u256, 1) << 255, wrapExp(2, 255));
    try std.testing.expectEqual(@as(u256, 0), wrapExp(2, 256));
    try std.testing.expectEqual(@as(u256, 0), wrapExp(4, 128));

    const a = 2;
    const exponent = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF;
    const result = wrapExp(a, exponent);
    try std.testing.expectEqual(@as(u256, 0), result);
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

/// Returns how many bytes are needed to represent the significant part of a 256-bit integer.
pub inline fn countSignificantBytesSize(value: u256) i64 {
    return @divFloor(256 - @as(i64, @intCast(@clz(value))) + 7, 8);
}

test countSignificantBytesSize {
    try std.testing.expectEqual(countSignificantBytesSize(0), 0);
    try std.testing.expectEqual(countSignificantBytesSize(1), 1);
    try std.testing.expectEqual(countSignificantBytesSize(255), 1);
    try std.testing.expectEqual(countSignificantBytesSize(256), 2);
    try std.testing.expectEqual(countSignificantBytesSize(1000), 2);
    try std.testing.expectEqual(countSignificantBytesSize(std.math.maxInt(u256)), 32);
}
