const std = @import("std");
const Metadata = @import("Metadata.zig");
const scanner = @import("scanner.zig");
const Config = @import("../Config.zig");
const Opcode = @import("../opcode.zig").Opcode;
const t = @import("../t.zig");

const JumpDestMap = @This();
pub const Strategy = Config.JumpDestStrategy;
const Word = usize;
const word_bytes = @sizeOf(Word);
const word_byte_ones = repeatByte(0x01);
const word_byte_high_bits = repeatByte(0x80);
const push_prefix_bits = repeatByte(0x60);
const push_prefix_mask = repeatByte(0xe0);

bits: Metadata.BitSet,
analyzed: bool,
strategy: Strategy,

pub const empty = JumpDestMap{
    .bits = .{},
    .analyzed = false,
    .strategy = .legacy,
};

pub fn init(strategy: Strategy) JumpDestMap {
    return .{
        .bits = .{},
        .analyzed = false,
        .strategy = strategy,
    };
}

pub fn deinit(self: *JumpDestMap, allocator: std.mem.Allocator) void {
    self.bits.deinit(allocator);
    self.* = empty;
}

pub fn isValid(self: *JumpDestMap, allocator: std.mem.Allocator, bytes: []const u8, target: usize) !bool {
    if (target >= bytes.len) return false;

    const opcode: Opcode = @enumFromInt(bytes[target]);
    if (opcode != .JUMPDEST) return false;

    try self.ensureValidBytes(allocator, bytes);
    return self.bits.isSet(target);
}

pub fn analyze(self: *JumpDestMap, allocator: std.mem.Allocator, bytes: []const u8) !void {
    try self.ensureValidBytes(allocator, bytes);
}

fn ensureValidBytes(self: *JumpDestMap, allocator: std.mem.Allocator, bytes: []const u8) !void {
    if (self.analyzed) return;

    if (bytes.len == 0) {
        self.analyzed = true;
        return;
    }

    self.bits = try Metadata.BitSet.initEmpty(allocator, bytes.len);

    switch (self.strategy) {
        .simd_bitmask => self.markValidJumpdestBytesSimdBitmask(bytes),
        .legacy => {
            if (shouldUseLinearValidByteScan(bytes)) {
                self.markValidJumpdestBytesLinear(bytes);
            } else {
                self.markValidJumpdestBytes(bytes);
            }
        },
    }

    self.analyzed = true;
}

fn markValidJumpdestBytesLinear(self: *JumpDestMap, bytes: []const u8) void {
    var pc: usize = 0;
    while (pc < bytes.len) {
        const opcode: Opcode = @enumFromInt(bytes[pc]);
        if (opcode == .JUMPDEST) {
            self.bits.set(pc);
        }

        pc = nextInstructionPc(bytes.len, pc, opcode);
    }
}

fn markValidJumpdestBytesSimdBitmask(self: *JumpDestMap, bytes: []const u8) void {
    scanner.markJumpDests(&self.bits, bytes);
}

fn markValidJumpdestBytes(self: *JumpDestMap, bytes: []const u8) void {
    var pc: usize = 0;
    while (std.mem.indexOfScalarPos(u8, bytes, pc, Opcode.JUMPDEST.toByte())) |jumpdest| {
        if (jumpdest == pc) {
            pc = self.markContiguousJumpdests(bytes, pc);
            continue;
        }

        while (pc < jumpdest) {
            const opcode: Opcode = @enumFromInt(bytes[pc]);
            if (hasPushPayload(opcode)) {
                pc = nextInstructionPc(bytes.len, pc, opcode);
                if (pc > jumpdest) break;
                continue;
            }

            pc = findNextPush(bytes, pc + 1, jumpdest) orelse break;
        }

        if (pc <= jumpdest) {
            self.bits.set(jumpdest);
            pc = jumpdest + 1;
        }
    }
}

fn shouldUseLinearValidByteScan(bytes: []const u8) bool {
    const sample_len = @min(bytes.len, 1024);
    var push_bytes: usize = 0;
    for (bytes[0..sample_len]) |byte| {
        const opcode: Opcode = @enumFromInt(byte);
        push_bytes += @intFromBool(hasPushPayload(opcode));
    }
    return push_bytes > sample_len / 32;
}

fn markContiguousJumpdests(self: *JumpDestMap, bytes: []const u8, start: usize) usize {
    var end = start + 1;
    while (end < bytes.len and bytes[end] == Opcode.JUMPDEST.toByte()) {
        end += 1;
    }
    self.bits.setRangeValue(.{ .start = start, .end = end }, true);
    return end;
}

fn findNextPush(bytes: []const u8, start: usize, end: usize) ?usize {
    var index = start;
    while (end - index >= word_bytes) {
        const word = std.mem.readInt(Word, bytes[index..][0..word_bytes], .little);
        if (wordMightContainPush(word)) {
            const chunk_end = index + word_bytes;
            while (index < chunk_end) : (index += 1) {
                const opcode: Opcode = @enumFromInt(bytes[index]);
                if (hasPushPayload(opcode)) return index;
            }
        } else {
            index += word_bytes;
        }
    }

    while (index < end) : (index += 1) {
        const opcode: Opcode = @enumFromInt(bytes[index]);
        if (hasPushPayload(opcode)) return index;
    }
    return null;
}

fn hasPushPayload(opcode: Opcode) bool {
    return opcode.isPushN();
}

fn wordMightContainPush(word: Word) bool {
    const high_bits = (word ^ push_prefix_bits) & push_prefix_mask;
    return hasZeroByte(high_bits);
}

fn hasZeroByte(word: Word) bool {
    return ((word -% word_byte_ones) & ~word & word_byte_high_bits) != 0;
}

fn repeatByte(comptime byte: u8) Word {
    return @as(Word, byte) * (~@as(Word, 0) / 0xff);
}

fn nextInstructionPc(bytes_len: usize, pc: usize, opcode: Opcode) usize {
    var next = pc + 1;
    if (hasPushPayload(opcode)) {
        next += opcode.toByte() - Opcode.PUSH0.toByte();
    }
    return @min(bytes_len, next);
}

test "jumpdest map skips PUSH data" {
    var map = JumpDestMap.empty;
    defer map.deinit(std.testing.allocator);

    const bytecode = t.bytecode(.{ .PUSH1, .JUMPDEST, .JUMPDEST });

    try std.testing.expect(!try map.isValid(std.testing.allocator, &bytecode, 1));
    try std.testing.expect(try map.isValid(std.testing.allocator, &bytecode, 2));
}

test "jumpdest map accepts destinations after push-looking data" {
    var map = JumpDestMap.empty;
    defer map.deinit(std.testing.allocator);

    const bytecode = t.bytecode(.{ .PUSH2, 0x00, .PUSH1, .JUMPDEST });

    try std.testing.expect(try map.isValid(std.testing.allocator, &bytecode, 3));
}

test "jumpdest map rejects non-destinations without analysis" {
    var map = JumpDestMap.empty;
    defer map.deinit(std.testing.allocator);

    const bytecode = t.bytecode(.{ .STOP, .JUMPDEST });

    try std.testing.expect(!try map.isValid(std.testing.allocator, &bytecode, 0));
    try std.testing.expect(!map.analyzed);
}

test "jumpdest map handles sparse long bytecode" {
    var map = JumpDestMap.empty;
    defer map.deinit(std.testing.allocator);

    var bytecode = [_]u8{0} ** 128;
    bytecode[0] = Opcode.PUSH2.toByte();
    bytecode[1] = 0;
    bytecode[2] = 127;
    bytecode[3] = Opcode.JUMP.toByte();
    bytecode[127] = Opcode.JUMPDEST.toByte();

    try std.testing.expect(try map.isValid(std.testing.allocator, &bytecode, 127));
}

test "jumpdest map finds push bytes with word scanner" {
    var bytecode = [_]u8{0} ** (word_bytes * 3 + 3);

    try std.testing.expectEqual(@as(?usize, null), findNextPush(&bytecode, 0, bytecode.len));

    const push_index = word_bytes + 2;
    bytecode[push_index] = Opcode.PUSH17.toByte();
    try std.testing.expectEqual(@as(?usize, push_index), findNextPush(&bytecode, 0, bytecode.len));
}

test "simd jumpdest map ignores fake push in PUSH payload" {
    const bytecode = t.bytecode(.{ .PUSH1, .PUSH32, .JUMPDEST });

    try expectSimdMatchesLinear(&bytecode);
}

test "simd jumpdest map carries PUSH payload across chunks" {
    var bytecode = [_]u8{0} ** 48;
    bytecode[0] = Opcode.PUSH32.toByte();
    bytecode[1] = Opcode.JUMPDEST.toByte();
    bytecode[16] = Opcode.PUSH1.toByte();
    bytecode[31] = Opcode.JUMPDEST.toByte();
    bytecode[33] = Opcode.JUMPDEST.toByte();
    bytecode[34] = Opcode.PUSH1.toByte();
    bytecode[35] = Opcode.JUMPDEST.toByte();
    bytecode[36] = Opcode.JUMPDEST.toByte();

    try expectSimdMatchesLinear(&bytecode);
}

fn expectSimdMatchesLinear(bytes: []const u8) !void {
    var linear = JumpDestMap{
        .bits = try Metadata.BitSet.initEmpty(std.testing.allocator, bytes.len),
        .analyzed = true,
        .strategy = .legacy,
    };
    defer linear.deinit(std.testing.allocator);

    var simd = JumpDestMap{
        .bits = try Metadata.BitSet.initEmpty(std.testing.allocator, bytes.len),
        .analyzed = true,
        .strategy = .simd_bitmask,
    };
    defer simd.deinit(std.testing.allocator);

    linear.markValidJumpdestBytesLinear(bytes);
    simd.markValidJumpdestBytesSimdBitmask(bytes);

    try std.testing.expect(linear.bits.eql(simd.bits));
}
