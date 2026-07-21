const std = @import("std");
const block_stf = @import("block_stf.zig");
const fixture_common = @import("fixture.zig");
const fixture_pool = @import("fixture_pool.zig");

const default_jobs = 4;
const max_jobs = 16;

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const arena = init.arena.allocator();

    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, allocator);
    defer args.deinit();
    _ = args.next();

    var options = block_stf.Options{};
    var paths: std.ArrayList([]const u8) = .empty;
    defer paths.deinit(allocator);
    var jobs: usize = default_jobs;
    var jobs_explicit = false;

    while (args.next()) |arg_z| {
        const arg = arg_z[0..arg_z.len];
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            printUsage();
            return;
        } else if (std.mem.eql(u8, arg, "--test")) {
            const value = args.next() orelse return error.MissingTestFilter;
            options.test_filter = try arena.dupe(u8, value);
        } else if (std.mem.eql(u8, arg, "--limit")) {
            const value = args.next() orelse return error.MissingLimit;
            options.limit = try std.fmt.parseInt(usize, value, 10);
        } else if (std.mem.eql(u8, arg, "--jobs")) {
            const value = args.next() orelse return error.MissingJobs;
            jobs = try parseJobs(value);
            jobs_explicit = true;
        } else if (std.mem.eql(u8, arg, "--verbose")) {
            options.verbose = true;
        } else if (std.mem.eql(u8, arg, "--bal-differential")) {
            options.bal_differential = true;
        } else {
            try paths.append(allocator, try arena.dupe(u8, arg));
        }
    }

    if (requiresSequential(options) and jobs > 1) {
        if (jobs_explicit) return error.ParallelOptionsUnsupported;
        jobs = 1;
    }

    if (paths.items.len == 0) {
        try paths.append(allocator, try fixture_common.lockedFixturePath(init.io, arena, "blockchain_tests_sync"));
    }

    var total = block_stf.Summary{};
    for (paths.items) |path| {
        const summary = if (jobs == 1)
            try runPath(init.io, allocator, path, options)
        else
            try runPathConcurrent(init.io, allocator, path, options, jobs);
        total.add(summary);
        printSummary(path, summary);
    }
    if (paths.items.len > 1) printSummary("total", total);
    if (total.failed > 0) std.process.exit(1);
    if (total.passed == 0) {
        std.debug.print("no regular BlockSTF fixtures were validated\n", .{});
        std.process.exit(1);
    }
}

const FileError = struct {
    path: []u8,
    err: anyerror,
};

const Worker = struct {
    allocator: std.mem.Allocator,
    options: block_stf.Options,
    summary: block_stf.Summary = .{},
    file_errors: std.ArrayList(FileError) = .empty,
    allocation_error: ?anyerror = null,

    fn run(self: *Worker, io: std.Io, queue: *std.Io.Queue([]u8)) std.Io.Cancelable!void {
        while (true) {
            const path = queue.getOne(io) catch |err| switch (err) {
                error.Closed => return,
                error.Canceled => return error.Canceled,
            };
            const summary = block_stf.runFile(io, self.allocator, path, self.options) catch |err| {
                self.file_errors.append(self.allocator, .{ .path = path, .err = err }) catch |alloc_err| {
                    if (self.allocation_error == null) self.allocation_error = alloc_err;
                    self.allocator.free(path);
                };
                continue;
            };
            self.summary.add(summary);
            self.allocator.free(path);
        }
    }
};

fn runPath(io: std.Io, allocator: std.mem.Allocator, path: []const u8, options: block_stf.Options) !block_stf.Summary {
    var dir = std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch |err| switch (err) {
        error.NotDir => return block_stf.runFile(io, allocator, path, options),
        else => return err,
    };
    defer dir.close(io);

    var total = block_stf.Summary{};
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        const child = try std.fs.path.join(allocator, &.{ path, entry.name });
        defer allocator.free(child);
        switch (entry.kind) {
            .directory => total.add(try runPath(io, allocator, child, options)),
            .file => if (std.mem.endsWith(u8, entry.name, ".json")) {
                total.add(try block_stf.runFile(io, allocator, child, options));
            },
            else => {},
        }
        if (options.limit > 0 and total.fixtures >= options.limit) break;
    }
    return total;
}

fn runPathConcurrent(
    io: std.Io,
    allocator: std.mem.Allocator,
    path: []const u8,
    options: block_stf.Options,
    jobs: usize,
) !block_stf.Summary {
    var dir = std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch |err| switch (err) {
        error.NotDir => return block_stf.runFile(io, allocator, path, options),
        else => return err,
    };
    dir.close(io);

    const workers = try allocator.alloc(Worker, jobs);
    defer {
        for (workers) |*worker| {
            for (worker.file_errors.items) |file_error| allocator.free(file_error.path);
            worker.file_errors.deinit(allocator);
        }
        allocator.free(workers);
    }
    for (workers) |*worker| worker.* = .{
        .allocator = allocator,
        .options = options,
    };
    try fixture_pool.runWorkers(io, allocator, path, workers, .{ .suffix = ".json" }, Worker.run);

    var total = block_stf.Summary{};
    var file_errors: std.ArrayList(FileError) = .empty;
    defer file_errors.deinit(allocator);
    var allocation_error: ?anyerror = null;
    for (workers) |*worker| {
        total.add(worker.summary);
        try file_errors.appendSlice(allocator, worker.file_errors.items);
        if (allocation_error == null) allocation_error = worker.allocation_error;
    }
    std.sort.heap(FileError, file_errors.items, {}, fileErrorLessThan);
    for (file_errors.items) |file_error| {
        std.debug.print("ERROR {s}: {s}\n", .{ file_error.path, @errorName(file_error.err) });
    }
    if (allocation_error) |err| return err;
    if (file_errors.items.len > 0) return file_errors.items[0].err;
    return total;
}

fn fileErrorLessThan(_: void, lhs: FileError, rhs: FileError) bool {
    return std.mem.order(u8, lhs.path, rhs.path) == .lt;
}

fn parseJobs(value: []const u8) !usize {
    const jobs = try std.fmt.parseInt(usize, value, 10);
    if (jobs == 0 or jobs > max_jobs) return error.InvalidJobs;
    return jobs;
}

fn requiresSequential(options: block_stf.Options) bool {
    return options.limit > 0 or options.verbose or options.bal_differential;
}

fn printSummary(path: []const u8, summary: block_stf.Summary) void {
    std.debug.print(
        "{s}: files={} fixtures={} passed={} failed={} skipped={} unchecked={}\n",
        .{ path, summary.files, summary.fixtures, summary.passed, summary.failed, summary.skipped, summary.unchecked },
    );
    inline for (std.meta.fields(block_stf.SkipReason), 0..) |field, i| {
        const count = summary.skip_reasons[i];
        if (count != 0) std.debug.print("  skip.{s}: {}\n", .{ field.name, count });
    }
    inline for (std.meta.fields(block_stf.FailReason), 0..) |field, i| {
        const count = summary.fail_reasons[i];
        if (count != 0) std.debug.print("  fail.{s}: {}\n", .{ field.name, count });
    }
    inline for (std.meta.fields(block_stf.UncheckedReason), 0..) |field, i| {
        const count = summary.unchecked_reasons[i];
        if (count != 0) std.debug.print("  unchecked.{s}: {}\n", .{ field.name, count });
    }
}

fn printUsage() void {
    std.debug.print(
        \\usage: zig build eest-block-stf -- [--jobs N] [--test NAME] [--limit N] [--verbose] [--bal-differential] [path ...]
        \\
        \\Runs regular EEST blockchain_tests_sync fixtures through eth.BlockSTF.
        \\The adapter seeds pre/genesis state into MemoryStore and executes
        \\Engine API payloads in order. Witness-backed zkEVM fixtures belong to
        \\eest-stateless-block-stf.
        \\Uses {d} workers by default (maximum {d}). --limit, --verbose, and
        \\--bal-differential require --jobs 1.
        \\
    , .{ default_jobs, max_jobs });
}

test "jobs parser enforces the BlockSTF memory bound" {
    try std.testing.expectEqual(@as(usize, 1), try parseJobs("1"));
    try std.testing.expectEqual(@as(usize, max_jobs), try parseJobs("16"));
    try std.testing.expectError(error.InvalidJobs, parseJobs("0"));
    try std.testing.expectError(error.InvalidJobs, parseJobs("17"));
}

test "limited and verbose BlockSTF runs stay sequential" {
    try std.testing.expect(!requiresSequential(.{}));
    try std.testing.expect(requiresSequential(.{ .limit = 1 }));
    try std.testing.expect(requiresSequential(.{ .verbose = true }));
    try std.testing.expect(requiresSequential(.{ .bal_differential = true }));
}
