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
    var account_updates: std.ArrayList(mpt.StatelessUpdate) =
        try .initCapacity(commit_allocator, dirty_account_count);
    var account_values: std.ArrayList(trie.AccountValueBuffer) =
        try .initCapacity(commit_allocator, dirty_account_count);

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
                trie.accountValueInto(account_values.addOneAssumeCapacity(), account);
        };
        account_updates.appendAssumeCapacity(.{
            .key = claim.trie_key,
            .value = value,
        });
    }
    std.debug.assert(account_updates.items.len == dirty_account_count);

    var scope = workspace.beginScope();
    defer scope.deinit();
    return trie.updateStatelessCatalogHashed(
        &workspace.mpt_workspace,
        scope.allocator(),
        root_hash,
        catalog,
        catalog.stateCatalogRoot(),
        account_updates.items,
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
    var updates: std.ArrayList(mpt.StatelessUpdate) =
        try .initCapacity(allocator, dirty_storage_count);
    var values: std.ArrayList(trie.StorageValueBuffer) =
        try .initCapacity(allocator, dirty_storage_count);

    for (commit.storageTrieOrder(account_id)) |storage_id| {
        if (!commit.storageDirty(storage_id)) continue;
        const claim = commit.storageClaim(storage_id);
        const current = commit.storageValue(storage_id);
        updates.appendAssumeCapacity(.{
            .key = claim.trie_key,
            .value = if (current == 0)
                null
            else
                trie.storageValueInto(values.addOneAssumeCapacity(), current),
        });
    }
    std.debug.assert(updates.items.len == dirty_storage_count);

    const root_ref: mpt.catalog.RootRef = if (wiped or
        std.mem.eql(u8, &parent_root, &trie.empty_root_hash))
        .empty
    else
        try catalog.storageCatalogRoot(parent_root);
    return trie.updateStatelessCatalogHashed(
        &workspace.mpt_workspace,
        allocator,
        base_root,
        catalog,
        root_ref,
        updates.items,
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
};
