//! In-memory state store for tests, demos, fixtures, and lightweight embeds.
//!
//! `reader()` exposes the read-only `StateReader` adapter. `committer()` applies
//! final changesets back into this canonical memory store. It is not the
//! execution overlay: speculative writes, checkpoints, reverts, logs, warmth,
//! and the journal live in `Overlay`.

const std = @import("std");

const evmz = @import("../evm.zig");
const AccountState = @import("./Account.zig");
const Changeset = @import("./Changeset.zig");
const Committer = @import("./Committer.zig");
const StateReader = @import("./Reader.zig");
const TouchedHashMap = @import("./TouchedHashMap.zig");

const Address = evmz.Address;
const addr = evmz.addr;

const MemoryStore = @This();

allocator: std.mem.Allocator,
accounts: TouchedHashMap.Auto(Address, AccountState),

pub fn init(allocator: std.mem.Allocator) MemoryStore {
    return .{
        .allocator = allocator,
        .accounts = TouchedHashMap.Auto(Address, AccountState).init(allocator),
    };
}

pub fn deinit(self: *MemoryStore) void {
    self.clearAccounts();
    self.accounts.deinit();
}

pub fn reader(self: *MemoryStore) StateReader {
    return .{ .ptr = self, .vtable = &.{
        .accountExists = accountExists,
        .loadAccount = loadAccount,
        .getStorage = getStorage,
        .accountHasStorage = accountHasStorage,
    } };
}

pub fn committer(self: *MemoryStore) Committer {
    return .{ .ptr = self, .vtable = &.{
        .commit = commit,
    } };
}

pub fn getAccount(self: *MemoryStore, address: Address) ?*AccountState {
    return self.accounts.getPtr(address);
}

pub fn getOrCreateAccount(self: *MemoryStore, address: Address) !*AccountState {
    if (!self.accounts.contains(address)) {
        try self.accounts.put(address, AccountState.init(self.allocator));
    }
    return self.accounts.getPtr(address).?;
}

/// Inserts an owned account into the in-memory pre-state.
/// The store will deinit the account with its allocator.
pub fn putAccount(self: *MemoryStore, address: Address, account: AccountState) !void {
    if (self.accounts.fetchRemove(address)) |removed| {
        var old_account = removed.value;
        old_account.deinit(self.allocator);
    }
    try self.accounts.put(address, account);
}

pub fn clearAccounts(self: *MemoryStore) void {
    var account_it = self.accounts.valueIterator();
    while (account_it.next()) |account| {
        account.deinit(self.allocator);
    }
    self.accounts.clearRetainingCapacity();
}

pub fn applyChangeset(self: *MemoryStore, changeset: *const Changeset) !void {
    for (changeset.account_deletes.items) |address| {
        if (self.accounts.fetchRemove(address)) |removed| {
            var account = removed.value;
            account.deinit(self.allocator);
        }
    }

    for (changeset.account_updates.items) |update| {
        const account = try self.getOrCreateAccount(update.address);
        account.nonce = update.nonce;
        account.balance = update.balance;
        try account.setCode(self.allocator, update.code);
    }

    for (changeset.storage_writes.items) |write| {
        if (write.value == 0) {
            if (self.accounts.getPtr(write.address)) |account| {
                _ = account.storage.remove(write.key);
            }
        } else {
            const account = try self.getOrCreateAccount(write.address);
            try account.storage.put(write.key, write.value);
        }
    }
}

fn commit(ptr: *anyopaque, changeset: *const Changeset) !void {
    const self: *MemoryStore = @ptrCast(@alignCast(ptr));
    try self.applyChangeset(changeset);
}

fn accountExists(ptr: *anyopaque, address: Address) !bool {
    const self: *MemoryStore = @ptrCast(@alignCast(ptr));
    return self.accounts.contains(address);
}

fn loadAccount(ptr: *anyopaque, allocator: std.mem.Allocator, address: Address) !?AccountState {
    const self: *MemoryStore = @ptrCast(@alignCast(ptr));
    const account = self.accounts.getPtr(address) orelse return null;
    return try account.clone(allocator);
}

fn getStorage(ptr: *anyopaque, address: Address, key: u256) !u256 {
    const self: *MemoryStore = @ptrCast(@alignCast(ptr));
    const account = self.accounts.getPtr(address) orelse return 0;
    return account.getStorage(key);
}

fn accountHasStorage(ptr: *anyopaque, address: Address) !bool {
    const self: *MemoryStore = @ptrCast(@alignCast(ptr));
    const account = self.accounts.getPtr(address) orelse return false;
    return account.storage.count() != 0;
}

test "memory store exposes state reader" {
    const address = addr(0xabc);
    var memory = MemoryStore.init(std.testing.allocator);
    defer memory.deinit();

    var account = try memory.getOrCreateAccount(address);
    account.balance = 99;
    try account.setCode(std.testing.allocator, &.{0x5f});
    try account.storage.put(7, 0xaa);

    const state_reader = memory.reader();
    try std.testing.expect(try state_reader.accountExists(address));
    try std.testing.expectEqual(@as(u256, 0xaa), try state_reader.getStorage(address, 7));
    try std.testing.expect(try state_reader.accountHasStorage(address));

    var loaded = (try state_reader.loadAccount(std.testing.allocator, address)).?;
    defer loaded.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u256, 99), loaded.balance);
    try std.testing.expectEqualSlices(u8, &.{0x5f}, loaded.code);
}

test "memory store can be seeded with an owned account" {
    const address = addr(0xdef);
    var memory = MemoryStore.init(std.testing.allocator);
    defer memory.deinit();

    var account = AccountState.init(std.testing.allocator);
    account.balance = 11;
    try account.storage.put(1, 2);
    try memory.putAccount(address, account);

    const state_reader = memory.reader();
    try std.testing.expect(try state_reader.accountExists(address));
    try std.testing.expectEqual(@as(u256, 2), try state_reader.getStorage(address, 1));
}

test "memory store applies changeset updates and storage writes" {
    const address = addr(0xbeef);
    var memory = MemoryStore.init(std.testing.allocator);
    defer memory.deinit();

    var account = try memory.getOrCreateAccount(address);
    account.balance = 1;
    account.nonce = 2;
    try account.setCode(std.testing.allocator, &.{0x5f});
    try account.storage.put(1, 1);
    try account.storage.put(2, 2);

    var delta = Changeset.init();
    defer delta.deinit(std.testing.allocator);
    {
        const code = try std.testing.allocator.dupe(u8, &.{ 0xaa, 0xbb });
        errdefer std.testing.allocator.free(code);
        try delta.account_updates.append(std.testing.allocator, .{
            .address = address,
            .nonce = 3,
            .balance = 9,
            .code = code,
        });
    }
    try delta.storage_writes.append(std.testing.allocator, .{
        .address = address,
        .key = 1,
        .value = 0,
    });
    try delta.storage_writes.append(std.testing.allocator, .{
        .address = address,
        .key = 2,
        .value = 22,
    });
    try delta.storage_writes.append(std.testing.allocator, .{
        .address = address,
        .key = 3,
        .value = 33,
    });

    try memory.applyChangeset(&delta);

    const updated = memory.getAccount(address).?;
    try std.testing.expectEqual(@as(u256, 9), updated.balance);
    try std.testing.expectEqual(@as(u64, 3), updated.nonce);
    try std.testing.expectEqualSlices(u8, &.{ 0xaa, 0xbb }, updated.code);
    try std.testing.expectEqual(@as(u256, 0), updated.getStorage(1));
    try std.testing.expectEqual(@as(u256, 22), updated.getStorage(2));
    try std.testing.expectEqual(@as(u256, 33), updated.getStorage(3));
}

test "memory store applies account deletes" {
    const address = addr(0xd1e);
    var memory = MemoryStore.init(std.testing.allocator);
    defer memory.deinit();

    _ = try memory.getOrCreateAccount(address);

    var delta = Changeset.init();
    defer delta.deinit(std.testing.allocator);
    try delta.account_deletes.append(std.testing.allocator, address);

    try memory.applyChangeset(&delta);

    try std.testing.expect(memory.getAccount(address) == null);
}

test "memory store exposes committer adapter" {
    const address = addr(0xc0de);
    var memory = MemoryStore.init(std.testing.allocator);
    defer memory.deinit();

    var delta = Changeset.init();
    defer delta.deinit(std.testing.allocator);
    try delta.storage_writes.append(std.testing.allocator, .{
        .address = address,
        .key = 7,
        .value = 99,
    });

    try memory.committer().commit(&delta);

    try std.testing.expectEqual(@as(u256, 99), memory.getAccount(address).?.getStorage(7));
}
