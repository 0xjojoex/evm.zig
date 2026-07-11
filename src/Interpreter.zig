//! The bytecode interpreter: the core execute loop over a single call frame.

const std = @import("std");
const Memory = @import("./Memory.zig");
const Host = @import("./Host.zig");
const Bytecode = @import("./code/Bytecode.zig");
const JumpDestMap = @import("./code/JumpDestMap.zig");
const evmz = @import("./evm.zig");
const instruction = @import("./instruction.zig");
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
        code: []const u8 = &.{},
        bytecode: ?*Bytecode = null,
        revision: Protocol.Revision,
        trace_sink: ?*trace.Sink = null,
        memory_allocator: ?std.mem.Allocator = null,
        memory_retain_capacity: bool = false,
        io: ?*frame_io.Slot = null,
    };
}

const FrameInit = struct {
    host: *Host,
    msg: *const Host.Message,
    code: []const u8 = &.{},
    bytecode: ?*Bytecode = null,
    revision_id: RevisionId,
    trace_sink: ?*trace.Sink = null,
    memory_allocator: ?std.mem.Allocator = null,
    memory_retain_capacity: bool = false,
    io: ?*frame_io.Slot = null,
};

fn frameInitFor(comptime Protocol: type, options: InitFor(Protocol)) FrameInit {
    return .{
        .host = options.host,
        .msg = options.msg,
        .code = options.code,
        .bytecode = options.bytecode,
        .revision_id = evmz.protocol.revisionIdForProtocol(Protocol, options.revision),
        .trace_sink = options.trace_sink,
        .memory_allocator = options.memory_allocator,
        .memory_retain_capacity = options.memory_retain_capacity,
        .io = options.io,
    };
}

pub fn For(comptime ProtocolType: type) type {
    const StatusType = Status;

    return struct {
        const Self = @This();
        const Instructions = instruction.For(Protocol);

        pub const Protocol = ProtocolType;
        pub const Status = StatusType;

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

        pub fn executeUntilAction(self: *Self) Error!RunResult {
            if (self.call_frame.wantsStepTracing()) {
                while (self.call_frame.status == .running) {
                    try self.stepTraced();
                }
            } else {
                try self.executeUntraced();
            }

            if (self.call_frame.takePendingAction()) |action| {
                return .{ .action = action };
            }
            return .{ .finished = self.call_frame.getResult() };
        }

        fn executeUntraced(self: *Self) Error!void {
            var frame = self.call_frame;
            if (frame.bytecode) |bytecode| {
                try tail_dispatch.For(Protocol).execute(frame, bytecode.read_bytes);
            } else {
                try executeUntracedBounded(frame);
            }

            if (frame.status == .running) {
                frame.status = .success;
            }
        }

        fn executeUntracedBounded(frame: *CallFrame) Error!void {
            while (frame.status == .running and frame.pc < frame.code.len) {
                const opcode_byte = frame.code[frame.pc];
                frame.pc += 1;
                try executeOpcode(opcode_byte, frame);
            }
        }

        inline fn executeOpcode(opcode_byte: u8, frame: *CallFrame) Error!void {
            Instructions.execute(opcode_byte, frame) catch |err| {
                if (invalidStatusError(err)) {
                    if (frame.status == .running) {
                        frame.failWithStatus(.invalid);
                    }
                    return;
                }
                return err;
            };
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

        fn stepTraced(self: *Self) Error!void {
            if (self.call_frame.pc >= self.call_frame.code.len) {
                self.call_frame.status = .success;
                return;
            }

            const pc = self.call_frame.pc;
            const opcode_byte = self.call_frame.code[pc];
            const sink = self.call_frame.trace_sink.?;
            const trace_flags = sink.flags();
            const wants_start = trace_flags.wants_step_start;
            const wants_end = trace_flags.wants_step_end;
            const decoded_opcode = if (trace_flags.wants_decoded_opcode) instruction.decode(opcode_byte) else null;
            const gas_before = if (wants_end and sink.events.step_end.contains(.gas_cost)) self.call_frame.gas_left else 0;
            if (wants_start) self.call_frame.traceStepStart(pc, opcode_byte, decoded_opcode);
            self.call_frame.pc += 1;

            try executeOpcode(opcode_byte, self.call_frame);
            if (self.call_frame.pc >= self.call_frame.code.len and self.call_frame.status == .running) {
                self.call_frame.status = .success;
            }
            if (self.call_frame.pending_action != null) {
                if (wants_end) {
                    self.call_frame.pending_step_end = .{
                        .pc = pc,
                        .opcode_byte = opcode_byte,
                        .decoded_opcode = decoded_opcode,
                        .gas_before = gas_before,
                    };
                }
            } else if (wants_end) {
                self.call_frame.traceStepEnd(pc, opcode_byte, decoded_opcode, gas_before);
            }
        }
    };
}

fn invalidStatusError(err: anyerror) bool {
    return switch (err) {
        error.StackOverflow,
        error.StackUnderflow,
        error.StaticCallViolation,
        error.UnknownOpcode,
        error.UnsupportedInstruction,
        => true,
        else => false,
    };
}

const PendingStepEnd = struct {
    pc: usize,
    opcode_byte: u8,
    decoded_opcode: ?instruction.Instruction,
    gas_before: i64,
};

pub const CallFrame = struct {
    status: FrameStatus,
    allocator: std.mem.Allocator,
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
    jumpdests: JumpDestMap = .empty,
    bytecode: ?*Bytecode = null,
    trace_sink: ?*trace.Sink = null,
    revision_id: RevisionId = 0,
    pending_action: ?Action = null,
    pending_step_end: ?PendingStepEnd = null,

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
        const code = if (options.bytecode) |bytecode|
            bytecode.bytes
        else
            options.code;
        const io = options.io orelse return error.MissingFrameIoStorage;
        var jumpdests = JumpDestMap.empty;
        if (options.bytecode == null) {
            jumpdests = JumpDestMap.init();
            try jumpdests.analyze(allocator, code);
        }

        self.allocator = allocator;
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
        self.jumpdests = jumpdests;
        self.bytecode = options.bytecode;
        self.trace_sink = options.trace_sink;
        self.status = if (code.len == 0) .success else .running;
        self.revision_id = options.revision_id;
        self.pending_action = null;
        self.pending_step_end = null;
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
        self.jumpdests.deinit(self.allocator);
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
            self.finishPendingStepEndTrace();
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
        self.finishPendingStepEndTrace();
    }

    pub fn resumeCreateResult(self: *CallFrame, continuation: CreateResume, result: Host.CreateResult) !void {
        const child_gas_left = @max(result.gas_left, 0);
        self.trackGas(continuation.gas_limit - child_gas_left);
        self.gas_reservoir = result.gas_reservoir;
        self.state_gas_spent = std.math.add(i64, self.state_gas_spent, result.state_gas_spent) catch std.math.maxInt(i64);
        self.state_gas_from_gas_left = std.math.add(i64, self.state_gas_from_gas_left, result.state_gas_from_gas_left) catch std.math.maxInt(i64);
        self.refillStateGas(result.state_gas_refund);
        if (result.status != .success) {
            self.refillStateGas(continuation.state_gas_charged);
        }
        if (self.status != .running) {
            self.finishPendingStepEndTrace();
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
        self.finishPendingStepEndTrace();
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
        if (self.bytecode) |bytecode| {
            return try bytecode.isValidJumpDest(self.allocator, target);
        }
        return try self.jumpdests.isValid(self.allocator, self.code, target);
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

    fn wantsStepTracing(self: *const CallFrame) bool {
        const sink = self.trace_sink orelse return false;
        return sink.wantsSteps();
    }

    pub fn traceAccountAccess(self: *CallFrame, account_address: evmz.Address) void {
        const sink = self.trace_sink orelse return;
        if (!sink.wantsAccountAccess()) return;
        const fields = sink.events.account_access;
        sink.accountAccess(.{
            .depth = if (fields.contains(.depth)) self.msg.depth else 0,
            .address = if (fields.contains(.address)) account_address else std.mem.zeroes(evmz.Address),
        });
    }

    fn traceStepStart(self: *CallFrame, pc: usize, opcode_byte: u8, decoded_opcode: ?instruction.Instruction) void {
        const fields = self.trace_sink.?.events.step_start;
        self.trace_sink.?.stepStart(.{
            .pc = if (fields.contains(.pc)) pc else 0,
            .opcode = if (fields.contains(.opcode)) opcode_byte else 0,
            .decoded_opcode = if (fields.contains(.decoded_opcode)) decodedOpcode(decoded_opcode) else null,
            .depth = if (fields.contains(.depth)) self.msg.depth else 0,
            .gas_left = if (fields.contains(.gas_left)) self.gas_left else 0,
            .stack = if (fields.contains(.stack)) self.stack.asSlice() else &.{},
            .memory_size = if (fields.contains(.memory_size)) self.memory.len() else 0,
            .return_data_size = if (fields.contains(.return_data_size)) self.return_data.len else 0,
        });
    }

    fn traceStepEnd(self: *CallFrame, pc: usize, opcode_byte: u8, decoded_opcode: ?instruction.Instruction, gas_before: i64) void {
        const fields = self.trace_sink.?.events.step_end;
        self.trace_sink.?.stepEnd(.{
            .pc = if (fields.contains(.pc)) pc else 0,
            .pc_next = if (fields.contains(.pc_next)) self.pc else 0,
            .opcode = if (fields.contains(.opcode)) opcode_byte else 0,
            .decoded_opcode = if (fields.contains(.decoded_opcode)) decodedOpcode(decoded_opcode) else null,
            .depth = if (fields.contains(.depth)) self.msg.depth else 0,
            .status = if (fields.contains(.status)) traceStatus(self.status) else .running,
            .gas_left = if (fields.contains(.gas_left)) self.gas_left else 0,
            .gas_cost = if (fields.contains(.gas_cost)) gasCost(gas_before, self.gas_left) else 0,
            .stack = if (fields.contains(.stack)) self.stack.asSlice() else &.{},
            .memory_size = if (fields.contains(.memory_size)) self.memory.len() else 0,
            .return_data_size = if (fields.contains(.return_data_size)) self.return_data.len else 0,
        });
    }

    fn finishPendingStepEndTrace(self: *CallFrame) void {
        const pending = self.pending_step_end orelse return;
        self.pending_step_end = null;
        self.traceStepEnd(pending.pc, pending.opcode_byte, pending.decoded_opcode, pending.gas_before);
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
    var frame: CallFrame = undefined;
    try frame.init(std.testing.allocator, .{
        .host = &host,
        .msg = &msg,
        .code = &code,
        .revision_id = evmz.protocol.revisionId(evmz.eth.Revision.latest),
        .io = &io_storage,
    }, &msg_storage, &stack_storage, &memory_storage);
    defer frame.deinit();
    try std.testing.expect(frame.stack.slots == &stack_storage);

    var interpreter = For(evmz.Evm.Protocol).init(&frame);
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
    var frame: CallFrame = undefined;
    try frame.init(std.testing.allocator, .{
        .host = &host,
        .msg = &msg,
        .code = &code,
        .revision_id = evmz.protocol.revisionId(evmz.eth.Revision.latest),
        .io = &io_storage,
    }, &msg_storage, &stack_storage, &memory_storage);
    defer frame.deinit();
    try std.testing.expectEqual(@intFromPtr(&memory_storage), @intFromPtr(frame.memory.bytes));

    var interpreter = For(evmz.Evm.Protocol).init(&frame);
    const result = try interpreter.execute();

    try std.testing.expectEqual(Status.success, result.status);
    try std.testing.expectEqual(@as(usize, 32), memory_storage.items.len);
    try std.testing.expectEqual(@as(u8, 0x2a), memory_storage.items[31]);
}

fn decodedOpcode(decoded: ?instruction.Instruction) ?Opcode {
    return if (decoded) |item| item.opcode else null;
}

fn traceStatus(status: FrameStatus) trace.StepStatus {
    return switch (status) {
        .running, .suspended => .running,
        .success => .success,
        .invalid => .invalid,
        .revert => .revert,
        .out_of_gas => .out_of_gas,
    };
}

fn gasCost(before: i64, after: i64) i64 {
    return if (before > after) before - after else 0;
}

test "interpreter trace sink records step start and end" {
    const code = [_]u8{ @intFromEnum(Opcode.PUSH1), 0x2a, @intFromEnum(Opcode.STOP) };
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

    var recorder = TraceRecorder{};
    var sink = recorder.sink();
    var frame = try OwnedCallFrame(evmz.Evm.Protocol).init(std.testing.allocator, .{
        .host = &host,
        .msg = &msg,
        .code = &code,
        .revision = .latest,
        .trace_sink = &sink,
    });
    defer frame.deinit();
    var interpreter = frame.interpreter();

    const result = try interpreter.execute();

    try std.testing.expectEqual(Status.success, result.status);
    try std.testing.expectEqual(@as(u8, 2), recorder.starts);
    try std.testing.expectEqual(@as(u8, 2), recorder.ends);
    try std.testing.expectEqual(@as(usize, 0), recorder.first_start_pc);
    try std.testing.expectEqual(@as(u8, @intFromEnum(Opcode.PUSH1)), recorder.first_start_opcode);
    try std.testing.expectEqual(@as(?Opcode, .PUSH1), recorder.first_start_decoded);
    try std.testing.expectEqual(@as(u16, 7), recorder.first_start_depth);
    try std.testing.expectEqual(@as(i64, 100), recorder.first_start_gas_left);
    try std.testing.expectEqual(@as(usize, 0), recorder.first_start_stack_len);
    try std.testing.expectEqual(@as(usize, 2), recorder.first_end_pc_next);
    try std.testing.expectEqual(trace.StepStatus.running, recorder.first_end_status);
    try std.testing.expectEqual(@as(i64, 97), recorder.first_end_gas_left);
    try std.testing.expectEqual(@as(i64, 3), recorder.first_end_gas_cost);
    try std.testing.expectEqual(@as(usize, 1), recorder.first_end_stack_len);
    try std.testing.expectEqual(@as(u256, 0x2a), recorder.first_end_stack_top);
    try std.testing.expectEqual(@as(usize, 2), recorder.last_end_pc);
    try std.testing.expectEqual(@as(usize, 3), recorder.last_end_pc_next);
    try std.testing.expectEqual(trace.StepStatus.success, recorder.last_end_status);
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

test "interpreter trace schema controls step emission" {
    const code = [_]u8{@intFromEnum(Opcode.STOP)};
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

    var recorder = TraceRecorder{};
    var sink = recorder.sinkWithoutEvents();
    var frame = try OwnedCallFrame(evmz.Evm.Protocol).init(std.testing.allocator, .{
        .host = &host,
        .msg = &msg,
        .code = &code,
        .revision = .latest,
        .trace_sink = &sink,
    });
    defer frame.deinit();
    var interpreter = frame.interpreter();

    const result = try interpreter.execute();

    try std.testing.expectEqual(Status.success, result.status);
    try std.testing.expectEqual(@as(u8, 0), recorder.starts);
    try std.testing.expectEqual(@as(u8, 0), recorder.ends);
}

const TraceRecorder = struct {
    starts: u8 = 0,
    ends: u8 = 0,
    first_start_pc: usize = 0,
    first_start_opcode: u8 = 0,
    first_start_decoded: ?Opcode = null,
    first_start_depth: u16 = 0,
    first_start_gas_left: i64 = 0,
    first_start_stack_len: usize = 0,
    first_end_pc_next: usize = 0,
    first_end_status: trace.StepStatus = .running,
    first_end_gas_left: i64 = 0,
    first_end_gas_cost: i64 = 0,
    first_end_stack_len: usize = 0,
    first_end_stack_top: u256 = 0,
    last_end_pc: usize = 0,
    last_end_pc_next: usize = 0,
    last_end_status: trace.StepStatus = .running,

    fn sink(self: *TraceRecorder) trace.Sink {
        return trace.Sink.init(self, .{
            .step_start = trace.StepStartFields.initMany(&.{ .pc, .opcode, .decoded_opcode, .depth, .gas_left, .stack }),
            .step_end = trace.StepEndFields.initMany(&.{ .pc, .pc_next, .status, .gas_left, .gas_cost, .stack }),
        }, &.{
            .stepStart = stepStart,
            .stepEnd = stepEnd,
        });
    }

    fn sinkWithoutEvents(self: *TraceRecorder) trace.Sink {
        return trace.Sink.init(self, .{}, &.{
            .stepStart = stepStart,
            .stepEnd = stepEnd,
        });
    }

    fn stepStart(ptr: *anyopaque, event: trace.StepStart) void {
        const self: *TraceRecorder = @ptrCast(@alignCast(ptr));
        if (self.starts == 0) {
            self.first_start_pc = event.pc;
            self.first_start_opcode = event.opcode;
            self.first_start_decoded = event.decoded_opcode;
            self.first_start_depth = event.depth;
            self.first_start_gas_left = event.gas_left;
            self.first_start_stack_len = event.stack.len;
        }
        self.starts += 1;
    }

    fn stepEnd(ptr: *anyopaque, event: trace.StepEnd) void {
        const self: *TraceRecorder = @ptrCast(@alignCast(ptr));
        if (self.ends == 0) {
            self.first_end_pc_next = event.pc_next;
            self.first_end_status = event.status;
            self.first_end_gas_left = event.gas_left;
            self.first_end_gas_cost = event.gas_cost;
            self.first_end_stack_len = event.stack.len;
            self.first_end_stack_top = event.stack[event.stack.len - 1];
        }
        self.last_end_pc = event.pc;
        self.last_end_pc_next = event.pc_next;
        self.last_end_status = event.status;
        self.ends += 1;
    }
};

pub fn OwnedCallFrame(comptime ProtocolType: type) type {
    return struct {
        const Self = @This();

        pub const Protocol = ProtocolType;
        pub const Init = InitFor(Protocol);

        allocator: std.mem.Allocator,
        slot: *CallFrameSlot,
        frame: *CallFrame,

        pub fn init(allocator: std.mem.Allocator, options: Init) !Self {
            const slot = try allocator.create(CallFrameSlot);
            errdefer allocator.destroy(slot);
            try slot.initFor(Protocol, allocator, options);
            return .{
                .allocator = allocator,
                .slot = slot,
                .frame = &slot.frame,
            };
        }

        pub fn deinit(self: *Self) void {
            self.slot.deinit();
            self.allocator.destroy(self.slot);
            self.* = undefined;
        }

        pub fn interpreter(self: *Self) For(Protocol) {
            return For(Protocol).init(self.frame);
        }
    };
}

comptime {
    if (@sizeOf(usize) == 8) {
        assertLayout(@sizeOf(CallFrame) == 512, "CallFrame size changed; rerun VM-loop canary benches");
        assertLayout(@alignOf(CallFrame) == 16, "CallFrame alignment changed; rerun VM-loop canary benches");
        assertLayout(@offsetOf(CallFrame, "stack") == 288, "CallFrame stack view moved; rerun arithmetic VM-loop bench");
        assertLayout(@offsetOf(CallFrame, "memory") == 304, "CallFrame memory moved; rerun memory VM-loop bench");
        assertLayout(@offsetOf(CallFrame, "gas_left") == 352, "CallFrame gas_left moved; rerun VM-loop canary benches");
        assertLayout(@offsetOf(CallFrame, "msg") == 280, "CallFrame msg pointer moved; check message ownership layout");
        assertLayout(@sizeOf(CallFrameSlot) == 33600, "CallFrameSlot size changed; check pooled frame/message layout");
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

    var frame = try OwnedCallFrame(evmz.Evm.Protocol).init(std.testing.allocator, .{
        .host = &host,
        .msg = &msg,
        .bytecode = &bytecode,
        .revision = .latest,
    });
    defer frame.deinit();
    var interpreter = frame.interpreter();

    const result = try interpreter.execute();
    try std.testing.expectEqual(Status.success, result.status);
    try std.testing.expect(!interpreter.call_frame.jumpdests.analyzed);
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

    var frame = try OwnedCallFrame(evmz.Evm.Protocol).init(std.testing.allocator, .{
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

    var frame = try OwnedCallFrame(evmz.Evm.Protocol).init(std.testing.allocator, .{
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
