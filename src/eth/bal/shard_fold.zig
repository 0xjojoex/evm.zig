//! Canonical union of independently produced BAL shards.

const std = @import("std");
const bal = @import("model.zig");

const Allocator = std.mem.Allocator;

/// Shards may arrive in any order. Indexed changes are sorted by their
/// `BlockAccessIndex`; account and storage reads are unioned because the BAL
/// wire format does not position them. A storage read is removed when any
/// shard writes the same slot. Duplicate changes for one field at one index
/// indicate overlapping shard ownership and are rejected.
pub const ShardFold = struct {
    const Lifecycle = enum {
        building,
        failed,
        finished,
    };

    allocator: Allocator,
    accounts: std.ArrayList(FoldAccount) = .empty,
    account_indices: std.AutoHashMap(bal.Address, usize),
    lifecycle: Lifecycle = .building,

    pub const Error = Allocator.Error || error{
        DuplicateStorageChangeIndex,
        DuplicateBalanceChangeIndex,
        DuplicateNonceChangeIndex,
        DuplicateCodeChangeIndex,
        FoldAlreadyFinished,
        FoldFailed,
    };

    pub fn init(allocator: Allocator) ShardFold {
        return .{
            .allocator = allocator,
            .account_indices = .init(allocator),
        };
    }

    pub fn deinit(self: *ShardFold) void {
        for (self.accounts.items) |*account| account.deinit(self.allocator);
        self.accounts.deinit(self.allocator);
        self.account_indices.deinit();
        self.* = undefined;
    }

    pub fn append(self: *ShardFold, shard: bal.BlockAccessList) Error!void {
        switch (self.lifecycle) {
            .building => {},
            .failed => return error.FoldFailed,
            .finished => return error.FoldAlreadyFinished,
        }
        self.appendFallible(shard) catch |err| {
            self.lifecycle = .failed;
            return err;
        };
    }

    fn appendFallible(self: *ShardFold, shard: bal.BlockAccessList) Error!void {
        for (shard) |account| {
            const target = try self.accountFor(account.address);
            try target.append(self.allocator, account);
        }
    }

    /// Consume the fold and return one canonical, independently owned BAL.
    /// A failed finish cannot be retried; `deinit` remains valid.
    pub fn finish(self: *ShardFold) Error!bal.Decoded {
        switch (self.lifecycle) {
            .building => {},
            .failed => return error.FoldFailed,
            .finished => return error.FoldAlreadyFinished,
        }
        const result = self.finishFallible() catch |err| {
            self.lifecycle = .failed;
            return err;
        };
        self.lifecycle = .finished;
        return result;
    }

    fn finishFallible(self: *ShardFold) Error!bal.Decoded {
        std.mem.sort(FoldAccount, self.accounts.items, {}, foldAccountLessThan);

        var accounts: std.ArrayList(bal.AccountChanges) = .empty;
        errdefer {
            for (accounts.items) |*account| deinitAccount(self.allocator, account);
            accounts.deinit(self.allocator);
        }
        try accounts.ensureTotalCapacity(self.allocator, self.accounts.items.len);
        for (self.accounts.items) |*account| {
            var owned = try account.toOwnedAccount(self.allocator);
            errdefer deinitAccount(self.allocator, &owned);
            accounts.appendAssumeCapacity(owned);
        }
        return .{ .accounts = try accounts.toOwnedSlice(self.allocator) };
    }

    fn accountFor(self: *ShardFold, target: bal.Address) Error!*FoldAccount {
        if (self.account_indices.get(target)) |index| return &self.accounts.items[index];
        const index = self.accounts.items.len;
        try self.accounts.append(self.allocator, .{ .address = target });
        errdefer _ = self.accounts.pop();
        try self.account_indices.put(target, index);
        return &self.accounts.items[index];
    }
};

const FoldStorageChange = struct {
    slot: u256,
    block_access_index: bal.BlockAccessIndex,
    new_value: u256,
};

const FoldAccount = struct {
    address: bal.Address,
    storage_changes: std.ArrayList(FoldStorageChange) = .empty,
    storage_reads: std.ArrayList(u256) = .empty,
    balance_changes: std.ArrayList(bal.BalanceChange) = .empty,
    nonce_changes: std.ArrayList(bal.NonceChange) = .empty,
    code_changes: std.ArrayList(bal.CodeChange) = .empty,

    fn deinit(self: *FoldAccount, allocator: Allocator) void {
        self.storage_changes.deinit(allocator);
        self.storage_reads.deinit(allocator);
        self.balance_changes.deinit(allocator);
        self.nonce_changes.deinit(allocator);
        for (self.code_changes.items) |change| allocator.free(@constCast(change.new_code));
        self.code_changes.deinit(allocator);
        self.* = undefined;
    }

    fn append(self: *FoldAccount, allocator: Allocator, account: bal.AccountChanges) Allocator.Error!void {
        for (account.storage_changes) |slot| {
            for (slot.changes) |change| try self.storage_changes.append(allocator, .{
                .slot = slot.slot,
                .block_access_index = change.block_access_index,
                .new_value = change.new_value,
            });
        }
        try self.storage_reads.appendSlice(allocator, account.storage_reads);
        try self.balance_changes.appendSlice(allocator, account.balance_changes);
        try self.nonce_changes.appendSlice(allocator, account.nonce_changes);
        for (account.code_changes) |change| {
            const new_code = try allocator.dupe(u8, change.new_code);
            errdefer allocator.free(new_code);
            try self.code_changes.append(allocator, .{
                .block_access_index = change.block_access_index,
                .new_code = new_code,
            });
        }
    }

    fn toOwnedAccount(self: *FoldAccount, allocator: Allocator) ShardFold.Error!bal.AccountChanges {
        var result = bal.AccountChanges{ .address = self.address };
        errdefer deinitAccount(allocator, &result);

        result.storage_changes = try self.toOwnedStorageChanges(allocator);
        result.storage_reads = try self.toOwnedStorageReads(allocator, result.storage_changes);

        std.mem.sort(bal.BalanceChange, self.balance_changes.items, {}, balanceChangeLessThan);
        try rejectDuplicateBalanceIndices(self.balance_changes.items);
        result.balance_changes = try self.balance_changes.toOwnedSlice(allocator);

        std.mem.sort(bal.NonceChange, self.nonce_changes.items, {}, nonceChangeLessThan);
        try rejectDuplicateNonceIndices(self.nonce_changes.items);
        result.nonce_changes = try self.nonce_changes.toOwnedSlice(allocator);

        std.mem.sort(bal.CodeChange, self.code_changes.items, {}, codeChangeLessThan);
        try rejectDuplicateCodeIndices(self.code_changes.items);
        result.code_changes = try self.code_changes.toOwnedSlice(allocator);
        return result;
    }

    fn toOwnedStorageChanges(self: *FoldAccount, allocator: Allocator) ShardFold.Error![]const bal.SlotChanges {
        std.mem.sort(FoldStorageChange, self.storage_changes.items, {}, storageChangeLessThan);
        var slots: std.ArrayList(bal.SlotChanges) = .empty;
        errdefer {
            for (slots.items) |slot| allocator.free(@constCast(slot.changes));
            slots.deinit(allocator);
        }

        var index: usize = 0;
        while (index < self.storage_changes.items.len) {
            const slot = self.storage_changes.items[index].slot;
            var changes: std.ArrayList(bal.StorageChange) = .empty;
            errdefer changes.deinit(allocator);
            while (index < self.storage_changes.items.len and self.storage_changes.items[index].slot == slot) {
                const change = self.storage_changes.items[index];
                if (changes.getLastOrNull()) |previous| {
                    if (previous.block_access_index == change.block_access_index)
                        return error.DuplicateStorageChangeIndex;
                }
                try changes.append(allocator, .{
                    .block_access_index = change.block_access_index,
                    .new_value = change.new_value,
                });
                index += 1;
            }
            const owned_slot_changes = try changes.toOwnedSlice(allocator);
            errdefer allocator.free(owned_slot_changes);
            try slots.append(allocator, .{ .slot = slot, .changes = owned_slot_changes });
        }
        return try slots.toOwnedSlice(allocator);
    }

    fn toOwnedStorageReads(
        self: *FoldAccount,
        allocator: Allocator,
        storage_changes: []const bal.SlotChanges,
    ) Allocator.Error![]const u256 {
        std.mem.sort(u256, self.storage_reads.items, {}, u256LessThan);
        var reads: std.ArrayList(u256) = .empty;
        errdefer reads.deinit(allocator);

        var previous: ?u256 = null;
        var change_index: usize = 0;
        for (self.storage_reads.items) |slot| {
            if (previous != null and previous.? == slot) continue;
            previous = slot;
            while (change_index < storage_changes.len and storage_changes[change_index].slot < slot) change_index += 1;
            if (change_index < storage_changes.len and storage_changes[change_index].slot == slot) continue;
            try reads.append(allocator, slot);
        }
        return try reads.toOwnedSlice(allocator);
    }
};

fn rejectDuplicateBalanceIndices(changes: []const bal.BalanceChange) ShardFold.Error!void {
    if (changes.len < 2) return;
    for (changes[1..], changes[0..changes.len -| 1]) |current, previous| {
        if (current.block_access_index == previous.block_access_index) return error.DuplicateBalanceChangeIndex;
    }
}

fn rejectDuplicateNonceIndices(changes: []const bal.NonceChange) ShardFold.Error!void {
    if (changes.len < 2) return;
    for (changes[1..], changes[0..changes.len -| 1]) |current, previous| {
        if (current.block_access_index == previous.block_access_index) return error.DuplicateNonceChangeIndex;
    }
}

fn rejectDuplicateCodeIndices(changes: []const bal.CodeChange) ShardFold.Error!void {
    if (changes.len < 2) return;
    for (changes[1..], changes[0..changes.len -| 1]) |current, previous| {
        if (current.block_access_index == previous.block_access_index) return error.DuplicateCodeChangeIndex;
    }
}

fn foldAccountLessThan(_: void, lhs: FoldAccount, rhs: FoldAccount) bool {
    return std.mem.order(u8, &lhs.address, &rhs.address) == .lt;
}

fn storageChangeLessThan(_: void, lhs: FoldStorageChange, rhs: FoldStorageChange) bool {
    if (lhs.slot != rhs.slot) return lhs.slot < rhs.slot;
    return lhs.block_access_index < rhs.block_access_index;
}

fn balanceChangeLessThan(_: void, lhs: bal.BalanceChange, rhs: bal.BalanceChange) bool {
    return lhs.block_access_index < rhs.block_access_index;
}

fn nonceChangeLessThan(_: void, lhs: bal.NonceChange, rhs: bal.NonceChange) bool {
    return lhs.block_access_index < rhs.block_access_index;
}

fn codeChangeLessThan(_: void, lhs: bal.CodeChange, rhs: bal.CodeChange) bool {
    return lhs.block_access_index < rhs.block_access_index;
}

fn u256LessThan(_: void, lhs: u256, rhs: u256) bool {
    return lhs < rhs;
}

fn deinitAccount(allocator: Allocator, account: *const bal.AccountChanges) void {
    for (account.storage_changes) |slot| {
        if (slot.changes.len > 0) allocator.free(slot.changes);
    }
    if (account.storage_changes.len > 0) allocator.free(account.storage_changes);
    if (account.storage_reads.len > 0) allocator.free(account.storage_reads);
    if (account.balance_changes.len > 0) allocator.free(account.balance_changes);
    if (account.nonce_changes.len > 0) allocator.free(account.nonce_changes);
    for (account.code_changes) |change| allocator.free(@constCast(change.new_code));
    if (account.code_changes.len > 0) allocator.free(account.code_changes);
}
