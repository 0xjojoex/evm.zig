//! Minimal EIP-3155 JSONL replay over a completed `TraceSpan`.
//!
//! Memory and storage contents are optional in EIP-3155 and are omitted. The
//! required return-data field references immutable blobs copied only when a
//! CALL/CREATE replacement occurs.

const std = @import("std");
const Opcode = @import("../opcode.zig").Opcode;
const tape = @import("tape.zig");

/// Minimum payload required by the EIP-3155 projection. Memory contents are
/// optional in the format, so logical size is sufficient.
pub const capture_profile: tape.CaptureProfile = .{
    .stack = .full,
    .memory = .size_only,
};

pub const Error = std.Io.Writer.Error || error{
    InvalidTraceSpan,
    InvalidRefund,
    NegativeGas,
    TraceCapabilityUnavailable,
};

pub const Summary = struct {
    state_root: [32]u8,
    output: []const u8,
    gas_used: u64,
    pass: bool,
    time_ns: ?u64 = null,
    fork: ?[]const u8 = null,
};

/// Write the required EIP-3155 per-operation JSONL objects.
///
/// Semantic validation happens before the first byte is written. Writer
/// failures may still leave partial output, as with any streaming serializer.
pub fn writeSteps(writer: *std.Io.Writer, span: tape.TraceSpan) Error!void {
    try validateSteps(span);
    var cursor = tape.TraceCursor.init(span);
    var refunds = RefundCursor{};
    while (try cursor.next()) |event| {
        switch (event) {
            .frame_enter => |frame| try refunds.enterFrame(frame),
            .step_start => |view| try writeStep(writer, view, try refunds.step(view)),
            .step_end => {},
            .frame_leave => |frame| try refunds.leaveFrame(frame),
        }
    }
}

/// Write the required final EIP-3155 summary object.
///
/// State-root calculation and transaction-result selection remain outside the
/// replay layer, so callers provide those operation-level facts explicitly.
pub fn writeSummary(writer: *std.Io.Writer, summary: Summary) std.Io.Writer.Error!void {
    try writer.writeAll("{\"stateRoot\":");
    try writeHexBytes(writer, &summary.state_root);
    try writer.writeAll(",\"output\":");
    try writeHexBytes(writer, summary.output);
    try writer.print(",\"gasUsed\":\"0x{x}\",\"pass\":{s}", .{
        summary.gas_used,
        if (summary.pass) "true" else "false",
    });
    if (summary.time_ns) |time_ns| try writer.print(",\"time\":{d}", .{time_ns});
    if (summary.fork) |fork| {
        try writer.writeAll(",\"fork\":");
        try std.json.Stringify.encodeJsonString(fork, .{}, writer);
    }
    try writer.writeAll("}\n");
}

/// Write step objects followed by the final summary object.
pub fn writeTrace(
    writer: *std.Io.Writer,
    span: tape.TraceSpan,
    summary: Summary,
) Error!void {
    try writeSteps(writer, span);
    try writeSummary(writer, summary);
}

fn validateSteps(span: tape.TraceSpan) Error!void {
    try span.require(capture_profile);
    var cursor = tape.TraceCursor.init(span);
    var refunds = RefundCursor{};
    while (try cursor.next()) |event| {
        switch (event) {
            .frame_enter => |frame| try refunds.enterFrame(frame),
            .step_start => |view| {
                if (view.row.gas_before < 0 or view.row.gas_after < 0) return error.NegativeGas;
                _ = try refunds.step(view);
            },
            .step_end => {},
            .frame_leave => |frame| try refunds.leaveFrame(frame),
        }
    }
}

fn writeStep(
    writer: *std.Io.Writer,
    view: tape.TraceCursor.StepView,
    refund: i64,
) Error!void {
    const gas_before: u64 = @intCast(view.row.gas_before);
    const gas_after: u64 = @intCast(view.row.gas_after);
    const gas_cost = gas_before -| gas_after;
    const depth = @as(u32, view.frame.depth) + 1;

    try writer.print(
        "{{\"pc\":{d},\"op\":{d},\"gas\":\"0x{x}\",\"gasCost\":\"0x{x}\",\"memSize\":{d},\"stack\":[",
        .{ view.row.pc, view.row.opcode, gas_before, gas_cost, view.state.memory_size },
    );
    for (view.state.stack.?, 0..) |word, index| {
        if (index != 0) try writer.writeByte(',');
        try writer.print("\"0x{x}\"", .{word});
    }
    try writer.print(
        "],\"depth\":{d},\"returnData\":",
        .{depth},
    );
    try writeHexBytes(writer, view.state.return_data);
    try writer.print(",\"refund\":{d}", .{refund});
    if (std.enums.fromInt(Opcode, view.row.opcode)) |opcode| {
        try writer.print(",\"opName\":\"{s}\"", .{@tagName(opcode)});
    }
    try writer.writeAll("}\n");
}

const RefundCursor = struct {
    const max_live_frames = 1025;
    const ActiveFrame = struct {
        id: u32,
        refund_base: i64,
        last_global_refund: i64,
    };

    frames: [max_live_frames]ActiveFrame = undefined,
    len: usize = 0,

    fn enterFrame(self: *RefundCursor, frame: tape.FrameRow) Error!void {
        if (self.len == self.frames.len) return error.InvalidTraceSpan;
        const refund_base = if (self.len == 0) 0 else self.frames[self.len - 1].last_global_refund;
        self.frames[self.len] = .{
            .id = frame.frame_id,
            .refund_base = refund_base,
            .last_global_refund = 0,
        };
        self.len += 1;
    }

    fn step(self: *RefundCursor, view: tape.TraceCursor.StepView) Error!i64 {
        if (self.len == 0 or self.frames[self.len - 1].id != view.row.frame_id) {
            return error.InvalidTraceSpan;
        }
        const current = &self.frames[self.len - 1];
        const refund = std.math.add(i64, current.refund_base, view.row.refund_before) catch {
            return error.InvalidRefund;
        };
        current.last_global_refund = refund;
        return refund;
    }

    fn leaveFrame(self: *RefundCursor, frame: tape.FrameRow) Error!void {
        if (self.len == 0 or self.frames[self.len - 1].id != frame.frame_id) {
            return error.InvalidTraceSpan;
        }
        self.len -= 1;
    }
};

fn writeHexBytes(writer: *std.Io.Writer, bytes: []const u8) std.Io.Writer.Error!void {
    try writer.writeAll("\"0x");
    try writer.print("{x}", .{bytes});
    try writer.writeByte('"');
}

test "EIP-3155 replay writes required step fields in canonical order" {
    var trace_tape = tape.TraceTape.initGrowable(std.testing.allocator);
    defer trace_tape.deinit();
    const mark = try trace_tape.begin(.{});
    const frame = try trace_tape.appendFrame(.{
        .frame_id = 0,
        .parent_frame_id = null,
        .depth = 0,
        .kind = .root,
    });
    const push = try trace_tape.appendStep(.{
        .frame_id = 0,
        .pc = 0,
        .opcode = @intFromEnum(Opcode.PUSH1),
        .gas_before = 100,
        .refund_before = 2,
        .stack_len = 0,
        .memory_size = 0,
    });
    try trace_tape.finishStep(push, .{ .pc_next = 2, .gas_after = 97, .outcome = .success, .stack = &.{0x2a} });
    const stop = try trace_tape.appendStep(.{
        .frame_id = 0,
        .pc = 2,
        .opcode = @intFromEnum(Opcode.STOP),
        .gas_before = 97,
        .refund_before = 2,
        .stack_len = 1,
        .memory_size = 0,
    });
    try trace_tape.finishStep(stop, .{ .pc_next = 3, .gas_after = 97, .outcome = .success, .stack = &.{0x2a} });
    try trace_tape.finishFrame(frame, .{
        .outcome = .success,
        .memory_size = 0,
    });
    const span = try trace_tape.finish(mark);
    defer trace_tape.resolve(span) catch unreachable;

    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try writeSteps(&output.writer, span);
    try std.testing.expectEqualStrings(
        "{\"pc\":0,\"op\":96,\"gas\":\"0x64\",\"gasCost\":\"0x3\",\"memSize\":0,\"stack\":[],\"depth\":1,\"returnData\":\"0x\",\"refund\":2,\"opName\":\"PUSH1\"}\n" ++
            "{\"pc\":2,\"op\":0,\"gas\":\"0x61\",\"gasCost\":\"0x0\",\"memSize\":0,\"stack\":[\"0x2a\"],\"depth\":1,\"returnData\":\"0x\",\"refund\":2,\"opName\":\"STOP\"}\n",
        output.written(),
    );
}

test "EIP-3155 replay writes caller-supplied summary" {
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try writeSummary(&output.writer, .{
        .state_root = [_]u8{0xab} ** 32,
        .output = &.{ 0x01, 0x02 },
        .gas_used = 21_000,
        .pass = true,
        .time_ns = 42,
        .fork = "Prague\npreview",
    });
    try std.testing.expectEqualStrings(
        "{\"stateRoot\":\"0xabababababababababababababababababababababababababababababababab\",\"output\":\"0x0102\",\"gasUsed\":\"0x5208\",\"pass\":true,\"time\":42,\"fork\":\"Prague\\npreview\"}\n",
        output.written(),
    );
}

test "EIP-3155 replay converts frame-local refunds to global refunds" {
    var trace_tape = tape.TraceTape.initGrowable(std.testing.allocator);
    defer trace_tape.deinit();
    const mark = try trace_tape.begin(.{});
    const parent = try trace_tape.appendFrame(.{
        .frame_id = 0,
        .parent_frame_id = null,
        .depth = 0,
        .kind = .root,
    });
    const parent_step = try trace_tape.appendStep(.{
        .frame_id = 0,
        .pc = 0,
        .opcode = @intFromEnum(Opcode.CALL),
        .gas_before = 100,
        .refund_before = 5,
        .stack_len = 0,
        .memory_size = 0,
    });
    try trace_tape.finishStep(parent_step, .{ .pc_next = 1, .gas_after = 90, .outcome = .success, .stack = &.{1} });
    const child = try trace_tape.appendFrame(.{
        .frame_id = 1,
        .parent_frame_id = 0,
        .depth = 1,
        .kind = .call,
    });
    const child_step = try trace_tape.appendStep(.{
        .frame_id = 1,
        .pc = 0,
        .opcode = @intFromEnum(Opcode.STOP),
        .gas_before = 10,
        .refund_before = 2,
        .stack_len = 0,
        .memory_size = 0,
    });
    try trace_tape.finishStep(child_step, .{ .pc_next = 1, .gas_after = 10, .outcome = .success, .stack = &.{} });
    try trace_tape.finishFrame(child, .{
        .outcome = .success,
        .memory_size = 0,
    });
    try trace_tape.finishFrame(parent, .{
        .outcome = .success,
        .memory_size = 0,
    });
    const span = try trace_tape.finish(mark);
    defer trace_tape.resolve(span) catch unreachable;

    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try writeSteps(&output.writer, span);
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "\"depth\":1,\"returnData\":\"0x\",\"refund\":5") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "\"depth\":2,\"returnData\":\"0x\",\"refund\":7") != null);
}

test "EIP-3155 replay writes versioned return data" {
    var trace_tape = tape.TraceTape.initGrowable(std.testing.allocator);
    defer trace_tape.deinit();
    const mark = try trace_tape.begin(.{});
    const frame = try trace_tape.appendFrame(.{
        .frame_id = 0,
        .parent_frame_id = null,
        .depth = 0,
        .kind = .root,
        .initial_return_data = &.{ 0xde, 0xad, 0xbe, 0xef },
    });
    const step = try trace_tape.appendStep(.{
        .frame_id = 0,
        .pc = 0,
        .opcode = @intFromEnum(Opcode.RETURNDATASIZE),
        .gas_before = 10,
        .refund_before = 0,
        .stack_len = 0,
        .memory_size = 0,
        .return_data = frame.initial_return_data,
    });
    try trace_tape.finishStep(step, .{ .pc_next = 1, .gas_after = 8, .outcome = .success, .stack = &.{4} });
    try trace_tape.finishFrame(frame, .{
        .outcome = .success,
        .memory_size = 0,
        .return_data = frame.initial_return_data,
    });
    const span = try trace_tape.finish(mark);
    defer trace_tape.resolve(span) catch unreachable;

    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try writeSteps(&output.writer, span);
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "\"returnData\":\"0xdeadbeef\"") != null);
}
