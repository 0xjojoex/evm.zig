const std = @import("std");

const Spec = @import("../spec.zig").Spec;
const uint256 = @import("../uint256.zig");

pub const blob_gas_per_blob: u64 = 131_072;
pub const min_blob_base_fee: u256 = 1;
pub const blob_base_cost: u64 = 8_192;
pub const cancun_blob_base_fee_update_fraction: u256 = 3_338_477;
pub const prague_blob_base_fee_update_fraction: u256 = 5_007_716;
pub const amsterdam_blob_base_fee_update_fraction: u256 = 11_684_671;
pub const blob_base_fee_update_fraction: u256 = cancun_blob_base_fee_update_fraction;

pub const BlobSchedule = struct {
    target: u64,
    max: u64,
    base_fee_update_fraction: u256,
};

pub const ExcessBlobGasInput = struct {
    parent_excess_blob_gas: u256,
    parent_blob_gas_used: u256,
    parent_base_fee_per_gas: u256,
};

pub fn blobSchedule(spec: Spec) ?BlobSchedule {
    if (!spec.isImpl(.cancun)) return null;
    if (spec.isImpl(.amsterdam)) {
        return .{
            .target = 14,
            .max = 21,
            .base_fee_update_fraction = amsterdam_blob_base_fee_update_fraction,
        };
    }
    if (spec.isImpl(.prague)) {
        return .{
            .target = 6,
            .max = 9,
            .base_fee_update_fraction = prague_blob_base_fee_update_fraction,
        };
    }
    return .{
        .target = 3,
        .max = 6,
        .base_fee_update_fraction = cancun_blob_base_fee_update_fraction,
    };
}

pub fn blobBaseFee(excess_blob_gas: u256) ?u256 {
    return blobBaseFeeForSchedule(.{
        .target = 3,
        .max = 6,
        .base_fee_update_fraction = cancun_blob_base_fee_update_fraction,
    }, excess_blob_gas);
}

pub fn blobBaseFeeForSpec(spec: Spec, excess_blob_gas: u256) ?u256 {
    const schedule = blobSchedule(spec) orelse return 0;
    return blobBaseFeeForSchedule(schedule, excess_blob_gas);
}

pub fn blobBaseFeeForSchedule(schedule: BlobSchedule, excess_blob_gas: u256) ?u256 {
    return fakeExponential(min_blob_base_fee, excess_blob_gas, schedule.base_fee_update_fraction);
}

pub fn calcExcessBlobGas(spec: Spec, input: ExcessBlobGasInput) ?u256 {
    const schedule = blobSchedule(spec) orelse return 0;
    return calcExcessBlobGasForSchedule(schedule, spec.isImpl(.osaka), input);
}

pub fn calcExcessBlobGasForSchedule(schedule: BlobSchedule, apply_reserve_price: bool, input: ExcessBlobGasInput) ?u256 {
    if (schedule.max == 0 or schedule.max < schedule.target) return null;

    const target_blob_gas = uint256.checkedMul(@as(u256, blob_gas_per_blob), @as(u256, schedule.target)) orelse return null;
    const total_blob_gas = uint256.checkedAdd(input.parent_excess_blob_gas, input.parent_blob_gas_used) orelse return null;
    if (total_blob_gas < target_blob_gas) return 0;

    if (apply_reserve_price) {
        const parent_blob_base_fee = blobBaseFeeForSchedule(schedule, input.parent_excess_blob_gas) orelse return null;
        const execution_reserve_price = uint256.checkedMul(@as(u256, blob_base_cost), input.parent_base_fee_per_gas) orelse return null;
        const blob_price = uint256.checkedMul(@as(u256, blob_gas_per_blob), parent_blob_base_fee) orelse return null;
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

pub fn maxBlobCount(spec: Spec) usize {
    const schedule = blobSchedule(spec) orelse return 0;
    return std.math.cast(usize, schedule.max) orelse std.math.maxInt(usize);
}

pub fn maxBlobCountPerTransaction(spec: Spec) usize {
    if (spec.isImpl(.osaka)) return 6;
    return maxBlobCount(spec);
}

pub fn blobVersion(hash: u256) u8 {
    return @intCast(hash >> 248);
}

test "transaction blob fee helpers" {
    try std.testing.expectEqual(@as(u256, 1), blobBaseFee(0x0e0000));
    try std.testing.expectEqual(@as(?BlobSchedule, null), blobSchedule(.shanghai));
    try std.testing.expectEqual(@as(u64, 6), blobSchedule(.cancun).?.max);
    try std.testing.expectEqual(cancun_blob_base_fee_update_fraction, blobSchedule(.cancun).?.base_fee_update_fraction);
    try std.testing.expectEqual(@as(u64, 9), blobSchedule(.osaka).?.max);
    try std.testing.expectEqual(@as(usize, 6), maxBlobCountPerTransaction(.osaka));
    try std.testing.expectEqual(prague_blob_base_fee_update_fraction, blobSchedule(.osaka).?.base_fee_update_fraction);
    try std.testing.expectEqual(@as(u64, 14), blobSchedule(.amsterdam).?.target);
    try std.testing.expectEqual(@as(u64, 21), blobSchedule(.amsterdam).?.max);
    try std.testing.expectEqual(amsterdam_blob_base_fee_update_fraction, blobSchedule(.amsterdam).?.base_fee_update_fraction);
    try std.testing.expectEqual(@as(u256, 19), blobBaseFeeForSpec(.cancun, 10_000_000));
    try std.testing.expectEqual(@as(u256, 7), blobBaseFeeForSpec(.osaka, 10_000_000));
    try std.testing.expectEqual(@as(u256, 786_432), calcExcessBlobGas(.prague, .{
        .parent_excess_blob_gas = 786_432,
        .parent_blob_gas_used = 786_432,
        .parent_base_fee_per_gas = 1_000_000,
    }));
    try std.testing.expectEqual(@as(u256, 1_048_576), calcExcessBlobGas(.osaka, .{
        .parent_excess_blob_gas = 786_432,
        .parent_blob_gas_used = 786_432,
        .parent_base_fee_per_gas = 1_000_000,
    }));
}
