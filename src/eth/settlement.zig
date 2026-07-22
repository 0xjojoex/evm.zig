const definition = @import("../definition.zig");
const Revision = @import("revision.zig").Revision;

pub const Settlement = struct {
    pub fn Patch(comptime R: type) type {
        const PatchType = struct {
            baseFeeActive: ?*const fn (R) bool = null,
            gasRefundCapDivisor: ?*const fn (R) u64 = null,
            usesStateGasAccounting: ?*const fn (R) bool = null,
            appliesCalldataFloorToBlockRegularGas: ?*const fn (R) bool = null,
            touchesFeeRecipientOnZeroPayment: ?*const fn (R) bool = null,
        };
        definition.assertPatchMirrors(definition.SettlementConfig(R), PatchType);
        return PatchType;
    }

    pub fn config() definition.SettlementConfig(Revision) {
        return .{
            .baseFeeActive = @This().baseFeeActive,
            .gasRefundCapDivisor = @This().gasRefundCapDivisor,
            .usesStateGasAccounting = @This().usesStateGasAccounting,
            .appliesCalldataFloorToBlockRegularGas = @This().appliesCalldataFloorToBlockRegularGas,
            .touchesFeeRecipientOnZeroPayment = @This().touchesFeeRecipientOnZeroPayment,
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

    pub fn appliesCalldataFloorToBlockRegularGas(revision: Revision) bool {
        return revision.isImpl(.amsterdam);
    }

    pub fn touchesFeeRecipientOnZeroPayment(revision: Revision) bool {
        return !revision.isImpl(.spurious_dragon);
    }
};
