const std = @import("std");
const block_stf = @import("../block_stf.zig");
const fixture_common = @import("../fixture.zig");
const runner = @import("../runner.zig");

pub const about = "Run regular EEST blockchain_tests through BlockSTF";

const default_jobs = 4;
const max_jobs = 16;
const Fixtures = runner.Runner(block_stf);

pub fn run(init: std.process.Init, args: *std.process.Args.Iterator) !void {
    const allocator = init.gpa;
    const arena = init.arena.allocator();

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
            jobs = try runner.parseJobs(value, max_jobs);
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
        const summary = try Fixtures.run(init.io, allocator, path, options, jobs);
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

test "limited and verbose BlockSTF runs stay sequential" {
    try std.testing.expect(!requiresSequential(.{}));
    try std.testing.expect(requiresSequential(.{ .limit = 1 }));
    try std.testing.expect(requiresSequential(.{ .verbose = true }));
    try std.testing.expect(requiresSequential(.{ .bal_differential = true }));
}
