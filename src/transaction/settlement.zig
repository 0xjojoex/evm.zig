const std = @import("std");

const address = @import("../address.zig");
const Address = address.Address;
const definition = @import("../definition.zig");
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

/// Engine-owned Ethereum-style settlement plan used by Definition-backed VMs.
/// Representation-changing families keep distinct fee plans in their STF and
/// compose executor lifecycle/state primitives directly.
pub const DefaultPlan = struct {
    revision_id: definition_support.RevisionId,
    payer: ?Address = null,
    gas_limit: u64,
    intrinsic_gas: u64,
    intrinsic_state_gas: u64,
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
    blob_schedule: ?tx_blob.BlobSchedule = null,
};

pub const ExecutionGasResult = struct {
    gas_left: i64,
    gas_refund: i64,
    gas_reservoir: i64,
    state_gas_spent: i64,
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

/// Engine-owned settlement costs for the Definition-backed transaction shell.
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

/// Type-bearing settlement values for the Definition-backed transaction shell.
/// Definition value hooks live separately on `Protocol.settlement`.
pub const Default = struct {
    pub const Plan = DefaultPlan;
    pub const Costs = DefaultCosts;
};

const EthereumSettlementProtocol = struct {
    pub const Revision = EthRevision;

    pub const settlement = struct {
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

/// Settlement planner borrowing one immutable transaction-policy snapshot.
pub fn Runtime(
    comptime ProtocolType: type,
    comptime TransactionPolicy: type,
) type {
    return struct {
        pub const Protocol = ProtocolType;
        const Self = @This();

        policy: *const TransactionPolicy,

        pub fn effectivePriorityFee(self: Self, revision: Protocol.Revision, input: FeeInput) u256 {
            definition_support.assertRevisionSupported(Protocol, revision);
            if (!self.policy.settlement.baseFeeActive(revision)) return input.gas_price;
            if (input.max_fee_per_gas) |max_fee| {
                const max_priority_fee = input.max_priority_fee_per_gas orelse 0;
                if (max_fee <= input.base_fee) return 0;
                return @min(max_priority_fee, max_fee - input.base_fee);
            }
            if (input.gas_price <= input.base_fee) return 0;
            return input.gas_price - input.base_fee;
        }

        pub fn defaultPlanFromGasPlan(self: Self, revision: Protocol.Revision, gas_limit: u64, plan: tx_gas.GasPlan, fees: DefaultFees) DefaultPlan {
            const upfront_debit = prechargeCost(self.policy.transaction.blobSchedule, revision, gas_limit, fees.gas_price, fees.blob_base_fee, fees.blob_count, fees.blob_schedule) orelse std.math.maxInt(u256);
            return .{
                .revision_id = definition_support.revisionIdForProtocol(Protocol, revision),
                .payer = fees.payer,
                .gas_limit = gas_limit,
                .intrinsic_gas = plan.intrinsic_gas,
                .intrinsic_state_gas = plan.intrinsic_state_gas,
                .floor_gas = plan.floor_gas,
                .gas_price = fees.gas_price,
                .priority_fee = fees.priority_fee,
                .fee_recipient = fees.fee_recipient,
                .upfront_debit = upfront_debit,
                .minimum_balance = std.math.add(u256, upfront_debit, fees.value) catch std.math.maxInt(u256),
            };
        }

        pub fn planRevisionId(_: Self, plan: DefaultPlan) definition_support.RevisionId {
            return plan.revision_id;
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

        pub fn defaultCosts(self: Self, settlement: DefaultPlan, result: ExecutionGasResult) !DefaultCosts {
            const revision = definition_support.decodeRevisionForProtocol(Protocol, settlement.revision_id);
            return calculateDefaultCosts(
                settlement,
                result,
                self.policy.settlement.usesStateGasAccounting(revision),
                self.policy.settlement.gasRefundCapDivisor(revision),
            );
        }
    };
}

fn StaticPolicy(comptime Protocol: type) type {
    return struct {
        settlement: definition.SettlementConfig(Protocol.Revision),
        transaction: definition.TransactionPolicyConfig(Protocol.Revision),
    };
}

/// Static-policy adapter for protocol-level helpers and tests. Settlement
/// behavior remains implemented only by `Runtime`.
pub fn For(comptime ProtocolType: type) Runtime(ProtocolType, StaticPolicy(ProtocolType)) {
    const Policy = StaticPolicy(ProtocolType);
    const Values = struct {
        const policy: Policy = .{
            .settlement = definition.projectSettlementConfig(
                ProtocolType.Revision,
                ProtocolType.settlement,
            ),
            .transaction = definition.projectTransactionConfig(
                ProtocolType.Revision,
                if (@hasDecl(ProtocolType, "transaction"))
                    ProtocolType.transaction
                else
                    definition.TransactionConfig(ProtocolType.Revision).default,
            ),
        };
    };
    return .{ .policy = &Values.policy };
}

fn prechargeCost(blob_schedule_for_revision: anytype, revision: anytype, gas_limit: u64, gas_price: u256, blob_base_fee: u256, blob_count: usize, blob_schedule: ?tx_blob.BlobSchedule) ?u256 {
    const gas_cost = checkedGasCost(gas_limit, gas_price) catch return null;
    const blob_gas = blobGasForCount(blob_schedule_for_revision, revision, blob_count, blob_schedule) orelse return null;
    const blob_cost = std.math.mul(u256, blob_gas, blob_base_fee) catch return null;
    return std.math.add(u256, gas_cost, blob_cost) catch null;
}

fn blobGasForCount(blob_schedule_for_revision: anytype, revision: anytype, blob_count: usize, blob_schedule: ?tx_blob.BlobSchedule) ?u256 {
    if (blob_count == 0) return 0;
    const schedule = blob_schedule orelse blob_schedule_for_revision(revision) orelse return null;
    return tx_blob.blobGasForSchedule(schedule, blob_count);
}

fn calculateDefaultCosts(
    settlement: DefaultPlan,
    result: ExecutionGasResult,
    uses_state_gas_accounting: bool,
    refund_cap_divisor: u64,
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
    const block_state_gas_used = if (uses_state_gas_accounting)
        settledStateGas(settlement.intrinsic_state_gas, result.state_gas_spent)
    else
        0;
    const block_regular_before_floor = pre_refund_gas_used - @min(pre_refund_gas_used, block_state_gas_used);
    const block_regular_gas_used = if (uses_state_gas_accounting)
        @max(block_regular_before_floor, settlement.floor_gas)
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

        pub const settlement = struct {
            pub fn baseFeeActive(revision: Revision) bool {
                _ = revision;
                return false;
            }
        };
    };
    const BaseFeeProtocol = struct {
        pub const Revision = CustomRevision;

        pub const settlement = struct {
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
    const settlement = DefaultPlan{
        .revision_id = definition_support.revisionId(EthRevision.london),
        .gas_limit = 100,
        .intrinsic_gas = 20,
        .intrinsic_state_gas = 0,
        .floor_gas = 0,
        .gas_price = 5,
        .priority_fee = 2,
        .fee_recipient = coinbase,
    };
    const costs = try For(EthereumSettlementProtocol).defaultCosts(settlement, .{
        .gas_left = 40,
        .gas_refund = 100,
        .gas_reservoir = 0,
        .state_gas_spent = 0,
    });

    try std.testing.expectEqual(@as(u64, 48), costs.gas.used);
    try std.testing.expectEqual(@as(u64, 48), costs.gas.block.total);
    try std.testing.expectEqual(@as(u64, 52), costs.gas.refunded);
    try std.testing.expectEqual(@as(u256, 260), costs.payer_refund);
    try std.testing.expectEqual(@as(u256, 96), costs.fee_payment);
}

test "settlement costs use comptime gas accounting policy" {
    const CustomRevision = enum(u8) { custom };
    const CustomSettlementProtocol = struct {
        pub const Revision = CustomRevision;

        pub const settlement = struct {
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
    const settlement = DefaultPlan{
        .revision_id = definition_support.revisionId(CustomRevision.custom),
        .gas_limit = 100,
        .intrinsic_gas = 20,
        .intrinsic_state_gas = 10,
        .floor_gas = 30,
        .gas_price = 5,
        .priority_fee = 2,
        .fee_recipient = address.addr(0xbeef),
    };
    const costs = try For(CustomSettlementProtocol).defaultCosts(settlement, .{
        .gas_left = 20,
        .gas_refund = 100,
        .gas_reservoir = 30,
        .state_gas_spent = 7,
    });

    try std.testing.expectEqual(@as(u64, 38), costs.gas.used);
    try std.testing.expectEqual(@as(u64, 33), costs.gas.block.total);
    try std.testing.expectEqual(@as(u64, 33), costs.gas.block.regular);
    try std.testing.expectEqual(@as(u64, 17), costs.gas.block.state);
    try std.testing.expectEqual(@as(u64, 62), costs.gas.refunded);
    try std.testing.expectEqual(@as(u256, 310), costs.payer_refund);
    try std.testing.expectEqual(@as(u256, 76), costs.fee_payment);
}

test "settlement costs enforce Prague calldata floor after refunds" {
    // EIP-7623 charges the calldata floor after execution gas refunds.
    const coinbase = address.addr(0xbeef);
    const settlement = DefaultPlan{
        .revision_id = definition_support.revisionId(EthRevision.prague),
        .gas_limit = 21_100,
        .intrinsic_gas = 21_016,
        .intrinsic_state_gas = 0,
        .floor_gas = 21_040,
        .gas_price = 7,
        .priority_fee = 0,
        .fee_recipient = coinbase,
    };
    const costs = try For(EthereumSettlementProtocol).defaultCosts(settlement, .{
        .gas_left = 84,
        .gas_refund = 0,
        .gas_reservoir = 0,
        .state_gas_spent = 0,
    });

    try std.testing.expectEqual(@as(u64, 21_040), costs.gas.used);
    try std.testing.expectEqual(@as(u64, 21_040), costs.gas.block.total);
    try std.testing.expectEqual(@as(u64, 60), costs.gas.refunded);
    try std.testing.expectEqual(@as(u256, 420), costs.payer_refund);
    try std.testing.expectEqual(@as(u256, 0), costs.fee_payment);
}

test "Amsterdam block gas accounting excludes refunds" {
    const settlement = DefaultPlan{
        .revision_id = definition_support.revisionId(EthRevision.amsterdam),
        .gas_limit = 100,
        .intrinsic_gas = 20,
        .intrinsic_state_gas = 0,
        .floor_gas = 0,
        .gas_price = 5,
        .priority_fee = 2,
        .fee_recipient = address.addr(0xbeef),
    };
    const costs = try For(EthereumSettlementProtocol).defaultCosts(settlement, .{
        .gas_left = 40,
        .gas_refund = 100,
        .gas_reservoir = 0,
        .state_gas_spent = 0,
    });

    try std.testing.expectEqual(@as(u64, 48), costs.gas.used);
    try std.testing.expectEqual(@as(u64, 60), costs.gas.block.total);
    try std.testing.expectEqual(@as(u64, 52), costs.gas.refunded);
    try std.testing.expectEqual(@as(u256, 260), costs.payer_refund);
    try std.testing.expectEqual(@as(u256, 96), costs.fee_payment);
}

test "Amsterdam settlement charges capped regular gas for high-gas invalid tx" {
    const eth_tx = @import("../eth/transaction.zig");
    const settlement = DefaultPlan{
        .revision_id = definition_support.revisionId(EthRevision.amsterdam),
        .gas_limit = 120_000_000,
        .intrinsic_gas = 21_000,
        .intrinsic_state_gas = 0,
        .floor_gas = 21_000,
        .gas_price = 10,
        .priority_fee = 3,
        .fee_recipient = address.addr(0xbeef),
    };
    const costs = try For(EthereumSettlementProtocol).defaultCosts(settlement, .{
        .gas_left = 0,
        .gas_refund = 0,
        .gas_reservoir = 120_000_000 - eth_tx.max_transaction_gas_limit,
        .state_gas_spent = 0,
    });

    try std.testing.expectEqual(eth_tx.max_transaction_gas_limit, costs.gas.used);
    try std.testing.expectEqual(eth_tx.max_transaction_gas_limit, costs.gas.block.total);
    try std.testing.expectEqual(@as(u64, 120_000_000 - eth_tx.max_transaction_gas_limit), costs.gas.refunded);
    try std.testing.expectEqual(@as(u256, (120_000_000 - eth_tx.max_transaction_gas_limit) * 10), costs.payer_refund);
    try std.testing.expectEqual(@as(u256, eth_tx.max_transaction_gas_limit * 3), costs.fee_payment);
}

test "Amsterdam failed create refills state gas before floor charge" {
    const eth_tx = @import("../eth/transaction.zig");
    const settlement = DefaultPlan{
        .revision_id = definition_support.revisionId(EthRevision.amsterdam),
        .gas_limit = 271_798,
        .intrinsic_gas = 271_798,
        .intrinsic_state_gas = eth_tx.amsterdam_new_account_state_gas,
        .floor_gas = 271_776,
        .gas_price = 10,
        .priority_fee = 3,
        .fee_recipient = address.addr(0xbeef),
    };
    const costs = try For(EthereumSettlementProtocol).defaultCosts(settlement, .{
        .gas_left = 0,
        .gas_refund = 0,
        .gas_reservoir = eth_tx.amsterdam_new_account_state_gas,
        .state_gas_spent = -@as(i64, eth_tx.amsterdam_new_account_state_gas),
    });

    try std.testing.expectEqual(@as(u64, 271_776), costs.gas.used);
    try std.testing.expectEqual(@as(u64, 271_776), costs.gas.block.total);
    try std.testing.expectEqual(@as(u64, 22), costs.gas.refunded);
    try std.testing.expectEqual(@as(u256, 220), costs.payer_refund);
    try std.testing.expectEqual(@as(u256, 815_328), costs.fee_payment);
}
