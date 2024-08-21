const Interpreter = @import("../Interpreter.zig");
const std = @import("std");
const utils = @import("../utils.zig");

pub fn log(ip: Interpreter, comptime n: u8) !void {
    if (n > 4) {
        @compileError("logN only supports up to 4 topics");
    }

    const offset = try ip.stack.pop();
    const size = try ip.stack.pop();

    var topics: [n]u256 = undefined;

    const offset_usize: usize = @intCast(offset);
    const size_usize: usize = @intCast(size);

    try ip.memory.expand(offset_usize, size_usize);
    var data = ip.memory.read(offset_usize);
    data = @byteSwap(data);

    for (0..n) |i| {
        const topic = try ip.stack.pop();
        topics[i] = topic;
    }

    try ip.state.emitLog(utils.Log{
        .address = ip.tx.to,
        .topics = topics[0..],
        .data = data,
    });
}
