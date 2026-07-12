const std = @import("std");
const definition = @import("../definition.zig");
const contract = @import("../protocol/types.zig");
const tx = @import("transaction.zig");
const Revision = @import("revision.zig").Revision;

pub const Settlement = struct {
    pub fn Patch(comptime R: type) type {
        const PatchType = struct {
            baseFeeActive: ?*const fn (R) bool = null,
            gasRefundCapDivisor: ?*const fn (R) u64 = null,
            usesStateGasAccounting: ?*const fn (R) bool = null,
        };
        definition.assertPatchMirrors(definition.SettlementConfig(R), PatchType);
        return PatchType;
    }

    pub fn config(comptime R: type) definition.SettlementConfig(R) {
        if (R != Revision) return .default;
        return .{
            .baseFeeActive = @This().baseFeeActive,
            .gasRefundCapDivisor = @This().gasRefundCapDivisor,
            .usesStateGasAccounting = @This().usesStateGasAccounting,
        };
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
    pub fn Patch(comptime R: type) type {
        const PatchType = struct {
            active: ?*const fn (R) bool = null,
            warmsDelegatedTarget: ?*const fn (R) bool = null,
            successGasAdjustment: ?*const fn (R, contract.AuthorizationSuccessInput) contract.AuthorizationGasAdjustment = null,
            invalidGasAdjustment: ?*const fn (R) contract.AuthorizationGasAdjustment = null,
            malformedGasAdjustment: ?*const fn (R, usize) contract.AuthorizationGasAdjustment = null,
        };
        definition.assertPatchMirrors(definition.AuthorizationConfig(R), PatchType);
        return PatchType;
    }

    pub fn config(comptime R: type) definition.AuthorizationConfig(R) {
        if (R != Revision) return .default;
        return .{
            .active = @This().active,
            .warmsDelegatedTarget = @This().warmsDelegatedTarget,
            .successGasAdjustment = @This().successGasAdjustment,
            .invalidGasAdjustment = @This().invalidGasAdjustment,
            .malformedGasAdjustment = @This().malformedGasAdjustment,
        };
    }

    pub fn warmsDelegatedTarget(revision: Revision) bool {
        return revision.isImpl(.prague) and !revision.isImpl(.amsterdam);
    }

    pub fn active(revision: Revision) bool {
        return revision.isImpl(.prague);
    }

    pub fn successGasAdjustment(
        revision: Revision,
        input: contract.AuthorizationSuccessInput,
    ) contract.AuthorizationGasAdjustment {
        if (revision.isImpl(.amsterdam)) {
            var adjustment = contract.AuthorizationGasAdjustment{};
            if (input.account_exists) {
                adjustment.add(.{
                    .regular_refund = tx.amsterdam_account_write_cost,
                    .state_refund = tx.amsterdam_new_account_state_gas,
                });
            }
            if (input.clears_delegation) {
                adjustment.add(.{ .state_refund = tx.amsterdam_auth_base_state_gas });
                if (input.delegated_before_tuple and !input.delegated_before_first_tuple) {
                    adjustment.add(.{ .state_refund = tx.amsterdam_auth_base_state_gas });
                }
            } else if (input.delegated_before_tuple or input.delegated_before_first_tuple) {
                adjustment.add(.{ .state_refund = tx.amsterdam_auth_base_state_gas });
            }
            return adjustment;
        }
        if (!input.account_exists) return .{};
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
