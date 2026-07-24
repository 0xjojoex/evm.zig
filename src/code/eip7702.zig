//! EIP-7702 delegation-indicator mechanism.

const std = @import("std");
const address = @import("../address.zig");

pub const Address = address.Address;
pub const delegation_designator = [_]u8{ 0xef, 0x01, 0x00 };
pub const delegation_address_len: usize = 20;
pub const delegation_code_len: usize = delegation_designator.len + delegation_address_len;
pub const delegation_indicator_state_bytes: u64 = @intCast(delegation_code_len);

pub const DecodeError = error{
    InvalidDelegationLength,
    UnsupportedDelegationVersion,
};

/// Decode delegation-shaped code, rejecting malformed `0xef01` forms.
/// Other code is not a delegation and returns `null`.
pub fn decodeDelegation(code: []const u8) DecodeError!?Address {
    if (code.len < 2 or code[0] != 0xef or code[1] != 0x01) return null;
    if (code.len != delegation_code_len) return error.InvalidDelegationLength;
    if (code[2] != delegation_designator[2]) return error.UnsupportedDelegationVersion;

    var target: Address = undefined;
    @memcpy(&target, code[delegation_designator.len..]);
    return target;
}

/// Permissive runtime classifier: malformed delegation-shaped bytes are not a
/// usable delegation target.
pub fn delegationTarget(code: []const u8) ?Address {
    return decodeDelegation(code) catch null;
}

pub fn writeDelegationCode(buffer: *[delegation_code_len]u8, target: Address) void {
    @memcpy(buffer[0..delegation_designator.len], &delegation_designator);
    @memcpy(buffer[delegation_designator.len..], &target);
}

test "delegation codec distinguishes valid, malformed, and unrelated code" {
    const target = address.addr(0x1234);
    var code: [delegation_code_len]u8 = undefined;
    writeDelegationCode(&code, target);
    try std.testing.expectEqual(target, (try decodeDelegation(&code)).?);
    try std.testing.expectEqual(target, delegationTarget(&code).?);
    try std.testing.expectError(error.InvalidDelegationLength, decodeDelegation(code[0 .. code.len - 1]));
    try std.testing.expectEqual(@as(?Address, null), try decodeDelegation(&.{ 0x60, 0x00 }));
}
