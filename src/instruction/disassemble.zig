//! Linear-sweep disassembly of raw bytecode.
//!
//! Bound to an exact instruction spec rather than the shared opcode table: a
//! fork that reassigns a byte, or a custom instruction installed with its own
//! immediate width, decodes under its own rules here. `Spec.fmt` supplies the
//! matching name.
//!
//! `Entry` holds a `type` field, so the spec table cannot be indexed at
//! runtime. Both lookups below are flattened into plain data at comptime.

const std = @import("std");
const instruction_table = @import("./table.zig");

/// One instruction at a code offset.
pub const Decoded = struct {
    pc: usize,
    opcode: u8,
    /// PUSH payload, empty for everything else. Truncated when the operand runs
    /// past the end of the code, which real bytecode does at its tail.
    immediate: []const u8,
    /// Whether this byte dispatches in the spec. Inactive bytes execute as
    /// INVALID regardless of the name a formatter prints for them.
    active: bool,
};

pub fn Iterator(comptime spec: instruction_table.Spec) type {
    const immediates, const actives = comptime blk: {
        var immediates: [256]u8 = undefined;
        var actives: [256]bool = undefined;
        for (0..256) |opcode_byte| {
            immediates[opcode_byte] = spec.table[opcode_byte].info.immediate;
            actives[opcode_byte] = spec.table[opcode_byte].active;
        }
        break :blk .{ immediates, actives };
    };

    return struct {
        code: []const u8,
        pc: usize = 0,

        pub fn next(self: *@This()) ?Decoded {
            if (self.pc >= self.code.len) return null;
            const pc = self.pc;
            const opcode = self.code[pc];
            const width = immediates[opcode];
            const start = pc + 1;
            self.pc = start + width;
            return .{
                .pc = pc,
                .opcode = opcode,
                .immediate = self.code[@min(start, self.code.len)..@min(self.pc, self.code.len)],
                .active = actives[opcode],
            };
        }
    };
}

pub fn iterate(comptime spec: instruction_table.Spec, code: []const u8) Iterator(spec) {
    return .{ .code = code };
}

const testing = std.testing;
const latest = @import("../eth.zig").latest.instruction;

test "sweeps past push immediates" {
    var iterator = iterate(latest, &.{ 0x63, 0x11, 0x22, 0x33, 0x44, 0x00 });

    const push = iterator.next().?;
    try testing.expectEqual(@as(usize, 0), push.pc);
    try testing.expectEqual(@as(u8, 0x63), push.opcode);
    try testing.expectEqualSlices(u8, &.{ 0x11, 0x22, 0x33, 0x44 }, push.immediate);
    try testing.expect(push.active);

    const stop = iterator.next().?;
    try testing.expectEqual(@as(usize, 5), stop.pc);
    try testing.expectEqual(@as(usize, 0), stop.immediate.len);

    try testing.expectEqual(null, iterator.next());
}

test "truncates an immediate that runs off the end" {
    var iterator = iterate(latest, &.{ 0x63, 0x11 });

    const push = iterator.next().?;
    try testing.expectEqualSlices(u8, &.{0x11}, push.immediate);
    try testing.expectEqual(null, iterator.next());
}

test "reports undefined bytes as inactive" {
    var iterator = iterate(latest, &.{0x0c});

    const decoded = iterator.next().?;
    try testing.expectEqual(@as(u8, 0x0c), decoded.opcode);
    try testing.expect(!decoded.active);
}

test "custom instruction immediates follow the installed spec" {
    const custom = comptime blk: {
        var instructions = @import("../eth.zig").latest.instruction;
        instructions.install(.IMM2, 0x0c, .{ .immediate = 2, .stack_out = 1 }, .invalid);
        break :blk instructions;
    };
    var iterator = iterate(custom, &.{ 0x0c, 0xaa, 0xbb, 0x00 });

    const decoded = iterator.next().?;
    try testing.expectEqualSlices(u8, &.{ 0xaa, 0xbb }, decoded.immediate);
    try testing.expect(decoded.active);
    try testing.expectEqual(@as(usize, 3), iterator.next().?.pc);
}
