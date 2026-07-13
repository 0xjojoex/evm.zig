const std = @import("std");
const conformance = @import("ssz_conformance.zig");
const lock = @import("lock.zig");

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const arena = init.arena.allocator();

    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, allocator);
    defer args.deinit();
    _ = args.next();

    var paths: std.ArrayList([]const u8) = .empty;
    defer paths.deinit(allocator);
    while (args.next()) |arg_z| {
        const arg = arg_z[0..arg_z.len];
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            printUsage();
            return;
        }
        try paths.append(allocator, try arena.dupe(u8, arg));
    }

    if (paths.items.len == 0) {
        try paths.append(allocator, try defaultFixturePath(init.io, arena, init.environ_map.get("EVMZ_EEST_ROOT")));
    }

    var total = Summary{};
    for (paths.items) |path| {
        const summary = try runPath(init.io, allocator, path);
        total.add(summary);
        printSummary(path, summary);
    }
    if (paths.items.len > 1) printSummary("total", total);
    if (!successful(total)) {
        std.debug.print("conformance incomplete: require at least one case and zero failures or skips\n", .{});
        std.process.exit(1);
    }
}

const Summary = struct {
    cases: usize = 0,
    passed: usize = 0,
    failed: usize = 0,
    skipped: usize = 0,

    fn add(self: *Summary, other: Summary) void {
        self.cases += other.cases;
        self.passed += other.passed;
        self.failed += other.failed;
        self.skipped += other.skipped;
    }
};

fn successful(summary: Summary) bool {
    return summary.cases > 0 and summary.failed == 0 and summary.skipped == 0;
}

fn runPath(io: std.Io, allocator: std.mem.Allocator, path: []const u8) !Summary {
    var dir = std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch |err| switch (err) {
        error.NotDir => return runFixture(io, allocator, path),
        else => return err,
    };
    defer dir.close(io);

    var total = Summary{};
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        const child = try std.fs.path.join(allocator, &.{ path, entry.name });
        defer allocator.free(child);
        switch (entry.kind) {
            .directory => total.add(try runPath(io, allocator, child)),
            .file => {
                if (std.mem.eql(u8, entry.name, "serialized.ssz_snappy")) {
                    total.add(try runFixture(io, allocator, child));
                }
            },
            else => {},
        }
    }
    return total;
}

fn runFixture(io: std.Io, allocator: std.mem.Allocator, path: []const u8) !Summary {
    var summary = Summary{ .cases = 1 };
    const result = conformance.runFile(io, allocator, path) catch |err| {
        summary.failed = 1;
        std.debug.print("FAIL {s}: {s}\n", .{ path, @errorName(err) });
        return summary;
    };
    switch (result) {
        .passed => summary.passed = 1,
        .skipped => summary.skipped = 1,
        .failed => |reason| {
            summary.failed = 1;
            std.debug.print("FAIL {s}: {s}\n", .{ path, @tagName(reason) });
        },
    }
    return summary;
}

fn defaultFixturePath(io: std.Io, allocator: std.mem.Allocator, shared_root: ?[]const u8) ![]u8 {
    var value = lock.readValue(io, allocator, "consensus_dest") catch |err| switch (err) {
        error.MissingEestLockKey => return error.MissingConsensusLockKey,
        else => return err,
    };
    defer value.deinit(allocator);
    const relative = value.bytes;
    if (shared_root) |root| {
        const suffix = if (std.mem.startsWith(u8, relative, ".eest/")) relative[6..] else relative;
        return std.fs.path.join(allocator, &.{ root, suffix });
    }
    if (try mainWorktreePath(io, allocator)) |worktree| {
        return std.fs.path.join(allocator, &.{ worktree, relative });
    }
    return if (std.fs.path.isAbsolute(relative))
        allocator.dupe(u8, relative)
    else if (value.relative_prefix.len == 0)
        allocator.dupe(u8, relative)
    else
        std.fs.path.join(allocator, &.{ value.relative_prefix, relative });
}

fn mainWorktreePath(io: std.Io, allocator: std.mem.Allocator) !?[]u8 {
    const result = std.process.run(allocator, io, .{
        .argv = &.{ "git", "worktree", "list", "--porcelain" },
        .stdout_limit = .limited(64 * 1024),
        .stderr_limit = .limited(16 * 1024),
    }) catch return null;
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    switch (result.term) {
        .exited => |code| if (code != 0) return null,
        else => return null,
    }
    const path = parseMainWorktree(result.stdout) orelse return null;
    return @as(?[]u8, try allocator.dupe(u8, path));
}

fn parseMainWorktree(output: []const u8) ?[]const u8 {
    var current: ?[]const u8 = null;
    var lines = std.mem.splitScalar(u8, output, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "worktree ")) {
            current = line["worktree ".len..];
        } else if (std.mem.eql(u8, line, "branch refs/heads/main")) {
            return current;
        }
    }
    return null;
}

fn printUsage() void {
    std.debug.print(
        \\usage: zig build ssz-conformance -- [consensus_ssz_dir_or_serialized_file...]
        \\
        \\Runs consensus-spec General, Mainnet, and Minimal SSZ fixtures.
        \\EVMZ_EEST_ROOT can point at a shared .eest directory. With no path,
        \\the runner uses the complete pinned consensus fixture destination.
        \\
    , .{});
}

fn printSummary(label: []const u8, summary: Summary) void {
    std.debug.print(
        "{s}: cases={d} passed={d} failed={d} skipped={d}\n",
        .{ label, summary.cases, summary.passed, summary.failed, summary.skipped },
    );
}

test "conformance success requires exercised cases without skips" {
    try std.testing.expect(successful(.{ .cases = 2, .passed = 2 }));
    try std.testing.expect(!successful(.{}));
    try std.testing.expect(!successful(.{ .cases = 1, .skipped = 1 }));
    try std.testing.expect(!successful(.{ .cases = 1, .failed = 1 }));
}

test "main worktree parser selects the main branch path" {
    const output =
        \\worktree /tmp/feature
        \\branch refs/heads/feature
        \\
        \\worktree /tmp/main repo
        \\branch refs/heads/main
    ;
    try std.testing.expectEqualStrings("/tmp/main repo", parseMainWorktree(output).?);
}
