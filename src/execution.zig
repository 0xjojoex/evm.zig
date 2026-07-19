//! Concrete values at the reusable EVM execution boundary.
//!
//! These values describe one root EVM invocation and the neutral transaction-
//! local state needed when opening its scope. Family transaction decoding,
//! validation, authorization, settlement, receipts, and continuations remain
//! outside this module.

const std = @import("std");

const Address = @import("./address.zig").Address;

const precompile_runtime = @import("./execution/precompile_runtime.zig");

pub const ExecutionGas = @import("./execution/gas.zig").ExecutionGas;
pub const PrecompileCall = precompile_runtime.PrecompileCall;
pub const PrecompileOutcome = precompile_runtime.PrecompileOutcome;
pub const PrecompileRuntime = precompile_runtime.PrecompileRuntime;

/// A top-level call message.
pub const Call = struct {
    sender: Address,
    recipient: Address,
    input: []const u8 = &.{},
    value: u256 = 0,
};

/// A top-level create or create2 message.
pub const Create = struct {
    sender: Address,
    init_code: []const u8,
    value: u256 = 0,
    salt: ?u256 = null,
};

/// The root call/create identity consumed by the execution engine.
///
/// The resolved execution budget lives on `EvmExecutionRequest`: it changes
/// during transaction preparation while the message itself does not.
pub const Message = union(enum) {
    call: Call,
    create: Create,

    pub fn init(message_input: struct {
        sender: Address,
        to: ?Address = null,
        input: []const u8 = &.{},
        value: u256 = 0,
        create2_salt: ?u256 = null,
    }) Message {
        if (message_input.to) |recipient| {
            return .{ .call = .{
                .sender = message_input.sender,
                .recipient = recipient,
                .input = message_input.input,
                .value = message_input.value,
            } };
        }
        return .{ .create = .{
            .sender = message_input.sender,
            .init_code = message_input.input,
            .value = message_input.value,
            .salt = message_input.create2_salt,
        } };
    }

    pub fn sender(self: Message) Address {
        return switch (self) {
            .call => |call| call.sender,
            .create => |create| create.sender,
        };
    }

    pub fn input(self: Message) []const u8 {
        return switch (self) {
            .call => |call| call.input,
            .create => |create| create.init_code,
        };
    }

    pub fn value(self: Message) u256 {
        return switch (self) {
            .call => |call| call.value,
            .create => |create| create.value,
        };
    }

    pub fn isCreate(self: Message) bool {
        return switch (self) {
            .call => false,
            .create => true,
        };
    }
};

/// Chain-lifetime values resolved for EVM execution.
pub const ChainEnvironment = struct {
    /// Required: a default would silently choose one family's chain identity.
    chain_id: u256,
};

/// Block-lifetime values resolved for EVM execution.
pub const BlockEnvironment = struct {
    coinbase: Address = std.mem.zeroes(Address),
    number: u64 = 0,
    slot_number: u64 = 0,
    timestamp: u64 = 0,
    /// Opcode-visible block gas limit, not the message execution budget.
    gas_limit: u64 = 0,
    difficulty_or_prev_randao: u256 = 0,
    base_fee: u256 = 0,
    blob_base_fee: u256 = 0,
};

/// Transaction-lifetime values resolved for EVM execution.
pub const TransactionEnvironment = struct {
    origin: Address,
    gas_price: u256 = 0,
    blob_hashes: []const u256 = &.{},
};

/// Resolved opcode-visible environment for one EVM call tree.
pub const ExecutionContext = struct {
    pub const Chain = ChainEnvironment;
    pub const Block = BlockEnvironment;
    pub const Transaction = TransactionEnvironment;

    chain: ChainEnvironment,
    block: BlockEnvironment = .{},
    transaction: TransactionEnvironment,
};

/// A storage slot that is already warm when root execution starts.
pub const WarmStorageSlot = struct {
    address: Address,
    key: u256,
};

/// Family- or witness-resolved additions to mandatory engine warmth.
///
/// This is not an Ethereum access list: grouping, duplicate charging, and
/// authorization processing remain family lifecycle policy.
pub const InitialWarmSet = struct {
    accounts: []const Address = &.{},
    storage_slots: []const WarmStorageSlot = &.{},
};

/// Neutral transaction-local state applied while opening an execution scope.
pub const ExecutionScopeInit = struct {
    pub const WarmSet = InitialWarmSet;
    pub const WarmSlot = WarmStorageSlot;

    initial_warm_set: InitialWarmSet = .{},
};

/// One immutable, borrowed EVM invocation.
///
/// Slices are borrowed data, not a serialization format. Durable replay needs
/// a versioned codec that copies their contents.
pub const EvmExecutionRequest = struct {
    context: ExecutionContext,
    message: Message,
    gas: ExecutionGas,
};

test "execution request and scope initialization contain no family policy" {
    const request_fields = std.meta.fields(EvmExecutionRequest);
    try std.testing.expectEqual(@as(usize, 3), request_fields.len);
    try std.testing.expectEqualStrings("context", request_fields[0].name);
    try std.testing.expect(request_fields[0].type == ExecutionContext);
    try std.testing.expectEqualStrings("message", request_fields[1].name);
    try std.testing.expect(request_fields[1].type == Message);
    try std.testing.expectEqualStrings("gas", request_fields[2].name);
    try std.testing.expect(request_fields[2].type == ExecutionGas);

    const scope_fields = std.meta.fields(ExecutionScopeInit);
    try std.testing.expectEqual(@as(usize, 1), scope_fields.len);
    try std.testing.expectEqualStrings("initial_warm_set", scope_fields[0].name);
    try std.testing.expect(scope_fields[0].type == InitialWarmSet);

    try std.testing.expect(!@hasField(EvmExecutionRequest, "transaction"));
    try std.testing.expect(!@hasField(EvmExecutionRequest, "access_list"));
    try std.testing.expect(!@hasField(EvmExecutionRequest, "authorization_list"));
    try std.testing.expect(!@hasField(EvmExecutionRequest, "settlement"));
    try std.testing.expect(!@hasField(EvmExecutionRequest, "checkpoint"));
    try std.testing.expect(!@hasField(Call, "gas"));
    try std.testing.expect(!@hasField(Call, "gas_reservoir"));
    try std.testing.expect(!@hasField(Create, "gas"));
    try std.testing.expect(!@hasField(Create, "gas_reservoir"));
    try std.testing.expect(!@hasField(ExecutionScopeInit, "access_list"));
    try std.testing.expect(!@hasField(ExecutionScopeInit, "authorization_list"));
}

test "message identity is independent from gas and preserves create2 salt" {
    const sender = [_]u8{0x11} ** 20;
    const message = Message.init(.{
        .sender = sender,
        .input = &.{0x42},
        .value = 7,
        .create2_salt = 9,
    });

    try std.testing.expect(message.isCreate());
    try std.testing.expectEqual(sender, message.sender());
    try std.testing.expectEqualSlices(u8, &.{0x42}, message.input());
    try std.testing.expectEqual(@as(u256, 7), message.value());
    try std.testing.expectEqual(@as(?u256, 9), message.create.salt);
}

test "concrete request literals expose call and warm-set fields" {
    const sender = [_]u8{0x11} ** 20;
    const recipient = [_]u8{0x22} ** 20;
    const request: EvmExecutionRequest = .{
        .context = .{
            .chain = .{ .chain_id = 1 },
            .block = .{ .coinbase = recipient },
            .transaction = .{ .origin = sender },
        },
        .message = .{ .call = .{
            .sender = sender,
            .recipient = recipient,
        } },
        .gas = .legacy(100_000),
    };
    const scope: ExecutionScopeInit = .{ .initial_warm_set = .{
        .accounts = &.{recipient},
        .storage_slots = &.{.{ .address = recipient, .key = 7 }},
    } };

    try std.testing.expectEqual(@as(u256, 1), request.context.chain.chain_id);
    try std.testing.expectEqual(@as(u64, 100_000), request.gas.regular_left);
    try std.testing.expectEqual(@as(usize, 1), scope.initial_warm_set.accounts.len);
    try std.testing.expectEqual(@as(usize, 1), scope.initial_warm_set.storage_slots.len);
}
