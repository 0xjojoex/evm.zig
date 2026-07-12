const std = @import("std");

const definition_support = @import("../protocol/support.zig");
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
};

pub const ExcessBlobGasInput = struct {
    parent_excess_blob_gas: u256,
    parent_blob_gas_used: u256,
    parent_base_fee_per_gas: u256,
};

pub fn For(comptime ProtocolType: type) type {
    return struct {
        const Self = @This();
        const transaction = ProtocolType.transaction;

        pub const Protocol = ProtocolType;

        pub fn blobSchedule(revision: Protocol.Revision) ?BlobSchedule {
            definition_support.assertRevisionSupported(Protocol, revision);
            return transaction.blobSchedule(revision);
        }

        pub fn blobBaseFeeForRevision(revision: Protocol.Revision, excess_blob_gas: u256) ?u256 {
            definition_support.assertRevisionSupported(Protocol, revision);
            const schedule = Self.blobSchedule(revision) orelse return 0;
            return blobBaseFeeForSchedule(schedule, excess_blob_gas);
        }

        pub fn calcExcessBlobGas(revision: Protocol.Revision, input: ExcessBlobGasInput) ?u256 {
            definition_support.assertRevisionSupported(Protocol, revision);
            const schedule = Self.blobSchedule(revision) orelse return 0;
            return calcExcessBlobGasForSchedule(schedule, input);
        }

        pub fn maxBlobCount(revision: Protocol.Revision) usize {
            definition_support.assertRevisionSupported(Protocol, revision);
            const schedule = Self.blobSchedule(revision) orelse return 0;
            return std.math.cast(usize, schedule.max) orelse std.math.maxInt(usize);
        }

        pub fn maxBlobCountPerTransaction(revision: Protocol.Revision) usize {
            definition_support.assertRevisionSupported(Protocol, revision);
            const schedule = Self.blobSchedule(revision) orelse return 0;
            return std.math.cast(usize, schedule.max_per_transaction) orelse std.math.maxInt(usize);
        }
    };
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
    const Ethereum = eth.Protocol;
    const EthBlob = For(Ethereum);

    try std.testing.expectEqual(@as(u256, 1), blobBaseFeeForSchedule(Ethereum.transaction.blobSchedule(.cancun).?, 0x0e0000));
    try std.testing.expectEqual(@as(?BlobSchedule, null), EthBlob.blobSchedule(.shanghai));
    try std.testing.expectEqual(@as(u64, 6), EthBlob.blobSchedule(.cancun).?.max);
    try std.testing.expectEqual(eth.transaction.cancun_blob_base_fee_update_fraction, EthBlob.blobSchedule(.cancun).?.base_fee_update_fraction);
    try std.testing.expectEqual(@as(u64, 9), EthBlob.blobSchedule(.osaka).?.max);
    try std.testing.expectEqual(@as(usize, 6), EthBlob.maxBlobCountPerTransaction(.osaka));
    try std.testing.expectEqual(eth.transaction.prague_blob_base_fee_update_fraction, EthBlob.blobSchedule(.osaka).?.base_fee_update_fraction);
    try std.testing.expectEqual(@as(u64, 14), EthBlob.blobSchedule(.amsterdam).?.target);
    try std.testing.expectEqual(@as(u64, 21), EthBlob.blobSchedule(.amsterdam).?.max);
    try std.testing.expectEqual(eth.transaction.amsterdam_blob_base_fee_update_fraction, EthBlob.blobSchedule(.amsterdam).?.base_fee_update_fraction);
    try std.testing.expectEqual(@as(u256, 19), EthBlob.blobBaseFeeForRevision(.cancun, 10_000_000));
    try std.testing.expectEqual(@as(u256, 7), EthBlob.blobBaseFeeForRevision(.osaka, 10_000_000));
    try std.testing.expectEqual(@as(u256, 786_432), EthBlob.calcExcessBlobGas(.prague, .{
        .parent_excess_blob_gas = 786_432,
        .parent_blob_gas_used = 786_432,
        .parent_base_fee_per_gas = 1_000_000,
    }));
    try std.testing.expectEqual(@as(u256, 1_048_576), EthBlob.calcExcessBlobGas(.osaka, .{
        .parent_excess_blob_gas = 786_432,
        .parent_blob_gas_used = 786_432,
        .parent_base_fee_per_gas = 1_000_000,
    }));
}

test "transaction blob helpers accept comptime protocol" {
    const CustomRevision = enum { cancun, osaka };
    const TestProtocol = struct {
        pub const Revision = CustomRevision;

        pub const transaction = struct {
            pub fn blobSchedule(revision: Revision) ?BlobSchedule {
                return .{
                    .target = 2,
                    .max = 4,
                    .max_per_transaction = if (revision == .osaka) 2 else 4,
                    .gas_per_blob = 131_072 * 2,
                    .min_base_fee = 1,
                    .execution_base_cost = 8_192,
                    .base_fee_update_fraction = 5_007_716,
                    .reserve_price_active = revision == .osaka,
                };
            }
        };
    };
    const input = ExcessBlobGasInput{
        .parent_excess_blob_gas = 262_144,
        .parent_blob_gas_used = 524_288,
        .parent_base_fee_per_gas = 1_000_000,
    };
    const Bound = For(TestProtocol);
    const schedule = TestProtocol.transaction.blobSchedule(.osaka).?;

    try std.testing.expectEqual(@as(u64, 4), Bound.blobSchedule(.cancun).?.max);
    try std.testing.expectEqual(@as(usize, 4), Bound.maxBlobCount(.cancun));
    try std.testing.expectEqual(@as(usize, 2), Bound.maxBlobCountPerTransaction(.osaka));
    try std.testing.expectEqual(blobBaseFeeForSchedule(schedule, 10_000_000), Bound.blobBaseFeeForRevision(.osaka, 10_000_000));
    try std.testing.expectEqual(@as(u256, 262_144), Bound.calcExcessBlobGas(.cancun, input));
    try std.testing.expectEqual(calcExcessBlobGasForSchedule(schedule, input), Bound.calcExcessBlobGas(.osaka, input));
}
