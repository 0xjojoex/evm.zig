//! Protocol-neutral transaction types, gas accounting, and preparation.

const std = @import("std");

const blob_mod = @import("./transaction/blob.zig");
const gas_mod = @import("./transaction/gas.zig");
const gas_bound_plan = @import("./transaction/gas_bound_plan.zig");
const program_mod = @import("./transaction/program.zig");
const settlement_mod = @import("./transaction/settlement.zig");
pub const type_id = @import("./transaction/type_id.zig");
pub const envelope = @import("./transaction/envelope.zig");
pub const raw = @import("./transaction/raw.zig");
pub const signing = @import("./transaction/signing.zig");
const transaction_mod = @import("./transaction/types.zig");

pub const AccessListCounts = transaction_mod.AccessListCounts;
pub const BlobSchedule = blob_mod.BlobSchedule;
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
pub const FeeFields = transaction_mod.FeeFields;
pub const Transaction = transaction_mod.Transaction;
pub const TransactionView = transaction_mod.TransactionView;
pub const EnvFacts = transaction_mod.EnvFacts;
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
pub const executionContext = transaction_mod.executionContext;
pub const executionRequest = transaction_mod.executionRequest;
pub const accessListCounts = gas_mod.accessListCounts;
pub const blobBaseFeeForSchedule = blob_mod.blobBaseFeeForSchedule;
pub const calcExcessBlobGasForSchedule = blob_mod.calcExcessBlobGasForSchedule;
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

test "transaction scope composes with the canonical execution message" {
    const addr = @import("./address.zig").addr;
    const sender = addr(0xaaaa);
    const recipient = addr(0xbbbb);
    const auth_target = addr(0xcccc);
    const storage_keys = [_]u256{ 1, 2 };
    const access_list = [_]AccessListEntry{.{
        .address = recipient,
        .storage_keys = &storage_keys,
    }};
    const authorization_list = [_]AuthorizationTuple{.{
        .chain_id = 1,
        .target = auth_target,
        .signer = sender,
        .nonce = 7,
        .y_parity = 0,
        .legacy_v = null,
        .r = 1,
        .s = 1,
    }};
    const message = @import("./execution.zig").Message{ .call = .{
        .sender = sender,
        .recipient = recipient,
        .input = &.{0x42},
        .value = 3,
    } };
    const scope = TransactionScope{
        .context = .{
            .chain = .{ .chain_id = 1 },
            .block = .{ .coinbase = recipient },
            .transaction = .{ .origin = sender },
        },
        .access_list = &access_list,
        .authorization_list = &authorization_list,
        .authorization_count = authorization_list.len,
    };

    try std.testing.expect(!message.isCreate());
    try std.testing.expectEqualSlices(u8, &sender, &message.sender());
    try std.testing.expectEqualSlices(u8, &.{0x42}, message.input());
    try std.testing.expectEqual(@as(u256, 3), message.value());
    try std.testing.expectEqual(@as(usize, 1), scope.access_list.len);
    try std.testing.expectEqual(@as(usize, 1), scope.authorization_list.len);
    try std.testing.expectEqual(@as(usize, 1), scope.authorizationCount());

    const request = executionRequest(scope.context, message, .{
        .regular_left = 79_000,
        .reservoir = 3,
    });
    try std.testing.expectEqualDeep(scope.context, request.context);
    const call = request.message.call;
    try std.testing.expectEqual(sender, call.sender);
    try std.testing.expectEqual(recipient, call.recipient);
    try std.testing.expectEqual(@as(u64, 79_000), request.gas.regular_left);
    try std.testing.expectEqual(@as(u64, 3), request.gas.reservoir);
}

test {
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(gas_bound_plan);
}
