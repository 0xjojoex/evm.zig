//! Executor state I/O aliases.
//!
//! `StateReader` is the canonical-state read boundary. `Committer` is the
//! optional persistence boundary for consuming a borrowed `ChangesView`.

const state = @import("../state.zig");

pub const StateReader = state.Reader;
pub const Committer = state.Committer;
