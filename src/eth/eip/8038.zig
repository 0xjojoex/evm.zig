//! EIP-8038 repricing of state access and write gas.
//!
//! The EIP splits an operation's cost into up to three independent components —
//! Access, Write, and state creation — and reprices the first two. State
//! creation is [EIP-8037](8037.zig)'s half; the two ship together for Amsterdam.
//!
//! Constants mirror the EIP's parameter table. Its spelling drops the `_COST`
//! suffix on several entries (`COLD_ACCOUNT_ACCESS`, `ACCOUNT_WRITE`,
//! `STORAGE_WRITE`, `CREATE_ACCESS`, `CALL_VALUE`); the catalog keeps `_cost`
//! here so the Berlin counterparts in [2929](2929.zig) stay greppable as pairs.
//!
//! Values track the EEST fixtures the repo pins, not the published draft — the
//! EIP is in Review and still moving.

const gas = @import("../gas.zig");

// Access component. WARM_ACCESS is unchanged from EIP-2929's
// WARM_STORAGE_READ_COST, so it stays owned by `2929.zig`.
/// COLD_ACCOUNT_ACCESS: cold account touch, up from EIP-2929's 2 600.
pub const cold_account_access_cost: u64 = 3_000;

/// COLD_STORAGE_ACCESS: cold SLOAD/SSTORE slot touch.
pub const cold_storage_access_cost: u64 = 3_000;

// Write component.
/// ACCOUNT_WRITE: writing an account leaf, for value transfer, SELFDESTRUCT,
/// CREATE, and EIP-7702 delegation.
pub const account_write_cost: u64 = 8_000;

/// STORAGE_WRITE: writing a storage slot. State growth is charged separately
/// as EIP-8037 state-gas.
pub const storage_write_cost: u64 = 10_000;

/// STORAGE_CLEAR_REFUND: refund when a storage write clears a slot.
pub const storage_clear_refund: u64 = 12_480;

/// CREATE_ACCESS: combined access and write cost for CREATE/CREATE2 and
/// contract-creation transactions; new-account bytes are state-gas.
pub const create_access_cost: u64 = 11_000;

// Prepaid access, charged from the transaction access list.
/// ACCESS_LIST_ADDRESS_COST, up from EIP-2930's 2 400.
pub const access_list_address_cost: u64 = 3_000;

/// ACCESS_LIST_STORAGE_KEY_COST, up from EIP-2930's 1 900.
pub const access_list_storage_key_cost: u64 = 3_000;

/// CALL_VALUE, redefined by the EIP as `ACCOUNT_WRITE + CALL_STIPEND`.
pub const call_value_cost: u64 = account_write_cost + gas.call_stipend;
