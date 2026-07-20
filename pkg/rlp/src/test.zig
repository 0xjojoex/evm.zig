const std = @import("std");
const rlp = @import("lib.zig");

const Change = struct {
    index: u32,
    value: u256,
};

const Changes = rlp.ListOf(rlp.Field(Change));
const SmallChanges = rlp.BoundedListOf(rlp.Field(Change), 2);
const deeply_nested_raw = [_]u8{ 0xc9, 0xc8, 0xc7, 0xc6, 0xc5, 0xc4, 0xc3, 0xc2, 0xc1, 0xc0 };

const Account = struct {
    address: [20]u8,
    nonce: u64,
    changes: []const Change,
};

comptime {
    if (rlp.Field([]const Change) != Changes) {
        @compileError("non-byte const slices must infer homogeneous RLP lists");
    }
}

const RenamedAmount = struct {
    amount: u64,

    pub const Rlp = rlp.Mapped(
        @This(),
        rlp.Struct(AmountWire, .{}),
        AmountMapping,
    );
};
const AmountWire = struct {
    value: u64,
};
const AmountMapping = struct {
    pub fn toWire(value: RenamedAmount) AmountWire {
        return .{ .value = value.amount };
    }

    pub fn fromWire(value: AmountWire) RenamedAmount {
        return .{ .amount = value.value };
    }
};
const PlainField = struct {
    amount: u256,
};

const RuntimeFields = struct {
    status: u8,
    root: [4]u8,
    tail: ?u16,
};

const RuntimePrefix = struct {
    status: u8,
    root: [4]u8,
};

fn emitRuntimeFields(fields: anytype, value: RuntimeFields) rlp.EncodeError!void {
    try fields.encodeFields(RuntimePrefix, value);
    if (value.tail) |tail| try fields.encode(u16, tail);
}

const WordBytesMapping = struct {
    pub fn toWire(value: u256) [32]u8 {
        var encoded: [32]u8 = undefined;
        std.mem.writeInt(u256, &encoded, value, .big);
        return encoded;
    }

    pub fn fromWire(encoded: [32]u8) u256 {
        return std.mem.readInt(u256, &encoded, .big);
    }
};
const WordBytesRlp = rlp.Mapped(u256, rlp.FixedBytes(32), WordBytesMapping);

fn emitWordBytes(fields: anytype, value: u256) rlp.EncodeError!void {
    try fields.encodeAs(WordBytesRlp, value);
}

fn emitPair(fields: anytype, values: [2]u8) rlp.EncodeError!void {
    for (values) |value| try fields.encode(u8, value);
}

fn emitNested(fields: anytype, values: [2]u8) rlp.EncodeError!void {
    try fields.encode(u8, 9);
    try fields.list(emitPair, values);
}

const UnstableEmission = struct {
    calls: *usize,
};

fn emitUnstable(fields: anytype, value: UnstableEmission) rlp.EncodeError!void {
    value.calls.* += 1;
    if (value.calls.* == 1) try fields.encode(u8, 1);
}

test "raw writer emits canonical byte, integer, and list encodings" {
    var payload_buffer: [16]u8 = undefined;
    var payload = rlp.Writer.fixed(&payload_buffer);
    try payload.bytes("cat");
    try payload.int(u9, 0x100);

    var encoded_buffer: [16]u8 = undefined;
    var encoded = rlp.Writer.fixed(&encoded_buffer);
    try encoded.listPayload(payload.written());
    try std.testing.expectEqualSlices(u8, &.{ 0xc7, 0x83, 'c', 'a', 't', 0x82, 0x01, 0x00 }, encoded.written());

    var cursor = rlp.Cursor.init(encoded.written());
    var fields = try cursor.nextList();
    try cursor.expectDone();
    try std.testing.expectEqualStrings("cat", try fields.nextBytes());
    try std.testing.expectEqual(@as(u9, 0x100), try fields.nextInt(u9));
    try fields.expectDone();
}

test "raw writer rolls fixed output back after capacity failure" {
    var buffer: [1]u8 = undefined;
    var writer = rlp.Writer.fixed(&buffer);
    try std.testing.expectError(error.NoSpaceLeft, writer.bytes("cat"));
    try std.testing.expectEqual(@as(usize, 0), writer.written().len);
}

test "raw writer ownership, reset, remaining, and list prefix stay compatible" {
    var writer = rlp.Writer.alloc(std.testing.allocator);
    defer writer.deinit();
    try std.testing.expectEqual(std.math.maxInt(usize), writer.remaining());
    try writer.bytes("dog");
    writer.reset();
    try std.testing.expectEqual(@as(usize, 0), writer.written().len);
    try writer.bytes("cat");
    const owned = try writer.toOwnedSlice();
    defer std.testing.allocator.free(owned);
    try std.testing.expectEqualSlices(u8, &.{ 0x83, 'c', 'a', 't' }, owned);

    var prefix_buffer: [rlp.max_length_prefix_bytes]u8 = undefined;
    try std.testing.expectEqualSlices(u8, &.{0xc0}, rlp.listPrefix(&prefix_buffer, 0));
    try std.testing.expectEqualSlices(u8, &.{0xf7}, rlp.listPrefix(&prefix_buffer, 55));
    try std.testing.expectEqualSlices(u8, &.{ 0xf8, 0x38 }, rlp.listPrefix(&prefix_buffer, 56));

    var fixed_buffer: [4]u8 = undefined;
    var fixed = rlp.Writer.fixed(&fixed_buffer);
    try std.testing.expectError(error.BorrowedWriter, fixed.toOwnedSlice());
    try std.testing.expectEqual(@as(usize, 4), fixed.remaining());
}

test "value-first list emitter reuses flat struct fields and appends runtime fields" {
    const value: RuntimeFields = .{
        .status = 1,
        .root = .{ 0xaa, 0xbb, 0xcc, 0xdd },
        .tail = 0x1234,
    };
    var out: [16]u8 = undefined;
    const encoded = try rlp.encodeList(emitRuntimeFields, &out, value);

    try std.testing.expectEqual(encoded.len, try rlp.encodedListLen(emitRuntimeFields, value));
    try std.testing.expectEqualSlices(
        u8,
        &.{ 0xc9, 0x01, 0x84, 0xaa, 0xbb, 0xcc, 0xdd, 0x82, 0x12, 0x34 },
        encoded,
    );

    const without_tail = RuntimeFields{ .status = 1, .root = value.root, .tail = null };
    try std.testing.expectEqualSlices(
        u8,
        &.{ 0xc6, 0x01, 0x84, 0xaa, 0xbb, 0xcc, 0xdd },
        try rlp.encodeList(emitRuntimeFields, &out, without_tail),
    );
    try std.testing.expectError(error.BufferTooSmall, rlp.encodeList(emitRuntimeFields, out[0..4], value));
}

test "top-level API infers scalar and struct codecs" {
    var scalar_out: [4]u8 = undefined;
    try std.testing.expectEqualSlices(
        u8,
        &.{ 0x82, 0x12, 0x34 },
        try rlp.encode(u256, &scalar_out, 0x1234),
    );

    var struct_out: [8]u8 = undefined;
    try std.testing.expectEqualSlices(
        u8,
        &.{ 0xc3, 0x82, 0x12, 0x34 },
        try rlp.encode(PlainField, &struct_out, .{ .amount = 0x1234 }),
    );
}

test "host types cover tuple structs, void, pointers, and owned mutable bytes" {
    const Pair = struct { u32, void };
    const Nested = struct {
        prefix: u8,
        pair: Pair,
    };
    const value = Nested{ .prefix = 1, .pair = .{ 42, {} } };

    var out: [16]u8 = undefined;
    const encoded = try rlp.encode(Nested, &out, &value);
    try std.testing.expectEqualSlices(u8, &.{ 0xc4, 0x01, 0xc2, 0x2a, 0x80 }, encoded);
    try std.testing.expectEqualDeep(value, try rlp.decode(Nested, encoded));
    try std.testing.expectEqualSlices(u8, &.{0x80}, try rlp.encode(void, &out, {}));
    _ = try rlp.decode(void, &.{0x80});
    try std.testing.expectError(error.UnexpectedLength, rlp.decode(void, &.{0x01}));

    var mutable = [_]u8{ 0x80, 0x81 };
    const mutable_encoded = try rlp.encode([]u8, &out, mutable[0..]);
    var decoded = try rlp.decodeAlloc([]u8, std.testing.allocator, mutable_encoded);
    defer rlp.deinit([]u8, std.testing.allocator, &decoded);
    try std.testing.expectEqualSlices(u8, &mutable, decoded);
    decoded[0] = 0;
    try std.testing.expectEqual(@as(u8, 0x80), mutable[0]);
}

test "owned mutable bytes enforce allocation budget and clean up failures" {
    var budget = rlp.Budget.init(.{ .max_allocated_bytes = 1 });
    try std.testing.expectError(
        error.DecodeAllocationLimitExceeded,
        rlp.decodeAllocWithBudget([]u8, std.testing.allocator, &.{ 0x82, 0xaa, 0xbb }, &budget),
    );

    const Harness = struct {
        fn run(allocator: std.mem.Allocator) !void {
            var decoded = try rlp.decodeAlloc([]u8, allocator, &.{ 0x82, 0xaa, 0xbb });
            defer rlp.deinit([]u8, allocator, &decoded);
            try std.testing.expectEqualSlices(u8, &.{ 0xaa, 0xbb }, decoded);
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Harness.run, .{});
}

test "value-first list emitter supports explicit wire meaning and nesting" {
    var word_out: [40]u8 = undefined;
    const encoded_word = try rlp.encodeList(emitWordBytes, &word_out, @as(u256, 0x1234));
    var word_root = rlp.Cursor.init(encoded_word);
    var word_fields = try word_root.nextList();
    try word_root.expectDone();
    const encoded = try word_fields.nextBytesExact(32);
    try std.testing.expectEqual(@as(u256, 0x1234), std.mem.readInt(u256, encoded[0..32], .big));
    try word_fields.expectDone();

    var nested_out: [8]u8 = undefined;
    try std.testing.expectEqualSlices(
        u8,
        &.{ 0xc4, 0x09, 0xc2, 0x01, 0x02 },
        try rlp.encodeList(emitNested, &nested_out, @as([2]u8, .{ 1, 2 })),
    );
}

test "value-first encodeListAlloc performs one exact allocation" {
    const value = RuntimeFields{
        .status = 1,
        .root = .{ 0xaa, 0xbb, 0xcc, 0xdd },
        .tail = 0x1234,
    };
    var counted = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const before = counted.alloc_index;
    const encoded = try rlp.encodeListAlloc(emitRuntimeFields, counted.allocator(), value);
    defer counted.allocator().free(encoded);

    try std.testing.expectEqual(before + 1, counted.alloc_index);
    try std.testing.expectEqual(encoded.len, try rlp.encodedListLen(emitRuntimeFields, value));
}

test "value-first emitter rejects a changed second pass" {
    var calls: usize = 0;
    var out: [4]u8 = undefined;
    try std.testing.expectError(
        error.EncodedLengthMismatch,
        rlp.encodeList(emitUnstable, &out, UnstableEmission{ .calls = &calls }),
    );
    try std.testing.expectEqual(@as(usize, 2), calls);
}

test "raw parser preserves exact spans and rejects trailing input" {
    const encoded = [_]u8{ 0xc1, 0x05 };
    const value = try rlp.parseExact(&encoded);
    try std.testing.expectEqual(rlp.Kind.list, value.kind());
    try std.testing.expectEqualSlices(u8, &encoded, value.encoded());
    try std.testing.expectEqualSlices(u8, encoded[1..], value.payload());
    try std.testing.expectError(error.TrailingBytes, rlp.parseExact(&.{ 0x01, 0x02 }));

    var exact = rlp.Cursor.init(&.{ 0x82, 'o', 'k' });
    try std.testing.expectError(error.UnexpectedLength, exact.nextBytesExact(20));
}

test "recursive exact validation finds malformed nested items" {
    var stack: [8]rlp.Cursor = undefined;
    try rlp.validateExact(&.{ 0xc1, 0x01 }, &stack, 2);
    try std.testing.expectError(
        error.NonCanonicalLength,
        rlp.validateExact(&.{ 0xc2, 0xb8, 0x01 }, &stack, 8),
    );
    try std.testing.expectError(
        error.ValidationItemLimitExceeded,
        rlp.validateExact(&.{ 0xc2, 0x01, 0x02 }, &stack, 2),
    );
}

test "recursive exact validation has caller-owned depth scratch" {
    var none: [0]rlp.Cursor = .{};
    try rlp.validateExact(&.{0xc0}, &none, 1);
    try std.testing.expectError(
        error.ValidationDepthExceeded,
        rlp.validateExact(&.{ 0xc1, 0xc0 }, &none, 2),
    );

    var stack: [2]rlp.Cursor = undefined;
    try rlp.validateExact(&.{ 0xc1, 0xc0 }, &stack, 2);
}

test "raw writer embeds a parsed item without another wrapper" {
    const item = try rlp.parseExact(&.{ 0xc1, 0x01 });
    var buffer: [2]u8 = undefined;
    var writer = rlp.Writer.fixed(&buffer);
    try writer.raw(item);
    try std.testing.expectEqualSlices(u8, item.encoded(), writer.written());
}

test "typed struct encodes nested lists directly into caller storage" {
    const changes = [_]Change{
        .{ .index = 1, .value = 0x42 },
        .{ .index = 2, .value = 0x100 },
    };
    const account = Account{
        .address = [_]u8{0x11} ** 20,
        .nonce = 7,
        .changes = &changes,
    };

    var out: [128]u8 = undefined;
    const encoded = try rlp.encode(Account, &out, &account);
    try std.testing.expectEqual(try rlp.encodedLen(Account, account), encoded.len);

    var decoded = try rlp.decodeAlloc(Account, std.testing.allocator, encoded);
    defer rlp.deinit(Account, std.testing.allocator, &decoded);
    try std.testing.expectEqualDeep(account, decoded);
}

test "typed codec appends directly to raw writer and rolls back capacity failure" {
    var output: [8]u8 = undefined;
    var writer = rlp.Writer.fixed(&output);
    try writer.bytes("x");
    try rlp.encodeToWriter(u16, &writer, 1024);
    try std.testing.expectEqualSlices(u8, &.{ 0x78, 0x82, 0x04, 0x00 }, writer.written());

    var too_small_buffer: [1]u8 = undefined;
    var too_small = rlp.Writer.fixed(&too_small_buffer);
    try std.testing.expectError(error.NoSpaceLeft, rlp.encodeToWriter(u16, &too_small, 1024));
    try std.testing.expectEqual(@as(usize, 0), too_small.written().len);
}

test "typed list view decodes without materializing" {
    const changes = [_]Change{
        .{ .index = 1, .value = 0x42 },
        .{ .index = 2, .value = 0x100 },
    };
    var out: [64]u8 = undefined;
    const encoded = try rlp.encode([]const Change, &out, &changes);

    var budget = rlp.Budget.init(.{ .max_depth = 2, .max_items = 7 });
    var root = rlp.Decoder.init(encoded, &budget);
    var view = try Changes.viewFrom(&root);
    try root.expectDone();

    try std.testing.expectEqualDeep(changes[0], (try view.next()).?);
    try std.testing.expectEqualDeep(changes[1], (try view.next()).?);
    try std.testing.expect((try view.next()) == null);
    try view.expectDone();
    try std.testing.expectEqual(@as(usize, 7), budget.visited_items);
}

test "typed raw codec preserves an embedded item's bytes" {
    const embedded = try rlp.parseExact(&.{ 0xc1, 0x01 });
    const RawList = rlp.BoundedListOf(rlp.Raw, 1);
    const values = [_]rlp.Item{embedded};
    var out: [8]u8 = undefined;
    const encoded = try rlp.encodeAs(RawList, &out, &values);
    try std.testing.expectEqualSlices(u8, &.{ 0xc2, 0xc1, 0x01 }, encoded);
}

test "typed raw codec recursively validates canonicality and budgets" {
    const valid = [_]u8{ 0xc2, 0xc1, 0x01 };
    var decoded = try rlp.decodeAllocAs(rlp.Raw, std.testing.allocator, &valid);
    defer rlp.deinitAs(rlp.Raw, std.testing.allocator, &decoded);
    try std.testing.expectEqualSlices(u8, &valid, decoded.encoded());

    try std.testing.expectError(
        error.NonCanonicalLength,
        rlp.decodeAllocAs(rlp.Raw, std.testing.allocator, &.{ 0xc2, 0xb8, 0x01 }),
    );

    const RawList = rlp.ListOf(rlp.Raw);
    try std.testing.expectError(
        error.NonCanonicalLength,
        rlp.decodeAllocAs(RawList, std.testing.allocator, &.{ 0xc3, 0xc2, 0xb8, 0x01 }),
    );

    var depth_budget = rlp.Budget.init(.{ .max_depth = 1 });
    try std.testing.expectError(
        error.DecodeDepthLimitExceeded,
        rlp.decodeAllocWithBudgetAs(
            rlp.Raw,
            std.testing.allocator,
            &.{ 0xc1, 0xc0 },
            &depth_budget,
        ),
    );

    var item_budget = rlp.Budget.init(.{ .max_items = 2 });
    try std.testing.expectError(
        error.DecodeItemLimitExceeded,
        rlp.decodeAllocWithBudgetAs(
            rlp.Raw,
            std.testing.allocator,
            &.{ 0xc2, 0x01, 0x02 },
            &item_budget,
        ),
    );

    var allocation_budget = rlp.Budget.init(.{
        .max_depth = 10,
        .max_allocated_bytes = 0,
    });
    try std.testing.expectError(
        error.DecodeAllocationLimitExceeded,
        rlp.decodeAllocWithBudgetAs(
            rlp.Raw,
            std.testing.allocator,
            &deeply_nested_raw,
            &allocation_budget,
        ),
    );
}

test "typed raw codec frees adaptive validation scratch" {
    const Harness = struct {
        fn run(allocator: std.mem.Allocator) !void {
            var decoded = try rlp.decodeAllocAs(rlp.Raw, allocator, &deeply_nested_raw);
            defer rlp.deinitAs(rlp.Raw, allocator, &decoded);
            try std.testing.expectEqualSlices(u8, &deeply_nested_raw, decoded.encoded());
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Harness.run, .{});
}

test "mapped codec keeps application projection outside wire structs" {
    const value = RenamedAmount{ .amount = 1024 };
    var out: [8]u8 = undefined;
    const encoded = try rlp.encode(RenamedAmount, &out, &value);
    try std.testing.expectEqualSlices(u8, &.{ 0xc3, 0x82, 0x04, 0x00 }, encoded);
    try std.testing.expectEqualDeep(value, try rlp.decode(RenamedAmount, encoded));
}

test "typed structs and arrays require exact field counts" {
    try std.testing.expectError(error.InputTooShort, rlp.decode(Change, &.{ 0xc1, 0x01 }));
    try std.testing.expectError(error.TrailingBytes, rlp.decode(Change, &.{ 0xc3, 0x01, 0x02, 0x03 }));

    try std.testing.expectEqualDeep([_]u16{ 1, 256 }, try rlp.decode([2]u16, &.{ 0xc4, 0x01, 0x82, 0x01, 0x00 }));
    try std.testing.expectError(error.InputTooShort, rlp.decode([2]u16, &.{ 0xc1, 0x01 }));
}

test "application bounded list is distinct from runtime budget" {
    const values = [_]Change{
        .{ .index = 1, .value = 1 },
        .{ .index = 2, .value = 2 },
        .{ .index = 3, .value = 3 },
    };
    var out: [32]u8 = undefined;
    try std.testing.expectError(error.ListLimitExceeded, rlp.encodeAs(SmallChanges, &out, &values));

    const encoded = try rlp.encode([]const Change, &out, &values);
    var budget = rlp.Budget.unlimited();
    var root = rlp.Decoder.init(encoded, &budget);
    var view = try SmallChanges.viewFrom(&root);
    _ = try view.next();
    _ = try view.next();
    try std.testing.expectError(error.ListLimitExceeded, view.next());
}

test "decode budget limits depth and visited items" {
    const values = [_]Change{.{ .index = 1, .value = 1 }};
    var out: [16]u8 = undefined;
    const encoded = try rlp.encode([]const Change, &out, &values);

    var depth_budget = rlp.Budget.init(.{ .max_depth = 1 });
    try std.testing.expectError(
        error.DecodeDepthLimitExceeded,
        rlp.decodeAllocWithBudget([]const Change, std.testing.allocator, encoded, &depth_budget),
    );

    var item_budget = rlp.Budget.init(.{ .max_items = 1 });
    try std.testing.expectError(
        error.DecodeItemLimitExceeded,
        rlp.decodeAllocWithBudget([]const Change, std.testing.allocator, encoded, &item_budget),
    );
}

test "decode budget limits materialized aggregate bytes" {
    const values = [_]Change{
        .{ .index = 1, .value = 1 },
        .{ .index = 2, .value = 2 },
    };
    var out: [32]u8 = undefined;
    const encoded = try rlp.encode([]const Change, &out, &values);

    var budget = rlp.Budget.init(.{
        .max_allocated_bytes = @sizeOf(Change) * values.len - 1,
    });
    try std.testing.expectError(
        error.DecodeAllocationLimitExceeded,
        rlp.decodeAllocWithBudget([]const Change, std.testing.allocator, encoded, &budget),
    );
}

test "integer and boolean codecs enforce Ethereum minimal integers" {
    try std.testing.expectEqual(@as(u64, 0), try rlp.decode(u64, &.{0x80}));
    try std.testing.expectError(error.NonCanonicalInteger, rlp.decode(u64, &.{0x00}));
    try std.testing.expectError(error.NonCanonicalInteger, rlp.decode(u64, &.{ 0x82, 0x00, 0x01 }));
    try std.testing.expectError(error.ExpectedBytes, rlp.decode(u256, &.{0xc0}));
    try std.testing.expectError(error.IntTooLarge, rlp.decode(u8, &.{ 0x82, 0x01, 0xff }));
    try std.testing.expectEqual(false, try rlp.decode(bool, &.{0x80}));
    try std.testing.expectEqual(true, try rlp.decode(bool, &.{0x01}));
    try std.testing.expectError(error.IntTooLarge, rlp.decode(bool, &.{0x02}));
}

test "optional fixed bytes distinguish empty from exact-width values" {
    const OptionalAddress = rlp.OptionalFixedBytes(2);
    var out: [3]u8 = undefined;

    const absent = try rlp.encodeAs(OptionalAddress, &out, null);
    try std.testing.expectEqualSlices(u8, &.{0x80}, absent);
    try std.testing.expectEqual(null, try rlp.decodeAs(OptionalAddress, absent));

    const address = [2]u8{ 0x00, 0x01 };
    const present = try rlp.encodeAs(OptionalAddress, &out, address);
    try std.testing.expectEqualSlices(u8, &.{ 0x82, 0x00, 0x01 }, present);
    try std.testing.expectEqual(address, (try rlp.decodeAs(OptionalAddress, present)).?);

    try std.testing.expectError(error.UnexpectedLength, rlp.decodeAs(OptionalAddress, &.{0x01}));
    try std.testing.expectError(error.ExpectedBytes, rlp.decodeAs(OptionalAddress, &.{0xc0}));
}

test "typed byte codecs cover the canonical 55 and 56 byte boundary" {
    const short = [_]u8{0xaa} ** 55;
    const long = [_]u8{0xbb} ** 56;
    var out: [58]u8 = undefined;

    const short_encoded = try rlp.encode([]const u8, &out, &short);
    try std.testing.expectEqual(@as(u8, 0xb7), short_encoded[0]);
    try std.testing.expectEqual(@as(usize, 56), short_encoded.len);

    const long_encoded = try rlp.encode([]const u8, &out, &long);
    try std.testing.expectEqualSlices(u8, &.{ 0xb8, 0x38 }, long_encoded[0..2]);
    try std.testing.expectEqual(@as(usize, 58), long_encoded.len);

    try std.testing.expectError(error.ExpectedBytes, rlp.decode([]const u8, &.{0xc0}));
    try std.testing.expectError(error.UnexpectedLength, rlp.decode([32]u8, &.{0x80}));
}

test "curated nested struct and homogeneous sequence vectors" {
    const Inner = struct {
        toggle: bool,
        number: u256,
        sequence: [0]bool,
    };
    const Outer = struct {
        toggle: bool,
        number: u256,
        sequence: [1]Inner,
    };
    const outer = Outer{
        .toggle = true,
        .number = 255,
        .sequence = .{.{ .toggle = false, .number = 0, .sequence = .{} }},
    };

    var out: [16]u8 = undefined;
    const encoded = try rlp.encode(Outer, &out, &outer);
    try std.testing.expectEqualSlices(
        u8,
        &.{ 0xc8, 0x01, 0x81, 0xff, 0xc4, 0xc3, 0x80, 0x80, 0xc0 },
        encoded,
    );
    try std.testing.expectEqualDeep(outer, try rlp.decode(Outer, encoded));

    const WithSequence = struct { items: []const u16 };
    var sequence = try rlp.decodeAlloc(
        WithSequence,
        std.testing.allocator,
        &.{ 0xc6, 0xc5, 0x01, 0x02, 0x03, 0x04, 0x05 },
    );
    defer rlp.deinit(WithSequence, std.testing.allocator, &sequence);
    try std.testing.expectEqualSlices(u16, &.{ 1, 2, 3, 4, 5 }, sequence.items);

    const FixedList = rlp.ListOf(rlp.FixedBytes(1));
    try std.testing.expectError(
        error.UnexpectedLength,
        rlp.decodeAllocAs(FixedList, std.testing.allocator, &.{ 0xc1, 0x80 }),
    );
}

test "large byte strings use a minimal long-length prefix" {
    const payload_len = 1 << 20;
    const payload = try std.testing.allocator.alloc(u8, payload_len);
    defer std.testing.allocator.free(payload);
    @memset(payload, 0x83);

    const encoded = try rlp.encodeAlloc([]const u8, std.testing.allocator, payload);
    defer std.testing.allocator.free(encoded);

    try std.testing.expectEqual(payload_len + 4, encoded.len);
    try std.testing.expectEqualSlices(u8, &.{ 0xba, 0x10, 0x00, 0x00 }, encoded[0..4]);
    try std.testing.expectEqualSlices(u8, payload, try rlp.decode([]const u8, encoded));
}

test "all typed allocation failure positions clean up" {
    const Harness = struct {
        fn run(allocator: std.mem.Allocator) !void {
            const values = [_]Change{
                .{ .index = 1, .value = 1 },
                .{ .index = 2, .value = 2 },
            };
            var out: [32]u8 = undefined;
            const encoded = try rlp.encode([]const Change, &out, &values);
            var decoded = try rlp.decodeAlloc([]const Change, allocator, encoded);
            defer rlp.deinit([]const Change, allocator, &decoded);
            try std.testing.expectEqualDeep(values[0], decoded[0]);
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Harness.run, .{});
}

test "all nested typed allocation failure positions clean up" {
    const Harness = struct {
        fn run(allocator: std.mem.Allocator) !void {
            const changes = [_]Change{
                .{ .index = 1, .value = 1 },
                .{ .index = 2, .value = 2 },
            };
            const account = Account{
                .address = [_]u8{0x11} ** 20,
                .nonce = 7,
                .changes = &changes,
            };
            var out: [128]u8 = undefined;
            const encoded = try rlp.encode(Account, &out, &account);
            var decoded = try rlp.decodeAlloc(Account, allocator, encoded);
            defer rlp.deinit(Account, allocator, &decoded);
            try std.testing.expectEqualDeep(account, decoded);
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Harness.run, .{});
}

test "vendored raw RLP valid vectors encode and decode" {
    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        @embedFile("fixtures/rlptest.json"),
        .{ .parse_numbers = false },
    );
    defer parsed.deinit();

    var fixtures = switch (parsed.value) {
        .object => |object| object,
        else => return error.MalformedFixture,
    };
    var iterator = fixtures.iterator();
    var cases: usize = 0;
    while (iterator.next()) |entry| {
        const fixture = switch (entry.value_ptr.*) {
            .object => |object| object,
            else => return error.MalformedFixture,
        };
        const input = fixture.get("in") orelse return error.MalformedFixture;
        const expected_hex = fixture.get("out") orelse return error.MalformedFixture;
        const expected = try parseHexAlloc(std.testing.allocator, try jsonString(expected_hex));
        defer std.testing.allocator.free(expected);

        var writer = rlp.Writer.alloc(std.testing.allocator);
        defer writer.deinit();
        try encodeFixtureValue(std.testing.allocator, &writer, input);
        try std.testing.expectEqualSlices(u8, expected, writer.written());

        var stack: [64]rlp.Cursor = undefined;
        try rlp.validateExact(expected, &stack, expected.len + 1);
        try expectFixtureValue(input, try rlp.parseExact(expected));
        cases += 1;
    }
    try std.testing.expectEqual(@as(usize, 28), cases);
}

test "vendored malformed RLP vectors are rejected recursively" {
    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        @embedFile("fixtures/invalidRLPTest.json"),
        .{ .parse_numbers = false },
    );
    defer parsed.deinit();

    var fixtures = switch (parsed.value) {
        .object => |object| object,
        else => return error.MalformedFixture,
    };
    var iterator = fixtures.iterator();
    var cases: usize = 0;
    while (iterator.next()) |entry| {
        const fixture = switch (entry.value_ptr.*) {
            .object => |object| object,
            else => return error.MalformedFixture,
        };
        const output = fixture.get("out") orelse return error.MalformedFixture;
        const encoded = try parseHexAlloc(std.testing.allocator, try jsonString(output));
        defer std.testing.allocator.free(encoded);
        var stack: [64]rlp.Cursor = undefined;
        if (rlp.validateExact(encoded, &stack, encoded.len + 1)) |_| {
            std.debug.print("invalid RLP fixture accepted: {s}\n", .{entry.key_ptr.*});
            return error.ExpectedInvalidRlp;
        } else |_| {}
        cases += 1;
    }
    try std.testing.expectEqual(@as(usize, 26), cases);
}

fn encodeFixtureValue(
    allocator: std.mem.Allocator,
    writer: *rlp.Writer,
    value: std.json.Value,
) !void {
    switch (value) {
        .string => |string| {
            if (std.mem.startsWith(u8, string, "#")) {
                var bytes: [512]u8 = undefined;
                try writer.bytes(try decimalBytes(string[1..], &bytes));
            } else {
                try writer.bytes(string);
            }
        },
        .number_string => |number| {
            var bytes: [512]u8 = undefined;
            try writer.bytes(try decimalBytes(number, &bytes));
        },
        .array => |array| {
            var payload = rlp.Writer.alloc(allocator);
            defer payload.deinit();
            for (array.items) |child| try encodeFixtureValue(allocator, &payload, child);
            try writer.listPayload(payload.written());
        },
        else => return error.MalformedFixture,
    }
}

fn expectFixtureValue(expected: std.json.Value, actual: rlp.Item) !void {
    switch (expected) {
        .string => |string| {
            if (std.mem.startsWith(u8, string, "#")) {
                var bytes: [512]u8 = undefined;
                try std.testing.expectEqualSlices(u8, try decimalBytes(string[1..], &bytes), try actual.asBytes());
            } else {
                try std.testing.expectEqualStrings(string, try actual.asBytes());
            }
        },
        .number_string => |number| {
            var bytes: [512]u8 = undefined;
            try std.testing.expectEqualSlices(u8, try decimalBytes(number, &bytes), try actual.asBytes());
        },
        .array => |array| {
            var children = try actual.listCursor();
            for (array.items) |child| try expectFixtureValue(child, try children.next());
            try children.expectDone();
        },
        else => return error.MalformedFixture,
    }
}

fn jsonString(value: std.json.Value) ![]const u8 {
    return switch (value) {
        .string => |string| string,
        else => error.MalformedFixture,
    };
}

fn parseHexAlloc(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    const hex = if (std.mem.startsWith(u8, value, "0x") or std.mem.startsWith(u8, value, "0X"))
        value[2..]
    else
        value;
    if (hex.len % 2 != 0) return error.MalformedFixture;
    const bytes = try allocator.alloc(u8, hex.len / 2);
    errdefer allocator.free(bytes);
    _ = try std.fmt.hexToBytes(bytes, hex);
    return bytes;
}

fn decimalBytes(decimal: []const u8, buffer: *[512]u8) ![]const u8 {
    if (decimal.len == 0) return error.MalformedFixture;
    buffer[0] = 0;
    var len: usize = 1;

    for (decimal) |character| {
        if (character < '0' or character > '9') return error.MalformedFixture;
        var carry: u16 = character - '0';
        for (buffer[0..len]) |*byte| {
            const value = @as(u16, byte.*) * 10 + carry;
            byte.* = @truncate(value);
            carry = value >> 8;
        }
        while (carry != 0) {
            if (len == buffer.len) return error.MalformedFixture;
            buffer[len] = @truncate(carry);
            carry >>= 8;
            len += 1;
        }
    }

    if (len == 1 and buffer[0] == 0) return buffer[0..0];
    std.mem.reverse(u8, buffer[0..len]);
    return buffer[0..len];
}
