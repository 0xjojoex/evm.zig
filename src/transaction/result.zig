//! Concrete Ethereum transaction result carriers shared by VM and block code.

const address = @import("../address.zig");
const execution = @import("../execution.zig");
const state = @import("../state.zig");
const transaction = @import("../transaction.zig");
const frames = @import("frames.zig");

/// Execution payload for a transaction that passed validation and ran.
///
/// `output` is borrowed from the owning Executor and remains valid until its
/// next operation can replace call output.
pub const Execution = struct {
    status: execution.Status,
    /// Settled transaction gas: receipt gas, refund gas, and block contribution.
    gas: transaction.ResultGas = .{},
    output: []const u8 = &.{},
    created_address: ?address.Address = null,
    /// EIP-8141 outcome; null for every other kind. A frame transaction has no
    /// transaction-level status: `status` is `.success` for any included one
    /// and the frame receipts carry the per-frame results.
    frame: ?Frame = null,

    pub const Frame = struct {
        payer: address.Address,
        /// Borrowed from the Executor until its next transaction.
        receipts: []const frames.Receipt,
        /// What settlement paid: an L2 redirects these amounts as it does a
        /// standard transaction's fees.
        settlement: frames.Settlement,
    };
};

/// Borrowed transaction receipt view for client and fixture receipt builders.
pub const Receipt = struct {
    status: execution.Status,
    gas_used: u64 = 0,
    cumulative_gas_used: u64 = 0,
    created_address: ?address.Address = null,
    logs: state.LogBuffer.View = .empty,
    /// EIP-8141 receipt content; null for every other kind. Each frame
    /// receipt's `log_range` indexes `logs`.
    frame: ?Frame = null,

    pub const Frame = struct {
        payer: address.Address,
        receipts: []const frames.Receipt,
    };
};
