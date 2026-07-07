const std = @import("std");
const definition_support = @import("./protocol/support.zig");
const rlp = @import("./rlp.zig");
const EthRevision = @import("./eth/revision.zig").Revision;
const eip7702 = @import("./executor/eip7702.zig");
const tx = @import("./transaction/Transaction.zig");

pub const set_code_transaction_type: u8 = 0x04;

pub const TransactionEnvelope = union(enum) {
    legacy: []const u8,
    typed: TypedEnvelope,
};

pub const TypedEnvelope = struct {
    type_id: u8,
    payload: []const u8,
};

pub const RawValidationError = enum {
    unsupported_transaction_type,
    type_4_tx_pre_fork,
    type_4_empty_authorization_list,
    type_4_invalid_authorization_format,
    type_4_invalid_authority_signature,
    type_4_invalid_authority_signature_s_too_high,
};

pub fn decodeEnvelope(bytes: []const u8) !TransactionEnvelope {
    if (bytes.len == 0) return error.EmptyTransaction;
    const prefix = bytes[0];
    if (prefix < 0x80) {
        return .{ .typed = .{
            .type_id = prefix,
            .payload = bytes[1..],
        } };
    }
    if (prefix >= 0xc0) {
        return .{ .legacy = bytes };
    }
    return error.InvalidTransactionEnvelope;
}

pub fn For(comptime ProtocolType: type) type {
    return struct {
        const Self = @This();

        pub const Protocol = ProtocolType;

        pub fn validateRawTransaction(revision: Protocol.Revision, bytes: []const u8) ?RawValidationError {
            definition_support.assertRevisionSupported(Protocol, revision);
            const envelope = decodeEnvelope(bytes) catch return .type_4_invalid_authorization_format;
            return switch (envelope) {
                .legacy => null,
                .typed => |typed| Self.validateTypedTransaction(revision, typed),
            };
        }

        fn validateTypedTransaction(revision: Protocol.Revision, typed: TypedEnvelope) ?RawValidationError {
            return switch (typed.type_id) {
                set_code_transaction_type => {
                    Self.validateSetCodeTransaction(revision, typed.payload) catch |err| return switch (err) {
                        error.Type4PreFork => .type_4_tx_pre_fork,
                        error.EmptyAuthorizationList => .type_4_empty_authorization_list,
                        error.InvalidAuthorizationFormat => .type_4_invalid_authorization_format,
                        error.InvalidAuthoritySignature => .type_4_invalid_authority_signature,
                        error.InvalidAuthoritySignatureSTooHigh => .type_4_invalid_authority_signature_s_too_high,
                    };
                    return null;
                },
                else => .unsupported_transaction_type,
            };
        }

        fn validateSetCodeTransaction(revision: Protocol.Revision, payload: []const u8) DecodeError!void {
            if (!Protocol.Transaction.kindActive(revision, tx.TxKind.set_code)) return error.Type4PreFork;

            validateSetCodePayload(payload) catch |err| return switch (err) {
                error.EmptyAuthorizationList => error.EmptyAuthorizationList,
                error.InvalidAuthoritySignature => error.InvalidAuthoritySignature,
                error.InvalidAuthoritySignatureSTooHigh => error.InvalidAuthoritySignatureSTooHigh,
                else => error.InvalidAuthorizationFormat,
            };
        }
    };
}

const DecodeError = error{
    Type4PreFork,
    EmptyAuthorizationList,
    InvalidAuthorizationFormat,
    InvalidAuthoritySignature,
    InvalidAuthoritySignatureSTooHigh,
};

fn validateSetCodePayload(payload: []const u8) !void {
    var cursor = rlp.Cursor.init(payload);
    var fields = try cursor.nextList();
    try cursor.expectDone();

    _ = try fields.nextInt(u256);
    _ = try fields.nextInt(u64);
    _ = try fields.nextInt(u256);
    _ = try fields.nextInt(u256);
    _ = try fields.nextInt(u64);
    _ = try fields.nextBytesExact(20);
    _ = try fields.nextInt(u256);
    _ = try fields.nextBytes();
    try validateAccessList(&fields);
    try validateAuthorizationList(&fields);
    _ = try nextSignatureUint(&fields);
    _ = try nextSignatureUint(&fields);
    _ = try nextSignatureUint(&fields);
    try fields.expectDone();
}

fn validateAccessList(fields: *rlp.Cursor) !void {
    var access_list = try fields.nextList();
    while (!access_list.isDone()) {
        var entry = try access_list.nextList();
        _ = try entry.nextBytesExact(20);
        var keys = try entry.nextList();
        while (!keys.isDone()) {
            _ = try keys.nextBytesExact(32);
        }
        try keys.expectDone();
        try entry.expectDone();
    }
    try access_list.expectDone();
}

fn validateAuthorizationList(fields: *rlp.Cursor) !void {
    var auth_list = try fields.nextList();
    var count: usize = 0;
    while (!auth_list.isDone()) {
        count += 1;
        var tuple = try auth_list.nextList();
        _ = try tuple.nextInt(u256);
        _ = try tuple.nextBytesExact(20);
        _ = try tuple.nextInt(u64);
        const y_parity = try nextSignatureUint(&tuple);
        const r = try nextSignatureUint(&tuple);
        const s = try nextSignatureUint(&tuple);
        try tuple.expectDone();
        if (!eip7702.authorizationSignatureShapeValid(y_parity, null, r, s)) {
            if (eip7702.authorizationSignatureSTooHigh(s)) {
                return error.InvalidAuthoritySignatureSTooHigh;
            }
            return error.InvalidAuthoritySignature;
        }
    }
    try auth_list.expectDone();
    if (count == 0) return error.EmptyAuthorizationList;
}

fn nextSignatureUint(cursor: *rlp.Cursor) !u256 {
    return cursor.nextInt(u256) catch |err| switch (err) {
        error.IntTooLarge => error.InvalidAuthoritySignature,
        else => err,
    };
}

test "EIP-2718 envelope splits typed transactions" {
    const bytes = [_]u8{ 0x04, 0xc0 };
    const envelope = try decodeEnvelope(&bytes);
    try std.testing.expectEqual(@as(u8, set_code_transaction_type), envelope.typed.type_id);
    try std.testing.expectEqualSlices(u8, &[_]u8{0xc0}, envelope.typed.payload);
}

test "EIP-2718 envelope keeps legacy transactions opaque" {
    const bytes = [_]u8{0xc0};
    const envelope = try decodeEnvelope(&bytes);
    try std.testing.expectEqualSlices(u8, &bytes, envelope.legacy);
}

test "set-code transaction rejects empty authorization list" {
    const ethereum = @import("./eth.zig");
    const hex = "04f86401808007830186a09400000000000000000000000000000000000000008080c0c001a04319a2e8066a9beedd85b227bf40cdecfb6134e6c1254f1e680895bc3131df31a059efad54e662f062d9af60acca08efb1d3d312742e381a600aac7c7989f892cc";
    var bytes: [hex.len / 2]u8 = undefined;
    _ = try std.fmt.hexToBytes(&bytes, hex);
    try std.testing.expectEqual(
        RawValidationError.type_4_empty_authorization_list,
        For(ethereum).validateRawTransaction(.prague, &bytes).?,
    );
}

test "raw transaction validation uses comptime transaction kind policy" {
    const ethereum = @import("./eth.zig");
    const EarlySetCodeProtocol = struct {
        pub const Revision = EthRevision;

        pub const Transaction = struct {
            pub fn kindActive(revision: Revision, kind: tx.TxKind) bool {
                _ = revision;
                return kind == .set_code;
            }
        };
    };
    const malformed_set_code = [_]u8{ 0x04, 0xc0 };

    try std.testing.expectEqual(
        RawValidationError.type_4_tx_pre_fork,
        For(ethereum).validateRawTransaction(.cancun, &malformed_set_code).?,
    );
    try std.testing.expectEqual(
        RawValidationError.type_4_invalid_authorization_format,
        For(EarlySetCodeProtocol).validateRawTransaction(.cancun, &malformed_set_code).?,
    );
}
