const tx = @import("../transaction/types.zig");

/// Bind the engine transaction facts for one `TransactionConfig(R)` value.
pub fn For(comptime transaction_config: anytype) type {
    return struct {
        /// Engine-owned transaction value used by every definition-backed VM.
        pub const Value = tx.Transaction;
        /// Read-only projection consumed by validation, gas, and preparation.
        pub const View = tx.TransactionView;
        /// Reason a transaction is rejected during pre-execution validation.
        pub const ValidationError = transaction_config.ValidationError;

        pub fn view(value: Value) View {
            return tx.transactionView(value);
        }

        pub fn prepare(
            comptime Protocol: type,
            policy: anytype,
            input: tx.PrepareInput(Protocol),
        ) !tx.PrepareResult(Protocol) {
            const Policy = @TypeOf(policy.*);
            return (transaction_config.Preparation.Runtime(Protocol, Policy){
                .policy = policy,
            }).prepare(input);
        }
    };
}
