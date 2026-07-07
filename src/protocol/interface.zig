const std = @import("std");

const address = @import("../address.zig");
const execution = @import("execution.zig");
const instruction_mod = @import("instruction.zig");
const opcode_info = @import("../opcode.zig");
const precompile = @import("../precompile.zig");
const support = @import("support.zig");
const transaction_protocol = @import("transaction.zig");
const tx = @import("../transaction/Transaction.zig");
const tx_validation = @import("../transaction/validation.zig");

const Address = address.Address;
const RevisionId = support.RevisionId;

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

pub const BlockStartContext = struct {
    number: u64,
    timestamp: u64,
    parent_hash: ?[32]u8 = null,
    parent_beacon_block_root: ?[32]u8 = null,
};

pub const BlockStartSystemCall = struct {
    sender: Address,
    recipient: Address,
    input: [32]u8,
    gas: u64,
};

pub const BlockStartSystemCalls = struct {
    pub const capacity = 4;

    items: [capacity]BlockStartSystemCall = undefined,
    len: usize = 0,

    pub fn append(self: *BlockStartSystemCalls, call: BlockStartSystemCall) void {
        std.debug.assert(self.len < capacity);
        self.items[self.len] = call;
        self.len += 1;
    }

    pub fn slice(self: *const BlockStartSystemCalls) []const BlockStartSystemCall {
        return self.items[0..self.len];
    }
};

pub const DelegatedAccountAccess = struct {
    status: AccountAccessStatus,
    gas: i64 = 0,
};

pub const AuthorizationGasAdjustment = struct {
    regular_refund: u64 = 0,
    state_refund: u64 = 0,

    pub fn add(self: *AuthorizationGasAdjustment, other: AuthorizationGasAdjustment) void {
        self.regular_refund = std.math.add(u64, self.regular_refund, other.regular_refund) catch std.math.maxInt(u64);
        self.state_refund = std.math.add(u64, self.state_refund, other.state_refund) catch std.math.maxInt(u64);
    }
};

pub const ChildGas = struct {
    gas: i64,
    out_of_gas: bool = false,
};

// Definition values are nominally typed: the compiler checks the domain
// config fields at construction and `Bound` enforces required fields. What
// remains here are the boundaries where user-provided *types* enter the
// engine — the instruction namespace, the precompile namespace, and the
// revision model — plus the generic transaction wiring that fn-type
// coercion cannot express.
pub fn assertValidDispatchDefinition(comptime Definition: type) void {
    const support_window = comptime assertDefinitionModel(Definition);
    assertDispatchSurfaceTypes(Definition, support_window);
}

pub fn assertValidProtocolDefinition(comptime Definition: type) void {
    assertValidDispatchDefinition(Definition);
    assertPrecompileDomainTypes(Definition);
}

pub fn assertValidDefinition(comptime Definition: type) void {
    assertValidProtocolDefinition(Definition);
    assertInstructionDynamicGasTypes(Definition);
    assertResolvedTransactionDomainTypes(Definition, transaction_protocol.For(Definition));
}

fn requireDecl(comptime Definition: type, comptime name: []const u8) void {
    if (!@hasDecl(Definition, name)) {
        @compileError("Definition missing required declaration: " ++ name);
    }
}

fn requireNestedDecl(comptime Namespace: type, comptime namespace_name: []const u8, comptime name: []const u8) void {
    if (!@hasDecl(Namespace, name)) {
        @compileError(namespace_name ++ " missing required declaration: " ++ name);
    }
}

fn requireNestedFn(comptime Namespace: type, comptime namespace_name: []const u8, comptime name: []const u8) void {
    if (!std.meta.hasFn(Namespace, name)) {
        if (@hasDecl(Namespace, name)) {
            @compileError(namespace_name ++ " declaration must be a function: " ++ name);
        }
        @compileError(namespace_name ++ " missing required function: " ++ name);
    }
}

fn requireOptionalNestedFn(comptime Namespace: type, comptime namespace_name: []const u8, comptime name: []const u8) void {
    if (@hasDecl(Namespace, name) and !std.meta.hasFn(Namespace, name)) {
        @compileError(namespace_name ++ " declaration must be a function: " ++ name);
    }
}

fn requireSupportMethod(comptime Support: type, comptime name: []const u8) void {
    if (!std.meta.hasMethod(Support, name)) {
        if (@hasDecl(Support, name)) {
            @compileError("Definition.Support declaration must be a method: " ++ name);
        }
        @compileError("Definition.Support missing required method: " ++ name);
    }
}

fn assertDefinitionModel(comptime Definition: type) Definition.Support {
    switch (@typeInfo(Definition.Revision)) {
        .@"enum" => {},
        else => @compileError("Definition.Revision must be an enum"),
    }
    if (@typeInfo(std.meta.Tag(Definition.Revision)).int.bits > @bitSizeOf(RevisionId)) {
        @compileError("Definition.Revision tag type is too large for runtime revision storage");
    }

    switch (@typeInfo(Definition.Support)) {
        .@"struct" => {},
        else => @compileError("Definition.Support must be a struct"),
    }

    switch (@typeInfo(Definition.Availability)) {
        .@"union" => {},
        else => @compileError("Definition.Availability must be a union"),
    }

    if (!@hasField(Definition.Support, "min")) {
        @compileError("Definition.Support must expose min");
    }
    if (!@hasField(Definition.Support, "max")) {
        @compileError("Definition.Support must expose max");
    }
    requireDecl(Definition.Support, "all");
    requireSupportMethod(Definition.Support, "assertValid");
    requireSupportMethod(Definition.Support, "contains");

    const support_window = Definition.Support.all;
    support_window.assertValid();
    const contains_min: bool = support_window.contains(support_window.min);
    _ = contains_min;

    if (@TypeOf(support_window.min) != Definition.Revision) {
        @compileError("Definition.Support.min must use Definition.Revision");
    }
    if (@TypeOf(support_window.max) != Definition.Revision) {
        @compileError("Definition.Support.max must use Definition.Revision");
    }

    assertRevisions(Definition);
    return support_window;
}

fn assertRevisions(comptime Definition: type) void {
    const revisions = Definition.revisions;
    if (revisions.len == 0) {
        @compileError("Definition.revisions must not be empty");
    }

    for (revisions) |revision| {
        if (@TypeOf(revision) != Definition.Revision) {
            @compileError("Definition.revisions entries must use Definition.Revision");
        }
    }
}

fn assertDispatchSurfaceTypes(comptime Definition: type, comptime support_window: Definition.Support) void {
    const opcode = opcode_info.Opcode.STOP;
    const opcode_byte = @intFromEnum(opcode);
    const Instruction = Definition.Instruction;
    switch (@typeInfo(Instruction)) {
        .@"struct" => {},
        else => @compileError("Definition.Instruction must be a struct namespace"),
    }
    requireNestedDecl(Instruction, "Definition.Instruction", "Value");
    requireNestedFn(Instruction, "Definition.Instruction", "fromByte");
    requireNestedFn(Instruction, "Definition.Instruction", "context");
    requireNestedFn(Instruction, "Definition.Instruction", "info");
    requireNestedFn(Instruction, "Definition.Instruction", "availability");
    requireNestedFn(Instruction, "Definition.Instruction", "tier");
    requireNestedFn(Instruction, "Definition.Instruction", "executionTarget");

    const instruction: Instruction.Value = comptime Instruction.fromByte(opcode_byte);
    const revision = Definition.revisions[0];

    const info: opcode_info.OpInfo = Definition.opcodeInfoByte(opcode_byte);
    const named_info: opcode_info.OpInfo = Definition.opcodeInfo(opcode);
    const instruction_info: opcode_info.OpInfo = comptime Instruction.info(instruction);
    _ = info;
    _ = named_info;
    _ = instruction_info;
    const context: instruction_mod.Context = comptime Instruction.context(instruction);
    const first_byte: u8 = context.firstByte();
    _ = first_byte;

    const availability: Definition.Availability = comptime Definition.opcodeAvailabilityByte(opcode_byte);
    const named_availability: Definition.Availability = comptime Definition.opcodeAvailability(opcode);
    const instruction_availability: Definition.Availability = comptime Instruction.availability(instruction);
    _ = named_availability;
    _ = instruction_availability;
    const resolved: support.Resolution = Definition.resolveAvailability(availability, support_window);
    _ = resolved;

    const static_gas: i64 = Definition.staticGasForRevisionByte(revision, opcode_byte);
    const named_static_gas: i64 = Definition.staticGasForRevision(revision, opcode);
    _ = named_static_gas;
    _ = static_gas;
    const instruction_static_gas: i64 = comptime Definition.staticGasForRevisionInstruction(revision, instruction);
    _ = instruction_static_gas;

    const tier_byte: support.OpcodeTier = Definition.opcodeTierByte(opcode_byte);
    _ = tier_byte;
    const tier: support.OpcodeTier = Definition.opcodeTier(opcode);
    _ = tier;
    const instruction_tier: support.OpcodeTier = comptime Instruction.tier(instruction);
    _ = instruction_tier;

    const instruction_target: execution.ExecutionTarget = comptime Instruction.executionTarget(instruction);
    execution.assertValidTarget(instruction_target);
}

fn assertPrecompileDomainTypes(comptime Definition: type) void {
    const Precompile = Definition.Precompile;
    switch (@typeInfo(Precompile)) {
        .@"struct" => {},
        else => @compileError("Definition.Precompile must be a struct namespace"),
    }
    requireNestedDecl(Precompile, "Definition.Precompile", "Entry");
    requireNestedFn(Precompile, "Definition.Precompile", "resolve");
    requireNestedFn(Precompile, "Definition.Precompile", "execute");
    requireOptionalNestedFn(Precompile, "Definition.Precompile", "active");
    requireOptionalNestedFn(Precompile, "Definition.Precompile", "executeWithOutputBuffer");

    const revision = Definition.revisions[0];
    const entry: ?Precompile.Entry = Precompile.resolve(revision, zeroAddress());
    _ = entry;

    const Execute = fn (
        std.mem.Allocator,
        Definition.Revision,
        Precompile.Entry,
        []const u8,
        i64,
    ) precompile.Error!precompile.Result;
    const execute: Execute = Precompile.execute;
    _ = execute;

    if (comptime std.meta.hasFn(Precompile, "active")) {
        const active: bool = Precompile.active(revision, zeroAddress());
        _ = active;
    }

    if (comptime std.meta.hasFn(Precompile, "executeWithOutputBuffer")) {
        const ExecuteWithOutputBuffer = fn (
            std.mem.Allocator,
            Definition.Revision,
            Precompile.Entry,
            []const u8,
            i64,
            ?[]u8,
        ) precompile.Error!precompile.Result;
        const execute_with_output_buffer: ExecuteWithOutputBuffer = Precompile.executeWithOutputBuffer;
        _ = execute_with_output_buffer;
    }
}

fn assertInstructionDynamicGasTypes(comptime Definition: type) void {
    const Instruction = Definition.Instruction;
    requireNestedFn(Instruction, "Definition.Instruction", "expByteGas");
    requireNestedFn(Instruction, "Definition.Instruction", "accountReadColdAccessGas");
    requireNestedFn(Instruction, "Definition.Instruction", "codeAccountAccessGas");

    const revision = Definition.revisions[0];

    const exp_byte_gas: i64 = Instruction.expByteGas(revision);
    _ = exp_byte_gas;
    const account_read_cold_access_gas: ?i64 = Instruction.accountReadColdAccessGas(revision);
    _ = account_read_cold_access_gas;
    const code_account_access_gas: ?i64 = Instruction.codeAccountAccessGas(revision, .cold);
    _ = code_account_access_gas;
}

pub fn assertResolvedTransactionDomainTypes(comptime Definition: type, comptime ResolvedTransaction: type) void {
    switch (@typeInfo(ResolvedTransaction)) {
        .@"struct" => {},
        else => @compileError("Protocol.Transaction must be a struct namespace"),
    }
    requireNestedDecl(ResolvedTransaction, "Protocol.Transaction", "Value");
    requireNestedDecl(ResolvedTransaction, "Protocol.Transaction", "View");
    requireNestedDecl(ResolvedTransaction, "Protocol.Transaction", "ValidationError");
    requireNestedFn(ResolvedTransaction, "Protocol.Transaction", "view");
    requireNestedFn(ResolvedTransaction, "Protocol.Transaction", "prepare");

    const DefinitionTransaction = Definition.Transaction;
    if (!std.meta.hasFn(DefinitionTransaction, "view") and
        (ResolvedTransaction.Value != tx.ProtocolTransaction or ResolvedTransaction.View != tx.TransactionView))
    {
        @compileError("Definition.Transaction.view is required when overriding Transaction.Value or Transaction.View");
    }
    if (!std.meta.hasFn(DefinitionTransaction, "prepare") and
        (ResolvedTransaction.View != tx.TransactionView or ResolvedTransaction.ValidationError != tx_validation.ValidationError))
    {
        @compileError("Definition.Transaction.prepare is required when overriding Transaction.View or Transaction.ValidationError");
    }

    const ProtocolLike = struct {
        pub const Revision = Definition.Revision;
        pub const Transaction = ResolvedTransaction;
        pub const Settlement = Definition.Settlement;
    };

    const view_fn: fn (ResolvedTransaction.Value) ResolvedTransaction.View = ResolvedTransaction.view;
    _ = view_fn;
    const prepare_result_type = @TypeOf(ResolvedTransaction.prepare(ProtocolLike, @as(tx.PrepareInput(ProtocolLike), undefined)));
    switch (@typeInfo(prepare_result_type)) {
        .error_union => |info| {
            if (info.payload != tx.PrepareResult(ProtocolLike)) {
                @compileError("Protocol.Transaction.prepare must return !transaction.PrepareResult(Protocol)");
            }
        },
        else => @compileError("Protocol.Transaction.prepare must return an error union"),
    }
}

fn zeroAddress() Address {
    return address.addr(0);
}

test "support value protocol exposes methods" {
    const Revision = enum { alpha };
    const Support = struct {
        min: Revision = .alpha,
        max: Revision = .alpha,

        pub const all: @This() = .{};

        pub fn assertValid(comptime self: @This()) void {
            _ = self;
        }

        pub fn contains(self: @This(), revision: Revision) bool {
            _ = self;
            _ = revision;
            return true;
        }
    };
    const FieldNamedLikeMethod = struct {
        assertValid: fn (Support) void,
    };

    try std.testing.expect(std.meta.hasMethod(Support, "assertValid"));
    try std.testing.expect(std.meta.hasMethod(Support, "contains"));
    try std.testing.expect(!std.meta.hasMethod(FieldNamedLikeMethod, "assertValid"));
}
