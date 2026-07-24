const std = @import("std");
const evmz = @import("../../evm.zig");

const Allocator = std.mem.Allocator;
const JsonValue = std.json.Value;
const bal = evmz.eth.bal;

const valid_fixtures = @embedFile("../fixtures/bal/valid.json");
const invalid_fixtures = @embedFile("../fixtures/bal/invalid.json");

const ParsedFixture = struct {
    block_access_list: bal.BlockAccessList = &.{},
    transaction_count: ?bal.BlockAccessIndex = null,

    fn deinit(self: *ParsedFixture, allocator: Allocator) void {
        for (self.block_access_list) |*account| deinitAccount(allocator, account);
        if (self.block_access_list.len > 0) allocator.free(self.block_access_list);
        self.* = .{};
    }
};

test "BAL fixture adapter accepts valid EEST-shaped declarations" {
    var parsed_json = try std.json.parseFromSlice(JsonValue, std.testing.allocator, valid_fixtures, .{
        .parse_numbers = false,
    });
    defer parsed_json.deinit();

    var root = try expectObject(parsed_json.value);
    var it = root.iterator();
    var cases: usize = 0;
    while (it.next()) |entry| {
        var fixture = try parseFixture(std.testing.allocator, entry.value_ptr.*);
        defer fixture.deinit(std.testing.allocator);

        try bal.validate(fixture.block_access_list, .{ .transaction_count = fixture.transaction_count });
        try assertEncodeDecodeRoundTrip(std.testing.allocator, fixture.block_access_list);
        try assertExpected(entry.key_ptr.*, entry.value_ptr.*, fixture);
        cases += 1;
    }

    try std.testing.expectEqual(@as(usize, 2), cases);
}

test "BAL fixture adapter reports invalid declaration errors" {
    var parsed_json = try std.json.parseFromSlice(JsonValue, std.testing.allocator, invalid_fixtures, .{
        .parse_numbers = false,
    });
    defer parsed_json.deinit();

    var root = try expectObject(parsed_json.value);
    var it = root.iterator();
    var cases: usize = 0;
    while (it.next()) |entry| {
        var fixture_object = try expectObject(entry.value_ptr.*);
        const expected = jsonString(fieldAny(&fixture_object, &.{ "expect_error", "expectError" }) orelse return error.MalformedFixture) orelse return error.MalformedFixture;

        var fixture = try parseFixture(std.testing.allocator, entry.value_ptr.*);
        defer fixture.deinit(std.testing.allocator);

        if (bal.validate(fixture.block_access_list, .{ .transaction_count = fixture.transaction_count })) |_| {
            return error.ExpectedFixtureValidationFailure;
        } else |err| {
            try std.testing.expectEqualStrings(expected, @errorName(err));
        }
        cases += 1;
    }

    try std.testing.expectEqual(@as(usize, 3), cases);
}

test "BAL fixture adapter rejects unknown keys" {
    const fixture =
        \\{
        \\  "bad": {
        \\    "transaction_count": "0x0",
        \\    "block_access_list": [],
        \\    "surprise": true
        \\  }
        \\}
    ;

    var parsed_json = try std.json.parseFromSlice(JsonValue, std.testing.allocator, fixture, .{
        .parse_numbers = false,
    });
    defer parsed_json.deinit();

    var root = try expectObject(parsed_json.value);
    const bad = root.get("bad") orelse return error.MalformedFixture;
    try std.testing.expectError(error.UnsupportedFixtureKey, parseFixture(std.testing.allocator, bad));
}

test "BAL fixture adapter parses JSON numbers as decimal and quoted quantities as hex" {
    var decimal = try std.json.parseFromSlice(JsonValue, std.testing.allocator, "10", .{
        .parse_numbers = false,
    });
    defer decimal.deinit();

    try std.testing.expectEqual(@as(bal.BlockAccessIndex, 10), try parseBlockAccessIndex(decimal.value));
    try std.testing.expectEqual(@as(bal.BlockAccessIndex, 16), try parseBlockAccessIndex(.{ .string = "0x10" }));
}

fn parseFixture(allocator: Allocator, value: JsonValue) !ParsedFixture {
    var object = try expectObject(value);
    try rejectUnknownKeys(&object, &.{
        "transaction_count",
        "transactionCount",
        "block_access_list",
        "blockAccessList",
        "expected",
        "expect_error",
        "expectError",
    });

    const transaction_count = if (fieldAny(&object, &.{ "transaction_count", "transactionCount" })) |count_value|
        try parseBlockAccessIndex(count_value)
    else
        null;

    const list_value = fieldAny(&object, &.{ "block_access_list", "blockAccessList" }) orelse return error.MalformedFixture;
    const list = try expectArray(list_value);

    var accounts = std.ArrayList(bal.AccountChanges).empty;
    errdefer {
        for (accounts.items) |*account| deinitAccount(allocator, account);
        accounts.deinit(allocator);
    }
    for (list.items) |account_value| {
        try accounts.append(allocator, try parseAccount(allocator, account_value));
    }

    return .{
        .block_access_list = try accounts.toOwnedSlice(allocator),
        .transaction_count = transaction_count,
    };
}

fn parseAccount(allocator: Allocator, value: JsonValue) !bal.AccountChanges {
    var object = try expectObject(value);
    try rejectUnknownKeys(&object, &.{
        "address",
        "storage_changes",
        "storageChanges",
        "storage_reads",
        "storageReads",
        "balance_changes",
        "balanceChanges",
        "nonce_changes",
        "nonceChanges",
        "code_changes",
        "codeChanges",
    });

    var account = bal.AccountChanges{
        .address = try parseAddress(fieldAny(&object, &.{"address"}) orelse return error.MalformedFixture),
    };
    errdefer deinitAccount(allocator, &account);

    account.storage_changes = try parseStorageChanges(allocator, fieldAny(&object, &.{ "storage_changes", "storageChanges" }));
    account.storage_reads = try parseU256List(allocator, fieldAny(&object, &.{ "storage_reads", "storageReads" }));
    account.balance_changes = try parseBalanceChanges(allocator, fieldAny(&object, &.{ "balance_changes", "balanceChanges" }));
    account.nonce_changes = try parseNonceChanges(allocator, fieldAny(&object, &.{ "nonce_changes", "nonceChanges" }));
    account.code_changes = try parseCodeChanges(allocator, fieldAny(&object, &.{ "code_changes", "codeChanges" }));
    return account;
}

fn parseStorageChanges(allocator: Allocator, value: ?JsonValue) ![]bal.SlotChanges {
    const array = if (value) |array_value| try expectArray(array_value) else return &.{};
    var out = std.ArrayList(bal.SlotChanges).empty;
    errdefer {
        for (out.items) |*slot| {
            if (slot.changes.len > 0) allocator.free(slot.changes);
        }
        out.deinit(allocator);
    }

    for (array.items) |slot_value| {
        var object = try expectObject(slot_value);
        try rejectUnknownKeys(&object, &.{ "slot", "key", "changes", "slot_changes", "slotChanges" });
        const changes = try parseStorageChangeList(allocator, fieldAny(&object, &.{ "slot_changes", "slotChanges", "changes" }) orelse return error.MalformedFixture);
        errdefer if (changes.len > 0) allocator.free(changes);
        try out.append(allocator, .{
            .slot = try parseU256(fieldAny(&object, &.{ "slot", "key" }) orelse return error.MalformedFixture),
            .changes = changes,
        });
    }
    return out.toOwnedSlice(allocator);
}

fn parseStorageChangeList(allocator: Allocator, value: JsonValue) ![]bal.StorageChange {
    const array = try expectArray(value);
    var out = std.ArrayList(bal.StorageChange).empty;
    errdefer out.deinit(allocator);
    for (array.items) |change_value| {
        var object = try expectObject(change_value);
        try rejectUnknownKeys(&object, &.{
            "block_access_index",
            "blockAccessIndex",
            "tx_index",
            "txIndex",
            "new_value",
            "newValue",
            "post_value",
            "postValue",
        });
        try out.append(allocator, .{
            .block_access_index = try parseChangeIndex(&object),
            .new_value = try parseU256(fieldAny(&object, &.{ "post_value", "postValue", "new_value", "newValue" }) orelse return error.MalformedFixture),
        });
    }
    return out.toOwnedSlice(allocator);
}

fn parseU256List(allocator: Allocator, value: ?JsonValue) ![]u256 {
    const array = if (value) |array_value| try expectArray(array_value) else return &.{};
    var out = std.ArrayList(u256).empty;
    errdefer out.deinit(allocator);
    for (array.items) |item| try out.append(allocator, try parseU256(item));
    return out.toOwnedSlice(allocator);
}

fn parseBalanceChanges(allocator: Allocator, value: ?JsonValue) ![]bal.BalanceChange {
    const array = if (value) |array_value| try expectArray(array_value) else return &.{};
    var out = std.ArrayList(bal.BalanceChange).empty;
    errdefer out.deinit(allocator);
    for (array.items) |change_value| {
        var object = try expectObject(change_value);
        try rejectUnknownKeys(&object, &.{
            "block_access_index",
            "blockAccessIndex",
            "tx_index",
            "txIndex",
            "post_balance",
            "postBalance",
        });
        try out.append(allocator, .{
            .block_access_index = try parseChangeIndex(&object),
            .post_balance = try parseU256(fieldAny(&object, &.{ "post_balance", "postBalance" }) orelse return error.MalformedFixture),
        });
    }
    return out.toOwnedSlice(allocator);
}

fn parseNonceChanges(allocator: Allocator, value: ?JsonValue) ![]bal.NonceChange {
    const array = if (value) |array_value| try expectArray(array_value) else return &.{};
    var out = std.ArrayList(bal.NonceChange).empty;
    errdefer out.deinit(allocator);
    for (array.items) |change_value| {
        var object = try expectObject(change_value);
        try rejectUnknownKeys(&object, &.{
            "block_access_index",
            "blockAccessIndex",
            "tx_index",
            "txIndex",
            "new_nonce",
            "newNonce",
            "post_nonce",
            "postNonce",
        });
        try out.append(allocator, .{
            .block_access_index = try parseChangeIndex(&object),
            .new_nonce = try parseU64(fieldAny(&object, &.{ "post_nonce", "postNonce", "new_nonce", "newNonce" }) orelse return error.MalformedFixture),
        });
    }
    return out.toOwnedSlice(allocator);
}

fn parseCodeChanges(allocator: Allocator, value: ?JsonValue) ![]bal.CodeChange {
    const array = if (value) |array_value| try expectArray(array_value) else return &.{};
    var out = std.ArrayList(bal.CodeChange).empty;
    errdefer {
        for (out.items) |change| {
            if (change.new_code.len > 0) allocator.free(change.new_code);
        }
        out.deinit(allocator);
    }
    for (array.items) |change_value| {
        var object = try expectObject(change_value);
        try rejectUnknownKeys(&object, &.{
            "block_access_index",
            "blockAccessIndex",
            "tx_index",
            "txIndex",
            "new_code",
            "newCode",
        });
        const code = try parseBytes(allocator, fieldAny(&object, &.{ "new_code", "newCode" }) orelse return error.MalformedFixture);
        errdefer if (code.len > 0) allocator.free(code);
        try out.append(allocator, .{
            .block_access_index = try parseChangeIndex(&object),
            .new_code = code,
        });
    }
    return out.toOwnedSlice(allocator);
}

fn parseChangeIndex(object: *const std.json.ObjectMap) !bal.BlockAccessIndex {
    return parseBlockAccessIndex(fieldAny(object, &.{
        "block_access_index",
        "blockAccessIndex",
        "tx_index",
        "txIndex",
    }) orelse return error.MalformedFixture);
}

fn assertExpected(test_name: []const u8, value: JsonValue, fixture: ParsedFixture) !void {
    _ = test_name;
    var object = try expectObject(value);
    const expected_value = fieldAny(&object, &.{"expected"}) orelse return;
    var expected = try expectObject(expected_value);
    try rejectUnknownKeys(&expected, &.{
        "counts",
        "per_index",
        "perIndex",
        "hash",
    });

    const counts = bal.count(fixture.block_access_list);
    if (fieldAny(&expected, &.{"counts"})) |counts_value| {
        var counts_object = try expectObject(counts_value);
        try rejectUnknownKeys(&counts_object, &.{
            "accounts",
            "storage_read_keys",
            "storage_write_keys",
            "storage_write_changes",
            "balance_changes",
            "nonce_changes",
            "code_changes",
            "code_bytes",
            "max_block_access_index",
        });
        try expectOptionalUsize(&counts_object, "accounts", counts.accounts);
        try expectOptionalUsize(&counts_object, "storage_read_keys", counts.storage_read_keys);
        try expectOptionalUsize(&counts_object, "storage_write_keys", counts.storage_write_keys);
        try expectOptionalUsize(&counts_object, "storage_write_changes", counts.storage_write_changes);
        try expectOptionalUsize(&counts_object, "balance_changes", counts.balance_changes);
        try expectOptionalUsize(&counts_object, "nonce_changes", counts.nonce_changes);
        try expectOptionalUsize(&counts_object, "code_changes", counts.code_changes);
        try expectOptionalUsize(&counts_object, "code_bytes", counts.code_bytes);
        if (fieldAny(&counts_object, &.{"max_block_access_index"})) |max_value| {
            try std.testing.expectEqual(try parseBlockAccessIndex(max_value), counts.max_block_access_index.?);
        }
    }

    if (fieldAny(&expected, &.{ "per_index", "perIndex" })) |per_index_value| {
        var per_index_object = try expectObject(per_index_value);
        try rejectUnknownKeys(&per_index_object, &.{
            "max_storage_write_keys",
            "max_changed_accounts",
        });
        var plan = try bal.planIndexResources(std.testing.allocator, fixture.block_access_list);
        defer plan.deinit(std.testing.allocator);
        const maxima = plan.maxima();
        try expectOptionalUsize(&per_index_object, "max_storage_write_keys", maxima.storage_write_keys);
        try expectOptionalUsize(&per_index_object, "max_changed_accounts", maxima.changed_accounts);
    }

    if (fieldAny(&expected, &.{"hash"})) |hash_value| {
        const expected_hash = try parseHash(hash_value);
        const actual_hash = try bal.hash(std.testing.allocator, fixture.block_access_list);
        try std.testing.expectEqualSlices(u8, &expected_hash, &actual_hash);
    }
}

fn assertEncodeDecodeRoundTrip(allocator: Allocator, block_access_list: bal.BlockAccessList) !void {
    const encoded = try bal.encodeAlloc(allocator, block_access_list);
    defer allocator.free(encoded);

    var decoded = try bal.decode(allocator, encoded);
    defer decoded.deinit(allocator);

    const encoded_again = try bal.encodeAlloc(allocator, decoded.accounts);
    defer allocator.free(encoded_again);
    try std.testing.expectEqualSlices(u8, encoded, encoded_again);
}

fn expectOptionalUsize(object: *const std.json.ObjectMap, key: []const u8, actual: usize) !void {
    if (fieldAny(object, &.{key})) |value| {
        try std.testing.expectEqual(try parseUsize(value), actual);
    }
}

fn expectObject(value: JsonValue) !std.json.ObjectMap {
    return switch (value) {
        .object => |object| object,
        else => error.MalformedFixture,
    };
}

fn expectArray(value: JsonValue) !std.json.Array {
    return switch (value) {
        .array => |array| array,
        else => error.MalformedFixture,
    };
}

fn fieldAny(object: *const std.json.ObjectMap, names: []const []const u8) ?JsonValue {
    for (names) |name| {
        if (object.get(name)) |value| return value;
    }
    return null;
}

fn rejectUnknownKeys(object: *const std.json.ObjectMap, allowed_keys: []const []const u8) !void {
    var it = object.iterator();
    while (it.next()) |entry| {
        for (allowed_keys) |allowed| {
            if (std.mem.eql(u8, entry.key_ptr.*, allowed)) break;
        } else {
            return error.UnsupportedFixtureKey;
        }
    }
}

fn jsonString(value: JsonValue) ?[]const u8 {
    return switch (value) {
        .string => |string| string,
        .number_string => |string| string,
        else => null,
    };
}

fn parseAddress(value: JsonValue) !bal.Address {
    const string = jsonString(value) orelse return error.MalformedFixture;
    return evmz.address.fromHex(string) catch error.MalformedFixture;
}

fn parseBlockAccessIndex(value: JsonValue) !bal.BlockAccessIndex {
    return parseHexInt(bal.BlockAccessIndex, value);
}

fn parseU64(value: JsonValue) !u64 {
    return parseHexInt(u64, value);
}

fn parseUsize(value: JsonValue) !usize {
    return parseHexInt(usize, value);
}

fn parseU256(value: JsonValue) !u256 {
    return parseHexInt(u256, value);
}

fn parseHexInt(comptime T: type, value: JsonValue) !T {
    return switch (value) {
        .number_string => |number| std.fmt.parseInt(T, number, 10) catch error.MalformedFixture,
        .string => |string| blk: {
            const hex = strip0x(string);
            if (hex.len == 0) break :blk 0;
            break :blk std.fmt.parseInt(T, hex, 16) catch error.MalformedFixture;
        },
        else => error.MalformedFixture,
    };
}

fn parseBytes(allocator: Allocator, value: JsonValue) ![]u8 {
    const string = jsonString(value) orelse return error.MalformedFixture;
    const hex = strip0x(string);
    if (hex.len % 2 != 0) return error.MalformedFixture;
    const out = try allocator.alloc(u8, hex.len / 2);
    errdefer allocator.free(out);
    _ = try std.fmt.hexToBytes(out, hex);
    return out;
}

fn parseHash(value: JsonValue) ![32]u8 {
    const string = jsonString(value) orelse return error.MalformedFixture;
    const hex = strip0x(string);
    if (hex.len != 64) return error.MalformedFixture;
    var out: [32]u8 = undefined;
    _ = try std.fmt.hexToBytes(&out, hex);
    return out;
}

fn strip0x(string: []const u8) []const u8 {
    if (std.mem.startsWith(u8, string, "0x") or std.mem.startsWith(u8, string, "0X")) {
        return string[2..];
    }
    return string;
}

fn deinitAccount(allocator: Allocator, account: *const bal.AccountChanges) void {
    for (account.storage_changes) |slot| {
        if (slot.changes.len > 0) allocator.free(slot.changes);
    }
    if (account.storage_changes.len > 0) allocator.free(account.storage_changes);
    if (account.storage_reads.len > 0) allocator.free(account.storage_reads);
    if (account.balance_changes.len > 0) allocator.free(account.balance_changes);
    if (account.nonce_changes.len > 0) allocator.free(account.nonce_changes);
    for (account.code_changes) |change| {
        if (change.new_code.len > 0) allocator.free(change.new_code);
    }
    if (account.code_changes.len > 0) allocator.free(account.code_changes);
}
