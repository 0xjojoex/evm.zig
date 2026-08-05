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
const empty_read_bytes: [zero_padding_len]u8 = @splat(0);

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

/// The semantic code. Always backed by `zero_padding_len` readable zero bytes
/// in the same allocation; see `readBytes`.
bytes: []const u8,
jumpdests: JumpDestMap,
needs_action_loop: bool,

/// The borrowed zero-length artifact, for callers that resolve code-less
/// accounts without preparing. Never pass this to `deinit`.
pub const empty = Bytecode{
    .bytes = empty_read_bytes[0..0],
    .jumpdests = .prepared_empty,
    .needs_action_loop = false,
};

pub fn init(allocator: std.mem.Allocator, bytes: []const u8) !Bytecode {
    const read_len = std.math.add(usize, bytes.len, zero_padding_len) catch return error.OutOfMemory;
    const read_bytes = try allocator.alloc(u8, read_len);
    @memcpy(read_bytes[0..bytes.len], bytes);
    @memset(read_bytes[bytes.len..], 0);

    var self = Bytecode{
        .bytes = read_bytes[0..bytes.len],
        .jumpdests = .empty,
        .needs_action_loop = false,
    };
    errdefer self.deinit(allocator);
    self.needs_action_loop = try self.jumpdests.analyzeAndClassifyActions(allocator, self.bytes);

    return self;
}

/// `bytes` extended by `zero_padding_len` zero bytes, letting opcode readers
/// over-read past the end of the code without a bounds check. This is exactly
/// the backing allocation, so `deinit` frees through it.
pub fn readBytes(self: *const Bytecode) []const u8 {
    return self.bytes.ptr[0 .. self.bytes.len + zero_padding_len];
}

pub fn view(self: *const Bytecode) View {
    return .{
        .bytes = self.bytes,
        .jumpdest_masks = self.jumpdests.bits.masks,
        .needs_action_loop = self.needs_action_loop,
    };
}

pub fn deinit(self: *Bytecode, allocator: std.mem.Allocator) void {
    allocator.free(self.readBytes());
    self.jumpdests.deinit(allocator);
    self.* = undefined;
}

pub fn isValidJumpDest(self: *const Bytecode, target: usize) bool {
    return self.jumpdests.isValidPrepared(self.bytes, target);
}

test "empty bytecode keeps a readable STOP tail" {
    try std.testing.expectEqual(@as(usize, 0), empty.bytes.len);
    try std.testing.expectEqual(zero_padding_len, empty.readBytes().len);
    try std.testing.expectEqual(@as(u8, @intFromEnum(Opcode.STOP)), empty.readBytes()[0]);
    try std.testing.expect(!empty.isValidJumpDest(0));
}

test "preparing zero-length code owns a padding-only allocation" {
    var bytecode = try Bytecode.init(std.testing.allocator, &.{});
    defer bytecode.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 0), bytecode.bytes.len);
    try std.testing.expectEqualSlices(u8, &empty_read_bytes, bytecode.readBytes());
    try std.testing.expect(bytecode.bytes.ptr != empty.bytes.ptr);
    try std.testing.expect(bytecode.jumpdests.analyzed);
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
    const action_code = t.bytecode(.{ .PUSH1, .CALL, .STATICCALL });
    var bytecode = try Bytecode.init(std.testing.allocator, &action_code);
    defer bytecode.deinit(std.testing.allocator);
    try std.testing.expect(bytecode.needs_action_loop);

    const push_only = t.bytecode(.{ .PUSH1, .CALL, .STOP });
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

test "bytecode owns a copy of the code behind a zero-padded tail" {
    const raw = t.bytecode(.{ .PUSH32, 0x01 });
    var bytecode = try Bytecode.init(std.testing.allocator, &raw);
    defer bytecode.deinit(std.testing.allocator);

    try std.testing.expectEqualSlices(u8, &raw, bytecode.bytes);
    try std.testing.expect(bytecode.bytes.ptr != raw[0..].ptr);
    try std.testing.expectEqualSlices(
        u8,
        &([_]u8{0} ** Bytecode.zero_padding_len),
        bytecode.readBytes()[raw.len..],
    );

    const borrowed = bytecode.view();
    try std.testing.expectEqual(raw.len, borrowed.bytes.len);
    try std.testing.expectEqual(bytecode.bytes.ptr, borrowed.bytes.ptr);
}
