//! Direct bindings to upstream bitcoin-core/libsecp256k1, plus the encoding
//! conversions every caller needs. Native profile only: the sources compile
//! into the consuming module (see `addNativeSecp256k1` in build.zig), so the
//! hidden upstream symbols resolve within the same link.
//!
//! Public keys cross into Zig as the 64-byte uncompressed `x || y` form (a
//! devp2p node id, or the pre-image whose keccak tail is an address).

pub const c = @cImport({
    @cInclude("secp256k1.h");
    @cInclude("secp256k1_ecdh.h");
    @cInclude("secp256k1_preallocated.h");
    @cInclude("secp256k1_recovery.h");
});

pub const Context = c.secp256k1_context;
pub const PublicKey = c.secp256k1_pubkey;

/// Upstream requires the self test before the first static-context use; it is
/// cheap and idempotent, so recovery paths call it unconditionally.
pub fn staticContext() *const Context {
    c.secp256k1_selftest();
    // translate-c types the extern pointer as optional; upstream defines it.
    return c.secp256k1_context_static.?;
}

/// Parses `x || y` by restoring the SEC1 `0x04` prefix. Null when the point
/// is not on the curve.
pub fn parsePublicKey(ctx: *const Context, xy: *const [64]u8) ?PublicKey {
    var serialized: [65]u8 = undefined;
    serialized[0] = 0x04;
    @memcpy(serialized[1..], xy);
    var key: PublicKey = undefined;
    if (c.secp256k1_ec_pubkey_parse(ctx, &key, &serialized, serialized.len) != 1) return null;
    return key;
}

/// Serializes uncompressed and strips the SEC1 `0x04` prefix.
pub fn serializePublicKey(ctx: *const Context, key: *const PublicKey) ?[64]u8 {
    var serialized: [65]u8 = undefined;
    var len: usize = serialized.len;
    if (c.secp256k1_ec_pubkey_serialize(ctx, &serialized, &len, key, c.SECP256K1_EC_UNCOMPRESSED) != 1) return null;
    if (len != serialized.len or serialized[0] != 0x04) return null;
    return serialized[1..].*;
}

/// ECDH hash function that keeps the raw shared x coordinate, as ECIES
/// consumes it. Upstream's default would SHA-256 the compressed point.
pub fn ecdhCopyX(output: [*c]u8, x32: [*c]const u8, y32: [*c]const u8, data: ?*anyopaque) callconv(.c) c_int {
    _ = y32;
    _ = data;
    @memcpy(output[0..32], x32[0..32]);
    return 1;
}

/// The EVM's ecrecover: recovery ids 0 and 1 only, any malformed input is
/// null, and the static context means no allocation on the hot path.
pub fn ecrecover(message_hash: *const [32]u8, r: *const [32]u8, s: *const [32]u8, recovery_id: u8) ?[64]u8 {
    if (recovery_id > 1) return null;
    const ctx = staticContext();

    var compact: [64]u8 = undefined;
    @memcpy(compact[0..32], r);
    @memcpy(compact[32..], s);
    var signature: c.secp256k1_ecdsa_recoverable_signature = undefined;
    if (c.secp256k1_ecdsa_recoverable_signature_parse_compact(ctx, &signature, &compact, recovery_id) != 1) return null;

    var key: PublicKey = undefined;
    if (c.secp256k1_ecdsa_recover(ctx, &key, &signature, message_hash) != 1) return null;
    return serializePublicKey(ctx, &key);
}
