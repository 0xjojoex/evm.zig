const opcode_info = @import("opcode.zig");
const Opcode = opcode_info.Opcode;
const std = @import("std");
const evmz = @import("./evm.zig");
const Interpreter = @import("./Interpreter.zig");
const CallFrame = Interpreter.CallFrame;
const tx_gas = @import("./transaction/gas.zig");

pub const call_value_cost = 9000;
pub const call_stipend: i64 = @intCast(tx_gas.call_stipend);
pub const account_creation_cost = 25000;

// [EIP-2929](https://eips.ethereum.org/EIPS/eip-2929)
pub const cold_sload_cost = 2100;
pub const cold_account_access_cost = 2600;
pub const warm_storage_read_cost = 100;

// warm_storage_read_cost is count before instruction execution
pub const cold_account_access_gas = cold_account_access_cost - warm_storage_read_cost;
pub const cold_sload_gas = cold_sload_cost - warm_storage_read_cost;

pub const Error = error{
    UnknownOpcode,
};

pub const arithmetic = @import("./instruction/arithmetic.zig");
pub const environment = @import("./instruction/environment.zig");
pub const flow = @import("./instruction/flow.zig");
pub const logging = @import("./instruction/logging.zig");
pub const stack = @import("./instruction/stack.zig");
pub const storage = @import("./instruction/storage.zig");
pub const system = @import("./instruction/system.zig");
pub const memory = @import("./instruction/memory.zig");
pub const logic = @import("./instruction/logic.zig");

pub const Instruction = struct {
    opcode: Opcode,
    static_gas: u16,
};

pub fn decode(opcode_byte: u8) ?Instruction {
    const opcode: Opcode = @enumFromInt(opcode_byte);
    const row = opcode_info.info(opcode.toByte());
    if (!row.defined) return null;
    return .{ .opcode = opcode, .static_gas = row.static_gas };
}

test decode {
    try std.testing.expectEqual(@as(u16, 0), decode(0x00).?.static_gas);
    try std.testing.expectEqual(@as(u16, 3), decode(0x60).?.static_gas);
    try std.testing.expectEqual(null, decode(0x0c));
}

test "decode follows opcode table for every byte" {
    for (0..256) |index| {
        const opcode_byte: u8 = @intCast(index);
        const row = opcode_info.info(opcode_byte);
        const decoded = decode(opcode_byte);
        if (!row.defined) {
            try std.testing.expectEqual(null, decoded);
            continue;
        }

        try std.testing.expect(decoded != null);
        try std.testing.expectEqual(opcode_byte, @intFromEnum(decoded.?.opcode));
        try std.testing.expectEqual(row.static_gas, decoded.?.static_gas);
    }
}

test "fork-gated opcodes are invalid before their activation fork" {
    try evmz.t.expectBytecodeStatusBySpec(.{.RETURNDATASIZE}, .homestead, .invalid);
    try evmz.t.expectBytecodeStatusBySpec(.{.RETURNDATASIZE}, .byzantium, .success);

    try evmz.t.expectBytecodeStatusBySpec(.{.BASEFEE}, .berlin, .invalid);
    try evmz.t.expectBytecodeStatusBySpec(.{.BASEFEE}, .london, .success);

    try evmz.t.expectBytecodeStatusBySpec(.{.PUSH0}, .london, .invalid);
    try evmz.t.expectBytecodeStatusBySpec(.{.PUSH0}, .shanghai, .success);

    try evmz.t.expectBytecodeStatusBySpec(.{.BLOBBASEFEE}, .shanghai, .invalid);
    try evmz.t.expectBytecodeStatusBySpec(.{.BLOBBASEFEE}, .cancun, .success);
    try evmz.t.expectBytecodeStatusBySpec(.{ .PUSH1, 0x00, .BLOBHASH }, .shanghai, .invalid);
    try evmz.t.expectBytecodeStatusBySpec(.{ .PUSH1, 0x00, .BLOBHASH }, .cancun, .success);

    try evmz.t.expectBytecodeStatusBySpec(.{.SLOTNUM}, .osaka, .invalid);
    try evmz.t.expectBytecodeStatusBySpec(.{.SLOTNUM}, .amsterdam, .success);

    try evmz.t.expectBytecodeStatusBySpec(.{
        .PUSH1, 0x01,   .PUSH0, .PUSH0, .PUSH0, .PUSH0,
        .PUSH0, .PUSH0, .PUSH0, .PUSH0, .PUSH0, .PUSH0,
        .PUSH0, .PUSH0, .PUSH0, .PUSH0, .PUSH0, .PUSH0,
        .DUPN,  0x80,
    }, .osaka, .invalid);
    try evmz.t.expectBytecodeStatusBySpec(.{
        .PUSH1, 0x01,   .PUSH0, .PUSH0, .PUSH0, .PUSH0,
        .PUSH0, .PUSH0, .PUSH0, .PUSH0, .PUSH0, .PUSH0,
        .PUSH0, .PUSH0, .PUSH0, .PUSH0, .PUSH0, .PUSH0,
        .DUPN,  0x80,
    }, .amsterdam, .success);
}

test "fork-dependent static gas follows legacy schedules" {
    try std.testing.expectEqual(@as(i64, 20), staticGasForSpec(.frontier, .BALANCE));
    try std.testing.expectEqual(@as(i64, 400), staticGasForSpec(.byzantium, .BALANCE));
    try std.testing.expectEqual(@as(i64, 700), staticGasForSpec(.istanbul, .BALANCE));
    try std.testing.expectEqual(@as(i64, 100), staticGasForSpec(.berlin, .BALANCE));

    try std.testing.expectEqual(@as(i64, 20), staticGasForSpec(.homestead, .EXTCODECOPY));
    try std.testing.expectEqual(@as(i64, 700), staticGasForSpec(.byzantium, .EXTCODECOPY));
    try std.testing.expectEqual(@as(i64, 400), staticGasForSpec(.petersburg, .EXTCODEHASH));
    try std.testing.expectEqual(@as(i64, 700), staticGasForSpec(.istanbul, .EXTCODEHASH));

    try std.testing.expectEqual(@as(i64, 50), staticGasForSpec(.frontier, .SLOAD));
    try std.testing.expectEqual(@as(i64, 200), staticGasForSpec(.byzantium, .SLOAD));
    try std.testing.expectEqual(@as(i64, 800), staticGasForSpec(.istanbul, .SLOAD));

    try std.testing.expectEqual(@as(i64, 0), staticGasForSpec(.homestead, .SELFDESTRUCT));
    try std.testing.expectEqual(@as(i64, 5000), staticGasForSpec(.tangerine_whistle, .SELFDESTRUCT));
}

pub fn staticGas(opcode: Opcode) u16 {
    return opcode_info.table[@intFromEnum(opcode)].static_gas;
}

pub inline fn execute(opcode_byte: u8, frame: *CallFrame) anyerror!void {
    @setEvalBranchQuota(5000);
    return switch (opcode_byte) {
        @intFromEnum(Opcode.STOP) => system.stop(frame),
        @intFromEnum(Opcode.ADD) => {
            if (!chargeStaticGas(frame, .ADD)) return;
            return arithmetic.add(frame);
        },
        @intFromEnum(Opcode.MUL) => {
            if (!chargeStaticGas(frame, .MUL)) return;
            return arithmetic.mul(frame);
        },
        @intFromEnum(Opcode.SUB) => {
            if (!chargeStaticGas(frame, .SUB)) return;
            return arithmetic.sub(frame);
        },
        @intFromEnum(Opcode.DIV) => {
            if (!chargeStaticGas(frame, .DIV)) return;
            return arithmetic.div(frame);
        },
        @intFromEnum(Opcode.SDIV) => {
            if (!chargeStaticGas(frame, .SDIV)) return;
            return arithmetic.sdiv(frame);
        },
        @intFromEnum(Opcode.MOD) => {
            if (!chargeStaticGas(frame, .MOD)) return;
            return arithmetic.mod(frame);
        },
        @intFromEnum(Opcode.SMOD) => {
            if (!chargeStaticGas(frame, .SMOD)) return;
            return arithmetic.smod(frame);
        },
        @intFromEnum(Opcode.ADDMOD) => {
            if (!chargeStaticGas(frame, .ADDMOD)) return;
            return arithmetic.addmod(frame);
        },
        @intFromEnum(Opcode.MULMOD) => {
            if (!chargeStaticGas(frame, .MULMOD)) return;
            return arithmetic.mulmod(frame);
        },
        @intFromEnum(Opcode.EXP) => {
            if (!chargeStaticGas(frame, .EXP)) return;
            return arithmetic.exp(frame);
        },
        @intFromEnum(Opcode.SIGNEXTEND) => {
            if (!chargeStaticGas(frame, .SIGNEXTEND)) return;
            return arithmetic.signextend(frame);
        },
        @intFromEnum(Opcode.LT) => {
            if (!chargeStaticGas(frame, .LT)) return;
            return logic.lt(frame);
        },
        @intFromEnum(Opcode.GT) => {
            if (!chargeStaticGas(frame, .GT)) return;
            return logic.gt(frame);
        },
        @intFromEnum(Opcode.SLT) => {
            if (!chargeStaticGas(frame, .SLT)) return;
            return logic.slt(frame);
        },
        @intFromEnum(Opcode.SGT) => {
            if (!chargeStaticGas(frame, .SGT)) return;
            return logic.sgt(frame);
        },
        @intFromEnum(Opcode.EQ) => {
            if (!chargeStaticGas(frame, .EQ)) return;
            return logic.eq(frame);
        },
        @intFromEnum(Opcode.ISZERO) => {
            if (!chargeStaticGas(frame, .ISZERO)) return;
            return logic.iszero(frame);
        },
        @intFromEnum(Opcode.AND) => {
            if (!chargeStaticGas(frame, .AND)) return;
            return logic.bitAnd(frame);
        },
        @intFromEnum(Opcode.OR) => {
            if (!chargeStaticGas(frame, .OR)) return;
            return logic.bitOr(frame);
        },
        @intFromEnum(Opcode.XOR) => {
            if (!chargeStaticGas(frame, .XOR)) return;
            return logic.bitXor(frame);
        },
        @intFromEnum(Opcode.NOT) => {
            if (!chargeStaticGas(frame, .NOT)) return;
            return logic.bitNot(frame);
        },
        @intFromEnum(Opcode.BYTE) => {
            if (!chargeStaticGas(frame, .BYTE)) return;
            return logic.byte(frame);
        },
        @intFromEnum(Opcode.SHL) => {
            if (!requireSpec(frame, .constantinople)) return;
            if (!chargeStaticGas(frame, .SHL)) return;
            return logic.shl(frame);
        },
        @intFromEnum(Opcode.SHR) => {
            if (!requireSpec(frame, .constantinople)) return;
            if (!chargeStaticGas(frame, .SHR)) return;
            return logic.shr(frame);
        },
        @intFromEnum(Opcode.SAR) => {
            if (!requireSpec(frame, .constantinople)) return;
            if (!chargeStaticGas(frame, .SAR)) return;
            return logic.sar(frame);
        },
        @intFromEnum(Opcode.CLZ) => {
            if (!requireSpec(frame, .osaka)) return;
            if (!chargeStaticGas(frame, .CLZ)) return;
            return logic.clz(frame);
        },
        @intFromEnum(Opcode.KECCAK256) => {
            if (!chargeStaticGas(frame, .KECCAK256)) return;
            return arithmetic.keccak256(frame);
        },
        @intFromEnum(Opcode.ADDRESS) => {
            if (!chargeStaticGas(frame, .ADDRESS)) return;
            return environment.address(frame);
        },
        @intFromEnum(Opcode.BALANCE) => {
            if (!chargeStaticGas(frame, .BALANCE)) return;
            return environment.balance(frame);
        },
        @intFromEnum(Opcode.ORIGIN) => {
            if (!chargeStaticGas(frame, .ORIGIN)) return;
            return environment.origin(frame);
        },
        @intFromEnum(Opcode.CALLER) => {
            if (!chargeStaticGas(frame, .CALLER)) return;
            return environment.caller(frame);
        },
        @intFromEnum(Opcode.CALLVALUE) => {
            if (!chargeStaticGas(frame, .CALLVALUE)) return;
            return environment.callvalue(frame);
        },
        @intFromEnum(Opcode.CALLDATALOAD) => {
            if (!chargeStaticGas(frame, .CALLDATALOAD)) return;
            return environment.calldataload(frame);
        },
        @intFromEnum(Opcode.CALLDATASIZE) => {
            if (!chargeStaticGas(frame, .CALLDATASIZE)) return;
            return environment.calldatasize(frame);
        },
        @intFromEnum(Opcode.CALLDATACOPY) => {
            if (!chargeStaticGas(frame, .CALLDATACOPY)) return;
            return environment.calldatacopy(frame);
        },
        @intFromEnum(Opcode.CODESIZE) => {
            if (!chargeStaticGas(frame, .CODESIZE)) return;
            return environment.codesize(frame);
        },
        @intFromEnum(Opcode.CODECOPY) => {
            if (!chargeStaticGas(frame, .CODECOPY)) return;
            return environment.codecopy(frame);
        },
        @intFromEnum(Opcode.GASPRICE) => {
            if (!chargeStaticGas(frame, .GASPRICE)) return;
            return environment.gasprice(frame);
        },
        @intFromEnum(Opcode.EXTCODESIZE) => {
            if (!chargeStaticGas(frame, .EXTCODESIZE)) return;
            return environment.extcodesize(frame);
        },
        @intFromEnum(Opcode.EXTCODECOPY) => {
            if (!chargeStaticGas(frame, .EXTCODECOPY)) return;
            return environment.extcodecopy(frame);
        },
        @intFromEnum(Opcode.RETURNDATASIZE) => {
            if (!requireSpec(frame, .byzantium)) return;
            if (!chargeStaticGas(frame, .RETURNDATASIZE)) return;
            return environment.returndatasize(frame);
        },
        @intFromEnum(Opcode.RETURNDATACOPY) => {
            if (!requireSpec(frame, .byzantium)) return;
            if (!chargeStaticGas(frame, .RETURNDATACOPY)) return;
            return environment.returndatacopy(frame);
        },
        @intFromEnum(Opcode.EXTCODEHASH) => {
            if (!requireSpec(frame, .constantinople)) return;
            if (!chargeStaticGas(frame, .EXTCODEHASH)) return;
            return environment.extcodehash(frame);
        },
        @intFromEnum(Opcode.BLOCKHASH) => {
            if (!chargeStaticGas(frame, .BLOCKHASH)) return;
            return environment.blockhash(frame);
        },
        @intFromEnum(Opcode.COINBASE) => {
            if (!chargeStaticGas(frame, .COINBASE)) return;
            return environment.coinbase(frame);
        },
        @intFromEnum(Opcode.TIMESTAMP) => {
            if (!chargeStaticGas(frame, .TIMESTAMP)) return;
            return environment.timestamp(frame);
        },
        @intFromEnum(Opcode.NUMBER) => {
            if (!chargeStaticGas(frame, .NUMBER)) return;
            return environment.number(frame);
        },
        @intFromEnum(Opcode.SLOTNUM) => {
            if (!requireSpec(frame, .amsterdam)) return;
            if (!chargeStaticGas(frame, .SLOTNUM)) return;
            return environment.slotnum(frame);
        },
        @intFromEnum(Opcode.PREVRANDAO) => {
            if (!chargeStaticGas(frame, .PREVRANDAO)) return;
            return environment.prevrandao(frame);
        },
        @intFromEnum(Opcode.GASLIMIT) => {
            if (!chargeStaticGas(frame, .GASLIMIT)) return;
            return environment.gaslimit(frame);
        },
        @intFromEnum(Opcode.CHAINID) => {
            if (!requireSpec(frame, .istanbul)) return;
            if (!chargeStaticGas(frame, .CHAINID)) return;
            return environment.chainid(frame);
        },
        @intFromEnum(Opcode.SELFBALANCE) => {
            if (!requireSpec(frame, .istanbul)) return;
            if (!chargeStaticGas(frame, .SELFBALANCE)) return;
            return environment.selfbalance(frame);
        },
        @intFromEnum(Opcode.BASEFEE) => {
            if (!requireSpec(frame, .london)) return;
            if (!chargeStaticGas(frame, .BASEFEE)) return;
            return environment.basefee(frame);
        },
        @intFromEnum(Opcode.BLOBHASH) => {
            if (!requireSpec(frame, .cancun)) return;
            if (!chargeStaticGas(frame, .BLOBHASH)) return;
            return environment.blobhash(frame);
        },
        @intFromEnum(Opcode.BLOBBASEFEE) => {
            if (!requireSpec(frame, .cancun)) return;
            if (!chargeStaticGas(frame, .BLOBBASEFEE)) return;
            return environment.blobbasefee(frame);
        },
        @intFromEnum(Opcode.POP) => {
            if (!chargeStaticGas(frame, .POP)) return;
            return stack.pop(frame);
        },
        @intFromEnum(Opcode.MLOAD) => {
            if (!chargeStaticGas(frame, .MLOAD)) return;
            return memory.mload(frame);
        },
        @intFromEnum(Opcode.MSTORE) => {
            if (!chargeStaticGas(frame, .MSTORE)) return;
            return memory.mstore(frame);
        },
        @intFromEnum(Opcode.MSTORE8) => {
            if (!chargeStaticGas(frame, .MSTORE8)) return;
            return memory.mstore8(frame);
        },
        @intFromEnum(Opcode.SLOAD) => {
            if (!chargeStaticGas(frame, .SLOAD)) return;
            return storage.sload(frame);
        },
        @intFromEnum(Opcode.SSTORE) => storage.sstore(frame),
        @intFromEnum(Opcode.JUMP) => {
            if (!chargeStaticGas(frame, .JUMP)) return;
            return flow.jump(frame);
        },
        @intFromEnum(Opcode.JUMPI) => {
            if (!chargeStaticGas(frame, .JUMPI)) return;
            return flow.jumpi(frame);
        },
        @intFromEnum(Opcode.PC) => {
            if (!chargeStaticGas(frame, .PC)) return;
            return flow.pc(frame);
        },
        @intFromEnum(Opcode.MSIZE) => {
            if (!chargeStaticGas(frame, .MSIZE)) return;
            return memory.msize(frame);
        },
        @intFromEnum(Opcode.GAS) => {
            if (!chargeStaticGas(frame, .GAS)) return;
            return environment.gas(frame);
        },
        @intFromEnum(Opcode.JUMPDEST) => {
            _ = chargeStaticGas(frame, .JUMPDEST);
            return;
        },
        @intFromEnum(Opcode.TLOAD) => {
            if (!requireSpec(frame, .cancun)) return;
            if (!chargeStaticGas(frame, .TLOAD)) return;
            return storage.tload(frame);
        },
        @intFromEnum(Opcode.TSTORE) => {
            if (!requireSpec(frame, .cancun)) return;
            if (!chargeStaticGas(frame, .TSTORE)) return;
            return storage.tstore(frame);
        },
        @intFromEnum(Opcode.MCOPY) => {
            if (!requireSpec(frame, .cancun)) return;
            if (!chargeStaticGas(frame, .MCOPY)) return;
            return memory.mcopy(frame);
        },
        @intFromEnum(Opcode.PUSH0) => {
            if (!requireSpec(frame, .shanghai)) return;
            if (!chargeStaticGas(frame, .PUSH0)) return;
            return stack.push0(frame);
        },
        inline @intFromEnum(Opcode.PUSH1)...@intFromEnum(Opcode.PUSH32) => |opcode| {
            if (!chargeGas(frame, 3)) return;
            return stack.push(frame, opcode - @intFromEnum(Opcode.PUSH0));
        },
        inline @intFromEnum(Opcode.DUP1)...@intFromEnum(Opcode.DUP16) => |opcode| {
            if (!chargeGas(frame, 3)) return;
            return stack.dup(frame, opcode - @intFromEnum(Opcode.DUP1) + 1);
        },
        inline @intFromEnum(Opcode.SWAP1)...@intFromEnum(Opcode.SWAP16) => |opcode| {
            if (!chargeGas(frame, 3)) return;
            return stack.swap(frame, opcode - @intFromEnum(Opcode.SWAP1) + 1);
        },
        @intFromEnum(Opcode.DUPN) => {
            if (!requireSpec(frame, .amsterdam)) return;
            if (!chargeStaticGas(frame, .DUPN)) return;
            return stack.dupn(frame);
        },
        @intFromEnum(Opcode.SWAPN) => {
            if (!requireSpec(frame, .amsterdam)) return;
            if (!chargeStaticGas(frame, .SWAPN)) return;
            return stack.swapn(frame);
        },
        @intFromEnum(Opcode.EXCHANGE) => {
            if (!requireSpec(frame, .amsterdam)) return;
            if (!chargeStaticGas(frame, .EXCHANGE)) return;
            return stack.exchange(frame);
        },
        inline @intFromEnum(Opcode.LOG0)...@intFromEnum(Opcode.LOG4) => |opcode| {
            const topics: u8 = opcode - @intFromEnum(Opcode.LOG0);
            if (!chargeGas(frame, 375 * (@as(i64, topics) + 1))) return;
            return logging.log(frame, topics);
        },
        @intFromEnum(Opcode.CREATE) => {
            if (!chargeStaticGas(frame, .CREATE)) return;
            return system.create(frame);
        },
        @intFromEnum(Opcode.CALL) => {
            if (!chargeStaticGas(frame, .CALL)) return;
            return system.callByOp(frame, .CALL);
        },
        @intFromEnum(Opcode.CALLCODE) => {
            if (!chargeStaticGas(frame, .CALLCODE)) return;
            return system.callByOp(frame, .CALLCODE);
        },
        @intFromEnum(Opcode.RETURN) => system.ret(frame),
        @intFromEnum(Opcode.DELEGATECALL) => {
            if (!requireSpec(frame, .homestead)) return;
            if (!chargeStaticGas(frame, .DELEGATECALL)) return;
            return system.callByOp(frame, .DELEGATECALL);
        },
        @intFromEnum(Opcode.CREATE2) => {
            if (!requireSpec(frame, .constantinople)) return;
            if (!chargeStaticGas(frame, .CREATE2)) return;
            return system.create2(frame);
        },
        @intFromEnum(Opcode.STATICCALL) => {
            if (!requireSpec(frame, .byzantium)) return;
            if (!chargeStaticGas(frame, .STATICCALL)) return;
            return system.callByOp(frame, .STATICCALL);
        },
        @intFromEnum(Opcode.REVERT) => {
            if (!requireSpec(frame, .byzantium)) return;
            return system.revert(frame);
        },
        @intFromEnum(Opcode.INVALID) => system.invalid(frame),
        @intFromEnum(Opcode.SELFDESTRUCT) => {
            if (!chargeStaticGas(frame, .SELFDESTRUCT)) return;
            return system.selfdestruct(frame);
        },
        else => error.UnknownOpcode,
    };
}

inline fn chargeStaticGas(frame: *CallFrame, comptime opcode: Opcode) bool {
    return chargeGas(frame, staticGasForSpec(frame.spec, opcode));
}

inline fn chargeGas(frame: *CallFrame, gas: i64) bool {
    frame.trackGas(gas);
    return frame.status == .running;
}

fn staticGasForSpec(spec: evmz.Spec, comptime opcode: Opcode) i64 {
    return switch (opcode) {
        .BALANCE => if (spec.isImpl(.berlin))
            100
        else if (spec.isImpl(.istanbul))
            700
        else if (spec.isImpl(.tangerine_whistle))
            400
        else
            20,
        .EXTCODESIZE, .EXTCODECOPY => if (spec.isImpl(.berlin))
            100
        else if (spec.isImpl(.tangerine_whistle))
            700
        else
            20,
        .EXTCODEHASH => if (spec.isImpl(.berlin))
            100
        else if (spec.isImpl(.istanbul))
            700
        else
            400,
        .SLOAD => if (spec.isImpl(.berlin))
            100
        else if (spec.isImpl(.istanbul))
            800
        else if (spec.isImpl(.tangerine_whistle))
            200
        else
            50,
        .CREATE, .CREATE2 => if (spec.isImpl(.amsterdam))
            tx_gas.amsterdam_create_access_cost
        else
            @intCast(staticGas(opcode)),
        .SELFDESTRUCT => if (spec.isImpl(.tangerine_whistle)) 5000 else 0,
        else => @intCast(staticGas(opcode)),
    };
}

inline fn requireSpec(frame: *CallFrame, spec: evmz.Spec) bool {
    if (frame.spec.isImpl(spec)) return true;
    frame.failWithStatus(.invalid);
    return false;
}
