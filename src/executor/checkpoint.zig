//! Composite execution checkpoint ownership.

const std = @import("std");

const Status = @import("../evm.zig").interpreter.Status;
const TransactionCheckpointCursor = @import("../execution/context.zig").TransactionCheckpointParticipant.Cursor;
const StateCheckpoint = @import("../state/checkpoint.zig").Checkpoint;

pub const Checkpoint = struct {
    state: StateCheckpoint,
    transaction: ?TransactionCheckpointCursor,

    pub fn open(executor: anytype) Checkpoint {
        return .{
            .state = executor.state.checkpoint(),
            .transaction = executor.currentExecutionContext().transaction.extension.checkpoint(),
        };
    }

    pub fn commit(self: Checkpoint, executor: anytype) void {
        if (self.transaction) |cursor| {
            executor.currentExecutionContext().transaction.extension.commitCheckpoint(cursor);
        }
        executor.state.commitCheckpoint(self.state);
    }

    pub fn restore(self: Checkpoint, executor: anytype) void {
        if (self.transaction) |cursor| {
            executor.currentExecutionContext().transaction.extension.restoreCheckpoint(cursor);
        }
        executor.state.revertToCheckpoint(self.state);
    }
};

/// Owns one interior call/create checkpoint until it is resolved or
/// transferred to a store row. Any early error restores it.
pub fn Guard(comptime Executor: type) type {
    return struct {
        const Self = @This();

        executor: *Executor,
        checkpoint_state: Checkpoint,
        open: bool = true,

        pub fn init(executor: *Executor, checkpoint_state: Checkpoint) Self {
            return .{ .executor = executor, .checkpoint_state = checkpoint_state };
        }

        pub fn deinit(self: *Self) void {
            if (self.open) self.checkpoint_state.restore(self.executor);
            self.* = undefined;
        }

        pub fn begin(executor: *Executor) Self {
            return .{ .executor = executor, .checkpoint_state = .open(executor) };
        }

        pub fn commit(self: *Self) void {
            self.checkpoint_state.commit(self.executor);
            self.open = false;
        }

        pub fn restore(self: *Self) void {
            self.checkpoint_state.restore(self.executor);
            self.open = false;
        }

        pub fn finish(self: *Self, status: Status) void {
            if (status == .success) self.commit() else self.restore();
        }

        /// Mark the checkpoint as handed off to a frame-store row.
        pub fn disarm(self: *Self) void {
            std.debug.assert(self.open);
            self.open = false;
        }
    };
}
