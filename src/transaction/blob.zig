const std = @import("std");

const uint256 = @import("../uint256.zig");

pub const BlobParams = struct {
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

pub fn blobBaseFeeForParams(params: BlobParams, excess_blob_gas: u256) ?u256 {
    return fakeExponential(params.min_base_fee, excess_blob_gas, params.base_fee_update_fraction);
}

pub fn blobGasForParams(params: BlobParams, blob_count: usize) ?u256 {
    const count: u256 = @intCast(blob_count);
    return uint256.checkedMul(count, @as(u256, params.gas_per_blob));
}

pub fn calcExcessBlobGasForParams(params: BlobParams, input: ExcessBlobGasInput) ?u256 {
    if (params.max == 0 or params.max < params.target) return null;

    const per_blob_gas_u256: u256 = @intCast(params.gas_per_blob);
    const target_blob_gas = uint256.checkedMul(per_blob_gas_u256, @as(u256, params.target)) orelse return null;
    const total_blob_gas = uint256.checkedAdd(input.parent_excess_blob_gas, input.parent_blob_gas_used) orelse return null;
    if (total_blob_gas < target_blob_gas) return 0;

    if (params.reserve_price_active) {
        const parent_blob_base_fee = blobBaseFeeForParams(params, input.parent_excess_blob_gas) orelse return null;
        const execution_reserve_price = uint256.checkedMul(@as(u256, params.execution_base_cost), input.parent_base_fee_per_gas) orelse return null;
        const blob_price = uint256.checkedMul(per_blob_gas_u256, parent_blob_base_fee) orelse return null;
        if (execution_reserve_price > blob_price) {
            const headroom = params.max - params.target;
            const scaled_used = uint256.checkedMul(input.parent_blob_gas_used, @as(u256, headroom)) orelse return null;
            const adjustment = @divFloor(scaled_used, @as(u256, params.max));
            return uint256.checkedAdd(input.parent_excess_blob_gas, adjustment);
        }
    }

    return total_blob_gas - target_blob_gas;
}

pub fn fakeExponential(factor: u256, numerator: u256, denominator: u256) ?u256 {
    if (denominator == 0) return null;
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
    const cancun = eth.cancun.transaction.blob_params.?;
    const prague = eth.prague.transaction.blob_params.?;
    const osaka = eth.osaka.transaction.blob_params.?;
    const amsterdam = eth.amsterdam.transaction.blob_params.?;

    try std.testing.expectEqual(@as(u256, 1), blobBaseFeeForParams(cancun, 0x0e0000));
    try std.testing.expectEqual(@as(?BlobParams, null), eth.shanghai.transaction.blob_params);
    try std.testing.expectEqual(@as(u64, 6), cancun.max);
    try std.testing.expectEqual(eth.transaction.cancun_blob_base_fee_update_fraction, cancun.base_fee_update_fraction);
    try std.testing.expectEqual(@as(u64, 9), osaka.max);
    try std.testing.expectEqual(@as(u64, 6), osaka.max_per_transaction);
    try std.testing.expectEqual(eth.transaction.prague_blob_base_fee_update_fraction, osaka.base_fee_update_fraction);
    try std.testing.expectEqual(@as(u64, 14), amsterdam.target);
    try std.testing.expectEqual(@as(u64, 21), amsterdam.max);
    try std.testing.expectEqual(eth.transaction.amsterdam_blob_base_fee_update_fraction, amsterdam.base_fee_update_fraction);
    try std.testing.expectEqual(@as(u256, 19), blobBaseFeeForParams(cancun, 10_000_000));
    try std.testing.expectEqual(@as(u256, 7), blobBaseFeeForParams(osaka, 10_000_000));
    try std.testing.expectEqual(@as(u256, 786_432), calcExcessBlobGasForParams(prague, .{
        .parent_excess_blob_gas = 786_432,
        .parent_blob_gas_used = 786_432,
        .parent_base_fee_per_gas = 1_000_000,
    }));
    try std.testing.expectEqual(@as(u256, 1_048_576), calcExcessBlobGasForParams(osaka, .{
        .parent_excess_blob_gas = 786_432,
        .parent_blob_gas_used = 786_432,
        .parent_base_fee_per_gas = 1_000_000,
    }));
}

test "fake exponential rejects a zero denominator" {
    try std.testing.expectEqual(@as(?u256, null), fakeExponential(1, 1, 0));
}
