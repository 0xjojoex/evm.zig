//! EIP-7251 consolidation request constants.

const address = @import("../../address.zig");
const interface = @import("../../protocol/interface.zig");

pub const request_type: u8 = 0x02;
pub const predeploy_address = address.addr(0x0000bbddc7ce488642fb579f8b00f3a590007251);

pub fn blockEndSystemCall(system_address: address.Address, gas: u64) interface.BlockEndSystemCall {
    return .{
        .sender = system_address,
        .recipient = predeploy_address,
        .gas = gas,
        .request_type = request_type,
        .require_code = true,
    };
}
