const tx = @import("../transaction/types.zig");
const transaction_prepare = @import("../eth/transaction_prepare.zig");
const transaction_validation = @import("../eth/transaction_validation.zig");

/// Fixed Ethereum transaction identity and preparation program. Families with
/// another transaction vocabulary compose it above the VM through `Program`.
pub const Ethereum = struct {
    pub const Value = tx.Transaction;
    pub const View = tx.TransactionView;
    pub const ValidationError = transaction_validation.ValidationError;

    pub fn view(value: Value) View {
        return tx.transactionView(value);
    }

    pub fn prepare(
        comptime Protocol: type,
        policy: anytype,
        input: tx.PrepareInput(Protocol),
    ) !tx.PrepareResult(Protocol) {
        const Policy = @TypeOf(policy.*);
        return (transaction_prepare.Runtime(Protocol, Policy){
            .policy = policy,
        }).prepare(input);
    }
};
