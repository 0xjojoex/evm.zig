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

pub fn begin(executor: anytype, mode: Mode) !void {
    std.debug.assert(executor.transaction_runtime_state == null);
    std.debug.assert(executor.execution_context == null);
    std.debug.assert(executor.checkpoint_top == 0);
    std.debug.assert(!executor.state.scopeActive());

    const state_attempt_id = switch (mode) {
        .normal => executor.state.beginTransaction(),
        .observed => executor.state.beginObservedTransaction(),
        .captured => |capture| blk: {
            std.debug.assert(capture.isActive());
            break :blk executor.state.beginObservedTransaction();
        },
    };
    std.debug.assert(executor.next_transaction_generation != std.math.maxInt(u64));
    executor.next_transaction_generation += 1;
    switch (mode) {
        .normal => executor.transaction_runtime_state = .{
            .state_attempt_id = state_attempt_id,
            .generation = executor.next_transaction_generation,
            .mode = .normal,
        },
        .observed => executor.transaction_runtime_state = .{
            .state_attempt_id = state_attempt_id,
            .generation = executor.next_transaction_generation,
            .mode = .observed,
        },
        .captured => |capture| executor.transaction_runtime_state = .{
            .state_attempt_id = state_attempt_id,
            .generation = executor.next_transaction_generation,
            .mode = .{ .captured = capture },
        },
    }
}

pub fn initializeMessageScope(
    executor: anytype,
    message: execution.Message,
    scope_init: execution.ExecutionScopeInit,
) !void {
    const initial_warm_set = scope_init.initial_warm_set;
    if (initial_warm_set.accounts.len != 0 or initial_warm_set.storage_slots.len != 0) {
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
            try executor.state.warmAccount(call.sender);
            try executor.state.warmAccount(call.recipient);
        },
        .create => |create| try executor.state.warmAccount(create.sender),
    }
    for (initial_warm_set.accounts) |address| {
        try executor.state.warmAccount(address);
    }
    for (initial_warm_set.storage_slots) |slot| {
        try executor.state.warmStorage(slot.address, slot.key);
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

    try initializeMessageScope(executor, request.message, scope_init);
}

pub fn runPayload(
    executor: anytype,
    request: execution.EvmExecutionRequest,
) @TypeOf(executor.executeTransactionRequestPhased(request)) {
    requireActive(executor);
    const runtime_state = &executor.transaction_runtime_state.?;
    std.debug.assert(!runtime_state.payload_started);
    runtime_state.payload_started = true;

    var checkpoint = try executor.checkpoint();
    defer checkpoint.deinit();

    const outcome = try executor.executeTransactionRequestPhased(request);
    if (outcome.stage == .preparation or executionRolledBack(outcome.result.outcome.status)) {
        try checkpoint.restore();
    } else {
        try checkpoint.commit();
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

    var checkpoint = try executor.checkpoint();
    defer checkpoint.deinit();
    const result = try executor.executeTransactionRequest(request);
    if (executionRolledBack(result.outcome.status)) {
        try checkpoint.restore();
    } else {
        try executor.finalizeTransactionState();
        try checkpoint.commit();
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
    executor.execution_context = null;
    executor.scope_root = null;
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
