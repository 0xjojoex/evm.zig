const std = @import("std");
const evmz = @import("evmz");
const common = @import("common.zig");

const Engine = evmz.Evm;
const MemoryStore = evmz.state.MemoryStore;

const sender_address = evmz.addr(0x1000000000000000000000000000000000000001);
const contract_address = evmz.addr(0x2000000000000000000000000000000000000002);

const Options = struct {
    policy: Policy = .growable,
    case: Case = .sstore_unique,
    spec: evmz.eth.Revision = .amsterdam,
    repeats: usize = 5,
    warmups: usize = 1,
    txs: usize = 1000,
    tx_gas_limit: u64 = 300_000,
    block_gas_limit: u64 = 120_000_000,
    access_list_addresses: usize = 0,
    access_list_storage_keys: usize = 0,
    commit: bool = true,
    summary: bool = false,
};

const Policy = enum {
    growable,
    exact_1m,
    exact_10m,
    exact_30m,
    exact_60m,
    exact_100m,
    exact_120m,
};

const Case = enum {
    noop,
    sstore_same,
    sstore_unique,
};

const RunResult = struct {
    elapsed_ns: u64,
    gas_used: u64,
    block_gas_used: u64,
    tx_count: u64,
};

const PreparedAccessList = struct {
    entries: []evmz.transaction.AccessListEntry = &.{},
    storage_keys: []u256 = &.{},

    pub fn deinit(self: *PreparedAccessList, allocator: std.mem.Allocator) void {
        allocator.free(self.entries);
        allocator.free(self.storage_keys);
        self.* = .{};
    }
};

pub fn main(init: std.process.Init) !void {
    const allocator = try common.benchmarkAllocator(init);

    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, allocator);
    defer args.deinit();
    _ = args.next();

    var options = Options{};
    while (args.next()) |arg_z| {
        const arg = arg_z[0..arg_z.len];
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            printUsage();
            return;
        } else if (std.mem.eql(u8, arg, "--policy")) {
            const value = args.next() orelse return error.MissingPolicy;
            options.policy = parsePolicy(value) orelse return error.InvalidPolicy;
        } else if (common.stripPrefix(arg, "--policy=")) |value| {
            options.policy = parsePolicy(value) orelse return error.InvalidPolicy;
        } else if (std.mem.eql(u8, arg, "--case")) {
            const value = args.next() orelse return error.MissingCase;
            options.case = parseCase(value) orelse return error.InvalidCase;
        } else if (common.stripPrefix(arg, "--case=")) |value| {
            options.case = parseCase(value) orelse return error.InvalidCase;
        } else if (std.mem.eql(u8, arg, "--spec")) {
            const value = args.next() orelse return error.MissingSpec;
            options.spec = common.parseSpec(value) orelse return error.InvalidSpec;
        } else if (common.stripPrefix(arg, "--spec=")) |value| {
            options.spec = common.parseSpec(value) orelse return error.InvalidSpec;
        } else if (std.mem.eql(u8, arg, "--repeats")) {
            const value = args.next() orelse return error.MissingRepeats;
            options.repeats = try common.parseNonZeroUsize(value);
        } else if (common.stripPrefix(arg, "--repeats=")) |value| {
            options.repeats = try common.parseNonZeroUsize(value);
        } else if (std.mem.eql(u8, arg, "--warmups")) {
            const value = args.next() orelse return error.MissingWarmups;
            options.warmups = try parseUsize(value);
        } else if (common.stripPrefix(arg, "--warmups=")) |value| {
            options.warmups = try parseUsize(value);
        } else if (std.mem.eql(u8, arg, "--txs")) {
            const value = args.next() orelse return error.MissingTxs;
            options.txs = try common.parseNonZeroUsize(value);
        } else if (common.stripPrefix(arg, "--txs=")) |value| {
            options.txs = try common.parseNonZeroUsize(value);
        } else if (std.mem.eql(u8, arg, "--tx-gas-limit")) {
            const value = args.next() orelse return error.MissingTxGasLimit;
            options.tx_gas_limit = try parseNonZeroU64(value);
        } else if (common.stripPrefix(arg, "--tx-gas-limit=")) |value| {
            options.tx_gas_limit = try parseNonZeroU64(value);
        } else if (std.mem.eql(u8, arg, "--block-gas-limit")) {
            const value = args.next() orelse return error.MissingBlockGasLimit;
            options.block_gas_limit = try parseNonZeroU64(value);
        } else if (common.stripPrefix(arg, "--block-gas-limit=")) |value| {
            options.block_gas_limit = try parseNonZeroU64(value);
        } else if (std.mem.eql(u8, arg, "--access-list-addresses")) {
            const value = args.next() orelse return error.MissingAccessListAddresses;
            options.access_list_addresses = try parseUsize(value);
        } else if (common.stripPrefix(arg, "--access-list-addresses=")) |value| {
            options.access_list_addresses = try parseUsize(value);
        } else if (std.mem.eql(u8, arg, "--access-list-storage-keys")) {
            const value = args.next() orelse return error.MissingAccessListStorageKeys;
            options.access_list_storage_keys = try parseUsize(value);
        } else if (common.stripPrefix(arg, "--access-list-storage-keys=")) |value| {
            options.access_list_storage_keys = try parseUsize(value);
        } else if (std.mem.eql(u8, arg, "--no-commit")) {
            options.commit = false;
        } else if (std.mem.eql(u8, arg, "--summary")) {
            options.summary = true;
        } else {
            return error.UnknownArgument;
        }
    }

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(init.io, &stdout_buffer);
    const stdout = &stdout_writer.interface;

    var warmup: usize = 0;
    while (warmup < options.warmups) : (warmup += 1) {
        _ = try runPolicy(allocator, options);
    }

    try stdout.print("suite,policy,case,spec,repeat,txs,access_list_addresses,access_list_storage_keys,elapsed_ns,ns_per_tx,gas_used,block_gas_used,tx_count,commit\n", .{});
    var repeat: usize = 0;
    while (repeat < options.repeats) : (repeat += 1) {
        const result = try runPolicy(allocator, options);
        const ns_per_tx = @as(f64, @floatFromInt(result.elapsed_ns)) / @as(f64, @floatFromInt(options.txs));
        try stdout.print(
            "block-lifecycle,{s},{s},{s},{d},{d},{d},{d},{d},{d:.3},{d},{d},{d},{s}\n",
            .{
                policyName(options.policy),
                caseName(options.case),
                @tagName(options.spec),
                repeat,
                options.txs,
                options.access_list_addresses,
                options.access_list_storage_keys,
                result.elapsed_ns,
                ns_per_tx,
                result.gas_used,
                result.block_gas_used,
                result.tx_count,
                if (options.commit) "true" else "false",
            },
        );
    }
    try stdout.flush();

    if (options.summary) {
        const gas_limit = switch (options.policy) {
            .growable => options.block_gas_limit,
            else => exactPolicyGasLimit(options.policy),
        };
        std.debug.print(
            "policy={s} case={s} spec={s} warmups={d} repeats={d} txs={d} tx_gas_limit={d} block_gas_limit={d} access_list_addresses={d} access_list_storage_keys={d} commit={s}\n",
            .{
                policyName(options.policy),
                caseName(options.case),
                @tagName(options.spec),
                options.warmups,
                options.repeats,
                options.txs,
                options.tx_gas_limit,
                gas_limit,
                options.access_list_addresses,
                options.access_list_storage_keys,
                if (options.commit) "true" else "false",
            },
        );
    }
}

fn runPolicy(allocator: std.mem.Allocator, options: Options) !RunResult {
    return switch (options.policy) {
        .growable => try runGrowableLifecycle(allocator, options),
        .exact_1m => try runExactLifecycle(allocator, options, 1_000_000),
        .exact_10m => try runExactLifecycle(allocator, options, 10_000_000),
        .exact_30m => try runExactLifecycle(allocator, options, 30_000_000),
        .exact_60m => try runExactLifecycle(allocator, options, 60_000_000),
        .exact_100m => try runExactLifecycle(allocator, options, 100_000_000),
        .exact_120m => try runExactLifecycle(allocator, options, 120_000_000),
    };
}

fn runGrowableLifecycle(allocator: std.mem.Allocator, options: Options) !RunResult {
    var memory = MemoryStore.init(allocator);
    defer memory.deinit();
    try seedState(&memory, options.case);
    var access_list = try prepareAccessList(allocator, options);
    defer access_list.deinit(allocator);

    const start_ns = try common.monotonicNowNs();
    var executor = Engine.Executor.init(allocator, .{
        .revision = options.spec,
        .state_reader = memory.reader(),
    });
    errdefer executor.deinit();

    var block = try Engine.BlockExecution.init(
        &executor,
        growableEnv(options.block_gas_limit),
    );
    defer block.discardIfUnfinished();
    const block_result = try runTransactions(&block, options, access_list.entries);
    if (options.commit) try commitChanges(&executor, &memory);
    executor.deinit();
    const end_ns = try common.monotonicNowNs();

    return .{
        .elapsed_ns = end_ns - start_ns,
        .gas_used = block_result.gas_used,
        .block_gas_used = block_result.block_gas.total,
        .tx_count = block_result.tx_count,
    };
}

fn runExactLifecycle(
    allocator: std.mem.Allocator,
    options: Options,
    gas_limit: u64,
) !RunResult {
    var memory = MemoryStore.init(allocator);
    defer memory.deinit();
    try seedState(&memory, options.case);
    var access_list = try prepareAccessList(allocator, options);
    defer access_list.deinit(allocator);

    const start_ns = try common.monotonicNowNs();
    var executor = try Engine.initBoundExecutor(allocator, .{
        .revision = options.spec,
        .state_reader = memory.reader(),
    }, .{
        .max_block_gas = gas_limit,
    });
    errdefer executor.deinit();

    var block = try Engine.BlockExecution.init(
        &executor,
        growableEnv(gas_limit),
    );
    defer block.discardIfUnfinished();
    const block_result = try runTransactions(&block, options, access_list.entries);
    if (options.commit) try commitChanges(&executor, &memory);
    executor.deinit();
    const end_ns = try common.monotonicNowNs();

    return .{
        .elapsed_ns = end_ns - start_ns,
        .gas_used = block_result.gas_used,
        .block_gas_used = block_result.block_gas.total,
        .tx_count = block_result.tx_count,
    };
}

fn commitChanges(executor: *Engine.Executor, memory: *MemoryStore) !void {
    var changes = try executor.changeset();
    defer changes.deinit(executor.allocator);
    try memory.committer().commit(&changes);
    executor.discardChanges();
}

fn seedState(memory: *MemoryStore, case: Case) !void {
    var sender = try memory.getOrCreateAccount(sender_address);
    sender.balance = std.math.maxInt(u256);

    var contract = try memory.getOrCreateAccount(contract_address);
    try contract.setCode(contractCode(case));
}

fn prepareAccessList(allocator: std.mem.Allocator, options: Options) !PreparedAccessList {
    const address_entries = options.access_list_addresses;
    const storage_keys = options.access_list_storage_keys;
    const entry_count: usize = if (address_entries != 0)
        address_entries
    else if (storage_keys != 0)
        1
    else
        0;
    if (entry_count == 0) return .{};

    const entries = try allocator.alloc(evmz.transaction.AccessListEntry, entry_count);
    errdefer allocator.free(entries);
    const keys = try allocator.alloc(u256, storage_keys);
    errdefer allocator.free(keys);

    for (keys, 0..) |*key, index| {
        key.* = @as(u256, @intCast(index + 1));
    }

    var key_offset: usize = 0;
    for (entries, 0..) |*entry, index| {
        const key_count = storageKeysForEntry(storage_keys, entry_count, index);
        const address = if (address_entries == 0)
            contract_address
        else
            syntheticAccessListAddress(index);
        entry.* = .{
            .address = address,
            .storage_keys = keys[key_offset .. key_offset + key_count],
        };
        key_offset += key_count;
    }

    return .{
        .entries = entries,
        .storage_keys = keys,
    };
}

fn storageKeysForEntry(total_keys: usize, entry_count: usize, index: usize) usize {
    if (entry_count == 0) return 0;
    const base = total_keys / entry_count;
    const remainder = total_keys % entry_count;
    return base + @intFromBool(index < remainder);
}

fn syntheticAccessListAddress(index: usize) evmz.Address {
    var address = [_]u8{0} ** 20;
    address[0] = 0xaa;
    var value: u64 = @intCast(index + 1);
    var i: usize = 0;
    while (i < 8) : (i += 1) {
        address[19 - i] = @intCast(value & 0xff);
        value >>= 8;
    }
    return address;
}

fn runTransactions(block: anytype, options: Options, access_list: []const evmz.transaction.AccessListEntry) !evmz.vm.BlockResult {
    var tx_input: [32]u8 = undefined;
    var index: usize = 0;
    while (index < options.txs) : (index += 1) {
        const input = txInput(options.case, index, &tx_input);
        const result = try block.transact(.{
            .sender = sender_address,
            .nonce = @intCast(index),
            .to = contract_address,
            .gas_limit = options.tx_gas_limit,
            .input = input,
            .access_list = access_list,
        });
        switch (result) {
            .included => |included| {
                if (included.result.status != .success) {
                    std.debug.print("tx_index={d} status={s}\n", .{ index, @tagName(included.result.status) });
                    return error.TransactionFailed;
                }
            },
            .rejected => |err| {
                std.debug.print("tx_index={d} validation_error={s}\n", .{ index, @tagName(err) });
                return error.TransactionFailed;
            },
        }
    }
    return block.finish();
}

fn contractCode(case: Case) []const u8 {
    return switch (case) {
        .noop => &.{0x00},
        .sstore_same => &.{ 0x60, 0x2a, 0x60, 0x00, 0x55, 0x00 },
        .sstore_unique => &.{ 0x60, 0x01, 0x60, 0x00, 0x35, 0x55, 0x00 },
    };
}

fn txInput(case: Case, index: usize, buffer: *[32]u8) []const u8 {
    if (case != .sstore_unique) return &.{};

    @memset(buffer, 0);
    var value: u64 = @intCast(index + 1);
    var i: usize = 0;
    while (i < 8) : (i += 1) {
        buffer[31 - i] = @intCast(value & 0xff);
        value >>= 8;
    }
    return buffer;
}

fn growableEnv(block_gas_limit: u64) evmz.Env {
    return .{
        .gas_limit = block_gas_limit,
    };
}

fn parsePolicy(value: []const u8) ?Policy {
    inline for (std.meta.fields(Policy)) |field| {
        if (tagNameMatches(value, field.name)) return @enumFromInt(field.value);
    }
    return null;
}

fn parseCase(value: []const u8) ?Case {
    inline for (std.meta.fields(Case)) |field| {
        if (tagNameMatches(value, field.name)) return @enumFromInt(field.value);
    }
    return null;
}

fn policyName(policy: Policy) []const u8 {
    return switch (policy) {
        .growable => "growable",
        .exact_1m => "exact-1m",
        .exact_10m => "exact-10m",
        .exact_30m => "exact-30m",
        .exact_60m => "exact-60m",
        .exact_100m => "exact-100m",
        .exact_120m => "exact-120m",
    };
}

fn caseName(case: Case) []const u8 {
    return switch (case) {
        .noop => "noop",
        .sstore_same => "sstore-same",
        .sstore_unique => "sstore-unique",
    };
}

fn exactPolicyGasLimit(policy: Policy) u64 {
    return switch (policy) {
        .growable => unreachable,
        .exact_1m => 1_000_000,
        .exact_10m => 10_000_000,
        .exact_30m => 30_000_000,
        .exact_60m => 60_000_000,
        .exact_100m => 100_000_000,
        .exact_120m => 120_000_000,
    };
}

fn tagNameMatches(value: []const u8, tag_name: []const u8) bool {
    if (value.len != tag_name.len) return false;
    for (value, tag_name) |lhs, rhs| {
        if (lhs == rhs) continue;
        if (lhs == '-' and rhs == '_') continue;
        return false;
    }
    return true;
}

fn parseNonZeroU64(value: []const u8) !u64 {
    const parsed = try std.fmt.parseUnsigned(u64, value, 10);
    if (parsed == 0) return error.InvalidNumber;
    return parsed;
}

fn parseUsize(value: []const u8) !usize {
    return try std.fmt.parseUnsigned(usize, value, 10);
}

fn printUsage() void {
    std.debug.print(
        \\Usage:
        \\  zig build block-lifecycle -- [options]
        \\
        \\Options:
        \\  --policy <name>              growable, exact-1m, exact-10m, exact-30m, exact-60m, exact-100m, exact-120m
        \\  --case <name>                noop, sstore-same, sstore-unique; default sstore-unique
        \\  --spec <name>                fork spec, default amsterdam
        \\  --repeats <n>                measured repeats, default 5
        \\  --warmups <n>                untimed warmups, default 1
        \\  --txs <n>                    transactions in one block, default 1000
        \\  --tx-gas-limit <n>           transaction gas limit, default 300000
        \\  --block-gas-limit <n>        growable block gas limit, default 120000000
        \\  --access-list-addresses <n>  synthetic access-list address entries per tx, default 0
        \\  --access-list-storage-keys <n> synthetic storage keys spread across entries, default 0
        \\  --no-commit                  skip final changeset persistence
        \\  --summary                    print resolved options to stderr
        \\  EVMZ_BENCH_ALLOCATOR=smp     opt into std.heap.smp_allocator for allocator probes
        \\
        \\This runner times one execution lifecycle per repeat: seeded pre-state outside timing,
        \\then Executor init, BlockExecution tx loop, optional persistence, and Executor deinit.
        \\
    , .{});
}

test "block lifecycle parser accepts dashed names" {
    try std.testing.expectEqual(Policy.exact_120m, parsePolicy("exact-120m").?);
    try std.testing.expectEqual(Case.sstore_unique, parseCase("sstore-unique").?);
}

test "block lifecycle unique calldata encodes tx index" {
    var buffer: [32]u8 = undefined;
    const input = txInput(.sstore_unique, 41, &buffer);
    try std.testing.expectEqual(@as(usize, 32), input.len);
    try std.testing.expectEqual(@as(u8, 42), input[31]);
}

test "block lifecycle prepares synthetic access list" {
    var access_list = try prepareAccessList(std.testing.allocator, .{
        .access_list_addresses = 3,
        .access_list_storage_keys = 8,
    });
    defer access_list.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 3), access_list.entries.len);
    try std.testing.expectEqual(@as(usize, 8), access_list.storage_keys.len);
    try std.testing.expectEqual(@as(usize, 3), access_list.entries[0].storage_keys.len);
    try std.testing.expectEqual(@as(usize, 3), access_list.entries[1].storage_keys.len);
    try std.testing.expectEqual(@as(usize, 2), access_list.entries[2].storage_keys.len);
    try std.testing.expectEqual(@as(u256, 1), access_list.entries[0].storage_keys[0]);
    try std.testing.expectEqual(@as(u256, 8), access_list.entries[2].storage_keys[1]);
}

test "block lifecycle storage-only access list uses contract entry" {
    var access_list = try prepareAccessList(std.testing.allocator, .{
        .access_list_storage_keys = 2,
    });
    defer access_list.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), access_list.entries.len);
    try std.testing.expectEqualSlices(u8, &contract_address, &access_list.entries[0].address);
    try std.testing.expectEqual(@as(usize, 2), access_list.entries[0].storage_keys.len);
}
