const std = @import("std");
const evmz = @import("evmz");
const fixture_common = @import("fixture.zig");
const ere_io = @import("stateless_ere_io.zig");

const JsonValue = fixture_common.JsonValue;
const asArray = fixture_common.asArray;
const asObject = fixture_common.asObject;
const parseBytesFromValue = fixture_common.parseBytesFromValue;

const Options = struct {
    test_filter: ?[]const u8 = null,
    index: usize = 0,
    input_format: ere_io.InputFormat = .zisk,
    expected_public_path: ?[]const u8 = null,
    expected_public_format: ere_io.PublicFormat = .raw,
};

const Selection = struct {
    input: []u8,
    expected_output: ?[]u8,

    fn deinit(self: Selection, allocator: std.mem.Allocator) void {
        allocator.free(self.input);
        if (self.expected_output) |bytes| allocator.free(bytes);
    }
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
        } else if (std.mem.eql(u8, arg, "--test")) {
            const value = args.next() orelse return error.MissingTestFilter;
            options.test_filter = try arena.dupe(u8, value);
        } else if (std.mem.eql(u8, arg, "--index")) {
            const value = args.next() orelse return error.MissingIndex;
            options.index = try std.fmt.parseInt(usize, value, 10);
        } else if (std.mem.eql(u8, arg, "--format") or std.mem.eql(u8, arg, "--input-format")) {
            const value = args.next() orelse return error.MissingInputFormat;
            options.input_format = ere_io.parseInputFormat(value) orelse return error.InvalidInputFormat;
        } else if (std.mem.eql(u8, arg, "--expected-public")) {
            const value = args.next() orelse return error.MissingExpectedPublicPath;
            options.expected_public_path = try arena.dupe(u8, value);
        } else if (std.mem.eql(u8, arg, "--expected-public-format")) {
            const value = args.next() orelse return error.MissingExpectedPublicFormat;
            options.expected_public_format = ere_io.parsePublicFormat(value) orelse return error.InvalidExpectedPublicFormat;
        } else {
            try paths.append(allocator, try arena.dupe(u8, arg));
        }
    }

    if (paths.items.len != 2) {
        printUsage();
        return error.InvalidArgumentCount;
    }

    const fixture_path = paths.items[0];
    const output_path = paths.items[1];
    const bytes = try std.Io.Dir.cwd().readFileAlloc(init.io, fixture_path, allocator, .limited(512 * 1024 * 1024));
    defer allocator.free(bytes);

    const selection = try selectInput(allocator, bytes, options);
    defer selection.deinit(allocator);

    const encoded = try ere_io.inputBytes(allocator, selection.input, options.input_format);
    defer allocator.free(encoded);
    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = output_path, .data = encoded });

    std.debug.print("wrote input_bytes={} output_bytes={} format={s} path={s}\n", .{ selection.input.len, encoded.len, @tagName(options.input_format), output_path });
    if (selection.expected_output) |expected_output| {
        const public = evmz.stateless.ere.outputPublicValues(expected_output);
        if (options.expected_public_path) |path| {
            const public_bytes = try ere_io.publicValuesBytes(allocator, &public, options.expected_public_format);
            defer allocator.free(public_bytes);
            try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = path, .data = public_bytes });
        }
        std.debug.print("expected_public={x} format={s}\n", .{ public, @tagName(options.expected_public_format) });
    }
}

fn selectInput(allocator: std.mem.Allocator, bytes: []const u8, options: Options) !Selection {
    var parsed = try std.json.parseFromSlice(JsonValue, allocator, bytes, .{ .parse_numbers = false });
    defer parsed.deinit();

    var root = asObject(parsed.value) orelse return error.ExpectedObject;
    var seen: usize = 0;
    var it = root.iterator();
    while (it.next()) |entry| {
        const test_name = entry.key_ptr.*;
        if (options.test_filter) |needle| {
            if (std.mem.indexOf(u8, test_name, needle) == null) continue;
        }

        const fixture = asObject(entry.value_ptr.*) orelse return error.MalformedFixture;
        const blocks = asArray(fixture.get("blocks") orelse return error.MalformedFixture) orelse return error.MalformedFixture;
        for (blocks.items) |block_value| {
            const block = asObject(block_value) orelse return error.MalformedFixture;
            const input_value = block.get("statelessInputBytes") orelse continue;
            const input = try parseBytesFromValue(allocator, input_value);
            errdefer allocator.free(input);
            if (input.len == 0) {
                allocator.free(input);
                continue;
            }
            if (seen != options.index) {
                seen += 1;
                allocator.free(input);
                continue;
            }

            const expected_output = if (block.get("statelessOutputBytes")) |expected_value|
                try parseBytesFromValue(allocator, expected_value)
            else
                null;
            return .{ .input = input, .expected_output = expected_output };
        }
    }

    return error.InputNotFound;
}

test "selects stateless input from fixture JSON" {
    const input = try evmz.stateless.wire.smokeInputBytes(std.testing.allocator);
    defer std.testing.allocator.free(input);
    const output = try evmz.stateless.wire.validateStatelessBytes(std.testing.allocator, input);
    defer std.testing.allocator.free(output);

    const input_hex = try hexAlloc(std.testing.allocator, input);
    defer std.testing.allocator.free(input_hex);
    const output_hex = try hexAlloc(std.testing.allocator, output);
    defer std.testing.allocator.free(output_hex);
    const fixture = try std.fmt.allocPrint(std.testing.allocator,
        \\{{"smoke":{{"blocks":[{{"statelessInputBytes":"0x{s}","statelessOutputBytes":"0x{s}"}}]}}}}
    , .{ input_hex, output_hex });
    defer std.testing.allocator.free(fixture);

    const selection = try selectInput(std.testing.allocator, fixture, .{});
    defer selection.deinit(std.testing.allocator);
    try std.testing.expectEqualSlices(u8, input, selection.input);
    try std.testing.expectEqualSlices(u8, output, selection.expected_output.?);
}

fn hexAlloc(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    const out = try allocator.alloc(u8, bytes.len * 2);
    const alphabet = "0123456789abcdef";
    for (bytes, 0..) |byte, i| {
        out[i * 2] = alphabet[byte >> 4];
        out[i * 2 + 1] = alphabet[byte & 0x0f];
    }
    return out;
}

fn printUsage() void {
    std.debug.print(
        \\usage: zig build zkevm-input -- [--test NAME] [--index N] [--format raw|zisk] [--expected-public PATH] [--expected-public-format raw|zisk] <fixture.json> <output.bin>
        \\
        \\Extracts one EEST zkEVM statelessInputBytes value. The default
        \\format is zisk, a length-prefixed stdin frame for local ziskemu.
        \\Use --format raw for the ERE/benchmark-workload stdin contract.
        \\
    , .{});
}
