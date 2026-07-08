//! EIP-8037 parameters for state-creation gas.
//!
//! The EIP separates gas into regular-gas and state-gas. Constants in this file
//! mirror the spec's "New parameters" and "Parameter changes" tables; fork
//! gating stays in the protocol modules.

const eip7702 = @import("7702.zig");

// New parameters: state byte pricing and sizing.
/// CPSB in the EIP: gas charged for each net-new state byte.
pub const cost_per_state_byte: u64 = 1_530;

/// Account leaf size used for CREATE, value transfer, SELFDESTRUCT, and EIP-7702 account creation.
pub const state_bytes_per_new_account: u64 = 120;
/// Storage slot size used when SSTORE creates a new slot.
pub const state_bytes_per_storage_set: u64 = 64;
/// Maximum SSTORE count assumed for an EIP-8037 Amsterdam system call.
pub const system_max_sstores_per_call: u64 = 16;

// Regular-gas companion costs for operations that also create state. The EIP
// notes ACCOUNT_WRITE, CREATE_ACCESS, and COLD_ACCOUNT_ACCESS come from EIP-8038.
/// Regular gas for writing an account leaf while handling delegation or account updates.
pub const account_write_cost: u64 = 8_000;
/// Regular gas for writing a storage slot; state growth is charged separately as state-gas.
pub const storage_write_cost: u64 = 10_000;
/// Regular-gas refund when a storage write clears a slot under the Amsterdam gas table.
pub const storage_clear_refund: u64 = 12_480;
/// Cold storage access cost used by Amsterdam SLOAD/SSTORE accounting.
pub const cold_storage_access_cost: u64 = 3_000;
/// Cold account access cost used by EIP-8037 through the Amsterdam/EIP-8038 gas table.
pub const cold_account_access_cost: u64 = 3_000;
/// Regular CREATE/CREATE2 access cost; new-account bytes are charged as state-gas.
pub const create_access_cost: u64 = 11_000;

/// Amsterdam transaction base cost before calldata, access list, authorization, or create costs.
pub const tx_base_cost: u64 = 12_000;
/// Extra regular gas for a value-bearing top-level transaction.
pub const tx_value_cost: u64 = 4_244;
/// Regular gas for the value-transfer log emitted by Amsterdam value transfers.
pub const transfer_log_cost: u64 = 1_756;
/// Regular code-deposit hash cost per 32-byte word; code bytes themselves are state-gas.
pub const code_deposit_word_cost: u64 = 6;
/// Regular part of each EIP-7702 authorization tuple beyond the state-gas byte charge.
pub const regular_per_auth_base_cost: u64 = 7_816;

// State-gas costs are byte-count parameters multiplied by CPSB.
/// State-gas charged when an operation creates a new account leaf.
pub const new_account_state_gas: u64 = state_bytes_per_new_account * cost_per_state_byte;
/// State-gas charged for a new EIP-7702 delegation indicator.
pub const auth_base_state_gas: u64 = eip7702.delegation_indicator_state_bytes * cost_per_state_byte;
/// State-gas charged when SSTORE creates a new storage slot.
pub const storage_set_state_gas: u64 = state_bytes_per_storage_set * cost_per_state_byte;
/// Worst-case state-gas for one EIP-7702 authorization.
pub const authorization_state_gas: u64 = new_account_state_gas + auth_base_state_gas;
/// Full intrinsic gas for one Amsterdam authorization: regular companion cost plus state-gas.
pub const authorization_intrinsic_gas: u64 =
    account_write_cost +
    regular_per_auth_base_cost +
    authorization_state_gas;

/// Amsterdam access-list address cost; access-list byte data is accounted separately.
pub const access_list_address_gas: u64 = 3_000;
/// Amsterdam access-list storage-key cost; access-list byte data is accounted separately.
pub const access_list_storage_key_gas: u64 = 3_000;

pub const call_stipend: u64 = 2_300;
/// Amsterdam CALL value cost: regular account-write cost plus the legacy stipend.
pub const call_value_cost: u64 = account_write_cost + call_stipend;

// EIP-7825's transaction gas cap bounds regular gas; EIP-8037 lets state-gas
// use the reservoir above this cap while still bounded by tx.gas.
/// Amsterdam raises the initcode size bound so larger deployments can use the state-gas reservoir.
pub const max_initcode_size: usize = 131_072;
/// TX_MAX_GAS_LIMIT: cap for regular-gas contribution, not total tx.gas after EIP-8037.
pub const max_transaction_gas_limit: u64 = 16_777_216;
