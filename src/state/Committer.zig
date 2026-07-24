//! Write-side state commit contract.
//!
//! A committer synchronously consumes a borrowed semantic change view. The
//! integration owns persistence layout, allocation, ordering, and retention.

const TrackedState = @import("./TrackedState.zig");
const ChangesView = TrackedState.ChangesView;

const Committer = @This();

ptr: *anyopaque,
vtable: *const VTable,

pub const VTable = struct {
    commit: *const fn (ptr: *anyopaque, changes: ChangesView) anyerror!void,
};

pub fn commit(self: Committer, changes: ChangesView) !void {
    return self.vtable.commit(self.ptr, changes);
}

test "committer delegates commit" {
    const std = @import("std");
    const addr = @import("../address.zig").addr;
    var state = TrackedState.init(std.testing.allocator);
    defer state.deinit();
    const attempt = state.beginTransaction();
    try state.setBalance(addr(1), 1);
    state.seal(attempt);
    state.retain(attempt);

    var count: u32 = 0;
    const writer = Committer{ .ptr = &count, .vtable = &.{
        .commit = struct {
            fn commit(ptr: *anyopaque, changes: ChangesView) !void {
                const result: *u32 = @ptrCast(@alignCast(ptr));
                result.* = changes.accounts.len();
            }
        }.commit,
    } };

    try writer.commit(state.acceptedView().changes());
    try std.testing.expectEqual(@as(u32, 1), count);
}
