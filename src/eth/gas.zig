//! Legacy gas-schedule values that no EIP tabulates.
//!
//! These predate named EIP parameter tables, so they have no `eip/` home; EIPs
//! that reprice them do so from their own table. Anything an EIP tabulates
//! belongs in `eip/`, not here.

/// G_transaction: base cost charged to every transaction.
pub const transaction_cost: u64 = 21_000;

/// G_txdatazero: per zero byte of calldata.
pub const tx_data_zero_cost: u64 = 4;

/// G_txdatanonzero: per non-zero byte of calldata.
pub const tx_data_nonzero_cost: u64 = 68;

/// EIP-2028's reprice of `tx_data_nonzero_cost`.
/// the cost only as `GTXDATANONZERO`, in prose.
pub const eip2028_tx_data_nonzero_cost: u64 = 16;

/// G_callstipend: gas handed to a value-bearing CALL so the callee can log.
pub const call_stipend: u64 = 2_300;

/// G_newaccount: charged when an operation brings a new account into existence.
pub const account_creation_cost: i64 = 25_000;

/// G_codedeposit, per runtime byte. Amsterdam reprices it per word through
/// [EIP-8037](eip/8037.zig).
pub const code_deposit_byte_cost: i64 = 200;
