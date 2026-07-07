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
pub const ProtocolTransaction = struct {
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
};

pub fn protocolTransactionView(tx: ProtocolTransaction) TransactionView {
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

pub fn executionContext(env: EnvFacts, origin: Address, gas_price: u256, gas_limit: u64, blob_hashes: []const u256) ExecutionContext {
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

pub const CallTransaction = struct {
    sender: Address,
    recipient: Address,
    input: []const u8 = &.{},
    gas_limit: u64,
    value: u256 = 0,
    access_list: []const AccessListEntry = &.{},
    authorization_list: []const AuthorizationTuple = &.{},
    authorization_count: ?usize = null,
};

pub const CreateTransaction = struct {
    sender: Address,
    init_code: []const u8,
    gas_limit: u64,
    value: u256 = 0,
    access_list: []const AccessListEntry = &.{},
    authorization_list: []const AuthorizationTuple = &.{},
    authorization_count: ?usize = null,
};

pub const ExecutionEnvelope = union(enum) {
    call: CallTransaction,
    create: CreateTransaction,

    pub fn sender(self: ExecutionEnvelope) Address {
        return switch (self) {
            .call => |tx| tx.sender,
            .create => |tx| tx.sender,
        };
    }

    pub fn input(self: ExecutionEnvelope) []const u8 {
        return switch (self) {
            .call => |tx| tx.input,
            .create => |tx| tx.init_code,
        };
    }

    pub fn gasLimit(self: ExecutionEnvelope) u64 {
        return switch (self) {
            .call => |tx| tx.gas_limit,
            .create => |tx| tx.gas_limit,
        };
    }

    pub fn value(self: ExecutionEnvelope) u256 {
        return switch (self) {
            .call => |tx| tx.value,
            .create => |tx| tx.value,
        };
    }

    pub fn isCreate(self: ExecutionEnvelope) bool {
        return switch (self) {
            .call => false,
            .create => true,
        };
    }

    pub fn accessList(self: ExecutionEnvelope) []const AccessListEntry {
        return switch (self) {
            .call => |tx| tx.access_list,
            .create => |tx| tx.access_list,
        };
    }

    pub fn authorizationList(self: ExecutionEnvelope) []const AuthorizationTuple {
        return switch (self) {
            .call => |tx| tx.authorization_list,
            .create => |tx| tx.authorization_list,
        };
    }

    pub fn authorizationCount(self: ExecutionEnvelope) usize {
        return switch (self) {
            .call => |tx| tx.authorization_count orelse tx.authorization_list.len,
            .create => |tx| tx.authorization_count orelse tx.authorization_list.len,
        };
    }
};

pub const Transaction = ExecutionEnvelope;

pub const ExecutionEnvelopeInput = struct {
    sender: Address,
    to: ?Address = null,
    input: []const u8 = &.{},
    gas_limit: u64,
    value: u256 = 0,
    access_list: []const AccessListEntry = &.{},
    authorization_list: []const AuthorizationTuple = &.{},
    authorization_count: ?usize = null,
};

pub const NormalizedTransactionInput = ExecutionEnvelopeInput;

pub fn executionEnvelope(input: ExecutionEnvelopeInput) ExecutionEnvelope {
    if (input.to) |recipient| {
        return .{ .call = .{
            .sender = input.sender,
            .recipient = recipient,
            .input = input.input,
            .gas_limit = input.gas_limit,
            .value = input.value,
            .access_list = input.access_list,
            .authorization_list = input.authorization_list,
            .authorization_count = input.authorization_count,
        } };
    }
    return .{ .create = .{
        .sender = input.sender,
        .init_code = input.input,
        .gas_limit = input.gas_limit,
        .value = input.value,
        .access_list = input.access_list,
        .authorization_list = input.authorization_list,
        .authorization_count = input.authorization_count,
    } };
}

pub const normalizedTransaction = executionEnvelope;

pub fn Prepared(comptime Protocol: type) type {
    return struct {
        created_address: ?Address = null,
        execution_context: ExecutionContext,
        envelope: ExecutionEnvelope,
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
