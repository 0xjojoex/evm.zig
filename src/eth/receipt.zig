//! Consensus receipt wire encoding and logs-bloom folding.
//!
//! Pure Ethereum encoding: no execution state, no block lifecycle. Both the
//! serial block STF and the BAL candidate lane fold receipts through here so
//! the two paths cannot diverge on wire bytes.

const std = @import("std");

const crypto = @import("../crypto.zig");
const rlp = @import("rlp");
const state = @import("../state.zig");
const transaction = @import("../transaction.zig");
const uint256 = @import("../uint256.zig");
const vm = @import("../vm.zig");

const Log = vm.Log;
const TxStatus = vm.TxStatus;
const TxReceiptView = vm.TxReceiptView;

pub const empty_logs_bloom = [_]u8{0} ** 256;

const TopicRlp = rlp.Mapped(u256, rlp.FixedBytes(32), struct {
    pub fn toWire(topic: u256) [32]u8 {
        return uint256.toBytes32(topic);
    }

    pub fn fromWire(encoded: [32]u8) u256 {
        return uint256.fromBytes32(&encoded);
    }
});

const LogRlp = rlp.Struct(Log, .{
    .topics = rlp.BoundedListOf(TopicRlp, 4),
});

/// Consensus receipt wire payload; `encode` writes its typed RLP form.
pub const Payload = struct {
    status: u8,
    cumulative_gas_used: u64,
    logs_bloom: [256]u8,
    logs: []const Log,

    pub const Rlp = rlp.Struct(@This(), .{
        .logs = rlp.ListOf(LogRlp),
    });
};

pub fn encode(allocator: std.mem.Allocator, kind: transaction.TxKind, receipt: TxReceiptView) ![]u8 {
    return encodeView(allocator, kind, receipt);
}

pub fn encodeView(allocator: std.mem.Allocator, kind: transaction.TxKind, receipt: anytype) ![]u8 {
    const logs = try allocator.alloc(Log, receipt.logs.len());
    defer allocator.free(logs);
    for (logs, 0..) |*event_log, index| event_log.* = receipt.logs.get(index);
    const payload: Payload = .{
        .status = receiptStatus(receipt.status),
        .cumulative_gas_used = receipt.cumulative_gas_used,
        .logs_bloom = logsBloom(receipt.logs),
        .logs = logs,
    };
    const payload_len = try rlp.encodedLen(Payload, &payload);
    const type_id = transactionType(kind);
    const envelope_len: usize = if (type_id == null) 0 else 1;
    const encoded_len = std.math.add(usize, envelope_len, payload_len) catch
        return error.EncodedLengthOverflow;
    const encoded = try allocator.alloc(u8, encoded_len);
    errdefer allocator.free(encoded);

    if (type_id) |id| encoded[0] = id;
    const written = try rlp.encode(Payload, encoded[envelope_len..], &payload);
    std.debug.assert(written.len == payload_len);
    return encoded;
}

fn receiptStatus(status: TxStatus) u8 {
    return switch (status) {
        .success => 1,
        .revert, .invalid, .out_of_gas => 0,
    };
}

fn transactionType(kind: transaction.TxKind) ?u8 {
    return switch (kind) {
        .legacy => null,
        .access_list => 0x01,
        .dynamic_fee => 0x02,
        .blob => 0x03,
        .set_code => 0x04,
    };
}

pub fn logsBloom(logs: state.LogBuffer.View) [256]u8 {
    var bloom = [_]u8{0} ** 256;
    for (0..logs.len()) |index| {
        const event_log = logs.get(index);
        addBloomEntry(&bloom, event_log.address.asBytes());
        for (event_log.topics) |topic| {
            const encoded_topic = uint256.toBytes32(topic);
            addBloomEntry(&bloom, &encoded_topic);
        }
    }
    return bloom;
}

pub fn mergeLogsBloom(target: *[256]u8, source: [256]u8) void {
    const target_words = std.mem.bytesAsSlice(u64, target[0..]);
    const source_words = std.mem.bytesAsSlice(u64, source[0..]);
    for (target_words, source_words) |*target_word, source_word| target_word.* |= source_word;
}

fn addBloomEntry(bloom: *[256]u8, entry: []const u8) void {
    const hash = crypto.keccak256(entry);
    inline for (.{ 0, 2, 4 }) |offset| {
        const bit_to_set: usize = ((@as(usize, hash[offset]) & 0x07) << 8) | @as(usize, hash[offset + 1]);
        const bit_index = 0x07ff - bit_to_set;
        bloom[bit_index / 8] |= @as(u8, 1) << @intCast(7 - (bit_index % 8));
    }
}

test "word-wise logs bloom merge matches byte-wise oracle" {
    var seed: u64 = 0x9e3779b97f4a7c15;
    for (0..256) |_| {
        var target: [256]u8 = undefined;
        var source: [256]u8 = undefined;
        var expected: [256]u8 = undefined;
        for (&target, &source, &expected) |*target_byte, *source_byte, *expected_byte| {
            seed ^= seed << 13;
            seed ^= seed >> 7;
            seed ^= seed << 17;
            target_byte.* = @truncate(seed);
            seed ^= seed << 13;
            seed ^= seed >> 7;
            seed ^= seed << 17;
            source_byte.* = @truncate(seed);
            expected_byte.* = target_byte.* | source_byte.*;
        }
        mergeLogsBloom(&target, source);
        try std.testing.expectEqualSlices(u8, &expected, &target);
    }
}
