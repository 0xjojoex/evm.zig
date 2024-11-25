const Opcode = @import("opcode.zig").Opcode;
const std = @import("std");
const evmz = @import("./evm.zig");
const interpreter = @import("./interpreter.zig");
const CallFrame = interpreter.CallFrame;

pub const call_value_cost = 9000;
pub const account_creation_cost = 25000;

// [EIP-2929](https://eips.ethereum.org/EIPS/eip-2929)
pub const cold_sload_cost = 2100;
const cold_account_access_cost = 2600;
pub const warm_storage_read_cost = 100;

// warm_storage_read_cost is count before instruction execution
pub const cold_account_access_gas = cold_account_access_cost - warm_storage_read_cost;
pub const cold_sload_gas = cold_sload_cost - warm_storage_read_cost;

pub const Error = error{
    UnknownOpcode,
};

pub const instruction_table = InstructionTable.init(instruction_entries);

const InstructionPtr = *const fn (ip: *CallFrame) anyerror!void;

const InstructionEntry = struct {
    Opcode,
    // the static gas cost required to execute this instruction
    // not using gas enum because it's not very readable
    u16,
    // StackHeight,
    // dynamic dispatching
    InstructionPtr,
};

const instruction_entries: []const InstructionEntry = &.{
    .{ .STOP, 0, Instructions.system.stop },
    .{ .ADD, 3, Instructions.arithmetic.add },
    .{ .MUL, 5, Instructions.arithmetic.mul },
    .{ .SUB, 3, Instructions.arithmetic.sub },
    .{ .DIV, 5, Instructions.arithmetic.div },
    .{ .SDIV, 5, Instructions.arithmetic.sdiv },
    .{ .MOD, 5, Instructions.arithmetic.mod },
    .{ .SMOD, 5, Instructions.arithmetic.smod },
    .{ .ADDMOD, 8, Instructions.arithmetic.addmod },
    .{ .MULMOD, 8, Instructions.arithmetic.mulmod },
    .{ .EXP, 10, Instructions.arithmetic.exp },
    .{ .SIGNEXTEND, 5, Instructions.arithmetic.signextend },
    .{ .LT, 3, Instructions.logic.lt },
    .{ .GT, 3, Instructions.logic.gt },
    .{ .SLT, 3, Instructions.logic.slt },
    .{ .SGT, 3, Instructions.logic.sgt },
    .{ .EQ, 3, Instructions.logic.eq },
    .{ .ISZERO, 3, Instructions.logic.iszero },
    .{ .AND, 3, Instructions.logic.bitAnd },
    .{ .OR, 3, Instructions.logic.bitOr },
    .{ .XOR, 3, Instructions.logic.bitXor },
    .{ .NOT, 3, Instructions.logic.bitNot },
    .{ .BYTE, 3, Instructions.logic.byte },
    .{ .SHL, 3, Instructions.logic.shl },
    .{ .SHR, 3, Instructions.logic.shr },
    .{ .SAR, 3, Instructions.logic.sar },
    .{ .KECCAK256, 30, Instructions.arithmetic.keccak256 },
    .{ .ADDRESS, 2, Instructions.environment.address },
    .{ .BALANCE, 100, Instructions.environment.balance },
    .{ .ORIGIN, 2, Instructions.environment.origin },
    .{ .CALLER, 2, Instructions.environment.caller },
    .{ .CALLVALUE, 2, Instructions.environment.callvalue },
    .{ .CALLDATALOAD, 3, Instructions.environment.calldataload },
    .{ .CALLDATASIZE, 2, Instructions.environment.calldatasize },
    .{ .CALLDATACOPY, 3, Instructions.environment.calldatacopy },
    .{ .CODESIZE, 2, Instructions.environment.codesize },
    .{ .CODECOPY, 3, Instructions.environment.codecopy },
    .{ .GASPRICE, 2, Instructions.environment.gasprice },
    .{ .EXTCODESIZE, 100, Instructions.environment.extcodesize },
    .{ .EXTCODECOPY, 100, Instructions.environment.extcodecopy },
    .{ .RETURNDATASIZE, 2, Instructions.environment.returndatasize },
    .{ .RETURNDATACOPY, 3, Instructions.environment.returndatacopy },
    .{ .EXTCODEHASH, 100, Instructions.environment.extcodehash },
    .{ .BLOCKHASH, 20, Instructions.environment.blockhash },
    .{ .COINBASE, 2, Instructions.environment.coinbase },
    .{ .TIMESTAMP, 2, Instructions.environment.timestamp },
    .{ .NUMBER, 2, Instructions.environment.number },
    .{ .PREVRANDAO, 2, Instructions.environment.prevrandao },
    .{ .GASLIMIT, 2, Instructions.environment.gaslimit },
    .{ .CHAINID, 2, Instructions.environment.chainid },
    .{ .SELFBALANCE, 5, Instructions.environment.selfbalance },
    .{ .BASEFEE, 2, Instructions.environment.basefee },
    .{ .BLOBHASH, 3, Instructions.environment.blobhash },
    .{ .BLOBBASEFEE, 3, Instructions.environment.blobbasefee },
    .{ .POP, 2, Instructions.stack.pop },
    .{ .MLOAD, 3, Instructions.memory.mload },
    .{ .MSTORE, 3, Instructions.memory.mstore },
    .{ .MSTORE8, 3, Instructions.memory.mstore8 },
    .{ .SLOAD, 100, Instructions.storage.sload },
    .{ .SSTORE, 100, Instructions.storage.sstore },
    .{ .JUMP, 8, Instructions.flow.jump },
    .{ .JUMPI, 10, Instructions.flow.jumpi },
    .{ .PC, 2, Instructions.flow.pc },
    .{ .MSIZE, 2, Instructions.memory.msize },
    .{ .GAS, 2, Instructions.environment.gas },
    .{ .JUMPDEST, 1, Instructions.noop },
    .{ .TLOAD, 100, Instructions.storage.tload },
    .{ .TSTORE, 100, Instructions.storage.tstore },
    .{ .MCOPY, 3, Instructions.memory.mcopy },
    .{ .PUSH0, 2, Instructions.stack.push0 },
    .{ .PUSH1, 3, Instructions.pushN(1) },
    .{ .PUSH2, 3, Instructions.pushN(2) },
    .{ .PUSH3, 3, Instructions.pushN(3) },
    .{ .PUSH4, 3, Instructions.pushN(4) },
    .{ .PUSH5, 3, Instructions.pushN(5) },
    .{ .PUSH6, 3, Instructions.pushN(6) },
    .{ .PUSH7, 3, Instructions.pushN(7) },
    .{ .PUSH8, 3, Instructions.pushN(8) },
    .{ .PUSH9, 3, Instructions.pushN(9) },
    .{ .PUSH10, 3, Instructions.pushN(10) },
    .{ .PUSH11, 3, Instructions.pushN(11) },
    .{ .PUSH12, 3, Instructions.pushN(12) },
    .{ .PUSH13, 3, Instructions.pushN(13) },
    .{ .PUSH14, 3, Instructions.pushN(14) },
    .{ .PUSH15, 3, Instructions.pushN(15) },
    .{ .PUSH16, 3, Instructions.pushN(16) },
    .{ .PUSH17, 3, Instructions.pushN(17) },
    .{ .PUSH18, 3, Instructions.pushN(18) },
    .{ .PUSH19, 3, Instructions.pushN(19) },
    .{ .PUSH20, 3, Instructions.pushN(20) },
    .{ .PUSH21, 3, Instructions.pushN(21) },
    .{ .PUSH22, 3, Instructions.pushN(22) },
    .{ .PUSH23, 3, Instructions.pushN(23) },
    .{ .PUSH24, 3, Instructions.pushN(24) },
    .{ .PUSH25, 3, Instructions.pushN(25) },
    .{ .PUSH26, 3, Instructions.pushN(26) },
    .{ .PUSH27, 3, Instructions.pushN(27) },
    .{ .PUSH28, 3, Instructions.pushN(28) },
    .{ .PUSH29, 3, Instructions.pushN(29) },
    .{ .PUSH30, 3, Instructions.pushN(30) },
    .{ .PUSH31, 3, Instructions.pushN(31) },
    .{ .PUSH32, 3, Instructions.pushN(32) },
    .{ .DUP1, 3, Instructions.dupN(1) },
    .{ .DUP2, 3, Instructions.dupN(2) },
    .{ .DUP3, 3, Instructions.dupN(3) },
    .{ .DUP4, 3, Instructions.dupN(4) },
    .{ .DUP5, 3, Instructions.dupN(5) },
    .{ .DUP6, 3, Instructions.dupN(6) },
    .{ .DUP7, 3, Instructions.dupN(7) },
    .{ .DUP8, 3, Instructions.dupN(8) },
    .{ .DUP9, 3, Instructions.dupN(9) },
    .{ .DUP10, 3, Instructions.dupN(10) },
    .{ .DUP11, 3, Instructions.dupN(11) },
    .{ .DUP12, 3, Instructions.dupN(12) },
    .{ .DUP13, 3, Instructions.dupN(13) },
    .{ .DUP14, 3, Instructions.dupN(14) },
    .{ .DUP15, 3, Instructions.dupN(15) },
    .{ .DUP16, 3, Instructions.dupN(16) },
    .{ .SWAP1, 3, Instructions.swapN(1) },
    .{ .SWAP2, 3, Instructions.swapN(2) },
    .{ .SWAP3, 3, Instructions.swapN(3) },
    .{ .SWAP4, 3, Instructions.swapN(4) },
    .{ .SWAP5, 3, Instructions.swapN(5) },
    .{ .SWAP6, 3, Instructions.swapN(6) },
    .{ .SWAP7, 3, Instructions.swapN(7) },
    .{ .SWAP8, 3, Instructions.swapN(8) },
    .{ .SWAP9, 3, Instructions.swapN(9) },
    .{ .SWAP10, 3, Instructions.swapN(10) },
    .{ .SWAP11, 3, Instructions.swapN(11) },
    .{ .SWAP12, 3, Instructions.swapN(12) },
    .{ .SWAP13, 3, Instructions.swapN(13) },
    .{ .SWAP14, 3, Instructions.swapN(14) },
    .{ .SWAP15, 3, Instructions.swapN(15) },
    .{ .SWAP16, 3, Instructions.swapN(16) },
    .{ .LOG0, 375, Instructions.logN(0) },
    .{ .LOG1, 375 * 2, Instructions.logN(1) },
    .{ .LOG2, 375 * 3, Instructions.logN(2) },
    .{ .LOG3, 375 * 4, Instructions.logN(3) },
    .{ .LOG4, 375 * 5, Instructions.logN(4) },
    .{ .CREATE, 32000, Instructions.system.create },
    .{ .CALL, 100, Instructions.call(.CALL) },
    .{ .CALLCODE, 100, Instructions.call(.CALLCODE) },
    .{ .RETURN, 0, Instructions.system.ret },
    .{ .DELEGATECALL, 100, Instructions.call(.DELEGATECALL) },
    .{ .CREATE2, 32000, Instructions.system.create2 },
    .{ .STATICCALL, 100, Instructions.call(.STATICCALL) },
    .{ .REVERT, 0, Instructions.system.revert },
    .{ .INVALID, 0, Instructions.system.invalid },
    .{ .SELFDESTRUCT, 5000, Instructions.system.selfdestruct },
};

pub const Instruction = struct {
    opcode: Opcode,
    static_gas: u16,
    ptr: InstructionPtr,
};

const InstructionTable = struct {
    ops: [256]Instruction,

    pub fn init(entries: []const InstructionEntry) InstructionTable {
        var table: [256]Instruction = undefined;
        for (0..256) |i| {
            table[i] = Instruction{
                .opcode = Opcode.REVERT,
                .static_gas = 0,
                .ptr = Instructions.unknown,
            };
        }

        if (@typeInfo(Opcode).Enum.fields.len != entries.len) {
            @compileError("Opcode enum and instruction_entries have different lengths");
        }

        for (entries) |entry| {
            const opcode, const gas, const ptr = entry;
            table[@intFromEnum(opcode)] = Instruction{
                .opcode = opcode,
                .static_gas = gas,
                .ptr = ptr,
            };
        }

        return InstructionTable{ .ops = table };
    }
};

test InstructionTable {
    try std.testing.expectEqual(instruction_table.ops[0x00].static_gas, 0);
    try std.testing.expectEqual(instruction_table.ops[0x60].static_gas, 3);
}

const Instructions = struct {
    pub const arithmetic = @import("./instruction/arithmetic.zig");
    pub const environment = @import("./instruction/environment.zig");
    pub const flow = @import("./instruction/flow.zig");
    pub const logging = @import("./instruction/logging.zig");
    pub const stack = @import("./instruction/stack.zig");
    pub const storage = @import("./instruction/storage.zig");
    pub const system = @import("./instruction/system.zig");
    pub const memory = @import("./instruction/memory.zig");
    pub const logic = @import("./instruction/logic.zig");

    fn unknown(_: *CallFrame) anyerror!void {
        return error.UnknownOpcode;
    }

    fn noop(_: *CallFrame) anyerror!void {
        return;
    }

    fn todo(_: *CallFrame) anyerror!void {
        return std.debug.panic("TODO", .{});
    }

    inline fn pushN(comptime n: u8) InstructionPtr {
        return struct {
            pub fn call(frame: *CallFrame) anyerror!void {
                return stack.push(frame, n);
            }
        }.call;
    }

    inline fn dupN(comptime n: u8) InstructionPtr {
        return struct {
            pub fn call(frame: *CallFrame) anyerror!void {
                return stack.dup(frame, n);
            }
        }.call;
    }

    inline fn swapN(comptime n: u8) InstructionPtr {
        return struct {
            pub fn call(frame: *CallFrame) anyerror!void {
                return stack.swap(frame, n);
            }
        }.call;
    }

    inline fn logN(comptime n: u8) InstructionPtr {
        return struct {
            pub fn call(frame: *CallFrame) anyerror!void {
                return logging.log(frame, n);
            }
        }.call;
    }

    inline fn call(comptime op: Opcode) InstructionPtr {
        return struct {
            pub fn call(frame: *CallFrame) anyerror!void {
                return system.callByOp(frame, op);
            }
        }.call;
    }
};
