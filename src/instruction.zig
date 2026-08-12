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
const Stack = @import("./Stack.zig");

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

pub const disassemble = @import("./instruction/disassemble.zig");
pub const arithmetic = @import("./instruction/arithmetic.zig");
pub const environment = @import("./instruction/environment.zig");
pub const stack = @import("./instruction/stack.zig");
pub const storage = @import("./instruction/storage.zig");
pub const system = @import("./instruction/system.zig");

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
            return Self.dispatchEntryForOpcode(opcode).info.static_gas;
        }

        pub inline fn tailFastPathBuiltin(comptime opcode: Opcode) bool {
            const dispatch_entry = comptime Self.dispatchEntryForOpcode(opcode);
            return switch (comptime dispatch_entry.dispatchTarget()) {
                .builtin => |builtin| builtin == opcode,
                .invalid, .custom => false,
            };
        }

        inline fn dispatchEntryForOpcode(comptime opcode: Opcode) instruction_table.Entry {
            return dispatch_table[@intFromEnum(opcode)];
        }

        pub inline fn chargeStaticGas(frame: *CallFrame, comptime opcode: Opcode) bool {
            return frame.trackGas(Self.staticGasForFrame(frame, opcode));
        }
    };
}

test {
    // Tail dispatch imports only the semantic modules it needs directly. Keep
    // the instruction-focused tests reachable independently of that production
    // dependency graph.
    inline for (.{
        disassemble,
        arithmetic,
        environment,
        @import("./instruction/flow.zig"),
        stack,
        storage,
        system,
        @import("./instruction/memory.zig"),
        @import("./instruction/logic.zig"),
    }) |namespace| _ = namespace;
}

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

test "prepared tail dispatch uses exact instruction availability" {
    if (comptime !evmz.t.forkEnabled(.frontier)) return error.SkipZigTest;
    try expectOpcodeHalt(evmz.eth.frontier, .BASEFEE, .invalid_opcode);
}

test "prepared tail dispatch uses resolved dispatch target for hot opcodes" {
    const spec = instructionOverrideSpec(.ADD, .invalid);

    var mock_host = evmz.t.MockHost.init(std.testing.allocator, null);
    defer mock_host.deinit();
    var host = mock_host.host();
    var msg = evmz.t.defaultMessage();
    const code = [_]u8{@intFromEnum(Opcode.ADD)};

    var frame = try Interpreter(spec).OwnedCallFrame.init(std.testing.allocator, .{
        .host = &host,
        .msg = &msg,
        .source = .{ .code = &code },
    });
    defer frame.deinit();

    frame.frame.stack.push(2);
    frame.frame.stack.push(3);
    try executeFrame(spec, frame.frame);
    try std.testing.expectEqual(interpreter.FrameHalt.invalid_opcode, frame.frame.haltReason().?);
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
        .source = .{ .bytecode = bytecode.view() },
    });
    defer frame.deinit();
    var intpr = frame.interpreter();

    const result = try intpr.execute();

    try std.testing.expectEqual(interpreter.Status.invalid, result.status());
}

test "untraced interpreter tail dispatch rejects invalid and undefined bytes" {
    inline for (.{ @intFromEnum(Opcode.INVALID), 0x0c }) |opcode_byte| {
        var mock_host = evmz.t.MockHost.init(std.testing.allocator, null);
        defer mock_host.deinit();
        var host = mock_host.host();
        var msg = evmz.t.defaultMessage();
        const code = [_]u8{opcode_byte};
        var bytecode = try evmz.Bytecode.init(std.testing.allocator, &code);
        defer bytecode.deinit(std.testing.allocator);

        var frame = try Interpreter(evmz.eth.amsterdam).OwnedCallFrame.init(std.testing.allocator, .{
            .host = &host,
            .msg = &msg,
            .source = .{ .bytecode = bytecode.view() },
        });
        defer frame.deinit();
        var intpr = frame.interpreter();

        const result = try intpr.execute();

        try std.testing.expectEqual(interpreter.Status.invalid, result.status());
        try std.testing.expectEqual(@as(i64, 0), frame.frame.gas_left);
    }
}

test "untraced interpreter tail dispatch executes a repointed builtin" {
    const spec = instructionOverrideSpec(.ADD, .{ .builtin = .SUB });

    var mock_host = evmz.t.MockHost.init(std.testing.allocator, null);
    defer mock_host.deinit();
    var host = mock_host.host();
    var msg = evmz.t.defaultMessage();
    const code = evmz.t.bytecode(.{ .PUSH1, 7, .PUSH1, 2, .ADD, .STOP });
    var bytecode = try evmz.Bytecode.init(std.testing.allocator, &code);
    defer bytecode.deinit(std.testing.allocator);

    var frame = try Interpreter(spec).OwnedCallFrame.init(std.testing.allocator, .{
        .host = &host,
        .msg = &msg,
        .source = .{ .bytecode = bytecode.view() },
    });
    defer frame.deinit();
    var intpr = frame.interpreter();

    const result = try intpr.execute();

    try std.testing.expectEqual(interpreter.Status.success, result.status());
    try std.testing.expectEqual(@as(u256, 2) -% 7, frame.frame.stack.pop());
}

test "untraced interpreter tail dispatch calls a custom target directly" {
    const CustomHandler = struct {
        pub inline fn execute(comptime Instructions: type, frame: *CallFrame) anyerror!void {
            if (!Instructions.chargeStaticGas(frame, .ADD)) return;
            _ = frame.push(42);
        }
    };
    const spec = instructionOverrideSpec(.ADD, .{ .custom = CustomHandler });

    var mock_host = evmz.t.MockHost.init(std.testing.allocator, null);
    defer mock_host.deinit();
    var host = mock_host.host();
    var msg = evmz.t.defaultMessage();
    const code = evmz.t.bytecode(.{ .ADD, .STOP });
    var bytecode = try evmz.Bytecode.init(std.testing.allocator, &code);
    defer bytecode.deinit(std.testing.allocator);

    var frame = try Interpreter(spec).OwnedCallFrame.init(std.testing.allocator, .{
        .host = &host,
        .msg = &msg,
        .source = .{ .bytecode = bytecode.view() },
    });
    defer frame.deinit();
    var intpr = frame.interpreter();

    const result = try intpr.execute();

    try std.testing.expectEqual(interpreter.Status.success, result.status());
    try std.testing.expectEqual(@as(u256, 42), frame.frame.stack.pop());
    try std.testing.expectEqual(msg.gas - staticGas(.ADD), frame.frame.gas_left);
}

test "captured custom MSTORE handler retains inherited trace effects" {
    const CustomMstore = struct {
        pub inline fn execute(comptime Instructions: type, frame: *CallFrame) anyerror!void {
            if (!Instructions.chargeStaticGas(frame, .MSTORE)) return;
            const offset, const value = frame.popN(2) orelse return;
            const offset_usize = frame.memoryOffsetToUsizeOrOog(offset, 32) orelse return;
            if (!try frame.expandMemory(offset_usize, 32)) return;
            frame.memory.write(offset_usize, value);
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
        .source = .{ .code = &code },
    });
    defer frame.deinit();
    var intpr = frame.interpreter();
    var tape = trace.TraceTape.initGrowable(std.testing.allocator);
    defer tape.deinit();

    const captured = try intpr.capture(&tape, .{ .memory = .writes });
    defer tape.resolve(captured.span) catch unreachable;
    try std.testing.expectEqual(interpreter.Status.success, captured.result.status());

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
    exact.table[@intFromEnum(opcode)].info.static_gas = gas;
    return evmz.eth.frontier.extend(.{
        .instruction = exact,
    });
}

fn staticGasAt(comptime revision: evmz.eth.Revision, comptime opcode: Opcode) i64 {
    return evmz.eth.specAt(revision).instruction.entry(@intFromEnum(opcode)).info.static_gas;
}

fn expectOpcodeHalt(comptime spec: evmz.eth.Spec, opcode: Opcode, expected: interpreter.FrameHalt) !void {
    var mock_host = evmz.t.MockHost.init(std.testing.allocator, null);
    defer mock_host.deinit();
    var host = mock_host.host();
    var msg = evmz.t.defaultMessage();
    const code = [_]u8{@intFromEnum(opcode)};

    var frame = try Interpreter(spec).OwnedCallFrame.init(std.testing.allocator, .{
        .host = &host,
        .msg = &msg,
        .source = .{ .code = &code },
    });
    defer frame.deinit();

    try executeFrame(spec, frame.frame);
    try std.testing.expectEqual(expected, frame.frame.haltReason().?);
}

test "instruction boundary resolves EVM faults without throwing" {
    const cases = [_]struct {
        opcode: u8,
        is_static: bool = false,
        expected: interpreter.FrameHalt,
    }{
        .{ .opcode = @intFromEnum(Opcode.ADD), .expected = .stack_underflow },
        .{ .opcode = 0x0c, .expected = .invalid_opcode },
        .{ .opcode = @intFromEnum(Opcode.SSTORE), .is_static = true, .expected = .write_protection },
    };

    inline for (cases) |case| {
        var mock_host = evmz.t.MockHost.init(std.testing.allocator, null);
        defer mock_host.deinit();
        var host = mock_host.host();
        var msg = evmz.t.defaultMessage();
        msg.is_static = case.is_static;
        const code = [_]u8{case.opcode};

        var frame = try Interpreter(evmz.eth.cancun).OwnedCallFrame.init(std.testing.allocator, .{
            .host = &host,
            .msg = &msg,
            .source = .{ .code = &code },
        });
        defer frame.deinit();

        try executeFrame(evmz.eth.cancun, frame.frame);
        try std.testing.expectEqual(case.expected, frame.frame.haltReason().?);
    }

    var mock_host = evmz.t.MockHost.init(std.testing.allocator, null);
    defer mock_host.deinit();
    var host = mock_host.host();
    var msg = evmz.t.defaultMessage();
    const code = [_]u8{@intFromEnum(Opcode.PUSH0)};
    var frame = try Interpreter(evmz.eth.cancun).OwnedCallFrame.init(std.testing.allocator, .{
        .host = &host,
        .msg = &msg,
        .source = .{ .code = &code },
    });
    defer frame.deinit();
    for (0..Stack.capacity) |_| frame.frame.stack.push(0);

    try executeFrame(evmz.eth.cancun, frame.frame);
    try std.testing.expectEqual(interpreter.FrameHalt.stack_overflow, frame.frame.haltReason().?);
}

test "static gas helper uses resolved rule gas" {
    if (comptime !evmz.t.forkEnabled(.frontier)) return error.SkipZigTest;
    var mock_host = evmz.t.MockHost.init(std.testing.allocator, null);
    defer mock_host.deinit();
    var host = mock_host.host();
    var msg = evmz.t.defaultMessage();
    const code = [_]u8{@intFromEnum(Opcode.CALL)};

    var frame = try evmz.Vm(evmz.eth.frontier).Interpreter.OwnedCallFrame.init(std.testing.allocator, .{
        .host = &host,
        .msg = &msg,
        .source = .{ .code = &code },
    });
    defer frame.deinit();

    try std.testing.expectEqual(@as(i64, 7), Instruction(instructionGasSpec(.CALL, 7)).staticGasForFrame(frame.frame, .CALL));
    try std.testing.expectEqual(@as(i64, 11), Instruction(instructionGasSpec(.CALL, 11)).staticGasForFrame(frame.frame, .CALL));
}

fn staticGas(opcode: Opcode) i64 {
    return opcode_info.table[@intFromEnum(opcode)].static_gas;
}

fn executeFrame(comptime spec: ExactSpec, frame: *CallFrame) !void {
    var intpr = Interpreter(spec).init(frame);
    _ = try intpr.execute();
}
