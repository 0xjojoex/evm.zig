//! `StateReader` adapter over a Merkle Patricia Trie witness nodes.
const std = @import("std");
const RewindableRegion = @import("rewindable_region");

const address = @import("../address.zig");
const crypto = @import("../crypto.zig");
const trie = @import("../eth/trie.zig");
const rlp = @import("rlp");
const Account = @import("../state/Account.zig");
const ClaimPlan = @import("../eth/bal/ClaimPlan.zig").ClaimPlan;
pub const ParentFacts = @import("ParentFacts.zig");
const StateReader = @import("../state/Reader.zig");
const StatelessArtifacts = @import("./artifacts.zig");
const StatelessCommit = @import("./commit.zig");

const Address = address.Address;
const CatalogInitError = std.mem.Allocator.Error || error{ InvalidNode, ResourceLimitExceeded };

pub const Mode = enum { indexed, catalog };
pub const Indexed = Reader(.indexed);
pub const Catalog = Reader(.catalog);

pub fn Reader(comptime mode: Mode) type {
    return struct {
        const WitnessStateReader = @This();
        const CatalogState = if (mode == .catalog) trie.WitnessCatalog else void;
        const IndexedState = if (mode == .indexed) struct {
            nodes: *trie.IndexedNodes,
            proof_cache: trie.ProofCache,
        } else void;

        pub const Error = error{InvalidWitness};
        pub const RootError = std.mem.Allocator.Error || Error || error{ResourceLimitExceeded};
        pub const CodeEntry = StatelessArtifacts.ParentCode;

        allocator: std.mem.Allocator,
        state_root: [32]u8,
        indexed: IndexedState,
        catalog: CatalogState,
        codes: []CodeEntry = &.{},
        accounts: trie.AccountFacts,

        pub fn init(
            allocator: std.mem.Allocator,
            state_root: [32]u8,
            indexed: *trie.IndexedNodes,
            codes: []const []const u8,
        ) !WitnessStateReader {
            if (comptime mode == .indexed) {
                errdefer indexed.deinit();
                return .{
                    .allocator = allocator,
                    .state_root = state_root,
                    .indexed = .{
                        .nodes = indexed,
                        .proof_cache = .init(allocator),
                    },
                    .catalog = {},
                    .codes = try indexCodes(allocator, codes),
                    .accounts = trie.AccountFacts.init(allocator),
                };
            }

            errdefer indexed.deinit();
            var catalog = try buildCatalog(allocator, state_root, indexed);
            errdefer catalog.deinit();
            const indexed_codes = try indexCodes(allocator, codes);
            // Catalog nodes borrow witness bytes, not the construction index.
            indexed.deinit();
            return .{
                .allocator = allocator,
                .state_root = state_root,
                .indexed = {},
                .catalog = catalog,
                .codes = indexed_codes,
                .accounts = trie.AccountFacts.init(allocator),
            };
        }

        /// Index raw witness nodes and adopt the resulting index.
        ///
        /// `allocator` and the witness byte slices must outlive the returned reader.
        pub fn initFromNodes(
            allocator: std.mem.Allocator,
            state_root: [32]u8,
            nodes: []const []const u8,
            codes: []const []const u8,
        ) !WitnessStateReader {
            return init(allocator, state_root, try trie.indexNodes(allocator, nodes), codes);
        }

        fn buildCatalog(
            allocator: std.mem.Allocator,
            state_root: [32]u8,
            indexed: *const trie.IndexedNodes,
        ) CatalogInitError!trie.WitnessCatalog {
            return trie.buildWitnessCatalog(allocator, state_root, indexed) catch |err| switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                error.ResourceLimitExceeded => error.ResourceLimitExceeded,
                else => error.InvalidNode,
            };
        }

        pub fn deinit(self: *WitnessStateReader) void {
            if (comptime mode == .indexed) {
                self.indexed.proof_cache.deinit();
                self.accounts.deinit();
                self.allocator.free(self.codes);
                self.indexed.nodes.deinit();
                self.* = undefined;
                return;
            }

            self.accounts.deinit();
            self.allocator.free(self.codes);
            self.catalog.deinit();
            self.* = undefined;
        }

        pub fn reader(self: *WitnessStateReader) StateReader {
            return .{
                .ptr = self,
                .vtable = &vtable,
            };
        }

        pub fn parentCodes(self: *const WitnessStateReader) []const CodeEntry {
            return self.codes;
        }

        pub fn authenticateClaimPlan(
            self: *WitnessStateReader,
            allocator: std.mem.Allocator,
            plan: ClaimPlan,
        ) (std.mem.Allocator.Error || Error)!?ParentFacts {
            if (comptime mode == .indexed) return null;
            return ParentFacts.authenticate(allocator, plan, &self.catalog) catch |err| switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                else => error.InvalidWitness,
            };
        }

        /// Post-state root for generic tracked `changes` against the parent root.
        pub fn stateRootAfterChanges(
            self: *const WitnessStateReader,
            allocator: std.mem.Allocator,
            changes: anytype,
        ) RootError![32]u8 {
            var seal_region = RewindableRegion.init(allocator);
            defer seal_region.deinit();
            const scratch = seal_region.allocator();
            return narrowRoot(self.rootAfterChanges(scratch, changes));
        }

        /// Post-state root for a sealed dense commit view, which stays projected as
        /// ClaimPlan IDs instead of address/slot change records.
        pub fn stateRootAfterDenseCommit(
            self: *const WitnessStateReader,
            allocator: std.mem.Allocator,
            commit_view: anytype,
        ) RootError![32]u8 {
            comptime std.debug.assert(mode == .catalog);
            return narrowRoot(StatelessCommit.stateRootAfterCatalog(allocator, self.state_root, &self.catalog, commit_view));
        }

        fn rootAfterChanges(
            self: *const WitnessStateReader,
            scratch: std.mem.Allocator,
            changes: anytype,
        ) trie.UpdateError![32]u8 {
            if (comptime mode == .catalog) {
                return trie.stateRootAfterChangesCatalog(
                    scratch,
                    self.state_root,
                    &self.catalog,
                    &self.accounts,
                    changes,
                );
            }
            return trie.stateRootAfterChangesIndexed(
                scratch,
                self.state_root,
                self.indexed.nodes,
                &self.accounts,
                changes,
            );
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

        fn loadMptAccount(self: *WitnessStateReader, target: Address) !?trie.Account {
            if (self.accounts.get(target)) |account| return account;
            const account = try self.readMptAccount(target);
            try self.accounts.put(target, account);
            return account;
        }

        fn readMptAccount(self: *WitnessStateReader, target: Address) Error!?trie.Account {
            const key = trie.hashedAddressKey(target);
            if (comptime mode == .catalog) {
                return self.catalog.decodedAccount(&key) catch return error.InvalidWitness;
            }
            const lookup = trie.cachedProof(
                self.state_root,
                self.indexed.nodes,
                &self.indexed.proof_cache,
            );
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

        fn context(ptr: *anyopaque) *WitnessStateReader {
            return @ptrCast(@alignCast(ptr));
        }

        fn accountExists(ptr: *anyopaque, target: Address) !bool {
            return (try context(ptr).loadMptAccount(target)) != null;
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
            if (comptime mode == .catalog) {
                const encoded = self.catalog.storage(account.storage_root, &storage_key) catch return error.InvalidWitness;
                return decodeStorageValue(encoded orelse return 0) catch return error.InvalidWitness;
            }
            const lookup = trie.cachedProof(
                account.storage_root,
                self.indexed.nodes,
                &self.indexed.proof_cache,
            );
            const encoded = lookup.get(&storage_key) catch return error.InvalidWitness;
            return decodeStorageValue(encoded orelse return 0) catch return error.InvalidWitness;
        }

        fn decodeStorageValue(encoded: []const u8) rlp.ParseError!u256 {
            return trie.decodeStorageValue(encoded);
        }

        fn accountHasStorage(ptr: *anyopaque, target: Address) !bool {
            const account = try context(ptr).loadMptAccount(target) orelse return false;
            return !std.mem.eql(u8, &account.storage_root, &trie.empty_root_hash);
        }
    };
}

test "witness state reader derives root directly from tracked changes" {
    const TrackedState = @import("../state/TrackedState.zig");
    var state = TrackedState.init(std.testing.allocator);
    defer state.deinit();
    const attempt = state.beginTransaction();
    state.beginScope();
    try state.setBalance(address.addr(1), 1);
    _ = try state.setStorage(address.addr(1), 2, 3);
    state.closeScope();
    state.seal(attempt);
    state.retain(attempt);
    const changes = state.acceptedView().changes();

    var witness = try Indexed.initFromNodes(std.testing.allocator, trie.empty_root_hash, &.{}, &.{});
    defer witness.deinit();
    try std.testing.expect(!try witness.reader().accountExists(address.addr(1)));

    const actual = try witness.stateRootAfterChanges(std.testing.allocator, changes);
    const expected = try trie.stateRootAfterChanges(
        std.testing.allocator,
        trie.empty_root_hash,
        &.{},
        changes,
    );
    try std.testing.expectEqualSlices(u8, &expected, &actual);
}

test "witness state reader returns empty state for empty root" {
    var witness = try Indexed.initFromNodes(std.testing.allocator, trie.empty_root_hash, &.{}, &.{});
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

    var witness = try Indexed.initFromNodes(scratch, state_root, &nodes, &codes);
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

    var witness = try Indexed.initFromNodes(scratch, state_root, &nodes, &.{});
    defer witness.deinit();
    const state_reader = witness.reader();
    try std.testing.expect(try state_reader.accountHasStorage(target));
    try std.testing.expectEqual(@as(u256, 42), try state_reader.getStorage(target, 3));
    try std.testing.expectEqual(@as(u256, 0), try state_reader.getStorage(target, 4));

    // Indexed reads bind to `state_root`, so a corrupted root only stays
    // readable through the account cache populated before the corruption.
    witness.state_root = [_]u8{0xaa} ** 32;
    try std.testing.expectEqual(@as(u256, 42), try state_reader.getStorage(target, 3));
    try std.testing.expectError(error.InvalidWitness, witness.readMptAccount(target));

    // The catalog authenticates at build time and never reconsults `state_root`.
    var catalog = try Catalog.initFromNodes(scratch, state_root, &nodes, &.{});
    defer catalog.deinit();
    catalog.state_root = [_]u8{0xaa} ** 32;
    try std.testing.expectEqual(@as(u256, 42), try catalog.reader().getStorage(target, 3));
}

test "catalog witness reader releases its construction index" {
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
    const indexed = try trie.indexNodes(allocator, &nodes);
    const indexed_bytes = indexed.allocationBytes();
    const freed_before = counted.freed_bytes;
    var catalog = try Catalog.init(allocator, state_root, indexed, &.{});
    defer catalog.deinit();

    try std.testing.expect(counted.freed_bytes - freed_before >= indexed_bytes);
    try std.testing.expect(try catalog.reader().accountExists(target));
}

test "catalog witness reader cleans every allocation failure position" {
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
            var catalog = try Catalog.initFromNodes(
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

    var witness = try Indexed.initFromNodes(scratch, state_root, &nodes, &.{});
    defer witness.deinit();
    const state_reader = witness.reader();

    const loaded = (try state_reader.loadAccount(target)).?;
    try std.testing.expectError(error.InvalidWitness, state_reader.loadCode(loaded.code_hash));
    try std.testing.expectError(error.InvalidWitness, state_reader.getStorage(target, 1));

    const malformed_code = [_]u8{0x00};
    const malformed_codes = [_][]const u8{&malformed_code};
    var malformed_witness = try Indexed.initFromNodes(scratch, state_root, &nodes, &malformed_codes);
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
