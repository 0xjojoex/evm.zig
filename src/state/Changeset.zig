//! Typed state delta emitted by `Overlay` after transaction finalization.
//!
//! This is the write boundary for integrations: clients keep their trie/db as
//! the state reader, then commit this compact delta after successful execution.
//! Account-leaf updates carry code hashes; code blobs are separate, idempotent,
//! content-addressed inserts.

const std = @import("std");

const Address = @import("../address.zig").Address;

const Changeset = @This();

pub const AccountUpdate = struct {
    address: Address,
    nonce: u64,
    balance: u256,
    /// Canonical code commitment after this update, whether or not code bytes
    /// had to be materialized in the execution overlay.
    code_hash: [32]u8,
};

/// Owned content-addressed code introduced by the transition.
pub const CodeInsert = struct {
    code_hash: [32]u8,
    code_offset: usize,
    code_len: usize,
};

pub const StorageWrite = struct {
    address: Address,
    key: u256,
    value: u256,
};

account_updates: std.ArrayList(AccountUpdate),
code_inserts: std.ArrayList(CodeInsert),
code_bytes: std.ArrayList(u8),
account_deletes: std.ArrayList(Address),
storage_writes: std.ArrayList(StorageWrite),

pub fn init() Changeset {
    return .{
        .account_updates = .empty,
        .code_inserts = .empty,
        .code_bytes = .empty,
        .account_deletes = .empty,
        .storage_writes = .empty,
    };
}

pub fn deinit(self: *Changeset, allocator: std.mem.Allocator) void {
    self.account_updates.deinit(allocator);
    self.code_inserts.deinit(allocator);
    self.code_bytes.deinit(allocator);
    self.account_deletes.deinit(allocator);
    self.storage_writes.deinit(allocator);
}

pub fn reserveCodeInserts(
    self: *Changeset,
    allocator: std.mem.Allocator,
    additional_inserts: usize,
    additional_bytes: usize,
) !void {
    try self.code_inserts.ensureUnusedCapacity(allocator, additional_inserts);
    try self.code_bytes.ensureUnusedCapacity(allocator, additional_bytes);
}

pub fn appendCodeInsert(
    self: *Changeset,
    allocator: std.mem.Allocator,
    code_hash: [32]u8,
    code: []const u8,
) !void {
    const owned_code_offset = self.ownedCodeOffset(code);
    try self.reserveCodeInserts(allocator, 1, code.len);
    errdefer comptime unreachable;
    const stable_code = if (owned_code_offset) |offset|
        self.code_bytes.items[offset..][0..code.len]
    else
        code;
    self.appendCodeInsertAssumeCapacity(code_hash, stable_code);
}

pub fn appendCodeInsertAssumeCapacity(self: *Changeset, code_hash: [32]u8, code: []const u8) void {
    const code_offset = self.code_bytes.items.len;
    self.code_bytes.appendSliceAssumeCapacity(code);
    self.code_inserts.appendAssumeCapacity(.{
        .code_hash = code_hash,
        .code_offset = code_offset,
        .code_len = code.len,
    });
}

pub fn codeBytes(self: *const Changeset, insert: CodeInsert) []const u8 {
    std.debug.assert(insert.code_offset <= self.code_bytes.items.len);
    std.debug.assert(insert.code_len <= self.code_bytes.items.len - insert.code_offset);
    return self.code_bytes.items[insert.code_offset..][0..insert.code_len];
}

fn ownedCodeOffset(self: *const Changeset, code: []const u8) ?usize {
    if (code.len == 0 or self.code_bytes.items.len == 0) return null;
    const buffer_start = @intFromPtr(self.code_bytes.items.ptr);
    const code_start = @intFromPtr(code.ptr);
    if (code_start < buffer_start) return null;
    const offset = code_start - buffer_start;
    if (offset > self.code_bytes.items.len or
        code.len > self.code_bytes.items.len - offset)
    {
        return null;
    }
    return offset;
}

pub fn sort(self: *Changeset) void {
    std.mem.sort(AccountUpdate, self.account_updates.items, {}, accountUpdateLessThan);
    std.mem.sort(CodeInsert, self.code_inserts.items, {}, codeInsertLessThan);
    std.mem.sort(Address, self.account_deletes.items, {}, addressLessThan);
    std.mem.sort(StorageWrite, self.storage_writes.items, {}, storageWriteLessThan);
}

fn codeInsertLessThan(_: void, lhs: CodeInsert, rhs: CodeInsert) bool {
    return std.mem.order(u8, &lhs.code_hash, &rhs.code_hash) == .lt;
}

fn accountUpdateLessThan(_: void, lhs: AccountUpdate, rhs: AccountUpdate) bool {
    return addressLessThan({}, lhs.address, rhs.address);
}

fn storageWriteLessThan(_: void, lhs: StorageWrite, rhs: StorageWrite) bool {
    const address_order = std.mem.order(u8, &lhs.address, &rhs.address);
    if (address_order != .eq) return address_order == .lt;
    return lhs.key < rhs.key;
}

fn addressLessThan(_: void, lhs: Address, rhs: Address) bool {
    return std.mem.order(u8, &lhs, &rhs) == .lt;
}

test "changeset code inserts use stable ranges in one byte buffer" {
    var changeset = Changeset.init();
    defer changeset.deinit(std.testing.allocator);

    const high = [_]u8{ 0xaa, 0xbb, 0xcc };
    const low = [_]u8{0x11};
    try changeset.appendCodeInsert(std.testing.allocator, [_]u8{0xff} ** 32, &high);
    try changeset.appendCodeInsert(std.testing.allocator, [_]u8{0x01} ** 32, &low);
    try changeset.appendCodeInsert(std.testing.allocator, [_]u8{0x80} ** 32, &.{});

    changeset.sort();

    try std.testing.expectEqualSlices(u8, &low, changeset.codeBytes(changeset.code_inserts.items[0]));
    try std.testing.expectEqual(@as(usize, 0), changeset.codeBytes(changeset.code_inserts.items[1]).len);
    try std.testing.expectEqualSlices(u8, &high, changeset.codeBytes(changeset.code_inserts.items[2]));
    try std.testing.expectEqualSlices(u8, &.{ 0xaa, 0xbb, 0xcc, 0x11 }, changeset.code_bytes.items);
}

test "changeset code append keeps logical lengths atomic on allocation failure" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 1 });
    var changeset = Changeset.init();
    defer changeset.deinit(failing.allocator());

    try std.testing.expectError(
        error.OutOfMemory,
        changeset.appendCodeInsert(failing.allocator(), [_]u8{0x01} ** 32, &.{ 1, 2, 3 }),
    );
    try std.testing.expectEqual(@as(usize, 0), changeset.code_inserts.items.len);
    try std.testing.expectEqual(@as(usize, 0), changeset.code_bytes.items.len);
}

test "changeset code append preserves self-borrowed bytes across growth" {
    var changeset = Changeset.init();
    defer changeset.deinit(std.testing.allocator);

    const code = [_]u8{0x5a} ** 128;
    try changeset.appendCodeInsert(std.testing.allocator, [_]u8{0x01} ** 32, &code);
    try changeset.code_bytes.shrinkAndFreePrecise(std.testing.allocator, changeset.code_bytes.items.len);
    const borrowed = changeset.codeBytes(changeset.code_inserts.items[0]);

    try changeset.appendCodeInsert(std.testing.allocator, [_]u8{0x02} ** 32, borrowed);

    try std.testing.expect(changeset.code_bytes.capacity >= code.len * 2);
    try std.testing.expectEqualSlices(u8, &code, changeset.codeBytes(changeset.code_inserts.items[0]));
    try std.testing.expectEqualSlices(u8, &code, changeset.codeBytes(changeset.code_inserts.items[1]));
}
