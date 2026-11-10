//! EIP-8141 frame transaction parameters.
//!
//! Constants mirror the EIP's tables; `params` assembles them for
//! `TransactionSpec.frame`. Fork gating stays in exact spec assembly.

const address = @import("../../address.zig");
const frames = @import("../../transaction/frames.zig");
const eip7825 = @import("7825.zig");
const eip7976 = @import("7976.zig");
const eip7623 = @import("7623.zig");
const eip8037 = @import("8037.zig");

// FRAME_TX_TYPE is `transaction.type_id.frame`.
/// FRAME_TX_INTRINSIC_COST.
pub const intrinsic_cost: u64 = 12_000;
/// FRAME_TX_PER_FRAME_COST.
pub const per_frame_cost: u64 = 475;
/// ENTRY_POINT.
pub const entry_point = address.addr(0xaa);
/// EXPIRY_VERIFIER, an ordinary contract deployed by a keyless transaction.
pub const expiry_verifier = address.addr("0x81413f0cF12e9b6a49B1D0439E081c577D57FfFf");
/// EXPIRY_DATA_LENGTH.
pub const expiry_data_length: usize = 8;
/// MAX_FRAMES.
pub const max_frames: u8 = 64;

/// Signature verification gas by scheme.
pub const arbitrary_signature_cost: u64 = 100;
pub const secp256k1_signature_cost: u64 = 2_800;
pub const p256_signature_cost: u64 = 6_700;

pub const params: frames.Params = .{
    .intrinsic_gas = intrinsic_cost,
    .per_frame_gas = per_frame_cost,
    .value_transfer_gas = eip8037.tx_value_cost,
    .arbitrary_signature_gas = arbitrary_signature_cost,
    .secp256k1_signature_gas = secp256k1_signature_cost,
    .p256_signature_gas = p256_signature_cost,
    .standard_token_gas = eip7623.standard_token_cost,
    .floor_token_gas = eip7976.total_cost_floor_per_token,
    .max_frames = max_frames,
    .max_execution_gas = eip7825.max_transaction_gas_limit,
    .sender_account_state_gas = eip8037.new_account_state_gas,
    .entry_point = entry_point,
    .expiry_verifier = expiry_verifier,
    .expiry_data_len = expiry_data_length,
};
