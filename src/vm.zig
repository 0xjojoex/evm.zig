//! Compile-time execution-engine family.
//!
//! `Vm(...)` binds revision, protocol semantics, and instruction configuration.
//! Its runtime lifetimes are explicit: `Executor` owns one mutable execution
//! branch, `transact` owns one transaction attempt, and
//! `BlockProgram.bind(TransactionRuntime, BlockPolicy, default_policy)` owns
//! sequential block progress over a caller-provided Executor. `Sequential` is
//! the family-hook convenience path.

const std = @import("std");

const evmz = @import("evm.zig");
const address = @import("./address.zig");
const definition_module = @import("./definition.zig");
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
const gas_bound_plan = @import("./transaction/gas_bound_plan.zig");

const Address = address.Address;
const addr = address.addr;
const Changeset = evmz.state.Changeset;
const MemoryStore = evmz.state.MemoryStore;

pub const StateReader = executor_module.state_io.StateReader;
pub const BlockHashSource = evmz.BlockHashSource;
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
pub const Message = executor_module.Message;
pub const EvmResult = executor_module.EvmResult;
pub const RuntimeResources = executor_module.RuntimeResources;
pub const BoundedRuntimeResources = executor_module.BoundedRuntimeResources;

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

/// Public composition options specialized to one execution definition.
pub fn OptionsFor(comptime execution_definition: anytype) type {
    const Definition = definition_module.BoundExecution(execution_definition);
    return struct {
        support: Definition.Support = Definition.Support.all,
        dispatch: protocol_dispatcher.DispatchConfig = .{},
    };
}

/// Compose a concrete engine-family type.
///
/// `R` is explicit because ZLS cannot reliably recover the revision type
/// through comptime definition values. The engine takes each authored layer
/// directly; no public all-domain namespace is required.
pub fn Vm(
    comptime R: type,
    comptime execution_definition: definition_module.ExecutionDefinition(R),
    comptime transaction_definition: definition_module.TransactionDefinition(R),
    comptime block_definition: definition_module.BlockDefinition(R),
    comptime options: OptionsFor(execution_definition),
) type {
    const ExecutionP = protocol_binding.ExecutionProtocolWithDispatch(
        execution_definition,
        options.support,
        options.dispatch,
    );
    const TransactionP = protocol_module.TransactionProtocol(ExecutionP, transaction_definition);
    const BlockP = protocol_module.BlockProtocol(TransactionP, block_definition);
    const transaction_policy = definition_module.projectTransactionPolicy(R, transaction_definition);
    const block_policy = definition_module.projectBlockPolicy(R, block_definition);
    return Typed(
        R,
        ExecutionP.BaseRevision,
        ExecutionP,
        TransactionP,
        BlockP,
        ExecutionP.Support,
        OptionsFor(execution_definition),
        ExecutionP.Instruction.Value,
        TransactionP.transaction.ValidationError,
        transaction.Prepared(TransactionP),
        transaction.PrepareResult(TransactionP),
        executor_module.Executor(ExecutionP),
        interpreter_module.For(ExecutionP),
        transaction_policy,
        block_policy,
    );
}

/// Internal ZLS carrier. Keep definition-dependent public types flat: wrapping
/// them in a descriptor type makes ZLS lose their fields and enum tags.
fn Typed(
    comptime RevisionType: type,
    comptime BaseRevisionType: type,
    comptime ExecutionProtocolType: type,
    comptime TransactionProtocolType: type,
    comptime BlockProtocolType: type,
    comptime SupportType: type,
    comptime OptionsType: type,
    comptime InstructionValueType: type,
    comptime ValidationErrorType: type,
    comptime PreparedTransactionType: type,
    comptime PreparedTransactionResultType: type,
    comptime ExecutorType: type,
    comptime InterpreterType: type,
    comptime default_transaction_policy: definition_module.TransactionPolicy(RevisionType),
    comptime default_block_policy: definition_module.BlockPolicy(RevisionType),
) type {
    if (ExecutionProtocolType.Revision != RevisionType) @compileError("Protocol revision mismatch");
    if (ExecutionProtocolType.BaseRevision != BaseRevisionType) @compileError("Protocol base revision mismatch");
    if (ExecutionProtocolType.Support != SupportType) @compileError("Protocol support mismatch");
    if (ExecutionProtocolType.Instruction.Value != InstructionValueType) @compileError("Protocol instruction value mismatch");
    if (TransactionProtocolType.ExecutionProtocol != ExecutionProtocolType) @compileError("Transaction protocol execution mismatch");
    if (BlockProtocolType.TransactionProtocol != TransactionProtocolType) @compileError("Block protocol transaction mismatch");
    if (TransactionProtocolType.Tx.Value != transaction.Transaction) @compileError("Protocol transaction mismatch");
    if (TransactionProtocolType.Tx.View != transaction.TransactionView) @compileError("Protocol transaction view mismatch");
    if (TransactionProtocolType.transaction.ValidationError != ValidationErrorType) @compileError("Protocol validation error mismatch");
    if (transaction.Prepared(TransactionProtocolType) != PreparedTransactionType) @compileError("Prepared transaction mismatch");
    if (transaction.PrepareResult(TransactionProtocolType) != PreparedTransactionResultType) @compileError("Prepared transaction result mismatch");
    if (executor_module.Executor(ExecutionProtocolType) != ExecutorType) @compileError("Executor mismatch");
    if (interpreter_module.For(ExecutionProtocolType) != InterpreterType) @compileError("Interpreter mismatch");

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
    const EthereumTransactionProgram = eth_transition.Program(
        TransactionProtocolType,
        PublicTransactInput,
        TxExecutionResult,
    );
    const TransactionBinding = struct {
        pub const Executor = ExecutorType;
        pub const TransactionProtocol = TransactionProtocolType;
        pub const TransactionPolicy = TransactionPolicyType;
        pub const transaction_policy = default_transaction_policy;
    };
    const BoundTransactionProgram = EthereumTransactionProgram.bind(TransactionBinding);
    const EthereumBlock = eth_block_program.For(
        BlockPolicyType,
        BoundTransactionProgram,
        Env,
        IncludedTransactionViewType,
        BlockResult,
    );
    const BeforeTransactionPrelude = EthereumBlock.Prelude;
    const EthereumBlockProgram = EthereumBlock.Program;

    return struct {
        const Self = @This();
        pub const ExecutionProtocol = ExecutionProtocolType;
        pub const TransactionProtocol = TransactionProtocolType;
        pub const TransactionPolicy = TransactionPolicyType;
        pub const BlockPolicy = BlockPolicyType;
        pub const transaction_policy = default_transaction_policy;
        pub const block_policy = default_block_policy;
        pub const BlockProtocol = BlockProtocolType;
        pub const Options = OptionsType;
        pub const Support = SupportType;
        pub const Revision = RevisionType;
        pub const BaseRevision = BaseRevisionType;
        /// Editor-facing instruction API rebuilt around the flat Value carrier.
        pub const Instruction = struct {
            pub const Value = InstructionValueType;
            pub const Context = ProtocolInstruction.Context;

            pub fn fromByte(comptime opcode_byte: u8) Value {
                return ProtocolInstruction.fromByte(opcode_byte);
            }

            pub fn context(comptime value: Value) Context {
                return ProtocolInstruction.context(value);
            }

            pub fn entry(comptime value: Value) protocol_module.DispatchEntry {
                return ProtocolInstruction.entry(value);
            }

            pub fn info(comptime value: Value) opcode_info.OpInfo {
                return ProtocolInstruction.info(value);
            }

            pub fn rawAvailability(comptime value: Value) ExecutionProtocolType.Availability {
                return ProtocolInstruction.rawAvailability(value);
            }

            pub fn availability(comptime value: Value) protocol_module.Resolution {
                return ProtocolInstruction.availability(value);
            }

            pub fn staticGasForRevision(revision: RevisionType, comptime value: Value) i64 {
                return ProtocolInstruction.staticGasForRevision(revision, value);
            }

            pub fn tier(comptime value: Value) protocol_module.OpcodeTier {
                return ProtocolInstruction.tier(value);
            }

            pub fn executionTarget(comptime value: Value) protocol_module.ExecutionTarget {
                return ProtocolInstruction.executionTarget(value);
            }

            pub fn staticGas(comptime value: Value) protocol_module.StaticGas {
                return ProtocolInstruction.staticGas(value);
            }

            pub fn staticGasConstant(comptime value: Value) ?i64 {
                return ProtocolInstruction.staticGasConstant(value);
            }

            pub fn expByteGas(revision: RevisionType) i64 {
                return ProtocolInstruction.expByteGas(revision);
            }

            pub fn accountReadColdAccessGas(revision: RevisionType) ?i64 {
                return ProtocolInstruction.accountReadColdAccessGas(revision);
            }

            pub fn codeAccountAccessGas(revision: RevisionType, status: protocol_module.AccountAccessStatus) ?i64 {
                return ProtocolInstruction.codeAccountAccessGas(revision, status);
            }
        };
        pub const Transaction = transaction.Transaction;
        pub const Output = TxExecutionResult;
        pub const TransactionView = transaction.TransactionView;
        pub const Rejection = ValidationErrorType;
        pub const Environment = Env;
        pub const TransactionLog = Log;
        pub const TxStatus = TxStatusType;
        pub const PreparedTransaction = PreparedTransactionType;
        pub const PreparedTransactionResult = PreparedTransactionResultType;
        pub const Executor = ExecutorType;
        pub const Interpreter = InterpreterType;
        pub const TransactionProgram = EthereumTransactionProgram;
        pub const Prelude = BoundTransactionProgram.Prelude;
        pub const PreludeContext = BoundTransactionProgram.PreludeContext;
        pub const BlockProgram = EthereumBlockProgram;
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
            return BoundTransactionProgram.withPreludeError(PreludeError);
        }

        pub fn rebindPreludeError(
            self: Self,
            comptime PreludeError: type,
        ) withPreludeError(PreludeError) {
            if (PreludeError == error{}) return self;
            return self.transaction_runtime.rebindPreludeError(PreludeError);
        }

        /// Checked transaction lease and semantic outcome come directly from
        /// the bound transaction program. Receipts begin at block inclusion.
        pub const Executed = BoundTransactionProgram.Executed;
        pub const Outcome = BoundTransactionProgram.Outcome;

        /// Borrowed facts for a transaction already included by BlockExecution.
        /// Output and logs remain valid until the next block mutation.
        pub const IncludedTransactionView = IncludedTransactionViewType;

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

        pub const RuntimeResources = executor_module.RuntimeResources;
        pub const BoundedRuntimeResources = executor_module.BoundedRuntimeResources;
        pub const BlockGas = transaction.BlockGas;
        pub const ResultGas = transaction.ResultGas;

        /// Direct block-program binding. This is the block fold boundary used
        /// by execution strategies and the family BlockSTF. It owns an
        /// exclusive, generation-checked claim over one stable Executor.
        pub const BlockExecution = EthereumBlockProgram.bind(
            Self,
            BlockPolicyType,
            default_block_policy,
        );

        /// One-worker lifecycle wrapper over `BlockExecution` with
        /// definition-owned system hooks. The embedded block owns the fold;
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

            /// Run definition-owned work before payload execution begins.
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

            /// Run definition-owned finalization calls and return their owned,
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
                call.gas,
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

        fn txStatus(status: interpreter_module.Status) TxStatusType {
            return switch (status) {
                .success => .success,
                .revert => .revert,
                .invalid => .invalid,
                .out_of_gas => .out_of_gas,
            };
        }

        fn systemCallGasUsed(gas: u64, gas_left: i64) u64 {
            if (gas_left <= 0) return gas;
            const left: u64 = @intCast(gas_left);
            return gas -| @min(gas, left);
        }
    };
}

const Default = evmz.Evm;
const EthValidationError = evmz.Evm.Rejection;

test "system call gas used handles signed gas-left boundaries" {
    try std.testing.expectEqual(@as(u64, 100), Default.systemCallGasUsed(100, -1));
    try std.testing.expectEqual(@as(u64, 100), Default.systemCallGasUsed(100, 0));
    try std.testing.expectEqual(@as(u64, 60), Default.systemCallGasUsed(100, 40));
    try std.testing.expectEqual(@as(u64, 0), Default.systemCallGasUsed(100, 100));
    try std.testing.expectEqual(@as(u64, 0), Default.systemCallGasUsed(100, std.math.maxInt(i64)));
}

fn defaultTransact(
    executor: *Default.Executor,
    input: Default.TransactInput,
) Default.Error!Default.Outcome {
    var vm = Default.init(executor);
    return vm.transact(input);
}

fn expectExecuted(result: anytype) !TxExecutionResult {
    if (comptime @TypeOf(result) == Default.Outcome) {
        return switch (result) {
            .executed => |value| blk: {
                const executed = value;
                const output = try executed.result();
                try executed.retain();
                break :blk output;
            },
            .rejected => error.UnexpectedRejection,
        };
    }
    @compileError("unsupported transaction result type");
}

fn expectRejected(result: anytype) !EthValidationError {
    if (comptime @TypeOf(result) == Default.BlockExecution.Outcome) {
        return switch (result) {
            .included => error.UnexpectedExecution,
            .rejected => |err| err,
        };
    }
    if (comptime @TypeOf(result) == Default.Outcome) {
        return switch (result) {
            .executed => |value| blk: {
                const executed = value;
                defer executed.discardIfCurrent();
                break :blk error.UnexpectedExecution;
            },
            .rejected => |err| err,
        };
    }
    @compileError("unsupported transaction result type");
}

test "Env execution context derives opcode-visible gas limit from the environment" {
    const origin = addr(0xaaaa);
    const env = Env{ .chain_id = 10, .gas_limit = 30_000_000 };
    const context = env.executionContext(origin, 7, &.{});

    try std.testing.expectEqual(@as(u256, 10), context.chain.chain_id);
    try std.testing.expectEqual(@as(u64, 30_000_000), context.block.gas_limit);
    try std.testing.expectEqual(origin, context.transaction.origin);
    try std.testing.expectEqual(@as(u256, 7), context.transaction.gas_price);
}

test "Vm defines the engine-family scopes" {
    try std.testing.expect(@sizeOf(Default) >= @sizeOf(Default.TransactionPolicy));
    try std.testing.expectEqual(@as(usize, 1), @typeInfo(Default).@"struct".fields.len);
    try std.testing.expect(@hasDecl(Default, "transact"));
    try std.testing.expect(@hasDecl(Default, "TransactInput"));
    try std.testing.expect(!@hasDecl(Default, "BlockTransactResult"));
    try std.testing.expect(@hasDecl(Default.TransactionProgram, "TransactInput"));
    try std.testing.expect(!@hasDecl(Default.TransactionProgram, "Invocation"));
    try std.testing.expect(Default.Error != anyerror);
    try std.testing.expect(Default.BlockExecution.Error != anyerror);
    try std.testing.expect(Default.Error == Default.TransactionProgram.bind(Default).Error);
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
}

test "production binders preserve flat public carriers" {
    comptime {
        if (@typeInfo(@TypeOf(Default.transact)).@"fn".return_type.? != Default.Error!Default.Outcome)
            @compileError("Vm transact return drifted");
        if (Default.BlockExecution != Default.BlockProgram.bind(
            Default,
            Default.BlockPolicy,
            Default.block_policy,
        ))
            @compileError("Vm BlockExecution is not the direct block-program binding");
        if (Default.BlockProgram.Transaction != Default.Transaction)
            @compileError("block program transaction carrier drifted");
        if (Default.BlockProgram.Output != Default.Output)
            @compileError("block program output carrier drifted");
        if (Default.BlockProgram.Rejection != Default.Rejection)
            @compileError("block program rejection carrier drifted");
        if (Default.BlockExecution.TransactionRuntime != Default)
            @compileError("block transaction runtime identity drifted");
        if (Default.BlockExecution.Transaction != Default.Transaction)
            @compileError("block transaction carrier drifted");
        if (Default.BlockExecution.Output != Default.Output)
            @compileError("block output carrier drifted");
        if (Default.BlockExecution.Included != Default.IncludedTransactionView)
            @compileError("block included carrier drifted");
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
    const AlternateTransaction = comptime evmz.eth.defineTransaction(.{
        .transaction = .{ .maxInitcodeSize = overrides.maxInitcodeSize },
    });
    const AlternateBlock = comptime evmz.eth.defineBlock(.{
        .block = .{ .beforeBlock = overrides.beforeBlock },
    });
    const Alternate = evmz.Vm(
        evmz.eth.Revision,
        evmz.eth.execution_definition,
        AlternateTransaction,
        AlternateBlock,
        .{},
    );
    comptime {
        if (Default == Alternate)
            @compileError("family customization collapsed to the base Vm");
        if (Default.Executor != Alternate.Executor)
            @compileError("transaction or block customization changed Executor identity");
        if (Default.Executor.Protocol != Default.ExecutionProtocol)
            @compileError("Vm.Executor is not bound to the execution-only protocol");
        if (@hasDecl(Default.Executor.Protocol, "transaction"))
            @compileError("execution protocol leaked transaction policy");
        if (@hasDecl(Default.Executor.Protocol, "block"))
            @compileError("execution protocol leaked block policy");
    }
}

test "Executed carries family output beside the checked lease" {
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(Default.Executor.ExecutionLease));
    try std.testing.expect(@sizeOf(Default.Executed) >= @sizeOf(Default.Executor.ExecutionLease));
    try std.testing.expect(@sizeOf(Default.Executed) <= @sizeOf(Default.Executor.ExecutionLease) + @sizeOf(TxExecutionResult) + @alignOf(TxExecutionResult));
    try std.testing.expect(!@hasField(Default, "direct_execution"));
}

test "transaction prelude is narrow and replaces the prepared block bridge" {
    const Bound = Default.TransactionProgram.bind(Default);
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

test "transaction program wrapper extends Ethereum before Vm completes attempt" {
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
    const WrappedTransition = struct {
        pub const Input = WrappedInput;

        pub fn For(comptime Context: type) type {
            const Base = Default.TransactionProgram.For(Context);
            return struct {
                pub const Error = Base.Error || error{WrappedPolicyFailure};

                pub fn transact(
                    context: *Context,
                    tx_value: WrappedTx,
                ) Error!transaction.TransitionOutcome(WrappedOutput, Default.Rejection) {
                    const base = try Base.transact(context, tx_value.ethereum);
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
        }
    };
    const WrappedProgram = transaction.Program(
        WrappedTx,
        WrappedOutput,
        Default.Rejection,
        WrappedTransition,
    );
    const WrappedVm = WrappedProgram.bind(Default);
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
    const WrappedBlockProgram = evmz.BlockProgram(
        WrappedTx,
        WrappedOutput,
        Default.Rejection,
        Env,
        WrappedIncluded,
        u64,
        WrappedBlockImpl,
    );
    const WrappedBlockExecution = WrappedBlockProgram.bind(
        WrappedVm,
        Default.BlockPolicy,
        Default.block_policy,
    );
    comptime {
        if (WrappedVm.Executor != Default.Executor)
            @compileError("transaction program changed Executor identity");
        if (WrappedVm.Transaction != WrappedTx)
            @compileError("wrapped transaction type was lost");
        if (WrappedVm.Output != WrappedOutput)
            @compileError("wrapped output type was lost");
        if (WrappedBlockExecution.TransactionRuntime != WrappedVm)
            @compileError("wrapped block program changed transaction runtime identity");
        if (WrappedBlockExecution.Transaction != WrappedTx)
            @compileError("wrapped block transaction type was lost");
        if (WrappedBlockExecution.Output != WrappedOutput)
            @compileError("wrapped block output type was lost");
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
        ) Default.IncludedTransactionView {
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
    const Program = Default.BlockProgram;
    const CountingProgram = evmz.BlockProgram(
        Default.Transaction,
        Default.Output,
        Default.Rejection,
        Env,
        Default.IncludedTransactionView,
        BlockResult,
        CountingFold,
    );
    const PreludeProgram = evmz.BlockProgram(
        Default.Transaction,
        Default.Output,
        Default.Rejection,
        Env,
        Default.IncludedTransactionView,
        BlockResult,
        PreludeFold,
    );
    const ConcreteContext = transaction.Context(Default, Default.TransactInput);
    const ConcreteEthereum = Default.TransactionProgram.For(ConcreteContext);
    const ConcreteTransition = struct {
        pub const Input = Default.TransactInput;
        pub const Error = ConcreteEthereum.Error;

        pub fn transact(
            context: *ConcreteContext,
            tx_value: Default.Transaction,
        ) Error!transaction.TransitionOutcome(Default.Output, Default.Rejection) {
            return ConcreteEthereum.transact(context, tx_value);
        }
    };
    const ConcreteProgram = transaction.Program(
        Default.Transaction,
        Default.Output,
        Default.Rejection,
        ConcreteTransition,
    );
    const ConcreteRuntime = ConcreteProgram.bind(Default);
    const Bound = Program.bind(Default, Default.BlockPolicy, Default.block_policy);
    const CountingBound = CountingProgram.bind(Default, Default.BlockPolicy, Default.block_policy);
    const PreludeBound = PreludeProgram.bind(Default, Default.BlockPolicy, Default.block_policy);
    const ConcretePreludeBound = PreludeProgram.bind(
        ConcreteRuntime,
        Default.BlockPolicy,
        Default.block_policy,
    );
    comptime {
        if (Bound.TransactionRuntime != Default)
            @compileError("block program changed transaction runtime identity");
        if (CountingBound.TransactionRuntime != Default)
            @compileError("alternate block program changed transaction runtime identity");
        if (Bound == CountingBound) @compileError("distinct block programs collapsed to one type");
        if (ConcretePreludeBound.TransactionRuntime.Context != ConcreteContext)
            @compileError("block prelude error changed the concrete transaction context identity");
        const prelude_error: PreludeBound.Error = error.CustomPreludeFailure;
        if (prelude_error != error.CustomPreludeFailure)
            @compileError("block prelude error was lost");
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
    var prelude_block = try PreludeBound.init(
        &prelude_executor,
        .{ .gas_limit = 100_000 },
    );
    defer prelude_block.discardIfUnfinished();
    const FailingPrelude = struct {
        pub fn run(
            _: *@This(),
            _: PreludeBound.PreludeContext,
        ) PreludeBound.PreludeContext.Error!void {
            return error.CustomPreludeFailure;
        }
    };
    var failing_prelude = FailingPrelude{};
    try std.testing.expectError(error.CustomPreludeFailure, prelude_block.transactWithPrelude(
        .{ .sender = addr(0xaaaa), .to = addr(0xbbbb), .gas_limit = 30_000 },
        PreludeBound.Prelude.init(&failing_prelude),
    ));
    try std.testing.expectEqual(@as(u64, 0), (try prelude_block.finish()).tx_count);
}

test "block claim cannot authorize another Executor" {
    const Bound = Default.BlockProgram.bind(
        Default,
        Default.BlockPolicy,
        Default.block_policy,
    );
    var claimed_executor = Default.Executor.init(std.testing.allocator, .{ .revision = .cancun });
    defer claimed_executor.deinit();
    var other_executor = Default.Executor.init(std.testing.allocator, .{ .revision = .cancun });
    defer other_executor.deinit();

    var block = try Bound.init(
        &claimed_executor,
        .{ .gas_limit = 100_000 },
    );
    defer block.discardIfUnfinished();
    var other_vm = Default.init(&other_executor);
    try std.testing.expectError(error.WrongBlockExecution, other_vm.transactInBlock(
        .{
            .env = .{ .gas_limit = 100_000 },
            .tx = .{ .sender = addr(0xaaaa), .to = addr(0xbbbb), .gas_limit = 30_000 },
        },
        block.claim,
    ));
}

test "Executor initializes with an empty changeset" {
    var executor = Default.Executor.init(std.testing.allocator, .{
        .revision = .osaka,
    });
    defer executor.deinit();

    var diff = try executor.changeset();
    defer diff.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), diff.account_updates.items.len);
}

test "Executor account code remains overlay-owned and traced with a prepared backend entry" {
    const contract = addr(0xc0de);
    const code = [_]u8{ 0x60, 0x00 };
    var memory = MemoryStore.init(std.testing.allocator);
    defer memory.deinit();

    var account = try memory.getOrCreateAccount(contract);
    try account.setCode(&code);

    const Recorder = struct {
        reads: usize = 0,
        last: evmz.trace.CodeRead = undefined,

        fn sink(self: *@This()) evmz.trace.Sink {
            return evmz.trace.Sink.init(self, .{
                .state_read = evmz.trace.StateReadKinds.initMany(&.{.code}),
            }, &.{ .stateRead = stateRead });
        }

        fn stateRead(ptr: *anyopaque, event: evmz.trace.StateRead) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.last = switch (event) {
                .code => |payload| payload,
                else => unreachable,
            };
            self.reads += 1;
        }
    };
    var recorder = Recorder{};
    var sink = recorder.sink();
    var prepared_pool = evmz.prepared_code.InMemoryPreparedPool.init(std.testing.allocator);
    defer prepared_pool.deinit();
    var executor = Default.Executor.init(std.testing.allocator, .{
        .revision = .osaka,
        .state_reader = memory.reader(),
        .prepared_code_backend = prepared_pool.backend(),
    });
    defer executor.deinit();

    const code_hash = evmz.crypto.keccak256(&code);
    const prepared = try prepared_pool.getOrPrepare(executor.preparedCodeKey(), code_hash, &code);
    var context = executor_module.CaptureContext.init(
        std.testing.allocator,
        null,
        executor_module.capture_context.stateTargetForSink(&sink),
    );
    defer context.deinit();
    executor.setCaptureContext(&context);
    try context.begin();
    defer {
        if (context.isActive()) context.abort() catch {};
        executor.setCaptureContext(null);
    }
    const view = try executor.getCode(contract);
    _ = try context.finish();

    try std.testing.expect(view.ptr != prepared.bytes.ptr);
    try std.testing.expectEqualSlices(u8, &code, view);
    try std.testing.expectEqual(@as(usize, 1), recorder.reads);
    try std.testing.expectEqualSlices(u8, &contract, &recorder.last.address);
    try std.testing.expectEqual(code.len, recorder.last.size);

    try prepared_pool.clearRetainingCapacity();
    try std.testing.expectEqualSlices(u8, &code, view);
}

test "Executor runs low-level standalone call" {
    const sender = addr(0xaaaa);
    const contract = addr(0xbbbb);
    var memory = MemoryStore.init(std.testing.allocator);
    defer memory.deinit();

    var sender_account = try memory.getOrCreateAccount(sender);
    sender_account.balance = 10_000_000;
    var contract_account = try memory.getOrCreateAccount(contract);
    try contract_account.setCode(&.{ 0x60, 0x2a, 0x5f, 0x55, 0x00 });

    var executor = Default.Executor.init(std.testing.allocator, .{
        .revision = .osaka,
        .state_reader = memory.reader(),
    });
    defer executor.deinit();

    const call = Call{
        .sender = sender,
        .recipient = contract,
    };
    const result = (try executor.runStandalone(
        (Env{}).txContext(call.sender, 0, 100_000, &.{}),
        .{ .call = call },
        .legacy(100_000),
    )).expectCall();
    try std.testing.expectEqual(interpreter_module.Status.success, result.status);

    var diff = try executor.changeset();
    defer diff.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), diff.storage_writes.items.len);
    try std.testing.expectEqual(contract, diff.storage_writes.items[0].address);
    try std.testing.expectEqual(@as(u256, 0), diff.storage_writes.items[0].key);
    try std.testing.expectEqual(@as(u256, 0x2a), diff.storage_writes.items[0].value);
}

test "Executor runs low-level standalone create" {
    const sender = addr(0xaaaa);
    const create_address = address.create(sender, 0);
    var memory = MemoryStore.init(std.testing.allocator);
    defer memory.deinit();

    var sender_account = try memory.getOrCreateAccount(sender);
    sender_account.balance = 10_000_000;

    var executor = Default.Executor.init(std.testing.allocator, .{
        .revision = .berlin,
        .state_reader = memory.reader(),
    });
    defer executor.deinit();

    const init_code = &.{ 0x60, 0x00, 0x60, 0x00, 0x53, 0x60, 0x01, 0x60, 0x00, 0xf3 };
    const create = Create{
        .sender = sender,
        .recipient = create_address,
        .init_code = init_code,
    };
    const result = (try executor.runStandalone(
        (Env{}).txContext(create.sender, 0, 100_000, &.{}),
        .{ .create = create },
        .legacy(100_000),
    )).expectCreate();
    try std.testing.expectEqual(interpreter_module.Status.success, result.status);
    try std.testing.expectEqualSlices(u8, &create_address, &result.address);

    var diff = try executor.changeset();
    defer diff.deinit(std.testing.allocator);
    diff.sort();
    try std.testing.expectEqual(@as(usize, 2), diff.account_updates.items.len);
    try std.testing.expectEqual(sender, diff.account_updates.items[0].address);
    try std.testing.expectEqual(@as(u64, 1), diff.account_updates.items[0].nonce);
    try std.testing.expectEqual(create_address, diff.account_updates.items[1].address);
    try std.testing.expectEqual(@as(usize, 1), diff.code_inserts.items.len);
    try std.testing.expectEqualSlices(u8, &.{0x00}, diff.code_inserts.items[0].code);
    try std.testing.expectEqualSlices(
        u8,
        &diff.account_updates.items[1].code_hash,
        &diff.code_inserts.items[0].code_hash,
    );
}

test "transaction STF validates and executes a call" {
    const sender = addr(0xaaaa);
    const contract = addr(0xbbbb);
    var memory = MemoryStore.init(std.testing.allocator);
    defer memory.deinit();

    var sender_account = try memory.getOrCreateAccount(sender);
    sender_account.balance = 1_000_000;
    var contract_account = try memory.getOrCreateAccount(contract);
    try contract_account.setCode(&.{ 0x60, 0x2a, 0x5f, 0x55, 0x00 });

    var executor = Default.Executor.init(std.testing.allocator, .{
        .revision = .osaka,
        .state_reader = memory.reader(),
    });
    defer executor.deinit();

    const outcome = try defaultTransact(&executor, .{
        .env = .{ .gas_limit = 1_000_000 },
        .tx = .{
            .sender = sender,
            .to = contract,
            .gas_limit = 300_000,
        },
    });
    const executed = switch (outcome) {
        .executed => |value| value,
        .rejected => return error.UnexpectedRejection,
    };
    defer executed.discardIfCurrent();
    const result = try executed.result();
    try std.testing.expectEqual(TxStatus.success, result.status);
    try std.testing.expectEqual(TxStatus.success, result.status);
    try std.testing.expect(result.gas.used > 21_000);
    try std.testing.expectEqual(result.gas.used, result.gas.block.total);

    var diff = try executed.changeset();
    defer diff.deinit(std.testing.allocator);
    diff.sort();
    try std.testing.expectEqual(@as(usize, 1), diff.account_updates.items.len);
    try std.testing.expectEqual(sender, diff.account_updates.items[0].address);
    try std.testing.expectEqual(@as(u64, 1), diff.account_updates.items[0].nonce);
    try std.testing.expectEqual(@as(usize, 1), diff.storage_writes.items.len);
    try std.testing.expectEqual(contract, diff.storage_writes.items[0].address);
    try std.testing.expectEqual(@as(u256, 0x2a), diff.storage_writes.items[0].value);
}

test "transaction STF needs only an Executor and explicit input" {
    const sender = addr(0xaaaa);
    const contract = addr(0xbbbb);
    var memory = MemoryStore.init(std.testing.allocator);
    defer memory.deinit();

    var sender_account = try memory.getOrCreateAccount(sender);
    sender_account.balance = 1_000_000;
    var contract_account = try memory.getOrCreateAccount(contract);
    try contract_account.setCode(&.{ 0x60, 0x2a, 0x5f, 0x55, 0x00 });

    var executor = Default.Executor.init(std.testing.allocator, .{
        .revision = .osaka,
        .state_reader = memory.reader(),
    });
    defer executor.deinit();

    const outcome = try defaultTransact(&executor, .{
        .env = .{ .gas_limit = 1_000_000 },
        .tx = .{
            .sender = sender,
            .to = contract,
            .gas_limit = 300_000,
        },
    });
    const executed = switch (outcome) {
        .executed => |value| value,
        .rejected => return error.UnexpectedRejection,
    };
    defer executed.discardIfCurrent();

    const result = try executed.result();
    try std.testing.expectEqual(TxStatus.success, result.status);
    try std.testing.expect(result.gas.used > 21_000);
    try executed.discard();
    try std.testing.expect(!executor.hasCurrentTransaction());
}

test "Sequential needs only a stable Executor and explicit environment" {
    const sender = addr(0xaaaa);
    const recipient = addr(0xbbbb);
    var memory = MemoryStore.init(std.testing.allocator);
    defer memory.deinit();

    var sender_account = try memory.getOrCreateAccount(sender);
    sender_account.balance = 1_000_000;

    var executor = Default.Executor.init(std.testing.allocator, .{
        .revision = .amsterdam,
        .state_reader = memory.reader(),
    });
    defer executor.deinit();

    var block = try Default.Sequential.init(&executor, .{
        .env = .{ .gas_limit = 1_000_000 },
    });
    defer block.discardIfUnfinished();
    const included = switch (try block.transact(.{
        .sender = sender,
        .to = recipient,
        .gas_limit = 100_000,
    })) {
        .included => |value| value,
        .rejected => return error.UnexpectedRejection,
    };

    try std.testing.expectEqual(TxStatus.success, included.result.status);
    try std.testing.expectEqual(@as(u64, 1), (try block.finish()).tx_count);
    try std.testing.expectEqual(@as(u64, 1), (try executor.getAccountOrLoad(sender)).?.nonce);
    try std.testing.expect(!@hasField(Default.Sequential, "vm"));
}

test "executed transaction discards without allocating" {
    const sender = addr(0xaaaa);
    const contract = addr(0xbbbb);
    var memory = MemoryStore.init(std.testing.allocator);
    defer memory.deinit();

    var sender_account = try memory.getOrCreateAccount(sender);
    sender_account.balance = 1_000_000;
    var contract_account = try memory.getOrCreateAccount(contract);
    try contract_account.setCode(&.{ 0x60, 0x2a, 0x5f, 0x55, 0x00 });

    var failing_allocator = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var executor = Default.Executor.init(failing_allocator.allocator(), .{
        .revision = .amsterdam,
        .state_reader = memory.reader(),
    });
    defer executor.deinit();

    const outcome = try defaultTransact(&executor, .{
        .env = .{ .gas_limit = 1_000_000 },
        .tx = .{
            .sender = sender,
            .to = contract,
            .gas_limit = 300_000,
            .value = 7,
        },
    });
    const executed = switch (outcome) {
        .executed => |value| value,
        .rejected => return error.UnexpectedRejection,
    };
    defer executed.discardIfCurrent();

    try std.testing.expectEqual(TxStatus.success, (try executed.result()).status);
    try std.testing.expectEqual(@as(usize, 1), (try executed.logs()).len);
    try std.testing.expectError(
        error.ExecutedTransactionActive,
        defaultTransact(&executor, .{
            .env = .{ .gas_limit = 1_000_000 },
            .tx = .{
                .sender = sender,
                .to = contract,
                .gas_limit = 300_000,
            },
        }),
    );

    failing_allocator.fail_index = failing_allocator.alloc_index;
    try executed.discard();
    try std.testing.expect(!failing_allocator.has_induced_failure);
    failing_allocator.fail_index = std.math.maxInt(usize);

    try std.testing.expectEqual(@as(u256, 0), try executor.getStorage(contract, 0));
    try std.testing.expectEqual(@as(usize, 0), executor.logs().len);
    var diff = try executor.changeset();
    defer diff.deinit(failing_allocator.allocator());
    try std.testing.expectEqual(@as(usize, 0), diff.account_updates.items.len);
    try std.testing.expectEqual(@as(usize, 0), diff.storage_writes.items.len);
}

test "changeset failure leaves the current execution discardable" {
    const sender = addr(0xaaaa);
    const contract = addr(0xbbbb);
    var memory = MemoryStore.init(std.testing.allocator);
    defer memory.deinit();

    var sender_account = try memory.getOrCreateAccount(sender);
    sender_account.balance = 1_000_000;
    var contract_account = try memory.getOrCreateAccount(contract);
    try contract_account.setCode(&.{ 0x60, 0x2a, 0x5f, 0x55, 0x00 });

    var failing_allocator = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var executor = Default.Executor.init(failing_allocator.allocator(), .{
        .revision = .amsterdam,
        .state_reader = memory.reader(),
    });
    defer executor.deinit();

    const executed = switch (try defaultTransact(&executor, .{
        .env = .{ .gas_limit = 1_000_000 },
        .tx = .{
            .sender = sender,
            .to = contract,
            .gas_limit = 300_000,
        },
    })) {
        .executed => |value| value,
        .rejected => return error.UnexpectedRejection,
    };
    defer executed.discardIfCurrent();

    failing_allocator.fail_index = failing_allocator.alloc_index;
    try std.testing.expectError(error.OutOfMemory, executed.changeset());
    failing_allocator.fail_index = std.math.maxInt(usize);

    try std.testing.expectEqual(TxStatus.success, (try executed.result()).status);
    try executed.discard();
}

test "backend commit failure leaves the current execution discardable" {
    const sender = addr(0xaaaa);
    const contract = addr(0xbbbb);
    var memory = MemoryStore.init(std.testing.allocator);
    defer memory.deinit();

    var sender_account = try memory.getOrCreateAccount(sender);
    sender_account.balance = 1_000_000;
    var contract_account = try memory.getOrCreateAccount(contract);
    try contract_account.setCode(&.{ 0x60, 0x2a, 0x5f, 0x55, 0x00 });

    var committer_anchor: u8 = 0;
    const failing_committer = Committer{ .ptr = &committer_anchor, .vtable = &.{
        .commit = struct {
            fn commit(_: *anyopaque, _: *const Changeset) !void {
                return error.CommitFailed;
            }
        }.commit,
    } };
    var executor = Default.Executor.init(std.testing.allocator, .{
        .revision = .amsterdam,
        .state_reader = memory.reader(),
    });
    defer executor.deinit();

    const executed = switch (try defaultTransact(&executor, .{
        .env = .{ .gas_limit = 1_000_000 },
        .tx = .{
            .sender = sender,
            .to = contract,
            .gas_limit = 300_000,
        },
    })) {
        .executed => |value| value,
        .rejected => return error.UnexpectedRejection,
    };
    defer executed.discardIfCurrent();

    var diff = try executed.changeset();
    defer diff.deinit(std.testing.allocator);
    try std.testing.expectError(error.CommitFailed, failing_committer.commit(&diff));
    try std.testing.expectEqual(TxStatus.success, (try executed.result()).status);
    try executed.discard();
}

test "copied execution leases cannot discard a stale transaction" {
    const sender = addr(0xaaaa);
    const recipient = addr(0xbbbb);
    var memory = MemoryStore.init(std.testing.allocator);
    defer memory.deinit();

    var sender_account = try memory.getOrCreateAccount(sender);
    sender_account.balance = 1_000_000;

    var executor = Default.Executor.init(std.testing.allocator, .{
        .revision = .amsterdam,
        .state_reader = memory.reader(),
    });
    defer executor.deinit();

    const first = switch (try defaultTransact(&executor, .{
        .env = .{ .gas_limit = 1_000_000 },
        .tx = .{
            .sender = sender,
            .to = recipient,
            .gas_limit = 300_000,
        },
    })) {
        .executed => |executed| executed,
        .rejected => return error.UnexpectedRejection,
    };
    const copied = first;
    var first_diff = try first.changeset();
    first_diff.deinit(std.testing.allocator);
    try first.retain();
    try std.testing.expectError(error.NoCurrentTransaction, copied.discard());

    const second = switch (try defaultTransact(&executor, .{
        .env = .{ .gas_limit = 1_000_000 },
        .tx = .{
            .sender = sender,
            .nonce = 1,
            .to = recipient,
            .gas_limit = 300_000,
        },
    })) {
        .executed => |executed| executed,
        .rejected => return error.UnexpectedRejection,
    };
    defer second.discardIfCurrent();

    try std.testing.expectError(error.StaleTransactionExecution, copied.result());
    copied.discardIfCurrent();
    try std.testing.expectEqual(TxStatus.success, (try second.result()).status);
    try second.discard();
}

test "transaction STF forwards BLOCKHASH to the Executor source" {
    const TestBlockHashSource = struct {
        const Self = @This();

        last_number: ?u64 = null,

        fn source(self: *Self) BlockHashSource {
            return .{ .ptr = self, .vtable = &.{
                .getBlockHash = getBlockHash,
            } };
        }

        fn getBlockHash(ptr: *anyopaque, number: u64) !?u256 {
            const self: *Self = @ptrCast(@alignCast(ptr));
            self.last_number = number;
            return if (number == 999) 0xab else null;
        }
    };

    const sender = addr(0xaaaa);
    const contract = addr(0xbbbb);
    var memory = MemoryStore.init(std.testing.allocator);
    defer memory.deinit();

    var sender_account = try memory.getOrCreateAccount(sender);
    sender_account.balance = 10_000_000;
    var contract_account = try memory.getOrCreateAccount(contract);
    try contract_account.setCode(&.{ 0x61, 0x03, 0xe7, 0x40, 0x5f, 0x55, 0x00 });

    var block_hashes = TestBlockHashSource{};
    var executor = Default.Executor.init(std.testing.allocator, .{
        .revision = .prague,
        .state_reader = memory.reader(),
        .block_hash_source = block_hashes.source(),
    });
    defer executor.deinit();

    const result = try expectExecuted(try defaultTransact(&executor, .{
        .env = .{ .number = 1000, .gas_limit = 1_000_000 },
        .tx = .{
            .sender = sender,
            .to = contract,
            .gas_limit = 300_000,
        },
    }));
    try std.testing.expectEqual(TxStatus.success, result.status);
    try std.testing.expectEqual(@as(?u64, 999), block_hashes.last_number);

    var diff = try executor.changeset();
    defer diff.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), diff.storage_writes.items.len);
    try std.testing.expectEqual(contract, diff.storage_writes.items[0].address);
    try std.testing.expectEqual(@as(u256, 0xab), diff.storage_writes.items[0].value);
}

test "transaction STF reports successful create address" {
    const sender = addr(0xaaaa);
    const create_address = address.create(sender, 0);
    var memory = MemoryStore.init(std.testing.allocator);
    defer memory.deinit();

    var sender_account = try memory.getOrCreateAccount(sender);
    sender_account.balance = 1_000_000;

    var executor = Default.Executor.init(std.testing.allocator, .{
        .revision = .berlin,
        .state_reader = memory.reader(),
    });
    defer executor.deinit();

    const init_code = &.{ 0x60, 0x00, 0x60, 0x00, 0x53, 0x60, 0x01, 0x60, 0x00, 0xf3 };
    const result = try expectExecuted(try defaultTransact(&executor, .{
        .env = .{ .gas_limit = 1_000_000 },
        .tx = .{
            .sender = sender,
            .gas_limit = 300_000,
            .input = init_code,
        },
    }));
    try std.testing.expectEqual(TxStatus.success, result.status);
    try std.testing.expectEqualSlices(u8, &create_address, &result.created_address.?);

    var diff = try executor.changeset();
    defer diff.deinit(std.testing.allocator);
    diff.sort();
    try std.testing.expectEqual(@as(usize, 2), diff.account_updates.items.len);
    try std.testing.expectEqual(sender, diff.account_updates.items[0].address);
    try std.testing.expectEqual(@as(u64, 1), diff.account_updates.items[0].nonce);
    try std.testing.expectEqual(create_address, diff.account_updates.items[1].address);
    try std.testing.expectEqual(@as(usize, 1), diff.code_inserts.items.len);
    try std.testing.expectEqualSlices(u8, &.{0x00}, diff.code_inserts.items[0].code);
    try std.testing.expectEqualSlices(
        u8,
        &diff.account_updates.items[1].code_hash,
        &diff.code_inserts.items[0].code_hash,
    );
}

test "transaction STF returns rejected validation result" {
    const sender = addr(0xaaaa);
    var memory = MemoryStore.init(std.testing.allocator);
    defer memory.deinit();

    var sender_account = try memory.getOrCreateAccount(sender);
    sender_account.balance = 10_000_000;
    sender_account.nonce = 7;

    var executor = Default.Executor.init(std.testing.allocator, .{
        .revision = .osaka,
        .state_reader = memory.reader(),
    });
    defer executor.deinit();

    const result = try defaultTransact(&executor, .{
        .env = .{ .gas_limit = 1_000_000 },
        .tx = .{
            .sender = sender,
            .nonce = 1,
            .to = addr(0xbbbb),
            .gas_limit = 300_000,
        },
    });
    try std.testing.expectEqual(EthValidationError.nonce_too_low, try expectRejected(result));

    var diff = try executor.changeset();
    defer diff.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), diff.account_updates.items.len);
    try std.testing.expectEqual(@as(usize, 0), diff.storage_writes.items.len);
}

test "rejected transaction preserves the retained Executor overlay" {
    const sender = addr(0xaaaa);
    const contract = addr(0xbbbb);
    var memory = MemoryStore.init(std.testing.allocator);
    defer memory.deinit();

    var sender_account = try memory.getOrCreateAccount(sender);
    sender_account.balance = 1_000_000;
    var contract_account = try memory.getOrCreateAccount(contract);
    try contract_account.setCode(&.{ 0x60, 0x2a, 0x5f, 0x55, 0x00 });

    var executor = Default.Executor.init(std.testing.allocator, .{
        .revision = .osaka,
        .state_reader = memory.reader(),
    });
    defer executor.deinit();

    _ = try expectExecuted(try defaultTransact(&executor, .{
        .env = .{ .gas_limit = 1_000_000 },
        .tx = .{
            .sender = sender,
            .to = contract,
            .gas_limit = 300_000,
        },
    }));
    const rejected = try defaultTransact(&executor, .{
        .env = .{ .gas_limit = 1_000_000 },
        .tx = .{
            .sender = sender,
            .nonce = 99,
            .to = contract,
            .gas_limit = 100_000,
        },
    });
    try std.testing.expectEqual(EthValidationError.nonce_too_high, try expectRejected(rejected));

    var diff = try executor.changeset();
    defer diff.deinit(std.testing.allocator);
    diff.sort();
    try std.testing.expectEqual(@as(usize, 1), diff.storage_writes.items.len);
    try std.testing.expectEqual(contract, diff.storage_writes.items[0].address);
    try std.testing.expectEqual(@as(u256, 0x2a), diff.storage_writes.items[0].value);
}

test "explicit backend commit persists then rebases the Executor overlay" {
    const sender = addr(0xaaaa);
    const contract = addr(0xbbbb);
    var memory = MemoryStore.init(std.testing.allocator);
    defer memory.deinit();

    var sender_account = try memory.getOrCreateAccount(sender);
    sender_account.balance = 10_000_000;
    var contract_account = try memory.getOrCreateAccount(contract);
    try contract_account.setCode(&.{ 0x60, 0x2a, 0x5f, 0x55, 0x00 });

    var executor = Default.Executor.init(std.testing.allocator, .{
        .revision = .osaka,
        .state_reader = memory.reader(),
    });
    defer executor.deinit();

    const executed = switch (try defaultTransact(&executor, .{
        .env = .{ .gas_limit = 1_000_000 },
        .tx = .{
            .sender = sender,
            .to = contract,
            .gas_limit = 300_000,
        },
    })) {
        .executed => |value| value,
        .rejected => return error.UnexpectedRejection,
    };
    defer executed.discardIfCurrent();
    var committed = try executed.changeset();
    defer committed.deinit(std.testing.allocator);
    try memory.committer().commit(&committed);
    try executed.retain();
    executor.discardChanges();

    var diff = try executor.changeset();
    defer diff.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), diff.account_updates.items.len);
    try std.testing.expectEqual(@as(usize, 0), diff.storage_writes.items.len);
    try std.testing.expectEqual(@as(u256, 0x2a), memory.getAccount(contract).?.getStorage(0));
}

test "Executor discardChanges drops retained overlay without touching its reader" {
    const sender = addr(0xaaaa);
    const contract = addr(0xbbbb);
    var memory = MemoryStore.init(std.testing.allocator);
    defer memory.deinit();

    var sender_account = try memory.getOrCreateAccount(sender);
    sender_account.balance = 1_000_000;
    var contract_account = try memory.getOrCreateAccount(contract);
    try contract_account.setCode(&.{ 0x60, 0x2a, 0x5f, 0x55, 0x00 });

    var executor = Default.Executor.init(std.testing.allocator, .{
        .revision = .osaka,
        .state_reader = memory.reader(),
    });
    defer executor.deinit();

    _ = try expectExecuted(try defaultTransact(&executor, .{
        .env = .{ .gas_limit = 1_000_000 },
        .tx = .{
            .sender = sender,
            .to = contract,
            .gas_limit = 300_000,
        },
    }));
    executor.discardChanges();

    var diff = try executor.changeset();
    defer diff.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), diff.account_updates.items.len);
    try std.testing.expectEqual(@as(usize, 0), diff.storage_writes.items.len);
    try std.testing.expectEqual(@as(u256, 0), memory.getAccount(contract).?.getStorage(0));
}

test "Amsterdam transaction reports gross block gas separately from receipt gas" {
    const sender = addr(0xaaaa);
    const contract = addr(0xbbbb);
    var memory = MemoryStore.init(std.testing.allocator);
    defer memory.deinit();

    var sender_account = try memory.getOrCreateAccount(sender);
    sender_account.balance = 1_000_000;
    var contract_account = try memory.getOrCreateAccount(contract);
    try contract_account.storage.put(0, 1);
    try contract_account.setCode(&.{ 0x5f, 0x5f, 0x55, 0x00 });

    var executor = Default.Executor.init(std.testing.allocator, .{
        .revision = .amsterdam,
        .state_reader = memory.reader(),
    });
    defer executor.deinit();

    const result = try expectExecuted(try defaultTransact(&executor, .{
        .env = .{ .gas_limit = 1_000_000 },
        .tx = .{
            .sender = sender,
            .to = contract,
            .gas_limit = 100_000,
        },
    }));
    try std.testing.expectEqual(TxStatus.success, result.status);
    try std.testing.expect(result.gas.refunded > 0);
    try std.testing.expect(result.gas.block.total > result.gas.used);
}

test "Executor exposes borrowed logs after transaction retention" {
    const sender = addr(0xaaaa);
    const recipient = addr(0xbbbb);
    var memory = MemoryStore.init(std.testing.allocator);
    defer memory.deinit();

    var sender_account = try memory.getOrCreateAccount(sender);
    sender_account.balance = 10_000_000;

    var executor = Default.Executor.init(std.testing.allocator, .{
        .revision = .amsterdam,
        .state_reader = memory.reader(),
    });
    defer executor.deinit();

    const result = try expectExecuted(try defaultTransact(&executor, .{
        .env = .{ .gas_limit = 1_000_000 },
        .tx = .{
            .sender = sender,
            .to = recipient,
            .gas_limit = 300_000,
            .value = 7,
        },
    }));
    try std.testing.expectEqual(TxStatus.success, result.status);
    const logs = executor.logs();
    try std.testing.expectEqual(@as(usize, 1), logs.len);
    try std.testing.expectEqualSlices(u8, &evmz.eth.system_address, &logs[0].address);
    try std.testing.expectEqual(evmz.eth.value_transfer_log_topic, logs[0].topics[0]);
}

test "rejected transaction clears the Executor log surface" {
    const sender = addr(0xaaaa);
    const recipient = addr(0xbbbb);
    var memory = MemoryStore.init(std.testing.allocator);
    defer memory.deinit();

    var sender_account = try memory.getOrCreateAccount(sender);
    sender_account.balance = 10_000_000;

    var executor = Default.Executor.init(std.testing.allocator, .{
        .revision = .amsterdam,
        .state_reader = memory.reader(),
    });
    defer executor.deinit();

    const accepted = try expectExecuted(try defaultTransact(&executor, .{
        .env = .{ .gas_limit = 1_000_000 },
        .tx = .{
            .sender = sender,
            .to = recipient,
            .gas_limit = 300_000,
            .value = 7,
        },
    }));
    try std.testing.expectEqual(TxStatus.success, accepted.status);
    try std.testing.expectEqual(@as(usize, 1), executor.logs().len);

    const rejected = try defaultTransact(&executor, .{
        .env = .{ .gas_limit = 1_000_000 },
        .tx = .{
            .sender = sender,
            .nonce = 99,
            .to = recipient,
            .gas_limit = 300_000,
            .value = 7,
        },
    });
    try std.testing.expectEqual(EthValidationError.nonce_too_high, try expectRejected(rejected));
    try std.testing.expectEqual(@as(usize, 0), executor.logs().len);
}

test "transaction STF uses comptime transaction gas policy" {
    const sender = addr(0xaaaa);
    const recipient = addr(0xbbbb);
    var memory = MemoryStore.init(std.testing.allocator);
    defer memory.deinit();

    var sender_account = try memory.getOrCreateAccount(sender);
    sender_account.balance = 10_000_000;

    var executor = Default.Executor.init(std.testing.allocator, .{
        .revision = .london,
        .state_reader = memory.reader(),
    });
    defer executor.deinit();

    const tx = Default.Transaction{
        .sender = sender,
        .to = recipient,
        .gas_limit = 21_000,
    };

    const default_result = try defaultTransact(&executor, .{
        .env = .{ .gas_limit = 1_000_000 },
        .tx = tx,
    });
    const default_execution = switch (default_result) {
        .executed => |value| value,
        .rejected => return error.UnexpectedRejection,
    };
    try default_execution.discard();

    const Overrides = struct {
        fn intrinsicBaseGas(_: evmz.eth.Revision, _: transaction.IntrinsicGasOptions) ?u64 {
            return 42_000;
        }
    };
    const HighIntrinsicTransaction = comptime evmz.eth.defineTransaction(.{ .transaction = .{
        .intrinsicBaseGas = Overrides.intrinsicBaseGas,
    } });
    const HighIntrinsicVm = Vm(
        evmz.eth.Revision,
        evmz.eth.execution_definition,
        HighIntrinsicTransaction,
        evmz.eth.block_definition,
        .{ .support = .{ .min = .london, .max = .london } },
    );
    var custom_executor = HighIntrinsicVm.Executor.init(std.testing.allocator, .{
        .revision = .london,
        .state_reader = memory.reader(),
    });
    defer custom_executor.deinit();

    var high_intrinsic_vm = HighIntrinsicVm.init(&custom_executor);
    const custom_result = try high_intrinsic_vm.transact(.{
        .env = .{ .gas_limit = 1_000_000 },
        .tx = tx,
    });
    switch (custom_result) {
        .executed => |value| {
            value.discardIfCurrent();
            try std.testing.expect(false);
        },
        .rejected => |err| try std.testing.expectEqual(EthValidationError.intrinsic_gas_too_low, err),
    }
    try std.testing.expectEqual(transaction.Transaction, HighIntrinsicVm.Transaction);
}

test "Vm instance owns its transaction policy snapshot" {
    const sender = addr(0xaaaa);
    const recipient = addr(0xbbbb);
    var memory = MemoryStore.init(std.testing.allocator);
    defer memory.deinit();

    var sender_account = try memory.getOrCreateAccount(sender);
    sender_account.balance = 10_000_000;

    var executor = Default.Executor.init(std.testing.allocator, .{
        .revision = .london,
        .state_reader = memory.reader(),
    });
    defer executor.deinit();

    const hooks = struct {
        fn strictTotalGasLimit(_: evmz.eth.Revision) ?u64 {
            return 20_000;
        }
    };
    var source_policy = Default.transaction_policy;
    source_policy.transaction.totalGasLimit = hooks.strictTotalGasLimit;
    var strict_vm = Default.initWithPolicy(&executor, source_policy);

    // The runtime owns a value snapshot, not a pointer to caller storage.
    source_policy = Default.transaction_policy;

    const input: Default.TransactInput = .{
        .env = .{ .gas_limit = 1_000_000 },
        .tx = .{
            .sender = sender,
            .to = recipient,
            .gas_limit = 21_000,
        },
    };
    const strict_result = try strict_vm.transact(input);
    try std.testing.expectEqual(
        EthValidationError.gas_allowance_exceeded,
        try expectRejected(strict_result),
    );

    // The same generated Vm and Executor can run with another policy value.
    var default_vm = Default.init(&executor);
    const default_result = try default_vm.transact(input);
    const executed = switch (default_result) {
        .executed => |value| value,
        .rejected => return error.UnexpectedRejection,
    };
    try executed.discard();
}

test "BlockExecution owns its block policy snapshot" {
    const recipient = addr(0xcafe);
    var memory = MemoryStore.init(std.testing.allocator);
    defer memory.deinit();

    var recipient_account = try memory.getOrCreateAccount(recipient);
    try recipient_account.setCode(&.{
        0x60, 0x2a, // PUSH1 42
        0x5f, // PUSH0
        0x55, // SSTORE
        0x00, // STOP
    });

    var executor = Default.Executor.init(std.testing.allocator, .{
        .revision = .cancun,
        .state_reader = memory.reader(),
    });
    defer executor.deinit();

    const hooks = struct {
        fn beforeBlock(
            _: evmz.eth.Revision,
            _: protocol_module.BeforeBlockContext,
        ) protocol_module.BlockSystemCalls {
            var calls: protocol_module.BlockSystemCalls = .{};
            calls.append(.{
                .sender = addr(0),
                .recipient = addr(0xcafe),
                .gas = 100_000,
                .require_code = true,
            });
            return calls;
        }
    };
    var source_policy = Default.block_policy;
    source_policy.beforeBlock = hooks.beforeBlock;
    var block = try Default.Sequential.initWithPolicies(
        &executor,
        Default.transaction_policy,
        source_policy,
        .{ .env = .{ .gas_limit = 1_000_000 } },
    );
    defer block.discardIfUnfinished();

    // Resetting the source does not change the block-owned value snapshot.
    source_policy = Default.block_policy;
    try block.beforeBlock(.{});
    try std.testing.expectEqual(@as(u256, 42), try executor.getStorage(recipient, 0));
}

test "Sequential validation rejection skips rollback snapshot" {
    const sender = addr(0xaaaa);
    const recipient = addr(0xbbbb);
    var memory = MemoryStore.init(std.testing.allocator);
    defer memory.deinit();

    var sender_account = try memory.getOrCreateAccount(sender);
    sender_account.balance = 10_000_000;

    var failing_allocator = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var executor = Default.Executor.init(failing_allocator.allocator(), .{
        .revision = .amsterdam,
        .state_reader = memory.reader(),
    });
    defer executor.deinit();

    try std.testing.expect((try executor.getAccountOrLoad(sender)) != null);
    failing_allocator.fail_index = failing_allocator.alloc_index;

    var block = try Default.Sequential.init(&executor, .{
        .env = .{ .gas_limit = 1_000_000 },
    });
    defer block.discardIfUnfinished();
    const rejected = try block.transact(.{
        .sender = sender,
        .nonce = 99,
        .to = recipient,
        .gas_limit = 300_000,
    });
    try std.testing.expectEqual(EthValidationError.nonce_too_high, try expectRejected(rejected));
    try std.testing.expect(!failing_allocator.has_induced_failure);
    try std.testing.expectEqual(@as(u64, 0), (try block.finish()).tx_count);
}

test "Sequential systemCall updates embedded block gas and restores overflow" {
    const recipient = addr(0xbbbb);
    var memory = MemoryStore.init(std.testing.allocator);
    defer memory.deinit();
    var recipient_account = try memory.getOrCreateAccount(recipient);
    try recipient_account.setCode(&.{ 0x60, 0x00, 0x50, 0x00 });

    var executor = Default.Executor.init(std.testing.allocator, .{
        .revision = .prague,
        .state_reader = memory.reader(),
    });
    defer executor.deinit();
    var block = try Default.Sequential.init(&executor, .{
        .env = .{ .gas_limit = 9 },
    });
    defer block.discardIfUnfinished();

    const call = SystemCall{
        .sender = addr(0xaaaa),
        .recipient = recipient,
        .gas = 9,
    };
    const result = try block.systemCall(call);

    try std.testing.expectEqual(interpreter_module.Status.success, result.status());
    try std.testing.expectEqualSlices(u8, &.{}, result.outputData());
    const progress = try block.progress();
    try std.testing.expectEqual(@as(u64, 5), progress.gas_used);
    try std.testing.expectEqual(@as(u64, 5), progress.block_gas.total);

    try std.testing.expectError(error.GasAllowanceExceeded, block.systemCall(call));
    const restored = try block.progress();
    try std.testing.expectEqual(@as(u64, 5), restored.gas_used);
    try std.testing.expectEqual(@as(u64, 5), restored.block_gas.total);
}

test "system call finalization failure restores block state" {
    const contract = addr(0xbbbb);
    const beneficiary = addr(0xbeef);
    var memory = MemoryStore.init(std.testing.allocator);
    defer memory.deinit();

    var contract_account = try memory.getOrCreateAccount(contract);
    contract_account.balance = 5;
    try contract_account.setCode(&.{ 0x61, 0xbe, 0xef, 0xff });
    var beneficiary_account = try memory.getOrCreateAccount(beneficiary);
    beneficiary_account.balance = 7;

    var executor = Default.Executor.init(std.testing.allocator, .{
        .revision = .london,
        .state_reader = memory.reader(),
    });
    defer executor.deinit();
    try executor.state.configureStateResources(.{
        .accounts = 2,
        .selfdestructed_accounts = 1,
        .deleted_accounts = 0,
        .dirty_accounts = 2,
    });

    const call = SystemCall{
        .sender = addr(0xaaaa),
        .recipient = contract,
        .gas = 100_000,
    };
    var block = try Default.Sequential.init(&executor, .{
        .env = .{ .gas_limit = 100_000 },
    });
    defer block.discardIfUnfinished();
    try std.testing.expectError(error.DeletedAccountCapacityExceeded, block.systemCall(call));
    try std.testing.expectEqual(@as(u64, 0), (try block.progress()).gas_used);
    try std.testing.expectEqual(@as(u256, 5), (try executor.getAccountOrLoad(contract)).?.balance);
    try std.testing.expectEqual(@as(u256, 7), (try executor.getAccountOrLoad(beneficiary)).?.balance);
    _ = try block.finish();
}

test "Sequential includes each transaction before returning" {
    const sender = addr(0xaaaa);
    const recipient = addr(0xbbbb);
    var memory = MemoryStore.init(std.testing.allocator);
    defer memory.deinit();

    var sender_account = try memory.getOrCreateAccount(sender);
    sender_account.balance = 10_000_000;

    var executor = Default.Executor.init(std.testing.allocator, .{
        .revision = .amsterdam,
        .state_reader = memory.reader(),
    });
    defer executor.deinit();

    var block = try Default.Sequential.init(&executor, .{
        .env = .{ .gas_limit = 1_000_000 },
    });
    defer block.discardIfUnfinished();
    const first = switch (try block.transact(.{
        .sender = sender,
        .to = recipient,
        .gas_limit = 100_000,
    })) {
        .included => |included| included,
        .rejected => return error.UnexpectedRejection,
    };
    try std.testing.expectEqual(TxStatus.success, first.result.status);
    try std.testing.expectEqual(@as(u64, 1), (try block.progress()).tx_count);

    const second = switch (try block.transact(.{
        .sender = sender,
        .nonce = 1,
        .to = recipient,
        .gas_limit = 100_000,
    })) {
        .included => |included| included,
        .rejected => return error.UnexpectedRejection,
    };
    try std.testing.expectEqual(TxStatus.success, second.result.status);
    try std.testing.expectEqual(@as(u64, 2), (try block.progress()).tx_count);
    try std.testing.expectEqual(@as(u64, 2), (try executor.getAccountOrLoad(sender)).?.nonce);
    try std.testing.expectEqual(@as(u64, 2), (try block.finish()).tx_count);
}

test "Sequential discardIfUnfinished drops included executions" {
    const sender = addr(0xaaaa);
    const recipient = addr(0xbbbb);
    var memory = MemoryStore.init(std.testing.allocator);
    defer memory.deinit();

    var sender_account = try memory.getOrCreateAccount(sender);
    sender_account.balance = 10_000_000;

    var executor = Default.Executor.init(std.testing.allocator, .{
        .revision = .amsterdam,
        .state_reader = memory.reader(),
    });
    defer executor.deinit();

    var block = try Default.Sequential.init(&executor, .{
        .env = .{ .gas_limit = 1_000_000 },
    });
    _ = try block.transact(.{
        .sender = sender,
        .to = recipient,
        .gas_limit = 100_000,
    });
    _ = try block.transact(.{
        .sender = sender,
        .nonce = 1,
        .to = recipient,
        .gas_limit = 100_000,
    });

    block.discardIfUnfinished();
    try std.testing.expectError(error.BlockExecutionFinished, block.finish());
    try std.testing.expectEqual(@as(u64, 0), (try executor.getAccountOrLoad(sender)).?.nonce);
    var diff = try executor.changeset();
    defer diff.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), diff.account_updates.items.len);
}

test "Sequential endTransactions closes the transaction phase" {
    var executor = Default.Executor.init(std.testing.allocator, .{ .revision = .amsterdam });
    defer executor.deinit();

    var block = try Default.Sequential.init(&executor, .{
        .env = .{ .gas_limit = 1_000_000 },
    });
    defer block.discardIfUnfinished();
    try block.endTransactions();
    try std.testing.expectError(error.TransactionPhaseClosed, block.transact(.{
        .sender = addr(0xaaaa),
        .to = addr(0xbbbb),
        .gas_limit = 100_000,
    }));
    try std.testing.expectEqual(@as(u64, 0), (try block.finish()).tx_count);
}

test "Sequential delegates block progress to BlockExecution" {
    try std.testing.expect(@hasField(Default.Sequential, "block"));
    try std.testing.expectEqual(Default.BlockExecution, @FieldType(Default.Sequential, "block"));
    try std.testing.expect(!@hasField(Default.Sequential, "gas_used"));
    try std.testing.expect(!@hasField(Default.Sequential, "block_gas"));
    try std.testing.expect(!@hasField(Default.Sequential, "tx_count"));
    try std.testing.expect(@hasField(Default.Sequential, "phase"));
    try std.testing.expect(!@hasField(Default, "active_block"));
}

test "Sequential rejects an overlay retained outside its lifetime" {
    const sender = addr(0xaaaa);
    const recipient = addr(0xbbbb);
    var memory = MemoryStore.init(std.testing.allocator);
    defer memory.deinit();

    var sender_account = try memory.getOrCreateAccount(sender);
    sender_account.balance = 10_000_000;

    var executor = Default.Executor.init(std.testing.allocator, .{
        .revision = .amsterdam,
        .state_reader = memory.reader(),
    });
    defer executor.deinit();

    const executed = switch (try defaultTransact(&executor, .{
        .env = .{ .gas_limit = 1_000_000 },
        .tx = .{
            .sender = sender,
            .to = recipient,
            .gas_limit = 100_000,
        },
    })) {
        .executed => |value| value,
        .rejected => return error.UnexpectedRejection,
    };
    defer executed.discardIfCurrent();
    var diff = try executed.changeset();
    diff.deinit(std.testing.allocator);
    try executed.retain();

    try std.testing.expectError(
        error.UncommittedChanges,
        Default.Sequential.init(&executor, .{ .env = .{ .gas_limit = 1_000_000 } }),
    );
    executor.discardChanges();
    var block = try Default.Sequential.init(&executor, .{
        .env = .{ .gas_limit = 1_000_000 },
    });
    defer block.discardIfUnfinished();
    _ = try block.finish();
}

test "Sequential rejects transaction whose gas limit exceeds remaining block dimensions" {
    const sender = addr(0xaaaa);
    const recipient = addr(0xbbbb);
    var memory = MemoryStore.init(std.testing.allocator);
    defer memory.deinit();

    var sender_account = try memory.getOrCreateAccount(sender);
    sender_account.balance = 10_000_000;

    var executor = Default.Executor.init(std.testing.allocator, .{
        .revision = .amsterdam,
        .state_reader = memory.reader(),
    });
    defer executor.deinit();

    var block = try Default.Sequential.init(&executor, .{
        .env = .{ .gas_limit = 29_000 },
    });
    defer block.discardIfUnfinished();
    const first = switch (try block.transact(.{
        .sender = sender,
        .to = recipient,
        .gas_limit = 29_000,
    })) {
        .included => |included| included,
        .rejected => return error.UnexpectedRejection,
    };
    const first_result = first.result;
    try std.testing.expectEqual(TxStatus.success, first_result.status);
    try std.testing.expectEqual(@as(u64, 15_000), first_result.gas.block.total);

    const rejected = try block.transact(.{
        .sender = sender,
        .to = recipient,
        .gas_limit = 29_000,
    });
    try std.testing.expectEqual(EthValidationError.gas_allowance_exceeded, try expectRejected(rejected));
    try std.testing.expectEqual(@as(u64, 1), (try block.finish()).tx_count);

    var diff = try executor.changeset();
    defer diff.deinit(std.testing.allocator);
    diff.sort();
    try std.testing.expectEqual(@as(usize, 1), diff.account_updates.items.len);
    try std.testing.expectEqual(@as(u64, 1), diff.account_updates.items[0].nonce);
    try std.testing.expectEqual(@as(usize, 0), diff.storage_writes.items.len);
}

test "Sequential returns included result and borrowed receipt view" {
    const sender = addr(0xaaaa);
    const recipient = addr(0xbbbb);
    var memory = MemoryStore.init(std.testing.allocator);
    defer memory.deinit();

    var sender_account = try memory.getOrCreateAccount(sender);
    sender_account.balance = 10_000_000;

    var executor = Default.Executor.init(std.testing.allocator, .{
        .revision = .amsterdam,
        .state_reader = memory.reader(),
    });
    defer executor.deinit();

    var block = try Default.Sequential.init(&executor, .{
        .env = .{ .gas_limit = 1_000_000 },
    });
    defer block.discardIfUnfinished();
    const included = switch (try block.transact(.{
        .sender = sender,
        .to = recipient,
        .gas_limit = 300_000,
        .value = 7,
    })) {
        .included => |value| value,
        .rejected => return error.UnexpectedRejection,
    };
    const receipt = included.receipt;
    const result = included.result;
    try std.testing.expectEqual(@as(u64, 1), (try block.progress()).tx_count);
    try std.testing.expectEqual(TxStatus.success, receipt.status);
    try std.testing.expectEqual(result.gas.used, receipt.gas_used);
    try std.testing.expectEqual(result.gas.used, receipt.cumulative_gas_used);
    try std.testing.expectEqual(@as(usize, 1), receipt.logs.len);
    try std.testing.expectEqual(evmz.eth.value_transfer_log_topic, receipt.logs[0].topics[0]);
    const summary = try block.finish();
    try std.testing.expectEqual(@as(u64, 1), summary.tx_count);
}
