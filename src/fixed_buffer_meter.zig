const std = @import("std");

pub const Metrics = struct {
    capacity_bytes: usize,
    peak_used_bytes: usize,
};

pub const MeteredFixedBufferAllocator = struct {
    fixed: std.heap.FixedBufferAllocator,
    peak_end_index: usize = 0,

    pub fn init(buffer: []u8) MeteredFixedBufferAllocator {
        return .{ .fixed = std.heap.FixedBufferAllocator.init(buffer) };
    }

    pub fn allocator(self: *MeteredFixedBufferAllocator) std.mem.Allocator {
        return .{
            .ptr = self,
            .vtable = &.{
                .alloc = alloc,
                .resize = resize,
                .remap = remap,
                .free = free,
            },
        };
    }

    pub fn metrics(self: *const MeteredFixedBufferAllocator) Metrics {
        return .{
            .capacity_bytes = self.fixed.buffer.len,
            .peak_used_bytes = self.peak_end_index,
        };
    }

    fn updatePeak(self: *MeteredFixedBufferAllocator) void {
        self.peak_end_index = @max(self.peak_end_index, self.fixed.end_index);
    }

    fn alloc(ctx: *anyopaque, n: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *MeteredFixedBufferAllocator = @ptrCast(@alignCast(ctx));
        const ptr = std.heap.FixedBufferAllocator.alloc(&self.fixed, n, alignment, ra) orelse return null;
        self.updatePeak();
        return ptr;
    }

    fn resize(
        ctx: *anyopaque,
        buf: []u8,
        alignment: std.mem.Alignment,
        new_size: usize,
        ra: usize,
    ) bool {
        const self: *MeteredFixedBufferAllocator = @ptrCast(@alignCast(ctx));
        const ok = std.heap.FixedBufferAllocator.resize(&self.fixed, buf, alignment, new_size, ra);
        if (ok) self.updatePeak();
        return ok;
    }

    fn remap(
        ctx: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        ra: usize,
    ) ?[*]u8 {
        const self: *MeteredFixedBufferAllocator = @ptrCast(@alignCast(ctx));
        const ptr = std.heap.FixedBufferAllocator.remap(&self.fixed, memory, alignment, new_len, ra) orelse return null;
        self.updatePeak();
        return ptr;
    }

    fn free(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, ra: usize) void {
        const self: *MeteredFixedBufferAllocator = @ptrCast(@alignCast(ctx));
        std.heap.FixedBufferAllocator.free(&self.fixed, buf, alignment, ra);
    }
};

test "metered fixed buffer tracks peak use" {
    var buffer: [64]u8 = undefined;
    var metered = MeteredFixedBufferAllocator.init(&buffer);
    const allocator = metered.allocator();

    const first = try allocator.alloc(u8, 10);
    try std.testing.expectEqual(@as(usize, 10), metered.metrics().peak_used_bytes);

    const second = try allocator.alloc(u8, 16);
    try std.testing.expect(metered.metrics().peak_used_bytes >= 26);

    allocator.free(second);
    allocator.free(first);
    try std.testing.expect(metered.fixed.end_index < metered.metrics().peak_used_bytes);
}
