const std = @import("std");

pub const ByteSlot = struct {
    allocator: std.mem.Allocator = undefined,
    buf: []u8 = &.{},
    len: usize = 0,
    bounded: bool = false,
    initialized: bool = false,

    pub fn initGrowable(allocator: std.mem.Allocator) ByteSlot {
        return .{
            .allocator = allocator,
            .initialized = true,
        };
    }

    pub fn initBounded(allocator: std.mem.Allocator, slot_capacity: usize) !ByteSlot {
        return .{
            .allocator = allocator,
            .buf = try allocator.alloc(u8, slot_capacity),
            .bounded = true,
            .initialized = true,
        };
    }

    pub fn deinit(self: *ByteSlot) void {
        if (self.initialized and self.buf.len != 0) {
            self.allocator.free(self.buf);
        }
        self.* = .{};
    }

    pub fn setGrowable(self: *ByteSlot) void {
        self.bounded = false;
    }

    pub fn setBounded(self: *ByteSlot, slot_capacity: usize) !void {
        std.debug.assert(self.initialized);
        self.len = 0;
        if (self.buf.len != slot_capacity) {
            if (slot_capacity == 0) {
                if (self.buf.len != 0) self.allocator.free(self.buf);
                self.buf = &.{};
            } else if (self.buf.len == 0) {
                self.buf = try self.allocator.alloc(u8, slot_capacity);
            } else {
                self.buf = try self.allocator.realloc(self.buf, slot_capacity);
            }
        }
        self.bounded = true;
    }

    pub fn clear(self: *ByteSlot) []u8 {
        self.len = 0;
        return self.buf[0..0];
    }

    pub fn assumeWritten(self: *ByteSlot, len: usize) ![]u8 {
        if (len > self.buf.len) {
            if (self.bounded) return error.FrameIoCapacityExceeded;
            self.buf = if (self.buf.len == 0)
                try self.allocator.alloc(u8, len)
            else
                try self.allocator.realloc(self.buf, len);
        }
        self.len = len;
        return self.slice();
    }

    pub fn replace(self: *ByteSlot, bytes: []const u8) ![]u8 {
        if (bytes.len > self.buf.len) {
            if (self.bounded) return error.FrameIoCapacityExceeded;
            self.buf = if (self.buf.len == 0)
                try self.allocator.alloc(u8, bytes.len)
            else
                try self.allocator.realloc(self.buf, bytes.len);
        }
        @memcpy(self.buf[0..bytes.len], bytes);
        self.len = bytes.len;
        return self.slice();
    }

    pub fn slice(self: *const ByteSlot) []u8 {
        return self.buf[0..self.len];
    }

    pub fn capacity(self: *const ByteSlot) usize {
        return self.buf.len;
    }
};

pub const Slot = struct {
    return_data: ByteSlot,

    pub fn initGrowable(allocator: std.mem.Allocator) Slot {
        return .{
            .return_data = ByteSlot.initGrowable(allocator),
        };
    }

    pub fn initBounded(allocator: std.mem.Allocator, slot_capacity: usize) !Slot {
        return .{
            .return_data = try ByteSlot.initBounded(allocator, slot_capacity),
        };
    }

    pub fn deinit(self: *Slot) void {
        self.return_data.deinit();
        self.* = undefined;
    }

    pub fn setGrowable(self: *Slot) void {
        self.return_data.setGrowable();
    }

    pub fn setBounded(self: *Slot, slot_capacity: usize) !void {
        try self.return_data.setBounded(slot_capacity);
    }

    pub fn clearFrame(self: *Slot) void {
        _ = self.return_data.clear();
    }
};

test "frame return-data slot overwrites and retains capacity" {
    var slot = Slot.initGrowable(std.testing.allocator);
    defer slot.deinit();

    try std.testing.expectEqualSlices(u8, "abc", try slot.return_data.replace("abc"));
    try std.testing.expectEqual(@as(usize, 3), slot.return_data.capacity());

    try std.testing.expectEqualSlices(u8, "x", try slot.return_data.replace("x"));
    try std.testing.expectEqual(@as(usize, 3), slot.return_data.capacity());
    try std.testing.expectEqual(@as(usize, 1), slot.return_data.slice().len);

    slot.clearFrame();
    try std.testing.expectEqual(@as(usize, 0), slot.return_data.slice().len);
    try std.testing.expectEqual(@as(usize, 3), slot.return_data.capacity());
}

test "bounded frame return-data slot rejects growth without clobbering previous data" {
    var slot = try Slot.initBounded(std.testing.allocator, 3);
    defer slot.deinit();

    try std.testing.expectEqualSlices(u8, "abc", try slot.return_data.replace("abc"));
    try std.testing.expectError(error.FrameIoCapacityExceeded, slot.return_data.replace("abcd"));
    try std.testing.expectEqualSlices(u8, "abc", slot.return_data.slice());
}
