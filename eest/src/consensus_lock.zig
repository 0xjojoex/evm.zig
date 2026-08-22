const std = @import("std");

pub const Value = struct {
    bytes: []u8,
    relative_prefix: []const u8,

    pub fn deinit(self: *Value, allocator: std.mem.Allocator) void {
        allocator.free(self.bytes);
        self.* = undefined;
    }
};

/// Read an owned value from the nearest consensus fixture lock.
pub fn readValue(
    io: std.Io,
    allocator: std.mem.Allocator,
    key: []const u8,
) !Value {
    const locations = [_]struct {
        lock_path: []const u8,
        relative_prefix: []const u8,
    }{
        .{ .lock_path = "consensus.lock", .relative_prefix = "" },
        .{ .lock_path = "eest/consensus.lock", .relative_prefix = "eest" },
    };

    for (locations) |location| {
        const lock = std.Io.Dir.cwd().readFileAlloc(
            io,
            location.lock_path,
            allocator,
            .limited(64 * 1024),
        ) catch |err| {
            if (err == error.FileNotFound) continue;
            return err;
        };
        defer allocator.free(lock);
        const raw = parseValue(lock, key) orelse return error.MissingConsensusLockKey;
        return .{
            .bytes = try allocator.dupe(u8, raw),
            .relative_prefix = location.relative_prefix,
        };
    }
    return error.MissingConsensusLock;
}

pub fn parseValue(bytes: []const u8, key: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        const equals = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const line_key = std.mem.trim(u8, line[0..equals], " \t");
        if (!std.mem.eql(u8, line_key, key)) continue;
        return std.mem.trim(u8, line[equals + 1 ..], " \t");
    }
    return null;
}

pub fn relativeReleasePath(
    allocator: std.mem.Allocator,
    release: []const u8,
) ![]u8 {
    const slug = try allocator.dupe(u8, release);
    defer allocator.free(slug);
    for (slug) |*byte| {
        if (byte.* == '@') byte.* = '-';
    }
    return std.fs.path.join(allocator, &.{ ".consensus", slug });
}

test "consensus lock parser trims comments and values" {
    const bytes =
        \\# comment
        \\ repository = example/specs
        \\release=example@release
        \\ artifact = fixtures.tar.gz
        \\
    ;

    try std.testing.expectEqualStrings("example/specs", parseValue(bytes, "repository").?);
    try std.testing.expectEqualStrings("example@release", parseValue(bytes, "release").?);
    try std.testing.expectEqualStrings("fixtures.tar.gz", parseValue(bytes, "artifact").?);
    try std.testing.expectEqual(@as(?[]const u8, null), parseValue(bytes, "missing"));
}

test "consensus release paths are derived from the release" {
    const allocator = std.testing.allocator;
    const consensus = try relativeReleasePath(allocator, "release-alpha");
    defer allocator.free(consensus);

    try std.testing.expectEqualStrings(".consensus/release-alpha", consensus);
}
