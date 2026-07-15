const std = @import("std");
const mpt = @import("mpt");

const max_entries = 8;
const max_key_bytes = 8;
const max_value_bytes = 16;
const raw_node_capacity = 128;
const raw_key_capacity = 16;

const integer_controls_bytes = 3 * @sizeOf(u64);
const generated_data_bytes = max_entries * max_key_bytes +
    max_key_bytes + max_entries + max_entries * max_value_bytes;
const raw_node_len_offset = integer_controls_bytes + generated_data_bytes;
const raw_node_offset = raw_node_len_offset + @sizeOf(u32);
const raw_key_len_offset = raw_node_offset + raw_node_capacity;
const raw_key_offset = raw_key_len_offset + @sizeOf(u32);
const corpus_bytes = raw_key_offset + raw_key_capacity;

const Properties = struct {
    const zero_seed = [_]u8{0} ** corpus_bytes;
    const wide_seed = seed: {
        var bytes = [_]u8{0} ** corpus_bytes;
        bytes[0] = max_entries;
        bytes[8] = 2;
        bytes[16] = max_key_bytes;
        @memset(bytes[integer_controls_bytes..raw_node_len_offset], 0xff);
        bytes[raw_node_len_offset] = raw_node_capacity;
        @memset(bytes[raw_node_offset..raw_key_len_offset], 0xff);
        bytes[raw_key_len_offset] = raw_key_capacity;
        @memset(bytes[raw_key_offset..], 0xff);
        break :seed bytes;
    };

    const corpus = [_][]const u8{
        &zero_seed,
        &wide_seed,
    };

    fn oracle(_: void, smith: *std.testing.Smith) anyerror!void {
        const entry_count: usize = smith.valueRangeAtMost(u8, 1, max_entries);
        const topology = smith.valueRangeAtMost(u8, 0, 2);
        const key_span: usize = smith.valueRangeAtMost(u8, 1, max_key_bytes);

        var keys: [max_entries][max_key_bytes]u8 = undefined;
        smith.bytes(std.mem.asBytes(&keys));
        var shared_path: [max_key_bytes]u8 = undefined;
        smith.bytes(&shared_path);
        var value_lengths: [max_entries]u8 = undefined;
        smith.bytes(&value_lengths);
        var values: [max_entries][max_value_bytes]u8 = undefined;
        smith.bytes(std.mem.asBytes(&values));

        var entries: [max_entries]mpt.Entry = undefined;
        for (0..entry_count) |index| {
            const key_len = shapeKey(topology, key_span, index, &keys, &shared_path);
            const value_len = 1 + @as(usize, value_lengths[index] % max_value_bytes);
            entries[index] = .{
                .key = keys[index][0..key_len],
                .value = values[index][0..value_len],
            };
        }

        const trie = mpt.init(std.testing.allocator);
        const sorted_root = try trie.rootSorted(entries[0..entry_count]);

        var reversed: [max_entries]mpt.Entry = undefined;
        for (0..entry_count) |index| {
            reversed[index] = entries[entry_count - index - 1];
        }
        const unsorted_root = try trie.root(reversed[0..entry_count]);
        try expectRootEqual(sorted_root, unsorted_root);

        const root_workspace_len = try mpt.rootWorkspaceSize(reversed[0..entry_count], true);
        const root_buffer = try std.testing.allocator.alloc(u8, root_workspace_len);
        defer std.testing.allocator.free(root_buffer);
        var root_workspace = mpt.Workspace.init(root_buffer);
        const workspace_root = try trie.rootWithWorkspace(&root_workspace, reversed[0..entry_count]);
        try expectRootEqual(sorted_root, workspace_root);
        try std.testing.expect(root_workspace.peak_used_bytes <= root_workspace_len);

        var updates: [max_entries]mpt.Update = undefined;
        for (entries[0..entry_count], 0..) |entry, index| {
            updates[index] = .{ .key = entry.key, .value = entry.value };
        }
        const sparse_root = try trie.updateSorted(mpt.empty_root, mpt.empty_node_index, updates[0..entry_count]);
        try expectRootEqual(sorted_root, sparse_root);

        try checkLeafProof(trie, entries[0]);
        try checkEmbeddedBranchUpdates(trie);
        try checkArbitraryProofDeterminism(trie, smith);
    }
};

test "MPT construction, workspace, sparse update, and proof properties" {
    try std.testing.fuzz({}, Properties.oracle, .{ .corpus = &Properties.corpus });
}

fn checkEmbeddedBranchUpdates(trie: mpt.DefaultTrie) !void {
    const key0 = [_]u8{0x00};
    const key1 = [_]u8{0x10};
    var encoded: [22]u8 = undefined;
    encoded[0] = 0xd5;
    @memcpy(encoded[1..7], &[_]u8{ 0xc2, 0x30, 0x01, 0xc2, 0x30, 0x02 });
    @memset(encoded[7..], 0x80);

    const root = mpt.StdKeccak256Context.keccak256(.{}, &encoded);
    const encoded_nodes = [_][]const u8{&encoded};
    var indexed = try trie.indexNodes(&encoded_nodes);
    defer indexed.deinit();

    const updates = [_]mpt.Update{
        .{ .key = &key0, .value = &[_]u8{0x03} },
        .{ .key = &key1, .value = null },
    };
    const updated = try trie.updateSorted(root, indexed.index(), &updates);
    const expected = try trie.rootSorted(&.{.{
        .key = &key0,
        .value = &[_]u8{0x03},
    }});
    try expectRootEqual(expected, updated);

    const deletions = [_]mpt.Update{
        .{ .key = &key0, .value = null },
        .{ .key = &key1, .value = null },
    };
    const emptied = try trie.updateSorted(root, indexed.index(), &deletions);
    try expectRootEqual(mpt.empty_root, emptied);
}

fn shapeKey(
    topology: u8,
    key_span: usize,
    index: usize,
    keys: *[max_entries][max_key_bytes]u8,
    shared_path: *const [max_key_bytes]u8,
) usize {
    switch (topology) {
        0 => {
            @memcpy(keys[index][0 .. key_span - 1], shared_path[0 .. key_span - 1]);
            keys[index][key_span - 1] = @intCast(index);
            return key_span;
        },
        1 => {
            keys[index][0] = @intCast(index);
            return key_span;
        },
        else => {
            const key_len = index;
            @memcpy(keys[index][0..key_len], shared_path[0..key_len]);
            return key_len;
        },
    }
}

fn checkLeafProof(trie: mpt.DefaultTrie, entry: mpt.Entry) !void {
    var encoded_storage: [64]u8 = undefined;
    const encoded = encodeLeaf(&encoded_storage, entry.key, entry.value);
    const encoded_root = mpt.StdKeccak256Context.keccak256(.{}, encoded);
    const single_entry_root = try trie.rootSorted(&.{entry});
    try expectRootEqual(single_entry_root, encoded_root);

    const encoded_nodes = [_][]const u8{encoded};
    var indexed = try trie.indexNodes(&encoded_nodes);
    defer indexed.deinit();
    switch (try trie.lookup(encoded_root, indexed.index(), entry.key)) {
        .present => |value| try std.testing.expectEqualSlices(u8, entry.value, value),
        .absent => return error.ExpectedPresent,
    }

    const replacement_value = [_]u8{0xa5};
    const replacement = [_]mpt.Update{.{
        .key = entry.key,
        .value = &replacement_value,
    }};
    const replaced = try trie.updateSorted(encoded_root, indexed.index(), &replacement);
    const expected_replaced = try trie.rootSorted(&.{.{
        .key = entry.key,
        .value = &replacement_value,
    }});
    try expectRootEqual(expected_replaced, replaced);

    const deletion = [_]mpt.Update{.{ .key = entry.key, .value = null }};
    const deleted = try trie.updateSorted(encoded_root, indexed.index(), &deletion);
    try expectRootEqual(mpt.empty_root, deleted);
}

fn checkArbitraryProofDeterminism(trie: mpt.DefaultTrie, smith: *std.testing.Smith) !void {
    var encoded_storage: [raw_node_capacity]u8 = undefined;
    const encoded_len: usize = smith.slice(&encoded_storage);
    if (encoded_len == 0) return;

    var key_storage: [raw_key_capacity]u8 = undefined;
    const key_len: usize = smith.slice(&key_storage);
    const encoded = encoded_storage[0..encoded_len];
    const key = key_storage[0..key_len];
    const encoded_nodes = [_][]const u8{encoded};
    var indexed = try trie.indexNodes(&encoded_nodes);
    defer indexed.deinit();
    const root = mpt.StdKeccak256Context.keccak256(.{}, encoded);

    if (trie.lookup(root, indexed.index(), key)) |first| {
        const second = try trie.lookup(root, indexed.index(), key);
        try expectLookupEqual(first, second);
    } else |first_error| {
        if (trie.lookup(root, indexed.index(), key)) |_| {
            return error.NondeterministicLookup;
        } else |second_error| {
            try std.testing.expectEqual(first_error, second_error);
        }
    }
}

fn encodeLeaf(storage: *[64]u8, key: []const u8, value: []const u8) []const u8 {
    var compact: [max_key_bytes + 1]u8 = undefined;
    compact[0] = 0x20;
    @memcpy(compact[1 .. key.len + 1], key);

    var cursor: usize = 1;
    cursor += writeShortString(storage[cursor..], compact[0 .. key.len + 1]);
    cursor += writeShortString(storage[cursor..], value);
    storage[0] = 0xc0 + @as(u8, @intCast(cursor - 1));
    return storage[0..cursor];
}

fn writeShortString(output: []u8, value: []const u8) usize {
    if (value.len == 1 and value[0] < 0x80) {
        output[0] = value[0];
        return 1;
    }
    output[0] = 0x80 + @as(u8, @intCast(value.len));
    @memcpy(output[1 .. value.len + 1], value);
    return value.len + 1;
}

fn expectRootEqual(expected: mpt.Root, actual: mpt.Root) !void {
    try std.testing.expectEqualSlices(u8, &expected, &actual);
}

fn expectLookupEqual(expected: mpt.Lookup, actual: mpt.Lookup) !void {
    switch (expected) {
        .present => |expected_value| switch (actual) {
            .present => |actual_value| try std.testing.expectEqualSlices(u8, expected_value, actual_value),
            .absent => return error.NondeterministicLookup,
        },
        .absent => |expected_reason| switch (actual) {
            .present => return error.NondeterministicLookup,
            .absent => |actual_reason| try std.testing.expectEqual(expected_reason, actual_reason),
        },
    }
}
