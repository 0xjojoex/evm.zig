const std = @import("std");

pub const EOK: c_int = 0;
pub const EFAIL: c_int = -1;

const empty_input = [_]u8{0};

pub fn inputPtr(bytes: []const u8) [*]const u8 {
    return if (bytes.len == 0) empty_input[0..].ptr else bytes.ptr;
}

pub const Bytes16 = extern struct { data: [16]u8 align(8) };
pub const Bytes32 = extern struct { data: [32]u8 align(8) };
pub const Bytes48 = extern struct { data: [48]u8 align(8) };
pub const Bytes64 = extern struct { data: [64]u8 align(8) };
pub const Bytes96 = extern struct { data: [96]u8 align(8) };
pub const Bytes128 = extern struct { data: [128]u8 align(8) };
pub const Bytes192 = extern struct { data: [192]u8 align(8) };

pub const Keccak256Hash = Bytes32;
pub const Sha256Hash = Bytes32;
pub const Ripemd160Hash = Bytes32;

pub const Secp256k1Hash = Bytes32;
pub const Secp256k1Signature = Bytes64;
pub const Secp256k1Pubkey = Bytes64;

pub const Secp256r1Hash = Bytes32;
pub const Secp256r1Signature = Bytes64;
pub const Secp256r1Pubkey = Bytes64;

pub const Bn254G1Point = Bytes64;
pub const Bn254G2Point = Bytes128;
pub const Bn254Scalar = Bytes32;
pub const Bn254PairingPair = extern struct {
    g1: Bn254G1Point,
    g2: Bn254G2Point,
};

pub const Bls12G1Point = Bytes96;
pub const Bls12G2Point = Bytes192;
pub const Bls12Scalar = Bytes32;
pub const Bls12Fp = Bytes48;
pub const Bls12Fp2 = Bytes96;
pub const Bls12G1MsmPair = extern struct {
    point: Bls12G1Point,
    scalar: Bls12Scalar,
};
pub const Bls12G2MsmPair = extern struct {
    point: Bls12G2Point,
    scalar: Bls12Scalar,
};
pub const Bls12PairingPair = extern struct {
    g1: Bls12G1Point,
    g2: Bls12G2Point,
};

pub const Blake2fState = Bytes64;
pub const Blake2fMessage = Bytes128;
pub const Blake2fOffset = Bytes16;

pub const KzgCommitment = Bytes48;
pub const KzgProof = Bytes48;
pub const KzgFieldElement = Bytes32;

pub extern fn zkvm_keccak256(data: [*]const u8, len: usize, output: *Keccak256Hash) c_int;
pub extern fn zkvm_secp256k1_verify(
    msg: *const Secp256k1Hash,
    sig: *const Secp256k1Signature,
    pubkey: *const Secp256k1Pubkey,
    verified: *bool,
) c_int;

pub extern fn zkvm_secp256k1_ecrecover(
    msg: *const Secp256k1Hash,
    sig: *const Secp256k1Signature,
    recid: u8,
    output: *Secp256k1Pubkey,
) c_int;
pub extern fn zkvm_sha256(data: [*]const u8, len: usize, output: *Sha256Hash) c_int;
pub extern fn zkvm_ripemd160(data: [*]const u8, len: usize, output: *Ripemd160Hash) c_int;
pub extern fn zkvm_modexp(
    base: [*]const u8,
    base_len: usize,
    exp: [*]const u8,
    exp_len: usize,
    modulus: [*]const u8,
    mod_len: usize,
    output: [*]u8,
) c_int;
pub extern fn zkvm_bn254_g1_add(
    p1: *const Bn254G1Point,
    p2: *const Bn254G1Point,
    result: *Bn254G1Point,
) c_int;
pub extern fn zkvm_bn254_g1_mul(
    point: *const Bn254G1Point,
    scalar: *const Bn254Scalar,
    result: *Bn254G1Point,
) c_int;
pub extern fn zkvm_bn254_pairing(
    pairs: [*]const Bn254PairingPair,
    num_pairs: usize,
    verified: *bool,
) c_int;
pub extern fn zkvm_blake2f(
    rounds: u32,
    h: *Blake2fState,
    m: *const Blake2fMessage,
    t: *const Blake2fOffset,
    f: u8,
) c_int;
pub extern fn zkvm_kzg_point_eval(
    commitment: *const KzgCommitment,
    z: *const KzgFieldElement,
    y: *const KzgFieldElement,
    proof: *const KzgProof,
    verified: *bool,
) c_int;
pub extern fn zkvm_bls12_g1_add(
    p1: *const Bls12G1Point,
    p2: *const Bls12G1Point,
    result: *Bls12G1Point,
) c_int;
pub extern fn zkvm_bls12_g1_msm(
    pairs: [*]const Bls12G1MsmPair,
    num_pairs: usize,
    result: *Bls12G1Point,
) c_int;
pub extern fn zkvm_bls12_g2_add(
    p1: *const Bls12G2Point,
    p2: *const Bls12G2Point,
    result: *Bls12G2Point,
) c_int;
pub extern fn zkvm_bls12_g2_msm(
    pairs: [*]const Bls12G2MsmPair,
    num_pairs: usize,
    result: *Bls12G2Point,
) c_int;
pub extern fn zkvm_bls12_pairing(
    pairs: [*]const Bls12PairingPair,
    num_pairs: usize,
    verified: *bool,
) c_int;
pub extern fn zkvm_bls12_map_fp_to_g1(
    field_element: *const Bls12Fp,
    result: *Bls12G1Point,
) c_int;
pub extern fn zkvm_bls12_map_fp2_to_g2(
    field_element: *const Bls12Fp2,
    result: *Bls12G2Point,
) c_int;
pub extern fn zkvm_secp256r1_verify(
    msg: *const Secp256r1Hash,
    sig: *const Secp256r1Signature,
    pubkey: *const Secp256r1Pubkey,
    verified: *bool,
) c_int;

test "byte wrappers match zkvm_accelerators.h" {
    try expectAbi(Bytes16, 16);
    try expectAbi(Bytes32, 32);
    try expectAbi(Bytes48, 48);
    try expectAbi(Bytes64, 64);
    try expectAbi(Bytes96, 96);
    try expectAbi(Bytes128, 128);
    try expectAbi(Bytes192, 192);
}

test "composite wrappers match zkvm_accelerators.h" {
    try expectAbi(Bn254PairingPair, 192);
    try expectAbi(Bls12G1MsmPair, 128);
    try expectAbi(Bls12G2MsmPair, 224);
    try expectAbi(Bls12PairingPair, 288);
}

fn expectAbi(comptime T: type, comptime size: usize) !void {
    try std.testing.expectEqual(@as(usize, size), @sizeOf(T));
    try std.testing.expectEqual(@as(usize, 8), @alignOf(T));
}
