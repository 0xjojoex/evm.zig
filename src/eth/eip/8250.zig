//! EIP-8250 keyed nonces for frame transactions.
//!
//! Constants mirror the EIP's table; `params` extends EIP-8141's frame
//! parameters with them for `TransactionSpec.frame`.

const address = @import("../../address.zig");
const frames = @import("../../transaction/frames.zig");
const eip8037 = @import("8037.zig");
const eip8038 = @import("8038.zig");
const eip8141 = @import("8141.zig");

/// NONCE_MANAGER, an ordinary contract deployed by a keyless transaction.
pub const nonce_manager = address.addr("0x8250968C12e01A19d6F667b9B2F3b3A4d0e51cB7");
/// MAX_NONCE_KEYS.
pub const max_nonce_keys: u8 = 16;
/// KEYED_NONCE_ACCESS_COST: COLD_STORAGE_ACCESS + STORAGE_WRITE.
pub const keyed_nonce_access_cost: u64 = eip8038.cold_storage_access_cost + eip8038.storage_write_cost;
/// KEYED_NONCE_FIRST_USE_STATE_GAS: STATE_BYTES_PER_STORAGE_SET * CPSB.
pub const keyed_nonce_first_use_state_gas: u64 = eip8037.storage_set_state_gas;

pub const params: frames.Params = blk: {
    var value = eip8141.params;
    value.keyed_nonces = .{
        .nonce_manager = nonce_manager,
        .max_keys = max_nonce_keys,
        .access_gas = keyed_nonce_access_cost,
        .first_use_state_gas = keyed_nonce_first_use_state_gas,
    };
    break :blk value;
};
