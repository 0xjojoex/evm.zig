const opcode_info = @import("opcode.zig");
const Opcode = opcode_info.Opcode;
const std = @import("std");
const ExactSpec = @import("./spec.zig").Spec;
const instruction_table = @import("./instruction/table.zig");
const evmz = @import("./evm.zig");

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
        const dispatch_table = exact_instructions.table;

        pub const table = dispatch_table;

        pub fn entry(comptime opcode_byte: u8) instruction_table.Entry {
            return dispatch_table[opcode_byte];
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

fn staticGasAt(comptime revision: evmz.eth.Revision, comptime opcode: Opcode) i64 {
    return evmz.eth.specAt(revision).instruction.entry(@intFromEnum(opcode)).info.static_gas;
}
