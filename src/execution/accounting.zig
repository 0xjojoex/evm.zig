//! Frame-local gas arithmetic shared by bytecode and native execution.
//! Callers own the counters and implement trackGas, including their OOG transition.
//! Prices are resolved by the selected spec before entering these operations.

const std = @import("std");
const Host = @import("../Host.zig");

/// Settle one child exactly once. The child has already finalized its own scope.
/// gas_limit is the forwarded budget; state_gas_charged is the parent-side state
/// charge to restore if the attempt fails. Neither is reconstructed from output.
pub fn settleChild(self: anytype, gas_limit: i64, state_gas_charged: i64, child: Host.Result) bool {
    const succeeded = child.isSuccess();
    const gas_charged = self.trackGas(gas_limit - @max(child.gas_left, 0));
    self.gas_reservoir = child.gas_reservoir;
    self.state_gas_spent +|= child.state_gas_spent;
    self.state_gas_from_gas_left +|= child.state_gas_from_gas_left;
    if (succeeded) {
        repayStateGasSpill(self);
    } else {
        refillStateGas(self, state_gas_charged);
    }
    if (!gas_charged) return false;
    if (succeeded) self.gas_refund += child.gas_refund;
    return true;
}

/// Charge from the reservoir first, then regular gas. Failure changes no state
/// counters; trackGas performs the caller's exceptional halt.
pub fn trackStateGas(self: anytype, gas: i64) bool {
    if (gas <= 0) return true;
    const from_reservoir = @min(@max(self.gas_reservoir, 0), gas);
    const from_regular = gas - from_reservoir;
    if (!self.trackGas(from_regular)) return false;
    self.gas_reservoir -= from_reservoir;
    self.state_gas_from_gas_left +|= from_regular;
    self.state_gas_spent +|= gas;
    return true;
}

/// Credits repay regular-gas spill before increasing the reservoir. Net state
/// gas is signed because a child can release state charged by an ancestor.
pub inline fn refillStateGas(self: anytype, gas: i64) void {
    if (gas <= 0) return;
    const to_regular = @min(self.state_gas_from_gas_left, gas);
    self.gas_left +|= to_regular;
    self.state_gas_from_gas_left -= to_regular;
    self.gas_reservoir +|= gas - to_regular;
    self.state_gas_spent -|= gas;
}

inline fn repayStateGasSpill(self: anytype) void {
    std.debug.assert(self.gas_reservoir >= 0);
    std.debug.assert(self.state_gas_from_gas_left >= 0);
    const repayment = @min(self.gas_reservoir, self.state_gas_from_gas_left);
    self.gas_left += repayment;
    self.gas_reservoir -= repayment;
    self.state_gas_from_gas_left -= repayment;
    std.debug.assert(self.gas_reservoir == 0 or self.state_gas_from_gas_left == 0);
}
