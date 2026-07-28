//! Normalized stateless validation input.
//!
//! This model contains Ethereum execution facts and proof material only. Wire
//! schema ids, fixture fields, and runtime framing are adapter concerns.

const address = @import("../address.zig");
const block_stf = @import("../eth/block_stf.zig");
const Withdrawal = @import("../eth/Withdrawal.zig");
const transaction = @import("../transaction.zig");

pub const Witness = struct {
    state: []const []const u8 = &.{},
    codes: []const []const u8 = &.{},
    headers: []const []const u8 = &.{},
};

/// Execution payload and Engine API claims after wire-specific normalization.
pub const Block = struct {
    parent_hash: [32]u8,
    fee_recipient: address.Address,
    state_root: [32]u8,
    receipts_root: [32]u8,
    logs_bloom: [256]u8,
    prev_randao: u256,
    number: u64,
    gas_limit: u64,
    gas_used: u64,
    timestamp: u64,
    extra_data: []const u8,
    base_fee_per_gas: u256,
    block_hash: [32]u8,
    /// Transactions authenticated and decoded by the wire adapter. Original
    /// envelopes remain attached for transaction-root reconstruction.
    transactions: []const block_stf.TransactionInput = &.{},
    withdrawals: []const Withdrawal = &.{},
    blob_gas_used: ?u64 = null,
    excess_blob_gas: ?u64 = null,
    versioned_hashes: []const [32]u8 = &.{},
    parent_beacon_block_root: ?[32]u8 = null,
    execution_requests: []const []const u8 = &.{},
    block_access_list: ?[]const u8 = null,
    slot_number: u64 = 0,
};

pub const Input = struct {
    /// Transaction replay domain and `CHAINID` opcode value.
    chain_id: u256,
    blob_schedule: ?transaction.BlobSchedule = null,
    /// The block number and timestamp live here as execution/header facts, not
    /// as fork-selection configuration.
    block: Block,
    witness: Witness,
};
