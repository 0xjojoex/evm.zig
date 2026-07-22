//! Private Ethereum-family compiler.
//!
//! `compile(...)` consumes one complete Ethereum-owned rule set. Public callers
//! reach it through `eth.extend` or `eth.derive`.
//! Its runtime lifetimes are explicit: `Executor` owns one mutable execution
//! branch, `transact` owns one transaction attempt, and
//! `Program.Block(...)` owns sequential block progress over a caller-provided
//! Executor. `Sequential` is the family-hook convenience path.

const std = @import("std");

const address = @import("./address.zig");
const block_hash_source = @import("./BlockHashSource.zig");
const block_program_module = @import("./block_program.zig");
const definition_module = @import("./definition.zig");
const eth_config = @import("./eth/config.zig");
const eth_block_program = @import("./eth/block_program.zig");
const eth_transition = @import("./eth/transition.zig");
const executor_module = @import("./executor.zig");
const executor_context = @import("./executor/context.zig");
const execution = @import("./execution.zig");
const Host = @import("./Host.zig");
const interpreter_module = @import("./Interpreter.zig");
const opcode_info = @import("./opcode.zig");
const protocol_binding = @import("./protocol/binding.zig");
const protocol_dispatcher = @import("./protocol/dispatcher.zig");
const protocol_module = @import("./protocol.zig");
const transaction = @import("./transaction.zig");
const transaction_program = @import("./transaction/program.zig");
const gas_bound_plan = @import("./transaction/gas_bound_plan.zig");

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
    /// When null, transaction validation and settlement use the protocol schedule for the active revision.
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
pub const TxStatus = protocol_module.BlockTransactionStatus;

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
    logs: []const Log = &.{},
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
pub const AfterTransactionContext = protocol_module.AfterTransactionContext;
pub const FinalizeBlockContext = protocol_module.FinalizeBlockContext;

/// Gas-derived allocation envelope for `initBoundExecutor`.
///
/// This is an implementation capacity, not the consensus block environment;
/// each `BlockExecution.init` still receives the actual `Env.gas_limit`.
pub const BlockBound = struct {
    max_block_gas: u64,
    max_live_frames: usize = executor_module.default_max_live_frames,
};
const BlockBoundType = BlockBound;

/// Compile a concrete Ethereum-family type from one complete resolved input.
///
/// `R` is explicit because ZLS cannot reliably recover the revision type
/// through comptime values. Layer ownership remains separate inside `resolved`.
pub fn compile(
    comptime R: type,
    comptime resolved: eth_config.Resolved(R),
    comptime support_window: definition_module.ExecutionModel(resolved.execution).Support,
    comptime dispatch: protocol_dispatcher.DispatchConfig,
) type {
    const ExecutionP = protocol_binding.compileExecutionWithDispatch(
        resolved.execution,
        support_window,
        dispatch,
    );
    const TransactionP = protocol_binding.compileTransaction(ExecutionP, resolved.transaction);
    const transaction_policy = definition_module.projectTransactionPolicy(R, resolved.transaction);
    const block_policy = definition_module.projectBlockPolicy(R, resolved.block);
    return EthereumFamily(
        R,
        ExecutionP.BaseRevision,
        ExecutionP,
        TransactionP,
        ExecutionP.Support,
        TransactionP.Tx.ValidationError,
        executor_module.Executor(ExecutionP),
        interpreter_module.For(ExecutionP),
        transaction_policy,
        block_policy,
    );
}

/// Public custom-program carrier closed over one Ethereum family.
/// Keep the exposed semantic types as flat parameters: deriving them through
/// `TransactionRuntimeType` makes ZLS 0.16 lose nested fields and union tags.
fn FamilyProgram(
    comptime TransactionRuntimeType: type,
    comptime RevisionType: type,
    comptime ExecutorType: type,
    comptime TransactionProtocolType: type,
    comptime TransactionPolicyType: type,
    comptime default_transaction_policy: TransactionPolicyType,
    comptime ContextType: type,
    comptime TransactionType: type,
    comptime InputType: type,
    comptime OutputType: type,
    comptime RejectionType: type,
    comptime ExecutedType: type,
    comptime PreludeType: type,
    comptime PreludeContextType: type,
    comptime OutcomeType: type,
    comptime ErrorType: type,
    comptime BlockPolicyType: type,
    comptime default_block_policy: BlockPolicyType,
) type {
    comptime {
        std.debug.assert(TransactionRuntimeType.Revision == RevisionType);
        std.debug.assert(TransactionRuntimeType.Executor == ExecutorType);
        std.debug.assert(TransactionRuntimeType.TransactionProtocol == TransactionProtocolType);
        std.debug.assert(TransactionRuntimeType.TransactionPolicy == TransactionPolicyType);
        std.debug.assert(TransactionRuntimeType.Context == ContextType);
        std.debug.assert(TransactionRuntimeType.Transaction == TransactionType);
        std.debug.assert(TransactionRuntimeType.TransactInput == InputType);
        std.debug.assert(TransactionRuntimeType.Output == OutputType);
        std.debug.assert(TransactionRuntimeType.TransactionLog == Log);
        std.debug.assert(TransactionRuntimeType.Rejection == RejectionType);
        std.debug.assert(TransactionRuntimeType.Executed == ExecutedType);
        std.debug.assert(TransactionRuntimeType.Prelude == PreludeType);
        std.debug.assert(TransactionRuntimeType.PreludeContext == PreludeContextType);
        std.debug.assert(TransactionRuntimeType.Outcome == OutcomeType);
        std.debug.assert(TransactionRuntimeType.Error == ErrorType);
    }

    return struct {
        const Self = @This();

        pub const TransactionRuntime = TransactionRuntimeType;
        pub const Revision = RevisionType;
        pub const Executor = ExecutorType;
        pub const TransactionProtocol = TransactionProtocolType;
        pub const TransactionPolicy = TransactionPolicyType;
        pub const transaction_policy = default_transaction_policy;
        pub const BlockPolicy = BlockPolicyType;
        pub const block_policy = default_block_policy;
        pub const Context = ContextType;
        pub const Transaction = TransactionType;
        pub const TransactInput = InputType;
        pub const Output = OutputType;
        pub const TransactionLog = Log;
        pub const Rejection = RejectionType;
        pub const Executed = ExecutedType;
        pub const Prelude = PreludeType;
        pub const PreludeContext = PreludeContextType;
        pub const Outcome = OutcomeType;
        pub const Error = ErrorType;

        transaction_runtime: TransactionRuntimeType,

        pub fn init(executor: *Executor) Self {
            return initWithPolicy(executor, default_transaction_policy);
        }

        pub fn initWithPolicy(executor: *Executor, policy: TransactionPolicy) Self {
            return .{ .transaction_runtime = TransactionRuntimeType.initWithPolicy(executor, policy) };
        }

        pub fn executorPtr(self: *const Self) *Executor {
            return self.transaction_runtime.executorPtr();
        }

        pub fn withPreludeError(comptime PreludeError: type) type {
            if (PreludeError == error{}) return Self;
            const WidenedRuntime = TransactionRuntimeType.withPreludeError(PreludeError);
            return FamilyProgram(
                WidenedRuntime,
                RevisionType,
                ExecutorType,
                TransactionProtocolType,
                TransactionPolicyType,
                default_transaction_policy,
                ContextType,
                TransactionType,
                InputType,
                OutputType,
                RejectionType,
                WidenedRuntime.Executed,
                WidenedRuntime.Prelude,
                WidenedRuntime.PreludeContext,
                WidenedRuntime.Outcome,
                WidenedRuntime.Error,
                BlockPolicyType,
                default_block_policy,
            );
        }

        pub fn rebindPreludeError(
            self: Self,
            comptime PreludeError: type,
        ) withPreludeError(PreludeError) {
            return .{
                .transaction_runtime = self.transaction_runtime.rebindPreludeError(PreludeError),
            };
        }

        pub fn transact(self: *Self, input: TransactInput) Error!Outcome {
            return self.transaction_runtime.transact(input);
        }

        pub fn transactInBlock(
            self: *Self,
            input: TransactInput,
            claim: Executor.BlockExecutionClaim,
        ) Error!Outcome {
            return self.transaction_runtime.transactInBlock(input, claim);
        }

        pub fn transactInBlockWithPrelude(
            self: *Self,
            input: TransactInput,
            claim: Executor.BlockExecutionClaim,
            prelude: Prelude,
        ) Error!Outcome {
            return self.transaction_runtime.transactInBlockWithPrelude(input, claim, prelude);
        }

        /// Bind one block fold above this exact transaction program while the
        /// parent VM supplies the coherent block policy and default snapshot.
        pub fn Block(
            comptime EnvironmentType: type,
            comptime IncludedType: type,
            comptime ResultType: type,
            comptime ImplementationType: type,
        ) type {
            return block_program_module.bind(
                Self,
                ExecutorType,
                BlockPolicyType,
                default_block_policy,
                TransactionType,
                InputType,
                OutputType,
                RejectionType,
                EnvironmentType,
                IncludedType,
                ResultType,
                ImplementationType,
            );
        }
    };
}

/// Internal ZLS carrier. Keep family-rule-dependent public types flat: wrapping
/// them in a descriptor type makes ZLS lose their fields and enum tags.
fn EthereumFamily(
    comptime RevisionType: type,
    comptime BaseRevisionType: type,
    comptime ExecutionProtocolType: type,
    comptime TransactionProtocolType: type,
    comptime SupportType: type,
    comptime ValidationErrorType: type,
    comptime ExecutorType: type,
    comptime InterpreterType: type,
    comptime default_transaction_policy: definition_module.TransactionPolicy(RevisionType),
    comptime default_block_policy: definition_module.BlockPolicy(RevisionType),
) type {
    comptime {
        std.debug.assert(ExecutionProtocolType.Revision == RevisionType);
        std.debug.assert(ExecutionProtocolType.BaseRevision == BaseRevisionType);
        std.debug.assert(ExecutionProtocolType.Support == SupportType);
        std.debug.assert(TransactionProtocolType.ExecutionProtocol == ExecutionProtocolType);
        std.debug.assert(TransactionProtocolType.Tx.Value == transaction.Transaction);
        std.debug.assert(TransactionProtocolType.Tx.View == transaction.TransactionView);
        std.debug.assert(TransactionProtocolType.Tx.ValidationError == ValidationErrorType);
        std.debug.assert(executor_module.Executor(ExecutionProtocolType) == ExecutorType);
        std.debug.assert(interpreter_module.For(ExecutionProtocolType) == InterpreterType);
    }

    const ProtocolInstruction = ExecutionProtocolType.Instruction;
    const GasBoundPlanner = gas_bound_plan.For(TransactionProtocolType);
    const TxStatusType = TxStatus;
    const TransactionPolicyType = definition_module.TransactionPolicy(RevisionType);
    const BlockPolicyType = definition_module.BlockPolicy(RevisionType);
    const PublicTransactInput = struct {
        env: Env,
        tx: transaction.Transaction,
        progress: transaction.PreparationBlockProgress = .{},
    };
    const PublicTransactionContext = transaction_program.Context(
        RevisionType,
        ExecutorType,
        TransactionProtocolType,
        TransactionPolicyType,
        PublicTransactInput,
    );
    const EthereumTransactionImplementation = eth_transition.Implementation(
        TransactionProtocolType,
        TxExecutionResult,
    ).For(PublicTransactionContext);
    const BoundTransactionProgram = transaction_program.bind(
        RevisionType,
        ExecutorType,
        TransactionProtocolType,
        TransactionPolicyType,
        default_transaction_policy,
        transaction.Transaction,
        PublicTransactInput,
        TxExecutionResult,
        ValidationErrorType,
        EthereumTransactionImplementation,
    );
    const EthereumBlock = eth_block_program.For(
        BlockPolicyType,
        BoundTransactionProgram,
        Env,
        IncludedTransactionViewType,
        BlockResult,
    );
    const BeforeTransactionPrelude = EthereumBlock.Prelude;
    const EthereumBlockImplementation = EthereumBlock.Implementation;

    return struct {
        const Self = @This();
        pub const ExecutionProtocol = ExecutionProtocolType;
        pub const TransactionProtocol = TransactionProtocolType;
        pub const TransactionPolicy = TransactionPolicyType;
        pub const BlockPolicy = BlockPolicyType;
        pub const transaction_policy = default_transaction_policy;
        pub const block_policy = default_block_policy;
        pub const Support = SupportType;
        pub const Revision = RevisionType;
        pub const BaseRevision = BaseRevisionType;
        pub const Instruction = ProtocolInstruction;
        pub const Transaction = transaction.Transaction;
        pub const Output = TxExecutionResult;
        pub const Rejection = ValidationErrorType;
        pub const TransactionLog = Log;
        pub const TxStatus = TxStatusType;
        pub const Executor = ExecutorType;
        pub const Interpreter = InterpreterType;
        pub const TransactionRuntime = BoundTransactionProgram;
        pub const Prelude = BoundTransactionProgram.Prelude;
        pub const PreludeContext = BoundTransactionProgram.PreludeContext;
        /// Operational failures from the transaction program. Protocol
        /// rejection remains the `.rejected` outcome, not an error.
        pub const Error = BoundTransactionProgram.Error;

        transaction_runtime: BoundTransactionProgram,

        /// Bind one caller-owned Executor to an immutable transaction-policy
        /// snapshot. The resulting value owns transaction lifetime; Executor
        /// remains the reusable mutable execution branch below it.
        pub fn init(executor: *Executor) Self {
            return initWithPolicy(executor, default_transaction_policy);
        }

        pub fn initWithPolicy(
            executor: *Executor,
            policy: TransactionPolicyType,
        ) Self {
            return .{
                .transaction_runtime = BoundTransactionProgram.initWithPolicy(executor, policy),
            };
        }

        pub fn executorPtr(self: *const Self) *Executor {
            return self.transaction_runtime.executorPtr();
        }

        pub fn withPreludeError(comptime PreludeError: type) type {
            if (PreludeError == error{}) return Self;
            const WidenedRuntime = BoundTransactionProgram.withPreludeError(PreludeError);
            return FamilyProgram(
                WidenedRuntime,
                RevisionType,
                ExecutorType,
                TransactionProtocolType,
                TransactionPolicyType,
                default_transaction_policy,
                PublicTransactionContext,
                transaction.Transaction,
                PublicTransactInput,
                TxExecutionResult,
                ValidationErrorType,
                WidenedRuntime.Executed,
                WidenedRuntime.Prelude,
                WidenedRuntime.PreludeContext,
                WidenedRuntime.Outcome,
                WidenedRuntime.Error,
                BlockPolicyType,
                default_block_policy,
            );
        }

        pub fn rebindPreludeError(
            self: Self,
            comptime PreludeError: type,
        ) withPreludeError(PreludeError) {
            return .{
                .transaction_runtime = self.transaction_runtime.rebindPreludeError(PreludeError),
            };
        }

        /// Checked transaction lease and semantic outcome come directly from
        /// the bound transaction program. Receipts begin at block inclusion.
        pub const Executed = BoundTransactionProgram.Executed;
        pub const Outcome = BoundTransactionProgram.Outcome;

        /// Explicit one-transaction STF input. The Executor owns mutable state
        /// and attempt lifetime; block/environment facts are invocation input.
        pub const TransactInput = PublicTransactInput;

        const RetainedTransaction = struct {
            index: u64,
            status: TxStatusType,
            gas_used: u64,
        };

        pub fn baseRevision(revision: Revision) BaseRevision {
            return ExecutionProtocolType.baseRevision(revision);
        }

        pub const BlockBound = BlockBoundType;

        /// Ethereum's prewired block fold. It owns an exclusive,
        /// generation-checked claim over one stable Executor.
        pub const BlockExecution = block_program_module.bind(
            Self,
            ExecutorType,
            BlockPolicyType,
            default_block_policy,
            transaction.Transaction,
            PublicTransactInput,
            TxExecutionResult,
            ValidationErrorType,
            Env,
            IncludedTransactionViewType,
            BlockResult,
            EthereumBlockImplementation,
        );

        /// One-worker lifecycle wrapper over `BlockExecution` with
        /// block-rule-owned system hooks. The embedded block owns the fold;
        /// this wrapper only interleaves before/after/finalize hooks.
        pub const Sequential = struct {
            const Phase = enum {
                transactions,
                post_transactions,
                finalized,
            };

            pub const InitOptions = struct {
                env: Env,
            };

            block: BlockExecution,
            phase: Phase = .transactions,
            retained_for_after_hook: ?RetainedTransaction = null,

            /// Establish a block lifetime over a caller-stable Executor.
            /// The caller grants exclusive use of that state domain until
            /// `finish` or `discardIfUnfinished`.
            pub fn init(
                executor: *Executor,
                options_value: InitOptions,
            ) !Sequential {
                return Sequential.initWithRuntime(
                    Self.init(executor),
                    options_value,
                );
            }

            /// Advanced composition seam for a preconfigured transaction runtime.
            pub fn initWithRuntime(
                transaction_runtime: Self,
                options_value: InitOptions,
            ) !Sequential {
                const executor = transaction_runtime.executorPtr();
                try validateBoundedEnvironment(executor, options_value.env);
                return .{
                    .block = try BlockExecution.initWithRuntime(
                        transaction_runtime,
                        options_value.env,
                    ),
                };
            }

            pub fn initWithPolicies(
                executor: *Executor,
                transaction_policy_value: TransactionPolicyType,
                block_policy_value: BlockPolicyType,
                options_value: InitOptions,
            ) !Sequential {
                try validateBoundedEnvironment(executor, options_value.env);
                return .{
                    .block = try BlockExecution.initWithPolicies(
                        executor,
                        transaction_policy_value,
                        block_policy_value,
                        options_value.env,
                    ),
                };
            }

            /// Return included block progress.
            pub fn progress(self: *const Sequential) !BlockResult {
                try self.requireActive();
                return self.block.progress();
            }

            /// Run family block work before payload execution begins.
            /// Family-owned actions can be applied before or after this call.
            pub fn beforeBlock(self: *Sequential, input: BeforeBlockInput) !void {
                try self.requireActive();
                if (self.phase != .transactions) return error.TransactionPhaseClosed;
                if (self.block.executorPtr().hasCurrentTransaction()) return error.ExecutedTransactionActive;
                try executor_module.system_contracts.applyBeforeBlock(
                    self.block.policy(),
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

            /// Execute and include one protocol transaction atomically.
            pub fn transact(self: *Sequential, tx: Self.Transaction) !BlockExecution.Outcome {
                try self.requireActive();
                if (self.phase != .transactions) return error.TransactionPhaseClosed;
                try self.flushAfterTransaction();
                const progress_value = self.block.progress();
                var prelude = BeforeTransactionPrelude{
                    .block_policy = self.block.policy(),
                    .env = self.block.environment,
                    .transaction_index = progress_value.tx_count,
                };
                const outcome = try self.block.transactWithPrelude(
                    tx,
                    Prelude.init(&prelude),
                );
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

            /// End the transaction phase without ending the block execution.
            /// Block STFs use this before family-owned post-transaction writes.
            pub fn endTransactions(self: *Sequential) !void {
                try self.requireActive();
                if (self.phase == .finalized) return error.BlockAlreadyFinalized;
                try self.flushAfterTransaction();
                self.phase = .post_transactions;
            }

            /// Run the current transaction's family-owned after hook after the
            /// caller has consumed its borrowed logs.
            pub fn afterTransaction(self: *Sequential) !void {
                try self.requireActive();
                if (self.retained_for_after_hook == null) return error.NoPendingTransaction;
                try self.flushAfterTransaction();
            }

            fn flushAfterTransaction(self: *Sequential) !void {
                const retained = self.retained_for_after_hook orelse return;
                const progress_value = self.block.progress();
                try executor_module.system_contracts.applyAfterTransaction(
                    self.block.policy(),
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

            /// Run family finalization calls and return their owned,
            /// prefixed outputs. The family STF decides how those outputs are
            /// interpreted and combined with family-owned finality data.
            pub fn finalizeBlock(self: *Sequential, allocator: std.mem.Allocator) ![]const []const u8 {
                try self.requireActive();
                if (self.phase == .finalized) return error.BlockAlreadyFinalized;
                try self.flushAfterTransaction();
                self.phase = .post_transactions;
                const progress_value = self.block.progress();
                const outputs = try executor_module.system_contracts.applyFinalizeBlock(
                    self.block.policy(),
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

            pub fn systemCall(self: *Sequential, call: SystemCall) !EvmResult {
                try self.requireActive();
                if (self.phase == .finalized) return error.BlockAlreadyFinalized;
                try self.flushAfterTransaction();
                const executor = self.block.executorPtr();
                const state = &self.block.state;
                var pre_call = try executor.snapshot();
                defer pre_call.deinit(executor.allocator);
                try executor.traceSnapshotLifecycle(.checkpoint, &pre_call);
                var trace_checkpoint_open = true;
                errdefer if (trace_checkpoint_open) {
                    executor.traceSnapshotLifecycle(.revert, &pre_call) catch {};
                    executor.restore(&pre_call) catch {};
                };

                const result = try executeSystemCallWithExecutor(executor, self.block.environment, call);
                const spent = systemCallGasUsed(call.gas, result.gasLeft());
                const next_block_gas = state.block_gas.add(transaction.BlockGas.legacy(spent)) catch {
                    try executor.traceSnapshotLifecycle(.revert, &pre_call);
                    trace_checkpoint_open = false;
                    try executor.restore(&pre_call);
                    return error.GasAllowanceExceeded;
                };
                const next_gas_used = std.math.add(u64, state.gas_used, spent) catch {
                    try executor.traceSnapshotLifecycle(.revert, &pre_call);
                    trace_checkpoint_open = false;
                    try executor.restore(&pre_call);
                    return error.GasAllowanceExceeded;
                };
                if (!next_block_gas.withinLimit(self.block.environment.gas_limit)) {
                    try executor.traceSnapshotLifecycle(.revert, &pre_call);
                    trace_checkpoint_open = false;
                    try executor.restore(&pre_call);
                    return error.GasAllowanceExceeded;
                }

                try executor.traceSnapshotLifecycle(.commit, &pre_call);
                trace_checkpoint_open = false;
                state.gas_used = next_gas_used;
                state.block_gas = next_block_gas;
                return result;
            }

            /// Flush the final after-transaction phase and return block progress.
            /// Consume or copy the last receipt's borrowed logs before calling.
            pub fn finish(self: *Sequential) !BlockResult {
                try self.requireActive();
                try self.flushAfterTransaction();
                return self.block.finish();
            }

            /// Abort every overlay change made by this unfinished block lifetime.
            pub fn discardIfUnfinished(self: *Sequential) void {
                self.requireActive() catch return;
                std.debug.assert(!self.block.executorPtr().hasCurrentTransaction());
                self.retained_for_after_hook = null;
                self.block.discardIfUnfinished();
            }

            fn requireActive(self: *const Sequential) !void {
                if (self.block.finished) return error.BlockExecutionFinished;
                try self.block.claim.requireFor(self.block.executorPtr());
            }

            fn lifecycleTxContext(self: *const Sequential) Host.TxContext {
                return self.block.environment.txContext(addr(0), 0, self.block.environment.gas_limit, &.{});
            }
        };

        pub fn boundedRuntimeResources(revision: RevisionType, bound: BlockBoundType) !executor_module.BoundedRuntimeResources {
            if (bound.max_block_gas == 0) return error.InvalidBlockGasBound;
            const envelope = try GasBoundPlanner.resourceEnvelope(.{
                .revision = revision,
                .block_gas_limit = bound.max_block_gas,
                .max_live_frames = bound.max_live_frames,
            });
            var resources = executor_module.BoundedRuntimeResources.fromResourceEnvelope(envelope);
            resources.max_block_gas = bound.max_block_gas;
            return resources;
        }

        /// Initialize an Executor with gas-derived, revision-locked capacity.
        pub fn initBoundExecutor(
            allocator: std.mem.Allocator,
            options_value: Executor.Init,
            bound: BlockBoundType,
        ) !Executor {
            var executor = try Executor.initWithRuntimeResources(allocator, options_value, .{
                .bounded = try boundedRuntimeResources(options_value.revision, bound),
            });
            executor.lockRuntimeResources();
            return executor;
        }

        fn executeSystemCallWithExecutor(executor: *Executor, env: Env, call: SystemCall) !EvmResult {
            if (env.gas_limit != 0 and call.gas > env.gas_limit) return error.GasAllowanceExceeded;
            const context_gas_limit = if (env.gas_limit == 0) call.gas else env.gas_limit;
            const result = try executor.executeSystemCall(
                env.txContext(call.sender, 0, context_gas_limit, &.{}),
                call.sender,
                call.recipient,
                call.input,
                .legacy(call.gas),
            );
            return Host.Result.fromCall(.{
                .status = result.status,
                .output_data = result.output_data,
                .gas_left = result.gas_left,
                .gas_refund = result.gas_refund,
            });
        }

        /// Execute one protocol transaction over a caller-owned Executor.
        pub fn transact(self: *Self, input: TransactInput) Error!Outcome {
            return self.transaction_runtime.transact(input);
        }

        /// Transaction entry used only by a bound block program holding the
        /// Executor's active block claim.
        pub fn transactInBlock(
            self: *Self,
            input: TransactInput,
            claim: Executor.BlockExecutionClaim,
        ) Error!Outcome {
            return self.transaction_runtime.transactInBlock(input, claim);
        }

        /// Transaction entry for a bound block program that supplies a family
        /// prelude sharing the payload's retain/discard lifetime.
        pub fn transactInBlockWithPrelude(
            self: *Self,
            input: TransactInput,
            claim: Executor.BlockExecutionClaim,
            prelude: Prelude,
        ) Error!Outcome {
            return self.transaction_runtime.transactInBlockWithPrelude(
                input,
                claim,
                prelude,
            );
        }

        fn validateBoundedEnvironment(executor: *const Executor, env: Env) !void {
            const max_block_gas = executor.blockGasLimitBound() orelse return;
            if (env.gas_limit == 0) return error.InvalidBlockGasLimit;
            if (env.gas_limit > max_block_gas) return error.BlockGasLimitExceedsBound;
        }

        fn systemCallGasUsed(gas: u64, gas_left: i64) u64 {
            if (gas_left <= 0) return gas;
            const left: u64 = @intCast(gas_left);
            return gas -| @min(gas, left);
        }

        /// Construct a transaction context using this VM's flat lexical type
        /// carriers so editor tooling does not need to recover nested family
        /// declarations through another comptime type constructor.
        pub fn Context(comptime Input: type) type {
            return transaction_program.Context(
                RevisionType,
                ExecutorType,
                TransactionProtocolType,
                TransactionPolicyType,
                Input,
            );
        }

        /// Bind Ethereum's transaction transition from the original input type;
        /// callers never have to pass the generated context into another binder.
        pub fn Transition(comptime Input: type) type {
            return eth_transition.Implementation(
                TransactionProtocolType,
                TxExecutionResult,
            ).For(Context(Input));
        }

        /// Gas planner runtime bound to this VM's transaction protocol and the
        /// transaction sub-policy, built from the VM's flat carriers so callers
        /// never thread the protocol and policy field types by hand.
        pub const Gas = transaction.GasRuntime(
            TransactionProtocolType,
            @FieldType(TransactionPolicyType, "transaction"),
        );

        /// Settlement runtime bound to this VM's transaction protocol and full
        /// transaction policy.
        pub const Settlement = transaction.SettlementRuntime(
            TransactionProtocolType,
            TransactionPolicyType,
        );

        /// Construct and bind a transaction program from flat semantic types;
        /// no generated program carrier crosses this comptime boundary.
        pub fn Program(
            comptime TransactionType: type,
            comptime InputType: type,
            comptime OutputType: type,
            comptime RejectionType: type,
            comptime ImplementationType: type,
        ) type {
            const Runtime = transaction_program.bind(
                RevisionType,
                ExecutorType,
                TransactionProtocolType,
                TransactionPolicyType,
                default_transaction_policy,
                TransactionType,
                InputType,
                OutputType,
                RejectionType,
                ImplementationType,
            );
            return FamilyProgram(
                Runtime,
                RevisionType,
                ExecutorType,
                TransactionProtocolType,
                TransactionPolicyType,
                default_transaction_policy,
                Context(InputType),
                TransactionType,
                InputType,
                OutputType,
                RejectionType,
                Runtime.Executed,
                Runtime.Prelude,
                Runtime.PreludeContext,
                Runtime.Outcome,
                Runtime.Error,
                BlockPolicyType,
                default_block_policy,
            );
        }
    };
}

test "system call gas used handles signed gas-left boundaries" {
    const Default = @import("evm.zig").Evm;
    try std.testing.expectEqual(@as(u64, 100), Default.systemCallGasUsed(100, -1));
    try std.testing.expectEqual(@as(u64, 100), Default.systemCallGasUsed(100, 0));
    try std.testing.expectEqual(@as(u64, 60), Default.systemCallGasUsed(100, 40));
    try std.testing.expectEqual(@as(u64, 0), Default.systemCallGasUsed(100, 100));
    try std.testing.expectEqual(@as(u64, 0), Default.systemCallGasUsed(100, std.math.maxInt(i64)));
}
