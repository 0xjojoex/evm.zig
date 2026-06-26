//! Mutable account record used by the executor overlay and by `MemoryBackend`.
//!
//! The `storage` map is not the production database. For a client-backed run,
//! canonical slots are read through `Backend.getStorage`; this map holds slots
//! that are materialized in a throwaway memory backend or touched by execution.

const std = @import("std");

const Account = @This();

nonce: u64 = 0,
balance: u256 = 0,
code: []u8 = &.{},
storage: std.AutoHashMap(u256, u256),

pub fn init(allocator: std.mem.Allocator) Account {
    return .{
        .storage = std.AutoHashMap(u256, u256).init(allocator),
    };
}

pub fn deinit(self: *Account, allocator: std.mem.Allocator) void {
    allocator.free(self.code);
    self.storage.deinit();
}

pub fn clone(self: *const Account, allocator: std.mem.Allocator) !Account {
    var result = Account.init(allocator);
    errdefer result.deinit(allocator);

    result.balance = self.balance;
    result.nonce = self.nonce;
    result.code = try allocator.dupe(u8, self.code);

    var storage = self.storage;
    var storage_it = storage.iterator();
    while (storage_it.next()) |entry| {
        try result.storage.put(entry.key_ptr.*, entry.value_ptr.*);
    }

    return result;
}

pub fn getStorage(self: *Account, key: u256) u256 {
    return self.storage.get(key) orelse 0;
}

pub fn clearCode(self: *Account, allocator: std.mem.Allocator) void {
    allocator.free(self.code);
    self.code = &.{};
}

pub fn setCode(self: *Account, allocator: std.mem.Allocator, code: []const u8) !void {
    const copy = try allocator.dupe(u8, code);
    self.clearCode(allocator);
    self.code = copy;
}

test "account clone owns code and storage" {
    var account = Account.init(std.testing.allocator);
    defer account.deinit(std.testing.allocator);
    try account.setCode(std.testing.allocator, &.{ 0x60, 0x00 });
    try account.storage.put(1, 2);

    var cloned = try account.clone(std.testing.allocator);
    defer cloned.deinit(std.testing.allocator);

    try std.testing.expectEqualSlices(u8, account.code, cloned.code);
    try std.testing.expectEqual(@as(u256, 2), cloned.getStorage(1));
}
