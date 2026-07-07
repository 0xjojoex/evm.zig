const std = @import("std");

pub const Slot = struct {
    kind: Kind,

    const Kind = union(enum) {
        growable: std.heap.ArenaAllocator,
        bounded: Bounded,
    };

    const Bounded = struct {
        buffer: []u8,
        fixed: std.heap.FixedBufferAllocator,
    };

    pub fn initGrowable(parent_allocator: std.mem.Allocator) Slot {
        return .{ .kind = .{ .growable = std.heap.ArenaAllocator.init(parent_allocator) } };
    }

    pub fn deinit(self: *Slot, parent_allocator: std.mem.Allocator) void {
        switch (self.kind) {
            .growable => |arena| arena.deinit(),
            .bounded => |bounded| parent_allocator.free(bounded.buffer),
        }
        self.* = undefined;
    }

    pub fn setGrowable(self: *Slot, parent_allocator: std.mem.Allocator) void {
        self.deinit(parent_allocator);
        self.* = initGrowable(parent_allocator);
    }

    pub fn setBounded(self: *Slot, parent_allocator: std.mem.Allocator, slot_capacity: usize) !void {
        const buffer = try parent_allocator.alloc(u8, slot_capacity);
        errdefer parent_allocator.free(buffer);
        self.deinit(parent_allocator);
        self.* = .{ .kind = .{ .bounded = .{
            .buffer = buffer,
            .fixed = std.heap.FixedBufferAllocator.init(buffer),
        } } };
    }

    pub fn reset(self: *Slot) void {
        switch (self.kind) {
            .growable => |*arena| _ = arena.reset(.retain_capacity),
            .bounded => |*bounded| bounded.fixed.reset(),
        }
    }

    pub fn allocator(self: *Slot) std.mem.Allocator {
        return switch (self.kind) {
            .growable => |*arena| arena.allocator(),
            .bounded => |*bounded| bounded.fixed.allocator(),
        };
    }

    pub fn capacity(self: *const Slot) usize {
        return switch (self.kind) {
            .growable => |arena| arena.queryCapacity(),
            .bounded => |bounded| bounded.buffer.len,
        };
    }

    pub fn isBounded(self: *const Slot) bool {
        return self.kind == .bounded;
    }
};

test "bounded call scratch slot reuses fixed buffer" {
    var slot = Slot.initGrowable(std.testing.allocator);
    defer slot.deinit(std.testing.allocator);

    try slot.setBounded(std.testing.allocator, 4);
    try std.testing.expect(slot.isBounded());
    try std.testing.expectEqual(@as(usize, 4), slot.capacity());

    const allocator = slot.allocator();
    _ = try allocator.alloc(u8, 4);
    try std.testing.expectError(error.OutOfMemory, allocator.alloc(u8, 1));

    slot.reset();
    _ = try allocator.alloc(u8, 4);
}

test "call scratch slot can switch back to growable" {
    var slot = Slot.initGrowable(std.testing.allocator);
    defer slot.deinit(std.testing.allocator);

    try slot.setBounded(std.testing.allocator, 0);
    try std.testing.expect(slot.isBounded());
    slot.setGrowable(std.testing.allocator);
    try std.testing.expect(!slot.isBounded());

    const allocator = slot.allocator();
    const bytes = try allocator.alloc(u8, 16);
    try std.testing.expectEqual(@as(usize, 16), bytes.len);
}
