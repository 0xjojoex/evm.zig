//! EVM transaction types, gas accounting, and preparation.

const std = @import("std");

const blob_mod = @import("./transaction/blob.zig");
pub const authorization = @import("./transaction/authorization.zig");
const gas_mod = @import("./transaction/gas.zig");
const program_mod = @import("./transaction/program.zig");
const settlement_mod = @import("./transaction/settlement.zig");
pub const type_id = @import("./transaction/type_id.zig");
pub const envelope = @import("./transaction/envelope.zig");
pub const raw = @import("./transaction/raw.zig");
pub const signing = @import("./transaction/signing.zig");
const transaction_mod = @import("./transaction/types.zig");

pub const AccessListCounts = transaction_mod.AccessListCounts;
pub const BlobParams = blob_mod.BlobParams;
pub const ExcessBlobGasInput = blob_mod.ExcessBlobGasInput;
pub const TxKind = transaction_mod.TxKind;
pub const SenderCodeKind = transaction_mod.SenderCodeKind;
pub const IntrinsicGasOptions = gas_mod.IntrinsicGasOptions;
pub const FloorGasInput = gas_mod.FloorGasInput;
pub const GasCharge = gas_mod.GasCharge;
pub const InitialGas = gas_mod.InitialGas;
pub const GasPlan = gas_mod.GasPlan;
pub const AccessListEntry = transaction_mod.AccessListEntry;
pub const AuthorizationTuple = transaction_mod.AuthorizationTuple;
pub const AuthorizationSuccessInput = authorization.SuccessInput;
pub const AuthorizationGasAdjustment = authorization.GasAdjustment;
pub const FeeFields = transaction_mod.FeeFields;
pub const Transaction = transaction_mod.Transaction;
pub const TransactionView = transaction_mod.TransactionView;
pub const Env = transaction_mod.Env;
pub const PreparationAccount = transaction_mod.PreparationAccount;
pub const PreparationStateAccess = transaction_mod.PreparationStateAccess;
pub const PreparationBlockProgress = transaction_mod.PreparationBlockProgress;
pub const TransactionScope = transaction_mod.TransactionScope;
pub const FeeInput = settlement_mod.FeeInput;
pub const ExecutionGasResult = settlement_mod.ExecutionGasResult;
pub const BlockGas = settlement_mod.BlockGas;
pub const ResultGas = settlement_mod.ResultGas;
pub const SenderRecovery = signing.SenderRecovery;
pub const SenderRecoveryError = signing.SenderRecoveryError;

pub const transactionView = transaction_mod.transactionView;
pub const effectiveGasPrice = transaction_mod.effectiveGasPrice;
// The opcode-visible context is projected by `Env.executionContext`, so there is
// no free-function form to re-export here.
pub const executionRequest = transaction_mod.executionRequest;
pub const accessListCounts = gas_mod.accessListCounts;
pub const blobBaseFeeForParams = blob_mod.blobBaseFeeForParams;
pub const calcExcessBlobGasForParams = blob_mod.calcExcessBlobGasForParams;
pub const fakeExponential = blob_mod.fakeExponential;
pub const checkedGasCost = settlement_mod.checkedGasCost;
pub const Prepared = transaction_mod.Prepared;
pub const PrepareInput = transaction_mod.PrepareInput;
pub const PrepareResult = transaction_mod.PrepareResult;
pub const recoverSender = signing.recoverSender;
pub const signingHash = signing.signingHash;
pub const recoverAuthorizationSigner = signing.recoverAuthorizationSigner;
pub const TransitionOutcome = program_mod.TransitionOutcome;
pub const TransactOutcome = program_mod.TransactOutcome;
pub const GasRuntime = gas_mod.Runtime;
pub const SettlementRuntime = settlement_mod.Runtime;

test {
    std.testing.refAllDecls(@This());
}
