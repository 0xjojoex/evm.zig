//! Exact-spec EVM compiler.
//!
//! `Vm(spec)` closes every semantic choice at comptime. Runtime fork selection
//! belongs to the caller; no revision state enters the generated VM.

const std = @import("std");

const address = @import("./address.zig");
const block_hash_source = @import("./BlockHashSource.zig");
const block_program_module = @import("./block_program.zig");
const engine_spec = @import("./spec.zig");
const ethereum_block_program = @import("./block_program/ethereum.zig");
const ethereum_tx_transition = @import("./transaction/transition.zig");
const transaction_validation = @import("./transaction/validation.zig");
const executor_module = @import("./executor.zig");
const InstrumentationMode = @import("./executor/instrumentation.zig").Mode;
const execution = @import("./execution.zig");
const Host = @import("./Host.zig");
const interpreter = @import("./Interpreter.zig");
const instruction = @import("./instruction.zig");
const state_module = @import("./state.zig");
const block_state = @import("./vm/block_state.zig");
const transaction = @import("./transaction.zig");
const transaction_program = @import("./transaction/program.zig");

const Address = address.Address;
const addr = address.addr;

pub const StateReader = executor_module.state_io.StateReader;
pub const BlockHashSource = block_hash_source;
pub const Committer = executor_module.state_io.Committer;
pub const Log = Host.Log;

/// Block/environment values supplied by the caller.
///
/// The engine has exactly one of these. Transaction preparation reads the same
/// type the caller fills in, so there is nothing to copy between the two.
pub const Env = transaction.Env;

/// Terminal status of a transaction that reached execution.
pub const TxStatus = execution.Status;

/// Execution payload for a transaction that passed validation and ran.
///
/// `output` is borrowed from the owning Executor and remains valid until its
/// next operation can replace call output.
pub const TxExecutionResult = struct {
    status: TxStatus,
    /// Settled transaction gas: receipt gas, refund gas, and block contribution.
    gas: transaction.ResultGas = .{},
    output: []const u8 = &.{},
    created_address: ?Address = null,
};

/// Borrowed transaction receipt view for client/fixture receipt builders.
///
/// `logs` is borrowed from the owning execution scope and is valid only until
/// its next operation advances or closes that scope. Copy it when constructing
/// owned receipts.
pub const TxReceiptView = struct {
    status: TxStatus,
    /// Receipt gas for this transaction.
    gas_used: u64 = 0,
    /// Receipt cumulative gas across included transactions in this block execution.
    cumulative_gas_used: u64 = 0,
    created_address: ?Address = null,
    logs: state_module.LogBuffer.View = .empty,
};

/// Summary of included transactions in a `BlockExecution`.
pub const BlockResult = struct {
    /// Cumulative receipt gas.
    gas_used: u64 = 0,
    /// Cumulative block/header gas contribution.
    block_gas: transaction.BlockGas = .{},
    tx_count: u64 = 0,
};

/// Read-only account view borrowed from an Executor overlay/state-reader cache.
pub const AccountView = struct {
    nonce: u64,
    balance: u256,
    code: []const u8 = &.{},
};

pub const Call = executor_module.Call;
pub const Create = executor_module.Create;
pub const EvmResult = executor_module.EvmResult;
pub const CompileOptions = executor_module.CompileOptions;

/// Explicit non-transaction system call for block-hook style operations.
pub const SystemCall = struct {
    sender: Address,
    recipient: Address,
    input: []const u8 = &.{},
    gas: u64,
};

/// Header facts not already carried by `Env` that seed before-block hooks.
pub const BeforeBlockInput = struct {
    parent_hash: ?[32]u8 = null,
    parent_beacon_block_root: ?[32]u8 = null,
};
pub const AfterTransactionContext = block_program_module.AfterTransactionContext;
pub const FinalizeBlockContext = block_program_module.FinalizeBlockContext;

/// Compile one complete exact specification into its concrete VM type.
/// Runtime fork selection belongs outside this boundary.
pub fn Vm(comptime spec: engine_spec.Spec) type {
    return VmWithOptions(spec, .{});
}

pub fn VmWithOptions(comptime spec: engine_spec.Spec, comptime options_value: CompileOptions) type {
    return VmType(spec, block_state.Tracked(spec), options_value);
}

pub fn BalStatelessVm(comptime spec: engine_spec.Spec) type {
    return BalStatelessVmWithOptions(spec, .{});
}

pub fn BalStatelessVmWithOptions(
    comptime spec: engine_spec.Spec,
    comptime options_value: CompileOptions,
) type {
    return VmType(spec, block_state.BalStateless, options_value);
}

pub fn VmType(
    comptime spec: engine_spec.Spec,
    comptime BlockStateType: type,
    comptime options_value: CompileOptions,
) type {
    comptime BlockStateType.checkSpec(spec);

    return struct {
        const Self = @This();

        const PublicTransactInput = struct {
            env: Env,
            tx: transaction.Transaction,
            progress: transaction.PreparationBlockProgress = .{},
        };

        const EthereumTxTransition = Self.Transition(PublicTransactInput);

        const TransactionRuntime = Self.Program(
            transaction.Transaction,
            PublicTransactInput,
            TxExecutionResult,
            transaction_validation.ValidationError,
            EthereumTxTransition,
        );

        const EthereumBlock = ethereum_block_program.bind(TransactionRuntime, Env, IncludedTransactionType, BlockResult);

        const BlockTransactionRuntime = transaction_program.ProgramType(
            Executor,
            transaction.Transaction,
            PublicTransactInput,
            TxExecutionResult,
            transaction_validation.ValidationError,
            EthereumTxTransition,
            EthereumBlock.Implementation.PreludeError,
        );
        const BlockExecutionType = block_program_module.bind(
            BlockTransactionRuntime,
            Executor,
            transaction.Transaction,
            PublicTransactInput,
            TxExecutionResult,
            transaction_validation.ValidationError,
            Env,
            IncludedTransactionType,
            BlockResult,
            EthereumBlock.Implementation,
        );

        const ReceiptType = struct {
            status: TxStatus,
            gas_used: u64 = 0,
            cumulative_gas_used: u64 = 0,
            created_address: ?Address = null,
            logs: Executor.State.LogView = .empty,
        };
        const IncludedTransactionType = struct {
            result: TxExecutionResult,
            receipt: ReceiptType,
        };

        pub const specification = spec;
        pub const compile_options = options_value;
        pub const BlockState = BlockStateType;

        pub const Executor = executor_module.ExecutorType(spec, BlockState, options_value);
        pub const Interpreter = interpreter.Interpreter(spec);
        pub const Transaction = transaction.Transaction;
        pub const TransactionLog = Log;
        pub const TransactionLogs = TransactionRuntime.TransactionLogs;
        pub const TransactInput = PublicTransactInput;
        pub const Output = TxExecutionResult;
        pub const Rejection = transaction_validation.ValidationError;
        pub const Executed = TransactionRuntime.Executed;
        pub const Prelude = TransactionRuntime.Prelude;
        pub const PreludeContext = TransactionRuntime.PreludeContext;
        pub const Outcome = TransactionRuntime.Outcome;
        pub const Error = TransactionRuntime.Error;
        pub const Gas = transaction.GasRuntime(spec);
        pub const Settlement = transaction.SettlementRuntime(spec);
        pub const BlockExecution = BlockExecutionType;

        transaction_runtime: TransactionRuntime,

        pub const Observed = struct {
            vm: *Self,

            pub fn transact(self: Observed, input: TransactInput) Error!Outcome {
                return self.vm.transaction_runtime.observe().transact(input);
            }
        };

        pub const Captured = struct {
            vm: *Self,
            context: *executor_module.CaptureContext,

            pub fn transact(self: Captured, input: TransactInput) Error!Outcome {
                return self.vm.transaction_runtime.capture(self.context).transact(input);
            }
        };

        /// Bind this exact VM family to one caller-owned Executor.
        ///
        /// The VM borrows the Executor and owns no independent lifecycle state.
        pub fn init(executor: *Executor) Self {
            return .{ .transaction_runtime = TransactionRuntime.init(executor) };
        }

        /// Validate and execute one family transaction.
        ///
        /// Rejection changes no state. Completion returns the sole unresolved
        /// `Executed` owner, which must be retained or discarded before the
        /// Executor can accept another transaction.
        pub fn transact(self: *Self, input: TransactInput) Error!Outcome {
            return self.transaction_runtime.transact(input);
        }

        /// Borrow a VM facade that records state observations.
        pub fn observe(self: *Self) Observed {
            return .{ .vm = self };
        }

        /// Borrow a VM facade bound to caller-owned passive capture storage.
        pub fn capture(self: *Self, context: *executor_module.CaptureContext) Captured {
            return .{ .vm = self, .context = context };
        }

        /// Define the narrow family-authoring context for a custom input type.
        pub fn Context(comptime Input: type) type {
            return transaction_program.ContextType(Executor, Input);
        }

        /// Bind Ethereum transaction stage helpers to a custom input type.
        pub fn Transition(comptime Input: type) type {
            return ethereum_tx_transition.bind(spec, Executor, Context(Input), TxExecutionResult);
        }

        /// Bind one closed transaction representation and workflow to this VM.
        pub fn Program(
            comptime TransactionType: type,
            comptime InputType: type,
            comptime OutputType: type,
            comptime RejectionType: type,
            comptime ImplementationType: type,
        ) type {
            return transaction_program.ProgramType(
                Executor,
                TransactionType,
                InputType,
                OutputType,
                RejectionType,
                ImplementationType,
                error{},
            );
        }

        /// One-worker Ethereum block lifecycle over the exact VM.
        pub const Sequential = struct {
            const SequentialSelf = @This();

            const Phase = enum {
                transactions,
                post_transactions,
                finalized,
            };

            pub const InitOptions = struct {
                env: Env,
            };

            const RetainedTransaction = struct {
                index: u64,
                status: execution.Status,
                gas_used: u64,
            };

            block: BlockExecution,
            phase: Phase = .transactions,
            retained_for_after_hook: ?RetainedTransaction = null,

            fn InstrumentedSession(comptime Observer: type) type {
                return struct {
                    session: *SequentialSelf,
                    mode: InstrumentationMode,
                    observer: Observer,

                    pub fn transact(self: @This(), tx: Transaction) !BlockExecution.Outcome {
                        return self.session.transactMode(tx, self.mode, self.observer);
                    }

                    pub fn systemCall(self: @This(), call: SystemCall) !EvmResult {
                        return self.session.systemCallMode(call, self.mode, self.observer);
                    }
                };
            }

            pub fn observe(self: *SequentialSelf, observer: anytype) InstrumentedSession(@TypeOf(observer)) {
                return .{ .session = self, .mode = .observed, .observer = observer };
            }

            pub fn capture(
                self: *SequentialSelf,
                context: *executor_module.CaptureContext,
                observer: anytype,
            ) InstrumentedSession(@TypeOf(observer)) {
                return .{
                    .session = self,
                    .mode = .{ .captured = context },
                    .observer = observer,
                };
            }

            pub fn init(executor: *Executor, options: InitOptions) !@This() {
                return .{ .block = try BlockExecution.init(executor, options.env) };
            }

            /// Return included block progress.
            pub fn progress(self: *const @This()) BlockResult {
                self.requireActive();
                return self.block.progress();
            }

            pub fn beforeBlock(self: *@This(), input: BeforeBlockInput) !void {
                self.requireActive();
                if (self.phase != .transactions) return error.TransactionPhaseClosed;
                if (block_program_module.executorFor(&self.block).hasCurrentTransaction()) return error.ExecutedTransactionActive;
                try executor_module.system_contracts.applyBeforeBlock(
                    block_program_module.executorFor(&self.block),
                    self.lifecycleExecutionContext(),
                    .{
                        .number = self.block.environment.number,
                        .timestamp = self.block.environment.timestamp,
                        .parent_hash = input.parent_hash,
                        .parent_beacon_block_root = input.parent_beacon_block_root,
                    },
                );
            }

            pub fn transact(self: *@This(), tx: Transaction) !BlockExecution.Outcome {
                return self.transactMode(tx, .normal, {});
            }

            fn transactMode(
                self: *@This(),
                tx: Transaction,
                mode: InstrumentationMode,
                observer: anytype,
            ) !BlockExecution.Outcome {
                self.requireActive();
                if (self.phase != .transactions) return error.TransactionPhaseClosed;
                try self.flushAfterTransaction();
                const progress_value = self.block.progress();
                var prelude = EthereumBlock.Prelude{
                    .env = self.block.environment,
                    .transaction_index = progress_value.tx_count,
                };
                const outcome = switch (mode) {
                    .normal => try self.block.transactWithPrelude(
                        tx,
                        TransactionRuntime.Prelude.init(&prelude),
                    ),
                    .observed => try self.block.observe(observer).transactWithPrelude(
                        tx,
                        TransactionRuntime.Prelude.init(&prelude),
                    ),
                    .captured => |context| try self.block.capture(context, observer).transactWithPrelude(
                        tx,
                        TransactionRuntime.Prelude.init(&prelude),
                    ),
                };
                switch (outcome) {
                    .rejected => {},
                    .included => |included| self.retained_for_after_hook = .{
                        .index = progress_value.tx_count,
                        .status = included.result.status,
                        .gas_used = included.result.gas.used,
                    },
                }
                return outcome;
            }

            pub fn endTransactions(self: *@This()) !void {
                self.requireActive();
                if (self.phase == .finalized) return error.BlockAlreadyFinalized;
                try self.flushAfterTransaction();
                self.phase = .post_transactions;
            }

            pub fn afterTransaction(self: *@This()) !void {
                self.requireActive();
                if (self.retained_for_after_hook == null) return error.NoPendingTransaction;
                try self.flushAfterTransaction();
            }

            fn flushAfterTransaction(self: *@This()) !void {
                const retained = self.retained_for_after_hook orelse return;
                const progress_value = self.block.progress();
                try executor_module.system_contracts.applyAfterTransaction(
                    block_program_module.executorFor(&self.block),
                    self.lifecycleExecutionContext(),
                    .{
                        .number = self.block.environment.number,
                        .timestamp = self.block.environment.timestamp,
                        .transaction_index = retained.index,
                        .status = retained.status,
                        .gas_used = retained.gas_used,
                        .cumulative_gas_used = progress_value.gas_used,
                        .cumulative_block_gas = progress_value.block_gas.total,
                        .cumulative_state_gas = progress_value.block_gas.state,
                    },
                );
                self.retained_for_after_hook = null;
            }

            pub fn finalizeBlock(self: *@This(), allocator: std.mem.Allocator) ![]const []const u8 {
                self.requireActive();
                if (self.phase == .finalized) return error.BlockAlreadyFinalized;
                try self.flushAfterTransaction();
                self.phase = .post_transactions;
                const progress_value = self.block.progress();
                const outputs = try executor_module.system_contracts.applyFinalizeBlock(
                    block_program_module.executorFor(&self.block),
                    self.lifecycleExecutionContext(),
                    allocator,
                    .{
                        .number = self.block.environment.number,
                        .timestamp = self.block.environment.timestamp,
                        .transaction_count = progress_value.tx_count,
                        .gas_used = progress_value.gas_used,
                        .block_gas = progress_value.block_gas.total,
                        .state_gas = progress_value.block_gas.state,
                    },
                );
                self.phase = .finalized;
                return outputs;
            }

            /// Execute non-transaction block work and account its regular gas.
            pub fn systemCall(self: *@This(), call: SystemCall) !EvmResult {
                return self.systemCallMode(call, .normal, {});
            }

            fn systemCallMode(
                self: *@This(),
                call: SystemCall,
                mode: InstrumentationMode,
                observer: anytype,
            ) !EvmResult {
                self.requireActive();
                if (self.phase == .finalized) return error.BlockAlreadyFinalized;
                try self.flushAfterTransaction();
                const executor = block_program_module.executorFor(&self.block);
                const state = &self.block.state;
                var pre_call = try executor.branchCheckpoint();
                defer pre_call.deinit();

                const result = executeSystemCallWithExecutor(
                    executor,
                    self.block.environment,
                    call,
                    mode,
                    observer,
                ) catch |err| {
                    executor.restoreBranch(&pre_call);
                    return err;
                };
                const spent = systemCallGasUsed(call.gas, result.gasLeft());
                const next_block_gas = state.block_gas.add(transaction.BlockGas.legacy(spent)) catch {
                    executor.restoreBranch(&pre_call);
                    return error.GasAllowanceExceeded;
                };
                const next_gas_used = std.math.add(u64, state.gas_used, spent) catch {
                    executor.restoreBranch(&pre_call);
                    return error.GasAllowanceExceeded;
                };
                if (!next_block_gas.withinLimit(self.block.environment.gas_limit)) {
                    executor.restoreBranch(&pre_call);
                    return error.GasAllowanceExceeded;
                }

                state.gas_used = next_gas_used;
                state.block_gas = next_block_gas;
                return result;
            }

            pub fn finish(self: *@This()) !BlockResult {
                self.requireActive();
                try self.flushAfterTransaction();
                return self.block.finish();
            }

            pub fn discardIfUnfinished(self: *@This()) void {
                self.retained_for_after_hook = null;
                self.block.discardIfUnfinished();
            }

            fn requireActive(self: *const @This()) void {
                block_program_module.requireActive(&self.block);
            }

            fn lifecycleExecutionContext(self: *const @This()) execution.ExecutionContext {
                return self.block.environment.executionContext(.{ .origin = addr(0) });
            }
        };

        fn executeSystemCallWithExecutor(
            executor: *Executor,
            env: Env,
            call: SystemCall,
            mode: InstrumentationMode,
            observer: anytype,
        ) !EvmResult {
            if (env.gas_limit != 0 and call.gas > env.gas_limit) return error.GasAllowanceExceeded;
            const result = switch (mode) {
                .normal => try executor.executeSystemCall(
                    env.executionContext(.{ .origin = call.sender }),
                    call.sender,
                    call.recipient,
                    call.input,
                    .legacy(call.gas),
                ),
                .observed => try executor.observe(observer).executeSystemCall(
                    env.executionContext(.{ .origin = call.sender }),
                    call.sender,
                    call.recipient,
                    call.input,
                    .legacy(call.gas),
                ),
                .captured => |context| try executor.capture(context).executeSystemCall(
                    env.executionContext(.{ .origin = call.sender }),
                    call.sender,
                    call.recipient,
                    call.input,
                    .legacy(call.gas),
                    observer,
                ),
            };
            return Host.Result.fromCall(.{
                .outcome = result.outcome,
                .frame_halt = result.frame_halt,
                .output_data = result.output_data,
                .gas_left = result.gas_left,
                .gas_refund = result.gas_refund,
            });
        }

        fn systemCallGasUsed(gas: u64, gas_left: i64) u64 {
            if (gas_left <= 0) return gas;
            const left: u64 = @intCast(gas_left);
            return gas -| @min(gas, left);
        }
    };
}
