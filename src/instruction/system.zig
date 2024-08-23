const Interpreter = @import("../Interpreter.zig");
const Opcode = @import("../opcode.zig").Opcode;
const Host = @import("../Host.zig");
const common = @import("../common.zig");
const std = @import("std");

const addr = common.addr;

pub fn stop(ip: *Interpreter) !void {
    ip.status = .success;
}

pub fn invalid(ip: *Interpreter) !void {
    // TODO: cosume all gas
    ip.status = .invalid;
}

/// `RETURN` Halt the execution returning the output data
pub fn ret(ip: *Interpreter) !void {
    const offset = try ip.stack.pop();
    const size = try ip.stack.pop();

    const offset_usize: usize = @intCast(offset);
    const size_usize: usize = @intCast(size);

    try ip.memory.expand(offset_usize, size_usize);
    const data = ip.memory.readBytes(offset_usize, size_usize);

    try ip.replaceReturnData(data);
    ip.status = .success;
}

/// `REVERT` Halt the execution reverting state changes but returning data and remaining gas
pub fn revert(ip: *Interpreter) !void {
    const offset = try ip.stack.pop();
    const size = try ip.stack.pop();

    const offset_usize: usize = @intCast(offset);
    const size_usize: usize = @intCast(size);

    try ip.memory.expand(offset_usize, size_usize);
    const data = ip.memory.readBytes(offset_usize, size_usize);

    // const buf = try ip.allocator.alloc(u8, data.len);
    // @memcpy(buf, data);

    try ip.replaceReturnData(data);
    ip.status = .revert;
}

pub fn callByOp(ip: *Interpreter, comptime op: Opcode) !void {
    if (op != Opcode.CALL and op != Opcode.STATICCALL and op != Opcode.DELEGATECALL and op != Opcode.CALLCODE) {
        @compileError("Invalid opcode for " ++ @tagName(op));
    }

    const gas = try ip.stack.pop();
    const address_word = try ip.stack.pop();
    const address: [20]u8 = @bitCast(@byteSwap(@as(u160, @intCast(address_word))));
    const value = if (op == Opcode.CALL or op == Opcode.CALLCODE) try ip.stack.pop() else 0;
    const in_offset = try ip.stack.pop();
    const in_size = try ip.stack.pop();
    const out_offset = try ip.stack.pop();
    const out_size = try ip.stack.pop();

    const in_offset_usize: usize = @intCast(in_offset);
    const in_size_usize: usize = @intCast(in_size);
    const out_offset_usize: usize = @intCast(out_offset);
    const out_size_usize: usize = @intCast(out_size);

    // TODO: handle gas

    try ip.memory.expand(in_offset_usize, in_size_usize);
    const data = ip.memory.readBytes(in_offset_usize, in_size_usize);

    const msg = Host.Message{
        .kind = Host.CallKind.fromOpcode(op),
        .recipient = if (op == Opcode.CALL or op == Opcode.STATICCALL) address else ip.msg.recipient,
        .is_static = op == Opcode.STATICCALL,
        .code_address = address,
        .sender = if (op == Opcode.DELEGATECALL) ip.msg.sender else ip.msg.recipient,
        .value = if (op == Opcode.DELEGATECALL) ip.msg.value else value,
        .input_data = data,
        .gas = gas,
    };

    const result = try ip.host.call(msg);

    try ip.memory.expand(out_offset_usize, out_size_usize);
    try ip.memory.writeBytes(out_offset_usize, result.output_data);

    try ip.replaceReturnData(result.output_data);

    if (result.status == .success) {
        try ip.stack.push(1);
    } else {
        try ip.stack.push(0);
    }
}

pub fn create(ip: *Interpreter) !void {
    return create_(ip, comptime false);
}

pub fn create2(ip: *Interpreter) !void {
    return create_(ip, comptime true);
}

pub inline fn create_(ip: *Interpreter, comptime is_create2: bool) !void {
    if (ip.msg.is_static) {
        return error.StaticCallViolation;
    }

    const value = try ip.stack.pop();
    const offset = try ip.stack.pop();
    const size = try ip.stack.pop();
    const salt = if (is_create2) try ip.stack.pop() else 0;

    const offset_usize: usize = @intCast(offset);
    const size_usize: usize = @intCast(size);

    const init_code = ip.memory.readBytes(offset_usize, size_usize);

    // TODO: again, need to handle gas cost
    const msg = Host.Message{
        .kind = if (is_create2) .create2 else .create,
        .input_data = init_code,
        .gas = ip.gas_left,
        .sender = ip.msg.recipient,
        .value = value,
        .create2_salt = salt,
    };

    const result = try ip.host.call(msg);

    if (result.status == .success) {
        try ip.replaceReturnData(result.output_data);
        try ip.stack.push(@byteSwap(@as(u160, @bitCast(result.create_address.?))));
    } else {
        try ip.stack.push(0);
    }
}

pub fn selfdestruct(ip: *Interpreter) !void {
    if (ip.msg.is_static) {
        return error.StaticCallViolation;
    }

    const address_word = try ip.stack.pop();

    const address: [20]u8 = @bitCast(@byteSwap(@as(u160, @intCast(address_word))));

    // TODO: handle gas cost

    try ip.host.selfDestruct(ip.msg.recipient, address);
    ip.status = .success;
}
