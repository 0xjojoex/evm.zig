//! EIP-7251 consolidation request constants.

const address = @import("../../address.zig");
const block_program = @import("../../block_program.zig");

pub const request_type: u8 = 0x02;
pub const predeploy_address = address.addr(0x0000bbddc7ce488642fb579f8b00f3a590007251);

pub fn finalizeSystemCall(system_address: address.Address, gas: u64, state_gas: u64) block_program.FinalizeSystemCall {
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
