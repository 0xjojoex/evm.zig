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
    state_target: ?StateTarget = null,
    frame_captures: std.ArrayList(trace.TraceCapture) = .empty,
    next_frame_id: u32 = 0,
    mark: ?trace.TraceMark = null,
    active: bool = false,
    tape_attached: bool = false,
    call_attached: bool = false,

    pub fn init(
        allocator: std.mem.Allocator,
        trace_binding: ?TraceBinding,
        state_target: ?StateTarget,
    ) Context {
        return .{
            .allocator = allocator,
            .tape = if (trace_binding) |binding| binding.tape else null,
            .trace_profile = if (trace_binding) |binding| binding.profile else .{},
            .state_target = state_target,
        };
    }

    pub fn initWithCalls(
        allocator: std.mem.Allocator,
        trace_binding: ?TraceBinding,
        call_binding: CallBinding,
        state_target: ?StateTarget,
    ) Context {
        var context = init(allocator, trace_binding, state_target);
        context.call_arena = call_binding.arena;
        return context;
    }

    /// Build a context whose live-frame sidecar cannot allocate or outgrow the
    /// caller-provided storage. The tape may independently be bounded or
    /// growable.
    pub fn initBounded(
        frame_storage: []trace.TraceCapture,
        trace_binding: ?TraceBinding,
        state_target: ?StateTarget,
    ) Context {
        return .{
            .allocator = null,
            .tape = if (trace_binding) |binding| binding.tape else null,
            .trace_profile = if (trace_binding) |binding| binding.profile else .{},
            .state_target = state_target,
            .frame_captures = .initBuffer(frame_storage),
        };
    }

    pub fn initBoundedWithCalls(
        frame_storage: []trace.TraceCapture,
        trace_binding: ?TraceBinding,
        call_binding: CallBinding,
        state_target: ?StateTarget,
    ) Context {
        var context = initBounded(frame_storage, trace_binding, state_target);
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
        self.trace_profile = .{};
        self.tape_attached = false;
    }

    fn detachScopedCalls(self: *Context) void {
        if (!self.call_attached) return;
        self.call_arena = null;
        self.call_attached = false;
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
    var context = Context.init(std.testing.allocator, .{ .tape = &tape }, recorder.target());
    defer context.deinit();

    try context.begin();
    try context.accountAccess(.{ .address = @splat(1) });
    try context.pushFrame(0, .root, &.{}, 0, &.{}, &.{}, 0);
    try context.finishCurrentFrame(.{
        .outcome = .success,
        .memory_size = 0,
    });
    context.popFrame();
    const span = (try context.finish()).?;
    defer tape.resolve(span) catch unreachable;

    try std.testing.expectEqual(@as(usize, 1), recorder.accesses);
    try std.testing.expectEqual(@as(usize, 1), span.frames.len);
}

test "call binding attaches for one payload inside a wider capture scope" {
    var arena = trace.CallArena.init(std.testing.allocator);
    defer arena.deinit();
    var context = Context.init(std.testing.allocator, null, null);
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
    var context = Context.init(std.testing.allocator, null, null);
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
    var context = Context.initBounded(&capture_storage, .{ .tape = &tape }, null);
    defer context.deinit();

    try context.begin();
    try context.pushFrame(0, .root, &.{}, 0, &.{}, &.{}, 0);
    try std.testing.expectError(error.TraceCapacityExceeded, context.pushFrame(1, .call, &.{}, 0, &.{}, &.{}, 0));
    try std.testing.expectEqual(@as(usize, 1), tape.frameCount());
    try context.abort();
}
