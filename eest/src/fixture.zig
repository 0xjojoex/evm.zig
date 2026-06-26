const std = @import("std");
const evmz = @import("evmz");

pub const JsonValue = std.json.Value;
pub const Address = evmz.Address;
pub const AccountState = evmz.state.AccountState;
pub const MemoryBackend = evmz.state.MemoryBackend;

pub const AccessListEntry = struct {
    address: Address,
    storage_keys: std.json.Array,
};

pub fn asObject(value: JsonValue) ?std.json.ObjectMap {
    return switch (value) {
        .object => |object| object,
        else => null,
    };
}

pub fn asArray(value: JsonValue) ?std.json.Array {
    return switch (value) {
        .array => |array| array,
        else => null,
    };
}

pub fn jsonString(value: JsonValue) ?[]const u8 {
    return switch (value) {
        .string => |string| string,
        .number_string => |string| string,
        else => null,
    };
}

pub fn parseAddressFromValue(value: JsonValue) !Address {
    const string = jsonString(value) orelse return error.MalformedFixture;
    return parseAddress(string);
}

pub fn parseU256FromValue(value: JsonValue) !u256 {
    const string = jsonString(value) orelse return error.MalformedFixture;
    return parseHexInt(u256, string);
}

pub fn parseU64FromValue(value: JsonValue) !u64 {
    const string = jsonString(value) orelse return error.MalformedFixture;
    return parseHexInt(u64, string);
}

pub fn parseBytesFromValue(allocator: std.mem.Allocator, value: JsonValue) ![]u8 {
    const string = jsonString(value) orelse return error.MalformedFixture;
    return parseBytes(allocator, string);
}

pub fn parseHashFromValue(value: JsonValue) ![32]u8 {
    const string = jsonString(value) orelse return error.MalformedFixture;
    const hex = strip0x(string);
    if (hex.len != 64) return error.InvalidHash;

    var result: [32]u8 = undefined;
    try parseHexInto(hex, &result);
    return result;
}

pub fn parseHexInt(comptime T: type, string: []const u8) !T {
    const hex = strip0x(string);
    if (hex.len == 0) return 0;
    return std.fmt.parseInt(T, hex, 16);
}

pub fn parseAddress(string: []const u8) !Address {
    const hex = strip0x(string);
    if (hex.len != 40) return error.InvalidAddress;

    var address: Address = undefined;
    try parseHexInto(hex, &address);
    return address;
}

pub fn parseBytes(allocator: std.mem.Allocator, string: []const u8) ![]u8 {
    const hex = strip0x(string);
    if (hex.len % 2 != 0) return error.InvalidHex;
    const out = try allocator.alloc(u8, hex.len / 2);
    errdefer allocator.free(out);
    try parseHexInto(hex, out);
    return out;
}

pub fn parseHexInto(hex: []const u8, out: []u8) !void {
    if (hex.len != out.len * 2) return error.InvalidHex;
    for (out, 0..) |*byte, i| {
        byte.* = (try hexDigit(hex[i * 2]) << 4) | try hexDigit(hex[i * 2 + 1]);
    }
}

pub fn strip0x(string: []const u8) []const u8 {
    if (std.mem.startsWith(u8, string, "0x") or std.mem.startsWith(u8, string, "0X")) {
        return string[2..];
    }
    return string;
}

pub fn accountFromJson(allocator: std.mem.Allocator, account: *const std.json.ObjectMap) !AccountState {
    var self = AccountState.init(allocator);
    errdefer self.deinit(allocator);

    self.balance = if (account.get("balance")) |value| try parseU256FromValue(value) else 0;
    self.nonce = if (account.get("nonce")) |value| try parseU64FromValue(value) else 0;
    if (account.get("code")) |value| {
        self.code = try parseBytesFromValue(allocator, value);
    }

    if (account.get("storage")) |storage_value| {
        var storage = asObject(storage_value) orelse return error.MalformedFixture;
        var it = storage.iterator();
        while (it.next()) |entry| {
            const key = try parseHexInt(u256, entry.key_ptr.*);
            const value = try parseU256FromValue(entry.value_ptr.*);
            if (value != 0) {
                try self.storage.put(key, value);
            }
        }
    }

    return self;
}

pub fn seedMemoryBackend(allocator: std.mem.Allocator, backend: *MemoryBackend, pre: *const std.json.ObjectMap) !void {
    var account_it = pre.iterator();
    while (account_it.next()) |entry| {
        const address = try parseAddress(entry.key_ptr.*);
        const account_obj = asObject(entry.value_ptr.*) orelse return error.MalformedFixture;
        var account = try accountFromJson(allocator, &account_obj);
        var account_owned = true;
        errdefer if (account_owned) account.deinit(allocator);

        try backend.putAccount(address, account);
        account_owned = false;
    }
}

pub fn parseAccessListEntry(value: JsonValue) !AccessListEntry {
    if (asObject(value)) |entry| {
        return .{
            .address = try parseAddressFromValue(entry.get("address") orelse return error.MalformedFixture),
            .storage_keys = asArray(entry.get("storageKeys") orelse return error.MalformedFixture) orelse return error.MalformedFixture,
        };
    }
    if (asArray(value)) |entry| {
        if (entry.items.len != 2) return error.MalformedFixture;
        return .{
            .address = try parseAddressFromValue(entry.items[0]),
            .storage_keys = asArray(entry.items[1]) orelse return error.MalformedFixture,
        };
    }
    return error.MalformedFixture;
}

pub fn authorizationListLen(tx: *const std.json.ObjectMap) usize {
    const value = tx.get("authorizationList") orelse return 0;
    const list = asArray(value) orelse return 0;
    return list.items.len;
}

pub fn parseBlobHashes(allocator: std.mem.Allocator, tx: *const std.json.ObjectMap) ![]u256 {
    const value = tx.get("blobVersionedHashes") orelse return &.{};
    const hashes = asArray(value) orelse return error.MalformedFixture;
    const result = try allocator.alloc(u256, hashes.items.len);
    errdefer allocator.free(result);
    for (hashes.items, 0..) |hash, i| {
        result[i] = try parseU256FromValue(hash);
    }
    return result;
}

pub fn parseStateFork(name: []const u8) ?evmz.Spec {
    if (std.ascii.eqlIgnoreCase(name, "Frontier")) return .frontier;
    if (std.ascii.eqlIgnoreCase(name, "Homestead")) return .homestead;
    if (std.ascii.eqlIgnoreCase(name, "EIP150")) return .tangerine_whistle;
    if (std.ascii.eqlIgnoreCase(name, "TangerineWhistle")) return .tangerine_whistle;
    if (std.ascii.eqlIgnoreCase(name, "EIP158")) return .spurious_dragon;
    if (std.ascii.eqlIgnoreCase(name, "SpuriousDragon")) return .spurious_dragon;
    if (std.ascii.eqlIgnoreCase(name, "Byzantium")) return .byzantium;
    if (std.ascii.eqlIgnoreCase(name, "Constantinople")) return .constantinople;
    if (std.ascii.eqlIgnoreCase(name, "ConstantinopleFix")) return .petersburg;
    if (std.ascii.eqlIgnoreCase(name, "Petersburg")) return .petersburg;
    if (std.ascii.eqlIgnoreCase(name, "Istanbul")) return .istanbul;
    if (std.ascii.eqlIgnoreCase(name, "Berlin")) return .berlin;
    if (std.ascii.eqlIgnoreCase(name, "London")) return .london;
    if (std.ascii.eqlIgnoreCase(name, "Paris")) return .merge;
    if (std.ascii.eqlIgnoreCase(name, "Merge")) return .merge;
    if (std.ascii.eqlIgnoreCase(name, "Shanghai")) return .shanghai;
    if (std.ascii.eqlIgnoreCase(name, "Cancun")) return .cancun;
    if (std.ascii.eqlIgnoreCase(name, "Prague")) return .prague;
    if (std.ascii.eqlIgnoreCase(name, "Osaka")) return .osaka;
    return null;
}

pub fn parseBenchmarkFork(name: []const u8) ?evmz.Spec {
    if (std.ascii.eqlIgnoreCase(name, "Shanghai")) return .shanghai;
    if (std.ascii.eqlIgnoreCase(name, "Cancun")) return .cancun;
    if (std.ascii.eqlIgnoreCase(name, "Prague")) return .prague;
    if (std.ascii.eqlIgnoreCase(name, "Osaka")) return .osaka;
    return null;
}

fn hexDigit(char: u8) !u8 {
    return switch (char) {
        '0'...'9' => char - '0',
        'a'...'f' => char - 'a' + 10,
        'A'...'F' => char - 'A' + 10,
        else => error.InvalidHex,
    };
}

test "EEST state fork parser maps ConstantinopleFix to Petersburg" {
    try std.testing.expectEqual(evmz.Spec.petersburg, parseStateFork("ConstantinopleFix"));
    try std.testing.expectEqual(evmz.Spec.osaka, parseStateFork("Osaka"));
    try std.testing.expectEqual(evmz.Spec.osaka, parseBenchmarkFork("Osaka"));
}
