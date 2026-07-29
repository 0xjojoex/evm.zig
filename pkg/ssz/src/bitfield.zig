const std = @import("std");
const ssz = @import("lib.zig");
const codec = @import("codec.zig");
const Error = @import("error.zig").Error;
const schema_limit = @import("schema_limit.zig");

const bits_per_byte = 8;

/// Borrowed canonical SSZ bitfield serialization with its semantic bit length.
///
/// For bitlists, `serialized` includes the delimiter bit required by the wire
/// encoding. `len` and `isSet` expose only the semantic bits before it.
/// Keep the borrowed serialization alive and unchanged while using the view.
pub const PackedBitsView = struct {
    serialized: []const u8,
    bit_length: usize,

    pub fn len(self: PackedBitsView) usize {
        return self.bit_length;
    }

    pub fn isSet(self: PackedBitsView, index: usize) bool {
        std.debug.assert(index < self.bit_length);
        return getBit(self.serialized, index);
    }
};

/// Return the codec for SSZ `Bitvector[length]`.
pub fn Bitvector(comptime bit_length: usize) type {
    if (bit_length == 0) @compileError("SSZ bitvectors cannot be empty");
    const byte_length = (bit_length - 1) / bits_per_byte + 1;

    return struct {
        pub const Value = [bit_length]bool;
        pub const kind: codec.Kind = .bitvector;
        pub const length = bit_length;
        pub const is_variable_size = false;
        pub const fixed_size: ?usize = byte_length;
        pub const requires_allocator = false;

        pub fn encodedLen(_: Value) Error!usize {
            return byte_length;
        }

        pub fn encode(out: []u8, value: Value) Error![]u8 {
            if (out.len < byte_length) return error.BufferTooSmall;
            @memset(out[0..byte_length], 0);
            for (value, 0..) |bit, index| {
                if (bit) setBit(out, index);
            }
            return out[0..byte_length];
        }

        pub fn decode(bytes: []const u8) Error!Value {
            try validate(bytes);
            var value: Value = undefined;
            for (&value, 0..) |*bit, index| {
                bit.* = getBit(bytes, index);
            }
            return value;
        }

        pub fn validate(bytes: []const u8) Error!void {
            try validateBitvector(bytes, bit_length);
        }
    };
}

/// Return a borrowed packed codec for SSZ `Bitvector[length]`.
pub fn PackedBitvector(comptime bit_length: usize) type {
    if (bit_length == 0) @compileError("SSZ bitvectors cannot be empty");
    const byte_length = (bit_length - 1) / bits_per_byte + 1;

    return struct {
        pub const Value = PackedBitsView;
        pub const kind: codec.Kind = .bitvector;
        pub const length = bit_length;
        pub const is_variable_size = false;
        pub const fixed_size: ?usize = byte_length;
        pub const requires_allocator = false;

        pub fn encodedLen(value: Value) Error!usize {
            try validateValue(value);
            return byte_length;
        }

        pub fn encode(out: []u8, value: Value) Error![]u8 {
            const len = try encodedLen(value);
            if (out.len < len) return error.BufferTooSmall;
            @memcpy(out[0..len], value.serialized);
            return out[0..len];
        }

        pub fn decode(bytes: []const u8) Error!Value {
            try validate(bytes);
            return .{ .serialized = bytes, .bit_length = bit_length };
        }

        pub fn validate(bytes: []const u8) Error!void {
            try validateBitvector(bytes, bit_length);
        }

        /// Capability used by Merkleization to consume packed bits directly.
        pub fn packedBits(value: Value) Error!PackedBitsView {
            try validateValue(value);
            return value;
        }

        fn validateValue(value: Value) Error!void {
            if (value.bit_length != bit_length) return error.InvalidByteLength;
            try validate(value.serialized);
        }
    };
}

/// Return an allocation-backed codec for SSZ `Bitvector[length]`.
pub fn BitvectorSlice(comptime bit_length: usize) type {
    if (bit_length == 0) @compileError("SSZ bitvectors cannot be empty");
    const byte_length = (bit_length - 1) / bits_per_byte + 1;

    return struct {
        pub const Value = []const bool;
        pub const Owned = []bool;
        pub const kind: codec.Kind = .bitvector;
        pub const length = bit_length;
        pub const is_variable_size = false;
        pub const fixed_size: ?usize = byte_length;
        pub const requires_allocator = true;

        pub fn encodedLen(value: Value) Error!usize {
            if (value.len != bit_length) return error.InvalidByteLength;
            return byte_length;
        }

        pub fn encode(out: []u8, value: Value) Error![]u8 {
            _ = try encodedLen(value);
            if (out.len < byte_length) return error.BufferTooSmall;
            @memset(out[0..byte_length], 0);
            for (value, 0..) |bit, index| {
                if (bit) setBit(out, index);
            }
            return out[0..byte_length];
        }

        pub fn decodeAlloc(allocator: std.mem.Allocator, bytes: []const u8) (Error || std.mem.Allocator.Error)!Value {
            try validate(bytes);
            const value = try allocator.alloc(bool, bit_length);
            for (value, 0..) |*bit, index| {
                bit.* = getBit(bytes, index);
            }
            return value;
        }

        pub fn validate(bytes: []const u8) Error!void {
            try validateBitvector(bytes, bit_length);
        }

        pub fn deinit(allocator: std.mem.Allocator, value: *Value) void {
            allocator.free(value.*);
            value.* = &.{};
        }
    };
}

/// Return the codec for SSZ `Bitlist[limit]`.
/// `limit` is an arbitrary-precision schema capacity; runtime lengths remain `usize`.
pub fn Bitlist(comptime limit: comptime_int) type {
    return BitlistCodec(limit, false);
}

/// Codec for SSZ `ProgressiveBitlist`.
pub const ProgressiveBitlist = BitlistCodec(0, true);

/// Return a borrowed packed codec for SSZ `Bitlist[limit]`.
pub fn PackedBitlist(comptime limit: comptime_int) type {
    return PackedBitlistCodec(limit, false);
}

/// Borrowed packed codec for SSZ `ProgressiveBitlist`.
pub const ProgressivePackedBitlist = PackedBitlistCodec(0, true);

fn BitlistCodec(comptime limit: comptime_int, comptime progressive: bool) type {
    comptime schema_limit.assertValid(limit);
    return struct {
        pub const Value = []const bool;
        pub const Owned = []bool;
        pub const kind: codec.Kind = if (progressive) .progressive_bitlist else .bitlist;
        pub const max_length: ?comptime_int = if (progressive) null else limit;
        pub const is_progressive = progressive;
        pub const is_variable_size = true;
        pub const fixed_size: ?usize = null;
        pub const requires_allocator = true;

        pub fn encodedLen(value: Value) Error!usize {
            if (!progressive and schema_limit.exceededBy(value.len, limit)) return error.ListLimitExceeded;
            const len = value.len / bits_per_byte + 1;
            if (len > std.math.maxInt(u32)) return error.EncodedLengthOverflow;
            return len;
        }

        pub fn encode(out: []u8, value: Value) Error![]u8 {
            const len = try encodedLen(value);
            if (out.len < len) return error.BufferTooSmall;
            @memset(out[0..len], 0);
            for (value, 0..) |bit, index| {
                if (bit) setBit(out, index);
            }
            setBit(out, value.len);
            return out[0..len];
        }

        pub fn decodeAlloc(allocator: std.mem.Allocator, bytes: []const u8) (Error || std.mem.Allocator.Error)!Value {
            const length = try decodedLength(bytes);
            const value = try allocator.alloc(bool, length);
            for (value, 0..) |*bit, index| {
                bit.* = getBit(bytes, index);
            }
            return value;
        }

        pub fn validate(bytes: []const u8) Error!void {
            _ = try decodedLength(bytes);
        }

        pub fn deinit(allocator: std.mem.Allocator, value: *Value) void {
            allocator.free(value.*);
            value.* = &.{};
        }

        fn decodedLength(bytes: []const u8) Error!usize {
            return bitlistDecodedLength(bytes, limit, progressive);
        }
    };
}

fn PackedBitlistCodec(comptime limit: comptime_int, comptime progressive: bool) type {
    comptime schema_limit.assertValid(limit);
    return struct {
        pub const Value = PackedBitsView;
        pub const kind: codec.Kind = if (progressive) .progressive_bitlist else .bitlist;
        pub const max_length: ?comptime_int = if (progressive) null else limit;
        pub const is_progressive = progressive;
        pub const is_variable_size = true;
        pub const fixed_size: ?usize = null;
        pub const requires_allocator = false;

        pub fn encodedLen(value: Value) Error!usize {
            try validateValue(value);
            return value.serialized.len;
        }

        pub fn encode(out: []u8, value: Value) Error![]u8 {
            const len = try encodedLen(value);
            if (out.len < len) return error.BufferTooSmall;
            @memcpy(out[0..len], value.serialized);
            return out[0..len];
        }

        pub fn decode(bytes: []const u8) Error!Value {
            return .{ .serialized = bytes, .bit_length = try decodedLength(bytes) };
        }

        pub fn validate(bytes: []const u8) Error!void {
            _ = try decodedLength(bytes);
        }

        /// Capability used by Merkleization to consume packed bits directly.
        pub fn packedBits(value: Value) Error!PackedBitsView {
            try validateValue(value);
            return value;
        }

        fn validateValue(value: Value) Error!void {
            if (try decodedLength(value.serialized) != value.bit_length) {
                return error.InvalidByteLength;
            }
        }

        fn decodedLength(bytes: []const u8) Error!usize {
            return bitlistDecodedLength(bytes, limit, progressive);
        }
    };
}

fn setBit(bytes: []u8, index: usize) void {
    bytes[index / bits_per_byte] |= @as(u8, 1) << @intCast(index % bits_per_byte);
}

fn getBit(bytes: []const u8, index: usize) bool {
    return bytes[index / bits_per_byte] & (@as(u8, 1) << @intCast(index % bits_per_byte)) != 0;
}

fn validateBitvector(bytes: []const u8, bit_length: usize) Error!void {
    const byte_length = (bit_length - 1) / bits_per_byte + 1;
    if (bytes.len != byte_length) return error.InvalidByteLength;
    const used_bits = bit_length % bits_per_byte;
    if (used_bits != 0) {
        const valid_mask = (@as(u8, 1) << @intCast(used_bits)) - 1;
        if (bytes[byte_length - 1] & ~valid_mask != 0) {
            return error.InvalidBitvectorPadding;
        }
    }
}

fn bitlistDecodedLength(
    bytes: []const u8,
    comptime limit: comptime_int,
    comptime progressive: bool,
) Error!usize {
    if (bytes.len == 0) return error.InvalidBitlistDelimiter;
    if (bytes.len > std.math.maxInt(u32)) return error.EncodedLengthOverflow;
    const last = bytes[bytes.len - 1];
    if (last == 0) return error.InvalidBitlistDelimiter;

    const delimiter_index = 7 - @as(usize, @intCast(@clz(last)));
    const whole_bytes_length = std.math.mul(usize, bytes.len - 1, bits_per_byte) catch
        return error.EncodedLengthOverflow;
    const length = std.math.add(usize, whole_bytes_length, delimiter_index) catch
        return error.EncodedLengthOverflow;
    if (!progressive and schema_limit.exceededBy(length, limit)) return error.ListLimitExceeded;
    return length;
}

test "SSZ Bitvector packs bits least-significant first" {
    const Flags = ssz.Bitvector(10);
    var value = [_]bool{false} ** 10;
    value[0] = true;
    value[3] = true;
    value[8] = true;
    value[9] = true;
    var storage: [2]u8 = undefined;

    const encoded = try Flags.encode(&storage, value);
    try std.testing.expectEqualSlices(u8, &.{ 0x09, 0x03 }, encoded);
    try std.testing.expectEqualDeep(value, try Flags.decode(encoded));
}

test "SSZ Bitvector rejects non-zero padding bits" {
    const Flags = ssz.Bitvector(10);

    try std.testing.expectError(error.InvalidByteLength, Flags.validate(&.{0}));
    try std.testing.expectError(error.InvalidBitvectorPadding, Flags.validate(&.{ 0, 0x80 }));
}

test "SSZ PackedBitvector borrows canonical bytes and roundtrips exactly" {
    const Flags = ssz.PackedBitvector(10);
    const serialized = [_]u8{ 0x09, 0x03 };
    const decoded = try Flags.decode(&serialized);

    try std.testing.expect(!Flags.requires_allocator);
    try std.testing.expectEqual(@as(usize, 10), decoded.len());
    try std.testing.expect(decoded.isSet(0));
    try std.testing.expect(decoded.isSet(3));
    try std.testing.expect(decoded.isSet(8));
    try std.testing.expect(decoded.isSet(9));
    try std.testing.expect(!decoded.isSet(1));
    try std.testing.expectEqual(serialized[0..].ptr, decoded.serialized.ptr);

    var storage: [2]u8 = undefined;
    try std.testing.expectEqualSlices(u8, &serialized, try Flags.encode(&storage, decoded));
}

test "SSZ PackedBitvector enforces vector length and padding boundaries" {
    const One = ssz.PackedBitvector(1);
    const FullByte = ssz.PackedBitvector(8);

    try std.testing.expectEqual(@as(usize, 1), (try One.decode(&.{0x01})).len());
    try std.testing.expectEqual(@as(usize, 8), (try FullByte.decode(&.{0xff})).len());
    try std.testing.expectError(error.InvalidByteLength, One.decode(""));
    try std.testing.expectError(error.InvalidBitvectorPadding, One.decode(&.{0x02}));

    var storage: [1]u8 = undefined;
    try std.testing.expectError(
        error.InvalidByteLength,
        One.encode(&storage, .{ .serialized = &.{0x01}, .bit_length = 2 }),
    );
    try std.testing.expectError(
        error.InvalidBitvectorPadding,
        One.encode(&storage, .{ .serialized = &.{0x02}, .bit_length = 1 }),
    );
}

test "SSZ Bitlist uses a delimiter bit at its actual length" {
    const Bits = ssz.Bitlist(16);
    const value = [_]bool{ true, false, true, false, true };
    var storage: [3]u8 = undefined;

    const encoded = try Bits.encode(&storage, &value);
    try std.testing.expectEqualSlices(u8, &.{0x35}, encoded);

    var decoded = try Bits.decodeAlloc(std.testing.allocator, encoded);
    defer Bits.deinit(std.testing.allocator, &decoded);
    try std.testing.expectEqualSlices(bool, &value, decoded);
}

test "SSZ Bitlist empty and byte-aligned values remain self-delimiting" {
    const Bits = ssz.Bitlist(8);
    const empty = [_]bool{};
    const full_byte = [_]bool{false} ** 8;
    var storage: [2]u8 = undefined;

    try std.testing.expectEqualSlices(u8, &.{0x01}, try Bits.encode(&storage, &empty));
    try std.testing.expectEqualSlices(u8, &.{ 0x00, 0x01 }, try Bits.encode(&storage, &full_byte));
}

test "SSZ Bitlist keeps schema capacity independent from runtime length" {
    const Bits = ssz.Bitlist(1 << 120);
    const value = [_]bool{ true, false, true };
    var storage: [1]u8 = undefined;

    try std.testing.expect(comptime Bits.max_length.? == 1 << 120);
    try std.testing.expectEqualSlices(u8, &.{0x0d}, try Bits.encode(&storage, &value));
}

test "SSZ zero-limit Bitlist accepts only the empty value" {
    const Bits = ssz.Bitlist(0);
    const empty = [_]bool{};
    var storage: [1]u8 = undefined;

    try std.testing.expectEqualSlices(u8, &.{0x01}, try Bits.encode(&storage, &empty));
    try std.testing.expectError(error.ListLimitExceeded, Bits.validate(&.{0x02}));
}

test "SSZ ProgressiveBitlist preserves delimiter serialization without a schema limit" {
    const value = [_]bool{false} ** 10;
    var storage: [2]u8 = undefined;

    const encoded = try ssz.ProgressiveBitlist.encode(&storage, &value);
    try std.testing.expect(ssz.ProgressiveBitlist.is_progressive);
    try std.testing.expectEqualSlices(u8, &.{ 0, 4 }, encoded);

    var decoded = try ssz.ProgressiveBitlist.decodeAlloc(std.testing.allocator, encoded);
    defer ssz.ProgressiveBitlist.deinit(std.testing.allocator, &decoded);
    try std.testing.expectEqualSlices(bool, &value, decoded);
}

test "SSZ Bitlist rejects missing delimiters and lengths above its limit" {
    const Bits = ssz.Bitlist(4);

    try std.testing.expectError(error.InvalidBitlistDelimiter, Bits.validate(""));
    try std.testing.expectError(error.InvalidBitlistDelimiter, Bits.validate(&.{0}));
    try std.testing.expectError(error.InvalidBitlistDelimiter, Bits.validate(&.{ 1, 0 }));
    try std.testing.expectError(error.ListLimitExceeded, Bits.validate(&.{0x20}));
}

test "SSZ PackedBitlist retains delimiter serialization and borrows input" {
    const Bits = ssz.PackedBitlist(16);
    const serialized = [_]u8{0x35};
    const decoded = try Bits.decode(&serialized);

    try std.testing.expect(!Bits.requires_allocator);
    try std.testing.expectEqual(@as(usize, 5), decoded.len());
    try std.testing.expect(decoded.isSet(0));
    try std.testing.expect(decoded.isSet(2));
    try std.testing.expect(decoded.isSet(4));
    try std.testing.expect(!decoded.isSet(1));
    try std.testing.expectEqual(serialized[0..].ptr, decoded.serialized.ptr);
    try std.testing.expectEqualSlices(u8, &.{0x35}, decoded.serialized);

    var storage: [1]u8 = undefined;
    try std.testing.expectEqualSlices(u8, &serialized, try Bits.encode(&storage, decoded));
}

test "SSZ PackedBitlist handles empty and byte-aligned semantic lengths" {
    const Bits = ssz.PackedBitlist(8);
    const empty = try Bits.decode(&.{0x01});
    const byte_aligned = try Bits.decode(&.{ 0xa5, 0x01 });

    try std.testing.expectEqual(@as(usize, 0), empty.len());
    try std.testing.expectEqual(@as(usize, 8), byte_aligned.len());
    try std.testing.expect(byte_aligned.isSet(0));
    try std.testing.expect(!byte_aligned.isSet(1));
    try std.testing.expect(byte_aligned.isSet(7));
    try std.testing.expectEqualSlices(u8, &.{ 0xa5, 0x01 }, byte_aligned.serialized);
}

test "SSZ packed bitlists reject malformed serialization and stale lengths" {
    const Bits = ssz.PackedBitlist(4);

    try std.testing.expectError(error.InvalidBitlistDelimiter, Bits.decode(""));
    try std.testing.expectError(error.InvalidBitlistDelimiter, Bits.decode(&.{0}));
    try std.testing.expectError(error.InvalidBitlistDelimiter, Bits.decode(&.{ 1, 0 }));
    try std.testing.expectError(error.ListLimitExceeded, Bits.decode(&.{0x20}));

    var storage: [1]u8 = undefined;
    try std.testing.expectError(
        error.InvalidByteLength,
        Bits.encode(&storage, .{ .serialized = &.{0x0d}, .bit_length = 2 }),
    );
    try std.testing.expectError(
        error.InvalidBitlistDelimiter,
        Bits.encode(&storage, .{ .serialized = &.{0}, .bit_length = 0 }),
    );
}

test "SSZ ProgressivePackedBitlist borrows without a schema limit" {
    const serialized = [_]u8{ 0, 4 };
    const decoded = try ssz.ProgressivePackedBitlist.decode(&serialized);

    try std.testing.expect(ssz.ProgressivePackedBitlist.is_progressive);
    try std.testing.expectEqual(@as(usize, 10), decoded.len());
    try std.testing.expectEqual(serialized[0..].ptr, decoded.serialized.ptr);

    var storage: [2]u8 = undefined;
    try std.testing.expectEqualSlices(
        u8,
        &serialized,
        try ssz.ProgressivePackedBitlist.encode(&storage, decoded),
    );
}

test "SSZ containers preserve packed bitfield borrowing without allocation" {
    const PackedVector = ssz.PackedBitvector(10);
    const FixedValue = struct {
        flags: ssz.PackedBitsView,
        count: u16,
    };
    const FixedValueSsz = ssz.Container(FixedValue, .{ .flags = PackedVector });
    const fixed_serialized = [_]u8{ 0x09, 0x03, 0x34, 0x12 };
    const fixed = try FixedValueSsz.decode(&fixed_serialized);

    try std.testing.expect(!FixedValueSsz.requires_allocator);
    try std.testing.expectEqual(@as(u16, 0x1234), fixed.count);
    try std.testing.expectEqual(fixed_serialized[0..].ptr, fixed.flags.serialized.ptr);

    const PackedList = ssz.PackedBitlist(8);
    const VariableValue = struct {
        id: u16,
        bits: ssz.PackedBitsView,
    };
    const VariableValueSsz = ssz.Container(VariableValue, .{ .bits = PackedList });
    const variable_serialized = [_]u8{ 7, 0, 6, 0, 0, 0, 0x0d };
    const variable = try VariableValueSsz.decode(&variable_serialized);

    try std.testing.expect(!VariableValueSsz.requires_allocator);
    try std.testing.expectEqual(@as(u16, 7), variable.id);
    try std.testing.expectEqual(variable_serialized[6..].ptr, variable.bits.serialized.ptr);
    try std.testing.expectEqual(@as(usize, 3), variable.bits.len());
}
