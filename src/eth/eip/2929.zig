//! EIP-2929 gas repricing for state-access opcodes.
//!
//! Constants mirror the EIP's parameter table; fork gating stays in exact spec
//! assembly. Amsterdam replaces this table wholesale through [8037](8037.zig).
//!
//! Values are `i64` because every consumer is instruction gas, which this
//! engine accounts as signed.

/// COLD_SLOAD_COST: total cost of reading a cold storage slot.
pub const cold_sload_cost: i64 = 2_100;

/// COLD_ACCOUNT_ACCESS_COST: total cost of touching a cold account.
pub const cold_account_access_cost: i64 = 2_600;

/// WARM_STORAGE_READ_COST: the repriced static gas of the access opcodes, so a
/// warm access is fully paid before the instruction body runs.
pub const warm_storage_read_cost: i64 = 100;

/// Cold storage surcharge left to charge once the warm static gas is paid.
pub const cold_sload_surcharge: i64 = cold_sload_cost - warm_storage_read_cost;

/// Cold account surcharge left to charge once the warm static gas is paid.
pub const cold_account_access_surcharge: i64 = cold_account_access_cost - warm_storage_read_cost;
