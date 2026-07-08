//! Protocol-neutral transaction types, gas accounting, and preparation.

const std = @import("std");

const blob_mod = @import("./transaction/blob.zig");
const eth_transaction = @import("./eth/transaction.zig");
const gas_mod = @import("./transaction/gas.zig");
const gas_bound_plan = @import("./transaction/gas_bound_plan.zig");
const prepare_mod = @import("./transaction/prepare.zig");
const settlement_mod = @import("./transaction/settlement.zig");
pub const type_id = @import("./transaction/type_id.zig");
pub const envelope = @import("./transaction/envelope.zig");
const validation_mod = @import("./transaction/validation.zig");
const transaction_mod = @import("./transaction/types.zig");

pub const AccessListCounts = transaction_mod.AccessListCounts;
pub const BlobSchedule = blob_mod.BlobSchedule;
pub const ExcessBlobGasInput = blob_mod.ExcessBlobGasInput;
pub const TxKind = transaction_mod.TxKind;
pub const SenderCodeKind = transaction_mod.SenderCodeKind;
pub const ValidationError = validation_mod.ValidationError;
pub const IntrinsicGasOptions = gas_mod.IntrinsicGasOptions;
pub const GasCharge = gas_mod.GasCharge;
pub const InitialGas = gas_mod.InitialGas;
pub const ExecutionGas = gas_mod.ExecutionGas;
pub const GasPlan = gas_mod.GasPlan;
pub const AccessListEntry = transaction_mod.AccessListEntry;
pub const AuthorizationTuple = transaction_mod.AuthorizationTuple;
pub const FeeFields = transaction_mod.FeeFields;
pub const Transaction = transaction_mod.Transaction;
pub const TransactionView = transaction_mod.TransactionView;
pub const EnvFacts = transaction_mod.EnvFacts;
pub const StateFacts = transaction_mod.StateFacts;
pub const ExecutionContext = transaction_mod.ExecutionContext;
pub const TransactionScope = transaction_mod.TransactionScope;
pub const RootFrame = transaction_mod.RootFrame;
pub const FeeInput = settlement_mod.FeeInput;
pub const Settlement = settlement_mod.Settlement;
pub const SettlementFees = settlement_mod.SettlementFees;
pub const ExecutionGasResult = settlement_mod.ExecutionGasResult;
pub const SettlementCosts = settlement_mod.SettlementCosts;
pub const SettlementPrecharge = settlement_mod.Precharge;

pub const transactionView = transaction_mod.transactionView;
pub const effectiveGasPrice = transaction_mod.effectiveGasPrice;
pub const accessListCounts = gas_mod.accessListCounts;
pub const blobBaseFeeForSchedule = blob_mod.blobBaseFeeForSchedule;
pub const calcExcessBlobGasForSchedule = blob_mod.calcExcessBlobGasForSchedule;
pub const fakeExponential = blob_mod.fakeExponential;
pub const checkedGasCost = settlement_mod.checkedGasCost;
pub const Prepared = transaction_mod.Prepared;
pub const PrepareInput = transaction_mod.PrepareInput;
pub const PrepareResult = transaction_mod.PrepareResult;

pub fn For(comptime ProtocolType: type) type {
    return struct {
        pub const Protocol = ProtocolType;
        pub const blob = blob_mod.For(ProtocolType);
        pub const gas = gas_mod.For(ProtocolType);
        pub const prepare = prepare_mod.For(ProtocolType);
        pub const settlement = settlement_mod.For(ProtocolType);
        pub const validation = validation_mod.For(ProtocolType);
    };
}

test "transaction facade exposes root frame and transaction scope" {
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
    const root = RootFrame{ .call = .{
        .sender = sender,
        .recipient = recipient,
        .input = &.{0x42},
        .gas_limit = 100_000,
        .value = 3,
    } };
    const scope = TransactionScope{
        .context = .{
            .origin = sender,
            .coinbase = recipient,
        },
        .access_list = &access_list,
        .authorization_list = &authorization_list,
        .authorization_count = authorization_list.len,
    };

    try std.testing.expect(!root.isCreate());
    try std.testing.expectEqualSlices(u8, &sender, &root.sender());
    try std.testing.expectEqualSlices(u8, &.{0x42}, root.input());
    try std.testing.expectEqual(@as(u64, 100_000), root.gasLimit());
    try std.testing.expectEqual(@as(u256, 3), root.value());
    try std.testing.expectEqual(@as(usize, 1), scope.access_list.len);
    try std.testing.expectEqual(@as(usize, 1), scope.authorization_list.len);
    try std.testing.expectEqual(@as(usize, 1), scope.authorizationCount());
}

test "transaction bound namespace carries comptime protocol" {
    const DoubleBlobProtocol = struct {
        pub const Revision = enum { test_revision };

        pub const Transaction = struct {
            pub fn blobSchedule(revision: Revision) ?BlobSchedule {
                _ = revision;
                return .{
                    .target = 3,
                    .max = 6,
                    .max_per_transaction = 6,
                    .gas_per_blob = eth_transaction.blob_gas_per_blob * 2,
                    .min_base_fee = eth_transaction.min_blob_base_fee,
                    .execution_base_cost = eth_transaction.blob_base_cost,
                    .base_fee_update_fraction = eth_transaction.cancun_blob_base_fee_update_fraction,
                    .reserve_price_active = false,
                };
            }
        };
    };
    const Bound = For(DoubleBlobProtocol);

    try std.testing.expectEqual(
        @as(u256, 10 + eth_transaction.blob_gas_per_blob * 2),
        Bound.validation.prepaymentCost(.test_revision, 10, 1, 1, 1).?,
    );
}

test {
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(gas_bound_plan);
}
