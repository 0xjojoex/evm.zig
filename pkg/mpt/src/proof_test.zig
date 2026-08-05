//! Witness-index property tests through the public package API.

const std = @import("std");
const mpt = @import("mpt");

// Leaf with an empty compact path and one 8-byte value:
// rlp(["0x20", value]) = 0xca 0x20 0x88 <8 value bytes>.
fn leafNode(value: u64) [11]u8 {
    var encoded: [11]u8 = undefined;
    encoded[0] = 0xca;
    encoded[1] = 0x20;
    encoded[2] = 0x88;
    std.mem.writeInt(u64, encoded[3..11], value, .big);
    return encoded;
}

test "witness index resolves every node by digest and misses absent digests" {
    var prng = std.Random.DefaultPrng.init(0x6e6f6465);
    const random = prng.random();
    const node_count = 2_048;

    var nodes: [node_count][11]u8 = undefined;
    var encoded_nodes: [node_count + 128][]const u8 = undefined;
    for (&nodes, encoded_nodes[0..node_count], 0..) |*bytes, *encoded, index| {
        bytes.* = leafNode(index);
        encoded.* = bytes;
    }
    // Exact duplicates must dedup, not conflict.
    for (encoded_nodes[node_count..]) |*duplicate| {
        duplicate.* = encoded_nodes[random.uintLessThan(usize, node_count)];
    }

    const trie = mpt.init(std.testing.allocator);
    var indexed = try trie.indexNodes(&encoded_nodes);
    defer indexed.deinit();
    const index = indexed.index();
    try std.testing.expectEqual(@as(usize, node_count), indexed.nodeCount());

    for (encoded_nodes[0..node_count], 0..) |encoded, expected| {
        const digest = mpt.StdKeccak256Context.keccak256(.{}, encoded);
        switch (try trie.lookup(digest, index, "")) {
            .present => |value| try std.testing.expectEqual(
                expected,
                std.mem.readInt(u64, value[0..8], .big),
            ),
            .absent => return error.ExpectedPresent,
        }
    }
    for (0..1_024) |_| {
        var absent: [32]u8 = undefined;
        random.bytes(&absent);
        try std.testing.expectError(error.MissingNode, trie.lookup(absent, index, ""));
    }
}
