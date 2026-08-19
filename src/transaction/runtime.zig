//! Private transaction-program choreography over Executor's authoritative state.
//!
//! This module owns no state or generation. Its functions operate directly on
//! the one active transaction row stored by Executor, keeping family policy in
//! `program.zig` without exposing begin/finish lifecycle methods to consumers.

const std = @import("std");

const execution = @import("../execution.zig");

pub const Mode = @import("../executor/instrumentation.zig").Mode;

pub fn hasActive(executor: anytype) bool {
    const state = executor.transaction_runtime_state orelse return false;
    return state.phase == .active;
}

pub inline fn requireActive(executor: anytype) void {
    std.debug.assert(hasActive(executor));
}

pub const RootAccessReservation = enum { none, reserve };

pub fn begin(executor: anytype, mode: Mode) !void {
    std.debug.assert(executor.transaction_runtime_state == null);
    std.debug.assert(executor.execution_context == null);
    std.debug.assert(executor.checkpoint_top == 0);
    std.debug.assert(!executor.state.scopeActive());

    if (mode.captureContext()) |capture| std.debug.assert(capture.isActive());
    const state_attempt_id = if (mode.observesState())
        executor.state.beginObservedTransaction()
    else
        executor.state.beginTransaction();
    std.debug.assert(executor.next_transaction_generation != std.math.maxInt(u64));
    executor.next_transaction_generation += 1;
    executor.transaction_runtime_state = .{
        .state_attempt_id = state_attempt_id,
        .generation = executor.next_transaction_generation,
        .mode = mode,
    };
}

pub fn initializeMessageScope(
    executor: anytype,
    message: execution.Message,
    scope_init: execution.ExecutionScopeInit,
    root_access_reservation: RootAccessReservation,
) !void {
    const initial_warm_set = scope_init.initial_warm_set;
    if (root_access_reservation == .reserve or
        initial_warm_set.accounts.len != 0 or
        initial_warm_set.storage_slots.len != 0)
    {
        const root_accounts: usize = switch (message) {
            .call => 2,
            .create => 1,
        };
        std.debug.assert(initial_warm_set.accounts.len <= std.math.maxInt(usize) - root_accounts);
        try executor.state.reserveAccessHint(.{
            .accounts = root_accounts + initial_warm_set.accounts.len,
            .storage_keys = initial_warm_set.storage_slots.len,
        });
    }

    switch (message) {
        .call => |call| {
            try executor.warmAccount(call.sender);
            try executor.warmAccount(call.recipient);
        },
        .create => |create| try executor.warmAccount(create.sender),
    }
    for (initial_warm_set.accounts) |address| {
        try executor.warmAccount(address);
    }
    for (initial_warm_set.storage_slots) |slot| {
        try executor.warmStorage(slot.address, slot.key);
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
    request: execution.EvmExecutionRequest,
    scope_init: execution.ExecutionScopeInit,
) !void {
    requireActive(executor);
    std.debug.assert(executor.execution_context == null);
    std.debug.assert(executor.checkpoint_top == 0);
    std.debug.assert(!executor.state.scopeActive());

    executor.execution_context = request.context;
    executor.scope_root = null;
    executor.state.beginScope();
    errdefer closeExecutionScope(executor);

    try initializeMessageScope(executor, request.message, scope_init, .none);
}

/// Open one transaction-scoped execution session that may run multiple EVM
/// roots. Unlike `beginExecution`, this does not bind or warm a root message;
/// the family transition may take an outer checkpoint before `runRoot`.
pub fn beginRootSession(executor: anytype, context: execution.ExecutionContext) !void {
    requireActive(executor);
    std.debug.assert(executor.execution_context == null);
    std.debug.assert(executor.checkpoint_top == 0);
    std.debug.assert(!executor.state.scopeActive());

    executor.execution_context = context;
    executor.scope_root = null;
    executor.state.beginScope();
}

/// Execute one independently rollback-armed EVM root inside an open custom
/// transaction session. Warmth and logs survive successful roots; transient
/// storage is cleared before every root and cannot be resurrected by an outer
/// rollback. Failed-root state, warmth, and logs roll back to the root boundary.
pub fn runRoot(
    executor: anytype,
    request: execution.EvmExecutionRequest,
    scope_init: execution.ExecutionScopeInit,
) @TypeOf(executor.executeTransactionRequestPhased(request)) {
    requireActive(executor);
    const runtime_state = &executor.transaction_runtime_state.?;
    runtime_state.payload_started = true;
    std.debug.assert(executor.execution_context != null);
    std.debug.assert(executor.state.scopeActive());
    std.debug.assert(executor.execution_context.?.sameRootSession(request.context));

    executor.state.clearTransientStorage();
    executor.execution_context = request.context;
    executor.scope_root = null;

    var checkpoint = executor.checkpoint();
    defer checkpoint.deinit();
    try initializeMessageScope(executor, request.message, scope_init, .reserve);

    const outcome = try executor.executeTransactionRequestPhased(request);
    if (outcome.stage == .preparation or executionRolledBack(outcome.result.outcome.status)) {
        checkpoint.restore();
    } else {
        checkpoint.commit();
    }
    return outcome;
}

pub fn runPayload(
    executor: anytype,
    request: execution.EvmExecutionRequest,
) @TypeOf(executor.executeTransactionRequestPhased(request)) {
    requireActive(executor);
    const runtime_state = &executor.transaction_runtime_state.?;
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
    request: execution.EvmExecutionRequest,
) @TypeOf(executor.executeTransactionRequest(request)) {
    requireActive(executor);
    std.debug.assert(executor.execution_context == null);
    std.debug.assert(executor.checkpoint_top == 0);
    std.debug.assert(!executor.state.scopeActive());

    executor.execution_context = request.context;
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
    executor.state.beginScope();
    errdefer closeExecutionScope(executor);

    var checkpoint = executor.checkpoint();
    defer checkpoint.deinit();
    const result = try executor.executeTransactionRequest(request);
    if (executionRolledBack(result.outcome.status)) {
        checkpoint.restore();
    } else {
        try executor.finalizeTransactionState();
        checkpoint.commit();
    }
    closeExecutionScope(executor);
    return result;
}

pub fn finish(executor: anytype) u64 {
    requireActive(executor);
    const state_attempt_id = executor.transaction_runtime_state.?.state_attempt_id;
    const generation = executor.transaction_runtime_state.?.generation;
    closeExecutionScope(executor);
    executor.state.seal(state_attempt_id);
    executor.transaction_runtime_state.?.phase = .pending;
    return generation;
}

pub fn discard(executor: anytype) void {
    requireActive(executor);
    const state_attempt_id = executor.transaction_runtime_state.?.state_attempt_id;
    closeExecutionScope(executor);
    executor.state.discard(state_attempt_id);
    executor.clearLastOutput();
    executor.transaction_runtime_state = null;
}

fn executionRolledBack(status: anytype) bool {
    return switch (status) {
        .success => false,
        .revert, .invalid, .out_of_gas => true,
    };
}

fn closeExecutionScope(executor: anytype) void {
    if (executor.execution_context == null) return;
    std.debug.assert(executor.state.scopeActive());
    executor.state.closeScope();
    executor.execution_context = null;
    executor.scope_root = null;
}
