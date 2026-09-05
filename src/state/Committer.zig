//! Write-side state commit contract.
//!
//! A committer synchronously consumes a detached block-final delta. The
//! integration owns persistence layout, allocation, ordering, and retention;
//! the delta is borrowed for the duration of the call.

const StateDelta = @import("./StateDelta.zig");

const Committer = @This();

ptr: *anyopaque,
vtable: *const VTable,

pub const VTable = struct {
    commit: *const fn (ptr: *anyopaque, delta: StateDelta.View) anyerror!void,
};

pub fn commit(self: Committer, delta: StateDelta.View) !void {
    return self.vtable.commit(self.ptr, delta);
}
