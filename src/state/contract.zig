//! Vocabulary shared by the execution-state lanes.
//!
//! `TrackedState` and `eth.bal.ClaimState` both implement the surface the
//! executor drives through its `Execution.State` binding. That surface is not
//! enumerated here: the test binary compiles both lanes through one executor,
//! so a missing or mismatched method fails at its call site, where the error
//! reads best. What call sites cannot catch is two lanes defining the same
//! boundary struct separately — an anonymous literal coerces into either — so
//! those types live here and `check` asserts each lane re-exports them.

const execution = @import("../execution.zig");

/// Capacity advice for the containers a lane keeps per transaction attempt.
/// Advisory: a lane may ignore it, and allocation failure must not change
/// execution results.
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

/// Assert `State` shares this module's boundary types and declares its
/// capacity policy. Runs once per compiled executor.
///
/// `grows_on_touch` says whether the lane allocates rows as execution touches
/// state. A lane that does accepts `reserveAccessHint`,
/// `reserveAcceptedAccessHint`, and the transaction capacity-reuse pair; a
/// lane whose universe is declared up front has nothing to reserve, and the
/// executor skips those calls at comptime.
pub fn check(comptime State: type) void {
    comptime {
        if (State.AccessHint != AccessHint) @compileError(
            @typeName(State) ++ ".AccessHint must be state.contract.AccessHint",
        );
        if (State.FinalizationRules != FinalizationRules) @compileError(
            @typeName(State) ++ ".FinalizationRules must be state.contract.FinalizationRules",
        );
        if (@TypeOf(State.grows_on_touch) != bool) @compileError(
            @typeName(State) ++ ".grows_on_touch must be a bool capability",
        );
    }
}

test "tracked lane satisfies the contract" {
    check(@import("./TrackedState.zig"));
}
