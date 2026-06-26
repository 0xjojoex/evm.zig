const std = @import("std");
const evmz = @import("../evm.zig");
const Interpreter = @import("../Interpreter.zig");

const CallFrame = Interpreter.CallFrame;

pub fn push0(frame: *CallFrame) !void {
    try frame.stack.push(0);
}

pub inline fn push(frame: *CallFrame, comptime n: u8) !void {
    if (n < 1 or n > 32) {
        @compileError("pushN: n must be in the range 1..32");
    }

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
    if (n < 1 or n > 16) {
        @compileError("dup: n must be in the range 1..16");
    }
    try frame.stack.dup(n);
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
    if (n < 1 or n > 16) {
        @compileError("swap: n must be in the range 1..16");
    }
    try frame.stack.swap(n);
}
