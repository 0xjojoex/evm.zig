const std = @import("std");
const Opcode = @import("../opcode.zig").Opcode;

const Metadata = @This();
pub const BitSet = std.DynamicBitSetUnmanaged;

const jumpdest_opcode = @intFromEnum(Opcode.JUMPDEST);
const push0_opcode = @intFromEnum(Opcode.PUSH0);
const push32_opcode = @intFromEnum(Opcode.PUSH32);

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

pub fn markOpcodeStart(self: *Metadata, pc: usize, opcode: u8) void {
    self.opcode_start.set(pc);
    if (opcode == jumpdest_opcode) self.jumpdest.set(pc);
    self.markOpcodeClass(pc, opcode);
}

pub fn markOpcodeClass(self: *Metadata, pc: usize, opcode: u8) void {
    if (opcode >= push0_opcode and opcode <= push32_opcode) self.push_opcode.set(pc);
}

test "metadata marks opcode starts and push/jumpdest bits" {
    var metadata = try Metadata.init(std.testing.allocator, 8);
    defer metadata.deinit(std.testing.allocator);

    metadata.markOpcodeStart(0, Opcode.PUSH0.toInt());
    metadata.markOpcodeStart(1, Opcode.JUMPDEST.toInt());
    metadata.markOpcodeStart(2, Opcode.SSTORE.toInt());

    try std.testing.expect(metadata.opcode_start.isSet(0));
    try std.testing.expect(metadata.push_opcode.isSet(0));
    try std.testing.expect(metadata.jumpdest.isSet(1));
    try std.testing.expect(metadata.opcode_start.isSet(2));
    try std.testing.expect(!metadata.push_opcode.isSet(2));
}
