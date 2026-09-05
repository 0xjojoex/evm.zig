const std = @import("std");
const mpt = @import("mpt");
const fixed_key_nibbles = @sizeOf(mpt.FixedKey) * 2;

test "catalog fixed batch binds shared prefixes without allocation" {
    const leaf0 = try encodeZeroLeaf(63, 1);
    defer std.testing.allocator.free(leaf0);
    const leaf1 = try encodeZeroLeaf(63, 2);
    defer std.testing.allocator.free(leaf1);
    const root_node = try encodeBranch01(leaf0, leaf1);
    defer std.testing.allocator.free(root_node);
    const nodes = [_][]const u8{ root_node, leaf0, leaf1 };
    const trie = mpt.init(std.testing.allocator);
    var indexed = try trie.indexWitness(&nodes);
    defer indexed.deinit();
    var builder = try mpt.Catalog.Builder.init(trie.allocator, indexed);
    defer builder.deinit();
    const root_hash = mpt.StdKeccak256Context.keccak256(.{}, root_node);
    const root = try builder.authenticateRoot(root_hash);
    var catalog = try builder.finishAssumeCollisionResistant();
    defer catalog.deinit();

    const key0: mpt.FixedKey = [_]u8{0} ** @sizeOf(mpt.FixedKey);
    const key1: mpt.FixedKey = [_]u8{0x10} ++ [_]u8{0} ** (@sizeOf(mpt.FixedKey) - 1);
    const key2: mpt.FixedKey = [_]u8{0x20} ++ [_]u8{0} ** (@sizeOf(mpt.FixedKey) - 1);
    const keys = [_]mpt.FixedKey{ key0, key1, key2 };
    var results: [keys.len]mpt.FixedLookup = undefined;
    var workspace: mpt.Catalog.BindWorkspace = .{};
    try catalog.bindSorted(root, &keys, &results, &workspace);

    try std.testing.expectEqualSlices(u8, &.{0x01}, results[0].present);
    try std.testing.expectEqualSlices(u8, &.{0x02}, results[1].present);
    try expectAbsence(.missing_branch_child, results[2]);

    for (keys, results) |key, result| {
        const single = try catalog.lookupBound(root, &key);
        switch (single) {
            .present => |present| try std.testing.expectEqualSlices(u8, present.value, result.present),
            .absent => try expectAbsence(.missing_branch_child, result),
        }
    }
}

test "catalog fixed batch rejects key order before walking" {
    const low: mpt.FixedKey = [_]u8{0} ** @sizeOf(mpt.FixedKey);
    const high: mpt.FixedKey = [_]u8{0xff} ** @sizeOf(mpt.FixedKey);
    var results: [2]mpt.FixedLookup = undefined;
    var workspace: mpt.Catalog.BindWorkspace = .{};
    var builder = try mpt.Catalog.Builder.init(std.testing.allocator, mpt.WitnessIndex.empty);
    defer builder.deinit();
    var catalog = try builder.finishAssumeCollisionResistant();
    defer catalog.deinit();

    const descending = [_]mpt.FixedKey{ high, low };
    try std.testing.expectError(
        error.UnsortedKeys,
        catalog.bindSorted(.empty, &descending, &results, &workspace),
    );
    const duplicate = [_]mpt.FixedKey{ low, low };
    try std.testing.expectError(
        error.DuplicateKey,
        catalog.bindSorted(.empty, &duplicate, &results, &workspace),
    );
}

test "catalog fixed batch preserves fixed-key validation and missing-node errors" {
    const key: mpt.FixedKey = [_]u8{0} ** @sizeOf(mpt.FixedKey);
    var results: [1]mpt.FixedLookup = undefined;
    var workspace: mpt.Catalog.BindWorkspace = .{};
    const trie = mpt.init(std.testing.allocator);

    const short_leaf = [_]u8{ 0xe2, 0xa0, 0x30 } ++ [_]u8{0} ** 31 ++ [_]u8{0x01};
    const short_nodes = [_][]const u8{&short_leaf};
    var short_indexed = try trie.indexWitness(&short_nodes);
    defer short_indexed.deinit();
    var short_builder = try mpt.Catalog.Builder.init(trie.allocator, short_indexed);
    defer short_builder.deinit();
    const short_root = try short_builder.authenticateRoot(
        mpt.StdKeccak256Context.keccak256(.{}, &short_leaf),
    );
    var short_catalog = try short_builder.finishAssumeCollisionResistant();
    defer short_catalog.deinit();
    try std.testing.expectError(
        error.InvalidNode,
        short_catalog.bindSorted(short_root, &.{key}, &results, &workspace),
    );

    const missing_digest = [_]u8{0x55} ** 32;
    const missing_child = [_]u8{0xf3} ++ [_]u8{0xa0} ++ missing_digest ++
        [_]u8{0x80} ** 14 ++ [_]u8{ 0xc2, 0x20, 0x02, 0x80 };
    const missing_nodes = [_][]const u8{&missing_child};
    var missing_indexed = try trie.indexWitness(&missing_nodes);
    defer missing_indexed.deinit();
    var missing_builder = try mpt.Catalog.Builder.init(trie.allocator, missing_indexed);
    defer missing_builder.deinit();
    const missing_root = try missing_builder.authenticateRoot(
        mpt.StdKeccak256Context.keccak256(.{}, &missing_child),
    );
    var missing_catalog = try missing_builder.finishAssumeCollisionResistant();
    defer missing_catalog.deinit();
    try std.testing.expectError(
        error.MissingNode,
        missing_catalog.bindSorted(missing_root, &.{key}, &results, &workspace),
    );
}

test "catalog fixed batch rejects branch values" {
    const key: mpt.FixedKey = [_]u8{0} ** @sizeOf(mpt.FixedKey);
    const child = [_]u8{ 0xe2, 0xa0, 0x30 } ++ [_]u8{0} ** 31 ++ [_]u8{0x02};
    const child_hash = mpt.StdKeccak256Context.keccak256(.{}, &child);
    const branch = [_]u8{0xf1} ++ [_]u8{0xa0} ++ child_hash ++
        [_]u8{0x80} ** 15 ++ [_]u8{0x01};
    const nodes = [_][]const u8{ &branch, &child };
    const trie = mpt.init(std.testing.allocator);
    var indexed = try trie.indexWitness(&nodes);
    defer indexed.deinit();
    var builder = try mpt.Catalog.Builder.init(trie.allocator, indexed);
    defer builder.deinit();
    const root = try builder.authenticateRoot(mpt.StdKeccak256Context.keccak256(.{}, &branch));
    var catalog = try builder.finishAssumeCollisionResistant();
    defer catalog.deinit();
    var results: [1]mpt.FixedLookup = undefined;
    var workspace: mpt.Catalog.BindWorkspace = .{};
    try std.testing.expectError(
        error.NonCanonicalNode,
        catalog.bindSorted(root, &.{key}, &results, &workspace),
    );
}

fn expectAbsence(expected: mpt.FixedAbsence, actual: mpt.FixedLookup) !void {
    switch (actual) {
        .present => return error.ExpectedAbsent,
        .absent => |absence| try std.testing.expectEqual(expected, absence),
    }
}

fn encodeZeroLeaf(suffix_nibbles: usize, value: u8) ![]u8 {
    std.debug.assert(suffix_nibbles <= fixed_key_nibbles);
    const compact_len = 1 + suffix_nibbles / 2;
    const compact_prefix_len: usize = if (compact_len == 1) 0 else 1;
    const payload_len = compact_prefix_len + compact_len + 1;
    const list_prefix_len: usize = if (payload_len <= 55) 1 else 2;
    const encoded = try std.testing.allocator.alloc(u8, list_prefix_len + payload_len);
    var cursor = writeListPrefix(encoded, payload_len);
    if (compact_prefix_len != 0) {
        encoded[cursor] = 0x80 + @as(u8, @intCast(compact_len));
        cursor += 1;
    }
    encoded[cursor] = (@as(u8, 2) | @as(u8, @intCast(suffix_nibbles & 1))) << 4;
    @memset(encoded[cursor + 1 .. cursor + compact_len], 0);
    cursor += compact_len;
    encoded[cursor] = value;
    return encoded;
}

fn encodeBranch01(child0: []const u8, child1: []const u8) ![]u8 {
    const payload_len = referenceLen(child0) + referenceLen(child1) + 15;
    const list_prefix_len: usize = if (payload_len <= 55) 1 else 2;
    const encoded = try std.testing.allocator.alloc(u8, list_prefix_len + payload_len);
    var cursor = writeListPrefix(encoded, payload_len);
    cursor += writeReference(encoded[cursor..], child0);
    cursor += writeReference(encoded[cursor..], child1);
    @memset(encoded[cursor..], 0x80);
    return encoded;
}

fn writeListPrefix(out: []u8, payload_len: usize) usize {
    if (payload_len <= 55) {
        out[0] = 0xc0 + @as(u8, @intCast(payload_len));
        return 1;
    }
    out[0] = 0xf8;
    out[1] = @intCast(payload_len);
    return 2;
}

fn referenceLen(encoded: []const u8) usize {
    return if (encoded.len < 32) encoded.len else 33;
}

fn writeReference(out: []u8, encoded: []const u8) usize {
    if (encoded.len < 32) {
        @memcpy(out[0..encoded.len], encoded);
        return encoded.len;
    }
    out[0] = 0xa0;
    const digest = mpt.StdKeccak256Context.keccak256(.{}, encoded);
    @memcpy(out[1..33], &digest);
    return 33;
}
