//! EIP-7002 withdrawal request constants.

const address = @import("../../address.zig");
const types = @import("../../protocol/types.zig");

pub const request_type: u8 = 0x01;
pub const predeploy_address = address.addr(0x00000961ef480eb55e80d19ad83579a64c007002);

pub fn finalizeSystemCall(system_address: address.Address, gas: u64, state_gas: u64) types.FinalizeSystemCall {
    return .{
        .call = .{
            .sender = system_address,
            .recipient = predeploy_address,
            .gas = gas,
            .state_gas = state_gas,
            .require_code = true,
        },
        .output_prefix = request_type,
    };
}
