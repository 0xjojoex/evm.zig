//! Typed block-fold program bound above one transaction runtime.
//!
//! The program owns block environment, cumulative fold state, inclusion
//! planning, and included/result representation. The bound runtime owns one
//! exclusive Executor block claim. Scheduling and whole-block validation stay
//! above this layer.
const std = @import("std");

const CaptureContext = @import("./executor/capture_context.zig").Context;
const Address = @import("./address.zig").Address;
const execution = @import("./execution.zig");
const executor_errors = @import("./executor/error.zig");

const AttemptMode = union(enum) {
    normal,
    observed,
    captured: *CaptureContext,
};

pub const BeforeBlockContext = struct {
    number: u64,
    timestamp: u64,
    parent_hash: ?[32]u8 = null,
    parent_beacon_block_root: ?[32]u8 = null,
};

pub const BlockHookInput = union(enum) {
    none,
    word: [32]u8,
    bytes: []const u8,

    pub fn slice(self: *const BlockHookInput) []const u8 {
        return switch (self.*) {
            .none => &.{},
            .word => |*word| word,
            .bytes => |bytes| bytes,
        };
    }
};

pub const BlockSystemCall = struct {
    sender: Address,
    recipient: Address,
    input: BlockHookInput = .none,
    gas: u64,
    state_gas: u64 = 0,
    require_code: bool = false,
};

pub const BlockSystemCalls = struct {
    pub const capacity = 4;

    items: [capacity]BlockSystemCall = undefined,
    len: usize = 0,

    pub fn append(self: *BlockSystemCalls, call: BlockSystemCall) void {
        std.debug.assert(self.len < capacity);
        self.items[self.len] = call;
        self.len += 1;
    }

    pub fn slice(self: *const BlockSystemCalls) []const BlockSystemCall {
        return self.items[0..self.len];
    }
};

pub const BeforeTransactionContext = struct {
    number: u64,
    timestamp: u64,
    transaction_index: u64,
};

pub const AfterTransactionContext = struct {
    number: u64,
    timestamp: u64,
    transaction_index: u64,
    status: execution.Status,
    gas_used: u64,
    cumulative_gas_used: u64,
    cumulative_block_gas: u64,
    cumulative_state_gas: u64,
};

pub const FinalizeBlockContext = struct {
    number: u64,
    timestamp: u64,
    transaction_count: u64,
    gas_used: u64,
    block_gas: u64,
    state_gas: u64,
};

pub const FinalizeSystemCall = struct {
    call: BlockSystemCall,
    output_prefix: u8,
};

pub const FinalizeSystemCalls = struct {
    pub const capacity = 4;

    items: [capacity]FinalizeSystemCall = undefined,
    len: usize = 0,

    pub fn append(self: *FinalizeSystemCalls, call: FinalizeSystemCall) void {
        std.debug.assert(self.len < capacity);
        self.items[self.len] = call;
        self.len += 1;
    }

    pub fn slice(self: *const FinalizeSystemCalls) []const FinalizeSystemCall {
        return self.items[0..self.len];
    }
};

pub fn TransactOutcome(comptime Included: type, comptime Rejection: type) type {
    return union(enum) {
        rejected: Rejection,
        included: Included,
    };
}

test "block hook collections preserve insertion order" {
    const first = [_]u8{0x11} ** 20;
    const second = [_]u8{0x22} ** 20;
    var calls = BlockSystemCalls{};
    calls.append(.{ .sender = first, .recipient = second, .gas = 7 });

    try std.testing.expectEqual(@as(usize, 1), calls.slice().len);
    try std.testing.expectEqual(first, calls.slice()[0].sender);
    try std.testing.expectEqual(second, calls.slice()[0].recipient);
}

/// Internal flat binder used by a concrete VM program's `Block(...)` closure.
pub fn bind(
    comptime TransactionRuntimeType: type,
    comptime ExecutorType: type,
    comptime TransactionType: type,
    comptime TransactInputType: type,
    comptime OutputType: type,
    comptime RejectionType: type,
    comptime EnvironmentType: type,
    comptime IncludedType: type,
    comptime ResultType: type,
    comptime ImplementationType: type,
) type {
    comptime {
        std.debug.assert(@hasDecl(ImplementationType, "PreludeError"));
    }

    const RuntimeWithPrelude = TransactionRuntimeType.withPreludeError(ImplementationType.PreludeError);
    return BoundBlockProgram(
        TransactionRuntimeType,
        RuntimeWithPrelude,
        ExecutorType,
        TransactionType,
        TransactInputType,
        OutputType,
        RejectionType,
        RuntimeWithPrelude.Prelude,
        RuntimeWithPrelude.PreludeContext,
        EnvironmentType,
        IncludedType,
        ResultType,
        ImplementationType,
    );
}

fn BoundBlockProgram(
    comptime BaseTransactionRuntimeType: type,
    comptime TransactionRuntimeType: type,
    comptime ExecutorType: type,
    comptime TransactionType: type,
    comptime TransactInputType: type,
    comptime OutputType: type,
    comptime RejectionType: type,
    comptime PreludeType: type,
    comptime PreludeContextType: type,
    comptime EnvironmentType: type,
    comptime IncludedType: type,
    comptime ResultType: type,
    comptime ImplementationType: type,
) type {
    const OutcomeType = TransactOutcome(IncludedType, RejectionType);
    const ContractError = error{
        UncommittedChanges,
    };
    const ErrorType = TransactionRuntimeType.Error || ImplementationType.Error || ContractError;
    const TransactionLogs = TransactionRuntimeType.TransactionLogs;
    comptime validateImplementation(
        TransactionType,
        TransactInputType,
        OutputType,
        TransactionLogs,
        EnvironmentType,
        IncludedType,
        ResultType,
        ImplementationType,
    );

    return struct {
        const Self = @This();

        pub const TransactionRuntime = TransactionRuntimeType;
        pub const Executor = ExecutorType;
        pub const Transaction = TransactionType;
        pub const Output = OutputType;
        pub const Rejection = RejectionType;
        pub const Prelude = PreludeType;
        pub const PreludeContext = PreludeContextType;
        pub const Environment = EnvironmentType;
        pub const Included = IncludedType;
        pub const Result = ResultType;
        pub const Outcome = OutcomeType;
        pub const Error = ErrorType;

        transaction_runtime: TransactionRuntimeType,
        claim: Executor.BlockExecutionClaim,
        environment: Environment,
        state: ImplementationType.State,
        finished: bool = false,

        pub fn init(
            executor: *Executor,
            environment: Environment,
        ) Error!Self {
            return initWithRuntime(
                BaseTransactionRuntimeType.init(executor),
                environment,
            );
        }

        /// Advanced composition seam for a preconfigured transaction runtime.
        pub fn initWithRuntime(
            transaction_runtime: BaseTransactionRuntimeType,
            environment: Environment,
        ) Error!Self {
            return initRuntime(transaction_runtime, environment);
        }

        fn initRuntime(
            transaction_runtime: BaseTransactionRuntimeType,
            environment: Environment,
        ) Error!Self {
            const runtime = transaction_runtime.rebindPreludeError(ImplementationType.PreludeError);
            const executor = runtime.executorPtr();
            if (executor.hasActiveBlockExecution()) return error.BlockExecutionActive;
            std.debug.assert(!executor.hasCurrentTransaction());
            if (executor.acceptedView().hasChanges()) return error.UncommittedChanges;
            return .{
                .transaction_runtime = runtime,
                .claim = executor.claimBlockExecution() catch |err| return executor_errors.normalize(err),
                .environment = environment,
                .state = ImplementationType.init(environment),
            };
        }

        pub fn executorPtr(self: *const Self) *Executor {
            return self.transaction_runtime.executorPtr();
        }

        pub fn transact(self: *Self, transaction_value: Transaction) Error!Outcome {
            return self.transactOwned(
                transaction_value,
                null,
                .normal,
                IgnorePending{},
            ) catch |err| return @errorCast(err);
        }

        /// Fold one transaction whose family prelude shares the transaction
        /// program's journaled retain/discard lifetime.
        pub fn transactWithPrelude(
            self: *Self,
            transaction_value: Transaction,
            prelude: Prelude,
        ) Error!Outcome {
            return self.transactOwned(
                transaction_value,
                prelude,
                .normal,
                IgnorePending{},
            ) catch |err| return @errorCast(err);
        }

        /// Inspect one included transaction while its state is sealed but still
        /// pending. The observer must copy or consume borrowed views before
        /// returning; successful observation is followed by retain.
        pub fn transactWithPreludeObserved(
            self: *Self,
            transaction_value: Transaction,
            prelude: Prelude,
            observer: anytype,
        ) anyerror!Outcome {
            return self.transactOwned(transaction_value, prelude, .observed, observer);
        }

        pub fn transactWithPreludeCaptured(
            self: *Self,
            transaction_value: Transaction,
            prelude: Prelude,
            capture: *CaptureContext,
            observer: anytype,
        ) anyerror!Outcome {
            return self.transactOwned(
                transaction_value,
                prelude,
                .{ .captured = capture },
                observer,
            );
        }

        fn transactOwned(
            self: *Self,
            transaction_value: Transaction,
            prelude: ?Prelude,
            mode: AttemptMode,
            observer: anytype,
        ) anyerror!Outcome {
            if (self.finished) return error.BlockExecutionFinished;
            const input = ImplementationType.transactInput(
                &self.environment,
                &self.state,
                &transaction_value,
            );
            const outcome = if (prelude) |value| switch (mode) {
                .normal => try self.transaction_runtime.transactInBlockWithPrelude(
                    input,
                    self.claim,
                    value,
                ),
                .observed => try self.transaction_runtime.transactObservedInBlockWithPrelude(
                    input,
                    self.claim,
                    value,
                ),
                .captured => |capture| try self.transaction_runtime.transactCapturedInBlockWithPrelude(
                    input,
                    self.claim,
                    value,
                    capture,
                ),
            } else switch (mode) {
                .normal => try self.transaction_runtime.transactInBlock(input, self.claim),
                .observed => try self.transaction_runtime.transactObservedInBlock(input, self.claim),
                .captured => unreachable,
            };
            return switch (outcome) {
                .rejected => |reason| .{ .rejected = reason },
                .executed => |executed_value| blk: {
                    var executed = executed_value;
                    defer executed.discardIfCurrent();
                    const view = executed.view();
                    const plan = try ImplementationType.planInclude(
                        &self.environment,
                        &self.state,
                        &transaction_value,
                        view.output,
                        view.logs,
                    );
                    const included = ImplementationType.included(
                        &transaction_value,
                        view.output,
                        view.logs,
                        plan,
                    );
                    try observer.observe(executed.pending.view());
                    try executed.retain();
                    ImplementationType.applyInclude(&self.state, plan);
                    break :blk .{ .included = included };
                },
            };
        }

        pub fn progress(self: *const Self) Result {
            return ImplementationType.finish(&self.environment, &self.state);
        }

        pub fn finish(self: *Self) Error!Result {
            if (self.finished) return error.BlockExecutionFinished;
            try self.claim.requireFor(self.executorPtr());
            const result = ImplementationType.finish(&self.environment, &self.state);
            self.claim.release();
            self.finished = true;
            return result;
        }

        pub fn discardIfUnfinished(self: *Self) void {
            if (self.finished) return;
            self.claim.requireFor(self.executorPtr()) catch return;
            self.executorPtr().discardAccepted();
            self.claim.release();
            self.finished = true;
        }

        const IgnorePending = struct {
            pub fn observe(_: IgnorePending, _: ExecutorType.State.PendingView) !void {}
        };
    };
}

fn validateImplementation(
    comptime TransactionType: type,
    comptime TransactInputType: type,
    comptime OutputType: type,
    comptime TransactionLogsType: type,
    comptime EnvironmentType: type,
    comptime IncludedType: type,
    comptime ResultType: type,
    comptime Implementation: type,
) void {
    comptime {
        std.debug.assert(@hasDecl(Implementation, "State"));
        std.debug.assert(@hasDecl(Implementation, "InclusionPlan"));
        std.debug.assert(@hasDecl(Implementation, "Error"));

        assertSignature(Implementation.init, &.{EnvironmentType}, Implementation.State);
        assertSignature(Implementation.transactInput, &.{
            *const EnvironmentType,
            *const Implementation.State,
            *const TransactionType,
        }, TransactInputType);
        assertSignature(Implementation.planInclude, &.{
            *const EnvironmentType,
            *const Implementation.State,
            *const TransactionType,
            *const OutputType,
            TransactionLogsType,
        }, Implementation.Error!Implementation.InclusionPlan);
        assertSignature(Implementation.included, &.{
            *const TransactionType,
            *const OutputType,
            TransactionLogsType,
            Implementation.InclusionPlan,
        }, IncludedType);
        assertSignature(Implementation.applyInclude, &.{
            *Implementation.State,
            Implementation.InclusionPlan,
        }, void);
        assertSignature(Implementation.finish, &.{
            *const EnvironmentType,
            *const Implementation.State,
        }, ResultType);
    }
}

/// Inspect the function type only; a call expression under @TypeOf would
/// force eager analysis of the implementation's whole graph per instantiation.
fn assertSignature(comptime function: anytype, comptime params: []const type, comptime Return: type) void {
    comptime {
        const info = @typeInfo(@TypeOf(function)).@"fn";
        std.debug.assert(info.params.len == params.len);
        for (info.params, params) |actual, expected| {
            std.debug.assert(actual.type.? == expected);
        }
        std.debug.assert(info.return_type.? == Return);
    }
}
