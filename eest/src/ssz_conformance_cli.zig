const std = @import("std");
const conformance = @import("ssz_conformance.zig");
const fixture_pool = @import("fixture_pool.zig");
const lock = @import("lock.zig");

const default_jobs = 4;
const max_jobs = 64;

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const arena = init.arena.allocator();

    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, allocator);
    defer args.deinit();
    _ = args.next();

    var paths: std.ArrayList([]const u8) = .empty;
    defer paths.deinit(allocator);
    var jobs: usize = default_jobs;
    while (args.next()) |arg_z| {
        const arg = arg_z[0..arg_z.len];
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            printUsage();
            return;
        } else if (std.mem.eql(u8, arg, "--jobs")) {
            const value = args.next() orelse return error.MissingJobs;
            jobs = try parseJobs(value);
        } else try paths.append(allocator, try arena.dupe(u8, arg));
    }

    if (paths.items.len == 0) {
        try paths.append(allocator, try defaultFixturePath(init.io, arena, init.environ_map.get("EVMZ_EEST_ROOT")));
    }

    var total = Summary{};
    for (paths.items) |path| {
        const summary = if (jobs == 1)
            try runPath(init.io, allocator, path)
        else
            try runPathConcurrent(init.io, allocator, path, jobs);
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

const Failure = struct {
    path: []u8,
    reason: []const u8,
};

const FixtureReport = struct {
    summary: Summary,
    failure_reason: ?[]const u8 = null,
};

const Worker = struct {
    allocator: std.mem.Allocator,
    summary: Summary = .{},
    failures: std.ArrayList(Failure) = .empty,
    allocation_error: ?anyerror = null,

    fn run(self: *Worker, io: std.Io, queue: *std.Io.Queue([]u8)) std.Io.Cancelable!void {
        while (true) {
            const path = queue.getOne(io) catch |err| switch (err) {
                error.Closed => return,
                error.Canceled => return error.Canceled,
            };
            const report = evaluateFixture(io, self.allocator, path);
            self.summary.add(report.summary);
            if (report.failure_reason) |reason| {
                self.failures.append(self.allocator, .{ .path = path, .reason = reason }) catch |err| {
                    if (self.allocation_error == null) self.allocation_error = err;
                    self.allocator.free(path);
                };
            } else {
                self.allocator.free(path);
            }
        }
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

fn runPathConcurrent(
    io: std.Io,
    allocator: std.mem.Allocator,
    path: []const u8,
    jobs: usize,
) !Summary {
    var dir = std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch |err| switch (err) {
        error.NotDir => return runFixture(io, allocator, path),
        else => return err,
    };
    dir.close(io);

    const workers = try allocator.alloc(Worker, jobs);
    defer {
        for (workers) |*worker| {
            for (worker.failures.items) |failure| allocator.free(failure.path);
            worker.failures.deinit(allocator);
        }
        allocator.free(workers);
    }
    for (workers) |*worker| worker.* = .{ .allocator = allocator };
    try fixture_pool.runWorkers(
        io,
        allocator,
        path,
        workers,
        .{ .basename = "serialized.ssz_snappy" },
        Worker.run,
    );

    var total = Summary{};
    var failures: std.ArrayList(Failure) = .empty;
    defer failures.deinit(allocator);
    var allocation_error: ?anyerror = null;
    for (workers) |*worker| {
        total.add(worker.summary);
        try failures.appendSlice(allocator, worker.failures.items);
        if (allocation_error == null) allocation_error = worker.allocation_error;
    }
    std.sort.heap(Failure, failures.items, {}, failureLessThan);
    for (failures.items) |failure| {
        std.debug.print("FAIL {s}: {s}\n", .{ failure.path, failure.reason });
    }
    if (allocation_error) |err| return err;
    return total;
}

fn runFixture(io: std.Io, allocator: std.mem.Allocator, path: []const u8) !Summary {
    const report = evaluateFixture(io, allocator, path);
    if (report.failure_reason) |reason| std.debug.print("FAIL {s}: {s}\n", .{ path, reason });
    return report.summary;
}

fn evaluateFixture(io: std.Io, allocator: std.mem.Allocator, path: []const u8) FixtureReport {
    var summary = Summary{ .cases = 1 };
    const result = conformance.runFile(io, allocator, path) catch |err| {
        summary.failed = 1;
        return .{ .summary = summary, .failure_reason = @errorName(err) };
    };
    switch (result) {
        .passed => summary.passed = 1,
        .skipped => summary.skipped = 1,
        .failed => |reason| {
            summary.failed = 1;
            return .{ .summary = summary, .failure_reason = @tagName(reason) };
        },
    }
    return .{ .summary = summary };
}

fn failureLessThan(_: void, lhs: Failure, rhs: Failure) bool {
    return std.mem.order(u8, lhs.path, rhs.path) == .lt;
}

fn parseJobs(value: []const u8) !usize {
    const jobs = try std.fmt.parseInt(usize, value, 10);
    if (jobs == 0 or jobs > max_jobs) return error.InvalidJobs;
    return jobs;
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
        \\usage: zig build ssz-conformance -- [--jobs N] [consensus_ssz_dir_or_serialized_file...]
        \\
        \\Runs consensus-spec General, Mainnet, and Minimal SSZ fixtures.
        \\Uses {d} workers by default; --jobs 1 runs sequentially (maximum {d}).
        \\EVMZ_EEST_ROOT can point at a shared .eest directory. With no path,
        \\the runner uses the complete pinned consensus fixture destination.
        \\
    , .{ default_jobs, max_jobs });
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

test "jobs parser enforces the bounded worker count" {
    try std.testing.expectEqual(@as(usize, 1), try parseJobs("1"));
    try std.testing.expectEqual(@as(usize, max_jobs), try parseJobs("64"));
    try std.testing.expectError(error.InvalidJobs, parseJobs("0"));
    try std.testing.expectError(error.InvalidJobs, parseJobs("65"));
}
