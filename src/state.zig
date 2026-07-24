//! State module.
//!
//! - `Reader`: client/database read interface (root alias `evmz.StateReader`).
//! - `Backend`: block-lifetime reader, root derivation, and optional commit.
//! - `TrackedState`: accepted branch, transaction rows, and scope rollback.
//! - `Committer`: integration-owned sink for borrowed tracked-state changes.
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
pub const Committer = @import("./state/Committer.zig");
pub const TrackedState = @import("./state/TrackedState.zig");
pub const MemoryStore = @import("./state/MemoryStore.zig");

pub const StorageKey = storage.Key;
pub const storageStatus = storage.status;

test {
    std.testing.refAllDecls(BalClaimReader);
    std.testing.refAllDecls(@This());
}
