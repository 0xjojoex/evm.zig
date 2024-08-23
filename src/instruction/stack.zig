const Interpreter = @import("../Interpreter.zig");
const std = @import("std");

pub fn push0(ip: *Interpreter) !void {
    try ip.stack.push(0);
}

pub fn push(ip: *Interpreter, comptime n: u8) !void {
    if (n < 1 or n > 32) {
        @compileError("pushN: n must e in the range 1..32");
    }
    const value = ip.bytes[ip.pc .. ip.pc + n];

    const f = std.mem.readVarInt(u256, value, .big);
    try ip.stack.push(f);
    ip.pc += n;
}

pub fn pop(ip: *Interpreter) !void {
    _ = try ip.stack.pop();
}

pub fn dup(ip: *Interpreter, comptime n: u8) !void {
    if (n < 1 or n > 32) {
        @compileError("dup: n must be in the range 1..16");
    }
    try ip.stack.dup(n);
}

pub fn swap(ip: *Interpreter, comptime n: u8) !void {
    if (n < 1 or n > 16) {
        @compileError("swap: n must be in the range 1..16");
    }
    try ip.stack.swap(n);
}
