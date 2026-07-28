//! Static execution artifacts for protocol-constant Ethereum system code.
//!
//! Lookup is keyed only by an authenticated account code hash. The state
//! reader remains responsible for loading witness code and validating that its
//! bytes match the account hash.

const std = @import("std");
const Bytecode = @import("../code/Bytecode.zig");
const static_bytecode = @import("../code/static.zig");
const Backend = @import("../prepared_code/Backend.zig");
const crypto = @import("../crypto.zig");

pub const beacon_roots_code = code: {
    var bytes: [97]u8 = undefined;
    _ = std.fmt.hexToBytes(
        &bytes,
        "3373fffffffffffffffffffffffffffffffffffffffe14604d57602036146024575f5ffd5b5f35801560495762001fff810690815414603c575f5ffd5b62001fff01545f5260205ff35b5f5ffd5b62001fff42064281555f359062001fff015500",
    ) catch unreachable;
    break :code bytes;
};

pub const beacon_roots_code_hash = hash: {
    var bytes: [32]u8 = undefined;
    _ = std.fmt.hexToBytes(
        &bytes,
        "f57acd40259872606d76197ef052f3d35588dadf919ee1f0e3cb9b62d3f4b02c",
    ) catch unreachable;
    break :hash bytes;
};

const BeaconRoots = static_bytecode.View(&beacon_roots_code);
var backend_context: u8 = 0;

pub fn backend() Backend {
    return .{
        .ptr = &backend_context,
        .vtable = &backend_vtable,
    };
}

const backend_vtable = Backend.VTable{
    .beginExecution = beginExecution,
    .endExecution = endExecution,
    .lookup = lookup,
    .admit = admit,
};

fn beginExecution(ptr: *anyopaque) !void {
    _ = ptr;
}

fn endExecution(ptr: *anyopaque) void {
    _ = ptr;
}

fn lookup(ptr: *anyopaque, code_hash: [32]u8) !?Bytecode.View {
    _ = ptr;
    if (std.mem.eql(u8, &code_hash, &beacon_roots_code_hash)) {
        return BeaconRoots.view;
    }
    return null;
}

fn admit(
    ptr: *anyopaque,
    code_hash: [32]u8,
    raw_code: []const u8,
) !?Bytecode.View {
    _ = ptr;
    _ = code_hash;
    _ = raw_code;
    return null;
}

test "beacon roots artifact is selected by its authenticated hash" {
    try std.testing.expectEqualSlices(
        u8,
        &beacon_roots_code_hash,
        &crypto.keccak256(&beacon_roots_code),
    );

    const prepared = (try backend().lookup(beacon_roots_code_hash)).?;
    try std.testing.expectEqualSlices(u8, &beacon_roots_code, prepared.bytes);
    try std.testing.expectEqual(
        @as(?Bytecode.View, null),
        try backend().lookup([_]u8{0xff} ** 32),
    );
}
