const std = @import("std");
const address = @import("address.zig");
const Spec = @import("spec.zig").Spec;
const uint256 = @import("uint256.zig");
const ckzg = @import("ckzg");
const kzg_trusted_setup = @import("kzg_trusted_setup");
const bn254_native = @cImport({
    @cInclude("bn254.h");
});
const bls12_native = @cImport({
    @cInclude("bls12.h");
});

const Address = address.Address;
const modexp_osaka_max_input_len: u256 = 1024;
const p256verify_gas: i64 = 6900;

pub const Error = std.mem.Allocator.Error || error{
    NotImplemented,
};

pub const Status = enum(u8) {
    success,
    failure,
    out_of_gas,
};

pub const Result = struct {
    status: Status,
    output_data: []u8,
    gas_left: i64,
};

pub const Call = struct {
    allocator: std.mem.Allocator,
    spec: Spec,
    input_data: []const u8,
    gas: i64,
};

pub const Contract = enum(u16) {
    ecrecover = 0x01,
    sha256 = 0x02,
    ripemd160 = 0x03,
    identity = 0x04,
    modexp = 0x05,
    bn254_add = 0x06,
    bn254_mul = 0x07,
    bn254_pairing = 0x08,
    blake2f = 0x09,
    kzg_point_evaluation = 0x0a,
    bls12_g1add = 0x0b,
    bls12_g1msm = 0x0c,
    bls12_g2add = 0x0d,
    bls12_g2msm = 0x0e,
    bls12_pairing_check = 0x0f,
    bls12_map_fp_to_g1 = 0x10,
    bls12_map_fp2_to_g2 = 0x11,
    p256verify = 0x100,

    pub fn toAddress(c: Contract) Address {
        return address.addr(@as(u160, @intFromEnum(c)));
    }
    pub fn minimumSpec(c: Contract) Spec {
        return switch (c) {
            .ecrecover,
            .sha256,
            .ripemd160,
            .identity,
            => .frontier,

            .modexp,
            .bn254_add,
            .bn254_mul,
            .bn254_pairing,
            => .byzantium,

            .blake2f => .istanbul,
            .kzg_point_evaluation => .cancun,

            .bls12_g1add,
            .bls12_g1msm,
            .bls12_g2add,
            .bls12_g2msm,
            .bls12_pairing_check,
            .bls12_map_fp_to_g1,
            .bls12_map_fp2_to_g2,
            => .prague,

            .p256verify => .osaka,
        };
    }
};

pub fn activeAt(spec: Spec, target: Address) ?Contract {
    const contract = contractFromAddress(target) orelse return null;
    if (!spec.isImpl(contract.minimumSpec())) return null;
    return contract;
}

pub fn execute(allocator: std.mem.Allocator, spec: Spec, target: Address, input_data: []const u8, gas: i64) Error!?Result {
    const contract = activeAt(spec, target) orelse return null;
    return try dispatch(contract, .{
        .allocator = allocator,
        .spec = spec,
        .input_data = input_data,
        .gas = gas,
    });
}

fn dispatch(contract: Contract, call: Call) Error!Result {
    return switch (contract) {
        .ecrecover => ecrecover(call),
        .sha256 => sha256(call),
        .ripemd160 => ripemd160(call),
        .identity => identity(call),
        .modexp => modexp(call),
        .bn254_add => bn254Add(call),
        .bn254_mul => bn254Mul(call),
        .bn254_pairing => bn254Pairing(call),
        .blake2f => blake2f(call),
        .kzg_point_evaluation => kzgPointEvaluation(call),
        .bls12_g1add => bls12G1Add(call),
        .bls12_g1msm => bls12G1Msm(call),
        .bls12_g2add => bls12G2Add(call),
        .bls12_g2msm => bls12G2Msm(call),
        .bls12_pairing_check => bls12PairingCheck(call),
        .bls12_map_fp_to_g1 => bls12MapFpToG1(call),
        .bls12_map_fp2_to_g2 => bls12MapFp2ToG2(call),
        .p256verify => p256Verify(call),
    };
}

fn contractFromAddress(target: Address) ?Contract {
    const contract_id = std.mem.readInt(u160, &target, .big);
    if (contract_id > std.math.maxInt(u16)) return null;
    return switch (@as(u16, @intCast(contract_id))) {
        0x01 => .ecrecover,
        0x02 => .sha256,
        0x03 => .ripemd160,
        0x04 => .identity,
        0x05 => .modexp,
        0x06 => .bn254_add,
        0x07 => .bn254_mul,
        0x08 => .bn254_pairing,
        0x09 => .blake2f,
        0x0a => .kzg_point_evaluation,
        0x0b => .bls12_g1add,
        0x0c => .bls12_g1msm,
        0x0d => .bls12_g2add,
        0x0e => .bls12_g2msm,
        0x0f => .bls12_pairing_check,
        0x10 => .bls12_map_fp_to_g1,
        0x11 => .bls12_map_fp2_to_g2,
        0x100 => .p256verify,
        else => null,
    };
}

fn emptyResult(status: Status) Result {
    return .{
        .status = status,
        .output_data = &.{},
        .gas_left = 0,
    };
}

fn wordSize(byte_count: usize) ?i64 {
    const words = byte_count / 32 + @intFromBool(byte_count % 32 != 0);
    return std.math.cast(i64, words);
}

fn linearCost(byte_count: usize, base: i64, per_word: i64) ?i64 {
    const words = wordSize(byte_count) orelse return null;
    const variable = std.math.mul(i64, per_word, words) catch return null;
    return std.math.add(i64, base, variable) catch null;
}

fn charge(call: Call, cost: i64) ?i64 {
    if (call.gas < cost) return null;
    return call.gas - cost;
}

fn ecrecover(call: Call) Error!Result {
    const gas_left = charge(call, 3000) orelse return emptyResult(.out_of_gas);
    const recovered = recoverAddress(call.input_data) orelse {
        return .{
            .status = .success,
            .output_data = &.{},
            .gas_left = gas_left,
        };
    };

    const output = try call.allocator.alloc(u8, 32);
    @memset(output[0..12], 0);
    @memcpy(output[12..32], &recovered);
    return .{
        .status = .success,
        .output_data = output,
        .gas_left = gas_left,
    };
}

fn sha256(call: Call) Error!Result {
    const cost = linearCost(call.input_data.len, 60, 12) orelse return emptyResult(.out_of_gas);
    const gas_left = charge(call, cost) orelse return emptyResult(.out_of_gas);

    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(call.input_data, &digest, .{});
    const output = try call.allocator.dupe(u8, &digest);
    return .{
        .status = .success,
        .output_data = output,
        .gas_left = gas_left,
    };
}

fn ripemd160(call: Call) Error!Result {
    const cost = linearCost(call.input_data.len, 600, 120) orelse return emptyResult(.out_of_gas);
    const gas_left = charge(call, cost) orelse return emptyResult(.out_of_gas);

    const digest = ripemd160Digest(call.input_data);
    const output = try call.allocator.alloc(u8, 32);
    @memset(output[0..12], 0);
    @memcpy(output[12..32], &digest);
    return .{
        .status = .success,
        .output_data = output,
        .gas_left = gas_left,
    };
}

fn identity(call: Call) Error!Result {
    const cost = linearCost(call.input_data.len, 15, 3) orelse return emptyResult(.out_of_gas);
    const gas_left = charge(call, cost) orelse return emptyResult(.out_of_gas);
    return .{
        .status = .success,
        .output_data = try call.allocator.dupe(u8, call.input_data),
        .gas_left = gas_left,
    };
}

fn modexp(call: Call) Error!Result {
    const base_len = std.mem.readInt(u256, &paddedWord(call.input_data, 0), .big);
    const exponent_len = std.mem.readInt(u256, &paddedWord(call.input_data, 1), .big);
    const modulus_len = std.mem.readInt(u256, &paddedWord(call.input_data, 2), .big);
    if (call.spec.isImpl(.osaka) and !modexpLengthsWithinOsakaLimit(base_len, exponent_len, modulus_len)) {
        return emptyResult(.out_of_gas);
    }

    const exponent_offset = uint256.checkedAdd(96, base_len) orelse return emptyResult(.out_of_gas);
    const exponent_head = modexpExponentHead(call.input_data, exponent_offset, exponent_len);
    const cost = modexpGas(call.spec, base_len, exponent_len, modulus_len, exponent_head) orelse {
        return emptyResult(.out_of_gas);
    };
    const gas_left = charge(call, cost) orelse return emptyResult(.out_of_gas);

    const modulus_len_usize = std.math.cast(usize, modulus_len) orelse return emptyResult(.out_of_gas);
    if (modulus_len_usize == 0) {
        return .{
            .status = .success,
            .output_data = &.{},
            .gas_left = gas_left,
        };
    }

    const base_len_usize = std.math.cast(usize, base_len) orelse return emptyResult(.out_of_gas);
    const exponent_len_usize = std.math.cast(usize, exponent_len) orelse return emptyResult(.out_of_gas);
    const base_offset: usize = 96;
    const exponent_offset_usize = std.math.add(usize, base_offset, base_len_usize) catch {
        return emptyResult(.out_of_gas);
    };
    const modulus_offset = std.math.add(usize, exponent_offset_usize, exponent_len_usize) catch {
        return emptyResult(.out_of_gas);
    };

    const base_bytes = try paddedBytes(call.allocator, call.input_data, base_offset, base_len_usize);
    defer call.allocator.free(base_bytes);
    const exponent_bytes = try paddedBytes(call.allocator, call.input_data, exponent_offset_usize, exponent_len_usize);
    defer call.allocator.free(exponent_bytes);
    const modulus_bytes = try paddedBytes(call.allocator, call.input_data, modulus_offset, modulus_len_usize);
    defer call.allocator.free(modulus_bytes);

    const output = try call.allocator.alloc(u8, modulus_len_usize);
    @memset(output, 0);
    if (allZero(modulus_bytes)) {
        return .{
            .status = .success,
            .output_data = output,
            .gas_left = gas_left,
        };
    }

    try modexpInto(call.allocator, output, base_bytes, exponent_bytes, modulus_bytes);
    return .{
        .status = .success,
        .output_data = output,
        .gas_left = gas_left,
    };
}

fn modexpGas(spec: Spec, base_len: u256, exponent_len: u256, modulus_len: u256, exponent_head: u256) ?i64 {
    const max_len = @max(base_len, modulus_len);
    if (spec.isImpl(.osaka)) {
        const complexity = modexpOsakaMultComplexity(max_len) orelse return null;
        const iteration_count = modexpOsakaIterationCount(exponent_len, exponent_head) orelse return null;
        const cost = uint256.checkedMul(complexity, iteration_count) orelse return null;
        return std.math.cast(i64, @max(cost, 500));
    }

    if (spec.isImpl(.berlin)) {
        const words = uint256.ceilDiv(max_len, 8);
        const complexity = uint256.checkedMul(words, words) orelse return null;
        if (complexity == 0) return 200;
        const iteration_count = adjustedExponentLength(exponent_len, exponent_head) orelse return null;
        const iterations = @max(iteration_count, 1);
        const numerator = uint256.checkedMul(complexity, iterations) orelse return null;
        const cost = @max(@divFloor(numerator, 3), 200);
        return std.math.cast(i64, cost);
    }

    const complexity = eip198MultComplexity(max_len) orelse return null;
    if (complexity == 0) return 0;
    const iteration_count = adjustedExponentLength(exponent_len, exponent_head) orelse return null;
    const iterations = @max(iteration_count, 1);
    const numerator = uint256.checkedMul(complexity, iterations) orelse return null;
    const cost = @divFloor(numerator, 20);
    return std.math.cast(i64, cost);
}

fn modexpLengthsWithinOsakaLimit(base_len: u256, exponent_len: u256, modulus_len: u256) bool {
    return base_len <= modexp_osaka_max_input_len and
        exponent_len <= modexp_osaka_max_input_len and
        modulus_len <= modexp_osaka_max_input_len;
}

fn modexpOsakaMultComplexity(max_len: u256) ?u256 {
    if (max_len <= 32) return 16;
    const words = uint256.ceilDiv(max_len, 8);
    const square = uint256.checkedMul(words, words) orelse return null;
    return uint256.checkedMul(2, square);
}

fn modexpOsakaIterationCount(exponent_len: u256, exponent_head: u256) ?u256 {
    const bit_len = uint256.bitLength(exponent_head);
    if (exponent_len <= 32) {
        if (bit_len == 0) return 1;
        return @max(@as(u256, bit_len - 1), 1);
    }

    const tail = uint256.checkedMul(16, exponent_len - 32) orelse return null;
    const adjusted = if (bit_len == 0)
        tail
    else
        uint256.checkedAdd(tail, bit_len - 1) orelse return null;
    return @max(adjusted, 1);
}

fn eip198MultComplexity(x: u256) ?u256 {
    const square = uint256.checkedMul(x, x) orelse return null;
    if (x <= 64) return square;
    if (x <= 1024) {
        const linear = uint256.checkedMul(96, x) orelse return null;
        const combined = uint256.checkedAdd(@divFloor(square, 4), linear) orelse return null;
        return combined - 3072;
    }

    const linear = uint256.checkedMul(480, x) orelse return null;
    const combined = uint256.checkedAdd(@divFloor(square, 16), linear) orelse return null;
    return combined - 199680;
}

fn adjustedExponentLength(exponent_len: u256, exponent_head: u256) ?u256 {
    const bit_len = uint256.bitLength(exponent_head);
    if (exponent_len <= 32) {
        if (bit_len == 0) return 0;
        return bit_len - 1;
    }

    const tail = uint256.checkedMul(8, exponent_len - 32) orelse return null;
    if (bit_len == 0) return tail;
    return uint256.checkedAdd(tail, bit_len - 1);
}

fn modexpExponentHead(input: []const u8, exponent_offset: u256, exponent_len: u256) u256 {
    var word = [_]u8{0} ** 32;
    const offset = std.math.cast(usize, exponent_offset) orelse return 0;
    if (offset >= input.len or exponent_len == 0) return 0;

    if (exponent_len <= 32) {
        const len = std.math.cast(usize, exponent_len).?;
        const copied = @min(len, input.len - offset);
        @memcpy(word[32 - len ..][0..copied], input[offset..][0..copied]);
    } else {
        const copied = @min(32, input.len - offset);
        @memcpy(word[0..copied], input[offset..][0..copied]);
    }
    return std.mem.readInt(u256, &word, .big);
}

fn paddedBytes(allocator: std.mem.Allocator, input: []const u8, offset: usize, len: usize) ![]u8 {
    const bytes = try allocator.alloc(u8, len);
    @memset(bytes, 0);
    if (offset < input.len) {
        const copied = @min(len, input.len - offset);
        @memcpy(bytes[0..copied], input[offset..][0..copied]);
    }
    return bytes;
}

fn allZero(bytes: []const u8) bool {
    for (bytes) |byte| {
        if (byte != 0) return false;
    }
    return true;
}

fn modexpInto(allocator: std.mem.Allocator, output: []u8, base_bytes: []const u8, exponent_bytes: []const u8, modulus_bytes: []const u8) !void {
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

fn managedFromBytes(allocator: std.mem.Allocator, bytes: []const u8) !std.math.big.int.Managed {
    var value = try std.math.big.int.Managed.init(allocator);
    errdefer value.deinit();
    try value.ensureTwosCompCapacity(8 * bytes.len);
    var mutable = value.toMutable();
    mutable.readTwosComplement(bytes, 8 * bytes.len, .big, .unsigned);
    value.setMetadata(mutable.positive, mutable.len);
    return value;
}

fn reduceManaged(value: *std.math.big.int.Managed, modulus: *const std.math.big.int.Managed) !void {
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
) !void {
    try std.math.big.int.Managed.mul(product, a, b);
    try std.math.big.int.Managed.divTrunc(quotient, remainder, product, modulus);
    target.swap(remainder);
}

fn bn254Add(call: Call) Error!Result {
    const gas_left = charge(call, bn254AddGas(call.spec)) orelse return emptyResult(.out_of_gas);
    const output = try call.allocator.alloc(u8, 64);
    errdefer call.allocator.free(output);
    if (bn254_native.evmz_bn254_add(call.input_data.ptr, call.input_data.len, output.ptr) != 0) {
        call.allocator.free(output);
        return emptyResult(.failure);
    }

    return .{
        .status = .success,
        .output_data = output,
        .gas_left = gas_left,
    };
}

fn bn254Mul(call: Call) Error!Result {
    const gas_left = charge(call, bn254MulGas(call.spec)) orelse return emptyResult(.out_of_gas);
    const output = try call.allocator.alloc(u8, 64);
    errdefer call.allocator.free(output);
    if (bn254_native.evmz_bn254_mul(call.input_data.ptr, call.input_data.len, output.ptr) != 0) {
        call.allocator.free(output);
        return emptyResult(.failure);
    }

    return .{
        .status = .success,
        .output_data = output,
        .gas_left = gas_left,
    };
}

fn bn254Pairing(call: Call) Error!Result {
    const cost = bn254PairingGas(call.spec, call.input_data.len) orelse return emptyResult(.out_of_gas);
    const gas_left = charge(call, cost) orelse return emptyResult(.out_of_gas);
    if (call.input_data.len % bn254_pair_size != 0) return emptyResult(.failure);

    const output = try call.allocator.alloc(u8, 32);
    errdefer call.allocator.free(output);
    if (bn254_native.evmz_bn254_pairing_check(call.input_data.ptr, call.input_data.len, output.ptr) != 0) {
        call.allocator.free(output);
        return emptyResult(.failure);
    }

    return .{
        .status = .success,
        .output_data = output,
        .gas_left = gas_left,
    };
}

const bn254_pair_size = 192;

fn bn254AddGas(spec: Spec) i64 {
    return if (spec.isImpl(.istanbul)) 150 else 500;
}

fn bn254MulGas(spec: Spec) i64 {
    return if (spec.isImpl(.istanbul)) 6000 else 40000;
}

fn bn254PairingGas(spec: Spec, input_size: usize) ?i64 {
    const pair_count = input_size / bn254_pair_size;
    const base: i64 = if (spec.isImpl(.istanbul)) 45_000 else 100_000;
    const per_pair: i64 = if (spec.isImpl(.istanbul)) 34_000 else 80_000;
    const pair_count_i64 = std.math.cast(i64, pair_count) orelse return null;
    const variable = std.math.mul(i64, per_pair, pair_count_i64) catch return null;
    return std.math.add(i64, base, variable) catch null;
}

fn blake2f(call: Call) Error!Result {
    if (call.input_data.len != blake2f_input_size) return emptyResult(.failure);

    const rounds = std.mem.readInt(u32, call.input_data[0..4], .big);
    const gas_left = charge(call, @intCast(rounds)) orelse return emptyResult(.out_of_gas);

    const final_block = switch (call.input_data[212]) {
        0 => false,
        1 => true,
        else => return emptyResult(.failure),
    };

    var h: [8]u64 = undefined;
    for (&h, 0..) |*word, i| {
        const offset = 4 + i * 8;
        word.* = std.mem.readInt(u64, call.input_data[offset..][0..8], .little);
    }

    var m: [16]u64 = undefined;
    for (&m, 0..) |*word, i| {
        const offset = 68 + i * 8;
        word.* = std.mem.readInt(u64, call.input_data[offset..][0..8], .little);
    }

    const t0 = std.mem.readInt(u64, call.input_data[196..204], .little);
    const t1 = std.mem.readInt(u64, call.input_data[204..212], .little);
    blake2bCompress(rounds, &h, &m, .{ t0, t1 }, final_block);

    const output = try call.allocator.alloc(u8, 64);
    for (h, 0..) |word, i| {
        std.mem.writeInt(u64, output[i * 8 ..][0..8], word, .little);
    }
    return .{
        .status = .success,
        .output_data = output,
        .gas_left = gas_left,
    };
}

const blake2f_input_size = 213;

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

fn kzgPointEvaluation(call: Call) Error!Result {
    const gas_left = charge(call, kzg_point_evaluation_gas) orelse return emptyResult(.out_of_gas);
    if (call.input_data.len != kzg_point_evaluation_input_size) return emptyResult(.failure);

    const versioned_hash = call.input_data[0..32];
    const z = kzgBytes32(call.input_data[32..64]);
    const y = kzgBytes32(call.input_data[64..96]);
    const commitment = kzgBytes48(call.input_data[96..144]);
    const proof = kzgBytes48(call.input_data[144..192]);
    if (!std.mem.eql(u8, versioned_hash, &kzgToVersionedHash(call.input_data[96..144]))) {
        return emptyResult(.failure);
    }

    const settings = kzgSettings() catch return emptyResult(.failure);
    const ok = settings.verifyKzgProof(&commitment, &z, &y, &proof) catch false;
    if (!ok) return emptyResult(.failure);

    const output = try call.allocator.alloc(u8, 64);
    std.mem.writeInt(u256, output[0..32], kzg_field_elements_per_blob, .big);
    std.mem.writeInt(u256, output[32..64], kzg_bls_modulus, .big);
    return .{
        .status = .success,
        .output_data = output,
        .gas_left = gas_left,
    };
}

fn bls12G1Add(call: Call) Error!Result {
    const gas_left = charge(call, 375) orelse return emptyResult(.out_of_gas);
    if (call.input_data.len != 256) return emptyResult(.failure);
    var output: [128]u8 = undefined;
    return bls12NativeResult(call, gas_left, bls12_native.evmz_bls12_g1_add(call.input_data.ptr, &output), &output);
}

fn bls12G1Msm(call: Call) Error!Result {
    const cost = bls12G1MsmGas(call.input_data.len) orelse return emptyResult(.out_of_gas);
    const gas_left = charge(call, cost) orelse return emptyResult(.out_of_gas);
    var output: [128]u8 = undefined;
    return bls12NativeResult(call, gas_left, bls12_native.evmz_bls12_g1_msm(call.input_data.ptr, call.input_data.len, &output), &output);
}

fn bls12G2Add(call: Call) Error!Result {
    const gas_left = charge(call, 600) orelse return emptyResult(.out_of_gas);
    if (call.input_data.len != 512) return emptyResult(.failure);
    var output: [256]u8 = undefined;
    return bls12NativeResult(call, gas_left, bls12_native.evmz_bls12_g2_add(call.input_data.ptr, &output), &output);
}

fn bls12G2Msm(call: Call) Error!Result {
    const cost = bls12G2MsmGas(call.input_data.len) orelse return emptyResult(.out_of_gas);
    const gas_left = charge(call, cost) orelse return emptyResult(.out_of_gas);
    var output: [256]u8 = undefined;
    return bls12NativeResult(call, gas_left, bls12_native.evmz_bls12_g2_msm(call.input_data.ptr, call.input_data.len, &output), &output);
}

fn bls12PairingCheck(call: Call) Error!Result {
    const cost = bls12PairingGas(call.input_data.len) orelse return emptyResult(.out_of_gas);
    const gas_left = charge(call, cost) orelse return emptyResult(.out_of_gas);
    var output: [32]u8 = undefined;
    return bls12NativeResult(call, gas_left, bls12_native.evmz_bls12_pairing_check(call.input_data.ptr, call.input_data.len, &output), &output);
}

fn bls12MapFpToG1(call: Call) Error!Result {
    const gas_left = charge(call, 5500) orelse return emptyResult(.out_of_gas);
    if (call.input_data.len != 64) return emptyResult(.failure);
    var output: [128]u8 = undefined;
    return bls12NativeResult(call, gas_left, bls12_native.evmz_bls12_map_fp_to_g1(call.input_data.ptr, &output), &output);
}

fn bls12MapFp2ToG2(call: Call) Error!Result {
    const gas_left = charge(call, 23800) orelse return emptyResult(.out_of_gas);
    if (call.input_data.len != 128) return emptyResult(.failure);
    var output: [256]u8 = undefined;
    return bls12NativeResult(call, gas_left, bls12_native.evmz_bls12_map_fp2_to_g2(call.input_data.ptr, &output), &output);
}

const kzg_point_evaluation_input_size = 192;
const kzg_point_evaluation_gas = 50_000;
const kzg_field_elements_per_blob: u256 = 4096;
const kzg_bls_modulus: u256 = 52435875175126190479447740508185965837690552500527637822603658699938581184513;

var kzg_settings: ckzg.Settings = .{};

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

fn kzgBytes32(bytes: []const u8) ckzg.Bytes32 {
    var out: ckzg.Bytes32 = undefined;
    @memcpy(out.bytes[0..32], bytes[0..32]);
    return out;
}

fn kzgBytes48(bytes: []const u8) ckzg.Bytes48 {
    var out: ckzg.Bytes48 = undefined;
    @memcpy(out.bytes[0..48], bytes[0..48]);
    return out;
}

fn kzgToVersionedHash(commitment: []const u8) [32]u8 {
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(commitment, &hash, .{});
    hash[0] = 0x01;
    return hash;
}

fn bls12NativeResult(call: Call, gas_left: i64, status_code: c_int, output: []const u8) Error!Result {
    return switch (status_code) {
        bls12_native.EVMZ_BLS12_OK => .{
            .status = .success,
            .output_data = try call.allocator.dupe(u8, output),
            .gas_left = gas_left,
        },
        bls12_native.EVMZ_BLS12_INVALID => emptyResult(.failure),
        bls12_native.EVMZ_BLS12_OOM => error.OutOfMemory,
        else => emptyResult(.failure),
    };
}

fn bls12G1MsmGas(input_size: usize) ?i64 {
    return bls12MsmGas(input_size, 160, 12_000, &bls12_g1_msm_discounts, 519);
}

fn bls12G2MsmGas(input_size: usize) ?i64 {
    return bls12MsmGas(input_size, 288, 22_500, &bls12_g2_msm_discounts, 524);
}

fn bls12MsmGas(input_size: usize, len_per_pair: usize, multiplication_cost: i64, discounts: *const [128]u16, max_discount: u16) ?i64 {
    const k = input_size / len_per_pair;
    if (k == 0) return 0;
    const k_i64 = std.math.cast(i64, k) orelse return null;
    const discount = if (k > 128) max_discount else discounts[k - 1];
    const discounted = std.math.mul(i64, k_i64, multiplication_cost) catch return null;
    const numerator = std.math.mul(i64, discounted, @intCast(discount)) catch return null;
    return @divFloor(numerator, 1000);
}

fn bls12PairingGas(input_size: usize) ?i64 {
    const k = input_size / 384;
    const k_i64 = std.math.cast(i64, k) orelse return null;
    const variable = std.math.mul(i64, 32_600, k_i64) catch return null;
    return std.math.add(i64, 37_700, variable) catch null;
}

const bls12_g1_msm_discounts = [_]u16{
    1000, 949, 848, 797, 764, 750, 738, 728, 719, 712, 705, 698, 692, 687, 682, 677,
    673,  669, 665, 661, 658, 654, 651, 648, 645, 642, 640, 637, 635, 632, 630, 627,
    625,  623, 621, 619, 617, 615, 613, 611, 609, 608, 606, 604, 603, 601, 599, 598,
    596,  595, 593, 592, 591, 589, 588, 586, 585, 584, 582, 581, 580, 579, 577, 576,
    575,  574, 573, 572, 570, 569, 568, 567, 566, 565, 564, 563, 562, 561, 560, 559,
    558,  557, 556, 555, 554, 553, 552, 551, 550, 549, 548, 547, 547, 546, 545, 544,
    543,  542, 541, 540, 540, 539, 538, 537, 536, 536, 535, 534, 533, 532, 532, 531,
    530,  529, 528, 528, 527, 526, 525, 525, 524, 523, 522, 522, 521, 520, 520, 519,
};

const bls12_g2_msm_discounts = [_]u16{
    1000, 1000, 923, 884, 855, 832, 812, 796, 782, 770, 759, 749, 740, 732, 724, 717,
    711,  704,  699, 693, 688, 683, 679, 674, 670, 666, 663, 659, 655, 652, 649, 646,
    643,  640,  637, 634, 632, 629, 627, 624, 622, 620, 618, 615, 613, 611, 609, 607,
    606,  604,  602, 600, 598, 597, 595, 593, 592, 590, 589, 587, 586, 584, 583, 582,
    580,  579,  578, 576, 575, 574, 573, 571, 570, 569, 568, 567, 566, 565, 563, 562,
    561,  560,  559, 558, 557, 556, 555, 554, 553, 552, 552, 551, 550, 549, 548, 547,
    546,  545,  545, 544, 543, 542, 541, 541, 540, 539, 538, 537, 537, 536, 535, 535,
    534,  533,  532, 532, 531, 530, 530, 529, 528, 528, 527, 526, 526, 525, 524, 524,
};

fn p256Verify(call: Call) Error!Result {
    const gas_left = charge(call, p256verify_gas) orelse return emptyResult(.out_of_gas);
    if (!p256VerifyInput(call.input_data)) {
        return .{
            .status = .success,
            .output_data = &.{},
            .gas_left = gas_left,
        };
    }

    const output = try call.allocator.alloc(u8, 32);
    @memset(output, 0);
    output[31] = 1;
    return .{
        .status = .success,
        .output_data = output,
        .gas_left = gas_left,
    };
}

fn p256VerifyInput(input: []const u8) bool {
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

fn p256ScalarFromWord(word: [32]u8) std.crypto.ecc.P256.scalar.Scalar {
    var expanded = [_]u8{0} ** 64;
    @memcpy(expanded[32..64], &word);
    return std.crypto.ecc.P256.scalar.Scalar.fromBytes64(expanded, .big);
}

fn recoverAddress(input: []const u8) ?Address {
    const message_hash = paddedWord(input, 0);
    const v_word = paddedWord(input, 1);
    const r_bytes = paddedWord(input, 2);
    const s_bytes = paddedWord(input, 3);

    const v = std.mem.readInt(u256, &v_word, .big);
    if (v != 27 and v != 28) return null;

    const Secp256k1 = std.crypto.ecc.Secp256k1;
    const Scalar = Secp256k1.scalar.Scalar;

    const r_scalar = Scalar.fromBytes(r_bytes, .big) catch return null;
    const s_scalar = Scalar.fromBytes(s_bytes, .big) catch return null;
    if (r_scalar.isZero() or s_scalar.isZero()) return null;

    const x = Secp256k1.Fe.fromBytes(r_bytes, .big) catch return null;
    const y = Secp256k1.recoverY(x, v == 28) catch return null;
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
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha3.Keccak256.hash(uncompressed[1..65], &hash, .{});

    var address_bytes: Address = undefined;
    @memcpy(&address_bytes, hash[12..32]);
    return address_bytes;
}

fn paddedWord(input: []const u8, word_index: usize) [32]u8 {
    var word = [_]u8{0} ** 32;
    const start = word_index * 32;
    if (start >= input.len) return word;
    const size = @min(32, input.len - start);
    @memcpy(word[0..size], input[start .. start + size]);
    return word;
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

test activeAt {
    try std.testing.expectEqual(Contract.ecrecover, activeAt(.frontier, Contract.ecrecover.toAddress()).?);
    try std.testing.expect(activeAt(.frontier, Contract.modexp.toAddress()) == null);
    try std.testing.expectEqual(Contract.modexp, activeAt(.byzantium, Contract.modexp.toAddress()).?);
    try std.testing.expect(activeAt(.byzantium, Contract.blake2f.toAddress()) == null);
    try std.testing.expectEqual(Contract.blake2f, activeAt(.istanbul, Contract.blake2f.toAddress()).?);
    try std.testing.expect(activeAt(.shanghai, Contract.kzg_point_evaluation.toAddress()) == null);
    try std.testing.expectEqual(Contract.kzg_point_evaluation, activeAt(.cancun, Contract.kzg_point_evaluation.toAddress()).?);
    try std.testing.expect(activeAt(.cancun, Contract.bls12_g1add.toAddress()) == null);
    try std.testing.expectEqual(Contract.bls12_g1add, activeAt(.prague, Contract.bls12_g1add.toAddress()).?);
    try std.testing.expect(activeAt(.prague, address.addr(0x12)) == null);
    try std.testing.expect(activeAt(.prague, Contract.p256verify.toAddress()) == null);
    try std.testing.expectEqual(Contract.p256verify, activeAt(.osaka, Contract.p256verify.toAddress()).?);
}

test execute {
    try std.testing.expectEqual(null, try execute(std.testing.allocator, .frontier, Contract.modexp.toAddress(), &.{}, 0));

    const result = (try execute(std.testing.allocator, .byzantium, Contract.modexp.toAddress(), &.{}, 0)).?;
    try std.testing.expectEqual(Status.success, result.status);
    try std.testing.expectEqual(@as(i64, 0), result.gas_left);
    try std.testing.expectEqual(@as(usize, 0), result.output_data.len);
}

test ecrecover {
    const input = [_]u8{
        0x18, 0xc5, 0x47, 0xe4, 0xf7, 0xb0, 0xf3, 0x25,
        0xad, 0x1e, 0x56, 0xf5, 0x7e, 0x26, 0xc7, 0x45,
        0xb0, 0x9a, 0x3e, 0x50, 0x3d, 0x86, 0xe0, 0x0e,
        0x52, 0x55, 0xff, 0x7f, 0x71, 0x5d, 0x3d, 0x1c,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x1c,
        0x73, 0xb1, 0x69, 0x38, 0x92, 0x21, 0x9d, 0x73,
        0x6c, 0xab, 0xa5, 0x5b, 0xdb, 0x67, 0x21, 0x6e,
        0x48, 0x55, 0x57, 0xea, 0x6b, 0x6a, 0xf7, 0x5f,
        0x37, 0x09, 0x6c, 0x9a, 0xa6, 0xa5, 0xa7, 0x5f,
        0xee, 0xb9, 0x40, 0xb1, 0xd0, 0x3b, 0x21, 0xe3,
        0x6b, 0x0e, 0x47, 0xe7, 0x97, 0x69, 0xf0, 0x95,
        0xfe, 0x2a, 0xb8, 0x55, 0xbd, 0x91, 0xe3, 0xa3,
        0x87, 0x56, 0xb7, 0xd7, 0x5a, 0x9c, 0x45, 0x49,
    };

    const result = (try execute(std.testing.allocator, .frontier, Contract.ecrecover.toAddress(), &input, 3000)).?;
    defer std.testing.allocator.free(result.output_data);

    try std.testing.expectEqual(Status.success, result.status);
    try std.testing.expectEqual(@as(i64, 0), result.gas_left);
    try std.testing.expectEqualSlices(u8, &[_]u8{
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0xa9, 0x4f, 0x53, 0x74,
        0xfc, 0xe5, 0xed, 0xbc, 0x8e, 0x2a, 0x86, 0x97,
        0xc1, 0x53, 0x31, 0x67, 0x7e, 0x6e, 0xbf, 0x0b,
    }, result.output_data);

    const invalid = (try execute(std.testing.allocator, .frontier, Contract.ecrecover.toAddress(), &.{}, 3001)).?;
    try std.testing.expectEqual(Status.success, invalid.status);
    try std.testing.expectEqual(@as(i64, 1), invalid.gas_left);
    try std.testing.expectEqual(@as(usize, 0), invalid.output_data.len);
}

test identity {
    const input = "hello";
    const result = (try execute(std.testing.allocator, .frontier, Contract.identity.toAddress(), input, 18)).?;
    defer std.testing.allocator.free(result.output_data);

    try std.testing.expectEqual(Status.success, result.status);
    try std.testing.expectEqual(@as(i64, 0), result.gas_left);
    try std.testing.expectEqualSlices(u8, input, result.output_data);

    const oog = (try execute(std.testing.allocator, .frontier, Contract.identity.toAddress(), input, 17)).?;
    try std.testing.expectEqual(Status.out_of_gas, oog.status);
    try std.testing.expectEqual(@as(usize, 0), oog.output_data.len);
}

test modexp {
    var eip198_input: [161]u8 = undefined;
    _ = try std.fmt.hexToBytes(&eip198_input, "0000000000000000000000000000000000000000000000000000000000000001" ++
        "0000000000000000000000000000000000000000000000000000000000000020" ++
        "0000000000000000000000000000000000000000000000000000000000000020" ++
        "03" ++
        "fffffffffffffffffffffffffffffffffffffffffffffffffffffffefffffc2e" ++
        "fffffffffffffffffffffffffffffffffffffffffffffffffffffffefffffc2f");
    var expected: [32]u8 = [_]u8{0} ** 32;
    expected[31] = 1;

    const byzantium = (try execute(std.testing.allocator, .byzantium, Contract.modexp.toAddress(), &eip198_input, 13056)).?;
    defer std.testing.allocator.free(byzantium.output_data);

    try std.testing.expectEqual(Status.success, byzantium.status);
    try std.testing.expectEqual(@as(i64, 0), byzantium.gas_left);
    try std.testing.expectEqualSlices(u8, &expected, byzantium.output_data);

    const byzantium_oog = (try execute(std.testing.allocator, .byzantium, Contract.modexp.toAddress(), &eip198_input, 13055)).?;
    try std.testing.expectEqual(Status.out_of_gas, byzantium_oog.status);

    const berlin = (try execute(std.testing.allocator, .berlin, Contract.modexp.toAddress(), &eip198_input, 1361)).?;
    defer std.testing.allocator.free(berlin.output_data);

    try std.testing.expectEqual(Status.success, berlin.status);
    try std.testing.expectEqual(@as(i64, 1), berlin.gas_left);
    try std.testing.expectEqualSlices(u8, &expected, berlin.output_data);

    const osaka = (try execute(std.testing.allocator, .osaka, Contract.modexp.toAddress(), &eip198_input, 4080)).?;
    defer std.testing.allocator.free(osaka.output_data);

    try std.testing.expectEqual(Status.success, osaka.status);
    try std.testing.expectEqual(@as(i64, 0), osaka.gas_left);
    try std.testing.expectEqualSlices(u8, &expected, osaka.output_data);

    const osaka_oog = (try execute(std.testing.allocator, .osaka, Contract.modexp.toAddress(), &eip198_input, 4079)).?;
    try std.testing.expectEqual(Status.out_of_gas, osaka_oog.status);

    var osaka_zero_head_long_exp: [225]u8 = undefined;
    @memset(&osaka_zero_head_long_exp, 0);
    std.mem.writeInt(u256, osaka_zero_head_long_exp[0..32], 1, .big);
    std.mem.writeInt(u256, osaka_zero_head_long_exp[32..64], 64, .big);
    std.mem.writeInt(u256, osaka_zero_head_long_exp[64..96], 64, .big);
    osaka_zero_head_long_exp[96] = 1;
    @memset(osaka_zero_head_long_exp[161..225], 2);
    const osaka_zero_head_oog = (try execute(std.testing.allocator, .osaka, Contract.modexp.toAddress(), &osaka_zero_head_long_exp, 65_535)).?;
    try std.testing.expectEqual(Status.out_of_gas, osaka_zero_head_oog.status);
    const osaka_zero_head = (try execute(std.testing.allocator, .osaka, Contract.modexp.toAddress(), &osaka_zero_head_long_exp, 65_536)).?;
    defer std.testing.allocator.free(osaka_zero_head.output_data);
    try std.testing.expectEqual(Status.success, osaka_zero_head.status);
    try std.testing.expectEqual(@as(i64, 0), osaka_zero_head.gas_left);

    var small_input: [99]u8 = undefined;
    _ = try std.fmt.hexToBytes(&small_input, "0000000000000000000000000000000000000000000000000000000000000001" ++
        "0000000000000000000000000000000000000000000000000000000000000001" ++
        "0000000000000000000000000000000000000000000000000000000000000001" ++
        "02050d");
    const small = (try execute(std.testing.allocator, .byzantium, Contract.modexp.toAddress(), &small_input, 0)).?;
    defer std.testing.allocator.free(small.output_data);

    try std.testing.expectEqual(Status.success, small.status);
    try std.testing.expectEqual(@as(i64, 0), small.gas_left);
    try std.testing.expectEqualSlices(u8, &[_]u8{6}, small.output_data);

    const small_berlin_oog = (try execute(std.testing.allocator, .berlin, Contract.modexp.toAddress(), &small_input, 199)).?;
    try std.testing.expectEqual(Status.out_of_gas, small_berlin_oog.status);

    const small_osaka_oog = (try execute(std.testing.allocator, .osaka, Contract.modexp.toAddress(), &small_input, 499)).?;
    try std.testing.expectEqual(Status.out_of_gas, small_osaka_oog.status);

    const small_osaka = (try execute(std.testing.allocator, .osaka, Contract.modexp.toAddress(), &small_input, 500)).?;
    defer std.testing.allocator.free(small_osaka.output_data);

    try std.testing.expectEqual(Status.success, small_osaka.status);
    try std.testing.expectEqual(@as(i64, 0), small_osaka.gas_left);
    try std.testing.expectEqualSlices(u8, &[_]u8{6}, small_osaka.output_data);

    var zero_modulus_input: [97]u8 = undefined;
    _ = try std.fmt.hexToBytes(&zero_modulus_input, "0000000000000000000000000000000000000000000000000000000000000000" ++
        "0000000000000000000000000000000000000000000000000000000000000000" ++
        "0000000000000000000000000000000000000000000000000000000000000001" ++
        "00");
    const zero_modulus = (try execute(std.testing.allocator, .berlin, Contract.modexp.toAddress(), &zero_modulus_input, 200)).?;
    defer std.testing.allocator.free(zero_modulus.output_data);

    try std.testing.expectEqual(Status.success, zero_modulus.status);
    try std.testing.expectEqualSlices(u8, &[_]u8{0}, zero_modulus.output_data);

    var zero_complexity_input: [96]u8 = [_]u8{0} ** 96;
    zero_complexity_input[32] = 0x80;
    const zero_complexity = (try execute(std.testing.allocator, .berlin, Contract.modexp.toAddress(), &zero_complexity_input, 200)).?;
    try std.testing.expectEqual(Status.success, zero_complexity.status);
    try std.testing.expectEqual(@as(i64, 0), zero_complexity.gas_left);
    try std.testing.expectEqual(@as(usize, 0), zero_complexity.output_data.len);

    var over_osaka_limit_input: [96]u8 = [_]u8{0} ** 96;
    std.mem.writeInt(u256, over_osaka_limit_input[0..32], modexp_osaka_max_input_len + 1, .big);
    const oversized_prague = (try execute(std.testing.allocator, .prague, Contract.modexp.toAddress(), &over_osaka_limit_input, 6000)).?;
    try std.testing.expectEqual(Status.success, oversized_prague.status);

    const oversized_osaka = (try execute(std.testing.allocator, .osaka, Contract.modexp.toAddress(), &over_osaka_limit_input, 6000)).?;
    try std.testing.expectEqual(Status.out_of_gas, oversized_osaka.status);
}

test "P256VERIFY precompile" {
    const Scheme = std.crypto.sign.ecdsa.EcdsaP256Sha256;
    const Hash = std.crypto.hash.sha2.Sha256;

    const seed = [_]u8{0x42} ** Scheme.KeyPair.seed_length;
    const key_pair = try Scheme.KeyPair.generateDeterministic(seed);
    const message = "p256verify precompile test";
    var message_hash: [Hash.digest_length]u8 = undefined;
    Hash.hash(message, &message_hash, .{});
    const signature = try key_pair.signPrehashed(message_hash, null);
    const signature_bytes = signature.toBytes();
    const public_key = key_pair.public_key.toUncompressedSec1();

    var input: [160]u8 = undefined;
    @memcpy(input[0..32], &message_hash);
    @memcpy(input[32..96], &signature_bytes);
    @memcpy(input[96..128], public_key[1..33]);
    @memcpy(input[128..160], public_key[33..65]);

    try std.testing.expectEqual(null, try execute(std.testing.allocator, .prague, Contract.p256verify.toAddress(), &input, p256verify_gas));

    const oog = (try execute(std.testing.allocator, .osaka, Contract.p256verify.toAddress(), &input, p256verify_gas - 1)).?;
    try std.testing.expectEqual(Status.out_of_gas, oog.status);

    const valid = (try execute(std.testing.allocator, .osaka, Contract.p256verify.toAddress(), &input, p256verify_gas + 1)).?;
    defer std.testing.allocator.free(valid.output_data);

    var expected = [_]u8{0} ** 32;
    expected[31] = 1;
    try std.testing.expectEqual(Status.success, valid.status);
    try std.testing.expectEqual(@as(i64, 1), valid.gas_left);
    try std.testing.expectEqualSlices(u8, &expected, valid.output_data);

    var wrong_hash = input;
    wrong_hash[0] ^= 0x01;
    const invalid_signature = (try execute(std.testing.allocator, .osaka, Contract.p256verify.toAddress(), &wrong_hash, p256verify_gas + 1)).?;
    try std.testing.expectEqual(Status.success, invalid_signature.status);
    try std.testing.expectEqual(@as(i64, 1), invalid_signature.gas_left);
    try std.testing.expectEqual(@as(usize, 0), invalid_signature.output_data.len);

    const invalid_length = (try execute(std.testing.allocator, .osaka, Contract.p256verify.toAddress(), input[0..159], p256verify_gas + 1)).?;
    try std.testing.expectEqual(Status.success, invalid_length.status);
    try std.testing.expectEqual(@as(i64, 1), invalid_length.gas_left);
    try std.testing.expectEqual(@as(usize, 0), invalid_length.output_data.len);

    var infinity_key = input;
    @memset(infinity_key[96..160], 0);
    const invalid_key = (try execute(std.testing.allocator, .osaka, Contract.p256verify.toAddress(), &infinity_key, p256verify_gas + 1)).?;
    try std.testing.expectEqual(Status.success, invalid_key.status);
    try std.testing.expectEqual(@as(i64, 1), invalid_key.gas_left);
    try std.testing.expectEqual(@as(usize, 0), invalid_key.output_data.len);
}

test "bn254 add and mul" {
    var add_input: [128]u8 = undefined;
    _ = try std.fmt.hexToBytes(&add_input, "0000000000000000000000000000000000000000000000000000000000000001" ++
        "0000000000000000000000000000000000000000000000000000000000000002" ++
        "0000000000000000000000000000000000000000000000000000000000000001" ++
        "0000000000000000000000000000000000000000000000000000000000000002");
    var doubled_expected: [64]u8 = undefined;
    _ = try std.fmt.hexToBytes(&doubled_expected, "030644e72e131a029b85045b68181585d97816a916871ca8d3c208c16d87cfd3" ++
        "15ed738c0e0a7c92e7845f96b2ae9c0a68a6a449e3538fc7ff3ebf7a5a18a2c4");

    const add_result = (try execute(std.testing.allocator, .byzantium, Contract.bn254_add.toAddress(), &add_input, 500)).?;
    defer std.testing.allocator.free(add_result.output_data);

    try std.testing.expectEqual(Status.success, add_result.status);
    try std.testing.expectEqual(@as(i64, 0), add_result.gas_left);
    try std.testing.expectEqualSlices(u8, &doubled_expected, add_result.output_data);

    var mul_input: [96]u8 = undefined;
    _ = try std.fmt.hexToBytes(&mul_input, "0000000000000000000000000000000000000000000000000000000000000001" ++
        "0000000000000000000000000000000000000000000000000000000000000002" ++
        "0000000000000000000000000000000000000000000000000000000000000003");
    var tripled_expected: [64]u8 = undefined;
    _ = try std.fmt.hexToBytes(&tripled_expected, "0769bf9ac56bea3ff40232bcb1b6bd159315d84715b8e679f2d355961915abf0" ++
        "2ab799bee0489429554fdb7c8d086475319e63b40b9c5b57cdf1ff3dd9fe2261");

    const mul_result = (try execute(std.testing.allocator, .istanbul, Contract.bn254_mul.toAddress(), &mul_input, 6001)).?;
    defer std.testing.allocator.free(mul_result.output_data);

    try std.testing.expectEqual(Status.success, mul_result.status);
    try std.testing.expectEqual(@as(i64, 1), mul_result.gas_left);
    try std.testing.expectEqualSlices(u8, &tripled_expected, mul_result.output_data);

    const invalid = (try execute(std.testing.allocator, .byzantium, Contract.bn254_add.toAddress(), &[_]u8{0xff} ** 32, 500)).?;
    try std.testing.expectEqual(Status.failure, invalid.status);
}

test "bn254 pairing" {
    var true_output = [_]u8{0} ** 32;
    true_output[31] = 1;

    const empty = (try execute(std.testing.allocator, .byzantium, Contract.bn254_pairing.toAddress(), &.{}, 100_001)).?;
    defer std.testing.allocator.free(empty.output_data);

    try std.testing.expectEqual(Status.success, empty.status);
    try std.testing.expectEqual(@as(i64, 1), empty.gas_left);
    try std.testing.expectEqualSlices(u8, &true_output, empty.output_data);

    const repriced = (try execute(std.testing.allocator, .istanbul, Contract.bn254_pairing.toAddress(), &.{}, 45_000)).?;
    defer std.testing.allocator.free(repriced.output_data);

    try std.testing.expectEqual(Status.success, repriced.status);
    try std.testing.expectEqual(@as(i64, 0), repriced.gas_left);
    try std.testing.expectEqualSlices(u8, &true_output, repriced.output_data);

    const oog = (try execute(std.testing.allocator, .istanbul, Contract.bn254_pairing.toAddress(), &.{}, 44_999)).?;
    try std.testing.expectEqual(Status.out_of_gas, oog.status);

    const malformed = (try execute(std.testing.allocator, .istanbul, Contract.bn254_pairing.toAddress(), &[_]u8{0}, 45_000)).?;
    try std.testing.expectEqual(Status.failure, malformed.status);
}

test "bn254 pairing rejects field elements outside modulus" {
    var input = [_]u8{0} ** bn254_pair_size;
    _ = try std.fmt.hexToBytes(input[0..32], "30644e72e131a029b85045b68181585d97816a916871ca8d3c208c16d87cfd47");

    const invalid = (try execute(std.testing.allocator, .byzantium, Contract.bn254_pairing.toAddress(), &input, 180_000)).?;
    try std.testing.expectEqual(Status.failure, invalid.status);
    try std.testing.expectEqual(@as(i64, 0), invalid.gas_left);
}

test blake2f {
    var input: [blake2f_input_size]u8 = undefined;
    _ = try std.fmt.hexToBytes(&input, "0000000c" ++
        "48c9bdf267e6096a3ba7ca8485ae67bb2bf894fe72f36e3cf1361d5f3af54fa5" ++
        "d182e6ad7f520e511f6c3e2b8c68059b6bbd41fbabd9831f79217e1319cde05b" ++
        "6162630000000000000000000000000000000000000000000000000000000000" ++
        "0000000000000000000000000000000000000000000000000000000000000000" ++
        "0000000000000000000000000000000000000000000000000000000000000000" ++
        "0000000000000000000000000000000000000000000000000000000000000000" ++
        "0300000000000000000000000000000001");

    var expected: [64]u8 = undefined;
    _ = try std.fmt.hexToBytes(&expected, "ba80a53f981c4d0d6a2797b69f12f6e94c212f14685ac4b74b12bb6fdbffa2d1" ++
        "7d87c5392aab792dc252d5de4533cc9518d38aa8dbf1925ab92386edd4009923");

    const result = (try execute(std.testing.allocator, .istanbul, Contract.blake2f.toAddress(), &input, 12)).?;
    defer std.testing.allocator.free(result.output_data);

    try std.testing.expectEqual(Status.success, result.status);
    try std.testing.expectEqual(@as(i64, 0), result.gas_left);
    try std.testing.expectEqualSlices(u8, &expected, result.output_data);

    input[2] = 0x04;
    input[3] = 0x00;
    _ = try std.fmt.hexToBytes(&expected, "689419d2bf32b5a9901a2c733b9946727026a60d8773117eabb35f04a52cdcf1" ++
        "b8fb4473454cf03d46c36a10b3f784aae4dc80a24424960e66a8ad5a8c2bfb30");
    const long_rounds = (try execute(std.testing.allocator, .istanbul, Contract.blake2f.toAddress(), &input, 1024)).?;
    defer std.testing.allocator.free(long_rounds.output_data);

    try std.testing.expectEqual(Status.success, long_rounds.status);
    try std.testing.expectEqualSlices(u8, &expected, long_rounds.output_data);

    input[2] = 0x00;
    input[3] = 0x0c;
    const oog = (try execute(std.testing.allocator, .istanbul, Contract.blake2f.toAddress(), &input, 11)).?;
    try std.testing.expectEqual(Status.out_of_gas, oog.status);

    input[212] = 2;
    const invalid_flag = (try execute(std.testing.allocator, .istanbul, Contract.blake2f.toAddress(), &input, 12)).?;
    try std.testing.expectEqual(Status.failure, invalid_flag.status);
}

test sha256 {
    const result = (try execute(std.testing.allocator, .frontier, Contract.sha256.toAddress(), &.{}, 60)).?;
    defer std.testing.allocator.free(result.output_data);

    try std.testing.expectEqual(Status.success, result.status);
    try std.testing.expectEqual(@as(i64, 0), result.gas_left);
    try std.testing.expectEqualSlices(u8, &[_]u8{
        0xe3, 0xb0, 0xc4, 0x42, 0x98, 0xfc, 0x1c, 0x14,
        0x9a, 0xfb, 0xf4, 0xc8, 0x99, 0x6f, 0xb9, 0x24,
        0x27, 0xae, 0x41, 0xe4, 0x64, 0x9b, 0x93, 0x4c,
        0xa4, 0x95, 0x99, 0x1b, 0x78, 0x52, 0xb8, 0x55,
    }, result.output_data);

    const oog = (try execute(std.testing.allocator, .frontier, Contract.sha256.toAddress(), &.{}, 59)).?;
    try std.testing.expectEqual(Status.out_of_gas, oog.status);
    try std.testing.expectEqual(@as(usize, 0), oog.output_data.len);
}

test ripemd160Digest {
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

test ripemd160 {
    const result = (try execute(std.testing.allocator, .frontier, Contract.ripemd160.toAddress(), "abc", 720)).?;
    defer std.testing.allocator.free(result.output_data);

    try std.testing.expectEqual(Status.success, result.status);
    try std.testing.expectEqual(@as(i64, 0), result.gas_left);
    try std.testing.expectEqualSlices(u8, &[_]u8{
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x8e, 0xb2, 0x08, 0xf7,
        0xe0, 0x5d, 0x98, 0x7a, 0x9b, 0x04, 0x4a, 0x8e,
        0x98, 0xc6, 0xb0, 0x87, 0xf1, 0x5a, 0x0b, 0xfc,
    }, result.output_data);

    const oog = (try execute(std.testing.allocator, .frontier, Contract.ripemd160.toAddress(), "abc", 719)).?;
    try std.testing.expectEqual(Status.out_of_gas, oog.status);
    try std.testing.expectEqual(@as(usize, 0), oog.output_data.len);
}
