//! One runtime frame's concrete connection to `TraceTape`.

const tape = @import("tape.zig");

pub const TraceCapture = struct {
    tape: *tape.TraceTape,
    frame: tape.FrameHandle,
    frame_id: u32,
    pending_step: ?tape.StepHandle = null,

    pub fn init(target: *tape.TraceTape, input: tape.FrameInput) tape.Error!TraceCapture {
        return .{
            .tape = target,
            .frame = try target.appendFrame(input),
            .frame_id = input.frame_id,
        };
    }

    pub inline fn beginStep(self: *TraceCapture, input: tape.StepInput) tape.Error!void {
        if (self.pending_step != null) return error.TraceStepNotFinished;
        var step_input = input;
        step_input.frame_id = self.frame_id;
        self.pending_step = try self.tape.appendStep(step_input);
    }

    pub inline fn finishStep(self: *TraceCapture, completion: tape.StepFinish) tape.Error!void {
        const handle = self.pending_step orelse return;
        try self.tape.finishStep(handle, completion);
        self.pending_step = null;
    }

    pub fn finishFrame(self: *TraceCapture, completion: tape.FrameFinish) tape.Error!void {
        if (self.pending_step != null) return error.TraceStepNotFinished;
        try self.tape.finishFrame(self.frame, completion);
    }
};

test "trace capture owns one frame and delayed step" {
    const std = @import("std");

    var target = tape.TraceTape.initGrowable(std.testing.allocator);
    defer target.deinit();
    const mark = try target.begin();

    var capture = try TraceCapture.init(&target, .{
        .frame_id = 4,
        .parent_frame_id = null,
        .depth = 0,
        .kind = .root,
    });
    try capture.beginStep(.{
        .frame_id = undefined,
        .pc = 1,
        .opcode = 0x01,
        .gas_before = 10,
        .refund_before = 0,
        .stack = &.{2},
        .memory_size = 0,
        .return_data_size = 0,
    });
    try std.testing.expectError(error.TraceStepNotFinished, target.finish(mark));
    try capture.finishStep(.{ .pc_next = 2, .gas_after = 7, .outcome = .success });
    try capture.finishFrame(.{
        .outcome = .success,
        .stack = &.{3},
        .memory_size = 32,
        .return_data_size = 4,
    });

    const span = try target.finish(mark);
    try std.testing.expectEqual(@as(u32, 4), span.steps[0].frame_id);
    try std.testing.expectEqual(@as(u32, 4), span.frames[0].frame_id);
    try std.testing.expectEqualSlices(u256, &.{3}, span.finalStackFor(span.frames[0]));
    try target.resolve(span);
}
