//! Top-frame state gas arithmetic: the reservoir/regular split and how a
//! charge is reconciled back into the result once execution terminates.
//!
//! The fork policy that decides *how much* to charge stays with the executor;
//! this file only knows how to spend it and how to give it back.

const std = @import("std");

const ExecutionGas = @import("../evm.zig").execution.ExecutionGas;
const ExecutionResult = @import("../evm.zig").execution.ExecutionResult;

pub const Charge = struct {
    spent: i64 = 0,
    from_regular: i64 = 0,
    out_of_gas: bool = false,
};

/// Draw `amount` from the reservoir first, then from regular gas.
pub fn charge(gas: *ExecutionGas, amount: i64) Charge {
    if (amount <= 0) return .{};

    const total: u64 = @intCast(amount);
    const from_reservoir = @min(gas.reservoir, total);
    const from_regular = total - from_reservoir;
    if (from_regular > gas.regular_left) return .{ .out_of_gas = true };

    gas.reservoir -= from_reservoir;
    gas.regular_left -= from_regular;
    return .{
        .spent = amount,
        .from_regular = @intCast(from_regular),
    };
}

/// Fold a charge into a terminated result: success accounts it as state gas,
/// every rollback status refunds it.
pub fn finish(result: *ExecutionResult, spent: Charge) void {
    if (spent.spent == 0) return;
    std.debug.assert(spent.from_regular >= 0);
    std.debug.assert(spent.from_regular <= spent.spent);
    const from_reservoir = spent.spent - spent.from_regular;
    switch (result.outcome.status) {
        .success => {
            result.state_gas_spent +|= spent.spent;
            result.state_gas_from_gas_left +|= spent.from_regular;
        },
        .revert => {
            result.gas_reservoir +|= from_reservoir;
            result.gas_left +|= spent.from_regular;
        },
        .invalid, .out_of_gas => {
            result.gas_reservoir +|= from_reservoir;
        },
    }
}
