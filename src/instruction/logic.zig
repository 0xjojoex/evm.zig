const evmz = @import("../evm.zig");
const Interpreter = @import("../Interpreter.zig");
const std = @import("std");

const CallFrame = Interpreter.CallFrame;

pub fn lt(frame: *CallFrame) !void {
    const a = try frame.stack.pop();
    const b = try frame.stack.pop();
    const result: u256 = if (a < b) 1 else 0;
    try frame.stack.push(result);
}

pub fn gt(frame: *CallFrame) !void {
    const a = try frame.stack.pop();
    const b = try frame.stack.pop();
    const result: u256 = if (a > b) 1 else 0;
    try frame.stack.push(result);
}

pub fn slt(frame: *CallFrame) !void {
    const a = try frame.stack.pop();
    const b = try frame.stack.pop();
    const ia: i256 = @bitCast(a);
    const ib: i256 = @bitCast(b);
    const result: u256 = if (ia < ib) 1 else 0;
    try frame.stack.push(result);
}

pub fn sgt(frame: *CallFrame) !void {
    const a = try frame.stack.pop();
    const b = try frame.stack.pop();
    const ia: i256 = @bitCast(a);
    const ib: i256 = @bitCast(b);
    const result: u256 = if (ia > ib) 1 else 0;
    try frame.stack.push(result);
}

pub fn eq(frame: *CallFrame) !void {
    const a = try frame.stack.pop();
    const b = try frame.stack.pop();
    const result: u256 = if (a == b) 1 else 0;
    try frame.stack.push(result);
}

pub fn iszero(frame: *CallFrame) !void {
    const a = try frame.stack.pop();
    const result: u256 = if (a == 0) 1 else 0;
    try frame.stack.push(result);
}

pub fn bitAnd(frame: *CallFrame) !void {
    const a = try frame.stack.pop();
    const b = try frame.stack.pop();
    try frame.stack.push(a & b);
}

pub fn bitOr(frame: *CallFrame) !void {
    const a = try frame.stack.pop();
    const b = try frame.stack.pop();
    try frame.stack.push(a | b);
}

pub fn bitXor(frame: *CallFrame) !void {
    const a = try frame.stack.pop();
    const b = try frame.stack.pop();
    try frame.stack.push(a ^ b);
}

pub fn bitNot(frame: *CallFrame) !void {
    const a = try frame.stack.pop();
    try frame.stack.push(~a);
}

pub fn byte(frame: *CallFrame) !void {
    const bit_offset = try frame.stack.pop();
    const word_value = try frame.stack.pop();
    // the indicated byte at the least significant position. If the byte offset is out of range, the result is 0.
    const bit_offset_u8: u8 = @intCast(bit_offset);
    const result: u256 = if (bit_offset_u8 < 32) (word_value >> ((31 - bit_offset_u8) * 8)) & 0xff else 0;
    try frame.stack.push(result);
}

pub fn shl(frame: *CallFrame) !void {
    const b = try frame.stack.pop();
    const a = try frame.stack.pop();
    if (b > std.math.maxInt(u8)) {
        try frame.stack.push(0);
        return;
    }
    const b_u8: u8 = @intCast(b);
    try frame.stack.push(a << b_u8);
}

pub fn shr(frame: *CallFrame) !void {
    const b = try frame.stack.pop();
    const a = try frame.stack.pop();
    if (b > std.math.maxInt(u8)) {
        try frame.stack.push(0);
        return;
    }
    const b_u8: u8 = @intCast(b);
    try frame.stack.push(a >> b_u8);
}

pub fn sar(frame: *CallFrame) !void {
    const b = try frame.stack.pop();
    const a = try frame.stack.pop();

    const value: i256 = @bitCast(a);

    if (b >= std.math.maxInt(u8)) {
        try frame.stack.push(if (value < 0) std.math.maxInt(u256) else 0);
        return;
    }
    const shift: u8 = @intCast(b);
    const result = value >> shift;
    try frame.stack.push(@bitCast(result));
}
