//! Typed transaction-program binding above one reusable Executor branch.
//!
//! The program owns transaction representation and semantics. The binder owns
//! attempt cleanup and the neutral executed lease. Family output is stored
//! beside that lease, never inside Executor.

const std = @import("std");

const Address = @import("../address.zig").Address;
const crypto = @import("../crypto.zig");
const definition = @import("../definition.zig");
const execution = @import("../execution.zig");
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

/// First-class transaction program with flat lexical carriers for ZLS.
/// `Impl.Input` is the complete invocation value and must contain a `tx: Tx`
/// field. `Impl.For(Context).transact` receives that concrete transaction.
pub fn Transaction(
    comptime TxT: type,
    comptime OutputT: type,
    comptime RejectionT: type,
    comptime ImplT: type,
) type {
    const TxType = TxT;
    const Input = ImplT.Input;
    const OutputType = OutputT;
    const RejectionType = RejectionT;
    const ImplementationType = ImplT;
    comptime {
        if (!@hasField(Input, "tx"))
            @compileError("transaction program input must contain a tx field");
        if (@FieldType(Input, "tx") != TxType)
            @compileError("transaction program input tx field has the wrong type");
    }

    return struct {
        pub const Transaction = TxType;
        pub const TransactInput = Input;
        pub const Output = OutputType;
        pub const Rejection = RejectionType;
        pub const Implementation = ImplementationType;

        pub fn For(comptime ContextType: type) type {
            const Bound = bindTransition(ContextType, Implementation);
            comptime validateTransition(ContextType, TxType, OutputType, RejectionType, Bound);
            return Bound;
        }

        /// Bind transaction semantics to one engine family. The family carries
        /// both the reusable Executor and the matching transaction protocol.
        pub fn bind(comptime FamilyType: type) type {
            comptime validateFamilyBinding(FamilyType);
            return BoundTransaction(
                FamilyType.Executor,
                FamilyType.TransactionProtocol,
                FamilyType.TransactionPolicy,
                FamilyType.transaction_policy,
                TxType,
                Input,
                OutputType,
                RejectionType,
                ImplementationType,
                error{},
            );
        }
    };
}

const ContractError = error{
    InvalidTransactionOutcome,
    TransactionPreludeAlreadyRun,
    TransactionPreludeFailed,
    TransactionPreludeNotRun,
};

/// Concrete family-authoring context. Custom transitions can name this type at
/// file scope; library presets may continue to expose `For(Context)`.
pub fn Context(
    comptime Family: type,
    comptime Input: type,
) type {
    comptime validateFamilyBinding(Family);
    return TransactionContext(
        Family.Executor,
        Family.TransactionProtocol,
        Family.TransactionPolicy,
        Input,
    );
}

fn RuntimeState(
    comptime ExecutorType: type,
    comptime TransactionPolicyType: type,
    comptime InputType: type,
) type {
    const Error = ExecutorType.Error || ContractError;

    return struct {
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
        policy: *const TransactionPolicyType,
        input_value: *const InputType,
        attempt: ?ExecutorType.TransactionAttempt = null,
        prelude: PreludeState = .none,

        fn discardIfActive(self: *@This()) void {
            const attempt = self.attempt orelse return;
            attempt.discardIfCurrent();
            self.attempt = null;
        }

        fn complete(self: *@This()) Error!ExecutorType.ExecutionLease {
            switch (self.prelude) {
                .pending => return error.TransactionPreludeNotRun,
                .failed => return error.TransactionPreludeFailed,
                .none, .consumed => {},
            }
            const attempt = self.attempt orelse return error.InvalidTransactionOutcome;
            const executed = attempt.completeLease() catch |err| return ExecutorType.normalizeError(err);
            self.attempt = null;
            return executed;
        }

        fn preludeFailure(self: *const @This()) ?anyerror {
            return switch (self.prelude) {
                .failed => |err| err,
                else => null,
            };
        }
    };
}

fn AttemptType(
    comptime ExecutorType: type,
    comptime TransactionPolicyType: type,
    comptime InputType: type,
) type {
    const Error = ExecutorType.Error || ContractError;
    const Runtime = RuntimeState(ExecutorType, TransactionPolicyType, InputType);

    return struct {
        handle: *anyopaque,

        fn runtimeState(self: @This()) *Runtime {
            return @ptrCast(@alignCast(self.handle));
        }

        fn token(self: @This()) Error!ExecutorType.TransactionAttempt {
            return self.runtimeState().attempt orelse error.NoCurrentTransaction;
        }

        pub fn allocator(self: @This()) Error!std.mem.Allocator {
            return (try self.token()).allocator() catch |err| return ExecutorType.normalizeError(err);
        }

        pub fn checkpoint(self: @This()) Error!ExecutorType.ExecutionCheckpoint {
            return (try self.token()).checkpoint() catch |err| return ExecutorType.normalizeError(err);
        }

        pub fn executeRequest(self: @This(), request: execution.EvmExecutionRequest) Error!Interpreter.Result {
            return (try self.token()).executeRequest(request) catch |err| return ExecutorType.normalizeError(err);
        }

        pub fn executeRequestPhased(
            self: @This(),
            request: execution.EvmExecutionRequest,
        ) Error!ExecutorType.TransactionExecutionOutcome {
            return (try self.token()).executeRequestPhased(request) catch |err| return ExecutorType.normalizeError(err);
        }

        pub fn runPayload(
            self: @This(),
            request: execution.EvmExecutionRequest,
        ) Error!ExecutorType.TransactionExecutionOutcome {
            return (try self.token()).runPayload(request) catch |err| return ExecutorType.normalizeError(err);
        }

        pub fn beginExecution(
            self: @This(),
            request: execution.EvmExecutionRequest,
            init_value: execution.ExecutionScopeInit,
        ) Error!void {
            return (try self.token()).beginExecution(request, init_value) catch |err| return ExecutorType.normalizeError(err);
        }

        pub fn accountSummary(self: @This(), account_address: Address) Error!?ExecutorType.TransactionAttempt.AccountSummary {
            return (try self.token()).accountSummary(account_address) catch |err| return ExecutorType.normalizeError(err);
        }

        pub fn code(self: @This(), account_address: Address) Error![]const u8 {
            return (try self.token()).code(account_address) catch |err| return ExecutorType.normalizeError(err);
        }

        pub fn balance(self: @This(), account_address: Address) Error!u256 {
            return (try self.token()).balance(account_address) catch |err| return ExecutorType.normalizeError(err);
        }

        pub fn accountAccess(self: @This(), account_address: Address) Error!void {
            return (try self.token()).accountAccess(account_address) catch |err| return ExecutorType.normalizeError(err);
        }

        pub fn touchAccount(self: @This(), account_address: Address) Error!void {
            return (try self.token()).touchAccount(account_address) catch |err| return ExecutorType.normalizeError(err);
        }

        pub fn addBalance(self: @This(), account_address: Address, value: u256) Error!void {
            return (try self.token()).addBalance(account_address, value) catch |err| return ExecutorType.normalizeError(err);
        }

        pub fn subtractBalance(self: @This(), account_address: Address, value: u256) Error!bool {
            return (try self.token()).subtractBalance(account_address, value) catch |err| return ExecutorType.normalizeError(err);
        }

        pub fn setNonce(self: @This(), account_address: Address, nonce: u64) Error!void {
            return (try self.token()).setNonce(account_address, nonce) catch |err| return ExecutorType.normalizeError(err);
        }

        pub fn incrementNonce(self: @This(), account_address: Address) Error!void {
            return (try self.token()).incrementNonce(account_address) catch |err| return ExecutorType.normalizeError(err);
        }

        pub fn setCode(self: @This(), account_address: Address, code_bytes: []const u8) Error!void {
            return (try self.token()).setCode(account_address, code_bytes) catch |err| return ExecutorType.normalizeError(err);
        }

        pub fn clearCode(self: @This(), account_address: Address) Error!void {
            return (try self.token()).clearCode(account_address) catch |err| return ExecutorType.normalizeError(err);
        }

        pub fn warmAccount(self: @This(), account_address: Address) Error!void {
            return (try self.token()).warmAccount(account_address) catch |err| return ExecutorType.normalizeError(err);
        }

        pub fn warmStorage(self: @This(), account_address: Address, key: u256) Error!void {
            return (try self.token()).warmStorage(account_address, key) catch |err| return ExecutorType.normalizeError(err);
        }

        pub fn finalizeState(self: @This()) Error!void {
            return (try self.token()).finalizeState() catch |err| return ExecutorType.normalizeError(err);
        }
    };
}

fn PreludeContext(
    comptime ExecutorType: type,
    comptime TransactionPolicyType: type,
    comptime InputType: type,
    comptime PreludeErrorType: type,
) type {
    const ContextError = ExecutorType.Error || ContractError || PreludeErrorType;
    const Runtime = RuntimeState(ExecutorType, TransactionPolicyType, InputType);

    return struct {
        handle: *anyopaque,

        pub const Error = ContextError;

        fn runtimeState(self: @This()) *Runtime {
            return @ptrCast(@alignCast(self.handle));
        }

        fn token(self: @This()) ContextError!ExecutorType.TransactionAttempt {
            return self.runtimeState().attempt orelse error.NoCurrentTransaction;
        }

        pub fn revision(self: @This()) ContextError!ExecutorType.Protocol.Revision {
            return (try self.token()).revision() catch |err| return ExecutorType.normalizeError(err);
        }

        pub fn code(self: @This(), account_address: Address) ContextError![]const u8 {
            return (try self.token()).code(account_address) catch |err| return ExecutorType.normalizeError(err);
        }

        pub fn executeRequest(self: @This(), request: execution.EvmExecutionRequest) ContextError!Interpreter.Result {
            return (try self.token()).executePreludeRequest(request) catch |err| return ExecutorType.normalizeError(err);
        }
    };
}

fn Prelude(
    comptime ExecutorType: type,
    comptime TransactionPolicyType: type,
    comptime InputType: type,
    comptime PreludeErrorType: type,
) type {
    const ContextError = ExecutorType.Error || ContractError || PreludeErrorType;
    const ContextType = PreludeContext(ExecutorType, TransactionPolicyType, InputType, PreludeErrorType);

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

fn TransactionContext(
    comptime ExecutorType: type,
    comptime TransactionProtocolType: type,
    comptime TransactionPolicyType: type,
    comptime InputType: type,
) type {
    const ContextError = ExecutorType.Error || ContractError;
    const RuntimeType = RuntimeState(ExecutorType, TransactionPolicyType, InputType);
    const Attempt = AttemptType(ExecutorType, TransactionPolicyType, InputType);

    return struct {
        handle: *anyopaque,

        pub const Error = ContextError;
        pub const Executor = ExecutorType;
        pub const Input = InputType;
        pub const RuntimeState = RuntimeType;
        pub const AttemptCapability = Attempt;
        pub const TransactionProtocol = TransactionProtocolType;
        pub const TransactionPolicy = TransactionPolicyType;

        fn runtimeState(self: *const @This()) *RuntimeType {
            return @ptrCast(@alignCast(self.handle));
        }

        pub fn input(self: *const @This()) *const InputType {
            return self.runtimeState().input_value;
        }

        pub fn revision(self: *const @This()) ExecutorType.Protocol.Revision {
            return self.runtimeState().executor.revision();
        }

        pub fn policy(self: *const @This()) *const TransactionPolicyType {
            return self.runtimeState().policy;
        }

        pub fn blockGasLimitBound(self: *const @This()) ?u64 {
            return self.runtimeState().executor.blockGasLimitBound();
        }

        pub fn preparationState(self: *@This()) tx.PreparationStateAccess {
            return .{
                .ptr = self.runtimeState(),
                .vtable = &preparation_state_vtable,
            };
        }

        pub fn beginAttempt(self: *@This()) ContextError!Attempt {
            const runtime = self.runtimeState();
            if (runtime.attempt != null) return error.TransactionAttemptActive;
            runtime.attempt = runtime.executor.beginTransactionAttemptLifetime() catch |err| return ExecutorType.normalizeError(err);
            return .{ .handle = runtime };
        }

        pub fn activeAttempt(self: *@This()) ContextError!Attempt {
            const runtime = self.runtimeState();
            _ = runtime.attempt orelse return error.NoCurrentTransaction;
            return .{ .handle = runtime };
        }

        pub fn runPrelude(self: *@This()) ContextError!void {
            const runtime = self.runtimeState();
            switch (runtime.prelude) {
                .none => return,
                .pending => |binding| {
                    _ = runtime.attempt orelse return error.NoCurrentTransaction;
                    runtime.prelude = .consumed;
                    binding.run(binding.handle, runtime) catch |err| {
                        runtime.prelude = .{ .failed = err };
                        return error.TransactionPreludeFailed;
                    };
                    runtime.executor.clearLogs();
                    runtime.executor.clearLastOutput();
                },
                .consumed, .failed => return error.TransactionPreludeAlreadyRun,
            }
        }

        pub fn infrastructureError(_: *const @This(), err: anyerror) ContextError {
            return ExecutorType.normalizeError(err);
        }

        fn preparationAccountSummary(ptr: *anyopaque, account_address: Address) !?tx.PreparationAccount {
            const runtime: *RuntimeType = @ptrCast(@alignCast(ptr));
            const account = (runtime.executor.getAccountOrLoad(account_address) catch |err| return ExecutorType.normalizeError(err)) orelse return null;
            return .{
                .nonce = account.nonce,
                .balance = account.balance,
                .code_hash = account.code_hash,
            };
        }

        fn preparationCode(ptr: *anyopaque, account_address: Address, expected_hash: [32]u8) ![]const u8 {
            const runtime: *RuntimeType = @ptrCast(@alignCast(ptr));
            const code_bytes = runtime.executor.getCode(account_address) catch |err| return ExecutorType.normalizeError(err);
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

fn bindTransition(comptime ContextType: type, comptime Implementation: type) type {
    if (comptime @hasDecl(Implementation, "For")) return Implementation.For(ContextType);
    return Implementation;
}

fn transitionContext(comptime GeneratedContext: type, comptime Implementation: type) type {
    if (comptime @hasDecl(Implementation, "For")) return GeneratedContext;
    const params = @typeInfo(@TypeOf(Implementation.transact)).@"fn".params;
    if (params.len < 2) @compileError("concrete transaction transition must accept context and transaction");
    const ContextPointer = params[0].type orelse
        @compileError("concrete transaction transition context must have a declared type");
    const pointer = switch (@typeInfo(ContextPointer)) {
        .pointer => |info| info,
        else => @compileError("concrete transaction transition context must be a pointer"),
    };
    if (pointer.size != .one or pointer.is_const)
        @compileError("concrete transaction transition context must be a mutable single-item pointer");
    const Concrete = pointer.child;
    inline for (.{ "Executor", "Input", "TransactionProtocol", "TransactionPolicy", "RuntimeState" }) |name| {
        if (!@hasDecl(Concrete, name))
            @compileError("concrete transaction context is missing " ++ name);
    }
    if (Concrete.Executor != GeneratedContext.Executor)
        @compileError("concrete transaction context Executor does not match the bound family");
    if (Concrete.Input != GeneratedContext.Input)
        @compileError("concrete transaction context Input does not match the bound program");
    if (Concrete.TransactionProtocol != GeneratedContext.TransactionProtocol)
        @compileError("concrete transaction context TransactionProtocol does not match the bound family");
    if (Concrete.TransactionPolicy != GeneratedContext.TransactionPolicy)
        @compileError("concrete transaction context TransactionPolicy does not match the bound family");
    return Concrete;
}

fn BoundTransaction(
    comptime ExecutorType: type,
    comptime TransactionProtocolType: type,
    comptime TransactionPolicyType: type,
    comptime default_transaction_policy: TransactionPolicyType,
    comptime TransactionType: type,
    comptime TransactInputType: type,
    comptime OutputType: type,
    comptime RejectionType: type,
    comptime ImplementationType: type,
    comptime PreludeErrorType: type,
) type {
    const ContextError = ExecutorType.Error || ContractError;

    comptime {
        if (TransactionPolicyType != definition.TransactionPolicy(TransactionProtocolType.Revision))
            @compileError("transaction runtime policy has the wrong nominal type");
    }

    const PreludeContextType = PreludeContext(
        ExecutorType,
        TransactionPolicyType,
        TransactInputType,
        PreludeErrorType,
    );
    const PreludeType = Prelude(
        ExecutorType,
        TransactionPolicyType,
        TransactInputType,
        PreludeErrorType,
    );
    const GeneratedContext = TransactionContext(
        ExecutorType,
        TransactionProtocolType,
        TransactionPolicyType,
        TransactInputType,
    );
    const ContextType = transitionContext(GeneratedContext, ImplementationType);
    const Runtime = ContextType.RuntimeState;
    const BoundImpl = bindTransition(ContextType, ImplementationType);
    comptime validateTransition(ContextType, TransactionType, OutputType, RejectionType, BoundImpl);
    const ProgramError = ContextError || BoundImpl.Error || PreludeErrorType;

    const ExecutedType = struct {
        lease: ExecutorType.ExecutionLease,
        output_value: OutputType,

        pub const View = struct {
            output: *const OutputType,
            logs: []const Host.Log,
        };

        /// Borrow the complete inclusion view after one lease validation.
        pub fn view(self: *const @This()) ExecutorType.ExecutionLeaseError!View {
            return .{
                .output = &self.output_value,
                .logs = try self.lease.logs(),
            };
        }

        pub fn output(self: *const @This()) ExecutorType.ExecutionLeaseError!*const OutputType {
            try self.lease.requireCurrent();
            return &self.output_value;
        }

        pub fn result(self: @This()) ExecutorType.ExecutionLeaseError!OutputType {
            try self.lease.requireCurrent();
            return self.output_value;
        }

        pub fn logs(self: @This()) ExecutorType.ExecutionLeaseError![]const Host.Log {
            return self.lease.logs();
        }

        pub fn changeset(self: @This()) ExecutorType.Error!state.Changeset {
            return self.lease.changeset() catch |err| return ExecutorType.normalizeError(err);
        }

        pub fn retain(self: @This()) ExecutorType.Error!void {
            self.lease.retain() catch |err| return ExecutorType.normalizeError(err);
        }

        pub fn discard(self: @This()) ExecutorType.Error!void {
            return self.lease.discard() catch |err| return ExecutorType.normalizeError(err);
        }

        pub fn discardIfCurrent(self: @This()) void {
            self.lease.discardIfCurrent();
        }
    };

    const OutcomeType = TransactOutcome(ExecutedType, RejectionType);

    return struct {
        pub const Executor = ExecutorType;
        pub const TransactionProtocol = TransactionProtocolType;
        pub const TransactionPolicy = TransactionPolicyType;
        pub const Context = ContextType;
        pub const Transaction = TransactionType;
        pub const TransactInput = TransactInputType;
        pub const Output = OutputType;
        pub const TransactionLog = Host.Log;
        pub const Rejection = RejectionType;
        pub const Executed = ExecutedType;
        pub const Prelude = PreludeType;
        pub const PreludeContext = PreludeContextType;
        pub const Outcome = OutcomeType;
        pub const Error = ProgramError;

        executor: *ExecutorType,
        policy: TransactionPolicyType,

        pub fn init(executor: *ExecutorType) @This() {
            return initWithPolicy(executor, default_transaction_policy);
        }

        pub fn initWithPolicy(
            executor: *ExecutorType,
            policy: TransactionPolicyType,
        ) @This() {
            return .{
                .executor = executor,
                .policy = policy,
            };
        }

        pub fn executorPtr(self: *const @This()) *ExecutorType {
            return self.executor;
        }

        /// Rebind the same transaction program with block-prelude failures that
        /// must remain typed across the rollback-integrated callback boundary.
        pub fn withPreludeError(comptime AdditionalError: type) type {
            if (AdditionalError == error{}) return @This();
            return BoundTransaction(
                ExecutorType,
                TransactionProtocolType,
                TransactionPolicyType,
                default_transaction_policy,
                TransactionType,
                TransactInputType,
                OutputType,
                RejectionType,
                ImplementationType,
                PreludeErrorType || AdditionalError,
            );
        }

        /// Rebind this runtime value to a wider block-prelude error set while
        /// preserving its Executor and owned policy snapshot.
        pub fn rebindPreludeError(
            self: @This(),
            comptime AdditionalError: type,
        ) withPreludeError(AdditionalError) {
            return .{
                .executor = self.executor,
                .policy = self.policy,
            };
        }

        pub fn transact(self: *@This(), input_value: TransactInputType) Error!Outcome {
            return self.transactOwned(input_value, false, null);
        }

        /// Execute under the exclusive block claim owned by a bound block
        /// program. Direct callers cannot bypass block ownership with a bool.
        pub fn transactInBlock(
            self: *@This(),
            input_value: TransactInputType,
            claim: ExecutorType.BlockExecutionClaim,
        ) Error!Outcome {
            try claim.requireFor(self.executor);
            return self.transactOwned(input_value, true, null);
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
            return self.transactOwned(input_value, true, prelude);
        }

        fn transactOwned(
            self: *@This(),
            input_value: TransactInputType,
            block_claimed: bool,
            prelude: ?PreludeType,
        ) Error!OutcomeType {
            const executor = self.executor;
            if (!block_claimed and executor.hasActiveBlockExecution())
                return error.BlockExecutionActive;
            if (executor.hasCurrentTransaction()) return error.ExecutedTransactionActive;
            executor.clearLogs();

            var runtime: Runtime = .{
                .executor = executor,
                .policy = &self.policy,
                .input_value = &input_value,
                .prelude = if (prelude) |value| .{ .pending = .{
                    .handle = value.handle,
                    .run = value.run_fn,
                } } else .none,
            };
            errdefer runtime.discardIfActive();
            var context: ContextType = .{ .handle = &runtime };
            const outcome = BoundImpl.transact(&context, input_value.tx) catch |err| {
                if (err != error.TransactionPreludeFailed) return err;
                const prelude_error = runtime.preludeFailure() orelse
                    return error.TransactionPreludeFailed;
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
                    .lease = try runtime.complete(),
                    .output_value = output_value,
                } },
            };
        }
    };
}

fn validateFamilyBinding(comptime Family: type) void {
    if (!@hasDecl(Family, "Executor"))
        @compileError("transaction program binding must declare Executor");
    if (!@hasDecl(Family, "TransactionProtocol"))
        @compileError("transaction program binding must declare TransactionProtocol");
    if (!@hasDecl(Family, "TransactionPolicy"))
        @compileError("transaction program binding must declare TransactionPolicy");
    if (!@hasDecl(Family, "transaction_policy"))
        @compileError("transaction program binding must declare transaction_policy");
    if (!@hasDecl(Family.Executor, "Protocol"))
        @compileError("transaction program Executor must declare Protocol");
    if (!@hasDecl(Family.TransactionProtocol, "ExecutionProtocol"))
        @compileError("transaction protocol must declare ExecutionProtocol");
    if (Family.Executor.Protocol != Family.TransactionProtocol.ExecutionProtocol)
        @compileError("transaction program Executor and TransactionProtocol do not share one execution protocol");
    if (Family.TransactionPolicy != definition.TransactionPolicy(Family.TransactionProtocol.Revision))
        @compileError("transaction program family has the wrong transaction policy type");
    if (@TypeOf(Family.transaction_policy) != Family.TransactionPolicy)
        @compileError("transaction program family has the wrong default transaction policy value");
}

fn validateTransition(
    comptime ContextType: type,
    comptime TransactionType: type,
    comptime OutputType: type,
    comptime RejectionType: type,
    comptime Bound: type,
) void {
    if (!@hasDecl(Bound, "Error"))
        @compileError("transaction implementation must declare Error");
    const actual = @TypeOf(Bound.transact(
        @as(*ContextType, undefined),
        @as(TransactionType, undefined),
    ));
    const expected = Bound.Error!TransitionOutcome(OutputType, RejectionType);
    if (actual != expected)
        @compileError("transaction implementation has the wrong signature");
}
