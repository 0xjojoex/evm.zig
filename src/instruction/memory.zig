const evmz = @import("../evm.zig");
const interpreter = @import("../interpreter.zig");
const std = @import("std");

const CallFrame = interpreter.CallFrame;

pub fn Memory(comptime spec: evmz.Spec) type {
    return struct {
        pub fn mstore(frame: *CallFrame) !void {
            const offset = try frame.stack.pop();
            const value = try frame.stack.pop();
            const offset_usize: usize = @intCast(offset);
            const expand_cost = try frame.memory.expand(offset_usize, 32);
            frame.trackGas(expand_cost);
            try frame.memory.write(offset_usize, value);
        }

        pub fn mstore8(frame: *CallFrame) !void {
            const offset = try frame.stack.pop();
            const value = try frame.stack.pop();
            const offset_usize: usize = @intCast(offset);
            const expand_cost = try frame.memory.expand(offset_usize, 1);
            frame.trackGas(expand_cost);
            frame.memory.write8(offset_usize, value);
        }

        pub fn mload(frame: *CallFrame) !void {
            const offset = try frame.stack.pop();
            const offset_usize: usize = @intCast(offset);
            const expand_cost = try frame.memory.expand(offset_usize, 32);
            frame.trackGas(expand_cost);
            const value = frame.memory.read(offset_usize);
            try frame.stack.push(value);
        }

        pub fn msize(frame: *CallFrame) !void {
            const size = frame.memory.len();
            try frame.stack.push(size);
        }

        pub fn mcopy(frame: *CallFrame) !void {
            if (spec.isImpl(.cancun)) {
                return error.UnsupportedInstruction;
            }

            const dest = try frame.stack.pop();
            const offset = try frame.stack.pop();
            const size = try frame.stack.pop();
            const dest_usize: usize = @intCast(dest);
            const offset_usize: usize = @intCast(offset);
            const size_usize: usize = @intCast(size);

            const expand_cost = try frame.memory.expand(offset_usize, size_usize);
            const word_copied_cost = evmz.calcWordSize(i64, @intCast(size_usize)) * 3;
            frame.trackGas(expand_cost + word_copied_cost);

            try frame.memory.copy(dest_usize, offset_usize, size_usize);
        }
    };
}
