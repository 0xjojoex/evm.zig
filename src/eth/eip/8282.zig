//! EIP-8282 builder execution request constants.

const address = @import("../../address.zig");
const types = @import("../../protocol/types.zig");

pub const builder_deposit_request_type: u8 = 0x03;
pub const builder_exit_request_type: u8 = 0x04;

pub const builder_deposit_predeploy_address = address.addr(0x0000884d2aa32eaa155f59a2f24efa73d9008282);
pub const builder_exit_predeploy_address = address.addr(0x000014574a74c805590aff9499fc7a690f008282);

pub fn builderDepositFinalizeSystemCall(system_address: address.Address, gas: u64) types.FinalizeSystemCall {
    return .{
        .call = .{
            .sender = system_address,
            .recipient = builder_deposit_predeploy_address,
            .gas = gas,
            .require_code = true,
        },
        .output_prefix = builder_deposit_request_type,
    };
}

pub fn builderExitFinalizeSystemCall(system_address: address.Address, gas: u64) types.FinalizeSystemCall {
    return .{
        .call = .{
            .sender = system_address,
            .recipient = builder_exit_predeploy_address,
            .gas = gas,
            .require_code = true,
        },
        .output_prefix = builder_exit_request_type,
    };
}
