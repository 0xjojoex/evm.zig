const evmz = @import("../evm.zig");
const interpreter = @import("../interpreter.zig");
const std = @import("std");

const CallFrame = interpreter.CallFrame;

pub fn Stack(comptime spec: evmz.Spec) type {
    _ = spec;
    return struct {
        pub fn push0(frame: *CallFrame) !void {
            try frame.stack.push(0);
        }

        pub fn push(frame: *CallFrame, comptime n: u8) !void {
            if (n < 1 or n > 32) {
                @compileError("pushN: n must e in the range 1..32");
            }
            const value = frame.bytes[frame.pc .. frame.pc + n];

            const f = std.mem.readVarInt(u256, value, .big);
            try frame.stack.push(f);
            frame.pc += n;
        }

        pub fn pop(frame: *CallFrame) !void {
            _ = try frame.stack.pop();
        }

        pub fn dup(frame: *CallFrame, comptime n: u8) !void {
            if (n < 1 or n > 32) {
                @compileError("dup: n must be in the range 1..16");
            }
            try frame.stack.dup(n);
        }

        pub fn swap(frame: *CallFrame, comptime n: u8) !void {
            if (n < 1 or n > 16) {
                @compileError("swap: n must be in the range 1..16");
            }
            try frame.stack.swap(n);
        }
    };
}
