pub const evmc = @cImport({
    @cInclude("evmc/evmc.h");
});
const std = @import("std");
const evmz = @import("../evm.zig");

comptime {
    if (evmc.EVMC_ABI_VERSION != 13) {
        @compileError("EVMC ABI changed; update the evmz EVMC adapter");
    }
}

pub fn toEvmcAddress(addr: ?evmz.Address) evmc.evmc_address {
    return evmc.evmc_address{
        .bytes = if (addr) |a| a else evmz.addr(0),
    };
}

pub fn fromEvmcAddress(addr: evmc.evmc_address) evmz.Address {
    return addr.bytes;
}

pub fn fromEvmcBytes32(b: evmc.evmc_bytes32) u256 {
    return std.mem.readInt(u256, &b.bytes, .big);
}

pub const max_blob_hashes: usize = @intCast(evmz.Evm.transaction_policy.transaction.blobSchedule(.amsterdam).?.max);

pub fn toEvmcBytes32(value: ?u256) evmc.evmc_bytes32 {
    var result = std.mem.zeroes(evmc.evmc_bytes32);
    std.mem.writeInt(u256, &result.bytes, value orelse 0, .big);
    return result;
}

pub fn callKindFromEvmc(kind: evmc.evmc_call_kind) !evmz.Host.CallKind {
    return switch (kind) {
        evmc.EVMC_CALL => .call,
        evmc.EVMC_DELEGATECALL => .delegatecall,
        evmc.EVMC_CALLCODE => .callcode,
        evmc.EVMC_CREATE => .create,
        evmc.EVMC_CREATE2 => .create2,
        else => error.InvalidCallKind,
    };
}

pub fn evmcInputData(input_data: [*c]const u8, input_size: usize) ![]const u8 {
    if (input_size == 0) return &.{};
    if (input_data == null) return error.InvalidInputData;
    return input_data[0..input_size];
}

pub fn fromEvmcBlobHashes(tx_context: evmc.evmc_tx_context, scratch: []u256) ![]const u256 {
    if (tx_context.blob_hashes_count == 0) return &.{};
    if (tx_context.blob_hashes == null) return error.InvalidBlobHashes;
    if (tx_context.blob_hashes_count > scratch.len) return error.TooManyBlobHashes;

    const out = scratch[0..tx_context.blob_hashes_count];
    for (out, 0..) |*hash, i| {
        hash.* = fromEvmcBytes32(tx_context.blob_hashes[i]);
    }
    return out;
}

pub fn toEvmcBlobHashes(blob_hashes: []const u256, scratch: []evmc.evmc_bytes32) ![]const evmc.evmc_bytes32 {
    if (blob_hashes.len == 0) return &.{};
    if (blob_hashes.len > scratch.len) return error.TooManyBlobHashes;

    const out = scratch[0..blob_hashes.len];
    for (blob_hashes, out) |hash, *evmc_hash| {
        evmc_hash.* = toEvmcBytes32(hash);
    }
    return out;
}

pub fn fromEvmcTxContext(tx_context: evmc.evmc_tx_context, blob_hashes: []u256) !evmz.Host.TxContext {
    return evmz.Host.TxContext{
        .base_fee = fromEvmcBytes32(tx_context.block_base_fee),
        .blob_base_fee = fromEvmcBytes32(tx_context.blob_base_fee),
        .blob_hashes = try fromEvmcBlobHashes(tx_context, blob_hashes),
        .chain_id = fromEvmcBytes32(tx_context.chain_id),
        .coinbase = fromEvmcAddress(tx_context.block_coinbase),
        .gas_limit = try castNonNegative(u64, tx_context.block_gas_limit),
        .gas_price = fromEvmcBytes32(tx_context.tx_gas_price),
        .number = try castNonNegative(u64, tx_context.block_number),
        .slot_number = @intCast(tx_context.block_slot_number),
        .origin = fromEvmcAddress(tx_context.tx_origin),
        .prev_randao = fromEvmcBytes32(tx_context.block_prev_randao),
        .timestamp = try castNonNegative(u64, tx_context.block_timestamp),
    };
}

fn castNonNegative(comptime T: type, value: anytype) !T {
    return std.math.cast(T, value) orelse error.InvalidTxContext;
}
