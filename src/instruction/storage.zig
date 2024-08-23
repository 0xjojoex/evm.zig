const std = @import("std");
const Interpreter = @import("../Interpreter.zig");

pub fn sstore(ip: *Interpreter) !void {
    if (ip.msg.is_static) {
        return error.StaticCallViolation;
    }
    const key = try ip.stack.pop();
    const value = try ip.stack.pop();
    try ip.host.setStorage(ip.msg.recipient, key, value);
}

pub fn sload(ip: *Interpreter) !void {
    const key = try ip.stack.pop();
    const value = ip.host.getStorage(ip.msg.recipient, key);
    try ip.stack.push(value orelse 0);
}
