/// Initial execution gas state consumed by the interpreter.
///
/// `regular_left` is the value visible to the `GAS` opcode. `reservoir` is an
/// additional family-resolved budget, currently used by Amsterdam state gas.
pub const ExecutionGas = struct {
    regular_left: u64,
    reservoir: u64 = 0,

    /// Scope-opening gas for a transaction included without payload execution.
    pub const none: ExecutionGas = .{ .regular_left = 0 };

    pub fn legacy(regular_left: u64) ExecutionGas {
        return .{ .regular_left = regular_left };
    }
};
