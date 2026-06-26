//! State module.
//!
//! - `Backend`: client/database read interface.
//! - `Overlay`: executor-owned execution cache; future journal belongs here.
//! - `MemoryBackend`: in-memory `Backend` implementation for seeded pre-state.

const std = @import("std");

pub const Account = @import("./state/Account.zig");
pub const Storage = @import("./state/Storage.zig");
pub const Backend = @import("./state/Backend.zig");
pub const Overlay = @import("./state/Overlay.zig");
pub const MemoryBackend = @import("./state/MemoryBackend.zig");

pub const AccountState = Account;
pub const StorageKey = Storage.Key;
pub const storageStatus = Storage.status;

test {
    std.testing.refAllDecls(@This());
}
