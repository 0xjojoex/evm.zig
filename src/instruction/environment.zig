const std = @import("std");
const Interpreter = @import("../Interpreter.zig");
const utils = @import("../utils.zig");

pub inline fn gas(ip: *Interpreter) !void {
    const gas_left = std.math.maxInt(u256); // TODO: after gas is implemented, get the actual gas left
    try ip.stack.push(gas_left);
}

pub inline fn address(ip: *Interpreter) !void {
    try ip.stack.push(@byteSwap(@as(u160, @bitCast(ip.tx.to))));
}

pub inline fn caller(ip: *Interpreter) !void {
    try ip.stack.push(@byteSwap(@as(u160, @bitCast(ip.tx.from))));
}

pub inline fn origin(ip: *Interpreter) !void {
    try ip.stack.push(@byteSwap(@as(u160, @bitCast(ip.tx.origin))));
}

pub inline fn gasprice(ip: *Interpreter) !void {
    try ip.stack.push(ip.tx.gas_price);
}

pub inline fn basefee(ip: *Interpreter) !void {
    try ip.stack.push(ip.block.base_fee);
}

pub inline fn coinbase(ip: *Interpreter) !void {
    try ip.stack.push(@byteSwap(@as(u160, @bitCast(ip.block.coinbase))));
}

pub inline fn timestamp(ip: *Interpreter) !void {
    try ip.stack.push(ip.block.timestamp);
}

pub inline fn number(ip: *Interpreter) !void {
    try ip.stack.push(ip.block.number);
}

pub inline fn prevrandao(ip: *Interpreter) !void {
    try ip.stack.push(ip.block.prev_randao);
}

pub inline fn gaslimit(ip: *Interpreter) !void {
    try ip.stack.push(ip.block.gas_limit);
}

pub inline fn chainid(ip: *Interpreter) !void {
    try ip.stack.push(ip.block.chain_id);
}

pub inline fn blockhash(ip: *Interpreter) !void {
    const block_number: u256 = try ip.stack.pop();

    if (block_number > ip.block.number + 256) {
        // TODO: implement blockhash
        try ip.stack.push(0);
    } else {
        try ip.stack.push(0);
    }
}

pub inline fn balance(ip: *Interpreter) !void {
    const target_address = try ip.stack.pop();
    const address_balance = try ip.state.getBalance(@bitCast(@byteSwap(@as(u160, @intCast(target_address)))));
    try ip.stack.push(address_balance);
}

pub inline fn callvalue(ip: *Interpreter) !void {
    try ip.stack.push(ip.tx.value);
}

pub inline fn calldataload(ip: *Interpreter) !void {
    const offset: usize = @intCast(try ip.stack.pop());
    var buffer: [32]u8 = [_]u8{0} ** 32;

    for (0..32) |i| {
        if (offset + i < ip.tx.data.len) {
            buffer[i] = ip.tx.data[offset + i];
        }
    }

    try ip.stack.push(utils.bytesToU256(buffer[0..]));
}

pub inline fn calldatasize(ip: *Interpreter) !void {
    try ip.stack.push(ip.tx.data.len);
}

pub inline fn calldatacopy(ip: *Interpreter) !void {
    const dest_offset: usize = @intCast(try ip.stack.pop());
    const offset: usize = @intCast(try ip.stack.pop());
    const size: usize = @intCast(try ip.stack.pop());

    try ip.memory.expand(dest_offset, size);

    // refactor to write bytes
    for (0..size) |i| {
        if (offset + i < ip.tx.data.len) {
            ip.memory.bytes.items[dest_offset + i] = ip.tx.data[offset + i];
        } else {
            ip.memory.bytes.items[dest_offset + i] = 0;
        }
    }
}

pub inline fn codesize(ip: *Interpreter) !void {
    try ip.stack.push(ip.bytes.len);
}

pub inline fn codecopy(ip: *Interpreter) !void {
    const dest_offset: usize = @intCast(try ip.stack.pop());
    const offset: usize = @intCast(try ip.stack.pop());
    const size: usize = @intCast(try ip.stack.pop());

    try ip.memory.expand(dest_offset, size);

    for (0..size) |i| {
        if (offset + i < ip.bytes.len) {
            ip.memory.bytes.items[dest_offset + i] = ip.bytes[offset + i];
        }
    }
}

pub inline fn extcodesize(ip: *Interpreter) !void {
    const target_address = try ip.stack.pop();
    const address_code = try ip.state.getCode(@bitCast(@byteSwap(@as(u160, @intCast(target_address)))));
    try ip.stack.push(address_code.len);
}

pub inline fn extcodecopy(ip: *Interpreter) !void {
    const target_address = try ip.stack.pop();
    const dest_offset: usize = @intCast(try ip.stack.pop());
    const offset: usize = @intCast(try ip.stack.pop());
    const size: usize = @intCast(try ip.stack.pop());

    const address_code = try ip.state.getCode(@bitCast(@byteSwap(@as(u160, @intCast(target_address)))));

    std.debug.print("extcodecopy: {x}", .{address_code});

    try ip.memory.expand(dest_offset, size);

    // refactor to write bytes
    for (0..size) |i| {
        if (offset + i < address_code.len) {
            ip.memory.bytes.items[dest_offset + i] = address_code[offset + i];
        } else {
            ip.memory.bytes.items[dest_offset + i] = 0;
        }
    }
}

pub inline fn extcodehash(ip: *Interpreter) !void {
    const target_address = try ip.stack.pop();
    const address_code = try ip.state.getCode(@bitCast(@byteSwap(@as(u160, @intCast(target_address)))));
    std.debug.print("extcodehash: {d}", .{address_code.len});
    if (address_code.len == 0) {
        try ip.stack.push(0);
        // try ip.stack.push(0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470);
    } else {
        var result: [32]u8 = undefined;
        std.crypto.hash.sha3.Keccak256.hash(address_code, &result, .{});
        const final_result = @byteSwap(@as(u256, @bitCast(result)));
        try ip.stack.push(final_result);
    }
}

pub inline fn selfbalance(ip: *Interpreter) !void {
    const address_balance = try ip.state.getBalance(ip.tx.to);
    try ip.stack.push(address_balance);
}

pub inline fn returndatasize(ip: *Interpreter) !void {
    try ip.stack.push(ip.return_data.len);
}

pub inline fn returndatacopy(ip: *Interpreter) !void {
    const dest_offset: usize = @intCast(try ip.stack.pop());
    const offset: usize = @intCast(try ip.stack.pop());
    const size: usize = @intCast(try ip.stack.pop());

    try ip.memory.expand(dest_offset, size);

    try ip.memory.writeBytes(dest_offset, ip.return_data[offset .. offset + size]);
}
