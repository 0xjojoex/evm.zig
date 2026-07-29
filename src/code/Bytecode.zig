//! Immutable, execution-ready bytecode artifact.
//!
//! Construction owns and pads the source bytes, classifies the action loop,
//! and eagerly completes jumpdest analysis. Execution receives a borrowed
//! `View`; mutation is limited to owner-side construction/teardown.

const std = @import("std");
const JumpDestMap = @import("JumpDestMap.zig");
const Opcode = @import("../opcode.zig").Opcode;
const t = @import("../t.zig");

const Bytecode = @This();

pub const zero_padding_len = 33;
const empty_read_bytes = [_]u8{0} ** zero_padding_len;

/// Non-owning execution view. `bytes` is the semantic code and is backed by
/// `zero_padding_len` readable zero bytes. The prepared-code owner must keep
/// both code and jumpdest storage alive through every use.
pub const View = struct {
    bytes: []const u8,
    jumpdest_masks: [*]const usize,
    needs_action_loop: bool,

    pub const empty = View{
        .bytes = empty_read_bytes[0..0],
        .jumpdest_masks = JumpDestMap.prepared_empty.bits.masks,
        .needs_action_loop = false,
    };
};

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
    const padded = try ZeroPaddedCode.init(allocator, bytes);
    var self = Bytecode{
        .bytes = padded.bytes,
        .read_bytes = padded.read_bytes,
        .jumpdests = .empty,
        .needs_action_loop = false,
    };
    errdefer self.deinit(allocator);
    self.needs_action_loop = try self.jumpdests.analyzeAndClassifyActions(allocator, self.bytes);

    return self;
}

pub fn view(self: *const Bytecode) View {
    return .{
        .bytes = self.bytes,
        .jumpdest_masks = self.jumpdests.bits.masks,
        .needs_action_loop = self.needs_action_loop,
    };
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

test "bytecode eagerly completes jumpdest analysis" {
    const raw = t.bytecode(.{ .PUSH1, .JUMPDEST, .JUMPDEST });
    var bytecode = try Bytecode.init(std.testing.allocator, &raw);
    defer bytecode.deinit(std.testing.allocator);

    try std.testing.expect(bytecode.jumpdests.analyzed);
    try std.testing.expect(bytecode.isValidJumpDest(2));
    try std.testing.expect(!bytecode.isValidJumpDest(1));
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
    const borrowed = bytecode.view();
    try std.testing.expectEqual(raw.len, borrowed.bytes.len);
    try std.testing.expectEqual(bytecode.bytes.ptr, borrowed.bytes.ptr);
}
