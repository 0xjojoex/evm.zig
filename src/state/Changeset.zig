//! Typed state delta emitted by `Overlay` after transaction finalization.
//!
//! This is the write boundary for integrations: clients keep their trie/db as
//! the state reader, then commit this compact delta after successful execution.

const std = @import("std");

const Address = @import("../address.zig").Address;

const Changeset = @This();

pub const AccountUpdate = struct {
    address: Address,
    nonce: u64,
    balance: u256,
    code: []u8,
};

pub const StorageWrite = struct {
    address: Address,
    key: u256,
    value: u256,
};

account_updates: std.ArrayList(AccountUpdate),
account_deletes: std.ArrayList(Address),
storage_writes: std.ArrayList(StorageWrite),

pub fn init() Changeset {
    return .{
        .account_updates = .empty,
        .account_deletes = .empty,
        .storage_writes = .empty,
    };
}

pub fn deinit(self: *Changeset, allocator: std.mem.Allocator) void {
    for (self.account_updates.items) |update| {
        allocator.free(update.code);
    }
    self.account_updates.deinit(allocator);
    self.account_deletes.deinit(allocator);
    self.storage_writes.deinit(allocator);
}

pub fn sort(self: *Changeset) void {
    std.mem.sort(AccountUpdate, self.account_updates.items, {}, accountUpdateLessThan);
    std.mem.sort(Address, self.account_deletes.items, {}, addressLessThan);
    std.mem.sort(StorageWrite, self.storage_writes.items, {}, storageWriteLessThan);
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
