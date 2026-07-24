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
const StorageKey = evmz.state.StorageKey;
const TrackedState = evmz.state.TrackedState;
const StorageSlot = TrackedState.ScopeStorage;
const SparseStorageSlotMap = @FieldType(TrackedState.Scope, "storage");
const StdStorageSlotMap = std.AutoHashMap(StorageKey, StorageSlot);
const SparseStorageMap = @FieldType(TrackedState.Transaction, "storage");
const StdStorageMap = std.AutoHashMap(StorageKey, TrackedState.StorageRow);
const SparseAddressMap = @FieldType(TrackedState.Transaction, "accounts");
const StdAddressMap = std.AutoHashMap(Address, TrackedState.AccountRow);

var sparse_clear_small: []SparseStorageSlotMap = &.{};
var std_clear_small: []StdStorageSlotMap = &.{};
var sparse_clear_broad: []SparseStorageSlotMap = &.{};
var std_clear_broad: []StdStorageSlotMap = &.{};
var clear_storage_keys: []const StorageKey = &.{};
var accepted_hit_load_state: ?*TrackedState = null;
var accepted_miss_load_state: ?*TrackedState = null;
var accepted_hit_attempt: ?TrackedState.AttemptId = null;
var accepted_miss_attempt: ?TrackedState.AttemptId = null;

test "micro/state/sparse-hash-map/hash" {
    var keys: [state_map_ops_per_run]StorageKey = undefined;
    initStorageKeys(&keys, 0);

    var bench = zbench.Benchmark.init(std.testing.allocator, bench_config);
    defer bench.deinit();

    var hash_context = StorageKeyHashBench{ .keys = &keys };
    try bench.addParam(
        "sparse-hash-map/storage-key/hash/1024x",
        @as(*const StorageKeyHashBench, &hash_context),
        .{},
    );

    try bench.run(std.testing.io, .stdout());
}

test "micro/state/sparse-hash-map/storage-slot-contains" {
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

    var sparse_maps: [cases.len]SparseStorageSlotMap = undefined;
    var std_maps: [cases.len]StdStorageSlotMap = undefined;
    for (&sparse_maps) |*map| map.* = SparseStorageSlotMap.init(std.testing.allocator);
    for (&std_maps) |*map| map.* = StdStorageSlotMap.init(std.testing.allocator);
    defer for (&sparse_maps) |*map| map.deinit();
    defer for (&std_maps) |*map| map.deinit();

    for (cases, 0..) |case, index| {
        try sparse_maps[index].ensureTotalCapacity(@intCast(case.reserve));
        try std_maps[index].ensureTotalCapacity(@intCast(case.reserve));
        fillStorageSlotMap(&sparse_maps[index], keys[0..case.live]);
        fillStorageSlotMap(&std_maps[index], keys[0..case.live]);
        try expectStorageSlotMapParity(&sparse_maps[index], &std_maps[index], keys[0..case.live], &misses);
    }

    var contexts = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer contexts.deinit();
    const context_allocator = contexts.allocator();

    var bench = zbench.Benchmark.init(std.testing.allocator, bench_config);
    defer bench.deinit();

    for (cases, 0..) |case, index| {
        const miss_count = @max(case.live, 1);
        try addContainsBench(
            SparseStorageSlotMap,
            &bench,
            context_allocator,
            "sparse",
            case,
            "miss",
            &sparse_maps[index],
            misses[0..miss_count],
        );
        try addContainsBench(
            StdStorageSlotMap,
            &bench,
            context_allocator,
            "std",
            case,
            "miss",
            &std_maps[index],
            misses[0..miss_count],
        );
        if (case.live != 0) {
            try addContainsBench(
                SparseStorageSlotMap,
                &bench,
                context_allocator,
                "sparse",
                case,
                "hit",
                &sparse_maps[index],
                keys[0..case.live],
            );
            try addContainsBench(
                StdStorageSlotMap,
                &bench,
                context_allocator,
                "std",
                case,
                "hit",
                &std_maps[index],
                keys[0..case.live],
            );
        }
    }

    try bench.run(std.testing.io, .stdout());
}

test "micro/state/sparse-hash-map/storage-overlay-get" {
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
        try addStorageGetBench(
            SparseStorageMap,
            &bench,
            context_allocator,
            "sparse",
            case,
            "miss",
            &sparse_maps[index],
            misses[0..miss_count],
        );
        try addStorageGetBench(
            StdStorageMap,
            &bench,
            context_allocator,
            "std",
            case,
            "miss",
            &std_maps[index],
            misses[0..miss_count],
        );
        if (case.live != 0) {
            try addStorageGetBench(
                SparseStorageMap,
                &bench,
                context_allocator,
                "sparse",
                case,
                "hit",
                &sparse_maps[index],
                keys[0..case.live],
            );
            try addStorageGetBench(
                StdStorageMap,
                &bench,
                context_allocator,
                "std",
                case,
                "hit",
                &std_maps[index],
                keys[0..case.live],
            );
        }
    }

    try bench.run(std.testing.io, .stdout());
}

test "micro/state/tracked-state/cold-storage-load" {
    var keys: [state_map_ops_per_run]StorageKey = undefined;
    var misses: [state_map_ops_per_run]StorageKey = undefined;
    initStorageKeys(&keys, 0);
    initStorageKeys(&misses, 1_000_000);

    var accepted_hit = TrackedState.init(std.testing.allocator);
    defer accepted_hit.deinit();
    try configureStorageLoadState(&accepted_hit, &keys);

    var accepted_miss = TrackedState.init(std.testing.allocator);
    defer accepted_miss.deinit();
    try configureStorageLoadState(&accepted_miss, &misses);

    accepted_hit_load_state = &accepted_hit;
    accepted_miss_load_state = &accepted_miss;
    defer {
        if (accepted_hit_attempt) |attempt| accepted_hit.discard(attempt);
        if (accepted_miss_attempt) |attempt| accepted_miss.discard(attempt);
        accepted_hit_load_state = null;
        accepted_miss_load_state = null;
        accepted_hit_attempt = null;
        accepted_miss_attempt = null;
    }

    var accepted_hit_context = TrackedStorageLoadBench{ .state = &accepted_hit, .keys = &keys };
    var accepted_miss_context = TrackedStorageLoadBench{ .state = &accepted_miss, .keys = &keys };
    var bench = zbench.Benchmark.init(std.testing.allocator, bench_config);
    defer bench.deinit();
    try bench.addParam(
        "tracked-state/cold-storage-load/accepted-hit/1024x",
        @as(*const TrackedStorageLoadBench, &accepted_hit_context),
        .{ .hooks = .{ .before_each = prepareAcceptedHitStorageLoads } },
    );
    try bench.addParam(
        "tracked-state/cold-storage-load/accepted-miss/1024x",
        @as(*const TrackedStorageLoadBench, &accepted_miss_context),
        .{ .hooks = .{ .before_each = prepareAcceptedMissStorageLoads } },
    );

    try bench.run(std.testing.io, .stdout());
}

test "micro/state/sparse-hash-map/account-get-ptr" {
    const cases = [_]StateMapCase{
        .{ .reserve = 64, .live = 64 },
        .{ .reserve = 1024, .live = 1 },
        .{ .reserve = 1024, .live = 64 },
        .{ .reserve = 16 * 1024, .live = 1 },
        .{ .reserve = 16 * 1024, .live = 64 },
    };

    var keys: [64]Address = undefined;
    var misses: [64]Address = undefined;
    initAddresses(&keys, 0);
    initAddresses(&misses, 1_000_000);

    var sparse_maps: [cases.len]SparseAddressMap = undefined;
    var std_maps: [cases.len]StdAddressMap = undefined;
    for (&sparse_maps) |*map| map.* = SparseAddressMap.init(std.testing.allocator);
    for (&std_maps) |*map| map.* = StdAddressMap.init(std.testing.allocator);
    defer for (&sparse_maps) |*map| map.deinit();
    defer for (&std_maps) |*map| map.deinit();

    for (cases, 0..) |case, index| {
        try sparse_maps[index].ensureTotalCapacity(@intCast(case.reserve));
        try std_maps[index].ensureTotalCapacity(@intCast(case.reserve));
        fillAddressMap(&sparse_maps[index], keys[0..case.live]);
        fillAddressMap(&std_maps[index], keys[0..case.live]);
        try expectAddressMapParity(&sparse_maps[index], &std_maps[index], keys[0..case.live], &misses);
    }

    var contexts = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer contexts.deinit();
    const context_allocator = contexts.allocator();

    var bench = zbench.Benchmark.init(std.testing.allocator, bench_config);
    defer bench.deinit();

    for (cases, 0..) |case, index| {
        const miss_count = @max(case.live, 1);
        try addGetPtrBench(
            SparseAddressMap,
            &bench,
            context_allocator,
            "sparse",
            case,
            "miss",
            &sparse_maps[index],
            misses[0..miss_count],
        );
        try addGetPtrBench(
            StdAddressMap,
            &bench,
            context_allocator,
            "std",
            case,
            "miss",
            &std_maps[index],
            misses[0..miss_count],
        );
        try addGetPtrBench(
            SparseAddressMap,
            &bench,
            context_allocator,
            "sparse",
            case,
            "hit",
            &sparse_maps[index],
            keys[0..case.live],
        );
        try addGetPtrBench(
            StdAddressMap,
            &bench,
            context_allocator,
            "std",
            case,
            "hit",
            &std_maps[index],
            keys[0..case.live],
        );
    }

    try bench.run(std.testing.io, .stdout());
}

test "micro/state/sparse-hash-map/clear-retaining-capacity" {
    var keys: [1024]StorageKey = undefined;
    initStorageKeys(&keys, 0);

    var sparse_small: [state_map_clear_ops_per_run]SparseStorageSlotMap = undefined;
    var std_small: [state_map_clear_ops_per_run]StdStorageSlotMap = undefined;
    var sparse_broad: [state_map_clear_ops_per_run]SparseStorageSlotMap = undefined;
    var std_broad: [state_map_clear_ops_per_run]StdStorageSlotMap = undefined;
    for (&sparse_small) |*map| map.* = SparseStorageSlotMap.init(std.testing.allocator);
    for (&std_small) |*map| map.* = StdStorageSlotMap.init(std.testing.allocator);
    for (&sparse_broad) |*map| map.* = SparseStorageSlotMap.init(std.testing.allocator);
    for (&std_broad) |*map| map.* = StdStorageSlotMap.init(std.testing.allocator);
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
        try std.testing.expectEqual(@as(usize, 0), map.debugOccupiedSlots());
    }
    for (&std_small) |*map| try std.testing.expectEqual(@as(usize, 0), map.count());
    for (&sparse_broad) |*map| {
        try std.testing.expectEqual(@as(u32, 0), map.count());
        try std.testing.expectEqual(@as(usize, 0), map.debugOccupiedSlots());
    }
    for (&std_broad) |*map| try std.testing.expectEqual(@as(usize, 0), map.count());
}

const StateMapCase = struct {
    reserve: usize,
    live: usize,
};

const StorageKeyHashBench = struct {
    keys: []const StorageKey,

    pub fn run(self: *StorageKeyHashBench, _: std.mem.Allocator) void {
        const context: std.hash_map.AutoContext(StorageKey) = .{};
        var acc: u64 = 0;
        for (self.keys) |key| acc +%= context.hash(key);
        std.mem.doNotOptimizeAway(acc);
    }
};

fn ContainsBench(comptime Map: type, comptime Key: type) type {
    return struct {
        const Self = @This();

        map: *Map,
        keys: []const Key,

        pub fn run(self: *Self, _: std.mem.Allocator) void {
            std.debug.assert(std.math.isPowerOfTwo(self.keys.len));
            const mask = self.keys.len - 1;
            var hits: usize = 0;
            for (0..state_map_ops_per_run) |index| {
                hits +%= @intFromBool(self.map.contains(self.keys[index & mask]));
            }
            std.mem.doNotOptimizeAway(hits);
        }
    };
}

fn GetPtrBench(comptime Map: type, comptime Key: type) type {
    return struct {
        const Self = @This();

        map: *Map,
        keys: []const Key,

        pub fn run(self: *Self, _: std.mem.Allocator) void {
            std.debug.assert(std.math.isPowerOfTwo(self.keys.len));
            const mask = self.keys.len - 1;
            var acc: u64 = 0;
            for (0..state_map_ops_per_run) |index| {
                if (self.map.getPtr(self.keys[index & mask])) |row| {
                    const current = row.current orelse continue;
                    acc +%= switch (current) {
                        .loaded => |account| account.nonce,
                        .absent, .exists_only => 0,
                    };
                }
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
                if (self.map.get(self.keys[index & mask])) |row| acc +%= row.current orelse 0;
            }
            std.mem.doNotOptimizeAway(acc);
        }
    };
}

const TrackedStorageLoadBench = struct {
    state: *TrackedState,
    keys: []const StorageKey,

    pub fn run(self: *TrackedStorageLoadBench, _: std.mem.Allocator) void {
        var acc: u256 = 0;
        for (self.keys) |key| {
            const result = self.state.loadStorage(key.address, key.key) catch unreachable;
            acc +%= result.value;
        }
        std.mem.doNotOptimizeAway(acc);
    }
};

fn addContainsBench(
    comptime Map: type,
    bench: *zbench.Benchmark,
    allocator: std.mem.Allocator,
    map_name: []const u8,
    case: StateMapCase,
    result_name: []const u8,
    map: *Map,
    keys: []const StorageKey,
) !void {
    const Context = ContainsBench(Map, StorageKey);
    const context = try allocator.create(Context);
    context.* = .{ .map = map, .keys = keys };
    const name = try std.fmt.allocPrint(
        allocator,
        "storage-slot-contains/{s}/reserve{d}/live{d}/{s}/1024x",
        .{ map_name, case.reserve, case.live, result_name },
    );
    try bench.addParam(name, @as(*const Context, context), .{});
}

fn addGetPtrBench(
    comptime Map: type,
    bench: *zbench.Benchmark,
    allocator: std.mem.Allocator,
    map_name: []const u8,
    case: StateMapCase,
    result_name: []const u8,
    map: *Map,
    keys: []const Address,
) !void {
    const Context = GetPtrBench(Map, Address);
    const context = try allocator.create(Context);
    context.* = .{ .map = map, .keys = keys };
    const name = try std.fmt.allocPrint(
        allocator,
        "account-get-ptr/{s}/reserve{d}/live{d}/{s}/1024x",
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
        "storage-overlay-get/{s}/reserve{d}/live{d}/{s}/1024x",
        .{ map_name, case.reserve, case.live, result_name },
    );
    try bench.addParam(name, @as(*const Context, context), .{});
}

fn initStorageKeys(keys: []StorageKey, offset: u64) void {
    const contract = evmz.addr(0x2000000000000000000000000000000000000002);
    for (keys, 0..) |*key, index| {
        key.* = .{
            .address = contract,
            .key = mixedWord(offset + @as(u64, @intCast(index))),
        };
    }
}

fn initAddresses(addresses: []Address, offset: u64) void {
    for (addresses, 0..) |*address, index| {
        address.* = [_]u8{0} ** 20;
        address[0] = 0x20;
        std.mem.writeInt(u64, address[12..20], offset + @as(u64, @intCast(index)) + 1, .big);
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

fn fillStorageSlotMap(map: anytype, keys: []const StorageKey) void {
    for (keys) |key| map.putAssumeCapacityNoClobber(key, StorageSlot{});
}

fn fillStorageMap(map: anytype, keys: []const StorageKey) void {
    for (keys, 0..) |key, index| map.putAssumeCapacityNoClobber(
        key,
        .{ .current = mixedWord(@intCast(index + 42)) },
    );
}

fn fillAddressMap(map: anytype, keys: []const Address) void {
    for (keys, 0..) |key, index| {
        map.putAssumeCapacityNoClobber(key, .{
            .current = .{ .loaded = .{ .nonce = @intCast(index + 1) } },
        });
    }
}

fn expectStorageSlotMapParity(
    sparse: *SparseStorageSlotMap,
    standard: *StdStorageSlotMap,
    hits: []const StorageKey,
    misses: []const StorageKey,
) !void {
    try std.testing.expectEqual(@as(usize, sparse.count()), standard.count());
    for (hits) |key| {
        try std.testing.expect(sparse.contains(key));
        try std.testing.expect(standard.contains(key));
    }
    for (misses) |key| {
        try std.testing.expect(!sparse.contains(key));
        try std.testing.expect(!standard.contains(key));
    }
}

fn expectAddressMapParity(
    sparse: *SparseAddressMap,
    standard: *StdAddressMap,
    hits: []const Address,
    misses: []const Address,
) !void {
    try std.testing.expectEqual(@as(usize, sparse.count()), standard.count());
    for (hits) |key| {
        try std.testing.expectEqualDeep(sparse.getPtr(key).?.*, standard.getPtr(key).?.*);
    }
    for (misses) |key| {
        try std.testing.expectEqual(sparse.getPtr(key) == null, standard.getPtr(key) == null);
    }
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

fn configureStorageLoadState(state: *TrackedState, accepted_keys: []const StorageKey) !void {
    var account = evmz.state.MemoryAccount.init(std.testing.allocator);
    for (accepted_keys, 0..) |key, index| {
        try account.storage.put(key.key, mixedWord(@intCast(index + 42)));
    }
    try state.seedAccount(accepted_keys[0].address, account);
}

fn prepareAcceptedHitStorageLoads() void {
    if (accepted_hit_attempt) |attempt| accepted_hit_load_state.?.discard(attempt);
    const attempt = accepted_hit_load_state.?.beginTransaction();
    accepted_hit_load_state.?.beginScope();
    accepted_hit_load_state.?.reserveAccessHint(.{
        .accounts = 1,
        .storage_keys = state_map_ops_per_run,
    }) catch unreachable;
    accepted_hit_attempt = attempt;
}

fn prepareAcceptedMissStorageLoads() void {
    if (accepted_miss_attempt) |attempt| accepted_miss_load_state.?.discard(attempt);
    const attempt = accepted_miss_load_state.?.beginTransaction();
    accepted_miss_load_state.?.beginScope();
    accepted_miss_load_state.?.reserveAccessHint(.{
        .accounts = 1,
        .storage_keys = state_map_ops_per_run,
    }) catch unreachable;
    accepted_miss_attempt = attempt;
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
        try std.fmt.allocPrint(allocator, "clear/sparse/reserve{s}/live64/8x", .{reserve}),
        sparse_clear,
        .{ .iterations = 512, .hooks = .{ .before_each = hooks.sparse_64 } },
    );
    try bench.add(
        try std.fmt.allocPrint(allocator, "clear/std/reserve{s}/live64/8x", .{reserve}),
        std_clear,
        .{ .iterations = 512, .hooks = .{ .before_each = hooks.std_64 } },
    );
    try bench.add(
        try std.fmt.allocPrint(allocator, "clear/sparse/reserve{s}/live1024/8x", .{reserve}),
        sparse_clear,
        .{ .iterations = 512, .hooks = .{ .before_each = hooks.sparse_1024 } },
    );
    try bench.add(
        try std.fmt.allocPrint(allocator, "clear/std/reserve{s}/live1024/8x", .{reserve}),
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
    prepareSparseClear(sparse_clear_small, 64);
}

fn prepareStdSmall64() void {
    prepareStdClear(std_clear_small, 64);
}

fn prepareSparseSmall1024() void {
    prepareSparseClear(sparse_clear_small, 1024);
}

fn prepareStdSmall1024() void {
    prepareStdClear(std_clear_small, 1024);
}

fn prepareSparseBroad64() void {
    prepareSparseClear(sparse_clear_broad, 64);
}

fn prepareStdBroad64() void {
    prepareStdClear(std_clear_broad, 64);
}

fn prepareSparseBroad1024() void {
    prepareSparseClear(sparse_clear_broad, 1024);
}

fn prepareStdBroad1024() void {
    prepareStdClear(std_clear_broad, 1024);
}

fn prepareSparseClear(maps: []SparseStorageSlotMap, live: usize) void {
    for (maps) |*map| {
        std.debug.assert(map.count() == 0);
        fillStorageSlotMap(map, clear_storage_keys[0..live]);
    }
}

fn prepareStdClear(maps: []StdStorageSlotMap, live: usize) void {
    for (maps) |*map| {
        std.debug.assert(map.count() == 0);
        fillStorageSlotMap(map, clear_storage_keys[0..live]);
    }
}
