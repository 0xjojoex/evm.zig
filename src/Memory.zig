const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const uint256 = @import("./uint256.zig");

const Memory = @This();

const word_size = 32;

pub const Expansion = struct {
    cost: i64,
    next_size: usize,
};

pub const Storage = ArrayList(u8);

/// Stable coordinates into EVM memory. Resolve only while the owning frame is
/// alive; the backing allocation may move as memory expands.
pub const Range = struct {
    offset: usize = 0,
    len: usize = 0,
};

bytes: *Storage,
allocator: Allocator,

pub fn init(storage: *Storage, allocator: Allocator) Memory {
    storage.* = .empty;
    return .{ .bytes = storage, .allocator = allocator };
}

pub fn initRetainingCapacity(storage: *Storage, allocator: Allocator) Memory {
    storage.clearRetainingCapacity();
    return .{ .bytes = storage, .allocator = allocator };
}

pub fn reserveCapacity(storage: *Storage, allocator: Allocator, capacity: usize) !void {
    try storage.ensureTotalCapacityPrecise(allocator, capacity);
    storage.clearRetainingCapacity();
}

pub fn deinit(self: *Memory) void {
    self.bytes.deinit(self.allocator);
    self.bytes.* = .empty;
    self.* = undefined;
}

pub fn deinitRetainingCapacity(self: *Memory) void {
    self.bytes.clearRetainingCapacity();
    self.* = undefined;
}

pub fn rebindStorage(self: *Memory, storage: *Storage) void {
    self.bytes = storage;
}

pub fn read(self: *const Memory, offset: usize) u256 {
    assert(offset + word_size <= self.bytes.items.len);

    const bytes = self.bytes.items[offset..][0..word_size];
    return uint256.fromBytes32(bytes);
}

pub fn readBytes(self: *const Memory, offset: usize, size: usize) []u8 {
    assert(offset + size <= self.bytes.items.len);

    return self.bytes.items[offset..][0..size];
}

pub fn range(self: *const Memory, offset: usize, size: usize) Range {
    assert(offset <= self.bytes.items.len);
    assert(size <= self.bytes.items.len - offset);
    return .{ .offset = offset, .len = size };
}

pub fn readRange(self: *const Memory, memory_range: Range) []u8 {
    if (memory_range.len == 0) return &.{};
    return self.readBytes(memory_range.offset, memory_range.len);
}

pub fn writeSlice(self: *Memory, offset: usize, size: usize) []u8 {
    assert(offset + size <= self.bytes.items.len);

    return self.bytes.items[offset..][0..size];
}

pub fn len(self: *const Memory) usize {
    return self.bytes.items.len;
}

fn resize(self: *Memory, size: usize) !void {
    if (size <= self.len()) {
        return;
    }
    const additional = size - self.len();
    if (self.bytes.capacity >= size) {
        self.bytes.appendNTimesAssumeCapacity(0, additional);
        return;
    }
    try self.bytes.appendNTimes(self.allocator, 0, additional);
}

pub fn write(self: *Memory, offset: usize, value: u256) void {
    assert(offset + word_size <= self.bytes.items.len);

    const bytes = self.bytes.items[offset..][0..word_size];
    uint256.writeBytes32(bytes, value);
}

pub fn writeBytes(self: *Memory, offset: usize, value: []const u8) void {
    if (value.len == 0) return;
    assert(offset + value.len <= self.bytes.items.len);

    @memcpy(self.bytes.items[offset..][0..value.len], value);
}

pub fn writePaddedBytes(self: *Memory, offset: usize, size: usize, value: []const u8) void {
    if (size == 0) return;
    assert(offset + size <= self.bytes.items.len);

    const dest = self.bytes.items[offset..][0..size];
    const copied = @min(size, value.len);
    if (copied != 0) {
        @memcpy(dest[0..copied], value[0..copied]);
    }
    if (copied < size) {
        @memset(dest[copied..], 0);
    }
}

pub fn write8(self: *Memory, offset: usize, value: u256) void {
    // assuming already resize upstream
    assert(offset + 1 <= self.bytes.items.len);
    self.bytes.items[offset] = @truncate(value);
}

pub fn copy(self: *Memory, dest: usize, src: usize, size: usize) void {
    assert(dest + size <= self.bytes.items.len);
    assert(src + size <= self.bytes.items.len);

    if (dest == src or size == 0) return;

    const dest_bytes = self.bytes.items[dest..][0..size];
    const src_bytes = self.bytes.items[src..][0..size];
    if (dest < src) {
        std.mem.copyForwards(u8, dest_bytes, src_bytes);
    } else {
        std.mem.copyBackwards(u8, dest_bytes, src_bytes);
    }
}

/// Expand the memory if needed, return the *gas cost* of the expansion.
pub fn expand(self: *Memory, offset: usize, byte_size: usize) !i64 {
    const expansion = try self.expansionFor(offset, byte_size);
    try self.expandPrepared(expansion);
    return expansion.cost;
}

pub fn expansionFor(self: *const Memory, offset: usize, byte_size: usize) error{OutOfMemory}!Expansion {
    const next_size = try nextSize(offset, byte_size);
    const cost = if (self.len() < next_size)
        try memoryCost(next_size) - try memoryCost(self.len())
    else
        0;
    return .{ .cost = cost, .next_size = next_size };
}

pub fn expansionCost(self: *const Memory, offset: usize, byte_size: usize) error{OutOfMemory}!i64 {
    return (try self.expansionFor(offset, byte_size)).cost;
}

pub fn expandToFit(self: *Memory, offset: usize, byte_size: usize) !void {
    try self.expandPrepared(try self.expansionFor(offset, byte_size));
}

pub fn expandPrepared(self: *Memory, expansion: Expansion) !void {
    if (self.len() < expansion.next_size) {
        try self.resize(expansion.next_size);
    }
}

inline fn nextSize(offset: usize, byte_size: usize) !usize {
    if (byte_size == 0) {
        return 0;
    }
    const end = std.math.add(usize, offset, byte_size) catch return error.OutOfMemory;
    const end_with_padding = std.math.add(usize, end, word_size - 1) catch return error.OutOfMemory;
    return (end_with_padding / word_size) * word_size;
}

test nextSize {
    try std.testing.expectEqual(32, try nextSize(0, 32));
    try std.testing.expectEqual(64, try nextSize(31, 32));
    try std.testing.expectEqual(64, try nextSize(32, 32));
    try std.testing.expectEqual(96, try nextSize(57, 32));
    try std.testing.expectEqual(256, try nextSize(255, 1));
    try std.testing.expectEqual(32, try nextSize(1, 3));
    try std.testing.expectError(error.OutOfMemory, nextSize(std.math.maxInt(usize), 1));
}

pub inline fn memoryCost(expand_size: usize) !i64 {
    const memory_size_word = (expand_size + 31) / 32;
    const words: u128 = memory_size_word;
    const cost = (words * words) / 512 + (3 * words);
    if (cost > std.math.maxInt(i64)) return error.OutOfMemory;
    return @intCast(cost);
}

test Memory {
    var storage: Storage = .empty;
    var memory = Memory.init(&storage, std.testing.allocator);
    defer memory.deinit();

    _ = try memory.expand(0, 64);
    memory.write(0, 0xff);

    const value0 = memory.read(0);
    try std.testing.expectEqual(0xff, value0);

    const value1 = memory.read(1);
    try std.testing.expectEqual(0xff00, value1);

    memory.write(31, 0xff);
    const value2 = memory.read(31);
    try std.testing.expectEqual(0xff, value2);
}

test "bounded memory reuses reserved capacity and rejects growth" {
    const no_growth_allocator: Allocator = .{
        .ptr = undefined,
        .vtable = &.{
            .alloc = Allocator.noAlloc,
            .resize = Allocator.noResize,
            .remap = Allocator.noRemap,
            .free = Allocator.noFree,
        },
    };

    var storage: Storage = .empty;
    try Memory.reserveCapacity(&storage, std.testing.allocator, 64);

    {
        var memory = Memory.initRetainingCapacity(&storage, no_growth_allocator);
        _ = try memory.expand(0, 64);
        try std.testing.expectEqual(@as(usize, 64), memory.len());
        try std.testing.expectError(error.OutOfMemory, memory.expand(64, 32));
        memory.deinitRetainingCapacity();
    }

    try std.testing.expectEqual(@as(usize, 64), storage.capacity);
    try std.testing.expectEqual(@as(usize, 0), storage.items.len);

    {
        var memory = Memory.initRetainingCapacity(&storage, std.testing.allocator);
        defer memory.deinit();
        _ = try memory.expand(32, 32);
        try std.testing.expectEqual(@as(usize, 64), memory.len());
        try std.testing.expectEqual(@as(usize, 64), storage.capacity);
    }
}

test "memory writes overwrite without shifting bytes" {
    var storage: Storage = .empty;
    var memory = Memory.init(&storage, std.testing.allocator);
    defer memory.deinit();

    _ = try memory.expand(0, 32);
    try std.testing.expectEqual(@as(usize, 32), memory.len());

    memory.write(0, 0xff);
    try std.testing.expectEqual(@as(usize, 32), memory.len());
    try std.testing.expectEqual(@as(u256, 0xff), memory.read(0));

    memory.write(0, 0xaa);
    try std.testing.expectEqual(@as(usize, 32), memory.len());
    try std.testing.expectEqual(@as(u256, 0xaa), memory.read(0));
}

test "memory byte slice writes overwrite without shifting bytes" {
    var storage: Storage = .empty;
    var memory = Memory.init(&storage, std.testing.allocator);
    defer memory.deinit();

    _ = try memory.expand(0, 32);
    memory.writeBytes(0, &.{ 0xaa, 0xbb, 0xcc });
    try std.testing.expectEqual(@as(usize, 32), memory.len());
    try std.testing.expectEqualSlices(u8, &.{ 0xaa, 0xbb, 0xcc }, memory.readBytes(0, 3));

    memory.writeBytes(1, &.{ 0x11, 0x22 });
    try std.testing.expectEqual(@as(usize, 32), memory.len());
    try std.testing.expectEqualSlices(u8, &.{ 0xaa, 0x11, 0x22 }, memory.readBytes(0, 3));
}

test "empty memory byte writes are no-ops" {
    var storage: Storage = .empty;
    var memory = Memory.init(&storage, std.testing.allocator);
    defer memory.deinit();

    memory.writeBytes(1024, &.{});
    try std.testing.expectEqual(@as(usize, 0), memory.len());
}

test "memory byte writes use low byte of word" {
    var storage: Storage = .empty;
    var memory = Memory.init(&storage, std.testing.allocator);
    defer memory.deinit();

    _ = try memory.expand(0, 1);
    memory.write8(0, 0x1234);
    try std.testing.expectEqual(@as(u8, 0x34), memory.readBytes(0, 1)[0]);
}

test "padded memory byte writes only zero missing source bytes" {
    var storage: Storage = .empty;
    var memory = Memory.init(&storage, std.testing.allocator);
    defer memory.deinit();

    _ = try memory.expand(0, 32);
    @memset(memory.readBytes(0, 32), 0xff);

    memory.writePaddedBytes(0, 4, &.{ 0xaa, 0xbb, 0xcc, 0xdd, 0xee });
    try std.testing.expectEqualSlices(u8, &.{ 0xaa, 0xbb, 0xcc, 0xdd }, memory.readBytes(0, 4));
    try std.testing.expectEqual(@as(u8, 0xff), memory.readBytes(4, 1)[0]);

    memory.writePaddedBytes(8, 4, &.{ 0x11, 0x22 });
    try std.testing.expectEqualSlices(u8, &.{ 0x11, 0x22, 0x00, 0x00 }, memory.readBytes(8, 4));
}

test "memory copy is overlap safe" {
    var storage: Storage = .empty;
    var memory = Memory.init(&storage, std.testing.allocator);
    defer memory.deinit();

    _ = try memory.expand(0, 32);
    memory.writeBytes(0, &.{ 0xaa, 0xbb, 0xcc, 0xdd });
    memory.copy(2, 0, 4);
    try std.testing.expectEqualSlices(u8, &.{ 0xaa, 0xbb, 0xaa, 0xbb, 0xcc, 0xdd }, memory.readBytes(0, 6));

    memory.copy(0, 2, 4);
    try std.testing.expectEqualSlices(u8, &.{ 0xaa, 0xbb, 0xcc, 0xdd }, memory.readBytes(0, 4));
}
