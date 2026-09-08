const ConsensusFixtures = @This();

const std = @import("std");
const Io = std.Io;
const Step = std.Build.Step;
const pins = @import("../consensus.zon");
const presets = .{ "general", "mainnet", "minimal" };

step: Step,
roots: [presets.len]std.Build.GeneratedFile,

pub fn create(b: *std.Build) [presets.len]std.Build.LazyPath {
    const self = b.allocator.create(ConsensusFixtures) catch @panic("OOM");
    self.* = .{
        .step = Step.init(.{
            .id = .custom,
            .name = "prepare shared consensus fixtures",
            .owner = b,
            .makeFn = make,
        }),
        .roots = undefined,
    };
    var paths: [presets.len]std.Build.LazyPath = undefined;
    for (&self.roots, &paths) |*root, *path| {
        root.* = .{ .step = &self.step };
        path.* = .{ .generated = .{ .file = root } };
    }
    return paths;
}

fn make(step: *Step, options: Step.MakeOptions) !void {
    const self: *ConsensusFixtures = @fieldParentPtr("step", step);
    const b = step.owner;
    const io = b.graph.io;
    const xdg_cache = b.graph.environ_map.get("XDG_CACHE_HOME") orelse "";
    const base = if (xdg_cache.len != 0) xdg_cache else base: {
        const home = b.graph.environ_map.get("HOME") orelse
            return step.fail("shared consensus fixtures require HOME or XDG_CACHE_HOME", .{});
        break :base b.pathJoin(&.{ home, ".cache" });
    };
    const cache_path = b.pathResolve(&.{ b.graph.cache.cwd, base, "evmz", "consensus" });
    var cache = try Io.Dir.cwd().createDirPathOpen(io, cache_path, .{});
    defer cache.close(io);
    const lock = try cache.createFile(io, ".lock", .{ .truncate = false, .lock = .exclusive });
    defer lock.close(io);

    step.result_cached = true;
    inline for (presets, 0..) |preset, i| {
        const pin = @field(pins, preset);
        const subdir = if (std.mem.eql(u8, preset, "general")) "general/phase0/ssz_generic" else preset;
        try self.prepare(cache, pin.url, pin.hash, subdir, options);
        self.roots[i].path = b.pathJoin(&.{ cache_path, pin.hash, subdir });
    }
}

fn prepare(
    self: *ConsensusFixtures,
    cache: Io.Dir,
    url: []const u8,
    hash: []const u8,
    subdir: []const u8,
    options: Step.MakeOptions,
) !void {
    const step = &self.step;
    const b = step.owner;
    const io = b.graph.io;
    if (cache.openDir(io, hash, .{ .follow_symlinks = false })) |package| {
        package.close(io);
    } else |err| switch (err) {
        error.FileNotFound => {
            step.result_cached = false;
            var random: u64 = undefined;
            io.random(std.mem.asBytes(&random));
            const temporary = b.fmt(".prepare-{x}", .{random});
            // Create exclusively on the same filesystem as the final package.
            try cache.createDir(io, temporary, .default_dir);
            defer cache.deleteTree(io, temporary) catch {};
            var staging = try cache.openDir(io, temporary, .{});
            defer staging.close(io);
            try staging.writeFile(io, .{ .sub_path = "build.zig", .data = "" });
            var manifest: Io.Writer.Allocating = .init(b.allocator);
            defer manifest.deinit();
            try std.zon.stringify.serialize(.{
                .name = .fixture_cache,
                .version = "0.0.0",
                .fingerprint = @as(u64, 0x58a8d62106270de5),
                .paths = .{"build.zig"},
                .dependencies = .{ .fixture = .{ .url = url, .hash = hash } },
            }, .{}, &manifest.writer);
            try staging.writeFile(io, .{ .sub_path = "build.zig.zon", .data = manifest.written() });

            const argv = &.{
                b.graph.zig_exe,
                "build",
                "--fetch=all",
                "--global-cache-dir",
                b.pathResolve(&.{ b.graph.cache.cwd, b.graph.global_cache_root.path.? }),
            };
            const cwd: std.process.Child.Cwd = .{
                .path = try staging.realPathFileAlloc(io, ".", b.allocator),
            };
            step.result_failed_command = try Step.allocPrintCmd(b.allocator, cwd, null, argv);
            try Step.handleVerbose(b, cwd, argv);
            const result = try std.process.run(b.allocator, io, .{
                .argv = argv,
                .cwd = cwd,
                .environ_map = &b.graph.environ_map,
                .progress_node = options.progress_node,
            });
            if (result.stderr.len != 0) try step.addError("{s}", .{result.stderr});
            try step.handleChildProcessTerm(result.term);

            const source = b.pathJoin(&.{ "zig-pkg", hash });
            const fixtures = try staging.openDir(io, b.pathJoin(&.{ source, subdir }), .{});
            fixtures.close(io);
            try staging.rename(source, cache, hash, io);
        },
        else => return err,
    }
    const fixtures = try cache.openDir(io, b.pathJoin(&.{ hash, subdir }), .{});
    fixtures.close(io);
}
