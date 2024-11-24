const evmz = @import("../evm.zig");
const interpreter = @import("../interpreter.zig");
const std = @import("std");
const Host = @import("../Host.zig");

const CallFrame = interpreter.CallFrame;

pub fn Logging(comptime spec: evmz.Spec) type {
    _ = spec;
    return struct {
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

            const offset_usize: usize = @intCast(offset);
            const size_usize: usize = @intCast(size);

            const expand_cost = try frame.memory.expand(offset_usize, size_usize);
            const log_cost: i64 = @intCast(8 * size_usize);
            frame.trackGas(expand_cost + log_cost);

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
    };
}
