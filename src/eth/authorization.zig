//! Ethereum authorization policy.
//!
//! Authorization owns tuple-local validity consequences and gas decisions.
//! The transaction transition owns tuple order, runtime gas transport, and the
//! rollback boundary around the complete authorization phase.

const definition = @import("../definition.zig");
const contract = @import("../protocol/types.zig");
const tx = @import("transaction.zig");
const Revision = @import("revision.zig").Revision;

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
            return .{
                .account_state_charge = if (input.account_exists)
                    0
                else
                    tx.amsterdam_new_account_state_gas,
                .account_write_charge = if (input.account_already_written)
                    0
                else
                    tx.amsterdam_account_write_cost,
                .delegation_state_charge = if (!input.clears_delegation and
                    !input.delegated_before_transaction and
                    !input.delegation_set_before)
                    tx.amsterdam_auth_base_state_gas
                else
                    0,
            };
        }
        if (!input.account_exists) return .{};
        return .{ .regular_refund = tx.authorization_existing_account_refund_gas };
    }

    pub fn invalidGasAdjustment(_: Revision) contract.AuthorizationGasAdjustment {
        return .{};
    }

    pub fn malformedGasAdjustment(_: Revision, _: usize) contract.AuthorizationGasAdjustment {
        return .{};
    }
};
