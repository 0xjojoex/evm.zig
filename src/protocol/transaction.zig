const tx = @import("../transaction/types.zig");

pub fn For(comptime Definition: type) type {
    const DefinitionTransaction = Definition.transaction;

    return struct {
        const Self = @This();

        /// Engine-owned transaction value used by every Definition-backed VM.
        pub const Value = tx.Transaction;
        /// Read-only projection consumed by validation, gas, and preparation.
        pub const View = tx.TransactionView;
        /// Reason a transaction is rejected during pre-execution validation.
        pub const ValidationError = DefinitionTransaction.ValidationError;

        pub fn view(value: Value) View {
            return tx.transactionView(value);
        }

        pub fn prepare(comptime Protocol: type, input: tx.PrepareInput(Protocol)) !tx.PrepareResult(Protocol) {
            return DefinitionTransaction.Preparation.For(Protocol).prepare(input);
        }

        comptime {
            _ = Self.Value;
            _ = Self.View;
            _ = Self.ValidationError;
        }
    };
}
