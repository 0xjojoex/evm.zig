//! RLP (Recursive Length Prefix) encoding and decoding.

const std = @import("std");
const crypto = @import("./crypto.zig");
const t = @import("./t.zig");

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

const Allocator = std.mem.Allocator;
const ByteList = std.ArrayList(u8);
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

    pub fn bytes(self: *Writer, payload: []const u8) Writer.Error!void {
        const start = self.len();
        appendBytesTo(self, payload) catch |err| {
            self.truncate(start);
            return err;
        };
    }

    pub fn int(self: *Writer, comptime T: type, value: T) Writer.Error!void {
        const start = self.len();
        appendIntTo(self, T, value) catch |err| {
            self.truncate(start);
            return err;
        };
    }

    pub fn list(self: *Writer, payload: []const u8) Writer.Error!void {
        const start = self.len();
        appendListTo(self, payload) catch |err| {
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

    fn appendByte(self: *Writer, byte: u8) Writer.Error!void {
        switch (self.*) {
            .allocating => |*allocating| try allocating.out.append(allocating.allocator, byte),
            .borrowed => |*fixed_buffer| {
                if (fixed_buffer.len == fixed_buffer.buffer.len) return error.NoSpaceLeft;
                fixed_buffer.buffer[fixed_buffer.len] = byte;
                fixed_buffer.len += 1;
            },
        }
    }

    fn appendSlice(self: *Writer, bytes_slice: []const u8) Writer.Error!void {
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

pub fn listPrefix(buffer: *[max_length_prefix_bytes]u8, payload_len: usize) []const u8 {
    var writer = Writer.fixed(buffer);
    appendLengthPrefixTo(&writer, 0xc0, 0xf7, payload_len) catch unreachable;
    return writer.written();
}

const AllocatingBuffer = struct {
    allocator: Allocator,
    out: ByteList = .empty,
};

const FixedBuffer = struct {
    buffer: []u8,
    len: usize = 0,
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

fn assertUnsignedInt(comptime T: type) void {
    switch (@typeInfo(T)) {
        .int => |info| {
            if (info.signedness != .unsigned) {
                @compileError("RLP integer encoding requires an unsigned integer type");
            }
            if (info.bits > 256) {
                @compileError("RLP integer encoding supports unsigned integer types up to u256");
            }
        },
        else => @compileError("RLP integer encoding requires an unsigned integer type"),
    }
}

fn appendBytesTo(writer: anytype, payload: []const u8) !void {
    if (payload.len == 1 and payload[0] < 0x80) {
        try writer.appendByte(payload[0]);
        return;
    }

    try appendLengthPrefixTo(writer, 0x80, 0xb7, payload.len);
    try writer.appendSlice(payload);
}

fn appendIntTo(writer: anytype, comptime T: type, value: T) !void {
    assertUnsignedInt(T);

    if (value == 0) {
        try appendBytesTo(writer, &.{});
        return;
    }

    const be = intBytes(T, value);

    var first: usize = 0;
    while (be[first] == 0) : (first += 1) {}
    try appendBytesTo(writer, be[first..]);
}

fn appendListTo(writer: anytype, payload: []const u8) !void {
    try appendLengthPrefixTo(writer, 0xc0, 0xf7, payload.len);
    try writer.appendSlice(payload);
}

// trim leading zeros for odd widths
fn intBytes(comptime T: type, value: T) [byteLen(T)]u8 {
    var bytes: [byteLen(T)]u8 = undefined;
    var remaining: u256 = @intCast(value);
    var i = bytes.len;
    while (i > 0) {
        i -= 1;
        bytes[i] = @truncate(remaining);
        remaining >>= 8;
    }
    return bytes;
}

fn byteLen(comptime T: type) usize {
    const bits = @typeInfo(T).int.bits;
    return (bits + 7) / 8;
}

fn appendLengthPrefixTo(writer: anytype, short_base: u8, long_base: u8, payload_len: usize) !void {
    if (payload_len < 56) {
        try writer.appendByte(short_base + @as(u8, @intCast(payload_len)));
        return;
    }

    var len_be: [@sizeOf(usize)]u8 = undefined;
    std.mem.writeInt(usize, &len_be, payload_len, .big);

    var first: usize = 0;
    while (len_be[first] == 0) : (first += 1) {}
    const len_of_len = len_be.len - first;

    try writer.appendByte(long_base + @as(u8, @intCast(len_of_len)));
    try writer.appendSlice(len_be[first..]);
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

test "RLP encoder emits canonical byte and list encodings" {
    const allocator = std.testing.allocator;
    var out = Writer.alloc(allocator);
    defer out.deinit();

    try out.bytes("");
    try t.expectHex(out.written(), "80");

    out.reset();
    try out.bytes("dog");
    try t.expectHex(out.written(), "83646f67");

    out.reset();
    try out.bytes(&.{0x7f});
    try t.expectHex(out.written(), "7f");

    out.reset();
    try out.bytes(&.{0x80});
    try t.expectHex(out.written(), "8180");

    out.reset();
    var payload = Writer.alloc(allocator);
    defer payload.deinit();
    try payload.bytes("cat");
    try payload.bytes("dog");
    try out.list(payload.written());
    try t.expectHex(out.written(), "c88363617483646f67");
}

test "RLP encoder round-trips through cursor decoder" {
    const allocator = std.testing.allocator;
    var inner_payload = Writer.alloc(allocator);
    defer inner_payload.deinit();
    var encoded = Writer.alloc(allocator);
    defer encoded.deinit();

    var long_bytes = [_]u8{0xab} ** 56;
    long_bytes[55] = 0xcd;

    try inner_payload.int(u64, 0);
    try inner_payload.int(u64, 0x7f);
    try inner_payload.int(u64, 0x80);
    try inner_payload.bytes("cat");
    try inner_payload.bytes(&long_bytes);
    try encoded.list(inner_payload.written());

    var cursor = Cursor.init(encoded.written());
    var list = try cursor.nextList();
    try cursor.expectDone();

    try std.testing.expectEqual(@as(u64, 0), try list.nextInt(u64));
    try std.testing.expectEqual(@as(u64, 0x7f), try list.nextInt(u64));
    try std.testing.expectEqual(@as(u64, 0x80), try list.nextInt(u64));
    try std.testing.expectEqualStrings("cat", try list.nextBytes());
    try std.testing.expectEqualSlices(u8, &long_bytes, try list.nextBytes());
    try list.expectDone();
}

test "RLP encoder handles non-byte-width unsigned integers" {
    const allocator = std.testing.allocator;
    var out = Writer.alloc(allocator);
    defer out.deinit();

    try out.int(u1, 1);
    try out.int(u2, 2);
    try out.int(u9, 0x100);
    try t.expectHex(out.written(), "0102820100");

    var cursor = Cursor.init(out.written());
    try std.testing.expectEqual(@as(u1, 1), try cursor.nextInt(u1));
    try std.testing.expectEqual(@as(u2, 2), try cursor.nextInt(u2));
    try std.testing.expectEqual(@as(u9, 0x100), try cursor.nextInt(u9));
    try cursor.expectDone();
}

test "RLP fixed buffer encoder writes without allocation" {
    var payload_buf: [16]u8 = undefined;
    var payload = Writer.fixed(&payload_buf);
    try payload.bytes("cat");
    try payload.int(u9, 0x100);

    var encoded_buf: [16]u8 = undefined;
    var encoded = Writer.fixed(&encoded_buf);
    try encoded.list(payload.written());
    try t.expectHex(encoded.written(), "c783636174820100");

    var cursor = Cursor.init(encoded.written());
    var list = try cursor.nextList();
    try std.testing.expectEqualStrings("cat", try list.nextBytes());
    try std.testing.expectEqual(@as(u9, 0x100), try list.nextInt(u9));
    try list.expectDone();
    try cursor.expectDone();
}

test "RLP fixed buffer reports capacity failure" {
    var bytes: [1]u8 = undefined;
    var fixed = Writer.fixed(&bytes);

    try std.testing.expectError(error.NoSpaceLeft, fixed.bytes("cat"));
    try std.testing.expectEqual(@as(usize, 0), fixed.written().len);
}

test "RLP list prefix helper encodes short and long lengths" {
    var buffer: [max_length_prefix_bytes]u8 = undefined;

    try std.testing.expectEqualSlices(u8, &[_]u8{0xc0}, listPrefix(&buffer, 0));
    try std.testing.expectEqualSlices(u8, &[_]u8{0xf7}, listPrefix(&buffer, 55));
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0xf8, 0x38 }, listPrefix(&buffer, 56));
}

test "RLP allocating writer can return owned bytes" {
    const allocator = std.testing.allocator;
    var allocating = Writer.alloc(allocator);
    try allocating.bytes("dog");

    const owned = try allocating.toOwnedSlice();
    defer allocator.free(owned);
    try t.expectHex(owned, "83646f67");

    var fixed_buf: [4]u8 = undefined;
    var fixed = Writer.fixed(&fixed_buf);
    try std.testing.expectError(error.BorrowedWriter, fixed.toOwnedSlice());
}

test "RLP encoder reproduces EIP-155 transaction signing hash" {
    const allocator = std.testing.allocator;
    var fields = Writer.alloc(allocator);
    defer fields.deinit();
    var signing_data = Writer.alloc(allocator);
    defer signing_data.deinit();

    const to = [_]u8{0x35} ** 20;
    try fields.int(u64, 9);
    try fields.int(u64, 20_000_000_000);
    try fields.int(u64, 21_000);
    try fields.bytes(&to);
    try fields.int(u64, 1_000_000_000_000_000_000);
    try fields.bytes("");
    try fields.int(u64, 1);
    try fields.int(u64, 0);
    try fields.int(u64, 0);
    try signing_data.list(fields.written());

    try t.expectHex(
        signing_data.written(),
        "ec098504a817c800825208943535353535353535353535353535353535353535880de0b6b3a764000080018080",
    );
    const signing_hash = crypto.keccak256(signing_data.written());
    try t.expectHex(&signing_hash, "daf5a779ae972f972197303d7b574746c7ef83eadac0f2791ad23db92e4c8e53");

    var signed_fields = Writer.alloc(allocator);
    defer signed_fields.deinit();
    var signed_tx = Writer.alloc(allocator);
    defer signed_tx.deinit();

    try signed_fields.int(u64, 9);
    try signed_fields.int(u64, 20_000_000_000);
    try signed_fields.int(u64, 21_000);
    try signed_fields.bytes(&to);
    try signed_fields.int(u64, 1_000_000_000_000_000_000);
    try signed_fields.bytes("");
    try signed_fields.int(u8, 37);
    try signed_fields.bytes(&t.hexBytes("28ef61340bd939bc2195fe537567866003e1a15d3c71ff63e1590620aa636276"));
    try signed_fields.bytes(&t.hexBytes("67cbe9d8997f761aecb703304b3800ccf555c9f3dc64214b297fb1966a3b6d83"));
    try signed_tx.list(signed_fields.written());

    try t.expectHex(
        signed_tx.written(),
        "f86c098504a817c800825208943535353535353535353535353535353535353535880de0b6b3a76400008025a028ef61340bd939bc2195fe537567866003e1a15d3c71ff63e1590620aa636276a067cbe9d8997f761aecb703304b3800ccf555c9f3dc64214b297fb1966a3b6d83",
    );
    const signed_tx_hash = crypto.keccak256(signed_tx.written());
    try t.expectHex(&signed_tx_hash, "33469b22e9f636356c4160a87eb19df52b7412e8eac32a4a55ffe88ea8350788");
}

test "RLP encoder reproduces Ethereum mainnet genesis header hash" {
    const allocator = std.testing.allocator;
    var fields = Writer.alloc(allocator);
    defer fields.deinit();
    var header = Writer.alloc(allocator);
    defer header.deinit();

    const zero_hash = [_]u8{0} ** 32;
    const zero_address = [_]u8{0} ** 20;
    const zero_bloom = [_]u8{0} ** 256;
    const uncles_hash = t.hexBytes("1dcc4de8dec75d7aab85b567b6ccd41ad312451b948a7413f0a142fd40d49347");
    const state_root = t.hexBytes("d7f8974fb5ac78d9ac099b9ad5018bedc2ce0a72dad1827a1709da30580f0544");
    const empty_trie_root = t.hexBytes("56e81f171bcc55a6ff8345e692c0f86e5b48e01b996cadc001622fb5e363b421");
    const extra_data = t.hexBytes("11bbe8db4e347b4e8c937c1c8370e4b5ed33adb3db69cbdb7a38e1e50b1b82fa");
    const nonce = t.hexBytes("0000000000000042");

    try fields.bytes(&zero_hash);
    try fields.bytes(&uncles_hash);
    try fields.bytes(&zero_address);
    try fields.bytes(&state_root);
    try fields.bytes(&empty_trie_root);
    try fields.bytes(&empty_trie_root);
    try fields.bytes(&zero_bloom);
    try fields.int(u64, 17_179_869_184);
    try fields.int(u64, 0);
    try fields.int(u64, 5_000);
    try fields.int(u64, 0);
    try fields.int(u64, 0);
    try fields.bytes(&extra_data);
    try fields.bytes(&zero_hash);
    try fields.bytes(&nonce);
    try header.list(fields.written());

    const header_hash = crypto.keccak256(header.written());
    try t.expectHex(&header_hash, "d4e56740f876aef8c010b86a40d5f56745a118d0906a34e69aec8c0db1cb8fa3");
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
