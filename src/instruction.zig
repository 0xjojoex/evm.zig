const Opcode = @import("opcode.zig").Opcode;
const std = @import("std");
const Interpreter = @import("./Interpreter.zig");

const InstructionPtr = *const fn (ip: *Interpreter) anyerror!void;

// const Gas = struct { u16 };
const StackHeight = struct {
    // stack height required
    u8,
    // stack height change
    i8,
};

const InstructionEntry = struct {
    Opcode,
    // the static gas cost required to execute this instruction
    // not using gas enum because it's not very readable
    u16,
    // StackHeight,
    /// dynamic dispatching, TODO: can it be inline fn?
    InstructionPtr,
};

const instruction_entries: []const InstructionEntry = &.{
    .{ .STOP, 0, instruction.stop },
    .{ .ADD, 3, instruction.add },
    .{ .MUL, 5, instruction.mul },
    .{ .SUB, 3, instruction.sub },
    .{ .DIV, 5, instruction.div },
    .{ .SDIV, 5, instruction.sdiv },
    .{ .MOD, 5, instruction.mod },
    .{ .SMOD, 5, instruction.smod },
    .{ .ADDMOD, 8, instruction.addmod },
    .{ .MULMOD, 8, instruction.mulmod },
    .{ .EXP, 10, instruction.exp },
    .{ .SIGNEXTEND, 5, instruction.signextend },
    .{ .LT, 3, instruction.lt },
    .{ .GT, 3, instruction.gt },
    .{ .SLT, 3, instruction.slt },
    .{ .SGT, 3, instruction.sgt },
    .{ .EQ, 3, instruction.eq },
    .{ .ISZERO, 3, instruction.iszero },
    .{ .AND, 3, instruction.bitAnd },
    .{ .OR, 3, instruction.bitOr },
    .{ .XOR, 3, instruction.bitXor },
    .{ .NOT, 3, instruction.bitNot },
    .{ .BYTE, 3, instruction.byte },
    .{ .SHL, 3, instruction.shl },
    .{ .SHR, 3, instruction.shr },
    .{ .SAR, 3, instruction.sar },
    .{ .KECCAK256, 30, instruction.keccak256 },
    .{ .ADDRESS, 2, instruction.address },
    .{ .BALANCE, 100, instruction.balance },
    .{ .ORIGIN, 2, instruction.origin },
    .{ .CALLER, 2, instruction.caller },
    .{ .CALLVALUE, 2, instruction.callvalue },
    .{ .CALLDATALOAD, 3, instruction.calldataload },
    .{ .CALLDATASIZE, 2, instruction.calldatasize },
    .{ .CALLDATACOPY, 3, instruction.calldatacopy },
    .{ .CODESIZE, 2, instruction.codesize },
    .{ .CODECOPY, 3, instruction.codecopy },
    .{ .GASPRICE, 2, instruction.gasprice },
    .{ .EXTCODESIZE, 100, instruction.extcodesize },
    .{ .EXTCODECOPY, 100, instruction.extcodecopy },
    .{ .RETURNDATASIZE, 2, instruction.returndatasize },
    .{ .RETURNDATACOPY, 3, instruction.returndatacopy },
    .{ .EXTCODEHASH, 100, instruction.extcodehash },
    .{ .BLOCKHASH, 20, instruction.blockhash },
    .{ .COINBASE, 2, instruction.coinbase },
    .{ .TIMESTAMP, 2, instruction.timestamp },
    .{ .NUMBER, 2, instruction.number },
    .{ .PREVRANDAO, 2, instruction.prevrandao },
    .{ .GASLIMIT, 2, instruction.gaslimit },
    .{ .CHAINID, 2, instruction.chainid },
    .{ .SELFBALANCE, 5, instruction.selfbalance },
    .{ .BASEFEE, 2, instruction.basefee },
    .{ .BLOBHASH, 3, instruction.todo }, // TODO
    .{ .BLOBBASEFEE, 3, instruction.todo }, // TODO
    .{ .POP, 2, instruction.pop },
    .{ .MLOAD, 3, instruction.mload },
    .{ .MSTORE, 3, instruction.mstore },
    .{ .MSTORE8, 3, instruction.mstore8 },
    .{ .SLOAD, 100, instruction.sload },
    .{ .SSTORE, 100, instruction.sstore },
    .{ .JUMP, 8, instruction.jump },
    .{ .JUMPI, 10, instruction.jumpi },
    .{ .PC, 2, instruction.pc },
    .{ .MSIZE, 2, instruction.msize },
    .{ .GAS, 2, instruction.gas },
    .{ .JUMPDEST, 1, instruction.noop },
    .{ .TLOAD, 100, instruction.todo }, // TLOAD
    .{ .TSTORE, 100, instruction.todo }, // TSTORE
    .{ .MCOPY, 3, instruction.todo },
    .{ .PUSH0, 2, instruction.push0 },
    .{ .PUSH1, 3, instruction.pushN(1) },
    .{ .PUSH2, 3, instruction.pushN(2) },
    .{ .PUSH3, 3, instruction.pushN(3) },
    .{ .PUSH4, 3, instruction.pushN(4) },
    .{ .PUSH5, 3, instruction.pushN(5) },
    .{ .PUSH6, 3, instruction.pushN(6) },
    .{ .PUSH7, 3, instruction.pushN(7) },
    .{ .PUSH8, 3, instruction.pushN(8) },
    .{ .PUSH9, 3, instruction.pushN(9) },
    .{ .PUSH10, 3, instruction.pushN(10) },
    .{ .PUSH11, 3, instruction.pushN(11) },
    .{ .PUSH12, 3, instruction.pushN(12) },
    .{ .PUSH13, 3, instruction.pushN(13) },
    .{ .PUSH14, 3, instruction.pushN(14) },
    .{ .PUSH15, 3, instruction.pushN(15) },
    .{ .PUSH16, 3, instruction.pushN(16) },
    .{ .PUSH17, 3, instruction.pushN(17) },
    .{ .PUSH18, 3, instruction.pushN(18) },
    .{ .PUSH19, 3, instruction.pushN(19) },
    .{ .PUSH20, 3, instruction.pushN(20) },
    .{ .PUSH21, 3, instruction.pushN(21) },
    .{ .PUSH22, 3, instruction.pushN(22) },
    .{ .PUSH23, 3, instruction.pushN(23) },
    .{ .PUSH24, 3, instruction.pushN(24) },
    .{ .PUSH25, 3, instruction.pushN(25) },
    .{ .PUSH26, 3, instruction.pushN(26) },
    .{ .PUSH27, 3, instruction.pushN(27) },
    .{ .PUSH28, 3, instruction.pushN(28) },
    .{ .PUSH29, 3, instruction.pushN(29) },
    .{ .PUSH30, 3, instruction.pushN(30) },
    .{ .PUSH31, 3, instruction.pushN(31) },
    .{ .PUSH32, 3, instruction.pushN(32) },
    .{ .DUP1, 3, instruction.dupN(1) },
    .{ .DUP2, 3, instruction.dupN(2) },
    .{ .DUP3, 3, instruction.dupN(3) },
    .{ .DUP4, 3, instruction.dupN(4) },
    .{ .DUP5, 3, instruction.dupN(5) },
    .{ .DUP6, 3, instruction.dupN(6) },
    .{ .DUP7, 3, instruction.dupN(7) },
    .{ .DUP8, 3, instruction.dupN(8) },
    .{ .DUP9, 3, instruction.dupN(9) },
    .{ .DUP10, 3, instruction.dupN(10) },
    .{ .DUP11, 3, instruction.dupN(11) },
    .{ .DUP12, 3, instruction.dupN(12) },
    .{ .DUP13, 3, instruction.dupN(13) },
    .{ .DUP14, 3, instruction.dupN(14) },
    .{ .DUP15, 3, instruction.dupN(15) },
    .{ .DUP16, 3, instruction.dupN(16) },
    .{ .SWAP1, 3, instruction.swapN(1) },
    .{ .SWAP2, 3, instruction.swapN(2) },
    .{ .SWAP3, 3, instruction.swapN(3) },
    .{ .SWAP4, 3, instruction.swapN(4) },
    .{ .SWAP5, 3, instruction.swapN(5) },
    .{ .SWAP6, 3, instruction.swapN(6) },
    .{ .SWAP7, 3, instruction.swapN(7) },
    .{ .SWAP8, 3, instruction.swapN(8) },
    .{ .SWAP9, 3, instruction.swapN(9) },
    .{ .SWAP10, 3, instruction.swapN(10) },
    .{ .SWAP11, 3, instruction.swapN(11) },
    .{ .SWAP12, 3, instruction.swapN(12) },
    .{ .SWAP13, 3, instruction.swapN(13) },
    .{ .SWAP14, 3, instruction.swapN(14) },
    .{ .SWAP15, 3, instruction.swapN(15) },
    .{ .SWAP16, 3, instruction.swapN(16) },
    .{ .LOG0, 375, instruction.logN(0) },
    .{ .LOG1, 375 * 2, instruction.logN(1) },
    .{ .LOG2, 375 * 3, instruction.logN(2) },
    .{ .LOG3, 375 * 4, instruction.logN(3) },
    .{ .LOG4, 375 * 5, instruction.logN(4) },
    .{ .CREATE, 32000, instruction.create },
    .{ .CALL, 100, instruction.call(.CALL) },
    .{ .CALLCODE, 100, instruction.call(.CALLCODE) },
    .{ .RETURN, 0, instruction.ret },
    .{ .DELEGATECALL, 100, instruction.call(.DELEGATECALL) },
    .{ .CREATE2, 32000, instruction.create2 },
    .{ .STATICCALL, 100, instruction.call(.STATICCALL) },
    .{ .REVERT, 0, instruction.revert },
    .{ .INVALID, 0, instruction.invalid },
    .{ .SELFDESTRUCT, 5000, instruction.selfdestruct },
};

test instruction_entries {
    try std.testing.expectEqual(@typeInfo(Opcode).Enum.fields.len, instruction_entries.len);
}

pub const Instruction = struct {
    opcode: Opcode,
    static_gas: u16,
    ptr: InstructionPtr,
};

pub const InstructionTable = entries: {
    const max = std.math.maxInt(u8) + 1;
    var table: [max]Instruction = undefined;

    for (0..max) |i| {
        table[i] = Instruction{
            .opcode = Opcode.REVERT,
            .static_gas = 0,
            .ptr = instruction.unknown,
        };
    }

    for (instruction_entries) |entry| {
        const opcode, const gas, const ptr = entry;
        table[@intFromEnum(opcode)] = Instruction{
            .opcode = opcode,
            .static_gas = gas,
            .ptr = ptr,
        };
    }

    break :entries table;
};

pub fn getInstruction(opcode: Opcode) Instruction {
    return InstructionTable[@intFromEnum(opcode)];
}

test InstructionTable {
    try std.testing.expectEqual(getInstruction(Opcode.PUSH1).opcode, Opcode.PUSH1);
    try std.testing.expectEqual(InstructionTable[0x60].static_gas, 3);
}

pub const Error = error{
    UnknownOpcode,
};

const instruction = struct {
    usingnamespace @import("./instruction/stack.zig");
    usingnamespace @import("./instruction/arithmetic.zig");
    usingnamespace @import("./instruction/flow.zig");
    usingnamespace @import("./instruction/logic.zig");
    usingnamespace @import("./instruction/memory.zig");
    usingnamespace @import("./instruction/storage.zig");
    usingnamespace @import("./instruction/logging.zig");
    usingnamespace @import("./instruction/system.zig");
    usingnamespace @import("./instruction/environment.zig");

    const Self = @This();

    fn noop(ip: *Interpreter) anyerror!void {
        _ = ip;
        return;
    }

    fn unknown(ip: *Interpreter) anyerror!void {
        _ = ip;
        return error.UnknownOpcode;
    }

    fn todo(ip: *Interpreter) anyerror!void {
        _ = ip;
        return std.debug.panic("TODO", .{});
    }

    inline fn pushN(comptime n: u8) InstructionPtr {
        return struct {
            pub fn call(ip: *Interpreter) anyerror!void {
                return Self.push(ip, n);
            }
        }.call;
    }

    inline fn dupN(comptime n: u8) InstructionPtr {
        return struct {
            pub fn call(ip: *Interpreter) anyerror!void {
                return Self.dup(ip, n);
            }
        }.call;
    }

    inline fn swapN(comptime n: u8) InstructionPtr {
        return struct {
            pub fn call(ip: *Interpreter) anyerror!void {
                return Self.swap(ip, n);
            }
        }.call;
    }

    inline fn logN(comptime n: u8) InstructionPtr {
        return struct {
            pub fn call(ip: *Interpreter) anyerror!void {
                return Self.log(ip, n);
            }
        }.call;
    }

    inline fn call(comptime op: Opcode) InstructionPtr {
        return struct {
            pub fn call(ip: *Interpreter) anyerror!void {
                return Self.callByOp(ip, op);
            }
        }.call;
    }
};
