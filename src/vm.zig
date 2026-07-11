//! Public runtime VM facade.
//!
//! `Vm` is the object an integration holds across blocks. It owns the low-level
//! `executor`, current environment, and optional commit sink. Protocol
//! transactions go through `transact`; diagnostics, benchmarks, and fixtures can
//! drive `executor` directly when they need raw execution control.

const std = @import("std");

const evmz = @import("evm.zig");
const address = @import("./address.zig");
const definition_module = @import("./definition.zig");
const executor_module = @import("./executor.zig");
const Host = @import("./Host.zig");
const interpreter_module = @import("./Interpreter.zig");
const protocol_module = @import("./protocol.zig");
const transaction = @import("./transaction.zig");

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
};

/// Terminal status of a transaction that reached execution.
pub const TxStatus = enum {
    success,
    revert,
    invalid,
    out_of_gas,
};

/// Execution payload for a transaction that passed validation and ran.
///
/// `output` is borrowed from the VM and remains valid until the next VM call
/// that can replace call output.
pub const TxExecutionResult = struct {
    status: TxStatus,
    /// Settled transaction gas: receipt gas, refund gas, and block contribution.
    gas: transaction.ResultGas = .{},
    output: []const u8 = &.{},
    created_address: ?Address = null,
};

/// Result of `Vm.transact`.
///
/// Validation rejection is tx/protocol state, not execution. `BlockSession`
/// reports block inclusion failures, such as block gas exhaustion, through
/// Zig errors so rejected transactions cannot accidentally build receipts.
pub fn TxResultFor(comptime Protocol: type) type {
    return union(enum) {
        executed: TxExecutionResult,
        rejected: Protocol.Transaction.ValidationError,
    };
}

/// Borrowed transaction receipt view for client/fixture receipt builders.
///
/// `logs` is borrowed from the VM and is invalidated by the next transaction,
/// discard, commit, or VM teardown. Copy it when constructing owned receipts.
pub const TxReceiptView = struct {
    status: TxStatus,
    /// Receipt gas for this transaction.
    gas_used: u64 = 0,
    /// Receipt cumulative gas across accepted transactions in this block session.
    cumulative_gas_used: u64 = 0,
    created_address: ?Address = null,
    logs: []const Log = &.{},
};

/// Summary of accepted transactions in a `BlockSession`.
pub const BlockResult = struct {
    /// Cumulative receipt gas.
    gas_used: u64 = 0,
    /// Cumulative block/header gas contribution.
    block_gas: transaction.BlockGas = .{},
    tx_count: u64 = 0,
};

/// Read-only account view borrowed from the VM overlay/state-reader cache.
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

/// Gas-derived allocation envelope for `initBound`.
///
/// This is an implementation capacity, not the consensus block environment;
/// each `beginBlock` still receives the actual `Env.gas_limit`.
pub const BlockBound = struct {
    max_block_gas: u64,
    max_live_frames: usize = executor_module.default_max_live_frames,
};
const BlockBoundType = BlockBound;

/// Public composition options specialized to one Definition value.
pub fn OptionsFor(comptime definition_value: anytype) type {
    const Definition = definition_module.Bound(definition_value);
    return struct {
        support: Definition.Support = Definition.Support.all,
        dispatch: protocol_module.DispatchConfig = .{},
    };
}

/// Compose a concrete VM type.
///
/// `R` is explicit because ZLS cannot recover the revision type through a
/// comptime Definition value. The options parameter becomes concrete once
/// `definition_value` is known.
pub fn Vm(
    comptime R: type,
    comptime definition_value: definition_module.Definition(R),
    comptime options: OptionsFor(definition_value),
) type {
    const Definition = definition_module.Bound(definition_value);
    const ProtocolType = protocol_module.ProtocolWithDispatch(definition_value, options.support, options.dispatch);
    return Typed(
        R,
        ProtocolType,
        Definition.Support,
        OptionsFor(definition_value),
        ProtocolType.Instruction,
        // The current Definition schema uses the engine transaction vocabulary.
        // Keep these concrete for ZLS; Typed verifies Protocol coherence below.
        transaction.Transaction,
        transaction.TransactionView,
        ProtocolType.Transaction.ValidationError,
        transaction.Prepared(ProtocolType),
        transaction.PrepareResult(ProtocolType),
        TxResultFor(ProtocolType),
        executor_module.Executor(ProtocolType),
        interpreter_module.For(ProtocolType),
    );
}

/// The runtime VM bound to a concrete `Protocol`.
///
/// Returns the facade described in the module doc: an object held across blocks
/// that validates and runs `Protocol` transactions via `transact`, groups them
/// into a block through `BlockSession`, and commits the resulting state diff.
/// `evm.zig` exposes the mainnet instantiation as `Evm`.
pub fn ResolvedVm(comptime Protocol: type) type {
    const SupportType = if (@hasDecl(Protocol, "Support")) Protocol.Support else void;
    const InstructionType = if (@hasDecl(Protocol, "Instruction")) Protocol.Instruction else void;
    return Typed(
        Protocol.Revision,
        Protocol,
        SupportType,
        void,
        InstructionType,
        Protocol.Transaction.Value,
        Protocol.Transaction.View,
        Protocol.Transaction.ValidationError,
        transaction.Prepared(Protocol),
        transaction.PrepareResult(Protocol),
        TxResultFor(Protocol),
        executor_module.Executor(Protocol),
        interpreter_module.For(Protocol),
    );
}

/// Internal ZLS carrier. Keep Definition-dependent public types flat: wrapping
/// them in a descriptor type makes ZLS lose their fields and enum tags.
fn Typed(
    comptime RevisionType: type,
    comptime ProtocolType: type,
    comptime SupportType: type,
    comptime OptionsType: type,
    comptime InstructionType: type,
    comptime TransactionType: type,
    comptime TransactionViewType: type,
    comptime ValidationErrorType: type,
    comptime PreparedTransactionType: type,
    comptime PreparedTransactionResultType: type,
    comptime TxResultType: type,
    comptime ExecutorType: type,
    comptime InterpreterType: type,
) type {
    if (ProtocolType.Revision != RevisionType) @compileError("Protocol revision mismatch");
    if (@hasDecl(ProtocolType, "Support")) {
        if (ProtocolType.Support != SupportType) @compileError("Protocol support mismatch");
    } else if (SupportType != void) {
        @compileError("Protocol support mismatch");
    }
    if (@hasDecl(ProtocolType, "Instruction")) {
        if (ProtocolType.Instruction != InstructionType) @compileError("Protocol instruction mismatch");
    } else if (InstructionType != void) {
        @compileError("Protocol instruction mismatch");
    }
    if (ProtocolType.Transaction.Value != TransactionType) @compileError("Protocol transaction mismatch");
    if (ProtocolType.Transaction.View != TransactionViewType) @compileError("Protocol transaction view mismatch");
    if (ProtocolType.Transaction.ValidationError != ValidationErrorType) @compileError("Protocol validation error mismatch");
    if (transaction.Prepared(ProtocolType) != PreparedTransactionType) @compileError("Prepared transaction mismatch");
    if (transaction.PrepareResult(ProtocolType) != PreparedTransactionResultType) @compileError("Prepared transaction result mismatch");
    if (TxResultFor(ProtocolType) != TxResultType) @compileError("Transaction result mismatch");
    if (executor_module.Executor(ProtocolType) != ExecutorType) @compileError("Executor mismatch");
    if (interpreter_module.For(ProtocolType) != InterpreterType) @compileError("Interpreter mismatch");

    const ProtocolNamespace = ProtocolType;
    const TxRuntime = transaction.For(ProtocolType);
    const TxStatusType = TxStatus;

    return struct {
        const Self = @This();
        const tx_protocol = TxRuntime;

        pub const Protocol = ProtocolNamespace;
        pub const Options = OptionsType;
        pub const Support = SupportType;
        pub const Revision = RevisionType;
        pub const Instruction = InstructionType;
        pub const Transaction = TransactionType;
        pub const TransactionView = TransactionViewType;
        pub const ValidationError = ValidationErrorType;
        pub const TxResult = TxResultType;
        pub const TxStatus = TxStatusType;
        pub const PreparedTransaction = PreparedTransactionType;
        pub const PreparedTransactionResult = PreparedTransactionResultType;
        pub const Executor = ExecutorType;
        pub const Interpreter = InterpreterType;

        /// Low-level execution substrate for diagnostics, fixtures, and benchmarks.
        executor: Executor,
        /// Current block/environment values used to build transaction host contexts.
        env: Env,
        /// Optional sink used by `commit` to persist the overlay diff.
        committer: ?Committer,
        /// Resource envelope enforced by the block-session API.
        block_bound: ?BlockBoundType,

        pub const BlockBound = BlockBoundType;

        pub const Init = struct {
            revision: RevisionType,
            state_reader: ?StateReader = null,
            block_hash_source: ?BlockHashSource = null,
            committer: ?Committer = null,
            env: Env = .{},
            config: evmz.ExecutionConfig = .base,
            trace_sink: ?*evmz.trace.Sink = null,
        };

        pub const RuntimeResources = executor_module.RuntimeResources;
        pub const BoundedRuntimeResources = executor_module.BoundedRuntimeResources;
        pub const BlockGas = transaction.BlockGas;
        pub const ResultGas = transaction.ResultGas;

        /// A single block's transaction sequence over one `Vm`.
        ///
        /// It executes session for multiple txs under one env, Not a Ethereum block processor.
        /// Feed transactions through `transact` to accumulate block-level gas
        /// and the transaction count. Preparation receives current gas progress;
        /// each executable call then snapshots before execution so the final fold
        /// can still roll back without tearing down the block.
        pub const BlockSession = struct {
            vm: *Self,
            /// Cumulative receipt gas for accepted transactions.
            gas_used: u64 = 0,
            /// Cumulative block/header gas for accepted transactions.
            block_gas: transaction.BlockGas = .{},
            tx_count: u64 = 0,

            pub fn transact(self: *BlockSession, tx: Self.Transaction) !Self.TxResult {
                const prepared = try self.vm.prepareTransaction(tx, .{
                    .receipt_gas_used = self.gas_used,
                    .block_gas = self.block_gas,
                });
                switch (prepared) {
                    .rejected => |err| return .{ .rejected = err },
                    .executable => |executable| {
                        var pre_tx = try self.vm.executor.snapshot();
                        defer pre_tx.deinit(self.vm.executor.allocator);
                        self.vm.executor.traceSnapshotLifecycle(.checkpoint, &pre_tx);
                        var trace_checkpoint_open = true;
                        errdefer if (trace_checkpoint_open) {
                            self.vm.executor.traceSnapshotLifecycle(.revert, &pre_tx);
                        };

                        const result = try self.vm.executePreparedTransaction(executable);
                        const next_gas_used = std.math.add(u64, self.gas_used, result.gas.used) catch {
                            trace_checkpoint_open = false;
                            return self.drop(&pre_tx);
                        };
                        const next_block_gas = self.block_gas.add(result.gas.block) catch {
                            trace_checkpoint_open = false;
                            return self.drop(&pre_tx);
                        };
                        if (!next_block_gas.withinLimit(self.vm.runtimeEnv().gas_limit)) {
                            trace_checkpoint_open = false;
                            return self.drop(&pre_tx);
                        }

                        self.gas_used = next_gas_used;
                        self.block_gas = next_block_gas;
                        self.tx_count += 1;
                        self.vm.executor.traceSnapshotLifecycle(.commit, &pre_tx);
                        trace_checkpoint_open = false;
                        return .{ .executed = result };
                    },
                }
            }

            pub fn receipt(self: *const BlockSession, result: TxExecutionResult) TxReceiptView {
                return .{
                    .status = result.status,
                    .gas_used = result.gas.used,
                    .cumulative_gas_used = self.gas_used,
                    .created_address = result.created_address,
                    .logs = self.vm.logs(),
                };
            }

            pub fn systemCall(self: *BlockSession, call: SystemCall) !EvmResult {
                var pre_call = try self.vm.executor.snapshot();
                defer pre_call.deinit(self.vm.executor.allocator);
                self.vm.executor.traceSnapshotLifecycle(.checkpoint, &pre_call);
                var trace_checkpoint_open = true;
                errdefer if (trace_checkpoint_open) {
                    self.vm.executor.traceSnapshotLifecycle(.revert, &pre_call);
                };

                const result = try self.vm.executeSystemCall(call);
                const spent = systemCallGasUsed(call.gas, result.gasLeft());
                const next_block_gas = self.block_gas.add(transaction.BlockGas.legacy(spent)) catch {
                    self.vm.executor.traceSnapshotLifecycle(.revert, &pre_call);
                    trace_checkpoint_open = false;
                    try self.vm.executor.restore(&pre_call);
                    return error.GasAllowanceExceeded;
                };
                const next_gas_used = std.math.add(u64, self.gas_used, spent) catch {
                    self.vm.executor.traceSnapshotLifecycle(.revert, &pre_call);
                    trace_checkpoint_open = false;
                    try self.vm.executor.restore(&pre_call);
                    return error.GasAllowanceExceeded;
                };
                const env = self.vm.runtimeEnv();
                if (!next_block_gas.withinLimit(env.gas_limit)) {
                    self.vm.executor.traceSnapshotLifecycle(.revert, &pre_call);
                    trace_checkpoint_open = false;
                    try self.vm.executor.restore(&pre_call);
                    return error.GasAllowanceExceeded;
                }

                self.gas_used = next_gas_used;
                self.block_gas = next_block_gas;
                self.vm.executor.traceSnapshotLifecycle(.commit, &pre_call);
                trace_checkpoint_open = false;
                return result;
            }

            pub fn finish(self: *const BlockSession) BlockResult {
                return .{
                    .gas_used = self.gas_used,
                    .block_gas = self.block_gas,
                    .tx_count = self.tx_count,
                };
            }

            fn drop(self: *BlockSession, pre_tx: *Executor.Snapshot) !Self.TxResult {
                self.vm.executor.traceSnapshotLifecycle(.revert, pre_tx);
                try self.vm.executor.restore(pre_tx);
                return error.BlockGasExceeded;
            }
        };

        pub fn init(allocator: std.mem.Allocator, options: Init) Self {
            return .{
                .executor = Executor.init(allocator, .{
                    .revision = options.revision,
                    .state_reader = options.state_reader,
                    .block_hash_source = options.block_hash_source,
                    .config = options.config,
                    .trace_sink = options.trace_sink,
                }),
                .env = options.env,
                .committer = options.committer,
                .block_bound = null,
            };
        }

        /// Initialize a VM with a gas-derived, locked runtime-resource envelope.
        pub fn initBound(allocator: std.mem.Allocator, options: Init, bound: BlockBoundType) !Self {
            var result = try initWithRuntimeResourcesInternal(allocator, options, .{
                .bounded = try boundedRuntimeResources(options.revision, bound),
            });
            result.executor.lockRuntimeResources();
            result.block_bound = bound;
            return result;
        }

        /// Initialize a VM and reserve reusable execution resources up front.
        pub fn initWithRuntimeResources(allocator: std.mem.Allocator, options: Init, runtime_resources: executor_module.RuntimeResources) !Self {
            return initWithRuntimeResourcesInternal(allocator, options, runtime_resources);
        }

        fn initWithRuntimeResourcesInternal(allocator: std.mem.Allocator, options: Init, runtime_resources: executor_module.RuntimeResources) !Self {
            return .{
                .executor = try Executor.initWithRuntimeResources(allocator, .{
                    .revision = options.revision,
                    .state_reader = options.state_reader,
                    .block_hash_source = options.block_hash_source,
                    .config = options.config,
                    .trace_sink = options.trace_sink,
                }, runtime_resources),
                .env = options.env,
                .committer = options.committer,
                .block_bound = null,
            };
        }

        pub fn boundedRuntimeResources(revision: RevisionType, bound: BlockBoundType) !executor_module.BoundedRuntimeResources {
            if (bound.max_block_gas == 0) return error.InvalidBlockGasBound;
            const envelope = try tx_protocol.gas_bound.resourceEnvelope(.{
                .revision = revision,
                .block_gas_limit = bound.max_block_gas,
                .max_live_frames = bound.max_live_frames,
            });
            return executor_module.BoundedRuntimeResources.fromResourceEnvelope(envelope);
        }

        pub fn deinit(self: *Self) void {
            self.executor.deinit();
        }

        /// Rebind fixture/benchmark inputs while retaining executor capacity.
        pub fn reset(self: *Self, options: Init) !void {
            try self.executor.reset(.{
                .revision = options.revision,
                .state_reader = options.state_reader,
                .block_hash_source = options.block_hash_source,
                .config = options.config,
                .trace_sink = options.trace_sink,
            });
            self.env = options.env;
            self.committer = options.committer;
        }

        pub fn beginBlock(self: *Self, env: Env) !BlockSession {
            if (self.block_bound) |bound| {
                if (env.gas_limit == 0) return error.InvalidBlockGasLimit;
                if (env.gas_limit > bound.max_block_gas) return error.BlockGasLimitExceedsBound;
            }
            self.env = env;
            return .{ .vm = self };
        }

        pub fn envContext(self: *const Self) Env {
            return self.runtimeEnv();
        }

        pub fn getAccount(self: *Self, address_value: Address) !?AccountView {
            const account = try self.executor.getAccountOrLoad(address_value) orelse return null;
            const code = try self.executor.getCode(address_value);
            return .{
                .nonce = account.nonce,
                .balance = account.balance,
                .code = code,
            };
        }

        pub fn getStorage(self: *Self, address_value: Address, key: u256) !u256 {
            return self.executor.getStorage(address_value, key);
        }

        /// Credit an account balance through the VM overlay.
        ///
        /// Block-level callers use this for execution-derived writes such as
        /// withdrawal credits while keeping `BlockSession` limited to tx folding.
        pub fn creditBalance(self: *Self, address_value: Address, amount: u256) !void {
            if (amount == 0) return;
            const current_balance = try self.executor.state.getBalance(address_value);
            const next_balance = std.math.add(u256, current_balance, amount) catch return error.BalanceOverflow;
            try self.executor.state.setBalance(address_value, next_balance);
        }

        /// Borrow logs emitted by the most recent transaction/system-call scope.
        ///
        /// Receipt builders can copy these immediately after `transact`; the slice is
        /// invalidated by the next transaction, discard, commit, or VM teardown.
        pub fn logs(self: *const Self) []const Log {
            return self.executor.logs();
        }

        /// Execute an explicit non-transaction system call.
        pub fn systemCall(self: *Self, call: SystemCall) !EvmResult {
            try self.requireDirectExecution();
            return self.executeSystemCall(call);
        }

        fn executeSystemCall(self: *Self, call: SystemCall) !EvmResult {
            const env = self.runtimeEnv();
            if (env.gas_limit != 0 and call.gas > env.gas_limit) return error.GasAllowanceExceeded;
            const context_gas_limit = if (env.gas_limit == 0) call.gas else env.gas_limit;
            const result = try self.executor.executeSystemCall(
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

        /// Execute one protocol transaction into the VM overlay.
        pub fn transact(self: *Self, tx: Self.Transaction) !Self.TxResult {
            try self.requireDirectExecution();
            const prepared = try self.prepareTransaction(tx, .{});
            return switch (prepared) {
                .rejected => |err| .{ .rejected = err },
                .executable => |executable| .{ .executed = try self.executePreparedTransaction(executable) },
            };
        }

        fn prepareTransaction(self: *Self, tx: Self.Transaction, block: transaction.PreparationBlockProgress) !Self.PreparedTransactionResult {
            self.executor.clearLogs();
            const env = self.runtimeEnv();
            const input: transaction.PrepareInput(Protocol) = .{
                .revision = self.executor.revision(),
                .tx = tx,
                .env = envFacts(env),
                .block = block,
                .state = self.preparationStateAccess(),
            };
            return Protocol.Transaction.prepare(Protocol, input);
        }

        fn executePreparedTransaction(self: *Self, prepared: Self.PreparedTransaction) !TxExecutionResult {
            try self.executor.beginTransactionScope(prepared.scope, prepared.root);
            errdefer self.executor.closeTransaction();
            const result = try self.executor.runTopLevelTransaction(prepared.scope, prepared.root, .{
                .execution = prepared.execution_gas,
                .settlement = prepared.settlement,
            });

            const costs = try tx_protocol.settlement.planCosts(prepared.settlement, .{
                .gas_left = result.gas_left,
                .gas_refund = result.gas_refund,
                .gas_reservoir = result.gas_reservoir,
                .state_gas_spent = result.state_gas_spent,
            });
            return .{
                .status = txStatus(result.status),
                .gas = costs.gas,
                .output = result.output_data,
                .created_address = if (result.status == .success) prepared.created_address else null,
            };
        }

        /// Convenience for one-off callers. Block executors should usually call
        /// `transact` many times, then one `commit`.
        pub fn transactCommit(self: *Self, tx: Self.Transaction) !Self.TxResult {
            const result = try self.transact(tx);
            switch (result) {
                .rejected => return result,
                .executed => {},
            }
            try self.commit();
            return result;
        }

        fn requireDirectExecution(self: *const Self) !void {
            if (self.block_bound != null) return error.BlockSessionRequired;
        }

        fn preparationStateAccess(self: *Self) transaction.PreparationStateAccess {
            return .{
                .ptr = self,
                .vtable = &preparation_state_vtable,
            };
        }

        const preparation_state_vtable = transaction.PreparationStateAccess.VTable{
            .accountSummary = preparationAccountSummary,
            .code = preparationCode,
        };

        fn preparationAccountSummary(ptr: *anyopaque, account_address: Address) !?transaction.PreparationAccount {
            const self: *Self = @ptrCast(@alignCast(ptr));
            const account = try self.executor.getAccountOrLoad(account_address) orelse return null;
            return .{
                .nonce = account.nonce,
                .balance = account.balance,
                .code_hash = account.code_hash,
            };
        }

        fn preparationCode(ptr: *anyopaque, account_address: Address, expected_hash: [32]u8) ![]const u8 {
            const self: *Self = @ptrCast(@alignCast(ptr));
            const code = try self.executor.getCode(account_address);
            // Reader implementations own missing/malformed-state errors. The
            // expected hash came from the same metadata read, so a mismatch here
            // is a generic preparation contract error, not a witness diagnosis.
            if (!std.mem.eql(u8, &evmz.mpt.codeHash(code), &expected_hash)) {
                return error.CodeHashMismatch;
            }
            return code;
        }

        fn envFacts(env: Env) transaction.EnvFacts {
            return .{
                .chain_id = env.chain_id,
                .coinbase = env.coinbase,
                .number = env.number,
                .slot_number = env.slot_number,
                .timestamp = env.timestamp,
                .gas_limit = env.gas_limit,
                .prev_randao = env.prev_randao,
                .base_fee = env.base_fee,
                .blob_base_fee = env.blob_base_fee,
                .blob_schedule = env.blob_schedule,
            };
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
            const left = std.math.cast(u64, gas_left) orelse return 0;
            return gas -| @min(gas, left);
        }

        /// Return the current pending state diff without persisting it.
        pub fn changeset(self: *Self) !Changeset {
            return self.executor.changeset();
        }

        /// Drop pending overlay changes without writing them to the commit sink.
        pub fn discard(self: *Self) void {
            self.executor.discardChanges();
        }

        /// Persist the current overlay diff, then rebase the VM to the updated state reader.
        ///
        /// The committer is expected to write to the same canonical state observed by
        /// the reader. After a successful commit, the in-memory overlay is cleared so
        /// the same VM can process the next block.
        pub fn commit(self: *Self) !void {
            const committer = self.committer orelse return error.ReadOnly;
            var diff = try self.executor.changeset();
            defer diff.deinit(self.executor.allocator);
            try committer.commit(&diff);
            self.executor.discardChanges();
        }

        fn runtimeEnv(self: *const Self) Env {
            return self.env;
        }
    };
}

const Default = evmz.Evm;
const EthValidationError = evmz.Evm.Protocol.Transaction.ValidationError;

fn expectExecuted(result: Default.TxResult) !TxExecutionResult {
    return switch (result) {
        .executed => |executed| executed,
        .rejected => error.UnexpectedRejection,
    };
}

fn expectRejected(result: Default.TxResult) !EthValidationError {
    return switch (result) {
        .executed => error.UnexpectedExecution,
        .rejected => |err| err,
    };
}

test "Vm exposes protocol verbs and low-level executor field" {
    try std.testing.expect(@hasDecl(Default, "transact"));
    try std.testing.expect(@hasDecl(Default, "beginBlock"));
    try std.testing.expect(@hasDecl(Default.BlockSession, "receipt"));
    try std.testing.expect(@hasDecl(Default, "systemCall"));
    try std.testing.expect(@hasDecl(Default, "logs"));
    try std.testing.expect(@hasDecl(Default, "commit"));
    try std.testing.expect(@hasField(Default, "executor"));
}

test "Vm initializes and exposes empty changeset" {
    var vm = Default.init(std.testing.allocator, .{
        .revision = .osaka,
        .env = .{ .chain_id = 1 },
    });
    defer vm.deinit();

    var diff = try vm.changeset();
    defer diff.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), diff.account_updates.items.len);
}

test "Vm executor runs low-level standalone call" {
    const sender = addr(0xaaaa);
    const contract = addr(0xbbbb);
    var memory = MemoryStore.init(std.testing.allocator);
    defer memory.deinit();

    var sender_account = try memory.getOrCreateAccount(sender);
    sender_account.balance = 10_000_000;
    var contract_account = try memory.getOrCreateAccount(contract);
    try contract_account.setCode(&.{ 0x60, 0x2a, 0x5f, 0x55, 0x00 });

    var vm = Default.init(std.testing.allocator, .{
        .revision = .osaka,
        .state_reader = memory.reader(),
    });
    defer vm.deinit();

    const call = Call{
        .sender = sender,
        .recipient = contract,
        .gas = 100_000,
    };
    const context_gas_limit = if (vm.env.gas_limit == 0) call.gas else vm.env.gas_limit;
    const result = (try vm.executor.runStandalone(
        vm.env.txContext(call.sender, 0, context_gas_limit, &.{}),
        .{ .call = call },
    )).expectCall();
    try std.testing.expectEqual(interpreter_module.Status.success, result.status);

    var diff = try vm.changeset();
    defer diff.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), diff.storage_writes.items.len);
    try std.testing.expectEqual(contract, diff.storage_writes.items[0].address);
    try std.testing.expectEqual(@as(u256, 0), diff.storage_writes.items[0].key);
    try std.testing.expectEqual(@as(u256, 0x2a), diff.storage_writes.items[0].value);
}

test "Vm executor runs low-level standalone create" {
    const sender = addr(0xaaaa);
    const create_address = address.create(sender, 0);
    var memory = MemoryStore.init(std.testing.allocator);
    defer memory.deinit();

    var sender_account = try memory.getOrCreateAccount(sender);
    sender_account.balance = 10_000_000;

    var vm = Default.init(std.testing.allocator, .{
        .revision = .berlin,
        .state_reader = memory.reader(),
    });
    defer vm.deinit();

    const init_code = &.{ 0x60, 0x00, 0x60, 0x00, 0x53, 0x60, 0x01, 0x60, 0x00, 0xf3 };
    const create = Create{
        .sender = sender,
        .init_code = init_code,
        .gas = 100_000,
    };
    const context_gas_limit = if (vm.env.gas_limit == 0) create.gas else vm.env.gas_limit;
    const result = (try vm.executor.runStandalone(
        vm.env.txContext(create.sender, 0, context_gas_limit, &.{}),
        .{ .create = create },
    )).expectCreate();
    try std.testing.expectEqual(interpreter_module.Status.success, result.status);
    try std.testing.expectEqualSlices(u8, &create_address, &result.address);

    var diff = try vm.changeset();
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

test "Vm transact validates and executes call transaction" {
    const sender = addr(0xaaaa);
    const contract = addr(0xbbbb);
    var memory = MemoryStore.init(std.testing.allocator);
    defer memory.deinit();

    var sender_account = try memory.getOrCreateAccount(sender);
    sender_account.balance = 1_000_000;
    var contract_account = try memory.getOrCreateAccount(contract);
    try contract_account.setCode(&.{ 0x60, 0x2a, 0x5f, 0x55, 0x00 });

    var vm = Default.init(std.testing.allocator, .{
        .revision = .osaka,
        .state_reader = memory.reader(),
        .env = .{ .gas_limit = 1_000_000 },
    });
    defer vm.deinit();

    const result = try expectExecuted(try vm.transact(.{
        .sender = sender,
        .to = contract,
        .gas_limit = 300_000,
    }));
    try std.testing.expectEqual(TxStatus.success, result.status);
    try std.testing.expect(result.gas.used > 21_000);
    try std.testing.expectEqual(result.gas.used, result.gas.block.total);

    var diff = try vm.changeset();
    defer diff.deinit(std.testing.allocator);
    diff.sort();
    try std.testing.expectEqual(@as(usize, 1), diff.account_updates.items.len);
    try std.testing.expectEqual(sender, diff.account_updates.items[0].address);
    try std.testing.expectEqual(@as(u64, 1), diff.account_updates.items[0].nonce);
    try std.testing.expectEqual(@as(usize, 1), diff.storage_writes.items.len);
    try std.testing.expectEqual(contract, diff.storage_writes.items[0].address);
    try std.testing.expectEqual(@as(u256, 0x2a), diff.storage_writes.items[0].value);
}

test "Vm transact forwards BLOCKHASH to configured block hash source" {
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
    var vm = Default.init(std.testing.allocator, .{
        .revision = .prague,
        .state_reader = memory.reader(),
        .block_hash_source = block_hashes.source(),
        .env = .{ .number = 1000, .gas_limit = 1_000_000 },
    });
    defer vm.deinit();

    const result = try expectExecuted(try vm.transact(.{
        .sender = sender,
        .to = contract,
        .gas_limit = 300_000,
    }));
    try std.testing.expectEqual(TxStatus.success, result.status);
    try std.testing.expectEqual(@as(?u64, 999), block_hashes.last_number);

    var diff = try vm.changeset();
    defer diff.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), diff.storage_writes.items.len);
    try std.testing.expectEqual(contract, diff.storage_writes.items[0].address);
    try std.testing.expectEqual(@as(u256, 0xab), diff.storage_writes.items[0].value);
}

test "Vm transact reports successful create address" {
    const sender = addr(0xaaaa);
    const create_address = address.create(sender, 0);
    var memory = MemoryStore.init(std.testing.allocator);
    defer memory.deinit();

    var sender_account = try memory.getOrCreateAccount(sender);
    sender_account.balance = 1_000_000;

    var vm = Default.init(std.testing.allocator, .{
        .revision = .berlin,
        .state_reader = memory.reader(),
        .env = .{ .gas_limit = 1_000_000 },
    });
    defer vm.deinit();

    const init_code = &.{ 0x60, 0x00, 0x60, 0x00, 0x53, 0x60, 0x01, 0x60, 0x00, 0xf3 };
    const result = try expectExecuted(try vm.transact(.{
        .sender = sender,
        .gas_limit = 300_000,
        .input = init_code,
    }));
    try std.testing.expectEqual(TxStatus.success, result.status);
    try std.testing.expectEqualSlices(u8, &create_address, &result.created_address.?);

    var diff = try vm.changeset();
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

test "Vm transact returns rejected validation result" {
    const sender = addr(0xaaaa);
    var memory = MemoryStore.init(std.testing.allocator);
    defer memory.deinit();

    var sender_account = try memory.getOrCreateAccount(sender);
    sender_account.balance = 10_000_000;
    sender_account.nonce = 7;

    var vm = Default.init(std.testing.allocator, .{
        .revision = .osaka,
        .state_reader = memory.reader(),
        .env = .{ .gas_limit = 1_000_000 },
    });
    defer vm.deinit();

    const result = try vm.transact(.{
        .sender = sender,
        .nonce = 1,
        .to = addr(0xbbbb),
        .gas_limit = 300_000,
    });
    try std.testing.expectEqual(EthValidationError.nonce_mismatch, try expectRejected(result));

    var diff = try vm.changeset();
    defer diff.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), diff.account_updates.items.len);
    try std.testing.expectEqual(@as(usize, 0), diff.storage_writes.items.len);
}

test "Vm rejected transaction preserves pending overlay" {
    const sender = addr(0xaaaa);
    const contract = addr(0xbbbb);
    var memory = MemoryStore.init(std.testing.allocator);
    defer memory.deinit();

    var sender_account = try memory.getOrCreateAccount(sender);
    sender_account.balance = 1_000_000;
    var contract_account = try memory.getOrCreateAccount(contract);
    try contract_account.setCode(&.{ 0x60, 0x2a, 0x5f, 0x55, 0x00 });

    var vm = Default.init(std.testing.allocator, .{
        .revision = .osaka,
        .state_reader = memory.reader(),
        .env = .{ .gas_limit = 1_000_000 },
    });
    defer vm.deinit();

    _ = try vm.transact(.{
        .sender = sender,
        .to = contract,
        .gas_limit = 300_000,
    });
    const rejected = try vm.transact(.{
        .sender = sender,
        .nonce = 99,
        .to = contract,
        .gas_limit = 100_000,
    });
    try std.testing.expectEqual(EthValidationError.nonce_mismatch, try expectRejected(rejected));

    var diff = try vm.changeset();
    defer diff.deinit(std.testing.allocator);
    diff.sort();
    try std.testing.expectEqual(@as(usize, 1), diff.storage_writes.items.len);
    try std.testing.expectEqual(contract, diff.storage_writes.items[0].address);
    try std.testing.expectEqual(@as(u256, 0x2a), diff.storage_writes.items[0].value);
}

test "Vm commit applies changeset and rebases overlay" {
    const sender = addr(0xaaaa);
    const contract = addr(0xbbbb);
    var memory = MemoryStore.init(std.testing.allocator);
    defer memory.deinit();

    var sender_account = try memory.getOrCreateAccount(sender);
    sender_account.balance = 10_000_000;
    var contract_account = try memory.getOrCreateAccount(contract);
    try contract_account.setCode(&.{ 0x60, 0x2a, 0x5f, 0x55, 0x00 });

    var vm = Default.init(std.testing.allocator, .{
        .revision = .osaka,
        .state_reader = memory.reader(),
        .committer = memory.committer(),
        .env = .{ .gas_limit = 1_000_000 },
    });
    defer vm.deinit();

    _ = try vm.transact(.{
        .sender = sender,
        .to = contract,
        .gas_limit = 300_000,
    });
    try vm.commit();

    var diff = try vm.changeset();
    defer diff.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), diff.account_updates.items.len);
    try std.testing.expectEqual(@as(usize, 0), diff.storage_writes.items.len);
    try std.testing.expectEqual(@as(u256, 0x2a), memory.getAccount(contract).?.getStorage(0));
}

test "Vm discard drops pending overlay without touching state reader" {
    const sender = addr(0xaaaa);
    const contract = addr(0xbbbb);
    var memory = MemoryStore.init(std.testing.allocator);
    defer memory.deinit();

    var sender_account = try memory.getOrCreateAccount(sender);
    sender_account.balance = 1_000_000;
    var contract_account = try memory.getOrCreateAccount(contract);
    try contract_account.setCode(&.{ 0x60, 0x2a, 0x5f, 0x55, 0x00 });

    var vm = Default.init(std.testing.allocator, .{
        .revision = .osaka,
        .state_reader = memory.reader(),
        .env = .{ .gas_limit = 1_000_000 },
    });
    defer vm.deinit();

    _ = try vm.transact(.{
        .sender = sender,
        .to = contract,
        .gas_limit = 300_000,
    });
    vm.discard();

    var diff = try vm.changeset();
    defer diff.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), diff.account_updates.items.len);
    try std.testing.expectEqual(@as(usize, 0), diff.storage_writes.items.len);
    try std.testing.expectEqual(@as(u256, 0), memory.getAccount(contract).?.getStorage(0));
}

test "Vm read-only commit leaves pending overlay intact" {
    const sender = addr(0xaaaa);
    const contract = addr(0xbbbb);
    var memory = MemoryStore.init(std.testing.allocator);
    defer memory.deinit();

    var sender_account = try memory.getOrCreateAccount(sender);
    sender_account.balance = 10_000_000;
    var contract_account = try memory.getOrCreateAccount(contract);
    try contract_account.setCode(&.{ 0x60, 0x2a, 0x5f, 0x55, 0x00 });

    var vm = Default.init(std.testing.allocator, .{
        .revision = .osaka,
        .state_reader = memory.reader(),
        .env = .{ .gas_limit = 1_000_000 },
    });
    defer vm.deinit();

    _ = try vm.transact(.{
        .sender = sender,
        .to = contract,
        .gas_limit = 300_000,
    });
    try std.testing.expectError(error.ReadOnly, vm.commit());

    var diff = try vm.changeset();
    defer diff.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), diff.storage_writes.items.len);
    try std.testing.expectEqual(@as(u256, 0), memory.getAccount(contract).?.getStorage(0));
}

test "Vm transactCommit skips commit for rejected transaction" {
    const sender = addr(0xaaaa);
    const contract = addr(0xbbbb);
    var memory = MemoryStore.init(std.testing.allocator);
    defer memory.deinit();

    var sender_account = try memory.getOrCreateAccount(sender);
    sender_account.balance = 1_000_000;
    var contract_account = try memory.getOrCreateAccount(contract);
    try contract_account.setCode(&.{ 0x60, 0x2a, 0x5f, 0x55, 0x00 });

    var vm = Default.init(std.testing.allocator, .{
        .revision = .osaka,
        .state_reader = memory.reader(),
        .committer = memory.committer(),
        .env = .{ .gas_limit = 1_000_000 },
    });
    defer vm.deinit();

    _ = try vm.transact(.{
        .sender = sender,
        .to = contract,
        .gas_limit = 100_000,
    });
    const rejected = try vm.transactCommit(.{
        .sender = sender,
        .nonce = 99,
        .to = contract,
        .gas_limit = 100_000,
    });
    try std.testing.expectEqual(EthValidationError.nonce_mismatch, try expectRejected(rejected));
    try std.testing.expectEqual(@as(u256, 0), memory.getAccount(contract).?.getStorage(0));

    var diff = try vm.changeset();
    defer diff.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), diff.storage_writes.items.len);
}

test "Vm Amsterdam transaction reports gross block gas separately from receipt gas" {
    const sender = addr(0xaaaa);
    const contract = addr(0xbbbb);
    var memory = MemoryStore.init(std.testing.allocator);
    defer memory.deinit();

    var sender_account = try memory.getOrCreateAccount(sender);
    sender_account.balance = 1_000_000;
    var contract_account = try memory.getOrCreateAccount(contract);
    try contract_account.storage.put(0, 1);
    try contract_account.setCode(&.{ 0x5f, 0x5f, 0x55, 0x00 });

    var vm = Default.init(std.testing.allocator, .{
        .revision = .amsterdam,
        .state_reader = memory.reader(),
        .env = .{ .gas_limit = 1_000_000 },
    });
    defer vm.deinit();

    const result = try expectExecuted(try vm.transact(.{
        .sender = sender,
        .to = contract,
        .gas_limit = 100_000,
    }));
    try std.testing.expectEqual(TxStatus.success, result.status);
    try std.testing.expect(result.gas.refunded > 0);
    try std.testing.expect(result.gas.block.total > result.gas.used);
}

test "Vm exposes borrowed logs for client receipt builders" {
    const sender = addr(0xaaaa);
    const recipient = addr(0xbbbb);
    var memory = MemoryStore.init(std.testing.allocator);
    defer memory.deinit();

    var sender_account = try memory.getOrCreateAccount(sender);
    sender_account.balance = 10_000_000;

    var vm = Default.init(std.testing.allocator, .{
        .revision = .amsterdam,
        .state_reader = memory.reader(),
        .env = .{ .gas_limit = 1_000_000 },
    });
    defer vm.deinit();

    const result = try expectExecuted(try vm.transact(.{
        .sender = sender,
        .to = recipient,
        .gas_limit = 300_000,
        .value = 7,
    }));
    try std.testing.expectEqual(TxStatus.success, result.status);
    try std.testing.expectEqual(@as(usize, 1), vm.logs().len);
    try std.testing.expectEqualSlices(u8, &evmz.eth.system_address, &vm.logs()[0].address);
    try std.testing.expectEqual(evmz.eth.value_transfer_log_topic, vm.logs()[0].topics[0]);
}

test "Vm rejected transaction clears borrowed log surface" {
    const sender = addr(0xaaaa);
    const recipient = addr(0xbbbb);
    var memory = MemoryStore.init(std.testing.allocator);
    defer memory.deinit();

    var sender_account = try memory.getOrCreateAccount(sender);
    sender_account.balance = 10_000_000;

    var vm = Default.init(std.testing.allocator, .{
        .revision = .amsterdam,
        .state_reader = memory.reader(),
        .env = .{ .gas_limit = 1_000_000 },
    });
    defer vm.deinit();

    const accepted = try expectExecuted(try vm.transact(.{
        .sender = sender,
        .to = recipient,
        .gas_limit = 300_000,
        .value = 7,
    }));
    try std.testing.expectEqual(TxStatus.success, accepted.status);
    try std.testing.expectEqual(@as(usize, 1), vm.logs().len);

    const rejected = try vm.transact(.{
        .sender = sender,
        .nonce = 99,
        .to = recipient,
        .gas_limit = 300_000,
        .value = 7,
    });
    try std.testing.expectEqual(EthValidationError.nonce_mismatch, try expectRejected(rejected));
    try std.testing.expectEqual(@as(usize, 0), vm.logs().len);
}

test "Vm preparation uses comptime transaction gas policy" {
    const sender = addr(0xaaaa);
    const recipient = addr(0xbbbb);
    var memory = MemoryStore.init(std.testing.allocator);
    defer memory.deinit();

    var sender_account = try memory.getOrCreateAccount(sender);
    sender_account.balance = 10_000_000;

    var vm = Default.init(std.testing.allocator, .{
        .revision = .london,
        .state_reader = memory.reader(),
        .env = .{ .gas_limit = 1_000_000 },
    });
    defer vm.deinit();

    const tx = Default.Transaction{
        .sender = sender,
        .to = recipient,
        .gas_limit = 21_000,
    };

    const default_prepared = try vm.prepareTransaction(tx, .{});
    switch (default_prepared) {
        .executable => {},
        .rejected => return error.UnexpectedRejection,
    }

    const HighIntrinsicProtocol = struct {
        pub const Revision = evmz.eth.Revision;

        pub const Transaction = struct {
            pub const Value = transaction.Transaction;
            pub const View = transaction.TransactionView;
            pub const ValidationError = EthValidationError;

            pub fn view(value: Value) View {
                return transaction.transactionView(value);
            }

            pub fn prepare(comptime ProtocolType: type, input: transaction.PrepareInput(ProtocolType)) !transaction.PrepareResult(ProtocolType) {
                return evmz.eth.transaction_prepare.For(ProtocolType).prepare(input);
            }

            pub fn kindActive(revision: Revision, kind: transaction.TxKind) bool {
                _ = revision;
                _ = kind;
                return true;
            }

            pub fn allowsContractCreation(revision: Revision, kind: transaction.TxKind) bool {
                _ = revision;
                _ = kind;
                return true;
            }

            pub fn requiresAuthorizationList(revision: Revision, kind: transaction.TxKind) bool {
                _ = revision;
                _ = kind;
                return false;
            }

            pub fn rejectsNonDelegatingSenderCode(revision: Revision, kind: transaction.TxKind) bool {
                _ = revision;
                _ = kind;
                return false;
            }

            pub fn blobSchedule(revision: Revision) ?transaction.BlobSchedule {
                _ = revision;
                return null;
            }

            pub fn blobVersionedHashActive(revision: Revision, version: u8) bool {
                _ = revision;
                _ = version;
                return false;
            }

            pub fn maxInitcodeSize(revision: Revision) usize {
                _ = revision;
                return std.math.maxInt(usize);
            }

            pub fn intrinsicBaseGas(revision: Revision, options: transaction.IntrinsicGasOptions) ?u64 {
                _ = revision;
                _ = options;
                return 42_000;
            }

            pub fn createIntrinsicGas(revision: Revision) ?u64 {
                _ = revision;
                return 0;
            }

            pub fn dataByteGas(revision: Revision, byte: u8) u64 {
                _ = revision;
                _ = byte;
                return 0;
            }

            pub fn accessListAddressGas(revision: Revision) u64 {
                _ = revision;
                return 0;
            }

            pub fn storageKeyGas(revision: Revision) u64 {
                _ = revision;
                return 0;
            }

            pub fn accessListDataGas(revision: Revision, counts: transaction.AccessListCounts) ?u64 {
                _ = revision;
                _ = counts;
                return 0;
            }

            pub fn initCodeWordGas(revision: Revision) u64 {
                _ = revision;
                return 0;
            }

            pub fn authorizationIntrinsicGas(revision: Revision) u64 {
                _ = revision;
                return 0;
            }

            pub fn intrinsicStateGas(revision: Revision, options: transaction.IntrinsicGasOptions) ?u64 {
                _ = revision;
                _ = options;
                return 0;
            }

            pub fn floorGas(revision: Revision, input: []const u8, options: transaction.IntrinsicGasOptions) ?u64 {
                _ = revision;
                _ = input;
                _ = options;
                return null;
            }

            pub fn regularGasLimit(revision: Revision, gas_limit: u64) u64 {
                _ = revision;
                return gas_limit;
            }

            pub fn intrinsicRegularGasLimit(revision: Revision) ?u64 {
                _ = revision;
                return null;
            }

            pub fn totalGasLimit(revision: Revision) ?u64 {
                _ = revision;
                return null;
            }
        };

        pub const Settlement = struct {
            pub const Plan = transaction.Settlement;

            pub fn baseFeeActive(revision: Revision) bool {
                _ = revision;
                return true;
            }

            pub fn gasRefundCapDivisor(revision: Revision) u64 {
                _ = revision;
                return 5;
            }

            pub fn usesStateGasAccounting(revision: Revision) bool {
                _ = revision;
                return false;
            }
        };
    };

    const HighIntrinsicVm = ResolvedVm(HighIntrinsicProtocol);
    var custom_vm = HighIntrinsicVm.init(std.testing.allocator, .{
        .revision = .london,
        .state_reader = memory.reader(),
        .env = .{ .gas_limit = 1_000_000 },
    });
    defer custom_vm.deinit();

    const custom_prepared = try custom_vm.prepareTransaction(tx, .{});
    switch (custom_prepared) {
        .executable => try std.testing.expect(false),
        .rejected => |err| try std.testing.expectEqual(EthValidationError.intrinsic_gas_too_low, err),
    }
}

test "Vm preparation accepts custom transaction value" {
    const sender = addr(0xaaaa);
    const recipient = addr(0xbbbb);

    const CustomProtocol = struct {
        pub const Revision = enum { custom };

        pub const Transaction = struct {
            pub const Value = struct {
                from: Address,
                target: Address,
                amount: u256 = 0,
                gas: u64,
            };
            pub const View = transaction.TransactionView;
            pub const ValidationError = enum { rejected };

            pub fn view(value: Value) View {
                return .{
                    .sender = value.from,
                    .to = value.target,
                    .gas_limit = value.gas,
                    .value = value.amount,
                };
            }

            pub fn prepare(comptime ProtocolType: type, input: transaction.PrepareInput(ProtocolType)) !transaction.PrepareResult(ProtocolType) {
                const tx_view = ProtocolType.Transaction.view(input.tx);
                return .{ .executable = .{
                    .created_address = null,
                    .scope = .{
                        .context = .init(input.env, tx_view.sender, 7, input.env.gas_limit, &.{}),
                    },
                    .root = .init(.{
                        .sender = tx_view.sender,
                        .to = tx_view.to,
                        .gas_limit = tx_view.gas_limit,
                        .value = tx_view.value,
                    }),
                    .execution_gas = transaction.ExecutionGas.legacy(12_345),
                    .settlement = .{
                        .revision = input.revision,
                        .marker = 9,
                    },
                } };
            }
        };

        pub const Settlement = struct {
            pub const Plan = struct {
                revision: Revision,
                marker: u8,
            };

            pub fn costs(comptime ProtocolType: type, plan: Plan, result: transaction.ExecutionGasResult) !transaction.SettlementCosts {
                _ = ProtocolType;
                _ = plan;
                _ = result;
                return .{
                    .gas = .{},
                    .sender_refund = 0,
                    .coinbase_payment = 0,
                };
            }
        };
    };

    const CustomVm = ResolvedVm(CustomProtocol);
    var vm = CustomVm.init(std.testing.allocator, .{
        .revision = .custom,
        .env = .{ .gas_limit = 99_000 },
    });
    defer vm.deinit();

    const prepared = try vm.prepareTransaction(.{
        .from = sender,
        .target = recipient,
        .amount = 5,
        .gas = 50_000,
    }, .{});

    const executable = switch (prepared) {
        .rejected => return error.UnexpectedRejection,
        .executable => |value| value,
    };

    try std.testing.expectEqual(@as(u256, 7), executable.scope.context.gas_price);
    try std.testing.expectEqual(@as(u64, 12_345), executable.execution_gas.?.regular_left);
    try std.testing.expectEqual(@as(u8, 9), executable.settlement.marker);
    try std.testing.expectEqual(@as(u64, 50_000), executable.root.gasLimit());
    try std.testing.expectEqual(@as(u256, 5), executable.root.value());
}

test "BlockSession validation rejection skips rollback snapshot" {
    const sender = addr(0xaaaa);
    const recipient = addr(0xbbbb);
    var memory = MemoryStore.init(std.testing.allocator);
    defer memory.deinit();

    var sender_account = try memory.getOrCreateAccount(sender);
    sender_account.balance = 10_000_000;

    var failing_allocator = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var vm = Default.init(failing_allocator.allocator(), .{
        .revision = .amsterdam,
        .state_reader = memory.reader(),
    });
    defer vm.deinit();

    try std.testing.expect((try vm.getAccount(sender)) != null);
    failing_allocator.fail_index = failing_allocator.alloc_index;

    var block = try vm.beginBlock(.{ .gas_limit = 1_000_000 });
    const rejected = try block.transact(.{
        .sender = sender,
        .nonce = 99,
        .to = recipient,
        .gas_limit = 300_000,
    });
    try std.testing.expectEqual(EthValidationError.nonce_mismatch, try expectRejected(rejected));
    try std.testing.expect(!failing_allocator.has_induced_failure);
    try std.testing.expectEqual(@as(u64, 0), block.finish().tx_count);
}

test "Vm systemCall uses bound executor protocol" {
    var vm = Default.init(std.testing.allocator, .{
        .revision = .prague,
    });
    defer vm.deinit();

    const result = try vm.systemCall(.{
        .sender = addr(0xaaaa),
        .recipient = addr(0xbbbb),
        .gas = 50_000,
    });

    try std.testing.expectEqual(interpreter_module.Status.success, result.status());
    try std.testing.expectEqualSlices(u8, &.{}, result.outputData());
}

test "BlockSession rejects transaction whose gas limit exceeds remaining block dimensions" {
    const sender = addr(0xaaaa);
    const recipient = addr(0xbbbb);
    var memory = MemoryStore.init(std.testing.allocator);
    defer memory.deinit();

    var sender_account = try memory.getOrCreateAccount(sender);
    sender_account.balance = 10_000_000;

    var vm = Default.init(std.testing.allocator, .{
        .revision = .amsterdam,
        .state_reader = memory.reader(),
    });
    defer vm.deinit();

    var block = try vm.beginBlock(.{ .gas_limit = 29_000 });
    const accepted = try expectExecuted(try block.transact(.{
        .sender = sender,
        .to = recipient,
        .gas_limit = 29_000,
    }));
    try std.testing.expectEqual(TxStatus.success, accepted.status);
    try std.testing.expectEqual(@as(u64, 15_000), accepted.gas.block.total);
    try std.testing.expectEqual(@as(u64, 1), block.finish().tx_count);

    const rejected = try block.transact(.{
        .sender = sender,
        .to = recipient,
        .gas_limit = 29_000,
    });
    try std.testing.expectEqual(EthValidationError.gas_allowance_exceeded, try expectRejected(rejected));
    try std.testing.expectEqual(@as(u64, 1), block.finish().tx_count);

    var diff = try vm.changeset();
    defer diff.deinit(std.testing.allocator);
    diff.sort();
    try std.testing.expectEqual(@as(usize, 1), diff.account_updates.items.len);
    try std.testing.expectEqual(@as(u64, 1), diff.account_updates.items[0].nonce);
    try std.testing.expectEqual(@as(usize, 0), diff.storage_writes.items.len);
}

test "BlockSession builds borrowed receipt view with cumulative gas and logs" {
    const sender = addr(0xaaaa);
    const recipient = addr(0xbbbb);
    var memory = MemoryStore.init(std.testing.allocator);
    defer memory.deinit();

    var sender_account = try memory.getOrCreateAccount(sender);
    sender_account.balance = 10_000_000;

    var vm = Default.init(std.testing.allocator, .{
        .revision = .amsterdam,
        .state_reader = memory.reader(),
    });
    defer vm.deinit();

    var block = try vm.beginBlock(.{ .gas_limit = 1_000_000 });
    const result = try expectExecuted(try block.transact(.{
        .sender = sender,
        .to = recipient,
        .gas_limit = 300_000,
        .value = 7,
    }));
    const receipt = block.receipt(result);

    try std.testing.expectEqual(TxStatus.success, receipt.status);
    try std.testing.expectEqual(result.gas.used, receipt.gas_used);
    try std.testing.expectEqual(result.gas.used, receipt.cumulative_gas_used);
    try std.testing.expectEqual(@as(usize, 1), receipt.logs.len);
    try std.testing.expectEqual(evmz.eth.value_transfer_log_topic, receipt.logs[0].topics[0]);
}
