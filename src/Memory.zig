const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;

const Memory = @This();

const word_size = 32;

bytes: ArrayList(u8),

pub fn init(allocator: Allocator) Memory {
    return .{ .bytes = ArrayList(u8).init(allocator) };
}

pub fn deinit(self: *Memory) void {
    self.bytes.deinit();
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
    try self.bytes.appendNTimes(0, size);
}

pub fn write(self: *Memory, offset: usize, value: u256) !void {
    const pad_left_value = @byteSwap(value);
    const bytes = std.mem.asBytes(&pad_left_value);
    try self.bytes.insertSlice(offset, bytes);
}

pub fn writeBytes(self: *Memory, offset: usize, value: []u8) !void {
    try self.bytes.insertSlice(offset, value);
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

    @memcpy(self.readBytes(dest, size), self.readBytes(src, size));
}

/// Expand the memory if needed, return the *gas cost* of the expansion.
pub fn expand(self: *Memory, offset: usize, byte_size: usize) !i64 {
    if (byte_size == 0) {
        return 0;
    }
    const next_size = nextSize(offset, byte_size);
    if (self.len() < next_size) {
        try self.resize(next_size);
        return expandCost(next_size);
    }
    return 0;
}

inline fn nextSize(offset: usize, byte_size: usize) usize {
    const f: f64 = @floatFromInt(offset);
    const byte_size_f: f64 = @floatFromInt(byte_size);
    const base: usize = @intFromFloat(@ceil(f / byte_size_f) * byte_size_f);
    return base + byte_size;
}

test nextSize {
    try std.testing.expectEqual(32, nextSize(0, 32));
    try std.testing.expectEqual(64, nextSize(31, 32));
    try std.testing.expectEqual(64, nextSize(32, 32));
    try std.testing.expectEqual(96, nextSize(57, 32));
    try std.testing.expectEqual(256, nextSize(255, 1));
}

pub inline fn expandCost(expand_size: u64) i64 {
    const memory_size_word = (expand_size + 31) / 32;
    return @intCast((memory_size_word * memory_size_word) / 512 + (3 * memory_size_word));
}

test Memory {
    var memory = Memory.init(std.testing.allocator);
    defer memory.deinit();

    try memory.resize(32);
    try memory.write(0, 0xff);

    const value0 = memory.read(0);
    try std.testing.expectEqual(0xff, value0);

    const value1 = memory.read(1);
    try std.testing.expectEqual(0xff00, value1);

    try memory.resize(1024);
    try memory.write(31, 0xff);
    const value2 = memory.read(31);
    try std.testing.expectEqual(0xff, value2);
}
