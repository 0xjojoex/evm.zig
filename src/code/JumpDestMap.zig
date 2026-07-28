const std = @import("std");
const scanner = @import("scanner.zig");
const Opcode = @import("../opcode.zig").Opcode;
const t = @import("../t.zig");

const JumpDestMap = @This();

bits: std.DynamicBitSetUnmanaged,
analyzed: bool,

pub const empty = JumpDestMap{
    .bits = .{},
    .analyzed = false,
};

pub const prepared_empty = JumpDestMap{
    .bits = .{},
    .analyzed = true,
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

/// Query an eagerly analyzed map without mutation or allocation.
pub fn isValidPrepared(self: *const JumpDestMap, bytes: []const u8, target: usize) bool {
    std.debug.assert(self.analyzed);
    if (target >= bytes.len) return false;
    if (bytes[target] != @intFromEnum(Opcode.JUMPDEST)) return false;
    return self.bits.isSet(target);
}

pub fn analyze(self: *JumpDestMap, allocator: std.mem.Allocator, bytes: []const u8) !void {
    try self.ensureValidBytes(allocator, bytes);
}

/// Analyze and report whether `bytes` contains an action-boundary opcode, both
/// from the single scan. Only valid on a not-yet-analyzed map.
pub fn analyzeAndClassifyActions(self: *JumpDestMap, allocator: std.mem.Allocator, bytes: []const u8) !bool {
    std.debug.assert(!self.analyzed);

    if (bytes.len == 0) {
        self.analyzed = true;
        return false;
    }

    self.bits = try std.DynamicBitSetUnmanaged.initEmpty(allocator, bytes.len);
    const needs_action_loop = scanner.markJumpDestsAndClassifyActions(&self.bits, bytes);
    self.analyzed = true;
    return needs_action_loop;
}

fn ensureValidBytes(self: *JumpDestMap, allocator: std.mem.Allocator, bytes: []const u8) !void {
    if (self.analyzed) return;

    if (bytes.len == 0) {
        self.analyzed = true;
        return;
    }

    self.bits = try std.DynamicBitSetUnmanaged.initEmpty(allocator, bytes.len);
    scanner.markJumpDests(&self.bits, bytes);
    self.analyzed = true;
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

test "jumpdest map ignores fake push in PUSH payload" {
    const bytecode = t.bytecode(.{ .PUSH1, .PUSH32, .JUMPDEST });

    try expectMatchesLinear(&bytecode);
}

test "jumpdest map leaves EIP-8024 immediate bytes as instruction boundaries" {
    {
        const bytecode = t.bytecode(.{ .DUPN, .JUMPDEST });
        var map = JumpDestMap.init();
        defer map.deinit(std.testing.allocator);

        try std.testing.expect(try map.isValid(std.testing.allocator, &bytecode, 1));
        try expectMatchesLinear(&bytecode);
    }

    {
        const bytecode = t.bytecode(.{ .DUPN, .PUSH1, .JUMPDEST });
        var map = JumpDestMap.init();
        defer map.deinit(std.testing.allocator);

        try std.testing.expect(!try map.isValid(std.testing.allocator, &bytecode, 2));
        try expectMatchesLinear(&bytecode);
    }
}

test "jumpdest map carries PUSH payload across chunks" {
    var bytecode = [_]u8{0} ** 48;
    bytecode[0] = Opcode.PUSH32.toByte();
    bytecode[1] = Opcode.JUMPDEST.toByte();
    bytecode[16] = Opcode.PUSH1.toByte();
    bytecode[31] = Opcode.JUMPDEST.toByte();
    bytecode[33] = Opcode.JUMPDEST.toByte();
    bytecode[34] = Opcode.PUSH1.toByte();
    bytecode[35] = Opcode.JUMPDEST.toByte();
    bytecode[36] = Opcode.JUMPDEST.toByte();

    try expectMatchesLinear(&bytecode);
}

/// Obviously-correct reference scan: walk instruction by instruction, stepping
/// over PUSH immediates. The bitmask scanner must agree with it exactly.
fn markLinear(bits: *std.DynamicBitSetUnmanaged, bytes: []const u8) void {
    var pc: usize = 0;
    while (pc < bytes.len) {
        const opcode: Opcode = @enumFromInt(bytes[pc]);
        if (opcode == .JUMPDEST) bits.set(pc);

        var next = pc + 1;
        if (opcode.isPushN()) next += opcode.toByte() - Opcode.PUSH0.toByte();
        pc = @min(bytes.len, next);
    }
}

fn expectMatchesLinear(bytes: []const u8) !void {
    var linear = try std.DynamicBitSetUnmanaged.initEmpty(std.testing.allocator, bytes.len);
    defer linear.deinit(std.testing.allocator);
    markLinear(&linear, bytes);

    var scanned = JumpDestMap.empty;
    defer scanned.deinit(std.testing.allocator);
    try scanned.analyze(std.testing.allocator, bytes);

    try std.testing.expect(linear.eql(scanned.bits));
}
