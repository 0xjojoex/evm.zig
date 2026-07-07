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
const revision = support.Model(Revision);
const cold_account_access_cost: i64 = 2600;
const warm_storage_read_cost: i64 = 100;
const cold_account_access_gas: i64 = cold_account_access_cost - warm_storage_read_cost;
const static_gas_definition = struct {
    pub const Revision = revision_mod.Revision;
    pub const revisions = std.enums.values(revision_mod.Revision);
    pub const Support = revision.Support;
};

pub const Availability = revision.Availability;
pub const Support = revision.Support;

pub const Instruction = struct {
    pub const Value = u8;

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

        return switch (opcode) {
            .DELEGATECALL => .{ .since = .homestead },
            .RETURNDATASIZE,
            .RETURNDATACOPY,
            .STATICCALL,
            .REVERT,
            => .{ .since = .byzantium },
            .SHL,
            .SHR,
            .SAR,
            .EXTCODEHASH,
            .CREATE2,
            => .{ .since = .constantinople },
            .CHAINID,
            .SELFBALANCE,
            => .{ .since = .istanbul },
            .BASEFEE => .{ .since = .london },
            .PUSH0 => .{ .since = .shanghai },
            .BLOBHASH,
            .BLOBBASEFEE,
            .TLOAD,
            .TSTORE,
            .MCOPY,
            => .{ .since = .cancun },
            .CLZ => .{ .since = .osaka },
            .SLOTNUM,
            .DUPN,
            .SWAPN,
            .EXCHANGE,
            => .{ .since = .amsterdam },
            else => .always,
        };
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

    pub fn expByteGas(spec: Revision) i64 {
        return if (spec.isImpl(.spurious_dragon)) 50 else 10;
    }

    pub fn accountReadColdAccessGas(spec: Revision) ?i64 {
        if (!spec.isImpl(.berlin)) return null;
        if (spec.isImpl(.amsterdam)) return tx.amsterdam_cold_account_access_cost - warm_storage_read_cost;
        return cold_account_access_gas;
    }

    pub fn codeAccountAccessGas(spec: Revision, status: interface.AccountAccessStatus) ?i64 {
        if (!spec.isImpl(.berlin)) return null;
        return switch (status) {
            .cold => if (spec.isImpl(.amsterdam))
                std.math.cast(i64, tx.amsterdam_cold_account_access_cost) orelse std.math.maxInt(i64)
            else
                cold_account_access_gas,
            .warm => if (spec.isImpl(.amsterdam))
                warm_storage_read_cost
            else
                0,
        };
    }
};

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

pub fn staticGasForRevisionByte(spec: Revision, comptime opcode_byte: u8) i64 {
    const opcode: Opcode = @enumFromInt(opcode_byte);
    return switch (opcode) {
        .BALANCE => if (spec.isImpl(.berlin))
            100
        else if (spec.isImpl(.istanbul))
            700
        else if (spec.isImpl(.tangerine_whistle))
            400
        else
            20,
        .EXTCODESIZE, .EXTCODECOPY => if (spec.isImpl(.berlin))
            100
        else if (spec.isImpl(.tangerine_whistle))
            700
        else
            20,
        .EXTCODEHASH => if (spec.isImpl(.berlin))
            100
        else if (spec.isImpl(.istanbul))
            700
        else
            400,
        .SLOAD => if (spec.isImpl(.berlin))
            100
        else if (spec.isImpl(.istanbul))
            800
        else if (spec.isImpl(.tangerine_whistle))
            200
        else
            50,
        .CREATE, .CREATE2 => if (spec.isImpl(.amsterdam))
            tx.amsterdam_create_access_cost
        else
            @intCast(opcodeInfo(opcode).static_gas),
        .SELFDESTRUCT => if (spec.isImpl(.tangerine_whistle)) 5000 else 0,
        else => @intCast(opcodeInfoByte(opcode_byte).static_gas),
    };
}

pub fn staticGasForRevision(spec: Revision, comptime opcode: Opcode) i64 {
    return staticGasForRevisionByte(spec, @intFromEnum(opcode));
}

pub fn staticGasByte(comptime opcode_byte: u8, comptime support_window: Support) support.StaticGas {
    return staticGasByteFor(static_gas_definition, opcode_byte, support_window);
}

pub fn staticGasByteFor(comptime Definition: type, comptime opcode_byte: u8, comptime support_window: Definition.Support) support.StaticGas {
    if (Definition.Revision != Revision) @compileError("eth.Instruction static gas requires eth.Revision");
    support_window.assertValid();
    if (!opcodeInfoByte(opcode_byte).defined) return .{ .constant = 0 };
    const opcode: Opcode = @enumFromInt(opcode_byte);

    return switch (opcode) {
        .BALANCE,
        .EXTCODESIZE,
        .EXTCODECOPY,
        .EXTCODEHASH,
        .SLOAD,
        .CREATE,
        .CREATE2,
        .SELFDESTRUCT,
        => resolveStaticGasForSupport(Definition, opcode_byte, support_window),
        else => .{ .constant = @intCast(opcodeInfoByte(opcode_byte).static_gas) },
    };
}

pub fn staticGas(comptime opcode: Opcode, comptime support_window: Support) support.StaticGas {
    return staticGasByte(@intFromEnum(opcode), support_window);
}

fn resolveStaticGasForSupport(comptime Definition: type, comptime opcode_byte: u8, comptime support_window: Definition.Support) support.StaticGas {
    if (support_window.min == support_window.max) {
        return .{ .constant = staticGasForRevisionByte(support_window.min, opcode_byte) };
    }

    var bands = support.StaticGasBands{};
    var last: ?i64 = null;
    inline for (Definition.revisions) |revision_value| {
        if (support_window.contains(revision_value)) {
            const gas = staticGasForRevisionByte(revision_value, opcode_byte);
            if (last == null or last.? != gas) {
                bands.appendRevision(revision_value, gas);
                last = gas;
            }
        }
    }

    if (bands.len == 1) return .{ .constant = bands.items[0].gas };
    return .{ .revision_bands = bands };
}
