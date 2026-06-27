const std = @import("std");
const Memory = @import("./Memory.zig");
const Config = @import("./Config.zig");
const Host = @import("./Host.zig");
const CodeAnalysisState = @import("./code/State.zig");
const evmz = @import("./evm.zig");
const instruction = @import("./instruction.zig");
const Stack = @import("./Stack.zig");

const Error = error{} | Stack.Error | std.mem.Allocator.Error | instruction.Error;

pub const Status = enum(u8) { success, invalid, revert, out_of_gas };

pub const FrameStatus = enum(u8) {
    running,
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
            .running => unreachable,
        };
    }
};

pub const Result = struct {
    status: Status,
    gas_left: i64,
    gas_refund: i64,
    output_data: []u8,
};

call_frame: CallFrame,

const Interpreter = @This();

pub const Init = struct {
    host: *Host,
    msg: *const Host.Message,
    code: []const u8,
    spec: evmz.Spec,
    config: Config = .base,
};

pub fn init(
    self: *Interpreter,
    allocator: std.mem.Allocator,
    options: Init,
) !void {
    try self.call_frame.init(allocator, options);
}

pub fn deinit(self: *Interpreter) void {
    self.call_frame.deinit();
}

pub fn execute(self: *Interpreter) Result {
    while (self.call_frame.status == .running) {
        self.step();
    }

    return self.call_frame.getResult();
}

fn step(self: *Interpreter) void {
    if (self.call_frame.pc >= self.call_frame.code.len) {
        self.call_frame.status = .success;
        return;
    }

    const opcode_byte = self.call_frame.code[self.call_frame.pc];
    self.call_frame.pc += 1;

    instruction.execute(opcode_byte, &self.call_frame) catch {
        if (self.call_frame.status == .running) {
            self.call_frame.failWithStatus(.invalid);
        }
    };
    if (self.call_frame.pc >= self.call_frame.code.len and self.call_frame.status == .running) {
        self.call_frame.status = .success;
    }
}

pub const CallFrame = struct {
    status: FrameStatus,
    allocator: std.mem.Allocator,
    host: *Host,
    msg: *const Host.Message,
    stack: Stack,
    memory: Memory,
    pc: usize = 0,
    code: []const u8 = &.{},
    gas_left: i64 = 0,
    gas_refund: i64 = 0,
    return_data: []u8 = &.{},
    output_data: []u8 = &.{},
    analysis: CodeAnalysisState = .empty,
    config: Config = .base,
    spec: evmz.Spec = evmz.Spec.latest,

    pub fn init(
        self: *CallFrame,
        allocator: std.mem.Allocator,
        options: Init,
    ) !void {
        const analysis = try CodeAnalysisState.init(options.code, options.config);

        self.allocator = allocator;
        self.host = options.host;
        self.msg = options.msg;
        self.stack = undefined;
        self.stack.len = 0;
        self.memory = Memory.init(allocator);
        self.pc = 0;
        self.code = options.code;
        self.gas_left = options.msg.gas;
        self.gas_refund = 0;
        self.return_data = &.{};
        self.output_data = &.{};
        self.analysis = analysis;
        self.config = options.config;
        self.status = if (options.code.len == 0) .success else .running;
        self.spec = options.spec;
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
            .gas_refund = self.gas_refund,
            .output_data = self.output_data,
            .status = self.status.toResult(),
        };
    }
};
