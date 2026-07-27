const std = @import("std");
const fixture = @import("../fixture.zig");
const mutation = @import("../stateless_mutation.zig");

pub const about = "Run typed stateless mutation rejection fixtures";

const default_manifest = "fixtures/stateless-mutations-tests-zkevm-v0.6.2.txt";

pub fn run(init: std.process.Init, args: *std.process.Args.Iterator) !void {
    const allocator = init.gpa;
    const arena = init.arena.allocator();

    var manifest_path: []const u8 = default_manifest;
    var fixture_root: ?[]const u8 = null;
    while (args.next()) |arg_z| {
        const arg = arg_z[0..arg_z.len];
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            printUsage();
            return;
        } else if (std.mem.eql(u8, arg, "--manifest")) {
            const value = args.next() orelse return error.MissingManifestPath;
            manifest_path = try arena.dupe(u8, value);
        } else if (fixture_root == null) {
            fixture_root = try arena.dupe(u8, arg);
        } else {
            printUsage();
            return error.InvalidArgumentCount;
        }
    }

    const root = fixture_root orelse try fixture.lockedZkevmReleasePath(init.io, arena);
    const summary = try mutation.runManifest(init.io, allocator, root, manifest_path);
    std.debug.print("canonical_inputs={} mutations={}/{}\n", .{
        summary.canonical_inputs,
        summary.resolvedCount(),
        summary.resolved.len,
    });
    if (!summary.complete()) {
        summary.printMissing();
        std.process.exit(1);
    }
}

fn printUsage() void {
    std.debug.print(
        \\usage: zig build zkevm-mutations -- [--manifest PATH] [fixture-root]
        \\
        \\Runs a bounded structured-mutation matrix over passing tests-zkevm inputs.
        \\With no fixture root, uses the pinned zkevm release root from eest.lock.
        \\
    , .{});
}
