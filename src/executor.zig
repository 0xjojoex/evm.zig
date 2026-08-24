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

const std = @import("std");

const evmz = @import("./evm.zig");
const call_scratch_storage = @import("./executor/call_scratch.zig");
const checkpoint_guard = @import("./executor/checkpoint.zig");
const frame_io = @import("./frame_io.zig");
const FrameStore = @import("./executor/FrameStore.zig");
const HostCallbacks = @import("./executor/host.zig").Callbacks;
const InstrumentationMode = @import("./executor/instrumentation.zig").Mode;
const top_frame_gas = @import("./executor/top_frame_gas.zig");
const trace_capture = @import("./executor/trace_capture.zig");
const transaction_runtime = @import("./transaction/runtime.zig");
pub const capture_context = @import("./executor/capture_context.zig");
pub const eip7702 = @import("./executor/eip7702.zig");
pub const errors = @import("./executor/error.zig");
pub const state_io = @import("./executor/state_io.zig");
pub const system_contracts = @import("./executor/system_contracts.zig");

const Address = evmz.Address;
const AddressWord = evmz.AddressWord;
const AccountState = evmz.state.Account;
const BlockHashSource = evmz.BlockHashSource;
const Bytecode = evmz.Bytecode;
const Spec = @import("./spec.zig").Spec;
const prepared_code = evmz.prepared_code;
const ExecutionContext = evmz.execution.ExecutionContext;
const ExecutionGas = evmz.execution.ExecutionGas;
const ExecutionResult = evmz.execution.ExecutionResult;
const ExecutionRequest = evmz.execution.ExecutionRequest;
const ExecutionScopeInit = evmz.execution.ExecutionScopeInit;
const Host = evmz.Host;
const Interpreter = evmz.interpreter;
const FrameResult = Interpreter.FrameResult;
pub const Result = Host.Result;

/// Root execution reports whether the VM reached payload execution so the
/// transaction program can place its preparation checkpoint without
/// duplicating CALL/CREATE dispatch semantics.
pub const TransactionExecutionStage = enum {
    preparation,
    payload,
};

pub const TransactionExecutionOutcome = struct {
    stage: TransactionExecutionStage,
    result: ExecutionResult,
};

const ScopeRoot = struct {
    sender: Address,
    recipient: ?Address,

    fn fromMessage(message: evmz.Message) ScopeRoot {
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

/// Construct the public initializer for one execution-state implementation.
/// Implementations with a semantic empty baseline may omit `state`;
/// authenticated dense state keeps
/// the field structurally required.
fn ExecutorInitType(comptime Execution: type) type {
    const StateInit = Execution.Init;
    if (Execution.default_init) |default_state| {
        return struct {
            state: StateInit = default_state,
            /// Caller-owned derived-artifact service. Its allocation, I/O,
            /// synchronization, and capacity policy are outside executor bounds.
            prepared_code_backend: ?prepared_code.Backend = null,
            block_hash_source: ?BlockHashSource = null,
            reentrant_native_contract_runtime: ?evmz.execution.ReentrantNativeContractRuntime = null,
        };
    }
    return struct {
        state: StateInit,
        prepared_code_backend: ?prepared_code.Backend = null,
        block_hash_source: ?BlockHashSource = null,
        reentrant_native_contract_runtime: ?evmz.execution.ReentrantNativeContractRuntime = null,
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

pub const Call = evmz.execution.Call;
pub const Create = evmz.execution.Create;
const Message = evmz.execution.Message;
pub const default_max_live_frames: usize = @as(usize, Host.max_call_depth) + 1;

pub const CaptureContext = capture_context.Context;

/// Non-consensus capabilities selected when compiling an exact executor.
pub const CompileOptions = struct {
    /// Include opcode-step capture and its traced dispatch table.
    step_capture: bool = false,
};

/// Compile one exact executor over an execution-state implementation.
///
/// The domain defines how its executor state is constructed. Admission,
/// authenticated facts, and commitment construction remain outside this
/// executor boundary.
pub fn ExecutorType(
    comptime spec: Spec,
    comptime ExecutionState: type,
    comptime options_value: CompileOptions,
) type {
    comptime ExecutionState.checkSpec(spec);

    return struct {
        const Executor = @This();

        const BoundInterpreter = Interpreter.Interpreter(spec);

        const callbacks = HostCallbacks(spec, ExecutionState, options_value);

        pub const State = ExecutionState.State;

        pub const StateAddress = ExecutionState.StateAddress;

        pub const BranchCheckpoint = State.BranchCheckpoint;

        pub const Init = ExecutorInitType(ExecutionState);

        pub inline fn stateAddress(value: Address) StateAddress {
            return ExecutionState.stateAddress(value);
        }

        pub inline fn executionAddress(value: AddressWord) StateAddress {
            return ExecutionState.executionAddress(value);
        }

        allocator: std.mem.Allocator,
        state: State,
        frame_store: FrameStore,
        call_scratch_slots: std.ArrayList(*call_scratch_storage.Slot),
        prepared_code_scratch: call_scratch_storage.Slot,
        execution_context: ?ExecutionContext = null,
        scope_root: ?ScopeRoot = null,
        attempt: ?Attempt = null,
        next_transaction_generation: u64 = 0,
        active_block_execution_generation: ?u64 = null,
        next_block_execution_generation: u64 = 0,
        checkpoint_top: usize = 0,
        next_checkpoint_id: usize = 0,
        block_hash_source: ?BlockHashSource = null,
        reentrant_native_contract_runtime: ?evmz.execution.ReentrantNativeContractRuntime = null,
        prepared_code_backend: ?prepared_code.Backend,
        prepared_code_execution: ?prepared_code.Execution = null,
        prepared_code_execution_depth: usize = 0,
        trace_depth: u16 = 0,
        last_call_output: frame_io.ByteSlot,

        /// Construct and take exclusive ownership of domain state.
        pub fn init(allocator: std.mem.Allocator, options: Init) Executor {
            return .{
                .allocator = allocator,
                .state = ExecutionState.init(spec, allocator, options.state),
                .frame_store = .{ .stable_metadata_capacity = default_max_live_frames },
                .call_scratch_slots = .empty,
                .prepared_code_scratch = .init(allocator),
                .block_hash_source = options.block_hash_source,
                .reentrant_native_contract_runtime = options.reentrant_native_contract_runtime,
                .prepared_code_backend = options.prepared_code_backend,
                .last_call_output = .init(allocator),
            };
        }

        /// Release state, frame pools, scratch arenas, and retained frame buffers.
        pub fn deinit(self: *Executor) void {
            std.debug.assert(!self.hasActiveBlockExecution());
            std.debug.assert(self.frame_store.len() == 0);
            std.debug.assert(self.checkpoint_top == 0);
            std.debug.assert(!self.hasCurrentTransaction());
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

        // Transaction scope: at most one attempt is live between open and close.

        /// The one live state attempt. `owner` records which lifecycle opened
        /// it and therefore who may resolve it: scope methods resolve `manual`
        /// attempts, `transaction/runtime.zig` resolves `transaction` ones
        /// through an `Executed` handle.
        const Attempt = struct {
            id: State.AttemptId,
            mode: InstrumentationMode,
            owner: Owner,

            const Owner = union(enum) {
                manual,
                transaction: Transaction,
            };

            /// Family-transaction bookkeeping that a manual attempt has no use for.
            const Transaction = struct {
                generation: u64,
                phase: enum { active, pending } = .active,
                nonce_advanced: bool = false,
                payload_started: bool = false,
            };
        };

        /// The family row inside the live attempt. Callers that may run under a
        /// manual attempt must test `hasCurrentTransaction` first.
        fn transactionAttempt(self: *Executor) *Attempt.Transaction {
            const attempt = if (self.attempt) |*value| value else unreachable;
            return switch (attempt.owner) {
                .manual => unreachable,
                .transaction => |*value| value,
            };
        }

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

        fn openTransactionScope(
            self: *Executor,
            context: ExecutionContext,
            mode: InstrumentationMode,
        ) !void {
            std.debug.assert(self.execution_context == null);
            std.debug.assert(self.checkpoint_top == 0);
            std.debug.assert(self.attempt == null);
            assertExecutionMode(mode);
            const state_attempt_id = if (mode.observesState())
                self.state.beginObservedTransaction()
            else
                self.state.beginTransaction();
            self.state.beginScope();
            self.attempt = .{ .id = state_attempt_id, .mode = mode, .owner = .manual };
            self.execution_context = context;
            self.scope_root = null;
        }

        fn warmTransactionAccesses(
            self: *Executor,
            sender: Address,
            recipient: ?Address,
        ) !void {
            try self.state.warmAccount(stateAddress(sender));
            if (recipient) |address| {
                try self.state.warmAccount(stateAddress(address));
            }
            self.scope_root = .{ .sender = sender, .recipient = recipient };
        }

        fn requireTransactionScope(self: *const Executor) void {
            std.debug.assert(self.execution_context != null);
        }

        fn validateScopeContext(self: *const Executor, context: ExecutionContext) void {
            self.requireTransactionScope();
            std.debug.assert(self.execution_context.?.eql(context));
        }

        fn validateScopeRoot(self: *const Executor, root: ScopeRoot) void {
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
        pub fn beginTransaction(self: *Executor, context: ExecutionContext, sender: Address, recipient: Address) !void {
            try self.beginTransactionMode(context, sender, recipient, .normal);
        }

        fn beginTransactionMode(
            self: *Executor,
            context: ExecutionContext,
            sender: Address,
            recipient: Address,
            mode: InstrumentationMode,
        ) !void {
            try self.openTransactionScope(context, mode);
            errdefer self.discardStateTransition();
            try self.warmTransactionAccesses(sender, recipient);
        }

        /// Open a direct message-execution scope from its authoritative context.
        ///
        /// This is open-only: callers own checkpoint placement, execution, and
        /// the eventual commit, rollback, retain, or discard. Mandatory
        /// sender/recipient warmth is derived from `request`;
        /// `scope_init` supplies family- or witness-resolved warmth beyond the
        /// mandatory root sender/recipient accounts.
        pub fn beginMessageScope(
            self: *Executor,
            request: evmz.execution.ExecutionRequest,
            scope_init: ExecutionScopeInit,
        ) !void {
            try self.beginMessageScopeContext(request.context, request.message, scope_init, .normal);
        }

        fn beginMessageScopeContext(
            self: *Executor,
            context: ExecutionContext,
            message: Message,
            scope_init: ExecutionScopeInit,
            mode: InstrumentationMode,
        ) !void {
            try self.openTransactionScope(context, mode);
            errdefer self.discardStateTransition();

            try transaction_runtime.initializeMessageScope(self, message, scope_init, .none);
        }

        fn beginSystemCall(
            self: *Executor,
            context: ExecutionContext,
            mode: InstrumentationMode,
        ) !void {
            try self.openTransactionScope(context, mode);
        }

        /// Open a transaction-like scope for family/STF state work without a
        /// root EVM message. Retain or discard it explicitly.
        pub fn beginStateTransition(self: *Executor, context: ExecutionContext) !void {
            try self.openTransactionScope(context, .normal);
        }

        pub fn advanceTransactionNonce(self: *Executor, message: Message) !void {
            const runtime_state = self.transactionAttempt();
            std.debug.assert(runtime_state.phase == .active);
            std.debug.assert(!runtime_state.nonce_advanced);
            std.debug.assert(!runtime_state.payload_started);
            self.validateScopeRoot(.fromMessage(message));

            try self.incrementNonce(message.sender());
            runtime_state.nonce_advanced = true;
        }

        pub fn transactionAccountSummary(self: *Executor, account_address: Address) !?AccountState {
            transaction_runtime.requireActive(self);
            return self.getAccountOrLoad(account_address);
        }

        /// Report whether an unresolved transaction currently owns the Executor.
        ///
        /// This is diagnostic state only; it does not grant resolution
        /// authority or expose the active transaction.
        pub fn hasCurrentTransaction(self: *const Executor) bool {
            const attempt = self.attempt orelse return false;
            return switch (attempt.owner) {
                .manual => false,
                .transaction => true,
            };
        }

        fn hasActiveBlockExecution(self: *const Executor) bool {
            return self.active_block_execution_generation != null;
        }

        fn currentObservation(self: *const Executor) Observation {
            const pending = self.state.pendingView();
            return .{
                .log_view = pending.logs(),
                .changes_view = pending.changes(),
                .observations_view = pending.observations(),
            };
        }

        /// Apply protocol finalization without resolving the current transition.
        ///
        /// This is an advanced building block for callers that must inspect or
        /// extend finalized state before retaining it.
        pub fn finalizeTransactionState(self: *Executor) !void {
            try self.state.finalize(.{
                .existing_account = spec.self_destruct.finalization(false),
                .created_account = spec.self_destruct.finalization(true),
            });
        }

        /// Run protocol finalization, retain the transition, and close its scope.
        pub fn commitTransaction(self: *Executor) !void {
            try self.commitTransactionWithObserver({});
        }

        fn commitTransactionWithObserver(self: *Executor, observer: anytype) !void {
            std.debug.assert(self.checkpoint_top == 0);
            std.debug.assert(!self.hasCurrentTransaction());
            try self.finalizeTransactionState();
            try self.resolveManualTransaction(observer);
        }

        /// Retain the current manual state transition exactly as it stands.
        ///
        /// This seals and retains mutations but does not run protocol
        /// finalization. Prefer `commitTransaction` unless the caller
        /// deliberately owns finalization. Failure cleanup must use
        /// `discardStateTransition`.
        pub fn retainStateTransition(self: *Executor) void {
            self.retainStateTransitionWithObserver({}) catch unreachable;
        }

        fn retainStateTransitionWithObserver(self: *Executor, observer: anytype) !void {
            std.debug.assert(self.checkpoint_top == 0);
            std.debug.assert(!self.hasCurrentTransaction());
            if (self.execution_context == null) return;
            try self.resolveManualTransaction(observer);
        }

        /// Restore a caller-owned branch checkpoint and discard the transition.
        pub fn rollbackTransaction(self: *Executor, checkpoint_state: *BranchCheckpoint) void {
            std.debug.assert(self.checkpoint_top == 0);
            std.debug.assert(!self.hasCurrentTransaction());
            self.restoreBranch(checkpoint_state);
            self.discardStateTransition();
        }

        /// Discard the active manual transition and close its execution scope.
        ///
        /// This is allocation-free and safe in `defer` or `errdefer`. It is a
        /// no-op after the transition has already been committed, retained, or
        /// discarded.
        pub fn discardStateTransition(self: *Executor) void {
            std.debug.assert(self.checkpoint_top == 0);
            std.debug.assert(!self.hasCurrentTransaction());
            if (self.execution_context == null) {
                std.debug.assert(self.attempt == null);
                return;
            }
            std.debug.assert(self.state.scopeActive());
            const state_attempt_id = (self.attempt orelse unreachable).id;
            self.state.closeScope();
            self.state.discard(state_attempt_id);
            self.closeManualTransactionLifetime();
        }

        fn resolveManualTransaction(self: *Executor, observer: anytype) !void {
            std.debug.assert(self.state.scopeActive());
            const state_attempt_id = (self.attempt orelse unreachable).id;
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

        fn closeManualTransactionLifetime(self: *Executor) void {
            self.attempt = null;
            self.execution_context = null;
            self.scope_root = null;
        }

        /// Close whichever execution scope belongs to a resolved transaction
        /// attempt, or clear an execution-less attempt's retained journal.
        fn closeTransactionLifetime(self: *Executor) void {
            std.debug.assert(self.checkpoint_top == 0);
            std.debug.assert(self.hasCurrentTransaction());
            std.debug.assert(!self.state.scopeActive());
            self.execution_context = null;
            self.scope_root = null;
        }

        fn discardCurrentTransaction(self: *Executor) void {
            std.debug.assert(self.hasCurrentTransaction());
            defer self.finishCurrentTransaction(true);
            self.state.discard(self.attempt.?.id);
        }

        fn finishCurrentTransaction(self: *Executor, clear_output: bool) void {
            std.debug.assert(self.hasCurrentTransaction());
            if (clear_output) self.clearLastOutput();
            self.closeTransactionLifetime();
            self.attempt = null;
        }

        /// The exclusive externally copyable owner of one completed but
        /// unresolved transaction. Executor keeps the phase state; this value
        /// carries the generation needed to reject stale copies.
        pub fn Executed(comptime Output: type) type {
            return struct {
                const Execution = @This();

                executor: *Executor,
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
                    _ = self.state();
                    self.executor.state.retain(self.executor.attempt.?.id);
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
                    if (!self.executor.hasCurrentTransaction()) return;
                    const current = self.executor.transactionAttempt();
                    if (current.generation != self.generation or current.phase != .pending) return;
                    self.discard();
                }

                fn state(self: Execution) *Attempt.Transaction {
                    const state_value = self.executor.transactionAttempt();
                    std.debug.assert(state_value.generation == self.generation);
                    std.debug.assert(state_value.phase == .pending);
                    return state_value;
                }
            };
        }

        // Checkpoints. `ExecutionCheckpoint` is the public id-nested token; `CheckpointGuard`
        // is the interior one whose ownership migrates into a frame-store row.

        /// Scope-bound execution checkpoint paired with one trace/BAL lifecycle.
        ///
        /// This journal-backed token must be opened and closed inside one active
        /// transaction scope. It never finalizes or closes that scope. The owning
        /// transaction runtime can span prelude writes and payload execution;
        /// broader block phases still use their own STF/backend lifetime.
        /// Treat this token as move-only.
        pub const ExecutionCheckpoint = struct {
            executor: *Executor,
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

        /// Open one journal-backed checkpoint inside the active execution scope.
        pub fn checkpoint(self: *Executor) ExecutionCheckpoint {
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

        /// Capture the mutable branch independently from execution checkpoints.
        pub fn branchCheckpoint(self: *Executor) !BranchCheckpoint {
            return self.state.branchCheckpoint();
        }

        /// Restore the mutable branch independently from execution checkpoints.
        pub fn restoreBranch(self: *Executor, checkpoint_state: *BranchCheckpoint) void {
            self.state.restoreBranch(checkpoint_state);
        }

        const CheckpointGuard = checkpoint_guard.Guard(State);

        // Ambient per-execution state. Each of these is saved and restored by hand at
        // every entrypoint that owns it, rather than inherited from a scope value.

        pub fn currentExecutionContext(self: *const Executor) *const ExecutionContext {
            return if (self.execution_context) |*context| context else unreachable;
        }

        pub fn currentCaptureContext(self: *Executor) ?*CaptureContext {
            const attempt = self.attempt orelse return null;
            return attempt.mode.captureContext();
        }

        fn assertExecutionMode(mode: InstrumentationMode) void {
            const context = mode.captureContext() orelse return;
            std.debug.assert(context.isActive());
        }

        pub fn beginPreparedCodeExecution(self: *Executor) void {
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

        pub fn endPreparedCodeExecution(self: *Executor) void {
            std.debug.assert(self.prepared_code_execution_depth > 0);
            self.prepared_code_execution_depth -= 1;
            if (self.prepared_code_execution_depth != 0) return;

            self.prepared_code_execution.?.deinit();
            self.prepared_code_execution = null;
            self.prepared_code_scratch.reset();
        }

        /// Reuse prepared code and cleared transaction containers for one
        /// sequential protocol-call batch.
        pub fn beginSystemCallBatch(self: *Executor) void {
            self.beginPreparedCodeExecution();
            self.state.beginTransactionCapacityReuse();
        }

        pub fn endSystemCallBatch(self: *Executor) void {
            self.state.endTransactionCapacityReuse();
            self.endPreparedCodeExecution();
        }

        const ScratchScope = struct {
            executor: *Executor,
            depth: u16,
            allocator: std.mem.Allocator,

            pub fn deinit(self: *ScratchScope) void {
                self.executor.endCallScratch(self.depth);
                self.* = undefined;
            }
        };

        pub fn callScratch(self: *Executor, depth: u16) !ScratchScope {
            return .{
                .executor = self,
                .depth = depth,
                .allocator = try self.beginCallScratch(depth),
            };
        }

        fn beginCallScratch(self: *Executor, depth: u16) !std.mem.Allocator {
            const index: usize = depth;
            while (self.call_scratch_slots.items.len <= index) {
                const slot = try self.allocator.create(call_scratch_storage.Slot);
                errdefer self.allocator.destroy(slot);
                slot.* = call_scratch_storage.Slot.init(self.allocator);
                errdefer slot.deinit();
                try self.call_scratch_slots.append(self.allocator, slot);
            }
            self.call_scratch_slots.items[index].reset();
            return self.call_scratch_slots.items[index].allocator();
        }

        fn endCallScratch(self: *Executor, depth: u16) void {
            const index: usize = depth;
            if (index < self.call_scratch_slots.items.len) {
                self.call_scratch_slots.items[index].reset();
            }
        }

        /// Drop the retained output buffer from the last call/create result.
        pub fn clearLastOutput(self: *Executor) void {
            _ = self.last_call_output.clear();
        }

        pub fn lastOutputData(self: *const Executor) []u8 {
            return self.last_call_output.slice();
        }

        fn setLastOutput(self: *Executor, output_data: []const u8) ![]u8 {
            self.clearLastOutput();
            return self.last_call_output.replace(output_data);
        }

        pub fn stabilizeFinalResult(self: *Executor, result: Host.Result) !Host.Result {
            var value = result;
            value.output_data = if (self.aliasesLastOutput(result.output_data))
                self.lastOutputData()
            else
                try self.setLastOutput(result.output_data);
            return value;
        }

        fn aliasesLastOutput(self: *const Executor, output_data: []const u8) bool {
            const last = self.last_call_output.slice();
            if (output_data.len != last.len) return false;
            if (output_data.len == 0) return true;
            return output_data.ptr == last.ptr;
        }

        // Tracked-state access. Thin passthroughs that only widen `Address` to `StateAddress`.

        pub fn traceAccountAccess(self: *Executor, account_address: Address) !void {
            try self.state.observeAccountAccess(stateAddress(account_address));
        }

        pub fn reserveAcceptedAccessHint(self: *Executor, hint: State.AccessHint) !void {
            try self.state.reserveAcceptedAccessHint(hint);
        }

        /// Mark an account warm in the current transaction scope.
        pub fn warmAccount(self: *Executor, address: Address) !void {
            self.requireTransactionScope();
            try self.state.warmAccount(stateAddress(address));
        }

        /// Mark a storage slot warm in the current transaction scope.
        pub fn warmStorage(self: *Executor, address: Address, key: u256) !void {
            self.requireTransactionScope();
            try self.state.warmStorage(stateAddress(address), key);
        }

        /// Return account metadata already present in tracked state.
        pub fn getAccount(self: *const Executor, address: Address) ?AccountState {
            return self.state.getAccount(stateAddress(address));
        }

        /// Return account metadata, loading it from the state reader if needed.
        pub fn getAccountOrLoad(self: *Executor, address: Address) !?AccountState {
            return self.state.getAccountOrLoad(stateAddress(address));
        }

        /// Read storage through tracked state and its canonical reader.
        pub fn getStorage(self: *Executor, address: Address, key: u256) !u256 {
            return self.state.getStorage(stateAddress(address), key);
        }

        /// Read an account balance through tracked state and its canonical reader.
        pub fn getBalance(self: *Executor, address: Address) !u256 {
            return self.state.getBalance(stateAddress(address));
        }

        /// Add balance as a direct family/STF state transition.
        pub fn addBalance(self: *Executor, address: Address, value: u256) !void {
            try self.state.addBalance(stateAddress(address), value);
        }

        pub fn subtractBalance(self: *Executor, address: Address, value: u256) !bool {
            return self.state.subtractBalance(stateAddress(address), value);
        }

        pub fn setNonce(self: *Executor, address: Address, nonce: u64) !void {
            try self.state.setNonce(stateAddress(address), nonce);
        }

        pub fn touchAccount(self: *Executor, address: Address) !void {
            try self.state.touchAccount(stateAddress(address));
        }

        /// Record one semantic account access without changing warmth or
        /// loading account metadata.
        pub fn observeAccountAccess(self: *Executor, address_value: Address) !void {
            self.requireTransactionScope();
            try self.state.observeAccountAccess(stateAddress(address_value));
        }

        /// Set account code as a direct family/STF state transition.
        pub fn setCode(self: *Executor, address: Address, code: []const u8) !void {
            try self.state.setCode(stateAddress(address), code);
        }

        pub fn clearCode(self: *Executor, address: Address) !void {
            try self.state.clearCode(stateAddress(address));
        }

        pub fn logView(self: *const Executor) State.LogView {
            return self.state.logView();
        }

        pub fn clearLogs(self: *Executor) void {
            self.state.clearLogs();
        }

        pub fn acceptedView(self: *const Executor) State.AcceptedView {
            return self.state.acceptedView();
        }

        /// Borrow the cumulative accepted changes relative to the state reader.
        pub fn acceptedChanges(self: *const Executor) State.ChangesView {
            std.debug.assert(!self.hasCurrentTransaction());
            return self.acceptedView().changes();
        }

        /// Drop the cumulative accepted branch and clear any open context.
        pub fn discardAccepted(self: *Executor) void {
            std.debug.assert(self.checkpoint_top == 0);
            std.debug.assert(!self.hasCurrentTransaction());
            self.state.discardAccepted();
            self.execution_context = null;
            self.scope_root = null;
        }

        /// Transfer value between accounts, returning false on insufficient balance.
        pub fn transferValue(self: *Executor, sender: Address, recipient: Address, value: u256) !bool {
            if (value == 0) return true;
            if (!try self.state.subtractBalance(stateAddress(sender), value)) return false;
            try self.state.addBalance(stateAddress(recipient), value);
            try self.emitTransferLog(.{
                .from = sender,
                .to = recipient,
                .amount = value,
            });
            return true;
        }

        pub fn emitTransferLog(self: *Executor, input: evmz.execution.ValueTransferInput) !void {
            const transfer_log = spec.valueTransferLog(input) orelse return;

            const topics = [_]u256{
                transfer_log.topic,
                input.from.toU256(),
                input.to.toU256(),
            };
            var data: [32]u8 = undefined;
            std.mem.writeInt(u256, &data, input.amount, .big);

            try self.state.emitLog(Host.Log{
                .address = transfer_log.address,
                .topics = &topics,
                .data = &data,
            });
        }

        /// Increment an account nonce, saturating at `maxInt(u64)`.
        fn incrementNonce(self: *Executor, address: Address) !void {
            const account = try self.getAccountOrLoad(address) orelse AccountState{};
            try self.state.setNonce(stateAddress(address), std.math.add(u64, account.nonce, 1) catch std.math.maxInt(u64));
        }

        /// Return this executor's `Host` adapter for interpreter frames.
        pub fn host(self: *Executor) Host {
            return callbacks.host(self);
        }

        // Code resolution: canonical bytes -> EIP-7702 delegation -> prepared-code cache.

        pub const ResolvedCode = struct {
            address: Address,
            delegated: bool,
            original_view: State.CodeView,
        };

        /// Resolve canonical code first, then consult the executor-owned derived
        /// cache. Address-based callers materialize through tracked state for witness
        /// validation and code-read tracing; CALL paths can reuse that traced view.
        pub fn resolveExecutionCode(self: *Executor, address: Address) !Bytecode.View {
            return self.resolveExecutionCodeView(try self.state.getCodeView(stateAddress(address)));
        }

        pub fn resolveExecutionCodeView(self: *Executor, code: State.CodeView) !Bytecode.View {
            std.debug.assert(self.prepared_code_execution != null);
            const execution = &self.prepared_code_execution.?;
            return execution.resolve(code.code_hash, code.bytes, .{
                .admit = true,
            });
        }

        fn resolveCode(self: *Executor, address: Address) !ResolvedCode {
            const original = try self.state.getCodeView(stateAddress(address));
            if (eip7702.delegationTarget(original.bytes)) |target| {
                return .{
                    .address = target,
                    .delegated = true,
                    .original_view = original,
                };
            }
            return .{
                .address = address,
                .delegated = false,
                .original_view = original,
            };
        }

        pub fn resolvedCodeView(self: *Executor, resolved: ResolvedCode) !State.CodeView {
            if (resolved.delegated) return self.state.getCodeView(stateAddress(resolved.address));
            return resolved.original_view;
        }

        /// Read account code through tracked state and its canonical reader.
        pub fn getCode(self: *Executor, address: Address) ![]const u8 {
            return self.state.getCode(stateAddress(address));
        }

        /// Test code presence from authenticated account metadata.
        pub fn accountHasCode(self: *Executor, address: Address) !bool {
            return self.state.accountHasCode(stateAddress(address));
        }

        /// Prepare code according to the executor preprocessing configuration.
        pub fn prepareBytecode(self: *const Executor, code: []const u8) !Bytecode {
            return Bytecode.init(self.allocator, code);
        }

        fn hasBalance(self: *Executor, address: Address, value: u256) !bool {
            const account = try self.state.getAccountOrLoad(stateAddress(address)) orelse return value == 0;
            return account.balance >= value;
        }

        inline fn nativeContractActive(address: Address) bool {
            return spec.precompile.active(address) or
                spec.reentrant_native_contract.active(address);
        }

        // Capture wrappers. The mapping itself lives in `executor/trace_capture.zig`;
        // these only supply the borrowed context and the executing frame depth.

        pub fn beginRootCapture(self: *Executor, message: evmz.Message, gas: ExecutionGas) !?evmz.trace.CallToken {
            return trace_capture.beginRoot(self.currentCaptureContext(), message, gas);
        }

        pub fn finishRootCapture(self: *Executor, token: evmz.trace.CallToken, result: ExecutionResult) !void {
            try trace_capture.finishRoot(self.currentCaptureContext().?, token, result);
        }

        pub fn finishRootHostCapture(self: *Executor, token: evmz.trace.CallToken, result: Host.Result) !void {
            try trace_capture.finishCall(self.currentCaptureContext(), token, result);
        }

        pub fn beginSelfDestructCapture(self: *Executor, address: Address, beneficiary: Address, balance: u256) !?evmz.trace.CallToken {
            return trace_capture.beginSelfDestruct(
                self.currentCaptureContext(),
                self.trace_depth,
                address,
                beneficiary,
                balance,
            );
        }

        pub fn finishSelfDestructCapture(self: *Executor, token: evmz.trace.CallToken) !void {
            try trace_capture.finishSelfDestruct(self.currentCaptureContext().?, token);
        }

        // Frame execution: one root message driven as a LIFO frame stack, plus the
        // interior CALL/CREATE begin/finish halves that `CallRuntime` dispatches to.

        const StartedCall = union(enum) {
            immediate: Host.Result,
            child: ChildCall,
        };

        const ChildCall = struct {
            checkpoint_state: State.Checkpoint,
            bytecode: Bytecode.View,
        };

        const StartedCreate = union(enum) {
            immediate: Host.Result,
            child: ChildCreate,
        };

        const CreateCallerPreparation = union(enum) {
            rejected: Host.Result,
            nonce: u64,
        };

        const ChildCreate = struct {
            checkpoint_state: State.Checkpoint,
            /// Consumed synchronously while the originating CREATE action or
            /// root message remains alive. Address, kind, and init code are
            /// projections of this message and must not be duplicated here.
            source_msg: *const Host.Message,
        };

        /// Iteratively drives a LIFO frame stack for one root message.
        ///
        /// `run` is the uninterrupted lane every production entry point uses.
        pub const CallRuntime = struct {
            executor: *Executor,
            host_iface: Host,
            frames: *FrameStore,
            frame_base: usize,
            capture_context: ?*CaptureContext,
            top_frame_resolved: bool,

            pub fn init(executor: *Executor) CallRuntime {
                return .{
                    .executor = executor,
                    .host_iface = executor.host(),
                    .frames = &executor.frame_store,
                    .frame_base = executor.frame_store.len(),
                    .capture_context = executor.currentCaptureContext(),
                    .top_frame_resolved = false,
                };
            }

            /// Restore every unresolved child checkpoint owned by this runtime.
            pub fn deinit(self: *CallRuntime) void {
                if (self.top_frame_resolved) self.popResolvedFrame();
                while (self.frames.len() > self.frame_base) {
                    const index = self.frames.len() - 1;
                    switch (self.frames.control(index).kind) {
                        .root_call => {},
                        .call => |checkpoint_state| self.executor.state.revertToCheckpoint(checkpoint_state),
                        .create => |child| self.executor.state.revertToCheckpoint(child.checkpoint_state),
                    }
                    self.dropFrame();
                }
            }

            pub fn prepare(self: *CallRuntime) !void {
                std.debug.assert(self.frame_base == 0);
                try self.prepareNested();
            }

            fn prepareNested(self: *CallRuntime) !void {
                std.debug.assert(self.frames.len() == self.frame_base);
                if (self.frame_base == 0) {
                    if (self.capture_context) |context| {
                        if (context.capturesSteps()) {
                            try context.reserveFrameCapacity(default_max_live_frames);
                        }
                    }
                }
            }

            pub fn pushRootCall(self: *CallRuntime, msg: *const Host.Message, bytecode: Bytecode.View) !void {
                try self.pushFrame(msg, bytecode, .{ .kind = .root_call });
            }

            fn pushChildCall(
                self: *CallRuntime,
                msg: *const Host.Message,
                bytecode: Bytecode.View,
                checkpoint_state: State.Checkpoint,
                call_capture: ?evmz.trace.CallToken,
            ) !void {
                try self.pushFrame(msg, bytecode, .{
                    .kind = .{ .call = checkpoint_state },
                    .call_capture = call_capture,
                });
            }

            fn pushChildCreate(self: *CallRuntime, child: ChildCreate, call_capture: ?evmz.trace.CallToken) !void {
                std.debug.assert(self.executor.prepared_code_execution != null);
                const execution = &self.executor.prepared_code_execution.?;
                const source_msg = child.source_msg;
                const address = source_msg.recipient;
                const msg: Host.Message = .{
                    .depth = source_msg.depth,
                    .kind = .call,
                    .gas = source_msg.gas,
                    .gas_reservoir = source_msg.gas_reservoir,
                    .recipient = address,
                    .sender = source_msg.sender,
                    .input_data = &.{},
                    .value = source_msg.value,
                    .is_static = source_msg.is_static,
                    .code_address = address,
                };
                const bytecode = try execution.prepareTransient(source_msg.input_data);
                try self.pushFrame(
                    &msg,
                    bytecode,
                    .{
                        .kind = .{ .create = .{
                            .checkpoint_state = child.checkpoint_state,
                            .address = address,
                            .kind = source_msg.kind,
                        } },
                        .call_capture = call_capture,
                    },
                );
            }

            fn pushFrame(
                self: *CallRuntime,
                msg: *const Host.Message,
                bytecode: Bytecode.View,
                control_value: FrameStore.Control,
            ) !void {
                const index = try self.frames.push(
                    self.executor.allocator,
                    .{
                        .host = &self.host_iface,
                        .msg = msg,
                        .execution_context = &self.executor.execution_context.?,
                        .bytecode = bytecode,
                    },
                    control_value,
                );
                errdefer self.frames.pop();

                if (self.catpreContext(.step)) |context| {
                    const call_frame = self.frames.frame(index);
                    const parent_stack = if (index > 0)
                        self.frames.frame(index - 1).stack.asSlice()
                    else
                        &.{};
                    const parent_memory_size = if (index > 0)
                        self.frames.frame(index - 1).memory.len()
                    else
                        0;
                    try context.pushFrame(
                        call_frame.msg.depth,
                        trace_capture.frameKind(self.frames, index),
                        call_frame.stack.asSlice(),
                        call_frame.memory.len(),
                        call_frame.return_data,
                        parent_stack,
                        parent_memory_size,
                    );
                }
            }

            fn dropFrame(self: *CallRuntime) void {
                std.debug.assert(self.frames.len() > self.frame_base);
                if (self.catpreContext(.step)) |context| context.popFrame();
                self.frames.pop();
            }

            /// Drop the top frame after `finishFrame` resolved its checkpoint.
            pub fn popResolvedFrame(self: *CallRuntime) void {
                std.debug.assert(self.top_frame_resolved);
                self.top_frame_resolved = false;
                self.dropFrame();
            }

            inline fn catpreContext(self: *CallRuntime, scope: enum { call, step }) ?*CaptureContext {
                const context = self.capture_context orelse return null;
                return switch (scope) {
                    .call => if (context.capturesCalls()) context else null,
                    .step => if (context.capturesSteps()) context else null,
                };
            }

            fn run(self: *CallRuntime) !Host.Result {
                while (self.frames.len() > self.frame_base) {
                    const index = self.frames.len() - 1;
                    const call_frame = self.frames.frame(index);
                    var interpreter = BoundInterpreter.init(call_frame);
                    const depth = call_frame.msg.depth;
                    const previous_depth = self.executor.trace_depth;
                    self.executor.trace_depth = depth;
                    const run_result: Interpreter.RunResult = result: {
                        defer self.executor.trace_depth = previous_depth;
                        if (comptime options_value.step_capture) {
                            if (self.catpreContext(.step)) |context| {
                                break :result try interpreter.executeCapturedUntilSuspended(context.currentFrame());
                            }
                        }
                        break :result try interpreter.executeUntilSuspended();
                    };
                    switch (run_result) {
                        .suspended => |action| try self.dispatchSuspension(index, action),
                        .finished => |result| {
                            const host_result = try self.finishFrame(index, result);
                            if (self.frames.len() == self.frame_base + 1) {
                                const stable = try self.executor.stabilizeFinalResult(host_result);
                                self.popResolvedFrame();
                                return stable;
                            }

                            const parent_index = self.frames.len() - 2;
                            try self.resumeSuspended(parent_index, host_result);
                            self.popResolvedFrame();
                        },
                    }
                }
                unreachable;
            }

            pub fn dispatchSuspension(self: *CallRuntime, frame_index: usize, action: *const Interpreter.Action) !void {
                // Executor reserves pointer-bearing frame storage before the
                // root frame is acquired, so child pushes cannot move action.
                std.debug.assert(self.frames.metadataPointersStable());
                std.debug.assert(action == self.frames.frame(frame_index).suspendedAction().?);
                switch (action.*) {
                    .call => |*call_action| {
                        const continuation = call_action.continuation;
                        if (try self.startCall(&call_action.msg)) |host_result| {
                            try self.frames.frame(frame_index).resumeWith(host_result);
                            self.captureCallOutput(frame_index, continuation, host_result.output_data.len);
                            try self.captureReturnData(frame_index);
                        }
                    },
                    .create => |*create_action| {
                        if (try self.startCreate(&create_action.msg)) |host_result| {
                            try self.frames.frame(frame_index).resumeWith(host_result);
                            try self.captureReturnData(frame_index);
                        }
                    },
                }
            }

            pub fn resumeSuspended(self: *CallRuntime, frame_index: usize, result: Host.Result) !void {
                const frame = self.frames.frame(frame_index);
                const action = frame.suspendedAction() orelse return error.FrameNotSuspended;
                const call_continuation: ?Interpreter.Action.CallResume = switch (action.*) {
                    .call => |call_action| call_action.continuation,
                    .create => null,
                };
                try frame.resumeWith(result);
                if (call_continuation) |continuation| {
                    self.captureCallOutput(frame_index, continuation, result.output_data.len);
                }
                try self.captureReturnData(frame_index);
            }

            fn captureReturnData(self: *CallRuntime, frame_index: usize) !void {
                const context = self.catpreContext(.step) orelse return;
                try context.replaceFrameReturnData(
                    frame_index,
                    self.frames.frame(frame_index).return_data,
                );
            }

            fn captureCallOutput(
                self: *CallRuntime,
                frame_index: usize,
                continuation: Interpreter.Action.CallResume,
                output_len: usize,
            ) void {
                const context = self.catpreContext(.step) orelse return;
                context.setFrameMemoryWrite(
                    frame_index,
                    continuation.out_offset,
                    @min(continuation.out_size, output_len),
                );
            }

            fn startCall(self: *CallRuntime, msg: *const Host.Message) !?Host.Result {
                const previous_depth = self.executor.trace_depth;
                self.executor.trace_depth = msg.depth;
                defer self.executor.trace_depth = previous_depth;

                const call_capture = try trace_capture.beginCall(self.capture_context, msg);
                if (Host.precheckResult(msg.*)) |result| {
                    if (call_capture) |token| try trace_capture.finishCall(self.capture_context, token, result);
                    return result;
                }
                switch (try self.executor.beginCall(msg)) {
                    .immediate => |result| {
                        if (call_capture) |token| try trace_capture.finishCall(self.capture_context, token, result);
                        return result;
                    },
                    .child => |child| {
                        var child_checkpoint = CheckpointGuard.init(&self.executor.state, child.checkpoint_state);
                        defer child_checkpoint.deinit();

                        try self.pushChildCall(msg, child.bytecode, child.checkpoint_state, call_capture);
                        child_checkpoint.disarm();
                        return null;
                    },
                }
            }

            fn startCreate(self: *CallRuntime, msg: *const Host.Message) !?Host.Result {
                const previous_depth = self.executor.trace_depth;
                self.executor.trace_depth = msg.depth;
                defer self.executor.trace_depth = previous_depth;

                const call_capture = try trace_capture.beginCall(self.capture_context, msg);
                if (Host.precheckResult(msg.*)) |result| {
                    if (call_capture) |token| try trace_capture.finishCall(self.capture_context, token, result);
                    return result;
                }
                if (msg.depth > Host.max_call_depth) {
                    const result = self.executor.createFailureWithCause(msg.gas, msg.gas_reservoir, .invalid, .call_depth_exceeded);
                    if (call_capture) |token| try trace_capture.finishCall(self.capture_context, token, result);
                    return result;
                }

                switch (try self.executor.beginCreate(msg)) {
                    .immediate => |result| {
                        if (call_capture) |token| try trace_capture.finishCall(self.capture_context, token, result);
                        return result;
                    },
                    .child => |child| {
                        var child_checkpoint = CheckpointGuard.init(&self.executor.state, child.checkpoint_state);
                        defer child_checkpoint.deinit();

                        try self.pushChildCreate(child, call_capture);
                        child_checkpoint.disarm();
                        return null;
                    },
                }
            }

            pub fn finishFrame(self: *CallRuntime, frame_index: usize, result: FrameResult) !Host.Result {
                std.debug.assert(!self.top_frame_resolved);
                std.debug.assert(frame_index == self.frames.len() - 1);
                const control = self.frames.control(frame_index).*;
                const frame_kind = control.kind;
                const call_capture = control.call_capture;
                var frame_checkpoint: ?CheckpointGuard = switch (frame_kind) {
                    .root_call => null,
                    .call => |checkpoint_state| CheckpointGuard.init(&self.executor.state, checkpoint_state),
                    .create => |child| CheckpointGuard.init(&self.executor.state, child.checkpoint_state),
                };
                defer if (frame_checkpoint) |*guard| guard.deinit();

                const call_frame = self.frames.frame(frame_index);
                if (self.catpreContext(.step)) |context| {
                    try context.finishCurrentFrame(.{
                        .outcome = Interpreter.traceFrameOutcome(result.status()),
                        .memory_size = call_frame.memory.len(),
                    });
                }

                if (call_capture != null) {
                    try self.catpreContext(.call).?.reserveCallOutput(result.output_data.len);
                }

                const host_result = switch (frame_kind) {
                    .root_call => Host.Result.fromExecution(result.executionResult(), false),
                    .call => blk: {
                        if (frame_checkpoint) |*guard| {
                            guard.finish(result.status());
                        } else unreachable;
                        break :blk Host.Result.fromExecution(
                            result.executionResult(),
                            result.status() != .success,
                        );
                    },
                    .create => |child| blk: {
                        if (frame_checkpoint) |*guard| {
                            break :blk try self.executor.finishCreate(child, result, guard);
                        }
                        unreachable;
                    },
                };
                if (call_capture) |token| {
                    trace_capture.finishCallReserved(self.catpreContext(.call).?, token, host_result);
                }
                self.top_frame_resolved = true;
                return host_result;
            }
        };

        fn beginCall(self: *Executor, msg: *const Host.Message) !StartedCall {
            if (msg.depth > Host.max_call_depth) {
                return .{ .immediate = .{
                    .outcome = .{ .status = .invalid, .cause = .call_depth_exceeded },
                    .output_data = &.{},
                    .gas_left = msg.gas,
                    .gas_refund = 0,
                    .gas_reservoir = msg.gas_reservoir,
                } };
            }

            const resolved = try self.resolveCode(msg.code_address);
            if (resolved.delegated) try self.traceAccountAccess(resolved.address);
            const code = try self.resolvedCodeView(resolved);

            var call_checkpoint = CheckpointGuard.begin(&self.state);
            defer call_checkpoint.deinit();

            if (msg.value > 0 and (msg.kind == .call or msg.kind == .callcode)) {
                const value_ok = if (msg.kind == .call)
                    try self.transferValue(msg.sender, msg.recipient, msg.value)
                else
                    try self.hasBalance(msg.recipient, msg.value);
                if (!value_ok) {
                    call_checkpoint.restore();
                    return .{ .immediate = .{
                        .outcome = .{ .status = .invalid, .cause = .insufficient_balance },
                        .output_data = &.{},
                        .gas_left = msg.gas,
                        .gas_refund = 0,
                        .gas_reservoir = msg.gas_reservoir,
                    } };
                }
            }

            if (!resolved.delegated and nativeContractActive(msg.code_address)) {
                if (try self.runNativeCall(msg)) |result_value| {
                    var result = result_value;
                    if (result.status() == .success) {
                        try self.touchEmptyCallRecipient(msg);
                    }
                    call_checkpoint.finish(result.status());
                    result.checkpoint_reverted = result.status() != .success;
                    return .{ .immediate = result };
                }
            }

            if (code.bytes.len == 0) {
                try self.touchEmptyCallRecipient(msg);
                call_checkpoint.commit();
                return .{ .immediate = .{
                    .outcome = .{ .status = .success, .cause = .none },
                    .output_data = &.{},
                    .gas_left = msg.gas,
                    .gas_refund = 0,
                    .gas_reservoir = msg.gas_reservoir,
                } };
            }

            const bytecode = try self.resolveExecutionCodeView(code);
            call_checkpoint.disarm();
            return .{ .child = .{
                .checkpoint_state = call_checkpoint.checkpoint_state,
                .bytecode = bytecode,
            } };
        }

        fn runNativeCall(
            self: *Executor,
            msg: *const Host.Message,
        ) !?Host.Result {
            self.clearLastOutput();
            var scratch = try self.callScratch(msg.depth);
            defer scratch.deinit();

            const precompile = spec.precompile.resolve(msg.code_address);
            const reentrant = spec.reentrant_native_contract.active(msg.code_address);
            std.debug.assert(precompile == null or !reentrant);
            const result = if (precompile) |entry|
                spec.precompile.execute(entry, .{
                    .allocator = scratch.allocator,
                    .input_data = msg.input_data,
                    .gas = msg.gas,
                }) catch |err| switch (err) {
                    error.NotImplemented => return .{
                        .outcome = .{ .status = .invalid, .cause = .invalid },
                        .output_data = &.{},
                        .gas_left = 0,
                        .gas_refund = 0,
                        .gas_reservoir = msg.gas_reservoir,
                    },
                    else => return err,
                }
            else if (reentrant) blk: {
                const runtime = self.reentrant_native_contract_runtime orelse
                    return error.MissingReentrantNativeContractRuntime;
                var host_iface = self.host();
                break :blk try runtime.execute(.{
                    .allocator = scratch.allocator,
                    .host = &host_iface,
                    .message = msg,
                });
            } else return null;

            defer if (result.output_owned) scratch.allocator.free(result.output_data);
            const output = if (result.output_owned) output: {
                break :output try self.setLastOutput(result.output_data);
            } else if (result.output_data.len == 0) output: {
                break :output &.{};
            } else {
                return error.InvalidNativeContractOutput;
            };
            const status: evmz.TxStatus = switch (result.status) {
                .success => .success,
                .failure => .invalid,
                .out_of_gas => .out_of_gas,
            };
            return .{
                .outcome = .{
                    .status = status,
                    .cause = switch (status) {
                        .success => .none,
                        .out_of_gas => .out_of_gas,
                        .invalid => .invalid,
                        .revert => unreachable,
                    },
                },
                .output_data = output,
                .gas_left = if (status == .success) result.gas_left else 0,
                .gas_refund = 0,
                .gas_reservoir = msg.gas_reservoir,
            };
        }

        fn touchEmptyCallRecipient(self: *Executor, msg: *const Host.Message) !void {
            if (msg.kind != .call or !spec.call.touches_empty_recipient) return;
            try self.state.touchAccount(stateAddress(msg.recipient));
        }

        fn executeCreateMessage(self: *Executor, msg: Host.Message) !Host.Result {
            return self.executeCreateMessageWith(msg, beginCreate);
        }

        fn executeTransactionCreateMessage(self: *Executor, msg: Host.Message) !Host.Result {
            return self.executeCreateMessageWith(msg, beginTransactionCreate);
        }

        fn executeCreateMessageWith(
            self: *Executor,
            msg: Host.Message,
            comptime begin: *const fn (*Executor, *const Host.Message) anyerror!StartedCreate,
        ) !Host.Result {
            const previous_depth = self.trace_depth;
            self.trace_depth = msg.depth;
            defer self.trace_depth = previous_depth;

            if (msg.depth > Host.max_call_depth)
                return self.createFailureWithCause(msg.gas, msg.gas_reservoir, .invalid, .call_depth_exceeded);

            return switch (try begin(self, &msg)) {
                .immediate => |result| result,
                .child => |child| blk: {
                    var child_checkpoint = CheckpointGuard.init(&self.state, child.checkpoint_state);
                    defer child_checkpoint.deinit();

                    var runtime = CallRuntime.init(self);
                    defer runtime.deinit();
                    try runtime.prepareNested();
                    try runtime.pushChildCreate(child, null);
                    child_checkpoint.disarm();
                    const result = try runtime.run();
                    break :blk result;
                },
            };
        }

        fn beginCreate(self: *Executor, msg: *const Host.Message) !StartedCreate {
            const caller_nonce = switch (try self.prepareCreateCaller(msg)) {
                .rejected => |result| return .{ .immediate = result },
                .nonce => |nonce| nonce,
            };
            const next_nonce = std.math.add(u64, caller_nonce, 1) catch
                return .{ .immediate = self.createFailureWithCause(msg.gas, msg.gas_reservoir, .invalid, .nonce_overflow) };
            try self.warmCreatedAddressIfNeeded(msg.recipient);
            try self.state.setNonce(stateAddress(msg.sender), next_nonce);
            return self.beginPreparedCreate(msg);
        }

        fn beginTransactionCreate(self: *Executor, msg: *const Host.Message) !StartedCreate {
            switch (try self.prepareCreateCaller(msg)) {
                .rejected => |result| return .{ .immediate = result },
                .nonce => {},
            }
            try self.warmCreatedAddressIfNeeded(msg.recipient);
            return self.beginPreparedCreate(msg);
        }

        fn prepareCreateCaller(self: *Executor, msg: *const Host.Message) !CreateCallerPreparation {
            const caller = try self.getAccountOrLoad(msg.sender) orelse evmz.state.Account{};
            if (caller.balance < msg.value) {
                return .{ .rejected = self.createFailureWithCause(msg.gas, msg.gas_reservoir, .invalid, .insufficient_balance) };
            }
            return .{ .nonce = caller.nonce };
        }

        fn warmCreatedAddressIfNeeded(self: *Executor, create_address: Address) !void {
            if (spec.create.warms_created_address) {
                try self.warmAccount(create_address);
            }
        }

        fn beginPreparedCreate(self: *Executor, msg: *const Host.Message) !StartedCreate {
            const create_address = msg.recipient;
            var create_checkpoint = CheckpointGuard.begin(&self.state);
            defer create_checkpoint.deinit();

            if (try self.createCollision(create_address)) {
                create_checkpoint.commit();
                return .{ .immediate = self.createFailureWithCause(
                    0,
                    msg.gas_reservoir,
                    .invalid,
                    .contract_address_collision,
                ) };
            }

            _ = try self.state.subtractBalance(stateAddress(msg.sender), msg.value);
            try self.state.addBalance(stateAddress(create_address), msg.value);
            try self.emitTransferLog(.{
                .from = msg.sender,
                .to = create_address,
                .amount = msg.value,
            });
            try self.state.setNonce(stateAddress(create_address), spec.create.initial_nonce);
            try self.state.clearCode(stateAddress(create_address));
            try self.state.markCreatedContract(stateAddress(create_address));

            create_checkpoint.disarm();
            return .{ .child = .{
                .checkpoint_state = create_checkpoint.checkpoint_state,
                .source_msg = msg,
            } };
        }

        fn finishCreate(
            self: *Executor,
            child: FrameStore.CreateControl,
            frame_result: FrameResult,
            create_checkpoint: *CheckpointGuard,
        ) !Host.Result {
            const result = frame_result.executionResult();
            const output = result.output_data;
            if (result.outcome.status != .success) {
                create_checkpoint.restore();
                return Host.Result.fromExecution(result, true);
            }

            if (spec.create.code_size_limit) |limit| {
                if (output.len > limit) {
                    create_checkpoint.restore();
                    return self.createFailureFromResult(result, .out_of_gas, .max_code_size_exceeded);
                }
            }
            if (spec.create.rejectsCode(output)) {
                create_checkpoint.restore();
                return self.createFailureFromResult(result, .invalid, .invalid_code);
            }

            const runtime_size = std.math.cast(i64, output.len) orelse {
                create_checkpoint.restore();
                return self.createFailureFromResult(result, .out_of_gas, .code_store_out_of_gas);
            };
            const deposit_regular_cost = spec.create.depositRegularGas(runtime_size) orelse {
                create_checkpoint.restore();
                return self.createFailureFromResult(result, .out_of_gas, .code_store_out_of_gas);
            };
            if (result.gas_left < deposit_regular_cost) {
                if (spec.create.deposit_regular_gas_oog_commits) {
                    create_checkpoint.commit();
                    var failed_deposit = result;
                    failed_deposit.outcome = .{ .status = .success, .cause = .code_store_out_of_gas };
                    return Host.Result.fromExecution(failed_deposit, false);
                }
                create_checkpoint.restore();
                return self.createFailureFromResult(result, .out_of_gas, .code_store_out_of_gas);
            }

            var deposit_result = result;
            deposit_result.gas_left -= deposit_regular_cost;
            const deposit_state_gas = spec.create.depositStateGas(runtime_size) orelse {
                create_checkpoint.restore();
                return self.createFailureFromResult(deposit_result, .out_of_gas, .code_store_out_of_gas);
            };
            deposit_result.trackStateGas(deposit_state_gas);
            if (deposit_result.outcome.status != .success) {
                create_checkpoint.restore();
                return self.createFailureFromResult(deposit_result, deposit_result.outcome.status, .code_store_out_of_gas);
            }

            try self.state.setCode(stateAddress(child.address), output);
            create_checkpoint.commit();

            return Host.Result.fromExecution(deposit_result, false);
        }

        fn createFailureWithCause(
            self: *Executor,
            gas_left: i64,
            gas_reservoir: i64,
            status: evmz.execution.Status,
            cause: evmz.execution.TerminalCause,
        ) Host.Result {
            self.clearLastOutput();
            return .{
                .outcome = .{ .status = status, .cause = cause },
                .output_data = &.{},
                .gas_left = gas_left,
                .gas_refund = 0,
                .gas_reservoir = gas_reservoir,
            };
        }

        fn createFailureFromResult(
            self: *Executor,
            result: ExecutionResult,
            status: evmz.execution.Status,
            cause: evmz.execution.TerminalCause,
        ) Host.Result {
            var failed = result;
            failed.outcome = .{ .status = status, .cause = cause };
            failed.gas_left = 0;
            failed.gas_refund = 0;
            evmz.execution.finalizeStateGas(&failed);
            self.clearLastOutput();
            failed.output_data = &.{};
            return Host.Result.fromExecution(failed, true);
        }

        fn createCollision(self: *Executor, address: Address) !bool {
            if (nativeContractActive(address)) return true;
            if (try self.state.getAccountOrLoad(stateAddress(address))) |account| {
                if (account.nonce != 0) return true;
            }
            // EIP-7610 clarifies this rule retroactively for every Ethereum
            // revision: storage-only destinations also collide. Absence cannot
            // short-circuit that. EIP-161 deadness ignores storage, so a
            // storage-bearing account reads as absent, yet the state trie keeps
            // its leaf and creating over it would strand the storage.
            return (try self.state.accountHasCode(stateAddress(address))) or
                (try self.state.accountHasStorage(stateAddress(address)));
        }

        /// Host.call resolver for direct `Interpreter.execute()` users. Top-level call
        /// and create transactions enter `CallRuntime` through their executor entrypoints.
        pub fn resolveHostCall(self: *Executor, msg: Host.Message) !Host.Result {
            // Write protection is enforced through `is_static` alone; a
            // static call kind that fails to inherit it is a constructor bug.
            std.debug.assert(msg.kind != .staticcall or msg.is_static);
            self.beginPreparedCodeExecution();
            defer self.endPreparedCodeExecution();

            const previous_depth = self.trace_depth;
            self.trace_depth = msg.depth;
            defer self.trace_depth = previous_depth;

            const capture_value = self.currentCaptureContext();
            const call_capture = try trace_capture.beginCall(capture_value, &msg);
            const result = Host.precheckResult(msg) orelse if (msg.kind == .create or msg.kind == .create2) result: {
                // Direct Host callers may still submit an over-depth message.
                // Opcode-generated terminal attempts were resolved above.
                if (msg.depth > Host.max_call_depth) {
                    break :result self.createFailureWithCause(msg.gas, msg.gas_reservoir, .invalid, .call_depth_exceeded);
                }
                break :result try self.executeCreateMessage(msg);
            } else switch (try self.beginCall(&msg)) {
                .immediate => |immediate| immediate,
                .child => |child| blk: {
                    var child_checkpoint = CheckpointGuard.init(&self.state, child.checkpoint_state);
                    defer child_checkpoint.deinit();

                    var runtime = CallRuntime.init(self);
                    defer runtime.deinit();
                    try runtime.prepareNested();
                    try runtime.pushChildCall(&msg, child.bytecode, child.checkpoint_state, null);
                    child_checkpoint.disarm();
                    const result = try runtime.run();
                    break :blk result;
                },
            };
            if (call_capture) |token| try trace_capture.finishCall(capture_value, token, result);
            return result;
        }

        // Top-frame state gas. Charged before dispatch, reconciled into the result after.

        fn topLevelDelegatedAccountAccess(self: *Executor, target: Address) !?evmz.execution.DelegatedAccountAccess {
            const state_target = stateAddress(target);
            const already_warm = self.state.isAccountWarm(state_target);
            const access = spec.call.topLevelDelegatedAccountAccess(.{
                .target_is_native_contract = nativeContractActive(target),
                .already_warm = already_warm,
            }) orelse return null;
            if (access.status == .cold and !already_warm) {
                try self.state.warmAccount(state_target);
            }
            return access;
        }

        fn chargeTopFrameValueTransferStateGas(
            self: *Executor,
            sender: Address,
            recipient: Address,
            value: u256,
            gas: *ExecutionGas,
        ) !top_frame_gas.Charge {
            const same_address = Address.eql(sender, recipient);
            const creates_account = if (value == 0 or same_address)
                false
            else
                !try self.state.accountExists(stateAddress(recipient));
            const charge_i64 = spec.call.topFrameValueTransferStateGas(.{
                .value = value,
                .same_address = same_address,
                .creates_account = creates_account,
            });
            return top_frame_gas.charge(gas, charge_i64);
        }

        fn chargeTopFrameCreateStateGas(
            self: *Executor,
            options: Create,
            gas: *ExecutionGas,
        ) !top_frame_gas.Charge {
            // The integrated rule compares the pre-transaction account to the
            // empty account value. Storage does not make an account alive.
            const target_alive = if (try self.state.getAccountOrLoad(stateAddress(options.recipient))) |account|
                account.nonce != 0 or
                    account.balance != 0 or
                    !std.mem.eql(u8, &account.code_hash, &evmz.crypto.keccak256_empty)
            else
                false;

            return top_frame_gas.charge(
                gas,
                spec.create.accountStateGas(.{ .target_alive = target_alive }),
            );
        }

        // Entrypoints. The whole public execution surface, ordered outermost first.

        /// Execute a raw call/create message inside an already-open tx scope.
        ///
        /// This does not open or close a transaction scope. Use `executeStandalone` for the
        /// fully-managed raw-message lifecycle.
        pub fn executeMessage(self: *Executor, message: Message, gas: ExecutionGas) !Result {
            self.validateScopeRoot(.fromMessage(message));
            const call_capture = try self.beginRootCapture(message, gas);
            const result = try switch (message) {
                .call => |call| self.executeCall(call, gas),
                .create => |create| self.executeCreate(create, gas),
            };
            if (call_capture) |token| try self.finishRootHostCapture(token, result);
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
            self: *Executor,
            request: ExecutionRequest,
            scope_init: ExecutionScopeInit,
        ) !Result {
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
            self: *Executor,
            context: ExecutionContext,
            message: Message,
            gas: ExecutionGas,
            scope_init: ExecutionScopeInit,
            mode: InstrumentationMode,
            observer: anytype,
        ) !Result {
            try self.beginMessageScopeContext(context, message, scope_init, mode);
            errdefer self.discardStateTransition();

            var pre_execution = self.checkpoint();
            defer pre_execution.deinit();

            const result = try self.executeMessage(message, gas);
            if (!result.isSuccess()) {
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
        pub fn executeTransactionRequest(self: *Executor, request: ExecutionRequest) !ExecutionResult {
            return (try self.executeTransactionRequestPhased(request)).result;
        }

        /// Execute one root request and report whether dispatch preparation
        /// completed. The result remains an EVM result; the stage is only the
        /// stage fact needed by a family transaction coordinator to choose
        /// its outer rollback boundary.
        pub fn executeTransactionRequestPhased(
            self: *Executor,
            request: ExecutionRequest,
        ) !TransactionExecutionOutcome {
            self.validateScopeContext(request.context);
            self.validateScopeRoot(.fromMessage(request.message));
            return self.executeTransactionRequestTrustedPhased(request);
        }

        fn executeTransactionRequestTrustedPhased(
            self: *Executor,
            request: ExecutionRequest,
        ) !TransactionExecutionOutcome {
            switch (request.message) {
                .call => |call| try self.traceAccountAccess(call.recipient),
                .create => |create| try self.traceAccountAccess(create.recipient),
            }
            const call_capture = try self.beginRootCapture(request.message, request.gas);
            const outcome = try switch (request.message) {
                .call => |call| self.executeCallTransactionPhased(
                    call.sender,
                    call.recipient,
                    call.input,
                    request.gas,
                    call.value,
                ),
                .create => |create| self.executeCreateTransactionPhased(create, request.gas),
            };
            if (call_capture) |token| try self.finishRootCapture(token, outcome.result);
            return outcome;
        }

        pub fn executeCall(self: *Executor, options: Call, gas: ExecutionGas) !Result {
            const result = try executeCallTransaction(
                self,
                options.sender,
                options.recipient,
                options.input,
                gas,
                options.value,
            );
            return Host.Result.fromExecution(result, false);
        }

        pub fn executeCallTransaction(
            self: *Executor,
            sender: Address,
            recipient: Address,
            input: []const u8,
            gas: ExecutionGas,
            value: u256,
        ) !ExecutionResult {
            return (try executeCallTransactionPhased(
                self,
                sender,
                recipient,
                input,
                gas,
                value,
            )).result;
        }

        pub fn executeCallTransactionPhased(
            self: *Executor,
            sender: Address,
            recipient: Address,
            input: []const u8,
            gas: ExecutionGas,
            value: u256,
        ) !TransactionExecutionOutcome {
            self.beginPreparedCodeExecution();
            defer self.endPreparedCodeExecution();

            _ = self.currentExecutionContext();
            var execution_gas = gas;
            const top_frame_state_gas = try self.chargeTopFrameValueTransferStateGas(sender, recipient, value, &execution_gas);
            if (top_frame_state_gas.out_of_gas) {
                return .{
                    .stage = .preparation,
                    .result = .{
                        .outcome = .{ .status = .out_of_gas, .cause = .out_of_gas },
                        .gas_left = 0,
                        .gas_refund = 0,
                        .gas_reservoir = std.math.cast(i64, execution_gas.reservoir) orelse std.math.maxInt(i64),
                        .output_data = &.{},
                    },
                };
            }

            const resolved = try self.resolveCode(recipient);
            if (!resolved.delegated and nativeContractActive(recipient)) {
                var result = try self.runNativeCallTransaction(sender, recipient, input, execution_gas, value);
                top_frame_gas.finish(&result, top_frame_state_gas);
                return .{ .stage = .payload, .result = result };
            }
            if (resolved.delegated) {
                const access = try self.topLevelDelegatedAccountAccess(resolved.address);
                const access_cost = if (access) |entry|
                    std.math.cast(u64, entry.gas) orelse std.math.maxInt(u64)
                else
                    0;
                if (execution_gas.regular_left < access_cost) {
                    var result = ExecutionResult{
                        .outcome = .{ .status = .out_of_gas, .cause = .out_of_gas },
                        .gas_left = 0,
                        .gas_refund = 0,
                        .gas_reservoir = std.math.cast(i64, execution_gas.reservoir) orelse std.math.maxInt(i64),
                        .output_data = &.{},
                    };
                    top_frame_gas.finish(&result, top_frame_state_gas);
                    return .{ .stage = .preparation, .result = result };
                }
                execution_gas.regular_left -= access_cost;
                try self.traceAccountAccess(resolved.address);
            }

            const bytecode = try self.resolveExecutionCodeView(try self.resolvedCodeView(resolved));
            var result = try self.executePreparedCallTransaction(.{
                .bytecode = bytecode,
                .sender = sender,
                .recipient = recipient,
                .input = input,
                .gas = execution_gas.regular_left,
                .gas_reservoir = execution_gas.reservoir,
                .value = value,
            });
            top_frame_gas.finish(&result, top_frame_state_gas);
            return .{ .stage = .payload, .result = result };
        }

        fn runNativeCallTransaction(
            self: *Executor,
            sender: Address,
            recipient: Address,
            input: []const u8,
            gas: ExecutionGas,
            value: u256,
        ) !ExecutionResult {
            self.clearLastOutput();
            _ = self.currentExecutionContext();
            if (!try self.transferValue(sender, recipient, value)) {
                return .{
                    .outcome = .{ .status = .invalid, .cause = .insufficient_balance },
                    .gas_left = std.math.cast(i64, gas.regular_left) orelse std.math.maxInt(i64),
                    .gas_refund = 0,
                    .gas_reservoir = std.math.cast(i64, gas.reservoir) orelse std.math.maxInt(i64),
                    .output_data = &.{},
                };
            }

            const message = Host.Message{
                .depth = 0,
                .kind = .call,
                .gas = std.math.cast(i64, gas.regular_left) orelse std.math.maxInt(i64),
                .gas_reservoir = std.math.cast(i64, gas.reservoir) orelse std.math.maxInt(i64),
                .recipient = recipient,
                .sender = sender,
                .input_data = input,
                .value = value,
                .code_address = recipient,
            };
            const call_result = (try self.runNativeCall(&message)) orelse unreachable;
            if (call_result.status() == .success) try self.touchEmptyCallRecipient(&message);
            return call_result.executionResult(self.lastOutputData());
        }

        pub fn executePreparedCallTransaction(self: *Executor, options: PreparedCallTransaction) !ExecutionResult {
            self.beginPreparedCodeExecution();
            defer self.endPreparedCodeExecution();

            self.clearLastOutput();
            _ = currentExecutionContext(self);
            if (!try self.transferValue(options.sender, options.recipient, options.value)) {
                return .{
                    .outcome = .{ .status = .invalid, .cause = .insufficient_balance },
                    .gas_left = std.math.cast(i64, options.gas) orelse std.math.maxInt(i64),
                    .gas_refund = 0,
                    .gas_reservoir = std.math.cast(i64, options.gas_reservoir) orelse std.math.maxInt(i64),
                    .output_data = &.{},
                };
            }

            const message = Host.Message{
                .depth = 0,
                .kind = .call,
                .gas = std.math.cast(i64, options.gas) orelse std.math.maxInt(i64),
                .gas_reservoir = std.math.cast(i64, options.gas_reservoir) orelse std.math.maxInt(i64),
                .recipient = options.recipient,
                .sender = options.sender,
                .input_data = options.input,
                .value = options.value,
                .code_address = options.recipient,
            };

            const host_result = try self.executePreparedCallMessage(message, options.bytecode);
            if (host_result.status() == .success and options.bytecode.bytes.len == 0) {
                try self.touchEmptyCallRecipient(&message);
            }
            return host_result.executionResult(self.lastOutputData());
        }

        /// Execute one already-resolved root message through the index-based runtime.
        /// The caller owns transaction/checkpoint setup and prepared-code execution.
        pub fn executePreparedCallMessage(
            self: *Executor,
            message: Host.Message,
            bytecode: Bytecode.View,
        ) !Host.Result {
            var runtime = CallRuntime.init(self);
            defer runtime.deinit();
            try runtime.prepare();
            try runtime.pushRootCall(&message, bytecode);
            return runtime.run();
        }

        /// Execute a root call without entering the iterative frame store.
        /// Nested CALL/CREATE actions promote through `resolveHostCall`.
        pub fn executePreparedCallMessageDirect(
            self: *Executor,
            message: Host.Message,
            bytecode: Bytecode.View,
        ) !Host.Result {
            std.debug.assert(self.currentCaptureContext() == null);
            std.debug.assert(self.prepared_code_execution != null);
            var host_iface = self.host();
            var slot: Interpreter.CallFrameSlot = undefined;
            slot.init(self.allocator, .{
                .host = &host_iface,
                .msg = &message,
                .execution_context = &self.execution_context.?,
                .bytecode = bytecode,
            });
            defer slot.deinit();

            var interpreter = slot.interpreter(spec);
            const previous_depth = self.trace_depth;
            self.trace_depth = message.depth;
            defer self.trace_depth = previous_depth;
            const result = try interpreter.execute();
            return stabilizeFinalResult(
                self,
                Host.Result.fromExecution(result.executionResult(), false),
            );
        }

        /// Execute a root transaction CREATE. Transaction lifecycle owns the
        /// sender nonce; only raw and nested CREATE increment their creator.
        pub fn executeCreateTransactionPhased(
            self: *Executor,
            options: Create,
            gas: ExecutionGas,
        ) !TransactionExecutionOutcome {
            self.beginPreparedCodeExecution();
            defer self.endPreparedCodeExecution();

            self.clearLastOutput();
            _ = self.currentExecutionContext();
            var execution_gas = gas;
            const top_frame_state_gas = try self.chargeTopFrameCreateStateGas(options, &execution_gas);
            if (top_frame_state_gas.out_of_gas) {
                return .{
                    .stage = .preparation,
                    .result = .{
                        .outcome = .{ .status = .out_of_gas, .cause = .out_of_gas },
                        .gas_left = 0,
                        .gas_refund = 0,
                        .gas_reservoir = std.math.cast(i64, execution_gas.reservoir) orelse std.math.maxInt(i64),
                        .output_data = &.{},
                    },
                };
            }

            const host_result = try self.executeTransactionCreateMessage(.{
                .depth = 0,
                .kind = if (options.salt == null) .create else .create2,
                .gas = std.math.cast(i64, execution_gas.regular_left) orelse std.math.maxInt(i64),
                .gas_reservoir = std.math.cast(i64, execution_gas.reservoir) orelse std.math.maxInt(i64),
                .recipient = options.recipient,
                .sender = options.sender,
                .input_data = options.init_code,
                .value = options.value,
            });
            var result = host_result.executionResult(self.lastOutputData());
            top_frame_gas.finish(&result, top_frame_state_gas);
            return .{ .stage = .payload, .result = result };
        }

        pub fn executeCreate(self: *Executor, options: Create, gas: ExecutionGas) !Result {
            self.beginPreparedCodeExecution();
            defer self.endPreparedCodeExecution();

            self.clearLastOutput();
            _ = self.currentExecutionContext();
            try self.traceAccountAccess(options.recipient);
            return self.executeCreateMessage(.{
                .depth = 0,
                .kind = if (options.salt == null) .create else .create2,
                .gas = std.math.cast(i64, gas.regular_left) orelse std.math.maxInt(i64),
                .gas_reservoir = std.math.cast(i64, gas.reservoir) orelse std.math.maxInt(i64),
                .recipient = options.recipient,
                .sender = options.sender,
                .input_data = options.init_code,
                .value = options.value,
            });
        }

        /// Execute a system call as its own transaction-like scope.
        ///
        /// System calls bypass user transaction charging and value transfer, but still
        /// run with a execution context, checkpoint state, and commit/rollback semantics.
        pub fn executeSystemCall(
            self: *Executor,
            context: ExecutionContext,
            sender: Address,
            recipient: Address,
            input: []const u8,
            gas: ExecutionGas,
        ) !ExecutionResult {
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
            self: *Executor,
            context: ExecutionContext,
            sender: Address,
            recipient: Address,
            input: []const u8,
            gas: ExecutionGas,
            mode: InstrumentationMode,
            observer: anytype,
        ) !ExecutionResult {
            self.beginPreparedCodeExecution();
            defer self.endPreparedCodeExecution();

            try self.beginSystemCall(context, mode);
            errdefer self.discardStateTransition();

            self.clearLastOutput();
            var execution_checkpoint = self.checkpoint();
            defer execution_checkpoint.deinit();

            const resolved = try self.resolveCode(recipient);
            const resolved_view = try self.resolvedCodeView(resolved);
            const bytecode = try self.resolveExecutionCodeView(resolved_view);
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
                .normal, .observed => self.executePreparedCallMessageDirect(message, bytecode),
                .captured => self.executePreparedCallMessage(message, bytecode),
            };

            if (!host_result.isSuccess()) {
                execution_checkpoint.restore();
                try self.retainStateTransitionWithObserver(observer);
            } else {
                execution_checkpoint.commit();
                try self.commitTransactionWithObserver(observer);
            }

            return host_result.executionResult(self.lastOutputData());
        }

        // Mode facades. Each re-declares the same operations to bind one `InstrumentationMode`.

        pub fn ObservedExecutor(comptime Observer: type) type {
            return struct {
                executor: *Executor,
                observer: Observer,

                pub fn beginTransaction(self: @This(), context: ExecutionContext, sender: Address, recipient: Address) !void {
                    try self.executor.beginTransactionMode(context, sender, recipient, .observed);
                }

                pub fn beginMessageScope(self: @This(), request: ExecutionRequest, scope_init: ExecutionScopeInit) !void {
                    try self.executor.beginMessageScopeContext(request.context, request.message, scope_init, .observed);
                }

                pub fn beginStateTransition(self: @This(), context: ExecutionContext) !void {
                    try self.executor.openTransactionScope(context, .observed);
                }

                pub fn commitTransaction(self: @This()) !void {
                    try self.executor.commitTransactionWithObserver(self.observer);
                }

                pub fn retainStateTransition(self: @This()) !void {
                    try self.executor.retainStateTransitionWithObserver(self.observer);
                }

                pub fn executeStandalone(self: @This(), request: ExecutionRequest, scope_init: ExecutionScopeInit) !Result {
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
                    context: ExecutionContext,
                    sender: Address,
                    recipient: Address,
                    input: []const u8,
                    gas: ExecutionGas,
                ) !ExecutionResult {
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
        pub fn observe(self: *Executor, observer: anytype) ObservedExecutor(@TypeOf(observer)) {
            return .{ .executor = self, .observer = observer };
        }

        pub const CapturedExecutor = struct {
            executor: *Executor,
            context: *CaptureContext,

            pub fn beginTransaction(
                self: CapturedExecutor,
                execution_context: ExecutionContext,
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
                execution_context: ExecutionContext,
                message: Message,
                gas: ExecutionGas,
            ) !Result {
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
                execution_context: ExecutionContext,
                sender: Address,
                recipient: Address,
                input: []const u8,
                gas: ExecutionGas,
                observer: anytype,
            ) !ExecutionResult {
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
        pub fn capture(self: *Executor, context: *CaptureContext) CapturedExecutor {
            return .{ .executor = self, .context = context };
        }
    };
}

test "CREATE final stabilization reuses already-stable output" {
    const Berlin = evmz.t.Vm(.berlin) orelse return error.SkipZigTest;
    const Executor = Berlin.Executor;

    var failing_allocator = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    var executor = Executor.init(failing_allocator.allocator(), .{});
    defer executor.deinit();

    executor.last_call_output.deinit();
    executor.last_call_output = frame_io.ByteSlot.init(std.testing.allocator);
    _ = try executor.setLastOutput(&.{0xaa});
    const result = try executor.stabilizeFinalResult(.{
        .outcome = .{ .status = .success, .cause = .none },
        .output_data = executor.lastOutputData(),
        .gas_left = 7,
        .gas_refund = 0,
    });

    try std.testing.expectEqualSlices(u8, &.{0xaa}, result.output_data);
    try std.testing.expect(result.output_data.ptr == executor.lastOutputData().ptr);
}

test "EIP-7610 creation collision applies retroactively to every revision" {
    const target = evmz.addr(0x1234);

    // Sweeps only the fork set compiled into this build; ci's `all` lane
    // restores the full retroactive matrix.
    inline for (evmz.t.enabled_revisions) |revision| {
        try expectCreationCollision(revision, target);
    }
}

test "interior checkpoint guard restores unresolved state and preserves commits" {
    const Cancun = evmz.t.Vm(.cancun) orelse return error.SkipZigTest;
    const Executor = Cancun.Executor;
    const address = evmz.addr(0x1234);

    var executor = Executor.init(std.testing.allocator, .{});
    defer executor.deinit();
    const attempt = executor.state.beginTransaction();
    executor.state.beginScope();
    defer {
        executor.state.closeScope();
        executor.state.seal(attempt);
        executor.state.discard(attempt);
    }

    {
        var checkpoint = Executor.CheckpointGuard.begin(&executor.state);
        defer checkpoint.deinit();
        try executor.state.addBalance(address, 7);
    }
    try std.testing.expectEqual(@as(u256, 0), try executor.state.getBalance(address));

    {
        var checkpoint = Executor.CheckpointGuard.begin(&executor.state);
        defer checkpoint.deinit();
        try executor.state.addBalance(address, 9);
        checkpoint.commit();
    }
    try std.testing.expectEqual(@as(u256, 9), try executor.state.getBalance(address));
}

test "call runtime abort skips resolved top and restores enclosing checkpoint" {
    const Cancun = evmz.t.Vm(.cancun) orelse return error.SkipZigTest;
    const Executor = Cancun.Executor;
    const sender = evmz.addr(0x1111);
    const root_address = evmz.addr(0x2222);
    const parent_write = evmz.addr(0x3333);
    const child_write = evmz.addr(0x4444);

    var executor = Executor.init(std.testing.allocator, .{});
    defer executor.deinit();
    try executor.beginTransaction(
        evmz.t.defaultExecutionContext(sender, 100_000),
        sender,
        root_address,
    );
    defer executor.discardStateTransition();

    executor.beginPreparedCodeExecution();
    defer executor.endPreparedCodeExecution();
    var bytecode = try executor.prepareBytecode(&.{0x00});
    defer bytecode.deinit(std.testing.allocator);

    const root_message = Host.Message{
        .depth = 0,
        .kind = .call,
        .gas = 100_000,
        .recipient = root_address,
        .sender = sender,
        .input_data = &.{},
        .value = 0,
        .code_address = root_address,
    };
    var call = Executor.CallRuntime.init(&executor);
    defer call.deinit();
    try call.prepare();
    try call.pushRootCall(&root_message, bytecode.view());

    const parent_checkpoint = executor.state.checkpoint();
    try executor.state.addBalance(parent_write, 7);
    var parent_message = root_message;
    parent_message.depth = 1;
    try call.pushChildCall(&parent_message, bytecode.view(), parent_checkpoint, null);

    const child_checkpoint = executor.state.checkpoint();
    try executor.state.addBalance(child_write, 9);
    var child_message = root_message;
    child_message.depth = 2;
    try call.pushChildCall(&child_message, bytecode.view(), child_checkpoint, null);

    const child_index = call.frames.len() - 1;
    const child_frame = call.frames.frame(child_index);
    child_frame.halt(.success);
    _ = try call.finishFrame(child_index, child_frame.result());

    call.deinit();
    try std.testing.expectEqual(@as(u256, 0), try executor.state.getBalance(parent_write));
    try std.testing.expectEqual(@as(u256, 0), try executor.state.getBalance(child_write));
    try std.testing.expectEqual(@as(usize, 0), executor.frame_store.len());
}

test "nested runtime error restores its transferred checkpoint once" {
    if (comptime !evmz.t.forkEnabled(.cancun)) return error.SkipZigTest;
    const fail_byte: u8 = 0xb0;
    const Fail = struct {
        pub inline fn execute(comptime _: evmz.spec.Spec, _: *Interpreter.CallFrame) anyerror!void {
            return error.ForcedRuntimeFailure;
        }
    };
    const custom_instructions = comptime instructions: {
        var instructions = evmz.eth.cancun.instruction;
        instructions.install(.SQUARE, fail_byte, .{
            .static_gas = 0,
            .stack_in = 0,
        }, .{ .custom = Fail });
        break :instructions instructions;
    };
    const Exact = evmz.t.CustomVm(.cancun, .{ .instruction = custom_instructions }) orelse return error.SkipZigTest;
    const Executor = Exact.Executor;
    const sender = evmz.addr(0x1111);
    const recipient = evmz.addr(0x2222);

    var executor = Executor.init(std.testing.allocator, .{});
    defer executor.deinit();
    try evmz.t.seedExecutorAccount(&executor, sender, .{ .balance = 10 });
    var recipient_account = evmz.state.MemoryAccount.init(std.testing.allocator);
    try recipient_account.setCode(&.{fail_byte});
    try executor.state.seedAccount(recipient, recipient_account);
    try executor.beginTransaction(
        evmz.t.defaultExecutionContext(sender, 100_000),
        sender,
        recipient,
    );
    defer executor.discardStateTransition();

    try std.testing.expectError(error.ForcedRuntimeFailure, executor.resolveHostCall(.{
        .depth = 1,
        .kind = .call,
        .gas = 100_000,
        .recipient = recipient,
        .sender = sender,
        .input_data = &.{},
        .value = 7,
        .code_address = recipient,
    }));
    try std.testing.expectEqual(@as(u256, 10), try executor.state.getBalance(sender));
    try std.testing.expectEqual(@as(u256, 0), try executor.state.getBalance(recipient));
    try std.testing.expectEqual(@as(usize, 0), executor.frame_store.len());
}

fn expectCreationCollision(comptime revision: evmz.eth.Revision, target: Address) !void {
    const Exact = evmz.Vm(evmz.eth.specAt(revision));
    var executor = Exact.Executor.init(std.testing.allocator, .{});
    defer executor.deinit();
    var target_account = evmz.state.MemoryAccount.init(std.testing.allocator);
    try target_account.storage.put(1, 1);
    try executor.state.seedAccount(target, target_account);
    try std.testing.expect(try executor.createCollision(target));
}

test "nested call runtime owns its segment and keeps capture indices global" {
    const Exact = evmz.t.Vm(.cancun) orelse return error.SkipZigTest;
    const Executor = Exact.Executor;
    const child_address = evmz.addr(0x3333);

    var executor = Executor.init(std.testing.allocator, .{});
    defer executor.deinit();
    var child_account = evmz.state.MemoryAccount.init(std.testing.allocator);
    try child_account.setCode(&.{ 0x60, 0x07, 0x60, 0x00, 0x55, 0x00 });
    try executor.state.seedAccount(child_address, child_account);

    var tape = evmz.trace.TraceTape.initGrowable(std.testing.allocator);
    defer tape.deinit();
    var capture = CaptureContext.init(std.testing.allocator, .{ .tape = &tape });
    defer capture.deinit();
    try capture.begin();
    errdefer capture.abort() catch {};

    try executor.capture(&capture).beginTransaction(
        evmz.t.defaultExecutionContext(evmz.addr(0x1111), 100_000),
        evmz.addr(0x1111),
        evmz.addr(0x2222),
    );
    defer executor.discardStateTransition();

    executor.beginPreparedCodeExecution();
    defer executor.endPreparedCodeExecution();

    var bytecode = try executor.prepareBytecode(&.{0x00});
    defer bytecode.deinit(std.testing.allocator);
    const root_message = Host.Message{
        .depth = 0,
        .kind = .call,
        .gas = 100,
        .recipient = evmz.addr(0x2222),
        .sender = evmz.addr(0x1111),
        .input_data = &.{},
        .value = 0,
        .code_address = evmz.addr(0x2222),
    };

    var outer = Executor.CallRuntime.init(&executor);
    try outer.prepare();
    try outer.pushRootCall(&root_message, bytecode.view());
    try std.testing.expectEqual(@as(usize, 1), executor.frame_store.len());

    const nested_probe = Executor.CallRuntime.init(&executor);
    try std.testing.expectEqual(@as(usize, 1), nested_probe.frame_base);
    const child_result = (try executor.resolveHostCall(.{
        .depth = 1,
        .kind = .call,
        .gas = 100_000,
        .recipient = child_address,
        .sender = root_message.recipient,
        .input_data = &.{},
        .value = 0,
        .code_address = child_address,
    }));
    try std.testing.expectEqual(Interpreter.Status.success, child_result.status());
    try std.testing.expectEqual(@as(usize, 1), executor.frame_store.len());
    try std.testing.expectEqual(@as(usize, 1), capture.frame_captures.items.len);
    try std.testing.expectEqual(@as(u256, 7), try executor.state.getStorage(child_address, 0));

    const root_result = try outer.run();
    try std.testing.expectEqual(Interpreter.Status.success, root_result.status());
    try std.testing.expectEqual(@as(usize, 0), executor.frame_store.len());

    const span = (try capture.finish()).?;
    defer tape.resolve(span) catch unreachable;
    try std.testing.expectEqual(@as(usize, 2), span.frames.len);
    try std.testing.expectEqual(evmz.trace.TraceFrameKind.root, span.frames[0].kind);
    try std.testing.expectEqual(@as(?u32, 0), span.frames[1].parent_frame_id);
    try std.testing.expectEqual(evmz.trace.TraceFrameKind.call, span.frames[1].kind);
}

test {
    std.testing.refAllDecls(@This());
    _ = @import("./executor_test.zig");
}
