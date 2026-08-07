//! Require a ZisK host to propagate a failure-probe guest's nonzero return.
// tidy:root

const std = @import("std");
const Allocator = std.mem.Allocator;

const ready = "EVZKH001";
const response_header_bytes = 32;
const max_response_bytes = 4 * 1024 * 1024;

const Options = struct {
    host: []const u8,
    elf: []const u8,
    host_args: []const []const u8,
    /// Canary mode for conformance deviation D2 (guest/CONFORMANCE.md): passes
    /// while the ZisK startup library still discards main's nonzero return, and
    /// fails loudly the day it starts propagating, so the waiver gets removed.
    expect_no_propagation: bool = false,
};

const Checker = struct {
    allocator: Allocator,
    failure: []const u8 = "ZisK failure-status check failed",

    fn fail(checker: *Checker, message: []const u8) error{CheckFailed} {
        checker.failure = message;
        return error.CheckFailed;
    }

    fn failFmt(checker: *Checker, comptime format: []const u8, args: anytype) error{CheckFailed} {
        checker.failure = std.fmt.allocPrint(checker.allocator, format, args) catch "ZisK failure-status check failed";
        return error.CheckFailed;
    }

    fn validateHandshake(checker: *Checker, handshake: *const [ready.len]u8) error{CheckFailed}!void {
        if (!std.mem.eql(u8, handshake, ready)) {
            return checker.failFmt("invalid ZisK host handshake: {x}", .{handshake});
        }
    }

    fn payloadSize(checker: *Checker, header: *const [response_header_bytes]u8) error{CheckFailed}!usize {
        const size = std.mem.readInt(u64, header[24..32], .little);
        if (size > max_response_bytes) return checker.failFmt("ZisK host response is too large: {d}", .{size});
        return @intCast(size);
    }

    fn validateResponse(
        checker: *Checker,
        header: *const [response_header_bytes]u8,
        payload: []const u8,
        expect_no_propagation: bool,
    ) error{CheckFailed}!void {
        const expected_size = try checker.payloadSize(header);
        if (payload.len != expected_size) return checker.fail("ZisK host response payload length does not match its header");
        switch (header[0]) {
            0 => if (!expect_no_propagation) {
                return checker.fail("failure-probe guest completed successfully; the ZisK startup library did not propagate main's nonzero return");
            },
            1 => if (expect_no_propagation) {
                return checker.failFmt(
                    "ZisK host reported failure despite --expect-no-propagation; either ZisK now propagates main's nonzero return (remove the flag and clear deviation D2) or the probe run itself broke: {s}",
                    .{payload},
                );
            },
            else => return checker.failFmt("invalid ZisK host status: {d}", .{header[0]}),
        }
    }

    fn check(checker: *Checker, io: std.Io, options: Options) ![]const u8 {
        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(checker.allocator);
        try argv.appendSlice(checker.allocator, &.{ options.host, "--elf", options.elf });
        try argv.appendSlice(checker.allocator, options.host_args);

        var child = try std.process.spawn(io, .{
            .argv = argv.items,
            .stdin = .pipe,
            .stdout = .pipe,
            .stderr = .inherit,
        });
        defer child.kill(io);

        var handshake: [ready.len]u8 = undefined;
        readPipeAll(child.stdout.?, io, &handshake) catch return checker.fail("ZisK host closed its output before the handshake completed");
        try checker.validateHandshake(&handshake);

        var input_size: [8]u8 = undefined;
        std.mem.writeInt(u64, &input_size, 0, .little);
        try child.stdin.?.writeStreamingAll(io, &input_size);

        var header: [response_header_bytes]u8 = undefined;
        readPipeAll(child.stdout.?, io, &header) catch return checker.fail("ZisK host closed its output before the response header completed");
        const payload_size = try checker.payloadSize(&header);
        const payload = try checker.allocator.alloc(u8, payload_size);
        readPipeAll(child.stdout.?, io, payload) catch return checker.fail("ZisK host closed its output before the response payload completed");

        child.stdin.?.close(io);
        child.stdin = null;
        const term = try checker.waitForChild(io, &child);
        if (!termOk(term)) return checker.failFmt("ZisK host terminated with {f}", .{fmtTerm(term)});

        try checker.validateResponse(&header, payload, options.expect_no_propagation);
        if (options.expect_no_propagation) {
            return "provider still discards main's nonzero return; the expected-fail canary holds";
        }
        return std.fmt.allocPrint(
            checker.allocator,
            "nonzero guest exit propagated: {s}",
            .{payload},
        ) catch "nonzero guest exit propagated";
    }

    fn waitForChild(checker: *Checker, io: std.Io, child: *std.process.Child) !std.process.Child.Term {
        const Result = union(enum) {
            terminated: std.process.Child.WaitError!std.process.Child.Term,
            timeout: std.Io.Cancelable!void,
        };
        var results: [2]Result = undefined;
        var select = std.Io.Select(Result).init(io, &results);
        defer select.cancelDiscard();
        select.async(.terminated, std.process.Child.wait, .{ child, io });
        select.async(.timeout, std.Io.sleep, .{ io, std.Io.Duration.fromSeconds(10), std.Io.Clock.awake });
        return switch (try select.await()) {
            .terminated => |result| try result,
            .timeout => |result| {
                try result;
                return checker.fail("ZisK host did not exit within 10 seconds");
            },
        };
    }
};

fn readPipeAll(file: std.Io.File, io: std.Io, bytes: []u8) !void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        const read = try file.readStreaming(io, &.{bytes[offset..]});
        if (read == 0) return error.UnexpectedEndOfStream;
        offset += read;
    }
}

fn termOk(term: std.process.Child.Term) bool {
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

fn parseOptions(init: std.process.Init, allocator: Allocator) !Options {
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, allocator);
    defer args.deinit();
    _ = args.next();

    var host: ?[]const u8 = null;
    var elf: ?[]const u8 = null;
    var expect_no_propagation = false;
    var host_args: std.ArrayList([]const u8) = .empty;
    while (args.next()) |arg_z| {
        const arg = arg_z[0..arg_z.len];
        if (std.mem.eql(u8, arg, "--host-arg")) {
            const host_arg = args.next() orelse return error.MissingHostArgument;
            try host_args.append(allocator, host_arg[0..host_arg.len]);
        } else if (std.mem.eql(u8, arg, "--expect-no-propagation")) {
            expect_no_propagation = true;
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            printUsage();
            std.process.exit(0);
        } else if (std.mem.startsWith(u8, arg, "-")) {
            return error.UnknownArgument;
        } else if (host == null) {
            host = arg;
        } else if (elf == null) {
            elf = arg;
        } else {
            return error.UnexpectedArgument;
        }
    }
    return .{
        .host = host orelse return error.MissingHost,
        .elf = elf orelse return error.MissingElf,
        .host_args = try host_args.toOwnedSlice(allocator),
        .expect_no_propagation = expect_no_propagation,
    };
}

fn printUsage() void {
    std.debug.print("usage: check-zisk-failure-status [--expect-no-propagation] [--host-arg ARG]... HOST ELF\n", .{});
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const options = parseOptions(init, allocator) catch {
        printUsage();
        std.process.exit(2);
    };
    var checker: Checker = .{ .allocator = allocator };
    const reason = checker.check(init.io, options) catch |err| {
        const message = if (err == error.CheckFailed) checker.failure else @errorName(err);
        std.debug.print("check-zisk-failure-status: {s}\n", .{message});
        std.process.exit(1);
    };
    std.debug.print("check-zisk-failure-status: {s}\n", .{reason});
}

fn responseHeader(status: u8, payload_size: u64) [response_header_bytes]u8 {
    var header = [_]u8{0} ** response_header_bytes;
    header[0] = status;
    std.mem.writeInt(u64, header[24..32], payload_size, .little);
    return header;
}

test "accepts propagated guest failure" {
    var checker: Checker = .{ .allocator = std.testing.allocator };
    const header = responseHeader(1, 4);
    try checker.validateResponse(&header, "boom", false);
}

test "rejects successful failure probe" {
    var checker: Checker = .{ .allocator = std.testing.allocator };
    const header = responseHeader(0, 0);
    try std.testing.expectError(error.CheckFailed, checker.validateResponse(&header, "", false));
    try std.testing.expectEqualStrings(
        "failure-probe guest completed successfully; the ZisK startup library did not propagate main's nonzero return",
        checker.failure,
    );
}

test "canary mode accepts the provider's current non-propagation" {
    var checker: Checker = .{ .allocator = std.testing.allocator };
    const header = responseHeader(0, 0);
    try checker.validateResponse(&header, "", true);
}

test "canary mode fails loudly when propagation appears" {
    var checker: Checker = .{ .allocator = std.testing.allocator };
    defer if (!std.mem.eql(u8, checker.failure, "ZisK failure-status check failed")) std.testing.allocator.free(checker.failure);
    const header = responseHeader(1, 4);
    try std.testing.expectError(error.CheckFailed, checker.validateResponse(&header, "boom", true));
    try std.testing.expectEqualStrings(
        "ZisK host reported failure despite --expect-no-propagation; either ZisK now propagates main's nonzero return (remove the flag and clear deviation D2) or the probe run itself broke: boom",
        checker.failure,
    );
}

test "rejects oversized response before allocation" {
    var checker: Checker = .{ .allocator = std.testing.allocator };
    defer if (!std.mem.eql(u8, checker.failure, "ZisK failure-status check failed")) std.testing.allocator.free(checker.failure);
    const header = responseHeader(1, max_response_bytes + 1);
    try std.testing.expectError(error.CheckFailed, checker.payloadSize(&header));
    try std.testing.expectEqualStrings("ZisK host response is too large: 4194305", checker.failure);
}
