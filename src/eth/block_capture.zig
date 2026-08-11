//! Optional caller-owned instrumentation for the authoritative block fold.
//!
//! This module owns capture cleanup and delivery. It does not construct the
//! consensus block access list or participate in block validity.

const std = @import("std");

const Executor = @import("../executor.zig");
const bal = @import("bal/model.zig");
const state = @import("../state.zig");
const trace = @import("../trace.zig");

pub const Execution = struct {
    observations: ?ObservationTarget = null,
    steps: ?StepCapture = null,

    pub const StepCapture = struct {
        tape: *trace.TraceTape,
        profile: trace.CaptureProfile = .{},
        target: trace.TraceSpanTarget,
    };
};

/// Synchronous borrowed observation consumer. The callback must copy anything
/// it retains beyond the call.
pub const ObservationTarget = struct {
    ptr: *anyopaque,
    consume_fn: *const fn (
        *anyopaque,
        bal.BlockAccessIndex,
        state.TrackedState.ObservationsView,
    ) anyerror!void,

    pub fn init(
        ptr: *anyopaque,
        consume_fn: *const fn (
            *anyopaque,
            bal.BlockAccessIndex,
            state.TrackedState.ObservationsView,
        ) anyerror!void,
    ) ObservationTarget {
        return .{ .ptr = ptr, .consume_fn = consume_fn };
    }

    pub fn consume(
        self: ObservationTarget,
        block_access_index: bal.BlockAccessIndex,
        view: state.TrackedState.ObservationsView,
    ) !void {
        try self.consume_fn(self.ptr, block_access_index, view);
    }
};

/// Whole-block owner of optional step capture. Each transaction span is
/// resolved or aborted before the next transaction begins.
pub const StepScope = struct {
    context: Executor.CaptureContext,
    steps: ?Execution.StepCapture,
    block_open: bool = false,

    pub fn init(allocator: std.mem.Allocator, capture: ?Execution) StepScope {
        return .{
            .context = Executor.CaptureContext.init(allocator, null),
            .steps = if (capture) |value| value.steps else null,
        };
    }

    pub fn beginBlock(self: *StepScope) !void {
        if (self.steps == null) return;
        try self.context.begin();
        self.block_open = true;
    }

    pub fn deinit(self: *StepScope) void {
        if (self.block_open) self.context.abort() catch {};
        self.context.deinit();
        self.* = undefined;
    }

    pub fn active(self: *const StepScope) bool {
        return self.steps != null;
    }

    pub fn contextPtr(self: *StepScope) *Executor.CaptureContext {
        std.debug.assert(self.active());
        return &self.context;
    }

    pub fn beginTransaction(self: *StepScope) !?Span {
        const steps = self.steps orelse return null;
        try self.context.beginTrace(.{ .tape = steps.tape, .profile = steps.profile });
        return .{ .scope = self, .open = true };
    }

    pub fn finishBlock(self: *StepScope) !void {
        if (!self.block_open) return;
        _ = try self.context.finish();
        self.block_open = false;
    }

    pub const Span = struct {
        scope: *StepScope,
        open: bool,

        pub fn finish(self: *Span) !void {
            const steps = self.scope.steps.?;
            const span = try self.scope.context.finishTrace();
            self.open = false;
            var span_outstanding = true;
            defer if (span_outstanding) steps.tape.resolve(span) catch {};
            try steps.target.consume(span);
            try steps.tape.resolve(span);
            span_outstanding = false;
            try steps.tape.reset();
        }

        pub fn abort(self: *Span) void {
            if (self.open) self.scope.context.abortTrace() catch {};
        }
    };
};
