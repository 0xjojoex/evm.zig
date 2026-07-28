//! Storage keys and SSTORE status classification.

const std = @import("std");
const Host = @import("../Host.zig");
const Address = @import("../address.zig").Address;

pub const Key = struct {
    address: Address,
    key: u256,
};

pub fn status(original: u256, current: u256, next: u256) Host.StorageStatus {
    if (current == next) return .assigned;

    if (original == current) {
        if (original == 0) return .added;
        if (next == 0) return .deleted;
        return .modified;
    }

    if (original != 0) {
        if (current == 0) {
            if (next == original) return .deleted_restored;
            return .deleted_added;
        }
        if (next == 0) return .modified_deleted;
        if (next == original) return .modified_restored;
    } else if (next == 0) {
        return .added_deleted;
    }

    return .assigned;
}

test "storage status classifies basic transitions" {
    try std.testing.expectEqual(Host.StorageStatus.assigned, status(0, 0, 0));
    try std.testing.expectEqual(Host.StorageStatus.added, status(0, 0, 1));
    try std.testing.expectEqual(Host.StorageStatus.deleted, status(1, 1, 0));
    try std.testing.expectEqual(Host.StorageStatus.modified, status(1, 1, 2));
    try std.testing.expectEqual(Host.StorageStatus.deleted_restored, status(1, 0, 1));
    try std.testing.expectEqual(Host.StorageStatus.added_deleted, status(0, 1, 0));
}
