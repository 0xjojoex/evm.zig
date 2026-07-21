//! Bounded `std.Io.Group` submission and join.
//!
//! Tasks may complete in any order and may write only their own item. The
//! caller regains control only after the complete group is joined. The caller
//! owns item storage and all task/result semantics.

const std = @import("std");

pub const Submission = enum {
    /// Best-effort scheduling. The runtime may overlap the task or execute it
    /// eagerly on the submitting context when async capacity is unavailable.
    async,
    /// Require a distinct unit of concurrency. Failure cancels the submitted
    /// group and lets the BAL diagnostic lane fall back to serial execution.
    concurrent,
};

pub const Result = union(enum) {
    completed,
    concurrency_unavailable: usize,
};

pub fn run(
    comptime Item: type,
    io: std.Io,
    submission: Submission,
    items: []Item,
    task_context: anytype,
    task: anytype,
) std.Io.Cancelable!Result {
    var group: std.Io.Group = .init;
    var submitted: usize = 0;
    while (submitted < items.len) : (submitted += 1) {
        switch (submission) {
            .async => group.async(io, task, .{ task_context, &items[submitted] }),
            .concurrent => group.concurrent(
                io,
                task,
                .{ task_context, &items[submitted] },
            ) catch {
                group.cancel(io);
                return .{ .concurrency_unavailable = submitted };
            },
        }
    }
    try group.await(io);
    return .completed;
}

test "reverse task completion is visited in item order" {
    const Shared = struct {
        release_first: std.Io.Event = .unset,
        completion_order: [2]usize = undefined,
        visit_order: [2]usize = undefined,
        visit_count: usize = 0,
    };
    const Item = struct {
        index: usize,
        shared: *Shared,
    };
    const Worker = struct {
        fn run(io: std.Io, item: *Item) std.Io.Cancelable!void {
            if (item.index == 0) {
                try item.shared.release_first.wait(io);
                item.shared.completion_order[1] = 0;
            } else {
                item.shared.completion_order[0] = 1;
                item.shared.release_first.set(io);
            }
        }

        fn visit(_: void, item: *Item) void {
            item.shared.visit_order[item.shared.visit_count] = item.index;
            item.shared.visit_count += 1;
        }
    };

    var shared = Shared{};
    var items = [_]Item{
        .{ .index = 0, .shared = &shared },
        .{ .index = 1, .shared = &shared },
    };
    const result = try run(
        Item,
        std.testing.io,
        .concurrent,
        &items,
        std.testing.io,
        Worker.run,
    );
    try std.testing.expect(result == .completed);
    for (&items) |*item| Worker.visit({}, item);
    try std.testing.expectEqualSlices(usize, &.{ 1, 0 }, &shared.completion_order);
    try std.testing.expectEqualSlices(usize, &.{ 0, 1 }, &shared.visit_order);
}
