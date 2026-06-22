const evmz = @import("../evm.zig");
const Interpreter = @import("../Interpreter.zig");

const CallFrame = Interpreter.CallFrame;

pub fn mstore(frame: *CallFrame) !void {
    const offset = try frame.stack.pop();
    const value = try frame.stack.pop();
    const offset_usize = frame.wordToUsizeOrOog(offset) orelse return;
    if (!try frame.expandMemory(offset_usize, 32)) return;
    try frame.memory.write(offset_usize, value);
}

pub fn mstore8(frame: *CallFrame) !void {
    const offset = try frame.stack.pop();
    const value = try frame.stack.pop();
    const offset_usize = frame.wordToUsizeOrOog(offset) orelse return;
    if (!try frame.expandMemory(offset_usize, 1)) return;
    frame.memory.write8(offset_usize, value);
}

pub fn mload(frame: *CallFrame) !void {
    const offset = try frame.stack.pop();
    const offset_usize = frame.wordToUsizeOrOog(offset) orelse return;
    if (!try frame.expandMemory(offset_usize, 32)) return;
    const value = frame.memory.read(offset_usize);
    try frame.stack.push(value);
}

pub fn msize(frame: *CallFrame) !void {
    const size = frame.memory.len();
    try frame.stack.push(size);
}

pub fn mcopy(frame: *CallFrame) !void {
    if (!frame.spec.isImpl(.cancun)) {
        return error.UnsupportedInstruction;
    }

    const dest = try frame.stack.pop();
    const offset = try frame.stack.pop();
    const size = try frame.stack.pop();
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

    try frame.memory.copy(dest_usize, offset_usize, size_usize);
}

test "MCOPY is only enabled from Cancun" {
    try evmz.t.expectBytecodeStatus(&.{ 0x5f, 0x5f, 0x5f, 0x5e }, .shanghai, .invalid);
    try evmz.t.expectBytecodeStatus(&.{ 0x5f, 0x5f, 0x5f, 0x5e }, .cancun, .success);
}

test "MCOPY expands destination" {
    try evmz.t.expectCancunBytecodeStatus(&.{ 0x60, 0x01, 0x5f, 0x60, 0x20, 0x5e }, .success);
}

test "MCOPY zero length ignores out of bounds offsets" {
    try evmz.t.expectCancunBytecodeStatus(
        &.{ 0x5f, 0x5f, 0x7f, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x5e },
        .success,
    );
}
