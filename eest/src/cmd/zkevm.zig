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
    var report_only = false;

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
        } else if (std.mem.eql(u8, arg, "--report-only")) {
            report_only = true;
        } else if (std.mem.eql(u8, arg, "--oracle-differential")) {
            options.oracle_differential = true;
        } else if (std.mem.eql(u8, arg, "--report")) {
            const value = args.next() orelse return error.MissingReportPath;
            report_path = try arena.dupe(u8, value);
            options.report = &report;
        } else if (std.mem.eql(u8, arg, "--executor")) {
            const value = args.next() orelse return error.MissingExecutor;
            options.executor.target = stateless.Target.parse(value) orelse return error.InvalidExecutor;
        } else if (std.mem.eql(u8, arg, "--output-folder")) {
            const value = args.next() orelse return error.MissingOutputFolder;
            options.output_folder = try arena.dupe(u8, value);
        } else if (std.mem.eql(u8, arg, "--zisk-host")) {
            const value = args.next() orelse return error.MissingZiskHostPath;
            options.executor.zisk_host_path = try arena.dupe(u8, value);
        } else if (std.mem.eql(u8, arg, "--zisk-elf")) {
            const value = args.next() orelse return error.MissingZiskElfPath;
            options.executor.zisk_elf_path = try arena.dupe(u8, value);
        } else if (std.mem.eql(u8, arg, "--sp1-host")) {
            const value = args.next() orelse return error.MissingSp1HostPath;
            options.executor.sp1_host_path = try arena.dupe(u8, value);
        } else if (std.mem.eql(u8, arg, "--sp1-elf")) {
            const value = args.next() orelse return error.MissingSp1ElfPath;
            options.executor.sp1_elf_path = try arena.dupe(u8, value);
        } else if (std.mem.eql(u8, arg, "--sp1-work-dir")) {
            const value = args.next() orelse return error.MissingSp1WorkDir;
            options.executor.sp1_work_dir = try arena.dupe(u8, value);
        } else if (isOption(arg)) {
            return error.UnknownOption;
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

    // One session over every root: a guest context owns a host child, and
    // rebuilding it per root would repeat the ELF-to-ROM conversion per batch.
    options.source_roots = paths.items;
    const total = try Fixtures.run(init.io, allocator, paths.items, options, jobs);
    printSummary(if (paths.items.len == 1) paths.items[0] else "total", total);
    if (report_path) |path| try report.write(init.io, path);
    // `--report-only` withholds the exit code for accumulated fixture failures
    // so a downstream comparison still gets its rows. Configuration, I/O and
    // host-startup problems surface as errors above and still fail hard, and an
    // empty run is always a failure.
    if ((!report_only and total.failed > 0) or total.fixtures == 0) std.process.exit(1);
}

fn isOption(arg: []const u8) bool {
    return std.mem.startsWith(u8, arg, "-");
}

fn requiresSequential(options: stateless.Options) bool {
    return options.limit > 0 or options.verbose or options.trace_mismatch or
        options.classify_failures or options.report != null;
}

fn printSummary(path: []const u8, summary: stateless.Summary) void {
    std.debug.print(
        "{s}: files={} fixtures={} passed={} failed={} skipped={} oracle_compared={}\n",
        .{ path, summary.files, summary.fixtures, summary.passed, summary.failed, summary.skipped, summary.oracle_compared },
    );
    inline for (std.meta.fields(stateless.FailReason), 0..) |field, i| {
        const count = summary.fail_reasons[i];
        if (count != 0) std.debug.print("  {s}: {}\n", .{ field.name, count });
    }
}

fn printUsage() void {
    std.debug.print(
        \\usage: zig build zkevm -- [--executor native|zisk|sp1] [--jobs N] [--test NAME] [--limit N] [--verbose] [--trace-mismatch] [--classify-failures] [--oracle-differential] [--report PATH] [--output-folder PATH] [--zisk-host PATH] [--zisk-elf PATH] [--sp1-host PATH] [--sp1-elf PATH] [--sp1-work-dir PATH] [path ...]
        \\
        \\Runs EEST zkEVM blockchain fixtures by comparing statelessInputBytes
        \\against the raw statelessOutputBytes public values.
        \\Uses {d} workers by default (maximum {d}). --limit and diagnostic
        \\output options require --jobs 1.
        \\Use --trace-mismatch with --verbose to print selected gas/state trace events.
        \\Use --classify-failures to print one tab-separated record per failure.
        \\Use --oracle-differential to require dense/tracked consensus-result parity
        \\for blocks without expectException. Typed mutations own rejection-status parity.
        \\Use --report to write one deterministic JSON record per runnable block.
        \\Use --report-only to withhold the fixture-failure exit code so a
        \\downstream comparison still receives its rows; an empty run still fails.
        \\Use --executor to run each block on a zkVM guest instead of natively.
        \\Guest framing is stripped before comparison, so every executor is judged
        \\against the same statelessOutputBytes. Each worker owns one guest host
        \\child, which converts the ELF to a ZisK ROM once at startup.
        \\Use --output-folder to also write one ERE BenchmarkRun row per block.
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

test "unknown options are not fixture paths" {
    try std.testing.expect(isOption("--executorr"));
    try std.testing.expect(isOption("-unknown"));
    try std.testing.expect(!isOption("./-fixture.json"));
    try std.testing.expect(!isOption("fixtures/blockchain_tests"));
}
