//! Read-only canonical state provider supplied by an Ethereum client.
//!
//! Implementations should read from the client's database/trie/cache. Execution
//! writes belong in `Overlay` until the caller commits a final changeset.

const std = @import("std");

const Address = @import("../address.zig").Address;
const Account = @import("./Account.zig");
const mpt = @import("../mpt.zig");

const Reader = @This();

ptr: *anyopaque,
vtable: *const VTable,

pub const VTable = struct {
    accountExists: *const fn (ptr: *anyopaque, address: Address) anyerror!bool,
    loadAccount: *const fn (ptr: *anyopaque, address: Address) anyerror!?Account,
    /// Returns bytes whose hash is `code_hash`. The reader owns the slice.
    loadCode: *const fn (ptr: *anyopaque, code_hash: [32]u8) anyerror![]const u8,
    getStorage: *const fn (ptr: *anyopaque, address: Address, key: u256) anyerror!u256,
    accountHasStorage: *const fn (ptr: *anyopaque, address: Address) anyerror!bool,
};

pub fn accountExists(self: Reader, address: Address) !bool {
    return self.vtable.accountExists(self.ptr, address);
}

pub fn loadAccount(self: Reader, address: Address) !?Account {
    return self.vtable.loadAccount(self.ptr, address);
}

pub fn loadCode(self: Reader, code_hash: [32]u8) ![]const u8 {
    const code = try self.vtable.loadCode(self.ptr, code_hash);
    if (!std.mem.eql(u8, &mpt.codeHash(code), &code_hash)) return error.CodeHashMismatch;
    return code;
}

pub fn getStorage(self: Reader, address: Address, key: u256) !u256 {
    return self.vtable.getStorage(self.ptr, address, key);
}

pub fn accountHasStorage(self: Reader, address: Address) !bool {
    return self.vtable.accountHasStorage(self.ptr, address);
}

pub fn empty() Reader {
    return .{ .ptr = &empty_context, .vtable = &empty_vtable };
}

var empty_context: u8 = 0;

const empty_vtable = VTable{
    .accountExists = emptyAccountExists,
    .loadAccount = emptyLoadAccount,
    .loadCode = emptyLoadCode,
    .getStorage = emptyGetStorage,
    .accountHasStorage = emptyAccountHasStorage,
};

fn emptyAccountExists(ptr: *anyopaque, address: Address) !bool {
    _ = ptr;
    _ = address;
    return false;
}

fn emptyLoadAccount(ptr: *anyopaque, address: Address) !?Account {
    _ = ptr;
    _ = address;
    return null;
}

fn emptyLoadCode(ptr: *anyopaque, code_hash: [32]u8) ![]const u8 {
    _ = ptr;
    if (std.mem.eql(u8, &code_hash, &mpt.empty_code_hash)) return &.{};
    return error.CodeUnavailable;
}

fn emptyGetStorage(ptr: *anyopaque, address: Address, key: u256) !u256 {
    _ = ptr;
    _ = address;
    _ = key;
    return 0;
}

fn emptyAccountHasStorage(ptr: *anyopaque, address: Address) !bool {
    _ = ptr;
    _ = address;
    return false;
}

test "empty state reader returns empty state" {
    const addr = @import("../address.zig").addr;
    const reader = Reader.empty();
    try std.testing.expect(!try reader.accountExists(addr(1)));
    try std.testing.expectEqual(@as(?Account, null), try reader.loadAccount(addr(1)));
    try std.testing.expectEqualSlices(u8, &.{}, try reader.loadCode(mpt.empty_code_hash));
    try std.testing.expectEqual(@as(u256, 0), try reader.getStorage(addr(1), 1));
    try std.testing.expect(!try reader.accountHasStorage(addr(1)));
}
