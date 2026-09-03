//! Transaction-scope gas constants and intrinsic-gas helpers.
//!
//! Values an EIP tabulates live in `eip/`; read them from there rather than
//! re-exporting under a second name. A fork prefix here means the value varies
//! per fork within one parameter, not which fork adopted a table.

const std = @import("std");
const eip7623 = @import("eip/7623.zig");
const tx = @import("../transaction/types.zig");
const tx_gas = @import("../transaction/gas.zig");

pub const gas_per_blob: u64 = 131_072;
pub const min_base_fee_per_blob_gas: u256 = 1;
pub const blob_base_cost: u64 = 8_192;
pub const cancun_blob_base_fee_update_fraction: u256 = 3_338_477;
pub const prague_blob_base_fee_update_fraction: u256 = 5_007_716;
pub const amsterdam_blob_base_fee_update_fraction: u256 = 11_684_671;

pub const access_list_address_cost: u64 = 2_400;
pub const access_list_storage_key_cost: u64 = 1_900;
pub const access_list_address_data_gas: u64 = 1_280;
pub const access_list_storage_key_data_gas: u64 = 2_048;
pub const create_transaction_gas: u64 = 32_000;
pub const initcode_word_cost: u64 = 2;
pub const max_initcode_size: usize = 49_152;

/// Compute EIP-7623 calldata token total.
pub fn calldataTokenCount(input: []const u8) error{Overflow}!u64 {
    const zero_count = tx_gas.countZeroBytes(input);
    const total = std.math.cast(u64, input.len) orelse return error.Overflow;
    const nonzero_tokens = try std.math.mul(
        u64,
        total - zero_count,
        eip7623.tokens_per_nonzero_byte,
    );
    return std.math.add(u64, zero_count, nonzero_tokens);
}

pub fn accessListDataCost(counts: tx.AccessListCounts) error{Overflow}!u64 {
    const address_count = std.math.cast(u64, counts.addresses) orelse return error.Overflow;
    const storage_key_count = std.math.cast(u64, counts.storage_keys) orelse
        return error.Overflow;
    const address_cost = try std.math.mul(
        u64,
        address_count,
        access_list_address_data_gas,
    );
    const storage_key_cost = try std.math.mul(
        u64,
        storage_key_count,
        access_list_storage_key_data_gas,
    );
    return std.math.add(u64, address_cost, storage_key_cost);
}
