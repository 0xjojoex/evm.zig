const evmz = @import("../evm.zig");
const interpreter = @import("../interpreter.zig");
const std = @import("std");

const CallFrame = interpreter.CallFrame;

// TODO:
// handle error when offset > usize

pub fn Memory(comptime spec: evmz.Spec) type {
    _ = spec;
    return struct {
        pub fn mstore(frame: *CallFrame) !void {
            const offset = try frame.stack.pop();
            const value = try frame.stack.pop();
            const offset_usize: usize = @intCast(offset);
            try frame.memory.expand(offset_usize, 32);
            try frame.memory.write(offset_usize, value);
        }

        pub fn mstore8(frame: *CallFrame) !void {
            const offset = try frame.stack.pop();
            const value = try frame.stack.pop();
            const offset_usize: usize = @intCast(offset);
            try frame.memory.expand(offset_usize, 1);
            frame.memory.write8(offset_usize, value);
        }

        pub fn mload(frame: *CallFrame) !void {
            const offset = try frame.stack.pop();
            const offset_usize: usize = @intCast(offset);
            try frame.memory.expand(offset_usize, 32);
            const value = frame.memory.read(offset_usize);
            try frame.stack.push(value);
        }

        pub fn msize(frame: *CallFrame) !void {
            const size = frame.memory.len();
            try frame.stack.push(size);
        }
    };
}
