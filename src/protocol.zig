//! Binds a `Definition` value into the runtime dispatch surface.
//!
//! `Protocol` turns a fork-config value (`definition.zig`) into the bound
//! namespace the interpreter, executor, and VM dispatch through: instruction
//! tables, transaction rules, support window, and revision model.

const definition = @import("./definition.zig");
const opcode_info = @import("./opcode.zig");

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

pub fn assertValidDefinition(comptime definition_value: anytype) void {
    validate.assertValidDefinition(definition.Bound(definition_value));
}

pub fn assertValidProtocolDefinition(comptime definition_value: anytype) void {
    validate.assertValidProtocolDefinition(definition.Bound(definition_value));
}

pub const RevisionModel = support.Model;
pub const DispatchEntry = dispatcher.DispatchEntry;
pub const DispatchTable = dispatcher.DispatchTable;
pub const DispatchConfig = dispatcher.DispatchConfig;
pub const ExecutionOverride = dispatcher.ExecutionOverride;
pub const ExecutionTarget = dispatcher.ExecutionTarget;
pub const HotColdDispatch = dispatcher.HotColdDispatch;
pub const InstructionContext = instruction.Context;
pub const OpInfo = opcode_info.OpInfo;
pub const OpcodeTier = support.OpcodeTier;
pub const Resolution = support.Resolution;
pub const ProtocolWithDispatch = binding.ProtocolWithDispatch;
pub const StaticGas = dispatcher.StaticGas;
pub const StaticGasBand = support.StaticGasBand;
pub const StaticGasBands = support.StaticGasBands;
pub const resolveDispatchTable = dispatcher.resolveDispatchTable;
pub const RevisionId = support.RevisionId;
pub const revisionId = support.revisionId;
pub const decodeRevision = support.decodeRevision;
pub const revisionSupported = support.revisionSupported;
pub const assertRevisionSupported = support.assertRevisionSupported;
pub const revisionIdForProtocol = support.revisionIdForProtocol;
pub const decodeRevisionForProtocol = support.decodeRevisionForProtocol;

/// Bind a protocol definition to one concrete support window.
pub fn Protocol(
    comptime definition_value: anytype,
    comptime support_window: definition.Bound(definition_value).Support,
) type {
    return ProtocolWithDispatch(definition_value, support_window, .{});
}

test {
    _ = @import("./protocol/test.zig");
}
