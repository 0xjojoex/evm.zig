//! Linear-sweep disassembly of raw bytecode.
//!
//! The exact instruction spec supplies activation and names. Instruction
//! framing follows the EVM byte encoding itself: only PUSH1..PUSH32 consume
//! following bytes.
//!
//! `Entry` holds a `type` field, so the spec table cannot be indexed at
//! runtime. Activation is flattened into plain data at comptime.

const std = @import("std");
const instruction_table = @import("./table.zig");
const immediate = @import("./immediate.zig");
const Opcode = @import("../opcode.zig").Opcode;

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
    /// Display-only decode of the EIP-8024 operand carried by the following
    /// byte. The sweep does not consume that byte: it is a legal instruction
    /// boundary and appears as the next `Decoded`.
    peek: Peek = .none,

    pub const Peek = union(enum) {
        none,
        /// Operand byte missing or outside the EIP-8024 encoding.
        malformed,
        /// DUPN/SWAPN stack depth.
        depth: usize,
        /// EXCHANGE stack position pair.
        exchange: struct { usize, usize },
    };
};

const PeekKind = enum { none, depth, exchange };

pub fn Iterator(comptime spec: instruction_table.Spec) type {
    const actives = comptime blk: {
        var actives: [256]bool = undefined;
        for (0..256) |opcode_byte| {
            actives[opcode_byte] = spec.table[opcode_byte].active;
        }
        break :blk actives;
    };

    // Peek only bytes that dispatch as the builtin EIP-8024 instructions in
    // this spec; a custom or disabled byte carries no operand.
    const peek_kinds = comptime blk: {
        var kinds: [256]PeekKind = @splat(.none);
        for ([_]Opcode{ .DUPN, .SWAPN, .EXCHANGE }) |op| {
            switch (spec.table[@intFromEnum(op)].dispatchTarget()) {
                .builtin => {
                    kinds[@intFromEnum(op)] = if (op == .EXCHANGE) .exchange else .depth;
                },
                else => {},
            }
        }
        break :blk kinds;
    };

    return struct {
        code: []const u8,
        pc: usize = 0,

        pub fn next(self: *@This()) ?Decoded {
            if (self.pc >= self.code.len) return null;
            const pc = self.pc;
            const opcode = self.code[pc];
            const width = @as(Opcode, @enumFromInt(opcode)).pushImmediateLen();
            const start = pc + 1;
            self.pc = start + width;
            return .{
                .pc = pc,
                .opcode = opcode,
                .immediate = self.code[@min(start, self.code.len)..@min(self.pc, self.code.len)],
                .active = actives[opcode],
                .peek = self.peekOperand(peek_kinds[opcode], start),
            };
        }

        fn peekOperand(self: *const @This(), kind: PeekKind, at: usize) Decoded.Peek {
            if (kind == .none) return .none;
            if (at >= self.code.len) return .malformed;
            switch (kind) {
                .none => unreachable,
                .depth => {
                    const depth = immediate.decodeDepthImmediate(self.code[at]) orelse return .malformed;
                    return .{ .depth = depth };
                },
                .exchange => {
                    const n, const m = immediate.decodeExchangeImmediate(self.code[at]) orelse return .malformed;
                    return .{ .exchange = .{ n, m } };
                },
            }
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

test "peeks EIP-8024 operands without consuming the byte" {
    var iterator = iterate(latest, &.{ 0xe6, 0x80, 0xe8, 0x00 });

    const dupn = iterator.next().?;
    try testing.expectEqual(@as(usize, 0), dupn.immediate.len);
    try testing.expectEqual(Decoded.Peek{ .depth = 17 }, dupn.peek);

    // The operand byte stays an instruction boundary of its own.
    const operand = iterator.next().?;
    try testing.expectEqual(@as(usize, 1), operand.pc);
    try testing.expectEqual(Decoded.Peek.none, operand.peek);

    const exchange = iterator.next().?;
    try testing.expectEqual(@as(usize, 2), exchange.pc);
    try testing.expectEqual(Decoded.Peek{ .exchange = .{ 9, 16 } }, exchange.peek);
}

test "flags malformed EIP-8024 operands" {
    // 0x5b sits in the rejected JUMPDEST..PUSH range — and stays a jumpdest.
    var rejected = iterate(latest, &.{ 0xe7, 0x5b });
    try testing.expectEqual(Decoded.Peek.malformed, rejected.next().?.peek);
    try testing.expectEqual(@as(u8, 0x5b), rejected.next().?.opcode);

    // Operand truncated by end of code.
    var truncated = iterate(latest, &.{0xe6});
    try testing.expectEqual(Decoded.Peek.malformed, truncated.next().?.peek);
}

test "custom instructions do not redefine bytecode framing" {
    const custom = comptime blk: {
        var instructions = @import("../eth.zig").latest.instruction;
        instructions.install(.CUSTOM, 0x0c, .{}, .invalid);
        break :blk instructions;
    };
    var iterator = iterate(custom, &.{ 0x0c, 0xaa, 0xbb, 0x00 });

    const decoded = iterator.next().?;
    try testing.expectEqual(@as(usize, 0), decoded.immediate.len);
    try testing.expect(decoded.active);
    try testing.expectEqual(@as(usize, 1), iterator.next().?.pc);
}
