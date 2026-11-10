//! Private transaction-program choreography over Executor's authoritative state.
//!
//! This module owns no state or generation. Its functions operate directly on
//! the one active transaction row stored by Executor, keeping family policy in
//! `program.zig` without exposing begin/finish lifecycle methods to consumers.

const std = @import("std");

const execution = @import("../execution.zig");
const executor_engine = @import("../executor.zig");
const LogBuffer = @import("../state/LogBuffer.zig");

pub const Mode = @import("../executor/instrumentation.zig").Mode;

/// One attempted root of a multi-root session.
pub const RootExecutionOutcome = struct {
    stage: executor_engine.TransactionExecutionStage,
    result: execution.ExecutionResult,
    /// Logs this root left in the transaction log buffer; empty when it
    /// rolled back. An outer rollback that truncates past its start
    /// invalidates it.
    log_range: LogBuffer.RowRange,
};

pub fn hasActive(executor: anytype) bool {
    const attempt = executor.attempt orelse return false;
    return switch (attempt.owner) {
        .manual => false,
        .transaction => |transaction| transaction.phase == .active,
    };
}

pub inline fn requireActive(executor: anytype) void {
    std.debug.assert(hasActive(executor));
}

pub fn begin(executor: anytype, mode: Mode) !void {
    std.debug.assert(executor.attempt == null);
    std.debug.assert(executor.execution_context == null);
    std.debug.assert(!executor.state.hasOpenCheckpoint());
    std.debug.assert(!executor.state.sessionActive());

    if (mode.captureContext()) |capture| std.debug.assert(capture.isActive());
    const state_attempt_id = if (mode.observesState())
        executor.state.beginObservedAttempt()
    else
        executor.state.beginAttempt();
    if (comptime @TypeOf(executor.transaction_journal) != void)
        executor.transaction_journal.beginTransaction();
    std.debug.assert(executor.next_transaction_generation != std.math.maxInt(u64));
    executor.next_transaction_generation += 1;
    executor.attempt = .{
        .id = state_attempt_id,
        .mode = mode,
        .owner = .{ .transaction = .{ .generation = executor.next_transaction_generation } },
    };
}

pub fn initializeMessageScope(
    executor: anytype,
    message: execution.Message,
    scope_init: execution.ExecutionScopeInit,
) !void {
    const initial_warm_set = scope_init.initial_warm_set;
    if (initial_warm_set.accounts.len != 0 or initial_warm_set.storage_slots.len != 0) {
        const root_accounts = rootAccounts(message);
        std.debug.assert(initial_warm_set.accounts.len <= std.math.maxInt(usize) - root_accounts);
        try executor.reserveAccessHint(.{
            .accounts = root_accounts + initial_warm_set.accounts.len,
            .storage_keys = initial_warm_set.storage_slots.len,
        });
    }
    try initializeRoot(executor, message, .{});
    try warmInitialSet(executor, initial_warm_set);
}

fn rootAccounts(message: execution.Message) usize {
    return switch (message) {
        .call => 2,
        .create => 1,
    };
}

fn warmInitialSet(executor: anytype, initial_warm_set: execution.InitialWarmSet) !void {
    for (initial_warm_set.accounts) |address| {
        try executor.warmAccount(address);
    }
    for (initial_warm_set.storage_slots) |slot| {
        try executor.warmStorage(slot.address, slot.key);
    }
}

/// Warm and bind one root message. Non-default entry modes apply only to calls.
fn initializeRoot(
    executor: anytype,
    message: execution.Message,
    root_init: execution.RootExecutionInit,
) !void {
    switch (message) {
        .call => |call| switch (root_init.access) {
            .prewarm_sender_and_recipient => {
                try executor.warmAccount(call.sender);
                try executor.warmAccount(call.recipient);
            },
            // The executor charges and warms the target at dispatch.
            .charge_call_target => {},
        },
        .create => |create| {
            std.debug.assert(std.meta.eql(root_init, execution.RootExecutionInit{}));
            try executor.warmAccount(create.sender);
        },
    }
    executor.scope_root = switch (message) {
        .call => |call| .{
            .sender = call.sender,
            .recipient = call.recipient,
        },
        .create => |create| .{
            .sender = create.sender,
            .recipient = null,
        },
    };
}

pub fn beginExecution(
    executor: anytype,
    request: execution.ExecutionRequest,
    scope_init: execution.ExecutionScopeInit,
) !void {
    requireActive(executor);
    std.debug.assert(executor.execution_context == null);
    std.debug.assert(!executor.state.hasOpenCheckpoint());
    std.debug.assert(!executor.state.sessionActive());

    executor.execution_context = request.context;
    executor.execution_phase = .idle;
    executor.scope_root = null;
    executor.state.openSession();
    errdefer closeExecutionScope(executor);

    try initializeMessageScope(executor, request.message, scope_init);
}

/// Open one transaction-scoped execution session that may run multiple EVM
/// roots. Unlike `beginExecution`, this does not bind or warm a root message;
/// the family transition may take an outer checkpoint before `runRoot`.
/// `scope_init` warms accounts and slots for the whole session.
pub fn beginRootSession(
    executor: anytype,
    context: execution.ExecutionContext,
    scope_init: execution.ExecutionScopeInit,
) !void {
    requireActive(executor);
    std.debug.assert(executor.execution_context == null);
    std.debug.assert(!executor.state.hasOpenCheckpoint());
    std.debug.assert(!executor.state.sessionActive());

    executor.execution_context = context;
    executor.execution_phase = .idle;
    executor.scope_root = null;
    executor.state.openSession();
    errdefer closeExecutionScope(executor);

    const initial_warm_set = scope_init.initial_warm_set;
    if (initial_warm_set.accounts.len != 0 or initial_warm_set.storage_slots.len != 0) {
        try executor.reserveAccessHint(.{
            .accounts = initial_warm_set.accounts.len,
            .storage_keys = initial_warm_set.storage_slots.len,
        });
    }
    try warmInitialSet(executor, initial_warm_set);
}

/// Execute one independently rollback-armed EVM root inside an open custom
/// transaction session. Warmth and logs survive successful roots; transient
/// storage is cleared before every root and cannot be resurrected by an outer
/// rollback. Failed-root state, warmth, and logs roll back to the root boundary.
pub fn runRoot(
    executor: anytype,
    request: execution.ExecutionRequest,
    root_init: execution.RootExecutionInit,
) !RootExecutionOutcome {
    requireActive(executor);
    std.debug.assert(executor.execution_context != null);
    std.debug.assert(executor.execution_phase == .idle);
    const runtime_state = &executor.attempt.?.owner.transaction;
    runtime_state.payload_started = true;
    std.debug.assert(executor.state.sessionActive());
    std.debug.assert(executor.execution_context.?.sameRootSession(request.context));

    executor.state.clearTransientStorage();
    executor.execution_context = request.context;
    executor.scope_root = null;

    const log_start = executor.logView().len();
    var checkpoint = executor.checkpoint();
    defer checkpoint.deinit();
    try executor.reserveAccessHint(.{ .accounts = rootAccounts(request.message), .storage_keys = 0 });
    try initializeRoot(executor, request.message, root_init);

    const outcome = try executor.executeRootTransactionRequestPhased(request, root_init);
    if (outcome.stage == .preparation or executionRolledBack(outcome.result.outcome.status)) {
        checkpoint.restore();
    } else {
        checkpoint.commit();
    }
    const log_end = executor.logView().len();
    std.debug.assert(log_end >= log_start);
    return .{
        .stage = outcome.stage,
        .result = outcome.result,
        .log_range = .init(log_start, log_end - log_start),
    };
}

pub fn runPayload(
    executor: anytype,
    request: execution.ExecutionRequest,
) @TypeOf(executor.executeTransactionRequestPhased(request)) {
    requireActive(executor);
    std.debug.assert(executor.execution_context != null);
    std.debug.assert(executor.execution_phase == .idle);
    const runtime_state = &executor.attempt.?.owner.transaction;
    std.debug.assert(!runtime_state.payload_started);
    runtime_state.payload_started = true;

    var checkpoint = executor.checkpoint();
    defer checkpoint.deinit();

    const outcome = try executor.executeTransactionRequestPhased(request);
    if (outcome.stage == .preparation or executionRolledBack(outcome.result.outcome.status)) {
        checkpoint.restore();
    } else {
        checkpoint.commit();
    }
    return outcome;
}

pub fn runPrelude(
    executor: anytype,
    request: execution.ExecutionRequest,
) @TypeOf(executor.executeTransactionRequest(request)) {
    requireActive(executor);
    std.debug.assert(executor.execution_context == null);
    std.debug.assert(!executor.state.hasOpenCheckpoint());
    std.debug.assert(!executor.state.sessionActive());

    executor.execution_context = request.context;
    executor.execution_phase = .idle;
    executor.scope_root = switch (request.message) {
        .call => |call| .{
            .sender = call.sender,
            .recipient = call.recipient,
        },
        .create => |create| .{
            .sender = create.sender,
            .recipient = null,
        },
    };
    executor.state.openSession();
    errdefer closeExecutionScope(executor);

    var checkpoint = executor.checkpoint();
    defer checkpoint.deinit();
    const result = try executor.executeTransactionRequest(request);
    if (executionRolledBack(result.outcome.status)) {
        checkpoint.restore();
    } else {
        try executor.finalizeExecution();
        checkpoint.commit();
    }
    closeExecutionScope(executor);
    return result;
}

/// Seal the attempt. Lifecycle rows left by dispatch must be finalized or rolled
/// back first; State asserts that at seal.
pub fn finish(executor: anytype) u64 {
    requireActive(executor);
    if (executor.execution_context != null) {
        std.debug.assert(executor.execution_phase != .running);
    }
    const state_attempt_id = executor.attempt.?.id;
    const generation = executor.attempt.?.owner.transaction.generation;
    closeExecutionScope(executor);
    executor.state.sealAttempt(state_attempt_id);
    executor.attempt.?.owner.transaction.phase = .pending;
    return generation;
}

pub fn discard(executor: anytype) void {
    requireActive(executor);
    const state_attempt_id = executor.attempt.?.id;
    closeExecutionScope(executor);
    if (comptime @TypeOf(executor.transaction_journal) != void)
        executor.transaction_journal.discardTransaction();
    executor.state.discardAttempt(state_attempt_id);
    executor.clearLastOutput();
    executor.attempt = null;
}

fn executionRolledBack(status: anytype) bool {
    return switch (status) {
        .success => false,
        .revert, .invalid, .out_of_gas => true,
    };
}

fn closeExecutionScope(executor: anytype) void {
    if (executor.execution_context == null) return;
    std.debug.assert(executor.state.sessionActive());
    executor.state.closeSession();
    executor.execution_context = null;
    executor.scope_root = null;
}
