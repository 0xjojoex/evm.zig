const std = @import("std");
const support = @import("vm_support.zig");

const evmz = support.evmz;
const protocol_module = support.protocol_module;
const transaction = support.transaction;
const Default = support.Default;
const addr = support.addr;
const BlockResult = support.BlockResult;
const Env = support.Env;
const Log = support.Log;
const TxExecutionResult = support.TxExecutionResult;
const TxStatus = support.TxStatus;
const defaultTransact = support.defaultTransact;

test "Env execution context derives opcode-visible gas limit from the environment" {
    const origin = addr(0xaaaa);
    const env = Env{ .chain_id = 10, .gas_limit = 30_000_000 };
    const context = env.executionContext(origin, 7, &.{});

    try std.testing.expectEqual(@as(u256, 10), context.chain.chain_id);
    try std.testing.expectEqual(@as(u64, 30_000_000), context.block.gas_limit);
    try std.testing.expectEqual(origin, context.transaction.origin);
    try std.testing.expectEqual(@as(u256, 7), context.transaction.gas_price);
}

test "Ethereum family compiler defines the runtime scopes" {
    const DefaultContext = Default.Context(Default.TransactInput);
    const DefaultTransition = Default.Transition(Default.TransactInput);
    const TransitionContextPointer = @typeInfo(@TypeOf(DefaultTransition.transact)).@"fn".params[0].type.?;
    const TransitionContext = @typeInfo(TransitionContextPointer).pointer.child;

    try std.testing.expect(@sizeOf(Default) >= @sizeOf(Default.TransactionPolicy));
    try std.testing.expectEqual(@as(usize, 1), @typeInfo(Default).@"struct".fields.len);
    try std.testing.expect(@hasDecl(Default, "transact"));
    try std.testing.expect(@hasDecl(Default, "TransactInput"));
    try std.testing.expect(!@hasDecl(Default, "BlockTransactResult"));
    try std.testing.expect(@hasDecl(Default, "Transition"));
    try std.testing.expect(!@hasDecl(Default, "TransactionProgram"));
    try std.testing.expect(Default.Error != anyerror);
    try std.testing.expect(Default.BlockExecution.Error != anyerror);
    try std.testing.expect(DefaultContext.Revision == Default.Revision);
    try std.testing.expect(TransitionContext == DefaultContext);
    try std.testing.expect(@hasDecl(Default, "Program"));
    try std.testing.expect(!@hasDecl(evmz, "EvmWith"));
    try std.testing.expect(!@hasDecl(Default, "Block"));
    try std.testing.expect(!@hasDecl(Default, "BlockProtocol"));
    try std.testing.expect(!@hasDecl(Default, "Options"));
    try std.testing.expect(!@hasDecl(Default, "TransactionView"));
    try std.testing.expect(!@hasDecl(Default, "IncludedTransactionView"));
    try std.testing.expect(!@hasDecl(Default, "BlockGas"));
    try std.testing.expect(!@hasDecl(Default, "ResultGas"));
    try std.testing.expect(@hasDecl(Default, "BlockExecution"));
    try std.testing.expect(@hasDecl(Default, "Sequential"));
    try std.testing.expect(!@hasDecl(Default, "BlockSession"));
    try std.testing.expect(@hasDecl(Default, "init"));
    try std.testing.expect(!@hasDecl(Default, "unsafeExecutor"));
    try std.testing.expect(!@hasDecl(Default, "executeTransaction"));
    try std.testing.expect(!@hasDecl(Default, "transactCommit"));
    try std.testing.expect(!@hasDecl(Default, "commit"));
    try std.testing.expect(!@hasDecl(Default.Executed, "receipt"));
    try std.testing.expect(@hasDecl(Default.Executed, "retain"));
    try std.testing.expect(@hasDecl(Default.Executed, "discard"));
    try std.testing.expect(!@hasDecl(Default.Executed, "accept"));
    try std.testing.expect(!@hasDecl(Default.Executed, "reject"));
    try std.testing.expect(!@hasDecl(evmz, "BlockProgram"));
    try std.testing.expect(!@hasDecl(transaction, "Program"));
    try std.testing.expect(!@hasDecl(transaction, "Context"));
}

test "production binding preserves public carrier identity" {
    comptime {
        if (@typeInfo(@TypeOf(Default.transact)).@"fn".return_type.? != Default.Error!Default.Outcome)
            @compileError("family transact return drifted");
        if (@hasDecl(Default, "BlockProgram"))
            @compileError("family still exposes the reverse block-program descriptor");
        if (Default.BlockExecution.TransactionRuntime != Default)
            @compileError("block transaction runtime identity drifted");
        if (Default.BlockExecution.Transaction != Default.Transaction)
            @compileError("block transaction carrier drifted");
        if (Default.BlockExecution.Output != Default.Output)
            @compileError("block output carrier drifted");
        if (@typeInfo(@TypeOf(Default.BlockExecution.transact)).@"fn".return_type.? != Default.BlockExecution.Error!Default.BlockExecution.Outcome)
            @compileError("block transact return drifted");
        if (Default.BlockExecution == Default.Sequential)
            @compileError("direct block fold collapsed into family Sequential convenience");
    }
}

test "transaction and block customization preserve Executor identity" {
    const overrides = struct {
        fn maxInitcodeSize(_: evmz.eth.Revision) usize {
            return 2048;
        }

        fn beforeBlock(_: evmz.eth.Revision, _: protocol_module.BeforeBlockContext) protocol_module.BlockSystemCalls {
            return .{};
        }
    };
    const Alternate = evmz.eth.extend(.{
        .transaction = .{ .maxInitcodeSize = overrides.maxInitcodeSize },
        .block = .{ .beforeBlock = overrides.beforeBlock },
    });
    const AlternateBlockOnly = evmz.eth.extend(.{
        .block = .{ .beforeBlock = overrides.beforeBlock },
    });
    comptime {
        if (Default == Alternate)
            @compileError("family customization collapsed to the base family");
        if (Default.Executor != Alternate.Executor)
            @compileError("transaction or block customization changed Executor identity");
        if (Default.Executor.Protocol != Default.ExecutionProtocol)
            @compileError("family Executor is not bound to the execution-only protocol");
        if (@hasDecl(Default.Executor.Protocol, "transaction"))
            @compileError("execution protocol leaked transaction policy");
        if (@hasDecl(Default.Executor.Protocol, "block"))
            @compileError("execution protocol leaked block policy");
        if (Default.TransactionRuntime != AlternateBlockOnly.TransactionRuntime)
            @compileError("block customization changed transaction-runtime identity");
        if (Default.BlockExecution == AlternateBlockOnly.BlockExecution)
            @compileError("block customization did not change block-runtime identity");
    }
}

test "Executed carries family output beside the checked lease" {
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(Default.Executor.ExecutionLease));
    try std.testing.expect(@sizeOf(Default.Executed) >= @sizeOf(Default.Executor.ExecutionLease));
    try std.testing.expect(@sizeOf(Default.Executed) <= @sizeOf(Default.Executor.ExecutionLease) + @sizeOf(TxExecutionResult) + @alignOf(TxExecutionResult));
    try std.testing.expect(!@hasField(Default, "direct_execution"));
}

test "transaction prelude is narrow and replaces the prepared block bridge" {
    const Bound = Default;
    try std.testing.expect(@hasDecl(Bound, "Prelude"));
    try std.testing.expect(@hasDecl(Default.BlockExecution, "transactWithPrelude"));
    try std.testing.expect(!@hasDecl(Bound, "transactPreparedInBlock"));
    try std.testing.expect(!@hasField(Default.PreludeContext, "executor"));
    try std.testing.expect(!@hasDecl(Default.PreludeContext, "retain"));
    try std.testing.expect(!@hasDecl(Default.PreludeContext, "discard"));
    try std.testing.expect(!@hasDecl(Default.PreludeContext, "addBalance"));
}

test "transaction boundary preserves bounded resource failures" {
    var executor = Default.Executor.init(std.testing.allocator, .{ .revision = .cancun });
    defer executor.deinit();
    try executor.state.configureAccessResources(.{
        .accounts = 1,
        .storage_keys = 0,
    });

    try std.testing.expectError(error.WarmAccountCapacityExceeded, defaultTransact(&executor, .{
        .env = .{ .gas_limit = 100_000 },
        .tx = .{
            .sender = addr(0xaaaa),
            .to = addr(0xbbbb),
            .gas_limit = 30_000,
        },
    }));
    try std.testing.expect(!executor.hasCurrentTransaction());
}

test "transaction program wrapper extends Ethereum before the family completes attempt" {
    const WrappedTx = struct {
        ethereum: Default.Transaction,
        family_credit: u256,
    };
    const WrappedInput = struct {
        env: Env,
        tx: WrappedTx,
        progress: transaction.PreparationBlockProgress = .{},
    };
    const WrappedOutput = struct {
        ethereum: TxExecutionResult,
        family_credit: u256,
    };
    const WrappedContext = Default.Context(WrappedInput);
    const BaseWrappedTransition = Default.Transition(WrappedInput);
    const WrappedTransition = struct {
        pub const Error = BaseWrappedTransition.Error || error{WrappedPolicyFailure};

        pub fn transact(
            context: *WrappedContext,
            tx_value: WrappedTx,
        ) Error!transaction.TransitionOutcome(WrappedOutput, Default.Rejection) {
            const base = try BaseWrappedTransition.transact(context, tx_value.ethereum);
            return switch (base) {
                .rejected => |reason| .{ .rejected = reason },
                .completed => |output| blk: {
                    const attempt = try context.activeAttempt();
                    try attempt.addBalance(addr(0xfee), tx_value.family_credit);
                    break :blk .{ .completed = .{
                        .ethereum = output,
                        .family_credit = tx_value.family_credit,
                    } };
                },
            };
        }
    };
    const WrappedVm = Default.Program(
        WrappedTx,
        WrappedInput,
        WrappedOutput,
        Default.Rejection,
        WrappedTransition,
    );
    const WrappedIncluded = struct {
        output: WrappedOutput,
        cumulative_transactions: u64,
    };
    const WrappedBlockImpl = struct {
        pub const State = u64;
        pub const Error = error{Overflow};
        pub const PreludeError = error{};
        pub const InclusionPlan = u64;

        pub fn init(_: Env) State {
            return 0;
        }

        pub fn transactInput(
            env: *const Env,
            _: *const State,
            tx_value: *const WrappedTx,
        ) WrappedVm.TransactInput {
            return .{ .env = env.*, .tx = tx_value.* };
        }

        pub fn planInclude(
            _: *const Env,
            state: *const State,
            _: *const WrappedTx,
            _: *const WrappedOutput,
            _: []const Log,
        ) Error!InclusionPlan {
            return std.math.add(u64, state.*, 1) catch error.Overflow;
        }

        pub fn included(
            _: *const WrappedTx,
            output: *const WrappedOutput,
            _: []const Log,
            plan: InclusionPlan,
        ) WrappedIncluded {
            return .{
                .output = output.*,
                .cumulative_transactions = plan,
            };
        }

        pub fn applyInclude(state: *State, plan: InclusionPlan) void {
            state.* = plan;
        }

        pub fn finish(_: *const Env, state: *const State) u64 {
            return state.*;
        }
    };
    const WrappedBlockExecution = WrappedVm.Block(
        Env,
        WrappedIncluded,
        u64,
        WrappedBlockImpl,
    );
    comptime {
        if (WrappedVm.Executor != Default.Executor)
            @compileError("transaction program changed Executor identity");
        if (WrappedVm.Context != Default.Context(WrappedInput))
            @compileError("program facade changed its canonical Context identity");
        if (WrappedVm.Transaction != WrappedTx)
            @compileError("wrapped transaction type was lost");
        if (WrappedVm.Output != WrappedOutput)
            @compileError("wrapped output type was lost");
        if (WrappedBlockExecution.TransactionRuntime != WrappedVm)
            @compileError("wrapped block program changed transaction runtime identity");
        if (WrappedVm.Error == anyerror)
            @compileError("wrapped transaction program reopened anyerror");
        if (WrappedBlockExecution.Error == anyerror)
            @compileError("wrapped block program reopened anyerror");

        const family_error: WrappedVm.Error = error.WrappedPolicyFailure;
        const block_error: WrappedBlockExecution.Error = error.Overflow;
        if (family_error != error.WrappedPolicyFailure)
            @compileError("wrapped transaction error was lost");
        if (block_error != error.Overflow)
            @compileError("wrapped block error was lost");
    }

    const sender = addr(0xaaaa);
    const recipient = addr(0xbbbb);
    var executor = Default.Executor.init(std.testing.allocator, .{ .revision = .cancun });
    defer executor.deinit();
    var wrapped_vm = WrappedVm.init(&executor);

    var discarded = switch (try wrapped_vm.transact(.{
        .env = .{ .gas_limit = 100_000 },
        .tx = .{
            .ethereum = .{
                .sender = sender,
                .gas_limit = 30_000,
                .to = recipient,
            },
            .family_credit = 7,
        },
    })) {
        .executed => |executed| executed,
        .rejected => return error.UnexpectedRejection,
    };
    defer discarded.discardIfCurrent();
    try std.testing.expectEqual(@as(u256, 7), (try discarded.output()).family_credit);
    try discarded.discard();
    try std.testing.expectEqual(@as(u256, 0), try executor.getBalance(addr(0xfee)));

    var retained = switch (try wrapped_vm.transact(.{
        .env = .{ .gas_limit = 100_000 },
        .tx = .{
            .ethereum = .{
                .sender = sender,
                .gas_limit = 30_000,
                .to = recipient,
            },
            .family_credit = 11,
        },
    })) {
        .executed => |executed| executed,
        .rejected => return error.UnexpectedRejection,
    };
    defer retained.discardIfCurrent();
    try retained.retain();
    try std.testing.expectEqual(@as(u256, 11), try executor.getBalance(addr(0xfee)));

    var block_executor = Default.Executor.init(std.testing.allocator, .{ .revision = .cancun });
    defer block_executor.deinit();
    var block = try WrappedBlockExecution.init(
        &block_executor,
        .{ .gas_limit = 100_000 },
    );
    defer block.discardIfUnfinished();
    const included = switch (try block.transact(.{
        .ethereum = .{
            .sender = sender,
            .gas_limit = 30_000,
            .to = recipient,
        },
        .family_credit = 13,
    })) {
        .included => |value| value,
        .rejected => return error.UnexpectedRejection,
    };
    try std.testing.expectEqual(@as(u256, 13), included.output.family_credit);
    try std.testing.expectEqual(@as(u64, 1), included.cumulative_transactions);
    try std.testing.expectEqual(@as(u64, 1), try block.finish());
}

test "block programs vary independently above one transaction runtime" {
    const Fold = struct {
        pub const State = BlockResult;
        pub const Error = error{ BlockGasExceeded, Overflow };
        pub const PreludeError = error{};
        pub const InclusionPlan = struct { next: State };

        pub fn init(_: Env) State {
            return .{};
        }

        pub fn transactInput(
            env: *const Env,
            state: *const State,
            tx_value: *const Default.Transaction,
        ) Default.TransactInput {
            return .{
                .env = env.*,
                .tx = tx_value.*,
                .progress = .{
                    .receipt_gas_used = state.gas_used,
                    .block_gas = state.block_gas,
                },
            };
        }

        pub fn planInclude(
            env: *const Env,
            state: *const State,
            _: *const Default.Transaction,
            output: *const Default.Output,
            _: []const Default.TransactionLog,
        ) Error!InclusionPlan {
            var next = state.*;
            next.gas_used = std.math.add(u64, next.gas_used, output.gas.used) catch return error.Overflow;
            next.block_gas = next.block_gas.add(output.gas.block) catch return error.Overflow;
            if (!next.block_gas.withinLimit(env.gas_limit)) return error.BlockGasExceeded;
            next.tx_count = std.math.add(u64, next.tx_count, 1) catch return error.Overflow;
            return .{ .next = next };
        }

        pub fn included(
            _: *const Default.Transaction,
            output: *const Default.Output,
            logs: []const Default.TransactionLog,
            plan: InclusionPlan,
        ) Default.BlockExecution.Included {
            return .{
                .result = output.*,
                .receipt = .{
                    .status = output.status,
                    .gas_used = output.gas.used,
                    .cumulative_gas_used = plan.next.gas_used,
                    .created_address = output.created_address,
                    .logs = logs,
                },
            };
        }

        pub fn applyInclude(state: *State, plan: InclusionPlan) void {
            state.* = plan.next;
        }

        pub fn finish(_: *const Env, state: *const State) BlockResult {
            return state.*;
        }
    };
    const CountingFold = struct {
        pub const State = Fold.State;
        pub const Error = Fold.Error;
        pub const PreludeError = Fold.PreludeError;
        pub const InclusionPlan = Fold.InclusionPlan;

        pub const init = Fold.init;
        pub const transactInput = Fold.transactInput;
        pub const planInclude = Fold.planInclude;
        pub const included = Fold.included;
        pub fn applyInclude(state: *State, plan: InclusionPlan) void {
            state.* = plan.next;
            state.tx_count +|= 100;
        }
        pub const finish = Fold.finish;
    };
    const PreludeFold = struct {
        pub const State = Fold.State;
        pub const Error = Fold.Error;
        pub const PreludeError = error{CustomPreludeFailure};
        pub const InclusionPlan = Fold.InclusionPlan;

        pub const init = Fold.init;
        pub const transactInput = Fold.transactInput;
        pub const planInclude = Fold.planInclude;
        pub const included = Fold.included;
        pub const applyInclude = Fold.applyInclude;
        pub const finish = Fold.finish;
    };
    const ConcreteContext = Default.Context(Default.TransactInput);
    const ConcreteEthereum = Default.Transition(Default.TransactInput);
    const DefaultProgram = Default.Program(
        Default.Transaction,
        Default.TransactInput,
        Default.Output,
        Default.Rejection,
        ConcreteEthereum,
    );
    const Bound = DefaultProgram.Block(
        Env,
        Default.BlockExecution.Included,
        BlockResult,
        Fold,
    );
    const CountingBound = DefaultProgram.Block(
        Env,
        Default.BlockExecution.Included,
        BlockResult,
        CountingFold,
    );
    const RuntimePolicyProbe = struct {
        fn totalGasLimit(_: Default.Revision) ?u64 {
            return null;
        }
    };
    const ConcreteTransition = struct {
        pub const Error = ConcreteEthereum.Error || error{TransactionPolicySnapshotLost};

        pub fn transact(
            context: *ConcreteContext,
            tx_value: Default.Transaction,
        ) Error!transaction.TransitionOutcome(Default.Output, Default.Rejection) {
            if (context.policy().transaction.totalGasLimit != RuntimePolicyProbe.totalGasLimit)
                return error.TransactionPolicySnapshotLost;
            return ConcreteEthereum.transact(context, tx_value);
        }
    };
    const ConcreteRuntime = Default.Program(
        Default.Transaction,
        Default.TransactInput,
        Default.Output,
        Default.Rejection,
        ConcreteTransition,
    );
    const ConcretePreludeBound = ConcreteRuntime.Block(
        Env,
        Default.BlockExecution.Included,
        BlockResult,
        PreludeFold,
    );
    comptime {
        std.debug.assert(Bound.TransactionRuntime == DefaultProgram);
        std.debug.assert(CountingBound.TransactionRuntime == DefaultProgram);
        std.debug.assert(Bound != CountingBound);
        std.debug.assert(ConcretePreludeBound.TransactionRuntime == ConcreteRuntime.withPreludeError(PreludeFold.PreludeError));
        const prelude_error: ConcretePreludeBound.Error = error.CustomPreludeFailure;
        std.debug.assert(prelude_error == error.CustomPreludeFailure);
    }

    var executor = Default.Executor.init(std.testing.allocator, .{ .revision = .cancun });
    defer executor.deinit();
    var block = try Bound.init(
        &executor,
        .{ .gas_limit = 100_000 },
    );
    defer block.discardIfUnfinished();
    try std.testing.expectError(error.BlockExecutionActive, defaultTransact(&executor, .{
        .env = .{ .gas_limit = 100_000 },
        .tx = .{ .sender = addr(0xaaaa), .to = addr(0xbbbb), .gas_limit = 30_000 },
    }));
    const included = switch (try block.transact(.{
        .sender = addr(0xaaaa),
        .to = addr(0xbbbb),
        .gas_limit = 30_000,
    })) {
        .included => |value| value,
        .rejected => return error.UnexpectedRejection,
    };
    try std.testing.expectEqual(TxStatus.success, included.result.status);
    const result = try block.finish();
    try std.testing.expectEqual(@as(u64, 1), result.tx_count);

    var prelude_executor = Default.Executor.init(std.testing.allocator, .{ .revision = .cancun });
    defer prelude_executor.deinit();
    var transaction_policy = Default.transaction_policy;
    transaction_policy.transaction.totalGasLimit = RuntimePolicyProbe.totalGasLimit;
    const concrete_runtime = ConcreteRuntime.initWithPolicy(&prelude_executor, transaction_policy);
    var prelude_block = try ConcretePreludeBound.initWithRuntime(
        concrete_runtime,
        .{ .gas_limit = 100_000 },
    );
    defer prelude_block.discardIfUnfinished();
    const FailingPrelude = struct {
        pub fn run(
            _: *@This(),
            _: ConcretePreludeBound.PreludeContext,
        ) ConcretePreludeBound.PreludeContext.Error!void {
            return error.CustomPreludeFailure;
        }
    };
    var failing_prelude = FailingPrelude{};
    try std.testing.expectError(error.CustomPreludeFailure, prelude_block.transactWithPrelude(
        .{ .sender = addr(0xaaaa), .to = addr(0xbbbb), .gas_limit = 30_000 },
        ConcretePreludeBound.Prelude.init(&failing_prelude),
    ));
    try std.testing.expectEqual(@as(u64, 0), (try prelude_block.finish()).tx_count);
}
