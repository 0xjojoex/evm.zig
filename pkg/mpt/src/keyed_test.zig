const std = @import("std");
const mpt = @import("mpt");

test "typed key facade delegates root, proof, and sparse update to structural MPT" {
    const DomainKey = enum(u8) {
        alice = 1,
        bob = 2,
    };
    const KeyContext = struct {
        namespace: u8,

        pub fn trieKey(self: @This(), key: DomainKey) mpt.Root {
            const input = [_]u8{ self.namespace, @intFromEnum(key) };
            return mpt.StdKeccak256Context.keccak256(.{}, &input);
        }
    };
    const Structural = mpt.Trie(mpt.StdKeccak256Context);
    const Map = Structural.Keyed(DomainKey, KeyContext);
    const map = Map.init(
        Structural.init(std.testing.allocator, .{}),
        .{ .namespace = 0xa5 },
    );

    const entries = [_]Map.Entry{
        .{ .key = .bob, .value = "bob" },
        .{ .key = .alice, .value = "alice" },
    };
    const typed_root = try map.root(&entries);

    const alice_key = map.key_context.trieKey(.alice);
    const bob_key = map.key_context.trieKey(.bob);
    const structural = mpt.init(std.testing.allocator);
    const raw_root = try structural.root(&.{
        .{ .key = &bob_key, .value = "bob" },
        .{ .key = &alice_key, .value = "alice" },
    });
    try std.testing.expectEqualSlices(u8, &raw_root, &typed_root);

    const inserted = try map.update(mpt.empty_root, mpt.empty_node_index, &.{
        .{ .key = .bob, .value = "bob" },
        .{ .key = .alice, .value = "alice" },
    });
    try std.testing.expectEqualSlices(u8, &typed_root, &inserted);

    var leaf: [36]u8 = undefined;
    leaf[0] = 0xe3;
    leaf[1] = 0xa1;
    leaf[2] = 0x20;
    @memcpy(leaf[3..35], &alice_key);
    leaf[35] = 0x01;
    const leaf_root = mpt.StdKeccak256Context.keccak256(.{}, &leaf);
    var indexed = try map.indexNodes(&.{&leaf});
    defer indexed.deinit();

    switch (try map.lookup(leaf_root, indexed.index(), .alice)) {
        .present => |value| try std.testing.expectEqualSlices(u8, &.{0x01}, value),
        .absent => return error.ExpectedPresent,
    }
}

test "typed key facade detects collisions after projection" {
    const KeyContext = struct {
        pub fn trieKey(_: @This(), _: u8) mpt.Root {
            return [_]u8{0x11} ** 32;
        }
    };
    const Structural = mpt.Trie(mpt.StdKeccak256Context);
    const Map = Structural.Keyed(u8, KeyContext);
    const map = Map.init(Structural.init(std.testing.allocator, .{}), .{});

    try std.testing.expectError(error.DuplicateKey, map.root(&.{
        .{ .key = 1, .value = "one" },
        .{ .key = 2, .value = "two" },
    }));
    try std.testing.expectError(error.DuplicateKey, map.update(
        mpt.empty_root,
        mpt.empty_node_index,
        &.{
            .{ .key = 1, .value = "one" },
            .{ .key = 2, .value = "two" },
        },
    ));
}
