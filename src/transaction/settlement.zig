const std = @import("std");

const address = @import("../address.zig");
const Address = address.Address;
const Spec = @import("../spec.zig").Spec;

pub const FeeInput = struct {
    gas_price: u256,
    base_fee: u256 = 0,
    max_fee_per_gas: ?u256 = null,
    max_priority_fee_per_gas: ?u256 = null,
};

pub const Settlement = struct {
    spec: Spec,
    gas_limit: u64,
    intrinsic_gas: u64,
    floor_gas: u64,
    gas_price: u256,
    priority_fee: u256,
    coinbase: Address,
};

pub const ExecutionGasResult = struct {
    gas_left: i64,
    gas_refund: i64,
};

pub const SettlementCosts = struct {
    gas_used: u64,
    refunded_gas: u64,
    sender_refund: u256,
    coinbase_payment: u256,
};

pub fn effectivePriorityFee(spec: Spec, input: FeeInput) u256 {
    if (!spec.isImpl(.london)) return input.gas_price;
    if (input.max_fee_per_gas) |max_fee| {
        const max_priority_fee = input.max_priority_fee_per_gas orelse 0;
        if (max_fee <= input.base_fee) return 0;
        return @min(max_priority_fee, max_fee - input.base_fee);
    }
    if (input.gas_price <= input.base_fee) return 0;
    return input.gas_price - input.base_fee;
}

pub fn settlementCosts(settlement: Settlement, result: ExecutionGasResult) !SettlementCosts {
    const execution_gas = settlement.gas_limit - @min(settlement.gas_limit, settlement.intrinsic_gas);
    const gas_left = if (result.gas_left > 0)
        @min(std.math.cast(u64, result.gas_left) orelse std.math.maxInt(u64), execution_gas)
    else
        0;
    const pre_refund_gas_used = settlement.gas_limit - gas_left;
    const refund_cap_divisor: u64 = if (settlement.spec.isImpl(.london)) 5 else 2;
    const refund_cap = pre_refund_gas_used / refund_cap_divisor;
    const raw_refund = if (result.gas_refund > 0)
        std.math.cast(u64, result.gas_refund) orelse std.math.maxInt(u64)
    else
        0;
    const refund_gas = @min(raw_refund, refund_cap);
    const refunded_gas = gas_left + refund_gas;
    const gas_used_after_refund = settlement.gas_limit - @min(settlement.gas_limit, refunded_gas);
    const gas_used = @max(gas_used_after_refund, settlement.floor_gas);
    const sender_refunded_gas = settlement.gas_limit - @min(settlement.gas_limit, gas_used);

    return .{
        .gas_used = gas_used,
        .refunded_gas = sender_refunded_gas,
        .sender_refund = try checkedGasCost(sender_refunded_gas, settlement.gas_price),
        .coinbase_payment = try checkedGasCost(gas_used, settlement.priority_fee),
    };
}

pub fn checkedGasCost(gas: u64, price: u256) !u256 {
    return std.math.mul(u256, @as(u256, gas), price) catch error.Overflow;
}

test "effective priority fee follows legacy and dynamic fee rules" {
    try std.testing.expectEqual(@as(u256, 7), effectivePriorityFee(.berlin, .{
        .gas_price = 7,
    }));
    try std.testing.expectEqual(@as(u256, 0), effectivePriorityFee(.london, .{
        .gas_price = 9,
        .base_fee = 10,
    }));
    try std.testing.expectEqual(@as(u256, 2), effectivePriorityFee(.london, .{
        .gas_price = 12,
        .base_fee = 10,
    }));
    try std.testing.expectEqual(@as(u256, 3), effectivePriorityFee(.london, .{
        .gas_price = 0,
        .base_fee = 10,
        .max_fee_per_gas = 20,
        .max_priority_fee_per_gas = 3,
    }));
    try std.testing.expectEqual(@as(u256, 0), effectivePriorityFee(.london, .{
        .gas_price = 0,
        .base_fee = 20,
        .max_fee_per_gas = 20,
        .max_priority_fee_per_gas = 3,
    }));
}

test "settlement costs cap gas refund by fork" {
    const coinbase = address.addr(0xbeef);
    const settlement = Settlement{
        .spec = .london,
        .gas_limit = 100,
        .intrinsic_gas = 20,
        .floor_gas = 0,
        .gas_price = 5,
        .priority_fee = 2,
        .coinbase = coinbase,
    };
    const costs = try settlementCosts(settlement, .{
        .gas_left = 40,
        .gas_refund = 100,
    });

    try std.testing.expectEqual(@as(u64, 48), costs.gas_used);
    try std.testing.expectEqual(@as(u64, 52), costs.refunded_gas);
    try std.testing.expectEqual(@as(u256, 260), costs.sender_refund);
    try std.testing.expectEqual(@as(u256, 96), costs.coinbase_payment);
}

test "settlement costs enforce Prague calldata floor after refunds" {
    // EIP-7623 charges the calldata floor after execution gas refunds.
    const coinbase = address.addr(0xbeef);
    const settlement = Settlement{
        .spec = .prague,
        .gas_limit = 21_100,
        .intrinsic_gas = 21_016,
        .floor_gas = 21_040,
        .gas_price = 7,
        .priority_fee = 0,
        .coinbase = coinbase,
    };
    const costs = try settlementCosts(settlement, .{
        .gas_left = 84,
        .gas_refund = 0,
    });

    try std.testing.expectEqual(@as(u64, 21_040), costs.gas_used);
    try std.testing.expectEqual(@as(u64, 60), costs.refunded_gas);
    try std.testing.expectEqual(@as(u256, 420), costs.sender_refund);
    try std.testing.expectEqual(@as(u256, 0), costs.coinbase_payment);
}
