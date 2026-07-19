//! Binds authored definition values into per-layer runtime surfaces.
//!
//! Each layer binds directly above the one below it: `ExecutionProtocol`
//! turns an execution definition into the dispatch namespace the interpreter
//! and executor consume (instruction tables, support window, revision model);
//! `TransactionProtocol` binds transaction policy above it; `BlockProtocol`
//! binds block sequencing hooks above that. There is no composed all-domain
//! protocol namespace.

const definition = @import("./definition.zig");

const types = @import("./protocol/types.zig");
const validate = @import("./protocol/validate.zig");
pub const dispatcher = @import("./protocol/dispatcher.zig");
pub const instruction = @import("./protocol/instruction.zig");
pub const transaction = @import("./protocol/transaction.zig");
pub const binding = @import("./protocol/binding.zig");
pub const support = @import("./protocol/support.zig");

pub const SelfDestructPolicy = types.SelfDestructPolicy;
pub const SelfDestructFinalization = types.SelfDestructFinalization;
pub const CallNewAccountGas = types.CallNewAccountGas;
pub const AccountAccessStatus = types.AccountAccessStatus;
pub const StorageStatus = types.StorageStatus;
pub const StorageGas = types.StorageGas;
pub const StorageStateGas = types.StorageStateGas;
pub const ValueTransferLog = types.ValueTransferLog;
pub const ValueTransferInput = types.ValueTransferInput;
pub const AuthorizationSuccessInput = types.AuthorizationSuccessInput;
pub const CallNewAccountInput = types.CallNewAccountInput;
pub const TopFrameValueTransferInput = types.TopFrameValueTransferInput;
pub const TopLevelDelegatedAccountAccessInput = types.TopLevelDelegatedAccountAccessInput;
pub const ChildGasInput = types.ChildGasInput;
pub const SelfDestructPolicyInput = types.SelfDestructPolicyInput;
pub const SelfDestructNewAccountInput = types.SelfDestructNewAccountInput;
pub const BeforeBlockContext = types.BeforeBlockContext;
pub const BlockHookInput = types.BlockHookInput;
pub const BlockSystemCall = types.BlockSystemCall;
pub const BlockSystemCalls = types.BlockSystemCalls;
pub const BeforeTransactionContext = types.BeforeTransactionContext;
pub const BlockTransactionStatus = types.BlockTransactionStatus;
pub const AfterTransactionContext = types.AfterTransactionContext;
pub const FinalizeBlockContext = types.FinalizeBlockContext;
pub const FinalizeSystemCall = types.FinalizeSystemCall;
pub const FinalizeSystemCalls = types.FinalizeSystemCalls;
pub const DelegatedAccountAccess = types.DelegatedAccountAccess;
pub const AuthorizationGasAdjustment = types.AuthorizationGasAdjustment;
pub const ChildGas = types.ChildGas;

/// Assert the full execution-layer contract for one execution definition:
/// dispatch surface, precompile domain, and interpreter dynamic-gas hooks.
pub fn assertExecutionContract(comptime execution_definition: anytype) void {
    validate.assertExecutionContract(definition.BoundExecution(execution_definition));
}

/// Assert the dispatch and precompile contract for one execution definition.
pub fn assertDispatchContract(comptime execution_definition: anytype) void {
    validate.assertDispatchContract(definition.BoundExecution(execution_definition));
}

/// Assert one transaction definition's preparation contract over revision `R`.
pub fn assertTransactionContract(comptime R: type, comptime transaction_definition: anytype) void {
    validate.assertTransactionContract(R, transaction_definition);
}

pub const DispatchEntry = dispatcher.DispatchEntry;
pub const ExecutionTarget = dispatcher.ExecutionTarget;
pub const OpcodeTier = support.OpcodeTier;
pub const Resolution = support.Resolution;
pub const ExecutionProtocol = binding.ExecutionProtocol;
pub const TransactionProtocol = binding.TransactionProtocol;
pub const BlockProtocol = binding.BlockProtocol;
pub const StaticGas = dispatcher.StaticGas;
pub const RevisionId = support.RevisionId;
pub const revisionId = support.revisionId;
pub const revisionIdForProtocol = support.revisionIdForProtocol;
pub const decodeRevisionForProtocol = support.decodeRevisionForProtocol;

test {
    _ = @import("./protocol/test.zig");
}
