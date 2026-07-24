const std = @import("std");
const evmz = @import("../evm.zig");

const ReentrantInstruction = struct {
    const child = evmz.addr(0x5678);
    const max_depth: u16 = 8;

    var call_count: usize = 0;
    var root_stack_moved: bool = false;
    var root_capture_stable: bool = false;
    var capture_context: ?*evmz.executor.CaptureContext = null;

    const Handler = struct {
        pub inline fn execute(comptime Instructions: type, frame: *evmz.interpreter.CallFrame) anyerror!void {
            if (!Instructions.chargeStaticGas(frame, .ADD)) return;

            const stack_before = @intFromPtr(frame.stack.base);
            const root_capture_before: ?usize = if (frame.msg.depth == 0) blk: {
                const capture = capture_context orelse return error.MissingTestCaptureContext;
                if (capture.frame_captures.items.len != 1) return error.UnexpectedActiveCaptureCount;
                break :blk @intFromPtr(&capture.frame_captures.items[0]);
            } else null;
            if (frame.msg.depth < max_depth) {
                const result = (try frame.host.call(.{
                    .depth = frame.msg.depth + 1,
                    .kind = .call,
                    .gas = 100_000,
                    .recipient = child,
                    .sender = frame.msg.recipient,
                    .input_data = &.{},
                    .value = 0,
                    .is_static = frame.msg.is_static,
                    .real_sender = frame.msg.real_sender,
                    .code_address = child,
                })).expectCall();
                if (result.status != .success) return error.ReentrantChildFailed;
                call_count += 1;
            }

            if (frame.msg.depth == 0) {
                root_stack_moved = stack_before != @intFromPtr(frame.stack.base);
                const capture = capture_context orelse return error.MissingTestCaptureContext;
                root_capture_stable = root_capture_before.? == @intFromPtr(&capture.frame_captures.items[0]);
            }
            const sentinel = try frame.stack.pop();
            try frame.stack.push(sentinel + 1);
        }
    };
};

const reentrant_cancun = blk: {
    var instruction = evmz.eth.cancun.instruction;
    instruction.table[@intFromEnum(evmz.Opcode.ADD)].target = .{ .custom = ReentrantInstruction.Handler };
    break :blk evmz.eth.cancun.extend(.{ .instruction = instruction });
};
const ReentrantVm = evmz.Vm(reentrant_cancun);

test "custom instruction host reentry refreshes the parent stack after arena growth" {
    const sender = evmz.addr(0xaaaa);
    const parent = evmz.addr(0xbbbb);
    const child = ReentrantInstruction.child;
    const filler_words = 599;
    const parent_tail = evmz.t.bytecode(.{
        .PUSH1, 0x2a,
        .ADD,   .PUSH1,
        0x2b,   .EQ,
        .PUSH0, .SSTORE,
        .STOP,
    });
    var parent_code: [filler_words + parent_tail.len]u8 = undefined;
    @memset(parent_code[0..filler_words], evmz.Opcode.PUSH0.toByte());
    @memcpy(parent_code[filler_words..], &parent_tail);
    const child_code = evmz.t.bytecode(.{
        .PUSH1, 0x2a,
        .ADD,   .PUSH1,
        0x2b,   .EQ,
        .PUSH0, .SSTORE,
        .STOP,
    });

    ReentrantInstruction.call_count = 0;
    ReentrantInstruction.root_stack_moved = false;
    ReentrantInstruction.root_capture_stable = false;

    var executor = ReentrantVm.Executor.init(std.testing.allocator, .{});
    defer executor.deinit();

    var tape = evmz.trace.TraceTape.initGrowable(std.testing.allocator);
    defer tape.deinit();
    var capture = evmz.executor.CaptureContext.init(std.testing.allocator, .{ .tape = &tape });
    defer capture.deinit();
    try capture.reserveFrameCapacity(1);
    try std.testing.expectEqual(@as(usize, 1), capture.frame_captures.capacity);
    ReentrantInstruction.capture_context = &capture;
    defer ReentrantInstruction.capture_context = null;

    var parent_account = evmz.state.MemoryAccount.init(std.testing.allocator);
    try parent_account.setCode(&parent_code);
    try executor.state.seedAccount(parent, parent_account);
    var child_account = evmz.state.MemoryAccount.init(std.testing.allocator);
    try child_account.setCode(&child_code);
    try executor.state.seedAccount(child, child_account);

    try capture.begin();
    errdefer capture.abort() catch {};
    const result = (try executor.runStandaloneCapturedRequest(.{
        .context = .{
            .chain = .{ .chain_id = 1 },
            .transaction = .{ .origin = sender },
        },
        .message = .{ .call = .{
            .sender = sender,
            .recipient = parent,
        } },
        .gas = .legacy(100_000),
    }, .{}, &capture)).expectCall();
    const span = (try capture.finish()).?;
    defer tape.resolve(span) catch unreachable;

    try std.testing.expectEqual(ReentrantVm.Interpreter.Status.success, result.status);
    try std.testing.expectEqual(@as(usize, ReentrantInstruction.max_depth), ReentrantInstruction.call_count);
    try std.testing.expect(ReentrantInstruction.root_stack_moved);
    try std.testing.expect(ReentrantInstruction.root_capture_stable);
    try std.testing.expectEqual(ReentrantVm.Executor.default_max_live_frames, capture.frame_captures.capacity);
    try std.testing.expectEqual(@as(u256, 1), try executor.getStorage(parent, 0));
    try std.testing.expectEqual(@as(u256, 1), try executor.getStorage(child, 0));

    const expected_frames = @as(usize, ReentrantInstruction.max_depth) + 1;
    try std.testing.expectEqual(expected_frames, span.frames.len);
    var opcode_counts: [expected_frames][4]usize = @splat(@splat(0));
    for (span.frames, 0..) |frame, index| {
        try std.testing.expectEqual(@as(u32, @intCast(index)), frame.frame_id);
        try std.testing.expectEqual(@as(u16, @intCast(index)), frame.depth);
        try std.testing.expectEqual(evmz.trace.TraceFrameOutcome.success, frame.outcome);
        if (index == 0) {
            try std.testing.expectEqual(@as(?u32, null), frame.parent_frame_id);
            try std.testing.expectEqual(evmz.trace.TraceFrameKind.root, frame.kind);
        } else {
            try std.testing.expectEqual(@as(?u32, @intCast(index - 1)), frame.parent_frame_id);
            try std.testing.expectEqual(evmz.trace.TraceFrameKind.call, frame.kind);
        }
    }
    for (span.steps) |step| {
        try std.testing.expect(step.frame_id < expected_frames);
        try std.testing.expectEqual(evmz.trace.TraceStepOutcome.success, step.outcome);
        const frame_index: usize = @intCast(step.frame_id);
        if (step.opcode == @intFromEnum(evmz.Opcode.ADD)) opcode_counts[frame_index][0] += 1;
        if (step.opcode == @intFromEnum(evmz.Opcode.EQ)) opcode_counts[frame_index][1] += 1;
        if (step.opcode == @intFromEnum(evmz.Opcode.SSTORE)) opcode_counts[frame_index][2] += 1;
        if (step.opcode == @intFromEnum(evmz.Opcode.STOP)) opcode_counts[frame_index][3] += 1;
    }
    for (opcode_counts) |counts| {
        try std.testing.expectEqual([4]usize{ 1, 1, 1, 1 }, counts);
    }
}
