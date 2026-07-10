const std = @import("std");
const ExecutionConfig = @import("../ExecutionConfig.zig");
const JumpDestMap = @import("JumpDestMap.zig");
const t = @import("../t.zig");

const Bytecode = @This();

pub const zero_padding_len = 33;

pub const ZeroPaddedCode = struct {
    bytes: []u8,
    read_bytes: []u8,

    pub fn init(allocator: std.mem.Allocator, source: []const u8) !ZeroPaddedCode {
        const read_len = std.math.add(usize, source.len, zero_padding_len) catch return error.OutOfMemory;
        const read_bytes = try allocator.alloc(u8, read_len);
        @memcpy(read_bytes[0..source.len], source);
        @memset(read_bytes[source.len..], 0);
        return .{
            .bytes = read_bytes[0..source.len],
            .read_bytes = read_bytes,
        };
    }

    pub fn deinit(self: *ZeroPaddedCode, allocator: std.mem.Allocator) void {
        allocator.free(self.read_bytes);
        self.* = .{ .bytes = &.{}, .read_bytes = &.{} };
    }
};

bytes: []u8,
read_bytes: []u8,
jumpdests: JumpDestMap,

pub const empty = Bytecode{
    .bytes = &.{},
    .read_bytes = &.{},
    .jumpdests = .empty,
};

pub fn init(allocator: std.mem.Allocator, bytes: []const u8) !Bytecode {
    return initWithConfig(allocator, bytes, .base);
}

pub fn initWithConfig(allocator: std.mem.Allocator, bytes: []const u8, config: ExecutionConfig) !Bytecode {
    var self = empty;
    errdefer self.deinit(allocator);

    const padded = try ZeroPaddedCode.init(allocator, bytes);
    self.bytes = padded.bytes;
    self.read_bytes = padded.read_bytes;
    self.jumpdests = JumpDestMap.initWithStrategy(config.jumpDestStrategy());
    if (config.buildsJumpDestMap()) {
        try self.jumpdests.analyze(allocator, self.bytes);
    }

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

test "bytecode can opt into SIMD jumpdest map" {
    const raw = t.bytecode(.{ .PUSH1, .JUMPDEST, .JUMPDEST });
    var bytecode = try Bytecode.initWithConfig(std.testing.allocator, &raw, .{ .jumpdest_strategy = .simd_bitmask });
    defer bytecode.deinit(std.testing.allocator);

    try std.testing.expectEqual(ExecutionConfig.JumpDestStrategy.simd_bitmask, bytecode.jumpdests.strategy);
    try std.testing.expect(bytecode.jumpdests.analyzed);
    try std.testing.expect(try bytecode.isValidJumpDest(std.testing.allocator, 2));
}

test "bytecode can defer jumpdest preprocessing" {
    const raw = t.bytecode(.{ .PUSH1, .JUMPDEST, .JUMPDEST });
    var bytecode = try Bytecode.initWithConfig(std.testing.allocator, &raw, .{ .preprocessing = .none });
    defer bytecode.deinit(std.testing.allocator);

    try std.testing.expectEqual(ExecutionConfig.JumpDestStrategy.legacy, bytecode.jumpdests.strategy);
    try std.testing.expect(!bytecode.jumpdests.analyzed);
    try std.testing.expect(try bytecode.isValidJumpDest(std.testing.allocator, 2));
    try std.testing.expect(bytecode.jumpdests.analyzed);
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

test "zero-padded code owns semantic bytes and readable tail" {
    const source = [_]u8{ 0x60, 0x01 };
    var padded = try ZeroPaddedCode.init(std.testing.allocator, &source);
    defer padded.deinit(std.testing.allocator);

    try std.testing.expectEqual(source.len, padded.bytes.len);
    try std.testing.expectEqual(source.len + zero_padding_len, padded.read_bytes.len);
    try std.testing.expectEqual(padded.bytes.ptr, padded.read_bytes.ptr);
    try std.testing.expectEqualSlices(u8, &source, padded.bytes);
    try std.testing.expect(std.mem.allEqual(u8, padded.read_bytes[source.len..], 0));
}
