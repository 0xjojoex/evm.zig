//! EIP-7623 calldata cost floor.
//!
//! A transaction pays the greater of its standard cost and a per-token floor,
//! so calldata-heavy transactions cannot be priced below the space they take.

/// STANDARD_TOKEN_COST: gas per calldata token on the standard path.
///
/// The legacy byte costs are exactly this times the token weights:
/// a zero byte is 1 token (4 gas), a non-zero byte 4 tokens (16 gas).
pub const standard_token_cost: u64 = 4;

/// TOTAL_COST_FLOOR_PER_TOKEN: gas per calldata token on the floor path.
/// [EIP-7976](7976.zig) raises this.
pub const total_cost_floor_per_token: u64 = 10;

/// Tokens charged for one non-zero calldata byte; a zero byte counts as one.
/// From `tokens_in_calldata = zero_bytes_in_calldata + nonzero_bytes_in_calldata * 4`.
pub const tokens_per_nonzero_byte: u64 = 4;
