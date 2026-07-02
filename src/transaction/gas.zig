const std = @import("std");
const Transaction = @import("./Transaction.zig");
const Spec = @import("../spec.zig").Spec;

pub const authorization_intrinsic_gas: u64 = 25_000;
pub const authorization_existing_account_refund_gas: u64 = 12_500;
pub const access_list_address_gas: u64 = 2_400;
pub const access_list_storage_key_gas: u64 = 1_900;
pub const create_transaction_gas: u64 = 32_000;
pub const initcode_word_gas: u64 = 2;
pub const max_initcode_size: usize = 49_152;
pub const max_transaction_gas_limit: u64 = 16_777_216;

pub const AccessListCounts = Transaction.AccessListCounts;
pub const AccessListEntry = Transaction.AccessListEntry;

pub const IntrinsicGasOptions = struct {
    authorization_count: usize = 0,
    access_list_counts: AccessListCounts = .{},
    is_create: bool = false,
};

pub const GasPlan = struct {
    intrinsic_gas: u64,
    floor_gas: u64,
    minimum_gas: u64,
    execution_gas: ?u64,
};

pub fn intrinsicGas(spec: Spec, input: []const u8, authorization_count: usize, access_list_counts: AccessListCounts) ?u64 {
    return intrinsicGasForTransaction(spec, input, .{
        .authorization_count = authorization_count,
        .access_list_counts = access_list_counts,
    });
}

pub fn intrinsicGasForTransaction(spec: Spec, input: []const u8, options: IntrinsicGasOptions) ?u64 {
    var gas: u64 = 21_000;
    if (options.is_create and spec.isImpl(.homestead)) {
        gas = std.math.add(u64, gas, create_transaction_gas) catch return null;
    }
    const non_zero_byte_cost: u64 = if (spec.isImpl(.istanbul)) 16 else 68;
    for (input) |byte| {
        const byte_cost: u64 = if (byte == 0) 4 else non_zero_byte_cost;
        gas = std.math.add(u64, gas, byte_cost) catch return null;
    }
    const access_list_address_count = std.math.cast(u64, options.access_list_counts.addresses) orelse return null;
    const access_list_storage_key_count = std.math.cast(u64, options.access_list_counts.storage_keys) orelse return null;
    const access_list_address_cost = std.math.mul(u64, access_list_address_count, access_list_address_gas) catch return null;
    const access_list_storage_key_cost = std.math.mul(u64, access_list_storage_key_count, access_list_storage_key_gas) catch return null;
    gas = std.math.add(u64, gas, access_list_address_cost) catch return null;
    gas = std.math.add(u64, gas, access_list_storage_key_cost) catch return null;
    if (options.is_create and spec.isImpl(.shanghai)) {
        const words = std.math.cast(u64, wordCount(input.len)) orelse return null;
        const initcode_cost = std.math.mul(u64, words, initcode_word_gas) catch return null;
        gas = std.math.add(u64, gas, initcode_cost) catch return null;
    }
    if (spec.isImpl(.prague)) {
        const auth_count = std.math.cast(u64, options.authorization_count) orelse return null;
        const auth_cost = std.math.mul(u64, auth_count, authorization_intrinsic_gas) catch return null;
        gas = std.math.add(u64, gas, auth_cost) catch return null;
    }
    return gas;
}

pub fn accessListCounts(access_list: []const AccessListEntry) AccessListCounts {
    var result = AccessListCounts{};
    result.addresses = access_list.len;
    for (access_list) |entry| {
        result.storage_keys += entry.storage_keys.len;
    }
    return result;
}

pub fn gasPlan(spec: Spec, input: []const u8, gas_limit: u64, options: IntrinsicGasOptions) GasPlan {
    const intrinsic_gas = intrinsicGasForTransaction(spec, input, options) orelse std.math.maxInt(u64);
    const floor_gas = if (spec.isImpl(.prague)) floorGas(spec, input) orelse std.math.maxInt(u64) else 0;
    const minimum_gas = @max(intrinsic_gas, floor_gas);
    return .{
        .intrinsic_gas = intrinsic_gas,
        .floor_gas = floor_gas,
        .minimum_gas = minimum_gas,
        .execution_gas = if (gas_limit >= minimum_gas) gas_limit - intrinsic_gas else null,
    };
}

pub fn minimumGas(spec: Spec, input: []const u8, authorization_count: usize, access_list_counts: AccessListCounts) ?u64 {
    return minimumGasForTransaction(spec, input, .{
        .authorization_count = authorization_count,
        .access_list_counts = access_list_counts,
    });
}

pub fn minimumGasForTransaction(spec: Spec, input: []const u8, options: IntrinsicGasOptions) ?u64 {
    const intrinsic = intrinsicGasForTransaction(spec, input, options) orelse return null;
    if (!spec.isImpl(.prague)) return intrinsic;

    const floor = floorGas(spec, input) orelse return null;
    return @max(intrinsic, floor);
}

pub fn floorGas(spec: Spec, input: []const u8) ?u64 {
    if (!spec.isImpl(.prague)) return null;
    const tokens = calldataTokenCount(input) orelse return null;
    const floor_data_cost = std.math.mul(u64, tokens, 10) catch return null;
    return std.math.add(u64, 21_000, floor_data_cost) catch return null;
}

pub fn calldataTokenCount(input: []const u8) ?u64 {
    var tokens: u64 = 0;
    for (input) |byte| {
        const byte_tokens: u64 = if (byte == 0) 1 else 4;
        tokens = std.math.add(u64, tokens, byte_tokens) catch return null;
    }
    return tokens;
}

fn wordCount(len: usize) usize {
    return (len + 31) / 32;
}

test "transaction gas helpers" {
    try std.testing.expectEqual(@as(u64, 21_072), intrinsicGas(.byzantium, &.{ 0, 1 }, 0, .{}));
    try std.testing.expectEqual(@as(u64, 21_020), intrinsicGas(.istanbul, &.{ 0, 1 }, 0, .{}));
    try std.testing.expectEqual(@as(u64, 46_020), intrinsicGas(.prague, &.{ 0, 1 }, 1, .{}));
    try std.testing.expectEqual(@as(u64, 29_120), intrinsicGas(.berlin, &.{ 0, 1 }, 0, .{
        .addresses = 1,
        .storage_keys = 3,
    }));
    try std.testing.expectEqual(@as(u64, 5), calldataTokenCount(&.{ 0, 1 }));
    try std.testing.expectEqual(@as(u64, 21_020), minimumGas(.istanbul, &.{ 0, 1 }, 0, .{}));
    try std.testing.expectEqual(@as(u64, 21_050), minimumGas(.prague, &.{ 0, 1 }, 0, .{}));
    try std.testing.expectEqual(@as(u64, 46_020), minimumGas(.prague, &.{ 0, 1 }, 1, .{}));
    try std.testing.expectEqual(@as(u64, 21_008), intrinsicGasForTransaction(.frontier, &.{ 0, 0 }, .{ .is_create = true }));
    try std.testing.expectEqual(@as(u64, 53_008), intrinsicGasForTransaction(.homestead, &.{ 0, 0 }, .{ .is_create = true }));
    try std.testing.expectEqual(@as(u64, 53_010), intrinsicGasForTransaction(.shanghai, &.{ 0, 0 }, .{ .is_create = true }));
    const storage_keys = [_]u256{ 1, 2, 3 };
    try std.testing.expectEqual(AccessListCounts{
        .addresses = 2,
        .storage_keys = 3,
    }, accessListCounts(&.{
        .{ .address = @import("../address.zig").addr(0xaaaa), .storage_keys = storage_keys[0..2] },
        .{ .address = @import("../address.zig").addr(0xbbbb), .storage_keys = storage_keys[2..] },
    }));
}

test "transaction gas plan computes executable gas after intrinsic and floor costs" {
    const istanbul = gasPlan(.istanbul, &.{ 0, 1 }, 100_000, .{});
    try std.testing.expectEqual(@as(u64, 21_020), istanbul.intrinsic_gas);
    try std.testing.expectEqual(@as(u64, 0), istanbul.floor_gas);
    try std.testing.expectEqual(@as(u64, 21_020), istanbul.minimum_gas);
    try std.testing.expectEqual(@as(?u64, 78_980), istanbul.execution_gas);

    const prague_floor = gasPlan(.prague, &.{ 1, 1, 1, 1 }, 21_100, .{});
    try std.testing.expectEqual(@as(u64, 21_064), prague_floor.intrinsic_gas);
    try std.testing.expectEqual(@as(u64, 21_160), prague_floor.floor_gas);
    try std.testing.expectEqual(@as(u64, 21_160), prague_floor.minimum_gas);
    try std.testing.expectEqual(@as(?u64, null), prague_floor.execution_gas);

    const prague_authorization = gasPlan(.prague, &.{}, 100_000, .{ .authorization_count = 1 });
    try std.testing.expectEqual(@as(u64, 46_000), prague_authorization.intrinsic_gas);
    try std.testing.expectEqual(@as(u64, 21_000), prague_authorization.floor_gas);
    try std.testing.expectEqual(@as(u64, 46_000), prague_authorization.minimum_gas);
    try std.testing.expectEqual(@as(?u64, 54_000), prague_authorization.execution_gas);
}
