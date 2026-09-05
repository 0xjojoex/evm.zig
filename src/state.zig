//! Generic state vocabulary and the open execution lane.
//!
//! - `AccessHint`, `FinalizationRules`, `CodeView`, the change records, and the
//!   observation/effect flags: vocabulary shared by both execution state lanes
//!   at the executor boundary.
//! - `Reader`: client/database read interface (root alias `evmz.StateReader`).
//! - `WorldState(World)`: the one execution-state machine; `OpenWorld` is the
//!   world for block building, discovery, and forks without a block access
//!   list, and `OpenState` its instantiation.
//! - `Checkpoint`: scope-rollback record shared with the claim-indexed lane.
//! - `LogBuffer`: packed emitted logs, also shared with the claim-indexed lane.
//! - `StateDelta`: owned block-final semantic changes, detached from execution.
//!   It is the only change shape that leaves evmz; `checkChangesView` pins the
//!   borrowed producers it is built from, `checkCommitView` the id-indexed
//!   projection the trie commits from.
//! - `Committer`: integration-owned sink for a detached delta.
//! - `RootProvider`: integration-owned post-state root over a detached delta.
//! - `MemoryStore`: in-memory store for seeded pre-state and test/demo commits.
//!
//! The claim-indexed lane, `evmz.eth.bal.ClosedState`, is `WorldState` over
//! `eth.bal.ClosedWorld`; `evmz.Backend` selects between the two lanes and is
//! therefore layered above both.

const std = @import("std");

const Address = @import("./address.zig").Address;
const execution = @import("./execution.zig");

pub const Account = @import("./state/Account.zig");
pub const MemoryAccount = @import("./state/MemoryAccount.zig");
pub const storage = @import("./state/storage.zig");
pub const LogBuffer = @import("./state/LogBuffer.zig");
pub const Reader = @import("./state/Reader.zig");
pub const ConcurrentReader = @import("./state/ConcurrentReader.zig");
pub const StateDelta = @import("./state/StateDelta.zig");
pub const Committer = @import("./state/Committer.zig");
pub const RootProvider = @import("./state/RootProvider.zig");
pub const sparse_hash_map = @import("./state/sparse_hash_map.zig");
pub const world_state = @import("./state/world_state.zig");
pub const WorldState = world_state.WorldState;
pub const OpenWorld = @import("./state/OpenWorld.zig");
pub const OpenState = WorldState(OpenWorld);
pub const MemoryStore = @import("./state/MemoryStore.zig");

pub const StorageKey = storage.Key;
pub const storageStatus = storage.status;

/// One call-scope rollback record, shared by every execution state model.
pub const Checkpoint = struct {
    /// Identifies one transaction attempt; scope checkpoints are only valid within
    /// the attempt that opened them.
    pub const AttemptId = enum(u64) { _ };

    /// Retained log-buffer lengths at scope open.
    pub const Log = struct {
        rows_len: u32,
        topics_len: u32,
        data_len: u32,
    };

    attempt_id: AttemptId,
    /// Generation that must be active when this checkpoint is closed.
    scope_generation: u64,
    /// Generation that becomes active after close. Lanes whose generation is
    /// per transaction rather than per scope restore the same value.
    parent_scope_generation: u64,
    journal_len: u32,
    changed_accounts_len: u32,
    changed_storage_len: u32,
    /// Transaction-scoped wipe list length; zero for lanes that keep wipes at
    /// block lifetime and unwind them through the journal.
    storage_wipes_len: u32,
    logs: Log,
};

/// Capacity advice for the containers a state lane keeps per transaction
/// attempt. Advisory: a lane may ignore it, and allocation failure must not
/// change execution results.
pub const AccessHint = struct {
    accounts: usize,
    storage_keys: usize,
};

/// Self-destruct settlement policy applied by `finalize` at the end of a
/// transaction attempt, split by whether the account was created in it.
pub const FinalizationRules = struct {
    existing_account: execution.SelfDestructFinalization = .{},
    created_account: execution.SelfDestructFinalization = .{},
};

/// Canonical code resolved for execution. The borrowed bytes stay valid for as
/// long as the lane that produced the view keeps its code storage alive.
pub const CodeView = struct {
    code_hash: [32]u8,
    bytes: []const u8,
};

/// One post-state account value, or `null` where the account is deleted.
pub const AccountChange = struct {
    address: Address,
    account: ?Account,
};

/// One post-state slot value, tagged by the account that owns it.
pub const StorageChange = struct {
    address: Address,
    key: u256,
    value: u256,
};

/// One sealed account observation: what a transaction read or wrote for one
/// address, with the value it started from and ended at. `null` is absent.
pub const AccountObservationFact = struct {
    address: Address,
    original: ?Account,
    current: ?Account,
    observation: AccountObservation,
    effect: AccountEffect,
};

/// One sealed storage observation with a complete value fact.
pub const StorageObservationFact = struct {
    address: Address,
    key: u256,
    original: u256,
    current: u256,
    observation: StorageObservation,
    effect: StorageEffect,
};

/// The identity and flags of a storage observation without its values; gas-only
/// access rows in the open lane have no value fact.
pub const StorageObservationMetadata = struct {
    address: Address,
    key: u256,
    observation: StorageObservation,
    effect: StorageEffect,
};

/// Which branch a changes view reads: the accepted branch accumulated across
/// committed transactions, or the open transaction attempt alone.
pub const ChangeLayer = enum {
    accepted,
    transaction,
};

/// Access flags for one account within a transaction attempt. Reads survive
/// inner rollback, so these are tracked separately from `AccountEffect`.
pub const AccountObservation = packed struct {
    accessed: bool = false,
    semantic_access: bool = false,
    existence_read: bool = false,
    value_read: bool = false,
    code_read: bool = false,
    _padding: u3 = 0,

    pub fn merge(self: *AccountObservation, other: AccountObservation) void {
        self.accessed = self.accessed or other.accessed;
        self.semantic_access = self.semantic_access or other.semantic_access;
        self.existence_read = self.existence_read or other.existence_read;
        self.value_read = self.value_read or other.value_read;
        self.code_read = self.code_read or other.code_read;
    }
};

/// Access flags for one storage slot within a transaction attempt.
pub const StorageObservation = packed struct {
    accessed: bool = false,
    value_read: bool = false,
    _padding: u6 = 0,

    pub fn merge(self: *StorageObservation, other: StorageObservation) void {
        self.accessed = self.accessed or other.accessed;
        self.value_read = self.value_read or other.value_read;
    }
};

/// Checkpoint-resolved account effects used by observation projectors.
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

/// Checkpoint-resolved storage effects used by observation projectors.
pub const StorageEffect = packed struct {
    written: bool = false,
    _padding: u7 = 0,
};

/// Assert `View` enumerates semantic changes: three indexed lists (`len() u32`
/// + `at(u32)`) of `AccountChange`, `StorageChange`, and wiped `Address`, plus
/// `introducedCode(hash)`. Ordering is unspecified. Both lanes' change views
/// and `StateDelta.View` qualify; `StateDelta.init` and
/// `eth.commit.SortedChanges` are the consumers.
pub fn checkChangesView(comptime View: type) void {
    comptime {
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
        if (!std.meta.hasMethod(View, "introducedCode")) @compileError(
            "changes view " ++ @typeName(View) ++ " is missing 'introducedCode'",
        );
    }
}

/// Assert `Commit` is a commit view: the accepted branch projected as dense
/// ids in trie order with pre-hashed keys, so the trie walks sorted fixed keys
/// and never reconstructs identity from address/slot records. The id types
/// are whatever `accountTrieOrder` and `storageTrieOrder` yield. Each lane
/// provides one; `eth.commit` is the consumer.
///
/// `authenticated_parents` says whether the view carries the parent trie
/// facts itself through `accountFact(id)` (a closed world authenticated at
/// admission) or the committer resolves parents from the witness by
/// `accountTrieKey(id)`.
pub fn checkCommitView(comptime Commit: type) void {
    comptime {
        if (!@hasDecl(Commit, "authenticated_parents")) @compileError(
            "commit view " ++ @typeName(Commit) ++ " is missing 'authenticated_parents'",
        );
        if (@TypeOf(Commit.authenticated_parents) != bool) @compileError(
            "commit view " ++ @typeName(Commit) ++ ".authenticated_parents must be a bool",
        );
        const methods = [_][]const u8{
            "accountTrieOrder", "storageTrieOrder", "accountTrieKey", "storageTrieKey",
            "accountDirty",     "accountChanged",   "accountValue",   "accountStorageDirty",
            "storageDirty",     "storageWiped",     "storageValue",
        };
        for (methods) |method| {
            if (!std.meta.hasMethod(Commit, method)) @compileError(
                "commit view " ++ @typeName(Commit) ++ " is missing '" ++ method ++ "'",
            );
        }
        if (Commit.authenticated_parents and !std.meta.hasMethod(Commit, "accountFact")) @compileError(
            "commit view " ++ @typeName(Commit) ++ " authenticates parents but has no 'accountFact'",
        );
    }
}

test {
    std.testing.refAllDecls(@This());
}
