const std = @import("std");
const Metadata = @import("Metadata.zig");
const Opcode = @import("../opcode.zig").Opcode;
const t = @import("../t.zig");

pub const lanes = 16;

const jumpdest_opcode = @intFromEnum(Opcode.JUMPDEST);
const push0_opcode = @intFromEnum(Opcode.PUSH0);
const push1_opcode = @intFromEnum(Opcode.PUSH1);
const push32_opcode = @intFromEnum(Opcode.PUSH32);

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
        const masks = rawSimdMasks(bytes, index);
        consume(context, index, resolveBoundaryMasks(bytes[index..][0..lanes], masks.push, masks.jumpdest, &carry_payload));
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
        const masks = rawSimdMasks(bytes, index);
        try consume(context, index, resolveBoundaryMasks(bytes[index..][0..lanes], masks.push, masks.jumpdest, &carry_payload));
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

fn rawSimdMasks(bytes: []const u8, index: usize) RawMasks {
    const Vec = @Vector(lanes, u8);
    const ptr: *align(1) const Vec = @ptrCast(bytes.ptr + index);
    const chunk = ptr.*;
    const push_matches = (chunk & @as(Vec, @splat(0xe0))) == @as(Vec, @splat(0x60));
    const jumpdest_matches = chunk == @as(Vec, @splat(jumpdest_opcode));

    var push: u64 = 0;
    var jumpdest: u64 = 0;
    inline for (0..lanes) |lane| {
        push |= @as(u64, @intFromBool(push_matches[lane])) << lane;
        jumpdest |= @as(u64, @intFromBool(jumpdest_matches[lane])) << lane;
    }
    return .{ .push = push, .jumpdest = jumpdest };
}

fn rawScalarMasks(bytes: []const u8) RawMasks {
    var push: u64 = 0;
    var jumpdest: u64 = 0;
    for (bytes, 0..) |byte, index| {
        push |= @as(u64, @intFromBool(byte >= push1_opcode and byte <= push32_opcode)) << @intCast(index);
        jumpdest |= @as(u64, @intFromBool(byte == jumpdest_opcode)) << @intCast(index);
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

        const push_len: usize = bytes[bit] - push0_opcode;
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
    bytecode[0] = Opcode.PUSH32.toInt();
    bytecode[1] = Opcode.JUMPDEST.toInt();
    bytecode[31] = Opcode.JUMPDEST.toInt();
    bytecode[33] = Opcode.JUMPDEST.toInt();
    var map = try Metadata.BitSet.initEmpty(std.testing.allocator, bytecode.len);
    defer map.deinit(std.testing.allocator);

    markJumpDests(&map, &bytecode);

    try std.testing.expect(!map.isSet(1));
    try std.testing.expect(!map.isSet(31));
    try std.testing.expect(map.isSet(33));
}
