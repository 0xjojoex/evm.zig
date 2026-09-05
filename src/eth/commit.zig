//! Post-state root from a sealed commit view.
//!
//! A commit view is the accepted branch projected as dense ids in trie order
//! with pre-hashed keys (`state.checkCommitView`). The closed lane's view is
//! the claim plan itself; the open lane and detached deltas project through
//! `SortedChanges`. Either way the trie walks pre-sorted fixed keys and never
//! reconstructs identity from address/slot change records.

const std = @import("std");

const address = @import("../address.zig");
const state = @import("../state.zig");
const StateDelta = @import("../state/StateDelta.zig");
const Backend = @import("../backend.zig").Backend;
const trie = @import("trie.zig");
const mpt = @import("mpt");

const Allocator = std.mem.Allocator;
const Address = address.Address;
const Account = state.Account;

pub const RootError = error{
    InfrastructureFailure,
    InvalidWitness,
    OutOfMemory,
    ResourceLimitExceeded,
};

/// Post-state root of an accepted view against the block's backend. A world
/// that authenticated its parents at admission commits its rows directly and
/// can only have done so from a witness; any other world is sorted into a
/// commit view for a witness, or detached into a delta for an external root
/// provider. `node_updates` is a witness-only retention target. `delta` starts
/// null and receives the external delta; the candidate owns it even on failure
/// and reuses it for commit or transfers it to the caller's output.
pub fn stateRoot(
    allocator: Allocator,
    backend: *Backend,
    accepted: anytype,
    node_updates: ?*trie.NodeUpdates,
    delta: *?StateDelta,
) RootError![32]u8 {
    std.debug.assert(delta.* == null);
    const State = @typeInfo(@TypeOf(accepted.state)).pointer.child;
    const authenticated = State.CommitView.authenticated_parents;
    switch (backend.*) {
        .witness => |*witness| {
            if (comptime authenticated) {
                return witness.stateRootAfterCommit(allocator, accepted.commit(), node_updates) catch |err|
                    return normalizeRootError(err);
            }
            var sorted = SortedChanges.init(allocator, accepted.changes()) catch
                return error.OutOfMemory;
            defer sorted.deinit();
            return witness.stateRootAfterCommit(allocator, sorted, node_updates) catch |err|
                return normalizeRootError(err);
        },
        .external => |external| {
            if (comptime authenticated) return error.InvalidWitness;
            std.debug.assert(node_updates == null);
            delta.* = StateDelta.init(allocator, accepted.changes()) catch
                return error.OutOfMemory;
            return external.root_provider.afterChanges(allocator, delta.*.?.view()) catch |err|
                return normalizeRootError(err);
        },
    }
}

fn normalizeRootError(err: anyerror) RootError {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.ResourceLimitExceeded => error.ResourceLimitExceeded,
        error.InvalidWitness => error.InvalidWitness,
        else => error.InfrastructureFailure,
    };
}

/// Commit sealed rows through a witness catalog. Parent facts stay borrowed
/// from the view when it authenticated them at admission, otherwise they are
/// resolved from the catalog by hashed key; either way the catalog receives
/// pre-hashed sorted updates.
pub fn stateRootAfterCommit(
    allocator: Allocator,
    root_hash: mpt.Root,
    catalog: *const trie.WitnessCatalog,
    commit: anytype,
) trie.UpdateError![32]u8 {
    return stateRootAfterCommitWithNodeUpdates(allocator, root_hash, catalog, commit, {});
}

pub fn stateRootAfterCommitWithNodeUpdates(
    allocator: Allocator,
    root_hash: mpt.Root,
    catalog: *const trie.WitnessCatalog,
    commit: anytype,
    node_updates: anytype,
) trie.UpdateError![32]u8 {
    comptime state.checkCommitView(@TypeOf(commit));
    try catalog.validateStateRoot(root_hash);
    var workspace = DenseCommitWorkspace.init(allocator);
    defer workspace.deinit();
    const commit_allocator = workspace.retainedAllocator();

    var dirty_account_count: usize = 0;
    for (commit.accountTrieOrder()) |account_id| {
        if (commit.accountDirty(account_id)) dirty_account_count += 1;
    }
    var account_updates: std.ArrayList(mpt.FixedUpdate) =
        try .initCapacity(commit_allocator, dirty_account_count);
    var account_values: std.ArrayList(trie.AccountValueBuffer) =
        try .initCapacity(commit_allocator, dirty_account_count);

    for (commit.accountTrieOrder()) |account_id| {
        if (!commit.accountDirty(account_id)) continue;
        const parent = try parentAccount(catalog, commit, account_id);
        const account_changed = commit.accountChanged(account_id);
        const current = commit.accountValue(account_id);
        const deleted = account_changed and current == null;
        const value: ?[]const u8 = if (deleted)
            null
        else value: {
            var account = parent;
            if (account_changed) {
                const execution = current.?;
                account.nonce = execution.nonce;
                account.balance = execution.balance;
                account.code_hash = execution.code_hash;
            }
            account.storage_root = try storageRootAfterCommit(
                &workspace,
                catalog,
                commit,
                account_id,
                parent.storage_root,
                node_updates,
            );
            break :value if (account.hasNoState())
                null
            else
                trie.accountValueInto(account_values.addOneAssumeCapacity(), account);
        };
        account_updates.appendAssumeCapacity(.{
            .key = commit.accountTrieKey(account_id),
            .value = value,
        });
    }
    std.debug.assert(account_updates.items.len == dirty_account_count);

    return if (comptime @TypeOf(node_updates) == void)
        trie.updateHashedSorted(
            &workspace.arena,
            catalog.source(catalog.stateCatalogRoot()),
            account_updates.items,
        )
    else
        trie.updateHashedSortedWithNodeUpdates(
            &workspace.arena,
            catalog.source(catalog.stateCatalogRoot()),
            account_updates.items,
            node_updates,
        );
}

/// The parent trie account an update starts from; empty when the account is
/// absent in the parent state.
fn parentAccount(
    catalog: *const trie.WitnessCatalog,
    commit: anytype,
    account_id: anytype,
) trie.UpdateError!trie.Account {
    if (comptime @TypeOf(commit).authenticated_parents) {
        return switch (commit.accountFact(account_id).parent) {
            .absent => .{},
            .present => |parent| parent,
        };
    }
    const key = commit.accountTrieKey(account_id);
    return (try catalog.decodedAccount(&key)) orelse .{};
}

fn storageRootAfterCommit(
    workspace: *DenseCommitWorkspace,
    catalog: *const trie.WitnessCatalog,
    commit: anytype,
    account_id: anytype,
    parent_root: [32]u8,
    node_updates: anytype,
) trie.UpdateError![32]u8 {
    if (!commit.accountStorageDirty(account_id)) return parent_root;
    var scope = workspace.beginScope();
    defer scope.deinit();
    const allocator = scope.allocator();
    const wiped = commit.storageWiped(account_id);
    const base_root = if (wiped) trie.empty_root_hash else parent_root;

    var dirty_storage_count: usize = 0;
    for (commit.storageTrieOrder(account_id)) |storage_id| {
        if (commit.storageDirty(storage_id)) dirty_storage_count += 1;
    }
    if (dirty_storage_count == 0) return base_root;
    var updates: std.ArrayList(mpt.FixedUpdate) =
        try .initCapacity(allocator, dirty_storage_count);
    var values: std.ArrayList(trie.StorageValueBuffer) =
        try .initCapacity(allocator, dirty_storage_count);

    for (commit.storageTrieOrder(account_id)) |storage_id| {
        if (!commit.storageDirty(storage_id)) continue;
        const current = commit.storageValue(storage_id);
        updates.appendAssumeCapacity(.{
            .key = commit.storageTrieKey(storage_id),
            .value = if (current == 0)
                null
            else
                trie.storageValueInto(values.addOneAssumeCapacity(), current),
        });
    }
    std.debug.assert(updates.items.len == dirty_storage_count);

    const root_ref: mpt.Catalog.Root = if (wiped or
        std.mem.eql(u8, &parent_root, &trie.empty_root_hash))
        .empty
    else
        try catalog.storageCatalogRoot(parent_root);
    return if (comptime @TypeOf(node_updates) == void)
        trie.updateHashedSorted(
            &workspace.arena,
            catalog.source(root_ref),
            updates.items,
        )
    else
        trie.updateHashedSortedWithNodeUpdates(
            &workspace.arena,
            catalog.source(root_ref),
            updates.items,
            node_updates,
        );
}

/// Owns the serial dense-commit lifetime tree. Retained account material lives
/// at the root; each storage calculation gets a nested scope, while catalog
/// mutation scopes itself inside the same arena.
const DenseCommitWorkspace = struct {
    arena: mpt.ScopedArenaAllocator,

    const Scope = struct {
        workspace: *DenseCommitWorkspace,
        mark: mpt.ScopedArenaAllocator.Mark,

        fn allocator(self: *Scope) Allocator {
            return self.workspace.arena.allocator();
        }

        fn deinit(self: *Scope) void {
            self.workspace.arena.rewind(self.mark);
            self.* = undefined;
        }
    };

    fn init(parent_allocator: Allocator) DenseCommitWorkspace {
        return .{ .arena = mpt.ScopedArenaAllocator.init(parent_allocator) };
    }

    fn deinit(self: *DenseCommitWorkspace) void {
        self.arena.deinit();
        self.* = undefined;
    }

    fn retainedAllocator(self: *DenseCommitWorkspace) Allocator {
        return self.arena.allocator();
    }

    fn beginScope(self: *DenseCommitWorkspace) Scope {
        return .{ .workspace = self, .mark = self.arena.mark() };
    }
};

/// Commit view for a producer with no trie order of its own: hashes and sorts
/// address-keyed changes once, at seal. The open lane and detached deltas
/// project through it; the closed lane's plan already carries the order.
///
/// Only dirty accounts enter, so every account and slot answers dirty. A
/// deleted account keeps its slots listed; the committer drops the leaf
/// before it looks at them. Parents are not authenticated here: the
/// committer resolves them from the catalog by hashed key.
pub const SortedChanges = struct {
    allocator: Allocator,
    accounts: []AccountEntry,
    account_order: []AccountId,
    storage: []StorageEntry,
    storage_order: []StorageId,

    pub const AccountId = enum(u32) { _ };
    pub const StorageId = enum(u32) { _ };
    pub const authenticated_parents = false;

    const AccountEntry = struct {
        key: [32]u8,
        value: ?Account = null,
        changed: bool = false,
        wiped: bool = false,
        storage_start: u32 = 0,
        storage_len: u32 = 0,

        fn lessThan(_: void, lhs: AccountEntry, rhs: AccountEntry) bool {
            return keyLessThan(lhs.key, rhs.key);
        }
    };

    const StorageEntry = struct {
        key: [32]u8,
        value: u256,

        fn lessThan(_: void, lhs: StorageEntry, rhs: StorageEntry) bool {
            return keyLessThan(lhs.key, rhs.key);
        }
    };

    const AddressIndex = std.array_hash_map.Auto(Address, u32);

    pub fn init(allocator: Allocator, changes: anytype) Allocator.Error!SortedChanges {
        comptime state.checkChangesView(@TypeOf(changes));

        var index: AddressIndex = .empty;
        defer index.deinit(allocator);
        var entries: std.ArrayList(AccountEntry) = .empty;
        errdefer entries.deinit(allocator);

        var account_index: u32 = 0;
        while (account_index < changes.accounts.len()) : (account_index += 1) {
            const change = changes.accounts.at(account_index);
            const entry = try entryFor(allocator, &index, &entries, change.address);
            std.debug.assert(!entry.changed);
            entry.changed = true;
            entry.value = change.account;
        }

        var wipe_index: u32 = 0;
        while (wipe_index < changes.storage_wipes.len()) : (wipe_index += 1) {
            const entry = try entryFor(allocator, &index, &entries, changes.storage_wipes.at(wipe_index));
            entry.wiped = true;
        }

        var storage_index: u32 = 0;
        while (storage_index < changes.storage_writes.len()) : (storage_index += 1) {
            const write = changes.storage_writes.at(storage_index);
            const entry = try entryFor(allocator, &index, &entries, write.address);
            entry.storage_len += 1;
        }

        const cursors = try allocator.alloc(u32, entries.items.len);
        defer allocator.free(cursors);
        var storage_total: u32 = 0;
        for (entries.items, cursors) |*entry, *cursor| {
            entry.storage_start = storage_total;
            cursor.* = storage_total;
            storage_total += entry.storage_len;
        }

        const storage = try allocator.alloc(StorageEntry, storage_total);
        errdefer allocator.free(storage);
        storage_index = 0;
        while (storage_index < changes.storage_writes.len()) : (storage_index += 1) {
            const write = changes.storage_writes.at(storage_index);
            const slot = index.get(write.address).?;
            storage[cursors[slot]] = .{
                .key = trie.hashedStorageKey(write.key),
                .value = write.value,
            };
            cursors[slot] += 1;
        }
        for (entries.items) |entry| {
            std.mem.sort(
                StorageEntry,
                storage[entry.storage_start..][0..entry.storage_len],
                {},
                StorageEntry.lessThan,
            );
        }
        std.mem.sort(AccountEntry, entries.items, {}, AccountEntry.lessThan);

        const account_order = try allocator.alloc(AccountId, entries.items.len);
        errdefer allocator.free(account_order);
        for (account_order, 0..) |*id, position| id.* = @enumFromInt(position);
        const storage_order = try allocator.alloc(StorageId, storage_total);
        errdefer allocator.free(storage_order);
        for (storage_order, 0..) |*id, position| id.* = @enumFromInt(position);

        return .{
            .allocator = allocator,
            .accounts = try entries.toOwnedSlice(allocator),
            .account_order = account_order,
            .storage = storage,
            .storage_order = storage_order,
        };
    }

    fn entryFor(
        allocator: Allocator,
        index: *AddressIndex,
        entries: *std.ArrayList(AccountEntry),
        target: Address,
    ) Allocator.Error!*AccountEntry {
        const result = try index.getOrPut(allocator, target);
        if (!result.found_existing) {
            errdefer index.swapRemoveAt(result.index);
            result.value_ptr.* = @intCast(entries.items.len);
            try entries.append(allocator, .{ .key = trie.hashedAddressKey(target) });
        }
        return &entries.items[result.value_ptr.*];
    }

    pub fn deinit(self: *SortedChanges) void {
        self.allocator.free(self.storage_order);
        self.allocator.free(self.storage);
        self.allocator.free(self.account_order);
        self.allocator.free(self.accounts);
        self.* = undefined;
    }

    pub fn accountTrieOrder(self: SortedChanges) []const AccountId {
        return self.account_order;
    }

    pub fn storageTrieOrder(self: SortedChanges, account: AccountId) []const StorageId {
        const entry = self.accountEntry(account);
        return self.storage_order[entry.storage_start..][0..entry.storage_len];
    }

    pub fn accountTrieKey(self: SortedChanges, id: AccountId) [32]u8 {
        return self.accountEntry(id).key;
    }

    pub fn storageTrieKey(self: SortedChanges, id: StorageId) [32]u8 {
        return self.storage[@intFromEnum(id)].key;
    }

    pub fn accountDirty(_: SortedChanges, _: AccountId) bool {
        return true;
    }

    pub fn accountChanged(self: SortedChanges, id: AccountId) bool {
        return self.accountEntry(id).changed;
    }

    pub fn accountValue(self: SortedChanges, id: AccountId) ?Account {
        return self.accountEntry(id).value;
    }

    pub fn accountStorageDirty(self: SortedChanges, id: AccountId) bool {
        const entry = self.accountEntry(id);
        return entry.wiped or entry.storage_len != 0;
    }

    pub fn storageDirty(_: SortedChanges, _: StorageId) bool {
        return true;
    }

    pub fn storageWiped(self: SortedChanges, id: AccountId) bool {
        return self.accountEntry(id).wiped;
    }

    pub fn storageValue(self: SortedChanges, id: StorageId) u256 {
        return self.storage[@intFromEnum(id)].value;
    }

    fn accountEntry(self: SortedChanges, id: AccountId) *const AccountEntry {
        return &self.accounts[@intFromEnum(id)];
    }
};

fn keyLessThan(lhs: [32]u8, rhs: [32]u8) bool {
    return std.mem.lessThan(u8, &lhs, &rhs);
}

comptime {
    state.checkCommitView(SortedChanges);
}
