const std = @import("std");

pub const Value = struct {
    bytes: []u8,
    relative_prefix: []const u8,

    pub fn deinit(self: *Value, allocator: std.mem.Allocator) void {
        allocator.free(self.bytes);
        self.* = undefined;
    }
};

pub const Track = enum {
    zkevm,
    consensus,
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

pub fn readPath(
    io: std.Io,
    allocator: std.mem.Allocator,
    key: []const u8,
) ![]u8 {
    var value = try readValue(io, allocator, key);
    defer value.deinit(allocator);
    return resolvePath(allocator, value.relative_prefix, value.bytes);
}

pub fn releasePath(
    io: std.Io,
    allocator: std.mem.Allocator,
    track: Track,
) ![]u8 {
    var release = try readValue(io, allocator, releaseKey(track));
    defer release.deinit(allocator);
    const relative = try relativeReleasePath(allocator, track, release.bytes);
    defer allocator.free(relative);
    return resolvePath(allocator, release.relative_prefix, relative);
}

pub fn relativeReleasePath(
    allocator: std.mem.Allocator,
    track: Track,
    release: []const u8,
) ![]u8 {
    const slug = try allocator.dupe(u8, release);
    defer allocator.free(slug);
    for (slug) |*byte| {
        if (byte.* == '@') byte.* = '-';
    }
    const category = switch (track) {
        .zkevm => "fixtures",
        .consensus => "consensus",
    };
    return std.fs.path.join(allocator, &.{ ".eest", category, slug });
}

fn releaseKey(track: Track) []const u8 {
    return switch (track) {
        .zkevm => "zkevm_release",
        .consensus => "consensus_release",
    };
}

fn resolvePath(
    allocator: std.mem.Allocator,
    relative_prefix: []const u8,
    path: []const u8,
) ![]u8 {
    if (std.fs.path.isAbsolute(path) or relative_prefix.len == 0) {
        return allocator.dupe(u8, path);
    }
    return std.fs.path.join(allocator, &.{ relative_prefix, path });
}

test "EEST lock parser trims comments and values" {
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

test "fixture release paths are derived from track and release" {
    const allocator = std.testing.allocator;
    const zkevm = try relativeReleasePath(allocator, .zkevm, "example@release");
    defer allocator.free(zkevm);
    const consensus = try relativeReleasePath(allocator, .consensus, "release-alpha");
    defer allocator.free(consensus);

    try std.testing.expectEqualStrings(".eest/fixtures/example-release", zkevm);
    try std.testing.expectEqualStrings(".eest/consensus/release-alpha", consensus);
}
