const evmz = @import("../evm.zig");
const Interpreter = @import("../Interpreter.zig");
const std = @import("std");

const CallFrame = Interpreter.CallFrame;

pub fn lt(frame: *CallFrame) !void {
    const a, const b = try frame.stack.popN(2);
    const result: u256 = if (a < b) 1 else 0;
    frame.stack.pushUnchecked(result);
}

pub fn gt(frame: *CallFrame) !void {
    const a, const b = try frame.stack.popN(2);
    const result: u256 = if (a > b) 1 else 0;
    frame.stack.pushUnchecked(result);
}

pub fn slt(frame: *CallFrame) !void {
    const a, const b = try frame.stack.popN(2);
    const ia: i256 = @bitCast(a);
    const ib: i256 = @bitCast(b);
    const result: u256 = if (ia < ib) 1 else 0;
    frame.stack.pushUnchecked(result);
}

pub fn sgt(frame: *CallFrame) !void {
    const a, const b = try frame.stack.popN(2);
    const ia: i256 = @bitCast(a);
    const ib: i256 = @bitCast(b);
    const result: u256 = if (ia > ib) 1 else 0;
    frame.stack.pushUnchecked(result);
}

pub fn eq(frame: *CallFrame) !void {
    const a, const b = try frame.stack.popN(2);
    const result: u256 = if (a == b) 1 else 0;
    frame.stack.pushUnchecked(result);
}

pub fn iszero(frame: *CallFrame) !void {
    const a = frame.stack.peek() orelse return error.StackUnderflow;
    const result: u256 = if (a == 0) 1 else 0;
    frame.stack.replaceTopUnchecked(result);
}

pub fn bitAnd(frame: *CallFrame) !void {
    const a, const b = try frame.stack.popN(2);
    frame.stack.pushUnchecked(a & b);
}

pub fn bitOr(frame: *CallFrame) !void {
    const a, const b = try frame.stack.popN(2);
    frame.stack.pushUnchecked(a | b);
}

pub fn bitXor(frame: *CallFrame) !void {
    const a, const b = try frame.stack.popN(2);
    frame.stack.pushUnchecked(a ^ b);
}

pub fn bitNot(frame: *CallFrame) !void {
    const a = frame.stack.peek() orelse return error.StackUnderflow;
    frame.stack.replaceTopUnchecked(~a);
}

pub fn byte(frame: *CallFrame) !void {
    const bit_offset, const word_value = try frame.stack.popN(2);
    // the indicated byte at the least significant position. If the byte offset is out of range, the result is 0.
    if (bit_offset >= 32) {
        frame.stack.pushUnchecked(0);
        return;
    }
    const bit_offset_u8: u8 = @intCast(bit_offset);
    const result: u256 = (word_value >> ((31 - bit_offset_u8) * 8)) & 0xff;
    frame.stack.pushUnchecked(result);
}

pub fn shl(frame: *CallFrame) !void {
    const b, const a = try frame.stack.popN(2);
    if (b > std.math.maxInt(u8)) {
        frame.stack.pushUnchecked(0);
        return;
    }
    const b_u8: u8 = @intCast(b);
    frame.stack.pushUnchecked(evmz.uint256.shl(a, b_u8));
}

pub fn shr(frame: *CallFrame) !void {
    const b, const a = try frame.stack.popN(2);
    if (b > std.math.maxInt(u8)) {
        frame.stack.pushUnchecked(0);
        return;
    }
    const b_u8: u8 = @intCast(b);
    frame.stack.pushUnchecked(a >> b_u8);
}

pub fn sar(frame: *CallFrame) !void {
    const b, const a = try frame.stack.popN(2);

    const value: i256 = @bitCast(a);

    if (b >= std.math.maxInt(u8)) {
        frame.stack.pushUnchecked(if (value < 0) std.math.maxInt(u256) else 0);
        return;
    }
    const shift: u8 = @intCast(b);
    const result = value >> shift;
    frame.stack.pushUnchecked(@bitCast(result));
}

pub fn clz(frame: *CallFrame) !void {
    const value = frame.stack.peek() orelse return error.StackUnderflow;
    frame.stack.replaceTopUnchecked(@clz(value));
}

test "BYTE with large offset pushes zero" {
    try evmz.t.expectLatestForkBytecodeStackTop(.{ .PUSH1, 0x01, .PUSH1, 0xff, .BYTE }, 0);
}

test "CLZ is only enabled from Osaka" {
    try evmz.t.expectBytecodeStatusByRevision(.{ .PUSH1, 0x01, .CLZ }, .prague, .invalid);
}

test "CLZ treats zero as a value and counts leading zero bits in an EVM word" {
    try evmz.t.expectBytecodeStackTopByRevision(.{ .PUSH0, .CLZ }, .osaka, 256);
    try evmz.t.expectBytecodeStackTopByRevision(.{ .PUSH1, 0x01, .CLZ }, .osaka, 255);
    try evmz.t.expectBytecodeStackTopByRevision(.{ .PUSH1, 0x80, .CLZ }, .osaka, 248);
}
