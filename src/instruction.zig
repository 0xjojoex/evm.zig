const opcode_info = @import("opcode.zig");
const Opcode = opcode_info.Opcode;
const std = @import("std");
const ExactSpec = @import("./spec.zig").Spec;
const instruction_table = @import("./instruction/table.zig");
const evmz = @import("./evm.zig");
const interpreter = @import("./Interpreter.zig");

const CallFrame = interpreter.CallFrame;

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
pub const environment = @import("./instruction/environment.zig");
pub const immediate = @import("./instruction/immediate.zig");
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
