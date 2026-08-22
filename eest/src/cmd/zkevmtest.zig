const std = @import("std");
const direct = @import("direct.zig");
const fixture_common = @import("../fixture.zig");
const stateless = @import("../stateless.zig");

pub const about = "Consume one EEST stateless zkEVM fixture file";

pub fn run(init: std.process.Init, args: *std.process.Args.Iterator) !void {
    const allocator = init.gpa;
    const parsed_args = try direct.parse(init.arena.allocator(), args);
    const input = switch (parsed_args) {
        .help => {
            printUsage();
            return;
        },
        .input => |input| input,
    };

    const bytes = try std.Io.Dir.cwd().readFileAlloc(init.io, input.path, allocator, .limited(512 * 1024 * 1024));
    defer allocator.free(bytes);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{ .parse_numbers = false });
    defer parsed.deinit();
    var root = fixture_common.asObject(parsed.value) orelse return error.ExpectedObject;

    const options = stateless.Options{ .oracle_differential = true };
    var context = try stateless.Context.init(init.io, options);
    defer context.deinit();

    var results: std.ArrayList(direct.Result) = .empty;
    defer results.deinit(allocator);
    var it = root.iterator();
    while (it.next()) |entry| {
        const name = entry.key_ptr.*;
        if (input.fixture_name) |selected| {
            if (!std.mem.eql(u8, name, selected)) continue;
        }
        const summary = try stateless.runCase(
            init.io,
            allocator,
            input.path,
            name,
            entry.value_ptr.*,
            options,
            &context,
        );
        try results.append(allocator, try resultFor(init.arena.allocator(), name, summary));
    }
    if (input.fixture_name != null and results.items.len == 0) return error.FixtureNotFound;
    if (results.items.len == 0) return error.EmptyFixtureFile;
    try direct.writeResults(init.io, allocator, results.items);
}

fn resultFor(arena: std.mem.Allocator, name: []const u8, summary: stateless.Summary) !direct.Result {
    const skip = summary.fixtures == 0 and summary.failed == 0;
    const pass = summary.fixtures > 0 and
        summary.passed == summary.fixtures and
        summary.failed == 0;
    return .{
        .name = name,
        .pass = pass,
        .skip = skip,
        .@"error" = if (pass) "" else try std.fmt.allocPrint(
            arena,
            "stateless fixture incomplete: blocks={} passed={} failed={} ignored={} ({s})",
            .{ summary.fixtures, summary.passed, summary.failed, summary.skipped, firstProblem(summary) },
        ),
    };
}

fn firstProblem(summary: stateless.Summary) []const u8 {
    inline for (std.meta.fields(stateless.FailReason), 0..) |field, i| {
        if (summary.fail_reasons[i] != 0) return field.name;
    }
    if (summary.fixtures == 0) return "no_stateless_blocks";
    return "inconsistent_summary";
}

fn printUsage() void {
    std.debug.print(
        \\usage: evmz-eest zkevmtest [--run EXACT_ID] <fixture.json>
        \\
        \\Runs the statelessInputBytes blocks from one EEST blockchain_test
        \\file and writes consume-direct result JSON. execution-specs owns
        \\fixture discovery, filtering, caching, and native parallelism.
        \\
    , .{});
}

test "zkevmtest accepts checked stateless blocks and ignores ordinary blocks" {
    const passing = try resultFor(std.testing.allocator, "pass", .{
        .fixtures = 1,
        .passed = 1,
        .skipped = 1,
    });
    defer if (passing.@"error".len != 0) std.testing.allocator.free(passing.@"error");
    try std.testing.expect(passing.pass);
    try std.testing.expect(!passing.skip);

    const skipped = try resultFor(std.testing.allocator, "skip", .{ .skipped = 1 });
    defer std.testing.allocator.free(skipped.@"error");
    try std.testing.expect(!skipped.pass);
    try std.testing.expect(skipped.skip);

    var failed_summary = stateless.Summary{ .fixtures = 1, .failed = 1 };
    failed_summary.fail_reasons[@intFromEnum(stateless.FailReason.output_mismatch)] = 1;
    const failed = try resultFor(std.testing.allocator, "fail", failed_summary);
    defer std.testing.allocator.free(failed.@"error");
    try std.testing.expect(!failed.pass);
    try std.testing.expect(std.mem.indexOf(u8, failed.@"error", "output_mismatch") != null);
}
