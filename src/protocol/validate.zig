//! Comptime validation for bound execution and transaction contracts.
//!
//! Implementer-facing hook semantics and neutral defaults live in
//! `definition.zig`; shared semantic values live in `types.zig`.

const std = @import("std");

const address = @import("../address.zig");
const definition = @import("../definition.zig");
const execution = @import("execution.zig");
const instruction_mod = @import("instruction.zig");
const opcode_info = @import("../opcode.zig");
const precompile = @import("../precompile.zig");
const precompile_runtime = @import("../execution/precompile_runtime.zig");
const support = @import("support.zig");
const transaction_protocol = @import("transaction.zig");
const tx = @import("../transaction/types.zig");
const tx_settlement = @import("../transaction/settlement.zig");

const RevisionId = support.RevisionId;

// Authored definition values are nominally typed before this point. These
// checks receive a `BoundExecution` and validate the user-provided type
// surfaces that enter dispatch, precompiles, and interpreter execution.
pub fn assertInstructionContract(comptime ExecutionBinding: type) void {
    const support_window = comptime assertDefinitionModel(ExecutionBinding);
    assertDispatchSurfaceTypes(ExecutionBinding, support_window);
}

pub fn assertDispatchContract(comptime ExecutionBinding: type) void {
    assertInstructionContract(ExecutionBinding);
    assertPrecompileDomainTypes(ExecutionBinding);
}

/// Full execution-layer contract: dispatch surface, precompile domain, and the
/// dynamic-gas hooks the real Interpreter consumes. Takes a `BoundExecution`.
pub fn assertExecutionContract(comptime ExecutionBinding: type) void {
    assertDispatchContract(ExecutionBinding);
    assertInstructionDynamicGasTypes(ExecutionBinding);
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

    switch (@typeInfo(Definition.BaseRevision)) {
        .@"enum" => {},
        else => @compileError("Definition.BaseRevision must be an enum"),
    }
    requireNestedFn(Definition, "Definition", "baseRevision");
    requireNestedFn(Definition, "Definition", "order");
    const base_revision_fn: *const fn (Definition.Revision) Definition.BaseRevision = Definition.baseRevision;
    const order_fn: *const fn (Definition.Revision, Definition.Revision) std.math.Order = Definition.order;
    _ = base_revision_fn;
    _ = order_fn;

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
    requireNestedFn(Instruction, "Definition.Instruction", "staticGasForRevision");

    const instruction: Instruction.Value = comptime Instruction.fromByte(opcode_byte);
    const revision = Definition.revisions[0];

    const instruction_info: opcode_info.OpInfo = comptime Instruction.info(instruction);
    _ = instruction_info;
    const context: instruction_mod.Context = comptime Instruction.context(instruction);
    const first_byte: u8 = context.firstByte();
    _ = first_byte;

    const instruction_availability: Definition.Availability = comptime Instruction.availability(instruction);
    const resolved: support.Resolution = Definition.resolveAvailability(instruction_availability, support_window);
    _ = resolved;

    const instruction_static_gas: i64 = comptime Instruction.staticGasForRevision(revision, instruction);
    _ = instruction_static_gas;

    const instruction_tier: support.OpcodeTier = comptime Instruction.tier(instruction);
    _ = instruction_tier;

    const instruction_target: execution.ExecutionTarget = comptime Instruction.executionTarget(instruction);
    execution.assertValidTarget(instruction_target);

    assertInstructionContexts(Definition);
}

fn assertInstructionContexts(comptime Definition: type) void {
    const Instruction = Definition.Instruction;
    inline for (0..256) |index| {
        const ingress_byte: u8 = @intCast(index);
        const value: Instruction.Value = comptime Instruction.fromByte(ingress_byte);
        switch (comptime Instruction.context(value)) {
            .byte => |inherited_byte| {
                if (comptime inherited_byte != ingress_byte) {
                    @compileError(std.fmt.comptimePrint(
                        "Definition.Instruction.fromByte(0x{x:0>2}) must inherit the same byte or return a custom instruction",
                        .{ingress_byte},
                    ));
                }
                const inherited_info = comptime opcode_info.info(inherited_byte);
                const instruction_info = comptime Instruction.info(value);
                if (comptime !instructionInfoEql(instruction_info, inherited_info)) {
                    @compileError(std.fmt.comptimePrint(
                        "Definition.Instruction byte 0x{x:0>2} changes canonical EVM metadata; use custom context for a new instruction",
                        .{ingress_byte},
                    ));
                }
            },
            .custom => |custom| {
                if (comptime custom.first_byte != ingress_byte) {
                    @compileError(std.fmt.comptimePrint(
                        "Definition.Instruction custom value from byte 0x{x:0>2} must retain that first byte",
                        .{ingress_byte},
                    ));
                }
            },
        }
    }
}

fn instructionInfoEql(a: opcode_info.OpInfo, b: opcode_info.OpInfo) bool {
    const names_equal = if (a.name) |a_name|
        if (b.name) |b_name| std.mem.eql(u8, a_name, b_name) else false
    else
        b.name == null;
    if (!names_equal) return false;

    var a_without_name = a;
    var b_without_name = b;
    a_without_name.name = null;
    b_without_name.name = null;
    return std.meta.eql(a_without_name, b_without_name);
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

    const revision = Definition.revisions[0];
    const entry: ?Precompile.Entry = Precompile.resolve(revision, address.zero_address);
    _ = entry;

    const Execute = fn (
        Definition.Revision,
        Precompile.Entry,
        precompile_runtime.PrecompileCall,
    ) precompile.Error!precompile_runtime.PrecompileOutcome;
    const execute: Execute = Precompile.execute;
    _ = execute;

    if (comptime std.meta.hasFn(Precompile, "active")) {
        const active: bool = Precompile.active(revision, address.zero_address);
        _ = active;
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

/// Assert that one transaction definition's user-provided `Preparation` type
/// satisfies the engine prepare contract. Runs at `TransactionProtocol` bind.
pub fn assertTransactionContract(comptime R: type, comptime transaction_definition: anytype) void {
    const TransactionApi = transaction_protocol.For(transaction_definition.transaction);
    const ProtocolLike = struct {
        pub const Revision = R;
        pub const transaction = transaction_definition.transaction;
        pub const Tx = TransactionApi;
        pub const settlement = transaction_definition.settlement;
        pub const Settlement = tx_settlement.Default;
    };

    const prepare_result_type = @TypeOf(TransactionApi.prepare(
        ProtocolLike,
        @as(*const definition.TransactionPolicy(R), undefined),
        @as(tx.PrepareInput(ProtocolLike), undefined),
    ));
    switch (@typeInfo(prepare_result_type)) {
        .error_union => |info| {
            if (info.payload != tx.PrepareResult(ProtocolLike)) {
                @compileError("Protocol.Tx.prepare must return !transaction.PrepareResult(Protocol)");
            }
        },
        else => @compileError("Protocol.Tx.prepare must return an error union"),
    }
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
