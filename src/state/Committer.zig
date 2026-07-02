//! Write-side state commit contract.
//!
//! A committer applies the final `Changeset` emitted by an execution overlay to
//! an integration-owned store. It is intentionally not used for opcode-level
//! writes; speculative execution writes belong in `Overlay`.

const std = @import("std");

const Changeset = @import("./Changeset.zig");

const Committer = @This();

ptr: *anyopaque,
vtable: *const VTable,

pub const VTable = struct {
    commit: *const fn (ptr: *anyopaque, changeset: *const Changeset) anyerror!void,
};

pub fn commit(self: Committer, changeset: *const Changeset) !void {
    return self.vtable.commit(self.ptr, changeset);
}

test "committer delegates commit" {
    var called = false;
    const writer = Committer{ .ptr = &called, .vtable = &.{
        .commit = struct {
            fn commit(ptr: *anyopaque, changeset: *const Changeset) !void {
                _ = changeset;
                const flag: *bool = @ptrCast(@alignCast(ptr));
                flag.* = true;
            }
        }.commit,
    } };
    var changeset = Changeset.init();
    defer changeset.deinit(std.testing.allocator);

    try writer.commit(&changeset);
    try std.testing.expect(called);
}
