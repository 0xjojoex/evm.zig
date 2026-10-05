//! Keys, recoverable ECDSA, and ECDH over secp256k1, bound directly to
//! bitcoin-core/libsecp256k1 through `libsecp256k1.zig`. Native profile only:
//! the zkVM profile recovers through its accelerator and never signs.
//!
//! Public keys are the 64-byte uncompressed `x || y` form: a devp2p node id, or
//! the pre-image whose keccak tail is an address. Signatures are compact
//! `r || s` plus a recovery id, and serialize to the 65-byte `r || s || v` form
//! the wire protocols carry. The EVM's own recovery path (`ecrecoverPublicKey`)
//! stays context-free in `crypto.zig`.

const std = @import("std");
const lib = @import("./libsecp256k1.zig");
const c = lib.c;

pub const SecretKey = [32]u8;
pub const PublicKey = [64]u8;
pub const MessageHash = [32]u8;
/// Raw x coordinate of the ECDH point, as ECIES feeds it into its KDF.
pub const SharedSecret = [32]u8;

pub const Signature = struct {
    /// Compact `r || s`. Signatures produced by `Context.sign` are low-s.
    rs: [64]u8,
    /// 0 or 1 in practice; libsecp256k1 reserves 2 and 3 for x >= n.
    recovery_id: u2,

    pub const encoded_length = 65;

    /// `r || s || v` with `v` the raw recovery id (0..3), as RLPx and discv4
    /// carry it. Transaction encodings add their own chain-id offset on top.
    pub fn toBytes(self: Signature) [encoded_length]u8 {
        var out: [encoded_length]u8 = undefined;
        @memcpy(out[0..64], &self.rs);
        out[64] = self.recovery_id;
        return out;
    }

    /// Checks only the recovery id; preserves `r || s` without validating or normalizing it.
    pub fn fromBytes(bytes: [encoded_length]u8) error{InvalidSignature}!Signature {
        if (bytes[64] > 3) return error.InvalidSignature;
        return .{ .rs = bytes[0..64].*, .recovery_id = @intCast(bytes[64]) };
    }
};

/// A randomized libsecp256k1 context. Create one per process (or per node
/// identity), keep it for the lifetime of the node, and share it freely: it is
/// never mutated after `init`, so concurrent use from many threads is safe.
pub const Context = struct {
    raw: *c.secp256k1_context,
    memory: Memory,
    allocator: std.mem.Allocator,

    /// Upstream wants the block "suitably aligned to hold an object of any
    /// type", i.e. `max_align_t`.
    const alignment: std.mem.Alignment = .@"16";
    const Memory = []align(alignment.toByteUnits()) u8;

    /// `seed` blinds the signing arithmetic against side channels; draw it
    /// from `Io.randomSecure`. Recovery-only callers do not need a context:
    /// see `ecrecoverPublicKey`.
    ///
    /// The context lives in `allocator` memory through upstream's preallocated
    /// API. `secp256k1_context_create` is deliberately unused: it routes its
    /// own allocation failure into upstream's error callback, which aborts.
    pub fn init(allocator: std.mem.Allocator, seed: [32]u8) std.mem.Allocator.Error!Context {
        const size = c.secp256k1_context_preallocated_size(c.SECP256K1_CONTEXT_NONE);
        const memory = try allocator.alignedAlloc(u8, alignment, size);
        errdefer allocator.free(memory);
        // Null only on an illegal argument, which upstream aborts on first.
        const raw = c.secp256k1_context_preallocated_create(memory.ptr, c.SECP256K1_CONTEXT_NONE).?;
        // Blinds the generator multiplications used by signing and ECDH.
        std.debug.assert(c.secp256k1_context_randomize(raw, &seed) == 1);
        return .{ .raw = raw, .memory = memory, .allocator = allocator };
    }

    pub fn deinit(self: Context) void {
        c.secp256k1_context_preallocated_destroy(self.raw);
        self.allocator.free(self.memory);
    }

    /// True for scalars in `[1, n)`; everything else is unusable as a key.
    pub fn isValidSecretKey(self: Context, secret: SecretKey) bool {
        return c.secp256k1_ec_seckey_verify(self.raw, &secret) == 1;
    }

    /// True when `public` is a point on the curve.
    pub fn isValidPublicKey(self: Context, public: PublicKey) bool {
        return lib.parsePublicKey(self.raw, &public) != null;
    }

    pub fn publicKey(self: Context, secret: SecretKey) error{InvalidSecretKey}!PublicKey {
        var key: lib.PublicKey = undefined;
        if (c.secp256k1_ec_pubkey_create(self.raw, &key, &secret) != 1) return error.InvalidSecretKey;
        return lib.serializePublicKey(self.raw, &key) orelse error.InvalidSecretKey;
    }

    /// Deterministic (RFC 6979), low-s recoverable signature over a 32-byte digest.
    pub fn sign(self: Context, message_hash: MessageHash, secret: SecretKey) error{InvalidSecretKey}!Signature {
        var signature: c.secp256k1_ecdsa_recoverable_signature = undefined;
        if (c.secp256k1_ecdsa_sign_recoverable(self.raw, &signature, &message_hash, &secret, null, null) != 1) {
            return error.InvalidSecretKey;
        }
        var rs: [64]u8 = undefined;
        var recovery_id: c_int = undefined;
        // Serialization of a signature we just produced cannot fail.
        std.debug.assert(c.secp256k1_ecdsa_recoverable_signature_serialize_compact(self.raw, &rs, &recovery_id, &signature) == 1);
        return .{ .rs = rs, .recovery_id = @intCast(recovery_id) };
    }

    /// The public key that produced `signature` over `message_hash`.
    pub fn recover(self: Context, message_hash: MessageHash, signature: Signature) error{InvalidSignature}!PublicKey {
        var parsed: c.secp256k1_ecdsa_recoverable_signature = undefined;
        if (c.secp256k1_ecdsa_recoverable_signature_parse_compact(self.raw, &parsed, &signature.rs, signature.recovery_id) != 1) {
            return error.InvalidSignature;
        }
        var key: lib.PublicKey = undefined;
        if (c.secp256k1_ecdsa_recover(self.raw, &key, &parsed, &message_hash) != 1) return error.InvalidSignature;
        return lib.serializePublicKey(self.raw, &key) orelse error.InvalidSignature;
    }

    /// Succeeds only for a well-formed, low-s signature by `public`.
    pub fn verify(self: Context, message_hash: MessageHash, rs: [64]u8, public: PublicKey) error{SignatureVerificationFailed}!void {
        var signature: c.secp256k1_ecdsa_signature = undefined;
        if (c.secp256k1_ecdsa_signature_parse_compact(self.raw, &signature, &rs) != 1) return error.SignatureVerificationFailed;
        const key = lib.parsePublicKey(self.raw, &public) orelse return error.SignatureVerificationFailed;
        if (c.secp256k1_ecdsa_verify(self.raw, &signature, &message_hash, &key) != 1) return error.SignatureVerificationFailed;
    }

    /// Raw ECDH: the x coordinate of `secret * public`.
    pub fn ecdh(self: Context, public: PublicKey, secret: SecretKey) error{ InvalidPublicKey, InvalidSecretKey }!SharedSecret {
        if (!self.isValidSecretKey(secret)) return error.InvalidSecretKey;
        const key = lib.parsePublicKey(self.raw, &public) orelse return error.InvalidPublicKey;
        var out: SharedSecret = undefined;
        if (c.secp256k1_ecdh(self.raw, &out, &key, &secret, lib.ecdhCopyX, null) != 1) return error.InvalidPublicKey;
        return out;
    }
};

const testing = std.testing;

fn hex(comptime s: []const u8) [s.len / 2]u8 {
    var out: [s.len / 2]u8 = undefined;
    _ = std.fmt.hexToBytes(&out, s) catch unreachable;
    return out;
}

fn testContext() !Context {
    return Context.init(testing.allocator, @as([32]u8, @splat(0x5a)));
}

test "context allocation failure is an error, not an abort" {
    try testing.expectError(error.OutOfMemory, Context.init(testing.failing_allocator, @as([32]u8, @splat(0x5a))));
}

test "secret key 1 maps to the generator" {
    const ctx = try testContext();
    defer ctx.deinit();
    var one: SecretKey = @splat(0);
    one[31] = 1;
    const generator = hex("79be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798" ++
        "483ada7726a3c4655da4fbfc0e1108a8fd17b448a68554199c47d08ffb10d4b8");
    try testing.expectEqualSlices(u8, &generator, &try ctx.publicKey(one));
    try testing.expect(ctx.isValidPublicKey(generator));
}

test "rejects zero and out-of-range secret keys" {
    const ctx = try testContext();
    defer ctx.deinit();
    const zero: SecretKey = @splat(0);
    const too_big: SecretKey = @splat(0xff);
    try testing.expect(!ctx.isValidSecretKey(zero));
    try testing.expect(!ctx.isValidSecretKey(too_big));
    try testing.expectError(error.InvalidSecretKey, ctx.publicKey(zero));
    try testing.expectError(error.InvalidSecretKey, ctx.sign(@as([32]u8, @splat(1)), too_big));
    try testing.expect(!ctx.isValidPublicKey(@as([64]u8, @splat(0))));
}

test "recovers go-ethereum's reference signature" {
    // crypto/signature_test.go in go-ethereum.
    const ctx = try testContext();
    defer ctx.deinit();
    const message_hash = hex("ce0677bb30baa8cf067c88db9811f4333d131bf8bcf12fe7065d211dce971008");
    const encoded = hex("90f27b8b488db00b00606796d2987f6a5f59ae62ea05effe84fef5b8b0e54998" ++
        "4a691139ad57a3f0b906637673aa2f63d1f55cb1a69199d4009eea23ceaddc93" ++ "01");
    const expected = hex("e32df42865e97135acfb65f3bae71bdc86f4d49150ad6a440b6f15878109880a" ++
        "0a2b2667f7e725ceea70c673093bf67663e0312623c8e091b13cf2c0f11ef652");

    const signature = try Signature.fromBytes(encoded);
    try testing.expectEqual(@as(u2, 1), signature.recovery_id);
    try testing.expectEqualSlices(u8, &expected, &try ctx.recover(message_hash, signature));
    try ctx.verify(message_hash, signature.rs, expected);
    try testing.expectEqualSlices(u8, &encoded, &signature.toBytes());

    // The other recovery id yields a different key, never this one.
    const flipped: Signature = .{ .rs = signature.rs, .recovery_id = 0 };
    const other = ctx.recover(message_hash, flipped) catch null;
    try testing.expect(other == null or !std.mem.eql(u8, &other.?, &expected));
}

test "sign, recover, verify round trip" {
    const ctx = try testContext();
    defer ctx.deinit();
    var secret: SecretKey = undefined;
    for (&secret, 0..) |*byte, i| byte.* = @truncate(i * 7 + 1);
    const public = try ctx.publicKey(secret);
    var message_hash: MessageHash = undefined;
    std.crypto.hash.sha3.Keccak256.hash("evmz", &message_hash, .{});

    const signature = try ctx.sign(message_hash, secret);
    try testing.expectEqualSlices(u8, &public, &try ctx.recover(message_hash, signature));
    try ctx.verify(message_hash, signature.rs, public);

    // RFC 6979 makes signing deterministic.
    try testing.expectEqual(signature, try ctx.sign(message_hash, secret));

    var tampered = message_hash;
    tampered[0] ^= 1;
    try testing.expectError(error.SignatureVerificationFailed, ctx.verify(tampered, signature.rs, public));
    try testing.expectError(error.InvalidSignature, Signature.fromBytes(@as([64]u8, @splat(0)) ++ [_]u8{4}));
}

test "ecdh is symmetric and rejects bad inputs" {
    const ctx = try testContext();
    defer ctx.deinit();
    const a: SecretKey = @splat(0x11);
    const b: SecretKey = @splat(0x22);
    const shared = try ctx.ecdh(try ctx.publicKey(b), a);
    try testing.expectEqualSlices(u8, &shared, &try ctx.ecdh(try ctx.publicKey(a), b));

    try testing.expectError(error.InvalidPublicKey, ctx.ecdh(@as([64]u8, @splat(0)), a));
    try testing.expectError(error.InvalidSecretKey, ctx.ecdh(try ctx.publicKey(b), @as([32]u8, @splat(0))));
}

test "decoding preserves high-s signatures for recovery but verification rejects them" {
    const ctx = try testContext();
    defer ctx.deinit();
    const secret: SecretKey = @splat(0x11);
    const public = try ctx.publicKey(secret);
    const message_hash: MessageHash = @splat(1);
    const signature = try ctx.sign(message_hash, secret);
    const order: u256 = 0xfffffffffffffffffffffffffffffffebaaedce6af48a03bbfd25e8cd0364141;
    const s = std.mem.readInt(u256, signature.rs[32..64], .big);
    try testing.expect(s > 0 and s <= order / 2);

    var high = signature;
    std.mem.writeInt(u256, high.rs[32..64], order - s, .big);
    high.recovery_id ^= 1;
    const decoded = try Signature.fromBytes(high.toBytes());
    try testing.expectEqual(high, decoded);
    try testing.expectEqualSlices(u8, &public, &try ctx.recover(message_hash, decoded));
    try testing.expectError(error.SignatureVerificationFailed, ctx.verify(message_hash, decoded.rs, public));
}
