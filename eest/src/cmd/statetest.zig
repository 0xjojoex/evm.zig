const std = @import("std");
const direct = @import("direct.zig");
const fixture_common = @import("../fixture.zig");
const state = @import("../state.zig");

pub const about = "Consume one EEST state fixture file";

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

    const bytes = try std.Io.Dir.cwd().readFileAlloc(init.io, input.path, allocator, .limited(256 * 1024 * 1024));
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
        const summary = state.runCase(allocator, name, entry.value_ptr.*, .{});
        try results.append(allocator, try resultFor(init.arena.allocator(), name, summary));
    }
    if (input.fixture_name != null and results.items.len == 0) return error.FixtureNotFound;
    if (results.items.len == 0) return error.EmptyFixtureFile;
    try direct.writeResults(init.io, allocator, results.items);
}

fn resultFor(arena: std.mem.Allocator, name: []const u8, summary: state.Summary) !direct.Result {
    const pass = summary.vectors > 0 and
        summary.passed == summary.vectors and
        summary.failed == 0 and
        summary.skipped == 0 and
        summary.unchecked == 0;
    return .{
        .name = name,
        .pass = pass,
        .@"error" = if (pass) "" else try std.fmt.allocPrint(
            arena,
            "state fixture incomplete: vectors={} passed={} failed={} skipped={} unchecked={} ({s})",
            .{ summary.vectors, summary.passed, summary.failed, summary.skipped, summary.unchecked, firstProblem(summary) },
        ),
    };
}

fn firstProblem(summary: state.Summary) []const u8 {
    inline for (std.meta.fields(state.FailReason), 0..) |field, i| {
        if (summary.fail_reasons[i] != 0) return field.name;
    }
    inline for (std.meta.fields(state.UncheckedReason), 0..) |field, i| {
        if (summary.unchecked_reasons[i] != 0) return field.name;
    }
    if (summary.vectors == 0) return "no_vectors";
    if (summary.skipped != 0) return "skipped";
    return "inconsistent_summary";
}

fn printUsage() void {
    std.debug.print(
        \\usage: evmz-eest statetest [--run EXACT_ID] <fixture.json>
        \\
        \\Runs one EEST state_test file and writes consume-direct result JSON.
        \\Selection is exact. Fixture discovery, filtering, caching, and parallelism
        \\belong to execution-specs consume direct.
        \\
    , .{});
}

test "statetest requires every vector to be checked and passing" {
    const passing = try resultFor(std.testing.allocator, "pass", .{ .vectors = 1, .passed = 1 });
    defer if (passing.@"error".len != 0) std.testing.allocator.free(passing.@"error");
    try std.testing.expect(passing.pass);

    var unchecked_summary = state.Summary{
        .vectors = 1,
        .passed = 1,
        .unchecked = 1,
    };
    unchecked_summary.unchecked_reasons[@intFromEnum(state.UncheckedReason.missing_post_state)] = 1;
    const unchecked = try resultFor(std.testing.allocator, "unchecked", unchecked_summary);
    defer std.testing.allocator.free(unchecked.@"error");
    try std.testing.expect(!unchecked.pass);
    try std.testing.expect(std.mem.indexOf(u8, unchecked.@"error", "missing_post_state") != null);
}
