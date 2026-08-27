const std = @import("std");
const ScopedArenaAllocator = @import("stdx").ScopedArenaAllocator;

pub const Slot = struct {
    arena: ScopedArenaAllocator,

    pub fn init(parent_allocator: std.mem.Allocator) Slot {
        return .{ .arena = ScopedArenaAllocator.init(parent_allocator) };
    }

    pub fn deinit(self: *Slot) void {
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn reset(self: *Slot) void {
        self.arena.resetRetainingCapacity();
    }

    pub fn allocator(self: *Slot) std.mem.Allocator {
        return self.arena.allocator();
    }

    pub fn capacity(self: *const Slot) usize {
        return self.arena.capacity();
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
