const std = @import("std");
const stateless = @import("../stateless.zig");
const guest_evidence = @import("../guest_evidence.zig");
const fixture_pool = @import("../fixture_pool.zig");
const guest_runner = @import("../guest_fixture_runner.zig");

pub const about = "Run EEST zkEVM stateless SSZ fixtures";

const default_jobs = 2;
const max_jobs = 16;
const Fixtures = guest_runner.Runner(stateless);

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
    var evidence_dir: ?[]const u8 = null;
    var corpus_manifest: ?[]const u8 = null;
    var known_failures: ?[]const u8 = null;
    var source_ref: ?[]const u8 = null;
    var stateless_schema: ?[]const u8 = null;
    var zig_version: ?[]const u8 = null;
    var backend_version: ?[]const u8 = null;
    var backend_commit: ?[]const u8 = null;
    var backend_toolchain: ?[]const u8 = null;
    var strict_evidence = false;

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
            jobs = try fixture_pool.parseJobs(value, max_jobs);
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
        } else if (std.mem.eql(u8, arg, "--evidence-dir")) {
            const value = args.next() orelse return error.MissingEvidenceDir;
            evidence_dir = try arena.dupe(u8, value);
        } else if (std.mem.eql(u8, arg, "--corpus-manifest")) {
            const value = args.next() orelse return error.MissingCorpusManifest;
            corpus_manifest = try arena.dupe(u8, value);
        } else if (std.mem.eql(u8, arg, "--known-failures")) {
            const value = args.next() orelse return error.MissingKnownFailures;
            known_failures = try arena.dupe(u8, value);
        } else if (std.mem.eql(u8, arg, "--source-ref")) {
            const value = args.next() orelse return error.MissingSourceRef;
            source_ref = try arena.dupe(u8, value);
        } else if (std.mem.eql(u8, arg, "--stateless-schema")) {
            const value = args.next() orelse return error.MissingStatelessSchema;
            stateless_schema = try arena.dupe(u8, value);
        } else if (std.mem.eql(u8, arg, "--zig-version")) {
            const value = args.next() orelse return error.MissingZigVersion;
            zig_version = try arena.dupe(u8, value);
        } else if (std.mem.eql(u8, arg, "--backend-version")) {
            const value = args.next() orelse return error.MissingBackendVersion;
            backend_version = try arena.dupe(u8, value);
        } else if (std.mem.eql(u8, arg, "--backend-commit")) {
            const value = args.next() orelse return error.MissingBackendCommit;
            backend_commit = try arena.dupe(u8, value);
        } else if (std.mem.eql(u8, arg, "--backend-toolchain")) {
            const value = args.next() orelse return error.MissingBackendToolchain;
            backend_toolchain = try arena.dupe(u8, value);
        } else if (std.mem.eql(u8, arg, "--strict-evidence")) {
            strict_evidence = true;
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
        } else if (std.mem.eql(u8, arg, "--openvm-host")) {
            const value = args.next() orelse return error.MissingOpenVmHostPath;
            options.executor.openvm_host_path = try arena.dupe(u8, value);
        } else if (std.mem.eql(u8, arg, "--openvm-config")) {
            const value = args.next() orelse return error.MissingOpenVmConfigPath;
            options.executor.openvm_config_path = try arena.dupe(u8, value);
        } else if (std.mem.eql(u8, arg, "--openvm-elf")) {
            const value = args.next() orelse return error.MissingOpenVmElfPath;
            options.executor.openvm_elf_path = try arena.dupe(u8, value);
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
        if (corpus_manifest) |manifest_path| {
            try paths.appendSlice(allocator, try manifestFixtureRoots(init.io, arena, manifest_path));
        } else {
            printUsage();
            return error.MissingFixturePath;
        }
    }

    const evidence_options: ?guest_evidence.Options = if (evidence_dir) |dir| evidence: {
        if (options.output_folder != null) return error.EvidenceOwnsOutputFolder;
        const rows_dir = try std.fs.path.join(arena, &.{ dir, "rows" });
        options.output_folder = rows_dir;
        report_only = true;
        const elf_path = switch (options.executor.target) {
            .zisk => options.executor.zisk_elf_path,
            .sp1 => options.executor.sp1_elf_path,
            .openvm => options.executor.openvm_elf_path,
            .native => null,
        } orelse return error.MissingEvidenceElf;
        break :evidence .{
            .output_dir = dir,
            .rows_dir = rows_dir,
            .corpus_manifest = corpus_manifest orelse return error.MissingCorpusManifest,
            .known_failures = known_failures,
            .source_ref = source_ref orelse return error.MissingSourceRef,
            .strict = strict_evidence,
            .backend = options.executor.target,
            .elf_path = elf_path,
            .stateless_schema = stateless_schema orelse return error.MissingStatelessSchema,
            .zig_version = zig_version orelse return error.MissingZigVersion,
            .backend_version = backend_version orelse return error.MissingBackendVersion,
            .backend_commit = backend_commit orelse return error.MissingBackendCommit,
            .backend_toolchain = backend_toolchain orelse return error.MissingBackendToolchain,
        };
    } else if (corpus_manifest != null or
        known_failures != null or
        source_ref != null or
        stateless_schema != null or
        zig_version != null or
        backend_version != null or
        backend_commit != null or
        backend_toolchain != null or
        strict_evidence)
        return error.EvidenceOptionsRequireEvidenceDir
    else
        null;

    if (evidence_options) |evidence| {
        try guest_evidence.prepare(init.io, arena, evidence.output_dir, evidence.rows_dir);
    }

    // One session over every root: a guest context owns a host child, and
    // rebuilding it per root would repeat the ELF-to-ROM conversion per batch.
    options.source_roots = paths.items;
    const total = try Fixtures.run(init.io, allocator, paths.items, options, jobs);
    printSummary(if (paths.items.len == 1) paths.items[0] else "total", total);
    if (report_path) |path| try report.write(init.io, path);
    if (evidence_options) |evidence| {
        if (!try guest_evidence.write(init.io, arena, evidence)) std.process.exit(1);
    }
    // `--report-only` withholds the exit code for accumulated fixture failures
    // so a downstream comparison still gets its rows. Configuration, I/O and
    // host-startup problems surface as errors above and still fail hard, and an
    // empty run is always a failure.
    if ((!report_only and total.failed > 0) or total.fixtures == 0) std.process.exit(1);
}

fn isOption(arg: []const u8) bool {
    return std.mem.startsWith(u8, arg, "-");
}

/// A resolved corpus manifest records the fixture roots its fetcher verified,
/// so a manifest-driven run needs no separately supplied paths.
fn manifestFixtureRoots(io: std.Io, arena: std.mem.Allocator, manifest_path: []const u8) ![]const []const u8 {
    const max_manifest_bytes = 16 * 1024 * 1024;
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, manifest_path, arena, .limited(max_manifest_bytes));
    const manifest = try std.json.parseFromSliceLeaky(
        struct { fixture_roots: []const []const u8 = &.{} },
        arena,
        bytes,
        .{ .ignore_unknown_fields = true },
    );
    if (manifest.fixture_roots.len == 0) return error.MissingManifestFixtureRoots;
    return manifest.fixture_roots;
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
        \\usage: zig build zkevm -- [--executor native|zisk|sp1|openvm] [--jobs N] [--test NAME] [--limit N] [--verbose] [--trace-mismatch] [--classify-failures] [--oracle-differential] [--report PATH] [--output-folder PATH] [--evidence-dir PATH --corpus-manifest PATH --source-ref REF --stateless-schema ID --zig-version VERSION --backend-version VERSION --backend-commit SHA --backend-toolchain VERSION [--known-failures PATH] [--strict-evidence]] [--zisk-host PATH] [--zisk-elf PATH] [--sp1-host PATH] [--sp1-elf PATH] [--openvm-host PATH] [--openvm-config PATH] [--openvm-elf PATH] [path ...]
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
        \\child, which converts the ELF once at startup.
        \\Use --output-folder to also write one ERE BenchmarkRun row per block.
        \\Use --evidence-dir to aggregate those rows into evidence.json and
        \\report.md. Evidence mode owns its rows subdirectory and applies the
        \\corpus-scoped known-failure gate. --strict-evidence additionally
        \\requires pinned release-corpus identity; exact ledger matches remain accepted.
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

test "manifest-driven runs take their fixture roots from the resolved manifest" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(std.testing.io, &root_buffer)];
    const manifest_path = try std.fs.path.join(std.testing.allocator, &.{ root, "manifest.json" });
    defer std.testing.allocator.free(manifest_path);

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const cwd = std.Io.Dir.cwd();
    try cwd.writeFile(std.testing.io, .{
        .sub_path = manifest_path,
        .data =
        \\{"mode": "tests-zkevm", "fixture_roots": ["/corpus/a", "/corpus/b"]}
        ,
    });
    const roots = try manifestFixtureRoots(std.testing.io, arena_state.allocator(), manifest_path);
    try std.testing.expectEqual(@as(usize, 2), roots.len);
    try std.testing.expectEqualStrings("/corpus/a", roots[0]);

    try cwd.writeFile(std.testing.io, .{ .sub_path = manifest_path, .data = "{\"mode\": \"pinned\"}" });
    try std.testing.expectError(
        error.MissingManifestFixtureRoots,
        manifestFixtureRoots(std.testing.io, arena_state.allocator(), manifest_path),
    );
}

test "unknown options are not fixture paths" {
    try std.testing.expect(isOption("--executorr"));
    try std.testing.expect(isOption("-unknown"));
    try std.testing.expect(!isOption("./-fixture.json"));
    try std.testing.expect(!isOption("fixtures/blockchain_tests"));
}
