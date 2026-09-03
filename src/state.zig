//! Generic state vocabulary and the tracked execution lane.
//!
//! - `AccessHint` and `FinalizationRules`: vocabulary shared by both execution
//!   state lanes at the executor boundary.
//! - `Reader`: client/database read interface (root alias `evmz.StateReader`).
//! - `TrackedState`: accepted branch, transaction rows, and scope rollback.
//! - `checkpoint`: scope-rollback shapes shared with the claim-indexed lane.
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

const execution = @import("./execution.zig");

pub const Account = @import("./state/Account.zig");
pub const MemoryAccount = @import("./state/MemoryAccount.zig");
pub const storage = @import("./state/storage.zig");
pub const checkpoint = @import("./state/checkpoint.zig");
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
        if (State.AccessHint != AccessHint) @compileError(
            @typeName(State) ++ ".AccessHint must be state.AccessHint",
        );
        if (State.FinalizationRules != FinalizationRules) @compileError(
            @typeName(State) ++ ".FinalizationRules must be state.FinalizationRules",
        );
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
