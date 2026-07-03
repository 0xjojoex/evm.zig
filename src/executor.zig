//! Low-level EVM execution engine.
//!
//! `Executor` owns the mutable overlay state, transaction context, frame pools,
//! and output buffers used while running EVM code. Higher-level APIs such as
//! `Vm` handle validation and user-facing transaction shapes; this type is the
//! execution substrate underneath them.
//!
//! The public methods fall into three lifecycle layers:
//!
//! 1. `runStandalone` is the convenience path for raw call/create messages. It
//!    opens a transaction scope, snapshots state, executes, then commits or
//!    rolls back from the result status.
//! 2. `beginTransactionScope` + `runTopLevelTransaction` is the normal validated
//!    transaction path used by `Vm.transact`: the caller opens the scope, then
//!    the executor charges gas, applies nonce/access/authorization effects,
//!    executes the message, settles costs, and closes the scope.
//! 3. `beginTransaction` / `beginCreateTransaction` + `executeCall` /
//!    `executeCreate` are lower-level building blocks for tests, fixtures,
//!    benchmarks, and code that needs to drive a partially-managed scope.
//!
//! `executor/call_runtime.zig` owns call/create frame execution and bytecode
//! frame setup. `executor/host_callbacks.zig` owns the `Host` vtable adapter.

const std = @import("std");
const evmz = @import("./evm.zig");

const Address = evmz.Address;
const AccountState = evmz.state.AccountState;
const BlockHashSource = evmz.BlockHashSource;
const Bytecode = evmz.Bytecode;
const Changeset = evmz.state.Changeset;
const Host = evmz.Host;
const Interpreter = evmz.Interpreter;
const StateOverlay = evmz.state.Overlay;
const trace = @import("./trace.zig");
const TraceSink = trace.Sink;
const transaction = evmz.transaction;
const tx_gas = @import("./transaction/gas.zig");
const uint256 = @import("./uint256.zig");

const Executor = @This();
const CallFramePool = std.heap.MemoryPool(Interpreter.CallFrameSlot);
const SnapshotPool = std.heap.MemoryPool(Snapshot);
const CallScratchArenas = std.ArrayList(*std.heap.ArenaAllocator);

pub const eip7702 = @import("./executor/eip7702.zig");
pub const system_contracts = @import("./executor/system_contracts.zig");
pub const state_io = @import("./executor/state_io.zig");
pub const transfer_logs = @import("./executor/transfer_logs.zig");
const call_runtime = @import("./executor/call_runtime.zig");
const host_callbacks = @import("./executor/host_callbacks.zig");

pub const Snapshot = StateOverlay.Snapshot;
pub const TransientSnapshot = StateOverlay.TransientSnapshot;
pub const code_deposit_gas: i64 = 200;
pub const max_code_size = 0x6000;
pub const amsterdam_max_code_size = 0x10000;

pub fn maxCodeSize(spec: evmz.Spec) usize {
    return if (spec.isImpl(.amsterdam)) amsterdam_max_code_size else max_code_size;
}

/// Construction options for the execution substrate.
///
/// `state_reader` is optional so tests and ephemeral executors can run purely
/// from the in-memory overlay. `block_hash_source` is separate because native
/// BLOCKHASH reads chain history, not account/trie state. `trace_sink` is
/// threaded through state and interpreter frames when tracing is enabled.
pub const Init = struct {
    spec: evmz.Spec,
    state_reader: ?evmz.state.StateReader = null,
    block_hash_source: ?BlockHashSource = null,
    config: evmz.Config = .base,
    trace_sink: ?*TraceSink = null,
};

/// A top-level call whose bytecode has already been prepared by the caller.
///
/// This is the narrowest call entrypoint. Use it when a benchmark/test wants to
/// control bytecode preprocessing explicitly; otherwise prefer `executeCall` or
/// `runStandalone`.
pub const PreparedCallTransaction = struct {
    bytecode: *Bytecode,
    sender: Address,
    recipient: Address,
    input: []const u8 = &.{},
    gas: u64,
    gas_reservoir: u64 = 0,
    value: u256 = 0,
};

/// Raw top-level call message executed inside an already-open tx scope.
pub const Call = struct {
    sender: Address,
    recipient: Address,
    input: []const u8 = &.{},
    gas: u64,
    gas_reservoir: u64 = 0,
    value: u256 = 0,
};

/// Raw top-level create/create2 message executed inside an already-open tx scope.
pub const Create = struct {
    sender: Address,
    init_code: []const u8,
    gas: u64,
    gas_reservoir: u64 = 0,
    value: u256 = 0,
    salt: ?u256 = null,
};

/// Raw message shape accepted by the standalone executor path.
pub const Message = union(enum) {
    call: Call,
    create: Create,
};

pub const EvmResult = Host.Result;
pub const AuthorizationTuple = transaction.AuthorizationTuple;
pub const Transaction = transaction.Transaction;

allocator: std.mem.Allocator,
state: StateOverlay,
call_frame_pool: CallFramePool,
snapshot_pool: SnapshotPool,
call_scratch_arenas: CallScratchArenas,
tx_context: ?Host.TxContext = null,
block_hash_source: ?BlockHashSource = null,
spec: evmz.Spec,
config: evmz.Config,
trace_sink: ?*TraceSink = null,
last_call_output: []u8 = &.{},

/// Parameters that belong to transaction settlement rather than bytecode
/// execution.
pub const TopLevelTransactionRun = struct {
    execution: ?transaction.ExecutionGas = null,
    execution_gas: ?u64 = null,
    settlement: transaction.Settlement,

    fn gas(self: TopLevelTransactionRun) ?transaction.ExecutionGas {
        if (self.execution) |execution| return execution;
        if (self.execution_gas) |legacy| return transaction.ExecutionGas.legacy(legacy);
        return null;
    }
};

/// Optional execution hook for benchmark/fixture drivers.
///
/// Production transaction execution uses `defaultTransactionEngine`; tests and
/// benchmark harnesses can swap this to time or compare only the message
/// execution portion while reusing the same transaction accounting shell.
pub const TransactionEngine = struct {
    ptr: ?*anyopaque = null,
    execute: *const fn (
        ptr: ?*anyopaque,
        executor: *Executor,
        tx: Transaction,
        gas: transaction.ExecutionGas,
    ) anyerror!Interpreter.Result,
};

const AuthorizationGasAdjustment = struct {
    regular_refund: u64 = 0,
    state_refund: u64 = 0,

    fn add(self: *AuthorizationGasAdjustment, other: AuthorizationGasAdjustment) void {
        self.regular_refund = std.math.add(u64, self.regular_refund, other.regular_refund) catch std.math.maxInt(u64);
        self.state_refund = std.math.add(u64, self.state_refund, other.state_refund) catch std.math.maxInt(u64);
    }
};

/// Execute a raw call inside an already-open tx scope.
pub const executeCall = call_runtime.executeCall;
/// Execute a raw call by loading and preparing recipient code first.
pub const executeCallTransaction = call_runtime.executeCallTransaction;
/// Execute a raw call with caller-provided prepared bytecode.
pub const executePreparedCallTransaction = call_runtime.executePreparedCallTransaction;
/// Execute a raw create inside an already-open create tx scope.
pub const executeCreateTransaction = call_runtime.executeCreateTransaction;
/// Execute a raw create/create2 message inside an already-open tx scope.
pub const executeCreate = call_runtime.executeCreate;
/// Return this executor's `Host` adapter for interpreter frames.
pub const host = host_callbacks.host;

const SnapshotLease = struct {
    executor: *Executor,
    snapshot: *Snapshot,

    pub fn deinit(self: *SnapshotLease) void {
        self.snapshot.deinit(self.executor.allocator);
        self.executor.snapshot_pool.destroy(self.snapshot);
        self.* = undefined;
    }
};

/// Initialize an executor with an empty mutable overlay.
pub fn init(allocator: std.mem.Allocator, options: Init) Executor {
    var state = if (options.state_reader) |state_reader|
        StateOverlay.initWithStateReader(allocator, state_reader)
    else
        StateOverlay.init(allocator);
    state.trace_sink = options.trace_sink;

    return .{
        .allocator = allocator,
        .state = state,
        .call_frame_pool = .empty,
        .snapshot_pool = .empty,
        .call_scratch_arenas = .empty,
        .spec = options.spec,
        .block_hash_source = options.block_hash_source,
        .config = options.config,
        .trace_sink = options.trace_sink,
    };
}

/// Release state, frame pools, scratch arenas, and retained return-data buffers.
pub fn deinit(self: *Executor) void {
    self.state.deinit();
    self.call_frame_pool.deinit(self.allocator);
    self.snapshot_pool.deinit(self.allocator);
    for (self.call_scratch_arenas.items) |arena| {
        arena.deinit();
        self.allocator.destroy(arena);
    }
    self.call_scratch_arenas.deinit(self.allocator);
    self.allocator.free(self.last_call_output);
}

fn warmTransactionAccesses(self: *Executor, tx_context: Host.TxContext, sender: Address, recipient: ?Address) !void {
    try self.warmAccessListAddress(sender);
    if (recipient) |address| {
        try self.warmAccessListAddress(address);
    }
    if (self.spec.isImpl(.shanghai)) {
        try self.warmAccessListAddress(tx_context.coinbase);
    }
}

/// Open a manual call transaction scope.
///
/// Callers that use this directly must eventually call `commitTransaction`,
/// `rollbackTransaction`, `closeTransaction`, or another helper that does so.
/// The scope warms the sender, recipient, and spec-required coinbase account.
pub fn beginTransaction(self: *Executor, tx_context: Host.TxContext, sender: Address, recipient: Address) !void {
    self.tx_context = tx_context;
    self.state.beginTransaction();
    errdefer self.closeTransaction();
    try self.warmTransactionAccesses(tx_context, sender, recipient);
}

/// Open a manual create transaction scope.
///
/// This is the create counterpart to `beginTransaction`; there is no recipient
/// to warm before the create address is derived during execution.
pub fn beginCreateTransaction(self: *Executor, tx_context: Host.TxContext, sender: Address) !void {
    self.tx_context = tx_context;
    self.state.beginTransaction();
    errdefer self.closeTransaction();
    try self.warmTransactionAccesses(tx_context, sender, null);
}

/// Open the correct manual scope for a normalized transaction.
///
/// `Vm.transact` and fixture runners use this before `runTopLevelTransaction`.
pub fn beginTransactionScope(self: *Executor, tx_context: Host.TxContext, tx: Transaction) !void {
    switch (tx) {
        .call => |call_tx| try self.beginTransaction(tx_context, call_tx.sender, call_tx.recipient),
        .create => |create_tx| try self.beginCreateTransaction(tx_context, create_tx.sender),
    }
}

fn beginSystemCall(self: *Executor, tx_context: Host.TxContext) !void {
    self.tx_context = tx_context;
    self.state.beginTransaction();
}

/// Mark an account warm in the current transaction scope.
pub fn warmAccessListAddress(self: *Executor, address: Address) !void {
    try self.state.warmAccount(address);
}

/// Mark a storage slot warm in the current transaction scope.
pub fn warmAccessListStorage(self: *Executor, address: Address, key: u256) !void {
    try self.state.warmStorage(address, key);
}

/// Apply a transaction access list to the current scope.
pub fn warmAccessList(self: *Executor, access_list: []const transaction.AccessListEntry) !void {
    for (access_list) |entry| {
        try self.warmAccessListAddress(entry.address);
        for (entry.storage_keys) |key| {
            try self.warmAccessListStorage(entry.address, key);
        }
    }
}

/// Return an account already present in the overlay, without consulting the state reader.
pub fn getAccount(self: *Executor, address: Address) ?*AccountState {
    return self.state.getAccount(address);
}

/// Return an account, loading it from the state reader into the overlay if needed.
pub fn getAccountOrLoad(self: *Executor, address: Address) !?*AccountState {
    return self.state.getAccountOrLoad(address);
}

/// Return an account, creating an empty overlay account when none exists.
pub fn getOrCreateAccount(self: *Executor, address: Address) !*AccountState {
    return self.state.getOrCreateAccount(address);
}

/// Read storage through the overlay/state-reader view.
pub fn getStorage(self: *Executor, address: Address, key: u256) !u256 {
    return self.state.getStorage(address, key);
}

pub fn logs(self: *const Executor) []const Host.Log {
    return self.state.getLogs();
}

pub fn clearLogs(self: *Executor) void {
    self.state.clearLogs();
}

/// Capture a full overlay snapshot suitable for transaction rollback.
pub fn snapshot(self: *Executor) !Snapshot {
    return self.state.snapshot();
}

fn snapshotLease(self: *Executor) !SnapshotLease {
    const snapshot_state = try self.snapshot_pool.create(self.allocator);
    errdefer self.snapshot_pool.destroy(snapshot_state);
    snapshot_state.* = try self.snapshot();
    return .{
        .executor = self,
        .snapshot = snapshot_state,
    };
}

/// Restore the overlay to a previous full snapshot.
pub fn restore(self: *Executor, snapshot_state: *Snapshot) !void {
    try self.state.restore(snapshot_state);
}

/// Restore only revertible execution effects from a previous snapshot.
pub fn restoreRevertible(self: *Executor, snapshot_state: *Snapshot) !void {
    try self.state.restoreRevertible(snapshot_state);
}

/// Commit the current transaction scope.
///
/// Kept as a compatibility alias for callers that speak in terms of
/// "finalizing" a transaction; internally this is `commitTransaction`.
pub fn finalizeTransaction(self: *Executor) !void {
    try self.commitTransaction();
}

/// Finalize state changes for the current transaction and close its context.
pub fn commitTransaction(self: *Executor) !void {
    try self.state.finalizeTransaction(self.spec);
    self.closeTransaction();
}

/// Restore from a snapshot and close the current transaction context.
pub fn rollbackTransaction(self: *Executor, snapshot_state: *Snapshot) !void {
    try self.restore(snapshot_state);
    self.closeTransaction();
}

/// Close the current transaction context without restoring overlay changes.
pub fn closeTransaction(self: *Executor) void {
    self.state.closeTransaction();
    self.tx_context = null;
}

/// Return the pending overlay changes without committing them.
pub fn changeset(self: *Executor) !Changeset {
    return self.state.changeset();
}

/// Drop all pending overlay changes and clear any open transaction context.
pub fn discardChanges(self: *Executor) void {
    self.state.discardChanges();
    self.tx_context = null;
}

/// Read account code through the overlay/state-reader view.
pub fn getCode(self: *Executor, address: Address) ![]const u8 {
    return self.state.getCode(address);
}

/// Prepare code according to the executor preprocessing configuration.
pub fn prepareBytecode(self: *const Executor, code: []const u8) !Bytecode {
    return call_runtime.prepareBytecodeAlloc(self, self.allocator, code);
}

/// Duplicate the effective execution code for an address.
///
/// EIP-7702 delegation is resolved here so callers execute target code while
/// preserving the original message address semantics.
pub fn dupeExecutionCode(self: *Executor, address: Address) ![]u8 {
    return call_runtime.dupeExecutionCodeAlloc(self, self.allocator, address);
}

/// Execute a raw call/create message inside an already-open tx scope.
///
/// This does not open or close a transaction scope. Use `runStandalone` for the
/// fully-managed raw-message lifecycle.
pub fn executeMessage(self: *Executor, message: Message) !EvmResult {
    return switch (message) {
        .call => |options| self.executeCall(options),
        .create => |options| self.executeCreate(options),
    };
}

/// Run one raw call/create message as a complete transaction scope.
///
/// Lifecycle: open scope -> snapshot -> execute -> commit on success, rollback
/// on revert/invalid/out-of-gas. This is useful for raw VM calls outside the
/// full transaction validation/accounting path.
pub fn runStandalone(self: *Executor, tx_context: Host.TxContext, message: Message) !EvmResult {
    return switch (message) {
        .call => |options| self.runStandaloneCall(tx_context, options),
        .create => |options| self.runStandaloneCreate(tx_context, options),
    };
}

fn runStandaloneCall(self: *Executor, tx_context: Host.TxContext, options: Call) !EvmResult {
    try self.beginTransaction(tx_context, options.sender, options.recipient);
    errdefer self.closeTransaction();

    var pre_execution = try self.snapshot();
    defer pre_execution.deinit(self.allocator);
    errdefer self.rollbackTransaction(&pre_execution) catch self.closeTransaction();

    const result = try self.executeCall(options);
    try self.finishStandaloneTransaction(result.status(), &pre_execution);
    return result;
}

fn runStandaloneCreate(self: *Executor, tx_context: Host.TxContext, options: Create) !EvmResult {
    try self.beginCreateTransaction(tx_context, options.sender);
    errdefer self.closeTransaction();

    var pre_execution = try self.snapshot();
    defer pre_execution.deinit(self.allocator);
    errdefer self.rollbackTransaction(&pre_execution) catch self.closeTransaction();

    const result = try self.executeCreate(options);
    try self.finishStandaloneTransaction(result.status(), &pre_execution);
    return result;
}

fn finishStandaloneTransaction(self: *Executor, status: Interpreter.Status, snapshot_state: *Snapshot) !void {
    if (executionRolledBack(status)) {
        try self.rollbackTransaction(snapshot_state);
    } else {
        try self.commitTransaction();
    }
}

/// Execute the message portion of a normalized transaction.
///
/// The caller owns transaction charging, nonce/access/auth handling, settlement,
/// and final commit/rollback. `runTopLevelTransaction` wraps those pieces.
pub fn executeTransactionMessage(self: *Executor, tx: Transaction, gas: transaction.ExecutionGas) !Interpreter.Result {
    return switch (tx) {
        .call => |call_tx| call_runtime.executeCallTransaction(
            self,
            call_tx.sender,
            call_tx.recipient,
            call_tx.input,
            gas,
            call_tx.value,
        ),
        .create => |create_tx| blk: {
            const result = (try call_runtime.executeCreateTransaction(
                self,
                create_tx.sender,
                create_tx.init_code,
                gas,
                create_tx.value,
            )).expectCreate();
            var interpreter_result = Interpreter.Result{
                .status = result.status,
                .gas_left = result.gas_left,
                .gas_refund = result.gas_refund,
                .gas_reservoir = result.gas_reservoir,
                .state_gas_spent = result.state_gas_spent,
                .state_gas_from_gas_left = result.state_gas_from_gas_left,
                .output_data = self.last_call_output,
            };
            interpreter_result.refillIntrinsicStateGas(result.state_gas_refund);
            break :blk interpreter_result;
        },
    };
}

/// Run the normal top-level transaction accounting shell.
///
/// Callers must first open a matching scope with `beginTransactionScope`. This
/// method charges upfront gas, applies nonce/access/authorization effects,
/// executes when `execution_gas` is present, commits or restores state, settles
/// gas costs, and closes the transaction context.
pub fn runTopLevelTransaction(
    self: *Executor,
    tx: Transaction,
    run: TopLevelTransactionRun,
) !Interpreter.Result {
    return self.runTopLevelTransactionWithEngine(tx, run, .{
        .execute = defaultTransactionEngine,
    });
}

/// Variant of `runTopLevelTransaction` with an injectable execution engine.
///
/// Benchmark and fixture drivers use this to swap only the message execution
/// step while preserving the same transaction accounting behavior.
pub fn runTopLevelTransactionWithEngine(
    self: *Executor,
    tx: Transaction,
    run: TopLevelTransactionRun,
    engine: TransactionEngine,
) !Interpreter.Result {
    var shell_start_state = try self.snapshot();
    defer shell_start_state.deinit(self.allocator);
    errdefer {
        self.restore(&shell_start_state) catch {};
        self.closeTransaction();
    }

    const sender = tx.sender();
    var execution_gas = run.gas();
    const transaction_charged = if (execution_gas != null)
        try self.chargeTransactionCosts(sender, tx.gasLimit(), tx.value())
    else
        false;
    var authorization_gas = AuthorizationGasAdjustment{};
    if (transaction_charged) {
        if (!tx.isCreate()) {
            try self.incrementNonce(sender);
        }
        try self.warmAccessList(tx.accessList());
        authorization_gas = try self.applyAuthorizationList(tx.authorizationList());
        authorization_gas.add(self.malformedAuthorizationGasAdjustment(tx));
        if (authorization_gas.state_refund != 0) {
            if (execution_gas) |current_gas| {
                const adjusted_gas = transaction.ExecutionGas{
                    .regular_left = current_gas.regular_left,
                    .reservoir = std.math.add(u64, current_gas.reservoir, authorization_gas.state_refund) catch std.math.maxInt(u64),
                };
                execution_gas = adjusted_gas;
            }
        }
        try self.warmDelegatedTransactionTarget(tx);
    }

    var pre_execution_state = try self.snapshot();
    defer pre_execution_state.deinit(self.allocator);

    var result = Interpreter.Result{
        .status = .out_of_gas,
        .gas_left = 0,
        .gas_refund = 0,
        .output_data = &.{},
    };
    if (execution_gas) |gas| {
        if (!transaction_charged) {
            result.status = .invalid;
        } else {
            result = try engine.execute(engine.ptr, self, tx, gas);
        }
    }
    const authorization_refund_i64 = std.math.cast(i64, authorization_gas.regular_refund) orelse std.math.maxInt(i64);
    result.gas_refund = std.math.add(i64, result.gas_refund, authorization_refund_i64) catch std.math.maxInt(i64);
    if (authorization_gas.state_refund != 0) {
        const state_refund_i64 = std.math.cast(i64, authorization_gas.state_refund) orelse std.math.maxInt(i64);
        result.state_gas_spent = std.math.sub(i64, result.state_gas_spent, state_refund_i64) catch std.math.minInt(i64);
    }

    if (executionRolledBack(result.status)) {
        if (self.spec.isImpl(.amsterdam) and tx.isCreate() and transaction_charged) {
            result.refillIntrinsicStateGas(std.math.cast(i64, transaction.amsterdam_new_account_state_gas) orelse std.math.maxInt(i64));
        }
        try self.restore(&pre_execution_state);
        if (tx.isCreate() and transaction_charged) {
            try self.incrementNonce(sender);
        }
        self.closeTransaction();
    } else {
        try self.commitTransaction();
    }
    if (transaction_charged) {
        try self.settleTransactionCosts(sender, run.settlement, result);
    }

    return result;
}

fn defaultTransactionEngine(
    ptr: ?*anyopaque,
    executor: *Executor,
    tx: Transaction,
    gas: transaction.ExecutionGas,
) !Interpreter.Result {
    _ = ptr;
    return executor.executeTransactionMessage(tx, gas);
}

/// Execute a system call as its own transaction-like scope.
///
/// System calls bypass user transaction charging and value transfer, but still
/// run with a tx context, checkpoint state, and commit/rollback semantics.
pub fn executeSystemCall(
    self: *Executor,
    tx_context: Host.TxContext,
    sender: Address,
    recipient: Address,
    input: []const u8,
    gas: u64,
) !Interpreter.Result {
    try self.beginSystemCall(tx_context);
    errdefer self.closeTransaction();

    self.clearLastOutput();
    const checkpoint_state = self.state.checkpoint();
    var checkpoint_open = true;
    errdefer {
        if (checkpoint_open) self.state.revertToCheckpoint(checkpoint_state) catch {};
    }

    var host_iface = self.host();
    var scratch = try call_runtime.callScratch(self, 0);
    defer scratch.deinit();
    const code = try call_runtime.dupeExecutionCodeAlloc(self, scratch.allocator, recipient);
    var bytecode = try call_runtime.prepareBytecodeAlloc(self, scratch.allocator, code);
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

    var frame = try call_runtime.acquireBytecodeFrame(self, scratch.allocator, &host_iface, &message, &bytecode);
    defer frame.deinit();
    var interpreter = frame.interpreter();

    const result = try call_runtime.executeInterpreter(self, &interpreter, message.depth);
    self.clearLastOutput();
    self.last_call_output = try self.allocator.dupe(u8, result.output_data);

    if (executionRolledBack(result.status)) {
        try self.state.revertToCheckpoint(checkpoint_state);
        checkpoint_open = false;
        self.closeTransaction();
    } else {
        self.state.commitCheckpoint(checkpoint_state);
        checkpoint_open = false;
        try self.commitTransaction();
    }

    return .{
        .status = result.status,
        .gas_left = result.gas_left,
        .gas_refund = result.gas_refund,
        .output_data = self.last_call_output,
    };
}

/// Transfer value between accounts, returning false on insufficient balance.
pub fn transferValue(self: *Executor, sender: Address, recipient: Address, value: u256) !bool {
    if (value == 0) return true;
    if (!try self.state.subtractBalance(sender, value)) return false;
    try self.state.addBalance(recipient, value);
    try transfer_logs.emit(self, sender, recipient, value);
    return true;
}

/// Increment an account nonce, saturating at `maxInt(u64)`.
pub fn incrementNonce(self: *Executor, address: Address) !void {
    const account = try self.getOrCreateAccount(address);
    try self.state.setNonce(address, std.math.add(u64, account.nonce, 1) catch std.math.maxInt(u64));
}

/// Charge the sender's upfront transaction cost.
///
/// Returns false when prepayment overflows or the sender cannot cover gas plus
/// value. The caller still decides whether to execute and how to close scope.
pub fn chargeTransactionCosts(self: *Executor, sender: Address, gas_limit: u64, value: u256) !bool {
    const tx_context = try call_runtime.currentTxContext(self);
    const upfront_cost = transaction.prepaymentCost(
        gas_limit,
        tx_context.gas_price,
        tx_context.blob_base_fee,
        tx_context.blob_hashes.len,
    ) orelse return false;
    const required_balance = uint256.checkedAdd(upfront_cost, value) orelse return false;
    const sender_account = try self.state.getAccountOrLoad(sender) orelse return false;
    if (sender_account.balance < required_balance) return false;
    return self.state.subtractBalance(sender, upfront_cost);
}

/// Refund unused gas to the sender and pay the block coinbase.
pub fn settleTransactionCosts(self: *Executor, sender: Address, settlement: transaction.Settlement, result: Interpreter.Result) !void {
    const costs = try transaction.settlementCosts(settlement, .{
        .gas_left = result.gas_left,
        .gas_refund = result.gas_refund,
        .gas_reservoir = result.gas_reservoir,
        .state_gas_spent = result.state_gas_spent,
    });
    try self.state.addBalance(sender, costs.sender_refund);
    try self.state.addBalance(settlement.coinbase, costs.coinbase_payment);
}

/// Apply all EIP-7702 authorizations and return their gas refund.
pub fn applyAuthorizationList(self: *Executor, authorization_list: []const AuthorizationTuple) !AuthorizationGasAdjustment {
    if (!self.spec.isImpl(.prague)) return .{};
    var adjustment = AuthorizationGasAdjustment{};
    var pre_delegated = std.AutoHashMap(Address, bool).init(self.allocator);
    defer pre_delegated.deinit();
    for (authorization_list) |auth| {
        adjustment.add(try self.applyAuthorizationTupleTracked(auth, &pre_delegated));
    }
    return adjustment;
}

/// Apply one EIP-7702 authorization tuple.
///
/// Invalid tuples are ignored. Before Amsterdam they do not refund; Amsterdam
/// refills the tuple's intrinsic state-gas slice and refunds ACCOUNT_WRITE.
pub fn applyAuthorizationTuple(self: *Executor, auth: AuthorizationTuple) !AuthorizationGasAdjustment {
    return self.applyAuthorizationTupleTracked(auth, null);
}

fn applyAuthorizationTupleTracked(
    self: *Executor,
    auth: AuthorizationTuple,
    pre_delegated_by_authority: ?*std.AutoHashMap(Address, bool),
) !AuthorizationGasAdjustment {
    if (!self.spec.isImpl(.prague)) return .{};
    if (!eip7702.authorizationSignatureShapeValid(auth.y_parity, auth.legacy_v, auth.r, auth.s)) return self.invalidAuthorizationGasAdjustment();
    const tx_context = try call_runtime.currentTxContext(self);
    if (auth.chain_id != 0 and auth.chain_id != tx_context.chain_id) return self.invalidAuthorizationGasAdjustment();
    if (auth.nonce == std.math.maxInt(u64)) return self.invalidAuthorizationGasAdjustment();

    try self.state.warmAccount(auth.signer);

    const existing_account = try self.state.getAccountOrLoad(auth.signer);
    const account_exists = existing_account != null;
    const cur_delegated = if (existing_account) |existing|
        eip7702.delegationTarget(existing.code) != null
    else
        false;
    const pre_delegated = if (pre_delegated_by_authority) |map| blk: {
        if (map.get(auth.signer)) |delegated| break :blk delegated;
        try map.put(auth.signer, cur_delegated);
        break :blk cur_delegated;
    } else cur_delegated;
    if (existing_account) |existing| {
        if (existing.code.len != 0 and !cur_delegated) return self.invalidAuthorizationGasAdjustment();
        if (existing.nonce != auth.nonce) return self.invalidAuthorizationGasAdjustment();
    } else if (auth.nonce != 0) {
        return self.invalidAuthorizationGasAdjustment();
    }

    const account = try self.getOrCreateAccount(auth.signer);

    if (std.mem.eql(u8, &auth.target, &evmz.address.zero_address)) {
        try self.state.clearCode(auth.signer);
    } else {
        var code: [eip7702.delegation_code_len]u8 = undefined;
        eip7702.writeDelegationCode(&code, auth.target);
        try self.state.setCode(auth.signer, &code);
    }
    try self.state.setNonce(auth.signer, account.nonce + 1);
    if (self.spec.isImpl(.amsterdam)) {
        var adjustment = AuthorizationGasAdjustment{};
        if (account_exists) {
            adjustment.add(.{
                .regular_refund = tx_gas.amsterdam_account_write_cost,
                .state_refund = transaction.amsterdam_new_account_state_gas,
            });
        }
        const clears_delegation = std.mem.eql(u8, &auth.target, &evmz.address.zero_address);
        if (clears_delegation) {
            adjustment.add(.{ .state_refund = tx_gas.amsterdam_auth_base_state_gas });
            if (cur_delegated and !pre_delegated) {
                adjustment.add(.{ .state_refund = tx_gas.amsterdam_auth_base_state_gas });
            }
        } else if (cur_delegated or pre_delegated) {
            adjustment.add(.{ .state_refund = tx_gas.amsterdam_auth_base_state_gas });
        }
        return adjustment;
    }
    if (!account_exists) return .{};
    return .{ .regular_refund = transaction.authorization_existing_account_refund_gas };
}

fn invalidAuthorizationGasAdjustment(self: *const Executor) AuthorizationGasAdjustment {
    if (!self.spec.isImpl(.amsterdam)) return .{};
    return .{
        .regular_refund = tx_gas.amsterdam_account_write_cost,
        .state_refund = tx_gas.amsterdam_authorization_state_gas,
    };
}

fn malformedAuthorizationGasAdjustment(self: *const Executor, tx: Transaction) AuthorizationGasAdjustment {
    if (!self.spec.isImpl(.amsterdam)) return .{};
    const total_count = tx.authorizationCount();
    const parsed_count = tx.authorizationList().len;
    if (total_count <= parsed_count) return .{};
    const missing_count = total_count - parsed_count;
    const regular_refund = std.math.mul(u64, tx_gas.amsterdam_account_write_cost, missing_count) catch std.math.maxInt(u64);
    const state_refund = std.math.mul(u64, tx_gas.amsterdam_authorization_state_gas, missing_count) catch std.math.maxInt(u64);
    return .{
        .regular_refund = regular_refund,
        .state_refund = state_refund,
    };
}

fn warmDelegatedTransactionTarget(self: *Executor, tx: Transaction) !void {
    if (!self.spec.isImpl(.prague)) return;
    if (self.spec.isImpl(.amsterdam)) return;
    switch (tx) {
        .call => |call_tx| {
            // EIP-7702 warms the delegate target when the tx destination is delegated.
            const target = eip7702.delegationTarget(try self.getCode(call_tx.recipient)) orelse return;
            try self.warmAccessListAddress(target);
        },
        .create => {},
    }
}

/// Snapshot transient storage for nested execution rollback.
pub fn snapshotTransient(self: *Executor) !TransientSnapshot {
    return self.state.snapshotTransient();
}

/// Restore transient storage from a previous snapshot.
pub fn restoreTransient(self: *Executor, snapshot_state: *TransientSnapshot) !void {
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
pub fn clearLastOutput(self: *Executor) void {
    self.allocator.free(self.last_call_output);
    self.last_call_output = &.{};
}

test "executor init options retain code analysis config" {
    var executor = Executor.init(std.testing.allocator, .{
        .spec = .latest,
        .config = .advanced,
    });
    defer executor.deinit();

    try std.testing.expectEqual(evmz.Config.Preprocessing.full, executor.config.preprocessing);
}

test "executor executes prepared bytecode call transaction" {
    const sender = evmz.addr(0xaaaa);
    const contract = evmz.addr(0xbbbb);
    const tx_context = testTxContext(sender, 100_000);
    var executor = Executor.init(std.testing.allocator, .{
        .spec = .osaka,
    });
    defer executor.deinit();

    var sender_account = AccountState.init(std.testing.allocator);
    sender_account.balance = 1_000_000;
    try executor.state.accounts.put(sender, sender_account);

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
    try std.testing.expect(!bytecode.isAnalyzed());
    try std.testing.expectEqual(@as(u256, 0x2a), try executor.getStorage(contract, 0));
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
    var executor = Executor.init(std.testing.allocator, .{
        .spec = .prague,
        .block_hash_source = block_hashes.source(),
    });
    defer executor.deinit();

    var sender_account = AccountState.init(std.testing.allocator);
    sender_account.balance = 1_000_000;
    try executor.state.accounts.put(sender, sender_account);

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
    var executor = Executor.init(std.testing.allocator, .{
        .spec = .osaka,
    });
    defer executor.deinit();

    var sender_account = AccountState.init(std.testing.allocator);
    sender_account.balance = 1_000_000;
    try executor.state.accounts.put(sender, sender_account);

    var contract_account = AccountState.init(std.testing.allocator);
    try contract_account.setCode(std.testing.allocator, &.{ 0x60, 0x2a, 0x5f, 0x55, 0x00 });
    try executor.state.accounts.put(contract, contract_account);

    try executor.beginTransaction(tx_context, sender, contract);
    const result = (try executor.executeMessage(.{ .call = .{
        .sender = sender,
        .recipient = contract,
        .gas = 100_000,
    } })).expectCall();

    try std.testing.expectEqual(Interpreter.Status.success, result.status);
    try std.testing.expectEqual(@as(u256, 0x2a), try executor.getStorage(contract, 0));
}

test "executor begins normalized transaction scope and warms access list" {
    const sender = evmz.addr(0xaaaa);
    const contract = evmz.addr(0xbbbb);
    const access_address = evmz.addr(0xcccc);
    const coinbase = evmz.addr(0xdddd);
    var tx_context = testTxContext(sender, 100_000);
    tx_context.coinbase = coinbase;
    var executor = Executor.init(std.testing.allocator, .{
        .spec = .shanghai,
    });
    defer executor.deinit();

    const tx = Transaction{ .call = .{
        .sender = sender,
        .recipient = contract,
        .gas_limit = 100_000,
    } };
    try executor.beginTransactionScope(tx_context, tx);
    defer executor.closeTransaction();

    const storage_keys = [_]u256{ 1, 2 };
    const access_list = [_]transaction.AccessListEntry{.{
        .address = access_address,
        .storage_keys = &storage_keys,
    }};
    try executor.warmAccessList(&access_list);

    try std.testing.expect(executor.state.warm_accounts.contains(sender));
    try std.testing.expect(executor.state.warm_accounts.contains(contract));
    try std.testing.expect(executor.state.warm_accounts.contains(coinbase));
    try std.testing.expect(executor.state.warm_accounts.contains(access_address));
    try std.testing.expect(executor.state.warm_storage.contains(.{ .address = access_address, .key = 1 }));
    try std.testing.expect(executor.state.warm_storage.contains(.{ .address = access_address, .key = 2 }));
}

test "executor executeTransactionMessage dispatches normalized call" {
    const sender = evmz.addr(0xaaaa);
    const contract = evmz.addr(0xbbbb);
    const tx_context = testTxContext(sender, 100_000);
    var executor = Executor.init(std.testing.allocator, .{
        .spec = .osaka,
    });
    defer executor.deinit();

    var sender_account = AccountState.init(std.testing.allocator);
    sender_account.balance = 1_000_000;
    try executor.state.accounts.put(sender, sender_account);

    var contract_account = AccountState.init(std.testing.allocator);
    try contract_account.setCode(std.testing.allocator, &.{ 0x60, 0x2a, 0x5f, 0x55, 0x00 });
    try executor.state.accounts.put(contract, contract_account);

    const tx = Transaction{ .call = .{
        .sender = sender,
        .recipient = contract,
        .gas_limit = 100_000,
    } };
    try executor.beginTransactionScope(tx_context, tx);
    const result = try executor.executeTransactionMessage(tx, .legacy(100_000));

    try std.testing.expectEqual(Interpreter.Status.success, result.status);
    try std.testing.expectEqual(@as(u256, 0x2a), try executor.getStorage(contract, 0));
}

test "executor settleTransactionCosts applies refund and coinbase payment" {
    const sender = evmz.addr(0xaaaa);
    const coinbase = evmz.addr(0xbbbb);
    var executor = Executor.init(std.testing.allocator, .{
        .spec = .london,
    });
    defer executor.deinit();

    try executor.settleTransactionCosts(sender, .{
        .spec = .london,
        .gas_limit = 100,
        .intrinsic_gas = 20,
        .intrinsic_state_gas = 0,
        .floor_gas = 0,
        .gas_price = 5,
        .priority_fee = 2,
        .coinbase = coinbase,
    }, .{
        .status = .success,
        .gas_left = 40,
        .gas_refund = 100,
        .output_data = &.{},
    });

    try std.testing.expectEqual(@as(u256, 260), executor.getAccount(sender).?.balance);
    try std.testing.expectEqual(@as(u256, 96), executor.getAccount(coinbase).?.balance);
}

test "executor returns EIP-7702 refund for existing authority account" {
    const sender = evmz.addr(0xaaaa);
    const authority = evmz.addr(0xbbbb);
    const target = evmz.addr(0xcccc);
    const tx_context = testTxContext(sender, 100_000);
    var executor = Executor.init(std.testing.allocator, .{
        .spec = .prague,
    });
    defer executor.deinit();

    const authority_account = AccountState.init(std.testing.allocator);
    try executor.state.accounts.put(authority, authority_account);

    try executor.beginTransaction(tx_context, sender, target);
    defer executor.closeTransaction();

    const refund = try executor.applyAuthorizationTuple(.{
        .chain_id = 0,
        .target = target,
        .signer = authority,
        .nonce = 0,
        .y_parity = 0,
        .legacy_v = null,
        .r = 1,
        .s = 1,
    });

    try std.testing.expectEqual(@as(u64, transaction.authorization_existing_account_refund_gas), refund.regular_refund);
    try std.testing.expectEqual(@as(u64, 0), refund.state_refund);
    try std.testing.expectEqual(@as(u64, 1), executor.getAccount(authority).?.nonce);
    try std.testing.expectEqualSlices(u8, &target, &eip7702.delegationTarget(executor.getAccount(authority).?.code).?);
}

test "executor rejects EIP-7702 max authorization nonce before warming signer" {
    const sender = evmz.addr(0xaaaa);
    const recipient = evmz.addr(0xbbbb);
    const authority = evmz.addr(0xcccc);
    const target = evmz.addr(0xdddd);
    const tx_context = testTxContext(sender, 100_000);
    var executor = Executor.init(std.testing.allocator, .{
        .spec = .prague,
    });
    defer executor.deinit();

    var authority_account = AccountState.init(std.testing.allocator);
    authority_account.nonce = std.math.maxInt(u64);
    try executor.state.accounts.put(authority, authority_account);

    try executor.beginTransaction(tx_context, sender, recipient);
    defer executor.closeTransaction();

    const refund = try executor.applyAuthorizationTuple(.{
        .chain_id = 0,
        .target = target,
        .signer = authority,
        .nonce = std.math.maxInt(u64),
        .y_parity = 0,
        .legacy_v = null,
        .r = 1,
        .s = 1,
    });

    try std.testing.expectEqual(@as(u64, 0), refund.regular_refund);
    try std.testing.expectEqual(@as(u64, 0), refund.state_refund);
    try std.testing.expect(!executor.state.warm_accounts.contains(authority));
    try std.testing.expectEqual(std.math.maxInt(u64), executor.getAccount(authority).?.nonce);
    try std.testing.expectEqual(@as(usize, 0), executor.getAccount(authority).?.code.len);
}

test "executor top-level transaction settles EIP-7702 authorization refund" {
    const sender = evmz.addr(0xaaaa);
    const recipient = evmz.addr(0xbbbb);
    const authority = evmz.addr(0xcccc);
    const target = evmz.addr(0xdddd);
    var tx_context = testTxContext(sender, 100_000);
    tx_context.gas_price = 1;
    var executor = Executor.init(std.testing.allocator, .{
        .spec = .prague,
    });
    defer executor.deinit();

    var sender_account = AccountState.init(std.testing.allocator);
    sender_account.balance = 1_000_000;
    try executor.state.accounts.put(sender, sender_account);

    const authority_account = AccountState.init(std.testing.allocator);
    try executor.state.accounts.put(authority, authority_account);

    const authorization_list = [_]transaction.AuthorizationTuple{.{
        .chain_id = 0,
        .target = target,
        .signer = authority,
        .nonce = 0,
        .y_parity = 0,
        .legacy_v = null,
        .r = 1,
        .s = 1,
    }};
    const tx = Transaction{ .call = .{
        .sender = sender,
        .recipient = recipient,
        .gas_limit = 100_000,
        .authorization_list = &authorization_list,
    } };

    const SucceedingEngine = struct {
        fn execute(
            ptr: ?*anyopaque,
            inner: *Executor,
            normalized_tx: Transaction,
            gas: transaction.ExecutionGas,
        ) !Interpreter.Result {
            _ = ptr;
            _ = inner;
            _ = normalized_tx;
            try std.testing.expectEqual(@as(u64, 54_000), gas.regular_left);
            return .{
                .status = .success,
                .gas_left = 54_000,
                .gas_refund = 0,
                .output_data = &.{},
            };
        }
    };

    try executor.beginTransactionScope(tx_context, tx);
    const result = try executor.runTopLevelTransactionWithEngine(tx, .{
        .execution_gas = 54_000,
        .settlement = .{
            .spec = .prague,
            .gas_limit = 100_000,
            .intrinsic_gas = 46_000,
            .intrinsic_state_gas = 0,
            .floor_gas = 21_000,
            .gas_price = 1,
            .priority_fee = 0,
            .coinbase = tx_context.coinbase,
        },
    }, .{ .execute = SucceedingEngine.execute });

    try std.testing.expectEqual(Interpreter.Status.success, result.status);
    try std.testing.expectEqual(@as(i64, 12_500), result.gas_refund);
    try std.testing.expectEqual(@as(u256, 963_200), executor.getAccount(sender).?.balance);
}

test "top-level engine errors roll back without gas settlement" {
    const sender = evmz.addr(0xaaaa);
    const recipient = evmz.addr(0xbbbb);
    var tx_context = testTxContext(sender, 100_000);
    tx_context.gas_price = 1;
    var executor = Executor.init(std.testing.allocator, .{
        .spec = .prague,
    });
    defer executor.deinit();

    var sender_account = AccountState.init(std.testing.allocator);
    sender_account.balance = 1_000_000;
    sender_account.nonce = 7;
    try executor.state.accounts.put(sender, sender_account);

    const tx = Transaction{ .call = .{
        .sender = sender,
        .recipient = recipient,
        .gas_limit = 100_000,
    } };
    const FailingEngine = struct {
        fn execute(
            ptr: ?*anyopaque,
            inner: *Executor,
            normalized_tx: Transaction,
            gas: transaction.ExecutionGas,
        ) !Interpreter.Result {
            _ = ptr;
            _ = inner;
            _ = normalized_tx;
            _ = gas;
            return error.DatabaseUnavailable;
        }
    };

    try executor.beginTransactionScope(tx_context, tx);
    try std.testing.expectError(
        error.DatabaseUnavailable,
        executor.runTopLevelTransactionWithEngine(tx, .{
            .execution_gas = 79_000,
            .settlement = .{
                .spec = .prague,
                .gas_limit = 100_000,
                .intrinsic_gas = 21_000,
                .intrinsic_state_gas = 0,
                .floor_gas = 21_000,
                .gas_price = 1,
                .priority_fee = 0,
                .coinbase = tx_context.coinbase,
            },
        }, .{ .execute = FailingEngine.execute }),
    );

    const restored_sender = executor.getAccount(sender).?;
    try std.testing.expectEqual(@as(u256, 1_000_000), restored_sender.balance);
    try std.testing.expectEqual(@as(u64, 7), restored_sender.nonce);
    try std.testing.expectEqual(null, executor.tx_context);
    try std.testing.expectEqual(@as(u32, 0), executor.state.warm_accounts.count());
}

test "Amsterdam malformed authorization count refills intrinsic auth gas" {
    const sender = evmz.addr(0xaaaa);
    const recipient = evmz.addr(0xbbbb);
    var tx_context = testTxContext(sender, 300_000);
    tx_context.gas_price = 1;
    var executor = Executor.init(std.testing.allocator, .{
        .spec = .amsterdam,
    });
    defer executor.deinit();

    var sender_account = AccountState.init(std.testing.allocator);
    sender_account.balance = 1_000_000;
    try executor.state.accounts.put(sender, sender_account);

    const tx = Transaction{ .call = .{
        .sender = sender,
        .recipient = recipient,
        .gas_limit = 300_000,
        .authorization_count = 1,
    } };
    const gas_plan = transaction.gasPlan(.amsterdam, &.{}, tx.gasLimit(), .{
        .authorization_count = tx.authorizationCount(),
    });

    const SucceedingEngine = struct {
        fn execute(
            ptr: ?*anyopaque,
            inner: *Executor,
            normalized_tx: Transaction,
            gas: transaction.ExecutionGas,
        ) !Interpreter.Result {
            _ = ptr;
            _ = inner;
            _ = normalized_tx;
            return .{
                .status = .success,
                .gas_left = std.math.cast(i64, gas.regular_left) orelse std.math.maxInt(i64),
                .gas_refund = 0,
                .gas_reservoir = std.math.cast(i64, gas.reservoir) orelse std.math.maxInt(i64),
                .output_data = &.{},
            };
        }
    };

    try executor.beginTransactionScope(tx_context, tx);
    const result = try executor.runTopLevelTransactionWithEngine(tx, .{
        .execution = gas_plan.execution,
        .settlement = transaction.settlementFromGasPlan(.amsterdam, tx.gasLimit(), gas_plan, .{
            .gas_price = tx_context.gas_price,
            .priority_fee = 0,
            .coinbase = tx_context.coinbase,
        }),
    }, .{ .execute = SucceedingEngine.execute });

    try std.testing.expectEqual(Interpreter.Status.success, result.status);
    try std.testing.expectEqual(@as(i64, tx_gas.amsterdam_account_write_cost), result.gas_refund);
    try std.testing.expectEqual(-@as(i64, tx_gas.amsterdam_authorization_state_gas), result.state_gas_spent);
}

test "executor warms delegated target for top-level transaction destination" {
    const sender = evmz.addr(0xaaaa);
    const authority = evmz.addr(0xbbbb);
    const target = evmz.addr(0xcccc);
    const tx_context = testTxContext(sender, 100_000);
    var executor = Executor.init(std.testing.allocator, .{
        .spec = .prague,
    });
    defer executor.deinit();

    var sender_account = AccountState.init(std.testing.allocator);
    sender_account.balance = 1_000_000;
    try executor.state.accounts.put(sender, sender_account);

    const authorization_list = [_]transaction.AuthorizationTuple{.{
        .chain_id = 0,
        .target = target,
        .signer = authority,
        .nonce = 0,
        .y_parity = 0,
        .legacy_v = null,
        .r = 1,
        .s = 1,
    }};
    const tx = Transaction{ .call = .{
        .sender = sender,
        .recipient = authority,
        .gas_limit = 100_000,
        .authorization_list = &authorization_list,
    } };

    const CheckingEngine = struct {
        const expected_target = evmz.addr(0xcccc);

        fn execute(
            ptr: ?*anyopaque,
            inner: *Executor,
            normalized_tx: Transaction,
            gas: transaction.ExecutionGas,
        ) !Interpreter.Result {
            _ = ptr;
            _ = normalized_tx;
            try std.testing.expectEqual(@as(u64, 54_000), gas.regular_left);
            try std.testing.expect(inner.state.warm_accounts.contains(expected_target));
            return .{
                .status = .success,
                .gas_left = 54_000,
                .gas_refund = 0,
                .output_data = &.{},
            };
        }
    };

    try executor.beginTransactionScope(tx_context, tx);
    const result = try executor.runTopLevelTransactionWithEngine(tx, .{
        .execution_gas = 54_000,
        .settlement = .{
            .spec = .prague,
            .gas_limit = 100_000,
            .intrinsic_gas = 46_000,
            .intrinsic_state_gas = 0,
            .floor_gas = 21_000,
            .gas_price = 0,
            .priority_fee = 0,
            .coinbase = tx_context.coinbase,
        },
    }, .{ .execute = CheckingEngine.execute });

    try std.testing.expectEqual(Interpreter.Status.success, result.status);
    try std.testing.expectEqualSlices(u8, &target, &eip7702.delegationTarget(executor.getAccount(authority).?.code).?);
}

test "Prague top-level delegated precompile call can use exactly intrinsic gas" {
    const sender = evmz.addr(0xaaaa);
    const authority = evmz.addr(0xbbbb);
    const precompile_address = evmz.addr(1);
    const tx_context = testTxContext(sender, 46_000);
    var executor = Executor.init(std.testing.allocator, .{
        .spec = .prague,
    });
    defer executor.deinit();

    var sender_account = AccountState.init(std.testing.allocator);
    sender_account.balance = 1_000_000;
    try executor.state.accounts.put(sender, sender_account);

    var authority_account = AccountState.init(std.testing.allocator);
    authority_account.balance = 1;
    try executor.state.accounts.put(authority, authority_account);

    const authorization_list = [_]transaction.AuthorizationTuple{.{
        .chain_id = 0,
        .target = precompile_address,
        .signer = authority,
        .nonce = 0,
        .y_parity = 0,
        .legacy_v = null,
        .r = 1,
        .s = 1,
    }};
    const tx = Transaction{ .call = .{
        .sender = sender,
        .recipient = authority,
        .gas_limit = 46_000,
        .value = 1,
        .authorization_list = &authorization_list,
    } };
    const gas_plan = transaction.gasPlan(.prague, &.{}, tx.gasLimit(), .{
        .authorization_count = authorization_list.len,
        .value = tx.value(),
    });

    try executor.beginTransactionScope(tx_context, tx);
    const result = try executor.runTopLevelTransaction(tx, .{
        .execution = gas_plan.execution,
        .settlement = transaction.settlementFromGasPlan(.prague, tx.gasLimit(), gas_plan, .{
            .gas_price = 0,
            .priority_fee = 0,
            .coinbase = tx_context.coinbase,
        }),
    });

    try std.testing.expectEqual(Interpreter.Status.success, result.status);
    try std.testing.expectEqual(@as(i64, 0), result.gas_left);
    try std.testing.expectEqual(@as(u256, 2), executor.getAccount(authority).?.balance);
    try std.testing.expectEqualSlices(u8, &precompile_address, &eip7702.delegationTarget(executor.getAccount(authority).?.code).?);
}

test "executor runTopLevelTransaction commits successful call" {
    const sender = evmz.addr(0xaaaa);
    const contract = evmz.addr(0xbbbb);
    const tx_context = testTxContext(sender, 100_000);
    var executor = Executor.init(std.testing.allocator, .{
        .spec = .osaka,
    });
    defer executor.deinit();

    var sender_account = AccountState.init(std.testing.allocator);
    sender_account.balance = 1_000_000;
    try executor.state.accounts.put(sender, sender_account);

    var contract_account = AccountState.init(std.testing.allocator);
    try contract_account.setCode(std.testing.allocator, &.{ 0x60, 0x2a, 0x5f, 0x55, 0x00 });
    try executor.state.accounts.put(contract, contract_account);

    const tx = Transaction{ .call = .{
        .sender = sender,
        .recipient = contract,
        .gas_limit = 100_000,
    } };
    try executor.beginTransactionScope(tx_context, tx);
    const result = try executor.runTopLevelTransaction(tx, .{
        .execution_gas = 100_000,
        .settlement = .{
            .spec = .osaka,
            .gas_limit = 100_000,
            .intrinsic_gas = 21_000,
            .intrinsic_state_gas = 0,
            .floor_gas = 21_000,
            .gas_price = 0,
            .priority_fee = 0,
            .coinbase = tx_context.coinbase,
        },
    });

    try std.testing.expectEqual(Interpreter.Status.success, result.status);
    try std.testing.expectEqual(@as(u64, 1), executor.getAccount(sender).?.nonce);
    try std.testing.expectEqual(@as(u256, 0x2a), try executor.getStorage(contract, 0));
    try std.testing.expectEqual(@as(?Host.TxContext, null), executor.tx_context);
}

test "executor runTopLevelTransaction increments create nonce after rollback" {
    const sender = evmz.addr(0xaaaa);
    const tx_context = testTxContext(sender, 100_000);
    var executor = Executor.init(std.testing.allocator, .{
        .spec = .osaka,
    });
    defer executor.deinit();

    var sender_account = AccountState.init(std.testing.allocator);
    sender_account.balance = 1_000_000;
    try executor.state.accounts.put(sender, sender_account);

    const tx = Transaction{ .create = .{
        .sender = sender,
        .init_code = &.{0xfe},
        .gas_limit = 100_000,
    } };
    try executor.beginTransactionScope(tx_context, tx);
    const result = try executor.runTopLevelTransaction(tx, .{
        .execution_gas = 100_000,
        .settlement = .{
            .spec = .osaka,
            .gas_limit = 100_000,
            .intrinsic_gas = 53_000,
            .intrinsic_state_gas = 0,
            .floor_gas = 21_000,
            .gas_price = 0,
            .priority_fee = 0,
            .coinbase = tx_context.coinbase,
        },
    });

    try std.testing.expectEqual(Interpreter.Status.invalid, result.status);
    try std.testing.expectEqual(@as(u64, 1), executor.getAccount(sender).?.nonce);
    try std.testing.expectEqual(@as(?Host.TxContext, null), executor.tx_context);
}

test "recursive call bomb unwinds with default executor" {
    const sender = evmz.addr(0x371c4d94cf9ed2e0cde964a748609b7c46ec3811);
    const contract = evmz.addr(0xd83874a1c62a78b10ae86b27b59b21c4d34f6d30);
    const tx_context = testTxContext(sender, 1_000_000);
    var executor = Executor.init(std.testing.allocator, .{
        .spec = .cancun,
    });
    defer executor.deinit();

    var sender_account = AccountState.init(std.testing.allocator);
    sender_account.balance = 1_000_000_000_000_000_000;
    try executor.state.accounts.put(sender, sender_account);

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
    var contract_account = AccountState.init(std.testing.allocator);
    contract_account.balance = 20_000_000;
    try contract_account.setCode(std.testing.allocator, &code);
    try executor.state.accounts.put(contract, contract_account);

    try executor.beginTransaction(tx_context, sender, contract);
    const result = try executor.executeCallTransaction(sender, contract, &.{}, .legacy(979_000), 100_000);

    try std.testing.expectEqual(Interpreter.Status.success, result.status);
    try std.testing.expectEqual(@as(u256, 0x12), try executor.getStorage(contract, 0));
    try std.testing.expectEqual(@as(u256, 1), try executor.getStorage(contract, 1));
}

test "recursive call bomb unwinds with iterative call runtime" {
    const sender = evmz.addr(0x371c4d94cf9ed2e0cde964a748609b7c46ec3811);
    const contract = evmz.addr(0xd83874a1c62a78b10ae86b27b59b21c4d34f6d30);
    const tx_context = testTxContext(sender, 1_000_000);
    var executor = Executor.init(std.testing.allocator, .{
        .spec = .cancun,
    });
    defer executor.deinit();

    var sender_account = AccountState.init(std.testing.allocator);
    sender_account.balance = 1_000_000_000_000_000_000;
    try executor.state.accounts.put(sender, sender_account);

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
    var contract_account = AccountState.init(std.testing.allocator);
    contract_account.balance = 20_000_000;
    try contract_account.setCode(std.testing.allocator, &code);
    try executor.state.accounts.put(contract, contract_account);

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
    var executor = Executor.init(std.testing.allocator, .{
        .spec = .cancun,
    });
    defer executor.deinit();

    var sender_account = AccountState.init(std.testing.allocator);
    sender_account.balance = 1_000_000_000_000_000_000;
    try executor.state.accounts.put(sender, sender_account);

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
    var contract_account = AccountState.init(std.testing.allocator);
    try contract_account.setCode(std.testing.allocator, &code);
    try executor.state.accounts.put(contract, contract_account);

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
    var executor = Executor.init(std.testing.allocator, .{
        .spec = .cancun,
    });
    defer executor.deinit();

    var sender_account = AccountState.init(std.testing.allocator);
    sender_account.balance = 1_000_000;
    try executor.state.accounts.put(sender, sender_account);

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
        spec: evmz.Spec,
        materialized: bool,
        gas_left: i64,
    }{
        .{ .spec = .frontier, .materialized = true, .gas_left = 64_922 },
        .{ .spec = .spurious_dragon, .materialized = false, .gas_left = 89_262 },
    };

    for (cases) |case| {
        const tx_context = testTxContext(sender, 100_000);
        var executor = Executor.init(std.testing.allocator, .{
            .spec = case.spec,
        });
        defer executor.deinit();

        var sender_account = AccountState.init(std.testing.allocator);
        sender_account.balance = 1_000_000_000_000_000_000;
        try executor.state.accounts.put(sender, sender_account);

        var contract_account = AccountState.init(std.testing.allocator);
        try contract_account.setCode(std.testing.allocator, &code);
        try executor.state.accounts.put(contract, contract_account);

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

    var executor = Executor.init(std.testing.allocator, .{
        .spec = .cancun,
    });
    defer executor.deinit();

    var sender_account = AccountState.init(std.testing.allocator);
    sender_account.balance = 1_000_000_000_000_000_000;
    try executor.state.accounts.put(sender, sender_account);

    var contract_account = AccountState.init(std.testing.allocator);
    try contract_account.setCode(std.testing.allocator, &code);
    try executor.state.accounts.put(contract, contract_account);

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

    var executor = Executor.init(std.testing.allocator, .{
        .spec = .cancun,
    });
    defer executor.deinit();

    var sender_account = AccountState.init(std.testing.allocator);
    sender_account.balance = 1_000_000_000_000_000_000;
    try executor.state.accounts.put(sender, sender_account);

    var contract_account = AccountState.init(std.testing.allocator);
    try contract_account.setCode(std.testing.allocator, &code);
    try executor.state.accounts.put(contract, contract_account);

    var target_account = AccountState.init(std.testing.allocator);
    try target_account.setCode(std.testing.allocator, &target_code);
    try executor.state.accounts.put(target, target_account);

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

    var executor = Executor.init(std.testing.allocator, .{
        .spec = .cancun,
    });
    defer executor.deinit();

    var sender_account = AccountState.init(std.testing.allocator);
    sender_account.balance = 1_000_000_000_000_000_000;
    try executor.state.accounts.put(sender, sender_account);

    var contract_account = AccountState.init(std.testing.allocator);
    try contract_account.setCode(std.testing.allocator, &code);
    try executor.state.accounts.put(contract, contract_account);

    var target_account = AccountState.init(std.testing.allocator);
    try target_account.setCode(std.testing.allocator, &target_code);
    try executor.state.accounts.put(target, target_account);

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

    var executor = Executor.init(std.testing.allocator, .{
        .spec = .cancun,
    });
    defer executor.deinit();

    var sender_account = AccountState.init(std.testing.allocator);
    sender_account.balance = 1_000_000_000_000_000_000;
    try executor.state.accounts.put(sender, sender_account);

    var contract_account = AccountState.init(std.testing.allocator);
    try contract_account.setCode(std.testing.allocator, &code);
    try executor.state.accounts.put(contract, contract_account);

    var target_account = AccountState.init(std.testing.allocator);
    try target_account.setCode(std.testing.allocator, &target_code);
    try executor.state.accounts.put(target, target_account);

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

    var executor = Executor.init(std.testing.allocator, .{
        .spec = .cancun,
    });
    defer executor.deinit();

    var sender_account = AccountState.init(std.testing.allocator);
    sender_account.balance = 1_000_000_000_000_000_000;
    try executor.state.accounts.put(sender, sender_account);

    var contract_account = AccountState.init(std.testing.allocator);
    try contract_account.setCode(std.testing.allocator, &code);
    try executor.state.accounts.put(contract, contract_account);

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
    try std.testing.expectEqualSlices(u8, &.{0x00}, executor.getAccount(create_address).?.code);
    try std.testing.expectEqualSlices(u8, &.{0x00}, executor.getAccount(create2_address).?.code);
}

test "CREATE2 insufficient balance does not bump creator nonce" {
    const sender = evmz.addr(0x0343505c9f9bda06ff73c96183434ffd23442073);
    const contract = evmz.addr(0xbba624a7e00e22fd18816e2e0e1f4f396ce3409c);
    const tx_context = testTxContext(sender, 100_000);
    const create2_address = evmz.address.create2(contract, 0, &.{});
    const code = evmz.t.bytecode(.{
        .PUSH0, .PUSH0, .PUSH0, .GAS, .CREATE2, .STOP,
    });

    var executor = Executor.init(std.testing.allocator, .{
        .spec = .cancun,
    });
    defer executor.deinit();

    var sender_account = AccountState.init(std.testing.allocator);
    sender_account.balance = 1_000_000;
    try executor.state.accounts.put(sender, sender_account);

    var contract_account = AccountState.init(std.testing.allocator);
    contract_account.nonce = 1;
    try contract_account.setCode(std.testing.allocator, &code);
    try executor.state.accounts.put(contract, contract_account);

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

test "iterative trace ends call and create steps after child resume" {
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
    var recorder = StepOrderRecorder{};
    var sink = recorder.sink();
    var executor = Executor.init(std.testing.allocator, .{
        .spec = .cancun,
        .trace_sink = &sink,
    });
    defer executor.deinit();

    var sender_account = AccountState.init(std.testing.allocator);
    sender_account.balance = 1_000_000_000_000_000_000;
    try executor.state.accounts.put(sender, sender_account);

    var contract_account = AccountState.init(std.testing.allocator);
    try contract_account.setCode(std.testing.allocator, &code);
    try executor.state.accounts.put(contract, contract_account);

    var child_account = AccountState.init(std.testing.allocator);
    try child_account.setCode(std.testing.allocator, &.{@intFromEnum(evmz.Opcode.STOP)});
    try executor.state.accounts.put(child, child_account);

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
    const call_start = recorder.firstIndex(.start, .CALL, 0).?;
    const call_end = recorder.firstIndex(.end, .CALL, 0).?;
    try std.testing.expect(call_start < call_end);
    try std.testing.expect(recorder.hasDepthStartBetween(1, call_start, call_end));
    try std.testing.expectEqual(@as(u256, 1), recorder.events[call_end].stack_top.?);

    const create_start = recorder.firstIndex(.start, .CREATE, 0).?;
    const create_end = recorder.firstIndex(.end, .CREATE, 0).?;
    try std.testing.expect(create_start < create_end);
    try std.testing.expect(recorder.hasDepthStartBetween(1, create_start, create_end));
    try std.testing.expectEqual(evmz.address.toU256(create_address), recorder.events[create_end].stack_top.?);
}

test "top-level transaction execution requires begin tx context" {
    var executor = Executor.init(std.testing.allocator, .{
        .spec = .berlin,
    });
    defer executor.deinit();

    try std.testing.expectError(
        error.MissingTxContext,
        executor.executeCallTransaction(evmz.addr(0xaaaa), evmz.addr(0xbbbb), &.{}, .legacy(100_000), 0),
    );
    var amsterdam_executor = Executor.init(std.testing.allocator, .{
        .spec = .amsterdam,
    });
    defer amsterdam_executor.deinit();
    try std.testing.expectError(
        error.MissingTxContext,
        amsterdam_executor.executeCallTransaction(evmz.addr(0xaaaa), evmz.addr(0xbbbb), &.{}, .{
            .regular_left = transaction.amsterdam_new_account_state_gas - 1,
        }, 1),
    );
    try std.testing.expectError(
        error.MissingTxContext,
        executor.executeCreateTransaction(evmz.addr(0xaaaa), &.{}, .legacy(100_000), 0),
    );
    try std.testing.expectError(
        error.MissingTxContext,
        executor.executeCall(.{
            .sender = evmz.addr(0xaaaa),
            .recipient = evmz.addr(0xbbbb),
            .gas = 100_000,
        }),
    );
    try std.testing.expectError(
        error.MissingTxContext,
        executor.executeCreate(.{
            .sender = evmz.addr(0xaaaa),
            .init_code = &.{},
            .gas = 100_000,
        }),
    );
}

test "rollback transaction restores snapshot and closes tx context" {
    const sender = evmz.addr(0xaaaa);
    const contract = evmz.addr(0xbbbb);
    const tx_context = testTxContext(sender, 100_000);
    var executor = Executor.init(std.testing.allocator, .{
        .spec = .berlin,
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
    try std.testing.expect(executor.tx_context == null);
}

test "executor executes top-level create transaction" {
    const sender = evmz.addr(0xaaaa);
    const tx_context = testTxContext(sender, 100_000);
    var executor = Executor.init(std.testing.allocator, .{
        .spec = .berlin,
    });
    defer executor.deinit();

    var sender_account = AccountState.init(std.testing.allocator);
    sender_account.balance = 1_000_000;
    try executor.state.accounts.put(sender, sender_account);

    const init_code = &.{ 0x60, 0x00, 0x60, 0x00, 0x53, 0x60, 0x01, 0x60, 0x00, 0xf3 };
    const create_address = evmz.address.create(sender, 0);

    try executor.beginCreateTransaction(tx_context, sender);
    const result = (try executor.executeCreate(.{
        .sender = sender,
        .init_code = init_code,
        .gas = 100_000,
    })).expectCreate();

    try std.testing.expectEqual(Interpreter.Status.success, result.status);
    try std.testing.expectEqualSlices(u8, &create_address, &result.address);
    try std.testing.expectEqual(@as(u64, 1), executor.getAccount(sender).?.nonce);
    try std.testing.expectEqualSlices(u8, &.{0x00}, executor.getAccount(create_address).?.code);
}

fn expectTransferLog(event_log: Host.Log, from: Address, to: Address, amount: u256) !void {
    try std.testing.expectEqualSlices(u8, &system_contracts.system_address, &event_log.address);
    try std.testing.expectEqual(@as(usize, 3), event_log.topics.len);
    try std.testing.expectEqual(transfer_logs.transfer_topic, event_log.topics[0]);
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
    var executor = Executor.init(std.testing.allocator, .{
        .spec = .amsterdam,
    });
    defer executor.deinit();

    var sender_account = AccountState.init(std.testing.allocator);
    sender_account.balance = 1_000_000;
    try executor.state.accounts.put(sender, sender_account);

    try executor.beginTransaction(testTxContext(sender, 100_000), sender, recipient);
    const result = try executor.executeCallTransaction(sender, recipient, &.{}, .{
        .regular_left = 50_000,
        .reservoir = transaction.amsterdam_new_account_state_gas,
    }, 7);

    try std.testing.expectEqual(Interpreter.Status.success, result.status);
    try std.testing.expectEqual(@as(usize, 1), executor.logs().len);
    try expectTransferLog(executor.logs()[0], sender, recipient, 7);
}

test "Osaka value transaction does not emit transfer log" {
    const sender = evmz.addr(0xaaaa);
    const recipient = evmz.addr(0xbbbb);
    var executor = Executor.init(std.testing.allocator, .{
        .spec = .osaka,
    });
    defer executor.deinit();

    var sender_account = AccountState.init(std.testing.allocator);
    sender_account.balance = 1_000_000;
    try executor.state.accounts.put(sender, sender_account);

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

    var executor = Executor.init(std.testing.allocator, .{
        .spec = .amsterdam,
    });
    defer executor.deinit();

    var sender_account = AccountState.init(std.testing.allocator);
    sender_account.balance = 1_000_000;
    try executor.state.accounts.put(sender, sender_account);

    var contract_account = AccountState.init(std.testing.allocator);
    contract_account.balance = 100;
    try contract_account.setCode(std.testing.allocator, &code);
    try executor.state.accounts.put(contract, contract_account);

    const result = (try executor.runStandalone(testTxContext(sender, 100_000), .{ .call = .{
        .sender = sender,
        .recipient = contract,
        .gas = 90_000,
        .gas_reservoir = transaction.amsterdam_new_account_state_gas,
    } })).expectCall();

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

    var executor = Executor.init(std.testing.allocator, .{
        .spec = .amsterdam,
    });
    defer executor.deinit();

    var sender_account = AccountState.init(std.testing.allocator);
    sender_account.balance = 1_000_000;
    try executor.state.accounts.put(sender, sender_account);

    var contract_account = AccountState.init(std.testing.allocator);
    contract_account.balance = 100;
    try contract_account.setCode(std.testing.allocator, &code);
    try executor.state.accounts.put(contract, contract_account);

    try executor.beginTransaction(testTxContext(sender, 100_000), sender, contract);
    const result = try executor.executeCallTransaction(sender, contract, &.{}, .{
        .regular_left = 90_000,
        .reservoir = transaction.amsterdam_new_account_state_gas,
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

    var executor = Executor.init(std.testing.allocator, .{
        .spec = .amsterdam,
    });
    defer executor.deinit();

    var sender_account = AccountState.init(std.testing.allocator);
    sender_account.balance = 1_000_000;
    try executor.state.accounts.put(sender, sender_account);

    var contract_account = AccountState.init(std.testing.allocator);
    contract_account.balance = 7;
    try contract_account.setCode(std.testing.allocator, &code);
    try executor.state.accounts.put(contract, contract_account);

    try executor.beginTransaction(testTxContext(sender, 100_000), sender, contract);
    const result = try executor.executeCallTransaction(sender, contract, &.{}, .{
        .regular_left = 90_000,
        .reservoir = transaction.amsterdam_new_account_state_gas,
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

fn putFundedSender(executor: *Executor, sender: Address) !void {
    var sender_account = AccountState.init(std.testing.allocator);
    sender_account.balance = 100_000_000;
    try executor.state.accounts.put(sender, sender_account);
}

test "Amsterdam raises create runtime code size limit" {
    const sender = evmz.addr(0xaaaa);
    const tx_context = testTxContext(sender, 20_000_000);
    const oversized_osaka = initCodeReturningRuntimeSize(Executor.max_code_size + 1);
    const oversized_amsterdam = initCodeReturningRuntimeSize(Executor.amsterdam_max_code_size + 1);

    var osaka = Executor.init(std.testing.allocator, .{
        .spec = .osaka,
    });
    defer osaka.deinit();
    try putFundedSender(&osaka, sender);

    const osaka_result = (try osaka.runStandalone(tx_context, .{ .create = .{
        .sender = sender,
        .init_code = &oversized_osaka,
        .gas = 20_000_000,
    } })).expectCreate();
    try std.testing.expectEqual(Interpreter.Status.out_of_gas, osaka_result.status);

    var amsterdam = Executor.init(std.testing.allocator, .{
        .spec = .amsterdam,
    });
    defer amsterdam.deinit();
    try putFundedSender(&amsterdam, sender);

    const amsterdam_result = (try amsterdam.runStandalone(tx_context, .{ .create = .{
        .sender = sender,
        .init_code = &oversized_osaka,
        .gas = 20_000_000,
        .gas_reservoir = tx_gas.amsterdam_new_account_state_gas + (Executor.max_code_size + 1) * tx_gas.amsterdam_cost_per_state_byte,
    } })).expectCreate();
    try std.testing.expectEqual(Interpreter.Status.success, amsterdam_result.status);
    try std.testing.expectEqualSlices(u8, &evmz.address.create(sender, 0), &amsterdam_result.address);
    try std.testing.expectEqual(@as(usize, Executor.max_code_size + 1), amsterdam.getAccount(amsterdam_result.address).?.code.len);

    var amsterdam_over = Executor.init(std.testing.allocator, .{
        .spec = .amsterdam,
    });
    defer amsterdam_over.deinit();
    try putFundedSender(&amsterdam_over, sender);

    const amsterdam_over_result = (try amsterdam_over.runStandalone(tx_context, .{ .create = .{
        .sender = sender,
        .init_code = &oversized_amsterdam,
        .gas = 20_000_000,
    } })).expectCreate();
    try std.testing.expectEqual(Interpreter.Status.out_of_gas, amsterdam_over_result.status);
}

test "create warms created address from Berlin" {
    const sender = evmz.addr(0xaaaa);
    const tx_context = testTxContext(sender, 100_000);
    var executor = Executor.init(std.testing.allocator, .{
        .spec = .berlin,
    });
    defer executor.deinit();

    var sender_account = AccountState.init(std.testing.allocator);
    sender_account.balance = 1_000_000;
    try executor.state.accounts.put(sender, sender_account);

    try executor.beginCreateTransaction(tx_context, sender);

    const init_code = &.{ 0x60, 0x00, 0x60, 0x00, 0xf3 };
    const create_address = evmz.address.create(sender, 0);
    const result = (try executor.executeCreateTransaction(sender, init_code, .legacy(100_000), 0)).expectCreate();

    try std.testing.expectEqual(Interpreter.Status.success, result.status);
    try std.testing.expect(executor.state.warm_accounts.contains(create_address));
}

test "callcode with insufficient balance fails without executing target code" {
    const caller = evmz.addr(0xaaaa);
    const target = evmz.addr(0xbbbb);
    const tx_context = testTxContext(caller, 100_000);
    var recorder = CheckpointTraceRecorder{};
    var sink = recorder.sink();
    var executor = Executor.init(std.testing.allocator, .{
        .spec = .berlin,
        .trace_sink = &sink,
    });
    defer executor.deinit();

    var caller_account = AccountState.init(std.testing.allocator);
    caller_account.balance = 0;
    try executor.state.accounts.put(caller, caller_account);

    var target_account = AccountState.init(std.testing.allocator);
    try target_account.setCode(std.testing.allocator, &.{ 0x60, 0x11, 0x60, 0x64, 0x55, 0x00 });
    try executor.state.accounts.put(target, target_account);

    try executor.beginTransaction(tx_context, caller, caller);
    const result = (try call_runtime.call(&executor, .{
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
    try std.testing.expectEqual(@as(u8, 2), recorder.checkpoints);
    try std.testing.expectEqual(trace.CheckpointKind.checkpoint, recorder.first);
    try std.testing.expectEqual(trace.CheckpointKind.revert, recorder.last);
}

test "create address collision closes checkpoint without rolling back nonce or warmth" {
    const sender = evmz.addr(0xaaaa);
    const tx_context = testTxContext(sender, 100_000);
    var recorder = CheckpointTraceRecorder{};
    var sink = recorder.sink();
    var executor = Executor.init(std.testing.allocator, .{
        .spec = .berlin,
        .trace_sink = &sink,
    });
    defer executor.deinit();

    var sender_account = AccountState.init(std.testing.allocator);
    sender_account.balance = 1;
    try executor.state.accounts.put(sender, sender_account);

    const create_address = evmz.address.create(sender, 0);
    var existing_account = AccountState.init(std.testing.allocator);
    existing_account.nonce = 1;
    try executor.state.accounts.put(create_address, existing_account);

    try executor.beginCreateTransaction(tx_context, sender);

    const result = (try executor.executeCreateTransaction(sender, &.{0x00}, .legacy(100_000), 1)).expectCreate();

    try std.testing.expectEqual(Interpreter.Status.invalid, result.status);
    try std.testing.expectEqual(@as(u64, 1), executor.getAccount(sender).?.nonce);
    try std.testing.expect(executor.state.warm_accounts.contains(create_address));
    try std.testing.expectEqual(@as(u8, 2), recorder.checkpoints);
    try std.testing.expectEqual(trace.CheckpointKind.checkpoint, recorder.first);
    try std.testing.expectEqual(trace.CheckpointKind.commit, recorder.last);
}

test "call-like message at max depth still executes in recipient storage" {
    const caller = evmz.addr(0xaaaa);
    const target = evmz.addr(0xbbbb);
    const tx_context = testTxContext(caller, 100_000);
    var executor = Executor.init(std.testing.allocator, .{
        .spec = .frontier,
    });
    defer executor.deinit();

    var caller_account = AccountState.init(std.testing.allocator);
    caller_account.balance = 1_000_000;
    try executor.state.accounts.put(caller, caller_account);

    try executor.state.accounts.put(target, AccountState.init(std.testing.allocator));

    inline for (.{ Host.CallKind.callcode, Host.CallKind.delegatecall }, 0..) |kind, slot| {
        try executor.getAccount(target).?.setCode(std.testing.allocator, &.{ 0x60, 0x2a, 0x60, @intCast(slot), 0x55, 0x00 });
        try executor.beginTransaction(tx_context, caller, caller);
        const result = (try call_runtime.call(&executor, .{
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
    }
}

test "value call at max depth returns stipend without child execution" {
    const caller = evmz.addr(0xaaaa);
    const contract = evmz.addr(0xbbbb);
    const tx_context = testTxContext(caller, 100_000);
    var executor = Executor.init(std.testing.allocator, .{
        .spec = .berlin,
    });
    defer executor.deinit();

    var caller_account = AccountState.init(std.testing.allocator);
    caller_account.balance = 1_000_000;
    try executor.state.accounts.put(caller, caller_account);

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
    var contract_account = AccountState.init(std.testing.allocator);
    try contract_account.setCode(std.testing.allocator, &code);
    try executor.state.accounts.put(contract, contract_account);

    try executor.beginTransaction(tx_context, caller, contract);
    const result = (try call_runtime.call(&executor, .{
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
    var executor = Executor.init(std.testing.allocator, .{
        .spec = .amsterdam,
    });
    defer executor.deinit();

    var caller_account = AccountState.init(std.testing.allocator);
    caller_account.balance = 1_000_000;
    try executor.state.accounts.put(caller, caller_account);

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
    var contract_account = AccountState.init(std.testing.allocator);
    contract_account.balance = 1;
    try contract_account.setCode(std.testing.allocator, &code);
    try executor.state.accounts.put(contract, contract_account);

    try executor.beginTransaction(tx_context, caller, contract);
    const result = (try call_runtime.call(&executor, .{
        .depth = Host.max_call_depth,
        .kind = .call,
        .gas = 100_000,
        .gas_reservoir = transaction.amsterdam_new_account_state_gas,
        .recipient = contract,
        .sender = caller,
        .input_data = &.{},
        .value = 0,
        .code_address = contract,
    })).expectCall();

    try std.testing.expectEqual(Interpreter.Status.success, result.status);
    try std.testing.expectEqual(@as(i64, transaction.amsterdam_new_account_state_gas), result.gas_reservoir);
    try std.testing.expectEqual(@as(i64, 0), result.state_gas_spent);
    try std.testing.expect(!try executor.state.accountExists(recipient));
}

test "Amsterdam create at max depth refills new-account state gas" {
    const caller = evmz.addr(0xaaaa);
    const contract = evmz.addr(0xbbbb);
    const tx_context = testTxContext(caller, 300_000);
    var executor = Executor.init(std.testing.allocator, .{
        .spec = .amsterdam,
    });
    defer executor.deinit();

    var caller_account = AccountState.init(std.testing.allocator);
    caller_account.balance = 1_000_000;
    try executor.state.accounts.put(caller, caller_account);

    const code = evmz.t.bytecode(.{ .PUSH0, .PUSH0, .PUSH0, .CREATE, .STOP });
    var contract_account = AccountState.init(std.testing.allocator);
    try contract_account.setCode(std.testing.allocator, &code);
    try executor.state.accounts.put(contract, contract_account);

    try executor.beginTransaction(tx_context, caller, contract);
    const result = (try call_runtime.call(&executor, .{
        .depth = Host.max_call_depth,
        .kind = .call,
        .gas = 100_000,
        .gas_reservoir = transaction.amsterdam_new_account_state_gas,
        .recipient = contract,
        .sender = caller,
        .input_data = &.{},
        .value = 0,
        .code_address = contract,
    })).expectCall();

    try std.testing.expectEqual(Interpreter.Status.success, result.status);
    try std.testing.expectEqual(@as(i64, transaction.amsterdam_new_account_state_gas), result.gas_reservoir);
    try std.testing.expectEqual(@as(i64, 0), result.state_gas_spent);
    try std.testing.expectEqual(@as(u64, 0), executor.getAccount(contract).?.nonce);
}

test "exceptional child call burns forwarded gas" {
    const caller = evmz.addr(0xaaaa);
    const target = evmz.addr(0xbbbb);
    const tx_context = testTxContext(caller, 100_000);
    var executor = Executor.init(std.testing.allocator, .{
        .spec = .berlin,
    });
    defer executor.deinit();

    var caller_account = AccountState.init(std.testing.allocator);
    caller_account.balance = 1_000_000;
    try executor.state.accounts.put(caller, caller_account);

    var target_account = AccountState.init(std.testing.allocator);
    try target_account.setCode(std.testing.allocator, &.{0xfe});
    try executor.state.accounts.put(target, target_account);

    try executor.beginTransaction(tx_context, caller, caller);
    const result = (try call_runtime.call(&executor, .{
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
    var executor = Executor.init(std.testing.allocator, .{
        .spec = .berlin,
    });
    defer executor.deinit();

    var caller_account = AccountState.init(std.testing.allocator);
    caller_account.balance = 1_000_000;
    try executor.state.accounts.put(caller, caller_account);

    var target_account = AccountState.init(std.testing.allocator);
    try target_account.setCode(std.testing.allocator, &.{ 0x60, 0x11, 0x60, 0x64, 0x55, 0xfe });
    try executor.state.accounts.put(target, target_account);

    try executor.beginTransaction(tx_context, caller, caller);
    const result = (try call_runtime.call(&executor, .{
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
    var executor = Executor.init(std.testing.allocator, .{
        .spec = .london,
    });
    defer executor.deinit();

    var sender_account = AccountState.init(std.testing.allocator);
    sender_account.balance = 1_000_000;
    try executor.state.accounts.put(sender, sender_account);

    try executor.beginCreateTransaction(tx_context, sender);

    const init_code = &.{ 0x60, 0xef, 0x60, 0x00, 0x53, 0x60, 0x10, 0x60, 0x00, 0xf3 };
    const create_address = evmz.address.create(sender, 0);
    const result = (try executor.executeCreateTransaction(sender, init_code, .legacy(100_000), 0)).expectCreate();

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
    var executor = Executor.init(std.testing.allocator, .{
        .spec = .cancun,
    });
    defer executor.deinit();

    var sender_account = AccountState.init(std.testing.allocator);
    sender_account.balance = 1_000_000;
    try executor.state.accounts.put(sender, sender_account);

    var contract_account = AccountState.init(std.testing.allocator);
    contract_account.balance = 1;
    try contract_account.setCode(std.testing.allocator, &.{ 0x5f, 0xff });
    try executor.state.accounts.put(contract, contract_account);

    try executor.beginTransaction(tx_context, sender, contract);
    const result = try executor.executeCallTransaction(sender, contract, &.{}, .legacy(100_000), 0);

    try std.testing.expectEqual(Interpreter.Status.success, result.status);
    try std.testing.expectEqual(@as(i64, 69_998), result.gas_left);
}

test "SELFDESTRUCT refund is removed at London" {
    const sender = evmz.addr(0xaaaa);
    const contract = evmz.addr(0xbbbb);
    const code = evmz.t.bytecode(.{ .PUSH1, 0x00, .SELFDESTRUCT });
    const cases = [_]struct {
        spec: evmz.Spec,
        refund: i64,
    }{
        .{ .spec = .berlin, .refund = 24_000 },
        .{ .spec = .london, .refund = 0 },
    };

    for (cases) |case| {
        const tx_context = testTxContext(sender, 100_000);
        var executor = Executor.init(std.testing.allocator, .{
            .spec = case.spec,
        });
        defer executor.deinit();

        var sender_account = AccountState.init(std.testing.allocator);
        sender_account.balance = 1_000_000;
        try executor.state.accounts.put(sender, sender_account);

        var contract_account = AccountState.init(std.testing.allocator);
        try contract_account.setCode(std.testing.allocator, &code);
        try executor.state.accounts.put(contract, contract_account);

        try executor.beginTransaction(tx_context, sender, contract);
        const result = try executor.executeCallTransaction(sender, contract, &.{}, .legacy(100_000), 0);

        try std.testing.expectEqual(Interpreter.Status.success, result.status);
        try std.testing.expectEqual(case.refund, result.gas_refund);
    }
}

test "active precompiles are warm but not existing state accounts" {
    const precompile_address = evmz.addr(2);
    var executor = Executor.init(std.testing.allocator, .{
        .spec = .berlin,
    });
    defer executor.deinit();

    var host_iface = executor.host();
    try std.testing.expect(!try host_iface.accountExists(precompile_address));
    try std.testing.expectEqual(Host.AccessStatus.warm, try host_iface.accessAccount(precompile_address));
    try std.testing.expectEqual(@as(u256, 0), try host_iface.getCodeHash(precompile_address));

    _ = try executor.getOrCreateAccount(precompile_address);
    try std.testing.expectEqual(evmz.empty_code_hash, try host_iface.getCodeHash(precompile_address));
}

test "delegated precompile targets are warm" {
    const authority = evmz.addr(0xbbbb);
    const precompile_address = evmz.addr(2);
    for ([_]evmz.Spec{ .prague, .amsterdam }) |spec| {
        var executor = Executor.init(std.testing.allocator, .{
            .spec = spec,
        });
        defer executor.deinit();

        var code: [eip7702.delegation_code_len]u8 = undefined;
        eip7702.writeDelegationCode(&code, precompile_address);
        var authority_account = AccountState.init(std.testing.allocator);
        try authority_account.setCode(std.testing.allocator, &code);
        try executor.state.accounts.put(authority, authority_account);

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
    var executor = Executor.init(std.testing.allocator, .{
        .spec = .berlin,
        .trace_sink = &sink,
    });
    defer executor.deinit();

    var sender_account = AccountState.init(std.testing.allocator);
    sender_account.balance = 1_000_000;
    try executor.state.accounts.put(sender, sender_account);

    var contract_account = AccountState.init(std.testing.allocator);
    try contract_account.setCode(std.testing.allocator, &.{
        0x60, 0x2a, // PUSH1 42
        0x60, 0x00, // PUSH1 0
        0x55, // SSTORE
        0x00, // STOP
    });
    try executor.state.accounts.put(contract, contract_account);

    try executor.beginTransaction(tx_context, sender, contract);
    const result = try executor.executeCallTransaction(sender, contract, &.{}, .legacy(100_000), 0);

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
        return .{ .ptr = self, .events = .{
            .state_read = .{ .storage = true },
            .state_write = .{ .storage = true },
        }, .vtable = &.{
            .stepStart = stepStart,
            .stepEnd = stepEnd,
            .stateRead = stateRead,
            .stateWrite = stateWrite,
        } };
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
        return .{ .ptr = self, .events = .{
            .step_start = .{
                .opcode = true,
                .depth = true,
            },
            .step_end = .{
                .opcode = true,
                .depth = true,
                .stack = true,
                .status = true,
            },
        }, .vtable = &.{
            .stepStart = stepStart,
            .stepEnd = stepEnd,
        } };
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
        return .{ .ptr = self, .events = .{
            .checkpoint = trace.CheckpointFields.all(),
        }, .vtable = &.{
            .checkpoint = checkpointEvent,
        } };
    }

    fn checkpointEvent(ptr: *anyopaque, event: trace.Checkpoint) void {
        const self: *CheckpointTraceRecorder = @ptrCast(@alignCast(ptr));
        if (self.checkpoints == 0) self.first = event.kind;
        self.last = event.kind;
        self.checkpoints += 1;
    }
};

fn testTxContext(origin: Address, gas_limit: u64) Host.TxContext {
    return .{
        .chain_id = 1,
        .gas_price = 0,
        .origin = origin,
        .coinbase = evmz.addr(0),
        .number = 0,
        .timestamp = 0,
        .gas_limit = gas_limit,
        .prev_randao = 0,
        .base_fee = 0,
        .blob_base_fee = 0,
        .blob_hashes = &.{},
    };
}

test {
    std.testing.refAllDecls(@This());
}
