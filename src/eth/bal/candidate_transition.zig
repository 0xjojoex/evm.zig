//! One isolated lane's owned execution evidence.
//!
//! An executor produces one `LaneTransition` from its sealed `ObservationsView`,
//! and that transition is projected straight into the block's BAL shard.
//!
//! There is deliberately no candidate-state fold here any more. Reconstructing
//! post-transaction state existed to give block-final work a positioned view,
//! but reading the claim through the last transaction index already is that
//! view, so the whole layer - `CandidateState`, `OrderedTransitionFold`,
//! `FoldedStateReader` and their deltas - was redundant.

const std = @import("std");

const Host = @import("../../Host.zig");
const observation = @import("observation.zig");
const state = @import("../../state.zig");
const vm = @import("../../vm.zig");

/// Singular owned handoff from one isolated transaction lane.
pub const TransactionEffects = struct {
    allocator: std.mem.Allocator,
    result: vm.TxExecutionResult,
    logs: []Host.Log,
    transition: observation.LaneTransition,

    pub const Builder = struct {
        allocator: std.mem.Allocator,
        result: vm.TxExecutionResult,
        logs: []Host.Log,
        transition: observation.LaneTransition,
        finished: bool = false,

        /// Take ownership of `transition` and detach the remaining borrowed
        /// execution outputs before the pending transaction resolves.
        pub fn init(executed: anytype, transition: observation.LaneTransition) !Builder {
            const allocator = executed.allocator();
            var owned_transition = transition;
            errdefer owned_transition.deinit(allocator);
            const view = executed.view();

            const output = try allocator.dupe(u8, view.output.output);
            errdefer allocator.free(output);
            const logs = try cloneLogs(allocator, view.logs);
            errdefer deinitLogs(allocator, logs);

            var result = view.output.*;
            result.output = output;
            return .{
                .allocator = allocator,
                .result = result,
                .logs = logs,
                .transition = owned_transition,
            };
        }

        pub fn finish(self: *Builder) TransactionEffects {
            std.debug.assert(!self.finished);
            self.finished = true;
            return .{
                .allocator = self.allocator,
                .result = self.result,
                .logs = self.logs,
                .transition = self.transition,
            };
        }

        pub fn discardIfUnfinished(self: *Builder) void {
            if (!self.finished) {
                self.allocator.free(@constCast(self.result.output));
                deinitLogs(self.allocator, self.logs);
                self.transition.deinit(self.allocator);
            }
            self.* = undefined;
        }
    };

    pub fn deinit(self: *TransactionEffects) void {
        self.allocator.free(@constCast(self.result.output));
        deinitLogs(self.allocator, self.logs);
        self.transition.deinit(self.allocator);
        self.* = undefined;
    }
};

pub fn cloneLogs(allocator: std.mem.Allocator, source: state.TrackedState.LogView) ![]Host.Log {
    const logs = try allocator.alloc(Host.Log, source.len());
    errdefer allocator.free(logs);

    var initialized: usize = 0;
    errdefer deinitLogItems(allocator, logs[0..initialized]);
    for (logs, 0..) |*target, index| {
        const event_log = source.get(index);
        const topics = try allocator.dupe(u256, event_log.topics);
        errdefer allocator.free(topics);
        const data = try allocator.dupe(u8, event_log.data);
        target.* = .{
            .address = event_log.address,
            .topics = topics,
            .data = data,
        };
        initialized += 1;
    }
    return logs;
}

fn deinitLogs(allocator: std.mem.Allocator, logs: []Host.Log) void {
    deinitLogItems(allocator, logs);
    allocator.free(logs);
}

fn deinitLogItems(allocator: std.mem.Allocator, logs: []Host.Log) void {
    for (logs) |event_log| {
        allocator.free(@constCast(event_log.topics));
        allocator.free(@constCast(event_log.data));
    }
}
