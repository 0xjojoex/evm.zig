const std = @import("std");

const blob = @import("./transaction/blob.zig");
const gas = @import("./transaction/gas.zig");
const settlement = @import("./transaction/settlement.zig");
const validation = @import("./transaction/validation.zig");
const transaction = @import("./transaction/Transaction.zig");

pub const blob_gas_per_blob = blob.blob_gas_per_blob;
pub const min_blob_base_fee = blob.min_blob_base_fee;
pub const blob_base_cost = blob.blob_base_cost;
pub const cancun_blob_base_fee_update_fraction = blob.cancun_blob_base_fee_update_fraction;
pub const prague_blob_base_fee_update_fraction = blob.prague_blob_base_fee_update_fraction;
pub const blob_base_fee_update_fraction = blob.blob_base_fee_update_fraction;
pub const authorization_intrinsic_gas = gas.authorization_intrinsic_gas;
pub const authorization_existing_account_refund_gas = gas.authorization_existing_account_refund_gas;
pub const access_list_address_gas = gas.access_list_address_gas;
pub const access_list_storage_key_gas = gas.access_list_storage_key_gas;
pub const access_list_address_data_gas = gas.access_list_address_data_gas;
pub const access_list_storage_key_data_gas = gas.access_list_storage_key_data_gas;
pub const create_transaction_gas = gas.create_transaction_gas;
pub const amsterdam_new_account_state_gas = gas.amsterdam_new_account_state_gas;
pub const initcode_word_gas = gas.initcode_word_gas;
pub const max_initcode_size = gas.max_initcode_size;
pub const amsterdam_max_initcode_size = gas.amsterdam_max_initcode_size;
pub const max_transaction_gas_limit = gas.max_transaction_gas_limit;
pub const maxInitcodeSize = gas.maxInitcodeSize;

pub const AccessListCounts = transaction.AccessListCounts;
pub const BlobSchedule = blob.BlobSchedule;
pub const ExcessBlobGasInput = blob.ExcessBlobGasInput;
pub const TxKind = transaction.TxKind;
pub const SenderCodeKind = validation.SenderCodeKind;
pub const ValidationError = validation.ValidationError;
pub const IntrinsicGasOptions = gas.IntrinsicGasOptions;
pub const GasCharge = gas.GasCharge;
pub const InitialGas = gas.InitialGas;
pub const ExecutionGas = gas.ExecutionGas;
pub const GasPlan = gas.GasPlan;
pub const ValidationInput = validation.ValidationInput;
pub const AccessListEntry = transaction.AccessListEntry;
pub const AuthorizationTuple = transaction.AuthorizationTuple;
pub const CallTransaction = transaction.CallTransaction;
pub const CreateTransaction = transaction.CreateTransaction;
pub const NormalizedTransactionInput = transaction.NormalizedTransactionInput;
pub const Transaction = transaction.Transaction;
pub const FeeInput = settlement.FeeInput;
pub const Settlement = settlement.Settlement;
pub const SettlementFees = settlement.SettlementFees;
pub const ExecutionGasResult = settlement.ExecutionGasResult;
pub const SettlementCosts = settlement.SettlementCosts;

pub const normalizedTransaction = transaction.normalizedTransaction;
pub const intrinsicGas = gas.intrinsicGas;
pub const intrinsicGasForTransaction = gas.intrinsicGasForTransaction;
pub const accessListCounts = gas.accessListCounts;
pub const gasPlan = gas.gasPlan;
pub const minimumGas = gas.minimumGas;
pub const minimumGasForTransaction = gas.minimumGasForTransaction;
pub const floorGas = gas.floorGas;
pub const floorGasForTransaction = gas.floorGasForTransaction;
pub const validate = validation.validate;
pub const maxPrepaymentCost = validation.maxPrepaymentCost;
pub const prepaymentCost = validation.prepaymentCost;
pub const calldataTokenCount = gas.calldataTokenCount;
pub const accessListDataCost = gas.accessListDataCost;
pub const blobSchedule = blob.blobSchedule;
pub const blobBaseFee = blob.blobBaseFee;
pub const blobBaseFeeForSpec = blob.blobBaseFeeForSpec;
pub const blobBaseFeeForSchedule = blob.blobBaseFeeForSchedule;
pub const calcExcessBlobGas = blob.calcExcessBlobGas;
pub const calcExcessBlobGasForSchedule = blob.calcExcessBlobGasForSchedule;
pub const fakeExponential = blob.fakeExponential;
pub const effectivePriorityFee = settlement.effectivePriorityFee;
pub const settlementFromGasPlan = settlement.settlementFromGasPlan;
pub const settlementCosts = settlement.settlementCosts;
pub const checkedGasCost = settlement.checkedGasCost;

test "transaction facade exposes normalized transaction shape" {
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
    const tx = Transaction{ .call = .{
        .sender = sender,
        .recipient = recipient,
        .input = &.{0x42},
        .gas_limit = 100_000,
        .value = 3,
        .access_list = &access_list,
        .authorization_list = &authorization_list,
    } };

    try std.testing.expect(!tx.isCreate());
    try std.testing.expectEqualSlices(u8, &sender, &tx.sender());
    try std.testing.expectEqualSlices(u8, &.{0x42}, tx.input());
    try std.testing.expectEqual(@as(u64, 100_000), tx.gasLimit());
    try std.testing.expectEqual(@as(u256, 3), tx.value());
    try std.testing.expectEqual(@as(usize, 1), tx.accessList().len);
    try std.testing.expectEqual(@as(usize, 1), tx.authorizationList().len);
    try std.testing.expectEqual(@as(usize, 1), tx.authorizationCount());
}

test {
    std.testing.refAllDecls(@This());
}
