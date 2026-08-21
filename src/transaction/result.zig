//! Concrete Ethereum transaction result carriers shared by VM and block code.

const address = @import("../address.zig");
const execution = @import("../execution.zig");
const state = @import("../state.zig");
const transaction = @import("../transaction.zig");

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
};

/// Borrowed transaction receipt view for client and fixture receipt builders.
pub const Receipt = struct {
    status: execution.Status,
    gas_used: u64 = 0,
    cumulative_gas_used: u64 = 0,
    created_address: ?address.Address = null,
    logs: state.LogBuffer.View = .empty,
};
