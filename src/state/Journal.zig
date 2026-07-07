//! Reversible execution journal for `Overlay` checkpoint rollback.

const std = @import("std");
const evmz = @import("../evm.zig");
const AccountState = @import("./Account.zig");
const storage = @import("./storage.zig");

const Journal = @This();

const Address = evmz.Address;
const StorageKey = storage.Key;

items: std.ArrayList(Entry),
capacity_limit: ?usize,

pub const Checkpoint = struct {
    journal_len: usize,
    logs_len: usize,
};

pub const Entry = union(enum) {
    account_created: Address,
    deleted_account_revived: Address,
    dirty_account: Address,
    balance: struct {
        address: Address,
        prev: u256,
    },
    nonce: struct {
        address: Address,
        prev: u64,
    },
    code: struct {
        address: Address,
        prev: []u8,
    },
    account_removed: struct {
        address: Address,
        prev: ?AccountState,
    },
    storage: struct {
        address: Address,
        key: u256,
        overlay_had: bool,
        overlay_prev: u256,
    },
    transient_storage: struct {
        address: Address,
        key: u256,
        had_value: bool,
        prev: u256,
    },
    warm_account: Address,
    warm_storage: StorageKey,
    created_contract: Address,
    selfdestruct: Address,
    deleted_account_marked: Address,
    created_contract_cleared: Address,
    selfdestruct_cleared: Address,
    storage_overlay_removed: struct {
        key: StorageKey,
        prev: u256,
    },

    pub fn deinit(self: *Entry, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .code => |code| allocator.free(code.prev),
            .account_removed => |*removed| {
                if (removed.prev) |*account| {
                    account.deinit(allocator);
                }
            },
            else => {},
        }
        self.* = undefined;
    }
};

pub fn init() Journal {
    return .{
        .items = .empty,
        .capacity_limit = null,
    };
}

pub fn deinit(self: *Journal, allocator: std.mem.Allocator) void {
    self.clearRetainingCapacity(allocator);
    self.items.deinit(allocator);
}

pub fn checkpoint(self: *const Journal, logs_len: usize) Checkpoint {
    return .{
        .journal_len = self.items.items.len,
        .logs_len = logs_len,
    };
}

pub fn len(self: *const Journal) usize {
    return self.items.items.len;
}

pub fn configureCapacity(self: *Journal, allocator: std.mem.Allocator, capacity: ?usize) !void {
    if (self.items.items.len != 0) return error.ActiveJournal;
    if (capacity) |limit| {
        try self.items.ensureTotalCapacityPrecise(allocator, limit);
        self.capacity_limit = limit;
    } else {
        self.capacity_limit = null;
    }
}

pub fn append(self: *Journal, allocator: std.mem.Allocator, entry: Entry) !void {
    if (self.capacity_limit) |limit| {
        if (self.items.items.len >= limit) return error.JournalCapacityExceeded;
        std.debug.assert(self.items.capacity >= limit);
        self.items.appendAssumeCapacity(entry);
        return;
    }
    try self.items.append(allocator, entry);
}

pub fn pop(self: *Journal) ?Entry {
    if (self.items.items.len == 0) return null;
    const index = self.items.items.len - 1;
    const entry = self.items.items[index];
    self.items.items.len = index;
    return entry;
}

pub fn truncate(self: *Journal, allocator: std.mem.Allocator, target_len: usize) void {
    while (self.items.items.len > target_len) {
        var entry = self.pop().?;
        entry.deinit(allocator);
    }
}

pub fn clearRetainingCapacity(self: *Journal, allocator: std.mem.Allocator) void {
    self.truncate(allocator, 0);
    self.items.clearRetainingCapacity();
}

test "checkpoint records journal and log lengths" {
    var journal = Journal.init();
    defer journal.deinit(std.testing.allocator);

    try journal.append(std.testing.allocator, .{ .warm_account = evmz.addr(1) });
    const checkpoint_state = journal.checkpoint(7);

    try std.testing.expectEqual(@as(usize, 1), checkpoint_state.journal_len);
    try std.testing.expectEqual(@as(usize, 7), checkpoint_state.logs_len);
}

test "bounded journal reports capacity exhaustion" {
    var journal = Journal.init();
    defer journal.deinit(std.testing.allocator);

    try journal.configureCapacity(std.testing.allocator, 1);
    try journal.append(std.testing.allocator, .{ .warm_account = evmz.addr(1) });
    try std.testing.expectError(
        error.JournalCapacityExceeded,
        journal.append(std.testing.allocator, .{ .warm_account = evmz.addr(2) }),
    );

    journal.clearRetainingCapacity(std.testing.allocator);
    try journal.append(std.testing.allocator, .{ .warm_account = evmz.addr(3) });
}

test "journal can switch back to growable capacity" {
    var journal = Journal.init();
    defer journal.deinit(std.testing.allocator);

    try journal.configureCapacity(std.testing.allocator, 0);
    try std.testing.expectError(
        error.JournalCapacityExceeded,
        journal.append(std.testing.allocator, .{ .warm_account = evmz.addr(1) }),
    );
    try journal.configureCapacity(std.testing.allocator, null);
    try journal.append(std.testing.allocator, .{ .warm_account = evmz.addr(1) });
}
