const evmz = @import("../evm.zig");
const Interpreter = @import("../Interpreter.zig");
const std = @import("std");
const Host = @import("../Host.zig");

const CallFrame = Interpreter.CallFrame;

pub fn log(frame: *CallFrame, comptime n: u8) !void {
    comptime std.debug.assert(n <= 4);

    if (frame.msg.is_static) {
        return error.StaticCallViolation;
    }

    const offset, const size = try frame.stack.popN(2);

    var topics: [n]u256 = undefined;

    const size_usize = frame.wordToUsizeOrOog(size) orelse return;
    const offset_usize = frame.memoryOffsetToUsizeOrOog(offset, size_usize) orelse return;

    if (!try frame.expandMemory(offset_usize, size_usize)) return;
    const size_i64 = frame.wordToIntOrStatus(i64, size, .out_of_gas) orelse return;
    const log_cost = std.math.mul(i64, 8, size_i64) catch {
        frame.failWithStatus(.out_of_gas);
        return;
    };
    frame.trackGas(log_cost);
    if (frame.status != .running) return;

    const data = frame.memory.readBytes(offset_usize, size_usize);

    for (0..n) |i| {
        const topic = try frame.stack.pop();
        topics[i] = topic;
    }

    try frame.host.emitLog(Host.Log{
        .address = frame.msg.recipient,
        .topics = topics[0..n],
        .data = data,
    });
}
