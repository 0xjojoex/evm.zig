//! Shared EVM opcode vocabulary and static per-opcode metadata.
//!
//! PUSH1..PUSH32 payloads are the only bytes that are not
//! instructions. Framing belongs to the code format, not to any instruction
//! table — a fork may reimplement or reprice a builtin opcode, but never
//! change what it means; new semantics only land on free bytes. Jumpdest
//! analysis, code scanning, and disassembly all hardcode this rule and stay
//! correct for every spec. Opcodes that need an operand (EIP-8024
//! DUPN/SWAPN/EXCHANGE) read it in the handler with an encoding that avoids
//! 0x5b..0x7f, so the operand byte stays an instruction boundary.

const std = @import("std");

/// Shared ISA metadata and EVM vocabulary.
pub const Opcode = enum(u8) {
    STOP = 0x00,
    ADD = 0x01,
    MUL = 0x02,
    SUB = 0x03,
    DIV = 0x04,
    SDIV = 0x05,
    MOD = 0x06,
    SMOD = 0x07,
    ADDMOD = 0x08,
    MULMOD = 0x09,
    EXP = 0x0a,
    SIGNEXTEND = 0x0b,
    LT = 0x10,
    GT = 0x11,
    SLT = 0x12,
    SGT = 0x13,
    EQ = 0x14,
    ISZERO = 0x15,
    AND = 0x16,
    OR = 0x17,
    XOR = 0x18,
    NOT = 0x19,
    BYTE = 0x1a,
    SHL = 0x1b,
    SHR = 0x1c,
    SAR = 0x1d,
    CLZ = 0x1e,
    KECCAK256 = 0x20,
    ADDRESS = 0x30,
    BALANCE = 0x31,
    ORIGIN = 0x32,
    CALLER = 0x33,
    CALLVALUE = 0x34,
    CALLDATALOAD = 0x35,
    CALLDATASIZE = 0x36,
    CALLDATACOPY = 0x37,
    CODESIZE = 0x38,
    CODECOPY = 0x39,
    GASPRICE = 0x3a,
    EXTCODESIZE = 0x3b,
    EXTCODECOPY = 0x3c,
    RETURNDATASIZE = 0x3d,
    RETURNDATACOPY = 0x3e,
    EXTCODEHASH = 0x3f,
    BLOCKHASH = 0x40,
    COINBASE = 0x41,
    TIMESTAMP = 0x42,
    NUMBER = 0x43,
    PREVRANDAO = 0x44,
    GASLIMIT = 0x45,
    CHAINID = 0x46,
    SELFBALANCE = 0x47,
    BASEFEE = 0x48,
    BLOBHASH = 0x49,
    BLOBBASEFEE = 0x4a,
    SLOTNUM = 0x4b,
    POP = 0x50,
    MLOAD = 0x51,
    MSTORE = 0x52,
    MSTORE8 = 0x53,
    SLOAD = 0x54,
    SSTORE = 0x55,
    JUMP = 0x56,
    JUMPI = 0x57,
    PC = 0x58,
    MSIZE = 0x59,
    GAS = 0x5a,
    JUMPDEST = 0x5b,
    TLOAD = 0x5c,
    TSTORE = 0x5d,
    MCOPY = 0x5e,
    PUSH0 = 0x5f,
    PUSH1 = 0x60,
    PUSH2 = 0x61,
    PUSH3 = 0x62,
    PUSH4 = 0x63,
    PUSH5 = 0x64,
    PUSH6 = 0x65,
    PUSH7 = 0x66,
    PUSH8 = 0x67,
    PUSH9 = 0x68,
    PUSH10 = 0x69,
    PUSH11 = 0x6a,
    PUSH12 = 0x6b,
    PUSH13 = 0x6c,
    PUSH14 = 0x6d,
    PUSH15 = 0x6e,
    PUSH16 = 0x6f,
    PUSH17 = 0x70,
    PUSH18 = 0x71,
    PUSH19 = 0x72,
    PUSH20 = 0x73,
    PUSH21 = 0x74,
    PUSH22 = 0x75,
    PUSH23 = 0x76,
    PUSH24 = 0x77,
    PUSH25 = 0x78,
    PUSH26 = 0x79,
    PUSH27 = 0x7a,
    PUSH28 = 0x7b,
    PUSH29 = 0x7c,
    PUSH30 = 0x7d,
    PUSH31 = 0x7e,
    PUSH32 = 0x7f,
    DUP1 = 0x80,
    DUP2 = 0x81,
    DUP3 = 0x82,
    DUP4 = 0x83,
    DUP5 = 0x84,
    DUP6 = 0x85,
    DUP7 = 0x86,
    DUP8 = 0x87,
    DUP9 = 0x88,
    DUP10 = 0x89,
    DUP11 = 0x8a,
    DUP12 = 0x8b,
    DUP13 = 0x8c,
    DUP14 = 0x8d,
    DUP15 = 0x8e,
    DUP16 = 0x8f,
    SWAP1 = 0x90,
    SWAP2 = 0x91,
    SWAP3 = 0x92,
    SWAP4 = 0x93,
    SWAP5 = 0x94,
    SWAP6 = 0x95,
    SWAP7 = 0x96,
    SWAP8 = 0x97,
    SWAP9 = 0x98,
    SWAP10 = 0x99,
    SWAP11 = 0x9a,
    SWAP12 = 0x9b,
    SWAP13 = 0x9c,
    SWAP14 = 0x9d,
    SWAP15 = 0x9e,
    SWAP16 = 0x9f,
    LOG0 = 0xa0,
    LOG1 = 0xa1,
    LOG2 = 0xa2,
    LOG3 = 0xa3,
    LOG4 = 0xa4,
    DUPN = 0xe6,
    SWAPN = 0xe7,
    EXCHANGE = 0xe8,
    CREATE = 0xf0,
    CALL = 0xf1,
    CALLCODE = 0xf2,
    RETURN = 0xf3,
    DELEGATECALL = 0xf4,
    CREATE2 = 0xf5,
    STATICCALL = 0xfa,
    REVERT = 0xfd,
    INVALID = 0xfe,
    SELFDESTRUCT = 0xff,
    _,

    pub fn isPushN(self: Opcode) bool {
        return self.toByte() >= Opcode.PUSH1.toByte() and self.toByte() <= Opcode.PUSH32.toByte();
    }

    /// PUSH payload bytes following this opcode; zero for everything else.
    /// The single framing rule of the code format (see module doc).
    pub fn pushImmediateLen(self: Opcode) u8 {
        if (!self.isPushN()) return 0;
        return self.toByte() - Opcode.PUSH0.toByte();
    }

    pub inline fn toByte(self: Opcode) u8 {
        return @intFromEnum(self);
    }

    pub fn format(self: Opcode, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        if (std.enums.tagName(Opcode, self)) |name| {
            return writer.writeAll(name);
        }
        try writer.print("0x{x:0>2}", .{self.toByte()});
    }
};

/// Metadata consumed by exact instruction configuration and trace capture.
/// Indexed by raw byte via `table`; undefined bytes get the zeroed default row.
pub const OpInfo = struct {
    /// False for unused byte values; INVALID/0xfe remains a defined opcode.
    defined: bool = false,
    /// Static gas for this row. The shared opcode table holds the baseline;
    /// exact instruction specs copy and reprice the same field.
    static_gas: i64 = 0,
    /// Minimum stack height required before execution. Variable-depth
    /// instructions may require more after decoding their immediate operand.
    stack_in: u8 = 0,
};

/// 256-entry opcode property table. Gap bytes default to an undefined row.
pub const table: [256]OpInfo = blk: {
    var t = [_]OpInfo{.{}} ** 256;
    for (std.enums.values(Opcode)) |op| {
        var row = infoFor(op);
        row.defined = true;
        t[@intFromEnum(op)] = row;
    }
    break :blk t;
};

/// Direct byte lookup. Every byte maps to a row (no `orelse` dance).
pub inline fn info(opcode_byte: u8) OpInfo {
    return table[opcode_byte];
}

/// One baseline gas/trace row per named opcode. `defined` is stamped by
/// `table`. The `_` prong covers unnamed bytes; the compiler still errors if a
/// new named opcode is added without a row here.
fn infoFor(op: Opcode) OpInfo {
    return switch (op) {
        // 0x00s — arithmetic
        .STOP => .{},
        .ADD => .{ .static_gas = 3, .stack_in = 2 },
        .MUL => .{ .static_gas = 5, .stack_in = 2 },
        .SUB => .{ .static_gas = 3, .stack_in = 2 },
        .DIV => .{ .static_gas = 5, .stack_in = 2 },
        .SDIV => .{ .static_gas = 5, .stack_in = 2 },
        .MOD => .{ .static_gas = 5, .stack_in = 2 },
        .SMOD => .{ .static_gas = 5, .stack_in = 2 },
        .ADDMOD => .{ .static_gas = 8, .stack_in = 3 },
        .MULMOD => .{ .static_gas = 8, .stack_in = 3 },
        .EXP => .{ .static_gas = 10, .stack_in = 2 },
        .SIGNEXTEND => .{ .static_gas = 5, .stack_in = 2 },

        // 0x10s — comparison & bitwise
        .LT => .{ .static_gas = 3, .stack_in = 2 },
        .GT => .{ .static_gas = 3, .stack_in = 2 },
        .SLT => .{ .static_gas = 3, .stack_in = 2 },
        .SGT => .{ .static_gas = 3, .stack_in = 2 },
        .EQ => .{ .static_gas = 3, .stack_in = 2 },
        .ISZERO => .{ .static_gas = 3, .stack_in = 1 },
        .AND => .{ .static_gas = 3, .stack_in = 2 },
        .OR => .{ .static_gas = 3, .stack_in = 2 },
        .XOR => .{ .static_gas = 3, .stack_in = 2 },
        .NOT => .{ .static_gas = 3, .stack_in = 1 },
        .BYTE => .{ .static_gas = 3, .stack_in = 2 },
        .SHL => .{ .static_gas = 3, .stack_in = 2 },
        .SHR => .{ .static_gas = 3, .stack_in = 2 },
        .SAR => .{ .static_gas = 3, .stack_in = 2 },
        .CLZ => .{ .static_gas = 5, .stack_in = 1 },

        // 0x20 — keccak
        .KECCAK256 => .{ .static_gas = 30, .stack_in = 2 },

        // 0x30s — environment / calldata / code
        .ADDRESS => .{ .static_gas = 2 },
        .BALANCE => .{ .static_gas = 20, .stack_in = 1 },
        .ORIGIN => .{ .static_gas = 2 },
        .CALLER => .{ .static_gas = 2 },
        .CALLVALUE => .{ .static_gas = 2 },
        .CALLDATALOAD => .{ .static_gas = 3, .stack_in = 1 },
        .CALLDATASIZE => .{ .static_gas = 2 },
        .CALLDATACOPY => .{ .static_gas = 3, .stack_in = 3 },
        .CODESIZE => .{ .static_gas = 2 },
        .CODECOPY => .{ .static_gas = 3, .stack_in = 3 },
        .GASPRICE => .{ .static_gas = 2 },
        .EXTCODESIZE => .{ .static_gas = 20, .stack_in = 1 },
        .EXTCODECOPY => .{ .static_gas = 20, .stack_in = 4 },
        .RETURNDATASIZE => .{ .static_gas = 2 },
        .RETURNDATACOPY => .{ .static_gas = 3, .stack_in = 3 },
        .EXTCODEHASH => .{ .static_gas = 400, .stack_in = 1 },

        // 0x40s — block context
        .BLOCKHASH => .{ .static_gas = 20, .stack_in = 1 },
        .COINBASE => .{ .static_gas = 2 },
        .TIMESTAMP => .{ .static_gas = 2 },
        .NUMBER => .{ .static_gas = 2 },
        .PREVRANDAO => .{ .static_gas = 2 },
        .GASLIMIT => .{ .static_gas = 2 },
        .CHAINID => .{ .static_gas = 2 },
        .SELFBALANCE => .{ .static_gas = 5 },
        .BASEFEE => .{ .static_gas = 2 },
        .BLOBHASH => .{ .static_gas = 3, .stack_in = 1 },
        .BLOBBASEFEE => .{ .static_gas = 2 },
        .SLOTNUM => .{ .static_gas = 2 },

        // 0x50s — stack / memory / storage / flow
        .POP => .{ .static_gas = 2, .stack_in = 1 },
        .MLOAD => .{ .static_gas = 3, .stack_in = 1 },
        .MSTORE => .{ .static_gas = 3, .stack_in = 2 },
        .MSTORE8 => .{ .static_gas = 3, .stack_in = 2 },
        .SLOAD => .{ .static_gas = 50, .stack_in = 1 },
        .SSTORE => .{ .static_gas = 0, .stack_in = 2 },
        .JUMP => .{ .static_gas = 8, .stack_in = 1 },
        .JUMPI => .{ .static_gas = 10, .stack_in = 2 },
        .PC => .{ .static_gas = 2 },
        .MSIZE => .{ .static_gas = 2 },
        .GAS => .{ .static_gas = 2 },
        .JUMPDEST => .{ .static_gas = 1 },
        .TLOAD => .{ .static_gas = 100, .stack_in = 1 },
        .TSTORE => .{ .static_gas = 100, .stack_in = 2 },
        .MCOPY => .{ .static_gas = 3, .stack_in = 3 },
        .PUSH0 => .{ .static_gas = 2 },

        // 0x60..0x7f — PUSH1..PUSH32
        .PUSH1,
        .PUSH2,
        .PUSH3,
        .PUSH4,
        .PUSH5,
        .PUSH6,
        .PUSH7,
        .PUSH8,
        .PUSH9,
        .PUSH10,
        .PUSH11,
        .PUSH12,
        .PUSH13,
        .PUSH14,
        .PUSH15,
        .PUSH16,
        .PUSH17,
        .PUSH18,
        .PUSH19,
        .PUSH20,
        .PUSH21,
        .PUSH22,
        .PUSH23,
        .PUSH24,
        .PUSH25,
        .PUSH26,
        .PUSH27,
        .PUSH28,
        .PUSH29,
        .PUSH30,
        .PUSH31,
        .PUSH32,
        => .{ .static_gas = 3 },

        // 0x80..0x8f — DUP1..DUP16
        .DUP1,
        .DUP2,
        .DUP3,
        .DUP4,
        .DUP5,
        .DUP6,
        .DUP7,
        .DUP8,
        .DUP9,
        .DUP10,
        .DUP11,
        .DUP12,
        .DUP13,
        .DUP14,
        .DUP15,
        .DUP16,
        => blk2: {
            const n: u8 = @intFromEnum(op) - @intFromEnum(Opcode.DUP1) + 1;
            break :blk2 .{ .static_gas = 3, .stack_in = n };
        },

        // 0x90..0x9f — SWAP1..SWAP16
        .SWAP1,
        .SWAP2,
        .SWAP3,
        .SWAP4,
        .SWAP5,
        .SWAP6,
        .SWAP7,
        .SWAP8,
        .SWAP9,
        .SWAP10,
        .SWAP11,
        .SWAP12,
        .SWAP13,
        .SWAP14,
        .SWAP15,
        .SWAP16,
        => blk2: {
            const n: u8 = @intFromEnum(op) - @intFromEnum(Opcode.SWAP1) + 1;
            break :blk2 .{ .static_gas = 3, .stack_in = n + 1 };
        },

        // 0xa0..0xa4 — LOG0..LOG4 (pops mem offset+size + N topics)
        .LOG0, .LOG1, .LOG2, .LOG3, .LOG4 => blk2: {
            const n: u8 = @intFromEnum(op) - @intFromEnum(Opcode.LOG0);
            break :blk2 .{
                .static_gas = 375 * (@as(u16, n) + 1),
                .stack_in = n + 2,
            };
        },

        // Variable-depth instructions declare their fixed minimum; handlers
        // enforce the decoded depth.
        .DUPN => .{ .static_gas = 3, .stack_in = 17 },
        .SWAPN => .{ .static_gas = 3, .stack_in = 18 },
        .EXCHANGE => .{ .static_gas = 3, .stack_in = 3 },

        // 0xf0s — system / calls
        .CREATE => .{ .static_gas = 32000, .stack_in = 3 },
        .CALL => .{ .static_gas = 40, .stack_in = 7 },
        .CALLCODE => .{ .static_gas = 40, .stack_in = 7 },
        .RETURN => .{ .static_gas = 0, .stack_in = 2 },
        .DELEGATECALL => .{ .static_gas = 40, .stack_in = 6 },
        .CREATE2 => .{ .static_gas = 32000, .stack_in = 4 },
        .STATICCALL => .{ .static_gas = 40, .stack_in = 6 },
        .REVERT => .{ .static_gas = 0, .stack_in = 2 },
        .INVALID => .{},
        .SELFDESTRUCT => .{ .static_gas = 0, .stack_in = 1 },
        _ => .{},
    };
}

test "opcode table carries baseline gas and trace stack suffixes" {
    const expectEqual = std.testing.expectEqual;

    // Gap bytes are undefined; INVALID remains a named, defined opcode.
    try std.testing.expect(!table[0x0c].defined);
    try std.testing.expect(table[@intFromEnum(Opcode.INVALID)].defined);

    // A plain binary op charges its baseline gas and captures two inputs.
    const add = table[@intFromEnum(Opcode.ADD)];
    try expectEqual(@as(i64, 3), add.static_gas);
    try expectEqual(@as(u8, 2), add.stack_in);

    // Historically repriced opcodes keep base gas here; fork-resolved gas
    // belongs to the exact instruction spec.
    try expectEqual(@as(i64, 20), table[@intFromEnum(Opcode.BALANCE)].static_gas);
    try expectEqual(@as(i64, 20), table[@intFromEnum(Opcode.EXTCODESIZE)].static_gas);
    try expectEqual(@as(i64, 20), table[@intFromEnum(Opcode.EXTCODECOPY)].static_gas);
    try expectEqual(@as(i64, 400), table[@intFromEnum(Opcode.EXTCODEHASH)].static_gas);
    try expectEqual(@as(i64, 50), table[@intFromEnum(Opcode.SLOAD)].static_gas);
    try expectEqual(@as(i64, 0), table[@intFromEnum(Opcode.SELFDESTRUCT)].static_gas);

    // Fixed-depth stack operations retain the suffix needed by tracing.
    try expectEqual(@as(u8, 3), table[@intFromEnum(Opcode.DUP3)].stack_in);
    try expectEqual(@as(u8, 6), table[@intFromEnum(Opcode.SWAP5)].stack_in);

    // Variable-depth EIP-8024 operations declare their fixed minimum.
    try expectEqual(@as(i64, 3), table[@intFromEnum(Opcode.DUPN)].static_gas);
    try expectEqual(@as(u8, 17), table[@intFromEnum(Opcode.DUPN)].stack_in);
    try expectEqual(@as(u8, 18), table[@intFromEnum(Opcode.SWAPN)].stack_in);
    try expectEqual(@as(u8, 3), table[@intFromEnum(Opcode.EXCHANGE)].stack_in);

    // LOG4 consumes offset, size, and four topics.
    try expectEqual(@as(i64, 1875), table[@intFromEnum(Opcode.LOG4)].static_gas);
    try expectEqual(@as(u8, 6), table[@intFromEnum(Opcode.LOG4)].stack_in);
    try expectEqual(@as(u8, 7), table[@intFromEnum(Opcode.CALL)].stack_in);
    try expectEqual(@as(u8, 2), table[@intFromEnum(Opcode.SSTORE)].stack_in);
}

test "opcode table defined rows match Opcode enum exactly" {
    var defined_count: usize = 0;
    for (0..256) |index| {
        const opcode_byte: u8 = @intCast(index);
        const row = table[opcode_byte];
        var is_named_opcode = false;
        for (std.enums.values(Opcode)) |op| {
            if (@intFromEnum(op) == opcode_byte) {
                is_named_opcode = true;
                break;
            }
        }

        try std.testing.expectEqual(is_named_opcode, row.defined);

        if (row.defined) {
            defined_count += 1;
        } else {
            try std.testing.expectEqual(@as(i64, 0), row.static_gas);
            try std.testing.expectEqual(@as(u8, 0), row.stack_in);
        }
    }
    try std.testing.expectEqual(std.enums.values(Opcode).len, defined_count);
}

test "opcode formatter derives named tags and preserves unnamed bytes" {
    var buffer: [32]u8 = undefined;

    const named = try std.fmt.bufPrint(&buffer, "{f}", .{Opcode.ADD});
    try std.testing.expectEqualStrings("ADD", named);

    const unnamed = try std.fmt.bufPrint(&buffer, "{f}", .{@as(Opcode, @enumFromInt(0x0c))});
    try std.testing.expectEqualStrings("0x0c", unnamed);
}
