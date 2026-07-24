//! Typed transaction-program binding above one reusable Executor branch.
//!
//! The program owns transaction representation and semantics. The binder owns
//! attempt cleanup and the uncommitted pending state. Family output is stored
//! beside that state, never inside Executor.

const std = @import("std");

const Address = @import("../address.zig").Address;
const block_program = @import("../block_program.zig");
const crypto = @import("../crypto.zig");
const execution = @import("../execution.zig");
const CaptureContext = @import("../executor/capture_context.zig").Context;
const executor_errors = @import("../executor/error.zig");
const Host = @import("../Host.zig");
const Interpreter = @import("../Interpreter.zig");
const state = @import("../state.zig");
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

/// Internal transport caught by the binder and replaced with the concrete
/// block-prelude error before it reaches a program caller.
const ContractError = error{TransactionPreludeFailed};

const AttemptMode = union(enum) {
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
        error{},
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
        mode: AttemptMode,
        attempt: ?ExecutorType.TransactionAttempt = null,
        prelude: PreludeState = .none,

        fn discardIfActive(self: *Self) void {
            const attempt = self.attempt orelse return;
            attempt.discardIfCurrent();
            self.attempt = null;
        }

        fn complete(self: *Self) Error!ExecutorType.Pending {
            std.debug.assert(switch (self.prelude) {
                .none, .consumed => true,
                .pending, .failed => false,
            });
            switch (self.prelude) {
                .pending, .failed => unreachable,
                .none, .consumed => {},
            }
            std.debug.assert(self.attempt != null);
            const attempt = self.attempt orelse unreachable;
            const executed = attempt.finish();
            self.attempt = null;
            return executed;
        }

        fn preludeFailure(self: *const Self) ?anyerror {
            return switch (self.prelude) {
                .failed => |err| err,
                else => null,
            };
        }
    };
}

fn AttemptType(
    comptime ExecutorType: type,
    comptime Runtime: type,
) type {
    const Error = executor_errors.Error || ContractError;

    return struct {
        handle: *anyopaque,

        const Self = @This();

        pub const TransactionNonceIntent = struct {
            inner: ExecutorType.TransactionAttempt.TransactionNonceIntent,

            pub fn complete(self: TransactionNonceIntent) void {
                self.inner.complete();
            }
        };

        fn runtimeState(self: Self) *Runtime {
            return @ptrCast(@alignCast(self.handle));
        }

        fn token(self: Self) ExecutorType.TransactionAttempt {
            return self.runtimeState().attempt orelse unreachable;
        }

        pub fn allocator(self: Self) Error!std.mem.Allocator {
            return self.token().allocator();
        }

        pub fn checkpoint(self: Self) Error!ExecutorType.ExecutionCheckpoint {
            return self.token().checkpoint() catch |err| return executor_errors.normalize(err);
        }

        pub fn executeRequest(self: Self, request: execution.EvmExecutionRequest) Error!Interpreter.Result {
            return self.token().executeRequest(request) catch |err| return executor_errors.normalize(err);
        }

        pub fn executeRequestPhased(
            self: Self,
            request: execution.EvmExecutionRequest,
        ) Error!ExecutorType.TransactionExecutionOutcome {
            return self.token().executeRequestPhased(request) catch |err| return executor_errors.normalize(err);
        }

        pub fn runPayload(
            self: Self,
            request: execution.EvmExecutionRequest,
        ) Error!ExecutorType.TransactionExecutionOutcome {
            return self.token().runPayload(request) catch |err| return executor_errors.normalize(err);
        }

        pub fn beginExecution(
            self: Self,
            request: execution.EvmExecutionRequest,
            init_value: execution.ExecutionScopeInit,
        ) Error!void {
            return self.token().beginExecution(request, init_value) catch |err| return executor_errors.normalize(err);
        }

        pub fn accountSummary(self: Self, account_address: Address) Error!?ExecutorType.TransactionAttempt.AccountSummary {
            return self.token().accountSummary(account_address) catch |err| return executor_errors.normalize(err);
        }

        pub fn code(self: Self, account_address: Address) Error![]const u8 {
            return self.token().code(account_address) catch |err| return executor_errors.normalize(err);
        }

        pub fn balance(self: Self, account_address: Address) Error!u256 {
            return self.token().balance(account_address) catch |err| return executor_errors.normalize(err);
        }

        pub fn accountAccess(self: Self, account_address: Address) Error!void {
            return self.token().accountAccess(account_address) catch |err| return executor_errors.normalize(err);
        }

        pub fn touchAccount(self: Self, account_address: Address) Error!void {
            return self.token().touchAccount(account_address) catch |err| return executor_errors.normalize(err);
        }

        pub fn addBalance(self: Self, account_address: Address, value: u256) Error!void {
            return self.token().addBalance(account_address, value) catch |err| return executor_errors.normalize(err);
        }

        pub fn subtractBalance(self: Self, account_address: Address, value: u256) Error!bool {
            return self.token().subtractBalance(account_address, value) catch |err| return executor_errors.normalize(err);
        }

        pub fn setNonce(self: Self, account_address: Address, nonce: u64) Error!void {
            return self.token().setNonce(account_address, nonce) catch |err| return executor_errors.normalize(err);
        }

        pub fn incrementNonce(self: Self, account_address: Address) Error!void {
            return self.token().incrementNonce(account_address) catch |err| return executor_errors.normalize(err);
        }

        pub fn advanceTransactionNonce(
            self: Self,
            message: execution.Message,
        ) Error!TransactionNonceIntent {
            const intent = self.token().advanceTransactionNonce(message) catch |err|
                return executor_errors.normalize(err);
            return .{ .inner = intent };
        }

        pub fn setCode(self: Self, account_address: Address, code_bytes: []const u8) Error!void {
            return self.token().setCode(account_address, code_bytes) catch |err| return executor_errors.normalize(err);
        }

        pub fn clearCode(self: Self, account_address: Address) Error!void {
            return self.token().clearCode(account_address) catch |err| return executor_errors.normalize(err);
        }

        pub fn warmAccount(self: Self, account_address: Address) Error!void {
            return self.token().warmAccount(account_address) catch |err| return executor_errors.normalize(err);
        }

        pub fn warmStorage(self: Self, account_address: Address, key: u256) Error!void {
            return self.token().warmStorage(account_address, key) catch |err| return executor_errors.normalize(err);
        }

        pub fn finalizeState(self: Self) Error!void {
            return self.token().finalizeState() catch |err| return executor_errors.normalize(err);
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

        fn token(self: Self) ExecutorType.TransactionAttempt {
            return self.runtimeState().attempt orelse unreachable;
        }

        pub fn code(self: Self, account_address: Address) ContextError![]const u8 {
            return self.token().code(account_address) catch |err| return executor_errors.normalize(err);
        }

        pub fn executeRequest(self: Self, request: execution.EvmExecutionRequest) ContextError!Interpreter.Result {
            return self.token().executePreludeRequest(request) catch |err| return executor_errors.normalize(err);
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
    const Attempt = AttemptType(ExecutorType, RuntimeType);

    return struct {
        handle: *anyopaque,

        const Self = @This();

        pub const Error = ContextError;
        pub const Executor = ExecutorType;
        pub const specification = ExecutorType.specification;
        pub const Input = InputType;
        pub const AttemptCapability = Attempt;

        fn runtimeState(self: *const Self) *RuntimeType {
            return @ptrCast(@alignCast(self.handle));
        }

        pub fn input(self: *const Self) *const InputType {
            return self.runtimeState().input_value;
        }

        pub fn preparationState(self: *Self) tx.PreparationStateAccess {
            return .{
                .ptr = self.runtimeState(),
                .vtable = &preparation_state_vtable,
            };
        }

        pub fn beginAttempt(self: *Self) ContextError!Attempt {
            const runtime = self.runtimeState();
            std.debug.assert(runtime.attempt == null);
            runtime.attempt = switch (runtime.mode) {
                .normal => runtime.executor.beginTransactionAttemptLifetime(),
                .observed => runtime.executor.beginObservedTransactionAttemptLifetime(),
                .captured => |capture| runtime.executor.beginCapturedTransactionAttemptLifetime(capture),
            } catch |err| return executor_errors.normalize(err);
            return .{ .handle = runtime };
        }

        pub fn activeAttempt(self: *Self) ContextError!Attempt {
            const runtime = self.runtimeState();
            std.debug.assert(runtime.attempt != null);
            return .{ .handle = runtime };
        }

        pub fn runPrelude(self: *Self) ContextError!void {
            const runtime = self.runtimeState();
            switch (runtime.prelude) {
                .none => return,
                .pending => |binding| {
                    std.debug.assert(runtime.attempt != null);
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

    const ExecutedType = struct {
        pending: ExecutorType.Pending,
        output_value: OutputType,

        pub const View = struct {
            output: *const OutputType,
            logs: ExecutorType.State.LogView,
        };

        /// Borrow the complete inclusion view after one pending-state assertion.
        pub fn view(self: *const @This()) View {
            return .{
                .output = &self.output_value,
                .logs = self.pending.logView(),
            };
        }

        pub fn output(self: *const @This()) *const OutputType {
            self.pending.requireCurrent();
            return &self.output_value;
        }

        pub fn result(self: @This()) OutputType {
            self.pending.requireCurrent();
            return self.output_value;
        }

        pub fn logs(self: @This()) ExecutorType.State.LogView {
            return self.pending.logView();
        }

        pub fn allocator(self: @This()) std.mem.Allocator {
            return self.pending.allocator();
        }

        pub fn changes(self: @This()) ExecutorType.State.ChangesView {
            return self.pending.changes();
        }

        pub fn observations(self: @This()) ExecutorType.State.ObservationsView {
            return self.pending.view().observations();
        }

        pub fn retain(self: @This()) executor_errors.Error!void {
            self.pending.retain() catch |err| return executor_errors.normalize(err);
        }

        /// Retain the attempt's state writes and return the output in one
        /// step. Read `view`/`logs` first: retention closes pending state.
        /// Borrowed output slices stay valid until the next Executor
        /// operation.
        pub fn retainResult(self: @This()) executor_errors.Error!OutputType {
            try self.retain();
            return self.output_value;
        }

        pub fn discard(self: @This()) executor_errors.Error!void {
            return self.pending.discard() catch |err| return executor_errors.normalize(err);
        }

        pub fn discardIfCurrent(self: @This()) void {
            self.pending.discardIfCurrent();
        }
    };

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

        pub fn init(executor: *ExecutorType) @This() {
            return .{ .executor = executor };
        }

        pub fn executorPtr(self: *const @This()) *ExecutorType {
            return self.executor;
        }

        pub fn Block(
            comptime EnvironmentType: type,
            comptime IncludedType: type,
            comptime ResultType: type,
            comptime BlockImplementationType: type,
        ) type {
            return block_program.bind(
                @This(),
                ExecutorType,
                TransactionType,
                TransactInputType,
                OutputType,
                RejectionType,
                EnvironmentType,
                IncludedType,
                ResultType,
                BlockImplementationType,
            );
        }

        /// Rebind the same transaction program with block-prelude failures that
        /// must remain typed across the rollback-integrated callback boundary.
        pub fn withPreludeError(comptime AdditionalError: type) type {
            if (AdditionalError == error{}) return @This();
            return BoundTransaction(
                ExecutorType,
                ContextType,
                TransactionType,
                TransactInputType,
                OutputType,
                RejectionType,
                ImplementationType,
                PreludeErrorType || AdditionalError,
            );
        }

        /// Rebind this runtime value to a wider block-prelude error set while
        /// preserving its Executor.
        pub fn rebindPreludeError(
            self: @This(),
            comptime AdditionalError: type,
        ) withPreludeError(AdditionalError) {
            return .{
                .executor = self.executor,
            };
        }

        pub fn transact(self: *@This(), input_value: TransactInputType) Error!Outcome {
            return self.transactOwned(input_value, false, null, .normal);
        }

        pub fn transactObserved(self: *@This(), input_value: TransactInputType) Error!Outcome {
            return self.transactOwned(input_value, false, null, .observed);
        }

        pub fn transactCaptured(
            self: *@This(),
            input_value: TransactInputType,
            capture: *CaptureContext,
        ) Error!Outcome {
            return self.transactOwned(input_value, false, null, .{ .captured = capture });
        }

        /// Execute under the exclusive block claim owned by a bound block
        /// program. Direct callers cannot bypass block ownership with a bool.
        pub fn transactInBlock(
            self: *@This(),
            input_value: TransactInputType,
            claim: ExecutorType.BlockExecutionClaim,
        ) Error!Outcome {
            try claim.requireFor(self.executor);
            return self.transactOwned(input_value, true, null, .normal);
        }

        pub fn transactObservedInBlock(
            self: *@This(),
            input_value: TransactInputType,
            claim: ExecutorType.BlockExecutionClaim,
        ) Error!Outcome {
            try claim.requireFor(self.executor);
            return self.transactOwned(input_value, true, null, .observed);
        }

        /// Execute under a block claim with a family prelude that is invoked by
        /// the transaction implementation after validation/preparation and
        /// after opening the rollback-armed attempt.
        pub fn transactInBlockWithPrelude(
            self: *@This(),
            input_value: TransactInputType,
            claim: ExecutorType.BlockExecutionClaim,
            prelude: PreludeType,
        ) Error!Outcome {
            try claim.requireFor(self.executor);
            return self.transactOwned(input_value, true, prelude, .normal);
        }

        pub fn transactObservedInBlockWithPrelude(
            self: *@This(),
            input_value: TransactInputType,
            claim: ExecutorType.BlockExecutionClaim,
            prelude: PreludeType,
        ) Error!Outcome {
            try claim.requireFor(self.executor);
            return self.transactOwned(input_value, true, prelude, .observed);
        }

        pub fn transactCapturedInBlockWithPrelude(
            self: *@This(),
            input_value: TransactInputType,
            claim: ExecutorType.BlockExecutionClaim,
            prelude: PreludeType,
            capture: *CaptureContext,
        ) Error!Outcome {
            try claim.requireFor(self.executor);
            return self.transactOwned(input_value, true, prelude, .{ .captured = capture });
        }

        fn transactOwned(
            self: *@This(),
            input_value: TransactInputType,
            block_claimed: bool,
            prelude: ?PreludeType,
            mode: AttemptMode,
        ) Error!OutcomeType {
            const executor = self.executor;
            if (!block_claimed and executor.hasActiveBlockExecution())
                return error.BlockExecutionActive;
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
                    .pending = try runtime.complete(),
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
