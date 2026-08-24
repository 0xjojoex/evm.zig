//! Concrete Ethereum block fold over one exact transaction program.

const std = @import("std");

const block = @import("../block.zig");
const CaptureContext = @import("../executor/capture_context.zig").Context;
const InstrumentationMode = @import("../executor/instrumentation.zig").Mode;
const executor_errors = @import("../executor/error.zig");
const state = @import("../state.zig");
const transaction = @import("../transaction.zig");
const transaction_program = @import("../transaction/program.zig");
const transaction_result = @import("../transaction/result.zig");

/// Summary of included transactions in an Ethereum block fold.
const FoldResult = struct {
    /// Cumulative receipt gas.
    gas_used: u64 = 0,
    /// Cumulative block/header gas contribution.
    block_gas: transaction.BlockGas = .{},
    tx_count: u64 = 0,

    /// Cumulative progress in the shape transaction preparation consumes.
    pub fn preparation(self: FoldResult) transaction.PreparationBlockProgress {
        return .{ .receipt_gas_used = self.gas_used, .block_gas = self.block_gas };
    }
};
pub const Result = FoldResult;

/// Advance the fold by one included transaction's settled gas. This is the
/// canonical block-gas admission arithmetic; the BAL differential accumulator
/// delegates here so fold and cross-check cannot diverge.
pub fn advance(
    progress: FoldResult,
    env: transaction.Env,
    gas: transaction.ResultGas,
) error{ BlockGasExceeded, Overflow }!FoldResult {
    var next = progress;
    next.gas_used = std.math.add(u64, next.gas_used, gas.used) catch
        return error.BlockGasExceeded;
    next.block_gas = next.block_gas.add(gas.block) catch
        return error.BlockGasExceeded;
    if (!next.block_gas.withinLimit(env.gas_limit))
        return error.BlockGasExceeded;
    next.tx_count = std.math.add(u64, next.tx_count, 1) catch
        return error.Overflow;
    return next;
}

/// Ethereum transaction result paired with its block receipt.
const IncludedTransaction = struct {
    result: transaction_result.Execution,
    receipt: transaction_result.Receipt,
};

const TransactOutcome = union(enum) {
    rejected: transaction.validation.ValidationError,
    included: IncludedTransaction,
};
const BlockError = executor_errors.Error || error{
    BlockGasExceeded,
    Overflow,
    UncommittedChanges,
};

fn observerError(comptime Observer: type, comptime Observation: type) type {
    if (Observer == void) return error{};
    const Container = switch (@typeInfo(Observer)) {
        .pointer => |pointer| pointer.child,
        else => Observer,
    };
    if (!@hasDecl(Container, "observe"))
        @compileError("block observer must declare `observe`");
    const result = switch (@typeInfo(@TypeOf(
        @as(Observer, undefined).observe(@as(Observation, undefined)),
    ))) {
        .error_union => |value| value,
        else => @compileError("block observer `observe` must return an error union"),
    };
    if (result.payload != void)
        @compileError("block observer `observe` must return `!void`");
    return result.error_set;
}

/// Build the concrete Ethereum fold for one exact transaction program.
pub fn ExecutionType(comptime Program: type) type {
    const Executor = Program.Executor;

    return struct {
        const Self = @This();
        const PreludeError = error{};
        const PreludeBinding = transaction_program.PreludeBinding(PreludeError);

        pub const Transaction = transaction.Transaction;
        pub const Prelude = Program.PreludeFor(PreludeError);
        pub const PreludeContext = Program.PreludeContextFor(PreludeError);
        pub const Env = transaction.Env;
        pub const Included = IncludedTransaction;
        pub const Result = FoldResult;
        pub const Outcome = TransactOutcome;
        pub const Error = BlockError;

        executor: *Executor,
        claim: block.Claim,
        environment: Env,
        state_value: FoldResult = .{},

        fn Instrumented(comptime Observer: type) type {
            const InstrumentedError = BlockError || observerError(Observer, Executor.Observation);

            return struct {
                block_execution: *Self,
                mode: InstrumentationMode,
                observer: Observer,

                pub fn transact(
                    self: @This(),
                    transaction_value: Transaction,
                ) InstrumentedError!TransactOutcome {
                    return self.block_execution.transactOwned(
                        &transaction_value,
                        null,
                        self.mode,
                        self.observer,
                    );
                }

                pub fn transactWithPrelude(
                    self: @This(),
                    transaction_value: *const Transaction,
                    prelude: PreludeBinding,
                ) InstrumentedError!TransactOutcome {
                    return self.block_execution.transactOwned(
                        transaction_value,
                        prelude,
                        self.mode,
                        self.observer,
                    );
                }
            };
        }

        /// Claim one Executor branch for an ordered Ethereum block fold.
        pub fn init(executor: *Executor, environment: Env) error{UncommittedChanges}!Self {
            return .{
                .executor = executor,
                .claim = try block.Claim.begin(executor),
                .environment = environment,
            };
        }

        /// Borrow a block path that records and consumes pending observations.
        pub fn observe(self: *Self, observer: anytype) Instrumented(@TypeOf(observer)) {
            return .{ .block_execution = self, .mode = .observed, .observer = observer };
        }

        /// Borrow a block path with passive call capture and observation.
        pub fn capture(
            self: *Self,
            context: *CaptureContext,
            observer: anytype,
        ) Instrumented(@TypeOf(observer)) {
            return .{
                .block_execution = self,
                .mode = .{ .captured = context },
                .observer = observer,
            };
        }

        /// Execute, include, and retain one Ethereum transaction atomically.
        pub fn transact(self: *Self, transaction_value: Transaction) BlockError!TransactOutcome {
            return self.transactOwned(&transaction_value, null, .normal, {});
        }

        /// Execute a transaction with a journaled before-transaction prelude.
        pub fn transactWithPrelude(
            self: *Self,
            transaction_value: *const Transaction,
            prelude: PreludeBinding,
        ) BlockError!TransactOutcome {
            return self.transactOwned(transaction_value, prelude, .normal, {});
        }

        fn transactOwned(
            self: *Self,
            transaction_value: *const Transaction,
            prelude: ?PreludeBinding,
            mode: InstrumentationMode,
            observer: anytype,
        ) (BlockError || observerError(@TypeOf(observer), Executor.Observation))!TransactOutcome {
            self.claim.requireActive(self.executor);
            const input: Program.TransactInput = .{
                .env = self.environment,
                .tx = transaction_value.*,
                .progress = self.state_value.preparation(),
            };
            const outcome = if (prelude) |value|
                try Program.transactInBlockWithPrelude(
                    PreludeError,
                    self.executor,
                    self.claim,
                    input,
                    value,
                    mode,
                )
            else
                try Program.transactInBlock(self.executor, self.claim, input, mode);

            return switch (outcome) {
                .rejected => |reason| .{ .rejected = reason },
                .executed => |executed_value| blk: {
                    var executed = executed_value;
                    defer executed.discardIfCurrent();
                    const view = executed.view();

                    const next = try advance(self.state_value, self.environment, view.output.gas);

                    const included: IncludedTransaction = .{
                        .result = view.output.*,
                        .receipt = .{
                            .status = view.output.status,
                            .gas_used = view.output.gas.used,
                            .cumulative_gas_used = next.gas_used,
                            .created_address = view.output.created_address,
                            .logs = view.logs,
                        },
                    };

                    if (comptime @TypeOf(observer) != void)
                        try observer.observe(executed.observation());
                    executed.retain();
                    self.state_value = next;
                    break :blk .{ .included = included };
                },
            };
        }

        /// Return current fold output without releasing ownership.
        pub fn progress(self: *const Self) FoldResult {
            self.claim.requireActive(self.executor);
            return self.state_value;
        }

        /// Return the final fold output and release the Executor claim.
        pub fn finish(self: *Self) FoldResult {
            self.claim.requireActive(self.executor);
            const result = self.state_value;
            self.claim.release(self.executor);
            return result;
        }

        /// Roll back accepted changes if this copy still owns the block claim.
        pub fn discardIfUnfinished(self: *Self) void {
            self.claim.discardIfUnfinished(self.executor);
        }
    };
}
