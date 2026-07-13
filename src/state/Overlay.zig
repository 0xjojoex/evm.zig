//! Executor-owned execution overlay for a transaction or nested call.
//!
//! `StateReader` provides canonical reads. `Overlay` owns loaded accounts, writes,
//! warm access state, transient storage, logs, snapshots, reverts, and the
//! execution journal.

const std = @import("std");
const evmz = @import("../evm.zig");
const Host = @import("../Host.zig");
const trace = @import("../trace.zig");
const Address = evmz.Address;
const Account = @import("./Account.zig");
const MemoryAccount = @import("./MemoryAccount.zig");
const storage = @import("./storage.zig");
const StorageKey = storage.Key;
const StateReader = @import("./Reader.zig");
const Changeset = @import("./Changeset.zig");
const Journal = @import("./Journal.zig");
const mpt = @import("../mpt.zig");
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
const StorageSet = SparseHashMap(StorageKey, void);
const StorageMap = SparseHashMap(StorageKey, u256);
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
warm_storage: StorageSet,
access_resources: ?AccessResources,
original_storage: StorageMap,
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
trace_sink: ?*trace.Sink,
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
        .warm_storage = StorageSet.init(allocator),
        .access_resources = null,
        .original_storage = StorageMap.init(allocator),
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
        .trace_sink = null,
        .trace_depth = 0,
    };
}

pub fn initWithStateReader(allocator: std.mem.Allocator, state_reader: StateReader) Overlay {
    var result = Overlay.init(allocator);
    result.state_reader = state_reader;
    return result;
}

/// Clear all semantic overlay state while keeping configured backing capacity.
pub fn reset(self: *Overlay, state_reader: ?StateReader, trace_sink: ?*trace.Sink) void {
    self.discardChanges();
    self.state_reader = state_reader;
    self.trace_sink = trace_sink;
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
    self.warm_storage.deinit();
    self.original_storage.deinit();
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
    if (self.warm_accounts.count() != 0 or self.warm_storage.count() != 0) return error.ActiveAccessState;
    if (resources) |bounded| {
        try self.warm_accounts.ensureTotalCapacity(try accessHashMapCapacity(bounded.accounts));
        try self.warm_storage.ensureTotalCapacity(try accessHashMapCapacity(bounded.storage_keys));
        self.access_resources = bounded;
    } else {
        self.access_resources = null;
    }
}

pub fn reserveAccessHint(self: *Overlay, resources: AccessResources) !void {
    if (self.access_resources != null) return;
    const account_capacity = std.math.add(usize, self.warm_accounts.count(), resources.accounts) catch return error.AccessCapacityTooLarge;
    const storage_capacity = std.math.add(usize, self.warm_storage.count(), resources.storage_keys) catch return error.AccessCapacityTooLarge;
    try self.warm_accounts.ensureTotalCapacity(try accessHintCapacity(account_capacity));
    try self.warm_storage.ensureTotalCapacity(try accessHintCapacity(storage_capacity));
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
            self.original_storage.count() != 0 or
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
        try self.original_storage.ensureTotalCapacity(try hashMapCapacity(bounded.original_storage_entries));
        try self.storage_overlay.ensureTotalCapacity(try hashMapCapacity(bounded.storage_overlay_entries));
        try self.selfdestructed_accounts.ensureTotalCapacity(try hashMapCapacity(bounded.selfdestructed_accounts));
        try self.created_contracts.ensureTotalCapacity(try hashMapCapacity(bounded.created_contracts));
        try self.deleted_accounts.ensureTotalCapacity(try hashMapCapacity(bounded.deleted_accounts));
        try self.dirty_accounts.ensureTotalCapacity(try hashMapCapacity(bounded.dirty_accounts));
        self.state_resources = bounded;
    } else {
        if (self.code_cache.count() != 0) return error.ActiveStateOverlay;
        self.state_resources = null;
        self.bounded_code_data.deinit(self.allocator);
        self.bounded_code_data = .empty;
    }
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

    const code_hash = account.code_hash orelse mpt.codeHash(account.code);
    if (!std.mem.eql(u8, &mpt.codeHash(account.code), &code_hash)) return error.CodeHashMismatch;

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
    if (std.mem.eql(u8, &code_hash, &mpt.empty_code_hash)) return &.{};
    if (self.code_cache.get(code_hash)) |entry| return entry.bytes;
    const state_reader = self.state_reader orelse return error.CodeUnavailable;
    return try self.cacheCode(code_hash, try state_reader.loadCode(code_hash), false);
}

fn cacheCode(self: *Overlay, code_hash: [32]u8, code: []const u8, introduced: bool) ![]const u8 {
    std.debug.assert(std.mem.eql(u8, &mpt.codeHash(code), &code_hash));
    if (std.mem.eql(u8, &code_hash, &mpt.empty_code_hash)) return &.{};
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
    self.traceStateRead(.{
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
            .code_hash = mpt.empty_code_hash,
            .bytes = &.{},
        };
    self.traceStateRead(.{
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
    return !std.mem.eql(u8, &account.code_hash, &mpt.empty_code_hash);
}

pub fn getBalance(self: *Overlay, address: Address) !u256 {
    const balance = if (try self.getAccountOrLoad(address)) |account| account.balance else 0;
    self.traceStateRead(.{
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
    errdefer self.discardLastJournalEntry();
    const newly_dirty = try self.markAccountDirty(address);
    errdefer if (newly_dirty) self.undoAccountDirtyMark(address);

    account.balance = value;
    self.traceStateWrite(.{
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
    const account = try self.getAccountOrLoad(address) orelse return false;
    if (account.balance < value) return false;
    try self.journal.append(self.allocator, .{ .balance = .{
        .address = address,
        .prev = account.balance,
    } });
    errdefer self.discardLastJournalEntry();
    const newly_dirty = try self.markAccountDirty(address);
    errdefer if (newly_dirty) self.undoAccountDirtyMark(address);

    const previous = account.balance;
    account.balance -= value;
    self.traceStateWrite(.{
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
    errdefer self.discardLastJournalEntry();
    const newly_dirty = try self.markAccountDirty(address);
    errdefer if (newly_dirty) self.undoAccountDirtyMark(address);

    const previous = account.nonce;
    account.nonce = value;
    self.traceStateWrite(.{
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
    errdefer self.discardLastJournalEntry();
    const newly_dirty = try self.markAccountDirty(address);
    errdefer if (newly_dirty) self.undoAccountDirtyMark(address);

    const code_hash = mpt.codeHash(code);
    _ = try self.cacheCode(code_hash, code, true);
    account.code_hash = code_hash;
    self.traceStateWrite(.{
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

pub fn getStorage(self: *Overlay, address: Address, key: u256) !u256 {
    const storage_key = StorageKey{ .address = address, .key = key };
    const value = blk: {
        if (self.deleted_accounts.count() != 0 and self.deleted_accounts.contains(address)) break :blk 0;
        if (self.storage_overlay.count() != 0) {
            if (self.storage_overlay.get(storage_key)) |overlay_value| break :blk overlay_value;
        }
        if (self.seeded_storage.get(storage_key)) |seeded_value| break :blk seeded_value;
        const state_reader = self.state_reader orelse break :blk 0;
        break :blk try state_reader.getStorage(address, key);
    };
    self.traceStateRead(.{
        .storage = .{
            .address = address,
            .key = key,
            .value = value,
        },
    });
    return value;
}

pub fn setStorage(self: *Overlay, address: Address, key: u256, value: u256) !Host.StorageStatus {
    const storage_key = StorageKey{ .address = address, .key = key };
    const overlay_prev = self.storage_overlay.get(storage_key);
    if (overlay_prev) |current| {
        if (current == value) return .assigned;
    }

    const mutation_checkpoint = self.journal.checkpoint(self.logs.items.len);
    errdefer self.rollbackInternalCheckpoint(mutation_checkpoint);

    const original_entry = try self.getOrPutOriginalStorage(storage_key);
    const had_original = original_entry.found_existing;
    if (!had_original) {
        original_entry.value_ptr.* = try self.getStorage(address, key);
    }
    errdefer {
        if (!had_original) _ = self.original_storage.remove(storage_key);
    }
    const original = original_entry.value_ptr.*;
    const current = if (had_original) overlay_prev orelse try self.getStorage(address, key) else original;
    const status = storage.status(original, current, value);
    if (current == value) return status;

    _ = try self.getOrCreateAccount(address);

    try self.journal.append(self.allocator, .{ .storage = .{
        .address = address,
        .key = key,
        .overlay_had = overlay_prev != null,
        .overlay_prev = overlay_prev orelse 0,
    } });
    errdefer self.discardLastJournalEntry();

    try self.putStorageOverlay(storage_key, value);
    self.traceStateWrite(.{
        .storage = .{
            .address = address,
            .key = key,
            .previous = current,
            .value = value,
        },
    });
    return status;
}

pub fn originalStorage(self: *Overlay, address: Address, key: u256) !u256 {
    const storage_key = StorageKey{ .address = address, .key = key };
    if (self.original_storage.get(storage_key)) |value| return value;
    const value = try self.getStorage(address, key);
    try self.putOriginalStorage(storage_key, value);
    return value;
}

fn getOrPutOriginalStorage(self: *Overlay, storage_key: StorageKey) !StorageMap.GetOrPutResult {
    if (self.state_resources) |resources| {
        assertBoundedMapSlack(&self.original_storage, resources.original_storage_entries);
        const result = self.original_storage.getOrPutAssumeCapacity(storage_key);
        if (!result.found_existing and @as(usize, self.original_storage.count()) > resources.original_storage_entries) {
            _ = self.original_storage.remove(storage_key);
            return error.OriginalStorageCapacityExceeded;
        }
        return result;
    }
    return try self.original_storage.getOrPut(storage_key);
}

fn putOriginalStorage(self: *Overlay, storage_key: StorageKey, value: u256) !void {
    if (self.state_resources) |resources| {
        try putBoundedStorageMap(
            &self.original_storage,
            storage_key,
            value,
            resources.original_storage_entries,
            error.OriginalStorageCapacityExceeded,
        );
        return;
    }
    try self.original_storage.put(storage_key, value);
}

fn putStorageOverlay(self: *Overlay, storage_key: StorageKey, value: u256) !void {
    if (self.state_resources) |resources| {
        try putBoundedStorageMap(
            &self.storage_overlay,
            storage_key,
            value,
            resources.storage_overlay_entries,
            error.StorageOverlayCapacityExceeded,
        );
        return;
    }
    try self.storage_overlay.put(storage_key, value);
}

fn putBoundedStorageMap(
    map: *StorageMap,
    storage_key: StorageKey,
    value: u256,
    entry_limit: usize,
    comptime capacity_error: anyerror,
) !void {
    assertBoundedMapSlack(map, entry_limit);
    const result = map.getOrPutAssumeCapacity(storage_key);
    if (!result.found_existing and @as(usize, map.count()) > entry_limit) {
        _ = map.remove(storage_key);
        return capacity_error;
    }
    result.value_ptr.* = value;
}

pub fn accountHasStorage(self: *Overlay, address: Address) !bool {
    const result = try self.accountHasStorageInner(address);
    self.traceStateRead(.{
        .account_has_storage = .{
            .address = address,
            .exists = result,
        },
    });
    return result;
}

fn accountHasStorageInner(self: *Overlay, address: Address) !bool {
    if (self.deleted_accounts.contains(address)) return false;
    var overlay_it = self.storage_overlay.iterator();
    while (overlay_it.next()) |entry| {
        if (entry.value_ptr.* != 0 and std.mem.eql(u8, &entry.key_ptr.address, &address)) return true;
    }
    var seeded_it = self.seeded_storage.iterator();
    while (seeded_it.next()) |entry| {
        if (std.mem.eql(u8, &entry.key_ptr.address, &address)) {
            if (entry.value_ptr.* == 0) continue;
            if (self.storage_overlay.get(entry.key_ptr.*)) |overlay_value| {
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
}

pub fn closeTransaction(self: *Overlay) void {
    self.warm_accounts.clearRetainingCapacity();
    self.warm_storage.clearRetainingCapacity();
    self.transient_storage.clearRetainingCapacity();
    self.original_storage.clearRetainingCapacity();
    self.journal.clearRetainingCapacity(self.allocator);
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

pub fn warmAccount(self: *Overlay, address: Address) !void {
    if (self.warm_accounts.contains(address)) return;
    try self.journal.append(self.allocator, .{ .warm_account = address });
    errdefer self.discardLastJournalEntry();
    try self.putWarmAccount(address);
    self.traceStateWrite(.{
        .warm_account = .{
            .address = address,
        },
    });
}

pub fn warmStorage(self: *Overlay, address: Address, key: u256) !void {
    const storage_key = StorageKey{ .address = address, .key = key };
    if (self.warm_storage.contains(storage_key)) return;
    try self.journal.append(self.allocator, .{ .warm_storage = storage_key });
    errdefer self.discardLastJournalEntry();
    try self.putWarmStorage(storage_key);
    self.traceStateWrite(.{
        .warm_storage = .{
            .address = address,
            .key = key,
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

fn putWarmStorage(self: *Overlay, storage_key: StorageKey) !void {
    if (self.access_resources) |resources| {
        try putBoundedStorageSet(&self.warm_storage, storage_key, resources.storage_keys, error.WarmStorageCapacityExceeded);
        return;
    }
    try self.warm_storage.put(storage_key, {});
}

pub fn getTransientStorage(self: *Overlay, address: Address, key: u256) u256 {
    const value = self.transient_storage.get(.{ .address = address, .key = key }) orelse 0;
    self.traceStateRead(.{
        .transient_storage = .{
            .address = address,
            .key = key,
            .value = value,
        },
    });
    return value;
}

pub fn setTransientStorage(self: *Overlay, address: Address, key: u256, value: u256) !void {
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
    self.traceStateWrite(.{
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
    if (self.log_resources != null) {
        try self.emitBoundedLog(event_log);
        return;
    }

    const topics = try self.allocator.dupe(u256, event_log.topics);
    errdefer self.allocator.free(topics);
    const data = try self.allocator.dupe(u8, event_log.data);
    errdefer self.allocator.free(data);
    try self.logs.append(self.allocator, .{
        .address = event_log.address,
        .topics = topics,
        .data = data,
    });
    self.traceStateWrite(.{
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
    self.traceStateWrite(.{
        .log = .{
            .address = event_log.address,
            .topics_len = event_log.topics.len,
            .data_size = event_log.data.len,
        },
    });
}

pub fn markCreatedContract(self: *Overlay, address: Address) !void {
    if (self.created_contracts.contains(address)) return;
    try self.journal.append(self.allocator, .{ .created_contract = address });
    errdefer self.discardLastJournalEntry();
    try self.putCreatedContract(address);
    self.traceStateWrite(.{
        .created_contract = .{
            .address = address,
        },
    });
}

pub fn markSelfdestructed(self: *Overlay, address: Address) !void {
    if (self.selfdestructed_accounts.contains(address)) return;
    try self.journal.append(self.allocator, .{ .selfdestruct = address });
    errdefer self.discardLastJournalEntry();
    try self.putSelfdestructedAccount(address);
    self.traceStateWrite(.{
        .selfdestruct = .{
            .address = address,
        },
    });
}

pub fn checkpoint(self: *const Overlay) Journal.Checkpoint {
    const checkpoint_state = self.journal.checkpoint(self.logs.items.len);
    self.traceCheckpoint(.checkpoint, checkpoint_state);
    return checkpoint_state;
}

pub fn commitCheckpoint(self: *Overlay, checkpoint_state: Journal.Checkpoint) void {
    self.traceCheckpoint(.commit, checkpoint_state);
}

pub fn revertToCheckpoint(self: *Overlay, checkpoint_state: Journal.Checkpoint) !void {
    while (self.journal.len() > checkpoint_state.journal_len) {
        var entry = self.journal.pop().?;
        defer entry.deinit(self.allocator);
        try self.revertJournalEntry(&entry);
    }
    self.truncateLogs(checkpoint_state.logs_len);
    self.traceCheckpoint(.revert, checkpoint_state);
}

fn rollbackInternalCheckpoint(self: *Overlay, checkpoint_state: Journal.Checkpoint) void {
    while (self.journal.len() > checkpoint_state.journal_len) {
        var entry = self.journal.pop().?;
        defer entry.deinit(self.allocator);
        self.revertJournalEntry(&entry) catch unreachable;
    }
    self.truncateLogs(checkpoint_state.logs_len);
}

fn revertJournalEntry(self: *Overlay, entry: *Journal.Entry) !void {
    switch (entry.*) {
        .account_created => |address| {
            _ = self.accounts.remove(address);
        },
        .deleted_account_revived => |address| {
            _ = self.accounts.remove(address);
            try self.putDeletedAccount(address);
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
                try self.putAccount(removed.address, account);
                removed.prev = null;
            }
        },
        .storage => |storage_entry| {
            const storage_key = StorageKey{ .address = storage_entry.address, .key = storage_entry.key };
            if (storage_entry.overlay_had) {
                try self.putStorageOverlay(storage_key, storage_entry.overlay_prev);
            } else {
                _ = self.storage_overlay.remove(storage_key);
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
        .warm_storage => |storage_key| {
            _ = self.warm_storage.remove(storage_key);
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
            try self.putCreatedContract(address);
        },
        .selfdestruct_cleared => |address| {
            try self.putSelfdestructedAccount(address);
        },
        .storage_overlay_removed => |removed| {
            try self.putStorageOverlay(removed.key, removed.prev);
        },
    }
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

fn putBoundedStorageSet(
    set: *StorageSet,
    storage_key: StorageKey,
    entry_limit: usize,
    comptime capacity_error: anyerror,
) !void {
    assertBoundedMapSlack(set, entry_limit);
    const result = set.getOrPutAssumeCapacity(storage_key);
    if (!result.found_existing and @as(usize, set.count()) > entry_limit) {
        _ = set.remove(storage_key);
        return capacity_error;
    }
    result.value_ptr.* = {};
}

fn assertBoundedMapSlack(map: anytype, entry_limit: usize) void {
    std.debug.assert(@as(usize, map.capacity()) > entry_limit);
}

fn undoAccountDirtyMark(self: *Overlay, address: Address) void {
    _ = self.dirty_accounts.remove(address);
    self.discardLastJournalEntry();
}

fn traceStateRead(self: *const Overlay, event: trace.StateRead) void {
    const sink = self.trace_sink orelse return;
    if (!sink.wantsStateReadKind(event.kind())) return;
    sink.stateRead(event.withDepth(self.trace_depth));
}

fn traceStateWrite(self: *const Overlay, event: trace.StateWrite) void {
    const sink = self.trace_sink orelse return;
    if (!sink.wantsStateWriteKind(event.kind())) return;
    sink.stateWrite(event.withDepth(self.trace_depth));
}

fn traceCheckpoint(self: *const Overlay, kind: trace.CheckpointKind, checkpoint_state: Journal.Checkpoint) void {
    const sink = self.trace_sink orelse return;
    if (!sink.wantsCheckpoint()) return;
    sink.checkpoint(.{
        .kind = kind,
        .depth = self.trace_depth,
        .journal_len = checkpoint_state.journal_len,
        .logs_len = checkpoint_state.logs_len,
    });
}

fn discardLastJournalEntry(self: *Overlay) void {
    var entry = self.journal.pop() orelse return;
    entry.deinit(self.allocator);
}

pub fn snapshot(self: *Overlay) !Snapshot {
    var result = Snapshot{
        .accounts = AccountMap.init(self.allocator),
        .warm_accounts = AddressSet.init(self.allocator),
        .warm_storage = StorageSet.init(self.allocator),
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

    var warm_storage_it = self.warm_storage.keyIterator();
    while (warm_storage_it.next()) |key| {
        try result.warm_storage.put(key.*, {});
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
pub fn traceSnapshotLifecycle(self: *const Overlay, kind: trace.CheckpointKind, snapshot_state: *const Snapshot) void {
    self.traceCheckpoint(kind, .{
        .journal_len = snapshot_state.journal_len,
        .logs_len = snapshot_state.logs_len,
    });
}

fn restoreFromSnapshot(self: *Overlay, snapshot_state: *Snapshot) !void {
    self.clearAccounts();
    self.warm_accounts.clearRetainingCapacity();
    self.warm_storage.clearRetainingCapacity();
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

    var warm_storage_it = snapshot_state.warm_storage.keyIterator();
    while (warm_storage_it.next()) |key| {
        try self.putWarmStorage(key.*);
    }

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

pub fn finalizeTransaction(self: *Overlay, finalizer: anytype) !void {
    var finalized_accounts: std.ArrayList(Address) = .empty;
    defer finalized_accounts.deinit(self.allocator);
    var newly_deleted_accounts: std.ArrayList(Address) = .empty;
    defer newly_deleted_accounts.deinit(self.allocator);
    var removed_storage_keys: std.ArrayList(StorageKey) = .empty;
    defer removed_storage_keys.deinit(self.allocator);

    const journal_len = self.journal.len();
    errdefer self.journal.truncate(self.allocator, journal_len);

    var it = self.selfdestructed_accounts.keyIterator();
    while (it.next()) |address| {
        try self.journal.append(self.allocator, .{ .selfdestruct_cleared = address.* });
        const policy: evmz.protocol.SelfDestructFinalization =
            finalizer.selfDestructFinalization(self.created_contracts.contains(address.*));
        if (policy.clear_storage) {
            try self.journalStorageOverlayRemovedForAddress(address.*, &removed_storage_keys);
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
        self.traceStateWrite(.{
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
        try result.storage_writes.append(self.allocator, .{
            .address = entry.key_ptr.address,
            .key = entry.key_ptr.key,
            .value = entry.value_ptr.*,
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
    warm_storage: StorageSet,
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
        self.warm_storage.deinit();
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
    overlay.trace_sink = &sink;
    overlay.trace_depth = 3;

    const view = try overlay.getCodeView(address);
    try std.testing.expectEqualSlices(u8, &mpt.codeHash(&code), &view.code_hash);
    try std.testing.expectEqualSlices(u8, &code, view.bytes);
    try std.testing.expectEqual(@as(usize, 1), recorder.reads);
    try std.testing.expectEqual(@as(u16, 3), recorder.last.depth);
    try std.testing.expectEqualSlices(u8, &address, &recorder.last.address);
    try std.testing.expectEqual(code.len, recorder.last.size);

    try std.testing.expectEqualSlices(u8, &code, try overlay.getCode(address));
    try std.testing.expectEqual(@as(usize, 2), recorder.reads);

    const empty_view = try overlay.getCodeView(evmz.addr(0xdef));
    try std.testing.expectEqualSlices(u8, &mpt.empty_code_hash, &empty_view.code_hash);
    try std.testing.expectEqual(@as(usize, 0), empty_view.bytes.len);
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
