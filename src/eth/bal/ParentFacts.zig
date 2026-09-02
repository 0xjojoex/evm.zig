//! Immutable parent-state truth for one block, authenticated against the
//! catalog and indexed by dense claim id.
//!
//! The catalog remains owned by `WitnessStateReader`. This object owns only
//! one account fact per BAL account and one storage fact per BAL slot. Claim
//! identity and trie ordering remain in the borrowed `ClaimPlan`.

const std = @import("std");

const address = @import("../../address.zig");
const bal = @import("model.zig");
const claim_plan = @import("ClaimPlan.zig");
const trie = @import("../trie.zig");
const mpt = @import("mpt");
const rlp = @import("rlp");

const Allocator = std.mem.Allocator;
const ParentFacts = @This();
pub const AccountParent = union(enum) {
    absent: mpt.FixedAbsence,
    present: trie.Account,
};

/// Dense index is `ClaimPlan.AccountId`; identity is intentionally not copied.
pub const AccountFact = struct {
    parent: AccountParent,
};

/// Dense index is `ClaimPlan.StorageId`; identity is intentionally not copied.
pub const StorageFact = struct {
    value: u256,
};

pub const Error = std.mem.Allocator.Error || trie.ProofLookupError;

accounts: []AccountFact = &.{},
storage: []StorageFact = &.{},

/// Copy fixture/integration facts into the owned block-lifetime representation.
pub fn initCopy(
    allocator: Allocator,
    account_facts: []const AccountFact,
    storage_facts: []const StorageFact,
) Allocator.Error!ParentFacts {
    const accounts = try allocator.dupe(AccountFact, account_facts);
    errdefer allocator.free(accounts);
    const storage = try allocator.dupe(StorageFact, storage_facts);
    return .{ .accounts = accounts, .storage = storage };
}

pub fn authenticate(
    allocator: Allocator,
    plan: claim_plan.ClaimPlan,
    catalog: *const trie.WitnessCatalog,
) Error!ParentFacts {
    const accounts = try allocator.alloc(AccountFact, plan.accountCount());
    errdefer allocator.free(accounts);
    const storage = try allocator.alloc(StorageFact, plan.storageCount());
    errdefer allocator.free(storage);

    // Account and storage lookups are serial, so they reuse the same typed
    // scratch slices and capacity is their maximum.
    const scratch_capacity = @max(plan.accountCount(), plan.storageCount());
    const keys = try allocator.alloc(mpt.FixedKey, scratch_capacity);
    defer allocator.free(keys);
    const results = try allocator.alloc(mpt.FixedLookup, scratch_capacity);
    defer allocator.free(results);
    const account_keys = keys[0..plan.accountCount()];
    const account_results = results[0..plan.accountCount()];
    for (plan.account_trie_order, 0..) |id, index| {
        account_keys[index] = plan.accountTrieKey(id);
    }
    var workspace: mpt.Catalog.BindWorkspace = .{};
    try catalog.topology.bindAssumeSorted(
        catalog.stateCatalogRoot(),
        account_keys,
        account_results,
        &workspace,
    );
    for (plan.account_trie_order, account_results) |id, result| {
        const fact = &accounts[@intFromEnum(id)];
        switch (result) {
            .present => |encoded| {
                fact.* = .{ .parent = .{ .present = undefined } };
                const account = switch (fact.parent) {
                    .present => |*value| value,
                    .absent => unreachable,
                };
                try trie.decodeAccountValueInto(encoded, account);
            },
            .absent => |absence| fact.* = .{ .parent = .{ .absent = absence } },
        }
    }

    @memset(storage, .{ .value = 0 });
    const storage_keys = keys[0..plan.storageCount()];
    const storage_results = results[0..plan.storageCount()];
    for (accounts, 0..) |account, account_index| {
        const id: claim_plan.AccountId = @enumFromInt(account_index);
        const order = plan.storageTrieOrder(id);
        if (order.len == 0) continue;
        const parent = switch (account.parent) {
            .absent => continue,
            .present => |value| value,
        };
        if (std.mem.eql(u8, &parent.storage_root, &trie.empty_root_hash)) continue;

        const range = plan.accountStorageRange(id);
        const begin: usize = range.start;
        const end: usize = range.end();
        for (order, 0..) |storage_id, offset| {
            storage_keys[begin + offset] = plan.storageTrieKey(storage_id);
        }
        try catalog.topology.bindAssumeSorted(
            try catalog.storageCatalogRoot(parent.storage_root),
            storage_keys[begin..end],
            storage_results[begin..end],
            &workspace,
        );
        for (order, storage_results[begin..end]) |storage_id, result| {
            const fact = &storage[@intFromEnum(storage_id)];
            switch (result) {
                .absent => {},
                .present => |encoded| fact.value = try trie.decodeStorageValue(encoded),
            }
        }
    }

    return .{
        .accounts = accounts,
        .storage = storage,
    };
}

pub fn deinit(self: *ParentFacts, allocator: Allocator) void {
    allocator.free(self.storage);
    allocator.free(self.accounts);
    self.* = undefined;
}

pub fn allocationBytes(self: ParentFacts) usize {
    return self.accounts.len * @sizeOf(AccountFact) +
        self.storage.len * @sizeOf(StorageFact);
}

test "catalog records bind typed account and storage facts without another topology" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    const target = address.addr(1);
    const slot: u256 = 7;
    const storage_key = trie.hashedStorageKey(slot);
    const storage_value = try trie.storageValue(scratch, 42);
    const storage_leaf = try testLeafNode(scratch, storage_key, storage_value);
    const storage_root = mpt.StdKeccak256Context.keccak256(.{}, storage_leaf);
    const account_value = try trie.accountValue(scratch, 3, 9, storage_root, [_]u8{0x44} ** 32);
    const account_leaf = try testLeafNode(scratch, trie.hashedAddressKey(target), account_value);
    const state_root = mpt.StdKeccak256Context.keccak256(.{}, account_leaf);
    const nodes = [_][]const u8{ account_leaf, storage_leaf };
    var indexed = try trie.indexWitness(scratch, &nodes);
    defer indexed.deinit();
    var catalog = try trie.buildWitnessCatalog(scratch, state_root, indexed);
    defer catalog.deinit();

    const claims = [_]bal.AccountChanges{.{ .address = target, .storage_reads = &.{slot} }};
    try bal.validate(&claims, .{ .transaction_count = 0 });
    var plan = try claim_plan.ClaimPlan.initAssumeValidated(scratch, &claims);
    defer plan.deinit(scratch);
    var records = try authenticate(scratch, plan, &catalog);
    defer records.deinit(scratch);

    try std.testing.expectEqual(@as(usize, 1), records.accounts.len);
    try std.testing.expectEqual(@as(u64, 3), records.accounts[0].parent.present.nonce);
    try std.testing.expectEqual(@as(u256, 9), records.accounts[0].parent.present.balance);
    try std.testing.expectEqual(@as(usize, 1), records.storage.len);
    try std.testing.expectEqual(@as(u256, 42), records.storage[0].value);
    try std.testing.expectEqual(
        @sizeOf(AccountFact) + @sizeOf(StorageFact),
        records.allocationBytes(),
    );
}

test "catalog records inherit absence without resolving storage" {
    const claims = [_]bal.AccountChanges{.{ .address = address.addr(2), .storage_reads = &.{7} }};
    var plan = try claim_plan.ClaimPlan.initAssumeValidated(std.testing.allocator, &claims);
    defer plan.deinit(std.testing.allocator);
    var indexed = try trie.indexWitness(std.testing.allocator, &.{});
    defer indexed.deinit();
    var catalog = try trie.buildWitnessCatalog(std.testing.allocator, trie.empty_root_hash, indexed);
    defer catalog.deinit();
    var records = try authenticate(std.testing.allocator, plan, &catalog);
    defer records.deinit(std.testing.allocator);

    try std.testing.expect(records.accounts[0].parent == .absent);
    try std.testing.expectEqual(@as(u256, 0), records.storage[0].value);
}

test "authentication workspace is transient and facts reclaim in LIFO order" {
    const claims = [_]bal.AccountChanges{.{ .address = address.addr(2), .storage_reads = &.{7} }};
    var plan = try claim_plan.ClaimPlan.initAssumeValidated(std.testing.allocator, &claims);
    defer plan.deinit(std.testing.allocator);
    var indexed = try trie.indexWitness(std.testing.allocator, &.{});
    defer indexed.deinit();
    var catalog = try trie.buildWitnessCatalog(std.testing.allocator, trie.empty_root_hash, indexed);
    defer catalog.deinit();
    var backing: [1024]u8 align(16) = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&backing);

    var records = try authenticate(fixed.allocator(), plan, &catalog);
    try std.testing.expectEqual(records.allocationBytes(), fixed.end_index);
    records.deinit(fixed.allocator());
    try std.testing.expectEqual(@as(usize, 0), fixed.end_index);
}

test "catalog records clean every allocation failure position" {
    const Harness = struct {
        fn run(allocator: Allocator) !void {
            const target = address.addr(1);
            const account_value = try trie.accountValueFrom(allocator, .{ .balance = 1 });
            defer allocator.free(account_value);
            const leaf = try testLeafNode(allocator, trie.hashedAddressKey(target), account_value);
            defer allocator.free(leaf);
            const root = mpt.StdKeccak256Context.keccak256(.{}, leaf);
            const nodes = [_][]const u8{leaf};
            var indexed = try trie.indexWitness(allocator, &nodes);
            defer indexed.deinit();
            var catalog = try trie.buildWitnessCatalog(allocator, root, indexed);
            defer catalog.deinit();
            const claims = [_]bal.AccountChanges{.{ .address = target }};
            var plan = try claim_plan.ClaimPlan.initAssumeValidated(allocator, &claims);
            defer plan.deinit(allocator);
            var records = try authenticate(allocator, plan, &catalog);
            defer records.deinit(allocator);
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Harness.run, .{});
}

fn testLeafNode(allocator: Allocator, key: [32]u8, value: []const u8) ![]u8 {
    var compact: [33]u8 = undefined;
    compact[0] = 0x20;
    @memcpy(compact[1..], &key);
    var payload = rlp.Writer.alloc(allocator);
    defer payload.deinit();
    try payload.bytes(&compact);
    try payload.bytes(value);
    var out = rlp.Writer.alloc(allocator);
    errdefer out.deinit();
    try out.listPayload(payload.written());
    return out.toOwnedSlice() catch |err| switch (err) {
        error.BorrowedWriter => unreachable,
        error.OutOfMemory => error.OutOfMemory,
    };
}
