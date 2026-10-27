const std = @import("std");
const direct = @import("direct.zig");
const fixtures = @import("fixtures");
const transaction = @import("../transaction.zig");

pub const about = "Consume one EEST transaction fixture file";

pub fn run(init: std.process.Init, args: *std.process.Args.Iterator) !void {
    const allocator = init.gpa;
    const input = switch (try direct.parse(init.arena.allocator(), args)) {
        .help => {
            std.debug.print("usage: evmz-eest transactiontest [--run EXACT_ID] <fixture.json>\n", .{});
            return;
        },
        .input => |input| input,
    };
    const bytes = try std.Io.Dir.cwd().readFileAlloc(init.io, input.path, allocator, .limited(256 * 1024 * 1024));
    defer allocator.free(bytes);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{ .parse_numbers = false });
    defer parsed.deinit();
    var root = fixtures.asObject(parsed.value) orelse return error.ExpectedObject;
    var results: std.ArrayList(direct.Result) = .empty;
    defer results.deinit(allocator);
    var it = root.iterator();
    while (it.next()) |entry| {
        const name = entry.key_ptr.*;
        if (input.fixture_name) |selected| {
            if (!std.mem.eql(u8, name, selected)) continue;
        }
        transaction.runCase(allocator, entry.value_ptr.*) catch |err| {
            if (err == error.OutOfMemory) return err;
            try results.append(allocator, .{ .name = name, .pass = false, .@"error" = @errorName(err) });
            continue;
        };
        try results.append(allocator, .{ .name = name, .pass = true, .@"error" = "" });
    }
    if (input.fixture_name != null and results.items.len == 0) return error.FixtureNotFound;
    if (results.items.len == 0) return error.EmptyFixtureFile;
    try direct.writeResults(init.io, allocator, results.items);
}
