//! Transaction value shapes, in Ethereum terms.
//!
//! One transaction flows through several representations. Keep them distinct:
//!
//!   raw bytes ─(transaction/envelope.zig)-> Transaction ─(prepare)->
//!     TransactionView ─> Prepared{scope, message} ─> EvmExecutionRequest

const std = @import("std");

const Address = @import("../address.zig").Address;
const execution = @import("../execution.zig");
const BlobSchedule = @import("./blob.zig").BlobSchedule;
const BlockGas = @import("./settlement.zig").BlockGas;
const ExecutionGas = execution.ExecutionGas;

pub const AccessListCounts = struct {
    addresses: usize = 0,
    storage_keys: usize = 0,
};

/// Normalized transaction envelope kind used by semantic validation.
/// This is not a fixture name or an encoded transaction byte; callers infer it
/// from their own transaction representation before calling `validate`.
pub const TxKind = enum {
    legacy,
    access_list,
    dynamic_fee,
    blob,
    set_code,
};

/// Sender-code category used by pre-execution transaction validation.
/// Delegation code is split from normal code so EIP-7702 senders can be
/// accepted while EIP-3607 still rejects non-delegating contract senders.
pub const SenderCodeKind = enum {
    empty,
    delegation,
    non_delegating,
};

pub const AccessListEntry = struct {
    address: Address,
    storage_keys: []const u256 = &.{},
};

pub const AuthorizationTuple = struct {
    chain_id: u256,
    target: Address,
    signer: Address,
    nonce: u64,
    y_parity: u256,
    legacy_v: ?u256,
    r: u256,
    s: u256,
};

pub const FeeFields = struct {
    gas_price: u256 = 0,
    max_fee_per_gas: ?u256 = null,
    max_priority_fee_per_gas: ?u256 = null,
    max_fee_per_blob_gas: ?u256 = null,
};

/// Unvalidated Ethereum-shaped ingress value used by Definition-backed `Vm`
/// types. Representation-changing families own a concrete facade above the
/// executor rather than replacing this engine transaction value.
pub const Transaction = struct {
    kind: TxKind = .legacy,
    sender: Address,
    /// Retain the encoded domain until Transaction validation classifies it.
    /// Account and executable nonces are `u64`; this wider input-only value lets
    /// an encoded nonce at or above the account limit receive the protocol
    /// rejection instead of being misclassified as a decode failure.
    nonce: ?u256 = null,
    gas_limit: u64,
    to: ?Address = null,
    value: u256 = 0,
    input: []const u8 = &.{},
    gas_price: u256 = 0,
    max_fee_per_gas: ?u256 = null,
    max_priority_fee_per_gas: ?u256 = null,
    max_fee_per_blob_gas: ?u256 = null,
    blob_hashes: []const u256 = &.{},
    access_list: []const AccessListEntry = &.{},
    authorization_list: []const AuthorizationTuple = &.{},
    authorization_count: ?usize = null,
};

/// Read-only projection of unvalidated transaction input. Wide nonce data must
/// not cross the Transaction validation boundary into `Prepared`.
pub const TransactionView = struct {
    kind: TxKind = .legacy,
    sender: Address,
    nonce: ?u256 = null,
    gas_limit: u64,
    to: ?Address = null,
    value: u256 = 0,
    input: []const u8 = &.{},
    access_list: []const AccessListEntry = &.{},
    authorization_list: []const AuthorizationTuple = &.{},
    authorization_count: usize = 0,
    fee: FeeFields = .{},
    blob_hashes: []const u256 = &.{},
};

pub const EnvFacts = struct {
    chain_id: u256 = 1,
    coinbase: Address,
    number: u64 = 0,
    slot_number: u64 = 0,
    timestamp: u64 = 0,
    gas_limit: u64 = 0,
    prev_randao: u256 = 0,
    base_fee: u256 = 0,
    blob_base_fee: u256 = 0,
    /// Optional dynamic chain/fixture override for blob gas rules.
    /// When null, transaction validation and settlement use the protocol schedule for the active revision.
    blob_schedule: ?BlobSchedule = null,
};

/// Minimal account proof consumed during protocol transaction preparation.
pub const PreparationAccount = struct {
    nonce: u64,
    balance: u256,
    code_hash: [32]u8,
};

/// Read-only state capability available to protocol transaction preparation.
///
/// Preparation controls when these reads happen. The VM supplies the current
/// overlay-backed view, but exposes neither storage nor mutation through this
/// boundary.
pub const PreparationStateAccess = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        accountSummary: *const fn (ptr: *anyopaque, address: Address) anyerror!?PreparationAccount,
        code: *const fn (ptr: *anyopaque, address: Address, expected_hash: [32]u8) anyerror![]const u8,
    };

    pub fn accountSummary(self: PreparationStateAccess, address: Address) !?PreparationAccount {
        return self.vtable.accountSummary(self.ptr, address);
    }

    /// Load code proven by `expected_hash`. Returned bytes are borrowed for the
    /// duration of preparation.
    pub fn code(self: PreparationStateAccess, address: Address, expected_hash: [32]u8) ![]const u8 {
        return self.vtable.code(self.ptr, address, expected_hash);
    }
};

/// Cumulative progress before the transaction currently being prepared.
pub const PreparationBlockProgress = struct {
    /// Receipt cumulative gas, used by the legacy one-dimensional allowance.
    receipt_gas_used: u64 = 0,
    /// Block/header dimensions, used by multidimensional gas accounting.
    block_gas: BlockGas = .{},
};

/// Project preparation facts into the engine's concrete opcode-visible context.
pub fn executionContext(env: EnvFacts, origin: Address, gas_price: u256, gas_limit: u64, blob_hashes: []const u256) execution.ExecutionContext {
    return .{
        .chain = .{ .chain_id = env.chain_id },
        .block = .{
            .coinbase = env.coinbase,
            .number = env.number,
            .slot_number = env.slot_number,
            .timestamp = env.timestamp,
            .gas_limit = gas_limit,
            .difficulty_or_prev_randao = env.prev_randao,
            .base_fee = env.base_fee,
            .blob_base_fee = env.blob_base_fee,
        },
        .transaction = .{
            .origin = origin,
            .gas_price = gas_price,
            .blob_hashes = blob_hashes,
        },
    };
}

/// Transaction-scoped execution environment: the data that belongs to the whole
/// transaction rather than to the top-level call/create frame.
///
/// Mirrors the spec's `TransactionEnvironment` — the executor's transaction
/// accounting shell warms the `access_list` and applies the `authorization_list`;
/// the interpreter never sees them. Paired with an execution `Message` in
/// `Prepared`.
pub const TransactionScope = struct {
    pub const Context = execution.ExecutionContext;

    context: Context,
    access_list: []const AccessListEntry = &.{},
    authorization_list: []const AuthorizationTuple = &.{},
    /// Count of authorization tuples *parsed* from the transaction. May exceed
    /// `authorization_list.len` (malformed tuples are parsed but dropped from the
    /// list). Set explicitly — it does NOT default from the list, so a scope built
    /// by hand with authorizations must fill this or gas accounting under-counts.
    authorization_count: usize = 0,

    /// The parsed authorization count (see the `authorization_count` field).
    pub fn authorizationCount(self: TransactionScope) usize {
        return self.authorization_count;
    }
};

/// Project a `Transaction` into the read-only `TransactionView` (fees grouped
/// into `FeeFields`) consumed by the validation and gas paths.
pub fn transactionView(tx: Transaction) TransactionView {
    return .{
        .kind = tx.kind,
        .sender = tx.sender,
        .nonce = tx.nonce,
        .gas_limit = tx.gas_limit,
        .to = tx.to,
        .value = tx.value,
        .input = tx.input,
        .access_list = tx.access_list,
        .authorization_list = tx.authorization_list,
        .authorization_count = tx.authorization_count orelse tx.authorization_list.len,
        .fee = .{
            .gas_price = tx.gas_price,
            .max_fee_per_gas = tx.max_fee_per_gas,
            .max_priority_fee_per_gas = tx.max_priority_fee_per_gas,
            .max_fee_per_blob_gas = tx.max_fee_per_blob_gas,
        },
        .blob_hashes = tx.blob_hashes,
    };
}

pub fn effectiveGasPrice(env: EnvFacts, view: TransactionView) u256 {
    return switch (view.kind) {
        .legacy, .access_list => view.fee.gas_price,
        .dynamic_fee, .blob, .set_code => blk: {
            const max_fee = view.fee.max_fee_per_gas orelse return view.fee.gas_price;
            const priority_fee = view.fee.max_priority_fee_per_gas orelse 0;
            const capped_priority = std.math.add(u256, env.base_fee, priority_fee) catch std.math.maxInt(u256);
            break :blk @min(max_fee, capped_priority);
        },
    };
}

/// Build the immutable EVM request after family lifecycle has resolved the
/// message gas budget.
pub fn executionRequest(context: execution.ExecutionContext, message: execution.Message, gas: ExecutionGas) execution.EvmExecutionRequest {
    return .{
        .context = context,
        .message = message,
        .gas = gas,
    };
}

/// A validated transaction ready to execute: the pipeline output of `prepare`.
/// The raw transaction nonce is intentionally absent; execution consumes only
/// the validated account state and the derived message identity.
pub fn Prepared(comptime Protocol: type) type {
    return struct {
        /// Transaction-scope environment (context + access/authorization lists).
        scope: TransactionScope,
        /// The top-level call/create identity the executor runs.
        message: execution.Message,
        /// Resolved execution gas; null when the transaction has no execution step.
        execution_gas: ?ExecutionGas,
        settlement: Protocol.Settlement.Plan,
    };
}

pub fn PrepareResult(comptime Protocol: type) type {
    return union(enum) {
        rejected: Protocol.Tx.ValidationError,
        executable: Prepared(Protocol),
    };
}

pub fn PrepareInput(comptime Protocol: type) type {
    return struct {
        pub const ProtocolType = Protocol;

        revision: Protocol.Revision,
        tx: Transaction,
        env: EnvFacts,
        block: PreparationBlockProgress = .{},
        state: PreparationStateAccess,
    };
}
