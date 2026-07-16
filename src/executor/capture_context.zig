//! Operation-scoped carrier for the one captured execution runtime.

const std = @import("std");
const trace = @import("../trace.zig");

/// Internal fallible target for live state and lifecycle facts.
///
/// Step callbacks deliberately do not exist here: step consumers replay a
/// completed `TraceSpan`. The target remains erased because state hooks are
/// outside opcode dispatch and must not multiply executor/runtime types.
pub const StateTarget = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        account_access: ?*const fn (*anyopaque, trace.AccountAccess) anyerror!void = null,
        state_read: ?*const fn (*anyopaque, trace.StateRead) anyerror!void = null,
        state_write: ?*const fn (*anyopaque, trace.StateWrite) anyerror!void = null,
        checkpoint: ?*const fn (*anyopaque, trace.Checkpoint) anyerror!void = null,
    };

    pub fn init(ptr: *anyopaque, vtable: *const VTable) StateTarget {
        return .{ .ptr = ptr, .vtable = vtable };
    }

    pub inline fn accountAccess(self: StateTarget, event: trace.AccountAccess) !void {
        const callback = self.vtable.account_access orelse return;
        try callback(self.ptr, event);
    }

    pub inline fn stateRead(self: StateTarget, event: trace.StateRead) !void {
        const callback = self.vtable.state_read orelse return;
        try callback(self.ptr, event);
    }

    pub inline fn stateWrite(self: StateTarget, event: trace.StateWrite) !void {
        const callback = self.vtable.state_write orelse return;
        try callback(self.ptr, event);
    }

    pub inline fn checkpoint(self: StateTarget, event: trace.Checkpoint) !void {
        const callback = self.vtable.checkpoint orelse return;
        try callback(self.ptr, event);
    }
};

/// Fixed two-way state fanout used by block capture (for example BAL plus one
/// runtime compatibility target). It does not change execution types.
pub const StateFanout = struct {
    first: ?StateTarget = null,
    second: ?StateTarget = null,

    pub fn target(self: *StateFanout) StateTarget {
        return StateTarget.init(self, &.{
            .account_access = accountAccess,
            .state_read = stateRead,
            .state_write = stateWrite,
            .checkpoint = checkpoint,
        });
    }

    fn accountAccess(ptr: *anyopaque, event: trace.AccountAccess) !void {
        const self: *StateFanout = @ptrCast(@alignCast(ptr));
        if (self.first) |target_value| try target_value.accountAccess(event);
        if (self.second) |target_value| try target_value.accountAccess(event);
    }

    fn stateRead(ptr: *anyopaque, event: trace.StateRead) !void {
        const self: *StateFanout = @ptrCast(@alignCast(ptr));
        if (self.first) |target_value| try target_value.stateRead(event);
        if (self.second) |target_value| try target_value.stateRead(event);
    }

    fn stateWrite(ptr: *anyopaque, event: trace.StateWrite) !void {
        const self: *StateFanout = @ptrCast(@alignCast(ptr));
        if (self.first) |target_value| try target_value.stateWrite(event);
        if (self.second) |target_value| try target_value.stateWrite(event);
    }

    fn checkpoint(ptr: *anyopaque, event: trace.Checkpoint) !void {
        const self: *StateFanout = @ptrCast(@alignCast(ptr));
        if (self.first) |target_value| try target_value.checkpoint(event);
        if (self.second) |target_value| try target_value.checkpoint(event);
    }
};

/// Adapt the state-only portion of the staged runtime sink. Step callbacks are
/// never invoked here; they are replayed from `TraceSpan`.
pub fn stateTargetForSink(sink: *trace.Sink) ?StateTarget {
    const flags = sink.flags();
    if (!flags.wants_account_access and
        !flags.wants_state_read and
        !flags.wants_state_write and
        !flags.wants_checkpoint)
    {
        return null;
    }
    return StateTarget.init(sink, &.{
        .account_access = sinkAccountAccess,
        .state_read = sinkStateRead,
        .state_write = sinkStateWrite,
        .checkpoint = sinkCheckpoint,
    });
}

fn sinkAccountAccess(ptr: *anyopaque, event: trace.AccountAccess) !void {
    const sink: *trace.Sink = @ptrCast(@alignCast(ptr));
    sink.accountAccess(event);
}

fn sinkStateRead(ptr: *anyopaque, event: trace.StateRead) !void {
    const sink: *trace.Sink = @ptrCast(@alignCast(ptr));
    sink.stateRead(event);
}

fn sinkStateWrite(ptr: *anyopaque, event: trace.StateWrite) !void {
    const sink: *trace.Sink = @ptrCast(@alignCast(ptr));
    sink.stateWrite(event);
}

fn sinkCheckpoint(ptr: *anyopaque, event: trace.Checkpoint) !void {
    const sink: *trace.Sink = @ptrCast(@alignCast(ptr));
    sink.checkpoint(event);
}

pub const Context = struct {
    allocator: ?std.mem.Allocator,
    tape: ?*trace.TraceTape = null,
    state_target: ?StateTarget = null,
    frame_captures: std.ArrayList(trace.TraceCapture) = .empty,
    next_frame_id: u32 = 0,
    mark: ?trace.TraceMark = null,
    active: bool = false,
    tape_attached: bool = false,

    pub fn init(
        allocator: std.mem.Allocator,
        tape: ?*trace.TraceTape,
        state_target: ?StateTarget,
    ) Context {
        return .{
            .allocator = allocator,
            .tape = tape,
            .state_target = state_target,
        };
    }

    /// Build a context whose live-frame sidecar cannot allocate or outgrow the
    /// caller-provided storage. The tape may independently be bounded or
    /// growable.
    pub fn initBounded(
        frame_storage: []trace.TraceCapture,
        tape: ?*trace.TraceTape,
        state_target: ?StateTarget,
    ) Context {
        return .{
            .allocator = null,
            .tape = tape,
            .state_target = state_target,
            .frame_captures = .initBuffer(frame_storage),
        };
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
        self.mark = if (self.tape) |tape| try tape.begin() else null;
    }

    /// Close one successful capture. The returned span remains borrowed from
    /// the tape until the caller explicitly resolves it.
    pub fn finish(self: *Context) !?trace.TraceSpan {
        if (!self.active) return error.CaptureOperationNotActive;
        if (self.frame_captures.items.len != 0) return error.ActiveCaptureFrames;

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
        self.active = false;
    }

    pub inline fn isActive(self: *const Context) bool {
        return self.active;
    }

    pub inline fn capturesSteps(self: *const Context) bool {
        return self.active and self.mark != null;
    }

    /// Enable step capture for one sub-operation while keeping the state target
    /// active across a wider scope such as a block.
    pub fn beginTrace(self: *Context, tape: *trace.TraceTape) !void {
        if (!self.active) return error.CaptureOperationNotActive;
        if (self.mark != null) return error.TraceOperationActive;
        if (self.frame_captures.items.len != 0) return error.ActiveCaptureFrames;
        if (self.tape != null) return error.TraceOperationActive;
        self.tape = tape;
        self.tape_attached = true;
        errdefer {
            self.tape = null;
            self.tape_attached = false;
        }
        self.mark = try tape.begin();
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
    ) !void {
        if (!self.capturesSteps()) return;
        if (self.allocator) |allocator| {
            try self.frame_captures.ensureUnusedCapacity(allocator, 1);
        } else if (self.frame_captures.items.len == self.frame_captures.capacity) {
            return error.TraceCapacityExceeded;
        }
        const frame_id = self.next_frame_id;
        self.next_frame_id = std.math.add(u32, frame_id, 1) catch return error.TraceIndexOverflow;
        const parent_frame_id = if (self.frame_captures.getLastOrNull()) |parent|
            parent.frame_id
        else
            null;
        self.frame_captures.appendAssumeCapacity(try trace.TraceCapture.init(self.tape.?, .{
            .frame_id = frame_id,
            .parent_frame_id = parent_frame_id,
            .depth = depth,
            .kind = kind,
        }));
    }

    pub inline fn currentFrame(self: *Context) *trace.TraceCapture {
        return &self.frame_captures.items[self.frame_captures.items.len - 1];
    }

    pub fn finishCurrentFrame(self: *Context, completion: trace.TraceFrameFinish) !void {
        if (!self.capturesSteps()) return;
        try self.currentFrame().finishFrame(completion);
    }

    pub fn popFrame(self: *Context) void {
        if (!self.capturesSteps()) return;
        _ = self.frame_captures.pop();
    }

    pub inline fn accountAccess(self: *Context, event: trace.AccountAccess) !void {
        if (!self.active) return;
        const target = self.state_target orelse return;
        try target.accountAccess(event);
    }

    pub inline fn stateRead(self: *Context, event: trace.StateRead) !void {
        if (!self.active) return;
        const target = self.state_target orelse return;
        try target.stateRead(event);
    }

    pub inline fn stateWrite(self: *Context, event: trace.StateWrite) !void {
        if (!self.active) return;
        const target = self.state_target orelse return;
        try target.stateWrite(event);
    }

    pub inline fn checkpoint(self: *Context, event: trace.Checkpoint) !void {
        if (!self.active) return;
        const target = self.state_target orelse return;
        try target.checkpoint(event);
    }

    fn detachScopedTape(self: *Context) void {
        if (!self.tape_attached) return;
        self.tape = null;
        self.tape_attached = false;
    }
};

test "capture context scopes tape and fallible state target together" {
    const Recorder = struct {
        accesses: usize = 0,

        fn target(self: *@This()) StateTarget {
            return StateTarget.init(self, &.{ .account_access = accountAccess });
        }

        fn accountAccess(ptr: *anyopaque, _: trace.AccountAccess) !void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.accesses += 1;
        }
    };

    var tape = trace.TraceTape.initGrowable(std.testing.allocator);
    defer tape.deinit();
    var recorder = Recorder{};
    var context = Context.init(std.testing.allocator, &tape, recorder.target());
    defer context.deinit();

    try context.begin();
    try context.accountAccess(.{ .address = @splat(1) });
    try context.pushFrame(0, .root);
    try context.finishCurrentFrame(.{
        .outcome = .success,
        .stack = &.{},
        .memory_size = 0,
        .return_data_size = 0,
    });
    context.popFrame();
    const span = (try context.finish()).?;
    defer tape.resolve(span) catch unreachable;

    try std.testing.expectEqual(@as(usize, 1), recorder.accesses);
    try std.testing.expectEqual(@as(usize, 1), span.frames.len);
}

test "scoped trace detaches from a reusable state capture context" {
    var tape = trace.TraceTape.initGrowable(std.testing.allocator);
    defer tape.deinit();
    var context = Context.init(std.testing.allocator, null, null);
    defer context.deinit();

    try context.begin();
    try context.beginTrace(&tape);
    try context.pushFrame(0, .root);
    try context.finishCurrentFrame(.{
        .outcome = .success,
        .stack = &.{},
        .memory_size = 0,
        .return_data_size = 0,
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
    var stack_storage: [1]u256 = undefined;
    var capture_storage: [1]trace.TraceCapture = undefined;
    var tape = trace.TraceTape.initBounded(.{
        .steps = &step_storage,
        .frames = &frame_storage,
        .stack_words = &stack_storage,
    });
    defer tape.deinit();
    var context = Context.initBounded(&capture_storage, &tape, null);
    defer context.deinit();

    try context.begin();
    try context.pushFrame(0, .root);
    try std.testing.expectError(error.TraceCapacityExceeded, context.pushFrame(1, .call));
    try std.testing.expectEqual(@as(usize, 1), tape.frameCount());
    try context.abort();
}
