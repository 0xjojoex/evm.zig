const std = @import("std");
const Memory = @import("./Memory.zig");
const Config = @import("./Config.zig");
const Host = @import("./Host.zig");
const Bytecode = @import("./code/Bytecode.zig");
const CodeAnalysisState = @import("./code/State.zig");
const evmz = @import("./evm.zig");
const instruction = @import("./instruction.zig");
const Stack = @import("./Stack.zig");
const trace = @import("./trace.zig");
const Opcode = @import("./opcode.zig").Opcode;

const Error = error{} | Stack.Error | std.mem.Allocator.Error | instruction.Error;

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
    output_data: []u8,
};

pub const CallResume = struct {
    gas_limit: i64,
    out_offset: usize,
    out_size: usize,
};

pub const CreateResume = struct {
    gas_limit: i64,
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

call_frame: *CallFrame,

const Interpreter = @This();

pub const Init = struct {
    host: *Host,
    msg: *const Host.Message,
    code: []const u8 = &.{},
    bytecode: ?*Bytecode = null,
    spec: evmz.Spec,
    config: Config = .base,
    trace_sink: ?*trace.Sink = null,
};

pub fn init(call_frame: *CallFrame) Interpreter {
    return .{ .call_frame = call_frame };
}

pub fn execute(self: *Interpreter) Result {
    while (true) {
        switch (self.executeUntilAction()) {
            .finished => |result| return result,
            .action => |action| self.resolveHostAction(action),
        }
    }
}

pub fn executeUntilAction(self: *Interpreter) RunResult {
    if (self.call_frame.wantsStepTracing()) {
        while (self.call_frame.status == .running) {
            self.stepTraced();
        }
    } else {
        var frame = self.call_frame;
        while (frame.status == .running and frame.pc < frame.code.len) {
            const opcode_byte = frame.code[frame.pc];
            frame.pc += 1;

            instruction.execute(opcode_byte, frame) catch {
                if (frame.status == .running) {
                    frame.failWithStatus(.invalid);
                }
            };
        }

        if (frame.status == .running) {
            frame.status = .success;
        }
    }

    if (self.call_frame.takePendingAction()) |action| {
        return .{ .action = action };
    }
    return .{ .finished = self.call_frame.getResult() };
}

fn resolveHostAction(self: *Interpreter, action: Action) void {
    switch (action) {
        .call => |call_action| {
            const result = (self.call_frame.host.call(call_action.msg) catch {
                if (self.call_frame.status == .running) self.call_frame.failWithStatus(.invalid);
                return;
            }).expectCall();
            self.call_frame.resumeCallResult(call_action.continuation, result) catch {
                if (self.call_frame.status == .running) self.call_frame.failWithStatus(.invalid);
            };
        },
        .create => |create_action| {
            const result = (self.call_frame.host.call(create_action.msg) catch {
                if (self.call_frame.status == .running) self.call_frame.failWithStatus(.invalid);
                return;
            }).expectCreate();
            self.call_frame.resumeCreateResult(create_action.continuation, result) catch {
                if (self.call_frame.status == .running) self.call_frame.failWithStatus(.invalid);
            };
        },
    }
}

const PendingStepEnd = struct {
    pc: usize,
    opcode_byte: u8,
    decoded_opcode: ?instruction.Instruction,
    gas_before: i64,
};

fn stepTraced(self: *Interpreter) void {
    if (self.call_frame.pc >= self.call_frame.code.len) {
        self.call_frame.status = .success;
        return;
    }

    const pc = self.call_frame.pc;
    const opcode_byte = self.call_frame.code[pc];
    const sink = self.call_frame.trace_sink.?;
    const wants_start = sink.wantsStepStart();
    const wants_end = sink.wantsStepEnd();
    const decoded_opcode = if (sink.wantsDecodedOpcode()) instruction.decode(opcode_byte) else null;
    const gas_before = if (wants_end and sink.events.step_end.gas_cost) self.call_frame.gas_left else 0;
    if (wants_start) self.call_frame.traceStepStart(pc, opcode_byte, decoded_opcode);
    self.call_frame.pc += 1;

    instruction.execute(opcode_byte, self.call_frame) catch {
        if (self.call_frame.status == .running) {
            self.call_frame.failWithStatus(.invalid);
        }
    };
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

pub const CallFrame = struct {
    status: FrameStatus,
    allocator: std.mem.Allocator,
    host: *Host,
    msg: Host.Message,
    stack: Stack,
    memory: Memory,
    pc: usize = 0,
    code: []const u8 = &.{},
    gas_left: i64 = 0,
    gas_refund: i64 = 0,
    return_data: []u8 = &.{},
    output_data: []u8 = &.{},
    analysis: CodeAnalysisState = .empty,
    bytecode: ?*Bytecode = null,
    config: Config = .base,
    trace_sink: ?*trace.Sink = null,
    spec: evmz.Spec = evmz.Spec.latest,
    pending_action: ?Action = null,
    pending_step_end: ?PendingStepEnd = null,

    pub fn init(
        self: *CallFrame,
        allocator: std.mem.Allocator,
        options: Init,
    ) !void {
        const code = if (options.bytecode) |bytecode|
            bytecode.bytes
        else
            options.code;
        const analysis = if (options.bytecode == null)
            try CodeAnalysisState.init(code, options.config)
        else
            CodeAnalysisState.empty;

        self.allocator = allocator;
        self.host = options.host;
        self.msg = options.msg.*;
        self.stack = undefined;
        self.stack.len = 0;
        self.memory = Memory.init(allocator);
        self.pc = 0;
        self.code = code;
        self.gas_left = options.msg.gas;
        self.gas_refund = 0;
        self.return_data = &.{};
        self.output_data = &.{};
        self.analysis = analysis;
        self.bytecode = options.bytecode;
        self.config = options.config;
        self.trace_sink = options.trace_sink;
        self.status = if (code.len == 0) .success else .running;
        self.spec = options.spec;
        self.pending_action = null;
        self.pending_step_end = null;
    }

    pub fn deinit(self: *CallFrame) void {
        self.memory.deinit();
        self.allocator.free(self.return_data);
        self.allocator.free(self.output_data);
        self.analysis.deinit(self.allocator);
        self.* = undefined;
    }

    fn replaceOwnedBytes(self: *CallFrame, target: *[]u8, bytes: []const u8) !void {
        self.allocator.free(target.*);
        const buf = try self.allocator.alloc(u8, bytes.len);
        @memcpy(buf, bytes);
        target.* = buf;
    }

    pub fn replaceReturnData(self: *CallFrame, return_data: []const u8) !void {
        try self.replaceOwnedBytes(&self.return_data, return_data);
    }

    pub fn replaceOutputData(self: *CallFrame, output_data: []const u8) !void {
        try self.replaceOwnedBytes(&self.output_data, output_data);
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
        return try self.analysis.isValidJumpDest(self.allocator, self.code, target);
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
        try self.memory.expandPrepared(expansion);
        return true;
    }

    pub fn getResult(self: *const CallFrame) Result {
        return Result{
            .gas_left = self.gas_left,
            // EIP-2200: a frame-local refund counter is discarded on revert.
            .gas_refund = if (self.status == .success) self.gas_refund else 0,
            .output_data = self.output_data,
            .status = self.status.toResult(),
        };
    }

    fn wantsStepTracing(self: *const CallFrame) bool {
        const sink = self.trace_sink orelse return false;
        return sink.wantsSteps();
    }

    fn traceStepStart(self: *CallFrame, pc: usize, opcode_byte: u8, decoded_opcode: ?instruction.Instruction) void {
        const fields = self.trace_sink.?.events.step_start;
        self.trace_sink.?.stepStart(.{
            .pc = if (fields.pc) pc else 0,
            .opcode = if (fields.opcode) opcode_byte else 0,
            .decoded_opcode = if (fields.decoded_opcode) decodedOpcode(decoded_opcode) else null,
            .depth = if (fields.depth) self.msg.depth else 0,
            .gas_left = if (fields.gas_left) self.gas_left else 0,
            .stack = if (fields.stack) self.stack.asSlice() else &.{},
            .memory_size = if (fields.memory_size) self.memory.len() else 0,
            .return_data_size = if (fields.return_data_size) self.return_data.len else 0,
        });
    }

    fn traceStepEnd(self: *CallFrame, pc: usize, opcode_byte: u8, decoded_opcode: ?instruction.Instruction, gas_before: i64) void {
        const fields = self.trace_sink.?.events.step_end;
        self.trace_sink.?.stepEnd(.{
            .pc = if (fields.pc) pc else 0,
            .pc_next = if (fields.pc_next) self.pc else 0,
            .opcode = if (fields.opcode) opcode_byte else 0,
            .decoded_opcode = if (fields.decoded_opcode) decodedOpcode(decoded_opcode) else null,
            .depth = if (fields.depth) self.msg.depth else 0,
            .status = if (fields.status) traceStatus(self.status) else .running,
            .gas_left = if (fields.gas_left) self.gas_left else 0,
            .gas_cost = if (fields.gas_cost) gasCost(gas_before, self.gas_left) else 0,
            .stack = if (fields.stack) self.stack.asSlice() else &.{},
            .memory_size = if (fields.memory_size) self.memory.len() else 0,
            .return_data_size = if (fields.return_data_size) self.return_data.len else 0,
        });
    }

    fn finishPendingStepEndTrace(self: *CallFrame) void {
        const pending = self.pending_step_end orelse return;
        self.pending_step_end = null;
        self.traceStepEnd(pending.pc, pending.opcode_byte, pending.decoded_opcode, pending.gas_before);
    }
};

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
    var frame = try OwnedCallFrame.init(std.testing.allocator, .{
        .host = &host,
        .msg = &msg,
        .code = &code,
        .spec = .latest,
        .trace_sink = &sink,
    });
    defer frame.deinit();
    var interpreter = frame.interpreter();

    const result = interpreter.execute();

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
    var frame = try OwnedCallFrame.init(std.testing.allocator, .{
        .host = &host,
        .msg = &msg,
        .code = &code,
        .spec = .latest,
        .trace_sink = &sink,
    });
    defer frame.deinit();
    var interpreter = frame.interpreter();

    const result = interpreter.execute();

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
        return .{ .ptr = self, .events = .{
            .step_start = .{
                .pc = true,
                .opcode = true,
                .decoded_opcode = true,
                .depth = true,
                .gas_left = true,
                .stack = true,
            },
            .step_end = .{
                .pc = true,
                .pc_next = true,
                .status = true,
                .gas_left = true,
                .gas_cost = true,
                .stack = true,
            },
        }, .vtable = &.{
            .stepStart = stepStart,
            .stepEnd = stepEnd,
        } };
    }

    fn sinkWithoutEvents(self: *TraceRecorder) trace.Sink {
        return .{ .ptr = self, .vtable = &.{
            .stepStart = stepStart,
            .stepEnd = stepEnd,
        } };
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

pub const OwnedCallFrame = struct {
    allocator: std.mem.Allocator,
    frame: *CallFrame,

    pub fn init(allocator: std.mem.Allocator, options: Init) !OwnedCallFrame {
        const frame = try allocator.create(CallFrame);
        errdefer allocator.destroy(frame);
        try frame.init(allocator, options);
        return .{
            .allocator = allocator,
            .frame = frame,
        };
    }

    pub fn deinit(self: *OwnedCallFrame) void {
        self.frame.deinit();
        self.allocator.destroy(self.frame);
        self.* = undefined;
    }

    pub fn interpreter(self: *OwnedCallFrame) Interpreter {
        return Interpreter.init(self.frame);
    }
};

test "interpreter can execute prepared bytecode jumpdest map" {
    const t = @import("./t.zig");
    const raw = t.bytecode(.{ .PUSH1, 0x04, .JUMP, .STOP, .JUMPDEST });
    var bytecode = try Bytecode.init(std.testing.allocator, &raw, .jumpdest);
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

    var frame = try OwnedCallFrame.init(std.testing.allocator, .{
        .host = &host,
        .msg = &msg,
        .bytecode = &bytecode,
        .spec = .latest,
    });
    defer frame.deinit();
    var interpreter = frame.interpreter();

    const result = interpreter.execute();
    try std.testing.expectEqual(Status.success, result.status);
    try std.testing.expect(!interpreter.call_frame.analysis.isAnalyzed());
    try std.testing.expect(bytecode.jumpdests.analyzed);
}
