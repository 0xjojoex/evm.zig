//! Runs one stateless input on the selected target and returns canonical result
//! bytes.
//!
//! Each target frames its input and public output differently. That framing is
//! private to the executor, so `stateless.zig` compares the same canonical bytes
//! for a native run, a ZisK guest, and an SP1 guest, and one set of fixture
//! semantics covers all three.

const std = @import("std");
const evmz = @import("evmz");
const ere_io = @import("stateless_ere_io.zig");

/// Magic the guest payload writes instead of a result when it fails before
/// producing one. See `guest/payload/stateless_ere.zig`.
const guest_error_magic = "EVMZERR1";

pub const Target = enum {
    native,
    zisk,
    sp1,

    pub fn label(self: Target) []const u8 {
        return switch (self) {
            .native => "evmz-native",
            .zisk => "zisk-ziskemu",
            .sp1 => "sp1-executor",
        };
    }

    pub fn parse(value: []const u8) ?Target {
        return std.meta.stringToEnum(Target, value);
    }
};

pub const Options = struct {
    target: Target = .native,
    zisk_host_path: ?[]const u8 = null,
    zisk_elf_path: ?[]const u8 = null,
    sp1_host_path: ?[]const u8 = null,
    sp1_elf_path: ?[]const u8 = null,
    sp1_work_dir: []const u8 = "zig-out/zkevm-sp1",
};

pub const Completed = struct {
    /// Canonical SSZ `StatelessValidationResult` bytes, owned by the caller.
    output: []u8,
    /// Executed steps for ZisK, cycles for SP1, zero for native.
    cycles: u64,
    duration_nanos: u64,
};

/// A target that never produced a result. `reason` is owned by the caller.
pub const Crashed = struct {
    reason: []const u8,
};

pub const Outcome = union(enum) {
    completed: Completed,
    crashed: Crashed,

    pub fn deinit(self: *Outcome, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .completed => |completed| allocator.free(completed.output),
            .crashed => |crashed| allocator.free(crashed.reason),
        }
    }
};

/// One executor per worker. The ZisK host is a persistent child process that
/// caches the ELF's ROM across fixtures, so it must not be shared across
/// threads.
pub const Executor = struct {
    io: std.Io,
    options: Options,
    zisk_host: ?ZiskHost = null,

    pub fn init(io: std.Io, options: Options) !Executor {
        return .{
            .io = io,
            .options = options,
            .zisk_host = if (options.target == .zisk) try ZiskHost.init(io, options) else null,
        };
    }

    pub fn deinit(self: *Executor) void {
        if (self.zisk_host) |*host| host.deinit(self.io);
    }

    /// A guest writes its result into a fixed-width public region, and an
    /// encoded `StatelessValidationResult` is variable-size, so the meaningful
    /// length cannot be recovered from the region alone. `canonical_len` is the
    /// fixture's own expected length; the executor requires the remainder of
    /// the region to be zero. `label` disambiguates the SP1 work directory.
    pub fn execute(
        self: *Executor,
        allocator: std.mem.Allocator,
        input: []const u8,
        canonical_len: usize,
        label: []const u8,
    ) !Outcome {
        return switch (self.options.target) {
            .native => executeNative(self.io, allocator, input),
            .zisk => self.executeZisk(allocator, input, canonical_len),
            .sp1 => executeSp1(self.io, allocator, input, canonical_len, self.options, label),
        };
    }

    fn executeZisk(
        self: *Executor,
        allocator: std.mem.Allocator,
        input: []const u8,
        canonical_len: usize,
    ) !Outcome {
        var response = try self.zisk_host.?.execute(self.io, allocator, input);
        defer response.deinit(allocator);
        if (response.status != 0) {
            return .{ .crashed = .{ .reason = try allocator.dupe(u8, response.payload) } };
        }
        return canonicalOutcome(
            allocator,
            response.payload,
            canonical_len,
            response.steps,
            response.duration_nanos,
        );
    }
};

fn executeNative(io: std.Io, allocator: std.mem.Allocator, input: []const u8) !Outcome {
    const start = monotonicNanos(io);
    const output = try evmz.stateless.wire.validateStatelessBytes(allocator, input);
    return .{ .completed = .{
        .output = output,
        .cycles = 0,
        .duration_nanos = monotonicNanos(io) - start,
    } };
}

fn executeSp1(
    io: std.Io,
    allocator: std.mem.Allocator,
    input: []const u8,
    canonical_len: usize,
    options: Options,
    label: []const u8,
) !Outcome {
    const host_path = options.sp1_host_path orelse return error.MissingSp1HostPath;
    const elf_path = options.sp1_elf_path orelse return error.MissingSp1ElfPath;

    const run_id = try std.fmt.allocPrint(allocator, "{s}-{d}", .{ label, monotonicNanos(io) });
    defer allocator.free(run_id);
    const work_dir = try std.fs.path.join(allocator, &.{ options.sp1_work_dir, run_id });
    defer allocator.free(work_dir);
    try std.Io.Dir.cwd().createDirPath(io, work_dir);

    const input_path = try std.fs.path.join(allocator, &.{ work_dir, "stdin.bin" });
    defer allocator.free(input_path);
    const output_path = try std.fs.path.join(allocator, &.{ work_dir, "public.bin" });
    defer allocator.free(output_path);

    const framed = try ere_io.inputBytes(allocator, input, .sp1);
    defer allocator.free(framed);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = input_path, .data = framed });

    const argv = [_][]const u8{ host_path, "--elf", elf_path, "--input", input_path, "--output", output_path };
    const start = monotonicNanos(io);
    const result = try std.process.run(allocator, io, .{
        .argv = &argv,
        .stdout_limit = .limited(4 * 1024 * 1024),
        .stderr_limit = .limited(4 * 1024 * 1024),
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    const elapsed_ns = monotonicNanos(io) - start;

    if (!childTermOk(result.term)) {
        return .{ .crashed = .{ .reason = try std.fmt.allocPrint(
            allocator,
            "SP1 executor exited with {f}: {s}{s}",
            .{ fmtTerm(result.term), result.stdout, result.stderr },
        ) } };
    }
    const cycles = parseSp1Cycles(result.stdout) orelse parseSp1Cycles(result.stderr) orelse 0;
    if (cycles == 0) {
        return .{ .crashed = .{ .reason = try std.fmt.allocPrint(
            allocator,
            "SP1 executor reported no cycle count: {s}{s}",
            .{ result.stdout, result.stderr },
        ) } };
    }

    const public = try std.Io.Dir.cwd().readFileAlloc(io, output_path, allocator, .limited(4 * 1024));
    defer allocator.free(public);
    return canonicalOutcome(allocator, public, canonical_len, cycles, elapsed_ns);
}

/// Strips guest framing. A guest that failed before producing a result writes
/// its error magic instead, which is a crash rather than a wrong output.
fn canonicalOutcome(
    allocator: std.mem.Allocator,
    payload: []const u8,
    canonical_len: usize,
    cycles: u64,
    duration_nanos: u64,
) !Outcome {
    if (std.mem.startsWith(u8, payload, guest_error_magic)) {
        const code = if (payload.len >= guest_error_magic.len + 4)
            std.mem.readInt(u32, payload[8..12], .little)
        else
            0;
        return .{ .crashed = .{
            .reason = try std.fmt.allocPrint(allocator, "guest reported error {d}", .{code}),
        } };
    }
    if (payload.len < canonical_len) return .{ .crashed = .{
        .reason = try std.fmt.allocPrint(
            allocator,
            "guest public output is {d} bytes, expected at least {d}",
            .{ payload.len, canonical_len },
        ),
    } };
    if (!std.mem.allEqual(u8, payload[canonical_len..], 0)) return .{ .crashed = .{
        .reason = try allocator.dupe(u8, "guest public output has non-zero padding"),
    } };
    return .{ .completed = .{
        .output = try allocator.dupe(u8, payload[0..canonical_len]),
        .cycles = cycles,
        .duration_nanos = duration_nanos,
    } };
}

const ZiskHost = struct {
    child: std.process.Child,

    const ready = "EVZKH001";
    const response_header_bytes = 32;
    const max_response_payload_bytes = 4 * 1024 * 1024;

    fn init(io: std.Io, options: Options) !ZiskHost {
        const host_path = options.zisk_host_path orelse return error.MissingZiskHostPath;
        const elf_path = options.zisk_elf_path orelse return error.MissingZiskElfPath;
        const argv = [_][]const u8{ host_path, "--elf", elf_path };
        var child = try std.process.spawn(io, .{
            .argv = &argv,
            .stdin = .pipe,
            .stdout = .pipe,
            .stderr = .inherit,
        });
        errdefer child.kill(io);

        var handshake: [ready.len]u8 = undefined;
        try readPipeAll(child.stdout.?, io, &handshake);
        if (!std.mem.eql(u8, &handshake, ready)) return error.InvalidZiskHostHandshake;
        return .{ .child = child };
    }

    fn deinit(self: *ZiskHost, io: std.Io) void {
        if (self.child.id == null) return;
        if (self.child.stdin) |stdin| {
            stdin.close(io);
            self.child.stdin = null;
        }
        _ = self.child.wait(io) catch {
            self.child.kill(io);
            return;
        };
    }

    fn execute(self: *ZiskHost, io: std.Io, allocator: std.mem.Allocator, input: []const u8) !Response {
        var length_bytes: [8]u8 = undefined;
        std.mem.writeInt(u64, &length_bytes, @intCast(input.len), .little);
        try writePipeAll(self.child.stdin.?, io, &length_bytes);
        try writePipeAll(self.child.stdin.?, io, input);

        var header: [response_header_bytes]u8 = undefined;
        try readPipeAll(self.child.stdout.?, io, &header);
        const status = header[0];
        if (status > 1) return error.InvalidZiskHostStatus;
        const payload_len = std.mem.readInt(u64, header[24..32], .little);
        if (payload_len > max_response_payload_bytes) return error.ZiskHostResponseTooLarge;

        const payload = try allocator.alloc(u8, @intCast(payload_len));
        errdefer allocator.free(payload);
        try readPipeAll(self.child.stdout.?, io, payload);
        return .{
            .status = status,
            .steps = std.mem.readInt(u64, header[8..16], .little),
            .duration_nanos = std.mem.readInt(u64, header[16..24], .little),
            .payload = payload,
        };
    }

    const Response = struct {
        status: u8,
        steps: u64,
        duration_nanos: u64,
        payload: []u8,

        fn deinit(self: *Response, allocator: std.mem.Allocator) void {
            allocator.free(self.payload);
        }
    };
};

fn readPipeAll(file: std.Io.File, io: std.Io, bytes: []u8) !void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        const read = try file.readStreaming(io, &.{bytes[offset..]});
        if (read == 0) return error.UnexpectedEndOfStream;
        offset += read;
    }
}

fn writePipeAll(file: std.Io.File, io: std.Io, bytes: []const u8) !void {
    try file.writeStreamingAll(io, bytes);
}

fn parseSp1Cycles(bytes: []const u8) ?u64 {
    return parseCounter(bytes, "cycles=") orelse parseCounter(bytes, "total_cycles=");
}

fn parseCounter(bytes: []const u8, needle: []const u8) ?u64 {
    const start = std.mem.indexOf(u8, bytes, needle) orelse return null;
    var end = start + needle.len;
    while (end < bytes.len and std.ascii.isDigit(bytes[end])) end += 1;
    if (end == start + needle.len) return null;
    return std.fmt.parseInt(u64, bytes[start + needle.len .. end], 10) catch null;
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

fn monotonicNanos(io: std.Io) u64 {
    const timestamp = std.Io.Clock.awake.now(io).nanoseconds;
    return if (timestamp <= 0) 0 else @as(u64, @intCast(timestamp));
}

test "canonical outcome strips the guest public region's zero padding" {
    const canonical_len = 69;
    const padded = try std.testing.allocator.alloc(u8, 256);
    defer std.testing.allocator.free(padded);
    @memset(padded, 0);
    for (padded[0..canonical_len], 0..) |*byte, i| byte.* = @truncate(i + 1);

    var outcome = try canonicalOutcome(std.testing.allocator, padded, canonical_len, 42, 7);
    defer outcome.deinit(std.testing.allocator);

    try std.testing.expectEqualSlices(u8, padded[0..canonical_len], outcome.completed.output);
    try std.testing.expectEqual(@as(u64, 42), outcome.completed.cycles);
}

test "canonical outcome rejects non-zero padding" {
    const padded = try std.testing.allocator.alloc(u8, 256);
    defer std.testing.allocator.free(padded);
    @memset(padded, 0);
    padded[69] = 1;

    var outcome = try canonicalOutcome(std.testing.allocator, padded, 69, 0, 0);
    defer outcome.deinit(std.testing.allocator);
    try std.testing.expect(outcome == .crashed);
}

test "a guest public region shorter than the expected result is a crash" {
    const short = [_]u8{1} ** 8;
    var outcome = try canonicalOutcome(std.testing.allocator, &short, 69, 0, 0);
    defer outcome.deinit(std.testing.allocator);
    try std.testing.expect(outcome == .crashed);
}

test "guest error magic becomes a crash rather than a wrong output" {
    var payload: [32]u8 = [_]u8{0} ** 32;
    @memcpy(payload[0..8], guest_error_magic);
    std.mem.writeInt(u32, payload[8..12], 9, .little);

    var outcome = try canonicalOutcome(std.testing.allocator, &payload, 69, 0, 0);
    defer outcome.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("guest reported error 9", outcome.crashed.reason);
}

test "native execution returns the validator's own result bytes" {
    const input = try evmz.stateless.wire.smokeInputBytes(std.testing.allocator);
    defer std.testing.allocator.free(input);
    const expected = try evmz.stateless.wire.validateStatelessBytes(std.testing.allocator, input);
    defer std.testing.allocator.free(expected);

    var executor = try Executor.init(std.testing.io, .{ .target = .native });
    defer executor.deinit();

    var outcome = try executor.execute(std.testing.allocator, input, expected.len, "smoke");
    defer outcome.deinit(std.testing.allocator);
    try std.testing.expectEqualSlices(u8, expected, outcome.completed.output);
}
