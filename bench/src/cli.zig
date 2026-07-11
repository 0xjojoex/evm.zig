const std = @import("std");

pub fn stripPrefix(value: []const u8, prefix: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, value, prefix)) return null;
    return value[prefix.len..];
}

pub fn parseNonZeroUsize(value: []const u8) !usize {
    const parsed = try std.fmt.parseUnsigned(usize, value, 10);
    if (parsed == 0) return error.InvalidNumber;
    return parsed;
}

pub fn parseUsize(value: []const u8) !usize {
    return std.fmt.parseUnsigned(usize, value, 10);
}

test "integer parsers distinguish zero-allowed and non-zero values" {
    try std.testing.expectEqual(@as(usize, 0), try parseUsize("0"));
    try std.testing.expectEqual(@as(usize, 42), try parseNonZeroUsize("42"));
    try std.testing.expectError(error.InvalidNumber, parseNonZeroUsize("0"));
}
