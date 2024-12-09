const std = @import("std");
const Opcode = @import("./opcode.zig").Opcode;
const Stack = @import("./Stack.zig");
const Memory = @import("./Memory.zig");
const Host = @import("./Host.zig");
const evmz = @import("./evm.zig");
const instruction = @import("./instruction.zig");

const Address = evmz.Address;
const addr = evmz.addr;
const log = std.log.scoped(.interpreter);

const Error = error{} | Stack.Error | std.mem.Allocator.Error | instruction.Error;

pub const Status = enum(u8) { success, invalid, running, revert, out_of_gas };

pub const Result = struct {
    status: Status,
    gas_left: i64,
    gas_refund: i64,
    output_data: []u8,
};

call_frame: CallFrame,

const Interpreter = @This();

pub fn init(
    allocator: std.mem.Allocator,
    host: *Host,
    msg: *const Host.Message,
    bytes: []const u8,
    spec: evmz.Spec,
) Interpreter {
    const callframe = CallFrame.init(allocator, host, msg, bytes, spec);

    return .{
        .call_frame = callframe,
    };
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
    const opcode_byte = self.call_frame.bytes[self.call_frame.pc];
    self.call_frame.pc += 1;
    const instr = instruction.instruction_table.ops[opcode_byte];

    self.call_frame.trackGas(instr.static_gas);

    if (self.call_frame.status != .running) {
        return;
    }

    instr.ptr(&self.call_frame) catch |err| {
        if (self.call_frame.status == .running) {
            self.call_frame.status = .invalid;
            log.debug("Error: {any}\n", .{err});
        }
    };
    if (self.call_frame.pc >= self.call_frame.bytes.len and self.call_frame.status == .running) {
        self.call_frame.status = .success;
    }
}

pub const CallFrame = struct {
    status: Status,
    allocator: std.mem.Allocator,
    host: *Host,
    msg: *const Host.Message,
    stack: Stack,
    memory: Memory,
    pc: usize = 0,
    bytes: []const u8 = &.{},
    gas_left: i64 = 0,
    gas_refund: i64 = 0,
    return_data: []u8 = &.{},
    spec: evmz.Spec = evmz.Spec.latest,
    _tx_context: ?Host.TxContext = null,

    pub fn init(
        allocator: std.mem.Allocator,
        host: *Host,
        msg: *const Host.Message,
        bytes: []const u8,
        spec: evmz.Spec,
    ) CallFrame {
        return .{
            .allocator = allocator,
            .stack = Stack.init(),
            .memory = Memory.init(allocator),
            .host = host,
            .msg = msg,
            .bytes = bytes,
            .gas_left = msg.gas,
            .status = if (bytes.len == 0) .success else .running,
            .spec = spec,
        };
    }

    pub fn deinit(self: *CallFrame) void {
        self.memory.deinit();
        self.allocator.free(self.return_data);
        self.* = undefined;
    }

    pub fn replaceReturnData(self: *CallFrame, return_data: []const u8) !void {
        self.allocator.free(self.return_data);
        const buf = try self.allocator.alloc(u8, return_data.len);
        @memcpy(buf, return_data);
        self.return_data = buf;
    }

    pub fn trackGas(self: *CallFrame, gas: i64) void {
        self.gas_left -= gas;
        if (self.gas_left < 0) {
            self.status = .out_of_gas;
            log.debug("OOG: {any}\n", .{self});
        }
    }

    pub fn getTxContext(self: *CallFrame) !Host.TxContext {
        if (self._tx_context) |tx_context| {
            return tx_context;
        }

        const tx_context = try self.host.getTxContext();
        self._tx_context = tx_context;

        return self._tx_context orelse error.MissingTxContext;
    }

    pub fn getResult(self: *const CallFrame) Result {
        return Result{
            .gas_left = self.gas_left,
            .gas_refund = self.gas_refund,
            .output_data = self.return_data,
            .status = self.status,
        };
    }
};
