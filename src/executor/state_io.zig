//! Executor state I/O aliases.
//!
//! `StateReader` is the canonical-state read boundary. `Committer` is the
//! optional persistence boundary for committing a VM `Changeset`.

const state = @import("../state.zig");

pub const StateReader = state.Reader;
pub const Changeset = state.Changeset;
pub const Committer = state.Committer;
