const std = @import("std");
const ssz = @import("ssz");
const zbench = @import("zbench");
const phase0 = @import("phase0.zig");

const default_time_ms = 100;
const default_max_iterations = 100_000;
const list_limit = 1_048_576;

const Header = phase0.BeaconBlockHeader;
const HeaderSsz = Header.Ssz;
const U64List = ssz.List(u64, list_limit);

const Operation = enum {
    encode,
    decode,
    hash_tree_root,
};

const Case = enum {
    encode_bool,
    encode_u64,
    encode_bytes32,
    encode_header,
    encode_list_u64_1k,
    encode_list_u64_100k,
    encode_alloc_beacon_state_16k,
    encode_reuse_beacon_state_16k,
    encode_alloc_beacon_state_100k,
    encode_reuse_beacon_state_100k,
    decode_bool,
    decode_u64,
    decode_bytes32,
    decode_header,
    decode_list_u64_1k,
    decode_list_u64_100k,
    decode_beacon_state_16k,
    decode_beacon_state_100k,
    hash_tree_root_bool,
    hash_tree_root_u64,
    hash_tree_root_bytes32,
    hash_tree_root_header,
};

const CaseInfo = struct {
    operation: Operation,
    name: []const u8,
    boundary: []const u8,
    batch_ops: usize,
    items: usize,
    encoded_bytes: usize,
};

const SelectedCase = struct {
    case: Case,
    encoded_bytes: usize,
};

const Options = struct {
    filter: ?[]const u8 = null,
    time_ms: u64 = default_time_ms,
    max_iterations: u32 = default_max_iterations,
    no_header: bool = false,
};

const Fixtures = struct {
    allocator: std.mem.Allocator,
    encode_out: []u8,
    list_1k: []u64,
    list_100k: []u64,
    encoded_list_1k: []u8,
    encoded_list_100k: []u8,
    encoded_bool: [1]u8,
    encoded_u64: [8]u8,
    encoded_bytes32: [32]u8,
    encoded_header: [112]u8,
    beacon_state_16k: phase0.Fixture,
    beacon_state_100k: phase0.Fixture,
    encoded_beacon_state_16k: []u8,
    encoded_beacon_state_100k: []u8,

    fn init(allocator: std.mem.Allocator) !Fixtures {
        const encode_out = try allocator.alloc(u8, 800_000);
        errdefer allocator.free(encode_out);
        const list_1k = try listValues(allocator, 1_000);
        errdefer allocator.free(list_1k);
        const list_100k = try listValues(allocator, 100_000);
        errdefer allocator.free(list_100k);
        const encoded_list_1k = try allocator.alloc(u8, 8_000);
        errdefer allocator.free(encoded_list_1k);
        const encoded_list_100k = try allocator.alloc(u8, 800_000);
        errdefer allocator.free(encoded_list_100k);
        var beacon_state_16k = try phase0.Fixture.init(allocator, 16_384);
        errdefer beacon_state_16k.deinit();
        var beacon_state_100k = try phase0.Fixture.init(allocator, 100_000);
        errdefer beacon_state_100k.deinit();
        const beacon_state_16k_len = try phase0.BeaconState.Ssz.encodedLen(beacon_state_16k.state);
        const encoded_beacon_state_16k = try allocator.alloc(u8, beacon_state_16k_len);
        errdefer allocator.free(encoded_beacon_state_16k);
        const beacon_state_100k_len = try phase0.BeaconState.Ssz.encodedLen(beacon_state_100k.state);
        const encoded_beacon_state_100k = try allocator.alloc(u8, beacon_state_100k_len);
        errdefer allocator.free(encoded_beacon_state_100k);

        var fixtures = Fixtures{
            .allocator = allocator,
            .encode_out = encode_out,
            .list_1k = list_1k,
            .list_100k = list_100k,
            .encoded_list_1k = encoded_list_1k,
            .encoded_list_100k = encoded_list_100k,
            .encoded_bool = undefined,
            .encoded_u64 = undefined,
            .encoded_bytes32 = undefined,
            .encoded_header = undefined,
            .beacon_state_16k = beacon_state_16k,
            .beacon_state_100k = beacon_state_100k,
            .encoded_beacon_state_16k = encoded_beacon_state_16k,
            .encoded_beacon_state_100k = encoded_beacon_state_100k,
        };
        _ = try ssz.Fixed(bool).encode(&fixtures.encoded_bool, true);
        _ = try ssz.Fixed(u64).encode(&fixtures.encoded_u64, 0x0123456789abcdef);
        _ = try ssz.Fixed([32]u8).encode(&fixtures.encoded_bytes32, bytes32Value());
        _ = try HeaderSsz.encode(&fixtures.encoded_header, headerValue());
        _ = try U64List.encode(fixtures.encoded_list_1k, fixtures.list_1k);
        _ = try U64List.encode(fixtures.encoded_list_100k, fixtures.list_100k);
        _ = try phase0.BeaconState.Ssz.encode(
            fixtures.encoded_beacon_state_16k,
            fixtures.beacon_state_16k.state,
        );
        _ = try phase0.BeaconState.Ssz.encode(
            fixtures.encoded_beacon_state_100k,
            fixtures.beacon_state_100k.state,
        );
        return fixtures;
    }

    fn deinit(self: *Fixtures) void {
        self.allocator.free(self.encoded_beacon_state_100k);
        self.allocator.free(self.encoded_beacon_state_16k);
        self.beacon_state_100k.deinit();
        self.beacon_state_16k.deinit();
        self.allocator.free(self.encoded_list_100k);
        self.allocator.free(self.encoded_list_1k);
        self.allocator.free(self.list_100k);
        self.allocator.free(self.list_1k);
        self.allocator.free(self.encode_out);
        self.* = undefined;
    }
};

const CaseContext = struct {
    case: Case,
    batch_ops: usize,
    fixtures: *Fixtures,

    pub fn run(self: *const CaseContext, allocator: std.mem.Allocator) void {
        self.runFallible(allocator) catch |err| {
            std.debug.panic("SSZ benchmark failed: {s}", .{@errorName(err)});
        };
    }

    fn runFallible(self: *const CaseContext, allocator: std.mem.Allocator) !void {
        const fixtures = self.fixtures;
        return switch (self.case) {
            .encode_bool => benchEncode(ssz.Fixed(bool), fixtures.encode_out, true, self.batch_ops),
            .encode_u64 => benchEncode(ssz.Fixed(u64), fixtures.encode_out, @as(u64, 0x0123456789abcdef), self.batch_ops),
            .encode_bytes32 => benchEncode(ssz.Fixed([32]u8), fixtures.encode_out, bytes32Value(), self.batch_ops),
            .encode_header => benchEncode(HeaderSsz, fixtures.encode_out, headerValue(), self.batch_ops),
            .encode_list_u64_1k => benchEncode(U64List, fixtures.encode_out, fixtures.list_1k, self.batch_ops),
            .encode_list_u64_100k => benchEncode(U64List, fixtures.encode_out, fixtures.list_100k, self.batch_ops),
            .encode_alloc_beacon_state_16k => benchEncodeAlloc(
                phase0.BeaconState.Ssz,
                allocator,
                fixtures.beacon_state_16k.state,
                self.batch_ops,
            ),
            .encode_reuse_beacon_state_16k => benchEncode(
                phase0.BeaconState.Ssz,
                fixtures.encoded_beacon_state_16k,
                fixtures.beacon_state_16k.state,
                self.batch_ops,
            ),
            .encode_alloc_beacon_state_100k => benchEncodeAlloc(
                phase0.BeaconState.Ssz,
                allocator,
                fixtures.beacon_state_100k.state,
                self.batch_ops,
            ),
            .encode_reuse_beacon_state_100k => benchEncode(
                phase0.BeaconState.Ssz,
                fixtures.encoded_beacon_state_100k,
                fixtures.beacon_state_100k.state,
                self.batch_ops,
            ),
            .decode_bool => benchDecode(ssz.Fixed(bool), allocator, &fixtures.encoded_bool, self.batch_ops),
            .decode_u64 => benchDecode(ssz.Fixed(u64), allocator, &fixtures.encoded_u64, self.batch_ops),
            .decode_bytes32 => benchDecode(ssz.Fixed([32]u8), allocator, &fixtures.encoded_bytes32, self.batch_ops),
            .decode_header => benchDecode(HeaderSsz, allocator, &fixtures.encoded_header, self.batch_ops),
            .decode_list_u64_1k => benchDecode(U64List, allocator, fixtures.encoded_list_1k, self.batch_ops),
            .decode_list_u64_100k => benchDecode(U64List, allocator, fixtures.encoded_list_100k, self.batch_ops),
            .decode_beacon_state_16k => benchDecode(
                phase0.BeaconState.Ssz,
                allocator,
                fixtures.encoded_beacon_state_16k,
                self.batch_ops,
            ),
            .decode_beacon_state_100k => benchDecode(
                phase0.BeaconState.Ssz,
                allocator,
                fixtures.encoded_beacon_state_100k,
                self.batch_ops,
            ),
            .hash_tree_root_bool => benchRoot(ssz.Fixed(bool), true, self.batch_ops),
            .hash_tree_root_u64 => benchRoot(ssz.Fixed(u64), @as(u64, 0x0123456789abcdef), self.batch_ops),
            .hash_tree_root_bytes32 => benchRoot(ssz.Fixed([32]u8), bytes32Value(), self.batch_ops),
            .hash_tree_root_header => benchRoot(HeaderSsz, headerValue(), self.batch_ops),
        };
    }
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const options = try parseOptions(init, allocator);
    defer if (options.filter) |filter| allocator.free(filter);

    var fixtures = try Fixtures.init(allocator);
    defer fixtures.deinit();

    var contexts: [std.enums.values(Case).len]CaseContext = undefined;
    var selected: std.ArrayList(SelectedCase) = .empty;
    defer selected.deinit(allocator);

    const time_budget_ns = try std.math.mul(u64, options.time_ms, std.time.ns_per_ms);
    var bench = zbench.Benchmark.init(allocator, .{
        .max_iterations = options.max_iterations,
        .time_budget_ns = time_budget_ns,
    });
    defer bench.deinit();

    for (std.enums.values(Case)) |case| {
        const info = caseInfo(case);
        if (!matchesFilter(info, options.filter)) continue;
        const index = @intFromEnum(case);
        contexts[index] = .{ .case = case, .batch_ops = info.batch_ops, .fixtures = &fixtures };
        const context: *const CaseContext = &contexts[index];
        try bench.addParam(info.name, context, .{});
        try selected.append(allocator, .{
            .case = case,
            .encoded_bytes = caseEncodedBytes(case, &fixtures),
        });
    }

    var stdout_buffer: [8192]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(init.io, &stdout_buffer);
    const stdout = &stdout_writer.interface;
    if (!options.no_header) {
        try stdout.writeAll(
            "suite,operation,case,boundary,items,encoded_bytes,batch_ops,samples,mean_batch_ns,mean_ns_per_op,median_ns_per_op,min_ns_per_op,max_ns_per_op,p99_ns_per_op,median_mib_per_s\n",
        );
    }

    var iterator = try bench.iterator();
    errdefer iterator.abort();
    var result_index: usize = 0;
    while (try iterator.next(init.io)) |step| switch (step) {
        .progress => {},
        .result => |result| {
            defer result.deinit();
            try printResult(stdout, selected.items[result_index], result.readings.timings_ns);
            result_index += 1;
        },
    };
    try stdout.flush();
}

fn printResult(stdout: anytype, selected: SelectedCase, timings: []u64) !void {
    const info = caseInfo(selected.case);
    var total: u128 = 0;
    var min: u64 = std.math.maxInt(u64);
    var max: u64 = 0;
    for (timings) |timing| {
        total += timing;
        min = @min(min, timing);
        max = @max(max, timing);
    }
    const mean_batch_ns = @as(f64, @floatFromInt(total)) / @as(f64, @floatFromInt(timings.len));
    const mean_ns_per_op = mean_batch_ns / @as(f64, @floatFromInt(info.batch_ops));
    std.sort.heap(u64, timings, {}, std.sort.asc(u64));
    const median_batch_ns = if (timings.len % 2 == 0)
        (@as(f64, @floatFromInt(timings[timings.len / 2 - 1])) +
            @as(f64, @floatFromInt(timings[timings.len / 2]))) / 2.0
    else
        @as(f64, @floatFromInt(timings[timings.len / 2]));
    const median_ns_per_op = median_batch_ns / @as(f64, @floatFromInt(info.batch_ops));
    const min_ns_per_op = @as(f64, @floatFromInt(min)) / @as(f64, @floatFromInt(info.batch_ops));
    const max_ns_per_op = @as(f64, @floatFromInt(max)) / @as(f64, @floatFromInt(info.batch_ops));
    const p99_ns_per_op = @as(f64, @floatFromInt(timings[timings.len * 99 / 100])) /
        @as(f64, @floatFromInt(info.batch_ops));
    const mib_per_s = @as(f64, @floatFromInt(selected.encoded_bytes)) /
        (1024.0 * 1024.0) / (median_ns_per_op / std.time.ns_per_s);
    try stdout.print(
        "ssz,{s},{s},{s},{d},{d},{d},{d},{d:.3},{d:.3},{d:.3},{d:.3},{d:.3},{d:.3},{d:.3}\n",
        .{
            @tagName(info.operation),
            info.name,
            info.boundary,
            info.items,
            selected.encoded_bytes,
            info.batch_ops,
            timings.len,
            mean_batch_ns,
            mean_ns_per_op,
            median_ns_per_op,
            min_ns_per_op,
            max_ns_per_op,
            p99_ns_per_op,
            mib_per_s,
        },
    );
}

fn benchEncode(comptime Codec: type, out: []u8, value: Codec.Value, operations: usize) !void {
    var input = value;
    for (0..operations) |_| {
        std.mem.doNotOptimizeAway(&input);
        var encoded = try Codec.encode(out, input);
        std.mem.doNotOptimizeAway(&encoded);
    }
}

fn benchEncodeAlloc(
    comptime Codec: type,
    allocator: std.mem.Allocator,
    value: Codec.Value,
    operations: usize,
) !void {
    var input = value;
    for (0..operations) |_| {
        std.mem.doNotOptimizeAway(&input);
        var encoded = try ssz.encodeAlloc(Codec, allocator, input);
        std.mem.doNotOptimizeAway(&encoded);
        allocator.free(encoded);
    }
}

fn benchDecode(
    comptime Codec: type,
    allocator: std.mem.Allocator,
    bytes: []const u8,
    operations: usize,
) !void {
    for (0..operations) |_| {
        std.mem.doNotOptimizeAway(bytes.ptr);
        if (Codec.requires_allocator) {
            var decoded = try Codec.decodeAlloc(allocator, bytes);
            std.mem.doNotOptimizeAway(&decoded);
            Codec.deinit(allocator, &decoded);
        } else {
            var decoded = try Codec.decode(bytes);
            std.mem.doNotOptimizeAway(&decoded);
        }
    }
}

fn benchRoot(comptime Codec: type, value: Codec.Value, operations: usize) !void {
    var input = value;
    for (0..operations) |_| {
        std.mem.doNotOptimizeAway(&input);
        var root = try ssz.hashTreeRoot(Codec, input);
        std.mem.doNotOptimizeAway(&root);
    }
}

fn matchesFilter(info: CaseInfo, filter: ?[]const u8) bool {
    const value = filter orelse return true;
    return std.mem.indexOf(u8, info.name, value) != null or
        std.mem.indexOf(u8, @tagName(info.operation), value) != null or
        std.mem.indexOf(u8, info.boundary, value) != null;
}

fn caseEncodedBytes(case: Case, fixtures: *const Fixtures) usize {
    return switch (case) {
        .encode_alloc_beacon_state_16k,
        .encode_reuse_beacon_state_16k,
        .decode_beacon_state_16k,
        => fixtures.encoded_beacon_state_16k.len,
        .encode_alloc_beacon_state_100k,
        .encode_reuse_beacon_state_100k,
        .decode_beacon_state_100k,
        => fixtures.encoded_beacon_state_100k.len,
        else => caseInfo(case).encoded_bytes,
    };
}

fn parseOptions(init: std.process.Init, allocator: std.mem.Allocator) !Options {
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, allocator);
    defer args.deinit();
    _ = args.next();

    var options = Options{};
    while (args.next()) |arg_z| {
        const arg = arg_z[0..arg_z.len];
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            printUsage();
            std.process.exit(0);
        } else if (std.mem.eql(u8, arg, "--filter")) {
            if (options.filter != null) return error.DuplicateFilter;
            options.filter = try allocator.dupe(u8, args.next() orelse return error.MissingFilter);
        } else if (stripPrefix(arg, "--filter=")) |value| {
            if (options.filter != null) return error.DuplicateFilter;
            options.filter = try allocator.dupe(u8, value);
        } else if (std.mem.eql(u8, arg, "--time-ms") or std.mem.eql(u8, arg, "--sample-ms")) {
            options.time_ms = try parseNonZeroU64(args.next() orelse return error.MissingTimeMs);
        } else if (stripPrefix(arg, "--time-ms=")) |value| {
            options.time_ms = try parseNonZeroU64(value);
        } else if (stripPrefix(arg, "--sample-ms=")) |value| {
            options.time_ms = try parseNonZeroU64(value);
        } else if (std.mem.eql(u8, arg, "--max-iterations")) {
            options.max_iterations = try parseNonZeroU32(args.next() orelse return error.MissingMaxIterations);
        } else if (stripPrefix(arg, "--max-iterations=")) |value| {
            options.max_iterations = try parseNonZeroU32(value);
        } else if (std.mem.eql(u8, arg, "--no-header")) {
            options.no_header = true;
        } else {
            return error.UnknownArgument;
        }
    }
    return options;
}

fn printUsage() void {
    std.debug.print(
        \\Usage:
        \\  zig build bench -- [options]
        \\
        \\Options:
        \\  --filter <substring>    select case or operation names
        \\  --time-ms <n>          zbench time budget per case, default 100
        \\  --max-iterations <n>   maximum zbench samples, default 100000
        \\  --no-header            omit the CSV header
        \\
    , .{});
}

fn caseInfo(case: Case) CaseInfo {
    return switch (case) {
        .encode_bool => .{ .operation = .encode, .name = "bool", .boundary = "caller_buffer", .batch_ops = 4_096, .items = 1, .encoded_bytes = 1 },
        .encode_u64 => .{ .operation = .encode, .name = "u64", .boundary = "caller_buffer", .batch_ops = 4_096, .items = 1, .encoded_bytes = 8 },
        .encode_bytes32 => .{ .operation = .encode, .name = "bytes32", .boundary = "caller_buffer", .batch_ops = 4_096, .items = 1, .encoded_bytes = 32 },
        .encode_header => .{ .operation = .encode, .name = "beacon_block_header", .boundary = "caller_buffer", .batch_ops = 1_024, .items = 1, .encoded_bytes = 112 },
        .encode_list_u64_1k => .{ .operation = .encode, .name = "list_u64_1k", .boundary = "caller_buffer", .batch_ops = 256, .items = 1_000, .encoded_bytes = 8_000 },
        .encode_list_u64_100k => .{ .operation = .encode, .name = "list_u64_100k", .boundary = "caller_buffer", .batch_ops = 4, .items = 100_000, .encoded_bytes = 800_000 },
        .encode_alloc_beacon_state_16k => .{ .operation = .encode, .name = "beacon_state_phase0_16k", .boundary = "allocated_output", .batch_ops = 1, .items = 16_384, .encoded_bytes = 0 },
        .encode_reuse_beacon_state_16k => .{ .operation = .encode, .name = "beacon_state_phase0_16k", .boundary = "caller_buffer", .batch_ops = 1, .items = 16_384, .encoded_bytes = 0 },
        .encode_alloc_beacon_state_100k => .{ .operation = .encode, .name = "beacon_state_phase0_100k", .boundary = "allocated_output", .batch_ops = 1, .items = 100_000, .encoded_bytes = 0 },
        .encode_reuse_beacon_state_100k => .{ .operation = .encode, .name = "beacon_state_phase0_100k", .boundary = "caller_buffer", .batch_ops = 1, .items = 100_000, .encoded_bytes = 0 },
        .decode_bool => .{ .operation = .decode, .name = "bool", .boundary = "borrowed_input", .batch_ops = 4_096, .items = 1, .encoded_bytes = 1 },
        .decode_u64 => .{ .operation = .decode, .name = "u64", .boundary = "borrowed_input", .batch_ops = 4_096, .items = 1, .encoded_bytes = 8 },
        .decode_bytes32 => .{ .operation = .decode, .name = "bytes32", .boundary = "borrowed_input", .batch_ops = 4_096, .items = 1, .encoded_bytes = 32 },
        .decode_header => .{ .operation = .decode, .name = "beacon_block_header", .boundary = "borrowed_input", .batch_ops = 1_024, .items = 1, .encoded_bytes = 112 },
        .decode_list_u64_1k => .{ .operation = .decode, .name = "list_u64_1k", .boundary = "owned_alloc", .batch_ops = 256, .items = 1_000, .encoded_bytes = 8_000 },
        .decode_list_u64_100k => .{ .operation = .decode, .name = "list_u64_100k", .boundary = "owned_alloc", .batch_ops = 4, .items = 100_000, .encoded_bytes = 800_000 },
        .decode_beacon_state_16k => .{ .operation = .decode, .name = "beacon_state_phase0_16k", .boundary = "owned_alloc", .batch_ops = 1, .items = 16_384, .encoded_bytes = 0 },
        .decode_beacon_state_100k => .{ .operation = .decode, .name = "beacon_state_phase0_100k", .boundary = "owned_alloc", .batch_ops = 1, .items = 100_000, .encoded_bytes = 0 },
        .hash_tree_root_bool => .{ .operation = .hash_tree_root, .name = "bool", .boundary = "stdlib_sha256", .batch_ops = 4_096, .items = 1, .encoded_bytes = 1 },
        .hash_tree_root_u64 => .{ .operation = .hash_tree_root, .name = "u64", .boundary = "stdlib_sha256", .batch_ops = 4_096, .items = 1, .encoded_bytes = 8 },
        .hash_tree_root_bytes32 => .{ .operation = .hash_tree_root, .name = "bytes32", .boundary = "stdlib_sha256", .batch_ops = 4_096, .items = 1, .encoded_bytes = 32 },
        .hash_tree_root_header => .{ .operation = .hash_tree_root, .name = "beacon_block_header", .boundary = "stdlib_sha256", .batch_ops = 64, .items = 1, .encoded_bytes = 112 },
    };
}

fn listValues(allocator: std.mem.Allocator, count: usize) ![]u64 {
    const values = try allocator.alloc(u64, count);
    for (values, 0..) |*value, index| value.* = @intCast(index);
    return values;
}

fn bytes32Value() [32]u8 {
    var value: [32]u8 = undefined;
    for (&value, 0..) |*byte, index| byte.* = @intCast(index);
    return value;
}

fn headerValue() Header {
    return .{
        .slot = 123_456,
        .proposer_index = 42,
        .parent_root = [_]u8{0x11} ** 32,
        .state_root = [_]u8{0x22} ** 32,
        .body_root = [_]u8{0x33} ** 32,
    };
}

fn stripPrefix(value: []const u8, prefix: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, value, prefix)) return null;
    return value[prefix.len..];
}

fn parseNonZeroU64(value: []const u8) !u64 {
    const parsed = std.fmt.parseInt(u64, value, 10) catch return error.InvalidInteger;
    if (parsed == 0) return error.InvalidInteger;
    return parsed;
}

fn parseNonZeroU32(value: []const u8) !u32 {
    const parsed = std.fmt.parseInt(u32, value, 10) catch return error.InvalidInteger;
    if (parsed == 0) return error.InvalidInteger;
    return parsed;
}

test "case batch sizes match benchmark functions" {
    try std.testing.expectEqual(@as(usize, 4_096), caseInfo(.encode_u64).batch_ops);
    try std.testing.expectEqual(@as(usize, 4), caseInfo(.decode_list_u64_100k).batch_ops);
    try std.testing.expectEqual(@as(usize, 64), caseInfo(.hash_tree_root_header).batch_ops);
}
