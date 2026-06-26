const std = @import("std");
const Spec = @import("./spec.zig").Spec;
const uint256 = @import("./uint256.zig");

pub const blob_gas_per_blob: u64 = 131_072;
pub const min_blob_base_fee: u256 = 1;
pub const blob_base_cost: u64 = 8_192;
pub const cancun_blob_base_fee_update_fraction: u256 = 3_338_477;
pub const prague_blob_base_fee_update_fraction: u256 = 5_007_716;
pub const blob_base_fee_update_fraction: u256 = cancun_blob_base_fee_update_fraction;
pub const authorization_intrinsic_gas: u64 = 25_000;
pub const access_list_address_gas: u64 = 2_400;
pub const access_list_storage_key_gas: u64 = 1_900;
pub const create_transaction_gas: u64 = 32_000;
pub const initcode_word_gas: u64 = 2;
pub const max_initcode_size: usize = 49_152;
pub const max_transaction_gas_limit: u64 = 16_777_216;

pub const AccessListCounts = struct {
    addresses: usize = 0,
    storage_keys: usize = 0,
};

pub const BlobSchedule = struct {
    target: u64,
    max: u64,
    base_fee_update_fraction: u256,
};

pub const ExcessBlobGasInput = struct {
    parent_excess_blob_gas: u256,
    parent_blob_gas_used: u256,
    parent_base_fee_per_gas: u256,
};

/// Normalized transaction envelope kind used by semantic validation.
/// This is not a fixture name or an encoded transaction byte; callers infer it
/// from their own transaction representation before calling `validate`.
pub const TxKind = enum {
    legacy,
    access_list,
    dynamic_fee,
    blob,
    set_code,
};

/// Sender-code category used by pre-execution transaction validation.
/// Delegation code is split from normal code so EIP-7702 senders can be
/// accepted while EIP-3607 still rejects non-delegating contract senders.
pub const SenderCodeKind = enum {
    empty,
    delegation,
    non_delegating,
};

/// Core transaction validation failures. Fixture runners can translate these
/// into their own exception names without making core validation depend on
/// fixture input/output strings.
pub const ValidationError = enum {
    intrinsic_gas_too_low,
    intrinsic_gas_below_floor_gas_cost,
    insufficient_account_funds,
    insufficient_max_fee_per_gas,
    priority_greater_than_max_fee_per_gas,
    insufficient_max_fee_per_blob_gas,
    gas_allowance_exceeded,
    nonce_is_max,
    type_1_tx_pre_fork,
    type_2_tx_pre_fork,
    type_3_tx_pre_fork,
    type_4_tx_pre_fork,
    type_3_tx_contract_creation,
    type_3_tx_zero_blobs,
    type_3_tx_blob_count_exceeded,
    type_3_tx_invalid_blob_versioned_hash,
    initcode_size_exceeded,
    sender_not_eoa,
    type_4_empty_authorization_list,
    type_4_tx_contract_creation,
};

pub const IntrinsicGasOptions = struct {
    authorization_count: usize = 0,
    access_list_counts: AccessListCounts = .{},
    is_create: bool = false,
};

/// Facts required for pre-execution transaction validation.
/// Callers own decoding and fork/fixture-specific mapping; this struct is the
/// reusable semantic boundary used by the executor and EEST adapter.
pub const ValidationInput = struct {
    spec: Spec,
    kind: TxKind = .legacy,
    is_create: bool = false,
    gas_limit: u64,
    input: []const u8 = &.{},
    value: u256 = 0,
    gas_price: u256 = 0,
    base_fee: u256 = 0,
    block_gas_limit: u64 = 0,
    blob_base_fee: u256 = 0,
    max_fee_per_gas: ?u256 = null,
    max_priority_fee_per_gas: ?u256 = null,
    max_fee_per_blob_gas: ?u256 = null,
    sender_balance: u256 = 0,
    sender_nonce: u64 = 0,
    sender_code_kind: SenderCodeKind = .empty,
    authorization_count: usize = 0,
    access_list_counts: AccessListCounts = .{},
    blob_hashes: []const u256 = &.{},
};

pub fn intrinsicGas(spec: Spec, input: []const u8, authorization_count: usize, access_list_counts: AccessListCounts) ?u64 {
    return intrinsicGasForTransaction(spec, input, .{
        .authorization_count = authorization_count,
        .access_list_counts = access_list_counts,
    });
}

pub fn intrinsicGasForTransaction(spec: Spec, input: []const u8, options: IntrinsicGasOptions) ?u64 {
    var gas: u64 = 21_000;
    if (options.is_create) {
        gas = std.math.add(u64, gas, create_transaction_gas) catch return null;
    }
    const non_zero_byte_cost: u64 = if (spec.isImpl(.istanbul)) 16 else 68;
    for (input) |byte| {
        const byte_cost: u64 = if (byte == 0) 4 else non_zero_byte_cost;
        gas = std.math.add(u64, gas, byte_cost) catch return null;
    }
    const access_list_address_count = std.math.cast(u64, options.access_list_counts.addresses) orelse return null;
    const access_list_storage_key_count = std.math.cast(u64, options.access_list_counts.storage_keys) orelse return null;
    const access_list_address_cost = std.math.mul(u64, access_list_address_count, access_list_address_gas) catch return null;
    const access_list_storage_key_cost = std.math.mul(u64, access_list_storage_key_count, access_list_storage_key_gas) catch return null;
    gas = std.math.add(u64, gas, access_list_address_cost) catch return null;
    gas = std.math.add(u64, gas, access_list_storage_key_cost) catch return null;
    if (options.is_create and spec.isImpl(.shanghai)) {
        const words = std.math.cast(u64, wordCount(input.len)) orelse return null;
        const initcode_cost = std.math.mul(u64, words, initcode_word_gas) catch return null;
        gas = std.math.add(u64, gas, initcode_cost) catch return null;
    }
    if (spec.isImpl(.prague)) {
        const auth_count = std.math.cast(u64, options.authorization_count) orelse return null;
        const auth_cost = std.math.mul(u64, auth_count, authorization_intrinsic_gas) catch return null;
        gas = std.math.add(u64, gas, auth_cost) catch return null;
    }
    return gas;
}

pub fn minimumGas(spec: Spec, input: []const u8, authorization_count: usize, access_list_counts: AccessListCounts) ?u64 {
    return minimumGasForTransaction(spec, input, .{
        .authorization_count = authorization_count,
        .access_list_counts = access_list_counts,
    });
}

pub fn minimumGasForTransaction(spec: Spec, input: []const u8, options: IntrinsicGasOptions) ?u64 {
    const intrinsic = intrinsicGasForTransaction(spec, input, options) orelse return null;
    if (!spec.isImpl(.prague)) return intrinsic;

    const floor = floorGas(spec, input) orelse return null;
    return @max(intrinsic, floor);
}

pub fn floorGas(spec: Spec, input: []const u8) ?u64 {
    if (!spec.isImpl(.prague)) return null;
    const tokens = calldataTokenCount(input) orelse return null;
    const floor_data_cost = std.math.mul(u64, tokens, 10) catch return null;
    return std.math.add(u64, 21_000, floor_data_cost) catch return null;
}

pub fn validate(input: ValidationInput) ?ValidationError {
    if (preForkError(input.spec, input.kind)) |err| return err;

    if (input.kind == .set_code) {
        if (input.authorization_count == 0) return .type_4_empty_authorization_list;
        if (input.is_create) return .type_4_tx_contract_creation;
        if (input.sender_code_kind == .non_delegating) return .sender_not_eoa;
    } else if (input.spec.isImpl(.london) and input.sender_code_kind == .non_delegating) {
        return .sender_not_eoa;
    }

    if (input.sender_nonce == std.math.maxInt(u64)) return .nonce_is_max;

    if (input.kind == .blob) {
        if (input.is_create) return .type_3_tx_contract_creation;
        if (input.blob_hashes.len == 0) return .type_3_tx_zero_blobs;
        if (input.blob_hashes.len > maxBlobCount(input.spec)) return .type_3_tx_blob_count_exceeded;
        for (input.blob_hashes) |hash| {
            if (blobVersion(hash) != 0x01) return .type_3_tx_invalid_blob_versioned_hash;
        }
    }

    if (input.kind == .dynamic_fee or input.kind == .blob or input.kind == .set_code) {
        const max_fee = input.max_fee_per_gas orelse 0;
        const priority_fee = input.max_priority_fee_per_gas orelse 0;
        if (priority_fee > max_fee) return .priority_greater_than_max_fee_per_gas;
        if (max_fee < input.base_fee) return .insufficient_max_fee_per_gas;
    }

    if (input.kind == .blob) {
        const max_blob_fee = input.max_fee_per_blob_gas orelse 0;
        if (max_blob_fee < input.blob_base_fee) return .insufficient_max_fee_per_blob_gas;
    }

    if ((input.kind == .legacy or input.kind == .access_list) and input.spec.isImpl(.london) and input.gas_price < input.base_fee) {
        return .insufficient_max_fee_per_gas;
    }

    if (input.is_create and input.spec.isImpl(.shanghai) and input.input.len > max_initcode_size) {
        return .initcode_size_exceeded;
    }

    const intrinsic = intrinsicGasForTransaction(input.spec, input.input, .{
        .authorization_count = input.authorization_count,
        .access_list_counts = input.access_list_counts,
        .is_create = input.is_create,
    }) orelse return .intrinsic_gas_too_low;
    if (input.gas_limit < intrinsic) return .intrinsic_gas_too_low;

    if (floorGas(input.spec, input.input)) |floor| {
        if (input.gas_limit < floor) return .intrinsic_gas_below_floor_gas_cost;
    }

    if (input.spec.isImpl(.osaka) and input.gas_limit > max_transaction_gas_limit) {
        return .gas_allowance_exceeded;
    }

    if (input.block_gas_limit != 0 and input.gas_limit > input.block_gas_limit) {
        return .gas_allowance_exceeded;
    }

    const required_balance = maxPrepaymentCost(input) orelse return .insufficient_account_funds;
    if (input.sender_balance < required_balance) return .insufficient_account_funds;

    return null;
}

pub fn maxPrepaymentCost(input: ValidationInput) ?u256 {
    const gas_price = switch (input.kind) {
        .legacy, .access_list => input.gas_price,
        .dynamic_fee, .blob, .set_code => input.max_fee_per_gas orelse return null,
    };
    const blob_fee = if (input.kind == .blob) input.max_fee_per_blob_gas orelse return null else 0;
    const gas_cost = uint256.checkedMul(@as(u256, input.gas_limit), gas_price) orelse return null;
    const blob_count_u256: u256 = @intCast(if (input.kind == .blob) input.blob_hashes.len else 0);
    const blob_gas = uint256.checkedMul(blob_count_u256, blob_gas_per_blob) orelse return null;
    const blob_cost = uint256.checkedMul(blob_gas, blob_fee) orelse return null;
    const transaction_cost = uint256.checkedAdd(gas_cost, blob_cost) orelse return null;
    return uint256.checkedAdd(transaction_cost, input.value);
}

pub fn prepaymentCost(gas_limit: u64, gas_price: u256, blob_base_fee: u256, blob_count: usize) ?u256 {
    const gas_cost = uint256.checkedMul(@as(u256, gas_limit), gas_price) orelse return null;
    const blob_count_u256: u256 = @intCast(blob_count);
    const blob_gas = uint256.checkedMul(blob_count_u256, blob_gas_per_blob) orelse return null;
    const blob_cost = uint256.checkedMul(blob_gas, blob_base_fee) orelse return null;
    return uint256.checkedAdd(gas_cost, blob_cost);
}

pub fn calldataTokenCount(input: []const u8) ?u64 {
    var tokens: u64 = 0;
    for (input) |byte| {
        const byte_tokens: u64 = if (byte == 0) 1 else 4;
        tokens = std.math.add(u64, tokens, byte_tokens) catch return null;
    }
    return tokens;
}

pub fn blobSchedule(spec: Spec) ?BlobSchedule {
    if (!spec.isImpl(.cancun)) return null;
    if (spec.isImpl(.prague)) {
        return .{
            .target = 6,
            .max = 9,
            .base_fee_update_fraction = prague_blob_base_fee_update_fraction,
        };
    }
    return .{
        .target = 3,
        .max = 6,
        .base_fee_update_fraction = cancun_blob_base_fee_update_fraction,
    };
}

pub fn blobBaseFee(excess_blob_gas: u256) ?u256 {
    return blobBaseFeeForSchedule(.{
        .target = 3,
        .max = 6,
        .base_fee_update_fraction = cancun_blob_base_fee_update_fraction,
    }, excess_blob_gas);
}

pub fn blobBaseFeeForSpec(spec: Spec, excess_blob_gas: u256) ?u256 {
    const schedule = blobSchedule(spec) orelse return 0;
    return blobBaseFeeForSchedule(schedule, excess_blob_gas);
}

pub fn blobBaseFeeForSchedule(schedule: BlobSchedule, excess_blob_gas: u256) ?u256 {
    return fakeExponential(min_blob_base_fee, excess_blob_gas, schedule.base_fee_update_fraction);
}

pub fn calcExcessBlobGas(spec: Spec, input: ExcessBlobGasInput) ?u256 {
    const schedule = blobSchedule(spec) orelse return 0;
    return calcExcessBlobGasForSchedule(schedule, spec.isImpl(.osaka), input);
}

pub fn calcExcessBlobGasForSchedule(schedule: BlobSchedule, apply_reserve_price: bool, input: ExcessBlobGasInput) ?u256 {
    if (schedule.max == 0 or schedule.max < schedule.target) return null;

    const target_blob_gas = uint256.checkedMul(@as(u256, blob_gas_per_blob), @as(u256, schedule.target)) orelse return null;
    const total_blob_gas = uint256.checkedAdd(input.parent_excess_blob_gas, input.parent_blob_gas_used) orelse return null;
    if (total_blob_gas < target_blob_gas) return 0;

    if (apply_reserve_price) {
        const parent_blob_base_fee = blobBaseFeeForSchedule(schedule, input.parent_excess_blob_gas) orelse return null;
        const execution_reserve_price = uint256.checkedMul(@as(u256, blob_base_cost), input.parent_base_fee_per_gas) orelse return null;
        const blob_price = uint256.checkedMul(@as(u256, blob_gas_per_blob), parent_blob_base_fee) orelse return null;
        if (execution_reserve_price > blob_price) {
            const headroom = schedule.max - schedule.target;
            const scaled_used = uint256.checkedMul(input.parent_blob_gas_used, @as(u256, headroom)) orelse return null;
            const adjustment = @divFloor(scaled_used, @as(u256, schedule.max));
            return uint256.checkedAdd(input.parent_excess_blob_gas, adjustment);
        }
    }

    return total_blob_gas - target_blob_gas;
}

pub fn fakeExponential(factor: u256, numerator: u256, denominator: u256) ?u256 {
    var i: u256 = 1;
    var output: u256 = 0;
    var numerator_accum = uint256.checkedMul(factor, denominator) orelse return null;
    while (numerator_accum > 0) : (i += 1) {
        output = uint256.checkedAdd(output, numerator_accum) orelse return null;
        const next_numerator = uint256.checkedMul(numerator_accum, numerator) orelse return null;
        const next_denominator = uint256.checkedMul(denominator, i) orelse return null;
        numerator_accum = @divFloor(next_numerator, next_denominator);
    }
    return @divFloor(output, denominator);
}

fn preForkError(spec: Spec, kind: TxKind) ?ValidationError {
    return switch (kind) {
        .legacy => null,
        .access_list => if (spec.isImpl(.berlin)) null else .type_1_tx_pre_fork,
        .dynamic_fee => if (spec.isImpl(.london)) null else .type_2_tx_pre_fork,
        .blob => if (spec.isImpl(.cancun)) null else .type_3_tx_pre_fork,
        .set_code => if (spec.isImpl(.prague)) null else .type_4_tx_pre_fork,
    };
}

fn maxBlobCount(spec: Spec) usize {
    const schedule = blobSchedule(spec) orelse return 0;
    return std.math.cast(usize, schedule.max) orelse std.math.maxInt(usize);
}

fn blobVersion(hash: u256) u8 {
    return @intCast(hash >> 248);
}

fn wordCount(len: usize) usize {
    return (len + 31) / 32;
}

test "transaction gas helpers" {
    try std.testing.expectEqual(@as(u64, 21_072), intrinsicGas(.byzantium, &.{ 0, 1 }, 0, .{}));
    try std.testing.expectEqual(@as(u64, 21_020), intrinsicGas(.istanbul, &.{ 0, 1 }, 0, .{}));
    try std.testing.expectEqual(@as(u64, 46_020), intrinsicGas(.prague, &.{ 0, 1 }, 1, .{}));
    try std.testing.expectEqual(@as(u64, 29_120), intrinsicGas(.berlin, &.{ 0, 1 }, 0, .{
        .addresses = 1,
        .storage_keys = 3,
    }));
    try std.testing.expectEqual(@as(u64, 5), calldataTokenCount(&.{ 0, 1 }));
    try std.testing.expectEqual(@as(u64, 21_020), minimumGas(.istanbul, &.{ 0, 1 }, 0, .{}));
    try std.testing.expectEqual(@as(u64, 21_050), minimumGas(.prague, &.{ 0, 1 }, 0, .{}));
    try std.testing.expectEqual(@as(u64, 46_020), minimumGas(.prague, &.{ 0, 1 }, 1, .{}));
    try std.testing.expectEqual(@as(u64, 53_010), intrinsicGasForTransaction(.shanghai, &.{ 0, 0 }, .{ .is_create = true }));
    try std.testing.expectEqual(@as(u256, 1), blobBaseFee(0x0e0000));
    try std.testing.expectEqual(@as(?BlobSchedule, null), blobSchedule(.shanghai));
    try std.testing.expectEqual(@as(u64, 6), blobSchedule(.cancun).?.max);
    try std.testing.expectEqual(cancun_blob_base_fee_update_fraction, blobSchedule(.cancun).?.base_fee_update_fraction);
    try std.testing.expectEqual(@as(u64, 9), blobSchedule(.osaka).?.max);
    try std.testing.expectEqual(prague_blob_base_fee_update_fraction, blobSchedule(.osaka).?.base_fee_update_fraction);
    try std.testing.expectEqual(@as(u256, 19), blobBaseFeeForSpec(.cancun, 10_000_000));
    try std.testing.expectEqual(@as(u256, 7), blobBaseFeeForSpec(.osaka, 10_000_000));
    try std.testing.expectEqual(@as(u256, 786_432), calcExcessBlobGas(.prague, .{
        .parent_excess_blob_gas = 786_432,
        .parent_blob_gas_used = 786_432,
        .parent_base_fee_per_gas = 1_000_000,
    }));
    try std.testing.expectEqual(@as(u256, 1_048_576), calcExcessBlobGas(.osaka, .{
        .parent_excess_blob_gas = 786_432,
        .parent_blob_gas_used = 786_432,
        .parent_base_fee_per_gas = 1_000_000,
    }));
}

test "transaction prepayment includes blob gas" {
    try std.testing.expectEqual(@as(u256, 4_286_432), prepaymentCost(500_000, 7, 1, 6));
}

test "transaction validation rejects intrinsic gas below limit" {
    try std.testing.expectEqual(ValidationError.intrinsic_gas_too_low, validate(.{
        .spec = .cancun,
        .gas_limit = 21_000,
        .input = &.{0xff},
        .sender_balance = 1_000_000,
    }).?);
}

test "transaction validation rejects Prague floor gas" {
    try std.testing.expectEqual(ValidationError.intrinsic_gas_below_floor_gas_cost, validate(.{
        .spec = .prague,
        .gas_limit = 21_100,
        .input = &.{ 1, 1, 1, 1 },
        .sender_balance = 1_000_000,
    }).?);
}

test "transaction validation checks max fee balance" {
    try std.testing.expectEqual(ValidationError.insufficient_account_funds, validate(.{
        .spec = .cancun,
        .kind = .blob,
        .gas_limit = 21_000,
        .max_fee_per_gas = 10,
        .max_priority_fee_per_gas = 0,
        .max_fee_per_blob_gas = 2,
        .base_fee = 7,
        .blob_base_fee = 1,
        .blob_hashes = &.{@as(u256, 0x01) << 248},
        .sender_balance = 21_000 * 10 + blob_gas_per_blob * 2 - 1,
    }).?);
}

test "transaction validation rejects typed transaction before fork" {
    try std.testing.expectEqual(ValidationError.type_2_tx_pre_fork, validate(.{
        .spec = .berlin,
        .kind = .dynamic_fee,
        .gas_limit = 21_000,
        .max_fee_per_gas = 1,
        .sender_balance = 21_000,
    }).?);
}

test "transaction validation rejects non-EOA sender after London" {
    try std.testing.expectEqual(ValidationError.sender_not_eoa, validate(.{
        .spec = .cancun,
        .gas_limit = 21_000,
        .sender_code_kind = .non_delegating,
        .sender_balance = 21_000,
    }).?);
    try std.testing.expectEqual(@as(?ValidationError, null), validate(.{
        .spec = .berlin,
        .gas_limit = 21_000,
        .sender_code_kind = .non_delegating,
        .sender_balance = 21_000,
    }));
}

test "transaction validation rejects nonce overflow" {
    try std.testing.expectEqual(ValidationError.nonce_is_max, validate(.{
        .spec = .cancun,
        .is_create = true,
        .gas_limit = 100_000,
        .gas_price = 1,
        .sender_nonce = std.math.maxInt(u64),
        .sender_balance = 100_000,
    }).?);
}

test "transaction validation rejects blob contract creation" {
    try std.testing.expectEqual(ValidationError.type_3_tx_contract_creation, validate(.{
        .spec = .cancun,
        .kind = .blob,
        .is_create = true,
        .gas_limit = 100_000,
        .max_fee_per_gas = 7,
        .max_priority_fee_per_gas = 0,
        .max_fee_per_blob_gas = 1,
        .base_fee = 7,
        .blob_base_fee = 1,
        .blob_hashes = &.{@as(u256, 0x01) << 248},
        .sender_balance = 1_000_000,
    }).?);
}

test "transaction validation rejects block gas allowance" {
    try std.testing.expectEqual(ValidationError.gas_allowance_exceeded, validate(.{
        .spec = .cancun,
        .gas_limit = 90_000,
        .block_gas_limit = 80_000,
        .gas_price = 1,
        .sender_balance = 90_000,
    }).?);
}

test "transaction validation applies Osaka transaction gas cap" {
    try std.testing.expectEqual(@as(?ValidationError, null), validate(.{
        .spec = .osaka,
        .gas_limit = max_transaction_gas_limit,
        .gas_price = 1,
        .sender_balance = max_transaction_gas_limit,
    }));
    try std.testing.expectEqual(ValidationError.gas_allowance_exceeded, validate(.{
        .spec = .osaka,
        .gas_limit = max_transaction_gas_limit + 1,
        .gas_price = 1,
        .sender_balance = max_transaction_gas_limit + 1,
    }).?);
    try std.testing.expectEqual(@as(?ValidationError, null), validate(.{
        .spec = .prague,
        .gas_limit = max_transaction_gas_limit + 1,
        .gas_price = 1,
        .sender_balance = max_transaction_gas_limit + 1,
    }));
}

test "transaction validation rejects old type gas price below base fee" {
    try std.testing.expectEqual(ValidationError.insufficient_max_fee_per_gas, validate(.{
        .spec = .cancun,
        .gas_limit = 21_000,
        .gas_price = 999,
        .base_fee = 1_000,
        .sender_balance = 21_000_000,
    }).?);
}

test "transaction validation rejects blob shape errors" {
    try std.testing.expectEqual(ValidationError.type_3_tx_zero_blobs, validate(.{
        .spec = .cancun,
        .kind = .blob,
        .gas_limit = 21_000,
        .max_fee_per_gas = 1,
        .max_fee_per_blob_gas = 1,
        .sender_balance = 1_000_000,
    }).?);
    try std.testing.expectEqual(ValidationError.type_3_tx_invalid_blob_versioned_hash, validate(.{
        .spec = .cancun,
        .kind = .blob,
        .gas_limit = 21_000,
        .max_fee_per_gas = 1,
        .max_fee_per_blob_gas = 1,
        .blob_hashes = &.{@as(u256, 0x02) << 248},
        .sender_balance = 1_000_000,
    }).?);
}

test "transaction validation rejects set-code shape errors" {
    try std.testing.expectEqual(ValidationError.type_4_empty_authorization_list, validate(.{
        .spec = .prague,
        .kind = .set_code,
        .gas_limit = 21_000,
        .max_fee_per_gas = 1,
        .sender_balance = 1_000_000,
    }).?);
    try std.testing.expectEqual(ValidationError.type_4_tx_contract_creation, validate(.{
        .spec = .prague,
        .kind = .set_code,
        .is_create = true,
        .gas_limit = 100_000,
        .max_fee_per_gas = 1,
        .authorization_count = 1,
        .sender_balance = 1_000_000,
    }).?);
    try std.testing.expectEqual(ValidationError.sender_not_eoa, validate(.{
        .spec = .prague,
        .kind = .set_code,
        .gas_limit = 100_000,
        .max_fee_per_gas = 1,
        .authorization_count = 1,
        .sender_code_kind = .non_delegating,
        .sender_balance = 1_000_000,
    }).?);
}

test "transaction validation rejects oversized initcode" {
    var initcode = [_]u8{0} ** (max_initcode_size + 1);
    try std.testing.expectEqual(ValidationError.initcode_size_exceeded, validate(.{
        .spec = .shanghai,
        .is_create = true,
        .gas_limit = 1_000_000,
        .input = &initcode,
        .sender_balance = 1_000_000,
    }).?);
}
