const std = @import("std");
const evmz = @import("evmz");

pub const Address = evmz.Address;
pub const Host = evmz.Host;

pub const caller_address = evmz.addr(0x1000000000000000000000000000000000000001);
pub const contract_address = evmz.addr(0x2000000000000000000000000000000000000002);
pub const max_gas = std.math.maxInt(i64);
pub const allocator_env_var = "EVMZ_BENCH_ALLOCATOR";

pub const HostProfile = enum {
    null,
    mock,
};

pub fn benchmarkAllocator(init: std.process.Init) !std.mem.Allocator {
    const value = init.environ_map.get(allocator_env_var) orelse return init.gpa;
    if (std.mem.eql(u8, value, "gpa")) return init.gpa;
    if (std.mem.eql(u8, value, "smp")) return std.heap.smp_allocator;
    return error.InvalidAllocator;
}

const StorageKey = struct {
    address: Address,
    key: u256,
};

pub const HostCounters = struct {
    account_exists: u64 = 0,
    balance: u64 = 0,
    code_size: u64 = 0,
    code_hash: u64 = 0,
    copy_code: u64 = 0,
    storage_read: u64 = 0,
    storage_write: u64 = 0,
    log: u64 = 0,
    block_hash: u64 = 0,
    tx_context: u64 = 0,
    access_account: u64 = 0,
    access_storage: u64 = 0,
    access_delegated_account: u64 = 0,
    call: u64 = 0,
    selfdestruct: u64 = 0,
    transient_read: u64 = 0,
    transient_write: u64 = 0,

    pub fn total(self: HostCounters) u64 {
        var sum: u64 = 0;
        inline for (std.meta.fields(HostCounters)) |field| {
            sum += @field(self, field.name);
        }
        return sum;
    }

    pub fn add(self: *HostCounters, other: HostCounters) void {
        inline for (std.meta.fields(HostCounters)) |field| {
            @field(self, field.name) += @field(other, field.name);
        }
    }

    pub fn print(self: HostCounters, label: []const u8) void {
        inline for (std.meta.fields(HostCounters)) |field| {
            const value = @field(self, field.name);
            if (value != 0) std.debug.print("{s}.{s}={d}\n", .{ label, field.name, value });
        }
    }
};

pub const CountingHost = struct {
    allocator: std.mem.Allocator,
    profile: HostProfile,
    storage: std.AutoHashMap(StorageKey, u256),
    counters: HostCounters = .{},
    tx_context: Host.TxContext,

    pub fn init(allocator: std.mem.Allocator, profile: HostProfile) CountingHost {
        return .{
            .allocator = allocator,
            .profile = profile,
            .storage = std.AutoHashMap(StorageKey, u256).init(allocator),
            .tx_context = .{
                .chain_id = 1,
                .gas_price = 0,
                .origin = caller_address,
                .coinbase = evmz.addr(0),
                .number = 0,
                .timestamp = 0,
                .gas_limit = @intCast(max_gas),
                .prev_randao = 0,
                .base_fee = 0,
                .blob_base_fee = 0,
                .blob_hashes = &.{},
            },
        };
    }

    pub fn deinit(self: *CountingHost) void {
        self.storage.deinit();
    }

    pub fn resetCounters(self: *CountingHost) void {
        self.counters = .{};
    }

    pub fn seedStorage(self: *CountingHost, address: Address, key: u256, value: u256) !void {
        try self.storage.put(.{ .address = address, .key = key }, value);
    }

    pub fn host(self: *CountingHost) Host {
        return .{ .ptr = self, .vtable = &.{
            .accountExists = accountExists,
            .getBalance = getBalance,
            .copyCode = copyCode,
            .getCodeSize = getCodeSize,
            .getCodeHash = getCodeHash,
            .getStorage = getStorage,
            .setStorage = setStorage,
            .emitLog = emitLog,
            .getBlockHash = getBlockHash,
            .selfDestruct = selfDestruct,
            .accessStorage = accessStorage,
            .accessDelegatedAccount = accessDelegatedAccount,
            .accessAccount = accessAccount,
            .getTxContext = getTxContext,
            .call = call,
            .getTransientStorage = getTransientStorage,
            .setTransientStorage = setTransientStorage,
        } };
    }

    noinline fn accountExists(ptr: *anyopaque, address: Address) !bool {
        const self: *CountingHost = @ptrCast(@alignCast(ptr));
        _ = address;
        self.counters.account_exists += 1;
        return false;
    }

    noinline fn getBalance(ptr: *anyopaque, address: Address) !u256 {
        const self: *CountingHost = @ptrCast(@alignCast(ptr));
        _ = address;
        self.counters.balance += 1;
        return 0;
    }

    noinline fn copyCode(ptr: *anyopaque, address: Address, code_offset: usize, buffer_data: []u8) !usize {
        const self: *CountingHost = @ptrCast(@alignCast(ptr));
        _ = address;
        _ = code_offset;
        _ = buffer_data;
        self.counters.copy_code += 1;
        return 0;
    }

    noinline fn getCodeSize(ptr: *anyopaque, address: Address) !u256 {
        const self: *CountingHost = @ptrCast(@alignCast(ptr));
        _ = address;
        self.counters.code_size += 1;
        return 0;
    }

    noinline fn getCodeHash(ptr: *anyopaque, address: Address) !u256 {
        const self: *CountingHost = @ptrCast(@alignCast(ptr));
        _ = address;
        self.counters.code_hash += 1;
        return 0;
    }

    noinline fn getStorage(ptr: *anyopaque, address: Address, key: u256) !u256 {
        const self: *CountingHost = @ptrCast(@alignCast(ptr));
        self.counters.storage_read += 1;
        return self.storage.get(.{ .address = address, .key = key }) orelse 0;
    }

    noinline fn setStorage(ptr: *anyopaque, address: Address, key: u256, value: u256) !Host.StorageStatus {
        const self: *CountingHost = @ptrCast(@alignCast(ptr));
        self.counters.storage_write += 1;

        const storage_key = StorageKey{ .address = address, .key = key };
        const stored = self.storage.get(storage_key);
        const previous = stored orelse 0;
        if (previous == value) {
            if (stored == null) try self.storage.put(storage_key, value);
            return .assigned;
        }
        try self.storage.put(storage_key, value);
        if (previous == 0 and value != 0) return .added;
        if (previous != 0 and value == 0) return .deleted;
        return .modified;
    }

    noinline fn emitLog(ptr: *anyopaque, address: Address, topics: []const u256, data: []const u8) !void {
        const self: *CountingHost = @ptrCast(@alignCast(ptr));
        _ = address;
        _ = topics;
        _ = data;
        self.counters.log += 1;
    }

    noinline fn getBlockHash(ptr: *anyopaque, number: u256) !u256 {
        const self: *CountingHost = @ptrCast(@alignCast(ptr));
        _ = number;
        self.counters.block_hash += 1;
        return 0;
    }

    noinline fn getTxContext(ptr: *anyopaque) !Host.TxContext {
        const self: *CountingHost = @ptrCast(@alignCast(ptr));
        self.counters.tx_context += 1;
        return self.tx_context;
    }

    noinline fn accessAccount(ptr: *anyopaque, address: Address) !Host.AccessStatus {
        const self: *CountingHost = @ptrCast(@alignCast(ptr));
        _ = address;
        self.counters.access_account += 1;
        return .cold;
    }

    noinline fn accessStorage(ptr: *anyopaque, address: Address, key: u256) !Host.AccessStatus {
        const self: *CountingHost = @ptrCast(@alignCast(ptr));
        self.counters.access_storage += 1;
        return if (self.storage.contains(.{ .address = address, .key = key })) .warm else .cold;
    }

    noinline fn accessDelegatedAccount(ptr: *anyopaque, address: Address) !?Host.AccessStatus {
        const self: *CountingHost = @ptrCast(@alignCast(ptr));
        _ = address;
        self.counters.access_delegated_account += 1;
        return null;
    }

    noinline fn call(ptr: *anyopaque, msg: Host.Message) !Host.Result {
        const self: *CountingHost = @ptrCast(@alignCast(ptr));
        self.counters.call += 1;
        return Host.Result.fromCall(.{
            .status = .success,
            .gas_left = msg.gas,
            .gas_refund = 0,
            .output_data = &.{},
        });
    }

    noinline fn selfDestruct(ptr: *anyopaque, address: Address, beneficiary: Address) !bool {
        const self: *CountingHost = @ptrCast(@alignCast(ptr));
        _ = address;
        _ = beneficiary;
        self.counters.selfdestruct += 1;
        return false;
    }

    noinline fn getTransientStorage(ptr: *anyopaque, address: Address, key: u256) !u256 {
        const self: *CountingHost = @ptrCast(@alignCast(ptr));
        _ = address;
        _ = key;
        self.counters.transient_read += 1;
        return 0;
    }

    noinline fn setTransientStorage(ptr: *anyopaque, address: Address, key: u256, value: u256) !void {
        const self: *CountingHost = @ptrCast(@alignCast(ptr));
        _ = address;
        _ = key;
        _ = value;
        self.counters.transient_write += 1;
    }
};

test "counting host classifies same-value storage writes as assigned" {
    var counting_host = CountingHost.init(std.testing.allocator, .mock);
    defer counting_host.deinit();
    var host = counting_host.host();

    try std.testing.expectEqual(Host.StorageStatus.assigned, try host.setStorage(contract_address, 0, 0));
    try std.testing.expectEqual(Host.StorageStatus.added, try host.setStorage(contract_address, 0, 1));
    try std.testing.expectEqual(Host.StorageStatus.assigned, try host.setStorage(contract_address, 0, 1));
    try std.testing.expectEqual(Host.StorageStatus.deleted, try host.setStorage(contract_address, 0, 0));
    try std.testing.expectEqual(Host.StorageStatus.assigned, try host.setStorage(contract_address, 0, 0));
}

pub fn monotonicNowNs() !u64 {
    var ts: std.posix.timespec = undefined;
    switch (std.posix.errno(std.posix.system.clock_gettime(std.posix.CLOCK.MONOTONIC, &ts))) {
        .SUCCESS => return @intCast(@as(i128, ts.sec) * std.time.ns_per_s + ts.nsec),
        else => return error.ClockUnavailable,
    }
}

pub fn rejectNullHostTouches(profile: HostProfile, counters: HostCounters) !void {
    if (profile == .null and counters.total() != 0) return error.NullHostTouched;
}

pub fn decodeHexAlloc(allocator: std.mem.Allocator, source: []const u8) ![]u8 {
    const trimmed = std.mem.trim(u8, source, " \t\r\n");
    const hex = if (std.mem.startsWith(u8, trimmed, "0x") or std.mem.startsWith(u8, trimmed, "0X"))
        trimmed[2..]
    else
        trimmed;
    if (hex.len % 2 != 0) return error.InvalidHexLength;

    const bytes = try allocator.alloc(u8, hex.len / 2);
    errdefer allocator.free(bytes);
    _ = try std.fmt.hexToBytes(bytes, hex);
    return bytes;
}

pub fn stripPrefix(value: []const u8, prefix: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, value, prefix)) return null;
    return value[prefix.len..];
}

pub fn parseNonZeroUsize(value: []const u8) !usize {
    const parsed = try std.fmt.parseUnsigned(usize, value, 10);
    if (parsed == 0) return error.InvalidNumber;
    return parsed;
}

pub fn parseHostProfile(value: []const u8) ?HostProfile {
    inline for (std.meta.fields(HostProfile)) |field| {
        if (std.mem.eql(u8, value, field.name)) return @enumFromInt(field.value);
    }
    return null;
}

pub fn parseSpec(value: []const u8) ?evmz.Spec {
    inline for (std.meta.fields(evmz.Spec)) |field| {
        if (std.mem.eql(u8, value, field.name)) return @enumFromInt(field.value);
    }
    if (std.mem.eql(u8, value, "latest")) return .latest;
    return null;
}

test "decode hex accepts optional prefix and whitespace" {
    const bytes = try decodeHexAlloc(std.testing.allocator, "  0x6000\n");
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqualSlices(u8, &.{ 0x60, 0x00 }, bytes);
}

test "host counters sum fields" {
    const counters = HostCounters{ .storage_read = 2, .storage_write = 3 };
    try std.testing.expectEqual(@as(u64, 5), counters.total());
}
