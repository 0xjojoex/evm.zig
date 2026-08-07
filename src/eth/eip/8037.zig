//! EIP-8037 parameters for state-creation gas.
//!
//! The EIP separates gas into regular-gas and state-gas. Constants in this file
//! mirror the spec's "New parameters" and "Parameter changes" tables; fork
//! gating stays in exact spec assembly.

const delegation = @import("../../code/eip7702.zig");

// New parameters: state byte pricing and sizing.
/// CPSB in the EIP: gas charged for each net-new state byte.
pub const cost_per_state_byte: u64 = 1_530;

/// Account leaf size used for CREATE, value transfer, SELFDESTRUCT, and EIP-7702 account creation.
pub const state_bytes_per_new_account: u64 = 120;

/// Storage slot size used when SSTORE creates a new slot.
pub const state_bytes_per_storage_set: u64 = 64;

/// Maximum SSTORE count assumed for an EIP-8037 Amsterdam system call.
pub const system_max_sstores_per_call: u64 = 16;

/// Amsterdam transaction base cost before calldata, access list, authorization, or create costs.
pub const tx_base_cost: u64 = 12_000;

/// Extra regular gas for a non-CREATE, non-self top-level value transfer.
pub const tx_value_cost: u64 = 6_000;

/// Regular code-deposit hash cost per 32-byte word; code bytes themselves are state-gas.
pub const code_deposit_word_cost: u64 = 6;

/// Regular part of each EIP-7702 authorization tuple beyond the state-gas byte charge.
pub const regular_per_auth_base_cost: u64 = 7_816;

// State-gas costs are byte-count parameters multiplied by CPSB.
/// State-gas charged when an operation creates a new account leaf.
pub const new_account_state_gas: u64 = state_bytes_per_new_account * cost_per_state_byte;

/// State-gas charged for a new EIP-7702 delegation indicator.
pub const auth_base_state_gas: u64 = delegation.delegation_indicator_state_bytes * cost_per_state_byte;

/// State-gas charged when SSTORE creates a new storage slot.
pub const storage_set_state_gas: u64 = state_bytes_per_storage_set * cost_per_state_byte;

/// Worst-case state-gas for one EIP-7702 authorization.
pub const authorization_state_gas: u64 = new_account_state_gas + auth_base_state_gas;

// [EIP-7825](7825.zig)'s transaction gas cap bounds regular gas from here on;
// EIP-8037 lets state-gas use the reservoir above that cap, still bounded by
// tx.gas. The cap's value is unchanged, so it stays owned by 7825.
/// Amsterdam raises the initcode size bound so larger deployments can use the state-gas reservoir.
pub const max_initcode_size: usize = 131_072;
