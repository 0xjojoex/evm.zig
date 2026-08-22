const std = @import("std");
const evmz = @import("evmz");
const fixture = @import("fixture.zig");

const JsonArray = std.json.Array;
const JsonObject = std.json.ObjectMap;
const JsonValue = fixture.JsonValue;
const bal = evmz.eth.bal;

pub fn encodeClaim(allocator: std.mem.Allocator, block: *const JsonObject) ![]const u8 {
    const array = fixture.asArray(block.get("blockAccessList") orelse return error.MalformedFixture) orelse return error.MalformedFixture;
    const accounts = try parseBlockAccessList(allocator, array);
    return bal.encodeAlloc(allocator, accounts);
}

fn parseBlockAccessList(allocator: std.mem.Allocator, array: JsonArray) ![]const bal.AccountChanges {
    const out = try allocator.alloc(bal.AccountChanges, array.items.len);
    for (out, array.items) |*target, value| {
        const object = fixture.asObject(value) orelse return error.MalformedFixture;
        target.* = .{
            .address = try fixture.parseAddressFromValue(object.get("address") orelse return error.MalformedFixture),
            .storage_changes = try parseStorageChanges(allocator, optionalArrayField(&object, "storageChanges")),
            .storage_reads = try parseU256List(allocator, optionalArrayField(&object, "storageReads")),
            .balance_changes = try parseBalanceChanges(allocator, optionalArrayField(&object, "balanceChanges")),
            .nonce_changes = try parseNonceChanges(allocator, optionalArrayField(&object, "nonceChanges")),
            .code_changes = try parseCodeChanges(allocator, optionalArrayField(&object, "codeChanges")),
        };
    }
    return out;
}

fn parseStorageChanges(allocator: std.mem.Allocator, maybe_array: ?JsonArray) ![]const bal.SlotChanges {
    const array = maybe_array orelse return &.{};
    const out = try allocator.alloc(bal.SlotChanges, array.items.len);
    for (out, array.items) |*target, value| {
        const object = fixture.asObject(value) orelse return error.MalformedFixture;
        target.* = .{
            .slot = try u256FieldAny(&object, &.{ "slot", "key" }),
            .changes = try parseStorageChangeList(allocator, try arrayFieldAny(&object, &.{ "slotChanges", "storageChanges", "changes" })),
        };
    }
    return out;
}

fn parseStorageChangeList(allocator: std.mem.Allocator, array: JsonArray) ![]const bal.StorageChange {
    const out = try allocator.alloc(bal.StorageChange, array.items.len);
    for (out, array.items) |*target, value| {
        const object = fixture.asObject(value) orelse return error.MalformedFixture;
        target.* = .{
            .block_access_index = try blockAccessIndexField(&object),
            .new_value = try u256FieldAny(&object, &.{ "newValue", "new_value", "postValue", "post_value", "value" }),
        };
    }
    return out;
}

fn parseU256List(allocator: std.mem.Allocator, maybe_array: ?JsonArray) ![]const u256 {
    const array = maybe_array orelse return &.{};
    const out = try allocator.alloc(u256, array.items.len);
    for (out, array.items) |*target, value| target.* = try fixture.parseU256FromValue(value);
    return out;
}

fn parseBalanceChanges(allocator: std.mem.Allocator, maybe_array: ?JsonArray) ![]const bal.BalanceChange {
    const array = maybe_array orelse return &.{};
    const out = try allocator.alloc(bal.BalanceChange, array.items.len);
    for (out, array.items) |*target, value| {
        const object = fixture.asObject(value) orelse return error.MalformedFixture;
        target.* = .{
            .block_access_index = try blockAccessIndexField(&object),
            .post_balance = try u256FieldAny(&object, &.{ "postBalance", "post_balance", "value" }),
        };
    }
    return out;
}

fn parseNonceChanges(allocator: std.mem.Allocator, maybe_array: ?JsonArray) ![]const bal.NonceChange {
    const array = maybe_array orelse return &.{};
    const out = try allocator.alloc(bal.NonceChange, array.items.len);
    for (out, array.items) |*target, value| {
        const object = fixture.asObject(value) orelse return error.MalformedFixture;
        target.* = .{
            .block_access_index = try blockAccessIndexField(&object),
            .new_nonce = try u64FieldAny(&object, &.{ "newNonce", "new_nonce", "postNonce", "post_nonce", "value" }),
        };
    }
    return out;
}

fn parseCodeChanges(allocator: std.mem.Allocator, maybe_array: ?JsonArray) ![]const bal.CodeChange {
    const array = maybe_array orelse return &.{};
    const out = try allocator.alloc(bal.CodeChange, array.items.len);
    for (out, array.items) |*target, value| {
        const object = fixture.asObject(value) orelse return error.MalformedFixture;
        target.* = .{
            .block_access_index = try blockAccessIndexField(&object),
            .new_code = try fixture.parseBytesFromValue(allocator, fieldAny(&object, &.{ "newCode", "new_code", "value" })),
        };
    }
    return out;
}

fn blockAccessIndexField(object: *const JsonObject) !bal.BlockAccessIndex {
    const raw = try u64FieldAny(object, &.{ "blockAccessIndex", "block_access_index", "index" });
    return std.math.cast(bal.BlockAccessIndex, raw) orelse error.MalformedFixture;
}

fn optionalArrayField(object: *const JsonObject, name: []const u8) ?JsonArray {
    return fixture.asArray(object.get(name) orelse return null);
}

fn arrayFieldAny(object: *const JsonObject, names: []const []const u8) !JsonArray {
    return fixture.asArray(fieldAny(object, names)) orelse error.MalformedFixture;
}

fn fieldAny(object: *const JsonObject, names: []const []const u8) JsonValue {
    for (names) |name| {
        if (object.get(name)) |value| return value;
    }
    return .null;
}

fn u64FieldAny(object: *const JsonObject, names: []const []const u8) !u64 {
    return fixture.parseU64FromValue(fieldAny(object, names));
}

fn u256FieldAny(object: *const JsonObject, names: []const []const u8) !u256 {
    return fixture.parseU256FromValue(fieldAny(object, names));
}
