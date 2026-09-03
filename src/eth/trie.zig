//! Ethereum execution MPT helpers for root construction, proof lookup, and
//! witness-backed root updates.
//! This is not a persistent trie database or a complete general-purpose MPT library.

const std = @import("std");

const ExactSlab = @import("stdx").ExactSlab;

const address = @import("../address.zig");
const crypto = @import("../crypto.zig");
const rlp = @import("rlp");
const mpt = @import("mpt");
const uint256 = @import("../uint256.zig");
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
        return crypto.keccak256(target.asBytes());
    }
};

const StorageKeyContext = struct {
    pub fn trieKey(_: @This(), key: u256) mpt.Root {
        return crypto.keccak256(&uint256.toBytes32(key));
    }
};

const AccountTrie = StructuralTrie.Keyed(address.Address, AddressKeyContext);
const StorageTrie = StructuralTrie.Keyed(u256, StorageKeyContext);

const AccountBatch = struct {
    account_change_index: ?u32 = null,
    storage_start: u32 = 0,
    storage_len: u32 = 0,
    storage_cursor: u32 = 0,
    wiped: bool = false,
};

const AccountBatches = std.array_hash_map.Auto(address.Address, AccountBatch);

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
pub inline fn updateHashedSorted(
    scratch_arena: *mpt.ScopedArenaAllocator,
    source: anytype,
    updates: []const mpt.FixedUpdate,
) UpdateError![32]u8 {
    return structuralTrie(scratch_arena.allocator()).updateFixedSorted(
        scratch_arena,
        source,
        updates,
    );
}

pub const NodeUpdates = mpt.NodeUpdates;

pub inline fn updateHashedSortedWithNodeUpdates(
    scratch_arena: *mpt.ScopedArenaAllocator,
    source: anytype,
    updates: []const mpt.FixedUpdate,
    node_updates: *NodeUpdates,
) UpdateError![32]u8 {
    return structuralTrie(scratch_arena.allocator()).updateFixedSortedWithNodeUpdates(
        scratch_arena,
        source,
        updates,
        node_updates,
    );
}

pub const Error = Allocator.Error || mpt.Error || error{Overflow};
pub const ProofLookupError = rlp.DecodeError || mpt.Error;
pub const UpdateError = Allocator.Error || ProofLookupError || Error;

pub const empty_root_hash = mpt.empty_root;

pub const Pair = mpt.Entry;

const IndexKey = [1 + @sizeOf(usize)]u8;

/// Exact scratch for one ordered-trie root. Index keys and entry descriptors
/// stay live while the MPT builder uses its separately sized flat buffer.
const OrderedTrieWorkspace = struct {
    slab: ExactSlab,
    pairs: []Pair,
    root_buffer: []u8,

    fn init(
        allocator: Allocator,
        encoded_values: []const []const u8,
    ) Error!OrderedTrieWorkspace {
        std.debug.assert(encoded_values.len > 0);
        var max_value_bytes: usize = 0;
        for (encoded_values) |value| max_value_bytes = @max(max_value_bytes, value.len);
        const max_key_bytes = fixedRlpEncodedLen(usize, encoded_values.len - 1);
        const root_buffer_len = try mpt.rootBufferSizeForLimits(
            encoded_values.len,
            max_key_bytes,
            max_value_bytes,
            true,
        );
        var slab_len: usize = 0;
        slab_len = try ExactSlab.reserve(Pair, slab_len, encoded_values.len);
        slab_len = try ExactSlab.reserve(IndexKey, slab_len, encoded_values.len);
        slab_len = try ExactSlab.reserve(u8, slab_len, root_buffer_len);

        var slab = try ExactSlab.init(allocator, slab_len);
        const pairs = slab.take(Pair, encoded_values.len);
        const keys = slab.take(IndexKey, encoded_values.len);
        for (pairs, keys, encoded_values, 0..) |*pair, *key, value, index| {
            pair.* = .{
                .key = indexKeyInto(key, index),
                .value = value,
            };
        }
        const root_buffer = slab.take(u8, root_buffer_len);
        return .{ .slab = slab, .pairs = pairs, .root_buffer = root_buffer };
    }

    fn deinit(self: *OrderedTrieWorkspace, allocator: Allocator) void {
        self.slab.deinit(allocator);
        self.* = undefined;
    }
};

/// Withdrawal encodings have to coexist with ordered-root construction, so
/// they own a distinct exact outer workspace rather than borrowing root scratch.
const WithdrawalWorkspace = struct {
    slab: ExactSlab,
    values: [][]const u8,

    fn init(allocator: Allocator, withdrawals: []const Withdrawal) Error!WithdrawalWorkspace {
        var encoded_len: usize = 0;
        for (withdrawals) |withdrawal| {
            encoded_len = try std.math.add(
                usize,
                encoded_len,
                fixedRlpEncodedLen(Withdrawal, withdrawal),
            );
        }
        var slab_len: usize = 0;
        slab_len = try ExactSlab.reserve([]const u8, slab_len, withdrawals.len);
        slab_len = try ExactSlab.reserve(u8, slab_len, encoded_len);

        var slab = try ExactSlab.init(allocator, slab_len);
        const values = slab.take([]const u8, withdrawals.len);
        const encoded = slab.take(u8, encoded_len);
        var offset: usize = 0;
        for (values, withdrawals) |*value, withdrawal| {
            const len = fixedRlpEncodedLen(Withdrawal, withdrawal);
            value.* = encodeFixedRlpInto(
                Withdrawal,
                encoded[offset..][0..len],
                withdrawal,
            );
            offset += len;
        }
        return .{ .slab = slab, .values = values };
    }

    fn deinit(self: *WithdrawalWorkspace, allocator: Allocator) void {
        self.slab.deinit(allocator);
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
    /// emptiness, which ignores storage. A storage-only account is EIP-161-empty
    /// yet still keeps a leaf here. The EIP-161 predicate lives at the execution
    /// layer instead - see `Spec.retains_empty_accounts`.
    pub fn hasNoState(self: Account) bool {
        return self.nonce == 0 and
            self.balance == 0 and
            std.mem.eql(u8, &self.storage_root, &empty_root_hash) and
            std.mem.eql(u8, &self.code_hash, &crypto.keccak256_empty);
    }
};

const max_rlp_account: Account = .{
    .nonce = std.math.maxInt(u64),
    .balance = std.math.maxInt(u256),
    .storage_root = [_]u8{0xff} ** 32,
    .code_hash = [_]u8{0xff} ** 32,
};

pub const StorageValueBuffer = [fixedRlpEncodedLen(u256, std.math.maxInt(u256))]u8;
pub const AccountValueBuffer = [fixedRlpEncodedLen(Account, max_rlp_account)]u8;

pub const AccountFacts = @import("../state/sparse_hash_map.zig").WithContext(address.Address, ?Account, address.Address.HashContext);

pub const Update = mpt.Update;

pub const WitnessIndex = mpt.WitnessIndex;
pub const ProofCache = mpt.LookupCache;

const StorageCatalogRoot = struct {
    hash: [32]u8,
    root: mpt.Catalog.Root,
};

const CatalogAccount = struct {
    node: mpt.Catalog.NodeId,
    decoded: Account,
};

/// Block-lifetime authenticated topology for state reads and fixed-key commit.
/// The sealed witness index remains separately owned by the backend for proof
/// lookup and as the catalog's encoded-node backing.
pub const WitnessCatalog = struct {
    allocator: Allocator,
    topology: mpt.Catalog,
    state_root: mpt.Catalog.Root,
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
        const S = struct {
            fn compareAccountNode(target: mpt.Catalog.NodeId, item: CatalogAccount) std.math.Order {
                return std.math.order(@intFromEnum(target), @intFromEnum(item.node));
            }
        };
        const index = std.sort.binarySearch(
            CatalogAccount,
            self.accounts.items,
            bound.node,
            S.compareAccountNode,
        ) orelse return error.InvalidNode;
        return self.accounts.items[index].decoded;
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

    pub fn stateCatalogRoot(self: WitnessCatalog) mpt.Catalog.Root {
        return self.state_root;
    }

    /// Mutation source over this catalog's topology at `root`. Pointer
    /// receiver: the returned source borrows the topology in place.
    pub fn source(self: *const WitnessCatalog, catalog_root: mpt.Catalog.Root) mpt.Source(.catalog) {
        return .{ .topology = &self.topology, .root = catalog_root };
    }

    /// Resolve a storage root by its authenticated digest. Unlike the state
    /// commit boundary, the digest itself selects the catalog root.
    pub fn storageCatalogRoot(
        self: WitnessCatalog,
        digest: [32]u8,
    ) mpt.LookupError!mpt.Catalog.Root {
        if (std.mem.eql(u8, &digest, &empty_root_hash)) return .empty;
        return self.findStorageRoot(digest) orelse error.MissingNode;
    }

    /// State commit receives the pre-root independently from this catalog;
    /// reject a mismatched pair before deriving any changes.
    pub fn validateStateRoot(self: WitnessCatalog, digest: [32]u8) error{InvalidNodeReference}!void {
        if (!std.mem.eql(u8, &digest, &self.state_root.digest())) {
            return error.InvalidNodeReference;
        }
    }

    fn findStorageRoot(self: WitnessCatalog, digest: [32]u8) ?mpt.Catalog.Root {
        const S = struct {
            fn compareStorageRootHash(context: [32]u8, item: StorageCatalogRoot) std.math.Order {
                return std.mem.order(u8, &context, &item.hash);
            }
        };
        const index = std.sort.binarySearch(
            StorageCatalogRoot,
            self.storage_roots.items,
            digest,
            S.compareStorageRootHash,
        ) orelse return null;
        return self.storage_roots.items[index].root;
    }
};

/// Authenticate the state root, then bind every witness-present storage root
/// exposed by authenticated account leaves into the same immutable catalog.
/// Missing storage roots remain lazy witness failures when execution accesses
/// them, matching proof-reader behavior for partial witnesses.
pub fn buildWitnessCatalog(
    allocator: Allocator,
    state_root: [32]u8,
    witness: *const WitnessIndex,
) (Allocator.Error || ProofLookupError)!WitnessCatalog {
    var builder = try mpt.Catalog.Builder.init(allocator, witness);
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
        const id: mpt.Catalog.NodeId = @enumFromInt(raw_id);
        const encoded = (try builder.leafValue(id)) orelse continue;
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

    std.mem.sort(u32, account_indices, accounts, struct {
        fn lessThan(accounts_: []const CatalogAccount, lhs: u32, rhs: u32) bool {
            return std.mem.lessThan(u8, &accounts_[lhs].decoded.storage_root, &accounts_[rhs].decoded.storage_root);
        }
    }.lessThan);

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

pub const Proof = struct {
    root_hash: [32]u8,
    witness: *const WitnessIndex,
    cache: ?*ProofCache = null,

    pub fn get(self: Proof, key: []const u8) (Allocator.Error || ProofLookupError)!?[]const u8 {
        const result = if (self.cache) |cache|
            try self.witness.lookupCached(self.root_hash, key, cache)
        else
            try self.witness.lookup(self.root_hash, key);
        return switch (result) {
            .present => |value| value,
            .absent => null,
        };
    }
};

pub fn root(allocator: Allocator, pairs: []const Pair) Error![32]u8 {
    return structuralTrie(allocator).root(pairs);
}

pub fn indexWitness(allocator: Allocator, nodes: []const []const u8) Error!*WitnessIndex {
    return structuralTrie(allocator).indexWitness(nodes);
}

pub fn proof(root_hash: [32]u8, witness: *const WitnessIndex) Proof {
    return .{ .root_hash = root_hash, .witness = witness };
}

pub fn cachedProof(root_hash: [32]u8, witness: *const WitnessIndex, cache: *ProofCache) Proof {
    return .{ .root_hash = root_hash, .witness = witness, .cache = cache };
}

pub fn orderedTrieRoot(allocator: Allocator, encoded_values: []const []const u8) Error![32]u8 {
    if (encoded_values.len == 0) return empty_root_hash;

    var scratch = try OrderedTrieWorkspace.init(allocator, encoded_values);
    defer scratch.deinit(allocator);
    return structuralTrie(allocator).rootWithBuffer(scratch.root_buffer, scratch.pairs);
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
    var witness = try indexWitness(allocator, nodes);
    defer witness.deinit();
    return updateRootWithWitness(allocator, root_hash, witness, updates);
}

fn updateRootWithWitness(allocator: Allocator, root_hash: [32]u8, witness: *const WitnessIndex, updates: []const Update) UpdateError![32]u8 {
    if (updates.len == 0) return root_hash;

    const sorted = try allocator.dupe(Update, updates);
    defer allocator.free(sorted);
    mpt.sortUpdates(sorted);

    const trie = structuralTrie(allocator);

    return trie.updateSorted(root_hash, witness, sorted);
}

/// Node-resolution source plus pre-authenticated account facts for one
/// state-root derivation. Construct with `witnessSource`/`catalogSource`; the
/// argument's type selects the lane at comptime, so each root verb exists
/// once and this type owns the only witness-vs-catalog branches.
pub fn StateSource(comptime mode: mpt.SourceMode) type {
    return struct {
        const Self = @This();
        pub const source_mode = mode;

        resolver: switch (mode) {
            .witness => *const WitnessIndex,
            .catalog => *const WitnessCatalog,
        },
        root_hash: [32]u8,
        authenticated_accounts: ?*const AccountFacts,

        fn previousAccount(
            self: Self,
            accounts: AccountTrie,
            target: address.Address,
        ) UpdateError!Account {
            if (self.authenticated_accounts) |facts| {
                if (facts.get(target)) |account| return account orelse Account{};
            }
            return switch (mode) {
                .witness => try loadAccountOrEmpty(accounts, self.root_hash, self.resolver, target),
                .catalog => try loadCatalogAccountOrEmpty(self.resolver, target),
            };
        }

        fn stateSource(self: Self) mpt.Source(mode) {
            return switch (mode) {
                .witness => mpt.witnessSource(self.resolver, self.root_hash),
                .catalog => self.resolver.source(self.resolver.stateCatalogRoot()),
            };
        }

        /// Storage-trie source under `digest`. The catalog root resolves
        /// lazily, so callers must skip resolution for empty update batches:
        /// an untouched storage trie may be absent from the catalog.
        fn storageSource(self: Self, digest: [32]u8, wiped: bool) UpdateError!mpt.Source(mode) {
            return switch (mode) {
                .witness => mpt.witnessSource(
                    self.resolver,
                    if (wiped) empty_root_hash else digest,
                ),
                .catalog => self.resolver.source(if (wiped)
                    .empty
                else
                    try self.resolver.storageCatalogRoot(digest)),
            };
        }
    };
}

pub fn witnessSource(
    witness: *const WitnessIndex,
    root_hash: [32]u8,
    authenticated_accounts: ?*const AccountFacts,
) StateSource(.witness) {
    return .{
        .resolver = witness,
        .root_hash = root_hash,
        .authenticated_accounts = authenticated_accounts,
    };
}

/// Rejects a `root_hash` that does not match the catalog's authenticated
/// state root, so a mismatched pair never reaches change derivation.
pub fn catalogSource(
    catalog: *const WitnessCatalog,
    root_hash: [32]u8,
    authenticated_accounts: ?*const AccountFacts,
) error{InvalidNodeReference}!StateSource(.catalog) {
    try catalog.validateStateRoot(root_hash);
    return .{
        .resolver = catalog,
        .root_hash = root_hash,
        .authenticated_accounts = authenticated_accounts,
    };
}

fn assertStateSource(comptime T: type) void {
    const valid = @typeInfo(T) == .@"struct" and
        @hasDecl(T, "source_mode") and
        T == StateSource(T.source_mode);
    if (!valid) @compileError(
        "state root derivation requires a trie witnessSource/catalogSource, found " ++ @typeName(T),
    );
}

fn storageRootAfterChanges(
    scratch_arena: *mpt.ScopedArenaAllocator,
    allocator: Allocator,
    root_hash: [32]u8,
    source: anytype,
    changes: anytype,
    storage_write_indices: []const u32,
    wiped: bool,
    node_updates: anytype,
) UpdateError![32]u8 {
    if (storage_write_indices.len == 0) return if (wiped) empty_root_hash else root_hash;

    var updates: std.ArrayList(StorageTrie.Update) =
        try .initCapacity(allocator, storage_write_indices.len);
    defer updates.deinit(allocator);

    for (storage_write_indices) |index| {
        const write = changes.storage_writes.at(index);
        const value: ?[]const u8 = if (write.value == 0)
            null
        else
            try storageValue(allocator, write.value);
        updates.appendAssumeCapacity(.{ .key = write.key, .value = value });
    }

    const storage = storageTrie(allocator);
    return if (comptime @TypeOf(node_updates) == void)
        storage.update(scratch_arena, try source.storageSource(root_hash, wiped), updates.items)
    else
        storage.updateWithNodeUpdates(
            scratch_arena,
            try source.storageSource(root_hash, wiped),
            updates.items,
            node_updates,
        );
}

/// Comptime contract for a changes view, kept structural so this Ethereum
/// codec layer does not import the executor state graph. Any producer that
/// exposes three indexed lists (`len() u32` + `at(u32)`) qualifies:
/// `accounts` (post-state account values or deletes), `storage_writes`
/// (slot writes tagged by account address), and `storage_wipes` (accounts
/// whose entire storage clears before writes apply). `TrackedState.ChangesView`
/// is the live producer; `StateDelta.View` is the detached one.
fn assertChangesView(comptime View: type) void {
    for ([_][]const u8{ "accounts", "storage_writes", "storage_wipes" }) |list_name| {
        if (!@hasField(View, list_name)) @compileError(
            "changes view " ++ @typeName(View) ++ " is missing list '" ++ list_name ++ "'",
        );
    }
    for ([_]type{
        @FieldType(View, "accounts"),
        @FieldType(View, "storage_writes"),
        @FieldType(View, "storage_wipes"),
    }) |List| {
        for ([_][]const u8{ "len", "at" }) |method| {
            if (!std.meta.hasMethod(List, method)) @compileError(
                "changes list " ++ @typeName(List) ++ " is missing '" ++ method ++ "'",
            );
        }
    }
}

/// Convenience for callers holding raw witness nodes: index them into a
/// scratch arena and derive the root through a witness source.
pub fn stateRootAfterChangesFromNodes(
    allocator: Allocator,
    root_hash: [32]u8,
    nodes: []const []const u8,
    changes: anytype,
) UpdateError![32]u8 {
    comptime assertChangesView(@TypeOf(changes));
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    var witness = try indexWitness(scratch, nodes);
    defer witness.deinit();
    return stateRootAfterChanges(scratch, witnessSource(witness, root_hash, null), changes);
}

/// Post-state root for tracked `changes` applied through `source`
/// (`witnessSource` or `catalogSource`).
pub fn stateRootAfterChanges(
    allocator: Allocator,
    source: anytype,
    changes: anytype,
) UpdateError![32]u8 {
    return stateRootAfterChangesWithNodeUpdates(allocator, source, changes, {});
}

pub fn stateRootAfterChangesWithNodeUpdates(
    allocator: Allocator,
    source: anytype,
    changes: anytype,
    node_updates: anytype,
) UpdateError![32]u8 {
    comptime assertStateSource(@TypeOf(source));
    comptime assertChangesView(@TypeOf(changes));
    var scratch_arena: mpt.ScopedArenaAllocator = .init(allocator);
    defer scratch_arena.deinit();

    var batches: AccountBatches = .empty;
    defer batches.deinit(allocator);

    var account_index: u32 = 0;
    while (account_index < changes.accounts.len()) : (account_index += 1) {
        const change = changes.accounts.at(account_index);
        const result = try batches.getOrPut(allocator, change.address);
        if (!result.found_existing) result.value_ptr.* = .{};
        std.debug.assert(result.value_ptr.account_change_index == null);
        result.value_ptr.account_change_index = account_index;
    }

    var wipe_index: u32 = 0;
    while (wipe_index < changes.storage_wipes.len()) : (wipe_index += 1) {
        const target = changes.storage_wipes.at(wipe_index);
        const result = try batches.getOrPut(allocator, target);
        if (!result.found_existing) result.value_ptr.* = .{};
        if (!batchDeletesAccount(changes, result.value_ptr.*)) result.value_ptr.wiped = true;
    }

    var grouped_storage_count: u32 = 0;
    var storage_index: u32 = 0;
    while (storage_index < changes.storage_writes.len()) : (storage_index += 1) {
        const write = changes.storage_writes.at(storage_index);
        const result = try batches.getOrPut(allocator, write.address);
        if (!result.found_existing) result.value_ptr.* = .{};
        if (batchDeletesAccount(changes, result.value_ptr.*)) continue;
        result.value_ptr.storage_len += 1;
        grouped_storage_count += 1;
    }

    var storage_offset: u32 = 0;
    for (batches.values()) |*batch| {
        batch.storage_start = storage_offset;
        batch.storage_cursor = storage_offset;
        storage_offset += batch.storage_len;
    }
    std.debug.assert(storage_offset == grouped_storage_count);

    const storage_write_indices = try allocator.alloc(u32, grouped_storage_count);
    defer allocator.free(storage_write_indices);
    storage_index = 0;
    while (storage_index < changes.storage_writes.len()) : (storage_index += 1) {
        const write = changes.storage_writes.at(storage_index);
        const batch = batches.getPtr(write.address) orelse unreachable;
        if (batchDeletesAccount(changes, batch.*)) continue;
        storage_write_indices[batch.storage_cursor] = storage_index;
        batch.storage_cursor += 1;
    }

    for (batches.values()) |batch| {
        std.debug.assert(batch.storage_cursor == batch.storage_start + batch.storage_len);
    }

    var updates: std.ArrayList(AccountTrie.Update) =
        try .initCapacity(allocator, batches.count());
    defer updates.deinit(allocator);

    const accounts = accountTrie(allocator);
    for (batches.keys(), batches.values()) |target, batch| {
        if (batchDeletesAccount(changes, batch)) {
            updates.appendAssumeCapacity(.{ .key = target, .value = null });
            continue;
        }
        const previous = try source.previousAccount(accounts, target);
        const account_change = if (batch.account_change_index) |index|
            changes.accounts.at(index).account
        else
            null;
        const storage_end = batch.storage_start + batch.storage_len;
        const storage_root = try storageRootAfterChanges(
            &scratch_arena,
            allocator,
            previous.storage_root,
            source,
            changes,
            storage_write_indices[batch.storage_start..storage_end],
            batch.wiped,
            node_updates,
        );
        var next_account = previous;
        if (account_change) |account| {
            next_account.nonce = account.nonce;
            next_account.balance = account.balance;
            next_account.code_hash = account.code_hash;
        }
        next_account.storage_root = storage_root;

        const value: ?[]const u8 = if (next_account.hasNoState())
            null
        else
            try accountValueFrom(allocator, next_account);
        updates.appendAssumeCapacity(.{ .key = target, .value = value });
    }

    return if (comptime @TypeOf(node_updates) == void)
        accounts.update(&scratch_arena, source.stateSource(), updates.items)
    else
        accounts.updateWithNodeUpdates(
            &scratch_arena,
            source.stateSource(),
            updates.items,
            node_updates,
        );
}

pub fn hashedAddressKey(target: address.Address) [32]u8 {
    return AddressKeyContext.trieKey(.{}, target);
}

pub inline fn hashedAddressKeyInto(target: address.Address, digest: *align(8) [32]u8) void {
    crypto.keccak256Into(target.asBytes(), digest);
}

pub fn hashedStorageKey(key: u256) [32]u8 {
    return StorageKeyContext.trieKey(.{}, key);
}

pub inline fn hashedStorageKeyInto(key: u256, digest: *align(8) [32]u8) void {
    crypto.keccak256Into(&uint256.toBytes32(key), digest);
}

pub fn storageValue(allocator: Allocator, value: u256) Allocator.Error![]u8 {
    var out = rlp.Writer.alloc(allocator);
    errdefer out.deinit();
    try writerInt(&out, u256, value);
    return try writerOwned(&out);
}

pub fn storageValueInto(out: *StorageValueBuffer, value: u256) []const u8 {
    return encodeFixedRlpInto(u256, out, value);
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

pub fn accountValueInto(out: *AccountValueBuffer, account: Account) []const u8 {
    return encodeFixedRlpInto(Account, out, account);
}

pub fn decodeAccountValue(encoded: []const u8) ProofLookupError!Account {
    return rlp.decode(Account, encoded);
}

pub fn decodeAccountValueInto(encoded: []const u8, account: *Account) ProofLookupError!void {
    try rlp.decodeInto(Account, encoded, account);
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
    witness: *const WitnessIndex,
    target: address.Address,
) UpdateError!Account {
    return switch (try accounts.lookup(root_hash, witness, target)) {
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

inline fn batchDeletesAccount(changes: anytype, batch: AccountBatch) bool {
    const index = batch.account_change_index orelse return false;
    return changes.accounts.at(index).account == null;
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

fn writerInt(writer: *rlp.Writer, comptime T: type, value: T) Allocator.Error!void {
    writer.int(T, value) catch |err| switch (err) {
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
