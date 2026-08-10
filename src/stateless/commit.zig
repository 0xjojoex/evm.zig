//! ID-native post-state commit for the dense Amsterdam execution lane.
//!
//! The sealed execution state stays projected as ClaimPlan IDs, pre-hashed
//! trie order, authenticated parent facts, and final dirty values. Generic
//! address/slot change records are deliberately outside this boundary.

const std = @import("std");

const trie = @import("../eth/trie.zig");
const mpt = @import("mpt");

const Allocator = std.mem.Allocator;

/// Commit sealed dense rows without projecting them back through generic
/// address/slot changes. Parent facts and catalog topology remain borrowed;
/// this stage removes identity reconstruction and feeds pre-hashed sorted
/// updates into the existing catalog occurrence updater.
pub fn stateRootAfterCatalog(
    allocator: Allocator,
    root_hash: mpt.Root,
    catalog: *const trie.WitnessCatalog,
    commit: anytype,
) trie.UpdateError![32]u8 {
    var workspace = DenseCommitWorkspace.init(allocator);
    defer workspace.deinit();
    const commit_allocator = workspace.retainedAllocator();

    var dirty_account_count: usize = 0;
    for (commit.accountTrieOrder()) |account_id| {
        if (commit.accountDirty(account_id)) dirty_account_count += 1;
    }
    var no_account_updates: [0]mpt.StatelessUpdate = .{};
    const account_updates = if (dirty_account_count == 0)
        no_account_updates[0..]
    else
        try commit_allocator.alloc(mpt.StatelessUpdate, dirty_account_count);
    var no_account_values: [0]trie.AccountValueBuffer = .{};
    const account_values = if (dirty_account_count == 0)
        no_account_values[0..]
    else
        try commit_allocator.alloc(trie.AccountValueBuffer, dirty_account_count);

    var update_index: usize = 0;
    for (commit.accountTrieOrder()) |account_id| {
        if (!commit.accountDirty(account_id)) continue;
        const claim = commit.accountClaim(account_id);
        const fact = commit.accountFact(account_id);
        const account_changed = commit.accountChanged(account_id);
        const current = commit.accountValue(account_id);
        const deleted = account_changed and current == .absent;
        const value: ?[]const u8 = if (deleted)
            null
        else value: {
            var account = switch (fact.parent) {
                .absent => trie.Account{},
                .present => |parent| parent,
            };
            if (account_changed) switch (current) {
                .absent => unreachable,
                .present => |execution| {
                    account.nonce = execution.nonce;
                    account.balance = execution.balance;
                    account.code_hash = execution.code_hash;
                },
            };
            account.storage_root = try storageRootAfterCatalog(
                &workspace,
                catalog,
                commit,
                account_id,
                switch (fact.parent) {
                    .absent => trie.empty_root_hash,
                    .present => |parent| parent.storage_root,
                },
            );
            break :value if (account.hasNoState())
                null
            else
                trie.accountValueFromInto(&account_values[update_index], account);
        };
        account_updates[update_index] = .{
            .key = claim.trie_key,
            .value = value,
        };
        update_index += 1;
    }
    std.debug.assert(update_index == account_updates.len);

    var scope = workspace.beginScope();
    defer scope.deinit();
    return trie.updateStatelessCatalogHashed(
        workspace.mptWorkspace(),
        scope.allocator(),
        root_hash,
        catalog,
        catalog.stateCatalogRoot(),
        account_updates,
    );
}

fn storageRootAfterCatalog(
    workspace: *DenseCommitWorkspace,
    catalog: *const trie.WitnessCatalog,
    commit: anytype,
    account_id: anytype,
    parent_root: [32]u8,
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
    const updates = try allocator.alloc(mpt.StatelessUpdate, dirty_storage_count);
    const values = try allocator.alloc(trie.StorageValueBuffer, dirty_storage_count);

    var update_index: usize = 0;
    for (commit.storageTrieOrder(account_id)) |storage_id| {
        if (!commit.storageDirty(storage_id)) continue;
        const claim = commit.storageClaim(storage_id);
        const current = commit.storageValue(storage_id);
        updates[update_index] = .{
            .key = claim.trie_key,
            .value = if (current == 0)
                null
            else
                trie.storageValueInto(&values[update_index], current),
        };
        update_index += 1;
    }
    std.debug.assert(update_index == updates.len);

    const root_ref: mpt.catalog.RootRef = if (wiped or
        std.mem.eql(u8, &parent_root, &trie.empty_root_hash))
        .empty
    else
        try catalog.storageCatalogRoot(parent_root);
    return trie.updateStatelessCatalogHashed(
        workspace.mptWorkspace(),
        allocator,
        base_root,
        catalog,
        root_ref,
        updates,
    );
}

/// Owns the serial dense-commit lifetime tree. Retained account material lives
/// at the root; each storage calculation and MPT update gets a nested scope.
const DenseCommitWorkspace = struct {
    mpt_workspace: mpt.StatelessWorkspace,

    const Scope = struct {
        workspace: *DenseCommitWorkspace,
        mark: mpt.StatelessWorkspace.Mark,

        fn allocator(self: *Scope) Allocator {
            return self.workspace.mpt_workspace.allocator();
        }

        fn deinit(self: *Scope) void {
            self.workspace.mpt_workspace.rewind(self.mark);
            self.* = undefined;
        }
    };

    fn init(parent_allocator: Allocator) DenseCommitWorkspace {
        return .{ .mpt_workspace = mpt.StatelessWorkspace.init(parent_allocator) };
    }

    fn deinit(self: *DenseCommitWorkspace) void {
        self.mpt_workspace.deinit();
        self.* = undefined;
    }

    fn retainedAllocator(self: *DenseCommitWorkspace) Allocator {
        return self.mpt_workspace.allocator();
    }

    fn beginScope(self: *DenseCommitWorkspace) Scope {
        return .{ .workspace = self, .mark = self.mpt_workspace.mark() };
    }

    fn mptWorkspace(self: *DenseCommitWorkspace) *mpt.StatelessWorkspace {
        return &self.mpt_workspace;
    }
};
