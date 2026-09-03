//! Interior call/create checkpoint ownership.

const std = @import("std");

const Checkpoint = @import("../state/checkpoint.zig").Checkpoint;
const Status = @import("../evm.zig").interpreter.Status;

/// Owns one interior call/create checkpoint until it is resolved or
/// transferred to a store row. Any early error restores it.
pub fn Guard(comptime State: type) type {
    return struct {
        const Self = @This();

        state: *State,
        checkpoint_state: Checkpoint,
        open: bool = true,

        pub fn init(state: *State, checkpoint_state: Checkpoint) Self {
            return .{ .state = state, .checkpoint_state = checkpoint_state };
        }

        pub fn deinit(self: *Self) void {
            if (self.open) self.state.revertToCheckpoint(self.checkpoint_state);
            self.* = undefined;
        }

        pub fn begin(state: *State) Self {
            return .{ .state = state, .checkpoint_state = state.checkpoint() };
        }

        pub fn commit(self: *Self) void {
            self.state.commitCheckpoint(self.checkpoint_state);
            self.open = false;
        }

        pub fn restore(self: *Self) void {
            self.state.revertToCheckpoint(self.checkpoint_state);
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
