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
const ethereum_transition = @import("./transaction/transition.zig");
const transaction_validation = @import("./transaction/validation.zig");
const executor_module = @import("./executor.zig");
const executor_context = @import("./executor/context.zig");
const execution = @import("./execution.zig");
const Host = @import("./Host.zig");
const interpreter_module = @import("./Interpreter.zig");
const instruction_module = @import("./instruction.zig");
const opcode_info = @import("./opcode.zig");
const state_module = @import("./state.zig");
const transaction = @import("./transaction.zig");
const transaction_program = @import("./transaction/program.zig");

const Address = address.Address;
const addr = address.addr;

pub const StateReader = executor_module.state_io.StateReader;
pub const BlockHashSource = block_hash_source;
pub const Committer = executor_module.state_io.Committer;
pub const Log = Host.Log;

/// Block/environment values supplied by the caller.
pub const Env = struct {
    chain_id: u256 = 1,
    coinbase: Address = std.mem.zeroes(Address),
    number: u64 = 0,
    slot_number: u64 = 0,
    timestamp: u64 = 0,
    gas_limit: u64 = 0,
    prev_randao: u256 = 0,
    base_fee: u256 = 0,
    blob_base_fee: u256 = 0,
    /// Optional dynamic chain/fixture override for blob gas rules.
    /// When null, transaction validation and settlement use the exact spec schedule.
    // TODO: consider removing it in favor of policy
    blob_schedule: ?transaction.BlobSchedule = null,

    pub fn txContext(
        self: Env,
        origin: Address,
        gas_price: u256,
        gas_limit: u64,
        blob_hashes: []const u256,
    ) Host.TxContext {
        return .{
            .chain_id = self.chain_id,
            .gas_price = gas_price,
            .origin = origin,
            .coinbase = self.coinbase,
            .number = self.number,
            .slot_number = self.slot_number,
            .timestamp = self.timestamp,
            .gas_limit = gas_limit,
            .prev_randao = self.prev_randao,
            .base_fee = self.base_fee,
            .blob_base_fee = self.blob_base_fee,
            .blob_hashes = blob_hashes,
        };
    }

    /// Project environment values into one concrete engine request context.
    pub fn executionContext(
        self: Env,
        origin: Address,
        gas_price: u256,
        blob_hashes: []const u256,
    ) execution.ExecutionContext {
        return executor_context.fromHost(self.txContext(origin, gas_price, self.gas_limit, blob_hashes));
    }
};

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
    logs: state_module.TrackedState.LogView = .empty,
};

/// Borrowed facts for a transaction already included by a block program.
/// Output and logs remain valid until the next mutation of the same Executor.
const IncludedTransactionViewType = struct {
    result: TxExecutionResult,
    receipt: TxReceiptView,
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
    const InstructionType = instruction_module.Instruction(spec);
    const ExecutorType = executor_module.Executor(spec);
    const InterpreterType = interpreter_module.Interpreter(spec);
    const PublicTransactInput = struct {
        env: Env,
        tx: transaction.Transaction,
        progress: transaction.PreparationBlockProgress = .{},
    };
    const PublicContext = transaction_program.Context(ExecutorType, PublicTransactInput);
    const EthereumTransition = ethereum_transition.bind(
        spec,
        PublicContext,
        TxExecutionResult,
    );
    const TransactionRuntime = transaction_program.bind(
        ExecutorType,
        transaction.Transaction,
        PublicTransactInput,
        TxExecutionResult,
        transaction_validation.ValidationError,
        EthereumTransition,
    );
    const EthereumBlock = ethereum_block_program.bind(
        TransactionRuntime,
        Env,
        IncludedTransactionViewType,
        BlockResult,
    );
    const BlockExecutionType = block_program_module.bind(
        TransactionRuntime,
        ExecutorType,
        transaction.Transaction,
        PublicTransactInput,
        TxExecutionResult,
        transaction_validation.ValidationError,
        Env,
        IncludedTransactionViewType,
        BlockResult,
        EthereumBlock.Implementation,
    );

    return struct {
        const Self = @This();
        const IgnorePending = struct {
            pub fn observe(_: @This(), _: ExecutorType.State.PendingView) !void {}
        };

        pub const specification = spec;
        pub const Instruction = InstructionType;
        pub const Executor = ExecutorType;
        pub const Interpreter = InterpreterType;
        pub const Transaction = transaction.Transaction;
        pub const TransactionLog = Log;
        pub const TransactionLogs = TransactionRuntime.TransactionLogs;
        pub const TransactInput = PublicTransactInput;
        pub const Output = TxExecutionResult;
        pub const TxStatus = execution.Status;
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

        pub fn init(executor: *Executor) Self {
            return .{ .transaction_runtime = TransactionRuntime.init(executor) };
        }

        pub fn executorPtr(self: *const Self) *Executor {
            return self.transaction_runtime.executorPtr();
        }

        pub fn transact(self: *Self, input: TransactInput) Error!Outcome {
            return self.transaction_runtime.transact(input);
        }

        pub fn transactObserved(self: *Self, input: TransactInput) Error!Outcome {
            return self.transaction_runtime.transactObserved(input);
        }

        pub fn transactCaptured(
            self: *Self,
            input: TransactInput,
            capture: *executor_module.CaptureContext,
        ) Error!Outcome {
            return self.transaction_runtime.transactCaptured(input, capture);
        }

        pub fn transactInBlock(
            self: *Self,
            input: TransactInput,
            claim: Executor.BlockExecutionClaim,
        ) Error!Outcome {
            return self.transaction_runtime.transactInBlock(input, claim);
        }

        pub fn transactObservedInBlock(
            self: *Self,
            input: TransactInput,
            claim: Executor.BlockExecutionClaim,
        ) Error!Outcome {
            return self.transaction_runtime.transactObservedInBlock(input, claim);
        }

        pub fn transactInBlockWithPrelude(
            self: *Self,
            input: TransactInput,
            claim: Executor.BlockExecutionClaim,
            prelude: Prelude,
        ) Error!Outcome {
            return self.transaction_runtime.transactInBlockWithPrelude(input, claim, prelude);
        }

        pub fn transactObservedInBlockWithPrelude(
            self: *Self,
            input: TransactInput,
            claim: Executor.BlockExecutionClaim,
            prelude: Prelude,
        ) Error!Outcome {
            return self.transaction_runtime.transactObservedInBlockWithPrelude(input, claim, prelude);
        }

        pub fn transactCapturedInBlockWithPrelude(
            self: *Self,
            input: TransactInput,
            claim: Executor.BlockExecutionClaim,
            prelude: Prelude,
            capture: *executor_module.CaptureContext,
        ) Error!Outcome {
            return self.transaction_runtime.transactCapturedInBlockWithPrelude(
                input,
                claim,
                prelude,
                capture,
            );
        }

        pub fn Context(comptime Input: type) type {
            return transaction_program.Context(ExecutorType, Input);
        }

        pub fn Transition(comptime Input: type) type {
            return ethereum_transition.bind(
                spec,
                Context(Input),
                TxExecutionResult,
            );
        }

        pub fn Program(
            comptime TransactionType: type,
            comptime InputType: type,
            comptime OutputType: type,
            comptime RejectionType: type,
            comptime ImplementationType: type,
        ) type {
            return transaction_program.bind(
                ExecutorType,
                TransactionType,
                InputType,
                OutputType,
                RejectionType,
                ImplementationType,
            );
        }

        /// One-worker Ethereum block lifecycle over the exact VM.
        pub const Sequential = struct {
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

            pub fn init(executor: *Executor, options: InitOptions) !@This() {
                return .{ .block = try BlockExecution.init(executor, options.env) };
            }

            /// Return included block progress.
            pub fn progress(self: *const @This()) !BlockResult {
                try self.requireActive();
                return self.block.progress();
            }

            pub fn beforeBlock(self: *@This(), input: BeforeBlockInput) !void {
                try self.requireActive();
                if (self.phase != .transactions) return error.TransactionPhaseClosed;
                if (self.block.executorPtr().hasCurrentTransaction()) return error.ExecutedTransactionActive;
                try executor_module.system_contracts.applyBeforeBlock(
                    self.block.executorPtr(),
                    self.lifecycleTxContext(),
                    .{
                        .number = self.block.environment.number,
                        .timestamp = self.block.environment.timestamp,
                        .parent_hash = input.parent_hash,
                        .parent_beacon_block_root = input.parent_beacon_block_root,
                    },
                );
            }

            pub fn transact(self: *@This(), tx: Transaction) !BlockExecution.Outcome {
                return self.transactMode(tx, .normal, IgnorePending{});
            }

            pub fn transactObserved(
                self: *@This(),
                tx: Transaction,
                observer: anytype,
            ) !BlockExecution.Outcome {
                return self.transactMode(tx, .observed, observer);
            }

            pub fn transactCaptured(
                self: *@This(),
                tx: Transaction,
                capture: *executor_module.CaptureContext,
                observer: anytype,
            ) !BlockExecution.Outcome {
                return self.transactMode(tx, .{ .captured = capture }, observer);
            }

            const TransactionMode = union(enum) {
                normal,
                observed,
                captured: *executor_module.CaptureContext,
            };

            fn transactMode(
                self: *@This(),
                tx: Transaction,
                mode: TransactionMode,
                observer: anytype,
            ) !BlockExecution.Outcome {
                try self.requireActive();
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
                    .observed => try self.block.transactWithPreludeObserved(
                        tx,
                        TransactionRuntime.Prelude.init(&prelude),
                        observer,
                    ),
                    .captured => |capture| try self.block.transactWithPreludeCaptured(
                        tx,
                        TransactionRuntime.Prelude.init(&prelude),
                        capture,
                        observer,
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
                try self.requireActive();
                if (self.phase == .finalized) return error.BlockAlreadyFinalized;
                try self.flushAfterTransaction();
                self.phase = .post_transactions;
            }

            pub fn afterTransaction(self: *@This()) !void {
                try self.requireActive();
                if (self.retained_for_after_hook == null) return error.NoPendingTransaction;
                try self.flushAfterTransaction();
            }

            fn flushAfterTransaction(self: *@This()) !void {
                const retained = self.retained_for_after_hook orelse return;
                const progress_value = self.block.progress();
                try executor_module.system_contracts.applyAfterTransaction(
                    self.block.executorPtr(),
                    self.lifecycleTxContext(),
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
                try self.requireActive();
                if (self.phase == .finalized) return error.BlockAlreadyFinalized;
                try self.flushAfterTransaction();
                self.phase = .post_transactions;
                const progress_value = self.block.progress();
                const outputs = try executor_module.system_contracts.applyFinalizeBlock(
                    self.block.executorPtr(),
                    self.lifecycleTxContext(),
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
                return self.systemCallObserved(call, IgnorePending{});
            }

            pub fn systemCallObserved(
                self: *@This(),
                call: SystemCall,
                observer: anytype,
            ) !EvmResult {
                try self.requireActive();
                if (self.phase == .finalized) return error.BlockAlreadyFinalized;
                try self.flushAfterTransaction();
                const executor = self.block.executorPtr();
                const state = &self.block.state;
                var pre_call = try executor.branchCheckpoint();
                defer pre_call.deinit();

                const result = executeSystemCallWithExecutorObserved(
                    executor,
                    self.block.environment,
                    call,
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
                try self.requireActive();
                try self.flushAfterTransaction();
                return self.block.finish();
            }

            pub fn discardIfUnfinished(self: *@This()) void {
                self.requireActive() catch return;
                std.debug.assert(!self.block.executorPtr().hasCurrentTransaction());
                self.retained_for_after_hook = null;
                self.block.discardIfUnfinished();
            }

            fn requireActive(self: *const @This()) !void {
                if (self.block.finished) return error.BlockExecutionFinished;
                try self.block.claim.requireFor(self.block.executorPtr());
            }

            fn lifecycleTxContext(self: *const @This()) Host.TxContext {
                return self.block.environment.txContext(addr(0), 0, self.block.environment.gas_limit, &.{});
            }
        };

        fn executeSystemCallWithExecutorObserved(
            executor: *Executor,
            env: Env,
            call: SystemCall,
            observer: anytype,
        ) !EvmResult {
            if (env.gas_limit != 0 and call.gas > env.gas_limit) return error.GasAllowanceExceeded;
            const context_gas_limit = if (env.gas_limit == 0) call.gas else env.gas_limit;
            const result = try executor.executeSystemCallObserved(
                env.txContext(call.sender, 0, context_gas_limit, &.{}),
                call.sender,
                call.recipient,
                call.input,
                .legacy(call.gas),
                observer,
            );
            return Host.Result.fromCall(.{
                .status = result.status,
                .cause = result.cause,
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
