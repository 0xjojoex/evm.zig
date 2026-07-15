//! Composable typed RLP codecs.

const std = @import("std");
const raw = @import("raw.zig");
const decoding = @import("decoder.zig");
const encoding = @import("encoding.zig");

const Allocator = std.mem.Allocator;

pub const EncodeError = encoding.Error || error{
    BufferTooSmall,
    EncodedLengthMismatch,
    ListLimitExceeded,
};

pub const DecodeError = decoding.Error || error{ListLimitExceeded};

pub const Encoder = struct {
    out: []u8,
    offset: usize = 0,

    pub fn init(out: []u8) Encoder {
        return .{ .out = out };
    }

    pub fn written(self: Encoder) []const u8 {
        return self.out[0..self.offset];
    }

    pub fn appendByte(self: *Encoder, byte: u8) EncodeError!void {
        if (self.offset == self.out.len) return error.BufferTooSmall;
        self.out[self.offset] = byte;
        self.offset += 1;
    }

    pub fn appendSlice(self: *Encoder, value: []const u8) EncodeError!void {
        const end = std.math.add(usize, self.offset, value.len) catch
            return error.EncodedLengthOverflow;
        if (end > self.out.len) return error.BufferTooSmall;
        @memcpy(self.out[self.offset..end], value);
        self.offset = end;
    }

    pub fn bytes(self: *Encoder, value: []const u8) EncodeError!void {
        try encoding.writeBytes(self, value);
    }

    pub fn uint(self: *Encoder, comptime T: type, value: T) EncodeError!void {
        try encoding.writeInt(self, T, value);
    }

    pub fn listPrefix(self: *Encoder, payload_len: usize) EncodeError!void {
        try encoding.writeLengthPrefix(self, 0xc0, 0xf7, payload_len);
    }
};

/// Return the canonical encoded length for one host value.
pub fn encodedLen(comptime T: type, value: anytype) EncodeError!usize {
    return encodedLenAs(hostCodec(T), normalizeValue(T, value));
}

/// Return the encoded length for one explicitly coded value.
pub fn encodedLenAs(comptime Codec: type, value: Codec.Value) EncodeError!usize {
    comptime assertCodec(Codec);
    return Codec.encodedLen(value);
}

/// Encode one host value using its inferred or type-owned RLP meaning.
pub fn encode(
    comptime T: type,
    out: []u8,
    value: anytype,
) EncodeError![]const u8 {
    return encodeAs(hostCodec(T), out, normalizeValue(T, value));
}

/// Encode one value through an explicit codec.
pub fn encodeAs(
    comptime Codec: type,
    out: []u8,
    value: Codec.Value,
) EncodeError![]const u8 {
    comptime assertCodec(Codec);
    const expected = try Codec.encodedLen(value);
    return encodeExact(Codec.encodeTo, out, value, expected);
}

pub fn encodeExact(
    comptime encodeTo: anytype,
    out: []u8,
    value: anytype,
    expected: usize,
) EncodeError![]const u8 {
    if (out.len < expected) return error.BufferTooSmall;

    var encoder = Encoder.init(out[0..expected]);
    try encodeTo(&encoder, value);
    if (encoder.offset != expected) return error.EncodedLengthMismatch;
    return encoder.written();
}

pub fn encodeExactAlloc(
    comptime encodeTo: anytype,
    allocator: Allocator,
    value: anytype,
    expected: usize,
) (EncodeError || Allocator.Error)![]u8 {
    const out = try allocator.alloc(u8, expected);
    errdefer allocator.free(out);
    _ = try encodeExact(encodeTo, out, value, expected);
    return out;
}

/// Encode one host value with exactly one final allocation.
pub fn encodeAlloc(
    comptime T: type,
    allocator: Allocator,
    value: anytype,
) (EncodeError || Allocator.Error)![]u8 {
    return encodeAllocAs(hostCodec(T), allocator, normalizeValue(T, value));
}

/// Encode one value through an explicit codec with one final allocation.
pub fn encodeAllocAs(
    comptime Codec: type,
    allocator: Allocator,
    value: Codec.Value,
) (EncodeError || Allocator.Error)![]u8 {
    comptime assertCodec(Codec);
    const len = try Codec.encodedLen(value);
    return encodeExactAlloc(Codec.encodeTo, allocator, value, len);
}

/// Append one host value directly to an allocating or fixed raw writer.
pub fn encodeToWriter(
    comptime T: type,
    writer: *raw.Writer,
    value: anytype,
) (EncodeError || raw.Writer.Error)!void {
    return encodeToWriterAs(hostCodec(T), writer, normalizeValue(T, value));
}

/// Append one explicitly coded value to an allocating or fixed raw writer.
pub fn encodeToWriterAs(
    comptime Codec: type,
    writer: *raw.Writer,
    value: Codec.Value,
) (EncodeError || raw.Writer.Error)!void {
    comptime assertCodec(Codec);
    const len = try Codec.encodedLen(value);
    const start = writer.written().len;
    const destination = try writer.reserve(len);
    errdefer writer.truncateTo(start);
    _ = try encodeExact(Codec.encodeTo, destination, value, len);
}

/// Decode one nonallocating host value using its inferred or attached codec.
pub fn decode(comptime T: type, bytes: []const u8) DecodeError!T {
    return decodeAs(hostCodec(T), bytes);
}

/// Decode one nonallocating value through an explicit codec.
pub fn decodeAs(comptime Codec: type, bytes: []const u8) DecodeError!Codec.Value {
    var budget = decoding.Budget.unlimited();
    return decodeWithBudgetAs(Codec, bytes, &budget);
}

pub fn decodeWithBudget(
    comptime T: type,
    bytes: []const u8,
    budget: *decoding.Budget,
) DecodeError!T {
    return decodeWithBudgetAs(hostCodec(T), bytes, budget);
}

pub fn decodeWithBudgetAs(
    comptime Codec: type,
    bytes: []const u8,
    budget: *decoding.Budget,
) DecodeError!Codec.Value {
    comptime {
        assertCodec(Codec);
        if (Codec.requires_allocator) {
            @compileError("allocating RLP codec requires decodeAlloc");
        }
    }

    var decoder = decoding.Decoder.init(bytes, budget);
    const value = try Codec.decodeFrom(&decoder);
    try decoder.expectDone();
    return value;
}

pub fn decodeAlloc(
    comptime T: type,
    allocator: Allocator,
    bytes: []const u8,
) (DecodeError || Allocator.Error)!T {
    return decodeAllocAs(hostCodec(T), allocator, bytes);
}

pub fn decodeAllocAs(
    comptime Codec: type,
    allocator: Allocator,
    bytes: []const u8,
) (DecodeError || Allocator.Error)!Codec.Value {
    var budget = decoding.Budget.unlimited();
    return decodeAllocWithBudgetAs(Codec, allocator, bytes, &budget);
}

pub fn decodeAllocWithBudget(
    comptime T: type,
    allocator: Allocator,
    bytes: []const u8,
    budget: *decoding.Budget,
) (DecodeError || Allocator.Error)!T {
    return decodeAllocWithBudgetAs(hostCodec(T), allocator, bytes, budget);
}

pub fn decodeAllocWithBudgetAs(
    comptime Codec: type,
    allocator: Allocator,
    bytes: []const u8,
    budget: *decoding.Budget,
) (DecodeError || Allocator.Error)!Codec.Value {
    comptime assertCodec(Codec);
    var decoder = decoding.Decoder.init(bytes, budget);
    var value = try decodeValue(Codec, allocator, &decoder);
    errdefer deinitValue(Codec, allocator, &value);
    try decoder.expectDone();
    return value;
}

pub fn deinit(comptime T: type, allocator: Allocator, value: *T) void {
    deinitAs(hostCodec(T), allocator, value);
}

pub fn deinitAs(comptime Codec: type, allocator: Allocator, value: *Codec.Value) void {
    comptime assertCodec(Codec);
    deinitValue(Codec, allocator, value);
}

const Bytes = struct {
    pub const Value = []const u8;
    pub const requires_allocator = false;

    pub fn encodedLen(value: Value) EncodeError!usize {
        return bytesEncodedLen(value);
    }

    pub fn encodeTo(encoder: *Encoder, value: Value) EncodeError!void {
        try encoder.bytes(value);
    }

    pub fn decodeFrom(decoder: *decoding.Decoder) DecodeError!Value {
        return decoder.nextBytes();
    }
};

/// Caller-owned mutable bytes. Encoding borrows the slice; decoding copies it.
const OwnedBytes = struct {
    pub const Value = []u8;
    pub const requires_allocator = true;

    pub fn encodedLen(value: Value) EncodeError!usize {
        return bytesEncodedLen(value);
    }

    pub fn encodeTo(encoder: *Encoder, value: Value) EncodeError!void {
        try encoder.bytes(value);
    }

    pub fn decodeAllocFrom(
        allocator: Allocator,
        decoder: *decoding.Decoder,
    ) (DecodeError || Allocator.Error)!Value {
        const borrowed = try decoder.nextBytes();
        try decoder.budget.ensureAllocation(borrowed.len);
        const owned = try allocator.dupe(u8, borrowed);
        decoder.budget.commitAllocation(borrowed.len);
        return owned;
    }

    pub fn deinit(allocator: Allocator, value: *Value) void {
        allocator.free(value.*);
        value.* = undefined;
    }
};

/// `void` is the empty RLP byte string. It never means an omitted field.
const EmptyBytes = struct {
    pub const Value = void;
    pub const requires_allocator = false;

    pub fn encodedLen(_: void) EncodeError!usize {
        return 1;
    }

    pub fn encodeTo(encoder: *Encoder, _: void) EncodeError!void {
        try encoder.bytes("");
    }

    pub fn decodeFrom(decoder: *decoding.Decoder) DecodeError!void {
        if ((try decoder.nextBytes()).len != 0) return error.UnexpectedLength;
    }
};

pub fn FixedBytes(comptime len: usize) type {
    return struct {
        pub const Value = [len]u8;
        pub const requires_allocator = false;

        pub fn encodedLen(value: Value) EncodeError!usize {
            return bytesEncodedLen(&value);
        }

        pub fn encodeTo(encoder: *Encoder, value: Value) EncodeError!void {
            try encoder.bytes(&value);
        }

        pub fn decodeFrom(decoder: *decoding.Decoder) DecodeError!Value {
            const value = try decoder.nextBytesExact(len);
            return value[0..len].*;
        }
    };
}

fn Uint(comptime T: type) type {
    comptime encoding.assertUnsignedInt(T);
    return struct {
        pub const Value = T;
        pub const requires_allocator = false;

        pub fn encodedLen(value: T) EncodeError!usize {
            if (value == 0) return 1;
            const encoded = encoding.intBytes(T, value);
            var first: usize = 0;
            while (encoded[first] == 0) : (first += 1) {}
            return bytesEncodedLen(encoded[first..]);
        }

        pub fn encodeTo(encoder: *Encoder, value: T) EncodeError!void {
            try encoder.uint(T, value);
        }

        pub fn decodeFrom(decoder: *decoding.Decoder) DecodeError!T {
            return decoder.nextInt(T);
        }
    };
}

/// Ethereum's common boolean convention: false is integer zero, true is one.
const Bool = struct {
    pub const Value = bool;
    pub const requires_allocator = false;

    pub fn encodedLen(_: bool) EncodeError!usize {
        return 1;
    }

    pub fn encodeTo(encoder: *Encoder, value: bool) EncodeError!void {
        try encoder.uint(u1, @intFromBool(value));
    }

    pub fn decodeFrom(decoder: *decoding.Decoder) DecodeError!bool {
        return (try decoder.nextInt(u1)) == 1;
    }
};

/// One exact item, preserving its encoded span after recursive validation.
pub const Raw = struct {
    pub const Value = raw.Item;
    pub const requires_allocator = true;

    pub fn encodedLen(value: Value) EncodeError!usize {
        return value.encoded().len;
    }

    pub fn encodeTo(encoder: *Encoder, value: Value) EncodeError!void {
        try encoder.appendSlice(value.encoded());
    }

    pub fn decodeAllocFrom(
        allocator: Allocator,
        decoder: *decoding.Decoder,
    ) (DecodeError || Allocator.Error)!Value {
        const value = try decoder.next();
        if (value.kind() == .list) try validateRawList(allocator, decoder, value);
        return value;
    }

    pub fn deinit(_: Allocator, _: *Value) void {}

    const inline_depth = 8;

    fn validateRawList(
        allocator: Allocator,
        decoder: *decoding.Decoder,
        value: Value,
    ) (DecodeError || Allocator.Error)!void {
        const root_depth = std.math.add(usize, decoder.depth, 1) catch
            return error.DecodeDepthLimitExceeded;
        if (root_depth > decoder.budget.limits.max_depth) {
            return error.DecodeDepthLimitExceeded;
        }

        const remaining_depth = decoder.budget.limits.max_depth - root_depth;
        const max_stack_len = @min(remaining_depth, value.encoded().len);
        const remaining_items = decoder.budget.limits.max_items - decoder.budget.visited_items;
        const validation_items = remaining_items + 1;

        var inline_stack: [inline_depth]raw.Cursor = undefined;
        var stack_len: usize = @min(max_stack_len, inline_stack.len);
        while (true) {
            const stats = raw.validateExactCounted(
                value.encoded(),
                inline_stack[0..stack_len],
                validation_items,
            ) catch |err| switch (err) {
                error.ValidationDepthExceeded => {
                    if (stack_len == max_stack_len) return error.DecodeDepthLimitExceeded;
                    break;
                },
                error.ValidationItemLimitExceeded => return error.DecodeItemLimitExceeded,
                else => |parse_error| return parse_error,
            };
            try decoder.budget.commitItems(stats.items - 1);
            return;
        }

        while (stack_len < max_stack_len) {
            const doubled = std.math.mul(usize, stack_len, 2) catch max_stack_len;
            stack_len = @min(max_stack_len, @max(doubled, 1));
            const stack_bytes = std.math.mul(usize, @sizeOf(raw.Cursor), stack_len) catch
                return error.DecodeAllocationLimitExceeded;
            try decoder.budget.ensureAllocation(stack_bytes);
            const stack = try allocator.alloc(raw.Cursor, stack_len);
            defer allocator.free(stack);

            const stats = raw.validateExactCounted(
                value.encoded(),
                stack,
                validation_items,
            ) catch |err| switch (err) {
                error.ValidationDepthExceeded => {
                    if (stack_len == max_stack_len) return error.DecodeDepthLimitExceeded;
                    continue;
                },
                error.ValidationItemLimitExceeded => return error.DecodeItemLimitExceeded,
                else => |parse_error| return parse_error,
            };
            try decoder.budget.commitItems(stats.items - 1);
            return;
        }
        unreachable;
    }
};

pub fn Struct(comptime T: type, comptime overrides: anytype) type {
    comptime validateStruct(T, overrides);
    const needs_allocator = structRequiresAllocator(T, overrides);

    const Common = struct {
        pub const Value = T;

        pub fn encodedLen(value: T) EncodeError!usize {
            return listEncodedLen(try fieldsEncodedLen(value));
        }

        pub fn encodeTo(encoder: *Encoder, value: T) EncodeError!void {
            try encoder.listPrefix(try fieldsEncodedLen(value));
            try encodeFieldsTo(encoder, value);
        }

        pub fn fieldsEncodedLen(value: anytype) EncodeError!usize {
            return structFieldsEncodedLen(T, overrides, value);
        }

        pub fn encodeFieldsTo(encoder: *Encoder, value: anytype) EncodeError!void {
            try encodeStructFields(T, overrides, encoder, value);
        }

        pub fn decodeFrom(decoder: *decoding.Decoder) DecodeError!T {
            var fields = try decoder.nextList();
            var value: T = undefined;
            inline for (@typeInfo(T).@"struct".fields) |field| {
                const FieldCodec = fieldCodec(overrides, field.name, field.type);
                if (FieldCodec.requires_allocator) unreachable;
                @field(value, field.name) = try FieldCodec.decodeFrom(&fields);
            }
            try fields.expectDone();
            return value;
        }

        pub fn decodeAllocFrom(
            allocator: Allocator,
            decoder: *decoding.Decoder,
        ) (DecodeError || Allocator.Error)!T {
            var fields = try decoder.nextList();
            var value: T = undefined;
            try decodeStructFields(T, overrides, allocator, &fields, &value, 0);
            errdefer deinitStruct(T, overrides, allocator, &value);
            try fields.expectDone();
            return value;
        }

        pub fn deinitValue(allocator: Allocator, value: *T) void {
            deinitStruct(T, overrides, allocator, value);
        }
    };

    if (needs_allocator) {
        return struct {
            pub const Value = Common.Value;
            pub const requires_allocator = true;
            pub const encodedLen = Common.encodedLen;
            pub const encodeTo = Common.encodeTo;
            pub const fieldsEncodedLen = Common.fieldsEncodedLen;
            pub const encodeFieldsTo = Common.encodeFieldsTo;
            pub const decodeAllocFrom = Common.decodeAllocFrom;
            pub const deinit = Common.deinitValue;
        };
    }
    return struct {
        pub const Value = Common.Value;
        pub const requires_allocator = false;
        pub const encodedLen = Common.encodedLen;
        pub const encodeTo = Common.encodeTo;
        pub const fieldsEncodedLen = Common.fieldsEncodedLen;
        pub const encodeFieldsTo = Common.encodeFieldsTo;
        pub const decodeFrom = Common.decodeFrom;
    };
}

pub fn ArrayOf(comptime ElementCodec: type, comptime len: usize) type {
    comptime assertCodec(ElementCodec);
    const needs_allocator = ElementCodec.requires_allocator;

    const Common = struct {
        pub const Value = [len]ElementCodec.Value;

        pub fn encodedLen(values: Value) EncodeError!usize {
            return listEncodedLen(try sequencePayloadLen(ElementCodec, values));
        }

        pub fn encodeTo(encoder: *Encoder, values: Value) EncodeError!void {
            const payload_len = try sequencePayloadLen(ElementCodec, values);
            try encoder.listPrefix(payload_len);
            try encodeSequencePayload(ElementCodec, encoder, values);
        }

        pub fn decodeFrom(decoder: *decoding.Decoder) DecodeError!Value {
            var fields = try decoder.nextList();
            var values: Value = undefined;
            inline for (0..len) |index| {
                values[index] = try ElementCodec.decodeFrom(&fields);
            }
            try fields.expectDone();
            return values;
        }

        pub fn decodeAllocFrom(
            allocator: Allocator,
            decoder: *decoding.Decoder,
        ) (DecodeError || Allocator.Error)!Value {
            var fields = try decoder.nextList();
            var values: Value = undefined;
            try decodeArrayElements(ElementCodec, len, allocator, &fields, &values, 0);
            errdefer deinitArray(ElementCodec, len, allocator, &values);
            try fields.expectDone();
            return values;
        }

        pub fn deinitValue(allocator: Allocator, values: *Value) void {
            deinitArray(ElementCodec, len, allocator, values);
        }
    };

    if (needs_allocator) {
        return struct {
            pub const Value = Common.Value;
            pub const requires_allocator = true;
            pub const encodedLen = Common.encodedLen;
            pub const encodeTo = Common.encodeTo;
            pub const decodeAllocFrom = Common.decodeAllocFrom;
            pub const deinit = Common.deinitValue;
        };
    }
    return struct {
        pub const Value = Common.Value;
        pub const requires_allocator = false;
        pub const encodedLen = Common.encodedLen;
        pub const encodeTo = Common.encodeTo;
        pub const decodeFrom = Common.decodeFrom;
    };
}

pub fn ListOf(comptime ElementCodec: type) type {
    return ListCodec(ElementCodec, null);
}

/// Application-level element bound. The bound is not part of RLP canonicality.
pub fn BoundedListOf(comptime ElementCodec: type, comptime max_items: usize) type {
    return ListCodec(ElementCodec, max_items);
}

/// Infallible host/wire projection. When `WireCodec` allocates, `Mapping` must
/// also expose `deinit(allocator, *Host)` for the transferred ownership.
pub fn Mapped(comptime Host: type, comptime WireCodec: type, comptime Mapping: type) type {
    comptime {
        assertCodec(WireCodec);
        if (!@hasDecl(Mapping, "toWire") or !@hasDecl(Mapping, "fromWire")) {
            @compileError("RLP Mapped requires Mapping.toWire and Mapping.fromWire");
        }
        if (WireCodec.requires_allocator and !@hasDecl(Mapping, "deinit")) {
            @compileError("allocating RLP Mapped requires Mapping.deinit");
        }
    }

    const Common = struct {
        pub const Value = Host;

        pub fn encodedLen(value: Host) EncodeError!usize {
            return WireCodec.encodedLen(Mapping.toWire(value));
        }

        pub fn encodeTo(encoder: *Encoder, value: Host) EncodeError!void {
            try WireCodec.encodeTo(encoder, Mapping.toWire(value));
        }

        pub fn decodeFrom(decoder: *decoding.Decoder) DecodeError!Host {
            return Mapping.fromWire(try WireCodec.decodeFrom(decoder));
        }

        pub fn decodeAllocFrom(
            allocator: Allocator,
            decoder: *decoding.Decoder,
        ) (DecodeError || Allocator.Error)!Host {
            return Mapping.fromWire(try WireCodec.decodeAllocFrom(allocator, decoder));
        }

        pub fn deinitValue(allocator: Allocator, value: *Host) void {
            Mapping.deinit(allocator, value);
        }
    };

    if (WireCodec.requires_allocator) {
        return struct {
            pub const Value = Common.Value;
            pub const requires_allocator = true;
            pub const encodedLen = Common.encodedLen;
            pub const encodeTo = Common.encodeTo;
            pub const decodeAllocFrom = Common.decodeAllocFrom;
            pub const deinit = Common.deinitValue;
        };
    }
    return struct {
        pub const Value = Common.Value;
        pub const requires_allocator = false;
        pub const encodedLen = Common.encodedLen;
        pub const encodeTo = Common.encodeTo;
        pub const decodeFrom = Common.decodeFrom;
    };
}

fn ListCodec(comptime ElementCodec: type, comptime max_items: ?usize) type {
    comptime assertCodec(ElementCodec);
    return struct {
        pub const Value = []const ElementCodec.Value;
        pub const requires_allocator = true;

        pub const View = struct {
            decoder: decoding.Decoder,
            seen: usize = 0,

            pub fn next(self: *View) DecodeError!?ElementCodec.Value {
                comptime if (ElementCodec.requires_allocator) {
                    @compileError("allocation-free list view requires a nonallocating element codec");
                };
                if (self.decoder.isDone()) return null;
                const next_seen = std.math.add(usize, self.seen, 1) catch
                    return error.DecodeItemLimitExceeded;
                try checkCount(next_seen);
                const value = try ElementCodec.decodeFrom(&self.decoder);
                self.seen = next_seen;
                return value;
            }

            pub fn expectDone(self: View) DecodeError!void {
                return self.decoder.expectDone();
            }
        };

        pub fn encodedLen(values: Value) EncodeError!usize {
            try checkCount(values.len);
            return listEncodedLen(try sequencePayloadLen(ElementCodec, values));
        }

        pub fn encodeTo(encoder: *Encoder, values: Value) EncodeError!void {
            try checkCount(values.len);
            const payload_len = try sequencePayloadLen(ElementCodec, values);
            try encoder.listPrefix(payload_len);
            try encodeSequencePayload(ElementCodec, encoder, values);
        }

        pub fn viewFrom(decoder: *decoding.Decoder) DecodeError!View {
            return .{ .decoder = try decoder.nextList() };
        }

        pub fn decodeAllocFrom(
            allocator: Allocator,
            decoder: *decoding.Decoder,
        ) (DecodeError || Allocator.Error)!Value {
            var fields = try decoder.nextList();
            var scan = fields.cursor;
            var count: usize = 0;
            while (!scan.isDone()) {
                _ = try scan.next();
                count = std.math.add(usize, count, 1) catch
                    return error.DecodeItemLimitExceeded;
                try checkCount(count);
                try fields.budget.ensureItems(count);
            }

            const allocation_bytes = std.math.mul(usize, @sizeOf(ElementCodec.Value), count) catch
                return error.DecodeAllocationLimitExceeded;
            try fields.budget.ensureAllocation(allocation_bytes);
            const values = try allocator.alloc(ElementCodec.Value, count);
            fields.budget.commitAllocation(allocation_bytes);

            var initialized: usize = 0;
            errdefer {
                for (values[0..initialized]) |*value| deinitValue(ElementCodec, allocator, value);
                allocator.free(values);
            }

            while (!fields.isDone()) : (initialized += 1) {
                values[initialized] = try decodeValue(ElementCodec, allocator, &fields);
            }
            std.debug.assert(initialized == count);
            return values;
        }

        pub fn deinit(allocator: Allocator, values: *Value) void {
            for (@constCast(values.*)) |*value| deinitValue(ElementCodec, allocator, value);
            allocator.free(values.*);
            values.* = &.{};
        }

        fn checkCount(count: usize) error{ListLimitExceeded}!void {
            if (max_items) |limit| {
                if (count > limit) return error.ListLimitExceeded;
            }
        }
    };
}

fn codecFor(comptime T: type) type {
    if (hasRlpDecl(T)) return T.Rlp;
    return switch (@typeInfo(T)) {
        .void => EmptyBytes,
        .bool => Bool,
        .int => |info| if (info.signedness == .unsigned)
            Uint(T)
        else
            @compileError("RLP does not infer signed integer codecs"),
        .array => |array| if (array.child == u8)
            FixedBytes(array.len)
        else
            ArrayOf(codecFor(array.child), array.len),
        .pointer => |pointer| if (pointer.size == .slice)
            if (pointer.child == u8)
                if (pointer.is_const) Bytes else OwnedBytes
            else if (pointer.is_const)
                ListOf(codecFor(pointer.child))
            else
                @compileError("RLP infers non-byte lists only from const slices")
        else
            @compileError("RLP pointer types need an explicit codec"),
        .@"struct" => |info| if (info.layout == .auto)
            Struct(T, .{})
        else
            @compileError("packed and extern structs need an explicit RLP mapping"),
        else => @compileError("RLP type needs an explicit codec"),
    };
}

/// Select the reusable codec for one RLP field value.
pub fn Field(comptime T: type) type {
    return codecFor(T);
}

fn hostCodec(comptime T: type) type {
    const Codec = codecFor(T);
    comptime assertCodec(Codec);
    if (Codec.Value != T) {
        @compileError("RLP type-owned codec Value must match its host type");
    }
    return Codec;
}

fn normalizeValue(comptime T: type, value: anytype) T {
    const Value = @TypeOf(value);
    if (Value == T) return value;
    switch (@typeInfo(Value)) {
        .pointer => |pointer| {
            if (pointer.size == .one and pointer.child == T) return value.*;
        },
        else => {},
    }
    if (@typeInfo(T) == .@"struct" and @typeInfo(Value) == .@"struct") {
        var normalized: T = undefined;
        inline for (@typeInfo(T).@"struct".fields) |field| {
            @field(normalized, field.name) = @field(value, field.name);
        }
        return normalized;
    }
    return value;
}

fn fieldCodec(
    comptime overrides: anytype,
    comptime name: []const u8,
    comptime FieldType: type,
) type {
    if (@hasField(@TypeOf(overrides), name)) return @field(overrides, name);
    return Field(FieldType);
}

fn hasRlpDecl(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .@"struct", .@"union", .@"enum", .@"opaque" => @hasDecl(T, "Rlp"),
        else => false,
    };
}

pub fn assertCodec(comptime Codec: type) void {
    inline for (.{ "Value", "requires_allocator", "encodedLen", "encodeTo" }) |decl| {
        if (!@hasDecl(Codec, decl)) @compileError("RLP codec is missing " ++ decl);
    }
    if (Codec.requires_allocator) {
        if (!@hasDecl(Codec, "decodeAllocFrom")) {
            @compileError("allocating RLP codec is missing decodeAllocFrom");
        }
        if (!@hasDecl(Codec, "deinit")) {
            @compileError("allocating RLP codec is missing deinit");
        }
    } else if (!@hasDecl(Codec, "decodeFrom")) {
        @compileError("nonallocating RLP codec is missing decodeFrom");
    }
}

pub fn assertFieldsCodec(comptime Codec: type) void {
    assertCodec(Codec);
    inline for (.{ "fieldsEncodedLen", "encodeFieldsTo" }) |decl| {
        if (!@hasDecl(Codec, decl)) @compileError("RLP codec does not expose struct fields: " ++ decl);
    }
}

fn validateStruct(comptime T: type, comptime overrides: anytype) void {
    const info = switch (@typeInfo(T)) {
        .@"struct" => |value| value,
        else => @compileError("RLP Struct requires a Zig struct"),
    };
    inline for (@typeInfo(@TypeOf(overrides)).@"struct".fields) |override| {
        if (!@hasField(T, override.name)) {
            @compileError("unknown RLP Struct override: " ++ override.name);
        }
        if (override.type != type) @compileError("RLP Struct overrides must be codec types");
    }

    inline for (info.fields) |field| {
        const FieldCodec = fieldCodec(overrides, field.name, field.type);
        assertCodec(FieldCodec);
        if (FieldCodec.Value != field.type) {
            @compileError("RLP field codec Value mismatch: " ++ field.name);
        }
    }
}

fn structRequiresAllocator(comptime T: type, comptime overrides: anytype) bool {
    inline for (@typeInfo(T).@"struct".fields) |field| {
        if (fieldCodec(overrides, field.name, field.type).requires_allocator) return true;
    }
    return false;
}

fn structFieldsEncodedLen(comptime T: type, comptime overrides: anytype, value: anytype) EncodeError!usize {
    comptime validateStructSource(T, @TypeOf(value));
    var payload_len: usize = 0;
    inline for (@typeInfo(T).@"struct".fields) |field| {
        const FieldCodec = fieldCodec(overrides, field.name, field.type);
        const field_value = switch (@typeInfo(@TypeOf(value))) {
            .pointer => @field(value.*, field.name),
            else => @field(value, field.name),
        };
        payload_len = try checkedAdd(payload_len, try FieldCodec.encodedLen(field_value));
    }
    return payload_len;
}

fn encodeStructFields(
    comptime T: type,
    comptime overrides: anytype,
    encoder: *Encoder,
    value: anytype,
) EncodeError!void {
    comptime validateStructSource(T, @TypeOf(value));
    inline for (@typeInfo(T).@"struct".fields) |field| {
        const FieldCodec = fieldCodec(overrides, field.name, field.type);
        const field_value = switch (@typeInfo(@TypeOf(value))) {
            .pointer => @field(value.*, field.name),
            else => @field(value, field.name),
        };
        try FieldCodec.encodeTo(encoder, field_value);
    }
}

fn validateStructSource(comptime T: type, comptime Source: type) void {
    const SourceStruct = switch (@typeInfo(Source)) {
        .pointer => |pointer| if (pointer.size == .one)
            pointer.child
        else
            @compileError("RLP struct field source pointer must point to one value"),
        else => Source,
    };
    const source_info = switch (@typeInfo(SourceStruct)) {
        .@"struct" => |info| info,
        else => @compileError("RLP struct fields require a struct value or pointer"),
    };

    inline for (@typeInfo(T).@"struct".fields) |field| {
        const source_field = comptime blk: {
            for (source_info.fields) |candidate| {
                if (std.mem.eql(u8, field.name, candidate.name)) break :blk candidate;
            }
            @compileError("RLP struct field source is missing: " ++ field.name);
        };
        if (source_field.type != field.type) {
            @compileError("RLP struct field source type mismatch: " ++ field.name);
        }
    }
}

fn decodeStructFields(
    comptime T: type,
    comptime overrides: anytype,
    allocator: Allocator,
    decoder: *decoding.Decoder,
    value: *T,
    comptime index: usize,
) (DecodeError || Allocator.Error)!void {
    const fields = @typeInfo(T).@"struct".fields;
    if (index == fields.len) return;

    const field = fields[index];
    const FieldCodec = fieldCodec(overrides, field.name, field.type);
    @field(value, field.name) = try decodeValue(FieldCodec, allocator, decoder);
    errdefer deinitValue(FieldCodec, allocator, &@field(value, field.name));
    try decodeStructFields(T, overrides, allocator, decoder, value, index + 1);
}

fn deinitStruct(
    comptime T: type,
    comptime overrides: anytype,
    allocator: Allocator,
    value: *T,
) void {
    inline for (@typeInfo(T).@"struct".fields) |field| {
        const FieldCodec = fieldCodec(overrides, field.name, field.type);
        deinitValue(FieldCodec, allocator, &@field(value, field.name));
    }
}

fn decodeArrayElements(
    comptime ElementCodec: type,
    comptime len: usize,
    allocator: Allocator,
    decoder: *decoding.Decoder,
    values: *[len]ElementCodec.Value,
    comptime index: usize,
) (DecodeError || Allocator.Error)!void {
    if (index == len) return;
    values[index] = try decodeValue(ElementCodec, allocator, decoder);
    errdefer deinitValue(ElementCodec, allocator, &values[index]);
    try decodeArrayElements(ElementCodec, len, allocator, decoder, values, index + 1);
}

fn deinitArray(
    comptime ElementCodec: type,
    comptime len: usize,
    allocator: Allocator,
    values: *[len]ElementCodec.Value,
) void {
    inline for (0..len) |index| deinitValue(ElementCodec, allocator, &values[index]);
}

fn decodeValue(
    comptime Codec: type,
    allocator: Allocator,
    decoder: *decoding.Decoder,
) (DecodeError || Allocator.Error)!Codec.Value {
    return if (Codec.requires_allocator)
        Codec.decodeAllocFrom(allocator, decoder)
    else
        Codec.decodeFrom(decoder);
}

fn deinitValue(comptime Codec: type, allocator: Allocator, value: *Codec.Value) void {
    if (Codec.requires_allocator) Codec.deinit(allocator, value);
}

fn sequencePayloadLen(comptime ElementCodec: type, values: anytype) EncodeError!usize {
    var payload_len: usize = 0;
    for (values) |value| {
        payload_len = try checkedAdd(payload_len, try ElementCodec.encodedLen(value));
    }
    return payload_len;
}

fn encodeSequencePayload(comptime ElementCodec: type, encoder: *Encoder, values: anytype) EncodeError!void {
    for (values) |value| try ElementCodec.encodeTo(encoder, value);
}

fn bytesEncodedLen(value: []const u8) EncodeError!usize {
    if (value.len == 1 and value[0] < 0x80) return 1;
    return checkedAdd(try lengthPrefixLen(value.len), value.len);
}

pub fn listEncodedLen(payload_len: usize) EncodeError!usize {
    return checkedAdd(try lengthPrefixLen(payload_len), payload_len);
}

fn lengthPrefixLen(payload_len: usize) EncodeError!usize {
    if (payload_len < 56) return 1;
    return checkedAdd(1, try encoding.lengthByteCount(payload_len));
}

fn checkedAdd(lhs: usize, rhs: usize) EncodeError!usize {
    return std.math.add(usize, lhs, rhs) catch error.EncodedLengthOverflow;
}
