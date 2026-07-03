const std = @import("std");
const Analysis = @import("Analysis.zig");
const Config = @import("../Config.zig");
const JumpDestMap = @import("JumpDestMap.zig");
const t = @import("../t.zig");

const Bytecode = @This();

pub const zero_padding_len = 33;

bytes: []u8,
read_bytes: []u8,
jumpdests: JumpDestMap,
analysis: Analysis,
preprocessing: Config.Preprocessing,

pub const empty = Bytecode{
    .bytes = &.{},
    .read_bytes = &.{},
    .jumpdests = .empty,
    .analysis = .empty,
    .preprocessing = .none,
};

pub fn init(allocator: std.mem.Allocator, bytes: []const u8, preprocessing: Config.Preprocessing) !Bytecode {
    var self = empty;
    errdefer self.deinit(allocator);

    self.read_bytes = try allocator.alloc(u8, bytes.len + zero_padding_len);
    @memcpy(self.read_bytes[0..bytes.len], bytes);
    @memset(self.read_bytes[bytes.len..], 0);
    self.bytes = self.read_bytes[0..bytes.len];
    self.preprocessing = preprocessing;

    const config = Config{ .preprocessing = preprocessing };
    self.jumpdests = JumpDestMap.init(config.jumpDestStrategy());

    switch (preprocessing) {
        .none => {},
        .jumpdest => try self.jumpdests.analyze(allocator, self.bytes),
        .full => self.analysis = try Analysis.initWithConfig(allocator, self.bytes, config),
    }

    return self;
}

pub fn deinit(self: *Bytecode, allocator: std.mem.Allocator) void {
    allocator.free(self.read_bytes);
    self.jumpdests.deinit(allocator);
    self.analysis.deinit(allocator);
    self.* = empty;
}

pub fn isValidJumpDest(self: *Bytecode, allocator: std.mem.Allocator, target: usize) !bool {
    if (self.analysis.analyzed) {
        return self.analysis.isValidJumpDest(self.bytes, target);
    }
    return try self.jumpdests.isValid(allocator, self.bytes, target);
}

pub fn ensureAnalyzed(self: *Bytecode, allocator: std.mem.Allocator) !*const Analysis {
    if (!self.analysis.analyzed) {
        self.analysis = try Analysis.initWithConfig(allocator, self.bytes, .advanced);
    }
    return &self.analysis;
}

pub fn isAnalyzed(self: *const Bytecode) bool {
    return self.analysis.analyzed;
}

test "bytecode can precompute jumpdest map" {
    const raw = t.bytecode(.{ .PUSH1, .JUMPDEST, .JUMPDEST });
    var bytecode = try Bytecode.init(std.testing.allocator, &raw, .jumpdest);
    defer bytecode.deinit(std.testing.allocator);

    try std.testing.expect(bytecode.jumpdests.analyzed);
    try std.testing.expect(!bytecode.isAnalyzed());
    try std.testing.expect(!try bytecode.isValidJumpDest(std.testing.allocator, 1));
    try std.testing.expect(try bytecode.isValidJumpDest(std.testing.allocator, 2));
}

test "bytecode keeps semantic bytes separate from padded read bytes" {
    const raw = t.bytecode(.{ .PUSH32, 0x01 });
    var bytecode = try Bytecode.init(std.testing.allocator, &raw, .none);
    defer bytecode.deinit(std.testing.allocator);

    try std.testing.expectEqual(raw.len, bytecode.bytes.len);
    try std.testing.expectEqual(raw.len + Bytecode.zero_padding_len, bytecode.read_bytes.len);
    try std.testing.expectEqualSlices(u8, &raw, bytecode.bytes);
    try std.testing.expectEqualSlices(u8, &([_]u8{0} ** Bytecode.zero_padding_len), bytecode.read_bytes[raw.len..]);
}

test "bytecode full preprocessing builds analysis" {
    const raw = t.bytecode(.{ .PUSH1, 0x03, .JUMP, .JUMPDEST, .STOP });
    var bytecode = try Bytecode.init(std.testing.allocator, &raw, .full);
    defer bytecode.deinit(std.testing.allocator);

    try std.testing.expect(bytecode.isAnalyzed());
    try std.testing.expectEqual(@as(usize, 4), bytecode.analysis.instructions.len);
    try std.testing.expect(try bytecode.isValidJumpDest(std.testing.allocator, 3));
}
