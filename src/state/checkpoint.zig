//! Scope-rollback vocabulary shared by every execution state model.
//!
//! The executor's frame store retains one checkpoint per call scope regardless
//! of which state model is compiled in, so these shapes belong to neither the
//! tracked nor the dense lane.

/// Identifies one transaction attempt; scope checkpoints are only valid within
/// the attempt that opened them.
pub const AttemptId = enum(u64) { _ };

/// Retained log-buffer lengths at scope open.
pub const LogCheckpoint = struct {
    rows_len: u32,
    topics_len: u32,
    data_len: u32,
};

pub const Checkpoint = struct {
    attempt_id: AttemptId,
    scope_generation: u64,
    journal_len: u32,
    changed_accounts_len: u32,
    changed_storage_len: u32,
    storage_wipes_len: u32,
    logs: LogCheckpoint,
};
