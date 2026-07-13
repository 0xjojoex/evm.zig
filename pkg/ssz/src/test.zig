//! Integration tests exercising SSZ codecs in composition.
//! Single-codec unit tests live beside their implementation files.

const std = @import("std");
const ssz = @import("lib.zig");
const compatibility = @import("compatibility.zig");

test {
    std.testing.refAllDecls(ssz);
}

test "SSZ Mapped preserves a basic wire schema for a domain newtype" {
    const Slot = struct {
        value: u64,

        fn toWire(value: @This()) u64 {
            return value.value;
        }

        fn fromWire(value: u64) @This() {
            return .{ .value = value };
        }

        pub const Ssz = ssz.Mapped(@This(), ssz.Fixed(u64), .{
            .toWire = toWire,
            .fromWire = fromWire,
        });
    };
    const Message = struct { slot: Slot, enabled: bool };
    const MessageSsz = ssz.Container(Message, .{});
    const WireMessage = struct { slot: u64, enabled: bool };
    const WireMessageSsz = ssz.Container(WireMessage, .{});
    const value = Message{ .slot = .{ .value = 42 }, .enabled = true };
    var encoded: [9]u8 = undefined;

    try std.testing.expectEqualSlices(
        u8,
        &.{ 42, 0, 0, 0, 0, 0, 0, 0, 1 },
        try MessageSsz.encode(&encoded, value),
    );
    try std.testing.expectEqualDeep(value, try MessageSsz.decode(&encoded));
    try std.testing.expectEqual(
        try ssz.hashTreeRoot(ssz.Fixed(u64), 42),
        try ssz.hashTreeRoot(Slot.Ssz, value.slot),
    );
    try std.testing.expectEqual(
        try ssz.hashTreeRoot(WireMessageSsz, .{ .slot = 42, .enabled = true }),
        try ssz.hashTreeRoot(MessageSsz, value),
    );
    try std.testing.expect(compatibility.compatible(Slot.Ssz, ssz.Fixed(u64)));
}

test "SSZ Mapped keeps basic element packing inside lists" {
    const Slot = struct {
        value: u64,

        fn toWire(value: @This()) u64 {
            return value.value;
        }

        fn fromWire(value: u64) @This() {
            return .{ .value = value };
        }

        pub const Ssz = ssz.Mapped(@This(), ssz.Fixed(u64), .{
            .toWire = toWire,
            .fromWire = fromWire,
        });
    };
    const Slots = ssz.ListOf(Slot.Ssz, 4);
    const Integers = ssz.List(u64, 4);
    const slots = [_]Slot{ .{ .value = 3 }, .{ .value = 5 }, .{ .value = 8 } };
    const integers = [_]u64{ 3, 5, 8 };
    var slot_bytes: [24]u8 = undefined;
    var integer_bytes: [24]u8 = undefined;

    try std.testing.expectEqualSlices(
        u8,
        try Integers.encode(&integer_bytes, &integers),
        try Slots.encode(&slot_bytes, &slots),
    );
    try std.testing.expectEqual(
        try ssz.hashTreeRoot(Integers, &integers),
        try ssz.hashTreeRoot(Slots, &slots),
    );

    var decoded = try Slots.decodeAlloc(std.testing.allocator, &slot_bytes);
    defer Slots.deinit(std.testing.allocator, &decoded);
    try std.testing.expectEqualDeep(slots, decoded[0..slots.len].*);
}

test "SSZ Mapped transfers allocator-backed wire ownership" {
    const Bytes = struct {
        value: []const u8,

        fn toWire(value: @This()) []const u8 {
            return value.value;
        }

        fn fromWire(value: []const u8) @This() {
            return .{ .value = value };
        }

        pub const Ssz = ssz.Mapped(@This(), ssz.ByteList(8), .{
            .toWire = toWire,
            .fromWire = fromWire,
        });
    };

    const borrowed = try Bytes.Ssz.decode("mapped");
    try std.testing.expectEqualSlices(u8, "mapped", borrowed.value);
    try std.testing.expectEqual(
        try ssz.hashTreeRoot(ssz.ByteList(8), "mapped"),
        try ssz.hashTreeRoot(Bytes.Ssz, borrowed),
    );

    var owned = try Bytes.Ssz.decodeAlloc(std.testing.allocator, "mapped");
    try std.testing.expectEqualSlices(u8, "mapped", owned.value);
    Bytes.Ssz.deinit(std.testing.allocator, &owned);
    try std.testing.expectEqual(@as(usize, 0), owned.value.len);
}

const CountingVariableU8 = struct {
    pub const Value = u8;
    pub const kind = @import("codec.zig").Kind.list;
    pub const is_variable_size = true;
    pub const fixed_size: ?usize = null;
    pub const requires_allocator = false;
    pub var validation_count: usize = 0;

    pub fn encodedLen(_: Value) ssz.Error!usize {
        return 1;
    }

    pub fn encode(out: []u8, value: Value) ssz.Error![]u8 {
        if (out.len < 1) return error.BufferTooSmall;
        out[0] = value;
        return out[0..1];
    }

    pub fn decode(bytes: []const u8) ssz.Error!Value {
        try validate(bytes);
        return bytes[0];
    }

    pub fn validate(bytes: []const u8) ssz.Error!void {
        validation_count += 1;
        if (bytes.len != 1) return error.InvalidByteLength;
    }
};

test "SSZ Container composes VectorOf as a variable field" {
    const Pair = ssz.VectorOf(ssz.ByteList(2), 2);
    const Value = struct {
        tag: u8,
        pair: Pair.Value,
    };
    const ValueSsz = ssz.Container(Value, .{ .pair = Pair });
    const value = Value{ .tag = 7, .pair = .{ "a", "b" } };
    var storage: [15]u8 = undefined;

    const encoded = try ValueSsz.encode(&storage, value);
    try std.testing.expectEqualSlices(
        u8,
        &.{
            7, 5, 0, 0,   0,
            8, 0, 0, 0,   9,
            0, 0, 0, 'a', 'b',
        },
        encoded,
    );

    var decoded = try ValueSsz.decodeAlloc(std.testing.allocator, encoded);
    defer ValueSsz.deinit(std.testing.allocator, &decoded);
    try std.testing.expectEqual(value.tag, decoded.tag);
    for (value.pair, decoded.pair) |expected, actual| {
        try std.testing.expectEqualSlices(u8, expected, actual);
    }
}

test "SSZ Container stores fixed Bitvector fields inline" {
    const Flags = ssz.Bitvector(10);
    const Value = struct {
        flags: Flags.Value,
        count: u16,
    };
    const ValueSsz = ssz.Container(Value, .{ .flags = Flags });
    var flags = [_]bool{false} ** 10;
    flags[0] = true;
    flags[9] = true;
    const value = Value{ .flags = flags, .count = 0x1234 };
    var storage: [4]u8 = undefined;

    try std.testing.expect(!ValueSsz.is_variable_size);
    try std.testing.expectEqual(@as(?usize, 4), ValueSsz.fixed_size);
    const encoded = try ValueSsz.encode(&storage, value);
    try std.testing.expectEqualSlices(u8, &.{ 0x01, 0x02, 0x34, 0x12 }, encoded);

    const decoded = try ValueSsz.decode(encoded);
    try std.testing.expectEqualDeep(value, decoded);
}

test "SSZ Container composes Bitlist as a variable field" {
    const Bits = ssz.Bitlist(8);
    const Value = struct {
        id: u16,
        bits: []const bool,
    };
    const ValueSsz = ssz.Container(Value, .{ .bits = Bits });
    const bits = [_]bool{ true, false, true };
    const value = Value{ .id = 7, .bits = &bits };
    var storage: [7]u8 = undefined;

    const encoded = try ValueSsz.encode(&storage, value);
    try std.testing.expectEqualSlices(u8, &.{ 7, 0, 6, 0, 0, 0, 0x0d }, encoded);

    var decoded = try ValueSsz.decodeAlloc(std.testing.allocator, encoded);
    defer ValueSsz.deinit(std.testing.allocator, &decoded);
    try std.testing.expectEqual(value.id, decoded.id);
    try std.testing.expectEqualSlices(bool, value.bits, decoded.bits);
}

test "SSZ ListOf composes Union alternatives" {
    const Choice = union(enum) {
        number: u16,
        bytes: []const u8,
    };
    const ChoiceSsz = ssz.Union(Choice, .{
        .bytes = ssz.ByteList(4),
    });
    const Choices = ssz.ListOf(ChoiceSsz, 2);
    const values = [_]Choice{
        .{ .number = 0x1234 },
        .{ .bytes = "a" },
    };
    var storage: [13]u8 = undefined;

    const encoded = try Choices.encode(&storage, &values);
    try std.testing.expectEqualSlices(
        u8,
        &.{ 8, 0, 0, 0, 11, 0, 0, 0, 0, 0x34, 0x12, 1, 'a' },
        encoded,
    );

    var decoded = try Choices.decodeAlloc(std.testing.allocator, encoded);
    defer Choices.deinit(std.testing.allocator, &decoded);
    try std.testing.expectEqual(@as(u16, 0x1234), decoded[0].number);
    try std.testing.expectEqualStrings("a", decoded[1].bytes);
}

test "SSZ Container composes Union as a variable field" {
    const Choice = union(enum) {
        number: u16,
        bytes: []const u8,
    };
    const ChoiceSsz = ssz.Union(Choice, .{
        .bytes = ssz.ByteList(4),
    });
    const Value = struct {
        id: u8,
        choice: Choice,
    };
    const ValueSsz = ssz.Container(Value, .{ .choice = ChoiceSsz });
    const value = Value{ .id = 7, .choice = .{ .bytes = "ab" } };
    var storage: [8]u8 = undefined;

    const encoded = try ValueSsz.encode(&storage, value);
    try std.testing.expectEqualSlices(u8, &.{ 7, 5, 0, 0, 0, 1, 'a', 'b' }, encoded);

    var decoded = try ValueSsz.decodeAlloc(std.testing.allocator, encoded);
    defer ValueSsz.deinit(std.testing.allocator, &decoded);
    try std.testing.expectEqual(value.id, decoded.id);
    try std.testing.expectEqualStrings(value.choice.bytes, decoded.choice.bytes);
}

test "SSZ Container composes CompatibleUnion as a variable field" {
    const Choice = union(enum) {
        primary: u16,
        secondary: u16,
    };
    const ChoiceSsz = ssz.CompatibleUnion(Choice, .{
        .primary = .{ .selector = 1 },
        .secondary = .{ .selector = 7 },
    });
    const Value = struct {
        id: u8,
        choice: Choice,
    };
    const ValueSsz = ssz.Container(Value, .{ .choice = ChoiceSsz });
    const value = Value{ .id = 9, .choice = .{ .primary = 0x1234 } };
    var storage: [8]u8 = undefined;

    const encoded = try ValueSsz.encode(&storage, value);
    try std.testing.expectEqualSlices(u8, &.{ 9, 5, 0, 0, 0, 1, 0x34, 0x12 }, encoded);
    try std.testing.expect(!ValueSsz.requires_allocator);
    const decoded = try ValueSsz.decode(encoded);
    try std.testing.expectEqualDeep(value, decoded);
}

test "SSZ Container composes fixed, ByteList, and List fields" {
    const Payload = struct {
        number: u16,
        extra_data: []const u8,
        values: []const u16,
    };
    const PayloadSsz = ssz.Container(Payload, .{
        .extra_data = ssz.ByteList(4),
        .values = ssz.List(u16, 3),
    });
    const values = [_]u16{ 7, 9 };
    const payload = Payload{
        .number = 0x1234,
        .extra_data = "ab",
        .values = &values,
    };
    var storage: [16]u8 = undefined;

    try std.testing.expectEqual(@as(usize, 16), try PayloadSsz.encodedLen(payload));
    const encoded = try PayloadSsz.encode(&storage, payload);
    try std.testing.expectEqualSlices(
        u8,
        &.{
            0x34, 0x12,
            10,   0,
            0,    0,
            12,   0,
            0,    0,
            'a',  'b',
            7,    0,
            9,    0,
        },
        encoded,
    );

    var decoded = try PayloadSsz.decodeAlloc(std.testing.allocator, encoded);
    defer PayloadSsz.deinit(std.testing.allocator, &decoded);
    try std.testing.expectEqual(payload.number, decoded.number);
    try std.testing.expectEqualSlices(u8, payload.extra_data, decoded.extra_data);
    try std.testing.expectEqualSlices(u16, payload.values, decoded.values);
}

test "SSZ Container accepts empty variable fields" {
    const Value = struct {
        bytes: []const u8,
        numbers: []const u16,
    };
    const ValueSsz = ssz.Container(Value, .{
        .bytes = ssz.ByteList(4),
        .numbers = ssz.List(u16, 2),
    });
    const no_numbers = [_]u16{};
    var storage: [8]u8 = undefined;
    const encoded = try ValueSsz.encode(&storage, .{ .bytes = "", .numbers = &no_numbers });

    try std.testing.expectEqualSlices(u8, &.{ 8, 0, 0, 0, 8, 0, 0, 0 }, encoded);
    var decoded = try ValueSsz.decodeAlloc(std.testing.allocator, encoded);
    defer ValueSsz.deinit(std.testing.allocator, &decoded);
    try std.testing.expectEqual(@as(usize, 0), decoded.bytes.len);
    try std.testing.expectEqual(@as(usize, 0), decoded.numbers.len);
}

test "SSZ Container rejects malformed offsets and child scopes" {
    const Value = struct {
        bytes: []const u8,
        numbers: []const u16,
    };
    const ValueSsz = ssz.Container(Value, .{
        .bytes = ssz.ByteList(4),
        .numbers = ssz.List(u16, 2),
    });

    try std.testing.expectError(
        error.InvalidFirstOffset,
        ValueSsz.decodeAlloc(std.testing.allocator, &.{ 7, 0, 0, 0, 8, 0, 0, 0 }),
    );
    try std.testing.expectError(
        error.OffsetsNotMonotonic,
        ValueSsz.decodeAlloc(std.testing.allocator, &.{ 8, 0, 0, 0, 7, 0, 0, 0 }),
    );
    try std.testing.expectError(
        error.OffsetOutOfBounds,
        ValueSsz.decodeAlloc(std.testing.allocator, &.{ 8, 0, 0, 0, 9, 0, 0, 0 }),
    );
    try std.testing.expectError(
        error.InvalidByteLength,
        ValueSsz.decodeAlloc(std.testing.allocator, &.{ 8, 0, 0, 0, 9, 0, 0, 0, 'a', 1 }),
    );
}

test "SSZ Container cleans owned fields when a later fixed field is invalid" {
    const Value = struct {
        bytes: []const u8,
        active: bool,
    };
    const ValueSsz = ssz.Container(Value, .{ .bytes = ssz.ByteList(4) });

    try std.testing.expectError(
        error.InvalidBoolean,
        ValueSsz.decodeAlloc(std.testing.allocator, &.{ 5, 0, 0, 0, 2, 'x' }),
    );
}

test "SSZ Container validate checks inferred fixed fields" {
    const FixedValue = struct { active: bool };
    const FixedValueSsz = ssz.Container(FixedValue, .{});
    try std.testing.expectError(error.InvalidBoolean, FixedValueSsz.validate(&.{2}));

    const MixedValue = struct {
        active: bool,
        bytes: []const u8,
    };
    const MixedValueSsz = ssz.Container(MixedValue, .{ .bytes = ssz.ByteList(4) });
    try std.testing.expectError(
        error.InvalidBoolean,
        MixedValueSsz.validate(&.{ 2, 5, 0, 0, 0 }),
    );
}

test "SSZ composite decode validates each child once while materializing" {
    const Box = struct { value: u8 };
    const BoxSsz = ssz.Container(Box, .{ .value = CountingVariableU8 });
    CountingVariableU8.validation_count = 0;
    try std.testing.expectEqual(Box{ .value = 7 }, try BoxSsz.decode(&.{ 4, 0, 0, 0, 7 }));
    try std.testing.expectEqual(@as(usize, 1), CountingVariableU8.validation_count);

    const Values = ssz.ListOf(CountingVariableU8, 2);
    CountingVariableU8.validation_count = 0;
    var list = try Values.decodeAlloc(
        std.testing.allocator,
        &.{ 8, 0, 0, 0, 9, 0, 0, 0, 7, 8 },
    );
    defer Values.deinit(std.testing.allocator, &list);
    try std.testing.expectEqualSlices(u8, &.{ 7, 8 }, list);
    try std.testing.expectEqual(@as(usize, 2), CountingVariableU8.validation_count);

    const Pair = ssz.VectorSliceOf(CountingVariableU8, 2);
    CountingVariableU8.validation_count = 0;
    var vector = try Pair.decodeAlloc(
        std.testing.allocator,
        &.{ 8, 0, 0, 0, 9, 0, 0, 0, 7, 8 },
    );
    defer Pair.deinit(std.testing.allocator, &vector);
    try std.testing.expectEqualSlices(u8, &.{ 7, 8 }, vector);
    try std.testing.expectEqual(@as(usize, 2), CountingVariableU8.validation_count);

    const Choice = union(enum) { value: u8 };
    const ChoiceSsz = ssz.Union(Choice, .{ .value = CountingVariableU8 });
    CountingVariableU8.validation_count = 0;
    try std.testing.expectEqualDeep(Choice{ .value = 7 }, try ChoiceSsz.decode(&.{ 0, 7 }));
    try std.testing.expectEqual(@as(usize, 1), CountingVariableU8.validation_count);

    const CompatibleChoice = union(enum) { value: u8 };
    const CompatibleChoiceSsz = ssz.CompatibleUnion(CompatibleChoice, .{
        .value = .{ .selector = 1, .codec = CountingVariableU8 },
    });
    CountingVariableU8.validation_count = 0;
    try std.testing.expectEqualDeep(
        CompatibleChoice{ .value = 7 },
        try CompatibleChoiceSsz.decode(&.{ 1, 7 }),
    );
    try std.testing.expectEqual(@as(usize, 1), CountingVariableU8.validation_count);
}

test "SSZ Container allocates and releases only configured fields" {
    const Blob = ssz.Alloc(ssz.ByteVector(8));
    const Value = struct {
        count: u16,
        blob: Blob.Value,

        pub const Ssz = ssz.Container(@This(), .{ .blob = Blob });
    };
    const blob = [_]u8{ 0, 1, 2, 3, 4, 5, 6, 7 };
    const value = Value{ .count = 9, .blob = &blob };
    var encoded: [10]u8 = undefined;

    try std.testing.expect(Value.Ssz.requires_allocator);
    try std.testing.expect(@hasDecl(Value.Ssz, "decodeAlloc"));
    try std.testing.expect(!@hasDecl(Value.Ssz, "decode"));
    _ = try Value.Ssz.encode(&encoded, value);
    var decoded = try Value.Ssz.decodeAlloc(std.testing.allocator, &encoded);
    defer Value.Ssz.deinit(std.testing.allocator, &decoded);
    try std.testing.expectEqual(value.count, decoded.count);
    try std.testing.expectEqualSlices(u8, value.blob, decoded.blob);
}

test "SSZ Container releases partial ownership on every allocation failure" {
    const Harness = struct {
        fn run(allocator: std.mem.Allocator) !void {
            const Messages = ssz.ListOf(ssz.ByteList(4), 2);
            const Blob = ssz.Alloc(ssz.ByteVector(8));
            const Value = struct {
                messages: Messages.Value,
                blob: Blob.Value,

                pub const Ssz = ssz.Container(@This(), .{
                    .messages = Messages,
                    .blob = Blob,
                });
            };
            const messages = [_][]const u8{ "a", "bc" };
            const blob = [_]u8{ 0, 1, 2, 3, 4, 5, 6, 7 };
            const value = Value{ .messages = &messages, .blob = &blob };
            var storage: [23]u8 = undefined;

            const encoded = try Value.Ssz.encode(&storage, value);
            var decoded = try Value.Ssz.decodeAlloc(allocator, encoded);
            defer Value.Ssz.deinit(allocator, &decoded);
            try std.testing.expectEqualDeep(value, decoded);
        }
    };

    try std.testing.checkAllAllocationFailures(std.testing.allocator, Harness.run, .{});
}

test "SSZ Container propagates field limits and output capacity" {
    const Value = struct { bytes: []const u8 };
    const ValueSsz = ssz.Container(Value, .{ .bytes = ssz.ByteList(2) });
    var short_storage: [5]u8 = undefined;
    var enough_storage: [7]u8 = undefined;

    try std.testing.expectError(error.BufferTooSmall, ValueSsz.encode(&short_storage, .{ .bytes = "ab" }));
    try std.testing.expectError(error.ListLimitExceeded, ValueSsz.encode(&enough_storage, .{ .bytes = "abc" }));
}
