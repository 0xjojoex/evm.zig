//! One parent allocation carved into typed regions.

const std = @import("std");

const ExactSlab = @This();

backing: []u8,
fixed: std.heap.FixedBufferAllocator,

/// Bytes needed for `count` values of `T` placed after `offset`, including
/// worst-case alignment padding. `take` performs the real alignment.
pub fn reserve(comptime T: type, offset: usize, count: usize) !usize {
    if (count == 0) return offset;
    const padded = try std.math.add(usize, offset, @alignOf(T) - 1);
    const bytes = try std.math.mul(usize, @sizeOf(T), count);
    const result = try std.math.add(usize, padded, bytes);
    return result;
}

pub fn init(allocator: std.mem.Allocator, len: usize) std.mem.Allocator.Error!ExactSlab {
    const backing = try allocator.alloc(u8, len);
    return .{ .backing = backing, .fixed = .init(backing) };
}

/// Carve a region already accounted for by `reserve`, which is why the
/// backing buffer cannot run out.
pub fn take(self: *ExactSlab, comptime T: type, count: usize) []T {
    return self.fixed.allocator().alloc(T, count) catch unreachable;
}

pub fn deinit(self: *ExactSlab, allocator: std.mem.Allocator) void {
    allocator.free(self.backing);
    self.* = undefined;
}

test "exact slab carves aligned regions from an unaligned parent offset" {
    var buffer: [256]u8 = undefined;
    var parent = std.heap.FixedBufferAllocator.init(&buffer);
    const prefix = try parent.allocator().alloc(u8, 1);
    defer parent.allocator().free(prefix);

    var len: usize = 0;
    len = try reserve(u8, len, 3);
    len = try reserve(u256, len, 2);

    var slab = try init(parent.allocator(), len);
    defer slab.deinit(parent.allocator());
    const bytes = slab.take(u8, 3);
    const words = slab.take(u256, 2);
    const empty = slab.take(u64, 0);

    try std.testing.expectEqual(@as(usize, 3), bytes.len);
    try std.testing.expectEqual(@as(usize, 0), @intFromPtr(words.ptr) % @alignOf(u256));
    try std.testing.expectEqual(@as(usize, 0), empty.len);
}
