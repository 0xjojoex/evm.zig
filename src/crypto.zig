//! Hashing and signature primitives (keccak256, ecrecover).
//!
//! The backing provider is selected at build time by the crypto profile
//! (`native` or `zkvm`). Native builds can select the `std` or `xkcp` Keccak
//! backend and the `std` or `libsecp256k1` recovery backend independently;
//! zkVM builds stay on their custom accelerator provider.

const std = @import("std");
const build_options = @import("build_options");
const zkvm = @import("./crypto/zkvm_accelerators.zig");

pub const provider_name = build_options.profile;
pub const keccak_provider_name = if (std.mem.eql(u8, provider_name, "native"))
    build_options.native_keccak
else
    "zkvm";
pub const secp256k1_provider_name = if (std.mem.eql(u8, provider_name, "native"))
    build_options.native_secp256k1
else
    "zkvm";

/// Keccak-256 digest of the empty byte string.
pub const keccak256_empty = [_]u8{
    0xc5, 0xd2, 0x46, 0x01, 0x86, 0xf7, 0x23, 0x3c,
    0x92, 0x7e, 0x7d, 0xb2, 0xdc, 0xc7, 0x03, 0xc0,
    0xe5, 0x00, 0xb6, 0x53, 0xca, 0x82, 0x27, 0x3b,
    0x7b, 0xfa, 0xd8, 0x04, 0x5d, 0x85, 0xa4, 0x70,
};

const Provider = if (std.mem.eql(u8, provider_name, "native"))
    NativeProvider
else if (std.mem.eql(u8, provider_name, "zkvm"))
    ZkvmProvider
else
    @compileError("unsupported profile '" ++ provider_name ++ "'");

const NativeKeccakProvider = if (std.mem.eql(u8, build_options.native_keccak, "std"))
    StdKeccakProvider
else if (std.mem.eql(u8, build_options.native_keccak, "xkcp"))
    XkcpKeccakProvider
else
    @compileError("unsupported native Keccak backend '" ++ build_options.native_keccak ++ "'");

const NativeSecp256k1Provider = if (std.mem.eql(u8, build_options.native_secp256k1, "std"))
    StdSecp256k1Provider
else if (std.mem.eql(u8, build_options.native_secp256k1, "libsecp256k1"))
    Libsecp256k1Provider
else
    @compileError("unsupported native secp256k1 backend '" ++ build_options.native_secp256k1 ++ "'");

pub fn keccak256(input: []const u8) [32]u8 {
    var digest: [32]u8 = undefined;
    Provider.keccak256(input, &digest);
    return digest;
}

pub fn sha256(input: []const u8) [32]u8 {
    var digest: [32]u8 = undefined;
    Provider.sha256(input, &digest);
    return digest;
}

pub fn ecrecoverPublicKey(
    message_hash: [32]u8,
    r: [32]u8,
    s: [32]u8,
    recovery_id: u8,
) ?[64]u8 {
    return Provider.ecrecoverPublicKey(message_hash, r, s, recovery_id);
}

const NativeProvider = struct {
    fn keccak256(input: []const u8, out: *[32]u8) void {
        NativeKeccakProvider.keccak256(input, out);
    }

    fn sha256(input: []const u8, out: *[32]u8) void {
        std.crypto.hash.sha2.Sha256.hash(input, out, .{});
    }

    fn ecrecoverPublicKey(message_hash: [32]u8, r: [32]u8, s: [32]u8, recovery_id: u8) ?[64]u8 {
        return NativeSecp256k1Provider.ecrecoverPublicKey(message_hash, r, s, recovery_id);
    }
};

const StdSecp256k1Provider = struct {
    fn ecrecoverPublicKey(message_hash: [32]u8, r: [32]u8, s: [32]u8, recovery_id: u8) ?[64]u8 {
        if (recovery_id > 1) return null;

        const Secp256k1 = std.crypto.ecc.Secp256k1;
        const Scalar = Secp256k1.scalar.Scalar;

        const r_scalar = Scalar.fromBytes(r, .big) catch return null;
        const s_scalar = Scalar.fromBytes(s, .big) catch return null;
        if (r_scalar.isZero() or s_scalar.isZero()) return null;

        const x = Secp256k1.Fe.fromBytes(r, .big) catch return null;
        const y = Secp256k1.recoverY(x, recovery_id == 1) catch return null;
        const r_point = Secp256k1.fromAffineCoordinates(.{ .x = x, .y = y }) catch return null;

        var expanded_hash = [_]u8{0} ** 64;
        @memcpy(expanded_hash[32..64], &message_hash);
        const z = Scalar.fromBytes64(expanded_hash, .big);
        const r_inverse = r_scalar.invert();
        const base_scalar = z.mul(r_inverse).neg().toBytes(.big);
        const point_scalar = s_scalar.mul(r_inverse).toBytes(.big);
        const public_key = Secp256k1.mulDoubleBasePublic(Secp256k1.basePoint, base_scalar, r_point, point_scalar, .big) catch return null;
        public_key.rejectIdentity() catch return null;

        const uncompressed = public_key.toUncompressedSec1();
        var out: [64]u8 = undefined;
        @memcpy(&out, uncompressed[1..65]);
        return out;
    }
};

const StdKeccakProvider = struct {
    fn keccak256(input: []const u8, out: *[32]u8) void {
        std.crypto.hash.sha3.Keccak256.hash(input, out, .{});
    }
};

const XkcpKeccakProvider = struct {
    extern fn evmz_xkcp_keccak256(
        input: [*]const u8,
        input_len: usize,
        output: [*]u8,
    ) c_int;

    fn keccak256(input: []const u8, out: *[32]u8) void {
        const rc = evmz_xkcp_keccak256(input.ptr, input.len, out);
        if (rc != 0) unreachable;
    }
};

const Libsecp256k1Provider = struct {
    extern fn evmz_libsecp256k1_ecrecover(
        message_hash: [*]const u8,
        r: [*]const u8,
        s: [*]const u8,
        recovery_id: c_int,
        output: [*]u8,
    ) c_int;

    fn ecrecoverPublicKey(message_hash: [32]u8, r: [32]u8, s: [32]u8, recovery_id: u8) ?[64]u8 {
        if (recovery_id > 1) return null;

        var out: [64]u8 = undefined;
        if (evmz_libsecp256k1_ecrecover(
            &message_hash,
            &r,
            &s,
            recovery_id,
            &out,
        ) != 1) return null;
        return out;
    }
};

const ZkvmProvider = struct {
    fn keccak256(input: []const u8, out: *[32]u8) void {
        var digest: zkvm.Keccak256Hash = undefined;
        if (zkvm.zkvm_keccak256(zkvm.inputPtr(input), input.len, &digest) != zkvm.EOK) {
            @panic("zkvm_keccak256 failed");
        }
        out.* = digest.data;
    }

    fn sha256(input: []const u8, out: *[32]u8) void {
        var digest: zkvm.Sha256Hash = undefined;
        if (zkvm.zkvm_sha256(zkvm.inputPtr(input), input.len, &digest) != zkvm.EOK) {
            @panic("zkvm_sha256 failed");
        }
        out.* = digest.data;
    }

    fn ecrecoverPublicKey(message_hash: [32]u8, r: [32]u8, s: [32]u8, recovery_id: u8) ?[64]u8 {
        var msg: zkvm.Secp256k1Hash = .{ .data = message_hash };
        var sig: zkvm.Secp256k1Signature = undefined;
        @memcpy(sig.data[0..32], &r);
        @memcpy(sig.data[32..64], &s);

        var public_key: zkvm.Secp256k1Pubkey = undefined;
        if (zkvm.zkvm_secp256k1_ecrecover(&msg, &sig, recovery_id, &public_key) != zkvm.EOK) return null;
        return public_key.data;
    }
};

test keccak256 {
    try std.testing.expectEqualSlices(u8, &keccak256_empty, &keccak256(""));
}

test "native Keccak backend matches std across rate boundaries" {
    if (!std.mem.eql(u8, provider_name, "native")) return;

    var storage: [1025]u8 align(8) = undefined;
    const input = storage[1..];
    for (input, 0..) |*byte, i| byte.* = @truncate(i *% 17 +% 3);
    inline for (.{ 0, 1, 32, 135, 136, 137, 1024 }) |len| {
        var expected: [32]u8 = undefined;
        std.crypto.hash.sha3.Keccak256.hash(input[0..len], &expected, .{});
        try std.testing.expectEqualSlices(u8, &expected, &keccak256(input[0..len]));
    }
}

test sha256 {
    try std.testing.expectEqualSlices(u8, &[_]u8{
        0xe3, 0xb0, 0xc4, 0x42, 0x98, 0xfc, 0x1c, 0x14,
        0x9a, 0xfb, 0xf4, 0xc8, 0x99, 0x6f, 0xb9, 0x24,
        0x27, 0xae, 0x41, 0xe4, 0x64, 0x9b, 0x93, 0x4c,
        0xa4, 0x95, 0x99, 0x1b, 0x78, 0x52, 0xb8, 0x55,
    }, &sha256(""));
}

test "native secp256k1 backend matches std recovery semantics" {
    if (!std.mem.eql(u8, provider_name, "native")) return;

    const message_hash = [_]u8{
        0x18, 0xc5, 0x47, 0xe4, 0xf7, 0xb0, 0xf3, 0x25,
        0xad, 0x1e, 0x56, 0xf5, 0x7e, 0x26, 0xc7, 0x45,
        0xb0, 0x9a, 0x3e, 0x50, 0x3d, 0x86, 0xe0, 0x0e,
        0x52, 0x55, 0xff, 0x7f, 0x71, 0x5d, 0x3d, 0x1c,
    };
    const r = [_]u8{
        0x73, 0xb1, 0x69, 0x38, 0x92, 0x21, 0x9d, 0x73,
        0x6c, 0xab, 0xa5, 0x5b, 0xdb, 0x67, 0x21, 0x6e,
        0x48, 0x55, 0x57, 0xea, 0x6b, 0x6a, 0xf7, 0x5f,
        0x37, 0x09, 0x6c, 0x9a, 0xa6, 0xa5, 0xa7, 0x5f,
    };
    const s = [_]u8{
        0xee, 0xb9, 0x40, 0xb1, 0xd0, 0x3b, 0x21, 0xe3,
        0x6b, 0x0e, 0x47, 0xe7, 0x97, 0x69, 0xf0, 0x95,
        0xfe, 0x2a, 0xb8, 0x55, 0xbd, 0x91, 0xe3, 0xa3,
        0x87, 0x56, 0xb7, 0xd7, 0x5a, 0x9c, 0x45, 0x49,
    };

    const expected = StdSecp256k1Provider.ecrecoverPublicKey(message_hash, r, s, 1);
    try std.testing.expectEqual(expected, ecrecoverPublicKey(message_hash, r, s, 1));

    const zero = [_]u8{0} ** 32;
    try std.testing.expectEqual(
        StdSecp256k1Provider.ecrecoverPublicKey(message_hash, zero, s, 1),
        ecrecoverPublicKey(message_hash, zero, s, 1),
    );
    try std.testing.expectEqual(
        StdSecp256k1Provider.ecrecoverPublicKey(message_hash, r, zero, 1),
        ecrecoverPublicKey(message_hash, r, zero, 1),
    );
    const out_of_range = [_]u8{0xff} ** 32;
    try std.testing.expectEqual(
        StdSecp256k1Provider.ecrecoverPublicKey(message_hash, out_of_range, s, 1),
        ecrecoverPublicKey(message_hash, out_of_range, s, 1),
    );
    try std.testing.expectEqual(
        StdSecp256k1Provider.ecrecoverPublicKey(message_hash, r, out_of_range, 1),
        ecrecoverPublicKey(message_hash, r, out_of_range, 1),
    );
    try std.testing.expectEqual(
        StdSecp256k1Provider.ecrecoverPublicKey(message_hash, r, s, 2),
        ecrecoverPublicKey(message_hash, r, s, 2),
    );
}

test "zkvm byte wrappers match accelerator ABI" {
    try std.testing.expectEqual(@as(usize, 32), @sizeOf(zkvm.Bytes32));
    try std.testing.expectEqual(@as(usize, 8), @alignOf(zkvm.Bytes32));
    try std.testing.expectEqual(@as(usize, 64), @sizeOf(zkvm.Bytes64));
    try std.testing.expectEqual(@as(usize, 8), @alignOf(zkvm.Bytes64));
}
