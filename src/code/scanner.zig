const std = @import("std");
const Metadata = @import("Metadata.zig");
const Opcode = @import("../opcode.zig").Opcode;
const t = @import("../t.zig");

pub const lanes = 16;

pub const RawMasks = struct {
    push: u64,
    jumpdest: u64,
};

pub const BoundaryMasks = struct {
    boundary: u64,
    jumpdest: u64,
};

pub fn scan(
    comptime Context: type,
    context: Context,
    bytes: []const u8,
    comptime consume: fn (Context, usize, BoundaryMasks) void,
) void {
    var index: usize = 0;
    var carry_payload: usize = 0;

    while (bytes.len - index >= lanes) : (index += lanes) {
        const chunk = bytes[index..][0..lanes];
        const masks = rawSimdMasks(chunk);
        consume(context, index, resolveBoundaryMasks(chunk, masks.push, masks.jumpdest, &carry_payload));
    }

    if (index < bytes.len) {
        const tail = bytes[index..];
        const masks = rawScalarMasks(tail);
        consume(context, index, resolveBoundaryMasks(tail, masks.push, masks.jumpdest, &carry_payload));
    }
}

pub fn scanFallible(
    comptime Context: type,
    context: Context,
    bytes: []const u8,
    comptime consume: fn (Context, usize, BoundaryMasks) anyerror!void,
) !void {
    var index: usize = 0;
    var carry_payload: usize = 0;

    while (bytes.len - index >= lanes) : (index += lanes) {
        const chunk = bytes[index..][0..lanes];
        const masks = rawSimdMasks(chunk);
        try consume(context, index, resolveBoundaryMasks(chunk, masks.push, masks.jumpdest, &carry_payload));
    }

    if (index < bytes.len) {
        const tail = bytes[index..];
        const masks = rawScalarMasks(tail);
        try consume(context, index, resolveBoundaryMasks(tail, masks.push, masks.jumpdest, &carry_payload));
    }
}

pub fn markJumpDests(map: *Metadata.BitSet, bytes: []const u8) void {
    scan(*Metadata.BitSet, map, bytes, scatterJumpDests);
}

fn scatterJumpDests(map: *Metadata.BitSet, base: usize, masks: BoundaryMasks) void {
    orMask(map, base, masks.jumpdest);
}

pub fn orMask(bitset: *Metadata.BitSet, base: usize, mask: u64) void {
    if (mask == 0) return;

    const MaskInt = Metadata.BitSet.MaskInt;
    const word_bits = @bitSizeOf(MaskInt);
    const first_word = base / word_bits;
    const offset: Metadata.BitSet.ShiftInt = @truncate(base);

    bitset.masks[first_word] |= @as(MaskInt, @intCast(mask)) << offset;
    if (offset != 0 and first_word + 1 < numMasks(bitset.bit_length)) {
        const right_shift: Metadata.BitSet.ShiftInt = @intCast(word_bits - @as(usize, offset));
        bitset.masks[first_word + 1] |= @as(MaskInt, @intCast(mask >> right_shift));
    }
}

fn numMasks(bit_length: usize) usize {
    const MaskInt = Metadata.BitSet.MaskInt;
    return (bit_length + (@bitSizeOf(MaskInt) - 1)) / @bitSizeOf(MaskInt);
}

pub fn rawSimdMasks(bytes: *const [lanes]u8) RawMasks {
    const Vec = @Vector(lanes, u8);
    const chunk: Vec = bytes.*;
    const push_matches = (chunk & @as(Vec, @splat(0xe0))) == @as(Vec, @splat(0x60));
    const jumpdest_matches = chunk == @as(Vec, @splat(Opcode.JUMPDEST.toByte()));

    return .{
        .push = boolVectorMask(push_matches),
        .jumpdest = boolVectorMask(jumpdest_matches),
    };
}

fn boolVectorMask(matches: @Vector(lanes, bool)) u64 {
    const Bits = @Vector(lanes, u1);
    const MaskInt = std.meta.Int(.unsigned, lanes);
    const bits: Bits = @select(u1, matches, @as(Bits, @splat(1)), @as(Bits, @splat(0)));
    return @as(u64, @as(MaskInt, @bitCast(bits)));
}

pub fn rawScalarMasks(bytes: []const u8) RawMasks {
    var push: u64 = 0;
    var jumpdest: u64 = 0;
    for (bytes, 0..) |byte, index| {
        const opcode: Opcode = @enumFromInt(byte);
        push |= @as(u64, @intFromBool(opcode.isPushN())) << @intCast(index);
        jumpdest |= @as(u64, @intFromBool(opcode == .JUMPDEST)) << @intCast(index);
    }
    return .{ .push = push, .jumpdest = jumpdest };
}

fn resolveBoundaryMasks(bytes: []const u8, raw_push_mask: u64, raw_jumpdest_mask: u64, carry_payload: *usize) BoundaryMasks {
    const len = bytes.len;
    const valid_lanes = lowMask(len);

    if (carry_payload.* >= len) {
        carry_payload.* -= len;
        return .{ .boundary = 0, .jumpdest = 0 };
    }

    var payload_mask = lowMask(carry_payload.*);
    carry_payload.* = 0;

    var push_mask = raw_push_mask & valid_lanes;
    while (push_mask != 0) {
        const bit: usize = @intCast(@ctz(push_mask));
        push_mask &= push_mask - 1;

        const bit_mask = @as(u64, 1) << @intCast(bit);
        if ((payload_mask & bit_mask) != 0) continue;

        const opcode: Opcode = @enumFromInt(bytes[bit]);
        const push_len: usize = opcode.toByte() - Opcode.PUSH0.toByte();
        const payload_start = bit + 1;
        const payload_end = payload_start + push_len;
        if (payload_start < len) {
            payload_mask |= rangeMask(payload_start, @min(push_len, len - payload_start));
        }
        if (payload_end > len) {
            carry_payload.* = payload_end - len;
        }
    }

    const boundary = ~payload_mask & valid_lanes;
    return .{
        .boundary = boundary,
        .jumpdest = raw_jumpdest_mask & boundary,
    };
}

fn lowMask(count: usize) u64 {
    if (count == 0) return 0;
    if (count >= 64) return ~@as(u64, 0);
    return (@as(u64, 1) << @intCast(count)) - 1;
}

fn rangeMask(start: usize, count: usize) u64 {
    if (count == 0) return 0;
    return lowMask(count) << @intCast(start);
}

test "raw SIMD masks match scalar mask bit positions" {
    var bytes = [_]u8{0} ** lanes;

    inline for (0..lanes) |lane| {
        bytes = [_]u8{0} ** lanes;
        bytes[lane] = Opcode.PUSH1.toByte();
        var expected = @as(u64, 1) << lane;
        var simd = rawSimdMasks(&bytes);
        var scalar = rawScalarMasks(&bytes);
        try std.testing.expectEqual(expected, simd.push);
        try std.testing.expectEqual(scalar.push, simd.push);
        try std.testing.expectEqual(scalar.jumpdest, simd.jumpdest);

        bytes = [_]u8{0} ** lanes;
        bytes[lane] = Opcode.JUMPDEST.toByte();
        expected = @as(u64, 1) << lane;
        simd = rawSimdMasks(&bytes);
        scalar = rawScalarMasks(&bytes);
        try std.testing.expectEqual(expected, simd.jumpdest);
        try std.testing.expectEqual(scalar.push, simd.push);
        try std.testing.expectEqual(scalar.jumpdest, simd.jumpdest);
    }
}

test "scanner marks jumpdests while ignoring PUSH payload noise" {
    const bytecode = t.bytecode(.{ .PUSH1, .JUMPDEST, .JUMPDEST });
    var map = try Metadata.BitSet.initEmpty(std.testing.allocator, bytecode.len);
    defer map.deinit(std.testing.allocator);

    markJumpDests(&map, &bytecode);

    try std.testing.expect(!map.isSet(0));
    try std.testing.expect(!map.isSet(1));
    try std.testing.expect(map.isSet(2));
}

test "scanner carries PUSH payload across chunks" {
    var bytecode = [_]u8{0} ** 48;
    bytecode[0] = Opcode.PUSH32.toByte();
    bytecode[1] = Opcode.JUMPDEST.toByte();
    bytecode[31] = Opcode.JUMPDEST.toByte();
    bytecode[33] = Opcode.JUMPDEST.toByte();
    var map = try Metadata.BitSet.initEmpty(std.testing.allocator, bytecode.len);
    defer map.deinit(std.testing.allocator);

    markJumpDests(&map, &bytecode);

    try std.testing.expect(!map.isSet(1));
    try std.testing.expect(!map.isSet(31));
    try std.testing.expect(map.isSet(33));
}
