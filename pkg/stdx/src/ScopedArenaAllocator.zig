//! Single-owner chunked arena with nested mark/rewind and retained capacity.
//!
//! Allocations made after a mark are invalidated together when that mark is
//! rewound. Marks are strictly LIFO. Individual frees reclaim only the most
//! recent allocation.
//!
//! Not `std.heap.ArenaAllocator`: the std arena is thread-safe, and its atomic
//! RMW allocation path is wasted codegen for a single-threaded owner. Single
//! ownership is also what makes nested marks expressible at all.

const std = @import("std");

const Allocator = std.mem.Allocator;
const Alignment = std.mem.Alignment;
const ScopedArenaAllocator = @This();

parent: Allocator,
first: ?*Chunk = null,
last: ?*Chunk = null,
current: ?*Chunk = null,
active: ScopeState = .{},
next_mark_id: u64 = 1,

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

/// The innermost active scope: the newest mark's identity and the arena
/// position it rewinds to. `id` 0 means no mark is active.
const ScopeState = struct {
    id: u64 = 0,
    chunk: ?*Chunk = null,
    end_index: usize = 0,
};

/// Handle for `rewind`. The mark's rewind position lives in `owner.active`
/// while the mark is innermost; LIFO discipline (asserted) guarantees it is
/// still there when rewound.
pub const Mark = struct {
    owner: *ScopedArenaAllocator,
    id: u64,
    previous: ScopeState,
};

pub fn init(parent: Allocator) ScopedArenaAllocator {
    return .{ .parent = parent };
}

pub fn deinit(self: *ScopedArenaAllocator) void {
    std.debug.assert(self.active.id == 0);
    // Free newest-first: with byte-exact packing (see `appendChunk`) a LIFO
    // parent unwinds every chunk, reclaiming its space completely.
    var current = self.last;
    while (current) |chunk| {
        const previous = chunk.previous;
        self.parent.rawFree(chunk.allocation(), .@"1", @returnAddress());
        current = previous;
    }
    self.* = undefined;
}

pub fn mark(self: *ScopedArenaAllocator) Mark {
    const id = self.next_mark_id;
    std.debug.assert(id != 0);
    self.next_mark_id +%= 1;
    const result: Mark = .{ .owner = self, .id = id, .previous = self.active };
    self.active = .{
        .id = id,
        .chunk = self.current,
        .end_index = if (self.current) |chunk| chunk.end_index else 0,
    };
    return result;
}

/// Invalidate every allocation made after `mark`, retaining chunks for reuse.
pub fn rewind(self: *ScopedArenaAllocator, target: Mark) void {
    std.debug.assert(target.owner == self);
    std.debug.assert(target.id == self.active.id);
    self.rewindTo(self.active.chunk, self.active.end_index);
    self.active = target.previous;
}

/// Invalidate every outstanding allocation while keeping all chunks.
pub fn resetRetainingCapacity(self: *ScopedArenaAllocator) void {
    std.debug.assert(self.active.id == 0);
    self.rewindTo(null, 0);
}

fn rewindTo(self: *ScopedArenaAllocator, target: ?*Chunk, end_index: usize) void {
    if (target) |chunk| {
        std.debug.assert(end_index <= chunk.buffer().len);
        chunk.end_index = end_index;
        var current = chunk.next;
        while (current) |later| : (current = later.next) later.end_index = 0;
        self.current = chunk;
    } else {
        var current = self.first;
        while (current) |chunk| : (current = chunk.next) chunk.end_index = 0;
        self.current = self.first;
    }
}

pub fn allocator(self: *ScopedArenaAllocator) Allocator {
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

pub fn capacity(self: *const ScopedArenaAllocator) usize {
    var total: usize = 0;
    var current = self.first;
    while (current) |chunk| : (current = chunk.next) total += chunk.buffer().len;
    return total;
}

fn alloc(context: *anyopaque, len: usize, alignment: Alignment, return_address: usize) ?[*]u8 {
    const self: *ScopedArenaAllocator = @ptrCast(@alignCast(context));
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
    const self: *ScopedArenaAllocator = @ptrCast(@alignCast(context));
    _ = alignment;
    _ = return_address;
    std.debug.assert(memory.len > 0);
    std.debug.assert(new_len > 0);

    if (!self.allocationInsideActiveMark(memory)) return new_len == memory.len;

    const chunk = self.current.?;
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
    const self: *ScopedArenaAllocator = @ptrCast(@alignCast(context));
    _ = alignment;
    _ = return_address;
    std.debug.assert(memory.len > 0);

    const chunk = self.current.?;
    const buffer = chunk.buffer();
    if (@intFromPtr(memory.ptr) + memory.len != @intFromPtr(buffer.ptr) + chunk.end_index) return;
    if (!self.allocationInsideActiveMark(memory)) return;
    chunk.end_index -= memory.len;
}

/// Whether an allocation belongs to the innermost active scope. Allocations
/// below its mark floor must retain both their address and extent until rewind.
fn allocationInsideActiveMark(self: *const ScopedArenaAllocator, memory: []u8) bool {
    if (self.active.id == 0) return true;
    const floor = self.active.chunk orelse return true;
    const address = @intFromPtr(memory.ptr);
    var chunk: ?*Chunk = floor;
    while (chunk) |candidate| : (chunk = candidate.next) {
        const buffer = candidate.buffer();
        const start = @intFromPtr(buffer.ptr);
        if (address < start or address >= start + buffer.len) continue;
        return candidate != floor or address >= start + self.active.end_index;
    }
    return false;
}

fn allocateFrom(chunk: *Chunk, len: usize, alignment: Alignment) ?[*]u8 {
    const buffer = chunk.buffer();
    const start = alignedIndex(buffer.ptr, chunk.end_index, alignment);
    const end = std.math.add(usize, start, len) catch return null;
    if (end > buffer.len) return null;
    chunk.end_index = end;
    return buffer[start..end].ptr;
}

/// Chunks are requested from the parent at alignment 1, with the header
/// aligned manually inside (`base_offset`): consecutive chunks pack
/// byte-exactly, so a LIFO parent (`FixedBufferAllocator`, another instance)
/// never strands padding between them and `deinit` unwinds it fully.
fn appendChunk(
    self: *ScopedArenaAllocator,
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

test "nested marks rewind to exact allocation positions" {
    var backing: [4096]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&backing);
    var arena = ScopedArenaAllocator.init(fixed.allocator());
    defer arena.deinit();
    const allocator_instance = arena.allocator();

    const persistent = try allocator_instance.alloc(u8, 17);
    @memset(persistent, 0xa5);
    const outer = arena.mark();
    const outer_scratch = try allocator_instance.alignedAlloc(u8, .@"64", 100);
    const inner = arena.mark();
    const inner_scratch = try allocator_instance.alloc(u8, 1000);
    const retained = arena.capacity();

    arena.rewind(inner);
    const inner_again = try allocator_instance.alloc(u8, 1000);
    try std.testing.expectEqual(@intFromPtr(inner_scratch.ptr), @intFromPtr(inner_again.ptr));
    arena.rewind(outer);
    const outer_again = try allocator_instance.alignedAlloc(u8, .@"64", 100);
    try std.testing.expectEqual(@intFromPtr(outer_scratch.ptr), @intFromPtr(outer_again.ptr));
    try std.testing.expectEqual(retained, arena.capacity());
    try std.testing.expect(std.mem.allEqual(u8, persistent, 0xa5));
}

test "reset retains chunks and parent allocation is fully reclaimed" {
    var backing: [4096]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&backing);
    var arena = ScopedArenaAllocator.init(fixed.allocator());
    const allocator_instance = arena.allocator();
    _ = try allocator_instance.alloc(u8, 17);
    _ = try allocator_instance.alignedAlloc(u8, .@"64", 1000);
    const retained = arena.capacity();
    arena.resetRetainingCapacity();
    _ = try arena.allocator().alignedAlloc(u8, .@"64", 1000);
    try std.testing.expectEqual(retained, arena.capacity());
    arena.deinit();
    try std.testing.expectEqual(@as(usize, 0), fixed.end_index);
}

test "top allocation resize and free reuse current chunk" {
    var arena = ScopedArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator_instance = arena.allocator();
    var bytes = try allocator_instance.alloc(u8, 16);
    bytes = try allocator_instance.realloc(bytes, 32);
    allocator_instance.free(bytes);
    const again = try allocator_instance.alloc(u8, 32);
    try std.testing.expectEqual(@intFromPtr(bytes.ptr), @intFromPtr(again.ptr));
}

test "active mark protects earlier top allocation from free and resize" {
    var backing: [4096]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&backing);
    var arena = ScopedArenaAllocator.init(fixed.allocator());
    defer arena.deinit();
    const allocator_instance = arena.allocator();

    var persistent = try allocator_instance.alloc(u8, 32);
    const persistent_address = @intFromPtr(persistent.ptr);
    const scope = arena.mark();
    allocator_instance.free(persistent);
    try std.testing.expect(!allocator_instance.resize(persistent, 16));
    try std.testing.expect(!allocator_instance.resize(persistent, 48));
    const scratch = try allocator_instance.alloc(u8, 32);
    try std.testing.expect(persistent_address != @intFromPtr(scratch.ptr));

    arena.rewind(scope);
    try std.testing.expect(allocator_instance.resize(persistent, 16));
    persistent = persistent[0..16];
    try std.testing.expectEqual(persistent_address, @intFromPtr(persistent.ptr));
}

test "inner mark protects allocations owned by outer scope" {
    var backing: [4096]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&backing);
    var arena = ScopedArenaAllocator.init(fixed.allocator());
    defer arena.deinit();
    const allocator_instance = arena.allocator();

    const outer = arena.mark();
    const outer_value = try allocator_instance.alloc(u8, 32);
    const outer_address = @intFromPtr(outer_value.ptr);
    const inner = arena.mark();
    allocator_instance.free(outer_value);
    const inner_value = try allocator_instance.alloc(u8, 32);
    try std.testing.expect(outer_address != @intFromPtr(inner_value.ptr));

    arena.rewind(inner);
    allocator_instance.free(outer_value);
    const outer_again = try allocator_instance.alloc(u8, 32);
    try std.testing.expectEqual(outer_address, @intFromPtr(outer_again.ptr));
    try std.testing.expect(allocator_instance.resize(outer_again, 16));
    arena.rewind(outer);
}
