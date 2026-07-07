const std = @import("std");
const evmz = @import("evmz");
const common = @import("common.zig");
const host_boundary = @import("host_boundary.zig");

const Boundary = host_boundary.Boundary;
const Operation = host_boundary.Operation;

const default_repeats = 5;
const default_warmups = 1;

const Options = struct {
    iterations: usize = host_boundary.default_iterations,
    repeats: usize = default_repeats,
    warmups: usize = default_warmups,
    spec: evmz.eth.Revision = .latest,
    include_bytecode: bool = false,
    no_header: bool = false,
    explicit_boundary: bool = false,
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    var stdout_buffer: [8192]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(init.io, &stdout_buffer);
    const stdout = &stdout_writer.interface;

    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, allocator);
    defer args.deinit();
    _ = args.next();

    var options = Options{};
    var selected_ops: std.ArrayList(Operation) = .empty;
    defer selected_ops.deinit(allocator);
    var selected_boundaries: std.ArrayList(Boundary) = .empty;
    defer selected_boundaries.deinit(allocator);

    while (args.next()) |arg_z| {
        const arg = arg_z[0..arg_z.len];
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            printUsage();
            return;
        } else if (std.mem.eql(u8, arg, "--op")) {
            const value = args.next() orelse return error.MissingOp;
            try selected_ops.append(allocator, host_boundary.parseOperation(value) orelse return error.InvalidOp);
        } else if (common.stripPrefix(arg, "--op=")) |value| {
            try selected_ops.append(allocator, host_boundary.parseOperation(value) orelse return error.InvalidOp);
        } else if (std.mem.eql(u8, arg, "--boundary")) {
            const value = args.next() orelse return error.MissingBoundary;
            try selected_boundaries.append(allocator, host_boundary.parseBoundary(value) orelse return error.InvalidBoundary);
            options.explicit_boundary = true;
        } else if (common.stripPrefix(arg, "--boundary=")) |value| {
            try selected_boundaries.append(allocator, host_boundary.parseBoundary(value) orelse return error.InvalidBoundary);
            options.explicit_boundary = true;
        } else if (std.mem.eql(u8, arg, "--iterations") or std.mem.eql(u8, arg, "-n")) {
            const value = args.next() orelse return error.MissingIterations;
            options.iterations = try common.parseNonZeroUsize(value);
        } else if (common.stripPrefix(arg, "--iterations=")) |value| {
            options.iterations = try common.parseNonZeroUsize(value);
        } else if (std.mem.eql(u8, arg, "--repeats")) {
            const value = args.next() orelse return error.MissingRepeats;
            options.repeats = try common.parseNonZeroUsize(value);
        } else if (common.stripPrefix(arg, "--repeats=")) |value| {
            options.repeats = try common.parseNonZeroUsize(value);
        } else if (std.mem.eql(u8, arg, "--warmups")) {
            const value = args.next() orelse return error.MissingWarmups;
            options.warmups = try parseUsize(value);
        } else if (common.stripPrefix(arg, "--warmups=")) |value| {
            options.warmups = try parseUsize(value);
        } else if (std.mem.eql(u8, arg, "--spec")) {
            const value = args.next() orelse return error.MissingSpec;
            options.spec = common.parseSpec(value) orelse return error.InvalidSpec;
        } else if (common.stripPrefix(arg, "--spec=")) |value| {
            options.spec = common.parseSpec(value) orelse return error.InvalidSpec;
        } else if (std.mem.eql(u8, arg, "--include-bytecode")) {
            options.include_bytecode = true;
        } else if (std.mem.eql(u8, arg, "--no-header")) {
            options.no_header = true;
        } else {
            return error.UnknownArgument;
        }
    }

    if (selected_ops.items.len == 0) {
        try appendDefaultDirectOps(allocator, &selected_ops);
        if (options.include_bytecode) try appendBytecodeOps(allocator, &selected_ops);
    }
    if (selected_boundaries.items.len == 0) {
        try selected_boundaries.append(allocator, .zig);
        try selected_boundaries.append(allocator, .evmc);
    }

    if (!options.no_header) {
        try stdout.print("suite,op,boundary,repeat,iterations,elapsed_ns,ns_per_op,host_calls\n", .{});
    }

    for (selected_ops.items) |op| {
        if (host_boundary.isBytecodeOperation(op)) {
            if (options.explicit_boundary and !containsBoundary(selected_boundaries.items, .zig)) {
                return error.InvalidBoundaryForBytecodeOp;
            }
            try runSamples(allocator, stdout, options, op, .zig);
            continue;
        }

        for (selected_boundaries.items) |boundary| {
            try runSamples(allocator, stdout, options, op, boundary);
        }
    }

    try stdout.flush();
}

fn printUsage() void {
    std.debug.print(
        \\Usage:
        \\  zig build host-matrix -- [options]
        \\
        \\Options:
        \\  --op <operation>         operation filter; repeatable, default all direct host ops
        \\  --boundary <zig|evmc>   direct host boundary filter; repeatable, default both
        \\  --iterations, -n <n>    operation count per sample, default 100000
        \\  --repeats <n>           printed samples per row key, default 5
        \\  --warmups <n>           unprinted samples before repeats, default 1
        \\  --include-bytecode      add bytecode-sload and bytecode-sstore rows
        \\  --spec <name>           fork spec for bytecode operations, default latest
        \\  --no-header             omit CSV header
        \\
    , .{});
}

fn runSamples(
    allocator: std.mem.Allocator,
    stdout: anytype,
    options: Options,
    op: Operation,
    boundary: Boundary,
) !void {
    var warmup_index: usize = 0;
    while (warmup_index < options.warmups) : (warmup_index += 1) {
        _ = try host_boundary.run(allocator, .{
            .op = op,
            .boundary = boundary,
            .iterations = options.iterations,
            .spec = options.spec,
        });
    }

    var repeat_index: usize = 0;
    while (repeat_index < options.repeats) : (repeat_index += 1) {
        const measurement = try host_boundary.run(allocator, .{
            .op = op,
            .boundary = boundary,
            .iterations = options.iterations,
            .spec = options.spec,
        });
        const ns_per_op = @as(f64, @floatFromInt(measurement.elapsed_ns)) /
            @as(f64, @floatFromInt(options.iterations));
        try stdout.print(
            "host_boundary,{s},{s},{d},{d},{d},{d:.3},{d}\n",
            .{
                @tagName(op),
                measurement.boundary,
                repeat_index + 1,
                options.iterations,
                measurement.elapsed_ns,
                ns_per_op,
                measurement.counters.total(),
            },
        );
    }
}

fn appendDefaultDirectOps(allocator: std.mem.Allocator, ops: *std.ArrayList(Operation)) !void {
    const defaults = [_]Operation{
        .host_storage_read,
        .host_storage_write,
        .host_access_storage,
        .host_account_exists,
        .host_balance,
        .host_code_size,
        .host_code_hash,
        .host_copy_code,
        .host_tx_context,
        .host_call,
        .host_log,
    };
    try ops.appendSlice(allocator, &defaults);
}

fn appendBytecodeOps(allocator: std.mem.Allocator, ops: *std.ArrayList(Operation)) !void {
    try ops.append(allocator, .bytecode_sload);
    try ops.append(allocator, .bytecode_sstore);
}

fn containsBoundary(boundaries: []const Boundary, needle: Boundary) bool {
    for (boundaries) |boundary| {
        if (boundary == needle) return true;
    }
    return false;
}

fn parseUsize(value: []const u8) !usize {
    return std.fmt.parseUnsigned(usize, value, 10);
}

test "default matrix operations are direct host operations" {
    var ops: std.ArrayList(Operation) = .empty;
    defer ops.deinit(std.testing.allocator);
    try appendDefaultDirectOps(std.testing.allocator, &ops);

    try std.testing.expect(ops.items.len > 0);
    for (ops.items) |op| {
        try std.testing.expect(!host_boundary.isBytecodeOperation(op));
    }
}

test "boundary lookup finds selected boundary" {
    const boundaries = [_]Boundary{ .zig, .evmc };
    try std.testing.expect(containsBoundary(&boundaries, .evmc));
}
