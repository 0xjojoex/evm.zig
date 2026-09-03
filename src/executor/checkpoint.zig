//! Journal-checkpoint ownership for one execution scope.

const std = @import("std");

const Checkpoint = @import("../state/Checkpoint.zig");
const Status = @import("../evm.zig").interpreter.Status;

/// Owns one journal checkpoint from open until it is committed, restored, or
/// handed to a frame-store row. Dropping it open restores, so early error
/// paths need no cleanup. LIFO order is enforced by the state's scope
/// generations, not here. Treat as move-only.
pub fn Guard(comptime State: type) type {
    return struct {
        const Self = @This();

        state: *State,
        checkpoint: Checkpoint,
        open: bool = true,

        pub fn init(state: *State, checkpoint: Checkpoint) Self {
            return .{ .state = state, .checkpoint = checkpoint };
        }

        pub fn deinit(self: *Self) void {
            if (self.open) self.state.revertToCheckpoint(self.checkpoint);
            self.* = undefined;
        }

        pub fn begin(state: *State) Self {
            return .{ .state = state, .checkpoint = state.checkpoint() };
        }

        pub fn commit(self: *Self) void {
            self.state.commitCheckpoint(self.checkpoint);
            self.open = false;
        }

        pub fn restore(self: *Self) void {
            self.state.revertToCheckpoint(self.checkpoint);
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
