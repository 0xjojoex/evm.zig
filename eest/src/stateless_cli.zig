const std = @import("std");
const stateless = @import("stateless.zig");
const fixture_common = @import("fixture.zig");

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const arena = init.arena.allocator();

    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, allocator);
    defer args.deinit();
    _ = args.next();

    var options = stateless.Options{};
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
        } else if (std.mem.eql(u8, arg, "--trace-mismatch")) {
            options.trace_mismatch = true;
        } else if (std.mem.eql(u8, arg, "--classify-failures")) {
            options.classify_failures = true;
        } else if (std.mem.eql(u8, arg, "--ere-public")) {
            options.ere_public = true;
        } else {
            try paths.append(allocator, try arena.dupe(u8, arg));
        }
    }

    if (paths.items.len == 0) {
        try paths.append(allocator, try fixture_common.lockedZkevmFixturePath(init.io, arena));
    }

    var total = stateless.Summary{};
    for (paths.items) |path| {
        const summary = try runPath(init.io, allocator, path, options);
        total.add(summary);
        printSummary(path, summary);
    }
    if (paths.items.len > 1) printSummary("total", total);
    if (total.failed > 0) std.process.exit(1);
}

fn runPath(io: std.Io, allocator: std.mem.Allocator, path: []const u8, options: stateless.Options) !stateless.Summary {
    var dir = std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch |err| switch (err) {
        error.NotDir => return stateless.runFile(io, allocator, path, options),
        else => return err,
    };
    defer dir.close(io);

    var total = stateless.Summary{};
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        const child = try std.fs.path.join(allocator, &.{ path, entry.name });
        defer allocator.free(child);
        switch (entry.kind) {
            .directory => total.add(try runPath(io, allocator, child, options)),
            .file => if (std.mem.endsWith(u8, entry.name, ".json")) {
                total.add(try stateless.runFile(io, allocator, child, options));
            },
            else => {},
        }
        if (options.limit > 0 and total.fixtures >= options.limit) break;
    }
    return total;
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
        \\usage: zig build zkevm -- [--test NAME] [--limit N] [--verbose] [--trace-mismatch] [--classify-failures] [--ere-public] [path ...]
        \\
        \\Runs EEST zkEVM blockchain fixtures by comparing statelessInputBytes
        \\against statelessOutputBytes. With --ere-public, compares the ERE
        \\public-value convention: sha256(statelessOutputBytes).
        \\Use --trace-mismatch with --verbose to print selected gas/state trace events.
        \\Use --classify-failures to print one tab-separated record per failure.
        \\
    , .{});
}
