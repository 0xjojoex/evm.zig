//! Open-lane state micro benchmarks: the row maps `OpenWorld` keeps, and the
//! storage-load path through `OpenState`.
//!
//! Two questions live here. Whether the sparse map still beats `std.HashMap`
//! for retained-capacity rows, and whether the `AddressWord` row key the
//! world carries (chosen on the guest, where it wins 0.5–3% of steps) also
//! holds up natively against a plain `Address` key. It does, by 4–7% on hits.

const std = @import("std");
const evmz = @import("evmz");
const zbench = @import("zbench");

const state_map_ops_per_run = 1024;
const state_map_clear_ops_per_run = 8;
const bench_config = zbench.Config{
    .max_iterations = 4096,
    .time_budget_ns = 50 * std.time.ns_per_ms,
};

const Address = evmz.Address;
const AddressWord = evmz.AddressWord;
const OpenWorld = evmz.state.OpenWorld;
const OpenState = evmz.state.OpenState;
const AccountRow = evmz.state.world_state.AccountRow;
const StorageRow = evmz.state.world_state.StorageRow;
const AccountId = OpenWorld.AccountId;
const StorageKey = OpenWorld.StorageKey;

/// The world's map, keyed by `AddressWord`.
const SparseAccountMap = OpenWorld.AccountMap;
const StdAccountMap = std.HashMap(
    AddressWord,
    AccountRow,
    AddressWord.HashContext,
    std.hash_map.default_max_load_percentage,
);
/// The alternative: the same sparse map over twenty-byte keys.
const SparseAddressAccountMap = evmz.state.sparse_hash_map.WithContext(
    Address,
    AccountRow,
    Address.HashContext,
);
const SparseStorageMap = OpenWorld.StorageMap;
const StdStorageMap = std.AutoHashMap(StorageKey, StorageRow);

var sparse_clear_small: []SparseStorageMap = &.{};
var std_clear_small: []StdStorageMap = &.{};
var sparse_clear_broad: []SparseStorageMap = &.{};
var std_clear_broad: []StdStorageMap = &.{};
var clear_storage_keys: []const StorageKey = &.{};
var hit_load_state: ?*OpenState = null;
var admit_load_state: ?*OpenState = null;
var hit_load_attempt: ?evmz.state.Checkpoint.AttemptId = null;
var admit_load_attempt: ?evmz.state.Checkpoint.AttemptId = null;

test "micro/state/key-hash" {
    var addresses: [state_map_ops_per_run]Address = undefined;
    var words: [state_map_ops_per_run]AddressWord = undefined;
    var slots: [state_map_ops_per_run]StorageKey = undefined;
    initAddresses(&addresses, 0);
    for (&words, addresses) |*word, address| word.* = .fromAddress(address);
    initStorageKeys(&slots, 0);

    var bench = zbench.Benchmark.init(std.testing.allocator, bench_config);
    defer bench.deinit();

    var address_context = KeyHashBench(Address, Address.HashContext){ .keys = &addresses };
    var word_context = KeyHashBench(AddressWord, AddressWord.HashContext){ .keys = &words };
    var slot_context = KeyHashBench(StorageKey, std.hash_map.AutoContext(StorageKey)){ .keys = &slots };
    try bench.addParam("key-hash/address/1024x", @as(*const @TypeOf(address_context), &address_context), .{});
    try bench.addParam("key-hash/address-word/1024x", @as(*const @TypeOf(word_context), &word_context), .{});
    try bench.addParam("key-hash/storage-key/1024x", @as(*const @TypeOf(slot_context), &slot_context), .{});

    try bench.run(std.testing.io, .stdout());
}

test "micro/state/open-world/account-row-get" {
    const cases = [_]StateMapCase{
        .{ .reserve = 64, .live = 64 },
        .{ .reserve = 1024, .live = 1 },
        .{ .reserve = 1024, .live = 64 },
        .{ .reserve = 16 * 1024, .live = 1 },
        .{ .reserve = 16 * 1024, .live = 64 },
    };

    var keys: [64]Address = undefined;
    var misses: [64]Address = undefined;
    var word_keys: [64]AddressWord = undefined;
    var word_misses: [64]AddressWord = undefined;
    initAddresses(&keys, 0);
    initAddresses(&misses, 1_000_000);
    for (&word_keys, keys) |*word, key| word.* = .fromAddress(key);
    for (&word_misses, misses) |*word, key| word.* = .fromAddress(key);

    var sparse_maps: [cases.len]SparseAccountMap = undefined;
    var std_maps: [cases.len]StdAccountMap = undefined;
    var address_maps: [cases.len]SparseAddressAccountMap = undefined;
    for (&sparse_maps) |*map| map.* = SparseAccountMap.init(std.testing.allocator);
    for (&std_maps) |*map| map.* = StdAccountMap.init(std.testing.allocator);
    for (&address_maps) |*map| map.* = SparseAddressAccountMap.init(std.testing.allocator);
    defer for (&sparse_maps) |*map| map.deinit();
    defer for (&std_maps) |*map| map.deinit();
    defer for (&address_maps) |*map| map.deinit();

    for (cases, 0..) |case, index| {
        try sparse_maps[index].ensureTotalCapacity(@intCast(case.reserve));
        try std_maps[index].ensureTotalCapacity(@intCast(case.reserve));
        try address_maps[index].ensureTotalCapacity(@intCast(case.reserve));
        fillAccountMap(&sparse_maps[index], word_keys[0..case.live]);
        fillAccountMap(&std_maps[index], word_keys[0..case.live]);
        fillAccountMap(&address_maps[index], keys[0..case.live]);
        try expectAccountMapParity(&sparse_maps[index], &std_maps[index], AddressWord, word_keys[0..case.live], &word_misses);
        try expectAccountMapParity(&sparse_maps[index], &address_maps[index], Address, word_keys[0..case.live], &word_misses);
    }

    var contexts = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer contexts.deinit();
    const context_allocator = contexts.allocator();

    var bench = zbench.Benchmark.init(std.testing.allocator, bench_config);
    defer bench.deinit();

    for (cases, 0..) |case, index| {
        const miss_count = @max(case.live, 1);
        try addAccountGetBench(SparseAccountMap, &bench, context_allocator, "sparse", case, "miss", &sparse_maps[index], word_misses[0..miss_count]);
        try addAccountGetBench(StdAccountMap, &bench, context_allocator, "std", case, "miss", &std_maps[index], word_misses[0..miss_count]);
        try addAccountGetBench(SparseAddressAccountMap, &bench, context_allocator, "sparse-address", case, "miss", &address_maps[index], misses[0..miss_count]);
        try addAccountGetBench(SparseAccountMap, &bench, context_allocator, "sparse", case, "hit", &sparse_maps[index], word_keys[0..case.live]);
        try addAccountGetBench(StdAccountMap, &bench, context_allocator, "std", case, "hit", &std_maps[index], word_keys[0..case.live]);
        try addAccountGetBench(SparseAddressAccountMap, &bench, context_allocator, "sparse-address", case, "hit", &address_maps[index], keys[0..case.live]);
    }

    try bench.run(std.testing.io, .stdout());
}

test "micro/state/open-world/storage-row-get" {
    const cases = [_]StateMapCase{
        .{ .reserve = 64, .live = 64 },
        .{ .reserve = 8 * 1024, .live = 0 },
        .{ .reserve = 8 * 1024, .live = 1 },
        .{ .reserve = 8 * 1024, .live = 64 },
        .{ .reserve = 64 * 1024, .live = 0 },
        .{ .reserve = 64 * 1024, .live = 1 },
        .{ .reserve = 64 * 1024, .live = 64 },
    };

    var keys: [64]StorageKey = undefined;
    var misses: [64]StorageKey = undefined;
    initStorageKeys(&keys, 0);
    initStorageKeys(&misses, 1_000_000);

    var sparse_maps: [cases.len]SparseStorageMap = undefined;
    var std_maps: [cases.len]StdStorageMap = undefined;
    for (&sparse_maps) |*map| map.* = SparseStorageMap.init(std.testing.allocator);
    for (&std_maps) |*map| map.* = StdStorageMap.init(std.testing.allocator);
    defer for (&sparse_maps) |*map| map.deinit();
    defer for (&std_maps) |*map| map.deinit();

    for (cases, 0..) |case, index| {
        try sparse_maps[index].ensureTotalCapacity(@intCast(case.reserve));
        try std_maps[index].ensureTotalCapacity(@intCast(case.reserve));
        fillStorageMap(&sparse_maps[index], keys[0..case.live]);
        fillStorageMap(&std_maps[index], keys[0..case.live]);
        try expectStorageMapParity(&sparse_maps[index], &std_maps[index], keys[0..case.live], &misses);
    }

    var contexts = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer contexts.deinit();
    const context_allocator = contexts.allocator();

    var bench = zbench.Benchmark.init(std.testing.allocator, bench_config);
    defer bench.deinit();

    for (cases, 0..) |case, index| {
        const miss_count = @max(case.live, 1);
        try addStorageGetBench(SparseStorageMap, &bench, context_allocator, "sparse", case, "miss", &sparse_maps[index], misses[0..miss_count]);
        try addStorageGetBench(StdStorageMap, &bench, context_allocator, "std", case, "miss", &std_maps[index], misses[0..miss_count]);
        if (case.live != 0) {
            try addStorageGetBench(SparseStorageMap, &bench, context_allocator, "sparse", case, "hit", &sparse_maps[index], keys[0..case.live]);
            try addStorageGetBench(StdStorageMap, &bench, context_allocator, "std", case, "hit", &std_maps[index], keys[0..case.live]);
        }
    }

    try bench.run(std.testing.io, .stdout());
}

test "micro/state/open-state/storage-load" {
    var slots: [state_map_ops_per_run]u256 = undefined;
    for (&slots, 0..) |*slot, index| slot.* = mixedWord(@intCast(index));
    const contract = benchContract();

    // Rows admitted by seeding: every load finds its row and only warms it.
    var hit = OpenState.init(std.testing.allocator, .init(std.testing.allocator, null));
    defer hit.deinit();
    try seedStorage(&hit, contract, &slots);

    // No reader and no rows: every load admits an absent account or a zero
    // slot, which is the open lane's cold path minus the reader itself.
    var admit = OpenState.init(std.testing.allocator, .init(std.testing.allocator, null));
    defer admit.deinit();

    hit_load_state = &hit;
    admit_load_state = &admit;
    defer {
        if (hit_load_attempt) |attempt| hit.discard(attempt);
        if (admit_load_attempt) |attempt| admit.discard(attempt);
        hit_load_state = null;
        admit_load_state = null;
        hit_load_attempt = null;
        admit_load_attempt = null;
    }

    var hit_context = StorageLoadBench{ .state = &hit, .contract = .fromAddress(contract), .slots = &slots };
    var admit_context = StorageLoadBench{ .state = &admit, .contract = .fromAddress(contract), .slots = &slots };
    var bench = zbench.Benchmark.init(std.testing.allocator, bench_config);
    defer bench.deinit();
    try bench.addParam(
        "open-state/storage-load/row-hit/1024x",
        @as(*const StorageLoadBench, &hit_context),
        .{ .hooks = .{ .before_each = prepareHitStorageLoads } },
    );
    try bench.addParam(
        "open-state/storage-load/admit/1024x",
        @as(*const StorageLoadBench, &admit_context),
        .{ .hooks = .{ .before_each = prepareAdmitStorageLoads } },
    );

    try bench.run(std.testing.io, .stdout());
}

test "micro/state/open-world/storage-row-clear" {
    var keys: [1024]StorageKey = undefined;
    initStorageKeys(&keys, 0);

    var sparse_small: [state_map_clear_ops_per_run]SparseStorageMap = undefined;
    var std_small: [state_map_clear_ops_per_run]StdStorageMap = undefined;
    var sparse_broad: [state_map_clear_ops_per_run]SparseStorageMap = undefined;
    var std_broad: [state_map_clear_ops_per_run]StdStorageMap = undefined;
    for (&sparse_small) |*map| map.* = SparseStorageMap.init(std.testing.allocator);
    for (&std_small) |*map| map.* = StdStorageMap.init(std.testing.allocator);
    for (&sparse_broad) |*map| map.* = SparseStorageMap.init(std.testing.allocator);
    for (&std_broad) |*map| map.* = StdStorageMap.init(std.testing.allocator);
    defer for (&sparse_small) |*map| map.deinit();
    defer for (&std_small) |*map| map.deinit();
    defer for (&sparse_broad) |*map| map.deinit();
    defer for (&std_broad) |*map| map.deinit();

    for (&sparse_small) |*map| try map.ensureTotalCapacity(8 * 1024);
    for (&std_small) |*map| try map.ensureTotalCapacity(8 * 1024);
    for (&sparse_broad) |*map| try map.ensureTotalCapacity(64 * 1024);
    for (&std_broad) |*map| try map.ensureTotalCapacity(64 * 1024);

    sparse_clear_small = &sparse_small;
    std_clear_small = &std_small;
    sparse_clear_broad = &sparse_broad;
    std_clear_broad = &std_broad;
    clear_storage_keys = &keys;
    defer {
        sparse_clear_small = &.{};
        std_clear_small = &.{};
        sparse_clear_broad = &.{};
        std_clear_broad = &.{};
        clear_storage_keys = &.{};
    }

    var bench = zbench.Benchmark.init(std.testing.allocator, bench_config);
    defer bench.deinit();

    var names = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer names.deinit();

    try addClearBenchmarks(&bench, names.allocator(), "8192", clearSparseSmall, clearStdSmall, .{
        .sparse_64 = prepareSparseSmall64,
        .std_64 = prepareStdSmall64,
        .sparse_1024 = prepareSparseSmall1024,
        .std_1024 = prepareStdSmall1024,
    });
    try addClearBenchmarks(&bench, names.allocator(), "65536", clearSparseBroad, clearStdBroad, .{
        .sparse_64 = prepareSparseBroad64,
        .std_64 = prepareStdBroad64,
        .sparse_1024 = prepareSparseBroad1024,
        .std_1024 = prepareStdBroad1024,
    });

    try bench.run(std.testing.io, .stdout());

    for (&sparse_small) |*map| {
        try std.testing.expectEqual(@as(u32, 0), map.count());
        for (keys) |key| try std.testing.expect(!map.contains(key));
    }
    for (&std_small) |*map| try std.testing.expectEqual(@as(usize, 0), map.count());
    for (&sparse_broad) |*map| {
        try std.testing.expectEqual(@as(u32, 0), map.count());
        for (keys) |key| try std.testing.expect(!map.contains(key));
    }
    for (&std_broad) |*map| try std.testing.expectEqual(@as(usize, 0), map.count());
}

const StateMapCase = struct {
    reserve: usize,
    live: usize,
};

fn KeyHashBench(comptime Key: type, comptime Context: type) type {
    return struct {
        const Self = @This();

        keys: []const Key,

        pub fn run(self: *Self, _: std.mem.Allocator) void {
            const context: Context = .{};
            var acc: u64 = 0;
            for (self.keys) |key| acc +%= context.hash(key);
            std.mem.doNotOptimizeAway(acc);
        }
    };
}

fn AccountGetBench(comptime Map: type, comptime Key: type) type {
    return struct {
        const Self = @This();

        map: *Map,
        keys: []const Key,

        pub fn run(self: *Self, _: std.mem.Allocator) void {
            std.debug.assert(std.math.isPowerOfTwo(self.keys.len));
            const mask = self.keys.len - 1;
            var acc: u64 = 0;
            for (0..state_map_ops_per_run) |index| {
                const row = self.map.getPtr(self.keys[index & mask]) orelse continue;
                const current = row.current orelse continue;
                acc +%= current.nonce;
            }
            std.mem.doNotOptimizeAway(acc);
        }
    };
}

fn StorageGetBench(comptime Map: type) type {
    return struct {
        const Self = @This();

        map: *Map,
        keys: []const StorageKey,

        pub fn run(self: *Self, _: std.mem.Allocator) void {
            std.debug.assert(std.math.isPowerOfTwo(self.keys.len));
            const mask = self.keys.len - 1;
            var acc: u256 = 0;
            for (0..state_map_ops_per_run) |index| {
                if (self.map.get(self.keys[index & mask])) |row| acc +%= row.current;
            }
            std.mem.doNotOptimizeAway(acc);
        }
    };
}

const StorageLoadBench = struct {
    state: *OpenState,
    contract: AddressWord,
    slots: []const u256,

    pub fn run(self: *StorageLoadBench, _: std.mem.Allocator) void {
        var acc: u256 = 0;
        for (self.slots) |slot| {
            const result = self.state.loadStorage(self.contract, slot) catch unreachable;
            acc +%= result.value;
        }
        std.mem.doNotOptimizeAway(acc);
    }
};

fn addAccountGetBench(
    comptime Map: type,
    bench: *zbench.Benchmark,
    allocator: std.mem.Allocator,
    map_name: []const u8,
    case: StateMapCase,
    result_name: []const u8,
    map: *Map,
    keys: anytype,
) !void {
    const Context = AccountGetBench(Map, std.meta.Elem(@TypeOf(keys)));
    const context = try allocator.create(Context);
    context.* = .{ .map = map, .keys = keys };
    const name = try std.fmt.allocPrint(
        allocator,
        "account-row-get/{s}/reserve{d}/live{d}/{s}/1024x",
        .{ map_name, case.reserve, case.live, result_name },
    );
    try bench.addParam(name, @as(*const Context, context), .{});
}

fn addStorageGetBench(
    comptime Map: type,
    bench: *zbench.Benchmark,
    allocator: std.mem.Allocator,
    map_name: []const u8,
    case: StateMapCase,
    result_name: []const u8,
    map: *Map,
    keys: []const StorageKey,
) !void {
    const Context = StorageGetBench(Map);
    const context = try allocator.create(Context);
    context.* = .{ .map = map, .keys = keys };
    const name = try std.fmt.allocPrint(
        allocator,
        "storage-row-get/{s}/reserve{d}/live{d}/{s}/1024x",
        .{ map_name, case.reserve, case.live, result_name },
    );
    try bench.addParam(name, @as(*const Context, context), .{});
}

fn benchContract() Address {
    return evmz.addr(0x2000000000000000000000000000000000000002);
}

/// Storage rows all belong to one account row, as they would after one
/// contract's slots were admitted.
fn initStorageKeys(keys: []StorageKey, offset: u64) void {
    const account: AccountId = @enumFromInt(0);
    for (keys, 0..) |*key, index| {
        key.* = .{
            .account = account,
            .slot = mixedWord(offset + @as(u64, @intCast(index))),
        };
    }
}

fn initAddresses(addresses: []Address, offset: u64) void {
    for (addresses, 0..) |*address, index| {
        var bytes = [_]u8{0} ** Address.len;
        bytes[0] = 0x20;
        std.mem.writeInt(u64, bytes[12..20], offset + @as(u64, @intCast(index)) + 1, .big);
        address.* = .fromBytes(bytes);
    }
}

fn mixedWord(seed: u64) u256 {
    return @as(u256, mix64(seed)) |
        (@as(u256, mix64(seed +% 1)) << 64) |
        (@as(u256, mix64(seed +% 2)) << 128) |
        (@as(u256, mix64(seed +% 3)) << 192);
}

fn mix64(seed: u64) u64 {
    var value = seed +% 0x9e37_79b9_7f4a_7c15;
    value = (value ^ (value >> 30)) *% 0xbf58_476d_1ce4_e5b9;
    value = (value ^ (value >> 27)) *% 0x94d0_49bb_1331_11eb;
    return value ^ (value >> 31);
}

fn fillStorageMap(map: anytype, keys: []const StorageKey) void {
    for (keys, 0..) |key, index| map.putAssumeCapacityNoClobber(
        key,
        .{ .current = mixedWord(@intCast(index + 42)) },
    );
}

fn fillAccountMap(map: anytype, keys: anytype) void {
    for (keys, 0..) |key, index| {
        map.putAssumeCapacityNoClobber(key, .admitted(.{ .nonce = @intCast(index + 1) }));
    }
}

fn expectAccountMapParity(
    sparse: *SparseAccountMap,
    other: anytype,
    comptime OtherKey: type,
    hits: []const AddressWord,
    misses: []const AddressWord,
) !void {
    try std.testing.expectEqual(@as(usize, sparse.count()), other.count());
    for (hits) |key| {
        const expected = sparse.getPtr(key).?.*;
        const actual = other.getPtr(keyFor(OtherKey, key)).?.*;
        try std.testing.expectEqualDeep(expected, actual);
    }
    for (misses) |key| {
        try std.testing.expect(sparse.getPtr(key) == null);
        try std.testing.expect(other.getPtr(keyFor(OtherKey, key)) == null);
    }
}

fn keyFor(comptime Key: type, word: AddressWord) Key {
    return if (Key == AddressWord) word else word.address();
}

fn expectStorageMapParity(
    sparse: *SparseStorageMap,
    standard: *StdStorageMap,
    hits: []const StorageKey,
    misses: []const StorageKey,
) !void {
    try std.testing.expectEqual(@as(usize, sparse.count()), standard.count());
    for (hits) |key| try std.testing.expectEqualDeep(sparse.get(key), standard.get(key));
    for (misses) |key| try std.testing.expectEqualDeep(sparse.get(key), standard.get(key));
}

fn seedStorage(state: *OpenState, contract: Address, slots: []const u256) !void {
    var account = evmz.state.MemoryAccount.init(std.testing.allocator);
    account.account.nonce = 1;
    for (slots, 0..) |slot, index| try account.storage.put(slot, mixedWord(@intCast(index + 42)));
    try state.seedAccount(contract, account);
}

fn prepareHitStorageLoads() void {
    const state = hit_load_state.?;
    if (hit_load_attempt) |attempt| state.discard(attempt);
    hit_load_attempt = openLoadAttempt(state);
}

/// Rows admitted by the previous run are dropped so every load admits again.
fn prepareAdmitStorageLoads() void {
    const state = admit_load_state.?;
    if (admit_load_attempt) |attempt| state.discard(attempt);
    state.discardAccepted();
    admit_load_attempt = openLoadAttempt(state);
}

fn openLoadAttempt(state: *OpenState) evmz.state.Checkpoint.AttemptId {
    const attempt = state.beginTransaction();
    state.beginScope();
    state.reserveAccessHint(.{
        .accounts = 1,
        .storage_keys = state_map_ops_per_run,
    }) catch unreachable;
    return attempt;
}

const ClearHooks = struct {
    sparse_64: *const fn () void,
    std_64: *const fn () void,
    sparse_1024: *const fn () void,
    std_1024: *const fn () void,
};

fn addClearBenchmarks(
    bench: *zbench.Benchmark,
    allocator: std.mem.Allocator,
    reserve: []const u8,
    sparse_clear: *const fn (std.mem.Allocator) void,
    std_clear: *const fn (std.mem.Allocator) void,
    hooks: ClearHooks,
) !void {
    try bench.add(
        try std.fmt.allocPrint(allocator, "storage-row-clear/sparse/reserve{s}/live64/8x", .{reserve}),
        sparse_clear,
        .{ .iterations = 512, .hooks = .{ .before_each = hooks.sparse_64 } },
    );
    try bench.add(
        try std.fmt.allocPrint(allocator, "storage-row-clear/std/reserve{s}/live64/8x", .{reserve}),
        std_clear,
        .{ .iterations = 512, .hooks = .{ .before_each = hooks.std_64 } },
    );
    try bench.add(
        try std.fmt.allocPrint(allocator, "storage-row-clear/sparse/reserve{s}/live1024/8x", .{reserve}),
        sparse_clear,
        .{ .iterations = 512, .hooks = .{ .before_each = hooks.sparse_1024 } },
    );
    try bench.add(
        try std.fmt.allocPrint(allocator, "storage-row-clear/std/reserve{s}/live1024/8x", .{reserve}),
        std_clear,
        .{ .iterations = 512, .hooks = .{ .before_each = hooks.std_1024 } },
    );
}

fn clearSparseSmall(_: std.mem.Allocator) void {
    for (sparse_clear_small) |*map| map.clearRetainingCapacity();
}

fn clearStdSmall(_: std.mem.Allocator) void {
    for (std_clear_small) |*map| map.clearRetainingCapacity();
}

fn clearSparseBroad(_: std.mem.Allocator) void {
    for (sparse_clear_broad) |*map| map.clearRetainingCapacity();
}

fn clearStdBroad(_: std.mem.Allocator) void {
    for (std_clear_broad) |*map| map.clearRetainingCapacity();
}

fn prepareSparseSmall64() void {
    prepareClear(sparse_clear_small, 64);
}

fn prepareStdSmall64() void {
    prepareClear(std_clear_small, 64);
}

fn prepareSparseSmall1024() void {
    prepareClear(sparse_clear_small, 1024);
}

fn prepareStdSmall1024() void {
    prepareClear(std_clear_small, 1024);
}

fn prepareSparseBroad64() void {
    prepareClear(sparse_clear_broad, 64);
}

fn prepareStdBroad64() void {
    prepareClear(std_clear_broad, 64);
}

fn prepareSparseBroad1024() void {
    prepareClear(sparse_clear_broad, 1024);
}

fn prepareStdBroad1024() void {
    prepareClear(std_clear_broad, 1024);
}

fn prepareClear(maps: anytype, live: usize) void {
    for (maps) |*map| {
        std.debug.assert(map.count() == 0);
        fillStorageMap(map, clear_storage_keys[0..live]);
    }
}
