//! Dense state/storage claim namespace derived from a validated Amsterdam BAL.
//!
//! Raw BAL order defines stable execution IDs. Hot execution identity columns
//! stay separate from Keccak trie metadata and `u32` trie-order handles.
//! Claimed values remain borrowed by the original BAL; this plan owns only
//! identity and ordering metadata.

const std = @import("std");

const address = @import("../../address.zig");
const bal = @import("model.zig");
const trie = @import("../trie.zig");

const Allocator = std.mem.Allocator;
const Hash = [32]u8;
const AlignedHashes = []align(8) Hash;

pub const AccountId = enum(u32) { _ };
pub const StorageId = enum(u32) { _ };

pub const Range = struct {
    start: u32,
    len: u32,

    pub fn end(self: Range) u32 {
        return self.start + self.len;
    }
};

comptime {
    // Hot translation touches only address/range/slot columns; authentication
    // and commit touch trie-key columns. A hot whole-claim traversal would
    // falsify this split. Keep every stored address 8-byte aligned so the SoA
    // conversion does not undo the measured RV64 word-load layout.
    std.debug.assert(@sizeOf(address.AddressWord) == 24);
    std.debug.assert(@alignOf(address.AddressWord) == 8);
    std.debug.assert(@sizeOf(address.AddressWord) + @sizeOf(Range) + @sizeOf(Hash) == 64);
    std.debug.assert(@sizeOf(AccountId) + @sizeOf(u256) + @sizeOf(Hash) == 68);
}

pub const InitError = Allocator.Error || error{
    ResourceLimitExceeded,
    TrieKeyCollision,
};

pub const ClaimPlan = struct {
    account_addresses: []address.AddressWord = &.{},
    account_storage_ranges: []Range = &.{},
    account_trie_keys: AlignedHashes = &.{},
    storage_accounts: []AccountId = &.{},
    storage_slots: []u256 = &.{},
    storage_trie_keys: AlignedHashes = &.{},
    account_trie_order: []AccountId = &.{},
    storage_trie_order: []StorageId = &.{},
    /// Open-addressed AccountId + 1; zero marks an empty slot. The table is
    /// built at no more than 50% load and every hit verifies the full address.
    account_positions: []u32 = &.{},

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

        const account_addresses = try allocator.alloc(address.AddressWord, block_access_list.len);
        errdefer allocator.free(account_addresses);
        const account_storage_ranges = try allocator.alloc(Range, block_access_list.len);
        errdefer allocator.free(account_storage_ranges);
        const account_trie_keys = try allocator.alignedAlloc(
            Hash,
            .of(u64),
            block_access_list.len,
        );
        errdefer allocator.free(account_trie_keys);
        const storage_accounts = try allocator.alloc(AccountId, storage_count);
        errdefer allocator.free(storage_accounts);
        const storage_slots = try allocator.alloc(u256, storage_count);
        errdefer allocator.free(storage_slots);
        const storage_trie_keys = try allocator.alignedAlloc(Hash, .of(u64), storage_count);
        errdefer allocator.free(storage_trie_keys);

        const account_trie_order = try allocator.alloc(AccountId, account_addresses.len);
        errdefer allocator.free(account_trie_order);

        const storage_trie_order = try allocator.alloc(StorageId, storage_slots.len);
        errdefer allocator.free(storage_trie_order);

        const account_positions = try allocator.alloc(
            u32,
            try accountTableCapacity(account_addresses.len),
        );
        errdefer allocator.free(account_positions);
        @memset(account_positions, 0);

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
                storage_accounts[storage_index] = id;
                storage_slots[storage_index] = slot;
                trie.hashedStorageKeyInto(slot, &storage_trie_keys[storage_index]);
                storage_trie_order[storage_index] = storage_id;
                storage_index += 1;
            }

            account_addresses[account_index] = .fromAddress(account.address);
            trie.hashedAddressKeyInto(account.address, &account_trie_keys[account_index]);
            account_storage_ranges[account_index] = .{
                .start = @intCast(storage_start),
                .len = @intCast(storage_index - storage_start),
            };
            account_trie_order[account_index] = id;
            insertAccountPosition(account_positions, account_addresses, id);
        }
        std.debug.assert(storage_index == storage_slots.len);

        std.mem.sort(AccountId, account_trie_order, account_trie_keys, accountTrieLessThan);
        try rejectTrieKeyCollisions(AccountId, account_trie_keys, account_trie_order);
        for (account_storage_ranges) |storage_range| {
            const range = storage_trie_order[storage_range.start..storage_range.end()];
            std.mem.sort(StorageId, range, storage_trie_keys, storageTrieLessThan);
            try rejectTrieKeyCollisions(StorageId, storage_trie_keys, range);
        }

        return .{
            .account_addresses = account_addresses,
            .account_storage_ranges = account_storage_ranges,
            .account_trie_keys = account_trie_keys,
            .storage_accounts = storage_accounts,
            .storage_slots = storage_slots,
            .storage_trie_keys = storage_trie_keys,
            .account_trie_order = account_trie_order,
            .storage_trie_order = storage_trie_order,
            .account_positions = account_positions,
        };
    }

    pub fn deinit(self: *ClaimPlan, allocator: Allocator) void {
        allocator.free(self.account_addresses);
        allocator.free(self.account_storage_ranges);
        allocator.free(self.account_trie_keys);
        allocator.free(self.storage_accounts);
        allocator.free(self.storage_slots);
        allocator.free(self.storage_trie_keys);
        allocator.free(self.account_trie_order);
        allocator.free(self.storage_trie_order);
        allocator.free(self.account_positions);
        self.* = .{};
    }

    pub fn accountAddress(self: *const ClaimPlan, id: AccountId) address.Address {
        return self.accountAddressWord(id).address();
    }

    pub fn accountAddressWord(self: *const ClaimPlan, id: AccountId) address.AddressWord {
        return self.account_addresses[@intFromEnum(id)];
    }

    pub fn accountStorageRange(self: *const ClaimPlan, id: AccountId) Range {
        return self.account_storage_ranges[@intFromEnum(id)];
    }

    pub fn accountTrieKey(self: *const ClaimPlan, id: AccountId) Hash {
        return self.account_trie_keys[@intFromEnum(id)];
    }

    pub fn storageAccount(self: *const ClaimPlan, id: StorageId) AccountId {
        return self.storage_accounts[@intFromEnum(id)];
    }

    pub fn storageSlot(self: *const ClaimPlan, id: StorageId) u256 {
        return self.storage_slots[@intFromEnum(id)];
    }

    pub fn storageTrieKey(self: *const ClaimPlan, id: StorageId) Hash {
        return self.storage_trie_keys[@intFromEnum(id)];
    }

    pub fn accountCount(self: *const ClaimPlan) usize {
        return self.account_addresses.len;
    }

    pub fn storageCount(self: *const ClaimPlan) usize {
        return self.storage_slots.len;
    }

    pub fn storageSlots(self: *const ClaimPlan, id: AccountId) []const u256 {
        const range = self.accountStorageRange(id);
        return self.storage_slots[range.start..range.end()];
    }

    pub fn storageTrieOrder(self: *const ClaimPlan, id: AccountId) []const StorageId {
        const range = self.accountStorageRange(id);
        return self.storage_trie_order[range.start..range.end()];
    }

    /// Resolve one full address in canonical raw BAL order.
    pub fn accountIdWord(self: *const ClaimPlan, target: address.AddressWord) ?AccountId {
        if (self.account_positions.len == 0) return null;
        const mask: u64 = self.account_positions.len - 1;
        var slot: usize = @intCast(accountPositionHash(target) & mask);
        while (true) {
            const entry = self.account_positions[slot];
            if (entry == 0) return null;
            const id: AccountId = @enumFromInt(entry - 1);
            if (address.AddressWord.eql(self.account_addresses[@intFromEnum(id)], target)) return id;
            slot = @intCast((slot + 1) & mask);
        }
    }

    /// Resolve one full raw slot inside its account's canonical BAL range.
    pub fn storageId(self: *const ClaimPlan, account: AccountId, slot: u256) ?StorageId {
        const range = self.accountStorageRange(account);
        const window = self.storage_slots[range.start..range.end()];
        const S = struct {
            fn compareStorageSlot(target: u256, item: u256) std.math.Order {
                return std.math.order(target, item);
            }
        };
        const offset = std.sort.binarySearch(u256, window, slot, S.compareStorageSlot) orelse
            return null;
        return @enumFromInt(@as(u32, @intCast(range.start + offset)));
    }

    pub fn allocationBytes(self: *const ClaimPlan) usize {
        return self.account_addresses.len * @sizeOf(address.AddressWord) +
            self.account_storage_ranges.len * @sizeOf(Range) +
            self.account_trie_keys.len * @sizeOf(Hash) +
            self.storage_accounts.len * @sizeOf(AccountId) +
            self.storage_slots.len * @sizeOf(u256) +
            self.storage_trie_keys.len * @sizeOf(Hash) +
            self.account_trie_order.len * @sizeOf(AccountId) +
            self.storage_trie_order.len * @sizeOf(StorageId) +
            self.account_positions.len * @sizeOf(u32);
    }
};

/// Mix an address into the initial slot of `account_positions`.
/// This is not cryptographic; lookups verify the full address before returning an ID.
inline fn accountPositionHash(value: address.AddressWord) u64 {
    var mixed = value.words[0] ^ std.math.rotl(u64, value.words[1], 23) ^
        value.words[2] *% 0x9e3779b97f4a7c15;
    mixed ^= mixed >> 30;
    mixed *%= 0xbf58476d1ce4e5b9;
    mixed ^= mixed >> 27;
    mixed *%= 0x94d049bb133111eb;
    return mixed ^ (mixed >> 31);
}

fn accountTableCapacity(account_count: usize) InitError!usize {
    if (account_count == 0) return 0;
    const doubled = std.math.mul(usize, account_count, 2) catch
        return error.ResourceLimitExceeded;
    return std.math.ceilPowerOfTwo(usize, doubled) catch
        return error.ResourceLimitExceeded;
}

fn insertAccountPosition(
    positions: []u32,
    addresses: []const address.AddressWord,
    id: AccountId,
) void {
    const mask: u64 = positions.len - 1;
    var slot: usize = @intCast(accountPositionHash(addresses[@intFromEnum(id)]) & mask);
    while (positions[slot] != 0) slot = @intCast((slot + 1) & mask);
    positions[slot] = @intFromEnum(id) + 1;
}

fn accountTrieLessThan(trie_keys: []const Hash, lhs: AccountId, rhs: AccountId) bool {
    return std.mem.order(
        u8,
        &trie_keys[@intFromEnum(lhs)],
        &trie_keys[@intFromEnum(rhs)],
    ) == .lt;
}

fn storageTrieLessThan(trie_keys: []const Hash, lhs: StorageId, rhs: StorageId) bool {
    return std.mem.order(
        u8,
        &trie_keys[@intFromEnum(lhs)],
        &trie_keys[@intFromEnum(rhs)],
    ) == .lt;
}

fn rejectTrieKeyCollisions(
    comptime Id: type,
    trie_keys: []const Hash,
    order: []const Id,
) InitError!void {
    if (order.len < 2) return;
    for (order[1..], order[0 .. order.len - 1]) |current, previous| {
        if (std.mem.eql(
            u8,
            &trie_keys[@intFromEnum(previous)],
            &trie_keys[@intFromEnum(current)],
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
    try std.testing.expectEqual(@as(usize, 2), plan.accountCount());
    try std.testing.expectEqual(@as(usize, 5), plan.storageCount());
    try std.testing.expectEqual(address.addr(1), plan.accountAddress(@enumFromInt(0)));
    try std.testing.expectEqual(trie.hashedAddressKey(address.addr(1)), plan.accountTrieKey(@enumFromInt(0)));
    const first_storage = plan.storageSlots(@enumFromInt(0));
    try std.testing.expectEqual(@as(usize, 4), first_storage.len);
    try std.testing.expectEqualSlices(u256, &.{ 1, 3, 5, 9 }, first_storage);
    const second_storage = plan.storageSlots(@enumFromInt(1));
    try std.testing.expectEqual(@as(usize, 1), second_storage.len);
    try std.testing.expectEqual(@as(u256, 8), second_storage[0]);
    try expectAccountTrieOrder(plan);
    try expectStorageTrieOrder(plan, @enumFromInt(0));
    try expectStorageTrieOrder(plan, @enumFromInt(1));
    try std.testing.expectEqual(@as(usize, 512), plan.allocationBytes());
    try std.testing.expectEqual(@as(?AccountId, @enumFromInt(0)), plan.accountIdWord(.fromAddress(address.addr(1))));
    try std.testing.expectEqual(@as(?AccountId, @enumFromInt(1)), plan.accountIdWord(.fromAddress(address.addr(2))));
    try std.testing.expectEqual(@as(?AccountId, null), plan.accountIdWord(.fromAddress(address.addr(3))));
    try std.testing.expectEqual(@as(?StorageId, @enumFromInt(2)), plan.storageId(@enumFromInt(0), 5));
    try std.testing.expectEqual(@as(?StorageId, null), plan.storageId(@enumFromInt(0), 4));
    try std.testing.expectEqual(@as(AccountId, @enumFromInt(0)), plan.storageAccount(@enumFromInt(0)));
    try std.testing.expectEqual(@as(AccountId, @enumFromInt(1)), plan.storageAccount(@enumFromInt(4)));
    try std.testing.expectEqual(trie.hashedStorageKey(5), plan.storageTrieKey(@enumFromInt(2)));
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

test "account position table resolves collisions and terminates on a colliding miss" {
    var first: [4]?address.Address = .{null} ** 4;
    var second: [4]?address.Address = .{null} ** 4;
    var collision: [3]address.Address = undefined;
    var found = false;
    for (1..100) |value| {
        const candidate = address.addr(@as(u64, @intCast(value)));
        const slot: usize = @intCast(accountPositionHash(.fromAddress(candidate)) & 3);
        if (first[slot] == null) {
            first[slot] = candidate;
        } else if (second[slot] == null) {
            second[slot] = candidate;
        } else {
            collision = .{ first[slot].?, second[slot].?, candidate };
            found = true;
            break;
        }
    }
    try std.testing.expect(found);

    if (address.Address.order(collision[0], collision[1]) == .gt) {
        std.mem.swap(address.Address, &collision[0], &collision[1]);
    }
    const claims = [_]bal.AccountChanges{
        .{ .address = collision[0] },
        .{ .address = collision[1] },
    };
    try bal.validate(&claims, .{});

    var plan = try ClaimPlan.initAssumeValidated(std.testing.allocator, &claims);
    defer plan.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(?AccountId, @enumFromInt(0)), plan.accountIdWord(.fromAddress(collision[0])));
    try std.testing.expectEqual(@as(?AccountId, @enumFromInt(1)), plan.accountIdWord(.fromAddress(collision[1])));
    try std.testing.expectEqual(@as(?AccountId, null), plan.accountIdWord(.fromAddress(collision[2])));
}

fn expectAccountTrieOrder(plan: ClaimPlan) !void {
    if (plan.account_trie_order.len < 2) return;
    for (plan.account_trie_order[1..], plan.account_trie_order[0 .. plan.account_trie_order.len - 1]) |current, previous| {
        const previous_key = plan.accountTrieKey(previous);
        const current_key = plan.accountTrieKey(current);
        try std.testing.expect(std.mem.order(
            u8,
            &previous_key,
            &current_key,
        ) == .lt);
    }
}

fn expectStorageTrieOrder(plan: ClaimPlan, account: AccountId) !void {
    const order = plan.storageTrieOrder(account);
    if (order.len < 2) return;
    for (order[1..], order[0 .. order.len - 1]) |current, previous| {
        const previous_key = plan.storageTrieKey(previous);
        const current_key = plan.storageTrieKey(current);
        try std.testing.expect(std.mem.order(
            u8,
            &previous_key,
            &current_key,
        ) == .lt);
    }
}
