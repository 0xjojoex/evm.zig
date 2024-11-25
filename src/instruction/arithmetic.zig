const interpreter = @import("../interpreter.zig");
const std = @import("std");
const evmz = @import("../evm.zig");

const CallFrame = interpreter.CallFrame;

pub fn add(frame: *CallFrame) !void {
    const a = try frame.stack.pop();
    const b = try frame.stack.pop();
    const result = a +% b;

    try frame.stack.push(result);
}

pub fn mul(frame: *CallFrame) !void {
    const a = try frame.stack.pop();
    const b = try frame.stack.pop();
    const result = a *% b;

    try frame.stack.push(result);
}

pub fn sub(frame: *CallFrame) !void {
    const a = try frame.stack.pop();
    const b = try frame.stack.pop();
    const result = a -% b;

    try frame.stack.push(result);
}

pub fn div(frame: *CallFrame) !void {
    const top = frame.stack.peekN(2);
    const a = try frame.stack.pop();

    if (top.? != 0) {
        const b = try frame.stack.pop();
        const result = a / b;
        try frame.stack.push(result);
    }
}

pub fn sdiv(frame: *CallFrame) !void {
    const top = frame.stack.peekN(2);
    const a = try frame.stack.pop();

    if (top.? != 0) {
        const ia: i256 = @bitCast(a);
        const b = try frame.stack.pop();
        const ib: i256 = @bitCast(b);
        const result: u256 = @bitCast(@divFloor(ia, ib));

        try frame.stack.push(result);
    }
}

pub fn mod(frame: *CallFrame) !void {
    const a = try frame.stack.pop();
    const b = try frame.stack.pop();
    var result: u256 = undefined;
    if (b == 0) {
        result = 0;
    } else {
        result = a % b;
    }
    try frame.stack.push(result);
}

pub fn smod(frame: *CallFrame) !void {
    const a = try frame.stack.pop();
    const b = try frame.stack.pop();
    var result: u256 = undefined;
    if (b == 0) {
        result = 0;
    } else {
        const ia: i256 = @bitCast(a);
        const ib: i256 = @bitCast(b);
        result = @bitCast(@mod(ia, ib));
    }
    try frame.stack.push(result);
}

pub fn addmod(frame: *CallFrame) !void {
    const a = try frame.stack.pop();
    const b = try frame.stack.pop();
    const c = try frame.stack.pop();
    var result: u256 = undefined;
    if (c == 0) {
        result = 0;
    } else {
        result = u256AddMod(a, b, c);
    }
    try frame.stack.push(result);
}

pub fn mulmod(frame: *CallFrame) !void {
    const a = try frame.stack.pop();
    const b = try frame.stack.pop();
    const c = try frame.stack.pop();
    var result: u256 = undefined;
    if (c == 0) {
        result = 0;
    } else {
        result = u256MulMod(a, b, c);
    }
    try frame.stack.push(result);
}

pub fn exp(frame: *CallFrame) !void {
    const a = try frame.stack.pop();
    const exponent = try frame.stack.pop();

    const exp_cost: u8 = if (frame.spec.isImpl(.spurious_dragon)) 50 else 10;

    const exponent_byte_size: i64 = countSignificantBytesSize(@intCast(exponent));
    frame.trackGas(exp_cost * exponent_byte_size);

    const result = wrapExp(a, exponent);
    try frame.stack.push(result);
}

pub fn signextend(frame: *CallFrame) !void {
    const a = try frame.stack.pop();
    const b = try frame.stack.pop();

    var val = b;
    if (a < 31) {
        const sign_bit: u8 = @as(u8, @intCast(a)) * 8 + 7;
        const mask = std.math.shl(u256, 1, sign_bit - a) - 1;
        if (((b >> sign_bit) & 1) != 0) {
            val = b | ~mask;
        } else {
            val = b & mask;
        }
    }

    try frame.stack.push(val);
}

pub fn keccak256(frame: *CallFrame) !void {
    const offset: usize = @intCast(try frame.stack.pop());
    const size: usize = @intCast(try frame.stack.pop());

    const expand_cost = try frame.memory.expand(offset, size);
    const min_word_size = (size + 31) / 32;
    const gas_for_word: i64 = @intCast(6 * min_word_size);
    frame.trackGas(gas_for_word + expand_cost);

    const value = frame.memory.readBytes(offset, size);

    var result: [32]u8 = undefined;
    // TODO: test empty value
    std.crypto.hash.sha3.Keccak256.hash(value, &result, .{});

    const final_result = @byteSwap(@as(u256, @bitCast(result)));
    try frame.stack.push(final_result);
}

inline fn u256AddMod(a: u256, b: u256, c: u256) u256 {
    const r, const sum = @addWithOverflow(a, b);
    if (sum != 0) {
        return sum % c;
    } else {
        return r % c;
    }
}

test u256AddMod {
    const max_256 = std.math.maxInt(u256);
    try std.testing.expectEqual(u256AddMod(max_256, 1, max_256), 1);
}

// can work on a better version
inline fn u256MulMod(lhs: u256, rhs: u256, modulo: u256) u256 {
    if (modulo == 0) return 0;

    var result: u1024 = 0;
    var a: u1024 = @intCast(lhs % modulo);
    var b: u1024 = @intCast(rhs);
    while (b > 0) : (b >>= 1) {
        if (b & 1 == 1) {
            result = (result +% a) % modulo;
        }
        a = (a * 2) % modulo;
    }

    return @intCast(result);
}

inline fn wrapExp(a: u256, expo: u256) u256 {
    var value = a;
    var exponent = expo;
    var result: u256 = 1;
    while (exponent > 0) : (exponent >>= 1) {
        if ((exponent & 1) == 1) {
            result *%= value;
        }
        value *%= value;
    }

    if (result == 0) return 1;
    return result;
}

test wrapExp {
    try std.testing.expectEqual(wrapExp(2, 2), 4);

    const a = 2;
    const exponent = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF;
    const result = wrapExp(a, exponent);
    try std.testing.expectEqual(result, 1);
}

test u256MulMod {
    const max_256 = std.math.maxInt(u256);

    try std.testing.expectEqual(u256MulMod(std.math.pow(u256, 2, 255), std.math.pow(u256, 2, 255), max_256), 0x4000000000000000000000000000000000000000000000000000000000000000);
    try std.testing.expectEqual(u256MulMod(max_256, 1, max_256), 0);
    try std.testing.expectEqual(u256MulMod(3, 4, 5), 2);
}

/// Returns the number of significant byte size for the u64 integer, calcuate how many bytes are needed to represent the significant part of the integer.
inline fn countSignificantBytesSize(value: u64) u8 {
    return (64 - @clz(value) + 7) / 8;
}

test countSignificantBytesSize {
    try std.testing.expectEqual(countSignificantBytesSize(0), 0);
    try std.testing.expectEqual(countSignificantBytesSize(1), 1);
    try std.testing.expectEqual(countSignificantBytesSize(255), 1);
    try std.testing.expectEqual(countSignificantBytesSize(256), 2);
    try std.testing.expectEqual(countSignificantBytesSize(1000), 2);
}
