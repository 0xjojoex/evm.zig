//! Low-level EVM execution engine.
//!
//! `Executor` owns the mutable overlay state, transaction context, frame pools,
//! and output buffers used while running EVM code. Higher-level APIs such as
//! `Vm` handle validation and user-facing transaction shapes; this type is the
//! execution substrate underneath them.
//!
//! The public methods fall into two lifecycle layers:
//!
//! 1. `runStandalone` is the convenience path for raw call/create messages. It
//!    opens a transaction scope, checkpoints state, executes, then commits or
//!    rolls back from the result status.
//! 2. `beginMessageScope` + `beginTransactionAttempt` is the neutral transaction
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
pub const resource_bound = @import("./executor/resource_bound.zig");
pub const errors = @import("./executor/error.zig");
const Address = evmz.Address;
const AccountState = evmz.state.Account;
const MemoryAccount = evmz.state.MemoryAccount;
const BlockHashSource = evmz.BlockHashSource;
const Bytecode = evmz.Bytecode;
const prepared_code = evmz.prepared_code;
const Changeset = evmz.state.Changeset;
const execution_values = @import("./execution.zig");
const Host = evmz.Host;
const Interpreter = evmz.interpreter;
const JournalCheckpoint = evmz.state.Journal.Checkpoint;
const StateOverlay = evmz.state.Overlay;
const RevisionId = evmz.protocol.RevisionId;
const EthProtocol = evmz.Evm.ExecutionProtocol;
pub const Snapshot = StateOverlay.Snapshot;
pub const TransientSnapshot = StateOverlay.TransientSnapshot;
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
const SnapshotType = Snapshot;
const TransientSnapshotType = TransientSnapshot;
const call_runtime = @import("./executor/call_runtime.zig");
pub const capture_context = @import("./executor/capture_context.zig");
const call_scratch_storage = @import("./executor/call_scratch.zig");
const context_adapter = @import("./executor/context.zig");
pub const eip7702 = @import("./executor/eip7702.zig");
pub const FrameStore = @import("./executor/frame_store.zig");
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
/// BLOCKHASH reads chain history, not account/trie state. Capture is bound for
/// an operation through `setCaptureContext`, not construction.
fn InitFor(comptime Protocol: type) type {
    return struct {
        revision: Protocol.Revision,
        state_reader: ?evmz.state.Reader = null,
        /// Caller-owned derived-artifact service. Its allocation, I/O,
        /// synchronization, and capacity policy are outside executor bounds.
        prepared_code_backend: ?prepared_code.Backend = null,
        block_hash_source: ?BlockHashSource = null,
        precompile_runtime: ?execution_values.PrecompileRuntime = null,
        config: evmz.ExecutionConfig = .base,
    };
}

pub const default_max_live_frames: usize = @as(usize, Host.max_call_depth) + 1;

/// Optional steady-state resource caps for the executor.
///
/// These are caller-supplied runtime policy knobs. Growable remains the
/// default; each configured field means "reserve this backing storage and fail
/// instead of growing it." Caller-owned services such as `state_reader`,
/// `prepared_code_backend`, tracing, and precompile runtimes are outside this
/// VM-owned resource envelope and must enforce their own operational policy.
pub const BoundedRuntimeResources = struct {
    /// Semantic ceiling when these capacities were derived from block gas.
    /// Caller-declared capacity envelopes leave this null.
    max_block_gas: ?u64 = null,
    max_live_frames: usize = default_max_live_frames,
    memory_bytes_per_frame: ?usize = null,
    io_bytes_per_frame: ?usize = null,
    scratch_bytes_per_frame: ?usize = null,
    /// Transaction-scoped storage for transient prepared bytecode and metadata.
    /// `null` leaves this resource growable; a value reserves exactly that many
    /// bytes and reports `PreparedCodeCapacityExceeded` instead of growing.
    prepared_code_bytes_per_execution: ?usize = null,
    logs: ?StateOverlay.LogResources = null,
    journal_entries: ?usize = null,
    access: ?StateOverlay.AccessResources = null,
    state: ?StateOverlay.StateResources = null,
    transient_storage_entries: ?usize = null,
    result_bytes: ?usize = null,

    /// Convert a source-neutral resource envelope to bounded executor knobs.
    /// Byte caps stay caller-owned until EVM memory and frame/result I/O have
    /// transaction-wide planners.
    pub fn fromResourceEnvelope(envelope: resource_bound.Envelope) BoundedRuntimeResources {
        const block = envelope.block;
        const tx = envelope.transaction;
        return .{
            .max_live_frames = tx.max_live_frames,
            .logs = .{
                .entries = tx.logs.entries,
                .data_bytes = tx.logs.data_bytes,
            },
            .journal_entries = tx.journal_entries,
            .access = .{
                .accounts = tx.access.accounts,
                .storage_keys = tx.access.storage_keys,
            },
            .state = .{
                .accounts = block.state.accounts,
                .code_entries = block.state.code_entries,
                .code_bytes = block.state.code_bytes,
                .original_storage_entries = tx.state.original_storage_entries,
                .storage_overlay_entries = block.state.storage_overlay_entries,
                .selfdestructed_accounts = tx.state.selfdestructed_accounts,
                .created_contracts = tx.state.created_contracts,
                .deleted_accounts = block.state.deleted_accounts,
                .dirty_accounts = block.state.dirty_accounts,
            },
            .transient_storage_entries = tx.transient_storage_entries,
        };
    }
};

pub const RuntimeResources = union(enum) {
    growable,
    bounded: BoundedRuntimeResources,

    pub fn maxLiveFrames(self: RuntimeResources) ?usize {
        return switch (self) {
            .growable => null,
            .bounded => |bounded| bounded.max_live_frames,
        };
    }

    pub fn blockGasLimitBound(self: RuntimeResources) ?u64 {
        return switch (self) {
            .growable => null,
            .bounded => |bounded| bounded.max_block_gas,
        };
    }
};

test "resource bound envelope maps executor resources by lifetime" {
    const resources = BoundedRuntimeResources.fromResourceEnvelope(.{
        .source = .gas_derived,
        .block = .{ .state = .{
            .accounts = 101,
            .code_entries = 108,
            .code_bytes = 109,
            .original_storage_entries = 102,
            .storage_overlay_entries = 103,
            .selfdestructed_accounts = 104,
            .created_contracts = 105,
            .deleted_accounts = 106,
            .dirty_accounts = 107,
        } },
        .transaction = .{
            .max_live_frames = 11,
            .logs = .{ .entries = 12, .data_bytes = 13 },
            .journal_entries = 14,
            .access = .{ .accounts = 15, .storage_keys = 16 },
            .state = .{
                .accounts = 201,
                .original_storage_entries = 202,
                .storage_overlay_entries = 203,
                .selfdestructed_accounts = 204,
                .created_contracts = 205,
                .deleted_accounts = 206,
                .dirty_accounts = 207,
            },
            .transient_storage_entries = 17,
        },
    });

    try std.testing.expectEqual(@as(usize, 11), resources.max_live_frames);
    try std.testing.expectEqual(@as(usize, 12), resources.logs.?.entries);
    try std.testing.expectEqual(@as(usize, 13), resources.logs.?.data_bytes);
    try std.testing.expectEqual(@as(usize, 14), resources.journal_entries.?);
    try std.testing.expectEqual(@as(usize, 15), resources.access.?.accounts);
    try std.testing.expectEqual(@as(usize, 16), resources.access.?.storage_keys);
    try std.testing.expectEqual(@as(usize, 101), resources.state.?.accounts);
    try std.testing.expectEqual(@as(usize, 108), resources.state.?.code_entries.?);
    try std.testing.expectEqual(@as(usize, 109), resources.state.?.code_bytes.?);
    try std.testing.expectEqual(@as(usize, 202), resources.state.?.original_storage_entries);
    try std.testing.expectEqual(@as(usize, 103), resources.state.?.storage_overlay_entries);
    try std.testing.expectEqual(@as(usize, 204), resources.state.?.selfdestructed_accounts);
    try std.testing.expectEqual(@as(usize, 205), resources.state.?.created_contracts);
    try std.testing.expectEqual(@as(usize, 106), resources.state.?.deleted_accounts);
    try std.testing.expectEqual(@as(usize, 107), resources.state.?.dirty_accounts);
    try std.testing.expectEqual(@as(usize, 17), resources.transient_storage_entries.?);
    try std.testing.expectEqual(@as(?usize, null), resources.memory_bytes_per_frame);
    try std.testing.expectEqual(@as(?usize, null), resources.io_bytes_per_frame);
    try std.testing.expectEqual(@as(?usize, null), resources.scratch_bytes_per_frame);
    try std.testing.expectEqual(@as(?usize, null), resources.result_bytes);
}

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

const PreparedCallTransactionType = PreparedCallTransaction;
const CallType = Call;
const CreateType = Create;
const MessageType = Message;
const code_deposit_gas_value = code_deposit_gas;
const default_max_live_frames_value = default_max_live_frames;
const RuntimeResourcesType = RuntimeResources;
const BoundedRuntimeResourcesType = BoundedRuntimeResources;
const ErrorType = errors.Error;
pub const CaptureContext = capture_context.Context;
pub const CaptureStateTarget = capture_context.StateTarget;

/// The execution engine bound to a concrete `ProtocolType`.
///
/// Returns the `Executor` struct type described in the module doc above: it
/// carries the protocol-specific message/result aliases and the call/create
/// lifecycle methods for that fork. Instantiate once per protocol; a `Vm` wraps
/// one internally, and diagnostics/benchmarks can drive it directly.
pub fn Executor(comptime ProtocolType: type) type {
    return struct {
        const Self = @This();
        const runtime = call_runtime.For(Self);
        const callbacks = host_callbacks.For(Self);

        pub const Protocol = ProtocolType;
        pub const Error = ErrorType;
        pub const Init = InitFor(Protocol);
        pub const PreparedCallTransaction = PreparedCallTransactionType;
        pub const Call = CallType;
        pub const Create = CreateType;
        pub const Message = MessageType;
        pub const EvmResult = EvmResultType;
        pub const TransactionExecutionOutcome = TransactionExecutionOutcomeType;
        pub const Snapshot = SnapshotType;
        pub const TransientSnapshot = TransientSnapshotType;
        pub const code_deposit_gas = code_deposit_gas_value;
        pub const default_max_live_frames = default_max_live_frames_value;
        pub const RuntimeResources = RuntimeResourcesType;
        pub const BoundedRuntimeResources = BoundedRuntimeResourcesType;

        pub fn normalizeError(err: anyerror) Error {
            return errors.normalize(err);
        }

        allocator: std.mem.Allocator,
        state: StateOverlay,
        frame_store: FrameStore,
        runtime_frames: RuntimeFrameStack,
        call_scratch_slots: CallScratchSlots,
        prepared_code_scratch: call_scratch_storage.Slot,
        runtime_resources: RuntimeResourcesType = .growable,
        runtime_resources_locked: bool = false,
        execution_context: ?execution_values.ExecutionContext = null,
        scope_root: ?ScopeRoot = null,
        attempt_execution_journal_start: ?usize = null,
        active_transaction_checkpoint_id: usize = 0,
        next_transaction_checkpoint_id: usize = 0,
        current_transaction_attempt: ?TransactionAttemptState = null,
        next_transaction_attempt_generation: u64 = 0,
        current_execution_lease: ?ExecutionLeaseState = null,
        next_execution_lease_generation: u64 = 0,
        active_block_execution_generation: ?u64 = null,
        next_block_execution_generation: u64 = 0,
        checkpoint_top: usize = 0,
        next_checkpoint_id: usize = 0,
        block_hash_source: ?BlockHashSource = null,
        precompile_runtime: ?execution_values.PrecompileRuntime = null,
        revision_id: RevisionId,
        config: evmz.ExecutionConfig,
        prepared_code_backend: ?prepared_code.Backend,
        prepared_code_execution: ?prepared_code.Execution = null,
        prepared_code_execution_depth: usize = 0,
        prepared_code_admission: bool = true,
        capture_context: ?*CaptureContext = null,
        last_call_output: frame_io.ByteSlot,

        const ExecutionLeaseState = struct {
            checkpoint: TransactionCheckpoint,
            generation: u64,
        };

        const TransactionAttemptState = struct {
            checkpoint: TransactionCheckpoint,
            generation: u64,
        };

        pub const TransactionAttemptError = error{
            NoCurrentTransaction,
            StaleTransactionExecution,
        };

        /// Generation-checked mutation capability for one rollback-armed
        /// transaction attempt. It exposes execution and neutral state
        /// operations, but only the owning transaction binder may turn it into
        /// an executed lease.
        pub const TransactionAttempt = struct {
            executor: *Self,
            generation: u64,

            pub const AccountSummary = struct {
                nonce: u64,
                balance: u256,
                code_hash: [32]u8,
            };

            pub fn revision(self: TransactionAttempt) TransactionAttemptError!Protocol.Revision {
                try self.requireActive();
                return self.executor.revision();
            }

            pub fn allocator(self: TransactionAttempt) TransactionAttemptError!std.mem.Allocator {
                try self.requireActive();
                return self.executor.allocator;
            }

            pub fn executeRequest(
                self: TransactionAttempt,
                request: execution_values.EvmExecutionRequest,
            ) !Interpreter.Result {
                try self.requireActive();
                return self.executor.executeTransactionRequest(request);
            }

            pub fn executeRequestPhased(
                self: TransactionAttempt,
                request: execution_values.EvmExecutionRequest,
            ) !TransactionExecutionOutcomeType {
                try self.requireActive();
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
                try self.requireActive();
                return self.executor.runPayloadInOpenScope(request);
            }

            /// Execute a nested prelude request under this attempt's outer
            /// rollback checkpoint while temporarily using the request's own
            /// opcode-visible context and root message.
            pub fn executePreludeRequest(
                self: TransactionAttempt,
                request: execution_values.EvmExecutionRequest,
            ) !Interpreter.Result {
                try self.requireActive();
                return self.executor.runTransactionPreludeRequest(request);
            }

            /// Open the payload's execution scope after any transaction
            /// prelude scopes have closed.
            pub fn beginExecution(
                self: TransactionAttempt,
                request: execution_values.EvmExecutionRequest,
                scope_init: execution_values.ExecutionScopeInit,
            ) !void {
                try self.requireActive();
                try self.executor.beginMessageScopeInAttempt(request, scope_init);
            }

            pub fn checkpoint(self: TransactionAttempt) !ExecutionCheckpoint {
                try self.requireActive();
                return self.executor.checkpoint();
            }

            pub fn accountSummary(self: TransactionAttempt, account_address: Address) !?AccountSummary {
                try self.requireActive();
                const account = try self.executor.getAccountOrLoad(account_address) orelse return null;
                return .{
                    .nonce = account.nonce,
                    .balance = account.balance,
                    .code_hash = account.code_hash,
                };
            }

            pub fn code(self: TransactionAttempt, account_address: Address) ![]const u8 {
                try self.requireActive();
                return self.executor.getCode(account_address);
            }

            pub fn balance(self: TransactionAttempt, account_address: Address) !u256 {
                try self.requireActive();
                return self.executor.getBalance(account_address);
            }

            pub fn accountAccess(self: TransactionAttempt, account_address: Address) !void {
                try self.requireActive();
                try self.executor.traceAccountAccess(account_address, 0);
            }

            pub fn touchAccount(self: TransactionAttempt, account_address: Address) !void {
                try self.requireActive();
                try self.executor.state.touchAccount(account_address);
            }

            pub fn addBalance(self: TransactionAttempt, account_address: Address, value: u256) !void {
                try self.requireActive();
                try self.executor.state.addBalance(account_address, value);
            }

            pub fn subtractBalance(self: TransactionAttempt, account_address: Address, value: u256) !bool {
                try self.requireActive();
                return self.executor.state.subtractBalance(account_address, value);
            }

            pub fn setNonce(self: TransactionAttempt, account_address: Address, nonce: u64) !void {
                try self.requireActive();
                try self.executor.state.setNonce(account_address, nonce);
            }

            pub fn incrementNonce(self: TransactionAttempt, account_address: Address) !void {
                try self.requireActive();
                try self.executor.incrementNonce(account_address);
            }

            pub fn setCode(self: TransactionAttempt, account_address: Address, code_bytes: []const u8) !void {
                try self.requireActive();
                try self.executor.state.setCode(account_address, code_bytes);
            }

            pub fn clearCode(self: TransactionAttempt, account_address: Address) !void {
                try self.requireActive();
                try self.executor.state.clearCode(account_address);
            }

            pub fn warmAccount(self: TransactionAttempt, account_address: Address) !void {
                try self.requireActive();
                try self.executor.warmAccount(account_address);
            }

            pub fn warmStorage(self: TransactionAttempt, account_address: Address, key: u256) !void {
                try self.requireActive();
                try self.executor.warmStorage(account_address, key);
            }

            pub fn finalizeState(self: TransactionAttempt) !void {
                try self.requireActive();
                try self.executor.finalizeTransactionState();
            }

            pub fn logs(self: TransactionAttempt) TransactionAttemptError![]const Host.Log {
                try self.requireActive();
                return self.executor.logs();
            }

            /// Seal the attempt into a neutral retain/discard lease. Family
            /// transaction output stays in the transaction binder.
            pub fn completeLease(self: TransactionAttempt) TransactionAttemptError!ExecutionLease {
                const state_value = try self.state();
                const checkpoint_value = state_value.checkpoint;
                self.executor.current_transaction_attempt = null;
                return self.executor.openExecutionLease(checkpoint_value);
            }

            pub fn discard(self: TransactionAttempt) !void {
                const state_value = try self.state();
                defer {
                    self.executor.clearLastOutput();
                    self.executor.closeTransactionLifetime();
                    self.executor.current_transaction_attempt = null;
                }
                try state_value.checkpoint.restore();
            }

            pub fn discardIfCurrent(self: TransactionAttempt) void {
                const current = if (self.executor.current_transaction_attempt) |*value| value else return;
                if (current.generation != self.generation) return;
                self.discard() catch {};
            }

            fn requireActive(self: TransactionAttempt) TransactionAttemptError!void {
                _ = try self.state();
            }

            fn state(self: TransactionAttempt) TransactionAttemptError!*TransactionAttemptState {
                const state_value = if (self.executor.current_transaction_attempt) |*value| value else return error.NoCurrentTransaction;
                if (state_value.generation != self.generation)
                    return error.StaleTransactionExecution;
                return state_value;
            }
        };

        pub const ExecutionLeaseError = error{
            NoCurrentTransaction,
            StaleTransactionExecution,
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

        /// Checked lease over the Executor-owned top-level transaction attempt.
        ///
        /// The outer journal checkpoint and result remain in the Executor until
        /// one current lease retains or discards them. Copies are safe: resolving
        /// one makes every same-generation copy stale, while a later generation
        /// cannot be affected by an older lease.
        pub const ExecutionLease = struct {
            executor: *Self,
            generation: u64,

            pub fn requireCurrent(self: ExecutionLease) ExecutionLeaseError!void {
                _ = try self.state();
            }

            pub fn logs(self: ExecutionLease) ExecutionLeaseError![]const Host.Log {
                _ = try self.state();
                return self.executor.logs();
            }

            /// Materialize the eager overlay while rollback remains armed.
            pub fn changeset(self: ExecutionLease) !Changeset {
                _ = try self.state();
                return self.executor.state.changeset();
            }

            /// Retain a neutral lease whose family output lives beside it.
            pub fn retain(self: ExecutionLease) !void {
                const state_value = try self.state();
                try self.retainState(state_value);
            }

            fn retainState(self: ExecutionLease, state_value: *ExecutionLeaseState) !void {
                state_value.checkpoint.commit() catch |err| {
                    self.executor.clearLastOutput();
                    self.executor.closeTransactionLifetime();
                    self.executor.current_execution_lease = null;
                    return err;
                };
                self.executor.closeTransactionLifetime();
                self.executor.current_execution_lease = null;
            }

            /// Restore the state that preceded this execution. Transaction
            /// ownership closes even if rollback observation reports an error.
            pub fn discard(self: ExecutionLease) !void {
                const state_value = try self.state();
                defer {
                    self.executor.clearLastOutput();
                    self.executor.closeTransactionLifetime();
                    self.executor.current_execution_lease = null;
                }
                try state_value.checkpoint.restore();
            }

            pub fn discardIfCurrent(self: ExecutionLease) void {
                const current = if (self.executor.current_execution_lease) |*value| value else return;
                if (current.generation != self.generation) return;
                self.discard() catch {};
            }

            pub fn deinit(self: *ExecutionLease) void {
                self.discardIfCurrent();
                self.* = undefined;
            }

            fn state(self: ExecutionLease) ExecutionLeaseError!*ExecutionLeaseState {
                const state_value = if (self.executor.current_execution_lease) |*value| value else return error.NoCurrentTransaction;
                if (state_value.generation != self.generation) return error.StaleTransactionExecution;
                return state_value;
            }
        };

        const TransactionFinalizer = struct {
            revision: Protocol.Revision,

            pub fn selfDestructFinalization(
                self: @This(),
                created_in_transaction: bool,
            ) evmz.protocol.SelfDestructFinalization {
                return Protocol.self_destruct.selfDestructFinalization(self.revision, created_in_transaction);
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
            journal_checkpoint: JournalCheckpoint,
            id: usize,
            parent_id: usize,
            open: bool = true,

            pub fn commit(self: *ExecutionCheckpoint) !void {
                try self.validateClose();
                self.executor.state.commitCheckpoint(self.journal_checkpoint) catch |err| {
                    self.executor.state.revertToCheckpoint(self.journal_checkpoint) catch {};
                    self.finishClose();
                    return err;
                };
                self.finishClose();
            }

            pub fn restore(self: *ExecutionCheckpoint) !void {
                try self.validateClose();
                self.executor.state.revertToCheckpoint(self.journal_checkpoint) catch |err| {
                    self.finishClose();
                    return err;
                };
                self.finishClose();
            }

            pub fn deinit(self: *ExecutionCheckpoint) void {
                if (self.open) {
                    std.debug.assert(self.executor.checkpoint_top == self.id);
                    self.executor.state.revertToCheckpoint(self.journal_checkpoint) catch {};
                    self.finishClose();
                }
                self.* = undefined;
            }

            fn validateClose(self: *const ExecutionCheckpoint) !void {
                if (!self.open) return error.CheckpointClosed;
                if (self.executor.checkpoint_top != self.id) return error.CheckpointOrderViolation;
            }

            fn finishClose(self: *ExecutionCheckpoint) void {
                self.open = false;
                self.executor.checkpoint_top = self.parent_id;
            }
        };

        /// The one outer journal checkpoint spanning transaction charging,
        /// execution finalization, and settlement.
        const TransactionCheckpoint = struct {
            executor: *Self,
            journal_checkpoint: JournalCheckpoint,
            id: usize,
            open: bool = true,

            fn commit(self: *TransactionCheckpoint) !void {
                try self.validateClose();
                self.executor.state.commitCheckpoint(self.journal_checkpoint) catch |err| {
                    self.executor.state.revertToCheckpoint(self.journal_checkpoint) catch {};
                    self.finishClose();
                    return err;
                };
                self.finishClose();
            }

            fn restore(self: *TransactionCheckpoint) !void {
                try self.validateClose();
                self.executor.state.revertToCheckpoint(self.journal_checkpoint) catch |err| {
                    self.finishClose();
                    return err;
                };
                self.finishClose();
            }

            fn validateClose(self: *const TransactionCheckpoint) !void {
                if (!self.open) return error.TransactionCheckpointClosed;
                if (self.executor.active_transaction_checkpoint_id != self.id) {
                    return error.TransactionCheckpointOrderViolation;
                }
                if (self.executor.checkpoint_top != 0) return error.ActiveExecutionCheckpoints;
            }

            fn finishClose(self: *TransactionCheckpoint) void {
                self.open = false;
                self.executor.active_transaction_checkpoint_id = 0;
            }
        };

        /// Initialize an executor with an empty mutable overlay.
        pub fn init(allocator: std.mem.Allocator, options: Init) Self {
            const state = if (options.state_reader) |state_reader|
                StateOverlay.initWithStateReader(allocator, state_reader)
            else
                StateOverlay.init(allocator);

            const executor: Self = .{
                .allocator = allocator,
                .state = state,
                .frame_store = .{},
                .runtime_frames = .empty,
                .call_scratch_slots = .empty,
                .prepared_code_scratch = call_scratch_storage.Slot.initGrowable(allocator),
                .runtime_resources = .growable,
                .revision_id = evmz.protocol.revisionIdForProtocol(Protocol, options.revision),
                .block_hash_source = options.block_hash_source,
                .precompile_runtime = options.precompile_runtime,
                .config = options.config,
                .prepared_code_backend = options.prepared_code_backend,
                .capture_context = null,
                .last_call_output = frame_io.ByteSlot.initGrowable(allocator),
            };
            return executor;
        }

        /// Initialize an executor and reserve reusable runtime resources up front.
        pub fn initWithRuntimeResources(allocator: std.mem.Allocator, options: Init, runtime_resources: RuntimeResourcesType) !Self {
            var executor = init(allocator, options);
            errdefer executor.deinit();
            try executor.configureRuntimeResources(runtime_resources);
            return executor;
        }

        /// Bind the one concrete captured runtime. The context may remain
        /// bound while callers opt individual operations in through
        /// `CaptureContext.begin` and `finish`/`abort`.
        pub fn setCaptureContext(self: *Self, context: ?*CaptureContext) void {
            if (self.runtime_frames.items.len != 0) @panic("cannot replace capture context while runtime frames are active");
            if (self.prepared_code_execution_depth != 0) @panic("cannot replace capture context during prepared-code execution");
            if (self.capture_context) |current| {
                if (current.isActive()) @panic("cannot replace an active capture context");
            }
            self.capture_context = context;
            self.state.capture_context = context;
        }

        pub fn traceAccountAccess(self: *Self, account_address: Address, depth: u16) !void {
            if (self.capture_context) |context| try context.accountAccess(.{
                .depth = depth,
                .address = account_address,
            });
        }

        /// Rebind fixture/benchmark inputs while retaining configured resources.
        pub fn reset(self: *Self, options: Init) !void {
            if (self.hasActiveBlockExecution()) return error.BlockExecutionActive;
            if (self.runtime_frames.items.len != 0) return error.ActiveRuntimeFrames;
            if (self.checkpoint_top != 0) return error.ActiveCheckpoints;
            if (self.active_transaction_checkpoint_id != 0) return error.PendingTransactionActive;
            if (self.attempt_execution_journal_start != null) return error.ActiveTransactionScope;
            if (self.prepared_code_execution_depth != 0) return error.ActivePreparedCodeExecution;

            const next_revision_id = evmz.protocol.revisionIdForProtocol(Protocol, options.revision);
            if (self.runtime_resources_locked and self.revision_id != next_revision_id) {
                return error.RuntimeResourcesLocked;
            }
            self.state.reset(options.state_reader);
            self.execution_context = null;
            self.scope_root = null;
            self.attempt_execution_journal_start = null;
            self.block_hash_source = options.block_hash_source;
            self.precompile_runtime = options.precompile_runtime;
            self.revision_id = next_revision_id;
            self.config = options.config;
            self.prepared_code_backend = options.prepared_code_backend;
            self.clearLastOutput();
        }

        pub fn configureRuntimeResources(self: *Self, runtime_resources: RuntimeResourcesType) !void {
            if (self.hasActiveBlockExecution()) return error.BlockExecutionActive;
            if (self.runtime_resources_locked) return error.RuntimeResourcesLocked;
            try self.configureRuntimeResourcesUnlocked(runtime_resources);
        }

        pub fn lockRuntimeResources(self: *Self) void {
            self.runtime_resources_locked = true;
        }

        pub fn blockGasLimitBound(self: *const Self) ?u64 {
            return self.runtime_resources.blockGasLimitBound();
        }

        fn configureRuntimeResourcesUnlocked(self: *Self, runtime_resources: RuntimeResourcesType) !void {
            switch (runtime_resources) {
                .growable => {
                    try self.frame_store.setGrowable(self.allocator);
                    try self.setGrowableCallScratchSlots();
                    self.prepared_code_scratch.setGrowable(self.allocator);
                    try self.state.configureLogResources(null);
                    try self.state.configureJournalEntries(null);
                    try self.state.configureAccessResources(null);
                    try self.state.configureStateResources(null);
                    try self.state.configureTransientStorageEntries(null);
                    self.last_call_output.setGrowable();
                    self.prepared_code_admission = true;
                    self.runtime_resources = .growable;
                },
                .bounded => |bounded| {
                    if (bounded.max_live_frames == 0) return error.InvalidRuntimeResourcesCapacity;
                    try self.frame_store.reserveExact(
                        self.allocator,
                        bounded.max_live_frames,
                        bounded.io_bytes_per_frame,
                        bounded.memory_bytes_per_frame,
                    );
                    try self.reserveRuntimeFrames(bounded.max_live_frames);
                    try self.reserveCallScratchSlots(bounded.max_live_frames, bounded.scratch_bytes_per_frame);
                    if (bounded.prepared_code_bytes_per_execution) |capacity| {
                        try self.prepared_code_scratch.setBounded(self.allocator, capacity);
                    } else {
                        self.prepared_code_scratch.setGrowable(self.allocator);
                    }
                    try self.state.configureLogResources(bounded.logs);
                    try self.state.configureJournalEntries(bounded.journal_entries);
                    try self.state.configureAccessResources(bounded.access);
                    try self.state.configureStateResources(bounded.state);
                    try self.state.configureTransientStorageEntries(bounded.transient_storage_entries);
                    if (bounded.result_bytes) |result_bytes| {
                        try self.last_call_output.setBounded(result_bytes);
                    } else {
                        self.last_call_output.setGrowable();
                    }
                    // Persistent prepared-code allocation is separate from the
                    // currently bounded transient execution envelope. Existing
                    // entries remain usable, but bounded execution does not
                    // admit new cache entries implicitly.
                    self.prepared_code_admission = false;
                    self.runtime_resources = runtime_resources;
                },
            }
        }

        fn reserveRuntimeFrames(self: *Self, capacity: usize) !void {
            if (self.runtime_frames.items.len != 0) return error.ActiveRuntimeFrames;
            try self.runtime_frames.ensureTotalCapacityPrecise(self.allocator, capacity);
        }

        fn reserveCallScratchSlots(self: *Self, capacity: usize, scratch_bytes_per_frame: ?usize) !void {
            if (self.runtime_frames.items.len != 0) return error.ActiveRuntimeFrames;
            try self.call_scratch_slots.ensureTotalCapacityPrecise(self.allocator, capacity);
            while (self.call_scratch_slots.items.len < capacity) {
                const slot = try self.allocator.create(call_scratch_storage.Slot);
                errdefer self.allocator.destroy(slot);
                slot.* = call_scratch_storage.Slot.initGrowable(self.allocator);
                errdefer slot.deinit(self.allocator);
                self.call_scratch_slots.appendAssumeCapacity(slot);
            }
            for (self.call_scratch_slots.items[0..capacity]) |slot| {
                if (scratch_bytes_per_frame) |bytes_per_frame| {
                    try slot.setBounded(self.allocator, bytes_per_frame);
                } else {
                    slot.setGrowable(self.allocator);
                }
            }
        }

        fn setGrowableCallScratchSlots(self: *Self) !void {
            if (self.runtime_frames.items.len != 0) return error.ActiveRuntimeFrames;
            for (self.call_scratch_slots.items) |slot| {
                slot.setGrowable(self.allocator);
            }
        }

        pub inline fn revision(self: *const Self) Protocol.Revision {
            return evmz.protocol.decodeRevisionForProtocol(Protocol, self.revision_id);
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
            return .{ .revision_id = self.revision_id, .config = self.config };
        }

        /// Release state, frame pools, scratch arenas, and retained return-data buffers.
        pub fn deinit(self: *Self) void {
            std.debug.assert(!self.hasActiveBlockExecution());
            std.debug.assert(self.runtime_frames.items.len == 0);
            std.debug.assert(self.checkpoint_top == 0);
            std.debug.assert(self.active_transaction_checkpoint_id == 0);
            std.debug.assert(self.current_transaction_attempt == null);
            std.debug.assert(self.attempt_execution_journal_start == null);
            std.debug.assert(self.prepared_code_execution_depth == 0);
            std.debug.assert(self.prepared_code_execution == null);
            if (self.capture_context) |context| std.debug.assert(!context.isActive());
            std.debug.assert(self.current_execution_lease == null);
            self.state.deinit();
            self.runtime_frames.deinit(self.allocator);
            self.frame_store.deinit(self.allocator);
            self.prepared_code_scratch.deinit(self.allocator);
            for (self.call_scratch_slots.items) |slot| {
                slot.deinit(self.allocator);
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

        fn openTransactionScope(self: *Self, context: execution_values.ExecutionContext) !void {
            if (self.execution_context != null) return error.ActiveTransactionScope;
            if (self.checkpoint_top != 0) return error.ActiveExecutionCheckpoints;
            if (self.active_transaction_checkpoint_id != 0) return error.PendingTransactionActive;
            self.execution_context = context;
            self.scope_root = null;
            self.state.beginTransaction();
        }

        fn openTransactionAttemptScope(self: *Self, context: execution_values.ExecutionContext) !void {
            if (self.execution_context != null) return error.ActiveTransactionScope;
            if (self.checkpoint_top != 0) return error.ActiveExecutionCheckpoints;
            if (self.active_transaction_checkpoint_id == 0) return error.NoCurrentTransaction;
            if (self.attempt_execution_journal_start != null) return error.ActiveTransactionScope;
            self.execution_context = context;
            self.scope_root = null;
            self.attempt_execution_journal_start = self.state.beginExecutionScope();
        }

        fn closeTransactionAttemptScope(self: *Self) !void {
            if (self.execution_context == null) return;
            const journal_start = self.attempt_execution_journal_start orelse
                return error.MissingTransactionScope;
            try self.state.closeExecutionScope(journal_start);
            self.execution_context = null;
            self.scope_root = null;
            self.attempt_execution_journal_start = null;
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
            try self.openTransactionScope(context);
            errdefer self.closeTransaction();
            try warmTransactionAccesses(self, sender, recipient);
        }

        /// Open a manual create transaction scope.
        ///
        /// This is the create counterpart to `beginTransaction`; there is no recipient
        /// to warm before the create address is derived during execution.
        pub fn beginCreateTransaction(self: *Self, tx_context: Host.TxContext, sender: Address) !void {
            const context = context_adapter.fromHost(tx_context);
            try self.openTransactionScope(context);
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
            try self.beginMessageScopeContext(request.context, request.message, scope_init);
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

        /// Open only the rollback-armed transaction lifetime. Prelude execution
        /// scopes and the payload scope are sequenced beneath this attempt.
        pub fn beginTransactionAttemptLifetime(self: *Self) !TransactionAttempt {
            if (self.current_transaction_attempt != null or self.current_execution_lease != null)
                return error.TransactionAttemptActive;
            if (self.execution_context != null) return error.ActiveTransactionScope;
            if (self.checkpoint_top != 0) return error.ActiveExecutionCheckpoints;
            if (self.attempt_execution_journal_start != null) return error.ActiveTransactionScope;

            const checkpoint_value = try self.transactionCheckpoint();
            self.next_transaction_attempt_generation +%= 1;
            self.current_transaction_attempt = .{
                .checkpoint = checkpoint_value,
                .generation = self.next_transaction_attempt_generation,
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
        ) !void {
            try self.openTransactionScope(context);
            errdefer self.closeTransaction();

            try self.initializeMessageScope(message, scope_init);
        }

        fn beginMessageScopeInAttempt(
            self: *Self,
            request: execution_values.EvmExecutionRequest,
            scope_init: execution_values.ExecutionScopeInit,
        ) !void {
            try self.openTransactionAttemptScope(request.context);
            errdefer self.closeTransactionAttemptScope() catch {};

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
                const account_hint = std.math.add(
                    usize,
                    root_accounts,
                    initial_warm_set.accounts.len,
                ) catch return error.AccessCapacityTooLarge;
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

        fn beginSystemCall(self: *Self, tx_context: Host.TxContext) !void {
            try self.openTransactionScope(context_adapter.fromHost(tx_context));
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

        /// Return account metadata already present in the overlay.
        pub fn getAccount(self: *Self, address: Address) ?*AccountState {
            return self.state.getAccount(address);
        }

        /// Return account metadata, loading it from the state reader if needed.
        pub fn getAccountOrLoad(self: *Self, address: Address) !?*AccountState {
            return self.state.getAccountOrLoad(address);
        }

        /// Return account metadata, creating an empty record when none exists.
        pub fn getOrCreateAccount(self: *Self, address: Address) !*AccountState {
            return self.state.getOrCreateAccount(address);
        }

        /// Read storage through the overlay/state-reader view.
        pub fn getStorage(self: *Self, address: Address, key: u256) !u256 {
            return self.state.getStorage(address, key);
        }

        /// Read an account balance through the overlay/state-reader view.
        pub fn getBalance(self: *Self, address: Address) !u256 {
            return self.state.getBalance(address);
        }

        /// Add balance as a neutral family/STF state transition.
        pub fn addBalance(self: *Self, address: Address, value: u256) !void {
            try self.state.addBalance(address, value);
        }

        pub fn logs(self: *const Self) []const Host.Log {
            return self.state.getLogs();
        }

        pub fn clearLogs(self: *Self) void {
            self.state.clearLogs();
        }

        /// Capture a full overlay snapshot suitable for transaction rollback.
        pub fn snapshot(self: *Self) !Self.Snapshot {
            return self.state.snapshot();
        }

        pub fn traceSnapshotLifecycle(self: *Self, kind: trace.CheckpointKind, snapshot_state: *const Self.Snapshot) !void {
            try self.state.traceSnapshotLifecycle(kind, snapshot_state);
        }

        /// Open one journal-backed checkpoint inside the active execution scope.
        pub fn checkpoint(self: *Self) !ExecutionCheckpoint {
            try self.requireTransactionScope();
            const id = std.math.add(usize, self.next_checkpoint_id, 1) catch return error.CheckpointIdExhausted;
            const parent_id = self.checkpoint_top;
            const journal_checkpoint = try self.state.checkpoint();
            self.next_checkpoint_id = id;
            self.checkpoint_top = id;
            return .{
                .executor = self,
                .journal_checkpoint = journal_checkpoint,
                .id = id,
                .parent_id = parent_id,
            };
        }

        fn transactionCheckpoint(self: *Self) !TransactionCheckpoint {
            if (self.active_transaction_checkpoint_id != 0) return error.PendingTransactionActive;
            if (self.checkpoint_top != 0) return error.ActiveExecutionCheckpoints;
            const id = std.math.add(usize, self.next_transaction_checkpoint_id, 1) catch return error.CheckpointIdExhausted;
            const journal_checkpoint = try self.state.checkpoint();
            self.next_transaction_checkpoint_id = id;
            self.active_transaction_checkpoint_id = id;
            return .{
                .executor = self,
                .journal_checkpoint = journal_checkpoint,
                .id = id,
            };
        }

        fn openExecutionLease(
            self: *Self,
            transaction_checkpoint: TransactionCheckpoint,
        ) ExecutionLease {
            std.debug.assert(self.current_execution_lease == null);
            std.debug.assert(transaction_checkpoint.executor == self);
            std.debug.assert(transaction_checkpoint.open);
            self.next_execution_lease_generation +%= 1;
            self.current_execution_lease = .{
                .checkpoint = transaction_checkpoint,
                .generation = self.next_execution_lease_generation,
            };
            return .{
                .executor = self,
                .generation = self.next_execution_lease_generation,
            };
        }

        pub fn hasCurrentTransaction(self: *const Self) bool {
            return self.active_transaction_checkpoint_id != 0;
        }

        /// Restore the overlay to a previous full snapshot.
        pub fn restore(self: *Self, snapshot_state: *Self.Snapshot) !void {
            try self.state.restore(snapshot_state);
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

        pub fn hasChanges(self: *const Self) bool {
            return self.state.hasChanges();
        }

        /// Finalize state changes for the current transaction and close its context.
        pub fn commitTransaction(self: *Self) !void {
            if (self.checkpoint_top != 0) return error.ActiveExecutionCheckpoints;
            if (self.active_transaction_checkpoint_id != 0) return error.PendingTransactionActive;
            try self.finalizeTransactionState();
            self.closeTransaction();
        }

        fn finalizeTransactionState(self: *Self) !void {
            try self.state.finalizeTransaction(TransactionFinalizer{
                .revision = self.revision(),
            });
        }

        /// Restore from a snapshot and close the current transaction context.
        pub fn rollbackTransaction(self: *Self, snapshot_state: *Self.Snapshot) !void {
            if (self.checkpoint_top != 0) return error.ActiveExecutionCheckpoints;
            if (self.active_transaction_checkpoint_id != 0) return error.PendingTransactionActive;
            try self.restore(snapshot_state);
            self.closeTransaction();
        }

        /// Close the current transaction context without restoring overlay changes.
        pub fn closeTransaction(self: *Self) void {
            if (self.checkpoint_top != 0) @panic("cannot close a transaction scope while an execution checkpoint is open");
            if (self.active_transaction_checkpoint_id != 0) @panic("cannot close a transaction scope while its transaction checkpoint is open");
            if (self.execution_context == null) return;
            self.state.closeTransaction();
            self.execution_context = null;
            self.scope_root = null;
            self.attempt_execution_journal_start = null;
        }

        /// Close whichever execution scope belongs to a resolved transaction
        /// attempt, or clear an execution-less attempt's retained journal.
        fn closeTransactionLifetime(self: *Self) void {
            std.debug.assert(self.checkpoint_top == 0);
            std.debug.assert(self.active_transaction_checkpoint_id == 0);
            self.state.closeTransaction();
            self.execution_context = null;
            self.scope_root = null;
            self.attempt_execution_journal_start = null;
        }

        /// Return the pending overlay changes without committing them.
        pub fn changeset(self: *Self) !Changeset {
            if (self.active_transaction_checkpoint_id != 0) return error.PendingTransactionActive;
            return self.state.changeset();
        }

        /// Drop all pending overlay changes and clear any open transaction context.
        pub fn discardChanges(self: *Self) void {
            if (self.checkpoint_top != 0) @panic("cannot discard changes while an execution checkpoint is open");
            if (self.active_transaction_checkpoint_id != 0) @panic("cannot discard changes while a transaction is pending");
            self.state.discardChanges();
            self.execution_context = null;
            self.scope_root = null;
        }

        /// Read account code through the overlay/state-reader view.
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
            return switch (message) {
                .call => |call| runtime.executeCall(self, call, gas),
                .create => |create| runtime.executeCreate(self, create, gas),
            };
        }

        /// Compatibility adapter for one call/create message and flat host context.
        ///
        /// New integrations should prefer `runStandaloneRequest`, whose context is
        /// the authoritative concrete execution value.
        pub fn runStandalone(self: *Self, tx_context: Host.TxContext, message: Self.Message, gas: execution_values.ExecutionGas) !Self.EvmResult {
            return self.runStandaloneContext(context_adapter.fromHost(tx_context), message, gas, .{});
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
            return self.runStandaloneContext(request.context, request.message, request.gas, scope_init);
        }

        fn runStandaloneContext(
            self: *Self,
            context: execution_values.ExecutionContext,
            message: Self.Message,
            gas: execution_values.ExecutionGas,
            scope_init: execution_values.ExecutionScopeInit,
        ) !Self.EvmResult {
            try self.beginMessageScopeContext(context, message, scope_init);
            errdefer self.closeTransaction();

            var pre_execution = try self.checkpoint();
            defer pre_execution.deinit();

            const result = try self.executeMessage(message, gas);
            if (executionRolledBack(result.status())) {
                try pre_execution.restore();
                self.closeTransaction();
            } else {
                try self.finalizeTransactionState();
                try pre_execution.commit();
                self.closeTransaction();
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
        /// neutral fact needed by a family transaction coordinator to choose
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
            errdefer self.closeTransactionAttemptScope() catch {};
            self.scope_root = .fromMessage(request.message);

            var execution_checkpoint = try self.checkpoint();
            defer execution_checkpoint.deinit();
            const result = try self.executeTransactionRequestTrusted(request);
            if (executionRolledBack(result.status)) {
                try execution_checkpoint.restore();
                try self.closeTransactionAttemptScope();
            } else {
                try self.finalizeTransactionState();
                // Keep rollback armed until scope-local storage has been
                // promoted into the outer transaction journal. This also
                // leaves a caught allocation/capture error retry-safe.
                try self.closeTransactionAttemptScope();
                try execution_checkpoint.commit();
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
                .call => |call| try self.traceAccountAccess(call.recipient, 0),
                .create => |create| try self.traceAccountAccess(create.recipient, 0),
            }
            return switch (request.message) {
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
            gas: u64,
        ) !Interpreter.Result {
            self.beginPreparedCodeExecution();
            defer self.endPreparedCodeExecution();

            try self.beginSystemCall(tx_context);
            errdefer self.closeTransaction();

            self.clearLastOutput();
            const checkpoint_state = try self.state.checkpoint();
            var checkpoint_open = true;
            errdefer {
                if (checkpoint_open) self.state.revertToCheckpoint(checkpoint_state) catch {};
            }

            const resolved = try runtime.resolveCode(self, recipient);
            const bytecode = try runtime.resolveExecutionCodeView(self, try runtime.resolvedCodeView(self, resolved));
            var host_iface = self.host();
            try self.traceAccountAccess(recipient, 0);
            const message = Host.Message{
                .depth = 0,
                .kind = .call,
                .gas = std.math.cast(i64, gas) orelse std.math.maxInt(i64),
                .recipient = recipient,
                .sender = sender,
                .input_data = input,
                .value = 0,
                .code_address = recipient,
            };

            var frame = try runtime.acquireBytecodeFrame(self, self.allocator, &host_iface, &message, bytecode);
            defer frame.deinit();
            var interpreter = frame.interpreter(Protocol);
            var result = try runtime.executeInterpreter(self, &interpreter, message.depth);
            result.output_data = try self.setLastOutput(result.output_data);

            if (executionRolledBack(result.status)) {
                try self.state.revertToCheckpoint(checkpoint_state);
                checkpoint_open = false;
                self.closeTransaction();
            } else {
                try self.state.commitCheckpoint(checkpoint_state);
                checkpoint_open = false;
                try self.commitTransaction();
            }

            return .{
                .status = result.status,
                .gas_left = result.gas_left,
                .gas_refund = result.gas_refund,
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
            const account = try self.getOrCreateAccount(address);
            try self.state.setNonce(address, std.math.add(u64, account.nonce, 1) catch std.math.maxInt(u64));
        }

        /// Snapshot transient storage for nested execution rollback.
        pub fn snapshotTransient(self: *Self) !Self.TransientSnapshot {
            return self.state.snapshotTransient();
        }

        /// Restore transient storage from a previous snapshot.
        pub fn restoreTransient(self: *Self, snapshot_state: *Self.TransientSnapshot) !void {
            try self.state.restoreTransient(snapshot_state);
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
            return self.last_call_output.replace(output_data) catch |err| switch (err) {
                error.FrameIoCapacityExceeded => error.ResultOutputCapacityExceeded,
                else => err,
            };
        }

        pub fn assumeLastOutputWritten(self: *Self, len: usize) ![]u8 {
            return self.last_call_output.assumeWritten(len) catch |err| switch (err) {
                error.FrameIoCapacityExceeded => error.ResultOutputCapacityExceeded,
                else => err,
            };
        }
    };
}

const Default = Executor(EthProtocol);
const testTxContext = evmz.t.defaultTxContext;

test "executor init options retain code analysis config" {
    var executor = Default.init(std.testing.allocator, .{
        .revision = .latest,
        .config = .advanced,
    });
    defer executor.deinit();

    try std.testing.expectEqual(evmz.ExecutionConfig.Preprocessing.full, executor.config.preprocessing);
}

test "executor prepareBytecode honors jumpdest strategy config" {
    var executor = Default.init(std.testing.allocator, .{
        .revision = .latest,
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
    var executor = Default.init(std.testing.allocator, .{
        .revision = .osaka,
    });
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
    var executor = Default.init(std.testing.allocator, .{
        .revision = .osaka,
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
    var executor = Default.init(std.testing.allocator, .{
        .revision = .osaka,
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

    fn sink(self: *@This()) trace.Sink {
        return trace.Sink.init(self, .{
            .step_start = trace.StepStartFields.initMany(&.{.opcode}),
        }, &.{ .stepStart = stepStart });
    }

    fn stepStart(ptr: *anyopaque, event: trace.StepStart) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        _ = event;
        if (self.replay_cleared) return;
        self.pool.clearRetainingCapacity() catch |err| @panic(@errorName(err));
        self.replay_cleared = true;
    }
};

test "trace replay runs after prepared code leaves the live frame" {
    const sender = evmz.addr(0xaaaa);
    const contract = evmz.addr(0xbbbb);
    const code = evmz.t.bytecode(.{.STOP});

    var pool = evmz.prepared_code.InMemoryPreparedPool.init(std.testing.allocator);
    defer pool.deinit();
    var executor = Default.init(std.testing.allocator, .{
        .revision = .osaka,
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
    var sink = recorder.sink();
    var tape = trace.TraceTape.initGrowable(std.testing.allocator);
    defer tape.deinit();
    var capture = CaptureContext.init(std.testing.allocator, .{ .tape = &tape }, null);
    defer capture.deinit();
    executor.setCaptureContext(&capture);
    try capture.begin();
    var capture_open = true;
    defer {
        if (capture_open) capture.abort() catch {};
        executor.setCaptureContext(null);
    }

    try executor.beginTransaction(testTxContext(sender, 100_000), sender, contract);
    const result = try executor.executeCallTransaction(sender, contract, &.{}, .legacy(100_000), 0);
    executor.closeTransaction();

    const span = (try capture.finish()).?;
    capture_open = false;
    try trace.replaySteps(&sink, span);
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
    var executor = Default.init(std.testing.allocator, .{
        .revision = .osaka,
        .config = .base,
        .prepared_code_backend = pool.backend(),
    });
    defer executor.deinit();

    const prepared = try pool.getOrPrepare(executor.preparedCodeKey(), code_hash, &code);
    try executor.reset(.{
        .revision = .osaka,
        .config = .base,
        .prepared_code_backend = pool.backend(),
    });
    try std.testing.expectEqual(prepared, pool.get(executor.preparedCodeKey(), code_hash).?);

    try executor.reset(.{
        .revision = .osaka,
        .config = .advanced,
        .prepared_code_backend = pool.backend(),
    });
    const advanced = try pool.getOrPrepare(executor.preparedCodeKey(), code_hash, &code);
    try std.testing.expect(advanced != prepared);
    try std.testing.expectEqual(@as(usize, 2), pool.count());
}

test "bounded cached jump executes without persistent allocation" {
    const sender = evmz.addr(0xaaaa);
    const contract = evmz.addr(0xbbbb);
    const code = evmz.t.bytecode(.{
        .PUSH1, 0x03,
        .JUMP,  .JUMPDEST,
        .STOP,
    });

    var failing_allocator = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var pool = evmz.prepared_code.InMemoryPreparedPool.init(failing_allocator.allocator());
    defer pool.deinit();
    var executor = try Default.initWithRuntimeResources(failing_allocator.allocator(), .{
        .revision = .osaka,
        .prepared_code_backend = pool.backend(),
    }, .{ .bounded = .{
        .max_live_frames = 1,
        .memory_bytes_per_frame = 0,
        .io_bytes_per_frame = 0,
        .scratch_bytes_per_frame = 0,
        .result_bytes = 0,
    } });
    defer executor.deinit();

    var sender_account = MemoryAccount.init(failing_allocator.allocator());
    sender_account.balance = 1_000_000;
    try executor.state.seedAccount(sender, sender_account);

    var contract_account = MemoryAccount.init(failing_allocator.allocator());
    try contract_account.setCode(&code);
    try executor.state.seedAccount(contract, contract_account);

    const code_view = try executor.state.getCodeView(contract);
    const prepared = try pool.getOrPrepare(executor.preparedCodeKey(), code_view.code_hash, code_view.bytes);
    try std.testing.expect(prepared.jumpdests.analyzed);

    try executor.beginTransaction(testTxContext(sender, 100_000), sender, contract);
    failing_allocator.fail_index = failing_allocator.alloc_index;
    const result = try executor.executePreparedCallTransaction(.{
        .bytecode = prepared,
        .sender = sender,
        .recipient = contract,
        .gas = 100_000,
    });
    executor.closeTransaction();

    try std.testing.expectEqual(Interpreter.Status.success, result.status);
    try std.testing.expect(!failing_allocator.has_induced_failure);
}

test "cached child execution succeeds without transient preparation capacity" {
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
        .PUSH0,  .SLOAD,
        .PUSH1,  0x01,
        .ADD,    .PUSH0,
        .SSTORE, .STOP,
    });

    var pool = evmz.prepared_code.InMemoryPreparedPool.init(std.testing.allocator);
    defer pool.deinit();
    var executor = try Default.initWithRuntimeResources(std.testing.allocator, .{
        .revision = .osaka,
        .prepared_code_backend = pool.backend(),
    }, .{ .bounded = .{
        .max_live_frames = 2,
        .memory_bytes_per_frame = 0,
        .io_bytes_per_frame = 0,
        .scratch_bytes_per_frame = 0,
        .prepared_code_bytes_per_execution = 0,
        .result_bytes = 0,
    } });
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

    var root_bytecode = try executor.prepareBytecode(&contract_code);
    defer root_bytecode.deinit(std.testing.allocator);

    // Negative control: an uncached child must prepare an immutable artifact,
    // but this execution reserves no transient preparation storage.
    try executor.beginTransaction(tx_context, sender, contract);
    try std.testing.expectError(error.PreparedCodeCapacityExceeded, executor.executePreparedCallTransaction(.{
        .bytecode = &root_bytecode,
        .sender = sender,
        .recipient = contract,
        .gas = 100_000,
    }));
    executor.closeTransaction();

    // Explicit setup admission is allowed outside execution even though lazy
    // admission is disabled for the bounded runtime envelope.
    const target_view = try executor.state.getCodeView(target);
    _ = try pool.getOrPrepare(executor.preparedCodeKey(), target_view.code_hash, target_view.bytes);

    for (0..2) |_| {
        try executor.beginTransaction(tx_context, sender, contract);
        const result = try executor.executePreparedCallTransaction(.{
            .bytecode = &root_bytecode,
            .sender = sender,
            .recipient = contract,
            .gas = 100_000,
        });
        try std.testing.expectEqual(Interpreter.Status.success, result.status);
        executor.closeTransaction();
    }
    try std.testing.expectEqual(@as(u256, 2), try executor.getStorage(target, 0));
}

test "prepared execution follows current code hash without owning public code reads" {
    const contract = evmz.addr(0xc0de);
    const original_code = evmz.t.bytecode(.{ .PUSH0, .STOP });
    const replacement_code = evmz.t.bytecode(.{ .PUSH1, 0x2a, .STOP });

    var pool = evmz.prepared_code.InMemoryPreparedPool.init(std.testing.allocator);
    defer pool.deinit();
    var executor = Default.init(std.testing.allocator, .{
        .revision = .osaka,
        .prepared_code_backend = pool.backend(),
    });
    defer executor.deinit();

    var account = MemoryAccount.init(std.testing.allocator);
    try account.setCode(&original_code);
    try executor.state.seedAccount(contract, account);

    executor.beginPreparedCodeExecution();
    var prepared_execution_open = true;
    errdefer if (prepared_execution_open) executor.endPreparedCodeExecution();
    const original_execution = try call_runtime.For(Default).resolveExecutionCode(&executor, contract);
    const original_prepared = original_execution;
    const public_original = try executor.getCode(contract);
    try std.testing.expect(original_prepared.bytes.ptr != public_original.ptr);
    try std.testing.expectEqualSlices(u8, &original_code, public_original);

    try executor.state.setCode(contract, &replacement_code);
    const replacement_execution = try call_runtime.For(Default).resolveExecutionCode(&executor, contract);
    try std.testing.expect(replacement_execution != original_prepared);
    try std.testing.expectEqualSlices(u8, &replacement_code, replacement_execution.bytes);
    const public_replacement = try executor.getCode(contract);
    try std.testing.expectEqualSlices(u8, &replacement_code, public_replacement);

    executor.endPreparedCodeExecution();
    prepared_execution_open = false;
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
    var executor = Default.init(std.testing.allocator, .{
        .revision = .osaka,
        .state_reader = witness.reader(),
        .prepared_code_backend = pool.backend(),
    });
    defer executor.deinit();

    _ = try pool.getOrPrepare(executor.preparedCodeKey(), code_hash, &code);
    try std.testing.expect(pool.get(executor.preparedCodeKey(), code_hash) != null);
    try std.testing.expectError(
        error.InvalidWitness,
        call_runtime.For(Default).resolveExecutionCode(&executor, target),
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
    var executor = Default.init(std.testing.allocator, .{
        .revision = .prague,
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
    var executor = Default.init(std.testing.allocator, .{
        .revision = .osaka,
    });
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

test "executor carries comptime protocol through nested host calls" {
    const IstanbulProtocol = evmz.eth.fork(.istanbul).ExecutionProtocol;

    const default_gas_left = try executeNestedBalanceCall(EthProtocol, .istanbul);
    const istanbul_gas_left = try executeNestedBalanceCall(IstanbulProtocol, .istanbul);

    try std.testing.expectEqual(default_gas_left, istanbul_gas_left);
}

fn ethereumProtocolWith(comptime definition_name: []const u8, comptime overrides: evmz.eth.ExecutionOptions(evmz.eth.Revision)) type {
    comptime var options = overrides;
    options.name = definition_name;
    const custom_definition = comptime evmz.eth.defineExecution(options);
    const CustomDefinition = evmz.definition.BoundExecution(custom_definition);
    return evmz.protocol.ExecutionProtocol(custom_definition, CustomDefinition.Support.all);
}

test "protocol definition drives call base gas" {
    const overrides = struct {
        fn callBaseGas(revision_value: evmz.eth.Revision) i64 {
            return evmz.eth.system.Call.callBaseGas(revision_value) + 5;
        }
    };
    const ExpensiveCallProtocol = ethereumProtocolWith("expensive-call-base", .{
        .call = .{ .callBaseGas = overrides.callBaseGas },
    });

    const default_gas_left = try executeNestedBalanceCall(EthProtocol, .frontier);
    const custom_gas_left = try executeNestedBalanceCall(ExpensiveCallProtocol, .frontier);

    try std.testing.expectEqual(default_gas_left - 5, custom_gas_left);
}

test "protocol definition drives top-level delegated account access" {
    const overrides = struct {
        fn topLevelDelegatedAccountAccess(
            revision_value: evmz.eth.Revision,
            input: evmz.protocol.TopLevelDelegatedAccountAccessInput,
        ) ?evmz.protocol.DelegatedAccountAccess {
            _ = revision_value;
            _ = input;
            return .{ .status = .cold, .gas = 7 };
        }
    };
    const ExpensiveTopLevelDelegatedAccessProtocol = ethereumProtocolWith("expensive-top-level-delegated-access", .{
        .call = .{ .topLevelDelegatedAccountAccess = overrides.topLevelDelegatedAccountAccess },
    });

    const default_gas_left = try executeTopLevelDelegatedCall(EthProtocol);
    const custom_gas_left = try executeTopLevelDelegatedCall(ExpensiveTopLevelDelegatedAccessProtocol);

    try std.testing.expectEqual(default_gas_left - 7, custom_gas_left);
}

test "top-level call code resolution reuses one traced view" {
    const sender = evmz.addr(0x1111);
    const recipient = evmz.addr(0x2222);
    var recorder = CodeReadRecorder{};
    var sink = recorder.sink();
    var executor = Default.init(std.testing.allocator, .{
        .revision = .prague,
    });
    defer executor.deinit();
    try putFundedSender(&executor, sender);

    var recipient_account = MemoryAccount.init(std.testing.allocator);
    try recipient_account.setCode(&.{evmz.Opcode.STOP.toByte()});
    try executor.state.seedAccount(recipient, recipient_account);
    var capture: TestCapture(Default) = undefined;
    try capture.initSink(&executor, &sink);
    defer capture.deinit();

    const result = (try executor.runStandalone(testTxContext(sender, 100_000), .{ .call = .{
        .sender = sender,
        .recipient = recipient,
    } }, .legacy(100_000))).expectCall();
    try capture.finish();

    try std.testing.expectEqual(Interpreter.Status.success, result.status);
    try std.testing.expectEqual(@as(usize, 1), recorder.count);
    try std.testing.expectEqualSlices(u8, &recipient, &recorder.last_address.?);
}

test "top-level delegated access failure does not read target code" {
    const overrides = struct {
        fn topLevelDelegatedAccountAccess(
            revision_value: evmz.eth.Revision,
            input: evmz.protocol.TopLevelDelegatedAccountAccessInput,
        ) ?evmz.protocol.DelegatedAccountAccess {
            _ = revision_value;
            _ = input;
            return .{ .status = .cold, .gas = 100_001 };
        }
    };
    const ExpensiveTopLevelDelegatedAccessProtocol = ethereumProtocolWith("delegated-access-exceeds-call-gas", .{
        .call = .{ .topLevelDelegatedAccountAccess = overrides.topLevelDelegatedAccountAccess },
    });
    const ExpensiveExecutor = Executor(ExpensiveTopLevelDelegatedAccessProtocol);
    const sender = evmz.addr(0x1111);
    const authority = evmz.addr(0x2222);
    const target = evmz.addr(0x3333);
    var recorder = CodeReadRecorder{};
    var sink = recorder.sink();
    var executor = ExpensiveExecutor.init(std.testing.allocator, .{
        .revision = .prague,
    });
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
    var capture: TestCapture(ExpensiveExecutor) = undefined;
    try capture.initSink(&executor, &sink);
    defer capture.deinit();

    const result = (try executor.runStandalone(testTxContext(sender, 100_000), .{ .call = .{
        .sender = sender,
        .recipient = authority,
    } }, .legacy(100_000))).expectCall();
    try capture.finish();

    try std.testing.expectEqual(Interpreter.Status.out_of_gas, result.status);
    try std.testing.expectEqual(@as(usize, 1), recorder.count);
    try std.testing.expectEqualSlices(u8, &authority, &recorder.last_address.?);
}

test "protocol definition drives top-frame value transfer state gas" {
    const overrides = struct {
        fn topFrameValueTransferStateGas(
            revision_value: evmz.eth.Revision,
            input: evmz.protocol.TopFrameValueTransferInput,
        ) i64 {
            _ = revision_value;
            return if (input.creates_account) 9 else 0;
        }
    };
    const ExpensiveTopFrameValueTransferProtocol = ethereumProtocolWith("expensive-top-frame-value-transfer", .{
        .call = .{ .topFrameValueTransferStateGas = overrides.topFrameValueTransferStateGas },
    });

    const default_result = try executeTopFrameValueTransfer(EthProtocol);
    const custom_result = try executeTopFrameValueTransfer(ExpensiveTopFrameValueTransferProtocol);

    try std.testing.expectEqual(default_result.gas_left - 9, custom_result.gas_left);
    try std.testing.expectEqual(@as(i64, 9), custom_result.state_gas_spent);
    try std.testing.expectEqual(@as(i64, 9), custom_result.state_gas_from_gas_left);
}

test "protocol definition drives empty call recipient touching" {
    const overrides = struct {
        fn touchesEmptyCallRecipient(revision_value: evmz.eth.Revision) bool {
            _ = revision_value;
            return true;
        }
    };
    const TouchEmptyCallRecipientProtocol = ethereumProtocolWith("touch-empty-call-recipient", .{
        .call = .{ .touchesEmptyCallRecipient = overrides.touchesEmptyCallRecipient },
    });

    try std.testing.expect(!try emptyCallRecipientMaterialized(EthProtocol));
    try std.testing.expect(try emptyCallRecipientMaterialized(TouchEmptyCallRecipientProtocol));
}

test "protocol definition drives child call gas forwarding" {
    const overrides = struct {
        fn childGas(revision_value: evmz.eth.Revision, input: evmz.protocol.ChildGasInput) evmz.protocol.ChildGas {
            _ = revision_value;
            _ = input;
            return .{ .gas = 0 };
        }
    };
    const ZeroChildGasProtocol = ethereumProtocolWith("zero-child-gas", .{
        .call = .{ .childGas = overrides.childGas },
    });

    try std.testing.expectEqual(@as(u256, 1), try executeCallResultStore(EthProtocol));
    try std.testing.expectEqual(@as(u256, 0), try executeCallResultStore(ZeroChildGasProtocol));
}

test "protocol definition drives create initcode word gas" {
    const overrides = struct {
        fn createInitCodeWordGas(revision_value: evmz.eth.Revision, is_create2: bool) i64 {
            _ = revision_value;
            _ = is_create2;
            return 1_000_000;
        }
    };
    const ExpensiveCreateInitCodeProtocol = ethereumProtocolWith("expensive-create-initcode", .{
        .create = .{ .createInitCodeWordGas = overrides.createInitCodeWordGas },
    });

    try std.testing.expectEqual(Interpreter.Status.success, try executeCreateOpcodeStatus(EthProtocol));
    try std.testing.expectEqual(Interpreter.Status.out_of_gas, try executeCreateOpcodeStatus(ExpensiveCreateInitCodeProtocol));
}

fn executeCreateOpcodeStatus(comptime Protocol: type) !Interpreter.Status {
    const sender = evmz.addr(0x1111);
    const contract = evmz.addr(0xaaaa);
    const code = evmz.t.bytecode(.{
        .PUSH7, 0x36,    .PUSH0, .MSTORE8, 0x60,   0x01, .PUSH0, .RETURN,
        .PUSH0, .MSTORE, .PUSH1, 0x07,     .PUSH1, 0x19, .PUSH0, .CREATE,
        .STOP,
    });

    const Exec = Executor(Protocol);
    var executor = Exec.init(std.testing.allocator, .{
        .revision = .cancun,
    });
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

fn executeCallResultStore(comptime Protocol: type) !u256 {
    const sender = evmz.addr(0x1111);
    const parent = evmz.addr(0xaaaa);
    const target = evmz.addr(0xbbbb);
    const Exec = Executor(Protocol);
    var executor = Exec.init(std.testing.allocator, .{
        .revision = .frontier,
    });
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

fn executeTopLevelDelegatedCall(comptime Protocol: type) !i64 {
    const sender = evmz.addr(0x1111);
    const authority = evmz.addr(0x2222);
    const target = evmz.addr(0x3333);
    const tx_context = testTxContext(sender, 100_000);

    const Exec = Executor(Protocol);
    var executor = Exec.init(std.testing.allocator, .{
        .revision = .prague,
    });
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

const CodeReadRecorder = struct {
    count: usize = 0,
    last_address: ?Address = null,

    fn sink(self: *CodeReadRecorder) trace.Sink {
        return trace.Sink.init(self, .{
            .state_read = trace.StateReadKinds.initMany(&.{.code}),
        }, &.{ .stateRead = stateRead });
    }

    fn stateRead(ptr: *anyopaque, event: trace.StateRead) void {
        const self: *CodeReadRecorder = @ptrCast(@alignCast(ptr));
        switch (event) {
            .code => |read| {
                self.count += 1;
                self.last_address = read.address;
            },
            else => {},
        }
    }
};

const TopFrameValueTransferResult = struct {
    gas_left: i64,
    state_gas_spent: i64,
    state_gas_from_gas_left: i64,
};

fn executeTopFrameValueTransfer(comptime Protocol: type) !TopFrameValueTransferResult {
    const sender = evmz.addr(0x1111);
    const recipient = evmz.addr(0x2222);
    const tx_context = testTxContext(sender, 100_000);

    const Exec = Executor(Protocol);
    var executor = Exec.init(std.testing.allocator, .{
        .revision = .prague,
    });
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

fn emptyCallRecipientMaterialized(comptime Protocol: type) !bool {
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

    const Exec = Executor(Protocol);
    var executor = Exec.init(std.testing.allocator, .{
        .revision = .spurious_dragon,
    });
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

fn executeNestedBalanceCall(comptime Protocol: type, revision_value: Protocol.Revision) !i64 {
    const sender = evmz.addr(0x1111);
    const parent = evmz.addr(0xaaaa);
    const target = evmz.addr(0xbbbb);
    var executor = Executor(Protocol).init(std.testing.allocator, .{
        .revision = revision_value,
    });
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
    var executor = Default.init(std.testing.allocator, .{
        .revision = .cancun,
    });
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
    var executor = Default.init(std.testing.allocator, .{
        .revision = .cancun,
    });
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
    var executor = Default.init(std.testing.allocator, .{
        .revision = .cancun,
    });
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
    const cases = [_]struct {
        revision: evmz.eth.Revision,
        materialized: bool,
        gas_left: i64,
    }{
        .{ .revision = .frontier, .materialized = true, .gas_left = 64_922 },
        .{ .revision = .spurious_dragon, .materialized = false, .gas_left = 89_262 },
    };

    for (cases) |case| {
        const tx_context = testTxContext(sender, 100_000);
        var executor = Default.init(std.testing.allocator, .{
            .revision = case.revision,
        });
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
        try std.testing.expectEqual(case.gas_left, result.gas_left);
        try std.testing.expectEqual(case.materialized, executor.getAccount(precompile) != null);
    }
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

    var executor = Default.init(std.testing.allocator, .{
        .revision = .cancun,
    });
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

    var executor = Default.init(std.testing.allocator, .{
        .revision = .cancun,
    });
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

    var executor = Default.init(std.testing.allocator, .{
        .revision = .cancun,
    });
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

    var executor = Default.init(std.testing.allocator, .{
        .revision = .cancun,
    });
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

    _ = try executor.state.setStorage(contract, 1, 0x99);

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

    var executor = Default.init(std.testing.allocator, .{
        .revision = .cancun,
    });
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

    var executor = Default.init(std.testing.allocator, .{
        .revision = .cancun,
    });
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
    try std.testing.expect(!executor.state.warm_accounts.contains(create2_address));
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
    var capture = CaptureContext.init(std.testing.allocator, .{ .tape = &tape }, null);
    defer capture.deinit();
    var executor = Default.init(std.testing.allocator, .{ .revision = .cancun });
    defer executor.deinit();
    executor.setCaptureContext(&capture);
    defer executor.setCaptureContext(null);

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

    try executor.beginTransaction(tx_context, sender, contract);
    try capture.begin();
    errdefer capture.abort() catch {};
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
    var replay_sink = replay.sink();
    try trace.replaySteps(&replay_sink, span);
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
    var executor = Default.init(std.testing.allocator, .{ .revision = .osaka });
    defer executor.deinit();

    var sender_account = MemoryAccount.init(std.testing.allocator);
    sender_account.balance = 1_000_000;
    try executor.state.seedAccount(sender, sender_account);
    var contract_account = MemoryAccount.init(std.testing.allocator);
    try contract_account.setCode(&.{ 0x60, 0x2a, 0x5f, 0x55, 0x00 });
    try executor.state.seedAccount(contract, contract_account);

    var tape = trace.TraceTape.initGrowable(std.testing.allocator);
    defer tape.deinit();
    var capture = CaptureContext.init(std.testing.allocator, .{ .tape = &tape }, null);
    defer capture.deinit();
    executor.setCaptureContext(&capture);
    defer executor.setCaptureContext(null);

    const request_value = execution_values.EvmExecutionRequest{
        .context = context_adapter.fromHost(tx_context),
        .message = .{ .call = .{
            .sender = sender,
            .recipient = contract,
        } },
        .gas = .legacy(100_000),
    };
    const attempt = try executor.beginTransactionAttempt(request_value, .{});
    defer attempt.discardIfCurrent();
    try capture.begin();
    const result = try attempt.executeRequest(request_value);
    try std.testing.expectEqual(Interpreter.Status.success, result.status);
    var executed = try attempt.completeLease();
    defer executed.deinit();

    const span = (try capture.finish()).?;
    try std.testing.expect(span.steps.len > 0);
    try std.testing.expectEqual(@as(u8, @intFromEnum(evmz.Opcode.SSTORE)), span.steps[2].opcode);
    try std.testing.expectEqual(@as(u256, 0x2a), try executor.getStorage(contract, 0));

    try executed.discard();
    try std.testing.expectEqual(@as(u256, 0), try executor.getStorage(contract, 0));
    try tape.resolve(span);
}

test "transaction attempt owns rollback before executed lease" {
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
    var executor = Default.init(std.testing.allocator, .{ .revision = .cancun });
    defer executor.deinit();

    const first = try executor.beginTransactionAttempt(request, .{});
    const stale = first;
    try first.addBalance(sender, 9);
    try std.testing.expectEqual(@as(u256, 9), try first.balance(sender));

    try first.discard();
    try std.testing.expectEqual(@as(u256, 0), try executor.getBalance(sender));
    try std.testing.expect(!executor.hasCurrentTransaction());

    const second = try executor.beginTransactionAttempt(request, .{});
    defer second.discardIfCurrent();
    try std.testing.expectError(error.StaleTransactionExecution, stale.balance(sender));
}

test "transaction attempt completes into existing executed lease" {
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
    var executor = Default.init(std.testing.allocator, .{ .revision = .cancun });
    defer executor.deinit();

    const attempt = try executor.beginTransactionAttempt(request, .{});
    try attempt.addBalance(sender, 7);
    const executed = try attempt.completeLease();
    try std.testing.expectError(error.NoCurrentTransaction, attempt.balance(sender));
    try executed.retain();
    try std.testing.expectEqual(@as(u256, 7), try executor.getBalance(sender));
    try std.testing.expect(!executor.hasCurrentTransaction());
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
        var executor = Default.init(std.testing.allocator, .{ .revision = .cancun });
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
        const executed = try attempt.completeLease();
        try executed.retain();
        try std.testing.expectEqual(@as(u256, 12), try executor.getBalance(sender));
    }

    {
        var executor = Default.init(std.testing.allocator, .{ .revision = .cancun });
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
        const executed = try attempt.completeLease();
        try executed.retain();
        try std.testing.expectEqual(@as(u256, 0x2a), try executor.getStorage(contract, 0));
    }
}

test "top-level transaction execution requires begin tx context" {
    var executor = Default.init(std.testing.allocator, .{
        .revision = .berlin,
    });
    defer executor.deinit();

    try std.testing.expectError(
        error.MissingTxContext,
        executor.executeCallTransaction(evmz.addr(0xaaaa), evmz.addr(0xbbbb), &.{}, .legacy(100_000), 0),
    );
    var amsterdam_executor = Default.init(std.testing.allocator, .{
        .revision = .amsterdam,
    });
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

test "rollback transaction restores snapshot and closes tx context" {
    const sender = evmz.addr(0xaaaa);
    const contract = evmz.addr(0xbbbb);
    const tx_context = testTxContext(sender, 100_000);
    var executor = Default.init(std.testing.allocator, .{
        .revision = .berlin,
    });
    defer executor.deinit();

    _ = try executor.getOrCreateAccount(contract);

    try executor.beginTransaction(tx_context, sender, contract);
    var pre_execution = try executor.snapshot();
    defer pre_execution.deinit(std.testing.allocator);

    try std.testing.expectEqual(Host.StorageStatus.added, try executor.state.setStorage(contract, 7, 2));
    try std.testing.expectEqual(@as(u256, 2), try executor.getStorage(contract, 7));

    try executor.rollbackTransaction(&pre_execution);

    try std.testing.expectEqual(@as(u256, 0), try executor.getStorage(contract, 7));
    try std.testing.expectEqual(@as(usize, 0), executor.state.journal.len());
    try std.testing.expect(executor.execution_context == null);
}

test "executor executes top-level create transaction" {
    const sender = evmz.addr(0xaaaa);
    const tx_context = testTxContext(sender, 100_000);
    var executor = Default.init(std.testing.allocator, .{
        .revision = .berlin,
    });
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
    var executor = Default.init(std.testing.allocator, .{
        .revision = .amsterdam,
    });
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
    try std.testing.expectEqual(@as(usize, 1), executor.logs().len);
    try expectTransferLog(executor.logs()[0], sender, recipient, 7);
}

test "Osaka value transaction does not emit transfer log" {
    const sender = evmz.addr(0xaaaa);
    const recipient = evmz.addr(0xbbbb);
    var executor = Default.init(std.testing.allocator, .{
        .revision = .osaka,
    });
    defer executor.deinit();

    var sender_account = MemoryAccount.init(std.testing.allocator);
    sender_account.balance = 1_000_000;
    try executor.state.seedAccount(sender, sender_account);

    try executor.beginTransaction(testTxContext(sender, 100_000), sender, recipient);
    const result = try executor.executeCallTransaction(sender, recipient, &.{}, .legacy(50_000), 7);

    try std.testing.expectEqual(Interpreter.Status.success, result.status);
    try std.testing.expectEqual(@as(usize, 0), executor.logs().len);
}

test "Amsterdam nested CALL transfer log rolls back on revert" {
    const sender = evmz.addr(0xaaaa);
    const contract = evmz.addr(0xbbbb);
    const recipient = evmz.addr(0xcccc);
    const code = evmz.t.bytecode(.{
        .PUSH0, .PUSH0, .PUSH0,  .PUSH0, .PUSH1, 0x07, .PUSH2, 0xcc, 0xcc, .PUSH2, 0x27, 0x10, .CALL,
        .PUSH0, .PUSH0, .REVERT,
    });

    var executor = Default.init(std.testing.allocator, .{
        .revision = .amsterdam,
    });
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
    try std.testing.expectEqual(@as(usize, 0), executor.logs().len);
    try std.testing.expectEqual(@as(u256, 0), try executor.state.getBalance(recipient));
}

test "Amsterdam CREATE endowment emits transfer log" {
    const sender = evmz.addr(0xaaaa);
    const contract = evmz.addr(0xbbbb);
    const create_address = evmz.address.create(contract, 0);
    const code = evmz.t.bytecode(.{
        .PUSH1, 0x00, .PUSH1, 0x00, .PUSH1, 0x07, .CREATE, .POP, .STOP,
    });

    var executor = Default.init(std.testing.allocator, .{
        .revision = .amsterdam,
    });
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
    try std.testing.expectEqual(@as(usize, 1), executor.logs().len);
    try expectTransferLog(executor.logs()[0], contract, create_address, 7);
}

test "Amsterdam SELFDESTRUCT transfer emits transfer log" {
    const sender = evmz.addr(0xaaaa);
    const contract = evmz.addr(0xbbbb);
    const beneficiary = evmz.addr(0xcccc);
    const code = evmz.t.bytecode(.{ .PUSH2, 0xcc, 0xcc, .SELFDESTRUCT });

    var executor = Default.init(std.testing.allocator, .{
        .revision = .amsterdam,
    });
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
    try std.testing.expectEqual(@as(usize, 1), executor.logs().len);
    try expectTransferLog(executor.logs()[0], contract, beneficiary, 7);
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
    const default_max_code_size = evmz.eth.system.Create.max_code_size;
    const oversized_osaka = initCodeReturningRuntimeSize(default_max_code_size + 1);
    const oversized_amsterdam = initCodeReturningRuntimeSize(evmz.eth.system.Create.amsterdam_max_code_size + 1);

    var osaka = Default.init(std.testing.allocator, .{
        .revision = .osaka,
    });
    defer osaka.deinit();
    try putFundedSender(&osaka, sender);

    const osaka_result = (try osaka.runStandalone(tx_context, .{ .create = .{
        .sender = sender,
        .recipient = evmz.address.create(sender, 0),
        .init_code = &oversized_osaka,
    } }, .legacy(20_000_000))).expectCreate();
    try std.testing.expectEqual(Interpreter.Status.out_of_gas, osaka_result.status);

    var amsterdam = Default.init(std.testing.allocator, .{
        .revision = .amsterdam,
    });
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

    var amsterdam_over = Default.init(std.testing.allocator, .{
        .revision = .amsterdam,
    });
    defer amsterdam_over.deinit();
    try putFundedSender(&amsterdam_over, sender);

    const amsterdam_over_result = (try amsterdam_over.runStandalone(tx_context, .{ .create = .{
        .sender = sender,
        .recipient = evmz.address.create(sender, 0),
        .init_code = &oversized_amsterdam,
    } }, .legacy(20_000_000))).expectCreate();
    try std.testing.expectEqual(Interpreter.Status.out_of_gas, amsterdam_over_result.status);
}

test "protocol definition drives create runtime code size limit" {
    const overrides = struct {
        fn createCodeSizeLimit(revision_value: evmz.eth.Revision) ?usize {
            _ = revision_value;
            return 1;
        }
    };
    const TinyProtocol = ethereumProtocolWith("tiny-code-limit", .{
        .create = .{ .createCodeSizeLimit = overrides.createCodeSizeLimit },
    });
    const sender = evmz.addr(0xaaaa);
    const tx_context = testTxContext(sender, 100_000);
    const two_byte_runtime = initCodeReturningRuntimeSize(2);

    const TinyExecutor = Executor(TinyProtocol);
    var executor = TinyExecutor.init(std.testing.allocator, .{
        .revision = .shanghai,
    });
    defer executor.deinit();
    try putFundedSender(&executor, sender);

    const result = (try executor.runStandalone(tx_context, .{ .create = .{
        .sender = sender,
        .recipient = evmz.address.create(sender, 0),
        .init_code = &two_byte_runtime,
    } }, .legacy(100_000))).expectCreate();
    try std.testing.expectEqual(Interpreter.Status.out_of_gas, result.status);
}

test "protocol definition drives create runtime prefix rejection" {
    const overrides = struct {
        fn rejectsCreateCode(revision_value: evmz.eth.Revision, code: []const u8) bool {
            _ = revision_value;
            _ = code;
            return false;
        }
    };
    const AllowEfProtocol = ethereumProtocolWith("allow-ef-create-code", .{
        .create = .{ .rejectsCreateCode = overrides.rejectsCreateCode },
    });
    const sender = evmz.addr(0xaaaa);
    const tx_context = testTxContext(sender, 100_000);
    const init_code = evmz.t.bytecode(.{
        .PUSH1, 0xef, .PUSH0, .MSTORE8,
        .PUSH1, 0x01, .PUSH0, .RETURN,
    });

    var default_executor = Default.init(std.testing.allocator, .{
        .revision = .shanghai,
    });
    defer default_executor.deinit();
    try putFundedSender(&default_executor, sender);

    const default_result = (try default_executor.runStandalone(tx_context, .{ .create = .{
        .sender = sender,
        .recipient = evmz.address.create(sender, 0),
        .init_code = &init_code,
    } }, .legacy(100_000))).expectCreate();
    try std.testing.expectEqual(Interpreter.Status.invalid, default_result.status);

    const AllowEfExecutor = Executor(AllowEfProtocol);
    var custom_executor = AllowEfExecutor.init(std.testing.allocator, .{
        .revision = .shanghai,
    });
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

test "protocol definition drives create deposit gas" {
    const overrides = struct {
        fn createDepositRegularGas(revision_value: evmz.eth.Revision, runtime_size: i64) ?i64 {
            _ = revision_value;
            _ = runtime_size;
            return 1_000_000;
        }
    };
    const ExpensiveDepositProtocol = ethereumProtocolWith("expensive-create-deposit", .{
        .create = .{ .createDepositRegularGas = overrides.createDepositRegularGas },
    });
    const sender = evmz.addr(0xaaaa);
    const tx_context = testTxContext(sender, 100_000);
    const init_code = initCodeReturningRuntimeSize(1);

    var default_executor = Default.init(std.testing.allocator, .{
        .revision = .shanghai,
    });
    defer default_executor.deinit();
    try putFundedSender(&default_executor, sender);

    const default_result = (try default_executor.runStandalone(tx_context, .{ .create = .{
        .sender = sender,
        .recipient = evmz.address.create(sender, 0),
        .init_code = &init_code,
    } }, .legacy(100_000))).expectCreate();
    try std.testing.expectEqual(Interpreter.Status.success, default_result.status);
    try std.testing.expectEqual(@as(usize, 1), (try default_executor.getCode(default_result.address)).len);

    const ExpensiveDepositExecutor = Executor(ExpensiveDepositProtocol);
    var custom_executor = ExpensiveDepositExecutor.init(std.testing.allocator, .{
        .revision = .shanghai,
    });
    defer custom_executor.deinit();
    try putFundedSender(&custom_executor, sender);

    const custom_result = (try custom_executor.runStandalone(tx_context, .{ .create = .{
        .sender = sender,
        .recipient = evmz.address.create(sender, 0),
        .init_code = &init_code,
    } }, .legacy(100_000))).expectCreate();
    try std.testing.expectEqual(Interpreter.Status.out_of_gas, custom_result.status);
}

test "protocol definition drives created account initial nonce" {
    const overrides = struct {
        fn createInitialNonce(revision_value: evmz.eth.Revision) u64 {
            _ = revision_value;
            return 7;
        }
    };
    const NonceSevenProtocol = ethereumProtocolWith("create-nonce-seven", .{
        .create = .{ .createInitialNonce = overrides.createInitialNonce },
    });
    const sender = evmz.addr(0xaaaa);
    const tx_context = testTxContext(sender, 100_000);
    const init_code = initCodeReturningRuntimeSize(1);

    const NonceSevenExecutor = Executor(NonceSevenProtocol);
    var executor = NonceSevenExecutor.init(std.testing.allocator, .{
        .revision = .shanghai,
    });
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

test "protocol definition drives precompile warm access" {
    const NoPrecompiles = struct {
        pub const Entry = evmz.eth.precompile.Entry;

        pub fn resolve(revision_value: evmz.eth.Revision, target: Address) ?Entry {
            _ = revision_value;
            _ = target;
            return null;
        }

        pub fn execute(
            revision_value: evmz.eth.Revision,
            entry: Entry,
            call: evmz.execution.PrecompileCall,
        ) evmz.precompile.Error!evmz.execution.PrecompileOutcome {
            _ = revision_value;
            _ = entry;
            _ = call;
            return error.NotImplemented;
        }
    };
    const NoPrecompileProtocol = ethereumProtocolWith("no-precompiles", .{
        .precompile = NoPrecompiles,
    });
    const precompile_address = evmz.addr(0x01);

    var default_executor = Default.init(std.testing.allocator, .{
        .revision = .berlin,
    });
    defer default_executor.deinit();
    var default_host = default_executor.host();
    try std.testing.expectEqual(Host.AccessStatus.warm, try default_host.accessAccount(precompile_address));

    const NoPrecompileExecutor = Executor(NoPrecompileProtocol);
    var custom_executor = NoPrecompileExecutor.init(std.testing.allocator, .{
        .revision = .berlin,
    });
    defer custom_executor.deinit();
    var custom_host = custom_executor.host();
    try std.testing.expectEqual(Host.AccessStatus.cold, try custom_host.accessAccount(precompile_address));
}

test "protocol definition drives precompile execution" {
    const CustomPrecompileOverrides = struct {
        const custom_address = evmz.addr(0x1234);

        pub const Precompile = struct {
            pub const Entry = enum { custom };

            pub fn resolve(revision_value: evmz.eth.Revision, target: Address) ?Entry {
                _ = revision_value;
                if (!std.mem.eql(u8, &target, &custom_address)) return null;
                return .custom;
            }

            pub fn execute(
                revision_value: evmz.eth.Revision,
                entry: Entry,
                call: evmz.execution.PrecompileCall,
            ) evmz.precompile.Error!evmz.execution.PrecompileOutcome {
                _ = revision_value;
                _ = entry;
                return .{ .result = .{
                    .status = .success,
                    .output_data = try call.allocator.dupe(u8, &.{0xaa}),
                    .gas_left = call.message.gas - 7,
                } };
            }
        };
    };
    const CustomPrecompileProtocol = ethereumProtocolWith("custom-precompile-execution", .{
        .precompile = CustomPrecompileOverrides.Precompile,
    });
    const sender = evmz.addr(0xaaaa);
    const tx_context = testTxContext(sender, 100_000);

    const CustomPrecompileExecutor = Executor(CustomPrecompileProtocol);
    var executor = CustomPrecompileExecutor.init(std.testing.allocator, .{
        .revision = .cancun,
    });
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

test "protocol definition drives selfdestruct host policy" {
    const overrides = struct {
        fn selfDestructPolicy(
            revision_value: evmz.eth.Revision,
            input: evmz.protocol.SelfDestructPolicyInput,
        ) evmz.protocol.SelfDestructPolicy {
            _ = revision_value;
            _ = input;
            return .{
                .clear_balance = false,
                .reset_nonce = false,
                .mark_selfdestructed = false,
            };
        }

        fn selfDestructRefundGas(revision_value: evmz.eth.Revision) i64 {
            _ = revision_value;
            return 7;
        }
    };
    const KeepSelfDestructBalanceProtocol = ethereumProtocolWith("keep-selfdestruct-balance", .{
        .self_destruct = .{
            .selfDestructPolicy = overrides.selfDestructPolicy,
            .selfDestructRefundGas = overrides.selfDestructRefundGas,
        },
    });
    const sender = evmz.addr(0xaaaa);
    const contract = evmz.addr(0xbbbb);
    const beneficiary = evmz.addr(0xcccc);
    const code = evmz.t.bytecode(.{ .PUSH2, 0xcc, 0xcc, .SELFDESTRUCT });

    const KeepSelfDestructExecutor = Executor(KeepSelfDestructBalanceProtocol);
    var executor = KeepSelfDestructExecutor.init(std.testing.allocator, .{
        .revision = .cancun,
    });
    defer executor.deinit();
    try putFundedSender(&executor, sender);

    var contract_account = MemoryAccount.init(std.testing.allocator);
    contract_account.balance = 7;
    try contract_account.setCode(&code);
    try executor.state.seedAccount(contract, contract_account);

    _ = try executor.getOrCreateAccount(beneficiary);

    const result = (try executor.runStandalone(testTxContext(sender, 100_000), .{ .call = .{
        .sender = sender,
        .recipient = contract,
    } }, .legacy(100_000))).expectCall();

    try std.testing.expectEqual(Interpreter.Status.success, result.status);
    try std.testing.expectEqual(@as(i64, 7), result.gas_refund);
    try std.testing.expectEqual(@as(u256, 7), executor.getAccount(contract).?.balance);
    try std.testing.expectEqual(@as(u256, 7), executor.getAccount(beneficiary).?.balance);
    try std.testing.expect(!executor.state.selfdestructed_accounts.contains(contract));
}

test "create warms created address from Berlin" {
    const sender = evmz.addr(0xaaaa);
    const tx_context = testTxContext(sender, 100_000);
    var executor = Default.init(std.testing.allocator, .{
        .revision = .berlin,
    });
    defer executor.deinit();

    var sender_account = MemoryAccount.init(std.testing.allocator);
    sender_account.balance = 1_000_000;
    try executor.state.seedAccount(sender, sender_account);

    try executor.beginCreateTransaction(tx_context, sender);

    const init_code = &.{ 0x60, 0x00, 0x60, 0x00, 0xf3 };
    const create_address = evmz.address.create(sender, 0);
    const result = (try executor.executeCreateTransaction(sender, create_address, init_code, .legacy(100_000), 0)).expectCreate();

    try std.testing.expectEqual(Interpreter.Status.success, result.status);
    try std.testing.expect(executor.state.warm_accounts.contains(create_address));
}

test "callcode with insufficient balance fails without executing target code" {
    const caller = evmz.addr(0xaaaa);
    const target = evmz.addr(0xbbbb);
    const tx_context = testTxContext(caller, 100_000);
    var recorder = CheckpointTraceRecorder{};
    var sink = recorder.sink();
    var executor = Default.init(std.testing.allocator, .{
        .revision = .berlin,
    });
    defer executor.deinit();

    var caller_account = MemoryAccount.init(std.testing.allocator);
    caller_account.balance = 0;
    try executor.state.seedAccount(caller, caller_account);

    var target_account = MemoryAccount.init(std.testing.allocator);
    try target_account.setCode(&.{ 0x60, 0x11, 0x60, 0x64, 0x55, 0x00 });
    try executor.state.seedAccount(target, target_account);
    var capture: TestCapture(Default) = undefined;
    try capture.initSink(&executor, &sink);
    defer capture.deinit();

    try executor.beginTransaction(tx_context, caller, caller);
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
    try capture.finish();

    try std.testing.expectEqual(Interpreter.Status.invalid, result.status);
    try std.testing.expectEqual(@as(i64, 100_000), result.gas_left);
    try std.testing.expectEqual(@as(u256, 0), try executor.getStorage(caller, 0x64));
    try std.testing.expectEqual(@as(u8, 2), recorder.checkpoints);
    try std.testing.expectEqual(trace.CheckpointKind.checkpoint, recorder.first);
    try std.testing.expectEqual(trace.CheckpointKind.revert, recorder.last);
}

test "create address collision closes checkpoint without rolling back nonce or warmth" {
    const sender = evmz.addr(0xaaaa);
    const tx_context = testTxContext(sender, 100_000);
    var recorder = CheckpointTraceRecorder{};
    var sink = recorder.sink();
    var executor = Default.init(std.testing.allocator, .{
        .revision = .berlin,
    });
    defer executor.deinit();

    var sender_account = MemoryAccount.init(std.testing.allocator);
    sender_account.balance = 1;
    try executor.state.seedAccount(sender, sender_account);

    const create_address = evmz.address.create(sender, 0);
    var existing_account = MemoryAccount.init(std.testing.allocator);
    existing_account.nonce = 1;
    try executor.state.seedAccount(create_address, existing_account);
    var capture: TestCapture(Default) = undefined;
    try capture.initSink(&executor, &sink);
    defer capture.deinit();

    try executor.beginCreateTransaction(tx_context, sender);

    const result = (try executor.executeCreateTransaction(sender, create_address, &.{0x00}, .legacy(100_000), 1)).expectCreate();
    try capture.finish();

    try std.testing.expectEqual(Interpreter.Status.invalid, result.status);
    try std.testing.expectEqual(@as(u64, 1), executor.getAccount(sender).?.nonce);
    try std.testing.expect(executor.state.warm_accounts.contains(create_address));
    try std.testing.expectEqual(@as(u8, 2), recorder.checkpoints);
    try std.testing.expectEqual(trace.CheckpointKind.checkpoint, recorder.first);
    try std.testing.expectEqual(trace.CheckpointKind.commit, recorder.last);
}

test "checkpoint observation failures restore state and release ownership" {
    const caller = evmz.addr(0xaaaa);
    const tx_context = testTxContext(caller, 100_000);
    var executor = Default.init(std.testing.allocator, .{
        .revision = .berlin,
    });
    defer executor.deinit();
    try executor.state.setBalance(caller, 5);
    try executor.beginTransaction(tx_context, caller, caller);

    var failing = FailingCheckpointTarget{};
    var capture: TestCapture(Default) = undefined;
    try capture.init(&executor, failing.target());
    defer capture.deinit();

    failing.fail_kind = .checkpoint;
    try std.testing.expectError(error.TestCaptureFailure, executor.checkpoint());
    try std.testing.expectEqual(@as(usize, 0), executor.checkpoint_top);
    try std.testing.expectError(error.TestCaptureFailure, executor.transactionCheckpoint());
    try std.testing.expect(!executor.hasCurrentTransaction());

    failing.fail_kind = null;
    var commit_checkpoint = try executor.checkpoint();
    try executor.state.setBalance(caller, 9);
    failing.fail_kind = .commit;
    try std.testing.expectError(error.TestCaptureFailure, commit_checkpoint.commit());
    try std.testing.expectEqual(@as(u256, 5), try executor.getBalance(caller));
    try std.testing.expectEqual(@as(usize, 0), executor.checkpoint_top);

    failing.fail_kind = null;
    var revert_checkpoint = try executor.checkpoint();
    try executor.state.setBalance(caller, 11);
    failing.fail_kind = .revert;
    try std.testing.expectError(error.TestCaptureFailure, revert_checkpoint.restore());
    try std.testing.expectEqual(@as(u256, 5), try executor.getBalance(caller));
    try std.testing.expectEqual(@as(usize, 0), executor.checkpoint_top);

    failing.fail_kind = null;
    var reusable_checkpoint = try executor.checkpoint();
    try reusable_checkpoint.restore();
    var transaction_checkpoint = try executor.transactionCheckpoint();
    try transaction_checkpoint.restore();
    try std.testing.expect(!executor.hasCurrentTransaction());
    executor.closeTransaction();

    const request_value = execution_values.EvmExecutionRequest{
        .context = context_adapter.fromHost(tx_context),
        .message = .{ .call = .{
            .sender = caller,
            .recipient = caller,
        } },
        .gas = .legacy(100_000),
    };
    failing.fail_kind = .checkpoint;
    try std.testing.expectError(error.TestCaptureFailure, executor.beginTransactionAttempt(request_value, .{}));
    try std.testing.expectEqual(@as(?execution_values.ExecutionContext, null), executor.execution_context);
    try std.testing.expect(!executor.hasCurrentTransaction());

    failing.fail_kind = null;
    try capture.finish();
}

test "call-like message at max depth still executes in recipient storage" {
    const caller = evmz.addr(0xaaaa);
    const target = evmz.addr(0xbbbb);
    const tx_context = testTxContext(caller, 100_000);
    var executor = Default.init(std.testing.allocator, .{
        .revision = .frontier,
    });
    defer executor.deinit();

    var caller_account = MemoryAccount.init(std.testing.allocator);
    caller_account.balance = 1_000_000;
    try executor.state.seedAccount(caller, caller_account);

    try executor.state.seedAccount(target, MemoryAccount.init(std.testing.allocator));

    inline for (.{ Host.CallKind.callcode, Host.CallKind.delegatecall }, 0..) |kind, slot| {
        try executor.state.setCode(target, &.{ 0x60, 0x2a, 0x60, @intCast(slot), 0x55, 0x00 });
        try executor.beginTransaction(tx_context, caller, caller);
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
    var executor = Default.init(std.testing.allocator, .{
        .revision = .berlin,
    });
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
    var executor = Default.init(std.testing.allocator, .{
        .revision = .amsterdam,
    });
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
    var executor = Default.init(std.testing.allocator, .{
        .revision = .amsterdam,
    });
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
    var executor = Default.init(std.testing.allocator, .{
        .revision = .berlin,
    });
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
    var executor = Default.init(std.testing.allocator, .{
        .revision = .berlin,
    });
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
    var executor = Default.init(std.testing.allocator, .{
        .revision = .london,
    });
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
    try std.testing.expect(executor.state.warm_accounts.contains(create_address));
}

test "selfdestruct charges new-account cost for nonzero balance" {
    const sender = evmz.addr(0xaaaa);
    const contract = evmz.addr(0xbbbb);
    const tx_context = testTxContext(sender, 100_000);
    var executor = Default.init(std.testing.allocator, .{
        .revision = .cancun,
    });
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
    // Raw message scope is neutral: the zero beneficiary is cold unless the
    // transaction program supplies Ethereum's coinbase warm-up.
    try std.testing.expectEqual(@as(i64, 67_398), result.gas_left);
}

test "TangerineWhistle selfdestruct charges new-account cost without balance transfer" {
    const sender = evmz.addr(0xaaaa);
    const contract = evmz.addr(0xbbbb);
    const code = evmz.t.bytecode(.{ .PUSH1, 0x00, .SELFDESTRUCT });
    const cases = [_]struct {
        revision: evmz.eth.Revision,
        gas_left: i64,
    }{
        .{ .revision = .tangerine_whistle, .gas_left = 69_997 },
        .{ .revision = .spurious_dragon, .gas_left = 94_997 },
    };

    for (cases) |case| {
        const tx_context = testTxContext(sender, 100_000);
        var executor = Default.init(std.testing.allocator, .{
            .revision = case.revision,
        });
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
        try std.testing.expectEqual(case.gas_left, result.gas_left);
    }
}

test "SELFDESTRUCT refund is removed at London" {
    const sender = evmz.addr(0xaaaa);
    const contract = evmz.addr(0xbbbb);
    const code = evmz.t.bytecode(.{ .PUSH1, 0x00, .SELFDESTRUCT });
    const cases = [_]struct {
        revision: evmz.eth.Revision,
        refund: i64,
    }{
        .{ .revision = .berlin, .refund = 24_000 },
        .{ .revision = .london, .refund = 0 },
    };

    for (cases) |case| {
        const tx_context = testTxContext(sender, 100_000);
        var executor = Default.init(std.testing.allocator, .{
            .revision = case.revision,
        });
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
        try std.testing.expectEqual(case.refund, result.gas_refund);
    }
}

test "active precompiles are warm but not existing state accounts" {
    const precompile_address = evmz.addr(2);
    var executor = Default.init(std.testing.allocator, .{
        .revision = .berlin,
    });
    defer executor.deinit();

    var host_iface = executor.host();
    try std.testing.expect(!try host_iface.accountExists(precompile_address));
    try std.testing.expectEqual(Host.AccessStatus.warm, try host_iface.accessAccount(precompile_address));
    try std.testing.expectEqual(@as(u256, 0), try host_iface.getCodeHash(precompile_address));

    _ = try executor.getOrCreateAccount(precompile_address);
    try std.testing.expectEqual(uint256.fromBytes32(&evmz.crypto.keccak256_empty), try host_iface.getCodeHash(precompile_address));
}

test "delegated precompile targets are warm" {
    const authority = evmz.addr(0xbbbb);
    const precompile_address = evmz.addr(2);
    for ([_]evmz.eth.Revision{ .prague, .amsterdam }) |revision_value| {
        var executor = Default.init(std.testing.allocator, .{
            .revision = revision_value,
        });
        defer executor.deinit();

        var code: [eip7702.delegation_code_len]u8 = undefined;
        eip7702.writeDelegationCode(&code, precompile_address);
        var authority_account = MemoryAccount.init(std.testing.allocator);
        try authority_account.setCode(&code);
        try executor.state.seedAccount(authority, authority_account);

        var host_iface = executor.host();
        try std.testing.expectEqual(Host.AccessStatus.warm, (try host_iface.accessDelegatedAccount(authority)).?);
    }
}

test "state-only trace sink records state without step tracing" {
    const sender = evmz.addr(0xaaaa);
    const contract = evmz.addr(0xbbbb);
    const tx_context = testTxContext(sender, 100_000);

    var recorder = StateOnlyTraceRecorder{};
    var sink = recorder.sink();
    var executor = Default.init(std.testing.allocator, .{
        .revision = .berlin,
    });
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
    var capture: TestCapture(Default) = undefined;
    try capture.initSink(&executor, &sink);
    defer capture.deinit();

    try executor.beginTransaction(tx_context, sender, contract);
    const result = try executor.executeCallTransaction(sender, contract, &.{}, .legacy(100_000), 0);
    try capture.finish();

    try std.testing.expectEqual(Interpreter.Status.success, result.status);
    try std.testing.expectEqual(@as(u8, 0), recorder.step_starts);
    try std.testing.expectEqual(@as(u8, 0), recorder.step_ends);
    try std.testing.expect(recorder.storage_reads >= 1);
    try std.testing.expectEqual(@as(u8, 1), recorder.storage_writes);
    try std.testing.expectEqual(@as(u256, 42), recorder.last_storage_write);
}

const StateOnlyTraceRecorder = struct {
    step_starts: u8 = 0,
    step_ends: u8 = 0,
    storage_reads: u8 = 0,
    storage_writes: u8 = 0,
    last_storage_write: u256 = 0,

    fn sink(self: *StateOnlyTraceRecorder) trace.Sink {
        return trace.Sink.init(self, .{
            .state_read = trace.StateReadKinds.initMany(&.{.storage}),
            .state_write = trace.StateWriteKinds.initMany(&.{.storage}),
        }, &.{
            .stepStart = stepStart,
            .stepEnd = stepEnd,
            .stateRead = stateRead,
            .stateWrite = stateWrite,
        });
    }

    fn stepStart(ptr: *anyopaque, event: trace.StepStart) void {
        const self: *StateOnlyTraceRecorder = @ptrCast(@alignCast(ptr));
        _ = event;
        self.step_starts += 1;
    }

    fn stepEnd(ptr: *anyopaque, event: trace.StepEnd) void {
        const self: *StateOnlyTraceRecorder = @ptrCast(@alignCast(ptr));
        _ = event;
        self.step_ends += 1;
    }

    fn stateRead(ptr: *anyopaque, event: trace.StateRead) void {
        const self: *StateOnlyTraceRecorder = @ptrCast(@alignCast(ptr));
        switch (event) {
            .storage => self.storage_reads += 1,
            else => {},
        }
    }

    fn stateWrite(ptr: *anyopaque, event: trace.StateWrite) void {
        const self: *StateOnlyTraceRecorder = @ptrCast(@alignCast(ptr));
        switch (event) {
            .storage => |payload| {
                self.storage_writes += 1;
                self.last_storage_write = payload.value;
            },
            else => {},
        }
    }
};

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

    fn sink(self: *StepOrderRecorder) trace.Sink {
        return trace.Sink.init(self, .{
            .step_start = trace.StepStartFields.initMany(&.{ .opcode, .depth }),
            .step_end = trace.StepEndFields.initMany(&.{ .opcode, .depth, .stack, .status }),
        }, &.{
            .stepStart = stepStart,
            .stepEnd = stepEnd,
        });
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

    fn stepStart(ptr: *anyopaque, event: trace.StepStart) void {
        const self: *StepOrderRecorder = @ptrCast(@alignCast(ptr));
        self.append(.{
            .kind = .start,
            .opcode = event.opcode,
            .depth = event.depth,
        });
    }

    fn stepEnd(ptr: *anyopaque, event: trace.StepEnd) void {
        const self: *StepOrderRecorder = @ptrCast(@alignCast(ptr));
        self.append(.{
            .kind = .end,
            .opcode = event.opcode,
            .depth = event.depth,
            .stack_top = if (event.stack.len == 0) null else event.stack[event.stack.len - 1],
        });
    }
};

const CheckpointTraceRecorder = struct {
    checkpoints: u8 = 0,
    first: trace.CheckpointKind = .checkpoint,
    last: trace.CheckpointKind = .checkpoint,

    fn sink(self: *CheckpointTraceRecorder) trace.Sink {
        return trace.Sink.init(self, .{
            .checkpoint = trace.CheckpointFields.full,
        }, &.{
            .checkpoint = checkpointEvent,
        });
    }

    fn checkpointEvent(ptr: *anyopaque, event: trace.Checkpoint) void {
        const self: *CheckpointTraceRecorder = @ptrCast(@alignCast(ptr));
        if (self.checkpoints == 0) self.first = event.kind;
        self.last = event.kind;
        self.checkpoints += 1;
    }
};

const FailingCheckpointTarget = struct {
    fail_kind: ?trace.CheckpointKind = null,

    fn target(self: *FailingCheckpointTarget) CaptureStateTarget {
        return CaptureStateTarget.init(self, &.{ .checkpoint = checkpointEvent });
    }

    fn checkpointEvent(ptr: *anyopaque, event: trace.Checkpoint) !void {
        const self: *FailingCheckpointTarget = @ptrCast(@alignCast(ptr));
        if (self.fail_kind == event.kind) return error.TestCaptureFailure;
    }
};

fn TestCapture(comptime ExecutorType: type) type {
    return struct {
        const Self = @This();

        executor: *ExecutorType = undefined,
        context: CaptureContext = undefined,
        open: bool = false,
        bound: bool = false,

        fn init(self: *Self, executor: *ExecutorType, state_target: ?CaptureStateTarget) !void {
            self.* = .{
                .executor = executor,
                .context = CaptureContext.init(executor.allocator, null, state_target),
            };
            executor.setCaptureContext(&self.context);
            self.bound = true;
            errdefer {
                executor.setCaptureContext(null);
                self.bound = false;
                self.context.deinit();
            }
            try self.context.begin();
            self.open = true;
        }

        fn initSink(self: *Self, executor: *ExecutorType, sink: *trace.Sink) !void {
            try self.init(executor, capture_context.stateTargetForSink(sink));
        }

        fn finish(self: *Self) !void {
            _ = try self.context.finish();
            self.open = false;
            self.executor.setCaptureContext(null);
            self.bound = false;
        }

        fn deinit(self: *Self) void {
            if (self.open) {
                self.context.abort() catch |err| @panic(@errorName(err));
                self.open = false;
            }
            if (self.bound) self.executor.setCaptureContext(null);
            self.context.deinit();
            self.* = undefined;
        }
    };
}

fn executeHostCall(executor: anytype, msg: Host.Message) !Host.Result {
    var host_iface = executor.host();
    return host_iface.call(msg);
}

test {
    std.testing.refAllDecls(@This());
}
