const std = @import("std");
const mutation = @import("../stateless_mutation.zig");

pub const about = "Run typed stateless mutation rejection fixtures";

pub fn run(init: std.process.Init, args: *std.process.Args.Iterator) !void {
    const allocator = init.gpa;
    const arena = init.arena.allocator();

    var manifest_path: ?[]const u8 = null;
    var corpus_manifest: ?[]const u8 = null;
    var fixture_root: ?[]const u8 = null;
    while (args.next()) |arg_z| {
        const arg = arg_z[0..arg_z.len];
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            printUsage();
            return;
        } else if (std.mem.eql(u8, arg, "--manifest")) {
            const value = args.next() orelse return error.MissingManifestPath;
            manifest_path = try arena.dupe(u8, value);
        } else if (std.mem.eql(u8, arg, "--corpus-manifest")) {
            const value = args.next() orelse return error.MissingCorpusManifest;
            corpus_manifest = try arena.dupe(u8, value);
        } else if (fixture_root == null) {
            fixture_root = try arena.dupe(u8, arg);
        } else {
            printUsage();
            return error.InvalidArgumentCount;
        }
    }

    const root = fixture_root orelse if (corpus_manifest) |path|
        try corpusFixtureRoot(init.io, arena, path)
    else {
        printUsage();
        return error.MissingFixtureRoot;
    };
    const resolved_manifest = manifest_path orelse {
        printUsage();
        return error.MissingManifestPath;
    };
    const summary = try mutation.runManifest(init.io, allocator, root, resolved_manifest);
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

fn corpusFixtureRoot(io: std.Io, allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(16 * 1024 * 1024));
    const manifest = try std.json.parseFromSliceLeaky(
        struct { fixture_root: []const u8 = "" },
        allocator,
        bytes,
        .{ .ignore_unknown_fields = true },
    );
    if (manifest.fixture_root.len == 0) return error.MissingManifestFixtureRoot;
    return manifest.fixture_root;
}

fn printUsage() void {
    std.debug.print(
        \\usage: zig build zkevm-mutations -- --manifest PATH [--corpus-manifest PATH | fixture-root]
        \\
        \\Runs a bounded structured-mutation matrix over passing tests-zkevm inputs.
        \\execution-specs resolves and caches the corpus; this command only reads
        \\the explicit root or resolver manifest supplied by its caller.
        \\
    , .{});
}

test "mutation runs take their fixture root from the resolved manifest" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(std.testing.io, &root_buffer)];
    const manifest_path = try std.fs.path.join(std.testing.allocator, &.{ root, "manifest.json" });
    defer std.testing.allocator.free(manifest_path);

    const cwd = std.Io.Dir.cwd();
    try cwd.writeFile(std.testing.io, .{
        .sub_path = manifest_path,
        .data =
        \\{"mode": "tests-zkevm", "fixture_root": "/corpus/root"}
        ,
    });
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const fixture_root = try corpusFixtureRoot(std.testing.io, arena_state.allocator(), manifest_path);
    try std.testing.expectEqualStrings("/corpus/root", fixture_root);

    try cwd.writeFile(std.testing.io, .{ .sub_path = manifest_path, .data = "{}" });
    try std.testing.expectError(
        error.MissingManifestFixtureRoot,
        corpusFixtureRoot(std.testing.io, arena_state.allocator(), manifest_path),
    );
}
