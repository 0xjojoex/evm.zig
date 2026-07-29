//! Candidate-lane outcome vocabulary and caller-owned diagnostic output.
//!
//! Nothing here depends on the compiled engine, so the policy that maps an
//! execution failure to a lane status lives beside the statuses it produces.

const std = @import("std");

const BalClaimReader = @import("../../../state/BalClaimReader.zig");
const Reader = @import("../../../state/Reader.zig");
const batch_scheduler = @import("../../../io/batch_scheduler.zig");
const vm = @import("../../../vm.zig");

pub const Status = enum {
    not_run,
    outcomes_matched,
    candidate_matched,
    rejection_matched,
    matched,
    fallback_parallel_runtime,
    diagnostic_failure,
    claim_account_not_covered,
    claim_storage_not_covered,
    claim_import_failed,
    outcome_mismatch,
    transition_fold_mismatch,
    candidate_artifact_mismatch,
    candidate_rejection_mismatch,
    unsupported_before_transaction_hooks,
    unsupported_after_transaction_hooks,

    pub fn isFallback(self: Status) bool {
        return switch (self) {
            .fallback_parallel_runtime,
            .unsupported_before_transaction_hooks,
            .unsupported_after_transaction_hooks,
            => true,
            else => false,
        };
    }

    pub fn isMismatch(self: Status) bool {
        return switch (self) {
            .claim_account_not_covered,
            .claim_storage_not_covered,
            .claim_import_failed,
            .outcome_mismatch,
            .transition_fold_mismatch,
            .candidate_artifact_mismatch,
            .candidate_rejection_mismatch,
            .diagnostic_failure,
            => true,
            else => false,
        };
    }
};

pub const ParallelSubmission = batch_scheduler.Submission;

pub const ParallelFallback = enum {
    concurrent_state_reader_unavailable,
    concurrent_block_hash_source_unavailable,
    lane_storage_unavailable,
    concurrency_unavailable,
    lane_out_of_memory,
};

/// Internal capability bundle supplied by BlockSTF after it validates the
/// caller's public parallel resources.
pub const ParallelExecution = struct {
    io: std.Io,
    submission: ParallelSubmission,
    max_in_flight: usize,
    /// Must be safe for overlapping allocations from separate lane arenas.
    lane_allocator: std.mem.Allocator,
    state_reader: Reader,
    block_hash_source: ?vm.BlockHashSource,
};

/// Caller-owned diagnostic output. `mismatch_writer` is optional and receives
/// the final expected-vs-observed per-account BAL diff from `BlockSTF`.
pub const Report = struct {
    status: Status = .not_run,
    tx_index: ?usize = null,
    diagnostic_error: ?anyerror = null,
    mismatch_writer: ?*std.Io.Writer = null,
    mismatch_write_failed: bool = false,
    folded_transactions: usize = 0,
    parallel_fallback: ?ParallelFallback = null,
    parallel_batches: usize = 0,
    parallel_submitted_lanes: usize = 0,
    /// Largest number of lanes submitted as one batch. This does not claim
    /// that the selected `std.Io` runtime executed those lanes concurrently.
    parallel_max_batch_size: usize = 0,

    pub fn reset(self: *Report) void {
        const writer = self.mismatch_writer;
        self.* = .{ .mismatch_writer = writer };
    }
};

/// Classify a reader-side failure. Executor boundaries normalize type-erased
/// reader errors, so the claim reader's own detail is the only way to tell a
/// coverage gap from an infrastructure fault.
pub fn statusForError(err: anyerror, strategy_failure: ?BalClaimReader.StrategyFailure) Status {
    if (err == error.StateReaderStrategyFailure) {
        const failure = strategy_failure orelse return .diagnostic_failure;
        return switch (failure) {
            .account_not_covered => .claim_account_not_covered,
            .storage_not_covered => .claim_storage_not_covered,
        };
    }
    return .diagnostic_failure;
}

pub fn statusForCandidateError(err: anyerror) Status {
    return switch (err) {
        error.OutcomeMismatch => .outcome_mismatch,
        error.CandidateArtifactMismatch => .candidate_artifact_mismatch,
        error.CandidateRejectionMismatch => .candidate_rejection_mismatch,
        error.UnsupportedBeforeTransactionHooks => .unsupported_before_transaction_hooks,
        error.UnsupportedAfterTransactionHooks => .unsupported_after_transaction_hooks,
        else => .diagnostic_failure,
    };
}

/// A semantic disagreement is the candidate's own verdict, not a fault worth
/// reporting as a diagnostic error alongside the status.
pub fn candidateErrorIsSemantic(err: anyerror) bool {
    return switch (err) {
        error.OutcomeMismatch,
        error.CandidateArtifactMismatch,
        error.CandidateRejectionMismatch,
        error.UnsupportedBeforeTransactionHooks,
        error.UnsupportedAfterTransactionHooks,
        => true,
        else => false,
    };
}

test "BAL differential status classifies whole-lane fallback and mismatch" {
    try std.testing.expect(Status.fallback_parallel_runtime.isFallback());
    try std.testing.expect(Status.diagnostic_failure.isMismatch());
    try std.testing.expect(Status.claim_account_not_covered.isMismatch());
    try std.testing.expect(Status.claim_storage_not_covered.isMismatch());
    try std.testing.expect(Status.outcome_mismatch.isMismatch());
    try std.testing.expect(Status.transition_fold_mismatch.isMismatch());
    try std.testing.expect(Status.candidate_artifact_mismatch.isMismatch());
    try std.testing.expect(Status.candidate_rejection_mismatch.isMismatch());
    try std.testing.expect(!Status.matched.isFallback());
    try std.testing.expect(!Status.matched.isMismatch());
}

test "BAL strategy errors preserve differential policy" {
    try std.testing.expectEqual(Status.claim_account_not_covered, statusForError(error.StateReaderStrategyFailure, .account_not_covered));
    try std.testing.expectEqual(Status.claim_storage_not_covered, statusForError(error.StateReaderStrategyFailure, .storage_not_covered));
    try std.testing.expectEqual(Status.diagnostic_failure, statusForError(error.StateReaderStrategyFailure, null));
    try std.testing.expectEqual(Status.diagnostic_failure, statusForError(error.ProviderSpecificFailure, null));
}
