const std = @import("std");

const ExactSpec = @import("../spec.zig").Spec;
const uint256 = @import("../uint256.zig");

pub const BlobSchedule = struct {
    target: u64,
    max: u64,
    max_per_transaction: u64,
    gas_per_blob: u64,
    min_base_fee: u256,
    execution_base_cost: u64,
    base_fee_update_fraction: u256,
    reserve_price_active: bool,
    /// Accepted versioned-hash version byte (EIP-4844 KZG uses 0x01).
    hash_version: u8,
};

pub const ExcessBlobGasInput = struct {
    parent_excess_blob_gas: u256,
    parent_blob_gas_used: u256,
    parent_base_fee_per_gas: u256,
};

pub fn Runtime(comptime spec: ExactSpec) type {
    return struct {
        const Self = @This();
        const transaction = spec.transaction;

        pub const specification = spec;

        pub fn blobSchedule() ?BlobSchedule {
            return transaction.blob_schedule;
        }

        pub fn blobBaseFee(excess_blob_gas: u256) ?u256 {
            const schedule = Self.blobSchedule() orelse return 0;
            return blobBaseFeeForSchedule(schedule, excess_blob_gas);
        }

        pub fn calcExcessBlobGas(input: ExcessBlobGasInput) ?u256 {
            const schedule = Self.blobSchedule() orelse return 0;
            return calcExcessBlobGasForSchedule(schedule, input);
        }

        pub fn maxBlobCount() usize {
            const schedule = Self.blobSchedule() orelse return 0;
            return std.math.cast(usize, schedule.max) orelse std.math.maxInt(usize);
        }

        pub fn maxBlobCountPerTransaction() usize {
            const schedule = Self.blobSchedule() orelse return 0;
            return std.math.cast(usize, schedule.max_per_transaction) orelse std.math.maxInt(usize);
        }
    };
}

fn runtime(comptime spec: ExactSpec) type {
    return Runtime(spec);
}

pub fn blobBaseFeeForSchedule(schedule: BlobSchedule, excess_blob_gas: u256) ?u256 {
    return fakeExponential(schedule.min_base_fee, excess_blob_gas, schedule.base_fee_update_fraction);
}

pub fn blobGasForSchedule(schedule: BlobSchedule, blob_count: usize) ?u256 {
    const count: u256 = @intCast(blob_count);
    return uint256.checkedMul(count, @as(u256, schedule.gas_per_blob));
}

pub fn calcExcessBlobGasForSchedule(schedule: BlobSchedule, input: ExcessBlobGasInput) ?u256 {
    if (schedule.max == 0 or schedule.max < schedule.target) return null;

    const per_blob_gas_u256: u256 = @intCast(schedule.gas_per_blob);
    const target_blob_gas = uint256.checkedMul(per_blob_gas_u256, @as(u256, schedule.target)) orelse return null;
    const total_blob_gas = uint256.checkedAdd(input.parent_excess_blob_gas, input.parent_blob_gas_used) orelse return null;
    if (total_blob_gas < target_blob_gas) return 0;

    if (schedule.reserve_price_active) {
        const parent_blob_base_fee = blobBaseFeeForSchedule(schedule, input.parent_excess_blob_gas) orelse return null;
        const execution_reserve_price = uint256.checkedMul(@as(u256, schedule.execution_base_cost), input.parent_base_fee_per_gas) orelse return null;
        const blob_price = uint256.checkedMul(per_blob_gas_u256, parent_blob_base_fee) orelse return null;
        if (execution_reserve_price > blob_price) {
            const headroom = schedule.max - schedule.target;
            const scaled_used = uint256.checkedMul(input.parent_blob_gas_used, @as(u256, headroom)) orelse return null;
            const adjustment = @divFloor(scaled_used, @as(u256, schedule.max));
            return uint256.checkedAdd(input.parent_excess_blob_gas, adjustment);
        }
    }

    return total_blob_gas - target_blob_gas;
}

pub fn fakeExponential(factor: u256, numerator: u256, denominator: u256) ?u256 {
    var i: u256 = 1;
    var output: u256 = 0;
    var numerator_accum = uint256.checkedMul(factor, denominator) orelse return null;
    while (numerator_accum > 0) : (i += 1) {
        output = uint256.checkedAdd(output, numerator_accum) orelse return null;
        const next_numerator = uint256.checkedMul(numerator_accum, numerator) orelse return null;
        const next_denominator = uint256.checkedMul(denominator, i) orelse return null;
        numerator_accum = @divFloor(next_numerator, next_denominator);
    }
    return @divFloor(output, denominator);
}

pub fn blobVersion(hash: u256) u8 {
    return @intCast(hash >> 248);
}

test "transaction blob fee helpers" {
    const eth = @import("../eth.zig");
    const Shanghai = runtime(eth.shanghai);
    const Cancun = runtime(eth.cancun);
    const Prague = runtime(eth.prague);
    const Osaka = runtime(eth.osaka);
    const Amsterdam = runtime(eth.amsterdam);

    try std.testing.expectEqual(@as(u256, 1), blobBaseFeeForSchedule(eth.cancun.transaction.blob_schedule.?, 0x0e0000));
    try std.testing.expectEqual(@as(?BlobSchedule, null), Shanghai.blobSchedule());
    try std.testing.expectEqual(@as(u64, 6), Cancun.blobSchedule().?.max);
    try std.testing.expectEqual(eth.transaction.cancun_blob_base_fee_update_fraction, Cancun.blobSchedule().?.base_fee_update_fraction);
    try std.testing.expectEqual(@as(u64, 9), Osaka.blobSchedule().?.max);
    try std.testing.expectEqual(@as(usize, 6), Osaka.maxBlobCountPerTransaction());
    try std.testing.expectEqual(eth.transaction.prague_blob_base_fee_update_fraction, Osaka.blobSchedule().?.base_fee_update_fraction);
    try std.testing.expectEqual(@as(u64, 14), Amsterdam.blobSchedule().?.target);
    try std.testing.expectEqual(@as(u64, 21), Amsterdam.blobSchedule().?.max);
    try std.testing.expectEqual(eth.transaction.amsterdam_blob_base_fee_update_fraction, Amsterdam.blobSchedule().?.base_fee_update_fraction);
    try std.testing.expectEqual(@as(u256, 19), Cancun.blobBaseFee(10_000_000));
    try std.testing.expectEqual(@as(u256, 7), Osaka.blobBaseFee(10_000_000));
    try std.testing.expectEqual(@as(u256, 786_432), Prague.calcExcessBlobGas(.{
        .parent_excess_blob_gas = 786_432,
        .parent_blob_gas_used = 786_432,
        .parent_base_fee_per_gas = 1_000_000,
    }));
    try std.testing.expectEqual(@as(u256, 1_048_576), Osaka.calcExcessBlobGas(.{
        .parent_excess_blob_gas = 786_432,
        .parent_blob_gas_used = 786_432,
        .parent_base_fee_per_gas = 1_000_000,
    }));
}

test "transaction blob helpers accept extended exact specs" {
    const eth = @import("../eth.zig");
    const Cancun = eth.cancun.extend(.{ .transaction = .{ .blob_schedule = .{ .replace = .{
        .target = 2,
        .max = 4,
        .max_per_transaction = 4,
        .gas_per_blob = 131_072 * 2,
        .min_base_fee = 1,
        .execution_base_cost = 8_192,
        .base_fee_update_fraction = 5_007_716,
        .reserve_price_active = false,
        .hash_version = 0x01,
    } } } });
    const Osaka = eth.osaka.extend(.{ .transaction = .{ .blob_schedule = .{ .replace = .{
        .target = 2,
        .max = 4,
        .max_per_transaction = 2,
        .gas_per_blob = 131_072 * 2,
        .min_base_fee = 1,
        .execution_base_cost = 8_192,
        .base_fee_update_fraction = 5_007_716,
        .reserve_price_active = true,
        .hash_version = 0x01,
    } } } });
    const input = ExcessBlobGasInput{
        .parent_excess_blob_gas = 262_144,
        .parent_blob_gas_used = 524_288,
        .parent_base_fee_per_gas = 1_000_000,
    };
    const CancunBlob = runtime(Cancun);
    const OsakaBlob = runtime(Osaka);
    const schedule = Osaka.transaction.blob_schedule.?;

    try std.testing.expectEqual(@as(u64, 4), CancunBlob.blobSchedule().?.max);
    try std.testing.expectEqual(@as(usize, 4), CancunBlob.maxBlobCount());
    try std.testing.expectEqual(@as(usize, 2), OsakaBlob.maxBlobCountPerTransaction());
    try std.testing.expectEqual(blobBaseFeeForSchedule(schedule, 10_000_000), OsakaBlob.blobBaseFee(10_000_000));
    try std.testing.expectEqual(@as(u256, 262_144), CancunBlob.calcExcessBlobGas(input));
    try std.testing.expectEqual(calcExcessBlobGasForSchedule(schedule, input), OsakaBlob.calcExcessBlobGas(input));
}
