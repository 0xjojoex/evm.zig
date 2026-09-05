//! Open execution world: rows are admitted on first access by loading the
//! parent value from a `Reader`.
//!
//! The world for block building, BAL discovery, and every fork without a
//! block access list. Anything unknown is fetchable: a miss loads the parent
//! account or slot, normalizes it the way the fork sees existence, and
//! inserts a complete row. A row is inserted only after its load succeeded,
//! so a reader failure never leaves a half row behind. Rows are dense and
//! keep their identity during execution. `resetRows` and branch restore drop
//! rows from the tail; fixture seeding may reorder them and invalidates state
//! snapshots before doing so.
//!
//! Parent code is cached here, content-addressed, so the state machine's
//! code store only ever holds code introduced during the block.
//!
//! Rows are keyed by `AddressWord` (see `world_state`); the reader speaks
//! `Address`, so the conversion happens once per admission, not per lookup.

const std = @import("std");

const crypto = @import("../crypto.zig");
const state_types = @import("../state.zig");
const world_state = @import("./world_state.zig");
const Account = @import("./Account.zig");
const MemoryAccount = @import("./MemoryAccount.zig");
const Reader = @import("./Reader.zig");
const sparse_hash_map = @import("./sparse_hash_map.zig");
const range = @import("stdx").range;

const Allocator = std.mem.Allocator;
const Address = @import("../address.zig").Address;
const AddressWord = @import("../address.zig").AddressWord;
const AccessHint = state_types.AccessHint;
const CodeView = state_types.CodeView;
const AccountRow = world_state.AccountRow;
const StorageRow = world_state.StorageRow;
const RowSnapshot = world_state.RowSnapshot;
const ResolutionPolicy = world_state.ResolutionPolicy;
const CodeHash = [32]u8;
const ByteRange = range.Bytes;

const OpenWorld = @This();

pub const AccountMap = sparse_hash_map.WithContext(AddressWord, AccountRow, AddressWord.HashContext);
pub const AccountId = AccountMap.EntryId;

/// Slots are keyed by the owning row, not its address: the account resolves
/// first, and the id is what every storage-side lookup already holds.
pub const StorageKey = struct {
    account: AccountId,
    slot: u256,
};
pub const StorageMap = sparse_hash_map.Auto(StorageKey, StorageRow);
pub const StorageId = StorageMap.EntryId;

/// A reader answers with any error; the world adds nothing of its own.
pub const ResolutionError = anyerror;

pub const options: world_state.Options = .{
    // Rows are admitted as execution touches state, so capacity hints are meaningful.
    .grows_on_touch = true,
    // Parent facts come from a reader the world does not authenticate; the
    // committer resolves parents from the witness by key.
    .authenticated_parents = false,
    // Parent code loads through the reader into the world's own cache.
    .caches_parent_code = true,
};

const CodeMap = sparse_hash_map.Auto(CodeHash, CodeEntry);
const minimum_code_chunk_bytes = 4096;

reader: ?Reader,
/// Pre-Spurious-Dragon only. See `Spec.retains_empty_accounts`; a loaded
/// EIP-161-empty account is absent unless the fork keeps such accounts.
retains_empty_accounts: bool = false,
accounts: AccountMap,
storage: StorageMap,
code: CodeCache,

pub fn init(allocator: Allocator, reader: ?Reader) OpenWorld {
    return .{
        .reader = reader,
        .accounts = AccountMap.init(allocator),
        .storage = StorageMap.init(allocator),
        .code = CodeCache.init(allocator),
    };
}

/// The world for one exact execution spec.
pub fn initForSpec(allocator: Allocator, comptime spec: anytype, reader: ?Reader) OpenWorld {
    var world = init(allocator, reader);
    world.retains_empty_accounts = spec.retains_empty_accounts;
    return world;
}

pub fn deinit(self: *OpenWorld, allocator: Allocator) void {
    self.accounts.deinit();
    self.storage.deinit();
    self.code.deinit(allocator);
    self.* = undefined;
}

pub fn accountCount(self: *const OpenWorld) u32 {
    return self.accounts.count();
}

pub inline fn accountRow(self: *const OpenWorld, id: AccountId) *AccountRow {
    return self.accounts.valuePtrById(id);
}

pub inline fn storageRow(self: *const OpenWorld, id: StorageId) *StorageRow {
    return self.storage.valuePtrById(id);
}

pub fn accountAddress(self: *const OpenWorld, id: AccountId) Address {
    return self.accounts.keyById(id).address();
}

pub fn storageAccount(self: *const OpenWorld, id: StorageId) AccountId {
    return self.storage.keyById(id).account;
}

pub fn storageSlot(self: *const OpenWorld, id: StorageId) u256 {
    return self.storage.keyById(id).slot;
}

pub fn findAccount(self: *OpenWorld, address_word: AddressWord) ?AccountId {
    return self.accounts.getEntryId(address_word);
}

pub fn findStorage(self: *OpenWorld, account: AccountId, slot: u256) ?StorageId {
    return self.storage.getEntryId(.{ .account = account, .slot = slot });
}

/// Warm-only misses have no parent-value requirement and admit no row.
pub fn resolveAccount(
    self: *OpenWorld,
    address_word: AddressWord,
    policy: ResolutionPolicy,
) ResolutionError!?AccountId {
    if (self.accounts.getEntryId(address_word)) |id| return id;
    if (policy == .optional_warm_only) return null;
    return try self.admitAccount(address_word);
}

pub fn resolveStorage(
    self: *OpenWorld,
    account: AccountId,
    slot: u256,
    policy: ResolutionPolicy,
) ResolutionError!?StorageId {
    const key: StorageKey = .{ .account = account, .slot = slot };
    if (self.storage.getEntryId(key)) |id| return id;
    if (policy == .optional_warm_only) return null;
    return try self.admitStorage(key);
}

noinline fn admitAccount(self: *OpenWorld, address_word: AddressWord) ResolutionError!AccountId {
    const current = try self.loadAccount(address_word.address());
    try self.accounts.ensureUnusedCapacity(1);
    const result = self.accounts.getOrPutAssumeCapacity(address_word);
    std.debug.assert(!result.found_existing);
    result.value_ptr.* = .admitted(current);
    return result.entry_id;
}

noinline fn admitStorage(self: *OpenWorld, key: StorageKey) ResolutionError!StorageId {
    const value = if (self.reader) |reader|
        try reader.getStorage(self.accountAddress(key.account), key.slot)
    else
        0;
    try self.storage.ensureUnusedCapacity(1);
    const result = self.storage.getOrPutAssumeCapacity(key);
    std.debug.assert(!result.found_existing);
    result.value_ptr.* = .{ .current = value };
    return result.entry_id;
}

fn loadAccount(self: *const OpenWorld, address: Address) ResolutionError!?Account {
    const reader = self.reader orelse return null;
    const account = (try reader.loadAccount(address)) orelse return null;
    return self.normalize(account);
}

/// The fork half of EIP-161 emptiness. The value half is `Account.isEip161Empty`.
fn normalize(self: *const OpenWorld, account: Account) ?Account {
    if (!self.retains_empty_accounts and account.isEip161Empty()) return null;
    return account;
}

pub fn cachedCode(self: *const OpenWorld, code_hash: CodeHash) ?CodeView {
    const entry = self.code.entries.get(code_hash) orelse return null;
    return .{ .code_hash = code_hash, .bytes = entry.slice(&self.code) };
}

/// Parent code by hash: the cache, else the reader. `error.CodeUnavailable`
/// when there is no reader.
pub fn loadCode(self: *OpenWorld, code_hash: CodeHash) ResolutionError!CodeView {
    if (std.mem.eql(u8, &code_hash, &crypto.keccak256_empty)) {
        return .{ .code_hash = code_hash, .bytes = &.{} };
    }
    if (self.cachedCode(code_hash)) |view| return view;
    const reader = self.reader orelse return error.CodeUnavailable;
    const bytes = try reader.loadCode(code_hash);
    return .{ .code_hash = code_hash, .bytes = try self.cacheCode(code_hash, bytes) };
}

/// Drop every row; the next access reloads from the reader. Parent code
/// stays cached because it is content-addressed and immutable.
pub fn resetRows(self: *OpenWorld) void {
    self.accounts.clearRetainingCapacity();
    self.storage.clearRetainingCapacity();
}

pub fn reserveRows(self: *OpenWorld, hint: AccessHint) !void {
    try self.accounts.ensureUnusedCapacity(@intCast(hint.accounts));
    try self.storage.ensureUnusedCapacity(@intCast(hint.storage_keys));
}

/// Seed base state the way a reader load would arrive: the account is
/// normalized, its code is parent code, and its slots replace any the world
/// already holds for the address. Takes ownership of `account_value`.
pub fn seedAccount(self: *OpenWorld, address: Address, account_value: MemoryAccount) !void {
    var account = account_value;
    defer account.deinit();

    const code_hash = account.account.code_hash;
    if (!std.mem.eql(u8, &crypto.keccak256(account.code), &code_hash)) return error.CodeHashMismatch;
    if (account.code.len != 0) _ = try self.cacheCode(code_hash, account.code);

    const current = self.normalize(account.account);
    const result = try self.accounts.getOrPut(.fromAddress(address));
    if (result.found_existing) {
        const Owned = struct {
            account: AccountId,
            fn matches(context: @This(), key: StorageKey, _: StorageRow) bool {
                return key.account == context.account;
            }
        };
        self.storage.removeIf(Owned{ .account = result.entry_id }, Owned.matches);
    }
    result.value_ptr.* = .admitted(current);

    try self.storage.ensureUnusedCapacity(@intCast(account.storage.count()));
    var storage_it = account.storage.iterator();
    while (storage_it.next()) |entry| {
        self.storage.putAssumeCapacityNoClobber(
            .{ .account = result.entry_id, .slot = entry.key_ptr.* },
            .{ .current = entry.value_ptr.* },
        );
    }
}

pub fn allocationBytes(self: *const OpenWorld) usize {
    return self.accounts.allocationBytes() +
        self.storage.allocationBytes() +
        self.code.allocationBytes();
}

/// Capture current row values without copying map keys or probe slots.
pub fn captureSnapshot(self: *const OpenWorld, allocator: Allocator) Allocator.Error!RowSnapshot {
    const accounts = try allocator.alloc(AccountRow, self.accounts.count());
    errdefer allocator.free(accounts);
    for (accounts, 0..) |*row, index| row.* = self.accounts.entryAt(@intCast(index)).value_ptr.*;
    const storage = try allocator.alloc(StorageRow, self.storage.count());
    for (storage, 0..) |*row, index| row.* = self.storage.entryAt(@intCast(index)).value_ptr.*;
    return .{ .accounts = accounts, .storage = storage };
}

/// Restore captured values and drop rows admitted after the capture.
pub fn restoreSnapshot(self: *OpenWorld, snapshot: *const RowSnapshot) void {
    std.debug.assert(snapshot.accounts.len <= self.accounts.count());
    std.debug.assert(snapshot.storage.len <= self.storage.count());
    for (snapshot.accounts, 0..) |row, index|
        self.accounts.valuePtrById(@enumFromInt(index)).* = row;
    for (snapshot.storage, 0..) |row, index|
        self.storage.valuePtrById(@enumFromInt(index)).* = row;
    self.accounts.truncate(@intCast(snapshot.accounts.len));
    self.storage.truncate(@intCast(snapshot.storage.len));
}

pub const CodeEntry = struct {
    chunk: u32,
    bytes: ByteRange,

    comptime {
        std.debug.assert(@sizeOf(CodeEntry) == 12);
    }

    pub fn slice(self: CodeEntry, cache: *const CodeCache) []const u8 {
        const chunk = cache.chunks.items[self.chunk];
        return self.bytes.slice(chunk.bytes[0..chunk.used]);
    }
};

/// Parent code bytes, appended into stable chunks so a borrowed view survives
/// every later load.
pub const CodeCache = struct {
    const Chunk = struct {
        bytes: []u8,
        used: u32,
    };

    entries: CodeMap,
    chunks: std.ArrayList(Chunk) = .empty,
    used_bytes: usize = 0,

    fn init(allocator: Allocator) CodeCache {
        return .{ .entries = CodeMap.init(allocator) };
    }

    fn deinit(self: *CodeCache, allocator: Allocator) void {
        self.entries.deinit();
        for (self.chunks.items) |chunk| allocator.free(chunk.bytes);
        self.chunks.deinit(allocator);
        self.* = undefined;
    }

    fn allocationBytes(self: *const CodeCache) usize {
        var bytes = self.entries.allocationBytes() + self.chunks.capacity * @sizeOf(Chunk);
        for (self.chunks.items) |chunk| bytes += chunk.bytes.len;
        return bytes;
    }
};

fn cacheCode(self: *OpenWorld, code_hash: CodeHash, code_bytes: []const u8) ![]const u8 {
    std.debug.assert(std.mem.eql(u8, &crypto.keccak256(code_bytes), &code_hash));
    if (std.mem.eql(u8, &code_hash, &crypto.keccak256_empty)) return &.{};
    if (self.code.entries.get(code_hash)) |entry| return entry.slice(&self.code);
    std.debug.assert(code_bytes.len <= std.math.maxInt(u32));

    const allocator = self.code.entries.allocator;
    try self.code.entries.ensureUnusedCapacity(1);
    const tail_index = if (self.code.chunks.items.len == 0)
        null
    else
        self.code.chunks.items.len - 1;
    const chunk_index = if (tail_index) |index| blk: {
        const chunk = &self.code.chunks.items[index];
        const used: usize = chunk.used;
        if (code_bytes.len <= chunk.bytes.len - used) break :blk index;
        break :blk try self.appendCodeChunk(allocator, code_bytes.len);
    } else try self.appendCodeChunk(allocator, code_bytes.len);

    const chunk = &self.code.chunks.items[chunk_index];
    const code_range: ByteRange = .init(@as(usize, chunk.used), code_bytes.len);
    const entry: CodeEntry = .{ .chunk = @intCast(chunk_index), .bytes = code_range };
    const start: usize = chunk.used;
    @memcpy(chunk.bytes[start..][0..code_bytes.len], code_bytes);
    chunk.used += code_range.len;
    self.code.entries.putAssumeCapacityNoClobber(code_hash, entry);
    self.code.used_bytes += code_bytes.len;
    return entry.slice(&self.code);
}

fn appendCodeChunk(self: *OpenWorld, allocator: Allocator, required_bytes: usize) !usize {
    const chunk_index = self.code.chunks.items.len;
    try self.code.chunks.ensureUnusedCapacity(allocator, 1);
    const capacity = @max(required_bytes, minimum_code_chunk_bytes);
    const bytes = try allocator.alloc(u8, capacity);
    self.code.chunks.appendAssumeCapacity(.{ .bytes = bytes, .used = 0 });
    return chunk_index;
}

comptime {
    world_state.checkWorld(OpenWorld);
}
