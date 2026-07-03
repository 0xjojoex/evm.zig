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

pub const Transaction = union(enum) {
    call: CallTransaction,
    create: CreateTransaction,

    pub fn sender(self: Transaction) Address {
        return switch (self) {
            .call => |tx| tx.sender,
            .create => |tx| tx.sender,
        };
    }

    pub fn input(self: Transaction) []const u8 {
        return switch (self) {
            .call => |tx| tx.input,
            .create => |tx| tx.init_code,
        };
    }

    pub fn gasLimit(self: Transaction) u64 {
        return switch (self) {
            .call => |tx| tx.gas_limit,
            .create => |tx| tx.gas_limit,
        };
    }

    pub fn value(self: Transaction) u256 {
        return switch (self) {
            .call => |tx| tx.value,
            .create => |tx| tx.value,
        };
    }

    pub fn isCreate(self: Transaction) bool {
        return switch (self) {
            .call => false,
            .create => true,
        };
    }

    pub fn accessList(self: Transaction) []const AccessListEntry {
        return switch (self) {
            .call => |tx| tx.access_list,
            .create => |tx| tx.access_list,
        };
    }

    pub fn authorizationList(self: Transaction) []const AuthorizationTuple {
        return switch (self) {
            .call => |tx| tx.authorization_list,
            .create => |tx| tx.authorization_list,
        };
    }

    pub fn authorizationCount(self: Transaction) usize {
        return switch (self) {
            .call => |tx| tx.authorization_count orelse tx.authorization_list.len,
            .create => |tx| tx.authorization_count orelse tx.authorization_list.len,
        };
    }
};

pub const NormalizedTransactionInput = struct {
    sender: Address,
    to: ?Address = null,
    input: []const u8 = &.{},
    gas_limit: u64,
    value: u256 = 0,
    access_list: []const AccessListEntry = &.{},
    authorization_list: []const AuthorizationTuple = &.{},
    authorization_count: ?usize = null,
};

pub fn normalizedTransaction(input: NormalizedTransactionInput) Transaction {
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
