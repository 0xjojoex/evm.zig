const std = @import("std");
const Metadata = @import("Metadata.zig");
const scanner = @import("scanner.zig");
const Opcode = @import("../opcode.zig").Opcode;
const t = @import("../t.zig");

const JumpDestMap = @This();

bits: Metadata.BitSet,
analyzed: bool,

pub const empty = JumpDestMap{
    .bits = .{},
    .analyzed = false,
};

pub fn init() JumpDestMap {
    return empty;
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

    self.markValidJumpdestBytesSimdBitmask(bytes);
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

fn hasPushPayload(opcode: Opcode) bool {
    return opcode.isPushN();
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

test "simd jumpdest map ignores fake push in PUSH payload" {
    const bytecode = t.bytecode(.{ .PUSH1, .PUSH32, .JUMPDEST });

    try expectSimdMatchesLinear(&bytecode);
}

test "jumpdest map leaves EIP-8024 immediate bytes as instruction boundaries" {
    {
        const bytecode = t.bytecode(.{ .DUPN, .JUMPDEST });
        var map = JumpDestMap.init();
        defer map.deinit(std.testing.allocator);

        try std.testing.expect(try map.isValid(std.testing.allocator, &bytecode, 1));
        try expectSimdMatchesLinear(&bytecode);
    }

    {
        const bytecode = t.bytecode(.{ .DUPN, .PUSH1, .JUMPDEST });
        var map = JumpDestMap.init();
        defer map.deinit(std.testing.allocator);

        try std.testing.expect(!try map.isValid(std.testing.allocator, &bytecode, 2));
        try expectSimdMatchesLinear(&bytecode);
    }
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
    };
    defer linear.deinit(std.testing.allocator);

    var simd = JumpDestMap{
        .bits = try Metadata.BitSet.initEmpty(std.testing.allocator, bytes.len),
        .analyzed = true,
    };
    defer simd.deinit(std.testing.allocator);

    linear.markValidJumpdestBytesLinear(bytes);
    simd.markValidJumpdestBytesSimdBitmask(bytes);

    try std.testing.expect(linear.bits.eql(simd.bits));
}
