const std = @import("std");
const address = @import("../address.zig");
const support = @import("../protocol/support.zig");
const contract = @import("../protocol/interface.zig");
const tx = @import("transaction.zig");
const tx_settlement = @import("../transaction/settlement.zig");
const Revision = @import("revision.zig").Revision;
const Address = address.Address;

pub const Settlement = struct {
    pub const Plan = tx_settlement.Plan;

    pub fn revisionId(plan: Plan) support.RevisionId {
        return plan.revision_id;
    }

    pub fn precharge(plan: Plan) tx_settlement.Precharge {
        return .{
            .payer = plan.payer,
            .upfront_debit = plan.upfront_debit,
            .minimum_balance = plan.minimum_balance,
        };
    }

    pub fn feeRecipient(plan: Plan) ?Address {
        return plan.coinbase;
    }

    pub fn costs(comptime Protocol: type, plan: Plan, result: tx_settlement.ExecutionGasResult) !tx_settlement.SettlementCosts {
        return tx_settlement.For(Protocol).settlementCosts(plan, result);
    }

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

pub const Authorization = struct {
    pub fn warmsDelegatedTarget(revision: Revision) bool {
        return revision.isImpl(.prague) and !revision.isImpl(.amsterdam);
    }

    pub fn active(revision: Revision) bool {
        return revision.isImpl(.prague);
    }

    pub fn successGasAdjustment(
        revision: Revision,
        account_exists: bool,
        clears_delegation: bool,
        cur_delegated: bool,
        pre_delegated: bool,
    ) contract.AuthorizationGasAdjustment {
        if (revision.isImpl(.amsterdam)) {
            var adjustment = contract.AuthorizationGasAdjustment{};
            if (account_exists) {
                adjustment.add(.{
                    .regular_refund = tx.amsterdam_account_write_cost,
                    .state_refund = tx.amsterdam_new_account_state_gas,
                });
            }
            if (clears_delegation) {
                adjustment.add(.{ .state_refund = tx.amsterdam_auth_base_state_gas });
                if (cur_delegated and !pre_delegated) {
                    adjustment.add(.{ .state_refund = tx.amsterdam_auth_base_state_gas });
                }
            } else if (cur_delegated or pre_delegated) {
                adjustment.add(.{ .state_refund = tx.amsterdam_auth_base_state_gas });
            }
            return adjustment;
        }
        if (!account_exists) return .{};
        return .{ .regular_refund = tx.authorization_existing_account_refund_gas };
    }

    pub fn invalidGasAdjustment(revision: Revision) contract.AuthorizationGasAdjustment {
        if (!revision.isImpl(.amsterdam)) return .{};
        return .{
            .regular_refund = tx.amsterdam_account_write_cost,
            .state_refund = tx.amsterdam_authorization_state_gas,
        };
    }

    pub fn malformedGasAdjustment(revision: Revision, missing_count: usize) contract.AuthorizationGasAdjustment {
        if (!revision.isImpl(.amsterdam)) return .{};
        const count = std.math.cast(u64, missing_count) orelse std.math.maxInt(u64);
        return .{
            .regular_refund = std.math.mul(u64, tx.amsterdam_account_write_cost, count) catch std.math.maxInt(u64),
            .state_refund = std.math.mul(u64, tx.amsterdam_authorization_state_gas, count) catch std.math.maxInt(u64),
        };
    }
};
