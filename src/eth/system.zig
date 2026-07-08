const std = @import("std");
const address = @import("../address.zig");
const interface = @import("../protocol/interface.zig");
const tx = @import("transaction.zig");
const Revision = @import("revision.zig").Revision;
const Address = address.Address;

pub const system_address = address.addr(0xfffffffffffffffffffffffffffffffffffffffe);
pub const beacon_roots_address = address.addr(0x000f3df6d732807ef1319fb7b8bb8522d0beac02);
pub const history_storage_address = address.addr(0x0000f90827f1c53a10cb7a02335b175320002935);
pub const value_transfer_log_topic = 0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef;
pub const system_call_gas: u64 = 30_000_000;
const call_static_gas_floor: i64 = 40;
const call_value_cost: i64 = 9000;
const account_creation_cost: i64 = 25000;
const cold_account_access_cost: i64 = 2600;
const warm_storage_read_cost: i64 = 100;
const cold_account_access_gas: i64 = cold_account_access_cost - warm_storage_read_cost;
const cold_sload_cost: i64 = 2100;
const cold_sload_gas: i64 = cold_sload_cost - warm_storage_read_cost;

pub const Storage = struct {
    pub fn sloadColdStorageAccessGas(revision: Revision) ?i64 {
        if (!revision.isImpl(.berlin)) return null;
        if (revision.isImpl(.amsterdam)) return tx.amsterdam_cold_storage_access_cost - warm_storage_read_cost;
        return cold_sload_gas;
    }

    pub fn sstoreMinimumGas(revision: Revision) ?i64 {
        return if (revision.isImpl(.istanbul)) @intCast(tx.call_stipend) else null;
    }

    pub fn sstoreStorageAccessGas(revision: Revision, status: interface.AccountAccessStatus) ?i64 {
        if (!revision.isImpl(.berlin)) return null;
        return switch (status) {
            .cold => if (revision.isImpl(.amsterdam))
                std.math.cast(i64, tx.amsterdam_cold_storage_access_cost) orelse std.math.maxInt(i64)
            else
                cold_sload_cost,
            .warm => if (revision.isImpl(.amsterdam))
                warm_storage_read_cost
            else
                0,
        };
    }

    pub fn sstoreGas(revision: Revision, status: interface.StorageStatus) interface.StorageGas {
        if (revision.isImpl(.amsterdam)) {
            const storage_write: i64 = @intCast(tx.amsterdam_storage_write_cost);
            const clear_refund: i64 = @intCast(tx.amsterdam_storage_clear_refund);
            return switch (status) {
                .assigned => .{},
                .added, .modified => .{ .cost = storage_write },
                .deleted => .{ .cost = storage_write, .refund = clear_refund },
                .deleted_added => .{ .refund = -clear_refund },
                .modified_deleted => .{ .refund = clear_refund },
                .deleted_restored => .{ .refund = storage_write - clear_refund },
                .added_deleted, .modified_restored => .{ .refund = storage_write },
            };
        }

        const action = sstoreActionCost(revision);
        const net_gas = revision == .constantinople or revision.isImpl(.istanbul);
        if (!net_gas) {
            return switch (status) {
                .added, .deleted_added, .deleted_restored => .{ .cost = action.set },
                .deleted, .modified_deleted, .added_deleted => .{ .cost = action.reset, .refund = action.clear },
                .modified, .assigned, .modified_restored => .{ .cost = action.reset },
            };
        }

        return switch (status) {
            .assigned => .{ .cost = action.warm_access },
            .added => .{ .cost = action.set },
            .deleted => .{ .cost = action.reset, .refund = action.clear },
            .modified => .{ .cost = action.reset },
            .deleted_added => .{ .cost = action.warm_access, .refund = -action.clear },
            .modified_deleted => .{ .cost = action.warm_access, .refund = action.clear },
            .deleted_restored => .{ .cost = action.warm_access, .refund = action.reset - action.warm_access - action.clear },
            .added_deleted => .{ .cost = action.warm_access, .refund = action.set - action.warm_access },
            .modified_restored => .{ .cost = action.warm_access, .refund = action.reset - action.warm_access },
        };
    }

    pub fn sstoreStateGas(revision: Revision, status: interface.StorageStatus) interface.StorageStateGas {
        if (!revision.isImpl(.amsterdam)) return .{};
        const state_gas = std.math.cast(i64, tx.amsterdam_storage_set_state_gas) orelse std.math.maxInt(i64);
        return switch (status) {
            .added => .{ .charge = state_gas },
            .added_deleted => .{ .refund = state_gas },
            else => .{},
        };
    }
};

pub const Block = struct {
    pub fn valueTransferLog(revision: Revision, from: Address, to: Address, amount: u256) ?interface.ValueTransferLog {
        if (!revision.isImpl(.amsterdam)) return null;
        if (amount == 0) return null;
        if (std.mem.eql(u8, &from, &to)) return null;
        return .{
            .address = system_address,
            .topic = value_transfer_log_topic,
        };
    }

    pub fn blockStartSystemCalls(revision: Revision, context: interface.BlockStartContext) interface.BlockStartSystemCalls {
        var calls = interface.BlockStartSystemCalls{};
        if (context.number == 0) return calls;

        if (revision.isImpl(.cancun)) {
            if (context.parent_beacon_block_root) |root| {
                calls.append(.{
                    .sender = system_address,
                    .recipient = beacon_roots_address,
                    .input = root,
                    .gas = system_call_gas,
                });
            }
        }

        if (revision.isImpl(.prague)) {
            if (context.parent_hash) |hash| {
                calls.append(.{
                    .sender = system_address,
                    .recipient = history_storage_address,
                    .input = hash,
                    .gas = system_call_gas,
                });
            }
        }

        return calls;
    }

    pub fn transactionWarmsCoinbase(revision: Revision) bool {
        return revision.isImpl(.shanghai);
    }
};

const StorageActionCost = struct {
    warm_access: i64,
    set: i64,
    reset: i64,
    clear: i64,
};

fn sstoreActionCost(revision: Revision) StorageActionCost {
    var action = StorageActionCost{
        .warm_access = 200,
        .set = 20000,
        .reset = 5000,
        .clear = 15000,
    };

    if (revision.isImpl(.istanbul)) {
        action.warm_access = 800;
    }

    if (revision.isImpl(.berlin)) {
        action.warm_access = warm_storage_read_cost;
        action.reset = 5000 - cold_sload_cost;
    }

    if (revision.isImpl(.london)) {
        action.clear = 4800;
    }

    return action;
}

pub const Create = struct {
    pub const max_code_size = 0x6000;
    pub const amsterdam_max_code_size = 0x10000;

    pub fn createCodeSizeLimit(revision: Revision) ?usize {
        if (!revision.isImpl(.spurious_dragon)) return null;
        return if (revision.isImpl(.amsterdam)) amsterdam_max_code_size else max_code_size;
    }

    pub fn rejectsCreateCode(revision: Revision, code: []const u8) bool {
        return revision.isImpl(.london) and code.len > 0 and code[0] == 0xef;
    }

    pub fn createDepositRegularGas(revision: Revision, runtime_size: i64) ?i64 {
        if (revision.isImpl(.amsterdam)) {
            const words = @divFloor(runtime_size + 31, 32);
            return std.math.mul(i64, words, tx.amsterdam_code_deposit_word_cost) catch null;
        }
        return std.math.mul(i64, runtime_size, 200) catch null;
    }

    pub fn createDepositStateGas(revision: Revision, runtime_size: i64) ?i64 {
        if (!revision.isImpl(.amsterdam)) return 0;
        return std.math.mul(i64, runtime_size, tx.amsterdam_cost_per_state_byte) catch null;
    }

    pub fn createDepositRegularGasOogCommits(revision: Revision) bool {
        return !revision.isImpl(.homestead);
    }

    pub fn createAccountStateGasRefund(revision: Revision, account_pre_existing: bool) i64 {
        if (!revision.isImpl(.amsterdam) or !account_pre_existing) return 0;
        return std.math.cast(i64, tx.amsterdam_new_account_state_gas) orelse std.math.maxInt(i64);
    }

    pub fn createTransactionRollbackStateGasRefund(revision: Revision) i64 {
        if (!revision.isImpl(.amsterdam)) return 0;
        return std.math.cast(i64, tx.amsterdam_new_account_state_gas) orelse std.math.maxInt(i64);
    }

    pub fn createWarmsCreatedAddress(revision: Revision) bool {
        return revision.isImpl(.berlin);
    }

    pub fn createInitialNonce(revision: Revision) u64 {
        return if (revision.isImpl(.spurious_dragon)) 1 else 0;
    }

    pub fn createInitCodeSizeLimit(revision: Revision) ?usize {
        if (!revision.isImpl(.shanghai)) return null;
        return tx.Transaction.maxInitcodeSize(revision);
    }

    pub fn createInitCodeWordGas(revision: Revision, is_create2: bool) i64 {
        var cost: i64 = 0;
        if (revision.isImpl(.shanghai)) {
            cost += std.math.cast(i64, tx.initcode_word_gas) orelse std.math.maxInt(i64);
        }
        if (is_create2) {
            cost += 6;
        }
        return cost;
    }

    pub fn createAccountStateGas(revision: Revision) i64 {
        if (!revision.isImpl(.amsterdam)) return 0;
        return std.math.cast(i64, tx.amsterdam_new_account_state_gas) orelse std.math.maxInt(i64);
    }
};

pub const Call = struct {
    pub fn callBaseGas(revision: Revision) i64 {
        if (revision.isImpl(.berlin)) return warm_storage_read_cost;
        if (revision.isImpl(.tangerine_whistle)) return 700;
        return call_static_gas_floor;
    }

    pub fn callColdAccountAccessGas(revision: Revision) ?i64 {
        if (!revision.isImpl(.berlin)) return null;
        return if (revision.isImpl(.amsterdam))
            std.math.cast(i64, tx.amsterdam_cold_account_access_cost - warm_storage_read_cost) orelse std.math.maxInt(i64)
        else
            cold_account_access_gas;
    }

    pub fn callValueTransferGas(revision: Revision) i64 {
        if (revision.isImpl(.amsterdam)) {
            return std.math.cast(i64, tx.amsterdam_call_value_cost) orelse std.math.maxInt(i64);
        }
        return call_value_cost;
    }

    pub fn callValueStipend(revision: Revision) i64 {
        _ = revision;
        return @intCast(tx.call_stipend);
    }

    pub fn callNewAccountGas(revision: Revision, value: u256, account_exists: bool) interface.CallNewAccountGas {
        const charges_new_account = if (revision.isImpl(.spurious_dragon))
            value > 0 and !account_exists
        else
            !account_exists;
        if (!charges_new_account) return .{};
        if (revision.isImpl(.amsterdam)) {
            return .{ .state = std.math.cast(i64, tx.amsterdam_new_account_state_gas) orelse std.math.maxInt(i64) };
        }
        return .{ .regular = account_creation_cost };
    }

    pub fn topFrameValueTransferStateGas(revision: Revision, value: u256, same_address: bool, account_exists: bool) i64 {
        if (!revision.isImpl(.amsterdam)) return 0;
        if (value == 0 or same_address or account_exists) return 0;
        return std.math.cast(i64, tx.amsterdam_new_account_state_gas) orelse std.math.maxInt(i64);
    }

    pub fn delegatedAccountAccessGas(revision: Revision, cold: bool) i64 {
        if (!cold) return warm_storage_read_cost;
        if (revision.isImpl(.amsterdam)) return std.math.cast(i64, tx.amsterdam_cold_account_access_cost) orelse std.math.maxInt(i64);
        return cold_account_access_cost;
    }

    pub fn topLevelDelegatedAccountAccess(revision: Revision, target_is_precompile: bool, already_warm: bool) ?interface.DelegatedAccountAccess {
        if (!revision.isImpl(.amsterdam)) return null;
        _ = target_is_precompile;
        _ = already_warm;
        return .{
            .status = .cold,
            .gas = @This().delegatedAccountAccessGas(revision, true),
        };
    }

    pub fn touchesEmptyCallRecipient(revision: Revision) bool {
        return !revision.isImpl(.spurious_dragon);
    }

    pub fn childGas(revision: Revision, requested: i64, available: i64) interface.ChildGas {
        if (revision.isImpl(.tangerine_whistle)) {
            return .{ .gas = @min(requested, available - @divFloor(available, 64)) };
        }
        if (requested > available) return .{ .gas = 0, .out_of_gas = true };
        return .{ .gas = requested };
    }
};

pub const SelfDestruct = struct {
    pub fn selfDestructPolicy(
        revision: Revision,
        same_address: bool,
        created_in_transaction: bool,
    ) interface.SelfDestructPolicy {
        return .{
            .clear_balance = !same_address or ((!revision.isImpl(.cancun) or created_in_transaction) and !revision.isImpl(.amsterdam)),
            .reset_nonce = same_address and revision.isImpl(.amsterdam) and created_in_transaction,
            .mark_selfdestructed = !same_address or !revision.isImpl(.amsterdam) or created_in_transaction,
        };
    }

    pub fn selfDestructFinalization(revision: Revision, created_in_transaction: bool) interface.SelfDestructFinalization {
        if (revision.isImpl(.amsterdam) and created_in_transaction) {
            return .{
                .clear_storage = true,
                .reset_account = true,
            };
        }
        if (revision.isImpl(.cancun) and !created_in_transaction) return .{};
        return .{
            .delete_account = true,
            .clear_storage = true,
        };
    }

    pub fn selfDestructNewAccountGas(
        revision: Revision,
        same_address: bool,
        transfers_balance: bool,
        account_exists: bool,
    ) interface.CallNewAccountGas {
        const charges_new_account = if (!revision.isImpl(.tangerine_whistle) or same_address)
            false
        else if (revision.isImpl(.spurious_dragon))
            transfers_balance
        else
            true;
        if (!charges_new_account or account_exists) return .{};
        if (revision.isImpl(.amsterdam)) {
            return .{
                .regular = std.math.cast(i64, tx.amsterdam_account_write_cost) orelse std.math.maxInt(i64),
                .state = std.math.cast(i64, tx.amsterdam_new_account_state_gas) orelse std.math.maxInt(i64),
            };
        }
        return .{ .regular = account_creation_cost };
    }

    pub fn selfDestructColdAccountAccessGas(revision: Revision) ?i64 {
        if (!revision.isImpl(.berlin)) return null;
        if (revision.isImpl(.amsterdam)) return std.math.cast(i64, tx.amsterdam_cold_account_access_cost) orelse std.math.maxInt(i64);
        return cold_account_access_cost;
    }

    pub fn selfDestructRefundGas(revision: Revision) i64 {
        return if (revision.isImpl(.london)) 0 else 24_000;
    }
};
