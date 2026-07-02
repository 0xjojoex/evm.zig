const std = @import("std");

const blob = @import("./blob.zig");
const gas = @import("./gas.zig");
const Transaction = @import("./Transaction.zig");
const Spec = @import("../spec.zig").Spec;
const uint256 = @import("../uint256.zig");

pub const TxKind = Transaction.TxKind;
pub const AccessListCounts = Transaction.AccessListCounts;

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
    nonce_mismatch,
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
    tx_nonce: ?u64 = null,
    sender_code_kind: SenderCodeKind = .empty,
    authorization_count: usize = 0,
    access_list_counts: AccessListCounts = .{},
    blob_hashes: []const u256 = &.{},
};

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
    if (input.tx_nonce) |tx_nonce| {
        if (tx_nonce != input.sender_nonce) return .nonce_mismatch;
    }

    if (input.kind == .blob) {
        if (input.is_create) return .type_3_tx_contract_creation;
        if (input.blob_hashes.len == 0) return .type_3_tx_zero_blobs;
        if (input.blob_hashes.len > blob.maxBlobCount(input.spec)) return .type_3_tx_blob_count_exceeded;
        for (input.blob_hashes) |hash| {
            if (blob.blobVersion(hash) != 0x01) return .type_3_tx_invalid_blob_versioned_hash;
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

    if (input.is_create and input.spec.isImpl(.shanghai) and input.input.len > gas.max_initcode_size) {
        return .initcode_size_exceeded;
    }

    const intrinsic = gas.intrinsicGasForTransaction(input.spec, input.input, .{
        .authorization_count = input.authorization_count,
        .access_list_counts = input.access_list_counts,
        .is_create = input.is_create,
    }) orelse return .intrinsic_gas_too_low;
    if (input.gas_limit < intrinsic) return .intrinsic_gas_too_low;

    if (gas.floorGas(input.spec, input.input)) |floor| {
        if (input.gas_limit < floor) return .intrinsic_gas_below_floor_gas_cost;
    }

    if (input.spec.isImpl(.osaka) and input.gas_limit > gas.max_transaction_gas_limit) {
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
    const blob_gas = uint256.checkedMul(blob_count_u256, blob.blob_gas_per_blob) orelse return null;
    const blob_cost = uint256.checkedMul(blob_gas, blob_fee) orelse return null;
    const transaction_cost = uint256.checkedAdd(gas_cost, blob_cost) orelse return null;
    return uint256.checkedAdd(transaction_cost, input.value);
}

pub fn prepaymentCost(gas_limit: u64, gas_price: u256, blob_base_fee: u256, blob_count: usize) ?u256 {
    const gas_cost = uint256.checkedMul(@as(u256, gas_limit), gas_price) orelse return null;
    const blob_count_u256: u256 = @intCast(blob_count);
    const blob_gas = uint256.checkedMul(blob_count_u256, blob.blob_gas_per_blob) orelse return null;
    const blob_cost = uint256.checkedMul(blob_gas, blob_base_fee) orelse return null;
    return uint256.checkedAdd(gas_cost, blob_cost);
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
        .sender_balance = 21_000 * 10 + blob.blob_gas_per_blob * 2 - 1,
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

test "transaction validation rejects nonce mismatch" {
    try std.testing.expectEqual(ValidationError.nonce_mismatch, validate(.{
        .spec = .cancun,
        .gas_limit = 21_000,
        .gas_price = 1,
        .sender_nonce = 7,
        .tx_nonce = 8,
        .sender_balance = 21_000,
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
        .gas_limit = gas.max_transaction_gas_limit,
        .gas_price = 1,
        .sender_balance = gas.max_transaction_gas_limit,
    }));
    try std.testing.expectEqual(ValidationError.gas_allowance_exceeded, validate(.{
        .spec = .osaka,
        .gas_limit = gas.max_transaction_gas_limit + 1,
        .gas_price = 1,
        .sender_balance = gas.max_transaction_gas_limit + 1,
    }).?);
    try std.testing.expectEqual(@as(?ValidationError, null), validate(.{
        .spec = .prague,
        .gas_limit = gas.max_transaction_gas_limit + 1,
        .gas_price = 1,
        .sender_balance = gas.max_transaction_gas_limit + 1,
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
    var initcode = [_]u8{0} ** (gas.max_initcode_size + 1);
    try std.testing.expectEqual(ValidationError.initcode_size_exceeded, validate(.{
        .spec = .shanghai,
        .is_create = true,
        .gas_limit = 1_000_000,
        .input = &initcode,
        .sender_balance = 1_000_000,
    }).?);
}
