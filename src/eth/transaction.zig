const std = @import("std");
const tx = @import("../transaction/Transaction.zig");
const tx_blob = @import("../transaction/blob.zig");
const tx_gas = @import("../transaction/gas.zig");
const Revision = @import("revision.zig").Revision;
const eip7702 = @import("eip/7702.zig");
const eip8037 = @import("eip/8037.zig");

pub const blob_gas_per_blob: u64 = 131_072;
pub const min_blob_base_fee: u256 = 1;
pub const blob_base_cost: u64 = 8_192;
pub const cancun_blob_base_fee_update_fraction: u256 = 3_338_477;
pub const prague_blob_base_fee_update_fraction: u256 = 5_007_716;
pub const amsterdam_blob_base_fee_update_fraction: u256 = 11_684_671;
pub const blob_base_fee_update_fraction: u256 = cancun_blob_base_fee_update_fraction;

pub const authorization_intrinsic_gas = eip7702.per_empty_account_cost;
pub const authorization_existing_account_refund_gas = eip7702.existing_account_refund_gas;
pub const amsterdam_cost_per_state_byte = eip8037.cost_per_state_byte;
pub const amsterdam_state_bytes_per_new_account = eip8037.state_bytes_per_new_account;
pub const amsterdam_state_bytes_per_storage_set = eip8037.state_bytes_per_storage_set;
pub const amsterdam_account_write_cost = eip8037.account_write_cost;
pub const amsterdam_storage_write_cost = eip8037.storage_write_cost;
pub const amsterdam_storage_clear_refund = eip8037.storage_clear_refund;
pub const amsterdam_cold_storage_access_cost = eip8037.cold_storage_access_cost;
pub const call_stipend: u64 = 2_300;
pub const amsterdam_call_value_cost = eip8037.call_value_cost;
pub const amsterdam_code_deposit_word_cost = eip8037.code_deposit_word_cost;
pub const amsterdam_regular_per_auth_base_cost = eip8037.regular_per_auth_base_cost;
pub const amsterdam_auth_base_state_gas = eip8037.auth_base_state_gas;
pub const amsterdam_authorization_state_gas = eip8037.authorization_state_gas;
pub const amsterdam_authorization_intrinsic_gas = eip8037.authorization_intrinsic_gas;
pub const access_list_address_gas: u64 = 2_400;
pub const access_list_storage_key_gas: u64 = 1_900;
pub const amsterdam_access_list_address_gas = eip8037.access_list_address_gas;
pub const amsterdam_access_list_storage_key_gas = eip8037.access_list_storage_key_gas;
pub const access_list_address_data_gas: u64 = 1_280;
pub const access_list_storage_key_data_gas: u64 = 2_048;
pub const create_transaction_gas: u64 = 32_000;
pub const amsterdam_tx_base_cost = eip8037.tx_base_cost;
pub const amsterdam_cold_account_access_cost = eip8037.cold_account_access_cost;
pub const amsterdam_create_access_cost = eip8037.create_access_cost;
pub const amsterdam_tx_value_cost = eip8037.tx_value_cost;
pub const amsterdam_transfer_log_cost = eip8037.transfer_log_cost;
pub const amsterdam_new_account_state_gas = eip8037.new_account_state_gas;
pub const amsterdam_storage_set_state_gas = eip8037.storage_set_state_gas;
pub const initcode_word_gas: u64 = 2;
pub const max_initcode_size: usize = 49_152;
pub const amsterdam_max_initcode_size = eip8037.max_initcode_size;
pub const max_transaction_gas_limit = eip8037.max_transaction_gas_limit;

pub const Transaction = struct {
    pub fn kindActive(spec: Revision, kind: tx.TxKind) bool {
        return switch (kind) {
            .legacy => true,
            .access_list => spec.isImpl(.berlin),
            .dynamic_fee => spec.isImpl(.london),
            .blob => spec.isImpl(.cancun),
            .set_code => spec.isImpl(.prague),
        };
    }

    pub fn allowsContractCreation(spec: Revision, kind: tx.TxKind) bool {
        _ = spec;
        return switch (kind) {
            .legacy, .access_list, .dynamic_fee => true,
            .blob, .set_code => false,
        };
    }

    pub fn requiresAuthorizationList(spec: Revision, kind: tx.TxKind) bool {
        _ = spec;
        return kind == .set_code;
    }

    pub fn rejectsNonDelegatingSenderCode(spec: Revision, kind: tx.TxKind) bool {
        return kind == .set_code or spec.isImpl(.london);
    }

    pub fn blobSchedule(spec: Revision) ?tx_blob.BlobSchedule {
        if (!spec.isImpl(.cancun)) return null;
        if (spec.isImpl(.amsterdam)) {
            return .{
                .target = 14,
                .max = 21,
                .max_per_transaction = 6,
                .gas_per_blob = blob_gas_per_blob,
                .min_base_fee = min_blob_base_fee,
                .execution_base_cost = blob_base_cost,
                .base_fee_update_fraction = amsterdam_blob_base_fee_update_fraction,
                .reserve_price_active = true,
            };
        }
        if (spec.isImpl(.prague)) {
            return .{
                .target = 6,
                .max = 9,
                .max_per_transaction = if (spec.isImpl(.osaka)) 6 else 9,
                .gas_per_blob = blob_gas_per_blob,
                .min_base_fee = min_blob_base_fee,
                .execution_base_cost = blob_base_cost,
                .base_fee_update_fraction = prague_blob_base_fee_update_fraction,
                .reserve_price_active = spec.isImpl(.osaka),
            };
        }
        return .{
            .target = 3,
            .max = 6,
            .max_per_transaction = 6,
            .gas_per_blob = blob_gas_per_blob,
            .min_base_fee = min_blob_base_fee,
            .execution_base_cost = blob_base_cost,
            .base_fee_update_fraction = cancun_blob_base_fee_update_fraction,
            .reserve_price_active = false,
        };
    }

    pub fn blobVersionedHashActive(spec: Revision, version: u8) bool {
        _ = spec;
        return version == 0x01;
    }

    pub fn maxInitcodeSize(spec: Revision) usize {
        if (!spec.isImpl(.shanghai)) return std.math.maxInt(usize);
        return if (spec.isImpl(.amsterdam)) amsterdam_max_initcode_size else max_initcode_size;
    }

    pub fn intrinsicBaseGas(spec: Revision, options: tx_gas.IntrinsicGasOptions) ?u64 {
        if (!spec.isImpl(.amsterdam)) return 21_000;

        var gas: u64 = amsterdam_tx_base_cost;
        if (options.is_create) {
            gas = std.math.add(u64, gas, amsterdam_create_access_cost) catch return null;
        } else if (!options.is_self_transfer) {
            gas = std.math.add(u64, gas, amsterdam_cold_account_access_cost) catch return null;
        }

        if (options.value != 0 and !options.is_self_transfer) {
            gas = std.math.add(u64, gas, amsterdam_transfer_log_cost) catch return null;
            if (!options.is_create) {
                gas = std.math.add(u64, gas, amsterdam_tx_value_cost) catch return null;
            }
        }
        return gas;
    }

    pub fn createIntrinsicGas(spec: Revision) ?u64 {
        if (!spec.isImpl(.homestead) or spec.isImpl(.amsterdam)) return 0;
        return create_transaction_gas;
    }

    pub fn dataByteGas(spec: Revision, byte: u8) u64 {
        if (byte == 0) return 4;
        return if (spec.isImpl(.istanbul)) 16 else 68;
    }

    pub fn accessListAddressGas(spec: Revision) u64 {
        return if (spec.isImpl(.amsterdam)) amsterdam_access_list_address_gas else access_list_address_gas;
    }

    pub fn storageKeyGas(spec: Revision) u64 {
        return if (spec.isImpl(.amsterdam)) amsterdam_access_list_storage_key_gas else access_list_storage_key_gas;
    }

    pub fn accessListDataGas(spec: Revision, counts: tx_gas.AccessListCounts) ?u64 {
        if (!spec.isImpl(.amsterdam)) return 0;
        return accessListDataCost(counts);
    }

    pub fn initCodeWordGas(spec: Revision) u64 {
        return if (spec.isImpl(.shanghai)) initcode_word_gas else 0;
    }

    pub fn authorizationIntrinsicGas(spec: Revision) u64 {
        if (!spec.isImpl(.prague)) return 0;
        if (spec.isImpl(.amsterdam)) return amsterdam_account_write_cost + amsterdam_regular_per_auth_base_cost;
        return authorization_intrinsic_gas;
    }

    pub fn intrinsicStateGas(spec: Revision, options: tx_gas.IntrinsicGasOptions) ?u64 {
        if (!spec.isImpl(.amsterdam)) return 0;

        var gas: u64 = 0;
        if (options.is_create) {
            gas = std.math.add(u64, gas, amsterdam_new_account_state_gas) catch return null;
        }
        const auth_count = std.math.cast(u64, options.authorization_count) orelse return null;
        gas = std.math.add(u64, gas, std.math.mul(u64, auth_count, amsterdam_authorization_state_gas) catch return null) catch return null;
        return gas;
    }

    pub fn floorGas(spec: Revision, input: []const u8, options: tx_gas.IntrinsicGasOptions) ?u64 {
        if (!spec.isImpl(.prague)) return null;
        const floor_data_cost = if (spec.isImpl(.amsterdam)) blk: {
            const bytes = std.math.cast(u64, input.len) orelse return null;
            const floor_tokens = std.math.mul(u64, bytes, 4) catch return null;
            break :blk std.math.mul(u64, floor_tokens, 16) catch return null;
        } else blk: {
            const tokens = calldataTokenCount(input) orelse return null;
            break :blk std.math.mul(u64, tokens, 10) catch return null;
        };
        const floor_base_gas = if (spec.isImpl(.amsterdam)) amsterdam_tx_base_cost else 21_000;
        var gas = std.math.add(u64, floor_base_gas, floor_data_cost) catch return null;
        if (spec.isImpl(.amsterdam)) {
            gas = std.math.add(u64, gas, accessListDataCost(options.access_list_counts) orelse return null) catch return null;
        }
        return gas;
    }

    pub fn regularGasLimit(spec: Revision, gas_limit: u64) u64 {
        return if (spec.isImpl(.osaka)) @min(gas_limit, max_transaction_gas_limit) else gas_limit;
    }

    pub fn intrinsicRegularGasLimit(spec: Revision) ?u64 {
        return if (spec.isImpl(.amsterdam)) max_transaction_gas_limit else null;
    }

    pub fn totalGasLimit(spec: Revision) ?u64 {
        return if (spec.isImpl(.osaka) and !spec.isImpl(.amsterdam)) max_transaction_gas_limit else null;
    }
};

pub fn calldataTokenCount(input: []const u8) ?u64 {
    var tokens: u64 = 0;
    for (input) |byte| {
        const byte_tokens: u64 = if (byte == 0) 1 else 4;
        tokens = std.math.add(u64, tokens, byte_tokens) catch return null;
    }
    return tokens;
}

pub fn accessListDataCost(counts: tx.AccessListCounts) ?u64 {
    const address_count = std.math.cast(u64, counts.addresses) orelse return null;
    const storage_key_count = std.math.cast(u64, counts.storage_keys) orelse return null;
    const address_cost = std.math.mul(u64, address_count, access_list_address_data_gas) catch return null;
    const storage_key_cost = std.math.mul(u64, storage_key_count, access_list_storage_key_data_gas) catch return null;
    return std.math.add(u64, address_cost, storage_key_cost) catch return null;
}
