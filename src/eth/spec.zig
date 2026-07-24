//! Complete exact Ethereum specifications.
//!
//! Every fork is a complete comptime value extending its predecessor. Resolved
//! semantic functions consume runtime input only; revision selection stops at
//! `specAt` and never enters an exact VM.

const std = @import("std");

const address = @import("../address.zig");
const delegation_code = @import("../code/eip7702.zig");
const execution = @import("../execution.zig");
const engine_spec = @import("../spec.zig");
const authorization = @import("../transaction/authorization.zig");
const eip7002 = @import("eip/7002.zig");
const eip7251 = @import("eip/7251.zig");
const eip8282 = @import("eip/8282.zig");
const eth_instruction = @import("instruction.zig");
const eth_precompile = @import("precompile.zig");
const eth_system = @import("system.zig");
const eth_tx = @import("transaction.zig");
const tx = @import("../transaction/types.zig");
const tx_blob = @import("../transaction/blob.zig");
const tx_gas = @import("../transaction/gas.zig");

const Address = address.Address;
pub const Revision = @import("revision.zig").Revision;

pub const Spec = engine_spec.Spec;
pub const TransactionSpec = engine_spec.TransactionSpec;
pub const SettlementSpec = engine_spec.SettlementSpec;
pub const AuthorizationSpec = engine_spec.AuthorizationSpec;
pub const BlockSpec = engine_spec.BlockSpec;
pub const CallSpec = engine_spec.CallSpec;
pub const CreateSpec = engine_spec.CreateSpec;
pub const StorageSpec = engine_spec.StorageSpec;
pub const SelfDestructSpec = engine_spec.SelfDestructSpec;
pub const OptionalPatch = engine_spec.OptionalPatch;

const cold_account_access_cost: i64 = 2_600;
const warm_storage_read_cost: i64 = 100;
const cold_sload_cost: i64 = 2_100;
const account_creation_cost: i64 = 25_000;

const semantics = struct {
    fn allowsContractCreation(kind: tx.TxKind) bool {
        return kind == .legacy or kind == .access_list or kind == .dynamic_fee;
    }

    fn requiresAuthorizationList(kind: tx.TxKind) bool {
        return kind == .set_code;
    }

    fn rejectsSenderCodeBeforeLondon(kind: tx.TxKind) bool {
        return kind == .set_code;
    }

    fn rejectsAllSenderCode(_: tx.TxKind) bool {
        return true;
    }

    fn noDelegationCode(_: []const u8) bool {
        return false;
    }

    fn eip7702DelegationCode(code: []const u8) bool {
        return delegation_code.delegationTarget(code) != null;
    }

    fn legacyIntrinsicBase(_: tx_gas.IntrinsicGasOptions) ?u64 {
        return 21_000;
    }

    fn amsterdamIntrinsicBase(options: tx_gas.IntrinsicGasOptions) ?u64 {
        var gas: u64 = eth_tx.amsterdam_tx_base_cost;
        if (options.is_create) {
            gas = std.math.add(u64, gas, eth_tx.amsterdam_create_access_cost) catch return null;
        } else if (!options.is_self_transfer) {
            gas = std.math.add(u64, gas, eth_tx.amsterdam_cold_account_access_cost) catch return null;
        }
        if (options.value != 0 and !options.is_self_transfer) {
            gas = std.math.add(u64, gas, eth_tx.amsterdam_transfer_log_cost) catch return null;
            if (!options.is_create) {
                gas = std.math.add(u64, gas, eth_tx.amsterdam_tx_value_cost) catch return null;
            }
        }
        return gas;
    }

    fn calldataBeforeIstanbul(input: []const u8) ?u64 {
        return calldataCost(input, 68);
    }

    fn calldataSinceIstanbul(input: []const u8) ?u64 {
        return calldataCost(input, 16);
    }

    fn calldataCost(input: []const u8, nonzero_cost: u64) ?u64 {
        var gas: u64 = 0;
        for (input) |byte| {
            gas = std.math.add(u64, gas, if (byte == 0) 4 else nonzero_cost) catch return null;
        }
        return gas;
    }

    fn noAccessListData(_: tx_gas.AccessListCounts) ?u64 {
        return 0;
    }

    fn amsterdamAccessListData(counts: tx_gas.AccessListCounts) ?u64 {
        return eth_tx.accessListDataCost(counts);
    }

    fn noFloor(_: tx_gas.FloorGasInput) ?u64 {
        return null;
    }

    fn pragueFloor(input: tx_gas.FloorGasInput) ?u64 {
        const tokens = eth_tx.calldataTokenCount(input.input) orelse return null;
        const data_cost = std.math.mul(u64, tokens, 10) catch return null;
        return std.math.add(u64, 21_000, data_cost) catch null;
    }

    fn amsterdamFloor(input: tx_gas.FloorGasInput) ?u64 {
        const bytes = std.math.cast(u64, input.input.len) orelse return null;
        const data_cost = std.math.mul(u64, bytes, 64) catch return null;
        var gas = std.math.add(u64, amsterdamIntrinsicBase(input.options) orelse return null, data_cost) catch return null;
        gas = std.math.add(u64, gas, amsterdamAccessListData(input.options.access_list_counts) orelse return null) catch return null;
        return gas;
    }

    fn legacyAuthorizationSuccess(input: authorization.SuccessInput) authorization.GasAdjustment {
        if (!input.account_exists) return .{};
        return .{ .regular_refund = eth_tx.authorization_existing_account_refund_gas };
    }

    fn amsterdamAuthorizationSuccess(input: authorization.SuccessInput) authorization.GasAdjustment {
        return .{
            .account_state_charge = if (input.account_exists) 0 else eth_tx.amsterdam_new_account_state_gas,
            .account_write_charge = if (input.account_already_written) 0 else eth_tx.amsterdam_account_write_cost,
            .delegation_state_charge = if (!input.clears_delegation and
                !input.delegated_before_transaction and
                !input.delegation_set_before)
                eth_tx.amsterdam_auth_base_state_gas
            else
                0,
        };
    }

    fn noMalformedAuthorization(_: usize) authorization.GasAdjustment {
        return .{};
    }

    fn noBeforeBlock(_: eth_system.BeforeBlockContext) eth_system.BlockSystemCalls {
        return .{};
    }

    fn cancunBeforeBlock(context: eth_system.BeforeBlockContext) eth_system.BlockSystemCalls {
        var calls = eth_system.BlockSystemCalls{};
        if (context.number == 0) return calls;
        if (context.parent_beacon_block_root) |root| appendBeaconRoot(&calls, root, 0);
        return calls;
    }

    fn pragueBeforeBlock(context: eth_system.BeforeBlockContext) eth_system.BlockSystemCalls {
        return blockCalls(context, 0);
    }

    fn amsterdamBeforeBlock(context: eth_system.BeforeBlockContext) eth_system.BlockSystemCalls {
        return blockCalls(context, eth_system.system_call_state_gas);
    }

    fn blockCalls(context: eth_system.BeforeBlockContext, state_gas: u64) eth_system.BlockSystemCalls {
        var calls = eth_system.BlockSystemCalls{};
        if (context.number == 0) return calls;
        if (context.parent_beacon_block_root) |root| appendBeaconRoot(&calls, root, state_gas);
        if (context.parent_hash) |hash| {
            calls.append(.{
                .sender = eth_system.system_address,
                .recipient = eth_system.history_storage_address,
                .input = .{ .word = hash },
                .gas = eth_system.system_call_gas,
                .state_gas = state_gas,
            });
        }
        return calls;
    }

    fn appendBeaconRoot(calls: *eth_system.BlockSystemCalls, root: [32]u8, state_gas: u64) void {
        calls.append(.{
            .sender = eth_system.system_address,
            .recipient = eth_system.beacon_roots_address,
            .input = .{ .word = root },
            .gas = eth_system.system_call_gas,
            .state_gas = state_gas,
        });
    }

    fn noBeforeTransaction(_: eth_system.BeforeTransactionContext) eth_system.BlockSystemCalls {
        return .{};
    }

    fn noAfterTransaction(_: eth_system.AfterTransactionContext) eth_system.BlockSystemCalls {
        return .{};
    }

    fn noFinalize(_: eth_system.FinalizeBlockContext) eth_system.FinalizeSystemCalls {
        return .{};
    }

    fn pragueFinalize(context: eth_system.FinalizeBlockContext) eth_system.FinalizeSystemCalls {
        return finalizeCalls(context, 0, false);
    }

    fn amsterdamFinalize(context: eth_system.FinalizeBlockContext) eth_system.FinalizeSystemCalls {
        return finalizeCalls(context, eth_system.system_call_state_gas, true);
    }

    fn finalizeCalls(context: eth_system.FinalizeBlockContext, state_gas: u64, builders: bool) eth_system.FinalizeSystemCalls {
        var calls = eth_system.FinalizeSystemCalls{};
        if (context.number == 0) return calls;
        calls.append(eip7002.finalizeSystemCall(eth_system.system_address, eth_system.system_call_gas, state_gas));
        calls.append(eip7251.finalizeSystemCall(eth_system.system_address, eth_system.system_call_gas, state_gas));
        if (builders) {
            calls.append(eip8282.builderDepositFinalizeSystemCall(eth_system.system_address, eth_system.system_call_gas, state_gas));
            calls.append(eip8282.builderExitFinalizeSystemCall(eth_system.system_address, eth_system.system_call_gas, state_gas));
        }
        return calls;
    }

    fn frontierCallNewAccount(input: execution.CallNewAccountInput) execution.CallNewAccountGas {
        return if (!input.account_exists) .{ .regular = account_creation_cost } else .{};
    }

    fn spuriousCallNewAccount(input: execution.CallNewAccountInput) execution.CallNewAccountGas {
        return if (input.value > 0 and !input.account_exists) .{ .regular = account_creation_cost } else .{};
    }

    fn amsterdamCallNewAccount(input: execution.CallNewAccountInput) execution.CallNewAccountGas {
        return if (input.value > 0 and !input.account_exists)
            .{ .state = @intCast(eth_tx.amsterdam_new_account_state_gas) }
        else
            .{};
    }

    fn noTopFrameStateGas(_: execution.TopFrameValueTransferInput) i64 {
        return 0;
    }

    fn amsterdamTopFrameStateGas(input: execution.TopFrameValueTransferInput) i64 {
        if (input.value == 0 or input.same_address or !input.creates_account) return 0;
        return @intCast(eth_tx.amsterdam_new_account_state_gas);
    }

    fn legacyDelegatedAccountAccess(cold: bool) i64 {
        return if (cold) cold_account_access_cost else warm_storage_read_cost;
    }

    fn amsterdamDelegatedAccountAccess(cold: bool) i64 {
        return if (cold) @intCast(eth_tx.amsterdam_cold_account_access_cost) else warm_storage_read_cost;
    }

    fn noTopLevelDelegatedAccountAccess(_: execution.TopLevelDelegatedAccountAccessInput) ?execution.DelegatedAccountAccess {
        return null;
    }

    fn amsterdamTopLevelDelegatedAccountAccess(input: execution.TopLevelDelegatedAccountAccessInput) ?execution.DelegatedAccountAccess {
        const warm = input.target_is_precompile or input.already_warm;
        return .{
            .status = if (warm) .warm else .cold,
            .gas = amsterdamDelegatedAccountAccess(!warm),
        };
    }

    fn legacyChildGas(input: execution.ChildGasInput) execution.ChildGas {
        if (input.requested > input.available) return .{ .gas = 0, .out_of_gas = true };
        return .{ .gas = input.requested };
    }

    fn eip150ChildGas(input: execution.ChildGasInput) execution.ChildGas {
        return .{ .gas = @min(input.requested, input.available - @divFloor(input.available, 64)) };
    }

    fn acceptsCreateCode(_: []const u8) bool {
        return false;
    }

    fn rejectsEfCreateCode(code: []const u8) bool {
        return code.len > 0 and code[0] == 0xef;
    }

    fn legacyDepositRegularGas(runtime_size: i64) ?i64 {
        return std.math.mul(i64, runtime_size, 200) catch null;
    }

    fn amsterdamDepositRegularGas(runtime_size: i64) ?i64 {
        const words = @divFloor(runtime_size + 31, 32);
        return std.math.mul(i64, words, eth_tx.amsterdam_code_deposit_word_cost) catch null;
    }

    fn noDepositStateGas(_: i64) ?i64 {
        return 0;
    }

    fn amsterdamDepositStateGas(runtime_size: i64) ?i64 {
        return std.math.mul(i64, runtime_size, eth_tx.amsterdam_cost_per_state_byte) catch null;
    }

    fn preShanghaiInitcodeWordGas(is_create2: bool) i64 {
        return if (is_create2) 6 else 0;
    }

    fn shanghaiInitcodeWordGas(is_create2: bool) i64 {
        return @as(i64, @intCast(eth_tx.initcode_word_gas)) + @as(i64, if (is_create2) 6 else 0);
    }

    fn noCreateAccountStateGas(_: execution.CreateAccountStateGasInput) i64 {
        return 0;
    }

    fn amsterdamCreateAccountStateGas(input: execution.CreateAccountStateGasInput) i64 {
        return if (input.target_alive) 0 else @intCast(eth_tx.amsterdam_new_account_state_gas);
    }

    fn noStorageAccess(_: execution.AccountAccessStatus) ?i64 {
        return null;
    }

    fn berlinStorageAccess(status: execution.AccountAccessStatus) ?i64 {
        return if (status == .cold) cold_sload_cost else 0;
    }

    fn amsterdamStorageAccess(status: execution.AccountAccessStatus) ?i64 {
        return if (status == .cold) @intCast(eth_tx.amsterdam_cold_storage_access_cost) else warm_storage_read_cost;
    }

    const StorageSchedule = struct {
        warm_access: i64,
        set: i64,
        reset: i64,
        clear: i64,
        net: bool,
    };

    fn frontierSstore(status: execution.StorageStatus) execution.StorageGas {
        return scheduledSstore(.{ .warm_access = 200, .set = 20_000, .reset = 5_000, .clear = 15_000, .net = false }, status);
    }

    fn constantinopleSstore(status: execution.StorageStatus) execution.StorageGas {
        return scheduledSstore(.{ .warm_access = 200, .set = 20_000, .reset = 5_000, .clear = 15_000, .net = true }, status);
    }

    fn istanbulSstore(status: execution.StorageStatus) execution.StorageGas {
        return scheduledSstore(.{ .warm_access = 800, .set = 20_000, .reset = 5_000, .clear = 15_000, .net = true }, status);
    }

    fn berlinSstore(status: execution.StorageStatus) execution.StorageGas {
        return scheduledSstore(.{ .warm_access = 100, .set = 20_000, .reset = 2_900, .clear = 15_000, .net = true }, status);
    }

    fn londonSstore(status: execution.StorageStatus) execution.StorageGas {
        return scheduledSstore(.{ .warm_access = 100, .set = 20_000, .reset = 2_900, .clear = 4_800, .net = true }, status);
    }

    fn scheduledSstore(schedule: StorageSchedule, status: execution.StorageStatus) execution.StorageGas {
        if (!schedule.net) {
            return switch (status) {
                .added, .deleted_added, .deleted_restored => .{ .cost = schedule.set },
                .deleted, .modified_deleted, .added_deleted => .{ .cost = schedule.reset, .refund = schedule.clear },
                .modified, .assigned, .modified_restored => .{ .cost = schedule.reset },
            };
        }
        return switch (status) {
            .assigned => .{ .cost = schedule.warm_access },
            .added => .{ .cost = schedule.set },
            .deleted => .{ .cost = schedule.reset, .refund = schedule.clear },
            .modified => .{ .cost = schedule.reset },
            .deleted_added => .{ .cost = schedule.warm_access, .refund = -schedule.clear },
            .modified_deleted => .{ .cost = schedule.warm_access, .refund = schedule.clear },
            .deleted_restored => .{ .cost = schedule.warm_access, .refund = schedule.reset - schedule.warm_access - schedule.clear },
            .added_deleted => .{ .cost = schedule.warm_access, .refund = schedule.set - schedule.warm_access },
            .modified_restored => .{ .cost = schedule.warm_access, .refund = schedule.reset - schedule.warm_access },
        };
    }

    fn amsterdamSstore(status: execution.StorageStatus) execution.StorageGas {
        const write: i64 = @intCast(eth_tx.amsterdam_storage_write_cost);
        const clear: i64 = @intCast(eth_tx.amsterdam_storage_clear_refund);
        return switch (status) {
            .assigned => .{},
            .added, .modified => .{ .cost = write },
            .deleted => .{ .cost = write, .refund = clear },
            .deleted_added => .{ .refund = -clear },
            .modified_deleted => .{ .refund = clear },
            .deleted_restored => .{ .refund = write - clear },
            .added_deleted, .modified_restored => .{ .refund = write },
        };
    }

    fn noSstoreState(_: execution.StorageStatus) execution.StorageStateGas {
        return .{};
    }

    fn amsterdamSstoreState(status: execution.StorageStatus) execution.StorageStateGas {
        const charge: i64 = @intCast(eth_tx.amsterdam_storage_set_state_gas);
        return switch (status) {
            .added => .{ .charge = charge },
            .added_deleted => .{ .refund = charge },
            else => .{},
        };
    }

    fn legacySelfDestructPolicy(_: execution.SelfDestructPolicyInput) execution.SelfDestructPolicy {
        return .{ .clear_balance = true, .reset_nonce = false, .mark_selfdestructed = true };
    }

    fn cancunSelfDestructPolicy(input: execution.SelfDestructPolicyInput) execution.SelfDestructPolicy {
        return .{
            .clear_balance = !input.same_address or input.created_in_transaction,
            .reset_nonce = false,
            .mark_selfdestructed = true,
        };
    }

    fn amsterdamSelfDestructPolicy(input: execution.SelfDestructPolicyInput) execution.SelfDestructPolicy {
        return .{
            .clear_balance = !input.same_address,
            .reset_nonce = input.same_address and input.created_in_transaction,
            .mark_selfdestructed = !input.same_address or input.created_in_transaction,
        };
    }

    fn legacySelfDestructFinalization(_: bool) execution.SelfDestructFinalization {
        return .{ .delete_account = true, .clear_storage = true };
    }

    fn cancunSelfDestructFinalization(created: bool) execution.SelfDestructFinalization {
        return if (created) .{ .delete_account = true, .clear_storage = true } else .{};
    }

    fn amsterdamSelfDestructFinalization(created: bool) execution.SelfDestructFinalization {
        return if (created) .{ .clear_storage = true, .reset_account = true } else .{};
    }

    fn noSelfDestructNewAccount(_: execution.SelfDestructNewAccountInput) execution.CallNewAccountGas {
        return .{};
    }

    fn tangerineSelfDestructNewAccount(input: execution.SelfDestructNewAccountInput) execution.CallNewAccountGas {
        return if (!input.same_address and !input.account_exists) .{ .regular = account_creation_cost } else .{};
    }

    fn spuriousSelfDestructNewAccount(input: execution.SelfDestructNewAccountInput) execution.CallNewAccountGas {
        return if (!input.same_address and input.transfers_balance and !input.account_exists)
            .{ .regular = account_creation_cost }
        else
            .{};
    }

    fn amsterdamSelfDestructNewAccount(input: execution.SelfDestructNewAccountInput) execution.CallNewAccountGas {
        return if (!input.same_address and input.transfers_balance and !input.account_exists)
            .{
                .regular = @intCast(eth_tx.amsterdam_account_write_cost),
                .state = @intCast(eth_tx.amsterdam_new_account_state_gas),
            }
        else
            .{};
    }

    fn noValueTransferLog(_: execution.ValueTransferInput) ?execution.ValueTransferLog {
        return null;
    }

    fn amsterdamValueTransferLog(input: execution.ValueTransferInput) ?execution.ValueTransferLog {
        if (input.amount == 0 or std.mem.eql(u8, &input.from, &input.to)) return null;
        return .{ .address = eth_system.system_address, .topic = eth_system.value_transfer_log_topic };
    }
};

const cancun_blob_schedule: tx_blob.BlobSchedule = .{
    .target = 3,
    .max = 6,
    .max_per_transaction = 6,
    .gas_per_blob = eth_tx.blob_gas_per_blob,
    .min_base_fee = eth_tx.min_blob_base_fee,
    .execution_base_cost = eth_tx.blob_base_cost,
    .base_fee_update_fraction = eth_tx.cancun_blob_base_fee_update_fraction,
    .reserve_price_active = false,
    .hash_version = 0x01,
};

const prague_blob_schedule: tx_blob.BlobSchedule = .{
    .target = 6,
    .max = 9,
    .max_per_transaction = 9,
    .gas_per_blob = eth_tx.blob_gas_per_blob,
    .min_base_fee = eth_tx.min_blob_base_fee,
    .execution_base_cost = eth_tx.blob_base_cost,
    .base_fee_update_fraction = eth_tx.prague_blob_base_fee_update_fraction,
    .reserve_price_active = false,
    .hash_version = 0x01,
};

const osaka_blob_schedule: tx_blob.BlobSchedule = .{
    .target = 6,
    .max = 9,
    .max_per_transaction = 6,
    .gas_per_blob = eth_tx.blob_gas_per_blob,
    .min_base_fee = eth_tx.min_blob_base_fee,
    .execution_base_cost = eth_tx.blob_base_cost,
    .base_fee_update_fraction = eth_tx.prague_blob_base_fee_update_fraction,
    .reserve_price_active = true,
    .hash_version = 0x01,
};

const amsterdam_blob_schedule: tx_blob.BlobSchedule = .{
    .target = 14,
    .max = 21,
    .max_per_transaction = 6,
    .gas_per_blob = eth_tx.blob_gas_per_blob,
    .min_base_fee = eth_tx.min_blob_base_fee,
    .execution_base_cost = eth_tx.blob_base_cost,
    .base_fee_update_fraction = eth_tx.amsterdam_blob_base_fee_update_fraction,
    .reserve_price_active = true,
    .hash_version = 0x01,
};

pub const frontier: Spec = .{
    .transaction = .{
        .active_kinds = .initMany(&.{.legacy}),
        .allowsContractCreation = semantics.allowsContractCreation,
        .requiresAuthorizationList = semantics.requiresAuthorizationList,
        .rejectsNonDelegatingSenderCode = semantics.rejectsSenderCodeBeforeLondon,
        .isDelegationCode = semantics.noDelegationCode,
        .blob_schedule = null,
        .max_initcode_size = std.math.maxInt(usize),
        .intrinsicBaseGas = semantics.legacyIntrinsicBase,
        .create_intrinsic_gas = 0,
        .calldataGas = semantics.calldataBeforeIstanbul,
        .access_list_address_gas = eth_tx.access_list_address_gas,
        .storage_key_gas = eth_tx.access_list_storage_key_gas,
        .accessListDataGas = semantics.noAccessListData,
        .initcode_word_gas = 0,
        .authorization_intrinsic_gas = 0,
        .floorGas = semantics.noFloor,
        .regular_gas_cap = null,
        .intrinsic_regular_gas_limit = null,
        .total_gas_limit = null,
        .warms_coinbase = false,
    },
    .settlement = .{
        .base_fee_active = false,
        .gas_refund_cap_divisor = 2,
        .uses_state_gas_accounting = false,
        .applies_calldata_floor_to_block_regular_gas = false,
        .touches_fee_recipient_on_zero_payment = true,
    },
    .authorization = .{
        .active = false,
        .warms_delegated_target = false,
        .successGasAdjustment = semantics.legacyAuthorizationSuccess,
        .invalid_gas_adjustment = .{},
        .malformedGasAdjustment = semantics.noMalformedAuthorization,
    },
    .block = .{
        .beforeBlock = semantics.noBeforeBlock,
        .beforeTransaction = semantics.noBeforeTransaction,
        .afterTransaction = semantics.noAfterTransaction,
        .finalizeBlock = semantics.noFinalize,
    },
    .call = .{
        .base_gas = 40,
        .cold_account_access_gas = null,
        .value_transfer_gas = 9_000,
        .value_stipend = eth_tx.call_stipend,
        .newAccountGas = semantics.frontierCallNewAccount,
        .topFrameValueTransferStateGas = semantics.noTopFrameStateGas,
        .delegatedAccountAccessGas = semantics.legacyDelegatedAccountAccess,
        .topLevelDelegatedAccountAccess = semantics.noTopLevelDelegatedAccountAccess,
        .touches_empty_recipient = true,
        .childGas = semantics.legacyChildGas,
    },
    .create = .{
        .code_size_limit = null,
        .rejectsCode = semantics.acceptsCreateCode,
        .depositRegularGas = semantics.legacyDepositRegularGas,
        .depositStateGas = semantics.noDepositStateGas,
        .deposit_regular_gas_oog_commits = true,
        .warms_created_address = false,
        .initial_nonce = 0,
        .initcode_size_limit = null,
        .initcodeWordGas = semantics.preShanghaiInitcodeWordGas,
        .accountStateGas = semantics.noCreateAccountStateGas,
    },
    .storage = .{
        .sload_cold_access_gas = null,
        .sstore_minimum_gas = null,
        .sstoreAccessGas = semantics.noStorageAccess,
        .sstoreGas = semantics.frontierSstore,
        .sstoreStateGas = semantics.noSstoreState,
    },
    .self_destruct = .{
        .policy = semantics.legacySelfDestructPolicy,
        .finalization = semantics.legacySelfDestructFinalization,
        .touches_beneficiary_on_zero_transfer = true,
        .newAccountGas = semantics.noSelfDestructNewAccount,
        .cold_account_access_gas = null,
        .refund_gas = 24_000,
    },
    .valueTransferLog = semantics.noValueTransferLog,
    .instruction = eth_instruction.frontier,
    .precompile = eth_precompile.Exact(eth_precompile.frontier_config),
};

pub const frontier_thawing = frontier;

pub const homestead = frontier_thawing.extend(.{
    .transaction = .{ .create_intrinsic_gas = eth_tx.create_transaction_gas },
    .create = .{ .deposit_regular_gas_oog_commits = false },
    .instruction = eth_instruction.homestead,
});
pub const dao_fork = homestead;

pub const tangerine_whistle = dao_fork.extend(.{
    .call = .{ .base_gas = 700, .childGas = semantics.eip150ChildGas },
    .self_destruct = .{ .newAccountGas = semantics.tangerineSelfDestructNewAccount },
    .instruction = eth_instruction.tangerine_whistle,
});

pub const spurious_dragon = tangerine_whistle.extend(.{
    .settlement = .{ .touches_fee_recipient_on_zero_payment = false },
    .call = .{ .newAccountGas = semantics.spuriousCallNewAccount, .touches_empty_recipient = false },
    .create = .{ .code_size_limit = .{ .replace = eth_system.max_code_size }, .initial_nonce = 1 },
    .self_destruct = .{
        .touches_beneficiary_on_zero_transfer = false,
        .newAccountGas = semantics.spuriousSelfDestructNewAccount,
    },
    .instruction = eth_instruction.spurious_dragon,
});

pub const byzantium = spurious_dragon.extend(.{
    .instruction = eth_instruction.byzantium,
    .precompile = eth_precompile.Exact(eth_precompile.byzantium_config),
});

pub const constantinople = byzantium.extend(.{
    .storage = .{ .sstoreGas = semantics.constantinopleSstore },
    .instruction = eth_instruction.constantinople,
});

pub const petersburg = constantinople.extend(.{
    .storage = .{ .sstoreGas = semantics.frontierSstore },
});

pub const istanbul = petersburg.extend(.{
    .transaction = .{ .calldataGas = semantics.calldataSinceIstanbul },
    .storage = .{
        .sstore_minimum_gas = .{ .replace = eth_tx.call_stipend },
        .sstoreGas = semantics.istanbulSstore,
    },
    .instruction = eth_instruction.istanbul,
    .precompile = eth_precompile.Exact(eth_precompile.istanbul_config),
});

pub const muir_glacier = istanbul;

pub const berlin = muir_glacier.extend(.{
    .transaction = .{ .active_kinds = std.EnumSet(tx.TxKind).initMany(&.{ .legacy, .access_list }) },
    .call = .{ .base_gas = 100, .cold_account_access_gas = .{ .replace = cold_account_access_cost - warm_storage_read_cost } },
    .create = .{ .warms_created_address = true },
    .storage = .{
        .sload_cold_access_gas = .{ .replace = cold_sload_cost - warm_storage_read_cost },
        .sstoreAccessGas = semantics.berlinStorageAccess,
        .sstoreGas = semantics.berlinSstore,
    },
    .self_destruct = .{ .cold_account_access_gas = .{ .replace = cold_account_access_cost } },
    .instruction = eth_instruction.berlin,
    .precompile = eth_precompile.Exact(eth_precompile.berlin_config),
});
pub const london = berlin.extend(.{
    .transaction = .{
        .active_kinds = std.EnumSet(tx.TxKind).initMany(&.{ .legacy, .access_list, .dynamic_fee }),
        .rejectsNonDelegatingSenderCode = semantics.rejectsAllSenderCode,
    },
    .settlement = .{ .base_fee_active = true, .gas_refund_cap_divisor = 5 },
    .create = .{ .rejectsCode = semantics.rejectsEfCreateCode },
    .storage = .{ .sstoreGas = semantics.londonSstore },
    .self_destruct = .{ .refund_gas = 0 },
    .instruction = eth_instruction.london,
});

pub const arrow_glacier = london;

pub const gray_glacier = arrow_glacier;

pub const merge_fork = gray_glacier;

pub const shanghai = merge_fork.extend(.{
    .transaction = .{
        .max_initcode_size = eth_tx.max_initcode_size,
        .initcode_word_gas = eth_tx.initcode_word_gas,
        .warms_coinbase = true,
    },
    .create = .{
        .initcode_size_limit = .{ .replace = eth_tx.max_initcode_size },
        .initcodeWordGas = semantics.shanghaiInitcodeWordGas,
    },
    .instruction = eth_instruction.shanghai,
});

pub const cancun = shanghai.extend(.{
    .transaction = .{
        .active_kinds = std.EnumSet(tx.TxKind).initMany(&.{ .legacy, .access_list, .dynamic_fee, .blob }),
        .blob_schedule = .{ .replace = cancun_blob_schedule },
    },
    .block = .{ .beforeBlock = semantics.cancunBeforeBlock },
    .self_destruct = .{
        .policy = semantics.cancunSelfDestructPolicy,
        .finalization = semantics.cancunSelfDestructFinalization,
    },
    .instruction = eth_instruction.cancun,
    .precompile = eth_precompile.Exact(eth_precompile.cancun_config),
});

pub const prague = cancun.extend(.{
    .transaction = .{
        .active_kinds = std.EnumSet(tx.TxKind).initMany(&.{ .legacy, .access_list, .dynamic_fee, .blob, .set_code }),
        .isDelegationCode = semantics.eip7702DelegationCode,
        .blob_schedule = .{ .replace = prague_blob_schedule },
        .authorization_intrinsic_gas = eth_tx.authorization_intrinsic_gas,
        .floorGas = semantics.pragueFloor,
    },
    .authorization = .{ .active = true, .warms_delegated_target = true },
    .block = .{ .beforeBlock = semantics.pragueBeforeBlock, .finalizeBlock = semantics.pragueFinalize },
    .precompile = eth_precompile.Exact(eth_precompile.prague_config),
});

pub const osaka = prague.extend(.{
    .transaction = .{
        .blob_schedule = .{ .replace = osaka_blob_schedule },
        .regular_gas_cap = .{ .replace = eth_tx.max_transaction_gas_limit },
        .total_gas_limit = .{ .replace = eth_tx.max_transaction_gas_limit },
    },
    .instruction = eth_instruction.osaka,
    .precompile = eth_precompile.Exact(eth_precompile.osaka_config),
});

pub const amsterdam = osaka.extend(.{
    .transaction = .{
        .blob_schedule = .{ .replace = amsterdam_blob_schedule },
        .max_initcode_size = eth_tx.amsterdam_max_initcode_size,
        .intrinsicBaseGas = semantics.amsterdamIntrinsicBase,
        .create_intrinsic_gas = 0,
        .access_list_address_gas = eth_tx.amsterdam_access_list_address_gas,
        .storage_key_gas = eth_tx.amsterdam_access_list_storage_key_gas,
        .accessListDataGas = semantics.amsterdamAccessListData,
        .authorization_intrinsic_gas = eth_tx.amsterdam_regular_per_auth_base_cost,
        .floorGas = semantics.amsterdamFloor,
        .intrinsic_regular_gas_limit = .{ .replace = eth_tx.max_transaction_gas_limit },
        .total_gas_limit = .{ .replace = null },
    },
    .settlement = .{
        .uses_state_gas_accounting = true,
        .applies_calldata_floor_to_block_regular_gas = true,
    },
    .authorization = .{
        .warms_delegated_target = false,
        .successGasAdjustment = semantics.amsterdamAuthorizationSuccess,
    },
    .block = .{
        .beforeBlock = semantics.amsterdamBeforeBlock,
        .finalizeBlock = semantics.amsterdamFinalize,
    },
    .call = .{
        .cold_account_access_gas = .{ .replace = @as(i64, @intCast(eth_tx.amsterdam_cold_account_access_cost)) - warm_storage_read_cost },
        .value_transfer_gas = eth_tx.amsterdam_call_value_cost,
        .newAccountGas = semantics.amsterdamCallNewAccount,
        .topFrameValueTransferStateGas = semantics.amsterdamTopFrameStateGas,
        .delegatedAccountAccessGas = semantics.amsterdamDelegatedAccountAccess,
        .topLevelDelegatedAccountAccess = semantics.amsterdamTopLevelDelegatedAccountAccess,
    },
    .create = .{
        .code_size_limit = .{ .replace = eth_system.amsterdam_max_code_size },
        .initcode_size_limit = .{ .replace = eth_tx.amsterdam_max_initcode_size },
        .depositRegularGas = semantics.amsterdamDepositRegularGas,
        .depositStateGas = semantics.amsterdamDepositStateGas,
        .accountStateGas = semantics.amsterdamCreateAccountStateGas,
    },
    .storage = .{
        .sload_cold_access_gas = .{ .replace = @as(i64, @intCast(eth_tx.amsterdam_cold_storage_access_cost)) - warm_storage_read_cost },
        .sstoreAccessGas = semantics.amsterdamStorageAccess,
        .sstoreGas = semantics.amsterdamSstore,
        .sstoreStateGas = semantics.amsterdamSstoreState,
    },
    .self_destruct = .{
        .policy = semantics.amsterdamSelfDestructPolicy,
        .finalization = semantics.amsterdamSelfDestructFinalization,
        .newAccountGas = semantics.amsterdamSelfDestructNewAccount,
        .cold_account_access_gas = .{ .replace = eth_tx.amsterdam_cold_account_access_cost },
    },
    .valueTransferLog = semantics.amsterdamValueTransferLog,
    .instruction = eth_instruction.amsterdam,
});

pub fn specAt(comptime revision: Revision) Spec {
    return switch (revision) {
        .frontier => frontier,
        .frontier_thawing => frontier_thawing,
        .homestead => homestead,
        .dao_fork => dao_fork,
        .tangerine_whistle => tangerine_whistle,
        .spurious_dragon => spurious_dragon,
        .byzantium => byzantium,
        .constantinople => constantinople,
        .petersburg => petersburg,
        .istanbul => istanbul,
        .muir_glacier => muir_glacier,
        .berlin => berlin,
        .london => london,
        .arrow_glacier => arrow_glacier,
        .gray_glacier => gray_glacier,
        .merge => merge_fork,
        .shanghai => shanghai,
        .cancun => cancun,
        .prague => prague,
        .osaka => osaka,
        .amsterdam => amsterdam,
    };
}

pub const stable: Spec = osaka;
pub const latest: Spec = amsterdam;
