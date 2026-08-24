const std = @import("std");
const block_stf = @import("../block_stf.zig");
const direct = @import("direct.zig");
const fixture_common = @import("../fixture.zig");

pub const about = "Consume one EEST blockchain fixture file";

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

    var results: std.ArrayList(direct.Result) = .empty;
    defer results.deinit(allocator);
    var it = root.iterator();
    while (it.next()) |entry| {
        const name = entry.key_ptr.*;
        if (input.fixture_name) |selected| {
            if (!std.mem.eql(u8, name, selected)) continue;
        }
        const summary = try block_stf.runCase(allocator, entry.value_ptr.*);
        try results.append(allocator, try resultFor(init.arena.allocator(), name, summary));
    }
    if (input.fixture_name != null and results.items.len == 0) return error.FixtureNotFound;
    if (results.items.len == 0) return error.EmptyFixtureFile;
    try direct.writeResults(init.io, allocator, results.items);
}

fn resultFor(arena: std.mem.Allocator, name: []const u8, summary: block_stf.Summary) !direct.Result {
    const pass = summary.passed > 0 and
        summary.failed == 0 and
        summary.skipped == 0;
    return .{
        .name = name,
        .pass = pass,
        .@"error" = if (pass) "" else try std.fmt.allocPrint(
            arena,
            "blockchain fixture incomplete: blocks={} passed={} failed={} skipped={} ({s})",
            .{ summary.fixtures, summary.passed, summary.failed, summary.skipped, firstProblem(summary) },
        ),
    };
}

fn firstProblem(summary: block_stf.Summary) []const u8 {
    inline for (std.meta.fields(block_stf.FailReason), 0..) |field, i| {
        if (summary.fail_reasons[i] != 0) return field.name;
    }
    inline for (std.meta.fields(block_stf.SkipReason), 0..) |field, i| {
        if (summary.skip_reasons[i] != 0) return field.name;
    }
    if (summary.passed == 0) return "no_blocks";
    return "inconsistent_summary";
}

fn printUsage() void {
    std.debug.print(
        \\usage: evmz-eest blocktest [--run EXACT_ID] <fixture.json>
        \\
        \\Runs one EEST blockchain_test file and writes consume-direct result JSON.
        \\Selection is exact. Fixture discovery, filtering, caching, and parallelism
        \\belong to execution-specs consume direct.
        \\
    , .{});
}

test "blocktest rejects skipped execution" {
    const passing = try resultFor(std.testing.allocator, "pass", .{ .fixtures = 1, .passed = 1 });
    defer if (passing.@"error".len != 0) std.testing.allocator.free(passing.@"error");
    try std.testing.expect(passing.pass);

    var skipped_summary = block_stf.Summary{ .skipped = 1 };
    skipped_summary.skip_reasons[@intFromEnum(block_stf.SkipReason.expected_exception)] = 1;
    const skipped = try resultFor(std.testing.allocator, "skip", skipped_summary);
    defer std.testing.allocator.free(skipped.@"error");
    try std.testing.expect(!skipped.pass);
    try std.testing.expect(std.mem.indexOf(u8, skipped.@"error", "expected_exception") != null);
}
