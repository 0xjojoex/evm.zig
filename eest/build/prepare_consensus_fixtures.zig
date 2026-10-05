//! Host tool behind `ConsensusFixtures`: prepares the pinned consensus-spec
//! fixtures in a per-user cache shared across worktrees, then links each
//! preset's fixture root into the run step's output directory.
//!
//! usage: prepare_consensus_fixtures <zig> <out_dir> (<preset> <url> <hash> <subdir>)...

const std = @import("std");
const Io = std.Io;

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(arena);
    if (args.len < 3 or (args.len - 3) % 4 != 0) fatal("invalid arguments", .{});
    const zig_exe = args[1];
    const out_path = args[2];

    const xdg_cache = init.environ_map.get("XDG_CACHE_HOME") orelse "";
    const base = if (xdg_cache.len != 0) xdg_cache else base: {
        const home = init.environ_map.get("HOME") orelse
            fatal("shared consensus fixtures require HOME or XDG_CACHE_HOME", .{});
        break :base try std.fs.path.join(arena, &.{ home, ".cache" });
    };
    const cache_path = try std.fs.path.join(arena, &.{ base, "evmz", "consensus" });
    var cache = try Io.Dir.cwd().createDirPathOpen(io, cache_path, .{});
    defer cache.close(io);
    const lock = try cache.createFile(io, ".lock", .{ .truncate = false, .lock = .exclusive });
    defer lock.close(io);

    var out = try Io.Dir.cwd().createDirPathOpen(io, out_path, .{});
    defer out.close(io);

    var pin_args = args[3..];
    while (pin_args.len != 0) : (pin_args = pin_args[4..]) {
        const preset, const url, const hash, const subdir = pin_args[0..4].*;
        try prepare(init, cache, zig_exe, url, hash, subdir);
        const root = try std.fs.path.join(arena, &.{ cache_path, hash, subdir });
        out.deleteFile(io, preset) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };
        try out.symLink(io, root, preset, .{ .is_directory = true });
    }
}

fn prepare(
    init: std.process.Init,
    cache: Io.Dir,
    zig_exe: []const u8,
    url: []const u8,
    hash: []const u8,
    subdir: []const u8,
) !void {
    const arena = init.arena.allocator();
    const io = init.io;
    if (cache.openDir(io, hash, .{ .follow_symlinks = false })) |package| {
        package.close(io);
    } else |err| switch (err) {
        error.FileNotFound => {
            var random: u64 = undefined;
            io.random(std.mem.asBytes(&random));
            const temporary = try arena.print(".prepare-{x}", .{random});
            // Create exclusively on the same filesystem as the final package.
            try cache.createDir(io, temporary, .default_dir);
            defer cache.deleteTree(io, temporary) catch {};
            var staging = try cache.openDir(io, temporary, .{});
            defer staging.close(io);
            try staging.writeFile(io, .{ .sub_path = "build.zig", .data = "" });
            var manifest: Io.Writer.Allocating = .init(arena);
            try std.zon.stringify.serialize(.{
                .name = .fixture_cache,
                .version = "0.0.0",
                .fingerprint = @as(u64, 0x58a8d62106270de5),
                .paths = .{"build.zig"},
                .dependencies = .{ .fixture = .{ .url = url, .hash = hash } },
            }, .{}, &manifest.writer);
            try staging.writeFile(io, .{ .sub_path = "build.zig.zon", .data = manifest.written() });

            const result = try std.process.run(arena, io, .{
                .argv = &.{ zig_exe, "build", "--fetch=all" },
                .cwd = .{ .path = try staging.realPathFileAlloc(io, ".", arena) },
                .environ_map = init.environ_map,
            });
            if (!result.term.success()) fatal("fetching {s} failed:\n{s}", .{ url, result.stderr });

            const source = try std.fs.path.join(arena, &.{ "zig-pkg", hash });
            const fixtures = try staging.openDir(io, try std.fs.path.join(arena, &.{ source, subdir }), .{});
            fixtures.close(io);
            try staging.rename(source, cache, hash, io);
        },
        else => return err,
    }
    const fixtures = try cache.openDir(io, try std.fs.path.join(arena, &.{ hash, subdir }), .{});
    fixtures.close(io);
}

fn fatal(comptime format: []const u8, args: anytype) noreturn {
    std.process.fatal(format, args);
}
