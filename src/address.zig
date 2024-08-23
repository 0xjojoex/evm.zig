const std = @import("std");

pub const Address = [20]u8;

pub const zero_address: Address = std.mem.zeroes(Address);

/// Returns 0 padding address
pub fn addr(ess: u160) Address {
    if (ess == 0) {
        return zero_address;
    }
    const bytes: [20]u8 = @bitCast(@byteSwap(ess));
    return bytes;
}

test addr {
    const address0 = addr(0);
    try std.testing.expectEqual(zero_address, address0);
    var a = [_]u8{0} ** 20;
    const address1 = addr(1);
    a[19] = 1;
    try std.testing.expectEqual(a, address1);
}
