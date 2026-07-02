//! Read-only canonical state provider supplied by an Ethereum client.
//!
//! Implementations should read from the client's database/trie/cache. Execution
//! writes belong in `Overlay` until the caller commits a final changeset.

const std = @import("std");

const Address = @import("../address.zig").Address;
const AccountState = @import("./Account.zig");

const StateReader = @This();

ptr: *anyopaque,
vtable: *const VTable,

pub const VTable = struct {
    accountExists: *const fn (ptr: *anyopaque, address: Address) anyerror!bool,
    loadAccount: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator, address: Address) anyerror!?AccountState,
    getStorage: *const fn (ptr: *anyopaque, address: Address, key: u256) anyerror!u256,
    accountHasStorage: *const fn (ptr: *anyopaque, address: Address) anyerror!bool,
};

pub fn accountExists(self: StateReader, address: Address) !bool {
    return self.vtable.accountExists(self.ptr, address);
}

/// Returns an owned account snapshot. The caller owns any code buffer and the
/// returned account's storage map.
pub fn loadAccount(self: StateReader, allocator: std.mem.Allocator, address: Address) !?AccountState {
    return self.vtable.loadAccount(self.ptr, allocator, address);
}

pub fn getStorage(self: StateReader, address: Address, key: u256) !u256 {
    return self.vtable.getStorage(self.ptr, address, key);
}

pub fn accountHasStorage(self: StateReader, address: Address) !bool {
    return self.vtable.accountHasStorage(self.ptr, address);
}

pub fn empty() StateReader {
    return .{ .ptr = &empty_context, .vtable = &empty_vtable };
}

var empty_context: u8 = 0;

const empty_vtable = VTable{
    .accountExists = emptyAccountExists,
    .loadAccount = emptyLoadAccount,
    .getStorage = emptyGetStorage,
    .accountHasStorage = emptyAccountHasStorage,
};

fn emptyAccountExists(ptr: *anyopaque, address: Address) !bool {
    _ = ptr;
    _ = address;
    return false;
}

fn emptyLoadAccount(ptr: *anyopaque, allocator: std.mem.Allocator, address: Address) !?AccountState {
    _ = ptr;
    _ = allocator;
    _ = address;
    return null;
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
    const reader = StateReader.empty();
    try std.testing.expect(!try reader.accountExists(addr(1)));
    try std.testing.expectEqual(@as(?AccountState, null), try reader.loadAccount(std.testing.allocator, addr(1)));
    try std.testing.expectEqual(@as(u256, 0), try reader.getStorage(addr(1), 1));
    try std.testing.expect(!try reader.accountHasStorage(addr(1)));
}
