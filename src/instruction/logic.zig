const Interpreter = @import("../interpreter.zig");
const std = @import("std");

pub fn lt(ip: *Interpreter) !void {
    const a = try ip.stack.pop();
    const b = try ip.stack.pop();
    const result: u256 = if (a < b) 1 else 0;
    try ip.stack.push(result);
}

pub fn gt(ip: *Interpreter) !void {
    const a = try ip.stack.pop();
    const b = try ip.stack.pop();
    const result: u256 = if (a > b) 1 else 0;
    try ip.stack.push(result);
}

pub fn slt(ip: *Interpreter) !void {
    const a = try ip.stack.pop();
    const b = try ip.stack.pop();
    const ia: i256 = @bitCast(a);
    const ib: i256 = @bitCast(b);
    const result: u256 = if (ia < ib) 1 else 0;
    try ip.stack.push(result);
}

pub fn sgt(ip: *Interpreter) !void {
    const a = try ip.stack.pop();
    const b = try ip.stack.pop();
    const ia: i256 = @bitCast(a);
    const ib: i256 = @bitCast(b);
    const result: u256 = if (ia > ib) 1 else 0;
    try ip.stack.push(result);
}

pub fn eq(ip: *Interpreter) !void {
    const a = try ip.stack.pop();
    const b = try ip.stack.pop();
    const result: u256 = if (a == b) 1 else 0;
    try ip.stack.push(result);
}

pub fn isZero(ip: *Interpreter) !void {
    const a = try ip.stack.pop();
    const result: u256 = if (a == 0) 1 else 0;
    try ip.stack.push(result);
}

pub fn bitAnd(ip: *Interpreter) !void {
    const a = try ip.stack.pop();
    const b = try ip.stack.pop();
    try ip.stack.push(a & b);
}

pub fn bitOr(ip: *Interpreter) !void {
    const a = try ip.stack.pop();
    const b = try ip.stack.pop();
    try ip.stack.push(a | b);
}

pub fn bitXor(ip: *Interpreter) !void {
    const a = try ip.stack.pop();
    const b = try ip.stack.pop();
    try ip.stack.push(a ^ b);
}

pub fn bitNot(ip: *Interpreter) !void {
    const a = try ip.stack.pop();
    try ip.stack.push(~a);
}

pub fn byte(ip: *Interpreter) !void {
    const bit_offset = try ip.stack.pop();
    const word_value = try ip.stack.pop();
    // the indicated byte at the least significant position. If the byte offset is out of range, the result is 0.
    const bit_offset_u8: u8 = @intCast(bit_offset);
    const result: u256 = if (bit_offset_u8 < 32) (word_value >> ((31 - bit_offset_u8) * 8)) & 0xff else 0;
    try ip.stack.push(result);
}

pub fn shl(ip: *Interpreter) !void {
    const b = try ip.stack.pop();
    const a = try ip.stack.pop();
    if (b > std.math.maxInt(u8)) {
        try ip.stack.push(0);
        return;
    }
    const b_u8: u8 = @intCast(b);
    try ip.stack.push(a << b_u8);
}

pub fn shr(ip: *Interpreter) !void {
    const b = try ip.stack.pop();
    const a = try ip.stack.pop();
    if (b > std.math.maxInt(u8)) {
        try ip.stack.push(0);
        return;
    }
    const b_u8: u8 = @intCast(b);
    try ip.stack.push(a >> b_u8);
}

pub fn sar(ip: *Interpreter) !void {
    const b = try ip.stack.pop();
    const a = try ip.stack.pop();

    const value: i256 = @bitCast(a);

    if (b >= std.math.maxInt(u8)) {
        try ip.stack.push(if (value < 0) std.math.maxInt(u256) else 0);
        return;
    }
    const shift: u8 = @intCast(b);
    const result = value >> shift;
    try ip.stack.push(@bitCast(result));
}
