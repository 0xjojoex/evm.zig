//! Canonical Ethereum execution-header representation and RLP hash.

const std = @import("std");

const Address = @import("../address.zig").Address;
const crypto = @import("../crypto.zig");
const rlp = @import("../rlp.zig");
const Revision = @import("revision.zig").Revision;

pub const empty_ommers_hash = [_]u8{
    0x1d, 0xcc, 0x4d, 0xe8, 0xde, 0xc7, 0x5d, 0x7a,
    0xab, 0x85, 0xb5, 0x67, 0xb6, 0xcc, 0xd4, 0x1a,
    0xd3, 0x12, 0x45, 0x1b, 0x94, 0x8a, 0x74, 0x13,
    0xf0, 0xa1, 0x42, 0xfd, 0x40, 0xd4, 0x93, 0x47,
};

pub const pos_nonce = [_]u8{0} ** 8;

pub const Error = rlp.Writer.Error || error{
    ExtraDataTooLong,
    HeaderSurfaceMismatch,
};

/// Full execution-header value in canonical RLP field order.
///
/// Fields introduced by forks are optional in the value and are required to
/// match `revision` exactly when encoding or hashing.
pub const ExecutionHeader = struct {
    parent_hash: [32]u8,
    ommers_hash: [32]u8 = empty_ommers_hash,
    coinbase: Address,
    state_root: [32]u8,
    transactions_root: [32]u8,
    receipts_root: [32]u8,
    logs_bloom: [256]u8,
    difficulty: u256 = 0,
    number: u64,
    gas_limit: u64,
    gas_used: u64,
    timestamp: u64,
    extra_data: []const u8,
    prev_randao: [32]u8,
    nonce: [8]u8 = pos_nonce,
    base_fee_per_gas: ?u256 = null,
    withdrawals_root: ?[32]u8 = null,
    blob_gas_used: ?u64 = null,
    excess_blob_gas: ?u64 = null,
    parent_beacon_block_root: ?[32]u8 = null,
    requests_hash: ?[32]u8 = null,
    block_access_list_hash: ?[32]u8 = null,
    slot_number: ?u64 = null,

    pub fn validate(self: ExecutionHeader, revision: Revision) Error!void {
        if (self.extra_data.len > 32) return error.ExtraDataTooLong;

        const has_base_fee = revision.isImpl(.london);
        const has_withdrawals = revision.isImpl(.shanghai);
        const has_blob = revision.isImpl(.cancun);
        const has_requests = revision.isImpl(.prague);
        const has_amsterdam = revision.isImpl(.amsterdam);

        if ((self.base_fee_per_gas != null) != has_base_fee or
            (self.withdrawals_root != null) != has_withdrawals or
            (self.blob_gas_used != null) != has_blob or
            (self.excess_blob_gas != null) != has_blob or
            (self.parent_beacon_block_root != null) != has_blob or
            (self.requests_hash != null) != has_requests or
            (self.block_access_list_hash != null) != has_amsterdam or
            (self.slot_number != null) != has_amsterdam)
        {
            return error.HeaderSurfaceMismatch;
        }
    }

    pub fn encodeAlloc(self: ExecutionHeader, allocator: std.mem.Allocator, revision: Revision) Error![]u8 {
        try self.validate(revision);

        var fields = rlp.Writer.alloc(allocator);
        defer fields.deinit();
        try fields.bytes(&self.parent_hash);
        try fields.bytes(&self.ommers_hash);
        try fields.bytes(&self.coinbase);
        try fields.bytes(&self.state_root);
        try fields.bytes(&self.transactions_root);
        try fields.bytes(&self.receipts_root);
        try fields.bytes(&self.logs_bloom);
        try fields.int(u256, self.difficulty);
        try fields.int(u64, self.number);
        try fields.int(u64, self.gas_limit);
        try fields.int(u64, self.gas_used);
        try fields.int(u64, self.timestamp);
        try fields.bytes(self.extra_data);
        try fields.bytes(&self.prev_randao);
        try fields.bytes(&self.nonce);

        if (self.base_fee_per_gas) |value| try fields.int(u256, value);
        if (self.withdrawals_root) |value| try fields.bytes(&value);
        if (self.blob_gas_used) |value| try fields.int(u64, value);
        if (self.excess_blob_gas) |value| try fields.int(u64, value);
        if (self.parent_beacon_block_root) |value| try fields.bytes(&value);
        if (self.requests_hash) |value| try fields.bytes(&value);
        if (self.block_access_list_hash) |value| try fields.bytes(&value);
        if (self.slot_number) |value| try fields.int(u64, value);

        var encoded = rlp.Writer.alloc(allocator);
        defer encoded.deinit();
        try encoded.list(fields.written());
        return try allocator.dupe(u8, encoded.written());
    }

    pub fn hash(self: ExecutionHeader, allocator: std.mem.Allocator, revision: Revision) Error![32]u8 {
        const encoded = try self.encodeAlloc(allocator, revision);
        defer allocator.free(encoded);
        return crypto.keccak256(encoded);
    }
};

test "execution header reproduces Ethereum mainnet genesis hash" {
    const zero_hash = [_]u8{0} ** 32;
    const zero_address = [_]u8{0} ** 20;
    const empty_root = testHex("56e81f171bcc55a6ff8345e692c0f86e5b48e01b996cadc001622fb5e363b421");
    const header = ExecutionHeader{
        .parent_hash = zero_hash,
        .coinbase = zero_address,
        .state_root = testHex("d7f8974fb5ac78d9ac099b9ad5018bedc2ce0a72dad1827a1709da30580f0544"),
        .transactions_root = empty_root,
        .receipts_root = empty_root,
        .logs_bloom = [_]u8{0} ** 256,
        .difficulty = 17_179_869_184,
        .number = 0,
        .gas_limit = 5_000,
        .gas_used = 0,
        .timestamp = 0,
        .extra_data = &testHex("11bbe8db4e347b4e8c937c1c8370e4b5ed33adb3db69cbdb7a38e1e50b1b82fa"),
        .prev_randao = zero_hash,
        .nonce = testHex("0000000000000042"),
    };

    try expectHash(
        try header.hash(std.testing.allocator, .frontier),
        "d4e56740f876aef8c010b86a40d5f56745a118d0906a34e69aec8c0db1cb8fa3",
    );
}

test "execution header reproduces Amsterdam EEST genesis hash" {
    const zero_hash = [_]u8{0} ** 32;
    const empty_root = testHex("56e81f171bcc55a6ff8345e692c0f86e5b48e01b996cadc001622fb5e363b421");
    const header = ExecutionHeader{
        .parent_hash = zero_hash,
        .coinbase = [_]u8{0} ** 20,
        .state_root = testHex("d5ef849c559173e07d44d46a906eb95cbe0f1e417bf7aef21109efc88c3cf5fc"),
        .transactions_root = empty_root,
        .receipts_root = empty_root,
        .logs_bloom = [_]u8{0} ** 256,
        .number = 0,
        .gas_limit = 0x210f3e20,
        .gas_used = 0,
        .timestamp = 0,
        .extra_data = &.{0},
        .prev_randao = zero_hash,
        .base_fee_per_gas = 7,
        .withdrawals_root = empty_root,
        .blob_gas_used = 0,
        .excess_blob_gas = 0,
        .parent_beacon_block_root = zero_hash,
        .requests_hash = testHex("e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"),
        .block_access_list_hash = empty_ommers_hash,
        .slot_number = 0,
    };

    try expectHash(
        try header.hash(std.testing.allocator, .amsterdam),
        "f738eac1ac9ad987804bb1859ebbedfb24074e6206f9c4324070a5b4d394344c",
    );
}

test "execution header rejects fork-inconsistent field presence" {
    const zero_hash = [_]u8{0} ** 32;
    const header = ExecutionHeader{
        .parent_hash = zero_hash,
        .coinbase = [_]u8{0} ** 20,
        .state_root = zero_hash,
        .transactions_root = zero_hash,
        .receipts_root = zero_hash,
        .logs_bloom = [_]u8{0} ** 256,
        .number = 0,
        .gas_limit = 0,
        .gas_used = 0,
        .timestamp = 0,
        .extra_data = &.{},
        .prev_randao = zero_hash,
        .base_fee_per_gas = 0,
    };

    try std.testing.expectError(error.HeaderSurfaceMismatch, header.validate(.frontier));
    try header.validate(.london);
}

test "Amsterdam execution header encodes distinct tail fields in canonical order" {
    const zero_hash = [_]u8{0} ** 32;
    const header = ExecutionHeader{
        .parent_hash = zero_hash,
        .coinbase = [_]u8{0} ** 20,
        .state_root = zero_hash,
        .transactions_root = zero_hash,
        .receipts_root = zero_hash,
        .logs_bloom = [_]u8{0} ** 256,
        .number = 0,
        .gas_limit = 0,
        .gas_used = 0,
        .timestamp = 0,
        .extra_data = &.{},
        .prev_randao = zero_hash,
        .base_fee_per_gas = 0,
        .withdrawals_root = [_]u8{0x11} ** 32,
        .blob_gas_used = 1,
        .excess_blob_gas = 2,
        .parent_beacon_block_root = [_]u8{0x22} ** 32,
        .requests_hash = [_]u8{0x33} ** 32,
        .block_access_list_hash = [_]u8{0x44} ** 32,
        .slot_number = 3,
    };

    const encoded = try header.encodeAlloc(std.testing.allocator, .amsterdam);
    defer std.testing.allocator.free(encoded);

    var encoded_cursor = rlp.Cursor.init(encoded);
    var fields = try encoded_cursor.nextList();
    try encoded_cursor.expectDone();
    for (0..17) |_| _ = try fields.next();
    try std.testing.expectEqual(@as(u64, 1), try fields.nextInt(u64));
    try std.testing.expectEqual(@as(u64, 2), try fields.nextInt(u64));
    try std.testing.expectEqualSlices(u8, &([_]u8{0x22} ** 32), try fields.nextBytesExact(32));
    try std.testing.expectEqualSlices(u8, &([_]u8{0x33} ** 32), try fields.nextBytesExact(32));
    try std.testing.expectEqualSlices(u8, &([_]u8{0x44} ** 32), try fields.nextBytesExact(32));
    try std.testing.expectEqual(@as(u64, 3), try fields.nextInt(u64));
    try fields.expectDone();
}

fn testHex(comptime hex: []const u8) [hex.len / 2]u8 {
    var bytes: [hex.len / 2]u8 = undefined;
    _ = std.fmt.hexToBytes(&bytes, hex) catch unreachable;
    return bytes;
}

fn expectHash(actual: [32]u8, comptime expected_hex: []const u8) !void {
    const expected = testHex(expected_hex);
    try std.testing.expectEqualSlices(u8, &expected, &actual);
}
