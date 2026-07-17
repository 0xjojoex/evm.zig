//! Typed execution-state transitions referenced by immutable trace metadata.

const std = @import("std");

const Allocator = std.mem.Allocator;

pub const WordRange = struct {
    offset: u32 = 0,
    len: u32 = 0,
};

pub const ByteRange = struct {
    offset: u32 = 0,
    len: u32 = 0,
};

pub const MemoryWriteRange = struct {
    offset: u32 = 0,
    len: u32 = 0,
};

pub const MemoryWrite = struct {
    offset: u32,
    bytes: ByteRange,
};

pub const no_transition = std.math.maxInt(u32);

/// One fixed lookup record per step. Stack always changes logical position;
/// memory and return data allocate descriptors only when their state changes.
pub const StepTransitionRef = struct {
    stack: u32 = no_transition,
    memory: u32 = no_transition,
    return_data: u32 = no_transition,
};

pub const StackTransition = struct {
    append: WordRange = .{},
    before_len: u16,
    keep_len: u16 = 0,
};

pub const MemoryTransition = struct {
    writes: MemoryWriteRange = .{},
    after_size: u32 = 0,
};

pub const ReturnDataTransition = struct {
    after: ByteRange = .{},
};

pub const StateCheckpoint = struct {
    stack: WordRange = .{},
    return_data: ByteRange = .{},
    memory_size: u32 = 0,
};

pub const FrameTransition = struct {
    initial: StateCheckpoint = .{},
    parent: StateCheckpoint = .{},
    final_return_data: ByteRange = .{},
    final_memory_size: u32 = 0,
};

pub const Mark = struct {
    step_refs_len: usize,
    stack_len: usize,
    memory_len: usize,
    return_data_len: usize,
    frames_len: usize,
    words_len: usize,
    bytes_len: usize,
    memory_writes_len: usize,
};

pub const Span = struct {
    step_refs: []const StepTransitionRef,
    stack: []const StackTransition,
    memory: []const MemoryTransition,
    return_data: []const ReturnDataTransition,
    frames: []const FrameTransition,
    words: []const u256,
    bytes: []const u8,
    memory_writes: []const MemoryWrite,
};

pub const BoundedStorage = struct {
    step_refs: []StepTransitionRef,
    stack: []StackTransition,
    memory: []MemoryTransition,
    return_data: []ReturnDataTransition,
    frames: []FrameTransition,
    words: []u256,
    bytes: []u8,
    memory_writes: []MemoryWrite,
};

pub const Arena = struct {
    allocator: ?Allocator,
    step_refs: std.ArrayList(StepTransitionRef),
    stack: std.ArrayList(StackTransition),
    memory: std.ArrayList(MemoryTransition),
    return_data: std.ArrayList(ReturnDataTransition),
    frames: std.ArrayList(FrameTransition),
    words: std.ArrayList(u256),
    bytes: std.ArrayList(u8),
    memory_writes: std.ArrayList(MemoryWrite),

    pub fn initGrowable(allocator: Allocator) Arena {
        return .{
            .allocator = allocator,
            .step_refs = .empty,
            .stack = .empty,
            .memory = .empty,
            .return_data = .empty,
            .frames = .empty,
            .words = .empty,
            .bytes = .empty,
            .memory_writes = .empty,
        };
    }

    pub fn initBounded(storage: BoundedStorage) Arena {
        return .{
            .allocator = null,
            .step_refs = .initBuffer(storage.step_refs),
            .stack = .initBuffer(storage.stack),
            .memory = .initBuffer(storage.memory),
            .return_data = .initBuffer(storage.return_data),
            .frames = .initBuffer(storage.frames),
            .words = .initBuffer(storage.words),
            .bytes = .initBuffer(storage.bytes),
            .memory_writes = .initBuffer(storage.memory_writes),
        };
    }

    pub fn deinit(self: *Arena) void {
        if (self.allocator) |allocator| {
            self.step_refs.deinit(allocator);
            self.stack.deinit(allocator);
            self.memory.deinit(allocator);
            self.return_data.deinit(allocator);
            self.frames.deinit(allocator);
            self.words.deinit(allocator);
            self.bytes.deinit(allocator);
            self.memory_writes.deinit(allocator);
        }
        self.* = undefined;
    }

    pub fn mark(self: *const Arena) Mark {
        return .{
            .step_refs_len = self.step_refs.items.len,
            .stack_len = self.stack.items.len,
            .memory_len = self.memory.items.len,
            .return_data_len = self.return_data.items.len,
            .frames_len = self.frames.items.len,
            .words_len = self.words.items.len,
            .bytes_len = self.bytes.items.len,
            .memory_writes_len = self.memory_writes.items.len,
        };
    }

    pub fn span(self: *const Arena, mark_value: Mark) Span {
        return .{
            .step_refs = self.step_refs.items[mark_value.step_refs_len..],
            .stack = self.stack.items[mark_value.stack_len..],
            .memory = self.memory.items[mark_value.memory_len..],
            .return_data = self.return_data.items[mark_value.return_data_len..],
            .frames = self.frames.items[mark_value.frames_len..],
            .words = self.words.items[mark_value.words_len..],
            .bytes = self.bytes.items[mark_value.bytes_len..],
            .memory_writes = self.memory_writes.items[mark_value.memory_writes_len..],
        };
    }

    pub fn abort(self: *Arena, mark_value: Mark) void {
        self.step_refs.items.len = mark_value.step_refs_len;
        self.stack.items.len = mark_value.stack_len;
        self.memory.items.len = mark_value.memory_len;
        self.return_data.items.len = mark_value.return_data_len;
        self.frames.items.len = mark_value.frames_len;
        self.words.items.len = mark_value.words_len;
        self.bytes.items.len = mark_value.bytes_len;
        self.memory_writes.items.len = mark_value.memory_writes_len;
    }

    pub fn reset(self: *Arena) void {
        self.step_refs.clearRetainingCapacity();
        self.stack.clearRetainingCapacity();
        self.memory.clearRetainingCapacity();
        self.return_data.clearRetainingCapacity();
        self.frames.clearRetainingCapacity();
        self.words.clearRetainingCapacity();
        self.bytes.clearRetainingCapacity();
        self.memory_writes.clearRetainingCapacity();
    }
};
