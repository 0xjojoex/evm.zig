//! Canonical account metadata cached by the executor overlay.
//!
//! Code bytes are content-addressed by `code_hash`; storage is addressed by
//! account and slot. Neither belongs inside this value.
//!
//! Two different questions about "nothing here" run through the state layers,
//! and they do not agree. Keeping them apart is load-bearing:
//!
//!   - **EIP-161 empty / dead** - zero nonce, zero balance, empty code, with
//!     storage deliberately ignored. Drives account existence, `EXTCODEHASH`
//!     (EIP-1052), and the CALL and SELFDESTRUCT new-account charge, which
//!     EIP-161 levies against a *dead* destination. `TrackedState` resolves
//!     such an account to absent on every fork past Spurious Dragon; see
//!     `Spec.retains_empty_accounts`.
//!   - **No state at all** - additionally requires an empty storage root, and
//!     is what decides whether the trie stores a leaf. See
//!     `trie.Account.hasNoState` and `MemoryStore.EmptyAccountPolicy`.
//!
//! The gap between them is exactly the EIP-7610 residue: an account with
//! storage but no nonce, balance, or code is dead for every execution query
//! yet still owns a trie leaf, so `createCollision` must refuse to build over
//! it even though reads report it absent.

const crypto = @import("../crypto.zig");

nonce: u64 = 0,
balance: u256 = 0,
code_hash: [32]u8 = crypto.keccak256_empty,
