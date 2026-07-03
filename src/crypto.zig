const std = @import("std");
const build_options = @import("build_options");
const zkvm = @import("zkvm_accelerators.zig");

pub const provider_name = build_options.profile;

const Provider = if (std.mem.eql(u8, provider_name, "native"))
    NativeProvider
else if (std.mem.eql(u8, provider_name, "zkvm"))
    ZkvmProvider
else
    @compileError("unsupported profile '" ++ provider_name ++ "'");

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
        std.crypto.hash.sha3.Keccak256.hash(input, out, .{});
    }

    fn sha256(input: []const u8, out: *[32]u8) void {
        std.crypto.hash.sha2.Sha256.hash(input, out, .{});
    }

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
    try std.testing.expectEqualSlices(u8, &[_]u8{
        0xc5, 0xd2, 0x46, 0x01, 0x86, 0xf7, 0x23, 0x3c,
        0x92, 0x7e, 0x7d, 0xb2, 0xdc, 0xc7, 0x03, 0xc0,
        0xe5, 0x00, 0xb6, 0x53, 0xca, 0x82, 0x27, 0x3b,
        0x7b, 0xfa, 0xd8, 0x04, 0x5d, 0x85, 0xa4, 0x70,
    }, &keccak256(""));
}

test sha256 {
    try std.testing.expectEqualSlices(u8, &[_]u8{
        0xe3, 0xb0, 0xc4, 0x42, 0x98, 0xfc, 0x1c, 0x14,
        0x9a, 0xfb, 0xf4, 0xc8, 0x99, 0x6f, 0xb9, 0x24,
        0x27, 0xae, 0x41, 0xe4, 0x64, 0x9b, 0x93, 0x4c,
        0xa4, 0x95, 0x99, 0x1b, 0x78, 0x52, 0xb8, 0x55,
    }, &sha256(""));
}

test "zkvm byte wrappers match accelerator ABI" {
    try std.testing.expectEqual(@as(usize, 32), @sizeOf(zkvm.Bytes32));
    try std.testing.expectEqual(@as(usize, 8), @alignOf(zkvm.Bytes32));
    try std.testing.expectEqual(@as(usize, 64), @sizeOf(zkvm.Bytes64));
    try std.testing.expectEqual(@as(usize, 8), @alignOf(zkvm.Bytes64));
}
