//! Rich account storage used only by `MemoryStore` and fixture/test seeding.
//!
//! Executor accounts deliberately do not use this type: code is content-
//! addressed and storage is read independently through `StateReader`.

const std = @import("std");

const MemoryAccount = @This();

allocator: std.mem.Allocator,
nonce: u64 = 0,
balance: u256 = 0,
code: []u8 = &.{},
code_hash: ?[32]u8 = null,
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

    result.balance = self.balance;
    result.nonce = self.nonce;
    result.code_hash = self.code_hash;
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
    self.code_hash = null;
}

pub fn setCode(self: *MemoryAccount, code: []const u8) !void {
    const copy = try self.allocator.dupe(u8, code);
    self.clearCode();
    self.code = copy;
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
}
