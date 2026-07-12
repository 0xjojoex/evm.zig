//! Internal conversion at the concrete execution-context / host ABI boundary.

const std = @import("std");
const execution = @import("../execution.zig");
const Host = @import("../Host.zig");

pub fn fromHost(context: Host.TxContext) execution.ExecutionContext {
    return .{
        .chain = .{ .chain_id = context.chain_id },
        .block = .{
            .coinbase = context.coinbase,
            .number = context.number,
            .slot_number = context.slot_number,
            .timestamp = context.timestamp,
            .gas_limit = context.gas_limit,
            .difficulty_or_prev_randao = context.prev_randao,
            .base_fee = context.base_fee,
            .blob_base_fee = context.blob_base_fee,
        },
        .transaction = .{
            .origin = context.origin,
            .gas_price = context.gas_price,
            .blob_hashes = context.blob_hashes,
        },
    };
}

pub fn toHost(context: execution.ExecutionContext) Host.TxContext {
    return .{
        .chain_id = context.chain.chain_id,
        .gas_price = context.transaction.gas_price,
        .origin = context.transaction.origin,
        .coinbase = context.block.coinbase,
        .number = context.block.number,
        .slot_number = context.block.slot_number,
        .timestamp = context.block.timestamp,
        .gas_limit = context.block.gas_limit,
        .prev_randao = context.block.difficulty_or_prev_randao,
        .base_fee = context.block.base_fee,
        .blob_base_fee = context.block.blob_base_fee,
        .blob_hashes = context.transaction.blob_hashes,
    };
}

pub fn eql(a: execution.ExecutionContext, b: execution.ExecutionContext) bool {
    var a_transaction = a.transaction;
    var b_transaction = b.transaction;
    a_transaction.blob_hashes = &.{};
    b_transaction.blob_hashes = &.{};

    return std.meta.eql(a.chain, b.chain) and
        std.meta.eql(a.block, b.block) and
        std.meta.eql(a_transaction, b_transaction) and
        std.mem.eql(u256, a.transaction.blob_hashes, b.transaction.blob_hashes);
}

test "execution context is the lossless host context authority" {
    const blob_hashes = [_]u256{ 41, 43 };
    const expected = Host.TxContext{
        .chain_id = 7,
        .gas_price = 11,
        .origin = [_]u8{0x11} ** 20,
        .coinbase = [_]u8{0x22} ** 20,
        .number = 13,
        .slot_number = 17,
        .timestamp = 19,
        .gas_limit = 23,
        .prev_randao = 29,
        .base_fee = 31,
        .blob_base_fee = 37,
        .blob_hashes = &blob_hashes,
    };

    try std.testing.expectEqualDeep(expected, toHost(fromHost(expected)));
}

test "context equality compares borrowed blob values rather than slice identity" {
    const a_hashes = [_]u256{ 41, 43 };
    const b_hashes = [_]u256{ 41, 43 };
    const a = fromHost(.{
        .chain_id = 7,
        .gas_price = 11,
        .origin = [_]u8{0x11} ** 20,
        .coinbase = [_]u8{0x22} ** 20,
        .number = 13,
        .timestamp = 19,
        .gas_limit = 23,
        .prev_randao = 29,
        .base_fee = 31,
        .blob_base_fee = 37,
        .blob_hashes = &a_hashes,
    });
    var b = a;
    b.transaction.blob_hashes = &b_hashes;

    try std.testing.expect(eql(a, b));
    b.chain.chain_id = 8;
    try std.testing.expect(!eql(a, b));
}
