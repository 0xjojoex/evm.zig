const std = @import("std");
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

pub fn read(self: *Memory, offset: usize) u256 {
    const bytes = self.bytes.items[offset..][0..word_size];
    const value = @byteSwap(@as(u256, @bitCast(bytes.*)));
    return value;
}

pub fn readBytes(self: *Memory, offset: usize, size: usize) []u8 {
    return self.bytes.items[offset..][0..size];
}

pub fn len(self: *Memory) usize {
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
    const bytes = std.mem.asBytes(&value);
    // assuming already resize upstream
    self.bytes.items[offset] = bytes[0];
}

pub fn expand(self: *Memory, offset: usize, byte_size: usize) !void {
    if (byte_size == 0) {
        return;
    }
    const next_size = nextSize(offset, byte_size);
    if (self.len() < next_size) {
        try self.resize(next_size);
    }
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