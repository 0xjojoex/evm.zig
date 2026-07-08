const std = @import("std");
const address = @import("../address.zig");
const params = @import("../eth/eip/7702.zig");

pub const Address = address.Address;
pub const delegation_designator = params.delegation_designator;
pub const delegation_code_len = params.delegation_code_len;

const secp256k1n = 0xfffffffffffffffffffffffffffffffebaaedce6af48a03bbfd25e8cd0364141;
const secp256k1_half_n = secp256k1n / 2;

pub fn delegationTarget(code: []const u8) ?Address {
    if (code.len != delegation_code_len) return null;
    if (!std.mem.eql(u8, code[0..delegation_designator.len], &delegation_designator)) return null;
    var target: Address = undefined;
    @memcpy(&target, code[delegation_designator.len..]);
    return target;
}

pub fn writeDelegationCode(buffer: *[delegation_code_len]u8, target: Address) void {
    @memcpy(buffer[0..delegation_designator.len], &delegation_designator);
    @memcpy(buffer[delegation_designator.len..], &target);
}

pub fn authorizationSignatureShapeValid(y_parity: u256, legacy_v: ?u256, r: u256, s: u256) bool {
    if (y_parity > 1) return false;
    if (legacy_v) |v| {
        if (v > 1) return false;
    }
    return r > 0 and r < secp256k1n and s > 0 and s <= secp256k1_half_n;
}

pub fn authorizationSignatureSTooHigh(s: u256) bool {
    return s > secp256k1_half_n;
}

test "delegation code round-trips target" {
    const target = address.addr(0x1234);
    var code: [delegation_code_len]u8 = undefined;
    writeDelegationCode(&code, target);
    try std.testing.expectEqual(target, delegationTarget(&code).?);
    try std.testing.expectEqual(null, delegationTarget(code[0 .. code.len - 1]));
}

test "authorization signature shape rejects invalid scalar ranges" {
    try std.testing.expect(authorizationSignatureShapeValid(0, null, 1, 1));
    try std.testing.expect(!authorizationSignatureShapeValid(2, null, 1, 1));
    try std.testing.expect(!authorizationSignatureShapeValid(0, 2, 1, 1));
    try std.testing.expect(!authorizationSignatureShapeValid(0, null, 0, 1));
    try std.testing.expect(!authorizationSignatureShapeValid(0, null, 1, 0));
    try std.testing.expect(authorizationSignatureSTooHigh(secp256k1_half_n + 1));
}
