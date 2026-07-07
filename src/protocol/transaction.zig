const std = @import("std");

const tx_blob = @import("../transaction/blob.zig");
const tx_gas = @import("../transaction/gas.zig");
const tx = @import("../transaction/Transaction.zig");
const tx_prepare = @import("../transaction/prepare.zig");
const tx_validation = @import("../transaction/validation.zig");

fn declOr(comptime Namespace: type, comptime name: []const u8, comptime default_value: anytype) @TypeOf(if (@hasDecl(Namespace, name)) @field(Namespace, name) else default_value) {
    return if (@hasDecl(Namespace, name)) @field(Namespace, name) else default_value;
}

pub fn For(comptime Definition: type) type {
    const DefinitionTransaction = Definition.Transaction;

    return struct {
        const Self = @This();

        pub const Value = declOr(DefinitionTransaction, "Value", tx.ProtocolTransaction);
        pub const View = declOr(DefinitionTransaction, "View", tx.TransactionView);
        pub const ValidationError = declOr(DefinitionTransaction, "ValidationError", tx_validation.ValidationError);

        pub fn view(value: Value) View {
            if (comptime std.meta.hasFn(DefinitionTransaction, "view")) {
                return DefinitionTransaction.view(value);
            }
            if (comptime Value != tx.ProtocolTransaction or View != tx.TransactionView) {
                @compileError("Definition.Transaction.view is required when overriding Transaction.Value or Transaction.View");
            }
            return tx.protocolTransactionView(value);
        }

        pub fn prepare(comptime Protocol: type, input: tx.PrepareInput(Protocol)) !tx.PrepareResult(Protocol) {
            if (comptime std.meta.hasFn(DefinitionTransaction, "prepare")) {
                return DefinitionTransaction.prepare(Protocol, input);
            }
            if (comptime View != tx.TransactionView or ValidationError != tx_validation.ValidationError) {
                @compileError("Definition.Transaction.prepare is required when overriding Transaction.View or Transaction.ValidationError");
            }
            return tx_prepare.For(Protocol).prepare(input);
        }

        pub fn kindActive(revision: Definition.Revision, kind: tx.TxKind) bool {
            return DefinitionTransaction.kindActive(revision, kind);
        }

        pub fn allowsContractCreation(revision: Definition.Revision, kind: tx.TxKind) bool {
            return DefinitionTransaction.allowsContractCreation(revision, kind);
        }

        pub fn requiresAuthorizationList(revision: Definition.Revision, kind: tx.TxKind) bool {
            return DefinitionTransaction.requiresAuthorizationList(revision, kind);
        }

        pub fn rejectsNonDelegatingSenderCode(revision: Definition.Revision, kind: tx.TxKind) bool {
            return DefinitionTransaction.rejectsNonDelegatingSenderCode(revision, kind);
        }

        pub fn blobGasPerBlob(revision: Definition.Revision) u64 {
            const schedule = Self.blobSchedule(revision) orelse return 0;
            return schedule.gas_per_blob;
        }

        pub fn blobSchedule(revision: Definition.Revision) ?tx_blob.BlobSchedule {
            return DefinitionTransaction.blobSchedule(revision);
        }

        pub fn blobMaxCount(revision: Definition.Revision) usize {
            const schedule = Self.blobSchedule(revision) orelse return 0;
            return std.math.cast(usize, schedule.max) orelse std.math.maxInt(usize);
        }

        pub fn blobMaxCountPerTransaction(revision: Definition.Revision) usize {
            const schedule = Self.blobSchedule(revision) orelse return 0;
            return std.math.cast(usize, schedule.max_per_transaction) orelse std.math.maxInt(usize);
        }

        pub fn blobReservePriceActive(revision: Definition.Revision) bool {
            const schedule = Self.blobSchedule(revision) orelse return false;
            return schedule.reserve_price_active;
        }

        pub fn blobVersionedHashActive(revision: Definition.Revision, version: u8) bool {
            return DefinitionTransaction.blobVersionedHashActive(revision, version);
        }

        pub fn maxInitcodeSize(revision: Definition.Revision) usize {
            return DefinitionTransaction.maxInitcodeSize(revision);
        }

        pub fn intrinsicBaseGas(revision: Definition.Revision, options: tx_gas.IntrinsicGasOptions) ?u64 {
            return DefinitionTransaction.intrinsicBaseGas(revision, options);
        }

        pub fn createIntrinsicGas(revision: Definition.Revision) ?u64 {
            return DefinitionTransaction.createIntrinsicGas(revision);
        }

        pub fn dataByteGas(revision: Definition.Revision, byte: u8) u64 {
            return DefinitionTransaction.dataByteGas(revision, byte);
        }

        pub fn accessListAddressGas(revision: Definition.Revision) u64 {
            return DefinitionTransaction.accessListAddressGas(revision);
        }

        pub fn storageKeyGas(revision: Definition.Revision) u64 {
            return DefinitionTransaction.storageKeyGas(revision);
        }

        pub fn accessListDataGas(revision: Definition.Revision, counts: tx_gas.AccessListCounts) ?u64 {
            return DefinitionTransaction.accessListDataGas(revision, counts);
        }

        pub fn initCodeWordGas(revision: Definition.Revision) u64 {
            return DefinitionTransaction.initCodeWordGas(revision);
        }

        pub fn authorizationIntrinsicGas(revision: Definition.Revision) u64 {
            return DefinitionTransaction.authorizationIntrinsicGas(revision);
        }

        pub fn intrinsicStateGas(revision: Definition.Revision, options: tx_gas.IntrinsicGasOptions) ?u64 {
            return DefinitionTransaction.intrinsicStateGas(revision, options);
        }

        pub fn floorGas(revision: Definition.Revision, input: []const u8, options: tx_gas.IntrinsicGasOptions) ?u64 {
            return DefinitionTransaction.floorGas(revision, input, options);
        }

        pub fn regularGasLimit(revision: Definition.Revision, gas_limit: u64) u64 {
            return DefinitionTransaction.regularGasLimit(revision, gas_limit);
        }

        pub fn intrinsicRegularGasLimit(revision: Definition.Revision) ?u64 {
            return DefinitionTransaction.intrinsicRegularGasLimit(revision);
        }

        pub fn totalGasLimit(revision: Definition.Revision) ?u64 {
            return DefinitionTransaction.totalGasLimit(revision);
        }

        comptime {
            _ = Self.Value;
            _ = Self.View;
            _ = Self.ValidationError;
        }
    };
}
