const std = @import("std");
const codec = @import("codec.zig");
const Error = @import("error.zig").Error;

/// Adapt a host representation to an existing canonical SSZ codec.
///
/// `mapping.toWire` and `mapping.fromWire` must be infallible, lossless, and
/// ownership-preserving. Serialization, validation, and Merkleization remain
/// defined by `WireCodec`; the mapping changes only the in-memory value type.
/// Both round trips must preserve the value. For allocator-backed wire codecs,
/// `fromWire` transfers decoded ownership into `Host`, and `toWire` must return
/// those same allocations so `deinit` can release them through `WireCodec`.
pub fn Mapped(
    comptime Host: type,
    comptime WireCodec: type,
    comptime mapping: Mapping(Host, WireCodec),
) type {
    const Common = struct {
        pub const Value = Host;
        pub const kind = WireCodec.kind;
        pub const wire_codec = WireCodec;
        pub const is_variable_size = WireCodec.is_variable_size;
        pub const fixed_size = WireCodec.fixed_size;
        pub const requires_allocator = WireCodec.requires_allocator;
        pub const toWire = mapping.toWire;

        pub fn encodedLen(value: Host) Error!usize {
            return WireCodec.encodedLen(mapping.toWire(value));
        }

        pub fn encode(out: []u8, value: Host) Error![]u8 {
            return WireCodec.encode(out, mapping.toWire(value));
        }

        pub fn decodeAlloc(
            allocator: std.mem.Allocator,
            bytes: []const u8,
        ) (Error || std.mem.Allocator.Error)!Host {
            return mapping.fromWire(try codec.decodeOwned(WireCodec, allocator, bytes));
        }

        pub fn decode(bytes: []const u8) Error!Host {
            return mapping.fromWire(try WireCodec.decode(bytes));
        }

        pub const validate = WireCodec.validate;

        pub fn deinit(allocator: std.mem.Allocator, value: *Host) void {
            var wire = mapping.toWire(value.*);
            codec.deinitOwned(WireCodec, allocator, &wire);
            value.* = mapping.fromWire(wire);
        }
    };

    if (Common.requires_allocator) {
        if (std.meta.hasFn(WireCodec, "decode")) {
            return struct {
                pub const Value = Common.Value;
                pub const kind = Common.kind;
                pub const wire_codec = Common.wire_codec;
                pub const is_variable_size = Common.is_variable_size;
                pub const fixed_size = Common.fixed_size;
                pub const requires_allocator = true;
                pub const toWire = Common.toWire;
                pub const encodedLen = Common.encodedLen;
                pub const encode = Common.encode;
                pub const decodeAlloc = Common.decodeAlloc;
                pub const decode = Common.decode;
                pub const validate = Common.validate;
                pub const deinit = Common.deinit;
            };
        }
        return struct {
            pub const Value = Common.Value;
            pub const kind = Common.kind;
            pub const wire_codec = Common.wire_codec;
            pub const is_variable_size = Common.is_variable_size;
            pub const fixed_size = Common.fixed_size;
            pub const requires_allocator = true;
            pub const toWire = Common.toWire;
            pub const encodedLen = Common.encodedLen;
            pub const encode = Common.encode;
            pub const decodeAlloc = Common.decodeAlloc;
            pub const validate = Common.validate;
            pub const deinit = Common.deinit;
        };
    }
    return struct {
        pub const Value = Common.Value;
        pub const kind = Common.kind;
        pub const wire_codec = Common.wire_codec;
        pub const is_variable_size = Common.is_variable_size;
        pub const fixed_size = Common.fixed_size;
        pub const requires_allocator = false;
        pub const toWire = Common.toWire;
        pub const encodedLen = Common.encodedLen;
        pub const encode = Common.encode;
        pub const decode = Common.decode;
        pub const validate = Common.validate;
    };
}

fn Mapping(comptime Host: type, comptime WireCodec: type) type {
    comptime codec.assertCodec(WireCodec);
    return struct {
        toWire: *const fn (Host) WireCodec.Value,
        fromWire: *const fn (WireCodec.Value) Host,
    };
}
