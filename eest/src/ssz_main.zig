//! The `evmz-ssz-conformance` CLI. Separate from `main.zig` because this
//! runner builds without evmz, and because a consensus fixture reports a
//! `failed` case rather than an error, so it cannot reuse the guest runner.

const std = @import("std");
const conformance = @import("ssz_conformance.zig");
const fixture_pool = @import("fixture_pool.zig");

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
            jobs = try fixture_pool.parseJobs(value, max_jobs);
        } else try paths.append(allocator, try arena.dupe(u8, arg));
    }

    if (paths.items.len == 0) return error.MissingFixturePath;

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
        &.{path},
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

fn printUsage() void {
    std.debug.print(
        \\usage: zig build ssz-conformance -- [--jobs N] [consensus_ssz_dir_or_serialized_file...]
        \\
        \\Runs consensus-spec General, Mainnet, and Minimal SSZ fixtures.
        \\Uses {d} workers by default; --jobs 1 runs sequentially (maximum {d}).
        \\zig build ssz-conformance supplies the pinned fixture directories.
        \\The installed executable requires at least one fixture path.
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
