//! EIP-7002 withdrawal request constants.

const address = @import("../../address.zig");
const block_lifecycle = @import("../../block/lifecycle.zig");

pub const request_type: u8 = 0x01;
pub const predeploy_address = address.addr(0x00000961ef480eb55e80d19ad83579a64c007002);

pub fn finalizeSystemCall(system_address: address.Address, gas: u64, state_gas: u64) block_lifecycle.FinalizeSystemCall {
    return .request(request_type, predeploy_address, system_address, gas, state_gas);
}
