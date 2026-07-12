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
const transaction_config = @import("transaction_config.zig");

pub const Revision = revision.Revision;
const Opcode = opcode_info.Opcode;

/// Per-domain override surface for `define`; every field defaults to the
/// mainnet Ethereum rule, so `.{}` yields the standard definition.
pub fn Options(comptime R: type) type {
    return struct {
        name: []const u8 = "ethereum",
        revision: revision.Patch(R) = .{},
        instruction: ?type = null,
        transaction: transaction_config.Patch(R) = .{},
        settlement: settlement.Settlement.Patch(R) = .{},
        authorization: settlement.Authorization.Patch(R) = .{},
        block: system.Block.Patch(R) = .{},
        call: system.Call.Patch(R) = .{},
        create: system.Create.Patch(R) = .{},
        storage: system.Storage.Patch(R) = .{},
        self_destruct: system.SelfDestruct.Patch(R) = .{},
        precompile: ?type = null,
    };
}

pub fn define(comptime cfg: Options(Revision)) definition.Definition(Revision) {
    return defineFor(Revision, cfg);
}

pub fn defineFor(comptime R: type, comptime cfg: Options(R)) definition.Definition(R) {
    validateRevisionPatch(R, cfg.revision);
    const revision_config = mergePatch(defaultRevisionConfig(R), cfg.revision);
    return .{
        .name = cfg.name,
        .revision = revision_config,
        .instruction = domainOrDefault(R, cfg.instruction, instruction, "instruction"),
        .transaction = mergePatch(transaction_config.config(R), cfg.transaction),
        .settlement = mergePatch(settlement.Settlement.config(R), cfg.settlement),
        .authorization = mergePatch(settlement.Authorization.config(R), cfg.authorization),
        .block = mergePatch(system.Block.config(R), cfg.block),
        .call = mergePatch(system.Call.config(R), cfg.call),
        .create = mergePatch(system.Create.config(R), cfg.create),
        .storage = mergePatch(system.Storage.config(R), cfg.storage),
        .self_destruct = mergePatch(system.SelfDestruct.config(R), cfg.self_destruct),
        .precompile = domainOrDefault(R, cfg.precompile, precompile, "precompile"),
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

fn validateRevisionPatch(comptime R: type, comptime patch: revision.Patch(R)) void {
    if (patch.order != null and R == Revision) {
        @compileError("eth.define does not support overriding revision.order while inheriting Ethereum defaults; construct evmz.Definition with complete domain configs for custom revision semantics");
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
    try std.testing.expectEqual(@as(?usize, 49_152), Cancun.create.createInitCodeSizeLimit(.cancun));
    try std.testing.expect(Cancun.authorization.active(.prague));
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

test "domain patch can override an Ethereum hook back to its neutral default" {
    const neutral_active = definition.AuthorizationConfig(Revision).default.active;
    const definition_value = define(.{ .authorization = .{ .active = neutral_active } });
    const Definition = definition.Bound(definition_value);
    const Protocol = protocol_binding.Protocol(definition_value, Definition.Support.at(.prague));

    try std.testing.expect(!Protocol.authorization.active(.prague));
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

    try std.testing.expect(!Protocol.authorization.active(.london));
    try std.testing.expectEqual(@as(usize, 1000), Protocol.transaction.maxInitcodeSize(.london));
    try std.testing.expect(Protocol.authorization.warmsDelegatedTarget(.prague));
    try std.testing.expect(Protocol.block.transactionWarmsCoinbase(.london));
    try std.testing.expectEqual(@as(u64, 4), Protocol.settlement.gasRefundCapDivisor(.london));
    try std.testing.expectEqual(@as(i64, 77), Protocol.call.callBaseGas(.london));
    try std.testing.expectEqual(@as(?usize, 999), Protocol.create.createCodeSizeLimit(.london));
    try std.testing.expectEqual(@as(i64, 88), Protocol.self_destruct.selfDestructRefundGas(.london));
    try std.testing.expectEqual(@as(?i64, 123), Protocol.storage.sstoreMinimumGas(.london));
    try std.testing.expectEqual(@as(?i64, 2000), Protocol.storage.sloadColdStorageAccessGas(.london));
}
