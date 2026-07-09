const std = @import("std");
const build_options = @import("build_options");
const zkvm = @import("../crypto/zkvm_accelerators.zig");

pub const backend_name = build_options.profile;
pub const Status = enum { ok, invalid, oom };

const Backend = if (std.mem.eql(u8, backend_name, "native"))
    NativeBackend
else if (std.mem.eql(u8, backend_name, "zkvm"))
    ZkvmBackend
else
    @compileError("unsupported profile '" ++ backend_name ++ "'");

pub fn ripemd160(input: []const u8, output: *[32]u8) Status {
    return Backend.ripemd160(input, output);
}

pub fn modexp(
    allocator: std.mem.Allocator,
    output: []u8,
    base: []const u8,
    exponent: []const u8,
    modulus: []const u8,
) std.mem.Allocator.Error!Status {
    return Backend.modexp(allocator, output, base, exponent, modulus);
}

pub fn bn254Add(input: []const u8, output: *[64]u8) Status {
    return Backend.bn254Add(input, output);
}

pub fn bn254Mul(input: []const u8, output: *[64]u8) Status {
    return Backend.bn254Mul(input, output);
}

pub fn bn254Pairing(allocator: std.mem.Allocator, input: []const u8, output: *[32]u8) std.mem.Allocator.Error!Status {
    return Backend.bn254Pairing(allocator, input, output);
}

pub fn kzgPointEvaluation(commitment: [48]u8, z: [32]u8, y: [32]u8, proof: [48]u8) Status {
    return Backend.kzgPointEvaluation(commitment, z, y, proof);
}

pub fn bls12G1Add(input: []const u8, output: *[128]u8) Status {
    return Backend.bls12G1Add(input, output);
}

pub fn bls12G1Msm(allocator: std.mem.Allocator, input: []const u8, output: *[128]u8) std.mem.Allocator.Error!Status {
    return Backend.bls12G1Msm(allocator, input, output);
}

pub fn bls12G2Add(input: []const u8, output: *[256]u8) Status {
    return Backend.bls12G2Add(input, output);
}

pub fn bls12G2Msm(allocator: std.mem.Allocator, input: []const u8, output: *[256]u8) std.mem.Allocator.Error!Status {
    return Backend.bls12G2Msm(allocator, input, output);
}

pub fn bls12Pairing(allocator: std.mem.Allocator, input: []const u8, output: *[32]u8) std.mem.Allocator.Error!Status {
    return Backend.bls12Pairing(allocator, input, output);
}

pub fn bls12MapFpToG1(input: []const u8, output: *[128]u8) Status {
    return Backend.bls12MapFpToG1(input, output);
}

pub fn bls12MapFp2ToG2(input: []const u8, output: *[256]u8) Status {
    return Backend.bls12MapFp2ToG2(input, output);
}

pub fn blake2f(rounds: u32, final_block: bool, input: []const u8, output: *[64]u8) Status {
    return Backend.blake2f(rounds, final_block, input, output);
}

pub fn p256Verify(input: []const u8) bool {
    return Backend.p256Verify(input);
}

fn statusFromZkvm(status: c_int) Status {
    return if (status == zkvm.EOK) .ok else .invalid;
}

fn evmBoolOutput(output: *[32]u8, value: bool) void {
    @memset(output, 0);
    output[31] = @intFromBool(value);
}

fn paddedCopy(input: []const u8, offset: usize, output: []u8) void {
    @memset(output, 0);
    if (offset >= input.len) return;
    const copied = @min(output.len, input.len - offset);
    @memcpy(output[0..copied], input[offset..][0..copied]);
}

const NativeBackend = struct {
    const ckzg = @import("ckzg");
    const kzg_trusted_setup = @import("kzg_trusted_setup");
    const bn254_native = @cImport({
        @cInclude("bn254.h");
    });
    const bls12_native = @cImport({
        @cInclude("bls12.h");
    });

    var kzg_settings: ckzg.Settings = .{};

    fn ripemd160(input: []const u8, output: *[32]u8) Status {
        const digest = ripemd160Digest(input);
        @memset(output[0..12], 0);
        @memcpy(output[12..32], &digest);
        return .ok;
    }

    fn modexp(
        allocator: std.mem.Allocator,
        output: []u8,
        base: []const u8,
        exponent: []const u8,
        modulus: []const u8,
    ) std.mem.Allocator.Error!Status {
        try modexpInto(allocator, output, base, exponent, modulus);
        return .ok;
    }

    fn bn254Add(input: []const u8, output: *[64]u8) Status {
        return if (bn254_native.evmz_bn254_add(input.ptr, input.len, output) == 0) .ok else .invalid;
    }

    fn bn254Mul(input: []const u8, output: *[64]u8) Status {
        return if (bn254_native.evmz_bn254_mul(input.ptr, input.len, output) == 0) .ok else .invalid;
    }

    fn bn254Pairing(_: std.mem.Allocator, input: []const u8, output: *[32]u8) std.mem.Allocator.Error!Status {
        return if (bn254_native.evmz_bn254_pairing_check(input.ptr, input.len, output) == 0) .ok else .invalid;
    }

    fn kzgPointEvaluation(commitment: [48]u8, z: [32]u8, y: [32]u8, proof: [48]u8) Status {
        const settings = kzgSettings() catch return .invalid;
        const ok = settings.verifyKzgProof(
            &ckzg.Bytes48{ .bytes = commitment },
            &ckzg.Bytes32{ .bytes = z },
            &ckzg.Bytes32{ .bytes = y },
            &ckzg.Bytes48{ .bytes = proof },
        ) catch false;
        return if (ok) .ok else .invalid;
    }

    fn bls12G1Add(input: []const u8, output: *[128]u8) Status {
        return bls12Status(bls12_native.evmz_bls12_g1_add(input.ptr, output));
    }

    fn bls12G1Msm(_: std.mem.Allocator, input: []const u8, output: *[128]u8) std.mem.Allocator.Error!Status {
        return bls12Status(bls12_native.evmz_bls12_g1_msm(input.ptr, input.len, output));
    }

    fn bls12G2Add(input: []const u8, output: *[256]u8) Status {
        return bls12Status(bls12_native.evmz_bls12_g2_add(input.ptr, output));
    }

    fn bls12G2Msm(_: std.mem.Allocator, input: []const u8, output: *[256]u8) std.mem.Allocator.Error!Status {
        return bls12Status(bls12_native.evmz_bls12_g2_msm(input.ptr, input.len, output));
    }

    fn bls12Pairing(_: std.mem.Allocator, input: []const u8, output: *[32]u8) std.mem.Allocator.Error!Status {
        return bls12Status(bls12_native.evmz_bls12_pairing_check(input.ptr, input.len, output));
    }

    fn bls12MapFpToG1(input: []const u8, output: *[128]u8) Status {
        return bls12Status(bls12_native.evmz_bls12_map_fp_to_g1(input.ptr, output));
    }

    fn bls12MapFp2ToG2(input: []const u8, output: *[256]u8) Status {
        return bls12Status(bls12_native.evmz_bls12_map_fp2_to_g2(input.ptr, output));
    }

    fn blake2f(rounds: u32, final_block: bool, input: []const u8, output: *[64]u8) Status {
        if (input.len != 213) return .invalid;

        var h: [8]u64 = undefined;
        for (&h, 0..) |*word, i| {
            const offset = 4 + i * 8;
            word.* = std.mem.readInt(u64, input[offset..][0..8], .little);
        }

        var m: [16]u64 = undefined;
        for (&m, 0..) |*word, i| {
            const offset = 68 + i * 8;
            word.* = std.mem.readInt(u64, input[offset..][0..8], .little);
        }

        const t0 = std.mem.readInt(u64, input[196..204], .little);
        const t1 = std.mem.readInt(u64, input[204..212], .little);
        blake2bCompress(rounds, &h, &m, .{ t0, t1 }, final_block);

        for (h, 0..) |word, i| {
            std.mem.writeInt(u64, output[i * 8 ..][0..8], word, .little);
        }
        return .ok;
    }

    fn p256Verify(input: []const u8) bool {
        if (input.len != 160) return false;

        const P256 = std.crypto.ecc.P256;
        const Scalar = P256.scalar.Scalar;

        const h = input[0..32].*;
        const r = Scalar.fromBytes(input[32..64].*, .big) catch return false;
        const s = Scalar.fromBytes(input[64..96].*, .big) catch return false;
        if (r.isZero() or s.isZero()) return false;

        const public_key = P256.fromSerializedAffineCoordinates(input[96..128].*, input[128..160].*, .big) catch return false;
        public_key.rejectIdentity() catch return false;

        const s_inverse = s.invert();
        const hash_scalar = p256ScalarFromWord(h);
        const h_factor = hash_scalar.mul(s_inverse).toBytes(.big);
        const r_factor = r.mul(s_inverse).toBytes(.big);
        const recovered = P256.mulDoubleBasePublic(P256.basePoint, h_factor, public_key, r_factor, .big) catch return false;
        const recovered_x = recovered.affineCoordinates().x.toBytes(.big);
        return r.equivalent(p256ScalarFromWord(recovered_x));
    }

    fn kzgSettings() !*const ckzg.Settings {
        if (!kzg_settings.loaded) {
            kzg_settings = try ckzg.Settings.loadTrustedSetup(
                kzg_trusted_setup.g1_monomial_bytes,
                kzg_trusted_setup.g1_lagrange_bytes,
                kzg_trusted_setup.g2_monomial_bytes,
                0,
            );
        }
        return &kzg_settings;
    }

    fn bls12Status(status_code: c_int) Status {
        return switch (status_code) {
            bls12_native.EVMZ_BLS12_OK => .ok,
            bls12_native.EVMZ_BLS12_INVALID => .invalid,
            bls12_native.EVMZ_BLS12_OOM => .oom,
            else => .invalid,
        };
    }

    fn p256ScalarFromWord(word: [32]u8) std.crypto.ecc.P256.scalar.Scalar {
        var expanded = [_]u8{0} ** 64;
        @memcpy(expanded[32..64], &word);
        return std.crypto.ecc.P256.scalar.Scalar.fromBytes64(expanded, .big);
    }
};

const ZkvmBackend = struct {
    fn ripemd160(input: []const u8, output: *[32]u8) Status {
        var digest: zkvm.Ripemd160Hash = undefined;
        const status = zkvm.zkvm_ripemd160(zkvm.inputPtr(input), input.len, &digest);
        if (status != zkvm.EOK) return .invalid;
        output.* = digest.data;
        return .ok;
    }

    fn modexp(
        _: std.mem.Allocator,
        output: []u8,
        base: []const u8,
        exponent: []const u8,
        modulus: []const u8,
    ) std.mem.Allocator.Error!Status {
        return statusFromZkvm(zkvm.zkvm_modexp(
            zkvm.inputPtr(base),
            base.len,
            zkvm.inputPtr(exponent),
            exponent.len,
            zkvm.inputPtr(modulus),
            modulus.len,
            output.ptr,
        ));
    }

    fn bn254Add(input: []const u8, output: *[64]u8) Status {
        var p1: zkvm.Bn254G1Point = undefined;
        var p2: zkvm.Bn254G1Point = undefined;
        var result: zkvm.Bn254G1Point = undefined;
        paddedCopy(input, 0, &p1.data);
        paddedCopy(input, 64, &p2.data);
        const status = zkvm.zkvm_bn254_g1_add(&p1, &p2, &result);
        if (status != zkvm.EOK) return .invalid;
        output.* = result.data;
        return .ok;
    }

    fn bn254Mul(input: []const u8, output: *[64]u8) Status {
        var point: zkvm.Bn254G1Point = undefined;
        var scalar: zkvm.Bn254Scalar = undefined;
        var result: zkvm.Bn254G1Point = undefined;
        paddedCopy(input, 0, &point.data);
        paddedCopy(input, 64, &scalar.data);
        const status = zkvm.zkvm_bn254_g1_mul(&point, &scalar, &result);
        if (status != zkvm.EOK) return .invalid;
        output.* = result.data;
        return .ok;
    }

    fn bn254Pairing(allocator: std.mem.Allocator, input: []const u8, output: *[32]u8) std.mem.Allocator.Error!Status {
        if (input.len % 192 != 0) return .invalid;
        const count = input.len / 192;
        if (count == 0) {
            evmBoolOutput(output, true);
            return .ok;
        }
        const pairs = try allocator.alloc(zkvm.Bn254PairingPair, count);
        defer allocator.free(pairs);
        for (pairs, 0..) |*pair, i| {
            const item = input[i * 192 ..][0..192];
            @memcpy(&pair.g1.data, item[0..64]);
            @memcpy(&pair.g2.data, item[64..192]);
        }
        var verified: bool = false;
        const status = zkvm.zkvm_bn254_pairing(pairs.ptr, count, &verified);
        if (status != zkvm.EOK) return .invalid;
        evmBoolOutput(output, verified);
        return .ok;
    }

    fn kzgPointEvaluation(commitment: [48]u8, z: [32]u8, y: [32]u8, proof: [48]u8) Status {
        var commitment_arg: zkvm.KzgCommitment = .{ .data = commitment };
        var z_arg: zkvm.KzgFieldElement = .{ .data = z };
        var y_arg: zkvm.KzgFieldElement = .{ .data = y };
        var proof_arg: zkvm.KzgProof = .{ .data = proof };
        var verified = false;
        const status = zkvm.zkvm_kzg_point_eval(&commitment_arg, &z_arg, &y_arg, &proof_arg, &verified);
        return if (status == zkvm.EOK and verified) .ok else .invalid;
    }

    fn bls12G1Add(input: []const u8, output: *[128]u8) Status {
        if (input.len != 256) return .invalid;
        var p1: zkvm.Bls12G1Point = undefined;
        var p2: zkvm.Bls12G1Point = undefined;
        var result: zkvm.Bls12G1Point = undefined;
        if (!compactG1(&p1, input[0..128]) or !compactG1(&p2, input[128..256])) return .invalid;
        if (zkvm.zkvm_bls12_g1_add(&p1, &p2, &result) != zkvm.EOK) return .invalid;
        expandG1(output, result);
        return .ok;
    }

    fn bls12G1Msm(allocator: std.mem.Allocator, input: []const u8, output: *[128]u8) std.mem.Allocator.Error!Status {
        if (input.len == 0 or input.len % 160 != 0) return .invalid;
        const count = input.len / 160;
        const pairs = try allocator.alloc(zkvm.Bls12G1MsmPair, count);
        defer allocator.free(pairs);
        for (pairs, 0..) |*pair, i| {
            const item = input[i * 160 ..][0..160];
            if (!compactG1(&pair.point, item[0..128])) return .invalid;
            @memcpy(&pair.scalar.data, item[128..160]);
        }
        var result: zkvm.Bls12G1Point = undefined;
        if (zkvm.zkvm_bls12_g1_msm(pairs.ptr, count, &result) != zkvm.EOK) return .invalid;
        expandG1(output, result);
        return .ok;
    }

    fn bls12G2Add(input: []const u8, output: *[256]u8) Status {
        if (input.len != 512) return .invalid;
        var p1: zkvm.Bls12G2Point = undefined;
        var p2: zkvm.Bls12G2Point = undefined;
        var result: zkvm.Bls12G2Point = undefined;
        if (!compactG2(&p1, input[0..256]) or !compactG2(&p2, input[256..512])) return .invalid;
        if (zkvm.zkvm_bls12_g2_add(&p1, &p2, &result) != zkvm.EOK) return .invalid;
        expandG2(output, result);
        return .ok;
    }

    fn bls12G2Msm(allocator: std.mem.Allocator, input: []const u8, output: *[256]u8) std.mem.Allocator.Error!Status {
        if (input.len == 0 or input.len % 288 != 0) return .invalid;
        const count = input.len / 288;
        const pairs = try allocator.alloc(zkvm.Bls12G2MsmPair, count);
        defer allocator.free(pairs);
        for (pairs, 0..) |*pair, i| {
            const item = input[i * 288 ..][0..288];
            if (!compactG2(&pair.point, item[0..256])) return .invalid;
            @memcpy(&pair.scalar.data, item[256..288]);
        }
        var result: zkvm.Bls12G2Point = undefined;
        if (zkvm.zkvm_bls12_g2_msm(pairs.ptr, count, &result) != zkvm.EOK) return .invalid;
        expandG2(output, result);
        return .ok;
    }

    fn bls12Pairing(allocator: std.mem.Allocator, input: []const u8, output: *[32]u8) std.mem.Allocator.Error!Status {
        if (input.len == 0 or input.len % 384 != 0) return .invalid;
        const count = input.len / 384;
        const pairs = try allocator.alloc(zkvm.Bls12PairingPair, count);
        defer allocator.free(pairs);
        for (pairs, 0..) |*pair, i| {
            const item = input[i * 384 ..][0..384];
            if (!compactG1(&pair.g1, item[0..128]) or !compactG2(&pair.g2, item[128..384])) return .invalid;
        }
        var verified: bool = false;
        if (zkvm.zkvm_bls12_pairing(pairs.ptr, count, &verified) != zkvm.EOK) return .invalid;
        evmBoolOutput(output, verified);
        return .ok;
    }

    fn bls12MapFpToG1(input: []const u8, output: *[128]u8) Status {
        if (input.len != 64) return .invalid;
        var fp: zkvm.Bls12Fp = undefined;
        var result: zkvm.Bls12G1Point = undefined;
        if (!compactFp(&fp.data, input)) return .invalid;
        if (zkvm.zkvm_bls12_map_fp_to_g1(&fp, &result) != zkvm.EOK) return .invalid;
        expandG1(output, result);
        return .ok;
    }

    fn bls12MapFp2ToG2(input: []const u8, output: *[256]u8) Status {
        if (input.len != 128) return .invalid;
        var fp2: zkvm.Bls12Fp2 = undefined;
        var result: zkvm.Bls12G2Point = undefined;
        if (!compactFp2(&fp2.data, input)) return .invalid;
        if (zkvm.zkvm_bls12_map_fp2_to_g2(&fp2, &result) != zkvm.EOK) return .invalid;
        expandG2(output, result);
        return .ok;
    }

    fn blake2f(rounds: u32, final_block: bool, input: []const u8, output: *[64]u8) Status {
        if (input.len != 213) return .invalid;
        var h: zkvm.Blake2fState = .{ .data = input[4..68].* };
        var m: zkvm.Blake2fMessage = .{ .data = input[68..196].* };
        var t: zkvm.Blake2fOffset = .{ .data = input[196..212].* };
        const status = zkvm.zkvm_blake2f(rounds, &h, &m, &t, @intFromBool(final_block));
        if (status != zkvm.EOK) return .invalid;
        output.* = h.data;
        return .ok;
    }

    fn p256Verify(input: []const u8) bool {
        if (input.len != 160) return false;
        var msg: zkvm.Secp256r1Hash = .{ .data = input[0..32].* };
        var sig: zkvm.Secp256r1Signature = undefined;
        var pubkey: zkvm.Secp256r1Pubkey = undefined;
        @memcpy(sig.data[0..32], input[32..64]);
        @memcpy(sig.data[32..64], input[64..96]);
        @memcpy(pubkey.data[0..32], input[96..128]);
        @memcpy(pubkey.data[32..64], input[128..160]);

        var verified = false;
        if (zkvm.zkvm_secp256r1_verify(&msg, &sig, &pubkey, &verified) != zkvm.EOK) return false;
        return verified;
    }

    fn compactG1(out: *zkvm.Bls12G1Point, input: []const u8) bool {
        return compactFp(out.data[0..48], input[0..64]) and compactFp(out.data[48..96], input[64..128]);
    }

    fn compactG2(out: *zkvm.Bls12G2Point, input: []const u8) bool {
        return compactFp2(out.data[0..96], input[0..128]) and compactFp2(out.data[96..192], input[128..256]);
    }

    fn compactFp2(out: []u8, input: []const u8) bool {
        return compactFp(out[0..48], input[0..64]) and compactFp(out[48..96], input[64..128]);
    }

    fn compactFp(out: []u8, input: []const u8) bool {
        std.debug.assert(out.len == 48);
        std.debug.assert(input.len == 64);
        if (!allZero(input[0..16])) return false;
        @memcpy(out, input[16..64]);
        return true;
    }

    fn expandG1(out: *[128]u8, input: zkvm.Bls12G1Point) void {
        expandFp(out[0..64], input.data[0..48]);
        expandFp(out[64..128], input.data[48..96]);
    }

    fn expandG2(out: *[256]u8, input: zkvm.Bls12G2Point) void {
        expandFp2(out[0..128], input.data[0..96]);
        expandFp2(out[128..256], input.data[96..192]);
    }

    fn expandFp2(out: []u8, input: []const u8) void {
        expandFp(out[0..64], input[0..48]);
        expandFp(out[64..128], input[48..96]);
    }

    fn expandFp(out: []u8, input: []const u8) void {
        std.debug.assert(out.len == 64);
        std.debug.assert(input.len == 48);
        @memset(out[0..16], 0);
        @memcpy(out[16..64], input);
    }
};

fn modexpInto(allocator: std.mem.Allocator, output: []u8, base_bytes: []const u8, exponent_bytes: []const u8, modulus_bytes: []const u8) std.mem.Allocator.Error!void {
    const BigInt = std.math.big.int.Managed;
    var modulus = try managedFromBytes(allocator, modulus_bytes);
    defer modulus.deinit();

    var base = try managedFromBytes(allocator, base_bytes);
    defer base.deinit();
    try reduceManaged(&base, &modulus);

    var result = try BigInt.initSet(allocator, 1);
    defer result.deinit();
    try reduceManaged(&result, &modulus);

    var product = try BigInt.init(allocator);
    defer product.deinit();
    var quotient = try BigInt.init(allocator);
    defer quotient.deinit();
    var remainder = try BigInt.init(allocator);
    defer remainder.deinit();

    for (exponent_bytes) |byte| {
        var mask: u8 = 0x80;
        while (mask != 0) : (mask >>= 1) {
            try mulMod(&result, &result, &result, &modulus, &product, &quotient, &remainder);
            if (byte & mask != 0) {
                try mulMod(&result, &result, &base, &modulus, &product, &quotient, &remainder);
            }
        }
    }

    result.toConst().writeTwosComplement(output, .big);
}

fn managedFromBytes(allocator: std.mem.Allocator, bytes: []const u8) std.mem.Allocator.Error!std.math.big.int.Managed {
    var value = try std.math.big.int.Managed.init(allocator);
    errdefer value.deinit();
    try value.ensureTwosCompCapacity(8 * bytes.len);
    var mutable = value.toMutable();
    mutable.readTwosComplement(bytes, 8 * bytes.len, .big, .unsigned);
    value.setMetadata(mutable.positive, mutable.len);
    return value;
}

fn reduceManaged(value: *std.math.big.int.Managed, modulus: *const std.math.big.int.Managed) std.mem.Allocator.Error!void {
    var quotient = try std.math.big.int.Managed.init(value.allocator);
    defer quotient.deinit();
    var remainder = try std.math.big.int.Managed.init(value.allocator);
    defer remainder.deinit();
    try std.math.big.int.Managed.divTrunc(&quotient, &remainder, value, modulus);
    value.swap(&remainder);
}

fn mulMod(
    target: *std.math.big.int.Managed,
    a: *const std.math.big.int.Managed,
    b: *const std.math.big.int.Managed,
    modulus: *const std.math.big.int.Managed,
    product: *std.math.big.int.Managed,
    quotient: *std.math.big.int.Managed,
    remainder: *std.math.big.int.Managed,
) std.mem.Allocator.Error!void {
    try std.math.big.int.Managed.mul(product, a, b);
    try std.math.big.int.Managed.divTrunc(quotient, remainder, product, modulus);
    target.swap(remainder);
}

const blake2b_iv = [8]u64{
    0x6a09e667f3bcc908,
    0xbb67ae8584caa73b,
    0x3c6ef372fe94f82b,
    0xa54ff53a5f1d36f1,
    0x510e527fade682d1,
    0x9b05688c2b3e6c1f,
    0x1f83d9abfb41bd6b,
    0x5be0cd19137e2179,
};

const blake2b_sigma = [10][16]u8{
    .{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15 },
    .{ 14, 10, 4, 8, 9, 15, 13, 6, 1, 12, 0, 2, 11, 7, 5, 3 },
    .{ 11, 8, 12, 0, 5, 2, 15, 13, 10, 14, 3, 6, 7, 1, 9, 4 },
    .{ 7, 9, 3, 1, 13, 12, 11, 14, 2, 6, 5, 10, 4, 0, 15, 8 },
    .{ 9, 0, 5, 7, 2, 4, 10, 15, 14, 1, 11, 12, 6, 8, 3, 13 },
    .{ 2, 12, 6, 10, 0, 11, 8, 3, 4, 13, 7, 5, 15, 14, 1, 9 },
    .{ 12, 5, 1, 15, 14, 13, 4, 10, 0, 7, 6, 3, 9, 2, 8, 11 },
    .{ 13, 11, 7, 14, 12, 1, 3, 9, 5, 0, 15, 4, 8, 6, 2, 10 },
    .{ 6, 15, 14, 9, 11, 3, 0, 8, 12, 2, 13, 7, 1, 4, 10, 5 },
    .{ 10, 2, 8, 4, 7, 6, 1, 5, 15, 11, 9, 14, 3, 12, 13, 0 },
};

const Blake2bRound = struct {
    a: usize,
    b: usize,
    c: usize,
    d: usize,
    x: usize,
    y: usize,
};

const blake2b_rounds = [_]Blake2bRound{
    .{ .a = 0, .b = 4, .c = 8, .d = 12, .x = 0, .y = 1 },
    .{ .a = 1, .b = 5, .c = 9, .d = 13, .x = 2, .y = 3 },
    .{ .a = 2, .b = 6, .c = 10, .d = 14, .x = 4, .y = 5 },
    .{ .a = 3, .b = 7, .c = 11, .d = 15, .x = 6, .y = 7 },
    .{ .a = 0, .b = 5, .c = 10, .d = 15, .x = 8, .y = 9 },
    .{ .a = 1, .b = 6, .c = 11, .d = 12, .x = 10, .y = 11 },
    .{ .a = 2, .b = 7, .c = 8, .d = 13, .x = 12, .y = 13 },
    .{ .a = 3, .b = 4, .c = 9, .d = 14, .x = 14, .y = 15 },
};

fn blake2bCompress(rounds: u32, h: *[8]u64, m: *const [16]u64, t: [2]u64, final_block: bool) void {
    var v: [16]u64 = undefined;
    for (0..8) |i| {
        v[i] = h[i];
        v[i + 8] = blake2b_iv[i];
    }

    v[12] ^= t[0];
    v[13] ^= t[1];
    if (final_block) v[14] = ~v[14];

    var i: u32 = 0;
    while (i < rounds) : (i += 1) {
        const sigma = blake2b_sigma[i % blake2b_sigma.len];
        inline for (blake2b_rounds) |r| {
            v[r.a] = v[r.a] +% v[r.b] +% m[sigma[r.x]];
            v[r.d] = std.math.rotr(u64, v[r.d] ^ v[r.a], 32);
            v[r.c] = v[r.c] +% v[r.d];
            v[r.b] = std.math.rotr(u64, v[r.b] ^ v[r.c], 24);
            v[r.a] = v[r.a] +% v[r.b] +% m[sigma[r.y]];
            v[r.d] = std.math.rotr(u64, v[r.d] ^ v[r.a], 16);
            v[r.c] = v[r.c] +% v[r.d];
            v[r.b] = std.math.rotr(u64, v[r.b] ^ v[r.c], 63);
        }
    }

    for (h, 0..) |*word, j| {
        word.* ^= v[j] ^ v[j + 8];
    }
}

const ripemd160_r1 = [80]usize{
    0, 1,  2,  3,  4,  5,  6,  7,  8,  9, 10, 11, 12, 13, 14, 15,
    7, 4,  13, 1,  10, 6,  15, 3,  12, 0, 9,  5,  2,  14, 11, 8,
    3, 10, 14, 4,  9,  15, 8,  1,  2,  7, 0,  6,  13, 11, 5,  12,
    1, 9,  11, 10, 0,  8,  12, 4,  13, 3, 7,  15, 14, 5,  6,  2,
    4, 0,  5,  9,  7,  12, 2,  10, 14, 1, 3,  8,  11, 6,  15, 13,
};

const ripemd160_r2 = [80]usize{
    5,  14, 7,  0, 9, 2,  11, 4,  13, 6,  15, 8,  1,  10, 3,  12,
    6,  11, 3,  7, 0, 13, 5,  10, 14, 15, 8,  12, 4,  9,  1,  2,
    15, 5,  1,  3, 7, 14, 6,  9,  11, 8,  12, 2,  10, 0,  4,  13,
    8,  6,  4,  1, 3, 11, 15, 0,  5,  12, 2,  13, 9,  7,  10, 14,
    12, 15, 10, 4, 1, 5,  8,  7,  6,  2,  13, 14, 0,  3,  9,  11,
};

const ripemd160_s1 = [80]u5{
    11, 14, 15, 12, 5,  8,  7,  9,  11, 13, 14, 15, 6,  7,  9,  8,
    7,  6,  8,  13, 11, 9,  7,  15, 7,  12, 15, 9,  11, 7,  13, 12,
    11, 13, 6,  7,  14, 9,  13, 15, 14, 8,  13, 6,  5,  12, 7,  5,
    11, 12, 14, 15, 14, 15, 9,  8,  9,  14, 5,  6,  8,  6,  5,  12,
    9,  15, 5,  11, 6,  8,  13, 12, 5,  12, 13, 14, 11, 8,  5,  6,
};

const ripemd160_s2 = [80]u5{
    8,  9,  9,  11, 13, 15, 15, 5,  7,  7,  8,  11, 14, 14, 12, 6,
    9,  13, 15, 7,  12, 8,  9,  11, 7,  7,  12, 7,  6,  15, 13, 11,
    9,  7,  15, 11, 8,  6,  6,  14, 12, 13, 5,  14, 13, 13, 7,  5,
    15, 5,  8,  11, 14, 14, 6,  14, 6,  9,  12, 9,  12, 5,  15, 8,
    8,  5,  12, 9,  12, 5,  14, 6,  8,  13, 6,  5,  15, 13, 11, 11,
};

fn ripemd160Digest(input: []const u8) [20]u8 {
    var state = [_]u32{
        0x67452301,
        0xefcdab89,
        0x98badcfe,
        0x10325476,
        0xc3d2e1f0,
    };

    var offset: usize = 0;
    while (offset + 64 <= input.len) : (offset += 64) {
        ripemd160Compress(&state, input[offset..][0..64]);
    }

    var block = [_]u8{0} ** 128;
    const remaining = input[offset..];
    @memcpy(block[0..remaining.len], remaining);
    block[remaining.len] = 0x80;

    const bit_len = @as(u64, @truncate(@as(u128, input.len) * 8));
    const len_offset: usize = if (remaining.len < 56) 56 else 120;
    std.mem.writeInt(u64, block[len_offset..][0..8], bit_len, .little);
    ripemd160Compress(&state, block[0..64]);
    if (len_offset == 120) {
        ripemd160Compress(&state, block[64..128]);
    }

    var digest: [20]u8 = undefined;
    inline for (0..5) |i| {
        std.mem.writeInt(u32, digest[i * 4 ..][0..4], state[i], .little);
    }
    return digest;
}

fn ripemd160Compress(state: *[5]u32, block: *const [64]u8) void {
    var words: [16]u32 = undefined;
    inline for (0..16) |i| {
        words[i] = std.mem.readInt(u32, block[i * 4 ..][0..4], .little);
    }

    var al = state[0];
    var bl = state[1];
    var cl = state[2];
    var dl = state[3];
    var el = state[4];

    var ar = state[0];
    var br = state[1];
    var cr = state[2];
    var dr = state[3];
    var er = state[4];

    inline for (0..80) |i| {
        const left = std.math.rotl(
            u32,
            al +% ripemd160Left(i, bl, cl, dl) +% words[ripemd160_r1[i]] +% ripemd160LeftK(i),
            ripemd160_s1[i],
        ) +% el;
        al = el;
        el = dl;
        dl = std.math.rotl(u32, cl, 10);
        cl = bl;
        bl = left;

        const right = std.math.rotl(
            u32,
            ar +% ripemd160Right(i, br, cr, dr) +% words[ripemd160_r2[i]] +% ripemd160RightK(i),
            ripemd160_s2[i],
        ) +% er;
        ar = er;
        er = dr;
        dr = std.math.rotl(u32, cr, 10);
        cr = br;
        br = right;
    }

    const t = state[1] +% cl +% dr;
    state[1] = state[2] +% dl +% er;
    state[2] = state[3] +% el +% ar;
    state[3] = state[4] +% al +% br;
    state[4] = state[0] +% bl +% cr;
    state[0] = t;
}

fn ripemd160Left(round: usize, x: u32, y: u32, z: u32) u32 {
    return switch (round) {
        0...15 => x ^ y ^ z,
        16...31 => (x & y) | (~x & z),
        32...47 => (x | ~y) ^ z,
        48...63 => (x & z) | (y & ~z),
        64...79 => x ^ (y | ~z),
        else => unreachable,
    };
}

fn ripemd160Right(round: usize, x: u32, y: u32, z: u32) u32 {
    return switch (round) {
        0...15 => x ^ (y | ~z),
        16...31 => (x & z) | (y & ~z),
        32...47 => (x | ~y) ^ z,
        48...63 => (x & y) | (~x & z),
        64...79 => x ^ y ^ z,
        else => unreachable,
    };
}

fn ripemd160LeftK(round: usize) u32 {
    return switch (round) {
        0...15 => 0x00000000,
        16...31 => 0x5a827999,
        32...47 => 0x6ed9eba1,
        48...63 => 0x8f1bbcdc,
        64...79 => 0xa953fd4e,
        else => unreachable,
    };
}

fn ripemd160RightK(round: usize) u32 {
    return switch (round) {
        0...15 => 0x50a28be6,
        16...31 => 0x5c4dd124,
        32...47 => 0x6d703ef3,
        48...63 => 0x7a6d76e9,
        64...79 => 0x00000000,
        else => unreachable,
    };
}

fn allZero(bytes: []const u8) bool {
    for (bytes) |byte| {
        if (byte != 0) return false;
    }
    return true;
}

test "RIPEMD-160 vectors" {
    try std.testing.expectEqualSlices(u8, &[_]u8{
        0x9c, 0x11, 0x85, 0xa5, 0xc5, 0xe9, 0xfc, 0x54,
        0x61, 0x28, 0x08, 0x97, 0x7e, 0xe8, 0xf5, 0x48,
        0xb2, 0x25, 0x8d, 0x31,
    }, &ripemd160Digest(""));
    try std.testing.expectEqualSlices(u8, &[_]u8{
        0x0b, 0xdc, 0x9d, 0x2d, 0x25, 0x6b, 0x3e, 0xe9,
        0xda, 0xae, 0x34, 0x7b, 0xe6, 0xf4, 0xdc, 0x83,
        0x5a, 0x46, 0x7f, 0xfe,
    }, &ripemd160Digest("a"));
    try std.testing.expectEqualSlices(u8, &[_]u8{
        0x8e, 0xb2, 0x08, 0xf7, 0xe0, 0x5d, 0x98, 0x7a,
        0x9b, 0x04, 0x4a, 0x8e, 0x98, 0xc6, 0xb0, 0x87,
        0xf1, 0x5a, 0x0b, 0xfc,
    }, &ripemd160Digest("abc"));
    try std.testing.expectEqualSlices(u8, &[_]u8{
        0x5d, 0x06, 0x89, 0xef, 0x49, 0xd2, 0xfa, 0xe5,
        0x72, 0xb8, 0x81, 0xb1, 0x23, 0xa8, 0x5f, 0xfa,
        0x21, 0x59, 0x5f, 0x36,
    }, &ripemd160Digest("message digest"));
}

test "BLS12 zkvm adapter rejects non-zero EVM field padding" {
    var evm_fp = [_]u8{0} ** 64;
    var compact = [_]u8{0} ** 48;
    try std.testing.expect(ZkvmBackend.compactFp(&compact, &evm_fp));

    evm_fp[15] = 1;
    try std.testing.expect(!ZkvmBackend.compactFp(&compact, &evm_fp));
}

test "BLS12 zkvm adapter compacts and expands G1 points" {
    var evm_g1 = [_]u8{0} ** 128;
    for (0..48) |i| {
        evm_g1[16 + i] = @intCast(i + 1);
        evm_g1[80 + i] = @intCast(0x80 + i);
    }

    var compact: zkvm.Bls12G1Point = undefined;
    try std.testing.expect(ZkvmBackend.compactG1(&compact, &evm_g1));
    try std.testing.expectEqualSlices(u8, evm_g1[16..64], compact.data[0..48]);
    try std.testing.expectEqualSlices(u8, evm_g1[80..128], compact.data[48..96]);

    var expanded: [128]u8 = undefined;
    ZkvmBackend.expandG1(&expanded, compact);
    try std.testing.expectEqualSlices(u8, &evm_g1, &expanded);
}
