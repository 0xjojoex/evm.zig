const evmz = @import("../evm.zig");
const Interpreter = @import("../Interpreter.zig");
const std = @import("std");
const Host = @import("../Host.zig");

const CallFrame = Interpreter.CallFrame;

pub fn log(frame: *CallFrame, comptime n: u8) !void {
    if (n > 4) {
        @compileError("logN only supports up to 4 topics");
    }

    if (frame.msg.is_static) {
        return error.StaticCallViolation;
    }

    const offset = try frame.stack.pop();
    const size = try frame.stack.pop();

    var topics: [n]u256 = undefined;

    const offset_usize = frame.wordToUsizeOrOog(offset) orelse return;
    const size_usize = frame.wordToUsizeOrOog(size) orelse return;

    if (!try frame.expandMemory(offset_usize, size_usize)) return;
    const size_i64 = frame.wordToIntOrStatus(i64, size, .out_of_gas) orelse return;
    const log_cost = std.math.mul(i64, 8, size_i64) catch {
        frame.status = .out_of_gas;
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
