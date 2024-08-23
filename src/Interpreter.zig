const std = @import("std");
const Opcode = @import("./opcode.zig").Opcode;
const Stack = @import("./Stack.zig");
const Memory = @import("./Memory.zig");
const Host = @import("./Host.zig");
const evmz = @import("./evm.zig");
const instruction = @import("./instruction.zig");

const Address = evmz.Address;
const addr = evmz.addr;

const Bytes = evmz.Bytes;
const log = std.log;

const InterpreterError = Stack.Error | std.mem.Allocator.Error | instruction.Error;

pub const Status = enum(u8) { success, invalid, running, revert };

pub const Result = struct {
    status: Status,
    gas_left: u64,
    gas_refund: i64,
    output_data: []u8,
};

msg: *const Host.Message,
host: *Host,
allocator: std.mem.Allocator,
stack: Stack,
memory: Memory,
status: Status = .running,
bytes: Bytes = &.{},
pc: usize = 0,
return_data: []u8 = &.{},
gas_left: u64 = 0,
gas_refund: i64 = 0,

arena: std.heap.ArenaAllocator,
_tx_context: ?Host.TxContext = null,

const Self = @This();

pub fn init(
    allocaotr: std.mem.Allocator,
    host: *Host,
    msg: *const Host.Message,
    bytes: Bytes,
) Self {
    return .{
        .allocator = allocaotr,
        .stack = Stack.init(),
        .memory = Memory.init(allocaotr),
        .host = host,
        .msg = msg,
        .bytes = bytes,
        .arena = std.heap.ArenaAllocator.init(allocaotr),
        .status = if (bytes.len == 0) .success else .running,
    };
}

pub fn deinit(self: *Self) void {
    self.memory.deinit();
    self.allocator.free(self.return_data);
    self.* = undefined;
}

pub fn replaceReturnData(self: *Self, return_data: Bytes) !void {
    self.allocator.free(self.return_data);
    const buf = try self.allocator.alloc(u8, return_data.len);
    @memcpy(buf, return_data);
    self.return_data = buf;
}

pub fn getTxContext(self: *Self) !Host.TxContext {
    if (self._tx_context) |tx_context| {
        return tx_context;
    }

    return self.host.getTxContext();
}

pub fn getResult(self: *const Self) Result {
    return Result{
        .gas_left = self.gas_left,
        .gas_refund = self.gas_refund,
        .output_data = self.return_data,
        .status = self.status,
    };
}

pub fn execute(self: *Self) Result {
    while (self.status == .running) {
        self.step();
    }

    return self.getResult();
}

fn step(self: *Self) void {
    const opcode_byte = self.bytes[self.pc];
    self.pc += 1;
    const instr = instruction.InstructionTable[opcode_byte];
    instr.ptr(self) catch |err| {
        self.status = .invalid;
        log.err("Error: {any}\n", .{err});
    };
    if (self.pc >= self.bytes.len and self.status == Status.running) {
        self.status = .success;
    }
}
