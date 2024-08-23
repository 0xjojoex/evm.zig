const std = @import("std");
const Interpreter = @import("../Interpreter.zig");
const evmz = @import("../evm.zig");
const Address = evmz.Address;

pub fn gas(ip: *Interpreter) !void {
    const gas_left = std.math.maxInt(u256); // TODO: after gas is implemented, get the actual gas left
    try ip.stack.push(gas_left);
}

pub fn address(ip: *Interpreter) !void {
    try ip.stack.push(@byteSwap(@as(u160, @bitCast(ip.msg.recipient))));
}

pub fn caller(ip: *Interpreter) !void {
    try ip.stack.push(@byteSwap(@as(u160, @bitCast(ip.msg.sender))));
}

pub fn origin(ip: *Interpreter) !void {
    const tx_context = try ip.host.getTxContext();
    try ip.stack.push(@byteSwap(@as(u160, @bitCast(tx_context.origin))));
}

pub fn gasprice(ip: *Interpreter) !void {
    const tx_context = try ip.getTxContext();
    try ip.stack.push(tx_context.gas_price);
}

pub fn basefee(ip: *Interpreter) !void {
    const tx_context = try ip.host.getTxContext();
    try ip.stack.push(tx_context.base_fee);
}

pub fn coinbase(ip: *Interpreter) !void {
    const tx_context = try ip.host.getTxContext();
    try ip.stack.push(@byteSwap(@as(u160, @bitCast(tx_context.coinbase))));
}

pub fn timestamp(ip: *Interpreter) !void {
    const tx_context = try ip.host.getTxContext();
    try ip.stack.push(tx_context.timestamp);
}

pub fn number(ip: *Interpreter) !void {
    const tx_context = try ip.host.getTxContext();
    try ip.stack.push(tx_context.number);
}

pub fn prevrandao(ip: *Interpreter) !void {
    const tx_context = try ip.host.getTxContext();
    try ip.stack.push(tx_context.prev_randao);
}

pub fn gaslimit(ip: *Interpreter) !void {
    const tx_context = try ip.host.getTxContext();
    try ip.stack.push(tx_context.gas_limit);
}

pub fn chainid(ip: *Interpreter) !void {
    const tx_context = try ip.host.getTxContext();
    try ip.stack.push(tx_context.chain_id);
}

pub fn blockhash(ip: *Interpreter) !void {
    const block_number: u256 = try ip.stack.pop();

    const tx_context = try ip.host.getTxContext();

    if (block_number > tx_context.number + 256) {
        const block_hash = try ip.host.getBlockHash(block_number);
        try ip.stack.push(block_hash);
    } else {
        try ip.stack.push(0);
    }
}

pub fn balance(ip: *Interpreter) !void {
    const target_address = try ip.stack.pop();
    const address_balance = try ip.host.getBalance(@bitCast(@byteSwap(@as(u160, @intCast(target_address)))));
    try ip.stack.push(address_balance);
}

pub fn callvalue(ip: *Interpreter) !void {
    try ip.stack.push(ip.msg.value);
}

pub fn calldataload(ip: *Interpreter) !void {
    const offset: usize = @intCast(try ip.stack.pop());
    var buffer: [32]u8 = [_]u8{0} ** 32;

    for (0..32) |i| {
        if (offset + i < ip.msg.input_data.len) {
            buffer[i] = ip.msg.input_data[offset + i];
        }
    }

    try ip.stack.push(@byteSwap(@as(u256, @bitCast(buffer))));
}

pub fn calldatasize(ip: *Interpreter) !void {
    try ip.stack.push(ip.msg.input_data.len);
}

pub fn calldatacopy(ip: *Interpreter) !void {
    const dest_offset: usize = @intCast(try ip.stack.pop());
    const offset: usize = @intCast(try ip.stack.pop());
    const size: usize = @intCast(try ip.stack.pop());

    try ip.memory.expand(dest_offset, size);

    // refactor to write bytes
    for (0..size) |i| {
        if (offset + i < ip.msg.input_data.len) {
            ip.memory.bytes.items[dest_offset + i] = ip.msg.input_data[offset + i];
        } else {
            ip.memory.bytes.items[dest_offset + i] = 0;
        }
    }
}

pub fn codesize(ip: *Interpreter) !void {
    try ip.stack.push(ip.bytes.len);
}

pub fn codecopy(ip: *Interpreter) !void {
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

pub fn extcodesize(ip: *Interpreter) !void {
    const target_address = try ip.stack.pop();
    const size = try ip.host.getCodeSize(@bitCast(@byteSwap(@as(u160, @intCast(target_address)))));
    try ip.stack.push(size);
}

pub fn extcodecopy(ip: *Interpreter) !void {
    const address_word = try ip.stack.pop();
    const target_address: Address = @bitCast(@byteSwap(@as(u160, @intCast(address_word))));
    const dest_offset: usize = @intCast(try ip.stack.pop());
    const offset: usize = @intCast(try ip.stack.pop());
    const size: usize = @intCast(try ip.stack.pop());

    const buf = try ip.allocator.alloc(u8, size);
    defer ip.allocator.free(buf);
    @memset(buf[0..buf.len], 0);

    const code_len = try ip.host.copyCode(target_address, offset, buf);
    try ip.memory.expand(dest_offset, code_len);

    try ip.memory.writeBytes(dest_offset, buf[0..]);
}

pub fn extcodehash(ip: *Interpreter) !void {
    const address_word = try ip.stack.pop();
    const target_address: Address = @bitCast(@byteSwap(@as(u160, @intCast(address_word))));
    const code_hash = try ip.host.getCodeHash(target_address);
    try ip.stack.push(code_hash);
}

pub fn selfbalance(ip: *Interpreter) !void {
    const address_balance = try ip.host.getBalance(ip.msg.recipient);
    try ip.stack.push(address_balance);
}

pub fn returndatasize(ip: *Interpreter) !void {
    try ip.stack.push(ip.return_data.len);
}

pub fn returndatacopy(ip: *Interpreter) !void {
    const dest_offset: usize = @intCast(try ip.stack.pop());
    const offset: usize = @intCast(try ip.stack.pop());
    const size: usize = @intCast(try ip.stack.pop());

    try ip.memory.expand(dest_offset, size);

    try ip.memory.writeBytes(dest_offset, ip.return_data[offset .. offset + size]);
}
