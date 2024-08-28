const std = @import("std");
const evmz = @import("../evm.zig");
const interpreter = @import("../interpreter.zig");

const CallFrame = interpreter.CallFrame;

pub fn Storage(comptime spec: evmz.Spec) type {
    _ = spec;
    return struct {
        pub fn sstore(frame: *CallFrame) !void {
            if (frame.msg.is_static) {
                return error.StaticCallViolation;
            }
            const key = try frame.stack.pop();
            const value = try frame.stack.pop();
            try frame.host.setStorage(frame.msg.recipient, key, value);
        }

        pub fn sload(frame: *CallFrame) !void {
            const key = try frame.stack.pop();
            const value = frame.host.getStorage(frame.msg.recipient, key);
            try frame.stack.push(value orelse 0);
        }
    };
}
