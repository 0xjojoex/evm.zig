//! BAL adapter over one sealed tracked-state observation view.
//!
//! The tracked rows are the checkpoint-resolved source. This module owns BAL
//! grouping, sorting, allocation, and detached ownership.

const std = @import("std");
const address = @import("../../address.zig");
const State = @import("../../state/TrackedState.zig");
const Account = @import("../../state/Account.zig");
const MemoryAccount = @import("../../state/MemoryAccount.zig");
const StateReader = @import("../../state/Reader.zig");
const bal = @import("model.zig");
const observation = @import("observation.zig");
const shard_fold = @import("shard_fold.zig");
const ShardFold = shard_fold.ShardFold;

const Address = address.Address;
const Allocator = std.mem.Allocator;
const linear_index_limit = 8;

/// Detach one sealed observation view as an owned, sorted transition.
///
/// This shares `ObservationFold` with the block builder so the fact-to-
/// observation mapping - notably the rule that a storage wipe suppresses the
/// implied nonce and code finalization writes - exists exactly once.
pub fn materialize(
    view: anytype,
    allocator: Allocator,
) !observation.LaneTransition {
    var fold = ObservationFold.init(allocator);
    defer fold.deinit();
    try fold.appendView(view);

    std.mem.sort(FoldAccount, fold.accounts.items, {}, foldAccountLessThan);
    var accounts: std.ArrayList(observation.AccountObservation) = .empty;
    errdefer {
        for (accounts.items) |account| deinitAccountObservation(allocator, account);
        accounts.deinit(allocator);
    }
    try accounts.ensureTotalCapacity(allocator, fold.accounts.items.len);
    for (fold.accounts.items) |*account| {
        accounts.appendAssumeCapacity(try account.toOwnedObservation(allocator));
    }
    return .{ .accounts = try accounts.toOwnedSlice(allocator) };
}

/// Sequential block-level BAL builder over sealed transaction observations.
/// Multiple pending transitions at one index are coalesced before the indexed
/// shard is emitted.
pub const BlockBuilder = struct {
    allocator: Allocator,
    shards: ShardFold,
    active_index: ?bal.BlockAccessIndex = null,
    active: ?ObservationFold = null,
    finished: bool = false,

    pub fn init(allocator: Allocator) BlockBuilder {
        return .{
            .allocator = allocator,
            .shards = ShardFold.init(allocator),
        };
    }

    pub fn deinit(self: *BlockBuilder) void {
        if (self.active) |*active| active.deinit();
        self.shards.deinit();
        self.* = undefined;
    }

    pub fn append(
        self: *BlockBuilder,
        view: anytype,
        block_access_index: bal.BlockAccessIndex,
    ) !void {
        const active = try self.activeFold(block_access_index);
        try active.appendView(view);
    }

    pub fn appendTransition(
        self: *BlockBuilder,
        transition: observation.LaneTransition,
        block_access_index: bal.BlockAccessIndex,
    ) !void {
        const active = try self.activeFold(block_access_index);
        try active.append(transition);
    }

    pub fn finish(self: *BlockBuilder) !bal.Decoded {
        std.debug.assert(!self.finished);
        try self.flush();
        const result = try self.shards.finish();
        self.finished = true;
        return result;
    }

    fn flush(self: *BlockBuilder) !void {
        var active = self.active orelse return;
        self.active = null;
        defer active.deinit();

        for (active.accounts.items) |*account| {
            try self.shards.appendObservation(
                account.asObservation(),
                self.active_index.?,
            );
        }
        self.active_index = null;
    }

    fn activeFold(
        self: *BlockBuilder,
        block_access_index: bal.BlockAccessIndex,
    ) !*ObservationFold {
        std.debug.assert(!self.finished);
        if (self.active_index) |current| {
            std.debug.assert(block_access_index >= current);
            if (block_access_index != current) try self.flush();
        }
        if (self.active == null) {
            self.active = ObservationFold.init(self.allocator);
            self.active_index = block_access_index;
        }
        return &self.active.?;
    }
};

const ObservationFold = struct {
    allocator: Allocator,
    accounts: std.ArrayList(FoldAccount) = .empty,
    indices: std.AutoHashMap(Address, usize),

    fn init(allocator: Allocator) ObservationFold {
        return .{
            .allocator = allocator,
            .indices = .init(allocator),
        };
    }

    fn deinit(self: *ObservationFold) void {
        for (self.accounts.items) |*account| account.deinit(self.allocator);
        self.accounts.deinit(self.allocator);
        self.indices.deinit();
        self.* = undefined;
    }

    fn append(
        self: *ObservationFold,
        transition: observation.LaneTransition,
    ) !void {
        for (transition.accounts) |account| {
            const target = try self.accountFor(account.address);
            try target.append(self.allocator, account);
        }
    }

    fn appendView(self: *ObservationFold, view: anytype) !void {
        var account_index: u32 = 0;
        while (account_index < view.accounts.len()) : (account_index += 1) {
            const fact = view.accounts.at(account_index);
            if (!fact.observation.semantic_access and !fact.effect.any()) continue;
            const target = try self.accountFor(fact.address);
            try target.appendAccountFact(self.allocator, view, fact);
        }

        var storage_index: u32 = 0;
        var previous_address: ?Address = null;
        var previous_account_index: usize = undefined;
        while (storage_index < view.storage.len()) : (storage_index += 1) {
            const metadata = view.storage.metadataAt(storage_index);
            if (!metadata.observation.value_read and !metadata.effect.written) continue;
            const fact = view.storage.at(storage_index) orelse
                return error.IncompleteStorageObservation;
            if (previous_address == null or
                !std.mem.eql(u8, &previous_address.?, &fact.address))
            {
                previous_address = fact.address;
                previous_account_index = try self.accountIndexFor(fact.address);
            }
            const target = &self.accounts.items[previous_account_index];
            try target.appendStorage(self.allocator, .{
                .slot = fact.key,
                .original = fact.original,
                .current = fact.current,
            });
        }
    }

    fn accountFor(self: *ObservationFold, target: Address) !*FoldAccount {
        return &self.accounts.items[try self.accountIndexFor(target)];
    }

    fn accountIndexFor(self: *ObservationFold, target: Address) !usize {
        if (self.indices.count() == 0) {
            for (self.accounts.items, 0..) |account, index| {
                if (std.mem.eql(u8, &account.address, &target)) return index;
            }
            if (self.accounts.items.len == linear_index_limit) {
                try self.indices.ensureTotalCapacity(linear_index_limit + 1);
                for (self.accounts.items, 0..) |account, index| {
                    self.indices.putAssumeCapacity(account.address, index);
                }
            }
        }
        if (self.indices.get(target)) |index| return index;
        const index = self.accounts.items.len;
        try self.accounts.append(self.allocator, .{
            .address = target,
            .storage_indices = .init(self.allocator),
        });
        errdefer {
            var removed = self.accounts.pop().?;
            removed.deinit(self.allocator);
        }
        if (self.indices.count() != 0) try self.indices.put(target, index);
        return index;
    }
};

const FoldAccount = struct {
    address: Address,
    storage: std.ArrayList(observation.StorageObservation) = .empty,
    storage_indices: std.AutoHashMap(u256, usize),
    balance: ?observation.ValueObservation = null,
    nonce: ?observation.NonceObservation = null,
    code: ?observation.CodeObservation = null,
    storage_wiped: bool = false,

    fn deinit(self: *FoldAccount, allocator: Allocator) void {
        self.storage.deinit(allocator);
        self.storage_indices.deinit();
        if (self.code) |code| allocator.free(@constCast(code.current_code));
        self.* = undefined;
    }

    fn append(
        self: *FoldAccount,
        allocator: Allocator,
        account: observation.AccountObservation,
    ) !void {
        for (account.storage) |slot| {
            try self.appendStorage(allocator, slot);
        }
        if (account.balance) |balance| self.appendBalance(balance);
        if (account.nonce) |nonce| self.appendNonce(nonce);
        if (account.code) |code| try self.appendCode(allocator, code);
        self.storage_wiped = self.storage_wiped or account.storage_wiped;
    }

    fn appendStorage(
        self: *FoldAccount,
        allocator: Allocator,
        slot: observation.StorageObservation,
    ) !void {
        if (try self.storageIndex(slot.slot)) |index| {
            self.storage.items[index].current = slot.current;
            return;
        }
        const index = self.storage.items.len;
        try self.storage.append(allocator, slot);
        errdefer _ = self.storage.pop();
        if (self.storage_indices.count() != 0)
            try self.storage_indices.put(slot.slot, index);
    }

    fn storageIndex(self: *FoldAccount, slot: u256) !?usize {
        if (self.storage_indices.count() == 0) {
            for (self.storage.items, 0..) |entry, index| {
                if (entry.slot == slot) return index;
            }
            if (self.storage.items.len < linear_index_limit) return null;
            try self.storage_indices.ensureTotalCapacity(linear_index_limit + 1);
            for (self.storage.items, 0..) |entry, index| {
                self.storage_indices.putAssumeCapacity(entry.slot, index);
            }
        }
        return self.storage_indices.get(slot);
    }

    fn appendAccountFact(
        self: *FoldAccount,
        allocator: Allocator,
        view: anytype,
        fact: anytype,
    ) !void {
        if (fact.effect.balance_written or
            (!fact.effect.storage_wiped and
                (fact.effect.nonce_written or fact.effect.code_written)))
        {
            const original = accountOrZero(fact.original);
            const current = accountOrZero(fact.current);
            if (fact.effect.balance_written) {
                self.appendBalance(.{
                    .original = original.balance,
                    .current = current.balance,
                });
            }
            if (fact.effect.nonce_written and !fact.effect.storage_wiped) {
                self.appendNonce(.{
                    .original = original.nonce,
                    .current = current.nonce,
                });
            }
            if (fact.effect.code_written and !fact.effect.storage_wiped) {
                const code = view.code(current.code_hash) orelse
                    return error.ObservationCodeUnavailable;
                try self.appendCode(allocator, .{
                    .original_hash = original.code_hash,
                    .current_hash = current.code_hash,
                    .current_code = code.bytes,
                });
            }
        }

        self.storage_wiped = self.storage_wiped or fact.effect.storage_wiped;
    }

    fn appendBalance(self: *FoldAccount, balance: observation.ValueObservation) void {
        if (self.balance) |*current| {
            current.current = balance.current;
        } else {
            self.balance = balance;
        }
    }

    fn appendNonce(self: *FoldAccount, nonce: observation.NonceObservation) void {
        if (self.nonce) |*current| {
            current.current = nonce.current;
        } else {
            self.nonce = nonce;
        }
    }

    fn appendCode(
        self: *FoldAccount,
        allocator: Allocator,
        code: observation.CodeObservation,
    ) !void {
        const current_code = try allocator.dupe(u8, code.current_code);
        if (self.code) |*current| {
            allocator.free(@constCast(current.current_code));
            current.current_hash = code.current_hash;
            current.current_code = current_code;
        } else {
            self.code = .{
                .original_hash = code.original_hash,
                .current_hash = code.current_hash,
                .current_code = current_code,
            };
        }
    }

    /// Hand the folded rows to the caller. The code body is already owned; the
    /// slot list transfers as-is.
    fn toOwnedObservation(self: *FoldAccount, allocator: Allocator) !observation.AccountObservation {
        std.mem.sort(
            observation.StorageObservation,
            self.storage.items,
            {},
            storageObservationLessThan,
        );
        var result = self.asObservation();
        result.storage = try self.storage.toOwnedSlice(allocator);
        errdefer allocator.free(@constCast(result.storage));
        self.code = null;
        return result;
    }

    fn asObservation(self: *const FoldAccount) observation.AccountObservation {
        return .{
            .address = self.address,
            .storage = self.storage.items,
            .balance = self.balance,
            .nonce = self.nonce,
            .code = self.code,
            .storage_wiped = self.storage_wiped,
        };
    }
};

fn accountOrZero(value: anytype) Account {
    if (@TypeOf(value) == ?Account) return value orelse .{};
    return switch (value orelse .absent) {
        .loaded => |account| account,
        .absent => .{},
        .exists_only => unreachable,
    };
}

fn foldAccountLessThan(_: void, lhs: FoldAccount, rhs: FoldAccount) bool {
    return std.mem.order(u8, &lhs.address, &rhs.address) == .lt;
}

fn storageObservationLessThan(
    _: void,
    lhs: observation.StorageObservation,
    rhs: observation.StorageObservation,
) bool {
    return lhs.slot < rhs.slot;
}

fn deinitAccountObservation(
    allocator: Allocator,
    account: observation.AccountObservation,
) void {
    allocator.free(@constCast(account.storage));
    if (account.code) |code| allocator.free(@constCast(code.current_code));
}

test "existence-only semantic access does not require account fields" {
    const Reader = struct {
        var context: u8 = 0;

        fn reader() StateReader {
            return .{ .ptr = &context, .vtable = &.{
                .accountExists = accountExists,
                .loadAccount = loadAccount,
                .loadCode = loadCode,
                .getStorage = getStorage,
                .accountHasStorage = accountHasStorage,
            } };
        }

        fn accountExists(_: *anyopaque, _: Address) !bool {
            return true;
        }

        fn loadAccount(_: *anyopaque, _: Address) !?Account {
            // Alive: an EIP-161-empty account resolves to absent, which would
            // make this an existence test rather than an observation test.
            return .{ .balance = 1 };
        }

        fn loadCode(_: *anyopaque, _: [32]u8) ![]const u8 {
            return &.{};
        }

        fn getStorage(_: *anyopaque, _: Address, _: u256) !u256 {
            return 0;
        }

        fn accountHasStorage(_: *anyopaque, _: Address) !bool {
            return false;
        }
    };

    var state = State.initWithStateReader(std.testing.allocator, Reader.reader());
    defer state.deinit();
    const target = address.addr(1);
    const attempt = state.beginObservedTransaction();
    state.beginScope();
    try std.testing.expect(try state.accountExists(target));
    _ = try state.accessAccount(target);
    state.closeScope();
    state.seal(attempt);

    var transition = try materialize(state.pendingView().observations(), std.testing.allocator);
    defer transition.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), transition.accounts.len);
    try std.testing.expectEqualSlices(u8, &target, &transition.accounts[0].address);
    try std.testing.expectEqual(@as(?observation.ValueObservation, null), transition.accounts[0].balance);
    try std.testing.expectEqual(@as(?observation.NonceObservation, null), transition.accounts[0].nonce);
    try std.testing.expectEqual(@as(?observation.CodeObservation, null), transition.accounts[0].code);
}

test "gas-only storage access does not require storage values" {
    var state = State.init(std.testing.allocator);
    defer state.deinit();
    const attempt = state.beginObservedTransaction();
    state.beginScope();
    _ = try state.accessStorage(address.addr(1), 7);
    state.closeScope();
    state.seal(attempt);

    var transition = try materialize(state.pendingView().observations(), std.testing.allocator);
    defer transition.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), transition.accounts.len);
}

test "small observation indices promote and preserve duplicate merges" {
    const allocator = std.testing.allocator;
    var fold = ObservationFold.init(allocator);
    defer fold.deinit();

    for (0..linear_index_limit + 1) |index| {
        _ = try fold.accountFor(address.addr(@as(u64, @intCast(index + 1))));
    }
    try std.testing.expectEqual(linear_index_limit + 1, fold.accounts.items.len);
    try std.testing.expectEqual(linear_index_limit + 1, fold.indices.count());
    const duplicate = address.addr(@as(u64, 4));
    _ = try fold.accountFor(duplicate);
    try std.testing.expectEqual(linear_index_limit + 1, fold.accounts.items.len);

    var account = FoldAccount{
        .address = address.addr(1),
        .storage_indices = .init(allocator),
    };
    defer account.deinit(allocator);
    for (0..linear_index_limit + 1) |index| {
        const slot: u256 = @intCast(index);
        try account.append(allocator, .{
            .address = account.address,
            .storage = &.{.{
                .slot = slot,
                .original = slot,
                .current = slot + 1,
            }},
        });
    }
    try std.testing.expectEqual(linear_index_limit + 1, account.storage.items.len);
    try std.testing.expectEqual(linear_index_limit + 1, account.storage_indices.count());
    try account.append(allocator, .{
        .address = account.address,
        .storage = &.{.{
            .slot = 3,
            .original = 3,
            .current = 99,
        }},
    });
    try std.testing.expectEqual(linear_index_limit + 1, account.storage.items.len);
    try std.testing.expectEqual(@as(u256, 99), account.storage.items[3].current);
}

test "block builder coalesces transitions at one access index" {
    const allocator = std.testing.allocator;
    const target = address.addr(1);

    var state = State.init(allocator);
    defer state.deinit();
    var seeded = MemoryAccount.init(allocator);
    seeded.account.balance = 10;
    try state.seedAccount(target, seeded);

    var builder = BlockBuilder.init(allocator);
    defer builder.deinit();
    var reference_builder = BlockBuilder.init(allocator);
    defer reference_builder.deinit();

    const first = state.beginObservedTransaction();
    state.beginScope();
    try state.setBalance(target, 12);
    state.closeScope();
    state.seal(first);
    try builder.append(state.pendingView().observations(), 3);
    var first_transition = try materialize(state.pendingView().observations(), allocator);
    defer first_transition.deinit(allocator);
    try reference_builder.appendTransition(first_transition, 3);
    state.retain(first);

    const second = state.beginObservedTransaction();
    state.beginScope();
    try state.setBalance(target, 15);
    state.closeScope();
    state.seal(second);
    try builder.append(state.pendingView().observations(), 3);
    var second_transition = try materialize(state.pendingView().observations(), allocator);
    defer second_transition.deinit(allocator);
    try reference_builder.appendTransition(second_transition, 3);
    state.retain(second);

    var result = try builder.finish();
    defer result.deinit(allocator);
    var reference = try reference_builder.finish();
    defer reference.deinit(allocator);
    try expectEqualEncoded(allocator, reference, result);
    try std.testing.expectEqual(@as(usize, 1), result.accounts.len);
    try std.testing.expectEqualSlices(u8, &target, &result.accounts[0].address);
    try std.testing.expectEqual(@as(usize, 1), result.accounts[0].balance_changes.len);
    try std.testing.expectEqual(
        @as(bal.BlockAccessIndex, 3),
        result.accounts[0].balance_changes[0].block_access_index,
    );
    try std.testing.expectEqual(
        @as(u256, 15),
        result.accounts[0].balance_changes[0].post_balance,
    );
}

fn expectEqualEncoded(
    allocator: Allocator,
    expected: bal.Decoded,
    actual: bal.Decoded,
) !void {
    const expected_encoded = try bal.encodeAlloc(allocator, expected.accounts);
    defer allocator.free(expected_encoded);
    const actual_encoded = try bal.encodeAlloc(allocator, actual.accounts);
    defer allocator.free(actual_encoded);
    try std.testing.expectEqualSlices(u8, expected_encoded, actual_encoded);
}
