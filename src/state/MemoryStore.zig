//! In-memory state store for tests, demos, fixtures, and lightweight embeds.
//!
//! `reader()` exposes the read-only `StateReader` adapter. `committer()` applies
//! final changesets back into this canonical memory store. It is not the
//! execution overlay: speculative writes, checkpoints, reverts, logs, warmth,
//! and the journal live in `Overlay`.

const std = @import("std");

const evmz = @import("../evm.zig");
const Account = @import("./Account.zig");
const Backend = @import("./Backend.zig").Backend;
const RootProvider = @import("./Backend.zig").RootProvider;
const MemoryAccount = @import("./MemoryAccount.zig");
const Changeset = @import("./Changeset.zig");
const Committer = @import("./Committer.zig");
const StateReader = @import("./Reader.zig");
const ConcurrentReader = @import("./ConcurrentReader.zig");
const trie = @import("../eth/trie.zig");
const SparseHashMap = @import("./sparse_hash_map.zig").Auto;

const Address = evmz.Address;

pub const EmptyAccountPolicy = enum {
    omit,
    include,
};

pub const StateRootOptions = struct {
    empty_accounts: EmptyAccountPolicy = .omit,
};
const addr = evmz.addr;

const MemoryStore = @This();

allocator: std.mem.Allocator,
accounts: SparseHashMap(Address, MemoryAccount),
codes: SparseHashMap([32]u8, []u8),

pub fn init(allocator: std.mem.Allocator) MemoryStore {
    return .{
        .allocator = allocator,
        .accounts = SparseHashMap(Address, MemoryAccount).init(allocator),
        .codes = SparseHashMap([32]u8, []u8).init(allocator),
    };
}

pub fn deinit(self: *MemoryStore) void {
    self.clearAccounts();
    self.accounts.deinit();
    self.codes.deinit();
}

pub fn reader(self: *MemoryStore) StateReader {
    return .{ .ptr = self, .vtable = &.{
        .accountExists = accountExists,
        .loadAccount = loadAccount,
        .loadCode = loadCode,
        .getStorage = getStorage,
        .accountHasStorage = accountHasStorage,
    } };
}

/// Borrow a read-concurrent view of this store.
///
/// The caller must not mutate or deinitialize the store until every copied
/// reader handle has finished. Reader methods themselves do not populate
/// caches, so overlapping calls only inspect stable map and account storage.
pub fn concurrentReader(self: *MemoryStore) ConcurrentReader {
    return .initAssumeSafe(self.reader());
}

pub fn committer(self: *MemoryStore) Committer {
    return .{ .ptr = self, .vtable = &.{
        .commit = commit,
    } };
}

pub fn backend(self: *MemoryStore) Backend {
    return Backend.fromExternal(self.reader(), .{
        .ptr = self,
        .vtable = &root_provider_vtable,
    }, self.committer());
}

const root_provider_vtable = RootProvider.VTable{
    .afterChangeset = stateRootAfterChangesetProvider,
};

fn stateRootAfterChangesetProvider(ptr: *anyopaque, allocator: std.mem.Allocator, changeset: *const Changeset) ![32]u8 {
    const self: *MemoryStore = @ptrCast(@alignCast(ptr));
    return self.stateRootAfterChangeset(allocator, changeset);
}

pub fn getAccount(self: *MemoryStore, address: Address) ?*MemoryAccount {
    return self.accounts.getPtr(address);
}

pub fn getOrCreateAccount(self: *MemoryStore, address: Address) !*MemoryAccount {
    if (!self.accounts.contains(address)) {
        try self.accounts.put(address, MemoryAccount.init(self.allocator));
    }
    return self.accounts.getPtr(address).?;
}

/// Copy an account into the in-memory pre-state using the store allocator.
pub fn putAccount(self: *MemoryStore, address: Address, account: *const MemoryAccount) !void {
    const code_hash = accountCodeHash(account);
    if (!std.mem.eql(u8, &evmz.crypto.keccak256(account.code), &code_hash)) return error.CodeHashMismatch;

    var owned = try account.clone(self.allocator);
    errdefer owned.deinit();
    owned.code_hash = code_hash;

    if (!self.accounts.contains(address)) try self.accounts.ensureUnusedCapacity(1);
    if (owned.code.len != 0) try self.putCode(code_hash, owned.code);

    if (self.accounts.getPtr(address)) |existing| {
        var old = existing.*;
        existing.* = owned;
        owned = MemoryAccount.init(self.allocator);
        old.deinit();
        return;
    }
    self.accounts.putAssumeCapacity(address, owned);
    owned = MemoryAccount.init(self.allocator);
}

fn clearCodes(self: *MemoryStore) void {
    var code_it = self.codes.valueIterator();
    while (code_it.next()) |code| self.allocator.free(code.*);
    self.codes.clearRetainingCapacity();
}

fn putCode(self: *MemoryStore, hash: [32]u8, code: []const u8) !void {
    if (self.codes.contains(hash)) return;
    const owned = try self.allocator.dupe(u8, code);
    errdefer self.allocator.free(owned);
    try self.codes.put(hash, owned);
}

pub fn clearAccounts(self: *MemoryStore) void {
    var account_it = self.accounts.valueIterator();
    while (account_it.next()) |account| {
        account.deinit();
    }
    self.accounts.clearRetainingCapacity();
    self.clearCodes();
}

pub fn clone(self: *MemoryStore, allocator: std.mem.Allocator) !MemoryStore {
    var result = MemoryStore.init(allocator);
    errdefer result.deinit();

    var account_it = self.accounts.iterator();
    while (account_it.next()) |entry| {
        try result.putAccount(entry.key_ptr.*, entry.value_ptr);
    }

    var code_it = self.codes.iterator();
    while (code_it.next()) |entry| try result.putCode(entry.key_ptr.*, entry.value_ptr.*);

    return result;
}

pub fn stateRoot(self: *MemoryStore, allocator: std.mem.Allocator) ![32]u8 {
    return self.stateRootWithOptions(allocator, .{});
}

pub fn stateRootWithOptions(self: *MemoryStore, allocator: std.mem.Allocator, options: StateRootOptions) ![32]u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();

    var pairs: std.ArrayList(trie.Pair) = .empty;
    defer pairs.deinit(scratch);

    var account_it = self.accounts.iterator();
    while (account_it.next()) |entry| {
        const storage_root = try accountStorageRoot(scratch, entry.value_ptr);
        const code_hash = accountCodeHash(entry.value_ptr);
        const account = trie.Account{
            .nonce = entry.value_ptr.nonce,
            .balance = entry.value_ptr.balance,
            .storage_root = storage_root,
            .code_hash = code_hash,
        };
        if (options.empty_accounts == .omit and account.isEmpty()) continue;

        const key = try scratch.alloc(u8, 32);
        const hashed_key = trie.hashedAddressKey(entry.key_ptr.*);
        @memcpy(key, &hashed_key);

        try pairs.append(scratch, .{
            .key = key,
            .value = try trie.accountValueFrom(scratch, account),
        });
    }

    return try trie.root(allocator, pairs.items);
}

pub fn stateRootAfterChangeset(self: *MemoryStore, allocator: std.mem.Allocator, changeset: *const Changeset) ![32]u8 {
    return self.stateRootAfterChangesetWithOptions(allocator, changeset, .{});
}

pub fn stateRootAfterChangesetWithOptions(
    self: *MemoryStore,
    allocator: std.mem.Allocator,
    changeset: *const Changeset,
    options: StateRootOptions,
) ![32]u8 {
    var next = try self.clone(allocator);
    defer next.deinit();

    try next.applyChangesetInPlace(changeset);
    return try next.stateRootWithOptions(allocator, options);
}

pub fn applyChangeset(self: *MemoryStore, changeset: *const Changeset) !void {
    var next = try self.clone(self.allocator);
    errdefer next.deinit();
    try next.applyChangesetInPlace(changeset);

    std.mem.swap(MemoryStore, self, &next);
    next.deinit();
}

fn applyChangesetInPlace(self: *MemoryStore, changeset: *const Changeset) !void {
    for (changeset.code_inserts.items) |insert| {
        if (!std.mem.eql(u8, &evmz.crypto.keccak256(insert.code), &insert.code_hash)) return error.CodeHashMismatch;
        try self.putCode(insert.code_hash, insert.code);
    }

    for (changeset.account_deletes.items) |address| {
        if (self.accounts.fetchRemove(address)) |removed| {
            var account = removed.value;
            account.deinit();
        }
    }

    for (changeset.account_updates.items) |update| {
        const account = try self.getOrCreateAccount(update.address);
        const previous_code_hash = accountCodeHash(account);
        account.nonce = update.nonce;
        account.balance = update.balance;
        if (!std.mem.eql(u8, &previous_code_hash, &update.code_hash)) {
            const code = if (std.mem.eql(u8, &update.code_hash, &evmz.crypto.keccak256_empty))
                &.{}
            else
                try self.codeForHash(update.code_hash);
            try account.setCode(code);
        }
        account.code_hash = update.code_hash;
    }

    for (changeset.storage_writes.items) |write| {
        if (write.value == 0) {
            if (self.accounts.getPtr(write.address)) |account| {
                _ = account.storage.remove(write.key);
            }
        } else {
            const account = try self.getOrCreateAccount(write.address);
            try account.storage.put(write.key, write.value);
        }
    }
}

fn commit(ptr: *anyopaque, changeset: *const Changeset) !void {
    const self: *MemoryStore = @ptrCast(@alignCast(ptr));
    try self.applyChangeset(changeset);
}

fn accountExists(ptr: *anyopaque, address: Address) !bool {
    const self: *MemoryStore = @ptrCast(@alignCast(ptr));
    return self.accounts.contains(address);
}

fn loadAccount(ptr: *anyopaque, address: Address) !?Account {
    const self: *MemoryStore = @ptrCast(@alignCast(ptr));
    const account = self.accounts.getPtr(address) orelse return null;
    return .{
        .nonce = account.nonce,
        .balance = account.balance,
        .code_hash = accountCodeHash(account),
    };
}

fn loadCode(ptr: *anyopaque, hash: [32]u8) ![]const u8 {
    const self: *MemoryStore = @ptrCast(@alignCast(ptr));
    return self.codeForHash(hash);
}

fn codeForHash(self: *MemoryStore, hash: [32]u8) ![]const u8 {
    if (std.mem.eql(u8, &hash, &evmz.crypto.keccak256_empty)) return &.{};
    if (self.codes.get(hash)) |code| return code;

    var account_it = self.accounts.valueIterator();
    while (account_it.next()) |account| {
        if (!std.mem.eql(u8, &accountCodeHash(account), &hash)) continue;
        if (!std.mem.eql(u8, &evmz.crypto.keccak256(account.code), &hash)) return error.CodeHashMismatch;
        return account.code;
    }
    return error.MissingCode;
}

fn getStorage(ptr: *anyopaque, address: Address, key: u256) !u256 {
    const self: *MemoryStore = @ptrCast(@alignCast(ptr));
    const account = self.accounts.getPtr(address) orelse return 0;
    return account.getStorage(key);
}

fn accountHasStorage(ptr: *anyopaque, address: Address) !bool {
    const self: *MemoryStore = @ptrCast(@alignCast(ptr));
    const account = self.accounts.getPtr(address) orelse return false;
    return account.storage.count() != 0;
}

fn accountStorageRoot(allocator: std.mem.Allocator, account: *const MemoryAccount) ![32]u8 {
    var pairs: std.ArrayList(trie.Pair) = .empty;
    defer pairs.deinit(allocator);

    var storage = account.storage;
    var storage_it = storage.iterator();
    while (storage_it.next()) |entry| {
        if (entry.value_ptr.* == 0) continue;

        const key = try allocator.alloc(u8, 32);
        const hashed_key = trie.hashedStorageKey(entry.key_ptr.*);
        @memcpy(key, &hashed_key);

        try pairs.append(allocator, .{
            .key = key,
            .value = try trie.storageValue(allocator, entry.value_ptr.*),
        });
    }

    return try trie.root(allocator, pairs.items);
}

fn accountCodeHash(account: *const MemoryAccount) [32]u8 {
    return account.code_hash orelse evmz.crypto.keccak256(account.code);
}

test "memory store exposes state reader" {
    const address = addr(0xabc);
    var memory = MemoryStore.init(std.testing.allocator);
    defer memory.deinit();

    var account = try memory.getOrCreateAccount(address);
    account.balance = 99;
    try account.setCode(&.{0x5f});
    try account.storage.put(7, 0xaa);

    const state_reader = memory.reader();
    try std.testing.expect(try state_reader.accountExists(address));
    try std.testing.expectEqual(@as(u256, 0xaa), try state_reader.getStorage(address, 7));
    try std.testing.expect(try state_reader.accountHasStorage(address));

    const loaded = (try state_reader.loadAccount(address)).?;
    try std.testing.expectEqual(@as(u256, 99), loaded.balance);
    try std.testing.expectEqualSlices(u8, &.{0x5f}, try state_reader.loadCode(loaded.code_hash));
}

test "memory store computes full state root" {
    const address = addr(0x1234);
    var memory = MemoryStore.init(std.testing.allocator);
    defer memory.deinit();

    var account = try memory.getOrCreateAccount(address);
    account.nonce = 7;
    account.balance = 99;
    try account.setCode(&.{ 0x60, 0x00 });
    try account.storage.put(1, 42);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const scratch = arena.allocator();

    const storage_key = trie.hashedStorageKey(1);
    const storage_value = try trie.storageValue(scratch, 42);
    const storage_root = try trie.root(scratch, &.{.{ .key = &storage_key, .value = storage_value }});
    const account_key = trie.hashedAddressKey(address);
    const account_value = try trie.accountValueFrom(scratch, .{
        .nonce = 7,
        .balance = 99,
        .storage_root = storage_root,
        .code_hash = evmz.crypto.keccak256(&.{ 0x60, 0x00 }),
    });
    const expected = try trie.root(scratch, &.{.{ .key = &account_key, .value = account_value }});
    const actual = try memory.stateRoot(std.testing.allocator);

    try std.testing.expectEqualSlices(u8, &expected, &actual);
}

test "memory store state root retains an explicit empty account" {
    const address = addr(0x2345);
    var memory = MemoryStore.init(std.testing.allocator);
    defer memory.deinit();

    _ = try memory.getOrCreateAccount(address);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const scratch = arena.allocator();

    const account_key = trie.hashedAddressKey(address);
    const account_value = try trie.accountValueFrom(scratch, .{});
    const expected = try trie.root(scratch, &.{.{ .key = &account_key, .value = account_value }});
    const default_root = try memory.stateRoot(std.testing.allocator);
    const actual = try memory.stateRootWithOptions(std.testing.allocator, .{ .empty_accounts = .include });

    try std.testing.expectEqualSlices(u8, &trie.empty_root_hash, &default_root);
    try std.testing.expectEqualSlices(u8, &expected, &actual);
}

test "memory store computes state root after changeset without committing" {
    const address = addr(0x5678);
    var memory = MemoryStore.init(std.testing.allocator);
    defer memory.deinit();

    var account = try memory.getOrCreateAccount(address);
    account.balance = 1;

    var delta = Changeset.init();
    defer delta.deinit(std.testing.allocator);
    try delta.account_updates.append(std.testing.allocator, .{
        .address = address,
        .nonce = 1,
        .balance = 3,
        .code_hash = evmz.crypto.keccak256_empty,
    });

    const next_root = try memory.stateRootAfterChangeset(std.testing.allocator, &delta);
    try std.testing.expectEqual(@as(u256, 1), memory.getAccount(address).?.balance);

    try memory.applyChangeset(&delta);
    const committed_root = try memory.stateRoot(std.testing.allocator);
    try std.testing.expectEqualSlices(u8, &next_root, &committed_root);
    try std.testing.expectEqual(@as(u256, 3), memory.getAccount(address).?.balance);
}

test "memory store copies a borrowed account" {
    const address = addr(0xdef);
    var memory = MemoryStore.init(std.testing.allocator);
    defer memory.deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    const source = arena.allocator();
    var account = MemoryAccount.init(source);
    account.balance = 11;
    try account.setCode(&.{0x5f});
    try account.storage.put(1, 2);
    try memory.putAccount(address, &account);
    account.deinit();
    arena.deinit();

    const state_reader = memory.reader();
    try std.testing.expect(try state_reader.accountExists(address));
    const loaded = (try state_reader.loadAccount(address)).?;
    try std.testing.expectEqualSlices(u8, &.{0x5f}, try state_reader.loadCode(loaded.code_hash));
    try std.testing.expectEqual(@as(u256, 2), try state_reader.getStorage(address, 1));
}

test "memory store retains a code hash derived during account insertion" {
    const address = addr(0xc0de);
    const code = [_]u8{ 0x60, 0x00 };
    var memory = MemoryStore.init(std.testing.allocator);
    defer memory.deinit();

    var account = MemoryAccount.init(std.testing.allocator);
    defer account.deinit();
    try account.setCode(&code);
    try memory.putAccount(address, &account);

    try std.testing.expectEqual(evmz.crypto.keccak256(&code), memory.getAccount(address).?.code_hash.?);
}

test "memory store rejects empty code with non-empty explicit hash" {
    const address = addr(0xbad);
    var memory = MemoryStore.init(std.testing.allocator);
    defer memory.deinit();

    var account = MemoryAccount.init(std.testing.allocator);
    defer account.deinit();
    account.code_hash = [_]u8{0xaa} ** 32;

    try std.testing.expectError(error.CodeHashMismatch, memory.putAccount(address, &account));
    try std.testing.expect(memory.getAccount(address) == null);
}

test "memory store applies changeset updates and storage writes" {
    const address = addr(0xbeef);
    var memory = MemoryStore.init(std.testing.allocator);
    defer memory.deinit();

    var account = try memory.getOrCreateAccount(address);
    account.balance = 1;
    account.nonce = 2;
    try account.setCode(&.{0x5f});
    try account.storage.put(1, 1);
    try account.storage.put(2, 2);

    var delta = Changeset.init();
    defer delta.deinit(std.testing.allocator);
    {
        const code = try std.testing.allocator.dupe(u8, &.{ 0xaa, 0xbb });
        errdefer std.testing.allocator.free(code);
        try delta.account_updates.append(std.testing.allocator, .{
            .address = address,
            .nonce = 3,
            .balance = 9,
            .code_hash = evmz.crypto.keccak256(code),
        });
        try delta.code_inserts.append(std.testing.allocator, .{
            .code_hash = evmz.crypto.keccak256(code),
            .code = code,
        });
    }
    try delta.storage_writes.append(std.testing.allocator, .{
        .address = address,
        .key = 1,
        .value = 0,
    });
    try delta.storage_writes.append(std.testing.allocator, .{
        .address = address,
        .key = 2,
        .value = 22,
    });
    try delta.storage_writes.append(std.testing.allocator, .{
        .address = address,
        .key = 3,
        .value = 33,
    });

    try memory.applyChangeset(&delta);

    const updated = memory.getAccount(address).?;
    try std.testing.expectEqual(@as(u256, 9), updated.balance);
    try std.testing.expectEqual(@as(u64, 3), updated.nonce);
    try std.testing.expectEqualSlices(u8, &.{ 0xaa, 0xbb }, updated.code);
    try std.testing.expectEqual(@as(u256, 0), updated.getStorage(1));
    try std.testing.expectEqual(@as(u256, 22), updated.getStorage(2));
    try std.testing.expectEqual(@as(u256, 33), updated.getStorage(3));
}

test "memory store preserves existing code bytes on metadata-only account update" {
    const address = addr(0xcafe);
    const code = [_]u8{ 0x60, 0x00 };
    const code_hash = evmz.crypto.keccak256(&code);
    var memory = MemoryStore.init(std.testing.allocator);
    defer memory.deinit();

    const account = try memory.getOrCreateAccount(address);
    try account.setCode(&code);

    var delta = Changeset.init();
    defer delta.deinit(std.testing.allocator);
    try delta.account_updates.append(std.testing.allocator, .{
        .address = address,
        .nonce = 1,
        .balance = 9,
        .code_hash = code_hash,
    });

    try memory.applyChangeset(&delta);

    const updated = memory.getAccount(address).?;
    try std.testing.expectEqualSlices(u8, &code, updated.code);
    try std.testing.expectEqual(@as(u256, 9), updated.balance);
}

test "memory store applies explicit empty code replacement" {
    const address = addr(0xc1ea);
    var memory = MemoryStore.init(std.testing.allocator);
    defer memory.deinit();

    const account = try memory.getOrCreateAccount(address);
    try account.setCode(&.{0x5f});

    var delta = Changeset.init();
    defer delta.deinit(std.testing.allocator);
    try delta.account_updates.append(std.testing.allocator, .{
        .address = address,
        .nonce = 0,
        .balance = 0,
        .code_hash = evmz.crypto.keccak256_empty,
    });

    try memory.applyChangeset(&delta);

    try std.testing.expectEqual(@as(usize, 0), memory.getAccount(address).?.code.len);
}

test "memory store rejects missing code without partial account mutation" {
    const address = addr(0xc0de);
    var memory = MemoryStore.init(std.testing.allocator);
    defer memory.deinit();

    const account = try memory.getOrCreateAccount(address);
    account.nonce = 1;
    account.balance = 2;
    try account.setCode(&.{0x5f});

    var delta = Changeset.init();
    defer delta.deinit(std.testing.allocator);
    try delta.account_updates.append(std.testing.allocator, .{
        .address = address,
        .nonce = 9,
        .balance = 10,
        .code_hash = [_]u8{0xaa} ** 32,
    });

    try std.testing.expectError(error.MissingCode, memory.applyChangeset(&delta));
    const unchanged = memory.getAccount(address).?;
    try std.testing.expectEqual(@as(u64, 1), unchanged.nonce);
    try std.testing.expectEqual(@as(u256, 2), unchanged.balance);
    try std.testing.expectEqualSlices(u8, &.{0x5f}, unchanged.code);
}

test "memory store applies account deletes" {
    const address = addr(0xd1e);
    var memory = MemoryStore.init(std.testing.allocator);
    defer memory.deinit();

    _ = try memory.getOrCreateAccount(address);

    var delta = Changeset.init();
    defer delta.deinit(std.testing.allocator);
    try delta.account_deletes.append(std.testing.allocator, address);

    try memory.applyChangeset(&delta);

    try std.testing.expect(memory.getAccount(address) == null);
}

test "memory store exposes committer adapter" {
    const address = addr(0xc0de);
    var memory = MemoryStore.init(std.testing.allocator);
    defer memory.deinit();

    var delta = Changeset.init();
    defer delta.deinit(std.testing.allocator);
    try delta.storage_writes.append(std.testing.allocator, .{
        .address = address,
        .key = 7,
        .value = 99,
    });

    try memory.committer().commit(&delta);

    try std.testing.expectEqual(@as(u256, 99), memory.getAccount(address).?.getStorage(7));
}
