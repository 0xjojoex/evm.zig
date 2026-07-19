const std = @import("std");

const blob = @import("../transaction/blob.zig");
const definition = @import("../definition.zig");
const definition_support = @import("../protocol/support.zig");
const gas = @import("../transaction/gas.zig");
const Transaction = @import("../transaction/types.zig");
const EthRevision = @import("revision.zig").Revision;
const eth_transaction = @import("transaction.zig");
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

/// Ethereum transaction facts consumed by the ordered preparation program.
fn ValidationInput(comptime Protocol: type) type {
    return struct {
        revision: Protocol.Revision,
        kind: TxKind = .legacy,
        is_create: bool = false,
        is_self_transfer: bool = false,
        gas_limit: u64,
        input: []const u8 = &.{},
        value: u256 = 0,
        gas_price: u256 = 0,
        base_fee: u256 = 0,
        block_gas_limit: u64 = 0,
        block_progress: Transaction.PreparationBlockProgress = .{},
        blob_base_fee: u256 = 0,
        blob_schedule: ?blob.BlobSchedule = null,
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

/// Validation program borrowing one immutable transaction-policy snapshot.
pub fn Runtime(
    comptime ProtocolType: type,
    comptime TransactionPolicy: type,
) type {
    return struct {
        const Self = @This();
        const Gas = gas.Runtime(
            ProtocolType,
            @FieldType(TransactionPolicy, "transaction"),
        );

        pub const Protocol = ProtocolType;
        pub const Input = ValidationInput(Protocol);

        policy: *const TransactionPolicy,

        fn gasPlanner(self: Self) Gas {
            return .{ .transaction = &self.policy.transaction };
        }

        pub fn validate(self: Self, input: Input) ?ValidationError {
            const gas_plan = self.gasPlan(input);
            if (self.validateBeforeAccount(input, gas_plan)) |err| return err;
            if (self.validateAfterAccount(input)) |err| return err;
            return self.validateSenderCode(
                input,
                self.policy.transaction.rejectsNonDelegatingSenderCode(input.revision, input.kind),
            );
        }

        pub fn validateBeforeAccount(self: Self, input: Input, gas_plan: gas.GasPlan) ?ValidationError {
            definition_support.assertRevisionSupported(Protocol, input.revision);
            const transaction = &self.policy.transaction;
            if (self.inactiveTransactionKindError(input.revision, input.kind)) |err| return err;

            if (gas_plan.intrinsic_regular_gas == std.math.maxInt(u64) or
                gas_plan.intrinsic_state_gas == std.math.maxInt(u64) or
                gas_plan.intrinsic_gas == std.math.maxInt(u64))
            {
                return .intrinsic_gas_too_low;
            }

            if (transaction.intrinsicRegularGasLimit(input.revision)) |regular_intrinsic_limit| {
                const capped_intrinsic = @max(gas_plan.intrinsic_regular_gas, gas_plan.floor_gas);
                if (capped_intrinsic > regular_intrinsic_limit) return .intrinsic_gas_too_low;
            }
            if (input.gas_limit < gas_plan.intrinsic_gas) return .intrinsic_gas_too_low;
            if (input.gas_limit < gas_plan.floor_gas) return .intrinsic_gas_below_floor_gas_cost;
            if (input.tx_nonce) |tx_nonce| {
                if (tx_nonce == std.math.maxInt(u64)) return .nonce_is_max;
            }
            if (input.is_create and input.input.len > self.gasPlanner().maxInitcodeSize(input.revision))
                return .initcode_size_exceeded;
            if (transaction.totalGasLimit(input.revision)) |limit| {
                if (input.gas_limit > limit) return .gas_allowance_exceeded;
            }
            if (self.exceedsBlockGasAllowance(input)) return .gas_allowance_exceeded;
            if (input.kind == .blob) {
                const schedule = effectiveBlobScheduleWith(
                    transaction.blobSchedule,
                    input.revision,
                    input.blob_schedule,
                ) orelse return .type_3_tx_max_blob_gas_allowance_exceeded;
                if (input.blob_hashes.len > maxBlobCount(schedule)) return .type_3_tx_max_blob_gas_allowance_exceeded;
                if (input.blob_hashes.len > maxBlobCountPerTransaction(schedule)) return .type_3_tx_blob_count_exceeded;
            }
            return null;
        }

        pub fn gasPlan(self: Self, input: Input) gas.GasPlan {
            return self.gasPlanner().gasPlan(input.revision, input.input, input.gas_limit, .{
                .authorization_count = input.authorization_count,
                .access_list_counts = input.access_list_counts,
                .is_create = input.is_create,
                .value = input.value,
                .is_self_transfer = input.is_self_transfer,
            });
        }

        pub fn validateAfterAccount(self: Self, input: Input) ?ValidationError {
            definition_support.assertRevisionSupported(Protocol, input.revision);
            const transaction = &self.policy.transaction;
            if (input.kind == .dynamic_fee or input.kind == .blob or input.kind == .set_code) {
                const max_fee = input.max_fee_per_gas orelse 0;
                const priority_fee = input.max_priority_fee_per_gas orelse 0;
                if (priority_fee > max_fee) return .priority_greater_than_max_fee_per_gas;
                if (max_fee < input.base_fee) return .insufficient_max_fee_per_gas;
            }
            if ((input.kind == .legacy or input.kind == .access_list) and self.policy.settlement.baseFeeActive(input.revision) and input.gas_price < input.base_fee)
                return .insufficient_max_fee_per_gas;
            if (input.kind == .blob) {
                const max_blob_fee = input.max_fee_per_blob_gas orelse 0;
                if (max_blob_fee < input.blob_base_fee) return .insufficient_max_fee_per_blob_gas;
                if (!transaction.allowsContractCreation(input.revision, input.kind) and input.is_create) return .type_3_tx_contract_creation;
                if (input.blob_hashes.len == 0) return .type_3_tx_zero_blobs;
                for (input.blob_hashes) |hash| {
                    if (!transaction.blobVersionedHashActive(input.revision, blob.blobVersion(hash))) return .type_3_tx_invalid_blob_versioned_hash;
                }
            }
            if (input.kind == .set_code) {
                if (!transaction.allowsContractCreation(input.revision, input.kind) and input.is_create) return .type_4_tx_contract_creation;
                if (transaction.requiresAuthorizationList(input.revision, input.kind) and input.authorization_count == 0) return .type_4_empty_authorization_list;
            }
            if (input.tx_nonce) |tx_nonce| {
                if (tx_nonce != input.sender_nonce) return .nonce_mismatch;
            }
            const required_balance = self.maxPrepaymentCost(input) orelse return .insufficient_account_funds;
            if (input.sender_balance < required_balance) return .insufficient_account_funds;
            return null;
        }

        pub fn validateSenderCode(_: Self, input: Input, rejects_non_delegating: bool) ?ValidationError {
            definition_support.assertRevisionSupported(Protocol, input.revision);
            if (rejects_non_delegating and input.sender_code_kind == .non_delegating)
                return .sender_not_eoa;
            return null;
        }

        pub fn maxPrepaymentCost(self: Self, input: Input) ?u256 {
            definition_support.assertRevisionSupported(Protocol, input.revision);
            const gas_price = switch (input.kind) {
                .legacy, .access_list => input.gas_price,
                .dynamic_fee, .blob, .set_code => input.max_fee_per_gas orelse return null,
            };
            const blob_fee = if (input.kind == .blob) input.max_fee_per_blob_gas orelse return null else 0;
            const gas_cost = uint256.checkedMul(@as(u256, input.gas_limit), gas_price) orelse return null;
            const blob_gas = blobGasForCountWith(
                self.policy.transaction.blobSchedule,
                input.revision,
                input.blob_schedule,
                if (input.kind == .blob) input.blob_hashes.len else 0,
            ) orelse return null;
            const blob_cost = uint256.checkedMul(blob_gas, blob_fee) orelse return null;
            const transaction_cost = uint256.checkedAdd(gas_cost, blob_cost) orelse return null;
            return uint256.checkedAdd(transaction_cost, input.value);
        }

        pub fn prepaymentCost(self: Self, revision: Protocol.Revision, gas_limit: u64, gas_price: u256, blob_base_fee: u256, blob_count: usize) ?u256 {
            definition_support.assertRevisionSupported(Protocol, revision);
            const gas_cost = uint256.checkedMul(@as(u256, gas_limit), gas_price) orelse return null;
            const blob_gas = blobGasForCountWith(self.policy.transaction.blobSchedule, revision, null, blob_count) orelse return null;
            const blob_cost = uint256.checkedMul(blob_gas, blob_base_fee) orelse return null;
            return uint256.checkedAdd(gas_cost, blob_cost);
        }

        fn inactiveTransactionKindError(self: Self, revision: Protocol.Revision, kind: TxKind) ?ValidationError {
            if (self.policy.transaction.kindActive(revision, kind)) return null;
            return switch (kind) {
                .legacy => null,
                .access_list => .type_1_tx_pre_fork,
                .dynamic_fee => .type_2_tx_pre_fork,
                .blob => .type_3_tx_pre_fork,
                .set_code => .type_4_tx_pre_fork,
            };
        }

        fn exceedsBlockGasAllowance(self: Self, input: Input) bool {
            if (input.block_gas_limit == 0) return false;
            if (self.policy.settlement.usesStateGasAccounting(input.revision)) {
                const regular_available = input.block_gas_limit -| input.block_progress.block_gas.regular;
                const state_available = input.block_gas_limit -| input.block_progress.block_gas.state;
                return self.gasPlanner().regularGasLimit(input.revision, input.gas_limit) > regular_available or
                    input.gas_limit > state_available;
            }
            const available = input.block_gas_limit -| input.block_progress.receipt_gas_used;
            return input.gas_limit > available;
        }
    };
}

fn StaticPolicy(comptime Protocol: type) type {
    return struct {
        transaction: definition.TransactionPolicyConfig(Protocol.Revision),
        settlement: definition.SettlementConfig(Protocol.Revision),
    };
}

/// Static-policy adapter for protocol-level helpers and tests. Validation
/// behavior remains implemented only by `Runtime`.
pub fn For(comptime ProtocolType: type) Runtime(ProtocolType, StaticPolicy(ProtocolType)) {
    const Policy = StaticPolicy(ProtocolType);
    const Values = struct {
        const policy: Policy = .{
            .transaction = definition.projectTransactionConfig(
                ProtocolType.Revision,
                ProtocolType.transaction,
            ),
            .settlement = definition.projectSettlementConfig(
                ProtocolType.Revision,
                if (@hasDecl(ProtocolType, "settlement"))
                    ProtocolType.settlement
                else
                    definition.SettlementConfig(ProtocolType.Revision).default,
            ),
        };
    };
    return .{ .policy = &Values.policy };
}

fn effectiveBlobScheduleWith(blob_schedule_for_revision: anytype, revision: anytype, blob_schedule: ?blob.BlobSchedule) ?blob.BlobSchedule {
    return blob_schedule orelse blob_schedule_for_revision(revision);
}

fn maxBlobCount(schedule: blob.BlobSchedule) usize {
    return std.math.cast(usize, schedule.max) orelse std.math.maxInt(usize);
}

fn maxBlobCountPerTransaction(schedule: blob.BlobSchedule) usize {
    return std.math.cast(usize, schedule.max_per_transaction) orelse std.math.maxInt(usize);
}

fn blobGasForCountWith(blob_schedule_for_revision: anytype, revision: anytype, blob_schedule: ?blob.BlobSchedule, blob_count: usize) ?u256 {
    if (blob_count == 0) return 0;
    const schedule = effectiveBlobScheduleWith(blob_schedule_for_revision, revision, blob_schedule) orelse return null;
    return blob.blobGasForSchedule(schedule, blob_count);
}

fn ethereumProtocol() type {
    return @import("../eth.zig").Protocol.TransactionProtocol;
}

test "transaction prepayment includes blob gas" {
    try std.testing.expectEqual(@as(u256, 4_286_432), For(ethereumProtocol()).prepaymentCost(.cancun, 500_000, 7, 1, 6));
}

test "transaction prepayment uses comptime blob gas" {
    const DoubleBlobGasProtocol = struct {
        pub const Revision = EthRevision;

        pub const transaction = struct {
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
    const Validation = @TypeOf(For(ethereumProtocol()));
    const input = Validation.Input{
        .revision = .cancun,
        .kind = .blob,
        .gas_limit = 500_000,
        .max_fee_per_gas = 7,
        .max_fee_per_blob_gas = 5,
        .blob_hashes = &hashes,
    };

    const default = For(ethereumProtocol()).maxPrepaymentCost(input).?;
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

test "transaction validation uses runtime blob schedule" {
    var schedule = eth_transaction.Transaction.blobSchedule(.cancun).?;
    const hashes = [_]u256{
        @as(u256, 0x01) << 248,
        (@as(u256, 0x01) << 248) | 1,
    };

    schedule.max = 1;
    try std.testing.expectEqual(ValidationError.type_3_tx_max_blob_gas_allowance_exceeded, For(ethereumProtocol()).validate(.{
        .revision = .cancun,
        .kind = .blob,
        .gas_limit = 21_000,
        .max_fee_per_gas = 1,
        .max_fee_per_blob_gas = 1,
        .blob_schedule = schedule,
        .blob_hashes = &hashes,
        .sender_balance = 1_000_000,
    }).?);

    schedule.max = 6;
    schedule.gas_per_blob = eth_transaction.blob_gas_per_blob * 2;
    const cost = For(ethereumProtocol()).maxPrepaymentCost(.{
        .revision = .cancun,
        .kind = .blob,
        .gas_limit = 500_000,
        .max_fee_per_gas = 7,
        .max_fee_per_blob_gas = 5,
        .blob_schedule = schedule,
        .blob_hashes = &hashes,
    }).?;
    try std.testing.expectEqual(@as(u256, 500_000 * 7 + eth_transaction.blob_gas_per_blob * 2 * hashes.len * 5), cost);
}

test "transaction validation rejects intrinsic gas below limit" {
    try std.testing.expectEqual(ValidationError.intrinsic_gas_too_low, For(ethereumProtocol()).validate(.{
        .revision = .cancun,
        .gas_limit = 21_000,
        .input = &.{0xff},
        .sender_balance = 1_000_000,
    }).?);
}

test "transaction validation rejects Prague floor gas" {
    try std.testing.expectEqual(ValidationError.intrinsic_gas_below_floor_gas_cost, For(ethereumProtocol()).validate(.{
        .revision = .prague,
        .gas_limit = 21_100,
        .input = &.{ 1, 1, 1, 1 },
        .sender_balance = 1_000_000,
    }).?);
}

test "transaction validation applies Amsterdam calldata floor" {
    const amsterdam_floor_input = [_]u8{1} ** 63;
    try std.testing.expectEqual(@as(?ValidationError, null), For(ethereumProtocol()).validate(.{
        .revision = .prague,
        .gas_limit = 21_200,
        .input = &.{ 1, 1, 1, 1 },
        .sender_balance = 1_000_000,
    }));
    try std.testing.expectEqual(ValidationError.intrinsic_gas_below_floor_gas_cost, For(ethereumProtocol()).validate(.{
        .revision = .amsterdam,
        .gas_limit = 16_031,
        .input = &amsterdam_floor_input,
        .sender_balance = 1_000_000,
    }).?);
    try std.testing.expectEqual(@as(?ValidationError, null), For(ethereumProtocol()).validate(.{
        .revision = .amsterdam,
        .gas_limit = 16_032,
        .input = &amsterdam_floor_input,
        .sender_balance = 1_000_000,
    }));
}

test "transaction validation includes Amsterdam access-list data surcharge" {
    const access_counts = AccessListCounts{ .addresses = 1, .storage_keys = 1 };
    try std.testing.expectEqual(@as(?ValidationError, null), For(ethereumProtocol()).validate(.{
        .revision = .osaka,
        .gas_limit = 25_300,
        .access_list_counts = access_counts,
        .sender_balance = 100_000,
    }));
    try std.testing.expectEqual(ValidationError.intrinsic_gas_too_low, For(ethereumProtocol()).validate(.{
        .revision = .amsterdam,
        .gas_limit = 24_327,
        .access_list_counts = access_counts,
        .sender_balance = 100_000,
    }).?);
    try std.testing.expectEqual(@as(?ValidationError, null), For(ethereumProtocol()).validate(.{
        .revision = .amsterdam,
        .gas_limit = 24_328,
        .access_list_counts = access_counts,
        .sender_balance = 100_000,
    }));
}

test "transaction validation checks max fee balance" {
    try std.testing.expectEqual(ValidationError.insufficient_account_funds, For(ethereumProtocol()).validate(.{
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
    try std.testing.expectEqual(ValidationError.type_2_tx_pre_fork, For(ethereumProtocol()).validate(.{
        .revision = .berlin,
        .kind = .dynamic_fee,
        .gas_limit = 21_000,
        .max_fee_per_gas = 1,
        .sender_balance = 21_000,
    }).?);
}

test "transaction validation rejects non-EOA sender after London" {
    try std.testing.expectEqual(ValidationError.sender_not_eoa, For(ethereumProtocol()).validate(.{
        .revision = .cancun,
        .gas_limit = 21_000,
        .sender_code_kind = .non_delegating,
        .sender_balance = 21_000,
    }).?);
    try std.testing.expectEqual(@as(?ValidationError, null), For(ethereumProtocol()).validate(.{
        .revision = .berlin,
        .gas_limit = 21_000,
        .sender_code_kind = .non_delegating,
        .sender_balance = 21_000,
    }));
}

test "transaction validation rejects nonce overflow" {
    try std.testing.expectEqual(ValidationError.nonce_is_max, For(ethereumProtocol()).validate(.{
        .revision = .cancun,
        .is_create = true,
        .gas_limit = 100_000,
        .gas_price = 1,
        .tx_nonce = std.math.maxInt(u64),
        .sender_balance = 100_000,
    }).?);
}

test "transaction validation rejects nonce mismatch" {
    try std.testing.expectEqual(ValidationError.nonce_mismatch, For(ethereumProtocol()).validate(.{
        .revision = .cancun,
        .gas_limit = 21_000,
        .gas_price = 1,
        .sender_nonce = 7,
        .tx_nonce = 8,
        .sender_balance = 21_000,
    }).?);
}

test "transaction validation rejects blob contract creation" {
    try std.testing.expectEqual(ValidationError.type_3_tx_contract_creation, For(ethereumProtocol()).validate(.{
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
    try std.testing.expectEqual(ValidationError.gas_allowance_exceeded, For(ethereumProtocol()).validate(.{
        .revision = .cancun,
        .gas_limit = 90_000,
        .block_gas_limit = 80_000,
        .gas_price = 1,
        .sender_balance = 90_000,
    }).?);
}

test "transaction validation interprets revision-specific block progress" {
    const Validation = For(ethereumProtocol());

    try std.testing.expectEqual(ValidationError.gas_allowance_exceeded, Validation.validate(.{
        .revision = .cancun,
        .gas_limit = 50_000,
        .block_gas_limit = 100_000,
        .block_progress = .{ .receipt_gas_used = 60_000 },
    }).?);

    try std.testing.expectEqual(ValidationError.gas_allowance_exceeded, Validation.validate(.{
        .revision = .amsterdam,
        .gas_limit = 50_000,
        .block_gas_limit = 100_000,
        .block_progress = .{ .block_gas = .{
            .total = 60_000,
            .regular = 60_000,
        } },
    }).?);

    try std.testing.expectEqual(ValidationError.gas_allowance_exceeded, Validation.validate(.{
        .revision = .amsterdam,
        .gas_limit = 50_000,
        .block_gas_limit = 100_000,
        .block_progress = .{ .block_gas = .{
            .total = 60_000,
            .state = 60_000,
        } },
    }).?);

    try std.testing.expectEqual(@as(?ValidationError, null), Validation.validate(.{
        .revision = .amsterdam,
        .gas_limit = 50_000,
        .block_gas_limit = 100_000,
        .block_progress = .{ .receipt_gas_used = 99_999 },
    }));
}

test "transaction validation applies Osaka transaction gas cap" {
    try std.testing.expectEqual(@as(?ValidationError, null), For(ethereumProtocol()).validate(.{
        .revision = .osaka,
        .gas_limit = eth_transaction.max_transaction_gas_limit,
        .gas_price = 1,
        .sender_balance = eth_transaction.max_transaction_gas_limit,
    }));
    try std.testing.expectEqual(ValidationError.gas_allowance_exceeded, For(ethereumProtocol()).validate(.{
        .revision = .osaka,
        .gas_limit = eth_transaction.max_transaction_gas_limit + 1,
        .gas_price = 1,
        .sender_balance = eth_transaction.max_transaction_gas_limit + 1,
    }).?);
    try std.testing.expectEqual(@as(?ValidationError, null), For(ethereumProtocol()).validate(.{
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

        pub const transaction = struct {
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

            pub fn calldataGas(revision: Revision, input: []const u8) ?u64 {
                _ = revision;
                _ = input;
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

            pub fn floorGas(revision: Revision, input: gas.FloorGasInput) ?u64 {
                _ = revision;
                _ = input;
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

        pub const settlement = struct {
            pub fn baseFeeActive(revision: Revision) bool {
                _ = revision;
                return false;
            }

            pub fn usesStateGasAccounting(revision: Revision) bool {
                _ = revision;
                return false;
            }
        };
    };

    try std.testing.expectEqual(ValidationError.type_1_tx_pre_fork, For(ethereumProtocol()).validate(.{
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
    try std.testing.expectEqual(@as(?ValidationError, null), For(ethereumProtocol()).validate(.{
        .revision = .amsterdam,
        .gas_limit = fixture_gas,
        .gas_price = 1,
        .block_gas_limit = fixture_gas,
        .sender_balance = fixture_gas,
    }));
}

test "transaction validation caps Amsterdam intrinsic regular gas" {
    const too_many_addresses = (eth_transaction.max_transaction_gas_limit - 15_000) / (eth_transaction.amsterdam_access_list_address_gas + eth_transaction.access_list_address_data_gas) + 1;
    try std.testing.expectEqual(ValidationError.intrinsic_gas_too_low, For(ethereumProtocol()).validate(.{
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

    try std.testing.expectEqual(ValidationError.intrinsic_gas_too_low, For(ethereumProtocol()).validate(.{
        .revision = .amsterdam,
        .gas_limit = 30_000_000,
        .input = input,
    }).?);
}

test "transaction validation rejects old type gas price below base fee" {
    try std.testing.expectEqual(ValidationError.insufficient_max_fee_per_gas, For(ethereumProtocol()).validate(.{
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

    try std.testing.expectEqual(ValidationError.type_3_tx_zero_blobs, For(ethereumProtocol()).validate(.{
        .revision = .cancun,
        .kind = .blob,
        .gas_limit = 21_000,
        .max_fee_per_gas = 1,
        .max_fee_per_blob_gas = 1,
        .sender_balance = 1_000_000,
    }).?);
    try std.testing.expectEqual(ValidationError.type_3_tx_invalid_blob_versioned_hash, For(ethereumProtocol()).validate(.{
        .revision = .cancun,
        .kind = .blob,
        .gas_limit = 21_000,
        .max_fee_per_gas = 1,
        .max_fee_per_blob_gas = 1,
        .blob_hashes = &.{@as(u256, 0x02) << 248},
        .sender_balance = 1_000_000,
    }).?);
    try std.testing.expectEqual(ValidationError.type_3_tx_blob_count_exceeded, For(ethereumProtocol()).validate(.{
        .revision = .osaka,
        .kind = .blob,
        .gas_limit = 21_000,
        .max_fee_per_gas = 1,
        .max_fee_per_blob_gas = 1,
        .blob_hashes = &seven_blob_hashes,
        .sender_balance = 10_000_000,
    }).?);
    try std.testing.expectEqual(ValidationError.type_3_tx_max_blob_gas_allowance_exceeded, For(ethereumProtocol()).validate(.{
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
    try std.testing.expectEqual(ValidationError.type_4_empty_authorization_list, For(ethereumProtocol()).validate(.{
        .revision = .prague,
        .kind = .set_code,
        .gas_limit = 21_000,
        .max_fee_per_gas = 1,
        .sender_balance = 1_000_000,
    }).?);
    try std.testing.expectEqual(ValidationError.type_4_tx_contract_creation, For(ethereumProtocol()).validate(.{
        .revision = .prague,
        .kind = .set_code,
        .is_create = true,
        .gas_limit = 100_000,
        .max_fee_per_gas = 1,
        .authorization_count = 1,
        .sender_balance = 1_000_000,
    }).?);
    try std.testing.expectEqual(ValidationError.sender_not_eoa, For(ethereumProtocol()).validate(.{
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
    try std.testing.expectEqual(ValidationError.initcode_size_exceeded, For(ethereumProtocol()).validate(.{
        .revision = .shanghai,
        .is_create = true,
        .gas_limit = 1_000_000,
        .input = &initcode,
        .sender_balance = 1_000_000,
    }).?);

    try std.testing.expectEqual(ValidationError.initcode_size_exceeded, For(ethereumProtocol()).validate(.{
        .revision = .osaka,
        .is_create = true,
        .gas_limit = 1_000_000,
        .input = &initcode,
        .sender_balance = 1_000_000,
    }).?);

    try std.testing.expectEqual(@as(?ValidationError, null), For(ethereumProtocol()).validate(.{
        .revision = .amsterdam,
        .is_create = true,
        .gas_limit = 4_000_000,
        .input = &initcode,
        .sender_balance = 4_000_000,
    }));

    const oversized_amsterdam = try std.testing.allocator.alloc(u8, eth_transaction.amsterdam_max_initcode_size + 1);
    defer std.testing.allocator.free(oversized_amsterdam);
    @memset(oversized_amsterdam, 0);
    try std.testing.expectEqual(ValidationError.initcode_size_exceeded, For(ethereumProtocol()).validate(.{
        .revision = .amsterdam,
        .is_create = true,
        .gas_limit = 10_000_000,
        .input = oversized_amsterdam,
        .sender_balance = 10_000_000,
    }).?);
}
