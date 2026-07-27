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
const StateReader = @import("../../state/Reader.zig");
const bal = @import("model.zig");
const observation = @import("observation.zig");
const oracle_recorder = @import("recorder.zig");
const ShardFold = @import("shard_fold.zig").ShardFold;

const Address = address.Address;
const Allocator = std.mem.Allocator;
const linear_index_limit = 8;

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
        const metadata = view.storage.metadataAt(storage_index);
        if (!metadata.observation.value_read and !metadata.effect.written) continue;
        const fact = view.storage.at(storage_index) orelse
            return error.IncompleteStorageObservation;
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

    fn appendView(self: *ObservationFold, view: State.ObservationsView) !void {
        var account_index: u32 = 0;
        while (account_index < view.accounts.len()) : (account_index += 1) {
            const fact = view.accounts.at(account_index);
            if (!fact.observation.semantic_access and !fact.effect.any()) continue;
            const target = try self.accountFor(fact.address);
            try target.appendAccountFact(self.allocator, view, fact);
        }

        var storage_index: u32 = 0;
        while (storage_index < view.storage.len()) : (storage_index += 1) {
            const metadata = view.storage.metadataAt(storage_index);
            if (!metadata.observation.value_read and !metadata.effect.written) continue;
            const fact = view.storage.at(storage_index) orelse
                return error.IncompleteStorageObservation;
            const target = try self.accountFor(fact.address);
            try target.appendStorage(self.allocator, .{
                .slot = fact.key,
                .original = fact.original,
                .current = fact.current,
                .written = fact.effect.written,
            });
        }
    }

    fn accountFor(self: *ObservationFold, target: Address) !*FoldAccount {
        if (self.indices.count() == 0) {
            for (self.accounts.items) |*account| {
                if (std.mem.eql(u8, &account.address, &target)) return account;
            }
            if (self.accounts.items.len == linear_index_limit) {
                try self.indices.ensureTotalCapacity(linear_index_limit + 1);
                for (self.accounts.items, 0..) |account, index| {
                    self.indices.putAssumeCapacity(account.address, index);
                }
            }
        }
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
        if (self.indices.count() != 0) try self.indices.put(target, index);
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
            try self.appendStorage(allocator, slot);
        }
        if (account.balance) |balance| self.appendBalance(balance);
        if (account.nonce) |nonce| self.appendNonce(nonce);
        if (account.code) |code| try self.appendCode(allocator, code);
        try self.lifecycle.appendSlice(allocator, account.lifecycle);
        self.appendFlags(account.account_reset, account.account_deleted, account.storage_wiped);
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
        view: State.ObservationsView,
        fact: State.AccountObservationFact,
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

        const lifecycle_len: usize =
            @intFromBool(fact.effect.created_contract) +
            @intFromBool(fact.effect.selfdestruct) +
            @intFromBool(fact.effect.account_deleted);
        try self.lifecycle.ensureUnusedCapacity(allocator, lifecycle_len);
        if (fact.effect.created_contract) self.lifecycle.appendAssumeCapacity(.created_contract);
        if (fact.effect.selfdestruct) self.lifecycle.appendAssumeCapacity(.selfdestruct);
        if (fact.effect.account_deleted) self.lifecycle.appendAssumeCapacity(.account_deleted);

        self.appendFlags(
            accountAbsent(fact.original) and
                (!accountAbsent(fact.current) or fact.effect.created_contract),
            fact.effect.account_deleted,
            fact.effect.storage_wiped,
        );
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

    fn appendFlags(
        self: *FoldAccount,
        account_reset: bool,
        account_deleted: bool,
        storage_wiped: bool,
    ) void {
        self.account_reset = self.account_reset or account_reset;
        if (account_reset) self.account_deleted = false;
        if (account_deleted) self.account_deleted = true;
        self.storage_wiped = self.storage_wiped or storage_wiped;
    }

    fn asObservation(self: *const FoldAccount) observation.AccountObservation {
        return .{
            .address = self.address,
            .storage = self.storage.items,
            .balance = self.balance,
            .nonce = self.nonce,
            .code = self.code,
            .lifecycle = self.lifecycle.items,
            .account_reset = self.account_reset,
            .account_deleted = self.account_deleted,
            .storage_wiped = self.storage_wiped,
        };
    }
};

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
        result.account_reset = accountAbsent(fact.original) and
            (!accountAbsent(fact.current) or fact.effect.created_contract);
        result.account_deleted = fact.effect.account_deleted;
        result.storage_wiped = fact.effect.storage_wiped;
        if (fact.effect.balance_written) {
            result.balance = .{
                .original = accountOrZero(fact.original).balance,
                .current = accountOrZero(fact.current).balance,
            };
        }
        // A wipe only ever accompanies a same-transaction creation, so the
        // account is already reset for the consumer; the zeroed nonce and code
        // finalization writes are implied and must not reappear as changes.
        if (fact.effect.nonce_written and !fact.effect.storage_wiped) {
            result.nonce = .{
                .original = accountOrZero(fact.original).nonce,
                .current = accountOrZero(fact.current).nonce,
            };
        }
        if (fact.effect.code_written and !fact.effect.storage_wiped) {
            const original = accountOrZero(fact.original);
            const current = accountOrZero(fact.current);
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
            return .{};
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
    var direct_builder = BlockBuilder.init(allocator);
    defer direct_builder.deinit();
    try direct_builder.append(state.pendingView().observations(), 1);
    var direct = try direct_builder.finish();
    defer direct.deinit(allocator);
    try expectEqualEncoded(allocator, actual, direct);

    var expected = try oracle.toOwnedBlockAccessList(allocator);
    defer expected.deinit(allocator);
    try expectEqualEncoded(allocator, expected, actual);
}

test "selfdestruct finalization projects post-transaction BAL state" {
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
        .value = 0,
    });
    try state.setNonce(target, 4);
    try state.setCode(target, &replacement_code);
    _ = try state.setStorage(target, 7, 13);
    try oracle.recordStorageRead(.{
        .address = target,
        .key = 7,
        .value = 11,
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
                .written = true,
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
            .written = true,
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
    seeded.balance = 10;
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
