const std = @import("std");
const mpt = @import("mpt");

const JsonValue = std.json.Value;

test "official TrieTests construction corpus" {
    try runFixture(@embedFile("../fixtures/TrieTests/trietest.json"), false);
    try runFixture(@embedFile("../fixtures/TrieTests/trieanyorder.json"), false);
    try runFixture(@embedFile("../fixtures/TrieTests/trietest_secureTrie.json"), true);
    try runFixture(@embedFile("../fixtures/TrieTests/trieanyorder_secureTrie.json"), true);
    try runFixture(@embedFile("../fixtures/TrieTests/hex_encoded_securetrie_test.json"), true);
}

fn runFixture(bytes: []const u8, secure: bool) !void {
    var parsed = try std.json.parseFromSlice(JsonValue, std.testing.allocator, bytes, .{});
    defer parsed.deinit();
    const cases = try asObject(parsed.value);

    var case_iterator = cases.iterator();
    while (case_iterator.next()) |case| {
        var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena_state.deinit();
        const allocator = arena_state.allocator();

        var state = std.StringHashMap([]const u8).init(allocator);
        const case_object = try asObject(case.value_ptr.*);
        const input = case_object.get("in") orelse return error.MalformedFixture;
        switch (input) {
            .array => |operations| {
                for (operations.items) |operation| {
                    const pair = try asArray(operation);
                    if (pair.items.len != 2) return error.MalformedFixture;
                    const key = try jsonString(pair.items[0]);
                    try applyOperation(&state, allocator, key, pair.items[1], secure);
                }
            },
            .object => |values| {
                var value_iterator = values.iterator();
                while (value_iterator.next()) |entry| {
                    try applyOperation(&state, allocator, entry.key_ptr.*, entry.value_ptr.*, secure);
                }
            },
            else => return error.MalformedFixture,
        }

        const entries = try allocator.alloc(mpt.Entry, state.count());
        var entry_iterator = state.iterator();
        var entry_index: usize = 0;
        while (entry_iterator.next()) |entry| : (entry_index += 1) {
            entries[entry_index] = .{ .key = entry.key_ptr.*, .value = entry.value_ptr.* };
        }

        const actual = try mpt.init(allocator).root(entries);
        const expected_text = try jsonString(case_object.get("root") orelse return error.MalformedFixture);
        const expected = try decodeHexExact(mpt.Root, expected_text);
        std.testing.expectEqualSlices(u8, &expected, &actual) catch |err| {
            std.debug.print("TrieTests case failed: {s}\n", .{case.key_ptr.*});
            return err;
        };
    }
}

fn applyOperation(
    state: *std.StringHashMap([]const u8),
    allocator: std.mem.Allocator,
    encoded_key: []const u8,
    encoded_value: JsonValue,
    secure: bool,
) !void {
    const raw_key = try decodeBytes(allocator, encoded_key);
    const key = if (secure) key: {
        const digest = mpt.StdKeccak256Context.keccak256(.{}, raw_key);
        break :key try allocator.dupe(u8, &digest);
    } else raw_key;

    switch (encoded_value) {
        .null => _ = state.remove(key),
        .string, .number_string => {
            const value = try decodeBytes(allocator, try jsonString(encoded_value));
            try state.put(key, value);
        },
        else => return error.MalformedFixture,
    }
}

fn decodeBytes(allocator: std.mem.Allocator, encoded: []const u8) ![]const u8 {
    if (std.mem.startsWith(u8, encoded, "0x")) {
        const hex = encoded[2..];
        if (hex.len % 2 != 0) return error.MalformedFixture;
        const bytes = try allocator.alloc(u8, hex.len / 2);
        _ = std.fmt.hexToBytes(bytes, hex) catch return error.MalformedFixture;
        return bytes;
    }
    return allocator.dupe(u8, encoded);
}

fn decodeHexExact(comptime T: type, encoded: []const u8) !T {
    if (!std.mem.startsWith(u8, encoded, "0x") or encoded.len != 2 + @sizeOf(T) * 2) {
        return error.MalformedFixture;
    }
    var out: T = undefined;
    _ = std.fmt.hexToBytes(&out, encoded[2..]) catch return error.MalformedFixture;
    return out;
}

fn asObject(value: JsonValue) !std.json.ObjectMap {
    return switch (value) {
        .object => |object| object,
        else => error.MalformedFixture,
    };
}

fn asArray(value: JsonValue) !std.json.Array {
    return switch (value) {
        .array => |array| array,
        else => error.MalformedFixture,
    };
}

fn jsonString(value: JsonValue) ![]const u8 {
    return switch (value) {
        .string => |string| string,
        .number_string => |string| string,
        else => error.MalformedFixture,
    };
}
