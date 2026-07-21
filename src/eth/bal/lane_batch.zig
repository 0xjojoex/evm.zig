//! Synchronous bounded batches for isolated BAL candidate lanes.
//!
//! Tasks may complete in any order but write only their own slot. `flush`
//! joins the complete batch before invoking the caller's acceptance callback
//! in input order, so the coordinator and lane tasks never mutate shared
//! semantic state concurrently.

const std = @import("std");

const batch_scheduler = @import("../../io/batch_scheduler.zig");
const state = @import("../../state.zig");
const vm = @import("../../vm.zig");

pub fn Batch(
    comptime Owner: type,
    comptime Source: type,
    comptime Item: type,
    comptime Outcome: type,
    comptime Progress: type,
    comptime Callbacks: type,
) type {
    return struct {
        const Self = @This();

        const Slot = struct {
            input_arena: std.heap.ArenaAllocator,
            task_arena: std.heap.ArenaAllocator,
            expected: ?Item = null,
            outcome: ?Outcome = null,

            fn reset(self: *Slot) void {
                if (self.outcome) |*outcome| Callbacks.deinitOutcome(outcome);
                self.outcome = null;
                self.expected = null;
                _ = self.task_arena.reset(.retain_capacity);
                _ = self.input_arena.reset(.retain_capacity);
            }

            fn deinit(self: *Slot) void {
                if (self.outcome) |*outcome| Callbacks.deinitOutcome(outcome);
                self.task_arena.deinit();
                self.input_arena.deinit();
                self.* = undefined;
            }
        };

        const TaskContext = struct {
            owner: *const Owner,
            base_reader: state.Reader,
            block_hash_source: ?vm.BlockHashSource,
        };

        pub const Unavailable = struct {
            submitted: usize,
            failed: *const Item,
        };

        pub const FlushResult = union(enum) {
            completed: usize,
            concurrency_unavailable: Unavailable,
        };

        allocator: std.mem.Allocator,
        io: std.Io,
        submission: batch_scheduler.Submission,
        state_reader: state.Reader,
        block_hash_source: ?vm.BlockHashSource,
        slots: []Slot,
        pending_count: usize = 0,
        expected_progress: Progress,
        enabled: bool = true,

        pub fn init(
            allocator: std.mem.Allocator,
            lane_allocator: std.mem.Allocator,
            io: std.Io,
            submission: batch_scheduler.Submission,
            state_reader: state.Reader,
            block_hash_source: ?vm.BlockHashSource,
            max_in_flight: usize,
            initial_progress: Progress,
        ) !Self {
            const slots = try allocator.alloc(Slot, max_in_flight);
            for (slots) |*slot| slot.* = .{
                .input_arena = std.heap.ArenaAllocator.init(allocator),
                .task_arena = std.heap.ArenaAllocator.init(lane_allocator),
            };
            return .{
                .allocator = allocator,
                .io = io,
                .submission = submission,
                .state_reader = state_reader,
                .block_hash_source = block_hash_source,
                .slots = slots,
                .expected_progress = initial_progress,
            };
        }

        pub fn deinit(self: *Self) void {
            self.discard(self.expected_progress);
            for (self.slots) |*slot| slot.deinit();
            self.allocator.free(self.slots);
            self.* = undefined;
        }

        pub fn expectedProgress(self: *const Self) Progress {
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

        pub fn stage(self: *Self, source: Source, progress_after: Progress) !void {
            std.debug.assert(self.enabled);
            std.debug.assert(self.pending_count < self.slots.len);
            const slot = &self.slots[self.pending_count];
            std.debug.assert(slot.expected == null and slot.outcome == null);
            slot.expected = try Callbacks.cloneItem(slot.input_arena.allocator(), source);
            self.pending_count += 1;
            self.expected_progress = progress_after;
        }

        pub fn flush(self: *Self, owner: *Owner) std.Io.Cancelable!FlushResult {
            std.debug.assert(self.enabled);
            if (self.pending_count == 0) return .{ .completed = 0 };

            const pending_count = self.pending_count;
            const task_context = TaskContext{
                .owner = owner,
                .base_reader = self.state_reader,
                .block_hash_source = self.block_hash_source,
            };
            const batch_result = batch_scheduler.run(
                Slot,
                self.io,
                self.submission,
                self.slots[0..pending_count],
                task_context,
                runTask,
            ) catch |err| {
                self.discard(Callbacks.progress(owner));
                return err;
            };
            switch (batch_result) {
                .completed => {
                    for (self.slots[0..pending_count]) |*slot| {
                        Callbacks.accept(owner, &slot.expected.?, &slot.outcome.?);
                        slot.reset();
                    }
                    self.pending_count = 0;
                    self.expected_progress = Callbacks.progress(owner);
                    return .{ .completed = pending_count };
                },
                .concurrency_unavailable => |submitted| return .{
                    .concurrency_unavailable = .{
                        .submitted = submitted,
                        .failed = &self.slots[submitted].expected.?,
                    },
                },
            }
        }

        pub fn discard(self: *Self, progress: Progress) void {
            for (self.slots[0..self.pending_count]) |*slot| slot.reset();
            self.pending_count = 0;
            self.expected_progress = progress;
        }

        pub fn disable(self: *Self) void {
            self.enabled = false;
        }

        fn runTask(context: TaskContext, slot: *Slot) std.Io.Cancelable!void {
            slot.outcome = Callbacks.run(
                context.owner,
                slot.task_arena.allocator(),
                context.base_reader,
                context.block_hash_source,
                &slot.expected.?,
            );
        }
    };
}
