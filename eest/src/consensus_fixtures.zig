const std = @import("std");
const Io = std.Io;
const pins = @import("consensus_pins");
const presets = .{ "general", "mainnet", "minimal" };

/// Prepare immutable, hash-verified fixtures in the shared cache. The lock
/// covers admission and atomic publication, and is released before tests run.
pub fn prepare(init: std.process.Init, zig_exe: []const u8, global_cache: ?[]const u8) ![presets.len][]const u8 {
    const allocator = init.arena.allocator();
    const io = init.io;
    const xdg_cache = init.environ_map.get("XDG_CACHE_HOME") orelse "";
    const base = if (xdg_cache.len != 0) xdg_cache else base: {
        const home = init.environ_map.get("HOME") orelse return error.MissingCacheHome;
        break :base try Io.Dir.path.join(allocator, &.{ home, ".cache" });
    };
    const cwd = try Io.Dir.cwd().realPathFileAlloc(io, ".", allocator);
    const cache_path = try std.fs.path.resolve(allocator, &.{ cwd, base, "evmz", "consensus" });
    var cache = try Io.Dir.cwd().createDirPathOpen(io, cache_path, .{});
    defer cache.close(io);
    const lock = try cache.createFile(io, ".lock", .{ .truncate = false, .lock = .exclusive });
    defer lock.close(io);

    var paths: [presets.len][]const u8 = undefined;
    inline for (presets, 0..) |preset, i| {
        const pin = @field(pins, preset);
        const subdir = if (std.mem.eql(u8, preset, "general")) "general/phase0/ssz_generic" else preset;
        try preparePackage(init, zig_exe, global_cache, cache, pin.url, pin.hash, subdir);
        paths[i] = try Io.Dir.path.join(allocator, &.{ cache_path, pin.hash, subdir });
    }
    return paths;
}

fn preparePackage(
    init: std.process.Init,
    zig_exe: []const u8,
    global_cache: ?[]const u8,
    cache: Io.Dir,
    url: []const u8,
    hash: []const u8,
    subdir: []const u8,
) !void {
    const allocator = init.arena.allocator();
    const io = init.io;
    if (cache.openDir(io, hash, .{ .follow_symlinks = false })) |package| {
        package.close(io);
    } else |err| switch (err) {
        error.FileNotFound => {
            var random: u64 = undefined;
            io.random(std.mem.asBytes(&random));
            const temporary = try allocator.print(".prepare-{x}", .{random});
            // Stage on the same filesystem as the final package, exclusively.
            try cache.createDir(io, temporary, .default_dir);
            defer cache.deleteTree(io, temporary) catch {};
            var staging = try cache.openDir(io, temporary, .{});
            defer staging.close(io);
            try staging.writeFile(io, .{ .sub_path = "build.zig", .data = "" });
            var manifest: Io.Writer.Allocating = .init(allocator);
            try std.zon.stringify.serialize(.{
                .name = .fixture_cache,
                .version = "0.0.0",
                .fingerprint = @as(u64, 0x58a8d62106270de5),
                .paths = .{"build.zig"},
                .dependencies = .{ .fixture = .{ .url = url, .hash = hash } },
            }, .{}, &manifest.writer);
            try staging.writeFile(io, .{ .sub_path = "build.zig.zon", .data = manifest.written() });

            const result = try std.process.run(allocator, io, .{
                .argv = if (global_cache) |path|
                    &.{ zig_exe, "build", "--fetch=all", "--global-cache-dir", path }
                else
                    &.{ zig_exe, "build", "--fetch=all" },
                .cwd = .{ .path = try staging.realPathFileAlloc(io, ".", allocator) },
                .environ_map = init.environ_map,
            });
            if (result.stderr.len != 0) std.debug.print("{s}", .{result.stderr});
            switch (result.term) {
                .exited => |code| if (code != 0) return error.FixtureFetchFailed,
                else => return error.FixtureFetchFailed,
            }
            const source = try Io.Dir.path.join(allocator, &.{ "zig-pkg", hash });
            const fixtures = try staging.openDir(io, try Io.Dir.path.join(allocator, &.{ source, subdir }), .{});
            fixtures.close(io);
            try staging.rename(source, cache, hash, io);
        },
        else => return err,
    }
    const fixtures = try cache.openDir(io, try Io.Dir.path.join(allocator, &.{ hash, subdir }), .{});
    fixtures.close(io);
}
