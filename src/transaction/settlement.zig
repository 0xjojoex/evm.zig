const std = @import("std");

const address = @import("../address.zig");
const Address = address.Address;
const ExactSpec = @import("../spec.zig").Spec;
const tx_blob = @import("blob.zig");
const tx_gas = @import("gas.zig");

pub const FeeInput = struct {
    gas_price: u256,
    base_fee: u256 = 0,
    max_fee_per_gas: ?u256 = null,
    max_priority_fee_per_gas: ?u256 = null,
};

/// Engine-owned Ethereum-style settlement plan used by exact VMs.
/// Representation-changing families keep distinct fee plans in their STF and
/// compose executor lifecycle/state primitives directly.
pub const DefaultPlan = struct {
    payer: ?Address = null,
    gas_limit: u64,
    intrinsic_gas: u64,
    floor_gas: u64,
    gas_price: u256,
    priority_fee: u256,
    fee_recipient: Address,
    upfront_debit: u256 = 0,
    minimum_balance: u256 = 0,
};

pub const DefaultFees = struct {
    gas_price: u256,
    priority_fee: u256,
    fee_recipient: Address,
    payer: ?Address = null,
    value: u256 = 0,
    blob_base_fee: u256 = 0,
    blob_count: usize = 0,
};

pub const ExecutionGasResult = struct {
    gas_left: i64,
    gas_refund: i64,
    gas_reservoir: i64,
    state_gas_spent: i64,

    pub const empty: ExecutionGasResult = std.mem.zeroes(@This());
};

/// Gas contribution used for block/session accounting.
///
/// `total` is the canonical value compared to the block gas limit and, for
/// Amsterdam state-gas accounting, is derived from cumulative dimensions as
/// `max(regular, state)`.
pub const BlockGas = struct {
    /// Canonical/header gas used by the block.
    total: u64 = 0,
    /// Regular EVM gas contribution.
    regular: u64 = 0,
    /// EIP-8037 state-growth gas contribution.
    state: u64 = 0,

    /// Build legacy one-dimensional block gas.
    pub fn legacy(used: u64) BlockGas {
        return .{
            .total = used,
            .regular = used,
        };
    }

    /// Build dimensional block gas and derive the canonical total.
    pub fn fromDimensions(regular: u64, state: u64) BlockGas {
        return .{
            .total = @max(regular, state),
            .regular = regular,
            .state = state,
        };
    }

    /// Add block gas dimensions and re-derive the canonical total.
    pub fn add(a: BlockGas, b: BlockGas) error{Overflow}!BlockGas {
        return fromDimensions(
            try std.math.add(u64, a.regular, b.regular),
            try std.math.add(u64, a.state, b.state),
        );
    }

    /// Check the canonical block gas limit. A zero limit means "unbounded".
    pub fn withinLimit(self: BlockGas, limit: u64) bool {
        return limit == 0 or self.total <= limit;
    }
};

/// Settled gas accounting for one transaction result.
///
/// `used` is the receipt/cumulative-gas value. `block` is the contribution to
/// block/header accounting, which may differ from receipt gas after refunds or
/// EIP-8037 state-gas splitting.
pub const ResultGas = struct {
    /// Final receipt gas used after refunds/floor rules.
    used: u64 = 0,
    /// Gas refunded to the sender.
    refunded: u64 = 0,
    /// Block/session accounting contribution.
    block: BlockGas = .{},
};

/// Engine-owned settlement costs for the exact transaction shell.
pub const DefaultCosts = struct {
    gas: ResultGas,
    /// Amount returned to the payer for unused gas.
    payer_refund: u256,
    /// Priority-fee payment routed by the default plan.
    fee_payment: u256,
};

pub const Precharge = struct {
    payer: ?Address = null,
    upfront_debit: u256 = 0,
    minimum_balance: u256 = 0,
};

/// Type-bearing settlement values for the exact transaction shell.
/// Exact values live separately on `Spec.settlement`.
pub const Default = struct {
    pub const Plan = DefaultPlan;
    pub const Costs = DefaultCosts;
};

/// Stateless settlement planner closed over one exact VM specification.
pub fn Runtime(comptime spec: ExactSpec) type {
    return struct {
        pub const specification = spec;
        const Self = @This();
        const settlement = spec.settlement;
        const transaction = spec.transaction;

        pub fn effectivePriorityFee(_: Self, input: FeeInput) u256 {
            if (!settlement.base_fee_active) return input.gas_price;
            if (input.max_fee_per_gas) |max_fee| {
                const max_priority_fee = input.max_priority_fee_per_gas orelse 0;
                if (max_fee <= input.base_fee) return 0;
                return @min(max_priority_fee, max_fee - input.base_fee);
            }
            if (input.gas_price <= input.base_fee) return 0;
            return input.gas_price - input.base_fee;
        }

        pub fn defaultPlanFromGasPlan(_: Self, gas_limit: u64, plan: tx_gas.GasPlan, fees: DefaultFees) DefaultPlan {
            const upfront_debit = prechargeCost(transaction.blob_schedule, gas_limit, fees.gas_price, fees.blob_base_fee, fees.blob_count) orelse std.math.maxInt(u256);
            return .{
                .payer = fees.payer,
                .gas_limit = gas_limit,
                .intrinsic_gas = plan.intrinsic_gas,
                .floor_gas = plan.floor_gas,
                .gas_price = fees.gas_price,
                .priority_fee = fees.priority_fee,
                .fee_recipient = fees.fee_recipient,
                .upfront_debit = upfront_debit,
                .minimum_balance = std.math.add(u256, upfront_debit, fees.value) catch std.math.maxInt(u256),
            };
        }

        pub fn planPrecharge(_: Self, plan: DefaultPlan) Precharge {
            return .{
                .payer = plan.payer,
                .upfront_debit = plan.upfront_debit,
                .minimum_balance = plan.minimum_balance,
            };
        }

        pub fn planCosts(self: Self, plan: DefaultPlan, result: ExecutionGasResult) !DefaultCosts {
            return self.defaultCosts(plan, result);
        }

        pub fn planGas(_: Self, costs: DefaultCosts) ResultGas {
            return costs.gas;
        }

        pub fn defaultCosts(_: Self, plan: DefaultPlan, result: ExecutionGasResult) !DefaultCosts {
            return calculateDefaultCosts(
                plan,
                result,
                settlement.uses_state_gas_accounting,
                settlement.gas_refund_cap_divisor,
                settlement.applies_calldata_floor_to_block_regular_gas,
            );
        }
    };
}

fn runtime(comptime spec: ExactSpec) Runtime(spec) {
    return .{};
}

fn prechargeCost(blob_schedule: ?tx_blob.BlobSchedule, gas_limit: u64, gas_price: u256, blob_base_fee: u256, blob_count: usize) ?u256 {
    const gas_cost = checkedGasCost(gas_limit, gas_price) catch return null;
    const blob_gas = blobGasForCount(blob_schedule, blob_count) orelse return null;
    const blob_cost = std.math.mul(u256, blob_gas, blob_base_fee) catch return null;
    return std.math.add(u256, gas_cost, blob_cost) catch null;
}

fn blobGasForCount(blob_schedule: ?tx_blob.BlobSchedule, blob_count: usize) ?u256 {
    if (blob_count == 0) return 0;
    const schedule = blob_schedule orelse return null;
    return schedule.blobGasForSchedule(blob_count);
}

fn calculateDefaultCosts(
    settlement: DefaultPlan,
    result: ExecutionGasResult,
    uses_state_gas_accounting: bool,
    refund_cap_divisor: u64,
    applies_calldata_floor_to_block_regular_gas: bool,
) !DefaultCosts {
    const gas_left = positiveGas(result.gas_left);
    const gas_reservoir = if (uses_state_gas_accounting) positiveGas(result.gas_reservoir) else 0;
    // EIP-8037: `gas_left` is regular gas only; unused state reservoir is also
    // refunded, so transaction gas spent subtracts both remaining pools.
    const pre_refund_gas_used = if (uses_state_gas_accounting)
        settlement.gas_limit - @min(settlement.gas_limit, gas_left +| gas_reservoir)
    else
        settlement.gas_limit - @min(settlement.gas_limit, gas_left);
    const refund_cap = pre_refund_gas_used / refund_cap_divisor;
    const raw_refund = if (result.gas_refund > 0)
        std.math.cast(u64, result.gas_refund) orelse std.math.maxInt(u64)
    else
        0;
    const refund_gas = @min(raw_refund, refund_cap);
    const gas_used_after_refund = pre_refund_gas_used - @min(pre_refund_gas_used, refund_gas);
    const gas_used = @max(gas_used_after_refund, settlement.floor_gas);
    const block_state_gas_used = if (uses_state_gas_accounting) positiveGas(result.state_gas_spent) else 0;
    const block_regular_before_floor = pre_refund_gas_used - @min(pre_refund_gas_used, block_state_gas_used);
    const block_regular_gas_used = if (uses_state_gas_accounting)
        if (applies_calldata_floor_to_block_regular_gas)
            @max(block_regular_before_floor, settlement.floor_gas)
        else
            block_regular_before_floor
    else
        gas_used;
    const block_gas = if (uses_state_gas_accounting)
        BlockGas.fromDimensions(block_regular_gas_used, block_state_gas_used)
    else
        BlockGas.legacy(gas_used);
    const sender_refunded_gas = settlement.gas_limit - @min(settlement.gas_limit, gas_used);

    return .{
        .gas = .{
            .used = gas_used,
            .refunded = sender_refunded_gas,
            .block = block_gas,
        },
        .payer_refund = try checkedGasCost(sender_refunded_gas, settlement.gas_price),
        .fee_payment = try checkedGasCost(gas_used, settlement.priority_fee),
    };
}

pub fn checkedGasCost(gas: u64, price: u256) !u256 {
    return std.math.mul(u256, @as(u256, gas), price) catch error.Overflow;
}

fn positiveGas(gas: i64) u64 {
    if (gas <= 0) return 0;
    return std.math.cast(u64, gas) orelse std.math.maxInt(u64);
}

test "effective priority fee follows legacy and dynamic fee policy" {
    const eth = @import("../eth.zig");
    const Berlin = eth.berlin;
    const London = eth.london;

    try std.testing.expectEqual(@as(u256, 7), runtime(Berlin).effectivePriorityFee(.{
        .gas_price = 7,
    }));
    try std.testing.expectEqual(@as(u256, 0), runtime(London).effectivePriorityFee(.{
        .gas_price = 9,
        .base_fee = 10,
    }));
    try std.testing.expectEqual(@as(u256, 2), runtime(London).effectivePriorityFee(.{
        .gas_price = 12,
        .base_fee = 10,
    }));
    try std.testing.expectEqual(@as(u256, 3), runtime(London).effectivePriorityFee(.{
        .gas_price = 0,
        .base_fee = 10,
        .max_fee_per_gas = 20,
        .max_priority_fee_per_gas = 3,
    }));
    try std.testing.expectEqual(@as(u256, 0), runtime(London).effectivePriorityFee(.{
        .gas_price = 0,
        .base_fee = 20,
        .max_fee_per_gas = 20,
        .max_priority_fee_per_gas = 3,
    }));
}

test "settlement cost vectors follow fork and exact-spec policies" {
    const eth = @import("../eth.zig");
    const eth_tx = @import("../eth/transaction.zig");
    const refund_plan = DefaultPlan{
        .gas_limit = 100,
        .intrinsic_gas = 20,
        .floor_gas = 0,
        .gas_price = 5,
        .priority_fee = 2,
        .fee_recipient = address.addr(0xbeef),
    };
    const refund_result = ExecutionGasResult{
        .gas_left = 40,
        .gas_refund = 100,
        .gas_reservoir = 0,
        .state_gas_spent = 0,
    };
    const custom_spec = eth.amsterdam.extend(.{ .settlement = .{
        .gas_refund_cap_divisor = 4,
        .uses_state_gas_accounting = true,
        .applies_calldata_floor_to_block_regular_gas = false,
    } });
    inline for (.{
        .{
            .spec = eth.london,
            .plan = refund_plan,
            .result = refund_result,
            .expected = DefaultCosts{
                .gas = .{ .used = 48, .refunded = 52, .block = .{ .total = 48, .regular = 48 } },
                .payer_refund = 260,
                .fee_payment = 96,
            },
        },
        .{
            .spec = eth.berlin,
            .plan = refund_plan,
            .result = refund_result,
            .expected = DefaultCosts{
                .gas = .{ .used = 30, .refunded = 70, .block = .{ .total = 30, .regular = 30 } },
                .payer_refund = 350,
                .fee_payment = 60,
            },
        },
        .{
            .spec = custom_spec,
            .plan = DefaultPlan{
                .gas_limit = 100,
                .intrinsic_gas = 20,
                .floor_gas = 30,
                .gas_price = 5,
                .priority_fee = 2,
                .fee_recipient = address.addr(0xbeef),
            },
            .result = ExecutionGasResult{
                .gas_left = 20,
                .gas_refund = 100,
                .gas_reservoir = 30,
                .state_gas_spent = 7,
            },
            .expected = DefaultCosts{
                .gas = .{ .used = 38, .refunded = 62, .block = .{ .total = 43, .regular = 43, .state = 7 } },
                .payer_refund = 310,
                .fee_payment = 76,
            },
        },
        .{
            .spec = eth.prague,
            .plan = DefaultPlan{
                .gas_limit = 21_100,
                .intrinsic_gas = 21_016,
                .floor_gas = 21_040,
                .gas_price = 7,
                .priority_fee = 0,
                .fee_recipient = address.addr(0xbeef),
            },
            .result = ExecutionGasResult{
                .gas_left = 84,
                .gas_refund = 20,
                .gas_reservoir = 0,
                .state_gas_spent = 0,
            },
            .expected = DefaultCosts{
                .gas = .{ .used = 21_040, .refunded = 60, .block = .{ .total = 21_040, .regular = 21_040 } },
                .payer_refund = 420,
                .fee_payment = 0,
            },
        },
        .{
            .spec = eth.amsterdam,
            .plan = DefaultPlan{
                .gas_limit = 200,
                .intrinsic_gas = 20,
                .floor_gas = 30,
                .gas_price = 5,
                .priority_fee = 2,
                .fee_recipient = address.addr(0xbeef),
            },
            .result = ExecutionGasResult{
                .gas_left = 20,
                .gas_refund = 0,
                .gas_reservoir = 100,
                .state_gas_spent = 70,
            },
            .expected = DefaultCosts{
                .gas = .{ .used = 80, .refunded = 120, .block = .{ .total = 70, .regular = 30, .state = 70 } },
                .payer_refund = 600,
                .fee_payment = 160,
            },
        },
        .{
            .spec = eth.amsterdam,
            .plan = refund_plan,
            .result = refund_result,
            .expected = DefaultCosts{
                .gas = .{ .used = 48, .refunded = 52, .block = .{ .total = 60, .regular = 60 } },
                .payer_refund = 260,
                .fee_payment = 96,
            },
        },
        .{
            .spec = eth.amsterdam,
            .plan = DefaultPlan{
                .gas_limit = 120_000_000,
                .intrinsic_gas = 21_000,
                .floor_gas = 21_000,
                .gas_price = 10,
                .priority_fee = 3,
                .fee_recipient = address.addr(0xbeef),
            },
            .result = ExecutionGasResult{
                .gas_left = 0,
                .gas_refund = 0,
                .gas_reservoir = 120_000_000 - eth_tx.max_transaction_gas_limit,
                .state_gas_spent = 0,
            },
            .expected = DefaultCosts{
                .gas = .{
                    .used = eth_tx.max_transaction_gas_limit,
                    .refunded = 120_000_000 - eth_tx.max_transaction_gas_limit,
                    .block = .{
                        .total = eth_tx.max_transaction_gas_limit,
                        .regular = eth_tx.max_transaction_gas_limit,
                    },
                },
                .payer_refund = (120_000_000 - eth_tx.max_transaction_gas_limit) * 10,
                .fee_payment = eth_tx.max_transaction_gas_limit * 3,
            },
        },
        .{
            .spec = eth.amsterdam,
            .plan = DefaultPlan{
                .gas_limit = 282_798,
                .intrinsic_gas = 88_198,
                .floor_gas = 282_776,
                .gas_price = 10,
                .priority_fee = 3,
                .fee_recipient = address.addr(0xbeef),
            },
            .result = ExecutionGasResult{
                .gas_left = 0,
                .gas_refund = 0,
                .gas_reservoir = eth_tx.amsterdam_new_account_state_gas,
                .state_gas_spent = 0,
            },
            .expected = DefaultCosts{
                .gas = .{ .used = 282_776, .refunded = 22, .block = .{ .total = 282_776, .regular = 282_776 } },
                .payer_refund = 220,
                .fee_payment = 848_328,
            },
        },
    }) |case| {
        try std.testing.expectEqualDeep(case.expected, try runtime(case.spec).defaultCosts(case.plan, case.result));
    }
}

test "settlement policy selects calldata floor contribution to dimensional block gas" {
    const eth = @import("../eth.zig");
    const without_block_floor = eth.amsterdam.extend(.{ .settlement = .{
        .gas_refund_cap_divisor = 5,
        .uses_state_gas_accounting = true,
        .applies_calldata_floor_to_block_regular_gas = false,
    } });
    const with_block_floor = eth.amsterdam.extend(.{ .settlement = .{
        .gas_refund_cap_divisor = 5,
        .uses_state_gas_accounting = true,
        .applies_calldata_floor_to_block_regular_gas = true,
    } });
    const settlement = DefaultPlan{
        .gas_limit = 100,
        .intrinsic_gas = 20,
        .floor_gas = 30,
        .gas_price = 5,
        .priority_fee = 2,
        .fee_recipient = address.addr(0xbeef),
    };
    const result = ExecutionGasResult{
        .gas_left = 80,
        .gas_refund = 0,
        .gas_reservoir = 0,
        .state_gas_spent = 0,
    };

    const without_floor = try runtime(without_block_floor).defaultCosts(settlement, result);
    const with_floor = try runtime(with_block_floor).defaultCosts(settlement, result);

    try std.testing.expectEqual(@as(u64, 30), without_floor.gas.used);
    try std.testing.expectEqual(@as(u64, 20), without_floor.gas.block.regular);
    try std.testing.expectEqual(@as(u64, 30), with_floor.gas.block.regular);
}

test "Amsterdam block gas sums dimensions before selecting the header total" {
    const first = BlockGas.fromDimensions(100, 1);
    const second = BlockGas.fromDimensions(1, 100);
    const combined = try first.add(second);

    try std.testing.expectEqual(@as(u64, 101), combined.regular);
    try std.testing.expectEqual(@as(u64, 101), combined.state);
    try std.testing.expectEqual(@as(u64, 101), combined.total);
}
