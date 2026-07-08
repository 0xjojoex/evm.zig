//! RLP (Recursive Length Prefix) encoding and decoding.

const std = @import("std");

pub const Error = error{
    ExpectedBytes,
    ExpectedList,
    InputTooShort,
    IntTooLarge,
    LengthOverflow,
    NonCanonicalInteger,
    NonCanonicalLength,
    NonCanonicalSingleByte,
    TrailingBytes,
    UnexpectedLength,
};

pub const Item = union(enum) {
    bytes: Span,
    list: Span,

    pub const Span = struct {
        encoded: []const u8,
        payload: []const u8,
    };

    pub fn kind(self: Item) Kind {
        return std.meta.activeTag(self);
    }

    pub fn encoded(self: Item) []const u8 {
        return switch (self) {
            .bytes => |span| span.encoded,
            .list => |span| span.encoded,
        };
    }

    pub fn payload(self: Item) []const u8 {
        return switch (self) {
            .bytes => |span| span.payload,
            .list => |span| span.payload,
        };
    }

    pub fn asBytes(self: Item) Error![]const u8 {
        return switch (self) {
            .bytes => |span| span.payload,
            .list => error.ExpectedBytes,
        };
    }

    pub fn asBytesExact(self: Item, len: usize) Error![]const u8 {
        const bytes = try self.asBytes();
        if (bytes.len != len) return error.UnexpectedLength;
        return bytes;
    }

    pub fn asInt(self: Item, comptime T: type) Error!T {
        const bytes = try self.asBytes();
        if (bytes.len == 0) return 0;
        if (bytes[0] == 0) return error.NonCanonicalInteger;
        if (bytes.len > @sizeOf(T)) return error.IntTooLarge;

        var value: u256 = 0;
        for (bytes) |byte| {
            value = (value << 8) | @as(u256, byte);
        }
        return std.math.cast(T, value) orelse error.IntTooLarge;
    }

    pub fn listCursor(self: Item) Error!Cursor {
        return switch (self) {
            .bytes => error.ExpectedList,
            .list => |span| Cursor.init(span.payload),
        };
    }
};

pub const Kind = std.meta.Tag(Item);

pub const Cursor = struct {
    input: []const u8,
    offset: usize = 0,

    pub fn init(input: []const u8) Cursor {
        return .{ .input = input };
    }

    pub fn isDone(self: Cursor) bool {
        return self.offset == self.input.len;
    }

    pub fn expectDone(self: Cursor) Error!void {
        if (!self.isDone()) return error.TrailingBytes;
    }

    pub fn nextList(self: *Cursor) Error!Cursor {
        return (try self.next()).listCursor();
    }

    pub fn nextBytes(self: *Cursor) Error![]const u8 {
        return (try self.next()).asBytes();
    }

    pub fn nextBytesExact(self: *Cursor, len: usize) Error![]const u8 {
        return (try self.next()).asBytesExact(len);
    }

    pub fn nextInt(self: *Cursor, comptime T: type) Error!T {
        return (try self.next()).asInt(T);
    }

    pub fn next(self: *Cursor) Error!Item {
        if (self.offset >= self.input.len) return error.InputTooShort;

        const start = self.offset;
        const prefix = self.input[self.offset];
        self.offset += 1;

        if (prefix < 0x80) {
            return item(.bytes, self.input[start..self.offset], self.input[start..self.offset]);
        }

        if (prefix <= 0xb7) {
            const len: usize = prefix - 0x80;
            const end = try checkedEnd(self.offset, len, self.input.len);
            const payload = self.input[self.offset..end];
            if (len == 1 and payload[0] < 0x80) return error.NonCanonicalSingleByte;
            self.offset = end;
            return item(.bytes, self.input[start..end], payload);
        }

        if (prefix <= 0xbf) {
            const len_of_len: usize = prefix - 0xb7;
            const payload_len = try readLongLength(self.input, self.offset, len_of_len);
            if (payload_len < 56) return error.NonCanonicalLength;
            self.offset = try checkedEnd(self.offset, len_of_len, self.input.len);
            const end = try checkedEnd(self.offset, payload_len, self.input.len);
            const payload = self.input[self.offset..end];
            self.offset = end;
            return item(.bytes, self.input[start..end], payload);
        }

        if (prefix <= 0xf7) {
            const len: usize = prefix - 0xc0;
            const end = try checkedEnd(self.offset, len, self.input.len);
            const payload = self.input[self.offset..end];
            self.offset = end;
            return item(.list, self.input[start..end], payload);
        }

        const len_of_len: usize = prefix - 0xf7;
        const payload_len = try readLongLength(self.input, self.offset, len_of_len);
        if (payload_len < 56) return error.NonCanonicalLength;
        self.offset = try checkedEnd(self.offset, len_of_len, self.input.len);
        const end = try checkedEnd(self.offset, payload_len, self.input.len);
        const payload = self.input[self.offset..end];
        self.offset = end;
        return item(.list, self.input[start..end], payload);
    }
};

fn item(kind: Kind, encoded: []const u8, payload: []const u8) Item {
    const span: Item.Span = .{ .encoded = encoded, .payload = payload };
    return switch (kind) {
        .bytes => .{ .bytes = span },
        .list => .{ .list = span },
    };
}

fn readLongLength(input: []const u8, offset: usize, len_of_len: usize) Error!usize {
    const end = try checkedEnd(offset, len_of_len, input.len);
    const bytes = input[offset..end];
    if (bytes.len == 0 or bytes[0] == 0) return error.NonCanonicalLength;
    if (bytes.len > @sizeOf(usize)) return error.LengthOverflow;

    var value: usize = 0;
    for (bytes) |byte| {
        value = (value << 8) | byte;
    }
    return value;
}

fn checkedEnd(offset: usize, len: usize, limit: usize) Error!usize {
    const end = std.math.add(usize, offset, len) catch return error.LengthOverflow;
    if (end > limit) return error.InputTooShort;
    return end;
}

test "RLP cursor reads nested canonical values" {
    const encoded = [_]u8{ 0xc8, 0x01, 0x80, 0x83, 'c', 'a', 't', 0xc1, 0x02 };
    var cursor = Cursor.init(&encoded);
    var list = try cursor.nextList();
    try cursor.expectDone();

    try std.testing.expectEqual(@as(u8, 1), try list.nextInt(u8));
    try std.testing.expectEqual(@as(u8, 0), try list.nextInt(u8));
    try std.testing.expectEqualStrings("cat", try list.nextBytes());
    var inner = try list.nextList();
    try std.testing.expectEqual(@as(u8, 2), try inner.nextInt(u8));
    try inner.expectDone();
    try list.expectDone();
}

test "RLP items carry their tag and raw spans" {
    const encoded = [_]u8{ 0xc1, 0x05 };
    var cursor = Cursor.init(&encoded);
    const item_value = try cursor.next();

    try std.testing.expectEqual(Kind.list, item_value.kind());
    try std.testing.expectEqualSlices(u8, &encoded, item_value.encoded());
    try std.testing.expectEqualSlices(u8, encoded[1..], item_value.payload());
    try std.testing.expectError(error.ExpectedBytes, item_value.asBytes());
}

test "RLP exact byte reads reject length mismatches distinctly" {
    var cursor = Cursor.init(&[_]u8{ 0x82, 'o', 'k' });
    try std.testing.expectError(error.UnexpectedLength, cursor.nextBytesExact(20));
}

test "RLP cursor rejects non-canonical byte encodings" {
    var single = Cursor.init(&[_]u8{ 0x81, 0x00 });
    try std.testing.expectError(error.NonCanonicalSingleByte, single.next());

    var short = Cursor.init(&[_]u8{ 0xb8, 0x01, 0x00 });
    try std.testing.expectError(error.NonCanonicalLength, short.next());

    var leading = Cursor.init(&[_]u8{ 0xb9, 0x00, 0x38 } ++ [_]u8{0} ** 56);
    try std.testing.expectError(error.NonCanonicalLength, leading.next());
}

test "RLP integers reject zero and leading-zero payloads" {
    var zero_cursor = Cursor.init(&[_]u8{0x80});
    try std.testing.expectEqual(@as(u64, 0), try (try zero_cursor.next()).asInt(u64));

    var scalar_zero = Cursor.init(&[_]u8{0x00});
    try std.testing.expectError(error.NonCanonicalInteger, (try scalar_zero.next()).asInt(u64));

    var leading = Cursor.init(&[_]u8{ 0x82, 0x00, 0x01 });
    try std.testing.expectError(error.NonCanonicalInteger, (try leading.next()).asInt(u64));
}
