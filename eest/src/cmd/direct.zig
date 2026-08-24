const std = @import("std");

pub const Input = struct {
    path: []const u8,
    fixture_name: ?[]const u8,
};

pub const Arguments = union(enum) {
    help,
    input: Input,
};

pub const Result = struct {
    name: []const u8,
    pass: bool,
    skip: bool = false,
    @"error": []const u8,
};

pub fn parse(arena: std.mem.Allocator, args: *std.process.Args.Iterator) !Arguments {
    var fixture_name: ?[]const u8 = null;
    var path: ?[]const u8 = null;
    var options = true;

    while (args.next()) |arg_z| {
        const arg = arg_z[0..arg_z.len];
        if (options and (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h"))) {
            return .help;
        }
        if (options and std.mem.eql(u8, arg, "--run")) {
            if (fixture_name != null) return error.DuplicateRun;
            const value = args.next() orelse return error.MissingRun;
            fixture_name = try arena.dupe(u8, value);
            continue;
        }
        if (options and std.mem.eql(u8, arg, "--")) {
            options = false;
            continue;
        }
        if (options and std.mem.startsWith(u8, arg, "-")) return error.UnknownOption;
        if (path != null) return error.TooManyPaths;
        path = try arena.dupe(u8, arg);
    }

    return .{ .input = .{
        .path = path orelse return error.MissingPath,
        .fixture_name = fixture_name,
    } };
}

pub fn writeResults(io: std.Io, allocator: std.mem.Allocator, results: []const Result) !void {
    const json = try std.json.Stringify.valueAlloc(allocator, results, .{});
    defer allocator.free(json);

    var buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(io, &buffer);
    try stdout.interface.writeAll(json);
    try stdout.interface.writeByte('\n');
    try stdout.interface.flush();
}
