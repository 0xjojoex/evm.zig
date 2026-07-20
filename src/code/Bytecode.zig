//! Immutable, execution-ready bytecode artifact.
//!
//! Construction owns and pads the source bytes, classifies the action loop,
//! and eagerly completes jumpdest analysis. Execution receives only
//! `*const Bytecode`; mutation is limited to owner-side construction/teardown.

const std = @import("std");
const ExecutionConfig = @import("../ExecutionConfig.zig");
const JumpDestMap = @import("JumpDestMap.zig");
const Opcode = @import("../opcode.zig").Opcode;
const t = @import("../t.zig");

const Bytecode = @This();

pub const zero_padding_len = 33;
const empty_read_bytes = [_]u8{0} ** zero_padding_len;

/// Owned source bytes followed by a zero-filled readable tail.
///
/// `bytes` is the semantic code; `read_bytes` is the same allocation extended
/// by `zero_padding_len` zero bytes so opcode readers can over-read past the
/// end of the code without a bounds check.
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

bytes: []const u8,
/// `bytes` extended by `zero_padding_len` zero bytes, letting opcode readers
/// over-read past the end of the code without a bounds check.
read_bytes: []const u8,
jumpdests: JumpDestMap,
needs_action_loop: bool,

pub const empty = Bytecode{
    .bytes = &.{},
    .read_bytes = &empty_read_bytes,
    .jumpdests = .prepared_empty,
    .needs_action_loop = false,
};

pub fn init(allocator: std.mem.Allocator, bytes: []const u8) !Bytecode {
    return prepare(allocator, bytes, .base);
}

pub fn initWithConfig(allocator: std.mem.Allocator, bytes: []const u8, config: ExecutionConfig) !Bytecode {
    return prepare(allocator, bytes, config);
}

pub fn prepare(allocator: std.mem.Allocator, bytes: []const u8, config: ExecutionConfig) !Bytecode {
    const padded = try ZeroPaddedCode.init(allocator, bytes);
    var self = Bytecode{
        .bytes = padded.bytes,
        .read_bytes = padded.read_bytes,
        .jumpdests = JumpDestMap.initWithStrategy(config.jumpDestStrategy()),
        .needs_action_loop = needsActionLoop(padded.bytes),
    };
    errdefer self.deinit(allocator);
    try self.jumpdests.analyze(allocator, self.bytes);

    return self;
}

pub fn needsActionLoop(code: []const u8) bool {
    var pc: usize = 0;
    while (pc < code.len) {
        const opcode_byte = code[pc];
        pc += 1;
        if (isActionBoundaryOpcode(opcode_byte)) return true;
        pc += @min(pushDataLen(opcode_byte), code.len - pc);
    }
    return false;
}

inline fn isActionBoundaryOpcode(opcode_byte: u8) bool {
    const system_offset = opcode_byte -% @intFromEnum(Opcode.CREATE);
    return (system_offset <= @intFromEnum(Opcode.CREATE2) - @intFromEnum(Opcode.CREATE) and opcode_byte != @intFromEnum(Opcode.RETURN)) or
        opcode_byte == @intFromEnum(Opcode.STATICCALL);
}

inline fn pushDataLen(opcode_byte: u8) usize {
    if (opcode_byte < @intFromEnum(Opcode.PUSH1) or opcode_byte > @intFromEnum(Opcode.PUSH32)) return 0;
    return @as(usize, opcode_byte - @intFromEnum(Opcode.PUSH1)) + 1;
}

pub fn deinit(self: *Bytecode, allocator: std.mem.Allocator) void {
    allocator.free(self.read_bytes);
    self.jumpdests.deinit(allocator);
    self.* = empty;
}

pub fn isValidJumpDest(self: *const Bytecode, target: usize) bool {
    return self.jumpdests.isValidPrepared(self.bytes, target);
}

test "empty bytecode keeps a readable STOP tail" {
    try std.testing.expectEqual(@as(usize, 0), empty.bytes.len);
    try std.testing.expect(empty.read_bytes.len >= zero_padding_len);
    try std.testing.expectEqual(@as(u8, @intFromEnum(Opcode.STOP)), empty.read_bytes[0]);
    try std.testing.expect(!empty.isValidJumpDest(0));
}

test "bytecode can precompute jumpdest map" {
    const raw = t.bytecode(.{ .PUSH1, .JUMPDEST, .JUMPDEST });
    var bytecode = try Bytecode.init(std.testing.allocator, &raw);
    defer bytecode.deinit(std.testing.allocator);

    try std.testing.expect(bytecode.jumpdests.analyzed);
    try std.testing.expect(!bytecode.isValidJumpDest(1));
    try std.testing.expect(bytecode.isValidJumpDest(2));
}

test "bytecode caches action-loop classification while ignoring push data" {
    const action_code = [_]u8{ @intFromEnum(Opcode.PUSH1), @intFromEnum(Opcode.CALL), @intFromEnum(Opcode.STATICCALL) };
    var bytecode = try Bytecode.init(std.testing.allocator, &action_code);
    defer bytecode.deinit(std.testing.allocator);
    try std.testing.expect(bytecode.needs_action_loop);

    const push_only = [_]u8{ @intFromEnum(Opcode.PUSH1), @intFromEnum(Opcode.CALL), @intFromEnum(Opcode.STOP) };
    var data_bytecode = try Bytecode.init(std.testing.allocator, &push_only);
    defer data_bytecode.deinit(std.testing.allocator);
    try std.testing.expect(!data_bytecode.needs_action_loop);
}

test "bytecode can opt into SIMD jumpdest map" {
    const raw = t.bytecode(.{ .PUSH1, .JUMPDEST, .JUMPDEST });
    var bytecode = try Bytecode.initWithConfig(std.testing.allocator, &raw, .{ .jumpdest_strategy = .simd_bitmask });
    defer bytecode.deinit(std.testing.allocator);

    try std.testing.expectEqual(ExecutionConfig.JumpDestStrategy.simd_bitmask, bytecode.jumpdests.strategy);
    try std.testing.expect(bytecode.jumpdests.analyzed);
    try std.testing.expect(bytecode.isValidJumpDest(2));
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
