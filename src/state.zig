//! State module.
//!
//! - `Reader`: client/database read interface (root alias `evmz.StateReader`).
//! - `Overlay`: executor-owned execution cache and journal owner.
//! - `Changeset`: final state delta to commit into an upstream store.
//! - `Committer`: integration-owned sink for final changesets.
//! - `MemoryStore`: in-memory store for seeded pre-state and test/demo commits.

const std = @import("std");

pub const Account = @import("./state/Account.zig");
pub const storage = @import("./state/storage.zig");
pub const Reader = @import("./state/Reader.zig");
pub const Changeset = @import("./state/Changeset.zig");
pub const Committer = @import("./state/Committer.zig");
pub const Journal = @import("./state/Journal.zig");
pub const Overlay = @import("./state/Overlay.zig");
pub const MemoryStore = @import("./state/MemoryStore.zig");

pub const StorageKey = storage.Key;
pub const storageStatus = storage.status;

test {
    std.testing.refAllDecls(@This());
}
