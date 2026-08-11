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
const state = @import("../state.zig");
const runtime_ops = @import("runtime.zig");
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

/// Weld a transition implementation's carrier decls to its `transact`
/// signature. Decls are the tooling-visible truth; the signature must agree.
/// Only the function type is inspected; a call expression here would force
/// eager analysis of the whole transact graph at every instantiation.
fn validateTransition(comptime Implementation: type) void {
    inline for (.{ "Context", "Transaction", "Output", "Rejection", "Error" }) |name| {
        if (!@hasDecl(Implementation, name))
            @compileError("transition implementation must declare `" ++ name ++ "`");
    }
    const Context = Implementation.Context;
    if (!@hasDecl(Context, "Executor") or !@hasDecl(Context, "Input") or
        Context != ContextType(Context.Executor, Context.Input))
        @compileError("`Context` must come from `Vm.Context(Input)`");
    if (!@hasField(Context.Input, "tx") or
        @FieldType(Context.Input, "tx") != Implementation.Transaction)
        @compileError("`Transaction` must be the type of the input's `tx` field");
    const info = @typeInfo(@TypeOf(Implementation.transact)).@"fn";
    if (info.params.len != 2 or
        info.params[0].type.? != *Context or
        info.params[1].type.? != Implementation.Transaction)
        @compileError("`transact` must take (*Context, Transaction)");
    if (info.return_type.? != Implementation.Error!TransitionOutcomeType(
        Implementation.Output,
        Implementation.Rejection,
    ))
        @compileError("`transact` must return `Error!TransitionOutcomeType(Output, Rejection)`");
}

/// Bind transaction semantics above one transition implementation.
/// Concrete VM types expose this through `VM.Program(...)`.
///
/// The implementation declares its carriers — `Context`, `Transaction`
/// (`Input.tx`), `Output`, `Rejection`, `Error` — and `validateTransition`
/// welds its `transact` signature to them.
pub fn ProgramType(comptime Implementation: type) type {
    comptime validateTransition(Implementation);

    const ContextError = executor_errors.Error;
    const Runtime = RuntimeStateType(Implementation.Context.Executor, Implementation.Context.Input);

    const ProgramError = ContextError || Implementation.Error;

    return struct {
        const Self = @This();

        pub const specification = Executor.specification;
        pub const Executor = Implementation.Context.Executor;
        pub const Context = Implementation.Context;
        pub const Transaction = Implementation.Transaction;
        pub const TransactInput = Implementation.Context.Input;
        pub const Output = Implementation.Output;
        pub const TransactionLog = Host.Log;
        pub const TransactionLogs = Executor.State.LogView;
        pub const Rejection = Implementation.Rejection;
        pub const Executed = Executor.Executed(Output);
        pub const Prelude = PreludeFor(error{});
        pub const PreludeContext = PreludeContextFor(error{});
        pub const Outcome = TransactOutcomeType(Executed, Rejection);
        pub const Error = ProgramError;

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
            var context: Context = .{ .handle = &runtime };
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
        handle: *anyopaque,

        const Self = @This();

        pub const Error = ContextError;
        pub const specification = Executor.specification;

        fn runtimeState(self: Self) *Runtime {
            return @ptrCast(@alignCast(self.handle));
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
                    return typed.run(Context{ .handle = runtime });
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
        handle: *anyopaque,

        const Self = @This();

        pub const Executor = ExecutorType;
        pub const Input = InputType;
        pub const Error = ContextError;
        pub const specification = Executor.specification;

        fn runtimeState(self: *const Self) *RuntimeState {
            return @ptrCast(@alignCast(self.handle));
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
            return self.activeExecutor().state.touchAccount(account_address) catch |err|
                return executor_errors.normalize(err);
        }

        pub fn addBalance(self: *Self, account_address: Address, value: u256) ContextError!void {
            return self.activeExecutor().state.addBalance(account_address, value) catch |err|
                return executor_errors.normalize(err);
        }

        pub fn subtractBalance(self: *Self, account_address: Address, value: u256) ContextError!bool {
            return self.activeExecutor().state.subtractBalance(account_address, value) catch |err|
                return executor_errors.normalize(err);
        }

        pub fn setNonce(self: *Self, account_address: Address, nonce: u64) ContextError!void {
            return self.activeExecutor().state.setNonce(account_address, nonce) catch |err|
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
            return self.activeExecutor().state.setCode(account_address, code_bytes) catch |err|
                return executor_errors.normalize(err);
        }

        pub fn clearCode(self: *Self, account_address: Address) ContextError!void {
            return self.activeExecutor().state.clearCode(account_address) catch |err|
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
