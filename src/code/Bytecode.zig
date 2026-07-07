const std = @import("std");
const JumpDestMap = @import("JumpDestMap.zig");
const t = @import("../t.zig");

const Bytecode = @This();

pub const zero_padding_len = 33;

bytes: []u8,
read_bytes: []u8,
jumpdests: JumpDestMap,

pub const empty = Bytecode{
    .bytes = &.{},
    .read_bytes = &.{},
    .jumpdests = .empty,
};

pub fn init(allocator: std.mem.Allocator, bytes: []const u8) !Bytecode {
    var self = empty;
    errdefer self.deinit(allocator);

    self.read_bytes = try allocator.alloc(u8, bytes.len + zero_padding_len);
    @memcpy(self.read_bytes[0..bytes.len], bytes);
    @memset(self.read_bytes[bytes.len..], 0);
    self.bytes = self.read_bytes[0..bytes.len];
    self.jumpdests = JumpDestMap.init();
    try self.jumpdests.analyze(allocator, self.bytes);

    return self;
}

pub fn deinit(self: *Bytecode, allocator: std.mem.Allocator) void {
    allocator.free(self.read_bytes);
    self.jumpdests.deinit(allocator);
    self.* = empty;
}

pub fn isValidJumpDest(self: *Bytecode, allocator: std.mem.Allocator, target: usize) !bool {
    return try self.jumpdests.isValid(allocator, self.bytes, target);
}

test "bytecode can precompute jumpdest map" {
    const raw = t.bytecode(.{ .PUSH1, .JUMPDEST, .JUMPDEST });
    var bytecode = try Bytecode.init(std.testing.allocator, &raw);
    defer bytecode.deinit(std.testing.allocator);

    try std.testing.expect(bytecode.jumpdests.analyzed);
    try std.testing.expect(!try bytecode.isValidJumpDest(std.testing.allocator, 1));
    try std.testing.expect(try bytecode.isValidJumpDest(std.testing.allocator, 2));
}

test "bytecode keeps semantic bytes separate from padded read bytes" {
    const raw = t.bytecode(.{ .PUSH32, 0x01 });
    var bytecode = try Bytecode.init(std.testing.allocator, &raw);
    defer bytecode.deinit(std.testing.allocator);

    try std.testing.expectEqual(raw.len, bytecode.bytes.len);
    try std.testing.expectEqual(raw.len + Bytecode.zero_padding_len, bytecode.read_bytes.len);
    try std.testing.expectEqualSlices(u8, &raw, bytecode.bytes);
    try std.testing.expectEqualSlices(u8, &([_]u8{0} ** Bytecode.zero_padding_len), bytecode.read_bytes[raw.len..]);
    try std.testing.expect(bytecode.bytes.ptr != raw[0..].ptr);
    try std.testing.expectEqual(bytecode.bytes.ptr, bytecode.read_bytes.ptr);
}
