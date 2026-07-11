const std = @import("std");
const evmz = @import("evmz");
const guest_options = @import("guest_options");

const native_heap_size = 16 * 1024 * 1024;

pub const MeteredFixedBufferAllocator = evmz.fixed_buffer_meter.MeteredFixedBufferAllocator;

extern var _evmz_heap_bottom: u8;
extern var _evmz_heap_top: u8;

const NativeHeap = if (guest_options.use_ziskos_staticlib) struct {
    fn buffer() []u8 {
        unreachable;
    }
} else struct {
    var backing: ?[]align(16) u8 = null;

    fn buffer() []u8 {
        if (backing) |existing| return existing;
        const allocated = std.heap.page_allocator.alignedAlloc(u8, .@"16", native_heap_size) catch {
            @panic("failed to allocate native guest heap");
        };
        backing = allocated;
        return allocated;
    }
};

pub fn fixedBuffer() []u8 {
    if (comptime guest_options.use_ziskos_staticlib) {
        const bottom = @intFromPtr(&_evmz_heap_bottom);
        const top = @intFromPtr(&_evmz_heap_top);
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
