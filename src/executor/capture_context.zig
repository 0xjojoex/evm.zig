//! Operation-scoped carrier for captured step and call runtimes.

const std = @import("std");
const trace = @import("../trace.zig");

pub const TraceBinding = struct {
    tape: *trace.TraceTape,
    profile: trace.CaptureProfile = .{},
};

pub const CallBinding = struct {
    arena: *trace.CallArena,
};

pub const Context = struct {
    allocator: ?std.mem.Allocator,
    tape: ?*trace.TraceTape = null,
    call_arena: ?*trace.CallArena = null,
    trace_profile: trace.CaptureProfile = .{},
    frame_captures: std.ArrayList(trace.TraceCapture) = .empty,
    next_frame_id: u32 = 0,
    mark: ?trace.TraceMark = null,
    active: bool = false,
    tape_attached: bool = false,
    call_attached: bool = false,

    pub fn init(
        allocator: std.mem.Allocator,
        trace_binding: ?TraceBinding,
    ) Context {
        return .{
            .allocator = allocator,
            .tape = if (trace_binding) |binding| binding.tape else null,
            .trace_profile = if (trace_binding) |binding| binding.profile else .{},
        };
    }

    pub fn initWithCalls(
        allocator: std.mem.Allocator,
        trace_binding: ?TraceBinding,
        call_binding: CallBinding,
    ) Context {
        var context = init(allocator, trace_binding);
        context.call_arena = call_binding.arena;
        return context;
    }

    /// Build a context whose live-frame sidecar cannot allocate or outgrow the
    /// caller-provided storage. The tape may independently be bounded or
    /// growable.
    pub fn initBounded(
        frame_storage: []trace.TraceCapture,
        trace_binding: ?TraceBinding,
    ) Context {
        return .{
            .allocator = null,
            .tape = if (trace_binding) |binding| binding.tape else null,
            .trace_profile = if (trace_binding) |binding| binding.profile else .{},
            .frame_captures = .initBuffer(frame_storage),
        };
    }

    pub fn initBoundedWithCalls(
        frame_storage: []trace.TraceCapture,
        trace_binding: ?TraceBinding,
        call_binding: CallBinding,
    ) Context {
        var context = initBounded(frame_storage, trace_binding);
        context.call_arena = call_binding.arena;
        return context;
    }

    pub fn deinit(self: *Context) void {
        std.debug.assert(!self.active);
        std.debug.assert(self.frame_captures.items.len == 0);
        if (self.allocator) |allocator| self.frame_captures.deinit(allocator);
        self.* = undefined;
    }

    /// Open capture for one operation. A context may stay bound to an executor
    /// while individual operations opt in and out through begin/finish.
    pub fn begin(self: *Context) !void {
        if (self.active) return error.CaptureOperationActive;
        if (self.frame_captures.items.len != 0) return error.ActiveCaptureFrames;

        self.active = true;
        errdefer self.active = false;
        self.next_frame_id = 0;
        if (self.call_arena) |arena| {
            try arena.begin();
            errdefer arena.abort() catch {};
        }
        self.mark = if (self.tape) |tape| try tape.begin(self.trace_profile) else null;
    }

    /// Close one successful capture. The returned span remains borrowed from
    /// the tape until the caller explicitly resolves it.
    pub fn finish(self: *Context) !?trace.TraceSpan {
        if (!self.active) return error.CaptureOperationNotActive;
        if (self.frame_captures.items.len != 0) return error.ActiveCaptureFrames;

        if (self.call_arena) |arena| {
            _ = try arena.finish();
            self.detachScopedCalls();
        }
        const span = if (self.mark != null) try self.finishTrace() else null;
        self.active = false;
        return span;
    }

    /// Discard partial trace rows after an execution or capture failure.
    pub fn abort(self: *Context) !void {
        if (!self.active) return error.CaptureOperationNotActive;
        if (self.mark != null) {
            try self.abortTrace();
        } else {
            std.debug.assert(self.frame_captures.items.len == 0);
        }
        if (self.call_arena) |arena| {
            try arena.abort();
            self.detachScopedCalls();
        }
        self.active = false;
    }

    pub inline fn isActive(self: *const Context) bool {
        return self.active;
    }

    pub inline fn capturesSteps(self: *const Context) bool {
        return self.active and self.mark != null;
    }

    pub inline fn capturesCalls(self: *const Context) bool {
        return self.active and self.call_arena != null;
    }

    /// Enable call capture for one payload while the outer context remains
    /// active for a wider state-capture scope.
    pub fn beginCalls(self: *Context, binding: CallBinding) !void {
        if (!self.active) return error.CaptureOperationNotActive;
        if (self.call_arena != null) return error.CallCaptureOperationActive;
        self.call_arena = binding.arena;
        self.call_attached = true;
        errdefer self.detachScopedCalls();
        try binding.arena.begin();
    }

    pub fn finishCalls(self: *Context) !trace.CallSpan {
        if (!self.active or !self.call_attached) return error.CallCaptureOperationNotActive;
        const span = try self.call_arena.?.finish();
        self.detachScopedCalls();
        return span;
    }

    pub fn abortCalls(self: *Context) !void {
        if (!self.active or !self.call_attached) return error.CallCaptureOperationNotActive;
        try self.call_arena.?.abort();
        self.detachScopedCalls();
    }

    pub fn beginCall(self: *Context, event: trace.CallStart) !?trace.CallToken {
        if (!self.capturesCalls()) return null;
        return try self.call_arena.?.start(event);
    }

    pub fn reserveCallOutput(self: *Context, output_len: usize) !void {
        if (!self.capturesCalls()) return;
        try self.call_arena.?.reserveOutput(output_len);
    }

    pub fn finishCallReserved(
        self: *Context,
        token: trace.CallToken,
        event: trace.CallFinish,
    ) void {
        std.debug.assert(self.capturesCalls());
        self.call_arena.?.finishReserved(token, event);
    }

    pub fn finishCall(
        self: *Context,
        token: trace.CallToken,
        event: trace.CallFinish,
    ) !void {
        if (!self.capturesCalls()) return;
        try self.call_arena.?.finishCall(token, event);
    }

    /// Fix the live-frame sidecar capacity before captured execution starts so
    /// synchronous host reentry cannot relocate an active TraceCapture.
    pub fn reserveFrameCapacity(self: *Context, capacity: usize) !void {
        // TODO: review
        if (self.frame_captures.items.len != 0) return error.ActiveCaptureFrames;
        if (self.allocator) |allocator| {
            try self.frame_captures.ensureTotalCapacityPrecise(allocator, capacity);
        }
    }

    /// Enable step capture for one sub-operation while keeping the state target
    /// active across a wider scope such as a block.
    pub fn beginTrace(self: *Context, binding: TraceBinding) !void {
        if (!self.active) return error.CaptureOperationNotActive;
        if (self.mark != null) return error.TraceOperationActive;
        if (self.frame_captures.items.len != 0) return error.ActiveCaptureFrames;
        if (self.tape != null) return error.TraceOperationActive;
        self.tape = binding.tape;
        self.trace_profile = binding.profile;
        self.tape_attached = true;
        errdefer {
            self.tape = null;
            self.trace_profile = .{};
            self.tape_attached = false;
        }
        self.mark = try binding.tape.begin(binding.profile);
        self.next_frame_id = 0;
    }

    pub fn finishTrace(self: *Context) !trace.TraceSpan {
        if (!self.active or self.mark == null) return error.TraceOperationNotActive;
        if (self.frame_captures.items.len != 0) return error.ActiveCaptureFrames;
        const span = try self.tape.?.finish(self.mark.?);
        self.mark = null;
        self.detachScopedTape();
        return span;
    }

    pub fn abortTrace(self: *Context) !void {
        if (!self.active or self.mark == null) return error.TraceOperationNotActive;
        self.frame_captures.clearRetainingCapacity();
        try self.tape.?.abort(self.mark.?);
        self.mark = null;
        self.detachScopedTape();
    }

    pub fn pushFrame(
        self: *Context,
        depth: u16,
        kind: trace.TraceFrameKind,
        initial_stack: []const u256,
        initial_memory_size: usize,
        initial_return_data: []const u8,
        parent_stack: []const u256,
        parent_memory_size: usize,
    ) !void {
        if (!self.capturesSteps()) return;
        if (self.allocator) |allocator| {
            try self.frame_captures.ensureUnusedCapacity(allocator, 1);
        } else if (self.frame_captures.items.len == self.frame_captures.capacity) {
            return error.TraceCapacityExceeded;
        }
        const frame_id = self.next_frame_id;
        const next_frame_id = std.math.add(u32, frame_id, 1) catch return error.TraceIndexOverflow;
        const parent_capture = self.frame_captures.getLastOrNull();
        const parent_frame_id = if (parent_capture) |parent| parent.frame_id else null;
        const parent_return_data: trace.tape.ByteRange = if (parent_capture) |parent|
            parent.currentReturnData()
        else
            .{};
        const frame_capture = try trace.TraceCapture.init(self.tape.?, .{
            .frame_id = frame_id,
            .parent_frame_id = parent_frame_id,
            .depth = depth,
            .kind = kind,
            .initial_stack = initial_stack,
            .initial_memory_size = initial_memory_size,
            .initial_return_data = initial_return_data,
            .parent_stack = parent_stack,
            .parent_memory_size = parent_memory_size,
            .parent_return_data = parent_return_data,
        });
        self.frame_captures.appendAssumeCapacity(frame_capture);
        self.next_frame_id = next_frame_id;
    }

    pub inline fn currentFrame(self: *Context) *trace.TraceCapture {
        return &self.frame_captures.items[self.frame_captures.items.len - 1];
    }

    pub fn finishCurrentFrame(self: *Context, completion: trace.TraceFrameFinish) !void {
        if (!self.capturesSteps()) return;
        try self.currentFrame().finishFrame(completion);
    }

    pub fn replaceFrameReturnData(self: *Context, frame_index: usize, bytes: []const u8) !void {
        if (!self.capturesSteps()) return;
        try self.frame_captures.items[frame_index].replaceReturnData(bytes);
    }

    pub fn setFrameMemoryWrite(self: *Context, frame_index: usize, offset: usize, size: usize) void {
        if (!self.capturesSteps()) return;
        self.frame_captures.items[frame_index].setPendingMemoryWrite(.{ .offset = offset, .size = size });
    }

    pub fn popFrame(self: *Context) void {
        if (!self.capturesSteps()) return;
        _ = self.frame_captures.pop();
    }

    fn detachScopedTape(self: *Context) void {
        if (!self.tape_attached) return;
        self.tape = null;
        self.trace_profile = .{};
        self.tape_attached = false;
    }

    fn detachScopedCalls(self: *Context) void {
        if (!self.call_attached) return;
        self.call_arena = null;
        self.call_attached = false;
    }
};

test "capture context scopes a trace tape" {
    var tape = trace.TraceTape.initGrowable(std.testing.allocator);
    defer tape.deinit();
    var context = Context.init(std.testing.allocator, .{ .tape = &tape });
    defer context.deinit();

    try context.begin();
    try context.pushFrame(0, .root, &.{}, 0, &.{}, &.{}, 0);
    try context.finishCurrentFrame(.{
        .outcome = .success,
        .memory_size = 0,
    });
    context.popFrame();
    const span = (try context.finish()).?;
    defer tape.resolve(span) catch unreachable;

    try std.testing.expectEqual(@as(usize, 1), span.frames.len);
}

test "call binding attaches for one payload inside a wider capture scope" {
    var arena = trace.CallArena.init(std.testing.allocator);
    defer arena.deinit();
    var context = Context.init(std.testing.allocator, null);
    defer context.deinit();

    try context.begin();
    try context.beginCalls(.{ .arena = &arena });
    const token = (try context.beginCall(.{
        .depth = 0,
        .kind = .call,
        .from = @splat(0x11),
        .to = @splat(0x22),
        .code_address = @splat(0x22),
    })).?;
    try context.finishCall(token, .{ .status = .success, .gas_left = 0 });
    const call_span = try context.finishCalls();

    try std.testing.expectEqual(@as(usize, 1), call_span.rows.len);
    try std.testing.expect(!context.capturesCalls());
    try std.testing.expect((try context.finish()) == null);
}

test "scoped trace detaches from a reusable state capture context" {
    var tape = trace.TraceTape.initGrowable(std.testing.allocator);
    defer tape.deinit();
    var context = Context.init(std.testing.allocator, null);
    defer context.deinit();

    try context.begin();
    try context.beginTrace(.{ .tape = &tape });
    try context.pushFrame(0, .root, &.{}, 0, &.{}, &.{}, 0);
    try context.finishCurrentFrame(.{
        .outcome = .success,
        .memory_size = 0,
    });
    context.popFrame();
    const span = try context.finishTrace();
    try tape.resolve(span);
    _ = try context.finish();

    try context.begin();
    try std.testing.expect(!context.capturesSteps());
    _ = try context.finish();
}

test "bounded capture context rejects live-frame growth before tape mutation" {
    var step_storage: [1]trace.tape.StepRow = undefined;
    var frame_storage: [2]trace.tape.FrameRow = undefined;
    var step_ref_storage: [1]trace.tape.StepTransitionRef = undefined;
    var stack_transition_storage: [1]trace.tape.StackTransition = undefined;
    var memory_transition_storage: [1]trace.tape.MemoryTransition = undefined;
    var return_data_transition_storage: [1]trace.tape.ReturnDataTransition = undefined;
    var frame_transition_storage: [2]trace.tape.FrameTransition = undefined;
    var word_storage: [1]u256 = undefined;
    var byte_storage: [0]u8 = undefined;
    var memory_write_storage: [0]trace.tape.MemoryWrite = undefined;
    var capture_storage: [1]trace.TraceCapture = undefined;
    var tape = trace.TraceTape.initBounded(.{
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
    var context = Context.initBounded(&capture_storage, .{ .tape = &tape });
    defer context.deinit();

    try context.begin();
    try context.pushFrame(0, .root, &.{}, 0, &.{}, &.{}, 0);
    try std.testing.expectError(error.TraceCapacityExceeded, context.pushFrame(1, .call, &.{}, 0, &.{}, &.{}, 0));
    try std.testing.expectEqual(@as(usize, 1), tape.frameCount());
    try context.abort();
}
