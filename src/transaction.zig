//! EVM transaction types, gas accounting, and preparation.

const std = @import("std");

pub const blob = @import("./transaction/blob.zig");
pub const authorization = @import("./transaction/authorization.zig");
pub const gas = @import("./transaction/gas.zig");
pub const settlement = @import("./transaction/settlement.zig");
pub const type_id = @import("./transaction/type_id.zig");
pub const envelope = @import("./transaction/envelope.zig");
pub const raw = @import("./transaction/raw.zig");
pub const signing = @import("./transaction/signing.zig");
const transaction = @import("./transaction/types.zig");
pub const transition = @import("./transaction/transition.zig");
pub const validation = @import("./transaction/validation.zig");
pub const program = @import("./transaction/program.zig");

pub const AccessListCounts = transaction.AccessListCounts;
pub const BlobParams = blob.BlobParams;
pub const BlobSchedule = blob.BlobSchedule;
pub const ExcessBlobGasInput = blob.ExcessBlobGasInput;
pub const TxKind = transaction.TxKind;
pub const SenderCodeKind = transaction.SenderCodeKind;
pub const IntrinsicGasOptions = gas.IntrinsicGasOptions;
pub const FloorGasInput = gas.FloorGasInput;
pub const GasCharge = gas.GasCharge;
pub const InitialGas = gas.InitialGas;
pub const GasPlan = gas.GasPlan;
pub const AccessListEntry = transaction.AccessListEntry;
pub const AuthorizationTuple = transaction.AuthorizationTuple;
pub const AuthorizationSuccessInput = authorization.SuccessInput;
pub const AuthorizationGasAdjustment = authorization.GasAdjustment;
pub const FeeFields = transaction.FeeFields;
pub const Transaction = transaction.Transaction;
pub const TransactionView = transaction.TransactionView;
pub const Env = transaction.Env;
pub const PreparationAccount = transaction.PreparationAccount;
pub const PreparationStateAccess = transaction.PreparationStateAccess;
pub const PreparationBlockProgress = transaction.PreparationBlockProgress;
pub const TransactionScope = transaction.TransactionScope;
pub const FeeInput = settlement.FeeInput;
pub const ExecutionGasResult = settlement.ExecutionGasResult;
pub const BlockGas = settlement.BlockGas;
pub const ResultGas = settlement.ResultGas;
pub const SenderRecovery = signing.SenderRecovery;
pub const SenderRecoveryError = signing.SenderRecoveryError;

pub const transactionView = transaction.transactionView;
pub const effectiveGasPrice = transaction.effectiveGasPrice;
// The opcode-visible context is projected by `Env.executionContext`, so there is
// no free-function form to re-export here.
pub const executionRequest = transaction.executionRequest;
pub const accessListCounts = gas.accessListCounts;
pub const fakeExponential = blob.fakeExponential;
pub const checkedGasCost = settlement.checkedGasCost;
pub const Prepared = transaction.Prepared;
pub const PrepareInput = transaction.PrepareInput;
pub const PrepareResult = transaction.PrepareResult;
pub const recoverSender = signing.recoverSender;
pub const signingHash = signing.signingHash;
pub const recoverAuthorizationSigner = signing.recoverAuthorizationSigner;
pub const TransitionOutcomeType = program.TransitionOutcomeType;
pub const TransactOutcomeType = program.TransactOutcomeType;
pub const GasRuntime = gas.Runtime;
pub const SettlementRuntime = settlement.Runtime;

test {
    std.testing.refAllDecls(@This());
}
