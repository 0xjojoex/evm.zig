//! `StateReader` adapter over a Merkle Patricia Trie witness nodes.

const std = @import("std");

const address = @import("../address.zig");
const crypto = @import("../crypto.zig");
const trie = @import("../eth/trie.zig");
const rlp = @import("rlp");
const Account = @import("./Account.zig");
const StateReader = @import("./Reader.zig");

const Address = address.Address;

const WitnessStateReader = @This();

pub const Error = error{InvalidWitness};

pub const Code = struct {
    hash: [32]u8,
    bytes: []const u8,
};

state_root: [32]u8,
indexed: *trie.IndexedNodes,
codes: []const Code = &.{},

pub fn init(state_root: [32]u8, indexed: *trie.IndexedNodes, codes: []const Code) WitnessStateReader {
    return .{
        .state_root = state_root,
        .indexed = indexed,
        .codes = codes,
    };
}

pub fn deinit(self: *WitnessStateReader) void {
    self.indexed.deinit();
    self.* = undefined;
}

pub fn reader(self: *WitnessStateReader) StateReader {
    return .{
        .ptr = self,
        .vtable = &vtable,
    };
}

fn loadMptAccount(self: *const WitnessStateReader, target: Address) Error!?trie.Account {
    const key = trie.hashedAddressKey(target);
    const encoded = trie.proof(self.state_root, self.indexed).get(&key) catch return error.InvalidWitness;
    return trie.decodeAccountValue(encoded orelse return null) catch return error.InvalidWitness;
}

fn codeForHash(self: *const WitnessStateReader, hash: [32]u8) Error![]const u8 {
    if (std.mem.eql(u8, &hash, &crypto.keccak256_empty)) return "";
    for (self.codes) |code| {
        if (!std.mem.eql(u8, &code.hash, &hash)) continue;
        const actual_hash = crypto.keccak256(code.bytes);
        if (!std.mem.eql(u8, &actual_hash, &hash)) return error.InvalidWitness;
        return code.bytes;
    }
    return error.InvalidWitness;
}

const vtable = StateReader.VTable{
    .accountExists = accountExists,
    .loadAccount = loadAccount,
    .loadCode = loadCode,
    .getStorage = getStorage,
    .accountHasStorage = accountHasStorage,
};

fn context(ptr: *anyopaque) *WitnessStateReader {
    return @ptrCast(@alignCast(ptr));
}

fn accountExists(ptr: *anyopaque, target: Address) !bool {
    return (try context(ptr).loadMptAccount(target)) != null;
}

fn loadAccount(ptr: *anyopaque, target: Address) !?Account {
    const account = try context(ptr).loadMptAccount(target) orelse return null;
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
    if (std.mem.eql(u8, &account.storage_root, &trie.empty_root_hash)) return 0;

    const storage_key = trie.hashedStorageKey(key);
    const encoded = trie.proof(account.storage_root, self.indexed).get(&storage_key) catch return error.InvalidWitness;
    return decodeStorageValue(encoded orelse return 0) catch return error.InvalidWitness;
}

fn accountHasStorage(ptr: *anyopaque, target: Address) !bool {
    const account = try context(ptr).loadMptAccount(target) orelse return false;
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
    const codes = [_]Code{.{ .hash = code_hash, .bytes = &code }};

    var witness = try initForTest(scratch, state_root, &nodes, &codes);
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
    const state_reader = witness.reader();
    try std.testing.expect(try state_reader.accountHasStorage(target));
    try std.testing.expectEqual(@as(u256, 42), try state_reader.getStorage(target, 3));
    try std.testing.expectEqual(@as(u256, 0), try state_reader.getStorage(target, 4));
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
    const state_reader = witness.reader();

    const loaded = (try state_reader.loadAccount(target)).?;
    try std.testing.expectError(error.InvalidWitness, state_reader.loadCode(loaded.code_hash));
    try std.testing.expectError(error.InvalidWitness, state_reader.getStorage(target, 1));

    const malformed_codes = [_]Code{.{ .hash = code_hash, .bytes = &.{0x00} }};
    witness.codes = &malformed_codes;
    try std.testing.expectError(error.InvalidWitness, state_reader.loadCode(loaded.code_hash));
}

fn initForTest(
    allocator: std.mem.Allocator,
    state_root: [32]u8,
    nodes: []const []const u8,
    codes: []const Code,
) !WitnessStateReader {
    return WitnessStateReader.init(state_root, try trie.indexNodes(allocator, nodes), codes);
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
