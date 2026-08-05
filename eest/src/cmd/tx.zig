const std = @import("std");
const fixture_common = @import("../fixture.zig");
const runner = @import("../runner.zig");
const tx = @import("../tx.zig");

pub const about = "Run EEST raw transaction-test fixtures";

const Fixtures = runner.Runner(tx);

pub fn run(init: std.process.Init, args: *std.process.Args.Iterator) !void {
    const allocator = init.gpa;
    const arena = init.arena.allocator();

    var options = tx.Options{};
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
        try paths.append(allocator, try fixture_common.lockedFixturePath(init.io, arena, "transaction_tests"));
    }

    var total = tx.Summary{};
    for (paths.items) |path| {
        const summary = try Fixtures.sequential(init.io, allocator, &.{path}, options);
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
        \\usage: zig build eest-tx -- [--fork Prague] [--test name-substring] [transaction_tests_dir_or_file...]
        \\
        \\Runs EEST raw transaction_tests fixtures:
        \\  - EIP-2718 transaction envelopes
        \\  - strict/canonical RLP
        \\  - Prague type-4 authorization-list validation
        \\
    , .{});
}

fn printSummary(label: []const u8, summary: tx.Summary) void {
    std.debug.print(
        "{s}: fixtures={d} vectors={d} passed={d} failed={d} skipped={d}\n",
        .{ label, summary.fixtures, summary.vectors, summary.passed, summary.failed, summary.skipped },
    );

    inline for (std.meta.fields(tx.FailReason)) |field| {
        const count = summary.fail_reasons[field.value];
        if (count > 0) {
            std.debug.print("  fail.{s}={d}\n", .{ field.name, count });
        }
    }
}
