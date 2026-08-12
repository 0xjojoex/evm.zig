//! The bytecode interpreter: the core execute loop over a single call frame.

const std = @import("std");
const Memory = @import("./Memory.zig");
const Host = @import("./Host.zig");
const Bytecode = @import("./code/Bytecode.zig");
const Spec = @import("./spec.zig").Spec;
const evmz = @import("./evm.zig");
const Stack = @import("./Stack.zig");
const frame_io = @import("./frame_io.zig");
const trace = @import("./trace.zig");
const tail_dispatch = @import("./interpreter/tail_dispatch.zig");
const Opcode = @import("./opcode.zig").Opcode;
const TerminalCause = @import("./execution.zig").TerminalCause;

const Error = anyerror;

pub const Status = evmz.execution.Status;

pub const FrameHalt = evmz.execution.FrameHalt;

pub const FrameState = union(enum) {
    running,
    suspended: *const Action,
    halted: FrameHalt,
};

pub const FrameResult = struct {
    halt: FrameHalt,
    gas_left: i64,
    gas_refund: i64,
    gas_reservoir: i64 = 0,
    state_gas_spent: i64 = 0,
    state_gas_from_gas_left: i64 = 0,
    /// Borrowed from the frame's EVM memory. Executor entry points copy root
    /// output into their retained result storage before releasing the frame.
    output_data: []u8,

    comptime {
        std.debug.assert(@sizeOf(FrameResult) == 64);
    }

    pub fn status(self: FrameResult) Status {
        return self.halt.status();
    }

    pub fn terminalCause(self: FrameResult) TerminalCause {
        return self.halt.terminalCause();
    }

    pub fn executionResult(self: FrameResult) evmz.execution.ExecutionResult {
        return .{
            .outcome = .{
                .status = self.status(),
                .cause = self.terminalCause(),
            },
            .frame_halt = self.halt,
            .gas_left = self.gas_left,
            .gas_refund = self.gas_refund,
            .gas_reservoir = self.gas_reservoir,
            .state_gas_spent = self.state_gas_spent,
            .state_gas_from_gas_left = self.state_gas_from_gas_left,
            .output_data = self.output_data,
        };
    }
};

pub const Action = frame_io.Action;

pub const RunResult = union(enum) {
    finished: FrameResult,
    /// Borrowed from the frame's action storage and valid only until the frame
    /// resumes or its owner relocates that storage.
    suspended: *const Action,
};

pub const Init = struct {
    host: *Host,
    msg: *const Host.Message,
    bytecode: Bytecode.View,
};

pub fn Interpreter(comptime spec: Spec) type {
    const StatusType = Status;
    const OwnedCallFrameType = OwnedCallFrameFor(spec);

    const TailDispatch = tail_dispatch.Dispatch(spec, .{ .traced = false });

    return struct {
        const Self = @This();

        pub const specification = spec;
        pub const Status = StatusType;
        pub const OwnedCallFrame = OwnedCallFrameType;
        pub const CapturedResult = struct {
            result: FrameResult,
            span: trace.TraceSpan,
        };

        call_frame: *CallFrame,

        pub fn init(call_frame: *CallFrame) Self {
            return .{ .call_frame = call_frame };
        }

        pub fn execute(self: *Self) Error!FrameResult {
            while (true) {
                switch (try self.executeUntilSuspended()) {
                    .finished => |result| return result,
                    .suspended => |action| try self.resolveSuspension(action),
                }
            }
        }

        /// Execute this standalone frame through the exact spec's fixed capture
        /// table and return a replay-only span. The consumer type never enters
        /// the interpreter type graph.
        pub fn capture(self: *Self, tape: *trace.TraceTape, profile: trace.CaptureProfile) Error!CapturedResult {
            const mark = try tape.begin(profile);
            errdefer tape.abort(mark) catch {};

            var frame_capture = try trace.TraceCapture.init(tape, .{
                .frame_id = 0,
                .parent_frame_id = null,
                .depth = self.call_frame.msg.depth,
                .kind = .root,
                .initial_stack = self.call_frame.stack.asSlice(),
                .initial_memory_size = self.call_frame.memory.len(),
                .initial_return_data = self.call_frame.return_data,
            });
            while (true) {
                switch (try self.executeCapturedUntilSuspended(&frame_capture)) {
                    .finished => |result| {
                        try frame_capture.finishFrame(.{
                            .outcome = traceFrameOutcome(result.status()),
                            .memory_size = self.call_frame.memory.len(),
                        });
                        return .{
                            .result = result,
                            .span = try tape.finish(mark),
                        };
                    },
                    .suspended => |action| {
                        const pending_memory_write: ?struct { offset: usize, size: usize } = switch (action.*) {
                            .call => |call_action| .{
                                .offset = call_action.continuation.out_offset,
                                .size = call_action.continuation.out_size,
                            },
                            .create => null,
                        };
                        try self.resolveSuspension(action);
                        if (pending_memory_write) |write| {
                            frame_capture.setPendingMemoryWrite(.{
                                .offset = write.offset,
                                .size = @min(write.size, self.call_frame.return_data.len),
                            });
                        }
                        try frame_capture.replaceReturnData(self.call_frame.return_data);
                    },
                }
            }
        }

        pub fn executeUntilSuspended(self: *Self) Error!RunResult {
            try self.executeUntraced();

            if (self.call_frame.suspendedAction()) |action| {
                return .{ .suspended = action };
            }
            return .{ .finished = self.call_frame.result() };
        }

        /// Execute one captured segment through the exact spec's fixed trace
        /// tail table. A CALL/CREATE suspension leaves its step open until the
        /// captured runtime applies the child result and resumes this frame.
        pub fn executeCapturedUntilSuspended(self: *Self, frame_capture: *trace.TraceCapture) Error!RunResult {
            if (self.call_frame.isRunning() or frame_capture.pending_step != null) {
                try tail_dispatch.Dispatch(spec, .{ .traced = true }).executeTraced(
                    frame_capture,
                    self.call_frame,
                );
            }

            if (self.call_frame.isRunning()) {
                self.call_frame.halt(.success);
            }
            if (self.call_frame.suspendedAction()) |action| {
                return .{ .suspended = action };
            }
            return .{ .finished = self.call_frame.result() };
        }

        fn executeUntraced(self: *Self) Error!void {
            var frame = self.call_frame;
            if (frame.isRunning()) {
                try TailDispatch.execute(frame);
            }

            if (frame.isRunning()) {
                frame.halt(.success);
            }
        }

        fn resolveSuspension(self: *Self, action: *const Action) Error!void {
            const msg = switch (action.*) {
                .call => |call_action| call_action.msg,
                .create => |create_action| create_action.msg,
            };
            try self.call_frame.resumeWith(try self.call_frame.host.call(msg));
        }
    };
}

pub const CallFrame = struct {
    state: FrameState,
    host: *Host,
    msg: *Host.Message,
    stack: Stack,
    memory: Memory,
    pc: usize = 0,
    code: []const u8 = &.{},
    gas_left: i64 = 0,
    gas_refund: i64 = 0,
    gas_reservoir: i64 = 0,
    state_gas_spent: i64 = 0,
    state_gas_from_gas_left: i64 = 0,
    return_data: []u8 = &.{},
    io: *frame_io.Slot = undefined,
    output_range: Memory.Range = .{},
    jumpdest_masks: [*]const usize = Bytecode.View.empty.jumpdest_masks,

    comptime {
        std.debug.assert(@sizeOf(CallFrame) == 184);
        std.debug.assert(@alignOf(CallFrame) == 8);
        std.debug.assert(@offsetOf(CallFrame, "state") == 0);
        std.debug.assert(@offsetOf(CallFrame, "host") == 16);
        std.debug.assert(@offsetOf(CallFrame, "msg") == 24);
        std.debug.assert(@offsetOf(CallFrame, "stack") == 32);
        std.debug.assert(@offsetOf(CallFrame, "memory") == 48);
        std.debug.assert(@offsetOf(CallFrame, "gas_left") == 96);
    }

    pub fn init(
        self: *CallFrame,
        allocator: std.mem.Allocator,
        options: Init,
        msg_storage: *Host.Message,
        stack: Stack,
        memory_storage: *Memory.Storage,
        io: *frame_io.Slot,
    ) void {
        self.initFields(
            options,
            msg_storage,
            stack,
            Memory.init(memory_storage, allocator),
            io,
        );
    }

    pub fn initRetainingMemoryCapacity(
        self: *CallFrame,
        allocator: std.mem.Allocator,
        options: Init,
        msg_storage: *Host.Message,
        stack: Stack,
        memory_storage: *Memory.Storage,
        io: *frame_io.Slot,
    ) void {
        self.initFields(
            options,
            msg_storage,
            stack,
            Memory.initRetainingCapacity(memory_storage, allocator),
            io,
        );
    }

    fn initFields(
        self: *CallFrame,
        options: Init,
        msg_storage: *Host.Message,
        stack: Stack,
        memory: Memory,
        io: *frame_io.Slot,
    ) void {
        const code = options.bytecode.bytes;

        self.host = options.host;
        msg_storage.* = options.msg.*;
        self.msg = msg_storage;
        self.stack = stack;
        self.memory = memory;
        self.pc = 0;
        self.code = code;
        self.gas_left = options.msg.gas;
        self.gas_refund = 0;
        self.gas_reservoir = options.msg.gas_reservoir;
        self.state_gas_spent = 0;
        self.state_gas_from_gas_left = 0;
        self.io = io;
        self.io.clearFrame();
        self.return_data = self.io.return_data.slice();
        self.output_range = .{};
        self.jumpdest_masks = options.bytecode.jumpdest_masks;
        self.state = if (code.len == 0) .{ .halted = .success } else .running;
    }

    pub fn deinit(self: *CallFrame) void {
        self.memory.deinit();
        self.deinitOwnedFields();
        self.* = undefined;
    }

    pub fn deinitRetainingMemoryCapacity(self: *CallFrame) void {
        self.memory.deinitRetainingCapacity();
        self.deinitOwnedFields();
        self.* = undefined;
    }

    fn deinitOwnedFields(self: *CallFrame) void {
        self.io.clearFrame();
    }

    pub fn replaceReturnData(self: *CallFrame, return_data: []const u8) !void {
        self.return_data = try self.io.return_data.replace(return_data);
    }

    pub fn setOutputRange(self: *CallFrame, offset: usize, len: usize) void {
        self.output_range = self.memory.range(offset, len);
    }

    pub fn outputData(self: *const CallFrame) []u8 {
        return self.memory.readRange(self.output_range);
    }

    pub fn isRunning(self: *const CallFrame) bool {
        return self.state == .running;
    }

    pub fn isSuspended(self: *const CallFrame) bool {
        return self.state == .suspended;
    }

    /// Borrow the frame-owned action until the frame resumes.
    pub fn suspendedAction(self: *const CallFrame) ?*const Action {
        return switch (self.state) {
            .suspended => |action| action,
            else => null,
        };
    }

    pub fn haltReason(self: *const CallFrame) ?FrameHalt {
        return switch (self.state) {
            .halted => |reason| reason,
            else => null,
        };
    }

    pub fn suspendWith(self: *CallFrame, action: Action) void {
        std.debug.assert(self.isRunning());
        self.io.action = action;
        self.state = .{ .suspended = &self.io.action };
    }

    /// Rebind cold frame storage after its owner relocates it.
    pub fn rebindIo(self: *CallFrame, io: *frame_io.Slot) void {
        self.io = io;
        if (self.isSuspended()) self.state = .{ .suspended = &io.action };
        self.return_data = io.return_data.slice();
    }

    /// Resume from an engine result while preserving its CALL/CREATE type.
    pub fn resumeWith(self: *CallFrame, child: Host.Result) !void {
        switch (child) {
            .call => |call_result| try self.resumeWithCall(call_result),
            .create => |create_result| try self.resumeWithCreate(create_result),
        }
    }

    /// Resume only a CALL action. A mismatch leaves the frame suspended.
    pub fn resumeWithCall(self: *CallFrame, child: Host.CallResult) !void {
        const continuation = (try self.takeSuspended(.call)).continuation;
        if (!self.settleChild(continuation.gas_limit, continuation.state_gas_charged, child)) return;

        const output_size = @min(continuation.out_size, child.output_data.len);
        self.memory.writeBytes(continuation.out_offset, child.output_data[0..output_size]);
        try self.replaceReturnData(child.output_data);
        self.stack.push(@intFromBool(child.outcome.status == .success));
    }

    /// Resume only a CREATE action. A mismatch leaves the frame suspended.
    pub fn resumeWithCreate(self: *CallFrame, child: Host.CreateResult) !void {
        const continuation = (try self.takeSuspended(.create)).continuation;
        if (!self.settleChild(continuation.gas_limit, continuation.state_gas_charged, child)) return;

        if (child.outcome.status == .success) {
            // A deployed contract yields its address, never return data.
            try self.replaceReturnData(&.{});
            self.stack.push(child.address.toU256());
        } else {
            try self.replaceReturnData(child.output_data);
            self.stack.push(0);
        }
    }

    /// Take the pending action of `kind` and put the frame back in `.running`,
    /// leaving it suspended if the kind does not match.
    fn takeSuspended(
        self: *CallFrame,
        comptime kind: std.meta.Tag(Action),
    ) !@FieldType(Action, @tagName(kind)) {
        const action = self.suspendedAction() orelse return error.FrameNotSuspended;
        if (action.* != kind) return error.ResumeKindMismatch;
        const payload = @field(action.*, @tagName(kind));
        self.state = .running;
        return payload;
    }

    /// Fold a returned child frame's gas accounting into this one. Returns
    /// whether execution may continue.
    fn settleChild(self: *CallFrame, gas_limit: i64, state_gas_charged: i64, child: anytype) bool {
        const succeeded = child.outcome.status == .success;
        const gas_charged = self.trackGas(gas_limit - @max(child.gas_left, 0));
        self.gas_reservoir = child.gas_reservoir;
        self.state_gas_spent +|= child.state_gas_spent;
        self.state_gas_from_gas_left +|= child.state_gas_from_gas_left;
        if (!succeeded) self.refillStateGas(state_gas_charged);
        if (!gas_charged) return false;
        // EIP-2200: child call-frame refunds only survive committed frames.
        if (succeeded) self.gas_refund += child.gas_refund;
        return true;
    }

    /// Returns whether execution may continue after the charge.
    pub fn trackGas(self: *CallFrame, gas: i64) bool {
        if (gas > self.gas_left) {
            @branchHint(.unlikely);
            self.halt(.out_of_gas);
            return false;
        }
        self.gas_left -= gas;
        return true;
    }

    /// Charge EIP-8037 state gas from the reservoir first, spilling into
    /// `gas_left` only after the reservoir is empty. Returns whether execution
    /// may continue after the charge.
    pub fn trackStateGas(self: *CallFrame, gas: i64) bool {
        if (gas <= 0) return true;
        const reservoir_available = @max(self.gas_reservoir, 0);
        const from_reservoir = @min(reservoir_available, gas);
        const from_regular = gas - from_reservoir;
        if (from_regular > self.gas_left) {
            @branchHint(.unlikely);
            self.halt(.out_of_gas);
            return false;
        }
        self.gas_reservoir -= from_reservoir;
        self.gas_left -= from_regular;
        self.state_gas_from_gas_left = std.math.add(i64, self.state_gas_from_gas_left, from_regular) catch std.math.maxInt(i64);
        self.state_gas_spent = std.math.add(i64, self.state_gas_spent, gas) catch std.math.maxInt(i64);
        return true;
    }

    /// Refill state gas in LIFO order: gas spilled from `gas_left` is restored
    /// first, then the reservoir is credited.
    pub fn refillStateGas(self: *CallFrame, gas: i64) void {
        if (gas <= 0) return;
        const to_regular = @min(self.state_gas_from_gas_left, gas);
        self.gas_left = std.math.add(i64, self.gas_left, to_regular) catch std.math.maxInt(i64);
        self.state_gas_from_gas_left -= to_regular;
        const to_reservoir = gas - to_regular;
        self.gas_reservoir = std.math.add(i64, self.gas_reservoir, to_reservoir) catch std.math.maxInt(i64);
        self.state_gas_spent = std.math.sub(i64, self.state_gas_spent, gas) catch std.math.minInt(i64);
    }

    /// Terminal EVM transition. Fault halts consume all remaining gas;
    /// successful and reverting halts preserve it.
    pub fn halt(self: *CallFrame, reason: FrameHalt) void {
        std.debug.assert(self.isRunning());
        self.state = .{ .halted = reason };
        if (reason.consumesAllGas()) self.gas_left = 0;
    }

    inline fn requireStack(self: *CallFrame, needed: usize) bool {
        if (self.stack.len < needed) {
            self.halt(.stack_underflow);
            return false;
        }
        return true;
    }

    inline fn requireStackRoom(self: *CallFrame) bool {
        if (self.stack.len >= Stack.capacity) {
            self.halt(.stack_overflow);
            return false;
        }
        return true;
    }

    /// Semantic stack boundary: malformed bytecode halts the frame; the
    /// invariant-only `Stack` operations below never return Zig errors.
    pub inline fn push(self: *CallFrame, value: u256) bool {
        if (!self.requireStackRoom()) return false;
        self.stack.push(value);
        return true;
    }

    pub inline fn pop(self: *CallFrame) ?u256 {
        if (!self.requireStack(1)) return null;
        return self.stack.pop();
    }

    pub inline fn popN(self: *CallFrame, comptime n: usize) ?[n]u256 {
        if (!self.requireStack(n)) return null;
        return self.stack.popN(n);
    }

    pub inline fn peek(self: *CallFrame) ?u256 {
        if (!self.requireStack(1)) return null;
        return self.stack.peek().?;
    }

    pub inline fn dup(self: *CallFrame, comptime n: usize) bool {
        if (!self.requireStack(n) or !self.requireStackRoom()) return false;
        self.stack.dup(n);
        return true;
    }

    pub inline fn dupDepth(self: *CallFrame, n: usize) bool {
        if (!self.requireStack(n) or !self.requireStackRoom()) return false;
        self.stack.dupDepth(n);
        return true;
    }

    pub inline fn swap(self: *CallFrame, comptime n: usize) bool {
        if (!self.requireStack(n + 1)) return false;
        self.stack.swap(n);
        return true;
    }

    pub inline fn swapDepth(self: *CallFrame, n: usize) bool {
        if (!self.requireStack(n + 1)) return false;
        self.stack.swapDepth(n);
        return true;
    }

    pub inline fn exchangeDepths(self: *CallFrame, n: usize, m: usize) bool {
        if (!self.requireStack(@max(n, m) + 1)) return false;
        self.stack.exchangeDepths(n, m);
        return true;
    }

    pub fn isValidJumpDest(self: *CallFrame, target: usize) !bool {
        if (target >= self.code.len) return false;
        if (self.code[target] != @intFromEnum(Opcode.JUMPDEST)) return false;
        const mask_bits = @bitSizeOf(usize);
        return self.jumpdest_masks[target / mask_bits] &
            (@as(usize, 1) << @intCast(target % mask_bits)) != 0;
    }

    pub fn wordToUsizeOrOog(self: *CallFrame, value: u256) ?usize {
        return self.wordToIntOrHalt(usize, value, .out_of_gas);
    }

    pub fn memoryOffsetToUsizeOrOog(self: *CallFrame, offset: u256, byte_size: usize) ?usize {
        if (byte_size == 0) return 0;
        return self.wordToUsizeOrOog(offset);
    }

    pub fn wordToIntOrHalt(self: *CallFrame, comptime T: type, value: u256, reason: FrameHalt) ?T {
        return std.math.cast(T, value) orelse {
            @branchHint(.unlikely);
            self.halt(reason);
            return null;
        };
    }

    pub fn expandMemory(self: *CallFrame, offset: usize, byte_size: usize) !bool {
        if (byte_size == 0) return true;
        const end = std.math.add(usize, offset, byte_size) catch {
            @branchHint(.unlikely);
            self.halt(.out_of_gas);
            return false;
        };
        if (end <= self.memory.len()) return true;

        const expansion = self.memory.planExpansion(offset, byte_size) orelse {
            @branchHint(.unlikely);
            self.halt(.out_of_gas);
            return false;
        };
        if (!self.trackGas(expansion.cost)) return false;
        try self.memory.applyExpansion(expansion);
        return true;
    }

    pub fn result(self: *const CallFrame) FrameResult {
        const halt_reason = self.haltReason() orelse unreachable;
        var frame_result = FrameResult{
            .gas_left = self.gas_left,
            // EIP-2200: a frame-local refund counter is discarded on revert.
            .gas_refund = if (halt_reason == .success) self.gas_refund else 0,
            .gas_reservoir = self.gas_reservoir,
            .state_gas_spent = self.state_gas_spent,
            .state_gas_from_gas_left = self.state_gas_from_gas_left,
            .output_data = self.outputData(),
            .halt = halt_reason,
        };
        evmz.execution.finalizeStateGas(&frame_result);
        return frame_result;
    }

    pub fn traceAccountAccess(self: *CallFrame, account_address: evmz.AddressWord) !void {
        try self.host.observeAccountAccess(account_address, self.msg.depth);
    }
};

pub const CallFrameSlot = struct {
    frame: CallFrame = undefined,
    stack_storage: Stack.Storage = undefined,
    memory_storage: Memory.Storage = .empty,
    io_storage: frame_io.Slot = undefined,
    msg: Host.Message = undefined,

    comptime {
        std.debug.assert(@sizeOf(CallFrameSlot) == 33424);
        std.debug.assert(@offsetOf(CallFrameSlot, "stack_storage") == 0);
        std.debug.assert(@offsetOf(CallFrameSlot, "io_storage") == @sizeOf(Stack.Storage));
        std.debug.assert(@offsetOf(CallFrameSlot, "msg") == @offsetOf(CallFrameSlot, "io_storage") + @sizeOf(frame_io.Slot));
        std.debug.assert(@offsetOf(CallFrameSlot, "frame") == @offsetOf(CallFrameSlot, "msg") + @sizeOf(Host.Message));
        std.debug.assert(@offsetOf(CallFrameSlot, "memory_storage") == @offsetOf(CallFrameSlot, "frame") + @sizeOf(CallFrame));
    }

    pub fn init(self: *CallFrameSlot, allocator: std.mem.Allocator, options: Init) void {
        self.io_storage.init(allocator);
        self.frame.init(
            allocator,
            options,
            &self.msg,
            Stack.init(&self.stack_storage, 0),
            &self.memory_storage,
            &self.io_storage,
        );
    }

    pub fn deinit(self: *CallFrameSlot) void {
        self.frame.deinit();
        self.io_storage.deinit();
        self.* = undefined;
    }

    pub fn interpreter(self: *CallFrameSlot, comptime spec: Spec) Interpreter(spec) {
        return Interpreter(spec).init(&self.frame);
    }
};

test "call frame can execute with externally supplied stack storage" {
    const code = [_]u8{
        @intFromEnum(Opcode.PUSH1),
        0x02,
        @intFromEnum(Opcode.PUSH1),
        0x03,
        @intFromEnum(Opcode.ADD),
        @intFromEnum(Opcode.STOP),
    };
    var host: Host = undefined;
    var msg = evmz.t.defaultMessage();
    msg.gas = 100;
    var msg_storage: Host.Message = undefined;
    var stack_storage: Stack.Storage = undefined;
    var memory_storage: Memory.Storage = .empty;
    var io_storage: frame_io.Slot = undefined;
    io_storage.init(std.testing.allocator);
    defer io_storage.deinit();
    var bytecode = try Bytecode.init(std.testing.allocator, &code);
    defer bytecode.deinit(std.testing.allocator);
    var frame: CallFrame = undefined;
    frame.init(
        std.testing.allocator,
        .{
            .host = &host,
            .msg = &msg,
            .bytecode = bytecode.view(),
        },
        &msg_storage,
        Stack.init(&stack_storage, 0),
        &memory_storage,
        &io_storage,
    );
    defer frame.deinit();
    try std.testing.expectEqual(@intFromPtr(&stack_storage), @intFromPtr(frame.stack.base));
    try std.testing.expectEqual(@as(u32, 0), frame.stack.base_word);

    var interpreter = evmz.Evm.Interpreter.init(&frame);
    const result = try interpreter.execute();

    try std.testing.expectEqual(Status.success, result.status());
    try std.testing.expectEqual(@as(u256, 5), frame.stack.peek().?);
    try std.testing.expectEqual(@as(u256, 5), stack_storage[0]);
}

test "call frame can execute with externally supplied memory storage" {
    const code = [_]u8{
        @intFromEnum(Opcode.PUSH1),
        0x2a,
        @intFromEnum(Opcode.PUSH1),
        0x00,
        @intFromEnum(Opcode.MSTORE),
        @intFromEnum(Opcode.STOP),
    };
    var host: Host = undefined;
    var msg = evmz.t.defaultMessage();
    msg.gas = 100;
    var msg_storage: Host.Message = undefined;
    var stack_storage: Stack.Storage = undefined;
    var memory_storage: Memory.Storage = .empty;
    var io_storage: frame_io.Slot = undefined;
    io_storage.init(std.testing.allocator);
    defer io_storage.deinit();
    var bytecode = try Bytecode.init(std.testing.allocator, &code);
    defer bytecode.deinit(std.testing.allocator);
    var frame: CallFrame = undefined;
    frame.init(
        std.testing.allocator,
        .{
            .host = &host,
            .msg = &msg,
            .bytecode = bytecode.view(),
        },
        &msg_storage,
        Stack.init(&stack_storage, 0),
        &memory_storage,
        &io_storage,
    );
    defer frame.deinit();
    try std.testing.expectEqual(@intFromPtr(&memory_storage), @intFromPtr(frame.memory.bytes));

    var interpreter = evmz.Evm.Interpreter.init(&frame);
    const result = try interpreter.execute();

    try std.testing.expectEqual(Status.success, result.status());
    try std.testing.expectEqual(@as(usize, 32), memory_storage.items.len);
    try std.testing.expectEqual(@as(u8, 0x2a), memory_storage.items[31]);
}

pub fn traceFrameOutcome(status: Status) trace.TraceFrameOutcome {
    return switch (status) {
        .success => .success,
        .invalid => .invalid,
        .revert => .revert,
        .out_of_gas => .out_of_gas,
    };
}

test "interpreter trace cursor records step start and end" {
    const code = [_]u8{ @intFromEnum(Opcode.PUSH1), 0x2a, @intFromEnum(Opcode.POP) };
    var host: Host = undefined;
    var msg = evmz.t.defaultMessage();
    msg.depth = 7;
    msg.gas = 100;

    var frame = try evmz.Evm.Interpreter.OwnedCallFrame.init(std.testing.allocator, .{
        .host = &host,
        .msg = &msg,
        .source = .{ .code = &code },
    });
    defer frame.deinit();
    var interpreter = frame.interpreter();
    var tape = trace.TraceTape.initGrowable(std.testing.allocator);
    defer tape.deinit();

    const captured = try interpreter.capture(&tape, .{ .stack = .full });
    defer tape.resolve(captured.span) catch unreachable;
    const result = captured.result;

    var starts: u8 = 0;
    var ends: u8 = 0;
    var cursor = trace.TraceCursor.init(captured.span);
    while (try cursor.next()) |event| switch (event) {
        .step_start => |view| {
            if (starts == 0) {
                try std.testing.expectEqual(@as(usize, 0), view.row.pc);
                try std.testing.expectEqual(@as(u8, @intFromEnum(Opcode.PUSH1)), view.row.opcode);
                try std.testing.expectEqual(@as(?Opcode, .PUSH1), std.enums.fromInt(Opcode, view.row.opcode));
                try std.testing.expectEqual(@as(u16, 7), view.frame.depth);
                try std.testing.expectEqual(@as(i64, 100), view.row.gas_before);
                try std.testing.expectEqual(@as(usize, 0), view.state.stack.?.len);
            }
            starts += 1;
        },
        .step_end => |view| {
            if (ends == 0) {
                try std.testing.expectEqual(@as(usize, 2), view.row.pc_next);
                try std.testing.expect(!view.terminal);
                try std.testing.expectEqual(@as(i64, 97), view.row.gas_after);
                try std.testing.expectEqual(@as(i64, 3), view.row.gas_before - view.row.gas_after);
                try std.testing.expectEqualSlices(u256, &.{0x2a}, view.state.stack.?);
            }
            if (view.terminal) {
                try std.testing.expectEqual(@as(usize, 2), view.row.pc);
                try std.testing.expectEqual(@as(usize, 3), view.row.pc_next);
                try std.testing.expectEqual(trace.TraceFrameOutcome.success, view.frame.outcome);
                try std.testing.expectEqual(@as(usize, 0), view.state.stack.?.len);
            }
            ends += 1;
        },
        .frame_enter, .frame_leave => {},
    };

    try std.testing.expectEqual(Status.success, result.status());
    try std.testing.expectEqual(@as(u8, 2), starts);
    try std.testing.expectEqual(@as(u8, 2), ends);
}

test "interpreter captured tail table records a replay span" {
    const code = [_]u8{ @intFromEnum(Opcode.PUSH1), 0x2a, @intFromEnum(Opcode.STOP) };
    var host: Host = undefined;
    var msg = evmz.t.defaultMessage();
    msg.gas = 100;

    var tape = trace.TraceTape.initGrowable(std.testing.allocator);
    defer tape.deinit();
    const mark = try tape.begin(.{});
    var capture = try trace.TraceCapture.init(&tape, .{
        .frame_id = 0,
        .parent_frame_id = null,
        .depth = 0,
        .kind = .root,
    });
    var frame = try evmz.Evm.Interpreter.OwnedCallFrame.init(std.testing.allocator, .{
        .host = &host,
        .msg = &msg,
        .source = .{ .code = &code },
    });
    defer frame.deinit();
    var interpreter = frame.interpreter();

    const run_result = try interpreter.executeCapturedUntilSuspended(&capture);
    const result = switch (run_result) {
        .finished => |finished| finished,
        .suspended => unreachable,
    };
    try capture.finishFrame(.{
        .outcome = .success,
        .memory_size = interpreter.call_frame.memory.len(),
    });
    const span = try tape.finish(mark);
    defer tape.resolve(span) catch unreachable;

    try std.testing.expectEqual(Status.success, result.status());
    try std.testing.expectEqual(@as(usize, 2), span.steps.len);
    try std.testing.expectEqual(@as(u8, @intFromEnum(Opcode.PUSH1)), span.steps[0].opcode);
    try std.testing.expectEqual(@as(u32, 2), span.steps[0].pc_next);
    var cursor = trace.TraceCursor.init(span);
    cursor.enterFrame(span.frames[0]);
    try std.testing.expectEqual(@as(usize, 0), cursor.stack().?.len);
    cursor.finishStep(span.steps[0]);
    try std.testing.expectEqual(@as(u8, @intFromEnum(Opcode.STOP)), span.steps[1].opcode);
    try std.testing.expectEqualSlices(u256, &.{0x2a}, cursor.stack().?);
}

test "captured tail memory exhaustion remains a resource error" {
    const code = evmz.t.bytecode(.{
        .PUSH1, 0x2a, .PUSH1, 0x20, .MSTORE,
        .STOP,
    });
    const no_growth_allocator: std.mem.Allocator = .{
        .ptr = undefined,
        .vtable = &.{
            .alloc = std.mem.Allocator.noAlloc,
            .resize = std.mem.Allocator.noResize,
            .remap = std.mem.Allocator.noRemap,
            .free = std.mem.Allocator.noFree,
        },
    };
    var host: Host = undefined;
    var msg = evmz.t.defaultMessage();
    msg.gas = 100;

    var bytecode = try Bytecode.init(std.testing.allocator, &code);
    defer bytecode.deinit(std.testing.allocator);
    var msg_storage: Host.Message = undefined;
    var stack_storage: Stack.Storage = undefined;
    var memory_storage: Memory.Storage = .empty;
    var io_storage: frame_io.Slot = undefined;
    io_storage.init(std.testing.allocator);
    defer io_storage.deinit();
    var frame: CallFrame = undefined;
    frame.init(
        no_growth_allocator,
        .{
            .host = &host,
            .msg = &msg,
            .bytecode = bytecode.view(),
        },
        &msg_storage,
        Stack.init(&stack_storage, 0),
        &memory_storage,
        &io_storage,
    );
    defer frame.deinit();

    var tape = trace.TraceTape.initGrowable(std.testing.allocator);
    defer tape.deinit();
    const mark = try tape.begin(.{});
    var capture = try trace.TraceCapture.init(&tape, .{
        .frame_id = 0,
        .parent_frame_id = null,
        .depth = 0,
        .kind = .root,
    });
    var interpreter = evmz.Evm.Interpreter.init(&frame);

    try std.testing.expectError(error.OutOfMemory, interpreter.executeCapturedUntilSuspended(&capture));
    try std.testing.expect(frame.isRunning());
    try tape.abort(mark);

    const reuse_mark = try tape.begin(.{});
    try tape.abort(reuse_mark);
}

test "interpreter captured tail table records optional memory writes" {
    const code = evmz.t.bytecode(.{ .PUSH1, 0x2a, .PUSH0, .MSTORE, .STOP });
    var host: Host = undefined;
    var msg = evmz.t.defaultMessage();
    msg.gas = 100;
    var frame = try evmz.Evm.Interpreter.OwnedCallFrame.init(std.testing.allocator, .{
        .host = &host,
        .msg = &msg,
        .source = .{ .code = &code },
    });
    defer frame.deinit();
    var interpreter = frame.interpreter();
    var tape = trace.TraceTape.initGrowable(std.testing.allocator);
    defer tape.deinit();

    const captured = try interpreter.capture(&tape, .{ .memory = .writes });
    defer tape.resolve(captured.span) catch unreachable;
    var cursor = trace.tape.TraceCursor.init(captured.span);
    cursor.enterFrame(captured.span.frames[0]);
    const writes = for (captured.span.steps) |row| {
        cursor.finishStep(row);
        if (row.opcode == @intFromEnum(Opcode.MSTORE)) break try cursor.memoryWrites();
    } else unreachable;
    try std.testing.expectEqual(@as(usize, 1), writes.len);
    const bytes = cursor.memoryWriteBytes(writes[0]);
    try std.testing.expectEqual(@as(usize, 32), bytes.len);
    try std.testing.expectEqual(@as(u8, 0x2a), bytes[31]);
}

test "interpreter captured tail table preserves terminal and fault outcomes" {
    const explicit_success = [_]u8{@intFromEnum(Opcode.STOP)};
    const revert = [_]u8{
        @intFromEnum(Opcode.PUSH0),
        @intFromEnum(Opcode.PUSH0),
        @intFromEnum(Opcode.REVERT),
    };
    const invalid = [_]u8{0xfe};
    const stack_fault = [_]u8{@intFromEnum(Opcode.POP)};
    const out_of_gas = [_]u8{ @intFromEnum(Opcode.PUSH1), 0x2a };
    const memory_offset_overflow = evmz.t.bytecode(.{ .PUSH1, 0x2a, .PUSH0, .NOT, .MSTORE });
    const Case = struct {
        code: []const u8,
        gas: i64,
        status: Status,
        cause: TerminalCause,
        outcome: trace.TraceFrameOutcome,
        step_outcome: ?trace.TraceStepOutcome,
    };
    const cases = [_]Case{
        .{ .code = &.{}, .gas = 100, .status = .success, .cause = .none, .outcome = .success, .step_outcome = null },
        .{ .code = &explicit_success, .gas = 100, .status = .success, .cause = .none, .outcome = .success, .step_outcome = .success },
        .{ .code = &revert, .gas = 100, .status = .revert, .cause = .revert, .outcome = .revert, .step_outcome = .revert },
        .{ .code = &invalid, .gas = 100, .status = .invalid, .cause = .invalid_opcode, .outcome = .invalid, .step_outcome = .invalid },
        .{ .code = &stack_fault, .gas = 100, .status = .invalid, .cause = .stack_underflow, .outcome = .invalid, .step_outcome = .invalid },
        .{ .code = &out_of_gas, .gas = 2, .status = .out_of_gas, .cause = .out_of_gas, .outcome = .out_of_gas, .step_outcome = .out_of_gas },
        .{ .code = &memory_offset_overflow, .gas = 100, .status = .out_of_gas, .cause = .out_of_gas, .outcome = .out_of_gas, .step_outcome = .out_of_gas },
    };

    var tape = trace.TraceTape.initGrowable(std.testing.allocator);
    defer tape.deinit();
    for (cases) |case| {
        var host: Host = undefined;
        var msg = evmz.t.defaultMessage();
        msg.gas = case.gas;
        var frame = try evmz.Evm.Interpreter.OwnedCallFrame.init(std.testing.allocator, .{
            .host = &host,
            .msg = &msg,
            .source = .{ .code = case.code },
        });
        defer frame.deinit();
        var interpreter = frame.interpreter();

        const captured = try interpreter.capture(&tape, .{});
        try std.testing.expectEqual(case.status, captured.result.status());
        try std.testing.expectEqual(case.cause, captured.result.terminalCause());
        try std.testing.expectEqual(@as(usize, 1), captured.span.frames.len);
        try std.testing.expectEqual(case.outcome, captured.span.frames[0].outcome);
        if (case.step_outcome) |expected| {
            try std.testing.expect(captured.span.steps.len != 0);
            try std.testing.expectEqual(expected, captured.span.steps[captured.span.steps.len - 1].outcome);
        } else {
            try std.testing.expectEqual(@as(usize, 0), captured.span.steps.len);
        }
        try tape.resolve(captured.span);
        try tape.reset();
    }
}

test "interpreter capture replays minimal EIP-3155 JSONL" {
    const code = [_]u8{ @intFromEnum(Opcode.PUSH1), 0x2a, @intFromEnum(Opcode.STOP) };
    var host: Host = undefined;
    var msg = evmz.t.defaultMessage();
    msg.gas = 100;
    var frame = try evmz.Evm.Interpreter.OwnedCallFrame.init(std.testing.allocator, .{
        .host = &host,
        .msg = &msg,
        .source = .{ .code = &code },
    });
    defer frame.deinit();
    var interpreter = frame.interpreter();
    var tape = trace.TraceTape.initGrowable(std.testing.allocator);
    defer tape.deinit();

    const captured = try interpreter.capture(&tape, .{});
    defer tape.resolve(captured.span) catch unreachable;
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try trace.eip3155.writeSteps(&output.writer, captured.span);

    try std.testing.expectEqualStrings(
        "{\"pc\":0,\"op\":96,\"gas\":\"0x64\",\"gasCost\":\"0x3\",\"memSize\":0,\"stack\":[],\"depth\":1,\"returnData\":\"0x\",\"refund\":0,\"opName\":\"PUSH1\"}\n" ++
            "{\"pc\":2,\"op\":0,\"gas\":\"0x61\",\"gasCost\":\"0x0\",\"memSize\":0,\"stack\":[\"0x2a\"],\"depth\":1,\"returnData\":\"0x\",\"refund\":0,\"opName\":\"STOP\"}\n",
        output.written(),
    );
}

test "yielded action stays in frame-owned sidecar until resume" {
    var host: Host = undefined;
    var msg = evmz.t.defaultMessage();
    msg.gas = 100;
    var owned = try evmz.Evm.Interpreter.OwnedCallFrame.init(std.testing.allocator, .{
        .host = &host,
        .msg = &msg,
    });
    defer owned.deinit();
    try std.testing.expect(owned.frame.suspendedAction() == null);

    const continuation = Action.CallResume{
        .gas_limit = 10,
        .out_offset = 0,
        .out_size = 0,
        .state_gas_charged = 0,
    };
    owned.frame.state = .running;
    owned.frame.suspendWith(.{ .call = .{
        .msg = msg,
        .continuation = continuation,
    } });
    try std.testing.expect(owned.frame.suspendedAction().? == &owned.slot.io_storage.action);

    var interpreter = owned.interpreter();
    const yielded = try interpreter.executeUntilSuspended();
    const action = switch (yielded) {
        .suspended => |value| value,
        .finished => return error.ExpectedAction,
    };
    try std.testing.expect(owned.frame.isSuspended());
    try std.testing.expectEqual(owned.frame.suspendedAction().?, action);
    const yielded_continuation = switch (action.*) {
        .call => |call| call.continuation,
        .create => return error.ExpectedCallAction,
    };
    try std.testing.expectEqual(continuation, yielded_continuation);

    try owned.frame.resumeWithCall(.{
        .outcome = .{ .status = .success, .cause = .none },
        .output_data = &.{},
        .gas_left = 10,
        .gas_refund = 0,
    });
    try std.testing.expect(owned.frame.isRunning());
    try std.testing.expect(owned.frame.suspendedAction() == null);
    try std.testing.expectEqualSlices(u256, &.{1}, owned.frame.stack.asSlice());
}

test "call and create resumes reject mismatched suspended actions" {
    var host: Host = undefined;
    var msg = evmz.t.defaultMessage();
    msg.gas = 100;
    var owned = try evmz.Evm.Interpreter.OwnedCallFrame.init(std.testing.allocator, .{
        .host = &host,
        .msg = &msg,
    });
    defer owned.deinit();

    const call_result = Host.CallResult{
        .outcome = .{ .status = .success, .cause = .none },
        .output_data = &.{},
        .gas_left = 10,
        .gas_refund = 0,
    };
    const create_result = Host.CreateResult{
        .outcome = .{ .status = .success, .cause = .none },
        .output_data = &.{},
        .gas_left = 10,
        .gas_refund = 0,
        .address = evmz.addr(0xbeef),
    };

    owned.frame.state = .running;
    owned.frame.suspendWith(.{ .call = .{
        .msg = msg,
        .continuation = .{
            .gas_limit = 10,
            .out_offset = 0,
            .out_size = 0,
        },
    } });
    const borrowed_call = owned.frame.suspendedAction().?;
    try std.testing.expectError(error.ResumeKindMismatch, owned.frame.resumeWithCreate(create_result));
    try std.testing.expect(owned.frame.isSuspended());
    try std.testing.expectEqual(borrowed_call, owned.frame.suspendedAction().?);
    try owned.frame.resumeWithCall(call_result);
    try std.testing.expect(owned.frame.isRunning());

    owned.frame.suspendWith(.{ .create = .{
        .msg = msg,
        .continuation = .{ .gas_limit = 10 },
    } });
    const borrowed_create = owned.frame.suspendedAction().?;
    var interpreter = owned.interpreter();
    const yielded_create = switch (try interpreter.executeUntilSuspended()) {
        .suspended => |action| action,
        .finished => return error.ExpectedAction,
    };
    try std.testing.expectEqual(borrowed_create, yielded_create);
    try std.testing.expectError(error.ResumeKindMismatch, owned.frame.resumeWithCall(call_result));
    try std.testing.expect(owned.frame.isSuspended());
    try std.testing.expectEqual(borrowed_create, owned.frame.suspendedAction().?);
    try owned.frame.resumeWithCreate(create_result);
    try std.testing.expect(owned.frame.isRunning());

    try std.testing.expectError(error.FrameNotSuspended, owned.frame.resumeWithCall(call_result));
}

test "interpreter gas charge reports whether execution may continue" {
    var frame: CallFrame = undefined;
    frame.state = .running;
    frame.gas_left = 10;

    try std.testing.expect(frame.trackGas(4));
    try std.testing.expectEqual(@as(i64, 6), frame.gas_left);
    try std.testing.expect(frame.isRunning());

    try std.testing.expect(!frame.trackGas(7));
    try std.testing.expectEqual(@as(i64, 0), frame.gas_left);
    try std.testing.expectEqual(FrameHalt.out_of_gas, frame.haltReason().?);
}

test "interpreter state gas charges reservoir before gas left and refills LIFO" {
    var frame: CallFrame = undefined;
    frame.state = .running;
    frame.gas_left = 10;
    frame.gas_reservoir = 5;
    frame.state_gas_spent = 0;
    frame.state_gas_from_gas_left = 0;

    try std.testing.expect(frame.trackStateGas(8));
    try std.testing.expect(frame.isRunning());
    try std.testing.expectEqual(@as(i64, 7), frame.gas_left);
    try std.testing.expectEqual(@as(i64, 0), frame.gas_reservoir);
    try std.testing.expectEqual(@as(i64, 8), frame.state_gas_spent);
    try std.testing.expectEqual(@as(i64, 3), frame.state_gas_from_gas_left);

    frame.refillStateGas(4);
    try std.testing.expectEqual(@as(i64, 10), frame.gas_left);
    try std.testing.expectEqual(@as(i64, 1), frame.gas_reservoir);
    try std.testing.expectEqual(@as(i64, 4), frame.state_gas_spent);
    try std.testing.expectEqual(@as(i64, 0), frame.state_gas_from_gas_left);
}

test "interpreter state gas charge is atomic on out of gas" {
    var frame: CallFrame = undefined;
    frame.state = .running;
    frame.gas_left = 2;
    frame.gas_reservoir = 5;
    frame.state_gas_spent = 0;
    frame.state_gas_from_gas_left = 0;

    try std.testing.expect(!frame.trackStateGas(8));
    try std.testing.expectEqual(FrameHalt.out_of_gas, frame.haltReason().?);
    try std.testing.expectEqual(@as(i64, 0), frame.gas_left);
    try std.testing.expectEqual(@as(i64, 5), frame.gas_reservoir);
    try std.testing.expectEqual(@as(i64, 0), frame.state_gas_spent);
    try std.testing.expectEqual(@as(i64, 0), frame.state_gas_from_gas_left);
}

test "interpreter reverts frame-local state gas" {
    var frame: CallFrame = undefined;
    frame.state = .running;
    frame.gas_left = 10;
    frame.gas_reservoir = 5;
    frame.state_gas_spent = 0;
    frame.state_gas_from_gas_left = 0;
    frame.output_range = .{};

    try std.testing.expect(frame.trackStateGas(8));
    frame.halt(.revert);
    const result = frame.result();

    try std.testing.expectEqual(Status.revert, result.status());
    try std.testing.expectEqual(@as(i64, 10), result.gas_left);
    try std.testing.expectEqual(@as(i64, 5), result.gas_reservoir);
    try std.testing.expectEqual(@as(i64, 0), result.state_gas_spent);
    try std.testing.expectEqual(@as(i64, 0), result.state_gas_from_gas_left);
}

test "interpreter exceptional halt unwinds state gas without restoring regular gas" {
    var frame: CallFrame = undefined;
    frame.state = .running;
    frame.gas_left = 10;
    frame.gas_reservoir = 5;
    frame.state_gas_spent = 0;
    frame.state_gas_from_gas_left = 0;
    frame.output_range = .{};

    try std.testing.expect(frame.trackStateGas(8));
    frame.halt(.invalid_opcode);
    const result = frame.result();

    try std.testing.expectEqual(Status.invalid, result.status());
    try std.testing.expectEqual(@as(i64, 0), result.gas_left);
    try std.testing.expectEqual(@as(i64, 5), result.gas_reservoir);
    try std.testing.expectEqual(@as(i64, 0), result.state_gas_spent);
    try std.testing.expectEqual(@as(i64, 0), result.state_gas_from_gas_left);
}

fn OwnedCallFrameFor(comptime spec: Spec) type {
    return struct {
        const Self = @This();

        pub const Options = struct {
            /// Where the executed bytecode comes from.
            pub const Source = union(enum) {
                /// Raw bytes. The frame prepares an artifact and owns it.
                code: []const u8,
                /// An already prepared artifact the caller keeps alive.
                bytecode: Bytecode.View,
            };

            host: *Host,
            msg: *const Host.Message,
            source: Source = .{ .code = &.{} },
        };

        allocator: std.mem.Allocator,
        slot: *CallFrameSlot,
        frame: *CallFrame,
        owned_bytecode: ?Bytecode,

        pub fn init(allocator: std.mem.Allocator, options: Options) !Self {
            var owned_bytecode: ?Bytecode = null;
            errdefer if (owned_bytecode) |*bytecode| bytecode.deinit(allocator);
            const bytecode = switch (options.source) {
                .bytecode => |view| view,
                .code => |code| prepared: {
                    if (code.len == 0) break :prepared Bytecode.View.empty;
                    const prepared = try Bytecode.init(allocator, code);
                    owned_bytecode = prepared;
                    break :prepared prepared.view();
                },
            };

            const slot = try allocator.create(CallFrameSlot);
            errdefer allocator.destroy(slot);
            slot.init(allocator, .{
                .host = options.host,
                .msg = options.msg,
                .bytecode = bytecode,
            });
            return .{
                .allocator = allocator,
                .slot = slot,
                .frame = &slot.frame,
                .owned_bytecode = owned_bytecode,
            };
        }

        pub fn deinit(self: *Self) void {
            self.slot.deinit();
            self.allocator.destroy(self.slot);
            if (self.owned_bytecode) |*bytecode| bytecode.deinit(self.allocator);
            self.* = undefined;
        }

        pub fn interpreter(self: *Self) Interpreter(spec) {
            return Interpreter(spec).init(self.frame);
        }
    };
}
