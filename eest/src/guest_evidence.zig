const std = @import("std");
const executor = @import("stateless_executor.zig");

const Allocator = std.mem.Allocator;
const max_json_bytes = 16 * 1024 * 1024;
const max_elf_bytes = 512 * 1024 * 1024;

pub const Options = struct {
    output_dir: []const u8,
    rows_dir: []const u8,
    corpus_manifest: []const u8,
    known_failures: ?[]const u8,
    source_ref: []const u8,
    strict: bool,
    backend: executor.Target,
    elf_path: []const u8,
    stateless_schema: []const u8,
    zig_version: []const u8,
    backend_version: []const u8,
    backend_commit: []const u8,
    backend_toolchain: []const u8,
};

const CorpusManifest = struct {
    schema_version: u32,
    mode: []const u8,
    id: []const u8,
    corpus_digest: ?[]const u8 = null,
    fixture_release: ?[]const u8 = null,
    network: []const u8,
    fixture_count: u64,
};

const KnownDocument = struct {
    schema_version: u32,
    corpus: []const u8,
    zisk: ?std.json.ArrayHashMap([]const u8) = null,
    sp1: ?std.json.ArrayHashMap([]const u8) = null,
    openvm: ?std.json.ArrayHashMap([]const u8) = null,
};

const BenchmarkRun = struct {
    name: []const u8,
    metadata: struct {
        source_path: []const u8 = "?",
        block_number: ?u64 = null,
    } = .{},
    execution: struct {
        success: ?struct {
            output_matched: bool,
            total_num_cycles: u64,
            region_cycles: struct { trace_cells: u64 },
            execution_duration: struct { secs: u64, nanos: u32 },
        } = null,
        crashed: ?struct {
            reason: []const u8,
        } = null,
    },
};

const Row = struct {
    name: []const u8,
    source: []const u8,
    primary: ?u64,
    secondary: u64 = 0,
    duration_nanos: u64 = 0,
    upstream_matched: ?bool,
    crash: ?[]const u8,

    fn failed(self: Row) bool {
        return self.crash != null or self.upstream_matched != true;
    }
};

const Aggregate = struct {
    fixture_count: u64 = 0,
    crashes: u64 = 0,
    upstream_matches: u64 = 0,
    total_primary: u64 = 0,
    total_secondary: u64 = 0,
    total_duration_nanos: u64 = 0,
    known_failures: u64 = 0,
    unexpected_failures: u64 = 0,
    known_failure_names: []const []const u8 = &.{},
    unexpected_failure_names: []const []const u8 = &.{},
    unexpected_passes: []const []const u8 = &.{},
    stale_known: []const []const u8 = &.{},

    fn passed(self: Aggregate, expected_fixtures: u64) bool {
        return self.fixture_count > 0 and
            self.fixture_count == expected_fixtures and
            self.total_primary > 0 and
            self.unexpected_failures == 0 and
            self.unexpected_passes.len == 0 and
            self.stale_known.len == 0;
    }

    fn deinit(self: Aggregate, allocator: Allocator) void {
        allocator.free(self.known_failure_names);
        allocator.free(self.unexpected_failure_names);
        allocator.free(self.unexpected_passes);
        allocator.free(self.stale_known);
    }
};

const Evidence = struct {
    schema_version: u32 = 2,
    source_ref: []const u8,
    backend: []const u8,
    metrics: struct {
        primary: []const u8,
        secondary: ?[]const u8,
    },
    stateless_schema: []const u8,
    guest: struct {
        elf_name: []const u8,
        elf_sha256: []const u8,
        zig_version: []const u8,
        backend_version: []const u8,
        backend_commit: []const u8,
        backend_toolchain: []const u8,
    },
    corpus: struct {
        mode: []const u8,
        id: []const u8,
        digest: ?[]const u8,
        fixture_release: ?[]const u8,
        network: []const u8,
        expected_fixtures: u64,
    },
    results: Aggregate,
    gate: struct {
        strict: bool,
        passed: bool,
    },
};

pub fn prepare(
    io: std.Io,
    allocator: Allocator,
    output_dir: []const u8,
    rows_dir: []const u8,
) !void {
    const evidence_path = try std.fs.path.join(allocator, &.{ output_dir, "evidence.json" });
    defer allocator.free(evidence_path);
    const report_path = try std.fs.path.join(allocator, &.{ output_dir, "report.md" });
    defer allocator.free(report_path);

    const cwd = std.Io.Dir.cwd();
    try cwd.deleteTree(io, rows_dir);
    try cwd.deleteTree(io, evidence_path);
    try cwd.deleteTree(io, report_path);
    try cwd.createDirPath(io, rows_dir);
}

pub fn write(io: std.Io, allocator: Allocator, options: Options) !bool {
    const primary_metric = options.backend.primaryMetric() orelse return error.EvidenceRequiresGuestBackend;
    if (options.source_ref.len == 0 or
        options.stateless_schema.len == 0 or
        options.zig_version.len == 0 or
        options.backend_version.len == 0 or
        options.backend_commit.len == 0 or
        options.backend_toolchain.len == 0)
    {
        return error.MissingEvidenceIdentity;
    }

    const manifest_bytes = try std.Io.Dir.cwd().readFileAlloc(
        io,
        options.corpus_manifest,
        allocator,
        .limited(max_json_bytes),
    );
    defer allocator.free(manifest_bytes);
    var manifest = try std.json.parseFromSlice(
        CorpusManifest,
        allocator,
        manifest_bytes,
        .{ .ignore_unknown_fields = true },
    );
    defer manifest.deinit();
    if (manifest.value.schema_version != 1) return error.UnsupportedCorpusManifest;
    if (manifest.value.id.len == 0 or manifest.value.network.len == 0) {
        return error.MissingCorpusIdentity;
    }
    if (options.strict and
        (!std.mem.eql(u8, manifest.value.mode, "tests-zkevm") or
            manifest.value.corpus_digest == null or
            manifest.value.fixture_release == null))
    {
        return error.InvalidStrictCorpus;
    }

    var known = std.StringHashMap(void).init(allocator);
    defer {
        var it = known.keyIterator();
        while (it.next()) |key| allocator.free(key.*);
        known.deinit();
    }
    if (options.known_failures) |path| {
        const known_bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(max_json_bytes));
        defer allocator.free(known_bytes);
        var document = try std.json.parseFromSlice(
            KnownDocument,
            allocator,
            known_bytes,
            .{ .ignore_unknown_fields = true },
        );
        defer document.deinit();
        if (document.value.schema_version != 1) return error.UnsupportedKnownFailures;
        if (std.mem.eql(u8, document.value.corpus, manifest.value.id)) {
            const entries = switch (options.backend) {
                .zisk => document.value.zisk,
                .sp1 => document.value.sp1,
                .openvm => document.value.openvm,
                .native => null,
            };
            if (entries) |backend_known| {
                var it = backend_known.map.iterator();
                while (it.next()) |entry| {
                    const name = try allocator.dupe(u8, entry.key_ptr.*);
                    errdefer allocator.free(name);
                    try known.put(name, {});
                }
            }
        }
    }

    var rows: std.ArrayList(Row) = .empty;
    defer rows.deinit(allocator);
    var names = std.StringHashMap(void).init(allocator);
    defer names.deinit();
    try loadRows(io, allocator, options.rows_dir, &rows, &names);
    std.sort.heap(Row, rows.items, {}, rowLessThan);

    const aggregate = try aggregateRows(allocator, rows.items, &known);
    defer aggregate.deinit(allocator);
    const passed = aggregate.passed(manifest.value.fixture_count);
    const elf_sha256 = try sha256File(io, allocator, options.elf_path);
    const evidence = Evidence{
        .source_ref = options.source_ref,
        .backend = @tagName(options.backend),
        .metrics = .{
            .primary = primary_metric,
            .secondary = options.backend.secondaryMetric(),
        },
        .stateless_schema = options.stateless_schema,
        .guest = .{
            .elf_name = std.fs.path.basename(options.elf_path),
            .elf_sha256 = &elf_sha256,
            .zig_version = options.zig_version,
            .backend_version = options.backend_version,
            .backend_commit = options.backend_commit,
            .backend_toolchain = options.backend_toolchain,
        },
        .corpus = .{
            .mode = manifest.value.mode,
            .id = manifest.value.id,
            .digest = manifest.value.corpus_digest,
            .fixture_release = manifest.value.fixture_release,
            .network = manifest.value.network,
            .expected_fixtures = manifest.value.fixture_count,
        },
        .results = aggregate,
        .gate = .{ .strict = options.strict, .passed = passed },
    };

    try std.Io.Dir.cwd().createDirPath(io, options.output_dir);
    const evidence_path = try std.fs.path.join(allocator, &.{ options.output_dir, "evidence.json" });
    defer allocator.free(evidence_path);
    const report_path = try std.fs.path.join(allocator, &.{ options.output_dir, "report.md" });
    defer allocator.free(report_path);

    const json = try std.json.Stringify.valueAlloc(allocator, evidence, .{ .whitespace = .indent_2 });
    defer allocator.free(json);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = evidence_path, .data = json });

    var report: std.Io.Writer.Allocating = .init(allocator);
    defer report.deinit();
    try writeReport(&report.writer, evidence, options.backend.displayName(), rows.items, &known);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = report_path, .data = report.written() });
    std.debug.print("{s}", .{report.written()});
    return passed;
}

fn loadRows(
    io: std.Io,
    allocator: Allocator,
    path: []const u8,
    rows: *std.ArrayList(Row),
    names: *std.StringHashMap(void),
) !void {
    var dir = try std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true });
    defer dir.close(io);
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        const child = try std.fs.path.join(allocator, &.{ path, entry.name });
        defer allocator.free(child);
        switch (entry.kind) {
            .directory => try loadRows(io, allocator, child, rows, names),
            .file => if (std.mem.endsWith(u8, entry.name, ".json")) {
                const bytes = try std.Io.Dir.cwd().readFileAlloc(io, child, allocator, .limited(max_json_bytes));
                const document = try std.json.parseFromSliceLeaky(
                    BenchmarkRun,
                    allocator,
                    bytes,
                    .{ .ignore_unknown_fields = true },
                );
                const result = try names.getOrPut(document.name);
                if (result.found_existing) return error.DuplicateMetricName;
                const row: Row = if (document.execution.success) |success|
                    .{
                        .name = document.name,
                        .source = document.metadata.source_path,
                        .primary = success.total_num_cycles,
                        .secondary = success.region_cycles.trace_cells,
                        .duration_nanos = try durationNanos(success.execution_duration.secs, success.execution_duration.nanos),
                        .upstream_matched = success.output_matched,
                        .crash = null,
                    }
                else if (document.execution.crashed) |crashed|
                    .{
                        .name = document.name,
                        .source = document.metadata.source_path,
                        .primary = null,
                        .upstream_matched = null,
                        .crash = crashed.reason,
                    }
                else
                    return error.MissingExecutionResult;
                try rows.append(allocator, row);
            },
            else => {},
        }
    }
}

fn durationNanos(secs: u64, nanos: u32) !u64 {
    if (nanos >= std.time.ns_per_s) return error.InvalidExecutionDuration;
    const seconds_nanos = std.math.mul(u64, secs, std.time.ns_per_s) catch
        return error.InvalidExecutionDuration;
    return std.math.add(u64, seconds_nanos, nanos) catch error.InvalidExecutionDuration;
}

fn aggregateRows(
    allocator: Allocator,
    rows: []const Row,
    known: *const std.StringHashMap(void),
) !Aggregate {
    var known_failure_names: std.ArrayList([]const u8) = .empty;
    var unexpected_failure_names: std.ArrayList([]const u8) = .empty;
    var unexpected_passes: std.ArrayList([]const u8) = .empty;
    var stale_known: std.ArrayList([]const u8) = .empty;
    var rows_by_name = std.StringHashMap(Row).init(allocator);
    defer rows_by_name.deinit();

    var aggregate: Aggregate = .{ .fixture_count = rows.len };
    for (rows) |row| {
        try rows_by_name.put(row.name, row);
        if (row.crash != null) aggregate.crashes += 1;
        if (row.upstream_matched == true) aggregate.upstream_matches += 1;
        aggregate.total_primary = std.math.add(u64, aggregate.total_primary, row.primary orelse 0) catch
            return error.MetricOverflow;
        aggregate.total_secondary = std.math.add(u64, aggregate.total_secondary, row.secondary) catch
            return error.MetricOverflow;
        aggregate.total_duration_nanos = std.math.add(u64, aggregate.total_duration_nanos, row.duration_nanos) catch
            return error.MetricOverflow;
        if (row.failed()) {
            if (known.contains(row.name)) {
                aggregate.known_failures += 1;
                try known_failure_names.append(allocator, row.name);
            } else {
                aggregate.unexpected_failures += 1;
                try unexpected_failure_names.append(allocator, row.name);
            }
        }
    }

    var known_it = known.iterator();
    while (known_it.next()) |entry| {
        if (rows_by_name.get(entry.key_ptr.*)) |row| {
            if (!row.failed()) try unexpected_passes.append(allocator, entry.key_ptr.*);
        } else {
            try stale_known.append(allocator, entry.key_ptr.*);
        }
    }
    sortStrings(known_failure_names.items);
    sortStrings(unexpected_failure_names.items);
    sortStrings(unexpected_passes.items);
    sortStrings(stale_known.items);
    aggregate.known_failure_names = try known_failure_names.toOwnedSlice(allocator);
    aggregate.unexpected_failure_names = try unexpected_failure_names.toOwnedSlice(allocator);
    aggregate.unexpected_passes = try unexpected_passes.toOwnedSlice(allocator);
    aggregate.stale_known = try stale_known.toOwnedSlice(allocator);
    return aggregate;
}

fn writeReport(
    writer: *std.Io.Writer,
    evidence: Evidence,
    backend_name: []const u8,
    rows: []const Row,
    known: *const std.StringHashMap(void),
) !void {
    try writer.print(
        "# {s} guest execution\n\n" ++
            "- Current: `{s}`\n" ++
            "- ELF SHA-256: `{s}`\n" ++
            "- Fixtures: `{s}`\n" ++
            "- Corpus digest: `{s}`\n" ++
            "- Strict gate: {s}\n" ++
            "- Gate passed: {s}\n\n" ++
            "| Fixtures | Expected | Known failures | Unexpected failures | Crashes | Upstream matches |\n" ++
            "| ---: | ---: | ---: | ---: | ---: | ---: |\n" ++
            "| {d} | {d} | {d} | {d} | {d} | {d}/{d} |\n\n" ++
            "| Metric | Total |\n" ++
            "| --- | ---: |\n" ++
            "| `{s}` | {d} |\n",
        .{
            backend_name,
            evidence.source_ref,
            evidence.guest.elf_sha256,
            evidence.corpus.id,
            evidence.corpus.digest orelse "unspecified",
            if (evidence.gate.strict) "yes" else "no",
            if (evidence.gate.passed) "yes" else "no",
            evidence.results.fixture_count,
            evidence.corpus.expected_fixtures,
            evidence.results.known_failures,
            evidence.results.unexpected_failures,
            evidence.results.crashes,
            evidence.results.upstream_matches,
            evidence.results.fixture_count,
            evidence.metrics.primary,
            evidence.results.total_primary,
        },
    );
    if (evidence.metrics.secondary) |metric| {
        try writer.print("| `{s}` | {d} |\n", .{ metric, evidence.results.total_secondary });
    }
    try writer.print("| `execution_duration_nanos` | {d} |\n\n", .{evidence.results.total_duration_nanos});
    for (rows) |row| {
        if (!row.failed() or known.contains(row.name)) continue;
        try writer.print("- `{s}: {s}`: {s}\n", .{
            row.source,
            row.name,
            row.crash orelse "upstream output mismatch",
        });
    }
    if (evidence.results.unexpected_passes.len != 0) {
        try writer.writeAll("\n## Known failures that now pass\n\n");
        for (evidence.results.unexpected_passes) |name| try writer.print("- `{s}`\n", .{name});
    }
    if (evidence.results.stale_known.len != 0) {
        try writer.writeAll("\n## Known failures missing from this corpus\n\n");
        for (evidence.results.stale_known) |name| try writer.print("- `{s}`\n", .{name});
    }
}

fn sha256File(io: std.Io, allocator: Allocator, path: []const u8) ![64]u8 {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(max_elf_bytes));
    defer allocator.free(bytes);
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    return std.fmt.bytesToHex(digest, .lower);
}

fn rowLessThan(_: void, lhs: Row, rhs: Row) bool {
    return std.mem.order(u8, lhs.name, rhs.name) == .lt;
}

fn sortStrings(strings: [][]const u8) void {
    std.sort.heap([]const u8, strings, {}, struct {
        fn lessThan(_: void, lhs: []const u8, rhs: []const u8) bool {
            return std.mem.order(u8, lhs, rhs) == .lt;
        }
    }.lessThan);
}

test "release evidence accepts exact known failures" {
    const rows = [_]Row{
        .{ .name = "pass", .source = "a.json", .primary = 10, .upstream_matched = true, .crash = null },
        .{ .name = "known", .source = "b.json", .primary = null, .upstream_matched = null, .crash = "provider crash" },
    };
    var known = std.StringHashMap(void).init(std.testing.allocator);
    defer known.deinit();
    try known.put("known", {});
    const aggregate = try aggregateRows(std.testing.allocator, &rows, &known);
    defer aggregate.deinit(std.testing.allocator);
    try std.testing.expect(aggregate.passed(2));
}

test "release evidence rejects unexpected failures" {
    const rows = [_]Row{
        .{ .name = "pass", .source = "a.json", .primary = 10, .upstream_matched = true, .crash = null },
        .{ .name = "unexpected", .source = "b.json", .primary = null, .upstream_matched = null, .crash = "new crash" },
    };
    var known = std.StringHashMap(void).init(std.testing.allocator);
    defer known.deinit();
    const aggregate = try aggregateRows(std.testing.allocator, &rows, &known);
    defer aggregate.deinit(std.testing.allocator);
    try std.testing.expect(!aggregate.passed(2));
}

test "known failure drift fails in both directions" {
    const rows = [_]Row{
        .{ .name = "fixed", .source = "a.json", .primary = 10, .upstream_matched = true, .crash = null },
    };
    var known = std.StringHashMap(void).init(std.testing.allocator);
    defer known.deinit();
    try known.put("fixed", {});
    try known.put("missing", {});
    const aggregate = try aggregateRows(std.testing.allocator, &rows, &known);
    defer aggregate.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), aggregate.unexpected_passes.len);
    try std.testing.expectEqual(@as(usize, 1), aggregate.stale_known.len);
    try std.testing.expect(!aggregate.passed(1));
}

test "evidence requires an execution metric" {
    const rows = [_]Row{
        .{ .name = "zero", .source = "a.json", .primary = 0, .upstream_matched = true, .crash = null },
    };
    var known = std.StringHashMap(void).init(std.testing.allocator);
    defer known.deinit();
    const aggregate = try aggregateRows(std.testing.allocator, &rows, &known);
    defer aggregate.deinit(std.testing.allocator);
    try std.testing.expect(!aggregate.passed(1));
}

test "execution duration rejects invalid or overflowing input" {
    try std.testing.expectError(error.InvalidExecutionDuration, durationNanos(0, std.time.ns_per_s));
    try std.testing.expectError(error.InvalidExecutionDuration, durationNanos(std.math.maxInt(u64), 0));
}

test "report names backend metrics without release policy" {
    const evidence: Evidence = .{
        .source_ref = "abc123",
        .backend = "openvm",
        .metrics = .{ .primary = "retired_instructions", .secondary = "trace_cells" },
        .stateless_schema = "0x1501",
        .guest = .{
            .elf_name = "guest.elf",
            .elf_sha256 = "deadbeef",
            .zig_version = "0.16.0",
            .backend_version = "v2.1.0-preview",
            .backend_commit = "def456",
            .backend_toolchain = "openvm-1.94.1",
        },
        .corpus = .{
            .mode = "tests-zkevm",
            .id = "tests-zkevm@v1",
            .digest = "digest",
            .fixture_release = "v1",
            .network = "Amsterdam",
            .expected_fixtures = 1,
        },
        .results = .{
            .fixture_count = 1,
            .upstream_matches = 1,
            .total_primary = 42,
            .total_secondary = 84,
            .total_duration_nanos = 99,
        },
        .gate = .{ .strict = true, .passed = true },
    };
    var report: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer report.deinit();
    var known = std.StringHashMap(void).init(std.testing.allocator);
    defer known.deinit();
    try writeReport(&report.writer, evidence, "OpenVM", &.{}, &known);
    try std.testing.expect(std.mem.indexOf(u8, report.written(), "# OpenVM guest execution") != null);
    try std.testing.expect(std.mem.indexOf(u8, report.written(), "`retired_instructions` | 42") != null);
    try std.testing.expect(std.mem.indexOf(u8, report.written(), "`trace_cells` | 84") != null);
}

test "prepare removes output from an earlier evidence run" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_buffer);
    const output_dir = try std.fs.path.join(std.testing.allocator, &.{ root_buffer[0..root_len], "evidence" });
    defer std.testing.allocator.free(output_dir);
    const rows_dir = try std.fs.path.join(std.testing.allocator, &.{ output_dir, "rows" });
    defer std.testing.allocator.free(rows_dir);
    const stale_row = try std.fs.path.join(std.testing.allocator, &.{ rows_dir, "stale.json" });
    defer std.testing.allocator.free(stale_row);
    const stale_evidence = try std.fs.path.join(std.testing.allocator, &.{ output_dir, "evidence.json" });
    defer std.testing.allocator.free(stale_evidence);
    const stale_report = try std.fs.path.join(std.testing.allocator, &.{ output_dir, "report.md" });
    defer std.testing.allocator.free(stale_report);

    const cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(std.testing.io, rows_dir);
    try cwd.writeFile(std.testing.io, .{ .sub_path = stale_row, .data = "{}" });
    try cwd.writeFile(std.testing.io, .{ .sub_path = stale_evidence, .data = "{}" });
    try cwd.writeFile(std.testing.io, .{ .sub_path = stale_report, .data = "stale" });

    try prepare(std.testing.io, std.testing.allocator, output_dir, rows_dir);

    try std.testing.expectError(error.FileNotFound, cwd.access(std.testing.io, stale_row, .{}));
    try std.testing.expectError(error.FileNotFound, cwd.access(std.testing.io, stale_evidence, .{}));
    try std.testing.expectError(error.FileNotFound, cwd.access(std.testing.io, stale_report, .{}));
    var rows = try cwd.openDir(std.testing.io, rows_dir, .{ .iterate = true });
    defer rows.close(std.testing.io);
    var iterator = rows.iterate();
    try std.testing.expect(try iterator.next(std.testing.io) == null);
}
