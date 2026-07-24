//! Precompiled-contract implementations and address dispatch.

const std = @import("std");
const address = @import("address.zig");
const crypto = @import("crypto.zig");
const precompile_runtime = @import("execution/precompile_runtime.zig");
const precompile_backend = @import("precompile/backend.zig");
const uint256 = @import("uint256.zig");

const Address = address.Address;

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
};

pub const contract_slots = @intFromEnum(Contract.p256verify) + 1;

/// Resolved scalar gas inputs consumed by the precompile formulas below.
/// Exact specifications provide one value per semantic key.
pub const GasParameter = enum {
    ecrecover,
    sha256_base,
    sha256_word,
    ripemd160_base,
    ripemd160_word,
    identity_base,
    identity_word,
    modexp_minimum,
    modexp_divisor,
    bn254_add,
    bn254_mul,
    bn254_pairing_base,
    bn254_pairing_pair,
    blake2f_round,
    kzg_point_evaluation,
    bls12_g1add,
    bls12_g1msm_multiplication,
    bls12_g2add,
    bls12_g2msm_multiplication,
    bls12_pairing_base,
    bls12_pairing_pair,
    bls12_map_fp_to_g1,
    bls12_map_fp2_to_g2,
    p256verify,
};

pub const GasSchedule = std.enums.EnumArray(GasParameter, i64);

pub const ModexpPricing = enum {
    eip198,
    eip2565,
    eip7883,
};

/// One exact precompile execution configuration. No fork identity enters a
/// precompile invocation after this value is selected.
pub const Config = struct {
    active: [contract_slots]bool,
    gas: GasSchedule,
    modexp_pricing: ModexpPricing,
    modexp_max_input_len: ?u256,
};

/// Bind precompile activation and pricing to one exact engine configuration.
pub fn Exact(comptime config: Config) type {
    return struct {
        pub const Entry = Contract;

        pub fn resolve(target: Address) ?Entry {
            const entry = contractFromAddress(target) orelse return null;
            return if (config.active[@intFromEnum(entry)]) entry else null;
        }

        pub fn active(target: Address) bool {
            return resolve(target) != null;
        }

        pub fn execute(
            entry: Entry,
            call: precompile_runtime.PrecompileCall,
        ) Error!precompile_runtime.PrecompileOutcome {
            return executeWithConfig(entry, call, config);
        }
    };
}

pub fn executeWithConfig(
    entry: Contract,
    call: precompile_runtime.PrecompileCall,
    comptime config: Config,
) Error!precompile_runtime.PrecompileOutcome {
    return .{ .result = try executeContract(entry, .{
        .allocator = call.allocator,
        .input_data = call.message.input_data,
        .gas = call.message.gas,
        .output_buffer = call.output_buffer,
    }, config) };
}

pub const Error = std.mem.Allocator.Error || error{
    NotImplemented,
    OutputBufferTooSmall,
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
    output_owned: bool = true,
};

pub const Call = struct {
    allocator: std.mem.Allocator,
    input_data: []const u8,
    gas: i64,
    output_buffer: ?[]u8 = null,
};

pub fn executeContract(
    contract: Contract,
    call: Call,
    comptime config: Config,
) Error!Result {
    validateConfig(config);
    const gas = config.gas;
    return switch (contract) {
        .ecrecover => ecrecover(call, gas),
        .sha256 => sha256(call, gas),
        .ripemd160 => ripemd160(call, gas),
        .identity => identity(call, gas),
        .modexp => modexp(call, config),
        .bn254_add => bn254Add(call, gas),
        .bn254_mul => bn254Mul(call, gas),
        .bn254_pairing => bn254Pairing(call, gas),
        .blake2f => blake2f(call, gas),
        .kzg_point_evaluation => kzgPointEvaluation(call, gas),
        .bls12_g1add => bls12G1Add(call, gas),
        .bls12_g1msm => bls12G1Msm(call, gas),
        .bls12_g2add => bls12G2Add(call, gas),
        .bls12_g2msm => bls12G2Msm(call, gas),
        .bls12_pairing_check => bls12PairingCheck(call, gas),
        .bls12_map_fp_to_g1 => bls12MapFpToG1(call, gas),
        .bls12_map_fp2_to_g2 => bls12MapFp2ToG2(call, gas),
        .p256verify => p256Verify(call, gas),
    };
}

fn validateConfig(comptime config: Config) void {
    const gas = config.gas;
    inline for (std.enums.values(GasParameter)) |parameter| {
        const value = comptime gas.get(parameter);
        if (value < 0) {
            @compileError("precompile gas parameter must be non-negative: " ++ @tagName(parameter));
        }
        switch (parameter) {
            .modexp_divisor => if (value == 0) {
                @compileError("modexp gas divisors must be positive");
            },
            else => {},
        }
    }
}

pub fn contractFromAddress(target: Address) ?Contract {
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
        .output_owned = false,
    };
}

fn allocOutput(call: Call, len: usize) Error![]u8 {
    if (call.output_buffer) |buffer| {
        if (len > buffer.len) return error.OutputBufferTooSmall;
        return buffer[0..len];
    }
    return call.allocator.alloc(u8, len);
}

fn dupeOutput(call: Call, bytes: []const u8) Error![]u8 {
    const output = try allocOutput(call, bytes.len);
    @memcpy(output, bytes);
    return output;
}

fn outputOwned(call: Call) bool {
    return call.output_buffer == null;
}

fn freeOutput(call: Call, output: []u8) void {
    if (outputOwned(call) and output.len != 0) call.allocator.free(output);
}

fn successOutput(call: Call, output: []u8, gas_left: i64) Result {
    return .{
        .status = .success,
        .output_data = output,
        .gas_left = gas_left,
        .output_owned = outputOwned(call),
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

fn ecrecover(call: Call, comptime gas: GasSchedule) Error!Result {
    const gas_left = charge(call, gas.get(.ecrecover)) orelse return emptyResult(.out_of_gas);
    const recovered = recoverAddress(call.input_data) orelse {
        return .{
            .status = .success,
            .output_data = &.{},
            .gas_left = gas_left,
        };
    };

    const output = try allocOutput(call, 32);
    @memset(output[0..12], 0);
    @memcpy(output[12..32], &recovered);
    return successOutput(call, output, gas_left);
}

fn sha256(call: Call, comptime gas: GasSchedule) Error!Result {
    const cost = linearCost(call.input_data.len, gas.get(.sha256_base), gas.get(.sha256_word)) orelse return emptyResult(.out_of_gas);
    const gas_left = charge(call, cost) orelse return emptyResult(.out_of_gas);

    const digest = crypto.sha256(call.input_data);
    return successOutput(call, try dupeOutput(call, &digest), gas_left);
}

fn ripemd160(call: Call, comptime gas: GasSchedule) Error!Result {
    const cost = linearCost(call.input_data.len, gas.get(.ripemd160_base), gas.get(.ripemd160_word)) orelse return emptyResult(.out_of_gas);
    const gas_left = charge(call, cost) orelse return emptyResult(.out_of_gas);

    var output: [32]u8 = undefined;
    return backendResult(call, gas_left, precompile_backend.ripemd160(call.input_data, &output), &output);
}

fn identity(call: Call, comptime gas: GasSchedule) Error!Result {
    const cost = linearCost(call.input_data.len, gas.get(.identity_base), gas.get(.identity_word)) orelse return emptyResult(.out_of_gas);
    const gas_left = charge(call, cost) orelse return emptyResult(.out_of_gas);
    return .{
        .status = .success,
        .output_data = try dupeOutput(call, call.input_data),
        .gas_left = gas_left,
        .output_owned = outputOwned(call),
    };
}

fn modexp(call: Call, comptime config: Config) Error!Result {
    const gas = config.gas;
    const base_len = std.mem.readInt(u256, &paddedWord(call.input_data, 0), .big);
    const exponent_len = std.mem.readInt(u256, &paddedWord(call.input_data, 1), .big);
    const modulus_len = std.mem.readInt(u256, &paddedWord(call.input_data, 2), .big);
    if (config.modexp_max_input_len) |max_input_len| {
        if (!modexpLengthsWithinLimit(base_len, exponent_len, modulus_len, max_input_len)) {
            return emptyResult(.out_of_gas);
        }
    }

    const exponent_offset = uint256.checkedAdd(96, base_len) orelse return emptyResult(.out_of_gas);
    const exponent_head = modexpExponentHead(call.input_data, exponent_offset, exponent_len);
    const cost = modexpGas(config.modexp_pricing, base_len, exponent_len, modulus_len, exponent_head, gas) orelse {
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

    const output = try allocOutput(call, modulus_len_usize);
    errdefer freeOutput(call, output);
    @memset(output, 0);
    if (allZero(modulus_bytes)) {
        return successOutput(call, output, gas_left);
    }

    switch (try precompile_backend.modexp(call.allocator, output, base_bytes, exponent_bytes, modulus_bytes)) {
        .ok => return successOutput(call, output, gas_left),
        .invalid => {
            freeOutput(call, output);
            return emptyResult(.failure);
        },
        .oom => return error.OutOfMemory,
    }
}

fn modexpGas(
    comptime pricing: ModexpPricing,
    base_len: u256,
    exponent_len: u256,
    modulus_len: u256,
    exponent_head: u256,
    comptime gas: GasSchedule,
) ?i64 {
    const max_len = @max(base_len, modulus_len);
    return switch (pricing) {
        .eip7883 => {
            const complexity = modexpOsakaMultComplexity(max_len) orelse return null;
            const iteration_count = modexpOsakaIterationCount(exponent_len, exponent_head) orelse return null;
            const cost = uint256.checkedMul(complexity, iteration_count) orelse return null;
            return std.math.cast(i64, @max(cost, @as(u256, @intCast(gas.get(.modexp_minimum)))));
        },
        .eip2565 => {
            const words = uint256.ceilDiv(max_len, 8);
            const complexity = uint256.checkedMul(words, words) orelse return null;
            if (complexity == 0) return gas.get(.modexp_minimum);
            const iteration_count = adjustedExponentLength(exponent_len, exponent_head) orelse return null;
            const iterations = @max(iteration_count, 1);
            const numerator = uint256.checkedMul(complexity, iterations) orelse return null;
            const divisor: u256 = @intCast(gas.get(.modexp_divisor));
            const minimum: u256 = @intCast(gas.get(.modexp_minimum));
            const cost = @max(@divFloor(numerator, divisor), minimum);
            return std.math.cast(i64, cost);
        },
        .eip198 => {
            const complexity = eip198MultComplexity(max_len) orelse return null;
            if (complexity == 0) return 0;
            const iteration_count = adjustedExponentLength(exponent_len, exponent_head) orelse return null;
            const iterations = @max(iteration_count, 1);
            const numerator = uint256.checkedMul(complexity, iterations) orelse return null;
            const cost = @divFloor(numerator, @as(u256, @intCast(gas.get(.modexp_divisor))));
            return std.math.cast(i64, cost);
        },
    };
}

fn modexpLengthsWithinLimit(base_len: u256, exponent_len: u256, modulus_len: u256, max_input_len: u256) bool {
    return base_len <= max_input_len and
        exponent_len <= max_input_len and
        modulus_len <= max_input_len;
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

fn bn254Add(call: Call, comptime gas: GasSchedule) Error!Result {
    const gas_left = charge(call, gas.get(.bn254_add)) orelse return emptyResult(.out_of_gas);
    const output = try allocOutput(call, 64);
    errdefer freeOutput(call, output);
    if (precompile_backend.bn254Add(call.input_data, output[0..64]) != .ok) {
        freeOutput(call, output);
        return emptyResult(.failure);
    }

    return successOutput(call, output, gas_left);
}

fn bn254Mul(call: Call, comptime gas: GasSchedule) Error!Result {
    const gas_left = charge(call, gas.get(.bn254_mul)) orelse return emptyResult(.out_of_gas);
    const output = try allocOutput(call, 64);
    errdefer freeOutput(call, output);
    if (precompile_backend.bn254Mul(call.input_data, output[0..64]) != .ok) {
        freeOutput(call, output);
        return emptyResult(.failure);
    }

    return successOutput(call, output, gas_left);
}

fn bn254Pairing(call: Call, comptime gas: GasSchedule) Error!Result {
    const cost = bn254PairingGas(call.input_data.len, gas) orelse return emptyResult(.out_of_gas);
    const gas_left = charge(call, cost) orelse return emptyResult(.out_of_gas);
    if (call.input_data.len % bn254_pair_size != 0) return emptyResult(.failure);

    const output = try allocOutput(call, 32);
    errdefer freeOutput(call, output);
    if (try precompile_backend.bn254Pairing(call.allocator, call.input_data, output[0..32]) != .ok) {
        freeOutput(call, output);
        return emptyResult(.failure);
    }

    return successOutput(call, output, gas_left);
}

const bn254_pair_size = 192;

fn bn254PairingGas(input_size: usize, comptime gas: GasSchedule) ?i64 {
    const pair_count = input_size / bn254_pair_size;
    const pair_count_i64 = std.math.cast(i64, pair_count) orelse return null;
    const variable = std.math.mul(i64, gas.get(.bn254_pairing_pair), pair_count_i64) catch return null;
    return std.math.add(i64, gas.get(.bn254_pairing_base), variable) catch null;
}

fn blake2f(call: Call, comptime gas: GasSchedule) Error!Result {
    if (call.input_data.len != blake2f_input_size) return emptyResult(.failure);

    const rounds = std.mem.readInt(u32, call.input_data[0..4], .big);
    const cost = std.math.mul(i64, @intCast(rounds), gas.get(.blake2f_round)) catch return emptyResult(.out_of_gas);
    const gas_left = charge(call, cost) orelse return emptyResult(.out_of_gas);

    const final_block = switch (call.input_data[212]) {
        0 => false,
        1 => true,
        else => return emptyResult(.failure),
    };

    var output: [64]u8 = undefined;
    return backendResult(call, gas_left, precompile_backend.blake2f(rounds, final_block, call.input_data, &output), &output);
}

const blake2f_input_size = 213;

fn kzgPointEvaluation(call: Call, comptime gas: GasSchedule) Error!Result {
    const gas_left = charge(call, gas.get(.kzg_point_evaluation)) orelse return emptyResult(.out_of_gas);
    if (call.input_data.len != kzg_point_evaluation_input_size) return emptyResult(.failure);

    const versioned_hash = call.input_data[0..32];
    const z = call.input_data[32..64].*;
    const y = call.input_data[64..96].*;
    const commitment = call.input_data[96..144].*;
    const proof = call.input_data[144..192].*;
    if (!std.mem.eql(u8, versioned_hash, &kzgToVersionedHash(call.input_data[96..144]))) {
        return emptyResult(.failure);
    }

    if (precompile_backend.kzgPointEvaluation(commitment, z, y, proof) != .ok) return emptyResult(.failure);

    const output = try allocOutput(call, 64);
    std.mem.writeInt(u256, output[0..32], kzg_field_elements_per_blob, .big);
    std.mem.writeInt(u256, output[32..64], kzg_bls_modulus, .big);
    return successOutput(call, output, gas_left);
}

fn bls12G1Add(call: Call, comptime gas: GasSchedule) Error!Result {
    const gas_left = charge(call, gas.get(.bls12_g1add)) orelse return emptyResult(.out_of_gas);
    if (call.input_data.len != 256) return emptyResult(.failure);
    var output: [128]u8 = undefined;
    return backendResult(call, gas_left, precompile_backend.bls12G1Add(call.input_data, &output), &output);
}

fn bls12G1Msm(call: Call, comptime gas: GasSchedule) Error!Result {
    const cost = bls12G1MsmGas(call.input_data.len, gas) orelse return emptyResult(.out_of_gas);
    const gas_left = charge(call, cost) orelse return emptyResult(.out_of_gas);
    var output: [128]u8 = undefined;
    return backendResult(call, gas_left, try precompile_backend.bls12G1Msm(call.allocator, call.input_data, &output), &output);
}

fn bls12G2Add(call: Call, comptime gas: GasSchedule) Error!Result {
    const gas_left = charge(call, gas.get(.bls12_g2add)) orelse return emptyResult(.out_of_gas);
    if (call.input_data.len != 512) return emptyResult(.failure);
    var output: [256]u8 = undefined;
    return backendResult(call, gas_left, precompile_backend.bls12G2Add(call.input_data, &output), &output);
}

fn bls12G2Msm(call: Call, comptime gas: GasSchedule) Error!Result {
    const cost = bls12G2MsmGas(call.input_data.len, gas) orelse return emptyResult(.out_of_gas);
    const gas_left = charge(call, cost) orelse return emptyResult(.out_of_gas);
    var output: [256]u8 = undefined;
    return backendResult(call, gas_left, try precompile_backend.bls12G2Msm(call.allocator, call.input_data, &output), &output);
}

fn bls12PairingCheck(call: Call, comptime gas: GasSchedule) Error!Result {
    const cost = bls12PairingGas(call.input_data.len, gas) orelse return emptyResult(.out_of_gas);
    const gas_left = charge(call, cost) orelse return emptyResult(.out_of_gas);
    var output: [32]u8 = undefined;
    return backendResult(call, gas_left, try precompile_backend.bls12Pairing(call.allocator, call.input_data, &output), &output);
}

fn bls12MapFpToG1(call: Call, comptime gas: GasSchedule) Error!Result {
    const gas_left = charge(call, gas.get(.bls12_map_fp_to_g1)) orelse return emptyResult(.out_of_gas);
    if (call.input_data.len != 64) return emptyResult(.failure);
    var output: [128]u8 = undefined;
    return backendResult(call, gas_left, precompile_backend.bls12MapFpToG1(call.input_data, &output), &output);
}

fn bls12MapFp2ToG2(call: Call, comptime gas: GasSchedule) Error!Result {
    const gas_left = charge(call, gas.get(.bls12_map_fp2_to_g2)) orelse return emptyResult(.out_of_gas);
    if (call.input_data.len != 128) return emptyResult(.failure);
    var output: [256]u8 = undefined;
    return backendResult(call, gas_left, precompile_backend.bls12MapFp2ToG2(call.input_data, &output), &output);
}

const kzg_point_evaluation_input_size = 192;
const kzg_field_elements_per_blob: u256 = 4096;
const kzg_bls_modulus: u256 = 52435875175126190479447740508185965837690552500527637822603658699938581184513;

fn kzgToVersionedHash(commitment: []const u8) [32]u8 {
    var hash = crypto.sha256(commitment);
    hash[0] = 0x01;
    return hash;
}

fn backendResult(call: Call, gas_left: i64, status: precompile_backend.Status, output: []const u8) Error!Result {
    return switch (status) {
        .ok => .{
            .status = .success,
            .output_data = try dupeOutput(call, output),
            .gas_left = gas_left,
            .output_owned = outputOwned(call),
        },
        .invalid => emptyResult(.failure),
        .oom => error.OutOfMemory,
    };
}

fn bls12G1MsmGas(input_size: usize, comptime gas: GasSchedule) ?i64 {
    return bls12MsmGas(input_size, 160, gas.get(.bls12_g1msm_multiplication), &bls12_g1_msm_discounts, 519);
}

fn bls12G2MsmGas(input_size: usize, comptime gas: GasSchedule) ?i64 {
    return bls12MsmGas(input_size, 288, gas.get(.bls12_g2msm_multiplication), &bls12_g2_msm_discounts, 524);
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

fn bls12PairingGas(input_size: usize, comptime gas: GasSchedule) ?i64 {
    const k = input_size / 384;
    const k_i64 = std.math.cast(i64, k) orelse return null;
    const variable = std.math.mul(i64, gas.get(.bls12_pairing_pair), k_i64) catch return null;
    return std.math.add(i64, gas.get(.bls12_pairing_base), variable) catch null;
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

fn p256Verify(call: Call, comptime gas: GasSchedule) Error!Result {
    const gas_left = charge(call, gas.get(.p256verify)) orelse return emptyResult(.out_of_gas);
    if (!precompile_backend.p256Verify(call.input_data)) {
        return .{
            .status = .success,
            .output_data = &.{},
            .gas_left = gas_left,
        };
    }

    const output = try allocOutput(call, 32);
    @memset(output, 0);
    output[31] = 1;
    return successOutput(call, output, gas_left);
}

fn recoverAddress(input: []const u8) ?Address {
    const message_hash = paddedWord(input, 0);
    const v_word = paddedWord(input, 1);
    const r_bytes = paddedWord(input, 2);
    const s_bytes = paddedWord(input, 3);

    const v = std.mem.readInt(u256, &v_word, .big);
    if (v != 27 and v != 28) return null;

    const public_key = crypto.ecrecoverPublicKey(message_hash, r_bytes, s_bytes, @intCast(v - 27)) orelse return null;
    const hash = crypto.keccak256(&public_key);

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

fn executeEthereumPrecompileForTest(
    allocator: std.mem.Allocator,
    comptime revision: @import("eth/revision.zig").Revision,
    target: Address,
    input_data: []const u8,
    gas: i64,
) Error!?Result {
    const eth_precompile = @import("eth/precompile.zig");
    const config = switch (revision) {
        .frontier,
        .frontier_thawing,
        .homestead,
        .dao_fork,
        .tangerine_whistle,
        .spurious_dragon,
        => eth_precompile.frontier_config,
        .byzantium,
        .constantinople,
        .petersburg,
        => eth_precompile.byzantium_config,
        .istanbul,
        .muir_glacier,
        => eth_precompile.istanbul_config,
        .berlin,
        .london,
        .arrow_glacier,
        .gray_glacier,
        .merge,
        .shanghai,
        => eth_precompile.berlin_config,
        .cancun => eth_precompile.cancun_config,
        .prague => eth_precompile.prague_config,
        .osaka, .amsterdam => eth_precompile.osaka_config,
    };
    const ExactConfig = Exact(config);
    const contract = ExactConfig.resolve(target) orelse return null;
    return try executeContract(contract, .{
        .allocator = allocator,
        .input_data = input_data,
        .gas = gas,
    }, config);
}

test "Ethereum precompile activation follows exact configs" {
    const eth_precompile = @import("eth/precompile.zig");
    const Frontier = Exact(eth_precompile.frontier_config);
    const Byzantium = Exact(eth_precompile.byzantium_config);
    const Istanbul = Exact(eth_precompile.istanbul_config);
    const Berlin = Exact(eth_precompile.berlin_config);
    const Cancun = Exact(eth_precompile.cancun_config);
    const Prague = Exact(eth_precompile.prague_config);
    const Osaka = Exact(eth_precompile.osaka_config);

    try std.testing.expectEqual(Contract.ecrecover, Frontier.resolve(Contract.ecrecover.toAddress()).?);
    try std.testing.expect(Frontier.resolve(Contract.modexp.toAddress()) == null);
    try std.testing.expectEqual(Contract.modexp, Byzantium.resolve(Contract.modexp.toAddress()).?);
    try std.testing.expect(Byzantium.resolve(Contract.blake2f.toAddress()) == null);
    try std.testing.expectEqual(Contract.blake2f, Istanbul.resolve(Contract.blake2f.toAddress()).?);
    try std.testing.expect(Berlin.resolve(Contract.kzg_point_evaluation.toAddress()) == null);
    try std.testing.expectEqual(Contract.kzg_point_evaluation, Cancun.resolve(Contract.kzg_point_evaluation.toAddress()).?);
    try std.testing.expect(Cancun.resolve(Contract.bls12_g1add.toAddress()) == null);
    try std.testing.expectEqual(Contract.bls12_g1add, Prague.resolve(Contract.bls12_g1add.toAddress()).?);
    try std.testing.expect(Prague.resolve(address.addr(0x12)) == null);
    try std.testing.expect(Prague.resolve(Contract.p256verify.toAddress()) == null);
    try std.testing.expectEqual(Contract.p256verify, Osaka.resolve(Contract.p256verify.toAddress()).?);
}

test "Ethereum precompile activation gates catalog execution" {
    try std.testing.expectEqual(null, try executeEthereumPrecompileForTest(std.testing.allocator, .frontier, Contract.modexp.toAddress(), &.{}, 0));

    const result = (try executeEthereumPrecompileForTest(std.testing.allocator, .byzantium, Contract.modexp.toAddress(), &.{}, 0)).?;
    try std.testing.expectEqual(Status.success, result.status);
    try std.testing.expectEqual(@as(i64, 0), result.gas_left);
    try std.testing.expectEqual(@as(usize, 0), result.output_data.len);
}

test "contract execution is independent from Ethereum activation window" {
    try std.testing.expectEqual(null, try executeEthereumPrecompileForTest(std.testing.allocator, .frontier, Contract.modexp.toAddress(), &.{}, 0));

    const result = try executeContract(.modexp, .{
        .allocator = std.testing.allocator,
        .input_data = &.{},
        .gas = 0,
    }, @import("eth/precompile.zig").frontier_config);
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

    const result = (try executeEthereumPrecompileForTest(std.testing.allocator, .frontier, Contract.ecrecover.toAddress(), &input, 3000)).?;
    defer std.testing.allocator.free(result.output_data);

    try std.testing.expectEqual(Status.success, result.status);
    try std.testing.expectEqual(@as(i64, 0), result.gas_left);
    try std.testing.expectEqualSlices(u8, &[_]u8{
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0xa9, 0x4f, 0x53, 0x74,
        0xfc, 0xe5, 0xed, 0xbc, 0x8e, 0x2a, 0x86, 0x97,
        0xc1, 0x53, 0x31, 0x67, 0x7e, 0x6e, 0xbf, 0x0b,
    }, result.output_data);

    const invalid = (try executeEthereumPrecompileForTest(std.testing.allocator, .frontier, Contract.ecrecover.toAddress(), &.{}, 3001)).?;
    try std.testing.expectEqual(Status.success, invalid.status);
    try std.testing.expectEqual(@as(i64, 1), invalid.gas_left);
    try std.testing.expectEqual(@as(usize, 0), invalid.output_data.len);
}

test identity {
    const input = "hello";
    const result = (try executeEthereumPrecompileForTest(std.testing.allocator, .frontier, Contract.identity.toAddress(), input, 18)).?;
    defer std.testing.allocator.free(result.output_data);

    try std.testing.expectEqual(Status.success, result.status);
    try std.testing.expectEqual(@as(i64, 0), result.gas_left);
    try std.testing.expectEqualSlices(u8, input, result.output_data);

    const oog = (try executeEthereumPrecompileForTest(std.testing.allocator, .frontier, Contract.identity.toAddress(), input, 17)).?;
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

    const byzantium = (try executeEthereumPrecompileForTest(std.testing.allocator, .byzantium, Contract.modexp.toAddress(), &eip198_input, 13056)).?;
    defer std.testing.allocator.free(byzantium.output_data);

    try std.testing.expectEqual(Status.success, byzantium.status);
    try std.testing.expectEqual(@as(i64, 0), byzantium.gas_left);
    try std.testing.expectEqualSlices(u8, &expected, byzantium.output_data);

    const byzantium_oog = (try executeEthereumPrecompileForTest(std.testing.allocator, .byzantium, Contract.modexp.toAddress(), &eip198_input, 13055)).?;
    try std.testing.expectEqual(Status.out_of_gas, byzantium_oog.status);

    const berlin = (try executeEthereumPrecompileForTest(std.testing.allocator, .berlin, Contract.modexp.toAddress(), &eip198_input, 1361)).?;
    defer std.testing.allocator.free(berlin.output_data);

    try std.testing.expectEqual(Status.success, berlin.status);
    try std.testing.expectEqual(@as(i64, 1), berlin.gas_left);
    try std.testing.expectEqualSlices(u8, &expected, berlin.output_data);

    const osaka = (try executeEthereumPrecompileForTest(std.testing.allocator, .osaka, Contract.modexp.toAddress(), &eip198_input, 4080)).?;
    defer std.testing.allocator.free(osaka.output_data);

    try std.testing.expectEqual(Status.success, osaka.status);
    try std.testing.expectEqual(@as(i64, 0), osaka.gas_left);
    try std.testing.expectEqualSlices(u8, &expected, osaka.output_data);

    const osaka_oog = (try executeEthereumPrecompileForTest(std.testing.allocator, .osaka, Contract.modexp.toAddress(), &eip198_input, 4079)).?;
    try std.testing.expectEqual(Status.out_of_gas, osaka_oog.status);

    var osaka_zero_head_long_exp: [225]u8 = undefined;
    @memset(&osaka_zero_head_long_exp, 0);
    std.mem.writeInt(u256, osaka_zero_head_long_exp[0..32], 1, .big);
    std.mem.writeInt(u256, osaka_zero_head_long_exp[32..64], 64, .big);
    std.mem.writeInt(u256, osaka_zero_head_long_exp[64..96], 64, .big);
    osaka_zero_head_long_exp[96] = 1;
    @memset(osaka_zero_head_long_exp[161..225], 2);
    const osaka_zero_head_oog = (try executeEthereumPrecompileForTest(std.testing.allocator, .osaka, Contract.modexp.toAddress(), &osaka_zero_head_long_exp, 65_535)).?;
    try std.testing.expectEqual(Status.out_of_gas, osaka_zero_head_oog.status);
    const osaka_zero_head = (try executeEthereumPrecompileForTest(std.testing.allocator, .osaka, Contract.modexp.toAddress(), &osaka_zero_head_long_exp, 65_536)).?;
    defer std.testing.allocator.free(osaka_zero_head.output_data);
    try std.testing.expectEqual(Status.success, osaka_zero_head.status);
    try std.testing.expectEqual(@as(i64, 0), osaka_zero_head.gas_left);

    var small_input: [99]u8 = undefined;
    _ = try std.fmt.hexToBytes(&small_input, "0000000000000000000000000000000000000000000000000000000000000001" ++
        "0000000000000000000000000000000000000000000000000000000000000001" ++
        "0000000000000000000000000000000000000000000000000000000000000001" ++
        "02050d");
    const small = (try executeEthereumPrecompileForTest(std.testing.allocator, .byzantium, Contract.modexp.toAddress(), &small_input, 0)).?;
    defer std.testing.allocator.free(small.output_data);

    try std.testing.expectEqual(Status.success, small.status);
    try std.testing.expectEqual(@as(i64, 0), small.gas_left);
    try std.testing.expectEqualSlices(u8, &[_]u8{6}, small.output_data);

    const small_berlin_oog = (try executeEthereumPrecompileForTest(std.testing.allocator, .berlin, Contract.modexp.toAddress(), &small_input, 199)).?;
    try std.testing.expectEqual(Status.out_of_gas, small_berlin_oog.status);

    const small_osaka_oog = (try executeEthereumPrecompileForTest(std.testing.allocator, .osaka, Contract.modexp.toAddress(), &small_input, 499)).?;
    try std.testing.expectEqual(Status.out_of_gas, small_osaka_oog.status);

    const small_osaka = (try executeEthereumPrecompileForTest(std.testing.allocator, .osaka, Contract.modexp.toAddress(), &small_input, 500)).?;
    defer std.testing.allocator.free(small_osaka.output_data);

    try std.testing.expectEqual(Status.success, small_osaka.status);
    try std.testing.expectEqual(@as(i64, 0), small_osaka.gas_left);
    try std.testing.expectEqualSlices(u8, &[_]u8{6}, small_osaka.output_data);

    var zero_modulus_input: [97]u8 = undefined;
    _ = try std.fmt.hexToBytes(&zero_modulus_input, "0000000000000000000000000000000000000000000000000000000000000000" ++
        "0000000000000000000000000000000000000000000000000000000000000000" ++
        "0000000000000000000000000000000000000000000000000000000000000001" ++
        "00");
    const zero_modulus = (try executeEthereumPrecompileForTest(std.testing.allocator, .berlin, Contract.modexp.toAddress(), &zero_modulus_input, 200)).?;
    defer std.testing.allocator.free(zero_modulus.output_data);

    try std.testing.expectEqual(Status.success, zero_modulus.status);
    try std.testing.expectEqualSlices(u8, &[_]u8{0}, zero_modulus.output_data);

    var zero_complexity_input: [96]u8 = [_]u8{0} ** 96;
    zero_complexity_input[32] = 0x80;
    const zero_complexity = (try executeEthereumPrecompileForTest(std.testing.allocator, .berlin, Contract.modexp.toAddress(), &zero_complexity_input, 200)).?;
    try std.testing.expectEqual(Status.success, zero_complexity.status);
    try std.testing.expectEqual(@as(i64, 0), zero_complexity.gas_left);
    try std.testing.expectEqual(@as(usize, 0), zero_complexity.output_data.len);

    var over_osaka_limit_input: [96]u8 = [_]u8{0} ** 96;
    std.mem.writeInt(u256, over_osaka_limit_input[0..32], @import("eth/precompile.zig").osaka_config.modexp_max_input_len.? + 1, .big);
    const oversized_prague = (try executeEthereumPrecompileForTest(std.testing.allocator, .prague, Contract.modexp.toAddress(), &over_osaka_limit_input, 6000)).?;
    try std.testing.expectEqual(Status.success, oversized_prague.status);

    const oversized_osaka = (try executeEthereumPrecompileForTest(std.testing.allocator, .osaka, Contract.modexp.toAddress(), &over_osaka_limit_input, 6000)).?;
    try std.testing.expectEqual(Status.out_of_gas, oversized_osaka.status);
}

test "P256VERIFY precompile" {
    const ethereum_p256verify_gas = @import("eth/precompile.zig").osaka_config.gas.get(.p256verify);
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

    try std.testing.expectEqual(null, try executeEthereumPrecompileForTest(std.testing.allocator, .prague, Contract.p256verify.toAddress(), &input, ethereum_p256verify_gas));

    const oog = (try executeEthereumPrecompileForTest(std.testing.allocator, .osaka, Contract.p256verify.toAddress(), &input, ethereum_p256verify_gas - 1)).?;
    try std.testing.expectEqual(Status.out_of_gas, oog.status);

    const valid = (try executeEthereumPrecompileForTest(std.testing.allocator, .osaka, Contract.p256verify.toAddress(), &input, ethereum_p256verify_gas + 1)).?;
    defer std.testing.allocator.free(valid.output_data);

    var expected = [_]u8{0} ** 32;
    expected[31] = 1;
    try std.testing.expectEqual(Status.success, valid.status);
    try std.testing.expectEqual(@as(i64, 1), valid.gas_left);
    try std.testing.expectEqualSlices(u8, &expected, valid.output_data);

    var wrong_hash = input;
    wrong_hash[0] ^= 0x01;
    const invalid_signature = (try executeEthereumPrecompileForTest(std.testing.allocator, .osaka, Contract.p256verify.toAddress(), &wrong_hash, ethereum_p256verify_gas + 1)).?;
    try std.testing.expectEqual(Status.success, invalid_signature.status);
    try std.testing.expectEqual(@as(i64, 1), invalid_signature.gas_left);
    try std.testing.expectEqual(@as(usize, 0), invalid_signature.output_data.len);

    const invalid_length = (try executeEthereumPrecompileForTest(std.testing.allocator, .osaka, Contract.p256verify.toAddress(), input[0..159], ethereum_p256verify_gas + 1)).?;
    try std.testing.expectEqual(Status.success, invalid_length.status);
    try std.testing.expectEqual(@as(i64, 1), invalid_length.gas_left);
    try std.testing.expectEqual(@as(usize, 0), invalid_length.output_data.len);

    var infinity_key = input;
    @memset(infinity_key[96..160], 0);
    const invalid_key = (try executeEthereumPrecompileForTest(std.testing.allocator, .osaka, Contract.p256verify.toAddress(), &infinity_key, ethereum_p256verify_gas + 1)).?;
    try std.testing.expectEqual(Status.success, invalid_key.status);
    try std.testing.expectEqual(@as(i64, 1), invalid_key.gas_left);
    try std.testing.expectEqual(@as(usize, 0), invalid_key.output_data.len);
}

test "P256VERIFY gas is selected by a derived exact config" {
    const config = comptime resolved: {
        var result = @import("eth/precompile.zig").berlin_config;
        result.gas.set(.p256verify, 3_450);
        break :resolved result;
    };
    const result = try executeContract(.p256verify, .{
        .allocator = std.testing.allocator,
        .input_data = &.{},
        .gas = 3_451,
    }, config);

    try std.testing.expectEqual(Status.success, result.status);
    try std.testing.expectEqual(@as(i64, 1), result.gas_left);
    try std.testing.expectEqual(@as(usize, 0), result.output_data.len);
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

    const add_result = (try executeEthereumPrecompileForTest(std.testing.allocator, .byzantium, Contract.bn254_add.toAddress(), &add_input, 500)).?;
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

    const mul_result = (try executeEthereumPrecompileForTest(std.testing.allocator, .istanbul, Contract.bn254_mul.toAddress(), &mul_input, 6001)).?;
    defer std.testing.allocator.free(mul_result.output_data);

    try std.testing.expectEqual(Status.success, mul_result.status);
    try std.testing.expectEqual(@as(i64, 1), mul_result.gas_left);
    try std.testing.expectEqualSlices(u8, &tripled_expected, mul_result.output_data);

    const invalid = (try executeEthereumPrecompileForTest(std.testing.allocator, .byzantium, Contract.bn254_add.toAddress(), &[_]u8{0xff} ** 32, 500)).?;
    try std.testing.expectEqual(Status.failure, invalid.status);
}

test "bn254 pairing" {
    var true_output = [_]u8{0} ** 32;
    true_output[31] = 1;

    const empty = (try executeEthereumPrecompileForTest(std.testing.allocator, .byzantium, Contract.bn254_pairing.toAddress(), &.{}, 100_001)).?;
    defer std.testing.allocator.free(empty.output_data);

    try std.testing.expectEqual(Status.success, empty.status);
    try std.testing.expectEqual(@as(i64, 1), empty.gas_left);
    try std.testing.expectEqualSlices(u8, &true_output, empty.output_data);

    const repriced = (try executeEthereumPrecompileForTest(std.testing.allocator, .istanbul, Contract.bn254_pairing.toAddress(), &.{}, 45_000)).?;
    defer std.testing.allocator.free(repriced.output_data);

    try std.testing.expectEqual(Status.success, repriced.status);
    try std.testing.expectEqual(@as(i64, 0), repriced.gas_left);
    try std.testing.expectEqualSlices(u8, &true_output, repriced.output_data);

    const oog = (try executeEthereumPrecompileForTest(std.testing.allocator, .istanbul, Contract.bn254_pairing.toAddress(), &.{}, 44_999)).?;
    try std.testing.expectEqual(Status.out_of_gas, oog.status);

    const malformed = (try executeEthereumPrecompileForTest(std.testing.allocator, .istanbul, Contract.bn254_pairing.toAddress(), &[_]u8{0}, 45_000)).?;
    try std.testing.expectEqual(Status.failure, malformed.status);
}

test "bn254 pairing rejects field elements outside modulus" {
    var input = [_]u8{0} ** bn254_pair_size;
    _ = try std.fmt.hexToBytes(input[0..32], "30644e72e131a029b85045b68181585d97816a916871ca8d3c208c16d87cfd47");

    const invalid = (try executeEthereumPrecompileForTest(std.testing.allocator, .byzantium, Contract.bn254_pairing.toAddress(), &input, 180_000)).?;
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

    const result = (try executeEthereumPrecompileForTest(std.testing.allocator, .istanbul, Contract.blake2f.toAddress(), &input, 12)).?;
    defer std.testing.allocator.free(result.output_data);

    try std.testing.expectEqual(Status.success, result.status);
    try std.testing.expectEqual(@as(i64, 0), result.gas_left);
    try std.testing.expectEqualSlices(u8, &expected, result.output_data);

    input[2] = 0x04;
    input[3] = 0x00;
    _ = try std.fmt.hexToBytes(&expected, "689419d2bf32b5a9901a2c733b9946727026a60d8773117eabb35f04a52cdcf1" ++
        "b8fb4473454cf03d46c36a10b3f784aae4dc80a24424960e66a8ad5a8c2bfb30");
    const long_rounds = (try executeEthereumPrecompileForTest(std.testing.allocator, .istanbul, Contract.blake2f.toAddress(), &input, 1024)).?;
    defer std.testing.allocator.free(long_rounds.output_data);

    try std.testing.expectEqual(Status.success, long_rounds.status);
    try std.testing.expectEqualSlices(u8, &expected, long_rounds.output_data);

    input[2] = 0x00;
    input[3] = 0x0c;
    const oog = (try executeEthereumPrecompileForTest(std.testing.allocator, .istanbul, Contract.blake2f.toAddress(), &input, 11)).?;
    try std.testing.expectEqual(Status.out_of_gas, oog.status);

    input[212] = 2;
    const invalid_flag = (try executeEthereumPrecompileForTest(std.testing.allocator, .istanbul, Contract.blake2f.toAddress(), &input, 12)).?;
    try std.testing.expectEqual(Status.failure, invalid_flag.status);
}

test sha256 {
    const result = (try executeEthereumPrecompileForTest(std.testing.allocator, .frontier, Contract.sha256.toAddress(), &.{}, 60)).?;
    defer std.testing.allocator.free(result.output_data);

    try std.testing.expectEqual(Status.success, result.status);
    try std.testing.expectEqual(@as(i64, 0), result.gas_left);
    try std.testing.expectEqualSlices(u8, &[_]u8{
        0xe3, 0xb0, 0xc4, 0x42, 0x98, 0xfc, 0x1c, 0x14,
        0x9a, 0xfb, 0xf4, 0xc8, 0x99, 0x6f, 0xb9, 0x24,
        0x27, 0xae, 0x41, 0xe4, 0x64, 0x9b, 0x93, 0x4c,
        0xa4, 0x95, 0x99, 0x1b, 0x78, 0x52, 0xb8, 0x55,
    }, result.output_data);

    const oog = (try executeEthereumPrecompileForTest(std.testing.allocator, .frontier, Contract.sha256.toAddress(), &.{}, 59)).?;
    try std.testing.expectEqual(Status.out_of_gas, oog.status);
    try std.testing.expectEqual(@as(usize, 0), oog.output_data.len);
}

test ripemd160 {
    const result = (try executeEthereumPrecompileForTest(std.testing.allocator, .frontier, Contract.ripemd160.toAddress(), "abc", 720)).?;
    defer std.testing.allocator.free(result.output_data);

    try std.testing.expectEqual(Status.success, result.status);
    try std.testing.expectEqual(@as(i64, 0), result.gas_left);
    try std.testing.expectEqualSlices(u8, &[_]u8{
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x8e, 0xb2, 0x08, 0xf7,
        0xe0, 0x5d, 0x98, 0x7a, 0x9b, 0x04, 0x4a, 0x8e,
        0x98, 0xc6, 0xb0, 0x87, 0xf1, 0x5a, 0x0b, 0xfc,
    }, result.output_data);

    const oog = (try executeEthereumPrecompileForTest(std.testing.allocator, .frontier, Contract.ripemd160.toAddress(), "abc", 719)).?;
    try std.testing.expectEqual(Status.out_of_gas, oog.status);
    try std.testing.expectEqual(@as(usize, 0), oog.output_data.len);
}
