const std = @import("std");
const eest = @import("state.zig");
const fixture_common = @import("fixture.zig");

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const arena = init.arena.allocator();

    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, allocator);
    defer args.deinit();
    _ = args.next();

    var options = eest.Options{};
    var mode: Mode = .files;
    var classify_options = ClassifyOptions{};
    var paths: std.ArrayList([]const u8) = .empty;
    defer paths.deinit(allocator);

    while (args.next()) |arg_z| {
        const arg = arg_z[0..arg_z.len];
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            printUsage();
            return;
        } else if (std.mem.eql(u8, arg, "--classify")) {
            mode = .classify;
        } else if (std.mem.eql(u8, arg, "--scope")) {
            mode = .scope;
        } else if (std.mem.eql(u8, arg, "--exclude-static")) {
            mode = .classify;
            classify_options.exclude_static = true;
        } else if (std.mem.eql(u8, arg, "--exact-gas-bound")) {
            options.exact_gas_bound = true;
        } else if (std.mem.eql(u8, arg, "--limit")) {
            const value = args.next() orelse return error.MissingLimit;
            mode = .classify;
            classify_options.limit = try std.fmt.parseInt(usize, value, 10);
        } else if (std.mem.eql(u8, arg, "--root")) {
            const value = args.next() orelse return error.MissingRoot;
            mode = .classify;
            try paths.append(allocator, try arena.dupe(u8, value));
        } else if (std.mem.eql(u8, arg, "--fork")) {
            const value = args.next() orelse return error.MissingFork;
            options.fork_filter = try arena.dupe(u8, value);
        } else if (std.mem.eql(u8, arg, "--test")) {
            const value = args.next() orelse return error.MissingTestFilter;
            options.test_filter = try arena.dupe(u8, value);
        } else {
            try paths.append(allocator, try arena.dupe(u8, arg));
        }
    }

    if (mode == .scope) {
        if (paths.items.len == 0) {
            try paths.append(allocator, try fixture_common.lockedFixturePath(init.io, arena, ""));
        }
        try printScopeReport(init.io, allocator, paths.items);
        return;
    }

    if (mode == .classify) {
        if (paths.items.len == 0) {
            try paths.append(allocator, try fixture_common.lockedFixturePath(init.io, arena, "state_tests"));
        }
        classify_options.run_options = options;
        var classification = Classification.init(allocator);
        defer classification.deinit();
        for (paths.items) |path| {
            try classification.runPath(init.io, path, classify_options);
        }
        try classification.print(allocator);
        return;
    }

    if (paths.items.len == 0) {
        try paths.append(allocator, try fixture_common.lockedFixturePath(init.io, arena, "state_tests"));
    }

    var total = eest.Summary{};
    for (paths.items) |path| {
        const summary = try runPath(init.io, allocator, path, options);
        total.add(summary);
        printSummary(path, summary);
    }

    if (paths.items.len > 1) {
        printSummary("total", total);
    }

    if (total.failed > 0) {
        std.process.exit(1);
    }
}

const Mode = enum {
    files,
    classify,
    scope,
};

fn runPath(io: std.Io, allocator: std.mem.Allocator, path: []const u8, options: eest.Options) !eest.Summary {
    var runner = eest.Runner{};
    defer runner.deinit();
    return runPathWithRunner(io, allocator, path, options, &runner);
}

fn runPathWithRunner(
    io: std.Io,
    allocator: std.mem.Allocator,
    path: []const u8,
    options: eest.Options,
    runner: *eest.Runner,
) !eest.Summary {
    var dir = std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch |err| switch (err) {
        error.NotDir => return runner.runFile(io, allocator, path, options),
        else => return err,
    };
    defer dir.close(io);

    var total = eest.Summary{};
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        const child = try std.fs.path.join(allocator, &.{ path, entry.name });
        defer allocator.free(child);

        switch (entry.kind) {
            .directory => total.add(try runPathWithRunner(io, allocator, child, options, runner)),
            .file => {
                if (std.mem.endsWith(u8, entry.name, ".json")) {
                    total.add(try runner.runFile(io, allocator, child, options));
                }
            },
            else => {},
        }
    }
    return total;
}

const ClassifyOptions = struct {
    run_options: eest.Options = .{},
    exclude_static: bool = false,
    limit: usize = 0,
};

const Stats = struct {
    files: usize = 0,
    vectors: usize = 0,
    passed: usize = 0,
    failed: usize = 0,
    skipped: usize = 0,
    unchecked: usize = 0,

    fn fromSummary(summary: eest.Summary) Stats {
        return .{
            .files = 1,
            .vectors = summary.vectors,
            .passed = summary.passed,
            .failed = summary.failed,
            .skipped = summary.skipped,
            .unchecked = summary.unchecked,
        };
    }

    fn add(self: *Stats, other: Stats) void {
        self.files += other.files;
        self.vectors += other.vectors;
        self.passed += other.passed;
        self.failed += other.failed;
        self.skipped += other.skipped;
        self.unchecked += other.unchecked;
    }
};

const StatsEntry = struct {
    name: []const u8,
    stats: Stats,
};

const ReasonByGroup = struct {
    group: []const u8,
    reason: []const u8,
    count: usize,
};

const FailedFile = struct {
    path: []const u8,
    count: usize,
};

const SortKey = enum {
    vectors,
    failed,
};

const Classification = struct {
    allocator: std.mem.Allocator,
    total: Stats = .{},
    files_seen: usize = 0,
    runner: eest.Runner = .{},
    by_fork: std.StringHashMap(Stats),
    by_group: std.StringHashMap(Stats),
    fail_reasons: [std.meta.fields(eest.FailReason).len]usize = [_]usize{0} ** std.meta.fields(eest.FailReason).len,
    fail_by_group: std.ArrayList(ReasonByGroup) = .empty,
    failed_files: std.ArrayList(FailedFile) = .empty,

    fn init(allocator: std.mem.Allocator) Classification {
        return .{
            .allocator = allocator,
            .by_fork = std.StringHashMap(Stats).init(allocator),
            .by_group = std.StringHashMap(Stats).init(allocator),
        };
    }

    fn deinit(self: *Classification) void {
        self.runner.deinit();
        freeMapKeys(self.allocator, &self.by_fork);
        self.by_fork.deinit();
        freeMapKeys(self.allocator, &self.by_group);
        self.by_group.deinit();
        for (self.fail_by_group.items) |entry| {
            self.allocator.free(entry.group);
            self.allocator.free(entry.reason);
        }
        self.fail_by_group.deinit(self.allocator);
        for (self.failed_files.items) |entry| {
            self.allocator.free(entry.path);
        }
        self.failed_files.deinit(self.allocator);
    }

    fn done(self: *const Classification, options: ClassifyOptions) bool {
        return options.limit > 0 and self.files_seen >= options.limit;
    }

    fn runPath(self: *Classification, io: std.Io, path: []const u8, options: ClassifyOptions) !void {
        if (self.done(options)) return;

        var dir = std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch |err| switch (err) {
            error.NotDir => return self.runFile(io, path, options),
            else => return err,
        };
        defer dir.close(io);

        var it = dir.iterate();
        while (try it.next(io)) |entry| {
            if (self.done(options)) break;
            const child = try std.fs.path.join(self.allocator, &.{ path, entry.name });
            defer self.allocator.free(child);

            switch (entry.kind) {
                .directory => try self.runPath(io, child, options),
                .file => {
                    if (std.mem.endsWith(u8, entry.name, ".json")) {
                        try self.runFile(io, child, options);
                    }
                },
                else => {},
            }
        }
    }

    fn runFile(self: *Classification, io: std.Io, path: []const u8, options: ClassifyOptions) !void {
        if (self.done(options)) return;
        if (options.exclude_static and std.mem.indexOf(u8, path, "/static/") != null) return;

        self.files_seen += 1;
        const summary = try self.runner.runFile(io, self.allocator, path, options.run_options);
        const stats = Stats.fromSummary(summary);
        self.total.add(stats);

        const fork = clusterFork(path);
        try addStats(self.allocator, &self.by_fork, fork, stats);

        const group = try clusterGroup(self.allocator, path);
        defer self.allocator.free(group);
        try addStats(self.allocator, &self.by_group, group, stats);

        if (summary.failed > 0) {
            const owned_path = try self.allocator.dupe(u8, path);
            errdefer self.allocator.free(owned_path);
            try self.failed_files.append(self.allocator, .{ .path = owned_path, .count = summary.failed });
        }

        inline for (std.meta.fields(eest.FailReason)) |field| {
            const count = summary.fail_reasons[field.value];
            if (count > 0) {
                self.fail_reasons[field.value] += count;
                const reason: eest.FailReason = @enumFromInt(field.value);
                try self.addReasonByGroup(group, @tagName(reason), count);
            }
        }
    }

    fn addReasonByGroup(self: *Classification, group: []const u8, reason: []const u8, count: usize) !void {
        for (self.fail_by_group.items) |*entry| {
            if (std.mem.eql(u8, entry.group, group) and std.mem.eql(u8, entry.reason, reason)) {
                entry.count += count;
                return;
            }
        }

        const owned_group = try self.allocator.dupe(u8, group);
        errdefer self.allocator.free(owned_group);
        const owned_reason = try self.allocator.dupe(u8, reason);
        errdefer self.allocator.free(owned_reason);
        try self.fail_by_group.append(self.allocator, .{
            .group = owned_group,
            .reason = owned_reason,
            .count = count,
        });
    }

    fn print(self: *Classification, allocator: std.mem.Allocator) !void {
        std.debug.print("files_seen={d} completed={d}\n", .{ self.files_seen, self.total.files });
        std.debug.print(
            "vectors={d} passed={d} failed={d} skipped={d} unchecked={d}\n",
            .{ self.total.vectors, self.total.passed, self.total.failed, self.total.skipped, self.total.unchecked },
        );
        if (self.total.vectors > 0) {
            std.debug.print(
                "pct passed={d:.1} failed={d:.1} skipped={d:.1}\n",
                .{
                    percent(self.total.passed, self.total.vectors),
                    percent(self.total.failed, self.total.vectors),
                    percent(self.total.skipped, self.total.vectors),
                },
            );
        }
        const exercised = self.total.passed + self.total.failed;
        if (exercised > 0) {
            std.debug.print("exercised={d} pass_of_exercised={d:.1}\n", .{ exercised, percent(self.total.passed, exercised) });
        }

        try printStatsMap(allocator, "by_fork:", &self.by_fork, .vectors, false);
        try printStatsMap(allocator, "top_failed_clusters:", &self.by_group, .failed, true);
        printFailReasons(self.fail_reasons);
        printReasonByGroup(&self.fail_by_group);
        printFailedFiles(&self.failed_files);
    }
};

fn printUsage() void {
    std.debug.print(
        \\usage: zig build eest -- [--exact-gas-bound] [--fork Cancun] [--test name-substring] [state-test.json-or-dir...]
        \\       zig build eest -- --classify [--exact-gas-bound] [--exclude-static] [--limit N] [--root state_tests_dir]
        \\       zig build eest -- --scope [fixtures_dir]
        \\
        \\Runs the supported subset of EEST state-test fixtures:
        \\  - pre accounts, code, storage, tx env
        \\  - CALL and create transactions
        \\  - post.state code/storage comparisons
        \\
        \\With no paths, the runner uses eest.lock dest + fixtures/state_tests.
        \\--exact-gas-bound runs compiled exact block-gas buckets and skips unsupported limits.
        \\
        \\Failed/unchecked vectors are reported separately.
        \\
    , .{});
}

fn printSummary(label: []const u8, summary: eest.Summary) void {
    std.debug.print(
        "{s}: fixtures={d} vectors={d} passed={d} failed={d} skipped={d} unchecked={d}\n",
        .{ label, summary.fixtures, summary.vectors, summary.passed, summary.failed, summary.skipped, summary.unchecked },
    );

    inline for (std.meta.fields(eest.FailReason)) |field| {
        const count = summary.fail_reasons[field.value];
        if (count > 0) {
            std.debug.print("  fail.{s}={d}\n", .{ field.name, count });
        }
    }

    inline for (std.meta.fields(eest.UncheckedReason)) |field| {
        const count = summary.unchecked_reasons[field.value];
        if (count > 0) {
            std.debug.print("  unchecked.{s}={d}\n", .{ field.name, count });
        }
    }
}

fn addStats(allocator: std.mem.Allocator, map: *std.StringHashMap(Stats), key: []const u8, stats: Stats) !void {
    if (map.getPtr(key)) |existing| {
        existing.add(stats);
        return;
    }

    const owned_key = try allocator.dupe(u8, key);
    errdefer allocator.free(owned_key);
    try map.put(owned_key, stats);
}

fn freeMapKeys(allocator: std.mem.Allocator, map: *std.StringHashMap(Stats)) void {
    var it = map.keyIterator();
    while (it.next()) |key| {
        allocator.free(key.*);
    }
}

fn printStatsMap(
    allocator: std.mem.Allocator,
    title: []const u8,
    map: *std.StringHashMap(Stats),
    sort_key: SortKey,
    failed_only: bool,
) !void {
    var entries: std.ArrayList(StatsEntry) = .empty;
    defer entries.deinit(allocator);

    var it = map.iterator();
    while (it.next()) |entry| {
        if (failed_only and entry.value_ptr.failed == 0) continue;
        try entries.append(allocator, .{
            .name = entry.key_ptr.*,
            .stats = entry.value_ptr.*,
        });
    }

    std.sort.heap(StatsEntry, entries.items, sort_key, statsEntryLess);

    std.debug.print("\n{s}\n", .{title});
    for (entries.items) |entry| {
        printStatsLine(entry.name, entry.stats);
    }
}

fn printStatsLine(name: []const u8, stats: Stats) void {
    std.debug.print(
        "{s:<32} files={d:5} vectors={d:7} passed={d:7} failed={d:7} skipped={d:7} unchecked={d:7}\n",
        .{ name, stats.files, stats.vectors, stats.passed, stats.failed, stats.skipped, stats.unchecked },
    );
}

fn statsEntryLess(sort_key: SortKey, a: StatsEntry, b: StatsEntry) bool {
    const a_value = switch (sort_key) {
        .vectors => a.stats.vectors,
        .failed => a.stats.failed,
    };
    const b_value = switch (sort_key) {
        .vectors => b.stats.vectors,
        .failed => b.stats.failed,
    };
    if (a_value != b_value) return a_value > b_value;
    return std.mem.lessThan(u8, a.name, b.name);
}

fn printFailReasons(counts: [std.meta.fields(eest.FailReason).len]usize) void {
    std.debug.print("\nfail_reasons:\n", .{});
    inline for (std.meta.fields(eest.FailReason)) |field| {
        const count = counts[field.value];
        if (count > 0) {
            std.debug.print("{s:<36} {d:8}\n", .{ field.name, count });
        }
    }
}

fn printReasonByGroup(items: *std.ArrayList(ReasonByGroup)) void {
    std.sort.heap(ReasonByGroup, items.items, {}, reasonByGroupLess);
    std.debug.print("\nfail_reasons_by_cluster:\n", .{});
    const limit = @min(items.items.len, 30);
    for (items.items[0..limit]) |entry| {
        std.debug.print("{d:8} {s:<32} {s}\n", .{ entry.count, entry.group, entry.reason });
    }
}

fn reasonByGroupLess(_: void, a: ReasonByGroup, b: ReasonByGroup) bool {
    if (a.count != b.count) return a.count > b.count;
    const group_order = std.mem.order(u8, a.group, b.group);
    if (group_order != .eq) return group_order == .lt;
    return std.mem.lessThan(u8, a.reason, b.reason);
}

fn printFailedFiles(items: *std.ArrayList(FailedFile)) void {
    std.sort.heap(FailedFile, items.items, {}, failedFileLess);
    std.debug.print("\ntop_failed_files:\n", .{});
    const limit = @min(items.items.len, 30);
    for (items.items[0..limit]) |entry| {
        std.debug.print("{d:8} {s}\n", .{ entry.count, entry.path });
    }
}

fn failedFileLess(_: void, a: FailedFile, b: FailedFile) bool {
    if (a.count != b.count) return a.count > b.count;
    return std.mem.lessThan(u8, a.path, b.path);
}

fn percent(value: usize, total: usize) f64 {
    return @as(f64, @floatFromInt(value)) * 100.0 / @as(f64, @floatFromInt(total));
}

fn clusterFork(path: []const u8) []const u8 {
    var parts: [128][]const u8 = undefined;
    const len = splitPath(path, &parts);
    for (parts[0..len], 0..) |part, i| {
        if (std.mem.eql(u8, part, "state_tests")) {
            if (i + 1 < len) return parts[i + 1];
            return "unknown";
        }
    }
    return "unknown";
}

fn clusterGroup(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    var parts: [128][]const u8 = undefined;
    const len = splitPath(path, &parts);
    for (parts[0..len], 0..) |part, i| {
        if (std.mem.eql(u8, part, "state_tests")) {
            if (i + 1 >= len) return allocator.dupe(u8, "unknown");
            const fork = parts[i + 1];
            if (std.mem.eql(u8, fork, "static")) {
                if (i + 3 < len) return std.fmt.allocPrint(allocator, "static/{s}", .{parts[i + 3]});
                return allocator.dupe(u8, "static/unknown");
            }
            if (i + 2 < len) return allocator.dupe(u8, parts[i + 2]);
            return allocator.dupe(u8, "unknown");
        }
    }
    return allocator.dupe(u8, "unknown");
}

fn splitPath(path: []const u8, out: *[128][]const u8) usize {
    var len: usize = 0;
    var it = std.mem.splitScalar(u8, path, '/');
    while (it.next()) |part| {
        if (part.len == 0) continue;
        if (len == out.len) break;
        out[len] = part;
        len += 1;
    }
    return len;
}

const ScopeStatus = enum {
    supported,
    partial,
    todo,
    out_of_scope,
    unsupported,
};

const ScopeTrack = struct {
    name: []const u8,
    status: ScopeStatus,
    note: []const u8,
};

const scope_tracks = [_]ScopeTrack{
    .{
        .name = "state_tests",
        .status = .supported,
        .note = "state runner executes tx validation, calls/create, and comparable post state",
    },
    .{
        .name = "blockchain_tests",
        .status = .out_of_scope,
        .note = "client/block scope: trie roots, receipts, logs hash, and block validation",
    },
    .{
        .name = "blockchain_tests_engine",
        .status = .out_of_scope,
        .note = "client/engine scope: Engine API payload validation",
    },
    .{
        .name = "blockchain_tests_engine_x",
        .status = .out_of_scope,
        .note = "client/engine scope: extended Engine API/pre-state-hash fixtures",
    },
    .{
        .name = "transaction_tests",
        .status = .supported,
        .note = "raw tx decoding/validation runner: strict RLP envelopes and Prague type-4 auth-list checks",
    },
};

fn printScopeReport(io: std.Io, allocator: std.mem.Allocator, roots: []const []const u8) !void {
    for (roots) |root| {
        std.debug.print("EEST fixture scope: {s}\n", .{root});
        std.debug.print("{s:<28} {s:>8} {s:<12} {s}\n", .{ "track", "files", "status", "note" });
        for (scope_tracks) |track| {
            const path = try std.fs.path.join(allocator, &.{ root, track.name });
            defer allocator.free(path);
            const count = try countJsonFilesIfPresent(io, path);
            std.debug.print("{s:<28} {d:>8} {s:<12} {s}\n", .{
                track.name,
                count,
                @tagName(track.status),
                track.note,
            });
        }
    }

    const benchmark_root = "../.eest/benchmarks/tests-benchmark-v0.0.9/fixtures";
    const benchmark_count = try countJsonFilesIfPresent(io, benchmark_root);
    if (benchmark_count > 0) {
        std.debug.print("\nEEST benchmark scope: {s}\n", .{benchmark_root});
        std.debug.print("{s:<28} {s:>8} {s:<12} {s}\n", .{ "track", "files", "status", "note" });
        std.debug.print("{s:<28} {d:>8} {s:<12} {s}\n", .{
            "benchmark_fixtures",
            benchmark_count,
            "partial",
            "benchmark runner covers decoded blockchain_tests compute fixtures only",
        });
    }
}

fn countJsonFilesIfPresent(io: std.Io, path: []const u8) !usize {
    var dir = std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return 0,
        else => return err,
    };
    defer dir.close(io);
    return countJsonFiles(io, &dir);
}

fn countJsonFiles(io: std.Io, dir: *std.Io.Dir) !usize {
    var total: usize = 0;
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        switch (entry.kind) {
            .directory => {
                var child = try dir.openDir(io, entry.name, .{ .iterate = true });
                defer child.close(io);
                total += try countJsonFiles(io, &child);
            },
            .file => {
                if (std.mem.endsWith(u8, entry.name, ".json")) total += 1;
            },
            else => {},
        }
    }
    return total;
}
