//! Value-first encoding for RLP lists whose field sequence is selected at runtime.

const std = @import("std");
const codec = @import("codec.zig");

const Allocator = std.mem.Allocator;

/// First-pass sink. The emitter calls the same methods used by `ListEncoder`.
const ListSizer = struct {
    payload_len: usize = 0,

    pub fn encode(self: *ListSizer, comptime T: type, value: T) codec.EncodeError!void {
        try self.encodeAs(codec.Field(T), value);
    }

    pub fn encodeAs(
        self: *ListSizer,
        comptime Codec: type,
        value: Codec.Value,
    ) codec.EncodeError!void {
        comptime codec.assertCodec(Codec);
        self.payload_len = std.math.add(usize, self.payload_len, try Codec.encodedLen(value)) catch
            return error.EncodedLengthOverflow;
    }

    /// Append a struct codec's fields without adding a nested list prefix.
    pub fn encodeFields(self: *ListSizer, comptime T: type, value: anytype) codec.EncodeError!void {
        const StructCodec = codec.Field(T);
        comptime codec.assertFieldsCodec(StructCodec);
        self.payload_len = std.math.add(
            usize,
            self.payload_len,
            try StructCodec.fieldsEncodedLen(value),
        ) catch return error.EncodedLengthOverflow;
    }

    pub fn list(
        self: *ListSizer,
        comptime emit: anytype,
        value: anytype,
    ) codec.EncodeError!void {
        var nested = ListSizer{};
        try emit(&nested, value);
        self.payload_len = std.math.add(
            usize,
            self.payload_len,
            try codec.listEncodedLen(nested.payload_len),
        ) catch return error.EncodedLengthOverflow;
    }
};

/// Second-pass sink writing values directly into the caller's final buffer.
const ListEncoder = struct {
    encoder: *codec.Encoder,

    pub fn encode(self: *ListEncoder, comptime T: type, value: T) codec.EncodeError!void {
        try self.encodeAs(codec.Field(T), value);
    }

    pub fn encodeAs(
        self: *ListEncoder,
        comptime Codec: type,
        value: Codec.Value,
    ) codec.EncodeError!void {
        comptime codec.assertCodec(Codec);
        try Codec.encodeTo(self.encoder, value);
    }

    /// Append a struct codec's fields without adding a nested list prefix.
    pub fn encodeFields(self: *ListEncoder, comptime T: type, value: anytype) codec.EncodeError!void {
        const StructCodec = codec.Field(T);
        comptime codec.assertFieldsCodec(StructCodec);
        try StructCodec.encodeFieldsTo(self.encoder, value);
    }

    pub fn list(
        self: *ListEncoder,
        comptime emit: anytype,
        value: anytype,
    ) codec.EncodeError!void {
        var nested_size = ListSizer{};
        try emit(&nested_size, value);
        const expected = try codec.listEncodedLen(nested_size.payload_len);
        const start = self.encoder.written().len;

        try self.encoder.listPrefix(nested_size.payload_len);
        var nested = ListEncoder{ .encoder = self.encoder };
        try emit(&nested, value);
        if (self.encoder.written().len - start != expected) {
            return error.EncodedLengthMismatch;
        }
    }
};

/// Return the exact encoded size of one emitted RLP list.
///
/// `emit` is evaluated again during encoding and must be deterministic and
/// side-effect-free.
pub fn encodedListLen(comptime emit: anytype, value: anytype) codec.EncodeError!usize {
    const payload_len = try measurePayload(emit, value);
    return codec.listEncodedLen(payload_len);
}

/// Encode one runtime-shaped list into caller-provided storage.
pub fn encodeList(
    comptime emit: anytype,
    out: []u8,
    value: anytype,
) codec.EncodeError![]const u8 {
    const payload_len = try measurePayload(emit, value);
    const encoded_len = try codec.listEncodedLen(payload_len);
    const Input = EncodeInput(@TypeOf(value));
    return codec.encodeExact(
        ListEncoding(emit, Input).encodeTo,
        out,
        Input{ .value = value, .payload_len = payload_len },
        encoded_len,
    );
}

/// Encode one runtime-shaped list with exactly one final allocation.
pub fn encodeListAlloc(
    comptime emit: anytype,
    allocator: Allocator,
    value: anytype,
) (codec.EncodeError || Allocator.Error)![]u8 {
    const payload_len = try measurePayload(emit, value);
    const encoded_len = try codec.listEncodedLen(payload_len);
    const Input = EncodeInput(@TypeOf(value));
    return codec.encodeExactAlloc(
        ListEncoding(emit, Input).encodeTo,
        allocator,
        Input{ .value = value, .payload_len = payload_len },
        encoded_len,
    );
}

fn measurePayload(comptime emit: anytype, value: anytype) codec.EncodeError!usize {
    var sizer = ListSizer{};
    try emit(&sizer, value);
    return sizer.payload_len;
}

fn EncodeInput(comptime Value: type) type {
    return struct {
        value: Value,
        payload_len: usize,
    };
}

fn ListEncoding(comptime emit: anytype, comptime Input: type) type {
    return struct {
        fn encodeTo(encoder: *codec.Encoder, input: Input) codec.EncodeError!void {
            try encoder.listPrefix(input.payload_len);
            var fields = ListEncoder{ .encoder = encoder };
            try emit(&fields, input.value);
        }
    };
}
