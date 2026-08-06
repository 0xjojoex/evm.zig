//! Rich account storage used only by `MemoryStore` and fixture/test seeding.
//!
//! Executor accounts deliberately do not use this type: code is content-
//! addressed and storage is read independently through `StateReader`.
//!
//! `account.code_hash` commits to `code`, and `setCode` is what keeps the two
//! in step. Both fields stay public so a fixture can seed a deliberately
//! inconsistent pair; `MemoryStore.putAccount` re-derives the hash and refuses
//! such an account rather than admitting it to the store.

const std = @import("std");

const crypto = @import("../crypto.zig");
const Account = @import("./Account.zig");

const MemoryAccount = @This();

allocator: std.mem.Allocator,
account: Account = .{},
code: []u8 = &.{},
storage: std.AutoHashMap(u256, u256),

pub fn init(allocator: std.mem.Allocator) MemoryAccount {
    return .{
        .allocator = allocator,
        .storage = std.AutoHashMap(u256, u256).init(allocator),
    };
}

pub fn deinit(self: *MemoryAccount) void {
    self.allocator.free(self.code);
    self.storage.deinit();
}

pub fn clone(self: *const MemoryAccount, allocator: std.mem.Allocator) !MemoryAccount {
    var result = MemoryAccount.init(allocator);
    errdefer result.deinit();

    result.account = self.account;
    result.code = try allocator.dupe(u8, self.code);

    var storage = self.storage;
    var storage_it = storage.iterator();
    while (storage_it.next()) |entry| {
        try result.storage.put(entry.key_ptr.*, entry.value_ptr.*);
    }

    return result;
}

pub fn getStorage(self: *MemoryAccount, key: u256) u256 {
    return self.storage.get(key) orelse 0;
}

pub fn clearCode(self: *MemoryAccount) void {
    self.allocator.free(self.code);
    self.code = &.{};
    self.account.code_hash = crypto.keccak256_empty;
}

pub fn setCode(self: *MemoryAccount, code: []const u8) !void {
    // Duplicate before freeing: `code` is allowed to alias the bytes this
    // account already owns.
    const copy = try self.allocator.dupe(u8, code);
    self.allocator.free(self.code);
    self.code = copy;
    self.account.code_hash = crypto.keccak256(copy);
}

/// Take ownership of bytes already allocated from this account's allocator.
///
/// Assigning `code` directly instead leaves `account.code_hash` stale, which
/// `MemoryStore.putAccount` and `TrackedState.seedAccount` then reject.
pub fn adoptCode(self: *MemoryAccount, code: []u8) void {
    std.debug.assert(self.code.len == 0 or self.code.ptr != code.ptr);
    self.allocator.free(self.code);
    self.code = code;
    self.account.code_hash = crypto.keccak256(code);
}

test "memory account clone owns code and storage" {
    var account = MemoryAccount.init(std.testing.allocator);
    defer account.deinit();
    try account.setCode(&.{ 0x60, 0x00 });
    try account.storage.put(1, 2);

    var cloned = try account.clone(std.testing.allocator);
    defer cloned.deinit();

    try std.testing.expectEqualSlices(u8, account.code, cloned.code);
    try std.testing.expectEqual(@as(u256, 2), cloned.getStorage(1));
    try std.testing.expectEqual(account.account, cloned.account);
}

test "code hash tracks the bytes across set, reset, and clear" {
    var account = MemoryAccount.init(std.testing.allocator);
    defer account.deinit();
    try std.testing.expectEqualSlices(u8, &crypto.keccak256_empty, &account.account.code_hash);

    try account.setCode(&.{ 0x60, 0x00 });
    try std.testing.expectEqualSlices(
        u8,
        &crypto.keccak256(&.{ 0x60, 0x00 }),
        &account.account.code_hash,
    );

    // Re-setting from the account's own bytes must survive the intermediate free.
    try account.setCode(account.code);
    try std.testing.expectEqualSlices(u8, &.{ 0x60, 0x00 }, account.code);
    try std.testing.expectEqualSlices(
        u8,
        &crypto.keccak256(&.{ 0x60, 0x00 }),
        &account.account.code_hash,
    );

    account.clearCode();
    try std.testing.expectEqual(@as(usize, 0), account.code.len);
    try std.testing.expectEqualSlices(u8, &crypto.keccak256_empty, &account.account.code_hash);
}

test "adoptCode takes ownership and keeps the hash in step" {
    var account = MemoryAccount.init(std.testing.allocator);
    defer account.deinit();
    try account.setCode(&.{0x01});

    const owned = try std.testing.allocator.dupe(u8, &.{ 0x60, 0x2a });
    account.adoptCode(owned);
    try std.testing.expectEqual(owned.ptr, account.code.ptr);
    try std.testing.expectEqualSlices(
        u8,
        &crypto.keccak256(&.{ 0x60, 0x2a }),
        &account.account.code_hash,
    );
}
