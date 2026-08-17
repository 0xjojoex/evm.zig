//! Golden fork × parameter table.
//!
//! One row per revision, Individual forks are covered elsewhere; what
//! this adds is adjacency and completeness — a repricing that lands on one fork
//! but silently changes another shows up here as a diff, and a consensus-relevant
//! value cannot move without an explicit edit to this table.
//!
//! Reads exact spec values only, so it needs no compiled VM and runs the whole
//! matrix regardless of `-Dtest-forks`.
//!
//! Access-list and initcode columns carry a value on forks that predate the EIP
//! introducing them; the spec field exists throughout and is simply unused until
//! then. `unbounded` marks "no limit configured".

const std = @import("std");
const evmz = @import("../evm.zig");

const Opcode = evmz.Opcode;
const Revision = evmz.eth.Revision;

const unbounded = std.math.maxInt(usize);

const Row = struct {
    revision: Revision,
    balance_static_gas: i64,
    cold_account_surcharge: ?i64,
    sload_static_gas: i64,
    cold_sload_surcharge: ?i64,
    sstore_set_cost: i64,
    sstore_clear_refund: i64,
    tx_intrinsic_base: ?u64,
    calldata_nonzero_byte: ?u64,
    calldata_zero_byte: ?u64,
    access_list_address: u64,
    access_list_storage_key: u64,
    initcode_word_gas: u64,
    max_initcode_size: usize,
    call_base_gas: i64,
    selfdestruct_refund: i64,
};

fn row(values: anytype) Row {
    const fields = std.meta.fields(Row);
    comptime std.debug.assert(std.meta.fields(@TypeOf(values)).len == fields.len);

    var result: Row = undefined;
    inline for (fields, 0..) |field, i| {
        @field(result, field.name) = values[i];
    }
    return result;
}

// Sourced from the exact specs and cross-checked against the EIP text;
// zig fmt: off
const table = [_]Row{
    //                              BALANCE      SLOAD        SSTORE          tx      calldata  access list  initcode       CALL SELFDESTRUCT
    // revision                     static cold  static cold  set     refund  base    nz zero   addr  key    word max       base refund
    row(.{ .frontier,                  20, null,     50, null,  20_000, 15_000, 21_000, 68, 4,    2_400, 1_900, 0, unbounded, 40, 24_000 }),
    row(.{ .frontier_thawing,          20, null,     50, null,  20_000, 15_000, 21_000, 68, 4,    2_400, 1_900, 0, unbounded, 40, 24_000 }),
    row(.{ .homestead,                 20, null,     50, null,  20_000, 15_000, 21_000, 68, 4,    2_400, 1_900, 0, unbounded, 40, 24_000 }),
    row(.{ .dao_fork,                  20, null,     50, null,  20_000, 15_000, 21_000, 68, 4,    2_400, 1_900, 0, unbounded, 40, 24_000 }),
    // EIP-150 reprices account and storage access, and CALL base 40 → 700.
    row(.{ .tangerine_whistle,         400, null,    200, null,  20_000, 15_000, 21_000, 68, 4,    2_400, 1_900, 0, unbounded, 700, 24_000 }),
    row(.{ .spurious_dragon,           400, null,    200, null,  20_000, 15_000, 21_000, 68, 4,    2_400, 1_900, 0, unbounded, 700, 24_000 }),
    row(.{ .byzantium,                 400, null,    200, null,  20_000, 15_000, 21_000, 68, 4,    2_400, 1_900, 0, unbounded, 700, 24_000 }),
    row(.{ .constantinople,            400, null,    200, null,  20_000, 15_000, 21_000, 68, 4,    2_400, 1_900, 0, unbounded, 700, 24_000 }),
    row(.{ .petersburg,                400, null,    200, null,  20_000, 15_000, 21_000, 68, 4,    2_400, 1_900, 0, unbounded, 700, 24_000 }),
    // EIP-1884 reprices BALANCE and SLOAD; EIP-2028 drops nonzero calldata 68 → 16.
    row(.{ .istanbul,                  700, null,    800, null,  20_000, 15_000, 21_000, 16, 4,    2_400, 1_900, 0, unbounded, 700, 24_000 }),
    row(.{ .muir_glacier,              700, null,    800, null,  20_000, 15_000, 21_000, 16, 4,    2_400, 1_900, 0, unbounded, 700, 24_000 }),
    // EIP-2929 splits every access into warm static gas plus a cold surcharge.
    row(.{ .berlin,                    100, 2_500,   100, 2_000, 20_000, 15_000, 21_000, 16, 4,    2_400, 1_900, 0, unbounded, 100, 24_000 }),
    // EIP-3529 cuts the clear refund and removes the SELFDESTRUCT refund.
    row(.{ .london,                    100, 2_500,   100, 2_000, 20_000,  4_800, 21_000, 16, 4,    2_400, 1_900, 0, unbounded, 100, 0 }),
    row(.{ .arrow_glacier,             100, 2_500,   100, 2_000, 20_000,  4_800, 21_000, 16, 4,    2_400, 1_900, 0, unbounded, 100, 0 }),
    row(.{ .gray_glacier,              100, 2_500,   100, 2_000, 20_000,  4_800, 21_000, 16, 4,    2_400, 1_900, 0, unbounded, 100, 0 }),
    row(.{ .merge,                     100, 2_500,   100, 2_000, 20_000,  4_800, 21_000, 16, 4,    2_400, 1_900, 0, unbounded, 100, 0 }),
    // EIP-3860 bounds initcode and prices it per word.
    row(.{ .shanghai,                  100, 2_500,   100, 2_000, 20_000,  4_800, 21_000, 16, 4,    2_400, 1_900, 2, 49_152,   100, 0 }),
    row(.{ .cancun,                    100, 2_500,   100, 2_000, 20_000,  4_800, 21_000, 16, 4,    2_400, 1_900, 2, 49_152,   100, 0 }),
    row(.{ .prague,                    100, 2_500,   100, 2_000, 20_000,  4_800, 21_000, 16, 4,    2_400, 1_900, 2, 49_152,   100, 0 }),
    row(.{ .osaka,                     100, 2_500,   100, 2_000, 20_000,  4_800, 21_000, 16, 4,    2_400, 1_900, 2, 49_152,   100, 0 }),
    // EIP-8037/8038: writes leave the regular schedule for state gas, and the
    // intrinsic base becomes TX_BASE_COST + COLD_ACCOUNT_ACCESS.
    row(.{ .amsterdam,                 100, 2_900,   100, 2_900, 10_000, 12_480, 15_000, 16, 4,    3_000, 3_000, 2, 131_072,  100, 0 }),
};
// zig fmt: on

fn actual(comptime revision: Revision) Row {
    const spec = comptime evmz.eth.specAt(revision);
    const nonzero = [_]u8{1};
    const zero = [_]u8{0};
    return .{
        .revision = revision,
        .balance_static_gas = spec.instruction.entry(@intFromEnum(Opcode.BALANCE)).info.static_gas,
        .cold_account_surcharge = spec.call.cold_account_access_gas,
        .sload_static_gas = spec.instruction.entry(@intFromEnum(Opcode.SLOAD)).info.static_gas,
        .cold_sload_surcharge = spec.storage.sload_cold_access_gas,
        .sstore_set_cost = spec.storage.sstoreGas(.added).cost,
        .sstore_clear_refund = spec.storage.sstoreGas(.deleted).refund,
        .tx_intrinsic_base = spec.transaction.intrinsicBaseGas(.{}),
        .calldata_nonzero_byte = spec.transaction.calldataGas(&nonzero),
        .calldata_zero_byte = spec.transaction.calldataGas(&zero),
        .access_list_address = spec.transaction.access_list_address_gas,
        .access_list_storage_key = spec.transaction.storage_key_gas,
        .initcode_word_gas = spec.transaction.initcode_word_gas,
        .max_initcode_size = spec.transaction.max_initcode_size,
        .call_base_gas = spec.call.base_gas,
        .selfdestruct_refund = spec.self_destruct.refund_gas,
    };
}

test "every revision charges its pinned gas parameters" {
    comptime std.debug.assert(table.len == std.enums.values(Revision).len);
    inline for (table) |expected| {
        const got = actual(expected.revision);
        inline for (std.meta.fields(Row)[1..]) |field| {
            std.testing.expectEqual(@field(expected, field.name), @field(got, field.name)) catch |err| {
                std.debug.print("{s}: field '{s}' diverged\n", .{ @tagName(expected.revision), field.name });
                return err;
            };
        }
    }
}

test "the table covers every revision exactly once, in fork order" {
    inline for (table, std.enums.values(Revision)) |expected, revision| {
        try std.testing.expectEqual(revision, expected.revision);
    }
}
