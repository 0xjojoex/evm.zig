//! Low-level EVM execution engine.
//!
//! `Executor` owns tracked transaction state, transaction context, frame pools,
//! and output buffers used while running EVM code. Higher-level APIs such as
//! `Vm` handle validation and user-facing transaction shapes; this type is the
//! execution substrate underneath them.
//!
//! Prefer one of three explicit ownership layers:
//!
//! 1. `Vm.transact` for complete family transaction semantics. Completion
//!    returns one `Executed` owner that must be retained or discarded.
//! 2. `executeStandalone*` for a fully managed raw CALL/CREATE message. These
//!    methods do not perform family validation, charging, or settlement.
//! 3. Manual scope methods for STF work and diagnostic harnesses that must place
//!    checkpoints themselves. A successful manual transition must be committed
//!    or explicitly retained; failure cleanup must discard it.
//!
//! Family transaction choreography is private to `transaction/runtime.zig`.
//! Consumers cannot begin or finish the Executor's active transaction row.
//!
//! `executor/call_runtime.zig` owns call/create frame execution and bytecode
//! frame setup. `executor/host_callbacks.zig` owns the `Host` vtable adapter.

const std = @import("std");

const evmz = @import("./evm.zig");
pub const errors = @import("./executor/error.zig");
const Address = evmz.Address;
const AccountState = evmz.state.Account;
const BlockHashSource = evmz.BlockHashSource;
const Bytecode = evmz.Bytecode;
const ExactSpec = @import("./spec.zig").Spec;
const prepared_code = evmz.prepared_code;
const execution_values = @import("./execution.zig");
const Host = evmz.Host;
const Interpreter = evmz.interpreter;
const TrackedState = evmz.state.TrackedState;
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
pub const eip7702 = @import("./executor/eip7702.zig");
const FrameStore = @import("./executor/frame_store.zig");
const host_callbacks = @import("./executor/host_callbacks.zig");
pub const state_io = @import("./executor/state_io.zig");
pub const system_contracts = @import("./executor/system_contracts.zig");
pub const transfer_logs = @import("./executor/transfer_logs.zig");
const frame_io = @import("./frame_io.zig");
const trace = @import("./trace.zig");
const transaction_runtime = @import("./transaction/runtime.zig");
const uint256 = @import("./uint256.zig");

const CallScratchSlots = std.ArrayList(*call_scratch_storage.Slot);

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
};

/// A top-level call whose bytecode has already been prepared by the caller.
///
/// This is the narrowest call entrypoint. Use it when a benchmark/test wants to
/// control bytecode preprocessing explicitly; otherwise prefer `executeCall` or
/// `executeStandalone`.
pub const PreparedCallTransaction = struct {
    bytecode: Bytecode.View,
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

/// Non-consensus capabilities selected when compiling an exact executor.
pub const CompileOptions = struct {
    /// Include opcode-step capture and its traced dispatch table.
    step_capture: bool = true,
};

/// The execution engine bound to one exact execution specification.
///
/// Returns the `Executor` struct type described in the module doc above: it
/// carries the fork-specific message/result aliases and call/create lifecycle
/// methods. A `Vm` closes it over one complete spec at comptime.
pub fn Executor(comptime spec: ExactSpec) type {
    return ExecutorWithOptions(spec, .{});
}

pub fn ExecutorWithOptions(comptime spec: ExactSpec, comptime options_value: CompileOptions) type {
    return struct {
        const Self = @This();
        const runtime = call_runtime.bind(Self);
        const callbacks = host_callbacks.bind(Self);

        pub const specification = spec;
        pub const compile_options = options_value;
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
        call_scratch_slots: CallScratchSlots,
        prepared_code_scratch: call_scratch_storage.Slot,
        execution_context: ?execution_values.ExecutionContext = null,
        scope_root: ?ScopeRoot = null,
        manual_state_attempt: ?ManualStateAttempt = null,
        transaction_runtime_state: ?TransactionRuntimeState = null,
        next_transaction_generation: u64 = 0,
        active_block_execution_generation: ?u64 = null,
        next_block_execution_generation: u64 = 0,
        checkpoint_top: usize = 0,
        next_checkpoint_id: usize = 0,
        block_hash_source: ?BlockHashSource = null,
        precompile_runtime: ?execution_values.PrecompileRuntime = null,
        prepared_code_backend: ?prepared_code.Backend,
        prepared_code_execution: ?prepared_code.Execution = null,
        prepared_code_execution_depth: usize = 0,
        trace_depth: u16 = 0,
        last_call_output: frame_io.ByteSlot,

        const ExecutionMode = union(enum) {
            normal,
            observed,
            captured: *CaptureContext,

            fn observesState(self: ExecutionMode) bool {
                return self != .normal;
            }

            fn captureContext(self: ExecutionMode) ?*CaptureContext {
                return switch (self) {
                    .normal, .observed => null,
                    .captured => |context| context,
                };
            }
        };

        const ManualStateAttempt = struct {
            id: TrackedState.AttemptId,
            mode: ExecutionMode,
        };

        const TransactionRuntimeState = struct {
            state_attempt_id: TrackedState.AttemptId,
            generation: u64,
            mode: ExecutionMode,
            phase: enum { active, pending } = .active,
            nonce_advanced: bool = false,
            payload_started: bool = false,
        };

        /// The exclusive externally copyable owner of one completed but
        /// unresolved transaction. Executor keeps the phase state; this value
        /// carries the generation needed to reject stale copies.
        pub fn Executed(comptime Output: type) type {
            return struct {
                const Execution = @This();

                executor: *Self,
                generation: u64,
                output_value: Output,

                pub const View = struct {
                    output: *const Output,
                    logs: TrackedState.LogView,
                };

                /// Borrow family output and logs while this result is unresolved.
                pub fn view(self: *const Execution) View {
                    return .{
                        .output = &self.output_value,
                        .logs = self.pendingView().logs(),
                    };
                }

                /// Borrow the family output while this result is unresolved.
                pub fn output(self: *const Execution) *const Output {
                    _ = self.state();
                    return &self.output_value;
                }

                /// Copy the family output while leaving state unresolved.
                pub fn result(self: Execution) Output {
                    _ = self.state();
                    return self.output_value;
                }

                /// Borrow transaction logs while this result is unresolved.
                pub fn logs(self: Execution) TrackedState.LogView {
                    return self.pendingView().logs();
                }

                /// Return the Executor allocator after validating this generation.
                pub fn allocator(self: Execution) std.mem.Allocator {
                    _ = self.state();
                    return self.executor.allocator;
                }

                /// Borrow the complete sealed state view before resolution.
                pub fn pendingView(self: Execution) TrackedState.PendingView {
                    _ = self.state();
                    return self.executor.state.pendingView();
                }

                /// Borrow net state changes before resolution.
                pub fn changes(self: Execution) TrackedState.ChangesView {
                    return self.pendingView().changes();
                }

                /// Borrow retained state observations before resolution.
                pub fn observations(self: Execution) TrackedState.ObservationsView {
                    return self.pendingView().observations();
                }

                /// Accept this transaction's sealed state into the Executor branch.
                ///
                /// The value and all copies become stale after this call.
                pub fn retain(self: Execution) void {
                    const state_value = self.state();
                    self.executor.state.retain(state_value.state_attempt_id);
                    self.executor.finishCurrentTransaction(false);
                }

                /// Retain state and return the family output by value.
                pub fn retainResult(self: Execution) Output {
                    self.retain();
                    return self.output_value;
                }

                /// Roll back this transaction's sealed state.
                ///
                /// The value and all copies become stale after this call.
                pub fn discard(self: Execution) void {
                    _ = self.state();
                    self.executor.discardCurrentTransaction();
                }

                /// Discard only if this copy still identifies the current result.
                ///
                /// This is the idempotent cleanup operation for `defer`.
                pub fn discardIfCurrent(self: Execution) void {
                    const current = if (self.executor.transaction_runtime_state) |*value| value else return;
                    if (current.generation != self.generation or current.phase != .pending) return;
                    self.discard();
                }

                fn state(self: Execution) *TransactionRuntimeState {
                    const state_value = if (self.executor.transaction_runtime_state) |*value| value else unreachable;
                    std.debug.assert(state_value.generation == self.generation);
                    std.debug.assert(state_value.phase == .pending);
                    return state_value;
                }
            };
        }

        pub const TransactionAccountSummary = struct {
            nonce: u64,
            balance: u256,
            code_hash: [32]u8,
        };

        pub fn transactionAccountSummary(self: *Self, account_address: Address) !?TransactionAccountSummary {
            transaction_runtime.requireActive(self);
            const account = try self.getAccountOrLoad(account_address) orelse return null;
            return .{
                .nonce = account.nonce,
                .balance = account.balance,
                .code_hash = account.code_hash,
            };
        }

        pub fn advanceTransactionNonce(
            self: *Self,
            message: MessageType,
        ) !void {
            const runtime_state = if (self.transaction_runtime_state) |*value| value else unreachable;
            std.debug.assert(runtime_state.phase == .active);
            std.debug.assert(!runtime_state.nonce_advanced);
            std.debug.assert(!runtime_state.payload_started);
            self.validateScopeRoot(.fromMessage(message));

            try self.incrementNonce(message.sender());
            runtime_state.nonce_advanced = true;
        }

        /// Scope-bound execution checkpoint paired with one trace/BAL lifecycle.
        ///
        /// This journal-backed token must be opened and closed inside one active
        /// transaction scope. It never finalizes or closes that scope. The owning
        /// transaction runtime can span prelude writes and payload execution;
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
            var state = if (options.state_reader) |state_reader|
                TrackedState.initWithStateReader(allocator, state_reader)
            else
                TrackedState.init(allocator);
            state.retains_empty_accounts = spec.retains_empty_accounts;

            const executor: Self = .{
                .allocator = allocator,
                .state = state,
                .frame_store = .{ .stable_metadata_capacity = default_max_live_frames_value },
                .call_scratch_slots = .empty,
                .prepared_code_scratch = call_scratch_storage.Slot.init(allocator),
                .block_hash_source = options.block_hash_source,
                .precompile_runtime = options.precompile_runtime,
                .prepared_code_backend = options.prepared_code_backend,
                .last_call_output = frame_io.ByteSlot.init(allocator),
            };
            return executor;
        }

        pub fn currentCaptureContext(self: *Self) ?*CaptureContext {
            if (self.transaction_runtime_state) |attempt|
                return attempt.mode.captureContext();
            if (self.manual_state_attempt) |attempt|
                return attempt.mode.captureContext();
            return null;
        }

        fn assertExecutionMode(mode: ExecutionMode) void {
            const context = mode.captureContext() orelse return;
            std.debug.assert(context.isActive());
        }

        pub fn traceAccountAccess(self: *Self, account_address: Address) !void {
            try self.state.observeAccountAccess(account_address);
        }

        /// Rebind fixture/benchmark inputs and reset tracked state.
        pub fn reset(self: *Self, options: Init) !void {
            std.debug.assert(!self.hasActiveBlockExecution());
            std.debug.assert(self.frame_store.len() == 0);
            std.debug.assert(self.checkpoint_top == 0);
            std.debug.assert(self.transaction_runtime_state == null);
            std.debug.assert(!self.state.scopeActive());
            std.debug.assert(self.prepared_code_execution_depth == 0);

            self.state.reset(options.state_reader);
            self.execution_context = null;
            self.scope_root = null;
            self.manual_state_attempt = null;
            self.block_hash_source = options.block_hash_source;
            self.precompile_runtime = options.precompile_runtime;
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
                );
            }
            std.debug.assert(self.prepared_code_execution_depth < std.math.maxInt(usize));
            self.prepared_code_execution_depth += 1;
        }

        pub fn endPreparedCodeExecution(self: *Self) void {
            std.debug.assert(self.prepared_code_execution_depth > 0);
            self.prepared_code_execution_depth -= 1;
            if (self.prepared_code_execution_depth != 0) return;

            self.prepared_code_execution.?.deinit();
            self.prepared_code_execution = null;
            self.prepared_code_scratch.reset();
        }

        /// Reuse prepared code and cleared transaction containers for one
        /// sequential protocol-call batch.
        pub fn beginSystemCallBatch(self: *Self) void {
            self.beginPreparedCodeExecution();
            self.state.beginTransactionCapacityReuse();
        }

        pub fn endSystemCallBatch(self: *Self) void {
            self.state.endTransactionCapacityReuse();
            self.endPreparedCodeExecution();
        }

        /// Reuse one cleared transaction container across an ordered batch.
        pub fn beginTransactionCapacityReuse(self: *Self) void {
            self.state.beginTransactionCapacityReuse();
        }

        pub fn endTransactionCapacityReuse(self: *Self) void {
            self.state.endTransactionCapacityReuse();
        }

        pub fn reserveAcceptedAccessHint(self: *Self, hint: TrackedState.AccessHint) !void {
            try self.state.reserveAcceptedAccessHint(hint);
        }

        /// Release state, frame pools, scratch arenas, and retained return-data buffers.
        pub fn deinit(self: *Self) void {
            std.debug.assert(!self.hasActiveBlockExecution());
            std.debug.assert(self.frame_store.len() == 0);
            std.debug.assert(self.checkpoint_top == 0);
            std.debug.assert(self.transaction_runtime_state == null);
            std.debug.assert(self.prepared_code_execution_depth == 0);
            std.debug.assert(self.prepared_code_execution == null);
            self.state.deinit();
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
            mode: ExecutionMode,
        ) !void {
            std.debug.assert(self.execution_context == null);
            std.debug.assert(self.checkpoint_top == 0);
            std.debug.assert(self.transaction_runtime_state == null);
            std.debug.assert(self.manual_state_attempt == null);
            assertExecutionMode(mode);
            const state_attempt_id = if (mode.observesState())
                self.state.beginObservedTransaction()
            else
                self.state.beginTransaction();
            self.state.beginScope();
            self.manual_state_attempt = .{ .id = state_attempt_id, .mode = mode };
            self.execution_context = context;
            self.scope_root = null;
        }

        fn requireTransactionScope(self: *const Self) void {
            std.debug.assert(self.execution_context != null);
        }

        fn validateScopeContext(self: *const Self, context: execution_values.ExecutionContext) void {
            self.requireTransactionScope();
            std.debug.assert(self.execution_context.?.eql(context));
        }

        fn validateScopeRoot(self: *const Self, root: ScopeRoot) void {
            self.requireTransactionScope();
            std.debug.assert(self.scope_root != null);
            std.debug.assert(ScopeRoot.eql(self.scope_root.?, root));
        }

        /// Open a manual call transaction scope.
        ///
        /// This low-level API does not finalize or resolve the transition. A
        /// successful caller must use `commitTransaction` or
        /// `retainStateTransition`; failure cleanup must use
        /// `discardStateTransition`.
        /// The scope warms the sender and recipient. Family-required additions,
        /// such as Ethereum's coinbase rule, belong in `beginMessageScope` init.
        pub fn beginTransaction(self: *Self, context: execution_values.ExecutionContext, sender: Address, recipient: Address) !void {
            try self.openTransactionScope(context, .normal);
            errdefer self.discardStateTransition();
            try warmTransactionAccesses(self, sender, recipient);
        }

        /// Open an observed manual call transaction scope.
        ///
        /// This has the same ownership contract as `beginTransaction`; the
        /// observed mode is carried into any root message execution.
        pub fn beginObservedTransaction(
            self: *Self,
            context: execution_values.ExecutionContext,
            sender: Address,
            recipient: Address,
        ) !void {
            try self.openTransactionScope(context, .observed);
            errdefer self.discardStateTransition();
            try warmTransactionAccesses(self, sender, recipient);
        }

        /// Open a captured manual call transaction scope.
        ///
        /// This has the same ownership contract as `beginTransaction`; captured
        /// call events are written into `capture`.
        pub fn beginCapturedTransaction(
            self: *Self,
            context: execution_values.ExecutionContext,
            sender: Address,
            recipient: Address,
            capture: *CaptureContext,
        ) !void {
            try self.openTransactionScope(context, .{ .captured = capture });
            errdefer self.discardStateTransition();
            try warmTransactionAccesses(self, sender, recipient);
        }

        /// Open a manual create transaction scope.
        ///
        /// This is the create counterpart to `beginTransaction`; there is no recipient
        /// to warm before the create address is derived during execution.
        pub fn beginCreateTransaction(self: *Self, context: execution_values.ExecutionContext, sender: Address) !void {
            try self.openTransactionScope(context, .normal);
            errdefer self.discardStateTransition();
            try warmTransactionAccesses(self, sender, null);
        }

        /// Open a direct message-execution scope from its authoritative context.
        ///
        /// This is open-only: callers own checkpoint placement, execution, and
        /// the eventual commit, rollback, retain, or discard. Mandatory
        /// sender/recipient warmth is derived from `request`;
        /// `scope_init` supplies family- or witness-resolved warmth beyond the
        /// mandatory root sender/recipient accounts.
        pub fn beginMessageScope(
            self: *Self,
            request: execution_values.EvmExecutionRequest,
            scope_init: execution_values.ExecutionScopeInit,
        ) !void {
            try self.beginMessageScopeContext(request.context, request.message, scope_init, .normal);
        }

        /// Open the observed counterpart to `beginMessageScope`.
        pub fn beginObservedMessageScope(
            self: *Self,
            request: execution_values.EvmExecutionRequest,
            scope_init: execution_values.ExecutionScopeInit,
        ) !void {
            try self.beginMessageScopeContext(request.context, request.message, scope_init, .observed);
        }

        fn beginMessageScopeContext(
            self: *Self,
            context: execution_values.ExecutionContext,
            message: Self.Message,
            scope_init: execution_values.ExecutionScopeInit,
            mode: ExecutionMode,
        ) !void {
            try self.openTransactionScope(context, mode);
            errdefer self.discardStateTransition();

            try transaction_runtime.initializeMessageScope(self, message, scope_init);
        }

        fn beginSystemCall(
            self: *Self,
            context: execution_values.ExecutionContext,
            mode: ExecutionMode,
        ) !void {
            try self.openTransactionScope(context, mode);
        }

        /// Open a transaction-like scope for family/STF state work without a
        /// root EVM message. Retain or discard it explicitly.
        pub fn beginStateTransition(self: *Self, context: execution_values.ExecutionContext) !void {
            try self.openTransactionScope(context, .normal);
        }

        /// Open an observed state transition without a root EVM message.
        pub fn beginObservedStateTransition(self: *Self, context: execution_values.ExecutionContext) !void {
            try self.openTransactionScope(context, .observed);
        }

        /// Mark an account warm in the current transaction scope.
        pub fn warmAccount(self: *Self, address: Address) !void {
            self.requireTransactionScope();
            try self.state.warmAccount(address);
        }

        /// Mark a storage slot warm in the current transaction scope.
        pub fn warmStorage(self: *Self, address: Address, key: u256) !void {
            self.requireTransactionScope();
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
            self.requireTransactionScope();
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
            self.requireTransactionScope();
            std.debug.assert(self.next_checkpoint_id < std.math.maxInt(usize));
            const id = self.next_checkpoint_id + 1;
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

        /// Report whether an unresolved transaction currently owns the Executor.
        ///
        /// This is diagnostic state only; it does not grant resolution
        /// authority or expose the active transaction.
        pub fn hasCurrentTransaction(self: *const Self) bool {
            return self.transaction_runtime_state != null;
        }

        /// Restore the mutable branch independently from execution checkpoints.
        pub fn restoreBranch(self: *Self, checkpoint_state: *Self.BranchCheckpoint) void {
            self.state.restoreBranch(checkpoint_state);
        }

        fn hasActiveBlockExecution(self: *const Self) bool {
            return self.active_block_execution_generation != null;
        }

        pub fn acceptedView(self: *const Self) TrackedState.AcceptedView {
            return self.state.acceptedView();
        }

        /// Run protocol finalization, retain the transition, and close its scope.
        pub fn commitTransaction(self: *Self) !void {
            try self.commitTransactionObserved(IgnorePending{});
        }

        /// Finalize and expose the sealed pending view before retaining it.
        /// Observer failure discards the complete transition.
        pub fn commitTransactionObserved(self: *Self, observer: anytype) !void {
            std.debug.assert(self.checkpoint_top == 0);
            std.debug.assert(self.transaction_runtime_state == null);
            try self.finalizeTransactionState();
            try self.resolveManualTransaction(observer);
        }

        /// Apply protocol finalization without resolving the current transition.
        ///
        /// This is an advanced building block for callers that must inspect or
        /// extend finalized state before retaining it.
        pub fn finalizeTransactionState(self: *Self) !void {
            try self.state.finalize(.{
                .existing_account = spec.self_destruct.finalization(false),
                .created_account = spec.self_destruct.finalization(true),
            });
        }

        /// Restore a caller-owned branch checkpoint and discard the transition.
        pub fn rollbackTransaction(self: *Self, checkpoint_state: *Self.BranchCheckpoint) void {
            std.debug.assert(self.checkpoint_top == 0);
            std.debug.assert(self.transaction_runtime_state == null);
            self.restoreBranch(checkpoint_state);
            self.discardStateTransition();
        }

        /// Retain the current manual state transition exactly as it stands.
        ///
        /// This seals and retains mutations but does not run protocol
        /// finalization. Prefer `commitTransaction` unless the caller
        /// deliberately owns finalization. Failure cleanup must use
        /// `discardStateTransition`.
        pub fn retainStateTransition(self: *Self) void {
            self.retainStateTransitionObserved(IgnorePending{}) catch unreachable;
        }

        /// Expose and retain the current manual transition without finalizing it.
        ///
        /// Borrowed pending views are valid only during `observer.observe`.
        /// Observer failure discards the transition.
        pub fn retainStateTransitionObserved(self: *Self, observer: anytype) !void {
            std.debug.assert(self.checkpoint_top == 0);
            std.debug.assert(self.transaction_runtime_state == null);
            if (self.execution_context == null) return;
            try self.resolveManualTransaction(observer);
        }

        /// Discard the active manual transition and close its execution scope.
        ///
        /// This is allocation-free and safe in `defer` or `errdefer`. It is a
        /// no-op after the transition has already been committed, retained, or
        /// discarded.
        pub fn discardStateTransition(self: *Self) void {
            std.debug.assert(self.checkpoint_top == 0);
            std.debug.assert(self.transaction_runtime_state == null);
            if (self.execution_context == null) {
                std.debug.assert(self.manual_state_attempt == null);
                return;
            }
            std.debug.assert(self.state.scopeActive());
            const state_attempt_id = (self.manual_state_attempt orelse unreachable).id;
            self.state.closeScope();
            self.state.discard(state_attempt_id);
            self.manual_state_attempt = null;
            self.execution_context = null;
            self.scope_root = null;
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
            std.debug.assert(self.transaction_runtime_state != null);
            std.debug.assert(!self.state.scopeActive());
            self.execution_context = null;
            self.scope_root = null;
        }

        fn discardCurrentTransaction(self: *Self) void {
            std.debug.assert(self.transaction_runtime_state != null);
            defer self.finishCurrentTransaction(true);
            self.state.discard(self.transaction_runtime_state.?.state_attempt_id);
        }

        fn finishCurrentTransaction(self: *Self, clear_output: bool) void {
            std.debug.assert(self.transaction_runtime_state != null);
            if (clear_output) self.clearLastOutput();
            self.closeTransactionLifetime();
            self.transaction_runtime_state = null;
        }

        /// Borrow the cumulative accepted changes relative to the state reader.
        pub fn acceptedChanges(self: *const Self) TrackedState.ChangesView {
            std.debug.assert(self.transaction_runtime_state == null);
            return self.acceptedView().changes();
        }

        /// Drop the cumulative accepted branch and clear any open context.
        pub fn discardAccepted(self: *Self) void {
            std.debug.assert(self.checkpoint_top == 0);
            std.debug.assert(self.transaction_runtime_state == null);
            self.state.discardAccepted();
            self.execution_context = null;
            self.scope_root = null;
        }

        /// Read account code through tracked state and its canonical reader.
        pub fn getCode(self: *Self, address: Address) ![]const u8 {
            return self.state.getCode(address);
        }

        /// Test code presence from authenticated account metadata.
        pub fn accountHasCode(self: *Self, address: Address) !bool {
            return self.state.accountHasCode(address);
        }

        /// Prepare code according to the executor preprocessing configuration.
        pub fn prepareBytecode(self: *const Self, code: []const u8) !Bytecode {
            return Bytecode.init(self.allocator, code);
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
        /// This does not open or close a transaction scope. Use `executeStandalone` for the
        /// fully-managed raw-message lifecycle.
        pub fn executeMessage(self: *Self, message: Self.Message, gas: execution_values.ExecutionGas) !Self.EvmResult {
            self.validateScopeRoot(.fromMessage(message));
            const call_capture = try runtime.beginRootCapture(self, message, gas);
            const result = try switch (message) {
                .call => |call| runtime.executeCall(self, call, gas),
                .create => |create| runtime.executeCreate(self, create, gas),
            };
            if (call_capture) |token| try runtime.finishRootHostCapture(self, token, result);
            return result;
        }

        fn runStandalone(self: *Self, context: execution_values.ExecutionContext, message: Self.Message, gas: execution_values.ExecutionGas) !Self.EvmResult {
            return self.runStandaloneContext(
                context,
                message,
                gas,
                .{},
                .normal,
                IgnorePending{},
            );
        }

        /// Run one direct message and consume its sealed observations before
        /// the transition is retained.
        fn runStandaloneObserved(
            self: *Self,
            context: execution_values.ExecutionContext,
            message: Self.Message,
            gas: execution_values.ExecutionGas,
            observer: anytype,
        ) !Self.EvmResult {
            return self.runStandaloneContext(
                context,
                message,
                gas,
                .{},
                .observed,
                observer,
            );
        }

        /// Execute one raw message with a managed scope and passive capture.
        ///
        /// `capture` must already be active and outlive this call. Captured
        /// artifacts do not own or resolve transaction state. This uses the
        /// default initial warm set; family validation, charging, settlement,
        /// and receipts remain outside this API.
        pub fn executeCaptured(
            self: *Self,
            context: execution_values.ExecutionContext,
            message: Self.Message,
            gas: execution_values.ExecutionGas,
            capture: *CaptureContext,
        ) !Self.EvmResult {
            return self.runStandaloneContext(
                context,
                message,
                gas,
                .{},
                .{ .captured = capture },
                IgnorePending{},
            );
        }

        /// Execute one normalized raw message with a fully managed lifecycle.
        ///
        /// This opens and resolves the state transition internally. EVM
        /// rollback statuses restore the message checkpoint; successful
        /// execution finalizes and retains state. Family transaction
        /// validation, charging, settlement, and receipts remain outside this
        /// low-level API.
        pub fn executeStandalone(
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

        /// Execute a managed raw message and expose its sealed state before retain.
        ///
        /// `observer` may only borrow the pending view during `observe`; an
        /// observer error discards the complete transition.
        pub fn executeStandaloneObserved(
            self: *Self,
            request: execution_values.EvmExecutionRequest,
            scope_init: execution_values.ExecutionScopeInit,
            observer: anytype,
        ) !Self.EvmResult {
            return self.runStandaloneContext(
                request.context,
                request.message,
                request.gas,
                scope_init,
                .observed,
                observer,
            );
        }

        fn runStandaloneContext(
            self: *Self,
            context: execution_values.ExecutionContext,
            message: Self.Message,
            gas: execution_values.ExecutionGas,
            scope_init: execution_values.ExecutionScopeInit,
            mode: ExecutionMode,
            observer: anytype,
        ) !Self.EvmResult {
            try self.beginMessageScopeContext(context, message, scope_init, mode);
            errdefer self.discardStateTransition();

            var pre_execution = try self.checkpoint();
            defer pre_execution.deinit();

            const result = try self.executeMessage(message, gas);
            if (executionRolledBack(result.status())) {
                try pre_execution.restore();
                try self.retainStateTransitionObserved(observer);
            } else {
                try self.finalizeTransactionState();
                try pre_execution.commit();
                try self.retainStateTransitionObserved(observer);
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
            self.validateScopeContext(request.context);
            self.validateScopeRoot(.fromMessage(request.message));
            return self.executeTransactionRequestTrustedPhased(request);
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
        /// run with a execution context, checkpoint state, and commit/rollback semantics.
        pub fn executeSystemCall(
            self: *Self,
            context: execution_values.ExecutionContext,
            sender: Address,
            recipient: Address,
            input: []const u8,
            gas: execution_values.ExecutionGas,
        ) !Interpreter.Result {
            return self.executeSystemCallMode(
                context,
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
            context: execution_values.ExecutionContext,
            sender: Address,
            recipient: Address,
            input: []const u8,
            gas: execution_values.ExecutionGas,
            observer: anytype,
        ) !Interpreter.Result {
            return self.executeSystemCallMode(
                context,
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
            context: execution_values.ExecutionContext,
            sender: Address,
            recipient: Address,
            input: []const u8,
            gas: execution_values.ExecutionGas,
            capture: *CaptureContext,
            observer: anytype,
        ) !Interpreter.Result {
            return self.executeSystemCallMode(
                context,
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
            context: execution_values.ExecutionContext,
            sender: Address,
            recipient: Address,
            input: []const u8,
            gas: execution_values.ExecutionGas,
            mode: ExecutionMode,
            observer: anytype,
        ) !Interpreter.Result {
            self.beginPreparedCodeExecution();
            defer self.endPreparedCodeExecution();

            try self.beginSystemCall(context, mode);
            errdefer self.discardStateTransition();

            self.clearLastOutput();
            const checkpoint_state = self.state.checkpoint();
            var checkpoint_open = true;
            errdefer {
                if (checkpoint_open) self.state.revertToCheckpoint(checkpoint_state);
            }

            const resolved = try runtime.resolveCode(self, recipient);
            const resolved_view = try runtime.resolvedCodeView(self, resolved);
            const bytecode = try runtime.resolveExecutionCodeView(self, resolved_view);
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

            const call_result = (try switch (mode) {
                .normal, .observed => runtime.executePreparedCallMessageDirect(self, message, bytecode),
                .captured => runtime.executePreparedCallMessage(self, message, bytecode),
            }).expectCall();
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
                try self.retainStateTransitionObserved(observer);
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

test {
    std.testing.refAllDecls(@This());
    _ = @import("./executor_test.zig");
}
