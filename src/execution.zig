//! Concrete values at the reusable EVM execution boundary.
//!
//! These values describe one root EVM invocation and the engine transaction-
//! local state needed when opening its scope. Family transaction decoding,
//! validation, authorization, settlement, receipts, and continuations remain
//! outside this module.

const std = @import("std");

const Address = @import("./address.zig").Address;
const execution_context = @import("./execution/context.zig");

const reentrant_native_contract = @import("./execution/reentrant_native_contract.zig");

pub const ExecutionGas = @import("./execution/gas.zig").ExecutionGas;
pub const ReentrantNativeContractCall = reentrant_native_contract.Call;
pub const ReentrantNativeContractRuntime = reentrant_native_contract.Runtime;
pub const NoReentrantNativeContracts = reentrant_native_contract.None;
pub const resources = @import("./execution/resources.zig");

pub const Status = enum(u8) {
    success,
    revert,
    invalid,
    out_of_gas,
};

/// Whether a transaction-scoped warmth record already existed for the thing
/// being accessed. Applies to accounts, storage slots, and delegation targets
/// alike; it says nothing about which kind of thing was accessed.
pub const AccessStatus = enum(u1) {
    cold,
    warm,
};

/// How one SSTORE moves a slot through its original/current/next triple.
///
/// Classified from state in `state.storage.status`; priced by fork gas
/// schedules. `assigned` covers every transition that neither creates nor
/// clears observable value.
pub const StorageStatus = enum(u8) {
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

pub const CallNewAccountGas = struct {
    regular: i64 = 0,
    state: i64 = 0,
};

pub const CallNewAccountInput = struct {
    value: u256,
    account_exists: bool,
};

pub const CreateAccountStateGasInput = struct {
    target_alive: bool,
};

pub const TopFrameValueTransferInput = struct {
    value: u256,
    same_address: bool,
    creates_account: bool,
};

pub const TopLevelDelegatedAccountAccessInput = struct {
    target_is_native_contract: bool,
    already_warm: bool,
};

pub const DelegatedAccountAccess = struct {
    status: AccessStatus,
    gas: i64 = 0,
};

pub const ChildGasInput = struct {
    requested: i64,
    available: i64,
};

pub const ChildGas = struct {
    gas: i64,
    out_of_gas: bool = false,
};

pub const SelfDestructPolicyInput = struct {
    same_address: bool,
    created_in_transaction: bool,
};

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

pub const SelfDestructNewAccountInput = struct {
    same_address: bool,
    transfers_balance: bool,
    account_exists: bool,
};

pub const ValueTransferInput = struct {
    from: Address,
    to: Address,
    amount: u256,
};

pub const ValueTransferLog = struct {
    address: Address,
    topic: u256,
};

/// Engine-level reason an EVM execution stopped.
///
/// `invalid` is the fallback for engine paths that have no more precise frame
/// or engine cause. Interpreter frames never halt with this generic reason.
/// Projection-specific strings do not belong here.
pub const TerminalCause = enum(u8) {
    none,
    revert,
    out_of_gas,
    invalid,
    call_depth_exceeded,
    insufficient_balance,
    nonce_overflow,
    invalid_opcode,
    stack_underflow,
    stack_overflow,
    invalid_jump,
    write_protection,
    return_data_out_of_bounds,
    contract_address_collision,
    max_code_size_exceeded,
    invalid_code,
    code_store_out_of_gas,
};

/// The bytecode interpreter's exact reason for halting one call frame.
///
/// Frame halts are historical facts. Engine finalization may produce a
/// different execution outcome without rewriting the reason the frame stopped.
pub const FrameHalt = enum(u8) {
    success,
    revert,
    out_of_gas,
    invalid_opcode,
    stack_underflow,
    stack_overflow,
    invalid_jump,
    write_protection,
    return_data_out_of_bounds,

    pub fn status(self: FrameHalt) Status {
        return switch (self) {
            .success => .success,
            .revert => .revert,
            .out_of_gas => .out_of_gas,
            .invalid_opcode,
            .stack_underflow,
            .stack_overflow,
            .invalid_jump,
            .write_protection,
            .return_data_out_of_bounds,
            => .invalid,
        };
    }

    pub fn terminalCause(self: FrameHalt) TerminalCause {
        return switch (self) {
            .success => .none,
            .revert => .revert,
            .out_of_gas => .out_of_gas,
            .invalid_opcode => .invalid_opcode,
            .stack_underflow => .stack_underflow,
            .stack_overflow => .stack_overflow,
            .invalid_jump => .invalid_jump,
            .write_protection => .write_protection,
            .return_data_out_of_bounds => .return_data_out_of_bounds,
        };
    }

    pub fn consumesAllGas(self: FrameHalt) bool {
        return switch (self) {
            .success, .revert => false,
            .out_of_gas,
            .invalid_opcode,
            .stack_underflow,
            .stack_overflow,
            .invalid_jump,
            .write_protection,
            .return_data_out_of_bounds,
            => true,
        };
    }
};

/// Atomic engine-visible classification of one completed execution.
///
/// `status` and `cause` are both required because a cause does not always
/// determine status (for example, pre-Homestead code-store out-of-gas).
pub const ExecutionOutcome = struct {
    status: Status,
    cause: TerminalCause,
};

/// Final engine result after prechecks, precompiles, and create finalization.
pub const ExecutionResult = struct {
    outcome: ExecutionOutcome,
    /// Present only when bytecode execution produced a frame.
    frame_halt: ?FrameHalt = null,
    gas_left: i64,
    gas_refund: i64,
    gas_reservoir: i64 = 0,
    state_gas_spent: i64 = 0,
    state_gas_from_gas_left: i64 = 0,
    output_data: []u8,

    comptime {
        std.debug.assert(@sizeOf(ExecutionResult) == 64);
    }

    pub fn status(self: ExecutionResult) Status {
        return self.outcome.status;
    }

    pub fn terminalCause(self: ExecutionResult) TerminalCause {
        return self.outcome.cause;
    }

    pub fn trackStateGas(self: *ExecutionResult, gas: i64) void {
        if (gas <= 0) return;
        const reservoir_available = @max(self.gas_reservoir, 0);
        const from_reservoir = @min(reservoir_available, gas);
        const from_regular = gas - from_reservoir;
        if (from_regular > self.gas_left) {
            self.outcome = .{ .status = .out_of_gas, .cause = .out_of_gas };
            self.gas_left = 0;
            return;
        }
        self.gas_reservoir -= from_reservoir;
        self.gas_left -= from_regular;
        self.state_gas_from_gas_left = std.math.add(i64, self.state_gas_from_gas_left, from_regular) catch std.math.maxInt(i64);
        self.state_gas_spent = std.math.add(i64, self.state_gas_spent, gas) catch std.math.maxInt(i64);
    }
};

/// Settle frame-local state gas against a completed result.
///
/// Shared by `Interpreter.FrameResult` and `ExecutionResult`: both carry the
/// same state-gas ledger fields and answer `status()`. State gas does not
/// survive a non-success outcome; only a revert also restores the regular gas
/// the charge spilled into.
pub fn finalizeStateGas(result: anytype) void {
    switch (result.status()) {
        .success => {},
        .revert => unwindStateGas(result, true),
        .invalid, .out_of_gas => unwindStateGas(result, false),
    }
}

fn unwindStateGas(result: anytype, restore_regular_gas: bool) void {
    const max_i64 = @as(i64, std.math.maxInt(i64));
    const min_i64 = @as(i64, std.math.minInt(i64));
    const reservoir_delta = std.math.sub(i64, result.state_gas_spent, result.state_gas_from_gas_left) catch
        if (result.state_gas_spent >= 0) max_i64 else min_i64;

    result.gas_reservoir = std.math.add(i64, result.gas_reservoir, reservoir_delta) catch
        if (reservoir_delta >= 0) max_i64 else min_i64;

    if (restore_regular_gas) {
        result.gas_left = std.math.add(i64, result.gas_left, result.state_gas_from_gas_left) catch
            if (result.state_gas_from_gas_left >= 0) max_i64 else min_i64;
    }

    result.state_gas_spent = 0;
    result.state_gas_from_gas_left = 0;
}

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
    /// Family-resolved account to create. Execution consumes this identity;
    /// it does not derive a second target from mutable state.
    recipient: Address,
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
        create_recipient: ?Address = null,
    }) error{MissingCreateRecipient}!Message {
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
            .recipient = message_input.create_recipient orelse return error.MissingCreateRecipient,
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
};

pub const ChainEnvironment = execution_context.ChainEnvironment;
pub const BlockEnvironment = execution_context.BlockEnvironment;
pub const TransactionEnvironment = execution_context.TransactionEnvironment;
pub const TransactionExtension = execution_context.TransactionExtension;
pub const ExecutionContext = execution_context.ExecutionContext;

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

/// Engine transaction-local state applied while opening an execution scope.
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
    try std.testing.expect(!@hasField(ExecutionScopeInit, "access_list"));
    try std.testing.expect(!@hasField(ExecutionScopeInit, "authorization_list"));
}

test "message identity preserves create2 salt" {
    const sender = Address.fromBytes([_]u8{0x11} ** 20);
    const recipient = Address.fromBytes([_]u8{0x22} ** 20);
    const message = try Message.init(.{
        .sender = sender,
        .create_recipient = recipient,
        .input = &.{0x42},
        .value = 7,
        .create2_salt = 9,
    });

    try std.testing.expectEqual(sender, message.sender());
    try std.testing.expectEqualSlices(u8, &.{0x42}, message.input());
    try std.testing.expectEqual(@as(u256, 7), message.value());
    try std.testing.expectEqual(@as(?u256, 9), message.create.salt);
    try std.testing.expectEqual(recipient, message.create.recipient);
}

test "create message construction requires a family-resolved recipient" {
    try std.testing.expectError(error.MissingCreateRecipient, Message.init(.{
        .sender = Address.fromBytes([_]u8{0x11} ** 20),
    }));
}
