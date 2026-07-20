//! Shared semantic values exchanged by Definition hooks and runtime code.
//!
//! Implementer-facing hook semantics and neutral defaults live in
//! `definition.zig`; comptime shape diagnostics live in `validate.zig`.
//! Named hook inputs keep function signatures stable as semantics grow;
//! additive fields must therefore carry neutral defaults.

const std = @import("std");

const Address = @import("../address.zig").Address;

pub const SelfDestructPolicy = struct {
    clear_balance: bool,
    reset_nonce: bool,
    mark_selfdestructed: bool,
};

pub const SelfDestructFinalization = struct {
    delete_account: bool = false,
    clear_storage: bool = false,
    reset_account: bool = false,
};

pub const CallNewAccountGas = struct {
    regular: i64 = 0,
    state: i64 = 0,
};

pub const AccountAccessStatus = enum {
    cold,
    warm,
};

pub const StorageStatus = enum {
    assigned,
    added,
    deleted,
    modified,
    deleted_added,
    modified_deleted,
    deleted_restored,
    added_deleted,
    modified_restored,
};

pub const StorageGas = struct {
    cost: i64 = 0,
    refund: i64 = 0,
};

pub const StorageStateGas = struct {
    charge: i64 = 0,
    refund: i64 = 0,
};

pub const ValueTransferLog = struct {
    address: Address,
    topic: u256,
};

/// One successful value movement after state balances have been updated.
pub const ValueTransferInput = struct {
    from: Address,
    to: Address,
    amount: u256,
};

/// State observed while applying one successful authorization tuple.
pub const AuthorizationSuccessInput = struct {
    /// Whether the authority account existed before this tuple was applied.
    account_exists: bool,
    /// Whether this transaction has already paid to write the authority leaf.
    account_already_written: bool,
    /// Whether this tuple removes, rather than installs, delegation code.
    clears_delegation: bool,
    /// Whether the authority was delegated before transaction execution began.
    delegated_before_transaction: bool,
    /// Whether an earlier tuple installed a delegation for this authority.
    delegation_set_before: bool,
};

/// Facts deciding whether CALL charges for materializing its recipient.
pub const CallNewAccountInput = struct {
    value: u256,
    /// Actual recipient existence observed before the call.
    account_exists: bool,
};

/// Facts deciding whether CREATE charges for materializing its derived target.
pub const CreateAccountStateGasInput = struct {
    /// Whether the derived target is alive before creation begins.
    target_alive: bool,
};

/// Facts deciding top-frame value-transfer state gas.
pub const TopFrameValueTransferInput = struct {
    value: u256,
    same_address: bool,
    /// Whether this transfer will materialize a previously absent recipient.
    creates_account: bool,
};

/// Engine state observed before following top-level delegation code.
pub const TopLevelDelegatedAccountAccessInput = struct {
    target_is_precompile: bool,
    already_warm: bool,
};

/// Gas available when deriving one child-frame grant.
pub const ChildGasInput = struct {
    requested: i64,
    available: i64,
};

/// Transaction-local facts controlling immediate SELFDESTRUCT effects.
pub const SelfDestructPolicyInput = struct {
    same_address: bool,
    created_in_transaction: bool,
};

/// Facts deciding whether SELFDESTRUCT charges for its beneficiary account.
pub const SelfDestructNewAccountInput = struct {
    same_address: bool,
    transfers_balance: bool,
    /// Actual beneficiary existence observed before SELFDESTRUCT.
    account_exists: bool,
};

/// Protocol-visible facts available before payload execution begins.
pub const BeforeBlockContext = struct {
    number: u64,
    timestamp: u64,
    parent_hash: ?[32]u8 = null,
    parent_beacon_block_root: ?[32]u8 = null,
};

/// Input owned by, or safely borrowed into, a block lifecycle plan.
///
/// `word` keeps header-derived values inline so a returned plan never borrows
/// from a temporary hook context. `bytes` is for static or caller-owned input.
pub const BlockHookInput = union(enum) {
    none,
    word: [32]u8,
    bytes: []const u8,

    pub fn slice(self: *const BlockHookInput) []const u8 {
        return switch (self.*) {
            .none => &.{},
            .word => |*word| word,
            .bytes => |bytes| bytes,
        };
    }
};

/// One definition-owned system call at a named block lifecycle phase.
pub const BlockSystemCall = struct {
    sender: Address,
    recipient: Address,
    input: BlockHookInput = .none,
    gas: u64,
    require_code: bool = false,
};

pub const BlockSystemCalls = struct {
    pub const capacity = 4;

    items: [capacity]BlockSystemCall = undefined,
    len: usize = 0,

    pub fn append(self: *BlockSystemCalls, call: BlockSystemCall) void {
        std.debug.assert(self.len < capacity);
        self.items[self.len] = call;
        self.len += 1;
    }

    pub fn slice(self: *const BlockSystemCalls) []const BlockSystemCall {
        return self.items[0..self.len];
    }
};

/// Facts available before an accepted payload transaction executes.
pub const BeforeTransactionContext = struct {
    number: u64,
    timestamp: u64,
    transaction_index: u64,
};

pub const BlockTransactionStatus = enum {
    success,
    revert,
    invalid,
    out_of_gas,
};

/// Execution facts available after the caller has consumed transaction logs.
pub const AfterTransactionContext = struct {
    number: u64,
    timestamp: u64,
    transaction_index: u64,
    status: BlockTransactionStatus,
    gas_used: u64,
    cumulative_gas_used: u64,
    cumulative_block_gas: u64,
    cumulative_state_gas: u64,
};

/// Protocol-visible facts available after payload and family-owned block
/// actions (for example withdrawals) have completed.
pub const FinalizeBlockContext = struct {
    number: u64,
    timestamp: u64,
    transaction_count: u64,
    gas_used: u64,
    block_gas: u64,
    state_gas: u64,
};

/// A finalization system call whose non-empty output is prefixed and returned
/// to the family STF. Ethereum uses the prefix as its EIP-7685 request type.
pub const FinalizeSystemCall = struct {
    call: BlockSystemCall,
    output_prefix: u8,
};

pub const FinalizeSystemCalls = struct {
    pub const capacity = 4;

    items: [capacity]FinalizeSystemCall = undefined,
    len: usize = 0,

    pub fn append(self: *FinalizeSystemCalls, call: FinalizeSystemCall) void {
        std.debug.assert(self.len < capacity);
        self.items[self.len] = call;
        self.len += 1;
    }

    pub fn slice(self: *const FinalizeSystemCalls) []const FinalizeSystemCall {
        return self.items[0..self.len];
    }
};

pub const DelegatedAccountAccess = struct {
    status: AccountAccessStatus,
    gas: i64 = 0,
};

pub const AuthorizationGasAdjustment = struct {
    /// State gas charged before writing a newly-created authority account.
    account_state_charge: u64 = 0,
    /// Regular gas charged for the transaction's first authority-leaf write.
    account_write_charge: u64 = 0,
    /// State gas charged for the transaction's first new delegation indicator.
    delegation_state_charge: u64 = 0,
    /// Legacy regular-gas refund retained for pre-Amsterdam authorization rules.
    regular_refund: u64 = 0,

    pub fn add(self: *AuthorizationGasAdjustment, other: AuthorizationGasAdjustment) void {
        self.account_state_charge = std.math.add(u64, self.account_state_charge, other.account_state_charge) catch std.math.maxInt(u64);
        self.account_write_charge = std.math.add(u64, self.account_write_charge, other.account_write_charge) catch std.math.maxInt(u64);
        self.delegation_state_charge = std.math.add(u64, self.delegation_state_charge, other.delegation_state_charge) catch std.math.maxInt(u64);
        self.regular_refund = std.math.add(u64, self.regular_refund, other.regular_refund) catch std.math.maxInt(u64);
    }
};

pub const ChildGas = struct {
    gas: i64,
    out_of_gas: bool = false,
};

test "block hook collections preserve insertion order" {
    const first = [_]u8{0x11} ** 20;
    const second = [_]u8{0x22} ** 20;
    var calls = BlockSystemCalls{};
    calls.append(.{ .sender = first, .recipient = second, .gas = 7 });

    try std.testing.expectEqual(@as(usize, 1), calls.slice().len);
    try std.testing.expectEqual(first, calls.slice()[0].sender);
    try std.testing.expectEqual(second, calls.slice()[0].recipient);
}
