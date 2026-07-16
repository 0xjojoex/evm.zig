//! Concrete, replay-only execution trace storage.
//!
//! `TraceTape` is intentionally independent of observer and serializer types.
//! One operation records between `begin` and `finish`; the resulting borrowed
//! `TraceSpan` remains stable until `resolve`. Capture failure uses `abort` to
//! restore every buffer to the operation mark.

const std = @import("std");

const Allocator = std.mem.Allocator;

pub const Error = Allocator.Error || error{
    TraceCapacityExceeded,
    TraceIndexOverflow,
    TraceOperationActive,
    TraceOperationNotActive,
    TraceSpanOutstanding,
    InvalidTraceMark,
    InvalidTraceHandle,
    TraceStepAlreadyFinished,
    TraceStepNotFinished,
    TraceFrameAlreadyFinished,
    TraceFrameNotFinished,
};

pub const WordRange = struct {
    offset: u32,
    len: u32,
};

pub const StepOutcome = enum(u8) {
    pending,
    success,
    invalid,
    revert,
    out_of_gas,
};

pub const StepRow = struct {
    gas_before: i64,
    gas_after: i64 = 0,
    refund_before: i64,
    stack: WordRange,
    frame_id: u32,
    pc: u32,
    pc_next: u32 = 0,
    memory_size: u32,
    return_data_size: u32,
    opcode: u8,
    outcome: StepOutcome = .pending,
};

comptime {
    if (@sizeOf(StepRow) > 56) @compileError("trace step row exceeded its compact layout budget");
}

pub const FrameKind = enum(u8) {
    root,
    call,
    callcode,
    delegatecall,
    staticcall,
    create,
    create2,
};

pub const FrameOutcome = enum(u8) {
    pending,
    success,
    invalid,
    revert,
    out_of_gas,
};

pub const FrameRow = struct {
    frame_id: u32,
    parent_frame_id: ?u32,
    final_stack: WordRange = .{ .offset = 0, .len = 0 },
    final_memory_size: u32 = 0,
    final_return_data_size: u32 = 0,
    depth: u16,
    kind: FrameKind,
    outcome: FrameOutcome = .pending,
};

comptime {
    if (@sizeOf(FrameRow) > 32) @compileError("trace frame row exceeded its compact layout budget");
}

pub const StepInput = struct {
    frame_id: u32,
    pc: usize,
    opcode: u8,
    gas_before: i64,
    refund_before: i64,
    stack: []const u256,
    memory_size: usize,
    return_data_size: usize,
};

pub const StepFinish = struct {
    pc_next: usize,
    gas_after: i64,
    outcome: StepOutcome,
};

pub const FrameInput = struct {
    frame_id: u32,
    parent_frame_id: ?u32,
    depth: u16,
    kind: FrameKind,
};

pub const FrameFinish = struct {
    outcome: FrameOutcome,
    stack: []const u256,
    memory_size: usize,
    return_data_size: usize,
};

pub const StepHandle = struct {
    generation: u64,
    index: u32,
};

pub const FrameHandle = struct {
    generation: u64,
    index: u32,
};

pub const TraceMark = struct {
    generation: u64,
    steps_len: usize,
    frames_len: usize,
    stack_words_len: usize,
};

/// Borrowed rows for one completed operation.
///
/// These slices remain valid only while the originating tape keeps this span
/// outstanding. Call `TraceTape.resolve` before reusing or resetting the tape.
pub const TraceSpan = struct {
    generation: u64,
    steps: []const StepRow,
    frames: []const FrameRow,
    stack_words: []const u256,

    pub fn stackFor(self: TraceSpan, row: StepRow) []const u256 {
        return self.stackForRange(row.stack);
    }

    pub fn finalStackFor(self: TraceSpan, frame: FrameRow) []const u256 {
        return self.stackForRange(frame.final_stack);
    }

    fn stackForRange(self: TraceSpan, range: WordRange) []const u256 {
        const offset: usize = range.offset;
        const len: usize = range.len;
        std.debug.assert(offset + len <= self.stack_words.len);
        return self.stack_words[offset..][0..len];
    }
};

pub const BoundedStorage = struct {
    steps: []StepRow,
    frames: []FrameRow,
    stack_words: []u256,
};

pub const TraceTape = struct {
    allocator: ?Allocator,
    steps: std.ArrayList(StepRow),
    frames: std.ArrayList(FrameRow),
    stack_words: std.ArrayList(u256),
    phase: Phase = .idle,
    generation: u64 = 0,
    active_mark: TraceMark = undefined,
    pending_steps: usize = 0,
    pending_frames: usize = 0,

    const Phase = enum {
        idle,
        recording,
        outstanding,
    };

    const no_growth_allocator: Allocator = .{
        .ptr = undefined,
        .vtable = &.{
            .alloc = Allocator.noAlloc,
            .resize = Allocator.noResize,
            .remap = Allocator.noRemap,
            .free = Allocator.noFree,
        },
    };

    pub fn initGrowable(allocator: Allocator) TraceTape {
        return .{
            .allocator = allocator,
            .steps = .empty,
            .frames = .empty,
            .stack_words = .empty,
        };
    }

    pub fn initBounded(storage: BoundedStorage) TraceTape {
        return .{
            .allocator = null,
            .steps = .initBuffer(storage.steps),
            .frames = .initBuffer(storage.frames),
            .stack_words = .initBuffer(storage.stack_words),
        };
    }

    pub fn deinit(self: *TraceTape) void {
        std.debug.assert(self.phase == .idle);
        if (self.allocator) |allocator| {
            self.steps.deinit(allocator);
            self.frames.deinit(allocator);
            self.stack_words.deinit(allocator);
        }
        self.* = undefined;
    }

    pub fn begin(self: *TraceTape) Error!TraceMark {
        switch (self.phase) {
            .idle => {},
            .recording => return error.TraceOperationActive,
            .outstanding => return error.TraceSpanOutstanding,
        }

        self.generation +%= 1;
        self.active_mark = .{
            .generation = self.generation,
            .steps_len = self.steps.items.len,
            .frames_len = self.frames.items.len,
            .stack_words_len = self.stack_words.items.len,
        };
        self.pending_steps = 0;
        self.pending_frames = 0;
        self.phase = .recording;
        return self.active_mark;
    }

    pub fn appendStep(self: *TraceTape, input: StepInput) Error!StepHandle {
        try self.requireRecording();

        const pc = try index32(input.pc);
        const memory_size = try index32(input.memory_size);
        const return_data_size = try index32(input.return_data_size);
        const stack_range = try relativeRange(
            self.stack_words.items.len,
            self.active_mark.stack_words_len,
            input.stack.len,
        );
        const row_index = try index32(self.steps.items.len);

        try self.ensureUnusedCapacity(&self.steps, 1);
        try self.ensureUnusedCapacity(&self.stack_words, input.stack.len);

        self.stack_words.appendSliceAssumeCapacity(input.stack);
        self.steps.appendAssumeCapacity(.{
            .frame_id = input.frame_id,
            .pc = pc,
            .opcode = input.opcode,
            .gas_before = input.gas_before,
            .refund_before = input.refund_before,
            .stack = .{ .offset = stack_range.offset, .len = stack_range.len },
            .memory_size = memory_size,
            // Q: When a concrete replay consumer needs return-data contents,
            // should the tape add versioned byte snapshots instead of copying
            // potentially large buffers for every step?
            // We only store the size here, return data can be large,
            // borrowing the live buffer would be unsafe because later calls replace it.
            // There's no way to reconstruct the exact return-data bytes visible at an arbitrary step currently.
            .return_data_size = return_data_size,
        });
        self.pending_steps += 1;

        return .{ .generation = self.generation, .index = row_index };
    }

    pub fn finishStep(self: *TraceTape, handle: StepHandle, completion: StepFinish) Error!void {
        try self.requireRecording();
        const row = try self.stepFromHandle(handle);
        if (row.outcome != .pending) return error.TraceStepAlreadyFinished;
        if (completion.outcome == .pending) return error.TraceStepNotFinished;

        row.pc_next = try index32(completion.pc_next);
        row.gas_after = completion.gas_after;
        row.outcome = completion.outcome;
        self.pending_steps -= 1;
    }

    pub fn appendFrame(self: *TraceTape, input: FrameInput) Error!FrameHandle {
        try self.requireRecording();
        const row_index = try index32(self.frames.items.len);
        try self.ensureUnusedCapacity(&self.frames, 1);
        self.frames.appendAssumeCapacity(.{
            .frame_id = input.frame_id,
            .parent_frame_id = input.parent_frame_id,
            .depth = input.depth,
            .kind = input.kind,
        });
        self.pending_frames += 1;
        return .{ .generation = self.generation, .index = row_index };
    }

    pub fn finishFrame(self: *TraceTape, handle: FrameHandle, completion: FrameFinish) Error!void {
        try self.requireRecording();
        const row = try self.frameFromHandle(handle);
        if (row.outcome != .pending) return error.TraceFrameAlreadyFinished;
        if (completion.outcome == .pending) return error.TraceFrameNotFinished;

        const memory_size = try index32(completion.memory_size);
        const return_data_size = try index32(completion.return_data_size);
        const stack_range = try relativeRange(
            self.stack_words.items.len,
            self.active_mark.stack_words_len,
            completion.stack.len,
        );
        try self.ensureUnusedCapacity(&self.stack_words, completion.stack.len);

        self.stack_words.appendSliceAssumeCapacity(completion.stack);
        row.final_stack = stack_range;
        row.final_memory_size = memory_size;
        row.final_return_data_size = return_data_size;
        row.outcome = completion.outcome;
        self.pending_frames -= 1;
    }

    pub fn finish(self: *TraceTape, mark: TraceMark) Error!TraceSpan {
        try self.requireMark(mark);
        if (self.pending_steps != 0) return error.TraceStepNotFinished;
        if (self.pending_frames != 0) return error.TraceFrameNotFinished;

        self.phase = .outstanding;
        return .{
            .generation = self.generation,
            .steps = self.steps.items[mark.steps_len..],
            .frames = self.frames.items[mark.frames_len..],
            .stack_words = self.stack_words.items[mark.stack_words_len..],
        };
    }

    pub fn resolve(self: *TraceTape, span: TraceSpan) Error!void {
        if (self.phase != .outstanding or span.generation != self.generation) {
            return error.InvalidTraceHandle;
        }
        self.phase = .idle;
    }

    pub fn abort(self: *TraceTape, mark: TraceMark) Error!void {
        try self.requireMark(mark);
        self.steps.items.len = mark.steps_len;
        self.frames.items.len = mark.frames_len;
        self.stack_words.items.len = mark.stack_words_len;
        self.pending_steps = 0;
        self.pending_frames = 0;
        self.phase = .idle;
    }

    pub fn reset(self: *TraceTape) Error!void {
        switch (self.phase) {
            .idle => {},
            .recording => return error.TraceOperationActive,
            .outstanding => return error.TraceSpanOutstanding,
        }
        self.steps.clearRetainingCapacity();
        self.frames.clearRetainingCapacity();
        self.stack_words.clearRetainingCapacity();
    }

    pub fn stepCount(self: *const TraceTape) usize {
        return self.steps.items.len;
    }

    pub fn frameCount(self: *const TraceTape) usize {
        return self.frames.items.len;
    }

    fn requireRecording(self: *const TraceTape) Error!void {
        switch (self.phase) {
            .recording => {},
            .idle => return error.TraceOperationNotActive,
            .outstanding => return error.TraceSpanOutstanding,
        }
    }

    fn requireMark(self: *const TraceTape, mark: TraceMark) Error!void {
        try self.requireRecording();
        if (!std.meta.eql(mark, self.active_mark)) return error.InvalidTraceMark;
    }

    fn stepFromHandle(self: *TraceTape, handle: StepHandle) Error!*StepRow {
        if (handle.generation != self.generation) return error.InvalidTraceHandle;
        const index: usize = handle.index;
        if (index < self.active_mark.steps_len or index >= self.steps.items.len) {
            return error.InvalidTraceHandle;
        }
        return &self.steps.items[index];
    }

    fn frameFromHandle(self: *TraceTape, handle: FrameHandle) Error!*FrameRow {
        if (handle.generation != self.generation) return error.InvalidTraceHandle;
        const index: usize = handle.index;
        if (index < self.active_mark.frames_len or index >= self.frames.items.len) {
            return error.InvalidTraceHandle;
        }
        return &self.frames.items[index];
    }

    fn ensureUnusedCapacity(self: *TraceTape, list: anytype, additional: usize) Error!void {
        list.ensureUnusedCapacity(self.allocator orelse no_growth_allocator, additional) catch |err| {
            if (self.allocator == null) return error.TraceCapacityExceeded;
            return err;
        };
    }
};

fn index32(value: usize) Error!u32 {
    return std.math.cast(u32, value) orelse error.TraceIndexOverflow;
}

fn relativeRange(absolute_start: usize, operation_start: usize, len: usize) Error!WordRange {
    std.debug.assert(absolute_start >= operation_start);
    const offset = absolute_start - operation_start;
    const end = std.math.add(usize, offset, len) catch return error.TraceIndexOverflow;
    if (end > std.math.maxInt(u32)) return error.TraceIndexOverflow;
    return .{
        .offset = try index32(offset),
        .len = try index32(len),
    };
}

test "trace tape appends patches and exposes one stable replay span" {
    var tape = TraceTape.initGrowable(std.testing.allocator);
    defer tape.deinit();

    const mark = try tape.begin();
    const frame = try tape.appendFrame(.{
        .frame_id = 7,
        .parent_frame_id = null,
        .depth = 0,
        .kind = .root,
    });
    const step = try tape.appendStep(.{
        .frame_id = 7,
        .pc = 3,
        .opcode = 0x01,
        .gas_before = 100,
        .refund_before = 2,
        .stack = &.{ 11, 12 },
        .memory_size = 32,
        .return_data_size = 2,
    });
    try tape.finishStep(step, .{
        .pc_next = 4,
        .gas_after = 97,
        .outcome = .success,
    });
    try tape.finishFrame(frame, .{
        .outcome = .success,
        .stack = &.{21},
        .memory_size = 64,
        .return_data_size = 5,
    });

    const span = try tape.finish(mark);
    try std.testing.expectEqual(@as(usize, 1), span.steps.len);
    try std.testing.expectEqual(@as(usize, 1), span.frames.len);
    try std.testing.expectEqual(@as(u32, 3), span.steps[0].pc);
    try std.testing.expectEqual(@as(u32, 4), span.steps[0].pc_next);
    try std.testing.expectEqual(@as(i64, 97), span.steps[0].gas_after);
    try std.testing.expectEqual(StepOutcome.success, span.steps[0].outcome);
    try std.testing.expectEqualSlices(u256, &.{ 11, 12 }, span.stackFor(span.steps[0]));
    try std.testing.expectEqual(@as(u32, 2), span.steps[0].return_data_size);
    try std.testing.expectEqual(FrameOutcome.success, span.frames[0].outcome);
    try std.testing.expectEqualSlices(u256, &.{21}, span.finalStackFor(span.frames[0]));
    try std.testing.expectEqual(@as(u32, 64), span.frames[0].final_memory_size);
    try std.testing.expectEqual(@as(u32, 5), span.frames[0].final_return_data_size);

    try std.testing.expectError(error.TraceSpanOutstanding, tape.begin());
    try std.testing.expectError(error.TraceSpanOutstanding, tape.reset());
    try tape.resolve(span);
    try tape.reset();
    try std.testing.expectEqual(@as(usize, 0), tape.stepCount());
    try std.testing.expectEqual(@as(usize, 0), tape.frameCount());
}

test "bounded trace tape rejects frame-end stack growth atomically" {
    var step_storage: [0]StepRow = undefined;
    var frame_storage: [1]FrameRow = undefined;
    var stack_storage: [1]u256 = undefined;
    var tape = TraceTape.initBounded(.{
        .steps = &step_storage,
        .frames = &frame_storage,
        .stack_words = &stack_storage,
    });
    defer tape.deinit();

    const mark = try tape.begin();
    const frame = try tape.appendFrame(.{
        .frame_id = 0,
        .parent_frame_id = null,
        .depth = 0,
        .kind = .root,
    });
    try std.testing.expectError(error.TraceCapacityExceeded, tape.finishFrame(frame, .{
        .outcome = .success,
        .stack = &.{ 1, 2 },
        .memory_size = 32,
        .return_data_size = 4,
    }));
    try std.testing.expectEqual(FrameOutcome.pending, tape.frames.items[0].outcome);
    try std.testing.expectEqual(@as(usize, 0), tape.stack_words.items.len);
    try tape.abort(mark);
}

test "bounded trace tape reports capacity without partial append" {
    var step_storage: [1]StepRow = undefined;
    var frame_storage: [1]FrameRow = undefined;
    var stack_storage: [1]u256 = undefined;
    var tape = TraceTape.initBounded(.{
        .steps = &step_storage,
        .frames = &frame_storage,
        .stack_words = &stack_storage,
    });
    defer tape.deinit();

    const mark = try tape.begin();
    try std.testing.expectError(error.TraceCapacityExceeded, tape.appendStep(.{
        .frame_id = 0,
        .pc = 0,
        .opcode = 0,
        .gas_before = 0,
        .refund_before = 0,
        .stack = &.{ 1, 2 },
        .memory_size = 0,
        .return_data_size = 0,
    }));
    try std.testing.expectEqual(@as(usize, 0), tape.stepCount());

    const step = try tape.appendStep(.{
        .frame_id = 0,
        .pc = 0,
        .opcode = 0,
        .gas_before = 0,
        .refund_before = 0,
        .stack = &.{1},
        .memory_size = 0,
        .return_data_size = 1,
    });
    try tape.finishStep(step, .{ .pc_next = 1, .gas_after = 0, .outcome = .success });
    const span = try tape.finish(mark);
    try std.testing.expectEqual(@as(usize, 1), span.steps.len);
    try tape.resolve(span);
}

test "trace tape abort restores every operation buffer" {
    var tape = TraceTape.initGrowable(std.testing.allocator);
    defer tape.deinit();

    const first_mark = try tape.begin();
    const first_step = try tape.appendStep(.{
        .frame_id = 0,
        .pc = 0,
        .opcode = 0,
        .gas_before = 1,
        .refund_before = 0,
        .stack = &.{1},
        .memory_size = 0,
        .return_data_size = 1,
    });
    try tape.finishStep(first_step, .{ .pc_next = 1, .gas_after = 0, .outcome = .success });
    const first_span = try tape.finish(first_mark);
    try tape.resolve(first_span);

    const second_mark = try tape.begin();
    _ = try tape.appendStep(.{
        .frame_id = 1,
        .pc = 2,
        .opcode = 1,
        .gas_before = 2,
        .refund_before = 0,
        .stack = &.{ 2, 3 },
        .memory_size = 4,
        .return_data_size = 2,
    });
    try tape.abort(second_mark);

    try std.testing.expectEqual(@as(usize, 1), tape.stepCount());
    const third_mark = try tape.begin();
    const third_span = try tape.finish(third_mark);
    try std.testing.expectEqual(@as(usize, 0), third_span.steps.len);
    try std.testing.expectEqual(@as(usize, 0), third_span.stack_words.len);
    try tape.resolve(third_span);
}

test "trace tape refuses unfinished and stale handles" {
    var tape = TraceTape.initGrowable(std.testing.allocator);
    defer tape.deinit();

    const mark = try tape.begin();
    const step = try tape.appendStep(.{
        .frame_id = 0,
        .pc = 0,
        .opcode = 0,
        .gas_before = 0,
        .refund_before = 0,
        .stack = &.{},
        .memory_size = 0,
        .return_data_size = 0,
    });
    try std.testing.expectError(error.TraceStepNotFinished, tape.finish(mark));
    try tape.finishStep(step, .{ .pc_next = 1, .gas_after = 0, .outcome = .success });
    try std.testing.expectError(
        error.TraceStepAlreadyFinished,
        tape.finishStep(step, .{ .pc_next = 1, .gas_after = 0, .outcome = .success }),
    );
    const span = try tape.finish(mark);
    try tape.resolve(span);

    const next_mark = try tape.begin();
    try std.testing.expectError(
        error.InvalidTraceHandle,
        tape.finishStep(step, .{ .pc_next = 1, .gas_after = 0, .outcome = .success }),
    );
    try tape.abort(next_mark);
}
