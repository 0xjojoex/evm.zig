const std = @import("std");
const execution = @import("execution.zig");
const instruction_mod = @import("instruction.zig");
const opcode_info = @import("../opcode.zig");
const Opcode = opcode_info.Opcode;
const OpInfo = opcode_info.OpInfo;
const support_mod = @import("support.zig");
const Resolution = support_mod.Resolution;
pub const InstructionContext = instruction_mod.Context;
pub const StaticGas = support_mod.StaticGas;
pub const OpcodeTier = support_mod.OpcodeTier;
pub const BuiltinHandler = execution.BuiltinHandler;
pub const ExecutionOverride = execution.ExecutionOverride;
pub const ExecutionTarget = execution.ExecutionTarget;

/// Comptime ceiling for the dispatcher's comptime evaluation roots (the
/// per-Definition attribute tables below and the per-window table resolve).
/// `@setEvalBranchQuota` raises a limit, it does not spend a budget, so
/// over-provisioning is free at compile time and the default keeps headroom.
/// The worst root measures ~20k for the current eth Definition: the
/// support-independent attributes are cached in `InstructionTables`, so the
/// per-window cost is now dominated by static-gas folding, which scales with
/// the revision count. A Definition with heavier comptime per-opcode logic can
/// raise the ceiling with `pub const dispatch_eval_branch_quota`.
fn dispatchEvalBranchQuota(comptime Definition: type) comptime_int {
    if (@hasDecl(Definition, "dispatch_eval_branch_quota")) return Definition.dispatch_eval_branch_quota;
    return 256 * 128 + Definition.revisions.len * 512;
}

/// Support-window-independent per-byte attributes, resolved once per Definition
/// and cached as container-level constants. `info`, raw `availability`, `tier`,
/// and `execution_target` depend only on the opcode byte, so the deep comptime
/// call chains behind them run a single time (each table is its own comptime
/// evaluation root with its own quota) instead of once per byte per support
/// window. `resolveDispatchTable` then just indexes these tables and layers the
/// window-dependent work (availability resolution + static-gas folding) on top.
fn InstructionTables(comptime Definition: type) type {
    return struct {
        pub const info: [256]OpInfo = blk: {
            @setEvalBranchQuota(dispatchEvalBranchQuota(Definition));
            var t: [256]OpInfo = undefined;
            for (0..256) |b| t[b] = instruction_mod.info(Definition, instructionFromByte(Definition, @intCast(b)));
            break :blk t;
        };
        pub const raw_availability: [256]Definition.Availability = blk: {
            @setEvalBranchQuota(dispatchEvalBranchQuota(Definition));
            var t: [256]Definition.Availability = undefined;
            for (0..256) |b| t[b] = instruction_mod.availability(Definition, instructionFromByte(Definition, @intCast(b)));
            break :blk t;
        };
        pub const tier: [256]OpcodeTier = blk: {
            @setEvalBranchQuota(dispatchEvalBranchQuota(Definition));
            var t: [256]OpcodeTier = undefined;
            for (0..256) |b| t[b] = instruction_mod.tier(Definition, instructionFromByte(Definition, @intCast(b)));
            break :blk t;
        };
        pub const execution_target: [256]ExecutionTarget = blk: {
            @setEvalBranchQuota(dispatchEvalBranchQuota(Definition));
            var t: [256]ExecutionTarget = undefined;
            for (0..256) |b| {
                const inst = instructionFromByte(Definition, @intCast(b));
                t[b] = resolveExecutionTargetInstructionWithInfo(Definition, inst, instruction_mod.info(Definition, inst));
            }
            break :blk t;
        };
    };
}

pub const HotColdDispatch = enum {
    enabled,
    disabled,
};

pub const DispatchConfig = struct {
    hot_cold: HotColdDispatch = .enabled,
};

pub const DispatchEntry = struct {
    opcode_byte: u8,
    /// Compatibility view for Ethereum-known and raw byte opcode callers.
    opcode: Opcode,
    info: OpInfo,
    availability: Resolution,
    static_gas: StaticGas,
    tier: OpcodeTier,
    execution_target: ExecutionTarget,
    hot_path: bool,

    pub fn defined(self: DispatchEntry) bool {
        return self.info.defined;
    }

    pub fn staticGasConstant(self: DispatchEntry) ?i64 {
        return switch (self.static_gas) {
            .constant => |gas| gas,
            .revision_bands => null,
        };
    }

    pub fn dispatchTarget(self: DispatchEntry) ExecutionTarget {
        if (self.availability == .never) return .invalid;
        return self.execution_target;
    }
};

pub const DispatchTable = [256]DispatchEntry;

pub fn Instruction(comptime Definition: type) type {
    return instruction_mod.Value(Definition);
}

pub fn instructionFromByte(comptime Definition: type, comptime opcode_byte: u8) Instruction(Definition) {
    return instruction_mod.fromByte(Definition, opcode_byte);
}

pub fn instructionContext(comptime Definition: type, comptime instruction: Instruction(Definition)) InstructionContext {
    return instruction_mod.context(Definition, instruction);
}

pub fn useHotColdDispatch(comptime config: DispatchConfig) bool {
    return switch (config.hot_cold) {
        .enabled => true,
        .disabled => false,
    };
}

pub fn resolveDispatchTable(comptime Definition: type, comptime support: Definition.Support) DispatchTable {
    // Zig's default quota is too small for materializing a 256-row table with
    // support-window gas folding and resolved execution targets.
    @setEvalBranchQuota(dispatchEvalBranchQuota(Definition));
    support.assertValid();

    var table: DispatchTable = undefined;
    inline for (0..256) |index| {
        const opcode_byte: u8 = @intCast(index);
        table[index] = resolveDispatchEntryByteAssumeValid(Definition, support, opcode_byte);
    }

    return table;
}

pub fn resolveDispatchEntry(comptime Definition: type, comptime support: Definition.Support, comptime opcode: Opcode) DispatchEntry {
    return resolveDispatchEntryByte(Definition, support, @intFromEnum(opcode));
}

pub fn resolveDispatchEntryByte(comptime Definition: type, comptime support: Definition.Support, comptime opcode_byte: u8) DispatchEntry {
    @setEvalBranchQuota(dispatchEvalBranchQuota(Definition));
    support.assertValid();

    return resolveDispatchEntryByteAssumeValid(Definition, support, opcode_byte);
}

pub fn resolveDispatchEntryInstruction(
    comptime Definition: type,
    comptime support: Definition.Support,
    comptime instruction: Instruction(Definition),
) DispatchEntry {
    @setEvalBranchQuota(dispatchEvalBranchQuota(Definition));
    support.assertValid();

    return switch (comptime instructionContext(Definition, instruction)) {
        .byte => |opcode_byte| resolveDispatchEntryByteAssumeValid(Definition, support, opcode_byte),
        .custom => |context| resolveDispatchEntryCustomInstructionAssumeValid(Definition, support, instruction, context.first_byte),
    };
}

fn resolveDispatchEntryByteAssumeValid(comptime Definition: type, comptime support: Definition.Support, comptime opcode_byte: u8) DispatchEntry {
    @setEvalBranchQuota(dispatchEvalBranchQuota(Definition));
    const tables = InstructionTables(Definition);
    const opcode: Opcode = @enumFromInt(opcode_byte);
    const info = tables.info[opcode_byte];
    const availability = Definition.resolveAvailability(tables.raw_availability[opcode_byte], support);
    const static_gas = resolveStaticGasByteWithInfo(Definition, support, opcode_byte, info);
    const tier = tables.tier[opcode_byte];
    const execution_target = tables.execution_target[opcode_byte];
    return .{
        .opcode_byte = opcode_byte,
        .opcode = opcode,
        .info = info,
        .availability = availability,
        .static_gas = static_gas,
        .tier = tier,
        .execution_target = execution_target,
        .hot_path = hotPathFromResolved(tier, availability, static_gas),
    };
}

fn resolveDispatchEntryCustomInstructionAssumeValid(
    comptime Definition: type,
    comptime support: Definition.Support,
    comptime instruction: Instruction(Definition),
    comptime first_byte: u8,
) DispatchEntry {
    @setEvalBranchQuota(dispatchEvalBranchQuota(Definition));
    const opcode: Opcode = @enumFromInt(first_byte);
    const info = instruction_mod.info(Definition, instruction);
    const availability = Definition.resolveAvailability(instruction_mod.availability(Definition, instruction), support);
    const static_gas = resolveStaticGasInstructionWithInfo(Definition, support, instruction, info);
    const tier = instruction_mod.tier(Definition, instruction);
    const execution_target = resolveExecutionTargetInstructionWithInfo(Definition, instruction, info);
    return .{
        .opcode_byte = first_byte,
        .opcode = opcode,
        .info = info,
        .availability = availability,
        .static_gas = static_gas,
        .tier = tier,
        .execution_target = execution_target,
        .hot_path = hotPathFromResolved(tier, availability, static_gas),
    };
}

pub fn resolveExecutionTarget(comptime Definition: type, comptime opcode: Opcode) ExecutionTarget {
    return resolveExecutionTargetByte(Definition, @intFromEnum(opcode));
}

pub fn resolveExecutionTargetByte(comptime Definition: type, comptime opcode_byte: u8) ExecutionTarget {
    const instruction = instructionFromByte(Definition, opcode_byte);
    return resolveExecutionTargetInstructionWithInfo(Definition, instruction, instruction_mod.info(Definition, instruction));
}

pub fn resolveExecutionTargetInstruction(
    comptime Definition: type,
    comptime instruction: Instruction(Definition),
) ExecutionTarget {
    return switch (comptime instructionContext(Definition, instruction)) {
        .byte => |opcode_byte| resolveExecutionTargetByte(Definition, opcode_byte),
        .custom => resolveExecutionTargetInstructionWithInfo(Definition, instruction, resolveOpcodeInfoInstruction(Definition, instruction)),
    };
}

fn resolveExecutionTargetInstructionWithInfo(
    comptime Definition: type,
    comptime instruction: Instruction(Definition),
    comptime info: OpInfo,
) ExecutionTarget {
    if (!info.defined) return .invalid;

    const target = instruction_mod.executionTarget(Definition, instruction);
    execution.assertValidTarget(target);
    return target;
}

pub fn resolveOpcodeTier(comptime Definition: type, comptime opcode: Opcode) OpcodeTier {
    return resolveOpcodeTierByte(Definition, @intFromEnum(opcode));
}

pub fn resolveOpcodeTierByte(comptime Definition: type, comptime opcode_byte: u8) OpcodeTier {
    return instruction_mod.tier(Definition, instructionFromByte(Definition, opcode_byte));
}

pub fn resolveOpcodeTierInstruction(comptime Definition: type, comptime instruction: Instruction(Definition)) OpcodeTier {
    switch (comptime instructionContext(Definition, instruction)) {
        .byte => |opcode_byte| return resolveOpcodeTierByte(Definition, opcode_byte),
        .custom => {},
    }
    return instruction_mod.tier(Definition, instruction);
}

pub fn resolveStaticGas(comptime Definition: type, comptime support: Definition.Support, comptime opcode: Opcode) StaticGas {
    return resolveStaticGasByte(Definition, support, @intFromEnum(opcode));
}

pub fn resolveStaticGasByte(comptime Definition: type, comptime support: Definition.Support, comptime opcode_byte: u8) StaticGas {
    @setEvalBranchQuota(dispatchEvalBranchQuota(Definition));
    return resolveStaticGasByteWithInfo(Definition, support, opcode_byte, Definition.opcodeInfoByte(opcode_byte));
}

pub fn resolveStaticGasInstruction(
    comptime Definition: type,
    comptime support: Definition.Support,
    comptime instruction: Instruction(Definition),
) StaticGas {
    @setEvalBranchQuota(dispatchEvalBranchQuota(Definition));
    switch (comptime instructionContext(Definition, instruction)) {
        .byte => |opcode_byte| return resolveStaticGasByteWithInfo(Definition, support, opcode_byte, Definition.opcodeInfoByte(opcode_byte)),
        .custom => {},
    }
    return resolveStaticGasInstructionWithInfo(Definition, support, instruction, resolveOpcodeInfoInstruction(Definition, instruction));
}

fn staticGasSource(comptime Definition: type) type {
    if (@hasDecl(Definition, "StaticGasSource")) return Definition.StaticGasSource;
    return Definition;
}

fn sourceSupportMatches(comptime Source: type, comptime Support: type) bool {
    return !@hasDecl(Source, "Support") or Source.Support == Support;
}

fn sourceStaticGasByte(comptime Definition: type, comptime support: Definition.Support, comptime opcode_byte: u8) ?StaticGas {
    const Source = staticGasSource(Definition);
    if (comptime std.meta.hasFn(Source, "staticGasByteFor")) {
        return Source.staticGasByteFor(Definition, opcode_byte, support);
    }
    if (comptime std.meta.hasFn(Source, "staticGasByte") and sourceSupportMatches(Source, Definition.Support)) {
        return Source.staticGasByte(opcode_byte, support);
    }
    if (comptime std.meta.hasFn(Source, "staticGas") and sourceSupportMatches(Source, Definition.Support)) {
        return Source.staticGas(@enumFromInt(opcode_byte), support);
    }
    return null;
}

fn sourceStaticGasInstruction(
    comptime Definition: type,
    comptime support: Definition.Support,
    comptime instruction: Instruction(Definition),
) ?StaticGas {
    const Source = staticGasSource(Definition);
    if (comptime std.meta.hasFn(Source, "staticGasInstruction") and sourceSupportMatches(Source, Definition.Support)) {
        return Source.staticGasInstruction(instruction, support);
    }
    return null;
}

fn resolveStaticGasByteWithInfo(comptime Definition: type, comptime support: Definition.Support, comptime opcode_byte: u8, comptime info: OpInfo) StaticGas {
    @setEvalBranchQuota(dispatchEvalBranchQuota(Definition));
    if (comptime sourceStaticGasByte(Definition, support, opcode_byte)) |static_gas| return static_gas;
    if (!info.defined) return .{ .constant = 0 };

    var bands = support_mod.StaticGasBands{};
    var last: ?i64 = null;
    if (support.min == support.max) {
        return .{ .constant = Definition.staticGasForRevisionByte(support.min, opcode_byte) };
    }

    inline for (Definition.revisions) |revision_value| {
        if (support.contains(revision_value)) {
            const gas = Definition.staticGasForRevisionByte(revision_value, opcode_byte);
            if (last == null or last.? != gas) {
                bands.appendRevision(revision_value, gas);
                last = gas;
            }
        }
    }

    if (bands.len == 1) return .{ .constant = bands.items[0].gas };
    return .{ .revision_bands = bands };
}

fn resolveStaticGasInstructionWithInfo(
    comptime Definition: type,
    comptime support: Definition.Support,
    comptime instruction: Instruction(Definition),
    comptime info: OpInfo,
) StaticGas {
    @setEvalBranchQuota(dispatchEvalBranchQuota(Definition));
    if (comptime sourceStaticGasInstruction(Definition, support, instruction)) |static_gas| return static_gas;
    if (!info.defined) return .{ .constant = 0 };

    var bands = support_mod.StaticGasBands{};
    var last: ?i64 = null;
    if (support.min == support.max) {
        return .{ .constant = resolveStaticGasForRevisionInstruction(Definition, support.min, instruction) };
    }

    inline for (Definition.revisions) |revision_value| {
        if (support.contains(revision_value)) {
            const gas = resolveStaticGasForRevisionInstruction(Definition, revision_value, instruction);
            if (last == null or last.? != gas) {
                bands.appendRevision(revision_value, gas);
                last = gas;
            }
        }
    }

    if (bands.len == 1) return .{ .constant = bands.items[0].gas };
    return .{ .revision_bands = bands };
}

pub fn resolveOpcodeInfoInstruction(comptime Definition: type, comptime instruction: Instruction(Definition)) OpInfo {
    return instruction_mod.info(Definition, instruction);
}

pub fn resolveOpcodeAvailabilityInstruction(comptime Definition: type, comptime instruction: Instruction(Definition)) Definition.Availability {
    return instruction_mod.availability(Definition, instruction);
}

pub fn resolveStaticGasForRevisionInstruction(
    comptime Definition: type,
    revision: Definition.Revision,
    comptime instruction: Instruction(Definition),
) i64 {
    switch (comptime instructionContext(Definition, instruction)) {
        .byte => |opcode_byte| return Definition.staticGasForRevisionByte(revision, opcode_byte),
        .custom => {},
    }
    if (comptime std.meta.hasFn(Definition, "staticGasForRevisionInstruction")) {
        return Definition.staticGasForRevisionInstruction(revision, instruction);
    }
    @compileError("Definition with custom Instruction must declare staticGasForRevisionInstruction");
}

pub fn hotPathFromResolved(tier: OpcodeTier, availability: Resolution, static_gas: StaticGas) bool {
    if (tier != .hot) return false;
    if (availability != .always) return false;
    return switch (static_gas) {
        .constant => true,
        .revision_bands => false,
    };
}

test "ethereum support windows resolve opcode availability" {
    const ethereum = @import("../eth.zig");
    const Support = ethereum.Support;

    const full = resolveDispatchTable(ethereum, Support.all);
    try std.testing.expectEqual(Resolution.runtime, full[@intFromEnum(Opcode.BLOBBASEFEE)].availability);
    try std.testing.expectEqual(Resolution.runtime, full[@intFromEnum(Opcode.SLOTNUM)].availability);

    const cancun_plus = resolveDispatchTable(ethereum, Support.since(.cancun));
    try std.testing.expectEqual(Resolution.always, cancun_plus[@intFromEnum(Opcode.BLOBBASEFEE)].availability);
    try std.testing.expectEqual(Resolution.runtime, cancun_plus[@intFromEnum(Opcode.SLOTNUM)].availability);
    try std.testing.expectEqual(false, cancun_plus[@intFromEnum(Opcode.SLOTNUM)].hot_path);

    const exact_cancun = resolveDispatchTable(ethereum, Support.at(.cancun));
    try std.testing.expectEqual(Resolution.always, exact_cancun[@intFromEnum(Opcode.BLOBBASEFEE)].availability);
    try std.testing.expectEqual(Resolution.never, exact_cancun[@intFromEnum(Opcode.SLOTNUM)].availability);
}

test "ethereum support windows collapse stable static gas" {
    const ethereum = @import("../eth.zig");
    const Support = ethereum.Support;

    const full = resolveDispatchTable(ethereum, Support.all);
    try std.testing.expectEqual(@as(?i64, null), full[@intFromEnum(Opcode.BALANCE)].staticGasConstant());
    try std.testing.expectEqual(@as(?i64, 2), full[@intFromEnum(Opcode.BASEFEE)].staticGasConstant());
    const balance_gas = switch (full[@intFromEnum(Opcode.BALANCE)].static_gas) {
        .revision_bands => |bands| bands,
        .constant => unreachable,
    };
    try std.testing.expectEqual(@as(u8, 4), balance_gas.len);
    try std.testing.expectEqual(@as(i64, 20), balance_gas.items[0].gas);
    try std.testing.expectEqual(@as(i64, 400), balance_gas.items[1].gas);
    try std.testing.expectEqual(@as(i64, 700), balance_gas.items[2].gas);
    try std.testing.expectEqual(@as(i64, 100), balance_gas.items[3].gas);

    const berlin_plus = resolveDispatchTable(ethereum, Support.since(.berlin));
    try std.testing.expectEqual(@as(?i64, 100), berlin_plus[@intFromEnum(Opcode.BALANCE)].staticGasConstant());
    try std.testing.expectEqual(@as(?i64, 100), berlin_plus[@intFromEnum(Opcode.SLOAD)].staticGasConstant());

    const cancun_plus = resolveDispatchTable(ethereum, Support.since(.cancun));
    try std.testing.expectEqual(@as(?i64, null), cancun_plus[@intFromEnum(Opcode.CREATE)].staticGasConstant());

    const exact_cancun = resolveDispatchTable(ethereum, Support.at(.cancun));
    try std.testing.expectEqual(@as(?i64, 32000), exact_cancun[@intFromEnum(Opcode.CREATE)].staticGasConstant());
}

test "static gas folding uses support containment instead of revision tag order" {
    const ReverseRevision = enum(u8) {
        alpha = 10,
        beta = 5,
    };
    const ReverseDefinition = struct {
        pub const Revision = ReverseRevision;
        pub const revisions: []const Revision = &.{ .alpha, .beta };

        pub const Support = struct {
            min: Revision = .alpha,
            max: Revision = .beta,

            pub const all: Support = .{};

            pub fn assertValid(comptime self: Support) void {
                _ = self;
            }

            pub fn contains(self: Support, revision: Revision) bool {
                _ = self;
                return revision == .alpha or revision == .beta;
            }
        };

        pub fn opcodeInfoByte(comptime opcode_byte: u8) OpInfo {
            _ = opcode_byte;
            return .{ .defined = true };
        }

        pub fn staticGasForRevisionByte(revision: Revision, comptime opcode_byte: u8) i64 {
            _ = opcode_byte;
            return switch (revision) {
                .alpha => 1,
                .beta => 2,
            };
        }
    };

    const resolved = resolveStaticGasByte(ReverseDefinition, ReverseDefinition.Support.all, 0);
    const bands = switch (resolved) {
        .revision_bands => |bands| bands,
        .constant => unreachable,
    };
    try std.testing.expectEqual(@as(u8, 2), bands.len);
    try std.testing.expectEqual(@as(i64, 1), bands.items[0].gas);
    try std.testing.expectEqual(@as(i64, 2), bands.items[1].gas);
}

test "resolved hot path requires tier, always availability, and constant gas" {
    const ethereum = @import("../eth.zig");
    const Support = ethereum.Support;

    const full = resolveDispatchTable(ethereum, Support.all);
    try std.testing.expect(full[@intFromEnum(Opcode.ADD)].hot_path);
    try std.testing.expect(full[@intFromEnum(Opcode.PUSH1)].hot_path);
    try std.testing.expect(!full[@intFromEnum(Opcode.PUSH0)].hot_path);
    try std.testing.expect(!full[@intFromEnum(Opcode.SLOAD)].hot_path);

    const shanghai_plus = resolveDispatchTable(ethereum, Support.since(.shanghai));
    try std.testing.expect(shanghai_plus[@intFromEnum(Opcode.PUSH0)].hot_path);
}
