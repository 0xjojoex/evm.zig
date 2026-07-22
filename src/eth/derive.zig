//! Ethereum-semantic lifting onto a chain-local revision timeline.

const std = @import("std");

const address = @import("../address.zig");
const definition = @import("../definition.zig");
const precompile_mod = @import("../precompile.zig");
const precompile_runtime = @import("../execution/precompile_runtime.zig");
const instruction_mod = @import("../protocol/instruction.zig");
const opcode_info = @import("../opcode.zig");
const protocol_dispatcher = @import("../protocol/dispatcher.zig");
const protocol_types = @import("../protocol/types.zig");
const support = @import("../protocol/support.zig");
const transaction = @import("../transaction.zig");
const vm = @import("../vm.zig");
const config = @import("config.zig");
const instruction = @import("instruction.zig");
const precompile = @import("precompile.zig");
const revision = @import("revision.zig");

const canonical = config.canonical;
const CanonicalExecution = definition.ExecutionModel(canonical.execution);

/// Same-timeline Ethereum extension options. Use `derive` when the family owns
/// a different revision enum and maps it onto Ethereum history.
pub const ExtendOptions = struct {
    support: CanonicalExecution.Support = .all,
    dispatch: protocol_dispatcher.DispatchConfig = .{},
    execution: config.ExecutionOptions(revision.Revision) = .{},
    transaction: config.TransactionOptions(revision.Revision) = .{},
    settlement: config.SettlementOptions(revision.Revision) = .{},
    authorization: config.AuthorizationOptions(revision.Revision) = .{},
    block: config.BlockOptions(revision.Revision) = .{},
};

/// Extend the canonical Ethereum revision timeline without exposing the raw
/// generic VM constructor or reauthoring inherited Ethereum semantics.
pub fn extend(comptime options: ExtendOptions) type {
    const resolved = config.resolveExtension(.{
        .execution = options.execution,
        .transaction = options.transaction,
        .settlement = options.settlement,
        .authorization = options.authorization,
        .block = options.block,
    });
    return vm.compile(
        revision.Revision,
        resolved,
        options.support,
        options.dispatch,
    );
}

/// Ethereum-derived family options. Structural transaction and block programs
/// compose through `Transition`, `Program`, and `Program.Block`.
pub fn Options(comptime Revisions: type) type {
    const R = Revisions.Revision;
    return struct {
        base_revision: *const fn (R) revision.Revision,
        /// Semantic overrides use the same typed vocabulary as direct
        /// `eth.extend` and are applied after Ethereum lifting.
        execution: config.ExecutionOptions(R) = .{},
        transaction: config.TransactionOptions(R) = .{},
        settlement: config.SettlementOptions(R) = .{},
        authorization: config.AuthorizationOptions(R) = .{},
        block: config.BlockOptions(R) = .{},
    };
}

/// Return the ordinary concrete generated VM surface for a local revision
/// model whose unchanged semantics are inherited from Ethereum.
pub fn derive(comptime Revisions: type, comptime options: Options(Revisions)) type {
    const R = Revisions.Revision;
    const resolved = config.applyOverrides(
        R,
        liftedRules(Revisions, options),
        semanticOptions(Revisions, options),
    );
    validateResolution(Revisions, options, resolved.execution.revision);
    return vm.compile(
        R,
        resolved,
        .all,
        .{},
    );
}

fn semanticOptions(
    comptime Revisions: type,
    comptime options: Options(Revisions),
) config.SemanticOptions(Revisions.Revision) {
    return .{
        .execution = options.execution,
        .transaction = options.transaction,
        .settlement = options.settlement,
        .authorization = options.authorization,
        .block = options.block,
    };
}

fn liftedRules(
    comptime Revisions: type,
    comptime options: Options(Revisions),
) config.Resolved(Revisions.Revision) {
    const R = Revisions.Revision;
    return .{
        .execution = liftedExecution(Revisions, options),
        .transaction = liftedTransaction(Revisions, options),
        .block = liftConfig(R, options.base_revision, canonical.block, definition.BlockConfig(R)),
    };
}

fn liftedExecution(
    comptime Revisions: type,
    comptime options: Options(Revisions),
) definition.ExecutionRules(Revisions.Revision) {
    const R = Revisions.Revision;
    const base = canonical.execution;
    return .{
        .name = "ethereum-derived",
        .revision = .{
            .revisions = Revisions.revisions,
            .latest = Revisions.latest,
            .stable = Revisions.stable,
            .order = Revisions.order,
            .semantics = RevisionSemantics(R, options.base_revision),
        },
        .instruction = LiftedInstruction(R, options.base_revision),
        .value_transfer_log = liftRevisionFunction(
            R,
            options.base_revision,
            base.value_transfer_log,
            *const fn (R, protocol_types.ValueTransferInput) ?protocol_types.ValueTransferLog,
        ),
        .call = liftConfig(R, options.base_revision, base.call, definition.CallConfig(R)),
        .create = liftConfig(R, options.base_revision, base.create, definition.CreateConfig(R)),
        .storage = liftConfig(R, options.base_revision, base.storage, definition.StorageConfig(R)),
        .self_destruct = liftConfig(R, options.base_revision, base.self_destruct, definition.SelfDestructConfig(R)),
        .precompile = LiftedPrecompile(R, options.base_revision),
    };
}

fn liftedTransaction(
    comptime Revisions: type,
    comptime options: Options(Revisions),
) definition.TransactionLayerRules(Revisions.Revision) {
    const R = Revisions.Revision;
    const base = canonical.transaction;
    return comptime .{
        .transaction = liftConfig(R, options.base_revision, base.transaction, definition.TransactionConfig(R)),
        .settlement = liftConfig(R, options.base_revision, base.settlement, definition.SettlementConfig(R)),
        .authorization = liftConfig(R, options.base_revision, base.authorization, definition.AuthorizationConfig(R)),
    };
}

fn validateResolution(
    comptime Revisions: type,
    comptime options: Options(Revisions),
    comptime revision_config: definition.RevisionConfig(Revisions.Revision),
) void {
    const R = Revisions.Revision;
    const Model = definition.RevisionModel(R, revision_config);
    if (firstBaseRevisionRegression(R, Model.revisions, options.base_revision)) |index| {
        const current = Model.revisions[index];
        const previous = Model.revisions[index - 1];
        const previous_base = options.base_revision(previous);
        const current_base = options.base_revision(current);
        @compileError("eth.derive base_revision must be non-decreasing: " ++
            @tagName(previous) ++ " -> " ++ @tagName(previous_base) ++ ", " ++
            @tagName(current) ++ " -> " ++ @tagName(current_base));
    }
}

fn firstBaseRevisionRegression(
    comptime R: type,
    comptime revisions: []const R,
    comptime map: *const fn (R) revision.Revision,
) ?usize {
    inline for (revisions[1..], 1..) |current, index| {
        if (map(current).order(map(revisions[index - 1])) == .lt) return index;
    }
    return null;
}

fn RevisionSemantics(
    comptime R: type,
    comptime map: *const fn (R) revision.Revision,
) type {
    return struct {
        pub const BaseRevision = revision.Revision;

        pub fn baseRevision(local_revision: R) BaseRevision {
            return map(local_revision);
        }
    };
}

/// Lift every field of a semantic config. A new field becomes a compile error
/// unless it is another revision-first function supported by the adapter or a
/// deliberately copied type field.
fn liftConfig(
    comptime R: type,
    comptime map: *const fn (R) revision.Revision,
    comptime source: anytype,
    comptime Target: type,
) Target {
    const Source = @TypeOf(source);
    var result: Target = undefined;

    inline for (std.meta.fields(Target)) |field| {
        if (!@hasField(Source, field.name)) {
            @compileError("Ethereum semantic lifter source is missing field: " ++ field.name);
        }
        const source_value = @field(source, field.name);
        switch (@typeInfo(field.type)) {
            .type => @field(result, field.name) = source_value,
            .pointer => @field(result, field.name) = liftRevisionFunction(
                R,
                map,
                source_value,
                field.type,
            ),
            else => @compileError("Ethereum semantic lifter cannot adapt field: " ++ field.name),
        }
    }

    inline for (std.meta.fields(Source)) |field| {
        if (!@hasField(Target, field.name)) {
            @compileError("Ethereum semantic lifter target is missing field: " ++ field.name);
        }
    }
    return result;
}

fn liftRevisionFunction(
    comptime R: type,
    comptime map: *const fn (R) revision.Revision,
    comptime source: anytype,
    comptime Target: type,
) Target {
    const target_pointer = switch (@typeInfo(Target)) {
        .pointer => |pointer| pointer,
        else => @compileError("Ethereum semantic lifter target field must be a function pointer"),
    };
    const source_pointer = switch (@typeInfo(@TypeOf(source))) {
        .pointer => |pointer| pointer,
        else => @compileError("Ethereum semantic lifter source field must be a function pointer"),
    };
    const target_fn = switch (@typeInfo(target_pointer.child)) {
        .@"fn" => |function| function,
        else => @compileError("Ethereum semantic lifter target field must point to a function"),
    };
    const source_fn = switch (@typeInfo(source_pointer.child)) {
        .@"fn" => |function| function,
        else => @compileError("Ethereum semantic lifter source field must point to a function"),
    };

    if (target_fn.params.len != source_fn.params.len or target_fn.params.len == 0) {
        @compileError("Ethereum semantic lifter requires matching revision-first functions");
    }
    if (target_fn.params[0].type.? != R or source_fn.params[0].type.? != revision.Revision) {
        @compileError("Ethereum semantic lifter requires LocalRevision and eth.Revision first parameters");
    }
    if (target_fn.return_type.? != source_fn.return_type.?) {
        @compileError("Ethereum semantic lifter cannot change a semantic function return type");
    }
    inline for (target_fn.params[1..], source_fn.params[1..]) |target_param, source_param| {
        if (target_param.type.? != source_param.type.?) {
            @compileError("Ethereum semantic lifter cannot change semantic input types");
        }
    }

    const Return = target_fn.return_type.?;
    return switch (target_fn.params.len) {
        1 => struct {
            fn call(local_revision: R) Return {
                return source(map(local_revision));
            }
        }.call,
        2 => blk: {
            const A = target_fn.params[1].type.?;
            break :blk struct {
                fn call(local_revision: R, a: A) Return {
                    return source(map(local_revision), a);
                }
            }.call;
        },
        3 => blk: {
            const A = target_fn.params[1].type.?;
            const B = target_fn.params[2].type.?;
            break :blk struct {
                fn call(local_revision: R, a: A, b: B) Return {
                    return source(map(local_revision), a, b);
                }
            }.call;
        },
        else => @compileError("Ethereum semantic lifter needs an adapter for this function arity"),
    };
}

fn LiftedInstruction(
    comptime R: type,
    comptime map: *const fn (R) revision.Revision,
) type {
    const Base = instruction.Instruction;
    const Availability = union(enum) {
        never,
        always,
        since: R,
        gate: *const fn (R) bool,
    };

    return struct {
        pub const Value = Base.Value;

        pub fn fromByte(comptime opcode_byte: u8) Value {
            return Base.fromByte(opcode_byte);
        }

        pub fn context(comptime value: Value) instruction_mod.Context {
            return Base.context(value);
        }

        pub fn info(comptime value: Value) opcode_info.OpInfo {
            return Base.info(value);
        }

        pub fn availability(comptime value: Value) Availability {
            return switch (Base.availability(value)) {
                .never => .never,
                .always => .always,
                .since => |base_revision| .{ .gate = SinceGate(R, map, base_revision).active },
                .gate => |active| .{ .gate = LiftedGate(R, map, active).active },
            };
        }

        pub fn tier(comptime value: Value) support.OpcodeTier {
            return Base.tier(value);
        }

        pub fn executionTarget(comptime value: Value) @import("../protocol/execution.zig").ExecutionTarget {
            return Base.executionTarget(value);
        }

        pub fn staticGasForRevisionByte(local_revision: R, comptime opcode_byte: u8) i64 {
            return instruction.staticGasForRevisionByte(map(local_revision), opcode_byte);
        }

        pub fn expByteGas(local_revision: R) i64 {
            return Base.expByteGas(map(local_revision));
        }

        pub fn accountReadColdAccessGas(local_revision: R) ?i64 {
            return Base.accountReadColdAccessGas(map(local_revision));
        }

        pub fn codeAccountAccessGas(local_revision: R, status: protocol_types.AccountAccessStatus) ?i64 {
            return Base.codeAccountAccessGas(map(local_revision), status);
        }
    };
}

fn SinceGate(
    comptime R: type,
    comptime map: *const fn (R) revision.Revision,
    comptime since: revision.Revision,
) type {
    return struct {
        fn active(local_revision: R) bool {
            return map(local_revision).isImpl(since);
        }
    };
}

fn LiftedGate(
    comptime R: type,
    comptime map: *const fn (R) revision.Revision,
    comptime base_gate: *const fn (revision.Revision) bool,
) type {
    return struct {
        fn active(local_revision: R) bool {
            return base_gate(map(local_revision));
        }
    };
}

fn LiftedPrecompile(
    comptime R: type,
    comptime map: *const fn (R) revision.Revision,
) type {
    return struct {
        pub const Entry = precompile.Entry;

        pub fn resolve(local_revision: R, target: address.Address) ?Entry {
            return precompile.resolve(map(local_revision), target);
        }

        pub fn active(local_revision: R, target: address.Address) bool {
            return precompile.active(map(local_revision), target);
        }

        pub fn execute(
            local_revision: R,
            entry: Entry,
            call: precompile_runtime.PrecompileCall,
        ) precompile_mod.Error!precompile_runtime.PrecompileOutcome {
            return precompile.execute(map(local_revision), entry, call);
        }
    };
}

test "derived family lifts Ethereum semantics onto a local revision timeline" {
    const LocalRevision = enum {
        prague,
        prague_patch,

        const Self = @This();

        pub fn order(self: Self, other: Self) std.math.Order {
            return std.math.order(@intFromEnum(self), @intFromEnum(other));
        }

        pub const isImpl = revision.Model(Self).isImpl;
    };
    const LocalRevisions = revision.Model(LocalRevision);
    const Base = struct {
        fn map(_: LocalRevision) revision.Revision {
            return .prague;
        }
    };
    const Derived = derive(LocalRevisions, .{
        .base_revision = Base.map,
    });
    const Input = struct {
        env: vm.Env,
        tx: Derived.Transaction,
        progress: transaction.PreparationBlockProgress = .{},
    };
    const Transition = Derived.Transition(Input);

    try std.testing.expectEqual(revision.Revision, Derived.BaseRevision);
    try std.testing.expectEqual(revision.Revision.prague, Derived.baseRevision(.prague));
    try std.testing.expectEqual(revision.Revision.prague, Derived.baseRevision(.prague_patch));
    try std.testing.expect(LocalRevision.prague_patch.isImpl(.prague));
    try std.testing.expect(Derived.ExecutionProtocol.isImpl(.prague_patch, .prague));
    try std.testing.expect(!Derived.ExecutionProtocol.isImpl(.prague, .prague_patch));
    try std.testing.expectEqual(
        instruction.staticGasForRevision(.prague, .BALANCE),
        Derived.Instruction.staticGasForRevision(.prague, Derived.Instruction.fromByte(@intFromEnum(opcode_info.Opcode.BALANCE))),
    );
    try std.testing.expect(Derived.TransactionProtocol.authorization.active(.prague));
    try std.testing.expect(Derived.ExecutionProtocol.Precompile.active(
        .prague,
        precompile.Entry.bls12_g1add.toAddress(),
    ));
    try std.testing.expect(@hasDecl(Transition, "transact"));
}

test "Ethereum semantic overrides apply after revision lifting" {
    const LocalRevision = enum {
        candidate,

        const Self = @This();

        pub fn order(self: Self, other: Self) std.math.Order {
            return std.math.order(@intFromEnum(self), @intFromEnum(other));
        }
    };
    const LocalRevisions = revision.Model(LocalRevision);
    const Base = struct {
        fn map(_: LocalRevision) revision.Revision {
            return .prague;
        }
    };
    const Override = struct {
        fn createCodeSizeLimit(_: LocalRevision) ?usize {
            return 1234;
        }

        fn totalGasLimit(_: LocalRevision) ?u64 {
            return 123;
        }

        fn gasRefundCapDivisor(_: LocalRevision) u64 {
            return 7;
        }

        fn authorizationActive(_: LocalRevision) bool {
            return false;
        }

        fn beforeBlock(_: LocalRevision, _: protocol_types.BeforeBlockContext) protocol_types.BlockSystemCalls {
            var calls = protocol_types.BlockSystemCalls{};
            calls.append(.{
                .sender = address.addr(0x100),
                .recipient = address.addr(0x200),
                .gas = 1,
            });
            return calls;
        }
    };
    const options: Options(LocalRevisions) = .{
        .base_revision = Base.map,
        .execution = .{
            .name = "derived-override",
            .create = .{ .createCodeSizeLimit = Override.createCodeSizeLimit },
        },
        .transaction = .{ .totalGasLimit = Override.totalGasLimit },
        .settlement = .{ .gasRefundCapDivisor = Override.gasRefundCapDivisor },
        .authorization = .{ .active = Override.authorizationActive },
        .block = .{ .beforeBlock = Override.beforeBlock },
    };
    const execution_rules = config.applyOverrides(
        LocalRevision,
        liftedRules(LocalRevisions, options),
        semanticOptions(LocalRevisions, options),
    ).execution;
    const Derived = derive(LocalRevisions, options);

    try std.testing.expectEqualStrings("derived-override", execution_rules.name);
    try std.testing.expectEqual(
        @as(?usize, 1234),
        Derived.ExecutionProtocol.create.createCodeSizeLimit(.candidate),
    );
    try std.testing.expectEqual(
        @as(?u64, 123),
        Derived.TransactionProtocol.transaction.totalGasLimit(.candidate),
    );
    try std.testing.expectEqual(
        @as(u64, 7),
        Derived.TransactionProtocol.settlement.gasRefundCapDivisor(.candidate),
    );
    try std.testing.expect(!Derived.TransactionProtocol.authorization.active(.candidate));
    try std.testing.expectEqual(
        @as(usize, 1),
        Derived.block_policy.beforeBlock(.candidate, .{
            .number = 0,
            .timestamp = 0,
        }).slice().len,
    );
}

test "base revision mapping detects a decreasing local timeline" {
    const LocalRevision = enum {
        first,
        second,

        const Self = @This();

        pub fn order(self: Self, other: Self) std.math.Order {
            return std.math.order(@intFromEnum(self), @intFromEnum(other));
        }
    };
    const Decreasing = struct {
        fn map(local_revision: LocalRevision) revision.Revision {
            return switch (local_revision) {
                .first => .prague,
                .second => .shanghai,
            };
        }
    };

    try std.testing.expectEqual(
        @as(?usize, 1),
        firstBaseRevisionRegression(
            LocalRevision,
            &.{ .first, .second },
            Decreasing.map,
        ),
    );
}
