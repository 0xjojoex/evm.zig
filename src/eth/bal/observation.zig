//! Owned, transaction-local semantic state observations used to rebuild BAL.
//!
//! This is deliberately separate from state changes: observations retain read
//! and original/current information that committers do not need.

const std = @import("std");
const bal = @import("model.zig");
const Account = @import("../../state/Account.zig");

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
};

pub const CodeObservation = struct {
    original_hash: [32]u8,
    current_hash: [32]u8,
    current_code: []const u8,
};

/// Allocation-free BAL projection of one sealed account fact. Identity stays
/// with the caller so address-keyed and dense-ID consumers share these rules.
pub const AccountFields = struct {
    balance: ?ValueObservation = null,
    nonce: ?NonceObservation = null,
    code: ?CodeObservation = null,
    storage_wiped: bool = false,
};

pub fn accountFields(view: anytype, fact: anytype) !?AccountFields {
    if (!fact.observation.semantic_access and !fact.effect.any()) return null;

    var fields = AccountFields{ .storage_wiped = fact.effect.storage_wiped };
    if (fact.effect.balance_written or
        (!fact.effect.storage_wiped and
            (fact.effect.nonce_written or fact.effect.code_written)))
    {
        const original = accountOrZero(fact.original);
        const current = accountOrZero(fact.current);
        if (fact.effect.balance_written) fields.balance = .{
            .original = original.balance,
            .current = current.balance,
        };
        if (fact.effect.nonce_written and !fact.effect.storage_wiped) fields.nonce = .{
            .original = original.nonce,
            .current = current.nonce,
        };
        if (fact.effect.code_written and !fact.effect.storage_wiped) {
            const code = view.code(current.code_hash) orelse
                return error.ObservationCodeUnavailable;
            fields.code = .{
                .original_hash = original.code_hash,
                .current_hash = current.code_hash,
                .current_code = code.bytes,
            };
        }
    }
    return fields;
}

pub inline fn storageIsRead(
    storage_wiped: bool,
    original: u256,
    current: u256,
) bool {
    return storage_wiped or original == current;
}

pub const AccountObservation = struct {
    address: bal.Address,
    storage: []const StorageObservation = &.{},
    balance: ?ValueObservation = null,
    nonce: ?NonceObservation = null,
    code: ?CodeObservation = null,
    /// A destroyed contract's touched slots are BAL reads rather than writes to
    /// zero, so the wipe has to survive as its own fact.
    storage_wiped: bool = false,
};

/// One owned, index-free transition detached from a sealed tracked transaction.
///
/// This is BAL evidence and nothing more. Whether a slot changed is read from
/// its original and current values, so no separate written flag is kept, and
/// lifecycle events are absent now that no fold interprets them.
/// Account and storage entries are sorted and unique. Reverted writes are
/// absent; original-equal-current entries retain the access needed to classify
/// a BAL read.
pub const LaneTransition = struct {
    accounts: []AccountObservation = &.{},

    pub fn deinit(self: *LaneTransition, allocator: Allocator) void {
        for (self.accounts) |account| {
            allocator.free(@constCast(account.storage));
            if (account.code) |code| allocator.free(@constCast(code.current_code));
        }
        allocator.free(self.accounts);
        self.* = .{};
    }
};

fn accountOrZero(value: anytype) Account {
    if (@TypeOf(value) == ?Account) return value orelse .{};
    return switch (value orelse .absent) {
        .loaded => |account| account,
        .absent => .{},
        .exists_only => unreachable,
    };
}
