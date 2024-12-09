const std = @import("std");
const Interpreter = @import("../Interpreter.zig");
const evmz = @import("../evm.zig");
const instruction = evmz.instruction;
const Address = evmz.Address;
const CallFrame = Interpreter.CallFrame;

pub fn gas(frame: *CallFrame) !void {
    const g: u64 = @intCast(frame.gas_left);
    const gas_left = @as(u256, g);
    try frame.stack.push(gas_left);
}

pub fn address(frame: *CallFrame) !void {
    try frame.stack.push(@byteSwap(@as(u160, @bitCast(frame.msg.recipient))));
}

pub fn caller(frame: *CallFrame) !void {
    try frame.stack.push(@byteSwap(@as(u160, @bitCast(frame.msg.sender))));
}

pub fn origin(frame: *CallFrame) !void {
    const tx_context = try frame.getTxContext();
    try frame.stack.push(@byteSwap(@as(u160, @bitCast(tx_context.origin))));
}

pub fn gasprice(frame: *CallFrame) !void {
    const tx_context = try frame.getTxContext();
    try frame.stack.push(tx_context.gas_price);
}

pub fn basefee(frame: *CallFrame) !void {
    const tx_context = try frame.getTxContext();
    try frame.stack.push(tx_context.base_fee);
}

pub fn coinbase(frame: *CallFrame) !void {
    const tx_context = try frame.getTxContext();
    try frame.stack.push(@byteSwap(@as(u160, @bitCast(tx_context.coinbase))));
}

pub fn timestamp(frame: *CallFrame) !void {
    const tx_context = try frame.getTxContext();
    try frame.stack.push(tx_context.timestamp);
}

pub fn number(frame: *CallFrame) !void {
    const tx_context = try frame.getTxContext();
    try frame.stack.push(tx_context.number);
}

pub fn prevrandao(frame: *CallFrame) !void {
    const tx_context = try frame.getTxContext();
    try frame.stack.push(tx_context.prev_randao);
}

pub fn gaslimit(frame: *CallFrame) !void {
    const tx_context = try frame.getTxContext();
    try frame.stack.push(tx_context.gas_limit);
}

pub fn chainid(frame: *CallFrame) !void {
    const tx_context = try frame.getTxContext();
    try frame.stack.push(tx_context.chain_id);
}

pub fn blockhash(frame: *CallFrame) !void {
    const block_number: u256 = try frame.stack.pop();

    const tx_context = try frame.getTxContext();

    if (block_number > tx_context.number + 256) {
        const block_hash = try frame.host.getBlockHash(block_number);
        try frame.stack.push(block_hash);
    } else {
        try frame.stack.push(0);
    }
}

pub fn balance(frame: *CallFrame) !void {
    const target_address_word = try frame.stack.pop();
    const target_address: Address = @bitCast(@byteSwap(@as(u160, @intCast(target_address_word))));
    if (frame.spec.isImpl(.berlin) and try frame.host.accessAccount(target_address) == .cold) {
        frame.trackGas(instruction.cold_account_access_gas);
    }
    const address_balance = try frame.host.getBalance(target_address);
    try frame.stack.push(address_balance);
}

pub fn callvalue(frame: *CallFrame) !void {
    try frame.stack.push(frame.msg.value);
}

pub fn calldataload(frame: *CallFrame) !void {
    const offset: usize = @intCast(try frame.stack.pop());
    var buffer: [32]u8 = [_]u8{0} ** 32;

    for (0..32) |i| {
        if (offset + i < frame.msg.input_data.len) {
            buffer[i] = frame.msg.input_data[offset + i];
        }
    }

    try frame.stack.push(@byteSwap(@as(u256, @bitCast(buffer))));
}

pub fn calldatasize(frame: *CallFrame) !void {
    try frame.stack.push(frame.msg.input_data.len);
}

pub fn calldatacopy(frame: *CallFrame) !void {
    const dest_offset: usize = @intCast(try frame.stack.pop());
    const offset: usize = @intCast(try frame.stack.pop());
    const size: usize = @intCast(try frame.stack.pop());

    const expand_cost = try frame.memory.expand(dest_offset, size);
    frame.trackGas(expand_cost);

    // refactor to write bytes
    for (0..size) |i| {
        if (offset + i < frame.msg.input_data.len) {
            frame.memory.bytes.items[dest_offset + i] = frame.msg.input_data[offset + i];
        } else {
            frame.memory.bytes.items[dest_offset + i] = 0;
        }
    }
}

pub fn codesize(frame: *CallFrame) !void {
    try frame.stack.push(frame.bytes.len);
}

pub fn codecopy(frame: *CallFrame) !void {
    const dest_offset: usize = @intCast(try frame.stack.pop());
    const offset: usize = @intCast(try frame.stack.pop());
    const size: usize = @intCast(try frame.stack.pop());

    const expand_cost = try frame.memory.expand(dest_offset, size);
    frame.trackGas(expand_cost);

    for (0..size) |i| {
        if (offset + i < frame.bytes.len) {
            frame.memory.bytes.items[dest_offset + i] = frame.bytes[offset + i];
        }
    }
}

pub fn extcodesize(frame: *CallFrame) !void {
    const target_address = try frame.stack.pop();
    const size = try frame.host.getCodeSize(@bitCast(@byteSwap(@as(u160, @intCast(target_address)))));
    try frame.stack.push(size);
}

pub fn extcodecopy(frame: *CallFrame) !void {
    const address_word = try frame.stack.pop();
    const target_address: Address = @bitCast(@byteSwap(@as(u160, @intCast(address_word))));
    const dest_offset: usize = @intCast(try frame.stack.pop());
    const offset: usize = @intCast(try frame.stack.pop());
    const size: usize = @intCast(try frame.stack.pop());

    const buf = try frame.allocator.alloc(u8, size);
    defer frame.allocator.free(buf);
    @memset(buf[0..buf.len], 0);

    if (frame.spec.isImpl(.berlin) and try frame.host.accessAccount(target_address) == .cold) {
        frame.trackGas(instruction.cold_account_access_gas);
    }

    const code_len = try frame.host.copyCode(target_address, offset, buf);
    const expand_cost = try frame.memory.expand(dest_offset, code_len);
    frame.trackGas(expand_cost);

    try frame.memory.writeBytes(dest_offset, buf[0..]);
}

pub fn extcodehash(frame: *CallFrame) !void {
    const address_word = try frame.stack.pop();
    const target_address: Address = @bitCast(@byteSwap(@as(u160, @intCast(address_word))));
    if (frame.spec.isImpl(.berlin) and try frame.host.accessAccount(target_address) == .cold) {
        frame.trackGas(instruction.cold_account_access_gas);
    }
    const code_hash = try frame.host.getCodeHash(target_address);
    try frame.stack.push(code_hash);
}

pub fn selfbalance(frame: *CallFrame) !void {
    const address_balance = try frame.host.getBalance(frame.msg.recipient);
    try frame.stack.push(address_balance);
}

pub fn returndatasize(frame: *CallFrame) !void {
    try frame.stack.push(frame.return_data.len);
}

pub fn returndatacopy(frame: *CallFrame) !void {
    const dest_offset: usize = @intCast(try frame.stack.pop());
    const offset: usize = @intCast(try frame.stack.pop());
    const size: usize = @intCast(try frame.stack.pop());

    const expand_cost = try frame.memory.expand(dest_offset, size);
    frame.trackGas(expand_cost);

    try frame.memory.writeBytes(dest_offset, frame.return_data[offset .. offset + size]);
}

pub fn blobhash(frame: *CallFrame) !void {
    const index: usize = @intCast(try frame.stack.pop());
    const tx_context = try frame.getTxContext();

    if (tx_context.blob_hashes.len < index) {
        try frame.stack.push(0);
        return;
    } else {
        try frame.stack.push(tx_context.blob_hashes[index]);
    }
}

pub fn blobbasefee(frame: *CallFrame) !void {
    const tx_context = try frame.getTxContext();
    try frame.stack.push(tx_context.blob_base_fee);
}
