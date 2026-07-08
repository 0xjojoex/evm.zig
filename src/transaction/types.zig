//! Transaction value shapes, in Ethereum terms.
//!
//! One transaction flows through several representations. Keep them distinct:
//!
//!   raw bytes ─(transaction/envelope.zig)-> Transaction ─(prepare)->
//!     TransactionView ─> Prepared{scope, root} ─(executor)-> Host.Message

const std = @import("std");

const Address = @import("../address.zig").Address;

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

/// Ethereum-shaped protocol transaction value used by the default VM surface.
/// Custom definitions can provide their own `Definition.Transaction.Value`.
pub const Transaction = struct {
    kind: TxKind = .legacy,
    sender: Address,
    nonce: ?u64 = null,
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

pub const TransactionView = struct {
    kind: TxKind = .legacy,
    sender: Address,
    nonce: ?u64 = null,
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
};

pub const StateFacts = struct {
    sender_balance: u256 = 0,
    sender_nonce: u64 = 0,
    sender_code_kind: SenderCodeKind = .empty,
    value_transfer_creates_account: bool = false,
};

pub const ExecutionContext = struct {
    chain_id: u256 = 1,
    gas_price: u256 = 0,
    origin: Address,
    coinbase: Address,
    number: u64 = 0,
    slot_number: u64 = 0,
    timestamp: u64 = 0,
    gas_limit: u64 = 0,
    prev_randao: u256 = 0,
    base_fee: u256 = 0,
    blob_base_fee: u256 = 0,
    blob_hashes: []const u256 = &.{},

    pub fn init(env: EnvFacts, origin: Address, gas_price: u256, gas_limit: u64, blob_hashes: []const u256) ExecutionContext {
        return .{
            .chain_id = env.chain_id,
            .gas_price = gas_price,
            .origin = origin,
            .coinbase = env.coinbase,
            .number = env.number,
            .slot_number = env.slot_number,
            .timestamp = env.timestamp,
            .gas_limit = gas_limit,
            .prev_randao = env.prev_randao,
            .base_fee = env.base_fee,
            .blob_base_fee = env.blob_base_fee,
            .blob_hashes = blob_hashes,
        };
    }
};

/// Transaction-scoped execution environment: the data that belongs to the whole
/// transaction rather than to the top-level call/create frame.
///
/// Mirrors the spec's `TransactionEnvironment` — the executor's transaction
/// accounting shell warms the `access_list` and applies the `authorization_list`;
/// the interpreter never sees them. Paired with a `RootFrame` in `Prepared`.
pub const TransactionScope = struct {
    context: ExecutionContext,
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

/// The top-level message a transaction initiates: a call to `to`, or a create.
///
/// The pure execution message — sender/target/input/gas/value only. Transaction
/// -scope data (access list, authorizations, block/tx context) lives on
/// `TransactionScope`, not here. Built by `rootFrame`, consumed by the executor;
/// it is the root of the call tree that inner `Host.Message` frames descend from.
pub const RootFrame = union(enum) {
    /// A message call to `recipient`.
    call: Call,
    /// A contract creation (address derived from sender + nonce).
    create: Create,

    pub const Call = struct {
        sender: Address,
        recipient: Address,
        input: []const u8 = &.{},
        gas_limit: u64,
        value: u256 = 0,
    };

    pub const Create = struct {
        sender: Address,
        init_code: []const u8,
        gas_limit: u64,
        value: u256 = 0,
    };

    /// Build a `RootFrame` from flat input: `to`-present becomes a `.call`, `to == null`
    /// becomes a `.create` (with `input` reinterpreted as init code).
    pub fn init(root_frame_input: struct {
        sender: Address,
        to: ?Address = null,
        input: []const u8 = &.{},
        gas_limit: u64,
        value: u256 = 0,
    }) RootFrame {
        if (root_frame_input.to) |recipient| {
            return .{ .call = .{
                .sender = root_frame_input.sender,
                .recipient = recipient,
                .input = root_frame_input.input,
                .gas_limit = root_frame_input.gas_limit,
                .value = root_frame_input.value,
            } };
        }
        return .{ .create = .{
            .sender = root_frame_input.sender,
            .init_code = root_frame_input.input,
            .gas_limit = root_frame_input.gas_limit,
            .value = root_frame_input.value,
        } };
    }

    pub fn sender(self: RootFrame) Address {
        return switch (self) {
            .call => |tx| tx.sender,
            .create => |tx| tx.sender,
        };
    }

    pub fn input(self: RootFrame) []const u8 {
        return switch (self) {
            .call => |tx| tx.input,
            .create => |tx| tx.init_code,
        };
    }

    pub fn gasLimit(self: RootFrame) u64 {
        return switch (self) {
            .call => |tx| tx.gas_limit,
            .create => |tx| tx.gas_limit,
        };
    }

    pub fn value(self: RootFrame) u256 {
        return switch (self) {
            .call => |tx| tx.value,
            .create => |tx| tx.value,
        };
    }

    pub fn isCreate(self: RootFrame) bool {
        return switch (self) {
            .call => false,
            .create => true,
        };
    }
};

/// A validated transaction ready to execute: the pipeline output of `prepare`.
pub fn Prepared(comptime Protocol: type) type {
    return struct {
        /// Create-transaction target address, resolved up front; null for calls.
        created_address: ?Address = null,
        /// Transaction-scope environment (context + access/authorization lists).
        scope: TransactionScope,
        /// The top-level call/create the executor runs.
        root: RootFrame,
        /// Resolved execution gas; null when the transaction has no execution step.
        execution_gas: ?@import("./gas.zig").ExecutionGas,
        settlement: Protocol.Settlement.Plan,
    };
}

pub fn PrepareResult(comptime Protocol: type) type {
    return union(enum) {
        rejected: Protocol.Transaction.ValidationError,
        executable: Prepared(Protocol),
    };
}

pub fn PrepareInput(comptime Protocol: type) type {
    return struct {
        pub const ProtocolType = Protocol;

        revision: Protocol.Revision,
        tx: Protocol.Transaction.Value,
        view: Protocol.Transaction.View,
        env: EnvFacts,
        state: StateFacts,
    };
}
