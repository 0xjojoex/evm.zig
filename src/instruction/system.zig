const Interpreter = @import("../interpreter.zig");
const utils = @import("../utils.zig");
const std = @import("std");

pub fn stop(ip: *Interpreter) !void {
    ip.status = .success;
}

pub fn invalid(ip: *Interpreter) !void {
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

    const buf = try ip.allocator.alloc(u8, data.len);
    @memcpy(buf, data);

    ip.return_data = buf;
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

    const buf = try ip.allocator.alloc(u8, data.len);
    @memcpy(buf, data);

    ip.return_data = buf;
    ip.status = .revert;
}

/// `CALL` Message-call into another account
pub fn call(ip: *Interpreter) !void {
    const gas = try ip.stack.pop();
    const address_word = try ip.stack.pop();
    const value = try ip.stack.pop();
    const in_offset = try ip.stack.pop();
    const in_size = try ip.stack.pop();
    const out_offset = try ip.stack.pop();
    const out_size = try ip.stack.pop();

    const in_offset_usize: usize = @intCast(in_offset);
    const in_size_usize: usize = @intCast(in_size);
    const out_offset_usize: usize = @intCast(out_offset);
    const out_size_usize: usize = @intCast(out_size);

    std.debug.print("in {d}, {d}\n", .{ in_offset, in_size });

    try ip.memory.expand(in_offset_usize, in_size_usize);
    const data = ip.memory.readBytes(in_offset_usize, in_size_usize);

    // TODO: gas
    _ = gas;

    const address: [20]u8 = @bitCast(@byteSwap(@as(u160, @intCast(address_word))));
    const address_code = try ip.state.getCode(address);
    var interpreter = Interpreter.init(ip.allocator, address_code, .{
        .origin = ip.tx.origin,
        .to = address,
        .value = value,
        .data = data,
        .gas_price = ip.tx.gas_price,
        .from = ip.tx.to,
    }, ip.block, ip.state);

    defer interpreter.deinit();

    interpreter.handle();

    try ip.memory.expand(out_offset_usize, out_size_usize);
    try ip.memory.writeBytes(out_offset_usize, interpreter.return_data);

    const buf = try ip.allocator.alloc(u8, interpreter.return_data.len);

    @memcpy(buf, interpreter.return_data);

    ip.return_data = buf;

    if (interpreter.status == .success) {
        try ip.stack.push(1);
    } else {
        try ip.stack.push(0);
    }
}

pub fn delegatecall(ip: *Interpreter) !void {
    const gas = try ip.stack.pop();
    const address_word = try ip.stack.pop();
    const in_offset = try ip.stack.pop();
    const in_size = try ip.stack.pop();
    const out_offset = try ip.stack.pop();
    const out_size = try ip.stack.pop();

    _ = gas;

    const in_offset_usize: usize = @intCast(in_offset);
    const in_size_usize: usize = @intCast(in_size);
    const out_offset_usize: usize = @intCast(out_offset);
    const out_size_usize: usize = @intCast(out_size);

    try ip.memory.expand(in_offset_usize, in_size_usize);
    const data = ip.memory.readBytes(in_offset_usize, in_size_usize);

    const address: [20]u8 = @bitCast(@byteSwap(@as(u160, @intCast(address_word))));
    const address_code = try ip.state.getCode(address);

    var interpreter = Interpreter.init(ip.allocator, address_code, .{
        .origin = ip.tx.origin,
        .to = ip.tx.to,
        .value = ip.tx.value,
        .data = data,
        .gas_price = ip.tx.gas_price,
        .from = ip.tx.from,
    }, ip.block, ip.state);

    defer interpreter.deinit();

    interpreter.handle();

    try ip.memory.expand(out_offset_usize, out_size_usize);
    try ip.memory.writeBytes(out_offset_usize, interpreter.return_data);

    const buf = try ip.allocator.alloc(u8, interpreter.return_data.len);

    @memcpy(buf, interpreter.return_data);

    ip.return_data = buf;

    if (interpreter.status == .success) {
        try ip.stack.push(1);
    } else {
        try ip.stack.push(0);
    }
}

pub fn staticcall(ip: *Interpreter) !void {
    const gas = try ip.stack.pop();
    const address_word = try ip.stack.pop();
    const in_offset = try ip.stack.pop();
    const in_size = try ip.stack.pop();
    const out_offset = try ip.stack.pop();
    const out_size = try ip.stack.pop();

    const in_offset_usize: usize = @intCast(in_offset);
    const in_size_usize: usize = @intCast(in_size);
    const out_offset_usize: usize = @intCast(out_offset);
    const out_size_usize: usize = @intCast(out_size);

    try ip.memory.expand(in_offset_usize, in_size_usize);
    const data = ip.memory.readBytes(in_offset_usize, in_size_usize);

    // TODO: gas
    _ = gas;

    const address: [20]u8 = @bitCast(@byteSwap(@as(u160, @intCast(address_word))));
    const address_code = try ip.state.getCode(address);
    var interpreter = Interpreter.init(ip.allocator, address_code, .{
        .origin = ip.tx.origin,
        .to = address,
        .value = 0,
        .data = data,
        .gas_price = ip.tx.gas_price,
        .from = ip.tx.to,
    }, ip.block, ip.state);

    interpreter.is_static = true;

    defer interpreter.deinit();

    interpreter.handle();

    try ip.memory.expand(out_offset_usize, out_size_usize);
    try ip.memory.writeBytes(out_offset_usize, interpreter.return_data);

    const buf = try ip.allocator.alloc(u8, interpreter.return_data.len);

    @memcpy(buf, interpreter.return_data);

    ip.return_data = buf;

    if (interpreter.status == .success) {
        try ip.stack.push(1);
    } else {
        try ip.stack.push(0);
    }
}

// create a new contract
pub fn create(ip: *Interpreter) !void {
    if (ip.is_static) {
        return error.StaticCallViolation;
    }

    const value = try ip.stack.pop();
    const offset = try ip.stack.pop();
    const size = try ip.stack.pop();

    const offset_usize: usize = @intCast(offset);
    const size_usize: usize = @intCast(size);

    // address = keccak256(rlp([sender_address,sender_nonce]))[12:]
    const sender = ip.tx.to;
    // const nonce = 0;
    var result: [32]u8 = undefined;
    std.crypto.hash.sha3.Keccak256.hash(sender[0..], &result, .{});

    const result_slice = result[12..32].*;
    const final_result = @byteSwap(@as(u160, @bitCast(result_slice)));
    const new_address: [20]u8 = result_slice;

    std.debug.print("new_address: {x}\n", .{new_address});

    try ip.state.putAccount(new_address, .{
        .balance = value,
    });

    const init_code = ip.memory.readBytes(offset_usize, size_usize);

    var interpreter = Interpreter.init(ip.allocator, init_code, .{
        .origin = ip.tx.origin,
        .to = new_address,
        .value = 0,
        .data = ip.tx.data,
        .gas_price = ip.tx.gas_price,
        .from = utils.zero_address,
    }, ip.block, ip.state);

    defer interpreter.deinit();

    interpreter.handle();

    if (interpreter.status == .success) {
        const buf = try ip.allocator.alloc(u8, interpreter.return_data.len);
        @memcpy(buf, interpreter.return_data);
        ip.return_data = buf;
        try ip.state.putCode(new_address, buf);
        try ip.stack.push(final_result);
    } else {
        try ip.stack.push(0);
    }
}

pub fn selfdestruct(ip: *Interpreter) !void {
    if (ip.is_static) {
        return error.StaticCallViolation;
    }

    const address_word = try ip.stack.pop();

    const address: [20]u8 = @bitCast(@byteSwap(@as(u160, @intCast(address_word))));

    const destrucrting_balance = try ip.state.getBalance(ip.tx.to);

    const recipient_balance = try ip.state.getBalance(address);

    // could be better handle these op in host.
    try ip.state.putAccount(address, .{
        .balance = destrucrting_balance + recipient_balance,
    });

    try ip.state.putAccount(ip.tx.to, .{
        .balance = 0,
    });

    try ip.state.selfDestruct(ip.tx.to);
    ip.status = .success;
}
