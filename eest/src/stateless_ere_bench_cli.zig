const std = @import("std");
const fixture_common = @import("fixture.zig");
const bench = @import("stateless_ere_bench.zig");

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const arena = init.arena.allocator();

    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, allocator);
    defer args.deinit();
    _ = args.next();

    var options = bench.Options{};
    var paths: std.ArrayList([]const u8) = .empty;
    defer paths.deinit(allocator);

    while (args.next()) |arg_z| {
        const arg = arg_z[0..arg_z.len];
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            bench.printUsage();
            return;
        } else if (std.mem.eql(u8, arg, "--engine")) {
            const value = args.next() orelse return error.MissingEngine;
            options.engine = parseEngine(value) orelse return error.InvalidEngine;
        } else if (std.mem.eql(u8, arg, "--output-folder")) {
            const value = args.next() orelse return error.MissingOutputFolder;
            options.output_folder = try arena.dupe(u8, value);
        } else if (std.mem.eql(u8, arg, "--limit")) {
            const value = args.next() orelse return error.MissingLimit;
            options.limit = try std.fmt.parseInt(usize, value, 10);
        } else if (std.mem.eql(u8, arg, "--test")) {
            const value = args.next() orelse return error.MissingTestFilter;
            options.test_filter = try arena.dupe(u8, value);
        } else if (std.mem.eql(u8, arg, "--ziskemu")) {
            const value = args.next() orelse return error.MissingZiskemuPath;
            options.ziskemu_path = try arena.dupe(u8, value);
        } else if (std.mem.eql(u8, arg, "--zisk-elf")) {
            const value = args.next() orelse return error.MissingZiskElfPath;
            options.zisk_elf_path = try arena.dupe(u8, value);
        } else if (std.mem.eql(u8, arg, "--zisk-work-dir")) {
            const value = args.next() orelse return error.MissingZiskWorkDir;
            options.zisk_work_dir = try arena.dupe(u8, value);
        } else if (std.mem.eql(u8, arg, "--zisk-max-steps")) {
            const value = args.next() orelse return error.MissingZiskMaxSteps;
            options.zisk_max_steps = try arena.dupe(u8, value);
        } else {
            try paths.append(allocator, try arena.dupe(u8, arg));
        }
    }

    if (paths.items.len == 0) {
        try paths.append(allocator, try fixture_common.lockedZkevmFixturePath(init.io, arena));
    }

    var total = bench.Summary{};
    var limit = bench.SelectionLimit{ .remaining = if (options.limit == 0) null else options.limit };
    for (paths.items) |path| {
        if (limit.exhausted()) break;
        const summary = try bench.runRoot(init.io, allocator, path, options, &limit);
        total.add(summary);
        printSummary(path, summary, options);
    }
    if (paths.items.len > 1) printSummary("total", total, options);

    if (total.failed > 0 or total.benchmarked == 0) std.process.exit(1);
}

fn parseEngine(value: []const u8) ?bench.Engine {
    if (std.mem.eql(u8, value, "native")) return .native;
    if (std.mem.eql(u8, value, "zisk")) return .zisk;
    return null;
}

fn printSummary(label: []const u8, summary: bench.Summary, options: bench.Options) void {
    std.debug.print(
        "{s}: engine={s} files={} fixtures={} benchmarked={} failed={} skipped={} output_folder={s}\n",
        .{
            label,
            options.engine.label(),
            summary.files,
            summary.fixtures,
            summary.benchmarked,
            summary.failed,
            summary.skipped,
            options.output_folder,
        },
    );
}
