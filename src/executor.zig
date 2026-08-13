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
//! 2. `executeStandalone`, `observe()`, or `capture()` for a fully managed raw
//!    CALL/CREATE message. These do not perform family validation, charging,
//!    or settlement.
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
const AddressWord = evmz.AddressWord;
const AccountState = evmz.state.Account;
const BlockHashSource = evmz.BlockHashSource;
const Bytecode = evmz.Bytecode;
const ExactSpec = @import("./spec.zig").Spec;
const prepared_code = evmz.prepared_code;
const execution_values = @import("./execution.zig");
const Host = evmz.Host;
const Interpreter = evmz.interpreter;
pub const EvmResult = Host.Result;

/// Root execution reports whether the VM reached payload execution so the
/// transaction program can place its preparation checkpoint without
/// duplicating CALL/CREATE dispatch semantics.
pub const TransactionExecutionStage = enum {
    preparation,
    payload,
};

pub const TransactionExecutionOutcome = struct {
    stage: TransactionExecutionStage,
    result: execution_values.ExecutionResult,
};

const call_runtime = @import("./executor/call_runtime.zig");
pub const capture_context = @import("./executor/capture_context.zig");
const call_scratch_storage = @import("./executor/call_scratch.zig");
pub const eip7702 = @import("./executor/eip7702.zig");
const FrameStore = @import("./executor/frame_store.zig");
const host_callbacks = @import("./executor/host_callbacks.zig");
const InstrumentationMode = @import("./executor/instrumentation.zig").Mode;
pub const state_io = @import("./executor/state_io.zig");
pub const system_contracts = @import("./executor/system_contracts.zig");
pub const transfer_logs = @import("./executor/transfer_logs.zig");
const frame_io = @import("./frame_io.zig");
const trace = @import("./trace.zig");
const transaction_runtime = @import("./transaction/runtime.zig");
const uint256 = @import("./uint256.zig");

const CallScratchSlots = std.ArrayList(*call_scratch_storage.Slot);

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
        if (!Address.eql(a.sender, b.sender)) return false;
        if ((a.recipient == null) != (b.recipient == null)) return false;
        if (a.recipient) |recipient| return Address.eql(recipient, b.recipient.?);
        return true;
    }
};

pub const code_deposit_gas: i64 = 200;

/// Construct the public initializer for one state domain. Only domains with a
/// semantic empty baseline may omit `state`; authenticated dense domains keep
/// the field structurally required.
fn ExecutorInitType(comptime StateDomain: type) type {
    const StateInit = StateDomain.ExecutorStateInit;
    if (@hasDecl(StateDomain, "default_executor_state_init")) {
        const default_state: StateInit = StateDomain.default_executor_state_init;
        return struct {
            state: StateInit = default_state,
            /// Caller-owned derived-artifact service. Its allocation, I/O,
            /// synchronization, and capacity policy are outside executor bounds.
            prepared_code_backend: ?prepared_code.Backend = null,
            block_hash_source: ?BlockHashSource = null,
            reentrant_native_contract_runtime: ?execution_values.ReentrantNativeContractRuntime = null,
        };
    }
    return struct {
        state: StateInit,
        prepared_code_backend: ?prepared_code.Backend = null,
        block_hash_source: ?BlockHashSource = null,
        reentrant_native_contract_runtime: ?execution_values.ReentrantNativeContractRuntime = null,
    };
}

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
const Message = execution_values.Message;
pub const default_max_live_frames: usize = @as(usize, Host.max_call_depth) + 1;

pub const CaptureContext = capture_context.Context;

/// Non-consensus capabilities selected when compiling an exact executor.
pub const CompileOptions = struct {
    /// Include opcode-step capture and its traced dispatch table.
    step_capture: bool = false,
};

/// Compile one exact executor over a state domain.
///
/// The domain defines how its executor state is constructed. Admission,
/// authenticated facts, and commitment construction remain outside this
/// executor boundary.
pub fn ExecutorType(
    comptime spec: ExactSpec,
    comptime StateDomain: type,
    comptime options_value: CompileOptions,
) type {
    return struct {
        const Self = @This();
        const runtime = call_runtime.bind(Self);
        const callbacks = host_callbacks.bind(Self);

        pub const specification = spec;
        pub const compile_options = options_value;
        pub const State = StateDomain.State;
        pub const StateAddress = StateDomain.StateAddress;
        pub const BranchCheckpoint = State.BranchCheckpoint;
        pub const Init = ExecutorInitType(StateDomain);

        pub inline fn stateAddress(value: Address) StateAddress {
            return StateDomain.stateAddress(value);
        }

        pub inline fn executionAddress(value: AddressWord) StateAddress {
            return StateDomain.executionAddress(value);
        }

        allocator: std.mem.Allocator,
        state: State,
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
        reentrant_native_contract_runtime: ?execution_values.ReentrantNativeContractRuntime = null,
        prepared_code_backend: ?prepared_code.Backend,
        prepared_code_execution: ?prepared_code.Execution = null,
        prepared_code_execution_depth: usize = 0,
        trace_depth: u16 = 0,
        last_call_output: frame_io.ByteSlot,

        const ManualStateAttempt = struct {
            id: State.AttemptId,
            mode: InstrumentationMode,
        };

        const TransactionRuntimeState = struct {
            state_attempt_id: State.AttemptId,
            generation: u64,
            mode: InstrumentationMode,
            phase: enum { active, pending } = .active,
            nonce_advanced: bool = false,
            payload_started: bool = false,
        };

        /// Callback-scoped semantic view of one sealed transition.
        /// State attempt identity and resolution remain private to Executor.
        pub const Observation = struct {
            log_view: State.LogView,
            changes_view: State.ChangesView,
            observations_view: State.ObservationsView,

            pub fn logs(self: Observation) State.LogView {
                return self.log_view;
            }

            pub fn changes(self: Observation) State.ChangesView {
                return self.changes_view;
            }

            pub fn observations(self: Observation) State.ObservationsView {
                return self.observations_view;
            }
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
                    logs: State.LogView,
                };

                /// Borrow family output and logs while this result is unresolved.
                pub fn view(self: *const Execution) View {
                    return .{
                        .output = &self.output_value,
                        .logs = self.logs(),
                    };
                }

                /// Copy the family output while leaving state unresolved.
                pub fn result(self: Execution) Output {
                    _ = self.state();
                    return self.output_value;
                }

                /// Borrow transaction logs while this result is unresolved.
                pub fn logs(self: Execution) State.LogView {
                    _ = self.state();
                    return self.executor.state.pendingView().logs();
                }

                /// Borrow the callback-scoped semantic observation before resolution.
                pub fn observation(self: Execution) Observation {
                    _ = self.state();
                    return self.executor.currentObservation();
                }

                /// Borrow net state changes before resolution.
                pub fn changes(self: Execution) State.ChangesView {
                    _ = self.state();
                    return self.executor.state.pendingView().changes();
                }

                /// Borrow retained state observations before resolution.
                pub fn observations(self: Execution) State.ObservationsView {
                    _ = self.state();
                    return self.executor.state.pendingView().observations();
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

        pub fn ObservedExecutor(comptime Observer: type) type {
            return struct {
                executor: *Self,
                observer: Observer,

                pub fn beginTransaction(
                    self: @This(),
                    context: execution_values.ExecutionContext,
                    sender: Address,
                    recipient: Address,
                ) !void {
                    try self.executor.beginTransactionMode(context, sender, recipient, .observed);
                }

                pub fn beginMessageScope(
                    self: @This(),
                    request: execution_values.EvmExecutionRequest,
                    scope_init: execution_values.ExecutionScopeInit,
                ) !void {
                    try self.executor.beginMessageScopeContext(request.context, request.message, scope_init, .observed);
                }

                pub fn beginStateTransition(
                    self: @This(),
                    context: execution_values.ExecutionContext,
                ) !void {
                    try self.executor.openTransactionScope(context, .observed);
                }

                pub fn commitTransaction(self: @This()) !void {
                    try self.executor.commitTransactionWithObserver(self.observer);
                }

                pub fn retainStateTransition(self: @This()) !void {
                    try self.executor.retainStateTransitionWithObserver(self.observer);
                }

                pub fn executeStandalone(
                    self: @This(),
                    request: execution_values.EvmExecutionRequest,
                    scope_init: execution_values.ExecutionScopeInit,
                ) !EvmResult {
                    return self.executor.runStandaloneContext(
                        request.context,
                        request.message,
                        request.gas,
                        scope_init,
                        .observed,
                        self.observer,
                    );
                }

                pub fn executeSystemCall(
                    self: @This(),
                    context: execution_values.ExecutionContext,
                    sender: Address,
                    recipient: Address,
                    input: []const u8,
                    gas: execution_values.ExecutionGas,
                ) !execution_values.ExecutionResult {
                    return self.executor.executeSystemCallMode(
                        context,
                        sender,
                        recipient,
                        input,
                        gas,
                        .observed,
                        self.observer,
                    );
                }
            };
        }

        /// Bind an observer to observed execution operations.
        pub fn observe(self: *Self, observer: anytype) ObservedExecutor(@TypeOf(observer)) {
            return .{ .executor = self, .observer = observer };
        }

        pub const CapturedExecutor = struct {
            executor: *Self,
            context: *CaptureContext,

            pub fn beginTransaction(
                self: CapturedExecutor,
                execution_context: execution_values.ExecutionContext,
                sender: Address,
                recipient: Address,
            ) !void {
                try self.executor.beginTransactionMode(
                    execution_context,
                    sender,
                    recipient,
                    .{ .captured = self.context },
                );
            }

            pub fn execute(
                self: CapturedExecutor,
                execution_context: execution_values.ExecutionContext,
                message: Message,
                gas: execution_values.ExecutionGas,
            ) !EvmResult {
                return self.executor.runStandaloneContext(
                    execution_context,
                    message,
                    gas,
                    .{},
                    .{ .captured = self.context },
                    {},
                );
            }

            pub fn executeSystemCall(
                self: CapturedExecutor,
                execution_context: execution_values.ExecutionContext,
                sender: Address,
                recipient: Address,
                input: []const u8,
                gas: execution_values.ExecutionGas,
                observer: anytype,
            ) !execution_values.ExecutionResult {
                return self.executor.executeSystemCallMode(
                    execution_context,
                    sender,
                    recipient,
                    input,
                    gas,
                    .{ .captured = self.context },
                    observer,
                );
            }
        };

        /// Borrow a captured execution view. The facade owns no transaction or
        /// capture lifetime; both remain with the Executor and caller context.
        pub fn capture(self: *Self, context: *CaptureContext) CapturedExecutor {
            return .{ .executor = self, .context = context };
        }

        pub fn transactionAccountSummary(self: *Self, account_address: Address) !?AccountState {
            transaction_runtime.requireActive(self);
            return self.getAccountOrLoad(account_address);
        }

        pub fn advanceTransactionNonce(
            self: *Self,
            message: Message,
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
            journal_checkpoint: State.Checkpoint,
            id: usize,
            parent_id: usize,
            open: bool = true,

            pub fn commit(self: *ExecutionCheckpoint) void {
                self.validateClose();
                self.executor.state.commitCheckpoint(self.journal_checkpoint);
                self.finishClose();
            }

            pub fn restore(self: *ExecutionCheckpoint) void {
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

        /// Construct and take exclusive ownership of domain state.
        pub fn init(allocator: std.mem.Allocator, options: Init) Self {
            return .{
                .allocator = allocator,
                .state = StateDomain.initExecutorState(allocator, options.state),
                .frame_store = .{ .stable_metadata_capacity = default_max_live_frames },
                .call_scratch_slots = .empty,
                .prepared_code_scratch = call_scratch_storage.Slot.init(allocator),
                .block_hash_source = options.block_hash_source,
                .reentrant_native_contract_runtime = options.reentrant_native_contract_runtime,
                .prepared_code_backend = options.prepared_code_backend,
                .last_call_output = frame_io.ByteSlot.init(allocator),
            };
        }

        pub fn currentCaptureContext(self: *Self) ?*CaptureContext {
            if (self.transaction_runtime_state) |attempt|
                return attempt.mode.captureContext();
            if (self.manual_state_attempt) |attempt|
                return attempt.mode.captureContext();
            return null;
        }

        fn assertExecutionMode(mode: InstrumentationMode) void {
            const context = mode.captureContext() orelse return;
            std.debug.assert(context.isActive());
        }

        pub fn traceAccountAccess(self: *Self, account_address: Address) !void {
            try self.state.observeAccountAccess(stateAddress(account_address));
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

        pub fn reserveAcceptedAccessHint(self: *Self, hint: State.AccessHint) !void {
            try self.state.reserveAcceptedAccessHint(hint);
        }

        /// Release state, frame pools, scratch arenas, and retained frame buffers.
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
            try self.state.warmAccount(stateAddress(sender));
            if (recipient) |address| {
                try self.state.warmAccount(stateAddress(address));
            }
            self.scope_root = .{ .sender = sender, .recipient = recipient };
        }

        fn openTransactionScope(
            self: *Self,
            context: execution_values.ExecutionContext,
            mode: InstrumentationMode,
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
            try self.beginTransactionMode(context, sender, recipient, .normal);
        }

        fn beginTransactionMode(
            self: *Self,
            context: execution_values.ExecutionContext,
            sender: Address,
            recipient: Address,
            mode: InstrumentationMode,
        ) !void {
            try self.openTransactionScope(context, mode);
            errdefer self.discardStateTransition();
            try warmTransactionAccesses(self, sender, recipient);
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

        fn beginMessageScopeContext(
            self: *Self,
            context: execution_values.ExecutionContext,
            message: Message,
            scope_init: execution_values.ExecutionScopeInit,
            mode: InstrumentationMode,
        ) !void {
            try self.openTransactionScope(context, mode);
            errdefer self.discardStateTransition();

            try transaction_runtime.initializeMessageScope(self, message, scope_init);
        }

        fn beginSystemCall(
            self: *Self,
            context: execution_values.ExecutionContext,
            mode: InstrumentationMode,
        ) !void {
            try self.openTransactionScope(context, mode);
        }

        /// Open a transaction-like scope for family/STF state work without a
        /// root EVM message. Retain or discard it explicitly.
        pub fn beginStateTransition(self: *Self, context: execution_values.ExecutionContext) !void {
            try self.openTransactionScope(context, .normal);
        }

        /// Mark an account warm in the current transaction scope.
        pub fn warmAccount(self: *Self, address: Address) !void {
            self.requireTransactionScope();
            try self.state.warmAccount(stateAddress(address));
        }

        /// Mark a storage slot warm in the current transaction scope.
        pub fn warmStorage(self: *Self, address: Address, key: u256) !void {
            self.requireTransactionScope();
            try self.state.warmStorage(stateAddress(address), key);
        }

        /// Return account metadata already present in tracked state.
        pub fn getAccount(self: *const Self, address: Address) ?AccountState {
            return self.state.getAccount(stateAddress(address));
        }

        /// Return account metadata, loading it from the state reader if needed.
        pub fn getAccountOrLoad(self: *Self, address: Address) !?AccountState {
            return self.state.getAccountOrLoad(stateAddress(address));
        }

        /// Read storage through tracked state and its canonical reader.
        pub fn getStorage(self: *Self, address: Address, key: u256) !u256 {
            return self.state.getStorage(stateAddress(address), key);
        }

        /// Read an account balance through tracked state and its canonical reader.
        pub fn getBalance(self: *Self, address: Address) !u256 {
            return self.state.getBalance(stateAddress(address));
        }

        /// Add balance as a direct family/STF state transition.
        pub fn addBalance(self: *Self, address: Address, value: u256) !void {
            try self.state.addBalance(stateAddress(address), value);
        }

        pub fn subtractBalance(self: *Self, address: Address, value: u256) !bool {
            return self.state.subtractBalance(stateAddress(address), value);
        }

        pub fn setNonce(self: *Self, address: Address, nonce: u64) !void {
            try self.state.setNonce(stateAddress(address), nonce);
        }

        pub fn touchAccount(self: *Self, address: Address) !void {
            try self.state.touchAccount(stateAddress(address));
        }

        /// Record one semantic account access without changing warmth or
        /// loading account metadata.
        pub fn observeAccountAccess(self: *Self, address_value: Address) !void {
            self.requireTransactionScope();
            try self.state.observeAccountAccess(stateAddress(address_value));
        }

        /// Set account code as a direct family/STF state transition.
        pub fn setCode(self: *Self, address: Address, code: []const u8) !void {
            try self.state.setCode(stateAddress(address), code);
        }

        pub fn clearCode(self: *Self, address: Address) !void {
            try self.state.clearCode(stateAddress(address));
        }

        pub fn logView(self: *const Self) State.LogView {
            return self.state.logView();
        }

        pub fn clearLogs(self: *Self) void {
            self.state.clearLogs();
        }

        /// Capture the mutable branch independently from execution checkpoints.
        pub fn branchCheckpoint(self: *Self) !Self.BranchCheckpoint {
            return self.state.branchCheckpoint();
        }

        /// Open one journal-backed checkpoint inside the active execution scope.
        pub fn checkpoint(self: *Self) ExecutionCheckpoint {
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

        pub fn acceptedView(self: *const Self) State.AcceptedView {
            return self.state.acceptedView();
        }

        fn currentObservation(self: *const Self) Observation {
            const pending = self.state.pendingView();
            return .{
                .log_view = pending.logs(),
                .changes_view = pending.changes(),
                .observations_view = pending.observations(),
            };
        }

        /// Run protocol finalization, retain the transition, and close its scope.
        pub fn commitTransaction(self: *Self) !void {
            try self.commitTransactionWithObserver({});
        }

        fn commitTransactionWithObserver(self: *Self, observer: anytype) !void {
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
            self.retainStateTransitionWithObserver({}) catch unreachable;
        }

        fn retainStateTransitionWithObserver(self: *Self, observer: anytype) !void {
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
            self.closeManualTransactionLifetime();
        }

        fn resolveManualTransaction(self: *Self, observer: anytype) !void {
            std.debug.assert(self.state.scopeActive());
            const state_attempt_id = (self.manual_state_attempt orelse unreachable).id;
            self.state.closeScope();
            self.state.seal(state_attempt_id);
            if (comptime @TypeOf(observer) != void)
                observer.observe(self.currentObservation()) catch |err| {
                    self.state.discard(state_attempt_id);
                    self.closeManualTransactionLifetime();
                    return err;
                };
            self.state.retain(state_attempt_id);
            self.closeManualTransactionLifetime();
        }

        fn closeManualTransactionLifetime(self: *Self) void {
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
        pub fn acceptedChanges(self: *const Self) State.ChangesView {
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
            return self.state.getCode(stateAddress(address));
        }

        /// Test code presence from authenticated account metadata.
        pub fn accountHasCode(self: *Self, address: Address) !bool {
            return self.state.accountHasCode(stateAddress(address));
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
        pub fn executeCall(self: *Self, message: Call, gas: execution_values.ExecutionGas) !EvmResult {
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
        ) !execution_values.ExecutionResult {
            return runtime.executeCallTransaction(self, sender, recipient, input, gas, value);
        }

        /// Execute a raw call with caller-provided prepared bytecode.
        pub fn executePreparedCallTransaction(self: *Self, options: PreparedCallTransaction) !execution_values.ExecutionResult {
            return runtime.executePreparedCallTransaction(self, options);
        }

        /// Execute a raw create/create2 message inside an already-open tx scope.
        pub fn executeCreate(self: *Self, message: Create, gas: execution_values.ExecutionGas) !EvmResult {
            return runtime.executeCreate(self, message, gas);
        }

        /// Execute a raw call/create message inside an already-open tx scope.
        ///
        /// This does not open or close a transaction scope. Use `executeStandalone` for the
        /// fully-managed raw-message lifecycle.
        pub fn executeMessage(self: *Self, message: Message, gas: execution_values.ExecutionGas) !EvmResult {
            self.validateScopeRoot(.fromMessage(message));
            const call_capture = try runtime.beginRootCapture(self, message, gas);
            const result = try switch (message) {
                .call => |call| runtime.executeCall(self, call, gas),
                .create => |create| runtime.executeCreate(self, create, gas),
            };
            if (call_capture) |token| try runtime.finishRootHostCapture(self, token, result);
            return result;
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
        ) !EvmResult {
            return self.runStandaloneContext(
                request.context,
                request.message,
                request.gas,
                scope_init,
                .normal,
                {},
            );
        }

        fn runStandaloneContext(
            self: *Self,
            context: execution_values.ExecutionContext,
            message: Message,
            gas: execution_values.ExecutionGas,
            scope_init: execution_values.ExecutionScopeInit,
            mode: InstrumentationMode,
            observer: anytype,
        ) !EvmResult {
            try self.beginMessageScopeContext(context, message, scope_init, mode);
            errdefer self.discardStateTransition();

            var pre_execution = self.checkpoint();
            defer pre_execution.deinit();

            const result = try self.executeMessage(message, gas);
            if (executionRolledBack(result.status())) {
                pre_execution.restore();
                try self.retainStateTransitionWithObserver(observer);
            } else {
                try self.finalizeTransactionState();
                pre_execution.commit();
                try self.retainStateTransitionWithObserver(observer);
            }
            return result;
        }

        /// Execute the normalized request inside its already-open transaction scope.
        ///
        /// The caller owns transaction charging, nonce/access/auth handling, settlement,
        /// and final commit/rollback. Transaction programs compose those pieces.
        pub fn executeTransactionRequest(self: *Self, request: execution_values.EvmExecutionRequest) !execution_values.ExecutionResult {
            return (try self.executeTransactionRequestPhased(request)).result;
        }

        /// Execute one root request and report whether dispatch preparation
        /// completed. The result remains an EVM result; the stage is only the
        /// stage fact needed by a family transaction coordinator to choose
        /// its outer rollback boundary.
        pub fn executeTransactionRequestPhased(
            self: *Self,
            request: execution_values.EvmExecutionRequest,
        ) !TransactionExecutionOutcome {
            self.validateScopeContext(request.context);
            self.validateScopeRoot(.fromMessage(request.message));
            return self.executeTransactionRequestTrustedPhased(request);
        }

        fn executeTransactionRequestTrustedPhased(
            self: *Self,
            request: execution_values.EvmExecutionRequest,
        ) !TransactionExecutionOutcome {
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
        ) !execution_values.ExecutionResult {
            return self.executeSystemCallMode(
                context,
                sender,
                recipient,
                input,
                gas,
                .normal,
                {},
            );
        }

        fn executeSystemCallMode(
            self: *Self,
            context: execution_values.ExecutionContext,
            sender: Address,
            recipient: Address,
            input: []const u8,
            gas: execution_values.ExecutionGas,
            mode: InstrumentationMode,
            observer: anytype,
        ) !execution_values.ExecutionResult {
            self.beginPreparedCodeExecution();
            defer self.endPreparedCodeExecution();

            try self.beginSystemCall(context, mode);
            errdefer self.discardStateTransition();

            self.clearLastOutput();
            var execution_checkpoint = self.checkpoint();
            defer execution_checkpoint.deinit();

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

            const host_result = try switch (mode) {
                .normal, .observed => runtime.executePreparedCallMessageDirect(self, message, bytecode),
                .captured => runtime.executePreparedCallMessage(self, message, bytecode),
            };

            if (executionRolledBack(host_result.status())) {
                execution_checkpoint.restore();
                try self.retainStateTransitionWithObserver(observer);
            } else {
                execution_checkpoint.commit();
                try self.commitTransactionWithObserver(observer);
            }

            return host_result.executionResult(self.lastOutputData());
        }

        /// Transfer value between accounts, returning false on insufficient balance.
        pub fn transferValue(self: *Self, sender: Address, recipient: Address, value: u256) !bool {
            if (value == 0) return true;
            if (!try self.state.subtractBalance(stateAddress(sender), value)) return false;
            try self.state.addBalance(stateAddress(recipient), value);
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
            try self.state.setNonce(stateAddress(address), std.math.add(u64, account.nonce, 1) catch std.math.maxInt(u64));
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
