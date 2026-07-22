//! Ethereum transaction semantic config and its typed authoring patch.

const definition = @import("../definition.zig");
const tx = @import("../transaction/types.zig");
const tx_blob = @import("../transaction/blob.zig");
const tx_gas = @import("../transaction/gas.zig");
const Revision = @import("revision.zig").Revision;
const transaction = @import("transaction.zig");

pub fn Patch(comptime R: type) type {
    const PatchType = struct {
        kindActive: ?*const fn (R, tx.TxKind) bool = null,
        allowsContractCreation: ?*const fn (R, tx.TxKind) bool = null,
        requiresAuthorizationList: ?*const fn (R, tx.TxKind) bool = null,
        rejectsNonDelegatingSenderCode: ?*const fn (R, tx.TxKind) bool = null,
        isDelegationCode: ?*const fn (R, []const u8) bool = null,
        blobSchedule: ?*const fn (R) ?tx_blob.BlobSchedule = null,
        blobVersionedHashActive: ?*const fn (R, u8) bool = null,
        maxInitcodeSize: ?*const fn (R) usize = null,
        intrinsicBaseGas: ?*const fn (R, tx_gas.IntrinsicGasOptions) ?u64 = null,
        createIntrinsicGas: ?*const fn (R) ?u64 = null,
        calldataGas: ?*const fn (R, []const u8) ?u64 = null,
        accessListAddressGas: ?*const fn (R) u64 = null,
        storageKeyGas: ?*const fn (R) u64 = null,
        accessListDataGas: ?*const fn (R, tx_gas.AccessListCounts) ?u64 = null,
        initCodeWordGas: ?*const fn (R) u64 = null,
        authorizationIntrinsicGas: ?*const fn (R) u64 = null,
        floorGas: ?*const fn (R, tx_gas.FloorGasInput) ?u64 = null,
        regularGasLimit: ?*const fn (R, u64) u64 = null,
        intrinsicRegularGasLimit: ?*const fn (R) ?u64 = null,
        totalGasLimit: ?*const fn (R) ?u64 = null,
        transactionWarmsCoinbase: ?*const fn (R) bool = null,
    };
    definition.assertPatchMirrors(definition.TransactionConfig(R), PatchType);
    return PatchType;
}

pub fn config() definition.TransactionConfig(Revision) {
    return .{
        .kindActive = transaction.Transaction.kindActive,
        .allowsContractCreation = transaction.Transaction.allowsContractCreation,
        .requiresAuthorizationList = transaction.Transaction.requiresAuthorizationList,
        .rejectsNonDelegatingSenderCode = transaction.Transaction.rejectsNonDelegatingSenderCode,
        .isDelegationCode = transaction.Transaction.isDelegationCode,
        .blobSchedule = transaction.Transaction.blobSchedule,
        .blobVersionedHashActive = transaction.Transaction.blobVersionedHashActive,
        .maxInitcodeSize = transaction.Transaction.maxInitcodeSize,
        .intrinsicBaseGas = transaction.Transaction.intrinsicBaseGas,
        .createIntrinsicGas = transaction.Transaction.createIntrinsicGas,
        .calldataGas = transaction.Transaction.calldataGas,
        .accessListAddressGas = transaction.Transaction.accessListAddressGas,
        .storageKeyGas = transaction.Transaction.storageKeyGas,
        .accessListDataGas = transaction.Transaction.accessListDataGas,
        .initCodeWordGas = transaction.Transaction.initCodeWordGas,
        .authorizationIntrinsicGas = transaction.Transaction.authorizationIntrinsicGas,
        .floorGas = transaction.Transaction.floorGas,
        .regularGasLimit = transaction.Transaction.regularGasLimit,
        .intrinsicRegularGasLimit = transaction.Transaction.intrinsicRegularGasLimit,
        .totalGasLimit = transaction.Transaction.totalGasLimit,
        .transactionWarmsCoinbase = transaction.Transaction.transactionWarmsCoinbase,
    };
}
