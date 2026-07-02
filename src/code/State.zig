const std = @import("std");
const Analysis = @import("Analysis.zig");
const Config = @import("../Config.zig");
const JumpDestMap = @import("JumpDestMap.zig");
const Opcode = @import("../opcode.zig").Opcode;
const t = @import("../t.zig");

const State = @This();

jumpdests: JumpDestMap,
analysis: Analysis,
config: Config,

pub const empty = State{
    .jumpdests = .empty,
    .analysis = .empty,
    .config = .base,
};

pub fn init(bytes: []const u8, config: Config) !State {
    _ = bytes;
    const strategy = config.jumpDestStrategy();
    return .{
        .jumpdests = JumpDestMap.init(strategy),
        .analysis = .empty,
        .config = config,
    };
}

pub fn deinit(self: *State, allocator: std.mem.Allocator) void {
    self.jumpdests.deinit(allocator);
    self.analysis.deinit(allocator);
    self.* = empty;
}

pub fn isValidJumpDest(self: *State, allocator: std.mem.Allocator, bytes: []const u8, target: usize) !bool {
    if (self.analysis.analyzed) {
        return self.analysis.isValidJumpDest(bytes, target);
    }
    return try self.jumpdests.isValid(allocator, bytes, target);
}

pub fn ensureAnalyzed(self: *State, allocator: std.mem.Allocator, bytes: []const u8) !*const Analysis {
    if (!self.analysis.analyzed) {
        self.analysis = try Analysis.initWithConfig(allocator, bytes, self.config);
    }
    return &self.analysis;
}

pub fn isAnalyzed(self: *const State) bool {
    return self.analysis.analyzed;
}

test "code analysis state keeps jumpdest validation lazy" {
    const bytecode = t.bytecode(.{ .STOP, .JUMPDEST });
    var state = try State.init(&bytecode, .base);
    defer state.deinit(std.testing.allocator);

    try std.testing.expect(!try state.isValidJumpDest(std.testing.allocator, &bytecode, 0));
    try std.testing.expect(!state.isAnalyzed());
}

test "base state keeps full analysis lazy" {
    const bytecode = t.bytecode(.{ .STOP, .JUMPDEST });
    var state = try State.init(&bytecode, .base);
    defer state.deinit(std.testing.allocator);

    try std.testing.expectEqual(Config.JumpDestStrategy.simd_bitmask, state.jumpdests.strategy);
    try std.testing.expect(try state.isValidJumpDest(std.testing.allocator, &bytecode, 1));
    try std.testing.expect(!state.isAnalyzed());
}

test "code analysis state can force full analysis" {
    const bytecode = t.bytecode(.{ .PUSH1, 0x00, .STOP });
    var state = try State.init(&bytecode, .base);
    defer state.deinit(std.testing.allocator);

    const analysis = try state.ensureAnalyzed(std.testing.allocator, &bytecode);
    try std.testing.expect(state.isAnalyzed());
    try std.testing.expectEqual(@as(usize, 2), analysis.instructions.len);
    try std.testing.expect(analysis.isInstructionStart(0));
    try std.testing.expect(!analysis.isInstructionStart(1));
    try std.testing.expect(analysis.isInstructionStart(2));
}

test "full preprocessing state keeps execution lazy but can force instruction metadata" {
    const bytecode = t.bytecode(.{ .PUSH0, .POP, .STOP });
    var state = try State.init(&bytecode, .advanced);
    defer state.deinit(std.testing.allocator);

    try std.testing.expect(!state.isAnalyzed());

    const analysis = try state.ensureAnalyzed(std.testing.allocator, &bytecode);
    try std.testing.expect(state.isAnalyzed());
    try std.testing.expectEqual(@as(usize, 3), analysis.instructions.len);
}

test "full preprocessing state remains local per call frame" {
    var bytecode = [_]u8{Opcode.JUMPDEST.toByte()} ** 64;
    bytecode[0] = Opcode.PUSH0.toByte();
    bytecode[1] = Opcode.POP.toByte();
    bytecode[2] = Opcode.STOP.toByte();

    var first = try State.init(&bytecode, .advanced);
    defer first.deinit(std.testing.allocator);
    const first_analysis = try first.ensureAnalyzed(std.testing.allocator, &bytecode);

    var second = try State.init(&bytecode, .advanced);
    defer second.deinit(std.testing.allocator);

    try std.testing.expect(first.isAnalyzed());
    try std.testing.expect(!second.isAnalyzed());
    try std.testing.expect(try second.isValidJumpDest(std.testing.allocator, &bytecode, 3));
    try std.testing.expect(!second.isAnalyzed());
    try std.testing.expect(first_analysis.isInstructionStart(0));
}
