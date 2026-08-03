//! Dense state/storage claim namespace derived from a validated Amsterdam BAL.
//!
//! Raw BAL order defines stable execution IDs. Separate `u32` handle arrays
//! provide Keccak trie order for batch authentication and later dirty commit.
//! Claimed values remain borrowed by the original BAL; this plan owns only
//! identity and ordering metadata.

const std = @import("std");

const address = @import("../../address.zig");
const bal = @import("model.zig");
const trie = @import("../trie.zig");

const Allocator = std.mem.Allocator;
const Hash = [32]u8;

pub const AccountId = enum(u32) { _ };
pub const StorageId = enum(u32) { _ };

pub const Range = struct {
    start: u32,
    len: u32,

    pub fn end(self: Range) u32 {
        return self.start + self.len;
    }
};

pub const AccountClaim = struct {
    // Aligned so address/key compares use word loads; `[N]u8` is otherwise
    // align-1 and this target assembles byte ladders for every compare.
    address: address.Address align(8),
    trie_key: Hash align(8),
    storage: Range,

    comptime {
        std.debug.assert(@sizeOf(AccountClaim) == 64);
        std.debug.assert(@alignOf(AccountClaim) == 8);
    }
};

pub const StorageClaim = struct {
    account: AccountId,
    slot: u256,
    trie_key: Hash align(8),

    comptime {
        std.debug.assert(@sizeOf(StorageClaim) == 80);
        std.debug.assert(@alignOf(StorageClaim) == 16);
    }
};

pub const InitError = Allocator.Error || error{
    ResourceLimitExceeded,
    TrieKeyCollision,
};

pub const ClaimPlan = struct {
    accounts: []AccountClaim = &.{},
    storage: []StorageClaim = &.{},
    account_trie_order: []AccountId = &.{},
    storage_trie_order: []StorageId = &.{},

    /// Construct from a BAL already accepted by `bal.validate`.
    pub fn initAssumeValidated(
        allocator: Allocator,
        block_access_list: bal.BlockAccessList,
    ) InitError!ClaimPlan {
        const counts = bal.count(block_access_list);
        const storage_count = std.math.add(
            usize,
            counts.storage_read_keys,
            counts.storage_write_keys,
        ) catch return error.ResourceLimitExceeded;
        if (block_access_list.len > std.math.maxInt(u32) or
            storage_count > std.math.maxInt(u32))
        {
            return error.ResourceLimitExceeded;
        }

        var accounts: []AccountClaim = &.{};
        if (block_access_list.len != 0) {
            accounts = try allocator.alloc(AccountClaim, block_access_list.len);
        }
        errdefer if (accounts.len != 0) allocator.free(accounts);

        var storage: []StorageClaim = &.{};
        if (storage_count != 0) storage = try allocator.alloc(StorageClaim, storage_count);
        errdefer if (storage.len != 0) allocator.free(storage);

        var account_trie_order: []AccountId = &.{};
        if (accounts.len != 0) account_trie_order = try allocator.alloc(AccountId, accounts.len);
        errdefer if (account_trie_order.len != 0) allocator.free(account_trie_order);

        var storage_trie_order: []StorageId = &.{};
        if (storage.len != 0) storage_trie_order = try allocator.alloc(StorageId, storage.len);
        errdefer if (storage_trie_order.len != 0) allocator.free(storage_trie_order);

        var storage_index: usize = 0;
        for (block_access_list, 0..) |account, account_index| {
            const id: AccountId = @enumFromInt(@as(u32, @intCast(account_index)));
            const storage_start = storage_index;
            var change_index: usize = 0;
            var read_index: usize = 0;
            while (change_index < account.storage_changes.len or
                read_index < account.storage_reads.len)
            {
                const has_change = change_index < account.storage_changes.len;
                const has_read = read_index < account.storage_reads.len;
                const slot = if (!has_read or
                    (has_change and account.storage_changes[change_index].slot < account.storage_reads[read_index]))
                slot: {
                    const value = account.storage_changes[change_index].slot;
                    change_index += 1;
                    break :slot value;
                } else slot: {
                    const value = account.storage_reads[read_index];
                    read_index += 1;
                    break :slot value;
                };
                const storage_id: StorageId = @enumFromInt(@as(u32, @intCast(storage_index)));
                storage[storage_index] = .{
                    .account = id,
                    .slot = slot,
                    .trie_key = trie.hashedStorageKey(slot),
                };
                storage_trie_order[storage_index] = storage_id;
                storage_index += 1;
            }

            accounts[account_index] = .{
                .address = account.address,
                .trie_key = trie.hashedAddressKey(account.address),
                .storage = .{
                    .start = @intCast(storage_start),
                    .len = @intCast(storage_index - storage_start),
                },
            };
            account_trie_order[account_index] = id;
        }
        std.debug.assert(storage_index == storage.len);

        std.mem.sort(AccountId, account_trie_order, accounts, accountTrieLessThan);
        try rejectAccountKeyCollisions(accounts, account_trie_order);
        for (accounts) |account| {
            const range = storage_trie_order[account.storage.start..account.storage.end()];
            std.mem.sort(StorageId, range, storage, storageTrieLessThan);
            try rejectStorageKeyCollisions(storage, range);
        }

        return .{
            .accounts = accounts,
            .storage = storage,
            .account_trie_order = account_trie_order,
            .storage_trie_order = storage_trie_order,
        };
    }

    pub fn deinit(self: *ClaimPlan, allocator: Allocator) void {
        if (self.accounts.len != 0) allocator.free(self.accounts);
        if (self.storage.len != 0) allocator.free(self.storage);
        if (self.account_trie_order.len != 0) allocator.free(self.account_trie_order);
        if (self.storage_trie_order.len != 0) allocator.free(self.storage_trie_order);
        self.* = .{};
    }

    pub fn storageClaims(self: ClaimPlan, id: AccountId) []const StorageClaim {
        const range = self.accounts[@intFromEnum(id)].storage;
        return self.storage[range.start..range.end()];
    }

    pub fn storageTrieOrder(self: ClaimPlan, id: AccountId) []const StorageId {
        const range = self.accounts[@intFromEnum(id)].storage;
        return self.storage_trie_order[range.start..range.end()];
    }

    /// Resolve one full address in canonical raw BAL order.
    pub fn accountId(self: ClaimPlan, target: address.Address) ?AccountId {
        var low: usize = 0;
        var high = self.accounts.len;
        while (low < high) {
            const mid = low + (high - low) / 2;
            switch (std.mem.order(u8, &self.accounts[mid].address, &target)) {
                .lt => low = mid + 1,
                .gt => high = mid,
                .eq => return @enumFromInt(@as(u32, @intCast(mid))),
            }
        }
        return null;
    }

    /// Resolve one full raw slot inside its account's canonical BAL range.
    pub fn storageId(self: ClaimPlan, account: AccountId, slot: u256) ?StorageId {
        const range = self.accounts[@intFromEnum(account)].storage;
        var low: usize = range.start;
        var high: usize = range.end();
        while (low < high) {
            const mid = low + (high - low) / 2;
            const current = self.storage[mid].slot;
            if (current < slot) {
                low = mid + 1;
            } else if (current > slot) {
                high = mid;
            } else {
                return @enumFromInt(@as(u32, @intCast(mid)));
            }
        }
        return null;
    }

    pub fn allocationBytes(self: ClaimPlan) usize {
        return self.accounts.len * @sizeOf(AccountClaim) +
            self.storage.len * @sizeOf(StorageClaim) +
            self.account_trie_order.len * @sizeOf(AccountId) +
            self.storage_trie_order.len * @sizeOf(StorageId);
    }
};

fn accountTrieLessThan(accounts: []const AccountClaim, lhs: AccountId, rhs: AccountId) bool {
    return std.mem.order(
        u8,
        &accounts[@intFromEnum(lhs)].trie_key,
        &accounts[@intFromEnum(rhs)].trie_key,
    ) == .lt;
}

fn storageTrieLessThan(storage: []const StorageClaim, lhs: StorageId, rhs: StorageId) bool {
    return std.mem.order(
        u8,
        &storage[@intFromEnum(lhs)].trie_key,
        &storage[@intFromEnum(rhs)].trie_key,
    ) == .lt;
}

fn rejectAccountKeyCollisions(accounts: []const AccountClaim, order: []const AccountId) InitError!void {
    if (order.len < 2) return;
    for (order[1..], order[0 .. order.len - 1]) |current, previous| {
        if (std.mem.eql(
            u8,
            &accounts[@intFromEnum(previous)].trie_key,
            &accounts[@intFromEnum(current)].trie_key,
        )) return error.TrieKeyCollision;
    }
}

fn rejectStorageKeyCollisions(storage: []const StorageClaim, order: []const StorageId) InitError!void {
    if (order.len < 2) return;
    for (order[1..], order[0 .. order.len - 1]) |current, previous| {
        if (std.mem.eql(
            u8,
            &storage[@intFromEnum(previous)].trie_key,
            &storage[@intFromEnum(current)].trie_key,
        )) return error.TrieKeyCollision;
    }
}

test "claim plan assigns raw IDs and separate trie order" {
    const first_changes = [_]bal.StorageChange{.{ .block_access_index = 1, .new_value = 7 }};
    const first_slots = [_]bal.SlotChanges{
        .{ .slot = 1, .changes = &first_changes },
        .{ .slot = 9, .changes = &first_changes },
    };
    const claims = [_]bal.AccountChanges{
        .{
            .address = address.addr(1),
            .storage_changes = &first_slots,
            .storage_reads = &.{ 3, 5 },
        },
        .{ .address = address.addr(2), .storage_reads = &.{8} },
    };
    try bal.validate(&claims, .{ .transaction_count = 1 });

    var plan = try ClaimPlan.initAssumeValidated(std.testing.allocator, &claims);
    defer plan.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), plan.accounts.len);
    try std.testing.expectEqual(@as(usize, 5), plan.storage.len);
    const first_storage = plan.storageClaims(@enumFromInt(0));
    try std.testing.expectEqual(@as(usize, 4), first_storage.len);
    for (first_storage, [_]u256{ 1, 3, 5, 9 }) |claim, expected| {
        try std.testing.expectEqual(expected, claim.slot);
    }
    const second_storage = plan.storageClaims(@enumFromInt(1));
    try std.testing.expectEqual(@as(usize, 1), second_storage.len);
    try std.testing.expectEqual(@as(u256, 8), second_storage[0].slot);
    try expectAccountTrieOrder(plan);
    try expectStorageTrieOrder(plan, @enumFromInt(0));
    try expectStorageTrieOrder(plan, @enumFromInt(1));
    try std.testing.expect(plan.allocationBytes() > 0);
    try std.testing.expectEqual(@as(?AccountId, @enumFromInt(0)), plan.accountId(address.addr(1)));
    try std.testing.expectEqual(@as(?AccountId, @enumFromInt(1)), plan.accountId(address.addr(2)));
    try std.testing.expectEqual(@as(?AccountId, null), plan.accountId(address.addr(3)));
    try std.testing.expectEqual(@as(?StorageId, @enumFromInt(2)), plan.storageId(@enumFromInt(0), 5));
    try std.testing.expectEqual(@as(?StorageId, null), plan.storageId(@enumFromInt(0), 4));
}

test "claim plan cleans every allocation failure position" {
    const Harness = struct {
        fn run(allocator: Allocator) !void {
            const changes = [_]bal.StorageChange{.{ .block_access_index = 1, .new_value = 1 }};
            const changed = [_]bal.SlotChanges{.{ .slot = 2, .changes = &changes }};
            const claims = [_]bal.AccountChanges{.{
                .address = address.addr(1),
                .storage_changes = &changed,
                .storage_reads = &.{3},
            }};
            var plan = try ClaimPlan.initAssumeValidated(allocator, &claims);
            defer plan.deinit(allocator);
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Harness.run, .{});
}

fn expectAccountTrieOrder(plan: ClaimPlan) !void {
    if (plan.account_trie_order.len < 2) return;
    for (plan.account_trie_order[1..], plan.account_trie_order[0 .. plan.account_trie_order.len - 1]) |current, previous| {
        try std.testing.expect(std.mem.order(
            u8,
            &plan.accounts[@intFromEnum(previous)].trie_key,
            &plan.accounts[@intFromEnum(current)].trie_key,
        ) == .lt);
    }
}

fn expectStorageTrieOrder(plan: ClaimPlan, account: AccountId) !void {
    const order = plan.storageTrieOrder(account);
    if (order.len < 2) return;
    for (order[1..], order[0 .. order.len - 1]) |current, previous| {
        try std.testing.expect(std.mem.order(
            u8,
            &plan.storage[@intFromEnum(previous)].trie_key,
            &plan.storage[@intFromEnum(current)].trie_key,
        ) == .lt);
    }
}
