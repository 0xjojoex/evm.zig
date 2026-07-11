//! Canonical account metadata cached by the executor overlay.
//!
//! Code bytes are content-addressed by `code_hash`; storage is addressed by
//! account and slot. Neither belongs inside this value.

const crypto = @import("../crypto.zig");

nonce: u64 = 0,
balance: u256 = 0,
code_hash: [32]u8 = crypto.keccak256_empty,
