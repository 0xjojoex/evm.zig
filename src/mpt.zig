//! Ethereum execution MPT helpers for root construction, proof lookup, and
//! witness-backed root updates.
//! This is not a persistent trie database or a complete general-purpose MPT library.

const std = @import("std");

const address = @import("./address.zig");
const crypto = @import("./crypto.zig");
const rlp = @import("rlp");
const uint256 = @import("./uint256.zig");
const Changeset = @import("./state/Changeset.zig");
const t = @import("./t.zig");

const Allocator = std.mem.Allocator;

pub const Error = Allocator.Error || error{DuplicateKey};

pub const ProofLookupError = rlp.DecodeError || error{
    InvalidCompactPath,
    InvalidNode,
    InvalidNodeReference,
    MissingNode,
};

pub const UpdateError = Allocator.Error || ProofLookupError || error{DuplicateKey};

pub const empty_root_hash = [_]u8{
    0x56, 0xe8, 0x1f, 0x17, 0x1b, 0xcc, 0x55, 0xa6,
    0xff, 0x83, 0x45, 0xe6, 0x92, 0xc0, 0xf8, 0x6e,
    0x5b, 0x48, 0xe0, 0x1b, 0x99, 0x6c, 0xad, 0xc0,
    0x01, 0x62, 0x2f, 0xb5, 0xe3, 0x63, 0xb4, 0x21,
};

pub const empty_code_hash = crypto.keccak256_empty;

pub const Pair = struct {
    key: []const u8,
    value: []const u8,
};

pub const Account = struct {
    nonce: u64 = 0,
    balance: u256 = 0,
    storage_root: [32]u8 = empty_root_hash,
    code_hash: [32]u8 = empty_code_hash,

    pub fn isEmpty(self: Account) bool {
        return self.nonce == 0 and
            self.balance == 0 and
            std.mem.eql(u8, &self.storage_root, &empty_root_hash) and
            std.mem.eql(u8, &self.code_hash, &empty_code_hash);
    }
};

pub const Withdrawal = struct {
    index: u64,
    validator_index: u64,
    address: address.Address,
    amount: u64,
};

pub const Update = struct {
    key: []const u8,
    value: ?[]const u8,
};

pub const Proof = struct {
    root_hash: [32]u8,
    nodes: []const []const u8,

    pub fn get(self: Proof, key: []const u8) ProofLookupError!?[]const u8 {
        if (std.mem.eql(u8, &self.root_hash, &empty_root_hash)) return null;
        const root_node = resolveNodeHash(self.nodes, self.root_hash) orelse return error.MissingNode;
        return try walkProofNode(self.nodes, root_node, key, 0);
    }
};

pub fn root(allocator: Allocator, pairs: []const Pair) Error![32]u8 {
    if (pairs.len == 0) return empty_root_hash;

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();

    const sorted = try scratch.dupe(Pair, pairs);
    std.mem.sort(Pair, sorted, {}, pairLessThan);
    try rejectDuplicateKeys(sorted);

    const encoded_root = try encodeNode(scratch, sorted, 0);
    return crypto.keccak256(encoded_root);
}

pub fn proof(root_hash: [32]u8, nodes: []const []const u8) Proof {
    return .{ .root_hash = root_hash, .nodes = nodes };
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
    if (updates.len == 0) return root_hash;

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();

    const sorted = try scratch.dupe(Update, updates);
    std.mem.sort(Update, sorted, {}, updateLessThan);
    try rejectDuplicateUpdates(sorted);

    const root_node = if (std.mem.eql(u8, &root_hash, &empty_root_hash))
        try newSparseNode(scratch, .empty)
    else root: {
        const root_encoded = resolveNodeHash(nodes, root_hash) orelse return error.MissingNode;
        break :root try decodeSparseNode(scratch, nodes, root_encoded);
    };

    for (sorted) |update| {
        const key_path = try keyNibbles(scratch, update.key, 0, nibbleLen(update.key));
        if (update.value) |value| {
            try insertSparse(scratch, nodes, root_node, key_path, value);
        } else {
            try deleteSparse(scratch, nodes, root_node, key_path);
        }
    }

    const encoded_root = try encodeSparseNode(scratch, root_node) orelse return empty_root_hash;
    return crypto.keccak256(encoded_root);
}

pub fn storageRootAfterChangeset(
    allocator: Allocator,
    root_hash: [32]u8,
    nodes: []const []const u8,
    changeset: *const Changeset,
    target: address.Address,
) UpdateError![32]u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();

    var updates: std.ArrayList(Update) = .empty;
    defer updates.deinit(scratch);

    for (changeset.storage_writes.items) |write| {
        if (!std.mem.eql(u8, &write.address, &target)) continue;

        const key = try scratch.alloc(u8, 32);
        const hashed_key = hashedStorageKey(write.key);
        @memcpy(key, &hashed_key);

        const value: ?[]const u8 = if (write.value == 0)
            null
        else
            try storageValue(scratch, write.value);
        try updates.append(scratch, .{ .key = key, .value = value });
    }

    return try updateRoot(allocator, root_hash, nodes, updates.items);
}

pub fn stateRootAfterChangeset(
    allocator: Allocator,
    root_hash: [32]u8,
    nodes: []const []const u8,
    changeset: *const Changeset,
) UpdateError![32]u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();

    var addresses: std.ArrayList(address.Address) = .empty;
    defer addresses.deinit(scratch);

    for (changeset.account_updates.items) |update| {
        if (!changesetDeletesAccount(changeset, update.address)) {
            try appendUniqueAddress(scratch, &addresses, update.address);
        }
    }
    for (changeset.storage_writes.items) |write| {
        if (!changesetDeletesAccount(changeset, write.address)) {
            try appendUniqueAddress(scratch, &addresses, write.address);
        }
    }

    var updates: std.ArrayList(Update) = .empty;
    defer updates.deinit(scratch);

    const state = proof(root_hash, nodes);
    for (addresses.items) |target| {
        const account_key = try hashedAddressKeyOwned(scratch, target);
        const previous = try loadAccountOrEmpty(state, account_key);
        const account_update = changesetAccountUpdate(changeset, target);
        const storage_root = try storageRootAfterChangeset(scratch, previous.storage_root, nodes, changeset, target);
        const next_account = accountAfterUpdate(previous, account_update, storage_root);

        const value: ?[]const u8 = if (next_account.isEmpty())
            null
        else
            try accountValueFrom(scratch, next_account);
        try updates.append(scratch, .{ .key = account_key, .value = value });
    }

    for (changeset.account_deletes.items) |deleted| {
        try updates.append(scratch, .{
            .key = try hashedAddressKeyOwned(scratch, deleted),
            .value = null,
        });
    }

    return try updateRoot(allocator, root_hash, nodes, updates.items);
}

pub fn hashedAddressKey(target: address.Address) [32]u8 {
    return crypto.keccak256(&target);
}

fn hashedAddressKeyOwned(allocator: Allocator, target: address.Address) Allocator.Error![]u8 {
    const out = try allocator.alloc(u8, 32);
    const key = hashedAddressKey(target);
    @memcpy(out, &key);
    return out;
}

pub fn hashedStorageKey(key: u256) [32]u8 {
    return crypto.keccak256(&uint256.toBytes32(key));
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

pub fn codeHash(code: []const u8) [32]u8 {
    return crypto.keccak256(code);
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

fn loadAccountOrEmpty(state: Proof, account_key: []const u8) UpdateError!Account {
    const encoded = try state.get(account_key) orelse return .{};
    return try decodeAccountValue(encoded);
}

fn accountAfterUpdate(previous: Account, update: ?Changeset.AccountUpdate, storage_root: [32]u8) Account {
    var account = previous;
    if (update) |account_update| {
        account.nonce = account_update.nonce;
        account.balance = account_update.balance;
        account.code_hash = account_update.code_hash;
    }
    account.storage_root = storage_root;
    return account;
}

fn changesetAccountUpdate(changeset: *const Changeset, target: address.Address) ?Changeset.AccountUpdate {
    for (changeset.account_updates.items) |update| {
        if (std.mem.eql(u8, &update.address, &target)) return update;
    }
    return null;
}

fn changesetDeletesAccount(changeset: *const Changeset, target: address.Address) bool {
    for (changeset.account_deletes.items) |deleted| {
        if (std.mem.eql(u8, &deleted, &target)) return true;
    }
    return false;
}

fn appendUniqueAddress(allocator: Allocator, addresses: *std.ArrayList(address.Address), target: address.Address) Allocator.Error!void {
    for (addresses.items) |existing| {
        if (std.mem.eql(u8, &existing, &target)) return;
    }
    try addresses.append(allocator, target);
}

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

fn walkProofNode(nodes: []const []const u8, encoded_node: []const u8, key: []const u8, depth: usize) ProofLookupError!?[]const u8 {
    const node = try singleList(encoded_node);
    const field_count = try listFieldCount(node);
    return switch (field_count) {
        2 => walkShortNode(nodes, node, key, depth),
        17 => walkBranchNode(nodes, node, key, depth),
        else => error.InvalidNode,
    };
}

fn walkShortNode(nodes: []const []const u8, node: rlp.Item, key: []const u8, depth: usize) ProofLookupError!?[]const u8 {
    var fields = try node.listCursor();
    const compact = try fields.nextBytes();
    const path = try CompactPath.init(compact);
    const value_or_ref = try fields.next();
    try fields.expectDone();

    if (!path.matchesKey(key, depth)) return null;

    if (path.terminal) {
        if (depth + path.len != nibbleLen(key)) return null;
        return try value_or_ref.asBytes();
    }

    if (path.len == 0) return error.InvalidNode;
    const child_node = try resolveChildReference(nodes, value_or_ref) orelse return error.InvalidNodeReference;
    return try walkProofNode(nodes, child_node, key, depth + path.len);
}

fn walkBranchNode(nodes: []const []const u8, node: rlp.Item, key: []const u8, depth: usize) ProofLookupError!?[]const u8 {
    if (depth > nibbleLen(key)) return error.InvalidNode;

    var fields = try node.listCursor();
    var target_child: ?rlp.Item = null;

    for (0..16) |child_nibble| {
        const child = try fields.next();
        if (depth < nibbleLen(key) and child_nibble == nibbleAt(key, depth)) {
            target_child = child;
        }
    }

    const branch_value = try fields.nextBytes();
    try fields.expectDone();

    if (depth == nibbleLen(key)) {
        return if (branch_value.len == 0) null else branch_value;
    }

    const child_node = try resolveChildReference(nodes, target_child.?) orelse return null;
    return try walkProofNode(nodes, child_node, key, depth + 1);
}

fn singleList(encoded: []const u8) ProofLookupError!rlp.Item {
    var cursor = rlp.Cursor.init(encoded);
    const node = try cursor.next();
    try cursor.expectDone();
    if (node.kind() != .list) return error.InvalidNode;
    return node;
}

fn listFieldCount(node: rlp.Item) ProofLookupError!usize {
    var cursor = try node.listCursor();
    var count: usize = 0;
    while (!cursor.isDone()) {
        _ = try cursor.next();
        count += 1;
    }
    return count;
}

fn resolveChildReference(nodes: []const []const u8, reference: rlp.Item) ProofLookupError!?[]const u8 {
    return switch (reference) {
        .list => {
            if (reference.encoded().len >= 32) return error.InvalidNodeReference;
            return reference.encoded();
        },
        .bytes => |span| {
            if (span.payload.len == 0) return null;
            if (span.payload.len != 32) return error.InvalidNodeReference;

            var hash: [32]u8 = undefined;
            @memcpy(&hash, span.payload);
            const node = resolveNodeHash(nodes, hash) orelse return error.MissingNode;
            if (node.len < 32) return error.InvalidNodeReference;
            return node;
        },
    };
}

fn resolveNodeHash(nodes: []const []const u8, hash: [32]u8) ?[]const u8 {
    for (nodes) |node| {
        const node_hash = crypto.keccak256(node);
        if (std.mem.eql(u8, &node_hash, &hash)) return node;
    }
    return null;
}

const CompactPath = struct {
    bytes: []const u8,
    len: usize,
    terminal: bool,
    odd: bool,

    fn init(bytes: []const u8) ProofLookupError!CompactPath {
        if (bytes.len == 0) return error.InvalidCompactPath;
        const flags = bytes[0] >> 4;
        if (flags > 3) return error.InvalidCompactPath;

        const odd = (flags & 1) == 1;
        if (!odd and bytes[0] & 0x0f != 0) return error.InvalidCompactPath;

        return .{
            .bytes = bytes,
            .len = (bytes.len - 1) * 2 + @intFromBool(odd),
            .terminal = (flags & 2) != 0,
            .odd = odd,
        };
    }

    fn matchesKey(self: CompactPath, key: []const u8, depth: usize) bool {
        if (depth + self.len > nibbleLen(key)) return false;
        for (0..self.len) |offset| {
            if (self.pathNibbleAt(offset) != nibbleAt(key, depth + offset)) return false;
        }
        return true;
    }

    fn pathNibbleAt(self: CompactPath, index: usize) u8 {
        if (self.odd) {
            if (index == 0) return self.bytes[0] & 0x0f;
            const adjusted = index - 1;
            const byte = self.bytes[1 + adjusted / 2];
            return if (adjusted % 2 == 0) byte >> 4 else byte & 0x0f;
        }

        const byte = self.bytes[1 + index / 2];
        return if (index % 2 == 0) byte >> 4 else byte & 0x0f;
    }

    fn toOwnedNibbles(self: CompactPath, allocator: Allocator) Allocator.Error![]u8 {
        const out = try allocator.alloc(u8, self.len);
        for (out, 0..) |*nibble, index| {
            nibble.* = self.pathNibbleAt(index);
        }
        return out;
    }
};

const SparseNode = union(enum) {
    empty,
    hash: [32]u8,
    leaf: Leaf,
    extension: Extension,
    branch: Branch,

    const Leaf = struct {
        path: []const u8,
        value: []const u8,
    };

    const Extension = struct {
        path: []const u8,
        child: *SparseNode,
    };

    const Branch = struct {
        children: [16]?*SparseNode,
        value: ?[]const u8,
    };
};

fn newSparseNode(allocator: Allocator, node: SparseNode) Allocator.Error!*SparseNode {
    const ptr = try allocator.create(SparseNode);
    ptr.* = node;
    return ptr;
}

fn emptyBranch() SparseNode.Branch {
    return .{
        .children = [_]?*SparseNode{null} ** 16,
        .value = null,
    };
}

fn decodeSparseNode(allocator: Allocator, nodes: []const []const u8, encoded_node: []const u8) UpdateError!*SparseNode {
    const node = try singleList(encoded_node);
    const field_count = try listFieldCount(node);
    return switch (field_count) {
        2 => decodeShortSparseNode(allocator, nodes, node),
        17 => decodeBranchSparseNode(allocator, nodes, node),
        else => error.InvalidNode,
    };
}

fn decodeShortSparseNode(allocator: Allocator, nodes: []const []const u8, node: rlp.Item) UpdateError!*SparseNode {
    var fields = try node.listCursor();
    const compact = try fields.nextBytes();
    const path = try CompactPath.init(compact);
    const nibbles = try path.toOwnedNibbles(allocator);
    const value_or_ref = try fields.next();
    try fields.expectDone();

    if (path.terminal) {
        return try newSparseNode(allocator, .{ .leaf = .{
            .path = nibbles,
            .value = try value_or_ref.asBytes(),
        } });
    }

    if (path.len == 0) return error.InvalidNode;
    const child = try decodeSparseChildReference(allocator, nodes, value_or_ref) orelse return error.InvalidNodeReference;
    return try newSparseNode(allocator, .{ .extension = .{
        .path = nibbles,
        .child = child,
    } });
}

fn decodeBranchSparseNode(allocator: Allocator, nodes: []const []const u8, node: rlp.Item) UpdateError!*SparseNode {
    var fields = try node.listCursor();
    var branch = emptyBranch();

    for (0..16) |child_nibble| {
        const child = try fields.next();
        branch.children[child_nibble] = try decodeSparseChildReference(allocator, nodes, child);
    }

    const value = try fields.nextBytes();
    if (value.len != 0) branch.value = value;
    try fields.expectDone();

    return try newSparseNode(allocator, .{ .branch = branch });
}

fn decodeSparseChildReference(allocator: Allocator, nodes: []const []const u8, reference: rlp.Item) UpdateError!?*SparseNode {
    return switch (reference) {
        .list => {
            if (reference.encoded().len >= 32) return error.InvalidNodeReference;
            return try decodeSparseNode(allocator, nodes, reference.encoded());
        },
        .bytes => |span| {
            if (span.payload.len == 0) return null;
            if (span.payload.len != 32) return error.InvalidNodeReference;

            var hash: [32]u8 = undefined;
            @memcpy(&hash, span.payload);
            return try newSparseNode(allocator, .{ .hash = hash });
        },
    };
}

fn materializeHash(allocator: Allocator, nodes: []const []const u8, node: *SparseNode) UpdateError!void {
    switch (node.*) {
        .hash => |hash| {
            const encoded = resolveNodeHash(nodes, hash) orelse return error.MissingNode;
            if (encoded.len < 32) return error.InvalidNodeReference;
            const decoded = try decodeSparseNode(allocator, nodes, encoded);
            node.* = decoded.*;
        },
        else => {},
    }
}

fn insertSparse(allocator: Allocator, nodes: []const []const u8, node: *SparseNode, key: []const u8, value: []const u8) UpdateError!void {
    try materializeHash(allocator, nodes, node);
    switch (node.*) {
        .empty => node.* = .{ .leaf = .{ .path = key, .value = value } },
        .hash => unreachable,
        .leaf => |leaf| try insertIntoLeaf(allocator, node, leaf, key, value),
        .extension => |extension| try insertIntoExtension(allocator, nodes, node, extension, key, value),
        .branch => |branch| try insertIntoBranch(allocator, nodes, node, branch, key, value),
    }
}

fn insertIntoLeaf(allocator: Allocator, node: *SparseNode, leaf: SparseNode.Leaf, key: []const u8, value: []const u8) UpdateError!void {
    const common = commonNibblePrefix(leaf.path, key);
    if (common == leaf.path.len and common == key.len) {
        node.* = .{ .leaf = .{ .path = leaf.path, .value = value } };
        return;
    }

    const branch_node = try splitValueAndValue(allocator, leaf.path[common..], leaf.value, key[common..], value);
    node.* = if (common == 0)
        branch_node.*
    else
        .{ .extension = .{
            .path = key[0..common],
            .child = branch_node,
        } };
}

fn insertIntoExtension(
    allocator: Allocator,
    nodes: []const []const u8,
    node: *SparseNode,
    extension: SparseNode.Extension,
    key: []const u8,
    value: []const u8,
) UpdateError!void {
    const common = commonNibblePrefix(extension.path, key);
    if (common == extension.path.len) {
        try insertSparse(allocator, nodes, extension.child, key[common..], value);
        node.* = .{ .extension = extension };
        return;
    }

    var branch = emptyBranch();
    const old_remaining = extension.path[common..];
    branch.children[old_remaining[0]] = if (old_remaining.len == 1)
        extension.child
    else
        try newSparseNode(allocator, .{ .extension = .{
            .path = old_remaining[1..],
            .child = extension.child,
        } });

    const new_remaining = key[common..];
    if (new_remaining.len == 0) {
        branch.value = value;
    } else {
        branch.children[new_remaining[0]] = try newSparseNode(allocator, .{ .leaf = .{
            .path = new_remaining[1..],
            .value = value,
        } });
    }

    const branch_node = try newSparseNode(allocator, .{ .branch = branch });
    node.* = if (common == 0)
        branch_node.*
    else
        .{ .extension = .{
            .path = key[0..common],
            .child = branch_node,
        } };
}

fn insertIntoBranch(
    allocator: Allocator,
    nodes: []const []const u8,
    node: *SparseNode,
    branch: SparseNode.Branch,
    key: []const u8,
    value: []const u8,
) UpdateError!void {
    var next = branch;
    if (key.len == 0) {
        next.value = value;
        node.* = .{ .branch = next };
        return;
    }

    const child_index = key[0];
    const child = next.children[child_index] orelse try newSparseNode(allocator, .empty);
    try insertSparse(allocator, nodes, child, key[1..], value);
    next.children[child_index] = child;
    node.* = .{ .branch = next };
}

fn splitValueAndValue(
    allocator: Allocator,
    old_path: []const u8,
    old_value: []const u8,
    new_path: []const u8,
    new_value: []const u8,
) UpdateError!*SparseNode {
    var branch = emptyBranch();
    if (old_path.len == 0) {
        branch.value = old_value;
    } else {
        branch.children[old_path[0]] = try newSparseNode(allocator, .{ .leaf = .{
            .path = old_path[1..],
            .value = old_value,
        } });
    }

    if (new_path.len == 0) {
        branch.value = new_value;
    } else {
        branch.children[new_path[0]] = try newSparseNode(allocator, .{ .leaf = .{
            .path = new_path[1..],
            .value = new_value,
        } });
    }

    return try newSparseNode(allocator, .{ .branch = branch });
}

fn deleteSparse(allocator: Allocator, nodes: []const []const u8, node: *SparseNode, key: []const u8) UpdateError!void {
    try materializeHash(allocator, nodes, node);
    switch (node.*) {
        .empty => {},
        .hash => unreachable,
        .leaf => |leaf| {
            if (std.mem.eql(u8, leaf.path, key)) node.* = .empty;
        },
        .extension => |extension| {
            if (!startsWithNibbles(key, extension.path)) return;
            try deleteSparse(allocator, nodes, extension.child, key[extension.path.len..]);
            try compressExtension(allocator, node, extension);
        },
        .branch => |branch| try deleteFromBranch(allocator, nodes, node, branch, key),
    }
}

fn deleteFromBranch(
    allocator: Allocator,
    nodes: []const []const u8,
    node: *SparseNode,
    branch: SparseNode.Branch,
    key: []const u8,
) UpdateError!void {
    var next = branch;
    if (key.len == 0) {
        next.value = null;
    } else if (next.children[key[0]]) |child| {
        try deleteSparse(allocator, nodes, child, key[1..]);
        if (isEmptyNode(child)) next.children[key[0]] = null;
    }
    try compressBranch(allocator, nodes, node, next);
}

fn compressExtension(allocator: Allocator, node: *SparseNode, extension: SparseNode.Extension) UpdateError!void {
    switch (extension.child.*) {
        .empty => node.* = .empty,
        .hash, .branch => node.* = .{ .extension = extension },
        .leaf => |leaf| node.* = .{ .leaf = .{
            .path = try concatNibbles(allocator, extension.path, leaf.path),
            .value = leaf.value,
        } },
        .extension => |child_extension| node.* = .{ .extension = .{
            .path = try concatNibbles(allocator, extension.path, child_extension.path),
            .child = child_extension.child,
        } },
    }
}

fn compressBranch(allocator: Allocator, nodes: []const []const u8, node: *SparseNode, branch: SparseNode.Branch) UpdateError!void {
    var child_count: usize = 0;
    var only_child_index: usize = 0;
    var only_child: ?*SparseNode = null;

    for (branch.children, 0..) |child, index| {
        if (child == null) continue;
        child_count += 1;
        only_child_index = index;
        only_child = child;
    }

    if (branch.value) |value| {
        node.* = if (child_count == 0)
            .{ .leaf = .{ .path = &.{}, .value = value } }
        else
            .{ .branch = branch };
        return;
    }

    if (child_count == 0) {
        node.* = .empty;
        return;
    }

    if (child_count > 1) {
        node.* = .{ .branch = branch };
        return;
    }

    const child = only_child.?;
    try materializeHash(allocator, nodes, child);
    const child_nibble: u8 = @intCast(only_child_index);
    switch (child.*) {
        .empty => node.* = .empty,
        .hash => unreachable,
        .branch => node.* = .{ .extension = .{
            .path = try singleNibble(allocator, child_nibble),
            .child = child,
        } },
        .leaf => |leaf| node.* = .{ .leaf = .{
            .path = try prependNibble(allocator, child_nibble, leaf.path),
            .value = leaf.value,
        } },
        .extension => |extension| node.* = .{ .extension = .{
            .path = try prependNibble(allocator, child_nibble, extension.path),
            .child = extension.child,
        } },
    }
}

fn encodeSparseNode(allocator: Allocator, node: *const SparseNode) UpdateError!?[]const u8 {
    return switch (node.*) {
        .empty => null,
        .hash => error.InvalidNode,
        .leaf => |leaf| try encodeLeaf(allocator, leaf.path, leaf.value),
        .extension => |extension| extension: {
            const child_ref = try sparseNodeReference(allocator, extension.child) orelse return error.InvalidNode;
            break :extension try encodeExtension(allocator, extension.path, child_ref);
        },
        .branch => |branch| try encodeSparseBranch(allocator, branch),
    };
}

fn encodeSparseBranch(allocator: Allocator, branch: SparseNode.Branch) UpdateError![]const u8 {
    var payload: std.ArrayList(u8) = .empty;
    defer payload.deinit(allocator);

    for (branch.children) |child| {
        if (child) |present| {
            const child_ref = try sparseNodeReference(allocator, present) orelse return error.InvalidNode;
            try payload.appendSlice(allocator, child_ref);
        } else {
            try appendBytesItem(allocator, &payload, "");
        }
    }

    try appendBytesItem(allocator, &payload, branch.value orelse "");
    return try wrapList(allocator, payload.items);
}

fn sparseNodeReference(allocator: Allocator, node: *const SparseNode) UpdateError!?[]const u8 {
    return switch (node.*) {
        .empty => null,
        .hash => |hash| try hashReference(allocator, hash),
        else => try nodeReference(allocator, (try encodeSparseNode(allocator, node)).?),
    };
}

fn hashReference(allocator: Allocator, hash: [32]u8) Allocator.Error![]const u8 {
    var out = rlp.Writer.alloc(allocator);
    errdefer out.deinit();
    try writerBytes(&out, &hash);
    return try writerOwned(&out);
}

fn isEmptyNode(node: *const SparseNode) bool {
    return node.* == .empty;
}

fn commonNibblePrefix(lhs: []const u8, rhs: []const u8) usize {
    const limit = @min(lhs.len, rhs.len);
    var len: usize = 0;
    while (len < limit and lhs[len] == rhs[len]) : (len += 1) {}
    return len;
}

fn startsWithNibbles(key: []const u8, prefix: []const u8) bool {
    return key.len >= prefix.len and std.mem.eql(u8, key[0..prefix.len], prefix);
}

fn concatNibbles(allocator: Allocator, lhs: []const u8, rhs: []const u8) Allocator.Error![]u8 {
    const out = try allocator.alloc(u8, lhs.len + rhs.len);
    @memcpy(out[0..lhs.len], lhs);
    @memcpy(out[lhs.len..], rhs);
    return out;
}

fn prependNibble(allocator: Allocator, nibble: u8, rest: []const u8) Allocator.Error![]u8 {
    const out = try allocator.alloc(u8, rest.len + 1);
    out[0] = nibble;
    @memcpy(out[1..], rest);
    return out;
}

fn singleNibble(allocator: Allocator, nibble: u8) Allocator.Error![]u8 {
    const out = try allocator.alloc(u8, 1);
    out[0] = nibble;
    return out;
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

    const found = (try proof(root_hash, &nodes).get(&key)).?;
    try std.testing.expectEqualSlices(u8, value, found);

    const missing_key = hashedStorageKey(1);
    try std.testing.expect(try proof(root_hash, &nodes).get(&missing_key) == null);
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

    const found = (try proof(root_hash, &nodes).get(&keys[14])).?;
    try std.testing.expectEqualSlices(u8, &values[14], found);

    const omitted_child = [_][]const u8{root_node};
    try std.testing.expectError(error.MissingNode, proof(root_hash, &omitted_child).get(&keys[14]));
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

    try std.testing.expect(try proof(root_hash, &nodes).get(&[_]u8{0x11}) == null);
}

test "MPT proof lookup rejects malformed compact paths" {
    const malformed = [_]u8{ 0xc2, 0x40, 0x80 };
    const root_hash = crypto.keccak256(&malformed);
    const nodes = [_][]const u8{&malformed};

    try std.testing.expectError(error.InvalidCompactPath, proof(root_hash, &nodes).get(""));
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

test "MPT storage root helper applies Changeset writes and zero deletes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const scratch = arena.allocator();

    const account = address.addr(0x1000);
    const other_account = address.addr(0x2000);
    const key0 = hashedStorageKey(0);
    const value0 = try storageValue(scratch, 42);
    const base_pairs = [_]Pair{.{ .key = &key0, .value = value0 }};
    const root_node = try encodedRootForTest(scratch, &base_pairs);
    const root_hash = crypto.keccak256(root_node);
    const nodes = [_][]const u8{root_node};

    var changeset = Changeset.init();
    defer changeset.deinit(scratch);
    try changeset.storage_writes.append(scratch, .{ .address = account, .key = 0, .value = 0 });
    try changeset.storage_writes.append(scratch, .{ .address = account, .key = 2, .value = 9 });
    try changeset.storage_writes.append(scratch, .{ .address = other_account, .key = 1, .value = 99 });
    changeset.sort();

    const actual = try storageRootAfterChangeset(scratch, root_hash, &nodes, &changeset, account);

    const key2 = hashedStorageKey(2);
    const value2 = try storageValue(scratch, 9);
    const expected_pairs = [_]Pair{.{ .key = &key2, .value = value2 }};
    const expected = try root(scratch, &expected_pairs);
    try std.testing.expectEqualSlices(u8, &expected, &actual);
}

test "MPT state root helper applies account and storage changes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const scratch = arena.allocator();

    const target = address.addr(0x1000);
    const key0 = hashedStorageKey(0);
    const value0 = try storageValue(scratch, 42);
    const storage_pairs = [_]Pair{.{ .key = &key0, .value = value0 }};
    const storage_root = try root(scratch, &storage_pairs);
    const storage_node = try encodedRootForTest(scratch, &storage_pairs);

    const account_key = hashedAddressKey(target);
    const account_value = try accountValueFrom(scratch, .{
        .nonce = 1,
        .balance = 10,
        .storage_root = storage_root,
        .code_hash = codeHash(&.{0x60}),
    });
    const state_pairs = [_]Pair{.{ .key = &account_key, .value = account_value }};
    const state_root_node = try encodedRootForTest(scratch, &state_pairs);
    const state_root = crypto.keccak256(state_root_node);
    const nodes = [_][]const u8{ state_root_node, storage_node };

    var changeset = Changeset.init();
    defer changeset.deinit(scratch);
    const new_code = try scratch.dupe(u8, &.{ 0x61, 0x62 });
    try changeset.account_updates.append(scratch, .{
        .address = target,
        .nonce = 2,
        .balance = 20,
        .code_hash = codeHash(new_code),
    });
    try changeset.code_inserts.append(scratch, .{
        .code_hash = codeHash(new_code),
        .code = new_code,
    });
    try changeset.storage_writes.append(scratch, .{ .address = target, .key = 0, .value = 0 });
    try changeset.storage_writes.append(scratch, .{ .address = target, .key = 1, .value = 7 });
    changeset.sort();

    const actual = try stateRootAfterChangeset(scratch, state_root, &nodes, &changeset);

    const key1 = hashedStorageKey(1);
    const value1 = try storageValue(scratch, 7);
    const expected_storage_pairs = [_]Pair{.{ .key = &key1, .value = value1 }};
    const expected_storage_root = try root(scratch, &expected_storage_pairs);
    const expected_account_value = try accountValueFrom(scratch, .{
        .nonce = 2,
        .balance = 20,
        .storage_root = expected_storage_root,
        .code_hash = codeHash(new_code),
    });
    const expected_state_pairs = [_]Pair{.{ .key = &account_key, .value = expected_account_value }};
    const expected = try root(scratch, &expected_state_pairs);
    try std.testing.expectEqualSlices(u8, &expected, &actual);
}

test "MPT state root helper applies storage-only changes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const scratch = arena.allocator();

    const target = address.addr(0x2000);
    const account_key = hashedAddressKey(target);
    const account_value = try accountValueFrom(scratch, .{
        .nonce = 5,
        .balance = 100,
        .code_hash = codeHash(&.{0x5f}),
    });
    const state_pairs = [_]Pair{.{ .key = &account_key, .value = account_value }};
    const state_root_node = try encodedRootForTest(scratch, &state_pairs);
    const state_root = crypto.keccak256(state_root_node);
    const nodes = [_][]const u8{state_root_node};

    var changeset = Changeset.init();
    defer changeset.deinit(scratch);
    try changeset.storage_writes.append(scratch, .{ .address = target, .key = 3, .value = 4 });

    const actual = try stateRootAfterChangeset(scratch, state_root, &nodes, &changeset);

    const storage_key = hashedStorageKey(3);
    const storage_value = try storageValue(scratch, 4);
    const expected_storage_pairs = [_]Pair{.{ .key = &storage_key, .value = storage_value }};
    const expected_account_value = try accountValueFrom(scratch, .{
        .nonce = 5,
        .balance = 100,
        .storage_root = try root(scratch, &expected_storage_pairs),
        .code_hash = codeHash(&.{0x5f}),
    });
    const expected_state_pairs = [_]Pair{.{ .key = &account_key, .value = expected_account_value }};
    const expected = try root(scratch, &expected_state_pairs);
    try std.testing.expectEqualSlices(u8, &expected, &actual);
}

test "MPT state root helper deletes accounts" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const scratch = arena.allocator();

    const target = address.addr(0x3000);
    const account_key = hashedAddressKey(target);
    const account_value = try accountValueFrom(scratch, .{
        .nonce = 1,
        .balance = 1,
        .code_hash = codeHash(&.{0x00}),
    });
    const state_pairs = [_]Pair{.{ .key = &account_key, .value = account_value }};
    const state_root_node = try encodedRootForTest(scratch, &state_pairs);
    const state_root = crypto.keccak256(state_root_node);
    const nodes = [_][]const u8{state_root_node};

    var changeset = Changeset.init();
    defer changeset.deinit(scratch);
    try changeset.account_deletes.append(scratch, target);

    const actual = try stateRootAfterChangeset(scratch, state_root, &nodes, &changeset);
    try std.testing.expectEqualSlices(u8, &empty_root_hash, &actual);
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
