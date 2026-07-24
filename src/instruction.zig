const opcode_info = @import("opcode.zig");
const Opcode = opcode_info.Opcode;
const std = @import("std");
const ExactSpec = @import("./spec.zig").Spec;
const instruction_table = @import("./instruction/table.zig");
const evmz = @import("./evm.zig");
const interpreter = @import("./Interpreter.zig");
const trace = @import("./trace.zig");

const Interpreter = interpreter.Interpreter;
const CallFrame = interpreter.CallFrame;

pub const call_value_cost = 9000;
pub const account_creation_cost = 25000;

// [EIP-2929](https://eips.ethereum.org/EIPS/eip-2929)
pub const cold_sload_cost = 2100;
pub const cold_account_access_cost = 2600;
pub const warm_storage_read_cost = 100;

// warm_storage_read_cost is count before instruction execution
pub const cold_account_access_gas = cold_account_access_cost - warm_storage_read_cost;
pub const cold_sload_gas = cold_sload_cost - warm_storage_read_cost;

pub const Target = instruction_table.Target;
pub const Entry = instruction_table.Entry;
pub const Table = instruction_table.Table;
pub const Spec = instruction_table.Spec;

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

test "fork-gated opcodes are invalid before their activation fork" {
    try evmz.t.expectBytecodeStatusByRevision(.{.RETURNDATASIZE}, .homestead, .invalid);
    try evmz.t.expectBytecodeStatusByRevision(.{.RETURNDATASIZE}, .byzantium, .success);

    try evmz.t.expectBytecodeStatusByRevision(.{.BASEFEE}, .berlin, .invalid);
    try evmz.t.expectBytecodeStatusByRevision(.{.BASEFEE}, .london, .success);

    try evmz.t.expectBytecodeStatusByRevision(.{.PUSH0}, .london, .invalid);
    try evmz.t.expectBytecodeStatusByRevision(.{.PUSH0}, .shanghai, .success);

    try evmz.t.expectBytecodeStatusByRevision(.{.BLOBBASEFEE}, .shanghai, .invalid);
    try evmz.t.expectBytecodeStatusByRevision(.{.BLOBBASEFEE}, .cancun, .success);
    try evmz.t.expectBytecodeStatusByRevision(.{ .PUSH1, 0x00, .BLOBHASH }, .shanghai, .invalid);
    try evmz.t.expectBytecodeStatusByRevision(.{ .PUSH1, 0x00, .BLOBHASH }, .cancun, .success);

    try evmz.t.expectBytecodeStatusByRevision(.{.SLOTNUM}, .osaka, .invalid);
    try evmz.t.expectBytecodeStatusByRevision(.{.SLOTNUM}, .amsterdam, .success);

    try evmz.t.expectBytecodeStatusByRevision(.{
        .PUSH1, 0x01,   .PUSH0, .PUSH0, .PUSH0, .PUSH0,
        .PUSH0, .PUSH0, .PUSH0, .PUSH0, .PUSH0, .PUSH0,
        .PUSH0, .PUSH0, .PUSH0, .PUSH0, .PUSH0, .PUSH0,
        .DUPN,  0x80,
    }, .osaka, .invalid);
    try evmz.t.expectBytecodeStatusByRevision(.{
        .PUSH1, 0x01,   .PUSH0, .PUSH0, .PUSH0, .PUSH0,
        .PUSH0, .PUSH0, .PUSH0, .PUSH0, .PUSH0, .PUSH0,
        .PUSH0, .PUSH0, .PUSH0, .PUSH0, .PUSH0, .PUSH0,
        .DUPN,  0x80,
    }, .amsterdam, .success);
}

test "fork-dependent static gas follows legacy schedules" {
    try std.testing.expectEqual(@as(i64, 20), staticGasAt(.frontier, .BALANCE));
    try std.testing.expectEqual(@as(i64, 400), staticGasAt(.byzantium, .BALANCE));
    try std.testing.expectEqual(@as(i64, 700), staticGasAt(.istanbul, .BALANCE));
    try std.testing.expectEqual(@as(i64, 100), staticGasAt(.berlin, .BALANCE));

    try std.testing.expectEqual(@as(i64, 20), staticGasAt(.homestead, .EXTCODECOPY));
    try std.testing.expectEqual(@as(i64, 700), staticGasAt(.byzantium, .EXTCODECOPY));
    try std.testing.expectEqual(@as(i64, 400), staticGasAt(.petersburg, .EXTCODEHASH));
    try std.testing.expectEqual(@as(i64, 700), staticGasAt(.istanbul, .EXTCODEHASH));

    try std.testing.expectEqual(@as(i64, 50), staticGasAt(.frontier, .SLOAD));
    try std.testing.expectEqual(@as(i64, 200), staticGasAt(.byzantium, .SLOAD));
    try std.testing.expectEqual(@as(i64, 800), staticGasAt(.istanbul, .SLOAD));

    try std.testing.expectEqual(@as(i64, 0), staticGasAt(.homestead, .SELFDESTRUCT));
    try std.testing.expectEqual(@as(i64, 5000), staticGasAt(.tangerine_whistle, .SELFDESTRUCT));
}

test "execute charges dynamic and fixed static gas" {
    try std.testing.expectEqual(@as(i64, 99_980), try executeBalance(evmz.eth.frontier));
    try std.testing.expectEqual(@as(i64, 99_300), try executeBalance(evmz.eth.istanbul));
}

test "execute uses exact instruction availability" {
    try expectOpcodeStatus(evmz.eth.frontier, .BASEFEE, .invalid_opcode);
}

test "execute uses resolved dispatch target for hot opcodes" {
    const spec = instructionOverrideSpec(.ADD, .invalid);

    var mock_host = evmz.t.MockHost.init(std.testing.allocator, null);
    defer mock_host.deinit();
    var host = mock_host.host();
    var msg = evmz.t.defaultMessage();
    const code = [_]u8{@intFromEnum(Opcode.ADD)};

    var frame = try Interpreter(spec).OwnedCallFrame.init(std.testing.allocator, .{
        .host = &host,
        .msg = &msg,
        .code = &code,
    });
    defer frame.deinit();

    try frame.frame.stack.push(2);
    try frame.frame.stack.push(3);
    try Instruction(spec).execute(@intFromEnum(Opcode.ADD), frame.frame);
    try std.testing.expectEqual(interpreter.FrameStatus.invalid_opcode, frame.frame.status);
}

test "untraced interpreter raw fallback respects resolved dispatch target" {
    const spec = instructionOverrideSpec(.ADD, .invalid);

    var mock_host = evmz.t.MockHost.init(std.testing.allocator, null);
    defer mock_host.deinit();
    var host = mock_host.host();
    var msg = evmz.t.defaultMessage();
    const code = [_]u8{
        @intFromEnum(Opcode.PUSH1),
        2,
        @intFromEnum(Opcode.PUSH1),
        3,
        @intFromEnum(Opcode.ADD),
    };

    var frame = try Interpreter(spec).OwnedCallFrame.init(std.testing.allocator, .{
        .host = &host,
        .msg = &msg,
        .code = &code,
    });
    defer frame.deinit();
    var intpr = frame.interpreter();

    const result = try intpr.execute();

    try std.testing.expectEqual(interpreter.Status.invalid, result.status);
}

test "untraced interpreter tail dispatch respects resolved dispatch target" {
    const spec = instructionOverrideSpec(.ADD, .invalid);

    var mock_host = evmz.t.MockHost.init(std.testing.allocator, null);
    defer mock_host.deinit();
    var host = mock_host.host();
    var msg = evmz.t.defaultMessage();
    const code = [_]u8{
        @intFromEnum(Opcode.PUSH1),
        2,
        @intFromEnum(Opcode.PUSH1),
        3,
        @intFromEnum(Opcode.ADD),
    };
    var bytecode = try evmz.Bytecode.init(std.testing.allocator, &code);
    defer bytecode.deinit(std.testing.allocator);

    var frame = try Interpreter(spec).OwnedCallFrame.init(std.testing.allocator, .{
        .host = &host,
        .msg = &msg,
        .bytecode = &bytecode,
    });
    defer frame.deinit();
    var intpr = frame.interpreter();

    const result = try intpr.execute();

    try std.testing.expectEqual(interpreter.Status.invalid, result.status);
}

test "execute calls custom dispatch target directly" {
    const CustomHandler = struct {
        pub inline fn execute(comptime Instructions: type, frame: *CallFrame) anyerror!void {
            if (!Instructions.chargeStaticGas(frame, .ADD)) return;
            return frame.stack.push(42);
        }
    };
    const spec = instructionOverrideSpec(.ADD, .{ .custom = CustomHandler });

    var mock_host = evmz.t.MockHost.init(std.testing.allocator, null);
    defer mock_host.deinit();
    var host = mock_host.host();
    var msg = evmz.t.defaultMessage();
    const code = [_]u8{@intFromEnum(Opcode.ADD)};

    var frame = try Interpreter(spec).OwnedCallFrame.init(std.testing.allocator, .{
        .host = &host,
        .msg = &msg,
        .code = &code,
    });
    defer frame.deinit();

    try Instruction(spec).execute(@intFromEnum(Opcode.ADD), frame.frame);

    try std.testing.expectEqual(interpreter.FrameStatus.running, frame.frame.status);
    try std.testing.expectEqual(@as(u256, 42), frame.frame.stack.pop());
    try std.testing.expectEqual(msg.gas - staticGas(.ADD), frame.frame.gas_left);
}

test "captured custom MSTORE handler retains inherited trace effects" {
    const CustomMstore = struct {
        pub inline fn execute(comptime Instructions: type, frame: *CallFrame) anyerror!void {
            if (!Instructions.chargeStaticGas(frame, .MSTORE)) return;
            return memory.mstore(frame);
        }
    };
    const spec = instructionOverrideSpec(.MSTORE, .{ .custom = CustomMstore });
    const code = evmz.t.bytecode(.{ .PUSH1, 0x2a, .PUSH0, .MSTORE, .STOP });

    var mock_host = evmz.t.MockHost.init(std.testing.allocator, null);
    defer mock_host.deinit();
    var host = mock_host.host();
    var msg = evmz.t.defaultMessage();
    msg.gas = 100;
    var frame = try Interpreter(spec).OwnedCallFrame.init(std.testing.allocator, .{
        .host = &host,
        .msg = &msg,
        .code = &code,
    });
    defer frame.deinit();
    var intpr = frame.interpreter();
    var tape = trace.TraceTape.initGrowable(std.testing.allocator);
    defer tape.deinit();

    const captured = try intpr.capture(&tape, .{ .memory = .writes });
    defer tape.resolve(captured.span) catch unreachable;
    try std.testing.expectEqual(interpreter.Status.success, captured.result.status);

    var cursor = trace.TraceCursor.init(captured.span);
    cursor.enterFrame(captured.span.frames[0]);
    const writes = for (captured.span.steps) |row| {
        cursor.finishStep(row);
        if (row.opcode == @intFromEnum(Opcode.MSTORE)) break try cursor.memoryWrites();
    } else unreachable;
    try std.testing.expectEqual(@as(usize, 1), writes.len);
    const bytes = cursor.memoryWriteBytes(writes[0]);
    try std.testing.expectEqual(@as(usize, 32), bytes.len);
    try std.testing.expectEqual(@as(u8, 0x2a), bytes[31]);
}

fn instructionOverrideSpec(
    comptime opcode: Opcode,
    comptime target: instruction_table.Target,
) evmz.eth.Spec {
    var exact = evmz.eth.amsterdam.instruction;
    exact.table[@intFromEnum(opcode)].target = target;
    return evmz.eth.amsterdam.extend(.{
        .instruction = exact,
    });
}

fn instructionGasSpec(comptime opcode: Opcode, comptime gas: i64) evmz.eth.Spec {
    var exact = evmz.eth.frontier.instruction;
    exact.table[@intFromEnum(opcode)].static_gas = gas;
    return evmz.eth.frontier.extend(.{
        .instruction = exact,
    });
}

fn staticGasAt(comptime revision: evmz.eth.Revision, comptime opcode: Opcode) i64 {
    return evmz.eth.specAt(revision).instruction.entry(@intFromEnum(opcode)).static_gas;
}

fn executeBalance(comptime spec: evmz.eth.Spec) !i64 {
    var mock_host = evmz.t.MockHost.init(std.testing.allocator, null);
    defer mock_host.deinit();
    var host = mock_host.host();
    var msg = evmz.t.defaultMessage();
    const code = [_]u8{@intFromEnum(Opcode.BALANCE)};

    var frame = try Interpreter(spec).OwnedCallFrame.init(std.testing.allocator, .{
        .host = &host,
        .msg = &msg,
        .code = &code,
    });
    defer frame.deinit();

    try frame.frame.stack.push(0);
    try Instruction(spec).execute(@intFromEnum(Opcode.BALANCE), frame.frame);
    try std.testing.expectEqual(interpreter.FrameStatus.running, frame.frame.status);
    return frame.frame.gas_left;
}

fn expectOpcodeStatus(comptime spec: evmz.eth.Spec, opcode: Opcode, expected: interpreter.FrameStatus) !void {
    var mock_host = evmz.t.MockHost.init(std.testing.allocator, null);
    defer mock_host.deinit();
    var host = mock_host.host();
    var msg = evmz.t.defaultMessage();
    const code = [_]u8{@intFromEnum(opcode)};

    var frame = try Interpreter(spec).OwnedCallFrame.init(std.testing.allocator, .{
        .host = &host,
        .msg = &msg,
        .code = &code,
    });
    defer frame.deinit();

    try Instruction(spec).execute(@intFromEnum(opcode), frame.frame);
    try std.testing.expectEqual(expected, frame.frame.status);
}

test "static gas helper uses resolved rule gas" {
    var mock_host = evmz.t.MockHost.init(std.testing.allocator, null);
    defer mock_host.deinit();
    var host = mock_host.host();
    var msg = evmz.t.defaultMessage();
    const code = [_]u8{@intFromEnum(Opcode.CALL)};

    var frame = try evmz.Vm(evmz.eth.frontier).Interpreter.OwnedCallFrame.init(std.testing.allocator, .{
        .host = &host,
        .msg = &msg,
        .code = &code,
    });
    defer frame.deinit();

    try std.testing.expectEqual(@as(i64, 7), Instruction(instructionGasSpec(.CALL, 7)).staticGasForFrame(frame.frame, .CALL));
    try std.testing.expectEqual(@as(i64, 11), Instruction(instructionGasSpec(.CALL, 11)).staticGasForFrame(frame.frame, .CALL));
}

pub fn staticGas(opcode: Opcode) u16 {
    return opcode_info.table[@intFromEnum(opcode)].static_gas;
}

const UnknownBuiltinHandler = struct {
    pub inline fn execute(comptime Instructions: type, frame: *CallFrame) anyerror!void {
        _ = Instructions;
        _ = frame;
        return error.UnknownOpcode;
    }
};

const InvalidBuiltinHandler = struct {
    pub inline fn execute(comptime Instructions: type, frame: *CallFrame) anyerror!void {
        _ = Instructions;
        return system.invalid(frame);
    }
};

fn NoGasHandler(comptime run: anytype) type {
    const run_fn = run;
    return struct {
        pub inline fn execute(comptime Instructions: type, frame: *CallFrame) anyerror!void {
            _ = Instructions;
            return run_fn(frame);
        }
    };
}

fn ChargeHandler(comptime opcode: Opcode, comptime run: anytype) type {
    const op = opcode;
    const run_fn = run;
    return struct {
        pub inline fn execute(comptime Instructions: type, frame: *CallFrame) anyerror!void {
            if (!Instructions.chargeStaticGas(frame, op)) return;
            return run_fn(frame);
        }
    };
}

fn RequireChargeHandler(comptime opcode: Opcode, comptime run: anytype) type {
    const op = opcode;
    const run_fn = run;
    return struct {
        pub inline fn execute(comptime Instructions: type, frame: *CallFrame) anyerror!void {
            if (!Instructions.requireOpcode(frame, op)) return;
            if (!Instructions.chargeStaticGas(frame, op)) return;
            return run_fn(frame);
        }
    };
}

fn PushHandler(comptime opcode: Opcode) type {
    const op = opcode;
    return struct {
        pub inline fn execute(comptime Instructions: type, frame: *CallFrame) anyerror!void {
            if (!Instructions.requireOpcode(frame, op)) return;
            if (!Instructions.chargeStaticGas(frame, op)) return;
            return stack.push(frame, @intFromEnum(op) - @intFromEnum(Opcode.PUSH0));
        }
    };
}

fn DupHandler(comptime opcode: Opcode) type {
    const op = opcode;
    return struct {
        pub inline fn execute(comptime Instructions: type, frame: *CallFrame) anyerror!void {
            if (!Instructions.requireOpcode(frame, op)) return;
            if (!Instructions.chargeStaticGas(frame, op)) return;
            return stack.dup(frame, @intFromEnum(op) - @intFromEnum(Opcode.DUP1) + 1);
        }
    };
}

fn SwapHandler(comptime opcode: Opcode) type {
    const op = opcode;
    return struct {
        pub inline fn execute(comptime Instructions: type, frame: *CallFrame) anyerror!void {
            if (!Instructions.requireOpcode(frame, op)) return;
            if (!Instructions.chargeStaticGas(frame, op)) return;
            return stack.swap(frame, @intFromEnum(op) - @intFromEnum(Opcode.SWAP1) + 1);
        }
    };
}

fn LogHandler(comptime opcode: Opcode) type {
    const op = opcode;
    return struct {
        pub inline fn execute(comptime Instructions: type, frame: *CallFrame) anyerror!void {
            const topics: u8 = @intFromEnum(op) - @intFromEnum(Opcode.LOG0);
            if (!Instructions.requireOpcode(frame, op)) return;
            if (!Instructions.chargeStaticGas(frame, op)) return;
            return logging.log(frame, topics);
        }
    };
}

const ExpHandler = struct {
    pub inline fn execute(comptime Instructions: type, frame: *CallFrame) anyerror!void {
        if (!Instructions.chargeStaticGas(frame, .EXP)) return;
        return arithmetic.bind(Instructions.specification).exp(frame);
    }
};

const BalanceHandler = struct {
    pub inline fn execute(comptime Instructions: type, frame: *CallFrame) anyerror!void {
        if (!Instructions.chargeStaticGas(frame, .BALANCE)) return;
        return environment.bind(Instructions.specification).balance(frame);
    }
};

const ExtCodeSizeHandler = struct {
    pub inline fn execute(comptime Instructions: type, frame: *CallFrame) anyerror!void {
        if (!Instructions.chargeStaticGas(frame, .EXTCODESIZE)) return;
        return environment.bind(Instructions.specification).extcodesize(frame);
    }
};

const ExtCodeCopyHandler = struct {
    pub inline fn execute(comptime Instructions: type, frame: *CallFrame) anyerror!void {
        if (!Instructions.chargeStaticGas(frame, .EXTCODECOPY)) return;
        return environment.bind(Instructions.specification).extcodecopy(frame);
    }
};

const ExtCodeHashHandler = struct {
    pub inline fn execute(comptime Instructions: type, frame: *CallFrame) anyerror!void {
        if (!Instructions.requireOpcode(frame, .EXTCODEHASH)) return;
        if (!Instructions.chargeStaticGas(frame, .EXTCODEHASH)) return;
        return environment.bind(Instructions.specification).extcodehash(frame);
    }
};

const JumpDestHandler = struct {
    pub inline fn execute(comptime Instructions: type, frame: *CallFrame) anyerror!void {
        _ = Instructions.chargeStaticGas(frame, .JUMPDEST);
        return;
    }
};

const SLoadHandler = struct {
    pub inline fn execute(comptime Instructions: type, frame: *CallFrame) anyerror!void {
        if (!Instructions.chargeStaticGas(frame, .SLOAD)) return;
        return storage.bind(Instructions.specification).sload(frame);
    }
};

const SStoreHandler = struct {
    pub inline fn execute(comptime Instructions: type, frame: *CallFrame) anyerror!void {
        return storage.bind(Instructions.specification).sstore(frame);
    }
};

const DupNHandler = struct {
    pub inline fn execute(comptime Instructions: type, frame: *CallFrame) anyerror!void {
        if (!Instructions.requireOpcode(frame, .DUPN)) return;
        if (!Instructions.chargeStaticGas(frame, .DUPN)) return;
        return stack.dupn(frame);
    }
};

const SwapNHandler = struct {
    pub inline fn execute(comptime Instructions: type, frame: *CallFrame) anyerror!void {
        if (!Instructions.requireOpcode(frame, .SWAPN)) return;
        if (!Instructions.chargeStaticGas(frame, .SWAPN)) return;
        return stack.swapn(frame);
    }
};

const ExchangeHandler = struct {
    pub inline fn execute(comptime Instructions: type, frame: *CallFrame) anyerror!void {
        if (!Instructions.requireOpcode(frame, .EXCHANGE)) return;
        if (!Instructions.chargeStaticGas(frame, .EXCHANGE)) return;
        return stack.exchange(frame);
    }
};

const CreateHandler = struct {
    pub inline fn execute(comptime Instructions: type, frame: *CallFrame) anyerror!void {
        if (!Instructions.chargeStaticGas(frame, .CREATE)) return;
        return system.bind(Instructions.specification).create(frame);
    }
};

fn CallByOpHandler(comptime opcode: Opcode) type {
    const op = opcode;
    return struct {
        pub inline fn execute(comptime Instructions: type, frame: *CallFrame) anyerror!void {
            if (comptime op == .DELEGATECALL or op == .STATICCALL) {
                if (!Instructions.requireOpcode(frame, op)) return;
            }
            if (!Instructions.chargeStaticGas(frame, op)) return;
            return system.bind(Instructions.specification).callByOp(frame, op);
        }
    };
}

const ReturnHandler = NoGasHandler(system.ret);

const Create2Handler = struct {
    pub inline fn execute(comptime Instructions: type, frame: *CallFrame) anyerror!void {
        if (!Instructions.requireOpcode(frame, .CREATE2)) return;
        if (!Instructions.chargeStaticGas(frame, .CREATE2)) return;
        return system.bind(Instructions.specification).create2(frame);
    }
};

const RevertHandler = struct {
    pub inline fn execute(comptime Instructions: type, frame: *CallFrame) anyerror!void {
        if (!Instructions.requireOpcode(frame, .REVERT)) return;
        return system.revert(frame);
    }
};

const SelfDestructHandler = struct {
    pub inline fn execute(comptime Instructions: type, frame: *CallFrame) anyerror!void {
        if (!Instructions.chargeStaticGas(frame, .SELFDESTRUCT)) return;
        return system.bind(Instructions.specification).selfdestruct(frame);
    }
};

const BuiltinInstruction = struct {
    opcode: Opcode,
    handler: type,
};

const builtin_instruction_catalog = [_]BuiltinInstruction{
    .{ .opcode = .STOP, .handler = NoGasHandler(system.stop) },
    .{ .opcode = .ADD, .handler = ChargeHandler(.ADD, arithmetic.add) },
    .{ .opcode = .MUL, .handler = ChargeHandler(.MUL, arithmetic.mul) },
    .{ .opcode = .SUB, .handler = ChargeHandler(.SUB, arithmetic.sub) },
    .{ .opcode = .DIV, .handler = ChargeHandler(.DIV, arithmetic.div) },
    .{ .opcode = .SDIV, .handler = ChargeHandler(.SDIV, arithmetic.sdiv) },
    .{ .opcode = .MOD, .handler = ChargeHandler(.MOD, arithmetic.mod) },
    .{ .opcode = .SMOD, .handler = ChargeHandler(.SMOD, arithmetic.smod) },
    .{ .opcode = .ADDMOD, .handler = ChargeHandler(.ADDMOD, arithmetic.addmod) },
    .{ .opcode = .MULMOD, .handler = ChargeHandler(.MULMOD, arithmetic.mulmod) },
    .{ .opcode = .EXP, .handler = ExpHandler },
    .{ .opcode = .SIGNEXTEND, .handler = ChargeHandler(.SIGNEXTEND, arithmetic.signextend) },
    .{ .opcode = .LT, .handler = ChargeHandler(.LT, logic.lt) },
    .{ .opcode = .GT, .handler = ChargeHandler(.GT, logic.gt) },
    .{ .opcode = .SLT, .handler = ChargeHandler(.SLT, logic.slt) },
    .{ .opcode = .SGT, .handler = ChargeHandler(.SGT, logic.sgt) },
    .{ .opcode = .EQ, .handler = ChargeHandler(.EQ, logic.eq) },
    .{ .opcode = .ISZERO, .handler = ChargeHandler(.ISZERO, logic.iszero) },
    .{ .opcode = .AND, .handler = ChargeHandler(.AND, logic.bitAnd) },
    .{ .opcode = .OR, .handler = ChargeHandler(.OR, logic.bitOr) },
    .{ .opcode = .XOR, .handler = ChargeHandler(.XOR, logic.bitXor) },
    .{ .opcode = .NOT, .handler = ChargeHandler(.NOT, logic.bitNot) },
    .{ .opcode = .BYTE, .handler = ChargeHandler(.BYTE, logic.byte) },
    .{ .opcode = .SHL, .handler = RequireChargeHandler(.SHL, logic.shl) },
    .{ .opcode = .SHR, .handler = RequireChargeHandler(.SHR, logic.shr) },
    .{ .opcode = .SAR, .handler = RequireChargeHandler(.SAR, logic.sar) },
    .{ .opcode = .CLZ, .handler = RequireChargeHandler(.CLZ, logic.clz) },
    .{ .opcode = .KECCAK256, .handler = ChargeHandler(.KECCAK256, arithmetic.keccak256) },
    .{ .opcode = .ADDRESS, .handler = ChargeHandler(.ADDRESS, environment.address) },
    .{ .opcode = .BALANCE, .handler = BalanceHandler },
    .{ .opcode = .ORIGIN, .handler = ChargeHandler(.ORIGIN, environment.origin) },
    .{ .opcode = .CALLER, .handler = ChargeHandler(.CALLER, environment.caller) },
    .{ .opcode = .CALLVALUE, .handler = ChargeHandler(.CALLVALUE, environment.callvalue) },
    .{ .opcode = .CALLDATALOAD, .handler = ChargeHandler(.CALLDATALOAD, environment.calldataload) },
    .{ .opcode = .CALLDATASIZE, .handler = ChargeHandler(.CALLDATASIZE, environment.calldatasize) },
    .{ .opcode = .CALLDATACOPY, .handler = ChargeHandler(.CALLDATACOPY, environment.calldatacopy) },
    .{ .opcode = .CODESIZE, .handler = ChargeHandler(.CODESIZE, environment.codesize) },
    .{ .opcode = .CODECOPY, .handler = ChargeHandler(.CODECOPY, environment.codecopy) },
    .{ .opcode = .GASPRICE, .handler = ChargeHandler(.GASPRICE, environment.gasprice) },
    .{ .opcode = .EXTCODESIZE, .handler = ExtCodeSizeHandler },
    .{ .opcode = .EXTCODECOPY, .handler = ExtCodeCopyHandler },
    .{ .opcode = .RETURNDATASIZE, .handler = RequireChargeHandler(.RETURNDATASIZE, environment.returndatasize) },
    .{ .opcode = .RETURNDATACOPY, .handler = RequireChargeHandler(.RETURNDATACOPY, environment.returndatacopy) },
    .{ .opcode = .EXTCODEHASH, .handler = ExtCodeHashHandler },
    .{ .opcode = .BLOCKHASH, .handler = ChargeHandler(.BLOCKHASH, environment.blockhash) },
    .{ .opcode = .COINBASE, .handler = ChargeHandler(.COINBASE, environment.coinbase) },
    .{ .opcode = .TIMESTAMP, .handler = ChargeHandler(.TIMESTAMP, environment.timestamp) },
    .{ .opcode = .NUMBER, .handler = ChargeHandler(.NUMBER, environment.number) },
    .{ .opcode = .PREVRANDAO, .handler = ChargeHandler(.PREVRANDAO, environment.prevrandao) },
    .{ .opcode = .GASLIMIT, .handler = ChargeHandler(.GASLIMIT, environment.gaslimit) },
    .{ .opcode = .CHAINID, .handler = RequireChargeHandler(.CHAINID, environment.chainid) },
    .{ .opcode = .SELFBALANCE, .handler = RequireChargeHandler(.SELFBALANCE, environment.selfbalance) },
    .{ .opcode = .BASEFEE, .handler = RequireChargeHandler(.BASEFEE, environment.basefee) },
    .{ .opcode = .BLOBHASH, .handler = RequireChargeHandler(.BLOBHASH, environment.blobhash) },
    .{ .opcode = .BLOBBASEFEE, .handler = RequireChargeHandler(.BLOBBASEFEE, environment.blobbasefee) },
    .{ .opcode = .SLOTNUM, .handler = RequireChargeHandler(.SLOTNUM, environment.slotnum) },
    .{ .opcode = .POP, .handler = ChargeHandler(.POP, stack.pop) },
    .{ .opcode = .MLOAD, .handler = ChargeHandler(.MLOAD, memory.mload) },
    .{ .opcode = .MSTORE, .handler = ChargeHandler(.MSTORE, memory.mstore) },
    .{ .opcode = .MSTORE8, .handler = ChargeHandler(.MSTORE8, memory.mstore8) },
    .{ .opcode = .SLOAD, .handler = SLoadHandler },
    .{ .opcode = .SSTORE, .handler = SStoreHandler },
    .{ .opcode = .JUMP, .handler = ChargeHandler(.JUMP, flow.jump) },
    .{ .opcode = .JUMPI, .handler = ChargeHandler(.JUMPI, flow.jumpi) },
    .{ .opcode = .PC, .handler = ChargeHandler(.PC, flow.pc) },
    .{ .opcode = .MSIZE, .handler = ChargeHandler(.MSIZE, memory.msize) },
    .{ .opcode = .GAS, .handler = ChargeHandler(.GAS, environment.gas) },
    .{ .opcode = .JUMPDEST, .handler = JumpDestHandler },
    .{ .opcode = .TLOAD, .handler = RequireChargeHandler(.TLOAD, storage.tload) },
    .{ .opcode = .TSTORE, .handler = RequireChargeHandler(.TSTORE, storage.tstore) },
    .{ .opcode = .MCOPY, .handler = RequireChargeHandler(.MCOPY, memory.mcopy) },
    .{ .opcode = .PUSH0, .handler = RequireChargeHandler(.PUSH0, stack.push0) },
    .{ .opcode = .DUPN, .handler = DupNHandler },
    .{ .opcode = .SWAPN, .handler = SwapNHandler },
    .{ .opcode = .EXCHANGE, .handler = ExchangeHandler },
    .{ .opcode = .CREATE, .handler = CreateHandler },
    .{ .opcode = .CALL, .handler = CallByOpHandler(.CALL) },
    .{ .opcode = .CALLCODE, .handler = CallByOpHandler(.CALLCODE) },
    .{ .opcode = .RETURN, .handler = ReturnHandler },
    .{ .opcode = .DELEGATECALL, .handler = CallByOpHandler(.DELEGATECALL) },
    .{ .opcode = .CREATE2, .handler = Create2Handler },
    .{ .opcode = .STATICCALL, .handler = CallByOpHandler(.STATICCALL) },
    .{ .opcode = .REVERT, .handler = RevertHandler },
    .{ .opcode = .INVALID, .handler = InvalidBuiltinHandler },
    .{ .opcode = .SELFDESTRUCT, .handler = SelfDestructHandler },
};

const builtin_handler_table: [256]type = blk: {
    var table = [_]type{UnknownBuiltinHandler} ** 256;
    for (builtin_instruction_catalog) |instruction| {
        table[@intFromEnum(instruction.opcode)] = instruction.handler;
    }
    for (@intFromEnum(Opcode.PUSH1)..@intFromEnum(Opcode.PUSH32) + 1) |byte| {
        table[byte] = PushHandler(@enumFromInt(@as(u8, @intCast(byte))));
    }
    for (@intFromEnum(Opcode.DUP1)..@intFromEnum(Opcode.DUP16) + 1) |byte| {
        table[byte] = DupHandler(@enumFromInt(@as(u8, @intCast(byte))));
    }
    for (@intFromEnum(Opcode.SWAP1)..@intFromEnum(Opcode.SWAP16) + 1) |byte| {
        table[byte] = SwapHandler(@enumFromInt(@as(u8, @intCast(byte))));
    }
    for (@intFromEnum(Opcode.LOG0)..@intFromEnum(Opcode.LOG4) + 1) |byte| {
        table[byte] = LogHandler(@enumFromInt(@as(u8, @intCast(byte))));
    }
    break :blk table;
};

inline fn builtinHandlerForByte(comptime opcode_byte: u8) type {
    return builtin_handler_table[opcode_byte];
}

inline fn builtinHandlerForOpcode(comptime opcode: Opcode) type {
    return builtinHandlerForByte(@intFromEnum(opcode));
}

comptime {
    assertBuiltinHandlerCatalogCoversBaseOpcodeTable();
}

fn assertBuiltinHandlerCatalogCoversBaseOpcodeTable() void {
    @setEvalBranchQuota(10_000);
    for (0..256) |index| {
        const opcode_byte: u8 = @intCast(index);
        const Handler = builtinHandlerForByte(opcode_byte);
        const defined = opcode_info.info(opcode_byte).defined;
        if (defined) {
            std.debug.assert(Handler != UnknownBuiltinHandler);
        } else {
            std.debug.assert(Handler == UnknownBuiltinHandler);
        }
    }
}

pub fn Instruction(comptime spec: ExactSpec) type {
    const exact_instructions = spec.instruction;
    comptime instruction_table.validate(exact_instructions.table);
    return struct {
        const Self = @This();
        const dispatch_table = exact_instructions.table;

        pub const specification = spec;
        pub const table = dispatch_table;

        pub fn entry(comptime opcode_byte: u8) instruction_table.Entry {
            return dispatch_table[opcode_byte];
        }

        pub inline fn staticGasForFrame(_: *CallFrame, comptime opcode: Opcode) i64 {
            return Self.dispatchEntryForOpcode(opcode).static_gas;
        }

        pub noinline fn execute(opcode_byte: u8, frame: *CallFrame) anyerror!void {
            @setEvalBranchQuota(30_000);
            return switch (opcode_byte) {
                inline 0...255 => |byte| Self.executeDispatchEntryForByte(@as(u8, byte), frame),
            };
        }

        pub inline fn executeDispatchEntryForByte(comptime opcode_byte: u8, frame: *CallFrame) anyerror!void {
            return Self.executeDispatchEntry(Self.dispatchEntryForByte(opcode_byte), frame);
        }

        pub inline fn tailFastPathBuiltin(comptime opcode: Opcode) bool {
            const dispatch_entry = comptime Self.dispatchEntryForOpcode(opcode);
            return switch (comptime dispatch_entry.dispatchTarget()) {
                .builtin => |builtin| builtin == opcode,
                .invalid, .custom => false,
            };
        }

        inline fn dispatchEntryForOpcode(comptime opcode: Opcode) instruction_table.Entry {
            return Self.dispatchEntryForByte(@intFromEnum(opcode));
        }

        inline fn dispatchEntryForByte(comptime opcode_byte: u8) instruction_table.Entry {
            return dispatch_table[opcode_byte];
        }

        pub inline fn executeDispatchEntry(comptime dispatch_entry: instruction_table.Entry, frame: *CallFrame) anyerror!void {
            return switch (comptime dispatch_entry.dispatchTarget()) {
                .invalid => Self.executeInvalidDispatchEntry(dispatch_entry, frame),
                .builtin => |opcode| builtinHandlerForOpcode(opcode).execute(Self, frame),
                .custom => |Handler| Self.executeCustomDispatchEntry(Handler, frame),
            };
        }

        inline fn executeInvalidDispatchEntry(comptime dispatch_entry: instruction_table.Entry, frame: *CallFrame) anyerror!void {
            if (comptime !dispatch_entry.defined()) return error.UnknownOpcode;
            return system.invalid(frame);
        }

        inline fn executeCustomDispatchEntry(comptime Handler: type, frame: *CallFrame) anyerror!void {
            return Handler.execute(Self, frame);
        }

        pub inline fn chargeStaticGas(frame: *CallFrame, comptime opcode: Opcode) bool {
            return chargeGas(frame, Self.staticGasForFrame(frame, opcode));
        }

        inline fn chargeGas(frame: *CallFrame, gas: i64) bool {
            return frame.trackGas(gas);
        }

        pub inline fn requireOpcode(frame: *CallFrame, comptime opcode: Opcode) bool {
            @setEvalBranchQuota(10_000);
            if (comptime Self.dispatchEntryForOpcode(opcode).active) return true;
            return failInvalid(frame);
        }
    };
}

inline fn failInvalid(frame: *CallFrame) bool {
    frame.failWithFrameStatus(.invalid_opcode);
    return false;
}
