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
    var workspace = mpt.StatelessWorkspace.init(allocator);
    defer workspace.deinit();

    var account_updates: std.ArrayList(mpt.StatelessUpdate) = .empty;
    defer account_updates.deinit(allocator);

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
                allocator,
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
                try trie.accountValueFrom(allocator, account);
        };
        try account_updates.append(allocator, .{
            .key = claim.trie_key,
            .value = value,
        });
    }

    return trie.updateStatelessCatalogHashed(
        &workspace,
        allocator,
        root_hash,
        catalog,
        catalog.stateCatalogRoot(),
        account_updates.items,
    );
}

fn storageRootAfterCatalog(
    workspace: *mpt.StatelessWorkspace,
    allocator: Allocator,
    catalog: *const trie.WitnessCatalog,
    commit: anytype,
    account_id: anytype,
    parent_root: [32]u8,
) trie.UpdateError![32]u8 {
    if (!commit.accountStorageDirty(account_id)) return parent_root;
    const wiped = commit.storageWiped(account_id);
    const base_root = if (wiped) trie.empty_root_hash else parent_root;
    var updates: std.ArrayList(mpt.StatelessUpdate) = .empty;
    defer updates.deinit(allocator);

    for (commit.storageTrieOrder(account_id)) |storage_id| {
        if (!commit.storageDirty(storage_id)) continue;
        const claim = commit.storageClaim(storage_id);
        const current = commit.storageValue(storage_id);
        try updates.append(allocator, .{
            .key = claim.trie_key,
            .value = if (current == 0) null else try trie.storageValue(allocator, current),
        });
    }
    if (updates.items.len == 0) return base_root;

    const root_ref: mpt.catalog.RootRef = if (wiped or
        std.mem.eql(u8, &parent_root, &trie.empty_root_hash))
        .empty
    else
        try catalog.storageCatalogRoot(parent_root);
    return trie.updateStatelessCatalogHashed(
        workspace,
        allocator,
        base_root,
        catalog,
        root_ref,
        updates.items,
    );
}
