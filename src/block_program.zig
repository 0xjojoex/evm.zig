//! Typed block-fold program bound above one transaction runtime.
//!
//! The program owns block environment, cumulative fold state, inclusion
//! planning, and included/result representation. The bound runtime owns one
//! exclusive Executor block claim. Scheduling and whole-block validation stay
//! above this layer.
const std = @import("std");

const CaptureContext = @import("./executor/capture_context.zig").Context;
const InstrumentationMode = @import("./executor/instrumentation.zig").Mode;
const Address = @import("./address.zig").Address;
const execution = @import("./execution.zig");
const transaction_program = @import("./transaction/program.zig");

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

pub fn executorFor(block: anytype) @TypeOf(block.transaction_runtime.executor) {
    return block.transaction_runtime.executor;
}

pub fn requireActive(block: anytype) void {
    const executor = executorFor(block);
    std.debug.assert(executor.active_block_execution_generation == block.generation);
}

fn claim(executor: anytype) u64 {
    std.debug.assert(executor.active_block_execution_generation == null);
    executor.next_block_execution_generation +%= 1;
    executor.active_block_execution_generation = executor.next_block_execution_generation;
    return executor.next_block_execution_generation;
}

fn release(executor: anytype, generation: u64) void {
    if (executor.active_block_execution_generation == generation)
        executor.active_block_execution_generation = null;
}

test "block hook collections preserve insertion order" {
    const first_sender = Address.fromBytes([_]u8{0x11} ** 20);
    const first_recipient = Address.fromBytes([_]u8{0x22} ** 20);
    const second_sender = Address.fromBytes([_]u8{0x33} ** 20);
    const second_recipient = Address.fromBytes([_]u8{0x44} ** 20);
    var calls = BlockSystemCalls{};
    calls.append(.{ .sender = first_sender, .recipient = first_recipient, .gas = 7 });
    calls.append(.{ .sender = second_sender, .recipient = second_recipient, .gas = 11 });

    try std.testing.expectEqual(@as(usize, 2), calls.slice().len);
    try std.testing.expectEqual(first_sender, calls.slice()[0].sender);
    try std.testing.expectEqual(first_recipient, calls.slice()[0].recipient);
    try std.testing.expectEqual(second_sender, calls.slice()[1].sender);
    try std.testing.expectEqual(second_recipient, calls.slice()[1].recipient);
}

/// Bind block-fold semantics above one transaction runtime.
/// Concrete VM programs expose this through `Program.Block(...)`.
///
/// Transaction carriers are read off the bound runtime; block-fold carriers
/// (Env, Included, Result) are decls of the implementation, welded to its
/// signatures by `validateImplementation`. The prelude author types widen by
/// the implementation's `PreludeError` without rebuilding the program.
pub fn BlockProgramType(
    comptime Runtime: type,
    comptime ImplementationType: type,
) type {
    comptime {
        for (.{ "PreludeError", "Env", "Included", "Result" }) |name| {
            if (!@hasDecl(ImplementationType, name))
                @compileError("block implementation must declare `" ++ name ++ "`");
        }
    }
    comptime validateImplementation(Runtime, ImplementationType);

    const ContractError = error{
        UncommittedChanges,
    };
    const ErrorType = Runtime.Error || ImplementationType.Error || ImplementationType.PreludeError || ContractError;

    const OutcomeType = TransactOutcome(ImplementationType.Included, Runtime.Rejection);

    return struct {
        const Self = @This();

        const TransactionRuntime = Runtime;
        const Executor = Runtime.Executor;
        pub const Transaction = Runtime.Transaction;
        pub const Output = Runtime.Output;
        pub const Rejection = Runtime.Rejection;
        pub const Prelude = Runtime.PreludeFor(ImplementationType.PreludeError);
        pub const PreludeContext = Runtime.PreludeContextFor(ImplementationType.PreludeError);
        pub const Env = ImplementationType.Env;
        pub const Included = ImplementationType.Included;
        pub const Result = ImplementationType.Result;
        pub const Outcome = OutcomeType;
        pub const Error = ErrorType;

        transaction_runtime: TransactionRuntime,
        generation: u64,
        environment: Env,
        state: ImplementationType.State,

        fn Instrumented(comptime Observer: type) type {
            return struct {
                block: *Self,
                mode: InstrumentationMode,
                observer: Observer,

                pub fn transact(
                    self: @This(),
                    transaction_value: Transaction,
                ) anyerror!Outcome {
                    return self.block.transactOwned(
                        &transaction_value,
                        null,
                        self.mode,
                        self.observer,
                    );
                }

                pub fn transactWithPrelude(
                    self: @This(),
                    transaction_value: *const Transaction,
                    prelude: transaction_program.PreludeBinding,
                ) anyerror!Outcome {
                    return self.block.transactOwned(
                        transaction_value,
                        prelude,
                        self.mode,
                        self.observer,
                    );
                }
            };
        }

        /// Borrow a block facade that records and consumes pending observations.
        pub fn observe(self: *Self, observer: anytype) Instrumented(@TypeOf(observer)) {
            return .{ .block = self, .mode = .observed, .observer = observer };
        }

        /// Borrow a block facade bound to passive capture and an observation consumer.
        pub fn capture(
            self: *Self,
            context: *CaptureContext,
            observer: anytype,
        ) Instrumented(@TypeOf(observer)) {
            return .{
                .block = self,
                .mode = .{ .captured = context },
                .observer = observer,
            };
        }

        /// Claim one Executor branch for an ordered block fold.
        ///
        /// The Executor must have no unresolved transaction or accepted
        /// changes. The returned block must eventually be finished or cleaned
        /// up with `discardIfUnfinished`.
        pub fn init(
            executor: *Executor,
            environment: Env,
        ) Error!Self {
            std.debug.assert(executor.active_block_execution_generation == null);
            std.debug.assert(!executor.hasCurrentTransaction());
            if (executor.acceptedView().hasChanges()) return error.UncommittedChanges;
            return .{
                .transaction_runtime = TransactionRuntime.init(executor),
                .generation = claim(executor),
                .environment = environment,
                .state = ImplementationType.init(environment),
            };
        }

        /// Execute, include, and retain one transaction atomically.
        ///
        /// All fallible inclusion planning happens before retain. Rejection
        /// leaves both the Executor branch and block accumulator unchanged.
        pub fn transact(self: *Self, transaction_value: Transaction) Error!Outcome {
            return self.transactOwned(
                &transaction_value,
                null,
                .normal,
                {},
            ) catch |err| return @errorCast(err);
        }

        /// Fold one borrowed transaction whose family prelude shares the
        /// transaction program's journaled retain/discard lifetime. The caller
        /// pins `transaction_value` through synchronous inclusion.
        pub fn transactWithPrelude(
            self: *Self,
            transaction_value: *const Transaction,
            prelude: transaction_program.PreludeBinding,
        ) Error!Outcome {
            return self.transactOwned(
                transaction_value,
                prelude,
                .normal,
                {},
            ) catch |err| return @errorCast(err);
        }

        fn transactOwned(
            self: *Self,
            transaction_value: *const Transaction,
            prelude: ?transaction_program.PreludeBinding,
            mode: InstrumentationMode,
            observer: anytype,
        ) anyerror!Outcome {
            requireActive(self);
            const input = ImplementationType.transactInput(
                &self.environment,
                &self.state,
                transaction_value,
            );
            const outcome = if (prelude) |value|
                try transaction_program.transactInBlockWithPrelude(
                    &self.transaction_runtime,
                    input,
                    value,
                    mode,
                )
            else
                try transaction_program.transactInBlock(
                    &self.transaction_runtime,
                    input,
                    mode,
                );
            return switch (outcome) {
                .rejected => |reason| .{ .rejected = reason },
                .executed => |executed_value| blk: {
                    var executed = executed_value;
                    defer executed.discardIfCurrent();
                    const view = executed.view();
                    const plan = try ImplementationType.planInclude(
                        &self.environment,
                        &self.state,
                        transaction_value,
                        view.output,
                        view.logs,
                    );
                    const included = ImplementationType.included(
                        transaction_value,
                        view.output,
                        view.logs,
                        plan,
                    );
                    if (comptime @TypeOf(observer) != void)
                        try observer.observe(executed.observation());
                    executed.retain();
                    ImplementationType.applyInclude(&self.state, plan);
                    break :blk .{ .included = included };
                },
            };
        }

        /// Return current block-fold output without releasing ownership.
        pub fn progress(self: *const Self) Result {
            requireActive(self);
            return ImplementationType.finish(&self.environment, &self.state);
        }

        /// Return final block-fold output and release the Executor claim.
        ///
        /// This does not commit the accepted branch to a durable backend.
        pub fn finish(self: *Self) Result {
            requireActive(self);
            const result = ImplementationType.finish(&self.environment, &self.state);
            release(executorFor(self), self.generation);
            return result;
        }

        /// Roll back accepted block changes if this copy still owns the claim.
        ///
        /// This is the idempotent cleanup operation for `defer`.
        pub fn discardIfUnfinished(self: *Self) void {
            const executor = executorFor(self);
            if (executor.active_block_execution_generation != self.generation) return;
            executor.discardAccepted();
            release(executor, self.generation);
        }
    };
}

fn validateImplementation(comptime Runtime: type, comptime Implementation: type) void {
    comptime {
        std.debug.assert(@hasDecl(Implementation, "State"));
        std.debug.assert(@hasDecl(Implementation, "InclusionPlan"));
        std.debug.assert(@hasDecl(Implementation, "Error"));

        const Env = Implementation.Env;
        const Transaction = Runtime.Transaction;
        const Output = Runtime.Output;
        const Logs = Runtime.TransactionLogs;

        assertSignature(Implementation.init, &.{Env}, Implementation.State);
        assertSignature(Implementation.transactInput, &.{
            *const Env,
            *const Implementation.State,
            *const Transaction,
        }, Runtime.TransactInput);
        assertSignature(Implementation.planInclude, &.{
            *const Env,
            *const Implementation.State,
            *const Transaction,
            *const Output,
            Logs,
        }, Implementation.Error!Implementation.InclusionPlan);
        assertSignature(Implementation.included, &.{
            *const Transaction,
            *const Output,
            Logs,
            Implementation.InclusionPlan,
        }, Implementation.Included);
        assertSignature(Implementation.applyInclude, &.{
            *Implementation.State,
            Implementation.InclusionPlan,
        }, void);
        assertSignature(Implementation.finish, &.{
            *const Env,
            *const Implementation.State,
        }, Implementation.Result);
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
