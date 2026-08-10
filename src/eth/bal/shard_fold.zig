//! Canonical union of independently produced BAL shards.

const std = @import("std");
const bal = @import("model.zig");
const observation = @import("observation.zig");

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
    accounts: std.array_hash_map.Auto(bal.Address, FoldAccount) = .empty,
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
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *ShardFold) void {
        for (self.accounts.values()) |*account| account.deinit(self.allocator);
        self.accounts.deinit(self.allocator);
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

    pub fn appendObservation(
        self: *ShardFold,
        account: observation.AccountObservation,
        block_access_index: bal.BlockAccessIndex,
    ) Error!void {
        switch (self.lifecycle) {
            .building => {},
            .failed => return error.FoldFailed,
            .finished => return error.FoldAlreadyFinished,
        }
        const target = self.accountFor(account.address) catch |err| {
            self.lifecycle = .failed;
            return err;
        };
        target.appendObservation(self.allocator, account, block_access_index) catch |err| {
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

    /// Compare the canonical fold directly with an admitted claim. This keeps
    /// the fold live so a mismatch can still be materialized for diagnostics.
    pub fn matchesClaim(self: *ShardFold, expected: bal.BlockAccessList) Error!bool {
        switch (self.lifecycle) {
            .building => {},
            .failed => return error.FoldFailed,
            .finished => return error.FoldAlreadyFinished,
        }
        return self.matchesClaimFallible(expected) catch |err| {
            self.lifecycle = .failed;
            return err;
        };
    }

    fn finishFallible(self: *ShardFold) Error!bal.Decoded {
        var canonical = try Canonical.init(self);
        defer canonical.deinit();
        return canonical.toOwnedDecoded();
    }

    fn matchesClaimFallible(self: *ShardFold, expected: bal.BlockAccessList) Error!bool {
        var canonical = try Canonical.init(self);
        defer canonical.deinit();
        return canonical.matchesClaim(expected);
    }

    fn accountFor(self: *ShardFold, target: bal.Address) Error!*FoldAccount {
        const result = try self.accounts.getOrPut(self.allocator, target);
        if (!result.found_existing) result.value_ptr.* = .{};
        return result.value_ptr;
    }
};

/// One validated canonical ordering of a live fold. Materialization and claim
/// comparison intentionally share this authority; they differ only in what
/// they do with the ordered values.
const Canonical = struct {
    allocator: Allocator,
    fold: *ShardFold,
    account_order: []usize,

    fn init(fold: *ShardFold) ShardFold.Error!Canonical {
        const account_order = try fold.allocator.alloc(usize, fold.accounts.count());
        for (account_order, 0..) |*index, value| index.* = value;
        std.sort.pdq(usize, account_order, fold.accounts.keys(), accountIndexLessThan);
        return .{ .allocator = fold.allocator, .fold = fold, .account_order = account_order };
    }

    fn deinit(self: *Canonical) void {
        self.allocator.free(self.account_order);
        self.* = undefined;
    }

    fn matchesClaim(self: *const Canonical, expected: bal.BlockAccessList) ShardFold.Error!bool {
        if (self.account_order.len != expected.len) return false;
        for (self.account_order, expected) |account_index, expected_account| {
            var actual = try self.account(account_index);
            defer actual.deinit(self.allocator);
            if (!actual.matchesClaim(expected_account)) return false;
        }
        return true;
    }

    fn toOwnedDecoded(self: *Canonical) ShardFold.Error!bal.Decoded {
        var accounts: std.ArrayList(bal.AccountChanges) = .empty;
        errdefer {
            for (accounts.items) |*owned| deinitAccount(self.allocator, owned);
            accounts.deinit(self.allocator);
        }
        try accounts.ensureTotalCapacity(self.allocator, self.account_order.len);
        for (self.account_order) |account_index| {
            var canonical = try self.account(account_index);
            defer canonical.deinit(self.allocator);
            var owned = try canonical.toOwnedAccount(self.allocator);
            errdefer deinitAccount(self.allocator, &owned);
            accounts.appendAssumeCapacity(owned);
        }
        return .{ .accounts = try accounts.toOwnedSlice(self.allocator) };
    }

    fn account(self: *const Canonical, index: usize) ShardFold.Error!CanonicalAccount {
        return CanonicalAccount.init(
            self.allocator,
            self.fold.accounts.keys()[index],
            &self.fold.accounts.values()[index],
        );
    }
};

/// Fold one detached transition into a standalone BAL at one access index.
///
/// Block assembly appends transitions directly into a shared fold; this is the
/// single-shard form used by fixtures and cross-checks against an independent
/// BAL source.
pub fn shardAlloc(
    allocator: Allocator,
    transition: observation.LaneTransition,
    block_access_index: bal.BlockAccessIndex,
) ShardFold.Error!bal.Decoded {
    var fold = ShardFold.init(allocator);
    defer fold.deinit();
    for (transition.accounts) |account| {
        try fold.appendObservation(account, block_access_index);
    }
    return fold.finish();
}

const FoldStorageChange = struct {
    slot: u256,
    block_access_index: bal.BlockAccessIndex,
    new_value: u256,
};

const FoldAccount = struct {
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

    fn appendObservation(
        self: *FoldAccount,
        allocator: Allocator,
        account: observation.AccountObservation,
        block_access_index: bal.BlockAccessIndex,
    ) Allocator.Error!void {
        for (account.storage) |slot| {
            if (account.storage_wiped or slot.original == slot.current) {
                try self.storage_reads.append(allocator, slot.slot);
            } else {
                try self.storage_changes.append(allocator, .{
                    .slot = slot.slot,
                    .block_access_index = block_access_index,
                    .new_value = slot.current,
                });
            }
        }
        if (account.balance) |balance| if (balance.original != balance.current) {
            try self.balance_changes.append(allocator, .{
                .block_access_index = block_access_index,
                .post_balance = balance.current,
            });
        };
        if (account.nonce) |nonce| if (nonce.original != nonce.current) {
            try self.nonce_changes.append(allocator, .{
                .block_access_index = block_access_index,
                .new_nonce = nonce.current,
            });
        };
        if (account.code) |code| if (!std.mem.eql(u8, &code.original_hash, &code.current_hash)) {
            const new_code = try allocator.dupe(u8, code.current_code);
            errdefer allocator.free(new_code);
            try self.code_changes.append(allocator, .{
                .block_access_index = block_access_index,
                .new_code = new_code,
            });
        };
    }
};

const CanonicalAccount = struct {
    address: bal.Address,
    fold: *FoldAccount,
    storage_order: []usize,

    fn init(
        allocator: Allocator,
        address: bal.Address,
        fold: *FoldAccount,
    ) ShardFold.Error!CanonicalAccount {
        const storage_order = try allocator.alloc(usize, fold.storage_changes.items.len);
        errdefer allocator.free(storage_order);
        for (storage_order, 0..) |*entry, index| entry.* = index;
        std.sort.pdq(usize, storage_order, fold.storage_changes.items, storageChangeIndexLessThan);
        try rejectDuplicateStorageIndices(fold.storage_changes.items, storage_order);

        std.mem.sort(u256, fold.storage_reads.items, {}, u256LessThan);
        std.mem.sort(bal.BalanceChange, fold.balance_changes.items, {}, balanceChangeLessThan);
        try rejectDuplicateBalanceIndices(fold.balance_changes.items);
        std.mem.sort(bal.NonceChange, fold.nonce_changes.items, {}, nonceChangeLessThan);
        try rejectDuplicateNonceIndices(fold.nonce_changes.items);
        std.mem.sort(bal.CodeChange, fold.code_changes.items, {}, codeChangeLessThan);
        try rejectDuplicateCodeIndices(fold.code_changes.items);
        return .{ .address = address, .fold = fold, .storage_order = storage_order };
    }

    fn deinit(self: *CanonicalAccount, allocator: Allocator) void {
        allocator.free(self.storage_order);
        self.* = undefined;
    }

    fn matchesClaim(self: *const CanonicalAccount, expected: bal.AccountChanges) bool {
        if (!std.mem.eql(u8, &self.address, &expected.address) or
            !self.storageChangesMatch(expected.storage_changes) or
            !self.storageReadsMatch(expected.storage_reads) or
            !bal.changesEql(bal.BalanceChange, expected.balance_changes, self.fold.balance_changes.items) or
            !bal.changesEql(bal.NonceChange, expected.nonce_changes, self.fold.nonce_changes.items) or
            !bal.codeChangesEql(expected.code_changes, self.fold.code_changes.items))
        {
            return false;
        }
        return true;
    }

    fn storageChangesMatch(self: *const CanonicalAccount, expected: []const bal.SlotChanges) bool {
        var actual_index: usize = 0;
        for (expected) |expected_slot| {
            if (actual_index == self.storage_order.len) return false;
            const slot = self.storageChange(actual_index).slot;
            if (slot != expected_slot.slot) return false;

            var change_index: usize = 0;
            while (actual_index < self.storage_order.len and self.storageChange(actual_index).slot == slot) {
                if (change_index == expected_slot.changes.len) return false;
                const expected_change = expected_slot.changes[change_index];
                const actual = self.storageChange(actual_index);
                if (expected_change.block_access_index != actual.block_access_index or
                    expected_change.new_value != actual.new_value)
                {
                    return false;
                }
                change_index += 1;
                actual_index += 1;
            }
            if (change_index != expected_slot.changes.len) return false;
        }
        return actual_index == self.storage_order.len;
    }

    fn storageReadsMatch(self: *const CanonicalAccount, expected: []const u256) bool {
        var reads = CanonicalStorageReads.init(self);
        for (expected) |slot| if (reads.next() != slot) return false;
        return reads.next() == null;
    }

    fn toOwnedAccount(self: *CanonicalAccount, allocator: Allocator) ShardFold.Error!bal.AccountChanges {
        var result = bal.AccountChanges{ .address = self.address };
        errdefer deinitAccount(allocator, &result);
        result.storage_changes = try self.toOwnedStorageChanges(allocator);
        result.storage_reads = try self.toOwnedStorageReads(allocator);
        result.balance_changes = try self.fold.balance_changes.toOwnedSlice(allocator);
        result.nonce_changes = try self.fold.nonce_changes.toOwnedSlice(allocator);
        result.code_changes = try self.fold.code_changes.toOwnedSlice(allocator);
        return result;
    }

    fn toOwnedStorageChanges(self: *const CanonicalAccount, allocator: Allocator) Allocator.Error![]const bal.SlotChanges {
        var slots: std.ArrayList(bal.SlotChanges) = .empty;
        errdefer {
            for (slots.items) |slot| allocator.free(@constCast(slot.changes));
            slots.deinit(allocator);
        }

        var index: usize = 0;
        while (index < self.storage_order.len) {
            const slot = self.storageChange(index).slot;
            var changes: std.ArrayList(bal.StorageChange) = .empty;
            errdefer changes.deinit(allocator);
            while (index < self.storage_order.len and self.storageChange(index).slot == slot) {
                const change = self.storageChange(index);
                try changes.append(allocator, .{
                    .block_access_index = change.block_access_index,
                    .new_value = change.new_value,
                });
                index += 1;
            }
            const owned_changes = try changes.toOwnedSlice(allocator);
            errdefer allocator.free(owned_changes);
            try slots.append(allocator, .{ .slot = slot, .changes = owned_changes });
        }
        return slots.toOwnedSlice(allocator);
    }

    fn toOwnedStorageReads(self: *const CanonicalAccount, allocator: Allocator) Allocator.Error![]const u256 {
        var result: std.ArrayList(u256) = .empty;
        errdefer result.deinit(allocator);
        var reads = CanonicalStorageReads.init(self);
        while (reads.next()) |slot| try result.append(allocator, slot);
        return result.toOwnedSlice(allocator);
    }

    fn storageChange(self: *const CanonicalAccount, index: usize) FoldStorageChange {
        return self.fold.storage_changes.items[self.storage_order[index]];
    }
};

const CanonicalStorageReads = struct {
    account: *const CanonicalAccount,
    read_index: usize = 0,
    change_index: usize = 0,
    previous: ?u256 = null,

    fn init(account: *const CanonicalAccount) CanonicalStorageReads {
        return .{ .account = account };
    }

    fn next(self: *CanonicalStorageReads) ?u256 {
        while (self.read_index < self.account.fold.storage_reads.items.len) {
            const slot = self.account.fold.storage_reads.items[self.read_index];
            self.read_index += 1;
            if (self.previous != null and self.previous.? == slot) continue;
            self.previous = slot;
            while (self.change_index < self.account.storage_order.len and
                self.account.storageChange(self.change_index).slot < slot)
            {
                self.change_index += 1;
            }
            if (self.change_index < self.account.storage_order.len and
                self.account.storageChange(self.change_index).slot == slot)
            {
                continue;
            }
            return slot;
        }
        return null;
    }
};

fn rejectDuplicateStorageIndices(
    changes: []const FoldStorageChange,
    order: []const usize,
) ShardFold.Error!void {
    if (order.len < 2) return;
    for (order[1..], order[0 .. order.len - 1]) |current_index, previous_index| {
        const current = changes[current_index];
        const previous = changes[previous_index];
        if (current.slot == previous.slot and
            current.block_access_index == previous.block_access_index)
        {
            return error.DuplicateStorageChangeIndex;
        }
    }
}

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

fn accountIndexLessThan(addresses: []const bal.Address, lhs: usize, rhs: usize) bool {
    return std.mem.order(u8, &addresses[lhs], &addresses[rhs]) == .lt;
}

fn storageChangeIndexLessThan(
    changes: []const FoldStorageChange,
    lhs_index: usize,
    rhs_index: usize,
) bool {
    const lhs = changes[lhs_index];
    const rhs = changes[rhs_index];
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
    for (account.storage_changes) |slot| allocator.free(slot.changes);
    allocator.free(account.storage_changes);
    allocator.free(account.storage_reads);
    allocator.free(account.balance_changes);
    allocator.free(account.nonce_changes);
    for (account.code_changes) |change| allocator.free(@constCast(change.new_code));
    allocator.free(account.code_changes);
}

test "observation append projects reads writes and code at one index" {
    const allocator = std.testing.allocator;
    var target: bal.Address = @splat(0);
    target[target.len - 1] = 1;
    const code = [_]u8{ 0x60, 0x00 };
    var storage = [_]observation.StorageObservation{
        .{ .slot = 1, .original = 5, .current = 5 },
        .{ .slot = 2, .original = 7, .current = 9 },
    };
    var accounts = [_]observation.AccountObservation{.{
        .address = target,
        .storage = &storage,
        .balance = .{ .original = 10, .current = 11 },
        .nonce = .{ .original = 2, .current = 3 },
        .code = .{
            .original_hash = @splat(0),
            .current_hash = @splat(1),
            .current_code = &code,
        },
    }};

    var result = try shardAlloc(allocator, .{ .accounts = &accounts }, 4);
    defer result.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), result.accounts.len);
    const account = result.accounts[0];
    // An unchanged slot is a read; a changed slot is a positioned write.
    try std.testing.expectEqualSlices(u256, &.{1}, account.storage_reads);
    try std.testing.expectEqual(@as(usize, 1), account.storage_changes.len);
    try std.testing.expectEqual(@as(u256, 2), account.storage_changes[0].slot);
    try std.testing.expectEqual(
        bal.StorageChange{ .block_access_index = 4, .new_value = 9 },
        account.storage_changes[0].changes[0],
    );
    try std.testing.expectEqual(
        bal.BalanceChange{ .block_access_index = 4, .post_balance = 11 },
        account.balance_changes[0],
    );
    try std.testing.expectEqual(
        bal.NonceChange{ .block_access_index = 4, .new_nonce = 3 },
        account.nonce_changes[0],
    );
    try std.testing.expectEqualSlices(u8, &code, account.code_changes[0].new_code);
}

test "large account fold canonicalizes through indirect order" {
    const allocator = std.testing.allocator;
    var fold = ShardFold.init(allocator);
    defer fold.deinit();

    for (0..32) |index| {
        var target: bal.Address = @splat(0);
        target[target.len - 1] = @intCast(32 - index);
        try fold.appendObservation(.{
            .address = target,
            .balance = .{ .original = 0, .current = 1 },
        }, @intCast(index + 1));
    }

    var result = try fold.finish();
    defer result.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 32), result.accounts.len);
    for (result.accounts, 1..) |account, expected| {
        try std.testing.expectEqual(@as(u8, @intCast(expected)), account.address[account.address.len - 1]);
    }
}

test "large storage fold canonicalizes through indirect order" {
    const allocator = std.testing.allocator;
    var fold = ShardFold.init(allocator);
    defer fold.deinit();

    const target: bal.Address = @splat(1);
    for (0..32) |index| {
        const slot: u256 = @intCast(32 - index);
        var storage = [_]observation.StorageObservation{.{
            .slot = slot,
            .original = 0,
            .current = 1,
        }};
        try fold.appendObservation(.{ .address = target, .storage = &storage }, @intCast(64 - index));
        storage[0].current = 2;
        try fold.appendObservation(.{ .address = target, .storage = &storage }, @intCast(index + 1));
    }

    var result = try fold.finish();
    defer result.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), result.accounts.len);
    try std.testing.expectEqual(@as(usize, 32), result.accounts[0].storage_changes.len);
    for (result.accounts[0].storage_changes, 1..) |slot, expected| {
        try std.testing.expectEqual(@as(u256, @intCast(expected)), slot.slot);
        try std.testing.expectEqual(@as(usize, 2), slot.changes.len);
        try std.testing.expect(slot.changes[0].block_access_index < slot.changes[1].block_access_index);
    }
}

test "claim comparison preserves mismatch materialization" {
    const allocator = std.testing.allocator;
    const target: bal.Address = @splat(1);
    var storage = [_]observation.StorageObservation{
        .{ .slot = 2, .original = 0, .current = 3 },
        .{ .slot = 1, .original = 4, .current = 4 },
    };
    var fold = ShardFold.init(allocator);
    defer fold.deinit();
    try fold.appendObservation(.{
        .address = target,
        .storage = &storage,
        .balance = .{ .original = 0, .current = 7 },
    }, 1);

    const storage_changes = [_]bal.StorageChange{.{
        .block_access_index = 1,
        .new_value = 3,
    }};
    const slots = [_]bal.SlotChanges{.{
        .slot = 2,
        .changes = &storage_changes,
    }};
    const reads = [_]u256{1};
    const balances = [_]bal.BalanceChange{.{
        .block_access_index = 1,
        .post_balance = 7,
    }};
    const expected = [_]bal.AccountChanges{.{
        .address = target,
        .storage_changes = &slots,
        .storage_reads = &reads,
        .balance_changes = &balances,
    }};
    try std.testing.expect(try fold.matchesClaim(&expected));

    var wrong_balances = balances;
    wrong_balances[0].post_balance = 8;
    var wrong = expected;
    wrong[0].balance_changes = &wrong_balances;
    try std.testing.expect(!try fold.matchesClaim(&wrong));

    var materialized = try fold.finish();
    defer materialized.deinit(allocator);
    try std.testing.expect(bal.eql(&expected, materialized.accounts));
}
