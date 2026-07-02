const std = @import("std");
const Config = @import("../Config.zig");
const Metadata = @import("Metadata.zig");
const scanner = @import("scanner.zig");
const t = @import("../t.zig");
const opcode_info = @import("../opcode.zig");
const Opcode = opcode_info.Opcode;

const Analysis = @This();

pub const invalid_instruction_index = std.math.maxInt(u32);
pub const invalid_block_index = std.math.maxInt(u32);

pub const InstructionMeta = struct {
    pc: u32,
    len: u8,
    opcode: Opcode,
    push_len: u8,
    immediate_len: u8,
    static_gas: u16,

    pub fn isPush(self: InstructionMeta) bool {
        return self.opcode.isPush();
    }

    pub fn pcEnd(self: InstructionMeta) usize {
        return @as(usize, self.pc) + self.len;
    }

    pub fn nextPc(self: InstructionMeta) usize {
        return @as(usize, self.pc) + 1 + self.push_len;
    }

    pub fn isContiguousWith(self: InstructionMeta, next: InstructionMeta) bool {
        return self.pcEnd() == next.pc;
    }

    pub fn pushValue(self: InstructionMeta, bytes: []const u8) u256 {
        return decodePushValue(bytes, self.pc, self.push_len);
    }
};

pub const BlockExit = opcode_info.ExitKind;

pub const BlockFlags = packed struct(u8) {
    uses_gas_left: bool = false,
    has_dynamic_gas: bool = false,
    touches_host: bool = false,
    writes_state: bool = false,
    unknown_opcode: bool = false,
    reserved: u3 = 0,

    fn merge(self: *BlockFlags, other: BlockFlags) void {
        self.uses_gas_left = self.uses_gas_left or other.uses_gas_left;
        self.has_dynamic_gas = self.has_dynamic_gas or other.has_dynamic_gas;
        self.touches_host = self.touches_host or other.touches_host;
        self.writes_state = self.writes_state or other.writes_state;
        self.unknown_opcode = self.unknown_opcode or other.unknown_opcode;
    }

    pub fn isStaticSafe(self: BlockFlags) bool {
        return !self.uses_gas_left and
            !self.has_dynamic_gas and
            !self.touches_host and
            !self.writes_state and
            !self.unknown_opcode;
    }

    pub fn isMeteredFlatSafe(self: BlockFlags) bool {
        return !self.uses_gas_left and
            !self.touches_host and
            !self.writes_state and
            !self.unknown_opcode;
    }

    pub fn isPrechargeSafe(self: BlockFlags) bool {
        return !self.has_dynamic_gas and
            !self.touches_host and
            !self.writes_state and
            !self.unknown_opcode;
    }
};

pub const BlockMeta = struct {
    first_instruction: u32,
    last_instruction: u32,
    pc_start: u32,
    pc_end: u32,
    static_gas: u32,
    fallthrough_block: u32,
    stack_required: u16,
    stack_max_growth: u16,
    stack_change: i16,
    exit: BlockExit,
    flags: BlockFlags,

    pub fn isStaticSafe(self: BlockMeta) bool {
        return self.flags.isStaticSafe();
    }

    pub fn isMeteredFlatSafe(self: BlockMeta) bool {
        return self.flags.isMeteredFlatSafe();
    }

    pub fn isPrechargeSafe(self: BlockMeta) bool {
        return self.flags.isPrechargeSafe();
    }
};

analyzed: bool,
metadata: Metadata,
pc_to_instruction: []u32,
pc_to_block: []u32,
instructions: []InstructionMeta,
blocks: []BlockMeta,

pub const empty = Analysis{
    .analyzed = false,
    .metadata = .empty,
    .pc_to_instruction = &.{},
    .pc_to_block = &.{},
    .instructions = &.{},
    .blocks = &.{},
};

pub fn init(allocator: std.mem.Allocator, bytes: []const u8) !Analysis {
    return initWithConfig(allocator, bytes, .base);
}

pub fn initWithConfig(allocator: std.mem.Allocator, bytes: []const u8, config: Config) !Analysis {
    var self = empty;
    errdefer self.deinit(allocator);

    self.analyzed = true;
    if (bytes.len == 0) return self;
    if (bytes.len > invalid_instruction_index) return error.CodeTooLarge;

    self.metadata = try Metadata.init(allocator, bytes.len);
    self.pc_to_instruction = try allocator.alloc(u32, bytes.len);
    @memset(self.pc_to_instruction, invalid_instruction_index);
    self.pc_to_block = try allocator.alloc(u32, bytes.len);
    @memset(self.pc_to_block, invalid_block_index);

    var instructions: std.ArrayList(InstructionMeta) = .empty;
    defer instructions.deinit(allocator);
    var blocks: std.ArrayList(BlockMeta) = .empty;
    defer blocks.deinit(allocator);
    var builder = AnalysisBuilder{
        .analysis = &self,
        .allocator = allocator,
        .bytes = bytes,
        .instructions = &instructions,
        .blocks = &blocks,
    };

    switch (config.jumpDestStrategy()) {
        .legacy => try decodeScalar(&builder),
        .simd_bitmask => try decodeSimdBitmask(&builder),
    }

    try builder.finish();
    self.instructions = try instructions.toOwnedSlice(allocator);
    self.blocks = try blocks.toOwnedSlice(allocator);
    return self;
}

pub fn deinit(self: *Analysis, allocator: std.mem.Allocator) void {
    self.metadata.deinit(allocator);
    allocator.free(self.pc_to_instruction);
    allocator.free(self.pc_to_block);
    allocator.free(self.instructions);
    allocator.free(self.blocks);
    self.* = empty;
}

pub fn isValidJumpDest(self: *const Analysis, bytes: []const u8, target: usize) bool {
    if (target >= bytes.len) return false;

    const opcode: Opcode = @enumFromInt(bytes[target]);
    if (opcode != .JUMPDEST) return false;

    return self.metadata.jumpdest.isSet(target);
}

pub fn isInstructionStart(self: *const Analysis, pc: usize) bool {
    return pc < self.metadata.opcode_start.bit_length and self.metadata.opcode_start.isSet(pc);
}

pub fn instructionIndexAtPc(self: *const Analysis, pc: usize) ?u32 {
    if (pc >= self.pc_to_instruction.len) return null;
    const index = self.pc_to_instruction[pc];
    return if (index == invalid_instruction_index) null else index;
}

pub fn blockIndexAtPc(self: *const Analysis, pc: usize) ?u32 {
    if (pc >= self.pc_to_block.len) return null;
    const index = self.pc_to_block[pc];
    return if (index == invalid_block_index) null else index;
}

pub fn blockIndexForInstruction(self: *const Analysis, instruction_index: usize) ?u32 {
    if (instruction_index >= self.instructions.len) return null;

    var lo: usize = 0;
    var hi: usize = self.blocks.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        const block = self.blocks[mid];
        if (instruction_index < block.first_instruction) {
            hi = mid;
        } else if (instruction_index >= block.last_instruction) {
            lo = mid + 1;
        } else {
            return @intCast(mid);
        }
    }
    return null;
}

pub fn jumpTargetBlock(self: *const Analysis, pc: usize) ?u32 {
    if (pc >= self.metadata.jumpdest.bit_length or !self.metadata.jumpdest.isSet(pc)) {
        return null;
    }
    return self.blockIndexAtPc(pc);
}

pub fn fallthroughBlockIndex(self: *const Analysis, block_index: usize) ?u32 {
    if (block_index >= self.blocks.len) return null;
    const next_index = self.blocks[block_index].fallthrough_block;
    return if (next_index == invalid_block_index) null else next_index;
}

fn decodeScalar(builder: *AnalysisBuilder) !void {
    var pc: usize = 0;
    const bytes = builder.bytes;
    while (pc < bytes.len) {
        const opcode: Opcode = @enumFromInt(bytes[pc]);
        const pc_end = nextInstructionPc(bytes.len, pc, opcode);
        try builder.appendDecodedInstruction(pc, pc_end, true);
        pc = pc_end;
    }
}

fn decodeSimdBitmask(builder: *AnalysisBuilder) !void {
    var context = DecodeContext{
        .builder = builder,
    };

    const bytes = builder.bytes;
    try scanner.scanFallible(*DecodeContext, &context, bytes, DecodeContext.consume);

    if (context.previous_pc) |pc| {
        try builder.appendDecodedInstruction(pc, bytes.len, false);
    }
}

const DecodeContext = struct {
    builder: *AnalysisBuilder,
    previous_pc: ?usize = null,

    fn consume(context: *DecodeContext, base: usize, masks: scanner.BoundaryMasks) !void {
        var pending = masks.boundary;
        while (pending != 0) {
            const bit: usize = @intCast(@ctz(pending));
            const bit_mask = @as(u64, 1) << @intCast(bit);
            pending &= pending - 1;

            const instruction_pc = base + bit;
            const analysis = context.builder.analysis;
            analysis.metadata.opcode_start.set(instruction_pc);
            if ((masks.jumpdest & bit_mask) != 0) analysis.metadata.jumpdest.set(instruction_pc);
            const opcode: Opcode = @enumFromInt(context.builder.bytes[instruction_pc]);
            analysis.metadata.markPushOpcode(instruction_pc, opcode);
            if (context.previous_pc) |pc| {
                try context.builder.appendDecodedInstruction(pc, instruction_pc, false);
            }
            context.previous_pc = instruction_pc;
        }
    }
};

const AnalysisBuilder = struct {
    analysis: *Analysis,
    allocator: std.mem.Allocator,
    bytes: []const u8,
    instructions: *std.ArrayList(InstructionMeta),
    blocks: *std.ArrayList(BlockMeta),
    current: BlockAccumulator = .{},

    fn appendDecodedInstruction(
        self: *AnalysisBuilder,
        pc: usize,
        pc_end: usize,
        comptime mark_byte_maps: bool,
    ) !void {
        const opcode: Opcode = @enumFromInt(self.bytes[pc]);
        const row = opcode_info.info(opcode.toByte());
        const instruction_index = try u32Index(self.instructions.items.len);

        if (self.current.active and opcode == .JUMPDEST) {
            try self.closeBlock(.fallthrough);
        }
        if (!self.current.active) {
            self.startBlock(pc, instruction_index);
        }

        if (mark_byte_maps) {
            self.analysis.metadata.markOpcodeStart(pc, opcode);
        }
        self.analysis.pc_to_instruction[pc] = instruction_index;
        self.analysis.pc_to_block[pc] = try u32Index(self.blocks.items.len);

        const push_len = row.immediate;
        const meta = InstructionMeta{
            .pc = try u32Index(pc),
            .len = try instructionByteLen(pc, pc_end),
            .opcode = opcode,
            .push_len = push_len,
            .immediate_len = immediateLen(self.bytes.len, pc, push_len),
            .static_gas = row.static_gas,
        };
        try self.instructions.append(self.allocator, meta);
        self.current.include(row, meta);

        if (row.exit != .fallthrough) {
            try self.closeBlock(row.exit);
        }
    }

    fn finish(self: *AnalysisBuilder) !void {
        if (self.current.active) {
            try self.closeBlock(.fallthrough);
        }
    }

    fn startBlock(self: *AnalysisBuilder, pc: usize, first_instruction: u32) void {
        self.current = .{
            .active = true,
            .first_instruction = first_instruction,
            .last_instruction = first_instruction,
            .pc_start = @intCast(pc),
            .pc_end = @intCast(pc),
        };
    }

    fn closeBlock(self: *AnalysisBuilder, exit: BlockExit) !void {
        std.debug.assert(self.current.active);

        const block_index = try u32Index(self.blocks.items.len);
        var block_exit = exit;
        if (block_exit == .fallthrough and self.current.pc_end >= self.bytes.len) {
            block_exit = .eof;
        }

        try self.blocks.append(self.allocator, .{
            .first_instruction = self.current.first_instruction,
            .last_instruction = self.current.last_instruction,
            .pc_start = self.current.pc_start,
            .pc_end = self.current.pc_end,
            .static_gas = try gasTotal(self.current.static_gas),
            .stack_required = try stackCount(self.current.stack_required),
            .stack_max_growth = try stackCount(self.current.stack_max_growth),
            .stack_change = try stackDelta(self.current.stack_height - self.current.stack_required),
            .exit = block_exit,
            .fallthrough_block = invalid_block_index,
            .flags = self.current.flags,
        });

        self.patchPreviousFallthrough(block_index);
        self.current = .{};
    }

    fn patchPreviousFallthrough(self: *AnalysisBuilder, block_index: u32) void {
        if (block_index == 0) return;

        const previous_index: usize = @intCast(block_index - 1);
        var previous = &self.blocks.items[previous_index];
        switch (previous.exit) {
            .fallthrough, .jumpi => {},
            else => return,
        }
        if (previous.pc_end == self.current.pc_start) {
            previous.fallthrough_block = block_index;
        }
    }
};

const BlockAccumulator = struct {
    active: bool = false,
    first_instruction: u32 = 0,
    last_instruction: u32 = 0,
    pc_start: u32 = 0,
    pc_end: u32 = 0,
    static_gas: u64 = 0,
    stack_height: i64 = 0,
    stack_required: i64 = 0,
    stack_max_growth: i64 = 0,
    flags: BlockFlags = .{},

    fn include(self: *BlockAccumulator, row: opcode_info.OpInfo, meta: InstructionMeta) void {
        self.last_instruction += 1;
        self.pc_end = @intCast(meta.pcEnd());
        self.static_gas += @as(u64, row.static_gas);
        self.flags.merge(blockFlagsForInfo(row));

        const required = @as(i64, row.stack_in);
        if (self.stack_height < required) {
            self.stack_required += required - self.stack_height;
            self.stack_height = required;
        }
        self.stack_height += row.stackChange();
        self.stack_max_growth = @max(self.stack_max_growth, self.stack_height);
    }
};

fn stackCount(value: i64) !u16 {
    std.debug.assert(value >= 0);
    return std.math.cast(u16, value) orelse error.CodeTooLarge;
}

fn stackDelta(value: i64) !i16 {
    return std.math.cast(i16, value) orelse error.CodeTooLarge;
}

fn gasTotal(value: u64) !u32 {
    return std.math.cast(u32, value) orelse error.CodeTooLarge;
}

fn blockFlagsForInfo(row: opcode_info.OpInfo) BlockFlags {
    return .{
        .uses_gas_left = row.flags.uses_gas_left,
        .has_dynamic_gas = row.flags.has_dynamic_gas,
        .touches_host = row.flags.touches_host,
        .writes_state = row.flags.writes_state,
        .unknown_opcode = !row.defined,
    };
}

fn u32Index(index: usize) !u32 {
    return std.math.cast(u32, index) orelse error.CodeTooLarge;
}

fn instructionByteLen(pc: usize, pc_end: usize) !u8 {
    std.debug.assert(pc_end >= pc);
    return std.math.cast(u8, pc_end - pc) orelse error.CodeTooLarge;
}

fn immediateLen(bytes_len: usize, pc: usize, push_len: u8) u8 {
    const start = pc + 1;
    if (start >= bytes_len) return 0;
    return @intCast(@min(@as(usize, push_len), bytes_len - start));
}

fn decodePushValue(bytes: []const u8, pc: usize, push_len: u8) u256 {
    var value: u256 = 0;
    for (0..push_len) |index| {
        value <<= 8;
        const byte_index = pc + 1 + index;
        if (byte_index < bytes.len) {
            value |= @intCast(bytes[byte_index]);
        }
    }
    return value;
}

fn nextInstructionPc(bytes_len: usize, pc: usize, opcode: Opcode) usize {
    const next = pc + 1 + @as(usize, opcode_info.info(opcode.toByte()).immediate);
    return @min(bytes_len, next);
}

test "code analysis skips PUSH data for jumpdest and boundary maps" {
    const bytecode = t.bytecode(.{ .PUSH1, .JUMPDEST, .JUMPDEST });
    var analysis = try Analysis.init(std.testing.allocator, &bytecode);
    defer analysis.deinit(std.testing.allocator);

    try std.testing.expect(analysis.analyzed);
    try std.testing.expect(!analysis.isInstructionStart(1));
    try std.testing.expect(!analysis.isValidJumpDest(&bytecode, 1));
    try std.testing.expect(analysis.isInstructionStart(2));
    try std.testing.expect(analysis.isValidJumpDest(&bytecode, 2));
    try std.testing.expectEqual(@as(usize, 2), analysis.instructions.len);
    try std.testing.expectEqual(@as(?u32, null), analysis.instructionIndexAtPc(1));
    try std.testing.expectEqual(@as(?u32, 1), analysis.instructionIndexAtPc(2));
}

test "code analysis metadata stays compact" {
    try std.testing.expectEqual(@as(usize, 12), @sizeOf(InstructionMeta));
    try std.testing.expectEqual(@as(usize, 32), @sizeOf(BlockMeta));
}

test "code analysis records truncated PUSH metadata" {
    const bytecode = t.bytecode(.{ .PUSH2, 0x01 });
    var analysis = try Analysis.init(std.testing.allocator, &bytecode);
    defer analysis.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), analysis.instructions.len);
    try std.testing.expectEqual(@as(u32, 0), analysis.instructions[0].pc);
    try std.testing.expectEqual(@as(usize, 2), analysis.instructions[0].pcEnd());
    try std.testing.expectEqual(@as(u8, 2), analysis.instructions[0].push_len);
    try std.testing.expectEqual(@as(u8, 1), analysis.instructions[0].immediate_len);
    try std.testing.expectEqual(@as(u256, 0x0100), analysis.instructions[0].pushValue(&bytecode));
    try std.testing.expectEqual(@as(usize, 3), analysis.instructions[0].nextPc());
    try std.testing.expect(!analysis.isInstructionStart(1));
}

test "code analysis predecodes full PUSH immediates" {
    const bytecode = t.bytecode(.{ .PUSH3, 0x01, 0x02, 0x03, .STOP });
    var analysis = try Analysis.init(std.testing.allocator, &bytecode);
    defer analysis.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u8, 3), analysis.instructions[0].push_len);
    try std.testing.expectEqual(@as(u8, 3), analysis.instructions[0].immediate_len);
    try std.testing.expectEqual(@as(u256, 0x010203), analysis.instructions[0].pushValue(&bytecode));
    try std.testing.expectEqual(@as(usize, 4), analysis.instructions[0].nextPc());
}

test "code analysis keeps unknown opcodes as instruction boundaries" {
    const bytecode = t.bytecode(.{ 0x0c, .JUMPDEST });
    var analysis = try Analysis.init(std.testing.allocator, &bytecode);
    defer analysis.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), analysis.instructions.len);
    try std.testing.expectEqual(@as(u8, 0x0c), analysis.instructions[0].opcode.toByte());
    try std.testing.expect(analysis.isInstructionStart(0));
    try std.testing.expect(analysis.isInstructionStart(1));
    try std.testing.expect(analysis.isValidJumpDest(&bytecode, 1));
}

test "code analysis builds basic block metadata" {
    const bytecode = t.bytecode(.{
        .PUSH1,    0x06,
        .JUMPI,    .JUMPDEST,
        .PUSH0,    .STOP,
        .JUMPDEST, .STOP,
    });
    var analysis = try Analysis.init(std.testing.allocator, &bytecode);
    defer analysis.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 3), analysis.blocks.len);
    try std.testing.expectEqual(@as(?u32, 0), analysis.blockIndexAtPc(0));
    try std.testing.expectEqual(@as(?u32, null), analysis.blockIndexAtPc(1));
    try std.testing.expectEqual(@as(?u32, 1), analysis.blockIndexAtPc(3));
    try std.testing.expectEqual(@as(?u32, 2), analysis.blockIndexAtPc(6));
    try std.testing.expectEqual(@as(?u32, 1), analysis.blockIndexForInstruction(3));

    const branch = analysis.blocks[0];
    try std.testing.expectEqual(BlockExit.jumpi, branch.exit);
    try std.testing.expectEqual(@as(u32, 13), branch.static_gas);
    try std.testing.expectEqual(@as(u16, 1), branch.stack_required);
    try std.testing.expectEqual(@as(u16, 1), branch.stack_max_growth);
    try std.testing.expectEqual(@as(i16, -1), branch.stack_change);
    try std.testing.expectEqual(@as(?u32, 1), analysis.fallthroughBlockIndex(0));
    try std.testing.expectEqual(@as(u32, 1), branch.fallthrough_block);

    const fallthrough = analysis.blocks[1];
    try std.testing.expectEqual(BlockExit.stop, fallthrough.exit);
    try std.testing.expectEqual(@as(u32, 3), fallthrough.static_gas);
    try std.testing.expectEqual(@as(u16, 0), fallthrough.stack_required);
    try std.testing.expectEqual(@as(u16, 1), fallthrough.stack_max_growth);
    try std.testing.expectEqual(@as(i16, 1), fallthrough.stack_change);
    try std.testing.expectEqual(@as(?u32, null), analysis.fallthroughBlockIndex(1));
    try std.testing.expectEqual(invalid_block_index, fallthrough.fallthrough_block);
}

test "code analysis blocks ignore jumpdest bytes inside push payloads" {
    const bytecode = t.bytecode(.{ .PUSH2, .JUMPDEST, .JUMPDEST, .JUMPDEST });
    var analysis = try Analysis.init(std.testing.allocator, &bytecode);
    defer analysis.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), analysis.instructions.len);
    try std.testing.expectEqual(@as(usize, 2), analysis.blocks.len);
    try std.testing.expectEqual(@as(?u32, 0), analysis.blockIndexAtPc(0));
    try std.testing.expectEqual(@as(?u32, null), analysis.blockIndexAtPc(1));
    try std.testing.expectEqual(@as(?u32, null), analysis.blockIndexAtPc(2));
    try std.testing.expectEqual(@as(?u32, 1), analysis.blockIndexAtPc(3));
    try std.testing.expectEqual(BlockExit.fallthrough, analysis.blocks[0].exit);
    try std.testing.expectEqual(BlockExit.eof, analysis.blocks[1].exit);
    try std.testing.expectEqual(@as(?u32, 1), analysis.fallthroughBlockIndex(0));
    try std.testing.expectEqual(@as(?u32, null), analysis.fallthroughBlockIndex(1));
    try std.testing.expectEqual(@as(u32, 1), analysis.blocks[0].fallthrough_block);
    try std.testing.expectEqual(invalid_block_index, analysis.blocks[1].fallthrough_block);
}

test "code analysis resolves jumpdest targets to block indexes" {
    const bytecode = t.bytecode(.{ .PUSH1, 0x04, .JUMP, .STOP, .JUMPDEST, .STOP });
    var analysis = try Analysis.init(std.testing.allocator, &bytecode);
    defer analysis.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(?u32, 2), analysis.jumpTargetBlock(4));
    try std.testing.expectEqual(@as(?u32, null), analysis.jumpTargetBlock(0));
    try std.testing.expectEqual(@as(?u32, null), analysis.jumpTargetBlock(3));
    try std.testing.expectEqual(@as(?u32, null), analysis.jumpTargetBlock(6));
    try std.testing.expectEqual(@as(?u32, null), analysis.fallthroughBlockIndex(0));
}

test "code analysis records block-local static gas totals" {
    const bytecode = t.bytecode(.{ .GAS, .PUSH0, .ADD });
    var analysis = try Analysis.init(std.testing.allocator, &bytecode);
    defer analysis.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), analysis.blocks.len);
    try std.testing.expect(analysis.blocks[0].isPrechargeSafe());
    try std.testing.expect(!analysis.blocks[0].isStaticSafe());
    try std.testing.expectEqual(@as(u32, 7), analysis.blocks[0].static_gas);
}

test "code analysis marks conservative block flags" {
    const bytecode = t.bytecode(.{ .GAS, .SSTORE, 0x0c });
    var analysis = try Analysis.init(std.testing.allocator, &bytecode);
    defer analysis.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), analysis.blocks.len);
    try std.testing.expect(analysis.blocks[0].flags.uses_gas_left);
    try std.testing.expect(analysis.blocks[0].flags.has_dynamic_gas);
    try std.testing.expect(analysis.blocks[0].flags.touches_host);
    try std.testing.expect(analysis.blocks[0].flags.writes_state);
    try std.testing.expect(analysis.blocks[0].flags.unknown_opcode);
    try std.testing.expectEqual(BlockExit.invalid, analysis.blocks[0].exit);
}

test "code analysis distinguishes INVALID from unknown opcodes" {
    const bytecode = t.bytecode(.{ .INVALID, 0x0c });
    var analysis = try Analysis.init(std.testing.allocator, &bytecode);
    defer analysis.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), analysis.blocks.len);
    try std.testing.expectEqual(BlockExit.invalid, analysis.blocks[0].exit);
    try std.testing.expect(!analysis.blocks[0].flags.unknown_opcode);
    try std.testing.expectEqual(BlockExit.invalid, analysis.blocks[1].exit);
    try std.testing.expect(analysis.blocks[1].flags.unknown_opcode);
}

test "code analysis keeps memory dynamic gas separate from host state flags" {
    const bytecode = t.bytecode(.{ .PUSH0, .MLOAD, .STOP });
    var analysis = try Analysis.init(std.testing.allocator, &bytecode);
    defer analysis.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), analysis.blocks.len);
    try std.testing.expect(!analysis.blocks[0].flags.uses_gas_left);
    try std.testing.expect(analysis.blocks[0].flags.has_dynamic_gas);
    try std.testing.expect(!analysis.blocks[0].flags.touches_host);
    try std.testing.expect(!analysis.blocks[0].flags.writes_state);
    try std.testing.expect(!analysis.blocks[0].flags.unknown_opcode);
}

test "code analysis keeps host storage and logs out of metered flat blocks" {
    const bytecode = t.bytecode(.{
        .PUSH0,  .SLOAD,
        .PUSH0,  .PUSH0,
        .SSTORE, .PUSH0,
        .PUSH0,  .LOG0,
        .STOP,
    });
    var analysis = try Analysis.init(std.testing.allocator, &bytecode);
    defer analysis.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), analysis.blocks.len);
    try std.testing.expect(!analysis.blocks[0].isStaticSafe());
    try std.testing.expect(!analysis.blocks[0].isMeteredFlatSafe());
    try std.testing.expect(analysis.blocks[0].flags.has_dynamic_gas);
    try std.testing.expect(analysis.blocks[0].flags.touches_host);
    try std.testing.expect(analysis.blocks[0].flags.writes_state);
}

test "code analysis keeps gas and call style opcodes out of metered flat blocks" {
    inline for (.{ .GAS, .CALL, .DELEGATECALL, .CREATE, .CREATE2, .SELFDESTRUCT }) |opcode| {
        const bytecode = t.bytecode(.{opcode});
        var analysis = try Analysis.init(std.testing.allocator, &bytecode);
        defer analysis.deinit(std.testing.allocator);

        try std.testing.expectEqual(@as(usize, 1), analysis.blocks.len);
        try std.testing.expect(!analysis.blocks[0].isMeteredFlatSafe());
    }
}

test "advanced code analysis SIMD boundary maps match scalar decode" {
    var bytecode = [_]u8{0} ** 48;
    bytecode[0] = Opcode.PUSH32.toByte();
    bytecode[1] = Opcode.JUMPDEST.toByte();
    bytecode[16] = Opcode.PUSH1.toByte();
    bytecode[31] = Opcode.JUMPDEST.toByte();
    bytecode[33] = Opcode.JUMPDEST.toByte();
    bytecode[34] = Opcode.PUSH1.toByte();
    bytecode[35] = Opcode.PUSH32.toByte();
    bytecode[36] = Opcode.JUMPDEST.toByte();

    var scalar = try Analysis.initWithConfig(std.testing.allocator, &bytecode, .base);
    defer scalar.deinit(std.testing.allocator);
    var simd = try Analysis.initWithConfig(std.testing.allocator, &bytecode, .advanced);
    defer simd.deinit(std.testing.allocator);

    try std.testing.expect(scalar.metadata.opcode_start.eql(simd.metadata.opcode_start));
    try std.testing.expect(scalar.metadata.jumpdest.eql(simd.metadata.jumpdest));
    try std.testing.expect(scalar.metadata.push_opcode.eql(simd.metadata.push_opcode));
    try std.testing.expectEqual(scalar.instructions.len, simd.instructions.len);
    for (scalar.instructions, simd.instructions) |lhs, rhs| {
        try std.testing.expectEqual(lhs.pc, rhs.pc);
        try std.testing.expectEqual(lhs.len, rhs.len);
        try std.testing.expectEqual(lhs.opcode, rhs.opcode);
        try std.testing.expectEqual(lhs.push_len, rhs.push_len);
        try std.testing.expectEqual(lhs.immediate_len, rhs.immediate_len);
        try std.testing.expectEqual(lhs.pushValue(&bytecode), rhs.pushValue(&bytecode));
    }
}
