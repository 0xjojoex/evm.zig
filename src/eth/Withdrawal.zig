//! Ethereum execution-layer withdrawal.

const Address = @import("../address.zig").Address;

index: u64,
validator_index: u64,
address: Address,
amount: u64,
