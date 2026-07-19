//! Executor-owned execution overlay for a transaction or nested call.
//!
//! `StateReader` provides canonical reads. `Overlay` owns loaded accounts, writes,
//! warm access state, transient storage, logs, snapshots, reverts, and the
//! execution journal.

const std = @import("std");
const evmz = @import("../evm.zig");
const Host = @import("../Host.zig");
const trace = @import("../trace.zig");
const capture_runtime = @import("../executor/capture_context.zig");
const CaptureContext = capture_runtime.Context;
const Address = evmz.Address;
const Account = @import("./Account.zig");
const MemoryAccount = @import("./MemoryAccount.zig");
const storage = @import("./storage.zig");
const StorageKey = storage.Key;
const StateReader = @import("./Reader.zig");
const Changeset = @import("./Changeset.zig");
const Journal = @import("./Journal.zig");
const SparseHashMap = @import("./sparse_hash_map.zig").Auto;

const Overlay = @This();
const AccountMap = SparseHashMap(Address, Account);
const CodeEntry = struct {
    bytes: []const u8,
    owned: bool,
    introduced: bool,
};
const CodeMap = SparseHashMap([32]u8, CodeEntry);
const AddressSet = SparseHashMap(Address, void);
const StorageMap = SparseHashMap(StorageKey, u256);
/// Transaction-local fused storage view. During a transaction this is the
/// authoritative value path; dirty slots fold into `storage_overlay` when the
/// transaction closes.
const StorageSlot = struct {
    original: u256 = 0,
    current: u256 = 0,
    loaded: bool = false,
    warm: bool = false,
    dirty: bool = false,
    overlay_present: bool = false,
    original_recorded: bool = false,
};
const StorageSlotMap = SparseHashMap(StorageKey, StorageSlot);
const StorageSlotAccess = struct {
    slot: *StorageSlot,
    access_status: Host.AccessStatus,
};
const TransientStorageMap = SparseHashMap(StorageKey, u256);

pub const LogResources = struct {
    entries: usize,
    data_bytes: usize,
};

pub const AccessResources = struct {
    accounts: usize,
    storage_keys: usize,
};

pub const StateResources = struct {
    accounts: usize = 0,
    /// Optional because BAL bounds code changes, but not pre-state code bytes
    /// loaded while executing calls.
    code_entries: ?usize = null,
    code_bytes: ?usize = null,
    original_storage_entries: usize = 0,
    storage_overlay_entries: usize = 0,
    selfdestructed_accounts: usize = 0,
    created_contracts: usize = 0,
    deleted_accounts: usize = 0,
    dirty_accounts: usize = 0,
};

/// Canonical code resolved by the overlay for execution.
///
/// `bytes` is borrowed from overlay state and hashes to `code_hash`. The empty
/// view uses Ethereum's empty-code hash, including for an absent account.
pub const CodeView = struct {
    code_hash: [32]u8,
    bytes: []const u8,
};

allocator: std.mem.Allocator,
state_reader: ?StateReader,
accounts: AccountMap,
code_cache: CodeMap,
bounded_code_data: std.ArrayList(u8),
code_bytes_used: usize,
seeded_storage: StorageMap,
state_resources: ?StateResources,
warm_accounts: AddressSet,
storage_slots: StorageSlotMap,
warm_storage_count: usize,
original_storage_count: usize,
pending_storage_overlay_entries: usize,
access_resources: ?AccessResources,
storage_overlay: StorageMap,
transient_storage: TransientStorageMap,
transient_storage_entries: ?usize,
selfdestructed_accounts: AddressSet,
created_contracts: AddressSet,
deleted_accounts: AddressSet,
dirty_accounts: AddressSet,
logs: std.ArrayList(Host.Log),
bounded_log_topics: std.ArrayList([4]u256),
bounded_log_data: std.ArrayList(u8),
log_resources: ?LogResources,
journal: Journal,
transaction_open: bool,
capture_context: ?*CaptureContext,
trace_depth: u16,

pub fn init(allocator: std.mem.Allocator) Overlay {
    return .{
        .allocator = allocator,
        .state_reader = null,
        .accounts = AccountMap.init(allocator),
        .code_cache = CodeMap.init(allocator),
        .bounded_code_data = .empty,
        .code_bytes_used = 0,
        .seeded_storage = StorageMap.init(allocator),
        .state_resources = null,
        .warm_accounts = AddressSet.init(allocator),
        .storage_slots = StorageSlotMap.init(allocator),
        .warm_storage_count = 0,
        .original_storage_count = 0,
        .pending_storage_overlay_entries = 0,
        .access_resources = null,
        .storage_overlay = StorageMap.init(allocator),
        .transient_storage = TransientStorageMap.init(allocator),
        .transient_storage_entries = null,
        .selfdestructed_accounts = AddressSet.init(allocator),
        .created_contracts = AddressSet.init(allocator),
        .deleted_accounts = AddressSet.init(allocator),
        .dirty_accounts = AddressSet.init(allocator),
        .logs = .empty,
        .bounded_log_topics = .empty,
        .bounded_log_data = .empty,
        .log_resources = null,
        .journal = Journal.init(),
        .transaction_open = false,
        .capture_context = null,
        .trace_depth = 0,
    };
}

pub fn initWithStateReader(allocator: std.mem.Allocator, state_reader: StateReader) Overlay {
    var result = Overlay.init(allocator);
    result.state_reader = state_reader;
    return result;
}

/// Clear all semantic overlay state while keeping configured backing capacity.
pub fn reset(self: *Overlay, state_reader: ?StateReader) void {
    self.discardChanges();
    self.state_reader = state_reader;
    self.trace_depth = 0;
}

pub fn deinit(self: *Overlay) void {
    self.clearLogsRetainingCapacity();
    self.clearAccounts();
    self.accounts.deinit();
    self.clearCodeCache();
    self.code_cache.deinit();
    self.bounded_code_data.deinit(self.allocator);
    self.seeded_storage.deinit();
    self.warm_accounts.deinit();
    self.storage_slots.deinit();
    self.storage_overlay.deinit();
    self.transient_storage.deinit();
    self.selfdestructed_accounts.deinit();
    self.created_contracts.deinit();
    self.deleted_accounts.deinit();
    self.dirty_accounts.deinit();
    self.logs.deinit(self.allocator);
    self.bounded_log_topics.deinit(self.allocator);
    self.bounded_log_data.deinit(self.allocator);
    self.journal.deinit(self.allocator);
}

pub fn configureLogResources(self: *Overlay, resources: ?LogResources) !void {
    if (self.logs.items.len != 0) return error.ActiveLogs;
    self.clearLogsRetainingCapacity();

    if (resources) |bounded| {
        try self.logs.ensureTotalCapacityPrecise(self.allocator, bounded.entries);
        try self.bounded_log_topics.ensureTotalCapacityPrecise(self.allocator, bounded.entries);
        try self.bounded_log_data.ensureTotalCapacityPrecise(self.allocator, bounded.data_bytes);
        self.log_resources = bounded;
    } else {
        self.log_resources = null;
        self.bounded_log_topics.deinit(self.allocator);
        self.bounded_log_data.deinit(self.allocator);
        self.bounded_log_topics = .empty;
        self.bounded_log_data = .empty;
    }
}

pub fn configureJournalEntries(self: *Overlay, entries: ?usize) !void {
    try self.journal.configureCapacity(self.allocator, entries);
}

pub fn configureAccessResources(self: *Overlay, resources: ?AccessResources) !void {
    if (self.warm_accounts.count() != 0 or self.storage_slots.count() != 0) {
        return error.ActiveAccessState;
    }
    if (resources) |bounded| {
        try self.warm_accounts.ensureTotalCapacity(try accessHashMapCapacity(bounded.accounts));
    }
    try self.reserveConfiguredStorageSlots(resources, self.state_resources);
    self.access_resources = resources;
}

pub fn reserveAccessHint(self: *Overlay, resources: AccessResources) !void {
    if (self.access_resources != null) return;
    const account_capacity = std.math.add(usize, self.warm_accounts.count(), resources.accounts) catch return error.AccessCapacityTooLarge;
    const storage_capacity = std.math.add(usize, self.storage_slots.count(), resources.storage_keys) catch return error.AccessCapacityTooLarge;
    try self.warm_accounts.ensureTotalCapacity(try accessHintCapacity(account_capacity));
    try self.storage_slots.ensureTotalCapacity(try accessHintCapacity(storage_capacity));
}

pub fn configureTransientStorageEntries(self: *Overlay, entries: ?usize) !void {
    if (self.transient_storage.count() != 0) return error.ActiveTransientStorage;
    if (entries) |bounded| {
        try self.transient_storage.ensureTotalCapacity(try transientStorageCapacity(bounded));
        self.transient_storage_entries = bounded;
    } else {
        self.transient_storage_entries = null;
    }
}

pub fn configureStateResources(self: *Overlay, resources: ?StateResources) !void {
    if (resources) |bounded| {
        if ((bounded.code_entries == null) != (bounded.code_bytes == null)) {
            return error.InvalidCodeResources;
        }
        if (self.accounts.count() != 0 or
            self.code_cache.count() != 0 or
            self.seeded_storage.count() != 0 or
            self.storage_slots.count() != 0 or
            self.storage_overlay.count() != 0 or
            self.selfdestructed_accounts.count() != 0 or
            self.created_contracts.count() != 0 or
            self.deleted_accounts.count() != 0 or
            self.dirty_accounts.count() != 0)
        {
            return error.ActiveStateOverlay;
        }

        try self.accounts.ensureTotalCapacity(try hashMapCapacity(bounded.accounts));
        if (bounded.code_entries) |entries| {
            try self.code_cache.ensureTotalCapacity(try hashMapCapacity(entries));
        }
        if (bounded.code_bytes) |bytes| {
            try self.bounded_code_data.ensureTotalCapacityPrecise(self.allocator, bytes);
        }
        try self.storage_overlay.ensureTotalCapacity(try hashMapCapacity(bounded.storage_overlay_entries));
        try self.selfdestructed_accounts.ensureTotalCapacity(try hashMapCapacity(bounded.selfdestructed_accounts));
        try self.created_contracts.ensureTotalCapacity(try hashMapCapacity(bounded.created_contracts));
        try self.deleted_accounts.ensureTotalCapacity(try hashMapCapacity(bounded.deleted_accounts));
        try self.dirty_accounts.ensureTotalCapacity(try hashMapCapacity(bounded.dirty_accounts));
    } else {
        if (self.code_cache.count() != 0) return error.ActiveStateOverlay;
        self.bounded_code_data.deinit(self.allocator);
        self.bounded_code_data = .empty;
    }
    try self.reserveConfiguredStorageSlots(self.access_resources, resources);
    self.state_resources = resources;
}

fn reserveConfiguredStorageSlots(
    self: *Overlay,
    access_resources: ?AccessResources,
    state_resources: ?StateResources,
) !void {
    const access_entries = if (access_resources) |resources| resources.storage_keys else 0;
    const original_entries = if (state_resources) |resources| resources.original_storage_entries else 0;
    const entries = std.math.add(usize, access_entries, original_entries) catch return error.StateCapacityTooLarge;
    if (entries == 0 and access_resources == null and state_resources == null) return;
    try self.storage_slots.ensureTotalCapacity(try hashMapCapacity(entries));
}

fn hashMapCapacity(capacity: usize) !u32 {
    // Bounded insert helpers reserve one physical spare slot so they can insert
    // once, detect logical overflow, and roll the new entry back without growth.
    const physical_capacity = std.math.add(usize, capacity, 1) catch return error.StateCapacityTooLarge;
    return std.math.cast(u32, physical_capacity) orelse error.StateCapacityTooLarge;
}

fn accessHashMapCapacity(capacity: usize) !u32 {
    const physical_capacity = std.math.add(usize, capacity, 1) catch return error.AccessCapacityTooLarge;
    return std.math.cast(u32, physical_capacity) orelse error.AccessCapacityTooLarge;
}

fn accessHintCapacity(capacity: usize) !u32 {
    return std.math.cast(u32, capacity) orelse error.AccessCapacityTooLarge;
}

fn transientStorageCapacity(capacity: usize) !u32 {
    return std.math.cast(u32, capacity) orelse error.TransientStorageCapacityTooLarge;
}

pub fn getAccount(self: *Overlay, address: Address) ?*Account {
    return self.accounts.getPtr(address);
}

pub fn getAccountOrLoad(self: *Overlay, address: Address) !?*Account {
    if (self.deleted_accounts.contains(address)) return null;
    if (self.accounts.getPtr(address)) |account| return account;
    const state_reader = self.state_reader orelse return null;
    if (try state_reader.loadAccount(address)) |account| {
        if (self.transaction_open) {
            try self.journal.append(self.allocator, .{ .account_loaded = address });
            errdefer self.discardLastJournalEntry();
        }
        try self.putAccount(address, account);
        return self.accounts.getPtr(address).?;
    }
    return null;
}

pub fn getOrCreateAccount(self: *Overlay, address: Address) !*Account {
    if (self.deleted_accounts.contains(address)) {
        try self.journal.append(self.allocator, .{ .deleted_account_revived = address });
        errdefer self.discardLastJournalEntry();
        try self.putAccount(address, .{});
        _ = self.deleted_accounts.remove(address);
        return self.accounts.getPtr(address).?;
    }
    if (try self.getAccountOrLoad(address)) |account| return account;
    if (!self.accounts.contains(address)) {
        try self.journal.append(self.allocator, .{ .account_created = address });
        errdefer self.discardLastJournalEntry();
        try self.putAccount(address, .{});
    }
    return self.accounts.getPtr(address).?;
}

fn putAccount(self: *Overlay, address: Address, account: Account) !void {
    if (self.state_resources) |resources| {
        if (self.accounts.getPtr(address)) |slot| {
            slot.* = account;
            return;
        }
        if (@as(usize, self.accounts.count()) >= resources.accounts) {
            return error.AccountCapacityExceeded;
        }
        self.accounts.putAssumeCapacity(address, account);
        return;
    }
    try self.accounts.put(address, account);
}

/// Seed a rich in-memory account while preserving the executor's split account,
/// code, and storage representations. The overlay consumes `account`, whose
/// allocator owns its code and storage.
pub fn seedAccount(
    self: *Overlay,
    address: Address,
    account_value: MemoryAccount,
) !void {
    var account = account_value;
    defer account.deinit();

    const code_hash = account.code_hash orelse evmz.crypto.keccak256(account.code);
    if (!std.mem.eql(u8, &evmz.crypto.keccak256(account.code), &code_hash)) return error.CodeHashMismatch;

    if (!self.accounts.contains(address)) {
        if (self.state_resources) |resources| {
            if (@as(usize, self.accounts.count()) >= resources.accounts) return error.AccountCapacityExceeded;
        } else {
            try self.accounts.ensureUnusedCapacity(1);
        }
    }

    const storage_count = std.math.cast(u32, account.storage.count()) orelse return error.StateCapacityTooLarge;
    try self.seeded_storage.ensureUnusedCapacity(storage_count);

    var old_storage_keys: std.ArrayList(StorageKey) = .empty;
    defer old_storage_keys.deinit(self.allocator);
    var seeded_it = self.seeded_storage.keyIterator();
    while (seeded_it.next()) |key| {
        if (std.mem.eql(u8, &key.address, &address)) try old_storage_keys.append(self.allocator, key.*);
    }

    if (account.code.len != 0) _ = try self.cacheCode(code_hash, account.code, false);

    for (old_storage_keys.items) |key| _ = self.seeded_storage.remove(key);
    self.accounts.putAssumeCapacity(address, .{
        .nonce = account.nonce,
        .balance = account.balance,
        .code_hash = code_hash,
    });

    var storage_it = account.storage.iterator();
    while (storage_it.next()) |entry| {
        self.seeded_storage.putAssumeCapacity(
            .{ .address = address, .key = entry.key_ptr.* },
            entry.value_ptr.*,
        );
    }
}

fn codeByHash(self: *Overlay, code_hash: [32]u8) ![]const u8 {
    if (std.mem.eql(u8, &code_hash, &evmz.crypto.keccak256_empty)) return &.{};
    if (self.code_cache.get(code_hash)) |entry| return entry.bytes;
    const state_reader = self.state_reader orelse return error.CodeUnavailable;
    return try self.cacheCode(code_hash, try state_reader.loadCode(code_hash), false);
}

fn cacheCode(self: *Overlay, code_hash: [32]u8, code: []const u8, introduced: bool) ![]const u8 {
    std.debug.assert(std.mem.eql(u8, &evmz.crypto.keccak256(code), &code_hash));
    if (std.mem.eql(u8, &code_hash, &evmz.crypto.keccak256_empty)) return &.{};
    if (self.code_cache.get(code_hash)) |entry| {
        return entry.bytes;
    }

    const resources = self.state_resources;
    if (resources) |bounded| {
        if (bounded.code_entries) |limit| {
            if (@as(usize, self.code_cache.count()) >= limit) return error.CodeCacheEntryCapacityExceeded;
        }
        if (bounded.code_bytes) |limit| {
            if (self.code_bytes_used > limit or code.len > limit - self.code_bytes_used) {
                return error.CodeCacheByteCapacityExceeded;
            }
        }
    }

    var owned = false;
    const bytes: []const u8 = if (resources != null and resources.?.code_bytes != null) blk: {
        const start = self.bounded_code_data.items.len;
        self.bounded_code_data.appendSliceAssumeCapacity(code);
        break :blk self.bounded_code_data.items[start..];
    } else blk: {
        owned = true;
        break :blk try self.allocator.dupe(u8, code);
    };
    errdefer if (owned) self.allocator.free(@constCast(bytes));
    errdefer {
        if (!owned) self.bounded_code_data.items.len -= code.len;
    }

    const entry = CodeEntry{ .bytes = bytes, .owned = owned, .introduced = introduced };
    if (resources != null and resources.?.code_entries != null) {
        self.code_cache.putAssumeCapacity(code_hash, entry);
    } else {
        try self.code_cache.put(code_hash, entry);
    }
    self.code_bytes_used += code.len;
    return bytes;
}

pub fn accountExists(self: *Overlay, address: Address) !bool {
    const result = blk: {
        if (self.deleted_accounts.contains(address)) break :blk false;
        if (self.accounts.contains(address)) break :blk true;
        const state_reader = self.state_reader orelse break :blk false;
        break :blk try state_reader.accountExists(address);
    };
    try self.traceStateRead(.{
        .account_exists = .{
            .address = address,
            .exists = result,
        },
    });
    return result;
}

pub fn getCodeView(self: *Overlay, address: Address) !CodeView {
    const view: CodeView = if (try self.getAccountOrLoad(address)) |account|
        .{
            .code_hash = account.code_hash,
            .bytes = try self.codeByHash(account.code_hash),
        }
    else
        .{
            .code_hash = evmz.crypto.keccak256_empty,
            .bytes = &.{},
        };
    try self.traceStateRead(.{
        .code = .{
            .address = address,
            .size = view.bytes.len,
        },
    });
    return view;
}

pub fn getCode(self: *Overlay, address: Address) ![]const u8 {
    return (try self.getCodeView(address)).bytes;
}

pub fn getCodeHash(self: *Overlay, address: Address) !u256 {
    const hash = if (try self.getAccountOrLoad(address)) |account|
        account.code_hash
    else
        return 0;
    return std.mem.readInt(u256, &hash, .big);
}

pub fn accountHasCode(self: *Overlay, address: Address) !bool {
    const account = try self.getAccountOrLoad(address) orelse return false;
    return !std.mem.eql(u8, &account.code_hash, &evmz.crypto.keccak256_empty);
}

pub fn getBalance(self: *Overlay, address: Address) !u256 {
    const balance = if (try self.getAccountOrLoad(address)) |account| account.balance else 0;
    try self.traceStateRead(.{
        .balance = .{
            .address = address,
            .value = balance,
        },
    });
    return balance;
}

pub fn setBalance(self: *Overlay, address: Address, value: u256) !void {
    const mutation_checkpoint = self.journal.checkpoint(self.logs.items.len);
    errdefer self.rollbackInternalCheckpoint(mutation_checkpoint);

    const account = try self.getOrCreateAccount(address);
    const previous = account.balance;
    try self.journal.append(self.allocator, .{ .balance = .{
        .address = address,
        .prev = previous,
    } });
    _ = try self.markAccountDirty(address);

    account.balance = value;
    try self.traceStateWrite(.{
        .balance = .{
            .address = address,
            .previous = previous,
            .value = value,
        },
    });
}

pub fn addBalance(self: *Overlay, address: Address, value: u256) !void {
    if (value == 0) return;
    const current = try self.getBalance(address);
    const next = std.math.add(u256, current, value) catch return error.BalanceOverflow;
    std.debug.assert(next >= current);
    try self.setBalance(address, next);
}

pub fn subtractBalance(self: *Overlay, address: Address, value: u256) !bool {
    if (value == 0) return true;
    const mutation_checkpoint = self.journal.checkpoint(self.logs.items.len);
    errdefer self.rollbackInternalCheckpoint(mutation_checkpoint);
    const account = try self.getAccountOrLoad(address) orelse return false;
    if (account.balance < value) return false;
    try self.journal.append(self.allocator, .{ .balance = .{
        .address = address,
        .prev = account.balance,
    } });
    _ = try self.markAccountDirty(address);

    const previous = account.balance;
    account.balance -= value;
    try self.traceStateWrite(.{
        .balance = .{
            .address = address,
            .previous = previous,
            .value = account.balance,
        },
    });
    return true;
}

pub fn setNonce(self: *Overlay, address: Address, value: u64) !void {
    const mutation_checkpoint = self.journal.checkpoint(self.logs.items.len);
    errdefer self.rollbackInternalCheckpoint(mutation_checkpoint);

    const account = try self.getOrCreateAccount(address);
    try self.journal.append(self.allocator, .{ .nonce = .{
        .address = address,
        .prev = account.nonce,
    } });
    _ = try self.markAccountDirty(address);

    const previous = account.nonce;
    account.nonce = value;
    try self.traceStateWrite(.{
        .nonce = .{
            .address = address,
            .previous = previous,
            .value = value,
        },
    });
}

pub fn setCode(self: *Overlay, address: Address, code: []const u8) !void {
    const mutation_checkpoint = self.journal.checkpoint(self.logs.items.len);
    errdefer self.rollbackInternalCheckpoint(mutation_checkpoint);

    const account = try self.getOrCreateAccount(address);
    try self.journal.append(self.allocator, .{ .code = .{
        .address = address,
        .prev = account.code_hash,
    } });
    _ = try self.markAccountDirty(address);

    const code_hash = evmz.crypto.keccak256(code);
    const inserted_code = !std.mem.eql(u8, &code_hash, &evmz.crypto.keccak256_empty) and
        !self.code_cache.contains(code_hash);
    _ = try self.cacheCode(code_hash, code, true);
    errdefer if (inserted_code) self.removeCachedCode(code_hash);
    account.code_hash = code_hash;
    try self.traceStateWrite(.{
        .code = .{
            .address = address,
            .size = code.len,
            .code = code,
        },
    });
}

pub fn clearCode(self: *Overlay, address: Address) !void {
    try self.setCode(address, &.{});
}

fn readStorageBacking(self: *Overlay, storage_key: StorageKey) !u256 {
    const value = blk: {
        if (self.deleted_accounts.count() != 0 and self.deleted_accounts.contains(storage_key.address)) break :blk 0;
        if (self.storage_overlay.count() != 0) {
            if (self.storage_overlay.get(storage_key)) |overlay_value| break :blk overlay_value;
        }
        if (self.seeded_storage.get(storage_key)) |seeded_value| break :blk seeded_value;
        const state_reader = self.state_reader orelse break :blk 0;
        break :blk try state_reader.getStorage(storage_key.address, storage_key.key);
    };
    return value;
}

pub fn getStorage(self: *Overlay, address: Address, key: u256) !u256 {
    const storage_key = StorageKey{ .address = address, .key = key };
    const value = blk: {
        if (self.deleted_accounts.count() != 0 and self.deleted_accounts.contains(address)) break :blk 0;
        if (self.storage_slots.getPtr(storage_key)) |slot| {
            try self.loadStorageSlot(storage_key, slot);
            break :blk slot.current;
        }
        break :blk try self.readStorageBacking(storage_key);
    };
    try self.traceStateRead(.{
        .storage = .{
            .address = address,
            .key = key,
            .value = value,
        },
    });
    return value;
}

pub fn loadStorage(self: *Overlay, address: Address, key: u256) !Host.StorageLoadResult {
    const mutation_checkpoint = self.journal.checkpoint(self.logs.items.len);
    errdefer self.rollbackInternalCheckpoint(mutation_checkpoint);

    const storage_key = StorageKey{ .address = address, .key = key };
    const access = try self.accessStorageSlot(storage_key);
    try self.traceStateRead(.{
        .storage = .{
            .address = address,
            .key = key,
            .value = access.slot.current,
        },
    });
    return .{ .value = access.slot.current, .access_status = access.access_status };
}

pub fn storeStorage(self: *Overlay, address: Address, key: u256, value: u256) !Host.StorageStoreResult {
    const mutation_checkpoint = self.journal.checkpoint(self.logs.items.len);
    errdefer self.rollbackInternalCheckpoint(mutation_checkpoint);

    const storage_key = StorageKey{ .address = address, .key = key };
    const access = try self.accessStorageSlot(storage_key);
    try self.traceStateRead(.{
        .storage = .{
            .address = address,
            .key = key,
            .value = access.slot.current,
        },
    });
    return .{
        .storage_status = try self.setStorageSlot(storage_key, access.slot, value),
        .access_status = access.access_status,
    };
}

fn accessStorageSlot(self: *Overlay, storage_key: StorageKey) !StorageSlotAccess {
    const result = try self.getOrPutStorageSlotForAccess(storage_key);
    if (!result.found_existing) result.value_ptr.* = .{};
    const slot = result.value_ptr;
    if (slot.warm and slot.loaded) {
        return .{ .slot = slot, .access_status = .warm };
    }

    const status = try self.markStorageSlotAccessed(storage_key, result);
    if (!slot.loaded) try self.loadStorageSlot(storage_key, slot);
    return .{ .slot = slot, .access_status = status };
}

pub fn accessStorage(self: *Overlay, address: Address, key: u256) !Host.AccessStatus {
    const storage_key = StorageKey{ .address = address, .key = key };
    const result = try self.getOrPutStorageSlotForAccess(storage_key);
    if (!result.found_existing) result.value_ptr.* = .{};
    return self.markStorageSlotAccessed(storage_key, result);
}

fn markStorageSlotAccessed(
    self: *Overlay,
    storage_key: StorageKey,
    result: StorageSlotMap.GetOrPutResult,
) !Host.AccessStatus {
    if (!result.value_ptr.warm) {
        self.warmStorageSlot(storage_key, result) catch |err| {
            if (!result.found_existing) _ = self.storage_slots.remove(storage_key);
            return err;
        };
        return .cold;
    }
    return .warm;
}

fn getOrPutStorageSlotForAccess(self: *Overlay, storage_key: StorageKey) !StorageSlotMap.GetOrPutResult {
    if (self.access_resources != null and self.state_resources != null) {
        return self.storage_slots.getOrPutAssumeCapacity(storage_key);
    }
    return try self.storage_slots.getOrPut(storage_key);
}

fn getOrPutStorageSlotForOriginal(self: *Overlay, storage_key: StorageKey) !StorageSlotMap.GetOrPutResult {
    if (self.access_resources != null and self.state_resources != null) {
        return self.storage_slots.getOrPutAssumeCapacity(storage_key);
    }
    return try self.storage_slots.getOrPut(storage_key);
}

fn loadStorageSlot(self: *Overlay, storage_key: StorageKey, slot: *StorageSlot) !void {
    if (slot.loaded) return;
    const overlay_value = self.storage_overlay.get(storage_key);
    const current = overlay_value orelse try self.readStorageBacking(storage_key);
    slot.original = current;
    slot.current = current;
    slot.loaded = true;
    slot.overlay_present = overlay_value != null;
}

pub fn setStorage(self: *Overlay, address: Address, key: u256, value: u256) !Host.StorageStatus {
    const storage_key = StorageKey{ .address = address, .key = key };
    const result = try self.getOrPutStorageSlotForOriginal(storage_key);
    if (!result.found_existing) result.value_ptr.* = .{};
    errdefer {
        if (!result.found_existing and !result.value_ptr.warm and !result.value_ptr.dirty) {
            _ = self.storage_slots.remove(storage_key);
        }
    }
    try self.loadStorageSlot(storage_key, result.value_ptr);
    try self.traceStateRead(.{
        .storage = .{
            .address = address,
            .key = key,
            .value = result.value_ptr.current,
        },
    });

    const had_original = result.value_ptr.original_recorded;
    if (!had_original) try self.recordOriginalStorage(result.value_ptr);
    errdefer if (!had_original) self.unrecordOriginalStorage(result.value_ptr);

    return self.setStorageSlot(storage_key, result.value_ptr, value);
}

fn setStorageSlot(self: *Overlay, storage_key: StorageKey, slot: *StorageSlot, value: u256) !Host.StorageStatus {
    if (slot.current == value) return .assigned;
    const status = storage.status(slot.original, slot.current, value);

    const mutation_checkpoint = self.journal.checkpoint(self.logs.items.len);
    errdefer self.rollbackInternalCheckpoint(mutation_checkpoint);

    const had_original = slot.original_recorded;
    if (!had_original) {
        try self.recordOriginalStorage(slot);
    }
    errdefer if (!had_original) self.unrecordOriginalStorage(slot);

    _ = try self.getOrCreateAccount(storage_key.address);

    const reserved_overlay_entry = !slot.dirty and !slot.overlay_present;
    if (reserved_overlay_entry) {
        try self.reservePendingStorageOverlayEntry();
    }
    errdefer {
        if (reserved_overlay_entry) self.pending_storage_overlay_entries -= 1;
    }

    try self.journal.append(self.allocator, .{ .storage_slot = .{
        .key = storage_key,
        .prev = slot.current,
        .dirty = slot.dirty,
    } });

    const previous = slot.current;
    slot.current = value;
    slot.dirty = true;
    try self.traceStateWrite(.{
        .storage = .{
            .address = storage_key.address,
            .key = storage_key.key,
            .previous = previous,
            .value = value,
        },
    });
    return status;
}

fn recordOriginalStorage(self: *Overlay, slot: *StorageSlot) !void {
    std.debug.assert(slot.loaded);
    std.debug.assert(!slot.original_recorded);
    if (self.state_resources) |resources| {
        if (self.original_storage_count >= resources.original_storage_entries) {
            return error.OriginalStorageCapacityExceeded;
        }
    }
    self.original_storage_count += 1;
    slot.original_recorded = true;
}

fn unrecordOriginalStorage(self: *Overlay, slot: *StorageSlot) void {
    std.debug.assert(slot.original_recorded);
    std.debug.assert(self.original_storage_count > 0);
    self.original_storage_count -= 1;
    slot.original_recorded = false;
}

fn reservePendingStorageOverlayEntry(self: *Overlay) !void {
    const next_pending = std.math.add(
        usize,
        self.pending_storage_overlay_entries,
        1,
    ) catch return error.StateCapacityTooLarge;

    if (self.state_resources) |resources| {
        const accepted_and_pending = std.math.add(
            usize,
            self.storage_overlay.count(),
            next_pending,
        ) catch return error.StateCapacityTooLarge;
        if (accepted_and_pending > resources.storage_overlay_entries) {
            return error.StorageOverlayCapacityExceeded;
        }
    } else {
        try self.storage_overlay.ensureUnusedCapacity(
            std.math.cast(u32, next_pending) orelse return error.StateCapacityTooLarge,
        );
    }
    self.pending_storage_overlay_entries = next_pending;
}

pub fn originalStorage(self: *Overlay, address: Address, key: u256) !u256 {
    const storage_key = StorageKey{ .address = address, .key = key };
    const result = try self.getOrPutStorageSlotForOriginal(storage_key);
    if (!result.found_existing) result.value_ptr.* = .{};
    errdefer {
        if (!result.found_existing and !result.value_ptr.warm and !result.value_ptr.dirty) {
            _ = self.storage_slots.remove(storage_key);
        }
    }
    try self.loadStorageSlot(storage_key, result.value_ptr);
    if (!result.value_ptr.original_recorded) try self.recordOriginalStorage(result.value_ptr);
    return result.value_ptr.original;
}

fn putStorageOverlay(self: *Overlay, storage_key: StorageKey, value: u256) !void {
    if (self.storage_overlay.getPtr(storage_key)) |existing| {
        existing.* = value;
        return;
    }

    if (self.state_resources) |resources| {
        const accepted_and_pending = std.math.add(
            usize,
            self.storage_overlay.count(),
            self.pending_storage_overlay_entries,
        ) catch return error.StateCapacityTooLarge;
        if (accepted_and_pending >= resources.storage_overlay_entries) {
            return error.StorageOverlayCapacityExceeded;
        }
        self.storage_overlay.putAssumeCapacityNoClobber(storage_key, value);
        return;
    }

    const needed = std.math.add(
        usize,
        self.pending_storage_overlay_entries,
        1,
    ) catch return error.StateCapacityTooLarge;
    try self.storage_overlay.ensureUnusedCapacity(
        std.math.cast(u32, needed) orelse return error.StateCapacityTooLarge,
    );
    self.storage_overlay.putAssumeCapacityNoClobber(storage_key, value);
}

pub fn accountHasStorage(self: *Overlay, address: Address) !bool {
    const result = try self.accountHasStorageInner(address);
    try self.traceStateRead(.{
        .account_has_storage = .{
            .address = address,
            .exists = result,
        },
    });
    return result;
}

fn accountHasStorageInner(self: *Overlay, address: Address) !bool {
    if (self.deleted_accounts.contains(address)) return false;

    var slot_it = self.storage_slots.iterator();
    while (slot_it.next()) |entry| {
        if (!std.mem.eql(u8, &entry.key_ptr.address, &address)) continue;
        if (entry.value_ptr.loaded and entry.value_ptr.current != 0) return true;
    }

    var overlay_it = self.storage_overlay.iterator();
    while (overlay_it.next()) |entry| {
        if (!std.mem.eql(u8, &entry.key_ptr.address, &address)) continue;
        if (self.storage_slots.get(entry.key_ptr.*)) |slot| {
            if ((if (slot.loaded) slot.current else entry.value_ptr.*) != 0) return true;
        } else if (entry.value_ptr.* != 0) {
            return true;
        }
    }
    var seeded_it = self.seeded_storage.iterator();
    while (seeded_it.next()) |entry| {
        if (std.mem.eql(u8, &entry.key_ptr.address, &address)) {
            if (entry.value_ptr.* == 0) continue;
            if (self.storage_slots.get(entry.key_ptr.*)) |slot| {
                if (slot.loaded) {
                    if (slot.current != 0) return true;
                } else if (self.storage_overlay.get(entry.key_ptr.*)) |overlay_value| {
                    if (overlay_value != 0) return true;
                } else {
                    return true;
                }
            } else if (self.storage_overlay.get(entry.key_ptr.*)) |overlay_value| {
                if (overlay_value != 0) return true;
            } else {
                return true;
            }
        }
    }
    const state_reader = self.state_reader orelse return false;
    return state_reader.accountHasStorage(address);
}

pub fn beginTransaction(self: *Overlay) void {
    self.clearLogsRetainingCapacity();
    self.closeTransaction();
    self.transaction_open = true;
}

/// Open one execution scope while retaining an outer transaction attempt's
/// journal. Returns the journal boundary used to compact scope-local entries
/// when the scope closes.
pub fn beginExecutionScope(self: *Overlay) usize {
    std.debug.assert(!self.transaction_open);
    std.debug.assert(self.warm_accounts.count() == 0);
    std.debug.assert(self.storage_slots.count() == 0);
    std.debug.assert(self.transient_storage.count() == 0);
    self.clearLogsRetainingCapacity();
    self.transaction_open = true;
    return self.journal.len();
}

/// Close a finalized execution scope without closing its outer transaction
/// attempt. Canonical storage writes are promoted into the overlay with inverse
/// journal entries; warmth, transient storage, and other scope-local entries
/// are discarded before the next execution scope begins.
pub fn closeExecutionScope(self: *Overlay, journal_start: usize) !void {
    std.debug.assert(self.transaction_open);
    try self.mergeDirtyStorageSlotsJournaled();
    self.compactExecutionScopeJournal(journal_start);
    self.clearExecutionScopeState();
    self.transaction_open = false;
}

pub fn closeTransaction(self: *Overlay) void {
    self.mergeDirtyStorageSlots();
    self.clearExecutionScopeState();
    self.journal.clearRetainingCapacity(self.allocator);
    self.transaction_open = false;
}

fn clearExecutionScopeState(self: *Overlay) void {
    self.warm_accounts.clearRetainingCapacity();
    self.storage_slots.clearRetainingCapacity();
    self.warm_storage_count = 0;
    self.original_storage_count = 0;
    self.pending_storage_overlay_entries = 0;
    self.transient_storage.clearRetainingCapacity();
    self.selfdestructed_accounts.clearRetainingCapacity();
    self.created_contracts.clearRetainingCapacity();
}

fn mergeDirtyStorageSlots(self: *Overlay) void {
    var it = self.storage_slots.iterator();
    while (it.next()) |entry| {
        const slot = entry.value_ptr;
        if (!slot.dirty) continue;
        if (self.deleted_accounts.contains(entry.key_ptr.address)) continue;

        if (self.storage_overlay.getPtr(entry.key_ptr.*)) |accepted| {
            accepted.* = slot.current;
        } else {
            self.storage_overlay.putAssumeCapacityNoClobber(entry.key_ptr.*, slot.current);
        }
    }
}

fn mergeDirtyStorageSlotsJournaled(self: *Overlay) !void {
    const mutation_checkpoint = self.journal.checkpoint(self.logs.items.len);
    errdefer self.rollbackInternalCheckpoint(mutation_checkpoint);

    var it = self.storage_slots.iterator();
    while (it.next()) |entry| {
        const slot = entry.value_ptr;
        if (!slot.dirty) continue;
        if (self.deleted_accounts.contains(entry.key_ptr.address)) continue;

        const previous = self.storage_overlay.get(entry.key_ptr.*);
        try self.journal.append(self.allocator, .{ .storage_overlay = .{
            .key = entry.key_ptr.*,
            .had_value = previous != null,
            .prev = previous orelse 0,
        } });
        if (self.storage_overlay.getPtr(entry.key_ptr.*)) |accepted| {
            accepted.* = slot.current;
        } else {
            self.storage_overlay.putAssumeCapacityNoClobber(entry.key_ptr.*, slot.current);
        }
    }
}

fn compactExecutionScopeJournal(self: *Overlay, journal_start: usize) void {
    std.debug.assert(journal_start <= self.journal.items.items.len);
    var write_index = journal_start;
    var read_index = journal_start;
    while (read_index < self.journal.items.items.len) : (read_index += 1) {
        const entry = self.journal.items.items[read_index];
        const scope_local = switch (entry) {
            .storage_slot,
            .transient_storage,
            .warm_account,
            .warm_storage,
            .created_contract,
            .selfdestruct,
            .created_contract_cleared,
            .selfdestruct_cleared,
            => true,
            else => false,
        };
        if (scope_local) {
            var discarded = entry;
            discarded.deinit(self.allocator);
            continue;
        }
        if (write_index != read_index) self.journal.items.items[write_index] = entry;
        write_index += 1;
    }
    self.journal.items.items.len = write_index;
}

pub fn discardChanges(self: *Overlay) void {
    self.closeTransaction();
    self.clearAccounts();
    self.clearCodeCache();
    self.seeded_storage.clearRetainingCapacity();
    self.storage_overlay.clearRetainingCapacity();
    self.selfdestructed_accounts.clearRetainingCapacity();
    self.created_contracts.clearRetainingCapacity();
    self.deleted_accounts.clearRetainingCapacity();
    self.dirty_accounts.clearRetainingCapacity();
    self.clearLogsRetainingCapacity();
}

/// Whether the eager branch contains canonical state mutations.
/// Read caches and transaction-local access metadata do not count as changes.
pub fn hasChanges(self: *const Overlay) bool {
    return self.dirty_accounts.count() != 0 or
        self.deleted_accounts.count() != 0 or
        self.storage_overlay.count() != 0;
}

pub fn warmAccount(self: *Overlay, address: Address) !void {
    if (self.warm_accounts.contains(address)) return;
    const mutation_checkpoint = self.journal.checkpoint(self.logs.items.len);
    errdefer self.rollbackInternalCheckpoint(mutation_checkpoint);
    try self.journal.append(self.allocator, .{ .warm_account = address });
    try self.putWarmAccount(address);
    try self.traceStateWrite(.{
        .warm_account = .{
            .address = address,
        },
    });
}

pub fn warmStorage(self: *Overlay, address: Address, key: u256) !void {
    const storage_key = StorageKey{ .address = address, .key = key };
    const result = try self.getOrPutStorageSlotForAccess(storage_key);
    if (!result.found_existing) result.value_ptr.* = .{};
    self.warmStorageSlot(storage_key, result) catch |err| {
        if (!result.found_existing) _ = self.storage_slots.remove(storage_key);
        return err;
    };
}

pub fn isStorageWarm(self: *const Overlay, address: Address, key: u256) bool {
    const slot = self.storage_slots.get(.{ .address = address, .key = key }) orelse return false;
    return slot.warm;
}

pub fn warmStorageCount(self: *const Overlay) usize {
    return self.warm_storage_count;
}

pub fn originalStorageCount(self: *const Overlay) usize {
    return self.original_storage_count;
}

fn warmStorageSlot(self: *Overlay, storage_key: StorageKey, result: StorageSlotMap.GetOrPutResult) !void {
    const slot = result.value_ptr;
    if (slot.warm) return;
    const mutation_checkpoint = self.journal.checkpoint(self.logs.items.len);
    errdefer self.rollbackInternalCheckpoint(mutation_checkpoint);

    if (self.access_resources) |resources| {
        if (self.warm_storage_count >= resources.storage_keys) {
            return error.WarmStorageCapacityExceeded;
        }
    }
    try self.journal.append(self.allocator, .{ .warm_storage = .{
        .key = storage_key,
        .slot_created = !result.found_existing,
    } });
    self.warm_storage_count += 1;
    slot.warm = true;
    try self.traceStateWrite(.{
        .warm_storage = .{
            .address = storage_key.address,
            .key = storage_key.key,
        },
    });
}

fn putWarmAccount(self: *Overlay, address: Address) !void {
    if (self.access_resources) |resources| {
        try putBoundedAddressSet(&self.warm_accounts, address, resources.accounts, error.WarmAccountCapacityExceeded);
        return;
    }
    try self.warm_accounts.put(address, {});
}

pub fn getTransientStorage(self: *Overlay, address: Address, key: u256) !u256 {
    const value = self.transient_storage.get(.{ .address = address, .key = key }) orelse 0;
    try self.traceStateRead(.{
        .transient_storage = .{
            .address = address,
            .key = key,
            .value = value,
        },
    });
    return value;
}

pub fn setTransientStorage(self: *Overlay, address: Address, key: u256, value: u256) !void {
    const mutation_checkpoint = self.journal.checkpoint(self.logs.items.len);
    errdefer self.rollbackInternalCheckpoint(mutation_checkpoint);
    const storage_key = StorageKey{ .address = address, .key = key };
    const prev = self.transient_storage.get(storage_key);

    if (value != 0 and prev == null) {
        if (self.transient_storage_entries) |entry_limit| {
            if (@as(usize, self.transient_storage.count()) >= entry_limit) {
                return error.TransientStorageCapacityExceeded;
            }
            std.debug.assert(self.transient_storage.count() < self.transient_storage.capacity());
        } else {
            try self.transient_storage.ensureUnusedCapacity(1);
        }
    }

    try self.journal.append(self.allocator, .{ .transient_storage = .{
        .address = address,
        .key = key,
        .had_value = prev != null,
        .prev = prev orelse 0,
    } });
    if (value == 0) {
        _ = self.transient_storage.remove(storage_key);
    } else {
        self.putTransientStorageAssumeCapacity(storage_key, value);
    }
    try self.traceStateWrite(.{
        .transient_storage = .{
            .address = address,
            .key = key,
            .previous = prev orelse 0,
            .value = value,
        },
    });
}

fn putTransientStorageAssumeCapacity(self: *Overlay, storage_key: StorageKey, value: u256) void {
    self.transient_storage.putAssumeCapacity(storage_key, value);
}

pub fn emitLog(self: *Overlay, event_log: Host.Log) !void {
    const mutation_checkpoint = self.journal.checkpoint(self.logs.items.len);
    errdefer self.rollbackInternalCheckpoint(mutation_checkpoint);
    if (self.log_resources != null) {
        try self.emitBoundedLog(event_log);
        return;
    }

    const topics = try self.allocator.dupe(u256, event_log.topics);
    var topics_owned = true;
    errdefer if (topics_owned) self.allocator.free(topics);
    const data = try self.allocator.dupe(u8, event_log.data);
    var data_owned = true;
    errdefer if (data_owned) self.allocator.free(data);
    try self.logs.append(self.allocator, .{
        .address = event_log.address,
        .topics = topics,
        .data = data,
    });
    topics_owned = false;
    data_owned = false;
    try self.traceStateWrite(.{
        .log = .{
            .address = event_log.address,
            .topics_len = event_log.topics.len,
            .data_size = event_log.data.len,
        },
    });
}

fn emitBoundedLog(self: *Overlay, event_log: Host.Log) !void {
    const resources = self.log_resources orelse unreachable;
    if (event_log.topics.len > 4) return error.LogTopicCapacityExceeded;
    if (self.logs.items.len >= resources.entries) return error.LogCapacityExceeded;
    if (event_log.data.len > resources.data_bytes - self.bounded_log_data.items.len) {
        return error.LogDataCapacityExceeded;
    }

    var topics_row = [_]u256{0} ** 4;
    @memcpy(topics_row[0..event_log.topics.len], event_log.topics);
    self.bounded_log_topics.appendAssumeCapacity(topics_row);

    const data_start = self.bounded_log_data.items.len;
    self.bounded_log_data.appendSliceAssumeCapacity(event_log.data);
    const data_end = self.bounded_log_data.items.len;

    const index = self.logs.items.len;
    self.logs.appendAssumeCapacity(.{
        .address = event_log.address,
        .topics = self.bounded_log_topics.items[index][0..event_log.topics.len],
        .data = self.bounded_log_data.items[data_start..data_end],
    });
    try self.traceStateWrite(.{
        .log = .{
            .address = event_log.address,
            .topics_len = event_log.topics.len,
            .data_size = event_log.data.len,
        },
    });
}

pub fn markCreatedContract(self: *Overlay, address: Address) !void {
    if (self.created_contracts.contains(address)) return;
    const mutation_checkpoint = self.journal.checkpoint(self.logs.items.len);
    errdefer self.rollbackInternalCheckpoint(mutation_checkpoint);
    try self.journal.append(self.allocator, .{ .created_contract = address });
    try self.putCreatedContract(address);
    try self.traceStateWrite(.{
        .created_contract = .{
            .address = address,
        },
    });
}

pub fn markSelfdestructed(self: *Overlay, address: Address) !void {
    if (self.selfdestructed_accounts.contains(address)) return;
    const mutation_checkpoint = self.journal.checkpoint(self.logs.items.len);
    errdefer self.rollbackInternalCheckpoint(mutation_checkpoint);
    try self.journal.append(self.allocator, .{ .selfdestruct = address });
    try self.putSelfdestructedAccount(address);
    try self.traceStateWrite(.{
        .selfdestruct = .{
            .address = address,
        },
    });
}

pub fn checkpoint(self: *const Overlay) !Journal.Checkpoint {
    const checkpoint_state = self.journal.checkpoint(self.logs.items.len);
    try self.traceCheckpoint(.checkpoint, checkpoint_state);
    return checkpoint_state;
}

pub fn commitCheckpoint(self: *Overlay, checkpoint_state: Journal.Checkpoint) !void {
    try self.traceCheckpoint(.commit, checkpoint_state);
}

pub fn revertToCheckpoint(self: *Overlay, checkpoint_state: Journal.Checkpoint) !void {
    self.rollbackInternalCheckpoint(checkpoint_state);
    try self.traceCheckpoint(.revert, checkpoint_state);
}

fn rollbackInternalCheckpoint(self: *Overlay, checkpoint_state: Journal.Checkpoint) void {
    while (self.journal.len() > checkpoint_state.journal_len) {
        var entry = self.journal.pop().?;
        defer entry.deinit(self.allocator);
        self.revertJournalEntry(&entry);
    }
    self.truncateLogs(checkpoint_state.logs_len);
}

fn revertJournalEntry(self: *Overlay, entry: *Journal.Entry) void {
    switch (entry.*) {
        .account_loaded => |address| {
            _ = self.accounts.remove(address);
        },
        .account_created => |address| {
            _ = self.accounts.remove(address);
        },
        .deleted_account_revived => |address| {
            _ = self.accounts.remove(address);
            restoreMapValueAssumeCapacity(&self.deleted_accounts, address, {});
        },
        .dirty_account => |address| {
            _ = self.dirty_accounts.remove(address);
        },
        .balance => |balance| {
            if (self.accounts.getPtr(balance.address)) |account| {
                account.balance = balance.prev;
            }
        },
        .nonce => |nonce| {
            if (self.accounts.getPtr(nonce.address)) |account| {
                account.nonce = nonce.prev;
            }
        },
        .code => |*code| {
            if (self.accounts.getPtr(code.address)) |account| {
                account.code_hash = code.prev;
            }
        },
        .account_removed => |*removed| {
            if (removed.prev) |account| {
                restoreMapValueAssumeCapacity(&self.accounts, removed.address, account);
                removed.prev = null;
            }
        },
        .storage_slot => |storage_entry| {
            if (self.storage_slots.getPtr(storage_entry.key)) |slot| {
                if (!slot.overlay_present) {
                    const current_pending = slot.dirty;
                    const restored_pending = storage_entry.dirty;
                    if (current_pending and !restored_pending) {
                        std.debug.assert(self.pending_storage_overlay_entries > 0);
                        self.pending_storage_overlay_entries -= 1;
                    } else if (!current_pending and restored_pending) {
                        self.pending_storage_overlay_entries += 1;
                    }
                }
                slot.current = storage_entry.prev;
                slot.dirty = storage_entry.dirty;
            }
        },
        .storage_overlay => |storage_entry| {
            if (storage_entry.had_value) {
                if (self.storage_overlay.getPtr(storage_entry.key)) |value| {
                    value.* = storage_entry.prev;
                } else {
                    restoreMapValueAssumeCapacity(
                        &self.storage_overlay,
                        storage_entry.key,
                        storage_entry.prev,
                    );
                }
            } else {
                _ = self.storage_overlay.remove(storage_entry.key);
            }
        },
        .transient_storage => |storage_entry| {
            const storage_key = StorageKey{ .address = storage_entry.address, .key = storage_entry.key };
            if (storage_entry.had_value) {
                self.putTransientStorageAssumeCapacity(storage_key, storage_entry.prev);
            } else {
                _ = self.transient_storage.remove(storage_key);
            }
        },
        .warm_account => |address| {
            _ = self.warm_accounts.remove(address);
        },
        .warm_storage => |storage_entry| {
            const slot = self.storage_slots.getPtr(storage_entry.key) orelse return;
            std.debug.assert(slot.warm);
            std.debug.assert(self.warm_storage_count > 0);
            slot.warm = false;
            self.warm_storage_count -= 1;
            if (storage_entry.slot_created and !slot.original_recorded and !slot.dirty) {
                _ = self.storage_slots.remove(storage_entry.key);
            }
        },
        .created_contract => |address| {
            _ = self.created_contracts.remove(address);
        },
        .selfdestruct => |address| {
            _ = self.selfdestructed_accounts.remove(address);
        },
        .deleted_account_marked => |address| {
            _ = self.deleted_accounts.remove(address);
        },
        .created_contract_cleared => |address| {
            restoreMapValueAssumeCapacity(&self.created_contracts, address, {});
        },
        .selfdestruct_cleared => |address| {
            restoreMapValueAssumeCapacity(&self.selfdestructed_accounts, address, {});
        },
        .storage_overlay_removed => |removed| {
            restoreMapValueAssumeCapacity(&self.storage_overlay, removed.key, removed.prev);
        },
    }
}

/// Journal rollback walks mutations in reverse order. Every removed entry left
/// its map allocation behind, while entries inserted after the checkpoint are
/// removed before an older value is restored. Rollback can therefore reinsert
/// without growing any map.
fn restoreMapValueAssumeCapacity(map: anytype, key: anytype, value: anytype) void {
    if (!map.contains(key)) std.debug.assert(map.count() < map.capacity());
    map.putAssumeCapacity(key, value);
}

fn markAccountDirty(self: *Overlay, address: Address) !bool {
    if (self.dirty_accounts.contains(address)) return false;
    try self.journal.append(self.allocator, .{ .dirty_account = address });
    errdefer self.discardLastJournalEntry();
    try self.putDirtyAccount(address);
    return true;
}

fn putCreatedContract(self: *Overlay, address: Address) !void {
    if (self.state_resources) |resources| {
        try putBoundedAddressSet(&self.created_contracts, address, resources.created_contracts, error.CreatedContractCapacityExceeded);
        return;
    }
    try self.created_contracts.put(address, {});
}

fn putSelfdestructedAccount(self: *Overlay, address: Address) !void {
    if (self.state_resources) |resources| {
        try putBoundedAddressSet(
            &self.selfdestructed_accounts,
            address,
            resources.selfdestructed_accounts,
            error.SelfdestructCapacityExceeded,
        );
        return;
    }
    try self.selfdestructed_accounts.put(address, {});
}

fn putDeletedAccount(self: *Overlay, address: Address) !void {
    if (self.state_resources) |resources| {
        try putBoundedAddressSet(&self.deleted_accounts, address, resources.deleted_accounts, error.DeletedAccountCapacityExceeded);
        return;
    }
    try self.deleted_accounts.put(address, {});
}

fn putDirtyAccount(self: *Overlay, address: Address) !void {
    if (self.state_resources) |resources| {
        try putBoundedAddressSet(&self.dirty_accounts, address, resources.dirty_accounts, error.DirtyAccountCapacityExceeded);
        return;
    }
    try self.dirty_accounts.put(address, {});
}

fn putBoundedAddressSet(
    set: *AddressSet,
    address: Address,
    entry_limit: usize,
    comptime capacity_error: anyerror,
) !void {
    assertBoundedMapSlack(set, entry_limit);
    const result = set.getOrPutAssumeCapacity(address);
    if (!result.found_existing and @as(usize, set.count()) > entry_limit) {
        _ = set.remove(address);
        return capacity_error;
    }
    result.value_ptr.* = {};
}

fn assertBoundedMapSlack(map: anytype, entry_limit: usize) void {
    std.debug.assert(@as(usize, map.capacity()) > entry_limit);
}

fn traceStateRead(self: *const Overlay, event: trace.StateRead) !void {
    const event_with_depth = event.withDepth(self.trace_depth);
    if (self.capture_context) |context| try context.stateRead(event_with_depth);
}

fn traceStateWrite(self: *const Overlay, event: trace.StateWrite) !void {
    const event_with_depth = event.withDepth(self.trace_depth);
    if (self.capture_context) |context| try context.stateWrite(event_with_depth);
}

fn traceCheckpoint(self: *const Overlay, kind: trace.CheckpointKind, checkpoint_state: Journal.Checkpoint) !void {
    const event: trace.Checkpoint = .{
        .kind = kind,
        .depth = self.trace_depth,
        .journal_len = checkpoint_state.journal_len,
        .logs_len = checkpoint_state.logs_len,
    };
    if (self.capture_context) |context| try context.checkpoint(event);
}

fn discardLastJournalEntry(self: *Overlay) void {
    var entry = self.journal.pop() orelse return;
    entry.deinit(self.allocator);
}

pub fn snapshot(self: *Overlay) !Snapshot {
    var result = Snapshot{
        .accounts = AccountMap.init(self.allocator),
        .warm_accounts = AddressSet.init(self.allocator),
        .storage_slots = StorageSlotMap.init(self.allocator),
        .warm_storage_count = self.warm_storage_count,
        .original_storage_count = self.original_storage_count,
        .pending_storage_overlay_entries = self.pending_storage_overlay_entries,
        .storage_overlay = StorageMap.init(self.allocator),
        .transient_storage = TransientStorageMap.init(self.allocator),
        .selfdestructed_accounts = AddressSet.init(self.allocator),
        .created_contracts = AddressSet.init(self.allocator),
        .deleted_accounts = AddressSet.init(self.allocator),
        .dirty_accounts = AddressSet.init(self.allocator),
        .logs_len = self.logs.items.len,
        .journal_len = self.journal.len(),
    };
    errdefer result.deinit(self.allocator);

    var account_it = self.accounts.iterator();
    while (account_it.next()) |entry| {
        try result.accounts.put(entry.key_ptr.*, entry.value_ptr.*);
    }

    var warm_account_it = self.warm_accounts.keyIterator();
    while (warm_account_it.next()) |address| {
        try result.warm_accounts.put(address.*, {});
    }

    var storage_slot_it = self.storage_slots.iterator();
    while (storage_slot_it.next()) |entry| {
        try result.storage_slots.put(entry.key_ptr.*, entry.value_ptr.*);
    }

    var storage_overlay_it = self.storage_overlay.iterator();
    while (storage_overlay_it.next()) |entry| {
        try result.storage_overlay.put(entry.key_ptr.*, entry.value_ptr.*);
    }

    var transient_it = self.transient_storage.iterator();
    while (transient_it.next()) |entry| {
        try result.transient_storage.put(entry.key_ptr.*, entry.value_ptr.*);
    }

    var selfdestruct_it = self.selfdestructed_accounts.keyIterator();
    while (selfdestruct_it.next()) |address| {
        try result.selfdestructed_accounts.put(address.*, {});
    }

    var created_it = self.created_contracts.keyIterator();
    while (created_it.next()) |address| {
        try result.created_contracts.put(address.*, {});
    }

    var deleted_it = self.deleted_accounts.keyIterator();
    while (deleted_it.next()) |address| {
        try result.deleted_accounts.put(address.*, {});
    }

    var dirty_it = self.dirty_accounts.keyIterator();
    while (dirty_it.next()) |address| {
        try result.dirty_accounts.put(address.*, {});
    }

    return result;
}

pub fn restore(self: *Overlay, snapshot_state: *Snapshot) !void {
    try self.restoreFromSnapshot(snapshot_state);
}

/// Emit lifecycle for snapshot-backed rollback paths that do not use journal
/// checkpoint methods directly.
pub fn traceSnapshotLifecycle(self: *const Overlay, kind: trace.CheckpointKind, snapshot_state: *const Snapshot) !void {
    try self.traceCheckpoint(kind, .{
        .journal_len = snapshot_state.journal_len,
        .logs_len = snapshot_state.logs_len,
    });
}

fn restoreFromSnapshot(self: *Overlay, snapshot_state: *Snapshot) !void {
    self.clearAccounts();
    self.warm_accounts.clearRetainingCapacity();
    self.storage_slots.clearRetainingCapacity();
    self.warm_storage_count = 0;
    self.original_storage_count = 0;
    self.pending_storage_overlay_entries = 0;
    self.storage_overlay.clearRetainingCapacity();
    self.transient_storage.clearRetainingCapacity();
    self.selfdestructed_accounts.clearRetainingCapacity();
    self.created_contracts.clearRetainingCapacity();
    self.deleted_accounts.clearRetainingCapacity();
    self.dirty_accounts.clearRetainingCapacity();
    self.truncateLogs(snapshot_state.logs_len);
    self.journal.truncate(self.allocator, snapshot_state.journal_len);

    var account_it = snapshot_state.accounts.iterator();
    while (account_it.next()) |entry| {
        try self.putAccount(entry.key_ptr.*, entry.value_ptr.*);
    }

    var warm_account_it = snapshot_state.warm_accounts.keyIterator();
    while (warm_account_it.next()) |address| {
        try self.putWarmAccount(address.*);
    }

    var storage_slot_it = snapshot_state.storage_slots.iterator();
    while (storage_slot_it.next()) |entry| {
        try self.storage_slots.put(entry.key_ptr.*, entry.value_ptr.*);
    }
    self.warm_storage_count = snapshot_state.warm_storage_count;
    self.original_storage_count = snapshot_state.original_storage_count;
    self.pending_storage_overlay_entries = snapshot_state.pending_storage_overlay_entries;

    var storage_overlay_it = snapshot_state.storage_overlay.iterator();
    while (storage_overlay_it.next()) |entry| {
        try self.putStorageOverlay(entry.key_ptr.*, entry.value_ptr.*);
    }

    var transient_it = snapshot_state.transient_storage.iterator();
    while (transient_it.next()) |entry| {
        self.putTransientStorageAssumeCapacity(entry.key_ptr.*, entry.value_ptr.*);
    }

    var selfdestruct_it = snapshot_state.selfdestructed_accounts.keyIterator();
    while (selfdestruct_it.next()) |address| {
        try self.putSelfdestructedAccount(address.*);
    }

    var created_it = snapshot_state.created_contracts.keyIterator();
    while (created_it.next()) |address| {
        try self.putCreatedContract(address.*);
    }

    var deleted_it = snapshot_state.deleted_accounts.keyIterator();
    while (deleted_it.next()) |address| {
        try self.putDeletedAccount(address.*);
    }

    var dirty_it = snapshot_state.dirty_accounts.keyIterator();
    while (dirty_it.next()) |address| {
        try self.putDirtyAccount(address.*);
    }
}

pub fn getLogs(self: *const Overlay) []const Host.Log {
    return self.logs.items;
}

pub fn clearLogs(self: *Overlay) void {
    self.clearLogsRetainingCapacity();
}

fn clearLogsRetainingCapacity(self: *Overlay) void {
    self.truncateLogs(0);
    self.logs.clearRetainingCapacity();
}

fn truncateLogs(self: *Overlay, len: usize) void {
    if (self.log_resources != null) {
        var data_len: usize = 0;
        for (self.logs.items[0..len]) |event_log| {
            data_len += event_log.data.len;
        }
        self.logs.items.len = len;
        self.bounded_log_topics.items.len = len;
        self.bounded_log_data.items.len = data_len;
        return;
    }

    for (self.logs.items[len..]) |*event_log| {
        deinitLog(self.allocator, event_log);
    }
    self.logs.items.len = len;
}

fn deinitLog(allocator: std.mem.Allocator, event_log: *Host.Log) void {
    allocator.free(@constCast(event_log.topics));
    allocator.free(@constCast(event_log.data));
    event_log.* = undefined;
}

pub fn clearAccounts(self: *Overlay) void {
    self.accounts.clearRetainingCapacity();
}

fn clearCodeCache(self: *Overlay) void {
    var code_it = self.code_cache.valueIterator();
    while (code_it.next()) |entry| {
        if (entry.owned) self.allocator.free(@constCast(entry.bytes));
    }
    self.code_cache.clearRetainingCapacity();
    self.bounded_code_data.clearRetainingCapacity();
    self.code_bytes_used = 0;
}

fn removeCachedCode(self: *Overlay, code_hash: [32]u8) void {
    const removed = self.code_cache.fetchRemove(code_hash) orelse unreachable;
    self.code_bytes_used -= removed.value.bytes.len;
    if (removed.value.owned) {
        self.allocator.free(@constCast(removed.value.bytes));
        return;
    }

    const bytes = removed.value.bytes;
    const bounded_end = self.bounded_code_data.items.ptr + self.bounded_code_data.items.len;
    std.debug.assert(bytes.ptr + bytes.len == bounded_end);
    self.bounded_code_data.items.len -= bytes.len;
}

pub fn finalizeTransaction(self: *Overlay, finalizer: anytype) !void {
    var finalized_accounts: std.ArrayList(Address) = .empty;
    defer finalized_accounts.deinit(self.allocator);
    var newly_deleted_accounts: std.ArrayList(Address) = .empty;
    defer newly_deleted_accounts.deinit(self.allocator);
    var removed_storage_keys: std.ArrayList(StorageKey) = .empty;
    defer removed_storage_keys.deinit(self.allocator);

    const mutation_checkpoint = self.journal.checkpoint(self.logs.items.len);
    errdefer self.rollbackInternalCheckpoint(mutation_checkpoint);

    var it = self.selfdestructed_accounts.keyIterator();
    while (it.next()) |address| {
        try self.journal.append(self.allocator, .{ .selfdestruct_cleared = address.* });
        const policy: evmz.protocol.SelfDestructFinalization =
            finalizer.selfDestructFinalization(self.created_contracts.contains(address.*));
        if (policy.clear_storage) {
            try self.journalStorageOverlayRemovedForAddress(address.*, &removed_storage_keys);
            try self.journalStorageSlotsClearedForAddress(address.*);
        }
        if (policy.reset_account) {
            if (self.accounts.contains(address.*)) {
                try self.setCode(address.*, &.{});
                try self.setNonce(address.*, 0);
            }
        }
        if (!policy.delete_account) {
            continue;
        }
        try finalized_accounts.append(self.allocator, address.*);
        try self.journalAccountRemoved(address.*);
        if (!self.deleted_accounts.contains(address.*)) {
            try newly_deleted_accounts.append(self.allocator, address.*);
            try self.journal.append(self.allocator, .{ .deleted_account_marked = address.* });
        }
    }

    var created_it = self.created_contracts.keyIterator();
    while (created_it.next()) |address| {
        try self.journal.append(self.allocator, .{ .created_contract_cleared = address.* });
    }

    if (self.state_resources) |resources| {
        if (@as(usize, self.deleted_accounts.count()) + newly_deleted_accounts.items.len > resources.deleted_accounts) {
            return error.DeletedAccountCapacityExceeded;
        }
    } else {
        try self.deleted_accounts.ensureUnusedCapacity(@intCast(newly_deleted_accounts.items.len));
    }

    for (finalized_accounts.items) |address| {
        _ = self.accounts.remove(address);
        try self.traceStateWrite(.{
            .account_deleted = .{
                .address = address,
            },
        });
    }
    for (removed_storage_keys.items) |key| {
        _ = self.storage_overlay.remove(key);
    }
    for (newly_deleted_accounts.items) |address| {
        if (self.state_resources != null) {
            try self.putDeletedAccount(address);
        } else {
            self.deleted_accounts.putAssumeCapacity(address, {});
        }
    }

    self.selfdestructed_accounts.clearRetainingCapacity();
    self.created_contracts.clearRetainingCapacity();
}

pub fn changeset(self: *Overlay) !Changeset {
    var result = Changeset.init();
    errdefer result.deinit(self.allocator);

    var dirty_it = self.dirty_accounts.keyIterator();
    while (dirty_it.next()) |dirty_address| {
        const address = dirty_address.*;
        if (self.deleted_accounts.contains(address)) continue;
        const account = self.accounts.getPtr(address) orelse continue;

        try result.account_updates.append(self.allocator, .{
            .address = address,
            .nonce = account.nonce,
            .balance = account.balance,
            .code_hash = account.code_hash,
        });
    }

    var code_it = self.code_cache.iterator();
    while (code_it.next()) |entry| {
        if (!entry.value_ptr.introduced) continue;
        if (!self.finalStateUsesCodeHash(entry.key_ptr.*)) continue;
        const owned = try self.allocator.dupe(u8, entry.value_ptr.bytes);
        errdefer self.allocator.free(owned);
        try result.code_inserts.append(self.allocator, .{
            .code_hash = entry.key_ptr.*,
            .code = owned,
        });
    }

    var deleted_it = self.deleted_accounts.keyIterator();
    while (deleted_it.next()) |address| {
        try result.account_deletes.append(self.allocator, address.*);
    }

    var storage_it = self.storage_overlay.iterator();
    while (storage_it.next()) |entry| {
        if (self.deleted_accounts.contains(entry.key_ptr.address)) continue;
        const value = if (self.storage_slots.get(entry.key_ptr.*)) |slot|
            if (slot.dirty) slot.current else entry.value_ptr.*
        else
            entry.value_ptr.*;
        try result.storage_writes.append(self.allocator, .{
            .address = entry.key_ptr.address,
            .key = entry.key_ptr.key,
            .value = value,
        });
    }

    var slot_it = self.storage_slots.iterator();
    while (slot_it.next()) |entry| {
        if (!entry.value_ptr.dirty) continue;
        if (self.deleted_accounts.contains(entry.key_ptr.address)) continue;
        if (self.storage_overlay.contains(entry.key_ptr.*)) continue;
        try result.storage_writes.append(self.allocator, .{
            .address = entry.key_ptr.address,
            .key = entry.key_ptr.key,
            .value = entry.value_ptr.current,
        });
    }

    result.sort();
    return result;
}

fn finalStateUsesCodeHash(self: *Overlay, code_hash: [32]u8) bool {
    var dirty_it = self.dirty_accounts.keyIterator();
    while (dirty_it.next()) |address| {
        if (self.deleted_accounts.contains(address.*)) continue;
        const account = self.accounts.getPtr(address.*) orelse continue;
        if (std.mem.eql(u8, &account.code_hash, &code_hash)) return true;
    }
    return false;
}

fn journalAccountRemoved(self: *Overlay, address: Address) !void {
    const prev: ?Account = if (self.accounts.getPtr(address)) |account|
        account.*
    else
        null;

    try self.journal.append(self.allocator, .{ .account_removed = .{
        .address = address,
        .prev = prev,
    } });
}

fn journalStorageOverlayRemovedForAddress(
    self: *Overlay,
    address: Address,
    removed_keys: *std.ArrayList(StorageKey),
) !void {
    var it = self.storage_overlay.iterator();
    while (it.next()) |entry| {
        if (std.mem.eql(u8, &entry.key_ptr.address, &address)) {
            try removed_keys.append(self.allocator, entry.key_ptr.*);
            try self.journal.append(self.allocator, .{ .storage_overlay_removed = .{
                .key = entry.key_ptr.*,
                .prev = entry.value_ptr.*,
            } });
        }
    }
}

fn journalStorageSlotsClearedForAddress(self: *Overlay, address: Address) !void {
    var it = self.storage_slots.iterator();
    while (it.next()) |entry| {
        if (!std.mem.eql(u8, &entry.key_ptr.address, &address)) continue;
        const slot = entry.value_ptr;
        if (!slot.loaded) continue;

        try self.journal.append(self.allocator, .{ .storage_slot = .{
            .key = entry.key_ptr.*,
            .prev = slot.current,
            .dirty = slot.dirty,
        } });
        if (slot.dirty and !slot.overlay_present) {
            std.debug.assert(self.pending_storage_overlay_entries > 0);
            self.pending_storage_overlay_entries -= 1;
        }
        slot.current = 0;
        slot.dirty = false;
    }
}

pub fn snapshotTransient(self: *Overlay) !TransientSnapshot {
    var result = TransientSnapshot{
        .transient_storage = TransientStorageMap.init(self.allocator),
    };
    errdefer result.deinit(self.allocator);

    var transient_it = self.transient_storage.iterator();
    while (transient_it.next()) |entry| {
        try result.transient_storage.put(entry.key_ptr.*, entry.value_ptr.*);
    }

    return result;
}

pub fn restoreTransient(self: *Overlay, snapshot_state: *TransientSnapshot) !void {
    self.transient_storage.clearRetainingCapacity();

    var transient_it = snapshot_state.transient_storage.iterator();
    while (transient_it.next()) |entry| {
        self.putTransientStorageAssumeCapacity(entry.key_ptr.*, entry.value_ptr.*);
    }
}

pub const Snapshot = struct {
    accounts: AccountMap,
    warm_accounts: AddressSet,
    storage_slots: StorageSlotMap,
    warm_storage_count: usize,
    original_storage_count: usize,
    pending_storage_overlay_entries: usize,
    storage_overlay: StorageMap,
    transient_storage: TransientStorageMap,
    selfdestructed_accounts: AddressSet,
    created_contracts: AddressSet,
    deleted_accounts: AddressSet,
    dirty_accounts: AddressSet,
    logs_len: usize,
    journal_len: usize,

    pub fn deinit(self: *Snapshot, allocator: std.mem.Allocator) void {
        _ = allocator;
        self.accounts.deinit();
        self.warm_accounts.deinit();
        self.storage_slots.deinit();
        self.storage_overlay.deinit();
        self.transient_storage.deinit();
        self.selfdestructed_accounts.deinit();
        self.created_contracts.deinit();
        self.deleted_accounts.deinit();
        self.dirty_accounts.deinit();
    }
};

pub const TransientSnapshot = struct {
    transient_storage: TransientStorageMap,

    pub fn deinit(self: *TransientSnapshot, allocator: std.mem.Allocator) void {
        _ = allocator;
        self.transient_storage.deinit();
    }
};

test "code view returns the canonical hash and preserves code-read tracing" {
    const address = evmz.addr(0xabc);
    const code = [_]u8{ 0x60, 0x00 };
    var overlay = Overlay.init(std.testing.allocator);
    defer overlay.deinit();

    try overlay.setCode(address, &code);

    var recorder = CodeReadRecorder{};
    var sink = recorder.sink();
    var context = CaptureContext.init(std.testing.allocator, null, capture_runtime.stateTargetForSink(&sink));
    defer context.deinit();
    overlay.capture_context = &context;
    try context.begin();
    defer {
        if (context.isActive()) context.abort() catch {};
        overlay.capture_context = null;
    }
    overlay.trace_depth = 3;

    const view = try overlay.getCodeView(address);
    try std.testing.expectEqualSlices(u8, &evmz.crypto.keccak256(&code), &view.code_hash);
    try std.testing.expectEqualSlices(u8, &code, view.bytes);
    try std.testing.expectEqual(@as(usize, 1), recorder.reads);
    try std.testing.expectEqual(@as(u16, 3), recorder.last.depth);
    try std.testing.expectEqualSlices(u8, &address, &recorder.last.address);
    try std.testing.expectEqual(code.len, recorder.last.size);

    try std.testing.expectEqualSlices(u8, &code, try overlay.getCode(address));
    try std.testing.expectEqual(@as(usize, 2), recorder.reads);

    const empty_view = try overlay.getCodeView(evmz.addr(0xdef));
    try std.testing.expectEqualSlices(u8, &evmz.crypto.keccak256_empty, &empty_view.code_hash);
    try std.testing.expectEqual(@as(usize, 0), empty_view.bytes.len);
    _ = try context.finish();
}

const CodeReadRecorder = struct {
    reads: usize = 0,
    last: trace.CodeRead = undefined,

    fn sink(self: *CodeReadRecorder) trace.Sink {
        return trace.Sink.init(self, .{
            .state_read = trace.StateReadKinds.initMany(&.{.code}),
        }, &.{
            .stateRead = stateRead,
        });
    }

    fn stateRead(ptr: *anyopaque, event: trace.StateRead) void {
        const self: *CodeReadRecorder = @ptrCast(@alignCast(ptr));
        self.last = switch (event) {
            .code => |payload| payload,
            else => unreachable,
        };
        self.reads += 1;
    }
};

test {
    _ = @import("./Overlay_test.zig");
}
