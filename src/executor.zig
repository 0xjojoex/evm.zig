//! Low-level EVM execution engine.
//!
//! `Executor` owns tracked transaction state, transaction context, frame pools,
//! and output buffers used while running EVM code. Higher-level APIs such as
//! `Vm` handle validation and user-facing transaction shapes; this type is the
//! execution substrate underneath them.
//!
//! The public methods fall into two lifecycle layers:
//!
//! 1. `runStandalone` is the convenience path for raw call/create messages. It
//!    opens a transaction scope, checkpoints state, executes, then commits or
//!    rolls back from the result status.
//! 2. `beginMessageScope` + `beginTransactionAttempt` is the engine transaction
//!    program boundary used by `Vm.transact`: the family program owns charging,
//!    nonce/access/authorization effects, execution rollback, and settlement.
//! `beginTransaction` / `beginCreateTransaction` + `executeCall` /
//! `executeCreate` are lower-level building blocks for tests, fixtures,
//! benchmarks, and code that needs to drive a partially-managed scope.
//!
//! `executor/call_runtime.zig` owns call/create frame execution and bytecode
//! frame setup. `executor/host_callbacks.zig` owns the `Host` vtable adapter.

const std = @import("std");

const evmz = @import("./evm.zig");
pub const errors = @import("./executor/error.zig");
const Address = evmz.Address;
const AccountState = evmz.state.Account;
const MemoryAccount = evmz.state.MemoryAccount;
const BlockHashSource = evmz.BlockHashSource;
const Bytecode = evmz.Bytecode;
const ExactSpec = @import("./spec.zig").Spec;
const prepared_code = evmz.prepared_code;
const execution_values = @import("./execution.zig");
const Host = evmz.Host;
const Interpreter = evmz.interpreter;
const TrackedState = evmz.state.TrackedState;
const DefaultSpec = evmz.Evm.specification;
pub const EvmResult = Host.Result;
const EvmResultType = EvmResult;

/// Root execution reports whether the VM reached payload execution so the
/// transaction program can place its preparation checkpoint without
/// duplicating CALL/CREATE dispatch semantics.
pub const TransactionExecutionStage = enum {
    preparation,
    payload,
};

pub const TransactionExecutionOutcome = struct {
    stage: TransactionExecutionStage,
    result: Interpreter.Result,
};

const TransactionExecutionOutcomeType = TransactionExecutionOutcome;
const call_runtime = @import("./executor/call_runtime.zig");
pub const capture_context = @import("./executor/capture_context.zig");
const call_scratch_storage = @import("./executor/call_scratch.zig");
const context_adapter = @import("./executor/context.zig");
pub const eip7702 = @import("./executor/eip7702.zig");
const FrameStore = @import("./executor/frame_store.zig");
const host_callbacks = @import("./executor/host_callbacks.zig");
const runtime_frame_defs = @import("./executor/runtime_frames.zig");
pub const state_io = @import("./executor/state_io.zig");
pub const system_contracts = @import("./executor/system_contracts.zig");
pub const transfer_logs = @import("./executor/transfer_logs.zig");
const frame_io = @import("./frame_io.zig");
const trace = @import("./trace.zig");
const uint256 = @import("./uint256.zig");

const CallScratchSlots = std.ArrayList(*call_scratch_storage.Slot);
const RuntimeFrameStack = std.ArrayList(runtime_frame_defs.Frame);

const IgnorePending = struct {
    pub fn observe(_: IgnorePending, _: TrackedState.PendingView) !void {}
};

const ScopeRoot = struct {
    sender: Address,
    recipient: ?Address,

    fn fromMessage(message: execution_values.Message) ScopeRoot {
        return switch (message) {
            .call => |call| .{ .sender = call.sender, .recipient = call.recipient },
            .create => |create| .{ .sender = create.sender, .recipient = null },
        };
    }

    fn eql(a: ScopeRoot, b: ScopeRoot) bool {
        if (!std.mem.eql(u8, &a.sender, &b.sender)) return false;
        if ((a.recipient == null) != (b.recipient == null)) return false;
        if (a.recipient) |recipient| return std.mem.eql(u8, &recipient, &b.recipient.?);
        return true;
    }
};

pub const code_deposit_gas: i64 = 200;

/// Construction options for the execution substrate.
///
/// `state_reader` is optional so tests and ephemeral executors can run purely
/// from the in-memory overlay. `block_hash_source` is separate because native
/// BLOCKHASH reads chain history, not account/trie state. Capture is selected
/// by an explicit transaction entrypoint, not construction.
const InitOptions = struct {
    state_reader: ?evmz.state.Reader = null,
    /// Caller-owned derived-artifact service. Its allocation, I/O,
    /// synchronization, and capacity policy are outside executor bounds.
    prepared_code_backend: ?prepared_code.Backend = null,
    block_hash_source: ?BlockHashSource = null,
    precompile_runtime: ?execution_values.PrecompileRuntime = null,
    config: evmz.ExecutionConfig = .base,
};

/// A top-level call whose bytecode has already been prepared by the caller.
///
/// This is the narrowest call entrypoint. Use it when a benchmark/test wants to
/// control bytecode preprocessing explicitly; otherwise prefer `executeCall` or
/// `runStandalone`.
pub const PreparedCallTransaction = struct {
    bytecode: *const Bytecode,
    sender: Address,
    recipient: Address,
    input: []const u8 = &.{},
    gas: u64,
    gas_reservoir: u64 = 0,
    value: u256 = 0,
};

pub const Call = execution_values.Call;
pub const Create = execution_values.Create;
pub const Message = execution_values.Message;
pub const default_max_live_frames: usize = @as(usize, Host.max_call_depth) + 1;

const PreparedCallTransactionType = PreparedCallTransaction;
const CallType = Call;
const CreateType = Create;
const MessageType = Message;
const code_deposit_gas_value = code_deposit_gas;
const default_max_live_frames_value = default_max_live_frames;
const ErrorType = errors.Error;
pub const CaptureContext = capture_context.Context;

/// The execution engine bound to one exact execution specification.
///
/// Returns the `Executor` struct type described in the module doc above: it
/// carries the fork-specific message/result aliases and call/create lifecycle
/// methods. A `Vm` closes it over one complete spec at comptime.
pub fn Executor(comptime spec: ExactSpec) type {
    return struct {
        const Self = @This();
        const runtime = call_runtime.bind(Self);
        const callbacks = host_callbacks.bind(Self);

        pub const specification = spec;
        pub const State = TrackedState;
        pub const ScopeCheckpoint = TrackedState.Checkpoint;
        pub const BranchCheckpoint = TrackedState.BranchCheckpoint;
        pub const Error = ErrorType;
        pub const Init = InitOptions;
        pub const PreparedCallTransaction = PreparedCallTransactionType;
        pub const Call = CallType;
        pub const Create = CreateType;
        pub const Message = MessageType;
        pub const EvmResult = EvmResultType;
        pub const TransactionExecutionOutcome = TransactionExecutionOutcomeType;
        pub const code_deposit_gas = code_deposit_gas_value;
        pub const default_max_live_frames = default_max_live_frames_value;

        allocator: std.mem.Allocator,
        state: TrackedState,
        frame_store: FrameStore,
        runtime_frames: RuntimeFrameStack,
        call_scratch_slots: CallScratchSlots,
        prepared_code_scratch: call_scratch_storage.Slot,
        execution_context: ?execution_values.ExecutionContext = null,
        scope_root: ?ScopeRoot = null,
        manual_state_attempt: ?ManualStateAttempt = null,
        current_transaction_attempt: ?TransactionAttemptState = null,
        next_transaction_attempt_generation: u64 = 0,
        active_block_execution_generation: ?u64 = null,
        next_block_execution_generation: u64 = 0,
        checkpoint_top: usize = 0,
        next_checkpoint_id: usize = 0,
        block_hash_source: ?BlockHashSource = null,
        precompile_runtime: ?execution_values.PrecompileRuntime = null,
        config: evmz.ExecutionConfig,
        prepared_code_backend: ?prepared_code.Backend,
        prepared_code_execution: ?prepared_code.Execution = null,
        prepared_code_execution_depth: usize = 0,
        trace_depth: u16 = 0,
        last_call_output: frame_io.ByteSlot,

        const AttemptMode = union(enum) {
            normal,
            observed,
            captured: *CaptureContext,

            fn observesState(self: AttemptMode) bool {
                return self != .normal;
            }

            fn captureContext(self: AttemptMode) ?*CaptureContext {
                return switch (self) {
                    .normal, .observed => null,
                    .captured => |context| context,
                };
            }
        };

        const ManualStateAttempt = struct {
            id: TrackedState.AttemptId,
            mode: AttemptMode,
        };

        const TransactionAttemptState = struct {
            state_attempt_id: TrackedState.AttemptId,
            generation: u64,
            mode: AttemptMode,
            phase: enum { active, pending } = .active,
            nonce_intent: TransactionNonceIntentState = .unused,
            payload_started: bool = false,
        };

        const TransactionNonceIntentState = union(enum) {
            unused,
            active: struct {
                root: ScopeRoot,
            },
            completed,
        };

        /// Generation-checked mutation capability for one rollback-armed
        /// transaction attempt. It exposes execution and direct state
        /// operations, but only the owning transaction binder may finish it.
        pub const TransactionAttempt = struct {
            executor: *Self,
            generation: u64,

            pub const AccountSummary = struct {
                nonce: u64,
                balance: u256,
                code_hash: [32]u8,
            };

            /// One transaction-owned sender-nonce advancement. The mutation is
            /// placed outside the payload checkpoint. Root transaction execution
            /// treats nonce handling as complete; raw and nested CREATE do not.
            pub const TransactionNonceIntent = struct {
                executor: *Self,
                attempt_generation: u64,
                sender: Address,

                pub fn complete(self: TransactionNonceIntent) void {
                    const attempt = TransactionAttempt{
                        .executor = self.executor,
                        .generation = self.attempt_generation,
                    };
                    const attempt_state = attempt.state();
                    const intent = switch (attempt_state.nonce_intent) {
                        .active => |intent| intent,
                        .unused, .completed => unreachable,
                    };
                    std.debug.assert(std.mem.eql(u8, &intent.root.sender, &self.sender));
                    attempt_state.nonce_intent = .completed;
                }
            };

            pub fn allocator(self: TransactionAttempt) std.mem.Allocator {
                self.requireActive();
                return self.executor.allocator;
            }

            pub fn executeRequest(
                self: TransactionAttempt,
                request: execution_values.EvmExecutionRequest,
            ) !Interpreter.Result {
                self.requireActive();
                return self.executor.executeTransactionRequest(request);
            }

            pub fn executeRequestPhased(
                self: TransactionAttempt,
                request: execution_values.EvmExecutionRequest,
            ) !TransactionExecutionOutcomeType {
                self.requireActive();
                return self.executor.executeTransactionRequestPhased(request);
            }

            /// Execute one root payload under a managed inner checkpoint.
            ///
            /// The payload writes remain in the outer attempt only when dispatch
            /// reaches payload execution and succeeds. Preparation failure and
            /// EVM revert/invalid/out-of-gas restore only this inner checkpoint.
            /// The caller still owns scope opening, family preparation and
            /// finalization, settlement, and completion of the outer attempt.
            pub fn runPayload(
                self: TransactionAttempt,
                request: execution_values.EvmExecutionRequest,
            ) !TransactionExecutionOutcomeType {
                self.requireActive();
                return self.executor.runPayloadInOpenScope(request);
            }

            /// Execute a nested prelude request under this attempt's outer
            /// rollback checkpoint while temporarily using the request's own
            /// opcode-visible context and root message.
            pub fn executePreludeRequest(
                self: TransactionAttempt,
                request: execution_values.EvmExecutionRequest,
            ) !Interpreter.Result {
                self.requireActive();
                return self.executor.runTransactionPreludeRequest(request);
            }

            /// Open the payload's execution scope after any transaction
            /// prelude scopes have closed.
            pub fn beginExecution(
                self: TransactionAttempt,
                request: execution_values.EvmExecutionRequest,
                scope_init: execution_values.ExecutionScopeInit,
            ) !void {
                self.requireActive();
                try self.executor.beginMessageScopeInAttempt(request, scope_init);
            }

            pub fn checkpoint(self: TransactionAttempt) !ExecutionCheckpoint {
                self.requireActive();
                return self.executor.checkpoint();
            }

            pub fn accountSummary(self: TransactionAttempt, account_address: Address) !?AccountSummary {
                self.requireActive();
                const account = try self.executor.getAccountOrLoad(account_address) orelse return null;
                return .{
                    .nonce = account.nonce,
                    .balance = account.balance,
                    .code_hash = account.code_hash,
                };
            }

            pub fn code(self: TransactionAttempt, account_address: Address) ![]const u8 {
                self.requireActive();
                return self.executor.getCode(account_address);
            }

            pub fn balance(self: TransactionAttempt, account_address: Address) !u256 {
                self.requireActive();
                return self.executor.getBalance(account_address);
            }

            pub fn accountAccess(self: TransactionAttempt, account_address: Address) !void {
                self.requireActive();
                try self.executor.traceAccountAccess(account_address);
            }

            pub fn touchAccount(self: TransactionAttempt, account_address: Address) !void {
                self.requireActive();
                try self.executor.state.touchAccount(account_address);
            }

            pub fn addBalance(self: TransactionAttempt, account_address: Address, value: u256) !void {
                self.requireActive();
                try self.executor.state.addBalance(account_address, value);
            }

            pub fn subtractBalance(self: TransactionAttempt, account_address: Address, value: u256) !bool {
                self.requireActive();
                return self.executor.state.subtractBalance(account_address, value);
            }

            pub fn setNonce(self: TransactionAttempt, account_address: Address, nonce: u64) !void {
                self.requireActive();
                try self.executor.state.setNonce(account_address, nonce);
            }

            pub fn incrementNonce(self: TransactionAttempt, account_address: Address) !void {
                self.requireActive();
                try self.executor.incrementNonce(account_address);
            }

            /// Advance the transaction sender nonce exactly once outside the
            /// payload rollback boundary. Completion is mandatory before the
            /// attempt can finish.
            pub fn advanceTransactionNonce(
                self: TransactionAttempt,
                message: MessageType,
            ) !TransactionNonceIntent {
                const attempt_state = self.state();
                std.debug.assert(std.meta.activeTag(attempt_state.nonce_intent) == .unused);
                std.debug.assert(!attempt_state.payload_started);
                try self.executor.validateScopeRoot(.fromMessage(message));

                const sender = message.sender();
                try self.executor.incrementNonce(sender);
                attempt_state.nonce_intent = .{ .active = .{
                    .root = .fromMessage(message),
                } };
                return .{
                    .executor = self.executor,
                    .attempt_generation = self.generation,
                    .sender = sender,
                };
            }

            pub fn setCode(self: TransactionAttempt, account_address: Address, code_bytes: []const u8) !void {
                self.requireActive();
                try self.executor.state.setCode(account_address, code_bytes);
            }

            pub fn clearCode(self: TransactionAttempt, account_address: Address) !void {
                self.requireActive();
                try self.executor.state.clearCode(account_address);
            }

            pub fn warmAccount(self: TransactionAttempt, account_address: Address) !void {
                self.requireActive();
                try self.executor.warmAccount(account_address);
            }

            pub fn warmStorage(self: TransactionAttempt, account_address: Address, key: u256) !void {
                self.requireActive();
                try self.executor.warmStorage(account_address, key);
            }

            pub fn finalizeState(self: TransactionAttempt) !void {
                self.requireActive();
                try self.executor.finalizeTransactionState();
            }

            pub fn logView(self: TransactionAttempt) TrackedState.LogView {
                self.requireActive();
                return self.executor.state.logView();
            }

            /// Finish the attempt into an uncommitted pending state. Family
            /// transaction output stays in the transaction binder.
            pub fn finish(self: TransactionAttempt) Pending {
                const state_value = self.state();
                std.debug.assert(std.meta.activeTag(state_value.nonce_intent) != .active);
                self.executor.closeTransactionAttemptScope();
                self.executor.state.seal(state_value.state_attempt_id);
                state_value.phase = .pending;
                return .{
                    .executor = self.executor,
                    .generation = self.generation,
                };
            }

            pub fn discard(self: TransactionAttempt) !void {
                _ = self.state();
                try self.executor.discardCurrentTransaction();
            }

            pub fn discardIfCurrent(self: TransactionAttempt) void {
                const current = if (self.executor.current_transaction_attempt) |*value| value else return;
                if (current.generation != self.generation) return;
                if (current.phase != .active) return;
                self.discard() catch {};
            }

            fn requireActive(self: TransactionAttempt) void {
                _ = self.state();
            }

            fn state(self: TransactionAttempt) *TransactionAttemptState {
                const state_value = if (self.executor.current_transaction_attempt) |*value| value else unreachable;
                std.debug.assert(state_value.generation == self.generation);
                std.debug.assert(state_value.phase == .active);
                return state_value;
            }
        };

        /// Generation-checked exclusive claim over this mutable state branch.
        /// Independent executors carry independent claims.
        pub const BlockExecutionClaim = struct {
            executor: *Self,
            generation: u64,

            pub fn requireActive(self: BlockExecutionClaim) !void {
                const active = self.executor.active_block_execution_generation orelse
                    return error.BlockExecutionFinished;
                if (active != self.generation) return error.StaleBlockExecution;
            }

            pub fn requireFor(self: BlockExecutionClaim, executor: *Self) !void {
                if (self.executor != executor) return error.WrongBlockExecution;
                try self.requireActive();
            }

            pub fn release(self: BlockExecutionClaim) void {
                if (self.executor.active_block_execution_generation == self.generation) {
                    self.executor.active_block_execution_generation = null;
                }
            }
        };

        /// Thin identity token for one completed transaction attempt.
        /// Lifecycle misuse is a programmer error. The generation only makes a
        /// copied stale token assert before it can resolve a newer attempt.
        pub const Pending = struct {
            executor: *Self,
            generation: u64,

            pub fn requireCurrent(self: Pending) void {
                _ = self.state();
            }

            pub fn view(self: Pending) TrackedState.PendingView {
                _ = self.state();
                return self.executor.state.pendingView();
            }

            pub fn logView(self: Pending) TrackedState.LogView {
                return self.view().logs();
            }

            /// Allocator that owns detached pending artifacts. It remains
            /// caller-owned and must outlive them.
            pub fn allocator(self: Pending) std.mem.Allocator {
                _ = self.state();
                return self.executor.allocator;
            }

            /// Borrow transaction-local changes while rollback remains armed.
            pub fn changes(self: Pending) TrackedState.ChangesView {
                return self.view().changes();
            }

            /// Retain pending state whose family output lives beside it.
            pub fn retain(self: Pending) !void {
                const state_value = self.state();
                try self.retainState(state_value);
            }

            fn retainState(self: Pending, state_value: *TransactionAttemptState) !void {
                self.executor.state.retain(state_value.state_attempt_id);
                self.executor.finishCurrentTransaction(false);
            }

            /// Restore the state that preceded this execution. Transaction
            /// ownership closes even if rollback observation reports an error.
            pub fn discard(self: Pending) !void {
                _ = self.state();
                try self.executor.discardCurrentTransaction();
            }

            pub fn discardIfCurrent(self: Pending) void {
                const current = if (self.executor.current_transaction_attempt) |*value| value else return;
                if (current.generation != self.generation) return;
                if (current.phase != .pending) return;
                self.discard() catch {};
            }

            fn state(self: Pending) *TransactionAttemptState {
                const state_value = if (self.executor.current_transaction_attempt) |*value| value else unreachable;
                std.debug.assert(state_value.generation == self.generation);
                std.debug.assert(state_value.phase == .pending);
                return state_value;
            }
        };

        /// Scope-bound execution checkpoint paired with one trace/BAL lifecycle.
        ///
        /// This journal-backed token must be opened and closed inside one active
        /// transaction scope. It never finalizes or closes that scope. The owning
        /// transaction attempt can span prelude writes and payload execution;
        /// broader block phases still use their own STF/backend lifetime.
        /// Treat this token as move-only.
        pub const ExecutionCheckpoint = struct {
            executor: *Self,
            journal_checkpoint: TrackedState.Checkpoint,
            id: usize,
            parent_id: usize,
            open: bool = true,

            pub fn commit(self: *ExecutionCheckpoint) !void {
                self.validateClose();
                self.executor.state.commitCheckpoint(self.journal_checkpoint);
                self.finishClose();
            }

            pub fn restore(self: *ExecutionCheckpoint) !void {
                self.validateClose();
                self.executor.state.revertToCheckpoint(self.journal_checkpoint);
                self.finishClose();
            }

            pub fn deinit(self: *ExecutionCheckpoint) void {
                if (self.open) {
                    std.debug.assert(self.executor.checkpoint_top == self.id);
                    self.executor.state.revertToCheckpoint(self.journal_checkpoint);
                    self.finishClose();
                }
                self.* = undefined;
            }

            fn validateClose(self: *const ExecutionCheckpoint) void {
                std.debug.assert(self.open);
                std.debug.assert(self.executor.checkpoint_top == self.id);
            }

            fn finishClose(self: *ExecutionCheckpoint) void {
                self.open = false;
                self.executor.checkpoint_top = self.parent_id;
            }
        };

        /// Initialize an executor with empty tracked state.
        pub fn init(allocator: std.mem.Allocator, options: Init) Self {
            const state = if (options.state_reader) |state_reader|
                TrackedState.initWithStateReader(allocator, state_reader)
            else
                TrackedState.init(allocator);

            const executor: Self = .{
                .allocator = allocator,
                .state = state,
                .frame_store = .{ .stable_metadata_capacity = default_max_live_frames_value },
                .runtime_frames = .empty,
                .call_scratch_slots = .empty,
                .prepared_code_scratch = call_scratch_storage.Slot.init(allocator),
                .block_hash_source = options.block_hash_source,
                .precompile_runtime = options.precompile_runtime,
                .config = options.config,
                .prepared_code_backend = options.prepared_code_backend,
                .last_call_output = frame_io.ByteSlot.init(allocator),
            };
            return executor;
        }

        pub fn currentCaptureContext(self: *Self) ?*CaptureContext {
            if (self.current_transaction_attempt) |attempt|
                return attempt.mode.captureContext();
            if (self.manual_state_attempt) |attempt|
                return attempt.mode.captureContext();
            return null;
        }

        fn assertAttemptMode(mode: AttemptMode) void {
            const context = mode.captureContext() orelse return;
            std.debug.assert(context.isActive());
        }

        pub fn traceAccountAccess(self: *Self, account_address: Address) !void {
            try self.state.observeAccountAccess(account_address);
        }

        /// Rebind fixture/benchmark inputs and reset tracked state.
        pub fn reset(self: *Self, options: Init) !void {
            if (self.hasActiveBlockExecution()) return error.BlockExecutionActive;
            if (self.runtime_frames.items.len != 0) return error.ActiveRuntimeFrames;
            if (self.checkpoint_top != 0) return error.ActiveCheckpoints;
            std.debug.assert(self.current_transaction_attempt == null);
            if (self.state.scopeActive()) return error.ActiveTransactionScope;
            if (self.prepared_code_execution_depth != 0) return error.ActivePreparedCodeExecution;

            self.state.reset(options.state_reader);
            self.execution_context = null;
            self.scope_root = null;
            self.manual_state_attempt = null;
            self.block_hash_source = options.block_hash_source;
            self.precompile_runtime = options.precompile_runtime;
            self.config = options.config;
            self.prepared_code_backend = options.prepared_code_backend;
            self.clearLastOutput();
        }

        pub fn beginPreparedCodeExecution(self: *Self) void {
            if (self.prepared_code_execution_depth == 0) {
                std.debug.assert(self.prepared_code_execution == null);
                self.prepared_code_scratch.reset();
                self.prepared_code_execution = prepared_code.Execution.init(
                    self.prepared_code_scratch.allocator(),
                    self.prepared_code_backend,
                    self.preparedCodeKey(),
                );
            }
            self.prepared_code_execution_depth = std.math.add(
                usize,
                self.prepared_code_execution_depth,
                1,
            ) catch @panic("prepared-code execution depth overflow");
        }

        pub fn endPreparedCodeExecution(self: *Self) void {
            std.debug.assert(self.prepared_code_execution_depth > 0);
            self.prepared_code_execution_depth -= 1;
            if (self.prepared_code_execution_depth != 0) return;

            self.prepared_code_execution.?.deinit();
            self.prepared_code_execution = null;
            self.prepared_code_scratch.reset();
        }

        pub fn preparedCodeKey(self: *const Self) prepared_code.PreparationKey {
            return .{ .config = self.config };
        }

        /// Release state, frame pools, scratch arenas, and retained return-data buffers.
        pub fn deinit(self: *Self) void {
            std.debug.assert(!self.hasActiveBlockExecution());
            std.debug.assert(self.runtime_frames.items.len == 0);
            std.debug.assert(self.checkpoint_top == 0);
            std.debug.assert(self.current_transaction_attempt == null);
            std.debug.assert(self.prepared_code_execution_depth == 0);
            std.debug.assert(self.prepared_code_execution == null);
            self.state.deinit();
            self.runtime_frames.deinit(self.allocator);
            self.frame_store.deinit(self.allocator);
            self.prepared_code_scratch.deinit();
            for (self.call_scratch_slots.items) |slot| {
                slot.deinit();
                self.allocator.destroy(slot);
            }
            self.call_scratch_slots.deinit(self.allocator);
            self.last_call_output.deinit();
        }

        fn warmTransactionAccesses(
            self: *Self,
            sender: Address,
            recipient: ?Address,
        ) !void {
            try self.state.warmAccount(sender);
            if (recipient) |address| {
                try self.state.warmAccount(address);
            }
            self.scope_root = .{ .sender = sender, .recipient = recipient };
        }

        fn openTransactionScope(
            self: *Self,
            context: execution_values.ExecutionContext,
            mode: AttemptMode,
        ) !void {
            if (self.execution_context != null) return error.ActiveTransactionScope;
            if (self.checkpoint_top != 0) return error.ActiveExecutionCheckpoints;
            std.debug.assert(self.current_transaction_attempt == null);
            std.debug.assert(self.manual_state_attempt == null);
            assertAttemptMode(mode);
            const state_attempt_id = if (mode.observesState())
                self.state.beginObservedTransaction()
            else
                self.state.beginTransaction();
            self.state.beginScope();
            self.manual_state_attempt = .{ .id = state_attempt_id, .mode = mode };
            self.execution_context = context;
            self.scope_root = null;
        }

        fn openTransactionAttemptScope(self: *Self, context: execution_values.ExecutionContext) !void {
            std.debug.assert(self.current_transaction_attempt != null);
            std.debug.assert(self.current_transaction_attempt.?.phase == .active);
            std.debug.assert(self.execution_context == null);
            std.debug.assert(self.checkpoint_top == 0);
            std.debug.assert(!self.state.scopeActive());
            self.execution_context = context;
            self.scope_root = null;
            self.state.beginScope();
        }

        fn closeTransactionAttemptScope(self: *Self) void {
            if (self.execution_context == null) return;
            std.debug.assert(self.current_transaction_attempt != null);
            std.debug.assert(self.state.scopeActive());
            self.state.closeScope();
            self.execution_context = null;
            self.scope_root = null;
        }

        fn requireTransactionScope(self: *const Self) !void {
            if (self.execution_context == null) return error.MissingTransactionScope;
        }

        fn validateScopeContext(self: *const Self, context: execution_values.ExecutionContext) !void {
            const open_context = self.execution_context orelse return error.MissingTransactionScope;
            if (!context_adapter.eql(open_context, context)) return error.ExecutionContextMismatch;
        }

        fn validateScopeRoot(self: *const Self, root: ScopeRoot) !void {
            try self.requireTransactionScope();
            const open_root = self.scope_root orelse return error.ExecutionScopeRootMismatch;
            if (!ScopeRoot.eql(open_root, root)) return error.ExecutionScopeRootMismatch;
        }

        /// Open a manual call transaction scope.
        ///
        /// Callers that use this directly must eventually call `commitTransaction`,
        /// `rollbackTransaction`, `closeTransaction`, or another helper that does so.
        /// The scope warms the sender and recipient. Family-required additions,
        /// such as Ethereum's coinbase rule, belong in `beginMessageScope` init.
        pub fn beginTransaction(self: *Self, tx_context: Host.TxContext, sender: Address, recipient: Address) !void {
            const context = context_adapter.fromHost(tx_context);
            try self.openTransactionScope(context, .normal);
            errdefer self.closeTransaction();
            try warmTransactionAccesses(self, sender, recipient);
        }

        pub fn beginObservedTransaction(
            self: *Self,
            tx_context: Host.TxContext,
            sender: Address,
            recipient: Address,
        ) !void {
            const context = context_adapter.fromHost(tx_context);
            try self.openTransactionScope(context, .observed);
            errdefer self.closeTransaction();
            try warmTransactionAccesses(self, sender, recipient);
        }

        pub fn beginCapturedTransaction(
            self: *Self,
            tx_context: Host.TxContext,
            sender: Address,
            recipient: Address,
            capture: *CaptureContext,
        ) !void {
            const context = context_adapter.fromHost(tx_context);
            try self.openTransactionScope(context, .{ .captured = capture });
            errdefer self.closeTransaction();
            try warmTransactionAccesses(self, sender, recipient);
        }

        /// Open a manual create transaction scope.
        ///
        /// This is the create counterpart to `beginTransaction`; there is no recipient
        /// to warm before the create address is derived during execution.
        pub fn beginCreateTransaction(self: *Self, tx_context: Host.TxContext, sender: Address) !void {
            const context = context_adapter.fromHost(tx_context);
            try self.openTransactionScope(context, .normal);
            errdefer self.closeTransaction();
            try warmTransactionAccesses(self, sender, null);
        }

        /// Open a direct message-execution scope from its authoritative context.
        ///
        /// This is open-only: callers own checkpoint placement, execution, and
        /// the eventual commit, restore, or close. Mandatory sender/recipient/
        /// `scope_init` supplies family- or witness-resolved warmth beyond the
        /// mandatory root sender/recipient accounts.
        pub fn beginMessageScope(
            self: *Self,
            request: execution_values.EvmExecutionRequest,
            scope_init: execution_values.ExecutionScopeInit,
        ) !void {
            try self.beginMessageScopeContext(request.context, request.message, scope_init, .normal);
        }

        pub fn beginObservedMessageScope(
            self: *Self,
            request: execution_values.EvmExecutionRequest,
            scope_init: execution_values.ExecutionScopeInit,
        ) !void {
            try self.beginMessageScopeContext(request.context, request.message, scope_init, .observed);
        }

        /// Atomically open one transaction attempt and its payload execution
        /// scope. Transaction programs with preludes use
        /// `beginTransactionAttemptLifetime` and open the payload afterwards.
        pub fn beginTransactionAttempt(
            self: *Self,
            request: execution_values.EvmExecutionRequest,
            scope_init: execution_values.ExecutionScopeInit,
        ) !TransactionAttempt {
            const attempt = try self.beginTransactionAttemptLifetime();
            errdefer attempt.discardIfCurrent();
            try attempt.beginExecution(request, scope_init);
            return attempt;
        }

        pub fn beginCapturedTransactionAttempt(
            self: *Self,
            request: execution_values.EvmExecutionRequest,
            scope_init: execution_values.ExecutionScopeInit,
            capture: *CaptureContext,
        ) !TransactionAttempt {
            const attempt = try self.beginCapturedTransactionAttemptLifetime(capture);
            errdefer attempt.discardIfCurrent();
            try attempt.beginExecution(request, scope_init);
            return attempt;
        }

        /// Open only the rollback-armed transaction lifetime. Prelude execution
        /// scopes and the payload scope are sequenced beneath this attempt.
        pub fn beginTransactionAttemptLifetime(self: *Self) !TransactionAttempt {
            return self.beginTransactionAttemptLifetimeMode(.normal);
        }

        pub fn beginObservedTransactionAttemptLifetime(self: *Self) !TransactionAttempt {
            return self.beginTransactionAttemptLifetimeMode(.observed);
        }

        pub fn beginCapturedTransactionAttemptLifetime(
            self: *Self,
            capture: *CaptureContext,
        ) !TransactionAttempt {
            return self.beginTransactionAttemptLifetimeMode(.{ .captured = capture });
        }

        fn beginTransactionAttemptLifetimeMode(
            self: *Self,
            mode: AttemptMode,
        ) !TransactionAttempt {
            std.debug.assert(self.current_transaction_attempt == null);
            std.debug.assert(self.execution_context == null);
            std.debug.assert(self.checkpoint_top == 0);
            std.debug.assert(!self.state.scopeActive());

            assertAttemptMode(mode);
            const state_attempt_id = if (mode.observesState())
                self.state.beginObservedTransaction()
            else
                self.state.beginTransaction();
            std.debug.assert(self.next_transaction_attempt_generation != std.math.maxInt(u64));
            self.next_transaction_attempt_generation += 1;
            self.current_transaction_attempt = .{
                .state_attempt_id = state_attempt_id,
                .generation = self.next_transaction_attempt_generation,
                .mode = mode,
            };
            return .{
                .executor = self,
                .generation = self.next_transaction_attempt_generation,
            };
        }

        fn beginMessageScopeContext(
            self: *Self,
            context: execution_values.ExecutionContext,
            message: Self.Message,
            scope_init: execution_values.ExecutionScopeInit,
            mode: AttemptMode,
        ) !void {
            try self.openTransactionScope(context, mode);
            errdefer self.closeTransaction();

            try self.initializeMessageScope(message, scope_init);
        }

        fn beginMessageScopeInAttempt(
            self: *Self,
            request: execution_values.EvmExecutionRequest,
            scope_init: execution_values.ExecutionScopeInit,
        ) !void {
            try self.openTransactionAttemptScope(request.context);
            errdefer self.closeTransactionAttemptScope();

            try self.initializeMessageScope(request.message, scope_init);
        }

        fn initializeMessageScope(
            self: *Self,
            message: Self.Message,
            scope_init: execution_values.ExecutionScopeInit,
        ) !void {
            const initial_warm_set = scope_init.initial_warm_set;
            if (initial_warm_set.accounts.len != 0 or initial_warm_set.storage_slots.len != 0) {
                const root_accounts: usize = switch (message) {
                    .call => 2,
                    .create => 1,
                };
                std.debug.assert(initial_warm_set.accounts.len <= std.math.maxInt(usize) - root_accounts);
                const account_hint = root_accounts + initial_warm_set.accounts.len;
                try self.state.reserveAccessHint(.{
                    .accounts = account_hint,
                    .storage_keys = initial_warm_set.storage_slots.len,
                });
            }

            switch (message) {
                .call => |call| try warmTransactionAccesses(self, call.sender, call.recipient),
                .create => |create| try warmTransactionAccesses(self, create.sender, null),
            }
            for (initial_warm_set.accounts) |address| {
                try self.state.warmAccount(address);
            }
            for (initial_warm_set.storage_slots) |slot| {
                try self.state.warmStorage(slot.address, slot.key);
            }
        }

        fn beginSystemCall(
            self: *Self,
            tx_context: Host.TxContext,
            mode: AttemptMode,
        ) !void {
            try self.openTransactionScope(context_adapter.fromHost(tx_context), mode);
        }

        /// Open a transaction-like scope for family/STF state work without a
        /// root EVM message.
        pub fn beginStateTransition(self: *Self, tx_context: Host.TxContext) !void {
            try self.openTransactionScope(context_adapter.fromHost(tx_context), .normal);
        }

        pub fn beginObservedStateTransition(self: *Self, tx_context: Host.TxContext) !void {
            try self.openTransactionScope(context_adapter.fromHost(tx_context), .observed);
        }

        /// Mark an account warm in the current transaction scope.
        pub fn warmAccount(self: *Self, address: Address) !void {
            try self.requireTransactionScope();
            try self.state.warmAccount(address);
        }

        /// Mark a storage slot warm in the current transaction scope.
        pub fn warmStorage(self: *Self, address: Address, key: u256) !void {
            try self.requireTransactionScope();
            try self.state.warmStorage(address, key);
        }

        /// Return account metadata already present in tracked state.
        pub fn getAccount(self: *const Self, address: Address) ?AccountState {
            return self.state.getAccount(address);
        }

        /// Return account metadata, loading it from the state reader if needed.
        pub fn getAccountOrLoad(self: *Self, address: Address) !?AccountState {
            return self.state.getAccountOrLoad(address);
        }

        /// Read storage through tracked state and its canonical reader.
        pub fn getStorage(self: *Self, address: Address, key: u256) !u256 {
            return self.state.getStorage(address, key);
        }

        /// Read an account balance through tracked state and its canonical reader.
        pub fn getBalance(self: *Self, address: Address) !u256 {
            return self.state.getBalance(address);
        }

        /// Add balance as a direct family/STF state transition.
        pub fn addBalance(self: *Self, address: Address, value: u256) !void {
            try self.state.addBalance(address, value);
        }

        /// Record one semantic account access without changing warmth or
        /// loading account metadata.
        pub fn observeAccountAccess(self: *Self, address_value: Address) !void {
            try self.requireTransactionScope();
            try self.state.observeAccountAccess(address_value);
        }

        /// Set account code as a direct family/STF state transition.
        pub fn setCode(self: *Self, address: Address, code: []const u8) !void {
            try self.state.setCode(address, code);
        }

        pub fn logView(self: *const Self) TrackedState.LogView {
            return self.state.logView();
        }

        pub fn logs(self: *const Self) TrackedState.LogView {
            return self.logView();
        }

        pub fn clearLogs(self: *Self) void {
            self.state.clearLogs();
        }

        /// Capture the mutable branch independently from execution checkpoints.
        pub fn branchCheckpoint(self: *Self) !Self.BranchCheckpoint {
            return self.state.branchCheckpoint();
        }

        /// Open one journal-backed checkpoint inside the active execution scope.
        pub fn checkpoint(self: *Self) !ExecutionCheckpoint {
            try self.requireTransactionScope();
            const id = std.math.add(usize, self.next_checkpoint_id, 1) catch return error.CheckpointIdExhausted;
            const parent_id = self.checkpoint_top;
            const journal_checkpoint = self.state.checkpoint();
            self.next_checkpoint_id = id;
            self.checkpoint_top = id;
            return .{
                .executor = self,
                .journal_checkpoint = journal_checkpoint,
                .id = id,
                .parent_id = parent_id,
            };
        }

        pub fn hasCurrentTransaction(self: *const Self) bool {
            return self.current_transaction_attempt != null;
        }

        /// Restore the mutable branch independently from execution checkpoints.
        pub fn restoreBranch(self: *Self, checkpoint_state: *Self.BranchCheckpoint) void {
            self.state.restoreBranch(checkpoint_state);
        }

        /// Internal lifetime seam used by the engine's BlockExecution scope.
        /// Public integrations construct that scope instead of claiming directly.
        pub fn claimBlockExecution(self: *Self) !BlockExecutionClaim {
            if (self.hasActiveBlockExecution()) return error.BlockExecutionActive;
            self.next_block_execution_generation +%= 1;
            self.active_block_execution_generation = self.next_block_execution_generation;
            return .{
                .executor = self,
                .generation = self.next_block_execution_generation,
            };
        }

        pub fn hasActiveBlockExecution(self: *const Self) bool {
            return self.active_block_execution_generation != null;
        }

        pub fn acceptedView(self: *const Self) TrackedState.AcceptedView {
            return self.state.acceptedView();
        }

        /// Finalize state changes for the current transaction and close its context.
        pub fn commitTransaction(self: *Self) !void {
            try self.commitTransactionObserved(IgnorePending{});
        }

        /// Finalize and expose the sealed pending view before retaining it.
        /// Observer failure discards the complete transition.
        pub fn commitTransactionObserved(self: *Self, observer: anytype) !void {
            if (self.checkpoint_top != 0) return error.ActiveExecutionCheckpoints;
            std.debug.assert(self.current_transaction_attempt == null);
            try self.finalizeTransactionState();
            try self.resolveManualTransaction(observer);
        }

        fn finalizeTransactionState(self: *Self) !void {
            try self.state.finalize(.{
                .existing_account = spec.self_destruct.finalization(false),
                .created_account = spec.self_destruct.finalization(true),
            });
        }

        /// Restore from a branch checkpoint and close the transaction context.
        pub fn rollbackTransaction(self: *Self, checkpoint_state: *Self.BranchCheckpoint) !void {
            if (self.checkpoint_top != 0) return error.ActiveExecutionCheckpoints;
            std.debug.assert(self.current_transaction_attempt == null);
            self.restoreBranch(checkpoint_state);
            self.closeTransaction();
        }

        /// Close the transaction context without restoring its mutations.
        pub fn closeTransaction(self: *Self) void {
            self.closeTransactionObserved(IgnorePending{}) catch unreachable;
        }

        /// Seal and expose an already-resolved manual transaction before
        /// retaining it. This skips protocol finalization.
        pub fn closeTransactionObserved(self: *Self, observer: anytype) !void {
            if (self.checkpoint_top != 0) @panic("cannot close a transaction scope while an execution checkpoint is open");
            std.debug.assert(self.current_transaction_attempt == null);
            if (self.execution_context == null) return;
            try self.resolveManualTransaction(observer);
        }

        fn resolveManualTransaction(self: *Self, observer: anytype) !void {
            std.debug.assert(self.state.scopeActive());
            const state_attempt_id = (self.manual_state_attempt orelse unreachable).id;
            self.state.closeScope();
            self.state.seal(state_attempt_id);
            observer.observe(self.state.pendingView()) catch |err| {
                self.state.discard(state_attempt_id);
                self.manual_state_attempt = null;
                self.execution_context = null;
                self.scope_root = null;
                return err;
            };
            self.state.retain(state_attempt_id);
            self.manual_state_attempt = null;
            self.execution_context = null;
            self.scope_root = null;
        }

        /// Close whichever execution scope belongs to a resolved transaction
        /// attempt, or clear an execution-less attempt's retained journal.
        fn closeTransactionLifetime(self: *Self) void {
            std.debug.assert(self.checkpoint_top == 0);
            std.debug.assert(self.current_transaction_attempt != null);
            std.debug.assert(!self.state.scopeActive());
            self.execution_context = null;
            self.scope_root = null;
        }

        fn discardCurrentTransaction(self: *Self) !void {
            std.debug.assert(self.current_transaction_attempt != null);
            defer self.finishCurrentTransaction(true);
            self.state.discard(self.current_transaction_attempt.?.state_attempt_id);
        }

        fn finishCurrentTransaction(self: *Self, clear_output: bool) void {
            std.debug.assert(self.current_transaction_attempt != null);
            if (clear_output) self.clearLastOutput();
            self.closeTransactionLifetime();
            self.current_transaction_attempt = null;
        }

        /// Borrow the cumulative accepted changes relative to the state reader.
        pub fn acceptedChanges(self: *const Self) TrackedState.ChangesView {
            std.debug.assert(self.current_transaction_attempt == null);
            return self.acceptedView().changes();
        }

        /// Drop the cumulative accepted branch and clear any open context.
        pub fn discardAccepted(self: *Self) void {
            if (self.checkpoint_top != 0) @panic("cannot discard changes while an execution checkpoint is open");
            std.debug.assert(self.current_transaction_attempt == null);
            self.state.discardAccepted();
            self.execution_context = null;
            self.scope_root = null;
        }

        /// Read account code through tracked state and its canonical reader.
        pub fn getCode(self: *Self, address: Address) ![]const u8 {
            return self.state.getCode(address);
        }

        /// Prepare code according to the executor preprocessing configuration.
        pub fn prepareBytecode(self: *const Self, code: []const u8) !Bytecode {
            return runtime.prepareBytecodeAlloc(self, self.allocator, code);
        }

        /// Duplicate the effective execution code for an address.
        ///
        /// EIP-7702 delegation is resolved here so callers execute target code while
        /// preserving the original message address semantics.
        pub fn dupeExecutionCode(self: *Self, address: Address) ![]u8 {
            return runtime.dupeExecutionCodeAlloc(self, self.allocator, address);
        }

        /// Return this executor's `Host` adapter for interpreter frames.
        pub fn host(self: *Self) Host {
            return callbacks.host(self);
        }

        /// Execute a raw call inside an already-open tx scope.
        pub fn executeCall(self: *Self, message: Self.Call, gas: execution_values.ExecutionGas) !Self.EvmResult {
            return runtime.executeCall(self, message, gas);
        }

        /// Execute a raw call by loading and preparing recipient code first.
        pub fn executeCallTransaction(
            self: *Self,
            sender: Address,
            recipient: Address,
            input: []const u8,
            gas: execution_values.ExecutionGas,
            value: u256,
        ) !Interpreter.Result {
            return runtime.executeCallTransaction(self, sender, recipient, input, gas, value);
        }

        /// Execute a raw call with caller-provided prepared bytecode.
        pub fn executePreparedCallTransaction(self: *Self, options: Self.PreparedCallTransaction) !Interpreter.Result {
            return runtime.executePreparedCallTransaction(self, options);
        }

        /// Execute a raw create inside an already-open create tx scope.
        pub fn executeCreateTransaction(
            self: *Self,
            sender: Address,
            recipient: Address,
            init_code: []const u8,
            gas: execution_values.ExecutionGas,
            value: u256,
        ) !Self.EvmResult {
            return runtime.executeCreateTransaction(self, sender, recipient, init_code, gas, value);
        }

        /// Execute a raw create/create2 message inside an already-open tx scope.
        pub fn executeCreate(self: *Self, message: Self.Create, gas: execution_values.ExecutionGas) !Self.EvmResult {
            return runtime.executeCreate(self, message, gas);
        }

        /// Execute a raw call/create message inside an already-open tx scope.
        ///
        /// This does not open or close a transaction scope. Use `runStandalone` for the
        /// fully-managed raw-message lifecycle.
        pub fn executeMessage(self: *Self, message: Self.Message, gas: execution_values.ExecutionGas) !Self.EvmResult {
            try self.validateScopeRoot(.fromMessage(message));
            const call_capture = try runtime.beginRootCapture(self, message, gas);
            const result = try switch (message) {
                .call => |call| runtime.executeCall(self, call, gas),
                .create => |create| runtime.executeCreate(self, create, gas),
            };
            if (call_capture) |token| try runtime.finishRootHostCapture(self, token, result);
            return result;
        }

        /// Compatibility adapter for one call/create message and flat host context.
        ///
        /// New integrations should prefer `runStandaloneRequest`, whose context is
        /// the authoritative concrete execution value.
        pub fn runStandalone(self: *Self, tx_context: Host.TxContext, message: Self.Message, gas: execution_values.ExecutionGas) !Self.EvmResult {
            return self.runStandaloneContext(
                context_adapter.fromHost(tx_context),
                message,
                gas,
                .{},
                .normal,
                IgnorePending{},
            );
        }

        /// Run one direct message and consume its sealed observations before
        /// the transition is retained.
        pub fn runStandaloneObserved(
            self: *Self,
            tx_context: Host.TxContext,
            message: Self.Message,
            gas: execution_values.ExecutionGas,
            observer: anytype,
        ) !Self.EvmResult {
            return self.runStandaloneContext(
                context_adapter.fromHost(tx_context),
                message,
                gas,
                .{},
                .observed,
                observer,
            );
        }

        pub fn runStandaloneCaptured(
            self: *Self,
            tx_context: Host.TxContext,
            message: Self.Message,
            gas: execution_values.ExecutionGas,
            capture: *CaptureContext,
        ) !Self.EvmResult {
            return self.runStandaloneContext(
                context_adapter.fromHost(tx_context),
                message,
                gas,
                .{},
                .{ .captured = capture },
                IgnorePending{},
            );
        }

        /// Run one direct execution request as a complete transaction scope.
        ///
        /// Lifecycle: open scope -> checkpoint -> execute -> finalize+commit on
        /// success, or restore on revert/invalid/out-of-gas -> close. Family
        /// validation, authorization processing, settlement, and receipts remain
        /// outside this convenience.
        pub fn runStandaloneRequest(
            self: *Self,
            request: execution_values.EvmExecutionRequest,
            scope_init: execution_values.ExecutionScopeInit,
        ) !Self.EvmResult {
            return self.runStandaloneContext(
                request.context,
                request.message,
                request.gas,
                scope_init,
                .normal,
                IgnorePending{},
            );
        }

        pub fn runStandaloneCapturedRequest(
            self: *Self,
            request: execution_values.EvmExecutionRequest,
            scope_init: execution_values.ExecutionScopeInit,
            capture: *CaptureContext,
        ) !Self.EvmResult {
            return self.runStandaloneContext(
                request.context,
                request.message,
                request.gas,
                scope_init,
                .{ .captured = capture },
                IgnorePending{},
            );
        }

        fn runStandaloneContext(
            self: *Self,
            context: execution_values.ExecutionContext,
            message: Self.Message,
            gas: execution_values.ExecutionGas,
            scope_init: execution_values.ExecutionScopeInit,
            mode: AttemptMode,
            observer: anytype,
        ) !Self.EvmResult {
            try self.beginMessageScopeContext(context, message, scope_init, mode);
            errdefer self.closeTransaction();

            var pre_execution = try self.checkpoint();
            defer pre_execution.deinit();

            const result = try self.executeMessage(message, gas);
            if (executionRolledBack(result.status())) {
                try pre_execution.restore();
                try self.closeTransactionObserved(observer);
            } else {
                try self.finalizeTransactionState();
                try pre_execution.commit();
                try self.closeTransactionObserved(observer);
            }
            return result;
        }

        /// Execute the normalized request inside its already-open transaction scope.
        ///
        /// The caller owns transaction charging, nonce/access/auth handling, settlement,
        /// and final commit/rollback. Transaction programs compose those pieces.
        pub fn executeTransactionRequest(self: *Self, request: execution_values.EvmExecutionRequest) !Interpreter.Result {
            return (try self.executeTransactionRequestPhased(request)).result;
        }

        /// Execute one root request and report whether dispatch preparation
        /// completed. The result remains an EVM result; the stage is only the
        /// stage fact needed by a family transaction coordinator to choose
        /// its outer rollback boundary.
        pub fn executeTransactionRequestPhased(
            self: *Self,
            request: execution_values.EvmExecutionRequest,
        ) !TransactionExecutionOutcomeType {
            try self.validateScopeContext(request.context);
            try self.validateScopeRoot(.fromMessage(request.message));
            return self.executeTransactionRequestTrustedPhased(request);
        }

        /// Resolve one root payload's inner rollback boundary inside an
        /// already-open transaction-attempt scope.
        fn runPayloadInOpenScope(
            self: *Self,
            request: execution_values.EvmExecutionRequest,
        ) !TransactionExecutionOutcomeType {
            std.debug.assert(self.current_transaction_attempt != null);
            const attempt_state = if (self.current_transaction_attempt) |*value| value else unreachable;
            std.debug.assert(!attempt_state.payload_started);
            attempt_state.payload_started = true;

            var execution_checkpoint = try self.checkpoint();
            defer execution_checkpoint.deinit();

            const outcome = try self.executeTransactionRequestPhased(request);
            if (outcome.stage == .preparation or executionRolledBack(outcome.result.status)) {
                try execution_checkpoint.restore();
            } else {
                try execution_checkpoint.commit();
            }
            return outcome;
        }

        /// Execute and finalize one family prelude request in its own execution
        /// scope while retaining the transaction attempt's outer journal. The
        /// next prelude request or payload starts with fresh warmth, transient
        /// storage, logs, and original-storage tracking.
        fn runTransactionPreludeRequest(self: *Self, request: execution_values.EvmExecutionRequest) !Interpreter.Result {
            try self.openTransactionAttemptScope(request.context);
            errdefer self.closeTransactionAttemptScope();
            self.scope_root = .fromMessage(request.message);

            var execution_checkpoint = try self.checkpoint();
            defer execution_checkpoint.deinit();
            const result = try self.executeTransactionRequestTrusted(request);
            if (executionRolledBack(result.status)) {
                try execution_checkpoint.restore();
                self.closeTransactionAttemptScope();
            } else {
                try self.finalizeTransactionState();
                try execution_checkpoint.commit();
                self.closeTransactionAttemptScope();
            }
            return result;
        }

        fn executeTransactionRequestTrusted(self: *Self, request: execution_values.EvmExecutionRequest) !Interpreter.Result {
            return (try self.executeTransactionRequestTrustedPhased(request)).result;
        }

        fn executeTransactionRequestTrustedPhased(
            self: *Self,
            request: execution_values.EvmExecutionRequest,
        ) !TransactionExecutionOutcomeType {
            switch (request.message) {
                .call => |call| try self.traceAccountAccess(call.recipient),
                .create => |create| try self.traceAccountAccess(create.recipient),
            }
            const call_capture = try runtime.beginRootCapture(self, request.message, request.gas);
            const outcome = try switch (request.message) {
                .call => |call| runtime.executeCallTransactionPhased(
                    self,
                    call.sender,
                    call.recipient,
                    call.input,
                    request.gas,
                    call.value,
                ),
                .create => |create| runtime.executeCreateTransactionPhased(
                    self,
                    create,
                    request.gas,
                ),
            };
            if (call_capture) |token| try runtime.finishRootCapture(self, token, outcome.result);
            return outcome;
        }

        /// Execute a system call as its own transaction-like scope.
        ///
        /// System calls bypass user transaction charging and value transfer, but still
        /// run with a tx context, checkpoint state, and commit/rollback semantics.
        pub fn executeSystemCall(
            self: *Self,
            tx_context: Host.TxContext,
            sender: Address,
            recipient: Address,
            input: []const u8,
            gas: execution_values.ExecutionGas,
        ) !Interpreter.Result {
            return self.executeSystemCallMode(
                tx_context,
                sender,
                recipient,
                input,
                gas,
                .normal,
                IgnorePending{},
            );
        }

        /// Execute one system call and expose its checkpoint-resolved pending
        /// state before the transition is retained.
        pub fn executeSystemCallObserved(
            self: *Self,
            tx_context: Host.TxContext,
            sender: Address,
            recipient: Address,
            input: []const u8,
            gas: execution_values.ExecutionGas,
            observer: anytype,
        ) !Interpreter.Result {
            return self.executeSystemCallMode(
                tx_context,
                sender,
                recipient,
                input,
                gas,
                .observed,
                observer,
            );
        }

        pub fn executeSystemCallCaptured(
            self: *Self,
            tx_context: Host.TxContext,
            sender: Address,
            recipient: Address,
            input: []const u8,
            gas: execution_values.ExecutionGas,
            capture: *CaptureContext,
            observer: anytype,
        ) !Interpreter.Result {
            return self.executeSystemCallMode(
                tx_context,
                sender,
                recipient,
                input,
                gas,
                .{ .captured = capture },
                observer,
            );
        }

        fn executeSystemCallMode(
            self: *Self,
            tx_context: Host.TxContext,
            sender: Address,
            recipient: Address,
            input: []const u8,
            gas: execution_values.ExecutionGas,
            mode: AttemptMode,
            observer: anytype,
        ) !Interpreter.Result {
            self.beginPreparedCodeExecution();
            defer self.endPreparedCodeExecution();

            try self.beginSystemCall(tx_context, mode);
            errdefer self.closeTransaction();

            self.clearLastOutput();
            const checkpoint_state = self.state.checkpoint();
            var checkpoint_open = true;
            errdefer {
                if (checkpoint_open) self.state.revertToCheckpoint(checkpoint_state);
            }

            const resolved = try runtime.resolveCode(self, recipient);
            const bytecode = try runtime.resolveExecutionCodeView(self, try runtime.resolvedCodeView(self, resolved));
            try self.traceAccountAccess(recipient);
            const message = Host.Message{
                .depth = 0,
                .kind = .call,
                .gas = std.math.cast(i64, gas.regular_left) orelse std.math.maxInt(i64),
                .gas_reservoir = std.math.cast(i64, gas.reservoir) orelse std.math.maxInt(i64),
                .recipient = recipient,
                .sender = sender,
                .input_data = input,
                .value = 0,
                .code_address = recipient,
            };

            const call_result = (try runtime.executePreparedCallMessage(self, message, bytecode)).expectCall();
            const result = Interpreter.Result{
                .status = call_result.status,
                .cause = call_result.cause,
                .gas_left = call_result.gas_left,
                .gas_refund = call_result.gas_refund,
                .gas_reservoir = call_result.gas_reservoir,
                .state_gas_spent = call_result.state_gas_spent,
                .state_gas_from_gas_left = call_result.state_gas_from_gas_left,
                .output_data = self.lastOutputData(),
            };

            if (executionRolledBack(result.status)) {
                self.state.revertToCheckpoint(checkpoint_state);
                checkpoint_open = false;
                try self.closeTransactionObserved(observer);
            } else {
                self.state.commitCheckpoint(checkpoint_state);
                checkpoint_open = false;
                try self.commitTransactionObserved(observer);
            }

            return .{
                .status = result.status,
                .cause = result.cause,
                .gas_left = result.gas_left,
                .gas_refund = result.gas_refund,
                .gas_reservoir = result.gas_reservoir,
                .state_gas_spent = result.state_gas_spent,
                .state_gas_from_gas_left = result.state_gas_from_gas_left,
                .output_data = self.lastOutputData(),
            };
        }

        /// Transfer value between accounts, returning false on insufficient balance.
        pub fn transferValue(self: *Self, sender: Address, recipient: Address, value: u256) !bool {
            if (value == 0) return true;
            if (!try self.state.subtractBalance(sender, value)) return false;
            try self.state.addBalance(recipient, value);
            try transfer_logs.emit(self, .{
                .from = sender,
                .to = recipient,
                .amount = value,
            });
            return true;
        }

        /// Increment an account nonce, saturating at `maxInt(u64)`.
        pub fn incrementNonce(self: *Self, address: Address) !void {
            const account = try self.getAccountOrLoad(address) orelse AccountState{};
            try self.state.setNonce(address, std.math.add(u64, account.nonce, 1) catch std.math.maxInt(u64));
        }

        /// Return whether an interpreter status should revert execution state.
        pub fn executionRolledBack(status: Interpreter.Status) bool {
            return switch (status) {
                .success => false,
                .revert, .invalid, .out_of_gas => true,
            };
        }

        /// Drop the retained output buffer from the last call/create result.
        pub fn clearLastOutput(self: *Self) void {
            _ = self.last_call_output.clear();
        }

        pub fn lastOutputData(self: *const Self) []u8 {
            return self.last_call_output.slice();
        }

        pub fn setLastOutput(self: *Self, output_data: []const u8) ![]u8 {
            self.clearLastOutput();
            return self.last_call_output.replace(output_data);
        }
    };
}

const Default = Executor(DefaultSpec);
const Frontier = evmz.Vm(evmz.eth.frontier);
const TangerineWhistle = evmz.Vm(evmz.eth.tangerine_whistle);
const SpuriousDragon = evmz.Vm(evmz.eth.spurious_dragon);
const Istanbul = evmz.Vm(evmz.eth.istanbul);
const Berlin = evmz.Vm(evmz.eth.berlin);
const London = evmz.Vm(evmz.eth.london);
const Shanghai = evmz.Vm(evmz.eth.shanghai);
const Cancun = evmz.Vm(evmz.eth.cancun);
const Prague = evmz.Vm(evmz.eth.prague);
const Osaka = evmz.Vm(evmz.eth.osaka);
const Amsterdam = evmz.Vm(evmz.eth.amsterdam);
const testTxContext = evmz.t.defaultTxContext;

test "executor init options retain code analysis config" {
    var executor = Amsterdam.Executor.init(std.testing.allocator, .{
        .config = .advanced,
    });
    defer executor.deinit();

    try std.testing.expectEqual(evmz.ExecutionConfig.Preprocessing.full, executor.config.preprocessing);
}

test "executor prepareBytecode honors jumpdest strategy config" {
    var executor = Amsterdam.Executor.init(std.testing.allocator, .{
        .config = .{ .jumpdest_strategy = .simd_bitmask },
    });
    defer executor.deinit();

    const code = evmz.t.bytecode(.{ .PUSH1, .JUMPDEST, .JUMPDEST });
    var bytecode = try executor.prepareBytecode(&code);
    defer bytecode.deinit(std.testing.allocator);

    try std.testing.expectEqual(evmz.ExecutionConfig.JumpDestStrategy.simd_bitmask, bytecode.jumpdests.strategy);
    try std.testing.expect(bytecode.jumpdests.analyzed);
}

test "executor executes prepared bytecode call transaction" {
    const sender = evmz.addr(0xaaaa);
    const contract = evmz.addr(0xbbbb);
    const tx_context = testTxContext(sender, 100_000);
    var executor = Osaka.Executor.init(std.testing.allocator, .{});
    defer executor.deinit();

    var sender_account = MemoryAccount.init(std.testing.allocator);
    sender_account.balance = 1_000_000;
    try executor.state.seedAccount(sender, sender_account);

    const code = evmz.t.bytecode(.{ .PUSH1, 0x2a, .PUSH0, .SSTORE, .STOP });
    var bytecode = try executor.prepareBytecode(&code);
    defer bytecode.deinit(std.testing.allocator);

    try executor.beginTransaction(tx_context, sender, contract);
    const result = try executor.executePreparedCallTransaction(.{
        .bytecode = &bytecode,
        .sender = sender,
        .recipient = contract,
        .gas = 100_000,
    });

    try std.testing.expectEqual(Interpreter.Status.success, result.status);
    try std.testing.expect(bytecode.jumpdests.analyzed);
    try std.testing.expectEqual(@as(u256, 0x2a), try executor.getStorage(contract, 0));
}

test "normal call transactions retain caller-owned prepared code" {
    const sender = evmz.addr(0xaaaa);
    const contract = evmz.addr(0xbbbb);
    const target = evmz.addr(0xbeef);
    const tx_context = testTxContext(sender, 100_000);
    const contract_code = evmz.t.bytecode(.{
        .PUSH0, .PUSH0, .PUSH0, .PUSH0, .PUSH0,
        .PUSH2, 0xbe,   0xef,   .GAS,   .CALL,
        .STOP,
    });
    const target_code = evmz.t.bytecode(.{
        .PUSH1, 0x2a,
        .PUSH0, .SSTORE,
        .STOP,
    });

    var pool = evmz.prepared_code.InMemoryPreparedPool.init(std.testing.allocator);
    defer pool.deinit();
    var executor = Osaka.Executor.init(std.testing.allocator, .{
        .prepared_code_backend = pool.backend(),
    });
    defer executor.deinit();

    var sender_account = MemoryAccount.init(std.testing.allocator);
    sender_account.balance = 1_000_000;
    try executor.state.seedAccount(sender, sender_account);

    var contract_account = MemoryAccount.init(std.testing.allocator);
    try contract_account.setCode(&contract_code);
    try executor.state.seedAccount(contract, contract_account);

    var target_account = MemoryAccount.init(std.testing.allocator);
    try target_account.setCode(&target_code);
    try executor.state.seedAccount(target, target_account);

    try executor.beginTransaction(tx_context, sender, contract);
    const first = try executor.executeCallTransaction(sender, contract, &.{}, .legacy(100_000), 0);
    executor.closeTransaction();

    try std.testing.expectEqual(Interpreter.Status.success, first.status);
    try std.testing.expectEqual(@as(usize, 2), pool.count());
    try std.testing.expectEqual(@as(u256, 0x2a), try executor.getStorage(target, 0));

    try executor.beginTransaction(tx_context, sender, contract);
    const second = try executor.executeCallTransaction(sender, contract, &.{}, .legacy(100_000), 0);
    executor.closeTransaction();

    try std.testing.expectEqual(Interpreter.Status.success, second.status);
    try std.testing.expectEqual(@as(usize, 2), pool.count());
}

test "CREATE initcode preparation remains execution-local" {
    const sender = evmz.addr(0xaaaa);
    const tx_context = testTxContext(sender, 100_000);

    var pool = evmz.prepared_code.InMemoryPreparedPool.init(std.testing.allocator);
    defer pool.deinit();
    var executor = Osaka.Executor.init(std.testing.allocator, .{
        .prepared_code_backend = pool.backend(),
    });
    defer executor.deinit();

    var sender_account = MemoryAccount.init(std.testing.allocator);
    sender_account.balance = 1_000_000;
    try executor.state.seedAccount(sender, sender_account);

    try executor.beginCreateTransaction(tx_context, sender);
    const result = (try executor.executeCreate(.{
        .sender = sender,
        .recipient = evmz.address.create(sender, 0),
        .init_code = &.{@intFromEnum(evmz.Opcode.STOP)},
    }, .legacy(100_000))).expectCreate();
    executor.closeTransaction();

    try std.testing.expectEqual(Interpreter.Status.success, result.status);
    try std.testing.expectEqual(@as(usize, 0), pool.count());
}

const CacheInvalidatingTrace = struct {
    pool: *evmz.prepared_code.InMemoryPreparedPool,
    replay_cleared: bool = false,

    fn replay(self: *@This(), span: trace.TraceSpan) !void {
        var cursor = trace.TraceCursor.init(span);
        while (try cursor.next()) |event| switch (event) {
            .step_start => {
                if (self.replay_cleared) continue;
                try self.pool.clearRetainingCapacity();
                self.replay_cleared = true;
            },
            .frame_enter, .step_end, .frame_leave => {},
        };
    }
};

test "trace replay runs after prepared code leaves the live frame" {
    const sender = evmz.addr(0xaaaa);
    const contract = evmz.addr(0xbbbb);
    const code = evmz.t.bytecode(.{.STOP});

    var pool = evmz.prepared_code.InMemoryPreparedPool.init(std.testing.allocator);
    defer pool.deinit();
    var executor = Osaka.Executor.init(std.testing.allocator, .{
        .prepared_code_backend = pool.backend(),
    });
    defer executor.deinit();

    var sender_account = MemoryAccount.init(std.testing.allocator);
    sender_account.balance = 1_000_000;
    try executor.state.seedAccount(sender, sender_account);

    var contract_account = MemoryAccount.init(std.testing.allocator);
    try contract_account.setCode(&code);
    try executor.state.seedAccount(contract, contract_account);

    const code_view = try executor.state.getCodeView(contract);
    _ = try pool.getOrPrepare(executor.preparedCodeKey(), code_view.code_hash, code_view.bytes);

    var recorder = CacheInvalidatingTrace{ .pool = &pool };
    var tape = trace.TraceTape.initGrowable(std.testing.allocator);
    defer tape.deinit();
    var capture = CaptureContext.init(std.testing.allocator, .{ .tape = &tape });
    defer capture.deinit();
    try capture.begin();
    var capture_open = true;
    defer {
        if (capture_open) capture.abort() catch {};
    }

    try executor.beginCapturedTransaction(
        testTxContext(sender, 100_000),
        sender,
        contract,
        &capture,
    );
    const result = try executor.executeCallTransaction(sender, contract, &.{}, .legacy(100_000), 0);
    executor.closeTransaction();

    const span = (try capture.finish()).?;
    capture_open = false;
    try recorder.replay(span);
    try tape.resolve(span);

    try std.testing.expectEqual(Interpreter.Status.success, result.status);
    try std.testing.expect(recorder.replay_cleared);
    try std.testing.expectEqual(@as(usize, 0), pool.count());
}

test "reset retains caller backend and isolates preparation configurations" {
    const code = evmz.t.bytecode(.{.STOP});
    const code_hash = evmz.crypto.keccak256(&code);

    var pool = evmz.prepared_code.InMemoryPreparedPool.init(std.testing.allocator);
    defer pool.deinit();
    var executor = Osaka.Executor.init(std.testing.allocator, .{
        .config = .base,
        .prepared_code_backend = pool.backend(),
    });
    defer executor.deinit();

    const prepared = try pool.getOrPrepare(executor.preparedCodeKey(), code_hash, &code);
    try executor.reset(.{
        .config = .base,
        .prepared_code_backend = pool.backend(),
    });
    try std.testing.expectEqual(prepared, pool.get(executor.preparedCodeKey(), code_hash).?);

    try executor.reset(.{
        .config = .advanced,
        .prepared_code_backend = pool.backend(),
    });
    const advanced = try pool.getOrPrepare(executor.preparedCodeKey(), code_hash, &code);
    try std.testing.expect(advanced != prepared);
    try std.testing.expectEqual(@as(usize, 2), pool.count());
}

test "prepared execution follows current code hash without owning public code reads" {
    const contract = evmz.addr(0xc0de);
    const original_code = evmz.t.bytecode(.{ .PUSH0, .STOP });
    const replacement_code = evmz.t.bytecode(.{ .PUSH1, 0x2a, .STOP });

    var pool = evmz.prepared_code.InMemoryPreparedPool.init(std.testing.allocator);
    defer pool.deinit();
    var executor = Osaka.Executor.init(std.testing.allocator, .{
        .prepared_code_backend = pool.backend(),
    });
    defer executor.deinit();

    var account = MemoryAccount.init(std.testing.allocator);
    try account.setCode(&original_code);
    try executor.state.seedAccount(contract, account);
    try executor.beginStateTransition(testTxContext(contract, 100_000));
    defer executor.closeTransaction();

    executor.beginPreparedCodeExecution();
    var prepared_execution_open = true;
    errdefer if (prepared_execution_open) executor.endPreparedCodeExecution();
    const original_execution = try call_runtime.bind(Osaka.Executor).resolveExecutionCode(&executor, contract);
    const original_prepared = original_execution;
    const public_original = try executor.getCode(contract);
    try std.testing.expect(original_prepared.bytes.ptr != public_original.ptr);
    try std.testing.expectEqualSlices(u8, &original_code, public_original);

    try executor.state.setCode(contract, &replacement_code);
    const replacement_execution = try call_runtime.bind(Osaka.Executor).resolveExecutionCode(&executor, contract);
    try std.testing.expect(replacement_execution != original_prepared);
    try std.testing.expectEqualSlices(u8, &replacement_code, replacement_execution.bytes);
    const public_replacement = try executor.getCode(contract);
    try std.testing.expectEqualSlices(u8, &replacement_code, public_replacement);

    executor.endPreparedCodeExecution();
    prepared_execution_open = false;
    executor.closeTransaction();
    try pool.clearRetainingCapacity();
    try std.testing.expectEqualSlices(u8, &replacement_code, public_replacement);
    try std.testing.expectEqualSlices(u8, &replacement_code, try executor.getCode(contract));
}

test "prepared cache cannot satisfy code omitted from the active witness" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const scratch = arena.allocator();

    const target = evmz.addr(0x3000);
    const code = [_]u8{@intFromEnum(evmz.Opcode.STOP)};
    const code_hash = evmz.crypto.keccak256(&code);
    const account_value = try evmz.eth.trie.accountValueFrom(scratch, .{
        .code_hash = code_hash,
    });
    const account_key = evmz.eth.trie.hashedAddressKey(target);

    const TestTrie = struct {
        fn leafNode(allocator: std.mem.Allocator, key: []const u8, value: []const u8) ![]u8 {
            const path = try allocator.alloc(u8, key.len + 1);
            path[0] = 0x20;
            @memcpy(path[1..], key);

            var payload = evmz.rlp.Writer.alloc(allocator);
            defer payload.deinit();
            try payload.bytes(path);
            try payload.bytes(value);

            var out = evmz.rlp.Writer.alloc(allocator);
            errdefer out.deinit();
            try out.listPayload(payload.written());
            return try out.toOwnedSlice();
        }
    };
    const state_node = try TestTrie.leafNode(scratch, &account_key, account_value);
    const state_root = evmz.crypto.keccak256(state_node);
    const nodes = [_][]const u8{state_node};
    const indexed = try evmz.eth.trie.indexNodes(scratch, &nodes);
    var witness = evmz.state.WitnessStateReader.init(state_root, indexed, &.{});
    defer witness.deinit();

    var pool = evmz.prepared_code.InMemoryPreparedPool.init(std.testing.allocator);
    defer pool.deinit();
    var executor = Osaka.Executor.init(std.testing.allocator, .{
        .state_reader = witness.reader(),
        .prepared_code_backend = pool.backend(),
    });
    defer executor.deinit();

    _ = try pool.getOrPrepare(executor.preparedCodeKey(), code_hash, &code);
    try std.testing.expect(pool.get(executor.preparedCodeKey(), code_hash) != null);
    try std.testing.expectError(
        error.InvalidWitness,
        call_runtime.bind(Osaka.Executor).resolveExecutionCode(&executor, target),
    );
}

test "executor BLOCKHASH reads configured block hash source" {
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

    const sender = evmz.addr(0xaaaa);
    const contract = evmz.addr(0xbbbb);
    var tx_context = testTxContext(sender, 100_000);
    tx_context.number = 1000;
    var block_hashes = TestBlockHashSource{};
    var executor = Prague.Executor.init(std.testing.allocator, .{
        .block_hash_source = block_hashes.source(),
    });
    defer executor.deinit();

    var sender_account = MemoryAccount.init(std.testing.allocator);
    sender_account.balance = 1_000_000;
    try executor.state.seedAccount(sender, sender_account);

    const code = evmz.t.bytecode(.{ .PUSH2, 0x03, 0xe7, .BLOCKHASH, .PUSH0, .SSTORE, .STOP });
    var bytecode = try executor.prepareBytecode(&code);
    defer bytecode.deinit(std.testing.allocator);

    try executor.beginTransaction(tx_context, sender, contract);
    const result = try executor.executePreparedCallTransaction(.{
        .bytecode = &bytecode,
        .sender = sender,
        .recipient = contract,
        .gas = 100_000,
    });

    try std.testing.expectEqual(Interpreter.Status.success, result.status);
    try std.testing.expectEqual(@as(?u64, 999), block_hashes.last_number);
    try std.testing.expectEqual(@as(u256, 0xab), try executor.getStorage(contract, 0));
}

test "executor executeMessage dispatches top-level call" {
    const sender = evmz.addr(0xaaaa);
    const contract = evmz.addr(0xbbbb);
    const tx_context = testTxContext(sender, 100_000);
    var executor = Osaka.Executor.init(std.testing.allocator, .{});
    defer executor.deinit();

    var sender_account = MemoryAccount.init(std.testing.allocator);
    sender_account.balance = 1_000_000;
    try executor.state.seedAccount(sender, sender_account);

    var contract_account = MemoryAccount.init(std.testing.allocator);
    try contract_account.setCode(&.{ 0x60, 0x2a, 0x5f, 0x55, 0x00 });
    try executor.state.seedAccount(contract, contract_account);

    try executor.beginTransaction(tx_context, sender, contract);
    const result = (try executor.executeMessage(.{ .call = .{
        .sender = sender,
        .recipient = contract,
    } }, .legacy(100_000))).expectCall();

    try std.testing.expectEqual(Interpreter.Status.success, result.status);
    try std.testing.expectEqual(@as(u256, 0x2a), try executor.getStorage(contract, 0));
}

test "system call preserves parent stack across nested frame growth" {
    const sender = evmz.addr(0x1111);
    const parent = evmz.addr(0xaaaa);
    const child = evmz.addr(0xbbbb);
    var executor = evmz.Vm(evmz.eth.cancun).Executor.init(std.testing.allocator, .{});
    defer executor.deinit();

    var parent_account = MemoryAccount.init(std.testing.allocator);
    try parent_account.setCode(&evmz.t.bytecode(.{
        .PUSH1,  0x7b,
        .PUSH0,  .PUSH0,
        .PUSH0,  .PUSH0,
        .PUSH0,  .PUSH2,
        0xbb,    0xbb,
        .PUSH2,  0xff,
        0xff,    .CALL,
        .POP,    .PUSH0,
        .SSTORE, .STOP,
    }));
    try executor.state.seedAccount(parent, parent_account);

    var child_account = MemoryAccount.init(std.testing.allocator);
    try child_account.setCode(&evmz.t.bytecode(.{
        .PUSH1,  0x2a,
        .PUSH1,  0x01,
        .SSTORE, .STOP,
    }));
    try executor.state.seedAccount(child, child_account);

    const result = try executor.executeSystemCall(
        testTxContext(sender, 200_000),
        sender,
        parent,
        &.{},
        .legacy(200_000),
    );

    try std.testing.expectEqual(Interpreter.Status.success, result.status);
    try std.testing.expectEqual(@as(u256, 0x7b), try executor.getStorage(parent, 0));
    try std.testing.expectEqual(@as(u256, 0x2a), try executor.getStorage(child, 1));
    try std.testing.expectEqual(@as(usize, 1), executor.frame_store.maxStackBase());
}

test "exact spec drives call base gas" {
    const ExpensiveCall = evmz.Vm(evmz.eth.frontier.extend(.{
        .call = .{ .base_gas = evmz.eth.frontier.call.base_gas + 5 },
    }));

    const default_gas_left = try executeNestedBalanceCall(Frontier.specification);
    const custom_gas_left = try executeNestedBalanceCall(ExpensiveCall.specification);

    try std.testing.expectEqual(default_gas_left - 5, custom_gas_left);
}

test "exact spec drives top-level delegated account access" {
    const overrides = struct {
        fn topLevelDelegatedAccountAccess(
            input: evmz.execution.TopLevelDelegatedAccountAccessInput,
        ) ?evmz.execution.DelegatedAccountAccess {
            _ = input;
            return .{ .status = .cold, .gas = 7 };
        }
    };
    const ExpensiveTopLevelDelegatedAccess = evmz.Vm(evmz.eth.prague.extend(.{
        .call = .{ .topLevelDelegatedAccountAccess = overrides.topLevelDelegatedAccountAccess },
    }));

    const default_gas_left = try executeTopLevelDelegatedCall(Prague.specification);
    const custom_gas_left = try executeTopLevelDelegatedCall(ExpensiveTopLevelDelegatedAccess.specification);

    try std.testing.expectEqual(default_gas_left - 7, custom_gas_left);
}

test "top-level call code resolution reuses one traced view" {
    const sender = evmz.addr(0x1111);
    const recipient = evmz.addr(0x2222);
    var observations = CodeObservation{
        .required = recipient,
        .expected_code_reads = 1,
    };
    var executor = Prague.Executor.init(std.testing.allocator, .{});
    defer executor.deinit();
    try putFundedSender(&executor, sender);

    var recipient_account = MemoryAccount.init(std.testing.allocator);
    try recipient_account.setCode(&.{evmz.Opcode.STOP.toByte()});
    try executor.state.seedAccount(recipient, recipient_account);

    const result = (try executor.runStandaloneObserved(
        testTxContext(sender, 100_000),
        .{ .call = .{
            .sender = sender,
            .recipient = recipient,
        } },
        .legacy(100_000),
        &observations,
    )).expectCall();

    try std.testing.expectEqual(Interpreter.Status.success, result.status);
    try std.testing.expectEqual(@as(usize, 1), observations.calls);
}

test "top-level delegated access failure does not read target code" {
    const overrides = struct {
        fn topLevelDelegatedAccountAccess(
            input: evmz.execution.TopLevelDelegatedAccountAccessInput,
        ) ?evmz.execution.DelegatedAccountAccess {
            _ = input;
            return .{ .status = .cold, .gas = 100_001 };
        }
    };
    const ExpensiveTopLevelDelegatedAccess = evmz.Vm(evmz.eth.prague.extend(.{
        .call = .{ .topLevelDelegatedAccountAccess = overrides.topLevelDelegatedAccountAccess },
    }));
    const ExpensiveExecutor = ExpensiveTopLevelDelegatedAccess.Executor;
    const sender = evmz.addr(0x1111);
    const authority = evmz.addr(0x2222);
    const target = evmz.addr(0x3333);
    var observations = CodeObservation{
        .required = authority,
        .forbidden = target,
        .expected_code_reads = 1,
    };
    var executor = ExpensiveExecutor.init(std.testing.allocator, .{});
    defer executor.deinit();
    try putFundedSender(&executor, sender);

    var delegation_code: [eip7702.delegation_code_len]u8 = undefined;
    eip7702.writeDelegationCode(&delegation_code, target);
    var authority_account = MemoryAccount.init(std.testing.allocator);
    try authority_account.setCode(&delegation_code);
    try executor.state.seedAccount(authority, authority_account);

    var target_account = MemoryAccount.init(std.testing.allocator);
    try target_account.setCode(&.{evmz.Opcode.STOP.toByte()});
    try executor.state.seedAccount(target, target_account);

    const result = (try executor.runStandaloneObserved(
        testTxContext(sender, 100_000),
        .{ .call = .{
            .sender = sender,
            .recipient = authority,
        } },
        .legacy(100_000),
        &observations,
    )).expectCall();

    try std.testing.expectEqual(Interpreter.Status.out_of_gas, result.status);
    try std.testing.expectEqual(@as(usize, 1), observations.calls);
}

test "exact spec drives top-frame value transfer state gas" {
    const overrides = struct {
        fn topFrameValueTransferStateGas(
            input: evmz.execution.TopFrameValueTransferInput,
        ) i64 {
            return if (input.creates_account) 9 else 0;
        }
    };
    const ExpensiveTopFrameValueTransfer = evmz.Vm(evmz.eth.prague.extend(.{
        .call = .{ .topFrameValueTransferStateGas = overrides.topFrameValueTransferStateGas },
    }));

    const default_result = try executeTopFrameValueTransfer(Prague.specification);
    const custom_result = try executeTopFrameValueTransfer(ExpensiveTopFrameValueTransfer.specification);

    try std.testing.expectEqual(default_result.gas_left - 9, custom_result.gas_left);
    try std.testing.expectEqual(@as(i64, 9), custom_result.state_gas_spent);
    try std.testing.expectEqual(@as(i64, 9), custom_result.state_gas_from_gas_left);
}

test "exact spec drives empty call recipient touching" {
    const TouchEmptyCallRecipient = evmz.Vm(evmz.eth.spurious_dragon.extend(.{
        .call = .{ .touches_empty_recipient = true },
    }));

    try std.testing.expect(!try emptyCallRecipientMaterialized(SpuriousDragon.specification));
    try std.testing.expect(try emptyCallRecipientMaterialized(TouchEmptyCallRecipient.specification));
}

test "exact spec drives child call gas forwarding" {
    const overrides = struct {
        fn childGas(input: evmz.execution.ChildGasInput) evmz.execution.ChildGas {
            _ = input;
            return .{ .gas = 0 };
        }
    };
    const ZeroChildGas = evmz.Vm(evmz.eth.frontier.extend(.{
        .call = .{ .childGas = overrides.childGas },
    }));

    try std.testing.expectEqual(@as(u256, 1), try executeCallResultStore(Frontier.specification));
    try std.testing.expectEqual(@as(u256, 0), try executeCallResultStore(ZeroChildGas.specification));
}

test "exact spec drives create initcode word gas" {
    const overrides = struct {
        fn createInitCodeWordGas(is_create2: bool) i64 {
            _ = is_create2;
            return 1_000_000;
        }
    };
    const ExpensiveCreateInitCode = evmz.Vm(evmz.eth.cancun.extend(.{
        .create = .{ .initcodeWordGas = overrides.createInitCodeWordGas },
    }));

    try std.testing.expectEqual(Interpreter.Status.success, try executeCreateOpcodeStatus(Cancun.specification));
    try std.testing.expectEqual(Interpreter.Status.out_of_gas, try executeCreateOpcodeStatus(ExpensiveCreateInitCode.specification));
}

fn executeCreateOpcodeStatus(comptime spec: ExactSpec) !Interpreter.Status {
    const sender = evmz.addr(0x1111);
    const contract = evmz.addr(0xaaaa);
    const code = evmz.t.bytecode(.{
        .PUSH7, 0x36,    .PUSH0, .MSTORE8, 0x60,   0x01, .PUSH0, .RETURN,
        .PUSH0, .MSTORE, .PUSH1, 0x07,     .PUSH1, 0x19, .PUSH0, .CREATE,
        .STOP,
    });

    const Exec = Executor(spec);
    var executor = Exec.init(std.testing.allocator, .{});
    defer executor.deinit();
    try putFundedSender(&executor, sender);

    var contract_account = MemoryAccount.init(std.testing.allocator);
    try contract_account.setCode(&code);
    try executor.state.seedAccount(contract, contract_account);

    return (try executor.runStandalone(testTxContext(sender, 100_000), .{ .call = .{
        .sender = sender,
        .recipient = contract,
    } }, .legacy(100_000))).expectCall().status;
}

fn executeCallResultStore(comptime spec: ExactSpec) !u256 {
    const sender = evmz.addr(0x1111);
    const parent = evmz.addr(0xaaaa);
    const target = evmz.addr(0xbbbb);
    const Exec = Executor(spec);
    var executor = Exec.init(std.testing.allocator, .{});
    defer executor.deinit();

    try putFundedSender(&executor, sender);

    var target_account = MemoryAccount.init(std.testing.allocator);
    try target_account.setCode(&evmz.t.bytecode(.{ .PUSH1, 0x00, .BALANCE, .STOP }));
    try executor.state.seedAccount(target, target_account);

    const parent_code = evmz.t.bytecode(.{
        .PUSH1, 0x00,   .PUSH1, 0x00,    .PUSH1, 0x00,   .PUSH1, 0x00,
        .PUSH1, 0x00,   .PUSH2, 0xbb,    0xbb,   .PUSH2, 0xff,   0xff,
        .CALL,  .PUSH1, 0x00,   .SSTORE, .STOP,
    });
    var parent_account = MemoryAccount.init(std.testing.allocator);
    try parent_account.setCode(&parent_code);
    try executor.state.seedAccount(parent, parent_account);

    const result = (try executor.runStandalone(testTxContext(sender, 100_000), .{ .call = .{
        .sender = sender,
        .recipient = parent,
    } }, .legacy(100_000))).expectCall();

    try std.testing.expectEqual(Interpreter.Status.success, result.status);
    return executor.getStorage(parent, 0);
}

fn executeTopLevelDelegatedCall(comptime spec: ExactSpec) !i64 {
    const sender = evmz.addr(0x1111);
    const authority = evmz.addr(0x2222);
    const target = evmz.addr(0x3333);
    const tx_context = testTxContext(sender, 100_000);

    const Exec = Executor(spec);
    var executor = Exec.init(std.testing.allocator, .{});
    defer executor.deinit();
    try putFundedSender(&executor, sender);

    var delegation_code: [eip7702.delegation_code_len]u8 = undefined;
    eip7702.writeDelegationCode(&delegation_code, target);
    var authority_account = MemoryAccount.init(std.testing.allocator);
    try authority_account.setCode(&delegation_code);
    try executor.state.seedAccount(authority, authority_account);

    var target_account = MemoryAccount.init(std.testing.allocator);
    try target_account.setCode(&.{evmz.Opcode.STOP.toByte()});
    try executor.state.seedAccount(target, target_account);

    const result = (try executor.runStandalone(tx_context, .{ .call = .{
        .sender = sender,
        .recipient = authority,
    } }, .legacy(100_000))).expectCall();

    try std.testing.expectEqual(Interpreter.Status.success, result.status);
    return result.gas_left;
}

const CodeObservation = struct {
    required: Address,
    forbidden: ?Address = null,
    expected_code_reads: u32,
    calls: usize = 0,

    pub fn observe(
        self: *@This(),
        pending: TrackedState.PendingView,
    ) !void {
        self.calls += 1;
        const view = pending.observations();
        var code_reads: u32 = 0;
        var required_found = false;
        var index: u32 = 0;
        while (index < view.accounts.len()) : (index += 1) {
            const fact = view.accounts.at(index);
            if (!fact.observation.code_read) continue;
            code_reads += 1;
            if (std.mem.eql(u8, &fact.address, &self.required)) {
                required_found = true;
            }
            if (self.forbidden) |forbidden| {
                try std.testing.expect(!std.mem.eql(u8, &fact.address, &forbidden));
            }
        }

        try std.testing.expect(required_found);
        try std.testing.expectEqual(self.expected_code_reads, code_reads);
    }
};

const TopFrameValueTransferResult = struct {
    gas_left: i64,
    state_gas_spent: i64,
    state_gas_from_gas_left: i64,
};

fn executeTopFrameValueTransfer(comptime spec: ExactSpec) !TopFrameValueTransferResult {
    const sender = evmz.addr(0x1111);
    const recipient = evmz.addr(0x2222);
    const tx_context = testTxContext(sender, 100_000);

    const Exec = Executor(spec);
    var executor = Exec.init(std.testing.allocator, .{});
    defer executor.deinit();
    try putFundedSender(&executor, sender);

    const result = (try executor.runStandalone(tx_context, .{ .call = .{
        .sender = sender,
        .recipient = recipient,
        .value = 1,
    } }, .legacy(100_000))).expectCall();

    try std.testing.expectEqual(Interpreter.Status.success, result.status);
    return .{
        .gas_left = result.gas_left,
        .state_gas_spent = result.state_gas_spent,
        .state_gas_from_gas_left = result.state_gas_from_gas_left,
    };
}

fn emptyCallRecipientMaterialized(comptime spec: ExactSpec) !bool {
    const sender = evmz.addr(0x1111);
    const contract = evmz.addr(0x2222);
    const recipient = evmz.addr(0x3333);
    const tx_context = testTxContext(sender, 100_000);
    const code = evmz.t.bytecode(.{
        .PUSH1, 0x00,
        .PUSH1, 0x00,
        .PUSH1, 0x00,
        .PUSH1, 0x00,
        .PUSH1, 0x00,
        .PUSH2, 0x33,
        0x33,   .PUSH2,
        0x27,   0x10,
        .CALL,  .POP,
        .STOP,
    });

    const Exec = Executor(spec);
    var executor = Exec.init(std.testing.allocator, .{});
    defer executor.deinit();
    try putFundedSender(&executor, sender);

    var contract_account = MemoryAccount.init(std.testing.allocator);
    try contract_account.setCode(&code);
    try executor.state.seedAccount(contract, contract_account);

    const result = (try executor.runStandalone(tx_context, .{ .call = .{
        .sender = sender,
        .recipient = contract,
    } }, .legacy(100_000))).expectCall();

    try std.testing.expectEqual(Interpreter.Status.success, result.status);
    return executor.state.accountExists(recipient);
}

fn executeNestedBalanceCall(comptime spec: ExactSpec) !i64 {
    const sender = evmz.addr(0x1111);
    const parent = evmz.addr(0xaaaa);
    const target = evmz.addr(0xbbbb);
    var executor = Executor(spec).init(std.testing.allocator, .{});
    defer executor.deinit();

    var sender_account = MemoryAccount.init(std.testing.allocator);
    sender_account.balance = 1_000_000;
    try executor.state.seedAccount(sender, sender_account);

    var target_account = MemoryAccount.init(std.testing.allocator);
    try target_account.setCode(&evmz.t.bytecode(.{ .PUSH1, 0x00, .BALANCE, .STOP }));
    try executor.state.seedAccount(target, target_account);

    const parent_code = evmz.t.bytecode(.{
        .PUSH1, 0x00,  .PUSH1, 0x00, .PUSH1, 0x00,   .PUSH1, 0x00,
        .PUSH1, 0x00,  .PUSH2, 0xbb, 0xbb,   .PUSH2, 0xff,   0xff,
        .CALL,  .STOP,
    });
    var bytecode = try executor.prepareBytecode(&parent_code);
    defer bytecode.deinit(std.testing.allocator);

    try executor.beginTransaction(testTxContext(sender, 100_000), sender, parent);
    const result = try executor.executePreparedCallTransaction(.{
        .bytecode = &bytecode,
        .sender = sender,
        .recipient = parent,
        .gas = 100_000,
    });

    try std.testing.expectEqual(Interpreter.Status.success, result.status);
    return result.gas_left;
}

test "recursive call bomb unwinds with iterative call runtime" {
    const sender = evmz.addr(0x371c4d94cf9ed2e0cde964a748609b7c46ec3811);
    const contract = evmz.addr(0xd83874a1c62a78b10ae86b27b59b21c4d34f6d30);
    const tx_context = testTxContext(sender, 1_000_000);
    var executor = Cancun.Executor.init(std.testing.allocator, .{});
    defer executor.deinit();

    var sender_account = MemoryAccount.init(std.testing.allocator);
    sender_account.balance = 1_000_000_000_000_000_000;
    try executor.state.seedAccount(sender, sender_account);

    const code = evmz.t.bytecode(.{
        .PUSH1,  0x01,
        .PUSH1,  0x00,
        .SLOAD,  .ADD,
        .PUSH1,  0x00,
        .SSTORE, .PUSH1,
        0x00,    .PUSH1,
        0x00,    .PUSH1,
        0x00,    .PUSH1,
        0x00,    .PUSH1,
        0x00,    .ADDRESS,
        .PUSH1,  0xe0,
        .GAS,    .SUB,
        .CALL,   .PUSH1,
        0x01,    .SSTORE,
        .STOP,
    });
    var contract_account = MemoryAccount.init(std.testing.allocator);
    contract_account.balance = 20_000_000;
    try contract_account.setCode(&code);
    try executor.state.seedAccount(contract, contract_account);

    var bytecode = try executor.prepareBytecode(&code);
    defer bytecode.deinit(std.testing.allocator);

    try executor.beginTransaction(tx_context, sender, contract);
    const result = try executor.executePreparedCallTransaction(.{
        .bytecode = &bytecode,
        .sender = sender,
        .recipient = contract,
        .gas = 979_000,
        .value = 100_000,
    });

    try std.testing.expectEqual(Interpreter.Status.success, result.status);
    try std.testing.expectEqual(@as(u256, 0x12), try executor.getStorage(contract, 0));
    try std.testing.expectEqual(@as(u256, 1), try executor.getStorage(contract, 1));
}

test "iterative call runtime preserves precompile output" {
    const sender = evmz.addr(0x371c4d94cf9ed2e0cde964a748609b7c46ec3811);
    const contract = evmz.addr(0xd83874a1c62a78b10ae86b27b59b21c4d34f6d30);
    const tx_context = testTxContext(sender, 100_000);
    var executor = Cancun.Executor.init(std.testing.allocator, .{});
    defer executor.deinit();

    var sender_account = MemoryAccount.init(std.testing.allocator);
    sender_account.balance = 1_000_000_000_000_000_000;
    try executor.state.seedAccount(sender, sender_account);

    const code = evmz.t.bytecode(.{
        .PUSH1,  0x2a,
        .PUSH1,  0x00,
        .MSTORE, .PUSH1,
        0x20,    .PUSH1,
        0x00,    .PUSH1,
        0x20,    .PUSH1,
        0x00,    .PUSH1,
        0x00,    .PUSH1,
        0x04,    .PUSH2,
        0x27,    0x10,
        .CALL,   .POP,
        .PUSH1,  0x20,
        .PUSH1,  0x00,
        .RETURN,
    });
    var contract_account = MemoryAccount.init(std.testing.allocator);
    try contract_account.setCode(&code);
    try executor.state.seedAccount(contract, contract_account);

    var bytecode = try executor.prepareBytecode(&code);
    defer bytecode.deinit(std.testing.allocator);

    try executor.beginTransaction(tx_context, sender, contract);
    const result = try executor.executePreparedCallTransaction(.{
        .bytecode = &bytecode,
        .sender = sender,
        .recipient = contract,
        .gas = 90_000,
        .value = 0,
    });

    var expected: [32]u8 = .{0} ** 32;
    expected[31] = 0x2a;
    try std.testing.expectEqual(Interpreter.Status.success, result.status);
    try std.testing.expectEqualSlices(u8, &expected, result.output_data);
}

test "top-level call transaction executes precompile recipient" {
    const sender = evmz.addr(0x371c4d94cf9ed2e0cde964a748609b7c46ec3811);
    const precompile = evmz.precompile.Contract.identity.toAddress();
    const tx_context = testTxContext(sender, 100_000);
    const input = [_]u8{ 0xde, 0xad };
    var executor = Cancun.Executor.init(std.testing.allocator, .{});
    defer executor.deinit();

    var sender_account = MemoryAccount.init(std.testing.allocator);
    sender_account.balance = 1_000_000;
    try executor.state.seedAccount(sender, sender_account);

    try executor.beginTransaction(tx_context, sender, precompile);
    const result = try executor.executeCallTransaction(sender, precompile, &input, .legacy(1000), 7);

    try std.testing.expectEqual(Interpreter.Status.success, result.status);
    try std.testing.expectEqual(@as(i64, 982), result.gas_left);
    try std.testing.expectEqualSlices(u8, &input, result.output_data);
    try std.testing.expectEqual(@as(u256, 999_993), executor.getAccount(sender).?.balance);
    try std.testing.expectEqual(@as(u256, 7), executor.getAccount(precompile).?.balance);
}

test "legacy precompile calls materialize touched empty account until Spurious Dragon" {
    try expectLegacyPrecompileCall(Frontier, true, 64_922);
    try expectLegacyPrecompileCall(SpuriousDragon, false, 89_262);
}

fn expectLegacyPrecompileCall(
    comptime ExactVm: type,
    materialized: bool,
    gas_left: i64,
) !void {
    const sender = evmz.addr(0x371c4d94cf9ed2e0cde964a748609b7c46ec3811);
    const contract = evmz.addr(0xd83874a1c62a78b10ae86b27b59b21c4d34f6d30);
    const precompile = evmz.precompile.Contract.identity.toAddress();
    const code = evmz.t.bytecode(.{
        .PUSH1, 0x00,
        .PUSH1, 0x00,
        .PUSH1, 0x00,
        .PUSH1, 0x00,
        .PUSH1, 0x00,
        .PUSH1, 0x04,
        .PUSH2, 0x27,
        0x10,   .CALL,
        .POP,   .STOP,
    });
    const tx_context = testTxContext(sender, 100_000);
    var executor = ExactVm.Executor.init(std.testing.allocator, .{});
    defer executor.deinit();

    var sender_account = MemoryAccount.init(std.testing.allocator);
    sender_account.balance = 1_000_000_000_000_000_000;
    try executor.state.seedAccount(sender, sender_account);

    var contract_account = MemoryAccount.init(std.testing.allocator);
    try contract_account.setCode(&code);
    try executor.state.seedAccount(contract, contract_account);

    var bytecode = try executor.prepareBytecode(&code);
    defer bytecode.deinit(std.testing.allocator);

    try executor.beginTransaction(tx_context, sender, contract);
    const result = try executor.executePreparedCallTransaction(.{
        .bytecode = &bytecode,
        .sender = sender,
        .recipient = contract,
        .gas = 90_000,
        .value = 0,
    });

    try std.testing.expectEqual(Interpreter.Status.success, result.status);
    try std.testing.expectEqual(gas_left, result.gas_left);
    try std.testing.expectEqual(materialized, executor.getAccount(precompile) != null);
}

test "prepared call transaction calls to empty account succeed" {
    const sender = evmz.addr(0x371c4d94cf9ed2e0cde964a748609b7c46ec3811);
    const contract = evmz.addr(0xd83874a1c62a78b10ae86b27b59b21c4d34f6d30);
    const tx_context = testTxContext(sender, 100_000);
    const code = evmz.t.bytecode(.{
        .PUSH1, 0x00,
        .PUSH1, 0x00,
        .PUSH1, 0x00,
        .PUSH1, 0x00,
        .PUSH1, 0x00,
        .PUSH2, 0x12,
        0x34,   .GAS,
        .CALL,  .PUSH1,
        0x00,   .SSTORE,
        .STOP,
    });

    var executor = Cancun.Executor.init(std.testing.allocator, .{});
    defer executor.deinit();

    var sender_account = MemoryAccount.init(std.testing.allocator);
    sender_account.balance = 1_000_000_000_000_000_000;
    try executor.state.seedAccount(sender, sender_account);

    var contract_account = MemoryAccount.init(std.testing.allocator);
    try contract_account.setCode(&code);
    try executor.state.seedAccount(contract, contract_account);

    var bytecode = try executor.prepareBytecode(&code);
    defer bytecode.deinit(std.testing.allocator);

    try executor.beginTransaction(tx_context, sender, contract);
    const result = try executor.executePreparedCallTransaction(.{
        .bytecode = &bytecode,
        .sender = sender,
        .recipient = contract,
        .gas = 90_000,
        .value = 0,
    });

    try std.testing.expectEqual(Interpreter.Status.success, result.status);
    try std.testing.expectEqual(@as(u256, 1), try executor.getStorage(contract, 0));
}

test "iterative CALLCODE writes target code in caller storage" {
    const sender = evmz.addr(0x371c4d94cf9ed2e0cde964a748609b7c46ec3811);
    const contract = evmz.addr(0xd83874a1c62a78b10ae86b27b59b21c4d34f6d30);
    const target = evmz.addr(0xbeef);
    const tx_context = testTxContext(sender, 100_000);
    const code = evmz.t.bytecode(.{
        .PUSH0, .PUSH0, .PUSH0, .PUSH0, .PUSH0,
        .PUSH2, 0xbe,   0xef,   .GAS,   .CALLCODE,
        .STOP,
    });
    const target_code = evmz.t.bytecode(.{
        .PUSH1, 0xcc,
        .PUSH0, .SSTORE,
        .STOP,
    });

    var executor = Cancun.Executor.init(std.testing.allocator, .{});
    defer executor.deinit();

    var sender_account = MemoryAccount.init(std.testing.allocator);
    sender_account.balance = 1_000_000_000_000_000_000;
    try executor.state.seedAccount(sender, sender_account);

    var contract_account = MemoryAccount.init(std.testing.allocator);
    try contract_account.setCode(&code);
    try executor.state.seedAccount(contract, contract_account);

    var target_account = MemoryAccount.init(std.testing.allocator);
    try target_account.setCode(&target_code);
    try executor.state.seedAccount(target, target_account);

    var bytecode = try executor.prepareBytecode(&code);
    defer bytecode.deinit(std.testing.allocator);

    try executor.beginTransaction(tx_context, sender, contract);
    const result = try executor.executePreparedCallTransaction(.{
        .bytecode = &bytecode,
        .sender = sender,
        .recipient = contract,
        .gas = 120_000,
        .value = 0,
    });

    try std.testing.expectEqual(Interpreter.Status.success, result.status);
    try std.testing.expectEqual(@as(u256, 0xcc), try executor.getStorage(contract, 0));
    try std.testing.expectEqual(@as(u256, 0), try executor.getStorage(target, 0));
}

test "iterative DELEGATECALL preserves parent call value" {
    const sender = evmz.addr(0x371c4d94cf9ed2e0cde964a748609b7c46ec3811);
    const contract = evmz.addr(0xd83874a1c62a78b10ae86b27b59b21c4d34f6d30);
    const target = evmz.addr(0xbeef);
    const tx_context = testTxContext(sender, 100_000);
    const code = evmz.t.bytecode(.{
        .PUSH0,        .PUSH0, .PUSH0, .PUSH0,
        .PUSH2,        0xbe,   0xef,   .GAS,
        .DELEGATECALL, .STOP,
    });
    const target_code = evmz.t.bytecode(.{
        .CALLVALUE,
        .PUSH0,
        .SSTORE,
        .STOP,
    });

    var executor = Cancun.Executor.init(std.testing.allocator, .{});
    defer executor.deinit();

    var sender_account = MemoryAccount.init(std.testing.allocator);
    sender_account.balance = 1_000_000_000_000_000_000;
    try executor.state.seedAccount(sender, sender_account);

    var contract_account = MemoryAccount.init(std.testing.allocator);
    try contract_account.setCode(&code);
    try executor.state.seedAccount(contract, contract_account);

    var target_account = MemoryAccount.init(std.testing.allocator);
    try target_account.setCode(&target_code);
    try executor.state.seedAccount(target, target_account);

    var bytecode = try executor.prepareBytecode(&code);
    defer bytecode.deinit(std.testing.allocator);

    try executor.beginTransaction(tx_context, sender, contract);
    const result = try executor.executePreparedCallTransaction(.{
        .bytecode = &bytecode,
        .sender = sender,
        .recipient = contract,
        .gas = 120_000,
        .value = 0x2a,
    });

    try std.testing.expectEqual(Interpreter.Status.success, result.status);
    try std.testing.expectEqual(@as(u256, 0x2a), try executor.getStorage(contract, 0));
    try std.testing.expectEqual(@as(u256, 0), try executor.getStorage(target, 0));
}

test "iterative STATICCALL failure resumes parent with zero result" {
    const sender = evmz.addr(0x371c4d94cf9ed2e0cde964a748609b7c46ec3811);
    const contract = evmz.addr(0xd83874a1c62a78b10ae86b27b59b21c4d34f6d30);
    const target = evmz.addr(0xbeef);
    const tx_context = testTxContext(sender, 100_000);
    const code = evmz.t.bytecode(.{
        .PUSH0, .PUSH0,  .PUSH0,      .PUSH0,
        .PUSH2, 0xbe,    0xef,        .PUSH2,
        0x27,   0x10,    .STATICCALL, .PUSH1,
        0x01,   .SSTORE, .STOP,
    });
    const target_code = evmz.t.bytecode(.{
        .PUSH1, 0xdd,
        .PUSH0, .SSTORE,
        .STOP,
    });

    var executor = Cancun.Executor.init(std.testing.allocator, .{});
    defer executor.deinit();

    var sender_account = MemoryAccount.init(std.testing.allocator);
    sender_account.balance = 1_000_000_000_000_000_000;
    try executor.state.seedAccount(sender, sender_account);

    var contract_account = MemoryAccount.init(std.testing.allocator);
    try contract_account.setCode(&code);
    try contract_account.storage.put(1, 0x99);
    try executor.state.seedAccount(contract, contract_account);

    var target_account = MemoryAccount.init(std.testing.allocator);
    try target_account.setCode(&target_code);
    try executor.state.seedAccount(target, target_account);

    var bytecode = try executor.prepareBytecode(&code);
    defer bytecode.deinit(std.testing.allocator);

    try executor.beginTransaction(tx_context, sender, contract);
    const result = try executor.executePreparedCallTransaction(.{
        .bytecode = &bytecode,
        .sender = sender,
        .recipient = contract,
        .gas = 120_000,
        .value = 0,
    });

    try std.testing.expectEqual(Interpreter.Status.success, result.status);
    try std.testing.expectEqual(@as(u256, 0), try executor.getStorage(contract, 1));
    try std.testing.expectEqual(@as(u256, 0), try executor.getStorage(target, 0));
}

test "prepared call transaction create opcodes deploy code" {
    const sender = evmz.addr(0x371c4d94cf9ed2e0cde964a748609b7c46ec3811);
    const contract = evmz.addr(0xd83874a1c62a78b10ae86b27b59b21c4d34f6d30);
    const tx_context = testTxContext(sender, 100_000);
    const init_code = [_]u8{ 0x36, 0x5f, 0x53, 0x60, 0x01, 0x5f, 0xf3 };
    const create_address = evmz.address.create(contract, 0);
    const create2_address = evmz.address.create2(contract, 0x2a, &init_code);
    const code = evmz.t.bytecode(.{
        .PUSH7, 0x36,     .PUSH0, .MSTORE8, 0x60,    0x01,  .PUSH0, .RETURN,
        .PUSH0, .MSTORE,  .PUSH1, 0x07,     .PUSH1,  0x19,  .PUSH0, .CREATE,
        .PUSH0, .SSTORE,  .PUSH1, 0x2a,     .PUSH1,  0x07,  .PUSH1, 0x19,
        .PUSH0, .CREATE2, .PUSH1, 0x01,     .SSTORE, .STOP,
    });

    var executor = Cancun.Executor.init(std.testing.allocator, .{});
    defer executor.deinit();

    var sender_account = MemoryAccount.init(std.testing.allocator);
    sender_account.balance = 1_000_000_000_000_000_000;
    try executor.state.seedAccount(sender, sender_account);

    var contract_account = MemoryAccount.init(std.testing.allocator);
    try contract_account.setCode(&code);
    try executor.state.seedAccount(contract, contract_account);

    var bytecode = try executor.prepareBytecode(&code);
    defer bytecode.deinit(std.testing.allocator);

    try executor.beginTransaction(tx_context, sender, contract);
    const result = try executor.executePreparedCallTransaction(.{
        .bytecode = &bytecode,
        .sender = sender,
        .recipient = contract,
        .gas = 300_000,
        .value = 0,
    });

    try std.testing.expectEqual(Interpreter.Status.success, result.status);
    try std.testing.expectEqual(evmz.address.toU256(create_address), try executor.getStorage(contract, 0));
    try std.testing.expectEqual(evmz.address.toU256(create2_address), try executor.getStorage(contract, 1));
    try std.testing.expectEqualSlices(u8, &.{0x00}, try executor.getCode(create_address));
    try std.testing.expectEqualSlices(u8, &.{0x00}, try executor.getCode(create2_address));
}

test "CREATE2 insufficient balance does not bump creator nonce" {
    const sender = evmz.addr(0x0343505c9f9bda06ff73c96183434ffd23442073);
    const contract = evmz.addr(0xbba624a7e00e22fd18816e2e0e1f4f396ce3409c);
    const tx_context = testTxContext(sender, 100_000);
    const create2_address = evmz.address.create2(contract, 0, &.{});
    const code = evmz.t.bytecode(.{
        .PUSH0, .PUSH0, .PUSH0, .GAS, .CREATE2, .STOP,
    });

    var executor = Cancun.Executor.init(std.testing.allocator, .{});
    defer executor.deinit();

    var sender_account = MemoryAccount.init(std.testing.allocator);
    sender_account.balance = 1_000_000;
    try executor.state.seedAccount(sender, sender_account);

    var contract_account = MemoryAccount.init(std.testing.allocator);
    contract_account.nonce = 1;
    try contract_account.setCode(&code);
    try executor.state.seedAccount(contract, contract_account);

    var bytecode = try executor.prepareBytecode(&code);
    defer bytecode.deinit(std.testing.allocator);

    try executor.beginTransaction(tx_context, sender, contract);
    const result = try executor.executePreparedCallTransaction(.{
        .bytecode = &bytecode,
        .sender = sender,
        .recipient = contract,
        .gas = 100_000,
        .value = 0,
    });

    try std.testing.expectEqual(Interpreter.Status.success, result.status);
    try std.testing.expectEqual(@as(u64, 1), executor.getAccount(contract).?.nonce);
    try std.testing.expect(!executor.state.isAccountWarm(create2_address));
}

test "captured runtime records nested call and create frames without generic stepping" {
    const sender = evmz.addr(0x371c4d94cf9ed2e0cde964a748609b7c46ec3811);
    const contract = evmz.addr(0xd83874a1c62a78b10ae86b27b59b21c4d34f6d30);
    const child = evmz.addr(0x1234);
    const tx_context = testTxContext(sender, 100_000);
    const create_address = evmz.address.create(contract, 0);
    const code = evmz.t.bytecode(.{
        .PUSH0, .PUSH0, .PUSH0,  .PUSH0, .PUSH0,  .PUSH2, 0x12,     0x34,
        .GAS,   .CALL,  .POP,    .PUSH7, 0x36,    .PUSH0, .MSTORE8, 0x60,
        0x01,   .PUSH0, .RETURN, .PUSH0, .MSTORE, .PUSH1, 0x07,     .PUSH1,
        0x19,   .PUSH0, .CREATE, .STOP,
    });

    var tape = trace.TraceTape.initGrowable(std.testing.allocator);
    defer tape.deinit();
    var capture = CaptureContext.init(std.testing.allocator, .{ .tape = &tape });
    defer capture.deinit();
    var executor = Cancun.Executor.init(std.testing.allocator, .{});
    defer executor.deinit();
    var sender_account = MemoryAccount.init(std.testing.allocator);
    sender_account.balance = 1_000_000_000_000_000_000;
    try executor.state.seedAccount(sender, sender_account);

    var contract_account = MemoryAccount.init(std.testing.allocator);
    try contract_account.setCode(&code);
    try executor.state.seedAccount(contract, contract_account);

    var child_account = MemoryAccount.init(std.testing.allocator);
    try child_account.setCode(&.{@intFromEnum(evmz.Opcode.STOP)});
    try executor.state.seedAccount(child, child_account);

    var bytecode = try executor.prepareBytecode(&code);
    defer bytecode.deinit(std.testing.allocator);

    try capture.begin();
    errdefer capture.abort() catch {};
    try executor.beginCapturedTransaction(tx_context, sender, contract, &capture);
    const result = try executor.executePreparedCallTransaction(.{
        .bytecode = &bytecode,
        .sender = sender,
        .recipient = contract,
        .gas = 300_000,
        .value = 0,
    });
    const span = (try capture.finish()).?;
    defer tape.resolve(span) catch unreachable;

    try std.testing.expectEqual(Interpreter.Status.success, result.status);
    try std.testing.expectEqual(@as(usize, 3), span.frames.len);
    try std.testing.expectEqual(trace.TraceFrameKind.root, span.frames[0].kind);
    try std.testing.expectEqual(@as(?u32, 0), span.frames[1].parent_frame_id);
    try std.testing.expectEqual(trace.TraceFrameKind.call, span.frames[1].kind);
    try std.testing.expectEqual(@as(?u32, 0), span.frames[2].parent_frame_id);
    try std.testing.expectEqual(trace.TraceFrameKind.create, span.frames[2].kind);
    for (span.frames) |frame_row| {
        try std.testing.expectEqual(trace.TraceFrameOutcome.success, frame_row.outcome);
    }

    var call_index: ?usize = null;
    var call_child_index: ?usize = null;
    var create_index: ?usize = null;
    var create_child_index: ?usize = null;
    for (span.steps, 0..) |step, index| {
        if (step.frame_id == 0 and step.opcode == @intFromEnum(evmz.Opcode.CALL)) call_index = index;
        if (step.frame_id == 1) call_child_index = index;
        if (step.frame_id == 0 and step.opcode == @intFromEnum(evmz.Opcode.CREATE)) create_index = index;
        if (step.frame_id == 2) create_child_index = index;
    }
    try std.testing.expect(call_index.? < call_child_index.?);
    try std.testing.expect(create_index.? < create_child_index.?);
    try std.testing.expect(span.steps[call_index.?].pc_next > span.steps[call_index.?].pc);
    try std.testing.expect(span.steps[create_index.?].pc_next > span.steps[create_index.?].pc);

    var replay = StepOrderRecorder{};
    try replay.consume(span);
    const replay_call_start = replay.firstIndex(.start, .CALL, 0).?;
    const replay_call_end = replay.firstIndex(.end, .CALL, 0).?;
    try std.testing.expect(replay.hasDepthStartBetween(1, replay_call_start, replay_call_end));
    try std.testing.expectEqual(@as(u256, 1), replay.events[replay_call_end].stack_top.?);
    const replay_create_start = replay.firstIndex(.start, .CREATE, 0).?;
    const replay_create_end = replay.firstIndex(.end, .CREATE, 0).?;
    try std.testing.expect(replay.hasDepthStartBetween(1, replay_create_start, replay_create_end));
    try std.testing.expectEqual(evmz.address.toU256(create_address), replay.events[replay_create_end].stack_top.?);
}

test "captured span is inspectable before executed transaction resolution" {
    const sender = evmz.addr(0xaaaa);
    const contract = evmz.addr(0xbbbb);
    const tx_context = testTxContext(sender, 100_000);
    var executor = Osaka.Executor.init(std.testing.allocator, .{});
    defer executor.deinit();

    var sender_account = MemoryAccount.init(std.testing.allocator);
    sender_account.balance = 1_000_000;
    try executor.state.seedAccount(sender, sender_account);
    var contract_account = MemoryAccount.init(std.testing.allocator);
    try contract_account.setCode(&.{ 0x60, 0x2a, 0x5f, 0x55, 0x00 });
    try executor.state.seedAccount(contract, contract_account);

    var tape = trace.TraceTape.initGrowable(std.testing.allocator);
    defer tape.deinit();
    var capture = CaptureContext.init(std.testing.allocator, .{ .tape = &tape });
    defer capture.deinit();
    const request_value = execution_values.EvmExecutionRequest{
        .context = context_adapter.fromHost(tx_context),
        .message = .{ .call = .{
            .sender = sender,
            .recipient = contract,
        } },
        .gas = .legacy(100_000),
    };
    try capture.begin();
    const attempt = try executor.beginCapturedTransactionAttempt(
        request_value,
        .{},
        &capture,
    );
    defer attempt.discardIfCurrent();
    const result = try attempt.executeRequest(request_value);
    try std.testing.expectEqual(Interpreter.Status.success, result.status);
    const executed = attempt.finish();
    defer executed.discardIfCurrent();

    const span = (try capture.finish()).?;
    try std.testing.expect(span.steps.len > 0);
    try std.testing.expectEqual(@as(u8, @intFromEnum(evmz.Opcode.SSTORE)), span.steps[2].opcode);
    try std.testing.expectEqual(@as(u256, 0x2a), try executor.getStorage(contract, 0));

    try executed.discard();
    try std.testing.expectEqual(@as(u256, 0), try executor.getStorage(contract, 0));
    try tape.resolve(span);
}

test "transaction attempt owns rollback before pending state" {
    const sender = evmz.addr(0xaaaa);
    const recipient = evmz.addr(0xbbbb);
    const request = execution_values.EvmExecutionRequest{
        .context = .{
            .chain = .{ .chain_id = 1 },
            .transaction = .{ .origin = sender },
        },
        .message = .{ .call = .{
            .sender = sender,
            .recipient = recipient,
        } },
        .gas = .legacy(100_000),
    };
    var executor = Cancun.Executor.init(std.testing.allocator, .{});
    defer executor.deinit();

    const first = try executor.beginTransactionAttempt(request, .{});
    const first_generation = first.generation;
    try first.addBalance(sender, 9);
    try std.testing.expectEqual(@as(u256, 9), try first.balance(sender));

    try first.discard();
    try std.testing.expectEqual(@as(u256, 0), try executor.getBalance(sender));
    try std.testing.expect(!executor.hasCurrentTransaction());

    const second = try executor.beginTransactionAttempt(request, .{});
    defer second.discardIfCurrent();
    try std.testing.expect(first_generation != second.generation);
}

test "transaction attempt finishes into pending state" {
    const sender = evmz.addr(0xaaaa);
    const recipient = evmz.addr(0xbbbb);
    const request = execution_values.EvmExecutionRequest{
        .context = .{
            .chain = .{ .chain_id = 1 },
            .transaction = .{ .origin = sender },
        },
        .message = .{ .call = .{
            .sender = sender,
            .recipient = recipient,
        } },
        .gas = .legacy(100_000),
    };
    var executor = Cancun.Executor.init(std.testing.allocator, .{});
    defer executor.deinit();

    const attempt = try executor.beginTransactionAttempt(request, .{});
    try attempt.addBalance(sender, 7);
    const executed = attempt.finish();
    try executed.retain();
    try std.testing.expectEqual(@as(u256, 7), try executor.getBalance(sender));
    try std.testing.expect(!executor.hasCurrentTransaction());
}

test "transaction nonce intent survives payload rollback" {
    const sender = evmz.addr(0xaaaa);
    const contract = evmz.addr(0xbbbb);
    const request = execution_values.EvmExecutionRequest{
        .context = .{
            .chain = .{ .chain_id = 1 },
            .transaction = .{ .origin = sender },
        },
        .message = .{ .call = .{
            .sender = sender,
            .recipient = contract,
        } },
        .gas = .legacy(100_000),
    };
    var executor = Cancun.Executor.init(std.testing.allocator, .{});
    defer executor.deinit();

    var sender_account = MemoryAccount.init(std.testing.allocator);
    sender_account.nonce = 7;
    try executor.state.seedAccount(sender, sender_account);
    const revert_code = evmz.t.bytecode(.{
        .PUSH0, .PUSH0, .REVERT,
    });
    var contract_account = MemoryAccount.init(std.testing.allocator);
    try contract_account.setCode(&revert_code);
    try executor.state.seedAccount(contract, contract_account);

    const attempt = try executor.beginTransactionAttemptLifetime();
    defer attempt.discardIfCurrent();
    try attempt.beginExecution(request, .{});
    const nonce_intent = try attempt.advanceTransactionNonce(request.message);
    const outcome = try attempt.runPayload(request);
    try std.testing.expectEqual(Interpreter.Status.revert, outcome.result.status);
    try std.testing.expectEqual(@as(u64, 8), (try attempt.accountSummary(sender)).?.nonce);

    nonce_intent.complete();
    const executed = attempt.finish();
    try executed.retain();
    try std.testing.expectEqual(@as(u64, 8), (try executor.getAccountOrLoad(sender)).?.nonce);
}

test "transaction nonce intent completion remains recorded for the attempt" {
    const sender = evmz.addr(0xaaaa);
    const recipient = evmz.addr(0xbbbb);
    const request = execution_values.EvmExecutionRequest{
        .context = .{
            .chain = .{ .chain_id = 1 },
            .transaction = .{ .origin = sender },
        },
        .message = .{ .call = .{
            .sender = sender,
            .recipient = recipient,
        } },
        .gas = .legacy(100_000),
    };
    var executor = Cancun.Executor.init(std.testing.allocator, .{});
    defer executor.deinit();

    var sender_account = MemoryAccount.init(std.testing.allocator);
    sender_account.nonce = 7;
    try executor.state.seedAccount(sender, sender_account);

    const first_attempt = try executor.beginTransactionAttemptLifetime();
    try first_attempt.beginExecution(request, .{});
    const first_intent = try first_attempt.advanceTransactionNonce(request.message);
    first_intent.complete();
    try std.testing.expectEqual(
        .completed,
        std.meta.activeTag(executor.current_transaction_attempt.?.nonce_intent),
    );
    try std.testing.expectEqual(@as(u64, 8), (try first_attempt.accountSummary(sender)).?.nonce);
    try first_attempt.discard();

    const second_attempt = try executor.beginTransactionAttemptLifetime();
    defer second_attempt.discardIfCurrent();
    try second_attempt.beginExecution(request, .{});
    const current_intent = try second_attempt.advanceTransactionNonce(request.message);
    current_intent.complete();
    try std.testing.expectEqual(@as(u64, 8), (try second_attempt.accountSummary(sender)).?.nonce);
}

test "transaction nonce intent selects the after-advance root create entry" {
    const sender = evmz.addr(0xaaaa);
    const recipient = evmz.address.create(sender, 7);
    const request = execution_values.EvmExecutionRequest{
        .context = .{
            .chain = .{ .chain_id = 1 },
            .transaction = .{ .origin = sender },
        },
        .message = .{
            .create = .{
                .sender = sender,
                .recipient = recipient,
                // PUSH0 PUSH0 RETURN deploys empty runtime code.
                .init_code = &.{ 0x5f, 0x5f, 0xf3 },
            },
        },
        .gas = .legacy(100_000),
    };
    var executor = Cancun.Executor.init(std.testing.allocator, .{});
    defer executor.deinit();

    var sender_account = MemoryAccount.init(std.testing.allocator);
    sender_account.nonce = 7;
    try executor.state.seedAccount(sender, sender_account);

    const attempt = try executor.beginTransactionAttemptLifetime();
    defer attempt.discardIfCurrent();
    try attempt.beginExecution(request, .{});
    const nonce_intent = try attempt.advanceTransactionNonce(request.message);
    const outcome = try attempt.runPayload(request);
    try std.testing.expectEqual(Interpreter.Status.success, outcome.result.status);
    try std.testing.expectEqual(@as(u64, 8), (try attempt.accountSummary(sender)).?.nonce);

    nonce_intent.complete();
    try attempt.finalizeState();
    const executed = attempt.finish();
    try executed.retain();
    try std.testing.expectEqual(@as(u64, 8), (try executor.getAccountOrLoad(sender)).?.nonce);
}

test "transaction nonce intent leaves max-nonce acceptance to transaction policy" {
    const sender = evmz.addr(0xaaaa);
    const max_nonce = std.math.maxInt(u64);
    const recipient = evmz.address.create(sender, max_nonce);
    const request = execution_values.EvmExecutionRequest{
        .context = .{
            .chain = .{ .chain_id = 1 },
            .transaction = .{ .origin = sender },
        },
        .message = .{
            .create = .{
                .sender = sender,
                .recipient = recipient,
                .init_code = &.{ 0x5f, 0x5f, 0xf3 },
            },
        },
        .gas = .legacy(100_000),
    };
    var executor = Cancun.Executor.init(std.testing.allocator, .{});
    defer executor.deinit();

    var sender_account = MemoryAccount.init(std.testing.allocator);
    sender_account.nonce = max_nonce;
    try executor.state.seedAccount(sender, sender_account);

    const attempt = try executor.beginTransactionAttemptLifetime();
    defer attempt.discardIfCurrent();
    try attempt.beginExecution(request, .{});
    const nonce_intent = try attempt.advanceTransactionNonce(request.message);
    const outcome = try attempt.runPayload(request);
    try std.testing.expectEqual(Interpreter.Status.success, outcome.result.status);
    try std.testing.expectEqual(max_nonce, (try attempt.accountSummary(sender)).?.nonce);

    nonce_intent.complete();
    try attempt.finalizeState();
    const executed = attempt.finish();
    try executed.retain();
    try std.testing.expectEqual(max_nonce, (try executor.getAccountOrLoad(sender)).?.nonce);
}

test "transaction attempt runPayload resolves only its inner checkpoint" {
    const sender = evmz.addr(0xaaaa);
    const contract = evmz.addr(0xbbbb);
    const request = execution_values.EvmExecutionRequest{
        .context = .{
            .chain = .{ .chain_id = 1 },
            .transaction = .{ .origin = sender },
        },
        .message = .{ .call = .{
            .sender = sender,
            .recipient = contract,
        } },
        .gas = .legacy(100_000),
    };

    {
        var executor = Cancun.Executor.init(std.testing.allocator, .{});
        defer executor.deinit();

        const revert_code = evmz.t.bytecode(.{
            .PUSH1, 0x2a,   .PUSH0,  .SSTORE,
            .PUSH0, .PUSH0, .REVERT,
        });
        var contract_account = MemoryAccount.init(std.testing.allocator);
        try contract_account.setCode(&revert_code);
        try executor.state.seedAccount(contract, contract_account);

        const attempt = try executor.beginTransactionAttemptLifetime();
        defer attempt.discardIfCurrent();
        try attempt.addBalance(sender, 7);
        try attempt.beginExecution(request, .{});

        var preparation_checkpoint = try attempt.checkpoint();
        defer preparation_checkpoint.deinit();
        try attempt.addBalance(sender, 5);

        const outcome = try attempt.runPayload(request);
        try std.testing.expectEqual(TransactionExecutionStage.payload, outcome.stage);
        try std.testing.expectEqual(Interpreter.Status.revert, outcome.result.status);
        try std.testing.expectEqual(@as(u256, 0), try executor.getStorage(contract, 0));
        try std.testing.expectEqual(@as(u256, 12), try attempt.balance(sender));

        try preparation_checkpoint.commit();
        const executed = attempt.finish();
        try executed.retain();
        try std.testing.expectEqual(@as(u256, 12), try executor.getBalance(sender));
    }

    {
        var executor = Cancun.Executor.init(std.testing.allocator, .{});
        defer executor.deinit();

        const success_code = evmz.t.bytecode(.{
            .PUSH1, 0x2a, .PUSH0, .SSTORE, .STOP,
        });
        var contract_account = MemoryAccount.init(std.testing.allocator);
        try contract_account.setCode(&success_code);
        try executor.state.seedAccount(contract, contract_account);

        const attempt = try executor.beginTransactionAttemptLifetime();
        defer attempt.discardIfCurrent();
        try attempt.addBalance(sender, 7);
        try attempt.beginExecution(request, .{});

        const outcome = try attempt.runPayload(request);
        try std.testing.expectEqual(TransactionExecutionStage.payload, outcome.stage);
        try std.testing.expectEqual(Interpreter.Status.success, outcome.result.status);
        try std.testing.expectEqual(@as(u256, 0x2a), try executor.getStorage(contract, 0));
        try std.testing.expectEqual(@as(u256, 7), try attempt.balance(sender));

        try attempt.finalizeState();
        const executed = attempt.finish();
        try executed.retain();
        try std.testing.expectEqual(@as(u256, 0x2a), try executor.getStorage(contract, 0));
    }
}

test "top-level transaction execution requires begin tx context" {
    var executor = Berlin.Executor.init(std.testing.allocator, .{});
    defer executor.deinit();

    try std.testing.expectError(
        error.MissingTxContext,
        executor.executeCallTransaction(evmz.addr(0xaaaa), evmz.addr(0xbbbb), &.{}, .legacy(100_000), 0),
    );
    var amsterdam_executor = Amsterdam.Executor.init(std.testing.allocator, .{});
    defer amsterdam_executor.deinit();
    try std.testing.expectError(
        error.MissingTxContext,
        amsterdam_executor.executeCallTransaction(evmz.addr(0xaaaa), evmz.addr(0xbbbb), &.{}, .{
            .regular_left = evmz.eth.transaction.amsterdam_new_account_state_gas - 1,
        }, 1),
    );
    try std.testing.expectError(
        error.MissingTxContext,
        executor.executeCreateTransaction(
            evmz.addr(0xaaaa),
            evmz.address.create(evmz.addr(0xaaaa), 0),
            &.{},
            .legacy(100_000),
            0,
        ),
    );
    try std.testing.expectError(
        error.MissingTxContext,
        executor.executeCall(.{
            .sender = evmz.addr(0xaaaa),
            .recipient = evmz.addr(0xbbbb),
        }, .legacy(100_000)),
    );
    try std.testing.expectError(
        error.MissingTxContext,
        executor.executeCreate(.{
            .sender = evmz.addr(0xaaaa),
            .recipient = evmz.address.create(evmz.addr(0xaaaa), 0),
            .init_code = &.{},
        }, .legacy(100_000)),
    );
}

test "rollback transaction restores branch checkpoint and closes tx context" {
    const sender = evmz.addr(0xaaaa);
    const contract = evmz.addr(0xbbbb);
    const tx_context = testTxContext(sender, 100_000);
    var executor = Berlin.Executor.init(std.testing.allocator, .{});
    defer executor.deinit();

    try executor.state.seedAccount(contract, MemoryAccount.init(std.testing.allocator));

    try executor.beginTransaction(tx_context, sender, contract);
    var pre_execution = try executor.branchCheckpoint();
    defer pre_execution.deinit();

    try std.testing.expectEqual(Host.StorageStatus.added, try executor.state.setStorage(contract, 7, 2));
    try std.testing.expectEqual(@as(u256, 2), try executor.getStorage(contract, 7));

    try executor.rollbackTransaction(&pre_execution);

    try std.testing.expectEqual(@as(u256, 0), try executor.getStorage(contract, 7));
    try std.testing.expectEqual(@as(usize, 0), executor.state.journalEntryCount());
    try std.testing.expect(executor.execution_context == null);
}

test "executor executes top-level create transaction" {
    const sender = evmz.addr(0xaaaa);
    const tx_context = testTxContext(sender, 100_000);
    var executor = Berlin.Executor.init(std.testing.allocator, .{});
    defer executor.deinit();

    var sender_account = MemoryAccount.init(std.testing.allocator);
    sender_account.balance = 1_000_000;
    try executor.state.seedAccount(sender, sender_account);

    const init_code = &.{ 0x60, 0x00, 0x60, 0x00, 0x53, 0x60, 0x01, 0x60, 0x00, 0xf3 };
    const create_address = evmz.address.create(sender, 0);

    try executor.beginCreateTransaction(tx_context, sender);
    const result = (try executor.executeCreate(.{
        .sender = sender,
        .recipient = create_address,
        .init_code = init_code,
    }, .legacy(100_000))).expectCreate();

    try std.testing.expectEqual(Interpreter.Status.success, result.status);
    try std.testing.expectEqualSlices(u8, &create_address, &result.address);
    try std.testing.expectEqual(@as(u64, 1), executor.getAccount(sender).?.nonce);
    try std.testing.expectEqualSlices(u8, &.{0x00}, try executor.getCode(create_address));
}

fn expectTransferLog(event_log: Host.Log, from: Address, to: Address, amount: u256) !void {
    try std.testing.expectEqualSlices(u8, &evmz.eth.system_address, &event_log.address);
    try std.testing.expectEqual(@as(usize, 3), event_log.topics.len);
    try std.testing.expectEqual(evmz.eth.value_transfer_log_topic, event_log.topics[0]);
    try std.testing.expectEqual(evmz.address.toU256(from), event_log.topics[1]);
    try std.testing.expectEqual(evmz.address.toU256(to), event_log.topics[2]);
    try std.testing.expectEqual(@as(usize, 32), event_log.data.len);
    var expected_data: [32]u8 = undefined;
    std.mem.writeInt(u256, &expected_data, amount, .big);
    try std.testing.expectEqualSlices(u8, &expected_data, event_log.data);
}

test "Amsterdam value transaction emits transfer log" {
    const sender = evmz.addr(0xaaaa);
    const recipient = evmz.addr(0xbbbb);
    var executor = Amsterdam.Executor.init(std.testing.allocator, .{});
    defer executor.deinit();

    var sender_account = MemoryAccount.init(std.testing.allocator);
    sender_account.balance = 1_000_000;
    try executor.state.seedAccount(sender, sender_account);

    try executor.beginTransaction(testTxContext(sender, 100_000), sender, recipient);
    const result = try executor.executeCallTransaction(sender, recipient, &.{}, .{
        .regular_left = 50_000,
        .reservoir = evmz.eth.transaction.amsterdam_new_account_state_gas,
    }, 7);

    try std.testing.expectEqual(Interpreter.Status.success, result.status);
    try std.testing.expectEqual(@as(usize, 1), executor.logs().len());
    try expectTransferLog(executor.logs().get(0), sender, recipient, 7);
}

test "Osaka value transaction does not emit transfer log" {
    const sender = evmz.addr(0xaaaa);
    const recipient = evmz.addr(0xbbbb);
    var executor = Osaka.Executor.init(std.testing.allocator, .{});
    defer executor.deinit();

    var sender_account = MemoryAccount.init(std.testing.allocator);
    sender_account.balance = 1_000_000;
    try executor.state.seedAccount(sender, sender_account);

    try executor.beginTransaction(testTxContext(sender, 100_000), sender, recipient);
    const result = try executor.executeCallTransaction(sender, recipient, &.{}, .legacy(50_000), 7);

    try std.testing.expectEqual(Interpreter.Status.success, result.status);
    try std.testing.expectEqual(@as(usize, 0), executor.logs().len());
}

test "Amsterdam nested CALL transfer log rolls back on revert" {
    const sender = evmz.addr(0xaaaa);
    const contract = evmz.addr(0xbbbb);
    const recipient = evmz.addr(0xcccc);
    const code = evmz.t.bytecode(.{
        .PUSH0, .PUSH0, .PUSH0,  .PUSH0, .PUSH1, 0x07, .PUSH2, 0xcc, 0xcc, .PUSH2, 0x27, 0x10, .CALL,
        .PUSH0, .PUSH0, .REVERT,
    });

    var executor = Amsterdam.Executor.init(std.testing.allocator, .{});
    defer executor.deinit();

    var sender_account = MemoryAccount.init(std.testing.allocator);
    sender_account.balance = 1_000_000;
    try executor.state.seedAccount(sender, sender_account);

    var contract_account = MemoryAccount.init(std.testing.allocator);
    contract_account.balance = 100;
    try contract_account.setCode(&code);
    try executor.state.seedAccount(contract, contract_account);

    const result = (try executor.runStandalone(testTxContext(sender, 100_000), .{ .call = .{
        .sender = sender,
        .recipient = contract,
    } }, .{
        .regular_left = 90_000,
        .reservoir = evmz.eth.transaction.amsterdam_new_account_state_gas,
    })).expectCall();

    try std.testing.expectEqual(Interpreter.Status.revert, result.status);
    try std.testing.expectEqual(@as(usize, 0), executor.logs().len());
    try std.testing.expectEqual(@as(u256, 0), try executor.state.getBalance(recipient));
}

test "Amsterdam CREATE endowment emits transfer log" {
    const sender = evmz.addr(0xaaaa);
    const contract = evmz.addr(0xbbbb);
    const create_address = evmz.address.create(contract, 0);
    const code = evmz.t.bytecode(.{
        .PUSH1, 0x00, .PUSH1, 0x00, .PUSH1, 0x07, .CREATE, .POP, .STOP,
    });

    var executor = Amsterdam.Executor.init(std.testing.allocator, .{});
    defer executor.deinit();

    var sender_account = MemoryAccount.init(std.testing.allocator);
    sender_account.balance = 1_000_000;
    try executor.state.seedAccount(sender, sender_account);

    var contract_account = MemoryAccount.init(std.testing.allocator);
    contract_account.balance = 100;
    try contract_account.setCode(&code);
    try executor.state.seedAccount(contract, contract_account);

    try executor.beginTransaction(testTxContext(sender, 100_000), sender, contract);
    const result = try executor.executeCallTransaction(sender, contract, &.{}, .{
        .regular_left = 90_000,
        .reservoir = evmz.eth.transaction.amsterdam_new_account_state_gas,
    }, 0);

    try std.testing.expectEqual(Interpreter.Status.success, result.status);
    try std.testing.expectEqual(@as(usize, 1), executor.logs().len());
    try expectTransferLog(executor.logs().get(0), contract, create_address, 7);
}

test "Amsterdam SELFDESTRUCT transfer emits transfer log" {
    const sender = evmz.addr(0xaaaa);
    const contract = evmz.addr(0xbbbb);
    const beneficiary = evmz.addr(0xcccc);
    const code = evmz.t.bytecode(.{ .PUSH2, 0xcc, 0xcc, .SELFDESTRUCT });

    var executor = Amsterdam.Executor.init(std.testing.allocator, .{});
    defer executor.deinit();

    var sender_account = MemoryAccount.init(std.testing.allocator);
    sender_account.balance = 1_000_000;
    try executor.state.seedAccount(sender, sender_account);

    var contract_account = MemoryAccount.init(std.testing.allocator);
    contract_account.balance = 7;
    try contract_account.setCode(&code);
    try executor.state.seedAccount(contract, contract_account);

    try executor.beginTransaction(testTxContext(sender, 100_000), sender, contract);
    const result = try executor.executeCallTransaction(sender, contract, &.{}, .{
        .regular_left = 90_000,
        .reservoir = evmz.eth.transaction.amsterdam_new_account_state_gas,
    }, 0);

    try std.testing.expectEqual(Interpreter.Status.success, result.status);
    try std.testing.expectEqual(@as(usize, 1), executor.logs().len());
    try expectTransferLog(executor.logs().get(0), contract, beneficiary, 7);
}

fn initCodeReturningRuntimeSize(size: u32) [6]u8 {
    return .{
        evmz.Opcode.PUSH3.toByte(),
        @as(u8, @intCast(size >> 16)),
        @as(u8, @intCast((size >> 8) & 0xff)),
        @as(u8, @intCast(size & 0xff)),
        evmz.Opcode.PUSH0.toByte(),
        evmz.Opcode.RETURN.toByte(),
    };
}

fn putFundedSender(executor: anytype, sender: Address) !void {
    var sender_account = MemoryAccount.init(std.testing.allocator);
    sender_account.balance = 100_000_000;
    try executor.state.seedAccount(sender, sender_account);
}

test "Amsterdam raises create runtime code size limit" {
    const sender = evmz.addr(0xaaaa);
    const tx_context = testTxContext(sender, 20_000_000);
    const default_max_code_size = evmz.eth.osaka.create.code_size_limit.?;
    const oversized_osaka = initCodeReturningRuntimeSize(default_max_code_size + 1);
    const oversized_amsterdam = initCodeReturningRuntimeSize(evmz.eth.amsterdam.create.code_size_limit.? + 1);

    var osaka = Osaka.Executor.init(std.testing.allocator, .{});
    defer osaka.deinit();
    try putFundedSender(&osaka, sender);

    const osaka_result = (try osaka.runStandalone(tx_context, .{ .create = .{
        .sender = sender,
        .recipient = evmz.address.create(sender, 0),
        .init_code = &oversized_osaka,
    } }, .legacy(20_000_000))).expectCreate();
    try std.testing.expectEqual(Interpreter.Status.out_of_gas, osaka_result.status);
    try std.testing.expectEqual(evmz.execution.TerminalCause.max_code_size_exceeded, osaka_result.cause.?);
    try std.testing.expect(osaka_result.checkpoint_reverted);

    var amsterdam = Amsterdam.Executor.init(std.testing.allocator, .{});
    defer amsterdam.deinit();
    try putFundedSender(&amsterdam, sender);

    const amsterdam_result = (try amsterdam.runStandalone(tx_context, .{ .create = .{
        .sender = sender,
        .recipient = evmz.address.create(sender, 0),
        .init_code = &oversized_osaka,
    } }, .{
        .regular_left = 20_000_000,
        .reservoir = evmz.eth.transaction.amsterdam_new_account_state_gas + (default_max_code_size + 1) * evmz.eth.transaction.amsterdam_cost_per_state_byte,
    })).expectCreate();
    try std.testing.expectEqual(Interpreter.Status.success, amsterdam_result.status);
    try std.testing.expectEqualSlices(u8, &evmz.address.create(sender, 0), &amsterdam_result.address);
    try std.testing.expectEqual(@as(usize, default_max_code_size + 1), (try amsterdam.getCode(amsterdam_result.address)).len);

    var amsterdam_over = Amsterdam.Executor.init(std.testing.allocator, .{});
    defer amsterdam_over.deinit();
    try putFundedSender(&amsterdam_over, sender);

    const amsterdam_over_result = (try amsterdam_over.runStandalone(tx_context, .{ .create = .{
        .sender = sender,
        .recipient = evmz.address.create(sender, 0),
        .init_code = &oversized_amsterdam,
    } }, .legacy(20_000_000))).expectCreate();
    try std.testing.expectEqual(Interpreter.Status.out_of_gas, amsterdam_over_result.status);
    try std.testing.expectEqual(evmz.execution.TerminalCause.max_code_size_exceeded, amsterdam_over_result.cause.?);
    try std.testing.expect(amsterdam_over_result.checkpoint_reverted);
}

test "exact spec drives create runtime code size limit" {
    const Tiny = evmz.Vm(evmz.eth.shanghai.extend(.{
        .create = .{ .code_size_limit = .{ .replace = 1 } },
    }));
    const sender = evmz.addr(0xaaaa);
    const tx_context = testTxContext(sender, 100_000);
    const two_byte_runtime = initCodeReturningRuntimeSize(2);

    var executor = Tiny.Executor.init(std.testing.allocator, .{});
    defer executor.deinit();
    try putFundedSender(&executor, sender);

    const result = (try executor.runStandalone(tx_context, .{ .create = .{
        .sender = sender,
        .recipient = evmz.address.create(sender, 0),
        .init_code = &two_byte_runtime,
    } }, .legacy(100_000))).expectCreate();
    try std.testing.expectEqual(Interpreter.Status.out_of_gas, result.status);
    try std.testing.expectEqual(evmz.execution.TerminalCause.max_code_size_exceeded, result.cause.?);
    try std.testing.expect(result.checkpoint_reverted);
}

test "exact spec drives create runtime prefix rejection" {
    const overrides = struct {
        fn rejectsCreateCode(code: []const u8) bool {
            _ = code;
            return false;
        }
    };
    const AllowEf = evmz.Vm(evmz.eth.shanghai.extend(.{
        .create = .{ .rejectsCode = overrides.rejectsCreateCode },
    }));
    const sender = evmz.addr(0xaaaa);
    const tx_context = testTxContext(sender, 100_000);
    const init_code = evmz.t.bytecode(.{
        .PUSH1, 0xef, .PUSH0, .MSTORE8,
        .PUSH1, 0x01, .PUSH0, .RETURN,
    });

    var default_executor = Shanghai.Executor.init(std.testing.allocator, .{});
    defer default_executor.deinit();
    try putFundedSender(&default_executor, sender);

    const default_result = (try default_executor.runStandalone(tx_context, .{ .create = .{
        .sender = sender,
        .recipient = evmz.address.create(sender, 0),
        .init_code = &init_code,
    } }, .legacy(100_000))).expectCreate();
    try std.testing.expectEqual(Interpreter.Status.invalid, default_result.status);
    try std.testing.expectEqual(evmz.execution.TerminalCause.invalid_code, default_result.cause.?);
    try std.testing.expect(default_result.checkpoint_reverted);

    var custom_executor = AllowEf.Executor.init(std.testing.allocator, .{});
    defer custom_executor.deinit();
    try putFundedSender(&custom_executor, sender);

    const custom_result = (try custom_executor.runStandalone(tx_context, .{ .create = .{
        .sender = sender,
        .recipient = evmz.address.create(sender, 0),
        .init_code = &init_code,
    } }, .legacy(100_000))).expectCreate();
    try std.testing.expectEqual(Interpreter.Status.success, custom_result.status);
    try std.testing.expectEqualSlices(u8, &.{0xef}, try custom_executor.getCode(custom_result.address));
}

test "exact spec drives create deposit gas" {
    const overrides = struct {
        fn createDepositRegularGas(runtime_size: i64) ?i64 {
            _ = runtime_size;
            return 1_000_000;
        }
    };
    const ExpensiveDeposit = evmz.Vm(evmz.eth.shanghai.extend(.{
        .create = .{ .depositRegularGas = overrides.createDepositRegularGas },
    }));
    const sender = evmz.addr(0xaaaa);
    const tx_context = testTxContext(sender, 100_000);
    const init_code = initCodeReturningRuntimeSize(1);

    var default_executor = Shanghai.Executor.init(std.testing.allocator, .{});
    defer default_executor.deinit();
    try putFundedSender(&default_executor, sender);

    const default_result = (try default_executor.runStandalone(tx_context, .{ .create = .{
        .sender = sender,
        .recipient = evmz.address.create(sender, 0),
        .init_code = &init_code,
    } }, .legacy(100_000))).expectCreate();
    try std.testing.expectEqual(Interpreter.Status.success, default_result.status);
    try std.testing.expectEqual(@as(usize, 1), (try default_executor.getCode(default_result.address)).len);

    var custom_executor = ExpensiveDeposit.Executor.init(std.testing.allocator, .{});
    defer custom_executor.deinit();
    try putFundedSender(&custom_executor, sender);

    const custom_result = (try custom_executor.runStandalone(tx_context, .{ .create = .{
        .sender = sender,
        .recipient = evmz.address.create(sender, 0),
        .init_code = &init_code,
    } }, .legacy(100_000))).expectCreate();
    try std.testing.expectEqual(Interpreter.Status.out_of_gas, custom_result.status);
    try std.testing.expectEqual(evmz.execution.TerminalCause.code_store_out_of_gas, custom_result.cause.?);
    try std.testing.expect(custom_result.checkpoint_reverted);
}

test "exact spec drives created account initial nonce" {
    const NonceSeven = evmz.Vm(evmz.eth.shanghai.extend(.{
        .create = .{ .initial_nonce = 7 },
    }));
    const sender = evmz.addr(0xaaaa);
    const tx_context = testTxContext(sender, 100_000);
    const init_code = initCodeReturningRuntimeSize(1);

    var executor = NonceSeven.Executor.init(std.testing.allocator, .{});
    defer executor.deinit();
    try putFundedSender(&executor, sender);

    const result = (try executor.runStandalone(tx_context, .{ .create = .{
        .sender = sender,
        .recipient = evmz.address.create(sender, 0),
        .init_code = &init_code,
    } }, .legacy(100_000))).expectCreate();
    try std.testing.expectEqual(Interpreter.Status.success, result.status);
    try std.testing.expectEqual(@as(u64, 7), executor.getAccount(result.address).?.nonce);
}

test "exact spec drives precompile warm access" {
    const NoPrecompiles = struct {
        pub const Entry = evmz.eth.precompile.Entry;

        pub fn resolve(target: Address) ?Entry {
            _ = target;
            return null;
        }

        pub fn active(target: Address) bool {
            _ = target;
            return false;
        }

        pub fn execute(
            entry: Entry,
            call: evmz.execution.PrecompileCall,
        ) evmz.precompile.Error!evmz.execution.PrecompileOutcome {
            _ = entry;
            _ = call;
            return error.NotImplemented;
        }
    };
    const NoPrecompile = evmz.Vm(evmz.eth.berlin.extend(.{
        .precompile = NoPrecompiles,
    }));
    const precompile_address = evmz.addr(0x01);

    var default_executor = Berlin.Executor.init(std.testing.allocator, .{});
    defer default_executor.deinit();
    try default_executor.beginStateTransition(testTxContext(precompile_address, 100_000));
    defer default_executor.closeTransaction();
    var default_host = default_executor.host();
    try std.testing.expectEqual(Host.AccessStatus.warm, try default_host.accessAccount(precompile_address));

    var custom_executor = NoPrecompile.Executor.init(std.testing.allocator, .{});
    defer custom_executor.deinit();
    try custom_executor.beginStateTransition(testTxContext(precompile_address, 100_000));
    defer custom_executor.closeTransaction();
    var custom_host = custom_executor.host();
    try std.testing.expectEqual(Host.AccessStatus.cold, try custom_host.accessAccount(precompile_address));
}

test "exact spec drives precompile execution" {
    const CustomPrecompileOverrides = struct {
        const custom_address = evmz.addr(0x1234);

        pub const Precompile = struct {
            pub const Entry = enum { custom };

            pub fn resolve(target: Address) ?Entry {
                if (!std.mem.eql(u8, &target, &custom_address)) return null;
                return .custom;
            }

            pub fn active(target: Address) bool {
                return resolve(target) != null;
            }

            pub fn execute(
                entry: Entry,
                call: evmz.execution.PrecompileCall,
            ) evmz.precompile.Error!evmz.execution.PrecompileOutcome {
                _ = entry;
                return .{ .result = .{
                    .status = .success,
                    .output_data = try call.allocator.dupe(u8, &.{0xaa}),
                    .gas_left = call.message.gas - 7,
                } };
            }
        };
    };
    const CustomPrecompile = evmz.Vm(evmz.eth.cancun.extend(.{
        .precompile = CustomPrecompileOverrides.Precompile,
    }));
    const sender = evmz.addr(0xaaaa);
    const tx_context = testTxContext(sender, 100_000);

    var executor = CustomPrecompile.Executor.init(std.testing.allocator, .{});
    defer executor.deinit();
    try putFundedSender(&executor, sender);

    const result = (try executor.runStandalone(tx_context, .{ .call = .{
        .sender = sender,
        .recipient = CustomPrecompileOverrides.custom_address,
        .input = &.{0xbb},
    } }, .legacy(1_000))).expectCall();

    try std.testing.expectEqual(Interpreter.Status.success, result.status);
    try std.testing.expectEqual(@as(i64, 993), result.gas_left);
    try std.testing.expectEqualSlices(u8, &.{0xaa}, result.output_data);
}

test "exact spec drives selfdestruct host policy" {
    const overrides = struct {
        fn selfDestructPolicy(
            input: evmz.execution.SelfDestructPolicyInput,
        ) evmz.execution.SelfDestructPolicy {
            _ = input;
            return .{
                .clear_balance = false,
                .reset_nonce = false,
                .mark_selfdestructed = false,
            };
        }
    };
    const KeepSelfDestructBalance = evmz.Vm(evmz.eth.cancun.extend(.{
        .self_destruct = .{
            .policy = overrides.selfDestructPolicy,
            .refund_gas = 7,
        },
    }));
    const sender = evmz.addr(0xaaaa);
    const contract = evmz.addr(0xbbbb);
    const beneficiary = evmz.addr(0xcccc);
    const code = evmz.t.bytecode(.{ .PUSH2, 0xcc, 0xcc, .SELFDESTRUCT });

    var executor = KeepSelfDestructBalance.Executor.init(std.testing.allocator, .{});
    defer executor.deinit();
    try putFundedSender(&executor, sender);

    var contract_account = MemoryAccount.init(std.testing.allocator);
    contract_account.balance = 7;
    try contract_account.setCode(&code);
    try executor.state.seedAccount(contract, contract_account);

    try executor.state.seedAccount(beneficiary, MemoryAccount.init(std.testing.allocator));

    const result = (try executor.runStandalone(testTxContext(sender, 100_000), .{ .call = .{
        .sender = sender,
        .recipient = contract,
    } }, .legacy(100_000))).expectCall();

    try std.testing.expectEqual(Interpreter.Status.success, result.status);
    try std.testing.expectEqual(@as(i64, 7), result.gas_refund);
    try std.testing.expectEqual(@as(u256, 7), executor.getAccount(contract).?.balance);
    try std.testing.expectEqual(@as(u256, 7), executor.getAccount(beneficiary).?.balance);
    try std.testing.expect(!executor.state.wasSelfdestructed(contract));
}

test "create warms created address from Berlin" {
    const sender = evmz.addr(0xaaaa);
    const tx_context = testTxContext(sender, 100_000);
    var executor = Berlin.Executor.init(std.testing.allocator, .{});
    defer executor.deinit();

    var sender_account = MemoryAccount.init(std.testing.allocator);
    sender_account.balance = 1_000_000;
    try executor.state.seedAccount(sender, sender_account);

    try executor.beginCreateTransaction(tx_context, sender);

    const init_code = &.{ 0x60, 0x00, 0x60, 0x00, 0xf3 };
    const create_address = evmz.address.create(sender, 0);
    const result = (try executor.executeCreateTransaction(sender, create_address, init_code, .legacy(100_000), 0)).expectCreate();

    try std.testing.expectEqual(Interpreter.Status.success, result.status);
    try std.testing.expect(executor.state.isAccountWarm(create_address));
}

test "callcode with insufficient balance leaves caller storage unchanged" {
    const caller = evmz.addr(0xaaaa);
    const target = evmz.addr(0xbbbb);
    const tx_context = testTxContext(caller, 100_000);
    var executor = Berlin.Executor.init(std.testing.allocator, .{});
    defer executor.deinit();

    var caller_account = MemoryAccount.init(std.testing.allocator);
    caller_account.balance = 0;
    try executor.state.seedAccount(caller, caller_account);

    var target_account = MemoryAccount.init(std.testing.allocator);
    try target_account.setCode(&.{ 0x60, 0x11, 0x60, 0x64, 0x55, 0x00 });
    try executor.state.seedAccount(target, target_account);

    try executor.beginTransaction(tx_context, caller, caller);
    defer executor.closeTransaction();
    const result = (try executeHostCall(&executor, .{
        .depth = 1,
        .kind = .callcode,
        .gas = 100_000,
        .recipient = caller,
        .sender = caller,
        .input_data = &.{},
        .value = 1,
        .code_address = target,
    })).expectCall();

    try std.testing.expectEqual(Interpreter.Status.invalid, result.status);
    try std.testing.expectEqual(@as(i64, 100_000), result.gas_left);
    try std.testing.expectEqual(@as(u256, 0), try executor.getStorage(caller, 0x64));
}

test "create address collision preserves nonce and warmth outside payload rollback" {
    const sender = evmz.addr(0xaaaa);
    const tx_context = testTxContext(sender, 100_000);
    var executor = Berlin.Executor.init(std.testing.allocator, .{});
    defer executor.deinit();

    var sender_account = MemoryAccount.init(std.testing.allocator);
    sender_account.balance = 1;
    try executor.state.seedAccount(sender, sender_account);

    const create_address = evmz.address.create(sender, 0);
    var existing_account = MemoryAccount.init(std.testing.allocator);
    existing_account.nonce = 1;
    try executor.state.seedAccount(create_address, existing_account);

    try executor.beginCreateTransaction(tx_context, sender);
    defer executor.closeTransaction();

    const result = (try executor.executeCreateTransaction(sender, create_address, &.{0x00}, .legacy(100_000), 1)).expectCreate();

    try std.testing.expectEqual(Interpreter.Status.invalid, result.status);
    try std.testing.expectEqual(@as(u64, 1), executor.getAccount(sender).?.nonce);
    try std.testing.expect(executor.state.isAccountWarm(create_address));
}

test "branch checkpoint is native" {
    var executor = Amsterdam.Executor.init(std.testing.allocator, .{});
    defer executor.deinit();

    var branch = try executor.branchCheckpoint();
    defer branch.deinit();
    executor.restoreBranch(&branch);
}

test "call-like message at max depth still executes in recipient storage" {
    const caller = evmz.addr(0xaaaa);
    const target = evmz.addr(0xbbbb);
    const tx_context = testTxContext(caller, 100_000);
    var executor = Frontier.Executor.init(std.testing.allocator, .{});
    defer executor.deinit();

    var caller_account = MemoryAccount.init(std.testing.allocator);
    caller_account.balance = 1_000_000;
    try executor.state.seedAccount(caller, caller_account);

    try executor.state.seedAccount(target, MemoryAccount.init(std.testing.allocator));

    inline for (.{ Host.CallKind.callcode, Host.CallKind.delegatecall }, 0..) |kind, slot| {
        try executor.beginTransaction(tx_context, caller, caller);
        try executor.state.setCode(target, &.{ 0x60, 0x2a, 0x60, @intCast(slot), 0x55, 0x00 });
        const result = (try executeHostCall(&executor, .{
            .depth = Host.max_call_depth,
            .kind = kind,
            .gas = 100_000,
            .recipient = caller,
            .sender = caller,
            .input_data = &.{},
            .value = 0,
            .code_address = target,
        })).expectCall();

        try std.testing.expectEqual(Interpreter.Status.success, result.status);
        try std.testing.expectEqual(@as(u256, 0x2a), try executor.getStorage(caller, slot));
        executor.closeTransaction();
    }
}

test "value call at max depth returns stipend without child execution" {
    const caller = evmz.addr(0xaaaa);
    const contract = evmz.addr(0xbbbb);
    const tx_context = testTxContext(caller, 100_000);
    var executor = Berlin.Executor.init(std.testing.allocator, .{});
    defer executor.deinit();

    var caller_account = MemoryAccount.init(std.testing.allocator);
    caller_account.balance = 1_000_000;
    try executor.state.seedAccount(caller, caller_account);

    const code = evmz.t.bytecode(.{
        .PUSH1, 0x00,
        .PUSH1, 0x00,
        .PUSH1, 0x00,
        .PUSH1, 0x00,
        .PUSH1, 0x01,
        .PUSH2, 0xbb,
        0xbb,   .PUSH1,
        0x00,   .CALL,
        .STOP,
    });
    var contract_account = MemoryAccount.init(std.testing.allocator);
    try contract_account.setCode(&code);
    try executor.state.seedAccount(contract, contract_account);

    try executor.beginTransaction(tx_context, caller, contract);
    const result = (try executeHostCall(&executor, .{
        .depth = Host.max_call_depth,
        .kind = .call,
        .gas = 100_000,
        .recipient = contract,
        .sender = caller,
        .input_data = &.{},
        .value = 0,
        .code_address = contract,
    })).expectCall();

    try std.testing.expectEqual(Interpreter.Status.success, result.status);
    try std.testing.expectEqual(@as(i64, 93_179), result.gas_left);
    try std.testing.expectEqual(@as(u256, 0), executor.getAccount(contract).?.balance);
}

test "Amsterdam value call at max depth refills new-account state gas" {
    const caller = evmz.addr(0xaaaa);
    const contract = evmz.addr(0xbbbb);
    const recipient = evmz.addr(0xcccc);
    const tx_context = testTxContext(caller, 300_000);
    var executor = Amsterdam.Executor.init(std.testing.allocator, .{});
    defer executor.deinit();

    var caller_account = MemoryAccount.init(std.testing.allocator);
    caller_account.balance = 1_000_000;
    try executor.state.seedAccount(caller, caller_account);

    const code = evmz.t.bytecode(.{
        .PUSH1, 0x00,
        .PUSH1, 0x00,
        .PUSH1, 0x00,
        .PUSH1, 0x00,
        .PUSH1, 0x01,
        .PUSH2, 0xcc,
        0xcc,   .PUSH2,
        0x27,   0x10,
        .CALL,  .STOP,
    });
    var contract_account = MemoryAccount.init(std.testing.allocator);
    contract_account.balance = 1;
    try contract_account.setCode(&code);
    try executor.state.seedAccount(contract, contract_account);

    try executor.beginTransaction(tx_context, caller, contract);
    const result = (try executeHostCall(&executor, .{
        .depth = Host.max_call_depth,
        .kind = .call,
        .gas = 100_000,
        .gas_reservoir = evmz.eth.transaction.amsterdam_new_account_state_gas,
        .recipient = contract,
        .sender = caller,
        .input_data = &.{},
        .value = 0,
        .code_address = contract,
    })).expectCall();

    try std.testing.expectEqual(Interpreter.Status.success, result.status);
    try std.testing.expectEqual(@as(i64, evmz.eth.transaction.amsterdam_new_account_state_gas), result.gas_reservoir);
    try std.testing.expectEqual(@as(i64, 0), result.state_gas_spent);
    try std.testing.expect(!try executor.state.accountExists(recipient));
}

test "Amsterdam create at max depth refills new-account state gas" {
    const caller = evmz.addr(0xaaaa);
    const contract = evmz.addr(0xbbbb);
    const tx_context = testTxContext(caller, 300_000);
    var executor = Amsterdam.Executor.init(std.testing.allocator, .{});
    defer executor.deinit();

    var caller_account = MemoryAccount.init(std.testing.allocator);
    caller_account.balance = 1_000_000;
    try executor.state.seedAccount(caller, caller_account);

    const code = evmz.t.bytecode(.{ .PUSH0, .PUSH0, .PUSH0, .CREATE, .STOP });
    var contract_account = MemoryAccount.init(std.testing.allocator);
    try contract_account.setCode(&code);
    try executor.state.seedAccount(contract, contract_account);

    try executor.beginTransaction(tx_context, caller, contract);
    const result = (try executeHostCall(&executor, .{
        .depth = Host.max_call_depth,
        .kind = .call,
        .gas = 100_000,
        .gas_reservoir = evmz.eth.transaction.amsterdam_new_account_state_gas,
        .recipient = contract,
        .sender = caller,
        .input_data = &.{},
        .value = 0,
        .code_address = contract,
    })).expectCall();

    try std.testing.expectEqual(Interpreter.Status.success, result.status);
    try std.testing.expectEqual(@as(i64, evmz.eth.transaction.amsterdam_new_account_state_gas), result.gas_reservoir);
    try std.testing.expectEqual(@as(i64, 0), result.state_gas_spent);
    try std.testing.expectEqual(@as(u64, 0), executor.getAccount(contract).?.nonce);
}

test "exceptional child call burns forwarded gas" {
    const caller = evmz.addr(0xaaaa);
    const target = evmz.addr(0xbbbb);
    const tx_context = testTxContext(caller, 100_000);
    var executor = Berlin.Executor.init(std.testing.allocator, .{});
    defer executor.deinit();

    var caller_account = MemoryAccount.init(std.testing.allocator);
    caller_account.balance = 1_000_000;
    try executor.state.seedAccount(caller, caller_account);

    var target_account = MemoryAccount.init(std.testing.allocator);
    try target_account.setCode(&.{0xfe});
    try executor.state.seedAccount(target, target_account);

    try executor.beginTransaction(tx_context, caller, caller);
    const result = (try executeHostCall(&executor, .{
        .depth = 1,
        .kind = .call,
        .gas = 100_000,
        .recipient = target,
        .sender = caller,
        .input_data = &.{},
        .value = 0,
        .code_address = target,
    })).expectCall();

    try std.testing.expectEqual(Interpreter.Status.invalid, result.status);
    try std.testing.expectEqual(@as(i64, 0), result.gas_left);
}

test "exceptional child call rolls back storage via checkpoint" {
    const caller = evmz.addr(0xaaaa);
    const target = evmz.addr(0xbbbb);
    const tx_context = testTxContext(caller, 100_000);
    var executor = Berlin.Executor.init(std.testing.allocator, .{});
    defer executor.deinit();

    var caller_account = MemoryAccount.init(std.testing.allocator);
    caller_account.balance = 1_000_000;
    try executor.state.seedAccount(caller, caller_account);

    var target_account = MemoryAccount.init(std.testing.allocator);
    try target_account.setCode(&.{ 0x60, 0x11, 0x60, 0x64, 0x55, 0xfe });
    try executor.state.seedAccount(target, target_account);

    try executor.beginTransaction(tx_context, caller, caller);
    const result = (try executeHostCall(&executor, .{
        .depth = 1,
        .kind = .call,
        .gas = 100_000,
        .recipient = target,
        .sender = caller,
        .input_data = &.{},
        .value = 0,
        .code_address = target,
    })).expectCall();

    try std.testing.expectEqual(Interpreter.Status.invalid, result.status);
    try std.testing.expectEqual(@as(u256, 0), try executor.state.getStorage(target, 0x64));
}

test "contract creation rejects EF-prefixed runtime code from London" {
    const sender = evmz.addr(0xaaaa);
    const tx_context = testTxContext(sender, 100_000);
    var executor = London.Executor.init(std.testing.allocator, .{});
    defer executor.deinit();

    var sender_account = MemoryAccount.init(std.testing.allocator);
    sender_account.balance = 1_000_000;
    try executor.state.seedAccount(sender, sender_account);

    try executor.beginCreateTransaction(tx_context, sender);

    const init_code = &.{ 0x60, 0xef, 0x60, 0x00, 0x53, 0x60, 0x10, 0x60, 0x00, 0xf3 };
    const create_address = evmz.address.create(sender, 0);
    const result = (try executor.executeCreateTransaction(sender, create_address, init_code, .legacy(100_000), 0)).expectCreate();

    try std.testing.expectEqual(Interpreter.Status.invalid, result.status);
    try std.testing.expectEqual(@as(i64, 0), result.gas_left);
    try std.testing.expectEqual(@as(u64, 1), executor.getAccount(sender).?.nonce);
    try std.testing.expect(executor.getAccount(create_address) == null);
    try std.testing.expect(executor.state.isAccountWarm(create_address));
}

test "selfdestruct charges new-account cost for nonzero balance" {
    const sender = evmz.addr(0xaaaa);
    const contract = evmz.addr(0xbbbb);
    const tx_context = testTxContext(sender, 100_000);
    var executor = Cancun.Executor.init(std.testing.allocator, .{});
    defer executor.deinit();

    var sender_account = MemoryAccount.init(std.testing.allocator);
    sender_account.balance = 1_000_000;
    try executor.state.seedAccount(sender, sender_account);

    var contract_account = MemoryAccount.init(std.testing.allocator);
    contract_account.balance = 1;
    try contract_account.setCode(&.{ 0x5f, 0xff });
    try executor.state.seedAccount(contract, contract_account);

    try executor.beginTransaction(tx_context, sender, contract);
    const result = try executor.executeCallTransaction(sender, contract, &.{}, .legacy(100_000), 0);

    try std.testing.expectEqual(Interpreter.Status.success, result.status);
    // Raw message scope omits family semantics: the zero beneficiary is cold
    // unless the transaction program supplies Ethereum's coinbase warm-up.
    try std.testing.expectEqual(@as(i64, 67_398), result.gas_left);
}

test "TangerineWhistle selfdestruct charges new-account cost without balance transfer" {
    try expectEmptySelfDestructGas(TangerineWhistle, 69_997);
    try expectEmptySelfDestructGas(SpuriousDragon, 94_997);
}

fn expectEmptySelfDestructGas(comptime ExactVm: type, expected_gas_left: i64) !void {
    const sender = evmz.addr(0xaaaa);
    const contract = evmz.addr(0xbbbb);
    const code = evmz.t.bytecode(.{ .PUSH1, 0x00, .SELFDESTRUCT });
    const tx_context = testTxContext(sender, 100_000);
    var executor = ExactVm.Executor.init(std.testing.allocator, .{});
    defer executor.deinit();

    var sender_account = MemoryAccount.init(std.testing.allocator);
    sender_account.balance = 1_000_000;
    try executor.state.seedAccount(sender, sender_account);

    var contract_account = MemoryAccount.init(std.testing.allocator);
    try contract_account.setCode(&code);
    try executor.state.seedAccount(contract, contract_account);

    try executor.beginTransaction(tx_context, sender, contract);
    const result = try executor.executeCallTransaction(sender, contract, &.{}, .legacy(100_000), 0);

    try std.testing.expectEqual(Interpreter.Status.success, result.status);
    try std.testing.expectEqual(expected_gas_left, result.gas_left);
}

test "SELFDESTRUCT refund is removed at London" {
    try expectSelfDestructRefund(Berlin, 24_000);
    try expectSelfDestructRefund(London, 0);
}

fn expectSelfDestructRefund(comptime ExactVm: type, expected_refund: i64) !void {
    const sender = evmz.addr(0xaaaa);
    const contract = evmz.addr(0xbbbb);
    const code = evmz.t.bytecode(.{ .PUSH1, 0x00, .SELFDESTRUCT });
    const tx_context = testTxContext(sender, 100_000);
    var executor = ExactVm.Executor.init(std.testing.allocator, .{});
    defer executor.deinit();

    var sender_account = MemoryAccount.init(std.testing.allocator);
    sender_account.balance = 1_000_000;
    try executor.state.seedAccount(sender, sender_account);

    var contract_account = MemoryAccount.init(std.testing.allocator);
    try contract_account.setCode(&code);
    try executor.state.seedAccount(contract, contract_account);

    try executor.beginTransaction(tx_context, sender, contract);
    const result = try executor.executeCallTransaction(sender, contract, &.{}, .legacy(100_000), 0);

    try std.testing.expectEqual(Interpreter.Status.success, result.status);
    try std.testing.expectEqual(expected_refund, result.gas_refund);
}

test "active precompiles are warm but not existing state accounts" {
    const precompile_address = evmz.addr(2);
    var executor = Berlin.Executor.init(std.testing.allocator, .{});
    defer executor.deinit();

    var host_iface = executor.host();
    try std.testing.expect(!try host_iface.accountExists(precompile_address));
    try std.testing.expectEqual(Host.AccessStatus.warm, try host_iface.accessAccount(precompile_address));
    try std.testing.expectEqual(@as(u256, 0), try host_iface.getCodeHash(precompile_address));

    try executor.state.seedAccount(precompile_address, MemoryAccount.init(std.testing.allocator));
    try std.testing.expectEqual(uint256.fromBytes32(&evmz.crypto.keccak256_empty), try host_iface.getCodeHash(precompile_address));
}

test "delegated precompile targets are warm" {
    try expectDelegatedPrecompileWarm(Prague);
    try expectDelegatedPrecompileWarm(Amsterdam);
}

fn expectDelegatedPrecompileWarm(comptime ExactVm: type) !void {
    const authority = evmz.addr(0xbbbb);
    const precompile_address = evmz.addr(2);
    var executor = ExactVm.Executor.init(std.testing.allocator, .{});
    defer executor.deinit();

    var code: [eip7702.delegation_code_len]u8 = undefined;
    eip7702.writeDelegationCode(&code, precompile_address);
    var authority_account = MemoryAccount.init(std.testing.allocator);
    try authority_account.setCode(&code);
    try executor.state.seedAccount(authority, authority_account);

    var host_iface = executor.host();
    try std.testing.expectEqual(Host.AccessStatus.warm, (try host_iface.accessDelegatedAccount(authority)).?);
}

test "sealed observations expose storage state without a trace tape" {
    const sender = evmz.addr(0xaaaa);
    const contract = evmz.addr(0xbbbb);
    const tx_context = testTxContext(sender, 100_000);

    const StorageObserver = struct {
        address: Address,
        key: u256,
        expected: u256,
        calls: usize = 0,

        pub fn observe(self: *@This(), pending: TrackedState.PendingView) !void {
            self.calls += 1;
            const storage = pending.observations().storage;
            var index: u32 = 0;
            while (index < storage.len()) : (index += 1) {
                const fact = storage.at(index);
                if (!std.mem.eql(u8, &fact.address, &self.address) or fact.key != self.key) continue;
                try std.testing.expect(fact.observation.value_read);
                try std.testing.expect(fact.effect.written);
                try std.testing.expectEqual(@as(u256, 0), fact.original);
                try std.testing.expectEqual(self.expected, fact.current);
                return;
            }
            return error.ExpectedStorageObservationMissing;
        }
    };
    var observations = StorageObserver{
        .address = contract,
        .key = 0,
        .expected = 42,
    };
    var executor = Berlin.Executor.init(std.testing.allocator, .{});
    defer executor.deinit();

    var sender_account = MemoryAccount.init(std.testing.allocator);
    sender_account.balance = 1_000_000;
    try executor.state.seedAccount(sender, sender_account);

    var contract_account = MemoryAccount.init(std.testing.allocator);
    try contract_account.setCode(&.{
        0x60, 0x2a, // PUSH1 42
        0x60, 0x00, // PUSH1 0
        0x55, // SSTORE
        0x00, // STOP
    });
    try executor.state.seedAccount(contract, contract_account);

    try executor.beginObservedTransaction(tx_context, sender, contract);
    defer executor.closeTransaction();
    const result = try executor.executeCallTransaction(sender, contract, &.{}, .legacy(100_000), 0);
    try executor.closeTransactionObserved(&observations);

    try std.testing.expectEqual(Interpreter.Status.success, result.status);
    try std.testing.expectEqual(@as(usize, 1), observations.calls);
}

const StepEventKind = enum {
    start,
    end,
};

const StepOrderRecorder = struct {
    const Event = struct {
        kind: StepEventKind,
        opcode: u8,
        depth: u16,
        stack_top: ?u256 = null,
    };

    events: [128]Event = undefined,
    len: usize = 0,

    fn consume(self: *StepOrderRecorder, span: trace.TraceSpan) !void {
        var cursor = trace.TraceCursor.init(span);
        while (try cursor.next()) |event| switch (event) {
            .step_start => |view| self.append(.{
                .kind = .start,
                .opcode = view.row.opcode,
                .depth = view.frame.depth,
            }),
            .step_end => |view| self.append(.{
                .kind = .end,
                .opcode = view.row.opcode,
                .depth = view.frame.depth,
                .stack_top = if (view.state.stack.?.len == 0)
                    null
                else
                    view.state.stack.?[view.state.stack.?.len - 1],
            }),
            .frame_enter, .frame_leave => {},
        };
    }

    fn firstIndex(self: *const StepOrderRecorder, kind: StepEventKind, opcode: evmz.Opcode, depth: u16) ?usize {
        for (self.events[0..self.len], 0..) |event, index| {
            if (event.kind == kind and event.opcode == @intFromEnum(opcode) and event.depth == depth) return index;
        }
        return null;
    }

    fn hasDepthStartBetween(self: *const StepOrderRecorder, depth: u16, start_index: usize, end_index: usize) bool {
        for (self.events[start_index + 1 .. end_index]) |event| {
            if (event.kind == .start and event.depth == depth) return true;
        }
        return false;
    }

    fn append(self: *StepOrderRecorder, event: Event) void {
        std.debug.assert(self.len < self.events.len);
        self.events[self.len] = event;
        self.len += 1;
    }
};

fn executeHostCall(executor: anytype, msg: Host.Message) !Host.Result {
    var host_iface = executor.host();
    return host_iface.call(msg);
}

test {
    std.testing.refAllDecls(@This());
}
