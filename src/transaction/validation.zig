const std = @import("std");

const blob = @import("./blob.zig");
const definition_support = @import("../protocol/support.zig");
const gas = @import("./gas.zig");
const Transaction = @import("./types.zig");
const EthRevision = @import("../eth/revision.zig").Revision;
const eth_transaction = @import("../eth/transaction.zig");
const uint256 = @import("../uint256.zig");

pub const TxKind = Transaction.TxKind;
pub const AccessListCounts = Transaction.AccessListCounts;
pub const SenderCodeKind = Transaction.SenderCodeKind;

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
    type_3_tx_max_blob_gas_allowance_exceeded,
    type_3_tx_invalid_blob_versioned_hash,
    initcode_size_exceeded,
    sender_not_eoa,
    type_4_empty_authorization_list,
    type_4_tx_contract_creation,
};

/// Facts required for pre-execution transaction validation.
/// Callers own decoding and fork/fixture-specific mapping; this struct is the
/// reusable semantic boundary used by the executor and EEST adapter.
fn ValidationInput(comptime Protocol: type) type {
    return struct {
        revision: Protocol.Revision,
        kind: TxKind = .legacy,
        is_create: bool = false,
        is_self_transfer: bool = false,
        creates_account: bool = false,
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
}

pub fn For(comptime ProtocolType: type) type {
    return struct {
        const Self = @This();
        const gas_protocol = gas.For(Protocol);

        pub const Protocol = ProtocolType;
        pub const Input = ValidationInput(Protocol);

        pub fn validate(input: Input) ?ValidationError {
            definition_support.assertRevisionSupported(Protocol, input.revision);
            if (Self.inactiveTransactionKindError(input.revision, input.kind)) |err| return err;

            if (input.kind == .set_code) {
                if (Protocol.Transaction.requiresAuthorizationList(input.revision, input.kind) and input.authorization_count == 0) return .type_4_empty_authorization_list;
                if (!Protocol.Transaction.allowsContractCreation(input.revision, input.kind) and input.is_create) return .type_4_tx_contract_creation;
                if (Protocol.Transaction.rejectsNonDelegatingSenderCode(input.revision, input.kind) and input.sender_code_kind == .non_delegating) return .sender_not_eoa;
            } else if (Protocol.Transaction.rejectsNonDelegatingSenderCode(input.revision, input.kind) and input.sender_code_kind == .non_delegating) {
                return .sender_not_eoa;
            }

            if (input.sender_nonce == std.math.maxInt(u64)) return .nonce_is_max;
            if (input.tx_nonce) |tx_nonce| {
                if (tx_nonce != input.sender_nonce) return .nonce_mismatch;
            }

            if (input.kind == .blob) {
                if (!Protocol.Transaction.allowsContractCreation(input.revision, input.kind) and input.is_create) return .type_3_tx_contract_creation;
                if (input.blob_hashes.len == 0) return .type_3_tx_zero_blobs;
                const BlobProtocol = blob.For(Protocol);
                if (input.blob_hashes.len > BlobProtocol.maxBlobCount(input.revision)) return .type_3_tx_max_blob_gas_allowance_exceeded;
                if (input.blob_hashes.len > BlobProtocol.maxBlobCountPerTransaction(input.revision)) return .type_3_tx_blob_count_exceeded;
                for (input.blob_hashes) |hash| {
                    if (!Protocol.Transaction.blobVersionedHashActive(input.revision, blob.blobVersion(hash))) return .type_3_tx_invalid_blob_versioned_hash;
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

            if ((input.kind == .legacy or input.kind == .access_list) and Protocol.Settlement.baseFeeActive(input.revision) and input.gas_price < input.base_fee) {
                return .insufficient_max_fee_per_gas;
            }

            if (input.is_create and input.input.len > gas_protocol.maxInitcodeSize(input.revision)) {
                return .initcode_size_exceeded;
            }

            const intrinsic_options = gas.IntrinsicGasOptions{
                .authorization_count = input.authorization_count,
                .access_list_counts = input.access_list_counts,
                .is_create = input.is_create,
                .value = input.value,
                .is_self_transfer = input.is_self_transfer,
                .creates_account = input.creates_account,
            };
            const intrinsic_regular = gas_protocol.intrinsicRegularGasForTransaction(input.revision, input.input, intrinsic_options) orelse return .intrinsic_gas_too_low;
            const intrinsic_state = gas_protocol.intrinsicStateGasForTransaction(input.revision, intrinsic_options) orelse return .intrinsic_gas_too_low;
            const intrinsic = std.math.add(u64, intrinsic_regular, intrinsic_state) catch return .intrinsic_gas_too_low;
            const floor = gas_protocol.floorGasForTransaction(input.revision, input.input, intrinsic_options);

            if (Protocol.Transaction.intrinsicRegularGasLimit(input.revision)) |regular_intrinsic_limit| {
                var capped_intrinsic = intrinsic_regular;
                if (floor) |floor_gas| capped_intrinsic = @max(capped_intrinsic, floor_gas);
                if (capped_intrinsic > regular_intrinsic_limit) return .intrinsic_gas_too_low;
            }

            if (input.gas_limit < intrinsic) return .intrinsic_gas_too_low;

            if (floor) |floor_gas| {
                if (input.gas_limit < floor_gas) return .intrinsic_gas_below_floor_gas_cost;
            }

            if (Protocol.Transaction.totalGasLimit(input.revision)) |limit| {
                if (input.gas_limit > limit) return .gas_allowance_exceeded;
            }

            if (input.block_gas_limit != 0 and input.gas_limit > input.block_gas_limit) {
                return .gas_allowance_exceeded;
            }

            const required_balance = Self.maxPrepaymentCost(input) orelse return .insufficient_account_funds;
            if (input.sender_balance < required_balance) return .insufficient_account_funds;

            return null;
        }

        pub fn maxPrepaymentCost(input: Input) ?u256 {
            definition_support.assertRevisionSupported(Protocol, input.revision);
            const gas_price = switch (input.kind) {
                .legacy, .access_list => input.gas_price,
                .dynamic_fee, .blob, .set_code => input.max_fee_per_gas orelse return null,
            };
            const blob_fee = if (input.kind == .blob) input.max_fee_per_blob_gas orelse return null else 0;
            const gas_cost = uint256.checkedMul(@as(u256, input.gas_limit), gas_price) orelse return null;
            const blob_gas = blobGasForCount(Protocol, input.revision, if (input.kind == .blob) input.blob_hashes.len else 0) orelse return null;
            const blob_cost = uint256.checkedMul(blob_gas, blob_fee) orelse return null;
            const transaction_cost = uint256.checkedAdd(gas_cost, blob_cost) orelse return null;
            return uint256.checkedAdd(transaction_cost, input.value);
        }

        pub fn prepaymentCost(revision: Protocol.Revision, gas_limit: u64, gas_price: u256, blob_base_fee: u256, blob_count: usize) ?u256 {
            definition_support.assertRevisionSupported(Protocol, revision);
            const gas_cost = uint256.checkedMul(@as(u256, gas_limit), gas_price) orelse return null;
            const blob_gas = blobGasForCount(Protocol, revision, blob_count) orelse return null;
            const blob_cost = uint256.checkedMul(blob_gas, blob_base_fee) orelse return null;
            return uint256.checkedAdd(gas_cost, blob_cost);
        }

        fn inactiveTransactionKindError(revision: Protocol.Revision, kind: TxKind) ?ValidationError {
            if (Protocol.Transaction.kindActive(revision, kind)) return null;
            return switch (kind) {
                .legacy => null,
                .access_list => .type_1_tx_pre_fork,
                .dynamic_fee => .type_2_tx_pre_fork,
                .blob => .type_3_tx_pre_fork,
                .set_code => .type_4_tx_pre_fork,
            };
        }
    };
}

fn blobGasForCount(comptime Protocol: type, revision: Protocol.Revision, blob_count: usize) ?u256 {
    if (blob_count == 0) return 0;
    const schedule = Protocol.Transaction.blobSchedule(revision) orelse return null;
    return blob.blobGasForSchedule(schedule, blob_count);
}

fn ethereumDefinition() type {
    return @import("../eth.zig");
}

test "transaction prepayment includes blob gas" {
    try std.testing.expectEqual(@as(u256, 4_286_432), For(ethereumDefinition()).prepaymentCost(.cancun, 500_000, 7, 1, 6));
}

test "transaction prepayment uses comptime blob gas" {
    const DoubleBlobGasProtocol = struct {
        pub const Revision = EthRevision;

        pub const Transaction = struct {
            pub fn blobSchedule(revision: Revision) ?blob.BlobSchedule {
                _ = revision;
                return .{
                    .target = 3,
                    .max = 6,
                    .max_per_transaction = 6,
                    .gas_per_blob = eth_transaction.blob_gas_per_blob * 2,
                    .min_base_fee = eth_transaction.min_blob_base_fee,
                    .execution_base_cost = eth_transaction.blob_base_cost,
                    .base_fee_update_fraction = eth_transaction.cancun_blob_base_fee_update_fraction,
                    .reserve_price_active = false,
                };
            }
        };
    };
    const hashes = [_]u256{@as(u256, 0x01) << 248} ** 2;
    const input = For(ethereumDefinition()).Input{
        .revision = .cancun,
        .kind = .blob,
        .gas_limit = 500_000,
        .max_fee_per_gas = 7,
        .max_fee_per_blob_gas = 5,
        .blob_hashes = &hashes,
    };

    const default = For(ethereumDefinition()).maxPrepaymentCost(input).?;
    const custom = For(DoubleBlobGasProtocol).maxPrepaymentCost(.{
        .revision = input.revision,
        .kind = input.kind,
        .gas_limit = input.gas_limit,
        .max_fee_per_gas = input.max_fee_per_gas,
        .max_fee_per_blob_gas = input.max_fee_per_blob_gas,
        .blob_hashes = input.blob_hashes,
    }).?;
    try std.testing.expectEqual(default + @as(u256, eth_transaction.blob_gas_per_blob * hashes.len * 5), custom);
}

test "transaction validation rejects intrinsic gas below limit" {
    try std.testing.expectEqual(ValidationError.intrinsic_gas_too_low, For(ethereumDefinition()).validate(.{
        .revision = .cancun,
        .gas_limit = 21_000,
        .input = &.{0xff},
        .sender_balance = 1_000_000,
    }).?);
}

test "transaction validation rejects Prague floor gas" {
    try std.testing.expectEqual(ValidationError.intrinsic_gas_below_floor_gas_cost, For(ethereumDefinition()).validate(.{
        .revision = .prague,
        .gas_limit = 21_100,
        .input = &.{ 1, 1, 1, 1 },
        .sender_balance = 1_000_000,
    }).?);
}

test "transaction validation applies Amsterdam calldata floor" {
    const amsterdam_floor_input = [_]u8{1} ** 63;
    try std.testing.expectEqual(@as(?ValidationError, null), For(ethereumDefinition()).validate(.{
        .revision = .prague,
        .gas_limit = 21_200,
        .input = &.{ 1, 1, 1, 1 },
        .sender_balance = 1_000_000,
    }));
    try std.testing.expectEqual(ValidationError.intrinsic_gas_below_floor_gas_cost, For(ethereumDefinition()).validate(.{
        .revision = .amsterdam,
        .gas_limit = 16_031,
        .input = &amsterdam_floor_input,
        .sender_balance = 1_000_000,
    }).?);
    try std.testing.expectEqual(@as(?ValidationError, null), For(ethereumDefinition()).validate(.{
        .revision = .amsterdam,
        .gas_limit = 16_032,
        .input = &amsterdam_floor_input,
        .sender_balance = 1_000_000,
    }));
}

test "transaction validation includes Amsterdam access-list data surcharge" {
    const access_counts = AccessListCounts{ .addresses = 1, .storage_keys = 1 };
    try std.testing.expectEqual(@as(?ValidationError, null), For(ethereumDefinition()).validate(.{
        .revision = .osaka,
        .gas_limit = 25_300,
        .access_list_counts = access_counts,
        .sender_balance = 100_000,
    }));
    try std.testing.expectEqual(ValidationError.intrinsic_gas_too_low, For(ethereumDefinition()).validate(.{
        .revision = .amsterdam,
        .gas_limit = 24_327,
        .access_list_counts = access_counts,
        .sender_balance = 100_000,
    }).?);
    try std.testing.expectEqual(@as(?ValidationError, null), For(ethereumDefinition()).validate(.{
        .revision = .amsterdam,
        .gas_limit = 24_328,
        .access_list_counts = access_counts,
        .sender_balance = 100_000,
    }));
}

test "transaction validation checks max fee balance" {
    try std.testing.expectEqual(ValidationError.insufficient_account_funds, For(ethereumDefinition()).validate(.{
        .revision = .cancun,
        .kind = .blob,
        .gas_limit = 21_000,
        .max_fee_per_gas = 10,
        .max_priority_fee_per_gas = 0,
        .max_fee_per_blob_gas = 2,
        .base_fee = 7,
        .blob_base_fee = 1,
        .blob_hashes = &.{@as(u256, 0x01) << 248},
        .sender_balance = 21_000 * 10 + eth_transaction.blob_gas_per_blob * 2 - 1,
    }).?);
}

test "transaction validation rejects typed transaction before fork" {
    try std.testing.expectEqual(ValidationError.type_2_tx_pre_fork, For(ethereumDefinition()).validate(.{
        .revision = .berlin,
        .kind = .dynamic_fee,
        .gas_limit = 21_000,
        .max_fee_per_gas = 1,
        .sender_balance = 21_000,
    }).?);
}

test "transaction validation rejects non-EOA sender after London" {
    try std.testing.expectEqual(ValidationError.sender_not_eoa, For(ethereumDefinition()).validate(.{
        .revision = .cancun,
        .gas_limit = 21_000,
        .sender_code_kind = .non_delegating,
        .sender_balance = 21_000,
    }).?);
    try std.testing.expectEqual(@as(?ValidationError, null), For(ethereumDefinition()).validate(.{
        .revision = .berlin,
        .gas_limit = 21_000,
        .sender_code_kind = .non_delegating,
        .sender_balance = 21_000,
    }));
}

test "transaction validation rejects nonce overflow" {
    try std.testing.expectEqual(ValidationError.nonce_is_max, For(ethereumDefinition()).validate(.{
        .revision = .cancun,
        .is_create = true,
        .gas_limit = 100_000,
        .gas_price = 1,
        .sender_nonce = std.math.maxInt(u64),
        .sender_balance = 100_000,
    }).?);
}

test "transaction validation rejects nonce mismatch" {
    try std.testing.expectEqual(ValidationError.nonce_mismatch, For(ethereumDefinition()).validate(.{
        .revision = .cancun,
        .gas_limit = 21_000,
        .gas_price = 1,
        .sender_nonce = 7,
        .tx_nonce = 8,
        .sender_balance = 21_000,
    }).?);
}

test "transaction validation rejects blob contract creation" {
    try std.testing.expectEqual(ValidationError.type_3_tx_contract_creation, For(ethereumDefinition()).validate(.{
        .revision = .cancun,
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
    try std.testing.expectEqual(ValidationError.gas_allowance_exceeded, For(ethereumDefinition()).validate(.{
        .revision = .cancun,
        .gas_limit = 90_000,
        .block_gas_limit = 80_000,
        .gas_price = 1,
        .sender_balance = 90_000,
    }).?);
}

test "transaction validation applies Osaka transaction gas cap" {
    try std.testing.expectEqual(@as(?ValidationError, null), For(ethereumDefinition()).validate(.{
        .revision = .osaka,
        .gas_limit = eth_transaction.max_transaction_gas_limit,
        .gas_price = 1,
        .sender_balance = eth_transaction.max_transaction_gas_limit,
    }));
    try std.testing.expectEqual(ValidationError.gas_allowance_exceeded, For(ethereumDefinition()).validate(.{
        .revision = .osaka,
        .gas_limit = eth_transaction.max_transaction_gas_limit + 1,
        .gas_price = 1,
        .sender_balance = eth_transaction.max_transaction_gas_limit + 1,
    }).?);
    try std.testing.expectEqual(@as(?ValidationError, null), For(ethereumDefinition()).validate(.{
        .revision = .prague,
        .gas_limit = eth_transaction.max_transaction_gas_limit + 1,
        .gas_price = 1,
        .sender_balance = eth_transaction.max_transaction_gas_limit + 1,
    }));
}

test "transaction validation uses comptime policy" {
    const CustomRevision = enum(u8) { custom };
    const CustomPolicyProtocol = struct {
        pub const Revision = CustomRevision;

        pub const Transaction = struct {
            pub fn kindActive(revision: Revision, kind: TxKind) bool {
                _ = revision;
                _ = kind;
                return true;
            }

            pub fn allowsContractCreation(revision: Revision, kind: TxKind) bool {
                _ = revision;
                _ = kind;
                return true;
            }

            pub fn requiresAuthorizationList(revision: Revision, kind: TxKind) bool {
                _ = revision;
                _ = kind;
                return false;
            }

            pub fn rejectsNonDelegatingSenderCode(revision: Revision, kind: TxKind) bool {
                _ = revision;
                _ = kind;
                return false;
            }

            pub fn blobSchedule(revision: Revision) ?blob.BlobSchedule {
                _ = revision;
                return .{
                    .target = 1,
                    .max = 1,
                    .max_per_transaction = 1,
                    .gas_per_blob = eth_transaction.blob_gas_per_blob,
                    .min_base_fee = eth_transaction.min_blob_base_fee,
                    .execution_base_cost = eth_transaction.blob_base_cost,
                    .base_fee_update_fraction = eth_transaction.cancun_blob_base_fee_update_fraction,
                    .reserve_price_active = false,
                };
            }

            pub fn blobVersionedHashActive(revision: Revision, version: u8) bool {
                _ = revision;
                _ = version;
                return false;
            }

            pub fn maxInitcodeSize(revision: Revision) usize {
                _ = revision;
                return std.math.maxInt(usize);
            }

            pub fn intrinsicBaseGas(revision: Revision, options: gas.IntrinsicGasOptions) ?u64 {
                _ = revision;
                _ = options;
                return 21_000;
            }

            pub fn createIntrinsicGas(revision: Revision) ?u64 {
                _ = revision;
                return 0;
            }

            pub fn dataByteGas(revision: Revision, byte: u8) u64 {
                _ = revision;
                _ = byte;
                return 0;
            }

            pub fn accessListAddressGas(revision: Revision) u64 {
                _ = revision;
                return 0;
            }

            pub fn storageKeyGas(revision: Revision) u64 {
                _ = revision;
                return 0;
            }

            pub fn accessListDataGas(revision: Revision, counts: AccessListCounts) ?u64 {
                _ = revision;
                _ = counts;
                return 0;
            }

            pub fn initCodeWordGas(revision: Revision) u64 {
                _ = revision;
                return 0;
            }

            pub fn authorizationIntrinsicGas(revision: Revision) u64 {
                _ = revision;
                return 0;
            }

            pub fn intrinsicStateGas(revision: Revision, options: gas.IntrinsicGasOptions) ?u64 {
                _ = revision;
                _ = options;
                return 0;
            }

            pub fn floorGas(revision: Revision, input: []const u8, options: gas.IntrinsicGasOptions) ?u64 {
                _ = revision;
                _ = input;
                _ = options;
                return null;
            }

            pub fn intrinsicRegularGasLimit(revision: Revision) ?u64 {
                _ = revision;
                return null;
            }

            pub fn totalGasLimit(revision: Revision) ?u64 {
                _ = revision;
                return 25_000;
            }

            pub fn regularGasLimit(revision: Revision, gas_limit: u64) u64 {
                _ = revision;
                return gas_limit;
            }
        };

        pub const Settlement = struct {
            pub fn baseFeeActive(revision: Revision) bool {
                _ = revision;
                return false;
            }
        };
    };

    try std.testing.expectEqual(ValidationError.type_1_tx_pre_fork, For(ethereumDefinition()).validate(.{
        .revision = .frontier,
        .kind = .access_list,
        .gas_limit = 21_000,
    }).?);
    try std.testing.expectEqual(@as(?ValidationError, null), For(CustomPolicyProtocol).validate(.{
        .revision = .custom,
        .kind = .access_list,
        .gas_limit = 21_000,
    }));
    try std.testing.expectEqual(ValidationError.gas_allowance_exceeded, For(CustomPolicyProtocol).validate(.{
        .revision = .custom,
        .kind = .access_list,
        .gas_limit = 25_001,
    }).?);
}

test "transaction validation does not apply Osaka total gas cap after Amsterdam" {
    const fixture_gas: u64 = 120_000_000;
    try std.testing.expectEqual(@as(?ValidationError, null), For(ethereumDefinition()).validate(.{
        .revision = .amsterdam,
        .gas_limit = fixture_gas,
        .gas_price = 1,
        .block_gas_limit = fixture_gas,
        .sender_balance = fixture_gas,
    }));
}

test "transaction validation caps Amsterdam intrinsic regular gas" {
    const too_many_addresses = (eth_transaction.max_transaction_gas_limit - 15_000) / (eth_transaction.amsterdam_access_list_address_gas + eth_transaction.access_list_address_data_gas) + 1;
    try std.testing.expectEqual(ValidationError.intrinsic_gas_too_low, For(ethereumDefinition()).validate(.{
        .revision = .amsterdam,
        .gas_limit = 30_000_000,
        .access_list_counts = .{ .addresses = too_many_addresses },
    }).?);
}

test "transaction validation caps Amsterdam calldata floor gas" {
    const floor_exceeding_len = (eth_transaction.max_transaction_gas_limit - eth_transaction.amsterdam_tx_base_cost) / 64 + 1;
    const input = try std.testing.allocator.alloc(u8, floor_exceeding_len);
    defer std.testing.allocator.free(input);
    @memset(input, 1);

    try std.testing.expectEqual(ValidationError.intrinsic_gas_too_low, For(ethereumDefinition()).validate(.{
        .revision = .amsterdam,
        .gas_limit = 30_000_000,
        .input = input,
    }).?);
}

test "transaction validation rejects old type gas price below base fee" {
    try std.testing.expectEqual(ValidationError.insufficient_max_fee_per_gas, For(ethereumDefinition()).validate(.{
        .revision = .cancun,
        .gas_limit = 21_000,
        .gas_price = 999,
        .base_fee = 1_000,
        .sender_balance = 21_000_000,
    }).?);
}

test "transaction validation rejects blob shape errors" {
    const seven_blob_hashes = [_]u256{@as(u256, 0x01) << 248} ** 7;
    const ten_blob_hashes = [_]u256{@as(u256, 0x01) << 248} ** 10;

    try std.testing.expectEqual(ValidationError.type_3_tx_zero_blobs, For(ethereumDefinition()).validate(.{
        .revision = .cancun,
        .kind = .blob,
        .gas_limit = 21_000,
        .max_fee_per_gas = 1,
        .max_fee_per_blob_gas = 1,
        .sender_balance = 1_000_000,
    }).?);
    try std.testing.expectEqual(ValidationError.type_3_tx_invalid_blob_versioned_hash, For(ethereumDefinition()).validate(.{
        .revision = .cancun,
        .kind = .blob,
        .gas_limit = 21_000,
        .max_fee_per_gas = 1,
        .max_fee_per_blob_gas = 1,
        .blob_hashes = &.{@as(u256, 0x02) << 248},
        .sender_balance = 1_000_000,
    }).?);
    try std.testing.expectEqual(ValidationError.type_3_tx_blob_count_exceeded, For(ethereumDefinition()).validate(.{
        .revision = .osaka,
        .kind = .blob,
        .gas_limit = 21_000,
        .max_fee_per_gas = 1,
        .max_fee_per_blob_gas = 1,
        .blob_hashes = &seven_blob_hashes,
        .sender_balance = 10_000_000,
    }).?);
    try std.testing.expectEqual(ValidationError.type_3_tx_max_blob_gas_allowance_exceeded, For(ethereumDefinition()).validate(.{
        .revision = .osaka,
        .kind = .blob,
        .gas_limit = 21_000,
        .max_fee_per_gas = 1,
        .max_fee_per_blob_gas = 1,
        .blob_hashes = &ten_blob_hashes,
        .sender_balance = 10_000_000,
    }).?);
}

test "transaction validation rejects set-code shape errors" {
    try std.testing.expectEqual(ValidationError.type_4_empty_authorization_list, For(ethereumDefinition()).validate(.{
        .revision = .prague,
        .kind = .set_code,
        .gas_limit = 21_000,
        .max_fee_per_gas = 1,
        .sender_balance = 1_000_000,
    }).?);
    try std.testing.expectEqual(ValidationError.type_4_tx_contract_creation, For(ethereumDefinition()).validate(.{
        .revision = .prague,
        .kind = .set_code,
        .is_create = true,
        .gas_limit = 100_000,
        .max_fee_per_gas = 1,
        .authorization_count = 1,
        .sender_balance = 1_000_000,
    }).?);
    try std.testing.expectEqual(ValidationError.sender_not_eoa, For(ethereumDefinition()).validate(.{
        .revision = .prague,
        .kind = .set_code,
        .gas_limit = 100_000,
        .max_fee_per_gas = 1,
        .authorization_count = 1,
        .sender_code_kind = .non_delegating,
        .sender_balance = 1_000_000,
    }).?);
}

test "transaction validation rejects oversized initcode" {
    var initcode = [_]u8{0} ** (eth_transaction.max_initcode_size + 1);
    try std.testing.expectEqual(ValidationError.initcode_size_exceeded, For(ethereumDefinition()).validate(.{
        .revision = .shanghai,
        .is_create = true,
        .gas_limit = 1_000_000,
        .input = &initcode,
        .sender_balance = 1_000_000,
    }).?);

    try std.testing.expectEqual(ValidationError.initcode_size_exceeded, For(ethereumDefinition()).validate(.{
        .revision = .osaka,
        .is_create = true,
        .gas_limit = 1_000_000,
        .input = &initcode,
        .sender_balance = 1_000_000,
    }).?);

    try std.testing.expectEqual(@as(?ValidationError, null), For(ethereumDefinition()).validate(.{
        .revision = .amsterdam,
        .is_create = true,
        .gas_limit = 4_000_000,
        .input = &initcode,
        .sender_balance = 4_000_000,
    }));

    const oversized_amsterdam = try std.testing.allocator.alloc(u8, eth_transaction.amsterdam_max_initcode_size + 1);
    defer std.testing.allocator.free(oversized_amsterdam);
    @memset(oversized_amsterdam, 0);
    try std.testing.expectEqual(ValidationError.initcode_size_exceeded, For(ethereumDefinition()).validate(.{
        .revision = .amsterdam,
        .is_create = true,
        .gas_limit = 1_000_000,
        .input = oversized_amsterdam,
        .sender_balance = 1_000_000,
    }).?);
}
