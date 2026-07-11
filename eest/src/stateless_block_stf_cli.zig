const std = @import("std");
const block_stf = @import("stateless_block_stf.zig");
const fixture_common = @import("fixture.zig");

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const arena = init.arena.allocator();

    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, allocator);
    defer args.deinit();
    _ = args.next();

    var options = block_stf.Options{};
    var paths: std.ArrayList([]const u8) = .empty;
    defer paths.deinit(allocator);

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
        } else if (std.mem.eql(u8, arg, "--verbose")) {
            options.verbose = true;
        } else if (std.mem.eql(u8, arg, "--expected-exceptions-only")) {
            options.expected_exceptions_only = true;
        } else {
            try paths.append(allocator, try arena.dupe(u8, arg));
        }
    }

    if (paths.items.len == 0) {
        try paths.append(allocator, try defaultFixturePath(init.io, arena));
    }

    var total = block_stf.Summary{};
    for (paths.items) |path| {
        const summary = try runPath(init.io, allocator, path, options);
        total.add(summary);
        printSummary(path, summary);
    }
    if (paths.items.len > 1) printSummary("total", total);
    if (total.failed > 0) std.process.exit(1);
}

fn defaultFixturePath(io: std.Io, allocator: std.mem.Allocator) ![]u8 {
    const root = try fixture_common.lockedZkevmFixturePath(io, allocator);
    return try std.fs.path.join(allocator, &.{
        root,
        "blockchain_tests/for_amsterdam/amsterdam/eip7928_block_level_access_lists",
    });
}

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

fn printSummary(path: []const u8, summary: block_stf.Summary) void {
    std.debug.print(
        "{s}: files={} fixtures={} passed={} failed={} skipped={}\n",
        .{ path, summary.files, summary.fixtures, summary.passed, summary.failed, summary.skipped },
    );
    inline for (std.meta.fields(block_stf.SkipReason), 0..) |field, i| {
        const count = summary.skip_reasons[i];
        if (count != 0) std.debug.print("  skip.{s}: {}\n", .{ field.name, count });
    }
    inline for (std.meta.fields(block_stf.FailReason), 0..) |field, i| {
        const count = summary.fail_reasons[i];
        if (count != 0) std.debug.print("  fail.{s}: {}\n", .{ field.name, count });
    }
    if (summary.expected.total != 0) {
        std.debug.print(
            "  expected: total={} evaluated={} rejected={} accepted={} adapter_errors={} skipped={} decoded_views={}\n",
            .{
                summary.expected.total,
                summary.expected.evaluated(),
                summary.expected.rejected,
                summary.expected.accepted,
                summary.expected.adapter_errors,
                summary.expected.skipped,
                summary.expected.decoded_views,
            },
        );
        inline for (std.meta.fields(block_stf.ExpectedStatus), 0..) |field, i| {
            const count = summary.expected.rejected_statuses[i];
            if (count != 0) std.debug.print("    status.{s}: {}\n", .{ field.name, count });
        }
    }
}

fn printUsage() void {
    std.debug.print(
        \\usage: zig build eest-stateless-block-stf -- [--test NAME] [--limit N] [--verbose] [--expected-exceptions-only] [path ...]
        \\
        \\Runs witness-backed zkEVM blockchain fixtures through eth.BlockSTF.
        \\The adapter supports positive blocks with an executionWitness and
        \\empty or legacy-signed payload transactions; unsupported blocks are
        \\reported as skips with a reason.
        \\--expected-exceptions-only executes only expectException blocks and
        \\reports observed STF statuses without interpreting fixture labels.
        \\
    , .{});
}
