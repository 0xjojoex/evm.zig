const Opcode = @import("opcode.zig").Opcode;
const std = @import("std");
const evmz = @import("./evm.zig");
const interpreter = @import("./interpreter.zig");

pub const call_value_cost = 9000;
pub const account_creation_cost = 25000;

// [EIP-2929](https://eips.ethereum.org/EIPS/eip-2929)
pub const cold_sload_cost = 2100;
const cold_account_access_cost = 2600;
pub const warm_storage_read_cost = 100;

// warm_storage_read_cost is count before instruction execution
pub const cold_account_access_gas = cold_account_access_cost - warm_storage_read_cost;
pub const cold_sload_gas = cold_sload_cost - warm_storage_read_cost;

const CallFrame = interpreter.CallFrame;

pub const Error = error{
    UnknownOpcode,
};

const InstructionPtr = *const fn (ip: *CallFrame) anyerror!void;

const InstructionEntry = struct {
    Opcode,
    // the static gas cost required to execute this instruction
    // not using gas enum because it's not very readable
    u16,
    // StackHeight,
    // dynamic dispatching, TODO: can it be inline fn?
    InstructionPtr,
};

pub const Instruction = struct {
    opcode: Opcode,
    static_gas: u16,
    ptr: InstructionPtr,
};

pub fn InstructionTable(comptime spec: evmz.Spec) type {
    const instructions = Instructions(spec);

    const instruction_entries: []const InstructionEntry = &.{
        .{ .STOP, 0, instructions.system.stop },
        .{ .ADD, 3, instructions.arithmetic.add },
        .{ .MUL, 5, instructions.arithmetic.mul },
        .{ .SUB, 3, instructions.arithmetic.sub },
        .{ .DIV, 5, instructions.arithmetic.div },
        .{ .SDIV, 5, instructions.arithmetic.sdiv },
        .{ .MOD, 5, instructions.arithmetic.mod },
        .{ .SMOD, 5, instructions.arithmetic.smod },
        .{ .ADDMOD, 8, instructions.arithmetic.addmod },
        .{ .MULMOD, 8, instructions.arithmetic.mulmod },
        .{ .EXP, 10, instructions.arithmetic.exp },
        .{ .SIGNEXTEND, 5, instructions.arithmetic.signextend },
        .{ .LT, 3, instructions.logic.lt },
        .{ .GT, 3, instructions.logic.gt },
        .{ .SLT, 3, instructions.logic.slt },
        .{ .SGT, 3, instructions.logic.sgt },
        .{ .EQ, 3, instructions.logic.eq },
        .{ .ISZERO, 3, instructions.logic.iszero },
        .{ .AND, 3, instructions.logic.bitAnd },
        .{ .OR, 3, instructions.logic.bitOr },
        .{ .XOR, 3, instructions.logic.bitXor },
        .{ .NOT, 3, instructions.logic.bitNot },
        .{ .BYTE, 3, instructions.logic.byte },
        .{ .SHL, 3, instructions.logic.shl },
        .{ .SHR, 3, instructions.logic.shr },
        .{ .SAR, 3, instructions.logic.sar },
        .{ .KECCAK256, 30, instructions.arithmetic.keccak256 },
        .{ .ADDRESS, 2, instructions.environment.address },
        .{ .BALANCE, 100, instructions.environment.balance },
        .{ .ORIGIN, 2, instructions.environment.origin },
        .{ .CALLER, 2, instructions.environment.caller },
        .{ .CALLVALUE, 2, instructions.environment.callvalue },
        .{ .CALLDATALOAD, 3, instructions.environment.calldataload },
        .{ .CALLDATASIZE, 2, instructions.environment.calldatasize },
        .{ .CALLDATACOPY, 3, instructions.environment.calldatacopy },
        .{ .CODESIZE, 2, instructions.environment.codesize },
        .{ .CODECOPY, 3, instructions.environment.codecopy },
        .{ .GASPRICE, 2, instructions.environment.gasprice },
        .{ .EXTCODESIZE, 100, instructions.environment.extcodesize },
        .{ .EXTCODECOPY, 100, instructions.environment.extcodecopy },
        .{ .RETURNDATASIZE, 2, instructions.environment.returndatasize },
        .{ .RETURNDATACOPY, 3, instructions.environment.returndatacopy },
        .{ .EXTCODEHASH, 100, instructions.environment.extcodehash },
        .{ .BLOCKHASH, 20, instructions.environment.blockhash },
        .{ .COINBASE, 2, instructions.environment.coinbase },
        .{ .TIMESTAMP, 2, instructions.environment.timestamp },
        .{ .NUMBER, 2, instructions.environment.number },
        .{ .PREVRANDAO, 2, instructions.environment.prevrandao },
        .{ .GASLIMIT, 2, instructions.environment.gaslimit },
        .{ .CHAINID, 2, instructions.environment.chainid },
        .{ .SELFBALANCE, 5, instructions.environment.selfbalance },
        .{ .BASEFEE, 2, instructions.environment.basefee },
        .{ .BLOBHASH, 3, instructions.environment.blobhash },
        .{ .BLOBBASEFEE, 3, instructions.environment.blobbasefee },
        .{ .POP, 2, instructions.stack.pop },
        .{ .MLOAD, 3, instructions.memory.mload },
        .{ .MSTORE, 3, instructions.memory.mstore },
        .{ .MSTORE8, 3, instructions.memory.mstore8 },
        .{ .SLOAD, 100, instructions.storage.sload },
        .{ .SSTORE, 100, instructions.storage.sstore },
        .{ .JUMP, 8, instructions.flow.jump },
        .{ .JUMPI, 10, instructions.flow.jumpi },
        .{ .PC, 2, instructions.flow.pc },
        .{ .MSIZE, 2, instructions.memory.msize },
        .{ .GAS, 2, instructions.environment.gas },
        .{ .JUMPDEST, 1, instructions.noop },
        .{ .TLOAD, 100, instructions.storage.tload },
        .{ .TSTORE, 100, instructions.storage.tstore },
        .{ .MCOPY, 3, instructions.memory.mcopy },
        .{ .PUSH0, 2, instructions.stack.push0 },
        .{ .PUSH1, 3, instructions.pushN(1) },
        .{ .PUSH2, 3, instructions.pushN(2) },
        .{ .PUSH3, 3, instructions.pushN(3) },
        .{ .PUSH4, 3, instructions.pushN(4) },
        .{ .PUSH5, 3, instructions.pushN(5) },
        .{ .PUSH6, 3, instructions.pushN(6) },
        .{ .PUSH7, 3, instructions.pushN(7) },
        .{ .PUSH8, 3, instructions.pushN(8) },
        .{ .PUSH9, 3, instructions.pushN(9) },
        .{ .PUSH10, 3, instructions.pushN(10) },
        .{ .PUSH11, 3, instructions.pushN(11) },
        .{ .PUSH12, 3, instructions.pushN(12) },
        .{ .PUSH13, 3, instructions.pushN(13) },
        .{ .PUSH14, 3, instructions.pushN(14) },
        .{ .PUSH15, 3, instructions.pushN(15) },
        .{ .PUSH16, 3, instructions.pushN(16) },
        .{ .PUSH17, 3, instructions.pushN(17) },
        .{ .PUSH18, 3, instructions.pushN(18) },
        .{ .PUSH19, 3, instructions.pushN(19) },
        .{ .PUSH20, 3, instructions.pushN(20) },
        .{ .PUSH21, 3, instructions.pushN(21) },
        .{ .PUSH22, 3, instructions.pushN(22) },
        .{ .PUSH23, 3, instructions.pushN(23) },
        .{ .PUSH24, 3, instructions.pushN(24) },
        .{ .PUSH25, 3, instructions.pushN(25) },
        .{ .PUSH26, 3, instructions.pushN(26) },
        .{ .PUSH27, 3, instructions.pushN(27) },
        .{ .PUSH28, 3, instructions.pushN(28) },
        .{ .PUSH29, 3, instructions.pushN(29) },
        .{ .PUSH30, 3, instructions.pushN(30) },
        .{ .PUSH31, 3, instructions.pushN(31) },
        .{ .PUSH32, 3, instructions.pushN(32) },
        .{ .DUP1, 3, instructions.dupN(1) },
        .{ .DUP2, 3, instructions.dupN(2) },
        .{ .DUP3, 3, instructions.dupN(3) },
        .{ .DUP4, 3, instructions.dupN(4) },
        .{ .DUP5, 3, instructions.dupN(5) },
        .{ .DUP6, 3, instructions.dupN(6) },
        .{ .DUP7, 3, instructions.dupN(7) },
        .{ .DUP8, 3, instructions.dupN(8) },
        .{ .DUP9, 3, instructions.dupN(9) },
        .{ .DUP10, 3, instructions.dupN(10) },
        .{ .DUP11, 3, instructions.dupN(11) },
        .{ .DUP12, 3, instructions.dupN(12) },
        .{ .DUP13, 3, instructions.dupN(13) },
        .{ .DUP14, 3, instructions.dupN(14) },
        .{ .DUP15, 3, instructions.dupN(15) },
        .{ .DUP16, 3, instructions.dupN(16) },
        .{ .SWAP1, 3, instructions.swapN(1) },
        .{ .SWAP2, 3, instructions.swapN(2) },
        .{ .SWAP3, 3, instructions.swapN(3) },
        .{ .SWAP4, 3, instructions.swapN(4) },
        .{ .SWAP5, 3, instructions.swapN(5) },
        .{ .SWAP6, 3, instructions.swapN(6) },
        .{ .SWAP7, 3, instructions.swapN(7) },
        .{ .SWAP8, 3, instructions.swapN(8) },
        .{ .SWAP9, 3, instructions.swapN(9) },
        .{ .SWAP10, 3, instructions.swapN(10) },
        .{ .SWAP11, 3, instructions.swapN(11) },
        .{ .SWAP12, 3, instructions.swapN(12) },
        .{ .SWAP13, 3, instructions.swapN(13) },
        .{ .SWAP14, 3, instructions.swapN(14) },
        .{ .SWAP15, 3, instructions.swapN(15) },
        .{ .SWAP16, 3, instructions.swapN(16) },
        .{ .LOG0, 375, instructions.logN(0) },
        .{ .LOG1, 375 * 2, instructions.logN(1) },
        .{ .LOG2, 375 * 3, instructions.logN(2) },
        .{ .LOG3, 375 * 4, instructions.logN(3) },
        .{ .LOG4, 375 * 5, instructions.logN(4) },
        .{ .CREATE, 32000, instructions.system.create },
        .{ .CALL, 100, instructions.call(.CALL) },
        .{ .CALLCODE, 100, instructions.call(.CALLCODE) },
        .{ .RETURN, 0, instructions.system.ret },
        .{ .DELEGATECALL, 100, instructions.call(.DELEGATECALL) },
        .{ .CREATE2, 32000, instructions.system.create2 },
        .{ .STATICCALL, 100, instructions.call(.STATICCALL) },
        .{ .REVERT, 0, instructions.system.revert },
        .{ .INVALID, 0, instructions.system.invalid },
        .{ .SELFDESTRUCT, 5000, instructions.system.selfdestruct },
    };

    return struct {
        const Self = @This();

        pub const data = entries: {
            const max = std.math.maxInt(u8) + 1;
            var table: [max]Instruction = undefined;

            for (0..max) |i| {
                table[i] = Instruction{
                    .opcode = Opcode.REVERT,
                    .static_gas = 0,
                    .ptr = instructions.unknown,
                };
            }

            if (@typeInfo(Opcode).Enum.fields.len != instruction_entries.len) {
                @compileError("Opcode enum and instruction_entries have different lengths");
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
    };
}

test InstructionTable {
    const instruction_table = InstructionTable(evmz.spec.Spec.latest);

    try std.testing.expectEqual(instruction_table.data[0x00].static_gas, 0);
    try std.testing.expectEqual(instruction_table.data[0x60].static_gas, 3);
}

pub fn Instructions(comptime spec: evmz.Spec) type {
    return struct {
        pub const arithmetic = @import("./instruction/arithmetic.zig").Arithmetic(spec);
        pub const environment = @import("./instruction/environment.zig").Enviroment(spec);
        pub const flow = @import("./instruction/flow.zig").Flow(spec);
        pub const logging = @import("./instruction/logging.zig").Logging(spec);
        pub const stack = @import("./instruction/stack.zig").Stack(spec);
        pub const storage = @import("./instruction/storage.zig").Storage(spec);
        pub const system = @import("./instruction/system.zig").System(spec);
        pub const memory = @import("./instruction/memory.zig").Memory(spec);
        pub const logic = @import("./instruction/logic.zig").Logic(spec);

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
}
