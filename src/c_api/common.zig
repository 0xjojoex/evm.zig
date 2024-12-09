const evmc = @cImport({
    @cInclude("evmc.h");
});
const std = @import("std");
const evmz = @import("../evm.zig");

pub fn toEvmcAddress(addr: ?evmz.Address) evmc.evmc_address {
    return evmc.evmc_address{
        .bytes = if (addr) |a| a else evmz.addr(0),
    };
}

pub fn fromEvmcAddress(addr: evmc.evmc_address) evmz.Address {
    return addr.bytes;
}

pub fn fromEvmcBytes32(b: evmc.evmc_bytes32) u256 {
    return @bitCast(b.bytes);
}

pub fn toEvmcBytes32(value: ?u256) [*c]evmc.evmc_bytes32 {
    return @ptrCast(@constCast(&evmc.evmc_bytes32{
        .bytes = if (value) |v| @bitCast(v) else std.mem.zeroes([32]u8),
    }));
}

pub fn fromEvmcTxContext(tx_context: evmc.evmc_tx_context) evmz.Host.TxContext {
    return evmz.Host.TxContext{
        .base_fee = fromEvmcBytes32(tx_context.block_base_fee),
        .blob_base_fee = fromEvmcBytes32(tx_context.block_base_fee),
        // .blob_hashes = tx_context.blob_hashes.*,
        .blob_hashes = &.{},
        .chain_id = fromEvmcBytes32(tx_context.chain_id),
        .coinbase = fromEvmcAddress(tx_context.block_coinbase),
        .gas_limit = @intCast(tx_context.block_gas_limit),
        .gas_price = fromEvmcBytes32(tx_context.tx_gas_price),
        .number = @intCast(tx_context.block_number),
        .origin = fromEvmcAddress(tx_context.tx_origin),
        .prev_randao = fromEvmcBytes32(tx_context.block_prev_randao),
        .timestamp = @intCast(tx_context.block_timestamp),
    };
}
