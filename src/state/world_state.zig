//! Transaction and scope lifecycle over a `World` that owns execution rows.
//!
//! `WorldState(World)` owns rollback, observations, and accepted branch tracking.
//! `World` supplies row, key resolution, parent reads, and optional trie
//! ordering.
//! Rows retain their id across attempts and hold a value from admission
//!
//! `findAccount`/`findStorage` query existing rows and may update lookup memos.
//! `resolveAccount`/`resolveStorage` may admit rows.
//! reader and trie boundaries use `Address`. Open-world warmth for keys without
//! rows is tracked separately, so warming does not require parent I/O.
//!
//! A world with `caches_parent_code` owns cached parent code; the State's code
//! store holds introduced code. Otherwise parent code is supplied to the store
//! at initialization.
//!
//! An attempt permits writes before its execution scope opens. Those writes
//! survive scope rollback and are undone by discarding the attempt. Reads outside
//! an open, unsealed attempt do not record observations. Every attempt tracks
//! observations; `beginObservedTransaction` also enables their sealed view.

const std = @import("std");

const crypto = @import("../crypto.zig");
const execution = @import("../execution.zig");
const Host = @import("../Host.zig");
const state_types = @import("../state.zig");
const Account = @import("./Account.zig");
const sparse_hash_map = @import("./sparse_hash_map.zig");
const ordered_map = @import("./ordered_map.zig");
const artifacts = @import("../eth/bal/claim_artifacts.zig");

const Allocator = std.mem.Allocator;
const Address = @import("../address.zig").Address;
const AddressWord = @import("../address.zig").AddressWord;
const storageStatus = @import("./storage.zig").status;

const LogBuffer = @import("./LogBuffer.zig");
const LogView = LogBuffer.View;
const AccessHint = state_types.AccessHint;
const Checkpoint = state_types.Checkpoint;
const FinalizationRules = state_types.FinalizationRules;
const CodeView = state_types.CodeView;
const AccountObservation = state_types.AccountObservation;
const StorageObservation = state_types.StorageObservation;
const AccountEffect = state_types.AccountEffect;
const StorageEffect = state_types.StorageEffect;
const ChangeLayer = state_types.ChangeLayer;
const AccountChange = state_types.AccountChange;
const StorageChange = state_types.StorageChange;
const AccountObservationRecord = state_types.AccountObservationRecord;
const StorageObservationRecord = state_types.StorageObservationRecord;
const StorageObservationMetadata = state_types.StorageObservationMetadata;
const CodeHash = [32]u8;

pub const CodeStore = artifacts.CodeStore;
pub const CodeRef = artifacts.CodeRef;

pub const ResolutionPolicy = enum {
    /// State reads/writes, observed system calls, and EIP-7702 authority paths
    /// after preliminary tuple validation all feed observation.
    required_observed,
    /// EIP-2930 list warming and delegated-target warming do not themselves
    /// emit accesses; a later real access resolves through the required path.
    optional_warm_only,
};

pub const AccountFlags = packed struct {
    block_changed: bool = false,
    storage_dirty: bool = false,
    storage_wiped: bool = false,
    touched: bool = false,
    created: bool = false,
    selfdestructed: bool = false,
    _padding: u2 = 0,
};

pub const StorageFlags = packed struct {
    block_dirty: bool = false,
    _padding: u7 = 0,
};

/// The State lifetimes that issue stamps. Each is a distinct `Generation`
/// type, so a row stamp compares only with its own lifetime's active value.
pub const Lifetime = enum { transaction, scope, root };

/// A lifetime identifier issued by the State clock. Nonzero values are unique
/// between clock resets; a row stamp matches when equal to the active value of
/// its lifetime. `none` denotes an unset or cleared stamp and is never issued.
pub fn Generation(comptime of: Lifetime) type {
    return enum(u32) {
        none = 0,
        _,

        /// Referenced so each lifetime is a distinct type, not one interned enum.
        pub const lifetime = of;
    };
}

comptime {
    std.debug.assert(Generation(.transaction) != Generation(.scope));
}

/// Version of one account's storage, initially `parent`. A wipe advances the
/// account's incarnation; a slot with a different incarnation reads as zero.
/// Restored alongside row values by rollback and branch restoration.
pub const Incarnation = enum(u32) {
    parent = 0,
    _,

    /// Return the successor. Requires a value below `maxInt(u32)`; overflow is
    /// safety-checked illegal behavior, with no wrap or reset policy here.
    pub inline fn next(self: Incarnation) Incarnation {
        return @enumFromInt(@intFromEnum(self) + 1);
    }
};

/// Index into the containing row's account or storage observation list, valid
/// only in the transaction matching `transaction`. Scope rollback preserves the
/// handle and recorded reads; observation effects unwind separately.
pub const ObservationHandle = struct {
    transaction: Generation(.transaction) = .none,
    index: u32 = 0,
};

/// Index of the first storage undo record in the transaction matching `transaction`. A
/// current handle also marks the slot as transaction-dirty. The first write
/// captures it; scope rollback restores the previous handle with the value.
pub const TransactionUndoHandle = struct {
    transaction: Generation(.transaction) = .none,
    index: u32 = 0,
};

/// Account value and tracking metadata retained across attempts until rows reset.
/// `current` is initialized on admission; `null` means absent, never unloaded.
/// Each stamp is qualified by its named lifetime and follows the rollback rule
/// documented on that field.
pub const AccountRow = struct {
    current: ?Account,
    code_ref: CodeRef,
    flags: AccountFlags = .{},
    /// Transaction that listed the row in `lifecycle_accounts`. Outside `flags`
    /// on purpose: the listing is not journaled.
    lifecycle_transaction: Generation(.transaction) = .none,
    /// Scope that already holds this row's undo record. Restored by undo.
    journaled_scope: Generation(.scope) = .none,
    /// Transaction in which the row became warm. Only a cold-to-warm transition
    /// adds a warmth undo entry; reverting that entry clears this stamp to `none`.
    warm_transaction: Generation(.transaction) = .none,
    /// Membership and recorded reads survive scope rollback; effects revert.
    /// Observation records are released when the attempt ends.
    observation: ObservationHandle = .{},
    /// Transaction in which the account was marked dirty. Restored by undo.
    dirty_transaction: Generation(.transaction) = .none,
    /// Advanced by each storage wipe; slots with a different incarnation read
    /// as zero. Restored by undo.
    storage_incarnation: Incarnation = .parent,
    /// Transaction in which storage was wiped; deduplicates the wipe list.
    /// Restored by undo.
    wiped_transaction: Generation(.transaction) = .none,

    comptime {
        std.debug.assert(@sizeOf(AccountRow) == 144);
    }

    /// Row for a value the world just admitted; code binds lazily.
    pub fn admitted(current: ?Account) AccountRow {
        return .{
            .current = current,
            .code_ref = if (std.mem.eql(u8, &accountCodeHash(current), &crypto.keccak256_empty))
                .empty
            else
                .missing,
        };
    }
};

/// Storage value and tracking metadata retained across attempts until rows reset.
/// `current` was written under `storage_incarnation`; the effective value is zero
/// when that incarnation differs from the owning account's.
pub const StorageRow = struct {
    current: u256,
    /// EIP-2200 original for the execution root in `execution_original_root`.
    /// Captured on first use in that execution root; preserved across nested rollback.
    execution_original: u256 = 0,
    flags: StorageFlags = .{},
    /// Scope that already holds this row's undo record. Restored by undo.
    journaled_scope: Generation(.scope) = .none,
    /// Cleared to `none` by revert; see `AccountRow.warm_transaction`.
    warm_transaction: Generation(.transaction) = .none,
    /// Preserved across scope rollback; see `AccountRow.observation`. The
    /// observation row also holds the transaction original.
    observation: ObservationHandle = .{},
    execution_original_root: Generation(.root) = .none,
    /// Restored by undo together with the value.
    transaction_undo: TransactionUndoHandle = .{},
    /// Incarnation `current` was written under. Restored by undo.
    storage_incarnation: Incarnation = .parent,

    comptime {
        std.debug.assert(@sizeOf(StorageRow) == 112);
    }
};

/// Heap-owned values for every world row at one branch boundary. The world
/// owns how these values map back onto its row identity and storage shape.
pub const RowSnapshot = struct {
    accounts: []AccountRow,
    storage: []StorageRow,

    pub fn clone(self: *const RowSnapshot, allocator: Allocator) Allocator.Error!RowSnapshot {
        const accounts = try allocator.dupe(AccountRow, self.accounts);
        errdefer allocator.free(accounts);
        return .{
            .accounts = accounts,
            .storage = try allocator.dupe(StorageRow, self.storage),
        };
    }

    pub fn deinit(self: *RowSnapshot, allocator: Allocator) void {
        allocator.free(self.accounts);
        allocator.free(self.storage);
        self.* = undefined;
    }
};

/// EIP-1153 key, one per transaction-owned map. Word storage carries the
/// boundary conversion once and drops padding, so `hash` may digest every
/// byte while `eql` compares fields.
pub const TransientKey = extern struct {
    address_word: AddressWord,
    slot_words: [4]u64,

    pub fn init(address_word: AddressWord, slot: u256) TransientKey {
        return .{ .address_word = address_word, .slot_words = @bitCast(slot) };
    }

    pub const HashContext = struct {
        pub inline fn hash(_: HashContext, value: TransientKey) u64 {
            return std.hash.Wyhash.hash(0, std.mem.asBytes(&value));
        }

        pub inline fn eql(_: HashContext, a: TransientKey, b: TransientKey) bool {
            return TransientKey.eql(a, b);
        }
    };

    /// Total order for the balanced-tree map: address words, then slot words.
    pub fn order(a: TransientKey, b: TransientKey) std.math.Order {
        const address_order = a.address_word.order(b.address_word);
        if (address_order != .eq) return address_order;
        inline for (a.slot_words, b.slot_words) |left, right| {
            if (left != right) return std.math.order(left, right);
        }
        return .eq;
    }

    pub inline fn eql(a: TransientKey, b: TransientKey) bool {
        return a.address_word.eql(b.address_word) and
            a.slot_words[0] == b.slot_words[0] and
            a.slot_words[1] == b.slot_words[1] and
            a.slot_words[2] == b.slot_words[2] and
            a.slot_words[3] == b.slot_words[3];
    }

    comptime {
        std.debug.assert(std.meta.hasUniqueRepresentation(TransientKey));
        std.debug.assert(@sizeOf(TransientKey) == 56);
        std.debug.assert(@alignOf(TransientKey) == 8);
    }
};

pub fn accountCodeHash(value: ?Account) CodeHash {
    return if (value) |account| account.code_hash else crypto.keccak256_empty;
}

/// `ensureUnusedCapacity` is an out-of-line call on every append, and the
/// guest pays it about as often as the append itself. Decide the common case
/// inline and call out only to grow.
inline fn reserve(list: anytype, allocator: Allocator, count: usize) Allocator.Error!void {
    if (list.capacity - list.items.len >= count) return;
    return list.ensureUnusedCapacity(allocator, count);
}

pub const Options = struct {
    /// Whether the lane allocates rows as execution touches state.
    grows_on_touch: bool,
    authenticated_parents: bool,
    caches_parent_code: bool,
};

/// Transaction-local warmth for open-world keys that have no loaded row.
/// Entries keep stable ids until transaction end, even after rollback clears
/// their warm bit. A later row warm is journaled independently, so reverting
/// its scope preserves any earlier key-only warmth.
const DeferredWarmth = struct {
    const Accounts = sparse_hash_map.WithContext(AddressWord, bool, AddressWord.HashContext);
    const Storage = sparse_hash_map.WithContext(TransientKey, bool, TransientKey.HashContext);

    accounts: Accounts,
    storage: Storage,

    fn init(allocator: Allocator) DeferredWarmth {
        return .{ .accounts = .init(allocator), .storage = .init(allocator) };
    }

    fn deinit(self: *DeferredWarmth) void {
        self.accounts.deinit();
        self.storage.deinit();
    }

    fn clearRetainingCapacity(self: *DeferredWarmth) void {
        self.accounts.clearRetainingCapacity();
        self.storage.clearRetainingCapacity();
    }

    fn allocationBytes(self: *const DeferredWarmth) usize {
        return self.accounts.allocationBytes() + self.storage.allocationBytes();
    }
};

/// Assert `World` provides what `WorldState` composes over. Row storage and
/// key resolution are the world's; everything else is written once here.
pub fn checkWorld(comptime World: type) void {
    comptime {
        std.debug.assert(@TypeOf(World.options) == Options);

        const options: Options = World.options;

        if (options.grows_on_touch and !std.meta.hasMethod(World, "reserveRows")) @compileError(
            "world " ++ @typeName(World) ++ " grows on touch but has no 'reserveRows'",
        );

        if (options.authenticated_parents) {
            const commit_methods = [_][]const u8{
                "accountTrieOrder", "storageTrieOrder", "accountTrieKey", "storageTrieKey", "parentAccount",
            };
            for (commit_methods) |method| {
                if (!std.meta.hasMethod(World, method)) @compileError(
                    "world " ++ @typeName(World) ++ " authenticates parents but is missing '" ++ method ++ "'",
                );
            }
        }
    }
}

pub fn WorldState(comptime World: type) type {
    comptime checkWorld(World);

    return struct {
        const options: Options = World.options;

        const State = @This();

        pub const AccountKey = AddressWord;
        pub const AccountId = World.AccountId;
        pub const StorageId = World.StorageId;
        pub const ResolutionError = World.ResolutionError;

        // Balanced tree, not a hash table: TSTORE keys are payload-chosen at
        // 100 gas each and a guest has no per-run seed, so a hash table's cost
        // is the attacker's choice. Real blocks touch a handful of transient
        // slots, so the tree's per-op cost is invisible there.
        const TransientStorageMap = ordered_map.OrderedMap(TransientKey, u256, TransientKey.order);

        const ResolvedStorage = struct {
            account: AccountId,
            storage: StorageId,
        };

        allocator: Allocator,
        world: World,
        code: CodeStore,
        transient_storage: TransientStorageMap,
        deferred_warmth: if (options.grows_on_touch) DeferredWarmth else void,
        logs: LogBuffer = .{},
        retained_logs: LogBuffer = .{},
        block_changed_accounts: std.ArrayList(AccountId) = .empty,
        block_storage_wipes: std.ArrayList(AccountId) = .empty,
        dirty_storage: std.ArrayList(StorageId) = .empty,
        changed_accounts: std.ArrayList(AccountId) = .empty,
        changed_storage: std.ArrayList(StorageId) = .empty,
        transaction_storage_wipes: std.ArrayList(AccountId) = .empty,
        lifecycle_accounts: std.ArrayList(AccountId) = .empty,
        block_introduced_codes: std.ArrayList(artifacts.IntroducedCodeId) = .empty,
        observed_accounts: std.ArrayList(AccountObservationRow) = .empty,
        observed_storage: std.ArrayList(StorageObservationRow) = .empty,
        journal: Journal = .{},
        /// Last issued value; every lifetime draws from it, so a value is unique
        /// within its lifetime between resets. Rollback never rewinds it;
        /// `discardAccepted` resets it together with the rows. Seeding and branch
        /// restoration preserve it because retained rows may carry old stamps.
        /// The caller must bound total ticks between resets below u32 exhaustion.
        clock: u32 = 0,
        /// The active value of each lifetime, a row stamp matches when equal.
        /// Both clear at attempt end. Stale row stamps are never cleared: a moved
        /// lifetime invalidates them lazily.
        lifetime: struct {
            /// Issued at attempt begin and retained after, also require `transaction_active`.
            transaction: Generation(.transaction) = .none,
            /// Issued at begin, `beginScope`, `closeScope`, and every checkpoint,
            /// restored to the parent on commit and revert.
            scope: Generation(.scope) = .none,
            /// Moves with `scope` except at checkpoints, so execution originals survive nested rollback.
            root: Generation(.root) = .none,
        } = .{},
        /// Advanced by `discardAccepted` and seeding; a branch snapshot is only valid
        /// within the epoch that captured it.
        world_epoch: u64 = 0,
        observed_attempt: bool = false,
        sealed: bool = false,
        /// `transaction_active and !sealed`, kept as one byte because every
        /// read consults it.
        attempt_open: bool = false,
        scope_depth: u32 = 0,
        transaction_active: bool = false,
        /// Set by `revertToCheckpoint`; only then can block or transaction ID lists
        /// hold stale or duplicate entries, so revert-free transactions skip their
        /// compaction passes.
        transaction_scope_reverted: bool = false,
        /// Accepted rows occupy each block list's prefix; the attempt appends a
        /// rollbackable suffix. Captured at begin, restored by `discard`.
        accepted_len: struct {
            block_changed_accounts: u32 = 0,
            block_storage_wipes: u32 = 0,
            dirty_storage: u32 = 0,
            block_introduced_codes: u32 = 0,
        } = .{},

        /// The current value is the row's: every account write goes through
        /// the row, and rollback restores row and effect together.
        const AccountObservationRow = struct {
            account: AccountId,
            original: ?Account,
            original_storage_incarnation: Incarnation,
            observation: AccountObservation,
            effect: AccountEffect = .{},
        };

        /// The current value is the original until a write, then the row's:
        /// rollback restores the row and the written flag together. A later
        /// lifecycle wipe is not reflected; consumers treat every slot of a
        /// wiped account as a read.
        const StorageObservationRow = struct {
            storage: StorageId,
            original: u256,
            observation: StorageObservation,
            effect: StorageEffect = .{},
        };

        pub const AccountChanges = struct {
            state: *const State,
            layer: ChangeLayer,

            pub fn len(self: AccountChanges) u32 {
                return @intCast(self.ids().len);
            }

            pub fn at(self: AccountChanges, index: u32) AccountChange {
                const id = self.ids()[index];
                return .{
                    .address = self.state.world.accountAddress(id),
                    .account = switch (self.layer) {
                        .accepted => self.state.acceptedAccountValue(id),
                        .transaction => self.state.world.accountRow(id).current,
                    },
                };
            }

            fn ids(self: AccountChanges) []const AccountId {
                return switch (self.layer) {
                    .accepted => if (self.state.transaction_active)
                        self.state.block_changed_accounts.items[0..self.state.accepted_len.block_changed_accounts]
                    else
                        self.state.block_changed_accounts.items,
                    .transaction => self.state.changed_accounts.items,
                };
            }
        };

        pub const StorageChanges = struct {
            state: *const State,
            layer: ChangeLayer,

            pub fn len(self: StorageChanges) u32 {
                return @intCast(self.ids().len);
            }

            pub fn at(self: StorageChanges, index: u32) StorageChange {
                const id = self.ids()[index];
                const account = self.state.world.storageAccount(id);
                return .{
                    .address = self.state.world.accountAddress(account),
                    .key = self.state.world.storageSlot(id),
                    .value = switch (self.layer) {
                        .accepted => self.state.acceptedStorageValue(id),
                        .transaction => self.state.effectiveStorage(id),
                    },
                };
            }

            fn ids(self: StorageChanges) []const StorageId {
                return switch (self.layer) {
                    .accepted => if (self.state.transaction_active)
                        self.state.dirty_storage.items[0..self.state.accepted_len.dirty_storage]
                    else
                        self.state.dirty_storage.items,
                    .transaction => self.state.changed_storage.items,
                };
            }
        };

        pub const StorageWipes = struct {
            state: *const State,
            layer: ChangeLayer,

            pub fn len(self: StorageWipes) u32 {
                return @intCast(self.ids().len);
            }

            pub fn at(self: StorageWipes, index: u32) Address {
                return self.state.world.accountAddress(self.ids()[index]);
            }

            fn ids(self: StorageWipes) []const AccountId {
                return switch (self.layer) {
                    .accepted => if (self.state.transaction_active)
                        self.state.block_storage_wipes.items[0..self.state.accepted_len.block_storage_wipes]
                    else
                        self.state.block_storage_wipes.items,
                    .transaction => self.state.transaction_storage_wipes.items,
                };
            }
        };

        /// Borrowed semantic delta. Ordering is unspecified; consumers own sorting,
        /// allocation, persistence batches, and any retained representation.
        pub const ChangesView = struct {
            state: *const State,
            layer: ChangeLayer,
            accounts: AccountChanges,
            storage_writes: StorageChanges,
            storage_wipes: StorageWipes,

            fn init(state: *const State, layer: ChangeLayer) ChangesView {
                return .{
                    .state = state,
                    .layer = layer,
                    .accounts = .{ .state = state, .layer = layer },
                    .storage_writes = .{ .state = state, .layer = layer },
                    .storage_wipes = .{ .state = state, .layer = layer },
                };
            }

            pub fn introducedCode(self: ChangesView, code_hash: CodeHash) ?CodeView {
                const ids = switch (self.layer) {
                    .accepted => if (self.state.transaction_active)
                        self.state.block_introduced_codes.items[0..self.state.accepted_len.block_introduced_codes]
                    else
                        self.state.block_introduced_codes.items,
                    .transaction => self.state.block_introduced_codes.items[self.state.accepted_len.block_introduced_codes..],
                };
                for (ids) |id| {
                    const view = self.state.code.introducedView(id);
                    if (std.mem.eql(u8, &view.code_hash, &code_hash)) return view;
                }
                return null;
            }

            pub fn hasChanges(self: ChangesView) bool {
                return self.accounts.len() != 0 or
                    self.storage_writes.len() != 0 or
                    self.storage_wipes.len() != 0;
            }
        };

        /// Dense transaction-local account observation records. Ordering is internal; projectors own
        /// sorting and any retained representation.
        pub const AccountObservations = struct {
            state: *const State,

            pub fn len(self: AccountObservations) u32 {
                return @intCast(self.state.observed_accounts.items.len);
            }

            pub fn at(self: AccountObservations, index: u32) AccountObservationRecord {
                const observed = &self.state.observed_accounts.items[index];
                return .{
                    .address = self.state.world.accountAddress(observed.account),
                    .original = observed.original,
                    .current = self.state.world.accountRow(observed.account).current,
                    .observation = observed.observation,
                    .effect = observed.effect,
                };
            }

            pub fn idAt(self: AccountObservations, index: u32) AccountId {
                return self.state.observed_accounts.items[index].account;
            }
        };

        /// Dense transaction-local storage observations. Every observed slot carries a
        /// complete value record because a row holds a value from admission.
        pub const StorageObservations = struct {
            state: *const State,

            pub fn len(self: StorageObservations) u32 {
                return @intCast(self.state.observed_storage.items.len);
            }

            pub fn at(self: StorageObservations, index: u32) StorageObservationRecord {
                const observed = &self.state.observed_storage.items[index];
                const account = self.state.world.storageAccount(observed.storage);
                return .{
                    .address = self.state.world.accountAddress(account),
                    .key = self.state.world.storageSlot(observed.storage),
                    .original = observed.original,
                    .current = if (observed.effect.written)
                        self.state.world.storageRow(observed.storage).current
                    else
                        observed.original,
                    .observation = observed.observation,
                    .effect = observed.effect,
                };
            }

            pub fn idAt(self: StorageObservations, index: u32) StorageId {
                return self.state.observed_storage.items[index].storage;
            }

            pub fn metadataAt(self: StorageObservations, index: u32) StorageObservationMetadata {
                const observed = &self.state.observed_storage.items[index];
                const account = self.state.world.storageAccount(observed.storage);
                return .{
                    .address = self.state.world.accountAddress(account),
                    .key = self.state.world.storageSlot(observed.storage),
                    .observation = observed.observation,
                    .effect = observed.effect,
                };
            }
        };

        /// Borrowed checkpoint-resolved semantic observations from one sealed
        /// transaction. BAL indices, output ordering, and detached ownership remain
        /// projector policy.
        pub const ObservationsView = struct {
            state: *const State,
            accounts: AccountObservations,
            storage: StorageObservations,

            fn init(state: *const State) ObservationsView {
                return .{
                    .state = state,
                    .accounts = .{ .state = state },
                    .storage = .{ .state = state },
                };
            }

            pub fn code(self: ObservationsView, code_hash: CodeHash) ?CodeView {
                return self.state.code.lookup(code_hash) orelse self.state.world.cachedCode(code_hash);
            }
        };

        /// Borrowed cumulative branch changes. Projectors own output policy and
        /// allocation; this view only exposes the accepted state representation.
        pub const AcceptedView = struct {
            state: *const State,

            pub fn hasChanges(self: AcceptedView) bool {
                return self.changes().hasChanges();
            }

            pub fn changes(self: AcceptedView) ChangesView {
                return ChangesView.init(self.state, .accepted);
            }

            /// Commit projection over the same sealed rows (`state.checkCommitView`).
            /// Only a world that knows its trie order and authenticated its
            /// parents up front can hand one out; the open lane sorts a changes
            /// view at seal instead.
            pub fn commit(self: AcceptedView) CommitView {
                comptime std.debug.assert(options.authenticated_parents);
                return .{ .state = self.state };
            }
        };

        pub const CommitView = struct {
            state: *const State,

            pub const authenticated_parents = options.authenticated_parents;

            pub fn accountTrieOrder(self: CommitView) []const AccountId {
                return self.state.world.accountTrieOrder();
            }

            pub fn storageTrieOrder(self: CommitView, account: AccountId) []const StorageId {
                return self.state.world.storageTrieOrder(account);
            }

            pub fn accountTrieKey(self: CommitView, id: AccountId) [32]u8 {
                return self.state.world.accountTrieKey(id);
            }

            pub fn storageTrieKey(self: CommitView, id: StorageId) [32]u8 {
                return self.state.world.storageTrieKey(id);
            }

            pub fn parentAccount(self: CommitView, id: AccountId) @TypeOf(self.state.world.parentAccount(id)) {
                return self.state.world.parentAccount(id);
            }

            pub fn accountValue(self: CommitView, id: AccountId) ?Account {
                return self.state.world.accountRow(id).current;
            }

            pub fn storageValue(self: CommitView, id: StorageId) u256 {
                return self.state.effectiveStorage(id);
            }

            /// Commitment work follows changes to account fields or storage.
            pub fn accountDirty(self: CommitView, id: AccountId) bool {
                const flags = self.state.world.accountRow(id).flags;
                return flags.block_changed or flags.storage_dirty;
            }

            pub fn accountChanged(self: CommitView, id: AccountId) bool {
                return self.state.world.accountRow(id).flags.block_changed;
            }

            pub fn accountStorageDirty(self: CommitView, id: AccountId) bool {
                return self.state.world.accountRow(id).flags.storage_dirty;
            }

            pub fn storageDirty(self: CommitView, id: StorageId) bool {
                const row = self.state.world.storageRow(id);
                const account = self.state.world.accountRow(self.state.world.storageAccount(id));
                return row.flags.block_dirty and
                    row.storage_incarnation == account.storage_incarnation;
            }

            pub fn storageWiped(self: CommitView, id: AccountId) bool {
                return self.state.world.accountRow(id).flags.storage_wiped;
            }
        };

        /// Borrowed sealed transaction plus the cumulative branch it would extend.
        /// The view does not own or resolve the transaction lifecycle.
        pub const PendingView = struct {
            state: *const State,

            pub fn accepted(self: PendingView) AcceptedView {
                self.state.assertSealed();
                return .{ .state = self.state };
            }

            pub fn logs(self: PendingView) LogView {
                self.state.assertSealed();
                return self.state.logs.view();
            }

            /// Transaction-local changes relative to the accepted branch.
            pub fn changes(self: PendingView) ChangesView {
                self.state.assertSealed();
                return ChangesView.init(self.state, .transaction);
            }

            pub fn observations(self: PendingView) ObservationsView {
                self.state.assertSealed();
                std.debug.assert(self.state.observed_attempt);
                return ObservationsView.init(self.state);
            }
        };

        /// Owned snapshot of accepted rows, logs, and change lists. Capture requires
        /// no active attempt. Restore requires the same State and `world_epoch`,
        /// consumes this snapshot, and may discard an attempt whose scope is closed.
        /// Capture and clone allocate; restore does not. Call `deinit` after use.
        pub const BranchSnapshot = struct {
            owner: *const State,
            allocator: Allocator,
            rows: RowSnapshot,
            retained_logs: LogBuffer,
            block_changed_accounts: []AccountId,
            block_storage_wipes: []AccountId,
            dirty_storage: []StorageId,
            block_introduced_codes_len: u32,
            introduced_code_len: u32,
            world_epoch: u64,
            resolved: bool = false,

            pub fn clone(self: *const BranchSnapshot) Allocator.Error!BranchSnapshot {
                std.debug.assert(!self.resolved);
                var rows = try self.rows.clone(self.allocator);
                errdefer rows.deinit(self.allocator);
                const block_changed_accounts = try self.allocator.dupe(AccountId, self.block_changed_accounts);
                errdefer self.allocator.free(block_changed_accounts);
                const block_storage_wipes = try self.allocator.dupe(AccountId, self.block_storage_wipes);
                errdefer self.allocator.free(block_storage_wipes);
                const dirty_storage = try self.allocator.dupe(StorageId, self.dirty_storage);
                errdefer self.allocator.free(dirty_storage);
                return .{
                    .owner = self.owner,
                    .allocator = self.allocator,
                    .rows = rows,
                    .retained_logs = try self.retained_logs.clone(self.allocator),
                    .block_changed_accounts = block_changed_accounts,
                    .block_storage_wipes = block_storage_wipes,
                    .dirty_storage = dirty_storage,
                    .block_introduced_codes_len = self.block_introduced_codes_len,
                    .introduced_code_len = self.introduced_code_len,
                    .world_epoch = self.world_epoch,
                };
            }

            pub fn deinit(self: *BranchSnapshot) void {
                self.allocator.free(self.block_changed_accounts);
                self.allocator.free(self.block_storage_wipes);
                self.allocator.free(self.dirty_storage);
                self.rows.deinit(self.allocator);
                self.retained_logs.deinit(self.allocator);
                self.* = undefined;
            }
        };

        const Journal = struct {
            const Id = enum(u32) { _ };

            const Entry = union(enum(u8)) {
                account: Id,
                storage: Id,
                /// A storage write needs only this flag undo unless a full
                /// account undo already covers the current scope.
                account_storage_dirty: AccountId,
                warm_account: AccountId,
                warm_storage: StorageId,
                deferred_warm_account: DeferredWarmth.Accounts.EntryId,
                deferred_warm_storage: DeferredWarmth.Storage.EntryId,
                transient_storage: Id,
                /// Pops the pairwise appends to both introduced-code lists. LIFO
                /// unwind matches them exactly because every introduction appends to
                /// both lists and the journal in the same operation.
                introduced_code,

                comptime {
                    std.debug.assert(@sizeOf(Entry) == 8);
                }
            };

            /// Row fields plus the observation effect; the observation handle
            /// survives rollback, so the row finds its observation at undo.
            const AccountUndo = struct {
                account: AccountId,
                current: ?Account,
                code_ref: CodeRef,
                flags: AccountFlags,
                journaled_scope: Generation(.scope),
                storage_incarnation: Incarnation,
                wiped_transaction: Generation(.transaction),
                dirty_transaction: Generation(.transaction),
                effect: AccountEffect,
            };

            const StorageUndo = struct {
                storage: StorageId,
                current: u256,
                flags: StorageFlags,
                journaled_scope: Generation(.scope),
                storage_incarnation: Incarnation,
                transaction_undo: TransactionUndoHandle,
                effect: StorageEffect,
            };

            const TransientUndo = struct {
                key: TransientKey,
                previous: u256,
            };

            entries: std.ArrayList(Entry) = .empty,
            accounts: std.ArrayList(AccountUndo) = .empty,
            storage: std.ArrayList(StorageUndo) = .empty,
            transient: std.ArrayList(TransientUndo) = .empty,

            fn deinit(self: *Journal, allocator: Allocator) void {
                self.entries.deinit(allocator);
                self.accounts.deinit(allocator);
                self.storage.deinit(allocator);
                self.transient.deinit(allocator);
                self.* = undefined;
            }

            fn clearRetainingCapacity(self: *Journal) void {
                self.entries.clearRetainingCapacity();
                self.accounts.clearRetainingCapacity();
                self.storage.clearRetainingCapacity();
                self.transient.clearRetainingCapacity();
            }

            /// Every payload list is cleared together with `entries`, so the entry
            /// list alone decides emptiness.
            fn isEmpty(self: *const Journal) bool {
                return self.entries.items.len == 0;
            }

            fn ensureAccount(self: *Journal, allocator: Allocator) !void {
                try reserve(&self.entries, allocator, 1);
                try reserve(&self.accounts, allocator, 1);
            }

            /// Reserve a storage undo and at most one account flag undo.
            fn ensureStorage(self: *Journal, allocator: Allocator) !void {
                try reserve(&self.entries, allocator, 2);
                try reserve(&self.storage, allocator, 1);
            }

            fn ensureWarm(self: *Journal, allocator: Allocator) !void {
                try reserve(&self.entries, allocator, 1);
            }

            fn appendTransient(self: *Journal, allocator: Allocator, undo: TransientUndo) !void {
                try reserve(&self.entries, allocator, 1);
                try reserve(&self.transient, allocator, 1);
                const id: Id = @enumFromInt(self.transient.items.len);
                self.transient.appendAssumeCapacity(undo);
                self.entries.appendAssumeCapacity(.{ .transient_storage = id });
            }

            fn appendAccountAssumeCapacity(self: *Journal, undo: AccountUndo) void {
                const id: Id = @enumFromInt(self.accounts.items.len);
                self.accounts.appendAssumeCapacity(undo);
                self.entries.appendAssumeCapacity(.{ .account = id });
            }

            fn appendStorageAssumeCapacity(self: *Journal, undo: StorageUndo) void {
                const id: Id = @enumFromInt(self.storage.items.len);
                self.storage.appendAssumeCapacity(undo);
                self.entries.appendAssumeCapacity(.{ .storage = id });
            }
        };

        /// Take ownership of `world`; introduced code starts empty.
        pub fn init(allocator: Allocator, world: World) State {
            return initWithCodeStore(allocator, world, .{ .introduced = .init(allocator) });
        }

        /// Take ownership of `world` and a code store carrying parent codes.
        /// Rows bind their code reference on first fetch (`bindCode`), so a
        /// row whose code is never executed never searches the store.
        pub fn initWithCodeStore(allocator: Allocator, world: World, code: CodeStore) State {
            return .{
                .allocator = allocator,
                .world = world,
                .code = code,
                .transient_storage = TransientStorageMap.init(allocator),
                .deferred_warmth = if (options.grows_on_touch) .init(allocator) else {},
            };
        }

        /// An unresolved attempt is released with everything else: the
        /// executor tolerates one at its own deinit, so nothing is owed.
        pub fn deinit(self: *State) void {
            self.code.deinit(self.allocator);
            self.transient_storage.deinit();
            if (comptime options.grows_on_touch) self.deferred_warmth.deinit();
            self.logs.deinit(self.allocator);
            self.retained_logs.deinit(self.allocator);
            self.block_changed_accounts.deinit(self.allocator);
            self.block_storage_wipes.deinit(self.allocator);
            self.dirty_storage.deinit(self.allocator);
            self.changed_accounts.deinit(self.allocator);
            self.changed_storage.deinit(self.allocator);
            self.transaction_storage_wipes.deinit(self.allocator);
            self.lifecycle_accounts.deinit(self.allocator);
            self.block_introduced_codes.deinit(self.allocator);
            self.observed_accounts.deinit(self.allocator);
            self.observed_storage.deinit(self.allocator);
            self.journal.deinit(self.allocator);
            self.world.deinit(self.allocator);
            self.* = undefined;
        }

        /// Seed base state for fixtures and examples through the world. Only
        /// valid before any block change; the world normalizes the value the
        /// way a parent load would.
        pub fn seedAccount(self: *State, address: Address, account: anytype) !void {
            std.debug.assert(!self.transaction_active);
            std.debug.assert(self.block_changed_accounts.items.len == 0);
            std.debug.assert(self.block_storage_wipes.items.len == 0);
            std.debug.assert(self.dirty_storage.items.len == 0);
            std.debug.assert(self.block_introduced_codes.items.len == 0);
            // Seeding can reorder row identities before failing. Invalidate first.
            self.world_epoch += 1;
            return self.world.seedAccount(address, account);
        }

        /// A hint is meaningful only to a world that grows on touch; a
        /// declared universe has nothing to reserve, and the whole call folds
        /// away at comptime so the caller's code shape does not change.
        pub fn reserveAccessHint(self: *State, hint: AccessHint) !void {
            if (comptime !options.grows_on_touch) return;
            self.assertAttempt();
            try self.world.reserveRows(hint);
        }

        pub fn reserveAcceptedAccessHint(self: *State, hint: AccessHint) !void {
            if (comptime !options.grows_on_touch) return;
            std.debug.assert(!self.transaction_active);
            try self.world.reserveRows(hint);
        }

        /// Start a mutable attempt on the accepted branch, with no execution scope.
        /// Asserts no attempt is active and the journal is empty. The returned
        /// generation identifies this attempt on this State; finish it with
        /// `retain` or `discard`. Copies must not be reused after a clock reset.
        /// Observations are tracked internally but not exposed through the pending view.
        pub fn beginTransaction(self: *State) Generation(.transaction) {
            return self.beginTransactionMode(false);
        }

        /// Start an attempt as in `beginTransaction`, enabling observation access
        /// through the pending view after sealing.
        pub fn beginObservedTransaction(self: *State) Generation(.transaction) {
            return self.beginTransactionMode(true);
        }

        fn beginTransactionMode(self: *State, comptime observe: bool) Generation(.transaction) {
            std.debug.assert(!self.transaction_active);
            std.debug.assert(self.journal.isEmpty());
            self.lifetime.transaction = self.tick(.transaction);
            self.observed_attempt = observe;
            self.sealed = false;
            self.transaction_active = true;
            self.attempt_open = true;
            // Pre-scope writes journal against this scope; a fresh row's zero
            // stamp never matches it, so the first write is always undone by
            // `discard` and never by a scope checkpoint. The root is issued
            // too, so original capture is one compare on every path.
            self.openRoot();
            self.accepted_len = .{
                .block_changed_accounts = @intCast(self.block_changed_accounts.items.len),
                .block_storage_wipes = @intCast(self.block_storage_wipes.items.len),
                .dirty_storage = @intCast(self.dirty_storage.items.len),
                .block_introduced_codes = @intCast(self.block_introduced_codes.items.len),
            };
            self.changed_accounts.clearRetainingCapacity();
            self.changed_storage.clearRetainingCapacity();
            self.transaction_storage_wipes.clearRetainingCapacity();
            std.debug.assert(self.lifecycle_accounts.items.len == 0);
            self.observed_accounts.clearRetainingCapacity();
            self.observed_storage.clearRetainingCapacity();
            self.logs.clearRetainingCapacity();
            self.retained_logs.clearRetainingCapacity();
            std.debug.assert(self.transient_storage.count() == 0);
            return self.lifetime.transaction;
        }

        /// Open an execution root and establish a fresh execution-original lifetime.
        /// Asserts a mutable attempt with no open scope. Earlier attempt writes
        /// remain outside this root's checkpoints.
        pub fn beginScope(self: *State) void {
            self.assertMutable();
            std.debug.assert(self.scope_depth == 0);
            self.openRoot();
            self.scope_depth = 1;
        }

        /// Close the execution root without reverting writes or ending the attempt.
        /// Asserts the root is active with no nested checkpoints. Subsequent writes
        /// use a fresh journaling scope and execution-original lifetime.
        pub fn closeScope(self: *State) void {
            self.assertRootScope();
            self.openRoot();
            self.scope_depth = 0;
        }

        /// Clear EIP-1153 state at a custom transaction root boundary while retaining
        /// transaction-scoped warmth, logs, and the surrounding rollback journal.
        /// The clear may occur inside an outer checkpoint and is not journaled: rollback
        /// must not resurrect transient values whose root lifetime has ended.
        pub fn clearTransientStorage(self: *State) void {
            self.assertTransaction();
            self.transient_storage.clearRetainingCapacity();
        }

        pub fn scopeActive(self: *const State) bool {
            return self.scope_depth != 0;
        }

        /// True while a nested checkpoint is open inside the scope root.
        pub fn hasOpenCheckpoint(self: *const State) bool {
            return self.scope_depth > 1;
        }

        /// Open a nested rollback scope. Asserts an active attempt and scope.
        /// Commit or revert the returned checkpoint in LIFO order on this State,
        /// within the same attempt. Block dirty lists use undo-restored row flags
        /// and retain-time compaction rather than saved lengths.
        pub fn checkpoint(self: *State) Checkpoint {
            self.assertTransaction();
            std.debug.assert(self.scope_depth != std.math.maxInt(u32));
            const parent = self.lifetime.scope;
            const scope = self.tick(.scope);
            self.scope_depth += 1;
            self.lifetime.scope = scope;
            return .{
                .scope = scope,
                .parent_scope = parent,
                .journal_len = @intCast(self.journal.entries.items.len),
                .changed_accounts_len = @intCast(self.changed_accounts.items.len),
                .changed_storage_len = @intCast(self.changed_storage.items.len),
                .logs = self.logs.checkpoint(),
            };
        }

        /// Close the active checkpoint while retaining its writes and undo records
        /// for any enclosing rollback. Asserts that this checkpoint is current.
        pub fn commitCheckpoint(self: *State, checkpoint_state: Checkpoint) void {
            self.assertCheckpoint(checkpoint_state);
            self.lifetime.scope = checkpoint_state.parent_scope;
            self.scope_depth -= 1;
        }

        /// Undo and close the active checkpoint, restoring its parent scope.
        /// Asserts that this checkpoint is current. Recorded reads survive;
        /// values, effects, and introduced warmth unwind through the journal.
        /// Block dirty lists retain stale entries until retain-time compaction.
        pub fn revertToCheckpoint(self: *State, checkpoint_state: Checkpoint) void {
            self.assertCheckpoint(checkpoint_state);
            self.transaction_scope_reverted = true;
            self.revertJournalTo(checkpoint_state.journal_len);
            self.changed_accounts.items.len = checkpoint_state.changed_accounts_len;
            self.changed_storage.items.len = checkpoint_state.changed_storage_len;
            self.logs.truncate(checkpoint_state.logs);
            self.lifetime.scope = checkpoint_state.parent_scope;
            self.scope_depth -= 1;
        }

        /// Freeze the current attempt for pending-view access without accepting it.
        /// Asserts a matching attempt generation, an unsealed attempt, and no open scope.
        /// The sealed attempt must still be retained or discarded.
        pub fn seal(self: *State, attempt: Generation(.transaction)) void {
            self.assertCurrent(attempt);
            std.debug.assert(!self.sealed);
            std.debug.assert(!self.scopeActive());
            self.compactTransactionStorageChanges();
            if (self.transaction_scope_reverted) self.compactTransactionStorageWipes();
            self.sealed = true;
            self.attempt_open = false;
        }

        /// Accept the current attempt's values, retain its logs, and end it.
        /// Release transaction observations and undo records.
        /// Asserts a matching attempt generation, a sealed attempt, and no open scope.
        pub fn retain(self: *State, attempt: Generation(.transaction)) void {
            self.assertCurrent(attempt);
            std.debug.assert(self.sealed);
            std.debug.assert(!self.scopeActive());
            std.mem.swap(LogBuffer, &self.logs, &self.retained_logs);
            if (self.transaction_scope_reverted) self.compactAcceptedAccountChanges();
            if (self.transaction_scope_reverted) self.compactAcceptedStorageWipes();
            if (self.transaction_scope_reverted or self.transaction_storage_wipes.items.len != 0)
                self.compactAcceptedStorageChanges();
            self.finishTransaction();
        }

        /// Undo the entire attempt, including writes before its execution root.
        /// Release its logs and observations. Asserts a matching attempt generation
        /// and no open scope; sealing is not required.
        pub fn discard(self: *State, attempt: Generation(.transaction)) void {
            self.assertCurrent(attempt);
            std.debug.assert(!self.scopeActive());
            self.revertJournalTo(0);
            self.block_changed_accounts.items.len = self.accepted_len.block_changed_accounts;
            self.block_storage_wipes.items.len = self.accepted_len.block_storage_wipes;
            self.dirty_storage.items.len = self.accepted_len.dirty_storage;
            self.block_introduced_codes.items.len = self.accepted_len.block_introduced_codes;
            self.finishTransaction();
        }

        /// Allocate a snapshot of the accepted branch. Asserts no active attempt.
        /// The caller owns the snapshot and must deinitialize it after use.
        pub fn branchSnapshot(self: *State) Allocator.Error!BranchSnapshot {
            std.debug.assert(!self.transaction_active);
            var rows = try self.world.captureSnapshot(self.allocator);
            errdefer rows.deinit(self.allocator);
            const block_changed_accounts = try self.allocator.dupe(AccountId, self.block_changed_accounts.items);
            errdefer self.allocator.free(block_changed_accounts);
            const block_storage_wipes = try self.allocator.dupe(AccountId, self.block_storage_wipes.items);
            errdefer self.allocator.free(block_storage_wipes);
            const dirty_storage = try self.allocator.dupe(StorageId, self.dirty_storage.items);
            errdefer self.allocator.free(dirty_storage);
            return .{
                .owner = self,
                .allocator = self.allocator,
                .rows = rows,
                .retained_logs = try self.retained_logs.clone(self.allocator),
                .block_changed_accounts = block_changed_accounts,
                .block_storage_wipes = block_storage_wipes,
                .dirty_storage = dirty_storage,
                .block_introduced_codes_len = @intCast(self.block_introduced_codes.items.len),
                .introduced_code_len = @intCast(self.code.introducedLen()),
                .world_epoch = self.world_epoch,
            };
        }

        /// Restore an unresolved snapshot without allocation. Asserts the same
        /// owner and epoch. If an attempt is active, its scope must be closed;
        /// that attempt is discarded first. Marks the snapshot resolved without
        /// freeing it. The generation clock remains advanced.
        pub fn restoreBranch(self: *State, snapshot: *BranchSnapshot) void {
            std.debug.assert(snapshot.owner == self);
            std.debug.assert(snapshot.world_epoch == self.world_epoch);
            std.debug.assert(!snapshot.resolved);
            if (self.transaction_active) self.discard(self.lifetime.transaction);
            self.world.restoreSnapshot(&snapshot.rows);
            self.block_changed_accounts.clearRetainingCapacity();
            self.block_changed_accounts.appendSliceAssumeCapacity(snapshot.block_changed_accounts);
            self.block_storage_wipes.clearRetainingCapacity();
            self.block_storage_wipes.appendSliceAssumeCapacity(snapshot.block_storage_wipes);
            self.dirty_storage.clearRetainingCapacity();
            self.dirty_storage.appendSliceAssumeCapacity(snapshot.dirty_storage);
            self.block_introduced_codes.items.len = snapshot.block_introduced_codes_len;
            self.code.truncateIntroduced(self.allocator, snapshot.introduced_code_len);
            std.mem.swap(LogBuffer, &self.retained_logs, &snapshot.retained_logs);
            snapshot.resolved = true;
        }

        pub fn acceptedView(self: *const State) AcceptedView {
            std.debug.assert(!self.transaction_active);
            return .{ .state = self };
        }

        /// Every accessor asserts the sealed transaction itself; the view is only a
        /// handle.
        pub fn pendingView(self: *const State) PendingView {
            return .{ .state = self };
        }

        pub fn logView(self: *const State) LogView {
            return if (self.transaction_active) self.logs.view() else self.retained_logs.view();
        }

        /// Return a materialized row without creating an execution observation.
        pub fn getAccount(self: *State, address: AccountKey) ?Account {
            const id = self.world.findAccount(address) orelse return null;
            return self.world.accountRow(id).current;
        }

        pub fn getAccountOrLoad(self: *State, address: AccountKey) !?Account {
            return self.readAccount(address, .{ .accessed = true, .value_read = true });
        }

        pub fn accountExists(self: *State, address: AccountKey) !bool {
            return (try self.readAccount(address, .{ .accessed = true, .existence_read = true })) != null;
        }

        pub fn getBalance(self: *State, address: AccountKey) !u256 {
            const account = (try self.readAccount(address, .{ .accessed = true, .value_read = true })) orelse
                return 0;
            return account.balance;
        }

        pub fn getNonce(self: *State, address: AccountKey) !u64 {
            const account = (try self.readAccount(address, .{ .accessed = true, .value_read = true })) orelse
                return 0;
            return account.nonce;
        }

        pub fn getCodeView(self: *State, address: AccountKey) !CodeView {
            const id = (try self.world.resolveAccount(address, .required_observed)).?;
            if (self.attemptOpen())
                try self.observeAccount(id, .{ .accessed = true, .code_read = true });
            const row = self.world.accountRow(id);
            return self.code.view(row.code_ref) orelse try self.bindCode(row);
        }

        /// A row whose reference is still unresolved. Parent code held by the
        /// store binds into the row, so the next fetch is a direct index; code
        /// found by hash anywhere else is returned unbound, because an
        /// introduced reference is only as durable as the scope that made it
        /// and the world's own cache is content-addressed already.
        noinline fn bindCode(self: *State, row: *AccountRow) !CodeView {
            const code_hash = accountCodeHash(row.current);
            if (self.code.bindParent(code_hash)) |ref| {
                row.code_ref = ref;
                return self.code.view(ref).?;
            }
            const view = self.world.cachedCode(code_hash) orelse
                self.code.lookup(code_hash) orelse
                try self.world.loadCode(code_hash);
            std.debug.assert(std.mem.eql(u8, &view.code_hash, &code_hash));
            return view;
        }

        pub fn getCode(self: *State, address: AccountKey) ![]const u8 {
            return (try self.getCodeView(address)).bytes;
        }

        pub fn getCodeHash(self: *State, address: AccountKey) !u256 {
            const account = (try self.readAccount(address, .{ .accessed = true, .value_read = true })) orelse
                return 0;
            return std.mem.readInt(u256, &account.code_hash, .big);
        }

        pub fn accountHasCode(self: *State, address: AccountKey) !bool {
            const account = (try self.readAccount(address, .{ .accessed = true, .value_read = true })) orelse
                return false;
            return !std.mem.eql(u8, &account.code_hash, &crypto.keccak256_empty);
        }

        pub fn setBalance(self: *State, address: AccountKey, balance: u256) !void {
            const id = (try self.world.resolveAccount(address, .required_observed)).?;
            const current = self.world.accountRow(id).current;
            var account = current orelse Account{};
            if (current != null and account.balance == balance) return;
            account.balance = balance;
            try self.writeAccount(id, account);
        }

        pub fn addBalance(self: *State, address: AccountKey, value: u256) !void {
            if (value == 0) return;
            const balance = try self.getBalance(address);
            try self.setBalance(
                address,
                std.math.add(u256, balance, value) catch return error.BalanceOverflow,
            );
        }

        pub fn subtractBalance(self: *State, address: AccountKey, value: u256) !bool {
            if (value == 0) return true;
            const balance = try self.getBalance(address);
            if (balance < value) return false;
            try self.setBalance(address, balance - value);
            return true;
        }

        pub fn setNonce(self: *State, address: AccountKey, nonce: u64) !void {
            const id = (try self.world.resolveAccount(address, .required_observed)).?;
            const current = self.world.accountRow(id).current;
            var account = current orelse Account{};
            if (current != null and account.nonce == nonce) return;
            account.nonce = nonce;
            try self.writeAccount(id, account);
        }

        pub fn setCode(self: *State, address: AccountKey, code_bytes: []const u8) !void {
            const id = (try self.world.resolveAccount(address, .required_observed)).?;
            try self.observeAccount(id, .{
                .accessed = true,
                .semantic_access = true,
                .value_read = true,
            });
            // Code the world already holds is parent code, not an introduction:
            // the row binds lazily through the world's cache like any parent row.
            const introduced_len = self.code.introducedLen();
            const cached: CodeStore.CacheResult = if (self.worldParentCode(code_bytes)) |view| .{
                .view = view,
                .ref = .missing,
                .newly_introduced = null,
            } else try self.code.cacheIntroduced(self.allocator, code_bytes);
            errdefer self.code.truncateIntroduced(self.allocator, introduced_len);
            if (cached.newly_introduced != null) {
                try reserve(&self.block_introduced_codes, self.allocator, 1);
                // Two entries: prepareAccountMutation may consume one for its undo.
                try reserve(&self.journal.entries, self.allocator, 2);
            }
            const row = try self.prepareAccountMutation(id);
            const previous = row.current;
            var account = previous orelse Account{};
            if (cached.newly_introduced) |introduced| {
                self.block_introduced_codes.appendAssumeCapacity(introduced);
                self.journal.entries.appendAssumeCapacity(.introduced_code);
            }
            account.code_hash = cached.view.code_hash;
            row.current = account;
            row.code_ref = cached.ref;
            recordAccountEffect(&self.observed_accounts.items[row.observation.index], previous, row.current);
        }

        fn worldParentCode(self: *const State, code_bytes: []const u8) ?CodeView {
            if (comptime !options.caches_parent_code) return null;
            if (code_bytes.len == 0) return null;
            const view = self.world.cachedCode(crypto.keccak256(code_bytes)) orelse return null;
            std.debug.assert(std.mem.eql(u8, view.bytes, code_bytes));
            return view;
        }

        pub fn clearCode(self: *State, address: AccountKey) !void {
            try self.setCode(address, &.{});
        }

        pub fn touchAccount(self: *State, address: AccountKey) !void {
            const id = (try self.world.resolveAccount(address, .required_observed)).?;
            try self.observeAccount(id, .{ .accessed = true });
            if (self.world.accountRow(id).flags.touched) return;
            const row = try self.prepareAccountMutation(id);
            if (row.current == null) row.current = .{};
            row.flags.touched = true;
        }

        pub fn accessAccount(self: *State, address: AccountKey) !execution.AccessStatus {
            const id = (try self.world.resolveAccount(address, .required_observed)).?;
            try self.observeAccount(id, .{ .accessed = true, .semantic_access = true });
            return if (try self.warmAccountId(id)) .cold else .warm;
        }

        /// Record an account access after instruction gas/admission has succeeded.
        /// This does not alter warmth.
        pub fn observeAccountAccess(self: *State, address: AccountKey) !void {
            const id = (try self.world.resolveAccount(address, .required_observed)).?;
            try self.observeAccount(id, .{ .accessed = true, .semantic_access = true });
        }

        pub fn warmAccount(self: *State, address: AccountKey) !void {
            _ = try self.warmAccountAddress(address, .optional_warm_only);
        }

        pub fn isAccountWarm(self: *State, address: AccountKey) bool {
            const id = self.world.findAccount(address) orelse return self.deferredAccountWarm(address);
            return self.accountWarm(id);
        }

        pub fn warmAccountAddress(self: *State, address: AccountKey, policy: ResolutionPolicy) !?bool {
            const id = (try self.world.resolveAccount(address, policy)) orelse {
                if (comptime options.grows_on_touch) return try self.deferAccountWarm(address);
                return null;
            };
            return try self.warmAccountId(id);
        }

        pub fn warmStorageSlot(self: *State, account: AccountId, key: u256, policy: ResolutionPolicy) !?bool {
            const id = (try self.world.resolveStorage(account, key, policy)) orelse {
                if (comptime options.grows_on_touch)
                    return try self.deferStorageWarm(.fromAddress(self.world.accountAddress(account)), key);
                return null;
            };
            return try self.warmStorageId(id);
        }

        pub fn warmAccountId(self: *State, id: AccountId) !bool {
            self.assertTransaction();
            const row = self.world.accountRow(id);
            if (row.warm_transaction == self.lifetime.transaction) return false;
            const was_warm = self.deferredAccountWarm(.fromAddress(self.world.accountAddress(id)));
            try self.journal.ensureWarm(self.allocator);
            self.journal.entries.appendAssumeCapacity(.{ .warm_account = id });
            row.warm_transaction = self.lifetime.transaction;
            return !was_warm;
        }

        pub fn warmStorageId(self: *State, id: StorageId) !bool {
            self.assertTransaction();
            const row = self.world.storageRow(id);
            if (row.warm_transaction == self.lifetime.transaction) return false;
            const was_warm = self.deferredStorageWarm(
                .fromAddress(self.world.accountAddress(self.world.storageAccount(id))),
                self.world.storageSlot(id),
            );
            try self.journal.ensureWarm(self.allocator);
            self.journal.entries.appendAssumeCapacity(.{ .warm_storage = id });
            row.warm_transaction = self.lifetime.transaction;
            return !was_warm;
        }

        pub fn accountWarm(self: *const State, id: AccountId) bool {
            return self.world.accountRow(id).warm_transaction == self.lifetime.transaction or
                self.deferredAccountWarm(.fromAddress(self.world.accountAddress(id)));
        }

        pub fn storageWarm(self: *const State, id: StorageId) bool {
            return self.world.storageRow(id).warm_transaction == self.lifetime.transaction or
                self.deferredStorageWarm(
                    .fromAddress(self.world.accountAddress(self.world.storageAccount(id))),
                    self.world.storageSlot(id),
                );
        }

        pub fn getStorage(self: *State, address: AccountKey, key: u256) !u256 {
            const resolved = (try self.resolveStorageKey(address, key, .required_observed)).?;
            if (!self.attemptOpen()) return self.resolvedValue(resolved);
            try self.observeAccount(resolved.account, .{ .accessed = true });
            return self.readResolvedStorage(resolved);
        }

        pub fn accessStorage(self: *State, address: AccountKey, key: u256) !execution.AccessStatus {
            const was_cold = (try self.warmStorageAddress(address, key)) orelse return .cold;
            return if (was_cold) .cold else .warm;
        }

        pub fn loadStorage(self: *State, address: AccountKey, key: u256) !Host.StorageLoadResult {
            const resolved = (try self.resolveStorageKey(address, key, .required_observed)).?;
            try self.observeAccount(resolved.account, .{ .accessed = true });
            const access_status = try self.accessResolvedStorage(resolved);
            return .{
                .value = try self.readResolvedStorage(resolved),
                .access_status = access_status,
            };
        }

        pub fn setStorage(self: *State, address: AccountKey, key: u256, value: u256) !execution.StorageStatus {
            const resolved = (try self.resolveStorageKey(address, key, .required_observed)).?;
            try self.observeAccount(resolved.account, .{ .accessed = true });
            return self.setResolvedStorage(resolved, value);
        }

        pub fn storeStorage(self: *State, address: AccountKey, key: u256, value: u256) !Host.StorageStoreResult {
            const resolved = (try self.resolveStorageKey(address, key, .required_observed)).?;
            try self.observeAccount(resolved.account, .{ .accessed = true });
            const access_status = try self.accessResolvedStorage(resolved);
            return .{
                .storage_status = try self.setResolvedStorage(resolved, value),
                .access_status = access_status,
            };
        }

        pub fn originalStorage(self: *State, address: AccountKey, key: u256) !u256 {
            const resolved = (try self.resolveStorageKey(address, key, .required_observed)).?;
            try self.observeAccount(resolved.account, .{ .accessed = true });
            try self.observeStorage(resolved, .{ .accessed = true, .value_read = true });
            const row = self.world.storageRow(resolved.storage);
            self.captureExecutionOriginal(row, self.resolvedValue(resolved));
            return row.execution_original;
        }

        pub fn warmStorage(self: *State, address: AccountKey, key: u256) !void {
            _ = try self.warmStorageAddress(address, key);
        }

        pub fn isStorageWarm(self: *State, address: AccountKey, key: u256) bool {
            const account = self.world.findAccount(address) orelse return self.deferredStorageWarm(address, key);
            const id = self.world.findStorage(account, key) orelse return self.deferredStorageWarm(address, key);
            return self.storageWarm(id);
        }

        fn warmStorageAddress(self: *State, address: AccountKey, key: u256) !?bool {
            const account = (try self.world.resolveAccount(address, .optional_warm_only)) orelse {
                if (comptime options.grows_on_touch) return try self.deferStorageWarm(address, key);
                return null;
            };
            return self.warmStorageSlot(account, key, .optional_warm_only);
        }

        fn deferredAccountWarm(self: *const State, address: AccountKey) bool {
            if (comptime !options.grows_on_touch) return false;
            return self.deferred_warmth.accounts.get(address) orelse false;
        }

        fn deferredStorageWarm(self: *const State, address: AccountKey, key: u256) bool {
            if (comptime !options.grows_on_touch) return false;
            return self.deferred_warmth.storage.get(.init(address, key)) orelse false;
        }

        fn deferAccountWarm(self: *State, address: AccountKey) !bool {
            self.assertTransaction();
            if (self.deferredAccountWarm(address)) return false;
            try self.journal.ensureWarm(self.allocator);
            const entry = try self.deferred_warmth.accounts.getOrPut(address);
            entry.value_ptr.* = true;
            self.journal.entries.appendAssumeCapacity(.{ .deferred_warm_account = entry.entry_id });
            return true;
        }

        fn deferStorageWarm(self: *State, address: AccountKey, key: u256) !bool {
            self.assertTransaction();
            if (self.deferredStorageWarm(address, key)) return false;
            try self.journal.ensureWarm(self.allocator);
            const entry = try self.deferred_warmth.storage.getOrPut(.init(address, key));
            entry.value_ptr.* = true;
            self.journal.entries.appendAssumeCapacity(.{ .deferred_warm_storage = entry.entry_id });
            return true;
        }

        pub fn getTransientStorage(self: *State, address: AccountKey, key: u256) u256 {
            self.assertTransaction();
            return self.transient_storage.get(.init(address, key)) orelse 0;
        }

        pub fn setTransientStorage(self: *State, address: AccountKey, key: u256, value: u256) !void {
            self.assertTransaction();
            const storage_key = TransientKey.init(address, key);
            const previous_entry = self.transient_storage.get(storage_key);
            const previous = previous_entry orelse 0;
            if (previous == value) return;
            if (previous_entry == null) try self.transient_storage.ensureUnusedCapacity(1);
            try self.journal.appendTransient(self.allocator, .{
                .key = storage_key,
                .previous = previous,
            });
            // Zero is transient storage's semantic absence. Retain the row until the
            // transaction-wide clear so checkpoint rollback never repairs probe clusters.
            self.transient_storage.putAssumeCapacity(storage_key, value);
        }

        pub fn emitLog(self: *State, event_log: Host.Log) !void {
            self.assertTransaction();
            try self.logs.append(self.allocator, event_log);
        }

        pub fn clearLogs(self: *State) void {
            const logs = if (self.transaction_active) &self.logs else &self.retained_logs;
            logs.clearRetainingCapacity();
        }

        pub fn markCreatedContract(self: *State, address: AccountKey) !void {
            const id = (try self.world.resolveAccount(address, .required_observed)).?;
            if (self.world.accountRow(id).flags.created) return;
            try self.markCreatedId(id);
        }

        pub fn markSelfdestructed(self: *State, address: AccountKey) !void {
            const id = (try self.world.resolveAccount(address, .required_observed)).?;
            if (self.world.accountRow(id).flags.selfdestructed) return;
            try self.markSelfdestructedId(id);
        }

        pub fn markCreatedId(self: *State, id: AccountId) !void {
            try self.observeAccount(id, .{ .accessed = true, .semantic_access = true });
            const row = try self.prepareLifecycleMutation(id);
            row.flags.created = true;
            self.observed_accounts.items[row.observation.index].effect.created_contract = true;
        }

        pub fn markSelfdestructedId(self: *State, id: AccountId) !void {
            try self.observeAccount(id, .{ .accessed = true, .semantic_access = true });
            const row = try self.prepareLifecycleMutation(id);
            row.flags.selfdestructed = true;
            self.observed_accounts.items[row.observation.index].effect.selfdestruct = true;
        }

        pub fn createdInTransaction(self: *State, address: AccountKey) bool {
            const id = self.world.findAccount(address) orelse return false;
            return self.transaction_active and self.world.accountRow(id).flags.created;
        }

        pub fn wasSelfdestructed(self: *State, address: AccountKey) bool {
            const id = self.world.findAccount(address) orelse return false;
            return self.transaction_active and self.world.accountRow(id).flags.selfdestructed;
        }

        /// Settle every lifecycle-listed row. The pass runs under its own
        /// checkpoint so that an allocation failure part-way leaves the
        /// enclosing scope exactly as it was.
        pub fn finalize(self: *State, rules: FinalizationRules) Allocator.Error!void {
            self.assertTransaction();
            if (self.lifecycle_accounts.items.len == 0) return;
            const checkpoint_state = self.checkpoint();
            errdefer self.revertToCheckpoint(checkpoint_state);
            for (self.lifecycle_accounts.items) |id| {
                const flags = self.world.accountRow(id).flags;
                if (!flags.created and !flags.selfdestructed) continue;
                if (!flags.selfdestructed) {
                    const row = try self.prepareAccountMutation(id);
                    row.flags.created = false;
                    continue;
                }

                const policy = if (flags.created)
                    rules.created_account
                else
                    rules.existing_account;
                if (policy.clear_storage) try self.wipeStorage(id);
                if (policy.reset_account) {
                    var account = self.world.accountRow(id).current orelse Account{};
                    account.nonce = 0;
                    account.code_hash = crypto.keccak256_empty;
                    // A reset account holding no balance is EIP-161 empty: drop the leaf
                    // instead of keeping a zero account the state root would not carry.
                    try self.writeAccount(id, if (account.balance == 0) null else account);
                } else if (policy.delete_account) {
                    try self.writeAccount(id, null);
                }
                const row = try self.prepareAccountMutation(id);
                row.flags.created = false;
                row.flags.selfdestructed = false;
            }
            self.commitCheckpoint(checkpoint_state);
        }

        /// Reset rows to parent state and release accepted changes and introduced
        /// code. Asserts no active attempt. Advances `world_epoch`, invalidating
        /// branch snapshots, and resets the generation clock. Attempt ids and
        /// checkpoints must not be reused across this boundary; they carry no epoch.
        pub fn discardAccepted(self: *State) void {
            std.debug.assert(!self.transaction_active);
            self.code.truncateIntroduced(self.allocator, 0);
            self.world.resetRows();
            self.block_changed_accounts.clearRetainingCapacity();
            self.block_storage_wipes.clearRetainingCapacity();
            self.dirty_storage.clearRetainingCapacity();
            self.block_introduced_codes.clearRetainingCapacity();
            self.retained_logs.clearRetainingCapacity();
            self.world_epoch += 1;
            // Reset rows carry only initial stamps, so the clock may restart.
            self.clock = 0;
        }

        pub fn journalEntryCount(self: *const State) usize {
            return self.journal.entries.items.len;
        }

        pub fn allocationBytes(self: *const State) usize {
            return self.world.allocationBytes() +
                (if (options.grows_on_touch) self.deferred_warmth.allocationBytes() else 0) +
                self.code.allocationBytes() +
                self.transient_storage.allocationBytes() +
                self.logs.allocationBytes() +
                self.retained_logs.allocationBytes() +
                self.block_changed_accounts.capacity * @sizeOf(AccountId) +
                self.block_storage_wipes.capacity * @sizeOf(AccountId) +
                self.dirty_storage.capacity * @sizeOf(StorageId) +
                self.changed_accounts.capacity * @sizeOf(AccountId) +
                self.changed_storage.capacity * @sizeOf(StorageId) +
                self.transaction_storage_wipes.capacity * @sizeOf(AccountId) +
                self.lifecycle_accounts.capacity * @sizeOf(AccountId) +
                self.block_introduced_codes.capacity * @sizeOf(artifacts.IntroducedCodeId) +
                self.observed_accounts.capacity * @sizeOf(AccountObservationRow) +
                self.observed_storage.capacity * @sizeOf(StorageObservationRow) +
                self.journal.entries.capacity * @sizeOf(Journal.Entry) +
                self.journal.accounts.capacity * @sizeOf(Journal.AccountUndo) +
                self.journal.storage.capacity * @sizeOf(Journal.StorageUndo) +
                self.journal.transient.capacity * @sizeOf(Journal.TransientUndo);
        }

        /// Hide all parent and prior-block storage without fabricating slot accesses.
        pub fn wipeStorage(self: *State, id: AccountId) Allocator.Error!void {
            try self.observeAccount(id, .{ .accessed = true, .semantic_access = true });
            const original = self.world.accountRow(id);
            const first_block_wipe = !original.flags.storage_wiped;
            const first_transaction_wipe = original.wiped_transaction !=
                self.lifetime.transaction;
            if (first_block_wipe) try reserve(&self.block_storage_wipes, self.allocator, 1);
            if (first_transaction_wipe) try reserve(&self.transaction_storage_wipes, self.allocator, 1);
            const row = try self.prepareAccountMutation(id);
            if (first_block_wipe) self.block_storage_wipes.appendAssumeCapacity(id);
            if (first_transaction_wipe) self.transaction_storage_wipes.appendAssumeCapacity(id);
            row.flags.storage_dirty = true;
            row.flags.storage_wiped = true;
            row.storage_incarnation = row.storage_incarnation.next();
            row.wiped_transaction = self.lifetime.transaction;
            self.observed_accounts.items[row.observation.index].effect.storage_wiped = true;
        }

        pub fn writeAccount(self: *State, id: AccountId, value: ?Account) !void {
            self.assertMutable();
            try self.observeAccount(id, .{
                .accessed = true,
                .semantic_access = true,
                .value_read = true,
            });
            const row = try self.prepareAccountMutation(id);
            const previous = row.current;
            const previous_hash = accountCodeHash(previous);
            const current_hash = accountCodeHash(value);
            if (!std.mem.eql(u8, &previous_hash, &current_hash)) {
                row.code_ref = self.code.bind(current_hash);
            }
            row.current = value;
            recordAccountEffect(&self.observed_accounts.items[row.observation.index], previous, value);
        }

        pub fn writeStorage(self: *State, id: StorageId, value: u256) !void {
            self.assertMutable();
            const resolved: ResolvedStorage = .{ .account = self.world.storageAccount(id), .storage = id };
            try self.observeAccount(resolved.account, .{ .accessed = true });
            try self.observeStorage(resolved, .{ .accessed = true, .value_read = true });
            self.captureExecutionOriginal(self.world.storageRow(id), self.resolvedValue(resolved));
            try self.writeResolvedStorage(resolved, value);
        }

        /// Journal, list, and write the slot. Asserts the slot was observed
        /// in this transaction. A full account undo in this scope already
        /// covers its flags; otherwise journal the storage-dirty transition.
        fn writeResolvedStorage(self: *State, resolved: ResolvedStorage, value: u256) Allocator.Error!void {
            const account_row = self.world.accountRow(resolved.account);
            const row = self.world.storageRow(resolved.storage);
            std.debug.assert(row.observation.transaction == self.lifetime.transaction);
            const needs_undo = row.journaled_scope != self.lifetime.scope;
            const first_dirty = !row.flags.block_dirty;
            const first_transaction_write = row.transaction_undo.transaction != self.lifetime.transaction;
            const needs_account_flag_undo = !account_row.flags.storage_dirty and
                account_row.journaled_scope != self.lifetime.scope;

            if (needs_undo)
                try self.journal.ensureStorage(self.allocator)
            else if (needs_account_flag_undo)
                try reserve(&self.journal.entries, self.allocator, 1);
            if (first_dirty) try reserve(&self.dirty_storage, self.allocator, 1);
            if (first_transaction_write) try reserve(&self.changed_storage, self.allocator, 1);

            if (needs_undo) self.appendStorageUndo(resolved.storage, row);
            if (needs_account_flag_undo)
                self.journal.entries.appendAssumeCapacity(.{ .account_storage_dirty = resolved.account });
            account_row.flags.storage_dirty = true;
            if (first_dirty) {
                row.flags.block_dirty = true;
                self.dirty_storage.appendAssumeCapacity(resolved.storage);
            }
            if (first_transaction_write) self.changed_storage.appendAssumeCapacity(resolved.storage);
            row.current = value;
            row.storage_incarnation = account_row.storage_incarnation;
            self.observed_storage.items[row.observation.index].effect.written = true;
        }

        /// Merge `observation` into the row's observation, creating it on first touch
        /// in this transaction. Every attempt observes; there is no opt-out.
        pub fn observeAccount(self: *State, id: AccountId, observation: AccountObservation) !void {
            self.assertMutable();
            const row = self.world.accountRow(id);
            if (row.observation.transaction == self.lifetime.transaction) {
                self.observed_accounts.items[row.observation.index].observation.merge(observation);
                return;
            }
            return self.observeAccountFirst(id, row, observation);
        }

        noinline fn observeAccountFirst(
            self: *State,
            id: AccountId,
            row: *AccountRow,
            observation: AccountObservation,
        ) !void {
            try reserve(&self.observed_accounts, self.allocator, 1);
            row.observation = .{
                .transaction = self.lifetime.transaction,
                .index = @intCast(self.observed_accounts.items.len),
            };
            self.observed_accounts.appendAssumeCapacity(.{
                .account = id,
                .original = row.current,
                .original_storage_incarnation = row.storage_incarnation,
                .observation = observation,
            });
        }

        /// Merge `observation` into the slot's observation, creating it on first
        /// touch in this transaction. The first touch also fixes the EIP-2200
        /// transaction original, so every read and write observes first.
        fn observeStorage(self: *State, resolved: ResolvedStorage, observation: StorageObservation) !void {
            self.assertMutable();
            const row = self.world.storageRow(resolved.storage);
            if (row.observation.transaction == self.lifetime.transaction) {
                self.observed_storage.items[row.observation.index].observation.merge(observation);
                return;
            }
            return self.observeStorageFirst(resolved, row, observation);
        }

        noinline fn observeStorageFirst(
            self: *State,
            resolved: ResolvedStorage,
            row: *StorageRow,
            observation: StorageObservation,
        ) Allocator.Error!void {
            try reserve(&self.observed_storage, self.allocator, 1);
            const account = self.world.accountRow(resolved.account);
            const current = effectiveValue(account, row);
            row.observation = .{
                .transaction = self.lifetime.transaction,
                .index = @intCast(self.observed_storage.items.len),
            };
            self.observed_storage.appendAssumeCapacity(.{
                .storage = resolved.storage,
                // A wipe earlier in this transaction hides the value the
                // transaction started from; the row still holds it.
                .original = if (account.wiped_transaction == self.lifetime.transaction)
                    row.current
                else
                    current,
                .observation = observation,
            });
        }

        inline fn assertTransaction(self: *const State) void {
            self.assertAttempt();
            std.debug.assert(self.scope_depth != 0);
        }

        /// An open, unsealed attempt: what a write needs. A scope is only
        /// needed by what a scope owns (checkpoints, warmth, logs, transient).
        inline fn assertMutable(self: *const State) void {
            self.assertAttempt();
            std.debug.assert(!self.sealed);
            std.debug.assert(self.attempt_open);
        }

        fn attemptOpen(self: *const State) bool {
            std.debug.assert(self.attempt_open == (self.transaction_active and !self.sealed));
            return self.attempt_open;
        }

        inline fn assertAttempt(self: *const State) void {
            std.debug.assert(self.transaction_active);
        }

        inline fn assertRootScope(self: *const State) void {
            self.assertTransaction();
            std.debug.assert(self.scope_depth == 1);
        }

        inline fn assertSealed(self: *const State) void {
            std.debug.assert(self.transaction_active);
            std.debug.assert(self.sealed);
            std.debug.assert(!self.scopeActive());
        }

        inline fn assertCurrent(self: *const State, attempt: Generation(.transaction)) void {
            self.assertAttempt();
            std.debug.assert(self.lifetime.transaction == attempt);
        }

        inline fn assertCheckpoint(self: *const State, checkpoint_state: Checkpoint) void {
            self.assertTransaction();
            std.debug.assert(self.scope_depth >= 1);
            std.debug.assert(checkpoint_state.scope == self.lifetime.scope);
            std.debug.assert(checkpoint_state.journal_len <= self.journal.entries.items.len);
            std.debug.assert(checkpoint_state.changed_accounts_len <= self.changed_accounts.items.len);
            std.debug.assert(checkpoint_state.changed_storage_len <= self.changed_storage.items.len);
            std.debug.assert(checkpoint_state.logs.rows_len <= self.logs.rows.items.len);
            std.debug.assert(checkpoint_state.logs.topics_len <= self.logs.topics.items.len);
            std.debug.assert(checkpoint_state.logs.data_len <= self.logs.data.items.len);
        }

        fn finishTransaction(self: *State) void {
            if (comptime options.grows_on_touch) self.deferred_warmth.clearRetainingCapacity();
            self.transaction_scope_reverted = false;
            self.transient_storage.clearRetainingCapacity();
            self.changed_accounts.clearRetainingCapacity();
            self.changed_storage.clearRetainingCapacity();
            self.transaction_storage_wipes.clearRetainingCapacity();
            self.lifecycle_accounts.clearRetainingCapacity();
            self.observed_accounts.clearRetainingCapacity();
            self.observed_storage.clearRetainingCapacity();
            self.logs.clearRetainingCapacity();
            self.journal.clearRetainingCapacity();
            self.transaction_active = false;
            self.observed_attempt = false;
            self.sealed = false;
            self.attempt_open = false;
            self.lifetime.scope = .none;
            self.lifetime.root = .none;
            self.scope_depth = 0;
        }

        fn revertJournalTo(self: *State, target_len: u32) void {
            while (self.journal.entries.items.len > target_len) {
                const entry = self.journal.entries.pop().?;
                switch (entry) {
                    .account => |undo_id| {
                        std.debug.assert(@intFromEnum(undo_id) + 1 == self.journal.accounts.items.len);
                        const undo = self.journal.accounts.pop().?;
                        const row = self.world.accountRow(undo.account);
                        row.current = undo.current;
                        row.code_ref = undo.code_ref;
                        row.flags = undo.flags;
                        row.journaled_scope = undo.journaled_scope;
                        row.storage_incarnation = undo.storage_incarnation;
                        row.wiped_transaction = undo.wiped_transaction;
                        row.dirty_transaction = undo.dirty_transaction;
                        self.observed_accounts.items[row.observation.index].effect = undo.effect;
                    },
                    .storage => |undo_id| {
                        std.debug.assert(@intFromEnum(undo_id) + 1 == self.journal.storage.items.len);
                        const undo = self.journal.storage.pop().?;
                        const row = self.world.storageRow(undo.storage);
                        row.current = undo.current;
                        row.flags = undo.flags;
                        row.journaled_scope = undo.journaled_scope;
                        row.storage_incarnation = undo.storage_incarnation;
                        row.transaction_undo = undo.transaction_undo;
                        self.observed_storage.items[row.observation.index].effect = undo.effect;
                    },
                    .account_storage_dirty => |id| self.world.accountRow(id).flags.storage_dirty = false,
                    .warm_account => |id| self.world.accountRow(id).warm_transaction = .none,
                    .warm_storage => |id| self.world.storageRow(id).warm_transaction = .none,
                    .deferred_warm_account => |id| {
                        if (comptime options.grows_on_touch)
                            self.deferred_warmth.accounts.valuePtrById(id).* = false
                        else
                            unreachable;
                    },
                    .deferred_warm_storage => |id| {
                        if (comptime options.grows_on_touch)
                            self.deferred_warmth.storage.valuePtrById(id).* = false
                        else
                            unreachable;
                    },
                    .transient_storage => |undo_id| {
                        std.debug.assert(@intFromEnum(undo_id) + 1 == self.journal.transient.items.len);
                        const undo = self.journal.transient.pop().?;
                        self.transient_storage.putAssumeCapacity(undo.key, undo.previous);
                    },
                    .introduced_code => {
                        const block_id = self.block_introduced_codes.pop().?;
                        std.debug.assert(@intFromEnum(block_id) + 1 == self.code.introducedLen());
                        self.code.truncateIntroduced(self.allocator, @intFromEnum(block_id));
                    },
                }
            }
        }

        fn readAccount(self: *State, address: AccountKey, observation: AccountObservation) !?Account {
            const id = (try self.world.resolveAccount(address, .required_observed)).?;
            // Block-system-call admission may inspect code presence before opening the
            // managed system-call attempt. The actual call records the access.
            if (self.attemptOpen()) try self.observeAccount(id, observation);
            return self.world.accountRow(id).current;
        }

        fn resolveStorageKey(self: *State, address: AccountKey, key: u256, policy: ResolutionPolicy) !?ResolvedStorage {
            const account = (try self.world.resolveAccount(address, policy)) orelse return null;
            const storage = (try self.world.resolveStorage(account, key, policy)) orelse return null;
            return .{ .account = account, .storage = storage };
        }

        /// Account value as the accepted branch sees it: the first-touch original
        /// while a transaction is active, else the row.
        fn acceptedAccountValue(self: *const State, id: AccountId) ?Account {
            const row = self.world.accountRow(id);
            if (!self.transaction_active or
                row.dirty_transaction != self.lifetime.transaction) return row.current;
            std.debug.assert(row.observation.transaction == self.lifetime.transaction);
            return self.observed_accounts.items[row.observation.index].original;
        }

        /// Storage value as the accepted branch sees it, honoring a storage incarnation
        /// that the active transaction may have advanced.
        fn acceptedStorageValue(self: *const State, id: StorageId) u256 {
            if (!self.transaction_active) return self.effectiveStorage(id);
            const account = self.world.storageAccount(id);
            const account_row = self.world.accountRow(account);
            const account_incarnation = if (account_row.observation.transaction == self.lifetime.transaction)
                self.observed_accounts.items[account_row.observation.index].original_storage_incarnation
            else
                account_row.storage_incarnation;
            const row = self.world.storageRow(id);
            const changed = row.transaction_undo.transaction == self.lifetime.transaction;
            const value = if (changed)
                self.journal.storage.items[row.transaction_undo.index].current
            else
                row.current;
            const storage_incarnation = if (changed)
                self.journal.storage.items[row.transaction_undo.index].storage_incarnation
            else
                row.storage_incarnation;
            return if (storage_incarnation == account_incarnation) value else 0;
        }

        fn recordAccountEffect(observation: *AccountObservationRow, previous: ?Account, current: ?Account) void {
            const value = current orelse {
                observation.effect.account_deleted = previous != null;
                return;
            };
            if (previous) |old| {
                observation.effect.balance_written = observation.effect.balance_written or
                    old.balance != value.balance;
                observation.effect.nonce_written = observation.effect.nonce_written or
                    old.nonce != value.nonce;
                observation.effect.code_written = observation.effect.code_written or
                    !std.mem.eql(u8, &old.code_hash, &value.code_hash);
            } else {
                observation.effect.balance_written = value.balance != 0;
                observation.effect.nonce_written = value.nonce != 0;
                observation.effect.code_written = !std.mem.eql(
                    u8,
                    &value.code_hash,
                    &crypto.keccak256_empty,
                );
            }
        }

        fn accessResolvedStorage(self: *State, resolved: ResolvedStorage) !execution.AccessStatus {
            return if (try self.warmStorageId(resolved.storage)) .cold else .warm;
        }

        fn readResolvedStorage(self: *State, resolved: ResolvedStorage) !u256 {
            try self.observeStorage(resolved, .{ .accessed = true, .value_read = true });
            return self.resolvedValue(resolved);
        }

        fn setResolvedStorage(self: *State, resolved: ResolvedStorage, value: u256) !execution.StorageStatus {
            try self.observeStorage(resolved, .{ .accessed = true, .value_read = true });
            const row = self.world.storageRow(resolved.storage);
            const current = self.resolvedValue(resolved);
            self.captureExecutionOriginal(row, current);
            if (current == value) return .assigned;
            const status = storageStatus(row.execution_original, current, value);
            try self.writeResolvedStorage(resolved, value);
            return status;
        }

        fn captureExecutionOriginal(self: *State, row: *StorageRow, current: u256) void {
            if (row.execution_original_root == self.lifetime.root) return;
            std.debug.assert(self.lifetime.root != .none);
            row.execution_original = current;
            row.execution_original_root = self.lifetime.root;
        }

        pub fn effectiveStorage(self: *const State, id: StorageId) u256 {
            return self.resolvedValue(.{ .account = self.world.storageAccount(id), .storage = id });
        }

        fn resolvedValue(self: *const State, resolved: ResolvedStorage) u256 {
            return effectiveValue(self.world.accountRow(resolved.account), self.world.storageRow(resolved.storage));
        }

        /// The value execution sees: zero when the slot was written under an
        /// incarnation a wipe has since retired.
        inline fn effectiveValue(account: *const AccountRow, row: *const StorageRow) u256 {
            return if (row.storage_incarnation != account.storage_incarnation) 0 else row.current;
        }

        /// Reserve, journal, and list the row for its first change at every layer;
        /// the caller applies the change to the returned row. Asserts the row was
        /// observed in this transaction.
        fn prepareAccountMutation(self: *State, id: AccountId) Allocator.Error!*AccountRow {
            const row = self.world.accountRow(id);
            std.debug.assert(row.observation.transaction == self.lifetime.transaction);
            const needs_undo = row.journaled_scope != self.lifetime.scope;
            const first_block_change = !row.flags.block_changed;
            const first_transaction_dirty =
                row.dirty_transaction != self.lifetime.transaction;
            if (needs_undo) try self.journal.ensureAccount(self.allocator);
            if (first_block_change) try reserve(&self.block_changed_accounts, self.allocator, 1);
            if (first_transaction_dirty) try reserve(&self.changed_accounts, self.allocator, 1);
            if (needs_undo) self.appendAccountUndo(id, row);
            if (first_block_change) {
                row.flags.block_changed = true;
                self.block_changed_accounts.appendAssumeCapacity(id);
            }
            if (first_transaction_dirty) {
                row.dirty_transaction = self.lifetime.transaction;
                self.changed_accounts.appendAssumeCapacity(id);
            }
            return row;
        }

        /// Lifecycle marks are dirty changes here: the row is listed for `finalize`
        /// on top of the full `prepareAccountMutation` bookkeeping.
        fn prepareLifecycleMutation(self: *State, id: AccountId) Allocator.Error!*AccountRow {
            const row = self.world.accountRow(id);
            const first_lifecycle = row.lifecycle_transaction != self.lifetime.transaction;
            if (first_lifecycle) try reserve(&self.lifecycle_accounts, self.allocator, 1);
            const mutable = try self.prepareAccountMutation(id);
            if (first_lifecycle) {
                mutable.lifecycle_transaction = self.lifetime.transaction;
                self.lifecycle_accounts.appendAssumeCapacity(id);
            }
            return mutable;
        }

        /// Journal the row once per scope generation; the caller reserved capacity.
        fn appendAccountUndo(self: *State, id: AccountId, row: *AccountRow) void {
            self.journal.appendAccountAssumeCapacity(.{
                .account = id,
                .current = row.current,
                .code_ref = row.code_ref,
                .flags = row.flags,
                .journaled_scope = row.journaled_scope,
                .storage_incarnation = row.storage_incarnation,
                .wiped_transaction = row.wiped_transaction,
                .dirty_transaction = row.dirty_transaction,
                .effect = self.observed_accounts.items[row.observation.index].effect,
            });
            row.journaled_scope = self.lifetime.scope;
        }

        fn appendStorageUndo(self: *State, id: StorageId, row: *StorageRow) void {
            const undo_index: u32 = @intCast(self.journal.storage.items.len);
            self.journal.appendStorageAssumeCapacity(.{
                .storage = id,
                .current = row.current,
                .flags = row.flags,
                .journaled_scope = row.journaled_scope,
                .storage_incarnation = row.storage_incarnation,
                .transaction_undo = row.transaction_undo,
                .effect = self.observed_storage.items[row.observation.index].effect,
            });
            if (row.transaction_undo.transaction != self.lifetime.transaction) {
                row.transaction_undo = .{
                    .transaction = self.lifetime.transaction,
                    .index = undo_index,
                };
            }
            row.journaled_scope = self.lifetime.scope;
        }

        /// Advance the State clock and issue its value to `lifetime`. Asserts the
        /// clock is below `maxInt(u32)`; there is no wrap or reset policy here.
        fn tick(self: *State, comptime lifetime: Lifetime) Generation(lifetime) {
            self.clock += 1;
            return @enumFromInt(self.clock);
        }

        /// Open a scope that is also an execution root. One clock value serves
        /// both lifetimes; their types keep the stamps apart.
        fn openRoot(self: *State) void {
            self.lifetime.scope = self.tick(.scope);
            self.lifetime.root = @enumFromInt(@intFromEnum(self.lifetime.scope));
        }

        /// Drop slots whose incarnation a wipe left behind so the transaction delta
        /// carries only slots the retained branch will keep.
        fn compactTransactionStorageChanges(self: *State) void {
            var write: usize = 0;
            for (self.changed_storage.items) |id| {
                const row = self.world.storageRow(id);
                const account = self.world.accountRow(self.world.storageAccount(id));
                if (row.storage_incarnation != account.storage_incarnation) continue;
                self.changed_storage.items[write] = id;
                write += 1;
            }
            self.changed_storage.items.len = write;
        }

        fn compactTransactionStorageWipes(self: *State) void {
            var write: usize = 0;
            for (self.transaction_storage_wipes.items) |id| {
                const row = self.world.accountRow(id);
                if (row.wiped_transaction != self.lifetime.transaction) continue;
                row.wiped_transaction = .none;
                self.transaction_storage_wipes.items[write] = id;
                write += 1;
            }
            for (self.transaction_storage_wipes.items[0..write]) |id|
                self.world.accountRow(id).wiped_transaction =
                    self.lifetime.transaction;
            self.transaction_storage_wipes.items.len = write;
        }

        /// Drops wiped-away rows and entries orphaned by scope reverts (their flag is
        /// already false). Only scope reverts can create revert-then-redirty repeats;
        /// that path consumes each row's flag so only the first live occurrence
        /// survives, then restores the flag on the kept entries. Wipe-only compaction
        /// preserves unique membership and filters stale incarnations in one pass.
        fn compactAcceptedStorageChanges(self: *State) void {
            const deduplicate = self.transaction_scope_reverted;
            var write: usize = 0;
            for (self.dirty_storage.items) |id| {
                const row = self.world.storageRow(id);
                if (!row.flags.block_dirty) continue;
                if (deduplicate) row.flags.block_dirty = false;
                const account = self.world.accountRow(self.world.storageAccount(id));
                if (row.storage_incarnation != account.storage_incarnation) {
                    row.flags.block_dirty = false;
                    continue;
                }
                self.dirty_storage.items[write] = id;
                write += 1;
            }
            if (deduplicate) {
                for (self.dirty_storage.items[0..write]) |id|
                    self.world.storageRow(id).flags.block_dirty = true;
            }
            self.dirty_storage.items.len = write;
        }

        /// Stale-entry compaction for the block account change list: scope
        /// reverts leave flag-false entries behind instead of truncating, so retain
        /// filters and deduplicates them with the same consume-then-restore passes.
        fn compactAcceptedAccountChanges(self: *State) void {
            var changed_write: usize = 0;
            for (self.block_changed_accounts.items) |id| {
                const row = self.world.accountRow(id);
                if (!row.flags.block_changed) continue;
                row.flags.block_changed = false;
                self.block_changed_accounts.items[changed_write] = id;
                changed_write += 1;
            }
            for (self.block_changed_accounts.items[0..changed_write]) |id| {
                self.world.accountRow(id).flags.block_changed = true;
            }
            self.block_changed_accounts.items.len = changed_write;
        }

        fn compactAcceptedStorageWipes(self: *State) void {
            var write: usize = 0;
            for (self.block_storage_wipes.items) |id| {
                const row = self.world.accountRow(id);
                if (!row.flags.storage_wiped) continue;
                row.flags.storage_wiped = false;
                self.block_storage_wipes.items[write] = id;
                write += 1;
            }
            for (self.block_storage_wipes.items[0..write]) |id|
                self.world.accountRow(id).flags.storage_wiped = true;
            self.block_storage_wipes.items.len = write;
        }
    };
}

test {
    _ = @import("./world_state_test.zig");
}
