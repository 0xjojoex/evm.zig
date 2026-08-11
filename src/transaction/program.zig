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

/// Internal transport caught by the binder and replaced with the concrete
/// block-prelude error before it reaches a program caller.
const ContractError = error{TransactionPreludeFailed};

/// Bind transaction semantics using flat engine-family and program carriers.
/// Concrete VM types expose this through `VM.Program(...)`.
pub fn ProgramType(
    comptime Executor: type,
    // FIXME: this has to be stop
    comptime Transaction_: type,
    comptime Input: type,
    comptime Output_: type,
    comptime Rejection_: type,
    comptime Implementation: type,
    comptime PreludeError: type,
) type {
    comptime {
        std.debug.assert(@hasField(Input, "tx"));
        std.debug.assert(@FieldType(Input, "tx") == Transaction_);
    }

    const ContextError = executor_errors.Error || ContractError;
    const Runtime = RuntimeStateType(Executor, Input);

    const ProgramError = ContextError || Implementation.Error || PreludeError;

    const ExecutedType = Executor.Executed(Output_);

    const OutcomeType = TransactOutcomeType(ExecutedType, Rejection_);

    return struct {
        const Self = @This();

        comptime {
            validateTransition(Context, Transaction_, Output_, Rejection_, Implementation);
        }

        pub const specification = Executor.specification;
        pub const Context = ContextType(Executor, Input);
        pub const Transaction = Transaction_;
        pub const TransactInput = Input;
        pub const Output = Output_;
        pub const TransactionLog = Host.Log;
        pub const TransactionLogs = Executor.State.LogView;
        pub const Rejection = Rejection_;
        pub const Executed = ExecutedType;
        pub const Prelude = PreludeType(PreludeContext);
        pub const PreludeContext = PreludeContextType(
            Executor,
            Runtime,
            PreludeError,
        );
        pub const Outcome = OutcomeType;
        pub const Error = ProgramError;

        pub const Observed = struct {
            program: *Self,

            pub fn transact(self: Observed, input_value: Input) Error!Outcome {
                return self.program.transactOwned(input_value, false, null, .observed);
            }
        };

        pub const Captured = struct {
            program: *Self,
            context: *CaptureContext,

            pub fn transact(self: Captured, input_value: Input) Error!Outcome {
                return self.program.transactOwned(
                    input_value,
                    false,
                    null,
                    .{ .captured = self.context },
                );
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
        /// The returned type is the only public in-block transaction entry
        /// point; block claims and transaction-runtime choreography stay
        /// internal to that type.
        pub fn Block(
            comptime EnvType: type,
            comptime IncludedType: type,
            comptime ResultType: type,
            comptime BlockImplementationType: type,
        ) type {
            const RuntimeWithPrelude = ProgramType(
                Executor,
                Transaction,
                Input,
                Output,
                Rejection,
                Implementation,
                PreludeError || BlockImplementationType.PreludeError,
            );
            return block_program.bind(
                RuntimeWithPrelude,
                Executor,
                Transaction,
                Input,
                Output,
                Rejection,
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
        pub fn transact(self: *@This(), input_value: Input) Error!Outcome {
            return self.transactOwned(input_value, false, null, .normal);
        }

        /// Borrow a transaction facade that records state observations.
        pub fn observe(self: *Self) Observed {
            return .{ .program = self };
        }

        /// Borrow a transaction facade bound to caller-owned capture storage.
        pub fn capture(self: *Self, context: *CaptureContext) Captured {
            return .{ .program = self, .context = context };
        }

        fn transactOwned(
            self: *@This(),
            input_value: Input,
            block_claimed: bool,
            prelude: ?Prelude,
            mode: InstrumentationMode,
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
            var context: Context = .{ .handle = &runtime };
            const outcome = Implementation.transact(&context, input_value.tx) catch |err| {
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

fn RuntimeStateType(
    comptime Executor: type,
    comptime Input: type,
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
    const ContextError = executor_errors.Error || ContractError || PreludeError;

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
                .run_fn = Adapter.run,
            };
        }
    };
}

/// Concrete family-authoring context assembled from flat lexical carriers.
pub fn ContextType(
    comptime Executor: type,
    comptime Input: type,
) type {
    const ContextError = executor_errors.Error || ContractError;
    const RuntimeState = RuntimeStateType(Executor, Input);

    return struct {
        handle: *anyopaque,

        const Self = @This();

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
        ) ContextError!Executor.TransactionExecutionOutcome {
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

fn validateTransition(
    comptime Context: type,
    comptime Transaction: type,
    comptime Output: type,
    comptime Rejection: type,
    comptime Bound: type,
) void {
    comptime {
        std.debug.assert(@hasDecl(Bound, "Error"));
        // Inspect the function type only; a call expression here would force
        // eager analysis of the whole transact graph at every instantiation.
        const info = @typeInfo(@TypeOf(Bound.transact)).@"fn";
        std.debug.assert(info.params.len == 2);
        std.debug.assert(info.params[0].type.? == *Context);
        std.debug.assert(info.params[1].type.? == Transaction);
        std.debug.assert(info.return_type.? == Bound.Error!TransitionOutcomeType(Output, Rejection));
    }
}
