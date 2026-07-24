const std = @import("std");
const evmz = @import("../evm.zig");
const Interpreter = @import("../Interpreter.zig");

const CallFrame = Interpreter.CallFrame;

pub fn push0(frame: *CallFrame) !void {
    try frame.stack.push(0);
}

pub inline fn push(frame: *CallFrame, comptime n: u8) !void {
    comptime std.debug.assert(n >= 1 and n <= 32);

    const start = frame.pc;
    if (comptime n >= 3) {
        if (start <= frame.code.len and frame.code.len - start >= n) {
            const Int = std.meta.Int(.unsigned, @as(comptime_int, n) * 8);
            const bytes: *const [n]u8 = @ptrCast(frame.code.ptr + start);
            try frame.stack.push(@as(u256, std.mem.readInt(Int, bytes, .big)));
            frame.pc += n;
            return;
        }
    }

    var value: u256 = 0;
    inline for (0..n) |i| {
        value <<= 8;
        if (start + i < frame.code.len) {
            value |= @intCast(frame.code[start + i]);
        }
    }

    try frame.stack.push(value);
    frame.pc += n;
}

pub fn pop(frame: *CallFrame) !void {
    _ = try frame.stack.pop();
}

pub fn dup(frame: *CallFrame, comptime n: u8) !void {
    comptime std.debug.assert(n >= 1 and n <= 16);
    try frame.stack.dup(n);
}

pub fn dupn(frame: *CallFrame) !void {
    const immediate = immediateByte(frame);
    const n = decodeSingle(immediate) orelse {
        frame.failWithFrameStatus(.invalid_opcode);
        return;
    };
    frame.pc += 1;
    try frame.stack.dupDepth(n);
}

test "PUSH pads missing immediate bytes with zeroes" {
    try evmz.t.expectLatestForkBytecodeStackTop(.{ .PUSH2, 0x01 }, 0x0100);
    try evmz.t.expectLatestForkBytecodeStackTop(.{.PUSH1}, 0);
    try evmz.t.expectLatestForkBytecodeStackTop(.{ .PUSH32, 0x01 }, @as(u256, 1) << 248);
}

test "PUSH decodes full immediates" {
    try evmz.t.expectLatestForkBytecodeStackTop(.{ .PUSH3, 0x01, 0x02, 0x03 }, 0x010203);
    try evmz.t.expectLatestForkBytecodeStackTop(
        .{
            .PUSH32,
            0x01,
            0x23,
            0x45,
            0x67,
            0x89,
            0xab,
            0xcd,
            0xef,
            0x01,
            0x23,
            0x45,
            0x67,
            0x89,
            0xab,
            0xcd,
            0xef,
            0x01,
            0x23,
            0x45,
            0x67,
            0x89,
            0xab,
            0xcd,
            0xef,
            0x01,
            0x23,
            0x45,
            0x67,
            0x89,
            0xab,
            0xcd,
            0xef,
        },
        0x0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef,
    );
}

pub fn swap(frame: *CallFrame, comptime n: u8) !void {
    comptime std.debug.assert(n >= 1 and n <= 16);
    try frame.stack.swap(n);
}

pub fn swapn(frame: *CallFrame) !void {
    const immediate = immediateByte(frame);
    const n = decodeSingle(immediate) orelse {
        frame.failWithFrameStatus(.invalid_opcode);
        return;
    };
    frame.pc += 1;
    try frame.stack.swapDepth(n);
}

pub fn exchange(frame: *CallFrame) !void {
    const immediate = immediateByte(frame);
    const n, const m = decodePair(immediate) orelse {
        frame.failWithFrameStatus(.invalid_opcode);
        return;
    };
    frame.pc += 1;
    try frame.stack.exchangeDepths(n, m);
}

fn immediateByte(frame: *CallFrame) u8 {
    return if (frame.pc < frame.code.len) frame.code[frame.pc] else 0;
}

fn decodeSingle(x: u8) ?usize {
    if (x > 90 and x < 128) return null;
    return (@as(usize, x) + 145) % 256;
}

fn decodePair(x: u8) ?struct { usize, usize } {
    if (x > 81 and x < 128) return null;

    const k = x ^ 143;
    const q: usize = k >> 4;
    const r: usize = k & 0x0f;
    if (q < r) {
        return .{ q + 1, r + 1 };
    }
    return .{ r + 1, 29 - q };
}

test "EIP-8024 DUPN duplicates a deep stack item" {
    var code: [20]u8 = undefined;
    code[0] = evmz.Opcode.PUSH1.toByte();
    code[1] = 1;
    @memset(code[2..18], evmz.Opcode.PUSH0.toByte());
    code[18] = evmz.Opcode.DUPN.toByte();
    code[19] = 0x80;

    var expected = [_]u256{0} ** 18;
    expected[0] = 1;
    expected[17] = 1;
    try evmz.t.expectStackByRevision(&code, .amsterdam, &expected);
}

test "EIP-8024 SWAPN swaps the top with a deep stack item" {
    var code: [22]u8 = undefined;
    code[0] = evmz.Opcode.PUSH1.toByte();
    code[1] = 1;
    @memset(code[2..18], evmz.Opcode.PUSH0.toByte());
    code[18] = evmz.Opcode.PUSH1.toByte();
    code[19] = 2;
    code[20] = evmz.Opcode.SWAPN.toByte();
    code[21] = 0x80;

    var expected = [_]u256{0} ** 18;
    expected[0] = 2;
    expected[17] = 1;
    try evmz.t.expectStackByRevision(&code, .amsterdam, &expected);
}

test "EIP-8024 EXCHANGE swaps two non-top stack items" {
    const code = evmz.t.bytecode(.{ .PUSH0, .PUSH1, 1, .PUSH1, 2, .EXCHANGE, 0x8e });
    const expected = [_]u256{ 1, 0, 2 };
    try evmz.t.expectStackByRevision(&code, .amsterdam, &expected);
}

test "EIP-8024 immediates reject jumpdest and push ranges" {
    try evmz.t.expectBytecodeStatusByRevision(.{ .DUPN, 0x5b }, .amsterdam, .invalid);
    try evmz.t.expectBytecodeStatusByRevision(.{ .SWAPN, 0x60 }, .amsterdam, .invalid);
    try evmz.t.expectBytecodeStatusByRevision(.{ .EXCHANGE, 0x52 }, .amsterdam, .invalid);
}

test "EIP-8024 missing immediate byte is decoded as zero" {
    var code = [_]u8{evmz.Opcode.PUSH0.toByte()} ** 146;
    code[145] = evmz.Opcode.DUPN.toByte();

    const expected = [_]u256{0} ** 146;
    try evmz.t.expectStackByRevision(&code, .amsterdam, &expected);
}
