//! BLS signature verification over BLS12-381 as the consensus layer uses it:
//! public keys in G1 (48 bytes compressed), signatures in G2 (96 bytes), the
//! proof-of-possession ciphersuite. Bound directly to blst, the library the
//! EIP-2537 precompiles already link. Native profile only.
//!
//! Three pieces make the consensus layer's `FastAggregateVerify`: validate
//! each key once with `PublicKey.fromCompressed`, sum the signers' keys with
//! `Aggregate`, then `verify` the signature against the sum. Keeping
//! validated keys lets a caller that checks many signatures from one key set
//! (a sync committee signs every slot of a period) decompress each key once.

const std = @import("std");
const c = @import("precompile_c");

/// The ciphersuite of every consensus-layer signature.
pub const dst = "BLS_SIG_BLS12381G2_XMD:SHA-256_SSWU_RO_POP_";

/// A public key that passed `KeyValidate`: on the curve, in the G1 subgroup,
/// not the point at infinity.
pub const PublicKey = struct {
    point: c.blst_p1_affine,

    pub fn fromCompressed(bytes: *const [48]u8) error{InvalidPublicKey}!PublicKey {
        var key: PublicKey = undefined;
        const status = c.blst_p1_uncompress(&key.point, bytes);
        if (status != c.BLST_SUCCESS) return error.InvalidPublicKey;
        if (c.blst_p1_affine_is_inf(&key.point)) return error.InvalidPublicKey;
        if (!c.blst_p1_affine_in_g1(&key.point)) return error.InvalidPublicKey;
        return key;
    }
};

/// A running sum of public keys, `AggregatePKs` of the consensus specs.
pub const Aggregate = struct {
    /// Jacobian; all zero is the point at infinity, the empty sum.
    sum: c.blst_p1,

    pub const empty: Aggregate = .{ .sum = std.mem.zeroes(c.blst_p1) };

    pub fn add(aggregate: *Aggregate, key: *const PublicKey) void {
        c.blst_p1_add_or_double_affine(&aggregate.sum, &aggregate.sum, &key.point);
    }

    /// The sum as a key, or null for the point at infinity (no keys added, or
    /// keys that cancel), which no signature verifies against.
    pub fn finish(aggregate: *const Aggregate) ?PublicKey {
        var key: PublicKey = undefined;
        c.blst_p1_to_affine(&key.point, &aggregate.sum);
        if (c.blst_p1_affine_is_inf(&key.point)) return null;
        return key;
    }
};

/// `CoreVerify` with the proof-of-possession ciphersuite: `signature` is a
/// valid G2 point in the subgroup and signs `message` under `key`.
pub fn verify(key: *const PublicKey, message: []const u8, signature: *const [96]u8) bool {
    var point: c.blst_p2_affine = undefined;
    if (c.blst_p2_uncompress(&point, signature) != c.BLST_SUCCESS) return false;
    // Checks the signature's subgroup; skips an infinite signature, which then
    // fails the pairing against a key that is not infinity.
    return c.blst_core_verify_pk_in_g1(
        &key.point,
        &point,
        true,
        message.ptr,
        message.len,
        dst,
        dst.len,
        null,
        0,
    ) == c.BLST_SUCCESS;
}

const testing = std.testing;

const Vectors = std.json.ArrayHashMap(struct {
    input: std.json.Value,
    output: ?bool,
});

fn parseVectors(comptime name: []const u8) !std.json.Parsed(Vectors) {
    const json = @embedFile("../test/fixtures/bls/" ++ name ++ ".json");
    return std.json.parseFromSlice(Vectors, testing.allocator, json, .{});
}

/// Hex with or without `0x`, of exactly `N` bytes; null for any other length.
fn hexBytes(comptime N: usize, value: std.json.Value) ?[N]u8 {
    const text = value.string;
    const digits = if (std.mem.startsWith(u8, text, "0x")) text[2..] else text;
    if (digits.len != 2 * N) return null;
    var out: [N]u8 = undefined;
    _ = std.fmt.hexToBytes(&out, digits) catch return null;
    return out;
}

fn hexAlloc(value: std.json.Value) ![]u8 {
    const digits = value.string[2..];
    const out = try testing.allocator.alloc(u8, digits.len / 2);
    _ = try std.fmt.hexToBytes(out, digits);
    return out;
}

// Vectors from ethereum/bls12-381-tests v0.1.2 (`bls_tests_json.tar.gz`), the
// consensus specs' BLS tests, one JSON object per directory.

test "fromCompressed is deserialization plus KeyValidate" {
    var parsed = try parseVectors("deserialization_G1");
    defer parsed.deinit();
    for (parsed.value.map.keys(), parsed.value.map.values()) |name, case| {
        // The infinity encoding deserializes, but KeyValidate refuses the point.
        const infinity = std.mem.endsWith(u8, name, "succeeds_infinity_with_true_b_flag");
        const expected = case.output.? and !infinity;
        const bytes = hexBytes(48, case.input.object.get("pubkey").?) orelse {
            try testing.expect(!expected);
            continue;
        };
        const valid = if (PublicKey.fromCompressed(&bytes)) |_| true else |_| false;
        testing.expectEqual(expected, valid) catch |err| {
            std.debug.print("vector {s}\n", .{name});
            return err;
        };
    }
    try testing.expectEqual(@as(usize, 13), parsed.value.map.count());
}

test "verify matches the consensus spec vectors" {
    var parsed = try parseVectors("verify");
    defer parsed.deinit();
    for (parsed.value.map.keys(), parsed.value.map.values()) |name, case| {
        const input = case.input.object;
        const message = try hexAlloc(input.get("message").?);
        defer testing.allocator.free(message);
        const signature = hexBytes(96, input.get("signature").?).?;
        const valid = if (PublicKey.fromCompressed(&hexBytes(48, input.get("pubkey").?).?)) |key|
            verify(&key, message, &signature)
        else |_|
            false;
        testing.expectEqual(case.output.?, valid) catch |err| {
            std.debug.print("vector {s}\n", .{name});
            return err;
        };
    }
    try testing.expectEqual(@as(usize, 29), parsed.value.map.count());
}

/// `FastAggregateVerify` composed as a caller does it.
fn fastAggregateVerify(
    pubkeys: []const std.json.Value,
    message: []const u8,
    signature: *const [96]u8,
) bool {
    var aggregate: Aggregate = .empty;
    for (pubkeys) |pubkey| {
        const bytes = hexBytes(48, pubkey) orelse return false;
        aggregate.add(&(PublicKey.fromCompressed(&bytes) catch return false));
    }
    const key = aggregate.finish() orelse return false;
    return verify(&key, message, signature);
}

test "Aggregate and verify make FastAggregateVerify" {
    var parsed = try parseVectors("fast_aggregate_verify");
    defer parsed.deinit();
    for (parsed.value.map.keys(), parsed.value.map.values()) |name, case| {
        const input = case.input.object;
        const message = try hexAlloc(input.get("message").?);
        defer testing.allocator.free(message);
        const signature = hexBytes(96, input.get("signature").?).?;
        const pubkeys = input.get("pubkeys").?.array.items;
        const valid = fastAggregateVerify(pubkeys, message, &signature);
        testing.expectEqual(case.output.?, valid) catch |err| {
            std.debug.print("vector {s}\n", .{name});
            return err;
        };
    }
    try testing.expectEqual(@as(usize, 12), parsed.value.map.count());
}

test "keys that cancel sum to no key" {
    var parsed = try parseVectors("verify");
    defer parsed.deinit();
    const case = parsed.value.map.get("verify_valid_case_195246ee3bd3b6ec").?;
    var bytes = hexBytes(48, case.input.object.get("pubkey").?).?;
    const key = try PublicKey.fromCompressed(&bytes);
    // Flipping the sign bit of a compressed point gives its negation.
    bytes[0] ^= 0x20;
    const negated = try PublicKey.fromCompressed(&bytes);

    var aggregate: Aggregate = .empty;
    try testing.expectEqual(@as(?PublicKey, null), aggregate.finish());
    aggregate.add(&key);
    try testing.expect(aggregate.finish() != null);
    aggregate.add(&negated);
    try testing.expectEqual(@as(?PublicKey, null), aggregate.finish());
}
