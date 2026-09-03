//! Canonical account metadata cached by the executor overlay.
//!
//! Code bytes are content-addressed by `code_hash`; storage is addressed by
//! account and slot. Neither belongs inside this value.
//!
//! Two different questions about "nothing here" run through the state layers:
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
//! A storage-only account is therefore dead for execution queries while still
//! owning a trie leaf.

const std = @import("std");

const crypto = @import("../crypto.zig");

const Account = @This();

nonce: u64 = 0,
balance: u256 = 0,
code_hash: [32]u8 = crypto.keccak256_empty,

/// EIP-161 emptiness: nonce, balance, and code only.
///
/// Storage is excluded on purpose, unlike `trie.Account.hasNoState`.
///
/// This is the value half only. Whether an empty account is *dropped* is a fork
/// question owned by the state lanes; see `Spec.retains_empty_accounts`.
pub fn isEip161Empty(self: Account) bool {
    return self.nonce == 0 and
        self.balance == 0 and
        std.mem.eql(u8, &self.code_hash, &crypto.keccak256_empty);
}

test "EIP-161 emptiness ignores storage and tracks each field" {
    try std.testing.expect((Account{}).isEip161Empty());
    try std.testing.expect(!(Account{ .nonce = 1 }).isEip161Empty());
    try std.testing.expect(!(Account{ .balance = 1 }).isEip161Empty());
    try std.testing.expect(!(Account{ .code_hash = [_]u8{0xaa} ** 32 }).isEip161Empty());
}
