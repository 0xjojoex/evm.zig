const std = @import("std");

pub const Value = struct {
    bytes: []u8,
    relative_prefix: []const u8,

    pub fn deinit(self: *Value, allocator: std.mem.Allocator) void {
        allocator.free(self.bytes);
        self.* = undefined;
    }
};

/// Read an owned raw value from the nearest EEST lockfile.
pub fn readValue(
    io: std.Io,
    allocator: std.mem.Allocator,
    key: []const u8,
) !Value {
    const locations = [_]struct {
        lock_path: []const u8,
        relative_prefix: []const u8,
    }{
        .{ .lock_path = "../eest.lock", .relative_prefix = ".." },
        .{ .lock_path = "eest.lock", .relative_prefix = "" },
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
        const raw = parseValue(lock, key) orelse return error.MissingEestLockKey;
        return .{
            .bytes = try allocator.dupe(u8, raw),
            .relative_prefix = location.relative_prefix,
        };
    }
    return error.MissingEestLock;
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

test "EEST lock parser trims comments and values" {
    const bytes =
        \\# comment
        \\ repo = ethereum/execution-specs
        \\version=tests-glamsterdam-devnet@v7.2.0
        \\artifact = fixtures_glamsterdam-devnet.tar.gz
        \\
    ;

    try std.testing.expectEqualStrings("ethereum/execution-specs", parseValue(bytes, "repo").?);
    try std.testing.expectEqualStrings("tests-glamsterdam-devnet@v7.2.0", parseValue(bytes, "version").?);
    try std.testing.expectEqualStrings("fixtures_glamsterdam-devnet.tar.gz", parseValue(bytes, "artifact").?);
    try std.testing.expectEqual(@as(?[]const u8, null), parseValue(bytes, "missing"));
}
