//! Writes one ERE `BenchmarkRun`-compatible JSON row per executed block.
//!
//! Guest evidence and external ERE tooling consume these rows, so the field
//! names follow ERE's schema rather than this repository's naming.

const std = @import("std");
const executor = @import("stateless_executor.zig");

const safe_file_stem_max_len = 220;

pub const Metadata = struct {
    fixture_format: []const u8 = "eest",
    original_test_name: []const u8,
    source_path: []const u8,
    block_index: usize,
    network: []const u8,
    chain_id: u64,
    block_number: ?u64,
    block_used_gas: ?u64,
};

/// Per-file name allocator. EEST test names are not unique once sanitised into
/// file stems, so collisions get a numeric suffix in encounter order.
pub const Names = struct {
    allocator: std.mem.Allocator,
    seen: std.StringHashMap(void),

    pub fn init(allocator: std.mem.Allocator) Names {
        return .{ .allocator = allocator, .seen = .init(allocator) };
    }

    pub fn deinit(self: *Names) void {
        var it = self.seen.keyIterator();
        while (it.next()) |key| self.allocator.free(key.*);
        self.seen.deinit();
    }

    /// Returned name is owned by the caller.
    pub fn take(self: *Names, test_name: []const u8, block_index: usize) ![]u8 {
        const base = try fixtureName(self.allocator, test_name, block_index);
        defer self.allocator.free(base);

        var index: usize = 1;
        while (true) : (index += 1) {
            const suffix = if (index == 1) "" else try std.fmt.allocPrint(self.allocator, "__{d}", .{index});
            defer if (index != 1) self.allocator.free(suffix);

            const candidate = try truncateFixtureName(self.allocator, base, suffix);
            errdefer self.allocator.free(candidate);
            if (!self.seen.contains(candidate)) {
                try self.seen.put(try self.allocator.dupe(u8, candidate), {});
                return candidate;
            }
            self.allocator.free(candidate);
        }
    }
};

pub fn write(
    io: std.Io,
    allocator: std.mem.Allocator,
    output_folder: []const u8,
    target: executor.Target,
    name: []const u8,
    metadata: Metadata,
    outcome: executor.Outcome,
    output_matched: bool,
) !void {
    const path = try outputPath(allocator, output_folder, target, name);
    defer allocator.free(path);

    const timestamp = try rfc3339NowAlloc(allocator, io);
    defer allocator.free(timestamp);

    var execution: Execution = switch (outcome) {
        .crashed => |crashed| .{ .crashed = .{ .reason = crashed.reason } },
        .completed => |completed| .{ .success = .{
            .output_matched = output_matched,
            .public_values = try .init(allocator, completed.output),
            .total_num_cycles = completed.cycles,
            .execution_duration = durationJson(completed.duration_nanos),
        } },
    };
    defer execution.deinit(allocator);

    const json = try std.json.Stringify.valueAlloc(allocator, BenchmarkRun{
        .name = name,
        .timestamp_completed = timestamp,
        .metadata = metadata,
        .execution = execution,
    }, .{ .whitespace = .indent_2 });
    defer allocator.free(json);

    if (std.fs.path.dirname(path)) |parent| {
        if (parent.len != 0) try std.Io.Dir.cwd().createDirPath(io, parent);
    }
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = json });
}

const BenchmarkRun = struct {
    name: []const u8,
    timestamp_completed: []const u8,
    metadata: Metadata,
    execution: Execution,
};

const Execution = union(enum) {
    success: Success,
    crashed: Crashed,

    fn deinit(self: *Execution, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .success => |success| allocator.free(success.public_values.chars),
            .crashed => {},
        }
    }
};

const Success = struct {
    output_matched: bool,
    public_values: PublicValuesHex,
    total_num_cycles: u64,
    region_cycles: struct {} = .{},
    execution_duration: DurationJson,
};

const Crashed = struct { reason: []const u8 };

const DurationJson = struct { secs: u64, nanos: u32 };

const PublicValuesHex = struct {
    chars: []u8,

    fn init(allocator: std.mem.Allocator, bytes: []const u8) !PublicValuesHex {
        return .{ .chars = try hexAlloc(allocator, bytes) };
    }

    pub fn jsonStringify(self: PublicValuesHex, jws: anytype) !void {
        try jws.write(self.chars);
    }
};

fn durationJson(nanos: u64) DurationJson {
    return .{ .secs = nanos / std.time.ns_per_s, .nanos = @intCast(nanos % std.time.ns_per_s) };
}

fn outputPath(
    allocator: std.mem.Allocator,
    output_folder: []const u8,
    target: executor.Target,
    name: []const u8,
) ![]u8 {
    const file_name = try std.fmt.allocPrint(allocator, "{s}.json", .{name});
    defer allocator.free(file_name);
    return std.fs.path.join(allocator, &.{ output_folder, target.label(), file_name });
}

/// Path as reported in a row, relative to whichever corpus root contains it.
/// The longest match wins, so nested roots report the most specific path.
pub fn relativeSourcePath(allocator: std.mem.Allocator, path: []const u8, roots: []const []const u8) ![]u8 {
    var relative = path;
    var matched: usize = 0;
    for (roots) |root| {
        if (std.mem.eql(u8, root, ".") or root.len <= matched) continue;
        if (!std.mem.startsWith(u8, path, root)) continue;
        var candidate = path[root.len..];
        while (candidate.len > 0 and (candidate[0] == '/' or candidate[0] == '\\')) candidate = candidate[1..];
        if (candidate.len == 0) continue;
        relative = candidate;
        matched = root.len;
    }

    const out = try allocator.alloc(u8, relative.len);
    for (relative, 0..) |byte, i| out[i] = if (byte == '\\') '/' else byte;
    return out;
}

fn fixtureName(allocator: std.mem.Allocator, test_name: []const u8, block_index: usize) ![]u8 {
    const sanitized = try sanitizeFixtureName(allocator, test_name);
    defer allocator.free(sanitized);
    return std.fmt.allocPrint(allocator, "eest__{s}__block{d}", .{ sanitized, block_index });
}

/// Collapses runs of path and parameter punctuation into single underscores so
/// one test name maps to one file stem.
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

fn hexAlloc(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    const out = try allocator.alloc(u8, bytes.len * 2);
    const alphabet = "0123456789abcdef";
    for (bytes, 0..) |byte, i| {
        out[i * 2] = alphabet[byte >> 4];
        out[i * 2 + 1] = alphabet[byte & 0x0f];
    }
    return out;
}

fn rfc3339NowAlloc(allocator: std.mem.Allocator, io: std.Io) ![]u8 {
    const timestamp = std.Io.Clock.real.now(io).nanoseconds;
    return rfc3339TimestampAlloc(allocator, @intCast(@max(timestamp, 0)));
}

fn rfc3339TimestampAlloc(allocator: std.mem.Allocator, timestamp_nanos: u128) ![]u8 {
    const seconds: u64 = @intCast(timestamp_nanos / std.time.ns_per_s);
    const nanos: u64 = @intCast(timestamp_nanos % std.time.ns_per_s);
    const epoch = std.time.epoch.EpochSeconds{ .secs = seconds };
    const day = epoch.getEpochDay();
    const year_day = day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const time = epoch.getDaySeconds();
    return std.fmt.allocPrint(
        allocator,
        "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}.{d:0>9}Z",
        .{
            year_day.year,
            month_day.month.numeric(),
            month_day.day_index + 1,
            time.getHoursIntoDay(),
            time.getMinutesIntoHour(),
            time.getSecondsIntoMinute(),
            nanos,
        },
    );
}

test "colliding fixture names get deterministic suffixes" {
    var names = Names.init(std.testing.allocator);
    defer names.deinit();

    const first = try names.take("tests/foo.py::test_same[name/a]", 0);
    defer std.testing.allocator.free(first);
    const second = try names.take("tests/foo.py::test_same[name?a]", 0);
    defer std.testing.allocator.free(second);

    try std.testing.expectEqualStrings("eest__tests_foo_py_test_same_name_a__block0", first);
    try std.testing.expectEqualStrings("eest__tests_foo_py_test_same_name_a__block0__2", second);
}

test "source paths are reported relative to the closest corpus root" {
    const relative = try relativeSourcePath(std.testing.allocator, "/corpus/a/b.json", &.{"/corpus"});
    defer std.testing.allocator.free(relative);
    try std.testing.expectEqualStrings("a/b.json", relative);

    const nested = try relativeSourcePath(
        std.testing.allocator,
        "/corpus/batch2/a/b.json",
        &.{ "/corpus", "/corpus/batch2" },
    );
    defer std.testing.allocator.free(nested);
    try std.testing.expectEqualStrings("a/b.json", nested);
}
