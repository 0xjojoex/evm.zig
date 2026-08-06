//! Dense Amsterdam execution state over a validated BAL namespace.
//!
//! This module owns no MPT topology. It takes ownership of the `ClaimPlan` and
//! authenticated parent facts, then owns block-current values, rollback,
//! warmth, observations, and dirty IDs for the complete block execution.

const std = @import("std");

const address = @import("../address.zig");
const claim_plan = @import("../eth/bal/ClaimPlan.zig");
const crypto = @import("../crypto.zig");
const Host = @import("../Host.zig");
const Account = @import("../state/Account.zig");
const artifacts = @import("./artifacts.zig");
const records = @import("./ParentFacts.zig");
const checkpoint_types = @import("../state/checkpoint.zig");
const storage_status = @import("../state/storage.zig");
const trie = @import("../eth/trie.zig");
const SparseHashMap = @import("../state/sparse_hash_map.zig").Auto;
const Views = @import("./views.zig").ViewType(StatelessBlockState);

const Allocator = std.mem.Allocator;
const StatelessBlockState = @This();
const StorageKey = storage_status.Key;
const TransientStorageMap = SparseHashMap(StorageKey, u256);

/// Dense state must be admitted by its block domain before executor ownership.
pub const standalone_reader_initialization = false;

pub const AccountId = claim_plan.AccountId;
pub const StorageId = claim_plan.StorageId;
pub const AttemptId = checkpoint_types.AttemptId;
pub const CodeView = artifacts.CodeView;
/// Emitted logs and their borrowed projection are lane-independent; see
/// `state/LogBuffer.zig`.
pub const LogBuffer = @import("../state/LogBuffer.zig");
pub const LogView = LogBuffer.View;
pub const ChangesView = Views.ChangesView;
pub const CommitView = Views.CommitView;
pub const ObservationsView = Views.ObservationsView;
pub const AcceptedView = Views.AcceptedView;
pub const PendingView = Views.PendingView;

pub const ResolutionPolicy = enum {
    /// State reads/writes, observed system calls, and EIP-7702 authority paths
    /// after preliminary tuple validation all feed BAL reconstruction.
    required_observed,
    /// EIP-2930 list warming and delegated-target warming do not themselves
    /// emit BAL accesses; a later real access resolves through the required path.
    optional_warm_only,
};

pub const ResolutionError = error{
    UndeclaredAccount,
    UndeclaredStorage,
};

pub const CodeError = artifacts.CodeStore.CacheError;
pub const AccessHint = struct {
    accounts: usize,
    storage_keys: usize,
};

pub const AccountValue = union(enum) {
    absent,
    present: Account,
};

pub const AccountFlags = packed struct {
    block_dirty: bool = false,
    block_changed: bool = false,
    storage_dirty: bool = false,
    storage_wiped: bool = false,
    touched: bool = false,
    created: bool = false,
    selfdestructed: bool = false,
    _padding: u1 = 0,
};

pub const StorageFlags = packed struct {
    block_dirty: bool = false,
    _padding: u7 = 0,
};

pub const AccountObservation = packed struct {
    accessed: bool = false,
    semantic_access: bool = false,
    existence_read: bool = false,
    value_read: bool = false,
    code_read: bool = false,
    _padding: u3 = 0,

    fn merge(self: *AccountObservation, other: AccountObservation) void {
        self.accessed = self.accessed or other.accessed;
        self.semantic_access = self.semantic_access or other.semantic_access;
        self.existence_read = self.existence_read or other.existence_read;
        self.value_read = self.value_read or other.value_read;
        self.code_read = self.code_read or other.code_read;
    }
};

pub const StorageObservation = packed struct {
    accessed: bool = false,
    value_read: bool = false,
    _padding: u6 = 0,

    fn merge(self: *StorageObservation, other: StorageObservation) void {
        self.accessed = self.accessed or other.accessed;
        self.value_read = self.value_read or other.value_read;
    }
};

pub const AccountEffect = packed struct {
    balance_written: bool = false,
    nonce_written: bool = false,
    code_written: bool = false,
    account_deleted: bool = false,
    created_contract: bool = false,
    selfdestruct: bool = false,
    storage_wiped: bool = false,
    _padding: u1 = 0,

    pub fn any(self: AccountEffect) bool {
        return self.balance_written or self.nonce_written or
            self.code_written or self.account_deleted or
            self.created_contract or self.selfdestruct or self.storage_wiped;
    }
};

pub const StorageEffect = packed struct {
    written: bool = false,
    _padding: u7 = 0,
};

pub const AccountRow = struct {
    current: AccountValue,
    code_ref: artifacts.CodeRef,
    flags: AccountFlags = .{},
    lifecycle_tracked: bool = false,
    journal_scope_generation: u32 = 0,
    warm_generation: u32 = 0,
    observation_generation: u32 = 0,
    observation_index: u32 = 0,
    transaction_dirty_generation: u32 = 0,
    storage_generation: u32 = 0,
    storage_wipe_transaction_generation: u32 = 0,
};

pub const StorageRow = struct {
    current: u256,
    transaction_original: u256 = 0,
    execution_original: u256 = 0,
    flags: StorageFlags = .{},
    journal_scope_generation: u32 = 0,
    warm_generation: u32 = 0,
    observation_generation: u32 = 0,
    observation_index: u32 = 0,
    original_generation: u32 = 0,
    execution_original_scope_generation: u32 = 0,
    transaction_dirty_generation: u32 = 0,
    transaction_undo_index: u32 = std.math.maxInt(u32),
    storage_generation: u32 = 0,
};

pub const AccountObservationRow = struct {
    account: AccountId,
    original: AccountValue,
    original_storage_generation: u32,
    effect_current: AccountValue,
    observation: AccountObservation,
    effect: AccountEffect = .{},
};

pub const StorageObservationRow = struct {
    storage: StorageId,
    original: u256,
    effect_current: u256,
    observation: StorageObservation,
    effect: StorageEffect = .{},
};

pub const Checkpoint = checkpoint_types.Checkpoint;

pub const BranchCheckpoint = struct {
    owner: *const StatelessBlockState,
    allocator: Allocator,
    accounts: []AccountRow,
    storage: []StorageRow,
    retained_logs: LogBuffer,
    dirty_accounts_len: u32,
    block_changed_accounts_len: u32,
    block_storage_wipes_len: u32,
    dirty_storage_len: u32,
    block_introduced_codes_len: u32,
    introduced_code_len: u32,
    accepted_generation: u64,
    resolved: bool = false,

    pub fn clone(self: *const BranchCheckpoint) Allocator.Error!BranchCheckpoint {
        std.debug.assert(!self.resolved);
        const accounts = try self.allocator.dupe(AccountRow, self.accounts);
        errdefer self.allocator.free(accounts);
        const storage = try self.allocator.dupe(StorageRow, self.storage);
        errdefer self.allocator.free(storage);
        return .{
            .owner = self.owner,
            .allocator = self.allocator,
            .accounts = accounts,
            .storage = storage,
            .retained_logs = try self.retained_logs.clone(self.allocator),
            .dirty_accounts_len = self.dirty_accounts_len,
            .block_changed_accounts_len = self.block_changed_accounts_len,
            .block_storage_wipes_len = self.block_storage_wipes_len,
            .dirty_storage_len = self.dirty_storage_len,
            .block_introduced_codes_len = self.block_introduced_codes_len,
            .introduced_code_len = self.introduced_code_len,
            .accepted_generation = self.accepted_generation,
        };
    }

    pub fn deinit(self: *BranchCheckpoint) void {
        self.allocator.free(self.accounts);
        self.allocator.free(self.storage);
        self.retained_logs.deinit(self.allocator);
        self.* = undefined;
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
        /// Pops the pairwise appends to both introduced-code lists. LIFO
        /// unwind matches them exactly because every introduction appends to
        /// both lists and the journal in the same operation.
        introduced_code,

        comptime {
            std.debug.assert(@sizeOf(Entry) <= 8);
        }
    };

    const AccountUndo = struct {
        account: AccountId,
        current: AccountValue,
        code_ref: artifacts.CodeRef,
        flags: AccountFlags,
        journal_scope_generation: u32,
        storage_generation: u32,
        storage_wipe_transaction_generation: u32,
        transaction_dirty_generation: u32,
    };

    const StorageUndo = struct {
        storage: StorageId,
        current: u256,
        flags: StorageFlags,
        journal_scope_generation: u32,
        storage_generation: u32,
        transaction_dirty_generation: u32,
        transaction_undo_index: u32,
    };

    const AccountObservationUndo = struct {
        observation: u32,
        effect_current: AccountValue,
        effect: AccountEffect,
    };

    const StorageObservationUndo = struct {
        observation: u32,
        effect_current: u256,
        effect: StorageEffect,
    };

    const TransientUndo = struct {
        key: StorageKey,
        previous: ?u256,
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

    fn ensureAccountAndStorage(self: *Journal, allocator: Allocator, observed: bool) !void {
        try self.entries.ensureUnusedCapacity(allocator, 2);
        try self.accounts.ensureUnusedCapacity(allocator, 1);
        try self.storage.ensureUnusedCapacity(allocator, 1);
        if (observed) {
            try self.account_observations.ensureUnusedCapacity(allocator, 1);
            try self.storage_observations.ensureUnusedCapacity(allocator, 1);
        }
    }

    fn ensureWarm(self: *Journal, allocator: Allocator) !void {
        try self.entries.ensureUnusedCapacity(allocator, 1);
    }

    fn appendTransient(self: *Journal, allocator: Allocator, undo: TransientUndo) !void {
        try self.entries.ensureUnusedCapacity(allocator, 1);
        try self.transient.ensureUnusedCapacity(allocator, 1);
        const id: Id = @enumFromInt(index32(self.transient.items.len));
        self.transient.appendAssumeCapacity(undo);
        self.entries.appendAssumeCapacity(.{ .transient_storage = id });
    }

    fn appendAccountAssumeCapacity(
        self: *Journal,
        undo: AccountUndo,
        observation_undo: ?AccountObservationUndo,
    ) void {
        const id: Id = @enumFromInt(index32(self.accounts.items.len));
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
        const id: Id = @enumFromInt(index32(self.storage.items.len));
        self.storage.appendAssumeCapacity(undo);
        if (observation_undo) |value| {
            self.storage_observations.appendAssumeCapacity(value);
            self.entries.appendAssumeCapacity(.{ .observed_storage = id });
        } else {
            self.entries.appendAssumeCapacity(.{ .storage = id });
        }
    }
};

allocator: Allocator,
plan: claim_plan.ClaimPlan,
facts: records,
accounts: []AccountRow,
storage: []StorageRow,
code: artifacts.CodeStore,
transient_storage: TransientStorageMap,
logs: LogBuffer = .{},
retained_logs: LogBuffer = .{},
dirty_accounts: std.ArrayList(AccountId) = .empty,
block_changed_accounts: std.ArrayList(AccountId) = .empty,
block_storage_wipes: std.ArrayList(AccountId) = .empty,
dirty_storage: std.ArrayList(StorageId) = .empty,
changed_accounts: std.ArrayList(AccountId) = .empty,
changed_storage: std.ArrayList(StorageId) = .empty,
transaction_storage_wipes: std.ArrayList(AccountId) = .empty,
lifecycle_accounts: std.ArrayList(AccountId) = .empty,
block_introduced_codes: std.ArrayList(artifacts.IntroducedCodeId) = .empty,
transaction_introduced_codes: std.ArrayList(artifacts.IntroducedCodeId) = .empty,
observed_accounts: std.ArrayList(AccountObservationRow) = .empty,
observed_storage: std.ArrayList(StorageObservationRow) = .empty,
journal: Journal = .{},
transaction_generation: u32 = 0,
accepted_generation: u64 = 0,
next_attempt_id: u32 = 0,
active_attempt_id: ?AttemptId = null,
observed_attempt: bool = false,
sealed: bool = false,
next_scope_generation: u32 = 0,
active_scope_generation: u32 = 0,
execution_scope_generation: u32 = 0,
scope_depth: u32 = 0,
transaction_active: bool = false,
/// Set by `revertToCheckpoint`; only then can block or transaction ID lists
/// hold stale or duplicate entries, so revert-free transactions skip their
/// compaction passes.
transaction_scope_reverted: bool = false,
/// Admitted hot-translation execution state: two remembered address→ID
/// entries and one (account, slot)→ID entry. `ClaimPlan` is immutable for the
/// whole block, so a remembered entry can never go stale and
/// revert/retain/discard must not touch it. Full-key equality decides a hit;
/// a miss falls back to the deterministic binary search and evicts entries
/// round-robin. Two account entries cover the caller/callee alternation of
/// nested calls, which a single entry misses on every step. Every dynamic
/// translation — CALL-family targets, dynamic-address opcodes, storage
/// owners, and system calls — passes through `resolveAccount`/
/// `resolveStorage`, so these entries cover the complete translation domain.
/// Memo keys are pre-assembled address words: the probe is assembled once per
/// resolution and then compares in registers, instead of paying an align-1
/// byte ladder on every hit.
translation_account_keys: [2][3]u64 = undefined,
translation_account_ids: [2]AccountId = undefined,
translation_account_valid: [2]bool = .{ false, false },
translation_account_victim: u1 = 0,
translation_storage_slot: u256 = undefined,
translation_storage_account: AccountId = undefined,
translation_storage_id: StorageId = undefined,
translation_storage_valid: bool = false,
transaction_dirty_accounts_start: u32 = 0,
transaction_block_changed_accounts_start: u32 = 0,
transaction_block_storage_wipes_start: u32 = 0,
transaction_dirty_storage_start: u32 = 0,
transaction_introduced_codes_start: u32 = 0,

pub fn init(
    allocator: Allocator,
    plan: claim_plan.ClaimPlan,
    facts: records,
) Allocator.Error!StatelessBlockState {
    return initWithCodes(allocator, plan, facts, &.{}) catch |err| switch (err) {
        error.CodeHashCollision => unreachable,
        error.ResourceLimitExceeded => unreachable,
        error.OutOfMemory => error.OutOfMemory,
    };
}

pub fn initWithCodes(
    allocator: Allocator,
    plan: claim_plan.ClaimPlan,
    facts: records,
    codes: []const []const u8,
) artifacts.CodeStore.InitError!StatelessBlockState {
    var owned_plan = plan;
    var owned_facts = facts;
    var owns_inputs = true;
    errdefer if (owns_inputs) {
        owned_facts.deinit(allocator);
        owned_plan.deinit(allocator);
    };
    const code = try artifacts.CodeStore.init(allocator, codes);
    owns_inputs = false;
    return initWithCodeStore(allocator, owned_plan, owned_facts, code);
}

pub fn initWithParentCodes(
    allocator: Allocator,
    plan: claim_plan.ClaimPlan,
    facts: records,
    codes: []const artifacts.ParentCode,
) artifacts.CodeStore.InitError!StatelessBlockState {
    var owned_plan = plan;
    var owned_facts = facts;
    var owns_inputs = true;
    errdefer if (owns_inputs) {
        owned_facts.deinit(allocator);
        owned_plan.deinit(allocator);
    };
    const code = try artifacts.CodeStore.initHashed(allocator, codes);
    owns_inputs = false;
    return initWithCodeStore(allocator, owned_plan, owned_facts, code);
}

fn initWithCodeStore(
    allocator: Allocator,
    plan: claim_plan.ClaimPlan,
    facts: records,
    code_value: artifacts.CodeStore,
) Allocator.Error!StatelessBlockState {
    var owned_plan = plan;
    var owned_facts = facts;
    var code = code_value;
    errdefer owned_plan.deinit(allocator);
    errdefer owned_facts.deinit(allocator);
    errdefer code.deinit(allocator);
    std.debug.assert(owned_plan.accounts.len == owned_facts.accounts.len);
    std.debug.assert(owned_plan.storage.len == owned_facts.storage.len);

    const accounts = try allocator.alloc(AccountRow, owned_facts.accounts.len);
    errdefer allocator.free(accounts);
    const storage = try allocator.alloc(StorageRow, owned_facts.storage.len);
    errdefer allocator.free(storage);

    for (owned_facts.accounts, accounts) |fact, *row| {
        const current = accountExecutionValue(fact);
        row.* = .{
            .current = current,
            .code_ref = code.bind(accountCodeHash(current)),
        };
    }
    for (owned_facts.storage, storage) |fact, *row| {
        row.* = .{ .current = fact.value };
    }

    return .{
        .allocator = allocator,
        .plan = owned_plan,
        .facts = owned_facts,
        .accounts = accounts,
        .storage = storage,
        .code = code,
        .transient_storage = TransientStorageMap.init(allocator),
    };
}

pub fn reserveAccessHint(_: *StatelessBlockState, _: AccessHint) Allocator.Error!void {}

pub fn reserveAcceptedAccessHint(_: *StatelessBlockState, _: AccessHint) Allocator.Error!void {}

pub fn beginTransactionCapacityReuse(_: *StatelessBlockState) void {}

pub fn endTransactionCapacityReuse(_: *StatelessBlockState) void {}

pub fn deinit(self: *StatelessBlockState) void {
    std.debug.assert(!self.transaction_active);
    self.allocator.free(self.accounts);
    self.allocator.free(self.storage);
    self.code.deinit(self.allocator);
    self.transient_storage.deinit();
    self.logs.deinit(self.allocator);
    self.retained_logs.deinit(self.allocator);
    self.dirty_accounts.deinit(self.allocator);
    self.block_changed_accounts.deinit(self.allocator);
    self.block_storage_wipes.deinit(self.allocator);
    self.dirty_storage.deinit(self.allocator);
    self.changed_accounts.deinit(self.allocator);
    self.changed_storage.deinit(self.allocator);
    self.transaction_storage_wipes.deinit(self.allocator);
    self.lifecycle_accounts.deinit(self.allocator);
    self.block_introduced_codes.deinit(self.allocator);
    self.transaction_introduced_codes.deinit(self.allocator);
    self.observed_accounts.deinit(self.allocator);
    self.observed_storage.deinit(self.allocator);
    self.journal.deinit(self.allocator);
    self.facts.deinit(self.allocator);
    self.plan.deinit(self.allocator);
    self.* = undefined;
}

inline fn addressWords(target: address.Address) [3]u64 {
    return .{
        std.mem.readInt(u64, target[0..8], .little),
        std.mem.readInt(u64, target[8..16], .little),
        std.mem.readInt(u32, target[16..20], .little),
    };
}

pub inline fn resolveAccount(
    self: *StatelessBlockState,
    target: address.Address,
    policy: ResolutionPolicy,
) ResolutionError!?AccountId {
    const words = addressWords(target);
    inline for (0..2) |entry| {
        if (self.translation_account_valid[entry] and
            self.translation_account_keys[entry][0] == words[0] and
            self.translation_account_keys[entry][1] == words[1] and
            self.translation_account_keys[entry][2] == words[2])
        {
            return self.translation_account_ids[entry];
        }
    }
    if (self.plan.accountId(target)) |id| {
        const victim = self.translation_account_victim;
        self.translation_account_keys[victim] = words;
        self.translation_account_ids[victim] = id;
        self.translation_account_valid[victim] = true;
        self.translation_account_victim +%= 1;
        return id;
    }
    return switch (policy) {
        .required_observed => error.UndeclaredAccount,
        .optional_warm_only => null,
    };
}

pub fn resolveStorage(
    self: *StatelessBlockState,
    account: AccountId,
    slot: u256,
    policy: ResolutionPolicy,
) ResolutionError!?StorageId {
    if (self.translation_storage_valid and
        self.translation_storage_account == account and
        self.translation_storage_slot == slot)
    {
        return self.translation_storage_id;
    }
    if (self.plan.storageId(account, slot)) |id| {
        self.translation_storage_account = account;
        self.translation_storage_slot = slot;
        self.translation_storage_id = id;
        self.translation_storage_valid = true;
        return id;
    }
    return switch (policy) {
        .required_observed => error.UndeclaredStorage,
        .optional_warm_only => null,
    };
}

pub fn beginTransaction(self: *StatelessBlockState) AttemptId {
    return self.beginTransactionMode(false);
}

pub fn beginObservedTransaction(self: *StatelessBlockState) AttemptId {
    return self.beginTransactionMode(true);
}

fn beginTransactionMode(self: *StatelessBlockState, observed: bool) AttemptId {
    std.debug.assert(!self.transaction_active);
    std.debug.assert(self.journal.entries.items.len == 0);
    std.debug.assert(self.next_attempt_id != std.math.maxInt(u32));
    self.next_attempt_id += 1;
    const id: AttemptId = @enumFromInt(self.next_attempt_id);
    self.transaction_generation = nextGeneration(self.transaction_generation);
    self.active_attempt_id = id;
    self.observed_attempt = observed;
    self.sealed = false;
    self.transaction_active = true;
    self.transaction_dirty_accounts_start = index32(self.dirty_accounts.items.len);
    self.transaction_block_changed_accounts_start = index32(self.block_changed_accounts.items.len);
    self.transaction_block_storage_wipes_start = index32(self.block_storage_wipes.items.len);
    self.transaction_dirty_storage_start = index32(self.dirty_storage.items.len);
    self.transaction_introduced_codes_start = index32(self.block_introduced_codes.items.len);
    self.changed_accounts.clearRetainingCapacity();
    self.changed_storage.clearRetainingCapacity();
    self.transaction_storage_wipes.clearRetainingCapacity();
    std.debug.assert(self.lifecycle_accounts.items.len == 0);
    self.transaction_introduced_codes.clearRetainingCapacity();
    self.observed_accounts.clearRetainingCapacity();
    self.observed_storage.clearRetainingCapacity();
    self.logs.clearRetainingCapacity();
    self.retained_logs.clearRetainingCapacity();
    std.debug.assert(self.transient_storage.count() == 0);
    return id;
}

pub fn beginScope(self: *StatelessBlockState) void {
    std.debug.assert(self.transaction_active);
    std.debug.assert(!self.sealed);
    std.debug.assert(self.scope_depth == 0);
    self.active_scope_generation = self.allocateScopeGeneration();
    self.execution_scope_generation = self.active_scope_generation;
    self.scope_depth = 1;
}

pub fn closeScope(self: *StatelessBlockState) void {
    self.assertRootScope();
    self.active_scope_generation = 0;
    self.execution_scope_generation = 0;
    self.scope_depth = 0;
}

pub fn scopeActive(self: *const StatelessBlockState) bool {
    return self.scope_depth != 0;
}

pub fn seal(self: *StatelessBlockState, id: AttemptId) void {
    self.assertCurrent(id);
    std.debug.assert(!self.scopeActive());
    std.debug.assert(!self.sealed);
    self.compactTransactionStorageChanges();
    if (self.transaction_scope_reverted) self.compactTransactionStorageWipes();
    self.sealed = true;
}

/// Retain block-current values and observations; discard rollback payloads.
pub fn retain(self: *StatelessBlockState, id: AttemptId) void {
    self.assertCurrent(id);
    std.debug.assert(self.sealed);
    std.debug.assert(!self.scopeActive());
    self.journal.clearRetainingCapacity();
    std.mem.swap(LogBuffer, &self.logs, &self.retained_logs);
    if (self.transaction_scope_reverted) self.compactAcceptedAccountChanges();
    if (self.transaction_scope_reverted) self.compactAcceptedStorageWipes();
    self.compactAcceptedStorageChanges();
    self.accepted_generation += 1;
    self.finishTransaction();
}

/// Restore the block state before this transaction and discard its observations.
pub fn discard(self: *StatelessBlockState, id: AttemptId) void {
    self.assertCurrent(id);
    std.debug.assert(!self.scopeActive());
    self.revertJournalTo(0);
    self.dirty_accounts.items.len = self.transaction_dirty_accounts_start;
    self.block_changed_accounts.items.len = self.transaction_block_changed_accounts_start;
    self.block_storage_wipes.items.len = self.transaction_block_storage_wipes_start;
    self.dirty_storage.items.len = self.transaction_dirty_storage_start;
    self.block_introduced_codes.items.len = self.transaction_introduced_codes_start;
    self.observed_accounts.clearRetainingCapacity();
    self.observed_storage.clearRetainingCapacity();
    self.logs.clearRetainingCapacity();
    self.finishTransaction();
}

/// The returned value is the complete scope record: `storage_wipes_len`
/// carries the parent scope generation (the borrowed `checkpoint.Checkpoint`
/// ABI has no field for it), and the block-lifetime dirty lists need no saved
/// lengths because revert restores row flags through the journal and stale
/// entries are compacted out at `retain`.
pub fn checkpoint(self: *StatelessBlockState) Checkpoint {
    self.assertTransaction();
    std.debug.assert(self.scope_depth < std.math.maxInt(u32));
    const parent_generation = self.active_scope_generation;
    const generation = self.allocateScopeGeneration();
    self.scope_depth += 1;
    self.active_scope_generation = generation;
    return .{
        .attempt_id = self.active_attempt_id.?,
        .scope_generation = generation,
        .journal_len = index32(self.journal.entries.items.len),
        .changed_accounts_len = index32(self.changed_accounts.items.len),
        .changed_storage_len = index32(self.changed_storage.items.len),
        .storage_wipes_len = parent_generation,
        .logs = self.logs.checkpoint(),
    };
}

pub fn branchCheckpoint(self: *StatelessBlockState) Allocator.Error!BranchCheckpoint {
    std.debug.assert(!self.transaction_active);
    const accounts = try self.allocator.dupe(AccountRow, self.accounts);
    errdefer self.allocator.free(accounts);
    const storage = try self.allocator.dupe(StorageRow, self.storage);
    errdefer self.allocator.free(storage);
    return .{
        .owner = self,
        .allocator = self.allocator,
        .accounts = accounts,
        .storage = storage,
        .retained_logs = try self.retained_logs.clone(self.allocator),
        .dirty_accounts_len = index32(self.dirty_accounts.items.len),
        .block_changed_accounts_len = index32(self.block_changed_accounts.items.len),
        .block_storage_wipes_len = index32(self.block_storage_wipes.items.len),
        .dirty_storage_len = index32(self.dirty_storage.items.len),
        .block_introduced_codes_len = index32(self.block_introduced_codes.items.len),
        .introduced_code_len = index32(self.code.introducedLen()),
        .accepted_generation = self.accepted_generation,
    };
}

pub fn restoreBranch(self: *StatelessBlockState, value: *BranchCheckpoint) void {
    std.debug.assert(value.owner == self);
    std.debug.assert(!value.resolved);
    if (self.transaction_active) self.discard(self.active_attempt_id.?);
    @memcpy(self.accounts, value.accounts);
    @memcpy(self.storage, value.storage);
    self.dirty_accounts.items.len = value.dirty_accounts_len;
    self.block_changed_accounts.items.len = value.block_changed_accounts_len;
    self.block_storage_wipes.items.len = value.block_storage_wipes_len;
    self.dirty_storage.items.len = value.dirty_storage_len;
    self.block_introduced_codes.items.len = value.block_introduced_codes_len;
    self.code.truncateIntroduced(self.allocator, value.introduced_code_len);
    std.mem.swap(LogBuffer, &self.retained_logs, &value.retained_logs);
    self.accepted_generation = value.accepted_generation;
    value.resolved = true;
}

pub fn commitCheckpoint(self: *StatelessBlockState, value: Checkpoint) void {
    self.validateCheckpoint(value);
    self.active_scope_generation = value.storage_wipes_len;
    self.scope_depth -= 1;
}

/// Journal unwind restores row values and flags, so entries appended to the
/// block-lifetime dirty lists inside the reverted scope become stale
/// (flag-false) rather than being truncated here; `retain` compacts them.
/// Introduced codes unwind through their own journal entries.
pub fn revertToCheckpoint(self: *StatelessBlockState, value: Checkpoint) void {
    self.validateCheckpoint(value);
    self.transaction_scope_reverted = true;
    self.revertJournalTo(value.journal_len);
    self.changed_accounts.items.len = value.changed_accounts_len;
    self.changed_storage.items.len = value.changed_storage_len;
    self.logs.truncate(.{
        .rows_len = value.logs.rows_len,
        .topics_len = value.logs.topics_len,
        .data_len = value.logs.data_len,
    });
    self.active_scope_generation = value.storage_wipes_len;
    self.scope_depth -= 1;
}

pub fn readAccount(
    self: *StatelessBlockState,
    target: address.Address,
) (ResolutionError || Allocator.Error)!AccountValue {
    const id = (try self.resolveAccount(target, .required_observed)).?;
    // Block-system-call admission may inspect code presence before opening the
    // managed system-call attempt. The actual call records the BAL access.
    if (self.transaction_active)
        try self.observeAccount(id, .{ .accessed = true, .value_read = true });
    return self.accounts[@intFromEnum(id)].current;
}

/// Return a materialized row without creating an execution observation.
pub fn getAccount(self: *const StatelessBlockState, target: address.Address) ?Account {
    const id = self.plan.accountId(target) orelse return null;
    return accountValue(self.accounts[@intFromEnum(id)].current);
}

pub fn getAccountOrLoad(
    self: *StatelessBlockState,
    target: address.Address,
) (ResolutionError || Allocator.Error)!?Account {
    return accountValue(try self.readAccount(target));
}

pub fn accountExists(
    self: *StatelessBlockState,
    target: address.Address,
) (ResolutionError || Allocator.Error)!bool {
    const id = (try self.resolveAccount(target, .required_observed)).?;
    if (self.transaction_active)
        try self.observeAccount(id, .{ .accessed = true, .existence_read = true });
    return self.accounts[@intFromEnum(id)].current == .present;
}

pub fn getBalance(
    self: *StatelessBlockState,
    target: address.Address,
) (ResolutionError || Allocator.Error)!u256 {
    return switch (try self.readAccount(target)) {
        .absent => 0,
        .present => |account_value| account_value.balance,
    };
}

pub fn getNonce(
    self: *StatelessBlockState,
    target: address.Address,
) (ResolutionError || Allocator.Error)!u64 {
    return switch (try self.readAccount(target)) {
        .absent => 0,
        .present => |account_value| account_value.nonce,
    };
}

pub fn setNonce(
    self: *StatelessBlockState,
    target: address.Address,
    nonce: u64,
) (ResolutionError || Allocator.Error)!void {
    const id = (try self.resolveAccount(target, .required_observed)).?;
    const current = self.accounts[@intFromEnum(id)].current;
    var account_value = switch (current) {
        .absent => Account{},
        .present => |value| value,
    };
    if (current == .present and account_value.nonce == nonce) return;
    account_value.nonce = nonce;
    try self.writeAccount(id, .{ .present = account_value });
}

pub fn getCodeView(
    self: *StatelessBlockState,
    target: address.Address,
) (ResolutionError || Allocator.Error || error{InvalidWitness})!CodeView {
    const id = (try self.resolveAccount(target, .required_observed)).?;
    if (self.transaction_active)
        try self.observeAccount(id, .{ .accessed = true, .code_read = true });
    const row = self.accounts[@intFromEnum(id)];
    const view = self.code.view(row.code_ref) orelse
        self.code.lookup(accountCodeHash(row.current)) orelse return error.InvalidWitness;
    std.debug.assert(std.mem.eql(u8, &view.code_hash, &accountCodeHash(row.current)));
    return view;
}

pub fn getCode(
    self: *StatelessBlockState,
    target: address.Address,
) (ResolutionError || Allocator.Error || error{InvalidWitness})![]const u8 {
    return (try self.getCodeView(target)).bytes;
}

pub fn getCodeHash(
    self: *StatelessBlockState,
    target: address.Address,
) (ResolutionError || Allocator.Error)!u256 {
    return switch (try self.readAccount(target)) {
        .absent => 0,
        .present => |value| std.mem.readInt(u256, &value.code_hash, .big),
    };
}

pub fn accountHasCode(
    self: *StatelessBlockState,
    target: address.Address,
) (ResolutionError || Allocator.Error)!bool {
    return switch (try self.readAccount(target)) {
        .absent => false,
        .present => |value| !std.mem.eql(u8, &value.code_hash, &crypto.keccak256_empty),
    };
}

pub fn setBalance(
    self: *StatelessBlockState,
    target: address.Address,
    balance: u256,
) (ResolutionError || Allocator.Error)!void {
    const id = (try self.resolveAccount(target, .required_observed)).?;
    const current = self.accounts[@intFromEnum(id)].current;
    var account_value = switch (current) {
        .absent => Account{},
        .present => |value| value,
    };
    if (current == .present and account_value.balance == balance) return;
    account_value.balance = balance;
    try self.writeAccount(id, .{ .present = account_value });
}

pub fn addBalance(
    self: *StatelessBlockState,
    target: address.Address,
    value: u256,
) (ResolutionError || Allocator.Error || error{BalanceOverflow})!void {
    if (value == 0) return;
    const balance = try self.getBalance(target);
    try self.setBalance(
        target,
        std.math.add(u256, balance, value) catch return error.BalanceOverflow,
    );
}

pub fn subtractBalance(
    self: *StatelessBlockState,
    target: address.Address,
    value: u256,
) (ResolutionError || Allocator.Error)!bool {
    if (value == 0) return true;
    const balance = try self.getBalance(target);
    if (balance < value) return false;
    try self.setBalance(target, balance - value);
    return true;
}

pub fn touchAccount(
    self: *StatelessBlockState,
    target: address.Address,
) (ResolutionError || Allocator.Error)!void {
    const id = (try self.resolveAccount(target, .required_observed)).?;
    try self.observeAccount(id, .{ .accessed = true });
    const row = &self.accounts[@intFromEnum(id)];
    if (row.flags.touched) return;
    const mutable = try self.prepareAccountMutation(id);
    if (mutable.current == .absent) {
        mutable.current = .{ .present = .{} };
        self.observed_accounts.items[mutable.observation_index].effect_current = mutable.current;
    }
    mutable.flags.touched = true;
}

pub fn setCode(
    self: *StatelessBlockState,
    target: address.Address,
    bytes: []const u8,
) (ResolutionError || CodeError)!void {
    const id = (try self.resolveAccount(target, .required_observed)).?;
    try self.observeAccount(id, .{
        .accessed = true,
        .semantic_access = true,
        .value_read = true,
    });
    const introduced_len = self.code.introducedLen();
    const cached = try self.code.cacheIntroduced(self.allocator, bytes);
    errdefer self.code.truncateIntroduced(self.allocator, introduced_len);
    if (cached.newly_introduced != null) {
        try self.block_introduced_codes.ensureUnusedCapacity(self.allocator, 1);
        try self.transaction_introduced_codes.ensureUnusedCapacity(self.allocator, 1);
        // Two entries: prepareAccountMutation may consume one for its undo.
        try self.journal.entries.ensureUnusedCapacity(self.allocator, 2);
    }
    const row = try self.prepareAccountMutation(id);
    const previous = row.current;
    var account_value = switch (previous) {
        .absent => Account{},
        .present => |value| value,
    };
    if (cached.newly_introduced) |introduced| {
        self.block_introduced_codes.appendAssumeCapacity(introduced);
        self.transaction_introduced_codes.appendAssumeCapacity(introduced);
        self.journal.entries.appendAssumeCapacity(.introduced_code);
    }
    account_value.code_hash = cached.view.code_hash;
    row.current = .{ .present = account_value };
    row.code_ref = cached.ref;
    recordAccountEffect(&self.observed_accounts.items[row.observation_index], previous, row.current);
}

pub fn clearCode(
    self: *StatelessBlockState,
    target: address.Address,
) (ResolutionError || CodeError)!void {
    try self.setCode(target, &.{});
}

pub fn writeAccount(
    self: *StatelessBlockState,
    id: AccountId,
    value: AccountValue,
) Allocator.Error!void {
    self.assertTransaction();
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
    recordAccountEffect(&self.observed_accounts.items[row.observation_index], previous, value);
}

pub fn markCreatedId(self: *StatelessBlockState, id: AccountId) Allocator.Error!void {
    try self.observeAccount(id, .{ .accessed = true, .semantic_access = true });
    const row = try self.prepareLifecycleMutation(id);
    row.flags.created = true;
    self.observed_accounts.items[row.observation_index].effect.created_contract = true;
}

pub fn markSelfdestructedId(self: *StatelessBlockState, id: AccountId) Allocator.Error!void {
    try self.observeAccount(id, .{ .accessed = true, .semantic_access = true });
    const row = try self.prepareLifecycleMutation(id);
    row.flags.selfdestructed = true;
    self.observed_accounts.items[row.observation_index].effect.selfdestruct = true;
}

pub fn markCreatedContract(
    self: *StatelessBlockState,
    target: address.Address,
) (ResolutionError || Allocator.Error)!void {
    const id = (try self.resolveAccount(target, .required_observed)).?;
    if (self.accounts[@intFromEnum(id)].flags.created) return;
    try self.markCreatedId(id);
}

pub fn markSelfdestructed(
    self: *StatelessBlockState,
    target: address.Address,
) (ResolutionError || Allocator.Error)!void {
    const id = (try self.resolveAccount(target, .required_observed)).?;
    if (self.accounts[@intFromEnum(id)].flags.selfdestructed) return;
    try self.markSelfdestructedId(id);
}

pub fn createdInTransaction(self: *const StatelessBlockState, target: address.Address) bool {
    const id = self.plan.accountId(target) orelse return false;
    return self.transaction_active and self.accounts[@intFromEnum(id)].flags.created;
}

pub fn wasSelfdestructed(self: *const StatelessBlockState, target: address.Address) bool {
    const id = self.plan.accountId(target) orelse return false;
    return self.transaction_active and self.accounts[@intFromEnum(id)].flags.selfdestructed;
}

pub fn finalize(self: *StatelessBlockState, rules: anytype) Allocator.Error!void {
    self.assertTransaction();
    if (self.lifecycle_accounts.items.len == 0) return;
    for (self.lifecycle_accounts.items) |id| {
        const index = @intFromEnum(id);
        const row_value = self.accounts[index];
        if (!row_value.flags.created and !row_value.flags.selfdestructed) continue;
        if (!row_value.flags.selfdestructed) {
            const row = try self.prepareAccountMutation(id);
            row.flags.created = false;
            continue;
        }

        const policy = if (row_value.flags.created)
            rules.created_account
        else
            rules.existing_account;
        if (policy.clear_storage) try self.wipeStorage(id);
        if (policy.reset_account) {
            var account_value = switch (self.accounts[index].current) {
                .absent => Account{},
                .present => |account| account,
            };
            account_value.nonce = 0;
            account_value.code_hash = crypto.keccak256_empty;
            try self.writeAccount(id, if (account_value.balance == 0)
                .absent
            else
                .{ .present = account_value });
        } else if (policy.delete_account) {
            try self.writeAccount(id, .absent);
        }
        const row = try self.prepareAccountMutation(id);
        row.flags.created = false;
        row.flags.selfdestructed = false;
    }
}

pub fn discardAccepted(self: *StatelessBlockState) void {
    std.debug.assert(!self.transaction_active);
    self.code.truncateIntroduced(self.allocator, 0);
    for (self.facts.accounts, self.accounts) |fact, *row| {
        const current = accountExecutionValue(fact);
        row.* = .{
            .current = current,
            .code_ref = self.code.bind(accountCodeHash(current)),
        };
    }
    for (self.facts.storage, self.storage) |fact, *row| {
        row.* = .{ .current = fact.value };
    }
    self.dirty_accounts.clearRetainingCapacity();
    self.block_changed_accounts.clearRetainingCapacity();
    self.block_storage_wipes.clearRetainingCapacity();
    self.dirty_storage.clearRetainingCapacity();
    self.block_introduced_codes.clearRetainingCapacity();
    self.retained_logs.clearRetainingCapacity();
    self.accepted_generation += 1;
}

/// Hide all parent and prior-block storage without fabricating slot accesses.
pub fn wipeStorage(self: *StatelessBlockState, id: AccountId) Allocator.Error!void {
    try self.observeAccount(id, .{ .accessed = true, .semantic_access = true });
    const original = &self.accounts[@intFromEnum(id)];
    const first_block_wipe = !original.flags.storage_wiped;
    const first_transaction_wipe = original.storage_wipe_transaction_generation !=
        self.transaction_generation;
    if (first_block_wipe)
        try self.block_storage_wipes.ensureUnusedCapacity(self.allocator, 1);
    if (first_transaction_wipe)
        try self.transaction_storage_wipes.ensureUnusedCapacity(self.allocator, 1);
    const row = try self.prepareAccountMutation(id);
    if (first_block_wipe) self.block_storage_wipes.appendAssumeCapacity(id);
    if (first_transaction_wipe) self.transaction_storage_wipes.appendAssumeCapacity(id);
    row.flags.storage_dirty = true;
    row.flags.storage_wiped = true;
    row.storage_generation = nextGeneration(row.storage_generation);
    row.storage_wipe_transaction_generation = self.transaction_generation;
    self.observed_accounts.items[row.observation_index].effect.storage_wiped = true;
}

pub fn getStorage(
    self: *StatelessBlockState,
    target: address.Address,
    slot: u256,
) (ResolutionError || Allocator.Error)!u256 {
    const account = (try self.resolveAccount(target, .required_observed)).?;
    try self.observeAccount(account, .{ .accessed = true });
    const id = (try self.resolveStorage(account, slot, .required_observed)).?;
    self.captureStorageOriginal(id);
    try self.observeStorage(id, .{ .accessed = true, .value_read = true });
    return self.effectiveStorage(id);
}

pub fn accessStorage(
    self: *StatelessBlockState,
    target: address.Address,
    slot: u256,
) (ResolutionError || Allocator.Error)!Host.AccessStatus {
    const account = (try self.resolveAccount(target, .optional_warm_only)) orelse return .cold;
    const id = (try self.resolveStorage(account, slot, .optional_warm_only)) orelse return .cold;
    return if (try self.warmStorageId(id)) .cold else .warm;
}

pub fn loadStorage(
    self: *StatelessBlockState,
    target: address.Address,
    slot: u256,
) (ResolutionError || Allocator.Error)!Host.StorageLoadResult {
    const access_status = try self.accessStorage(target, slot);
    return .{
        .value = try self.getStorage(target, slot),
        .access_status = access_status,
    };
}

pub fn setStorage(
    self: *StatelessBlockState,
    target: address.Address,
    slot: u256,
    value: u256,
) (ResolutionError || Allocator.Error)!Host.StorageStatus {
    const account = (try self.resolveAccount(target, .required_observed)).?;
    try self.observeAccount(account, .{ .accessed = true });
    const id = (try self.resolveStorage(account, slot, .required_observed)).?;
    self.captureStorageOriginal(id);
    try self.observeStorage(id, .{ .accessed = true, .value_read = true });
    self.captureExecutionOriginal(id);
    const row = &self.storage[@intFromEnum(id)];
    const status = storage_status.status(row.execution_original, self.effectiveStorage(id), value);
    if (self.effectiveStorage(id) != value) try self.writeStorage(id, value);
    return status;
}

pub fn storeStorage(
    self: *StatelessBlockState,
    target: address.Address,
    slot: u256,
    value: u256,
) (ResolutionError || Allocator.Error)!Host.StorageStoreResult {
    const access_status = try self.accessStorage(target, slot);
    return .{
        .storage_status = try self.setStorage(target, slot, value),
        .access_status = access_status,
    };
}

pub fn originalStorage(
    self: *StatelessBlockState,
    target: address.Address,
    slot: u256,
) (ResolutionError || Allocator.Error)!u256 {
    const account = (try self.resolveAccount(target, .required_observed)).?;
    try self.observeAccount(account, .{ .accessed = true });
    const id = (try self.resolveStorage(account, slot, .required_observed)).?;
    self.captureStorageOriginal(id);
    try self.observeStorage(id, .{ .accessed = true, .value_read = true });
    self.captureExecutionOriginal(id);
    return self.storage[@intFromEnum(id)].execution_original;
}

pub fn accountHasStorage(
    self: *StatelessBlockState,
    target: address.Address,
) (ResolutionError || Allocator.Error)!bool {
    const id = (try self.resolveAccount(target, .required_observed)).?;
    try self.observeAccount(id, .{ .accessed = true, .existence_read = true });
    const row = &self.accounts[@intFromEnum(id)];
    const range = self.plan.accounts[@intFromEnum(id)].storage;
    const begin: usize = range.start;
    const end: usize = range.end();
    for (self.storage[begin..end]) |storage_row| {
        if (storage_row.storage_generation == row.storage_generation and storage_row.current != 0)
            return true;
    }
    if (row.flags.storage_wiped) return false;
    return switch (self.facts.accounts[@intFromEnum(id)].parent) {
        .absent => false,
        .present => |parent| !std.mem.eql(u8, &parent.storage_root, &trie.empty_root_hash),
    };
}

pub fn getTransientStorage(
    self: *StatelessBlockState,
    target: address.Address,
    key: u256,
) u256 {
    self.assertTransaction();
    return self.transient_storage.get(.{ .address = target, .key = key }) orelse 0;
}

pub fn setTransientStorage(
    self: *StatelessBlockState,
    target: address.Address,
    key: u256,
    value: u256,
) !void {
    self.assertTransaction();
    const storage_key = StorageKey{ .address = target, .key = key };
    const previous = self.transient_storage.get(storage_key);
    if ((previous orelse 0) == value) return;
    if (previous == null and value != 0)
        try self.transient_storage.ensureUnusedCapacity(1);
    try self.journal.appendTransient(self.allocator, .{
        .key = storage_key,
        .previous = previous,
    });
    if (value == 0) {
        _ = self.transient_storage.remove(storage_key);
    } else {
        self.transient_storage.putAssumeCapacity(storage_key, value);
    }
}

pub fn emitLog(self: *StatelessBlockState, event_log: Host.Log) !void {
    self.assertTransaction();
    try self.logs.append(self.allocator, event_log);
}

pub fn logView(self: *const StatelessBlockState) LogView {
    return if (self.transaction_active) self.logs.view() else self.retained_logs.view();
}

pub fn clearLogs(self: *StatelessBlockState) void {
    const logs = if (self.transaction_active) &self.logs else &self.retained_logs;
    logs.clearRetainingCapacity();
}

pub fn pendingView(self: *const StatelessBlockState) PendingView {
    return .{ .state = self };
}

pub fn acceptedView(self: *const StatelessBlockState) AcceptedView {
    std.debug.assert(!self.transaction_active);
    return .{ .state = self };
}

pub fn storageValueForView(self: *const StatelessBlockState, id: StorageId) u256 {
    return self.effectiveStorage(id);
}

pub fn acceptedAccountValueForView(
    self: *const StatelessBlockState,
    id: AccountId,
) AccountValue {
    const row = &self.accounts[@intFromEnum(id)];
    if (!self.transaction_active or
        row.transaction_dirty_generation != self.transaction_generation) return row.current;
    std.debug.assert(row.observation_generation == self.transaction_generation);
    return self.observed_accounts.items[row.observation_index].original;
}

pub fn acceptedStorageValueForView(
    self: *const StatelessBlockState,
    id: StorageId,
) u256 {
    if (!self.transaction_active) return self.effectiveStorage(id);
    const account = self.plan.storage[@intFromEnum(id)].account;
    const account_row = &self.accounts[@intFromEnum(account)];
    const account_generation = if (account_row.observation_generation == self.transaction_generation)
        self.observed_accounts.items[account_row.observation_index].original_storage_generation
    else
        account_row.storage_generation;
    const row = &self.storage[@intFromEnum(id)];
    const changed = row.transaction_dirty_generation == self.transaction_generation;
    const value = if (changed)
        self.journal.storage.items[row.transaction_undo_index].current
    else
        row.current;
    const storage_generation = if (changed)
        self.journal.storage.items[row.transaction_undo_index].storage_generation
    else
        row.storage_generation;
    return if (storage_generation == account_generation) value else 0;
}

pub fn writeStorage(
    self: *StatelessBlockState,
    id: StorageId,
    value: u256,
) Allocator.Error!void {
    self.assertTransaction();
    const account = self.plan.storage[@intFromEnum(id)].account;
    try self.observeAccount(account, .{ .accessed = true });
    self.captureStorageOriginal(id);
    self.captureExecutionOriginal(id);
    try self.observeStorage(id, .{ .accessed = true, .value_read = true });

    const account_row = &self.accounts[@intFromEnum(account)];
    const storage_row = &self.storage[@intFromEnum(id)];
    const account_needs_undo = account_row.journal_scope_generation != self.active_scope_generation;
    const storage_needs_undo = storage_row.journal_scope_generation != self.active_scope_generation;
    const first_account_dirty = !account_row.flags.block_dirty;
    const first_storage_dirty = !storage_row.flags.block_dirty;
    const first_transaction_storage =
        storage_row.transaction_dirty_generation != self.transaction_generation;

    if (account_needs_undo and storage_needs_undo) {
        try self.journal.ensureAccountAndStorage(self.allocator, true);
    } else {
        if (account_needs_undo) try self.journal.ensureAccount(self.allocator, true);
        if (storage_needs_undo) try self.journal.ensureStorage(self.allocator, true);
    }
    if (first_account_dirty) try self.dirty_accounts.ensureUnusedCapacity(self.allocator, 1);
    if (first_storage_dirty) try self.dirty_storage.ensureUnusedCapacity(self.allocator, 1);
    if (first_transaction_storage) try self.changed_storage.ensureUnusedCapacity(self.allocator, 1);

    if (account_needs_undo) self.appendAccountUndo(account, account_row);
    if (storage_needs_undo) self.appendStorageUndo(id, storage_row);
    if (first_account_dirty) {
        account_row.flags.block_dirty = true;
        self.dirty_accounts.appendAssumeCapacity(account);
    }
    if (first_storage_dirty) {
        storage_row.flags.block_dirty = true;
        self.dirty_storage.appendAssumeCapacity(id);
    }
    if (first_transaction_storage) {
        std.debug.assert(storage_row.transaction_undo_index != std.math.maxInt(u32));
        storage_row.transaction_dirty_generation = self.transaction_generation;
        self.changed_storage.appendAssumeCapacity(id);
    }
    account_row.flags.storage_dirty = true;
    storage_row.current = value;
    storage_row.storage_generation = account_row.storage_generation;
    const observation = &self.observed_storage.items[storage_row.observation_index];
    observation.effect_current = value;
    observation.effect.written = true;
}

pub fn warmAccountAddress(
    self: *StatelessBlockState,
    target: address.Address,
    policy: ResolutionPolicy,
) (ResolutionError || Allocator.Error)!?bool {
    const id = (try self.resolveAccount(target, policy)) orelse return null;
    return try self.warmAccountId(id);
}

pub fn warmStorageSlot(
    self: *StatelessBlockState,
    account: AccountId,
    slot: u256,
    policy: ResolutionPolicy,
) (ResolutionError || Allocator.Error)!?bool {
    const id = (try self.resolveStorage(account, slot, policy)) orelse return null;
    return try self.warmStorageId(id);
}

pub fn warmAccount(self: *StatelessBlockState, target: address.Address) Allocator.Error!void {
    _ = self.warmAccountAddress(target, .optional_warm_only) catch |err| switch (err) {
        error.UndeclaredAccount, error.UndeclaredStorage => unreachable,
        error.OutOfMemory => return error.OutOfMemory,
    };
}

pub fn warmStorage(
    self: *StatelessBlockState,
    target: address.Address,
    slot: u256,
) Allocator.Error!void {
    const account = (self.resolveAccount(target, .optional_warm_only) catch unreachable) orelse return;
    _ = self.warmStorageSlot(account, slot, .optional_warm_only) catch |err| switch (err) {
        error.UndeclaredAccount, error.UndeclaredStorage => unreachable,
        error.OutOfMemory => return error.OutOfMemory,
    };
}

pub fn isAccountWarm(self: *StatelessBlockState, target: address.Address) bool {
    const id = (self.resolveAccount(target, .optional_warm_only) catch unreachable) orelse return false;
    return self.accountWarm(id);
}

pub fn isStorageWarm(self: *StatelessBlockState, target: address.Address, slot: u256) bool {
    const account = (self.resolveAccount(target, .optional_warm_only) catch unreachable) orelse return false;
    const id = (self.resolveStorage(account, slot, .optional_warm_only) catch unreachable) orelse return false;
    return self.storageWarm(id);
}

pub fn observeAccountAccess(
    self: *StatelessBlockState,
    target: address.Address,
) (ResolutionError || Allocator.Error)!void {
    const id = (try self.resolveAccount(target, .required_observed)).?;
    try self.observeAccount(id, .{ .accessed = true, .semantic_access = true });
}

pub fn warmAccountId(self: *StatelessBlockState, id: AccountId) Allocator.Error!bool {
    self.assertTransaction();
    const row = &self.accounts[@intFromEnum(id)];
    if (row.warm_generation == self.transaction_generation) return false;
    try self.journal.ensureWarm(self.allocator);
    self.journal.entries.appendAssumeCapacity(.{ .warm_account = id });
    row.warm_generation = self.transaction_generation;
    return true;
}

pub fn warmStorageId(self: *StatelessBlockState, id: StorageId) Allocator.Error!bool {
    self.assertTransaction();
    const row = &self.storage[@intFromEnum(id)];
    if (row.warm_generation == self.transaction_generation) return false;
    try self.journal.ensureWarm(self.allocator);
    self.journal.entries.appendAssumeCapacity(.{ .warm_storage = id });
    row.warm_generation = self.transaction_generation;
    return true;
}

pub fn accountWarm(self: *const StatelessBlockState, id: AccountId) bool {
    return self.accounts[@intFromEnum(id)].warm_generation == self.transaction_generation;
}

pub fn storageWarm(self: *const StatelessBlockState, id: StorageId) bool {
    return self.storage[@intFromEnum(id)].warm_generation == self.transaction_generation;
}

pub fn observeAccount(
    self: *StatelessBlockState,
    id: AccountId,
    observation: AccountObservation,
) Allocator.Error!void {
    self.assertTransaction();
    const row = &self.accounts[@intFromEnum(id)];
    if (row.observation_generation != self.transaction_generation) {
        try self.observed_accounts.ensureUnusedCapacity(self.allocator, 1);
        row.observation_generation = self.transaction_generation;
        row.observation_index = index32(self.observed_accounts.items.len);
        self.observed_accounts.appendAssumeCapacity(.{
            .account = id,
            .original = row.current,
            .original_storage_generation = row.storage_generation,
            .effect_current = row.current,
            .observation = observation,
        });
        return;
    }
    self.observed_accounts.items[row.observation_index].observation.merge(observation);
}

pub fn observeStorage(
    self: *StatelessBlockState,
    id: StorageId,
    observation: StorageObservation,
) Allocator.Error!void {
    self.assertTransaction();
    const row = &self.storage[@intFromEnum(id)];
    if (row.observation_generation != self.transaction_generation) {
        try self.observed_storage.ensureUnusedCapacity(self.allocator, 1);
        const original = if (row.original_generation == self.transaction_generation)
            row.transaction_original
        else
            self.effectiveStorage(id);
        row.observation_generation = self.transaction_generation;
        row.observation_index = index32(self.observed_storage.items.len);
        row.transaction_undo_index = std.math.maxInt(u32);
        self.observed_storage.appendAssumeCapacity(.{
            .storage = id,
            .original = original,
            .effect_current = self.effectiveStorage(id),
            .observation = observation,
        });
        return;
    }
    self.observed_storage.items[row.observation_index].observation.merge(observation);
}

pub fn allocationBytes(self: *const StatelessBlockState) usize {
    return self.accounts.len * @sizeOf(AccountRow) +
        self.storage.len * @sizeOf(StorageRow) +
        self.code.allocationBytes() +
        self.transient_storage.allocationBytes() +
        self.logs.allocationBytes() +
        self.retained_logs.allocationBytes() +
        self.dirty_accounts.capacity * @sizeOf(AccountId) +
        self.block_changed_accounts.capacity * @sizeOf(AccountId) +
        self.block_storage_wipes.capacity * @sizeOf(AccountId) +
        self.dirty_storage.capacity * @sizeOf(StorageId) +
        self.changed_accounts.capacity * @sizeOf(AccountId) +
        self.changed_storage.capacity * @sizeOf(StorageId) +
        self.transaction_storage_wipes.capacity * @sizeOf(AccountId) +
        self.lifecycle_accounts.capacity * @sizeOf(AccountId) +
        self.block_introduced_codes.capacity * @sizeOf(artifacts.IntroducedCodeId) +
        self.transaction_introduced_codes.capacity * @sizeOf(artifacts.IntroducedCodeId) +
        self.observed_accounts.capacity * @sizeOf(AccountObservationRow) +
        self.observed_storage.capacity * @sizeOf(StorageObservationRow) +
        self.journal.entries.capacity * @sizeOf(Journal.Entry) +
        self.journal.accounts.capacity * @sizeOf(Journal.AccountUndo) +
        self.journal.storage.capacity * @sizeOf(Journal.StorageUndo) +
        self.journal.account_observations.capacity * @sizeOf(Journal.AccountObservationUndo) +
        self.journal.storage_observations.capacity * @sizeOf(Journal.StorageObservationUndo) +
        self.journal.transient.capacity * @sizeOf(Journal.TransientUndo);
}

pub fn journalLen(self: *const StatelessBlockState) usize {
    return self.journal.entries.items.len;
}

fn captureStorageOriginal(self: *StatelessBlockState, id: StorageId) void {
    const row = &self.storage[@intFromEnum(id)];
    if (row.original_generation == self.transaction_generation) return;
    const account_id = self.plan.storage[@intFromEnum(id)].account;
    const account = &self.accounts[@intFromEnum(account_id)];
    row.transaction_original = if (account.storage_wipe_transaction_generation == self.transaction_generation)
        row.current
    else
        self.effectiveStorage(id);
    row.original_generation = self.transaction_generation;
}

fn captureExecutionOriginal(self: *StatelessBlockState, id: StorageId) void {
    const row = &self.storage[@intFromEnum(id)];
    if (row.execution_original_scope_generation == self.execution_scope_generation) return;
    std.debug.assert(self.execution_scope_generation != 0);
    row.execution_original = self.effectiveStorage(id);
    row.execution_original_scope_generation = self.execution_scope_generation;
}

fn effectiveStorage(self: *const StatelessBlockState, id: StorageId) u256 {
    const claim = self.plan.storage[@intFromEnum(id)];
    const account = &self.accounts[@intFromEnum(claim.account)];
    const row = &self.storage[@intFromEnum(id)];
    if (row.storage_generation != account.storage_generation) return 0;
    return row.current;
}

/// Drops wiped-away rows and entries orphaned by scope reverts (their flag is
/// already false), and deduplicates revert-then-redirty repeats: pass one
/// consumes each row's flag so only the first live occurrence survives, pass
/// two restores the flag on the kept entries.
fn compactAcceptedStorageChanges(self: *StatelessBlockState) void {
    var write: usize = 0;
    for (self.dirty_storage.items) |id| {
        const claim = self.plan.storage[@intFromEnum(id)];
        const row = &self.storage[@intFromEnum(id)];
        if (!row.flags.block_dirty) continue;
        row.flags.block_dirty = false;
        const current = row.storage_generation ==
            self.accounts[@intFromEnum(claim.account)].storage_generation;
        if (!current) continue;
        self.dirty_storage.items[write] = id;
        write += 1;
    }
    for (self.dirty_storage.items[0..write]) |id| {
        self.storage[@intFromEnum(id)].flags.block_dirty = true;
    }
    self.dirty_storage.items.len = write;
}

/// Same stale-entry compaction for the block-lifetime account lists: scope
/// reverts leave flag-false entries behind instead of truncating, so retain
/// filters and deduplicates them with the same consume-then-restore passes.
fn compactAcceptedAccountChanges(self: *StatelessBlockState) void {
    var dirty_write: usize = 0;
    for (self.dirty_accounts.items) |id| {
        const row = &self.accounts[@intFromEnum(id)];
        if (!row.flags.block_dirty) continue;
        row.flags.block_dirty = false;
        self.dirty_accounts.items[dirty_write] = id;
        dirty_write += 1;
    }
    for (self.dirty_accounts.items[0..dirty_write]) |id| {
        self.accounts[@intFromEnum(id)].flags.block_dirty = true;
    }
    self.dirty_accounts.items.len = dirty_write;

    var changed_write: usize = 0;
    for (self.block_changed_accounts.items) |id| {
        const row = &self.accounts[@intFromEnum(id)];
        if (!row.flags.block_changed) continue;
        row.flags.block_changed = false;
        self.block_changed_accounts.items[changed_write] = id;
        changed_write += 1;
    }
    for (self.block_changed_accounts.items[0..changed_write]) |id| {
        self.accounts[@intFromEnum(id)].flags.block_changed = true;
    }
    self.block_changed_accounts.items.len = changed_write;
}

fn compactAcceptedStorageWipes(self: *StatelessBlockState) void {
    var write: usize = 0;
    for (self.block_storage_wipes.items) |id| {
        const row = &self.accounts[@intFromEnum(id)];
        if (!row.flags.storage_wiped) continue;
        row.flags.storage_wiped = false;
        self.block_storage_wipes.items[write] = id;
        write += 1;
    }
    for (self.block_storage_wipes.items[0..write]) |id|
        self.accounts[@intFromEnum(id)].flags.storage_wiped = true;
    self.block_storage_wipes.items.len = write;
}

fn compactTransactionStorageWipes(self: *StatelessBlockState) void {
    var write: usize = 0;
    for (self.transaction_storage_wipes.items) |id| {
        const row = &self.accounts[@intFromEnum(id)];
        if (row.storage_wipe_transaction_generation != self.transaction_generation) continue;
        row.storage_wipe_transaction_generation = 0;
        self.transaction_storage_wipes.items[write] = id;
        write += 1;
    }
    for (self.transaction_storage_wipes.items[0..write]) |id|
        self.accounts[@intFromEnum(id)].storage_wipe_transaction_generation =
            self.transaction_generation;
    self.transaction_storage_wipes.items.len = write;
}

fn compactTransactionStorageChanges(self: *StatelessBlockState) void {
    var write: usize = 0;
    for (self.changed_storage.items) |id| {
        const claim = self.plan.storage[@intFromEnum(id)];
        const row = &self.storage[@intFromEnum(id)];
        if (row.storage_generation !=
            self.accounts[@intFromEnum(claim.account)].storage_generation) continue;
        self.changed_storage.items[write] = id;
        write += 1;
    }
    self.changed_storage.items.len = write;
}

fn prepareAccountMutation(
    self: *StatelessBlockState,
    id: AccountId,
) Allocator.Error!*AccountRow {
    const row = &self.accounts[@intFromEnum(id)];
    const needs_undo = row.journal_scope_generation != self.active_scope_generation;
    const first_dirty = !row.flags.block_dirty;
    const first_block_change = !row.flags.block_changed;
    const first_transaction_dirty =
        row.transaction_dirty_generation != self.transaction_generation;
    if (needs_undo) try self.journal.ensureAccount(self.allocator, true);
    if (first_dirty) try self.dirty_accounts.ensureUnusedCapacity(self.allocator, 1);
    if (first_block_change)
        try self.block_changed_accounts.ensureUnusedCapacity(self.allocator, 1);
    if (first_transaction_dirty) try self.changed_accounts.ensureUnusedCapacity(self.allocator, 1);
    if (needs_undo) self.appendAccountUndo(id, row);
    if (first_dirty) {
        row.flags.block_dirty = true;
        self.dirty_accounts.appendAssumeCapacity(id);
    }
    if (first_block_change) {
        row.flags.block_changed = true;
        self.block_changed_accounts.appendAssumeCapacity(id);
    }
    if (first_transaction_dirty) {
        row.transaction_dirty_generation = self.transaction_generation;
        self.changed_accounts.appendAssumeCapacity(id);
    }
    return row;
}

fn prepareLifecycleMutation(
    self: *StatelessBlockState,
    id: AccountId,
) Allocator.Error!*AccountRow {
    const row = &self.accounts[@intFromEnum(id)];
    const first_lifecycle = !row.lifecycle_tracked;
    if (first_lifecycle)
        try self.lifecycle_accounts.ensureUnusedCapacity(self.allocator, 1);
    const mutable = try self.prepareAccountMutation(id);
    if (first_lifecycle) {
        mutable.lifecycle_tracked = true;
        self.lifecycle_accounts.appendAssumeCapacity(id);
    }
    return mutable;
}

fn appendAccountUndo(self: *StatelessBlockState, id: AccountId, row: *AccountRow) void {
    const observation = &self.observed_accounts.items[row.observation_index];
    self.journal.appendAccountAssumeCapacity(.{
        .account = id,
        .current = row.current,
        .code_ref = row.code_ref,
        .flags = row.flags,
        .journal_scope_generation = row.journal_scope_generation,
        .storage_generation = row.storage_generation,
        .storage_wipe_transaction_generation = row.storage_wipe_transaction_generation,
        .transaction_dirty_generation = row.transaction_dirty_generation,
    }, .{
        .observation = row.observation_index,
        .effect_current = observation.effect_current,
        .effect = observation.effect,
    });
    row.journal_scope_generation = self.active_scope_generation;
}

fn appendStorageUndo(self: *StatelessBlockState, id: StorageId, row: *StorageRow) void {
    const observation = &self.observed_storage.items[row.observation_index];
    const undo_index = index32(self.journal.storage.items.len);
    self.journal.appendStorageAssumeCapacity(.{
        .storage = id,
        .current = row.current,
        .flags = row.flags,
        .journal_scope_generation = row.journal_scope_generation,
        .storage_generation = row.storage_generation,
        .transaction_dirty_generation = row.transaction_dirty_generation,
        .transaction_undo_index = row.transaction_undo_index,
    }, .{
        .observation = row.observation_index,
        .effect_current = observation.effect_current,
        .effect = observation.effect,
    });
    if (row.transaction_undo_index == std.math.maxInt(u32))
        row.transaction_undo_index = undo_index;
    row.journal_scope_generation = self.active_scope_generation;
}

fn revertJournalTo(self: *StatelessBlockState, target_len: u32) void {
    while (self.journal.entries.items.len > target_len) {
        const entry = self.journal.entries.pop().?;
        switch (entry) {
            .account, .observed_account => |undo_id| {
                const index = @intFromEnum(undo_id);
                std.debug.assert(index + 1 == self.journal.accounts.items.len);
                const undo = self.journal.accounts.pop().?;
                const row = &self.accounts[@intFromEnum(undo.account)];
                row.current = undo.current;
                row.code_ref = undo.code_ref;
                row.flags = undo.flags;
                row.journal_scope_generation = undo.journal_scope_generation;
                row.storage_generation = undo.storage_generation;
                row.storage_wipe_transaction_generation = undo.storage_wipe_transaction_generation;
                row.transaction_dirty_generation = undo.transaction_dirty_generation;
                if (entry == .observed_account) {
                    const observation_undo = self.journal.account_observations.pop().?;
                    const observation = &self.observed_accounts.items[observation_undo.observation];
                    observation.effect_current = observation_undo.effect_current;
                    observation.effect = observation_undo.effect;
                }
            },
            .storage, .observed_storage => |undo_id| {
                const index = @intFromEnum(undo_id);
                std.debug.assert(index + 1 == self.journal.storage.items.len);
                const undo = self.journal.storage.pop().?;
                const row = &self.storage[@intFromEnum(undo.storage)];
                row.current = undo.current;
                row.flags = undo.flags;
                row.journal_scope_generation = undo.journal_scope_generation;
                row.storage_generation = undo.storage_generation;
                row.transaction_dirty_generation = undo.transaction_dirty_generation;
                row.transaction_undo_index = undo.transaction_undo_index;
                if (entry == .observed_storage) {
                    const observation_undo = self.journal.storage_observations.pop().?;
                    const observation = &self.observed_storage.items[observation_undo.observation];
                    observation.effect_current = observation_undo.effect_current;
                    observation.effect = observation_undo.effect;
                }
            },
            .warm_account => |id| self.accounts[@intFromEnum(id)].warm_generation = 0,
            .warm_storage => |id| self.storage[@intFromEnum(id)].warm_generation = 0,
            .introduced_code => {
                const block_id = self.block_introduced_codes.pop().?;
                const transaction_id = self.transaction_introduced_codes.pop().?;
                std.debug.assert(block_id == transaction_id);
                std.debug.assert(@intFromEnum(block_id) + 1 == self.code.introducedLen());
                self.code.truncateIntroduced(self.allocator, @intFromEnum(block_id));
            },
            .transient_storage => |undo_id| {
                const index = @intFromEnum(undo_id);
                std.debug.assert(index + 1 == self.journal.transient.items.len);
                const undo = self.journal.transient.pop().?;
                if (undo.previous) |previous| {
                    self.transient_storage.putAssumeCapacity(undo.key, previous);
                } else {
                    _ = self.transient_storage.remove(undo.key);
                }
            },
        }
    }
}

fn validateCheckpoint(self: *const StatelessBlockState, value: Checkpoint) void {
    self.assertTransaction();
    std.debug.assert(self.scope_depth >= 1);
    std.debug.assert(value.attempt_id == self.active_attempt_id.?);
    std.debug.assert(value.scope_generation == self.active_scope_generation);
    std.debug.assert(value.journal_len <= self.journal.entries.items.len);
    std.debug.assert(value.changed_accounts_len <= self.changed_accounts.items.len);
    std.debug.assert(value.changed_storage_len <= self.changed_storage.items.len);
    std.debug.assert(value.logs.rows_len <= self.logs.rows.items.len);
    std.debug.assert(value.logs.topics_len <= self.logs.topics.items.len);
    std.debug.assert(value.logs.data_len <= self.logs.data.items.len);
}

fn allocateScopeGeneration(self: *StatelessBlockState) u32 {
    self.next_scope_generation = nextGeneration(self.next_scope_generation);
    return self.next_scope_generation;
}

fn finishTransaction(self: *StatelessBlockState) void {
    self.transaction_scope_reverted = false;
    self.transient_storage.clearRetainingCapacity();
    self.changed_accounts.clearRetainingCapacity();
    self.changed_storage.clearRetainingCapacity();
    self.transaction_storage_wipes.clearRetainingCapacity();
    for (self.lifecycle_accounts.items) |id|
        self.accounts[@intFromEnum(id)].lifecycle_tracked = false;
    self.lifecycle_accounts.clearRetainingCapacity();
    self.transaction_introduced_codes.clearRetainingCapacity();
    self.observed_accounts.clearRetainingCapacity();
    self.observed_storage.clearRetainingCapacity();
    self.logs.clearRetainingCapacity();
    self.journal.clearRetainingCapacity();
    self.transaction_active = false;
    self.active_attempt_id = null;
    self.observed_attempt = false;
    self.sealed = false;
    self.active_scope_generation = 0;
    self.execution_scope_generation = 0;
    self.scope_depth = 0;
}

fn assertTransaction(self: *const StatelessBlockState) void {
    self.assertAttempt();
    std.debug.assert(self.scope_depth != 0);
}

fn assertAttempt(self: *const StatelessBlockState) void {
    std.debug.assert(self.transaction_active);
    std.debug.assert(self.active_attempt_id != null);
}

fn assertRootScope(self: *const StatelessBlockState) void {
    self.assertTransaction();
    std.debug.assert(self.scope_depth == 1);
}

fn assertCurrent(self: *const StatelessBlockState, id: AttemptId) void {
    self.assertAttempt();
    std.debug.assert(self.active_attempt_id.? == id);
}

fn nextGeneration(current: u32) u32 {
    std.debug.assert(current != std.math.maxInt(u32));
    return current + 1;
}

fn accountExecutionValue(fact: records.AccountFact) AccountValue {
    return switch (fact.parent) {
        .absent => .absent,
        .present => |parent| if (parent.nonce == 0 and
            parent.balance == 0 and
            std.mem.eql(u8, &parent.code_hash, &crypto.keccak256_empty))
            .absent
        else
            .{ .present = .{
                .nonce = parent.nonce,
                .balance = parent.balance,
                .code_hash = parent.code_hash,
            } },
    };
}

fn accountCodeHash(value: AccountValue) [32]u8 {
    return switch (value) {
        .absent => crypto.keccak256_empty,
        .present => |account| account.code_hash,
    };
}

fn accountValue(value: AccountValue) ?Account {
    return switch (value) {
        .absent => null,
        .present => |account_value| account_value,
    };
}

fn recordAccountEffect(
    observation: *AccountObservationRow,
    previous: AccountValue,
    current: AccountValue,
) void {
    observation.effect_current = current;
    switch (current) {
        .absent => observation.effect.account_deleted = previous == .present,
        .present => |value| switch (previous) {
            .absent => {
                observation.effect.balance_written = value.balance != 0;
                observation.effect.nonce_written = value.nonce != 0;
                observation.effect.code_written = !std.mem.eql(
                    u8,
                    &value.code_hash,
                    &crypto.keccak256_empty,
                );
            },
            .present => |old| {
                observation.effect.balance_written = observation.effect.balance_written or
                    old.balance != value.balance;
                observation.effect.nonce_written = observation.effect.nonce_written or
                    old.nonce != value.nonce;
                observation.effect.code_written = observation.effect.code_written or
                    !std.mem.eql(u8, &old.code_hash, &value.code_hash);
            },
        },
    }
}

fn index32(value: usize) u32 {
    std.debug.assert(value <= std.math.maxInt(u32));
    return @intCast(value);
}

fn beginTestTransaction(state: *StatelessBlockState) AttemptId {
    const attempt = state.beginObservedTransaction();
    state.beginScope();
    return attempt;
}

fn retainTestTransaction(state: *StatelessBlockState, attempt: AttemptId) void {
    state.closeScope();
    state.seal(attempt);
    state.retain(attempt);
}

fn discardTestTransaction(state: *StatelessBlockState, attempt: AttemptId) void {
    state.closeScope();
    state.discard(attempt);
}

fn initTestState(
    allocator: Allocator,
    plan: claim_plan.ClaimPlan,
    account_facts: []const records.AccountFact,
    storage_facts: []const records.StorageFact,
) !StatelessBlockState {
    var owned_plan = plan;
    var owns_plan = true;
    errdefer if (owns_plan) owned_plan.deinit(allocator);
    const facts = try records.initCopy(allocator, account_facts, storage_facts);
    owns_plan = false;
    return init(allocator, owned_plan, facts);
}

test "dense state resolves required accesses and skips optional warm-only misses" {
    const bal = @import("../eth/bal/model.zig");
    const claims = [_]bal.AccountChanges{
        .{ .address = address.addr(1), .storage_reads = &.{7} },
        .{ .address = address.addr(2) },
    };
    try bal.validate(&claims, .{ .transaction_count = 0 });
    const plan = try claim_plan.ClaimPlan.initAssumeValidated(std.testing.allocator, &claims);
    const account_facts = [_]records.AccountFact{
        .{ .parent = .{ .present = .{ .nonce = 1 } } },
        .{ .parent = .{ .absent = .empty_trie } },
    };
    const storage_facts = [_]records.StorageFact{
        .{ .value = 0 },
    };
    var state = try initTestState(std.testing.allocator, plan, &account_facts, &storage_facts);
    defer state.deinit();

    try std.testing.expect((try state.resolveAccount(address.addr(1), .required_observed)) != null);
    try std.testing.expectError(
        error.UndeclaredAccount,
        state.resolveAccount(address.addr(3), .required_observed),
    );
    try std.testing.expectEqual(
        @as(?AccountId, null),
        try state.resolveAccount(address.addr(3), .optional_warm_only),
    );
    const first: AccountId = @enumFromInt(0);
    try std.testing.expectError(
        error.UndeclaredStorage,
        state.resolveStorage(first, 8, .required_observed),
    );
    try std.testing.expectEqual(
        @as(?StorageId, null),
        try state.resolveStorage(first, 8, .optional_warm_only),
    );
    try std.testing.expect(state.accounts[0].current == .present);
    try std.testing.expect(state.accounts[1].current == .absent);
    try std.testing.expectEqual(@as(u256, 0), state.facts.storage[0].value);

    const attempt = beginTestTransaction(&state);
    try std.testing.expectEqual(
        @as(?bool, null),
        try state.warmAccountAddress(address.addr(3), .optional_warm_only),
    );
    try std.testing.expectError(
        error.UndeclaredAccount,
        state.warmAccountAddress(address.addr(3), .required_observed),
    );

    discardTestTransaction(&state, attempt);
}

test "storage-only parent residue remains authenticated while execution is absent" {
    const bal = @import("../eth/bal/model.zig");
    const claims = [_]bal.AccountChanges{.{ .address = address.addr(1) }};
    const plan = try claim_plan.ClaimPlan.initAssumeValidated(std.testing.allocator, &claims);
    const storage_root = [_]u8{0x77} ** 32;
    const account_facts = [_]records.AccountFact{
        .{ .parent = .{ .present = .{ .storage_root = storage_root } } },
    };
    var state = try initTestState(std.testing.allocator, plan, &account_facts, &.{});
    defer state.deinit();

    try std.testing.expect(state.accounts[0].current == .absent);
    try std.testing.expect(state.facts.accounts[0].parent == .present);
    try std.testing.expectEqualSlices(
        u8,
        &storage_root,
        &state.facts.accounts[0].parent.present.storage_root,
    );
}

test "observations survive nested revert while values warmth and dirty IDs revert" {
    const bal = @import("../eth/bal/model.zig");
    const target = address.addr(1);
    const claims = [_]bal.AccountChanges{.{ .address = target, .storage_reads = &.{7} }};
    const plan = try claim_plan.ClaimPlan.initAssumeValidated(std.testing.allocator, &claims);
    const account_facts = [_]records.AccountFact{
        .{ .parent = .{ .present = .{ .nonce = 1 } } },
    };
    const storage_facts = [_]records.StorageFact{
        .{ .value = 3 },
    };
    var state = try initTestState(std.testing.allocator, plan, &account_facts, &storage_facts);
    defer state.deinit();
    const attempt = beginTestTransaction(&state);

    const checkpoint_value = state.checkpoint();
    try std.testing.expectEqual(@as(u256, 3), try state.getStorage(target, 7));
    const account_id: AccountId = @enumFromInt(0);
    const storage_id: StorageId = @enumFromInt(0);
    try std.testing.expect(try state.warmAccountId(account_id));
    try std.testing.expect(try state.warmStorageId(storage_id));
    try state.writeStorage(storage_id, 9);
    try std.testing.expectEqual(@as(usize, 1), state.observed_accounts.items.len);
    try std.testing.expectEqual(@as(usize, 1), state.observed_storage.items.len);
    try std.testing.expect(state.observed_storage.items[0].effect.written);
    try std.testing.expectEqual(@as(u256, 9), state.observed_storage.items[0].effect_current);
    state.revertToCheckpoint(checkpoint_value);

    try std.testing.expectEqual(@as(u256, 3), state.storage[0].current);
    try std.testing.expectEqual(@as(u256, 3), state.storage[0].transaction_original);
    try std.testing.expect(!state.accountWarm(account_id));
    try std.testing.expect(!state.storageWarm(storage_id));
    // Scope revert restores the row flags through the journal and leaves
    // stale list entries behind; retain compacts them away.
    try std.testing.expectEqual(@as(usize, 1), state.dirty_accounts.items.len);
    try std.testing.expectEqual(@as(usize, 1), state.dirty_storage.items.len);
    try std.testing.expect(!state.accounts[0].flags.block_dirty);
    try std.testing.expect(!state.storage[0].flags.block_dirty);
    try std.testing.expectEqual(@as(usize, 1), state.observed_accounts.items.len);
    try std.testing.expectEqual(@as(usize, 1), state.observed_storage.items.len);
    try std.testing.expect(!state.observed_storage.items[0].effect.written);
    try std.testing.expectEqual(@as(u256, 3), state.observed_storage.items[0].effect_current);
    retainTestTransaction(&state, attempt);
    try std.testing.expectEqual(@as(usize, 0), state.dirty_accounts.items.len);
    try std.testing.expectEqual(@as(usize, 0), state.dirty_storage.items.len);
}

test "dense lifecycle candidates are compact and survive marker rollback" {
    const bal = @import("../eth/bal/model.zig");
    const claims = [_]bal.AccountChanges{
        .{ .address = address.addr(1) },
        .{ .address = address.addr(2) },
    };
    const plan = try claim_plan.ClaimPlan.initAssumeValidated(std.testing.allocator, &claims);
    const account_facts = [_]records.AccountFact{
        .{ .parent = .{ .present = .{ .balance = 10 } } },
        .{ .parent = .{ .present = .{ .balance = 20 } } },
    };
    var state = try initTestState(std.testing.allocator, plan, &account_facts, &.{});
    defer state.deinit();
    const attempt = beginTestTransaction(&state);
    const first: AccountId = @enumFromInt(0);
    const second: AccountId = @enumFromInt(1);

    const first_marker = state.checkpoint();
    try state.markCreatedId(first);
    try state.markSelfdestructedId(first);
    try std.testing.expectEqual(@as(usize, 1), state.lifecycle_accounts.items.len);
    state.revertToCheckpoint(first_marker);
    try std.testing.expect(!state.accounts[0].flags.created);
    try std.testing.expect(!state.accounts[0].flags.selfdestructed);

    try state.markSelfdestructedId(first);
    try std.testing.expectEqual(@as(usize, 1), state.lifecycle_accounts.items.len);

    const second_marker = state.checkpoint();
    try state.markSelfdestructedId(second);
    try std.testing.expectEqual(@as(usize, 2), state.lifecycle_accounts.items.len);
    state.revertToCheckpoint(second_marker);
    try std.testing.expect(!state.accounts[1].flags.selfdestructed);

    const policy = @import("../execution.zig").SelfDestructFinalization{
        .delete_account = true,
    };
    try state.finalize(.{ .existing_account = policy, .created_account = policy });
    try std.testing.expect(state.accounts[0].current == .absent);
    try std.testing.expectEqual(@as(u256, 20), state.accounts[1].current.present.balance);

    retainTestTransaction(&state, attempt);
    try std.testing.expectEqual(@as(usize, 0), state.lifecycle_accounts.items.len);
    try std.testing.expect(!state.accounts[0].lifecycle_tracked);
    try std.testing.expect(!state.accounts[1].lifecycle_tracked);
}

test "execution original survives checkpoints and refreshes across execution scopes" {
    const bal = @import("../eth/bal/model.zig");
    const target = address.addr(1);
    const claims = [_]bal.AccountChanges{.{ .address = target, .storage_reads = &.{7} }};
    const plan = try claim_plan.ClaimPlan.initAssumeValidated(std.testing.allocator, &claims);
    const account_facts = [_]records.AccountFact{
        .{ .parent = .{ .present = .{ .nonce = 1 } } },
    };
    const storage_facts = [_]records.StorageFact{
        .{ .value = 3 },
    };
    var state = try initTestState(std.testing.allocator, plan, &account_facts, &storage_facts);
    defer state.deinit();

    const attempt = state.beginObservedTransaction();
    state.beginScope();
    try std.testing.expectEqual(.modified, try state.setStorage(target, 7, 9));
    const nested = state.checkpoint();
    try std.testing.expectEqual(@as(u256, 3), try state.originalStorage(target, 7));
    try std.testing.expectEqual(.assigned, try state.setStorage(target, 7, 11));
    state.commitCheckpoint(nested);
    state.closeScope();

    state.beginScope();
    try std.testing.expectEqual(@as(u256, 11), try state.originalStorage(target, 7));
    try std.testing.expectEqual(@as(u256, 3), state.storage[0].transaction_original);
    state.closeScope();
    state.seal(attempt);
    state.retain(attempt);
}

test "scope stamps journal one row once and restore the parent stamp" {
    const bal = @import("../eth/bal/model.zig");
    const claims = [_]bal.AccountChanges{.{ .address = address.addr(1) }};
    const plan = try claim_plan.ClaimPlan.initAssumeValidated(std.testing.allocator, &claims);
    const account_facts = [_]records.AccountFact{
        .{ .parent = .{ .present = .{ .nonce = 1 } } },
    };
    var state = try initTestState(std.testing.allocator, plan, &account_facts, &.{});
    defer state.deinit();
    const attempt = beginTestTransaction(&state);
    const id: AccountId = @enumFromInt(0);

    try state.writeAccount(id, .{ .present = .{ .nonce = 2 } });
    try state.writeAccount(id, .{ .present = .{ .nonce = 3 } });
    try std.testing.expectEqual(@as(usize, 1), state.journalLen());
    const nested = state.checkpoint();
    try state.writeAccount(id, .{ .present = .{ .nonce = 4 } });
    try std.testing.expectEqual(@as(usize, 2), state.journalLen());
    state.revertToCheckpoint(nested);
    try std.testing.expectEqual(@as(u64, 3), state.accounts[0].current.present.nonce);
    try state.writeAccount(id, .{ .present = .{ .nonce = 5 } });
    try std.testing.expectEqual(@as(usize, 1), state.journalLen());
    discardTestTransaction(&state, attempt);
    try std.testing.expectEqual(@as(u64, 1), state.accounts[0].current.present.nonce);
}

test "storage wipe uses account generation without inventing slot observations" {
    const bal = @import("../eth/bal/model.zig");
    const target = address.addr(1);
    const claims = [_]bal.AccountChanges{.{ .address = target, .storage_reads = &.{7} }};
    const plan = try claim_plan.ClaimPlan.initAssumeValidated(std.testing.allocator, &claims);
    const account_facts = [_]records.AccountFact{
        .{ .parent = .{ .present = .{ .nonce = 1 } } },
    };
    const storage_facts = [_]records.StorageFact{
        .{ .value = 3 },
    };
    var state = try initTestState(std.testing.allocator, plan, &account_facts, &storage_facts);
    defer state.deinit();
    const attempt = beginTestTransaction(&state);
    const account_id: AccountId = @enumFromInt(0);
    const storage_id: StorageId = @enumFromInt(0);

    try std.testing.expectEqual(@as(u256, 3), try state.getStorage(target, 7));
    const nested = state.checkpoint();
    try state.wipeStorage(account_id);
    try std.testing.expectEqual(@as(usize, 1), state.observed_storage.items.len);
    try std.testing.expectEqual(@as(u256, 0), try state.getStorage(target, 7));
    try state.writeStorage(storage_id, 9);
    try std.testing.expectEqual(@as(u256, 9), try state.getStorage(target, 7));
    try std.testing.expect(state.accounts[0].flags.storage_wiped);
    try std.testing.expect(state.observed_accounts.items[0].effect.storage_wiped);
    state.revertToCheckpoint(nested);

    try std.testing.expectEqual(@as(u256, 3), try state.getStorage(target, 7));
    try std.testing.expect(!state.accounts[0].flags.storage_wiped);
    try std.testing.expect(!state.observed_accounts.items[0].effect.storage_wiped);
    try std.testing.expect(!state.observed_storage.items[0].effect.written);
    // Stale entries from the reverted scope persist until retain compacts.
    try std.testing.expect(!state.accounts[0].flags.block_dirty);
    try std.testing.expect(!state.storage[0].flags.block_dirty);
    retainTestTransaction(&state, attempt);
    try std.testing.expectEqual(@as(usize, 0), state.dirty_accounts.items.len);
    try std.testing.expectEqual(@as(usize, 0), state.dirty_storage.items.len);
}

test "warm undo exists only for the cold to warm transition" {
    const bal = @import("../eth/bal/model.zig");
    const claims = [_]bal.AccountChanges{.{ .address = address.addr(1) }};
    const plan = try claim_plan.ClaimPlan.initAssumeValidated(std.testing.allocator, &claims);
    const account_facts = [_]records.AccountFact{
        .{ .parent = .{ .present = .{ .nonce = 1 } } },
    };
    var state = try initTestState(std.testing.allocator, plan, &account_facts, &.{});
    defer state.deinit();
    const attempt = beginTestTransaction(&state);
    const id: AccountId = @enumFromInt(0);

    try std.testing.expect(try state.warmAccountId(id));
    try std.testing.expectEqual(@as(usize, 1), state.journalLen());
    const nested = state.checkpoint();
    try std.testing.expect(!try state.warmAccountId(id));
    try std.testing.expectEqual(@as(usize, 1), state.journalLen());
    state.revertToCheckpoint(nested);
    try std.testing.expect(state.accountWarm(id));
    discardTestTransaction(&state, attempt);
    try std.testing.expect(!state.accountWarm(id));
}

test "dense state initialization cleans every allocation failure" {
    const Harness = struct {
        fn run(allocator: Allocator) !void {
            const bal = @import("../eth/bal/model.zig");
            const claims = [_]bal.AccountChanges{.{
                .address = address.addr(1),
                .storage_reads = &.{7},
            }};
            const plan = try claim_plan.ClaimPlan.initAssumeValidated(allocator, &claims);
            const account_facts = [_]records.AccountFact{
                .{ .parent = .{ .absent = .empty_trie } },
            };
            const storage_facts = [_]records.StorageFact{
                .{ .value = 0 },
            };
            var state = try initTestState(allocator, plan, &account_facts, &storage_facts);
            state.deinit();
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Harness.run, .{});
}

test "storage mutation reserves both journal entries atomically" {
    const bal = @import("../eth/bal/model.zig");
    const target = address.addr(1);
    const claims = [_]bal.AccountChanges{.{
        .address = target,
        .storage_reads = &.{7},
    }};
    const plan = try claim_plan.ClaimPlan.initAssumeValidated(std.testing.allocator, &claims);
    const account_facts = [_]records.AccountFact{.{
        .parent = .{ .present = .{ .nonce = 1 } },
    }};
    const storage_facts = [_]records.StorageFact{.{ .value = 3 }};
    var state = try initTestState(
        std.testing.allocator,
        plan,
        &account_facts,
        &storage_facts,
    );
    defer state.deinit();

    try state.journal.entries.ensureTotalCapacityPrecise(std.testing.allocator, 1);
    const attempt = beginTestTransaction(&state);
    try state.writeStorage(@enumFromInt(0), 9);
    try std.testing.expectEqual(@as(usize, 2), state.journalLen());
    discardTestTransaction(&state, attempt);
}

test "dense transaction cleans every allocation failure" {
    const Harness = struct {
        fn run(allocator: Allocator) !void {
            const bal = @import("../eth/bal/model.zig");
            const target = address.addr(1);
            const claims = [_]bal.AccountChanges{.{
                .address = target,
                .storage_reads = &.{7},
            }};
            const plan = try claim_plan.ClaimPlan.initAssumeValidated(allocator, &claims);
            const account_facts = [_]records.AccountFact{
                .{ .parent = .{ .present = .{ .nonce = 1 } } },
            };
            const storage_facts = [_]records.StorageFact{
                .{ .value = 3 },
            };
            var state = try initTestState(allocator, plan, &account_facts, &storage_facts);
            defer state.deinit();
            const attempt = beginTestTransaction(&state);
            defer if (state.transaction_active) discardTestTransaction(&state, attempt);
            try state.setBalance(target, 4);
            try state.setCode(target, &.{0x5f});
            try state.setTransientStorage(target, 8, 12);
            try state.emitLog(.{
                .address = target,
                .topics = &.{1},
                .data = &.{2},
            });
            _ = try state.getStorage(target, 7);
            const nested = state.checkpoint();
            var nested_active = true;
            errdefer if (nested_active) state.revertToCheckpoint(nested);
            _ = try state.warmAccountId(@enumFromInt(0));
            _ = try state.warmStorageId(@enumFromInt(0));
            try state.writeStorage(@enumFromInt(0), 9);
            state.revertToCheckpoint(nested);
            nested_active = false;
            retainTestTransaction(&state, attempt);
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Harness.run, .{});
}
