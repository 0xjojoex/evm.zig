//! Concrete, replay-only execution trace storage.
//!
//! `TraceTape` is intentionally independent of observer and serializer types.
//! One operation records between `begin` and `finish`; the resulting borrowed
//! `TraceSpan` remains stable until `resolve`. Capture failure uses `abort` to
//! restore every buffer to the operation mark.

const std = @import("std");
pub const step_table = @import("step_table.zig");
pub const transition_arena = @import("transition_arena.zig");

const Allocator = std.mem.Allocator;

pub const Error = Allocator.Error || error{
    TraceCapacityExceeded,
    TraceIndexOverflow,
    TraceOperationActive,
    TraceOperationNotActive,
    TraceSpanOutstanding,
    InvalidTraceMark,
    InvalidTraceHandle,
    InvalidTraceSpan,
    TraceStepAlreadyFinished,
    TraceStepNotFinished,
    TraceFrameAlreadyFinished,
    TraceFrameNotFinished,
    TraceCapabilityUnavailable,
};

pub const StackCapture = enum {
    omitted,
    full,
};

pub const MemoryCapture = enum {
    size_only,
    writes,
};

/// Immutable payload policy for one captured operation.
///
/// The profile is selected when recording begins and copied into the completed
/// span. It changes tape payload only; it never generates another tail table.
pub const CaptureProfile = struct {
    stack: StackCapture = .full,
    memory: MemoryCapture = .size_only,

    pub fn includes(self: CaptureProfile, required: CaptureProfile) bool {
        const has_stack = required.stack == .omitted or self.stack == .full;
        const has_memory = required.memory == .size_only or self.memory == .writes;
        return has_stack and has_memory;
    }
};

pub const WordRange = transition_arena.WordRange;
pub const ByteRange = transition_arena.ByteRange;
pub const MemoryWriteRange = transition_arena.MemoryWriteRange;
pub const MemoryWrite = transition_arena.MemoryWrite;
pub const StepTransitionRef = transition_arena.StepTransitionRef;
pub const StackTransition = transition_arena.StackTransition;
pub const MemoryTransition = transition_arena.MemoryTransition;
pub const ReturnDataTransition = transition_arena.ReturnDataTransition;
pub const FrameTransition = transition_arena.FrameTransition;

pub const MemoryWritePlan = struct {
    offset: usize,
    size: usize,
};

pub const MemoryWriteInput = struct {
    offset: usize,
    bytes: []const u8,
};

pub const TraceOutcome = step_table.TraceOutcome;
pub const StepOutcome = step_table.StepOutcome;
pub const StepRow = step_table.StepRow;
pub const FrameKind = step_table.FrameKind;
pub const FrameOutcome = step_table.FrameOutcome;
pub const FrameRow = step_table.FrameRow;
pub const StepTable = step_table.Table;
pub const TransitionArena = transition_arena.Arena;

pub const StepInput = struct {
    frame_id: u32,
    pc: usize,
    opcode: u8,
    gas_before: i64,
    refund_before: i64,
    stack_len: usize,
    /// Length of the unchanged stack prefix, resolved by the exact specification.
    /// Zero is always a correct full-snapshot fallback.
    stack_prefix_len: usize = 0,
    memory_size: usize,
    return_data: ByteRange = .{},
    memory_write: ?MemoryWritePlan = null,
};

pub const StepFinish = struct {
    pc_next: usize,
    gas_after: i64,
    outcome: StepOutcome,
    stack: []const u256,
    memory: []const u8 = &.{},
    memory_write: ?MemoryWriteInput = null,
    return_data: ByteRange = .{},
};

pub const FrameInput = struct {
    frame_id: u32,
    parent_frame_id: ?u32,
    depth: u16,
    kind: FrameKind,
    initial_stack: []const u256 = &.{},
    initial_memory_size: usize = 0,
    parent_stack: []const u256 = &.{},
    parent_memory_size: usize = 0,
    parent_return_data: ByteRange = .{},
    initial_return_data: []const u8 = &.{},
};

pub const FrameFinish = struct {
    outcome: FrameOutcome,
    memory_size: usize,
    return_data: ByteRange = .{},
};

pub const StepHandle = struct {
    generation: u64,
    index: u32,
    stack_before_len: u16,
    stack_prefix_len: u16,
    memory_before_size: u32,
    return_data_before: ByteRange,
};

pub const FrameHandle = struct {
    generation: u64,
    index: u32,
    initial_return_data: ByteRange,
};

pub const TraceMark = struct {
    generation: u64,
    table: step_table.Mark,
    transitions: transition_arena.Mark,
};

/// Borrowed rows for one completed operation.
///
/// These slices remain valid only while the originating tape keeps this span
/// outstanding. Call `TraceTape.resolve` before reusing or resetting the tape.
pub const TraceSpan = struct {
    owner: *const TraceTape,
    generation: u64,
    profile: CaptureProfile,
    steps: []const StepRow,
    frames: []const FrameRow,
    transitions: transition_arena.Span,

    pub fn require(self: TraceSpan, required: CaptureProfile) error{TraceCapabilityUnavailable}!void {
        if (!self.profile.includes(required)) return error.TraceCapabilityUnavailable;
    }
};

/// Sequential materializer for the current frame's stack.
///
/// Nested replay keeps one stack image: child frame rows carry the parent's
/// post-pop checkpoint, so leaving a child restores the parent without an
/// allocator or one 1024-word buffer per live frame.
pub const TraceCursor = struct {
    const max_live_frames = 1025;

    const ActiveFrame = struct {
        id: u32,
        pending_step: ?usize = null,
    };

    pub const StateView = struct {
        /// `null` means stack words were omitted; an empty slice is an exact
        /// captured empty stack.
        stack: ?[]const u256,
        memory_size: usize,
        return_data: []const u8,
    };

    pub const StepView = struct {
        row: StepRow,
        frame: FrameRow,
        state: StateView,
        terminal: bool = false,
    };

    pub const Event = union(enum) {
        frame_enter: FrameRow,
        step_start: StepView,
        step_end: StepView,
        frame_leave: FrameRow,
    };

    span: TraceSpan,
    stack_words: [1024]u256 = undefined,
    stack_len: usize = 0,
    memory_size: u32 = 0,
    return_data: ByteRange = .{},
    last_memory_writes: MemoryWriteRange = .{},
    frame_id: ?u32 = null,
    active_frames: [max_live_frames]ActiveFrame = undefined,
    active_len: usize = 0,
    next_step: usize = 0,
    pending_leave: ?FrameRow = null,
    root_entered: bool = false,

    pub fn init(span: TraceSpan) TraceCursor {
        return .{ .span = span };
    }

    /// Yield the canonical nested-frame replay sequence.
    ///
    /// State slices remain valid only until the next call. The cursor is the
    /// sole interpreter of transition streams; replay consumers project these
    /// validated views without reconstructing frame or machine state.
    pub fn next(self: *TraceCursor) error{InvalidTraceSpan}!?Event {
        if (self.pending_leave) |leaving| {
            self.pending_leave = null;
            std.debug.assert(self.active_len > 0);
            std.debug.assert(self.active_frames[self.active_len - 1].id == leaving.frame_id);
            self.active_len -= 1;
            if (self.active_len > 0) self.leaveFrame(leaving);
            return .{ .frame_leave = leaving };
        }

        const next_row = if (self.next_step < self.span.steps.len)
            self.span.steps[self.next_step]
        else
            null;

        if (self.active_len == 0) {
            const row = next_row orelse return null;
            if (self.root_entered) return error.InvalidTraceSpan;
            const frame = try self.frameById(row.frame_id);
            if (frame.parent_frame_id != null) return error.InvalidTraceSpan;
            self.active_frames[0] = .{ .id = frame.frame_id };
            self.active_len = 1;
            self.root_entered = true;
            self.enterFrame(frame);
            return .{ .frame_enter = frame };
        }

        const current = &self.active_frames[self.active_len - 1];
        if (next_row) |row| {
            if (row.frame_id == current.id) {
                if (current.pending_step) |row_index| {
                    current.pending_step = null;
                    return .{ .step_end = try self.finishStepView(row_index, false) };
                }

                const frame = try self.frameById(row.frame_id);
                self.next_step += 1;
                current.pending_step = self.next_step - 1;
                return .{ .step_start = .{
                    .row = row,
                    .frame = frame,
                    .state = self.stateView(),
                } };
            }

            const row_frame = try self.frameById(row.frame_id);
            if (row_frame.parent_frame_id == current.id) {
                if (self.active_len == self.active_frames.len) return error.InvalidTraceSpan;
                self.active_frames[self.active_len] = .{ .id = row_frame.frame_id };
                self.active_len += 1;
                self.enterFrame(row_frame);
                return .{ .frame_enter = row_frame };
            }
        }

        const leaving = try self.frameById(current.id);
        if (current.pending_step) |row_index| {
            current.pending_step = null;
            const view = try self.finishStepView(row_index, true);
            self.pending_leave = leaving;
            return .{ .step_end = view };
        }

        return error.InvalidTraceSpan;
    }

    pub fn enterFrame(self: *TraceCursor, frame: FrameRow) void {
        self.restoreCheckpoint(self.frameTransition(frame).initial);
        self.frame_id = frame.frame_id;
    }

    pub fn leaveFrame(self: *TraceCursor, frame: FrameRow) void {
        self.restoreCheckpoint(self.frameTransition(frame).parent);
        self.frame_id = frame.parent_frame_id;
    }

    pub fn stack(self: *const TraceCursor) ?[]const u256 {
        if (self.span.profile.stack == .omitted) return null;
        return self.stack_words[0..self.stack_len];
    }

    pub fn memorySize(self: *const TraceCursor) usize {
        return self.memory_size;
    }

    pub fn returnData(self: *const TraceCursor) []const u8 {
        return self.bytesFor(self.return_data);
    }

    pub fn memoryWrites(self: *const TraceCursor) error{TraceCapabilityUnavailable}![]const MemoryWrite {
        if (self.span.profile.memory != .writes) return error.TraceCapabilityUnavailable;
        const offset: usize = self.last_memory_writes.offset;
        const len: usize = self.last_memory_writes.len;
        std.debug.assert(offset + len <= self.span.transitions.memory_writes.len);
        return self.span.transitions.memory_writes[offset..][0..len];
    }

    pub fn memoryWriteBytes(self: *const TraceCursor, write: MemoryWrite) []const u8 {
        return self.bytesFor(write.bytes);
    }

    fn stateView(self: *const TraceCursor) StateView {
        return .{
            .stack = self.stack(),
            .memory_size = self.memorySize(),
            .return_data = self.returnData(),
        };
    }

    fn finishStepView(self: *TraceCursor, row_index: usize, terminal: bool) error{InvalidTraceSpan}!StepView {
        if (row_index >= self.span.steps.len) return error.InvalidTraceSpan;
        const row = self.span.steps[row_index];
        const frame = try self.frameById(row.frame_id);
        self.finishStep(row);
        if (terminal) self.finishFrame(frame);
        return .{
            .row = row,
            .frame = frame,
            .state = self.stateView(),
            .terminal = terminal,
        };
    }

    fn frameById(self: *const TraceCursor, frame_id: u32) error{InvalidTraceSpan}!FrameRow {
        const index: usize = frame_id;
        if (index < self.span.frames.len and self.span.frames[index].frame_id == frame_id) {
            return self.span.frames[index];
        }
        for (self.span.frames) |frame| {
            if (frame.frame_id == frame_id) return frame;
        }
        return error.InvalidTraceSpan;
    }

    pub fn finishStep(self: *TraceCursor, row: StepRow) void {
        std.debug.assert(self.frame_id == row.frame_id);
        const transition_index: usize = row.transition_offset;
        std.debug.assert(transition_index < self.span.transitions.step_refs.len);
        const transition_ref = self.span.transitions.step_refs[transition_index];
        if (transition_ref.stack != transition_arena.no_transition) {
            std.debug.assert(self.span.profile.stack == .full);
            std.debug.assert(transition_ref.stack < self.span.transitions.stack.len);
            const stack_transition = self.span.transitions.stack[transition_ref.stack];
            const keep_len: usize = stack_transition.keep_len;
            // A suspended CALL/CREATE restores the parent checkpoint after its
            // operands were popped, so the kept prefix may already be materialized.
            std.debug.assert(self.stack_len == stack_transition.before_len or self.stack_len == keep_len);
            const appended = self.wordsFor(stack_transition.append);
            std.debug.assert(keep_len <= self.stack_len);
            std.debug.assert(keep_len + appended.len <= self.stack_words.len);
            @memcpy(self.stack_words[keep_len..][0..appended.len], appended);
            self.stack_len = keep_len + appended.len;
        } else {
            std.debug.assert(self.span.profile.stack == .omitted);
        }
        self.last_memory_writes = .{};
        if (transition_ref.memory != transition_arena.no_transition) {
            std.debug.assert(transition_ref.memory < self.span.transitions.memory.len);
            const memory_transition = self.span.transitions.memory[transition_ref.memory];
            self.memory_size = memory_transition.after_size;
            self.last_memory_writes = memory_transition.writes;
        }
        if (transition_ref.return_data != transition_arena.no_transition) {
            std.debug.assert(transition_ref.return_data < self.span.transitions.return_data.len);
            self.return_data = self.span.transitions.return_data[transition_ref.return_data].after;
        }
    }

    pub fn finishFrame(self: *TraceCursor, frame: FrameRow) void {
        std.debug.assert(self.frame_id == frame.frame_id);
        const transition = self.frameTransition(frame);
        self.memory_size = transition.final_memory_size;
        self.return_data = transition.final_return_data;
        self.last_memory_writes = .{};
    }

    fn frameTransition(self: *const TraceCursor, frame: FrameRow) FrameTransition {
        const index: usize = frame.transition_offset;
        std.debug.assert(index < self.span.transitions.frames.len);
        return self.span.transitions.frames[index];
    }

    fn restoreCheckpoint(self: *TraceCursor, checkpoint: transition_arena.StateCheckpoint) void {
        if (self.span.profile.stack == .full) {
            self.replaceStack(self.wordsFor(checkpoint.stack));
        } else {
            self.stack_len = 0;
        }
        self.memory_size = checkpoint.memory_size;
        self.return_data = checkpoint.return_data;
        self.last_memory_writes = .{};
    }

    fn wordsFor(self: *const TraceCursor, range: WordRange) []const u256 {
        const offset: usize = range.offset;
        const len: usize = range.len;
        std.debug.assert(offset + len <= self.span.transitions.words.len);
        return self.span.transitions.words[offset..][0..len];
    }

    fn bytesFor(self: *const TraceCursor, range: ByteRange) []const u8 {
        const offset: usize = range.offset;
        const len: usize = range.len;
        std.debug.assert(offset + len <= self.span.transitions.bytes.len);
        return self.span.transitions.bytes[offset..][0..len];
    }

    fn replaceStack(self: *TraceCursor, values: []const u256) void {
        std.debug.assert(values.len <= self.stack_words.len);
        @memcpy(self.stack_words[0..values.len], values);
        self.stack_len = values.len;
    }
};

pub const BoundedStorage = struct {
    table: step_table.BoundedStorage,
    transitions: transition_arena.BoundedStorage,
};

pub const TraceTape = struct {
    table: StepTable,
    transitions: TransitionArena,
    phase: Phase = .idle,
    generation: u64 = 0,
    active_mark: TraceMark = undefined,
    active_profile: CaptureProfile = .{},
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
            .table = .initGrowable(allocator),
            .transitions = .initGrowable(allocator),
        };
    }

    pub fn initBounded(storage: BoundedStorage) TraceTape {
        return .{
            .table = .initBounded(storage.table),
            .transitions = .initBounded(storage.transitions),
        };
    }

    pub fn deinit(self: *TraceTape) void {
        std.debug.assert(self.phase == .idle);
        self.table.deinit();
        self.transitions.deinit();
        self.* = undefined;
    }

    pub fn begin(self: *TraceTape, profile: CaptureProfile) Error!TraceMark {
        switch (self.phase) {
            .idle => {},
            .recording => return error.TraceOperationActive,
            .outstanding => return error.TraceSpanOutstanding,
        }

        self.generation +%= 1;
        self.active_profile = profile;
        self.active_mark = .{
            .generation = self.generation,
            .table = self.table.mark(),
            .transitions = self.transitions.mark(),
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
        const stack_before_len = std.math.cast(u16, input.stack_len) orelse return error.TraceIndexOverflow;
        const requested_stack_prefix_len = std.math.cast(u16, input.stack_prefix_len) orelse return error.TraceIndexOverflow;
        const stack_prefix_len = if (requested_stack_prefix_len <= stack_before_len) requested_stack_prefix_len else 0;
        const row_index = try index32(self.table.steps.items.len);
        const transition_offset = try relativeIndex(
            self.transitions.step_refs.items.len,
            self.active_mark.transitions.step_refs_len,
        );

        try self.ensureTableCapacity(&self.table.steps, 1);
        try self.ensureTransitionCapacity(&self.transitions.step_refs, 1);

        self.table.steps.appendAssumeCapacity(.{
            .transition_offset = transition_offset,
            .frame_id = input.frame_id,
            .pc = pc,
            .opcode = input.opcode,
            .gas_before = input.gas_before,
            .refund_before = input.refund_before,
        });
        self.transitions.step_refs.appendAssumeCapacity(.{});
        self.pending_steps += 1;

        return .{
            .generation = self.generation,
            .index = row_index,
            .stack_before_len = stack_before_len,
            .stack_prefix_len = stack_prefix_len,
            .memory_before_size = memory_size,
            .return_data_before = input.return_data,
        };
    }

    pub fn finishStep(self: *TraceTape, handle: StepHandle, completion: StepFinish) Error!void {
        try self.requireRecording();
        const row = try self.stepFromHandle(handle);
        if (row.outcome != .pending) return error.TraceStepAlreadyFinished;
        if (completion.outcome == .pending) return error.TraceStepNotFinished;

        const pc_next = try index32(completion.pc_next);
        const memory_after_size = try index32(completion.memory.len);
        const transition_index = self.active_mark.transitions.step_refs_len + @as(usize, row.transition_offset);
        std.debug.assert(transition_index < self.transitions.step_refs.items.len);
        const transition_ref = &self.transitions.step_refs.items[transition_index];
        const capture_stack = self.capturesStack();
        const keep_len = if (capture_stack) stackPrefixLen(handle.stack_prefix_len, completion) else 0;
        const appended = if (capture_stack) completion.stack[keep_len..] else &.{};
        const memory_write_input = if (self.capturesMemoryWrites()) completion.memory_write else null;
        const append_range = try relativeRange(
            self.transitions.words.items.len,
            self.active_mark.transitions.words_len,
            appended.len,
        );
        const write_count: usize = if (memory_write_input == null) 0 else 1;
        const memory_changed = memory_after_size != handle.memory_before_size or write_count != 0;
        const return_data_changed = !std.meta.eql(completion.return_data, handle.return_data_before);
        const write_range = try relativeMemoryWriteRange(
            self.transitions.memory_writes.items.len,
            self.active_mark.transitions.memory_writes_len,
            write_count,
        );
        var write_offset: u32 = 0;
        var write_bytes: []const u8 = &.{};
        var write_bytes_range: ByteRange = .{};
        if (memory_write_input) |memory_write| {
            write_offset = try index32(memory_write.offset);
            write_bytes = memory_write.bytes;
            write_bytes_range = try relativeByteRange(
                self.transitions.bytes.items.len,
                self.active_mark.transitions.bytes_len,
                write_bytes.len,
            );
        }
        try self.ensureTransitionCapacity(&self.transitions.words, appended.len);
        try self.ensureTransitionCapacity(&self.transitions.memory_writes, write_count);
        try self.ensureTransitionCapacity(&self.transitions.bytes, write_bytes.len);
        try self.ensureTransitionCapacity(&self.transitions.stack, @intFromBool(capture_stack));
        try self.ensureTransitionCapacity(&self.transitions.memory, @intFromBool(memory_changed));
        try self.ensureTransitionCapacity(&self.transitions.return_data, @intFromBool(return_data_changed));

        const stack_offset = if (capture_stack) try relativeIndex(
            self.transitions.stack.items.len,
            self.active_mark.transitions.stack_len,
        ) else transition_arena.no_transition;
        const memory_offset = if (memory_changed) try relativeIndex(
            self.transitions.memory.items.len,
            self.active_mark.transitions.memory_len,
        ) else transition_arena.no_transition;
        const return_data_offset = if (return_data_changed) try relativeIndex(
            self.transitions.return_data.items.len,
            self.active_mark.transitions.return_data_len,
        ) else transition_arena.no_transition;

        self.transitions.words.appendSliceAssumeCapacity(appended);
        self.transitions.bytes.appendSliceAssumeCapacity(write_bytes);
        if (memory_write_input != null) {
            self.transitions.memory_writes.appendAssumeCapacity(.{
                .offset = write_offset,
                .bytes = write_bytes_range,
            });
        }
        if (capture_stack) self.transitions.stack.appendAssumeCapacity(.{
            .before_len = handle.stack_before_len,
            .keep_len = @intCast(keep_len),
            .append = append_range,
        });
        if (memory_changed) self.transitions.memory.appendAssumeCapacity(.{
            .after_size = memory_after_size,
            .writes = write_range,
        });
        if (return_data_changed) self.transitions.return_data.appendAssumeCapacity(.{
            .after = completion.return_data,
        });
        row.pc_next = pc_next;
        row.gas_after = completion.gas_after;
        transition_ref.* = .{
            .stack = stack_offset,
            .memory = memory_offset,
            .return_data = return_data_offset,
        };
        row.outcome = completion.outcome;
        self.pending_steps -= 1;
    }

    pub fn appendFrame(self: *TraceTape, input: FrameInput) Error!FrameHandle {
        try self.requireRecording();
        const initial_stack_values = if (self.capturesStack()) input.initial_stack else &.{};
        const parent_stack_values = if (self.capturesStack()) input.parent_stack else &.{};
        const row_index = try index32(self.table.frames.items.len);
        const transition_offset = try relativeIndex(
            self.transitions.frames.items.len,
            self.active_mark.transitions.frames_len,
        );
        const initial_stack = try relativeRange(
            self.transitions.words.items.len,
            self.active_mark.transitions.words_len,
            initial_stack_values.len,
        );
        const parent_stack = try relativeRange(
            self.transitions.words.items.len + initial_stack_values.len,
            self.active_mark.transitions.words_len,
            parent_stack_values.len,
        );
        const initial_return_data = try relativeByteRange(
            self.transitions.bytes.items.len,
            self.active_mark.transitions.bytes_len,
            input.initial_return_data.len,
        );
        const initial_memory_size = try index32(input.initial_memory_size);
        const parent_memory_size = try index32(input.parent_memory_size);
        try self.ensureTableCapacity(&self.table.frames, 1);
        try self.ensureTransitionCapacity(&self.transitions.frames, 1);
        try self.ensureTransitionCapacity(&self.transitions.words, initial_stack_values.len + parent_stack_values.len);
        try self.ensureTransitionCapacity(&self.transitions.bytes, input.initial_return_data.len);
        self.transitions.words.appendSliceAssumeCapacity(initial_stack_values);
        self.transitions.words.appendSliceAssumeCapacity(parent_stack_values);
        self.transitions.bytes.appendSliceAssumeCapacity(input.initial_return_data);
        self.table.frames.appendAssumeCapacity(.{
            .frame_id = input.frame_id,
            .parent_frame_id = input.parent_frame_id,
            .transition_offset = transition_offset,
            .depth = input.depth,
            .kind = input.kind,
        });
        self.transitions.frames.appendAssumeCapacity(.{
            .initial = .{
                .stack = initial_stack,
                .return_data = initial_return_data,
                .memory_size = initial_memory_size,
            },
            .parent = .{
                .stack = parent_stack,
                .return_data = input.parent_return_data,
                .memory_size = parent_memory_size,
            },
            .final_return_data = initial_return_data,
            .final_memory_size = initial_memory_size,
        });
        self.pending_frames += 1;
        return .{
            .generation = self.generation,
            .index = row_index,
            .initial_return_data = initial_return_data,
        };
    }

    pub fn finishFrame(self: *TraceTape, handle: FrameHandle, completion: FrameFinish) Error!void {
        try self.requireRecording();
        const row = try self.frameFromHandle(handle);
        if (row.outcome != .pending) return error.TraceFrameAlreadyFinished;
        if (completion.outcome == .pending) return error.TraceFrameNotFinished;

        const memory_size = try index32(completion.memory_size);
        const transition_index = self.active_mark.transitions.frames_len + @as(usize, row.transition_offset);
        std.debug.assert(transition_index < self.transitions.frames.items.len);
        const transition = &self.transitions.frames.items[transition_index];
        transition.final_memory_size = memory_size;
        transition.final_return_data = completion.return_data;
        row.outcome = completion.outcome;
        self.pending_frames -= 1;
    }

    pub fn finish(self: *TraceTape, mark: TraceMark) Error!TraceSpan {
        try self.requireMark(mark);
        if (self.pending_steps != 0) return error.TraceStepNotFinished;
        if (self.pending_frames != 0) return error.TraceFrameNotFinished;

        self.phase = .outstanding;
        const table_span = self.table.span(mark.table);
        return .{
            .owner = self,
            .generation = self.generation,
            .profile = self.active_profile,
            .steps = table_span.steps,
            .frames = table_span.frames,
            .transitions = self.transitions.span(mark.transitions),
        };
    }

    pub fn resolve(self: *TraceTape, span: TraceSpan) Error!void {
        if (self.phase != .outstanding or span.owner != self or span.generation != self.generation) {
            return error.InvalidTraceHandle;
        }
        self.phase = .idle;
    }

    pub fn abort(self: *TraceTape, mark: TraceMark) Error!void {
        try self.requireMark(mark);
        self.table.abort(mark.table);
        self.transitions.abort(mark.transitions);
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
        self.table.reset();
        self.transitions.reset();
    }

    /// Bytes retained by the tape's logical payload, excluding spare capacity.
    pub fn capturedBytes(self: *const TraceTape) usize {
        return self.table.steps.items.len * @sizeOf(StepRow) +
            self.table.frames.items.len * @sizeOf(FrameRow) +
            self.transitions.step_refs.items.len * @sizeOf(StepTransitionRef) +
            self.transitions.stack.items.len * @sizeOf(StackTransition) +
            self.transitions.memory.items.len * @sizeOf(MemoryTransition) +
            self.transitions.return_data.items.len * @sizeOf(ReturnDataTransition) +
            self.transitions.frames.items.len * @sizeOf(FrameTransition) +
            self.transitions.words.items.len * @sizeOf(u256) +
            self.transitions.bytes.items.len +
            self.transitions.memory_writes.items.len * @sizeOf(MemoryWrite);
    }

    pub fn stepCount(self: *const TraceTape) usize {
        return self.table.steps.items.len;
    }

    pub fn frameCount(self: *const TraceTape) usize {
        return self.table.frames.items.len;
    }

    pub inline fn capturesStack(self: *const TraceTape) bool {
        return self.active_profile.stack == .full;
    }

    pub inline fn capturesMemoryWrites(self: *const TraceTape) bool {
        return self.active_profile.memory == .writes;
    }

    /// Store one immutable return-data version. Callers keep and reuse the
    /// returned range until CALL/CREATE replaces the frame's return data.
    pub fn storeReturnData(self: *TraceTape, bytes: []const u8) Error!ByteRange {
        try self.requireRecording();
        if (bytes.len == 0) return .{};
        const range = try relativeByteRange(
            self.transitions.bytes.items.len,
            self.active_mark.transitions.bytes_len,
            bytes.len,
        );
        try self.ensureTransitionCapacity(&self.transitions.bytes, bytes.len);
        self.transitions.bytes.appendSliceAssumeCapacity(bytes);
        return range;
    }

    pub fn returnDataEquals(self: *const TraceTape, range: ByteRange, bytes: []const u8) bool {
        if (self.phase != .recording) return false;
        const offset = self.active_mark.transitions.bytes_len + @as(usize, range.offset);
        const len: usize = range.len;
        if (offset + len > self.transitions.bytes.items.len) return false;
        return std.mem.eql(u8, self.transitions.bytes.items[offset..][0..len], bytes);
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
        if (index < self.active_mark.table.steps_len or index >= self.table.steps.items.len) {
            return error.InvalidTraceHandle;
        }
        return &self.table.steps.items[index];
    }

    fn frameFromHandle(self: *TraceTape, handle: FrameHandle) Error!*FrameRow {
        if (handle.generation != self.generation) return error.InvalidTraceHandle;
        const index: usize = handle.index;
        if (index < self.active_mark.table.frames_len or index >= self.table.frames.items.len) {
            return error.InvalidTraceHandle;
        }
        return &self.table.frames.items[index];
    }

    fn ensureTableCapacity(self: *TraceTape, list: anytype, additional: usize) Error!void {
        try ensureCapacity(self.table.allocator, list, additional);
    }

    fn ensureTransitionCapacity(self: *TraceTape, list: anytype, additional: usize) Error!void {
        try ensureCapacity(self.transitions.allocator, list, additional);
    }

    fn ensureCapacity(allocator: ?Allocator, list: anytype, additional: usize) Error!void {
        list.ensureUnusedCapacity(allocator orelse no_growth_allocator, additional) catch |err| {
            if (allocator == null) return error.TraceCapacityExceeded;
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

fn relativeIndex(absolute_index: usize, operation_start: usize) Error!u32 {
    std.debug.assert(absolute_index >= operation_start);
    return index32(absolute_index - operation_start);
}

fn relativeByteRange(absolute_start: usize, operation_start: usize, len: usize) Error!ByteRange {
    const range = try relativeRange(absolute_start, operation_start, len);
    return .{ .offset = range.offset, .len = range.len };
}

fn relativeMemoryWriteRange(absolute_start: usize, operation_start: usize, len: usize) Error!MemoryWriteRange {
    const range = try relativeRange(absolute_start, operation_start, len);
    return .{ .offset = range.offset, .len = range.len };
}

fn stackPrefixLen(prefix_len_value: u16, completion: StepFinish) usize {
    const prefix_len: usize = prefix_len_value;
    const after_len = completion.stack.len;
    if (completion.outcome == .invalid or completion.outcome == .out_of_gas) return 0;
    return if (prefix_len <= after_len) prefix_len else 0;
}

test "trace tape appends patches and exposes one stable replay span" {
    var tape = TraceTape.initGrowable(std.testing.allocator);
    defer tape.deinit();

    const mark = try tape.begin(.{});
    const frame = try tape.appendFrame(.{
        .frame_id = 7,
        .parent_frame_id = null,
        .depth = 0,
        .kind = .root,
        .initial_stack = &.{ 11, 12 },
        .initial_return_data = &.{ 0xaa, 0xbb },
    });
    const step = try tape.appendStep(.{
        .frame_id = 7,
        .pc = 3,
        .opcode = 0x01,
        .gas_before = 100,
        .refund_before = 2,
        .stack_len = 2,
        .memory_size = 32,
        .return_data = frame.initial_return_data,
    });
    const final_return_data = try tape.storeReturnData(&.{ 1, 2, 3, 4, 5 });
    var final_memory = [_]u8{0} ** 64;
    try tape.finishStep(step, .{
        .pc_next = 4,
        .gas_after = 97,
        .outcome = .success,
        .stack = &.{21},
        .memory = &final_memory,
        .return_data = final_return_data,
    });
    try tape.finishFrame(frame, .{
        .outcome = .success,
        .memory_size = 64,
        .return_data = final_return_data,
    });

    const span = try tape.finish(mark);
    try std.testing.expectEqual(@as(usize, 1), span.steps.len);
    try std.testing.expectEqual(@as(usize, 1), span.frames.len);
    try std.testing.expectEqual(@as(u32, 3), span.steps[0].pc);
    try std.testing.expectEqual(@as(u32, 4), span.steps[0].pc_next);
    try std.testing.expectEqual(@as(i64, 97), span.steps[0].gas_after);
    try std.testing.expectEqual(StepOutcome.success, span.steps[0].outcome);
    var cursor = TraceCursor.init(span);
    cursor.enterFrame(span.frames[0]);
    try std.testing.expectEqualSlices(u256, &.{ 11, 12 }, cursor.stack().?);
    try std.testing.expectEqual(@as(usize, 0), cursor.memorySize());
    try std.testing.expectEqualSlices(u8, &.{ 0xaa, 0xbb }, cursor.returnData());
    cursor.finishStep(span.steps[0]);
    try std.testing.expectEqualSlices(u256, &.{21}, cursor.stack().?);
    try std.testing.expectEqual(@as(usize, 64), cursor.memorySize());
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4, 5 }, cursor.returnData());
    try std.testing.expectEqual(FrameOutcome.success, span.frames[0].outcome);

    try std.testing.expectError(error.TraceSpanOutstanding, tape.begin(.{}));
    try std.testing.expectError(error.TraceSpanOutstanding, tape.reset());
    try tape.resolve(span);
    try tape.reset();
    try std.testing.expectEqual(@as(usize, 0), tape.stepCount());
    try std.testing.expectEqual(@as(usize, 0), tape.frameCount());
}

test "trace cursor owns replay order and sparse state transitions" {
    var tape = TraceTape.initGrowable(std.testing.allocator);
    defer tape.deinit();

    const mark = try tape.begin(.{});
    const frame = try tape.appendFrame(.{
        .frame_id = 0,
        .parent_frame_id = null,
        .depth = 0,
        .kind = .root,
    });
    const step = try tape.appendStep(.{
        .frame_id = 0,
        .pc = 0,
        .opcode = 0x00,
        .gas_before = 1,
        .refund_before = 0,
        .stack_len = 0,
        .memory_size = 0,
    });
    try tape.finishStep(step, .{
        .pc_next = 1,
        .gas_after = 1,
        .outcome = .success,
        .stack = &.{},
    });
    try tape.finishFrame(frame, .{ .outcome = .success, .memory_size = 0 });
    const span = try tape.finish(mark);
    defer tape.resolve(span) catch unreachable;

    try std.testing.expectEqual(@as(usize, 1), span.transitions.step_refs.len);
    try std.testing.expectEqual(@as(usize, 1), span.transitions.stack.len);
    try std.testing.expectEqual(@as(usize, 0), span.transitions.memory.len);
    try std.testing.expectEqual(@as(usize, 0), span.transitions.return_data.len);

    var cursor = TraceCursor.init(span);
    try std.testing.expect((try cursor.next()).? == .frame_enter);
    const start = (try cursor.next()).?.step_start;
    try std.testing.expectEqual(@as(u32, 0), start.row.pc);
    try std.testing.expectEqual(@as(usize, 0), start.state.stack.?.len);
    const end = (try cursor.next()).?.step_end;
    try std.testing.expect(end.terminal);
    try std.testing.expectEqual(@as(usize, 0), end.state.memory_size);
    try std.testing.expect((try cursor.next()).? == .frame_leave);
    try std.testing.expect((try cursor.next()) == null);
}

test "capture profile omits stack payload and reports unavailable capabilities" {
    var tape = TraceTape.initGrowable(std.testing.allocator);
    defer tape.deinit();

    const mark = try tape.begin(.{ .stack = .omitted });
    const frame = try tape.appendFrame(.{
        .frame_id = 0,
        .parent_frame_id = null,
        .depth = 0,
        .kind = .root,
        .initial_stack = &.{ 1, 2 },
    });
    const step = try tape.appendStep(.{
        .frame_id = 0,
        .pc = 0,
        .opcode = 0x01,
        .gas_before = 3,
        .refund_before = 0,
        .stack_len = 2,
        .memory_size = 0,
    });
    try tape.finishStep(step, .{
        .pc_next = 1,
        .gas_after = 0,
        .outcome = .success,
        .stack = &.{3},
    });
    try tape.finishFrame(frame, .{ .outcome = .success, .memory_size = 0 });
    const span = try tape.finish(mark);
    defer tape.resolve(span) catch unreachable;

    try std.testing.expectEqual(StackCapture.omitted, span.profile.stack);
    try std.testing.expectEqual(@as(usize, 0), span.transitions.stack.len);
    try std.testing.expectEqual(@as(usize, 0), span.transitions.words.len);
    try std.testing.expectError(error.TraceCapabilityUnavailable, span.require(.{ .stack = .full }));
    try std.testing.expectError(error.TraceCapabilityUnavailable, span.require(.{ .memory = .writes }));

    var cursor = TraceCursor.init(span);
    try std.testing.expect((try cursor.next()).? == .frame_enter);
    try std.testing.expect((try cursor.next()).?.step_start.state.stack == null);
    try std.testing.expect((try cursor.next()).?.step_end.state.stack == null);
    try std.testing.expectError(error.TraceCapabilityUnavailable, cursor.memoryWrites());
}

test "bounded trace tape rejects frame stack checkpoints atomically" {
    var step_storage: [0]StepRow = undefined;
    var frame_storage: [1]FrameRow = undefined;
    var step_ref_storage: [0]StepTransitionRef = undefined;
    var stack_transition_storage: [0]StackTransition = undefined;
    var memory_transition_storage: [0]MemoryTransition = undefined;
    var return_data_transition_storage: [0]ReturnDataTransition = undefined;
    var frame_transition_storage: [1]FrameTransition = undefined;
    var word_storage: [1]u256 = undefined;
    var byte_storage: [0]u8 = undefined;
    var memory_write_storage: [0]MemoryWrite = undefined;
    var tape = TraceTape.initBounded(.{
        .table = .{
            .steps = &step_storage,
            .frames = &frame_storage,
        },
        .transitions = .{
            .step_refs = &step_ref_storage,
            .stack = &stack_transition_storage,
            .memory = &memory_transition_storage,
            .return_data = &return_data_transition_storage,
            .frames = &frame_transition_storage,
            .words = &word_storage,
            .bytes = &byte_storage,
            .memory_writes = &memory_write_storage,
        },
    });
    defer tape.deinit();

    const mark = try tape.begin(.{});
    try std.testing.expectError(error.TraceCapacityExceeded, tape.appendFrame(.{
        .frame_id = 0,
        .parent_frame_id = null,
        .depth = 0,
        .kind = .root,
        .initial_stack = &.{ 1, 2 },
    }));
    try std.testing.expectEqual(@as(usize, 0), tape.table.frames.items.len);
    try std.testing.expectEqual(@as(usize, 0), tape.transitions.words.items.len);
    try tape.abort(mark);
}

test "bounded trace tape reports capacity without partial append" {
    var step_storage: [1]StepRow = undefined;
    var frame_storage: [1]FrameRow = undefined;
    var step_ref_storage: [1]StepTransitionRef = undefined;
    var stack_transition_storage: [1]StackTransition = undefined;
    var memory_transition_storage: [1]MemoryTransition = undefined;
    var return_data_transition_storage: [1]ReturnDataTransition = undefined;
    var frame_transition_storage: [0]FrameTransition = undefined;
    var word_storage: [1]u256 = undefined;
    var byte_storage: [0]u8 = undefined;
    var memory_write_storage: [0]MemoryWrite = undefined;
    var tape = TraceTape.initBounded(.{
        .table = .{
            .steps = &step_storage,
            .frames = &frame_storage,
        },
        .transitions = .{
            .step_refs = &step_ref_storage,
            .stack = &stack_transition_storage,
            .memory = &memory_transition_storage,
            .return_data = &return_data_transition_storage,
            .frames = &frame_transition_storage,
            .words = &word_storage,
            .bytes = &byte_storage,
            .memory_writes = &memory_write_storage,
        },
    });
    defer tape.deinit();

    const mark = try tape.begin(.{});
    const step = try tape.appendStep(.{
        .frame_id = 0,
        .pc = 0,
        .opcode = 0x5f,
        .gas_before = 0,
        .refund_before = 0,
        .stack_len = 0,
        .memory_size = 0,
    });
    try std.testing.expectError(error.TraceCapacityExceeded, tape.finishStep(step, .{
        .pc_next = 1,
        .gas_after = 0,
        .outcome = .success,
        .stack = &.{ 1, 2 },
    }));
    try std.testing.expectEqual(StepOutcome.pending, tape.table.steps.items[0].outcome);
    try std.testing.expectEqual(@as(usize, 0), tape.transitions.words.items.len);

    try tape.finishStep(step, .{ .pc_next = 1, .gas_after = 0, .outcome = .success, .stack = &.{1} });
    const span = try tape.finish(mark);
    try std.testing.expectEqual(@as(usize, 1), span.steps.len);
    try tape.resolve(span);
}

test "trace tape abort restores every operation buffer" {
    var tape = TraceTape.initGrowable(std.testing.allocator);
    defer tape.deinit();

    const first_mark = try tape.begin(.{});
    const first_step = try tape.appendStep(.{
        .frame_id = 0,
        .pc = 0,
        .opcode = 0,
        .gas_before = 1,
        .refund_before = 0,
        .stack_len = 0,
        .memory_size = 0,
    });
    try tape.finishStep(first_step, .{ .pc_next = 1, .gas_after = 0, .outcome = .success, .stack = &.{} });
    const first_span = try tape.finish(first_mark);
    try tape.resolve(first_span);

    const second_mark = try tape.begin(.{});
    _ = try tape.appendStep(.{
        .frame_id = 1,
        .pc = 2,
        .opcode = 1,
        .gas_before = 2,
        .refund_before = 0,
        .stack_len = 2,
        .memory_size = 4,
    });
    try tape.abort(second_mark);

    try std.testing.expectEqual(@as(usize, 1), tape.stepCount());
    const third_mark = try tape.begin(.{});
    const third_span = try tape.finish(third_mark);
    try std.testing.expectEqual(@as(usize, 0), third_span.steps.len);
    try std.testing.expectEqual(@as(usize, 0), third_span.transitions.words.len);
    try tape.resolve(third_span);
}

test "trace tape rejects a span owned by another tape" {
    var first = TraceTape.initGrowable(std.testing.allocator);
    defer first.deinit();
    var second = TraceTape.initGrowable(std.testing.allocator);
    defer second.deinit();

    const first_span = try first.finish(try first.begin(.{}));
    const second_span = try second.finish(try second.begin(.{}));
    try std.testing.expectError(error.InvalidTraceHandle, first.resolve(second_span));
    try std.testing.expectError(error.InvalidTraceHandle, second.resolve(first_span));
    try first.resolve(first_span);
    try second.resolve(second_span);
}

test "trace tape selects a new capture profile for each operation" {
    var tape = TraceTape.initGrowable(std.testing.allocator);
    defer tape.deinit();

    const compact = try tape.finish(try tape.begin(.{ .stack = .omitted }));
    try std.testing.expectEqual(StackCapture.omitted, compact.profile.stack);
    try std.testing.expectEqual(MemoryCapture.size_only, compact.profile.memory);
    try tape.resolve(compact);

    const exact = try tape.finish(try tape.begin(.{ .stack = .full, .memory = .writes }));
    try std.testing.expectEqual(StackCapture.full, exact.profile.stack);
    try std.testing.expectEqual(MemoryCapture.writes, exact.profile.memory);
    try tape.resolve(exact);
}

test "trace tape refuses unfinished and stale handles" {
    var tape = TraceTape.initGrowable(std.testing.allocator);
    defer tape.deinit();

    const mark = try tape.begin(.{});
    const step = try tape.appendStep(.{
        .frame_id = 0,
        .pc = 0,
        .opcode = 0,
        .gas_before = 0,
        .refund_before = 0,
        .stack_len = 0,
        .memory_size = 0,
    });
    try std.testing.expectError(error.TraceStepNotFinished, tape.finish(mark));
    try tape.finishStep(step, .{ .pc_next = 1, .gas_after = 0, .outcome = .success, .stack = &.{} });
    try std.testing.expectError(
        error.TraceStepAlreadyFinished,
        tape.finishStep(step, .{ .pc_next = 1, .gas_after = 0, .outcome = .success, .stack = &.{} }),
    );
    const span = try tape.finish(mark);
    try tape.resolve(span);

    const next_mark = try tape.begin(.{});
    try std.testing.expectError(
        error.InvalidTraceHandle,
        tape.finishStep(step, .{ .pc_next = 1, .gas_after = 0, .outcome = .success, .stack = &.{} }),
    );
    try tape.abort(next_mark);
}
