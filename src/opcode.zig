//! Fork-neutral opcode vocabulary and static per-opcode metadata.

const std = @import("std");

/// Shared ISA metadata / fork-neutral vocabulary
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

    pub fn isPush(self: Opcode) bool {
        return self.toByte() >= Opcode.PUSH0.toByte() and self.toByte() <= Opcode.PUSH32.toByte();
    }

    pub fn isPushN(self: Opcode) bool {
        return self.toByte() >= Opcode.PUSH1.toByte() and self.toByte() <= Opcode.PUSH32.toByte();
    }

    pub fn oprand(self: Opcode) usize {
        if (self.isPushN()) {
            return self.toByte() - Opcode.PUSH0.toByte();
        } else {
            return 0;
        }
    }

    pub inline fn toByte(self: Opcode) u8 {
        return @intFromEnum(self);
    }
};

/// Control-flow class of an instruction. `.eof` is never produced per-opcode;
/// callers that group code into blocks derive it when fallthrough reaches EOF.
pub const ExitKind = enum(u8) {
    fallthrough,
    jump,
    jumpi,
    stop,
    return_,
    revert,
    invalid,
    selfdestruct,
    eof,
};

/// Per-opcode behavioral flags. Unknown opcode handling is derived from
/// `!OpInfo.defined` by callers that need that classification.
pub const Flags = struct {
    uses_gas_left: bool = false,
    has_dynamic_gas: bool = false,
    touches_host: bool = false,
    writes_state: bool = false,
};

/// Everything statically known about a single opcode byte — the single source of
/// truth that the gas / stack / flags / exit / push-width switches collapse into.
/// Indexed by raw byte via `table`; undefined bytes get the default (invalid) row.
pub const OpInfo = struct {
    /// Definition-owned mnemonic. Ethereum-known rows get the base enum tag;
    /// custom definitions may use chain-local names without extending `Opcode`.
    name: ?[]const u8 = null,
    /// false for the 106 unused byte values in 0x00..0xff (and only those;
    /// INVALID/0xfe is a *defined* opcode with `.exit = .invalid`).
    defined: bool = false,
    /// Baseline fixed gas before definition revision overrides. This is opcode
    /// metadata, not a fork-resolved gas query; use a bound protocol's static
    /// gas resolver for execution.
    static_gas: u16 = 0,
    /// Minimum stack height required to execute without underflow.
    stack_in: u8 = 0,
    /// Stack height after execution, relative to `stack_in` (height contribution,
    /// not "items pushed" — DUP/SWAP read deep without popping).
    stack_out: u8 = 0,
    /// PUSH immediate width in bytes (0 for everything else).
    immediate: u8 = 0,
    exit: ExitKind = .fallthrough,
    flags: Flags = .{},

    /// Net stack delta (`stack_out - stack_in`); range -6..+1.
    pub fn stackChange(self: OpInfo) i16 {
        return @as(i16, self.stack_out) - @as(i16, self.stack_in);
    }
};

/// 256-entry opcode property table. Gap bytes default to the invalid row.
pub const table: [256]OpInfo = blk: {
    var t = [_]OpInfo{.{ .exit = .invalid }} ** 256;
    for (std.enums.values(Opcode)) |op| {
        var row = infoFor(op);
        row.defined = true;
        row.name = @tagName(op);
        t[@intFromEnum(op)] = row;
    }
    break :blk t;
};

/// Direct byte lookup. Every byte maps to a row (no `orelse` dance).
pub inline fn info(opcode_byte: u8) OpInfo {
    return table[opcode_byte];
}

/// The declarative spec: one row per named opcode. `defined` is stamped by
/// `table`, `exit` defaults to `.fallthrough`, flags default to empty — so a
/// plain arithmetic op is just gas + stack heights. The `_` prong covers only
/// unnamed opcode bytes; the compiler still errors if a new named opcode is
/// added without a row here.
fn infoFor(op: Opcode) OpInfo {
    return switch (op) {
        // 0x00s — arithmetic
        .STOP => .{ .exit = .stop },
        .ADD => .{ .static_gas = 3, .stack_in = 2, .stack_out = 1 },
        .MUL => .{ .static_gas = 5, .stack_in = 2, .stack_out = 1 },
        .SUB => .{ .static_gas = 3, .stack_in = 2, .stack_out = 1 },
        .DIV => .{ .static_gas = 5, .stack_in = 2, .stack_out = 1 },
        .SDIV => .{ .static_gas = 5, .stack_in = 2, .stack_out = 1 },
        .MOD => .{ .static_gas = 5, .stack_in = 2, .stack_out = 1 },
        .SMOD => .{ .static_gas = 5, .stack_in = 2, .stack_out = 1 },
        .ADDMOD => .{ .static_gas = 8, .stack_in = 3, .stack_out = 1 },
        .MULMOD => .{ .static_gas = 8, .stack_in = 3, .stack_out = 1 },
        .EXP => .{ .static_gas = 10, .stack_in = 2, .stack_out = 1, .flags = .{ .has_dynamic_gas = true } },
        .SIGNEXTEND => .{ .static_gas = 5, .stack_in = 2, .stack_out = 1 },

        // 0x10s — comparison & bitwise
        .LT => .{ .static_gas = 3, .stack_in = 2, .stack_out = 1 },
        .GT => .{ .static_gas = 3, .stack_in = 2, .stack_out = 1 },
        .SLT => .{ .static_gas = 3, .stack_in = 2, .stack_out = 1 },
        .SGT => .{ .static_gas = 3, .stack_in = 2, .stack_out = 1 },
        .EQ => .{ .static_gas = 3, .stack_in = 2, .stack_out = 1 },
        .ISZERO => .{ .static_gas = 3, .stack_in = 1, .stack_out = 1 },
        .AND => .{ .static_gas = 3, .stack_in = 2, .stack_out = 1 },
        .OR => .{ .static_gas = 3, .stack_in = 2, .stack_out = 1 },
        .XOR => .{ .static_gas = 3, .stack_in = 2, .stack_out = 1 },
        .NOT => .{ .static_gas = 3, .stack_in = 1, .stack_out = 1 },
        .BYTE => .{ .static_gas = 3, .stack_in = 2, .stack_out = 1 },
        .SHL => .{ .static_gas = 3, .stack_in = 2, .stack_out = 1 },
        .SHR => .{ .static_gas = 3, .stack_in = 2, .stack_out = 1 },
        .SAR => .{ .static_gas = 3, .stack_in = 2, .stack_out = 1 },
        .CLZ => .{ .static_gas = 5, .stack_in = 1, .stack_out = 1 },

        // 0x20 — keccak
        .KECCAK256 => .{ .static_gas = 30, .stack_in = 2, .stack_out = 1, .flags = .{ .has_dynamic_gas = true } },

        // 0x30s — environment / calldata / code
        .ADDRESS => .{ .static_gas = 2, .stack_out = 1 },
        .BALANCE => .{ .static_gas = 20, .stack_in = 1, .stack_out = 1, .flags = .{ .has_dynamic_gas = true, .touches_host = true } },
        .ORIGIN => .{ .static_gas = 2, .stack_out = 1 },
        .CALLER => .{ .static_gas = 2, .stack_out = 1 },
        .CALLVALUE => .{ .static_gas = 2, .stack_out = 1 },
        .CALLDATALOAD => .{ .static_gas = 3, .stack_in = 1, .stack_out = 1 },
        .CALLDATASIZE => .{ .static_gas = 2, .stack_out = 1 },
        .CALLDATACOPY => .{ .static_gas = 3, .stack_in = 3, .flags = .{ .has_dynamic_gas = true } },
        .CODESIZE => .{ .static_gas = 2, .stack_out = 1 },
        .CODECOPY => .{ .static_gas = 3, .stack_in = 3, .flags = .{ .has_dynamic_gas = true } },
        .GASPRICE => .{ .static_gas = 2, .stack_out = 1 },
        .EXTCODESIZE => .{ .static_gas = 20, .stack_in = 1, .stack_out = 1, .flags = .{ .has_dynamic_gas = true, .touches_host = true } },
        .EXTCODECOPY => .{ .static_gas = 20, .stack_in = 4, .flags = .{ .has_dynamic_gas = true, .touches_host = true } },
        .RETURNDATASIZE => .{ .static_gas = 2, .stack_out = 1 },
        .RETURNDATACOPY => .{ .static_gas = 3, .stack_in = 3, .flags = .{ .has_dynamic_gas = true } },
        .EXTCODEHASH => .{ .static_gas = 400, .stack_in = 1, .stack_out = 1, .flags = .{ .has_dynamic_gas = true, .touches_host = true } },

        // 0x40s — block context
        .BLOCKHASH => .{ .static_gas = 20, .stack_in = 1, .stack_out = 1, .flags = .{ .has_dynamic_gas = true, .touches_host = true } },
        .COINBASE => .{ .static_gas = 2, .stack_out = 1 },
        .TIMESTAMP => .{ .static_gas = 2, .stack_out = 1 },
        .NUMBER => .{ .static_gas = 2, .stack_out = 1 },
        .PREVRANDAO => .{ .static_gas = 2, .stack_out = 1 },
        .GASLIMIT => .{ .static_gas = 2, .stack_out = 1 },
        .CHAINID => .{ .static_gas = 2, .stack_out = 1 },
        .SELFBALANCE => .{ .static_gas = 5, .stack_out = 1 },
        .BASEFEE => .{ .static_gas = 2, .stack_out = 1 },
        .BLOBHASH => .{ .static_gas = 3, .stack_in = 1, .stack_out = 1 },
        .BLOBBASEFEE => .{ .static_gas = 2, .stack_out = 1 },
        .SLOTNUM => .{ .static_gas = 2, .stack_out = 1 },

        // 0x50s — stack / memory / storage / flow
        .POP => .{ .static_gas = 2, .stack_in = 1 },
        .MLOAD => .{ .static_gas = 3, .stack_in = 1, .stack_out = 1, .flags = .{ .has_dynamic_gas = true } },
        .MSTORE => .{ .static_gas = 3, .stack_in = 2, .flags = .{ .has_dynamic_gas = true } },
        .MSTORE8 => .{ .static_gas = 3, .stack_in = 2, .flags = .{ .has_dynamic_gas = true } },
        .SLOAD => .{ .static_gas = 50, .stack_in = 1, .stack_out = 1, .flags = .{ .has_dynamic_gas = true, .touches_host = true } },
        .SSTORE => .{ .static_gas = 0, .stack_in = 2, .flags = .{ .has_dynamic_gas = true, .touches_host = true, .writes_state = true } },
        .JUMP => .{ .static_gas = 8, .stack_in = 1, .exit = .jump },
        .JUMPI => .{ .static_gas = 10, .stack_in = 2, .exit = .jumpi },
        .PC => .{ .static_gas = 2, .stack_out = 1 },
        .MSIZE => .{ .static_gas = 2, .stack_out = 1 },
        .GAS => .{ .static_gas = 2, .stack_out = 1, .flags = .{ .uses_gas_left = true } },
        .JUMPDEST => .{ .static_gas = 1 },
        .TLOAD => .{ .static_gas = 100, .stack_in = 1, .stack_out = 1, .flags = .{ .has_dynamic_gas = true, .touches_host = true } },
        .TSTORE => .{ .static_gas = 100, .stack_in = 2, .flags = .{ .has_dynamic_gas = true, .touches_host = true, .writes_state = true } },
        .MCOPY => .{ .static_gas = 3, .stack_in = 3, .flags = .{ .has_dynamic_gas = true } },
        .PUSH0 => .{ .static_gas = 2, .stack_out = 1 },

        // 0x60..0x7f — PUSH1..PUSH32 (immediate = N bytes)
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
        => .{ .static_gas = 3, .stack_out = 1, .immediate = @intFromEnum(op) - @intFromEnum(Opcode.PUSH0) },

        // 0x80..0x8f — DUP1..DUP16 (need N deep, leave N+1)
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
            break :blk2 .{ .static_gas = 3, .stack_in = n, .stack_out = n + 1 };
        },

        // 0x90..0x9f — SWAP1..SWAP16 (need N+1 deep, height unchanged)
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
            break :blk2 .{ .static_gas = 3, .stack_in = n + 1, .stack_out = n + 1 };
        },

        // 0xa0..0xa4 — LOG0..LOG4 (pops mem offset+size + N topics)
        .LOG0, .LOG1, .LOG2, .LOG3, .LOG4 => blk2: {
            const n: u8 = @intFromEnum(op) - @intFromEnum(Opcode.LOG0);
            break :blk2 .{
                .static_gas = 375 * (@as(u16, n) + 1),
                .stack_in = n + 2,
                .flags = .{ .has_dynamic_gas = true, .touches_host = true, .writes_state = true },
            };
        },

        .DUPN => .{ .static_gas = 3, .stack_in = 235, .stack_out = 236 },
        .SWAPN => .{ .static_gas = 3, .stack_in = 236, .stack_out = 236 },
        .EXCHANGE => .{ .static_gas = 3, .stack_in = 30, .stack_out = 30 },

        // 0xf0s — system / calls (all share uses_gas_left + dynamic + host + state)
        .CREATE => .{ .static_gas = 32000, .stack_in = 3, .stack_out = 1, .flags = .{ .uses_gas_left = true, .has_dynamic_gas = true, .touches_host = true, .writes_state = true } },
        .CALL => .{ .static_gas = 40, .stack_in = 7, .stack_out = 1, .flags = .{ .uses_gas_left = true, .has_dynamic_gas = true, .touches_host = true, .writes_state = true } },
        .CALLCODE => .{ .static_gas = 40, .stack_in = 7, .stack_out = 1, .flags = .{ .uses_gas_left = true, .has_dynamic_gas = true, .touches_host = true, .writes_state = true } },
        .RETURN => .{ .static_gas = 0, .stack_in = 2, .exit = .return_, .flags = .{ .has_dynamic_gas = true } },
        .DELEGATECALL => .{ .static_gas = 40, .stack_in = 6, .stack_out = 1, .flags = .{ .uses_gas_left = true, .has_dynamic_gas = true, .touches_host = true, .writes_state = true } },
        .CREATE2 => .{ .static_gas = 32000, .stack_in = 4, .stack_out = 1, .flags = .{ .uses_gas_left = true, .has_dynamic_gas = true, .touches_host = true, .writes_state = true } },
        .STATICCALL => .{ .static_gas = 40, .stack_in = 6, .stack_out = 1, .flags = .{ .uses_gas_left = true, .has_dynamic_gas = true, .touches_host = true, .writes_state = true } },
        .REVERT => .{ .static_gas = 0, .stack_in = 2, .exit = .revert, .flags = .{ .has_dynamic_gas = true } },
        .INVALID => .{ .exit = .invalid },
        .SELFDESTRUCT => .{ .static_gas = 0, .stack_in = 1, .exit = .selfdestruct, .flags = .{ .has_dynamic_gas = true, .touches_host = true, .writes_state = true } },
        _ => .{ .exit = .invalid },
    };
}

test "Opcode can represent unnamed opcode bytes" {
    const opcode: Opcode = @enumFromInt(0x0c);
    try std.testing.expectEqual(@as(u8, 0x0c), @intFromEnum(opcode));

    const row = infoFor(opcode);
    try std.testing.expect(!row.defined);
    try std.testing.expectEqual(ExitKind.invalid, row.exit);
}

test "opcode table reproduces the per-opcode switches" {
    const expectEqual = std.testing.expectEqual;

    // gap byte -> undefined, invalid exit, zeroed
    try std.testing.expect(!table[0x0c].defined);
    try expectEqual(ExitKind.invalid, table[0x0c].exit);

    // INVALID (0xfe) is a *defined* opcode that also exits invalid
    try std.testing.expect(table[@intFromEnum(Opcode.INVALID)].defined);
    try expectEqual(ExitKind.invalid, table[@intFromEnum(Opcode.INVALID)].exit);

    // gas + stack delta for a plain binary op
    const add = table[@intFromEnum(Opcode.ADD)];
    try std.testing.expectEqualStrings("ADD", add.name.?);
    try expectEqual(@as(u16, 3), add.static_gas);
    try expectEqual(@as(i16, -1), add.stackChange());

    // Historically repriced opcodes keep base gas here; fork-resolved gas
    // belongs to the protocol definition.
    try expectEqual(@as(u16, 20), table[@intFromEnum(Opcode.BALANCE)].static_gas);
    try expectEqual(@as(u16, 20), table[@intFromEnum(Opcode.EXTCODESIZE)].static_gas);
    try expectEqual(@as(u16, 20), table[@intFromEnum(Opcode.EXTCODECOPY)].static_gas);
    try expectEqual(@as(u16, 400), table[@intFromEnum(Opcode.EXTCODEHASH)].static_gas);
    try expectEqual(@as(u16, 50), table[@intFromEnum(Opcode.SLOAD)].static_gas);
    try expectEqual(@as(u16, 0), table[@intFromEnum(Opcode.SELFDESTRUCT)].static_gas);

    // PUSH immediate width
    try expectEqual(@as(u8, 1), table[@intFromEnum(Opcode.PUSH1)].immediate);
    try expectEqual(@as(u8, 32), table[@intFromEnum(Opcode.PUSH32)].immediate);

    // DUP/SWAP height bookkeeping (read deep, no pop)
    try expectEqual(@as(u8, 3), table[@intFromEnum(Opcode.DUP3)].stack_in);
    try expectEqual(@as(u8, 4), table[@intFromEnum(Opcode.DUP3)].stack_out);
    try expectEqual(@as(i16, 0), table[@intFromEnum(Opcode.SWAP5)].stackChange());

    // EIP-8024 opcodes carry execution immediates but do not mask JUMPDEST analysis.
    try expectEqual(@as(u8, 0), table[@intFromEnum(Opcode.DUPN)].immediate);
    try expectEqual(@as(u16, 3), table[@intFromEnum(Opcode.DUPN)].static_gas);
    try expectEqual(@as(i16, 1), table[@intFromEnum(Opcode.DUPN)].stackChange());
    try expectEqual(@as(i16, 0), table[@intFromEnum(Opcode.SWAPN)].stackChange());
    try expectEqual(@as(u8, 30), table[@intFromEnum(Opcode.EXCHANGE)].stack_in);

    // LOG family gas + flags
    try expectEqual(@as(u16, 1875), table[@intFromEnum(Opcode.LOG4)].static_gas);
    try std.testing.expect(table[@intFromEnum(Opcode.LOG4)].flags.writes_state);

    // exits + flags on the spicy ones
    try expectEqual(ExitKind.jump, table[@intFromEnum(Opcode.JUMP)].exit);
    try expectEqual(ExitKind.selfdestruct, table[@intFromEnum(Opcode.SELFDESTRUCT)].exit);
    try std.testing.expect(table[@intFromEnum(Opcode.CALL)].flags.uses_gas_left);
    try std.testing.expect(table[@intFromEnum(Opcode.SSTORE)].flags.writes_state);
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
        try std.testing.expect(row.exit != .eof);

        if (row.defined) {
            defined_count += 1;
            try std.testing.expect(row.immediate <= 32);
        } else {
            try std.testing.expectEqual(@as(u16, 0), row.static_gas);
            try std.testing.expectEqual(@as(u8, 0), row.stack_in);
            try std.testing.expectEqual(@as(u8, 0), row.stack_out);
            try std.testing.expectEqual(@as(u8, 0), row.immediate);
            try std.testing.expectEqual(ExitKind.invalid, row.exit);
            try std.testing.expectEqual(Flags{}, row.flags);
            try std.testing.expect(row.name == null);
        }
    }
    try std.testing.expectEqual(std.enums.values(Opcode).len, defined_count);
}
