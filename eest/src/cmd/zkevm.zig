const std = @import("std");
const stateless = @import("../stateless.zig");
const fixture_common = @import("../fixture.zig");
const runner = @import("../runner.zig");

pub const about = "Run EEST zkEVM stateless SSZ fixtures";

const default_jobs = 2;
const max_jobs = 16;
const Fixtures = runner.Runner(stateless);

pub fn run(init: std.process.Init, args: *std.process.Args.Iterator) !void {
    const allocator = init.gpa;
    const arena = init.arena.allocator();

    var options = stateless.Options{};
    var paths: std.ArrayList([]const u8) = .empty;
    defer paths.deinit(allocator);
    var jobs: usize = default_jobs;
    var jobs_explicit = false;
    var report = stateless.Report.init(allocator);
    defer report.deinit();
    var report_path: ?[]const u8 = null;

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
        } else if (std.mem.eql(u8, arg, "--trace-mismatch")) {
            options.trace_mismatch = true;
        } else if (std.mem.eql(u8, arg, "--classify-failures")) {
            options.classify_failures = true;
        } else if (std.mem.eql(u8, arg, "--report")) {
            const value = args.next() orelse return error.MissingReportPath;
            report_path = try arena.dupe(u8, value);
            options.report = &report;
        } else {
            try paths.append(allocator, try arena.dupe(u8, arg));
        }
    }

    if (requiresSequential(options) and jobs > 1) {
        if (jobs_explicit) return error.ParallelOptionsUnsupported;
        jobs = 1;
    }

    if (paths.items.len == 0) {
        try paths.append(allocator, try fixture_common.lockedZkevmFixturePath(init.io, arena));
    }

    var total = stateless.Summary{};
    for (paths.items) |path| {
        const summary = try Fixtures.run(init.io, allocator, path, options, jobs);
        total.add(summary);
        printSummary(path, summary);
    }
    if (paths.items.len > 1) printSummary("total", total);
    if (report_path) |path| try report.write(init.io, path);
    if (total.failed > 0) std.process.exit(1);
}

fn requiresSequential(options: stateless.Options) bool {
    return options.limit > 0 or options.verbose or options.trace_mismatch or
        options.classify_failures or options.report != null;
}

fn printSummary(path: []const u8, summary: stateless.Summary) void {
    std.debug.print(
        "{s}: files={} fixtures={} passed={} failed={} skipped={}\n",
        .{ path, summary.files, summary.fixtures, summary.passed, summary.failed, summary.skipped },
    );
    inline for (std.meta.fields(stateless.FailReason), 0..) |field, i| {
        const count = summary.fail_reasons[i];
        if (count != 0) std.debug.print("  {s}: {}\n", .{ field.name, count });
    }
}

fn printUsage() void {
    std.debug.print(
        \\usage: zig build zkevm -- [--jobs N] [--test NAME] [--limit N] [--verbose] [--trace-mismatch] [--classify-failures] [--report PATH] [path ...]
        \\
        \\Runs EEST zkEVM blockchain fixtures by comparing statelessInputBytes
        \\against the raw statelessOutputBytes public values.
        \\Uses {d} workers by default (maximum {d}). --limit and diagnostic
        \\output options require --jobs 1.
        \\Use --trace-mismatch with --verbose to print selected gas/state trace events.
        \\Use --classify-failures to print one tab-separated record per failure.
        \\Use --report to write one deterministic JSON record per runnable block.
        \\
    , .{ default_jobs, max_jobs });
}

test "limited and diagnostic zkEVM runs stay sequential" {
    try std.testing.expect(!requiresSequential(.{}));
    try std.testing.expect(requiresSequential(.{ .limit = 1 }));
    try std.testing.expect(requiresSequential(.{ .verbose = true }));
    try std.testing.expect(requiresSequential(.{ .trace_mismatch = true }));
    try std.testing.expect(requiresSequential(.{ .classify_failures = true }));
    var report = stateless.Report.init(std.testing.allocator);
    defer report.deinit();
    try std.testing.expect(requiresSequential(.{ .report = &report }));
}
