const std = @import("std");
const bench = @import("bench.zig");

pub fn main(init: std.process.Init) !void {
    const allocator = try benchmarkAllocator(init);
    const arena = init.arena.allocator();

    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, allocator);
    defer args.deinit();
    _ = args.next();

    var options = bench.Options{ .emit_results = true };
    var paths: std.ArrayList([]const u8) = .empty;
    var match_filters: std.ArrayList([]const u8) = .empty;
    defer paths.deinit(allocator);
    defer match_filters.deinit(allocator);

    while (args.next()) |arg_z| {
        const arg = arg_z[0..arg_z.len];
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            printUsage();
            return;
        } else if (std.mem.eql(u8, arg, "--iterations") or std.mem.eql(u8, arg, "-n")) {
            const value = args.next() orelse return error.MissingIterations;
            options.iterations = try std.fmt.parseInt(usize, value, 10);
        } else if (std.mem.eql(u8, arg, "--warmups")) {
            const value = args.next() orelse return error.MissingWarmups;
            options.warmups = try std.fmt.parseInt(usize, value, 10);
        } else if (std.mem.eql(u8, arg, "--test")) {
            const value = args.next() orelse return error.MissingTestFilter;
            options.test_filter = try arena.dupe(u8, value);
        } else if (std.mem.eql(u8, arg, "--match")) {
            const value = args.next() orelse return error.MissingTestFilter;
            try match_filters.append(allocator, try arena.dupe(u8, value));
        } else if (std.mem.eql(u8, arg, "--max-tests")) {
            const value = args.next() orelse return error.MissingMaxTests;
            const max_tests = try std.fmt.parseInt(usize, value, 10);
            if (max_tests == 0) return error.InvalidMaxTests;
            options.max_tests = max_tests;
        } else if (std.mem.eql(u8, arg, "--list")) {
            options.list_only = true;
        } else if (std.mem.eql(u8, arg, "--engine")) {
            const value = args.next() orelse return error.MissingEngine;
            options.engine = parseEngine(value) orelse return error.InvalidEngine;
        } else {
            try paths.append(allocator, try arena.dupe(u8, arg));
        }
    }

    if (paths.items.len == 0) {
        printUsage();
        return error.MissingFixturePath;
    }

    options.match_filters = try arena.dupe([]const u8, match_filters.items);

    var total = bench.Summary{};
    var limit = bench.SelectionLimit{ .remaining = options.max_tests };
    for (paths.items) |path| {
        if (limit.exhausted()) break;
        const summary = try runPath(init.io, allocator, path, options, &limit);
        printSummary(path, summary, options);
        total.add(summary);
    }

    if (paths.items.len > 1) {
        printSummary("total", total, options);
    }

    if (total.failed > 0 or (if (options.list_only) total.fixtures == 0 else total.benchmarked == 0)) {
        std.process.exit(1);
    }
}

const allocator_env_var = "EVMZ_BENCH_ALLOCATOR";

fn benchmarkAllocator(init: std.process.Init) !std.mem.Allocator {
    const value = init.environ_map.get(allocator_env_var) orelse return init.gpa;
    if (std.mem.eql(u8, value, "gpa")) return init.gpa;
    if (std.mem.eql(u8, value, "smp")) return std.heap.smp_allocator;
    return error.InvalidAllocator;
}

fn runPath(io: std.Io, allocator: std.mem.Allocator, path: []const u8, options: bench.Options, limit: *bench.SelectionLimit) !bench.Summary {
    var dir = std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch |err| switch (err) {
        error.NotDir => return bench.runFileLimited(io, allocator, path, options, limit),
        else => return err,
    };
    defer dir.close(io);

    var summary = bench.Summary{};
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (limit.exhausted()) break;

        const child = try std.fs.path.join(allocator, &.{ path, entry.name });
        defer allocator.free(child);

        switch (entry.kind) {
            .directory => {
                const child_summary = try runPath(io, allocator, child, options, limit);
                summary.add(child_summary);
            },
            .file => {
                if (std.mem.endsWith(u8, entry.name, ".json")) {
                    const child_summary = try bench.runFileLimited(io, allocator, child, options, limit);
                    summary.add(child_summary);
                }
            },
            else => {},
        }
    }
    return summary;
}

fn printUsage() void {
    std.debug.print(
        \\usage: zig build bench -- [--iterations N] [--warmups N] [--test substring] [--match substring] [--max-tests N] <blockchain-test.json-or-dir>...
        \\       zig build bench -- --list [--match substring] <blockchain-test.json-or-dir>...
        \\       zig build bench -- --engine evmone <blockchain-test.json-or-dir>...
        \\
        \\Runs the supported subset of EEST benchmark blockchain fixtures:
        \\  - decoded blockchain_tests transactions only
        \\  - CALL transactions with sender/to/gasLimit/data/value fields
        \\  - postState/post code and storage comparisons before timing
        \\  - engines: evmz, evmone, evmone-advanced, evmone-baseline
        \\  - repeated --match filters are ANDed against fixture/test names
        \\  - --max-tests caps matched fixtures globally across all paths
        \\  - EVMZ_BENCH_ALLOCATOR=smp opts into std.heap.smp_allocator for allocator probes
        \\
        \\Example:
        \\  scripts/fetch-eest-benchmarks.sh
        \\  zig build bench -- ../.eest/benchmarks/tests-benchmark-v0.0.9/fixtures/blockchain_tests/benchmark/compute
        \\  zig build bench -- --list --match opcode_MSTORE --match offset_0 ../.eest/benchmarks/tests-benchmark-v0.0.9/fixtures/blockchain_tests/benchmark/compute/instruction/memory/memory_access.json
        \\  zig build bench -- --match opcode_MSTORE --match offset_0 --max-tests 1 ../.eest/benchmarks/tests-benchmark-v0.0.9/fixtures/blockchain_tests/benchmark/compute/instruction/memory/memory_access.json
        \\
    , .{});
}

fn parseEngine(value: []const u8) ?bench.Engine {
    if (std.mem.eql(u8, value, "evmz")) return .evmz;
    if (std.mem.eql(u8, value, "evmone")) return .evmone_advanced;
    if (std.mem.eql(u8, value, "evmone-advanced")) return .evmone_advanced;
    if (std.mem.eql(u8, value, "evmone-baseline")) return .evmone_baseline;
    return null;
}

fn printSummary(label: []const u8, summary: bench.Summary, options: bench.Options) void {
    std.debug.print(
        "{s}: engine={s} files={d} fixtures={d} benchmarked={d} failed={d} skipped={d} txs={d} gas_used={d} iterations={d} elapsed_ns={d}",
        .{
            label,
            options.engine.label(),
            summary.files,
            summary.fixtures,
            summary.benchmarked,
            summary.failed,
            summary.skipped,
            summary.transactions,
            summary.gas_used,
            options.iterations,
            summary.elapsed_ns,
        },
    );
    bench.printThroughput(summary.gas_used, summary.elapsed_ns, options.iterations);
    std.debug.print(" vm_elapsed_ns={d}", .{summary.vm_elapsed_ns});
    bench.printVmThroughput(summary.gas_used, summary.vm_elapsed_ns, options.iterations);
    std.debug.print("\n", .{});

    inline for (std.meta.fields(bench.FailReason)) |field| {
        const count = summary.fail_reasons[field.value];
        if (count > 0) {
            std.debug.print("  fail.{s}={d}\n", .{ field.name, count });
        }
    }

    inline for (std.meta.fields(bench.SkipReason)) |field| {
        const count = summary.skip_reasons[field.value];
        if (count > 0) {
            std.debug.print("  skip.{s}={d}\n", .{ field.name, count });
        }
    }
}
