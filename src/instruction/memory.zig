const evmz = @import("../evm.zig");
const Interpreter = @import("../Interpreter.zig");
const std = @import("std");

const CallFrame = Interpreter.CallFrame;

pub fn mstore(frame: *CallFrame) !void {
    const offset, const value = try frame.stack.popN(2);
    const offset_usize = frame.wordToUsizeOrOog(offset) orelse return;
    const end = std.math.add(usize, offset_usize, 32) catch {
        frame.failWithStatus(.out_of_gas);
        return;
    };

    if (end <= frame.memory.len()) {
        frame.memory.write(offset_usize, value);
        return;
    }

    if (!try frame.expandMemory(offset_usize, 32)) return;
    frame.memory.write(offset_usize, value);
}

pub fn mstore8(frame: *CallFrame) !void {
    const offset, const value = try frame.stack.popN(2);
    const offset_usize = frame.wordToUsizeOrOog(offset) orelse return;
    const end = std.math.add(usize, offset_usize, 1) catch {
        frame.failWithStatus(.out_of_gas);
        return;
    };

    if (end <= frame.memory.len()) {
        frame.memory.write8(offset_usize, value);
        return;
    }

    if (!try frame.expandMemory(offset_usize, 1)) return;
    frame.memory.write8(offset_usize, value);
}

pub fn mload(frame: *CallFrame) !void {
    const offset = try frame.stack.pop();
    const offset_usize = frame.wordToUsizeOrOog(offset) orelse return;
    const end = std.math.add(usize, offset_usize, 32) catch {
        frame.failWithStatus(.out_of_gas);
        return;
    };

    if (end <= frame.memory.len()) {
        const value = frame.memory.read(offset_usize);
        frame.stack.pushUnchecked(value);
        return;
    }

    if (!try frame.expandMemory(offset_usize, 32)) return;
    const value = frame.memory.read(offset_usize);
    frame.stack.pushUnchecked(value);
}

test "MSTORE overwrites already expanded memory" {
    try evmz.t.expectLatestForkBytecodeStackTop(.{
        .PUSH1,  0xaa,
        .PUSH1,  0x00,
        .MSTORE, .PUSH1,
        0xbb,    .PUSH1,
        0x00,    .MSTORE,
        .PUSH1,  0x00,
        .MLOAD,
    }, 0xbb);
}

pub fn msize(frame: *CallFrame) !void {
    const size = frame.memory.len();
    try frame.stack.push(size);
}

pub fn mcopy(frame: *CallFrame) !void {
    if (!frame.spec.isImpl(.cancun)) {
        return error.UnsupportedInstruction;
    }

    const dest, const offset, const size = try frame.stack.popN(3);
    if (size == 0) return;

    const dest_usize = frame.wordToUsizeOrOog(dest) orelse return;
    const offset_usize = frame.wordToUsizeOrOog(offset) orelse return;
    const size_usize = frame.wordToUsizeOrOog(size) orelse return;

    if (!try frame.expandMemory(offset_usize, size_usize)) return;
    if (!try frame.expandMemory(dest_usize, size_usize)) return;
    const size_i64 = frame.wordToIntOrStatus(i64, size, .out_of_gas) orelse return;
    const word_copied_cost = evmz.calcWordSize(i64, size_i64) * 3;
    frame.trackGas(word_copied_cost);
    if (frame.status != .running) return;

    frame.memory.copy(dest_usize, offset_usize, size_usize);
}

test "MCOPY is only enabled from Cancun" {
    try evmz.t.expectBytecodeStatusBySpec(.{ .PUSH0, .PUSH0, .PUSH0, .MCOPY }, .shanghai, .invalid);
    try evmz.t.expectBytecodeStatusBySpec(.{ .PUSH0, .PUSH0, .PUSH0, .MCOPY }, .cancun, .success);
}

test "MCOPY expands destination" {
    try evmz.t.expectLatestForkBytecodeStatus(.{ .PUSH1, 0x01, .PUSH0, .PUSH1, 0x20, .MCOPY }, .success);
}

test "MCOPY zero length ignores out of bounds offsets" {
    try evmz.t.expectLatestForkBytecodeStatus(
        .{
            .PUSH0, .PUSH0, .PUSH32,
            0xff,   0xff,   0xff,
            0xff,   0xff,   0xff,
            0xff,   0xff,   0xff,
            0xff,   0xff,   0xff,
            0xff,   0xff,   0xff,
            0xff,   0xff,   0xff,
            0xff,   0xff,   0xff,
            0xff,   0xff,   0xff,
            0xff,   0xff,   0xff,
            0xff,   0xff,   0xff,
            0xff,   0xff,   .MCOPY,
        },
        .success,
    );
}
