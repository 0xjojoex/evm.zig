const std = @import("std");
const guest_options = @import("guest_options");

extern var _heap_start: u8;
extern var _heap_end: u8;
extern fn sys_alloc_aligned(bytes: usize, alignment: usize) callconv(.c) ?[*]u8;

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

fn fixedBuffer() []u8 {
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

const PlatformAllocator = struct {
    pub fn allocator(self: *PlatformAllocator) std.mem.Allocator {
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

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
        _ = ctx;
        _ = ra;
        return sys_alloc_aligned(len, alignment.toByteUnits());
    }

    fn resize(
        ctx: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        ra: usize,
    ) bool {
        _ = ctx;
        _ = alignment;
        _ = ra;
        return new_len <= memory.len;
    }

    fn remap(
        ctx: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        ra: usize,
    ) ?[*]u8 {
        return if (resize(ctx, memory, alignment, new_len, ra)) memory.ptr else null;
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ra: usize) void {
        _ = ctx;
        _ = memory;
        _ = alignment;
        _ = ra;
    }
};

pub const State = if (guest_options.backend == .sp1 or guest_options.backend == .openvm)
    PlatformAllocator
else
    std.heap.FixedBufferAllocator;

pub fn init() State {
    if (comptime guest_options.backend == .sp1 or guest_options.backend == .openvm) return .{};
    return std.heap.FixedBufferAllocator.init(fixedBuffer());
}
