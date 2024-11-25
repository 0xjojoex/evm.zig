const std = @import("std");
const evmz = @import("evm.zig");
const instruction = evmz.instruction;
const instruction_table = instruction.instruction_table;

const InstructionDetail = struct {
    instruction: instruction.Instruction,
    data: []const u8,
    offset: usize,

    pub fn format(self: @This(), comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        if (self.data.len > 0) {
            const hex = std.fmt.fmtSliceHexLower(self.data);

            return writer.print("{s} 0x{x}", .{ @tagName(self.instruction.opcode), hex });
        } else {
            return writer.print("{s}", .{@tagName(self.instruction.opcode)});
        }
    }
};

pub const DisassembleIterator = struct {
    bytecode: []const u8,
    pc: usize = 0,

    fn next(self: *DisassembleIterator) ?InstructionDetail {
        if (self.pc >= self.bytecode.len) {
            return null;
        }
        const instr = instruction_table.ops[self.bytecode[self.pc]];

        const oprand = instr.opcode.oprand();

        const offset = self.pc;

        self.pc += oprand + 1;
        return .{
            .instruction = instr,
            .data = if (oprand > 0) self.bytecode[offset + oprand .. self.pc] else &.{},
            .offset = offset,
        };
    }
};

pub const PrintOption = struct {
    show_offset: bool = false,
};

pub fn disassembleIter(bytecode: []const u8) DisassembleIterator {
    return .{
        .bytecode = bytecode,
        .pc = 0,
    };
}

pub fn disassemblePrint(bytecode: []const u8, opts: PrintOption) void {
    const stdout = std.io.getStdOut().writer();
    var iter = disassembleIter(bytecode);
    while (iter.next()) |instr| {
        if (opts.show_offset) {
            stdout.print("{x:0>6} {}\n", .{ instr.offset, instr }) catch return;
        } else {
            stdout.print("{}\n", .{instr}) catch return;
        }
    }
}

const testing = std.testing;
test "easm disassemble" {
    var buf: [1024]u8 = undefined;
    const bytecode = try std.fmt.hexToBytes(&buf, "6311223344");

    var iter = disassembleIter(bytecode);

    try testing.expectEqual(0, iter.pc);
    const n = iter.next();

    try testing.expectEqual(5, iter.pc);
    try testing.expectEqual(evmz.Opcode.PUSH4, n.?.instruction.opcode);

    const bytecode1 = try std.fmt.hexToBytes(&buf, "604260005260206000F3");
    disassemblePrint(bytecode1, .{});
}
