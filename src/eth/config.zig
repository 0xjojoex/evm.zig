//! Resolves one complete Ethereum-family rule set from per-domain spec tables.
//!
//! Public callers supply flat domain overrides through `eth.extend` or
//! `eth.derive`. The VM compiler receives only `Resolved(R)`, so execution,
//! transaction, and block rules cannot drift into independently assembled
//! families.

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
    return transaction_config.Patch(R);
}

pub fn SettlementOptions(comptime R: type) type {
    return settlement.Settlement.Patch(R);
}

pub fn AuthorizationOptions(comptime R: type) type {
    return authorization.Authorization.Patch(R);
}

pub fn BlockOptions(comptime R: type) type {
    return system.Block.Patch(R);
}

pub fn SemanticOptions(comptime R: type) type {
    return struct {
        execution: ExecutionOptions(R) = .{},
        transaction: TransactionOptions(R) = .{},
        settlement: SettlementOptions(R) = .{},
        authorization: AuthorizationOptions(R) = .{},
        block: BlockOptions(R) = .{},
    };
}

/// Complete rules consumed by the private Ethereum-family compiler.
pub fn Resolved(comptime R: type) type {
    return struct {
        execution: definition.ExecutionRules(R),
        transaction: definition.TransactionLayerRules(R),
        block: definition.BlockConfig(R),
    };
}

/// The single canonical Ethereum rule source before family overrides.
pub const canonical: Resolved(Revision) = canonicalRules();

/// Resolve an Ethereum same-timeline extension over canonical rules.
pub fn resolveExtension(comptime options: SemanticOptions(Revision)) Resolved(Revision) {
    return applyOverrides(Revision, canonical, options);
}

/// Apply the ordinary Ethereum override vocabulary to one complete family.
/// Both same-timeline extensions and lifted revision families pass through
/// this path, so field coverage and precedence cannot drift between them.
pub fn applyOverrides(
    comptime R: type,
    comptime base: Resolved(R),
    comptime options: SemanticOptions(R),
) Resolved(R) {
    return .{
        .execution = .{
            .name = options.execution.name orelse base.execution.name,
            .revision = base.execution.revision,
            .instruction = options.execution.instruction orelse base.execution.instruction,
            .value_transfer_log = options.execution.value_transfer_log orelse base.execution.value_transfer_log,
            .call = mergePatch(base.execution.call, options.execution.call),
            .create = mergePatch(base.execution.create, options.execution.create),
            .storage = mergePatch(base.execution.storage, options.execution.storage),
            .self_destruct = mergePatch(base.execution.self_destruct, options.execution.self_destruct),
            .precompile = options.execution.precompile orelse base.execution.precompile,
        },
        .transaction = .{
            .transaction = mergePatch(base.transaction.transaction, options.transaction),
            .settlement = mergePatch(base.transaction.settlement, options.settlement),
            .authorization = mergePatch(base.transaction.authorization, options.authorization),
        },
        .block = mergePatch(base.block, options.block),
    };
}

fn canonicalRules() Resolved(Revision) {
    const execution_rules: definition.ExecutionRules(Revision) = .{
        .name = "ethereum",
        .revision = defaultRevisionConfig(),
        .instruction = instruction,
        .value_transfer_log = system.Execution.valueTransferLog,
        .call = system.Call.config(),
        .create = system.Create.config(),
        .storage = system.Storage.config(),
        .self_destruct = system.SelfDestruct.config(),
        .precompile = precompile,
    };
    const transaction_rules: definition.TransactionLayerRules(Revision) = .{
        .transaction = transaction_config.config(),
        .settlement = settlement.Settlement.config(),
        .authorization = authorization.Authorization.config(),
    };
    return .{
        .execution = execution_rules,
        .transaction = transaction_rules,
        .block = system.Block.config(),
    };
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

fn defaultRevisionConfig() definition.RevisionConfig(Revision) {
    return .{
        .latest = Revision.latest,
        .stable = Revision.stable,
        .order = Revision.order,
    };
}

test "canonical Ethereum config resolves one complete family input" {
    const resolved = canonical;
    const Execution = definition.ExecutionModel(resolved.execution);
    const Cancun = protocol_binding.compileExecution(resolved.execution, Execution.Support.at(.cancun));
    const CancunTx = protocol_binding.compileTransaction(Cancun, resolved.transaction);

    comptime std.debug.assert(@TypeOf(resolved) == Resolved(Revision));

    try std.testing.expectEqualStrings("ethereum", resolved.execution.name);
    try std.testing.expectEqual(Revision.latest, Execution.latest);
    try std.testing.expectEqual(Revision.stable, Execution.stable);
    try std.testing.expectEqual(support.Resolution.always, Cancun.Instruction.availability(Cancun.Instruction.fromByte(@intFromEnum(Opcode.BLOBBASEFEE))));
    try std.testing.expectEqual(support.Resolution.never, Cancun.Instruction.availability(Cancun.Instruction.fromByte(@intFromEnum(Opcode.SLOTNUM))));
    try std.testing.expectEqual(@as(?i64, 100), Cancun.Instruction.staticGasConstant(Cancun.Instruction.fromByte(@intFromEnum(Opcode.BALANCE))));
    try std.testing.expectEqual(@as(?usize, 49_152), Cancun.create.createInitCodeSizeLimit(.cancun));
    try std.testing.expect(CancunTx.authorization.active(.prague));
}

test "preset config uses generated support with ethereum revision semantics" {
    const resolved = resolveExtension(.{});
    const Execution = definition.ExecutionModel(resolved.execution);
    const full = Execution.Support.all;

    full.assertValid();
    try std.testing.expect(full.contains(.london));
    try std.testing.expect(!Execution.Support.at(.cancun).contains(.prague));
    try std.testing.expectEqual(support.Resolution.runtime, Execution.resolveAvailability(.{ .since = .cancun }, full));
}

test "domain patch can override an Ethereum hook back to its neutral default" {
    const neutral_active = definition.AuthorizationConfig(Revision).default.active;
    const resolved = resolveExtension(.{
        .authorization = .{ .active = neutral_active },
    });
    const Execution = definition.ExecutionModel(resolved.execution);
    const Prague = protocol_binding.compileTransaction(
        protocol_binding.compileExecution(resolved.execution, Execution.Support.at(.prague)),
        resolved.transaction,
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
    const resolved = resolveExtension(.{
        .execution = .{
            .call = .{ .callBaseGas = overrides.callBaseGas },
            .create = .{ .createCodeSizeLimit = overrides.createCodeSizeLimit },
            .self_destruct = .{ .selfDestructRefundGas = overrides.selfDestructRefundGas },
            .storage = .{ .sstoreMinimumGas = overrides.sstoreMinimumGas },
        },
        .authorization = .{ .active = overrides.authorizationActive },
        .transaction = .{
            .maxInitcodeSize = overrides.maxInitcodeSize,
            .transactionWarmsCoinbase = overrides.transactionWarmsCoinbase,
        },
        .settlement = .{ .gasRefundCapDivisor = overrides.gasRefundCapDivisor },
    });
    const Execution = definition.ExecutionModel(resolved.execution);
    const London = protocol_binding.compileExecution(resolved.execution, Execution.Support.at(.london));
    const LondonTx = protocol_binding.compileTransaction(London, resolved.transaction);

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
