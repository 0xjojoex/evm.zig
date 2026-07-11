//! Assembles the Ethereum `Definition` from the per-domain spec tables.
//!
//! `Options` is the user-facing override surface; `define`/`defineFor` merge
//! those overrides onto complete Ethereum domain values and return a filled
//! `definition.Definition`. Domain modules own their concrete rules and migrate
//! their complete values beside those implementations; this file remains the
//! single merge/wiring point between authoring and the neutral fork schema.

const std = @import("std");

const definition = @import("../definition.zig");
const opcode_info = @import("../opcode.zig");
const protocol_binding = @import("../protocol/binding.zig");
const support = @import("../protocol/support.zig");
const instruction = @import("instruction.zig");
const precompile = @import("precompile.zig");
const revision = @import("revision.zig");
const settlement = @import("settlement.zig");
const system = @import("system.zig");
const transaction = @import("transaction.zig");
const transaction_prepare = @import("transaction_prepare.zig");
const transaction_validation = @import("transaction_validation.zig");

pub const Revision = revision.Revision;
const Opcode = opcode_info.Opcode;

/// Per-domain override surface for `define`; every field defaults to the
/// mainnet Ethereum rule, so `.{}` yields the standard definition.
pub fn Options(comptime R: type) type {
    return struct {
        name: []const u8 = "ethereum",
        revision: revision.Patch(R) = .{},
        instruction: ?type = null,
        transaction: definition.TransactionConfig(R) = .default,
        settlement: definition.SettlementConfig(R) = .default,
        authorization: definition.AuthorizationConfig(R) = .default,
        block: system.Block.Patch(R) = .{},
        call: definition.CallConfig(R) = .default,
        create: definition.CreateConfig(R) = .default,
        storage: definition.StorageConfig(R) = .default,
        self_destruct: definition.SelfDestructConfig(R) = .default,
        precompile: ?type = null,
    };
}

pub fn define(comptime cfg: Options(Revision)) definition.Definition(Revision) {
    return defineFor(Revision, cfg);
}

pub fn defineFor(comptime R: type, comptime cfg: Options(R)) definition.Definition(R) {
    validateRevisionPatch(R, cfg.revision);
    const revision_config = mergePatch(
        definition.RevisionConfig(R),
        revision.Patch(R),
        defaultRevisionConfig(R),
        cfg.revision,
    );
    return .{
        .name = cfg.name,
        .revision = revision_config,
        .instruction = domainOrDefault(R, cfg.instruction, instruction, "instruction"),
        .transaction = mergeConfig(definition.TransactionConfig(R), defaultTransactionConfig(R), cfg.transaction),
        .settlement = mergeConfig(definition.SettlementConfig(R), defaultSettlementConfig(R), cfg.settlement),
        .authorization = mergeConfig(definition.AuthorizationConfig(R), defaultAuthorizationConfig(R), cfg.authorization),
        .block = mergePatch(definition.BlockConfig(R), system.Block.Patch(R), system.Block.config(R), cfg.block),
        .call = mergeConfig(definition.CallConfig(R), defaultCallConfig(R), cfg.call),
        .create = mergeConfig(definition.CreateConfig(R), defaultCreateConfig(R), cfg.create),
        .storage = mergeConfig(definition.StorageConfig(R), defaultStorageConfig(R), cfg.storage),
        .self_destruct = mergeConfig(definition.SelfDestructConfig(R), defaultSelfDestructConfig(R), cfg.self_destruct),
        .precompile = domainOrDefault(R, cfg.precompile, precompile, "precompile"),
    };
}

fn mergeConfig(comptime T: type, comptime base: T, comptime overrides: T) T {
    var result = base;
    inline for (@typeInfo(T).@"struct".fields) |field| {
        if (@field(overrides, field.name) != @field(T.default, field.name)) {
            @field(result, field.name) = @field(overrides, field.name);
        }
    }
    return result;
}

fn mergePatch(comptime Config: type, comptime Patch: type, comptime base: Config, comptime overrides: Patch) Config {
    var result = base;
    inline for (@typeInfo(Patch).@"struct".fields) |field| {
        if (@field(overrides, field.name)) |value| {
            @field(result, field.name) = value;
        }
    }
    return result;
}

fn validateRevisionPatch(comptime R: type, comptime patch: revision.Patch(R)) void {
    if (patch.isImpl != null and R == Revision) {
        @compileError("eth.define does not support overriding revision.isImpl while inheriting Ethereum defaults; construct evmz.Definition with complete domain configs for custom revision semantics");
    }
}

fn defaultRevisionConfig(comptime R: type) definition.RevisionConfig(R) {
    if (R == Revision) {
        return .{
            .latest = Revision.latest,
            .stable = Revision.stable,
            .isImpl = Revision.isImpl,
        };
    }
    return .{};
}

fn domainOrDefault(comptime R: type, comptime override: ?type, comptime default: type, comptime name: []const u8) type {
    if (override) |Domain| return Domain;
    if (R == Revision) return default;
    @compileError("eth.defineFor with a custom Revision requires ." ++ name);
}

fn defaultTransactionConfig(comptime R: type) definition.TransactionConfig(R) {
    if (R == Revision) {
        return .{
            .Preparation = transaction_prepare,
            .ValidationError = transaction_validation.ValidationError,
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
            .dataByteGas = transaction.Transaction.dataByteGas,
            .accessListAddressGas = transaction.Transaction.accessListAddressGas,
            .storageKeyGas = transaction.Transaction.storageKeyGas,
            .accessListDataGas = transaction.Transaction.accessListDataGas,
            .initCodeWordGas = transaction.Transaction.initCodeWordGas,
            .authorizationIntrinsicGas = transaction.Transaction.authorizationIntrinsicGas,
            .intrinsicStateGas = transaction.Transaction.intrinsicStateGas,
            .floorGas = transaction.Transaction.floorGas,
            .regularGasLimit = transaction.Transaction.regularGasLimit,
            .intrinsicRegularGasLimit = transaction.Transaction.intrinsicRegularGasLimit,
            .totalGasLimit = transaction.Transaction.totalGasLimit,
        };
    }
    return .default;
}

fn defaultSettlementConfig(comptime R: type) definition.SettlementConfig(R) {
    if (R == Revision) {
        return .{
            .baseFeeActive = settlement.Settlement.baseFeeActive,
            .gasRefundCapDivisor = settlement.Settlement.gasRefundCapDivisor,
            .usesStateGasAccounting = settlement.Settlement.usesStateGasAccounting,
        };
    }
    return .default;
}

fn defaultAuthorizationConfig(comptime R: type) definition.AuthorizationConfig(R) {
    if (R == Revision) {
        return .{
            .active = settlement.Authorization.active,
            .warmsDelegatedTarget = settlement.Authorization.warmsDelegatedTarget,
            .successGasAdjustment = settlement.Authorization.successGasAdjustment,
            .invalidGasAdjustment = settlement.Authorization.invalidGasAdjustment,
            .malformedGasAdjustment = settlement.Authorization.malformedGasAdjustment,
        };
    }
    return .default;
}

fn defaultCallConfig(comptime R: type) definition.CallConfig(R) {
    if (R == Revision) {
        return .{
            .callBaseGas = system.Call.callBaseGas,
            .callColdAccountAccessGas = system.Call.callColdAccountAccessGas,
            .callValueTransferGas = system.Call.callValueTransferGas,
            .callValueStipend = system.Call.callValueStipend,
            .callNewAccountGas = system.Call.callNewAccountGas,
            .topFrameValueTransferStateGas = system.Call.topFrameValueTransferStateGas,
            .delegatedAccountAccessGas = system.Call.delegatedAccountAccessGas,
            .topLevelDelegatedAccountAccess = system.Call.topLevelDelegatedAccountAccess,
            .touchesEmptyCallRecipient = system.Call.touchesEmptyCallRecipient,
            .childGas = system.Call.childGas,
        };
    }
    return .default;
}

fn defaultCreateConfig(comptime R: type) definition.CreateConfig(R) {
    if (R == Revision) {
        return .{
            .createCodeSizeLimit = system.Create.createCodeSizeLimit,
            .rejectsCreateCode = system.Create.rejectsCreateCode,
            .createDepositRegularGas = system.Create.createDepositRegularGas,
            .createDepositStateGas = system.Create.createDepositStateGas,
            .createDepositRegularGasOogCommits = system.Create.createDepositRegularGasOogCommits,
            .createAccountStateGasRefund = system.Create.createAccountStateGasRefund,
            .createTransactionRollbackStateGasRefund = system.Create.createTransactionRollbackStateGasRefund,
            .createWarmsCreatedAddress = system.Create.createWarmsCreatedAddress,
            .createInitialNonce = system.Create.createInitialNonce,
            .createInitCodeSizeLimit = system.Create.createInitCodeSizeLimit,
            .createInitCodeWordGas = system.Create.createInitCodeWordGas,
            .createAccountStateGas = system.Create.createAccountStateGas,
        };
    }
    return .default;
}

fn defaultStorageConfig(comptime R: type) definition.StorageConfig(R) {
    if (R == Revision) {
        return .{
            .sloadColdStorageAccessGas = system.Storage.sloadColdStorageAccessGas,
            .sstoreMinimumGas = system.Storage.sstoreMinimumGas,
            .sstoreStorageAccessGas = system.Storage.sstoreStorageAccessGas,
            .sstoreGas = system.Storage.sstoreGas,
            .sstoreStateGas = system.Storage.sstoreStateGas,
        };
    }
    return .default;
}

fn defaultSelfDestructConfig(comptime R: type) definition.SelfDestructConfig(R) {
    if (R == Revision) {
        return .{
            .selfDestructPolicy = system.SelfDestruct.selfDestructPolicy,
            .selfDestructFinalization = system.SelfDestruct.selfDestructFinalization,
            .selfDestructNewAccountGas = system.SelfDestruct.selfDestructNewAccountGas,
            .selfDestructColdAccountAccessGas = system.SelfDestruct.selfDestructColdAccountAccessGas,
            .selfDestructRefundGas = system.SelfDestruct.selfDestructRefundGas,
        };
    }
    return .default;
}

test "default ethereum config assembles through generic definition config" {
    const definition_value = define(.{});
    const Definition = definition.Bound(definition_value);
    const Cancun = protocol_binding.Protocol(definition_value, Definition.Support.at(.cancun));

    try std.testing.expectEqualStrings("ethereum", Definition.name);
    try std.testing.expectEqual(Revision.latest, Definition.latest);
    try std.testing.expectEqual(Revision.stable, Definition.stable);
    try std.testing.expectEqual(support.Resolution.always, Cancun.Instruction.availability(Cancun.Instruction.fromByte(@intFromEnum(Opcode.BLOBBASEFEE))));
    try std.testing.expectEqual(support.Resolution.never, Cancun.Instruction.availability(Cancun.Instruction.fromByte(@intFromEnum(Opcode.SLOTNUM))));
    try std.testing.expectEqual(@as(?i64, 100), Cancun.Instruction.staticGasConstant(Cancun.Instruction.fromByte(@intFromEnum(Opcode.BALANCE))));
    try std.testing.expectEqual(@as(?usize, 49_152), Cancun.Create.createInitCodeSizeLimit(.cancun));
    try std.testing.expect(Cancun.Authorization.active(.prague));
}

test "preset config uses generated support with ethereum revision semantics" {
    const definition_value = define(.{ .revision = .{
        .latest = .cancun,
        .stable = .cancun,
    } });
    const Definition = definition.Bound(definition_value);
    const full = Definition.Support.all;

    full.assertValid();
    try std.testing.expect(full.contains(.london));
    try std.testing.expect(!Definition.Support.at(.cancun).contains(.prague));
    try std.testing.expectEqual(support.Resolution.runtime, Definition.resolveAvailability(.{ .since = .cancun }, full));
}

test "revision patch can restore semantic optional fields to neutral" {
    const definition_value = define(.{ .revision = .{
        .latest = @as(?Revision, null),
        .stable = @as(?Revision, null),
    } });
    const Definition = definition.Bound(definition_value);

    try std.testing.expectEqual(@as(?Revision, null), definition_value.revision.latest);
    try std.testing.expectEqual(@as(?Revision, null), definition_value.revision.stable);
    try std.testing.expectEqual(Revision.latest, Definition.latest);
    try std.testing.expectEqual(Revision.latest, Definition.stable);
}

test "preset config accepts partial simple-domain overrides" {
    const overrides = struct {
        fn authorizationActive(revision_value: Revision) bool {
            _ = revision_value;
            return false;
        }

        fn transactionWarmsCoinbase(revision_value: Revision) bool {
            _ = revision_value;
            return true;
        }

        fn gasRefundCapDivisor(revision_value: Revision) u64 {
            _ = revision_value;
            return 4;
        }

        fn maxInitcodeSize(revision_value: Revision) usize {
            _ = revision_value;
            return 1000;
        }

        fn callBaseGas(revision_value: Revision) i64 {
            _ = revision_value;
            return 77;
        }

        fn selfDestructRefundGas(revision_value: Revision) i64 {
            _ = revision_value;
            return 88;
        }

        fn createCodeSizeLimit(revision_value: Revision) ?usize {
            _ = revision_value;
            return 999;
        }

        fn sstoreMinimumGas(revision_value: Revision) ?i64 {
            _ = revision_value;
            return 123;
        }
    };
    const definition_value = define(.{
        .transaction = .{ .maxInitcodeSize = overrides.maxInitcodeSize },
        .authorization = .{ .active = overrides.authorizationActive },
        .block = .{ .transactionWarmsCoinbase = overrides.transactionWarmsCoinbase },
        .settlement = .{ .gasRefundCapDivisor = overrides.gasRefundCapDivisor },
        .call = .{ .callBaseGas = overrides.callBaseGas },
        .create = .{ .createCodeSizeLimit = overrides.createCodeSizeLimit },
        .self_destruct = .{ .selfDestructRefundGas = overrides.selfDestructRefundGas },
        .storage = .{ .sstoreMinimumGas = overrides.sstoreMinimumGas },
    });
    const Definition = definition.Bound(definition_value);
    const Protocol = protocol_binding.Protocol(definition_value, Definition.Support.at(.london));

    try std.testing.expect(!Protocol.Authorization.active(.london));
    try std.testing.expectEqual(@as(usize, 1000), Protocol.Transaction.maxInitcodeSize(.london));
    try std.testing.expect(Protocol.Authorization.warmsDelegatedTarget(.prague));
    try std.testing.expect(Protocol.block.transactionWarmsCoinbase(.london));
    try std.testing.expectEqual(@as(u64, 4), Protocol.Settlement.gasRefundCapDivisor(.london));
    try std.testing.expectEqual(@as(i64, 77), Protocol.Call.callBaseGas(.london));
    try std.testing.expectEqual(@as(?usize, 999), Protocol.Create.createCodeSizeLimit(.london));
    try std.testing.expectEqual(@as(i64, 88), Protocol.SelfDestruct.selfDestructRefundGas(.london));
    try std.testing.expectEqual(@as(?i64, 123), Protocol.Storage.sstoreMinimumGas(.london));
    try std.testing.expectEqual(@as(?i64, 2000), Protocol.Storage.sloadColdStorageAccessGas(.london));
}
