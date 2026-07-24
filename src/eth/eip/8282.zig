//! EIP-8282 builder execution request constants.

const address = @import("../../address.zig");
const block_program = @import("../../block_program.zig");

pub const builder_deposit_request_type: u8 = 0x03;
pub const builder_exit_request_type: u8 = 0x04;

pub const builder_deposit_predeploy_address = address.addr(0x0000bff46984e3725691fa540a8c7589300d8282);
pub const builder_exit_predeploy_address = address.addr(0x000064d678505ad48f8ccb093bc65613800e8282);

pub fn builderDepositFinalizeSystemCall(system_address: address.Address, gas: u64, state_gas: u64) block_program.FinalizeSystemCall {
    return .{
        .call = .{
            .sender = system_address,
            .recipient = builder_deposit_predeploy_address,
            .gas = gas,
            .state_gas = state_gas,
            .require_code = true,
        },
        .output_prefix = builder_deposit_request_type,
    };
}

pub fn builderExitFinalizeSystemCall(system_address: address.Address, gas: u64, state_gas: u64) block_program.FinalizeSystemCall {
    return .{
        .call = .{
            .sender = system_address,
            .recipient = builder_exit_predeploy_address,
            .gas = gas,
            .state_gas = state_gas,
            .require_code = true,
        },
        .output_prefix = builder_exit_request_type,
    };
}
