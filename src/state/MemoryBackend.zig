//! In-memory implementation of the read-only `Backend` interface.
//!
//! This is for seeded pre-state in tests, demos, fixtures, or lightweight
//! integrations. It is not the execution overlay: speculative writes,
//! checkpoints, reverts, logs, warmth, and the future journal live in `Overlay`.

const std = @import("std");

const address_mod = @import("../address.zig");
const AccountState = @import("./Account.zig");
const Address = address_mod.Address;
const StateBackend = @import("./Backend.zig");

const MemoryBackend = @This();

allocator: std.mem.Allocator,
accounts: std.AutoHashMap(Address, AccountState),

pub fn init(allocator: std.mem.Allocator) MemoryBackend {
    return .{
        .allocator = allocator,
        .accounts = std.AutoHashMap(Address, AccountState).init(allocator),
    };
}

pub fn deinit(self: *MemoryBackend) void {
    self.clearAccounts();
    self.accounts.deinit();
}

pub fn backend(self: *MemoryBackend) StateBackend {
    return .{ .ptr = self, .vtable = &.{
        .accountExists = accountExists,
        .loadAccount = loadAccount,
        .getStorage = getStorage,
        .accountHasStorage = accountHasStorage,
    } };
}

pub fn getAccount(self: *MemoryBackend, address: Address) ?*AccountState {
    return self.accounts.getPtr(address);
}

pub fn getOrCreateAccount(self: *MemoryBackend, address: Address) !*AccountState {
    if (!self.accounts.contains(address)) {
        try self.accounts.put(address, AccountState.init(self.allocator));
    }
    return self.accounts.getPtr(address).?;
}

/// Inserts an owned account into the in-memory pre-state.
/// The backend will deinit the account with its allocator.
pub fn putAccount(self: *MemoryBackend, address: Address, account: AccountState) !void {
    if (self.accounts.fetchRemove(address)) |removed| {
        var old_account = removed.value;
        old_account.deinit(self.allocator);
    }
    try self.accounts.put(address, account);
}

pub fn clearAccounts(self: *MemoryBackend) void {
    var account_it = self.accounts.valueIterator();
    while (account_it.next()) |account| {
        account.deinit(self.allocator);
    }
    self.accounts.clearRetainingCapacity();
}

fn accountExists(ptr: *anyopaque, address: Address) !bool {
    const self: *MemoryBackend = @ptrCast(@alignCast(ptr));
    return self.accounts.contains(address);
}

fn loadAccount(ptr: *anyopaque, allocator: std.mem.Allocator, address: Address) !?AccountState {
    const self: *MemoryBackend = @ptrCast(@alignCast(ptr));
    const account = self.accounts.getPtr(address) orelse return null;
    return try account.clone(allocator);
}

fn getStorage(ptr: *anyopaque, address: Address, key: u256) !u256 {
    const self: *MemoryBackend = @ptrCast(@alignCast(ptr));
    const account = self.accounts.getPtr(address) orelse return 0;
    return account.getStorage(key);
}

fn accountHasStorage(ptr: *anyopaque, address: Address) !bool {
    const self: *MemoryBackend = @ptrCast(@alignCast(ptr));
    const account = self.accounts.getPtr(address) orelse return false;
    return account.storage.count() != 0;
}

test "memory backend implements state backend reads" {
    const address = address_mod.addr(0xabc);
    var memory = MemoryBackend.init(std.testing.allocator);
    defer memory.deinit();

    var account = try memory.getOrCreateAccount(address);
    account.balance = 99;
    try account.setCode(std.testing.allocator, &.{0x5f});
    try account.storage.put(7, 0xaa);

    const state_backend = memory.backend();
    try std.testing.expect(try state_backend.accountExists(address));
    try std.testing.expectEqual(@as(u256, 0xaa), try state_backend.getStorage(address, 7));
    try std.testing.expect(try state_backend.accountHasStorage(address));

    var loaded = (try state_backend.loadAccount(std.testing.allocator, address)).?;
    defer loaded.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u256, 99), loaded.balance);
    try std.testing.expectEqualSlices(u8, &.{0x5f}, loaded.code);
}

test "memory backend can be seeded with an owned account" {
    const address = address_mod.addr(0xdef);
    var memory = MemoryBackend.init(std.testing.allocator);
    defer memory.deinit();

    var account = AccountState.init(std.testing.allocator);
    account.balance = 11;
    try account.storage.put(1, 2);
    try memory.putAccount(address, account);

    const state_backend = memory.backend();
    try std.testing.expect(try state_backend.accountExists(address));
    try std.testing.expectEqual(@as(u256, 2), try state_backend.getStorage(address, 1));
}
