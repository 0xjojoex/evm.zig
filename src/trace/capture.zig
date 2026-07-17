//! One runtime frame's concrete connection to `TraceTape`.

const tape = @import("tape.zig");

pub const TraceCapture = struct {
    tape: *tape.TraceTape,
    frame: tape.FrameHandle,
    frame_id: u32,
    pending_step: ?PendingStep = null,
    current_return_data: tape.ByteRange = .{},

    const PendingStep = struct {
        handle: tape.StepHandle,
        memory_write: ?tape.MemoryWritePlan,
    };

    pub fn init(target: *tape.TraceTape, input: tape.FrameInput) tape.Error!TraceCapture {
        const frame = try target.appendFrame(input);
        return .{
            .tape = target,
            .frame = frame,
            .frame_id = input.frame_id,
            .current_return_data = frame.initial_return_data,
        };
    }

    pub inline fn beginStep(self: *TraceCapture, input: tape.StepInput) tape.Error!void {
        if (self.pending_step != null) return error.TraceStepNotFinished;
        var step_input = input;
        step_input.frame_id = self.frame_id;
        step_input.return_data = self.current_return_data;
        self.pending_step = .{
            .handle = try self.tape.appendStep(step_input),
            .memory_write = if (self.tape.capturesMemoryWrites()) input.memory_write else null,
        };
    }

    pub inline fn finishStep(self: *TraceCapture, completion: tape.StepFinish) tape.Error!void {
        const pending = self.pending_step orelse return;
        var step_finish = completion;
        step_finish.memory_write = null;
        step_finish.return_data = self.current_return_data;
        if (pending.memory_write) |memory_write| {
            if (completion.outcome != .invalid and
                completion.outcome != .out_of_gas and
                memory_write.size != 0 and
                memory_write.offset <= completion.memory.len and
                memory_write.size <= completion.memory.len - memory_write.offset)
            {
                step_finish.memory_write = .{
                    .offset = memory_write.offset,
                    .bytes = completion.memory[memory_write.offset..][0..memory_write.size],
                };
            }
        }
        try self.tape.finishStep(pending.handle, step_finish);
        self.pending_step = null;
    }

    pub fn finishFrame(self: *TraceCapture, completion: tape.FrameFinish) tape.Error!void {
        if (self.pending_step != null) return error.TraceStepNotFinished;
        var frame_finish = completion;
        frame_finish.return_data = self.current_return_data;
        try self.tape.finishFrame(self.frame, frame_finish);
    }

    pub fn replaceReturnData(self: *TraceCapture, bytes: []const u8) tape.Error!void {
        if (self.tape.returnDataEquals(self.current_return_data, bytes)) return;
        self.current_return_data = try self.tape.storeReturnData(bytes);
    }

    pub inline fn currentReturnData(self: *const TraceCapture) tape.ByteRange {
        return self.current_return_data;
    }

    pub inline fn capturesMemoryWrites(self: *const TraceCapture) bool {
        return self.tape.capturesMemoryWrites();
    }

    pub fn setPendingMemoryWrite(self: *TraceCapture, plan: tape.MemoryWritePlan) void {
        if (!self.tape.capturesMemoryWrites()) return;
        if (self.pending_step) |*pending| pending.memory_write = plan;
    }
};

test "trace capture owns one frame and delayed step" {
    const std = @import("std");

    var target = tape.TraceTape.initGrowable(std.testing.allocator);
    defer target.deinit();
    const mark = try target.begin(.{});

    var capture = try TraceCapture.init(&target, .{
        .frame_id = 4,
        .parent_frame_id = null,
        .depth = 0,
        .kind = .root,
        .initial_stack = &.{2},
    });
    try capture.beginStep(.{
        .frame_id = undefined,
        .pc = 1,
        .opcode = 0x01,
        .gas_before = 10,
        .refund_before = 0,
        .stack_len = 1,
        .memory_size = 0,
    });
    try std.testing.expectError(error.TraceStepNotFinished, target.finish(mark));
    try capture.finishStep(.{ .pc_next = 2, .gas_after = 7, .outcome = .success, .stack = &.{3} });
    try capture.replaceReturnData(&.{ 1, 2, 3, 4 });
    try capture.replaceReturnData(&.{ 1, 2, 3, 4 });
    try capture.finishFrame(.{
        .outcome = .success,
        .memory_size = 32,
    });

    const span = try target.finish(mark);
    try std.testing.expectEqual(@as(u32, 4), span.steps[0].frame_id);
    try std.testing.expectEqual(@as(u32, 4), span.frames[0].frame_id);
    var cursor = tape.TraceCursor.init(span);
    cursor.enterFrame(span.frames[0]);
    try std.testing.expectEqualSlices(u256, &.{2}, cursor.stack().?);
    cursor.finishStep(span.steps[0]);
    try std.testing.expectEqualSlices(u256, &.{3}, cursor.stack().?);
    try std.testing.expectEqual(@as(usize, 4), span.transitions.bytes.len);
    cursor.finishFrame(span.frames[0]);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4 }, cursor.returnData());
    try target.resolve(span);
}

test "trace capture stores one memory transition only when requested" {
    const std = @import("std");

    var target = tape.TraceTape.initGrowable(std.testing.allocator);
    defer target.deinit();
    const mark = try target.begin(.{ .memory = .writes });
    var capture = try TraceCapture.init(&target, .{
        .frame_id = 0,
        .parent_frame_id = null,
        .depth = 0,
        .kind = .root,
        .initial_stack = &.{ 0x2a, 0 },
    });
    try capture.beginStep(.{
        .frame_id = undefined,
        .pc = 0,
        .opcode = 0x52,
        .gas_before = 10,
        .refund_before = 0,
        .stack_len = 2,
        .memory_size = 0,
        .memory_write = .{ .offset = 0, .size = 32 },
    });
    var memory = [_]u8{0} ** 32;
    memory[31] = 0x2a;
    try capture.finishStep(.{
        .pc_next = 1,
        .gas_after = 4,
        .outcome = .success,
        .stack = &.{},
        .memory = &memory,
    });
    try capture.finishFrame(.{ .outcome = .success, .memory_size = memory.len });
    const span = try target.finish(mark);
    defer target.resolve(span) catch unreachable;

    var cursor = tape.TraceCursor.init(span);
    cursor.enterFrame(span.frames[0]);
    cursor.finishStep(span.steps[0]);
    try std.testing.expectEqual(@as(usize, 32), cursor.memorySize());
    const writes = try cursor.memoryWrites();
    try std.testing.expectEqual(@as(usize, 1), writes.len);
    try std.testing.expectEqual(@as(u32, 0), writes[0].offset);
    try std.testing.expectEqualSlices(u8, &memory, cursor.memoryWriteBytes(writes[0]));
}
