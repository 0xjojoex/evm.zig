const std = @import("std");
const evmz = @import("evmz");
const guest_options = @import("guest_options");

pub const MeteredFixedBufferAllocator = evmz.fixed_buffer_meter.MeteredFixedBufferAllocator;

extern var _heap_start: u8;
extern var _heap_end: u8;

const NativeHeap = if (guest_options.backend != .native) struct {
    fn buffer() []u8 {
        unreachable;
    }
} else struct {
    var backing: ?[]align(16) u8 = null;

    /// Mapped rather than allocated. A safe-build `alignedAlloc` memsets the
    /// whole capacity to `undefined`, which materialises every page of a heap
    /// sized for a guest envelope; the payload only ever touches what it hands
    /// out. Subranges still get normal allocator initialisation.
    fn buffer() []u8 {
        if (backing) |existing| return existing;
        const mapped = std.heap.PageAllocator.map(guest_options.heap_bytes, .@"16") orelse
            @panic("failed to map native guest heap");
        const allocated: []align(16) u8 = @alignCast(mapped[0..guest_options.heap_bytes]);
        backing = allocated;
        return allocated;
    }
};

pub fn fixedBuffer() []u8 {
    if (comptime guest_options.backend != .native) {
        const bottom = @intFromPtr(&_heap_start);
        const top = @intFromPtr(&_heap_end);
        if (top <= bottom) unreachable;
        if (bottom % 16 != 0) unreachable;

        const ptr: [*]u8 = @ptrFromInt(bottom);
        return ptr[0 .. top - bottom];
    }

    return NativeHeap.buffer();
}

pub fn fixedBufferAllocator() std.heap.FixedBufferAllocator {
    return std.heap.FixedBufferAllocator.init(fixedBuffer());
}

pub fn meteredFixedBufferAllocator() MeteredFixedBufferAllocator {
    return MeteredFixedBufferAllocator.init(fixedBuffer());
}
