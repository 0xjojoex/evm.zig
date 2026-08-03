//! Schema-id framing shared by every stateless wire schema.
//!
//! Guest input is `schema_id || payload`, where the two-byte big-endian id packs
//! `fork_index || revision`. SSZ is not self-describing, so this prefix is the
//! only thing that lets a guest pick a decoder. The fork byte selects the
//! container shape and the execution spec; the revision byte selects the payload
//! encoding at that fork, leaving execution semantics untouched.

const std = @import("std");

pub const Error = error{ MissingSchemaId, UnsupportedSchemaId, UnsupportedFork };

pub const id_size = 2;

/// Stable execution-layer fork identifiers used by stateless schemas; one byte
/// wide because they are the high byte of a schema id. The pre-Amsterdam values
/// exist to keep the numbering canonical, not because inputs are defined there.
pub const ProtocolFork = enum(u8) {
    frontier = 0x01,
    homestead = 0x02,
    dao_fork = 0x03,
    tangerine_whistle = 0x04,
    spurious_dragon = 0x05,
    byzantium = 0x06,
    petersburg = 0x07,
    istanbul = 0x08,
    muir_glacier = 0x09,
    berlin = 0x0a,
    london = 0x0b,
    arrow_glacier = 0x0c,
    gray_glacier = 0x0d,
    paris = 0x0e,
    shanghai = 0x0f,
    cancun = 0x10,
    prague = 0x11,
    osaka = 0x12,
    bpo1 = 0x13,
    bpo2 = 0x14,
    amsterdam = 0x15,

    pub fn fromInt(value: u8) Error!ProtocolFork {
        return std.enums.fromInt(ProtocolFork, value) orelse error.UnsupportedFork;
    }
};

pub fn id(fork: ProtocolFork, revision: u8) u16 {
    return (@as(u16, @intFromEnum(fork)) << 8) | revision;
}

pub fn readId(bytes: []const u8) Error!u16 {
    if (bytes.len < id_size) return error.MissingSchemaId;
    return std.mem.readInt(u16, bytes[0..id_size], .big);
}

/// Strips the prefix for a schema that accepts exactly `expected`, reporting an
/// unimplemented payload encoding of a known fork (`UnsupportedSchemaId`) apart
/// from a fork this build cannot decode at all (`UnsupportedFork`).
pub fn body(bytes: []const u8, comptime expected: u16) Error![]const u8 {
    const actual = try readId(bytes);
    if (actual == expected) return bytes[id_size..];
    const fork = try ProtocolFork.fromInt(@intCast(actual >> 8));
    return if (@intFromEnum(fork) == comptime expected >> 8)
        error.UnsupportedSchemaId
    else
        error.UnsupportedFork;
}
