const std = @import("std");
const mpt = @import("mpt");

comptime {
    _ = @import("fixture_test.zig");
}

test {
    std.testing.refAllDecls(mpt);
}

test "empty root is canonical" {
    try expectHex(&(try mpt.init(std.testing.allocator).rootSorted(&.{})), "56e81f171bcc55a6ff8345e692c0f86e5b48e01b996cadc001622fb5e363b421");
}

test "full root matches canonical string-key example" {
    const entries = [_]mpt.Entry{
        .{ .key = "do", .value = "verb" },
        .{ .key = "dog", .value = "puppy" },
        .{ .key = "doge", .value = "coin" },
        .{ .key = "horse", .value = "stallion" },
    };
    try expectHex(&(try mpt.init(std.testing.allocator).rootSorted(&entries)), "5991bb8c6514148a29db676a14ac506cd2cd5775ace63c30a4fe457715e9ac84");
}

test "root sorts descriptors without copying key or value bytes" {
    const entries = [_]mpt.Entry{
        .{ .key = "horse", .value = "stallion" },
        .{ .key = "doge", .value = "coin" },
        .{ .key = "do", .value = "verb" },
        .{ .key = "dog", .value = "puppy" },
    };
    try expectHex(&(try mpt.init(std.testing.allocator).root(&entries)), "5991bb8c6514148a29db676a14ac506cd2cd5775ace63c30a4fe457715e9ac84");
}

test "reported root workspace bound is sufficient for byte-aligned storage" {
    const entries = [_]mpt.Entry{
        .{ .key = "do", .value = "verb" },
        .{ .key = "dog", .value = "puppy" },
        .{ .key = "doge", .value = "coin" },
        .{ .key = "horse", .value = "stallion" },
    };
    const needed = try mpt.rootWorkspaceSize(&entries, true);
    const backing = try std.testing.allocator.alloc(u8, needed + 1);
    defer std.testing.allocator.free(backing);
    const buffer = backing[1 .. needed + 1];
    var workspace = mpt.Workspace.init(buffer);
    _ = try mpt.rootWithWorkspace(&workspace, &entries);
    try std.testing.expect(workspace.peak_used_bytes <= needed);
}

test "full root handles prefix keys and embedded children" {
    const entries = [_]mpt.Entry{
        .{ .key = &[_]u8{0x0f}, .value = "dog" },
        .{ .key = &[_]u8{0x80}, .value = "cat" },
    };
    try expectHex(&(try mpt.init(std.testing.allocator).rootSorted(&entries)), "cabbd0a353cb4d2df5e27b9ffeceed340ddbacdf54929b65524a961bfc318e04");
}

test "root input failures remain distinct" {
    const unsorted = [_]mpt.Entry{
        .{ .key = "b", .value = "1" },
        .{ .key = "a", .value = "2" },
    };
    try std.testing.expectError(error.UnsortedKeys, mpt.init(std.testing.allocator).rootSorted(&unsorted));

    const duplicate = [_]mpt.Entry{
        .{ .key = "a", .value = "1" },
        .{ .key = "a", .value = "2" },
    };
    try std.testing.expectError(error.DuplicateKey, mpt.init(std.testing.allocator).root(&duplicate));

    const empty_value = [_]mpt.Entry{.{ .key = "a", .value = "" }};
    try std.testing.expectError(error.EmptyValue, mpt.init(std.testing.allocator).rootSorted(&empty_value));
}

test "caller allocator controls root workspace capacity" {
    const entries = [_]mpt.Entry{.{ .key = "dog", .value = "puppy" }};

    var fixed_buffer: [128 * 1024]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&fixed_buffer);
    _ = try mpt.init(fixed.allocator()).rootSorted(&entries);

    var tiny_buffer: [1]u8 = undefined;
    var tiny = std.heap.FixedBufferAllocator.init(&tiny_buffer);
    try std.testing.expectError(error.OutOfMemory, mpt.init(tiny.allocator()).rootSorted(&entries));
}

test "custom Keccak execution context is used for canonical node hashes" {
    const CountingKeccak = struct {
        calls: *usize,

        pub fn keccak256(self: @This(), input: []const u8) mpt.Root {
            self.calls.* += 1;
            return mpt.StdKeccak256Context.keccak256(.{}, input);
        }
    };

    const entries = [_]mpt.Entry{.{ .key = "dog", .value = "puppy" }};
    var calls: usize = 0;
    const trie = mpt.Trie(CountingKeccak).init(std.testing.allocator, .{ .calls = &calls });
    _ = try trie.rootSorted(&entries);
    try std.testing.expectEqual(@as(usize, 1), calls);
}

test "indexed proof lookup authenticates presence and absence without allocation" {
    // extension([1]) -> branch(child 0 = leaf(1), child 2 = leaf(2))
    const root_node = [_]u8{
        0xd7, 0x11, 0xd5,
        0xc2, 0x20, 0x01,
        0x80, 0xc2, 0x20,
        0x02, 0x80, 0x80,
        0x80, 0x80, 0x80,
        0x80, 0x80, 0x80,
        0x80, 0x80, 0x80,
        0x80, 0x80, 0x80,
    };
    const trie = mpt.init(std.testing.allocator);
    const encoded_nodes = [_][]const u8{&root_node};
    var indexed = try trie.indexNodes(&encoded_nodes);
    defer indexed.deinit();
    const index = indexed.index();
    const root_hash = mpt.StdKeccak256Context.keccak256(.{}, &root_node);

    const found = try trie.lookup(root_hash, index, &[_]u8{0x10});
    switch (found) {
        .present => |value| try std.testing.expectEqualSlices(u8, &[_]u8{0x01}, value),
        .absent => return error.ExpectedPresent,
    }
    try expectAbsence(.missing_branch_child, try trie.lookup(root_hash, index, &[_]u8{0x11}));
    try expectAbsence(.divergent_path, try trie.lookup(root_hash, index, &[_]u8{0x20}));
    try expectAbsence(.empty_trie, try trie.lookup(mpt.empty_root, index, "anything"));
}

test "node index hashes once, deduplicates, and rejects conflicts" {
    const CountingKeccak = struct {
        calls: *usize,

        pub fn keccak256(self: @This(), input: []const u8) mpt.Root {
            self.calls.* += 1;
            return mpt.StdKeccak256Context.keccak256(.{}, input);
        }
    };
    var calls: usize = 0;
    const trie = mpt.Trie(CountingKeccak).init(std.testing.allocator, .{ .calls = &calls });
    const leaf = [_]u8{ 0xc2, 0x20, 0x01 };
    const encoded = [_][]const u8{ &leaf, &leaf };
    var indexed = try trie.indexNodes(&encoded);
    defer indexed.deinit();
    try std.testing.expectEqual(@as(usize, 2), calls);
    try std.testing.expectEqual(@as(usize, 1), indexed.nodeCount());

    const ConstantKeccak = struct {
        pub fn keccak256(_: @This(), _: []const u8) mpt.Root {
            return [_]u8{0} ** 32;
        }
    };
    const conflicting = [_][]const u8{ "a", "b" };
    const constant_trie = mpt.Trie(ConstantKeccak).init(std.testing.allocator, .{});
    try std.testing.expectError(error.ConflictingNode, constant_trie.indexNodes(&conflicting));
}

test "raw witness mappings are not a public lookup capability" {
    try std.testing.expect(!@hasDecl(mpt, "NodeBag"));
    try std.testing.expect(!@hasDecl(mpt, "NodeRecord"));
    try std.testing.expect(!@hasDecl(mpt, "NodeIndexStorage"));
}

test "proof lookup distinguishes missing witness from malformed topology" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var missing_root_node = [_]u8{0} ** 35;
    missing_root_node[0] = 0xe2;
    missing_root_node[1] = 0x11;
    missing_root_node[2] = 0xa0;

    const trie = mpt.init(arena.allocator());
    const missing_nodes = [_][]const u8{&missing_root_node};
    const missing_indexed = try trie.indexNodes(&missing_nodes);
    const missing_root = mpt.StdKeccak256Context.keccak256(.{}, &missing_root_node);
    try std.testing.expectError(error.MissingNode, trie.lookup(missing_root, missing_indexed.index(), &[_]u8{0x10}));

    const one_occupant_branch = [_]u8{0xd1} ++ [_]u8{0x80} ** 17;
    const malformed_nodes = [_][]const u8{&one_occupant_branch};
    const malformed_indexed = try trie.indexNodes(&malformed_nodes);
    const malformed_root = mpt.StdKeccak256Context.keccak256(.{}, &one_occupant_branch);
    try std.testing.expectError(error.NonCanonicalNode, trie.lookup(malformed_root, malformed_indexed.index(), ""));

    const adjacent_short_nodes = [_]u8{ 0xc4, 0x11, 0xc2, 0x20, 0x01 };
    const adjacent_nodes = [_][]const u8{&adjacent_short_nodes};
    const adjacent_indexed = try trie.indexNodes(&adjacent_nodes);
    const adjacent_root = mpt.StdKeccak256Context.keccak256(.{}, &adjacent_short_nodes);
    try std.testing.expectError(error.NonCanonicalNode, trie.lookup(adjacent_root, adjacent_indexed.index(), &[_]u8{0x10}));

    const empty_compact = [_]u8{ 0xc2, 0x80, 0x01 };
    const empty_compact_nodes = [_][]const u8{&empty_compact};
    const empty_compact_indexed = try trie.indexNodes(&empty_compact_nodes);
    try std.testing.expectError(
        error.InvalidCompactPath,
        trie.lookup(mpt.StdKeccak256Context.keccak256(.{}, &empty_compact), empty_compact_indexed.index(), ""),
    );

    const invalid_flags = [_]u8{ 0xc2, 0x40, 0x01 };
    const invalid_flag_nodes = [_][]const u8{&invalid_flags};
    const invalid_flag_indexed = try trie.indexNodes(&invalid_flag_nodes);
    try std.testing.expectError(
        error.InvalidCompactPath,
        trie.lookup(mpt.StdKeccak256Context.keccak256(.{}, &invalid_flags), invalid_flag_indexed.index(), ""),
    );

    const invalid_padding = [_]u8{ 0xc2, 0x01, 0x01 };
    const invalid_padding_nodes = [_][]const u8{&invalid_padding};
    const invalid_padding_indexed = try trie.indexNodes(&invalid_padding_nodes);
    try std.testing.expectError(
        error.InvalidCompactPath,
        trie.lookup(mpt.StdKeccak256Context.keccak256(.{}, &invalid_padding), invalid_padding_indexed.index(), ""),
    );

    const truncated = [_]u8{ 0xc2, 0x20 };
    const truncated_nodes = [_][]const u8{&truncated};
    const truncated_indexed = try trie.indexNodes(&truncated_nodes);
    try std.testing.expectError(
        error.InputTooShort,
        trie.lookup(mpt.StdKeccak256Context.keccak256(.{}, &truncated), truncated_indexed.index(), ""),
    );

    const trailing = [_]u8{ 0xc2, 0x20, 0x01, 0x00 };
    const trailing_nodes = [_][]const u8{&trailing};
    const trailing_indexed = try trie.indexNodes(&trailing_nodes);
    try std.testing.expectError(
        error.TrailingBytes,
        trie.lookup(mpt.StdKeccak256Context.keccak256(.{}, &trailing), trailing_indexed.index(), ""),
    );
}

test "child references switch from embedded to hashed at 32 bytes" {
    const trie = mpt.init(std.testing.allocator);
    const key = [_]u8{0x00};

    const leaf31 = leafWithValueLen(28);
    try expectRootAccepted(trie, &leaf31);
    const embedded31 = branchWithEmbedded(leaf31.len, &leaf31);
    try expectBranchValue(trie, &embedded31, &.{&embedded31}, &key, leaf31[3..]);

    const leaf32 = leafWithValueLen(29);
    try expectRootAccepted(trie, &leaf32);
    const embedded32 = branchWithEmbedded(leaf32.len, &leaf32);
    try expectBranchError(error.InvalidNodeReference, trie, &embedded32, &.{&embedded32}, &key);

    const leaf33 = leafWithValueLen(30);
    try expectRootAccepted(trie, &leaf33);
    const embedded33 = branchWithEmbedded(leaf33.len, &leaf33);
    try expectBranchError(error.InvalidNodeReference, trie, &embedded33, &.{&embedded33}, &key);

    const hashed31 = branchWithHash(mpt.StdKeccak256Context.keccak256(.{}, &leaf31));
    try expectBranchError(error.InvalidNodeReference, trie, &hashed31, &.{ &hashed31, &leaf31 }, &key);

    const hashed32 = branchWithHash(mpt.StdKeccak256Context.keccak256(.{}, &leaf32));
    try expectBranchValue(trie, &hashed32, &.{ &hashed32, &leaf32 }, &key, leaf32[3..]);

    const hashed33 = branchWithHash(mpt.StdKeccak256Context.keccak256(.{}, &leaf33));
    try expectBranchValue(trie, &hashed33, &.{ &hashed33, &leaf33 }, &key, leaf33[3..]);
}

test "trusted root rejects a mutated reachable node" {
    const trie = mpt.init(std.testing.allocator);
    const original = [_]u8{ 0xc2, 0x20, 0x01 };
    const mutated = [_]u8{ 0xc2, 0x20, 0x02 };
    const trusted_root = mpt.StdKeccak256Context.keccak256(.{}, &original);
    const encoded_nodes = [_][]const u8{&mutated};
    var indexed = try trie.indexNodes(&encoded_nodes);
    defer indexed.deinit();

    try std.testing.expectError(error.MissingNode, trie.lookup(trusted_root, indexed.index(), ""));
}

test "sparse update inserts into empty trie" {
    const trie = mpt.init(std.testing.allocator);
    const updates = [_]mpt.Update{.{ .key = "dog", .value = "puppy" }};
    const actual = try trie.updateSorted(mpt.empty_root, mpt.empty_node_index, &updates);

    const entries = [_]mpt.Entry{.{ .key = "dog", .value = "puppy" }};
    const expected = try trie.rootSorted(&entries);
    try std.testing.expectEqualSlices(u8, &expected, &actual);
}

test "sparse insert preserves a witness path longer than the update key" {
    const long_key = [_]u8{0xff} ** 32;
    var root_node: [36]u8 = undefined;
    root_node[0] = 0xe3;
    root_node[1] = 0xa1;
    root_node[2] = 0x20;
    @memcpy(root_node[3..35], &long_key);
    root_node[35] = 0x01;

    const trie = mpt.init(std.testing.allocator);
    const encoded_nodes = [_][]const u8{&root_node};
    var indexed = try trie.indexNodes(&encoded_nodes);
    defer indexed.deinit();
    const root_hash = mpt.StdKeccak256Context.keccak256(.{}, &root_node);

    const short_key = [_]u8{0x00};
    const updates = [_]mpt.Update{.{ .key = &short_key, .value = &[_]u8{0x02} }};
    const actual = try trie.updateSorted(root_hash, indexed.index(), &updates);
    const expected_entries = [_]mpt.Entry{
        .{ .key = &short_key, .value = &[_]u8{0x02} },
        .{ .key = &long_key, .value = &[_]u8{0x01} },
    };
    const expected = try trie.rootSorted(&expected_entries);
    try std.testing.expectEqualSlices(u8, &expected, &actual);
}

test "caller allocator controls sparse update capacity" {
    const updates = [_]mpt.Update{.{ .key = "dog", .value = "puppy" }};

    var fixed_buffer: [16 * 1024]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&fixed_buffer);
    _ = try mpt.init(fixed.allocator()).updateSorted(mpt.empty_root, mpt.empty_node_index, &updates);

    var tiny_buffer: [1]u8 = undefined;
    var tiny = std.heap.FixedBufferAllocator.init(&tiny_buffer);
    try std.testing.expectError(
        error.OutOfMemory,
        mpt.init(tiny.allocator()).updateSorted(mpt.empty_root, mpt.empty_node_index, &updates),
    );
}

test "allocating APIs clean every allocation failure position" {
    const Harness = struct {
        fn run(allocator: std.mem.Allocator) !void {
            const trie = mpt.init(allocator);
            const entries = [_]mpt.Entry{.{ .key = "dog", .value = "puppy" }};
            const root_hash = try trie.rootSorted(&entries);

            const root_node = [_]u8{ 0xcb, 0x84, 0x20, 'd', 'o', 'g', 0x85, 'p', 'u', 'p', 'p', 'y' };
            const encoded_nodes = [_][]const u8{&root_node};
            var indexed = try trie.indexNodes(&encoded_nodes);
            defer indexed.deinit();

            const replacement = [_]mpt.Update{.{ .key = "dog", .value = "hound" }};
            _ = try trie.updateSorted(root_hash, indexed.index(), &replacement);
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Harness.run, .{});
}

test "empty-root batch does not reserve key-depth times node capacity" {
    const entry_count = 256;
    var keys: [entry_count][32]u8 = [_][32]u8{[_]u8{0} ** 32} ** entry_count;
    var values: [entry_count][1]u8 = undefined;
    var updates: [entry_count]mpt.Update = undefined;
    for (0..entry_count) |index| {
        keys[index][0] = @intCast(index);
        values[index][0] = @intCast(index % 255 + 1);
        updates[index] = .{ .key = &keys[index], .value = &values[index] };
    }

    var fixed_buffer: [1024 * 1024]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&fixed_buffer);
    _ = try mpt.init(fixed.allocator()).updateSorted(
        mpt.empty_root,
        mpt.empty_node_index,
        &updates,
    );
}

test "sparse update replaces and deletes a root leaf" {
    const root_node = [_]u8{ 0xcb, 0x84, 0x20, 'd', 'o', 'g', 0x85, 'p', 'u', 'p', 'p', 'y' };
    const trie = mpt.init(std.testing.allocator);
    const encoded_nodes = [_][]const u8{&root_node};
    var indexed = try trie.indexNodes(&encoded_nodes);
    defer indexed.deinit();
    const root_hash = mpt.StdKeccak256Context.keccak256(.{}, &root_node);

    const replacement = [_]mpt.Update{.{ .key = "dog", .value = "hound" }};
    const replaced = try trie.updateSorted(root_hash, indexed.index(), &replacement);
    const replaced_entries = [_]mpt.Entry{.{ .key = "dog", .value = "hound" }};
    try std.testing.expectEqualSlices(u8, &(try trie.rootSorted(&replaced_entries)), &replaced);

    const deletion = [_]mpt.Update{.{ .key = "dog", .value = null }};
    try std.testing.expectEqualSlices(u8, &mpt.empty_root, &(try trie.updateSorted(root_hash, indexed.index(), &deletion)));
}

test "sparse branch insert and delete agree with full rebuild" {
    const root_node = [_]u8{
        0xd7, 0x11, 0xd5,
        0xc2, 0x20, 0x01,
        0x80, 0xc2, 0x20,
        0x02, 0x80, 0x80,
        0x80, 0x80, 0x80,
        0x80, 0x80, 0x80,
        0x80, 0x80, 0x80,
        0x80, 0x80, 0x80,
    };
    const trie = mpt.init(std.testing.allocator);
    const encoded_nodes = [_][]const u8{&root_node};
    var indexed = try trie.indexNodes(&encoded_nodes);
    defer indexed.deinit();
    const root_hash = mpt.StdKeccak256Context.keccak256(.{}, &root_node);

    const insertion = [_]mpt.Update{.{ .key = &[_]u8{0x11}, .value = &[_]u8{0x03} }};
    const inserted = try trie.updateSorted(root_hash, indexed.index(), &insertion);
    const inserted_entries = [_]mpt.Entry{
        .{ .key = &[_]u8{0x10}, .value = &[_]u8{0x01} },
        .{ .key = &[_]u8{0x11}, .value = &[_]u8{0x03} },
        .{ .key = &[_]u8{0x12}, .value = &[_]u8{0x02} },
    };
    try std.testing.expectEqualSlices(u8, &(try trie.rootSorted(&inserted_entries)), &inserted);

    const deletion = [_]mpt.Update{.{ .key = &[_]u8{0x10}, .value = null }};
    const deleted = try trie.updateSorted(root_hash, indexed.index(), &deletion);
    const deleted_entries = [_]mpt.Entry{.{ .key = &[_]u8{0x12}, .value = &[_]u8{0x02} }};
    try std.testing.expectEqualSlices(u8, &(try trie.rootSorted(&deleted_entries)), &deleted);
}

test "sparse branch collapse reveals the sole hashed sibling" {
    var sibling: [43]u8 = undefined;
    sibling[0] = 0xea;
    sibling[1] = 0x30;
    sibling[2] = 0xa8;
    @memset(sibling[3..], 0xab);
    const sibling_hash = mpt.StdKeccak256Context.keccak256(.{}, &sibling);

    var root_node: [52]u8 = undefined;
    root_node[0] = 0xf3;
    @memcpy(root_node[1..4], &[_]u8{ 0xc2, 0x30, 0x01 });
    root_node[4] = 0xa0;
    @memcpy(root_node[5..37], &sibling_hash);
    @memset(root_node[37..], 0x80);

    const trie = mpt.init(std.testing.allocator);
    const encoded_nodes = [_][]const u8{ &root_node, &sibling };
    var indexed = try trie.indexNodes(&encoded_nodes);
    defer indexed.deinit();
    const root_hash = mpt.StdKeccak256Context.keccak256(.{}, &root_node);

    const deletion = [_]mpt.Update{.{ .key = &[_]u8{0x00}, .value = null }};
    const actual = try trie.updateSorted(root_hash, indexed.index(), &deletion);
    const expected_entries = [_]mpt.Entry{.{
        .key = &[_]u8{0x10},
        .value = &([_]u8{0xab} ** 40),
    }};
    const expected = try trie.rootSorted(&expected_entries);
    try std.testing.expectEqualSlices(u8, &expected, &actual);

    const root_only_nodes = [_][]const u8{&root_node};
    var root_only_indexed = try trie.indexNodes(&root_only_nodes);
    defer root_only_indexed.deinit();
    try std.testing.expectError(
        error.MissingNode,
        trie.updateSorted(root_hash, root_only_indexed.index(), &deletion),
    );
}

test "sparse update uses bounded frames for deep Patricia topology" {
    const key_bytes = 64;
    const entry_count = key_bytes * 2 + 1;
    var keys: [entry_count][key_bytes]u8 = [_][key_bytes]u8{[_]u8{0} ** key_bytes} ** entry_count;
    var values: [entry_count][1]u8 = undefined;
    var entries: [entry_count]mpt.Entry = undefined;
    var updates: [entry_count]mpt.Update = undefined;

    values[0][0] = 1;
    entries[0] = .{ .key = &keys[0], .value = &values[0] };
    updates[0] = .{ .key = &keys[0], .value = &values[0] };
    for (1..entry_count) |index| {
        const nibble_index = index - 1;
        const shift: u3 = if (nibble_index % 2 == 0) 4 else 0;
        keys[index][nibble_index / 2] = @as(u8, 1) << shift;
        values[index][0] = @intCast(index + 1);
        entries[index] = .{ .key = &keys[index], .value = &values[index] };
        updates[index] = .{ .key = &keys[index], .value = &values[index] };
    }
    std.mem.sort(mpt.Entry, &entries, {}, entryLessThan);
    std.mem.sort(mpt.Update, &updates, {}, updateLessThan);

    const trie = mpt.init(std.testing.allocator);
    const actual = try trie.updateSorted(mpt.empty_root, mpt.empty_node_index, &updates);
    const expected = try trie.rootSorted(&entries);
    try std.testing.expectEqualSlices(u8, &expected, &actual);
}

test "sparse update validates the full batch before mutation" {
    const trie = mpt.init(std.testing.allocator);
    const unsorted = [_]mpt.Update{
        .{ .key = "b", .value = "1" },
        .{ .key = "a", .value = "2" },
    };
    try std.testing.expectError(error.UnsortedKeys, trie.updateSorted(mpt.empty_root, mpt.empty_node_index, &unsorted));
    const empty = [_]mpt.Update{.{ .key = "a", .value = "" }};
    try std.testing.expectError(error.EmptyValue, trie.updateSorted(mpt.empty_root, mpt.empty_node_index, &empty));
}

fn expectAbsence(expected: mpt.Absence, lookup: mpt.Lookup) !void {
    switch (lookup) {
        .present => return error.ExpectedAbsent,
        .absent => |actual| try std.testing.expectEqual(expected, actual),
    }
}

fn entryLessThan(_: void, lhs: mpt.Entry, rhs: mpt.Entry) bool {
    return std.mem.order(u8, lhs.key, rhs.key) == .lt;
}

fn updateLessThan(_: void, lhs: mpt.Update, rhs: mpt.Update) bool {
    return std.mem.order(u8, lhs.key, rhs.key) == .lt;
}

fn leafWithValueLen(comptime value_len: usize) [value_len + 3]u8 {
    comptime std.debug.assert(value_len < 56);
    var encoded: [value_len + 3]u8 = undefined;
    encoded[0] = 0xc0 + value_len + 2;
    encoded[1] = 0x30;
    encoded[2] = 0x80 + value_len;
    @memset(encoded[3..], 0xab);
    return encoded;
}

fn branchWithEmbedded(comptime child_len: usize, child: *const [child_len]u8) [child_len + 19]u8 {
    comptime std.debug.assert(child_len + 18 < 56);
    var encoded: [child_len + 19]u8 = undefined;
    encoded[0] = 0xc0 + child_len + 18;
    @memcpy(encoded[1 .. 1 + child_len], child);
    @memcpy(encoded[1 + child_len .. 4 + child_len], &[_]u8{ 0xc2, 0x30, 0x02 });
    @memset(encoded[4 + child_len ..], 0x80);
    return encoded;
}

fn branchWithHash(digest: mpt.Root) [52]u8 {
    var encoded: [52]u8 = undefined;
    encoded[0] = 0xf3;
    encoded[1] = 0xa0;
    @memcpy(encoded[2..34], &digest);
    @memcpy(encoded[34..37], &[_]u8{ 0xc2, 0x30, 0x02 });
    @memset(encoded[37..], 0x80);
    return encoded;
}

fn expectRootAccepted(trie: anytype, root_node: []const u8) !void {
    const encoded_nodes = [_][]const u8{root_node};
    var indexed = try trie.indexNodes(&encoded_nodes);
    defer indexed.deinit();
    const root_hash = mpt.StdKeccak256Context.keccak256(.{}, root_node);
    try expectAbsence(.divergent_path, try trie.lookup(root_hash, indexed.index(), ""));
}

fn expectBranchValue(
    trie: anytype,
    root_node: []const u8,
    encoded_nodes: []const []const u8,
    key: []const u8,
    expected: []const u8,
) !void {
    var indexed = try trie.indexNodes(encoded_nodes);
    defer indexed.deinit();
    const root_hash = mpt.StdKeccak256Context.keccak256(.{}, root_node);
    const lookup = try trie.lookup(root_hash, indexed.index(), key);
    switch (lookup) {
        .present => |value| try std.testing.expectEqualSlices(u8, expected, value),
        .absent => return error.ExpectedPresent,
    }
}

fn expectBranchError(
    expected: anyerror,
    trie: anytype,
    root_node: []const u8,
    encoded_nodes: []const []const u8,
    key: []const u8,
) !void {
    var indexed = try trie.indexNodes(encoded_nodes);
    defer indexed.deinit();
    const root_hash = mpt.StdKeccak256Context.keccak256(.{}, root_node);
    try std.testing.expectError(expected, trie.lookup(root_hash, indexed.index(), key));
}

fn expectHex(actual: []const u8, comptime expected_hex: []const u8) !void {
    var expected: [expected_hex.len / 2]u8 = undefined;
    _ = try std.fmt.hexToBytes(&expected, expected_hex);
    try std.testing.expectEqualSlices(u8, &expected, actual);
}
