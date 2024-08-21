const Interpreter = @import("../Interpreter.zig");
const std = @import("std");

// TODO:
// handle error when offset > usize

pub inline fn mstore(ip: *Interpreter) !void {
    const offset = try ip.stack.pop();
    const value = try ip.stack.pop();
    const offset_usize: usize = @intCast(offset);
    try ip.memory.expand(offset_usize, 32);
    try ip.memory.write(offset_usize, value);
}

pub inline fn mstore8(ip: *Interpreter) !void {
    const offset = try ip.stack.pop();
    const value = try ip.stack.pop();
    const offset_usize: usize = @intCast(offset);
    try ip.memory.expand(offset_usize, 1);
    ip.memory.write8(offset_usize, value);
}

pub inline fn mload(ip: *Interpreter) !void {
    const offset = try ip.stack.pop();
    const offset_usize: usize = @intCast(offset);
    try ip.memory.expand(offset_usize, 32);
    const value = ip.memory.read(offset_usize);
    try ip.stack.push(value);
}

pub inline fn msize(ip: *Interpreter) !void {
    const size = ip.memory.len();
    try ip.stack.push(size);
}
