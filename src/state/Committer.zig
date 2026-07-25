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
