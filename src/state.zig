//! Generic state vocabulary and the tracked execution lane.
//!
//! - `Reader`: client/database read interface (root alias `evmz.StateReader`).
//! - `TrackedState`: accepted branch, transaction rows, and scope rollback.
//! - `checkpoint`: scope-rollback shapes shared with the stateless lane.
//! - `Committer`: integration-owned sink for borrowed tracked-state changes.
//! - `RootProvider`: integration-owned post-state root over borrowed changes.
//! - `MemoryStore`: in-memory store for seeded pre-state and test/demo commits.
//!
//! The dense stateless lane lives in `evmz.stateless`; `evmz.Backend` selects
//! between the two lanes and is therefore layered above both.

const std = @import("std");

pub const Account = @import("./state/Account.zig");
pub const MemoryAccount = @import("./state/MemoryAccount.zig");
pub const storage = @import("./state/storage.zig");
pub const checkpoint = @import("./state/checkpoint.zig");
pub const Reader = @import("./state/Reader.zig");
pub const ConcurrentReader = @import("./state/ConcurrentReader.zig");
pub const Committer = @import("./state/Committer.zig");
pub const RootProvider = @import("./state/RootProvider.zig");
pub const TrackedState = @import("./state/TrackedState.zig");
pub const MemoryStore = @import("./state/MemoryStore.zig");

pub const StorageKey = storage.Key;
pub const storageStatus = storage.status;

test {
    std.testing.refAllDecls(@This());
}
