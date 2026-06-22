const std = @import("std");
const eest = @import("eest.zig");

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const arena = init.arena.allocator();

    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, allocator);
    defer args.deinit();
    _ = args.next();

    var options = eest.Options{};
    var paths: std.ArrayList([]const u8) = .empty;
    defer paths.deinit(allocator);

    while (args.next()) |arg_z| {
        const arg = arg_z[0..arg_z.len];
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            printUsage();
            return;
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

    if (paths.items.len == 0) {
        printUsage();
        return error.MissingFixturePath;
    }

    var total = eest.Summary{};
    for (paths.items) |path| {
        const summary = try eest.runFile(init.io, allocator, path, options);
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

fn printUsage() void {
    std.debug.print(
        \\usage: zig build eest -- [--fork Cancun] [--test name-substring] <state-test.json>...
        \\
        \\Runs the supported subset of EEST state-test fixtures:
        \\  - pre accounts, code, storage, tx env
        \\  - CALL transactions to existing contracts
        \\  - post.state code/storage comparisons
        \\
        \\Skipped/unchecked vectors are reported separately.
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

    inline for (std.meta.fields(eest.SkipReason)) |field| {
        const count = summary.skip_reasons[field.value];
        if (count > 0) {
            std.debug.print("  skip.{s}={d}\n", .{ field.name, count });
        }
    }

    inline for (std.meta.fields(eest.UncheckedReason)) |field| {
        const count = summary.unchecked_reasons[field.value];
        if (count > 0) {
            std.debug.print("  unchecked.{s}={d}\n", .{ field.name, count });
        }
    }
}
