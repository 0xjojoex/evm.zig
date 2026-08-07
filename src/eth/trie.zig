//! Ethereum execution MPT helpers for root construction, proof lookup, and
//! witness-backed root updates.
//! This is not a persistent trie database or a complete general-purpose MPT library.

const std = @import("std");

const address = @import("../address.zig");
const crypto = @import("../crypto.zig");
const rlp = @import("rlp");
const mpt = @import("mpt");
const uint256 = @import("../uint256.zig");
const SparseHashMap = @import("../state/sparse_hash_map.zig").Auto;
const t = @import("../t.zig");
const Withdrawal = @import("Withdrawal.zig");
const Allocator = std.mem.Allocator;

/// Evmz execution backend for the MPT's fixed structural Keccak-256 rule.
const KeccakContext = struct {
    pub fn keccak256(_: @This(), input: []const u8) mpt.Root {
        return crypto.keccak256(input);
    }
};

const StructuralTrie = mpt.Trie(KeccakContext);

const AddressKeyContext = struct {
    pub fn trieKey(_: @This(), target: address.Address) mpt.Root {
        return crypto.keccak256(&target);
    }
};

const StorageKeyContext = struct {
    pub fn trieKey(_: @This(), key: u256) mpt.Root {
        return crypto.keccak256(&uint256.toBytes32(key));
    }
};

const AccountTrie = StructuralTrie.Keyed(address.Address, AddressKeyContext);
const StorageTrie = StructuralTrie.Keyed(u256, StorageKeyContext);

fn structuralTrie(allocator: Allocator) StructuralTrie {
    return StructuralTrie.init(allocator, .{});
}

fn accountTrie(allocator: Allocator) AccountTrie {
    return AccountTrie.init(structuralTrie(allocator), .{});
}

fn storageTrie(allocator: Allocator) StorageTrie {
    return StorageTrie.init(structuralTrie(allocator), .{});
}

/// Internal hashed-key seam for the dense commit module. Keeping the
/// structural trie context here avoids instantiating a second Keccak-backed
/// MPT implementation merely because commit lives in its own source file.
pub inline fn updateStatelessCatalogHashed(
    workspace: *mpt.StatelessWorkspace,
    allocator: Allocator,
    root_hash: [32]u8,
    catalog: *const WitnessCatalog,
    root_ref: mpt.catalog.RootRef,
    updates: []const mpt.StatelessUpdate,
) UpdateError![32]u8 {
    return structuralTrie(allocator).updateStatelessCatalog(
        workspace,
        root_hash,
        &catalog.topology,
        root_ref,
        updates,
    );
}

pub const Error = Allocator.Error || mpt.Error;

pub const ProofLookupError = rlp.DecodeError || mpt.Error;

pub const UpdateError = Allocator.Error || ProofLookupError || Error;

pub const empty_root_hash = mpt.empty_root;

pub const Pair = mpt.Entry;

const IndexKey = [1 + @sizeOf(usize)]u8;

/// Exact scratch for one ordered-trie root. Index keys and entry descriptors
/// stay live while the MPT builder uses its separately sized flat workspace.
const OrderedTrieWorkspace = struct {
    backing: []u8,
    pairs: []Pair,
    keys: []IndexKey,
    root_buffer: []u8,

    fn init(
        allocator: Allocator,
        encoded_values: []const []const u8,
    ) Error!OrderedTrieWorkspace {
        var max_value_bytes: usize = 0;
        for (encoded_values) |value| max_value_bytes = @max(max_value_bytes, value.len);
        const max_key_bytes = fixedRlpEncodedLen(usize, encoded_values.len - 1);
        const root_buffer_len = try mpt.rootWorkspaceSizeForLimits(
            encoded_values.len,
            max_key_bytes,
            max_value_bytes,
            true,
        );
        var backing_len: usize = 0;
        backing_len = try addWorkspaceRegion(Pair, backing_len, encoded_values.len);
        backing_len = try addWorkspaceRegion(IndexKey, backing_len, encoded_values.len);
        backing_len = try addWorkspaceRegion(u8, backing_len, root_buffer_len);
        const backing = try allocator.alloc(u8, backing_len);
        errdefer allocator.free(backing);
        var fixed = std.heap.FixedBufferAllocator.init(backing);
        const pairs = fixed.allocator().alloc(Pair, encoded_values.len) catch unreachable;
        const keys = fixed.allocator().alloc(IndexKey, encoded_values.len) catch unreachable;
        for (pairs, keys, encoded_values, 0..) |*pair, *key, value, index| {
            pair.* = .{
                .key = indexKeyInto(key, index),
                .value = value,
            };
        }
        const root_buffer = fixed.allocator().alloc(u8, root_buffer_len) catch unreachable;
        return .{
            .backing = backing,
            .pairs = pairs,
            .keys = keys,
            .root_buffer = root_buffer,
        };
    }

    fn deinit(self: *OrderedTrieWorkspace, allocator: Allocator) void {
        allocator.free(self.backing);
        self.* = undefined;
    }
};

/// Withdrawal encodings have to coexist with ordered-root construction, so
/// they own a distinct exact outer workspace rather than borrowing root scratch.
const WithdrawalWorkspace = struct {
    backing: []u8,
    values: [][]const u8,
    encoded: []u8,

    fn init(allocator: Allocator, withdrawals: []const Withdrawal) Error!WithdrawalWorkspace {
        var encoded_len: usize = 0;
        for (withdrawals) |withdrawal| {
            encoded_len = std.math.add(
                usize,
                encoded_len,
                fixedRlpEncodedLen(Withdrawal, withdrawal),
            ) catch return error.ResourceLimitExceeded;
        }
        var backing_len: usize = 0;
        backing_len = try addWorkspaceRegion([]const u8, backing_len, withdrawals.len);
        backing_len = try addWorkspaceRegion(u8, backing_len, encoded_len);
        const backing = try allocator.alloc(u8, backing_len);
        errdefer allocator.free(backing);
        var fixed = std.heap.FixedBufferAllocator.init(backing);
        const values = fixed.allocator().alloc([]const u8, withdrawals.len) catch unreachable;
        const encoded = fixed.allocator().alloc(u8, encoded_len) catch unreachable;
        var offset: usize = 0;
        for (values, withdrawals) |*value, withdrawal| {
            const len = fixedRlpEncodedLen(Withdrawal, withdrawal);
            value.* = encodeFixedRlpInto(
                Withdrawal,
                encoded[offset .. offset + len],
                withdrawal,
            );
            offset += len;
        }
        return .{ .backing = backing, .values = values, .encoded = encoded };
    }

    fn deinit(self: *WithdrawalWorkspace, allocator: Allocator) void {
        allocator.free(self.backing);
        self.* = undefined;
    }
};

pub const Account = struct {
    nonce: u64 = 0,
    balance: u256 = 0,
    storage_root: [32]u8 = empty_root_hash,
    code_hash: [32]u8 = crypto.keccak256_empty,

    /// The account holds no state at all, so the trie stores no leaf for it.
    ///
    /// Deliberately not named `isEmpty`: this is stricter than EIP-161
    /// emptiness, which ignores storage. An EIP-7610 storage-only account is
    /// EIP-161-empty yet still keeps a leaf here, which is exactly why
    /// creation has to collide with one. The EIP-161 predicate lives at the
    /// execution layer instead - see `Spec.retains_empty_accounts`.
    pub fn hasNoState(self: Account) bool {
        return self.nonce == 0 and
            self.balance == 0 and
            std.mem.eql(u8, &self.storage_root, &empty_root_hash) and
            std.mem.eql(u8, &self.code_hash, &crypto.keccak256_empty);
    }
};

pub const AccountFacts = SparseHashMap(address.Address, ?Account);

pub const Update = mpt.Update;

pub const IndexedNodes = mpt.IndexedNodes;
pub const ProofCache = mpt.LookupCache;

const StorageCatalogRoot = struct {
    hash: [32]u8,
    root: mpt.catalog.RootRef,
};

const CatalogAccount = struct {
    node: mpt.catalog.NodeId,
    decoded: Account,
};

/// Block-lifetime authenticated topology for state reads. The sorted witness
/// index remains separately owned by the backend until sparse commit is moved
/// onto catalog paths.
pub const WitnessCatalog = struct {
    allocator: Allocator,
    topology: mpt.Catalog,
    state_root: mpt.catalog.RootRef,
    storage_roots: std.ArrayList(StorageCatalogRoot),
    accounts: std.ArrayList(CatalogAccount),

    pub fn deinit(self: *WitnessCatalog) void {
        self.topology.deinit();
        self.storage_roots.deinit(self.allocator);
        self.accounts.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn account(self: WitnessCatalog, key: []const u8) mpt.LookupError!?[]const u8 {
        return catalogValue(try self.topology.lookup(self.state_root, key));
    }

    pub fn decodedAccount(self: WitnessCatalog, key: []const u8) ProofLookupError!?Account {
        const bound = switch (try self.topology.lookupBound(self.state_root, key)) {
            .present => |present| present,
            .absent => return null,
        };
        const target = @intFromEnum(bound.node);
        var low: usize = 0;
        var high = self.accounts.items.len;
        while (low < high) {
            const mid = low + (high - low) / 2;
            const current = @intFromEnum(self.accounts.items[mid].node);
            if (current < target) {
                low = mid + 1;
            } else if (current > target) {
                high = mid;
            } else {
                return self.accounts.items[mid].decoded;
            }
        }
        return error.InvalidNode;
    }

    pub fn storage(
        self: WitnessCatalog,
        storage_root: [32]u8,
        key: []const u8,
    ) mpt.LookupError!?[]const u8 {
        if (std.mem.eql(u8, &storage_root, &empty_root_hash)) return null;
        const root_ref = self.findStorageRoot(storage_root) orelse return error.MissingNode;
        return catalogValue(try self.topology.lookup(root_ref, key));
    }

    pub fn nodeCount(self: WitnessCatalog) usize {
        return self.topology.nodeCount();
    }

    pub fn branchCount(self: WitnessCatalog) usize {
        return self.topology.branchCount();
    }

    pub fn stateCatalogRoot(self: WitnessCatalog) mpt.catalog.RootRef {
        return self.state_root;
    }

    pub fn storageCatalogRoot(
        self: WitnessCatalog,
        digest: [32]u8,
    ) mpt.LookupError!mpt.catalog.RootRef {
        if (std.mem.eql(u8, &digest, &empty_root_hash)) return .empty;
        return self.findStorageRoot(digest) orelse error.MissingNode;
    }

    fn findStorageRoot(self: WitnessCatalog, digest: [32]u8) ?mpt.catalog.RootRef {
        var low: usize = 0;
        var high = self.storage_roots.items.len;
        while (low < high) {
            const mid = low + (high - low) / 2;
            switch (std.mem.order(u8, &self.storage_roots.items[mid].hash, &digest)) {
                .lt => low = mid + 1,
                .gt => high = mid,
                .eq => return self.storage_roots.items[mid].root,
            }
        }
        return null;
    }
};

/// Authenticate the state root, then bind every witness-present storage root
/// exposed by authenticated account leaves into the same immutable catalog.
/// Missing storage roots remain lazy witness failures when execution accesses
/// them, matching proof-reader behavior for partial witnesses.
pub fn buildWitnessCatalog(
    allocator: Allocator,
    state_root: [32]u8,
    indexed: *const IndexedNodes,
) (Allocator.Error || ProofLookupError)!WitnessCatalog {
    var builder = try structuralTrie(allocator).catalogBuilder(indexed.index());
    defer builder.deinit();

    const catalog_state_root = try builder.authenticateRoot(state_root);
    const state_node_count = builder.nodeCount();
    var storage_roots: std.ArrayList(StorageCatalogRoot) = .empty;
    errdefer storage_roots.deinit(allocator);
    var accounts: std.ArrayList(CatalogAccount) = .empty;
    errdefer accounts.deinit(allocator);
    var first_storage_root_account: ?u32 = null;
    var storage_root_accounts: std.ArrayList(u32) = .empty;
    defer storage_root_accounts.deinit(allocator);

    for (0..state_node_count) |raw_id| {
        const id: mpt.catalog.NodeId = @enumFromInt(@as(u32, @intCast(raw_id)));
        const node = builder.node(id) orelse return error.InvalidNodeReference;
        if (node.kind != .leaf) continue;
        const encoded = node.value() orelse return error.InvalidNode;
        const entry = try accounts.addOne(allocator);
        entry.node = id;
        try decodeAccountValueInto(encoded, &entry.decoded);
        if (std.mem.eql(u8, &entry.decoded.storage_root, &empty_root_hash)) continue;
        const account_index: u32 = @intCast(accounts.items.len - 1);
        if (first_storage_root_account == null) {
            first_storage_root_account = account_index;
        } else if (storage_root_accounts.items.len == 0) {
            try storage_root_accounts.ensureUnusedCapacity(allocator, 2);
            storage_root_accounts.appendAssumeCapacity(first_storage_root_account.?);
            storage_root_accounts.appendAssumeCapacity(account_index);
        } else {
            try storage_root_accounts.append(allocator, account_index);
        }
    }

    var single_storage_root_account: [1]u32 = undefined;
    const candidates = if (storage_root_accounts.items.len != 0)
        storage_root_accounts.items
    else if (first_storage_root_account) |account_index| blk: {
        single_storage_root_account[0] = account_index;
        break :blk single_storage_root_account[0..];
    } else single_storage_root_account[0..0];
    const unique_len = sortDeduplicateStorageRootAccounts(candidates, accounts.items);
    for (candidates[0..unique_len]) |account_index| {
        const storage_root = accounts.items[account_index].decoded.storage_root;
        const root_ref = builder.authenticateRoot(storage_root) catch |err| switch (err) {
            error.MissingNode => continue,
            else => return err,
        };
        try storage_roots.append(allocator, .{ .hash = storage_root, .root = root_ref });
    }

    return .{
        .allocator = allocator,
        .topology = try builder.finishAssumeCollisionResistant(),
        .state_root = catalog_state_root,
        .storage_roots = storage_roots,
        .accounts = accounts,
    };
}

fn catalogValue(result: mpt.Lookup) ?[]const u8 {
    return switch (result) {
        .present => |value| value,
        .absent => null,
    };
}

fn sortDeduplicateStorageRootAccounts(
    account_indices: []u32,
    accounts: []const CatalogAccount,
) usize {
    if (account_indices.len < 2) return account_indices.len;
    std.mem.sort(u32, account_indices, accounts, storageRootAccountLessThan);
    var unique_len: usize = 1;
    for (account_indices[1..]) |account_index| {
        const previous = accounts[account_indices[unique_len - 1]].decoded.storage_root;
        const current = accounts[account_index].decoded.storage_root;
        if (std.mem.eql(u8, &previous, &current)) continue;
        account_indices[unique_len] = account_index;
        unique_len += 1;
    }
    return unique_len;
}

fn storageRootAccountLessThan(accounts: []const CatalogAccount, lhs: u32, rhs: u32) bool {
    return std.mem.order(
        u8,
        &accounts[lhs].decoded.storage_root,
        &accounts[rhs].decoded.storage_root,
    ) == .lt;
}

pub const Proof = struct {
    root_hash: [32]u8,
    index: *const mpt.NodeIndex,
    cache: ?*ProofCache = null,

    pub fn get(self: Proof, key: []const u8) (Allocator.Error || ProofLookupError)!?[]const u8 {
        const result = if (self.cache) |cache|
            try mpt.lookupCached(self.root_hash, self.index, key, cache)
        else
            try mpt.lookup(self.root_hash, self.index, key);
        return switch (result) {
            .present => |value| value,
            .absent => null,
        };
    }
};

pub fn root(allocator: Allocator, pairs: []const Pair) Error![32]u8 {
    return structuralTrie(allocator).root(pairs);
}

pub fn indexNodes(allocator: Allocator, nodes: []const []const u8) Error!*IndexedNodes {
    return structuralTrie(allocator).indexNodes(nodes);
}

pub fn proof(root_hash: [32]u8, indexed: *const IndexedNodes) Proof {
    return .{ .root_hash = root_hash, .index = indexed.index() };
}

pub fn cachedProof(root_hash: [32]u8, indexed: *const IndexedNodes, cache: *ProofCache) Proof {
    return .{ .root_hash = root_hash, .index = indexed.index(), .cache = cache };
}

pub fn orderedTrieRoot(allocator: Allocator, encoded_values: []const []const u8) Error![32]u8 {
    if (encoded_values.len == 0) return empty_root_hash;

    var scratch = try OrderedTrieWorkspace.init(allocator, encoded_values);
    defer scratch.deinit(allocator);
    var root_workspace = mpt.Workspace.init(scratch.root_buffer);
    return structuralTrie(allocator).rootWithWorkspace(&root_workspace, scratch.pairs);
}

pub fn transactionRoot(allocator: Allocator, encoded_transactions: []const []const u8) Error![32]u8 {
    return orderedTrieRoot(allocator, encoded_transactions);
}

pub fn receiptRoot(allocator: Allocator, encoded_receipts: []const []const u8) Error![32]u8 {
    return orderedTrieRoot(allocator, encoded_receipts);
}

pub fn withdrawalsRoot(allocator: Allocator, withdrawals: []const Withdrawal) Error![32]u8 {
    if (withdrawals.len == 0) return empty_root_hash;

    var scratch = try WithdrawalWorkspace.init(allocator, withdrawals);
    defer scratch.deinit(allocator);
    return orderedTrieRoot(allocator, scratch.values);
}

pub fn updateRoot(allocator: Allocator, root_hash: [32]u8, nodes: []const []const u8, updates: []const Update) UpdateError![32]u8 {
    var indexed = try indexNodes(allocator, nodes);
    defer indexed.deinit();
    return updateRootIndexed(allocator, root_hash, indexed, updates);
}

fn updateRootIndexed(allocator: Allocator, root_hash: [32]u8, indexed: *const IndexedNodes, updates: []const Update) UpdateError![32]u8 {
    if (updates.len == 0) return root_hash;

    const sorted = try allocator.dupe(Update, updates);
    defer allocator.free(sorted);
    std.mem.sort(Update, sorted, {}, updateLessThan);
    try rejectDuplicateUpdates(sorted);

    const trie = structuralTrie(allocator);

    return trie.updateSorted(root_hash, indexed.index(), sorted);
}

fn storageRootAfterChangesIndexed(
    allocator: Allocator,
    root_hash: [32]u8,
    indexed: *const IndexedNodes,
    changes: anytype,
    target: address.Address,
) UpdateError![32]u8 {
    const scratch = allocator;

    var updates: std.ArrayList(StorageTrie.Update) = .empty;
    defer updates.deinit(scratch);

    var index: u32 = 0;
    while (index < changes.storage_writes.len()) : (index += 1) {
        const write = changes.storage_writes.at(index);
        if (!std.mem.eql(u8, &write.address, &target)) continue;

        const value: ?[]const u8 = if (write.value == 0)
            null
        else
            try storageValue(scratch, write.value);
        try updates.append(scratch, .{ .key = write.key, .value = value });
    }

    const base_root = if (changesWipeStorage(changes, target))
        empty_root_hash
    else
        root_hash;
    return storageTrie(allocator).update(base_root, indexed.index(), updates.items);
}

fn storageRootAfterChangesCatalog(
    workspace: *mpt.StatelessWorkspace,
    allocator: Allocator,
    root_hash: [32]u8,
    catalog: *const WitnessCatalog,
    changes: anytype,
    target: address.Address,
) UpdateError![32]u8 {
    var updates: std.ArrayList(StorageTrie.Update) = .empty;
    defer updates.deinit(allocator);

    var index: u32 = 0;
    while (index < changes.storage_writes.len()) : (index += 1) {
        const write = changes.storage_writes.at(index);
        if (!std.mem.eql(u8, &write.address, &target)) continue;
        const value: ?[]const u8 = if (write.value == 0)
            null
        else
            try storageValue(allocator, write.value);
        try updates.append(allocator, .{ .key = write.key, .value = value });
    }

    const wiped = changesWipeStorage(changes, target);
    const base_root = if (wiped) empty_root_hash else root_hash;
    if (updates.items.len == 0) return base_root;
    const root_ref: mpt.catalog.RootRef = if (wiped)
        .empty
    else
        try catalog.storageCatalogRoot(root_hash);
    return storageTrie(allocator).updateStatelessCatalog(
        workspace,
        base_root,
        &catalog.topology,
        root_ref,
        updates.items,
    );
}

pub fn stateRootAfterChanges(
    allocator: Allocator,
    root_hash: [32]u8,
    nodes: []const []const u8,
    changes: anytype,
) UpdateError![32]u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    var indexed = try indexNodes(scratch, nodes);
    defer indexed.deinit();
    return stateRootAfterChangesIndexed(scratch, root_hash, indexed, null, changes);
}

pub fn stateRootAfterChangesIndexed(
    allocator: Allocator,
    root_hash: [32]u8,
    indexed: *const IndexedNodes,
    authenticated_accounts: ?*const AccountFacts,
    changes: anytype,
) UpdateError![32]u8 {
    const scratch = allocator;

    var addresses: std.ArrayList(address.Address) = .empty;
    defer addresses.deinit(scratch);

    var account_index: u32 = 0;
    while (account_index < changes.accounts.len()) : (account_index += 1) {
        const change = changes.accounts.at(account_index);
        if (change.account != null) {
            try appendUniqueAddress(scratch, &addresses, change.address);
        }
    }
    var storage_index: u32 = 0;
    while (storage_index < changes.storage_writes.len()) : (storage_index += 1) {
        const write = changes.storage_writes.at(storage_index);
        if (!changesDeleteAccount(changes, write.address)) {
            try appendUniqueAddress(scratch, &addresses, write.address);
        }
    }
    var wipe_index: u32 = 0;
    while (wipe_index < changes.storage_wipes.len()) : (wipe_index += 1) {
        const target = changes.storage_wipes.at(wipe_index);
        if (!changesDeleteAccount(changes, target)) {
            try appendUniqueAddress(scratch, &addresses, target);
        }
    }

    var updates: std.ArrayList(AccountTrie.Update) = .empty;
    defer updates.deinit(scratch);

    const accounts = accountTrie(scratch);
    for (addresses.items) |target| {
        const previous = if (authenticated_accounts) |facts| previous: {
            if (facts.get(target)) |account| {
                break :previous account orelse Account{};
            }
            break :previous try loadAccountOrEmpty(
                accounts,
                root_hash,
                indexed.index(),
                target,
            );
        } else try loadAccountOrEmpty(accounts, root_hash, indexed.index(), target);
        const account_change = changesAccount(changes, target);
        const storage_root = try storageRootAfterChangesIndexed(
            scratch,
            previous.storage_root,
            indexed,
            changes,
            target,
        );
        var next_account = previous;
        if (account_change) |change| {
            const account = change.account orelse unreachable;
            next_account.nonce = account.nonce;
            next_account.balance = account.balance;
            next_account.code_hash = account.code_hash;
        }
        next_account.storage_root = storage_root;

        const value: ?[]const u8 = if (next_account.hasNoState())
            null
        else
            try accountValueFrom(scratch, next_account);
        try updates.append(scratch, .{ .key = target, .value = value });
    }

    account_index = 0;
    while (account_index < changes.accounts.len()) : (account_index += 1) {
        const change = changes.accounts.at(account_index);
        if (change.account != null) continue;
        try updates.append(scratch, .{ .key = change.address, .value = null });
    }

    return accounts.update(root_hash, indexed.index(), updates.items);
}

pub fn stateRootAfterChangesCatalog(
    allocator: Allocator,
    root_hash: [32]u8,
    catalog: *const WitnessCatalog,
    authenticated_accounts: *const AccountFacts,
    changes: anytype,
) UpdateError![32]u8 {
    var workspace = mpt.StatelessWorkspace.init(allocator);
    defer workspace.deinit();

    var addresses: std.ArrayList(address.Address) = .empty;
    defer addresses.deinit(allocator);

    var account_index: u32 = 0;
    while (account_index < changes.accounts.len()) : (account_index += 1) {
        const change = changes.accounts.at(account_index);
        if (change.account != null) try appendUniqueAddress(allocator, &addresses, change.address);
    }
    var storage_index: u32 = 0;
    while (storage_index < changes.storage_writes.len()) : (storage_index += 1) {
        const write = changes.storage_writes.at(storage_index);
        if (!changesDeleteAccount(changes, write.address)) {
            try appendUniqueAddress(allocator, &addresses, write.address);
        }
    }
    var wipe_index: u32 = 0;
    while (wipe_index < changes.storage_wipes.len()) : (wipe_index += 1) {
        const target = changes.storage_wipes.at(wipe_index);
        if (!changesDeleteAccount(changes, target)) {
            try appendUniqueAddress(allocator, &addresses, target);
        }
    }

    var updates: std.ArrayList(AccountTrie.Update) = .empty;
    defer updates.deinit(allocator);

    for (addresses.items) |target| {
        const previous = if (authenticated_accounts.get(target)) |account|
            account orelse Account{}
        else
            try loadCatalogAccountOrEmpty(catalog, target);
        const account_change = changesAccount(changes, target);
        const storage_root = try storageRootAfterChangesCatalog(
            &workspace,
            allocator,
            previous.storage_root,
            catalog,
            changes,
            target,
        );
        var next_account = previous;
        if (account_change) |change| {
            const account = change.account orelse unreachable;
            next_account.nonce = account.nonce;
            next_account.balance = account.balance;
            next_account.code_hash = account.code_hash;
        }
        next_account.storage_root = storage_root;

        const value: ?[]const u8 = if (next_account.hasNoState())
            null
        else
            try accountValueFrom(allocator, next_account);
        try updates.append(allocator, .{ .key = target, .value = value });
    }

    account_index = 0;
    while (account_index < changes.accounts.len()) : (account_index += 1) {
        const change = changes.accounts.at(account_index);
        if (change.account != null) continue;
        try updates.append(allocator, .{ .key = change.address, .value = null });
    }

    return accountTrie(allocator).updateStatelessCatalog(
        &workspace,
        root_hash,
        &catalog.topology,
        catalog.stateCatalogRoot(),
        updates.items,
    );
}

pub fn hashedAddressKey(target: address.Address) [32]u8 {
    return AddressKeyContext.trieKey(.{}, target);
}

pub fn hashedStorageKey(key: u256) [32]u8 {
    return StorageKeyContext.trieKey(.{}, key);
}

pub fn storageValue(allocator: Allocator, value: u256) Allocator.Error![]u8 {
    var out = rlp.Writer.alloc(allocator);
    errdefer out.deinit();
    try writerInt(&out, u256, value);
    return try writerOwned(&out);
}

pub fn accountValue(
    allocator: Allocator,
    nonce: u64,
    balance: u256,
    storage_root: [32]u8,
    code_hash: [32]u8,
) Allocator.Error![]u8 {
    return accountValueFrom(allocator, .{
        .nonce = nonce,
        .balance = balance,
        .storage_root = storage_root,
        .code_hash = code_hash,
    });
}

pub fn accountValueFrom(allocator: Allocator, account: Account) Allocator.Error![]u8 {
    return encodeFixedRlp(Account, allocator, account);
}

pub fn decodeAccountValue(encoded: []const u8) ProofLookupError!Account {
    return rlp.decode(Account, encoded);
}

pub fn decodeAccountValueInto(encoded: []const u8, account: *Account) ProofLookupError!void {
    try rlp.decodeInto(Account, encoded, account);
}

test "decodeAccountValue matches the fixed account schema" {
    var prng = std.Random.DefaultPrng.init(0xacc7);
    const random = prng.random();
    const scalars = [_]u256{ 0, 1, 0x7f, 0x80, 0xff, 0x100, std.math.maxInt(u64), 1 << 255, std.math.maxInt(u256) };
    for (0..256) |_| {
        var account = Account{
            .nonce = @truncate(scalars[random.uintLessThan(usize, scalars.len)]),
            .balance = scalars[random.uintLessThan(usize, scalars.len)],
        };
        random.bytes(&account.storage_root);
        random.bytes(&account.code_hash);
        const encoded = try encodeFixedRlp(Account, std.testing.allocator, account);
        defer std.testing.allocator.free(encoded);
        const decoded = try decodeAccountValue(encoded);
        try std.testing.expectEqual(account, decoded);
        var decoded_into: Account = undefined;
        try decodeAccountValueInto(encoded, &decoded_into);
        try std.testing.expectEqual(account, decoded_into);
        // Truncation must be rejected by typed decode.
        try std.testing.expectError(
            error.InputTooShort,
            decodeAccountValue(encoded[0 .. encoded.len - 1]),
        );
        try std.testing.expectError(
            error.InputTooShort,
            decodeAccountValueInto(encoded[0 .. encoded.len - 1], &decoded_into),
        );
    }
}

pub fn decodeStorageValue(encoded: []const u8) rlp.ParseError!u256 {
    var cursor = rlp.Cursor.init(encoded);
    const value = try cursor.nextInt(u256);
    try cursor.expectDone();
    return value;
}

pub fn withdrawalValue(allocator: Allocator, withdrawal: Withdrawal) Allocator.Error![]u8 {
    return encodeFixedRlp(Withdrawal, allocator, withdrawal);
}

fn indexKeyInto(out: *IndexKey, index: usize) []const u8 {
    return rlp.encode(usize, out, index) catch unreachable;
}

fn loadAccountOrEmpty(
    accounts: AccountTrie,
    root_hash: mpt.Root,
    index: *const mpt.NodeIndex,
    target: address.Address,
) UpdateError!Account {
    return switch (try accounts.lookup(root_hash, index, target)) {
        .present => |encoded| try decodeAccountValue(encoded),
        .absent => .{},
    };
}

fn loadCatalogAccountOrEmpty(
    catalog: *const WitnessCatalog,
    target: address.Address,
) UpdateError!Account {
    return try catalog.decodedAccount(&hashedAddressKey(target)) orelse .{};
}

fn changesAccount(changes: anytype, target: address.Address) ?@TypeOf(changes.accounts.at(0)) {
    var index: u32 = 0;
    while (index < changes.accounts.len()) : (index += 1) {
        const change = changes.accounts.at(index);
        if (std.mem.eql(u8, &change.address, &target)) return change;
    }
    return null;
}

fn changesDeleteAccount(changes: anytype, target: address.Address) bool {
    const change = changesAccount(changes, target) orelse return false;
    return change.account == null;
}

fn changesWipeStorage(changes: anytype, target: address.Address) bool {
    var index: u32 = 0;
    while (index < changes.storage_wipes.len()) : (index += 1) {
        const wiped = changes.storage_wipes.at(index);
        if (std.mem.eql(u8, &wiped, &target)) return true;
    }
    return false;
}

fn appendUniqueAddress(allocator: Allocator, addresses: *std.ArrayList(address.Address), target: address.Address) Allocator.Error!void {
    for (addresses.items) |existing| {
        if (std.mem.eql(u8, &existing, &target)) return;
    }
    try addresses.append(allocator, target);
}

// Test-only canonical node builder for assembling partial witness bags below.
// Production root, proof, and sparse-update paths delegate to pkg/mpt.
fn encodeNode(allocator: Allocator, pairs: []const Pair, depth: usize) Error![]const u8 {
    std.debug.assert(pairs.len > 0);

    if (pairs.len == 1) {
        const suffix = try keyNibbles(allocator, pairs[0].key, depth, nibbleLen(pairs[0].key) - depth);
        return encodeLeaf(allocator, suffix, pairs[0].value);
    }

    const common = commonPrefixLen(pairs, depth);
    if (common > 0) {
        const prefix = try keyNibbles(allocator, pairs[0].key, depth, common);
        const child = try encodeNode(allocator, pairs, depth + common);
        const child_ref = try nodeReference(allocator, child);
        return encodeExtension(allocator, prefix, child_ref);
    }

    return encodeBranch(allocator, pairs, depth);
}

fn encodeLeaf(allocator: Allocator, suffix: []const u8, value: []const u8) Error![]const u8 {
    var payload: std.ArrayList(u8) = .empty;
    defer payload.deinit(allocator);

    const compact = try compactPath(allocator, suffix, true);
    try appendBytesItem(allocator, &payload, compact);
    try appendBytesItem(allocator, &payload, value);
    return try wrapList(allocator, payload.items);
}

fn encodeExtension(allocator: Allocator, prefix: []const u8, child_ref: []const u8) Error![]const u8 {
    var payload: std.ArrayList(u8) = .empty;
    defer payload.deinit(allocator);

    const compact = try compactPath(allocator, prefix, false);
    try appendBytesItem(allocator, &payload, compact);
    try payload.appendSlice(allocator, child_ref);
    return try wrapList(allocator, payload.items);
}

fn encodeBranch(allocator: Allocator, pairs: []const Pair, depth: usize) Error![]const u8 {
    var payload: std.ArrayList(u8) = .empty;
    defer payload.deinit(allocator);

    var branch_value: ?[]const u8 = null;
    var index: usize = 0;
    while (index < pairs.len and nibbleLen(pairs[index].key) == depth) : (index += 1) {
        if (branch_value != null) return error.DuplicateKey;
        branch_value = pairs[index].value;
    }

    for (0..16) |child_nibble| {
        if (index < pairs.len and nibbleLen(pairs[index].key) > depth and nibbleAt(pairs[index].key, depth) == child_nibble) {
            const start = index;
            while (index < pairs.len and nibbleLen(pairs[index].key) > depth and nibbleAt(pairs[index].key, depth) == child_nibble) {
                index += 1;
            }
            const child = try encodeNode(allocator, pairs[start..index], depth + 1);
            const child_ref = try nodeReference(allocator, child);
            try payload.appendSlice(allocator, child_ref);
        } else {
            try appendBytesItem(allocator, &payload, "");
        }
    }

    if (index != pairs.len) return error.DuplicateKey;
    try appendBytesItem(allocator, &payload, branch_value orelse "");
    return try wrapList(allocator, payload.items);
}

fn nodeReference(allocator: Allocator, encoded_node: []const u8) Allocator.Error![]const u8 {
    if (encoded_node.len < 32) return encoded_node;
    const digest = crypto.keccak256(encoded_node);

    var out = rlp.Writer.alloc(allocator);
    errdefer out.deinit();
    try writerBytes(&out, &digest);
    return try writerOwned(&out);
}

fn wrapList(allocator: Allocator, payload: []const u8) Allocator.Error![]const u8 {
    var out = rlp.Writer.alloc(allocator);
    errdefer out.deinit();
    try writerList(&out, payload);
    return try writerOwned(&out);
}

fn appendBytesItem(allocator: Allocator, payload: *std.ArrayList(u8), value: []const u8) Allocator.Error!void {
    var item = rlp.Writer.alloc(allocator);
    defer item.deinit();
    try writerBytes(&item, value);
    try payload.appendSlice(allocator, item.written());
}

fn compactPath(allocator: Allocator, nibbles: []const u8, terminal: bool) Allocator.Error![]const u8 {
    const odd = nibbles.len % 2 == 1;
    const out_len = 1 + (nibbles.len / 2);
    const out = try allocator.alloc(u8, out_len);

    const flags: u8 = (@as(u8, @intFromBool(terminal)) << 1) | @as(u8, @intFromBool(odd));
    var nibble_index: usize = 0;
    out[0] = flags << 4;
    if (odd) {
        out[0] |= nibbles[0];
        nibble_index = 1;
    }

    var out_index: usize = 1;
    while (nibble_index < nibbles.len) : ({
        nibble_index += 2;
        out_index += 1;
    }) {
        out[out_index] = (nibbles[nibble_index] << 4) | nibbles[nibble_index + 1];
    }
    return out;
}

fn keyNibbles(allocator: Allocator, key: []const u8, start: usize, len: usize) Allocator.Error![]u8 {
    const out = try allocator.alloc(u8, len);
    for (out, 0..) |*nibble, offset| {
        nibble.* = nibbleAt(key, start + offset);
    }
    return out;
}

fn commonPrefixLen(pairs: []const Pair, depth: usize) usize {
    const first = pairs[0].key;
    const limit = minNibbleLen(pairs);
    var len: usize = 0;
    while (depth + len < limit) : (len += 1) {
        const expected = nibbleAt(first, depth + len);
        for (pairs[1..]) |pair| {
            if (nibbleAt(pair.key, depth + len) != expected) return len;
        }
    }
    return len;
}

fn minNibbleLen(pairs: []const Pair) usize {
    var len = nibbleLen(pairs[0].key);
    for (pairs[1..]) |pair| {
        len = @min(len, nibbleLen(pair.key));
    }
    return len;
}

fn nibbleLen(key: []const u8) usize {
    return key.len * 2;
}

fn nibbleAt(key: []const u8, index: usize) u8 {
    const byte = key[index / 2];
    return if (index % 2 == 0) byte >> 4 else byte & 0x0f;
}

fn pairLessThan(_: void, lhs: Pair, rhs: Pair) bool {
    return std.mem.order(u8, lhs.key, rhs.key) == .lt;
}

fn updateLessThan(_: void, lhs: Update, rhs: Update) bool {
    return std.mem.order(u8, lhs.key, rhs.key) == .lt;
}

fn rejectDuplicateKeys(pairs: []const Pair) Error!void {
    if (pairs.len < 2) return;
    for (pairs[1..], 1..) |pair, index| {
        if (std.mem.eql(u8, pairs[index - 1].key, pair.key)) return error.DuplicateKey;
    }
}

fn rejectDuplicateUpdates(updates: []const Update) UpdateError!void {
    if (updates.len < 2) return;
    for (updates[1..], 1..) |update, index| {
        if (std.mem.eql(u8, updates[index - 1].key, update.key)) return error.DuplicateKey;
    }
}

/// Narrows encode errors for schemas containing only bounded integers and fixed byte arrays.
fn encodeFixedRlp(
    comptime T: type,
    allocator: Allocator,
    value: anytype,
) Allocator.Error![]u8 {
    return rlp.encodeAlloc(T, allocator, value) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.BufferTooSmall,
        error.EncodedLengthMismatch,
        error.EncodedLengthOverflow,
        error.ListLimitExceeded,
        => unreachable,
    };
}

fn fixedRlpEncodedLen(comptime T: type, value: anytype) usize {
    return rlp.encodedLen(T, value) catch unreachable;
}

fn encodeFixedRlpInto(comptime T: type, out: []u8, value: anytype) []const u8 {
    return rlp.encode(T, out, value) catch unreachable;
}

fn addWorkspaceRegion(comptime T: type, offset: usize, count: usize) Error!usize {
    if (count == 0) return offset;
    const aligned = std.math.add(usize, offset, @alignOf(T) - 1) catch
        return error.ResourceLimitExceeded;
    const bytes = std.math.mul(usize, @sizeOf(T), count) catch
        return error.ResourceLimitExceeded;
    return std.math.add(usize, aligned, bytes) catch
        error.ResourceLimitExceeded;
}

fn writerBytes(writer: *rlp.Writer, value: []const u8) Allocator.Error!void {
    writer.bytes(value) catch |err| switch (err) {
        error.NoSpaceLeft => unreachable,
        error.OutOfMemory => return error.OutOfMemory,
    };
}

fn writerInt(writer: *rlp.Writer, comptime T: type, value: T) Allocator.Error!void {
    writer.int(T, value) catch |err| switch (err) {
        error.NoSpaceLeft => unreachable,
        error.OutOfMemory => return error.OutOfMemory,
    };
}

fn writerList(writer: *rlp.Writer, payload: []const u8) Allocator.Error!void {
    writer.listPayload(payload) catch |err| switch (err) {
        error.NoSpaceLeft => unreachable,
        error.OutOfMemory => return error.OutOfMemory,
    };
}

fn writerOwned(writer: *rlp.Writer) Allocator.Error![]u8 {
    return writer.toOwnedSlice() catch |err| switch (err) {
        error.BorrowedWriter => unreachable,
        error.OutOfMemory => return error.OutOfMemory,
    };
}

test "MPT root of empty trie matches Ethereum empty root" {
    try t.expectHex(&empty_root_hash, "56e81f171bcc55a6ff8345e692c0f86e5b48e01b996cadc001622fb5e363b421");
    try t.expectHex(&(try root(std.testing.allocator, &.{})), "56e81f171bcc55a6ff8345e692c0f86e5b48e01b996cadc001622fb5e363b421");
}

test "MPT root matches canonical string-key example" {
    const pairs = [_]Pair{
        .{ .key = "do", .value = "verb" },
        .{ .key = "dog", .value = "puppy" },
        .{ .key = "doge", .value = "coin" },
        .{ .key = "horse", .value = "stallion" },
    };
    try t.expectHex(&(try root(std.testing.allocator, &pairs)), "5991bb8c6514148a29db676a14ac506cd2cd5775ace63c30a4fe457715e9ac84");
}

test "MPT root handles hashed storage keys" {
    const allocator = std.testing.allocator;
    const key = hashedStorageKey(0);
    try t.expectHex(&key, "290decd9548b62a8d60345a988386fc84ba6bc95484008f6362f93160ef3e563");

    const value = try storageValue(allocator, 42);
    defer allocator.free(value);
    try t.expectHex(value, "2a");

    const pairs = [_]Pair{.{ .key = &key, .value = value }};
    try t.expectHex(&(try root(allocator, &pairs)), "81d1fa699f807735499cf6f7df860797cf66f6a66b565cfcda3fae3521eb6861");
}

test "MPT root handles index-keyed tries" {
    const pairs = [_]Pair{
        .{ .key = &[_]u8{0x80}, .value = "cat" },
        .{ .key = &[_]u8{0x0f}, .value = "dog" },
    };
    try t.expectHex(&(try root(std.testing.allocator, &pairs)), "cabbd0a353cb4d2df5e27b9ffeceed340ddbacdf54929b65524a961bfc318e04");
}

test "MPT ordered trie root uses RLP list indexes" {
    const values = [_][]const u8{ "cat", "dog" };
    try t.expectHex(&(try orderedTrieRoot(std.testing.allocator, &values)), "a2d85fc2849d6aec6107215f0e83954d4f25913d445387fc2c0ece0665219186");
    try t.expectHex(&(try transactionRoot(std.testing.allocator, &values)), "a2d85fc2849d6aec6107215f0e83954d4f25913d445387fc2c0ece0665219186");
    try t.expectHex(&(try receiptRoot(std.testing.allocator, &values)), "a2d85fc2849d6aec6107215f0e83954d4f25913d445387fc2c0ece0665219186");
    try t.expectHex(&(try orderedTrieRoot(std.testing.allocator, &.{})), "56e81f171bcc55a6ff8345e692c0f86e5b48e01b996cadc001622fb5e363b421");
}

test "MPT account value uses typed RLP with one allocation" {
    const input: Account = .{
        .nonce = 7,
        .balance = 42,
        .storage_root = [_]u8{0x11} ** 32,
        .code_hash = [_]u8{0x22} ** 32,
    };
    var direct_buffer: [128]u8 = undefined;
    const direct = try rlp.encode(Account, &direct_buffer, &input);

    var counted = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const before = counted.alloc_index;
    const encoded = try accountValueFrom(counted.allocator(), input);
    defer counted.allocator().free(encoded);

    try std.testing.expectEqual(before + 1, counted.alloc_index);
    try std.testing.expectEqualSlices(u8, direct, encoded);
    try std.testing.expectEqualDeep(input, try decodeAccountValue(encoded));
}

test "MPT withdrawals root encodes ordered withdrawals" {
    const withdrawals = [_]Withdrawal{
        .{
            .index = 1,
            .validator_index = 2,
            .address = address.addr(0x1000),
            .amount = 3,
        },
        .{
            .index = 4,
            .validator_index = 5,
            .address = address.addr(0x2000),
            .amount = 6,
        },
    };

    var direct_buffer: [64]u8 = undefined;
    const direct = try rlp.encode(Withdrawal, &direct_buffer, &withdrawals[0]);
    var counted = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const before = counted.alloc_index;
    const value0 = try withdrawalValue(counted.allocator(), withdrawals[0]);
    defer counted.allocator().free(value0);

    try std.testing.expectEqual(before + 1, counted.alloc_index);
    try std.testing.expectEqualSlices(u8, direct, value0);
    try t.expectHex(value0, "d8010294000000000000000000000000000000000000100003");
    try t.expectHex(&(try withdrawalsRoot(std.testing.allocator, &withdrawals)), "ba94e67f1ff34df6be897a534b805005dc84403f69a89614daa2283fa8b1862f");
    try t.expectHex(&(try withdrawalsRoot(std.testing.allocator, &.{})), "56e81f171bcc55a6ff8345e692c0f86e5b48e01b996cadc001622fb5e363b421");
}

test "ordered trie exact workspaces reclaim fixed backing" {
    const values = [_][]const u8{ "cat", "dog" };
    const withdrawals = [_]Withdrawal{.{
        .index = 1,
        .validator_index = 2,
        .address = address.addr(0x1000),
        .amount = 3,
    }};
    var backing: [64 * 1024]u8 align(16) = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&backing);

    _ = try orderedTrieRoot(fixed.allocator(), &values);
    try std.testing.expectEqual(@as(usize, 0), fixed.end_index);
    _ = try withdrawalsRoot(fixed.allocator(), &withdrawals);
    try std.testing.expectEqual(@as(usize, 0), fixed.end_index);
}

test "MPT root rejects duplicate keys" {
    const pairs = [_]Pair{
        .{ .key = "dog", .value = "puppy" },
        .{ .key = "dog", .value = "hound" },
    };
    try std.testing.expectError(error.DuplicateKey, root(std.testing.allocator, &pairs));
}

test "MPT proof lookup resolves a root leaf" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const scratch = arena.allocator();

    const key = hashedStorageKey(0);
    const value = try storageValue(scratch, 42);
    const pairs = [_]Pair{.{ .key = &key, .value = value }};
    const root_node = try encodedRootForTest(scratch, &pairs);
    const root_hash = crypto.keccak256(root_node);
    const nodes = [_][]const u8{root_node};
    const indexed = try indexNodes(scratch, &nodes);

    const found = (try proof(root_hash, indexed).get(&key)).?;
    try std.testing.expectEqualSlices(u8, value, found);

    const missing_key = hashedStorageKey(1);
    try std.testing.expect(try proof(root_hash, indexed).get(&missing_key) == null);
}

test "MPT proof lookup walks hashed child nodes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const scratch = arena.allocator();

    var keys: [16][1]u8 = undefined;
    var values: [16][1]u8 = undefined;
    var pairs: [16]Pair = undefined;
    for (0..16) |index| {
        keys[index][0] = @intCast(0x10 + index);
        values[index][0] = @intCast(index + 1);
        pairs[index] = .{ .key = &keys[index], .value = &values[index] };
    }

    const sorted = try sortedPairsForTest(scratch, &pairs);
    const root_node = try encodeNode(scratch, sorted, 0);
    const child_node = try encodeNode(scratch, sorted, 1);
    try std.testing.expect(child_node.len >= 32);

    const root_hash = crypto.keccak256(root_node);
    const nodes = [_][]const u8{ root_node, child_node };
    const indexed = try indexNodes(scratch, &nodes);

    const found = (try proof(root_hash, indexed).get(&keys[14])).?;
    try std.testing.expectEqualSlices(u8, &values[14], found);

    const omitted_child = [_][]const u8{root_node};
    const omitted_indexed = try indexNodes(scratch, &omitted_child);
    try std.testing.expectError(error.MissingNode, proof(root_hash, omitted_indexed).get(&keys[14]));
}

test "MPT proof lookup proves branch absence" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const scratch = arena.allocator();

    const pairs = [_]Pair{
        .{ .key = &[_]u8{0x10}, .value = &[_]u8{0x01} },
        .{ .key = &[_]u8{0x12}, .value = &[_]u8{0x02} },
    };
    const root_node = try encodedRootForTest(scratch, &pairs);
    const root_hash = crypto.keccak256(root_node);
    const nodes = [_][]const u8{root_node};
    const indexed = try indexNodes(scratch, &nodes);

    try std.testing.expect(try proof(root_hash, indexed).get(&[_]u8{0x11}) == null);
}

test "MPT proof lookup rejects malformed compact paths" {
    const malformed = [_]u8{ 0xc2, 0x40, 0x80 };
    const root_hash = crypto.keccak256(&malformed);
    const nodes = [_][]const u8{&malformed};
    var indexed = try indexNodes(std.testing.allocator, &nodes);
    defer indexed.deinit();

    try std.testing.expectError(error.InvalidCompactPath, proof(root_hash, indexed).get(""));
}

test "witness catalog links state and witness-present storage roots" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const scratch = arena.allocator();

    const slot_key = hashedStorageKey(3);
    const slot_value = try storageValue(scratch, 42);
    const storage_pairs = [_]Pair{.{ .key = &slot_key, .value = slot_value }};
    const storage_node = try encodedRootForTest(scratch, &storage_pairs);
    const storage_root = crypto.keccak256(storage_node);

    const target = address.addr(0x2000);
    const account_key = hashedAddressKey(target);
    const account_value = try accountValueFrom(scratch, .{ .storage_root = storage_root });
    const state_pairs = [_]Pair{.{ .key = &account_key, .value = account_value }};
    const state_node = try encodedRootForTest(scratch, &state_pairs);
    const state_root = crypto.keccak256(state_node);

    const nodes = [_][]const u8{ state_node, storage_node };
    var indexed = try indexNodes(scratch, &nodes);
    defer indexed.deinit();
    var catalog = try buildWitnessCatalog(scratch, state_root, indexed);
    defer catalog.deinit();

    try std.testing.expect((try catalog.account(&account_key)) != null);
    const account = (try catalog.decodedAccount(&account_key)).?;
    try std.testing.expectEqualSlices(u8, &storage_root, &account.storage_root);
    try std.testing.expectEqualSlices(u8, slot_value, (try catalog.storage(storage_root, &slot_key)).?);
    const absent_key = hashedStorageKey(4);
    try std.testing.expect(try catalog.storage(storage_root, &absent_key) == null);
    try std.testing.expectEqual(@as(usize, 2), catalog.nodeCount());

    const state_only_nodes = [_][]const u8{state_node};
    var state_only_indexed = try indexNodes(scratch, &state_only_nodes);
    defer state_only_indexed.deinit();
    var state_only = try buildWitnessCatalog(scratch, state_root, state_only_indexed);
    defer state_only.deinit();
    try std.testing.expect((try state_only.account(&account_key)) != null);
    try std.testing.expectError(error.MissingNode, state_only.storage(storage_root, &slot_key));
}

test "witness catalog storage-root accounts sort and deduplicate in place" {
    const first = [_]u8{0x11} ** 32;
    const second = [_]u8{0x22} ** 32;
    const third = [_]u8{0x33} ** 32;
    const accounts = [_]CatalogAccount{
        .{ .node = @enumFromInt(0), .decoded = .{ .storage_root = first } },
        .{ .node = @enumFromInt(1), .decoded = .{ .storage_root = second } },
        .{ .node = @enumFromInt(2), .decoded = .{ .storage_root = third } },
    };
    var account_indices = [_]u32{ 2, 0, 1, 0, 2 };

    const len = sortDeduplicateStorageRootAccounts(&account_indices, &accounts);
    try std.testing.expectEqual(@as(usize, 3), len);
    try std.testing.expectEqualSlices(u32, &.{ 0, 1, 2 }, account_indices[0..len]);
}

test "witness catalog cleans every allocation failure position" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const scratch = arena.allocator();

    const slot_key = hashedStorageKey(3);
    const slot_value = try storageValue(scratch, 42);
    const storage_node = try encodedRootForTest(
        scratch,
        &.{.{ .key = &slot_key, .value = slot_value }},
    );
    const storage_root = crypto.keccak256(storage_node);
    const account_key = hashedAddressKey(address.addr(0x2000));
    const account_value = try accountValueFrom(scratch, .{ .storage_root = storage_root });
    const state_node = try encodedRootForTest(
        scratch,
        &.{.{ .key = &account_key, .value = account_value }},
    );
    const state_root = crypto.keccak256(state_node);
    const nodes = [_][]const u8{ state_node, storage_node };

    const Harness = struct {
        fn run(
            allocator: Allocator,
            root_hash: [32]u8,
            encoded_nodes: []const []const u8,
        ) !void {
            var indexed = try indexNodes(allocator, encoded_nodes);
            defer indexed.deinit();
            var catalog = try buildWitnessCatalog(allocator, root_hash, indexed);
            defer catalog.deinit();
            try std.testing.expectEqual(@as(usize, 1), catalog.accounts.items.len);
            try std.testing.expectEqual(@as(usize, 1), catalog.storage_roots.items.len);
        }
    };
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        Harness.run,
        .{ state_root, &nodes },
    );
}

test "MPT update root inserts into empty trie" {
    const allocator = std.testing.allocator;
    const update = [_]Update{.{ .key = "dog", .value = "puppy" }};

    const actual = try updateRoot(allocator, empty_root_hash, &.{}, &update);
    const expected_pairs = [_]Pair{.{ .key = "dog", .value = "puppy" }};
    const expected = try root(allocator, &expected_pairs);
    try std.testing.expectEqualSlices(u8, &expected, &actual);
}

test "MPT update root replaces and deletes a root leaf" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const scratch = arena.allocator();

    const base_pairs = [_]Pair{.{ .key = "dog", .value = "puppy" }};
    const root_node = try encodedRootForTest(scratch, &base_pairs);
    const root_hash = crypto.keccak256(root_node);
    const nodes = [_][]const u8{root_node};

    const replacement = [_]Update{.{ .key = "dog", .value = "hound" }};
    const replaced = try updateRoot(scratch, root_hash, &nodes, &replacement);
    const replaced_pairs = [_]Pair{.{ .key = "dog", .value = "hound" }};
    try std.testing.expectEqualSlices(u8, &(try root(scratch, &replaced_pairs)), &replaced);

    const deletion = [_]Update{.{ .key = "dog", .value = null }};
    try std.testing.expectEqualSlices(u8, &empty_root_hash, &(try updateRoot(scratch, root_hash, &nodes, &deletion)));
}

test "MPT update root materializes hashed child nodes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const scratch = arena.allocator();

    var keys: [16][1]u8 = undefined;
    var values: [16][1]u8 = undefined;
    var pairs: [16]Pair = undefined;
    for (0..16) |index| {
        keys[index][0] = @intCast(0x10 + index);
        values[index][0] = @intCast(index + 1);
        pairs[index] = .{ .key = &keys[index], .value = &values[index] };
    }

    const sorted = try sortedPairsForTest(scratch, &pairs);
    const root_node = try encodeNode(scratch, sorted, 0);
    const child_node = try encodeNode(scratch, sorted, 1);
    const root_hash = crypto.keccak256(root_node);
    const nodes = [_][]const u8{ root_node, child_node };

    const new_value = [_]u8{0xff};
    const updates = [_]Update{.{ .key = &keys[14], .value = &new_value }};
    const actual = try updateRoot(scratch, root_hash, &nodes, &updates);

    values[14][0] = 0xff;
    pairs[14] = .{ .key = &keys[14], .value = &values[14] };
    const expected = try root(scratch, &pairs);
    try std.testing.expectEqualSlices(u8, &expected, &actual);

    const omitted_child = [_][]const u8{root_node};
    try std.testing.expectError(error.MissingNode, updateRoot(scratch, root_hash, &omitted_child, &updates));
}

test "MPT update root preserves unrevealed hashed siblings" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const scratch = arena.allocator();

    var keys: [32][1]u8 = undefined;
    var values: [32][1]u8 = undefined;
    var pairs: [32]Pair = undefined;
    for (0..16) |index| {
        keys[index][0] = @intCast(0x10 + index);
        values[index][0] = @intCast(index + 1);
        pairs[index] = .{ .key = &keys[index], .value = &values[index] };
    }
    for (16..32) |index| {
        keys[index][0] = @intCast(0x20 + index - 16);
        values[index][0] = @intCast(index + 1);
        pairs[index] = .{ .key = &keys[index], .value = &values[index] };
    }

    const sorted = try sortedPairsForTest(scratch, &pairs);
    const root_node = try encodeNode(scratch, sorted, 0);
    const revealed_child = try encodeNode(scratch, sorted[0..16], 1);
    const unrevealed_child = try encodeNode(scratch, sorted[16..32], 1);
    try std.testing.expect(revealed_child.len >= 32);
    try std.testing.expect(unrevealed_child.len >= 32);

    const root_hash = crypto.keccak256(root_node);
    const nodes = [_][]const u8{ root_node, revealed_child };

    const new_value = [_]u8{0xee};
    const updates = [_]Update{.{ .key = &keys[3], .value = &new_value }};
    const actual = try updateRoot(scratch, root_hash, &nodes, &updates);

    values[3][0] = 0xee;
    pairs[3] = .{ .key = &keys[3], .value = &values[3] };
    const expected = try root(scratch, &pairs);
    try std.testing.expectEqualSlices(u8, &expected, &actual);
}

test "MPT update root deletes and compresses branch" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const scratch = arena.allocator();

    const base_pairs = [_]Pair{
        .{ .key = &[_]u8{0x10}, .value = &[_]u8{0x01} },
        .{ .key = &[_]u8{0x12}, .value = &[_]u8{0x02} },
    };
    const root_node = try encodedRootForTest(scratch, &base_pairs);
    const root_hash = crypto.keccak256(root_node);
    const nodes = [_][]const u8{root_node};

    const updates = [_]Update{.{ .key = &[_]u8{0x12}, .value = null }};
    const actual = try updateRoot(scratch, root_hash, &nodes, &updates);
    const expected_pairs = [_]Pair{.{ .key = &[_]u8{0x10}, .value = &[_]u8{0x01} }};
    const expected = try root(scratch, &expected_pairs);
    try std.testing.expectEqualSlices(u8, &expected, &actual);
}

test "MPT update root delete materializes hashed sibling before branch collapse" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const scratch = arena.allocator();

    const deleted_key = [_]u8{0x10};
    const remaining_key = [_]u8{0x20};
    var large_value = [_]u8{0xab} ** 40;
    const base_pairs = [_]Pair{
        .{ .key = &deleted_key, .value = &[_]u8{0x01} },
        .{ .key = &remaining_key, .value = &large_value },
    };
    const sorted = try sortedPairsForTest(scratch, &base_pairs);
    const root_node = try encodeNode(scratch, sorted, 0);
    const hidden_sibling = try encodeNode(scratch, sorted[1..2], 1);
    try std.testing.expect(hidden_sibling.len >= 32);

    const root_hash = crypto.keccak256(root_node);
    const updates = [_]Update{.{ .key = &deleted_key, .value = null }};

    const nodes = [_][]const u8{ root_node, hidden_sibling };
    const actual = try updateRoot(scratch, root_hash, &nodes, &updates);
    const expected_pairs = [_]Pair{.{ .key = &remaining_key, .value = &large_value }};
    const expected = try root(scratch, &expected_pairs);
    try std.testing.expectEqualSlices(u8, &expected, &actual);

    const omitted_sibling = [_][]const u8{root_node};
    try std.testing.expectError(error.MissingNode, updateRoot(scratch, root_hash, &omitted_sibling, &updates));
}

test "MPT batch inserts before deletes to avoid unnecessary sibling witness" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const scratch = arena.allocator();

    const deleted_key = [_]u8{0x10};
    const inserted_key = [_]u8{0x11};
    const preserved_key = [_]u8{0x20};
    var large_value = [_]u8{0xab} ** 40;
    const base_pairs = [_]Pair{
        .{ .key = &deleted_key, .value = &[_]u8{0x01} },
        .{ .key = &preserved_key, .value = &large_value },
    };
    const sorted = try sortedPairsForTest(scratch, &base_pairs);
    const root_node = try encodeNode(scratch, sorted, 0);
    const hidden_sibling = try encodeNode(scratch, sorted[1..2], 1);
    try std.testing.expect(hidden_sibling.len >= 32);

    const root_hash = crypto.keccak256(root_node);
    const updates = [_]Update{
        .{ .key = &deleted_key, .value = null },
        .{ .key = &inserted_key, .value = &[_]u8{0x03} },
    };
    const root_only_nodes = [_][]const u8{root_node};
    const actual = try updateRoot(scratch, root_hash, &root_only_nodes, &updates);
    const expected_pairs = [_]Pair{
        .{ .key = &inserted_key, .value = &[_]u8{0x03} },
        .{ .key = &preserved_key, .value = &large_value },
    };
    const expected = try root(scratch, &expected_pairs);
    try std.testing.expectEqualSlices(u8, &expected, &actual);
}

test "MPT state root consumes tracked changes" {
    const TrackedState = @import("../state/TrackedState.zig");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const scratch = arena.allocator();

    const target = address.addr(0x1000);
    var state = TrackedState.init(scratch);
    defer state.deinit();
    const attempt = state.beginTransaction();
    state.beginScope();
    try state.setBalance(target, 20);
    _ = try state.setStorage(target, 1, 7);
    state.closeScope();
    state.seal(attempt);
    state.retain(attempt);
    const changes = state.acceptedView().changes();

    const direct = try stateRootAfterChanges(scratch, empty_root_hash, &.{}, changes);
    const storage_key = hashedStorageKey(1);
    const storage_value = try storageValue(scratch, 7);
    const storage_root = try root(scratch, &.{.{ .key = &storage_key, .value = storage_value }});
    const account_key = hashedAddressKey(target);
    const account_value = try accountValueFrom(scratch, .{
        .balance = 20,
        .storage_root = storage_root,
    });
    const expected = try root(scratch, &.{.{ .key = &account_key, .value = account_value }});
    try std.testing.expectEqualSlices(u8, &expected, &direct);

    const wiped = state.beginTransaction();
    state.beginScope();
    try state.setBalance(target, 0);
    try state.markSelfdestructed(target);
    try state.finalize(.{ .existing_account = .{
        .reset_account = true,
        .clear_storage = true,
    } });
    state.closeScope();
    state.seal(wiped);
    state.retain(wiped);
    const wiped_changes = state.acceptedView().changes();
    try std.testing.expectEqual(@as(u32, 1), wiped_changes.storage_wipes.len());
    try std.testing.expectEqual(@as(u32, 0), wiped_changes.storage_writes.len());

    const wiped_direct = try stateRootAfterChanges(
        scratch,
        empty_root_hash,
        &.{},
        wiped_changes,
    );
    try std.testing.expectEqualSlices(u8, &empty_root_hash, &wiped_direct);
}

test "MPT state roots agree with cached and witness-loaded accounts" {
    const TrackedState = @import("../state/TrackedState.zig");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const scratch = arena.allocator();

    const target = address.addr(0x1000);
    const previous = Account{ .nonce = 3, .balance = 10 };
    const account_key = hashedAddressKey(target);
    const account_value = try accountValueFrom(scratch, previous);
    const root_node = try encodedRootForTest(
        scratch,
        &.{.{ .key = &account_key, .value = account_value }},
    );
    const root_hash = crypto.keccak256(root_node);
    const nodes = [_][]const u8{root_node};
    var indexed = try indexNodes(scratch, &nodes);
    defer indexed.deinit();

    const MemoryAccount = @import("../state/MemoryAccount.zig");
    var state = TrackedState.init(scratch);
    defer state.deinit();
    var seeded = MemoryAccount.init(scratch);
    seeded.account.nonce = previous.nonce;
    seeded.account.balance = previous.balance;
    try state.seedAccount(target, seeded);
    const attempt = state.beginTransaction();
    state.beginScope();
    _ = try state.setStorage(target, 1, 7);
    state.closeScope();
    state.seal(attempt);
    state.retain(attempt);
    const changes = state.acceptedView().changes();

    var facts = AccountFacts.init(scratch);
    defer facts.deinit();
    try facts.put(target, previous);
    const cached = try stateRootAfterChangesIndexed(
        scratch,
        root_hash,
        indexed,
        &facts,
        changes,
    );
    const fallback = try stateRootAfterChangesIndexed(
        scratch,
        root_hash,
        indexed,
        null,
        changes,
    );
    var catalog = try buildWitnessCatalog(scratch, root_hash, indexed);
    defer catalog.deinit();
    const catalog_root = try stateRootAfterChangesCatalog(
        scratch,
        root_hash,
        &catalog,
        &facts,
        changes,
    );
    try std.testing.expectEqualSlices(u8, &fallback, &cached);
    try std.testing.expectEqualSlices(u8, &fallback, &catalog_root);
}

test "authenticated account facts preserve cached absence" {
    var facts = AccountFacts.init(std.testing.allocator);
    defer facts.deinit();

    try facts.put(address.addr(1), null);
    const cached = facts.get(address.addr(1));
    try std.testing.expect(cached != null);
    try std.testing.expect(cached.? == null);
    try std.testing.expect(facts.get(address.addr(2)) == null);
}

fn sortedPairsForTest(allocator: Allocator, pairs: []const Pair) ![]Pair {
    const sorted = try allocator.dupe(Pair, pairs);
    std.mem.sort(Pair, sorted, {}, pairLessThan);
    try rejectDuplicateKeys(sorted);
    return sorted;
}

fn encodedRootForTest(allocator: Allocator, pairs: []const Pair) ![]const u8 {
    const sorted = try sortedPairsForTest(allocator, pairs);
    return try encodeNode(allocator, sorted, 0);
}
