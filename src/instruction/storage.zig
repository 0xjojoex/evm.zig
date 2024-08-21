const Interpreter = @import("../interpreter.zig");

pub inline fn sstore(ip: *Interpreter) !void {
    if (ip.is_static) {
        return error.StaticCallViolation;
    }
    const key = try ip.stack.pop();
    const value = try ip.stack.pop();
    try ip.state.sstore(ip.tx.to, key, value);
}

pub inline fn sload(ip: *Interpreter) !void {
    const key = try ip.stack.pop();
    const value = ip.state.sload(ip.tx.to, key);
    try ip.stack.push(value orelse 0);
}
