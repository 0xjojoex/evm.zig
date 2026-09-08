//! Journal-checkpoint ownership for one execution scope.

const std = @import("std");

const Checkpoint = @import("../state.zig").Checkpoint;
const Status = @import("../evm.zig").interpreter.Status;

/// Owns one journal checkpoint from open until it is committed, restored, or
/// handed to a frame-store row. Dropping it open restores, so early error
/// paths need no cleanup. LIFO order is enforced by the state's scope
/// generations, not here. Treat as move-only.
/// `Owner` couples state and transaction-journal checkpoints through `openScope`,
/// `commitScope`, and `revertScope`.
pub fn Guard(comptime Owner: type) type {
    return struct {
        const Self = @This();

        owner: *Owner,
        checkpoint: Checkpoint,
        open: bool = true,

        pub fn init(owner: *Owner, checkpoint: Checkpoint) Self {
            return .{ .owner = owner, .checkpoint = checkpoint };
        }

        pub fn deinit(self: *Self) void {
            if (self.open) self.owner.revertScope(self.checkpoint);
            self.* = undefined;
        }

        pub fn begin(owner: *Owner) Self {
            return .{ .owner = owner, .checkpoint = owner.openScope() };
        }

        pub fn commit(self: *Self) void {
            self.owner.commitScope(self.checkpoint);
            self.open = false;
        }

        pub fn restore(self: *Self) void {
            self.owner.revertScope(self.checkpoint);
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
