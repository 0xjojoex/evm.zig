const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;

const Memory = @This();

const word_size = 32;

pub const Error = error{
    MemoryOverflow,
};

bytes: ArrayList(u8),
allocator: Allocator,

pub fn init(allocator: Allocator) Memory {
    return .{ .bytes = .empty, .allocator = allocator };
}

pub fn deinit(self: *Memory) void {
    self.bytes.deinit(self.allocator);
    self.* = undefined;
}

pub fn read(self: *const Memory, offset: usize) u256 {
    assert(offset + word_size <= self.bytes.items.len);

    const bytes = self.bytes.items[offset..][0..word_size];
    const value = @byteSwap(@as(u256, @bitCast(bytes.*)));
    return value;
}

pub fn readBytes(self: *const Memory, offset: usize, size: usize) []u8 {
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
    try self.bytes.appendNTimes(self.allocator, 0, size - self.len());
}

pub fn write(self: *Memory, offset: usize, value: u256) !void {
    assert(offset + word_size <= self.bytes.items.len);

    const pad_left_value = @byteSwap(value);
    const bytes = std.mem.asBytes(&pad_left_value);
    @memcpy(self.bytes.items[offset..][0..word_size], bytes);
}

pub fn writeBytes(self: *Memory, offset: usize, value: []const u8) !void {
    assert(offset + value.len <= self.bytes.items.len);

    @memcpy(self.bytes.items[offset..][0..value.len], value);
}

pub fn write8(self: *Memory, offset: usize, value: u256) void {
    // assuming already resize upstream
    assert(offset + 1 <= self.bytes.items.len);
    const bytes = std.mem.asBytes(&value);
    self.bytes.items[offset] = bytes[0];
}

pub fn copy(self: *Memory, dest: usize, src: usize, size: usize) !void {
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
    const cost = try self.expansionCost(offset, byte_size);
    try self.expandToFit(offset, byte_size);
    return cost;
}

pub fn expansionCost(self: *const Memory, offset: usize, byte_size: usize) Error!i64 {
    const next_size = try nextSize(offset, byte_size);
    if (self.len() < next_size) {
        return try memoryCost(next_size) - try memoryCost(self.len());
    }
    return 0;
}

pub fn expandToFit(self: *Memory, offset: usize, byte_size: usize) !void {
    const next_size = try nextSize(offset, byte_size);
    if (self.len() < next_size) {
        try self.resize(next_size);
    }
}

inline fn nextSize(offset: usize, byte_size: usize) Error!usize {
    if (byte_size == 0) {
        return 0;
    }
    const end = std.math.add(usize, offset, byte_size) catch return Error.MemoryOverflow;
    const end_with_padding = std.math.add(usize, end, word_size - 1) catch return Error.MemoryOverflow;
    return (end_with_padding / word_size) * word_size;
}

test nextSize {
    try std.testing.expectEqual(32, try nextSize(0, 32));
    try std.testing.expectEqual(64, try nextSize(31, 32));
    try std.testing.expectEqual(64, try nextSize(32, 32));
    try std.testing.expectEqual(96, try nextSize(57, 32));
    try std.testing.expectEqual(256, try nextSize(255, 1));
    try std.testing.expectEqual(32, try nextSize(1, 3));
    try std.testing.expectError(Error.MemoryOverflow, nextSize(std.math.maxInt(usize), 1));
}

pub inline fn memoryCost(expand_size: usize) Error!i64 {
    const memory_size_word = (expand_size + 31) / 32;
    const words: u128 = memory_size_word;
    const cost = (words * words) / 512 + (3 * words);
    if (cost > std.math.maxInt(i64)) return Error.MemoryOverflow;
    return @intCast(cost);
}

test Memory {
    var memory = Memory.init(std.testing.allocator);
    defer memory.deinit();

    _ = try memory.expand(0, 64);
    try memory.write(0, 0xff);

    const value0 = memory.read(0);
    try std.testing.expectEqual(0xff, value0);

    const value1 = memory.read(1);
    try std.testing.expectEqual(0xff00, value1);

    try memory.write(31, 0xff);
    const value2 = memory.read(31);
    try std.testing.expectEqual(0xff, value2);
}

test "memory writes overwrite without shifting bytes" {
    var memory = Memory.init(std.testing.allocator);
    defer memory.deinit();

    _ = try memory.expand(0, 32);
    try std.testing.expectEqual(@as(usize, 32), memory.len());

    try memory.write(0, 0xff);
    try std.testing.expectEqual(@as(usize, 32), memory.len());
    try std.testing.expectEqual(@as(u256, 0xff), memory.read(0));

    try memory.write(0, 0xaa);
    try std.testing.expectEqual(@as(usize, 32), memory.len());
    try std.testing.expectEqual(@as(u256, 0xaa), memory.read(0));
}

test "memory byte slice writes overwrite without shifting bytes" {
    var memory = Memory.init(std.testing.allocator);
    defer memory.deinit();

    _ = try memory.expand(0, 32);
    try memory.writeBytes(0, &.{ 0xaa, 0xbb, 0xcc });
    try std.testing.expectEqual(@as(usize, 32), memory.len());
    try std.testing.expectEqualSlices(u8, &.{ 0xaa, 0xbb, 0xcc }, memory.readBytes(0, 3));

    try memory.writeBytes(1, &.{ 0x11, 0x22 });
    try std.testing.expectEqual(@as(usize, 32), memory.len());
    try std.testing.expectEqualSlices(u8, &.{ 0xaa, 0x11, 0x22 }, memory.readBytes(0, 3));
}

test "memory copy is overlap safe" {
    var memory = Memory.init(std.testing.allocator);
    defer memory.deinit();

    _ = try memory.expand(0, 32);
    try memory.writeBytes(0, &.{ 0xaa, 0xbb, 0xcc, 0xdd });
    try memory.copy(2, 0, 4);
    try std.testing.expectEqualSlices(u8, &.{ 0xaa, 0xbb, 0xaa, 0xbb, 0xcc, 0xdd }, memory.readBytes(0, 6));

    try memory.copy(0, 2, 4);
    try std.testing.expectEqualSlices(u8, &.{ 0xaa, 0xbb, 0xcc, 0xdd }, memory.readBytes(0, 4));
}
