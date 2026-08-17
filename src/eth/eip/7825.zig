//! EIP-7825 transaction gas limit cap.

/// TX_MAX_GAS_LIMIT: 2^24, the per-transaction gas ceiling from Osaka on.
/// [8037](8037.zig) narrows what this bounds — regular gas rather than
/// `tx.gas` — without changing the value.
pub const max_transaction_gas_limit: u64 = 16_777_216;
