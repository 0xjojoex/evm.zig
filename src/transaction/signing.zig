//! Transaction-specific signing-message construction and sender recovery.

const std = @import("std");
const address = @import("../address.zig");
const crypto = @import("../crypto.zig");
const eip7702 = @import("../executor/eip7702.zig");
const eip7702_params = @import("../eth/eip/7702.zig");
const envelope = @import("./envelope.zig");
const rlp = @import("../rlp.zig");
const tx_type_id = @import("./type_id.zig");
const uint256 = @import("../uint256.zig");
const t = @import("../t.zig");

const Address = address.Address;
const TypedEnvelope = envelope.TypedEnvelope;

const access_list_transaction_type = tx_type_id.access_list;
const dynamic_fee_transaction_type = tx_type_id.dynamic_fee;
const blob_transaction_type = tx_type_id.blob;
const set_code_transaction_type = tx_type_id.set_code;
pub const set_code_authorization_magic = eip7702_params.magic;
const max_rlp_u256_bytes = 1 + 32;
const max_rlp_u64_bytes = 1 + 8;
const max_rlp_address_bytes = 1 + 20;
const authorization_fields_buffer_bytes = max_rlp_u256_bytes + max_rlp_address_bytes + max_rlp_u64_bytes;
const protected_legacy_tail_buffer_bytes = max_rlp_u256_bytes + 2;

pub const SenderRecovery = struct {
    sender: Address,
    signing_hash: [32]u8,
};

pub const SenderRecoveryError = std.mem.Allocator.Error || rlp.Error || error{
    EmptyTransaction,
    InvalidTransactionEnvelope,
    InvalidTransactionFormat,
    InvalidSignature,
    UnsupportedLegacyV,
    UnsupportedTransactionType,
};

pub fn signingHash(allocator: std.mem.Allocator, bytes: []const u8) SenderRecoveryError![32]u8 {
    return (try decodeSigningMessage(allocator, bytes)).signing_hash;
}

pub fn recoverSender(allocator: std.mem.Allocator, bytes: []const u8) SenderRecoveryError!SenderRecovery {
    const message = try decodeSigningMessage(allocator, bytes);
    return .{
        .sender = try recoverAddress(message.signing_hash, message.y_parity, message.r, message.s),
        .signing_hash = message.signing_hash,
    };
}

pub fn recoverAuthorizationSigner(
    chain_id: u256,
    target: Address,
    nonce: u64,
    y_parity: u256,
    r: u256,
    s: u256,
) SenderRecoveryError!Address {
    const parity = std.math.cast(u8, y_parity) orelse return error.InvalidSignature;
    var fields_buffer: [authorization_fields_buffer_bytes]u8 = undefined;
    var fields = rlp.Writer.fixed(&fields_buffer);
    writeFixedInt(&fields, u256, chain_id);
    writeFixedBytes(&fields, &target);
    writeFixedInt(&fields, u64, nonce);

    var prefix_buffer: [rlp.max_length_prefix_bytes]u8 = undefined;
    const prefix = rlp.listPrefix(&prefix_buffer, fields.written().len);
    var message: [1 + rlp.max_length_prefix_bytes + authorization_fields_buffer_bytes]u8 = undefined;
    var offset: usize = 0;
    message[offset] = set_code_authorization_magic;
    offset += 1;
    @memcpy(message[offset..][0..prefix.len], prefix);
    offset += prefix.len;
    @memcpy(message[offset..][0..fields.written().len], fields.written());
    offset += fields.written().len;
    return recoverAddress(crypto.keccak256(message[0..offset]), parity, r, s);
}

pub const SigningMessage = struct {
    signing_hash: [32]u8,
    y_parity: u8,
    r: u256,
    s: u256,
};

fn decodeSigningMessage(allocator: std.mem.Allocator, bytes: []const u8) SenderRecoveryError!SigningMessage {
    const tx_envelope = try envelope.decodeEnvelope(bytes);
    return switch (tx_envelope) {
        .legacy => |legacy| decodeLegacySigningMessage(allocator, legacy),
        .typed => |typed| decodeTypedSigningMessage(allocator, typed),
    };
}

fn decodeLegacySigningMessage(allocator: std.mem.Allocator, bytes: []const u8) SenderRecoveryError!SigningMessage {
    var cursor = rlp.Cursor.init(bytes);
    const list_item = try cursor.next();
    try cursor.expectDone();

    var fields = try list_item.listCursor();
    for (0..6) |_| {
        _ = try fields.next();
    }
    const unsigned_payload = list_item.payload()[0..fields.offset];

    const v = try nextTransactionSignatureUint(&fields);
    const r = try nextTransactionSignatureUint(&fields);
    const s = try nextTransactionSignatureUint(&fields);
    try fields.expectDone();

    const legacy = try legacySignature(v);
    const signing_hash = if (legacy.chain_id) |chain_id|
        try protectedLegacyHash(allocator, unsigned_payload, chain_id)
    else
        try listHash(allocator, unsigned_payload);

    return .{
        .signing_hash = signing_hash,
        .y_parity = legacy.y_parity,
        .r = r,
        .s = s,
    };
}

fn decodeTypedSigningMessage(allocator: std.mem.Allocator, typed: TypedEnvelope) SenderRecoveryError!SigningMessage {
    const unsigned_field_count = typedUnsignedFieldCount(typed.type_id) orelse return error.UnsupportedTransactionType;

    var cursor = rlp.Cursor.init(typed.payload);
    const list_item = try cursor.next();
    try cursor.expectDone();

    var fields = try list_item.listCursor();
    for (0..unsigned_field_count) |_| {
        _ = try fields.next();
    }
    const unsigned_payload = list_item.payload()[0..fields.offset];

    const y_parity = try nextYParity(&fields);
    const r = try nextTransactionSignatureUint(&fields);
    const s = try nextTransactionSignatureUint(&fields);
    try fields.expectDone();

    return .{
        .signing_hash = try typedListHash(allocator, typed.type_id, unsigned_payload),
        .y_parity = y_parity,
        .r = r,
        .s = s,
    };
}

const LegacySignature = struct {
    y_parity: u8,
    chain_id: ?u256,
};

fn legacySignature(v: u256) SenderRecoveryError!LegacySignature {
    if (v == 27 or v == 28) {
        return .{
            .y_parity = @intCast(v - 27),
            .chain_id = null,
        };
    }
    if (v < 35) return error.UnsupportedLegacyV;

    const protected_v = v - 35;
    return .{
        .y_parity = @intCast(protected_v & 1),
        .chain_id = protected_v / 2,
    };
}

fn typedUnsignedFieldCount(type_id: u8) ?usize {
    return switch (type_id) {
        access_list_transaction_type => 8,
        dynamic_fee_transaction_type => 9,
        blob_transaction_type => 11,
        set_code_transaction_type => 10,
        else => null,
    };
}

fn protectedLegacyHash(allocator: std.mem.Allocator, unsigned_payload: []const u8, chain_id: u256) SenderRecoveryError![32]u8 {
    var tail_buffer: [protected_legacy_tail_buffer_bytes]u8 = undefined;
    var tail = rlp.Writer.fixed(&tail_buffer);
    writeFixedInt(&tail, u256, chain_id);
    writeFixedInt(&tail, u8, 0);
    writeFixedInt(&tail, u8, 0);

    const payload_len = std.math.add(usize, unsigned_payload.len, tail.written().len) catch return error.InvalidTransactionFormat;
    var prefix_buffer: [rlp.max_length_prefix_bytes]u8 = undefined;
    const prefix = rlp.listPrefix(&prefix_buffer, payload_len);
    const parts = [_][]const u8{ prefix, unsigned_payload, tail.written() };
    return hashParts(allocator, &parts);
}

fn listHash(allocator: std.mem.Allocator, payload: []const u8) SenderRecoveryError![32]u8 {
    var prefix_buffer: [rlp.max_length_prefix_bytes]u8 = undefined;
    const prefix = rlp.listPrefix(&prefix_buffer, payload.len);
    const parts = [_][]const u8{ prefix, payload };
    return hashParts(allocator, &parts);
}

fn typedListHash(allocator: std.mem.Allocator, type_id: u8, payload: []const u8) SenderRecoveryError![32]u8 {
    var prefix_buffer: [rlp.max_length_prefix_bytes]u8 = undefined;
    const prefix = rlp.listPrefix(&prefix_buffer, payload.len);
    const type_prefix = [_]u8{type_id};
    const parts = [_][]const u8{ &type_prefix, prefix, payload };
    return hashParts(allocator, &parts);
}

fn hashParts(allocator: std.mem.Allocator, parts: []const []const u8) SenderRecoveryError![32]u8 {
    var len: usize = 0;
    for (parts) |part| {
        len = std.math.add(usize, len, part.len) catch return error.InvalidTransactionFormat;
    }

    const message = try allocator.alloc(u8, len);
    defer allocator.free(message);

    var offset: usize = 0;
    for (parts) |part| {
        @memcpy(message[offset..][0..part.len], part);
        offset += part.len;
    }
    return crypto.keccak256(message);
}

fn writeFixedInt(writer: *rlp.Writer, comptime T: type, value: T) void {
    writer.int(T, value) catch |err| switch (err) {
        error.NoSpaceLeft, error.OutOfMemory => unreachable,
    };
}

fn writeFixedBytes(writer: *rlp.Writer, payload: []const u8) void {
    writer.bytes(payload) catch |err| switch (err) {
        error.NoSpaceLeft, error.OutOfMemory => unreachable,
    };
}

fn nextYParity(cursor: *rlp.Cursor) SenderRecoveryError!u8 {
    const y_parity = cursor.nextInt(u8) catch |err| switch (err) {
        error.IntTooLarge => return error.InvalidSignature,
        else => return err,
    };
    if (y_parity > 1) return error.InvalidSignature;
    return y_parity;
}

fn nextTransactionSignatureUint(cursor: *rlp.Cursor) SenderRecoveryError!u256 {
    return cursor.nextInt(u256) catch |err| switch (err) {
        error.IntTooLarge => error.InvalidSignature,
        else => err,
    };
}

fn recoverAddress(message_hash: [32]u8, y_parity: u8, r: u256, s: u256) SenderRecoveryError!Address {
    if (!eip7702.authorizationSignatureShapeValid(y_parity, null, r, s)) return error.InvalidSignature;

    const public_key = crypto.ecrecoverPublicKey(
        message_hash,
        uint256.toBytes32(r),
        uint256.toBytes32(s),
        y_parity,
    ) orelse return error.InvalidSignature;
    return address.fromPublicKey(public_key);
}

test "sender recovery reproduces EIP-155 legacy vector" {
    const hex = "f86c098504a817c800825208943535353535353535353535353535353535353535880de0b6b3a76400008025a028ef61340bd939bc2195fe537567866003e1a15d3c71ff63e1590620aa636276a067cbe9d8997f761aecb703304b3800ccf555c9f3dc64214b297fb1966a3b6d83";
    var bytes: [hex.len / 2]u8 = undefined;
    _ = try std.fmt.hexToBytes(&bytes, hex);

    const recovered = try recoverSender(std.testing.allocator, &bytes);
    try t.expectHex(&recovered.sender, "9d8a62f656a8d1615c1294fd71e9cfb3e4855a4f");
    try t.expectHex(&recovered.signing_hash, "daf5a779ae972f972197303d7b574746c7ef83eadac0f2791ad23db92e4c8e53");
    const hash_only = try signingHash(std.testing.allocator, &bytes);
    try std.testing.expectEqualSlices(u8, &recovered.signing_hash, &hash_only);
}

test "sender recovery handles legacy v27 and typed transaction families" {
    const allocator = std.testing.allocator;
    const signer = try TestSigner.init();

    const legacy = try signedLegacyTransactionForTest(allocator, signer, null);
    defer allocator.free(legacy);
    try expectRecoveredSender(allocator, legacy, signer.sender);

    const protected_legacy = try signedLegacyTransactionForTest(allocator, signer, 1);
    defer allocator.free(protected_legacy);
    try expectRecoveredSender(allocator, protected_legacy, signer.sender);

    const typed_ids = [_]u8{
        access_list_transaction_type,
        dynamic_fee_transaction_type,
        blob_transaction_type,
        set_code_transaction_type,
    };
    for (typed_ids) |type_id| {
        const unsigned_payload = try unsignedTypedPayloadForTest(allocator, type_id);
        defer allocator.free(unsigned_payload);
        const signed = try signedTypedTransactionForTest(allocator, signer, type_id, unsigned_payload);
        defer allocator.free(signed);
        try expectRecoveredSender(allocator, signed, signer.sender);
    }
}

const secp256k1n = eip7702.secp256k1n;
const secp256k1_half_n = eip7702.secp256k1_half_n;

test "EIP-7702 authorization signer recovery handles generated tuple signature" {
    const signer = try TestSigner.init();
    const target = address.addr(0x7702);
    const hash = try authorizationHashForTest(std.testing.allocator, 1, target, 7);
    const signature = try signatureForHash(signer, hash);

    const recovered = try recoverAuthorizationSigner(1, target, 7, signature.y_parity, signature.r, signature.s);
    try std.testing.expectEqualSlices(u8, &signer.sender, &recovered);
}

test "sender recovery rejects high-s signatures" {
    const allocator = std.testing.allocator;
    const unsigned_payload = try unsignedLegacyPayloadForTest(allocator);
    defer allocator.free(unsigned_payload);
    const signed = try signedLegacyPayloadForTest(allocator, unsigned_payload, 27, 1, secp256k1_half_n + 1);
    defer allocator.free(signed);

    try std.testing.expectError(error.InvalidSignature, recoverSender(allocator, signed));
}

const TestSigner = struct {
    key_pair: std.crypto.sign.ecdsa.EcdsaSecp256k1Sha256.KeyPair,
    sender: Address,

    fn init() !TestSigner {
        const Scheme = std.crypto.sign.ecdsa.EcdsaSecp256k1Sha256;
        const secret = try Scheme.SecretKey.fromBytes([_]u8{0x11} ** Scheme.SecretKey.encoded_length);
        const key_pair = try Scheme.KeyPair.fromSecretKey(secret);
        const sec1 = key_pair.public_key.toUncompressedSec1();
        var public_key: [64]u8 = undefined;
        @memcpy(&public_key, sec1[1..65]);
        return .{
            .key_pair = key_pair,
            .sender = address.fromPublicKey(public_key),
        };
    }
};

const TestSignature = struct {
    y_parity: u8,
    r: u256,
    s: u256,
};

fn signatureForHash(signer: TestSigner, message_hash: [32]u8) !TestSignature {
    const signature = try signer.key_pair.signPrehashed(message_hash, null);
    const bytes = signature.toBytes();
    const r = std.mem.readInt(u256, bytes[0..32], .big);
    var s = std.mem.readInt(u256, bytes[32..64], .big);
    if (s > secp256k1_half_n) s = secp256k1n - s;

    for (0..2) |candidate| {
        const y_parity: u8 = @intCast(candidate);
        const recovered = recoverAddress(message_hash, y_parity, r, s) catch continue;
        if (std.mem.eql(u8, &recovered, &signer.sender)) {
            return .{ .y_parity = y_parity, .r = r, .s = s };
        }
    }
    return error.InvalidSignature;
}

fn expectRecoveredSender(allocator: std.mem.Allocator, bytes: []const u8, expected: Address) !void {
    const recovered = try recoverSender(allocator, bytes);
    try std.testing.expectEqualSlices(u8, &expected, &recovered.sender);
}

fn signedLegacyTransactionForTest(allocator: std.mem.Allocator, signer: TestSigner, chain_id: ?u256) ![]u8 {
    const unsigned_payload = try unsignedLegacyPayloadForTest(allocator);
    defer allocator.free(unsigned_payload);
    const hash = if (chain_id) |protected_chain_id|
        try protectedLegacyHash(allocator, unsigned_payload, protected_chain_id)
    else
        try listHash(allocator, unsigned_payload);
    const signature = try signatureForHash(signer, hash);
    const v: u256 = if (chain_id) |protected_chain_id|
        35 + protected_chain_id * 2 + signature.y_parity
    else
        27 + signature.y_parity;
    return try signedLegacyPayloadForTest(allocator, unsigned_payload, v, signature.r, signature.s);
}

fn unsignedLegacyPayloadForTest(allocator: std.mem.Allocator) ![]u8 {
    var fields = rlp.Writer.alloc(allocator);
    errdefer fields.deinit();
    try fields.int(u64, 9);
    try fields.int(u64, 20_000_000_000);
    try fields.int(u64, 21_000);
    try fields.bytes(&address.addr(0x3535));
    try fields.int(u64, 1_000);
    try fields.bytes("");
    return try writerOwnedForTest(&fields);
}

fn signedLegacyPayloadForTest(allocator: std.mem.Allocator, unsigned_payload: []const u8, v: u256, r: u256, s: u256) ![]u8 {
    var signature_fields = rlp.Writer.alloc(allocator);
    defer signature_fields.deinit();
    try signature_fields.int(u256, v);
    try signature_fields.int(u256, r);
    try signature_fields.int(u256, s);
    const payload = try concatForTest(allocator, unsigned_payload, signature_fields.written());
    defer allocator.free(payload);

    var out = rlp.Writer.alloc(allocator);
    errdefer out.deinit();
    try out.list(payload);
    return try writerOwnedForTest(&out);
}

fn unsignedTypedPayloadForTest(allocator: std.mem.Allocator, type_id: u8) ![]u8 {
    var fields = rlp.Writer.alloc(allocator);
    errdefer fields.deinit();
    try fields.int(u8, 1);
    try fields.int(u64, 9);
    switch (type_id) {
        access_list_transaction_type => try fields.int(u64, 20_000_000_000),
        dynamic_fee_transaction_type, blob_transaction_type, set_code_transaction_type => {
            try fields.int(u64, 1);
            try fields.int(u64, 20_000_000_000);
        },
        else => unreachable,
    }
    try fields.int(u64, 50_000);
    try fields.bytes(&address.addr(0x4444));
    try fields.int(u64, 1_000);
    try fields.bytes("hello");
    try fields.list("");
    if (type_id == blob_transaction_type) {
        try fields.int(u64, 3);
        var hashes = rlp.Writer.alloc(allocator);
        defer hashes.deinit();
        try hashes.bytes(&([_]u8{0x01} ** 32));
        try fields.list(hashes.written());
    } else if (type_id == set_code_transaction_type) {
        try fields.list("");
    }
    return try writerOwnedForTest(&fields);
}

fn signedTypedTransactionForTest(allocator: std.mem.Allocator, signer: TestSigner, type_id: u8, unsigned_payload: []const u8) ![]u8 {
    const hash = try typedListHash(allocator, type_id, unsigned_payload);
    const signature = try signatureForHash(signer, hash);

    var signature_fields = rlp.Writer.alloc(allocator);
    defer signature_fields.deinit();
    try signature_fields.int(u8, signature.y_parity);
    try signature_fields.int(u256, signature.r);
    try signature_fields.int(u256, signature.s);
    const signed_payload = try concatForTest(allocator, unsigned_payload, signature_fields.written());
    defer allocator.free(signed_payload);

    var payload = rlp.Writer.alloc(allocator);
    defer payload.deinit();
    try payload.list(signed_payload);

    const out = try allocator.alloc(u8, 1 + payload.written().len);
    out[0] = type_id;
    @memcpy(out[1..], payload.written());
    return out;
}

fn authorizationHashForTest(allocator: std.mem.Allocator, chain_id: u256, target: Address, nonce: u64) ![32]u8 {
    var fields = rlp.Writer.alloc(allocator);
    defer fields.deinit();
    try fields.int(u256, chain_id);
    try fields.bytes(&target);
    try fields.int(u64, nonce);

    var list = rlp.Writer.alloc(allocator);
    defer list.deinit();
    try list.list(fields.written());

    const message = try allocator.alloc(u8, 1 + list.written().len);
    defer allocator.free(message);
    message[0] = set_code_authorization_magic;
    @memcpy(message[1..], list.written());
    return crypto.keccak256(message);
}

fn concatForTest(allocator: std.mem.Allocator, lhs: []const u8, rhs: []const u8) ![]u8 {
    const out = try allocator.alloc(u8, lhs.len + rhs.len);
    @memcpy(out[0..lhs.len], lhs);
    @memcpy(out[lhs.len..], rhs);
    return out;
}

fn writerOwnedForTest(writer: *rlp.Writer) ![]u8 {
    return writer.toOwnedSlice() catch |err| switch (err) {
        error.BorrowedWriter => unreachable,
        error.OutOfMemory => return error.OutOfMemory,
    };
}
