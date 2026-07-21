//! The bytecode interpreter: the core execute loop over a single call frame.

const std = @import("std");
const Memory = @import("./Memory.zig");
const Host = @import("./Host.zig");
const Bytecode = @import("./code/Bytecode.zig");
const ExecutionConfig = @import("./ExecutionConfig.zig");
const evmz = @import("./evm.zig");
const Stack = @import("./Stack.zig");
const frame_io = @import("./frame_io.zig");
const trace = @import("./trace.zig");
const tail_dispatch = @import("./interpreter/tail_dispatch.zig");
const Opcode = @import("./opcode.zig").Opcode;
const RevisionId = evmz.protocol.RevisionId;

const Error = anyerror;

pub const Status = enum(u8) { success, invalid, revert, out_of_gas };

pub const FrameStatus = enum(u8) {
    running,
    suspended,
    success,
    invalid,
    revert,
    out_of_gas,

    pub fn fromResult(status: Status) FrameStatus {
        return switch (status) {
            .success => .success,
            .invalid => .invalid,
            .revert => .revert,
            .out_of_gas => .out_of_gas,
        };
    }

    pub fn toResult(self: FrameStatus) Status {
        return switch (self) {
            .success => .success,
            .invalid => .invalid,
            .revert => .revert,
            .out_of_gas => .out_of_gas,
            .running, .suspended => unreachable,
        };
    }
};

pub const Result = struct {
    status: Status,
    gas_left: i64,
    gas_refund: i64,
    gas_reservoir: i64 = 0,
    state_gas_spent: i64 = 0,
    state_gas_from_gas_left: i64 = 0,
    output_data: []u8,

    pub fn refillIntrinsicStateGas(self: *Result, amount: i64) void {
        self.gas_reservoir = std.math.add(i64, self.gas_reservoir, amount) catch std.math.maxInt(i64);
        self.state_gas_spent = std.math.sub(i64, self.state_gas_spent, amount) catch std.math.minInt(i64);
    }

    pub fn trackStateGas(self: *Result, gas: i64) void {
        if (gas <= 0) return;
        const reservoir_available = @max(self.gas_reservoir, 0);
        const from_reservoir = @min(reservoir_available, gas);
        const from_regular = gas - from_reservoir;
        if (from_regular > self.gas_left) {
            self.status = .out_of_gas;
            self.gas_left = 0;
            return;
        }
        self.gas_reservoir -= from_reservoir;
        self.gas_left -= from_regular;
        self.state_gas_from_gas_left = std.math.add(i64, self.state_gas_from_gas_left, from_regular) catch std.math.maxInt(i64);
        self.state_gas_spent = std.math.add(i64, self.state_gas_spent, gas) catch std.math.maxInt(i64);
    }

    pub fn finalizeFrameStateGas(self: *Result) void {
        switch (self.status) {
            .success => {},
            .revert => self.unwindFrameStateGas(true),
            .invalid, .out_of_gas => self.unwindFrameStateGas(false),
        }
    }

    fn unwindFrameStateGas(self: *Result, restore_regular_gas: bool) void {
        const max_i64 = @as(i64, std.math.maxInt(i64));
        const min_i64 = @as(i64, std.math.minInt(i64));
        const reservoir_delta = std.math.sub(i64, self.state_gas_spent, self.state_gas_from_gas_left) catch if (self.state_gas_spent >= 0) max_i64 else min_i64;
        self.gas_reservoir = std.math.add(i64, self.gas_reservoir, reservoir_delta) catch if (reservoir_delta >= 0) max_i64 else min_i64;
        if (restore_regular_gas) {
            self.gas_left = std.math.add(i64, self.gas_left, self.state_gas_from_gas_left) catch if (self.state_gas_from_gas_left >= 0) max_i64 else min_i64;
        }
        self.state_gas_spent = 0;
        self.state_gas_from_gas_left = 0;
    }
};

pub const CallResume = struct {
    gas_limit: i64,
    out_offset: usize,
    out_size: usize,
    state_gas_charged: i64 = 0,
};

pub const CreateResume = struct {
    gas_limit: i64,
    state_gas_charged: i64 = 0,
};

pub const CallAction = struct {
    msg: Host.Message,
    continuation: CallResume,
};

pub const CreateAction = struct {
    msg: Host.Message,
    continuation: CreateResume,
};

pub const Action = union(enum) {
    call: CallAction,
    create: CreateAction,
};

pub const RunResult = union(enum) {
    finished: Result,
    action: Action,
};

pub fn InitFor(comptime Protocol: type) type {
    return struct {
        host: *Host,
        msg: *const Host.Message,
        bytecode: *const Bytecode,
        revision: Protocol.Revision,
        memory_allocator: ?std.mem.Allocator = null,
        memory_retain_capacity: bool = false,
        io: ?*frame_io.Slot = null,
    };
}

const FrameInit = struct {
    host: *Host,
    msg: *const Host.Message,
    bytecode: *const Bytecode,
    revision_id: RevisionId,
    memory_allocator: ?std.mem.Allocator = null,
    memory_retain_capacity: bool = false,
    io: ?*frame_io.Slot = null,
};

fn frameInitFor(comptime Protocol: type, options: InitFor(Protocol)) FrameInit {
    return .{
        .host = options.host,
        .msg = options.msg,
        .bytecode = options.bytecode,
        .revision_id = evmz.protocol.revisionIdForProtocol(Protocol, options.revision),
        .memory_allocator = options.memory_allocator,
        .memory_retain_capacity = options.memory_retain_capacity,
        .io = options.io,
    };
}

pub fn For(comptime ProtocolType: type) type {
    const StatusType = Status;

    return struct {
        const Self = @This();

        pub const Protocol = ProtocolType;
        pub const Status = StatusType;
        pub const CapturedResult = struct {
            result: Result,
            span: trace.TraceSpan,
        };

        call_frame: *CallFrame,

        pub fn init(call_frame: *CallFrame) Self {
            return .{ .call_frame = call_frame };
        }

        pub inline fn revision(frame: *const CallFrame) Protocol.Revision {
            if (comptime @hasDecl(Protocol, "support") and @intFromEnum(Protocol.support.min) == @intFromEnum(Protocol.support.max)) {
                return Protocol.support.min;
            }
            return evmz.protocol.decodeRevisionForProtocol(Protocol, frame.revision_id);
        }

        pub fn execute(self: *Self) Error!Result {
            while (true) {
                switch (try self.executeUntilAction()) {
                    .finished => |result| return result,
                    .action => |action| try self.resolveHostAction(action),
                }
            }
        }

        /// Execute this standalone frame through the protocol's fixed capture
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
                switch (try self.executeCapturedUntilAction(&frame_capture)) {
                    .finished => |result| {
                        try frame_capture.finishFrame(.{
                            .outcome = traceFrameOutcome(result.status),
                            .memory_size = self.call_frame.memory.len(),
                        });
                        return .{
                            .result = result,
                            .span = try tape.finish(mark),
                        };
                    },
                    .action => |action| {
                        try self.resolveHostAction(action);
                        switch (action) {
                            .call => |call_action| frame_capture.setPendingMemoryWrite(.{
                                .offset = call_action.continuation.out_offset,
                                .size = @min(call_action.continuation.out_size, self.call_frame.return_data.len),
                            }),
                            .create => {},
                        }
                        try frame_capture.replaceReturnData(self.call_frame.return_data);
                    },
                }
            }
        }

        pub fn executeUntilAction(self: *Self) Error!RunResult {
            try self.executeUntraced();

            if (self.call_frame.takePendingAction()) |action| {
                return .{ .action = action };
            }
            return .{ .finished = self.call_frame.getResult() };
        }

        /// Execute one captured segment through the protocol's fixed trace
        /// tail table. A CALL/CREATE suspension leaves its step open until the
        /// captured runtime applies the child result and resumes this frame.
        pub fn executeCapturedUntilAction(self: *Self, frame_capture: *trace.TraceCapture) Error!RunResult {
            if (self.call_frame.status == .running or frame_capture.pending_step != null) {
                try tail_dispatch.TraceFor(Protocol).executeTraced(
                    frame_capture,
                    self.call_frame,
                    self.call_frame.bytecode.read_bytes,
                );
            }

            if (self.call_frame.status == .running) {
                self.call_frame.status = .success;
            }
            if (self.call_frame.takePendingAction()) |action| {
                return .{ .action = action };
            }
            return .{ .finished = self.call_frame.getResult() };
        }

        fn executeUntraced(self: *Self) Error!void {
            var frame = self.call_frame;
            if (frame.status == .running) {
                try tail_dispatch.For(Protocol).execute(frame, frame.bytecode.read_bytes);
            }

            if (frame.status == .running) {
                frame.status = .success;
            }
        }

        fn resolveHostAction(self: *Self, action: Action) Error!void {
            switch (action) {
                .call => |call_action| {
                    const result = (try self.call_frame.host.call(call_action.msg)).expectCall();
                    try self.call_frame.resumeCallResult(call_action.continuation, result);
                },
                .create => |create_action| {
                    const result = (try self.call_frame.host.call(create_action.msg)).expectCreate();
                    try self.call_frame.resumeCreateResult(create_action.continuation, result);
                },
            }
        }
    };
}

pub const CallFrame = struct {
    status: FrameStatus,
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
    output_data: []u8 = &.{},
    bytecode: *const Bytecode = &Bytecode.empty,
    revision_id: RevisionId = 0,
    pending_action: ?Action = null,

    pub fn initFor(
        self: *CallFrame,
        comptime Protocol: type,
        allocator: std.mem.Allocator,
        options: InitFor(Protocol),
        msg_storage: *Host.Message,
        stack_storage: *Stack.Storage,
        memory_storage: *Memory.Storage,
    ) !void {
        try self.init(
            allocator,
            frameInitFor(Protocol, options),
            msg_storage,
            stack_storage,
            memory_storage,
        );
    }

    pub fn init(
        self: *CallFrame,
        allocator: std.mem.Allocator,
        options: FrameInit,
        msg_storage: *Host.Message,
        stack_storage: *Stack.Storage,
        memory_storage: *Memory.Storage,
    ) !void {
        const code = options.bytecode.bytes;
        const io = options.io orelse return error.MissingFrameIoStorage;

        self.host = options.host;
        msg_storage.* = options.msg.*;
        self.msg = msg_storage;
        self.stack = Stack.init(stack_storage);
        const memory_allocator = options.memory_allocator orelse allocator;
        self.memory = if (options.memory_retain_capacity)
            Memory.initRetainingCapacity(memory_storage, memory_allocator)
        else
            Memory.init(memory_storage, memory_allocator);
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
        self.output_data = self.io.output_data.slice();
        self.bytecode = options.bytecode;
        self.status = if (code.len == 0) .success else .running;
        self.revision_id = options.revision_id;
        self.pending_action = null;
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

    pub fn replaceOutputData(self: *CallFrame, output_data: []const u8) !void {
        self.output_data = @constCast(output_data);
    }

    pub fn stabilizeOutputData(self: *CallFrame) ![]u8 {
        self.output_data = try self.io.output_data.replace(self.output_data);
        return self.output_data;
    }

    pub fn setPendingAction(self: *CallFrame, action: Action) void {
        self.pending_action = action;
        self.status = .suspended;
    }

    fn takePendingAction(self: *CallFrame) ?Action {
        const action = self.pending_action orelse return null;
        self.pending_action = null;
        self.status = .running;
        return action;
    }

    pub fn resumeCallResult(self: *CallFrame, continuation: CallResume, result: Host.CallResult) !void {
        const child_gas_left = @max(result.gas_left, 0);
        self.trackGas(continuation.gas_limit - child_gas_left);
        self.gas_reservoir = result.gas_reservoir;
        self.state_gas_spent = std.math.add(i64, self.state_gas_spent, result.state_gas_spent) catch std.math.maxInt(i64);
        self.state_gas_from_gas_left = std.math.add(i64, self.state_gas_from_gas_left, result.state_gas_from_gas_left) catch std.math.maxInt(i64);
        if (result.status != .success) {
            self.refillStateGas(continuation.state_gas_charged);
        }
        if (self.status != .running) {
            return;
        }
        if (result.status == .success) {
            // EIP-2200: child call-frame refunds only survive committed frames.
            self.gas_refund += result.gas_refund;
        }

        const output_size = @min(continuation.out_size, result.output_data.len);
        self.memory.writeBytes(continuation.out_offset, result.output_data[0..output_size]);

        try self.replaceReturnData(result.output_data);
        self.stack.pushUnchecked(if (result.status == .success) 1 else 0);
    }

    pub fn resumeCreateResult(self: *CallFrame, continuation: CreateResume, result: Host.CreateResult) !void {
        const child_gas_left = @max(result.gas_left, 0);
        self.trackGas(continuation.gas_limit - child_gas_left);
        self.gas_reservoir = result.gas_reservoir;
        self.state_gas_spent = std.math.add(i64, self.state_gas_spent, result.state_gas_spent) catch std.math.maxInt(i64);
        self.state_gas_from_gas_left = std.math.add(i64, self.state_gas_from_gas_left, result.state_gas_from_gas_left) catch std.math.maxInt(i64);
        if (result.status != .success) {
            self.refillStateGas(continuation.state_gas_charged);
        }
        if (self.status != .running) {
            return;
        }
        if (result.status == .success) {
            // EIP-2200: child call-frame refunds only survive committed frames.
            self.gas_refund += result.gas_refund;
        }

        if (result.status == .success) {
            try self.replaceReturnData(&.{});
            self.stack.pushUnchecked(evmz.address.toU256(result.address));
        } else {
            try self.replaceReturnData(result.output_data);
            self.stack.pushUnchecked(0);
        }
    }

    pub fn trackGas(self: *CallFrame, gas: i64) void {
        if (gas > self.gas_left) {
            self.failWithStatus(.out_of_gas);
            return;
        }
        self.gas_left -= gas;
    }

    /// Charge EIP-8037 state gas from the reservoir first, spilling into
    /// `gas_left` only after the reservoir is empty.
    pub fn trackStateGas(self: *CallFrame, gas: i64) void {
        if (gas <= 0) return;
        const reservoir_available = @max(self.gas_reservoir, 0);
        const from_reservoir = @min(reservoir_available, gas);
        const from_regular = gas - from_reservoir;
        if (from_regular > self.gas_left) {
            self.failWithStatus(.out_of_gas);
            return;
        }
        self.gas_reservoir -= from_reservoir;
        self.gas_left -= from_regular;
        self.state_gas_from_gas_left = std.math.add(i64, self.state_gas_from_gas_left, from_regular) catch std.math.maxInt(i64);
        self.state_gas_spent = std.math.add(i64, self.state_gas_spent, gas) catch std.math.maxInt(i64);
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

    pub fn failWithStatus(self: *CallFrame, status: Status) void {
        self.status = FrameStatus.fromResult(status);
        switch (status) {
            .invalid, .out_of_gas => self.gas_left = 0,
            .success, .revert => {},
        }
    }

    pub fn isValidJumpDest(self: *CallFrame, target: usize) !bool {
        return self.bytecode.isValidJumpDest(target);
    }

    pub fn wordToUsizeOrOog(self: *CallFrame, value: u256) ?usize {
        return self.wordToIntOrStatus(usize, value, .out_of_gas);
    }

    pub fn memoryOffsetToUsizeOrOog(self: *CallFrame, offset: u256, byte_size: usize) ?usize {
        if (byte_size == 0) return 0;
        return self.wordToUsizeOrOog(offset);
    }

    pub fn wordToIntOrStatus(self: *CallFrame, comptime T: type, value: u256, status: Status) ?T {
        return std.math.cast(T, value) orelse {
            self.failWithStatus(status);
            return null;
        };
    }

    pub fn expandMemory(self: *CallFrame, offset: usize, byte_size: usize) !bool {
        if (byte_size == 0) return true;
        const end = std.math.add(usize, offset, byte_size) catch {
            self.failWithStatus(.out_of_gas);
            return false;
        };
        if (end <= self.memory.len()) return true;

        const expansion = self.memory.expansionFor(offset, byte_size) catch |err| switch (err) {
            error.OutOfMemory => {
                self.failWithStatus(.out_of_gas);
                return false;
            },
        };
        self.trackGas(expansion.cost);
        if (self.status != .running) {
            return false;
        }
        self.memory.expandPrepared(expansion) catch |err| switch (err) {
            error.OutOfMemory => {
                self.failWithStatus(.out_of_gas);
                return false;
            },
        };
        return true;
    }

    pub fn getResult(self: *const CallFrame) Result {
        var result = Result{
            .gas_left = self.gas_left,
            // EIP-2200: a frame-local refund counter is discarded on revert.
            .gas_refund = if (self.status == .success) self.gas_refund else 0,
            .gas_reservoir = self.gas_reservoir,
            .state_gas_spent = self.state_gas_spent,
            .state_gas_from_gas_left = self.state_gas_from_gas_left,
            .output_data = self.output_data,
            .status = self.status.toResult(),
        };
        result.finalizeFrameStateGas();
        return result;
    }

    pub fn traceAccountAccess(self: *CallFrame, account_address: evmz.Address) !void {
        try self.host.observeAccountAccess(account_address, self.msg.depth);
    }
};

pub const CallFrameSlot = struct {
    frame: CallFrame = undefined,
    stack_storage: Stack.Storage = undefined,
    memory_storage: Memory.Storage = .empty,
    io_storage: frame_io.Slot = undefined,
    msg: Host.Message = undefined,

    pub fn initFor(self: *CallFrameSlot, comptime Protocol: type, allocator: std.mem.Allocator, options: InitFor(Protocol)) !void {
        try self.initRaw(allocator, frameInitFor(Protocol, options));
    }

    fn initRaw(self: *CallFrameSlot, allocator: std.mem.Allocator, options: FrameInit) !void {
        self.io_storage = frame_io.Slot.initGrowable(allocator);
        errdefer self.io_storage.deinit();

        var frame_options = options;
        frame_options.io = &self.io_storage;
        try self.frame.init(allocator, frame_options, &self.msg, &self.stack_storage, &self.memory_storage);
    }

    pub fn deinit(self: *CallFrameSlot) void {
        self.frame.deinit();
        self.io_storage.deinit();
        self.* = undefined;
    }

    pub fn interpreter(self: *CallFrameSlot, comptime Protocol: type) For(Protocol) {
        return For(Protocol).init(&self.frame);
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
    const msg = Host.Message{
        .depth = 0,
        .kind = .call,
        .gas = 100,
        .recipient = evmz.addr(0),
        .sender = evmz.addr(0),
        .input_data = &.{},
        .value = 0,
    };
    var msg_storage: Host.Message = undefined;
    var stack_storage: Stack.Storage = undefined;
    var memory_storage: Memory.Storage = .empty;
    var io_storage = frame_io.Slot.initGrowable(std.testing.allocator);
    defer io_storage.deinit();
    var bytecode = try Bytecode.init(std.testing.allocator, &code);
    defer bytecode.deinit(std.testing.allocator);
    var frame: CallFrame = undefined;
    try frame.init(std.testing.allocator, .{
        .host = &host,
        .msg = &msg,
        .bytecode = &bytecode,
        .revision_id = evmz.protocol.revisionId(evmz.eth.Revision.latest),
        .io = &io_storage,
    }, &msg_storage, &stack_storage, &memory_storage);
    defer frame.deinit();
    try std.testing.expect(frame.stack.slots == &stack_storage);

    var interpreter = For(evmz.Evm.ExecutionProtocol).init(&frame);
    const result = try interpreter.execute();

    try std.testing.expectEqual(Status.success, result.status);
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
    const msg = Host.Message{
        .depth = 0,
        .kind = .call,
        .gas = 100,
        .recipient = evmz.addr(0),
        .sender = evmz.addr(0),
        .input_data = &.{},
        .value = 0,
    };
    var msg_storage: Host.Message = undefined;
    var stack_storage: Stack.Storage = undefined;
    var memory_storage: Memory.Storage = .empty;
    var io_storage = frame_io.Slot.initGrowable(std.testing.allocator);
    defer io_storage.deinit();
    var bytecode = try Bytecode.init(std.testing.allocator, &code);
    defer bytecode.deinit(std.testing.allocator);
    var frame: CallFrame = undefined;
    try frame.init(std.testing.allocator, .{
        .host = &host,
        .msg = &msg,
        .bytecode = &bytecode,
        .revision_id = evmz.protocol.revisionId(evmz.eth.Revision.latest),
        .io = &io_storage,
    }, &msg_storage, &stack_storage, &memory_storage);
    defer frame.deinit();
    try std.testing.expectEqual(@intFromPtr(&memory_storage), @intFromPtr(frame.memory.bytes));

    var interpreter = For(evmz.Evm.ExecutionProtocol).init(&frame);
    const result = try interpreter.execute();

    try std.testing.expectEqual(Status.success, result.status);
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
    const msg = Host.Message{
        .depth = 7,
        .kind = .call,
        .gas = 100,
        .recipient = evmz.addr(0),
        .sender = evmz.addr(0),
        .input_data = &.{},
        .value = 0,
    };

    var frame = try OwnedCallFrame(evmz.Evm.ExecutionProtocol).init(std.testing.allocator, .{
        .host = &host,
        .msg = &msg,
        .code = &code,
        .revision = .latest,
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

    try std.testing.expectEqual(Status.success, result.status);
    try std.testing.expectEqual(@as(u8, 2), starts);
    try std.testing.expectEqual(@as(u8, 2), ends);
}

test "interpreter captured tail table records a replay span" {
    const code = [_]u8{ @intFromEnum(Opcode.PUSH1), 0x2a, @intFromEnum(Opcode.STOP) };
    var host: Host = undefined;
    const msg = Host.Message{
        .depth = 0,
        .kind = .call,
        .gas = 100,
        .recipient = evmz.addr(0),
        .sender = evmz.addr(0),
        .input_data = &.{},
        .value = 0,
    };

    var tape = trace.TraceTape.initGrowable(std.testing.allocator);
    defer tape.deinit();
    const mark = try tape.begin(.{});
    var capture = try trace.TraceCapture.init(&tape, .{
        .frame_id = 0,
        .parent_frame_id = null,
        .depth = 0,
        .kind = .root,
    });
    var frame = try OwnedCallFrame(evmz.Evm.ExecutionProtocol).init(std.testing.allocator, .{
        .host = &host,
        .msg = &msg,
        .code = &code,
        .revision = .latest,
    });
    defer frame.deinit();
    var interpreter = frame.interpreter();

    const run_result = try interpreter.executeCapturedUntilAction(&capture);
    const result = switch (run_result) {
        .finished => |finished| finished,
        .action => unreachable,
    };
    try capture.finishFrame(.{
        .outcome = .success,
        .memory_size = interpreter.call_frame.memory.len(),
    });
    const span = try tape.finish(mark);
    defer tape.resolve(span) catch unreachable;

    try std.testing.expectEqual(Status.success, result.status);
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

test "interpreter captured tail table records optional memory writes" {
    const code = evmz.t.bytecode(.{ .PUSH1, 0x2a, .PUSH0, .MSTORE, .STOP });
    var host: Host = undefined;
    const msg = Host.Message{
        .depth = 0,
        .kind = .call,
        .gas = 100,
        .recipient = evmz.addr(0),
        .sender = evmz.addr(0),
        .input_data = &.{},
        .value = 0,
    };
    var frame = try OwnedCallFrame(evmz.Evm.ExecutionProtocol).init(std.testing.allocator, .{
        .host = &host,
        .msg = &msg,
        .code = &code,
        .revision = .latest,
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
    const Case = struct {
        code: []const u8,
        gas: i64,
        status: Status,
        outcome: trace.TraceFrameOutcome,
        step_outcome: ?trace.TraceStepOutcome,
    };
    const cases = [_]Case{
        .{ .code = &.{}, .gas = 100, .status = .success, .outcome = .success, .step_outcome = null },
        .{ .code = &explicit_success, .gas = 100, .status = .success, .outcome = .success, .step_outcome = .success },
        .{ .code = &revert, .gas = 100, .status = .revert, .outcome = .revert, .step_outcome = .revert },
        .{ .code = &invalid, .gas = 100, .status = .invalid, .outcome = .invalid, .step_outcome = .invalid },
        .{ .code = &stack_fault, .gas = 100, .status = .invalid, .outcome = .invalid, .step_outcome = .invalid },
        .{ .code = &out_of_gas, .gas = 2, .status = .out_of_gas, .outcome = .out_of_gas, .step_outcome = .out_of_gas },
    };

    var tape = trace.TraceTape.initGrowable(std.testing.allocator);
    defer tape.deinit();
    for (cases) |case| {
        var host: Host = undefined;
        const msg = Host.Message{
            .depth = 0,
            .kind = .call,
            .gas = case.gas,
            .recipient = evmz.addr(0),
            .sender = evmz.addr(0),
            .input_data = &.{},
            .value = 0,
        };
        var frame = try OwnedCallFrame(evmz.Evm.ExecutionProtocol).init(std.testing.allocator, .{
            .host = &host,
            .msg = &msg,
            .code = case.code,
            .revision = .latest,
        });
        defer frame.deinit();
        var interpreter = frame.interpreter();

        const captured = try interpreter.capture(&tape, .{});
        try std.testing.expectEqual(case.status, captured.result.status);
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
    const msg = Host.Message{
        .depth = 0,
        .kind = .call,
        .gas = 100,
        .recipient = evmz.addr(0),
        .sender = evmz.addr(0),
        .input_data = &.{},
        .value = 0,
    };
    var frame = try OwnedCallFrame(evmz.Evm.ExecutionProtocol).init(std.testing.allocator, .{
        .host = &host,
        .msg = &msg,
        .code = &code,
        .revision = .latest,
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

test "interpreter state gas charges reservoir before gas left and refills LIFO" {
    var frame: CallFrame = undefined;
    frame.status = .running;
    frame.gas_left = 10;
    frame.gas_reservoir = 5;
    frame.state_gas_spent = 0;
    frame.state_gas_from_gas_left = 0;

    frame.trackStateGas(8);
    try std.testing.expectEqual(FrameStatus.running, frame.status);
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
    frame.status = .running;
    frame.gas_left = 2;
    frame.gas_reservoir = 5;
    frame.state_gas_spent = 0;
    frame.state_gas_from_gas_left = 0;

    frame.trackStateGas(8);
    try std.testing.expectEqual(FrameStatus.out_of_gas, frame.status);
    try std.testing.expectEqual(@as(i64, 0), frame.gas_left);
    try std.testing.expectEqual(@as(i64, 5), frame.gas_reservoir);
    try std.testing.expectEqual(@as(i64, 0), frame.state_gas_spent);
    try std.testing.expectEqual(@as(i64, 0), frame.state_gas_from_gas_left);
}

test "interpreter reverts frame-local state gas" {
    var frame: CallFrame = undefined;
    frame.status = .running;
    frame.gas_left = 10;
    frame.gas_reservoir = 5;
    frame.state_gas_spent = 0;
    frame.state_gas_from_gas_left = 0;
    frame.output_data = &.{};

    frame.trackStateGas(8);
    frame.failWithStatus(.revert);
    const result = frame.getResult();

    try std.testing.expectEqual(Status.revert, result.status);
    try std.testing.expectEqual(@as(i64, 10), result.gas_left);
    try std.testing.expectEqual(@as(i64, 5), result.gas_reservoir);
    try std.testing.expectEqual(@as(i64, 0), result.state_gas_spent);
    try std.testing.expectEqual(@as(i64, 0), result.state_gas_from_gas_left);
}

test "interpreter exceptional halt unwinds state gas without restoring regular gas" {
    var frame: CallFrame = undefined;
    frame.status = .running;
    frame.gas_left = 10;
    frame.gas_reservoir = 5;
    frame.state_gas_spent = 0;
    frame.state_gas_from_gas_left = 0;
    frame.output_data = &.{};

    frame.trackStateGas(8);
    frame.failWithStatus(.invalid);
    const result = frame.getResult();

    try std.testing.expectEqual(Status.invalid, result.status);
    try std.testing.expectEqual(@as(i64, 0), result.gas_left);
    try std.testing.expectEqual(@as(i64, 5), result.gas_reservoir);
    try std.testing.expectEqual(@as(i64, 0), result.state_gas_spent);
    try std.testing.expectEqual(@as(i64, 0), result.state_gas_from_gas_left);
}

pub fn OwnedInitFor(comptime Protocol: type) type {
    return struct {
        host: *Host,
        msg: *const Host.Message,
        /// Convenience byte input. The owned frame prepares it before execution.
        code: ?[]const u8 = null,
        /// Borrow an already prepared artifact instead of owning a temporary one.
        bytecode: ?*const Bytecode = null,
        revision: Protocol.Revision,
        config: ExecutionConfig = .base,
        memory_allocator: ?std.mem.Allocator = null,
        memory_retain_capacity: bool = false,
    };
}

pub fn OwnedCallFrame(comptime ProtocolType: type) type {
    return struct {
        const Self = @This();

        pub const Protocol = ProtocolType;
        pub const Init = OwnedInitFor(Protocol);

        allocator: std.mem.Allocator,
        slot: *CallFrameSlot,
        frame: *CallFrame,
        owned_bytecode: ?*Bytecode,

        pub fn init(allocator: std.mem.Allocator, options: Init) !Self {
            if (options.code != null and options.bytecode != null) {
                return error.AmbiguousBytecodeInput;
            }

            var owned_bytecode: ?*Bytecode = null;
            errdefer if (owned_bytecode) |bytecode| {
                bytecode.deinit(allocator);
                allocator.destroy(bytecode);
            };
            const bytecode = options.bytecode orelse prepared: {
                const code = options.code orelse &.{};
                if (code.len == 0) break :prepared &Bytecode.empty;
                const prepared = try allocator.create(Bytecode);
                prepared.* = Bytecode.prepare(allocator, code, options.config) catch |err| {
                    allocator.destroy(prepared);
                    return err;
                };
                owned_bytecode = prepared;
                break :prepared prepared;
            };

            const slot = try allocator.create(CallFrameSlot);
            errdefer allocator.destroy(slot);
            try slot.initFor(Protocol, allocator, .{
                .host = options.host,
                .msg = options.msg,
                .bytecode = bytecode,
                .revision = options.revision,
                .memory_allocator = options.memory_allocator,
                .memory_retain_capacity = options.memory_retain_capacity,
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
            if (self.owned_bytecode) |bytecode| {
                bytecode.deinit(self.allocator);
                self.allocator.destroy(bytecode);
            }
            self.* = undefined;
        }

        pub fn interpreter(self: *Self) For(Protocol) {
            return For(Protocol).init(self.frame);
        }
    };
}

comptime {
    if (@sizeOf(usize) == 8) {
        assertLayout(@sizeOf(CallFrame) == 400, "CallFrame size changed; rerun VM-loop canary benches");
        assertLayout(@alignOf(CallFrame) == 16, "CallFrame alignment changed; rerun VM-loop canary benches");
        assertLayout(@offsetOf(CallFrame, "stack") == 240, "CallFrame stack view moved; rerun arithmetic VM-loop bench");
        assertLayout(@offsetOf(CallFrame, "memory") == 256, "CallFrame memory moved; rerun memory VM-loop bench");
        assertLayout(@offsetOf(CallFrame, "gas_left") == 304, "CallFrame gas_left moved; rerun VM-loop canary benches");
        assertLayout(@offsetOf(CallFrame, "msg") == 232, "CallFrame msg pointer moved; check message ownership layout");
        assertLayout(@sizeOf(CallFrameSlot) == 33456, "CallFrameSlot size changed; check pooled frame/message layout");
        assertLayout(@offsetOf(CallFrameSlot, "frame") == 0, "CallFrameSlot frame moved; check pooled frame/message layout");
        assertLayout(@offsetOf(CallFrameSlot, "stack_storage") == @sizeOf(CallFrame), "CallFrameSlot stack storage no longer follows frame metadata");
        assertLayout(@offsetOf(CallFrameSlot, "msg") == @sizeOf(CallFrame) + @sizeOf(Stack.Storage), "CallFrameSlot msg no longer follows frame stack storage");
        assertLayout(@offsetOf(CallFrameSlot, "memory_storage") == @offsetOf(CallFrameSlot, "msg") + @sizeOf(Host.Message), "CallFrameSlot memory storage no longer follows message storage");
    }
}

fn assertLayout(comptime ok: bool, comptime message: []const u8) void {
    if (!ok) @compileError(message);
}

test "interpreter can execute prepared bytecode jumpdest map" {
    const t = @import("./t.zig");
    const raw = t.bytecode(.{ .PUSH1, 0x04, .JUMP, .STOP, .JUMPDEST });
    var bytecode = try Bytecode.init(std.testing.allocator, &raw);
    defer bytecode.deinit(std.testing.allocator);

    var mock_host = t.MockHost.init(std.testing.allocator, null);
    defer mock_host.deinit();
    var host = mock_host.host();
    const msg = Host.Message{
        .depth = 0,
        .kind = .call,
        .gas = 100_000,
        .recipient = evmz.addr(0),
        .sender = evmz.addr(0),
        .input_data = &.{},
        .value = 0,
    };

    var frame = try OwnedCallFrame(evmz.Evm.ExecutionProtocol).init(std.testing.allocator, .{
        .host = &host,
        .msg = &msg,
        .bytecode = &bytecode,
        .revision = .latest,
    });
    defer frame.deinit();
    var interpreter = frame.interpreter();

    const result = try interpreter.execute();
    try std.testing.expectEqual(Status.success, result.status);
    try std.testing.expectEqual(&bytecode, interpreter.call_frame.bytecode);
    try std.testing.expect(bytecode.jumpdests.analyzed);
}

test "prepared bytecode preserves truncated push semantics" {
    const t = @import("./t.zig");
    const raw = t.bytecode(.{ .PUSH32, 0x01 });
    var bytecode = try Bytecode.init(std.testing.allocator, &raw);
    defer bytecode.deinit(std.testing.allocator);

    var mock_host = t.MockHost.init(std.testing.allocator, null);
    defer mock_host.deinit();
    var host = mock_host.host();
    const msg = Host.Message{
        .depth = 0,
        .kind = .call,
        .gas = 100_000,
        .recipient = evmz.addr(0),
        .sender = evmz.addr(0),
        .input_data = &.{},
        .value = 0,
    };

    var frame = try OwnedCallFrame(evmz.Evm.ExecutionProtocol).init(std.testing.allocator, .{
        .host = &host,
        .msg = &msg,
        .bytecode = &bytecode,
        .revision = .latest,
    });
    defer frame.deinit();
    var interpreter = frame.interpreter();

    const result = try interpreter.execute();
    try std.testing.expectEqual(Status.success, result.status);
    try std.testing.expectEqual(@as(usize, raw.len), interpreter.call_frame.code.len);
    try std.testing.expectEqual(@as(u256, 1) << 248, interpreter.call_frame.stack.peek().?);
}

test "prepared bytecode keeps CODESIZE semantic length" {
    const t = @import("./t.zig");
    const raw = t.bytecode(.{.CODESIZE});
    var bytecode = try Bytecode.init(std.testing.allocator, &raw);
    defer bytecode.deinit(std.testing.allocator);

    var mock_host = t.MockHost.init(std.testing.allocator, null);
    defer mock_host.deinit();
    var host = mock_host.host();
    const msg = Host.Message{
        .depth = 0,
        .kind = .call,
        .gas = 100_000,
        .recipient = evmz.addr(0),
        .sender = evmz.addr(0),
        .input_data = &.{},
        .value = 0,
    };

    var frame = try OwnedCallFrame(evmz.Evm.ExecutionProtocol).init(std.testing.allocator, .{
        .host = &host,
        .msg = &msg,
        .bytecode = &bytecode,
        .revision = .latest,
    });
    defer frame.deinit();
    var interpreter = frame.interpreter();

    const result = try interpreter.execute();
    try std.testing.expectEqual(Status.success, result.status);
    try std.testing.expectEqual(@as(u256, raw.len), interpreter.call_frame.stack.peek().?);
}
