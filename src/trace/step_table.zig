//! Immutable trace metadata published by the capture runtime.

const std = @import("std");

const Allocator = std.mem.Allocator;

pub const TraceOutcome = enum(u8) {
    pending,
    success,
    invalid,
    revert,
    out_of_gas,
};

pub const StepOutcome = TraceOutcome;

pub const StepRow = struct {
    gas_before: i64,
    gas_after: i64 = 0,
    refund_before: i64,
    transition_offset: u32,
    frame_id: u32,
    pc: u32,
    pc_next: u32 = 0,
    opcode: u8,
    outcome: StepOutcome = .pending,
};

comptime {
    if (@sizeOf(StepRow) > 48) @compileError("trace step row exceeded its metadata layout budget");
    for (.{ "stack", "stack_before_len", "memory_size", "memory_after_size", "return_data" }) |field| {
        if (@hasField(StepRow, field)) @compileError("execution state belongs in TransitionArena, not StepRow");
    }
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

pub const FrameOutcome = TraceOutcome;

pub const FrameRow = struct {
    frame_id: u32,
    parent_frame_id: ?u32,
    transition_offset: u32,
    depth: u16,
    kind: FrameKind,
    outcome: FrameOutcome = .pending,
};

comptime {
    if (@sizeOf(FrameRow) > 24) @compileError("trace frame row exceeded its metadata layout budget");
    for (.{ "initial_stack", "parent_stack", "final_memory_size", "final_return_data" }) |field| {
        if (@hasField(FrameRow, field)) @compileError("frame state belongs in TransitionArena, not FrameRow");
    }
}

pub const Mark = struct {
    steps_len: usize,
    frames_len: usize,
};

pub const Span = struct {
    steps: []const StepRow,
    frames: []const FrameRow,
};

pub const BoundedStorage = struct {
    steps: []StepRow,
    frames: []FrameRow,
};

pub const Table = struct {
    allocator: ?Allocator,
    steps: std.ArrayList(StepRow),
    frames: std.ArrayList(FrameRow),

    pub fn initGrowable(allocator: Allocator) Table {
        return .{
            .allocator = allocator,
            .steps = .empty,
            .frames = .empty,
        };
    }

    pub fn initBounded(storage: BoundedStorage) Table {
        return .{
            .allocator = null,
            .steps = .initBuffer(storage.steps),
            .frames = .initBuffer(storage.frames),
        };
    }

    pub fn deinit(self: *Table) void {
        if (self.allocator) |allocator| {
            self.steps.deinit(allocator);
            self.frames.deinit(allocator);
        }
        self.* = undefined;
    }

    pub fn mark(self: *const Table) Mark {
        return .{
            .steps_len = self.steps.items.len,
            .frames_len = self.frames.items.len,
        };
    }

    pub fn span(self: *const Table, mark_value: Mark) Span {
        return .{
            .steps = self.steps.items[mark_value.steps_len..],
            .frames = self.frames.items[mark_value.frames_len..],
        };
    }

    pub fn abort(self: *Table, mark_value: Mark) void {
        self.steps.items.len = mark_value.steps_len;
        self.frames.items.len = mark_value.frames_len;
    }

    pub fn reset(self: *Table) void {
        self.steps.clearRetainingCapacity();
        self.frames.clearRetainingCapacity();
    }
};
