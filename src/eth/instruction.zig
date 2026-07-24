const std = @import("std");
const opcode_info = @import("../opcode.zig");
const tx = @import("transaction.zig");
const instruction_table = @import("../instruction/table.zig");

const Opcode = opcode_info.Opcode;
const warm_storage_read_cost: i64 = 100;

pub const Spec = instruction_table.Spec;

fn baseSpec() Spec {
    @setEvalBranchQuota(10_000);
    var spec: Spec = .{
        .table = undefined,
        .exp_byte_gas = 10,
        .account_read_cold_access_gas = null,
        .code_account_cold_access_gas = null,
        .code_account_warm_access_gas = null,
    };
    for (0..256) |index| {
        const opcode_byte: u8 = @intCast(index);
        const info = opcode_info.info(opcode_byte);
        spec.table[index] = .{
            .info = info,
            .active = false,
            .static_gas = if (info.defined) @intCast(info.static_gas) else 0,
            .target = defaultTarget(opcode_byte, info.defined),
        };
    }

    // activate the default range
    spec.activateRange(.STOP, .SIGNEXTEND);
    spec.activateRange(.LT, .BYTE);
    spec.activateRange(.ADDRESS, .EXTCODECOPY);
    spec.activateRange(.BLOCKHASH, .GASLIMIT);
    spec.activateRange(.POP, .JUMPDEST);
    spec.activateRange(.PUSH1, .PUSH32);
    spec.activateRange(.DUP1, .SWAP16);
    spec.activateRange(.LOG0, .LOG4);
    spec.activateRange(.CREATE, .RETURN);
    spec.activate(&.{ .INVALID, .SELFDESTRUCT, .KECCAK256 });
    return spec;
}

fn defaultTarget(comptime opcode_byte: u8, comptime defined: bool) instruction_table.Target {
    if (!defined) return .invalid;
    const opcode: Opcode = @enumFromInt(opcode_byte);
    return switch (opcode) {
        .INVALID => .invalid,
        else => .{ .builtin = opcode },
    };
}

const frontier_spec = baseSpec();
pub const frontier = frontier_spec;
pub const frontier_thawing = frontier;

const homestead_spec: Spec = spec: {
    var result = frontier_thawing;
    result.activate(&.{.DELEGATECALL});
    break :spec result;
};
pub const homestead = homestead_spec;

pub const dao_fork = homestead;

const tangerine_whistle_spec: Spec = spec: {
    var result = dao_fork;
    result.setStaticGas(&.{.BALANCE}, 400);
    result.setStaticGas(&.{ .EXTCODESIZE, .EXTCODECOPY }, 700);
    result.setStaticGas(&.{.SLOAD}, 200);
    result.setStaticGas(&.{.SELFDESTRUCT}, 5_000);
    break :spec result;
};
pub const tangerine_whistle = tangerine_whistle_spec;

const spurious_dragon_spec: Spec = spec: {
    var result = tangerine_whistle;
    result.exp_byte_gas = 50;
    break :spec result;
};
pub const spurious_dragon = spurious_dragon_spec;

const byzantium_spec: Spec = spec: {
    var result = spurious_dragon;
    result.activate(&.{ .RETURNDATASIZE, .RETURNDATACOPY, .STATICCALL, .REVERT });
    break :spec result;
};
pub const byzantium = byzantium_spec;

const constantinople_spec: Spec = spec: {
    var result = byzantium;
    result.activate(&.{ .SHL, .SHR, .SAR, .EXTCODEHASH, .CREATE2 });
    break :spec result;
};
pub const constantinople = constantinople_spec;

pub const petersburg = constantinople;

const istanbul_spec: Spec = spec: {
    var result = petersburg;
    result.activate(&.{ .CHAINID, .SELFBALANCE });
    result.setStaticGas(&.{.BALANCE}, 700);
    result.setStaticGas(&.{.EXTCODEHASH}, 700);
    result.setStaticGas(&.{.SLOAD}, 800);
    break :spec result;
};
pub const istanbul = istanbul_spec;

pub const muir_glacier = istanbul;

const berlin_spec: Spec = spec: {
    var result = muir_glacier;
    result.setStaticGas(&.{ .BALANCE, .EXTCODESIZE, .EXTCODECOPY, .EXTCODEHASH, .SLOAD }, 100);
    result.account_read_cold_access_gas = 2_500;
    result.code_account_cold_access_gas = 2_500;
    result.code_account_warm_access_gas = 0;
    break :spec result;
};
pub const berlin = berlin_spec;

const london_spec: Spec = spec: {
    var result = berlin;
    result.activate(&.{.BASEFEE});
    break :spec result;
};
pub const london = london_spec;

pub const arrow_glacier = london;
pub const gray_glacier = arrow_glacier;
pub const merge = gray_glacier;

const shanghai_spec: Spec = spec: {
    var result = merge;
    result.activate(&.{.PUSH0});
    break :spec result;
};
pub const shanghai = shanghai_spec;

const cancun_spec: Spec = spec: {
    var result = shanghai;
    result.activate(&.{ .BLOBHASH, .BLOBBASEFEE, .TLOAD, .TSTORE, .MCOPY });
    break :spec result;
};
pub const cancun = cancun_spec;

pub const prague = cancun;

const osaka_spec: Spec = spec: {
    var result = prague;
    result.activate(&.{.CLZ});
    break :spec result;
};
pub const osaka = osaka_spec;

const amsterdam_spec: Spec = spec: {
    var result = osaka;
    result.activate(&.{ .SLOTNUM, .DUPN, .SWAPN, .EXCHANGE });
    result.setStaticGas(&.{ .CREATE, .CREATE2 }, tx.amsterdam_create_access_cost);
    result.account_read_cold_access_gas = tx.amsterdam_cold_account_access_cost - warm_storage_read_cost;
    result.code_account_cold_access_gas = tx.amsterdam_cold_account_access_cost;
    result.code_account_warm_access_gas = warm_storage_read_cost;
    break :spec result;
};
pub const amsterdam = amsterdam_spec;

test "exact instruction specs extend activation and gas values" {
    try std.testing.expect(!frontier.table[@intFromEnum(Opcode.DELEGATECALL)].active);
    try std.testing.expect(homestead.table[@intFromEnum(Opcode.DELEGATECALL)].active);
    try std.testing.expect(!shanghai.table[@intFromEnum(Opcode.BLOBHASH)].active);
    try std.testing.expect(cancun.table[@intFromEnum(Opcode.BLOBHASH)].active);
    try std.testing.expect(!osaka.table[@intFromEnum(Opcode.SLOTNUM)].active);
    try std.testing.expect(amsterdam.table[@intFromEnum(Opcode.SLOTNUM)].active);

    try std.testing.expectEqual(@as(i64, 20), frontier.table[@intFromEnum(Opcode.BALANCE)].static_gas);
    try std.testing.expectEqual(@as(i64, 400), tangerine_whistle.table[@intFromEnum(Opcode.BALANCE)].static_gas);
    try std.testing.expectEqual(@as(i64, 700), istanbul.table[@intFromEnum(Opcode.BALANCE)].static_gas);
    try std.testing.expectEqual(@as(i64, 100), berlin.table[@intFromEnum(Opcode.BALANCE)].static_gas);
    try std.testing.expectEqual(@as(i64, tx.amsterdam_create_access_cost), amsterdam.table[@intFromEnum(Opcode.CREATE)].static_gas);
}

test "instruction spec mutation helpers derive one table value from another" {
    const Noop = struct {
        pub inline fn execute(comptime Instructions: type, frame: anytype) anyerror!void {
            _ = Instructions;
            _ = frame;
        }
    };
    const unassigned_byte: u8 = 0xb0;
    comptime std.debug.assert(!opcode_info.info(unassigned_byte).defined);

    const derived = comptime spec: {
        var result = cancun;
        result.install(unassigned_byte, 5, .{ .custom = Noop });
        result.deactivate(&.{.SELFDESTRUCT});
        result.setStaticGas(&.{.BALANCE}, 1_000);
        result.setTarget(@intFromEnum(Opcode.ADD), .invalid);
        break :spec result;
    };

    try std.testing.expect(derived.table[unassigned_byte].active);
    try std.testing.expectEqual(@as(i64, 5), derived.table[unassigned_byte].static_gas);
    try std.testing.expect(derived.table[unassigned_byte].target == .custom);
    try std.testing.expect(!derived.table[@intFromEnum(Opcode.SELFDESTRUCT)].active);
    try std.testing.expectEqual(@as(i64, 1_000), derived.table[@intFromEnum(Opcode.BALANCE)].static_gas);
    try std.testing.expect(derived.table[@intFromEnum(Opcode.ADD)].target == .invalid);
    // The base value stays untouched.
    try std.testing.expect(!cancun.table[unassigned_byte].active);
    try std.testing.expect(cancun.table[@intFromEnum(Opcode.SELFDESTRUCT)].active);
}

test "exact instruction spec carries execution constants as values" {
    try std.testing.expectEqual(@as(i64, 10), frontier.exp_byte_gas);
    try std.testing.expectEqual(@as(i64, 50), spurious_dragon.exp_byte_gas);
    try std.testing.expectEqual(@as(?i64, null), istanbul.account_read_cold_access_gas);
    try std.testing.expectEqual(@as(?i64, 2_500), berlin.account_read_cold_access_gas);
    try std.testing.expectEqual(
        @as(?i64, tx.amsterdam_cold_account_access_cost - warm_storage_read_cost),
        amsterdam.account_read_cold_access_gas,
    );
}
