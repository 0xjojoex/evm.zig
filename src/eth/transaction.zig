const std = @import("std");
const authorization = @import("../transaction/authorization.zig");
const tx = @import("../transaction/types.zig");
const tx_gas = @import("../transaction/gas.zig");
const eip8037 = @import("eip/8037.zig");

pub const blob_gas_per_blob: u64 = 131_072;
pub const min_blob_base_fee: u256 = 1;
pub const blob_base_cost: u64 = 8_192;
pub const cancun_blob_base_fee_update_fraction: u256 = 3_338_477;
pub const prague_blob_base_fee_update_fraction: u256 = 5_007_716;
pub const amsterdam_blob_base_fee_update_fraction: u256 = 11_684_671;

pub const authorization_intrinsic_gas = authorization.empty_account_cost;
pub const authorization_existing_account_refund_gas = authorization.existing_account_refund_gas;
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

/// Compute EIP-7623 calldata token total.
pub fn calldataTokenCount(input: []const u8) ?u64 {
    const zero_count = tx_gas.countZeroBytes(input);
    const total = std.math.cast(u64, input.len) orelse return null;
    const nonzero_tokens = std.math.mul(u64, total - zero_count, 4) catch return null;
    return std.math.add(u64, zero_count, nonzero_tokens) catch null;
}

pub fn accessListDataCost(counts: tx.AccessListCounts) ?u64 {
    const address_count = std.math.cast(u64, counts.addresses) orelse return null;
    const storage_key_count = std.math.cast(u64, counts.storage_keys) orelse return null;
    const address_cost = std.math.mul(u64, address_count, access_list_address_data_gas) catch return null;
    const storage_key_cost = std.math.mul(u64, storage_key_count, access_list_storage_key_data_gas) catch return null;
    return std.math.add(u64, address_cost, storage_key_cost) catch null;
}
