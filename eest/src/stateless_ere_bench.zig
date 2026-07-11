const std = @import("std");
const evmz = @import("evmz");
const fixture_common = @import("fixture.zig");
const ere_io = @import("stateless_ere_io.zig");

const JsonValue = fixture_common.JsonValue;
const asArray = fixture_common.asArray;
const asObject = fixture_common.asObject;
const jsonString = fixture_common.jsonString;
const parseBytesFromValue = fixture_common.parseBytesFromValue;

const safe_file_stem_max_len = 220;
const guest_heap_capacity_bytes = 16 * 1024 * 1024;
const max_benchmark_input_bytes = 512 * 1024 * 1024;

pub const Options = struct {
    test_filter: ?[]const u8 = null,
    limit: usize = 0,
    output_folder: []const u8 = "zkevm-metrics",
    engine: Engine = .native,
    ziskemu_path: ?[]const u8 = null,
    zisk_elf_path: ?[]const u8 = null,
    zisk_work_dir: []const u8 = "zig-out/zkevm-ere-bench",
    zisk_max_steps: []const u8 = "1000000",
};

pub const Engine = enum {
    native,
    zisk,

    pub fn label(self: Engine) []const u8 {
        return switch (self) {
            .native => "evmz-native",
            .zisk => "zisk-ziskemu",
        };
    }
};

pub const Summary = struct {
    files: usize = 0,
    fixtures: usize = 0,
    benchmarked: usize = 0,
    failed: usize = 0,
    skipped: usize = 0,

    pub fn add(self: *Summary, other: Summary) void {
        self.files += other.files;
        self.fixtures += other.fixtures;
        self.benchmarked += other.benchmarked;
        self.failed += other.failed;
        self.skipped += other.skipped;
    }
};

pub const SelectionLimit = struct {
    remaining: ?usize = null,

    pub fn take(self: *SelectionLimit) bool {
        if (self.remaining) |remaining| {
            if (remaining == 0) return false;
            self.remaining = remaining - 1;
        }
        return true;
    }

    pub fn exhausted(self: SelectionLimit) bool {
        return if (self.remaining) |remaining| remaining == 0 else false;
    }
};

pub fn runRoot(io: std.Io, allocator: std.mem.Allocator, path: []const u8, options: Options, limit: *SelectionLimit) !Summary {
    var dir = std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch |err| switch (err) {
        error.NotDir, error.FileNotFound => {
            const input_root = std.fs.path.dirname(path) orelse ".";
            return runFile(io, allocator, path, input_root, options, limit);
        },
        else => return err,
    };
    defer dir.close(io);

    return runDir(io, allocator, path, path, options, limit);
}

fn runDir(
    io: std.Io,
    allocator: std.mem.Allocator,
    path: []const u8,
    input_root: []const u8,
    options: Options,
    limit: *SelectionLimit,
) !Summary {
    var dir = try std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true });
    defer dir.close(io);

    var summary = Summary{};
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (limit.exhausted()) break;

        const child = try std.fs.path.join(allocator, &.{ path, entry.name });
        defer allocator.free(child);

        switch (entry.kind) {
            .directory => summary.add(try runDir(io, allocator, child, input_root, options, limit)),
            .file => {
                if (std.mem.endsWith(u8, entry.name, ".json")) {
                    summary.add(try runFile(io, allocator, child, input_root, options, limit));
                }
            },
            else => {},
        }
    }

    return summary;
}

pub fn runFile(
    io: std.Io,
    allocator: std.mem.Allocator,
    path: []const u8,
    input_root: []const u8,
    options: Options,
    limit: *SelectionLimit,
) !Summary {
    const bytes = try readBenchmarkInputFile(io, allocator, path);
    defer allocator.free(bytes);

    var summary = try runSlice(io, allocator, path, input_root, bytes, options, limit);
    summary.files = 1;
    return summary;
}

fn readBenchmarkInputFile(io: std.Io, allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return readBenchmarkInputPath(io, allocator, path) catch |err| switch (err) {
        error.FileNotFound => try readRootedBenchmarkInputPath(io, allocator, path),
        else => return err,
    };
}

fn readRootedBenchmarkInputPath(io: std.Io, allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    if (path.len == 0 or path[0] == '.' or path[0] == '/') return error.FileNotFound;
    const absolute = try std.fmt.allocPrint(allocator, "/{s}", .{path});
    defer allocator.free(absolute);
    return readBenchmarkInputPath(io, allocator, absolute);
}

fn readBenchmarkInputPath(io: std.Io, allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const fd = try std.posix.openat(std.posix.AT.FDCWD, path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    const file = std.Io.File{ .handle = fd, .flags = .{ .nonblocking = false } };
    defer file.close(io);

    var bytes: std.ArrayList(u8) = .empty;
    errdefer bytes.deinit(allocator);

    var buffer: [64 * 1024]u8 = undefined;
    while (true) {
        const read_len = try std.posix.read(fd, buffer[0..]);
        if (read_len == 0) break;
        if (bytes.items.len > max_benchmark_input_bytes - read_len) return error.FileTooBig;
        try bytes.appendSlice(allocator, buffer[0..read_len]);
    }

    return bytes.toOwnedSlice(allocator);
}

pub fn runSlice(
    io: std.Io,
    allocator: std.mem.Allocator,
    path: []const u8,
    input_root: []const u8,
    bytes: []const u8,
    options: Options,
    limit: *SelectionLimit,
) !Summary {
    var fixtures = try loadEestBenchmarkFixtures(allocator, path, input_root, bytes, options);
    defer {
        for (fixtures.items) |*fixture| fixture.deinit(allocator);
        fixtures.deinit(allocator);
    }

    var summary = Summary{};
    for (fixtures.items) |*fixture| {
        if (!limit.take()) break;
        summary.fixtures += 1;

        var execution = executeFixture(io, allocator, fixture, options) catch |err| blk: {
            const reason = try std.fmt.allocPrint(allocator, "evmz bridge failed: {s}", .{@errorName(err)});
            break :blk ExecutionMetrics{ .crashed = .{ .reason = reason } };
        };
        defer execution.deinit(allocator);

        const output_path = try metricOutputPath(allocator, options.output_folder, options.engine, fixture.name);
        defer allocator.free(output_path);
        try writeBenchmarkRun(io, allocator, output_path, fixture, execution);

        switch (execution) {
            .success => |success| {
                summary.benchmarked += 1;
                if (!success.output_matched) summary.failed += 1;
            },
            .crashed => summary.failed += 1,
        }
    }

    if (fixtures.items.len == 0) summary.skipped += 1;
    return summary;
}

const Fixture = struct {
    name: []u8,
    original_test_name: []u8,
    source_path: []u8,
    block_index: usize,
    network: []u8,
    chain_id: u64,
    block_number: ?u64,
    block_used_gas: ?u64,
    stateless_input_bytes: []u8,
    stateless_output_bytes: []u8,

    fn metadata(self: Fixture) Metadata {
        return .{
            .fixture_format = "eest",
            .original_test_name = self.original_test_name,
            .source_path = self.source_path,
            .block_index = self.block_index,
            .network = self.network,
            .chain_id = self.chain_id,
            .block_number = self.block_number,
            .block_used_gas = self.block_used_gas,
        };
    }

    fn deinit(self: *Fixture, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.original_test_name);
        allocator.free(self.source_path);
        allocator.free(self.network);
        allocator.free(self.stateless_input_bytes);
        allocator.free(self.stateless_output_bytes);
    }
};

const Metadata = struct {
    fixture_format: []const u8,
    original_test_name: []const u8,
    source_path: []const u8,
    block_index: usize,
    network: []const u8,
    chain_id: u64,
    block_number: ?u64,
    block_used_gas: ?u64,
};

fn loadEestBenchmarkFixtures(
    allocator: std.mem.Allocator,
    path: []const u8,
    input_root: []const u8,
    bytes: []const u8,
    options: Options,
) !std.ArrayList(Fixture) {
    var parsed = try std.json.parseFromSlice(JsonValue, allocator, bytes, .{ .parse_numbers = false });
    defer parsed.deinit();

    const source_path = try relativeSourcePath(allocator, path, input_root);
    defer allocator.free(source_path);

    var root = asObject(parsed.value) orelse return error.ExpectedObject;
    var fixtures: std.ArrayList(Fixture) = .empty;
    errdefer {
        for (fixtures.items) |*fixture| fixture.deinit(allocator);
        fixtures.deinit(allocator);
    }

    var fixture_names = std.StringHashMap(void).init(allocator);
    defer fixture_names.deinit();

    var it = root.iterator();
    while (it.next()) |entry| {
        const test_name = entry.key_ptr.*;
        if (options.test_filter) |needle| {
            if (std.mem.indexOf(u8, test_name, needle) == null) continue;
        }

        const test_obj = asObject(entry.value_ptr.*) orelse return error.MalformedFixture;
        const network = jsonString(test_obj.get("network") orelse return error.MalformedFixture) orelse return error.MalformedFixture;
        const config = asObject(test_obj.get("config") orelse return error.MalformedFixture) orelse return error.MalformedFixture;
        const chain_id = try parseJsonU64Value(config.get("chainid") orelse return error.MalformedFixture);
        const blocks = asArray(test_obj.get("blocks") orelse return error.MalformedFixture) orelse return error.MalformedFixture;

        for (blocks.items, 0..) |block_value, block_index| {
            const block = asObject(block_value) orelse return error.MalformedFixture;
            const input_value = block.get("statelessInputBytes") orelse continue;
            const input = try parseBytesFromValue(allocator, input_value);
            errdefer allocator.free(input);
            if (input.len == 0) {
                allocator.free(input);
                continue;
            }

            const output_value = block.get("statelessOutputBytes") orelse return error.MissingStatelessOutputBytes;
            const output = try parseBytesFromValue(allocator, output_value);
            errdefer allocator.free(output);

            const header = if (block.get("blockHeader")) |header_value|
                asObject(header_value) orelse return error.MalformedFixture
            else
                null;

            const block_number_value = if (header) |header_obj|
                header_obj.get("number") orelse block.get("blocknumber")
            else
                block.get("blocknumber");
            const block_used_gas_value = if (header) |header_obj| header_obj.get("gasUsed") else null;

            try fixtures.append(allocator, .{
                .name = try uniqueFixtureName(allocator, test_name, block_index, &fixture_names),
                .original_test_name = try allocator.dupe(u8, test_name),
                .source_path = try allocator.dupe(u8, source_path),
                .block_index = block_index,
                .network = try allocator.dupe(u8, network),
                .chain_id = chain_id,
                .block_number = try parseOptionalJsonU64(block_number_value),
                .block_used_gas = try parseOptionalJsonU64(block_used_gas_value),
                .stateless_input_bytes = input,
                .stateless_output_bytes = output,
            });
        }
    }

    return fixtures;
}

const ExecutionMetrics = union(enum) {
    success: ExecutionSuccess,
    crashed: CrashInfo,

    fn deinit(self: *ExecutionMetrics, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .crashed => |crash| allocator.free(crash.reason),
            .success => {},
        }
    }
};

const ExecutionSuccess = struct {
    output_matched: bool,
    total_num_cycles: u64,
    region_cycles: EmptyObject = .{},
    execution_duration: DurationJson,
    heap: ?HeapMetrics = null,
};

const EmptyObject = struct {};
const CrashInfo = struct { reason: []const u8 };
const DurationJson = struct { secs: u64, nanos: u32 };
const HeapMetrics = struct {
    allocator: []const u8 = "fixed-buffer",
    capacity_bytes: u64,
    peak_used_bytes: u64,
    measurement: []const u8,
};

fn executeFixture(io: std.Io, allocator: std.mem.Allocator, fixture: *const Fixture, options: Options) !ExecutionMetrics {
    return switch (options.engine) {
        .native => try executeNative(io, allocator, fixture),
        .zisk => try executeZisk(io, allocator, fixture, options),
    };
}

fn executeNative(io: std.Io, allocator: std.mem.Allocator, fixture: *const Fixture) !ExecutionMetrics {
    _ = allocator;
    const start = monotonicNanos(io);
    const run = try validateWithMeteredFixedHeap(fixture.stateless_input_bytes, "native-fixed");
    const elapsed_ns = monotonicNanos(io) - start;

    const expected_public = evmz.stateless.ere.outputPublicValues(fixture.stateless_output_bytes);
    return .{ .success = .{
        .output_matched = std.mem.eql(u8, &run.public_values, &expected_public),
        .total_num_cycles = 0,
        .execution_duration = durationJson(elapsed_ns),
        .heap = run.heap,
    } };
}

fn executeZisk(io: std.Io, allocator: std.mem.Allocator, fixture: *const Fixture, options: Options) !ExecutionMetrics {
    const ziskemu_path = options.ziskemu_path orelse return error.MissingZiskemuPath;
    const zisk_elf_path = options.zisk_elf_path orelse return error.MissingZiskElfPath;
    const heap = (try validateWithMeteredFixedHeap(fixture.stateless_input_bytes, "native-fixed-mirror")).heap;

    const run_id = try std.fmt.allocPrint(allocator, "{s}-{d}", .{ fixture.name, monotonicNanos(io) });
    defer allocator.free(run_id);
    const work_dir = try std.fs.path.join(allocator, &.{ options.zisk_work_dir, run_id });
    defer allocator.free(work_dir);
    try std.Io.Dir.cwd().createDirPath(io, work_dir);

    const input_path = try std.fs.path.join(allocator, &.{ work_dir, "stdin.bin" });
    defer allocator.free(input_path);
    const output_path = try std.fs.path.join(allocator, &.{ work_dir, "public.bin" });
    defer allocator.free(output_path);

    const framed_input = try ere_io.inputBytes(allocator, fixture.stateless_input_bytes, .zisk);
    defer allocator.free(framed_input);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = input_path, .data = framed_input });

    const argv = [_][]const u8{
        ziskemu_path,
        "-e",
        zisk_elf_path,
        "-i",
        input_path,
        "-o",
        output_path,
        "-n",
        options.zisk_max_steps,
        "-m",
        "--steps",
        "-c",
    };

    const start = monotonicNanos(io);
    const result = try std.process.run(allocator, io, .{
        .argv = &argv,
        .stdout_limit = .limited(4 * 1024 * 1024),
        .stderr_limit = .limited(4 * 1024 * 1024),
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    const elapsed_ns = monotonicNanos(io) - start;

    const steps = parseZiskSteps(result.stdout) orelse parseZiskSteps(result.stderr) orelse 0;
    if (!childTermOk(result.term)) {
        const reason = try std.fmt.allocPrint(allocator, "ziskemu exited with {f}: {s}{s}", .{ fmtTerm(result.term), result.stdout, result.stderr });
        return .{ .crashed = .{ .reason = reason } };
    }

    const actual = try std.Io.Dir.cwd().readFileAlloc(io, output_path, allocator, .limited(1024));
    defer allocator.free(actual);
    const expected_public = evmz.stateless.ere.outputPublicValues(fixture.stateless_output_bytes);
    const expected = try ere_io.publicValuesBytes(allocator, &expected_public, .zisk);
    defer allocator.free(expected);

    return .{ .success = .{
        .output_matched = std.mem.eql(u8, actual, expected),
        .total_num_cycles = steps,
        .execution_duration = durationJson(elapsed_ns),
        .heap = heap,
    } };
}

const MeteredRun = struct {
    public_values: evmz.stateless.ere.PublicValues,
    heap: HeapMetrics,
};

fn validateWithMeteredFixedHeap(input: []const u8, measurement: []const u8) !MeteredRun {
    const buffer = try std.heap.page_allocator.alignedAlloc(u8, .@"16", guest_heap_capacity_bytes);
    defer std.heap.page_allocator.free(buffer);

    var metered = evmz.fixed_buffer_meter.MeteredFixedBufferAllocator.init(buffer);
    const public_values = try evmz.stateless.ere.validateStatelessPublicValues(metered.allocator(), input);
    const metrics = metered.metrics();
    return .{
        .public_values = public_values,
        .heap = .{
            .capacity_bytes = @intCast(metrics.capacity_bytes),
            .peak_used_bytes = @intCast(metrics.peak_used_bytes),
            .measurement = measurement,
        },
    };
}

const BenchmarkRun = struct {
    name: []const u8,
    timestamp_completed: []const u8,
    metadata: Metadata,
    execution: ExecutionMetrics,

    pub fn jsonStringify(self: @This(), jws: anytype) !void {
        try jws.beginObject();
        try jws.objectField("name");
        try jws.write(self.name);
        try jws.objectField("timestamp_completed");
        try jws.write(self.timestamp_completed);
        try jws.objectField("metadata");
        try jws.write(self.metadata);
        try jws.objectField("execution");
        try jws.write(self.execution);
        try jws.endObject();
    }
};

fn writeBenchmarkRun(
    io: std.Io,
    allocator: std.mem.Allocator,
    output_path: []const u8,
    fixture: *const Fixture,
    execution: ExecutionMetrics,
) !void {
    const timestamp = try rfc3339NowAlloc(allocator, io);
    defer allocator.free(timestamp);
    const run = BenchmarkRun{
        .name = fixture.name,
        .timestamp_completed = timestamp,
        .metadata = fixture.metadata(),
        .execution = execution,
    };
    const json = try std.json.Stringify.valueAlloc(allocator, run, .{ .whitespace = .indent_2 });
    defer allocator.free(json);

    try ensureParentDir(io, output_path);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = output_path, .data = json });
}

fn metricOutputPath(allocator: std.mem.Allocator, output_folder: []const u8, engine: Engine, name: []const u8) ![]u8 {
    const file_name = try std.fmt.allocPrint(allocator, "{s}.json", .{name});
    defer allocator.free(file_name);
    return std.fs.path.join(allocator, &.{ output_folder, engine.label(), file_name });
}

fn ensureParentDir(io: std.Io, path: []const u8) !void {
    const parent = std.fs.path.dirname(path) orelse return;
    if (parent.len == 0) return;
    try std.Io.Dir.cwd().createDirPath(io, parent);
}

fn relativeSourcePath(allocator: std.mem.Allocator, path: []const u8, input_root: []const u8) ![]u8 {
    var relative = path;
    if (!std.mem.eql(u8, input_root, ".") and std.mem.startsWith(u8, path, input_root)) {
        relative = path[input_root.len..];
        while (relative.len > 0 and (relative[0] == '/' or relative[0] == '\\')) relative = relative[1..];
        if (relative.len == 0) relative = path;
    }

    const out = try allocator.alloc(u8, relative.len);
    for (relative, 0..) |byte, i| {
        out[i] = if (byte == '\\') '/' else byte;
    }
    return out;
}

fn parseOptionalJsonU64(value: ?JsonValue) !?u64 {
    return if (value) |inner| try parseJsonU64Value(inner) else null;
}

fn parseJsonU64Value(value: JsonValue) !u64 {
    const string = jsonString(value) orelse return error.MalformedFixture;
    const trimmed = std.mem.trim(u8, string, " \t\r\n");
    if (trimmed.len == 0) return 0;
    if (std.mem.startsWith(u8, trimmed, "0x") or std.mem.startsWith(u8, trimmed, "0X")) {
        return std.fmt.parseInt(u64, trimmed[2..], 16);
    }
    return std.fmt.parseInt(u64, trimmed, 10);
}

fn uniqueFixtureName(
    allocator: std.mem.Allocator,
    test_name: []const u8,
    block_index: usize,
    fixture_names: *std.StringHashMap(void),
) ![]u8 {
    const base = try fixtureName(allocator, test_name, block_index);
    defer allocator.free(base);

    var index: usize = 1;
    while (true) : (index += 1) {
        const suffix = if (index == 1)
            ""
        else
            try std.fmt.allocPrint(allocator, "__{d}", .{index});
        defer if (index != 1) allocator.free(suffix);

        const candidate = try truncateFixtureName(allocator, base, suffix);
        if (!fixture_names.contains(candidate)) {
            try fixture_names.put(candidate, {});
            return candidate;
        }
        allocator.free(candidate);
    }
}

fn fixtureName(allocator: std.mem.Allocator, test_name: []const u8, block_index: usize) ![]u8 {
    const sanitized = try sanitizeFixtureName(allocator, test_name);
    defer allocator.free(sanitized);
    return std.fmt.allocPrint(allocator, "eest__{s}__block{d}", .{ sanitized, block_index });
}

fn sanitizeFixtureName(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    var last_was_separator = false;
    for (value) |byte| {
        if (std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '_') {
            try out.append(allocator, byte);
            last_was_separator = false;
        } else if (!last_was_separator) {
            try out.append(allocator, '_');
            last_was_separator = true;
        }
    }

    const trimmed = std.mem.trim(u8, out.items, "_");
    if (trimmed.len == 0) return allocator.dupe(u8, "fixture");
    return allocator.dupe(u8, trimmed);
}

fn truncateFixtureName(allocator: std.mem.Allocator, base: []const u8, suffix: []const u8) ![]u8 {
    const base_max_len = safe_file_stem_max_len -| suffix.len;
    if (base.len <= base_max_len) {
        return std.fmt.allocPrint(allocator, "{s}{s}", .{ base, suffix });
    }

    var end = base_max_len;
    while (end > 0 and base[end - 1] == '_') end -= 1;
    return std.fmt.allocPrint(allocator, "{s}{s}", .{ base[0..end], suffix });
}

fn parseZiskSteps(bytes: []const u8) ?u64 {
    const needle = "steps=";
    const start = std.mem.indexOf(u8, bytes, needle) orelse return null;
    var cursor = start + needle.len;
    const digits_start = cursor;
    while (cursor < bytes.len and std.ascii.isDigit(bytes[cursor])) cursor += 1;
    if (cursor == digits_start) return null;
    return std.fmt.parseInt(u64, bytes[digits_start..cursor], 10) catch null;
}

fn childTermOk(term: std.process.Child.Term) bool {
    return switch (term) {
        .exited => |code| code == 0,
        else => false,
    };
}

fn formatTerm(term: std.process.Child.Term, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    switch (term) {
        .exited => |code| try writer.print("exit code {d}", .{code}),
        .signal => |signal| try writer.print("signal {d}", .{@intFromEnum(signal)}),
        .stopped => |signal| try writer.print("stopped signal {d}", .{@intFromEnum(signal)}),
        .unknown => |status| try writer.print("unknown status {d}", .{status}),
    }
}

fn fmtTerm(term: std.process.Child.Term) std.fmt.Alt(std.process.Child.Term, formatTerm) {
    return .{ .data = term };
}

fn durationJson(nanos: u64) DurationJson {
    return .{
        .secs = nanos / std.time.ns_per_s,
        .nanos = @as(u32, @intCast(nanos % std.time.ns_per_s)),
    };
}

fn monotonicNanos(io: std.Io) u64 {
    const timestamp = std.Io.Clock.awake.now(io).nanoseconds;
    return if (timestamp <= 0) 0 else @as(u64, @intCast(timestamp));
}

fn rfc3339NowAlloc(allocator: std.mem.Allocator, io: std.Io) ![]u8 {
    const timestamp = std.Io.Clock.real.now(io).nanoseconds;
    const nanos = if (timestamp <= 0) 0 else @as(u128, @intCast(timestamp));
    return rfc3339TimestampAlloc(allocator, nanos);
}

fn rfc3339TimestampAlloc(allocator: std.mem.Allocator, timestamp_nanos: u128) ![]u8 {
    const secs = @as(u64, @intCast(timestamp_nanos / std.time.ns_per_s));
    const frac = @as(u32, @intCast(timestamp_nanos % std.time.ns_per_s));
    const epoch_seconds = std.time.epoch.EpochSeconds{ .secs = secs };
    const year_day = epoch_seconds.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day_seconds = epoch_seconds.getDaySeconds();

    return std.fmt.allocPrint(
        allocator,
        "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}.{d:0>9}Z",
        .{
            year_day.year,
            @intFromEnum(month_day.month),
            month_day.day_index + 1,
            day_seconds.getHoursIntoDay(),
            day_seconds.getMinutesIntoHour(),
            day_seconds.getSecondsIntoMinute(),
            frac,
        },
    );
}

pub fn printUsage() void {
    std.debug.print(
        \\usage: zig build zkevm-ere-bench -- [--engine native|zisk] [--output-folder PATH] [--limit N] [--test NAME] [--ziskemu PATH] [--zisk-elf PATH] [path ...]
        \\
        \\Consumes direct EEST zkEVM fixtures with non-empty statelessInputBytes
        \\and emits ERE BenchmarkRun-compatible execution JSON rows. Native
        \\runs execute evmz directly. ZisK runs frame the raw fixture bytes at
        \\the backend boundary and compare the 256-byte padded public output.
        \\
    , .{});
}

test "loads EEST benchmark fixtures with upstream-compatible names and metadata" {
    const fixture =
        \\{
        \\  "tests/foo.py::test_same[name/a]": {
        \\    "network": "Amsterdam",
        \\    "config": {"chainid": "1"},
        \\    "blocks": [
        \\      {
        \\        "statelessInputBytes": "0x000102",
        \\        "statelessOutputBytes": "0xaabb",
        \\        "blockHeader": {"number": "0x01", "gasUsed": "0x10"}
        \\      },
        \\      {"blockHeader": {"number": "0x02", "gasUsed": "0x20"}},
        \\      {"statelessInputBytes": "0x", "statelessOutputBytes": "0xcc"}
        \\    ]
        \\  },
        \\  "tests/foo.py::test_same[name?a]": {
        \\    "network": "Amsterdam",
        \\    "config": {"chainid": "0x01"},
        \\    "blocks": [
        \\      {
        \\        "statelessInputBytes": "0x0f",
        \\        "statelessOutputBytes": "0xdead",
        \\        "blocknumber": "0x03",
        \\        "blockHeader": {"gasUsed": "0x30"}
        \\      }
        \\    ]
        \\  }
        \\}
    ;
    var fixtures = try loadEestBenchmarkFixtures(
        std.testing.allocator,
        "blockchain_tests/for_amsterdam/compute/mcopy.json",
        ".",
        fixture,
        .{},
    );
    defer {
        for (fixtures.items) |*item| item.deinit(std.testing.allocator);
        fixtures.deinit(std.testing.allocator);
    }

    try std.testing.expectEqual(@as(usize, 2), fixtures.items.len);
    try std.testing.expectEqualStrings("eest__tests_foo_py_test_same_name_a__block0", fixtures.items[0].name);
    try std.testing.expectEqualStrings("eest__tests_foo_py_test_same_name_a__block0__2", fixtures.items[1].name);
    try std.testing.expectEqualStrings("blockchain_tests/for_amsterdam/compute/mcopy.json", fixtures.items[0].source_path);
    try std.testing.expectEqual(@as(u64, 1), fixtures.items[0].chain_id);
    try std.testing.expectEqual(@as(?u64, 1), fixtures.items[0].block_number);
    try std.testing.expectEqual(@as(?u64, 16), fixtures.items[0].block_used_gas);
}

test "benchmark input reader accepts absolute paths" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const relative_path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/fixture.json", .{tmp.sub_path});
    defer std.testing.allocator.free(relative_path);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = relative_path, .data = "{}" });

    const absolute_path = try std.fs.path.resolve(std.testing.allocator, &.{relative_path});
    defer std.testing.allocator.free(absolute_path);

    const bytes = try readBenchmarkInputFile(std.testing.io, std.testing.allocator, absolute_path);
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqualStrings("{}", bytes);
}

test "native run writes BenchmarkRun execution success row" {
    const input = try evmz.stateless.wire.smokeInputBytes(std.testing.allocator);
    defer std.testing.allocator.free(input);
    const output = try evmz.stateless.wire.validateStatelessBytes(std.testing.allocator, input);
    defer std.testing.allocator.free(output);

    const input_hex = try hexAlloc(std.testing.allocator, input);
    defer std.testing.allocator.free(input_hex);
    const output_hex = try hexAlloc(std.testing.allocator, output);
    defer std.testing.allocator.free(output_hex);

    const fixture = try std.fmt.allocPrint(std.testing.allocator,
        \\{{"smoke":{{"network":"Amsterdam","config":{{"chainid":"1"}},"blocks":[{{"statelessInputBytes":"0x{s}","statelessOutputBytes":"0x{s}","blockHeader":{{"number":"1","gasUsed":"0"}}}}]}}}}
    , .{ input_hex, output_hex });
    defer std.testing.allocator.free(fixture);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const output_folder = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/metrics", .{tmp.sub_path});
    defer std.testing.allocator.free(output_folder);

    var limit = SelectionLimit{};
    const summary = try runSlice(std.testing.io, std.testing.allocator, "smoke.json", ".", fixture, .{ .output_folder = output_folder }, &limit);
    try std.testing.expectEqual(@as(usize, 1), summary.fixtures);
    try std.testing.expectEqual(@as(usize, 1), summary.benchmarked);
    try std.testing.expectEqual(@as(usize, 0), summary.failed);

    const metric_path = try metricOutputPath(std.testing.allocator, output_folder, .native, "eest__smoke__block0");
    defer std.testing.allocator.free(metric_path);
    const row = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, metric_path, std.testing.allocator, .limited(64 * 1024));
    defer std.testing.allocator.free(row);

    try std.testing.expect(std.mem.indexOf(u8, row, "\"name\": \"eest__smoke__block0\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, row, "\"success\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, row, "\"output_matched\": true") != null);
    try std.testing.expect(std.mem.indexOf(u8, row, "\"heap\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, row, "\"peak_used_bytes\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, row, "\"fixture_format\": \"eest\"") != null);
}

test "native run writes BenchmarkRun row to absolute output folder" {
    const input = try evmz.stateless.wire.smokeInputBytes(std.testing.allocator);
    defer std.testing.allocator.free(input);
    const output = try evmz.stateless.wire.validateStatelessBytes(std.testing.allocator, input);
    defer std.testing.allocator.free(output);

    const input_hex = try hexAlloc(std.testing.allocator, input);
    defer std.testing.allocator.free(input_hex);
    const output_hex = try hexAlloc(std.testing.allocator, output);
    defer std.testing.allocator.free(output_hex);

    const fixture = try std.fmt.allocPrint(std.testing.allocator,
        \\{{"smoke":{{"network":"Amsterdam","config":{{"chainid":"1"}},"blocks":[{{"statelessInputBytes":"0x{s}","statelessOutputBytes":"0x{s}","blockHeader":{{"number":"1","gasUsed":"0"}}}}]}}}}
    , .{ input_hex, output_hex });
    defer std.testing.allocator.free(fixture);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const relative_output_folder = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/absolute-metrics", .{tmp.sub_path});
    defer std.testing.allocator.free(relative_output_folder);
    const output_folder = try std.fs.path.resolve(std.testing.allocator, &.{relative_output_folder});
    defer std.testing.allocator.free(output_folder);

    var limit = SelectionLimit{};
    const summary = try runSlice(std.testing.io, std.testing.allocator, "smoke.json", ".", fixture, .{ .output_folder = output_folder }, &limit);
    try std.testing.expectEqual(@as(usize, 1), summary.benchmarked);
    try std.testing.expectEqual(@as(usize, 0), summary.failed);

    const metric_path = try metricOutputPath(std.testing.allocator, output_folder, .native, "eest__smoke__block0");
    defer std.testing.allocator.free(metric_path);
    const row = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, metric_path, std.testing.allocator, .limited(64 * 1024));
    defer std.testing.allocator.free(row);
    try std.testing.expect(std.mem.indexOf(u8, row, "\"output_matched\": true") != null);
}

test "formats RFC3339 timestamps" {
    const timestamp = try rfc3339TimestampAlloc(std.testing.allocator, 0);
    defer std.testing.allocator.free(timestamp);
    try std.testing.expectEqualStrings("1970-01-01T00:00:00.000000000Z", timestamp);
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
