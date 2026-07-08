const std = @import("std");
const opcode_info = @import("../opcode.zig");
const tx = @import("transaction.zig");
const execution = @import("../protocol/execution.zig");
const interface = @import("../protocol/interface.zig");
const instruction_mod = @import("../protocol/instruction.zig");
const support = @import("../protocol/support.zig");
const revision_mod = @import("revision.zig");

const Opcode = opcode_info.Opcode;
const OpInfo = opcode_info.OpInfo;
const Revision = revision_mod.Revision;
const model = support.Model(Revision);
const cold_account_access_cost: i64 = 2600;
const warm_storage_read_cost: i64 = 100;
const cold_account_access_gas: i64 = cold_account_access_cost - warm_storage_read_cost;

const static_gas_definition = struct {
    pub const Revision = revision_mod.Revision;
    pub const revisions = std.enums.values(revision_mod.Revision);
    pub const Support = model.Support;
};

pub const Availability = model.Availability;
pub const Support = model.Support;

pub const Instruction = struct {
    pub const Value = u8;

    pub const RevisionOverrides = struct {
        pub const availability: AvailabilityOverrides = .init(&.{
            .{ .since = .homestead, .opcodes = &.{.DELEGATECALL} },
            .{ .since = .byzantium, .opcodes = &.{ .RETURNDATASIZE, .RETURNDATACOPY, .STATICCALL, .REVERT } },
            .{ .since = .constantinople, .opcodes = &.{ .SHL, .SHR, .SAR, .EXTCODEHASH, .CREATE2 } },
            .{ .since = .istanbul, .opcodes = &.{ .CHAINID, .SELFBALANCE } },
            .{ .since = .london, .opcodes = &.{.BASEFEE} },
            .{ .since = .shanghai, .opcodes = &.{.PUSH0} },
            .{ .since = .cancun, .opcodes = &.{ .BLOBHASH, .BLOBBASEFEE, .TLOAD, .TSTORE, .MCOPY } },
            .{ .since = .osaka, .opcodes = &.{.CLZ} },
            .{ .since = .amsterdam, .opcodes = &.{ .SLOTNUM, .DUPN, .SWAPN, .EXCHANGE } },
        });

        pub const static_gas: StaticGasOverrides = .init(.{
            .expected_opcodes = &.{
                .BALANCE,
                .EXTCODESIZE,
                .EXTCODECOPY,
                .EXTCODEHASH,
                .SLOAD,
                .CREATE,
                .CREATE2,
                .SELFDESTRUCT,
            },
            .rows = &.{
                .{ .since = .tangerine_whistle, .opcodes = &.{.BALANCE}, .value = 400 },
                .{ .since = .istanbul, .opcodes = &.{.BALANCE}, .value = 700 },
                .{ .since = .berlin, .opcodes = &.{.BALANCE}, .value = 100 },

                .{ .since = .tangerine_whistle, .opcodes = &.{ .EXTCODESIZE, .EXTCODECOPY }, .value = 700 },
                .{ .since = .berlin, .opcodes = &.{ .EXTCODESIZE, .EXTCODECOPY }, .value = 100 },

                .{ .since = .istanbul, .opcodes = &.{.EXTCODEHASH}, .value = 700 },
                .{ .since = .berlin, .opcodes = &.{.EXTCODEHASH}, .value = 100 },

                .{ .since = .tangerine_whistle, .opcodes = &.{.SLOAD}, .value = 200 },
                .{ .since = .istanbul, .opcodes = &.{.SLOAD}, .value = 800 },
                .{ .since = .berlin, .opcodes = &.{.SLOAD}, .value = 100 },

                .{ .since = .amsterdam, .opcodes = &.{ .CREATE, .CREATE2 }, .value = tx.amsterdam_create_access_cost },

                .{ .since = .tangerine_whistle, .opcodes = &.{.SELFDESTRUCT}, .value = 5_000 },
            },
        });
    };

    pub fn fromByte(comptime opcode_byte: u8) Value {
        return opcode_byte;
    }

    pub fn context(comptime value: Value) instruction_mod.Context {
        return .{ .byte = value };
    }

    pub fn info(comptime value: Value) OpInfo {
        return opcode_info.info(value);
    }

    pub fn availability(comptime value: Value) Availability {
        if (!info(value).defined) return .never;
        const opcode: Opcode = @enumFromInt(value);
        return resolveAvailability(RevisionOverrides.availability, opcode);
    }

    pub fn tier(comptime value: Value) support.OpcodeTier {
        if (value >= @intFromEnum(Opcode.PUSH0) and value <= @intFromEnum(Opcode.SWAP16)) {
            return .hot;
        }

        const opcode: Opcode = @enumFromInt(value);
        return switch (opcode) {
            .STOP,
            .ADD,
            .MUL,
            .SUB,
            .DIV,
            .SDIV,
            .MOD,
            .SMOD,
            .LT,
            .GT,
            .SLT,
            .SGT,
            .EQ,
            .ISZERO,
            .AND,
            .OR,
            .XOR,
            .NOT,
            .BYTE,
            .POP,
            .MLOAD,
            .MSTORE,
            .MSTORE8,
            .JUMP,
            .JUMPI,
            .PC,
            .MSIZE,
            .GAS,
            .JUMPDEST,
            => .hot,
            else => .cold,
        };
    }

    pub fn executionTarget(comptime value: Value) execution.ExecutionTarget {
        return execution.defaultTargetForInfoByte(value, info(value));
    }

    pub fn expByteGas(revision: Revision) i64 {
        return if (revision.isImpl(.spurious_dragon)) 50 else 10;
    }

    pub fn accountReadColdAccessGas(revision: Revision) ?i64 {
        if (!revision.isImpl(.berlin)) return null;
        if (revision.isImpl(.amsterdam)) return tx.amsterdam_cold_account_access_cost - warm_storage_read_cost;
        return cold_account_access_gas;
    }

    pub fn codeAccountAccessGas(revision: Revision, status: interface.AccountAccessStatus) ?i64 {
        if (!revision.isImpl(.berlin)) return null;
        return switch (status) {
            .cold => if (revision.isImpl(.amsterdam))
                std.math.cast(i64, tx.amsterdam_cold_account_access_cost) orelse std.math.maxInt(i64)
            else
                cold_account_access_gas,
            .warm => if (revision.isImpl(.amsterdam))
                warm_storage_read_cost
            else
                0,
        };
    }
};

const AvailabilityOverrides = struct {
    rows: []const AvailabilityOverride,

    fn init(comptime rows: []const AvailabilityOverride) AvailabilityOverrides {
        comptime {
            var previous: ?Revision = null;
            for (rows, 0..) |row, row_index| {
                if (previous) |previous_revision| {
                    if (!row.since.isImpl(previous_revision)) {
                        @compileError("Instruction.RevisionOverrides.availability rows must be fork-sorted");
                    }
                }
                previous = row.since;

                for (row.opcodes, 0..) |opcode, opcode_index| {
                    if (!opcode_info.info(@intFromEnum(opcode)).defined) {
                        @compileError("Instruction.RevisionOverrides.availability references undefined opcode " ++ @tagName(opcode));
                    }
                    for (row.opcodes, 0..) |other, other_index| {
                        if (other_index > opcode_index and other == opcode) {
                            @compileError("Instruction.RevisionOverrides.availability row lists " ++ @tagName(opcode) ++ " more than once");
                        }
                    }
                    for (rows, 0..) |other, other_index| {
                        if (other_index > row_index and other.matches(opcode)) {
                            @compileError("duplicate availability override for " ++ @tagName(opcode));
                        }
                    }
                }
            }
        }

        return .{ .rows = rows };
    }
};

const StaticGasOverrides = struct {
    expected_opcodes: []const Opcode,
    rows: []const StaticGasOverride,

    fn init(comptime overrides: StaticGasOverrides) StaticGasOverrides {
        comptime {
            for (overrides.expected_opcodes, 0..) |opcode, opcode_index| {
                if (!opcode_info.info(@intFromEnum(opcode)).defined) {
                    @compileError("Instruction.RevisionOverrides.static_gas.opcodes references undefined opcode " ++ @tagName(opcode));
                }
                for (overrides.expected_opcodes, 0..) |other, other_index| {
                    if (other_index > opcode_index and other == opcode) {
                        @compileError("Instruction.RevisionOverrides.static_gas.opcodes lists " ++ @tagName(opcode) ++ " more than once");
                    }
                }
            }

            for (overrides.rows) |row| {
                for (row.opcodes, 0..) |opcode, opcode_index| {
                    if (!opcode_info.info(@intFromEnum(opcode)).defined) {
                        @compileError("Instruction.RevisionOverrides.static_gas references undefined opcode " ++ @tagName(opcode));
                    }
                    for (row.opcodes, 0..) |other, other_index| {
                        if (other_index > opcode_index and other == opcode) {
                            @compileError("Instruction.RevisionOverrides.static_gas row lists " ++ @tagName(opcode) ++ " more than once");
                        }
                    }
                    if (!containsOpcode(overrides.expected_opcodes, opcode)) {
                        @compileError("static gas row references " ++ @tagName(opcode) ++ " but opcodes does not list it");
                    }
                }
            }

            for (overrides.expected_opcodes) |opcode| {
                var seen = false;
                var previous: ?Revision = null;
                for (overrides.rows) |row| {
                    if (row.matches(opcode)) {
                        seen = true;
                        if (previous) |previous_revision| {
                            if (row.since == previous_revision) {
                                @compileError("duplicate static gas override for " ++ @tagName(opcode) ++ " at " ++ @tagName(row.since));
                            }
                            if (!row.since.isImpl(previous_revision)) {
                                @compileError("static gas overrides for " ++ @tagName(opcode) ++ " must be fork-sorted");
                            }
                        }
                        previous = row.since;
                    }
                }
                if (!seen) {
                    @compileError("static gas override opcode set includes " ++ @tagName(opcode) ++ " but rows do not override it");
                }
            }
        }

        return overrides;
    }
};

const AvailabilityOverride = struct {
    opcodes: []const Opcode,
    since: Revision,

    fn matches(comptime self: AvailabilityOverride, comptime opcode: Opcode) bool {
        inline for (self.opcodes) |candidate| {
            if (candidate == opcode) return true;
        }
        return false;
    }
};

const StaticGasOverride = struct {
    opcodes: []const Opcode,
    since: Revision,
    value: i64,

    fn matches(comptime self: StaticGasOverride, comptime opcode: Opcode) bool {
        inline for (self.opcodes) |candidate| {
            if (candidate == opcode) return true;
        }
        return false;
    }
};

fn resolveAvailability(comptime overrides: AvailabilityOverrides, comptime opcode: Opcode) Availability {
    inline for (overrides.rows) |row| {
        if (row.matches(opcode)) return .{ .since = row.since };
    }
    return .always;
}

fn resolveStaticGasForRevision(comptime overrides: StaticGasOverrides, revision_value: Revision, comptime opcode: Opcode, base_static_gas: i64) i64 {
    var resolved_gas = base_static_gas;
    inline for (overrides.rows) |row| {
        if (row.matches(opcode) and revision_value.isImpl(row.since)) resolved_gas = row.value;
    }
    return resolved_gas;
}

fn resolveStaticGasForSupport(
    comptime Definition: type,
    comptime overrides: StaticGasOverrides,
    comptime support_window: Definition.Support,
    comptime opcode: Opcode,
    comptime base_static_gas: i64,
) support.StaticGas {
    support_window.assertValid();
    if (!containsOpcode(overrides.expected_opcodes, opcode)) return .{ .constant = base_static_gas };
    if (support_window.min == support_window.max) {
        return .{ .constant = resolveStaticGasForRevision(overrides, support_window.min, opcode, base_static_gas) };
    }

    var bands = support.StaticGasBands{};
    var last: ?i64 = null;
    inline for (Definition.revisions) |revision_value| {
        if (support_window.contains(revision_value)) {
            const gas = resolveStaticGasForRevision(overrides, revision_value, opcode, base_static_gas);
            if (last == null or last.? != gas) {
                bands.appendRevision(revision_value, gas);
                last = gas;
            }
        }
    }

    if (bands.len == 1) return .{ .constant = bands.items[0].gas };
    return .{ .revision_bands = bands };
}

fn containsOpcode(comptime opcodes: []const Opcode, comptime opcode: Opcode) bool {
    inline for (opcodes) |candidate| {
        if (candidate == opcode) return true;
    }
    return false;
}

pub fn opcodeInfoByte(comptime opcode_byte: u8) OpInfo {
    return Instruction.info(Instruction.fromByte(opcode_byte));
}

pub fn opcodeInfo(comptime opcode: Opcode) OpInfo {
    return opcodeInfoByte(@intFromEnum(opcode));
}

pub fn opcodeAvailabilityByte(comptime opcode_byte: u8) Availability {
    return Instruction.availability(Instruction.fromByte(opcode_byte));
}

pub fn opcodeAvailability(comptime opcode: Opcode) Availability {
    return opcodeAvailabilityByte(@intFromEnum(opcode));
}

pub fn opcodeTierByte(comptime opcode_byte: u8) support.OpcodeTier {
    return Instruction.tier(Instruction.fromByte(opcode_byte));
}

pub fn opcodeTier(comptime opcode: Opcode) support.OpcodeTier {
    return opcodeTierByte(@intFromEnum(opcode));
}

pub fn staticGasForRevisionByte(revision: Revision, comptime opcode_byte: u8) i64 {
    const info = opcodeInfoByte(opcode_byte);
    if (!info.defined) return 0;

    const opcode: Opcode = @enumFromInt(opcode_byte);
    return resolveStaticGasForRevision(Instruction.RevisionOverrides.static_gas, revision, opcode, @intCast(info.static_gas));
}

pub fn staticGasForRevision(revision: Revision, comptime opcode: Opcode) i64 {
    return staticGasForRevisionByte(revision, @intFromEnum(opcode));
}

pub fn staticGasByte(comptime opcode_byte: u8, comptime support_window: Support) support.StaticGas {
    return staticGasByteFor(static_gas_definition, opcode_byte, support_window);
}

pub fn staticGasByteFor(comptime Definition: type, comptime opcode_byte: u8, comptime support_window: Definition.Support) support.StaticGas {
    if (Definition.Revision != Revision) @compileError("eth.Instruction static gas requires eth.Revision");
    support_window.assertValid();
    const info = comptime opcodeInfoByte(opcode_byte);
    if (!info.defined) return .{ .constant = 0 };

    const opcode: Opcode = @enumFromInt(opcode_byte);
    return resolveStaticGasForSupport(Definition, Instruction.RevisionOverrides.static_gas, support_window, opcode, @intCast(info.static_gas));
}

pub fn staticGas(comptime opcode: Opcode, comptime support_window: Support) support.StaticGas {
    return staticGasByte(@intFromEnum(opcode), support_window);
}

test "ethereum static gas applies revision overrides over opcode base gas" {
    try std.testing.expectEqual(@as(i64, 20), staticGasForRevision(.frontier, .BALANCE));
    try std.testing.expectEqual(@as(i64, 400), staticGasForRevision(.tangerine_whistle, .BALANCE));
    try std.testing.expectEqual(@as(i64, 700), staticGasForRevision(.istanbul, .BALANCE));
    try std.testing.expectEqual(@as(i64, 100), staticGasForRevision(.berlin, .BALANCE));

    try std.testing.expectEqual(@as(i64, 20), staticGasForRevision(.frontier, .EXTCODESIZE));
    try std.testing.expectEqual(@as(i64, 700), staticGasForRevision(.tangerine_whistle, .EXTCODESIZE));
    try std.testing.expectEqual(@as(i64, 100), staticGasForRevision(.berlin, .EXTCODESIZE));

    try std.testing.expectEqual(@as(i64, 400), staticGasForRevision(.constantinople, .EXTCODEHASH));
    try std.testing.expectEqual(@as(i64, 700), staticGasForRevision(.istanbul, .EXTCODEHASH));
    try std.testing.expectEqual(@as(i64, 100), staticGasForRevision(.berlin, .EXTCODEHASH));

    try std.testing.expectEqual(@as(i64, 50), staticGasForRevision(.frontier, .SLOAD));
    try std.testing.expectEqual(@as(i64, 200), staticGasForRevision(.tangerine_whistle, .SLOAD));
    try std.testing.expectEqual(@as(i64, 800), staticGasForRevision(.istanbul, .SLOAD));
    try std.testing.expectEqual(@as(i64, 100), staticGasForRevision(.berlin, .SLOAD));

    try std.testing.expectEqual(@as(i64, 32_000), staticGasForRevision(.cancun, .CREATE));
    try std.testing.expectEqual(@as(i64, tx.amsterdam_create_access_cost), staticGasForRevision(.amsterdam, .CREATE));

    try std.testing.expectEqual(@as(i64, 0), staticGasForRevision(.frontier, .SELFDESTRUCT));
    try std.testing.expectEqual(@as(i64, 5_000), staticGasForRevision(.tangerine_whistle, .SELFDESTRUCT));
}

test "ethereum static gas support windows resolve to bands or constants" {
    const full_balance = staticGas(.BALANCE, Support.all);
    const balance_bands = switch (full_balance) {
        .revision_bands => |bands| bands,
        .constant => return error.ExpectedRevisionBands,
    };
    try std.testing.expectEqual(@as(u8, 4), balance_bands.len);
    try std.testing.expectEqual(support.revisionId(Revision.frontier), balance_bands.items[0].since);
    try std.testing.expectEqual(@as(i64, 20), balance_bands.items[0].gas);
    try std.testing.expectEqual(support.revisionId(Revision.tangerine_whistle), balance_bands.items[1].since);
    try std.testing.expectEqual(@as(i64, 400), balance_bands.items[1].gas);
    try std.testing.expectEqual(support.revisionId(Revision.istanbul), balance_bands.items[2].since);
    try std.testing.expectEqual(@as(i64, 700), balance_bands.items[2].gas);
    try std.testing.expectEqual(support.revisionId(Revision.berlin), balance_bands.items[3].since);
    try std.testing.expectEqual(@as(i64, 100), balance_bands.items[3].gas);

    try std.testing.expectEqual(@as(i64, 2), switch (staticGas(.BASEFEE, Support.all)) {
        .constant => |gas| gas,
        .revision_bands => return error.ExpectedConstant,
    });

    const create = staticGas(.CREATE, Support.range(.cancun, .amsterdam));
    const create_bands = switch (create) {
        .revision_bands => |bands| bands,
        .constant => return error.ExpectedRevisionBands,
    };
    try std.testing.expectEqual(@as(u8, 2), create_bands.len);
    try std.testing.expectEqual(support.revisionId(Revision.cancun), create_bands.items[0].since);
    try std.testing.expectEqual(@as(i64, 32_000), create_bands.items[0].gas);
    try std.testing.expectEqual(support.revisionId(Revision.amsterdam), create_bands.items[1].since);
    try std.testing.expectEqual(@as(i64, tx.amsterdam_create_access_cost), create_bands.items[1].gas);
}
