//! Typed transaction-program binding above one reusable Executor branch.
//!
//! The program owns transaction representation and semantics. The binder owns
//! active transaction cleanup and the uncommitted pending state. Family output
//! is stored beside that state, never inside Executor.

const std = @import("std");

const Address = @import("../address.zig").Address;
const block_program = @import("../block_program.zig");
const crypto = @import("../crypto.zig");
const execution = @import("../execution.zig");
const CaptureContext = @import("../executor/capture_context.zig").Context;
const InstrumentationMode = @import("../executor/instrumentation.zig").Mode;
const executor_engine = @import("../executor.zig");
const executor_errors = @import("../executor/error.zig");
const Host = @import("../Host.zig");
const interpreter = @import("../Interpreter.zig");
const state = @import("../state.zig");
const gas = @import("gas.zig");
const runtime_ops = @import("runtime.zig");
const settlement = @import("settlement.zig");
const tx = @import("types.zig");

pub fn TransitionOutcomeType(comptime Output: type, comptime Rejection: type) type {
    return union(enum) {
        rejected: Rejection,
        completed: Output,
    };
}

pub fn TransactOutcomeType(comptime Executed: type, comptime Rejection: type) type {
    return union(enum) {
        rejected: Rejection,
        executed: Executed,
    };
}

pub fn transactInBlock(
    transaction_program: anytype,
    input: anytype,
    mode: InstrumentationMode,
) @TypeOf(transaction_program.transactOwned(input, true, null, mode)) {
    return transaction_program.transactOwned(input, true, null, mode);
}

pub fn transactInBlockWithPrelude(
    transaction_program: anytype,
    input: anytype,
    prelude: anytype,
    mode: InstrumentationMode,
) @TypeOf(transaction_program.transactOwned(input, true, prelude, mode)) {
    return transaction_program.transactOwned(input, true, prelude, mode);
}

/// Type-erased block-prelude transport shared by every program instantiation.
/// Constructed only by `Prelude.init`, which validates the typed `run`
/// signature before erasing it.
pub const PreludeBinding = struct {
    handle: *anyopaque,
    run: *const fn (*anyopaque, *anyopaque) anyerror!void,
};

/// A transition is a constructor: `fn (comptime Context: type) type`. The
/// binder supplies the authoring Context, so the implementation can never
/// disagree with it. The returned type declares exactly one contract member:
///
///   pub fn transact(*Context, Transaction) Error!TransitionOutcomeType(Output, Rejection)
///
/// The signature is the single statement of every carrier; `transitionShape`
/// derives them from the function type alone. The error set must be spelled
/// explicitly — deriving an inferred set would force analysis of the whole
/// transact graph at every instantiation.
pub const TransitionShape = struct {
    Transaction: type,
    Output: type,
    Rejection: type,
    Error: type,
};

fn transitionShape(comptime Context: type, comptime Implementation: type) TransitionShape {
    if (!@hasDecl(Implementation, "transact"))
        @compileError("transition implementation must declare `transact`");
    const info = @typeInfo(@TypeOf(Implementation.transact)).@"fn";
    if (info.params.len != 2 or info.params[0].type.? != *Context)
        @compileError("`transact` must take (*Context, Transaction)");
    const error_union = switch (@typeInfo(info.return_type.?)) {
        .error_union => |value| value,
        else => @compileError("`transact` must return `Error!TransitionOutcomeType(Output, Rejection)`"),
    };
    if (@typeInfo(error_union.payload) != .@"union" or
        !@hasField(error_union.payload, "completed") or
        !@hasField(error_union.payload, "rejected"))
        @compileError("`transact` must return `Error!TransitionOutcomeType(Output, Rejection)`");
    const Output = @FieldType(error_union.payload, "completed");
    const Rejection = @FieldType(error_union.payload, "rejected");
    if (error_union.payload != TransitionOutcomeType(Output, Rejection))
        @compileError("`transact` must return the canonical `TransitionOutcomeType` union");
    return .{
        .Transaction = info.params[1].type.?,
        .Output = Output,
        .Rejection = Rejection,
        .Error = error_union.error_set,
    };
}

/// Reify a transition implementation's signature as a tooling-visible public
/// contract. The implementation remains the single source of truth; these
/// aliases are generated after its function type has been validated.
pub fn BoundTransitionType(comptime ExactContext: type, comptime Implementation: type) type {
    const shape = transitionShape(ExactContext, Implementation);

    return struct {
        pub const Context = ExactContext;
        pub const Transaction = shape.Transaction;
        pub const Output = shape.Output;
        pub const Rejection = shape.Rejection;
        pub const Error = shape.Error;
        pub const transact = Implementation.transact;
    };
}

/// The uniform transition contract: the binder passes the authoring Context
/// in; the constructor returns the implementation bound to it.
pub const TransitionConstructor = fn (comptime type) type;

const FamilyCarrier = enum {
    transaction,
    output,
    rejection,
};

fn familyFields(comptime members: anytype) []const std.builtin.Type.StructField {
    const container = switch (@typeInfo(@TypeOf(members))) {
        .@"struct" => |value| value,
        else => @compileError("family members must be a named tuple of transition constructors"),
    };
    if (container.fields.len < 2 or container.fields.len > 256)
        @compileError("a transaction family must contain between 2 and 256 variants");
    for (container.fields) |field| {
        if (@typeInfo(field.type) != .@"fn")
            @compileError("every family member must be a `fn (comptime Context: type) type` transition constructor");
    }
    return container.fields;
}

fn carrierType(comptime shape: TransitionShape, comptime carrier: FamilyCarrier) type {
    return switch (carrier) {
        .transaction => shape.Transaction,
        .output => shape.Output,
        .rejection => shape.Rejection,
    };
}

fn generatedFamilyUnion(
    comptime fields: []const std.builtin.Type.StructField,
    comptime shapes: []const TransitionShape,
    comptime carrier: FamilyCarrier,
) type {
    var names: [fields.len][]const u8 = undefined;
    var values: [fields.len]u8 = undefined;
    var types: [fields.len]type = undefined;
    var attributes: [fields.len]std.builtin.Type.UnionField.Attributes = undefined;
    for (fields, shapes, 0..) |field, shape, index| {
        names[index] = field.name;
        values[index] = @intCast(index);
        types[index] = carrierType(shape, carrier);
        attributes[index] = .{};
    }
    const Tag = @Enum(u8, .exhaustive, &names, &values);
    return @Union(.auto, Tag, &names, &types, &attributes);
}

fn validateFamilyUnion(
    comptime Family: type,
    comptime fields: []const std.builtin.Type.StructField,
    comptime shapes: []const TransitionShape,
    comptime carrier: FamilyCarrier,
) void {
    const family = switch (@typeInfo(Family)) {
        .@"union" => |value| value,
        else => @compileError("family carriers must be tagged unions"),
    };
    if (family.tag_type == null or family.fields.len != fields.len)
        @compileError("family carrier tags must exactly match the member fields");
    for (fields, shapes) |field, shape| {
        if (!@hasField(Family, field.name))
            @compileError("family carrier is missing the `" ++ field.name ++ "` tag");
        if (@FieldType(Family, field.name) != carrierType(shape, carrier))
            @compileError("family carrier `" ++ field.name ++ "` has the wrong payload type");
    }
}

fn familyImplementation(
    comptime FamilyContext: type,
    comptime members: anytype,
    comptime NamedOutput: type,
    comptime NamedRejection: type,
    comptime NamedError: type,
) type {
    if (!@hasField(FamilyContext.Input, "tx"))
        @compileError("family input must contain a `tx` field");
    const TransactionType = @FieldType(FamilyContext.Input, "tx");

    // Every member is instantiated with the shared family Context, so branch
    // contexts cannot disagree; shapes come from each branch's signature.
    const fields = familyFields(members);
    comptime var shapes: [fields.len]TransitionShape = undefined;
    inline for (fields, 0..) |field, index| {
        shapes[index] = transitionShape(FamilyContext, @field(members, field.name)(FamilyContext));
    }
    const shape_slice: []const TransitionShape = &shapes;
    validateFamilyUnion(TransactionType, fields, shape_slice, .transaction);

    const OutputType = if (NamedOutput == void)
        generatedFamilyUnion(fields, shape_slice, .output)
    else
        NamedOutput;
    const RejectionType = if (NamedRejection == void)
        generatedFamilyUnion(fields, shape_slice, .rejection)
    else
        NamedRejection;
    validateFamilyUnion(OutputType, fields, shape_slice, .output);
    validateFamilyUnion(RejectionType, fields, shape_slice, .rejection);
    comptime var DerivedError: type = error{};
    inline for (shape_slice) |shape| DerivedError = DerivedError || shape.Error;
    const ErrorType = if (NamedError == void) DerivedError else NamedError;
    if (ErrorType != DerivedError)
        @compileError("family `Error` must exactly match the branch error union");

    return struct {
        // Generated carriers, re-declared for tooling; the binder derives the
        // same set from the `transact` signature below.
        pub const Transaction = TransactionType;
        pub const Output = OutputType;
        pub const Rejection = RejectionType;
        pub const Error = ErrorType;

        pub fn transact(
            context: *FamilyContext,
            transaction_value: Transaction,
        ) Error!TransitionOutcomeType(Output, Rejection) {
            return switch (transaction_value) {
                inline else => |branch_transaction, tag| {
                    const name = @tagName(tag);
                    const Branch = @field(members, name)(FamilyContext);
                    return switch (try Branch.transact(context, branch_transaction)) {
                        .rejected => |reason| .{
                            .rejected = @unionInit(Rejection, name, reason),
                        },
                        .completed => |result| .{
                            .completed = @unionInit(Output, name, result),
                        },
                    };
                },
            };
        }
    };
}

/// Compose transition constructors into one family transition constructor.
/// Output and rejection unions are generated from the branch signatures; the
/// transaction union is the family input's declared `tx` type.
pub fn FamilyTransitionType(comptime members: anytype) TransitionConstructor {
    return struct {
        fn bind(comptime Context: type) type {
            return familyImplementation(Context, members, void, void, void);
        }
    }.bind;
}

/// Compose a family over caller-declared output, rejection, and error
/// carriers. Their types are welded to the branch signatures at bind time.
pub fn NamedFamilyTransitionType(
    comptime members: anytype,
    comptime Output: type,
    comptime Rejection: type,
    comptime Error: type,
) TransitionConstructor {
    return struct {
        fn bind(comptime Context: type) type {
            return familyImplementation(Context, members, Output, Rejection, Error);
        }
    }.bind;
}

/// Bind transaction semantics above one transition constructor.
/// Concrete VM types expose this through `VM.Program(...)`.
///
/// The binder constructs the authoring Context from `Executor` and `Input` and
/// instantiates `semantics` with it, so the implementation can never disagree
/// with its Context. The explicit carrier parameters are the single public
/// statement of the program surface; the shape derived from the `transact`
/// signature is welded to them.
pub fn ProgramType(
    comptime ExactExecutor: type,
    comptime Input: type,
    comptime OutputType: type,
    comptime RejectionType: type,
    comptime ErrorType: type,
    comptime semantics: TransitionConstructor,
) type {
    const ExactContext = ContextType(ExactExecutor, Input);
    const Implementation = semantics(ExactContext);
    const shape = transitionShape(ExactContext, Implementation);
    if (shape.Transaction != @FieldType(Input, "tx"))
        @compileError("`transact` must take the type of the input's `tx` field");
    if (shape.Output != OutputType)
        @compileError("`transact` output must match the program output type");
    if (shape.Rejection != RejectionType)
        @compileError("`transact` rejection must match the program rejection type");

    const ContextError = executor_errors.Error;
    const Runtime = RuntimeStateType(ExactExecutor, Input);

    const ProgramError = ContextError || shape.Error;
    if (ErrorType != ProgramError)
        @compileError("transition errors must exactly match the program error type");

    return struct {
        const Self = @This();

        // Keep the public contract on direct comptime parameters. Routing these
        // aliases through `Implementation` makes ZLS lose `vm.transact`'s input
        // and return types even though the compiler can derive both.
        pub const specification = ExactExecutor.specification;
        pub const Executor = ExactExecutor;
        pub const Context = ExactContext;
        pub const Transaction = @FieldType(Input, "tx");
        pub const TransactInput = Input;
        pub const Output = OutputType;
        pub const TransactionLog = Host.Log;
        pub const TransactionLogs = Executor.State.LogView;
        pub const Rejection = RejectionType;
        pub const Executed = Executor.Executed(Output);
        pub const Prelude = PreludeFor(error{});
        pub const PreludeContext = PreludeContextFor(error{});
        pub const Outcome = TransactOutcomeType(Executed, Rejection);
        pub const Error = ErrorType;
        pub const Interpreter = interpreter.Interpreter(specification);
        pub const Gas = gas.Runtime(specification);
        pub const Settlement = settlement.Runtime(specification);

        /// Prelude author context whose error set is widened by one block
        /// implementation's `PreludeError`. Instantiating this never rebuilds
        /// the program itself.
        pub fn PreludeContextFor(comptime PreludeError: type) type {
            return PreludeContextType(Executor, Runtime, PreludeError);
        }

        /// Typed prelude validator matching `PreludeContextFor(PreludeError)`.
        pub fn PreludeFor(comptime PreludeError: type) type {
            return PreludeType(PreludeContextFor(PreludeError));
        }

        pub const Instrumented = struct {
            program: *Self,
            mode: InstrumentationMode,

            pub fn transact(self: Instrumented, input_value: TransactInput) Error!Outcome {
                return @errorCast(self.program.transactOwned(input_value, false, null, self.mode));
            }
        };

        executor: *Executor,

        /// Bind this exact family program to one caller-owned Executor.
        ///
        /// The program borrows the Executor; it owns no state and must not
        /// outlive that Executor.
        pub fn init(executor: *Executor) @This() {
            return .{ .executor = executor };
        }

        /// Close this transaction program over one block-fold policy.
        ///
        /// Env, Included, and Result are decls of the implementation. The
        /// returned type is the only public in-block transaction entry point;
        /// block claims and transaction-runtime choreography stay internal to
        /// that type.
        pub fn Block(comptime BlockImplementation: type) type {
            return block_program.BlockProgramType(Self, BlockImplementation);
        }

        /// Execute one family transaction.
        ///
        /// Rejection opens no pending state. Completion returns the sole
        /// rollback-armed `Executed` owner, which the caller must retain or
        /// discard before reusing this Executor.
        pub fn transact(self: *@This(), input_value: TransactInput) Error!Outcome {
            // No prelude runs outside a block fold, so every possible error
            // is a member of the declared program set.
            return @errorCast(self.transactOwned(input_value, false, null, .normal));
        }

        /// Borrow a transaction facade that records state observations.
        pub fn observe(self: *Self) Instrumented {
            return .{ .program = self, .mode = .observed };
        }

        /// Borrow a transaction facade bound to caller-owned capture storage.
        pub fn capture(self: *Self, context: *CaptureContext) Instrumented {
            return .{ .program = self, .mode = .{ .captured = context } };
        }

        /// Internal error type is open: a block prelude may fail with the
        /// block implementation's own `PreludeError`, which only the block
        /// binder can name. Public entry points narrow with `@errorCast`.
        fn transactOwned(
            self: *@This(),
            input_value: TransactInput,
            block_claimed: bool,
            prelude: ?PreludeBinding,
            mode: InstrumentationMode,
        ) anyerror!Outcome {
            const executor = self.executor;
            if (!block_claimed)
                std.debug.assert(executor.active_block_execution_generation == null);
            std.debug.assert(!executor.hasCurrentTransaction());
            executor.clearLogs();

            var runtime: Runtime = .{
                .executor = executor,
                .input_value = &input_value,
                .mode = mode,
                .prelude = if (prelude) |value| .{ .pending = value } else .none,
            };
            errdefer runtime.discardIfActive();
            var context: Context = .{ .runtime = &runtime };
            const outcome = Implementation.transact(&context, input_value.tx) catch |err| {
                // A recorded prelude failure outranks whatever transport or
                // follow-on error the implementation surfaced.
                if (runtime.preludeFailure()) |prelude_error| return prelude_error;
                return err;
            };
            if (runtime.preludeFailure()) |prelude_error|
                return prelude_error;
            return switch (outcome) {
                .rejected => |reason| blk: {
                    runtime.discardIfActive();
                    break :blk .{ .rejected = reason };
                },
                .completed => |output_value| .{ .executed = .{
                    .executor = executor,
                    .generation = try runtime.complete(),
                    .output_value = output_value,
                } },
            };
        }
    };
}

fn RuntimeStateType(
    comptime Executor: type,
    comptime Input: type,
) type {
    const Error = executor_errors.Error;

    return struct {
        const Self = @This();

        const PreludeState = union(enum) {
            none,
            pending: PreludeBinding,
            consumed,
            failed: anyerror,
        };

        executor: *Executor,
        input_value: *const Input,
        mode: InstrumentationMode,
        prelude: PreludeState = .none,

        fn discardIfActive(self: *Self) void {
            if (!runtime_ops.hasActive(self.executor)) return;
            runtime_ops.discard(self.executor);
        }

        fn complete(self: *Self) Error!u64 {
            std.debug.assert(switch (self.prelude) {
                .none, .consumed => true,
                .pending, .failed => false,
            });
            switch (self.prelude) {
                .pending, .failed => unreachable,
                .none, .consumed => {},
            }
            runtime_ops.requireActive(self.executor);
            return runtime_ops.finish(self.executor);
        }

        fn requireActive(self: *Self) void {
            runtime_ops.requireActive(self.executor);
        }

        fn preludeFailure(self: *const Self) ?anyerror {
            return switch (self.prelude) {
                .failed => |err| err,
                else => null,
            };
        }
    };
}

fn PreludeContextType(
    comptime Executor: type,
    comptime Runtime: type,
    comptime PreludeError: type,
) type {
    const ContextError = executor_errors.Error || PreludeError;

    return struct {
        runtime: *Runtime,

        const Self = @This();

        pub const Error = ContextError;
        pub const specification = Executor.specification;

        fn runtimeState(self: Self) *Runtime {
            return self.runtime;
        }

        pub fn code(self: Self, account_address: Address) ContextError![]const u8 {
            const runtime = self.runtimeState();
            runtime.requireActive();
            return runtime.executor.getCode(account_address) catch |err| return executor_errors.normalize(err);
        }

        pub fn executeRequest(self: Self, request: execution.EvmExecutionRequest) ContextError!execution.ExecutionResult {
            const runtime = self.runtimeState();
            runtime.requireActive();
            return runtime_ops.runPrelude(runtime.executor, request) catch |err| return executor_errors.normalize(err);
        }
    };
}

fn PreludeType(comptime Context: type) type {
    const ContextError = Context.Error;

    return struct {
        pub fn init(pointer: anytype) PreludeBinding {
            const Pointer = @TypeOf(pointer);
            const pointer_info = switch (@typeInfo(Pointer)) {
                .pointer => |info| info,
                else => @compileError("transaction prelude must be initialized from a pointer"),
            };
            if (pointer_info.size != .one)
                @compileError("transaction prelude must use a single-item pointer");
            if (pointer_info.is_const)
                @compileError("transaction prelude pointer must be mutable");

            const actual = @TypeOf(@as(Pointer, undefined).run(@as(Context, undefined)));
            if (actual != ContextError!void)
                @compileError("transaction prelude run has the wrong signature");

            const Adapter = struct {
                fn run(erased: *anyopaque, runtime: *anyopaque) anyerror!void {
                    const typed: Pointer = @ptrCast(@alignCast(erased));
                    return typed.run(Context{ .runtime = @ptrCast(@alignCast(runtime)) });
                }
            };
            return .{
                .handle = @ptrCast(pointer),
                .run = Adapter.run,
            };
        }
    };
}

/// Concrete family-authoring context assembled from flat lexical carriers.
///
/// `Executor` and `Input` are exported so binders can derive every other
/// carrier from a transition's `*Context` parameter alone.
pub fn ContextType(
    comptime ExecutorType: type,
    comptime InputType: type,
) type {
    const ContextError = executor_errors.Error;
    const RuntimeState = RuntimeStateType(ExecutorType, InputType);

    return struct {
        runtime: *RuntimeState,

        const Self = @This();

        pub const Executor = ExecutorType;
        pub const Input = InputType;
        pub const Error = ContextError;
        pub const specification = Executor.specification;

        fn runtimeState(self: *const Self) *RuntimeState {
            return self.runtime;
        }

        /// Borrow the exact caller input for this transaction invocation.
        pub fn input(self: *const Self) *const Input {
            return self.runtimeState().input_value;
        }

        /// Expose the minimal state access required by transaction preparation.
        pub fn preparationState(self: *Self) tx.PreparationStateAccess {
            return .{
                .ptr = self.runtimeState(),
                .vtable = &preparation_state_vtable,
            };
        }

        fn activeExecutor(self: *const Self) *Executor {
            const runtime = self.runtimeState();
            runtime.requireActive();
            return runtime.executor;
        }

        /// Open the one rollback-armed outer transaction lifetime.
        ///
        /// Validation that may reject without state must run first. Prelude,
        /// payload, and settlement effects then share this lifetime.
        pub fn beginTransaction(self: *Self) ContextError!void {
            const runtime = self.runtimeState();
            std.debug.assert(!runtime.executor.hasCurrentTransaction());
            const mode: runtime_ops.Mode = switch (runtime.mode) {
                .normal => .normal,
                .observed => .observed,
                .captured => |capture| .{ .captured = capture },
            };
            runtime_ops.begin(runtime.executor, mode) catch |err|
                return executor_errors.normalize(err);
        }

        /// Borrow the Executor allocator while the transaction is active.
        pub fn allocator(self: *const Self) ContextError!std.mem.Allocator {
            return self.activeExecutor().allocator;
        }

        /// Open an inner rollback checkpoint without resolving the transaction.
        pub fn checkpoint(self: *Self) Executor.ExecutionCheckpoint {
            return self.activeExecutor().checkpoint();
        }

        /// Execute the root payload under its own inner rollback checkpoint.
        ///
        /// A rollback status restores payload effects while preserving earlier
        /// family effects such as nonce advancement.
        pub fn runPayload(
            self: *Self,
            request: execution.EvmExecutionRequest,
        ) ContextError!executor_engine.TransactionExecutionOutcome {
            return runtime_ops.runPayload(self.activeExecutor(), request) catch |err|
                return executor_errors.normalize(err);
        }

        /// Open a custom-family session containing more than one EVM root.
        /// The supplied context establishes the transaction-lifetime extension;
        /// each root may rebind `ORIGIN` through its own request.
        pub fn beginRootSession(
            self: *Self,
            context: execution.ExecutionContext,
        ) ContextError!void {
            return runtime_ops.beginRootSession(self.activeExecutor(), context) catch |err|
                return executor_errors.normalize(err);
        }

        /// Execute one root in the open custom-family session. The full request
        /// context is provisional: only `ORIGIN` may differ from the session,
        /// enforced by the runtime until another consumer justifies a narrower
        /// root-context type.
        pub fn runRoot(
            self: *Self,
            request: execution.EvmExecutionRequest,
            init_value: execution.ExecutionScopeInit,
        ) ContextError!executor_engine.TransactionExecutionOutcome {
            return runtime_ops.runRoot(self.activeExecutor(), request, init_value) catch |err|
                return executor_errors.normalize(err);
        }

        /// Open the root message scope after family prelude work is complete.
        ///
        /// Call exactly once before `runPayload`.
        pub fn beginExecution(
            self: *Self,
            request: execution.EvmExecutionRequest,
            init_value: execution.ExecutionScopeInit,
        ) ContextError!void {
            return runtime_ops.beginExecution(self.activeExecutor(), request, init_value) catch |err|
                return executor_errors.normalize(err);
        }

        /// Read transaction-relevant account metadata from tracked state.
        pub fn accountSummary(
            self: *Self,
            account_address: Address,
        ) ContextError!?state.Account {
            return self.activeExecutor().transactionAccountSummary(account_address) catch |err|
                return executor_errors.normalize(err);
        }

        pub fn code(self: *Self, account_address: Address) ContextError![]const u8 {
            return self.activeExecutor().getCode(account_address) catch |err| return executor_errors.normalize(err);
        }

        pub fn accountAccess(self: *Self, account_address: Address) ContextError!void {
            return self.activeExecutor().traceAccountAccess(account_address) catch |err|
                return executor_errors.normalize(err);
        }

        pub fn touchAccount(self: *Self, account_address: Address) ContextError!void {
            return self.activeExecutor().touchAccount(account_address) catch |err|
                return executor_errors.normalize(err);
        }

        pub fn addBalance(self: *Self, account_address: Address, value: u256) ContextError!void {
            return self.activeExecutor().addBalance(account_address, value) catch |err|
                return executor_errors.normalize(err);
        }

        pub fn subtractBalance(self: *Self, account_address: Address, value: u256) ContextError!bool {
            return self.activeExecutor().subtractBalance(account_address, value) catch |err|
                return executor_errors.normalize(err);
        }

        pub fn setNonce(self: *Self, account_address: Address, nonce: u64) ContextError!void {
            return self.activeExecutor().setNonce(account_address, nonce) catch |err|
                return executor_errors.normalize(err);
        }

        /// Advance the root sender nonce once before payload execution.
        pub fn advanceTransactionNonce(
            self: *Self,
            message: execution.Message,
        ) ContextError!void {
            return self.activeExecutor().advanceTransactionNonce(message) catch |err|
                return executor_errors.normalize(err);
        }

        pub fn setCode(self: *Self, account_address: Address, code_bytes: []const u8) ContextError!void {
            return self.activeExecutor().setCode(account_address, code_bytes) catch |err|
                return executor_errors.normalize(err);
        }

        pub fn clearCode(self: *Self, account_address: Address) ContextError!void {
            return self.activeExecutor().clearCode(account_address) catch |err|
                return executor_errors.normalize(err);
        }

        pub fn warmAccount(self: *Self, account_address: Address) ContextError!void {
            return self.activeExecutor().warmAccount(account_address) catch |err|
                return executor_errors.normalize(err);
        }

        pub fn warmStorage(self: *Self, account_address: Address, key: u256) ContextError!void {
            return self.activeExecutor().warmStorage(account_address, key) catch |err|
                return executor_errors.normalize(err);
        }

        /// Apply the exact specification's end-of-transaction state rules.
        pub fn finalizeState(self: *Self) ContextError!void {
            return self.activeExecutor().finalizeTransactionState() catch |err|
                return executor_errors.normalize(err);
        }

        /// Run the bound block/family prelude at most once.
        ///
        /// Prelude effects share the outer transaction lifetime but execute in
        /// their own fresh message scope.
        pub fn runPrelude(self: *Self) ContextError!void {
            const runtime = self.runtimeState();
            switch (runtime.prelude) {
                .none => return,
                .pending => |binding| {
                    runtime.requireActive();
                    runtime.prelude = .consumed;
                    binding.run(binding.handle, runtime) catch |err| {
                        // The real error is recorded on the runtime and
                        // resurfaced by the binder; this return value only
                        // aborts the implementation and is never observable.
                        runtime.prelude = .{ .failed = err };
                        return error.SystemCallFailed;
                    };
                    runtime.executor.clearLogs();
                    runtime.executor.clearLastOutput();
                },
                .consumed, .failed => unreachable,
            }
        }

        pub fn infrastructureError(_: *const Self, err: anyerror) ContextError {
            return executor_errors.normalize(err);
        }

        fn preparationAccountSummary(ptr: *anyopaque, account_address: Address) !?tx.PreparationAccount {
            const runtime: *RuntimeState = @ptrCast(@alignCast(ptr));
            return runtime.executor.getAccountOrLoad(account_address) catch |err|
                return executor_errors.normalize(err);
        }

        fn preparationCode(ptr: *anyopaque, account_address: Address, expected_hash: [32]u8) ![]const u8 {
            const runtime: *RuntimeState = @ptrCast(@alignCast(ptr));
            const code_bytes = runtime.executor.getCode(account_address) catch |err| return executor_errors.normalize(err);
            if (!std.mem.eql(u8, &crypto.keccak256(code_bytes), &expected_hash))
                return error.CodeHashMismatch;
            return code_bytes;
        }

        const preparation_state_vtable = tx.PreparationStateAccess.VTable{
            .accountSummary = preparationAccountSummary,
            .code = preparationCode,
        };
    };
}
