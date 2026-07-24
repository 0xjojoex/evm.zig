const std = @import("std");

pub const ByteSlot = struct {
    allocator: std.mem.Allocator = undefined,
    buf: []u8 = &.{},
    len: usize = 0,
    initialized: bool = false,

    pub fn init(allocator: std.mem.Allocator) ByteSlot {
        return .{
            .allocator = allocator,
            .initialized = true,
        };
    }

    pub fn deinit(self: *ByteSlot) void {
        if (self.initialized and self.buf.len != 0) {
            self.allocator.free(self.buf);
        }
        self.* = .{};
    }

    pub fn clear(self: *ByteSlot) []u8 {
        self.len = 0;
        return self.buf[0..0];
    }

    pub fn replace(self: *ByteSlot, bytes: []const u8) ![]u8 {
        if (bytes.len > self.buf.len) {
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

    pub fn init(allocator: std.mem.Allocator) Slot {
        return .{
            .return_data = ByteSlot.init(allocator),
        };
    }

    pub fn deinit(self: *Slot) void {
        self.return_data.deinit();
        self.* = undefined;
    }

    pub fn clearFrame(self: *Slot) void {
        _ = self.return_data.clear();
    }
};

test "frame return-data slot overwrites and retains capacity" {
    var slot = Slot.init(std.testing.allocator);
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
