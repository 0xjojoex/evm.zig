//! Ethereum trie codec, root, proof, catalog, and update integration tests.
//!
//! An independent constructor supports tests that need selected encoded nodes to assemble
//! partial witness bags. `mpt.root` returns only a
//! digest; its intermediate topology and encodings live in reusable operation
//! scratch and are not retained. Using its node encoder here would also make
//! proof/update tests depend on their implementation. Production construction
//! and mutation stay in `pkg/mpt`.

const std = @import("std");

const trie = @import("trie.zig");
const TrackedState = @import("../state/TrackedState.zig");
const MemoryAccount = @import("../state/MemoryAccount.zig");
const address = @import("../address.zig");
const crypto = @import("../crypto.zig");
const mpt = @import("mpt");
const rlp = @import("rlp");
const t = @import("../t.zig");
const Withdrawal = @import("Withdrawal.zig");

const Allocator = std.mem.Allocator;
const Error = Allocator.Error || mpt.Error;
const Pair = mpt.Entry;
const Account = trie.Account;
const AccountFacts = trie.AccountFacts;
const Update = trie.Update;
const empty_root_hash = trie.empty_root_hash;
const root = trie.root;
const hashedStorageKey = trie.hashedStorageKey;
const hashedAddressKey = trie.hashedAddressKey;
const storageValue = trie.storageValue;
const accountValueFrom = trie.accountValueFrom;
const indexWitness = trie.indexWitness;
const proof = trie.proof;
const buildWitnessCatalog = trie.buildWitnessCatalog;
const updateRoot = trie.updateRoot;
const stateRootAfterChanges = trie.stateRootAfterChanges;
const stateRootAfterChangesFromNodes = trie.stateRootAfterChangesFromNodes;

const max_rlp_account: Account = .{
    .nonce = std.math.maxInt(u64),
    .balance = std.math.maxInt(u256),
    .storage_root = [_]u8{0xff} ** 32,
    .code_hash = [_]u8{0xff} ** 32,
};

fn encodeNode(allocator: Allocator, pairs: []const Pair, depth: usize) Error![]const u8 {
    std.debug.assert(pairs.len > 0);

    if (pairs.len == 1) {
        const suffix: mpt.nibble.Path = .{
            .key = pairs[0].key,
            .start = depth,
            .len = mpt.nibble.keyNibbleLen(pairs[0].key) - depth,
        };
        return encodeLeaf(allocator, suffix, pairs[0].value);
    }

    const common = commonPrefixLen(pairs, depth);
    if (common > 0) {
        const prefix: mpt.nibble.Path = .{ .key = pairs[0].key, .start = depth, .len = common };
        const child = try encodeNode(allocator, pairs, depth + common);
        const child_ref = try nodeReference(allocator, child);
        return encodeExtension(allocator, prefix, child_ref);
    }

    return encodeBranch(allocator, pairs, depth);
}

fn sortedPairs(allocator: Allocator, pairs: []const Pair) Error![]Pair {
    const sorted = try allocator.dupe(Pair, pairs);
    std.mem.sort(Pair, sorted, {}, struct {
        fn lessThan(_: void, lhs: Pair, rhs: Pair) bool {
            return std.mem.lessThan(u8, lhs.key, rhs.key);
        }
    }.lessThan);
    try rejectDuplicateKeys(sorted);
    return sorted;
}

fn encodedRoot(allocator: Allocator, pairs: []const Pair) Error![]const u8 {
    const sorted = try sortedPairs(allocator, pairs);
    defer allocator.free(sorted);
    return encodeNode(allocator, sorted, 0);
}

fn encodeLeaf(allocator: Allocator, suffix: mpt.nibble.Path, value: []const u8) Error![]const u8 {
    var payload: std.ArrayList(u8) = .empty;
    defer payload.deinit(allocator);

    const compact = try compactPath(allocator, suffix, true);
    try appendBytesItem(allocator, &payload, compact);
    try appendBytesItem(allocator, &payload, value);
    return wrapList(allocator, payload.items);
}

fn encodeExtension(allocator: Allocator, prefix: mpt.nibble.Path, child_ref: []const u8) Error![]const u8 {
    var payload: std.ArrayList(u8) = .empty;
    defer payload.deinit(allocator);

    const compact = try compactPath(allocator, prefix, false);
    try appendBytesItem(allocator, &payload, compact);
    try payload.appendSlice(allocator, child_ref);
    return wrapList(allocator, payload.items);
}

fn encodeBranch(allocator: Allocator, pairs: []const Pair, depth: usize) Error![]const u8 {
    var payload: std.ArrayList(u8) = .empty;
    defer payload.deinit(allocator);

    var branch_value: ?[]const u8 = null;
    var index: usize = 0;
    while (index < pairs.len and mpt.nibble.keyNibbleLen(pairs[index].key) == depth) : (index += 1) {
        if (branch_value != null) return error.DuplicateKey;
        branch_value = pairs[index].value;
    }

    for (0..16) |child_nibble| {
        if (index < pairs.len and mpt.nibble.keyNibbleLen(pairs[index].key) > depth and mpt.nibble.keyNibbleAt(pairs[index].key, depth) == child_nibble) {
            const start = index;
            while (index < pairs.len and mpt.nibble.keyNibbleLen(pairs[index].key) > depth and mpt.nibble.keyNibbleAt(pairs[index].key, depth) == child_nibble) {
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
    return wrapList(allocator, payload.items);
}

fn nodeReference(allocator: Allocator, encoded_node: []const u8) Allocator.Error![]const u8 {
    if (encoded_node.len < 32) return encoded_node;
    const digest = crypto.keccak256(encoded_node);

    var out = rlp.Writer.alloc(allocator);
    errdefer out.deinit();
    try writerBytes(&out, &digest);
    return writerOwned(&out);
}

fn wrapList(allocator: Allocator, payload: []const u8) Allocator.Error![]const u8 {
    var out = rlp.Writer.alloc(allocator);
    errdefer out.deinit();
    try writerList(&out, payload);
    return writerOwned(&out);
}

fn appendBytesItem(allocator: Allocator, payload: *std.ArrayList(u8), value: []const u8) Allocator.Error!void {
    var item = rlp.Writer.alloc(allocator);
    defer item.deinit();
    try writerBytes(&item, value);
    try payload.appendSlice(allocator, item.written());
}

fn compactPath(allocator: Allocator, path: mpt.nibble.Path, terminal: bool) Allocator.Error![]const u8 {
    const out = try allocator.alloc(u8, mpt.nibble.compactLen(path.len));
    return mpt.nibble.encodeCompact(out, path, terminal) catch unreachable;
}

fn commonPrefixLen(pairs: []const Pair, depth: usize) usize {
    var prefix: mpt.nibble.Path = .{
        .key = pairs[0].key,
        .start = depth,
        .len = mpt.nibble.keyNibbleLen(pairs[0].key) - depth,
    };
    for (pairs[1..]) |pair| {
        const candidate: mpt.nibble.Path = .{
            .key = pair.key,
            .start = depth,
            .len = mpt.nibble.keyNibbleLen(pair.key) - depth,
        };
        prefix.len = prefix.commonPrefix(candidate);
        if (prefix.len == 0) break;
    }
    return prefix.len;
}

fn rejectDuplicateKeys(pairs: []const Pair) Error!void {
    for (pairs[1..], 1..) |pair, index| {
        if (std.mem.eql(u8, pairs[index - 1].key, pair.key)) return error.DuplicateKey;
    }
}

fn writerBytes(writer: *rlp.Writer, value: []const u8) Allocator.Error!void {
    writer.bytes(value) catch |err| switch (err) {
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

test "decodeAccountValue matches the fixed account schema" {
    var prng = std.Random.DefaultPrng.init(0xacc7);
    const random = prng.random();
    const scalars = [_]u256{ 0, 1, 0x7f, 0x80, 0xff, 0x100, std.math.maxInt(u64), 1 << 255, std.math.maxInt(u256) };
    for (0..256) |_| {
        var account = Account{
            .nonce = @truncate(scalars[random.uintLessThan(usize, scalars.len)]),
            .balance = scalars[random.uintLessThan(usize, scalars.len)],
        };
        random.bytes(&account.storage_root);
        random.bytes(&account.code_hash);
        const encoded = try accountValueFrom(std.testing.allocator, account);
        defer std.testing.allocator.free(encoded);
        try std.testing.expectEqual(account, try trie.decodeAccountValue(encoded));

        var decoded: Account = undefined;
        try trie.decodeAccountValueInto(encoded, &decoded);
        try std.testing.expectEqual(account, decoded);
        try std.testing.expectError(
            error.InputTooShort,
            trie.decodeAccountValue(encoded[0 .. encoded.len - 1]),
        );
        try std.testing.expectError(
            error.InputTooShort,
            trie.decodeAccountValueInto(encoded[0 .. encoded.len - 1], &decoded),
        );
    }
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
    try t.expectHex(&(try trie.orderedTrieRoot(std.testing.allocator, &values)), "a2d85fc2849d6aec6107215f0e83954d4f25913d445387fc2c0ece0665219186");
    try t.expectHex(&(try trie.transactionRoot(std.testing.allocator, &values)), "a2d85fc2849d6aec6107215f0e83954d4f25913d445387fc2c0ece0665219186");
    try t.expectHex(&(try trie.receiptRoot(std.testing.allocator, &values)), "a2d85fc2849d6aec6107215f0e83954d4f25913d445387fc2c0ece0665219186");
    try t.expectHex(&(try trie.orderedTrieRoot(std.testing.allocator, &.{})), "56e81f171bcc55a6ff8345e692c0f86e5b48e01b996cadc001622fb5e363b421");
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
    try std.testing.expectEqualDeep(input, try trie.decodeAccountValue(encoded));
}

test "bounded trie value buffers match allocating encoders" {
    const storage_values = [_]u256{ 1, 0x7f, 0x80, std.math.maxInt(u256) };
    for (storage_values) |value| {
        const allocated = try storageValue(std.testing.allocator, value);
        defer std.testing.allocator.free(allocated);
        var buffer: trie.StorageValueBuffer = undefined;
        try std.testing.expectEqualSlices(u8, allocated, trie.storageValueInto(&buffer, value));
    }

    const accounts = [_]Account{
        .{},
        .{ .nonce = 1, .balance = 0x80 },
        max_rlp_account,
    };
    for (accounts) |account| {
        const allocated = try accountValueFrom(std.testing.allocator, account);
        defer std.testing.allocator.free(allocated);
        var buffer: trie.AccountValueBuffer = undefined;
        try std.testing.expectEqualSlices(u8, allocated, trie.accountValueInto(&buffer, account));
    }
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
    const value = try trie.withdrawalValue(counted.allocator(), withdrawals[0]);
    defer counted.allocator().free(value);

    try std.testing.expectEqual(before + 1, counted.alloc_index);
    try std.testing.expectEqualSlices(u8, direct, value);
    try t.expectHex(value, "d8010294000000000000000000000000000000000000100003");
    try t.expectHex(&(try trie.withdrawalsRoot(std.testing.allocator, &withdrawals)), "ba94e67f1ff34df6be897a534b805005dc84403f69a89614daa2283fa8b1862f");
    try t.expectHex(&(try trie.withdrawalsRoot(std.testing.allocator, &.{})), "56e81f171bcc55a6ff8345e692c0f86e5b48e01b996cadc001622fb5e363b421");
}

test "ordered trie exact workspaces reclaim fixed backing" {
    const values = [_][]const u8{ "cat", "dog" };
    const withdrawals = [_]Withdrawal{.{
        .index = 1,
        .validator_index = 2,
        .address = address.addr(0x1000),
        .amount = 3,
    }};
    var backing: [64 * 1024]u8 align(16) = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&backing);

    _ = try trie.orderedTrieRoot(fixed.allocator(), &values);
    try std.testing.expectEqual(@as(usize, 0), fixed.end_index);
    _ = try trie.withdrawalsRoot(fixed.allocator(), &withdrawals);
    try std.testing.expectEqual(@as(usize, 0), fixed.end_index);
}

test "MPT root rejects duplicate keys" {
    const pairs = [_]Pair{
        .{ .key = "dog", .value = "puppy" },
        .{ .key = "dog", .value = "hound" },
    };
    try std.testing.expectError(error.DuplicateKey, root(std.testing.allocator, &pairs));
}

test "MPT proof lookup rejects malformed compact paths" {
    const malformed = [_]u8{ 0xc2, 0x40, 0x80 };
    const root_hash = crypto.keccak256(&malformed);
    const nodes = [_][]const u8{&malformed};
    var witness = try indexWitness(std.testing.allocator, &nodes);
    defer witness.deinit();

    try std.testing.expectError(error.InvalidCompactPath, proof(root_hash, witness).get(""));
}

test "MPT update root inserts into empty trie" {
    const allocator = std.testing.allocator;
    const update = [_]Update{.{ .key = "dog", .value = "puppy" }};

    const actual = try updateRoot(allocator, empty_root_hash, &.{}, &update);
    const expected_pairs = [_]Pair{.{ .key = "dog", .value = "puppy" }};
    const expected = try root(allocator, &expected_pairs);
    try std.testing.expectEqualSlices(u8, &expected, &actual);
}

test "authenticated account facts preserve cached absence" {
    var facts = AccountFacts.init(std.testing.allocator);
    defer facts.deinit();

    try facts.put(address.addr(1), null);
    const cached = facts.get(address.addr(1));
    try std.testing.expect(cached != null);
    try std.testing.expect(cached.? == null);
    try std.testing.expect(facts.get(address.addr(2)) == null);
}

test "MPT proof lookup resolves a root leaf" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const scratch = arena.allocator();

    const key = hashedStorageKey(0);
    const value = try storageValue(scratch, 42);
    const pairs = [_]Pair{.{ .key = &key, .value = value }};
    const root_node = try encodedRoot(scratch, &pairs);
    const root_hash = crypto.keccak256(root_node);
    const nodes = [_][]const u8{root_node};
    const indexed = try indexWitness(scratch, &nodes);

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

    const sorted = try sortedPairs(scratch, &pairs);
    const root_node = try encodeNode(scratch, sorted, 0);
    const child_node = try encodeNode(scratch, sorted, 1);
    try std.testing.expect(child_node.len >= 32);

    const root_hash = crypto.keccak256(root_node);
    const nodes = [_][]const u8{ root_node, child_node };
    const indexed = try indexWitness(scratch, &nodes);

    const found = (try proof(root_hash, indexed).get(&keys[14])).?;
    try std.testing.expectEqualSlices(u8, &values[14], found);

    const omitted_child = [_][]const u8{root_node};
    const omitted_indexed = try indexWitness(scratch, &omitted_child);
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
    const root_node = try encodedRoot(scratch, &pairs);
    const root_hash = crypto.keccak256(root_node);
    const nodes = [_][]const u8{root_node};
    const indexed = try indexWitness(scratch, &nodes);

    try std.testing.expect(try proof(root_hash, indexed).get(&[_]u8{0x11}) == null);
}

test "witness catalog links state and witness-present storage roots" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const scratch = arena.allocator();

    const slot_key = hashedStorageKey(3);
    const slot_value = try storageValue(scratch, 42);
    const storage_pairs = [_]Pair{.{ .key = &slot_key, .value = slot_value }};
    const storage_node = try encodedRoot(scratch, &storage_pairs);
    const storage_root = crypto.keccak256(storage_node);

    const target = address.addr(0x2000);
    const account_key = hashedAddressKey(target);
    const account_value = try accountValueFrom(scratch, .{ .storage_root = storage_root });
    const state_pairs = [_]Pair{.{ .key = &account_key, .value = account_value }};
    const state_node = try encodedRoot(scratch, &state_pairs);
    const state_root = crypto.keccak256(state_node);

    const nodes = [_][]const u8{ state_node, storage_node };
    var indexed = try indexWitness(scratch, &nodes);
    defer indexed.deinit();
    var catalog = try buildWitnessCatalog(scratch, state_root, indexed);
    defer catalog.deinit();

    try std.testing.expect((try catalog.account(&account_key)) != null);
    const account = (try catalog.decodedAccount(&account_key)).?;
    try std.testing.expectEqualSlices(u8, &storage_root, &account.storage_root);
    try std.testing.expectEqualSlices(u8, slot_value, (try catalog.storage(storage_root, &slot_key)).?);
    const absent_key = hashedStorageKey(4);
    try std.testing.expect(try catalog.storage(storage_root, &absent_key) == null);
    try std.testing.expectEqual(@as(usize, 2), catalog.nodeCount());

    const state_only_nodes = [_][]const u8{state_node};
    var state_only_indexed = try indexWitness(scratch, &state_only_nodes);
    defer state_only_indexed.deinit();
    var state_only = try buildWitnessCatalog(scratch, state_root, state_only_indexed);
    defer state_only.deinit();
    try std.testing.expect((try state_only.account(&account_key)) != null);
    try std.testing.expectError(error.MissingNode, state_only.storage(storage_root, &slot_key));
}

test "witness catalog sorts and deduplicates shared storage roots" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const scratch = arena.allocator();

    const first_slot = hashedStorageKey(1);
    const first_value = try storageValue(scratch, 11);
    const first_storage_node = try encodedRoot(
        scratch,
        &.{.{ .key = &first_slot, .value = first_value }},
    );
    const first_storage_root = crypto.keccak256(first_storage_node);

    const second_slot = hashedStorageKey(2);
    const second_value = try storageValue(scratch, 22);
    const second_storage_node = try encodedRoot(
        scratch,
        &.{.{ .key = &second_slot, .value = second_value }},
    );
    const second_storage_root = crypto.keccak256(second_storage_node);

    const state_pairs = [_]Pair{
        .{ .key = &[_]u8{0x10}, .value = try accountValueFrom(scratch, .{ .storage_root = second_storage_root }) },
        .{ .key = &[_]u8{0x20}, .value = try accountValueFrom(scratch, .{ .storage_root = first_storage_root }) },
        .{ .key = &[_]u8{0x31}, .value = try accountValueFrom(scratch, .{ .storage_root = second_storage_root }) },
    };
    const sorted = try sortedPairs(scratch, &state_pairs);
    const state_node = try encodeNode(scratch, sorted, 0);
    const first_account_node = try encodeNode(scratch, sorted[0..1], 1);
    const second_account_node = try encodeNode(scratch, sorted[1..2], 1);
    const third_account_node = try encodeNode(scratch, sorted[2..3], 1);
    const state_root = crypto.keccak256(state_node);

    const nodes = [_][]const u8{
        state_node,
        first_account_node,
        second_account_node,
        third_account_node,
        first_storage_node,
        second_storage_node,
    };
    var witness = try indexWitness(scratch, &nodes);
    defer witness.deinit();
    var catalog = try buildWitnessCatalog(scratch, state_root, witness);
    defer catalog.deinit();

    try std.testing.expectEqual(@as(usize, 3), catalog.accounts.items.len);
    try std.testing.expectEqual(@as(usize, 2), catalog.storage_roots.items.len);
    _ = try catalog.storageCatalogRoot(first_storage_root);
    _ = try catalog.storageCatalogRoot(second_storage_root);
}

test "witness catalog cleans every allocation failure position" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const scratch = arena.allocator();

    const slot_key = hashedStorageKey(3);
    const slot_value = try storageValue(scratch, 42);
    const storage_node = try encodedRoot(
        scratch,
        &.{.{ .key = &slot_key, .value = slot_value }},
    );
    const storage_root = crypto.keccak256(storage_node);
    const account_key = hashedAddressKey(address.addr(0x2000));
    const account_value = try accountValueFrom(scratch, .{ .storage_root = storage_root });
    const state_node = try encodedRoot(
        scratch,
        &.{.{ .key = &account_key, .value = account_value }},
    );
    const state_root = crypto.keccak256(state_node);
    const nodes = [_][]const u8{ state_node, storage_node };

    const Harness = struct {
        fn run(
            allocator: Allocator,
            root_hash: [32]u8,
            encoded_nodes: []const []const u8,
        ) !void {
            var indexed = try indexWitness(allocator, encoded_nodes);
            defer indexed.deinit();
            var catalog = try buildWitnessCatalog(allocator, root_hash, indexed);
            defer catalog.deinit();
            try std.testing.expectEqual(@as(usize, 1), catalog.accounts.items.len);
            try std.testing.expectEqual(@as(usize, 1), catalog.storage_roots.items.len);
        }
    };
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        Harness.run,
        .{ state_root, &nodes },
    );
}

test "MPT update root replaces and deletes a root leaf" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const scratch = arena.allocator();

    const base_pairs = [_]Pair{.{ .key = "dog", .value = "puppy" }};
    const root_node = try encodedRoot(scratch, &base_pairs);
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

    const sorted = try sortedPairs(scratch, &pairs);
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

    const sorted = try sortedPairs(scratch, &pairs);
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
    const root_node = try encodedRoot(scratch, &base_pairs);
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
    const sorted = try sortedPairs(scratch, &base_pairs);
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

test "MPT batch inserts before deletes to avoid unnecessary sibling witness" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const scratch = arena.allocator();

    const deleted_key = [_]u8{0x10};
    const inserted_key = [_]u8{0x11};
    const preserved_key = [_]u8{0x20};
    var large_value = [_]u8{0xab} ** 40;
    const base_pairs = [_]Pair{
        .{ .key = &deleted_key, .value = &[_]u8{0x01} },
        .{ .key = &preserved_key, .value = &large_value },
    };
    const sorted = try sortedPairs(scratch, &base_pairs);
    const root_node = try encodeNode(scratch, sorted, 0);
    const hidden_sibling = try encodeNode(scratch, sorted[1..2], 1);
    try std.testing.expect(hidden_sibling.len >= 32);

    const root_hash = crypto.keccak256(root_node);
    const updates = [_]Update{
        .{ .key = &deleted_key, .value = null },
        .{ .key = &inserted_key, .value = &[_]u8{0x03} },
    };
    const root_only_nodes = [_][]const u8{root_node};
    const actual = try updateRoot(scratch, root_hash, &root_only_nodes, &updates);
    const expected_pairs = [_]Pair{
        .{ .key = &inserted_key, .value = &[_]u8{0x03} },
        .{ .key = &preserved_key, .value = &large_value },
    };
    const expected = try root(scratch, &expected_pairs);
    try std.testing.expectEqualSlices(u8, &expected, &actual);
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

    const direct = try stateRootAfterChangesFromNodes(scratch, empty_root_hash, &.{}, changes);
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

    const wiped_direct = try stateRootAfterChangesFromNodes(
        scratch,
        empty_root_hash,
        &.{},
        wiped_changes,
    );
    try std.testing.expectEqualSlices(u8, &empty_root_hash, &wiped_direct);
}

test "MPT state root groups interleaved tracked storage writes by address" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const scratch = arena.allocator();

    const first = address.addr(1);
    const second = address.addr(2);
    var state = TrackedState.init(scratch);
    defer state.deinit();
    const attempt = state.beginTransaction();
    state.beginScope();
    try state.setBalance(first, 10);
    _ = try state.setStorage(first, 1, 11);
    try state.setBalance(second, 20);
    _ = try state.setStorage(second, 2, 22);
    _ = try state.setStorage(first, 3, 33);
    state.closeScope();
    state.seal(attempt);
    state.retain(attempt);
    const changes = state.acceptedView().changes();
    try std.testing.expectEqual(first, changes.storage_writes.at(0).address);
    try std.testing.expectEqual(second, changes.storage_writes.at(1).address);
    try std.testing.expectEqual(first, changes.storage_writes.at(2).address);

    const actual = try stateRootAfterChangesFromNodes(scratch, empty_root_hash, &.{}, changes);

    const first_storage_keys = [_][32]u8{ hashedStorageKey(1), hashedStorageKey(3) };
    const first_storage_values = [_][]const u8{
        try storageValue(scratch, 11),
        try storageValue(scratch, 33),
    };
    const first_storage_root = try root(scratch, &.{
        .{ .key = &first_storage_keys[0], .value = first_storage_values[0] },
        .{ .key = &first_storage_keys[1], .value = first_storage_values[1] },
    });
    const second_storage_key = hashedStorageKey(2);
    const second_storage_value = try storageValue(scratch, 22);
    const second_storage_root = try root(scratch, &.{.{
        .key = &second_storage_key,
        .value = second_storage_value,
    }});

    const account_keys = [_][32]u8{ hashedAddressKey(first), hashedAddressKey(second) };
    const account_values = [_][]const u8{
        try accountValueFrom(scratch, .{ .balance = 10, .storage_root = first_storage_root }),
        try accountValueFrom(scratch, .{ .balance = 20, .storage_root = second_storage_root }),
    };
    const expected = try root(scratch, &.{
        .{ .key = &account_keys[0], .value = account_values[0] },
        .{ .key = &account_keys[1], .value = account_values[1] },
    });
    try std.testing.expectEqualSlices(u8, &expected, &actual);
}

test "MPT state roots agree with cached and witness-loaded accounts" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const scratch = arena.allocator();

    const target = address.addr(0x1000);
    const previous = Account{ .nonce = 3, .balance = 10 };
    const account_key = hashedAddressKey(target);
    const account_value = try accountValueFrom(scratch, previous);
    const root_node = try encodedRoot(
        scratch,
        &.{.{ .key = &account_key, .value = account_value }},
    );
    const root_hash = crypto.keccak256(root_node);
    const nodes = [_][]const u8{root_node};
    var indexed = try indexWitness(scratch, &nodes);
    defer indexed.deinit();

    var state = TrackedState.init(scratch);
    defer state.deinit();
    var seeded = MemoryAccount.init(scratch);
    seeded.account.nonce = previous.nonce;
    seeded.account.balance = previous.balance;
    try state.seedAccount(target, seeded);
    const attempt = state.beginTransaction();
    state.beginScope();
    _ = try state.setStorage(target, 1, 7);
    state.closeScope();
    state.seal(attempt);
    state.retain(attempt);
    const changes = state.acceptedView().changes();

    var facts = AccountFacts.init(scratch);
    defer facts.deinit();
    try facts.put(target, previous);
    const cached = try stateRootAfterChanges(
        scratch,
        trie.witnessSource(indexed, root_hash, &facts),
        changes,
    );
    const fallback = try stateRootAfterChanges(
        scratch,
        trie.witnessSource(indexed, root_hash, null),
        changes,
    );
    var catalog = try buildWitnessCatalog(scratch, root_hash, indexed);
    defer catalog.deinit();
    const catalog_root = try stateRootAfterChanges(
        scratch,
        try trie.catalogSource(&catalog, root_hash, &facts),
        changes,
    );
    try std.testing.expectEqualSlices(u8, &fallback, &cached);
    try std.testing.expectEqualSlices(u8, &fallback, &catalog_root);
}
