const std = @import("std");
const adapter = @import("../eth/trie.zig");
const mpt = @import("mpt");

test "standalone MPT roots match the evmz Keccak provider adapter" {
    var prng = std.Random.DefaultPrng.init(0x6d70742d706b672d);
    const random = prng.random();

    var keys: [32][3]u8 = undefined;
    var values: [32][16]u8 = undefined;
    var adapter_pairs: [32]adapter.Pair = undefined;
    var package_entries: [32]mpt.Entry = undefined;
    for (0..64) |round| {
        const count = 1 + round % keys.len;
        for (0..count) |index| {
            keys[index] = .{ @intCast(round), @intCast(index), random.int(u8) };
            random.bytes(&values[index]);
            const value_len = 1 + random.uintLessThan(usize, values[index].len);
            adapter_pairs[index] = .{ .key = &keys[index], .value = values[index][0..value_len] };
            package_entries[index] = .{ .key = &keys[index], .value = values[index][0..value_len] };
        }
        random.shuffle(adapter.Pair, adapter_pairs[0..count]);
        random.shuffle(mpt.Entry, package_entries[0..count]);

        const expected = try adapter.root(std.testing.allocator, adapter_pairs[0..count]);
        const actual = try mpt.init(std.testing.allocator).root(package_entries[0..count]);
        try std.testing.expectEqualSlices(u8, &expected, &actual);
    }
}
