//! Single-threaded chunked region with bulk reset and retained capacity.
//!
//! This is a narrow fallback for callers whose transient topology cannot be
//! sized before traversal. It is not thread-safe and must have one active
//! owner. Individual frees reclaim only the most recent allocation.

const std = @import("std");

const Allocator = std.mem.Allocator;
const Alignment = std.mem.Alignment;
const ResettableRegion = @This();

parent: Allocator,
first: ?*Chunk = null,
last: ?*Chunk = null,
current: ?*Chunk = null,

const Chunk = struct {
    allocation_len: usize,
    base_offset: usize,
    end_index: usize = 0,
    previous: ?*Chunk,
    next: ?*Chunk = null,

    fn allocation(self: *Chunk) []u8 {
        const base: [*]u8 = @ptrFromInt(@intFromPtr(self) - self.base_offset);
        return base[0..self.allocation_len];
    }

    fn buffer(self: *Chunk) []u8 {
        const start = self.base_offset + @sizeOf(Chunk);
        return self.allocation()[start..];
    }
};

pub fn init(parent: Allocator) ResettableRegion {
    return .{ .parent = parent };
}

pub fn deinit(self: *ResettableRegion) void {
    var current = self.last;
    while (current) |chunk| {
        const previous = chunk.previous;
        self.parent.rawFree(chunk.allocation(), .@"1", @returnAddress());
        current = previous;
    }
    self.* = undefined;
}

/// Invalidate every outstanding allocation while keeping chunks for the next
/// exclusive borrower.
pub fn resetRetainingCapacity(self: *ResettableRegion) void {
    var current = self.first;
    while (current) |chunk| : (current = chunk.next) chunk.end_index = 0;
    self.current = self.first;
}

pub fn allocator(self: *ResettableRegion) Allocator {
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

pub fn capacity(self: *const ResettableRegion) usize {
    var total: usize = 0;
    var current = self.first;
    while (current) |chunk| : (current = chunk.next) total += chunk.buffer().len;
    return total;
}

fn alloc(context: *anyopaque, len: usize, alignment: Alignment, return_address: usize) ?[*]u8 {
    const self: *ResettableRegion = @ptrCast(@alignCast(context));
    std.debug.assert(len > 0);

    var current = self.current orelse self.first;
    while (current) |chunk| : (current = chunk.next) {
        if (allocateFrom(chunk, len, alignment)) |pointer| {
            self.current = chunk;
            return pointer;
        }
    }

    const chunk = self.appendChunk(len, alignment, return_address) orelse return null;
    self.current = chunk;
    return allocateFrom(chunk, len, alignment).?;
}

fn resize(
    context: *anyopaque,
    memory: []u8,
    alignment: Alignment,
    new_len: usize,
    return_address: usize,
) bool {
    const self: *ResettableRegion = @ptrCast(@alignCast(context));
    _ = alignment;
    _ = return_address;
    std.debug.assert(memory.len > 0);
    std.debug.assert(new_len > 0);

    const chunk = self.current orelse return new_len <= memory.len;
    const buffer = chunk.buffer();
    if (@intFromPtr(memory.ptr) + memory.len != @intFromPtr(buffer.ptr) + chunk.end_index) {
        return new_len <= memory.len;
    }
    if (new_len <= memory.len) {
        chunk.end_index -= memory.len - new_len;
        return true;
    }
    const growth = new_len - memory.len;
    if (growth > buffer.len - chunk.end_index) return false;
    chunk.end_index += growth;
    return true;
}

fn remap(
    context: *anyopaque,
    memory: []u8,
    alignment: Alignment,
    new_len: usize,
    return_address: usize,
) ?[*]u8 {
    return if (resize(context, memory, alignment, new_len, return_address))
        memory.ptr
    else
        null;
}

fn free(
    context: *anyopaque,
    memory: []u8,
    alignment: Alignment,
    return_address: usize,
) void {
    const self: *ResettableRegion = @ptrCast(@alignCast(context));
    _ = alignment;
    _ = return_address;
    std.debug.assert(memory.len > 0);

    const chunk = self.current orelse return;
    const buffer = chunk.buffer();
    if (@intFromPtr(memory.ptr) + memory.len != @intFromPtr(buffer.ptr) + chunk.end_index) return;
    chunk.end_index -= memory.len;
}

fn allocateFrom(chunk: *Chunk, len: usize, alignment: Alignment) ?[*]u8 {
    const buffer = chunk.buffer();
    const start = alignedIndex(buffer.ptr, chunk.end_index, alignment);
    const end = std.math.add(usize, start, len) catch return null;
    if (end > buffer.len) return null;
    chunk.end_index = end;
    return buffer[start..end].ptr;
}

fn appendChunk(
    self: *ResettableRegion,
    len: usize,
    alignment: Alignment,
    return_address: usize,
) ?*Chunk {
    const minimum = std.math.add(usize, len, alignment.toByteUnits() - 1) catch return null;
    const previous_capacity = if (self.last) |last| last.buffer().len else 0;
    const grown = std.math.add(
        usize,
        previous_capacity,
        previous_capacity / 2 + 16,
    ) catch minimum;
    const requested_capacity = @max(minimum, grown);
    const header_slack = @alignOf(Chunk) - 1;
    const with_header = std.math.add(usize, header_slack, @sizeOf(Chunk)) catch return null;
    const allocation_len = std.math.add(usize, with_header, requested_capacity) catch return null;
    const base = self.parent.rawAlloc(allocation_len, .@"1", return_address) orelse return null;
    const chunk_address = std.mem.alignForward(usize, @intFromPtr(base), @alignOf(Chunk));
    const chunk: *Chunk = @ptrFromInt(chunk_address);
    chunk.* = .{
        .allocation_len = allocation_len,
        .base_offset = chunk_address - @intFromPtr(base),
        .previous = self.last,
    };
    if (self.last) |last| last.next = chunk else self.first = chunk;
    self.last = chunk;
    return chunk;
}

fn alignedIndex(buffer: [*]u8, end_index: usize, alignment: Alignment) usize {
    return alignment.forward(@intFromPtr(buffer) +% end_index) -% @intFromPtr(buffer);
}

test "reset retains chunks and parent allocation is fully reclaimed" {
    var backing: [4096]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&backing);
    var region = ResettableRegion.init(fixed.allocator());
    const allocator_instance = region.allocator();
    _ = try allocator_instance.alloc(u8, 17);
    _ = try allocator_instance.alignedAlloc(u8, .@"64", 1000);
    const retained = region.capacity();
    region.resetRetainingCapacity();
    _ = try region.allocator().alignedAlloc(u8, .@"64", 1000);
    try std.testing.expectEqual(retained, region.capacity());
    region.deinit();
    try std.testing.expectEqual(@as(usize, 0), fixed.end_index);
}

test "top allocation resize and free reuse current chunk" {
    var region = ResettableRegion.init(std.testing.allocator);
    defer region.deinit();
    const allocator_instance = region.allocator();
    var bytes = try allocator_instance.alloc(u8, 16);
    bytes = try allocator_instance.realloc(bytes, 32);
    allocator_instance.free(bytes);
    const again = try allocator_instance.alloc(u8, 32);
    try std.testing.expectEqual(@intFromPtr(bytes.ptr), @intFromPtr(again.ptr));
}
