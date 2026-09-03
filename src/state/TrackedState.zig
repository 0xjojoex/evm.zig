//! Transaction-tracked execution state over an open address universe.
//!
//! The counterpart of `eth.bal.ClaimState`: the same executor state-lane
//! surface, but keyed by address over an open universe behind an optional
//! `Reader` rather than by claim ID over a closed one. Rows are allocated as
//! execution touches state. Accepted branch state, transaction-attempt rows,
//! and execution-scope state have distinct ownership. Transaction rows retain
//! first-touch originals and observations across inner rollback; the scope
//! journal restores only current values and scope-local semantics. Semantic
//! observations are an opt-in transaction sidecar; normal execution does not
//! allocate or journal them.

const std = @import("std");

const crypto = @import("../crypto.zig");
const execution = @import("../execution.zig");
const Host = @import("../Host.zig");
const range = @import("stdx").range;
const state_types = @import("../state.zig");
const Account = @import("./Account.zig");
const MemoryAccount = @import("./MemoryAccount.zig");
const StateReader = @import("./Reader.zig");
const sparse_hash_map = @import("./sparse_hash_map.zig");

const Allocator = std.mem.Allocator;
const Address = @import("../address.zig").Address;
const StorageKey = @import("./storage.zig").Key;
const storageStatus = @import("./storage.zig").status;

const LogBuffer = @import("./LogBuffer.zig");
const LogView = LogBuffer.View;
const AccessHint = state_types.AccessHint;
const Checkpoint = state_types.Checkpoint;
const AttemptId = Checkpoint.AttemptId;
const FinalizationRules = state_types.FinalizationRules;
const CodeView = state_types.CodeView;
const AccountObservation = state_types.AccountObservation;
const StorageObservation = state_types.StorageObservation;
const AccountEffect = state_types.AccountEffect;
const StorageEffect = state_types.StorageEffect;
const ChangeLayer = state_types.ChangeLayer;
const AccountChange = state_types.AccountChange;
const StorageChange = state_types.StorageChange;
const CodeHash = [32]u8;
const ByteRange = range.Bytes;

const AddressSet = sparse_hash_map.WithContext(Address, void, Address.HashContext);
const CodeHashSet = sparse_hash_map.Auto(CodeHash, void);
const AcceptedAccountMap = sparse_hash_map.WithContext(Address, AcceptedAccountRow, Address.HashContext);
const AcceptedStorageMap = sparse_hash_map.Auto(StorageKey, AcceptedStorageRow);
const TransactionAccountMap = sparse_hash_map.WithContext(Address, AccountRow, Address.HashContext);
const TransactionStorageMap = sparse_hash_map.Auto(StorageKey, StorageRow);
const ScopeStorageMap = sparse_hash_map.Auto(StorageKey, ScopeStorage);
const TransientStorageMap = sparse_hash_map.Auto(StorageKey, u256);
const CodeMap = sparse_hash_map.Auto(CodeHash, CodeEntry);
const minimum_code_chunk_bytes = 4096;

pub const AccountId = TransactionAccountMap.EntryId;
pub const StorageId = TransactionStorageMap.EntryId;
const AcceptedAccountId = AcceptedAccountMap.EntryId;
const AcceptedStorageId = AcceptedStorageMap.EntryId;
const AccountObservationId = enum(u32) { _ };
const StorageObservationId = enum(u32) { _ };

const AccountRef = struct {
    id: AccountId,
    row: *AccountRow,
};

const StorageRef = struct {
    id: StorageId,
    row: *StorageRow,
};

const AccountAccess = struct {
    account: AccountRef,
    status: execution.AccessStatus,
};

const StorageAccess = struct {
    storage: StorageRef,
    scope: *ScopeStorage,
    status: execution.AccessStatus,
};

const TrackedState = @This();

/// Rows are allocated as execution touches state, so capacity hints and
/// transaction capacity reuse are meaningful here. See `state.checkLane`.
pub const grows_on_touch = true;

allocator: Allocator,
reader: ?StateReader,
/// Pre-Spurious-Dragon only. See `Spec.retains_empty_accounts`; the executor
/// sets this from its compiled spec.
retains_empty_accounts: bool = false,
epoch: u64,
accepted_generation: u64,
next_attempt_id: u64,
accepted: Accepted,
code: CodeCache,
tx: ?Transaction,
cached_tx: ?Transaction,
transaction_reuse_active: bool,
retained_logs: LogBuffer,

pub const AccountValue = union(enum) {
    absent,
    /// Known to exist without loaded fields; only a fork that retains empty
    /// accounts can answer existence without them.
    exists_only,
    present: Account,

    fn exists(self: AccountValue) bool {
        return switch (self) {
            .absent => false,
            .exists_only, .present => true,
        };
    }
};

const AcceptedAccountRow = struct {
    value: AccountValue,
    changed: bool = false,
    storage_wiped: bool = false,
};

const AcceptedStorageRow = struct {
    value: u256,
    changed: bool = false,
};

pub const AccountFlags = packed struct {
    dirty: bool = false,
    storage_wiped: bool = false,
    touched: bool = false,
    created: bool = false,
    selfdestructed: bool = false,
    lifecycle_listed: bool = false,
    _padding: u2 = 0,
};

pub const StorageFlags = packed struct {
    dirty: bool = false,
    _padding: u7 = 0,
};

pub const AccountRow = struct {
    current: ?AccountValue = null,
    original: ?AccountValue = null,
    flags: AccountFlags = .{},
    observation_id: ?AccountObservationId = null,
};

pub const StorageRow = struct {
    current: ?u256 = null,
    transaction_original: ?u256 = null,
    flags: StorageFlags = .{},
    observation_id: ?StorageObservationId = null,
};

const AccountObservationRow = struct {
    account: AccountId,
    /// Last field-level state before a lifecycle deletion hides it.
    effect_current: ?AccountValue = null,
    observation: AccountObservation = .{},
    effect: AccountEffect = .{},
};

const StorageObservationRow = struct {
    storage: StorageId,
    /// Last semantic value before an address-level lifecycle wipe hides it.
    effect_current: ?u256 = null,
    observation: StorageObservation = .{},
    effect: StorageEffect = .{},
};

pub const ScopeStorage = struct {
    execution_original: ?u256 = null,
    warm: bool = false,
};

pub const Accepted = struct {
    accounts: AcceptedAccountMap,
    storage: AcceptedStorageMap,
    changed_accounts: std.ArrayList(AcceptedAccountId) = .empty,
    changed_storage: std.ArrayList(AcceptedStorageId) = .empty,
    storage_wipes: std.ArrayList(AcceptedAccountId) = .empty,
    introduced_code: CodeHashSet,

    fn init(allocator: Allocator) Accepted {
        return .{
            .accounts = AcceptedAccountMap.init(allocator),
            .storage = AcceptedStorageMap.init(allocator),
            .introduced_code = CodeHashSet.init(allocator),
        };
    }

    fn deinit(self: *Accepted, allocator: Allocator) void {
        self.accounts.deinit();
        self.storage.deinit();
        self.changed_accounts.deinit(allocator);
        self.changed_storage.deinit(allocator);
        self.storage_wipes.deinit(allocator);
        self.introduced_code.deinit();
        self.* = undefined;
    }

    fn clone(self: *const Accepted, allocator: Allocator) !Accepted {
        var accounts = try self.accounts.clone(allocator);
        errdefer accounts.deinit();
        var storage = try self.storage.clone(allocator);
        errdefer storage.deinit();
        var introduced_code = try self.introduced_code.clone(allocator);
        errdefer introduced_code.deinit();

        var changed_accounts: std.ArrayList(AcceptedAccountId) = .empty;
        errdefer changed_accounts.deinit(allocator);
        try changed_accounts.appendSlice(allocator, self.changed_accounts.items);

        var changed_storage: std.ArrayList(AcceptedStorageId) = .empty;
        errdefer changed_storage.deinit(allocator);
        try changed_storage.appendSlice(allocator, self.changed_storage.items);

        var storage_wipes: std.ArrayList(AcceptedAccountId) = .empty;
        errdefer storage_wipes.deinit(allocator);
        try storage_wipes.appendSlice(allocator, self.storage_wipes.items);

        return .{
            .accounts = accounts,
            .storage = storage,
            .changed_accounts = changed_accounts,
            .changed_storage = changed_storage,
            .storage_wipes = storage_wipes,
            .introduced_code = introduced_code,
        };
    }
};

pub const CodeEntry = struct {
    chunk: u32,
    bytes: ByteRange,

    comptime {
        std.debug.assert(@sizeOf(CodeEntry) == 12);
    }

    pub fn slice(self: CodeEntry, cache: *const CodeCache) []const u8 {
        const chunk = cache.chunks.items[self.chunkIndex()];
        return self.bytes.slice(chunk.bytes[0..chunk.used]);
    }

    pub fn introduced(self: CodeEntry) bool {
        return self.chunk & introduced_bit != 0;
    }

    fn init(chunk: usize, bytes: ByteRange, is_introduced: bool) CodeEntry {
        std.debug.assert(chunk <= std.math.maxInt(u31));
        const chunk_index: u31 = @intCast(chunk);
        return .{
            .chunk = @as(u32, chunk_index) | if (is_introduced) introduced_bit else 0,
            .bytes = bytes,
        };
    }

    fn chunkIndex(self: CodeEntry) u31 {
        return @truncate(self.chunk);
    }

    const introduced_bit = @as(u32, 1) << 31;
};

pub const CodeCache = struct {
    const Chunk = struct {
        bytes: []u8,
        used: u32,
    };

    entries: CodeMap,
    chunks: std.ArrayList(Chunk) = .empty,
    used_bytes: usize = 0,

    fn init(allocator: Allocator) CodeCache {
        return .{ .entries = CodeMap.init(allocator) };
    }

    fn deinit(self: *CodeCache, allocator: Allocator) void {
        self.entries.deinit();
        for (self.chunks.items) |chunk| allocator.free(chunk.bytes);
        self.chunks.deinit(allocator);
        self.* = undefined;
    }
};

pub const AccountChanges = struct {
    state: *const TrackedState,
    layer: ChangeLayer,

    pub fn len(self: AccountChanges) u32 {
        return switch (self.layer) {
            .accepted => @intCast(self.state.accepted.changed_accounts.items.len),
            .transaction => @intCast(sealedTransaction(self.state).changed_accounts.items.len),
        };
    }

    pub fn at(self: AccountChanges, index: u32) AccountChange {
        return switch (self.layer) {
            .accepted => blk: {
                const accepted = &self.state.accepted;
                const id = accepted.changed_accounts.items[index];
                const entry = accepted.accounts.entryAt(@intFromEnum(id));
                break :blk .{
                    .address = entry.key_ptr.*,
                    .account = accountValue(entry.value_ptr.value),
                };
            },
            .transaction => blk: {
                const tx = sealedTransaction(self.state);
                const id = tx.changed_accounts.items[index];
                const entry = tx.accounts.entryAt(@intFromEnum(id));
                break :blk .{
                    .address = entry.key_ptr.*,
                    .account = accountValue(entry.value_ptr.current.?),
                };
            },
        };
    }
};

pub const StorageChanges = struct {
    state: *const TrackedState,
    layer: ChangeLayer,

    pub fn len(self: StorageChanges) u32 {
        return switch (self.layer) {
            .accepted => @intCast(self.state.accepted.changed_storage.items.len),
            .transaction => @intCast(sealedTransaction(self.state).changed_storage.items.len),
        };
    }

    pub fn at(self: StorageChanges, index: u32) StorageChange {
        return switch (self.layer) {
            .accepted => blk: {
                const accepted = &self.state.accepted;
                const id = accepted.changed_storage.items[index];
                const entry = accepted.storage.entryAt(@intFromEnum(id));
                break :blk .{
                    .address = entry.key_ptr.address,
                    .key = entry.key_ptr.key,
                    .value = entry.value_ptr.value,
                };
            },
            .transaction => blk: {
                const tx = sealedTransaction(self.state);
                const id = tx.changed_storage.items[index];
                const entry = tx.storage.entryAt(@intFromEnum(id));
                break :blk .{
                    .address = entry.key_ptr.address,
                    .key = entry.key_ptr.key,
                    .value = entry.value_ptr.current.?,
                };
            },
        };
    }
};

pub const StorageWipes = struct {
    state: *const TrackedState,
    layer: ChangeLayer,

    pub fn len(self: StorageWipes) u32 {
        return switch (self.layer) {
            .accepted => @intCast(self.state.accepted.storage_wipes.items.len),
            .transaction => @intCast(sealedTransaction(self.state).storage_wipes.items.len),
        };
    }

    pub fn at(self: StorageWipes, index: u32) Address {
        return switch (self.layer) {
            .accepted => blk: {
                const accepted = &self.state.accepted;
                const id = accepted.storage_wipes.items[index];
                break :blk accepted.accounts.keyById(id).*;
            },
            .transaction => blk: {
                const tx = sealedTransaction(self.state);
                const id = tx.storage_wipes.items[index];
                break :blk tx.accounts.keyById(id).*;
            },
        };
    }
};

/// Borrowed semantic delta. Ordering is unspecified; consumers own sorting,
/// allocation, persistence batches, and any retained representation.
pub const ChangesView = struct {
    state: *const TrackedState,
    layer: ChangeLayer,
    accounts: AccountChanges,
    storage_writes: StorageChanges,
    storage_wipes: StorageWipes,

    fn init(state: *const TrackedState, layer: ChangeLayer) ChangesView {
        return .{
            .state = state,
            .layer = layer,
            .accounts = .{ .state = state, .layer = layer },
            .storage_writes = .{ .state = state, .layer = layer },
            .storage_wipes = .{ .state = state, .layer = layer },
        };
    }

    pub fn introducedCode(self: ChangesView, code_hash: CodeHash) ?CodeView {
        const introduced = switch (self.layer) {
            .accepted => self.state.accepted.introduced_code.contains(code_hash),
            .transaction => sealedTransaction(self.state).introduced_code.contains(code_hash),
        };
        if (!introduced) return null;
        const entry = self.state.code.entries.get(code_hash).?;
        return .{ .code_hash = code_hash, .bytes = entry.slice(&self.state.code) };
    }

    pub fn hasChanges(self: ChangesView) bool {
        return self.accounts.len() != 0 or
            self.storage_writes.len() != 0 or
            self.storage_wipes.len() != 0;
    }
};

pub const AccountObservationFact = struct {
    address: Address,
    original: ?AccountValue,
    current: ?AccountValue,
    observation: AccountObservation,
    effect: AccountEffect,
};

pub const StorageObservationFact = struct {
    address: Address,
    key: u256,
    original: u256,
    current: u256,
    observation: StorageObservation,
    effect: StorageEffect,
};

pub const StorageObservationMetadata = struct {
    address: Address,
    key: u256,
    observation: StorageObservation,
    effect: StorageEffect,
};

/// Dense transaction-local account facts. Ordering is internal; projectors own
/// sorting and any retained representation.
pub const AccountObservations = struct {
    state: *const TrackedState,

    pub fn len(self: AccountObservations) u32 {
        return @intCast(sealedTransaction(self.state).observed_accounts.items.len);
    }

    pub fn at(self: AccountObservations, index: u32) AccountObservationFact {
        const tx = sealedTransaction(self.state);
        const observed = &tx.observed_accounts.items[index];
        const entry = tx.accounts.entryAt(@intFromEnum(observed.account));
        return .{
            .address = entry.key_ptr.*,
            .original = entry.value_ptr.original,
            .current = observed.effect_current orelse entry.value_ptr.current,
            .observation = observed.observation,
            .effect = observed.effect,
        };
    }
};

/// Dense transaction-local storage observations. Gas-only access rows have
/// metadata but no complete value fact.
pub const StorageObservations = struct {
    state: *const TrackedState,

    pub fn len(self: StorageObservations) u32 {
        return @intCast(sealedTransaction(self.state).observed_storage.items.len);
    }

    pub fn at(self: StorageObservations, index: u32) ?StorageObservationFact {
        const tx = sealedTransaction(self.state);
        const observed = &tx.observed_storage.items[index];
        const entry = tx.storage.entryAt(@intFromEnum(observed.storage));
        const original = entry.value_ptr.transaction_original orelse return null;
        const current = observed.effect_current orelse entry.value_ptr.current orelse return null;
        return .{
            .address = entry.key_ptr.address,
            .key = entry.key_ptr.key,
            .original = original,
            .current = current,
            .observation = observed.observation,
            .effect = observed.effect,
        };
    }

    pub fn metadataAt(self: StorageObservations, index: u32) StorageObservationMetadata {
        const tx = sealedTransaction(self.state);
        const observed = &tx.observed_storage.items[index];
        const entry = tx.storage.entryAt(@intFromEnum(observed.storage));
        return .{
            .address = entry.key_ptr.address,
            .key = entry.key_ptr.key,
            .observation = observed.observation,
            .effect = observed.effect,
        };
    }
};

/// Borrowed checkpoint-resolved semantic observations from one sealed
/// transaction. BAL indices, output ordering, and detached ownership remain
/// projector policy.
pub const ObservationsView = struct {
    state: *const TrackedState,
    accounts: AccountObservations,
    storage: StorageObservations,

    fn init(state: *const TrackedState) ObservationsView {
        return .{
            .state = state,
            .accounts = .{ .state = state },
            .storage = .{ .state = state },
        };
    }

    pub fn code(self: ObservationsView, code_hash: CodeHash) ?CodeView {
        if (std.mem.eql(u8, &code_hash, &crypto.keccak256_empty)) {
            return .{ .code_hash = code_hash, .bytes = &.{} };
        }
        const entry = self.state.code.entries.get(code_hash) orelse return null;
        return .{ .code_hash = code_hash, .bytes = entry.slice(&self.state.code) };
    }
};

/// Borrowed cumulative branch facts. Projectors own output policy and
/// allocation; this view only exposes the accepted state representation.
pub const AcceptedView = struct {
    state: *const TrackedState,

    pub fn hasChanges(self: AcceptedView) bool {
        return self.changes().hasChanges();
    }

    pub fn changes(self: AcceptedView) ChangesView {
        return ChangesView.init(self.state, .accepted);
    }
};

/// Borrowed sealed transaction plus the cumulative branch it would extend.
/// The view does not own or resolve the transaction lifecycle.
pub const PendingView = struct {
    state: *const TrackedState,

    pub fn accepted(self: PendingView) AcceptedView {
        return self.state.acceptedView();
    }

    pub fn logs(self: PendingView) LogView {
        return sealedTransaction(self.state).logs.view();
    }

    /// Transaction-local changes relative to the accepted branch.
    pub fn changes(self: PendingView) ChangesView {
        _ = sealedTransaction(self.state);
        return ChangesView.init(self.state, .transaction);
    }

    pub fn observations(self: PendingView) ObservationsView {
        std.debug.assert(sealedTransaction(self.state).observe);
        return ObservationsView.init(self.state);
    }
};

/// Heap copy of the accepted branch. Capture allocates; restore is
/// allocation-free and swaps the copy back in. Only valid between
/// transactions.
pub const BranchSnapshot = struct {
    owner: *const TrackedState,
    allocator: Allocator,
    epoch: u64,
    accepted_generation: u64,
    accepted: Accepted,
    retained_logs: LogBuffer,
    resolved: bool = false,

    pub fn clone(self: *const BranchSnapshot) !BranchSnapshot {
        std.debug.assert(!self.resolved);
        var accepted = try self.accepted.clone(self.allocator);
        errdefer accepted.deinit(self.allocator);
        return .{
            .owner = self.owner,
            .allocator = self.allocator,
            .epoch = self.epoch,
            .accepted_generation = self.accepted_generation,
            .accepted = accepted,
            .retained_logs = try self.retained_logs.clone(self.allocator),
        };
    }

    pub fn deinit(self: *BranchSnapshot) void {
        self.accepted.deinit(self.allocator);
        self.retained_logs.deinit(self.allocator);
        self.* = undefined;
    }
};

pub const Scope = struct {
    /// Generation of the innermost open checkpoint, or of the scope root when
    /// none is open. Every checkpoint allocates a fresh value, so closing one
    /// out of LIFO order fails `validateCheckpoint`.
    generation: u64 = 0,
    next_generation: u64 = 0,
    /// Open nested checkpoints; zero at the scope root.
    depth: u32 = 0,
    active: bool = false,
    warm_accounts: AddressSet,
    storage: ScopeStorageMap,
    transient_storage: TransientStorageMap,

    fn init(allocator: Allocator) Scope {
        return .{
            .warm_accounts = AddressSet.init(allocator),
            .storage = ScopeStorageMap.init(allocator),
            .transient_storage = TransientStorageMap.init(allocator),
        };
    }

    fn deinit(self: *Scope) void {
        self.warm_accounts.deinit();
        self.storage.deinit();
        self.transient_storage.deinit();
        self.* = undefined;
    }

    fn clearRetainingCapacity(self: *Scope) void {
        self.warm_accounts.clearRetainingCapacity();
        self.storage.clearRetainingCapacity();
        self.transient_storage.clearRetainingCapacity();
        self.active = false;
    }

    fn allocateGeneration(self: *Scope) u64 {
        std.debug.assert(self.next_generation != std.math.maxInt(u64));
        self.next_generation += 1;
        return self.next_generation;
    }
};

const Journal = struct {
    const Id = enum(u32) { _ };

    const Entry = union(enum(u8)) {
        account: Id,
        observed_account: Id,
        storage: Id,
        observed_storage: Id,
        warm_account: AccountId,
        warm_storage: StorageId,
        transient_storage: Id,

        comptime {
            std.debug.assert(@sizeOf(Entry) == 8);
        }
    };

    const AccountUndo = struct {
        account: AccountId,
        current: ?AccountValue,
        flags: AccountFlags,
    };

    const StorageUndo = struct {
        storage: StorageId,
        current: ?u256,
        flags: StorageFlags,
    };

    const AccountObservationUndo = struct {
        observation: AccountObservationId,
        effect_current: ?AccountValue,
        effect: AccountEffect,
    };

    const StorageObservationUndo = struct {
        observation: StorageObservationId,
        effect_current: ?u256,
        effect: StorageEffect,
    };

    const TransientUndo = struct {
        key: StorageKey,
        previous: u256,
    };

    entries: std.ArrayList(Entry) = .empty,
    accounts: std.ArrayList(AccountUndo) = .empty,
    storage: std.ArrayList(StorageUndo) = .empty,
    account_observations: std.ArrayList(AccountObservationUndo) = .empty,
    storage_observations: std.ArrayList(StorageObservationUndo) = .empty,
    transient: std.ArrayList(TransientUndo) = .empty,

    fn deinit(self: *Journal, allocator: Allocator) void {
        self.entries.deinit(allocator);
        self.accounts.deinit(allocator);
        self.storage.deinit(allocator);
        self.account_observations.deinit(allocator);
        self.storage_observations.deinit(allocator);
        self.transient.deinit(allocator);
        self.* = undefined;
    }

    fn clearRetainingCapacity(self: *Journal) void {
        self.entries.clearRetainingCapacity();
        self.accounts.clearRetainingCapacity();
        self.storage.clearRetainingCapacity();
        self.account_observations.clearRetainingCapacity();
        self.storage_observations.clearRetainingCapacity();
        self.transient.clearRetainingCapacity();
    }

    /// Every payload list is cleared together with `entries`, so the entry
    /// list alone decides emptiness.
    fn isEmpty(self: *const Journal) bool {
        return self.entries.items.len == 0;
    }

    fn ensureAccount(self: *Journal, allocator: Allocator, observed: bool) !void {
        try self.entries.ensureUnusedCapacity(allocator, 1);
        try self.accounts.ensureUnusedCapacity(allocator, 1);
        if (observed) try self.account_observations.ensureUnusedCapacity(allocator, 1);
    }

    fn ensureStorage(self: *Journal, allocator: Allocator, observed: bool) !void {
        try self.entries.ensureUnusedCapacity(allocator, 1);
        try self.storage.ensureUnusedCapacity(allocator, 1);
        if (observed) try self.storage_observations.ensureUnusedCapacity(allocator, 1);
    }

    fn ensureWarm(self: *Journal, allocator: Allocator) !void {
        try self.entries.ensureUnusedCapacity(allocator, 1);
    }

    fn appendTransient(self: *Journal, allocator: Allocator, undo: TransientUndo) !void {
        try self.entries.ensureUnusedCapacity(allocator, 1);
        try self.transient.ensureUnusedCapacity(allocator, 1);
        const id: Id = @enumFromInt(self.transient.items.len);
        self.transient.appendAssumeCapacity(undo);
        self.entries.appendAssumeCapacity(.{ .transient_storage = id });
    }

    fn appendAccountAssumeCapacity(
        self: *Journal,
        undo: AccountUndo,
        observation_undo: ?AccountObservationUndo,
    ) void {
        const id: Id = @enumFromInt(self.accounts.items.len);
        self.accounts.appendAssumeCapacity(undo);
        if (observation_undo) |value| {
            self.account_observations.appendAssumeCapacity(value);
            self.entries.appendAssumeCapacity(.{ .observed_account = id });
        } else {
            self.entries.appendAssumeCapacity(.{ .account = id });
        }
    }

    fn appendStorageAssumeCapacity(
        self: *Journal,
        undo: StorageUndo,
        observation_undo: ?StorageObservationUndo,
    ) void {
        const id: Id = @enumFromInt(self.storage.items.len);
        self.storage.appendAssumeCapacity(undo);
        if (observation_undo) |value| {
            self.storage_observations.appendAssumeCapacity(value);
            self.entries.appendAssumeCapacity(.{ .observed_storage = id });
        } else {
            self.entries.appendAssumeCapacity(.{ .storage = id });
        }
    }
};

pub const Transaction = struct {
    id: AttemptId,
    observe: bool,
    accounts: TransactionAccountMap,
    storage: TransactionStorageMap,
    observed_accounts: std.ArrayList(AccountObservationRow) = .empty,
    observed_storage: std.ArrayList(StorageObservationRow) = .empty,
    changed_accounts: std.ArrayList(AccountId) = .empty,
    changed_storage: std.ArrayList(StorageId) = .empty,
    storage_wipes: std.ArrayList(AccountId) = .empty,
    lifecycle_accounts: std.ArrayList(AccountId) = .empty,
    introduced_code: CodeHashSet,
    scope: Scope,
    journal: Journal = .{},
    logs: LogBuffer = .{},
    sealed: bool = false,

    fn init(allocator: Allocator, id: AttemptId, observe: bool) Transaction {
        return .{
            .id = id,
            .observe = observe,
            .accounts = TransactionAccountMap.init(allocator),
            .storage = TransactionStorageMap.init(allocator),
            .introduced_code = CodeHashSet.init(allocator),
            .scope = Scope.init(allocator),
        };
    }

    fn deinit(self: *Transaction, allocator: Allocator) void {
        self.accounts.deinit();
        self.storage.deinit();
        self.observed_accounts.deinit(allocator);
        self.observed_storage.deinit(allocator);
        self.changed_accounts.deinit(allocator);
        self.changed_storage.deinit(allocator);
        self.storage_wipes.deinit(allocator);
        self.lifecycle_accounts.deinit(allocator);
        self.introduced_code.deinit();
        self.scope.deinit();
        self.journal.deinit(allocator);
        self.logs.deinit(allocator);
        self.* = undefined;
    }

    fn reset(self: *Transaction, id: AttemptId, observe: bool) void {
        self.accounts.clearRetainingCapacity();
        self.storage.clearRetainingCapacity();
        self.observed_accounts.clearRetainingCapacity();
        self.observed_storage.clearRetainingCapacity();
        self.changed_accounts.clearRetainingCapacity();
        self.changed_storage.clearRetainingCapacity();
        self.storage_wipes.clearRetainingCapacity();
        self.lifecycle_accounts.clearRetainingCapacity();
        self.introduced_code.clearRetainingCapacity();
        self.scope.clearRetainingCapacity();
        self.scope.generation = 0;
        self.scope.next_generation = 0;
        self.scope.depth = 0;
        self.journal.clearRetainingCapacity();
        self.logs.clearRetainingCapacity();
        self.id = id;
        self.observe = observe;
        self.sealed = false;
    }
};

pub fn init(allocator: Allocator) TrackedState {
    return initWithStateReader(allocator, null);
}

/// Construct the tracked representation for one exact execution spec.
pub fn initForSpec(
    allocator: Allocator,
    comptime spec: anytype,
    reader: ?StateReader,
) TrackedState {
    var state = initWithStateReader(allocator, reader);
    state.retains_empty_accounts = spec.retains_empty_accounts;
    return state;
}

pub fn initWithStateReader(allocator: Allocator, reader: ?StateReader) TrackedState {
    return .{
        .allocator = allocator,
        .reader = reader,
        .epoch = 0,
        .accepted_generation = 0,
        .next_attempt_id = 0,
        .accepted = Accepted.init(allocator),
        .code = CodeCache.init(allocator),
        .tx = null,
        .cached_tx = null,
        .transaction_reuse_active = false,
        .retained_logs = .{},
    };
}

pub fn deinit(self: *TrackedState) void {
    if (self.tx) |*tx| tx.deinit(self.allocator);
    if (self.cached_tx) |*tx| tx.deinit(self.allocator);
    self.accepted.deinit(self.allocator);
    self.code.deinit(self.allocator);
    self.retained_logs.deinit(self.allocator);
    self.* = undefined;
}

fn reset(self: *TrackedState, reader: ?StateReader) void {
    const allocator = self.allocator;
    const retains_empty_accounts = self.retains_empty_accounts;
    std.debug.assert(self.epoch != std.math.maxInt(u64));
    const next_epoch = self.epoch + 1;
    self.deinit();
    self.* = initWithStateReader(allocator, reader);
    self.retains_empty_accounts = retains_empty_accounts;
    self.epoch = next_epoch;
}

pub fn seedAccount(self: *TrackedState, address: Address, account_value: MemoryAccount) !void {
    std.debug.assert(self.tx == null);
    std.debug.assert(self.accepted.changed_accounts.items.len == 0);
    std.debug.assert(self.accepted.changed_storage.items.len == 0);
    std.debug.assert(self.accepted.storage_wipes.items.len == 0);
    var account = account_value;
    defer account.deinit();

    const code_hash = account.account.code_hash;
    if (!std.mem.eql(u8, &crypto.keccak256(account.code), &code_hash)) return error.CodeHashMismatch;
    if (account.code.len != 0) _ = try self.cacheCode(code_hash, account.code, false);

    var old_keys: std.ArrayList(StorageKey) = .empty;
    defer old_keys.deinit(self.allocator);
    var accepted_it = self.accepted.storage.keyIterator();
    while (accepted_it.next()) |key| {
        if (Address.eql(key.address, address)) try old_keys.append(self.allocator, key.*);
    }
    for (old_keys.items) |key| {
        _ = self.accepted.storage.remove(key);
    }

    // Seeding is the other way base state arrives, so it normalizes like a
    // reader load: on a fork without empty accounts, seeding one seeds nothing.
    const seeded = account.account;
    try self.accepted.accounts.put(address, .{
        .value = if (self.dropsEmptyAccount(seeded)) .absent else .{ .present = seeded },
    });
    try self.accepted.storage.ensureUnusedCapacity(@intCast(account.storage.count()));
    var storage_it = account.storage.iterator();
    while (storage_it.next()) |entry| {
        self.accepted.storage.putAssumeCapacityNoClobber(.{
            .address = address,
            .key = entry.key_ptr.*,
        }, .{ .value = entry.value_ptr.* });
    }
}

pub fn reserveAccessHint(self: *TrackedState, hint: AccessHint) !void {
    const tx = self.mutableTransaction();
    try tx.scope.warm_accounts.ensureUnusedCapacity(@intCast(hint.accounts));
    try tx.accounts.ensureUnusedCapacity(@intCast(hint.accounts));
    try tx.scope.storage.ensureUnusedCapacity(@intCast(hint.storage_keys));
    try tx.storage.ensureUnusedCapacity(@intCast(hint.storage_keys));
}

pub fn reserveAcceptedAccessHint(self: *TrackedState, hint: AccessHint) !void {
    std.debug.assert(self.tx == null);
    try self.accepted.accounts.ensureUnusedCapacity(@intCast(hint.accounts));
    try self.accepted.storage.ensureUnusedCapacity(@intCast(hint.storage_keys));
}

pub fn beginTransactionCapacityReuse(self: *TrackedState) void {
    std.debug.assert(self.tx == null);
    std.debug.assert(self.cached_tx == null);
    std.debug.assert(!self.transaction_reuse_active);
    self.transaction_reuse_active = true;
}

pub fn endTransactionCapacityReuse(self: *TrackedState) void {
    std.debug.assert(self.tx == null);
    std.debug.assert(self.transaction_reuse_active);
    if (self.cached_tx) |*tx| tx.deinit(self.allocator);
    self.cached_tx = null;
    self.transaction_reuse_active = false;
}

pub fn beginTransaction(self: *TrackedState) AttemptId {
    return self.beginTransactionMode(false);
}

pub fn beginObservedTransaction(self: *TrackedState) AttemptId {
    return self.beginTransactionMode(true);
}

fn beginTransactionMode(self: *TrackedState, observe: bool) AttemptId {
    std.debug.assert(self.tx == null);
    std.debug.assert(self.next_attempt_id != std.math.maxInt(u64));
    self.next_attempt_id += 1;
    const id: AttemptId = @enumFromInt(self.next_attempt_id);
    var tx = if (self.cached_tx) |cached| blk: {
        std.debug.assert(self.transaction_reuse_active);
        var reusable = cached;
        reusable.reset(id, observe);
        break :blk reusable;
    } else Transaction.init(self.allocator, id, observe);
    self.cached_tx = null;
    std.mem.swap(LogBuffer, &tx.logs, &self.retained_logs);
    tx.logs.clearRetainingCapacity();
    self.tx = tx;
    return id;
}

pub fn beginScope(self: *TrackedState) void {
    const tx = self.mutableTransaction();
    std.debug.assert(!tx.scope.active);
    std.debug.assert(tx.journal.isEmpty());
    tx.scope.generation = tx.scope.allocateGeneration();
    tx.scope.depth = 0;
    tx.scope.active = true;
    tx.logs.clearRetainingCapacity();
}

pub fn closeScope(self: *TrackedState) void {
    const tx = self.mutableTransaction();
    std.debug.assert(tx.scope.active);
    std.debug.assert(tx.scope.depth == 0);
    tx.journal.clearRetainingCapacity();
    tx.scope.clearRetainingCapacity();
}

/// Clear EIP-1153 state at a custom transaction root boundary while retaining
/// transaction-scoped warmth, logs, and the surrounding rollback journal.
/// The clear may occur inside an outer checkpoint and is not journaled: rollback
/// must not resurrect transient values whose root lifetime has ended.
pub fn clearTransientStorage(self: *TrackedState) void {
    const tx = self.mutableTransaction();
    std.debug.assert(tx.scope.active);
    tx.scope.transient_storage.clearRetainingCapacity();
}

pub fn scopeActive(self: *const TrackedState) bool {
    const tx = self.tx orelse return false;
    return tx.scope.active;
}

/// True while a nested checkpoint is open inside the scope root.
pub fn hasOpenCheckpoint(self: *const TrackedState) bool {
    const tx = self.tx orelse return false;
    return tx.scope.depth != 0;
}

pub fn checkpoint(self: *TrackedState) Checkpoint {
    const tx = self.mutableTransaction();
    std.debug.assert(tx.scope.active);
    std.debug.assert(tx.scope.depth != std.math.maxInt(u32));
    const parent_generation = tx.scope.generation;
    const generation = tx.scope.allocateGeneration();
    tx.scope.depth += 1;
    tx.scope.generation = generation;
    return .{
        .attempt_id = tx.id,
        .scope_generation = generation,
        .parent_scope_generation = parent_generation,
        .journal_len = @intCast(tx.journal.entries.items.len),
        .changed_accounts_len = @intCast(tx.changed_accounts.items.len),
        .changed_storage_len = @intCast(tx.changed_storage.items.len),
        .storage_wipes_len = @intCast(tx.storage_wipes.items.len),
        .logs = tx.logs.checkpoint(),
    };
}

pub fn commitCheckpoint(self: *TrackedState, checkpoint_state: Checkpoint) void {
    self.validateCheckpoint(checkpoint_state);
    const tx = &self.tx.?;
    tx.scope.generation = checkpoint_state.parent_scope_generation;
    tx.scope.depth -= 1;
}

/// Journal unwind restores current values and flags; the transaction ID lists
/// are truncated to their checkpoint lengths because rows first listed inside
/// the reverted scope return to their untouched flags.
pub fn revertToCheckpoint(self: *TrackedState, checkpoint_state: Checkpoint) void {
    self.validateCheckpoint(checkpoint_state);
    const tx = &self.tx.?;
    self.revertJournalTo(checkpoint_state.journal_len);
    tx.changed_accounts.items.len = checkpoint_state.changed_accounts_len;
    tx.changed_storage.items.len = checkpoint_state.changed_storage_len;
    tx.storage_wipes.items.len = checkpoint_state.storage_wipes_len;
    tx.logs.truncate(checkpoint_state.logs);
    tx.scope.generation = checkpoint_state.parent_scope_generation;
    tx.scope.depth -= 1;
}

pub fn seal(self: *TrackedState, id: AttemptId) void {
    const tx = self.assertCurrent(id);
    std.debug.assert(!tx.sealed);
    std.debug.assert(!tx.scope.active);
    std.debug.assert(tx.journal.isEmpty());
    compactTransactionStorageChanges(tx);
    tx.sealed = true;
}

/// Fold the sealed transaction rows into the accepted branch; the transaction
/// itself is released or cached for reuse.
pub fn retain(self: *TrackedState, id: AttemptId) void {
    const tx = self.assertCurrent(id);
    std.debug.assert(tx.sealed);
    std.debug.assert(!tx.scope.active);
    std.debug.assert(self.accepted_generation != std.math.maxInt(u64));

    for (tx.storage_wipes.items) |tx_account_id| {
        const address = tx.accounts.keyById(tx_account_id).*;
        compactAcceptedStorageChanges(&self.accepted, address);
        const accepted_id = self.accepted.accounts.getEntryId(address).?;
        const accepted_row = self.accepted.accounts.valuePtrById(accepted_id);
        if (!accepted_row.storage_wiped) {
            accepted_row.storage_wiped = true;
            self.accepted.storage_wipes.appendAssumeCapacity(accepted_id);
        }
    }

    for (tx.changed_accounts.items) |tx_account_id| {
        const entry = tx.accounts.entryAt(@intFromEnum(tx_account_id));
        const current = entry.value_ptr.current.?;
        if (current == .absent) compactAcceptedStorageChanges(&self.accepted, entry.key_ptr.*);
        const accepted_id = self.accepted.accounts.getEntryId(entry.key_ptr.*).?;
        const accepted_row = self.accepted.accounts.valuePtrById(accepted_id);
        accepted_row.value = current;
        if (!accepted_row.changed) {
            accepted_row.changed = true;
            self.accepted.changed_accounts.appendAssumeCapacity(accepted_id);
        }
    }

    for (tx.changed_storage.items) |tx_storage_id| {
        const entry = tx.storage.entryAt(@intFromEnum(tx_storage_id));
        const result = self.accepted.storage.getOrPut(entry.key_ptr.*) catch unreachable;
        if (!result.found_existing) result.value_ptr.* = .{ .value = entry.value_ptr.current.? };
        result.value_ptr.value = entry.value_ptr.current.?;
        if (!result.value_ptr.changed) {
            result.value_ptr.changed = true;
            self.accepted.changed_storage.appendAssumeCapacity(result.entry_id);
        }
    }

    var introduced_it = tx.introduced_code.keyIterator();
    while (introduced_it.next()) |hash| {
        self.accepted.introduced_code.putAssumeCapacity(hash.*, {});
    }

    std.mem.swap(LogBuffer, &self.retained_logs, &tx.logs);
    self.accepted_generation += 1;
    self.discardActive();
}

/// Release the transaction rows; the accepted branch was never touched.
pub fn discard(self: *TrackedState, id: AttemptId) void {
    _ = self.assertCurrent(id);
    self.discardActive();
}

pub fn branchSnapshot(self: *TrackedState) !BranchSnapshot {
    std.debug.assert(self.tx == null);
    var accepted = try self.accepted.clone(self.allocator);
    errdefer accepted.deinit(self.allocator);
    return .{
        .owner = self,
        .allocator = self.allocator,
        .epoch = self.epoch,
        .accepted_generation = self.accepted_generation,
        .accepted = accepted,
        .retained_logs = try self.retained_logs.clone(self.allocator),
    };
}

pub fn restoreBranch(self: *TrackedState, snapshot: *BranchSnapshot) void {
    std.debug.assert(snapshot.owner == self);
    std.debug.assert(snapshot.epoch == self.epoch);
    std.debug.assert(!snapshot.resolved);
    self.discardActive();
    std.mem.swap(Accepted, &self.accepted, &snapshot.accepted);
    std.mem.swap(LogBuffer, &self.retained_logs, &snapshot.retained_logs);
    self.accepted_generation = snapshot.accepted_generation;
    snapshot.resolved = true;
}

pub fn acceptedView(self: *const TrackedState) AcceptedView {
    return .{ .state = self };
}

/// Every accessor asserts the sealed transaction itself; the view is only a
/// handle.
pub fn pendingView(self: *const TrackedState) PendingView {
    return .{ .state = self };
}

pub fn logView(self: *const TrackedState) LogView {
    return if (self.tx) |*tx| tx.logs.view() else self.retained_logs.view();
}

/// Return a materialized row without creating an execution observation.
pub fn getAccount(self: *const TrackedState, address: Address) ?Account {
    if (self.tx) |*tx| {
        if (tx.accounts.get(address)) |row| {
            if (row.current) |value| return accountValue(value);
        }
    }
    const row = self.accepted.accounts.get(address) orelse return null;
    return accountValue(row.value);
}

pub fn getAccountOrLoad(self: *TrackedState, address: Address) !?Account {
    return accountValue(try self.readAccount(address, .{ .accessed = true, .value_read = true }));
}

pub fn accountExists(self: *TrackedState, address: Address) !bool {
    if (self.tx == null) return (try self.acceptedAccountExistence(address)).exists();
    if (self.tx.?.sealed) {
        if (self.tx.?.accounts.get(address)) |row| {
            if (row.current) |value| return value.exists();
        }
        return (try self.acceptedAccountExistence(address)).exists();
    }
    const tx = self.mutableTransaction();
    const account_ref = try self.transactionAccountRef(tx, address);
    _ = try self.observeAccount(account_ref, .{ .accessed = true, .existence_read = true });
    if (account_ref.row.current == null) {
        const value = try self.acceptedAccountExistence(address);
        account_ref.row.original = value;
        account_ref.row.current = value;
    }
    return account_ref.row.current.?.exists();
}

pub fn getBalance(self: *TrackedState, address: Address) !u256 {
    return switch (try self.readAccount(address, .{ .accessed = true, .value_read = true })) {
        .absent => 0,
        .present => |account| account.balance,
        .exists_only => unreachable,
    };
}

pub fn getNonce(self: *TrackedState, address: Address) !u64 {
    return switch (try self.readAccount(address, .{ .accessed = true, .value_read = true })) {
        .absent => 0,
        .present => |account| account.nonce,
        .exists_only => unreachable,
    };
}

pub fn getCodeView(self: *TrackedState, address: Address) !CodeView {
    return switch (try self.readAccount(address, .{ .accessed = true, .code_read = true })) {
        .absent => .{ .code_hash = crypto.keccak256_empty, .bytes = &.{} },
        .present => |account| .{
            .code_hash = account.code_hash,
            .bytes = try self.codeByHash(account.code_hash),
        },
        .exists_only => unreachable,
    };
}

pub fn getCode(self: *TrackedState, address: Address) ![]const u8 {
    return (try self.getCodeView(address)).bytes;
}

pub fn getCodeHash(self: *TrackedState, address: Address) !u256 {
    return switch (try self.readAccount(address, .{ .accessed = true, .value_read = true })) {
        .absent => 0,
        .present => |account| std.mem.readInt(u256, &account.code_hash, .big),
        .exists_only => unreachable,
    };
}

pub fn accountHasCode(self: *TrackedState, address: Address) !bool {
    return switch (try self.readAccount(address, .{ .accessed = true, .value_read = true })) {
        .absent => false,
        .present => |account| !std.mem.eql(u8, &account.code_hash, &crypto.keccak256_empty),
        .exists_only => unreachable,
    };
}

pub fn setBalance(self: *TrackedState, address: Address, balance: u256) !void {
    const account_ref = try self.materializeTransactionAccount(address);
    const observation = try self.observeAccount(account_ref, .{
        .accessed = true,
        .semantic_access = true,
        .value_read = true,
    });
    const current = account_ref.row.current.?;
    var account = switch (current) {
        .absent => Account{},
        .present => |value| value,
        .exists_only => unreachable,
    };
    if (current == .present and account.balance == balance) return;
    account.balance = balance;
    const row = try self.prepareAccountMutation(account_ref);
    row.current = .{ .present = account };
    if (observation) |value| value.effect.balance_written = true;
}

pub fn addBalance(self: *TrackedState, address: Address, value: u256) !void {
    if (value == 0) return;
    const balance = try self.getBalance(address);
    try self.setBalance(
        address,
        std.math.add(u256, balance, value) catch return error.BalanceOverflow,
    );
}

pub fn subtractBalance(self: *TrackedState, address: Address, value: u256) !bool {
    if (value == 0) return true;
    const balance = try self.getBalance(address);
    if (balance < value) return false;
    try self.setBalance(address, balance - value);
    return true;
}

pub fn setNonce(self: *TrackedState, address: Address, nonce: u64) !void {
    const account_ref = try self.materializeTransactionAccount(address);
    const observation = try self.observeAccount(account_ref, .{
        .accessed = true,
        .semantic_access = true,
        .value_read = true,
    });
    const current = account_ref.row.current.?;
    var account = switch (current) {
        .absent => Account{},
        .present => |value| value,
        .exists_only => unreachable,
    };
    if (current == .present and account.nonce == nonce) return;
    account.nonce = nonce;
    const row = try self.prepareAccountMutation(account_ref);
    row.current = .{ .present = account };
    if (observation) |value| value.effect.nonce_written = true;
}

pub fn setCode(self: *TrackedState, address: Address, code_bytes: []const u8) !void {
    const account_ref = try self.materializeTransactionAccount(address);
    const observation = try self.observeAccount(account_ref, .{
        .accessed = true,
        .semantic_access = true,
        .value_read = true,
    });
    var account = switch (account_ref.row.current.?) {
        .absent => Account{},
        .present => |value| value,
        .exists_only => unreachable,
    };
    const code_hash = crypto.keccak256(code_bytes);
    const empty = std.mem.eql(u8, &code_hash, &crypto.keccak256_empty);
    const cached = if (empty) null else self.code.entries.get(code_hash);
    const introduced = !empty and (cached == null or cached.?.introduced());
    const tx = self.mutableTransaction();
    const track_introduction = introduced and
        !self.accepted.introduced_code.contains(code_hash) and
        !tx.introduced_code.contains(code_hash);
    if (track_introduction) {
        try tx.introduced_code.ensureUnusedCapacity(1);
        const introduced_count = tx.introduced_code.count();
        std.debug.assert(introduced_count < std.math.maxInt(u32));
        try self.accepted.introduced_code.ensureUnusedCapacity(introduced_count + 1);
    }
    _ = try self.cacheCode(code_hash, code_bytes, true);
    const row = try self.prepareAccountMutation(account_ref);
    if (track_introduction) tx.introduced_code.putAssumeCapacityNoClobber(code_hash, {});
    account.code_hash = code_hash;
    row.current = .{ .present = account };
    if (observation) |value| value.effect.code_written = true;
}

pub fn clearCode(self: *TrackedState, address: Address) !void {
    try self.setCode(address, &.{});
}

pub fn touchAccount(self: *TrackedState, address: Address) !void {
    const account_ref = try self.materializeTransactionAccount(address);
    _ = try self.observeAccount(account_ref, .{ .accessed = true });
    if (account_ref.row.flags.touched) return;
    const row = try self.prepareAccountMutation(account_ref);
    if (row.current.? == .absent) row.current = .{ .present = .{} };
    row.flags.touched = true;
}

pub fn accessAccount(self: *TrackedState, address: Address) !execution.AccessStatus {
    const access = try self.ensureAccountWarm(address);
    _ = try self.observeAccount(access.account, .{ .accessed = true, .semantic_access = true });
    return access.status;
}

/// Record an account access after instruction gas/admission has succeeded.
/// This does not load account metadata or alter warmth.
pub fn observeAccountAccess(self: *TrackedState, address: Address) !void {
    const tx = self.mutableTransaction();
    if (!tx.observe) return;
    const account_ref = try self.transactionAccountRef(tx, address);
    _ = try self.observeAccount(account_ref, .{ .accessed = true, .semantic_access = true });
}

pub fn warmAccount(self: *TrackedState, address: Address) !void {
    _ = try self.ensureAccountWarm(address);
}

pub fn isAccountWarm(self: *const TrackedState, address: Address) bool {
    const tx = self.tx orelse return false;
    return tx.scope.warm_accounts.contains(address);
}

pub fn getStorage(self: *TrackedState, address: Address, key: u256) !u256 {
    const storage_key: StorageKey = .{ .address = address, .key = key };
    if (self.tx == null) return self.readAcceptedStorage(storage_key);
    if (self.tx.?.sealed) {
        if (self.tx.?.storage.get(storage_key)) |row| {
            if (row.current) |value| return value;
        }
        if (transactionStorageWiped(&self.tx.?, address)) return 0;
        return self.readAcceptedStorage(storage_key);
    }
    const storage_ref = try self.materializeTransactionStorage(storage_key);
    _ = try self.observeStorage(storage_ref, .{ .accessed = true, .value_read = true });
    return storage_ref.row.current.?;
}

pub fn accessStorage(self: *TrackedState, address: Address, key: u256) !execution.AccessStatus {
    return (try self.accessStorageKey(.{ .address = address, .key = key })).status;
}

pub fn loadStorage(self: *TrackedState, address: Address, key: u256) !Host.StorageLoadResult {
    const storage_key: StorageKey = .{ .address = address, .key = key };
    const access = try self.accessStorageKey(storage_key);
    try self.loadStorageRef(storage_key, access.storage);
    _ = try self.observeStorage(access.storage, .{ .value_read = true });
    return .{ .value = access.storage.row.current.?, .access_status = access.status };
}

pub fn setStorage(self: *TrackedState, address: Address, key: u256, value: u256) !execution.StorageStatus {
    const storage_key: StorageKey = .{ .address = address, .key = key };
    const tx = self.mutableTransaction();
    std.debug.assert(tx.scope.active);
    const storage_ref = try self.transactionStorageRef(tx, storage_key);
    const scope_storage = try self.scopeStorageRef(tx, storage_key);
    try self.loadStorageRef(storage_key, storage_ref);
    return self.setResolvedStorage(storage_key, storage_ref, scope_storage, value);
}

pub fn storeStorage(self: *TrackedState, address: Address, key: u256, value: u256) !Host.StorageStoreResult {
    const storage_key: StorageKey = .{ .address = address, .key = key };
    const access = try self.accessStorageKey(storage_key);
    try self.loadStorageRef(storage_key, access.storage);
    return .{
        .storage_status = try self.setResolvedStorage(storage_key, access.storage, access.scope, value),
        .access_status = access.status,
    };
}

pub fn originalStorage(self: *TrackedState, address: Address, key: u256) !u256 {
    const storage_key: StorageKey = .{ .address = address, .key = key };
    const tx = self.mutableTransaction();
    std.debug.assert(tx.scope.active);
    const scope_storage = try self.scopeStorageRef(tx, storage_key);
    const storage_ref = try self.transactionStorageRef(tx, storage_key);
    try self.loadStorageRef(storage_key, storage_ref);
    _ = try self.observeStorage(storage_ref, .{ .accessed = true, .value_read = true });
    captureExecutionOriginal(scope_storage, storage_ref);
    return scope_storage.execution_original.?;
}

pub fn warmStorage(self: *TrackedState, address: Address, key: u256) !void {
    _ = try self.ensureStorageWarm(.{ .address = address, .key = key });
}

pub fn isStorageWarm(self: *const TrackedState, address: Address, key: u256) bool {
    const tx = self.tx orelse return false;
    const scope_storage = tx.scope.storage.get(.{ .address = address, .key = key }) orelse return false;
    return scope_storage.warm;
}

pub fn getTransientStorage(self: *TrackedState, address: Address, key: u256) !u256 {
    const tx = self.mutableTransaction();
    std.debug.assert(tx.scope.active);
    return tx.scope.transient_storage.get(.{ .address = address, .key = key }) orelse 0;
}

pub fn setTransientStorage(self: *TrackedState, address: Address, key: u256, value: u256) !void {
    const tx = self.mutableTransaction();
    std.debug.assert(tx.scope.active);
    const storage_key: StorageKey = .{ .address = address, .key = key };
    const previous_entry = tx.scope.transient_storage.get(storage_key);
    const previous = previous_entry orelse 0;
    if (previous == value) return;
    if (previous_entry == null) try tx.scope.transient_storage.ensureUnusedCapacity(1);
    try tx.journal.appendTransient(self.allocator, .{
        .key = storage_key,
        .previous = previous,
    });
    // Zero is transient storage's semantic absence. Retain the row until the
    // transaction-wide clear so checkpoint rollback never repairs probe clusters.
    tx.scope.transient_storage.putAssumeCapacity(storage_key, value);
}

pub fn emitLog(self: *TrackedState, event_log: Host.Log) !void {
    const tx = self.mutableTransaction();
    std.debug.assert(tx.scope.active);
    try tx.logs.append(self.allocator, event_log);
}

pub fn clearLogs(self: *TrackedState) void {
    const logs = if (self.tx) |*tx| &tx.logs else &self.retained_logs;
    logs.clearRetainingCapacity();
}

pub fn markCreatedContract(self: *TrackedState, address: Address) !void {
    const account_ref = try self.materializeTransactionAccount(address);
    const observation = try self.observeAccount(account_ref, .{ .accessed = true, .semantic_access = true });
    if (account_ref.row.flags.created) return;
    const row = try self.prepareLifecycleMutation(account_ref);
    row.flags.created = true;
    if (observation) |value| value.effect.created_contract = true;
}

pub fn markSelfdestructed(self: *TrackedState, address: Address) !void {
    const account_ref = try self.materializeTransactionAccount(address);
    const observation = try self.observeAccount(account_ref, .{ .accessed = true, .semantic_access = true });
    if (account_ref.row.flags.selfdestructed) return;
    const row = try self.prepareLifecycleMutation(account_ref);
    row.flags.selfdestructed = true;
    if (observation) |value| value.effect.selfdestruct = true;
}

pub fn createdInTransaction(self: *const TrackedState, address: Address) bool {
    const tx = self.tx orelse return false;
    const row = tx.accounts.get(address) orelse return false;
    return row.flags.created;
}

pub fn wasSelfdestructed(self: *const TrackedState, address: Address) bool {
    const tx = self.tx orelse return false;
    const row = tx.accounts.get(address) orelse return false;
    return row.flags.selfdestructed;
}

pub fn finalize(self: *TrackedState, rules: FinalizationRules) !void {
    const tx = self.mutableTransaction();
    std.debug.assert(tx.scope.active);
    if (tx.lifecycle_accounts.items.len == 0) return;

    // Every list append below assumes capacity, so one reservation covers the
    // whole pass and a failure leaves the rows untouched.
    const lifecycle_count: u32 = @intCast(tx.lifecycle_accounts.items.len);
    const pending_accounts = tx.changed_accounts.items.len + @as(usize, lifecycle_count);
    try tx.storage_wipes.ensureUnusedCapacity(self.allocator, lifecycle_count);
    try tx.changed_accounts.ensureUnusedCapacity(self.allocator, lifecycle_count);
    try self.accepted.storage_wipes.ensureUnusedCapacity(self.allocator, lifecycle_count);
    try self.accepted.changed_accounts.ensureUnusedCapacity(self.allocator, pending_accounts);

    const checkpoint_state = self.checkpoint();
    errdefer self.revertToCheckpoint(checkpoint_state);

    for (tx.lifecycle_accounts.items) |id| {
        const account_ref: AccountRef = .{ .id = id, .row = tx.accounts.valuePtrById(id) };
        const row = account_ref.row;
        if (!row.flags.selfdestructed) {
            if (row.flags.created) {
                try self.appendAccountUndo(account_ref);
                row.flags.created = false;
            }
            continue;
        }

        const policy = if (row.flags.created)
            rules.created_account
        else
            rules.existing_account;
        const first_change = !row.flags.dirty;
        try self.appendAccountUndo(account_ref);
        if (policy.clear_storage) try self.wipeStorage(account_ref);
        if (first_change and (policy.reset_account or policy.delete_account)) {
            tx.changed_accounts.appendAssumeCapacity(id);
        }
        if (policy.reset_account) {
            var account = switch (row.current.?) {
                .absent => Account{},
                .present => |value| value,
                .exists_only => unreachable,
            };
            account.nonce = 0;
            account.code_hash = crypto.keccak256_empty;
            // A reset account holding no balance is EIP-161 empty: drop the leaf
            // instead of keeping a zero account the state root would not carry.
            const emptied = account.balance == 0;
            if (accountObservation(tx, row)) |observation| {
                observation.effect.nonce_written = true;
                observation.effect.code_written = true;
                if (emptied) observation.effect.account_deleted = true;
            }
            row.current = if (emptied) .absent else .{ .present = account };
            row.flags.dirty = true;
        }
        if (policy.delete_account) {
            row.current = .absent;
            if (accountObservation(tx, row)) |observation|
                observation.effect.account_deleted = true;
            row.flags.dirty = true;
        }
        row.flags.created = false;
        row.flags.selfdestructed = false;
    }
    self.commitCheckpoint(checkpoint_state);
}

pub fn discardAccepted(self: *TrackedState) void {
    std.debug.assert(self.tx == null);
    const reader = self.reader;
    self.reset(reader);
}

pub fn journalEntryCount(self: *const TrackedState) usize {
    const tx = self.tx orelse return 0;
    return tx.journal.entries.items.len;
}

/// Hide every accepted and transaction slot of the address. Assumes `finalize`
/// reserved `storage_wipes` capacity and journaled the account row.
fn wipeStorage(self: *TrackedState, account_ref: AccountRef) !void {
    const tx = &self.tx.?;
    const row = account_ref.row;
    const address = tx.accounts.keyById(account_ref.id).*;
    var it = tx.storage.iterator();
    while (it.next()) |entry| {
        if (!Address.eql(entry.key_ptr.address, address)) continue;
        try self.appendStorageUndo(.{ .id = entry.entry_id, .row = entry.value_ptr });
        entry.value_ptr.current = 0;
        entry.value_ptr.flags.dirty = true;
    }
    if (!row.flags.storage_wiped) tx.storage_wipes.appendAssumeCapacity(account_ref.id);
    row.flags.storage_wiped = true;
    if (accountObservation(tx, row)) |observation| observation.effect.storage_wiped = true;
}

fn mutableTransaction(self: *TrackedState) *Transaction {
    std.debug.assert(self.tx != null);
    const tx = &self.tx.?;
    std.debug.assert(!tx.sealed);
    return tx;
}

fn sealedTransaction(self: *const TrackedState) *const Transaction {
    const tx = if (self.tx) |*value| value else unreachable;
    std.debug.assert(tx.sealed);
    std.debug.assert(!tx.scope.active);
    return tx;
}

fn assertCurrent(self: *TrackedState, id: AttemptId) *Transaction {
    std.debug.assert(self.tx != null);
    const tx = &self.tx.?;
    std.debug.assert(tx.id == id);
    return tx;
}

fn validateCheckpoint(self: *TrackedState, checkpoint_state: Checkpoint) void {
    const tx = self.mutableTransaction();
    std.debug.assert(tx.scope.active);
    std.debug.assert(tx.scope.depth != 0);
    std.debug.assert(checkpoint_state.attempt_id == tx.id);
    std.debug.assert(checkpoint_state.scope_generation == tx.scope.generation);
    std.debug.assert(checkpoint_state.journal_len <= tx.journal.entries.items.len);
    std.debug.assert(checkpoint_state.changed_accounts_len <= tx.changed_accounts.items.len);
    std.debug.assert(checkpoint_state.changed_storage_len <= tx.changed_storage.items.len);
    std.debug.assert(checkpoint_state.storage_wipes_len <= tx.storage_wipes.items.len);
    std.debug.assert(checkpoint_state.logs.rows_len <= tx.logs.rows.items.len);
    std.debug.assert(checkpoint_state.logs.topics_len <= tx.logs.topics.items.len);
    std.debug.assert(checkpoint_state.logs.data_len <= tx.logs.data.items.len);
}

fn discardActive(self: *TrackedState) void {
    if (self.tx) |tx| {
        var resolved = tx;
        if (self.transaction_reuse_active) {
            std.debug.assert(self.cached_tx == null);
            resolved.reset(resolved.id, resolved.observe);
            self.cached_tx = resolved;
        } else {
            resolved.deinit(self.allocator);
        }
    }
    self.tx = null;
}

fn revertJournalTo(self: *TrackedState, target_len: u32) void {
    const tx = &self.tx.?;
    while (tx.journal.entries.items.len > target_len) {
        const entry = tx.journal.entries.pop().?;
        switch (entry) {
            .account, .observed_account => |undo_id| {
                std.debug.assert(@intFromEnum(undo_id) + 1 == tx.journal.accounts.items.len);
                const undo = tx.journal.accounts.pop().?;
                const row = tx.accounts.valuePtrById(undo.account);
                row.current = undo.current;
                row.flags = undo.flags;
                if (entry == .observed_account) {
                    const observation_undo = tx.journal.account_observations.pop().?;
                    const observation = &tx.observed_accounts.items[@intFromEnum(observation_undo.observation)];
                    observation.effect_current = observation_undo.effect_current;
                    observation.effect = observation_undo.effect;
                }
            },
            .storage, .observed_storage => |undo_id| {
                std.debug.assert(@intFromEnum(undo_id) + 1 == tx.journal.storage.items.len);
                const undo = tx.journal.storage.pop().?;
                const row = tx.storage.valuePtrById(undo.storage);
                row.current = undo.current;
                row.flags = undo.flags;
                if (entry == .observed_storage) {
                    const observation_undo = tx.journal.storage_observations.pop().?;
                    const observation = &tx.observed_storage.items[@intFromEnum(observation_undo.observation)];
                    observation.effect_current = observation_undo.effect_current;
                    observation.effect = observation_undo.effect;
                }
            },
            .warm_account => |id| _ = tx.scope.warm_accounts.remove(tx.accounts.keyById(id).*),
            .warm_storage => |id| tx.scope.storage.getPtr(tx.storage.keyById(id).*).?.warm = false,
            .transient_storage => |undo_id| {
                std.debug.assert(@intFromEnum(undo_id) + 1 == tx.journal.transient.items.len);
                const undo = tx.journal.transient.pop().?;
                tx.scope.transient_storage.putAssumeCapacity(undo.key, undo.previous);
            },
        }
    }
}

fn acceptedAccountExistence(self: *TrackedState, address: Address) !AccountValue {
    if (self.accepted.accounts.get(address)) |row| return row.value;
    // When the fork has no empty accounts, existence is aliveness, which the
    // fields decide. Readers answer both questions from the same trie leaf, so
    // resolving the account here costs nothing over asking for a bare bool.
    if (!self.retains_empty_accounts) return self.loadAcceptedAccount(address);

    const exists = if (self.reader) |reader| try reader.accountExists(address) else false;
    const value: AccountValue = if (exists) .exists_only else .absent;
    try self.accepted.accounts.put(address, .{ .value = value });
    return value;
}

/// The fork half of EIP-161 emptiness. The value half is `Account.isEip161Empty`.
fn dropsEmptyAccount(self: *const TrackedState, account: Account) bool {
    if (self.retains_empty_accounts) return false;
    return account.isEip161Empty();
}

fn loadAcceptedAccount(self: *TrackedState, address: Address) !AccountValue {
    // One probe serves the hit check and the write-back: neither the reader
    // nor emptiness resolution touches the accepted map, so the row pointer
    // stays valid across the load.
    const existing = self.accepted.accounts.getPtr(address);
    if (existing) |row| {
        switch (row.value) {
            .absent, .present => return row.value,
            .exists_only => {},
        }
    }
    const loaded = if (self.reader) |reader| try reader.loadAccount(address) else null;
    const value: AccountValue = if (loaded) |account|
        if (self.dropsEmptyAccount(account)) .absent else .{ .present = account }
    else
        .absent;
    if (existing) |row| {
        row.value = value;
    } else {
        try self.accepted.accounts.put(address, .{ .value = value });
    }
    return value;
}

fn readAccount(
    self: *TrackedState,
    address: Address,
    observation: AccountObservation,
) !AccountValue {
    if (self.tx == null) return self.loadAcceptedAccount(address);
    if (self.tx.?.sealed) {
        if (self.tx.?.accounts.get(address)) |row| {
            if (row.current) |value| switch (value) {
                .absent, .present => return value,
                .exists_only => {},
            };
        }
        return self.loadAcceptedAccount(address);
    }
    const account_ref = try self.materializeTransactionAccount(address);
    _ = try self.observeAccount(account_ref, observation);
    return account_ref.row.current.?;
}

fn transactionAccountRef(_: *TrackedState, tx: *Transaction, address: Address) !AccountRef {
    const result = try tx.accounts.getOrPut(address);
    if (!result.found_existing) result.value_ptr.* = .{};
    return .{ .id = result.entry_id, .row = result.value_ptr };
}

fn materializeTransactionAccount(self: *TrackedState, address: Address) !AccountRef {
    const tx = self.mutableTransaction();
    const account_ref = try self.transactionAccountRef(tx, address);
    const row = account_ref.row;
    const needs_load = if (row.current) |current| switch (current) {
        .absent, .present => false,
        .exists_only => true,
    } else true;
    if (!needs_load) return account_ref;

    std.debug.assert(!row.flags.dirty);
    const value = try self.loadAcceptedAccount(address);
    if (row.original == null or row.original.? == .exists_only) row.original = value;
    row.current = value;
    return account_ref;
}

/// Merge `observation` into the row's observation, creating it on first touch.
/// Null when the transaction does not observe.
inline fn observeAccount(
    self: *TrackedState,
    account_ref: AccountRef,
    observation: AccountObservation,
) Allocator.Error!?*AccountObservationRow {
    const tx = &self.tx.?;
    if (!tx.observe) return null;
    if (account_ref.row.observation_id == null) {
        try tx.observed_accounts.ensureUnusedCapacity(self.allocator, 1);
        account_ref.row.observation_id = @enumFromInt(tx.observed_accounts.items.len);
        tx.observed_accounts.appendAssumeCapacity(.{ .account = account_ref.id });
    }
    const observed = &tx.observed_accounts.items[@intFromEnum(account_ref.row.observation_id.?)];
    observed.observation.merge(observation);
    return observed;
}

inline fn observeStorage(
    self: *TrackedState,
    storage_ref: StorageRef,
    observation: StorageObservation,
) Allocator.Error!?*StorageObservationRow {
    const tx = &self.tx.?;
    if (!tx.observe) return null;
    if (storage_ref.row.observation_id == null) {
        try tx.observed_storage.ensureUnusedCapacity(self.allocator, 1);
        storage_ref.row.observation_id = @enumFromInt(tx.observed_storage.items.len);
        tx.observed_storage.appendAssumeCapacity(.{ .storage = storage_ref.id });
    }
    const observed = &tx.observed_storage.items[@intFromEnum(storage_ref.row.observation_id.?)];
    observed.observation.merge(observation);
    return observed;
}

/// The row's observation without merging; null when unobserved.
inline fn accountObservation(tx: *Transaction, row: *const AccountRow) ?*AccountObservationRow {
    const id = row.observation_id orelse return null;
    return &tx.observed_accounts.items[@intFromEnum(id)];
}

fn accountValue(value: AccountValue) ?Account {
    return switch (value) {
        .absent, .exists_only => null,
        .present => |account| account,
    };
}

fn codeByHash(self: *TrackedState, code_hash: CodeHash) ![]const u8 {
    if (std.mem.eql(u8, &code_hash, &crypto.keccak256_empty)) return &.{};
    if (self.code.entries.get(code_hash)) |entry| return entry.slice(&self.code);
    const reader = self.reader orelse return error.CodeUnavailable;
    const code = try reader.loadCode(code_hash);
    return self.cacheCode(code_hash, code, false);
}

fn cacheCode(
    self: *TrackedState,
    code_hash: CodeHash,
    code_bytes: []const u8,
    introduced: bool,
) ![]const u8 {
    std.debug.assert(std.mem.eql(u8, &crypto.keccak256(code_bytes), &code_hash));
    if (std.mem.eql(u8, &code_hash, &crypto.keccak256_empty)) return &.{};
    if (self.code.entries.get(code_hash)) |entry| return entry.slice(&self.code);
    std.debug.assert(code_bytes.len <= std.math.maxInt(u32));

    try self.code.entries.ensureUnusedCapacity(1);
    const tail_index = if (self.code.chunks.items.len == 0)
        null
    else
        self.code.chunks.items.len - 1;
    const chunk_index = if (tail_index) |index| blk: {
        const chunk = &self.code.chunks.items[index];
        const used: usize = chunk.used;
        if (code_bytes.len <= chunk.bytes.len - used) break :blk index;
        break :blk try self.appendCodeChunk(code_bytes.len);
    } else try self.appendCodeChunk(code_bytes.len);

    const chunk = &self.code.chunks.items[chunk_index];
    const code_range: ByteRange = .init(@as(usize, chunk.used), code_bytes.len);
    const entry = CodeEntry.init(chunk_index, code_range, introduced);
    const start: usize = chunk.used;
    @memcpy(chunk.bytes[start..][0..code_bytes.len], code_bytes);
    chunk.used += code_range.len;
    self.code.entries.putAssumeCapacityNoClobber(code_hash, entry);
    self.code.used_bytes += code_bytes.len;
    return entry.slice(&self.code);
}

fn appendCodeChunk(self: *TrackedState, required_bytes: usize) !usize {
    const chunk_index = self.code.chunks.items.len;
    _ = CodeEntry.init(chunk_index, .{}, false);
    try self.code.chunks.ensureUnusedCapacity(self.allocator, 1);
    const capacity = @max(required_bytes, minimum_code_chunk_bytes);
    const bytes = try self.allocator.alloc(u8, capacity);
    self.code.chunks.appendAssumeCapacity(.{ .bytes = bytes, .used = 0 });
    return chunk_index;
}

fn readAcceptedStorage(self: *TrackedState, key: StorageKey) !u256 {
    // One probe serves every branch; the wipe check probes the accounts map
    // only when some accepted account was actually wiped (the flag is set
    // exactly where `storage_wipes` appends, so the list length gates it).
    const existing = self.accepted.storage.getPtr(key);
    if (existing) |row| {
        if (row.changed) return row.value;
    }
    if (self.accepted.storage_wipes.items.len != 0 and
        acceptedStorageWiped(&self.accepted, key.address)) return 0;
    if (existing) |row| return row.value;
    const value = if (self.reader) |reader|
        try reader.getStorage(key.address, key.key)
    else
        0;
    try self.accepted.storage.put(key, .{ .value = value });
    return value;
}

fn transactionStorageRef(_: *TrackedState, tx: *Transaction, key: StorageKey) !StorageRef {
    const result = try tx.storage.getOrPut(key);
    if (!result.found_existing) result.value_ptr.* = .{};
    return .{ .id = result.entry_id, .row = result.value_ptr };
}

fn scopeStorageRef(_: *TrackedState, tx: *Transaction, key: StorageKey) !*ScopeStorage {
    const result = try tx.scope.storage.getOrPut(key);
    if (!result.found_existing) result.value_ptr.* = .{};
    return result.value_ptr;
}

fn materializeTransactionStorage(self: *TrackedState, key: StorageKey) !StorageRef {
    const tx = self.mutableTransaction();
    const storage_ref = try self.transactionStorageRef(tx, key);
    try self.loadStorageRef(key, storage_ref);
    return storage_ref;
}

fn loadStorageRef(self: *TrackedState, key: StorageKey, storage_ref: StorageRef) !void {
    if (storage_ref.row.current != null) return;

    const value = try self.readAcceptedStorage(key);
    storage_ref.row.transaction_original = value;
    if (transactionStorageWiped(&self.tx.?, key.address)) {
        try self.appendStorageUndo(storage_ref);
        storage_ref.row.current = 0;
    } else {
        storage_ref.row.current = value;
    }
}

fn captureExecutionOriginal(scope_storage: *ScopeStorage, storage_ref: StorageRef) void {
    if (scope_storage.execution_original != null) return;
    scope_storage.execution_original = storage_ref.row.current.?;
}

fn accessStorageKey(self: *TrackedState, key: StorageKey) !StorageAccess {
    const access = try self.ensureStorageWarm(key);
    _ = try self.observeStorage(access.storage, .{ .accessed = true });
    return access;
}

fn setResolvedStorage(
    self: *TrackedState,
    storage_key: StorageKey,
    storage_ref: StorageRef,
    scope_storage: *ScopeStorage,
    value: u256,
) !execution.StorageStatus {
    const observation = try self.observeStorage(storage_ref, .{ .accessed = true, .value_read = true });
    captureExecutionOriginal(scope_storage, storage_ref);
    const row = storage_ref.row;
    const current = row.current.?;
    const status = storageStatus(scope_storage.execution_original.?, current, value);
    if (current == value) return status;

    // Wipes are recorded only by finalization, which follows every execution
    // write; compaction relies on this order to drop a wiped address's writes.
    const tx = &self.tx.?;
    std.debug.assert(!transactionStorageWiped(tx, storage_key.address));
    const first_change = !row.flags.dirty;
    if (first_change) try self.reserveAcceptedStorageMutation(storage_key);
    try self.appendStorageUndo(storage_ref);
    if (first_change) tx.changed_storage.appendAssumeCapacity(storage_ref.id);
    row.current = value;
    row.flags.dirty = true;
    if (observation) |observed| observed.effect.written = true;
    return status;
}

fn ensureAccountWarm(self: *TrackedState, address: Address) !AccountAccess {
    const tx = self.mutableTransaction();
    std.debug.assert(tx.scope.active);
    const account_ref = try self.transactionAccountRef(tx, address);
    if (tx.scope.warm_accounts.contains(address)) return .{ .account = account_ref, .status = .warm };
    try tx.scope.warm_accounts.ensureUnusedCapacity(1);
    try tx.journal.ensureWarm(self.allocator);
    tx.journal.entries.appendAssumeCapacity(.{ .warm_account = account_ref.id });
    tx.scope.warm_accounts.putAssumeCapacityNoClobber(address, {});
    return .{ .account = account_ref, .status = .cold };
}

fn ensureStorageWarm(self: *TrackedState, key: StorageKey) !StorageAccess {
    const tx = self.mutableTransaction();
    std.debug.assert(tx.scope.active);
    const storage_ref = try self.transactionStorageRef(tx, key);
    const scope_storage = try self.scopeStorageRef(tx, key);
    if (scope_storage.warm) return .{ .storage = storage_ref, .scope = scope_storage, .status = .warm };
    try tx.journal.ensureWarm(self.allocator);
    tx.journal.entries.appendAssumeCapacity(.{ .warm_storage = storage_ref.id });
    scope_storage.warm = true;
    return .{ .storage = storage_ref, .scope = scope_storage, .status = .cold };
}

/// Reserve, journal, and list the row for its first change in this
/// transaction; the caller applies the change to the returned row.
fn prepareAccountMutation(self: *TrackedState, account_ref: AccountRef) !*AccountRow {
    const tx = &self.tx.?;
    const row = account_ref.row;
    const first_change = !row.flags.dirty;
    if (first_change) try self.reserveAcceptedAccountMutation(tx.accounts.keyById(account_ref.id).*);
    try self.appendAccountUndo(account_ref);
    if (first_change) tx.changed_accounts.appendAssumeCapacity(account_ref.id);
    row.flags.dirty = true;
    return row;
}

/// Lifecycle marks are not dirty changes: the row is listed for `finalize`
/// and journaled, but never enters `changed_accounts` on its own.
fn prepareLifecycleMutation(self: *TrackedState, account_ref: AccountRef) !*AccountRow {
    const tx = &self.tx.?;
    const row = account_ref.row;
    if (!row.flags.lifecycle_listed) {
        try tx.lifecycle_accounts.ensureUnusedCapacity(self.allocator, 1);
        tx.lifecycle_accounts.appendAssumeCapacity(account_ref.id);
        row.flags.lifecycle_listed = true;
    }
    try self.appendAccountUndo(account_ref);
    return row;
}

fn reserveAcceptedAccountMutation(self: *TrackedState, address: Address) !void {
    const tx = &self.tx.?;
    try tx.changed_accounts.ensureUnusedCapacity(self.allocator, 1);
    const row = self.accepted.accounts.get(address).?;
    if (!row.changed) {
        try self.accepted.changed_accounts.ensureUnusedCapacity(
            self.allocator,
            tx.changed_accounts.items.len + 1,
        );
    }
}

fn reserveAcceptedStorageMutation(self: *TrackedState, key: StorageKey) !void {
    const tx = &self.tx.?;
    try tx.changed_storage.ensureUnusedCapacity(self.allocator, 1);
    const accepted = self.accepted.storage.get(key);
    if (accepted == null) try self.accepted.storage.ensureUnusedCapacity(1);
    if (accepted == null or !accepted.?.changed) {
        try self.accepted.changed_storage.ensureUnusedCapacity(
            self.allocator,
            tx.changed_storage.items.len + 1,
        );
    }
}

/// Journal the row once per scope entry point; a no-op outside the scope root
/// because nothing can revert there.
fn appendAccountUndo(self: *TrackedState, account_ref: AccountRef) !void {
    const tx = &self.tx.?;
    if (!tx.scope.active) return;
    const row = account_ref.row;
    const observation_undo: ?Journal.AccountObservationUndo =
        if (accountObservation(tx, row)) |observation| .{
            .observation = row.observation_id.?,
            .effect_current = observation.effect_current,
            .effect = observation.effect,
        } else null;
    try tx.journal.ensureAccount(self.allocator, observation_undo != null);
    tx.journal.appendAccountAssumeCapacity(.{
        .account = account_ref.id,
        .current = row.current,
        .flags = row.flags,
    }, observation_undo);
}

fn appendStorageUndo(self: *TrackedState, storage_ref: StorageRef) !void {
    const tx = &self.tx.?;
    const row = storage_ref.row;
    const observation_undo: ?Journal.StorageObservationUndo =
        if (row.observation_id) |id| blk: {
            const observation = &tx.observed_storage.items[@intFromEnum(id)];
            break :blk .{
                .observation = id,
                .effect_current = observation.effect_current,
                .effect = observation.effect,
            };
        } else null;
    try tx.journal.ensureStorage(self.allocator, observation_undo != null);
    tx.journal.appendStorageAssumeCapacity(.{
        .storage = storage_ref.id,
        .current = row.current,
        .flags = row.flags,
    }, observation_undo);
}

fn transactionStorageWiped(tx: *const Transaction, address: Address) bool {
    const row = tx.accounts.get(address) orelse return false;
    return row.flags.storage_wiped;
}

fn transactionDeletesAccount(tx: *const Transaction, address: Address) bool {
    const row = tx.accounts.get(address) orelse return false;
    if (!row.flags.dirty) return false;
    return row.current.? == .absent;
}

fn acceptedStorageWiped(accepted: *const Accepted, address: Address) bool {
    const row = accepted.accounts.get(address) orelse return false;
    return row.storage_wiped;
}

/// Drop writes under a wiped or deleted address so the transaction delta
/// carries only slots the retained branch will keep.
fn compactTransactionStorageChanges(tx: *Transaction) void {
    var write: usize = 0;
    for (tx.changed_storage.items) |id| {
        const key = tx.storage.keyById(id).*;
        if (transactionStorageWiped(tx, key.address) or
            transactionDeletesAccount(tx, key.address)) continue;
        tx.changed_storage.items[write] = id;
        write += 1;
    }
    tx.changed_storage.items.len = write;
}

/// Unlist every accepted slot of the address; a wipe or deletion supersedes
/// the writes it carried.
fn compactAcceptedStorageChanges(accepted: *Accepted, address: Address) void {
    var write: usize = 0;
    for (accepted.changed_storage.items) |id| {
        const key = accepted.storage.keyById(id).*;
        if (Address.eql(key.address, address)) {
            accepted.storage.valuePtrById(id).changed = false;
            continue;
        }
        accepted.changed_storage.items[write] = id;
        write += 1;
    }
    accepted.changed_storage.items.len = write;
}

test {
    _ = @import("./TrackedState_test.zig");
}
