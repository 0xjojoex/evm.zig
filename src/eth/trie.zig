//! Ethereum execution MPT helpers for root construction, proof lookup, and
//! witness-backed root updates.
//! This is not a persistent trie database or a complete general-purpose MPT library.

const std = @import("std");

const address = @import("../address.zig");
const crypto = @import("../crypto.zig");
const rlp = @import("rlp");
const mpt = @import("mpt");
const uint256 = @import("../uint256.zig");
const TrackedState = @import("../state/TrackedState.zig");
const t = @import("../t.zig");
const Withdrawal = @import("Withdrawal.zig");
const ChangesView = TrackedState.ChangesView;

const Allocator = std.mem.Allocator;

/// Evmz execution backend for the MPT's fixed structural Keccak-256 rule.
const KeccakContext = struct {
    pub fn keccak256(_: @This(), input: []const u8) mpt.Root {
        return crypto.keccak256(input);
    }
};

const StructuralTrie = mpt.Trie(KeccakContext);

const AddressKeyContext = struct {
    pub fn trieKey(_: @This(), target: address.Address) mpt.Root {
        return crypto.keccak256(&target);
    }
};

const StorageKeyContext = struct {
    pub fn trieKey(_: @This(), key: u256) mpt.Root {
        return crypto.keccak256(&uint256.toBytes32(key));
    }
};

const AccountTrie = StructuralTrie.Keyed(address.Address, AddressKeyContext);
const StorageTrie = StructuralTrie.Keyed(u256, StorageKeyContext);

fn structuralTrie(allocator: Allocator) StructuralTrie {
    return StructuralTrie.init(allocator, .{});
}

fn accountTrie(allocator: Allocator) AccountTrie {
    return AccountTrie.init(structuralTrie(allocator), .{});
}

fn storageTrie(allocator: Allocator) StorageTrie {
    return StorageTrie.init(structuralTrie(allocator), .{});
}

pub const Error = Allocator.Error || mpt.Error;

pub const ProofLookupError = rlp.DecodeError || mpt.Error;

pub const UpdateError = Allocator.Error || ProofLookupError || Error;

pub const empty_root_hash = mpt.empty_root;

pub const Pair = mpt.Entry;

pub const Account = struct {
    nonce: u64 = 0,
    balance: u256 = 0,
    storage_root: [32]u8 = empty_root_hash,
    code_hash: [32]u8 = crypto.keccak256_empty,

    pub fn isEmpty(self: Account) bool {
        return self.nonce == 0 and
            self.balance == 0 and
            std.mem.eql(u8, &self.storage_root, &empty_root_hash) and
            std.mem.eql(u8, &self.code_hash, &crypto.keccak256_empty);
    }
};

pub const Update = mpt.Update;

pub const IndexedNodes = mpt.IndexedNodes;

pub const Proof = struct {
    root_hash: [32]u8,
    index: *const mpt.NodeIndex,

    pub fn get(self: Proof, key: []const u8) ProofLookupError!?[]const u8 {
        const result = try mpt.lookup(
            self.root_hash,
            self.index,
            key,
        );
        return switch (result) {
            .present => |value| value,
            .absent => null,
        };
    }
};

pub fn root(allocator: Allocator, pairs: []const Pair) Error![32]u8 {
    return structuralTrie(allocator).root(pairs);
}

pub fn indexNodes(allocator: Allocator, nodes: []const []const u8) Error!*IndexedNodes {
    return structuralTrie(allocator).indexNodes(nodes);
}

pub fn proof(root_hash: [32]u8, indexed: *const IndexedNodes) Proof {
    return .{ .root_hash = root_hash, .index = indexed.index() };
}

pub fn orderedTrieRoot(allocator: Allocator, encoded_values: []const []const u8) Error![32]u8 {
    if (encoded_values.len == 0) return empty_root_hash;

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();

    const pairs = try scratch.alloc(Pair, encoded_values.len);
    for (pairs, encoded_values, 0..) |*pair, value, index| {
        pair.* = .{
            .key = try indexKey(scratch, index),
            .value = value,
        };
    }
    return try root(allocator, pairs);
}

pub fn transactionRoot(allocator: Allocator, encoded_transactions: []const []const u8) Error![32]u8 {
    return orderedTrieRoot(allocator, encoded_transactions);
}

pub fn receiptRoot(allocator: Allocator, encoded_receipts: []const []const u8) Error![32]u8 {
    return orderedTrieRoot(allocator, encoded_receipts);
}

pub fn withdrawalsRoot(allocator: Allocator, withdrawals: []const Withdrawal) Error![32]u8 {
    if (withdrawals.len == 0) return empty_root_hash;

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();

    const values = try scratch.alloc([]const u8, withdrawals.len);
    for (values, withdrawals) |*value, withdrawal| {
        value.* = try withdrawalValue(scratch, withdrawal);
    }
    return try orderedTrieRoot(allocator, values);
}

pub fn updateRoot(allocator: Allocator, root_hash: [32]u8, nodes: []const []const u8, updates: []const Update) UpdateError![32]u8 {
    var indexed = try indexNodes(allocator, nodes);
    defer indexed.deinit();
    return updateRootIndexed(allocator, root_hash, indexed, updates);
}

fn updateRootIndexed(allocator: Allocator, root_hash: [32]u8, indexed: *const IndexedNodes, updates: []const Update) UpdateError![32]u8 {
    if (updates.len == 0) return root_hash;

    const sorted = try allocator.dupe(Update, updates);
    defer allocator.free(sorted);
    std.mem.sort(Update, sorted, {}, updateLessThan);
    try rejectDuplicateUpdates(sorted);

    const trie = structuralTrie(allocator);

    return trie.updateSorted(root_hash, indexed.index(), sorted);
}

fn storageRootAfterChangesIndexed(
    allocator: Allocator,
    root_hash: [32]u8,
    indexed: *const IndexedNodes,
    changes: ChangesView,
    target: address.Address,
) UpdateError![32]u8 {
    const scratch = allocator;

    var updates: std.ArrayList(StorageTrie.Update) = .empty;
    defer updates.deinit(scratch);

    var index: u32 = 0;
    while (index < changes.storage_writes.len()) : (index += 1) {
        const write = changes.storage_writes.at(index);
        if (!std.mem.eql(u8, &write.address, &target)) continue;

        const value: ?[]const u8 = if (write.value == 0)
            null
        else
            try storageValue(scratch, write.value);
        try updates.append(scratch, .{ .key = write.key, .value = value });
    }

    const base_root = if (changesWipeStorage(changes, target))
        empty_root_hash
    else
        root_hash;
    return storageTrie(allocator).update(base_root, indexed.index(), updates.items);
}

pub fn stateRootAfterChanges(
    allocator: Allocator,
    root_hash: [32]u8,
    nodes: []const []const u8,
    changes: ChangesView,
) UpdateError![32]u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    var indexed = try indexNodes(scratch, nodes);
    defer indexed.deinit();
    return stateRootAfterChangesIndexed(scratch, root_hash, indexed, changes);
}

pub fn stateRootAfterChangesIndexed(
    allocator: Allocator,
    root_hash: [32]u8,
    indexed: *const IndexedNodes,
    changes: ChangesView,
) UpdateError![32]u8 {
    const scratch = allocator;

    var addresses: std.ArrayList(address.Address) = .empty;
    defer addresses.deinit(scratch);

    var account_index: u32 = 0;
    while (account_index < changes.accounts.len()) : (account_index += 1) {
        const change = changes.accounts.at(account_index);
        if (change.account != null) {
            try appendUniqueAddress(scratch, &addresses, change.address);
        }
    }
    var storage_index: u32 = 0;
    while (storage_index < changes.storage_writes.len()) : (storage_index += 1) {
        const write = changes.storage_writes.at(storage_index);
        if (!changesDeleteAccount(changes, write.address)) {
            try appendUniqueAddress(scratch, &addresses, write.address);
        }
    }
    var wipe_index: u32 = 0;
    while (wipe_index < changes.storage_wipes.len()) : (wipe_index += 1) {
        const target = changes.storage_wipes.at(wipe_index);
        if (!changesDeleteAccount(changes, target)) {
            try appendUniqueAddress(scratch, &addresses, target);
        }
    }

    var updates: std.ArrayList(AccountTrie.Update) = .empty;
    defer updates.deinit(scratch);

    const accounts = accountTrie(scratch);
    for (addresses.items) |target| {
        const previous = try loadAccountOrEmpty(accounts, root_hash, indexed.index(), target);
        const account_change = changesAccount(changes, target);
        const storage_root = try storageRootAfterChangesIndexed(
            scratch,
            previous.storage_root,
            indexed,
            changes,
            target,
        );
        var next_account = previous;
        if (account_change) |change| {
            const account = change.account orelse unreachable;
            next_account.nonce = account.nonce;
            next_account.balance = account.balance;
            next_account.code_hash = account.code_hash;
        }
        next_account.storage_root = storage_root;

        const value: ?[]const u8 = if (next_account.isEmpty())
            null
        else
            try accountValueFrom(scratch, next_account);
        try updates.append(scratch, .{ .key = target, .value = value });
    }

    account_index = 0;
    while (account_index < changes.accounts.len()) : (account_index += 1) {
        const change = changes.accounts.at(account_index);
        if (change.account != null) continue;
        try updates.append(scratch, .{ .key = change.address, .value = null });
    }

    return accounts.update(root_hash, indexed.index(), updates.items);
}

pub fn hashedAddressKey(target: address.Address) [32]u8 {
    return AddressKeyContext.trieKey(.{}, target);
}

pub fn hashedStorageKey(key: u256) [32]u8 {
    return StorageKeyContext.trieKey(.{}, key);
}

pub fn storageValue(allocator: Allocator, value: u256) Allocator.Error![]u8 {
    var out = rlp.Writer.alloc(allocator);
    errdefer out.deinit();
    try writerInt(&out, u256, value);
    return try writerOwned(&out);
}

pub fn accountValue(
    allocator: Allocator,
    nonce: u64,
    balance: u256,
    storage_root: [32]u8,
    code_hash: [32]u8,
) Allocator.Error![]u8 {
    return accountValueFrom(allocator, .{
        .nonce = nonce,
        .balance = balance,
        .storage_root = storage_root,
        .code_hash = code_hash,
    });
}

pub fn accountValueFrom(allocator: Allocator, account: Account) Allocator.Error![]u8 {
    return encodeFixedRlp(Account, allocator, account);
}

pub fn decodeAccountValue(encoded: []const u8) ProofLookupError!Account {
    return rlp.decode(Account, encoded);
}

pub fn withdrawalValue(allocator: Allocator, withdrawal: Withdrawal) Allocator.Error![]u8 {
    return encodeFixedRlp(Withdrawal, allocator, withdrawal);
}

fn indexKey(allocator: Allocator, index: usize) Allocator.Error![]u8 {
    var out = rlp.Writer.alloc(allocator);
    errdefer out.deinit();
    try writerInt(&out, usize, index);
    return try writerOwned(&out);
}

fn loadAccountOrEmpty(
    accounts: AccountTrie,
    root_hash: mpt.Root,
    index: *const mpt.NodeIndex,
    target: address.Address,
) UpdateError!Account {
    return switch (try accounts.lookup(root_hash, index, target)) {
        .present => |encoded| try decodeAccountValue(encoded),
        .absent => .{},
    };
}

fn changesAccount(changes: ChangesView, target: address.Address) ?TrackedState.AccountChange {
    var index: u32 = 0;
    while (index < changes.accounts.len()) : (index += 1) {
        const change = changes.accounts.at(index);
        if (std.mem.eql(u8, &change.address, &target)) return change;
    }
    return null;
}

fn changesDeleteAccount(changes: ChangesView, target: address.Address) bool {
    const change = changesAccount(changes, target) orelse return false;
    return change.account == null;
}

fn changesWipeStorage(changes: ChangesView, target: address.Address) bool {
    var index: u32 = 0;
    while (index < changes.storage_wipes.len()) : (index += 1) {
        const wiped = changes.storage_wipes.at(index);
        if (std.mem.eql(u8, &wiped, &target)) return true;
    }
    return false;
}

fn appendUniqueAddress(allocator: Allocator, addresses: *std.ArrayList(address.Address), target: address.Address) Allocator.Error!void {
    for (addresses.items) |existing| {
        if (std.mem.eql(u8, &existing, &target)) return;
    }
    try addresses.append(allocator, target);
}

// Test-only canonical node builder for assembling partial witness bags below.
// Production root, proof, and sparse-update paths delegate to pkg/mpt.
fn encodeNode(allocator: Allocator, pairs: []const Pair, depth: usize) Error![]const u8 {
    std.debug.assert(pairs.len > 0);

    if (pairs.len == 1) {
        const suffix = try keyNibbles(allocator, pairs[0].key, depth, nibbleLen(pairs[0].key) - depth);
        return encodeLeaf(allocator, suffix, pairs[0].value);
    }

    const common = commonPrefixLen(pairs, depth);
    if (common > 0) {
        const prefix = try keyNibbles(allocator, pairs[0].key, depth, common);
        const child = try encodeNode(allocator, pairs, depth + common);
        const child_ref = try nodeReference(allocator, child);
        return encodeExtension(allocator, prefix, child_ref);
    }

    return encodeBranch(allocator, pairs, depth);
}

fn encodeLeaf(allocator: Allocator, suffix: []const u8, value: []const u8) Error![]const u8 {
    var payload: std.ArrayList(u8) = .empty;
    defer payload.deinit(allocator);

    const compact = try compactPath(allocator, suffix, true);
    try appendBytesItem(allocator, &payload, compact);
    try appendBytesItem(allocator, &payload, value);
    return try wrapList(allocator, payload.items);
}

fn encodeExtension(allocator: Allocator, prefix: []const u8, child_ref: []const u8) Error![]const u8 {
    var payload: std.ArrayList(u8) = .empty;
    defer payload.deinit(allocator);

    const compact = try compactPath(allocator, prefix, false);
    try appendBytesItem(allocator, &payload, compact);
    try payload.appendSlice(allocator, child_ref);
    return try wrapList(allocator, payload.items);
}

fn encodeBranch(allocator: Allocator, pairs: []const Pair, depth: usize) Error![]const u8 {
    var payload: std.ArrayList(u8) = .empty;
    defer payload.deinit(allocator);

    var branch_value: ?[]const u8 = null;
    var index: usize = 0;
    while (index < pairs.len and nibbleLen(pairs[index].key) == depth) : (index += 1) {
        if (branch_value != null) return error.DuplicateKey;
        branch_value = pairs[index].value;
    }

    for (0..16) |child_nibble| {
        if (index < pairs.len and nibbleLen(pairs[index].key) > depth and nibbleAt(pairs[index].key, depth) == child_nibble) {
            const start = index;
            while (index < pairs.len and nibbleLen(pairs[index].key) > depth and nibbleAt(pairs[index].key, depth) == child_nibble) {
                index += 1;
            }
            const child = try encodeNode(allocator, pairs[start..index], depth + 1);
            const child_ref = try nodeReference(allocator, child);
            try payload.appendSlice(allocator, child_ref);
        } else {
            try appendBytesItem(allocator, &payload, "");
        }
    }

    if (index != pairs.len) return error.DuplicateKey;
    try appendBytesItem(allocator, &payload, branch_value orelse "");
    return try wrapList(allocator, payload.items);
}

fn nodeReference(allocator: Allocator, encoded_node: []const u8) Allocator.Error![]const u8 {
    if (encoded_node.len < 32) return encoded_node;
    const digest = crypto.keccak256(encoded_node);

    var out = rlp.Writer.alloc(allocator);
    errdefer out.deinit();
    try writerBytes(&out, &digest);
    return try writerOwned(&out);
}

fn wrapList(allocator: Allocator, payload: []const u8) Allocator.Error![]const u8 {
    var out = rlp.Writer.alloc(allocator);
    errdefer out.deinit();
    try writerList(&out, payload);
    return try writerOwned(&out);
}

fn appendBytesItem(allocator: Allocator, payload: *std.ArrayList(u8), value: []const u8) Allocator.Error!void {
    var item = rlp.Writer.alloc(allocator);
    defer item.deinit();
    try writerBytes(&item, value);
    try payload.appendSlice(allocator, item.written());
}

fn compactPath(allocator: Allocator, nibbles: []const u8, terminal: bool) Allocator.Error![]const u8 {
    const odd = nibbles.len % 2 == 1;
    const out_len = 1 + (nibbles.len / 2);
    const out = try allocator.alloc(u8, out_len);

    const flags: u8 = (@as(u8, @intFromBool(terminal)) << 1) | @as(u8, @intFromBool(odd));
    var nibble_index: usize = 0;
    out[0] = flags << 4;
    if (odd) {
        out[0] |= nibbles[0];
        nibble_index = 1;
    }

    var out_index: usize = 1;
    while (nibble_index < nibbles.len) : ({
        nibble_index += 2;
        out_index += 1;
    }) {
        out[out_index] = (nibbles[nibble_index] << 4) | nibbles[nibble_index + 1];
    }
    return out;
}

fn keyNibbles(allocator: Allocator, key: []const u8, start: usize, len: usize) Allocator.Error![]u8 {
    const out = try allocator.alloc(u8, len);
    for (out, 0..) |*nibble, offset| {
        nibble.* = nibbleAt(key, start + offset);
    }
    return out;
}

fn commonPrefixLen(pairs: []const Pair, depth: usize) usize {
    const first = pairs[0].key;
    const limit = minNibbleLen(pairs);
    var len: usize = 0;
    while (depth + len < limit) : (len += 1) {
        const expected = nibbleAt(first, depth + len);
        for (pairs[1..]) |pair| {
            if (nibbleAt(pair.key, depth + len) != expected) return len;
        }
    }
    return len;
}

fn minNibbleLen(pairs: []const Pair) usize {
    var len = nibbleLen(pairs[0].key);
    for (pairs[1..]) |pair| {
        len = @min(len, nibbleLen(pair.key));
    }
    return len;
}

fn nibbleLen(key: []const u8) usize {
    return key.len * 2;
}

fn nibbleAt(key: []const u8, index: usize) u8 {
    const byte = key[index / 2];
    return if (index % 2 == 0) byte >> 4 else byte & 0x0f;
}

fn pairLessThan(_: void, lhs: Pair, rhs: Pair) bool {
    return std.mem.order(u8, lhs.key, rhs.key) == .lt;
}

fn updateLessThan(_: void, lhs: Update, rhs: Update) bool {
    return std.mem.order(u8, lhs.key, rhs.key) == .lt;
}

fn rejectDuplicateKeys(pairs: []const Pair) Error!void {
    if (pairs.len < 2) return;
    for (pairs[1..], 1..) |pair, index| {
        if (std.mem.eql(u8, pairs[index - 1].key, pair.key)) return error.DuplicateKey;
    }
}

fn rejectDuplicateUpdates(updates: []const Update) UpdateError!void {
    if (updates.len < 2) return;
    for (updates[1..], 1..) |update, index| {
        if (std.mem.eql(u8, updates[index - 1].key, update.key)) return error.DuplicateKey;
    }
}

/// Narrows encode errors for schemas containing only bounded integers and fixed byte arrays.
fn encodeFixedRlp(
    comptime T: type,
    allocator: Allocator,
    value: anytype,
) Allocator.Error![]u8 {
    return rlp.encodeAlloc(T, allocator, value) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.BufferTooSmall,
        error.EncodedLengthMismatch,
        error.EncodedLengthOverflow,
        error.ListLimitExceeded,
        => unreachable,
    };
}

fn writerBytes(writer: *rlp.Writer, value: []const u8) Allocator.Error!void {
    writer.bytes(value) catch |err| switch (err) {
        error.NoSpaceLeft => unreachable,
        error.OutOfMemory => return error.OutOfMemory,
    };
}

fn writerInt(writer: *rlp.Writer, comptime T: type, value: T) Allocator.Error!void {
    writer.int(T, value) catch |err| switch (err) {
        error.NoSpaceLeft => unreachable,
        error.OutOfMemory => return error.OutOfMemory,
    };
}

fn writerList(writer: *rlp.Writer, payload: []const u8) Allocator.Error!void {
    writer.listPayload(payload) catch |err| switch (err) {
        error.NoSpaceLeft => unreachable,
        error.OutOfMemory => return error.OutOfMemory,
    };
}

fn writerOwned(writer: *rlp.Writer) Allocator.Error![]u8 {
    return writer.toOwnedSlice() catch |err| switch (err) {
        error.BorrowedWriter => unreachable,
        error.OutOfMemory => return error.OutOfMemory,
    };
}

test "MPT root of empty trie matches Ethereum empty root" {
    try t.expectHex(&empty_root_hash, "56e81f171bcc55a6ff8345e692c0f86e5b48e01b996cadc001622fb5e363b421");
    try t.expectHex(&(try root(std.testing.allocator, &.{})), "56e81f171bcc55a6ff8345e692c0f86e5b48e01b996cadc001622fb5e363b421");
}

test "MPT root matches canonical string-key example" {
    const pairs = [_]Pair{
        .{ .key = "do", .value = "verb" },
        .{ .key = "dog", .value = "puppy" },
        .{ .key = "doge", .value = "coin" },
        .{ .key = "horse", .value = "stallion" },
    };
    try t.expectHex(&(try root(std.testing.allocator, &pairs)), "5991bb8c6514148a29db676a14ac506cd2cd5775ace63c30a4fe457715e9ac84");
}

test "MPT root handles hashed storage keys" {
    const allocator = std.testing.allocator;
    const key = hashedStorageKey(0);
    try t.expectHex(&key, "290decd9548b62a8d60345a988386fc84ba6bc95484008f6362f93160ef3e563");

    const value = try storageValue(allocator, 42);
    defer allocator.free(value);
    try t.expectHex(value, "2a");

    const pairs = [_]Pair{.{ .key = &key, .value = value }};
    try t.expectHex(&(try root(allocator, &pairs)), "81d1fa699f807735499cf6f7df860797cf66f6a66b565cfcda3fae3521eb6861");
}

test "MPT root handles index-keyed tries" {
    const pairs = [_]Pair{
        .{ .key = &[_]u8{0x80}, .value = "cat" },
        .{ .key = &[_]u8{0x0f}, .value = "dog" },
    };
    try t.expectHex(&(try root(std.testing.allocator, &pairs)), "cabbd0a353cb4d2df5e27b9ffeceed340ddbacdf54929b65524a961bfc318e04");
}

test "MPT ordered trie root uses RLP list indexes" {
    const values = [_][]const u8{ "cat", "dog" };
    try t.expectHex(&(try orderedTrieRoot(std.testing.allocator, &values)), "a2d85fc2849d6aec6107215f0e83954d4f25913d445387fc2c0ece0665219186");
    try t.expectHex(&(try transactionRoot(std.testing.allocator, &values)), "a2d85fc2849d6aec6107215f0e83954d4f25913d445387fc2c0ece0665219186");
    try t.expectHex(&(try receiptRoot(std.testing.allocator, &values)), "a2d85fc2849d6aec6107215f0e83954d4f25913d445387fc2c0ece0665219186");
    try t.expectHex(&(try orderedTrieRoot(std.testing.allocator, &.{})), "56e81f171bcc55a6ff8345e692c0f86e5b48e01b996cadc001622fb5e363b421");
}

test "MPT account value uses typed RLP with one allocation" {
    const input: Account = .{
        .nonce = 7,
        .balance = 42,
        .storage_root = [_]u8{0x11} ** 32,
        .code_hash = [_]u8{0x22} ** 32,
    };
    var direct_buffer: [128]u8 = undefined;
    const direct = try rlp.encode(Account, &direct_buffer, &input);

    var counted = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const before = counted.alloc_index;
    const encoded = try accountValueFrom(counted.allocator(), input);
    defer counted.allocator().free(encoded);

    try std.testing.expectEqual(before + 1, counted.alloc_index);
    try std.testing.expectEqualSlices(u8, direct, encoded);
    try std.testing.expectEqualDeep(input, try decodeAccountValue(encoded));
}

test "MPT withdrawals root encodes ordered withdrawals" {
    const withdrawals = [_]Withdrawal{
        .{
            .index = 1,
            .validator_index = 2,
            .address = address.addr(0x1000),
            .amount = 3,
        },
        .{
            .index = 4,
            .validator_index = 5,
            .address = address.addr(0x2000),
            .amount = 6,
        },
    };

    var direct_buffer: [64]u8 = undefined;
    const direct = try rlp.encode(Withdrawal, &direct_buffer, &withdrawals[0]);
    var counted = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const before = counted.alloc_index;
    const value0 = try withdrawalValue(counted.allocator(), withdrawals[0]);
    defer counted.allocator().free(value0);

    try std.testing.expectEqual(before + 1, counted.alloc_index);
    try std.testing.expectEqualSlices(u8, direct, value0);
    try t.expectHex(value0, "d8010294000000000000000000000000000000000000100003");
    try t.expectHex(&(try withdrawalsRoot(std.testing.allocator, &withdrawals)), "ba94e67f1ff34df6be897a534b805005dc84403f69a89614daa2283fa8b1862f");
    try t.expectHex(&(try withdrawalsRoot(std.testing.allocator, &.{})), "56e81f171bcc55a6ff8345e692c0f86e5b48e01b996cadc001622fb5e363b421");
}

test "MPT root rejects duplicate keys" {
    const pairs = [_]Pair{
        .{ .key = "dog", .value = "puppy" },
        .{ .key = "dog", .value = "hound" },
    };
    try std.testing.expectError(error.DuplicateKey, root(std.testing.allocator, &pairs));
}

test "MPT proof lookup resolves a root leaf" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const scratch = arena.allocator();

    const key = hashedStorageKey(0);
    const value = try storageValue(scratch, 42);
    const pairs = [_]Pair{.{ .key = &key, .value = value }};
    const root_node = try encodedRootForTest(scratch, &pairs);
    const root_hash = crypto.keccak256(root_node);
    const nodes = [_][]const u8{root_node};
    const indexed = try indexNodes(scratch, &nodes);

    const found = (try proof(root_hash, indexed).get(&key)).?;
    try std.testing.expectEqualSlices(u8, value, found);

    const missing_key = hashedStorageKey(1);
    try std.testing.expect(try proof(root_hash, indexed).get(&missing_key) == null);
}

test "MPT proof lookup walks hashed child nodes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const scratch = arena.allocator();

    var keys: [16][1]u8 = undefined;
    var values: [16][1]u8 = undefined;
    var pairs: [16]Pair = undefined;
    for (0..16) |index| {
        keys[index][0] = @intCast(0x10 + index);
        values[index][0] = @intCast(index + 1);
        pairs[index] = .{ .key = &keys[index], .value = &values[index] };
    }

    const sorted = try sortedPairsForTest(scratch, &pairs);
    const root_node = try encodeNode(scratch, sorted, 0);
    const child_node = try encodeNode(scratch, sorted, 1);
    try std.testing.expect(child_node.len >= 32);

    const root_hash = crypto.keccak256(root_node);
    const nodes = [_][]const u8{ root_node, child_node };
    const indexed = try indexNodes(scratch, &nodes);

    const found = (try proof(root_hash, indexed).get(&keys[14])).?;
    try std.testing.expectEqualSlices(u8, &values[14], found);

    const omitted_child = [_][]const u8{root_node};
    const omitted_indexed = try indexNodes(scratch, &omitted_child);
    try std.testing.expectError(error.MissingNode, proof(root_hash, omitted_indexed).get(&keys[14]));
}

test "MPT proof lookup proves branch absence" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const scratch = arena.allocator();

    const pairs = [_]Pair{
        .{ .key = &[_]u8{0x10}, .value = &[_]u8{0x01} },
        .{ .key = &[_]u8{0x12}, .value = &[_]u8{0x02} },
    };
    const root_node = try encodedRootForTest(scratch, &pairs);
    const root_hash = crypto.keccak256(root_node);
    const nodes = [_][]const u8{root_node};
    const indexed = try indexNodes(scratch, &nodes);

    try std.testing.expect(try proof(root_hash, indexed).get(&[_]u8{0x11}) == null);
}

test "MPT proof lookup rejects malformed compact paths" {
    const malformed = [_]u8{ 0xc2, 0x40, 0x80 };
    const root_hash = crypto.keccak256(&malformed);
    const nodes = [_][]const u8{&malformed};
    var indexed = try indexNodes(std.testing.allocator, &nodes);
    defer indexed.deinit();

    try std.testing.expectError(error.InvalidCompactPath, proof(root_hash, indexed).get(""));
}

test "MPT update root inserts into empty trie" {
    const allocator = std.testing.allocator;
    const update = [_]Update{.{ .key = "dog", .value = "puppy" }};

    const actual = try updateRoot(allocator, empty_root_hash, &.{}, &update);
    const expected_pairs = [_]Pair{.{ .key = "dog", .value = "puppy" }};
    const expected = try root(allocator, &expected_pairs);
    try std.testing.expectEqualSlices(u8, &expected, &actual);
}

test "MPT update root replaces and deletes a root leaf" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const scratch = arena.allocator();

    const base_pairs = [_]Pair{.{ .key = "dog", .value = "puppy" }};
    const root_node = try encodedRootForTest(scratch, &base_pairs);
    const root_hash = crypto.keccak256(root_node);
    const nodes = [_][]const u8{root_node};

    const replacement = [_]Update{.{ .key = "dog", .value = "hound" }};
    const replaced = try updateRoot(scratch, root_hash, &nodes, &replacement);
    const replaced_pairs = [_]Pair{.{ .key = "dog", .value = "hound" }};
    try std.testing.expectEqualSlices(u8, &(try root(scratch, &replaced_pairs)), &replaced);

    const deletion = [_]Update{.{ .key = "dog", .value = null }};
    try std.testing.expectEqualSlices(u8, &empty_root_hash, &(try updateRoot(scratch, root_hash, &nodes, &deletion)));
}

test "MPT update root materializes hashed child nodes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const scratch = arena.allocator();

    var keys: [16][1]u8 = undefined;
    var values: [16][1]u8 = undefined;
    var pairs: [16]Pair = undefined;
    for (0..16) |index| {
        keys[index][0] = @intCast(0x10 + index);
        values[index][0] = @intCast(index + 1);
        pairs[index] = .{ .key = &keys[index], .value = &values[index] };
    }

    const sorted = try sortedPairsForTest(scratch, &pairs);
    const root_node = try encodeNode(scratch, sorted, 0);
    const child_node = try encodeNode(scratch, sorted, 1);
    const root_hash = crypto.keccak256(root_node);
    const nodes = [_][]const u8{ root_node, child_node };

    const new_value = [_]u8{0xff};
    const updates = [_]Update{.{ .key = &keys[14], .value = &new_value }};
    const actual = try updateRoot(scratch, root_hash, &nodes, &updates);

    values[14][0] = 0xff;
    pairs[14] = .{ .key = &keys[14], .value = &values[14] };
    const expected = try root(scratch, &pairs);
    try std.testing.expectEqualSlices(u8, &expected, &actual);

    const omitted_child = [_][]const u8{root_node};
    try std.testing.expectError(error.MissingNode, updateRoot(scratch, root_hash, &omitted_child, &updates));
}

test "MPT update root preserves unrevealed hashed siblings" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const scratch = arena.allocator();

    var keys: [32][1]u8 = undefined;
    var values: [32][1]u8 = undefined;
    var pairs: [32]Pair = undefined;
    for (0..16) |index| {
        keys[index][0] = @intCast(0x10 + index);
        values[index][0] = @intCast(index + 1);
        pairs[index] = .{ .key = &keys[index], .value = &values[index] };
    }
    for (16..32) |index| {
        keys[index][0] = @intCast(0x20 + index - 16);
        values[index][0] = @intCast(index + 1);
        pairs[index] = .{ .key = &keys[index], .value = &values[index] };
    }

    const sorted = try sortedPairsForTest(scratch, &pairs);
    const root_node = try encodeNode(scratch, sorted, 0);
    const revealed_child = try encodeNode(scratch, sorted[0..16], 1);
    const unrevealed_child = try encodeNode(scratch, sorted[16..32], 1);
    try std.testing.expect(revealed_child.len >= 32);
    try std.testing.expect(unrevealed_child.len >= 32);

    const root_hash = crypto.keccak256(root_node);
    const nodes = [_][]const u8{ root_node, revealed_child };

    const new_value = [_]u8{0xee};
    const updates = [_]Update{.{ .key = &keys[3], .value = &new_value }};
    const actual = try updateRoot(scratch, root_hash, &nodes, &updates);

    values[3][0] = 0xee;
    pairs[3] = .{ .key = &keys[3], .value = &values[3] };
    const expected = try root(scratch, &pairs);
    try std.testing.expectEqualSlices(u8, &expected, &actual);
}

test "MPT update root deletes and compresses branch" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const scratch = arena.allocator();

    const base_pairs = [_]Pair{
        .{ .key = &[_]u8{0x10}, .value = &[_]u8{0x01} },
        .{ .key = &[_]u8{0x12}, .value = &[_]u8{0x02} },
    };
    const root_node = try encodedRootForTest(scratch, &base_pairs);
    const root_hash = crypto.keccak256(root_node);
    const nodes = [_][]const u8{root_node};

    const updates = [_]Update{.{ .key = &[_]u8{0x12}, .value = null }};
    const actual = try updateRoot(scratch, root_hash, &nodes, &updates);
    const expected_pairs = [_]Pair{.{ .key = &[_]u8{0x10}, .value = &[_]u8{0x01} }};
    const expected = try root(scratch, &expected_pairs);
    try std.testing.expectEqualSlices(u8, &expected, &actual);
}

test "MPT update root delete materializes hashed sibling before branch collapse" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const scratch = arena.allocator();

    const deleted_key = [_]u8{0x10};
    const remaining_key = [_]u8{0x20};
    var large_value = [_]u8{0xab} ** 40;
    const base_pairs = [_]Pair{
        .{ .key = &deleted_key, .value = &[_]u8{0x01} },
        .{ .key = &remaining_key, .value = &large_value },
    };
    const sorted = try sortedPairsForTest(scratch, &base_pairs);
    const root_node = try encodeNode(scratch, sorted, 0);
    const hidden_sibling = try encodeNode(scratch, sorted[1..2], 1);
    try std.testing.expect(hidden_sibling.len >= 32);

    const root_hash = crypto.keccak256(root_node);
    const updates = [_]Update{.{ .key = &deleted_key, .value = null }};

    const nodes = [_][]const u8{ root_node, hidden_sibling };
    const actual = try updateRoot(scratch, root_hash, &nodes, &updates);
    const expected_pairs = [_]Pair{.{ .key = &remaining_key, .value = &large_value }};
    const expected = try root(scratch, &expected_pairs);
    try std.testing.expectEqualSlices(u8, &expected, &actual);

    const omitted_sibling = [_][]const u8{root_node};
    try std.testing.expectError(error.MissingNode, updateRoot(scratch, root_hash, &omitted_sibling, &updates));
}

test "MPT state root consumes tracked changes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const scratch = arena.allocator();

    const target = address.addr(0x1000);
    var state = TrackedState.init(scratch);
    defer state.deinit();
    const attempt = state.beginTransaction();
    state.beginScope();
    try state.setBalance(target, 20);
    _ = try state.setStorage(target, 1, 7);
    state.closeScope();
    state.seal(attempt);
    state.retain(attempt);
    const changes = state.acceptedView().changes();

    const direct = try stateRootAfterChanges(scratch, empty_root_hash, &.{}, changes);
    const storage_key = hashedStorageKey(1);
    const storage_value = try storageValue(scratch, 7);
    const storage_root = try root(scratch, &.{.{ .key = &storage_key, .value = storage_value }});
    const account_key = hashedAddressKey(target);
    const account_value = try accountValueFrom(scratch, .{
        .balance = 20,
        .storage_root = storage_root,
    });
    const expected = try root(scratch, &.{.{ .key = &account_key, .value = account_value }});
    try std.testing.expectEqualSlices(u8, &expected, &direct);

    const wiped = state.beginTransaction();
    state.beginScope();
    try state.setBalance(target, 0);
    try state.markSelfdestructed(target);
    try state.finalize(.{ .existing_account = .{
        .reset_account = true,
        .clear_storage = true,
    } });
    state.closeScope();
    state.seal(wiped);
    state.retain(wiped);
    const wiped_changes = state.acceptedView().changes();
    try std.testing.expectEqual(@as(u32, 1), wiped_changes.storage_wipes.len());
    try std.testing.expectEqual(@as(u32, 0), wiped_changes.storage_writes.len());

    const wiped_direct = try stateRootAfterChanges(
        scratch,
        empty_root_hash,
        &.{},
        wiped_changes,
    );
    try std.testing.expectEqualSlices(u8, &empty_root_hash, &wiped_direct);
}

fn sortedPairsForTest(allocator: Allocator, pairs: []const Pair) ![]Pair {
    const sorted = try allocator.dupe(Pair, pairs);
    std.mem.sort(Pair, sorted, {}, pairLessThan);
    try rejectDuplicateKeys(sorted);
    return sorted;
}

fn encodedRootForTest(allocator: Allocator, pairs: []const Pair) ![]const u8 {
    const sorted = try sortedPairsForTest(allocator, pairs);
    return try encodeNode(allocator, sorted, 0);
}
