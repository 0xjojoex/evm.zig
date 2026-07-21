//! Source-neutral resource-bound envelope for bounded execution.
//!
//! Producers can derive this from conservative gas formulas or from declared
//! block/witness/BAL inputs. Executor wiring should consume this envelope rather
//! than source-specific planner shapes.

const std = @import("std");

const address = @import("../address.zig");
const bal = @import("../eth/bal/model.zig");
const StateOverlay = @import("../state/Overlay.zig");

pub const Source = enum {
    gas_derived,
    declared,
};

pub const LogResources = StateOverlay.LogResources;
pub const AccessResources = StateOverlay.AccessResources;
pub const StateResources = StateOverlay.StateResources;

pub const empty_logs: LogResources = .{
    .entries = 0,
    .data_bytes = 0,
};

pub const empty_access: AccessResources = .{
    .accounts = 0,
    .storage_keys = 0,
};

pub const BlockResources = struct {
    state: StateResources = .{},
};

pub const TransactionResources = struct {
    max_live_frames: usize,
    logs: LogResources = empty_logs,
    journal_entries: usize = 0,
    access: AccessResources = empty_access,
    state: StateResources = .{},
    transient_storage_entries: usize = 0,
};

pub const Envelope = struct {
    source: Source,
    block: BlockResources = .{},
    transaction: TransactionResources,
};

/// Build block-lived executor capacities from a declared BAL.
///
/// Every BAL storage key can require a temporary block-lived overlay entry even
/// when its final per-index value is unchanged. Account-scoped maps likewise
/// need room for accessed accounts whose net change is empty.
pub fn blockResourcesFromBal(block_access_list: bal.BlockAccessList) BlockResources {
    const counts = bal.count(block_access_list);
    return .{
        .state = .{
            .accounts = counts.accounts,
            // BAL code changes do not bound pre-state code loaded by calls.
            // Callers with a witness/code manifest may add both code caps.
            .storage_overlay_entries = storageKeyCount(counts),
            .deleted_accounts = counts.accounts,
            .dirty_accounts = counts.accounts,
        },
    };
}

/// Build conservative block-lived capacities when only aggregate BAL counts are
/// available.
pub fn blockResourcesFromBalCounts(counts: bal.Counts) BlockResources {
    return .{
        .state = .{
            .accounts = counts.accounts,
            // Aggregate BAL counts still omit pre-state code byte lengths.
            .storage_overlay_entries = storageKeyCount(counts),
            .deleted_accounts = counts.accounts,
            .dirty_accounts = counts.accounts,
        },
    };
}

pub fn declaredEnvelopeFromBal(block_access_list: bal.BlockAccessList, transaction: TransactionResources) Envelope {
    return .{
        .source = .declared,
        .block = blockResourcesFromBal(block_access_list),
        .transaction = transaction,
    };
}

pub fn declaredEnvelopeFromBalCounts(counts: bal.Counts, transaction: TransactionResources) Envelope {
    return .{
        .source = .declared,
        .block = blockResourcesFromBalCounts(counts),
        .transaction = transaction,
    };
}

/// Raise transaction-lived original-storage capacity to a BAL-safe upper bound.
/// Storage reads are not indexed, so the safe source is every declared key.
pub fn transactionResourcesFromBal(
    block_access_list: bal.BlockAccessList,
    transaction: TransactionResources,
) TransactionResources {
    const counts = bal.count(block_access_list);

    var result = transaction;
    result.state.original_storage_entries = @max(
        result.state.original_storage_entries,
        storageKeyCount(counts),
    );
    return result;
}

pub fn declaredEnvelopeFromBalWithTransactionBounds(
    block_access_list: bal.BlockAccessList,
    transaction: TransactionResources,
) Envelope {
    return .{
        .source = .declared,
        .block = blockResourcesFromBal(block_access_list),
        .transaction = transactionResourcesFromBal(block_access_list, transaction),
    };
}

fn storageKeyCount(counts: bal.Counts) usize {
    return counts.storage_read_keys + counts.storage_write_keys;
}

test "BAL declaration maps to block-lived state resources" {
    const block_access_list = [_]bal.AccountChanges{
        .{
            .address = std.mem.zeroes(bal.Address),
            .storage_changes = &.{
                .{ .slot = 1, .changes = &.{
                    .{ .block_access_index = 1, .new_value = 2 },
                    .{ .block_access_index = 3, .new_value = 4 },
                } },
                .{ .slot = 5, .changes = &.{
                    .{ .block_access_index = 2, .new_value = 6 },
                } },
            },
            .storage_reads = &.{7},
            .balance_changes = &.{
                .{ .block_access_index = 1, .post_balance = 8 },
            },
        },
        .{
            .address = address.addr(1),
            .storage_reads = &.{9},
        },
    };

    const resources = blockResourcesFromBal(&block_access_list);
    try std.testing.expectEqual(@as(usize, 2), resources.state.accounts);
    try std.testing.expectEqual(@as(?usize, null), resources.state.code_entries);
    try std.testing.expectEqual(@as(?usize, null), resources.state.code_bytes);
    try std.testing.expectEqual(@as(usize, 4), resources.state.storage_overlay_entries);
    try std.testing.expectEqual(@as(usize, 2), resources.state.deleted_accounts);
    try std.testing.expectEqual(@as(usize, 2), resources.state.dirty_accounts);
    try std.testing.expectEqual(@as(usize, 0), resources.state.original_storage_entries);
}

test "BAL aggregate counts map conservatively without changed-account detail" {
    const resources = blockResourcesFromBalCounts(.{
        .accounts = 2,
        .storage_read_keys = 3,
        .storage_write_keys = 4,
        .storage_write_changes = 5,
    });

    try std.testing.expectEqual(@as(usize, 2), resources.state.accounts);
    try std.testing.expectEqual(@as(usize, 7), resources.state.storage_overlay_entries);
    try std.testing.expectEqual(@as(usize, 2), resources.state.deleted_accounts);
    try std.testing.expectEqual(@as(usize, 2), resources.state.dirty_accounts);
}

test "BAL declared envelope keeps transaction resources caller supplied" {
    const block_access_list = [_]bal.AccountChanges{.{
        .address = std.mem.zeroes(bal.Address),
        .storage_changes = &.{.{
            .slot = 1,
            .changes = &.{.{ .block_access_index = 1, .new_value = 2 }},
        }},
    }};
    const transaction = TransactionResources{
        .max_live_frames = 3,
        .journal_entries = 4,
        .access = .{ .accounts = 5, .storage_keys = 6 },
        .state = .{ .original_storage_entries = 7 },
    };

    const envelope = declaredEnvelopeFromBal(&block_access_list, transaction);
    try std.testing.expectEqual(Source.declared, envelope.source);
    try std.testing.expectEqual(@as(usize, 1), envelope.block.state.storage_overlay_entries);
    try std.testing.expectEqual(@as(usize, 3), envelope.transaction.max_live_frames);
    try std.testing.expectEqual(@as(usize, 7), envelope.transaction.state.original_storage_entries);
}

test "BAL declared envelope preserves a larger caller original-storage bound" {
    const block_access_list = [_]bal.AccountChanges{.{
        .address = std.mem.zeroes(bal.Address),
        .storage_changes = &.{
            .{ .slot = 1, .changes = &.{
                .{ .block_access_index = 1, .new_value = 2 },
            } },
            .{ .slot = 2, .changes = &.{
                .{ .block_access_index = 1, .new_value = 3 },
            } },
            .{ .slot = 3, .changes = &.{
                .{ .block_access_index = 2, .new_value = 4 },
            } },
        },
    }};

    const envelope = declaredEnvelopeFromBalWithTransactionBounds(&block_access_list, .{
        .max_live_frames = 3,
        .journal_entries = 99,
        .state = .{ .original_storage_entries = 99 },
    });

    try std.testing.expectEqual(Source.declared, envelope.source);
    try std.testing.expectEqual(@as(usize, 3), envelope.block.state.storage_overlay_entries);
    try std.testing.expectEqual(@as(usize, 99), envelope.transaction.state.original_storage_entries);
    try std.testing.expectEqual(@as(usize, 99), envelope.transaction.journal_entries);
}

test "BAL read-only slots reserve temporary storage maps" {
    const block_access_list = [_]bal.AccountChanges{.{
        .address = std.mem.zeroes(bal.Address),
        .storage_reads = &.{1},
    }};

    const envelope = declaredEnvelopeFromBalWithTransactionBounds(&block_access_list, .{
        .max_live_frames = 1,
    });

    try std.testing.expectEqual(@as(usize, 1), envelope.block.state.storage_overlay_entries);
    try std.testing.expectEqual(@as(usize, 1), envelope.transaction.state.original_storage_entries);
    try std.testing.expectEqual(@as(usize, 1), envelope.block.state.dirty_accounts);
    try std.testing.expectEqual(@as(usize, 1), envelope.block.state.deleted_accounts);
}
