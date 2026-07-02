const std = @import("std");
const Opcode = @import("../opcode.zig").Opcode;

const Metadata = @This();
pub const BitSet = std.DynamicBitSetUnmanaged;

opcode_start: BitSet,
jumpdest: BitSet,
push_opcode: BitSet,

pub const empty = Metadata{
    .opcode_start = .{},
    .jumpdest = .{},
    .push_opcode = .{},
};

pub fn init(allocator: std.mem.Allocator, byte_len: usize) !Metadata {
    var self = empty;
    errdefer self.deinit(allocator);

    self.opcode_start = try BitSet.initEmpty(allocator, byte_len);
    self.jumpdest = try BitSet.initEmpty(allocator, byte_len);
    self.push_opcode = try BitSet.initEmpty(allocator, byte_len);
    return self;
}

pub fn deinit(self: *Metadata, allocator: std.mem.Allocator) void {
    self.opcode_start.deinit(allocator);
    self.jumpdest.deinit(allocator);
    self.push_opcode.deinit(allocator);
    self.* = empty;
}

pub fn markOpcodeStart(self: *Metadata, pc: usize, opcode: Opcode) void {
    self.opcode_start.set(pc);
    if (opcode == .JUMPDEST) self.jumpdest.set(pc);
    self.markPushOpcode(pc, opcode);
}

pub fn markPushOpcode(self: *Metadata, pc: usize, opcode: Opcode) void {
    if (opcode.isPush()) self.push_opcode.set(pc);
}

test "metadata marks opcode starts and push/jumpdest bits" {
    var metadata = try Metadata.init(std.testing.allocator, 8);
    defer metadata.deinit(std.testing.allocator);

    metadata.markOpcodeStart(0, .PUSH0);
    metadata.markOpcodeStart(1, .JUMPDEST);
    metadata.markOpcodeStart(2, .SSTORE);

    try std.testing.expect(metadata.opcode_start.isSet(0));
    try std.testing.expect(metadata.push_opcode.isSet(0));
    try std.testing.expect(metadata.jumpdest.isSet(1));
    try std.testing.expect(metadata.opcode_start.isSet(2));
    try std.testing.expect(!metadata.push_opcode.isSet(2));
}
