//! Typed transaction-program binding above one reusable Executor branch.
//!
//! The program owns transaction representation and semantics. The binder owns
//! active transaction cleanup and the uncommitted pending state. Family output
//! is stored beside that state, never inside Executor.

const std = @import("std");

const Address = @import("../address.zig").Address;
const block = @import("../block.zig");
const crypto = @import("../crypto.zig");
const execution = @import("../execution.zig");
const CaptureContext = @import("../executor/capture_context.zig").Context;
const InstrumentationMode = @import("../executor/instrumentation.zig").Mode;
const executor_engine = @import("../executor.zig");
const executor_errors = @import("../executor/error.zig");
const ExactSpec = @import("../spec.zig").Spec;
const block_state = @import("../vm/block_state.zig");
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

/// Private transport stored by the transaction runtime after a typed prelude
/// binding has crossed the public boundary.
const ErasedPreludeBinding = struct {
    handle: *anyopaque,
    run: *const fn (*anyopaque, *anyopaque) anyerror!void,
};

/// A prelude capability whose identity includes the only extra errors its
/// erased callback may produce.
pub fn PreludeBinding(comptime PreludeError: type) type {
    return struct {
        pub const Error = PreludeError;

        erased: ErasedPreludeBinding,
    };
}

/// Internal transaction-program binder. Callers provide the executor's source
/// inputs and the family's concrete carriers; derived Executor and Context
/// types stay inside the binder.
pub fn ProgramType(
    comptime spec: ExactSpec,
    comptime StateDomain: type,
    comptime compile_options: executor_engine.CompileOptions,
    comptime Input: type,
    comptime Output: type,
    comptime Rejection: type,
    comptime Error: type,
    comptime Family: type,
) type {
    comptime StateDomain.checkSpec(spec);
    const ExactExecutor = executor_engine.ExecutorType(spec, StateDomain, compile_options);
    const ExactContext = ContextTypeWithState(
        spec,
        StateDomain,
        compile_options,
        Input,
    );
    const Runtime = RuntimeStateType(ExactExecutor, Input);
    const ExpectedTransact = fn (
        *ExactContext,
        @FieldType(Input, "tx"),
    ) Error!TransitionOutcomeType(Output, Rejection);
    if (!@hasDecl(Family, "transact") or @TypeOf(Family.transact) != ExpectedTransact)
        @compileError("family must declare `transact(*Context, Transaction) Error!TransitionOutcomeType(Output, Rejection)`");

    return struct {
        const Self = @This();

        pub const Executor = ExactExecutor;
        pub const PreludeContext = PreludeContextFor(error{});
        pub const TransactInput = Input;

        const Context = ExactContext;
        // pub const Transaction = @FieldType(Input, "tx");
        const Executed = Executor.Executed(Output);
        const Outcome = TransactOutcomeType(Executed, Rejection);

        /// Prelude author context whose error set is widened by one block
        /// implementation's `PreludeError`. Instantiating this never rebuilds
        /// the program itself.
        pub fn PreludeContextFor(comptime PreludeError: type) type {
            return PreludeContextType(Executor, Runtime, PreludeError);
        }

        /// Typed prelude validator matching `PreludeContextFor(PreludeError)`.
        pub fn PreludeFor(comptime PreludeError: type) type {
            return PreludeType(PreludeContextFor(PreludeError), PreludeError);
        }

        pub const Instrumented = struct {
            executor: *Executor,
            mode: InstrumentationMode,

            pub fn transact(self: Instrumented, input_value: Input) Error!Outcome {
                return @errorCast(Self.transactOwned(self.executor, input_value, null, null, self.mode));
            }
        };

        /// Execute one family transaction.
        ///
        /// Rejection opens no pending state. Completion returns the sole
        /// rollback-armed `Executed` owner, which the caller must retain or
        /// discard before reusing this Executor.
        pub fn transact(executor: *Executor, input_value: Input) Error!Outcome {
            return @errorCast(Self.transactOwned(executor, input_value, null, null, .normal));
        }

        /// Borrow a transaction facade that records state observations.
        pub fn observe(executor: *Executor) Instrumented {
            return .{ .executor = executor, .mode = .observed };
        }

        /// Borrow a transaction facade bound to caller-owned capture storage.
        pub fn capture(executor: *Executor, context: *CaptureContext) Instrumented {
            return .{ .executor = executor, .mode = .{ .captured = context } };
        }

        pub fn transactInBlock(
            executor: *Executor,
            claim: block.Claim,
            input_value: Input,
            mode: InstrumentationMode,
        ) Error!Outcome {
            return @errorCast(Self.transactOwned(executor, input_value, claim, null, mode));
        }

        pub fn transactInBlockWithPrelude(
            comptime PreludeError: type,
            executor: *Executor,
            claim: block.Claim,
            input_value: Input,
            prelude: PreludeBinding(PreludeError),
            mode: InstrumentationMode,
        ) (Error || PreludeError)!Outcome {
            return @errorCast(Self.transactOwned(executor, input_value, claim, prelude.erased, mode));
        }

        /// One non-generic body for every entry: the erased prelude transports
        /// failures as `anyerror`, and each public wrapper above narrows back to
        /// its audited error set with one `@errorCast`. Keeping the body free of
        /// a `PreludeError` parameter means a chain's non-empty prelude set never
        /// duplicates the validation/preparation/execution machine code.
        fn transactOwned(
            executor: *Executor,
            input_value: Input,
            claim: ?block.Claim,
            prelude: ?ErasedPreludeBinding,
            mode: InstrumentationMode,
        ) anyerror!Outcome {
            if (claim) |active_claim|
                active_claim.requireActive(executor)
            else
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
            const outcome = Family.transact(&context, input_value.tx) catch |err| {
                // A recorded prelude failure outranks whatever transport or
                // follow-on error the implementation surfaced.
                if (runtime.preludeFailure()) |prelude_error| return prelude_error;
                return err;
            };
            if (runtime.preludeFailure()) |prelude_error| return prelude_error;
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
            pending: ErasedPreludeBinding,
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

fn PreludeType(comptime Context: type, comptime PreludeError: type) type {
    const ContextError = Context.Error;
    const BindingType = PreludeBinding(PreludeError);

    return struct {
        pub const Binding = BindingType;

        pub fn init(pointer: anytype) BindingType {
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
                .erased = .{
                    .handle = @ptrCast(pointer),
                    .run = Adapter.run,
                },
            };
        }
    };
}

/// Concrete tracked-state authoring context assembled from source dependencies.
pub fn ContextType(
    comptime spec: ExactSpec,
    comptime compile_options: executor_engine.CompileOptions,
    comptime InputType: type,
) type {
    return ContextTypeWithState(
        spec,
        block_state.Tracked(spec),
        compile_options,
        InputType,
    );
}

/// State-domain form used by exact engines such as the BAL stateless VM.
pub fn ContextTypeWithState(
    comptime spec: ExactSpec,
    comptime StateDomain: type,
    comptime compile_options: executor_engine.CompileOptions,
    comptime InputType: type,
) type {
    comptime StateDomain.checkSpec(spec);
    const ExecutorType = executor_engine.ExecutorType(spec, StateDomain, compile_options);
    const ContextError = executor_errors.Error;
    const RuntimeState = RuntimeStateType(ExecutorType, InputType);

    return struct {
        runtime: *RuntimeState,

        const Self = @This();

        pub const Executor = ExecutorType;
        pub const Input = InputType;
        pub const Error = ContextError;
        pub const Gas = gas.Runtime(spec);
        pub const Settlement = settlement.Runtime(spec);

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
