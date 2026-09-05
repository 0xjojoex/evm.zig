//! `StateReader` adapter over Merkle Patricia Trie witness nodes, authenticated
//! into a catalog at construction. Both execution-state lanes read through it
//! and commit through `eth.commit` against the same catalog.
const std = @import("std");

const address = @import("../address.zig");
const crypto = @import("../crypto.zig");
const trie = @import("../eth/trie.zig");
const commit = @import("../eth/commit.zig");
const rlp = @import("rlp");
const Account = @import("../state/Account.zig");
const ClaimPlan = @import("../eth/bal/ClaimPlan.zig").ClaimPlan;
pub const ParentFacts = @import("../eth/bal/ParentFacts.zig");
const StateReader = @import("../state/Reader.zig");
const claim_artifacts = @import("../eth/bal/claim_artifacts.zig");

const Address = address.Address;
const CatalogInitError = std.mem.Allocator.Error || error{ InvalidNode, ResourceLimitExceeded };

const WitnessReader = @This();

pub const Error = error{InvalidWitness};
pub const RootError = std.mem.Allocator.Error || Error || error{ResourceLimitExceeded};
pub const CodeEntry = claim_artifacts.ParentCode;

allocator: std.mem.Allocator,
state_root: [32]u8,
catalog: trie.WitnessCatalog,
codes: []CodeEntry = &.{},
/// Accounts already decoded from the catalog, keyed by address; `null` is a
/// proven absence.
accounts: trie.AccountFacts,

/// Authenticate `state_root` over `witness` and adopt the resulting catalog.
/// The index is released here: catalog nodes borrow the encoded witness
/// bytes, not index storage. `allocator` and the byte slices must outlive the
/// reader.
pub fn init(
    allocator: std.mem.Allocator,
    state_root: [32]u8,
    witness: *trie.WitnessIndex,
    codes: []const []const u8,
) !WitnessReader {
    errdefer witness.deinit();
    var catalog = try buildCatalog(allocator, state_root, witness);
    errdefer catalog.deinit();
    const indexed_codes = try indexCodes(allocator, codes);
    witness.deinit();
    return .{
        .allocator = allocator,
        .state_root = state_root,
        .catalog = catalog,
        .codes = indexed_codes,
        .accounts = trie.AccountFacts.init(allocator),
    };
}

/// Index raw witness nodes and adopt the resulting catalog.
pub fn initFromNodes(
    allocator: std.mem.Allocator,
    state_root: [32]u8,
    nodes: []const []const u8,
    codes: []const []const u8,
) !WitnessReader {
    return init(allocator, state_root, try trie.indexWitness(allocator, nodes), codes);
}

fn buildCatalog(
    allocator: std.mem.Allocator,
    state_root: [32]u8,
    witness: *const trie.WitnessIndex,
) CatalogInitError!trie.WitnessCatalog {
    return trie.buildWitnessCatalog(allocator, state_root, witness) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.ResourceLimitExceeded => error.ResourceLimitExceeded,
        else => error.InvalidNode,
    };
}

pub fn deinit(self: *WitnessReader) void {
    self.accounts.deinit();
    self.allocator.free(self.codes);
    self.catalog.deinit();
    self.* = undefined;
}

pub fn reader(self: *WitnessReader) StateReader {
    return .{
        .ptr = self,
        .vtable = &vtable,
    };
}

pub fn parentCodes(self: *const WitnessReader) []const CodeEntry {
    return self.codes;
}

/// Batch-authenticate a validated BAL plan against the catalog.
pub fn authenticateClaimPlan(
    self: *WitnessReader,
    allocator: std.mem.Allocator,
    plan: ClaimPlan,
) (std.mem.Allocator.Error || Error)!ParentFacts {
    return ParentFacts.authenticate(allocator, plan, &self.catalog) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.InvalidWitness,
    };
}

/// Post-state root for a sealed commit view (`state.checkCommitView`) against
/// the parent root this reader authenticated.
pub fn stateRootAfterCommit(
    self: *const WitnessReader,
    allocator: std.mem.Allocator,
    commit_view: anytype,
    node_updates: ?*trie.NodeUpdates,
) RootError![32]u8 {
    return narrowRoot(if (node_updates) |updates|
        commit.stateRootAfterCommitWithNodeUpdates(
            allocator,
            self.state_root,
            &self.catalog,
            commit_view,
            updates,
        )
    else
        commit.stateRootAfterCommit(
            allocator,
            self.state_root,
            &self.catalog,
            commit_view,
        ));
}

/// Every trie or RLP failure over a sealed witness means the witness itself
/// could not back the claimed state. Only exhaustion stays distinguishable.
fn narrowRoot(result: trie.UpdateError![32]u8) RootError![32]u8 {
    return result catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.ResourceLimitExceeded => error.ResourceLimitExceeded,
        else => error.InvalidWitness,
    };
}

fn loadMptAccount(self: *WitnessReader, target: Address) !?trie.Account {
    if (self.accounts.get(target)) |account| return account;
    const account = try self.readMptAccount(target);
    try self.accounts.put(target, account);
    return account;
}

fn readMptAccount(self: *WitnessReader, target: Address) Error!?trie.Account {
    const key = trie.hashedAddressKey(target);
    return self.catalog.decodedAccount(&key) catch return error.InvalidWitness;
}

fn codeForHash(self: *const WitnessReader, hash: [32]u8) Error![]const u8 {
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
    .loadAccount = loadAccount,
    .loadCode = loadCode,
    .loadCodeValidatesHash = true,
    .getStorage = getStorage,
};

fn context(ptr: *anyopaque) *WitnessReader {
    return @ptrCast(@alignCast(ptr));
}

fn loadAccount(ptr: *anyopaque, target: Address) !?Account {
    const account = try context(ptr).loadMptAccount(target) orelse return null;
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
    if (std.mem.eql(u8, &account.storage_root, &trie.empty_root_hash)) return 0;
    const storage_key = trie.hashedStorageKey(key);
    const encoded = self.catalog.storage(account.storage_root, &storage_key) catch return error.InvalidWitness;
    return trie.decodeStorageValue(encoded orelse return 0) catch return error.InvalidWitness;
}

test "witness reader derives the root of tracked changes through a sorted commit" {
    const OpenState = @import("../state.zig").OpenState;
    var state = OpenState.init(std.testing.allocator, .init(std.testing.allocator, null));
    defer state.deinit();
    defer if (state.transaction_active) {
        if (state.scopeActive()) state.closeScope();
        state.discard(state.active_attempt_id.?);
    };
    const attempt = state.beginTransaction();
    state.beginScope();
    try state.setBalance(.fromAddress(address.addr(1)), 1);
    _ = try state.setStorage(.fromAddress(address.addr(1)), 2, 3);
    state.closeScope();
    state.seal(attempt);
    state.retain(attempt);

    var witness = try initFromNodes(std.testing.allocator, trie.empty_root_hash, &.{}, &.{});
    defer witness.deinit();
    try std.testing.expect(try witness.reader().loadAccount(address.addr(1)) == null);

    var sorted = try commit.SortedChanges.init(std.testing.allocator, state.acceptedView().changes());
    defer sorted.deinit();
    const actual = try witness.stateRootAfterCommit(std.testing.allocator, sorted, null);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    const storage_key = trie.hashedStorageKey(2);
    const storage_root = try trie.root(scratch, &.{.{
        .key = &storage_key,
        .value = try trie.storageValue(scratch, 3),
    }});
    const account_key = trie.hashedAddressKey(address.addr(1));
    const expected = try trie.root(scratch, &.{.{
        .key = &account_key,
        .value = try trie.accountValueFrom(scratch, .{ .balance = 1, .storage_root = storage_root }),
    }});
    try std.testing.expectEqualSlices(u8, &expected, &actual);
}

test "witness reader returns empty state for empty root" {
    var witness = try initFromNodes(std.testing.allocator, trie.empty_root_hash, &.{}, &.{});
    defer witness.deinit();
    const state_reader = witness.reader();
    const target = address.addr(0x1000);

    try std.testing.expect(try state_reader.loadAccount(target) == null);
    try std.testing.expectEqual(@as(u256, 0), try state_reader.getStorage(target, 1));
}

test "witness reader loads account and code" {
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

    var witness = try initFromNodes(scratch, state_root, &nodes, &codes);
    defer witness.deinit();
    const state_reader = witness.reader();

    const loaded = (try state_reader.loadAccount(target)).?;
    try std.testing.expectEqual(@as(u64, 7), loaded.nonce);
    try std.testing.expectEqual(@as(u256, 99), loaded.balance);
    try std.testing.expectEqualSlices(u8, &code, try state_reader.loadCode(loaded.code_hash));
}

test "witness reader reads storage through account storage root" {
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

    var witness = try initFromNodes(scratch, state_root, &nodes, &.{});
    defer witness.deinit();
    const state_reader = witness.reader();
    try std.testing.expectEqual(@as(u256, 42), try state_reader.getStorage(target, 3));
    try std.testing.expectEqual(@as(u256, 0), try state_reader.getStorage(target, 4));

    // The catalog authenticates at build time and never reconsults `state_root`.
    witness.state_root = [_]u8{0xaa} ** 32;
    try std.testing.expectEqual(@as(u256, 42), try state_reader.getStorage(target, 3));
}

test "witness reader rejects a root the witness does not contain" {
    const missing_root = [_]u8{0xab} ** 32;
    try std.testing.expectError(
        error.InvalidNode,
        initFromNodes(std.testing.allocator, missing_root, &.{}, &.{}),
    );
}

test "witness reader releases its construction index" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const scratch = arena.allocator();

    const target = address.addr(0x2000);
    const account_key = trie.hashedAddressKey(target);
    const account_value = try trie.accountValueFrom(scratch, .{ .balance = 42 });
    const state_node = try testLeafNode(scratch, &account_key, account_value);
    const state_root = crypto.keccak256(state_node);
    const nodes = [_][]const u8{state_node};

    var counted = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const allocator = counted.allocator();
    const witness = try trie.indexWitness(allocator, &nodes);
    const indexed_bytes = witness.allocationBytes();
    const freed_before = counted.freed_bytes;
    var catalog = try init(allocator, state_root, witness, &.{});
    defer catalog.deinit();

    try std.testing.expect(counted.freed_bytes - freed_before >= indexed_bytes);
    try std.testing.expect((try catalog.reader().loadAccount(target)) != null);
}

test "witness reader cleans every allocation failure position" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const scratch = arena.allocator();

    const target = address.addr(0x2000);
    const account_key = trie.hashedAddressKey(target);
    const account_value = try trie.accountValueFrom(scratch, .{ .balance = 42 });
    const state_node = try testLeafNode(scratch, &account_key, account_value);
    const state_root = crypto.keccak256(state_node);
    const nodes = [_][]const u8{state_node};
    const code = [_]u8{0x5f};
    const codes = [_][]const u8{&code};

    const Harness = struct {
        fn run(
            allocator: std.mem.Allocator,
            root: [32]u8,
            encoded_nodes: []const []const u8,
            code_bytes: []const []const u8,
        ) !void {
            var catalog = try initFromNodes(
                allocator,
                root,
                encoded_nodes,
                code_bytes,
            );
            catalog.deinit();
        }
    };
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        Harness.run,
        .{ state_root, &nodes, &codes },
    );
}

test "witness reader rejects missing witness nodes and code" {
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

    var witness = try initFromNodes(scratch, state_root, &nodes, &.{});
    defer witness.deinit();
    const state_reader = witness.reader();

    const loaded = (try state_reader.loadAccount(target)).?;
    try std.testing.expectError(error.InvalidWitness, state_reader.loadCode(loaded.code_hash));
    try std.testing.expectError(error.InvalidWitness, state_reader.getStorage(target, 1));

    const malformed_code = [_]u8{0x00};
    const malformed_codes = [_][]const u8{&malformed_code};
    var malformed_witness = try initFromNodes(scratch, state_root, &nodes, &malformed_codes);
    defer malformed_witness.deinit();
    try std.testing.expectError(
        error.InvalidWitness,
        malformed_witness.reader().loadCode(loaded.code_hash),
    );
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
