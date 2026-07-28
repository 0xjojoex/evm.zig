//! Shared canonical RLP wire encoding primitives.

const std = @import("std");

pub const Error = error{EncodedLengthOverflow};

pub fn writeBytes(writer: anytype, payload: []const u8) !void {
    if (payload.len == 1 and payload[0] < 0x80) {
        try writer.appendByte(payload[0]);
        return;
    }
    try writeLengthPrefix(writer, 0x80, 0xb7, payload.len);
    try writer.appendSlice(payload);
}

pub fn writeInt(writer: anytype, comptime T: type, value: T) !void {
    assertUnsignedInt(T);
    if (value == 0) return writeBytes(writer, &.{});

    const encoded = intBytes(T, value);
    const first = encoded.len - significantBytes(T, value);
    try writeBytes(writer, encoded[first..]);
}

/// Number of bytes in the minimal big-endian representation; 0 only for 0.
pub fn significantBytes(comptime T: type, value: T) usize {
    if (value == 0) return 0;
    const bits = @as(usize, @bitSizeOf(T)) - @clz(value);
    return (bits + 7) / 8;
}

pub fn writeListPayload(writer: anytype, payload: []const u8) !void {
    try writeLengthPrefix(writer, 0xc0, 0xf7, payload.len);
    try writer.appendSlice(payload);
}

pub fn writeLengthPrefix(
    writer: anytype,
    short_base: u8,
    long_base: u8,
    payload_len: usize,
) !void {
    if (payload_len < 56) {
        try writer.appendByte(short_base + @as(u8, @intCast(payload_len)));
        return;
    }

    const len_of_len = try lengthByteCount(payload_len);
    try writer.appendByte(long_base + @as(u8, @intCast(len_of_len)));

    var encoded: [8]u8 = undefined;
    var remaining = std.math.cast(u64, payload_len) orelse
        return error.EncodedLengthOverflow;
    var index = encoded.len;
    while (index > encoded.len - len_of_len) {
        index -= 1;
        encoded[index] = @truncate(remaining);
        remaining >>= 8;
    }
    try writer.appendSlice(encoded[index..]);
}

pub fn lengthByteCount(value: usize) Error!usize {
    var remaining = std.math.cast(u64, value) orelse
        return error.EncodedLengthOverflow;
    var count: usize = 0;
    while (remaining != 0) : (remaining >>= 8) count += 1;
    return count;
}

pub fn assertUnsignedInt(comptime T: type) void {
    const info = switch (@typeInfo(T)) {
        .int => |value| value,
        else => @compileError("RLP integer encoding requires an unsigned integer type"),
    };
    if (info.signedness != .unsigned or info.bits == 0 or info.bits > 256) {
        @compileError("RLP integer encoding supports unsigned integers from 1 to 256 bits");
    }
}

pub fn intBytes(comptime T: type, value: T) [byteLen(T)]u8 {
    const Wide = std.meta.Int(.unsigned, byteLen(T) * 8);
    var bytes: [byteLen(T)]u8 = undefined;
    std.mem.writeInt(Wide, &bytes, value, .big);
    return bytes;
}

pub fn byteLen(comptime T: type) usize {
    return (@typeInfo(T).int.bits + 7) / 8;
}
