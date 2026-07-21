//! Assembles Ethereum execution, transaction, and block definitions from their
//! per-domain spec tables.
//!
//! `ExecutionOptions`, `TransactionOptions`, and `BlockOptions` are the public
//! override surfaces. Their builders resolve patches into complete independent
//! definitions before per-layer runtime binding.

const std = @import("std");

const definition = @import("../definition.zig");
const opcode_info = @import("../opcode.zig");
const protocol_types = @import("../protocol/types.zig");
const protocol_binding = @import("../protocol/binding.zig");
const support = @import("../protocol/support.zig");
const authorization = @import("authorization.zig");
const instruction = @import("instruction.zig");
const precompile = @import("precompile.zig");
const revision = @import("revision.zig");
const settlement = @import("settlement.zig");
const system = @import("system.zig");
const transaction_config = @import("transaction_config.zig");

pub const Revision = revision.Revision;
const Opcode = opcode_info.Opcode;

pub fn ExecutionOptions(comptime R: type) type {
    return struct {
        name: ?[]const u8 = null,
        revision: revision.Patch(R) = .{},
        instruction: ?type = null,
        value_transfer_log: ?*const fn (R, protocol_types.ValueTransferInput) ?protocol_types.ValueTransferLog = null,
        call: system.Call.Patch(R) = .{},
        create: system.Create.Patch(R) = .{},
        storage: system.Storage.Patch(R) = .{},
        self_destruct: system.SelfDestruct.Patch(R) = .{},
        precompile: ?type = null,
    };
}

pub fn TransactionOptions(comptime R: type) type {
    return struct {
        transaction: transaction_config.Patch(R) = .{},
        settlement: settlement.Settlement.Patch(R) = .{},
        authorization: authorization.Authorization.Patch(R) = .{},
    };
}

pub fn BlockOptions(comptime R: type) type {
    return struct {
        block: system.Block.Patch(R) = .{},
    };
}

pub fn execution(comptime cfg: ExecutionOptions(Revision)) definition.ExecutionDefinition(Revision) {
    return executionFor(Revision, cfg);
}

pub fn executionFor(comptime R: type, comptime cfg: ExecutionOptions(R)) definition.ExecutionDefinition(R) {
    const base: definition.ExecutionDefinition(R) = .{
        .name = "ethereum",
        .revision = defaultRevisionConfig(R),
        .instruction = domainOrDefault(R, cfg.instruction, instruction, "instruction"),
        .value_transfer_log = if (R == Revision) system.Execution.valueTransferLog else definition.neutralValueTransferLog(R),
        .call = system.Call.config(R),
        .create = system.Create.config(R),
        .storage = system.Storage.config(R),
        .self_destruct = system.SelfDestruct.config(R),
        .precompile = domainOrDefault(R, cfg.precompile, precompile, "precompile"),
    };
    return applyExecution(R, base, cfg);
}

/// Apply the ordinary Ethereum execution-option vocabulary over an already
/// complete definition. `eth.derive` uses this after lifting and amendment
/// resolution so direct Ethereum config and derived families cannot drift into
/// separate semantic-override APIs.
pub fn applyExecution(
    comptime R: type,
    comptime base: definition.ExecutionDefinition(R),
    comptime cfg: ExecutionOptions(R),
) definition.ExecutionDefinition(R) {
    validateRevisionPatch(R, cfg.revision);
    return .{
        .name = cfg.name orelse base.name,
        .revision = mergePatch(base.revision, cfg.revision),
        .instruction = cfg.instruction orelse base.instruction,
        .value_transfer_log = cfg.value_transfer_log orelse base.value_transfer_log,
        .call = mergePatch(base.call, cfg.call),
        .create = mergePatch(base.create, cfg.create),
        .storage = mergePatch(base.storage, cfg.storage),
        .self_destruct = mergePatch(base.self_destruct, cfg.self_destruct),
        .precompile = cfg.precompile orelse base.precompile,
    };
}

pub fn transaction(comptime cfg: TransactionOptions(Revision)) definition.TransactionDefinition(Revision) {
    return transactionFor(Revision, cfg);
}

pub fn transactionFor(comptime R: type, comptime cfg: TransactionOptions(R)) definition.TransactionDefinition(R) {
    const base: definition.TransactionDefinition(R) = .{
        .transaction = transaction_config.config(R),
        .settlement = settlement.Settlement.config(R),
        .authorization = authorization.Authorization.config(R),
    };
    return applyTransaction(R, base, cfg);
}

/// Apply transaction-domain patches over a complete transaction definition.
pub fn applyTransaction(
    comptime R: type,
    comptime base: definition.TransactionDefinition(R),
    comptime cfg: TransactionOptions(R),
) definition.TransactionDefinition(R) {
    return .{
        .transaction = mergePatch(base.transaction, cfg.transaction),
        .settlement = mergePatch(base.settlement, cfg.settlement),
        .authorization = mergePatch(base.authorization, cfg.authorization),
    };
}

pub fn block(comptime cfg: BlockOptions(Revision)) definition.BlockDefinition(Revision) {
    return blockFor(Revision, cfg);
}

pub fn blockFor(comptime R: type, comptime cfg: BlockOptions(R)) definition.BlockDefinition(R) {
    const base: definition.BlockDefinition(R) = .{
        .block = system.Block.config(R),
    };
    return applyBlock(R, base, cfg);
}

/// Apply block-domain patches over a complete block definition.
pub fn applyBlock(
    comptime R: type,
    comptime base: definition.BlockDefinition(R),
    comptime cfg: BlockOptions(R),
) definition.BlockDefinition(R) {
    return .{ .block = mergePatch(base.block, cfg.block) };
}

fn mergePatch(comptime base: anytype, comptime overrides: anytype) @TypeOf(base) {
    var result = base;
    inline for (std.meta.fields(@TypeOf(overrides))) |field| {
        if (@field(overrides, field.name)) |value| {
            @field(result, field.name) = value;
        }
    }
    return result;
}

fn validateRevisionPatch(comptime R: type, comptime patch: revision.Patch(R)) void {
    if (patch.order != null and R == Revision) {
        @compileError("Ethereum execution defaults do not support overriding revision.order; construct a complete ExecutionDefinition for custom revision semantics");
    }
}

fn defaultRevisionConfig(comptime R: type) definition.RevisionConfig(R) {
    if (R == Revision) {
        return .{
            .latest = Revision.latest,
            .stable = Revision.stable,
            .order = Revision.order,
        };
    }
    return .{};
}

fn domainOrDefault(comptime R: type, comptime override: ?type, comptime default: type, comptime name: []const u8) type {
    if (override) |Domain| return Domain;
    if (R == Revision) return default;
    @compileError("eth.defineFor with a custom Revision requires ." ++ name);
}

test "default ethereum config assembles through layered definition builders" {
    const execution_definition = execution(.{});
    const Definition = definition.BoundExecution(execution_definition);
    const Cancun = protocol_binding.ExecutionProtocol(execution_definition, Definition.Support.at(.cancun));
    const CancunTx = protocol_binding.TransactionProtocol(Cancun, transaction(.{}));

    try std.testing.expectEqualStrings("ethereum", execution_definition.name);
    try std.testing.expectEqual(Revision.latest, Definition.latest);
    try std.testing.expectEqual(Revision.stable, Definition.stable);
    try std.testing.expectEqual(support.Resolution.always, Cancun.Instruction.availability(Cancun.Instruction.fromByte(@intFromEnum(Opcode.BLOBBASEFEE))));
    try std.testing.expectEqual(support.Resolution.never, Cancun.Instruction.availability(Cancun.Instruction.fromByte(@intFromEnum(Opcode.SLOTNUM))));
    try std.testing.expectEqual(@as(?i64, 100), Cancun.Instruction.staticGasConstant(Cancun.Instruction.fromByte(@intFromEnum(Opcode.BALANCE))));
    try std.testing.expectEqual(@as(?usize, 49_152), Cancun.create.createInitCodeSizeLimit(.cancun));
    try std.testing.expect(CancunTx.authorization.active(.prague));
}

test "preset config uses generated support with ethereum revision semantics" {
    const execution_definition = execution(.{ .revision = .{
        .latest = .cancun,
        .stable = .cancun,
    } });
    const Definition = definition.BoundExecution(execution_definition);
    const full = Definition.Support.all;

    full.assertValid();
    try std.testing.expect(full.contains(.london));
    try std.testing.expect(!Definition.Support.at(.cancun).contains(.prague));
    try std.testing.expectEqual(support.Resolution.runtime, Definition.resolveAvailability(.{ .since = .cancun }, full));
}

test "revision patch can restore semantic optional fields to neutral" {
    const execution_definition = execution(.{ .revision = .{
        .latest = @as(?Revision, null),
        .stable = @as(?Revision, null),
    } });
    const Definition = definition.BoundExecution(execution_definition);

    try std.testing.expectEqual(@as(?Revision, null), execution_definition.revision.latest);
    try std.testing.expectEqual(@as(?Revision, null), execution_definition.revision.stable);
    try std.testing.expectEqual(Revision.latest, Definition.latest);
    try std.testing.expectEqual(Revision.latest, Definition.stable);
}

test "domain patch can override an Ethereum hook back to its neutral default" {
    const neutral_active = definition.AuthorizationConfig(Revision).default.active;
    const execution_definition = execution(.{});
    const Definition = definition.BoundExecution(execution_definition);
    const Prague = protocol_binding.TransactionProtocol(
        protocol_binding.ExecutionProtocol(execution_definition, Definition.Support.at(.prague)),
        transaction(.{ .authorization = .{ .active = neutral_active } }),
    );

    try std.testing.expect(!Prague.authorization.active(.prague));
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
    const execution_definition = execution(.{
        .call = .{ .callBaseGas = overrides.callBaseGas },
        .create = .{ .createCodeSizeLimit = overrides.createCodeSizeLimit },
        .self_destruct = .{ .selfDestructRefundGas = overrides.selfDestructRefundGas },
        .storage = .{ .sstoreMinimumGas = overrides.sstoreMinimumGas },
    });
    const transaction_definition = transaction(.{
        .authorization = .{ .active = overrides.authorizationActive },
        .transaction = .{
            .maxInitcodeSize = overrides.maxInitcodeSize,
            .transactionWarmsCoinbase = overrides.transactionWarmsCoinbase,
        },
        .settlement = .{ .gasRefundCapDivisor = overrides.gasRefundCapDivisor },
    });
    const Definition = definition.BoundExecution(execution_definition);
    const London = protocol_binding.ExecutionProtocol(execution_definition, Definition.Support.at(.london));
    const LondonTx = protocol_binding.TransactionProtocol(London, transaction_definition);

    try std.testing.expect(!LondonTx.authorization.active(.london));
    try std.testing.expectEqual(@as(usize, 1000), LondonTx.transaction.maxInitcodeSize(.london));
    try std.testing.expect(LondonTx.authorization.warmsDelegatedTarget(.prague));
    try std.testing.expect(LondonTx.transaction.transactionWarmsCoinbase(.london));
    try std.testing.expectEqual(@as(u64, 4), LondonTx.settlement.gasRefundCapDivisor(.london));
    try std.testing.expectEqual(@as(i64, 77), London.call.callBaseGas(.london));
    try std.testing.expectEqual(@as(?usize, 999), London.create.createCodeSizeLimit(.london));
    try std.testing.expectEqual(@as(i64, 88), London.self_destruct.selfDestructRefundGas(.london));
    try std.testing.expectEqual(@as(?i64, 123), London.storage.sstoreMinimumGas(.london));
    try std.testing.expectEqual(@as(?i64, 2000), London.storage.sloadColdStorageAccessGas(.london));
}
