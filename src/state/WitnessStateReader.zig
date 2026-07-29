//! `StateReader` adapter over a Merkle Patricia Trie witness nodes.

const std = @import("std");

const address = @import("../address.zig");
const crypto = @import("../crypto.zig");
const trie = @import("../eth/trie.zig");
const rlp = @import("rlp");
const Account = @import("./Account.zig");
const StateReader = @import("./Reader.zig");
const ConcurrentReader = @import("./ConcurrentReader.zig");

const Address = address.Address;

const WitnessStateReader = @This();

pub const Error = error{InvalidWitness};

const CodeEntry = struct {
    hash: [32]u8,
    bytes: []const u8,
};

allocator: std.mem.Allocator,
state_root: [32]u8,
indexed: *trie.IndexedNodes,
codes: []CodeEntry = &.{},
accounts: trie.AccountFacts = .empty,
proof_cache: trie.ProofCache,

pub fn init(
    allocator: std.mem.Allocator,
    state_root: [32]u8,
    indexed: *trie.IndexedNodes,
    codes: []const []const u8,
) !WitnessStateReader {
    errdefer indexed.deinit();
    return .{
        .allocator = allocator,
        .state_root = state_root,
        .indexed = indexed,
        .codes = try indexCodes(allocator, codes),
        .proof_cache = .init(allocator),
    };
}

pub fn deinit(self: *WitnessStateReader) void {
    self.proof_cache.deinit();
    self.accounts.deinit(self.allocator);
    if (self.codes.len != 0) self.allocator.free(self.codes);
    self.indexed.deinit();
    self.* = undefined;
}

pub fn reader(self: *WitnessStateReader) StateReader {
    return .{
        .ptr = self,
        .vtable = &vtable,
    };
}

/// Share the sealed witness index across overlapping read-only lanes.
/// The witness and all borrowed node/code bytes must outlive those lanes.
pub fn concurrentReader(self: *WitnessStateReader) ConcurrentReader {
    return .initAssumeSafe(.{
        .ptr = self,
        .vtable = &concurrent_vtable,
    });
}

fn loadMptAccount(self: *WitnessStateReader, target: Address) !?trie.Account {
    if (self.accounts.get(target)) |account| return account;
    const account = try self.loadMptAccountFrom(target, &self.proof_cache);
    try self.accounts.put(self.allocator, target, account);
    return account;
}

fn loadMptAccountUncached(self: *const WitnessStateReader, target: Address) Error!?trie.Account {
    return self.loadMptAccountFrom(target, null);
}

fn loadMptAccountFrom(
    self: *const WitnessStateReader,
    target: Address,
    cache: ?*trie.ProofCache,
) !?trie.Account {
    const key = trie.hashedAddressKey(target);
    const lookup = if (cache) |active|
        trie.cachedProof(self.state_root, self.indexed, active)
    else
        trie.proof(self.state_root, self.indexed);
    const encoded = lookup.get(&key) catch return error.InvalidWitness;
    return trie.decodeAccountValue(encoded orelse return null) catch return error.InvalidWitness;
}

fn codeForHash(self: *const WitnessStateReader, hash: [32]u8) Error![]const u8 {
    if (std.mem.eql(u8, &hash, &crypto.keccak256_empty)) return "";
    for (self.codes) |code| {
        if (!std.mem.eql(u8, &code.hash, &hash)) continue;
        return code.bytes;
    }
    return error.InvalidWitness;
}

fn indexCodes(allocator: std.mem.Allocator, codes: []const []const u8) ![]CodeEntry {
    if (codes.len == 0) return &.{};
    const entries = try allocator.alloc(CodeEntry, codes.len);
    for (entries, codes) |*entry, code| {
        entry.* = .{
            .hash = crypto.keccak256(code),
            .bytes = code,
        };
    }
    return entries;
}

const vtable = StateReader.VTable{
    .accountExists = accountExists,
    .loadAccount = loadAccount,
    .loadCode = loadCode,
    .loadCodeValidatesHash = true,
    .getStorage = getStorage,
    .accountHasStorage = accountHasStorage,
};

const concurrent_vtable = StateReader.VTable{
    .accountExists = accountExistsUncached,
    .loadAccount = loadAccountUncached,
    .loadCode = loadCode,
    .loadCodeValidatesHash = true,
    .getStorage = getStorageUncached,
    .accountHasStorage = accountHasStorageUncached,
};

fn context(ptr: *anyopaque) *WitnessStateReader {
    return @ptrCast(@alignCast(ptr));
}

fn accountExists(ptr: *anyopaque, target: Address) !bool {
    return (try context(ptr).loadMptAccount(target)) != null;
}

fn accountExistsUncached(ptr: *anyopaque, target: Address) !bool {
    return (try context(ptr).loadMptAccountUncached(target)) != null;
}

fn loadAccount(ptr: *anyopaque, target: Address) !?Account {
    const account = try context(ptr).loadMptAccount(target) orelse return null;
    return accountValue(account);
}

fn loadAccountUncached(ptr: *anyopaque, target: Address) !?Account {
    const account = try context(ptr).loadMptAccountUncached(target) orelse return null;
    return accountValue(account);
}

fn accountValue(account: trie.Account) Account {
    return .{
        .nonce = account.nonce,
        .balance = account.balance,
        .code_hash = account.code_hash,
    };
}

fn loadCode(ptr: *anyopaque, hash: [32]u8) ![]const u8 {
    // Witness-specific absence and hash mismatches are classified here. The
    // generic overlay only caches and propagates reader failures.
    return context(ptr).codeForHash(hash);
}

fn getStorage(ptr: *anyopaque, target: Address, key: u256) !u256 {
    const self = context(ptr);
    const account = try self.loadMptAccount(target) orelse return 0;
    return self.getStorageFrom(account, key, &self.proof_cache);
}

fn getStorageUncached(ptr: *anyopaque, target: Address, key: u256) !u256 {
    const self = context(ptr);
    const account = try self.loadMptAccountUncached(target) orelse return 0;
    return self.getStorageFrom(account, key, null);
}

fn getStorageFrom(
    self: *const WitnessStateReader,
    account: trie.Account,
    key: u256,
    cache: ?*trie.ProofCache,
) !u256 {
    if (std.mem.eql(u8, &account.storage_root, &trie.empty_root_hash)) return 0;

    const storage_key = trie.hashedStorageKey(key);
    const lookup = if (cache) |active|
        trie.cachedProof(account.storage_root, self.indexed, active)
    else
        trie.proof(account.storage_root, self.indexed);
    const encoded = lookup.get(&storage_key) catch return error.InvalidWitness;
    return decodeStorageValue(encoded orelse return 0) catch return error.InvalidWitness;
}

fn accountHasStorage(ptr: *anyopaque, target: Address) !bool {
    const account = try context(ptr).loadMptAccount(target) orelse return false;
    return !std.mem.eql(u8, &account.storage_root, &trie.empty_root_hash);
}

fn accountHasStorageUncached(ptr: *anyopaque, target: Address) !bool {
    const account = try context(ptr).loadMptAccountUncached(target) orelse return false;
    return !std.mem.eql(u8, &account.storage_root, &trie.empty_root_hash);
}

fn decodeStorageValue(encoded: []const u8) rlp.ParseError!u256 {
    var cursor = rlp.Cursor.init(encoded);
    const value = try cursor.nextInt(u256);
    try cursor.expectDone();
    return value;
}

test "witness state reader returns empty state for empty root" {
    var witness = try initForTest(std.testing.allocator, trie.empty_root_hash, &.{}, &.{});
    defer witness.deinit();
    const state_reader = witness.reader();
    const target = address.addr(0x1000);

    try std.testing.expect(!try state_reader.accountExists(target));
    try std.testing.expect(try state_reader.loadAccount(target) == null);
    try std.testing.expectEqual(@as(u256, 0), try state_reader.getStorage(target, 1));
    try std.testing.expect(!try state_reader.accountHasStorage(target));
}

test "witness state reader loads account and code" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const scratch = arena.allocator();

    const target = address.addr(0x1000);
    const code = [_]u8{ 0x60, 0x00 };
    const code_hash = crypto.keccak256(&code);
    const account = trie.Account{
        .nonce = 7,
        .balance = 99,
        .code_hash = code_hash,
    };
    const account_value = try trie.accountValueFrom(scratch, account);
    const account_key = trie.hashedAddressKey(target);
    const state_node = try testLeafNode(scratch, &account_key, account_value);
    const state_root = crypto.keccak256(state_node);
    const nodes = [_][]const u8{state_node};
    const codes = [_][]const u8{&code};

    var witness = try initForTest(scratch, state_root, &nodes, &codes);
    defer witness.deinit();
    const state_reader = witness.reader();

    try std.testing.expect(try state_reader.accountExists(target));
    const loaded = (try state_reader.loadAccount(target)).?;
    try std.testing.expectEqual(@as(u64, 7), loaded.nonce);
    try std.testing.expectEqual(@as(u256, 99), loaded.balance);
    try std.testing.expectEqualSlices(u8, &code, try state_reader.loadCode(loaded.code_hash));
    try std.testing.expect(!try state_reader.accountHasStorage(target));
}

test "witness state reader reads storage through account storage root" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const scratch = arena.allocator();

    const target = address.addr(0x2000);
    const storage_key = trie.hashedStorageKey(3);
    const storage_value = try trie.storageValue(scratch, 42);
    const storage_node = try testLeafNode(scratch, &storage_key, storage_value);
    const storage_root = crypto.keccak256(storage_node);

    const account_value = try trie.accountValueFrom(scratch, .{ .storage_root = storage_root });
    const account_key = trie.hashedAddressKey(target);
    const state_node = try testLeafNode(scratch, &account_key, account_value);
    const state_root = crypto.keccak256(state_node);
    const nodes = [_][]const u8{ state_node, storage_node };

    var witness = try initForTest(scratch, state_root, &nodes, &.{});
    defer witness.deinit();
    const state_reader = witness.reader();
    try std.testing.expect(try state_reader.accountHasStorage(target));
    try std.testing.expectEqual(@as(u256, 42), try state_reader.getStorage(target, 3));
    try std.testing.expectEqual(@as(u256, 0), try state_reader.getStorage(target, 4));

    witness.state_root = [_]u8{0xaa} ** 32;
    try std.testing.expectEqual(@as(u256, 42), try state_reader.getStorage(target, 3));
    try std.testing.expectError(
        error.InvalidWitness,
        witness.concurrentReader().reader().getStorage(target, 3),
    );
}

test "witness state reader rejects missing witness nodes and code" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const scratch = arena.allocator();

    const target = address.addr(0x3000);
    const storage_root = [_]u8{0xab} ** 32;
    const code_hash = crypto.keccak256(&.{0x5f});
    const account_value = try trie.accountValueFrom(scratch, .{
        .storage_root = storage_root,
        .code_hash = code_hash,
    });
    const account_key = trie.hashedAddressKey(target);
    const state_node = try testLeafNode(scratch, &account_key, account_value);
    const state_root = crypto.keccak256(state_node);
    const nodes = [_][]const u8{state_node};

    var witness = try initForTest(scratch, state_root, &nodes, &.{});
    defer witness.deinit();
    const state_reader = witness.reader();

    const loaded = (try state_reader.loadAccount(target)).?;
    try std.testing.expectError(error.InvalidWitness, state_reader.loadCode(loaded.code_hash));
    try std.testing.expectError(error.InvalidWitness, state_reader.getStorage(target, 1));

    const malformed_code = [_]u8{0x00};
    const malformed_codes = [_][]const u8{&malformed_code};
    var malformed_witness = try initForTest(scratch, state_root, &nodes, &malformed_codes);
    defer malformed_witness.deinit();
    try std.testing.expectError(
        error.InvalidWitness,
        malformed_witness.reader().loadCode(loaded.code_hash),
    );
}

fn initForTest(
    allocator: std.mem.Allocator,
    state_root: [32]u8,
    nodes: []const []const u8,
    codes: []const []const u8,
) !WitnessStateReader {
    const indexed = try trie.indexNodes(allocator, nodes);
    return WitnessStateReader.init(allocator, state_root, indexed, codes);
}

fn testLeafNode(allocator: std.mem.Allocator, key: []const u8, value: []const u8) ![]u8 {
    const path = try testCompactPath(allocator, key);

    var payload = rlp.Writer.alloc(allocator);
    defer payload.deinit();
    try payload.bytes(path);
    try payload.bytes(value);

    var out = rlp.Writer.alloc(allocator);
    errdefer out.deinit();
    try out.listPayload(payload.written());
    return try writerOwned(&out);
}

fn testCompactPath(allocator: std.mem.Allocator, key: []const u8) ![]u8 {
    const out = try allocator.alloc(u8, key.len + 1);
    out[0] = 0x20;
    @memcpy(out[1..], key);
    return out;
}

fn writerOwned(writer: *rlp.Writer) std.mem.Allocator.Error![]u8 {
    return writer.toOwnedSlice() catch |err| switch (err) {
        error.BorrowedWriter => unreachable,
        error.OutOfMemory => return error.OutOfMemory,
    };
}
