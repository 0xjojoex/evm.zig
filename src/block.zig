//! Small procedural kernel for chain-owned block folds.

const std = @import("std");

/// Copyable token proving that one concrete block fold owns an Executor's
/// accepted branch. The fold keeps the Executor pointer; the token keeps only
/// the generation needed to reject stale copies.
///
/// The token is deliberately concrete — chain folds embed it in fields whose
/// types tooling must resolve — so its methods take the executor as `anytype`.
/// Misuse checks are `assert`s per the repo invariant doctrine; in release
/// builds a stale-token call is unchecked here and surfaces later as
/// `error.UncommittedChanges` from the next `begin`.
pub const Claim = struct {
    generation: u64,

    /// Claim an Executor whose accepted branch is empty.
    pub fn begin(executor: anytype) error{UncommittedChanges}!Claim {
        std.debug.assert(executor.active_block_execution_generation == null);
        std.debug.assert(!executor.hasCurrentTransaction());
        if (executor.acceptedView().hasChanges()) return error.UncommittedChanges;

        executor.next_block_execution_generation +%= 1;
        executor.active_block_execution_generation = executor.next_block_execution_generation;
        return .{ .generation = executor.next_block_execution_generation };
    }

    /// Assert that this token still owns the Executor's accepted branch.
    pub fn requireActive(self: Claim, executor: anytype) void {
        std.debug.assert(executor.active_block_execution_generation == self.generation);
    }

    /// Release this claim without changing the accepted branch.
    pub fn release(self: Claim, executor: anytype) void {
        if (executor.active_block_execution_generation == self.generation)
            executor.active_block_execution_generation = null;
    }

    /// Roll back accepted block changes if this stale-copy-safe token still
    /// owns the Executor.
    pub fn discardIfUnfinished(self: Claim, executor: anytype) void {
        if (executor.active_block_execution_generation != self.generation) return;
        std.debug.assert(!executor.hasCurrentTransaction());
        executor.discardAccepted();
        self.release(executor);
    }
};
