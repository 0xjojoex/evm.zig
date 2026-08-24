const std = @import("std");

const uint256 = @import("../uint256.zig");

/// EIP-7892 BPO modify only blob-related parameters for targeting hardfork
pub const BlobParams = struct {
    target: u64,
    max: u64,
    base_fee_update_fraction: u256,
};

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

    pub fn withParams(self: BlobSchedule, params: BlobParams) BlobSchedule {
        var result = self;
        result.target = params.target;
        result.max = params.max;
        result.base_fee_update_fraction = params.base_fee_update_fraction;
        return result;
    }

    pub fn blobGasForSchedule(self: BlobSchedule, blob_count: usize) ?u256 {
        const count: u256 = @intCast(blob_count);
        return uint256.checkedMul(count, @as(u256, self.gas_per_blob));
    }

    pub fn calcExcessBlobGasForSchedule(self: BlobSchedule, input: ExcessBlobGasInput) ?u256 {
        if (self.max == 0 or self.max < self.target) return null;

        const per_blob_gas_u256: u256 = @intCast(self.gas_per_blob);
        const target_blob_gas = uint256.checkedMul(per_blob_gas_u256, @as(u256, self.target)) orelse return null;
        const total_blob_gas = uint256.checkedAdd(input.parent_excess_blob_gas, input.parent_blob_gas_used) orelse return null;
        if (total_blob_gas < target_blob_gas) return 0;

        if (self.reserve_price_active) {
            const parent_blob_base_fee = self.blobBaseFeeForSchedule(input.parent_excess_blob_gas) orelse return null;
            const execution_reserve_price = uint256.checkedMul(@as(u256, self.execution_base_cost), input.parent_base_fee_per_gas) orelse return null;
            const blob_price = uint256.checkedMul(per_blob_gas_u256, parent_blob_base_fee) orelse return null;
            if (execution_reserve_price > blob_price) {
                const headroom = self.max - self.target;
                const scaled_used = uint256.checkedMul(input.parent_blob_gas_used, @as(u256, headroom)) orelse return null;
                const adjustment = @divFloor(scaled_used, @as(u256, self.max));
                return uint256.checkedAdd(input.parent_excess_blob_gas, adjustment);
            }
        }

        return total_blob_gas - target_blob_gas;
    }

    pub fn blobBaseFeeForSchedule(self: BlobSchedule, excess_blob_gas: u256) ?u256 {
        return fakeExponential(self.min_base_fee, excess_blob_gas, self.base_fee_update_fraction);
    }
};

pub const ExcessBlobGasInput = struct {
    parent_excess_blob_gas: u256,
    parent_blob_gas_used: u256,
    parent_base_fee_per_gas: u256,
};

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
    const cancun = eth.cancun.transaction.blob_schedule.?;
    const prague = eth.prague.transaction.blob_schedule.?;
    const osaka = eth.osaka.transaction.blob_schedule.?;
    const amsterdam = eth.amsterdam.transaction.blob_schedule.?;

    try std.testing.expectEqual(@as(u256, 1), cancun.blobBaseFeeForSchedule(0x0e0000));
    try std.testing.expectEqual(@as(?BlobSchedule, null), eth.shanghai.transaction.blob_schedule);
    try std.testing.expectEqual(@as(u64, 6), cancun.max);
    try std.testing.expectEqual(eth.transaction.cancun_blob_base_fee_update_fraction, cancun.base_fee_update_fraction);
    try std.testing.expectEqual(@as(u64, 9), osaka.max);
    try std.testing.expectEqual(@as(u64, 6), osaka.max_per_transaction);
    try std.testing.expectEqual(eth.transaction.prague_blob_base_fee_update_fraction, osaka.base_fee_update_fraction);
    try std.testing.expectEqual(@as(u64, 14), amsterdam.target);
    try std.testing.expectEqual(@as(u64, 21), amsterdam.max);
    try std.testing.expectEqual(eth.transaction.amsterdam_blob_base_fee_update_fraction, amsterdam.base_fee_update_fraction);
    try std.testing.expectEqual(@as(u256, 19), cancun.blobBaseFeeForSchedule(10_000_000));
    try std.testing.expectEqual(@as(u256, 7), osaka.blobBaseFeeForSchedule(10_000_000));
    try std.testing.expectEqual(@as(u256, 786_432), prague.calcExcessBlobGasForSchedule(.{
        .parent_excess_blob_gas = 786_432,
        .parent_blob_gas_used = 786_432,
        .parent_base_fee_per_gas = 1_000_000,
    }));
    try std.testing.expectEqual(@as(u256, 1_048_576), osaka.calcExcessBlobGasForSchedule(.{
        .parent_excess_blob_gas = 786_432,
        .parent_blob_gas_used = 786_432,
        .parent_base_fee_per_gas = 1_000_000,
    }));
}

test "runtime blob params only replace EIP-7892 schedule fields" {
    const schedule = @import("../eth.zig").osaka.transaction.blob_schedule.?;
    const resolved = schedule.withParams(.{
        .target = 10,
        .max = 15,
        .base_fee_update_fraction = 8_346_193,
    });

    try std.testing.expectEqual(@as(u64, 10), resolved.target);
    try std.testing.expectEqual(@as(u64, 15), resolved.max);
    try std.testing.expectEqual(@as(u256, 8_346_193), resolved.base_fee_update_fraction);
    try std.testing.expectEqual(schedule.max_per_transaction, resolved.max_per_transaction);
    try std.testing.expectEqual(schedule.gas_per_blob, resolved.gas_per_blob);
    try std.testing.expectEqual(schedule.hash_version, resolved.hash_version);
}

test "fake exponential rejects a zero denominator" {
    try std.testing.expectEqual(@as(?u256, null), fakeExponential(1, 1, 0));
}
