//! Generic state vocabulary and the tracked execution lane.
//!
//! - `AccessHint`, `FinalizationRules`, `CodeView`, the change records, and the
//!   observation/effect flags: vocabulary shared by both execution state lanes
//!   at the executor boundary. `checkLane` pins the ones a lane must re-export
//!   rather than redefine.
//! - `Reader`: client/database read interface (root alias `evmz.StateReader`).
//! - `TrackedState`: accepted branch, transaction rows, and scope rollback.
//! - `Checkpoint`: scope-rollback record shared with the claim-indexed lane.
//! - `LogBuffer`: packed emitted logs, also shared with the claim-indexed lane.
//! - `StateDelta`: owned block-final semantic changes, detached from execution.
//! - `Committer`: integration-owned sink for borrowed tracked-state changes.
//! - `RootProvider`: integration-owned post-state root over borrowed changes.
//! - `MemoryStore`: in-memory store for seeded pre-state and test/demo commits.
//!
//! The claim-indexed lane, `evmz.eth.bal.ClaimState`, is the other implementation
//! of the executor's state-lane surface; `evmz.Backend` selects between the two
//! lanes and is therefore layered above both.

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
pub const TrackedState = @import("./state/TrackedState.zig");
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

/// Assert `State` shares the state boundary types and declares its capacity
/// policy. Runs once per compiled executor.
///
/// `grows_on_touch` says whether the lane allocates rows as execution touches
/// state. A lane that does accepts `reserveAccessHint`,
/// `reserveAcceptedAccessHint`, and the transaction capacity-reuse pair; a lane
/// whose universe is declared up front has nothing to reserve, and the executor
/// skips those calls at comptime.
pub fn checkLane(comptime State: type) void {
    comptime {
        if (@TypeOf(State.grows_on_touch) != bool) @compileError(
            @typeName(State) ++ ".grows_on_touch must be a bool capability",
        );
    }
}

test "tracked state satisfies the state lane surface" {
    checkLane(TrackedState);
}

test {
    std.testing.refAllDecls(@This());
}
