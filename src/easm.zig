const std = @import("std");
const evmz = @import("evm.zig");
const instruction = evmz.instruction;

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
        const instr = instruction.decode(self.bytecode[self.pc]) orelse instruction.Instruction{
            .opcode = .INVALID,
            .static_gas = 0,
        };

        const offset = self.pc;
        const oprand = instr.opcode.oprand();
        const data_start = offset + 1;
        const next_pc = data_start + oprand;
        const data_end = @min(next_pc, self.bytecode.len);

        self.pc = next_pc;
        return .{
            .instruction = instr,
            .data = if (oprand > 0) self.bytecode[data_start..data_end] else &.{},
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
    var iter = disassembleIter(bytecode);
    while (iter.next()) |instr| {
        if (opts.show_offset) {
            std.debug.print("{x:0>6} {}\n", .{ instr.offset, instr });
        } else {
            std.debug.print("{}\n", .{instr});
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
    try testing.expectEqualSlices(u8, &.{ 0x11, 0x22, 0x33, 0x44 }, n.?.data);
}

test "easm disassemble truncated PUSH operand" {
    var iter = disassembleIter(&.{ 0x63, 0x11 });

    const n = iter.next().?;

    try testing.expectEqual(5, iter.pc);
    try testing.expectEqual(evmz.Opcode.PUSH4, n.instruction.opcode);
    try testing.expectEqualSlices(u8, &.{0x11}, n.data);
    try testing.expectEqual(null, iter.next());
}
