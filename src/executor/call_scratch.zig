const std = @import("std");
const RewindableRegion = @import("rewindable_region");

pub const Slot = struct {
    region: RewindableRegion,

    pub fn init(parent_allocator: std.mem.Allocator) Slot {
        return .{ .region = RewindableRegion.init(parent_allocator) };
    }

    pub fn deinit(self: *Slot) void {
        self.region.deinit();
        self.* = undefined;
    }

    pub fn reset(self: *Slot) void {
        self.region.resetRetainingCapacity();
    }

    pub fn allocator(self: *Slot) std.mem.Allocator {
        return self.region.allocator();
    }

    pub fn capacity(self: *const Slot) usize {
        return self.region.capacity();
    }
};

test "call scratch slot resets and retains storage" {
    var slot = Slot.init(std.testing.allocator);
    defer slot.deinit();
    const allocator = slot.allocator();
    _ = try allocator.alloc(u8, 16);
    const capacity = slot.capacity();
    slot.reset();
    _ = try slot.allocator().alloc(u8, 16);
    try std.testing.expectEqual(capacity, slot.capacity());
}
