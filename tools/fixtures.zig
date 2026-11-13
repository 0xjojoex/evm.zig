//! Shared JSON parsing and in-memory state seeding for Ethereum fixture tools and consumers.

const std = @import("std");
const evmz = @import("evmz");

pub const JsonValue = std.json.Value;
const Address = evmz.Address;
const MemoryAccount = evmz.state.MemoryAccount;
const MemoryStore = evmz.state.MemoryStore;

pub const AccessListEntry = struct {
    address: Address,
    storage_keys: std.json.Array,
};

pub const ParsedAccessList = struct {
    entries: []evmz.transaction.AccessListEntry = &.{},

    pub fn deinit(self: *ParsedAccessList, allocator: std.mem.Allocator) void {
        for (self.entries) |entry| allocator.free(@constCast(entry.storage_keys));
        allocator.free(self.entries);
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
        allocator.free(self.entries);
        self.* = .{};
    }
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

pub const FixtureConfig = struct {
    chain_id: u256 = 1,
    blob_params: ?evmz.transaction.BlobParams = null,
};

/// The fork a fixture declares. EEST moved `network` under `config` and marked
/// the root copy for deprecation, so accept either placement.
pub fn fixtureForkName(fixture: *const std.json.ObjectMap) ?[]const u8 {
    if (fixture.get("config")) |config_value| {
        if (asObject(config_value)) |config| {
            if (config.get("network")) |value| {
                if (jsonString(value)) |name| return name;
            }
        }
    }
    return jsonString(fixture.get("network") orelse return null);
}

pub fn parseFixtureConfig(
    fixture: *const std.json.ObjectMap,
    comptime revision: evmz.eth.Revision,
    fork_name: ?[]const u8,
) !FixtureConfig {
    const config_value = fixture.get("config") orelse return .{};
    const config = asObject(config_value) orelse return error.MalformedFixture;
    try rejectUnknownKeys(&config, &.{ "network", "chainid", "chainId", "blobSchedule", "zeroNonceStorageAccounts" });

    var result = FixtureConfig{
        .chain_id = if (config.get("chainid")) |value|
            try parseU256FromValue(value)
        else if (config.get("chainId")) |value|
            try parseU256FromValue(value)
        else
            1,
    };
    const schedule_value = config.get("blobSchedule") orelse return result;
    const schedules = asObject(schedule_value) orelse return error.MalformedFixture;
    try rejectUnknownKeys(&schedules, &.{
        "Cancun", "Prague",            "Osaka",                "Amsterdam",
        "BPO1",   "BPO2",              "AmsterdamBPOIncrease", "AmsterdamBPODecrease",
        "Bogota", "BogotaBPOIncrease", "BogotaBPODecrease",
    });
    if (blobScheduleEntry(schedules, revision, fork_name)) |value| {
        result.blob_params = try parseBlobParams(value);
    }
    return result;
}

/// The chain's EIP-8253 zero-nonce storage accounts, `config.zeroNonceStorageAccounts`.
/// A fixture without the key lists none.
pub fn zeroNonceStorageAccounts(allocator: std.mem.Allocator, fixture: *const std.json.ObjectMap) ![]Address {
    const config = asObject(fixture.get("config") orelse return &.{}) orelse return error.MalformedFixture;
    const list = asArray(config.get("zeroNonceStorageAccounts") orelse return &.{}) orelse
        return error.MalformedFixture;
    const accounts = try allocator.alloc(Address, list.items.len);
    errdefer allocator.free(accounts);
    for (list.items, accounts) |value, *account| account.* = try parseAddressFromValue(value);
    return accounts;
}

/// EEST ships the schedule cumulatively, one entry per fork name, and the
/// fixture's own fork is the entry it wants. Selecting by execution revision
/// instead cannot reach a BPO entry at all: EIP-7892 forks change blob
/// parameters without changing execution rules, so several of them project
/// onto one revision and would silently resolve to that revision's numbers.
fn blobScheduleEntry(
    schedules: std.json.ObjectMap,
    comptime revision: evmz.eth.Revision,
    fork_name: ?[]const u8,
) ?JsonValue {
    if (fork_name) |name| {
        if (schedules.get(name)) |value| return value;
    }
    // Names outside the schedule (`Paris`, transition networks) fall back to
    // the newest entry the revision can carry.
    const revision_key: ?[]const u8 = if (revision.isImpl(.amsterdam))
        "Amsterdam"
    else if (revision.isImpl(.osaka))
        "Osaka"
    else if (revision.isImpl(.prague))
        "Prague"
    else if (revision.isImpl(.cancun))
        "Cancun"
    else
        null;
    return schedules.get(revision_key orelse return null);
}

fn parseBlobParams(value: JsonValue) !evmz.transaction.BlobParams {
    const params = asObject(value) orelse return error.MalformedFixture;
    try rejectUnknownKeys(&params, &.{ "target", "max", "baseFeeUpdateFraction" });
    return .{
        .target = try parseU64FromValue(params.get("target") orelse return error.MalformedFixture),
        .max = try parseU64FromValue(params.get("max") orelse return error.MalformedFixture),
        .base_fee_update_fraction = try parseU256FromValue(params.get("baseFeeUpdateFraction") orelse return error.MalformedFixture),
    };
}

pub fn blobBaseFee(
    comptime revision: evmz.eth.Revision,
    blob_params: ?evmz.transaction.BlobParams,
    excess_blob_gas: u256,
) ?u256 {
    if (!revision.isImpl(.cancun)) return 0;
    const spec_schedule = evmz.eth.specAt(revision).transaction.blob_schedule orelse return 0;
    const schedule = if (blob_params) |params| spec_schedule.withParams(params) else spec_schedule;
    return schedule.blobBaseFeeForSchedule(excess_blob_gas);
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
    try parseHexInto(hex, &address.bytes);
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

pub fn accountFromJson(allocator: std.mem.Allocator, account: *const std.json.ObjectMap) !MemoryAccount {
    try rejectUnknownKeys(account, &.{ "balance", "nonce", "code", "storage" });

    var result = MemoryAccount.init(allocator);
    errdefer result.deinit();

    result.account.balance = if (account.get("balance")) |value| try parseU256FromValue(value) else 0;
    result.account.nonce = if (account.get("nonce")) |value| try parseU64FromValue(value) else 0;
    if (account.get("code")) |value| {
        result.adoptCode(try parseBytesFromValue(allocator, value));
    }

    if (account.get("storage")) |storage_value| {
        var storage = asObject(storage_value) orelse return error.MalformedFixture;
        var it = storage.iterator();
        while (it.next()) |entry| {
            const key = try parseHexInt(u256, entry.key_ptr.*);
            const value = try parseU256FromValue(entry.value_ptr.*);
            if (value != 0) {
                try result.storage.put(key, value);
            }
        }
    }

    return result;
}

pub fn seedMemoryStore(allocator: std.mem.Allocator, store: *MemoryStore, pre: *const std.json.ObjectMap) !void {
    var account_it = pre.iterator();
    while (account_it.next()) |entry| {
        const address = try parseAddress(entry.key_ptr.*);
        const account_obj = asObject(entry.value_ptr.*) orelse return error.MalformedFixture;
        var account = try accountFromJson(allocator, &account_obj);
        defer account.deinit();
        try store.putAccount(address, &account);
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
        for (entries.items) |entry| allocator.free(@constCast(entry.storage_keys));
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

const frames = evmz.transaction.frames;

/// EIP-8141 `frames`: `{mode, flags, target?, gasLimit, stateGasLimit, value, data}`.
pub fn parseFrames(allocator: std.mem.Allocator, tx: *const std.json.ObjectMap) ![]frames.Frame {
    const list = asArray(tx.get("frames") orelse return &.{}) orelse return error.MalformedFixture;
    const result = try allocator.alloc(frames.Frame, list.items.len);
    for (list.items, result) |item, *frame| {
        const object = asObject(item) orelse return error.MalformedFixture;
        try rejectUnknownKeys(&object, &.{ "mode", "flags", "target", "gasLimit", "stateGasLimit", "value", "data" });
        const target = if (object.get("target")) |value| try parseOptionalAddress(value) else null;
        frame.* = .{
            .mode = @fromBackingInt(@intCast(try parseHexInt(u8, try requiredString(&object, "mode")))),
            .flags = @bitCast(try parseHexInt(u8, try requiredString(&object, "flags"))),
            .target = target,
            .limits = .{
                .execution = try parseU64FromValue(object.get("gasLimit") orelse return error.MalformedFixture),
                .state = try parseU64FromValue(object.get("stateGasLimit") orelse return error.MalformedFixture),
            },
            .value = try parseU256FromValue(object.get("value") orelse return error.MalformedFixture),
            .data = try parseBytesFromValue(allocator, object.get("data") orelse return error.MalformedFixture),
        };
    }
    return result;
}

/// EIP-8141 `signatures`: `{scheme, signer, msg, signature}`; an empty
/// `signer` or `msg` is absent.
pub fn parseFrameSignatures(allocator: std.mem.Allocator, tx: *const std.json.ObjectMap) ![]frames.Signature {
    const list = asArray(tx.get("signatures") orelse return &.{}) orelse return error.MalformedFixture;
    const result = try allocator.alloc(frames.Signature, list.items.len);
    for (list.items, result) |item, *signature| {
        const object = asObject(item) orelse return error.MalformedFixture;
        try rejectUnknownKeys(&object, &.{ "scheme", "signer", "msg", "signature" });
        const msg_hex = strip0x(try requiredString(&object, "msg"));
        signature.* = .{
            .scheme = @fromBackingInt(@intCast(try parseHexInt(u8, try requiredString(&object, "scheme")))),
            .signer = try parseOptionalAddress(object.get("signer") orelse return error.MalformedFixture),
            .msg = if (msg_hex.len == 0) null else msg: {
                var digest: [32]u8 = undefined;
                try parseHexInto(msg_hex, &digest);
                break :msg digest;
            },
            .signature = try parseBytesFromValue(allocator, object.get("signature") orelse return error.MalformedFixture),
        };
    }
    return result;
}

/// EIP-8250 `nonceKeys`; null when the transaction predates them.
pub fn parseNonceKeys(allocator: std.mem.Allocator, tx: *const std.json.ObjectMap) !?[]u256 {
    const list = asArray(tx.get("nonceKeys") orelse return null) orelse return error.MalformedFixture;
    const result = try allocator.alloc(u256, list.items.len);
    for (list.items, result) |item, *key| key.* = try parseU256FromValue(item);
    return result;
}

fn requiredString(object: *const std.json.ObjectMap, key: []const u8) ![]const u8 {
    return jsonString(object.get(key) orelse return error.MalformedFixture) orelse error.MalformedFixture;
}

fn parseOptionalAddress(value: JsonValue) !?Address {
    const string = jsonString(value) orelse return error.MalformedFixture;
    if (strip0x(string).len == 0) return null;
    return try parseAddress(string);
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

/// A fork as EEST names it, with the execution rules it runs.
pub const Fork = struct {
    /// EEST's spelling, which also keys the fixture's blob schedule.
    name: []const u8,
    revision: evmz.eth.Revision,
};

const known_forks = [_]Fork{
    .{ .name = "Frontier", .revision = .frontier },
    .{ .name = "Homestead", .revision = .homestead },
    .{ .name = "EIP150", .revision = .tangerine_whistle },
    .{ .name = "TangerineWhistle", .revision = .tangerine_whistle },
    .{ .name = "EIP158", .revision = .spurious_dragon },
    .{ .name = "SpuriousDragon", .revision = .spurious_dragon },
    .{ .name = "Byzantium", .revision = .byzantium },
    .{ .name = "Constantinople", .revision = .constantinople },
    .{ .name = "ConstantinopleFix", .revision = .petersburg },
    .{ .name = "Petersburg", .revision = .petersburg },
    .{ .name = "Istanbul", .revision = .istanbul },
    .{ .name = "Berlin", .revision = .berlin },
    .{ .name = "London", .revision = .london },
    .{ .name = "Paris", .revision = .merge },
    .{ .name = "Merge", .revision = .merge },
    .{ .name = "Shanghai", .revision = .shanghai },
    .{ .name = "Cancun", .revision = .cancun },
    .{ .name = "Prague", .revision = .prague },
    .{ .name = "Osaka", .revision = .osaka },
    .{ .name = "Amsterdam", .revision = .amsterdam },
    .{ .name = "Bogota", .revision = .bogota },
    // BPO scenarios retain their parent fork's execution rules; the fixture's
    // named blob schedule entry supplies the changed parameters.
    .{ .name = "BPO1", .revision = .osaka },
    .{ .name = "BPO2", .revision = .osaka },
    .{ .name = "AmsterdamBPOIncrease", .revision = .amsterdam },
    .{ .name = "AmsterdamBPODecrease", .revision = .amsterdam },
    .{ .name = "BogotaBPOIncrease", .revision = .bogota },
    .{ .name = "BogotaBPODecrease", .revision = .bogota },
};

pub fn parseFork(name: []const u8) ?Fork {
    for (known_forks) |fork| {
        if (std.ascii.eqlIgnoreCase(name, fork.name)) return fork;
    }
    return null;
}

pub fn parseStateFork(name: []const u8) ?evmz.eth.Revision {
    return (parseFork(name) orelse return null).revision;
}

/// A fixture's network: one fork, or EEST's `<From>To<To>AtTime<N>k`
/// transition, which runs `from` before timestamp `at` and `to` from it on.
pub const Network = struct {
    from: Fork,
    to: ?Fork = null,
    at: u64 = 0,

    pub fn parse(name: []const u8) ?Network {
        if (parseFork(name)) |fork| return .{ .from = fork };
        const marker = std.mem.lastIndexOf(u8, name, "AtTime") orelse return null;
        const time = name[marker + "AtTime".len ..];
        if (time.len < 2 or time[time.len - 1] != 'k') return null;
        const thousands = std.fmt.parseInt(u64, time[0 .. time.len - 1], 10) catch return null;
        const at = std.math.mul(u64, thousands, 1000) catch return null;
        const forks = name[0..marker];
        var split: usize = 1;
        while (std.mem.indexOfPos(u8, forks, split, "To")) |index| : (split = index + 1) {
            const from = parseFork(forks[0..index]) orelse continue;
            const to = scenarioOf(from, forks[index + 2 ..]) orelse
                parseFork(forks[index + 2 ..]) orelse continue;
            return .{ .from = from, .to = to, .at = at };
        }
        return null;
    }

    /// The fork that runs a block at `timestamp`.
    pub fn forkAt(self: Network, timestamp: u64) Fork {
        const to = self.to orelse return self.from;
        return if (timestamp >= self.at) to else self.from;
    }

    /// EEST drops the source fork's prefix from a scenario of it:
    /// `AmsterdamToBPOIncreaseAtTime15k` moves to `AmsterdamBPOIncrease`.
    fn scenarioOf(from: Fork, suffix: []const u8) ?Fork {
        for (known_forks) |fork| {
            if (fork.name.len != from.name.len + suffix.len) continue;
            if (!std.mem.startsWith(u8, fork.name, from.name)) continue;
            if (std.ascii.eqlIgnoreCase(fork.name[from.name.len..], suffix)) return fork;
        }
        return null;
    }
};

fn hexDigit(char: u8) !u8 {
    return switch (char) {
        '0'...'9' => char - '0',
        'a'...'f' => char - 'a' + 10,
        'A'...'F' => char - 'A' + 10,
        else => error.InvalidHex,
    };
}

test "EEST state fork parser maps ConstantinopleFix to Petersburg" {
    try std.testing.expectEqual(evmz.eth.Revision.petersburg, parseStateFork("ConstantinopleFix"));
    try std.testing.expectEqual(evmz.eth.Revision.osaka, parseStateFork("Osaka"));
    try std.testing.expectEqual(evmz.eth.Revision.amsterdam, parseStateFork("Amsterdam"));
    try std.testing.expectEqual(evmz.eth.Revision.bogota, parseStateFork("Bogota"));
}
