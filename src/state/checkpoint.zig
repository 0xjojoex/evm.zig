//! Scope-rollback vocabulary shared by every execution state model.
//!
//! The executor's frame store retains one checkpoint per call scope regardless
//! of which state model is compiled in, so these shapes belong to neither the
//! tracked nor the claim-indexed lane.

/// Identifies one transaction attempt; scope checkpoints are only valid within
/// the attempt that opened them.
pub const AttemptId = enum(u64) { _ };

/// Retained log-buffer lengths at scope open.
pub const LogCheckpoint = struct {
    rows_len: u32,
    topics_len: u32,
    data_len: u32,
};

/// One call-scope record. Every lane fills every field; a lane that has no
/// counterpart for a field fills the value that makes its close a no-op.
pub const Checkpoint = struct {
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
    logs: LogCheckpoint,
};
