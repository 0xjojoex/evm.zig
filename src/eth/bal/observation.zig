//! Owned, transaction-local semantic state observations used to rebuild BAL.
//!
//! This is deliberately separate from `state.Changeset`: the latter remains
//! the compact authoritative commit boundary, while this artifact retains the
//! read and original/current information that committers do not need.

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
};

/// Canonical, index-free output from one completed semantic capture scope.
/// Account and storage entries are sorted and unique. Reverted writes and
/// lifecycle events are absent; original-equal-current entries retain the
/// access needed to classify a BAL read.
pub const StateObservationDelta = struct {
    accounts: []AccountObservation = &.{},

    pub fn deinit(self: *StateObservationDelta, allocator: Allocator) void {
        for (self.accounts) |account| {
            allocator.free(@constCast(account.storage));
            if (account.code) |code| allocator.free(@constCast(code.current_code));
            allocator.free(@constCast(account.lifecycle));
        }
        allocator.free(self.accounts);
        self.* = .{};
    }

    /// Build one BAL shard at the coordinator-owned block access index.
    /// Lifecycle is retained in this delta for policy/fallback decisions but
    /// remains intentionally uninterpreted until the EIP-8246 shape is pinned.
    pub fn toOwnedBlockAccessList(
        self: StateObservationDelta,
        allocator: Allocator,
        block_access_index: bal.BlockAccessIndex,
    ) !bal.Decoded {
        var accounts: std.ArrayList(bal.AccountChanges) = .empty;
        errdefer {
            for (accounts.items) |*account| deinitBalAccount(allocator, account);
            accounts.deinit(allocator);
        }
        try accounts.ensureTotalCapacity(allocator, self.accounts.len);

        for (self.accounts) |observed| {
            var account = bal.AccountChanges{ .address = observed.address };
            errdefer deinitBalAccount(allocator, &account);

            var storage_changes: std.ArrayList(bal.SlotChanges) = .empty;
            errdefer {
                for (storage_changes.items) |slot| allocator.free(@constCast(slot.changes));
                storage_changes.deinit(allocator);
            }
            var storage_reads: std.ArrayList(u256) = .empty;
            errdefer storage_reads.deinit(allocator);
            try storage_changes.ensureTotalCapacity(allocator, observed.storage.len);
            try storage_reads.ensureTotalCapacity(allocator, observed.storage.len);

            for (observed.storage) |slot| {
                if (slot.original == slot.current) {
                    storage_reads.appendAssumeCapacity(slot.slot);
                } else {
                    const changes = try allocator.alloc(bal.StorageChange, 1);
                    changes[0] = .{
                        .block_access_index = block_access_index,
                        .new_value = slot.current,
                    };
                    storage_changes.appendAssumeCapacity(.{
                        .slot = slot.slot,
                        .changes = changes,
                    });
                }
            }
            account.storage_changes = try storage_changes.toOwnedSlice(allocator);
            account.storage_reads = try storage_reads.toOwnedSlice(allocator);

            if (observed.balance) |balance| if (balance.original != balance.current) {
                const changes = try allocator.alloc(bal.BalanceChange, 1);
                changes[0] = .{
                    .block_access_index = block_access_index,
                    .post_balance = balance.current,
                };
                account.balance_changes = changes;
            };
            if (observed.nonce) |nonce| if (nonce.original != nonce.current) {
                const changes = try allocator.alloc(bal.NonceChange, 1);
                changes[0] = .{
                    .block_access_index = block_access_index,
                    .new_nonce = nonce.current,
                };
                account.nonce_changes = changes;
            };
            if (observed.code) |code| if (!std.mem.eql(u8, &code.original_hash, &code.current_hash)) {
                const current_code = try allocator.dupe(u8, code.current_code);
                errdefer allocator.free(current_code);
                const changes = try allocator.alloc(bal.CodeChange, 1);
                changes[0] = .{
                    .block_access_index = block_access_index,
                    .new_code = current_code,
                };
                account.code_changes = changes;
            };

            accounts.appendAssumeCapacity(account);
        }
        return .{ .accounts = try accounts.toOwnedSlice(allocator) };
    }
};

fn deinitBalAccount(allocator: Allocator, account: *const bal.AccountChanges) void {
    for (account.storage_changes) |slot| allocator.free(@constCast(slot.changes));
    allocator.free(@constCast(account.storage_changes));
    allocator.free(@constCast(account.storage_reads));
    allocator.free(@constCast(account.balance_changes));
    allocator.free(@constCast(account.nonce_changes));
    for (account.code_changes) |change| allocator.free(@constCast(change.new_code));
    allocator.free(@constCast(account.code_changes));
}
