const std = @import("std");
const Config = @import("../Config.zig");
const Metadata = @import("Metadata.zig");
const Scanner = @import("Scanner.zig");
const t = @import("../t.zig");
const instruction = @import("../instruction.zig");
const Opcode = @import("../opcode.zig").Opcode;

const Analysis = @This();

pub const invalid_instruction_index = std.math.maxInt(u32);

const jumpdest_opcode = @intFromEnum(Opcode.JUMPDEST);
const push0_opcode = @intFromEnum(Opcode.PUSH0);
const push1_opcode = @intFromEnum(Opcode.PUSH1);
const push32_opcode = @intFromEnum(Opcode.PUSH32);
const simd_lanes = Scanner.lanes;

pub const InstructionMeta = struct {
    pc: usize,
    pc_end: usize,
    opcode: u8,
    push_len: u8,
    immediate_len: u8,
    static_gas: u16,

    pub fn isPush(self: InstructionMeta) bool {
        return self.opcode >= push0_opcode and self.opcode <= push32_opcode;
    }
};

pub const PatternCensus = struct {
    push_pop: usize = 0,
    push_mload: usize = 0,
    push_push_mstore: usize = 0,
    push_push_mstore8: usize = 0,
    push_push_binary: usize = 0,
    push_jump: usize = 0,
    push_jumpi: usize = 0,

    pub fn total(self: PatternCensus) usize {
        return self.push_pop +
            self.push_mload +
            self.push_push_mstore +
            self.push_push_mstore8 +
            self.push_push_binary +
            self.push_jump +
            self.push_jumpi;
    }
};

const OpcodeClass = enum(u8) {
    other,
    push,
    pop,
    mload,
    mstore,
    mstore8,
    jump,
    jumpi,
    binary,
};

analyzed: bool,
metadata: Metadata,
pc_to_instruction: []u32,
instructions: []InstructionMeta,
classes: []u8,

pub const empty = Analysis{
    .analyzed = false,
    .metadata = .empty,
    .pc_to_instruction = &.{},
    .instructions = &.{},
    .classes = &.{},
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

    var instructions: std.ArrayList(InstructionMeta) = .empty;
    defer instructions.deinit(allocator);
    var classes: std.ArrayList(u8) = .empty;
    defer classes.deinit(allocator);

    switch (config.jumpDestStrategy()) {
        .legacy => try self.decodeScalar(allocator, bytes, &instructions, &classes),
        .simd_bitmask => try self.decodeSimdBitmask(allocator, bytes, &instructions, &classes),
    }

    self.instructions = try instructions.toOwnedSlice(allocator);
    self.classes = try classes.toOwnedSlice(allocator);
    return self;
}

pub fn deinit(self: *Analysis, allocator: std.mem.Allocator) void {
    self.metadata.deinit(allocator);
    allocator.free(self.pc_to_instruction);
    allocator.free(self.instructions);
    allocator.free(self.classes);
    self.* = empty;
}

pub fn isValidJumpDest(self: *const Analysis, bytes: []const u8, target: usize) bool {
    if (target >= bytes.len or bytes[target] != jumpdest_opcode) return false;
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

pub fn patternCensus(self: *const Analysis) PatternCensus {
    return patternCensusSimd(self.classes);
}

fn decodeScalar(
    self: *Analysis,
    allocator: std.mem.Allocator,
    bytes: []const u8,
    instructions: *std.ArrayList(InstructionMeta),
    classes: *std.ArrayList(u8),
) !void {
    var pc: usize = 0;
    while (pc < bytes.len) {
        const pc_end = nextInstructionPc(bytes.len, pc, bytes[pc]);
        try self.appendDecodedInstruction(allocator, bytes, pc, pc_end, instructions, classes, true);
        pc = pc_end;
    }
}

fn decodeSimdBitmask(
    self: *Analysis,
    allocator: std.mem.Allocator,
    bytes: []const u8,
    instructions: *std.ArrayList(InstructionMeta),
    classes: *std.ArrayList(u8),
) !void {
    var context = DecodeContext{
        .analysis = self,
        .allocator = allocator,
        .bytes = bytes,
        .instructions = instructions,
        .classes = classes,
    };

    try Scanner.scanFallible(*DecodeContext, &context, bytes, DecodeContext.consume);

    if (context.previous_pc) |pc| {
        try self.appendDecodedInstruction(allocator, bytes, pc, bytes.len, instructions, classes, false);
    }
}

const DecodeContext = struct {
    analysis: *Analysis,
    allocator: std.mem.Allocator,
    bytes: []const u8,
    instructions: *std.ArrayList(InstructionMeta),
    classes: *std.ArrayList(u8),
    previous_pc: ?usize = null,

    fn consume(context: *DecodeContext, base: usize, masks: Scanner.BoundaryMasks) !void {
        var pending = masks.boundary;
        while (pending != 0) {
            const bit: usize = @intCast(@ctz(pending));
            const bit_mask = @as(u64, 1) << @intCast(bit);
            pending &= pending - 1;

            const instruction_pc = base + bit;
            context.analysis.metadata.opcode_start.set(instruction_pc);
            if ((masks.jumpdest & bit_mask) != 0) context.analysis.metadata.jumpdest.set(instruction_pc);
            context.analysis.metadata.markOpcodeClass(instruction_pc, context.bytes[instruction_pc]);
            if (context.previous_pc) |pc| {
                try context.analysis.appendDecodedInstruction(
                    context.allocator,
                    context.bytes,
                    pc,
                    instruction_pc,
                    context.instructions,
                    context.classes,
                    false,
                );
            }
            context.previous_pc = instruction_pc;
        }
    }
};

fn appendDecodedInstruction(
    self: *Analysis,
    allocator: std.mem.Allocator,
    bytes: []const u8,
    pc: usize,
    pc_end: usize,
    instructions: *std.ArrayList(InstructionMeta),
    classes: *std.ArrayList(u8),
    comptime mark_byte_maps: bool,
) !void {
    const opcode = bytes[pc];
    const push_len = pushDataLen(opcode);
    const instruction_index = try u32Index(instructions.items.len);

    if (mark_byte_maps) {
        self.metadata.markOpcodeStart(pc, opcode);
    }
    self.pc_to_instruction[pc] = instruction_index;

    const decoded = instruction.decode(opcode);
    const static_gas = if (decoded) |instr| instr.static_gas else 0;
    try instructions.append(allocator, .{
        .pc = pc,
        .pc_end = pc_end,
        .opcode = opcode,
        .push_len = push_len,
        .immediate_len = immediateLen(bytes.len, pc, push_len),
        .static_gas = static_gas,
    });
    try classes.append(allocator, opcodeClass(opcode));
}

fn u32Index(index: usize) !u32 {
    return std.math.cast(u32, index) orelse error.CodeTooLarge;
}

fn immediateLen(bytes_len: usize, pc: usize, push_len: u8) u8 {
    const start = pc + 1;
    if (start >= bytes_len) return 0;
    return @intCast(@min(@as(usize, push_len), bytes_len - start));
}

fn pushDataLen(opcode: u8) u8 {
    if (opcode >= push1_opcode and opcode <= push32_opcode) {
        return opcode - push0_opcode;
    }
    return 0;
}

fn opcodeClass(opcode: u8) u8 {
    if (opcode >= push0_opcode and opcode <= push32_opcode) {
        return class(.push);
    }

    return switch (opcode) {
        @intFromEnum(Opcode.POP) => class(.pop),
        @intFromEnum(Opcode.MLOAD) => class(.mload),
        @intFromEnum(Opcode.MSTORE) => class(.mstore),
        @intFromEnum(Opcode.MSTORE8) => class(.mstore8),
        @intFromEnum(Opcode.JUMP) => class(.jump),
        @intFromEnum(Opcode.JUMPI) => class(.jumpi),
        @intFromEnum(Opcode.ADD),
        @intFromEnum(Opcode.SUB),
        @intFromEnum(Opcode.AND),
        @intFromEnum(Opcode.OR),
        @intFromEnum(Opcode.XOR),
        @intFromEnum(Opcode.EQ),
        @intFromEnum(Opcode.LT),
        @intFromEnum(Opcode.GT),
        => class(.binary),
        else => class(.other),
    };
}

fn class(comptime opcode_class: OpcodeClass) u8 {
    return @intFromEnum(opcode_class);
}

fn patternCensusSimd(classes: []const u8) PatternCensus {
    const Vec = @Vector(simd_lanes, u8);

    const push_vec: Vec = @splat(class(.push));
    const pop_vec: Vec = @splat(class(.pop));
    const mload_vec: Vec = @splat(class(.mload));
    const mstore_vec: Vec = @splat(class(.mstore));
    const mstore8_vec: Vec = @splat(class(.mstore8));
    const jump_vec: Vec = @splat(class(.jump));
    const jumpi_vec: Vec = @splat(class(.jumpi));
    const binary_vec: Vec = @splat(class(.binary));

    var census = PatternCensus{};
    var index: usize = 0;
    while (index + simd_lanes + 2 <= classes.len) : (index += simd_lanes) {
        const first = loadClassVec(classes, index);
        const second = loadClassVec(classes, index + 1);
        const third = loadClassVec(classes, index + 2);

        const first_push = first == push_vec;
        census.push_pop += countMatches(first_push & (second == pop_vec));
        census.push_mload += countMatches(first_push & (second == mload_vec));
        census.push_jump += countMatches(first_push & (second == jump_vec));
        census.push_jumpi += countMatches(first_push & (second == jumpi_vec));

        const first_two_push = first_push & (second == push_vec);
        census.push_push_mstore += countMatches(first_two_push & (third == mstore_vec));
        census.push_push_mstore8 += countMatches(first_two_push & (third == mstore8_vec));
        census.push_push_binary += countMatches(first_two_push & (third == binary_vec));
    }

    while (index < classes.len) : (index += 1) {
        countScalarPattern(classes, index, &census);
    }
    return census;
}

fn loadClassVec(classes: []const u8, index: usize) @Vector(simd_lanes, u8) {
    const Vec = @Vector(simd_lanes, u8);
    const ptr: *align(1) const Vec = @ptrCast(classes.ptr + index);
    return ptr.*;
}

fn countMatches(matches: @Vector(simd_lanes, bool)) usize {
    var count: usize = 0;
    inline for (0..simd_lanes) |lane| {
        count += @intFromBool(matches[lane]);
    }
    return count;
}

fn countScalarPattern(classes: []const u8, index: usize, census: *PatternCensus) void {
    if (classes[index] != class(.push)) return;

    if (index + 1 < classes.len) {
        switch (classes[index + 1]) {
            class(.pop) => census.push_pop += 1,
            class(.mload) => census.push_mload += 1,
            class(.jump) => census.push_jump += 1,
            class(.jumpi) => census.push_jumpi += 1,
            else => {},
        }
    }

    if (index + 2 < classes.len and classes[index + 1] == class(.push)) {
        switch (classes[index + 2]) {
            class(.mstore) => census.push_push_mstore += 1,
            class(.mstore8) => census.push_push_mstore8 += 1,
            class(.binary) => census.push_push_binary += 1,
            else => {},
        }
    }
}

fn nextInstructionPc(bytes_len: usize, pc: usize, opcode: u8) usize {
    var next = pc + 1;
    if (opcode >= push1_opcode and opcode <= push32_opcode) {
        next += opcode - push0_opcode;
    }
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

test "code analysis records truncated PUSH metadata" {
    const bytecode = t.bytecode(.{ .PUSH2, 0x01 });
    var analysis = try Analysis.init(std.testing.allocator, &bytecode);
    defer analysis.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), analysis.instructions.len);
    try std.testing.expectEqual(@as(usize, 0), analysis.instructions[0].pc);
    try std.testing.expectEqual(@as(usize, 2), analysis.instructions[0].pc_end);
    try std.testing.expectEqual(@as(u8, 2), analysis.instructions[0].push_len);
    try std.testing.expectEqual(@as(u8, 1), analysis.instructions[0].immediate_len);
    try std.testing.expect(!analysis.isInstructionStart(1));
}

test "code analysis keeps unknown opcodes as instruction boundaries" {
    const bytecode = t.bytecode(.{ 0x0c, .JUMPDEST });
    var analysis = try Analysis.init(std.testing.allocator, &bytecode);
    defer analysis.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), analysis.instructions.len);
    try std.testing.expect(analysis.isInstructionStart(0));
    try std.testing.expect(analysis.isInstructionStart(1));
    try std.testing.expect(analysis.isValidJumpDest(&bytecode, 1));
}

test "code analysis SIMD pattern census counts decoded windows" {
    const bytecode = t.bytecode(.{
        .PUSH1, 0x00,
        .POP,   .PUSH1,
        0x40,   .MLOAD,
        .PUSH1, 0x01,
        .PUSH1, 0x02,
        .ADD,   .PUSH1,
        0xaa,   .PUSH1,
        0x00,   .MSTORE,
        .PUSH1, 0x05,
        .JUMP,  .PUSH1,
        0x06,   .JUMPI,
    });
    var analysis = try Analysis.init(std.testing.allocator, &bytecode);
    defer analysis.deinit(std.testing.allocator);

    const census = analysis.patternCensus();
    try std.testing.expectEqual(@as(usize, 1), census.push_pop);
    try std.testing.expectEqual(@as(usize, 1), census.push_mload);
    try std.testing.expectEqual(@as(usize, 1), census.push_push_binary);
    try std.testing.expectEqual(@as(usize, 1), census.push_push_mstore);
    try std.testing.expectEqual(@as(usize, 0), census.push_push_mstore8);
    try std.testing.expectEqual(@as(usize, 1), census.push_jump);
    try std.testing.expectEqual(@as(usize, 1), census.push_jumpi);
    try std.testing.expectEqual(@as(usize, 6), census.total());
}

test "code analysis SIMD pattern census ignores PUSH payload noise" {
    const bytecode = t.bytecode(.{ .PUSH2, .PUSH1, .MSTORE, .POP });
    var analysis = try Analysis.init(std.testing.allocator, &bytecode);
    defer analysis.deinit(std.testing.allocator);

    const census = analysis.patternCensus();
    try std.testing.expectEqual(@as(usize, 1), census.push_pop);
    try std.testing.expectEqual(@as(usize, 0), census.push_push_mstore);
    try std.testing.expectEqual(@as(usize, 1), census.total());
}

test "advanced code analysis SIMD boundary maps match scalar decode" {
    var bytecode = [_]u8{0} ** 48;
    bytecode[0] = Opcode.PUSH32.toInt();
    bytecode[1] = Opcode.JUMPDEST.toInt();
    bytecode[16] = Opcode.PUSH1.toInt();
    bytecode[31] = Opcode.JUMPDEST.toInt();
    bytecode[33] = Opcode.JUMPDEST.toInt();
    bytecode[34] = Opcode.PUSH1.toInt();
    bytecode[35] = Opcode.PUSH32.toInt();
    bytecode[36] = Opcode.JUMPDEST.toInt();

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
        try std.testing.expectEqual(lhs.pc_end, rhs.pc_end);
        try std.testing.expectEqual(lhs.opcode, rhs.opcode);
        try std.testing.expectEqual(lhs.push_len, rhs.push_len);
        try std.testing.expectEqual(lhs.immediate_len, rhs.immediate_len);
    }
}

test "code analysis SIMD pattern census handles vector chunks and tail" {
    var bytecode: [42]u8 = undefined;
    const push_pop = t.bytecode(.{ .PUSH0, .POP });
    for (0..21) |i| {
        bytecode[i * 2] = push_pop[0];
        bytecode[i * 2 + 1] = push_pop[1];
    }

    var analysis = try Analysis.init(std.testing.allocator, &bytecode);
    defer analysis.deinit(std.testing.allocator);

    const census = analysis.patternCensus();
    try std.testing.expectEqual(@as(usize, 21), census.push_pop);
    try std.testing.expectEqual(@as(usize, 21), census.total());
    try std.testing.expect(analysis.instructions[0].isPush());
}
