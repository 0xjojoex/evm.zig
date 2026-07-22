//! Shared semantic carrier types and resolved revision/dispatch facts.
//!
//! Ethereum-family construction lives under `eth`; definition binding remains
//! private engine machinery. Execution consumers use these domain-owned values
//! without depending on the assembly path that selected them.

const types = @import("./protocol/types.zig");
const dispatcher = @import("./protocol/dispatcher.zig");
const support = @import("./protocol/support.zig");

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
pub const CreateAccountStateGasInput = types.CreateAccountStateGasInput;
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

pub const DispatchEntry = dispatcher.DispatchEntry;
pub const ExecutionTarget = dispatcher.ExecutionTarget;
pub const OpcodeTier = support.OpcodeTier;
pub const Resolution = support.Resolution;
pub const StaticGas = dispatcher.StaticGas;
pub const RevisionId = support.RevisionId;
pub const revisionId = support.revisionId;
pub const revisionIdForProtocol = support.revisionIdForProtocol;
pub const decodeRevisionForProtocol = support.decodeRevisionForProtocol;

test {
    _ = @import("./protocol/test.zig");
}
