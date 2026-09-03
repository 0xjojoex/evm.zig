//! 20-byte Ethereum address type, constructors, and hex parsing.

const std = @import("std");
const crypto = @import("crypto.zig");
const rlp = @import("rlp");
const ssz = @import("ssz");

/// A canonical 20-byte Ethereum account address.
///
/// Protocol encoders and cryptographic code must use `bytes` explicitly instead
/// of relying on the in-memory representation. Execution-oriented address forms
/// may then evolve independently without widening every protocol record.
pub const Address = extern struct {
    bytes: [20]u8,

    comptime {
        std.debug.assert(@sizeOf(Address) == 20);
        std.debug.assert(@alignOf(Address) == 1);
    }

    pub const len: usize = 20;

    pub const zero: Address = .{ .bytes = @splat(0) };

    pub const ParseError = error{
        InvalidAddressHexLength,
        InvalidAddressHexCharacter,
    };

    pub inline fn fromBytes(bytes: [len]u8) Address {
        return .{ .bytes = bytes };
    }

    pub inline fn fromU160(value: u160) Address {
        var bytes: [len]u8 = undefined;
        std.mem.writeInt(u160, &bytes, value, .big);
        return fromBytes(bytes);
    }

    pub inline fn toU256(self: Address) u256 {
        return std.mem.readInt(u160, &self.bytes, .big);
    }

    /// Truncates an EVM word to its low 20 bytes.
    pub inline fn fromU256(word: u256) Address {
        return fromU160(@truncate(word));
    }

    pub fn fromHex(hex: []const u8) ParseError!Address {
        const body = if (hasHexPrefix(hex)) hex[2..] else hex;
        if (body.len != 2 * len) return error.InvalidAddressHexLength;

        var bytes: [len]u8 = undefined;
        _ = std.fmt.hexToBytes(&bytes, body) catch return error.InvalidAddressHexCharacter;
        return fromBytes(bytes);
    }

    pub fn fromPublicKey(public_key: [64]u8) Address {
        return fromHash(crypto.keccak256(&public_key));
    }

    pub inline fn asBytes(self: *const Address) *const [len]u8 {
        return &self.bytes;
    }

    pub inline fn eql(a: Address, b: Address) bool {
        return std.mem.eql(u8, &a.bytes, &b.bytes);
    }

    pub inline fn order(a: Address, b: Address) std.math.Order {
        return std.mem.order(u8, &a.bytes, &b.bytes);
    }

    pub fn formatNumber(self: Address, writer: *std.Io.Writer, number: std.fmt.Number) std.Io.Writer.Error!void {
        if (number.mode == .hex and number.precision == null and number.width == null) {
            return writer.printHex(&self.bytes, number.case);
        }
        return writer.printIntAny(self.toU256(), number.mode.base() orelse 10, number.case, .{
            .precision = number.precision,
            .width = number.width,
            .alignment = number.alignment,
            .fill = number.fill,
        });
    }

    pub const HashContext = struct {
        pub inline fn hash(_: HashContext, value: Address) u64 {
            return std.hash.Wyhash.hash(0, &value.bytes);
        }

        pub inline fn eql(_: HashContext, a: Address, b: Address) bool {
            return Address.eql(a, b);
        }
    };

    pub fn HashMap(comptime Value: type) type {
        return std.HashMap(Address, Value, HashContext, std.hash_map.default_max_load_percentage);
    }

    const WireMapping = struct {
        pub fn toWire(value: Address) [len]u8 {
            return value.bytes;
        }

        pub fn fromWire(bytes: [len]u8) Address {
            return Address.fromBytes(bytes);
        }
    };

    pub const Rlp = rlp.Mapped(@This(), rlp.FixedBytes(len), WireMapping);
    pub const Ssz = ssz.Mapped(@This(), ssz.ByteVector(len), WireMapping);

    /// Ergonomic address constructor for unsigned integer literals, small unsigned integers,
    /// address bytes, and comptime-known 40-character hex strings with an optional 0x prefix.
    pub inline fn addr(value: anytype) Address {
        const T = @TypeOf(value);
        if (T == Address) return value;

        return switch (@typeInfo(T)) {
            .comptime_int => {
                if (value < 0) @compileError("addr integer literal must be non-negative");
                if (value > std.math.maxInt(u160)) @compileError("addr integer literal does not fit in u160");
                return .fromU160(@intCast(value));
            },
            .int => |info| {
                if (info.signedness != .unsigned) @compileError("addr only accepts unsigned integer types");
                if (info.bits > 160) @compileError("addr integer type " ++ @typeName(T) ++ " is wider than u160; narrow explicitly");
                return .fromU160(@intCast(value));
            },
            .array => |array| {
                if (array.child == u8 and array.len == Address.len) return .fromBytes(value);
                @compileError("addr only accepts [20]u8 address bytes by value; use a string or []const u8 for hex");
            },
            .pointer => |pointer| fromPointer(T, pointer, value),
            else => @compileError("addr does not accept " ++ @typeName(T)),
        };
    }
};

/// Word-aligned account identity used across execution callbacks and dense
/// state translation. Its first 20 in-memory bytes are the canonical address;
/// the final four bytes are always zero and never cross a protocol boundary.
pub const AddressWord = extern struct {
    words: [3]u64,

    comptime {
        std.debug.assert(@sizeOf(AddressWord) == 24);
        std.debug.assert(@alignOf(AddressWord) == 8);
    }

    pub inline fn fromAddress(value: Address) AddressWord {
        return .{ .words = .{
            std.mem.readInt(u64, value.bytes[0..8], .little),
            std.mem.readInt(u64, value.bytes[8..16], .little),
            std.mem.readInt(u32, value.bytes[16..20], .little),
        } };
    }

    pub inline fn fromU256(value: u256) AddressWord {
        return .{ .words = .{
            @byteSwap(@as(u64, @truncate(value >> 96))),
            @byteSwap(@as(u64, @truncate(value >> 32))),
            @byteSwap(@as(u32, @truncate(value))),
        } };
    }

    pub inline fn address(self: AddressWord) Address {
        std.debug.assert(self.words[2] <= std.math.maxInt(u32));
        var bytes: [Address.len]u8 = undefined;
        std.mem.writeInt(u64, bytes[0..8], self.words[0], .little);
        std.mem.writeInt(u64, bytes[8..16], self.words[1], .little);
        std.mem.writeInt(u32, bytes[16..20], @intCast(self.words[2]), .little);
        return Address.fromBytes(bytes);
    }

    pub inline fn toU256(self: AddressWord) u256 {
        std.debug.assert(self.words[2] <= std.math.maxInt(u32));
        return (@as(u256, @byteSwap(self.words[0])) << 96) |
            (@as(u256, @byteSwap(self.words[1])) << 32) |
            @byteSwap(@as(u32, @intCast(self.words[2])));
    }

    pub inline fn eql(a: AddressWord, b: AddressWord) bool {
        return a.words[0] == b.words[0] and
            a.words[1] == b.words[1] and
            a.words[2] == b.words[2];
    }
};

pub const addr = Address.addr;

inline fn fromPointer(comptime T: type, comptime pointer: std.builtin.Type.Pointer, value: T) Address {
    return switch (pointer.size) {
        .one => {
            if (pointer.child == Address) return value.*;
            return switch (@typeInfo(pointer.child)) {
                .array => |array| {
                    return if (array.child == u8 and array.len == Address.len)
                        .fromBytes(value.*)
                    else {
                        if (array.child != u8) @compileError("addr only accepts u8 hex strings");
                        return comptime Address.fromHex(value[0..array.len]) catch |err| switch (err) {
                            error.InvalidAddressHexLength => @compileError("address hex must contain 40 hex characters, with optional 0x prefix"),
                            error.InvalidAddressHexCharacter => @compileError("address hex contains a non-hex character"),
                        };
                    };
                },
                else => @compileError("addr does not accept pointer to " ++ @typeName(pointer.child)),
            };
        },
        .slice => @compileError("addr does not accept slices; use fromHex(...) for runtime hex, or pass a comptime-known string literal / fixed-size array pointer"),
        else => @compileError("addr does not accept pointer type " ++ @typeName(T)),
    };
}

fn hasHexPrefix(hex: []const u8) bool {
    return hex.len >= 2 and hex[0] == '0' and (hex[1] == 'x' or hex[1] == 'X');
}

/// keccak256(rlp([sender_address,sender_nonce]))[12:]
pub fn create(sender: Address, nonce: u64) Address {
    const CreateInput = struct {
        sender: Address,
        nonce: u64,

        /// List prefix over a 21-byte address and a worst-case 9-byte nonce; the
        /// payload never reaches the long-form prefix, so one byte always suffices.
        const max_encoded_len = 1 + 21 + 9;
    };

    var encoded: [CreateInput.max_encoded_len]u8 = undefined;
    const payload = rlp.encode(CreateInput, &encoded, CreateInput{
        .sender = sender,
        .nonce = nonce,
    }) catch unreachable;

    return fromHash(crypto.keccak256(payload));
}

/// keccak256( 0xff ++ address ++ salt ++ keccak256(init_code))[12:]
pub fn create2(sender: Address, salt: u256, init_code: []const u8) Address {
    const init_hash = crypto.keccak256(init_code);

    var salt_bytes: [32]u8 = undefined;
    std.mem.writeInt(u256, &salt_bytes, salt, .big);

    var data: [1 + 20 + 32 + 32]u8 = undefined;
    data[0] = 0xff;
    @memcpy(data[1..21], sender.asBytes());
    @memcpy(data[21..53], &salt_bytes);
    @memcpy(data[53..85], &init_hash);

    const hash = crypto.keccak256(&data);
    return fromHash(hash);
}

fn fromHash(hash: [32]u8) Address {
    var bytes: [Address.len]u8 = undefined;
    @memcpy(&bytes, hash[12..32]);
    return Address.fromBytes(bytes);
}

test addr {
    const address0 = addr(0);
    try std.testing.expectEqual(Address.zero, address0);
    var a = [_]u8{0} ** 20;
    const address1 = addr(1);
    a[19] = 1;
    try std.testing.expectEqual(Address.fromBytes(a), address1);

    try std.testing.expectEqual(Address.fromBytes(a), addr(@as(u8, 1)));
    try std.testing.expectEqual(Address.fromBytes(a), addr(a));
    try std.testing.expectEqual(Address.fromBytes(a), addr(&a));
    try std.testing.expectEqual(Address.fromBytes(a), addr("0000000000000000000000000000000000000001"));
    try std.testing.expectEqual(Address.fromBytes(a), addr("0x0000000000000000000000000000000000000001"));
}

test "Address.fromU256" {
    const word = (@as(u256, 1) << 160) | 0x1234;
    var expected = [_]u8{0} ** 20;
    expected[18] = 0x12;
    expected[19] = 0x34;
    try std.testing.expectEqual(Address.fromBytes(expected), Address.fromU256(word));
}

test "address word preserves canonical bytes and truncates EVM words" {
    const canonical = addr("123456789abcdef00123456789abcdef00123456");
    const from_address: AddressWord = .fromAddress(canonical);
    try std.testing.expectEqual(canonical, from_address.address());
    try std.testing.expectEqual(@as(u64, 0), from_address.words[2] >> 32);

    const evm_word = (@as(u256, 0xdeadbeef) << 160) | canonical.toU256();
    const from_evm_word: AddressWord = .fromU256(evm_word);
    try std.testing.expect(AddressWord.eql(from_address, from_evm_word));
    try std.testing.expectEqual(canonical.toU256(), from_evm_word.toU256());

    // Randomized oracle: limb recombination must match the canonical byte read.
    var prng = std.Random.DefaultPrng.init(0x5eed);
    const random = prng.random();
    for (0..10_000) |_| {
        var target: Address = undefined;
        random.bytes(&target.bytes);
        const word: AddressWord = .fromAddress(target);
        try std.testing.expectEqual(target.toU256(), word.toU256());
        try std.testing.expectEqual(target, AddressWord.fromU256(word.toU256()).address());
    }
}

test "Address.fromPublicKey" {
    const public_key = [_]u8{
        0x79, 0xbe, 0x66, 0x7e, 0xf9, 0xdc, 0xbb, 0xac,
        0x55, 0xa0, 0x62, 0x95, 0xce, 0x87, 0x0b, 0x07,
        0x02, 0x9b, 0xfc, 0xdb, 0x2d, 0xce, 0x28, 0xd9,
        0x59, 0xf2, 0x81, 0x5b, 0x16, 0xf8, 0x17, 0x98,
        0x48, 0x3a, 0xda, 0x77, 0x26, 0xa3, 0xc4, 0x65,
        0x5d, 0xa4, 0xfb, 0xfc, 0x0e, 0x11, 0x08, 0xa8,
        0xfd, 0x17, 0xb4, 0x48, 0xa6, 0x85, 0x54, 0x19,
        0x9c, 0x47, 0xd0, 0x8f, 0xfb, 0x10, 0xd4, 0xb8,
    };
    try std.testing.expectEqual(addr("7e5f4552091a69125d5dfcb7b8c2659029395bdf"), Address.fromPublicKey(public_key));
}

test "address conversion uses Ethereum byte order" {
    const address1 = addr(1);
    try std.testing.expectEqual(@as(u256, 1), address1.toU256());

    var address1234 = [_]u8{0} ** 20;
    address1234[18] = 0x12;
    address1234[19] = 0x34;
    const canonical = Address.fromBytes(address1234);
    try std.testing.expectEqual(canonical, addr(0x1234));
    try std.testing.expectEqual(@as(u256, 0x1234), canonical.toU256());
}

test "address hex formatting preserves leading zeroes" {
    var buffer: [2 * Address.len]u8 = undefined;
    const formatted = try std.fmt.bufPrint(&buffer, "{x}", .{addr(0x1234)});
    try std.testing.expectEqualStrings("0000000000000000000000000000000000001234", formatted);
}

test "address hash preserves canonical byte hashing" {
    const value = addr("123456789abcdef00123456789abcdef00123456");
    const ByteContext = std.hash_map.AutoContext([Address.len]u8);
    try std.testing.expectEqual(ByteContext.hash(.{}, value.bytes), Address.HashContext.hash(.{}, value));
}

test "address SSZ preserves the canonical byte-vector schema" {
    const value = addr("123456789abcdef00123456789abcdef00123456");
    comptime std.debug.assert(Address.Ssz.wire_codec == ssz.ByteVector(Address.len));

    var encoded: [Address.len]u8 = undefined;
    try std.testing.expectEqualSlices(u8, value.asBytes(), try Address.Ssz.encode(&encoded, value));
    try std.testing.expectEqual(value, try Address.Ssz.decode(&encoded));
    try std.testing.expectEqual(
        try ssz.hashTreeRoot(ssz.ByteVector(Address.len), value.bytes),
        try ssz.hashTreeRoot(Address.Ssz, value),
    );
}

test "Address.fromHex" {
    var expected = [_]u8{0} ** 20;
    expected[18] = 0x12;
    expected[19] = 0x34;

    try std.testing.expectEqual(Address.fromBytes(expected), try Address.fromHex("0000000000000000000000000000000000001234"));
    try std.testing.expectEqual(Address.fromBytes(expected), try Address.fromHex("0X0000000000000000000000000000000000001234"));
    try std.testing.expectError(error.InvalidAddressHexLength, Address.fromHex("1234"));
    try std.testing.expectError(error.InvalidAddressHexCharacter, Address.fromHex("00000000000000000000000000000000000012zz"));
}

test create {
    const sender = try Address.fromHex("5fc94da7cae6b2e69799b03858483a676c906772");
    const expected = try Address.fromHex("7ec63eda6c58777cb9f17a99a6a334547d59c9b6");
    try std.testing.expectEqual(expected, create(sender, 1));
}

test create2 {
    const sender = try Address.fromHex("0000000000000000000000000000000000000000");
    const expected = try Address.fromHex("4d1a2e2bb4f88f0250f26ffff098b0b30b26bf38");
    try std.testing.expectEqual(expected, create2(sender, 0, &.{0x00}));
}
