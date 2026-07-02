const std = @import("std");
const evmz = @import("evmz");

pub const JsonValue = std.json.Value;
pub const Address = evmz.Address;
pub const AccountState = evmz.state.AccountState;
pub const MemoryStore = evmz.state.MemoryStore;

pub const AccessListEntry = struct {
    address: Address,
    storage_keys: std.json.Array,
};

pub const ParsedAccessList = struct {
    entries: []evmz.transaction.AccessListEntry = &.{},

    pub fn deinit(self: *ParsedAccessList, allocator: std.mem.Allocator) void {
        for (self.entries) |entry| {
            if (entry.storage_keys.len > 0) allocator.free(@constCast(entry.storage_keys));
        }
        if (self.entries.len > 0) allocator.free(self.entries);
        self.* = .{};
    }
};

pub const AuthorizationListMode = enum {
    ignore_malformed_list,
    error_malformed_list,
};

pub const ParsedAuthorizationList = struct {
    entries: []evmz.transaction.AuthorizationTuple = &.{},
    count: usize = 0,

    pub fn deinit(self: *ParsedAuthorizationList, allocator: std.mem.Allocator) void {
        if (self.entries.len > 0) allocator.free(self.entries);
        self.* = .{};
    }
};

pub fn lockedFixturePath(
    io: std.Io,
    allocator: std.mem.Allocator,
    track: []const u8,
) ![]u8 {
    const dest = try lockedPathValue(io, allocator, "dest");
    return if (track.len == 0)
        try std.fs.path.join(allocator, &.{ dest, "fixtures" })
    else
        try std.fs.path.join(allocator, &.{ dest, "fixtures", track });
}

fn lockedPathValue(io: std.Io, allocator: std.mem.Allocator, key: []const u8) ![]const u8 {
    const locations = [_]struct {
        lock_path: []const u8,
        relative_prefix: []const u8,
    }{
        .{ .lock_path = "../eest.lock", .relative_prefix = ".." },
        .{ .lock_path = "eest.lock", .relative_prefix = "" },
    };

    for (locations) |location| {
        const bytes = std.Io.Dir.cwd().readFileAlloc(io, location.lock_path, allocator, .limited(64 * 1024)) catch |err| {
            if (err == error.FileNotFound) continue;
            return err;
        };
        const raw_value = parseLockValue(bytes, key) orelse return error.MissingEestLockKey;
        if (std.fs.path.isAbsolute(raw_value)) return raw_value;
        if (location.relative_prefix.len == 0) return raw_value;
        return std.fs.path.join(allocator, &.{ location.relative_prefix, raw_value });
    }

    return error.MissingEestLock;
}

fn parseLockValue(bytes: []const u8, key: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        const equals = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const line_key = std.mem.trim(u8, line[0..equals], " \t");
        if (!std.mem.eql(u8, line_key, key)) continue;
        return std.mem.trim(u8, line[equals + 1 ..], " \t");
    }
    return null;
}

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

pub fn rejectUnknownKeys(object: *const std.json.ObjectMap, allowed_keys: []const []const u8) !void {
    var it = object.iterator();
    while (it.next()) |entry| {
        for (allowed_keys) |allowed| {
            if (std.mem.eql(u8, entry.key_ptr.*, allowed)) break;
        } else {
            return error.UnsupportedFixtureKey;
        }
    }
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
    try rejectUnknownKeys(account, &.{ "balance", "nonce", "code", "storage" });

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

pub fn seedMemoryStore(allocator: std.mem.Allocator, store: *MemoryStore, pre: *const std.json.ObjectMap) !void {
    var account_it = pre.iterator();
    while (account_it.next()) |entry| {
        const address = try parseAddress(entry.key_ptr.*);
        const account_obj = asObject(entry.value_ptr.*) orelse return error.MalformedFixture;
        var account = try accountFromJson(allocator, &account_obj);
        var account_owned = true;
        errdefer if (account_owned) account.deinit(allocator);

        try store.putAccount(address, account);
        account_owned = false;
    }
}

pub fn parseAccessListEntry(value: JsonValue) !AccessListEntry {
    if (asObject(value)) |entry| {
        try rejectUnknownKeys(&entry, &.{ "address", "storageKeys" });
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

pub fn parseTransactionAccessList(allocator: std.mem.Allocator, list: std.json.Array) !ParsedAccessList {
    var entries: std.ArrayList(evmz.transaction.AccessListEntry) = .empty;
    errdefer {
        for (entries.items) |entry| {
            if (entry.storage_keys.len > 0) allocator.free(@constCast(entry.storage_keys));
        }
        entries.deinit(allocator);
    }

    for (list.items) |item| {
        const entry = try parseAccessListEntry(item);
        var storage_keys_owned = false;
        const storage_keys = if (entry.storage_keys.items.len == 0)
            &.{}
        else blk: {
            const keys = try allocator.alloc(u256, entry.storage_keys.items.len);
            for (entry.storage_keys.items, 0..) |key_value, i| {
                keys[i] = try parseU256FromValue(key_value);
            }
            storage_keys_owned = true;
            break :blk keys;
        };
        errdefer if (storage_keys_owned) allocator.free(@constCast(storage_keys));
        try entries.append(allocator, .{
            .address = entry.address,
            .storage_keys = storage_keys,
        });
        storage_keys_owned = false;
    }

    return .{ .entries = try entries.toOwnedSlice(allocator) };
}

pub fn parseTransactionAccessListFromValue(
    allocator: std.mem.Allocator,
    value: ?JsonValue,
) !ParsedAccessList {
    const list_value = value orelse return .{};
    const list = asArray(list_value) orelse return error.MalformedFixture;
    return parseTransactionAccessList(allocator, list);
}

pub fn parseTransactionAuthorizationList(
    allocator: std.mem.Allocator,
    tx: *const std.json.ObjectMap,
    mode: AuthorizationListMode,
) !ParsedAuthorizationList {
    const list_value = tx.get("authorizationList") orelse return .{};
    const list = asArray(list_value) orelse switch (mode) {
        .ignore_malformed_list => return .{},
        .error_malformed_list => return error.MalformedFixture,
    };
    var entries: std.ArrayList(evmz.transaction.AuthorizationTuple) = .empty;
    errdefer entries.deinit(allocator);

    for (list.items) |item| {
        const auth = asObject(item) orelse continue;
        const y_parity = parseU256FromValue(auth.get("yParity") orelse auth.get("v") orelse continue) catch continue;
        const legacy_v = if (auth.get("v")) |value| parseU256FromValue(value) catch continue else null;
        const r = parseU256FromValue(auth.get("r") orelse continue) catch continue;
        const s = parseU256FromValue(auth.get("s") orelse continue) catch continue;
        const chain_id = parseU256FromValue(auth.get("chainId") orelse continue) catch continue;
        const target = parseAddressFromValue(auth.get("address") orelse continue) catch continue;
        const signer = parseAddressFromValue(auth.get("signer") orelse continue) catch continue;
        const nonce_value = parseU256FromValue(auth.get("nonce") orelse continue) catch continue;
        const nonce = std.math.cast(u64, nonce_value) orelse continue;

        try entries.append(allocator, .{
            .chain_id = chain_id,
            .target = target,
            .signer = signer,
            .nonce = nonce,
            .y_parity = y_parity,
            .legacy_v = legacy_v,
            .r = r,
            .s = s,
        });
    }

    return .{
        .entries = try entries.toOwnedSlice(allocator),
        .count = list.items.len,
    };
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
