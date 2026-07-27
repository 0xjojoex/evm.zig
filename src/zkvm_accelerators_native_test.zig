//! Host-only semantic implementation of the zkVM accelerator ABI.
//!
//! This object is linked only into `-Dprofile=zkvm` tests. Production guest
//! builds must provide the real zkVM accelerator archive.
//!
//! It sits at `src/` rather than under `test/` because it is a module root
//! (`build.zig` compiles it as its own object at the native profile, then links
//! it into the zkVM-profile test binary). A module's root directory bounds every
//! file it imports, not just this one: `precompile/backend.zig` reaches for
//! `../crypto/zkvm_accelerators.zig`.

const std = @import("std");
const zkvm = @import("crypto/zkvm_accelerators.zig");
const native = @import("precompile/backend.zig");

const allocator = std.heap.c_allocator;

pub export fn zkvm_keccak256(
    data: [*]const u8,
    len: usize,
    output: *zkvm.Keccak256Hash,
) c_int {
    std.crypto.hash.sha3.Keccak256.hash(data[0..len], &output.data, .{});
    return zkvm.EOK;
}

pub export fn zkvm_sha256(
    data: [*]const u8,
    len: usize,
    output: *zkvm.Sha256Hash,
) c_int {
    std.crypto.hash.sha2.Sha256.hash(data[0..len], &output.data, .{});
    return zkvm.EOK;
}

pub export fn zkvm_ripemd160(
    data: [*]const u8,
    len: usize,
    output: *zkvm.Ripemd160Hash,
) c_int {
    return status(native.ripemd160(data[0..len], &output.data));
}

pub export fn zkvm_modexp(
    base: [*]const u8,
    base_len: usize,
    exponent: [*]const u8,
    exponent_len: usize,
    modulus: [*]const u8,
    modulus_len: usize,
    output: [*]u8,
) c_int {
    const result = native.modexp(
        allocator,
        output[0..modulus_len],
        base[0..base_len],
        exponent[0..exponent_len],
        modulus[0..modulus_len],
    ) catch return zkvm.EFAIL;
    return status(result);
}

pub export fn zkvm_secp256k1_verify(
    message: *const zkvm.Secp256k1Hash,
    signature: *const zkvm.Secp256k1Signature,
    public_key: *const zkvm.Secp256k1Pubkey,
    verified: *bool,
) c_int {
    verified.* = verifySecp256k1(message.data, signature.data, public_key.data);
    return zkvm.EOK;
}

pub export fn zkvm_secp256k1_ecrecover(
    message: *const zkvm.Secp256k1Hash,
    signature: *const zkvm.Secp256k1Signature,
    recovery_id: u8,
    output: *zkvm.Secp256k1Pubkey,
) c_int {
    output.data = recoverSecp256k1(message.data, signature.data, recovery_id) orelse
        return zkvm.EFAIL;
    return zkvm.EOK;
}

pub export fn zkvm_secp256r1_verify(
    message: *const zkvm.Secp256r1Hash,
    signature: *const zkvm.Secp256r1Signature,
    public_key: *const zkvm.Secp256r1Pubkey,
    verified: *bool,
) c_int {
    var input: [160]u8 = undefined;
    @memcpy(input[0..32], &message.data);
    @memcpy(input[32..96], &signature.data);
    @memcpy(input[96..160], &public_key.data);
    verified.* = native.p256Verify(&input);
    return zkvm.EOK;
}

pub export fn zkvm_bn254_g1_add(
    p1: *const zkvm.Bn254G1Point,
    p2: *const zkvm.Bn254G1Point,
    result: *zkvm.Bn254G1Point,
) c_int {
    var input: [128]u8 = undefined;
    @memcpy(input[0..64], &p1.data);
    @memcpy(input[64..128], &p2.data);
    return status(native.bn254Add(&input, &result.data));
}

pub export fn zkvm_bn254_g1_mul(
    point: *const zkvm.Bn254G1Point,
    scalar: *const zkvm.Bn254Scalar,
    result: *zkvm.Bn254G1Point,
) c_int {
    var input: [96]u8 = undefined;
    @memcpy(input[0..64], &point.data);
    @memcpy(input[64..96], &scalar.data);
    return status(native.bn254Mul(&input, &result.data));
}

pub export fn zkvm_bn254_pairing(
    pairs: [*]const zkvm.Bn254PairingPair,
    num_pairs: usize,
    verified: *bool,
) c_int {
    if (num_pairs == 0) {
        verified.* = true;
        return zkvm.EOK;
    }
    const input = allocator.alloc(u8, num_pairs * 192) catch return zkvm.EFAIL;
    defer allocator.free(input);
    for (pairs[0..num_pairs], 0..) |pair, i| {
        @memcpy(input[i * 192 ..][0..64], &pair.g1.data);
        @memcpy(input[i * 192 + 64 ..][0..128], &pair.g2.data);
    }
    var output: [32]u8 = undefined;
    const result = native.bn254Pairing(allocator, input, &output) catch return zkvm.EFAIL;
    if (result != .ok) return zkvm.EFAIL;
    verified.* = output[31] != 0;
    return zkvm.EOK;
}

pub export fn zkvm_blake2f(
    rounds: u32,
    h: *zkvm.Blake2fState,
    message: *const zkvm.Blake2fMessage,
    offset: *const zkvm.Blake2fOffset,
    final_block: u8,
) c_int {
    var input: [213]u8 = undefined;
    std.mem.writeInt(u32, input[0..4], rounds, .big);
    @memcpy(input[4..68], &h.data);
    @memcpy(input[68..196], &message.data);
    @memcpy(input[196..212], &offset.data);
    input[212] = final_block;
    return status(native.blake2f(rounds, final_block != 0, &input, &h.data));
}

pub export fn zkvm_kzg_point_eval(
    commitment: *const zkvm.KzgCommitment,
    z: *const zkvm.KzgFieldElement,
    y: *const zkvm.KzgFieldElement,
    proof: *const zkvm.KzgProof,
    verified: *bool,
) c_int {
    verified.* = native.kzgPointEvaluation(
        commitment.data,
        z.data,
        y.data,
        proof.data,
    ) == .ok;
    return zkvm.EOK;
}

pub export fn zkvm_bls12_g1_add(
    p1: *const zkvm.Bls12G1Point,
    p2: *const zkvm.Bls12G1Point,
    result: *zkvm.Bls12G1Point,
) c_int {
    var input: [256]u8 = undefined;
    expandG1(input[0..128], p1.data);
    expandG1(input[128..256], p2.data);
    var output: [128]u8 = undefined;
    if (native.bls12G1Add(&input, &output) != .ok) return zkvm.EFAIL;
    compactG1(&result.data, output);
    return zkvm.EOK;
}

pub export fn zkvm_bls12_g1_msm(
    pairs: [*]const zkvm.Bls12G1MsmPair,
    num_pairs: usize,
    result: *zkvm.Bls12G1Point,
) c_int {
    if (num_pairs == 0) {
        @memset(&result.data, 0);
        return zkvm.EOK;
    }
    const input = allocator.alloc(u8, num_pairs * 160) catch return zkvm.EFAIL;
    defer allocator.free(input);
    for (pairs[0..num_pairs], 0..) |pair, i| {
        const item = input[i * 160 ..][0..160];
        expandG1(item[0..128], pair.point.data);
        @memcpy(item[128..160], &pair.scalar.data);
    }
    var output: [128]u8 = undefined;
    const result_status = native.bls12G1Msm(allocator, input, &output) catch return zkvm.EFAIL;
    if (result_status != .ok) return zkvm.EFAIL;
    compactG1(&result.data, output);
    return zkvm.EOK;
}

pub export fn zkvm_bls12_g2_add(
    p1: *const zkvm.Bls12G2Point,
    p2: *const zkvm.Bls12G2Point,
    result: *zkvm.Bls12G2Point,
) c_int {
    var input: [512]u8 = undefined;
    expandG2(input[0..256], p1.data);
    expandG2(input[256..512], p2.data);
    var output: [256]u8 = undefined;
    if (native.bls12G2Add(&input, &output) != .ok) return zkvm.EFAIL;
    compactG2(&result.data, output);
    return zkvm.EOK;
}

pub export fn zkvm_bls12_g2_msm(
    pairs: [*]const zkvm.Bls12G2MsmPair,
    num_pairs: usize,
    result: *zkvm.Bls12G2Point,
) c_int {
    if (num_pairs == 0) {
        @memset(&result.data, 0);
        return zkvm.EOK;
    }
    const input = allocator.alloc(u8, num_pairs * 288) catch return zkvm.EFAIL;
    defer allocator.free(input);
    for (pairs[0..num_pairs], 0..) |pair, i| {
        const item = input[i * 288 ..][0..288];
        expandG2(item[0..256], pair.point.data);
        @memcpy(item[256..288], &pair.scalar.data);
    }
    var output: [256]u8 = undefined;
    const result_status = native.bls12G2Msm(allocator, input, &output) catch return zkvm.EFAIL;
    if (result_status != .ok) return zkvm.EFAIL;
    compactG2(&result.data, output);
    return zkvm.EOK;
}

pub export fn zkvm_bls12_pairing(
    pairs: [*]const zkvm.Bls12PairingPair,
    num_pairs: usize,
    verified: *bool,
) c_int {
    if (num_pairs == 0) {
        verified.* = true;
        return zkvm.EOK;
    }
    const input = allocator.alloc(u8, num_pairs * 384) catch return zkvm.EFAIL;
    defer allocator.free(input);
    for (pairs[0..num_pairs], 0..) |pair, i| {
        const item = input[i * 384 ..][0..384];
        expandG1(item[0..128], pair.g1.data);
        expandG2(item[128..384], pair.g2.data);
    }
    var output: [32]u8 = undefined;
    const result_status = native.bls12Pairing(allocator, input, &output) catch return zkvm.EFAIL;
    if (result_status != .ok) return zkvm.EFAIL;
    verified.* = output[31] != 0;
    return zkvm.EOK;
}

pub export fn zkvm_bls12_map_fp_to_g1(
    field_element: *const zkvm.Bls12Fp,
    result: *zkvm.Bls12G1Point,
) c_int {
    var input: [64]u8 = undefined;
    expandFp(&input, field_element.data);
    var output: [128]u8 = undefined;
    if (native.bls12MapFpToG1(&input, &output) != .ok) return zkvm.EFAIL;
    compactG1(&result.data, output);
    return zkvm.EOK;
}

pub export fn zkvm_bls12_map_fp2_to_g2(
    field_element: *const zkvm.Bls12Fp2,
    result: *zkvm.Bls12G2Point,
) c_int {
    var input: [128]u8 = undefined;
    expandFp2(&input, field_element.data);
    var output: [256]u8 = undefined;
    if (native.bls12MapFp2ToG2(&input, &output) != .ok) return zkvm.EFAIL;
    compactG2(&result.data, output);
    return zkvm.EOK;
}

fn status(result: native.Status) c_int {
    return if (result == .ok) zkvm.EOK else zkvm.EFAIL;
}

fn expandG1(output: []u8, input: [96]u8) void {
    expandFp(output[0..64], input[0..48].*);
    expandFp(output[64..128], input[48..96].*);
}

fn compactG1(output: *[96]u8, input: [128]u8) void {
    compactFp(output[0..48], input[0..64].*);
    compactFp(output[48..96], input[64..128].*);
}

fn expandG2(output: []u8, input: [192]u8) void {
    expandFp2(output[0..128], input[0..96].*);
    expandFp2(output[128..256], input[96..192].*);
}

fn compactG2(output: *[192]u8, input: [256]u8) void {
    compactFp2(output[0..96], input[0..128].*);
    compactFp2(output[96..192], input[128..256].*);
}

fn expandFp2(output: []u8, input: [96]u8) void {
    expandFp(output[0..64], input[0..48].*);
    expandFp(output[64..128], input[48..96].*);
}

fn compactFp2(output: []u8, input: [128]u8) void {
    compactFp(output[0..48], input[0..64].*);
    compactFp(output[48..96], input[64..128].*);
}

fn expandFp(output: []u8, input: [48]u8) void {
    @memset(output[0..16], 0);
    @memcpy(output[16..64], &input);
}

fn compactFp(output: []u8, input: [64]u8) void {
    std.debug.assert(std.mem.allEqual(u8, input[0..16], 0));
    @memcpy(output, input[16..64]);
}

fn verifySecp256k1(message: [32]u8, signature: [64]u8, public_key: [64]u8) bool {
    const Secp256k1 = std.crypto.ecc.Secp256k1;
    const Scalar = Secp256k1.scalar.Scalar;

    const r = Scalar.fromBytes(signature[0..32].*, .big) catch return false;
    const s = Scalar.fromBytes(signature[32..64].*, .big) catch return false;
    if (r.isZero() or s.isZero()) return false;

    const key = Secp256k1.fromSerializedAffineCoordinates(
        public_key[0..32].*,
        public_key[32..64].*,
        .big,
    ) catch return false;
    key.rejectIdentity() catch return false;

    const s_inverse = s.invert();
    const hash_scalar = secp256k1ScalarFromWord(message);
    const hash_factor = hash_scalar.mul(s_inverse).toBytes(.big);
    const r_factor = r.mul(s_inverse).toBytes(.big);
    const recovered = Secp256k1.mulDoubleBasePublic(
        Secp256k1.basePoint,
        hash_factor,
        key,
        r_factor,
        .big,
    ) catch return false;
    const recovered_x = recovered.affineCoordinates().x.toBytes(.big);
    return r.equivalent(secp256k1ScalarFromWord(recovered_x));
}

fn recoverSecp256k1(message: [32]u8, signature: [64]u8, recovery_id: u8) ?[64]u8 {
    if (recovery_id > 1) return null;

    const Secp256k1 = std.crypto.ecc.Secp256k1;
    const Scalar = Secp256k1.scalar.Scalar;
    const r = Scalar.fromBytes(signature[0..32].*, .big) catch return null;
    const s = Scalar.fromBytes(signature[32..64].*, .big) catch return null;
    if (r.isZero() or s.isZero()) return null;

    const x = Secp256k1.Fe.fromBytes(signature[0..32].*, .big) catch return null;
    const y = Secp256k1.recoverY(x, recovery_id == 1) catch return null;
    const recovery_point = Secp256k1.fromAffineCoordinates(.{ .x = x, .y = y }) catch return null;
    const r_inverse = r.invert();
    const base_scalar = secp256k1ScalarFromWord(message).mul(r_inverse).neg().toBytes(.big);
    const point_scalar = s.mul(r_inverse).toBytes(.big);
    const public_key = Secp256k1.mulDoubleBasePublic(
        Secp256k1.basePoint,
        base_scalar,
        recovery_point,
        point_scalar,
        .big,
    ) catch return null;
    public_key.rejectIdentity() catch return null;

    const uncompressed = public_key.toUncompressedSec1();
    return uncompressed[1..65].*;
}

fn secp256k1ScalarFromWord(word: [32]u8) std.crypto.ecc.Secp256k1.scalar.Scalar {
    var expanded = [_]u8{0} ** 64;
    @memcpy(expanded[32..64], &word);
    return std.crypto.ecc.Secp256k1.scalar.Scalar.fromBytes64(expanded, .big);
}

test "hash, RIPEMD padding, modexp, and BLAKE2f ABI semantics" {
    const empty = [_]u8{0};
    var hash: zkvm.Bytes32 = undefined;
    try std.testing.expectEqual(
        zkvm.EOK,
        zkvm_keccak256(&empty, 0, &hash),
    );
    try std.testing.expectEqualSlices(u8, &[_]u8{
        0xc5, 0xd2, 0x46, 0x01, 0x86, 0xf7, 0x23, 0x3c,
        0x92, 0x7e, 0x7d, 0xb2, 0xdc, 0xc7, 0x03, 0xc0,
        0xe5, 0x00, 0xb6, 0x53, 0xca, 0x82, 0x27, 0x3b,
        0x7b, 0xfa, 0xd8, 0x04, 0x5d, 0x85, 0xa4, 0x70,
    }, &hash.data);

    try std.testing.expectEqual(zkvm.EOK, zkvm_sha256(&empty, 0, &hash));
    try std.testing.expectEqualSlices(u8, &[_]u8{
        0xe3, 0xb0, 0xc4, 0x42, 0x98, 0xfc, 0x1c, 0x14,
        0x9a, 0xfb, 0xf4, 0xc8, 0x99, 0x6f, 0xb9, 0x24,
        0x27, 0xae, 0x41, 0xe4, 0x64, 0x9b, 0x93, 0x4c,
        0xa4, 0x95, 0x99, 0x1b, 0x78, 0x52, 0xb8, 0x55,
    }, &hash.data);

    try std.testing.expectEqual(zkvm.EOK, zkvm_ripemd160(&empty, 0, &hash));
    try std.testing.expectEqualSlices(u8, &([_]u8{0} ** 12), hash.data[0..12]);
    try std.testing.expectEqualSlices(u8, &[_]u8{
        0x9c, 0x11, 0x85, 0xa5, 0xc5, 0xe9, 0xfc, 0x54, 0x61, 0x28,
        0x08, 0x97, 0x7e, 0xe8, 0xf5, 0x48, 0xb2, 0x25, 0x8d, 0x31,
    }, hash.data[12..32]);

    const base = [_]u8{2};
    const exponent = [_]u8{5};
    const modulus = [_]u8{13};
    var modexp_output: [1]u8 = undefined;
    try std.testing.expectEqual(
        zkvm.EOK,
        zkvm_modexp(&base, 1, &exponent, 1, &modulus, 1, &modexp_output),
    );
    try std.testing.expectEqual(@as(u8, 6), modexp_output[0]);

    var h: zkvm.Blake2fState = .{ .data = [_]u8{0} ** 64 };
    const message: zkvm.Blake2fMessage = .{ .data = [_]u8{0} ** 128 };
    const offset: zkvm.Blake2fOffset = .{ .data = [_]u8{0} ** 16 };
    try std.testing.expectEqual(zkvm.EOK, zkvm_blake2f(0, &h, &message, &offset, 0));
    const iv = [_]u64{
        0x6a09e667f3bcc908,
        0xbb67ae8584caa73b,
        0x3c6ef372fe94f82b,
        0xa54ff53a5f1d36f1,
        0x510e527fade682d1,
        0x9b05688c2b3e6c1f,
        0x1f83d9abfb41bd6b,
        0x5be0cd19137e2179,
    };
    var expected_h: [64]u8 = undefined;
    for (iv, 0..) |word, i| {
        std.mem.writeInt(u64, expected_h[i * 8 ..][0..8], word, .little);
    }
    try std.testing.expectEqualSlices(u8, &expected_h, &h.data);
}

test "secp256k1 and secp256r1 verification ABI semantics" {
    const k1_public_key = keyFromLimbs(
        .{ 0x3bcfdc2aca47e0f2, 0xa739d5cc6b89e9b5, 0x35b73cc431afc6bc, 0xe1ea4273f638d4ae },
        .{ 0xc6402318ee33448e, 0x9f18c242b8df8bb6, 0x934a8dfdd797e1c4, 0x3840aa9c4d86557e },
    );
    const k1_message: zkvm.Secp256k1Hash = .{ .data = limbsToBe(
        .{ 0x1bf86a1816a52f52, 0xd31e26c3da73dda8, 0xa3b71997594da038, 0x17560495f6944673 },
    ) };
    var k1_signature: zkvm.Secp256k1Signature = .{ .data = signatureFromLimbs(
        .{ 0x68df7d8d7e0fb36b, 0xc2189fe681cd6e78, 0xc85ba1fd6238ecb5, 0x3e125456c8338994 },
        .{ 0xd4e89d1ae75aeea2, 0xb8e33178783bd1a3, 0x0866acebc9e141ec, 0x3a816b1c33739e41 },
    ) };
    const k1_key: zkvm.Secp256k1Pubkey = .{ .data = k1_public_key };
    var verified = false;
    try std.testing.expectEqual(
        zkvm.EOK,
        zkvm_secp256k1_verify(&k1_message, &k1_signature, &k1_key, &verified),
    );
    try std.testing.expect(verified);

    var recovered = false;
    for ([_]u8{ 0, 1 }) |recovery_id| {
        var output: zkvm.Secp256k1Pubkey = undefined;
        if (zkvm_secp256k1_ecrecover(&k1_message, &k1_signature, recovery_id, &output) ==
            zkvm.EOK and std.mem.eql(u8, &output.data, &k1_public_key))
        {
            recovered = true;
        }
    }
    try std.testing.expect(recovered);
    var output: zkvm.Secp256k1Pubkey = undefined;
    try std.testing.expectEqual(
        zkvm.EFAIL,
        zkvm_secp256k1_ecrecover(&k1_message, &k1_signature, 2, &output),
    );
    k1_signature.data[0] ^= 1;
    try std.testing.expectEqual(
        zkvm.EOK,
        zkvm_secp256k1_verify(&k1_message, &k1_signature, &k1_key, &verified),
    );
    try std.testing.expect(!verified);

    const r1_message: zkvm.Secp256r1Hash = .{ .data = limbsToBe(
        .{ 0x07a419feca605023, 0x0036e7c32b270c88, 0xed4361f59422a1e3, 0xbb5a52f42f9c9261 },
    ) };
    var r1_signature: zkvm.Secp256r1Signature = .{ .data = signatureFromLimbs(
        .{ 0xb8cc6af9bd5c2e18, 0xffe50d85a1eee859, 0x80a6d9d1190a436e, 0x2ba3a8be6b94d5ec },
        .{ 0x77a67f79e6fadd76, 0x525fe710fab9aa7c, 0x3c7b11eb6c4e0ae7, 0x4cd60b855d442f5b },
    ) };
    const r1_key: zkvm.Secp256r1Pubkey = .{ .data = keyFromLimbs(
        .{ 0x69c8c4df6c732838, 0x2903269919f70860, 0xdcfe467828128bad, 0x2927b10512bae3ed },
        .{ 0x8d1a974e7341513e, 0x6766b3d968500155, 0x921fb1498a60f460, 0xc7787964eaac00e5 },
    ) };
    try std.testing.expectEqual(
        zkvm.EOK,
        zkvm_secp256r1_verify(&r1_message, &r1_signature, &r1_key, &verified),
    );
    try std.testing.expect(verified);
    r1_signature.data[63] ^= 1;
    try std.testing.expectEqual(
        zkvm.EOK,
        zkvm_secp256r1_verify(&r1_message, &r1_signature, &r1_key, &verified),
    );
    try std.testing.expect(!verified);
}

test "BN254 and KZG accelerator ABI semantics" {
    const infinity: zkvm.Bn254G1Point = .{ .data = [_]u8{0} ** 64 };
    var result: zkvm.Bn254G1Point = .{ .data = [_]u8{0xff} ** 64 };
    try std.testing.expectEqual(
        zkvm.EOK,
        zkvm_bn254_g1_add(&infinity, &infinity, &result),
    );
    try std.testing.expectEqualSlices(u8, &infinity.data, &result.data);

    var generator: zkvm.Bn254G1Point = .{ .data = [_]u8{0} ** 64 };
    generator.data[31] = 1;
    generator.data[63] = 2;
    var one: zkvm.Bn254Scalar = .{ .data = [_]u8{0} ** 32 };
    one.data[31] = 1;
    try std.testing.expectEqual(
        zkvm.EOK,
        zkvm_bn254_g1_mul(&generator, &one, &result),
    );
    try std.testing.expectEqualSlices(u8, &generator.data, &result.data);

    const invalid: zkvm.Bn254G1Point = .{ .data = [_]u8{0xff} ** 64 };
    try std.testing.expectEqual(
        zkvm.EFAIL,
        zkvm_bn254_g1_add(&invalid, &infinity, &result),
    );
    const no_pairs = [_]zkvm.Bn254PairingPair{};
    var verified = false;
    try std.testing.expectEqual(
        zkvm.EOK,
        zkvm_bn254_pairing(&no_pairs, 0, &verified),
    );
    try std.testing.expect(verified);

    var commitment: zkvm.KzgCommitment = .{ .data = [_]u8{0} ** 48 };
    commitment.data[0] = 0xc0;
    const zero: zkvm.KzgFieldElement = .{ .data = [_]u8{0} ** 32 };
    var proof: zkvm.KzgProof = .{ .data = [_]u8{0} ** 48 };
    proof.data[0] = 0xc0;
    try std.testing.expectEqual(
        zkvm.EOK,
        zkvm_kzg_point_eval(&commitment, &zero, &zero, &proof, &verified),
    );
    try std.testing.expect(verified);
    proof.data[0] = 0;
    try std.testing.expectEqual(
        zkvm.EOK,
        zkvm_kzg_point_eval(&commitment, &zero, &zero, &proof, &verified),
    );
    try std.testing.expect(!verified);
}

test "BLS12 compact points, MSM, pairing, and map ABI semantics" {
    const g1_infinity: zkvm.Bls12G1Point = .{ .data = [_]u8{0} ** 96 };
    var g1: zkvm.Bls12G1Point = .{ .data = [_]u8{0xff} ** 96 };
    try std.testing.expectEqual(
        zkvm.EOK,
        zkvm_bls12_g1_add(&g1_infinity, &g1_infinity, &g1),
    );
    try std.testing.expectEqualSlices(u8, &g1_infinity.data, &g1.data);
    const no_g1_pairs = [_]zkvm.Bls12G1MsmPair{};
    try std.testing.expectEqual(
        zkvm.EOK,
        zkvm_bls12_g1_msm(&no_g1_pairs, 0, &g1),
    );
    try std.testing.expectEqualSlices(u8, &g1_infinity.data, &g1.data);

    const g2_infinity: zkvm.Bls12G2Point = .{ .data = [_]u8{0} ** 192 };
    var g2: zkvm.Bls12G2Point = .{ .data = [_]u8{0xff} ** 192 };
    try std.testing.expectEqual(
        zkvm.EOK,
        zkvm_bls12_g2_add(&g2_infinity, &g2_infinity, &g2),
    );
    try std.testing.expectEqualSlices(u8, &g2_infinity.data, &g2.data);
    const no_g2_pairs = [_]zkvm.Bls12G2MsmPair{};
    try std.testing.expectEqual(
        zkvm.EOK,
        zkvm_bls12_g2_msm(&no_g2_pairs, 0, &g2),
    );
    try std.testing.expectEqualSlices(u8, &g2_infinity.data, &g2.data);

    const no_pairings = [_]zkvm.Bls12PairingPair{};
    var verified = false;
    try std.testing.expectEqual(
        zkvm.EOK,
        zkvm_bls12_pairing(&no_pairings, 0, &verified),
    );
    try std.testing.expect(verified);

    const fp: zkvm.Bls12Fp = .{ .data = [_]u8{0} ** 48 };
    try std.testing.expectEqual(zkvm.EOK, zkvm_bls12_map_fp_to_g1(&fp, &g1));
    try std.testing.expect(!std.mem.allEqual(u8, &g1.data, 0));
    const fp2: zkvm.Bls12Fp2 = .{ .data = [_]u8{0} ** 96 };
    try std.testing.expectEqual(zkvm.EOK, zkvm_bls12_map_fp2_to_g2(&fp2, &g2));
    try std.testing.expect(!std.mem.allEqual(u8, &g2.data, 0));

    const invalid_fp: zkvm.Bls12Fp = .{ .data = [_]u8{0xff} ** 48 };
    try std.testing.expectEqual(
        zkvm.EFAIL,
        zkvm_bls12_map_fp_to_g1(&invalid_fp, &g1),
    );
}

fn limbsToBe(limbs: [4]u64) [32]u8 {
    var output: [32]u8 = undefined;
    for (limbs, 0..) |limb, i| {
        std.mem.writeInt(u64, output[(3 - i) * 8 ..][0..8], limb, .big);
    }
    return output;
}

fn signatureFromLimbs(r: [4]u64, s: [4]u64) [64]u8 {
    var output: [64]u8 = undefined;
    @memcpy(output[0..32], &limbsToBe(r));
    @memcpy(output[32..64], &limbsToBe(s));
    return output;
}

fn keyFromLimbs(x: [4]u64, y: [4]u64) [64]u8 {
    var output: [64]u8 = undefined;
    @memcpy(output[0..32], &limbsToBe(x));
    @memcpy(output[32..64], &limbsToBe(y));
    return output;
}
