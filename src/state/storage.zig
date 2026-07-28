//! Storage keys and SSTORE status classification.

const std = @import("std");
const Host = @import("../Host.zig");
const Address = @import("../address.zig").Address;

pub const Key = struct {
    address: Address,
    key: u256,
};

/// Fast non-cryptographic hash for gas-bounded transaction-local maps.
/// Equality still compares the complete key; collisions only add probes.
pub const TransactionKeyContext = struct {
    pub fn hash(_: TransactionKeyContext, value: Key) u64 {
        const address_head = std.mem.readInt(u64, value.address[0..8], .little);
        const address_middle = std.mem.readInt(u64, value.address[8..16], .little);
        const address_tail = std.mem.readInt(u32, value.address[16..20], .little);
        const key = value.key;
        var folded = address_head ^
            std.math.rotl(u64, address_middle, 17) ^
            (@as(u64, address_tail) << 32) ^
            @as(u64, @truncate(key)) ^
            std.math.rotl(u64, @truncate(key >> 64), 13) ^
            std.math.rotl(u64, @truncate(key >> 128), 29) ^
            std.math.rotl(u64, @truncate(key >> 192), 47);
        folded *%= 0x9e3779b97f4a7c15;
        return folded ^ (folded >> 32);
    }

    pub fn eql(_: TransactionKeyContext, a: Key, b: Key) bool {
        return a.key == b.key and std.mem.eql(u8, &a.address, &b.address);
    }
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

test "storage key hash covers every address and key limb" {
    const context = TransactionKeyContext{};
    const base = Key{ .address = std.mem.zeroes(Address), .key = 0 };
    const base_hash = context.hash(base);
    const hashes = [_]u64{
        context.hash(.{ .address = [_]u8{1} ++ [_]u8{0} ** 19, .key = 0 }),
        context.hash(.{ .address = [_]u8{0} ** 8 ++ [_]u8{1} ++ [_]u8{0} ** 11, .key = 0 }),
        context.hash(.{ .address = [_]u8{0} ** 16 ++ [_]u8{1} ++ [_]u8{0} ** 3, .key = 0 }),
        context.hash(.{ .address = base.address, .key = 1 }),
        context.hash(.{ .address = base.address, .key = @as(u256, 1) << 64 }),
        context.hash(.{ .address = base.address, .key = @as(u256, 1) << 128 }),
        context.hash(.{ .address = base.address, .key = @as(u256, 1) << 192 }),
    };
    for (hashes) |hash| try std.testing.expect(hash != base_hash);
}
