//! EIP-7002 withdrawal request constants.

const address = @import("../../address.zig");
const interface = @import("../../protocol/interface.zig");

pub const request_type: u8 = 0x01;
pub const predeploy_address = address.addr(0x00000961ef480eb55e80d19ad83579a64c007002);

pub fn blockEndSystemCall(system_address: address.Address, gas: u64) interface.BlockEndSystemCall {
    return .{
        .sender = system_address,
        .recipient = predeploy_address,
        .gas = gas,
        .request_type = request_type,
        .require_code = true,
    };
}
