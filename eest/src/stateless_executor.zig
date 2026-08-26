//! Runs one stateless input on the selected target and returns canonical result
//! bytes.
//!
//! Each target frames its input and public output differently. That framing is
//! private to the executor, so `stateless.zig` compares the same canonical bytes
//! for a native run or any guest backend, and one set of fixture semantics
//! covers every target.

const std = @import("std");
const builtin = @import("builtin");
const evmz = @import("evmz");

pub const Target = enum {
    native,
    zisk,
    sp1,
    openvm,

    pub fn label(self: Target) []const u8 {
        return switch (self) {
            .native => "evmz-native",
            .zisk => "zisk-ziskemu",
            .sp1 => "sp1-executor",
            .openvm => "openvm-executor",
        };
    }

    pub fn displayName(self: Target) []const u8 {
        return switch (self) {
            .native => "Native",
            .zisk => "ZisK",
            .sp1 => "SP1",
            .openvm => "OpenVM",
        };
    }

    pub fn primaryMetric(self: Target) ?[]const u8 {
        return switch (self) {
            .native => null,
            .zisk => "steps",
            .sp1 => "cycles",
            .openvm => "retired_instructions",
        };
    }

    pub fn secondaryMetric(self: Target) ?[]const u8 {
        return switch (self) {
            .openvm => "trace_cells",
            .native, .zisk, .sp1 => null,
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
    openvm_host_path: ?[]const u8 = null,
    openvm_config_path: ?[]const u8 = null,
    openvm_elf_path: ?[]const u8 = null,
};

pub const Completed = struct {
    /// Canonical SSZ `StatelessValidationResult` bytes, owned by the caller.
    output: []u8,
    /// Executed steps for ZisK, cycles for SP1, retired instructions for
    /// OpenVM, zero for native.
    cycles: u64,
    trace_cells: u64 = 0,
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

/// One executor per worker. Persistent guest hosts cache their compiled ELF
/// across fixtures, so they must not be shared across threads.
pub const Executor = struct {
    io: std.Io,
    options: Options,
    guest_host: ?GuestHost = null,

    pub fn init(io: std.Io, options: Options) !Executor {
        return .{
            .io = io,
            .options = options,
            .guest_host = if (options.target == .native) null else try GuestHost.init(io, options),
        };
    }

    pub fn deinit(self: *Executor) void {
        if (self.guest_host) |*host| host.deinit(self.io);
    }

    /// A guest writes its result into a fixed-width public region, and an
    /// encoded `StatelessValidationResult` is variable-size, so the meaningful
    /// length cannot be recovered from the region alone. `canonical_len` is the
    /// fixture's own expected length; the executor requires the remainder of
    /// the region to be zero. `label` identifies per-fixture guest work and
    /// failures.
    pub fn execute(
        self: *Executor,
        allocator: std.mem.Allocator,
        input: []const u8,
        canonical_len: usize,
        label: []const u8,
    ) !Outcome {
        return switch (self.options.target) {
            .native => executeNative(self.io, allocator, input),
            .zisk, .sp1, .openvm => self.executeGuest(allocator, input, canonical_len, label),
        };
    }

    fn executeGuest(
        self: *Executor,
        allocator: std.mem.Allocator,
        input: []const u8,
        canonical_len: usize,
        label: []const u8,
    ) !Outcome {
        var response = try self.guest_host.?.execute(self.io, allocator, input, label);
        defer response.deinit(allocator);
        if (response.status != 0) {
            return .{ .crashed = .{ .reason = try allocator.dupe(u8, response.payload) } };
        }
        return canonicalOutcome(
            allocator,
            response.payload,
            canonical_len,
            response.primary,
            response.secondary,
            response.duration_nanos,
        );
    }
};

fn executeNative(io: std.Io, allocator: std.mem.Allocator, input: []const u8) !Outcome {
    const start = monotonicNanos(io);
    const output = try evmz.stateless.wire.validateStatelessBytesReusable(allocator, input);
    return .{ .completed = .{
        .output = output,
        .cycles = 0,
        .trace_cells = 0,
        .duration_nanos = monotonicNanos(io) - start,
    } };
}

/// Strips guest framing after the host has confirmed a successful guest exit.
fn canonicalOutcome(
    allocator: std.mem.Allocator,
    payload: []const u8,
    canonical_len: usize,
    cycles: u64,
    trace_cells: u64,
    duration_nanos: u64,
) !Outcome {
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
        .trace_cells = trace_cells,
        .duration_nanos = duration_nanos,
    } };
}

const GuestHost = struct {
    child: std.process.Child,
    target: Target,

    const ready = "EVMZH001";
    const response_header_bytes = 40;
    const max_response_payload_bytes = 4 * 1024 * 1024;

    fn init(io: std.Io, options: Options) !GuestHost {
        const argv: []const []const u8 = switch (options.target) {
            .zisk => &.{
                options.zisk_host_path orelse return error.MissingZiskHostPath,
                "--elf",
                options.zisk_elf_path orelse return error.MissingZiskElfPath,
            },
            .sp1 => &.{
                options.sp1_host_path orelse return error.MissingSp1HostPath,
                "--elf",
                options.sp1_elf_path orelse return error.MissingSp1ElfPath,
            },
            .openvm => &.{
                options.openvm_host_path orelse return error.MissingOpenVmHostPath,
                "--server",
                options.openvm_config_path orelse return error.MissingOpenVmConfigPath,
                options.openvm_elf_path orelse return error.MissingOpenVmElfPath,
            },
            .native => unreachable,
        };
        var child = try std.process.spawn(io, .{
            .argv = argv,
            .stdin = .pipe,
            .stdout = .pipe,
            .stderr = .inherit,
            .request_resource_usage_statistics = true,
        });
        errdefer child.kill(io);

        var handshake: [ready.len]u8 = undefined;
        readPipeAll(child.stdout.?, io, &handshake) catch |cause| {
            logGuestHostFailure(guestHostFailureAfterExit(options.target, &child, io, .handshake, null, cause));
            return error.GuestHostStartupFailed;
        };
        if (!std.mem.eql(u8, &handshake, ready)) {
            logGuestHostFailure(guestHostFailureAfterKill(
                options.target,
                &child,
                io,
                .handshake,
                null,
                error.InvalidGuestHostHandshake,
            ));
            return error.GuestHostStartupFailed;
        }
        return .{ .child = child, .target = options.target };
    }

    fn deinit(self: *GuestHost, io: std.Io) void {
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

    fn execute(
        self: *GuestHost,
        io: std.Io,
        allocator: std.mem.Allocator,
        input: []const u8,
        label: []const u8,
    ) !Response {
        if (self.child.id == null) return error.GuestHostUnavailable;
        const stdin = self.child.stdin orelse return error.GuestHostUnavailable;
        const stdout = self.child.stdout orelse return error.GuestHostUnavailable;

        var length_bytes: [8]u8 = undefined;
        std.mem.writeInt(u64, &length_bytes, @intCast(input.len), .little);
        writePipeAll(stdin, io, &length_bytes) catch |cause| {
            logGuestHostFailure(guestHostFailureAfterExit(self.target, &self.child, io, .request_length, label, cause));
            return error.GuestHostProcessFailed;
        };
        writePipeAll(stdin, io, input) catch |cause| {
            logGuestHostFailure(guestHostFailureAfterExit(self.target, &self.child, io, .request_payload, label, cause));
            return error.GuestHostProcessFailed;
        };

        var header: [response_header_bytes]u8 = undefined;
        readPipeAll(stdout, io, &header) catch |cause| {
            logGuestHostFailure(guestHostFailureAfterExit(self.target, &self.child, io, .response_header, label, cause));
            return error.GuestHostProcessFailed;
        };
        const decoded = decodeHeader(&header);
        if (decoded.status > 1) {
            logGuestHostFailure(guestHostFailureAfterKill(
                self.target,
                &self.child,
                io,
                .response_header,
                label,
                error.InvalidGuestHostStatus,
            ));
            return error.GuestHostProtocolFailed;
        }
        if (decoded.payload_len > max_response_payload_bytes) {
            logGuestHostFailure(guestHostFailureAfterKill(
                self.target,
                &self.child,
                io,
                .response_header,
                label,
                error.GuestHostResponseTooLarge,
            ));
            return error.GuestHostProtocolFailed;
        }

        const payload = try allocator.alloc(u8, @intCast(decoded.payload_len));
        errdefer allocator.free(payload);
        readPipeAll(stdout, io, payload) catch |cause| {
            logGuestHostFailure(guestHostFailureAfterExit(self.target, &self.child, io, .response_payload, label, cause));
            return error.GuestHostProcessFailed;
        };
        return .{
            .status = decoded.status,
            .primary = decoded.primary,
            .secondary = decoded.secondary,
            .duration_nanos = decoded.duration_nanos,
            .payload = payload,
        };
    }

    const Header = struct {
        status: u8,
        primary: u64,
        secondary: u64,
        duration_nanos: u64,
        payload_len: u64,
    };

    fn decodeHeader(bytes: *const [response_header_bytes]u8) Header {
        return .{
            .status = bytes[0],
            .primary = std.mem.readInt(u64, bytes[8..16], .little),
            .secondary = std.mem.readInt(u64, bytes[16..24], .little),
            .duration_nanos = std.mem.readInt(u64, bytes[24..32], .little),
            .payload_len = std.mem.readInt(u64, bytes[32..40], .little),
        };
    }

    const Response = struct {
        status: u8,
        primary: u64,
        secondary: u64,
        duration_nanos: u64,
        payload: []u8,

        fn deinit(self: *Response, allocator: std.mem.Allocator) void {
            allocator.free(self.payload);
        }
    };
};

const GuestHostPhase = enum {
    handshake,
    request_length,
    request_payload,
    response_header,
    response_payload,
};

const GuestHostFailure = struct {
    target: Target,
    phase: GuestHostPhase,
    fixture: ?[]const u8,
    pid: ?u64,
    cause: anyerror,
    term: ?std.process.Child.Term,
    wait_error: ?anyerror = null,
    max_rss_bytes: ?usize,

    pub fn format(self: GuestHostFailure, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.print("{s} host failed phase={s}", .{ @tagName(self.target), @tagName(self.phase) });
        if (self.fixture) |fixture| try writer.print(" fixture={s}", .{fixture});
        if (self.pid) |pid| try writer.print(" pid={d}", .{pid});
        try writer.print(" cause={s}", .{@errorName(self.cause)});
        if (self.term) |term| {
            try writer.print(" term={f}", .{fmtTerm(term)});
        } else if (self.wait_error) |wait_error| {
            try writer.print(" term=unavailable wait_error={s}", .{@errorName(wait_error)});
        } else {
            try writer.writeAll(" term=terminated-by-runner");
        }
        if (self.max_rss_bytes) |max_rss| try writer.print(" max_rss_bytes={d}", .{max_rss});
    }
};

fn guestHostFailureAfterExit(
    target: Target,
    child: *std.process.Child,
    io: std.Io,
    phase: GuestHostPhase,
    fixture: ?[]const u8,
    cause: anyerror,
) GuestHostFailure {
    const pid = childPid(child);
    const term = child.wait(io) catch |wait_error| {
        child.kill(io);
        return .{
            .target = target,
            .phase = phase,
            .fixture = fixture,
            .pid = pid,
            .cause = cause,
            .term = null,
            .wait_error = wait_error,
            .max_rss_bytes = child.resource_usage_statistics.getMaxRss(),
        };
    };
    return .{
        .target = target,
        .phase = phase,
        .fixture = fixture,
        .pid = pid,
        .cause = cause,
        .term = term,
        .max_rss_bytes = child.resource_usage_statistics.getMaxRss(),
    };
}

fn guestHostFailureAfterKill(
    target: Target,
    child: *std.process.Child,
    io: std.Io,
    phase: GuestHostPhase,
    fixture: ?[]const u8,
    cause: anyerror,
) GuestHostFailure {
    const pid = childPid(child);
    child.kill(io);
    return .{
        .target = target,
        .phase = phase,
        .fixture = fixture,
        .pid = pid,
        .cause = cause,
        .term = null,
        .max_rss_bytes = child.resource_usage_statistics.getMaxRss(),
    };
}

fn childPid(child: *const std.process.Child) ?u64 {
    const id = child.id orelse return null;
    return switch (builtin.os.tag) {
        .windows => @intFromPtr(id),
        .wasi => null,
        else => @intCast(id),
    };
}

fn logGuestHostFailure(failure: GuestHostFailure) void {
    std.debug.print("{f}\n", .{failure});
}

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

    var outcome = try canonicalOutcome(std.testing.allocator, padded, canonical_len, 42, 84, 7);
    defer outcome.deinit(std.testing.allocator);

    try std.testing.expectEqualSlices(u8, padded[0..canonical_len], outcome.completed.output);
    try std.testing.expectEqual(@as(u64, 42), outcome.completed.cycles);
    try std.testing.expectEqual(@as(u64, 84), outcome.completed.trace_cells);
}

test "guest host response header carries two counters and duration" {
    var bytes: [GuestHost.response_header_bytes]u8 = @splat(0);
    bytes[0] = 1;
    std.mem.writeInt(u64, bytes[8..16], 42, .little);
    std.mem.writeInt(u64, bytes[16..24], 84, .little);
    std.mem.writeInt(u64, bytes[24..32], 99, .little);
    std.mem.writeInt(u64, bytes[32..40], 3, .little);
    const header = GuestHost.decodeHeader(&bytes);
    try std.testing.expectEqual(@as(u8, 1), header.status);
    try std.testing.expectEqual(@as(u64, 42), header.primary);
    try std.testing.expectEqual(@as(u64, 84), header.secondary);
    try std.testing.expectEqual(@as(u64, 99), header.duration_nanos);
    try std.testing.expectEqual(@as(u64, 3), header.payload_len);
}

test "canonical outcome rejects non-zero padding" {
    const padded = try std.testing.allocator.alloc(u8, 256);
    defer std.testing.allocator.free(padded);
    @memset(padded, 0);
    padded[69] = 1;

    var outcome = try canonicalOutcome(std.testing.allocator, padded, 69, 0, 0, 0);
    defer outcome.deinit(std.testing.allocator);
    try std.testing.expect(outcome == .crashed);
}

test "a guest public region shorter than the expected result is a crash" {
    const short = [_]u8{1} ** 8;
    var outcome = try canonicalOutcome(std.testing.allocator, &short, 69, 0, 0, 0);
    defer outcome.deinit(std.testing.allocator);
    try std.testing.expect(outcome == .crashed);
}

test "guest host failure names the backend phase fixture cause and process outcome" {
    const failure = GuestHostFailure{
        .target = .sp1,
        .phase = .response_header,
        .fixture = "case-1",
        .pid = 42,
        .cause = error.UnexpectedEndOfStream,
        .term = .{ .exited = 137 },
        .max_rss_bytes = 4096,
    };
    const rendered = try std.fmt.allocPrint(std.testing.allocator, "{f}", .{failure});
    defer std.testing.allocator.free(rendered);
    try std.testing.expectEqualStrings(
        "sp1 host failed phase=response_header fixture=case-1 pid=42 " ++
            "cause=UnexpectedEndOfStream term=exit code 137 max_rss_bytes=4096",
        rendered,
    );
}

test "guest host failure diagnosis preserves an early child exit" {
    if (builtin.os.tag == .windows or builtin.os.tag == .wasi) return error.SkipZigTest;

    const argv = [_][]const u8{"/usr/bin/false"};
    var child = try std.process.spawn(std.testing.io, .{
        .argv = &argv,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
        .request_resource_usage_statistics = true,
    });
    errdefer child.kill(std.testing.io);

    const failure = guestHostFailureAfterExit(
        .zisk,
        &child,
        std.testing.io,
        .handshake,
        null,
        error.UnexpectedEndOfStream,
    );
    try std.testing.expectEqual(@as(?u8, 1), switch (failure.term.?) {
        .exited => |code| code,
        else => null,
    });
    try std.testing.expectEqual(@as(?std.process.Child.Id, null), child.id);
}

test "native execution returns the validator's own result bytes" {
    const input = try evmz.stateless.wire.smokeInputBytes(std.testing.allocator);
    defer std.testing.allocator.free(input);
    const expected = try evmz.stateless.wire.validateStatelessBytesReusable(std.testing.allocator, input);
    defer std.testing.allocator.free(expected);

    var executor = try Executor.init(std.testing.io, .{ .target = .native });
    defer executor.deinit();

    var outcome = try executor.execute(std.testing.allocator, input, expected.len, "smoke");
    defer outcome.deinit(std.testing.allocator);
    try std.testing.expectEqualSlices(u8, expected, outcome.completed.output);
}
