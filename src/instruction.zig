const Opcode = @import("opcode.zig").Opcode;
const std = @import("std");
const Interpreter = @import("./Interpreter.zig");

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

    inline fn createPushN(comptime n: u8) InstructionPtr {
        return struct {
            pub inline fn call(ip: *Interpreter) anyerror!void {
                return Self.push(ip, n);
            }
        }.call;
    }

    inline fn createDupN(comptime n: u8) InstructionPtr {
        return struct {
            pub inline fn call(ip: *Interpreter) anyerror!void {
                return Self.dup(ip, n);
            }
        }.call;
    }

    inline fn createSwapN(comptime n: u8) InstructionPtr {
        return struct {
            pub inline fn call(ip: *Interpreter) anyerror!void {
                return Self.swap(ip, n);
            }
        }.call;
    }

    inline fn createLogN(comptime n: u8) InstructionPtr {
        return struct {
            pub inline fn call(ip: *Interpreter) anyerror!void {
                return Self.log(ip, n);
            }
        }.call;
    }
};

const InstructionPtr = *const fn (ip: *Interpreter) anyerror!void;

const InstructionEntry = struct { Opcode, u8, InstructionPtr };

const instruction_entries: []InstructionEntry = &.{
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
    .{ .BLOCKHASH, 20, instruction.blockhash },
    .{ .COINBASE, 2, instruction.coinbase },
    .{ .TIMESTAMP, 2, instruction.timestamp },
    .{ .NUMBER, 2, instruction.number },
    .{ .PREVRANDAO, 2, instruction.prevrandao },
    .{ .GASLIMIT, 2, instruction.gaslimit },
    .{ .CHAINID, 2, instruction.chainid },
    .{ .SELFBALANCE, 5, instruction.selfbalance },
    .{ .BASEFEE, 2, instruction.basefee },
    // .{ .BLOBHASH, 3, } TODO
    // .{ .BLOBBASEFEE, 3, } TODO
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
    .{ .JUMPDEST, 1, instruction.jumpdest },
    // TLOAD
    // TSTORE
    // .{ .MCOPY, 3, instruction.mcopy },
    .{ .PUSH0, 2, instruction.push0 },
    .{ .PUSH1, 3, instruction.createPushN(1) },
    .{ .PUSH2, 3, instruction.createPushN(2) },
    .{ .PUSH3, 3, instruction.createPushN(3) },
    .{ .PUSH4, 3, instruction.createPushN(4) },
    .{ .PUSH5, 3, instruction.createPushN(5) },
    .{ .PUSH6, 3, instruction.createPushN(6) },
    .{ .PUSH7, 3, instruction.createPushN(7) },
    .{ .PUSH8, 3, instruction.createPushN(8) },
    .{ .PUSH9, 3, instruction.createPushN(9) },
    .{ .PUSH10, 3, instruction.createPushN(10) },
    .{ .PUSH11, 3, instruction.createPushN(11) },
    .{ .PUSH12, 3, instruction.createPushN(12) },
    .{ .PUSH13, 3, instruction.createPushN(13) },
    .{ .PUSH14, 3, instruction.createPushN(14) },
    .{ .PUSH15, 3, instruction.createPushN(15) },
    .{ .PUSH16, 3, instruction.createPushN(16) },
    .{ .PUSH17, 3, instruction.createPushN(17) },
    .{ .PUSH18, 3, instruction.createPushN(18) },
    .{ .PUSH19, 3, instruction.createPushN(19) },
    .{ .PUSH20, 3, instruction.createPushN(20) },
    .{ .PUSH21, 3, instruction.createPushN(21) },
    .{ .PUSH22, 3, instruction.createPushN(22) },
    .{ .PUSH23, 3, instruction.createPushN(23) },
    .{ .PUSH24, 3, instruction.createPushN(24) },
    .{ .PUSH25, 3, instruction.createPushN(25) },
    .{ .PUSH26, 3, instruction.createPushN(26) },
    .{ .PUSH27, 3, instruction.createPushN(27) },
    .{ .PUSH28, 3, instruction.createPushN(28) },
    .{ .PUSH29, 3, instruction.createPushN(29) },
    .{ .PUSH30, 3, instruction.createPushN(30) },
    .{ .PUSH31, 3, instruction.createPushN(31) },
    .{ .PUSH32, 3, instruction.createPushN(32) },
    .{ .DUP1, 3, instruction.createDupN(1) },
    .{ .DUP2, 3, instruction.createDupN(2) },
    .{ .DUP3, 3, instruction.createDupN(3) },
    .{ .DUP4, 3, instruction.createDupN(4) },
    .{ .DUP5, 3, instruction.createDupN(5) },
    .{ .DUP6, 3, instruction.createDupN(6) },
    .{ .DUP7, 3, instruction.createDupN(7) },
    .{ .DUP8, 3, instruction.createDupN(8) },
    .{ .DUP9, 3, instruction.createDupN(9) },
    .{ .DUP10, 3, instruction.createDupN(10) },
    .{ .DUP11, 3, instruction.createDupN(11) },
    .{ .DUP12, 3, instruction.createDupN(12) },
    .{ .DUP13, 3, instruction.createDupN(13) },
    .{ .DUP14, 3, instruction.createDupN(14) },
    .{ .DUP15, 3, instruction.createDupN(15) },
    .{ .DUP16, 3, instruction.createDupN(16) },
    .{ .SWAP1, 3, instruction.createSwapN(1) },
    .{ .SWAP2, 3, instruction.createSwapN(2) },
    .{ .SWAP3, 3, instruction.createSwapN(3) },
    .{ .SWAP4, 3, instruction.createSwapN(4) },
    .{ .SWAP5, 3, instruction.createSwapN(5) },
    .{ .SWAP6, 3, instruction.createSwapN(6) },
    .{ .SWAP7, 3, instruction.createSwapN(7) },
    .{ .SWAP8, 3, instruction.createSwapN(8) },
    .{ .SWAP9, 3, instruction.createSwapN(9) },
    .{ .SWAP10, 3, instruction.createSwapN(10) },
    .{ .SWAP11, 3, instruction.createSwapN(11) },
    .{ .SWAP12, 3, instruction.createSwapN(12) },
    .{ .SWAP13, 3, instruction.createSwapN(13) },
    .{ .SWAP14, 3, instruction.createSwapN(14) },
    .{ .SWAP15, 3, instruction.createSwapN(15) },
    .{ .SWAP16, 3, instruction.createSwapN(16) },
    .{ .LOG0, 375, instruction.createLogN(0) },
    .{ .LOG1, 375 * 2, instruction.createLogN(1) },
    .{ .LOG2, 375 * 3, instruction.createLogN(2) },
    .{ .LOG3, 375 * 4, instruction.createLogN(3) },
    .{ .LOG4, 375 * 5, instruction.createLogN(4) },
    .{ .CREATE, 32000, instruction.create },
    .{ .CALL, 100, instruction.call },
    .{ .CALLCODE, 100, instruction.callcode },
    .{ .RETURN, 0, instruction.ret },
    .{ .DELEGATECALL, 100, instruction.delegatecall },
    .{ .CREATE2, 32000, instruction.create2 },
    .{ .STATICALL, 100, instruction.staticcall },
    .{ .REVERT, 0, instruction.revert },
    .{ .INVALID, 0, instruction.invalid },
    .{ .SELFDESTRUCT, 5000, instruction.selfdestruct },
};

test instruction_entries {
    try std.testing.expectEqual(@typeInfo(Opcode).Enum.fields.len, instruction_entries.len);
}
