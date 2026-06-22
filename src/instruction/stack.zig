const evmz = @import("../evm.zig");
const Interpreter = @import("../Interpreter.zig");
const std = @import("std");

const CallFrame = Interpreter.CallFrame;

pub fn push0(frame: *CallFrame) !void {
    try frame.stack.push(0);
}

pub fn push(frame: *CallFrame, comptime n: u8) !void {
    if (n < 1 or n > 32) {
        @compileError("pushN: n must e in the range 1..32");
    }

    // PUSHn can legally run out of bytecode, missing immediate bytes are zero-padded
    var bytes: [32]u8 = [_]u8{0} ** 32;
    const available = if (frame.pc >= frame.bytes.len) 0 else @min(n, frame.bytes.len - frame.pc);
    @memcpy(bytes[0..available], frame.bytes[frame.pc..][0..available]);

    const f = std.mem.readVarInt(u256, bytes[0..n], .big);
    try frame.stack.push(f);
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
    try evmz.t.expectCancunBytecodeStackTop(&.{ 0x61, 0x01 }, 0x0100);
}

pub fn swap(frame: *CallFrame, comptime n: u8) !void {
    if (n < 1 or n > 16) {
        @compileError("swap: n must be in the range 1..16");
    }
    try frame.stack.swap(n);
}
