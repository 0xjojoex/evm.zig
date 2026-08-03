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
const executor_errors = @import("../executor/error.zig");
const Host = @import("../Host.zig");
const state = @import("../state.zig");
const runtime_ops = @import("runtime.zig");
const tx = @import("types.zig");

pub fn TransitionOutcome(comptime Output: type, comptime Rejection: type) type {
    return union(enum) {
        rejected: Rejection,
        completed: Output,
    };
}

pub fn TransactOutcome(comptime Executed: type, comptime Rejection: type) type {
    return union(enum) {
        rejected: Rejection,
        executed: Executed,
    };
}

pub fn transactInBlock(
    transaction_program: anytype,
    input: anytype,
) @TypeOf(transaction_program.transactOwned(input, true, null, .normal)) {
    return transaction_program.transactOwned(input, true, null, .normal);
}

pub fn transactObservedInBlock(
    transaction_program: anytype,
    input: anytype,
) @TypeOf(transaction_program.transactOwned(input, true, null, .observed)) {
    return transaction_program.transactOwned(input, true, null, .observed);
}

pub fn transactInBlockWithPrelude(
    transaction_program: anytype,
    input: anytype,
    prelude: anytype,
) @TypeOf(transaction_program.transactOwned(input, true, prelude, .normal)) {
    return transaction_program.transactOwned(input, true, prelude, .normal);
}

pub fn transactObservedInBlockWithPrelude(
    transaction_program: anytype,
    input: anytype,
    prelude: anytype,
) @TypeOf(transaction_program.transactOwned(input, true, prelude, .observed)) {
    return transaction_program.transactOwned(input, true, prelude, .observed);
}

pub fn transactCapturedInBlockWithPrelude(
    transaction_program: anytype,
    input: anytype,
    prelude: anytype,
    capture: *CaptureContext,
) @TypeOf(transaction_program.transactOwned(input, true, prelude, .{ .captured = capture })) {
    return transaction_program.transactOwned(input, true, prelude, .{ .captured = capture });
}

/// Internal transport caught by the binder and replaced with the concrete
/// block-prelude error before it reaches a program caller.
const ContractError = error{TransactionPreludeFailed};

const TransactionMode = union(enum) {
    normal,
    observed,
    captured: *CaptureContext,
};

/// Bind transaction semantics using flat engine-family and program carriers.
/// Concrete VM types expose this through `VM.Program(...)`.
pub fn bind(
    comptime ExecutorType: type,
    comptime TransactionType: type,
    comptime InputType: type,
    comptime OutputType: type,
    comptime RejectionType: type,
    comptime ImplementationType: type,
) type {
    return bindWithPreludeError(
        ExecutorType,
        TransactionType,
        InputType,
        OutputType,
        RejectionType,
        ImplementationType,
        error{},
    );
}

pub fn bindWithPreludeError(
    comptime ExecutorType: type,
    comptime TransactionType: type,
    comptime InputType: type,
    comptime OutputType: type,
    comptime RejectionType: type,
    comptime ImplementationType: type,
    comptime PreludeErrorType: type,
) type {
    comptime {
        std.debug.assert(@hasField(InputType, "tx"));
        std.debug.assert(@FieldType(InputType, "tx") == TransactionType);
    }
    const ContextType = Context(ExecutorType, InputType);
    comptime validateTransition(ContextType, TransactionType, OutputType, RejectionType, ImplementationType);
    return BoundTransaction(
        ExecutorType,
        ContextType,
        TransactionType,
        InputType,
        OutputType,
        RejectionType,
        ImplementationType,
        PreludeErrorType,
    );
}

fn RuntimeState(
    comptime ExecutorType: type,
    comptime InputType: type,
) type {
    const Error = executor_errors.Error || ContractError;

    return struct {
        const Self = @This();

        const PreludeBinding = struct {
            handle: *anyopaque,
            run: *const fn (*anyopaque, *anyopaque) anyerror!void,
        };

        const PreludeState = union(enum) {
            none,
            pending: PreludeBinding,
            consumed,
            failed: anyerror,
        };

        executor: *ExecutorType,
        input_value: *const InputType,
        mode: TransactionMode,
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

fn PreludeContext(
    comptime ExecutorType: type,
    comptime RuntimeType: type,
    comptime PreludeErrorType: type,
) type {
    const ContextError = executor_errors.Error || ContractError || PreludeErrorType;

    return struct {
        handle: *anyopaque,

        const Self = @This();

        pub const Error = ContextError;
        pub const specification = ExecutorType.specification;

        fn runtimeState(self: Self) *RuntimeType {
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

fn Prelude(comptime ContextType: type) type {
    const ContextError = ContextType.Error;

    return struct {
        handle: *anyopaque,
        run_fn: *const fn (*anyopaque, *anyopaque) anyerror!void,

        pub fn init(pointer: anytype) @This() {
            const Pointer = @TypeOf(pointer);
            const pointer_info = switch (@typeInfo(Pointer)) {
                .pointer => |info| info,
                else => @compileError("transaction prelude must be initialized from a pointer"),
            };
            if (pointer_info.size != .one)
                @compileError("transaction prelude must use a single-item pointer");
            if (pointer_info.is_const)
                @compileError("transaction prelude pointer must be mutable");

            const actual = @TypeOf(@as(Pointer, undefined).run(@as(ContextType, undefined)));
            if (actual != ContextError!void)
                @compileError("transaction prelude run has the wrong signature");

            const Adapter = struct {
                fn run(erased: *anyopaque, runtime: *anyopaque) anyerror!void {
                    const typed: Pointer = @ptrCast(@alignCast(erased));
                    return typed.run(ContextType{ .handle = runtime });
                }
            };
            return .{
                .handle = @ptrCast(pointer),
                .run_fn = Adapter.run,
            };
        }
    };
}

/// Concrete family-authoring context assembled from flat lexical carriers.
pub fn Context(
    comptime ExecutorType: type,
    comptime InputType: type,
) type {
    const ContextError = executor_errors.Error || ContractError;
    const RuntimeType = RuntimeState(ExecutorType, InputType);

    return struct {
        handle: *anyopaque,

        const Self = @This();

        pub const Error = ContextError;
        pub const Executor = ExecutorType;
        pub const specification = ExecutorType.specification;
        pub const Input = InputType;

        fn runtimeState(self: *const Self) *RuntimeType {
            return @ptrCast(@alignCast(self.handle));
        }

        /// Borrow the exact caller input for this transaction invocation.
        pub fn input(self: *const Self) *const InputType {
            return self.runtimeState().input_value;
        }

        /// Expose the minimal state access required by transaction preparation.
        pub fn preparationState(self: *Self) tx.PreparationStateAccess {
            return .{
                .ptr = self.runtimeState(),
                .vtable = &preparation_state_vtable,
            };
        }

        fn activeExecutor(self: *const Self) *ExecutorType {
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
        pub fn checkpoint(self: *Self) ContextError!ExecutorType.ExecutionCheckpoint {
            return self.activeExecutor().checkpoint() catch |err| return executor_errors.normalize(err);
        }

        /// Execute the root payload under its own inner rollback checkpoint.
        ///
        /// A rollback status restores payload effects while preserving earlier
        /// family effects such as nonce advancement.
        pub fn runPayload(
            self: *Self,
            request: execution.EvmExecutionRequest,
        ) ContextError!ExecutorType.TransactionExecutionOutcome {
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
        ) ContextError!?ExecutorType.TransactionAccountSummary {
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
                        runtime.prelude = .{ .failed = err };
                        return error.TransactionPreludeFailed;
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
            const runtime: *RuntimeType = @ptrCast(@alignCast(ptr));
            const account = (runtime.executor.getAccountOrLoad(account_address) catch |err| return executor_errors.normalize(err)) orelse return null;
            return .{
                .nonce = account.nonce,
                .balance = account.balance,
                .code_hash = account.code_hash,
            };
        }

        fn preparationCode(ptr: *anyopaque, account_address: Address, expected_hash: [32]u8) ![]const u8 {
            const runtime: *RuntimeType = @ptrCast(@alignCast(ptr));
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

fn BoundTransaction(
    comptime ExecutorType: type,
    comptime ContextType: type,
    comptime TransactionType: type,
    comptime TransactInputType: type,
    comptime OutputType: type,
    comptime RejectionType: type,
    comptime ImplementationType: type,
    comptime PreludeErrorType: type,
) type {
    const ContextError = executor_errors.Error || ContractError;
    const Runtime = RuntimeState(ExecutorType, TransactInputType);

    const PreludeContextType = PreludeContext(
        ExecutorType,
        Runtime,
        PreludeErrorType,
    );
    const PreludeType = Prelude(PreludeContextType);
    const ProgramError = ContextError || ImplementationType.Error || PreludeErrorType;

    const ExecutedType = ExecutorType.Executed(OutputType);

    const OutcomeType = TransactOutcome(ExecutedType, RejectionType);

    return struct {
        pub const Executor = ExecutorType;
        pub const specification = ExecutorType.specification;
        pub const Context = ContextType;
        pub const Transaction = TransactionType;
        pub const TransactInput = TransactInputType;
        pub const Output = OutputType;
        pub const TransactionLog = Host.Log;
        pub const TransactionLogs = ExecutorType.State.LogView;
        pub const Rejection = RejectionType;
        pub const Executed = ExecutedType;
        pub const Prelude = PreludeType;
        pub const PreludeContext = PreludeContextType;
        pub const Outcome = OutcomeType;
        pub const Error = ProgramError;

        executor: *ExecutorType,

        /// Bind this exact family program to one caller-owned Executor.
        ///
        /// The program borrows the Executor; it owns no state and must not
        /// outlive that Executor.
        pub fn init(executor: *ExecutorType) @This() {
            return .{ .executor = executor };
        }

        /// Close this transaction program over one block-fold policy.
        ///
        /// The returned type is the only public in-block transaction entry
        /// point; block claims and transaction-runtime choreography stay
        /// internal to that type.
        pub fn Block(
            comptime EnvType: type,
            comptime IncludedType: type,
            comptime ResultType: type,
            comptime BlockImplementationType: type,
        ) type {
            const RuntimeWithPrelude = bindWithPreludeError(
                ExecutorType,
                TransactionType,
                TransactInputType,
                OutputType,
                RejectionType,
                ImplementationType,
                PreludeErrorType || BlockImplementationType.PreludeError,
            );
            return block_program.bind(
                RuntimeWithPrelude,
                ExecutorType,
                TransactionType,
                TransactInputType,
                OutputType,
                RejectionType,
                EnvType,
                IncludedType,
                ResultType,
                BlockImplementationType,
            );
        }

        /// Execute one family transaction.
        ///
        /// Rejection opens no pending state. Completion returns the sole
        /// rollback-armed `Executed` owner, which the caller must retain or
        /// discard before reusing this Executor.
        pub fn transact(self: *@This(), input_value: TransactInputType) Error!Outcome {
            return self.transactOwned(input_value, false, null, .normal);
        }

        /// Execute and retain transaction-scoped state observations.
        ///
        /// Observation views belong to the unresolved `Executed` result and
        /// remain borrowed until that result is retained or discarded.
        pub fn transactObserved(self: *@This(), input_value: TransactInputType) Error!Outcome {
            return self.transactOwned(input_value, false, null, .observed);
        }

        /// Execute with caller-owned passive capture storage.
        ///
        /// `capture` must already be active and must outlive execution. The
        /// returned `Executed` value still exclusively resolves state.
        pub fn transactCaptured(
            self: *@This(),
            input_value: TransactInputType,
            capture: *CaptureContext,
        ) Error!Outcome {
            return self.transactOwned(input_value, false, null, .{ .captured = capture });
        }

        fn transactOwned(
            self: *@This(),
            input_value: TransactInputType,
            block_claimed: bool,
            prelude: ?PreludeType,
            mode: TransactionMode,
        ) Error!OutcomeType {
            const executor = self.executor;
            if (!block_claimed)
                std.debug.assert(executor.active_block_execution_generation == null);
            std.debug.assert(!executor.hasCurrentTransaction());
            executor.clearLogs();

            var runtime: Runtime = .{
                .executor = executor,
                .input_value = &input_value,
                .mode = mode,
                .prelude = if (prelude) |value| .{ .pending = .{
                    .handle = value.handle,
                    .run = value.run_fn,
                } } else .none,
            };
            errdefer runtime.discardIfActive();
            var context: ContextType = .{ .handle = &runtime };
            const outcome = ImplementationType.transact(&context, input_value.tx) catch |err| {
                if (err != error.TransactionPreludeFailed) return err;
                std.debug.assert(runtime.preludeFailure() != null);
                const prelude_error = runtime.preludeFailure() orelse unreachable;
                return @errorCast(prelude_error);
            };
            if (runtime.preludeFailure()) |prelude_error|
                return @errorCast(prelude_error);
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

fn validateTransition(
    comptime ContextType: type,
    comptime TransactionType: type,
    comptime OutputType: type,
    comptime RejectionType: type,
    comptime Bound: type,
) void {
    comptime {
        std.debug.assert(@hasDecl(Bound, "Error"));
        // Inspect the function type only; a call expression here would force
        // eager analysis of the whole transact graph at every instantiation.
        const info = @typeInfo(@TypeOf(Bound.transact)).@"fn";
        std.debug.assert(info.params.len == 2);
        std.debug.assert(info.params[0].type.? == *ContextType);
        std.debug.assert(info.params[1].type.? == TransactionType);
        std.debug.assert(info.return_type.? == Bound.Error!TransitionOutcome(OutputType, RejectionType));
    }
}
