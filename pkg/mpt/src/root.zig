//! Trie root construction from a complete set of key/value entries.
//!
//! Builds the trie iteratively in the workspace (no recursion, no heap) and
//! returns only the resulting root hash.

const std = @import("std");
const rlp = @import("rlp");

const Error = @import("error.zig").BuildError;
const node_hash = @import("hash.zig");
const Root = node_hash.Root;
const nibble = @import("nibble.zig");
const Workspace = @import("workspace.zig").Workspace;

/// A key/value pair to insert into the trie. Both slices are borrowed.
pub const Entry = struct {
    key: []const u8,
    value: []const u8,
};

/// Checked workspace requirements derived from one concrete operation.
pub const Requirements = struct {
    key_bytes: usize,
    node_capacity: usize,
    node_rlp_bytes: usize,
    step_capacity: usize,
};

/// Derive workspace requirements from a complete root input.
pub fn requirements(entries: []const Entry) Error!Requirements {
    if (entries.len == 0) return .{
        .key_bytes = 0,
        .node_capacity = 0,
        .node_rlp_bytes = 0,
        .step_capacity = 0,
    };

    var max_key_bytes: usize = 0;
    var max_value_bytes: usize = 0;
    for (entries) |entry| {
        max_key_bytes = @max(max_key_bytes, entry.key.len);
        max_value_bytes = @max(max_value_bytes, entry.value.len);
    }

    const node_capacity = std.math.mul(usize, entries.len, 3) catch
        return error.ResourceLimitExceeded;
    const step_capacity = std.math.mul(usize, node_capacity, 2) catch
        return error.ResourceLimitExceeded;
    return .{
        .key_bytes = max_key_bytes,
        .node_capacity = node_capacity,
        .node_rlp_bytes = try nodeRlpUpperBound(max_key_bytes, max_value_bytes),
        .step_capacity = step_capacity,
    };
}

/// Conservative encoded-node bound for the given key and value maxima.
pub fn nodeRlpUpperBound(max_key_bytes: usize, max_value_bytes: usize) Error!usize {
    const compact_len = std.math.add(usize, max_key_bytes, 1) catch
        return error.ResourceLimitExceeded;
    const compact_item_len = try itemUpperBound(compact_len);
    const value_item_len = try itemUpperBound(max_value_bytes);

    const leaf_payload = std.math.add(usize, compact_item_len, value_item_len) catch
        return error.ResourceLimitExceeded;
    const leaf = try itemUpperBound(leaf_payload);

    const extension_payload = std.math.add(usize, compact_item_len, 33) catch
        return error.ResourceLimitExceeded;
    const extension = try itemUpperBound(extension_payload);

    const branch_children = std.math.mul(usize, 16, 33) catch
        return error.ResourceLimitExceeded;
    const branch_payload = std.math.add(usize, branch_children, value_item_len) catch
        return error.ResourceLimitExceeded;
    const branch = try itemUpperBound(branch_payload);

    return @max(leaf, @max(extension, branch));
}

fn itemUpperBound(payload_len: usize) Error!usize {
    const prefix_len: usize = if (payload_len < 56)
        1
    else
        std.math.add(usize, 1, lengthByteLen(payload_len)) catch
            return error.ResourceLimitExceeded;
    return std.math.add(usize, prefix_len, payload_len) catch
        error.ResourceLimitExceeded;
}

/// Bytes of workspace needed to build a root. Set `include_sort` when the
/// entries will be passed unsorted to `root`.
pub fn workspaceSize(entries: []const Entry, include_sort: bool) Error!usize {
    return workspaceSizeFor(entries.len, try requirements(entries), include_sort);
}

pub fn workspaceSizeFor(entry_count: usize, needed: Requirements, include_sort: bool) Error!usize {
    if (entry_count == 0) return 0;
    const possible_nodes = std.math.mul(usize, entry_count, 3) catch
        return error.ResourceLimitExceeded;
    const capacity = @min(possible_nodes, needed.node_capacity);
    if (capacity == 0 or capacity > std.math.maxInt(NodeIndex)) {
        return error.ResourceLimitExceeded;
    }

    const workspace_alignment = @max(
        @alignOf(Entry),
        @alignOf(Node),
        @alignOf(Task),
        @alignOf(Reference),
    );
    var offset: usize = workspace_alignment - 1;
    if (include_sort) offset = try addRegion(Entry, offset, entry_count);
    offset = try addRegion(Node, offset, capacity);
    offset = try addRegion(Task, offset, capacity);
    offset = try addRegion(Reference, offset, capacity);
    const compact_buffer_len = std.math.add(usize, needed.key_bytes, 1) catch
        return error.ResourceLimitExceeded;
    offset = try addRegion(u8, offset, compact_buffer_len);
    offset = try addRegion(u8, offset, needed.node_rlp_bytes);
    return offset;
}

const NodeIndex = u32;

const Node = union(enum) {
    pending,
    leaf: Leaf,
    extension: Extension,
    branch: Branch,

    const Leaf = struct {
        path: nibble.Path,
        value: []const u8,
    };

    const Extension = struct {
        path: nibble.Path,
        child: NodeIndex,
    };

    const Branch = struct {
        children: [16]?NodeIndex,
        value: ?[]const u8,
    };
};

const Task = struct {
    node: NodeIndex,
    start: usize,
    end: usize,
    depth: usize,
};

const Reference = union(enum) {
    embedded: Embedded,
    hashed: Root,

    const Embedded = struct {
        len: u8,
        bytes: [31]u8,
    };
};

/// Build the root from `entries` already sorted ascending by key; returns
/// `error.UnsortedKeys` if they are not.
pub fn rootSorted(
    keccak_context: anytype,
    workspace: *Workspace,
    entries: []const Entry,
    needed: Requirements,
) Error!Root {
    workspace.reset();
    if (entries.len == 0) return node_hash.empty_root;
    try validateEntries(entries, true);
    return buildRoot(keccak_context, workspace, entries, needed);
}

/// Build the root from `entries` in any order; they are copied into the
/// workspace and sorted before building.
pub fn root(
    keccak_context: anytype,
    workspace: *Workspace,
    entries: []const Entry,
    needed: Requirements,
) Error!Root {
    workspace.reset();
    if (entries.len == 0) return node_hash.empty_root;
    try validateEntries(entries, false);

    var fixed = std.heap.FixedBufferAllocator.init(workspace.buffer);
    const allocator = fixed.allocator();
    const sorted = allocator.dupe(Entry, entries) catch return error.WorkspaceTooSmall;
    std.mem.sort(Entry, sorted, {}, entryLessThan);
    try validateOrder(sorted);
    return buildRootWithAllocator(keccak_context, workspace, &fixed, sorted, needed);
}

fn buildRoot(
    keccak_context: anytype,
    workspace: *Workspace,
    entries: []const Entry,
    needed: Requirements,
) Error!Root {
    var fixed = std.heap.FixedBufferAllocator.init(workspace.buffer);
    return buildRootWithAllocator(keccak_context, workspace, &fixed, entries, needed);
}

fn buildRootWithAllocator(
    keccak_context: anytype,
    workspace: *Workspace,
    fixed: *std.heap.FixedBufferAllocator,
    entries: []const Entry,
    needed: Requirements,
) Error!Root {
    const allocator = fixed.allocator();
    const possible_nodes = std.math.mul(usize, entries.len, 3) catch
        return error.ResourceLimitExceeded;
    const capacity = @min(possible_nodes, needed.node_capacity);
    if (capacity == 0 or capacity > std.math.maxInt(NodeIndex)) {
        return error.ResourceLimitExceeded;
    }

    const nodes = allocator.alloc(Node, capacity) catch return error.WorkspaceTooSmall;
    const tasks = allocator.alloc(Task, capacity) catch return error.WorkspaceTooSmall;
    const references = allocator.alloc(Reference, capacity) catch return error.WorkspaceTooSmall;
    const compact_buffer_len = std.math.add(usize, needed.key_bytes, 1) catch
        return error.ResourceLimitExceeded;
    const compact_buffer = allocator.alloc(u8, compact_buffer_len) catch
        return error.WorkspaceTooSmall;
    const node_buffer = allocator.alloc(u8, needed.node_rlp_bytes) catch
        return error.WorkspaceTooSmall;

    var node_len: usize = 1;
    nodes[0] = .pending;
    var task_len: usize = 1;
    tasks[0] = .{ .node = 0, .start = 0, .end = entries.len, .depth = 0 };
    var steps: usize = 0;

    while (task_len > 0) {
        task_len -= 1;
        const task = tasks[task_len];
        steps = std.math.add(usize, steps, 1) catch return error.ResourceLimitExceeded;
        if (steps > needed.step_capacity) return error.ResourceLimitExceeded;

        const group = entries[task.start..task.end];
        if (group.len == 1) {
            const key_len = nibble.keyNibbleLen(group[0].key);
            nodes[task.node] = .{ .leaf = .{
                .path = .{ .key = group[0].key, .start = task.depth, .len = key_len - task.depth },
                .value = group[0].value,
            } };
            continue;
        }

        const common = commonPrefixLen(group, task.depth);
        if (common > 0) {
            const child = try appendPending(nodes, &node_len, capacity);
            nodes[task.node] = .{ .extension = .{
                .path = .{ .key = group[0].key, .start = task.depth, .len = common },
                .child = child,
            } };
            try pushTask(tasks, &task_len, .{
                .node = child,
                .start = task.start,
                .end = task.end,
                .depth = task.depth + common,
            });
            continue;
        }

        var branch: Node.Branch = .{
            .children = [_]?NodeIndex{null} ** 16,
            .value = null,
        };
        var index = task.start;
        while (index < task.end and nibble.keyNibbleLen(entries[index].key) == task.depth) : (index += 1) {
            if (branch.value != null) return error.DuplicateKey;
            branch.value = entries[index].value;
        }

        for (0..16) |child_nibble| {
            if (index >= task.end or nibble.keyNibbleLen(entries[index].key) == task.depth or
                nibble.keyNibbleAt(entries[index].key, task.depth) != child_nibble)
            {
                continue;
            }
            const start = index;
            while (index < task.end and nibble.keyNibbleLen(entries[index].key) > task.depth and
                nibble.keyNibbleAt(entries[index].key, task.depth) == child_nibble)
            {
                index += 1;
            }
            const child = try appendPending(nodes, &node_len, capacity);
            branch.children[child_nibble] = child;
            try pushTask(tasks, &task_len, .{
                .node = child,
                .start = start,
                .end = index,
                .depth = task.depth + 1,
            });
        }
        if (index != task.end) return error.DuplicateKey;
        nodes[task.node] = .{ .branch = branch };
    }

    var root_hash: Root = undefined;
    var index = node_len;
    while (index > 0) {
        index -= 1;
        steps = std.math.add(usize, steps, 1) catch return error.ResourceLimitExceeded;
        if (steps > needed.step_capacity) return error.ResourceLimitExceeded;
        const encoded = try encodeNode(node_buffer, compact_buffer, nodes[index], references);
        if (index == 0) {
            root_hash = keccak_context.keccak256(encoded);
        } else {
            references[index] = if (encoded.len < 32)
                embeddedReference(encoded)
            else
                .{ .hashed = keccak_context.keccak256(encoded) };
        }
    }

    workspace.peak_used_bytes = fixed.end_index;
    return root_hash;
}

fn appendPending(nodes: []Node, len: *usize, capacity: usize) Error!NodeIndex {
    if (len.* == capacity) return error.ResourceLimitExceeded;
    const index: NodeIndex = @intCast(len.*);
    nodes[len.*] = .pending;
    len.* += 1;
    return index;
}

fn pushTask(tasks: []Task, len: *usize, task: Task) Error!void {
    if (len.* == tasks.len) return error.ResourceLimitExceeded;
    tasks[len.*] = task;
    len.* += 1;
}

fn encodeNode(
    node_buffer: []u8,
    compact_buffer: []u8,
    node: Node,
    references: []const Reference,
) Error![]const u8 {
    return switch (node) {
        .pending => unreachable,
        .leaf => |leaf| encodeLeaf(node_buffer, compact_buffer, leaf),
        .extension => |extension| encodeExtension(node_buffer, compact_buffer, extension, references),
        .branch => |branch| encodeBranch(node_buffer, branch, references),
    };
}

fn encodeLeaf(node_buffer: []u8, compact_buffer: []u8, leaf: Node.Leaf) Error![]const u8 {
    const compact = try nibble.encodeCompact(compact_buffer, leaf.path, true);
    const payload_len = try addEncodedLengths(&.{ bytesEncodedLen(compact), bytesEncodedLen(leaf.value) });
    var writer = try listWriter(node_buffer, payload_len);
    try writeBytes(&writer, compact);
    try writeBytes(&writer, leaf.value);
    return node_buffer[0 .. listPrefixLen(payload_len) + writer.written().len];
}

fn encodeExtension(
    node_buffer: []u8,
    compact_buffer: []u8,
    extension: Node.Extension,
    references: []const Reference,
) Error![]const u8 {
    const compact = try nibble.encodeCompact(compact_buffer, extension.path, false);
    const child = references[extension.child];
    const payload_len = try addEncodedLengths(&.{ bytesEncodedLen(compact), referenceEncodedLen(child) });
    var writer = try listWriter(node_buffer, payload_len);
    try writeBytes(&writer, compact);
    try writeReference(&writer, child);
    return node_buffer[0 .. listPrefixLen(payload_len) + writer.written().len];
}

fn encodeBranch(node_buffer: []u8, branch: Node.Branch, references: []const Reference) Error![]const u8 {
    var payload_len: usize = bytesEncodedLen("");
    for (branch.children) |child| {
        payload_len = std.math.add(usize, payload_len, if (child) |child_index|
            referenceEncodedLen(references[child_index])
        else
            bytesEncodedLen("")) catch return error.ResourceLimitExceeded;
    }
    if (branch.value) |value| {
        payload_len = std.math.sub(usize, payload_len, bytesEncodedLen("")) catch unreachable;
        payload_len = std.math.add(usize, payload_len, bytesEncodedLen(value)) catch
            return error.ResourceLimitExceeded;
    }

    var writer = try listWriter(node_buffer, payload_len);
    for (branch.children) |child| {
        if (child) |child_index| {
            try writeReference(&writer, references[child_index]);
        } else {
            try writeBytes(&writer, "");
        }
    }
    try writeBytes(&writer, branch.value orelse "");
    return node_buffer[0 .. listPrefixLen(payload_len) + writer.written().len];
}

fn listWriter(node_buffer: []u8, payload_len: usize) Error!rlp.Writer {
    var prefix_buffer: [rlp.max_length_prefix_bytes]u8 = undefined;
    const prefix = rlp.listPrefix(&prefix_buffer, payload_len);
    const total_len = std.math.add(usize, prefix.len, payload_len) catch
        return error.ResourceLimitExceeded;
    if (total_len > node_buffer.len) return error.ResourceLimitExceeded;
    @memcpy(node_buffer[0..prefix.len], prefix);
    return rlp.Writer.fixed(node_buffer[prefix.len..total_len]);
}

fn writeBytes(writer: *rlp.Writer, value: []const u8) Error!void {
    writer.bytes(value) catch |err| switch (err) {
        error.NoSpaceLeft => return error.ResourceLimitExceeded,
        error.OutOfMemory => unreachable,
    };
}

fn writeReference(writer: *rlp.Writer, reference: Reference) Error!void {
    switch (reference) {
        .hashed => |digest| try writeBytes(writer, &digest),
        .embedded => |embedded| {
            const item = rlp.parseExact(embedded.bytes[0..embedded.len]) catch
                unreachable;
            writer.raw(item) catch |err| switch (err) {
                error.NoSpaceLeft => return error.ResourceLimitExceeded,
                error.OutOfMemory => unreachable,
            };
        },
    }
}

fn embeddedReference(encoded: []const u8) Reference {
    std.debug.assert(encoded.len < 32);
    var embedded: Reference.Embedded = .{ .len = @intCast(encoded.len), .bytes = undefined };
    @memcpy(embedded.bytes[0..encoded.len], encoded);
    return .{ .embedded = embedded };
}

fn referenceEncodedLen(reference: Reference) usize {
    return switch (reference) {
        .hashed => 33,
        .embedded => |embedded| embedded.len,
    };
}

fn bytesEncodedLen(value: []const u8) usize {
    if (value.len == 1 and value[0] < 0x80) return 1;
    if (value.len < 56) return 1 + value.len;
    return 1 + lengthByteLen(value.len) + value.len;
}

fn listPrefixLen(payload_len: usize) usize {
    return if (payload_len < 56) 1 else 1 + lengthByteLen(payload_len);
}

fn lengthByteLen(value: usize) usize {
    return (@bitSizeOf(usize) - @clz(value) + 7) / 8;
}

fn addEncodedLengths(lengths: []const usize) Error!usize {
    var total: usize = 0;
    for (lengths) |len| {
        total = std.math.add(usize, total, len) catch return error.ResourceLimitExceeded;
    }
    return total;
}

fn addRegion(comptime T: type, offset: usize, count: usize) Error!usize {
    const aligned = alignForward(offset, @alignOf(T)) catch return error.ResourceLimitExceeded;
    const bytes = std.math.mul(usize, @sizeOf(T), count) catch
        return error.ResourceLimitExceeded;
    return std.math.add(usize, aligned, bytes) catch error.ResourceLimitExceeded;
}

fn alignForward(value: usize, alignment: usize) error{Overflow}!usize {
    const mask = alignment - 1;
    const with_mask = std.math.add(usize, value, mask) catch return error.Overflow;
    return with_mask & ~mask;
}

pub fn validateEntries(entries: []const Entry, sorted: bool) Error!void {
    for (entries) |entry| {
        if (entry.value.len == 0) return error.EmptyValue;
    }
    if (sorted) try validateOrder(entries);
}

fn validateOrder(entries: []const Entry) Error!void {
    for (entries[1..], 1..) |entry, index| {
        switch (std.mem.order(u8, entries[index - 1].key, entry.key)) {
            .lt => {},
            .eq => return error.DuplicateKey,
            .gt => return error.UnsortedKeys,
        }
    }
}

fn entryLessThan(_: void, lhs: Entry, rhs: Entry) bool {
    return std.mem.order(u8, lhs.key, rhs.key) == .lt;
}

fn commonPrefixLen(entries: []const Entry, depth: usize) usize {
    var limit = nibble.keyNibbleLen(entries[0].key);
    for (entries[1..]) |entry| limit = @min(limit, nibble.keyNibbleLen(entry.key));

    var len: usize = 0;
    while (depth + len < limit) : (len += 1) {
        const expected = nibble.keyNibbleAt(entries[0].key, depth + len);
        for (entries[1..]) |entry| {
            if (nibble.keyNibbleAt(entry.key, depth + len) != expected) return len;
        }
    }
    return len;
}
