//! BAL adapter over one sealed tracked-state observation view.
//!
//! The tracked rows are the checkpoint-resolved source. This module owns BAL
//! grouping, sorting, allocation, and detached ownership.

const std = @import("std");
const address = @import("../../address.zig");
const crypto = @import("../../crypto.zig");
const State = @import("../../state/TrackedState.zig");
const Account = @import("../../state/Account.zig");
const MemoryAccount = @import("../../state/MemoryAccount.zig");
const bal = @import("model.zig");
const observation = @import("observation.zig");
const oracle_recorder = @import("recorder.zig");
const ShardFold = @import("shard_fold.zig").ShardFold;

const Address = address.Address;
const Allocator = std.mem.Allocator;

pub fn materialize(
    view: State.ObservationsView,
    allocator: Allocator,
) !observation.LaneTransition {
    var builders: std.ArrayList(AccountBuilder) = .empty;
    defer {
        for (builders.items) |*builder| builder.deinit(allocator);
        builders.deinit(allocator);
    }
    var indices = std.AutoHashMap(Address, usize).init(allocator);
    defer indices.deinit();

    var account_index: u32 = 0;
    while (account_index < view.accounts.len()) : (account_index += 1) {
        const fact = view.accounts.at(account_index);
        if (!fact.observation.semantic_access and !fact.effect.any()) continue;
        const builder = try accountBuilderFor(
            allocator,
            &builders,
            &indices,
            fact.address,
        );
        builder.account = fact;
    }

    var storage_index: u32 = 0;
    while (storage_index < view.storage.len()) : (storage_index += 1) {
        const fact = view.storage.at(storage_index);
        if (!fact.observation.value_read and !fact.effect.written) continue;
        const builder = try accountBuilderFor(
            allocator,
            &builders,
            &indices,
            fact.address,
        );
        try builder.storage.append(allocator, .{
            .slot = fact.key,
            .original = fact.original,
            .current = fact.current,
            .written = fact.effect.written,
        });
    }

    std.mem.sort(AccountBuilder, builders.items, {}, accountBuilderLessThan);
    var accounts: std.ArrayList(observation.AccountObservation) = .empty;
    errdefer {
        for (accounts.items) |account| deinitAccountObservation(allocator, account);
        accounts.deinit(allocator);
    }
    try accounts.ensureTotalCapacity(allocator, builders.items.len);
    for (builders.items) |*builder| {
        accounts.appendAssumeCapacity(try builder.toOwnedObservation(view, allocator));
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
        view: State.ObservationsView,
        block_access_index: bal.BlockAccessIndex,
    ) !void {
        var transition = try materialize(view, self.allocator);
        defer transition.deinit(self.allocator);
        try self.appendTransition(transition, block_access_index);
    }

    pub fn appendTransition(
        self: *BlockBuilder,
        transition: observation.LaneTransition,
        block_access_index: bal.BlockAccessIndex,
    ) !void {
        std.debug.assert(!self.finished);
        if (self.active_index) |current| {
            std.debug.assert(block_access_index >= current);
            if (block_access_index != current) try self.flush();
        }
        if (self.active == null) {
            self.active = ObservationFold.init(self.allocator);
            self.active_index = block_access_index;
        }
        try self.active.?.append(transition);
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

        var delta = try active.finish();
        defer delta.deinit(self.allocator);
        var shard = try delta.toOwnedBlockAccessList(
            self.allocator,
            self.active_index.?,
        );
        defer shard.deinit(self.allocator);
        try self.shards.append(shard.accounts);
        self.active_index = null;
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

    fn finish(self: *ObservationFold) !observation.LaneTransition {
        std.mem.sort(FoldAccount, self.accounts.items, {}, foldAccountLessThan);
        const accounts = try self.allocator.alloc(
            observation.AccountObservation,
            self.accounts.items.len,
        );
        errdefer self.allocator.free(accounts);

        var initialized: usize = 0;
        errdefer for (accounts[0..initialized]) |account|
            deinitAccountObservation(self.allocator, account);
        for (self.accounts.items, 0..) |*account, index| {
            accounts[index] = try account.takeObservation(self.allocator);
            initialized += 1;
        }
        return .{ .accounts = accounts };
    }

    fn accountFor(self: *ObservationFold, target: Address) !*FoldAccount {
        if (self.indices.get(target)) |index| return &self.accounts.items[index];
        const index = self.accounts.items.len;
        try self.accounts.append(self.allocator, .{
            .address = target,
            .storage_indices = .init(self.allocator),
        });
        errdefer {
            var removed = self.accounts.pop().?;
            removed.deinit(self.allocator);
        }
        try self.indices.put(target, index);
        return &self.accounts.items[index];
    }
};

const FoldAccount = struct {
    address: Address,
    storage: std.ArrayList(observation.StorageObservation) = .empty,
    storage_indices: std.AutoHashMap(u256, usize),
    balance: ?observation.ValueObservation = null,
    nonce: ?observation.NonceObservation = null,
    code: ?observation.CodeObservation = null,
    lifecycle: std.ArrayList(observation.LifecycleKind) = .empty,
    account_reset: bool = false,
    account_deleted: bool = false,
    storage_wiped: bool = false,

    fn deinit(self: *FoldAccount, allocator: Allocator) void {
        self.storage.deinit(allocator);
        self.storage_indices.deinit();
        if (self.code) |code| allocator.free(@constCast(code.current_code));
        self.lifecycle.deinit(allocator);
        self.* = undefined;
    }

    fn append(
        self: *FoldAccount,
        allocator: Allocator,
        account: observation.AccountObservation,
    ) !void {
        for (account.storage) |slot| {
            if (self.storage_indices.get(slot.slot)) |index| {
                self.storage.items[index].current = slot.current;
            } else {
                const index = self.storage.items.len;
                try self.storage.append(allocator, slot);
                errdefer _ = self.storage.pop();
                try self.storage_indices.put(slot.slot, index);
            }
        }
        if (account.balance) |balance| {
            if (self.balance) |*current| {
                current.current = balance.current;
            } else {
                self.balance = balance;
            }
        }
        if (account.nonce) |nonce| {
            if (self.nonce) |*current| {
                current.current = nonce.current;
            } else {
                self.nonce = nonce;
            }
        }
        if (account.code) |code| {
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
        try self.lifecycle.appendSlice(allocator, account.lifecycle);
        self.account_reset = self.account_reset or account.account_reset;
        if (account.account_reset) self.account_deleted = false;
        if (account.account_deleted) self.account_deleted = true;
        self.storage_wiped = self.storage_wiped or account.storage_wiped;
    }

    fn takeObservation(
        self: *FoldAccount,
        allocator: Allocator,
    ) !observation.AccountObservation {
        std.mem.sort(
            observation.StorageObservation,
            self.storage.items,
            {},
            storageObservationLessThan,
        );
        var result = observation.AccountObservation{
            .address = self.address,
            .balance = self.balance,
            .nonce = self.nonce,
            .account_reset = self.account_reset,
            .account_deleted = self.account_deleted,
            .storage_wiped = self.storage_wiped,
        };
        errdefer deinitAccountObservation(allocator, result);
        result.storage = try self.storage.toOwnedSlice(allocator);
        if (self.code) |code| {
            result.code = code;
            self.code = null;
        }
        result.lifecycle = try self.lifecycle.toOwnedSlice(allocator);
        return result;
    }
};

fn foldAccountLessThan(_: void, lhs: FoldAccount, rhs: FoldAccount) bool {
    return std.mem.order(u8, &lhs.address, &rhs.address) == .lt;
}

const AccountBuilder = struct {
    address: Address,
    account: ?State.AccountObservationFact = null,
    storage: std.ArrayList(observation.StorageObservation) = .empty,

    fn deinit(self: *AccountBuilder, allocator: Allocator) void {
        self.storage.deinit(allocator);
        self.* = undefined;
    }

    fn toOwnedObservation(
        self: *AccountBuilder,
        view: State.ObservationsView,
        allocator: Allocator,
    ) !observation.AccountObservation {
        var result = observation.AccountObservation{ .address = self.address };
        errdefer deinitAccountObservation(allocator, result);

        std.mem.sort(
            observation.StorageObservation,
            self.storage.items,
            {},
            storageObservationLessThan,
        );
        result.storage = try self.storage.toOwnedSlice(allocator);

        const fact = self.account orelse return result;
        const original = accountOrZero(fact.original);
        const current = accountOrZero(fact.current);
        result.account_reset = accountAbsent(fact.original) and
            (!accountAbsent(fact.current) or fact.effect.created_contract);
        result.account_deleted = fact.effect.account_deleted;
        result.storage_wiped = fact.effect.storage_wiped;
        if (fact.effect.balance_written) {
            result.balance = .{
                .original = original.balance,
                .current = current.balance,
            };
        }
        if (fact.effect.nonce_written) {
            result.nonce = .{
                .original = original.nonce,
                .current = current.nonce,
            };
        }
        if (fact.effect.code_written) {
            const code = view.code(current.code_hash) orelse
                return error.ObservationCodeUnavailable;
            result.code = .{
                .original_hash = original.code_hash,
                .current_hash = current.code_hash,
                .current_code = try allocator.dupe(u8, code.bytes),
            };
        }

        const lifecycle_len =
            @as(usize, @intFromBool(fact.effect.created_contract)) +
            @as(usize, @intFromBool(fact.effect.selfdestruct)) +
            @as(usize, @intFromBool(fact.effect.account_deleted));
        if (lifecycle_len != 0) {
            const lifecycle = try allocator.alloc(
                observation.LifecycleKind,
                lifecycle_len,
            );
            var index: usize = 0;
            if (fact.effect.created_contract) {
                lifecycle[index] = .created_contract;
                index += 1;
            }
            if (fact.effect.selfdestruct) {
                lifecycle[index] = .selfdestruct;
                index += 1;
            }
            if (fact.effect.account_deleted) {
                lifecycle[index] = .account_deleted;
            }
            result.lifecycle = lifecycle;
        }
        return result;
    }
};

fn accountBuilderFor(
    allocator: Allocator,
    builders: *std.ArrayList(AccountBuilder),
    indices: *std.AutoHashMap(Address, usize),
    account_address: Address,
) !*AccountBuilder {
    if (indices.get(account_address)) |index| return &builders.items[index];
    const index = builders.items.len;
    try builders.append(allocator, .{ .address = account_address });
    errdefer _ = builders.pop();
    try indices.put(account_address, index);
    return &builders.items[index];
}

fn accountOrZero(value: ?State.AccountValue) Account {
    return switch (value orelse .absent) {
        .loaded => |account| account,
        .absent => .{},
        .exists_only => unreachable,
    };
}

fn accountAbsent(value: ?State.AccountValue) bool {
    return switch (value orelse .absent) {
        .absent => true,
        .loaded, .exists_only => false,
    };
}

fn accountBuilderLessThan(_: void, lhs: AccountBuilder, rhs: AccountBuilder) bool {
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
    allocator.free(@constCast(account.lifecycle));
}

test "tracked observations match recorder after inner rollback" {
    const allocator = std.testing.allocator;
    const target = address.addr(1);
    const accessed = address.addr(2);
    const reverted = address.addr(3);
    const original_code = [_]u8{ 0x60, 0x01 };
    const replacement_code = [_]u8{ 0x60, 0x02 };

    var state = State.init(allocator);
    defer state.deinit();
    var seeded = MemoryAccount.init(allocator);
    seeded.balance = 10;
    seeded.nonce = 3;
    try seeded.setCode(&original_code);
    try seeded.storage.put(7, 11);
    try state.seedAccount(target, seeded);

    var oracle = oracle_recorder.Recorder.init(allocator);
    defer oracle.deinit();
    oracle.setBlockAccessIndex(1);

    const attempt = state.beginObservedTransaction();
    state.beginScope();
    try state.observeAccountAccess(accessed);
    try oracle.recordAccountAccess(accessed);

    try state.setBalance(target, 12);
    try oracle.recordBalanceWrite(.{
        .address = target,
        .previous = 10,
        .value = 12,
    });
    try state.setNonce(target, 4);
    try oracle.recordNonceWrite(.{
        .address = target,
        .previous = 3,
        .value = 4,
    });
    try state.setCode(target, &replacement_code);
    try oracle.recordCodeWrite(.{
        .address = target,
        .previous_hash = crypto.keccak256(&original_code),
        .size = replacement_code.len,
        .code = &replacement_code,
    });
    _ = try state.setStorage(target, 7, 13);
    try oracle.recordStorageWrite(.{
        .address = target,
        .key = 7,
        .previous = 11,
        .value = 13,
    });
    _ = try state.getStorage(target, 8);
    try oracle.recordStorageRead(.{
        .address = target,
        .key = 8,
        .value = 0,
    });

    const checkpoint = state.checkpoint();
    try oracle.checkpoint(.{
        .kind = .checkpoint,
        .depth = 1,
        .journal_len = 0,
        .logs_len = 0,
    });
    try state.setBalance(reverted, 9);
    try oracle.recordBalanceWrite(.{
        .address = reverted,
        .previous = 0,
        .value = 9,
    });
    _ = try state.setStorage(target, 7, 15);
    try oracle.recordStorageWrite(.{
        .address = target,
        .key = 7,
        .previous = 13,
        .value = 15,
    });
    try state.markCreatedContract(reverted);
    try oracle.recordLifecycle(.created_contract, reverted);
    state.revertToCheckpoint(checkpoint);
    try oracle.checkpoint(.{
        .kind = .revert,
        .depth = 1,
        .journal_len = 0,
        .logs_len = 0,
    });

    state.closeScope();
    state.seal(attempt);

    var delta = try materialize(state.pendingView().observations(), allocator);
    defer delta.deinit(allocator);
    var actual = try delta.toOwnedBlockAccessList(allocator, 1);
    defer actual.deinit(allocator);
    var expected = try oracle.toOwnedBlockAccessList(allocator);
    defer expected.deinit(allocator);
    try expectEqualEncoded(allocator, expected, actual);
}

test "tracked observations preserve writes hidden by finalization" {
    const allocator = std.testing.allocator;
    const target = address.addr(1);
    const original_code = [_]u8{ 0x60, 0x01 };
    const replacement_code = [_]u8{ 0x60, 0x02 };

    var state = State.init(allocator);
    defer state.deinit();
    var seeded = MemoryAccount.init(allocator);
    seeded.balance = 10;
    seeded.nonce = 3;
    try seeded.setCode(&original_code);
    try seeded.storage.put(7, 11);
    try state.seedAccount(target, seeded);

    var oracle = oracle_recorder.Recorder.init(allocator);
    defer oracle.deinit();
    oracle.setBlockAccessIndex(1);

    const attempt = state.beginObservedTransaction();
    state.beginScope();
    try state.setBalance(target, 12);
    try oracle.recordBalanceWrite(.{
        .address = target,
        .previous = 10,
        .value = 12,
    });
    try state.setNonce(target, 4);
    try oracle.recordNonceWrite(.{
        .address = target,
        .previous = 3,
        .value = 4,
    });
    try state.setCode(target, &replacement_code);
    try oracle.recordCodeWrite(.{
        .address = target,
        .previous_hash = crypto.keccak256(&original_code),
        .size = replacement_code.len,
        .code = &replacement_code,
    });
    _ = try state.setStorage(target, 7, 13);
    try oracle.recordStorageWrite(.{
        .address = target,
        .key = 7,
        .previous = 11,
        .value = 13,
    });
    try state.markSelfdestructed(target);
    try oracle.recordLifecycle(.selfdestruct, target);
    try state.finalize(.{ .existing_account = .{
        .delete_account = true,
        .clear_storage = true,
    } });
    try oracle.recordLifecycle(.account_deleted, target);
    state.closeScope();
    state.seal(attempt);

    var delta = try materialize(state.pendingView().observations(), allocator);
    defer delta.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), delta.accounts.len);
    try std.testing.expectEqualSlices(
        observation.LifecycleKind,
        &.{ .selfdestruct, .account_deleted },
        delta.accounts[0].lifecycle,
    );
    try std.testing.expect(delta.accounts[0].account_deleted);
    try std.testing.expect(delta.accounts[0].storage_wiped);
    try std.testing.expect(delta.accounts[0].storage[0].written);

    var actual = try delta.toOwnedBlockAccessList(allocator, 1);
    defer actual.deinit(allocator);
    var expected = try oracle.toOwnedBlockAccessList(allocator);
    defer expected.deinit(allocator);
    try expectEqualEncoded(allocator, expected, actual);
}

test "block builder coalesces transitions at one access index" {
    const allocator = std.testing.allocator;
    const target = address.addr(1);

    var state = State.init(allocator);
    defer state.deinit();
    var seeded = MemoryAccount.init(allocator);
    seeded.balance = 10;
    try state.seedAccount(target, seeded);

    var builder = BlockBuilder.init(allocator);
    defer builder.deinit();

    const first = state.beginObservedTransaction();
    state.beginScope();
    try state.setBalance(target, 12);
    state.closeScope();
    state.seal(first);
    try builder.append(state.pendingView().observations(), 3);
    state.retain(first);

    const second = state.beginObservedTransaction();
    state.beginScope();
    try state.setBalance(target, 15);
    state.closeScope();
    state.seal(second);
    try builder.append(state.pendingView().observations(), 3);
    state.retain(second);

    var result = try builder.finish();
    defer result.deinit(allocator);
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
