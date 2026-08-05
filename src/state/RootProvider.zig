//! Post-state root contract for stateful integrations.
//!
//! A root provider derives the state root that a borrowed change view would
//! produce, without committing it. The integration owns the trie, its node
//! storage, and any caching.

const std = @import("std");

const TrackedState = @import("./TrackedState.zig");
const ChangesView = TrackedState.ChangesView;

const RootProvider = @This();

ptr: *anyopaque,
vtable: *const VTable,

pub const VTable = struct {
    afterChanges: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator, changes: ChangesView) anyerror![32]u8,
};

pub fn afterChanges(self: RootProvider, allocator: std.mem.Allocator, changes: ChangesView) ![32]u8 {
    return self.vtable.afterChanges(self.ptr, allocator, changes);
}
