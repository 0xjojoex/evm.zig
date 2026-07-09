//! 20-byte Ethereum address type, constructors, and hex parsing.

const std = @import("std");
const crypto = @import("crypto.zig");

/// A 20-byte Ethereum account address.
pub const Address = [20]u8;

pub const zero_address: Address = std.mem.zeroes(Address);

pub const ParseError = error{
    InvalidAddressHexLength,
    InvalidAddressHexCharacter,
};

/// Ergonomic address constructor for unsigned integer literals, small unsigned integers,
/// address bytes, and comptime-known 40-character hex strings with an optional 0x prefix.
pub inline fn addr(value: anytype) Address {
    const T = @TypeOf(value);
    return switch (@typeInfo(T)) {
        .comptime_int => fromComptimeInt(value),
        .int => |info| fromInt(T, info, value),
        .array => |array| fromArray(T, array, value),
        .pointer => |pointer| fromPointer(T, pointer, value),
        else => @compileError("addr does not accept " ++ @typeName(T)),
    };
}

pub fn fromU160(value: u160) Address {
    var bytes: Address = undefined;
    std.mem.writeInt(u160, &bytes, value, .big);
    return bytes;
}

pub fn toU256(address: Address) u256 {
    return std.mem.readInt(u160, &address, .big);
}

pub fn fromHex(hex: []const u8) ParseError!Address {
    const body = if (hasHexPrefix(hex)) hex[2..] else hex;
    if (body.len != 2 * zero_address.len) return error.InvalidAddressHexLength;

    var bytes: Address = undefined;
    _ = std.fmt.hexToBytes(&bytes, body) catch return error.InvalidAddressHexCharacter;
    return bytes;
}

pub fn fromWord(word: u256) Address {
    return addr(@as(u160, @truncate(word)));
}

pub fn fromPublicKey(public_key: [64]u8) Address {
    return fromHash(crypto.keccak256(&public_key));
}

fn fromComptimeInt(comptime value: comptime_int) Address {
    if (value < 0) @compileError("addr integer literal must be non-negative");
    if (value > std.math.maxInt(u160)) @compileError("addr integer literal does not fit in u160");
    return fromU160(@intCast(value));
}

fn fromInt(comptime T: type, comptime info: std.builtin.Type.Int, value: T) Address {
    if (info.signedness != .unsigned) @compileError("addr only accepts unsigned integer types");
    if (info.bits > 160) @compileError("addr integer type " ++ @typeName(T) ++ " is wider than u160; narrow explicitly");
    return fromU160(@intCast(value));
}

fn fromArray(comptime T: type, comptime array: std.builtin.Type.Array, value: T) Address {
    if (T == Address) return value;
    _ = array;
    @compileError("addr only accepts [20]u8 address bytes by value; use a string or []const u8 for hex");
}

inline fn fromPointer(comptime T: type, comptime pointer: std.builtin.Type.Pointer, value: T) Address {
    return switch (pointer.size) {
        .one => fromSinglePointer(pointer.child, value),
        .slice => @compileError("addr does not accept slices; use fromHex(...) for runtime hex, or pass a comptime-known string literal / fixed-size array pointer"),
        else => @compileError("addr does not accept pointer type " ++ @typeName(T)),
    };
}

inline fn fromSinglePointer(comptime Child: type, value: anytype) Address {
    if (Child == Address) return value.*;
    return switch (@typeInfo(Child)) {
        .array => |array| fromHexStringPointer(array, value),
        else => @compileError("addr does not accept pointer to " ++ @typeName(Child)),
    };
}

inline fn fromHexStringPointer(comptime array: std.builtin.Type.Array, comptime value: anytype) Address {
    if (array.child != u8) @compileError("addr only accepts u8 hex strings");
    return fromComptimeHex(value[0..array.len]);
}

fn fromComptimeHex(comptime hex: []const u8) Address {
    return comptime fromHex(hex) catch |err| switch (err) {
        error.InvalidAddressHexLength => @compileError("address hex must contain 40 hex characters, with optional 0x prefix"),
        error.InvalidAddressHexCharacter => @compileError("address hex contains a non-hex character"),
    };
}

fn hasHexPrefix(hex: []const u8) bool {
    return hex.len >= 2 and hex[0] == '0' and (hex[1] == 'x' or hex[1] == 'X');
}

/// keccak256(rlp([sender_address,sender_nonce]))[12:]
pub fn create(sender: Address, nonce: u64) Address {
    var nonce_buf: [9]u8 = undefined;
    const nonce_rlp = rlpEncodeNonce(&nonce_buf, nonce);

    var encoded: [1 + 1 + 20 + 9]u8 = undefined;
    const payload_len = 1 + sender.len + nonce_rlp.len;
    encoded[0] = 0xc0 + @as(u8, @intCast(payload_len));
    encoded[1] = 0x80 + @as(u8, @intCast(sender.len));
    @memcpy(encoded[2 .. 2 + sender.len], &sender);
    @memcpy(encoded[2 + sender.len .. 2 + sender.len + nonce_rlp.len], nonce_rlp);

    const hash = crypto.keccak256(encoded[0 .. 1 + payload_len]);
    return fromHash(hash);
}

/// keccak256( 0xff ++ address ++ salt ++ keccak256(init_code))[12:]
pub fn create2(sender: Address, salt: u256, init_code: []const u8) Address {
    const init_hash = crypto.keccak256(init_code);

    var salt_bytes: [32]u8 = undefined;
    std.mem.writeInt(u256, &salt_bytes, salt, .big);

    var data: [1 + 20 + 32 + 32]u8 = undefined;
    data[0] = 0xff;
    @memcpy(data[1..21], &sender);
    @memcpy(data[21..53], &salt_bytes);
    @memcpy(data[53..85], &init_hash);

    const hash = crypto.keccak256(&data);
    return fromHash(hash);
}

fn fromHash(hash: [32]u8) Address {
    var result: Address = undefined;
    @memcpy(&result, hash[12..32]);
    return result;
}

fn rlpEncodeNonce(buf: *[9]u8, nonce: u64) []const u8 {
    if (nonce == 0) {
        buf[0] = 0x80;
        return buf[0..1];
    }
    if (nonce < 0x80) {
        buf[0] = @intCast(nonce);
        return buf[0..1];
    }

    var be: [8]u8 = undefined;
    std.mem.writeInt(u64, &be, nonce, .big);
    var first: usize = 0;
    while (be[first] == 0) : (first += 1) {}

    const len = be.len - first;
    buf[0] = 0x80 + @as(u8, @intCast(len));
    @memcpy(buf[1 .. 1 + len], be[first..]);
    return buf[0 .. 1 + len];
}

test addr {
    const address0 = addr(0);
    try std.testing.expectEqual(zero_address, address0);
    var a = [_]u8{0} ** 20;
    const address1 = addr(1);
    a[19] = 1;
    try std.testing.expectEqual(a, address1);

    try std.testing.expectEqual(a, addr(@as(u8, 1)));
    try std.testing.expectEqual(a, addr(a));
    try std.testing.expectEqual(a, addr(&a));
    try std.testing.expectEqual(a, addr("0000000000000000000000000000000000000001"));
    try std.testing.expectEqual(a, addr("0x0000000000000000000000000000000000000001"));
}

test fromWord {
    const word = (@as(u256, 1) << 160) | 0x1234;
    var expected = [_]u8{0} ** 20;
    expected[18] = 0x12;
    expected[19] = 0x34;
    try std.testing.expectEqual(expected, fromWord(word));
}

test fromPublicKey {
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
    try std.testing.expectEqual(addr("7e5f4552091a69125d5dfcb7b8c2659029395bdf"), fromPublicKey(public_key));
}

test "address conversion uses Ethereum byte order" {
    const address1 = addr(1);
    try std.testing.expectEqual(@as(u256, 1), toU256(address1));

    var address1234 = [_]u8{0} ** 20;
    address1234[18] = 0x12;
    address1234[19] = 0x34;
    try std.testing.expectEqual(address1234, addr(0x1234));
    try std.testing.expectEqual(@as(u256, 0x1234), toU256(address1234));
}

test fromHex {
    var expected = [_]u8{0} ** 20;
    expected[18] = 0x12;
    expected[19] = 0x34;

    try std.testing.expectEqual(expected, try fromHex("0000000000000000000000000000000000001234"));
    try std.testing.expectEqual(expected, try fromHex("0X0000000000000000000000000000000000001234"));
    try std.testing.expectError(error.InvalidAddressHexLength, fromHex("1234"));
    try std.testing.expectError(error.InvalidAddressHexCharacter, fromHex("00000000000000000000000000000000000012zz"));
}

test create {
    var sender: Address = undefined;
    _ = try std.fmt.hexToBytes(&sender, "5fc94da7cae6b2e69799b03858483a676c906772");
    var expected: Address = undefined;
    _ = try std.fmt.hexToBytes(&expected, "7ec63eda6c58777cb9f17a99a6a334547d59c9b6");
    try std.testing.expectEqual(expected, create(sender, 1));
}

test create2 {
    var sender: Address = undefined;
    _ = try std.fmt.hexToBytes(&sender, "0000000000000000000000000000000000000000");
    var expected: Address = undefined;
    _ = try std.fmt.hexToBytes(&expected, "4d1a2e2bb4f88f0250f26ffff098b0b30b26bf38");
    try std.testing.expectEqual(expected, create2(sender, 0, &.{0x00}));
}
