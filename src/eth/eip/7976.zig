//! EIP-7976 raise of the [EIP-7623](7623.zig) calldata floor.

const eip7623 = @import("7623.zig");

/// TOTAL_COST_FLOOR_PER_TOKEN, raised from EIP-7623's 10.
pub const total_cost_floor_per_token: u64 = 16;

/// Floor cost of one non-zero calldata byte. The EIP states this outright:
/// "TOTAL_COST_FLOOR_PER_TOKEN * 4 = 64".
pub const floor_cost_per_nonzero_byte: u64 = total_cost_floor_per_token * eip7623.tokens_per_nonzero_byte;
