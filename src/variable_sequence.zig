const std = @import("std");
const Error = @import("error.zig").Error;

pub const bytes_per_offset = 4;

pub fn encodedLen(comptime ElementCodec: type, values: anytype) Error!usize {
    var total = std.math.mul(usize, values.len, bytes_per_offset) catch
        return error.EncodedLengthOverflow;
    for (values) |value| {
        total = std.math.add(usize, total, try ElementCodec.encodedLen(value)) catch
            return error.EncodedLengthOverflow;
    }
    try validateSerializedLength(total);
    return total;
}

pub fn encodeInto(comptime ElementCodec: type, out: []u8, values: anytype) Error!void {
    var variable_offset = values.len * bytes_per_offset;
    for (values, 0..) |value, index| {
        writeOffset(out[index * bytes_per_offset ..][0..bytes_per_offset], variable_offset);
        const encoded = try ElementCodec.encode(out[variable_offset..], value);
        variable_offset += encoded.len;
    }
    std.debug.assert(variable_offset == out.len);
}

/// Validate a variable-element sequence's offset table without traversing its
/// elements. Decoders use this before slicing elements, which then validate
/// themselves while materializing their values.
pub fn validateOffsets(bytes: []const u8, count: usize) Error!void {
    try validateSerializedLength(bytes.len);
    const fixed_size = std.math.mul(usize, count, bytes_per_offset) catch
        return error.EncodedLengthOverflow;
    if (count == 0) {
        if (bytes.len != 0) return error.InvalidByteLength;
        return;
    }
    if (bytes.len < fixed_size) return error.InvalidByteLength;

    const first_offset = readOffset(bytes, 0);
    if (first_offset != fixed_size) return error.InvalidFirstOffset;

    var previous = first_offset;
    for (0..count) |index| {
        const offset = readOffset(bytes, index * bytes_per_offset);
        if (offset < previous) return error.OffsetsNotMonotonic;
        if (offset > bytes.len) return error.OffsetOutOfBounds;
        previous = offset;
    }
}

pub fn inferCount(bytes: []const u8) Error!usize {
    try validateSerializedLength(bytes.len);
    if (bytes.len == 0) return 0;
    if (bytes.len < bytes_per_offset) return error.InvalidByteLength;

    const first_offset = readOffset(bytes, 0);
    if (first_offset == 0 or first_offset % bytes_per_offset != 0) {
        return error.InvalidFirstOffset;
    }
    if (first_offset > bytes.len) return error.OffsetOutOfBounds;
    return first_offset / bytes_per_offset;
}

pub fn elementBytes(bytes: []const u8, count: usize, index: usize) []const u8 {
    const start = readOffset(bytes, index * bytes_per_offset);
    const end = if (index + 1 < count)
        readOffset(bytes, (index + 1) * bytes_per_offset)
    else
        bytes.len;
    // Callers must run validateOffsets first, which guarantees this ordering.
    std.debug.assert(start <= end and end <= bytes.len);
    return bytes[start..end];
}

fn writeOffset(out: []u8, offset: usize) void {
    std.mem.writeInt(u32, out[0..bytes_per_offset], @intCast(offset), .little);
}

fn readOffset(bytes: []const u8, offset: usize) usize {
    return std.mem.readInt(u32, bytes[offset..][0..bytes_per_offset], .little);
}

fn validateSerializedLength(len: usize) Error!void {
    if (len > std.math.maxInt(u32)) return error.EncodedLengthOverflow;
}
