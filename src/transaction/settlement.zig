const std = @import("std");

const address = @import("../address.zig");
const Address = address.Address;
const definition_support = @import("../protocol/support.zig");
const tx_blob = @import("blob.zig");
const tx_gas = @import("gas.zig");
const EthRevision = @import("../eth/revision.zig").Revision;

pub const FeeInput = struct {
    gas_price: u256,
    base_fee: u256 = 0,
    max_fee_per_gas: ?u256 = null,
    max_priority_fee_per_gas: ?u256 = null,
};

pub const Settlement = struct {
    revision_id: definition_support.RevisionId,
    payer: ?Address = null,
    gas_limit: u64,
    intrinsic_gas: u64,
    intrinsic_state_gas: u64,
    floor_gas: u64,
    gas_price: u256,
    priority_fee: u256,
    coinbase: Address,
    upfront_debit: u256 = 0,
    minimum_balance: u256 = 0,
};

pub const Plan = Settlement;

pub const SettlementFees = struct {
    gas_price: u256,
    priority_fee: u256,
    coinbase: Address,
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
};

pub const SettlementCosts = struct {
    gas_used: u64,
    block_gas_used: u64,
    block_regular_gas_used: u64 = 0,
    block_state_gas_used: u64 = 0,
    refunded_gas: u64,
    sender_refund: u256,
    coinbase_payment: u256,
};

pub const Precharge = struct {
    payer: ?Address = null,
    upfront_debit: u256 = 0,
    minimum_balance: u256 = 0,
};

const EthereumSettlementProtocol = struct {
    pub const Revision = EthRevision;

    pub const Settlement = struct {
        pub fn baseFeeActive(revision: Revision) bool {
            return revision.isImpl(.london);
        }

        pub fn gasRefundCapDivisor(revision: Revision) u64 {
            return if (revision.isImpl(.london)) 5 else 2;
        }

        pub fn usesStateGasAccounting(revision: Revision) bool {
            return revision.isImpl(.amsterdam);
        }
    };
};

pub fn For(comptime ProtocolType: type) type {
    return struct {
        pub const Protocol = ProtocolType;

        pub fn effectivePriorityFee(revision: Protocol.Revision, input: FeeInput) u256 {
            definition_support.assertRevisionSupported(Protocol, revision);
            if (!Protocol.Settlement.baseFeeActive(revision)) return input.gas_price;
            if (input.max_fee_per_gas) |max_fee| {
                const max_priority_fee = input.max_priority_fee_per_gas orelse 0;
                if (max_fee <= input.base_fee) return 0;
                return @min(max_priority_fee, max_fee - input.base_fee);
            }
            if (input.gas_price <= input.base_fee) return 0;
            return input.gas_price - input.base_fee;
        }

        pub fn settlementFromGasPlan(revision: Protocol.Revision, gas_limit: u64, plan: tx_gas.GasPlan, fees: SettlementFees) Settlement {
            const upfront_debit = prechargeCost(Protocol, revision, gas_limit, fees.gas_price, fees.blob_base_fee, fees.blob_count) orelse std.math.maxInt(u256);
            return .{
                .revision_id = definition_support.revisionIdForProtocol(Protocol, revision),
                .payer = fees.payer,
                .gas_limit = gas_limit,
                .intrinsic_gas = plan.intrinsic_gas,
                .intrinsic_state_gas = plan.intrinsic_state_gas,
                .floor_gas = plan.floor_gas,
                .gas_price = fees.gas_price,
                .priority_fee = fees.priority_fee,
                .coinbase = fees.coinbase,
                .upfront_debit = upfront_debit,
                .minimum_balance = std.math.add(u256, upfront_debit, fees.value) catch std.math.maxInt(u256),
            };
        }

        pub fn planRevisionId(plan: Protocol.Settlement.Plan) ?definition_support.RevisionId {
            if (comptime std.meta.hasFn(Protocol.Settlement, "revisionId")) {
                return Protocol.Settlement.revisionId(plan);
            }
            if (comptime Protocol.Settlement.Plan == Settlement) return plan.revision_id;
            return null;
        }

        pub fn planPrecharge(plan: Protocol.Settlement.Plan) Precharge {
            if (comptime std.meta.hasFn(Protocol.Settlement, "precharge")) {
                return Protocol.Settlement.precharge(plan);
            }
            if (comptime Protocol.Settlement.Plan == Settlement) return .{
                .payer = plan.payer,
                .upfront_debit = plan.upfront_debit,
                .minimum_balance = plan.minimum_balance,
            };
            return .{};
        }

        pub fn planFeeRecipient(plan: Protocol.Settlement.Plan) ?Address {
            if (comptime std.meta.hasFn(Protocol.Settlement, "feeRecipient")) {
                return Protocol.Settlement.feeRecipient(plan);
            }
            if (comptime Protocol.Settlement.Plan == Settlement) return plan.coinbase;
            return null;
        }

        pub fn planCosts(plan: Protocol.Settlement.Plan, result: ExecutionGasResult) !SettlementCosts {
            if (comptime std.meta.hasFn(Protocol.Settlement, "costs")) {
                return Protocol.Settlement.costs(Protocol, plan, result);
            }
            if (comptime Protocol.Settlement.Plan == Settlement) return settlementCosts(plan, result);
            @compileError("Protocol.Settlement must provide costs(comptime Protocol, plan, result)");
        }

        pub fn settlementCosts(settlement: Settlement, result: ExecutionGasResult) !SettlementCosts {
            const revision = definition_support.decodeRevisionForProtocol(Protocol, settlement.revision_id);
            const uses_state_gas_accounting = Protocol.Settlement.usesStateGasAccounting(revision);
            const gas_left = positiveGas(result.gas_left);
            const gas_reservoir = if (uses_state_gas_accounting) positiveGas(result.gas_reservoir) else 0;
            // EIP-8037: `gas_left` is regular gas only; unused state reservoir is also
            // refunded, so transaction gas spent subtracts both remaining pools.
            const pre_refund_gas_used = if (uses_state_gas_accounting)
                settlement.gas_limit - @min(settlement.gas_limit, gas_left +| gas_reservoir)
            else
                settlement.gas_limit - @min(settlement.gas_limit, gas_left);
            const refund_cap_divisor = Protocol.Settlement.gasRefundCapDivisor(revision);
            const refund_cap = pre_refund_gas_used / refund_cap_divisor;
            const raw_refund = if (result.gas_refund > 0)
                std.math.cast(u64, result.gas_refund) orelse std.math.maxInt(u64)
            else
                0;
            const refund_gas = @min(raw_refund, refund_cap);
            const gas_used_after_refund = pre_refund_gas_used - @min(pre_refund_gas_used, refund_gas);
            const gas_used = @max(gas_used_after_refund, settlement.floor_gas);
            const block_state_gas_used = if (uses_state_gas_accounting)
                settledStateGas(settlement.intrinsic_state_gas, result.state_gas_spent)
            else
                0;
            const block_regular_before_floor = pre_refund_gas_used - @min(pre_refund_gas_used, block_state_gas_used);
            const block_regular_gas_used = if (uses_state_gas_accounting)
                @max(block_regular_before_floor, settlement.floor_gas)
            else
                gas_used;
            const block_gas_used = if (uses_state_gas_accounting)
                @max(block_regular_gas_used, block_state_gas_used)
            else
                gas_used;
            const sender_refunded_gas = settlement.gas_limit - @min(settlement.gas_limit, gas_used);

            return .{
                .gas_used = gas_used,
                .block_gas_used = block_gas_used,
                .block_regular_gas_used = block_regular_gas_used,
                .block_state_gas_used = block_state_gas_used,
                .refunded_gas = sender_refunded_gas,
                .sender_refund = try checkedGasCost(sender_refunded_gas, settlement.gas_price),
                .coinbase_payment = try checkedGasCost(gas_used, settlement.priority_fee),
            };
        }
    };
}

fn prechargeCost(comptime Protocol: type, revision: Protocol.Revision, gas_limit: u64, gas_price: u256, blob_base_fee: u256, blob_count: usize) ?u256 {
    const gas_cost = checkedGasCost(gas_limit, gas_price) catch return null;
    const blob_gas = blobGasForCount(Protocol, revision, blob_count) orelse return null;
    const blob_cost = std.math.mul(u256, blob_gas, blob_base_fee) catch return null;
    return std.math.add(u256, gas_cost, blob_cost) catch null;
}

fn blobGasForCount(comptime Protocol: type, revision: Protocol.Revision, blob_count: usize) ?u256 {
    if (blob_count == 0) return 0;
    const schedule = Protocol.Transaction.blobSchedule(revision) orelse return null;
    return tx_blob.blobGasForSchedule(schedule, blob_count);
}

pub fn checkedGasCost(gas: u64, price: u256) !u256 {
    return std.math.mul(u256, @as(u256, gas), price) catch error.Overflow;
}

fn positiveGas(gas: i64) u64 {
    if (gas <= 0) return 0;
    return std.math.cast(u64, gas) orelse std.math.maxInt(u64);
}

fn settledStateGas(intrinsic_state_gas: u64, execution_state_gas: i64) u64 {
    if (execution_state_gas >= 0) {
        return intrinsic_state_gas +| (std.math.cast(u64, execution_state_gas) orelse std.math.maxInt(u64));
    }
    return intrinsic_state_gas -| (std.math.cast(u64, -execution_state_gas) orelse std.math.maxInt(u64));
}

test "effective priority fee follows legacy and dynamic fee policy" {
    try std.testing.expectEqual(@as(u256, 7), For(EthereumSettlementProtocol).effectivePriorityFee(.berlin, .{
        .gas_price = 7,
    }));
    try std.testing.expectEqual(@as(u256, 0), For(EthereumSettlementProtocol).effectivePriorityFee(.london, .{
        .gas_price = 9,
        .base_fee = 10,
    }));
    try std.testing.expectEqual(@as(u256, 2), For(EthereumSettlementProtocol).effectivePriorityFee(.london, .{
        .gas_price = 12,
        .base_fee = 10,
    }));
    try std.testing.expectEqual(@as(u256, 3), For(EthereumSettlementProtocol).effectivePriorityFee(.london, .{
        .gas_price = 0,
        .base_fee = 10,
        .max_fee_per_gas = 20,
        .max_priority_fee_per_gas = 3,
    }));
    try std.testing.expectEqual(@as(u256, 0), For(EthereumSettlementProtocol).effectivePriorityFee(.london, .{
        .gas_price = 0,
        .base_fee = 20,
        .max_fee_per_gas = 20,
        .max_priority_fee_per_gas = 3,
    }));
}

test "effective priority fee uses comptime base fee policy" {
    const CustomRevision = enum { custom };
    const LegacyFeeProtocol = struct {
        pub const Revision = CustomRevision;

        pub const Settlement = struct {
            pub fn baseFeeActive(revision: Revision) bool {
                _ = revision;
                return false;
            }
        };
    };
    const BaseFeeProtocol = struct {
        pub const Revision = CustomRevision;

        pub const Settlement = struct {
            pub fn baseFeeActive(revision: Revision) bool {
                _ = revision;
                return true;
            }
        };
    };
    const input = FeeInput{
        .gas_price = 12,
        .base_fee = 10,
        .max_fee_per_gas = 20,
        .max_priority_fee_per_gas = 3,
    };

    try std.testing.expectEqual(@as(u256, 12), For(LegacyFeeProtocol).effectivePriorityFee(.custom, input));
    try std.testing.expectEqual(@as(u256, 3), For(BaseFeeProtocol).effectivePriorityFee(.custom, input));
}

test "settlement costs cap gas refund by fork" {
    const coinbase = address.addr(0xbeef);
    const settlement = Settlement{
        .revision_id = definition_support.revisionId(EthRevision.london),
        .gas_limit = 100,
        .intrinsic_gas = 20,
        .intrinsic_state_gas = 0,
        .floor_gas = 0,
        .gas_price = 5,
        .priority_fee = 2,
        .coinbase = coinbase,
    };
    const costs = try For(EthereumSettlementProtocol).settlementCosts(settlement, .{
        .gas_left = 40,
        .gas_refund = 100,
        .gas_reservoir = 0,
        .state_gas_spent = 0,
    });

    try std.testing.expectEqual(@as(u64, 48), costs.gas_used);
    try std.testing.expectEqual(@as(u64, 48), costs.block_gas_used);
    try std.testing.expectEqual(@as(u64, 52), costs.refunded_gas);
    try std.testing.expectEqual(@as(u256, 260), costs.sender_refund);
    try std.testing.expectEqual(@as(u256, 96), costs.coinbase_payment);
}

test "settlement costs use comptime gas accounting policy" {
    const CustomRevision = enum(u8) { custom };
    const CustomSettlementProtocol = struct {
        pub const Revision = CustomRevision;

        pub const Settlement = struct {
            pub fn gasRefundCapDivisor(revision: Revision) u64 {
                _ = revision;
                return 4;
            }

            pub fn usesStateGasAccounting(revision: Revision) bool {
                _ = revision;
                return true;
            }
        };
    };
    const settlement = Settlement{
        .revision_id = definition_support.revisionId(CustomRevision.custom),
        .gas_limit = 100,
        .intrinsic_gas = 20,
        .intrinsic_state_gas = 10,
        .floor_gas = 30,
        .gas_price = 5,
        .priority_fee = 2,
        .coinbase = address.addr(0xbeef),
    };
    const costs = try For(CustomSettlementProtocol).settlementCosts(settlement, .{
        .gas_left = 20,
        .gas_refund = 100,
        .gas_reservoir = 30,
        .state_gas_spent = 7,
    });

    try std.testing.expectEqual(@as(u64, 38), costs.gas_used);
    try std.testing.expectEqual(@as(u64, 33), costs.block_gas_used);
    try std.testing.expectEqual(@as(u64, 33), costs.block_regular_gas_used);
    try std.testing.expectEqual(@as(u64, 17), costs.block_state_gas_used);
    try std.testing.expectEqual(@as(u64, 62), costs.refunded_gas);
    try std.testing.expectEqual(@as(u256, 310), costs.sender_refund);
    try std.testing.expectEqual(@as(u256, 76), costs.coinbase_payment);
}

test "settlement costs enforce Prague calldata floor after refunds" {
    // EIP-7623 charges the calldata floor after execution gas refunds.
    const coinbase = address.addr(0xbeef);
    const settlement = Settlement{
        .revision_id = definition_support.revisionId(EthRevision.prague),
        .gas_limit = 21_100,
        .intrinsic_gas = 21_016,
        .intrinsic_state_gas = 0,
        .floor_gas = 21_040,
        .gas_price = 7,
        .priority_fee = 0,
        .coinbase = coinbase,
    };
    const costs = try For(EthereumSettlementProtocol).settlementCosts(settlement, .{
        .gas_left = 84,
        .gas_refund = 0,
        .gas_reservoir = 0,
        .state_gas_spent = 0,
    });

    try std.testing.expectEqual(@as(u64, 21_040), costs.gas_used);
    try std.testing.expectEqual(@as(u64, 21_040), costs.block_gas_used);
    try std.testing.expectEqual(@as(u64, 60), costs.refunded_gas);
    try std.testing.expectEqual(@as(u256, 420), costs.sender_refund);
    try std.testing.expectEqual(@as(u256, 0), costs.coinbase_payment);
}

test "Amsterdam block gas accounting excludes refunds" {
    const settlement = Settlement{
        .revision_id = definition_support.revisionId(EthRevision.amsterdam),
        .gas_limit = 100,
        .intrinsic_gas = 20,
        .intrinsic_state_gas = 0,
        .floor_gas = 0,
        .gas_price = 5,
        .priority_fee = 2,
        .coinbase = address.addr(0xbeef),
    };
    const costs = try For(EthereumSettlementProtocol).settlementCosts(settlement, .{
        .gas_left = 40,
        .gas_refund = 100,
        .gas_reservoir = 0,
        .state_gas_spent = 0,
    });

    try std.testing.expectEqual(@as(u64, 48), costs.gas_used);
    try std.testing.expectEqual(@as(u64, 60), costs.block_gas_used);
    try std.testing.expectEqual(@as(u64, 52), costs.refunded_gas);
    try std.testing.expectEqual(@as(u256, 260), costs.sender_refund);
    try std.testing.expectEqual(@as(u256, 96), costs.coinbase_payment);
}

test "Amsterdam settlement charges capped regular gas for high-gas invalid tx" {
    const eth_tx = @import("../eth/transaction.zig");
    const settlement = Settlement{
        .revision_id = definition_support.revisionId(EthRevision.amsterdam),
        .gas_limit = 120_000_000,
        .intrinsic_gas = 21_000,
        .intrinsic_state_gas = 0,
        .floor_gas = 21_000,
        .gas_price = 10,
        .priority_fee = 3,
        .coinbase = address.addr(0xbeef),
    };
    const costs = try For(EthereumSettlementProtocol).settlementCosts(settlement, .{
        .gas_left = 0,
        .gas_refund = 0,
        .gas_reservoir = 120_000_000 - eth_tx.max_transaction_gas_limit,
        .state_gas_spent = 0,
    });

    try std.testing.expectEqual(eth_tx.max_transaction_gas_limit, costs.gas_used);
    try std.testing.expectEqual(eth_tx.max_transaction_gas_limit, costs.block_gas_used);
    try std.testing.expectEqual(@as(u64, 120_000_000 - eth_tx.max_transaction_gas_limit), costs.refunded_gas);
    try std.testing.expectEqual(@as(u256, (120_000_000 - eth_tx.max_transaction_gas_limit) * 10), costs.sender_refund);
    try std.testing.expectEqual(@as(u256, eth_tx.max_transaction_gas_limit * 3), costs.coinbase_payment);
}

test "Amsterdam failed create refills state gas before floor charge" {
    const eth_tx = @import("../eth/transaction.zig");
    const settlement = Settlement{
        .revision_id = definition_support.revisionId(EthRevision.amsterdam),
        .gas_limit = 271_798,
        .intrinsic_gas = 271_798,
        .intrinsic_state_gas = eth_tx.amsterdam_new_account_state_gas,
        .floor_gas = 271_776,
        .gas_price = 10,
        .priority_fee = 3,
        .coinbase = address.addr(0xbeef),
    };
    const costs = try For(EthereumSettlementProtocol).settlementCosts(settlement, .{
        .gas_left = 0,
        .gas_refund = 0,
        .gas_reservoir = eth_tx.amsterdam_new_account_state_gas,
        .state_gas_spent = -@as(i64, eth_tx.amsterdam_new_account_state_gas),
    });

    try std.testing.expectEqual(@as(u64, 271_776), costs.gas_used);
    try std.testing.expectEqual(@as(u64, 271_776), costs.block_gas_used);
    try std.testing.expectEqual(@as(u64, 22), costs.refunded_gas);
    try std.testing.expectEqual(@as(u256, 220), costs.sender_refund);
    try std.testing.expectEqual(@as(u256, 815_328), costs.coinbase_payment);
}
