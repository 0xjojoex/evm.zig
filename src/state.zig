//! State module.
//!
//! - `Reader`: client/database read interface (root alias `evmz.StateReader`).
//! - `Backend`: block-lifetime reader, root derivation, and optional commit.
//! - `Overlay`: executor-owned execution cache and journal owner.
//! - `Changeset`: final state delta to commit into an upstream store.
//! - `Committer`: integration-owned sink for final changesets.
//! - `MemoryStore`: in-memory store for seeded pre-state and test/demo commits.

const std = @import("std");

pub const Account = @import("./state/Account.zig");
pub const Backend = @import("./state/Backend.zig").Backend;
pub const RootProvider = @import("./state/Backend.zig").RootProvider;
pub const MemoryAccount = @import("./state/MemoryAccount.zig");
pub const storage = @import("./state/storage.zig");
pub const Reader = @import("./state/Reader.zig");
pub const ConcurrentReader = @import("./state/ConcurrentReader.zig");
// Internal until the BAL differential path locks positioned fallback policy.
const BalClaimReader = @import("./state/BalClaimReader.zig");
pub const WitnessStateReader = @import("./state/WitnessStateReader.zig");
pub const Changeset = @import("./state/Changeset.zig");
pub const Committer = @import("./state/Committer.zig");
pub const Journal = @import("./state/Journal.zig");
pub const Overlay = @import("./state/Overlay.zig");
pub const MemoryStore = @import("./state/MemoryStore.zig");

pub const StorageKey = storage.Key;
pub const storageStatus = storage.status;

test {
    std.testing.refAllDecls(BalClaimReader);
    std.testing.refAllDecls(@This());
}
