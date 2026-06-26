//! Executor-owned execution overlay for a transaction or nested call.
//!
//! `Backend` provides canonical reads. `Overlay` owns loaded accounts, writes,
//! warm access state, transient storage, logs, snapshots, reverts, and the
//! future journal.

const std = @import("std");
const Host = @import("../Host.zig");
const address_mod = @import("../address.zig");
const Spec = @import("../spec.zig").Spec;
const Address = address_mod.Address;
const AccountState = @import("./Account.zig");
const Storage = @import("./Storage.zig");
const StorageKey = Storage.Key;
const StateBackend = @import("./Backend.zig");

const Overlay = @This();
const AccountMap = std.AutoHashMap(Address, AccountState);
const AddressSet = std.AutoHashMap(Address, void);
const StorageSet = std.AutoHashMap(StorageKey, void);
const StorageMap = std.AutoHashMap(StorageKey, u256);
// TSTORE can remove zero values and rewrite the same slots later in a transaction;
// ArrayHashMap avoids tombstone buildup on that churn-prone path.
const TransientStorageMap = std.array_hash_map.Auto(StorageKey, u256);

allocator: std.mem.Allocator,
backend: ?StateBackend,
accounts: AccountMap,
warm_accounts: AddressSet,
warm_storage: StorageSet,
original_storage: StorageMap,
storage_overlay: StorageMap,
transient_storage: TransientStorageMap,
selfdestructed_accounts: AddressSet,
created_contracts: AddressSet,
deleted_accounts: AddressSet,
logs: std.ArrayList(Host.Log),

pub fn init(allocator: std.mem.Allocator) Overlay {
    return .{
        .allocator = allocator,
        .backend = null,
        .accounts = AccountMap.init(allocator),
        .warm_accounts = AddressSet.init(allocator),
        .warm_storage = StorageSet.init(allocator),
        .original_storage = StorageMap.init(allocator),
        .storage_overlay = StorageMap.init(allocator),
        .transient_storage = .empty,
        .selfdestructed_accounts = AddressSet.init(allocator),
        .created_contracts = AddressSet.init(allocator),
        .deleted_accounts = AddressSet.init(allocator),
        .logs = .empty,
    };
}

pub fn initWithBackend(allocator: std.mem.Allocator, backend: StateBackend) Overlay {
    var result = Overlay.init(allocator);
    result.backend = backend;
    return result;
}

pub fn deinit(self: *Overlay) void {
    self.clearAccounts();
    self.accounts.deinit();
    self.warm_accounts.deinit();
    self.warm_storage.deinit();
    self.original_storage.deinit();
    self.storage_overlay.deinit();
    self.transient_storage.deinit(self.allocator);
    self.selfdestructed_accounts.deinit();
    self.created_contracts.deinit();
    self.deleted_accounts.deinit();
    self.logs.deinit(self.allocator);
}

pub fn getAccount(self: *Overlay, address: Address) ?*AccountState {
    return self.accounts.getPtr(address);
}

pub fn getAccountOrLoad(self: *Overlay, address: Address) !?*AccountState {
    if (self.deleted_accounts.contains(address)) return null;
    if (self.accounts.getPtr(address)) |account| return account;
    const backend = self.backend orelse return null;
    if (try backend.loadAccount(self.allocator, address)) |account| {
        var loaded = account;
        errdefer loaded.deinit(self.allocator);
        try self.accounts.put(address, loaded);
        return self.accounts.getPtr(address).?;
    }
    return null;
}

pub fn getOrCreateAccount(self: *Overlay, address: Address) !*AccountState {
    const was_deleted = self.deleted_accounts.remove(address);
    if (was_deleted) {
        try self.accounts.put(address, AccountState.init(self.allocator));
        return self.accounts.getPtr(address).?;
    }
    if (try self.getAccountOrLoad(address)) |account| return account;
    if (!self.accounts.contains(address)) {
        try self.accounts.put(address, AccountState.init(self.allocator));
    }
    return self.accounts.getPtr(address).?;
}

pub fn accountExists(self: *Overlay, address: Address) !bool {
    if (self.deleted_accounts.contains(address)) return false;
    if (self.accounts.contains(address)) return true;
    const backend = self.backend orelse return false;
    return backend.accountExists(address);
}

pub fn getCode(self: *Overlay, address: Address) ![]const u8 {
    const account = try self.getAccountOrLoad(address) orelse return &.{};
    return account.code;
}

pub fn getBalance(self: *Overlay, address: Address) !u256 {
    const account = try self.getAccountOrLoad(address) orelse return 0;
    return account.balance;
}

pub fn getStorage(self: *Overlay, address: Address, key: u256) !u256 {
    if (self.deleted_accounts.contains(address)) return 0;
    const storage_key = StorageKey{ .address = address, .key = key };
    if (self.storage_overlay.get(storage_key)) |value| return value;
    if (self.accounts.getPtr(address)) |account| {
        if (account.storage.get(key)) |value| return value;
    }
    const backend = self.backend orelse return 0;
    return backend.getStorage(address, key);
}

pub fn setStorage(self: *Overlay, address: Address, key: u256, value: u256) !Host.StorageStatus {
    const storage_key = StorageKey{ .address = address, .key = key };
    const had_original = self.original_storage.contains(storage_key);
    const original = try self.originalStorage(address, key);
    const current = if (had_original) try self.getStorage(address, key) else original;
    const account = try self.getOrCreateAccount(address);

    try self.storage_overlay.put(storage_key, value);
    if (value == 0) {
        _ = account.storage.remove(key);
    } else {
        try account.storage.put(key, value);
    }
    return Storage.status(original, current, value);
}

pub fn originalStorage(self: *Overlay, address: Address, key: u256) !u256 {
    const storage_key = StorageKey{ .address = address, .key = key };
    if (self.original_storage.get(storage_key)) |value| return value;
    const value = try self.getStorage(address, key);
    try self.original_storage.put(storage_key, value);
    return value;
}

pub fn accountHasStorage(self: *Overlay, address: Address) !bool {
    if (self.deleted_accounts.contains(address)) return false;
    if (self.accounts.getPtr(address)) |account| {
        if (account.storage.count() != 0) return true;
    }
    const backend = self.backend orelse return false;
    return backend.accountHasStorage(address);
}

pub fn beginTransaction(self: *Overlay) void {
    self.warm_accounts.clearRetainingCapacity();
    self.warm_storage.clearRetainingCapacity();
    self.transient_storage.clearRetainingCapacity();
    self.original_storage.clearRetainingCapacity();
}

pub fn warmAccount(self: *Overlay, address: Address) !void {
    try self.warm_accounts.put(address, {});
}

pub fn warmStorage(self: *Overlay, address: Address, key: u256) !void {
    try self.warm_storage.put(.{ .address = address, .key = key }, {});
}

pub fn getTransientStorage(self: *Overlay, address: Address, key: u256) u256 {
    return self.transient_storage.get(.{ .address = address, .key = key }) orelse 0;
}

pub fn setTransientStorage(self: *Overlay, address: Address, key: u256, value: u256) !void {
    const storage_key = StorageKey{ .address = address, .key = key };
    if (value == 0) {
        _ = self.transient_storage.swapRemove(storage_key);
    } else {
        try self.transient_storage.put(self.allocator, storage_key, value);
    }
}

pub fn snapshot(self: *Overlay) !Snapshot {
    var result = Snapshot{
        .accounts = AccountMap.init(self.allocator),
        .warm_accounts = AddressSet.init(self.allocator),
        .warm_storage = StorageSet.init(self.allocator),
        .storage_overlay = StorageMap.init(self.allocator),
        .transient_storage = .empty,
        .selfdestructed_accounts = AddressSet.init(self.allocator),
        .created_contracts = AddressSet.init(self.allocator),
        .deleted_accounts = AddressSet.init(self.allocator),
        .logs_len = self.logs.items.len,
    };
    errdefer result.deinit(self.allocator);

    var account_it = self.accounts.iterator();
    while (account_it.next()) |entry| {
        var account = try entry.value_ptr.clone(self.allocator);
        errdefer account.deinit(self.allocator);
        try result.accounts.put(entry.key_ptr.*, account);
    }

    var warm_account_it = self.warm_accounts.keyIterator();
    while (warm_account_it.next()) |address| {
        try result.warm_accounts.put(address.*, {});
    }

    var warm_storage_it = self.warm_storage.keyIterator();
    while (warm_storage_it.next()) |key| {
        try result.warm_storage.put(key.*, {});
    }

    var storage_overlay_it = self.storage_overlay.iterator();
    while (storage_overlay_it.next()) |entry| {
        try result.storage_overlay.put(entry.key_ptr.*, entry.value_ptr.*);
    }

    var transient_it = self.transient_storage.iterator();
    while (transient_it.next()) |entry| {
        try result.transient_storage.put(self.allocator, entry.key_ptr.*, entry.value_ptr.*);
    }

    var selfdestruct_it = self.selfdestructed_accounts.keyIterator();
    while (selfdestruct_it.next()) |address| {
        try result.selfdestructed_accounts.put(address.*, {});
    }

    var created_it = self.created_contracts.keyIterator();
    while (created_it.next()) |address| {
        try result.created_contracts.put(address.*, {});
    }

    var deleted_it = self.deleted_accounts.keyIterator();
    while (deleted_it.next()) |address| {
        try result.deleted_accounts.put(address.*, {});
    }

    return result;
}

pub fn restore(self: *Overlay, snapshot_state: *Snapshot) !void {
    self.clearAccounts();
    self.warm_accounts.clearRetainingCapacity();
    self.warm_storage.clearRetainingCapacity();
    self.storage_overlay.clearRetainingCapacity();
    self.transient_storage.clearRetainingCapacity();
    self.selfdestructed_accounts.clearRetainingCapacity();
    self.created_contracts.clearRetainingCapacity();
    self.deleted_accounts.clearRetainingCapacity();
    self.logs.items.len = snapshot_state.logs_len;

    var account_it = snapshot_state.accounts.iterator();
    while (account_it.next()) |entry| {
        var account = try entry.value_ptr.clone(self.allocator);
        errdefer account.deinit(self.allocator);
        try self.accounts.put(entry.key_ptr.*, account);
    }

    var warm_account_it = snapshot_state.warm_accounts.keyIterator();
    while (warm_account_it.next()) |address| {
        try self.warm_accounts.put(address.*, {});
    }

    var warm_storage_it = snapshot_state.warm_storage.keyIterator();
    while (warm_storage_it.next()) |key| {
        try self.warm_storage.put(key.*, {});
    }

    var storage_overlay_it = snapshot_state.storage_overlay.iterator();
    while (storage_overlay_it.next()) |entry| {
        try self.storage_overlay.put(entry.key_ptr.*, entry.value_ptr.*);
    }

    var transient_it = snapshot_state.transient_storage.iterator();
    while (transient_it.next()) |entry| {
        try self.transient_storage.put(self.allocator, entry.key_ptr.*, entry.value_ptr.*);
    }

    var selfdestruct_it = snapshot_state.selfdestructed_accounts.keyIterator();
    while (selfdestruct_it.next()) |address| {
        try self.selfdestructed_accounts.put(address.*, {});
    }

    var created_it = snapshot_state.created_contracts.keyIterator();
    while (created_it.next()) |address| {
        try self.created_contracts.put(address.*, {});
    }

    var deleted_it = snapshot_state.deleted_accounts.keyIterator();
    while (deleted_it.next()) |address| {
        try self.deleted_accounts.put(address.*, {});
    }
}

pub fn restoreRevertible(self: *Overlay, snapshot_state: *Snapshot) !void {
    self.clearAccounts();
    self.warm_accounts.clearRetainingCapacity();
    self.warm_storage.clearRetainingCapacity();
    self.storage_overlay.clearRetainingCapacity();
    self.transient_storage.clearRetainingCapacity();
    self.selfdestructed_accounts.clearRetainingCapacity();
    self.created_contracts.clearRetainingCapacity();
    self.deleted_accounts.clearRetainingCapacity();
    self.logs.items.len = snapshot_state.logs_len;

    var account_it = snapshot_state.accounts.iterator();
    while (account_it.next()) |entry| {
        var account = try entry.value_ptr.clone(self.allocator);
        errdefer account.deinit(self.allocator);
        try self.accounts.put(entry.key_ptr.*, account);
    }

    var warm_account_it = snapshot_state.warm_accounts.keyIterator();
    while (warm_account_it.next()) |address| {
        try self.warm_accounts.put(address.*, {});
    }

    var warm_storage_it = snapshot_state.warm_storage.keyIterator();
    while (warm_storage_it.next()) |key| {
        try self.warm_storage.put(key.*, {});
    }

    var storage_overlay_it = snapshot_state.storage_overlay.iterator();
    while (storage_overlay_it.next()) |entry| {
        try self.storage_overlay.put(entry.key_ptr.*, entry.value_ptr.*);
    }

    var transient_it = snapshot_state.transient_storage.iterator();
    while (transient_it.next()) |entry| {
        try self.transient_storage.put(self.allocator, entry.key_ptr.*, entry.value_ptr.*);
    }

    var selfdestruct_it = snapshot_state.selfdestructed_accounts.keyIterator();
    while (selfdestruct_it.next()) |address| {
        try self.selfdestructed_accounts.put(address.*, {});
    }

    var created_it = snapshot_state.created_contracts.keyIterator();
    while (created_it.next()) |address| {
        try self.created_contracts.put(address.*, {});
    }

    var deleted_it = snapshot_state.deleted_accounts.keyIterator();
    while (deleted_it.next()) |address| {
        try self.deleted_accounts.put(address.*, {});
    }
}

pub fn clearAccounts(self: *Overlay) void {
    var account_it = self.accounts.valueIterator();
    while (account_it.next()) |account| {
        account.deinit(self.allocator);
    }
    self.accounts.clearRetainingCapacity();
}

pub fn finalizeTransaction(self: *Overlay, spec: Spec) !void {
    var it = self.selfdestructed_accounts.keyIterator();
    while (it.next()) |address| {
        if (spec.isImpl(.cancun) and !self.created_contracts.contains(address.*)) continue;
        if (self.accounts.fetchRemove(address.*)) |removed| {
            var account = removed.value;
            account.deinit(self.allocator);
        }
        try self.removeStorageForAddress(address.*);
        try self.deleted_accounts.put(address.*, {});
    }
    self.selfdestructed_accounts.clearRetainingCapacity();
    self.created_contracts.clearRetainingCapacity();
}

fn removeStorageForAddress(self: *Overlay, address: Address) !void {
    var keys: std.ArrayList(StorageKey) = .empty;
    defer keys.deinit(self.allocator);

    var it = self.storage_overlay.keyIterator();
    while (it.next()) |key| {
        if (std.mem.eql(u8, &key.address, &address)) {
            try keys.append(self.allocator, key.*);
        }
    }

    for (keys.items) |key| {
        _ = self.storage_overlay.remove(key);
    }
}

pub fn snapshotTransient(self: *Overlay) !TransientSnapshot {
    var result = TransientSnapshot{
        .transient_storage = .empty,
    };
    errdefer result.deinit(self.allocator);

    var transient_it = self.transient_storage.iterator();
    while (transient_it.next()) |entry| {
        try result.transient_storage.put(self.allocator, entry.key_ptr.*, entry.value_ptr.*);
    }

    return result;
}

pub fn restoreTransient(self: *Overlay, snapshot_state: *TransientSnapshot) !void {
    self.transient_storage.clearRetainingCapacity();

    var transient_it = snapshot_state.transient_storage.iterator();
    while (transient_it.next()) |entry| {
        try self.transient_storage.put(self.allocator, entry.key_ptr.*, entry.value_ptr.*);
    }
}

pub const Snapshot = struct {
    accounts: AccountMap,
    warm_accounts: AddressSet,
    warm_storage: StorageSet,
    storage_overlay: StorageMap,
    transient_storage: TransientStorageMap,
    selfdestructed_accounts: AddressSet,
    created_contracts: AddressSet,
    deleted_accounts: AddressSet,
    logs_len: usize,

    pub fn deinit(self: *Snapshot, allocator: std.mem.Allocator) void {
        var account_it = self.accounts.valueIterator();
        while (account_it.next()) |account| {
            account.deinit(allocator);
        }
        self.accounts.deinit();
        self.warm_accounts.deinit();
        self.warm_storage.deinit();
        self.storage_overlay.deinit();
        self.transient_storage.deinit(allocator);
        self.selfdestructed_accounts.deinit();
        self.created_contracts.deinit();
        self.deleted_accounts.deinit();
    }
};

pub const TransientSnapshot = struct {
    transient_storage: TransientStorageMap,

    pub fn deinit(self: *TransientSnapshot, allocator: std.mem.Allocator) void {
        self.transient_storage.deinit(allocator);
    }
};

test "snapshot restores accounts and warm state" {
    var overlay = Overlay.init(std.testing.allocator);
    defer overlay.deinit();

    const test_address = address_mod.addr(1);
    var account = try overlay.getOrCreateAccount(test_address);
    account.balance = 7;
    try overlay.warm_accounts.put(test_address, {});

    var snapshot_state = try overlay.snapshot();
    defer snapshot_state.deinit(std.testing.allocator);

    account = try overlay.getOrCreateAccount(test_address);
    account.balance = 9;
    overlay.warm_accounts.clearRetainingCapacity();

    try overlay.restore(&snapshot_state);
    try std.testing.expectEqual(@as(u256, 7), overlay.getAccount(test_address).?.balance);
    try std.testing.expect(overlay.warm_accounts.contains(test_address));
}

test "revertible snapshot restores warm state" {
    var overlay = Overlay.init(std.testing.allocator);
    defer overlay.deinit();

    const warm_before = address_mod.addr(1);
    const warm_after = address_mod.addr(2);
    try overlay.warm_accounts.put(warm_before, {});
    try overlay.warm_storage.put(.{ .address = warm_before, .key = 1 }, {});

    var snapshot_state = try overlay.snapshot();
    defer snapshot_state.deinit(std.testing.allocator);

    try overlay.warm_accounts.put(warm_after, {});
    try overlay.warm_storage.put(.{ .address = warm_after, .key = 2 }, {});

    try overlay.restoreRevertible(&snapshot_state);
    try std.testing.expect(overlay.warm_accounts.contains(warm_before));
    try std.testing.expect(!overlay.warm_accounts.contains(warm_after));
    try std.testing.expect(overlay.warm_storage.contains(.{ .address = warm_before, .key = 1 }));
    try std.testing.expect(!overlay.warm_storage.contains(.{ .address = warm_after, .key = 2 }));
}

const TestBackend = struct {
    address: Address,
    key: u256,
    value: u256,
    balance: u256,
    load_count: usize = 0,
    storage_reads: usize = 0,

    fn backend(self: *TestBackend) StateBackend {
        return .{ .ptr = self, .vtable = &.{
            .accountExists = backendAccountExists,
            .loadAccount = backendLoadAccount,
            .getStorage = backendGetStorage,
            .accountHasStorage = backendAccountHasStorage,
        } };
    }

    fn backendAccountExists(ptr: *anyopaque, address: Address) !bool {
        const self: *TestBackend = @ptrCast(@alignCast(ptr));
        return std.mem.eql(u8, &self.address, &address);
    }

    fn backendLoadAccount(ptr: *anyopaque, allocator: std.mem.Allocator, address: Address) !?AccountState {
        const self: *TestBackend = @ptrCast(@alignCast(ptr));
        if (!std.mem.eql(u8, &self.address, &address)) return null;
        self.load_count += 1;

        var account = AccountState.init(allocator);
        errdefer account.deinit(allocator);
        account.balance = self.balance;
        try account.setCode(allocator, &.{0x5f});
        return account;
    }

    fn backendGetStorage(ptr: *anyopaque, address: Address, key: u256) !u256 {
        const self: *TestBackend = @ptrCast(@alignCast(ptr));
        self.storage_reads += 1;
        if (std.mem.eql(u8, &self.address, &address) and key == self.key) return self.value;
        return 0;
    }

    fn backendAccountHasStorage(ptr: *anyopaque, address: Address) !bool {
        const self: *TestBackend = @ptrCast(@alignCast(ptr));
        return std.mem.eql(u8, &self.address, &address) and self.value != 0;
    }
};

test "backend loads account and storage lazily" {
    const address = address_mod.addr(0xbeef);
    var backend = TestBackend{
        .address = address,
        .key = 7,
        .value = 0xab,
        .balance = 0x1234,
    };
    var overlay = Overlay.initWithBackend(std.testing.allocator, backend.backend());
    defer overlay.deinit();

    try std.testing.expect(try overlay.accountExists(address));
    try std.testing.expectEqual(@as(u256, 0x1234), try overlay.getBalance(address));
    try std.testing.expectEqualSlices(u8, &.{0x5f}, try overlay.getCode(address));
    try std.testing.expectEqual(@as(u256, 0xab), try overlay.getStorage(address, 7));
    try std.testing.expectEqual(@as(usize, 1), backend.load_count);
    try std.testing.expectEqual(@as(usize, 1), backend.storage_reads);
}

test "zero storage write masks backend value" {
    const address = address_mod.addr(0xbeef);
    var backend = TestBackend{
        .address = address,
        .key = 7,
        .value = 0xab,
        .balance = 0,
    };
    var overlay = Overlay.initWithBackend(std.testing.allocator, backend.backend());
    defer overlay.deinit();

    overlay.beginTransaction();
    try std.testing.expectEqual(Host.StorageStatus.deleted, try overlay.setStorage(address, 7, 0));
    try std.testing.expectEqual(@as(u256, 0), try overlay.getStorage(address, 7));
    try std.testing.expectEqual(@as(usize, 1), backend.storage_reads);
}
