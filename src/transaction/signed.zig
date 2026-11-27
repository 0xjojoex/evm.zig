//! Signed EIP-2718 transaction envelopes: every field a transaction commits to,
//! signatures included, with canonical encoding and decoding.
//!
//! `transaction.raw` decodes an envelope into the engine's `Transaction`, which
//! keeps only what execution needs: it drops signatures, reduces legacy `v` to a
//! chain id, and drops authorization tuples whose signer does not recover. This
//! module keeps the whole signed form, so a value decoded here re-encodes to the
//! same bytes, and a value built from another source (an RPC response, a block
//! builder) encodes to the bytes whose keccak is the transaction hash and which
//! `eth.trie.transactionRoot` commits to.
//!
//! Each struct below is the field list of its kind in wire order; the RLP codec
//! derives both directions from it. Encoding and decoding are structural only:
//! signature validity and sender recovery belong to `transaction.signing`.
//!
//! Experimental: outside the compatibility surface until it is promoted.

const std = @import("std");
const rlp = @import("rlp");

const Address = @import("../address.zig").Address;
const envelope = @import("./envelope.zig");
const tx = @import("./types.zig");
const type_id = @import("./type_id.zig");
const uint256 = @import("../uint256.zig");

const AccessListEntry = tx.AccessListEntry;
const assert = std.debug.assert;

pub const EncodeError = rlp.EncodeError;
pub const DecodeError = rlp.DecodeError || std.mem.Allocator.Error || error{
    EmptyTransaction,
    InvalidTransactionEnvelope,
    UnsupportedTransactionType,
};

/// A 32-byte word (storage key or blob versioned hash) held as `u256`.
const Word = rlp.Mapped(u256, rlp.FixedBytes(32), struct {
    pub fn toWire(word: u256) [32]u8 {
        return uint256.toBytes32(word);
    }

    pub fn fromWire(bytes: [32]u8) u256 {
        return uint256.fromBytes32(&bytes);
    }
});

const AccessList = rlp.ListOf(rlp.Struct(AccessListEntry, .{
    .storage_keys = rlp.ListOf(Word),
}));

/// Legacy transaction. `v` is stored as encoded: `27 + y_parity` when
/// unprotected, `chain_id * 2 + 35 + y_parity` under EIP-155.
pub const Legacy = struct {
    nonce: u64,
    gas_price: u256,
    gas_limit: u64,
    to: ?Address,
    value: u256,
    input: []const u8,
    v: u256,
    r: u256,
    s: u256,
};

/// EIP-2930 transaction, type 1.
pub const AccessListTransaction = struct {
    chain_id: u256,
    nonce: u64,
    gas_price: u256,
    gas_limit: u64,
    to: ?Address,
    value: u256,
    input: []const u8,
    access_list: []const AccessListEntry,
    y_parity: u8,
    r: u256,
    s: u256,

    pub const Rlp = rlp.Struct(@This(), .{ .access_list = AccessList });
};

/// EIP-1559 transaction, type 2.
pub const DynamicFee = struct {
    chain_id: u256,
    nonce: u64,
    max_priority_fee_per_gas: u256,
    max_fee_per_gas: u256,
    gas_limit: u64,
    to: ?Address,
    value: u256,
    input: []const u8,
    access_list: []const AccessListEntry,
    y_parity: u8,
    r: u256,
    s: u256,

    pub const Rlp = rlp.Struct(@This(), .{ .access_list = AccessList });
};

/// EIP-4844 transaction, type 3, in its block form: no blobs, commitments or
/// proofs.
pub const Blob = struct {
    chain_id: u256,
    nonce: u64,
    max_priority_fee_per_gas: u256,
    max_fee_per_gas: u256,
    gas_limit: u64,
    to: Address,
    value: u256,
    input: []const u8,
    access_list: []const AccessListEntry,
    max_fee_per_blob_gas: u256,
    blob_hashes: []const u256,
    y_parity: u8,
    r: u256,
    s: u256,

    pub const Rlp = rlp.Struct(@This(), .{
        .access_list = AccessList,
        .blob_hashes = rlp.ListOf(Word),
    });
};

/// One signed EIP-7702 authorization tuple, kept whether or not its signature
/// recovers.
pub const Authorization = struct {
    chain_id: u256,
    address: Address,
    nonce: u64,
    y_parity: u8,
    r: u256,
    s: u256,
};

/// EIP-7702 transaction, type 4.
pub const SetCode = struct {
    chain_id: u256,
    nonce: u64,
    max_priority_fee_per_gas: u256,
    max_fee_per_gas: u256,
    gas_limit: u64,
    to: Address,
    value: u256,
    input: []const u8,
    access_list: []const AccessListEntry,
    authorization_list: []const Authorization,
    y_parity: u8,
    r: u256,
    s: u256,

    pub const Rlp = rlp.Struct(@This(), .{ .access_list = AccessList });
};

/// A signed transaction of any kind. Slices are borrowed when encoding; after
/// `decodeAlloc` they are owned by the value, except `input`, which borrows
/// the decoded bytes.
pub const Envelope = union(tx.TxKind) {
    legacy: Legacy,
    access_list: AccessListTransaction,
    dynamic_fee: DynamicFee,
    blob: Blob,
    set_code: SetCode,

    /// The EIP-2718 type byte, or null for a legacy transaction.
    pub fn typeId(self: Envelope) ?u8 {
        return switch (self) {
            .legacy => null,
            .access_list => type_id.access_list,
            .dynamic_fee => type_id.dynamic_fee,
            .blob => type_id.blob,
            .set_code => type_id.set_code,
        };
    }

    pub fn encodedLen(self: Envelope) EncodeError!usize {
        const prefix_len: usize = if (self.typeId() == null) 0 else 1;
        const body_len = switch (self) {
            inline else => |body| try rlp.encodedLen(@TypeOf(body), body),
        };
        return std.math.add(usize, prefix_len, body_len) catch error.EncodedLengthOverflow;
    }

    /// Write the canonical envelope into `out` and return the written prefix.
    pub fn encode(self: Envelope, out: []u8) EncodeError![]const u8 {
        const len = try self.encodedLen();
        if (out.len < len) return error.BufferTooSmall;
        var offset: usize = 0;
        if (self.typeId()) |id| {
            out[0] = id;
            offset = 1;
        }
        const body = switch (self) {
            inline else => |value| try rlp.encode(@TypeOf(value), out[offset..len], value),
        };
        assert(offset + body.len == len);
        return out[0..len];
    }

    /// Encode with exactly one allocation; the caller owns the result.
    pub fn encodeAlloc(
        self: Envelope,
        allocator: std.mem.Allocator,
    ) (EncodeError || std.mem.Allocator.Error)![]u8 {
        const out = try allocator.alloc(u8, try self.encodedLen());
        errdefer allocator.free(out);
        _ = try self.encode(out);
        return out;
    }

    /// Decode one canonical envelope. Lists are allocated with `allocator`
    /// and released by `deinit`; `input` borrows `bytes`.
    pub fn decodeAlloc(allocator: std.mem.Allocator, bytes: []const u8) DecodeError!Envelope {
        return switch (try envelope.decodeEnvelope(bytes)) {
            .legacy => |legacy| .{ .legacy = try rlp.decodeAlloc(Legacy, allocator, legacy) },
            .typed => |typed| switch (typed.type_id) {
                type_id.access_list => .{
                    .access_list = try rlp.decodeAlloc(AccessListTransaction, allocator, typed.payload),
                },
                type_id.dynamic_fee => .{
                    .dynamic_fee = try rlp.decodeAlloc(DynamicFee, allocator, typed.payload),
                },
                type_id.blob => .{ .blob = try rlp.decodeAlloc(Blob, allocator, typed.payload) },
                type_id.set_code => .{
                    .set_code = try rlp.decodeAlloc(SetCode, allocator, typed.payload),
                },
                else => error.UnsupportedTransactionType,
            },
        };
    }

    /// Release a value returned by `decodeAlloc`.
    pub fn deinit(self: *Envelope, allocator: std.mem.Allocator) void {
        switch (self.*) {
            inline else => |*body| rlp.deinit(@TypeOf(body.*), allocator, body),
        }
        self.* = undefined;
    }
};

const testing = std.testing;
const crypto = @import("../crypto.zig");
const eip7702 = @import("../executor/eip7702.zig");
const raw = @import("./raw.zig");
const signing = @import("./signing.zig");
const t = @import("../t.zig");

const TestSigner = struct {
    const Scheme = std.crypto.sign.ecdsa.EcdsaSecp256k1Sha256;

    key_pair: Scheme.KeyPair,
    address: Address,

    fn init(seed: u8) !TestSigner {
        const secret = try Scheme.SecretKey.fromBytes(@splat(seed));
        const key_pair = try Scheme.KeyPair.fromSecretKey(secret);
        const sec1 = key_pair.public_key.toUncompressedSec1();
        return .{ .key_pair = key_pair, .address = Address.fromPublicKey(sec1[1..65].*) };
    }

    const Signature = struct { y_parity: u8, r: u256, s: u256 };

    /// Sign a prehashed message with low s, and find the parity that recovers
    /// this signer.
    fn sign(self: TestSigner, message_hash: [32]u8) !Signature {
        const bytes = (try self.key_pair.signPrehashed(message_hash, null)).toBytes();
        const r = uint256.fromBytes32(bytes[0..32]);
        var s = uint256.fromBytes32(bytes[32..64]);
        if (s > eip7702.secp256k1_half_n) s = eip7702.secp256k1n - s;
        for ([_]u8{ 0, 1 }) |y_parity| {
            const public_key = crypto.ecrecoverPublicKey(
                message_hash,
                uint256.toBytes32(r),
                uint256.toBytes32(s),
                y_parity,
            ) orelse continue;
            if (Address.fromPublicKey(public_key).eql(self.address))
                return .{ .y_parity = y_parity, .r = r, .s = s };
        }
        return error.InvalidSignature;
    }

    /// Sign `value` in place. The signing hash comes from `transaction.signing`,
    /// so this checks that the encoder writes the layout the signer reads.
    fn signEnvelope(self: TestSigner, value: *Envelope) !void {
        const unsigned = try value.encodeAlloc(testing.allocator);
        defer testing.allocator.free(unsigned);
        const signature = try self.sign(try signing.signingHash(testing.allocator, unsigned));
        switch (value.*) {
            .legacy => |*legacy| {
                const base: u256 = if (legacy.v >= 35) (legacy.v - 35) / 2 * 2 + 35 else 27;
                legacy.v = base + signature.y_parity;
                legacy.r = signature.r;
                legacy.s = signature.s;
            },
            inline else => |*typed| {
                typed.y_parity = signature.y_parity;
                typed.r = signature.r;
                typed.s = signature.s;
            },
        }
    }

    fn authorize(self: TestSigner, chain_id: u256, target: Address, nonce: u64) !Authorization {
        const Fields = struct { chain_id: u256, address: Address, nonce: u64 };
        var message: [128]u8 = undefined;
        message[0] = 0x05;
        const fields = try rlp.encode(Fields, message[1..], Fields{
            .chain_id = chain_id,
            .address = target,
            .nonce = nonce,
        });
        const signature = try self.sign(crypto.keccak256(message[0 .. 1 + fields.len]));
        return .{
            .chain_id = chain_id,
            .address = target,
            .nonce = nonce,
            .y_parity = signature.y_parity,
            .r = signature.r,
            .s = signature.s,
        };
    }
};

/// Encode `value`, then check that the production decoder reads back the same
/// transaction and sender, and that the signed decoder reproduces the bytes.
fn expectRoundTrip(value: Envelope, sender: Address) !void {
    const allocator = testing.allocator;
    const encoded = try value.encodeAlloc(allocator);
    defer allocator.free(encoded);
    try testing.expectEqual(encoded.len, try value.encodedLen());
    try testing.expectEqual(value.typeId(), if (encoded[0] < 0x80) encoded[0] else null);

    var decoded = try raw.decodeRaw(allocator, encoded);
    defer decoded.deinit(allocator);
    try expectProjection(value, decoded.tx, sender);

    var again = try Envelope.decodeAlloc(allocator, encoded);
    defer again.deinit(allocator);
    try testing.expectEqual(std.meta.activeTag(value), std.meta.activeTag(again));
    const reencoded = try again.encodeAlloc(allocator);
    defer allocator.free(reencoded);
    try testing.expectEqualSlices(u8, encoded, reencoded);
}

fn expectProjection(value: Envelope, actual: tx.Transaction, sender: Address) !void {
    try testing.expectEqual(std.meta.activeTag(value), actual.kind);
    try testing.expectEqual(sender, actual.sender);
    switch (value) {
        inline else => |body| {
            try testing.expectEqual(@as(u256, body.nonce), actual.nonce.?);
            try testing.expectEqual(body.gas_limit, actual.gas_limit);
            try testing.expectEqual(@as(?Address, body.to), actual.to);
            try testing.expectEqual(body.value, actual.value);
            try testing.expectEqualSlices(u8, body.input, actual.input);
            if (@hasField(@TypeOf(body), "chain_id"))
                try testing.expectEqual(@as(?u256, body.chain_id), actual.chain_id);
            if (@hasField(@TypeOf(body), "gas_price"))
                try testing.expectEqual(body.gas_price, actual.gas_price);
            if (@hasField(@TypeOf(body), "max_fee_per_gas")) {
                try testing.expectEqual(body.max_fee_per_gas, actual.max_fee_per_gas.?);
                try testing.expectEqual(
                    body.max_priority_fee_per_gas,
                    actual.max_priority_fee_per_gas.?,
                );
            }
            if (@hasField(@TypeOf(body), "access_list")) {
                try testing.expectEqual(body.access_list.len, actual.access_list.len);
                for (body.access_list, actual.access_list) |expected, entry| {
                    try testing.expectEqual(expected.address, entry.address);
                    try testing.expectEqualSlices(u256, expected.storage_keys, entry.storage_keys);
                }
            }
            if (@hasField(@TypeOf(body), "blob_hashes")) {
                try testing.expectEqual(body.max_fee_per_blob_gas, actual.max_fee_per_blob_gas.?);
                try testing.expectEqualSlices(u256, body.blob_hashes, actual.blob_hashes);
            }
        },
    }
}

const test_to = Address.fromBytes(@splat(0x35));
const test_input = [_]u8{ 0x00, 0x60, 0x01, 0xff };
// Keys with leading zero bytes: a word encoded as an integer would lose them.
const test_keys = [_]u256{ 0x01, @as(u256, 0xab) << 248 };
const test_access_list = [_]AccessListEntry{
    .{ .address = Address.fromBytes(@splat(0x11)), .storage_keys = &test_keys },
    .{ .address = Address.fromBytes(@splat(0x12)) },
};

test "legacy envelopes round-trip with unprotected and EIP-155 v" {
    const signer = try TestSigner.init(0x11);
    for ([_]u256{ 27, 1 * 2 + 35, 1337 * 2 + 35 }) |v| {
        var value: Envelope = .{ .legacy = .{
            .nonce = 9,
            .gas_price = 20_000_000_000,
            .gas_limit = 21_000,
            .to = test_to,
            .value = 1_000_000_000_000_000_000,
            .input = &test_input,
            .v = v,
            .r = 1,
            .s = 1,
        } };
        try signer.signEnvelope(&value);
        try expectRoundTrip(value, signer.address);

        value.legacy.to = null;
        try signer.signEnvelope(&value);
        try expectRoundTrip(value, signer.address);
    }
}

test "typed envelopes round-trip through the production decoder" {
    const signer = try TestSigner.init(0x22);
    const blob_hashes = [_]u256{ (@as(u256, 0x01) << 248) | 0x07, 0x02 };
    const values = [_]Envelope{
        .{ .access_list = .{
            .chain_id = 1,
            .nonce = 3,
            .gas_price = 7,
            .gas_limit = 50_000,
            .to = null,
            .value = 5,
            .input = &test_input,
            .access_list = &test_access_list,
            .y_parity = 0,
            .r = 1,
            .s = 1,
        } },
        .{ .dynamic_fee = .{
            .chain_id = 1,
            .nonce = 4,
            .max_priority_fee_per_gas = 2,
            .max_fee_per_gas = 1_000_000_007,
            .gas_limit = 60_000,
            .to = test_to,
            .value = 0,
            .input = &.{},
            .access_list = &test_access_list,
            .y_parity = 0,
            .r = 1,
            .s = 1,
        } },
        .{ .blob = .{
            .chain_id = 1,
            .nonce = std.math.maxInt(u64) - 1,
            .max_priority_fee_per_gas = 3,
            .max_fee_per_gas = 11,
            .gas_limit = 70_000,
            .to = test_to,
            .value = 1,
            .input = &test_input,
            .access_list = &.{},
            .max_fee_per_blob_gas = 13,
            .blob_hashes = &blob_hashes,
            .y_parity = 0,
            .r = 1,
            .s = 1,
        } },
    };
    for (values) |template| {
        var value = template;
        try signer.signEnvelope(&value);
        try expectRoundTrip(value, signer.address);
    }
}

test "set-code envelopes keep every authorization signature" {
    const allocator = testing.allocator;
    const sender = try TestSigner.init(0x33);
    const authority = try TestSigner.init(0x44);
    const delegate = Address.fromBytes(@splat(0x77));
    const valid = try authority.authorize(1, delegate, 5);
    // Out-of-range s: the execution decoder drops this tuple, the signed form
    // keeps it.
    var invalid = valid;
    invalid.s = eip7702.secp256k1n - 1;
    const authorizations = [_]Authorization{ valid, invalid };

    var value: Envelope = .{ .set_code = .{
        .chain_id = 1,
        .nonce = 6,
        .max_priority_fee_per_gas = 2,
        .max_fee_per_gas = 9,
        .gas_limit = 100_000,
        .to = test_to,
        .value = 0,
        .input = &test_input,
        .access_list = &test_access_list,
        .authorization_list = &authorizations,
        .y_parity = 0,
        .r = 1,
        .s = 1,
    } };
    try sender.signEnvelope(&value);
    try expectRoundTrip(value, sender.address);

    const encoded = try value.encodeAlloc(allocator);
    defer allocator.free(encoded);
    var decoded = try raw.decodeRaw(allocator, encoded);
    defer decoded.deinit(allocator);
    try testing.expectEqual(@as(usize, 2), decoded.tx.authorization_count.?);
    try testing.expectEqual(@as(usize, 1), decoded.tx.authorization_list.len);
    try testing.expectEqual(authority.address, decoded.tx.authorization_list[0].signer);
    try testing.expectEqual(delegate, decoded.tx.authorization_list[0].target);

    var signed = try Envelope.decodeAlloc(allocator, encoded);
    defer signed.deinit(allocator);
    try testing.expectEqualSlices(Authorization, &authorizations, signed.set_code.authorization_list);
}

test "signed decoder reproduces the EIP-155 example transaction" {
    const allocator = testing.allocator;
    const hex = "f86c098504a817c800825208943535353535353535353535353535353535353535880de0b6b3a76400008025a028ef61340bd939bc2195fe537567866003e1a15d3c71ff63e1590620aa636276a067cbe9d8997f761aecb703304b3800ccf555c9f3dc64214b297fb1966a3b6d83";
    var bytes: [hex.len / 2]u8 = undefined;
    _ = try std.fmt.hexToBytes(&bytes, hex);

    var value = try Envelope.decodeAlloc(allocator, &bytes);
    defer value.deinit(allocator);
    try testing.expectEqual(@as(u256, 37), value.legacy.v);
    try testing.expectEqual(
        @as(u256, 0x28ef61340bd939bc2195fe537567866003e1a15d3c71ff63e1590620aa636276),
        value.legacy.r,
    );
    var out: [bytes.len]u8 = undefined;
    try testing.expectEqualSlices(u8, &bytes, try value.encode(&out));
    try testing.expectError(error.BufferTooSmall, value.encode(out[0 .. out.len - 1]));
    try t.expectHex(
        (try signing.recoverSender(allocator, &out)).sender.asBytes(),
        "9d8a62f656a8d1615c1294fd71e9cfb3e4855a4f",
    );
}

test "signed decoder rejects unknown types and a typed create" {
    const allocator = testing.allocator;
    try testing.expectError(
        error.UnsupportedTransactionType,
        Envelope.decodeAlloc(allocator, &.{ 0x05, 0xc0 }),
    );
    try testing.expectError(error.EmptyTransaction, Envelope.decodeAlloc(allocator, &.{}));

    // A set-code transaction with an empty `to` is not representable.
    const value: Envelope = .{ .dynamic_fee = .{
        .chain_id = 1,
        .nonce = 0,
        .max_priority_fee_per_gas = 0,
        .max_fee_per_gas = 0,
        .gas_limit = 0,
        .to = null,
        .value = 0,
        .input = &.{},
        .access_list = &.{},
        .y_parity = 0,
        .r = 1,
        .s = 1,
    } };
    const encoded = try value.encodeAlloc(allocator);
    defer allocator.free(encoded);
    encoded[0] = type_id.set_code;
    try testing.expectError(error.UnexpectedLength, Envelope.decodeAlloc(allocator, encoded));
}
