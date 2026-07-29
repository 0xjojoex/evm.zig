//! Owned, transaction-local semantic state observations used to rebuild BAL.
//!
//! This is deliberately separate from state changes: observations retain read
//! and original/current information that committers do not need.

const std = @import("std");
const bal = @import("model.zig");

const Allocator = std.mem.Allocator;

pub const ValueObservation = struct {
    original: u256,
    current: u256,
};

pub const NonceObservation = struct {
    original: u64,
    current: u64,
};

pub const StorageObservation = struct {
    slot: u256,
    original: u256,
    current: u256,
    written: bool = false,
};

pub const CodeObservation = struct {
    original_hash: [32]u8,
    current_hash: [32]u8,
    current_code: []const u8,
};

pub const LifecycleKind = enum {
    created_contract,
    selfdestruct,
    account_deleted,
};

pub const AccountObservation = struct {
    address: bal.Address,
    storage: []const StorageObservation = &.{},
    balance: ?ValueObservation = null,
    nonce: ?NonceObservation = null,
    code: ?CodeObservation = null,
    lifecycle: []const LifecycleKind = &.{},
    account_reset: bool = false,
    account_deleted: bool = false,
    storage_wiped: bool = false,
};

/// One owned, index-free transition detached from a sealed tracked transaction.
///
/// BAL consumes observations and original/current pairs. Candidate-state folds
/// consume written fields and final lifecycle flags. This is the only detached
/// state artifact produced by an isolated execution lane.
/// Account and storage entries are sorted and unique. Reverted writes and
/// lifecycle events are absent; original-equal-current entries retain the
/// access needed to classify a BAL read.
pub const LaneTransition = struct {
    accounts: []AccountObservation = &.{},

    pub fn deinit(self: *LaneTransition, allocator: Allocator) void {
        for (self.accounts) |account| {
            allocator.free(@constCast(account.storage));
            if (account.code) |code| allocator.free(@constCast(code.current_code));
            allocator.free(@constCast(account.lifecycle));
        }
        allocator.free(self.accounts);
        self.* = .{};
    }
};
