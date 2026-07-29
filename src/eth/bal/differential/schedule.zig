//! Bounded concurrent batching for isolated candidate lanes.
//!
//! This is the only file that assumes anything about concurrency. Lanes may
//! complete in any order but write only their own slot; `flush` joins the whole
//! batch before handing results to the owner in input order, so the coordinator
//! and lane tasks never touch shared semantic state at the same time. A runtime
//! that cannot actually overlap `concurrent` submissions is reported as a
//! fallback rather than silently serialized.

const std = @import("std");

const batch_scheduler = @import("../../../io/batch_scheduler.zig");
const lane = @import("lane.zig");
const report_types = @import("report.zig");
const Reader = @import("../../../state/Reader.zig");
const vm = @import("../../../vm.zig");

const Report = report_types.Report;

/// `Owner` must expose `acceptLaneOutcome(*const OwnedIncluded, *Outcome) void`
/// and `laneProgress() vm.BlockResult`.
pub fn Schedule(comptime Engine: type, comptime Owner: type) type {
    const Lane = lane.Lane(Engine);

    return struct {
        const Self = @This();

        const Slot = struct {
            input_arena: std.heap.ArenaAllocator,
            task_arena: std.heap.ArenaAllocator,
            expected: ?Lane.OwnedIncluded = null,
            outcome: ?Lane.Outcome = null,

            fn reset(self: *Slot) void {
                // Evidence is arena-allocated, so the reset below reclaims it.
                if (self.outcome) |*outcome| outcome.deinit(self.task_arena.allocator());
                self.outcome = null;
                self.expected = null;
                _ = self.task_arena.reset(.retain_capacity);
                _ = self.input_arena.reset(.retain_capacity);
            }

            fn deinit(self: *Slot) void {
                if (self.outcome) |*outcome| outcome.deinit(self.task_arena.allocator());
                self.task_arena.deinit();
                self.input_arena.deinit();
                self.* = undefined;
            }
        };

        const TaskContext = struct {
            lane_context: Lane.Context,
            base_reader: Reader,
        };

        allocator: std.mem.Allocator,
        io: std.Io,
        submission: report_types.ParallelSubmission,
        report: *Report,
        lane_context: Lane.Context,
        base_reader: Reader,
        slots: []Slot,
        pending_count: usize = 0,
        expected_progress: vm.BlockResult = .{},
        enabled: bool = true,

        pub fn init(
            allocator: std.mem.Allocator,
            report: *Report,
            execution: report_types.ParallelExecution,
            lane_context: Lane.Context,
        ) !Self {
            const slots = try allocator.alloc(Slot, execution.max_in_flight);
            for (slots) |*slot| slot.* = .{
                .input_arena = std.heap.ArenaAllocator.init(allocator),
                .task_arena = std.heap.ArenaAllocator.init(execution.lane_allocator),
            };
            return .{
                .allocator = allocator,
                .io = execution.io,
                .submission = execution.submission,
                .report = report,
                .lane_context = .{
                    .env = lane_context.env,
                    .claim = lane_context.claim,
                    // Parallel lanes prepare code privately.
                    .prepared_code_backend = null,
                    .block_hash_source = execution.block_hash_source,
                },
                .base_reader = execution.state_reader,
                .slots = slots,
            };
        }

        pub fn deinit(self: *Self) void {
            self.discard(self.expected_progress);
            for (self.slots) |*slot| slot.deinit();
            self.allocator.free(self.slots);
            self.* = undefined;
        }

        pub fn expectedProgress(self: *const Self) vm.BlockResult {
            return self.expected_progress;
        }

        pub fn isEnabled(self: *const Self) bool {
            return self.enabled;
        }

        pub fn hasPending(self: *const Self) bool {
            return self.pending_count != 0;
        }

        pub fn isFull(self: *const Self) bool {
            return self.pending_count == self.slots.len;
        }

        pub fn stage(self: *Self, included: Lane.Included, progress_after: vm.BlockResult) !void {
            std.debug.assert(self.enabled);
            std.debug.assert(self.pending_count < self.slots.len);
            const slot = &self.slots[self.pending_count];
            std.debug.assert(slot.expected == null and slot.outcome == null);
            slot.expected = try Lane.OwnedIncluded.init(slot.input_arena.allocator(), included);
            self.pending_count += 1;
            self.expected_progress = progress_after;
        }

        /// Run one full bounded batch, then hand each detached result to the
        /// owner in transaction order. Returns the transaction index that could
        /// not be submitted when the runtime refuses to overlap the batch.
        pub fn flush(self: *Self, owner: *Owner) std.Io.Cancelable!?usize {
            std.debug.assert(self.enabled);
            if (self.pending_count == 0) return null;

            const pending_count = self.pending_count;
            const task_context = TaskContext{
                .lane_context = self.lane_context,
                .base_reader = self.base_reader,
            };
            const batch_result = batch_scheduler.run(
                Slot,
                self.io,
                self.submission,
                self.slots[0..pending_count],
                task_context,
                runTask,
            ) catch |err| {
                self.discard(owner.laneProgress());
                return err;
            };
            switch (batch_result) {
                .completed => {
                    self.recordBatch(pending_count);
                    self.report.parallel_batches += 1;
                    for (self.slots[0..pending_count]) |*slot| {
                        owner.acceptLaneOutcome(&slot.expected.?, &slot.outcome.?);
                        slot.reset();
                    }
                    self.pending_count = 0;
                    self.expected_progress = owner.laneProgress();
                    return null;
                },
                .concurrency_unavailable => |submitted| {
                    self.recordBatch(submitted);
                    return self.slots[submitted].expected.?.tx_index;
                },
            }
        }

        pub fn discard(self: *Self, progress: vm.BlockResult) void {
            for (self.slots[0..self.pending_count]) |*slot| slot.reset();
            self.pending_count = 0;
            self.expected_progress = progress;
        }

        pub fn disable(self: *Self) void {
            self.enabled = false;
        }

        fn recordBatch(self: *Self, submitted: usize) void {
            self.report.parallel_submitted_lanes += submitted;
            self.report.parallel_max_batch_size = @max(
                self.report.parallel_max_batch_size,
                submitted,
            );
        }

        fn runTask(context: TaskContext, slot: *Slot) std.Io.Cancelable!void {
            slot.outcome = Lane.run(
                context.lane_context,
                slot.task_arena.allocator(),
                context.base_reader,
                slot.expected.?.view(),
            );
        }
    };
}
