//! ID-native post-state commit for the dense Amsterdam execution lane.
//!
//! The sealed execution state stays projected as ClaimPlan IDs, pre-hashed
//! trie order, authenticated parent facts, and final dirty values. Generic
//! address/slot change records are deliberately outside this boundary.

const std = @import("std");

const trie = @import("../eth/trie.zig");
const mpt = @import("mpt");

const Allocator = std.mem.Allocator;

/// Comptime contract for the dense commit view this lane consumes. The
/// canonical implementation is `views.zig` `CommitView`; a conforming view
/// projects sealed rows by dense ID with no address/slot identity:
///
/// - `accountTrieOrder()` / `storageTrieOrder(account_id)`: dense IDs
///   pre-sorted by hashed trie key; commit iterates them verbatim.
/// - `accountDirty(id)` / `storageDirty(id)` / `accountStorageDirty(id)`:
///   whether the row (or any of an account's slots) needs a trie write.
/// - `accountTrieKey(id)` / `storageTrieKey(id)`: pre-hashed trie keys.
/// - `accountFact(id)`: authenticated parent fact; `.parent` distinguishes
///   absent from present-with-storage-root.
/// - `accountChanged(id)` + `accountValue(id)`: final execution value;
///   `storageWiped(account_id)` + `storageValue(storage_id)`: final slots.
pub fn assertCommitView(comptime View: type) void {
    for ([_][]const u8{
        "accountTrieOrder",
        "storageTrieOrder",
        "accountDirty",
        "storageDirty",
        "accountStorageDirty",
        "accountTrieKey",
        "storageTrieKey",
        "accountFact",
        "accountChanged",
        "accountValue",
        "storageValue",
        "storageWiped",
    }) |method| {
        if (!std.meta.hasMethod(View, method)) @compileError(
            "dense commit view " ++ @typeName(View) ++ " is missing '" ++ method ++ "'",
        );
    }
}

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
    comptime assertCommitView(@TypeOf(commit));
    var workspace = DenseCommitWorkspace.init(allocator);
    defer workspace.deinit();
    const commit_allocator = workspace.retainedAllocator();

    var dirty_account_count: usize = 0;
    for (commit.accountTrieOrder()) |account_id| {
        if (commit.accountDirty(account_id)) dirty_account_count += 1;
    }
    var account_updates: std.ArrayList(mpt.CatalogUpdate) =
        try .initCapacity(commit_allocator, dirty_account_count);
    var account_values: std.ArrayList(trie.AccountValueBuffer) =
        try .initCapacity(commit_allocator, dirty_account_count);

    for (commit.accountTrieOrder()) |account_id| {
        if (!commit.accountDirty(account_id)) continue;
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
            .key = commit.accountTrieKey(account_id),
            .value = value,
        });
    }
    std.debug.assert(account_updates.items.len == dirty_account_count);

    var scope = workspace.beginScope();
    defer scope.deinit();
    return trie.updateCatalogHashed(
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
    var updates: std.ArrayList(mpt.CatalogUpdate) =
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

    const root_ref: mpt.catalog.RootRef = if (wiped or
        std.mem.eql(u8, &parent_root, &trie.empty_root_hash))
        .empty
    else
        try catalog.storageCatalogRoot(parent_root);
    return trie.updateCatalogHashed(
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
    mpt_workspace: mpt.CatalogWorkspace,

    const Scope = struct {
        workspace: *DenseCommitWorkspace,
        mark: mpt.CatalogWorkspace.Mark,

        fn allocator(self: *Scope) Allocator {
            return self.workspace.mpt_workspace.allocator();
        }

        fn deinit(self: *Scope) void {
            self.workspace.mpt_workspace.rewind(self.mark);
            self.* = undefined;
        }
    };

    fn init(parent_allocator: Allocator) DenseCommitWorkspace {
        return .{ .mpt_workspace = mpt.CatalogWorkspace.init(parent_allocator) };
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
