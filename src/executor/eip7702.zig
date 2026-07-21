//! EIP-7702 runtime helpers and authorization-signature validation.
//!
//! This is the *behavior* half of EIP-7702, distinct from `eth/eip/7702.zig`,
//! which owns the *parameter table* (magic byte, gas costs, prefix, lengths).
//! The neutral delegation codec lives under `code/`; signature behavior stays
//! here in the executor layer.
const std = @import("std");
const address = @import("../address.zig");
const delegation = @import("../code/eip7702.zig");

const Address = address.Address;
/// Delegation indicator prefix (`0xef0100`); re-exported from the eth table.
pub const delegation_designator = delegation.delegation_designator;
/// Byte length of a full delegation indicator; re-exported from the eth table.
pub const delegation_code_len = delegation.delegation_code_len;

/// secp256k1 group order `n`; upper bound for a valid signature `r`/`s` scalar.
pub const secp256k1n = 0xfffffffffffffffffffffffffffffffebaaedce6af48a03bbfd25e8cd0364141;
/// `n / 2`; EIP-2 low-`s` bound rejecting malleable signatures.
pub const secp256k1_half_n = secp256k1n / 2;

pub const delegationTarget = delegation.delegationTarget;
pub const writeDelegationCode = delegation.writeDelegationCode;

/// Validate the scalar ranges of an authorization-tuple signature.
///
/// Enforces `y_parity` (and any `legacy_v`) is 0/1, `r`/`s` are non-zero, and
/// both stay below the curve order with `s` under the EIP-2 low-`s` bound.
/// Returns false for any out-of-range field; it does not recover the signer.
pub fn authorizationSignatureShapeValid(y_parity: u256, legacy_v: ?u256, r: u256, s: u256) bool {
    if (y_parity > 1) return false;
    if (legacy_v) |v| {
        if (v > 1) return false;
    }
    return r > 0 and r < secp256k1n and s > 0 and s <= secp256k1_half_n;
}

/// Whether `s` exceeds the EIP-2 low-`s` bound (`n / 2`).
///
/// Lets callers distinguish a high-`s` rejection from other shape failures.
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
