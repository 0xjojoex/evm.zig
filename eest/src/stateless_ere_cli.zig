const std = @import("std");
const evmz = @import("evmz");
const ere_io = @import("stateless_ere_io.zig");

const Options = struct {
    public_format: ere_io.PublicFormat = .raw,
    expected_public_path: ?[]const u8 = null,
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const arena = init.arena.allocator();

    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, allocator);
    defer args.deinit();
    _ = args.next();

    var options = Options{};
    var paths: std.ArrayList([]const u8) = .empty;
    defer paths.deinit(allocator);

    while (args.next()) |arg_z| {
        const arg = arg_z[0..arg_z.len];
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            printUsage();
            return;
        } else if (std.mem.eql(u8, arg, "--public-format")) {
            const value = args.next() orelse return error.MissingPublicFormat;
            options.public_format = ere_io.parsePublicFormat(value) orelse return error.InvalidPublicFormat;
        } else if (std.mem.eql(u8, arg, "--expected-public")) {
            const value = args.next() orelse return error.MissingExpectedPublicPath;
            options.expected_public_path = try arena.dupe(u8, value);
        } else {
            try paths.append(allocator, try arena.dupe(u8, arg));
        }
    }

    if (paths.items.len != 2) {
        printUsage();
        return error.InvalidArgumentCount;
    }

    const input_path = paths.items[0];
    const output_path = paths.items[1];
    const input = try std.Io.Dir.cwd().readFileAlloc(init.io, input_path, allocator, .limited(512 * 1024 * 1024));
    defer allocator.free(input);

    const public = try evmz.stateless.ere.validateStatelessPublicValues(allocator, input);
    const output = try ere_io.publicValuesBytes(allocator, &public, options.public_format);
    defer allocator.free(output);
    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = output_path, .data = output });

    if (options.expected_public_path) |path| {
        const expected = try std.Io.Dir.cwd().readFileAlloc(init.io, path, allocator, .limited(1024));
        defer allocator.free(expected);
        if (!std.mem.eql(u8, output, expected)) return error.PublicValuesMismatch;
    }

    std.debug.print("wrote public={x} output_bytes={} format={s} path={s}\n", .{ public, output.len, @tagName(options.public_format), output_path });
}

test "raw stateless input produces ERE public values" {
    const input = try evmz.stateless.wire.smokeInputBytes(std.testing.allocator);
    defer std.testing.allocator.free(input);

    const public = try evmz.stateless.ere.validateStatelessPublicValues(std.testing.allocator, input);
    const expected_output = try evmz.stateless.wire.validateStatelessBytes(std.testing.allocator, input);
    defer std.testing.allocator.free(expected_output);
    const expected_public = evmz.stateless.ere.outputPublicValues(expected_output);

    try std.testing.expectEqualSlices(u8, &expected_public, &public);
}

fn printUsage() void {
    std.debug.print(
        \\usage: zig build zkevm-ere -- [--public-format raw|zisk] [--expected-public PATH] <stateless-input.bin> <public-output.bin>
        \\
        \\Runs raw ERE/benchmark-workload statelessInputBytes through the native
        \\evmz adapter and writes sha256(statelessOutputBytes). Use
        \\--public-format zisk to write the 256-byte ZisK-padded public output.
        \\
    , .{});
}
