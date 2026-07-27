/// Initial execution gas state consumed by the interpreter.
///
/// `regular_left` is the value visible to the `GAS` opcode. `reservoir` is an
/// additional family-resolved budget, currently used by Amsterdam state gas.
///
/// Three distinct quantities in the spec are all spelled "gas". Keep them apart:
///
///   - `transaction.Env.gas_limit` — the *block's* limit, read by GASLIMIT.
///     Spec `BlockEnvironment.block_gas_limit`.
///   - `transaction.TransactionView.gas_limit` — the signed transaction field.
///     Spec `tx.gas`.
///   - `ExecutionGas.regular_left` — the top frame's *budget*, which is
///     `TransactionView.gas_limit - intrinsic_gas` (see `transaction/gas.zig`
///     `gasPlan`). Spec `TransactionEnvironment.gas`.
///
/// Only the first two are limits, and neither equals this budget. That is why
/// `ExecutionContext` carries no transaction gas field at all: a limit is a
/// caller-supplied constant, a budget decrements as the frame runs.
pub const ExecutionGas = struct {
    regular_left: u64,
    reservoir: u64 = 0,

    /// Scope-opening gas for a transaction included without payload execution.
    pub const none: ExecutionGas = .{ .regular_left = 0 };

    pub fn legacy(regular_left: u64) ExecutionGas {
        return .{ .regular_left = regular_left };
    }
};
