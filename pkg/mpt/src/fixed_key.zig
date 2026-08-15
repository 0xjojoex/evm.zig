//! Fixed-key allocation-free batch binding over an already authenticated catalog.
//!
//! The catalog owns decoded topology. This pass only walks integer links and
//! returns borrowed leaf values. It allocates nothing and shares prefixes
//! between sorted 32-byte state/storage keys.

const std = @import("std");

const catalog = @import("catalog.zig");
const errors = @import("error.zig");
const nibble = @import("nibble.zig");

pub const FixedKey = [32]u8;
pub const key_nibbles = @sizeOf(FixedKey) * 2;
pub const max_path_nodes = key_nibbles + 1;

pub const FixedAbsence = enum {
    empty_trie,
    missing_branch_child,
    divergent_path,
};

pub const FixedLookup = union(enum) {
    present: []const u8,
    absent: FixedAbsence,
};

pub const Error = errors.CodecError || error{MissingNode};
pub const BatchLookupError = Error || error{ DuplicateKey, UnsortedKeys };

pub const BindWorkspace = struct {
    frames: [max_path_nodes]Frame = undefined,
    len: u7 = 0,
};

/// Bind sorted unique fixed-width keys against an immutable catalog.
/// Results retain trie-key order and borrow value spans from witness nodes.
pub fn bindSorted(
    topology: catalog.Catalog,
    root: catalog.RootRef,
    keys: []const FixedKey,
    results: []FixedLookup,
    workspace: *BindWorkspace,
) BatchLookupError!void {
    std.debug.assert(results.len == keys.len);
    std.debug.assert(workspace.len == 0);
    try validateSortedKeys(keys);
    return bindAssumeSorted(topology, root, keys, results, workspace);
}

/// Bind keys whose strict sorted order was already established by the caller.
pub fn bindAssumeSorted(
    topology: catalog.Catalog,
    root: catalog.RootRef,
    keys: []const FixedKey,
    results: []FixedLookup,
    workspace: *BindWorkspace,
) Error!void {
    std.debug.assert(results.len == keys.len);
    std.debug.assert(workspace.len == 0);
    defer workspace.len = 0;
    if (keys.len == 0) return;
    if (root == .empty) {
        @memset(results, .{ .absent = .empty_trie });
        return;
    }

    push(workspace, .{ .node = root.node.id, .begin = 0, .end = keys.len, .depth = 0 });
    while (workspace.len != 0) {
        const frame = &workspace.frames[workspace.len - 1];
        switch (frame.state) {
            .enter => {
                const node = topology.node(frame.node) orelse return error.InvalidNodeReference;
                switch (node.kind) {
                    .leaf => {
                        const path = node.path() orelse return error.InvalidNode;
                        const remaining = key_nibbles - @as(usize, frame.depth);
                        if (path.len != remaining) return error.InvalidNode;
                        const value = node.value() orelse return error.InvalidNode;
                        for (frame.begin..frame.end) |key_index| {
                            results[key_index] = if (path.matchesKey(&keys[key_index], frame.depth))
                                .{ .present = value }
                            else
                                .{ .absent = .divergent_path };
                        }
                        pop(workspace);
                    },
                    .extension => {
                        const path = node.path() orelse return error.InvalidNode;
                        const remaining = key_nibbles - @as(usize, frame.depth);
                        if (path.len >= remaining) return error.InvalidNode;

                        var match_begin: ?usize = null;
                        var match_end = frame.begin;
                        for (frame.begin..frame.end) |key_index| {
                            if (path.matchesKey(&keys[key_index], frame.depth)) {
                                if (match_begin == null) match_begin = key_index;
                                match_end = key_index + 1;
                            } else {
                                results[key_index] = .{ .absent = .divergent_path };
                            }
                        }
                        const begin = match_begin orelse {
                            pop(workspace);
                            continue;
                        };
                        const child = try followRequired(
                            node.extensionChild() orelse return error.InvalidNodeReference,
                        );
                        const child_node = topology.node(child) orelse return error.InvalidNodeReference;
                        if (child_node.kind != .branch) return error.NonCanonicalNode;
                        frame.* = .{
                            .node = child,
                            .begin = begin,
                            .end = match_end,
                            .depth = frame.depth + @as(u7, @intCast(path.len)),
                        };
                    },
                    .branch => {
                        if (node.value() != null) return error.NonCanonicalNode;
                        if (frame.depth == key_nibbles) return error.InvalidNode;
                        frame.state = .{ .branch = .{ .next = frame.begin } };
                    },
                }
            },
            .branch => |*branch| {
                if (branch.next == frame.end) {
                    pop(workspace);
                    continue;
                }
                const selected: u4 = @intCast(nibble.keyNibbleAt(&keys[branch.next], frame.depth));
                var group_end = branch.next + 1;
                while (group_end < frame.end and
                    nibble.keyNibbleAt(&keys[group_end], frame.depth) == selected)
                {
                    group_end += 1;
                }
                const group_begin = branch.next;
                branch.next = group_end;
                const children = topology.branchChildren(frame.node) orelse
                    return error.InvalidNodeReference;
                const child = (try follow(children[selected])) orelse {
                    @memset(results[group_begin..group_end], .{ .absent = .missing_branch_child });
                    continue;
                };
                push(workspace, .{
                    .node = child,
                    .begin = group_begin,
                    .end = group_end,
                    .depth = frame.depth + 1,
                });
            },
        }
    }
}

const Frame = struct {
    node: catalog.NodeId,
    begin: usize,
    end: usize,
    depth: u7,
    state: union(enum) {
        enter,
        branch: struct { next: usize },
    } = .enter,
};

fn push(workspace: *BindWorkspace, frame: Frame) void {
    std.debug.assert(workspace.len < max_path_nodes);
    workspace.frames[workspace.len] = frame;
    workspace.len += 1;
}

fn pop(workspace: *BindWorkspace) void {
    std.debug.assert(workspace.len != 0);
    workspace.len -= 1;
}

fn followRequired(link: catalog.Link) Error!catalog.NodeId {
    return (try follow(link)) orelse return error.InvalidNodeReference;
}

fn follow(link: catalog.Link) Error!?catalog.NodeId {
    return switch (link) {
        .empty => null,
        .@"opaque" => error.MissingNode,
        _ => link.node() orelse error.InvalidNodeReference,
    };
}

fn validateSortedKeys(keys: []const FixedKey) BatchLookupError!void {
    if (keys.len < 2) return;
    for (keys[1..], keys[0 .. keys.len - 1]) |current, previous| {
        switch (std.mem.order(u8, &previous, &current)) {
            .lt => {},
            .eq => return error.DuplicateKey,
            .gt => return error.UnsortedKeys,
        }
    }
}
