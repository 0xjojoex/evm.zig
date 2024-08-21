const std = @import("std");
const Opcode = @import("./opcode.zig").Opcode;
const Stack = @import("./Stack.zig");
const Memory = @import("./Memory.zig");
const Host = @import("./Host.zig");
const alias = @import("./alias.zig");
const instruction = @import("./instruction.zig");

const Address = alias.Address;
const Bytes = alias.Bytes;
const log = std.log;

const InterpreterError = Stack.Error | std.mem.Allocator.Error;

pub const Status = enum(u8) { success, invalid, running, revert };

host: Host,
allocator: std.mem.Allocator,
stack: Stack,
memory: Memory,
status: Status = .running,
bytes: Bytes,
pc: usize = 0,
return_data: []u8 = &.{},
is_static: bool = false,

const Self = @This();

pub fn init(
    allocaotr: std.mem.Allocator,
    bytes: Bytes,
    host: Host,
) Self {
    return .{
        .allocator = allocaotr,
        .stack = Stack.init(),
        .memory = Memory.init(allocaotr),
        .bytes = bytes,
        .status = Status.running,
        .host = host,
    };
}

pub fn deinit(self: *Self) void {
    self.memory.deinit();
    self.allocator.free(self.return_data.ptr[0..self.return_data.len]);
    self.* = undefined;
}

pub fn handle(self: *Self) void {
    while (self.status == Status.running) {
        if (self.bytes.len == 0) {
            self.status = .success;
            return;
        }
        const next_bytes = self.bytes[self.pc];
        step(self, next_bytes) catch |err| {
            self.status = .invalid;
            log.err("Error: {any}\n", .{err});
        };

        if (self.pc >= self.bytes.len and self.status == Status.running) {
            self.status = Status.success;
        }
    }
}

fn step(self: *Self, opcode_byte: u8) !void {
    self.pc += 1;
    const instr = instruction.InstructionTable[opcode_byte];
    try instr.ptr(self);

    // switch (opcode) {
    //     .PUSH0 => try instruction.push0(self),
    //     // until switch range for enum support...
    //     // https://github.com/ziglang/zig/issues/15556
    //     inline .PUSH1, .PUSH2, .PUSH3, .PUSH4, .PUSH5, .PUSH6, .PUSH7, .PUSH8, .PUSH9, .PUSH10, .PUSH11, .PUSH12, .PUSH13, .PUSH14, .PUSH15, .PUSH16, .PUSH17, .PUSH18, .PUSH19, .PUSH20, .PUSH21, .PUSH22, .PUSH23, .PUSH24, .PUSH25, .PUSH26, .PUSH27, .PUSH28, .PUSH29, .PUSH30, .PUSH31, .PUSH32 => |op| try {
    //         return instruction.pushN(self, op.toInt() - Opcode.PUSH1.toInt() + 1);
    //     },
    //     .POP => try instruction.pop(self),
    //     .ADD => try instruction.add(self),
    //     .MUL => try instruction.mul(self),
    //     .SUB => try instruction.sub(self),
    //     .DIV => try instruction.div(self),
    //     .MOD => try instruction.mod(self),
    //     .ADDMOD => try instruction.addmod(self),
    //     .MULMOD => try instruction.mulmod(self),
    //     .EXP => try instruction.exp(self),
    //     .SIGNEXTEND => try instruction.signextend(self),
    //     .SDIV => try instruction.sdiv(self),
    //     .SMOD => try instruction.smod(self),
    //     .LT => try instruction.lt(self),
    //     .GT => try instruction.gt(self),
    //     .SLT => try instruction.slt(self),
    //     .SGT => try instruction.sgt(self),
    //     .EQ => try instruction.eq(self),
    //     .ISZERO => try instruction.isZero(self),
    //     .AND => try instruction.bitAnd(self),
    //     .OR => try instruction.bitOr(self),
    //     .XOR => try instruction.bitXor(self),
    //     .NOT => try instruction.bitNot(self),
    //     .BYTE => try instruction.byte(self),
    //     .SHL => try instruction.shl(self),
    //     .SHR => try instruction.shr(self),
    //     .SAR => try instruction.sar(self),
    //     inline .DUP1, .DUP2, .DUP3, .DUP4, .DUP5, .DUP6, .DUP7, .DUP8, .DUP9, .DUP10, .DUP11, .DUP12, .DUP13, .DUP14, .DUP15, .DUP16 => |op| try {
    //         return instruction.dup(self, op.toInt() - Opcode.DUP1.toInt() + 1);
    //     },
    //     inline .SWAP1, .SWAP2, .SWAP3, .SWAP4, .SWAP5, .SWAP6, .SWAP7, .SWAP8, .SWAP9, .SWAP10, .SWAP11, .SWAP12, .SWAP13, .SWAP14, .SWAP15, .SWAP16 => |op| try {
    //         return instruction.swap(self, op.toInt() - Opcode.SWAP1.toInt() + 1);
    //     },
    //     .INVALID => self.status = .invalid,
    //     .PC => try instruction.pc(self),
    //     .GAS => try instruction.gas(self),
    //     .JUMP => try instruction.jump(self),
    //     .JUMPI => try instruction.jumpi(self),
    //     .JUMPDEST => {},
    //     .MSTORE => try instruction.mstore(self),
    //     .MSTORE8 => try instruction.mstore8(self),
    //     .MLOAD => try instruction.mload(self),
    //     .MSIZE => try instruction.msize(self),
    //     .KECCAK256 => try instruction.keccak256(self),
    //     .ADDRESS => try instruction.address(self),
    //     .CALLER => try instruction.caller(self),
    //     .ORIGIN => try instruction.origin(self),
    //     .GASPRICE => try instruction.gasprice(self),
    //     .BASEFEE => try instruction.basefee(self),
    //     .COINBASE => try instruction.coinbase(self),
    //     .TIMESTAMP => try instruction.timestamp(self),
    //     .NUMBER => try instruction.number(self),
    //     .PREVRANDAO => try instruction.prevrandao(self),
    //     .GASLIMIT => try instruction.gaslimit(self),
    //     .CHAINID => try instruction.chainid(self),
    //     .BLOCKHASH => try instruction.blockhash(self),
    //     .BALANCE => try instruction.balance(self),
    //     .CALLVALUE => try instruction.callvalue(self),
    //     .CALLDATALOAD => try instruction.calldataload(self),
    //     .CALLDATASIZE => try instruction.calldatasize(self),
    //     .CALLDATACOPY => try instruction.calldatacopy(self),
    //     .CODESIZE => try instruction.codesize(self),
    //     .CODECOPY => try instruction.codecopy(self),
    //     .EXTCODESIZE => try instruction.extcodesize(self),
    //     .EXTCODECOPY => try instruction.extcodecopy(self),
    //     .EXTCODEHASH => try instruction.extcodehash(self),
    //     .SELFBALANCE => try instruction.selfbalance(self),
    //     .SSTORE => try instruction.sstore(self),
    //     .SLOAD => try instruction.sload(self),
    //     .LOG0 => try instruction.createLogN(0)(self),
    //     .LOG1 => try instruction.createLogN(1)(self),
    //     .LOG2 => try instruction.createLogN(2)(self),
    //     .LOG3 => try instruction.createLogN(3)(self),
    //     .LOG4 => try instruction.createLogN(4)(self),
    //     .RETURN => try instruction.ret(self),
    //     .REVERT => try instruction.revert(self),
    //     .CALL => try instruction.call(self),
    //     .RETURNDATASIZE => try instruction.returndatasize(self),
    //     .RETURNDATACOPY => try instruction.returndatacopy(self),
    //     .DELEGATECALL => try instruction.delegatecall(self),
    //     .STATICCALL => try instruction.staticcall(self),
    //     .CREATE => try instruction.create(self),
    //     .SELFDESTRUCT => try instruction.selfdestruct(self),
    //     .STOP => self.status = .success,
    //     inline else => {
    //         std.debug.print("Opcode not implemented: {s}\n", .{@tagName(opcode)});
    //         self.status = .invalid;
    //     },
    // }
}
