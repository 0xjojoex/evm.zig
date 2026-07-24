//! Transaction-tracked execution state.
//!
//! Accepted branch state, transaction-attempt rows, and execution-scope state
//! have distinct ownership. Transaction rows retain first-touch originals and
//! observations across inner rollback; the scope journal restores only current
//! values and scope-local semantics. Semantic observations are an opt-in
//! transaction sidecar; normal execution does not allocate or journal them.

const std = @import("std");
const Address = @import("../address.zig").Address;
const crypto = @import("../crypto.zig");
const execution = @import("../execution.zig");
const Host = @import("../Host.zig");
const Account = @import("./Account.zig");
const MemoryAccount = @import("./MemoryAccount.zig");
const StateReader = @import("./Reader.zig");
const storage = @import("./storage.zig");
const SparseHashMap = @import("./sparse_hash_map.zig").Auto;

const TrackedState = @This();
const StorageKey = storage.Key;
const CodeHash = [32]u8;

const AddressSet = SparseHashMap(Address, void);
const CodeHashSet = SparseHashMap(CodeHash, void);
const AcceptedAccountMap = SparseHashMap(Address, AcceptedAccountRow);
const AcceptedStorageMap = SparseHashMap(StorageKey, AcceptedStorageRow);
const TransactionAccountMap = SparseHashMap(Address, AccountRow);
const TransactionStorageMap = SparseHashMap(StorageKey, StorageRow);
const ScopeStorageMap = SparseHashMap(StorageKey, ScopeStorage);
const TransientStorageMap = SparseHashMap(StorageKey, u256);
const CodeMap = SparseHashMap(CodeHash, CodeEntry);
const minimum_code_chunk_bytes = 4096;

pub const AccountId = TransactionAccountMap.EntryId;
pub const StorageId = TransactionStorageMap.EntryId;
pub const AcceptedAccountId = AcceptedAccountMap.EntryId;
pub const AcceptedStorageId = AcceptedStorageMap.EntryId;
const AccountObservationId = enum(u32) { _ };
const StorageObservationId = enum(u32) { _ };

const AccountRef = struct {
    id: AccountId,
    row: *AccountRow,
};

const AccountAccess = struct {
    id: AccountId,
    row: *AccountRow,
    status: Host.AccessStatus,
};

const StorageRef = struct {
    id: StorageId,
    row: *StorageRow,
};

const StorageAccess = struct {
    storage: StorageRef,
    scope: *ScopeStorage,
    status: Host.AccessStatus,
};

pub const ByteRange = struct {
    offset: u32 = 0,
    len: u32 = 0,

    pub fn slice(self: ByteRange, bytes: []const u8) []const u8 {
        const offset: usize = self.offset;
        const len: usize = self.len;
        std.debug.assert(offset + len <= bytes.len);
        return bytes[offset..][0..len];
    }
};

pub const TopicRange = struct {
    offset: u32 = 0,
    len: u8 = 0,

    pub fn slice(self: TopicRange, topics: []const u256) []const u256 {
        const offset: usize = self.offset;
        const len: usize = self.len;
        std.debug.assert(offset + len <= topics.len);
        return topics[offset..][0..len];
    }
};

allocator: std.mem.Allocator,
reader: ?StateReader,
epoch: u64,
generation: u64,
next_attempt_id: u64,
accepted: Accepted,
code: CodeCache,
tx: ?Transaction,
retained_logs: LogBuffer,

pub const AttemptId = enum(u64) { _ };

pub const FinalizationRules = struct {
    existing_account: execution.SelfDestructFinalization = .{},
    created_account: execution.SelfDestructFinalization = .{},
};

pub const AccountValue = union(enum) {
    absent,
    exists_only,
    loaded: Account,

    fn exists(self: AccountValue) bool {
        return switch (self) {
            .absent => false,
            .exists_only, .loaded => true,
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

pub const AccountObservation = packed struct {
    listed: bool = false,
    accessed: bool = false,
    semantic_access: bool = false,
    existence_read: bool = false,
    value_read: bool = false,
    code_read: bool = false,
};

/// Checkpoint-resolved account effects used by observation projectors.
/// Access flags live separately because reads survive inner rollback.
pub const AccountEffect = packed struct {
    balance_written: bool = false,
    nonce_written: bool = false,
    code_written: bool = false,
    created_contract: bool = false,
    selfdestruct: bool = false,
    account_deleted: bool = false,
    storage_wiped: bool = false,

    pub fn any(self: AccountEffect) bool {
        return self.balance_written or
            self.nonce_written or
            self.code_written or
            self.created_contract or
            self.selfdestruct or
            self.account_deleted or
            self.storage_wiped;
    }
};

pub const AccountMutation = packed struct {
    touched: bool = false,
    dirty: bool = false,
    created: bool = false,
    selfdestructed: bool = false,
    delete_on_finalize: bool = false,
    storage_wiped: bool = false,
    lifecycle_tracked: bool = false,
};

pub const AccountRow = struct {
    original: ?AccountValue = null,
    current: ?AccountValue = null,
    observation_id: ?AccountObservationId = null,
    mutation: AccountMutation = .{},
};

pub const StorageObservation = packed struct {
    listed: bool = false,
    accessed: bool = false,
    value_read: bool = false,
};

pub const StorageEffect = packed struct {
    written: bool = false,
};

pub const StorageMutation = packed struct {
    dirty: bool = false,
};

pub const StorageRow = struct {
    transaction_original: ?u256 = null,
    current: ?u256 = null,
    observation_id: ?StorageObservationId = null,
    mutation: StorageMutation = .{},
};

const AccountObservationRow = struct {
    account: AccountId,
    /// Last field-level state before a lifecycle deletion hides it.
    effect_current: ?AccountValue = null,
    observation: AccountObservation = .{ .listed = true },
    effect: AccountEffect = .{},
};

const StorageObservationRow = struct {
    storage: StorageId,
    /// Last semantic value before an address-level lifecycle wipe hides it.
    effect_current: ?u256 = null,
    observation: StorageObservation = .{ .listed = true },
    effect: StorageEffect = .{},
};

pub const ScopeStorage = struct {
    execution_original: ?u256 = null,
    warm: bool = false,
};

pub const Accepted = struct {
    accounts: AcceptedAccountMap,
    storage: AcceptedStorageMap,
    changed_accounts: std.ArrayList(AcceptedAccountId),
    changed_storage: std.ArrayList(AcceptedStorageId),
    storage_wipes: std.ArrayList(AcceptedAccountId),
    introduced_code: CodeHashSet,

    fn init(allocator: std.mem.Allocator) Accepted {
        return .{
            .accounts = AcceptedAccountMap.init(allocator),
            .storage = AcceptedStorageMap.init(allocator),
            .changed_accounts = .empty,
            .changed_storage = .empty,
            .storage_wipes = .empty,
            .introduced_code = CodeHashSet.init(allocator),
        };
    }

    fn deinit(self: *Accepted, allocator: std.mem.Allocator) void {
        self.accounts.deinit();
        self.storage.deinit();
        self.changed_accounts.deinit(allocator);
        self.changed_storage.deinit(allocator);
        self.storage_wipes.deinit(allocator);
        self.introduced_code.deinit();
        self.* = undefined;
    }

    fn clone(self: *const Accepted, allocator: std.mem.Allocator) !Accepted {
        var accounts = try self.accounts.clone(allocator);
        errdefer accounts.deinit();
        var storage_map = try self.storage.clone(allocator);
        errdefer storage_map.deinit();
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
            .storage = storage_map,
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

pub const CodeChunk = struct {
    bytes: []u8,
    used: u32,
};

pub const CodeCache = struct {
    entries: CodeMap,
    chunks: std.ArrayList(CodeChunk),
    used_bytes: usize,

    fn init(allocator: std.mem.Allocator) CodeCache {
        return .{
            .entries = CodeMap.init(allocator),
            .chunks = .empty,
            .used_bytes = 0,
        };
    }

    fn deinit(self: *CodeCache, allocator: std.mem.Allocator) void {
        self.entries.deinit();
        for (self.chunks.items) |chunk| allocator.free(chunk.bytes);
        self.chunks.deinit(allocator);
        self.* = undefined;
    }
};

/// Canonical code resolved for execution. The borrowed bytes remain stable for
/// the lifetime of the tracked state, including across cache growth.
pub const CodeView = struct {
    code_hash: CodeHash,
    bytes: []const u8,
};

pub const AccountChange = struct {
    address: Address,
    account: ?Account,
};

pub const StorageChange = struct {
    address: Address,
    key: u256,
    value: u256,
};

const ChangeLayer = enum {
    accepted,
    transaction,
};

pub const AccountChanges = struct {
    handle: *const anyopaque,
    layer: ChangeLayer,

    pub fn len(self: AccountChanges) u32 {
        const state = self.tracked();
        return switch (self.layer) {
            .accepted => @intCast(state.accepted.changed_accounts.items.len),
            .transaction => @intCast(self.transaction().changed_accounts.items.len),
        };
    }

    pub fn at(self: AccountChanges, index: u32) AccountChange {
        std.debug.assert(index < self.len());
        const state = self.tracked();
        return switch (self.layer) {
            .accepted => blk: {
                const id = state.accepted.changed_accounts.items[index];
                const entry = state.accepted.accounts.entryAt(@intFromEnum(id));
                break :blk .{
                    .address = entry.key_ptr.*,
                    .account = accountValue(entry.value_ptr.value),
                };
            },
            .transaction => blk: {
                const tx = self.transaction();
                const id = tx.changed_accounts.items[index];
                const entry = tx.accounts.entryAt(@intFromEnum(id));
                break :blk .{
                    .address = entry.key_ptr.*,
                    .account = accountValue(entry.value_ptr.current orelse unreachable),
                };
            },
        };
    }

    fn tracked(self: AccountChanges) *const TrackedState {
        return @ptrCast(@alignCast(self.handle));
    }

    fn transaction(self: AccountChanges) *const Transaction {
        return sealedTransaction(self.tracked());
    }
};

pub const StorageChanges = struct {
    handle: *const anyopaque,
    layer: ChangeLayer,

    pub fn len(self: StorageChanges) u32 {
        const state = self.tracked();
        return switch (self.layer) {
            .accepted => @intCast(state.accepted.changed_storage.items.len),
            .transaction => @intCast(self.transaction().changed_storage.items.len),
        };
    }

    pub fn at(self: StorageChanges, index: u32) StorageChange {
        std.debug.assert(index < self.len());
        const state = self.tracked();
        return switch (self.layer) {
            .accepted => blk: {
                const id = state.accepted.changed_storage.items[index];
                const entry = state.accepted.storage.entryAt(@intFromEnum(id));
                break :blk .{
                    .address = entry.key_ptr.address,
                    .key = entry.key_ptr.key,
                    .value = entry.value_ptr.value,
                };
            },
            .transaction => blk: {
                const tx = self.transaction();
                const id = tx.changed_storage.items[index];
                const entry = tx.storage.entryAt(@intFromEnum(id));
                break :blk .{
                    .address = entry.key_ptr.address,
                    .key = entry.key_ptr.key,
                    .value = entry.value_ptr.current orelse unreachable,
                };
            },
        };
    }

    fn tracked(self: StorageChanges) *const TrackedState {
        return @ptrCast(@alignCast(self.handle));
    }

    fn transaction(self: StorageChanges) *const Transaction {
        return sealedTransaction(self.tracked());
    }
};

pub const StorageWipes = struct {
    handle: *const anyopaque,
    layer: ChangeLayer,

    pub fn len(self: StorageWipes) u32 {
        const state = self.tracked();
        return switch (self.layer) {
            .accepted => @intCast(state.accepted.storage_wipes.items.len),
            .transaction => @intCast(self.transaction().storage_wipes.items.len),
        };
    }

    pub fn at(self: StorageWipes, index: u32) Address {
        std.debug.assert(index < self.len());
        const state = self.tracked();
        return switch (self.layer) {
            .accepted => state.accepted.accounts
                .entryAt(@intFromEnum(state.accepted.storage_wipes.items[index]))
                .key_ptr.*,
            .transaction => blk: {
                const tx = self.transaction();
                break :blk tx.accounts
                    .entryAt(@intFromEnum(tx.storage_wipes.items[index]))
                    .key_ptr.*;
            },
        };
    }

    fn tracked(self: StorageWipes) *const TrackedState {
        return @ptrCast(@alignCast(self.handle));
    }

    fn transaction(self: StorageWipes) *const Transaction {
        return sealedTransaction(self.tracked());
    }
};

/// Borrowed semantic delta. Ordering is unspecified; consumers own sorting,
/// allocation, persistence batches, and any retained representation.
pub const ChangesView = struct {
    handle: *const anyopaque,
    layer: ChangeLayer,
    accounts: AccountChanges,
    storage_writes: StorageChanges,
    storage_wipes: StorageWipes,

    fn init(state: *const TrackedState, layer: ChangeLayer) ChangesView {
        return .{
            .handle = state,
            .layer = layer,
            .accounts = .{ .handle = state, .layer = layer },
            .storage_writes = .{ .handle = state, .layer = layer },
            .storage_wipes = .{ .handle = state, .layer = layer },
        };
    }

    pub fn introducedCode(self: ChangesView, code_hash: CodeHash) ?CodeView {
        const state = self.tracked();
        const introduced = switch (self.layer) {
            .accepted => state.accepted.introduced_code.contains(code_hash),
            .transaction => sealedTransaction(state).introduced_code.contains(code_hash),
        };
        if (!introduced) return null;
        const entry = state.code.entries.get(code_hash) orelse unreachable;
        return .{ .code_hash = code_hash, .bytes = entry.slice(&state.code) };
    }

    pub fn hasChanges(self: ChangesView) bool {
        return self.accounts.len() != 0 or
            self.storage_writes.len() != 0 or
            self.storage_wipes.len() != 0;
    }

    fn tracked(self: ChangesView) *const TrackedState {
        return @ptrCast(@alignCast(self.handle));
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

/// Dense transaction-local account facts. Ordering is internal; projectors own
/// sorting and any retained representation.
pub const AccountObservations = struct {
    handle: *const anyopaque,

    pub fn len(self: AccountObservations) u32 {
        return @intCast(self.transaction().observed_accounts.items.len);
    }

    pub fn at(self: AccountObservations, index: u32) AccountObservationFact {
        std.debug.assert(index < self.len());
        const tx = self.transaction();
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

    fn transaction(self: AccountObservations) *const Transaction {
        return sealedTransaction(self.tracked());
    }

    fn tracked(self: AccountObservations) *const TrackedState {
        return @ptrCast(@alignCast(self.handle));
    }
};

/// Dense transaction-local storage facts. Every row has a transaction original
/// and a checkpoint-resolved current value.
pub const StorageObservations = struct {
    handle: *const anyopaque,

    pub fn len(self: StorageObservations) u32 {
        return @intCast(self.transaction().observed_storage.items.len);
    }

    pub fn at(self: StorageObservations, index: u32) StorageObservationFact {
        std.debug.assert(index < self.len());
        const tx = self.transaction();
        const observed = &tx.observed_storage.items[index];
        const entry = tx.storage.entryAt(@intFromEnum(observed.storage));
        return .{
            .address = entry.key_ptr.address,
            .key = entry.key_ptr.key,
            .original = entry.value_ptr.transaction_original orelse unreachable,
            .current = observed.effect_current orelse
                entry.value_ptr.current orelse unreachable,
            .observation = observed.observation,
            .effect = observed.effect,
        };
    }

    fn transaction(self: StorageObservations) *const Transaction {
        return sealedTransaction(self.tracked());
    }

    fn tracked(self: StorageObservations) *const TrackedState {
        return @ptrCast(@alignCast(self.handle));
    }
};

/// Borrowed checkpoint-resolved semantic observations from one sealed
/// transaction. BAL indices, output ordering, and detached ownership remain
/// projector policy.
pub const ObservationsView = struct {
    handle: *const anyopaque,
    accounts: AccountObservations,
    storage: StorageObservations,

    fn init(state: *const TrackedState) ObservationsView {
        return .{
            .handle = state,
            .accounts = .{ .handle = state },
            .storage = .{ .handle = state },
        };
    }

    pub fn code(self: ObservationsView, code_hash: CodeHash) ?CodeView {
        if (std.mem.eql(u8, &code_hash, &crypto.keccak256_empty)) {
            return .{ .code_hash = code_hash, .bytes = &.{} };
        }
        const state = self.tracked();
        const entry = state.code.entries.get(code_hash) orelse return null;
        return .{ .code_hash = code_hash, .bytes = entry.slice(&state.code) };
    }

    fn tracked(self: ObservationsView) *const TrackedState {
        return @ptrCast(@alignCast(self.handle));
    }
};

pub const LogBuffer = struct {
    rows: std.ArrayList(LogRow),
    topics: std.ArrayList(u256),
    data: std.ArrayList(u8),

    pub const LogRow = struct {
        address: Address,
        topics: TopicRange,
        data: ByteRange,
    };

    pub const Checkpoint = struct {
        rows_len: u32,
        topics_len: u32,
        data_len: u32,
    };

    fn init() LogBuffer {
        return .{ .rows = .empty, .topics = .empty, .data = .empty };
    }

    fn deinit(self: *LogBuffer, allocator: std.mem.Allocator) void {
        self.rows.deinit(allocator);
        self.topics.deinit(allocator);
        self.data.deinit(allocator);
        self.* = undefined;
    }

    fn clone(self: *const LogBuffer, allocator: std.mem.Allocator) !LogBuffer {
        var result = LogBuffer.init();
        errdefer result.deinit(allocator);
        try result.rows.appendSlice(allocator, self.rows.items);
        try result.topics.appendSlice(allocator, self.topics.items);
        try result.data.appendSlice(allocator, self.data.items);
        return result;
    }

    fn checkpoint(self: *const LogBuffer) LogBuffer.Checkpoint {
        return .{
            .rows_len = index32(self.rows.items.len),
            .topics_len = index32(self.topics.items.len),
            .data_len = index32(self.data.items.len),
        };
    }

    fn truncate(self: *LogBuffer, checkpoint_state: LogBuffer.Checkpoint) void {
        std.debug.assert(checkpoint_state.rows_len <= self.rows.items.len);
        std.debug.assert(checkpoint_state.topics_len <= self.topics.items.len);
        std.debug.assert(checkpoint_state.data_len <= self.data.items.len);
        self.rows.items.len = checkpoint_state.rows_len;
        self.topics.items.len = checkpoint_state.topics_len;
        self.data.items.len = checkpoint_state.data_len;
    }

    fn clearRetainingCapacity(self: *LogBuffer) void {
        self.truncate(.{ .rows_len = 0, .topics_len = 0, .data_len = 0 });
    }

    fn append(self: *LogBuffer, allocator: std.mem.Allocator, event_log: Host.Log) !void {
        if (event_log.topics.len > 4) return error.TooManyLogTopics;
        std.debug.assert(self.rows.items.len < std.math.maxInt(u32));
        const topics = topicRange(self.topics.items.len, event_log.topics.len);
        const data = byteRange(self.data.items.len, event_log.data.len);
        try self.rows.ensureUnusedCapacity(allocator, 1);
        try self.topics.ensureUnusedCapacity(allocator, event_log.topics.len);
        try self.data.ensureUnusedCapacity(allocator, event_log.data.len);

        self.topics.appendSliceAssumeCapacity(event_log.topics);
        self.data.appendSliceAssumeCapacity(event_log.data);
        self.rows.appendAssumeCapacity(.{
            .address = event_log.address,
            .topics = topics,
            .data = data,
        });
    }
};

/// Borrowed arena projection. Retained logs remain readable until the next
/// transaction begins; discard and explicit clearing invalidate them sooner.
pub const LogView = union(enum) {
    arena: Packed,
    flat: []const Host.Log,

    pub const Packed = struct {
        rows: []const LogBuffer.LogRow,
        topics: []const u256,
        data: []const u8,

        pub const empty: Packed = .{
            .rows = &.{},
            .topics = &.{},
            .data = &.{},
        };
    };

    pub const empty: LogView = .{ .arena = .empty };

    pub fn fromSlice(logs: []const Host.Log) LogView {
        return .{ .flat = logs };
    }

    pub fn len(self: LogView) usize {
        return switch (self) {
            .arena => |arena| arena.rows.len,
            .flat => |logs| logs.len,
        };
    }

    pub fn get(self: LogView, index: usize) Host.Log {
        return switch (self) {
            .arena => |arena| blk: {
                const row = arena.rows[index];
                break :blk .{
                    .address = row.address,
                    .topics = row.topics.slice(arena.topics),
                    .data = row.data.slice(arena.data),
                };
            },
            .flat => |logs| logs[index],
        };
    }
};

/// Borrowed cumulative branch facts. Projectors own output policy and
/// allocation; this view only exposes the accepted state representation.
pub const AcceptedView = struct {
    handle: *const anyopaque,

    pub fn generation(self: AcceptedView) u64 {
        return self.tracked().generation;
    }

    pub fn hasChanges(self: AcceptedView) bool {
        return self.changes().hasChanges();
    }

    pub fn changes(self: AcceptedView) ChangesView {
        return ChangesView.init(self.tracked(), .accepted);
    }

    fn tracked(self: AcceptedView) *const TrackedState {
        return @ptrCast(@alignCast(self.handle));
    }
};

/// Borrowed sealed transaction plus the cumulative branch it would extend.
/// The view does not own or resolve the transaction lifecycle.
pub const PendingView = struct {
    handle: *const anyopaque,

    pub fn accepted(self: PendingView) AcceptedView {
        return self.tracked().acceptedView();
    }

    pub fn attemptId(self: PendingView) AttemptId {
        return self.transaction().id;
    }

    pub fn logs(self: PendingView) LogView {
        return logBufferView(&self.transaction().logs);
    }

    /// Transaction-local changes relative to the accepted branch.
    pub fn changes(self: PendingView) ChangesView {
        _ = self.transaction();
        return ChangesView.init(self.tracked(), .transaction);
    }

    pub fn observations(self: PendingView) ObservationsView {
        std.debug.assert(self.transaction().observe);
        return ObservationsView.init(self.tracked());
    }

    fn transaction(self: PendingView) *const Transaction {
        const tx = if (self.tracked().tx) |*value| value else unreachable;
        std.debug.assert(tx.sealed);
        std.debug.assert(!tx.scope.active);
        return tx;
    }

    fn tracked(self: PendingView) *const TrackedState {
        return @ptrCast(@alignCast(self.handle));
    }
};

pub const Scope = struct {
    generation: u64,
    active: bool,
    warm_accounts: AddressSet,
    storage: ScopeStorageMap,
    transient_storage: TransientStorageMap,

    fn init(allocator: std.mem.Allocator) Scope {
        return .{
            .generation = 0,
            .active = false,
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
};

pub const Journal = struct {
    entries: std.ArrayList(Entry),
    account_undo: std.ArrayList(AccountUndo),
    storage_undo: std.ArrayList(StorageUndo),
    account_observation_undo: std.ArrayList(AccountObservationUndo),
    storage_observation_undo: std.ArrayList(StorageObservationUndo),
    transient_undo: std.ArrayList(TransientUndo),

    const Id = enum(u32) {
        _,

        pub fn index(value: usize) Id {
            return @enumFromInt(@as(u32, @intCast(value)));
        }
    };

    pub const AccountUndoId = Id;
    pub const StorageUndoId = Id;
    pub const TransientUndoId = Id;

    pub const Entry = union(enum(u8)) {
        account: AccountUndoId,
        observed_account: AccountUndoId,
        storage: StorageUndoId,
        observed_storage: StorageUndoId,
        warm_account: AccountId,
        warm_storage: StorageId,
        transient_storage: TransientUndoId,
    };

    pub const AccountUndo = struct {
        row: AccountId,
        previous_current: ?AccountValue,
        previous_mutation: AccountMutation,
    };

    pub const StorageUndo = struct {
        row: StorageId,
        previous_current: ?u256,
        previous_mutation: StorageMutation,
    };

    const AccountObservationUndo = struct {
        row: AccountObservationId,
        previous_effect_current: ?AccountValue,
        previous_effect: AccountEffect,
    };

    const StorageObservationUndo = struct {
        row: StorageObservationId,
        previous_effect_current: ?u256,
        previous_effect: StorageEffect,
    };

    pub const TransientUndo = struct {
        key: StorageKey,
        previous: ?u256,
    };

    fn init() Journal {
        return .{
            .entries = .empty,
            .account_undo = .empty,
            .storage_undo = .empty,
            .account_observation_undo = .empty,
            .storage_observation_undo = .empty,
            .transient_undo = .empty,
        };
    }

    fn deinit(self: *Journal, allocator: std.mem.Allocator) void {
        self.entries.deinit(allocator);
        self.account_undo.deinit(allocator);
        self.storage_undo.deinit(allocator);
        self.account_observation_undo.deinit(allocator);
        self.storage_observation_undo.deinit(allocator);
        self.transient_undo.deinit(allocator);
        self.* = undefined;
    }

    fn len(self: *const Journal) u32 {
        return index32(self.entries.items.len);
    }

    fn isEmpty(self: *const Journal) bool {
        return self.entries.items.len == 0 and
            self.account_undo.items.len == 0 and
            self.storage_undo.items.len == 0 and
            self.account_observation_undo.items.len == 0 and
            self.storage_observation_undo.items.len == 0 and
            self.transient_undo.items.len == 0;
    }

    fn appendAccount(
        self: *Journal,
        allocator: std.mem.Allocator,
        undo: AccountUndo,
        observation_undo: ?AccountObservationUndo,
    ) !void {
        try self.ensureEntryCapacity(allocator);
        const undo_id: AccountUndoId = .index(self.account_undo.items.len);
        try self.ensurePayloadCapacity(allocator, &self.account_undo);
        if (observation_undo != null)
            try self.ensurePayloadCapacity(allocator, &self.account_observation_undo);
        self.account_undo.appendAssumeCapacity(undo);
        if (observation_undo) |value| {
            self.account_observation_undo.appendAssumeCapacity(value);
            self.entries.appendAssumeCapacity(.{ .observed_account = undo_id });
        } else {
            self.entries.appendAssumeCapacity(.{ .account = undo_id });
        }
    }

    fn appendStorage(
        self: *Journal,
        allocator: std.mem.Allocator,
        undo: StorageUndo,
        observation_undo: ?StorageObservationUndo,
    ) !void {
        try self.ensureEntryCapacity(allocator);
        const undo_id: StorageUndoId = .index(self.storage_undo.items.len);
        try self.ensurePayloadCapacity(allocator, &self.storage_undo);
        if (observation_undo != null)
            try self.ensurePayloadCapacity(allocator, &self.storage_observation_undo);
        self.storage_undo.appendAssumeCapacity(undo);
        if (observation_undo) |value| {
            self.storage_observation_undo.appendAssumeCapacity(value);
            self.entries.appendAssumeCapacity(.{ .observed_storage = undo_id });
        } else {
            self.entries.appendAssumeCapacity(.{ .storage = undo_id });
        }
    }

    fn appendWarmAccount(self: *Journal, allocator: std.mem.Allocator, row: AccountId) !void {
        try self.ensureEntryCapacity(allocator);
        self.entries.appendAssumeCapacity(.{ .warm_account = row });
    }

    fn appendWarmStorage(self: *Journal, allocator: std.mem.Allocator, row: StorageId) !void {
        try self.ensureEntryCapacity(allocator);
        self.entries.appendAssumeCapacity(.{ .warm_storage = row });
    }

    fn appendTransient(self: *Journal, allocator: std.mem.Allocator, undo: TransientUndo) !void {
        try self.ensureEntryCapacity(allocator);
        const undo_id: TransientUndoId = .index(self.transient_undo.items.len);
        try self.ensurePayloadCapacity(allocator, &self.transient_undo);
        self.transient_undo.appendAssumeCapacity(undo);
        self.entries.appendAssumeCapacity(.{ .transient_storage = undo_id });
    }

    fn ensureEntryCapacity(self: *Journal, allocator: std.mem.Allocator) !void {
        std.debug.assert(self.entries.items.len < std.math.maxInt(u32));
        try self.entries.ensureUnusedCapacity(allocator, 1);
    }

    fn ensurePayloadCapacity(
        self: *Journal,
        allocator: std.mem.Allocator,
        payload: anytype,
    ) !void {
        _ = self;
        try payload.ensureUnusedCapacity(allocator, 1);
    }

    fn pop(self: *Journal) Entry {
        std.debug.assert(self.entries.items.len != 0);
        const last = self.entries.items.len - 1;
        const entry = self.entries.items[last];
        self.entries.items.len = last;
        return entry;
    }

    fn takeAccount(self: *Journal, id: AccountUndoId) AccountUndo {
        return takeLast(AccountUndo, &self.account_undo, @intFromEnum(id));
    }

    fn takeStorage(self: *Journal, id: StorageUndoId) StorageUndo {
        return takeLast(StorageUndo, &self.storage_undo, @intFromEnum(id));
    }

    fn takeAccountObservation(self: *Journal) AccountObservationUndo {
        const last = self.account_observation_undo.items.len - 1;
        return takeLast(AccountObservationUndo, &self.account_observation_undo, @intCast(last));
    }

    fn takeStorageObservation(self: *Journal) StorageObservationUndo {
        const last = self.storage_observation_undo.items.len - 1;
        return takeLast(StorageObservationUndo, &self.storage_observation_undo, @intCast(last));
    }

    fn takeTransient(self: *Journal, id: TransientUndoId) TransientUndo {
        return takeLast(TransientUndo, &self.transient_undo, @intFromEnum(id));
    }

    fn truncate(self: *Journal, target_len: u32) void {
        const target: usize = target_len;
        std.debug.assert(target <= self.entries.items.len);
        while (self.entries.items.len > target) {
            self.discardPayload(self.pop());
        }
    }

    fn discardPayload(self: *Journal, entry: Entry) void {
        switch (entry) {
            .account => |id| _ = self.takeAccount(id),
            .observed_account => |id| {
                _ = self.takeAccount(id);
                _ = self.takeAccountObservation();
            },
            .storage => |id| _ = self.takeStorage(id),
            .observed_storage => |id| {
                _ = self.takeStorage(id);
                _ = self.takeStorageObservation();
            },
            .transient_storage => |id| _ = self.takeTransient(id),
            .warm_account, .warm_storage => {},
        }
    }

    fn takeLast(comptime T: type, list: *std.ArrayList(T), index: u32) T {
        std.debug.assert(list.items.len != 0);
        const last = list.items.len - 1;
        std.debug.assert(@as(usize, index) == last);
        const value = list.items[last];
        list.items.len = last;
        return value;
    }
};

pub const Checkpoint = struct {
    attempt_id: AttemptId,
    scope_generation: u64,
    journal_len: u32,
    changed_accounts_len: u32,
    changed_storage_len: u32,
    storage_wipes_len: u32,
    logs: LogBuffer.Checkpoint,
};

const AcceptedBranchCheckpoint = struct {
    generation: u64,
    accepted: Accepted,
    retained_logs: LogBuffer,
};

pub const BranchCheckpoint = struct {
    owner: *const TrackedState,
    allocator: std.mem.Allocator,
    epoch: u64,
    resolved: bool = false,
    payload: union(enum) {
        accepted: AcceptedBranchCheckpoint,
        transaction: Checkpoint,
    },

    pub fn clone(self: *const BranchCheckpoint) !BranchCheckpoint {
        std.debug.assert(!self.resolved);
        return switch (self.payload) {
            .transaction => |checkpoint_state| .{
                .owner = self.owner,
                .allocator = self.allocator,
                .epoch = self.epoch,
                .payload = .{ .transaction = checkpoint_state },
            },
            .accepted => |*accepted_checkpoint| blk: {
                var accepted = try accepted_checkpoint.accepted.clone(self.allocator);
                errdefer accepted.deinit(self.allocator);
                var retained_logs = try accepted_checkpoint.retained_logs.clone(self.allocator);
                errdefer retained_logs.deinit(self.allocator);
                break :blk .{
                    .owner = self.owner,
                    .allocator = self.allocator,
                    .epoch = self.epoch,
                    .payload = .{ .accepted = .{
                        .generation = accepted_checkpoint.generation,
                        .accepted = accepted,
                        .retained_logs = retained_logs,
                    } },
                };
            },
        };
    }

    pub fn deinit(self: *BranchCheckpoint) void {
        switch (self.payload) {
            .accepted => |*accepted| {
                accepted.accepted.deinit(self.allocator);
                accepted.retained_logs.deinit(self.allocator);
            },
            .transaction => {},
        }
        self.* = undefined;
    }
};

pub const Transaction = struct {
    id: AttemptId,
    observe: bool,
    accounts: TransactionAccountMap,
    storage: TransactionStorageMap,
    observed_accounts: std.ArrayList(AccountObservationRow),
    observed_storage: std.ArrayList(StorageObservationRow),
    changed_accounts: std.ArrayList(AccountId),
    changed_storage: std.ArrayList(StorageId),
    storage_wipes: std.ArrayList(AccountId),
    lifecycle_accounts: std.ArrayList(AccountId),
    introduced_code: CodeHashSet,
    scope: Scope,
    undo: Journal,
    logs: LogBuffer,
    sealed: bool,

    fn init(allocator: std.mem.Allocator, id: AttemptId, observe: bool) Transaction {
        return .{
            .id = id,
            .observe = observe,
            .accounts = TransactionAccountMap.init(allocator),
            .storage = TransactionStorageMap.init(allocator),
            .observed_accounts = .empty,
            .observed_storage = .empty,
            .changed_accounts = .empty,
            .changed_storage = .empty,
            .storage_wipes = .empty,
            .lifecycle_accounts = .empty,
            .introduced_code = CodeHashSet.init(allocator),
            .scope = Scope.init(allocator),
            .undo = Journal.init(),
            .logs = LogBuffer.init(),
            .sealed = false,
        };
    }

    fn deinit(self: *Transaction, allocator: std.mem.Allocator) void {
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
        self.undo.deinit(allocator);
        self.logs.deinit(allocator);
        self.* = undefined;
    }
};

pub fn init(allocator: std.mem.Allocator) TrackedState {
    return initWithStateReader(allocator, null);
}

pub fn initWithStateReader(allocator: std.mem.Allocator, reader: ?StateReader) TrackedState {
    return .{
        .allocator = allocator,
        .reader = reader,
        .epoch = 0,
        .generation = 0,
        .next_attempt_id = 0,
        .accepted = Accepted.init(allocator),
        .code = CodeCache.init(allocator),
        .tx = null,
        .retained_logs = LogBuffer.init(),
    };
}

pub fn deinit(self: *TrackedState) void {
    self.discardActive();
    self.accepted.deinit(self.allocator);
    self.code.deinit(self.allocator);
    self.retained_logs.deinit(self.allocator);
    self.* = undefined;
}

pub fn reset(self: *TrackedState, reader: ?StateReader) void {
    const allocator = self.allocator;
    std.debug.assert(self.epoch != std.math.maxInt(u64));
    const next_epoch = self.epoch + 1;
    self.deinit();
    self.* = initWithStateReader(allocator, reader);
    self.epoch = next_epoch;
}

pub fn seedAccount(self: *TrackedState, address: Address, account_value: MemoryAccount) !void {
    std.debug.assert(self.tx == null);
    std.debug.assert(self.accepted.changed_accounts.items.len == 0);
    std.debug.assert(self.accepted.changed_storage.items.len == 0);
    std.debug.assert(self.accepted.storage_wipes.items.len == 0);
    var account = account_value;
    defer account.deinit();

    const code_hash = account.code_hash orelse crypto.keccak256(account.code);
    if (!std.mem.eql(u8, &crypto.keccak256(account.code), &code_hash)) return error.CodeHashMismatch;
    if (account.code.len != 0) _ = try self.cacheCode(code_hash, account.code, false);

    var old_keys: std.ArrayList(StorageKey) = .empty;
    defer old_keys.deinit(self.allocator);
    var accepted_it = self.accepted.storage.keyIterator();
    while (accepted_it.next()) |key| {
        if (std.mem.eql(u8, &key.address, &address)) try old_keys.append(self.allocator, key.*);
    }
    for (old_keys.items) |key| {
        _ = self.accepted.storage.remove(key);
    }

    try self.accepted.accounts.put(address, .{ .value = .{ .loaded = .{
        .nonce = account.nonce,
        .balance = account.balance,
        .code_hash = code_hash,
    } } });
    try self.accepted.storage.ensureUnusedCapacity(@intCast(account.storage.count()));
    var storage_it = account.storage.iterator();
    while (storage_it.next()) |entry| {
        self.accepted.storage.putAssumeCapacityNoClobber(.{
            .address = address,
            .key = entry.key_ptr.*,
        }, .{ .value = entry.value_ptr.* });
    }
}

pub fn reserveAccessHint(self: *TrackedState, hint: anytype) !void {
    const tx = self.mutableTransaction();
    try tx.scope.warm_accounts.ensureUnusedCapacity(@intCast(hint.accounts));
    try tx.accounts.ensureUnusedCapacity(@intCast(hint.accounts));
    try tx.scope.storage.ensureUnusedCapacity(@intCast(hint.storage_keys));
    try tx.storage.ensureUnusedCapacity(@intCast(hint.storage_keys));
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
    var tx = Transaction.init(self.allocator, id, observe);
    std.mem.swap(LogBuffer, &tx.logs, &self.retained_logs);
    tx.logs.clearRetainingCapacity();
    self.tx = tx;
    return id;
}

pub fn beginScope(self: *TrackedState) void {
    const tx = self.mutableTransaction();
    std.debug.assert(!tx.scope.active);
    std.debug.assert(tx.undo.isEmpty());

    std.debug.assert(tx.scope.generation != std.math.maxInt(u64));
    tx.scope.generation += 1;
    tx.scope.active = true;
    tx.logs.clearRetainingCapacity();
}

pub fn closeScope(self: *TrackedState) void {
    const tx = self.mutableTransaction();
    std.debug.assert(tx.scope.active);
    tx.undo.truncate(0);
    tx.scope.clearRetainingCapacity();
}

pub fn seal(self: *TrackedState, id: AttemptId) void {
    const tx = self.assertCurrent(id);
    std.debug.assert(!tx.sealed);
    std.debug.assert(!tx.scope.active);
    std.debug.assert(tx.undo.isEmpty());
    compactTransactionStorageChanges(tx);
    tx.sealed = true;
}

pub fn discard(self: *TrackedState, id: AttemptId) void {
    _ = self.assertCurrent(id);
    self.discardActive();
}

pub fn retain(self: *TrackedState, id: AttemptId) void {
    const tx = self.assertCurrent(id);
    std.debug.assert(tx.sealed);
    std.debug.assert(!tx.scope.active);
    std.debug.assert(self.generation != std.math.maxInt(u64));

    for (tx.storage_wipes.items) |tx_account_id| {
        const address = tx.accounts.keyById(tx_account_id).*;
        compactAcceptedStorageChanges(&self.accepted, address);
        const accepted_id = self.accepted.accounts.getEntryId(address) orelse unreachable;
        const accepted_row = self.accepted.accounts.valuePtrById(accepted_id);
        if (!accepted_row.storage_wiped) {
            accepted_row.storage_wiped = true;
            self.accepted.storage_wipes.appendAssumeCapacity(accepted_id);
        }
    }

    for (tx.changed_accounts.items) |tx_account_id| {
        const entry = tx.accounts.entryAt(@intFromEnum(tx_account_id));
        const current = entry.value_ptr.current orelse unreachable;
        if (current == .absent) compactAcceptedStorageChanges(&self.accepted, entry.key_ptr.*);
        const accepted_id = self.accepted.accounts.getEntryId(entry.key_ptr.*) orelse unreachable;
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

    self.discardActive();
    self.generation += 1;
}

pub fn acceptedView(self: *const TrackedState) AcceptedView {
    return .{ .handle = self };
}

pub fn branchCheckpoint(self: *TrackedState) !BranchCheckpoint {
    if (self.tx != null) {
        return .{
            .owner = self,
            .allocator = self.allocator,
            .epoch = self.epoch,
            .payload = .{ .transaction = self.checkpoint() },
        };
    }

    var accepted = try self.accepted.clone(self.allocator);
    errdefer accepted.deinit(self.allocator);
    var retained_logs = try self.retained_logs.clone(self.allocator);
    errdefer retained_logs.deinit(self.allocator);
    return .{
        .owner = self,
        .allocator = self.allocator,
        .epoch = self.epoch,
        .payload = .{ .accepted = .{
            .generation = self.generation,
            .accepted = accepted,
            .retained_logs = retained_logs,
        } },
    };
}

pub fn restoreBranch(self: *TrackedState, checkpoint_state: *BranchCheckpoint) void {
    std.debug.assert(checkpoint_state.owner == self);
    std.debug.assert(checkpoint_state.epoch == self.epoch);
    std.debug.assert(!checkpoint_state.resolved);
    switch (checkpoint_state.payload) {
        .transaction => |checkpoint_state_value| {
            self.revertToCheckpoint(checkpoint_state_value);
        },
        .accepted => |*accepted_checkpoint| {
            self.discardActive();
            std.mem.swap(Accepted, &self.accepted, &accepted_checkpoint.accepted);
            std.mem.swap(LogBuffer, &self.retained_logs, &accepted_checkpoint.retained_logs);
            self.generation = accepted_checkpoint.generation;
        },
    }
    checkpoint_state.resolved = true;
}

pub fn pendingView(self: *const TrackedState) PendingView {
    const tx = if (self.tx) |*value| value else unreachable;
    std.debug.assert(tx.sealed);
    std.debug.assert(!tx.scope.active);
    return .{ .handle = self };
}

pub fn logView(self: *const TrackedState) LogView {
    const logs = if (self.tx) |*tx| &tx.logs else &self.retained_logs;
    return logBufferView(logs);
}

pub fn scopeActive(self: *const TrackedState) bool {
    const tx = self.tx orelse return false;
    return tx.scope.active;
}

pub fn checkpoint(self: *TrackedState) Checkpoint {
    const tx = self.mutableTransaction();
    std.debug.assert(tx.scope.active);
    return .{
        .attempt_id = tx.id,
        .scope_generation = tx.scope.generation,
        .journal_len = tx.undo.len(),
        .changed_accounts_len = index32(tx.changed_accounts.items.len),
        .changed_storage_len = index32(tx.changed_storage.items.len),
        .storage_wipes_len = index32(tx.storage_wipes.items.len),
        .logs = tx.logs.checkpoint(),
    };
}

pub fn commitCheckpoint(self: *TrackedState, checkpoint_state: Checkpoint) void {
    self.validateCheckpoint(checkpoint_state);
}

pub fn revertToCheckpoint(self: *TrackedState, checkpoint_state: Checkpoint) void {
    self.validateCheckpoint(checkpoint_state);
    const tx = &self.tx.?;
    while (tx.undo.entries.items.len > @as(usize, checkpoint_state.journal_len)) {
        const entry = tx.undo.pop();
        self.revertEntry(tx, entry);
    }
    tx.changed_accounts.items.len = checkpoint_state.changed_accounts_len;
    tx.changed_storage.items.len = checkpoint_state.changed_storage_len;
    tx.storage_wipes.items.len = checkpoint_state.storage_wipes_len;
    tx.logs.truncate(checkpoint_state.logs);
}

fn validateCheckpoint(self: *TrackedState, checkpoint_state: Checkpoint) void {
    const tx = self.mutableTransaction();
    std.debug.assert(tx.scope.active);
    std.debug.assert(checkpoint_state.attempt_id == tx.id);
    std.debug.assert(checkpoint_state.scope_generation == tx.scope.generation);
    std.debug.assert(@as(usize, checkpoint_state.journal_len) <= tx.undo.entries.items.len);
    std.debug.assert(@as(usize, checkpoint_state.changed_accounts_len) <= tx.changed_accounts.items.len);
    std.debug.assert(@as(usize, checkpoint_state.changed_storage_len) <= tx.changed_storage.items.len);
    std.debug.assert(@as(usize, checkpoint_state.storage_wipes_len) <= tx.storage_wipes.items.len);
}

fn assertCurrent(self: *TrackedState, id: AttemptId) *Transaction {
    std.debug.assert(self.tx != null);
    const tx = &self.tx.?;
    std.debug.assert(tx.id == id);
    return tx;
}

fn discardActive(self: *TrackedState) void {
    if (self.tx) |*tx| tx.deinit(self.allocator);
    self.tx = null;
}

fn revertEntry(self: *TrackedState, tx: *Transaction, entry: Journal.Entry) void {
    _ = self;
    switch (entry) {
        .account => |undo_id| {
            const undo = tx.undo.takeAccount(undo_id);
            const row = tx.accounts.valuePtrById(undo.row);
            row.current = undo.previous_current;
            row.mutation = undo.previous_mutation;
        },
        .observed_account => |undo_id| {
            const undo = tx.undo.takeAccount(undo_id);
            const row = tx.accounts.valuePtrById(undo.row);
            row.current = undo.previous_current;
            row.mutation = undo.previous_mutation;
            const observation_undo = tx.undo.takeAccountObservation();
            const observation = &tx.observed_accounts.items[@intFromEnum(observation_undo.row)];
            observation.effect_current = observation_undo.previous_effect_current;
            observation.effect = observation_undo.previous_effect;
        },
        .storage => |undo_id| {
            const undo = tx.undo.takeStorage(undo_id);
            const row = tx.storage.valuePtrById(undo.row);
            row.current = undo.previous_current;
            row.mutation = undo.previous_mutation;
        },
        .observed_storage => |undo_id| {
            const undo = tx.undo.takeStorage(undo_id);
            const row = tx.storage.valuePtrById(undo.row);
            row.current = undo.previous_current;
            row.mutation = undo.previous_mutation;
            const observation_undo = tx.undo.takeStorageObservation();
            const observation = &tx.observed_storage.items[@intFromEnum(observation_undo.row)];
            observation.effect_current = observation_undo.previous_effect_current;
            observation.effect = observation_undo.previous_effect;
        },
        .warm_account => |account_id| {
            _ = tx.scope.warm_accounts.remove(tx.accounts.keyById(account_id).*);
        },
        .warm_storage => |storage_id| {
            const key = tx.storage.keyById(storage_id).*;
            const row = tx.scope.storage.getPtr(key) orelse unreachable;
            row.warm = false;
        },
        .transient_storage => |undo_id| {
            const undo = tx.undo.takeTransient(undo_id);
            if (undo.previous) |previous| {
                tx.scope.transient_storage.putAssumeCapacity(undo.key, previous);
            } else {
                _ = tx.scope.transient_storage.remove(undo.key);
            }
        },
    }
}

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
    return accountValue(try self.readAccountValue(address, .value));
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
    const row = try tx.accounts.getOrPut(address);
    if (!row.found_existing) row.value_ptr.* = .{};
    if (try self.observeAccount(.{ .id = row.entry_id, .row = row.value_ptr })) |observation| {
        observation.observation.accessed = true;
        observation.observation.existence_read = true;
    }
    if (row.value_ptr.current == null) {
        const value = try self.acceptedAccountExistence(address);
        row.value_ptr.original = value;
        row.value_ptr.current = value;
    }
    return row.value_ptr.current.?.exists();
}

pub fn getBalance(self: *TrackedState, address: Address) !u256 {
    return switch (try self.readAccountValue(address, .value)) {
        .loaded => |account| account.balance,
        .absent => 0,
        .exists_only => unreachable,
    };
}

pub fn getNonce(self: *TrackedState, address: Address) !u64 {
    return switch (try self.readAccountValue(address, .value)) {
        .loaded => |account| account.nonce,
        .absent => 0,
        .exists_only => unreachable,
    };
}

pub fn getCodeView(self: *TrackedState, address: Address) !CodeView {
    return codeView(self, try self.readAccountValue(address, .code));
}

pub fn getCode(self: *TrackedState, address: Address) ![]const u8 {
    return (try self.getCodeView(address)).bytes;
}

pub fn getCodeHash(self: *TrackedState, address: Address) !u256 {
    return switch (try self.readAccountValue(address, .value)) {
        .loaded => |account| std.mem.readInt(u256, &account.code_hash, .big),
        .absent => 0,
        .exists_only => unreachable,
    };
}

pub fn accountHasCode(self: *TrackedState, address: Address) !bool {
    return switch (try self.readAccountValue(address, .value)) {
        .loaded => |account| !std.mem.eql(u8, &account.code_hash, &crypto.keccak256_empty),
        .absent => false,
        .exists_only => unreachable,
    };
}

pub fn setBalance(self: *TrackedState, address: Address, balance: u256) !void {
    const account_ref = try self.materializeTransactionAccount(address);
    const row = account_ref.row;
    const observation = try self.observeAccount(account_ref);
    if (observation) |value| {
        value.observation.accessed = true;
        value.observation.semantic_access = true;
        value.observation.value_read = true;
    }
    var account = switch (row.current.?) {
        .loaded => |value| value,
        .absent => Account{},
        .exists_only => unreachable,
    };
    if (account.balance == balance and row.current.? == .loaded) return;

    const first_change = !row.mutation.dirty;
    if (first_change) try self.reserveAcceptedAccountMutation(address);
    try self.appendAccountUndo(account_ref.id, row);
    if (first_change) self.tx.?.changed_accounts.appendAssumeCapacity(account_ref.id);
    account.balance = balance;
    row.current = .{ .loaded = account };
    if (observation) |value| value.effect.balance_written = true;
    row.mutation.dirty = true;
}

pub fn touchAccount(self: *TrackedState, address: Address) !void {
    const account_ref = try self.materializeTransactionAccount(address);
    const row = account_ref.row;
    if (try self.observeAccount(account_ref)) |observation|
        observation.observation.accessed = true;
    if (row.mutation.touched) return;

    const first_change = !row.mutation.dirty;
    if (first_change) try self.reserveAcceptedAccountMutation(address);
    try self.appendAccountUndo(account_ref.id, row);
    if (first_change) self.tx.?.changed_accounts.appendAssumeCapacity(account_ref.id);
    if (row.current.? == .absent) row.current = .{ .loaded = .{} };
    row.mutation.touched = true;
    row.mutation.dirty = true;
}

pub fn addBalance(self: *TrackedState, address: Address, value: u256) !void {
    if (value == 0) return;
    const balance = try self.getBalance(address);
    try self.setBalance(address, std.math.add(u256, balance, value) catch return error.BalanceOverflow);
}

pub fn subtractBalance(self: *TrackedState, address: Address, value: u256) !bool {
    if (value == 0) return true;
    const balance = try self.getBalance(address);
    if (balance < value) return false;
    try self.setBalance(address, balance - value);
    return true;
}

pub fn setCode(self: *TrackedState, address: Address, code_bytes: []const u8) !void {
    const account_ref = try self.materializeTransactionAccount(address);
    const row = account_ref.row;
    const observation = try self.observeAccount(account_ref);
    if (observation) |value| {
        value.observation.accessed = true;
        value.observation.semantic_access = true;
        value.observation.value_read = true;
    }

    var account = switch (row.current.?) {
        .loaded => |value| value,
        .absent => Account{},
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

    const first_change = !row.mutation.dirty;
    if (first_change) try self.reserveAcceptedAccountMutation(address);
    if (track_introduction) {
        try tx.introduced_code.ensureUnusedCapacity(1);
        const introduced_count = tx.introduced_code.count();
        std.debug.assert(introduced_count < std.math.maxInt(u32));
        const pending_introduced = introduced_count + 1;
        try self.accepted.introduced_code.ensureUnusedCapacity(pending_introduced);
    }
    _ = try self.cacheCode(code_hash, code_bytes, true);
    try self.appendAccountUndo(account_ref.id, row);
    if (first_change) tx.changed_accounts.appendAssumeCapacity(account_ref.id);

    if (track_introduction) tx.introduced_code.putAssumeCapacityNoClobber(code_hash, {});
    account.code_hash = code_hash;
    row.current = .{ .loaded = account };
    if (observation) |value| value.effect.code_written = true;
    row.mutation.dirty = true;
}

pub fn clearCode(self: *TrackedState, address: Address) !void {
    try self.setCode(address, &.{});
}

pub fn setNonce(self: *TrackedState, address: Address, nonce: u64) !void {
    const account_ref = try self.materializeTransactionAccount(address);
    const row = account_ref.row;
    const observation = try self.observeAccount(account_ref);
    if (observation) |value| {
        value.observation.accessed = true;
        value.observation.semantic_access = true;
        value.observation.value_read = true;
    }
    var account = switch (row.current.?) {
        .loaded => |value| value,
        .absent => Account{},
        .exists_only => unreachable,
    };
    if (account.nonce == nonce and row.current.? == .loaded) return;

    const first_change = !row.mutation.dirty;
    if (first_change) try self.reserveAcceptedAccountMutation(address);
    try self.appendAccountUndo(account_ref.id, row);
    if (first_change) self.tx.?.changed_accounts.appendAssumeCapacity(account_ref.id);
    account.nonce = nonce;
    row.current = .{ .loaded = account };
    if (observation) |value| value.effect.nonce_written = true;
    row.mutation.dirty = true;
}

pub fn accessAccount(self: *TrackedState, address: Address) !Host.AccessStatus {
    const access = try self.ensureAccountWarm(address);
    if (try self.observeAccount(.{ .id = access.id, .row = access.row })) |observation| {
        observation.observation.accessed = true;
        observation.observation.semantic_access = true;
    }
    return access.status;
}

/// Record an account access after instruction gas/admission has succeeded.
/// This does not load account metadata or alter warmth.
pub fn observeAccountAccess(self: *TrackedState, address: Address) !void {
    if (!self.mutableTransaction().observe) return;
    const tx = self.mutableTransaction();
    const result = try tx.accounts.getOrPut(address);
    if (!result.found_existing) result.value_ptr.* = .{};
    const account_ref = AccountRef{ .id = result.entry_id, .row = result.value_ptr };
    const observation = (try self.observeAccount(account_ref)).?;
    observation.observation.accessed = true;
    observation.observation.semantic_access = true;
}

pub fn warmAccount(self: *TrackedState, address: Address) !void {
    _ = try self.ensureAccountWarm(address);
}

pub fn isAccountWarm(self: *const TrackedState, address: Address) bool {
    const tx = self.tx orelse return false;
    return tx.scope.warm_accounts.contains(address);
}

pub fn warmAccountCount(self: *const TrackedState) usize {
    const tx = self.tx orelse return 0;
    return tx.scope.warm_accounts.count();
}

pub fn journalEntryCount(self: *const TrackedState) usize {
    const tx = self.tx orelse return 0;
    return tx.undo.entries.items.len;
}

pub fn getStorage(self: *TrackedState, address: Address, key: u256) !u256 {
    const storage_key = StorageKey{ .address = address, .key = key };
    if (self.tx == null) return self.readAcceptedStorage(storage_key);
    if (self.tx.?.sealed) {
        if (self.tx.?.storage.get(storage_key)) |row| {
            if (row.current) |value| return value;
        }
        if (transactionStorageWiped(&self.tx.?, address)) return 0;
        return self.readAcceptedStorage(storage_key);
    }
    const storage_ref = try self.materializeTransactionStorage(storage_key);
    const row = storage_ref.row;
    if (try self.observeStorage(storage_ref)) |observation| {
        observation.observation.accessed = true;
        observation.observation.value_read = true;
    }
    return row.current.?;
}

pub fn accessStorage(self: *TrackedState, address: Address, key: u256) !Host.AccessStatus {
    return (try self.accessStorageKey(.{ .address = address, .key = key })).status;
}

pub fn warmStorage(self: *TrackedState, address: Address, key: u256) !void {
    _ = try self.ensureStorageWarm(.{ .address = address, .key = key });
}

pub fn isStorageWarm(self: *const TrackedState, address: Address, key: u256) bool {
    const tx = self.tx orelse return false;
    const scope_storage = tx.scope.storage.get(.{ .address = address, .key = key }) orelse return false;
    return scope_storage.warm;
}

pub fn warmStorageCount(self: *TrackedState) usize {
    const tx = if (self.tx) |*value| value else return 0;
    var count: usize = 0;
    var it = tx.scope.storage.valueIterator();
    while (it.next()) |scope_storage| {
        if (scope_storage.warm) count += 1;
    }
    return count;
}

pub fn loadStorage(self: *TrackedState, address: Address, key: u256) !Host.StorageLoadResult {
    const storage_key = StorageKey{ .address = address, .key = key };
    const access = try self.accessStorageKey(storage_key);
    try self.loadStorageRef(storage_key, access.storage);
    if (try self.observeStorage(access.storage)) |observation|
        observation.observation.value_read = true;
    return .{ .value = access.storage.row.current.?, .access_status = access.status };
}

pub fn setStorage(self: *TrackedState, address: Address, key: u256, value: u256) !Host.StorageStatus {
    const storage_key = StorageKey{ .address = address, .key = key };
    const tx = self.mutableTransaction();
    std.debug.assert(tx.scope.active);
    const storage_ref = try self.transactionStorageRef(tx, storage_key);
    const scope_storage = try self.scopeStorageRef(tx, storage_key);
    try self.loadStorageRef(storage_key, storage_ref);
    return self.setStorageAfterAccess(storage_key, storage_ref, scope_storage, value);
}

pub fn storeStorage(self: *TrackedState, address: Address, key: u256, value: u256) !Host.StorageStoreResult {
    const storage_key = StorageKey{ .address = address, .key = key };
    const access = try self.accessStorageKey(storage_key);
    try self.loadStorageRef(storage_key, access.storage);
    const storage_status = try self.setStorageAfterAccess(storage_key, access.storage, access.scope, value);
    return .{ .storage_status = storage_status, .access_status = access.status };
}

fn setStorageAfterAccess(
    self: *TrackedState,
    storage_key: StorageKey,
    storage_ref: StorageRef,
    scope_storage: *ScopeStorage,
    value: u256,
) !Host.StorageStatus {
    const row = storage_ref.row;
    const observation = try self.observeStorage(storage_ref);
    if (observation) |observed| {
        observed.observation.accessed = true;
        observed.observation.value_read = true;
    }
    const tx = &self.tx.?;
    if (scope_storage.execution_original == null) scope_storage.execution_original = storage_ref.row.current.?;
    const current = row.current.?;
    const status = storage.status(scope_storage.execution_original.?, current, value);
    if (current == value) return status;

    const first_change = !row.mutation.dirty;
    if (first_change) try self.reserveAcceptedStorageMutation(storage_key);
    try self.appendStorageUndo(storage_ref.id, row);
    if (first_change) tx.changed_storage.appendAssumeCapacity(storage_ref.id);
    row.current = value;
    if (observation) |observed| observed.effect.written = true;
    row.mutation.dirty = true;
    return status;
}

pub fn originalStorage(self: *TrackedState, address: Address, key: u256) !u256 {
    const storage_key = StorageKey{ .address = address, .key = key };
    const tx = self.mutableTransaction();
    std.debug.assert(tx.scope.active);
    const scope_storage = try self.scopeStorageRef(tx, storage_key);
    const storage_ref = try self.transactionStorageRef(tx, storage_key);
    try self.loadStorageRef(storage_key, storage_ref);
    if (try self.observeStorage(storage_ref)) |observation| {
        observation.observation.accessed = true;
        observation.observation.value_read = true;
    }
    if (scope_storage.execution_original == null) scope_storage.execution_original = storage_ref.row.current.?;
    return scope_storage.execution_original.?;
}

pub fn accountHasStorage(self: *TrackedState, address: Address) !bool {
    return switch (try self.storagePresence(address)) {
        .empty => false,
        // Point writes cannot prove they cleared the reader's final base slot.
        // CREATE collision checks must therefore treat unknown as occupied.
        .nonempty, .unknown => true,
    };
}

const StoragePresence = enum { empty, nonempty, unknown };

fn storagePresence(self: *TrackedState, address: Address) !StoragePresence {
    var has_zero_override = false;
    if (self.tx) |*tx| {
        if (transactionStorageWiped(tx, address)) return .empty;
        var tx_it = tx.storage.iterator();
        while (tx_it.next()) |entry| {
            if (!std.mem.eql(u8, &entry.key_ptr.address, &address)) continue;
            const current = entry.value_ptr.current orelse continue;
            if (current != 0) return .nonempty;
            const accepted_row = self.accepted.storage.get(entry.key_ptr.*);
            if (entry.value_ptr.mutation.dirty or
                (accepted_row != null and accepted_row.?.changed))
            {
                has_zero_override = true;
            }
        }
    }

    const accepted_wiped = acceptedStorageWiped(&self.accepted, address);
    var accepted_it = self.accepted.storage.iterator();
    while (accepted_it.next()) |entry| {
        if (!std.mem.eql(u8, &entry.key_ptr.address, &address)) continue;
        if (self.tx) |*tx| {
            if (transactionShadowsStorage(tx, entry.key_ptr.*)) continue;
        }
        if (accepted_wiped and !entry.value_ptr.changed) continue;
        if (entry.value_ptr.value != 0) return .nonempty;
        if (entry.value_ptr.changed) has_zero_override = true;
    }
    if (accepted_wiped) return .empty;

    const reader = self.reader orelse return .empty;
    if (!try reader.accountHasStorage(address)) return .empty;
    return if (has_zero_override) .unknown else .nonempty;
}

pub fn getTransientStorage(self: *TrackedState, address: Address, key: u256) !u256 {
    const tx = self.mutableTransaction();
    std.debug.assert(tx.scope.active);
    return tx.scope.transient_storage.get(.{ .address = address, .key = key }) orelse 0;
}

pub fn setTransientStorage(self: *TrackedState, address: Address, key: u256, value: u256) !void {
    const tx = self.mutableTransaction();
    std.debug.assert(tx.scope.active);
    const storage_key = StorageKey{ .address = address, .key = key };
    const previous = tx.scope.transient_storage.get(storage_key);
    if ((previous orelse 0) == value) return;
    if (previous == null and value != 0) try tx.scope.transient_storage.ensureUnusedCapacity(1);
    try tx.undo.appendTransient(self.allocator, .{
        .key = storage_key,
        .previous = previous,
    });
    if (value == 0) {
        _ = tx.scope.transient_storage.remove(storage_key);
    } else {
        tx.scope.transient_storage.putAssumeCapacity(storage_key, value);
    }
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
    const observation = try self.observeAccount(account_ref);
    if (observation) |value| {
        value.observation.accessed = true;
        value.observation.semantic_access = true;
    }
    if (account_ref.row.mutation.created) return;
    try self.trackLifecycleAccount(account_ref);
    try self.appendAccountUndo(account_ref.id, account_ref.row);
    account_ref.row.mutation.created = true;
    if (observation) |value| value.effect.created_contract = true;
}

pub fn markSelfdestructed(self: *TrackedState, address: Address) !void {
    const account_ref = try self.materializeTransactionAccount(address);
    const observation = try self.observeAccount(account_ref);
    if (observation) |value| {
        value.observation.accessed = true;
        value.observation.semantic_access = true;
    }
    if (account_ref.row.mutation.selfdestructed) return;
    try self.trackLifecycleAccount(account_ref);
    try self.appendAccountUndo(account_ref.id, account_ref.row);
    account_ref.row.mutation.selfdestructed = true;
    if (observation) |value| value.effect.selfdestruct = true;
}

pub fn createdInTransaction(self: *const TrackedState, address: Address) bool {
    const tx = self.tx orelse return false;
    const row = tx.accounts.get(address) orelse return false;
    return row.mutation.created;
}

pub fn wasSelfdestructed(self: *const TrackedState, address: Address) bool {
    const tx = self.tx orelse return false;
    const row = tx.accounts.get(address) orelse return false;
    return row.mutation.selfdestructed;
}

pub fn finalize(self: *TrackedState, rules: FinalizationRules) !void {
    const tx = self.mutableTransaction();
    std.debug.assert(tx.scope.active);

    const lifecycle_count = index32(tx.lifecycle_accounts.items.len);
    const pending_accounts = tx.changed_accounts.items.len + @as(usize, lifecycle_count);
    try tx.storage_wipes.ensureUnusedCapacity(self.allocator, lifecycle_count);
    try tx.changed_accounts.ensureUnusedCapacity(self.allocator, lifecycle_count);
    try self.accepted.storage_wipes.ensureUnusedCapacity(self.allocator, lifecycle_count);
    try self.accepted.changed_accounts.ensureUnusedCapacity(self.allocator, pending_accounts);

    const checkpoint_state = self.checkpoint();
    errdefer self.revertToCheckpoint(checkpoint_state);

    for (tx.lifecycle_accounts.items) |account_id| {
        const row = tx.accounts.valuePtrById(account_id);
        if (!row.mutation.selfdestructed) {
            if (row.mutation.created) {
                try self.appendAccountUndo(account_id, row);
                row.mutation.created = false;
            }
            continue;
        }

        const policy = if (row.mutation.created) rules.created_account else rules.existing_account;
        const first_change = !row.mutation.dirty;
        try self.appendAccountUndo(account_id, row);

        if (policy.clear_storage) {
            try self.wipeTransactionStorage(tx.accounts.keyById(account_id).*);
            if (!row.mutation.storage_wiped) tx.storage_wipes.appendAssumeCapacity(account_id);
            row.mutation.storage_wiped = true;
            if (accountObservation(tx, row)) |observation|
                observation.effect.storage_wiped = true;
        }
        if (first_change and (policy.reset_account or policy.delete_account)) {
            tx.changed_accounts.appendAssumeCapacity(account_id);
        }
        if (policy.reset_account) {
            var account = switch (row.current.?) {
                .loaded => |value| value,
                .absent => Account{},
                .exists_only => unreachable,
            };
            account.nonce = 0;
            account.code_hash = crypto.keccak256_empty;
            row.current = .{ .loaded = account };
            if (accountObservation(tx, row)) |observation| {
                observation.effect.nonce_written = true;
                observation.effect.code_written = true;
            }
            row.mutation.dirty = true;
        }
        if (policy.delete_account) {
            if (accountObservation(tx, row)) |observation|
                observation.effect_current = row.current;
            row.current = .absent;
            if (accountObservation(tx, row)) |observation|
                observation.effect.account_deleted = true;
            row.mutation.dirty = true;
            row.mutation.delete_on_finalize = true;
        }
        row.mutation.created = false;
        row.mutation.selfdestructed = false;
    }
}

pub fn discardAccepted(self: *TrackedState) void {
    std.debug.assert(self.tx == null);
    const reader = self.reader;
    self.reset(reader);
}

fn logBufferView(logs: *const LogBuffer) LogView {
    return .{ .arena = .{
        .rows = logs.rows.items,
        .topics = logs.topics.items,
        .data = logs.data.items,
    } };
}

fn mutableTransaction(self: *TrackedState) *Transaction {
    std.debug.assert(self.tx != null);
    const tx = &self.tx.?;
    std.debug.assert(!tx.sealed);
    return tx;
}

fn acceptedAccountExistence(self: *TrackedState, address: Address) !AccountValue {
    if (self.accepted.accounts.get(address)) |row| return row.value;
    const exists = if (self.reader) |reader| try reader.accountExists(address) else false;
    const value: AccountValue = if (exists) .exists_only else .absent;
    try self.accepted.accounts.put(address, .{ .value = value });
    return value;
}

fn loadAcceptedAccount(self: *TrackedState, address: Address) !AccountValue {
    if (self.accepted.accounts.get(address)) |row| {
        switch (row.value) {
            .loaded, .absent => return row.value,
            .exists_only => {},
        }
    }
    const loaded = if (self.reader) |reader| try reader.loadAccount(address) else null;
    const value: AccountValue = if (loaded) |account| .{ .loaded = account } else .absent;
    if (self.accepted.accounts.getPtr(address)) |row| {
        row.value = value;
    } else {
        try self.accepted.accounts.put(address, .{ .value = value });
    }
    return value;
}

const AccountRead = enum { value, code };

fn readAccountValue(self: *TrackedState, address: Address, read: AccountRead) !AccountValue {
    if (self.tx == null) return self.loadAcceptedAccount(address);
    if (self.tx.?.sealed) {
        if (self.tx.?.accounts.get(address)) |row| {
            if (row.current) |value| switch (value) {
                .loaded, .absent => return value,
                .exists_only => {},
            };
        }
        return self.loadAcceptedAccount(address);
    }

    const account_ref = try self.materializeTransactionAccount(address);
    const row = account_ref.row;
    if (try self.observeAccount(account_ref)) |observation| {
        observation.observation.accessed = true;
        switch (read) {
            .value => observation.observation.value_read = true,
            .code => observation.observation.code_read = true,
        }
    }
    return row.current.?;
}

fn materializeTransactionAccount(self: *TrackedState, address: Address) !AccountRef {
    const tx = self.mutableTransaction();
    const result = try tx.accounts.getOrPut(address);
    if (!result.found_existing) result.value_ptr.* = .{};
    const row = result.value_ptr;
    const account_ref = AccountRef{ .id = result.entry_id, .row = row };

    const needs_load = if (row.current) |current| switch (current) {
        .exists_only => true,
        .absent, .loaded => false,
    } else true;
    if (!needs_load) return account_ref;

    std.debug.assert(!row.mutation.dirty);
    const value = try self.loadAcceptedAccount(address);
    if (row.original == null or row.original.? == .exists_only) row.original = value;
    row.current = value;
    return account_ref;
}

inline fn observeAccount(
    self: *TrackedState,
    account_ref: AccountRef,
) !?*AccountObservationRow {
    const tx = &self.tx.?;
    if (!tx.observe) return null;
    if (account_ref.row.observation_id) |id|
        return &tx.observed_accounts.items[@intFromEnum(id)];
    try tx.observed_accounts.ensureUnusedCapacity(self.allocator, 1);
    const id: AccountObservationId = @enumFromInt(index32(tx.observed_accounts.items.len));
    tx.observed_accounts.appendAssumeCapacity(.{ .account = account_ref.id });
    account_ref.row.observation_id = id;
    return &tx.observed_accounts.items[@intFromEnum(id)];
}

fn accountValue(value: AccountValue) ?Account {
    return switch (value) {
        .loaded => |account| account,
        .absent, .exists_only => null,
    };
}

fn codeView(self: *TrackedState, value: AccountValue) !CodeView {
    return switch (value) {
        .loaded => |account| .{
            .code_hash = account.code_hash,
            .bytes = try self.codeByHash(account.code_hash),
        },
        .absent => .{
            .code_hash = crypto.keccak256_empty,
            .bytes = &.{},
        },
        .exists_only => unreachable,
    };
}

fn codeByHash(self: *TrackedState, code_hash: CodeHash) ![]const u8 {
    if (std.mem.eql(u8, &code_hash, &crypto.keccak256_empty)) return &.{};
    if (self.code.entries.get(code_hash)) |entry| return entry.slice(&self.code);
    const reader = self.reader orelse return error.CodeUnavailable;
    return self.cacheCode(code_hash, try reader.loadCode(code_hash), false);
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
    _ = byteRange(0, code_bytes.len);

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
    const range = byteRange(@as(usize, chunk.used), code_bytes.len);
    const entry = CodeEntry.init(chunk_index, range, introduced);
    const start: usize = chunk.used;
    @memcpy(chunk.bytes[start..][0..code_bytes.len], code_bytes);
    chunk.used += range.len;
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
    if (self.accepted.storage.get(key)) |row| {
        if (row.changed) return row.value;
    }
    if (acceptedStorageWiped(&self.accepted, key.address)) return 0;
    if (self.accepted.storage.get(key)) |row| return row.value;
    const value = if (self.reader) |reader|
        try reader.getStorage(key.address, key.key)
    else
        0;
    try self.accepted.storage.put(key, .{ .value = value });
    return value;
}

fn materializeTransactionStorage(self: *TrackedState, key: StorageKey) !StorageRef {
    const tx = self.mutableTransaction();
    const storage_ref = try self.transactionStorageRef(tx, key);
    try self.loadStorageRef(key, storage_ref);
    return storage_ref;
}

inline fn observeStorage(
    self: *TrackedState,
    storage_ref: StorageRef,
) !?*StorageObservationRow {
    const tx = &self.tx.?;
    if (!tx.observe) return null;
    if (storage_ref.row.observation_id) |id|
        return &tx.observed_storage.items[@intFromEnum(id)];
    try tx.observed_storage.ensureUnusedCapacity(self.allocator, 1);
    const id: StorageObservationId = @enumFromInt(index32(tx.observed_storage.items.len));
    tx.observed_storage.appendAssumeCapacity(.{ .storage = storage_ref.id });
    storage_ref.row.observation_id = id;
    return &tx.observed_storage.items[@intFromEnum(id)];
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

fn loadStorageRef(self: *TrackedState, key: StorageKey, storage_ref: StorageRef) !void {
    if (storage_ref.row.current != null) return;

    const value = try self.readAcceptedStorage(key);
    storage_ref.row.transaction_original = value;
    if (transactionStorageWiped(&self.tx.?, key.address)) {
        try self.appendStorageUndo(storage_ref.id, storage_ref.row);
        storage_ref.row.current = 0;
    } else {
        storage_ref.row.current = value;
    }
}

fn accessStorageKey(self: *TrackedState, key: StorageKey) !StorageAccess {
    const access = try self.ensureStorageWarm(key);
    if (try self.observeStorage(access.storage)) |observation|
        observation.observation.accessed = true;
    return access;
}

fn ensureAccountWarm(self: *TrackedState, address: Address) !AccountAccess {
    const tx = self.mutableTransaction();
    std.debug.assert(tx.scope.active);
    const account_row = try tx.accounts.getOrPut(address);
    if (!account_row.found_existing) account_row.value_ptr.* = .{};
    if (tx.scope.warm_accounts.contains(address)) return .{
        .id = account_row.entry_id,
        .row = account_row.value_ptr,
        .status = .warm,
    };
    try tx.scope.warm_accounts.ensureUnusedCapacity(1);
    try tx.undo.appendWarmAccount(self.allocator, account_row.entry_id);
    tx.scope.warm_accounts.putAssumeCapacityNoClobber(address, {});
    return .{
        .id = account_row.entry_id,
        .row = account_row.value_ptr,
        .status = .cold,
    };
}

fn ensureStorageWarm(self: *TrackedState, key: StorageKey) !StorageAccess {
    const tx = self.mutableTransaction();
    std.debug.assert(tx.scope.active);
    const storage_ref = try self.transactionStorageRef(tx, key);
    const scope_storage = try self.scopeStorageRef(tx, key);
    if (scope_storage.warm) return .{
        .storage = storage_ref,
        .scope = scope_storage,
        .status = .warm,
    };
    try tx.undo.appendWarmStorage(self.allocator, storage_ref.id);
    scope_storage.warm = true;
    return .{
        .storage = storage_ref,
        .scope = scope_storage,
        .status = .cold,
    };
}

fn trackLifecycleAccount(self: *TrackedState, account_ref: AccountRef) !void {
    if (account_ref.row.mutation.lifecycle_tracked) return;
    const tx = &self.tx.?;
    try tx.lifecycle_accounts.ensureUnusedCapacity(self.allocator, 1);
    tx.lifecycle_accounts.appendAssumeCapacity(account_ref.id);
    account_ref.row.mutation.lifecycle_tracked = true;
}

fn reserveAcceptedAccountMutation(self: *TrackedState, address: Address) !void {
    const tx = &self.tx.?;
    try tx.changed_accounts.ensureUnusedCapacity(self.allocator, 1);
    const row = self.accepted.accounts.get(address) orelse unreachable;
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

fn wipeTransactionStorage(self: *TrackedState, address: Address) !void {
    const tx = &self.tx.?;
    var it = tx.storage.iterator();
    while (it.next()) |entry| {
        if (!std.mem.eql(u8, &entry.key_ptr.address, &address)) continue;
        try self.appendStorageUndo(entry.entry_id, entry.value_ptr);
        if (storageObservation(tx, entry.value_ptr)) |observation|
            observation.effect_current = entry.value_ptr.current;
        entry.value_ptr.current = 0;
        entry.value_ptr.mutation.dirty = true;
    }
}

fn transactionStorageWiped(tx: *const Transaction, address: Address) bool {
    const row = tx.accounts.get(address) orelse return false;
    return row.mutation.storage_wiped;
}

fn transactionDeletesAccount(tx: *const Transaction, address: Address) bool {
    const row = tx.accounts.get(address) orelse return false;
    if (!row.mutation.dirty) return false;
    return row.current.? == .absent;
}

fn compactTransactionStorageChanges(tx: *Transaction) void {
    var write_index: usize = 0;
    for (tx.changed_storage.items) |storage_id| {
        const key = tx.storage.keyById(storage_id).*;
        if (transactionStorageWiped(tx, key.address) or
            transactionDeletesAccount(tx, key.address))
        {
            continue;
        }
        tx.changed_storage.items[write_index] = storage_id;
        write_index += 1;
    }
    tx.changed_storage.items.len = write_index;
}

fn compactAcceptedStorageChanges(accepted: *Accepted, address: Address) void {
    var write_index: usize = 0;
    for (accepted.changed_storage.items) |storage_id| {
        const key = accepted.storage.keyById(storage_id).*;
        if (std.mem.eql(u8, &key.address, &address)) {
            accepted.storage.valuePtrById(storage_id).changed = false;
            continue;
        }
        accepted.changed_storage.items[write_index] = storage_id;
        write_index += 1;
    }
    accepted.changed_storage.items.len = write_index;
}

fn acceptedStorageWiped(accepted: *const Accepted, address: Address) bool {
    const row = accepted.accounts.get(address) orelse return false;
    return row.storage_wiped;
}

fn sealedTransaction(state: *const TrackedState) *const Transaction {
    const tx = if (state.tx) |*value| value else unreachable;
    std.debug.assert(tx.sealed);
    std.debug.assert(!tx.scope.active);
    return tx;
}

fn transactionShadowsStorage(tx: *const Transaction, key: StorageKey) bool {
    const row = tx.storage.get(key) orelse return false;
    return row.current != null;
}

inline fn accountObservation(
    tx: *Transaction,
    row: *const AccountRow,
) ?*AccountObservationRow {
    const id = row.observation_id orelse return null;
    return &tx.observed_accounts.items[@intFromEnum(id)];
}

inline fn storageObservation(
    tx: *Transaction,
    row: *const StorageRow,
) ?*StorageObservationRow {
    const id = row.observation_id orelse return null;
    return &tx.observed_storage.items[@intFromEnum(id)];
}

fn appendAccountUndo(self: *TrackedState, account_id: AccountId, row: *const AccountRow) !void {
    const tx = &self.tx.?;
    if (!tx.scope.active) return;
    const observation_undo: ?Journal.AccountObservationUndo =
        if (row.observation_id) |id| blk: {
            const observation = &tx.observed_accounts.items[@intFromEnum(id)];
            break :blk .{
                .row = id,
                .previous_effect_current = observation.effect_current,
                .previous_effect = observation.effect,
            };
        } else null;
    try tx.undo.appendAccount(self.allocator, .{
        .row = account_id,
        .previous_current = row.current,
        .previous_mutation = row.mutation,
    }, observation_undo);
}

fn appendStorageUndo(self: *TrackedState, storage_id: StorageId, row: *const StorageRow) !void {
    const tx = &self.tx.?;
    const observation_undo: ?Journal.StorageObservationUndo =
        if (row.observation_id) |id| blk: {
            const observation = &tx.observed_storage.items[@intFromEnum(id)];
            break :blk .{
                .row = id,
                .previous_effect_current = observation.effect_current,
                .previous_effect = observation.effect,
            };
        } else null;
    try tx.undo.appendStorage(self.allocator, .{
        .row = storage_id,
        .previous_current = row.current,
        .previous_mutation = row.mutation,
    }, observation_undo);
}

fn index32(value: usize) u32 {
    std.debug.assert(value <= std.math.maxInt(u32));
    return @intCast(value);
}

fn byteRange(offset: usize, len: usize) ByteRange {
    const offset_u32 = index32(offset);
    const len_u32 = index32(len);
    std.debug.assert(len_u32 <= std.math.maxInt(u32) - offset_u32);
    return .{ .offset = offset_u32, .len = len_u32 };
}

fn topicRange(offset: usize, len: usize) TopicRange {
    std.debug.assert(len <= 4);
    const offset_u32 = index32(offset);
    const len_u32 = index32(len);
    std.debug.assert(len_u32 <= std.math.maxInt(u32) - offset_u32);
    return .{ .offset = offset_u32, .len = @intCast(len) };
}

comptime {
    std.debug.assert(@sizeOf(ByteRange) == 8);
    std.debug.assert(@sizeOf(TopicRange) == 8);
    std.debug.assert(@sizeOf(LogBuffer.LogRow) == 36);
    std.debug.assert(@sizeOf(CodeEntry) == 12);
    std.debug.assert(@sizeOf(Journal.Entry) == 8);
}

test {
    _ = @import("./TrackedState_test.zig");
}
