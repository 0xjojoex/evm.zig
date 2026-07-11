const std = @import("std");

pub const InputFormat = enum {
    raw,
    zisk,
};

pub const PublicFormat = enum {
    raw,
    zisk,
};

pub fn parseInputFormat(value: []const u8) ?InputFormat {
    if (std.mem.eql(u8, value, "raw")) return .raw;
    if (std.mem.eql(u8, value, "zisk")) return .zisk;
    return null;
}

pub fn parsePublicFormat(value: []const u8) ?PublicFormat {
    if (std.mem.eql(u8, value, "raw")) return .raw;
    if (std.mem.eql(u8, value, "zisk")) return .zisk;
    return null;
}

pub fn inputBytes(allocator: std.mem.Allocator, input: []const u8, format: InputFormat) ![]u8 {
    return switch (format) {
        .raw => try allocator.dupe(u8, input),
        .zisk => try ziskInputFrame(allocator, input),
    };
}

pub fn publicValuesBytes(allocator: std.mem.Allocator, public_values: []const u8, format: PublicFormat) ![]u8 {
    if (public_values.len != 32) return error.InvalidPublicValuesLength;
    return switch (format) {
        .raw => try allocator.dupe(u8, public_values),
        .zisk => blk: {
            const out = try allocator.alloc(u8, 256);
            @memset(out, 0);
            @memcpy(out[0..32], public_values);
            break :blk out;
        },
    };
}

fn ziskInputFrame(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    const total_len = 8 + input.len;
    const padding = (8 - (total_len % 8)) % 8;
    const out = try allocator.alloc(u8, total_len + padding);
    @memset(out, 0);
    std.mem.writeInt(u64, out[0..8], input.len, .little);
    @memcpy(out[8..][0..input.len], input);
    return out;
}

test "input raw format leaves bytes unchanged" {
    const out = try inputBytes(std.testing.allocator, "hello", .raw);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("hello", out);
}

test "input zisk format stores one length-prefixed padded record" {
    const frame = try inputBytes(std.testing.allocator, "hello", .zisk);
    defer std.testing.allocator.free(frame);

    try std.testing.expectEqual(@as(usize, 16), frame.len);
    try std.testing.expectEqual(@as(u64, 5), std.mem.readInt(u64, frame[0..8], .little));
    try std.testing.expectEqualStrings("hello", frame[8..13]);
    try std.testing.expect(std.mem.allEqual(u8, frame[13..], 0));
}

test "public zisk format pads digest to 256 bytes" {
    const digest = [_]u8{0xab} ** 32;
    const out = try publicValuesBytes(std.testing.allocator, &digest, .zisk);
    defer std.testing.allocator.free(out);

    try std.testing.expectEqual(@as(usize, 256), out.len);
    try std.testing.expectEqualSlices(u8, &digest, out[0..32]);
    try std.testing.expect(std.mem.allEqual(u8, out[32..], 0));
}
