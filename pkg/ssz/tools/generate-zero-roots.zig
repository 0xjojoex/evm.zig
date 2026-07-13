const std = @import("std");

const Root = [32]u8;
const root_count = 256;

pub fn main(init: std.process.Init) !void {
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa);
    defer args.deinit();
    _ = args.next();

    const output_path = args.next() orelse {
        printUsage();
        return error.MissingOutputPath;
    };
    if (args.next() != null) {
        printUsage();
        return error.InvalidArgumentCount;
    }

    var roots: [root_count]Root = undefined;
    roots[0] = [_]u8{0} ** @sizeOf(Root);
    for (roots[1..], 1..) |*root, index| {
        const previous = roots[index - 1];
        var input: [64]u8 = undefined;
        @memcpy(input[0..32], &previous);
        @memcpy(input[32..64], &previous);
        std.crypto.hash.sha2.Sha256.hash(&input, root, .{});
    }

    try std.Io.Dir.cwd().writeFile(init.io, .{
        .sub_path = output_path,
        .data = std.mem.asBytes(&roots),
    });
    std.debug.print("wrote {d} SSZ zero roots ({d} bytes) to {s}\n", .{
        roots.len,
        @sizeOf(@TypeOf(roots)),
        output_path,
    });
}

fn printUsage() void {
    std.debug.print("usage: generate-zero-roots <output-path>\n", .{});
}
