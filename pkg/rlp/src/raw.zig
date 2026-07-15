//! Strict borrowed RLP parsing and migration-friendly writing primitives.

const std = @import("std");
const encoding = @import("encoding.zig");

const Allocator = std.mem.Allocator;
const ByteList = std.ArrayList(u8);

pub const ParseError = error{
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
pub const ValidationError = ParseError || error{
    ValidationDepthExceeded,
    ValidationItemLimitExceeded,
};
pub const ValidationStats = struct {
    items: usize,
    max_depth: usize,
};
pub const max_length_prefix_bytes = 1 + @sizeOf(usize);

pub const Writer = union(enum) {
    allocating: AllocatingBuffer,
    borrowed: FixedBuffer,

    pub const Error = Allocator.Error || error{NoSpaceLeft};
    pub const OwnedSliceError = Allocator.Error || error{BorrowedWriter};

    pub fn alloc(allocator: Allocator) Writer {
        return .{ .allocating = .{ .allocator = allocator } };
    }

    pub fn fixed(buffer: []u8) Writer {
        return .{ .borrowed = .{ .buffer = buffer } };
    }

    pub fn deinit(self: *Writer) void {
        switch (self.*) {
            .allocating => |*allocating| allocating.out.deinit(allocating.allocator),
            .borrowed => {},
        }
    }

    pub fn written(self: Writer) []const u8 {
        return switch (self) {
            .allocating => |allocating| allocating.out.items,
            .borrowed => |fixed_buffer| fixed_buffer.buffer[0..fixed_buffer.len],
        };
    }

    pub fn toOwnedSlice(self: *Writer) OwnedSliceError![]u8 {
        return switch (self.*) {
            .allocating => |*allocating| try allocating.out.toOwnedSlice(allocating.allocator),
            .borrowed => error.BorrowedWriter,
        };
    }

    pub fn reset(self: *Writer) void {
        switch (self.*) {
            .allocating => |*allocating| allocating.out.clearRetainingCapacity(),
            .borrowed => |*fixed_buffer| fixed_buffer.len = 0,
        }
    }

    pub fn remaining(self: Writer) usize {
        return switch (self) {
            .allocating => std.math.maxInt(usize),
            .borrowed => |fixed_buffer| fixed_buffer.buffer.len - fixed_buffer.len,
        };
    }

    /// Reserve uninitialized output for a package codec.
    pub fn reserve(self: *Writer, count: usize) Writer.Error![]u8 {
        return switch (self.*) {
            .allocating => |*allocating| try allocating.out.addManyAsSlice(allocating.allocator, count),
            .borrowed => |*fixed_buffer| blk: {
                if (count > fixed_buffer.buffer.len - fixed_buffer.len) return error.NoSpaceLeft;
                const start = fixed_buffer.len;
                fixed_buffer.len += count;
                break :blk fixed_buffer.buffer[start..fixed_buffer.len];
            },
        };
    }

    /// Roll back to a previously observed `written().len`.
    pub fn truncateTo(self: *Writer, new_len: usize) void {
        std.debug.assert(new_len <= self.len());
        self.truncate(new_len);
    }

    pub fn bytes(self: *Writer, payload: []const u8) Writer.Error!void {
        const start = self.len();
        appendCanonicalBytes(self, payload) catch |err| {
            self.truncate(start);
            return err;
        };
    }

    pub fn int(self: *Writer, comptime T: type, value: T) Writer.Error!void {
        const start = self.len();
        appendCanonicalInt(self, T, value) catch |err| {
            self.truncate(start);
            return err;
        };
    }

    /// Append a list whose payload is already a joined sequence of RLP items.
    pub fn listPayload(self: *Writer, payload: []const u8) Writer.Error!void {
        const start = self.len();
        appendCanonicalList(self, payload) catch |err| {
            self.truncate(start);
            return err;
        };
    }

    /// Append an item that was already parsed by the strict cursor.
    pub fn raw(self: *Writer, value: Item) Writer.Error!void {
        const start = self.len();
        self.appendSlice(value.encoded()) catch |err| {
            self.truncate(start);
            return err;
        };
    }

    fn len(self: Writer) usize {
        return self.written().len;
    }

    fn truncate(self: *Writer, new_len: usize) void {
        switch (self.*) {
            .allocating => |*allocating| allocating.out.shrinkRetainingCapacity(new_len),
            .borrowed => |*fixed_buffer| fixed_buffer.len = new_len,
        }
    }

    /// Internal sink contract used by the package's canonical encoder.
    pub fn appendByte(self: *Writer, byte: u8) Writer.Error!void {
        switch (self.*) {
            .allocating => |*allocating| try allocating.out.append(allocating.allocator, byte),
            .borrowed => |*fixed_buffer| {
                if (fixed_buffer.len == fixed_buffer.buffer.len) return error.NoSpaceLeft;
                fixed_buffer.buffer[fixed_buffer.len] = byte;
                fixed_buffer.len += 1;
            },
        }
    }

    /// Internal sink contract used by the package's canonical encoder.
    pub fn appendSlice(self: *Writer, bytes_slice: []const u8) Writer.Error!void {
        switch (self.*) {
            .allocating => |*allocating| try allocating.out.appendSlice(allocating.allocator, bytes_slice),
            .borrowed => |*fixed_buffer| {
                const remaining_bytes = fixed_buffer.buffer.len - fixed_buffer.len;
                if (bytes_slice.len > remaining_bytes) return error.NoSpaceLeft;
                @memcpy(fixed_buffer.buffer[fixed_buffer.len..][0..bytes_slice.len], bytes_slice);
                fixed_buffer.len += bytes_slice.len;
            },
        }
    }
};

const AllocatingBuffer = struct {
    allocator: Allocator,
    out: ByteList = .empty,
};

const FixedBuffer = struct {
    buffer: []u8,
    len: usize = 0,
};

fn appendCanonicalBytes(writer: *Writer, payload: []const u8) Writer.Error!void {
    encoding.writeBytes(writer, payload) catch |err| switch (err) {
        error.EncodedLengthOverflow => unreachable,
        else => |writer_error| return writer_error,
    };
}

fn appendCanonicalInt(writer: *Writer, comptime T: type, value: T) Writer.Error!void {
    encoding.writeInt(writer, T, value) catch |err| switch (err) {
        error.EncodedLengthOverflow => unreachable,
        else => |writer_error| return writer_error,
    };
}

fn appendCanonicalList(writer: *Writer, payload: []const u8) Writer.Error!void {
    encoding.writeListPayload(writer, payload) catch |err| switch (err) {
        error.EncodedLengthOverflow => unreachable,
        else => |writer_error| return writer_error,
    };
}

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
            inline else => |span| span.encoded,
        };
    }

    pub fn payload(self: Item) []const u8 {
        return switch (self) {
            inline else => |span| span.payload,
        };
    }

    pub fn asBytes(self: Item) ParseError![]const u8 {
        return switch (self) {
            .bytes => |span| span.payload,
            .list => error.ExpectedBytes,
        };
    }

    pub fn asBytesExact(self: Item, len: usize) ParseError![]const u8 {
        const bytes_value = try self.asBytes();
        if (bytes_value.len != len) return error.UnexpectedLength;
        return bytes_value;
    }

    pub fn asInt(self: Item, comptime T: type) ParseError!T {
        encoding.assertUnsignedInt(T);
        const bytes_value = try self.asBytes();
        if (bytes_value.len == 0) return 0;
        if (bytes_value[0] == 0) return error.NonCanonicalInteger;
        if (bytes_value.len > encoding.byteLen(T)) return error.IntTooLarge;

        var value: u256 = 0;
        for (bytes_value) |byte| value = (value << 8) | @as(u256, byte);
        return std.math.cast(T, value) orelse error.IntTooLarge;
    }

    pub fn listCursor(self: Item) ParseError!Cursor {
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

    pub fn expectDone(self: Cursor) ParseError!void {
        if (!self.isDone()) return error.TrailingBytes;
    }

    pub fn nextList(self: *Cursor) ParseError!Cursor {
        return (try self.next()).listCursor();
    }

    pub fn nextBytes(self: *Cursor) ParseError![]const u8 {
        return (try self.next()).asBytes();
    }

    pub fn nextBytesExact(self: *Cursor, len: usize) ParseError![]const u8 {
        return (try self.next()).asBytesExact(len);
    }

    pub fn nextInt(self: *Cursor, comptime T: type) ParseError!T {
        return (try self.next()).asInt(T);
    }

    pub fn next(self: *Cursor) ParseError!Item {
        if (self.offset >= self.input.len) return error.InputTooShort;

        const start = self.offset;
        const prefix = self.input[self.offset];
        self.offset += 1;

        if (prefix < 0x80) {
            return makeItem(.bytes, self.input[start..self.offset], self.input[start..self.offset]);
        }

        if (prefix <= 0xb7) {
            const len: usize = prefix - 0x80;
            const end = try checkedEnd(self.offset, len, self.input.len);
            const payload = self.input[self.offset..end];
            if (len == 1 and payload[0] < 0x80) return error.NonCanonicalSingleByte;
            self.offset = end;
            return makeItem(.bytes, self.input[start..end], payload);
        }

        if (prefix <= 0xbf) {
            const len_of_len: usize = prefix - 0xb7;
            const payload_len = try readLongLength(self.input, self.offset, len_of_len);
            if (payload_len < 56) return error.NonCanonicalLength;
            self.offset = try checkedEnd(self.offset, len_of_len, self.input.len);
            const end = try checkedEnd(self.offset, payload_len, self.input.len);
            const payload = self.input[self.offset..end];
            self.offset = end;
            return makeItem(.bytes, self.input[start..end], payload);
        }

        if (prefix <= 0xf7) {
            const len: usize = prefix - 0xc0;
            const end = try checkedEnd(self.offset, len, self.input.len);
            const payload = self.input[self.offset..end];
            self.offset = end;
            return makeItem(.list, self.input[start..end], payload);
        }

        const len_of_len: usize = prefix - 0xf7;
        const payload_len = try readLongLength(self.input, self.offset, len_of_len);
        if (payload_len < 56) return error.NonCanonicalLength;
        self.offset = try checkedEnd(self.offset, len_of_len, self.input.len);
        const end = try checkedEnd(self.offset, payload_len, self.input.len);
        const payload = self.input[self.offset..end];
        self.offset = end;
        return makeItem(.list, self.input[start..end], payload);
    }
};

pub fn parseExact(input: []const u8) ParseError!Item {
    var cursor = Cursor.init(input);
    const value = try cursor.next();
    try cursor.expectDone();
    return value;
}

/// Recursively validate one exact RLP item without allocation or host recursion.
/// `list_stack.len` is the maximum accepted nesting depth, excluding the root.
pub fn validateExact(
    input: []const u8,
    list_stack: []Cursor,
    max_items: usize,
) ValidationError!void {
    _ = try validateExactCounted(input, list_stack, max_items);
}

pub fn validateExactCounted(
    input: []const u8,
    list_stack: []Cursor,
    max_items: usize,
) ValidationError!ValidationStats {
    const root = try parseExact(input);
    if (max_items == 0) return error.ValidationItemLimitExceeded;
    if (root.kind() == .bytes) return .{ .items = 1, .max_depth = 0 };

    var current = try root.listCursor();
    var saved_parents: usize = 0;
    var items: usize = 1;
    var max_depth: usize = 0;

    while (true) {
        if (current.isDone()) {
            if (saved_parents == 0) break;
            saved_parents -= 1;
            current = list_stack[saved_parents];
            continue;
        }

        const child = try current.next();
        items = std.math.add(usize, items, 1) catch
            return error.ValidationItemLimitExceeded;
        if (items > max_items) return error.ValidationItemLimitExceeded;

        if (child.kind() == .list) {
            if (saved_parents == list_stack.len) return error.ValidationDepthExceeded;
            list_stack[saved_parents] = current;
            saved_parents += 1;
            max_depth = @max(max_depth, saved_parents);
            current = try child.listCursor();
        }
    }
    return .{ .items = items, .max_depth = max_depth };
}

pub fn listPrefix(buffer: *[max_length_prefix_bytes]u8, payload_len: usize) []const u8 {
    var writer = Writer.fixed(buffer);
    encoding.writeLengthPrefix(&writer, 0xc0, 0xf7, payload_len) catch unreachable;
    return writer.written();
}

fn makeItem(kind: Kind, encoded: []const u8, payload: []const u8) Item {
    const span: Item.Span = .{ .encoded = encoded, .payload = payload };
    return switch (kind) {
        .bytes => .{ .bytes = span },
        .list => .{ .list = span },
    };
}

fn readLongLength(input: []const u8, offset: usize, len_of_len: usize) ParseError!usize {
    const end = try checkedEnd(offset, len_of_len, input.len);
    const bytes_value = input[offset..end];
    if (bytes_value.len == 0 or bytes_value[0] == 0) return error.NonCanonicalLength;
    if (bytes_value.len > @sizeOf(usize)) return error.LengthOverflow;

    var value: usize = 0;
    for (bytes_value) |byte| value = (value << 8) | byte;
    return value;
}

fn checkedEnd(offset: usize, len: usize, limit: usize) ParseError!usize {
    const end = std.math.add(usize, offset, len) catch return error.LengthOverflow;
    if (end > limit) return error.InputTooShort;
    return end;
}
