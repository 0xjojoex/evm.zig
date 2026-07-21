//! Positioned `StateReader` adapter over a validated EIP-7928 claim.
//!
//! Covered account and storage reads see the latest claim value at or before
//! `block_access_index`, falling back to authenticated pre-state when no claim
//! write applies yet. Reads outside claim coverage fail closed.
//!
//! BAL does not inventory untouched storage. When a positioned write clears a
//! pre-state nonzero slot, a boolean pre-state `accountHasStorage` result cannot
//! prove whether another untouched slot remains. That case is reported as
//! `PositionedStorageUnknown`; callers must leave the BAL path rather than
//! guess.
//!
//! BAL reads also lack position indices. A legacy empty base account can be
//! touched and deleted without a net claim mutation, so its later presence is
//! reported as `PositionedAccountUnknown`. Index zero remains exact pre-state.

const std = @import("std");

const address = @import("../address.zig");
const bal = @import("../eth/bal/model.zig");
const ClaimView = @import("../eth/bal/ClaimView.zig");
const crypto = @import("../crypto.zig");
const Account = @import("./Account.zig");
const Reader = @import("./Reader.zig");

const Address = address.Address;
const BalClaimReader = @This();

pub const Error = error{
    BlockAccessListAccountNotCovered,
    BlockAccessListStorageNotCovered,
    PositionedAccountUnknown,
    PositionedStorageUnknown,
};

pub const StoragePresence = enum {
    empty,
    nonempty,
    unknown,
};

/// Detailed cause retained beside the generic executor strategy failure.
pub const StrategyFailure = enum {
    account_not_covered,
    storage_not_covered,
    positioned_account_unknown,
    positioned_storage_unknown,
};

base: Reader,
claim: *const ClaimView,
block_access_index: bal.BlockAccessIndex,
strategy_failure: ?StrategyFailure = null,

pub fn init(base: Reader, claim: *const ClaimView, block_access_index: bal.BlockAccessIndex) BalClaimReader {
    return .{
        .base = base,
        .claim = claim,
        .block_access_index = block_access_index,
    };
}

pub fn reader(self: *BalClaimReader) Reader {
    return .{ .ptr = self, .vtable = &vtable };
}

/// Exact when possible; `.unknown` is the conservative result when the BAL and
/// the base reader's boolean storage summary cannot identify the last slot.
pub fn storagePresence(self: *BalClaimReader, target: Address) !StoragePresence {
    const account_cursor = self.claim.account(target) orelse return self.fail(.account_not_covered);
    if (try self.loadPositionedAccountFor(target, account_cursor) == null) return .empty;
    return self.storagePresenceFor(target, account_cursor);
}

fn storagePresenceFor(self: *BalClaimReader, target: Address, account_cursor: ClaimView.AccountCursor) !StoragePresence {
    var positioned_writes = account_cursor.storageWritesAt(self.block_access_index);
    while (positioned_writes.next()) |write| {
        if (write.value != 0) return .nonempty;
    }

    if (!try self.base.accountHasStorage(target)) return .empty;
    positioned_writes = account_cursor.storageWritesAt(self.block_access_index);
    while (positioned_writes.next()) |write| {
        std.debug.assert(write.value == 0);
        if (try self.base.getStorage(target, write.slot) != 0) {
            return .unknown;
        }
    }

    return .nonempty;
}

const vtable = Reader.VTable{
    .accountExists = accountExists,
    .loadAccount = loadAccount,
    .loadCode = loadCode,
    .getStorage = getStorage,
    .accountHasStorage = accountHasStorage,
};

fn context(ptr: *anyopaque) *BalClaimReader {
    return @ptrCast(@alignCast(ptr));
}

fn accountExists(ptr: *anyopaque, target: Address) !bool {
    return (try loadPositionedAccount(context(ptr), target)) != null;
}

fn loadAccount(ptr: *anyopaque, target: Address) !?Account {
    return loadPositionedAccount(context(ptr), target);
}

fn loadPositionedAccount(self: *BalClaimReader, target: Address) !?Account {
    const account_cursor = self.claim.account(target) orelse return self.fail(.account_not_covered);
    return self.loadPositionedAccountFor(target, account_cursor);
}

fn loadPositionedAccountFor(self: *BalClaimReader, target: Address, account_cursor: ClaimView.AccountCursor) !?Account {
    const balance = account_cursor.balanceAt(self.block_access_index);
    const nonce = account_cursor.nonceAt(self.block_access_index);
    const code = account_cursor.codeAt(self.block_access_index);
    const has_positioned_storage_write = account_cursor.hasStorageWriteAt(self.block_access_index);
    const has_positioned_mutation = balance != null or nonce != null or code != null or has_positioned_storage_write;

    const base_account = if (balance != null and nonce != null and code != null)
        null
    else
        try self.base.loadAccount(target);
    var positioned_account = base_account orelse Account{};
    if (balance) |value| positioned_account.balance = value;
    if (nonce) |value| positioned_account.nonce = value;
    if (code) |value| positioned_account.code_hash = value.hash;

    if (!accountFieldsEmpty(positioned_account)) return positioned_account;
    if (!has_positioned_mutation and base_account == null) return null;
    if (!has_positioned_mutation and self.block_access_index == 0) return base_account;

    // BAL has no indexed account-access/deletion fact. At later positions an
    // empty base leaf may have survived untouched or been removed by EIP-161;
    // an applicable mutation ending empty has the same missing lifecycle bit.
    return self.fail(.positioned_account_unknown);
}

fn loadCode(ptr: *anyopaque, code_hash: [32]u8) ![]const u8 {
    const self = context(ptr);
    if (self.claim.codeByHash(code_hash)) |code| return code.bytes;

    // Delegate through the underlying vtable so the outer Reader performs the
    // content-hash check exactly once for both base and claim code.
    return self.base.vtable.loadCode(self.base.ptr, code_hash);
}

fn getStorage(ptr: *anyopaque, target: Address, key: u256) !u256 {
    const self = context(ptr);
    const account_cursor = self.claim.account(target) orelse return self.fail(.account_not_covered);
    const lookup = account_cursor.storageLookupAt(key, self.block_access_index);
    switch (lookup) {
        .uncovered => return self.fail(.storage_not_covered),
        .prestate, .value => {},
    }
    if (try self.loadPositionedAccountFor(target, account_cursor) == null) return 0;
    return switch (lookup) {
        .uncovered => unreachable,
        .prestate => self.base.getStorage(target, key),
        .value => |value| value,
    };
}

fn accountHasStorage(ptr: *anyopaque, target: Address) !bool {
    return switch (try context(ptr).storagePresence(target)) {
        .empty => false,
        .nonempty => true,
        .unknown => context(ptr).fail(.positioned_storage_unknown),
    };
}

fn fail(self: *BalClaimReader, failure: StrategyFailure) Error {
    self.strategy_failure = failure;
    return switch (failure) {
        .account_not_covered => error.BlockAccessListAccountNotCovered,
        .storage_not_covered => error.BlockAccessListStorageNotCovered,
        .positioned_account_unknown => error.PositionedAccountUnknown,
        .positioned_storage_unknown => error.PositionedStorageUnknown,
    };
}

fn accountFieldsEmpty(account: Account) bool {
    return account.nonce == 0 and
        account.balance == 0 and
        std.mem.eql(u8, &account.code_hash, &crypto.keccak256_empty);
}

const TestStorage = struct {
    key: u256,
    value: u256,
};

const TestBase = struct {
    target: Address,
    account: ?Account = null,
    code: []const u8 = &.{},
    code_key: ?[32]u8 = null,
    storage: []const TestStorage = &.{},

    fn reader(self: *TestBase) Reader {
        return .{ .ptr = self, .vtable = &.{
            .accountExists = testAccountExists,
            .loadAccount = testLoadAccount,
            .loadCode = testLoadCode,
            .getStorage = testGetStorage,
            .accountHasStorage = testAccountHasStorage,
        } };
    }

    fn from(ptr: *anyopaque) *TestBase {
        return @ptrCast(@alignCast(ptr));
    }

    fn testAccountExists(ptr: *anyopaque, target: Address) !bool {
        const self = from(ptr);
        return std.mem.eql(u8, &self.target, &target) and self.account != null;
    }

    fn testLoadAccount(ptr: *anyopaque, target: Address) !?Account {
        const self = from(ptr);
        if (!std.mem.eql(u8, &self.target, &target)) return null;
        return self.account;
    }

    fn testLoadCode(ptr: *anyopaque, code_hash: [32]u8) ![]const u8 {
        const self = from(ptr);
        if (std.mem.eql(u8, &code_hash, &crypto.keccak256_empty)) return &.{};
        const stored_hash = self.code_key orelse crypto.keccak256(self.code);
        if (std.mem.eql(u8, &code_hash, &stored_hash)) return self.code;
        return error.MissingCode;
    }

    fn testGetStorage(ptr: *anyopaque, target: Address, key: u256) !u256 {
        const self = from(ptr);
        if (!std.mem.eql(u8, &self.target, &target)) return 0;
        for (self.storage) |entry| {
            if (entry.key == key) return entry.value;
        }
        return 0;
    }

    fn testAccountHasStorage(ptr: *anyopaque, target: Address) !bool {
        const self = from(ptr);
        if (!std.mem.eql(u8, &self.target, &target)) return false;
        for (self.storage) |entry| {
            if (entry.value != 0) return true;
        }
        return false;
    }
};

test "BalClaimReader resolves positioned account code and storage" {
    const target = address.addr(1);
    const old_code = [_]u8{0x00};
    const new_code = [_]u8{ 0x60, 0x00 };
    const storage_changes = [_]bal.StorageChange{.{ .block_access_index = 1, .new_value = 7 }};
    const slots = [_]bal.SlotChanges{.{ .slot = 2, .changes = &storage_changes }};
    const reads = [_]u256{3};
    const balance_changes = [_]bal.BalanceChange{.{ .block_access_index = 1, .post_balance = 20 }};
    const nonce_changes = [_]bal.NonceChange{.{ .block_access_index = 2, .new_nonce = 3 }};
    const code_changes = [_]bal.CodeChange{.{ .block_access_index = 2, .new_code = &new_code }};
    const claim = [_]bal.AccountChanges{.{
        .address = target,
        .storage_changes = &slots,
        .storage_reads = &reads,
        .balance_changes = &balance_changes,
        .nonce_changes = &nonce_changes,
        .code_changes = &code_changes,
    }};
    try bal.validate(&claim, .{});

    var view = try ClaimView.initAssumeValidated(std.testing.allocator, &claim);
    defer view.deinit(std.testing.allocator);
    const base_storage = [_]TestStorage{
        .{ .key = 2, .value = 5 },
        .{ .key = 3, .value = 9 },
    };
    var base = TestBase{
        .target = target,
        .account = .{ .nonce = 1, .balance = 10, .code_hash = crypto.keccak256(&old_code) },
        .code = &old_code,
        .storage = &base_storage,
    };

    var before = BalClaimReader.init(base.reader(), &view, 0);
    const before_reader = before.reader();
    const before_account = (try before_reader.loadAccount(target)).?;
    try std.testing.expectEqual(@as(u64, 1), before_account.nonce);
    try std.testing.expectEqual(@as(u256, 10), before_account.balance);
    try std.testing.expectEqual(@as(u256, 5), try before_reader.getStorage(target, 2));
    try std.testing.expectEqual(@as(u256, 9), try before_reader.getStorage(target, 3));
    try std.testing.expectEqualSlices(u8, &old_code, try before_reader.loadCode(before_account.code_hash));

    var after_balance = BalClaimReader.init(base.reader(), &view, 1);
    const after_balance_reader = after_balance.reader();
    const middle_account = (try after_balance_reader.loadAccount(target)).?;
    try std.testing.expectEqual(@as(u64, 1), middle_account.nonce);
    try std.testing.expectEqual(@as(u256, 20), middle_account.balance);
    try std.testing.expectEqual(@as(u256, 7), try after_balance_reader.getStorage(target, 2));

    var after_all = BalClaimReader.init(base.reader(), &view, 2);
    const after_reader = after_all.reader();
    const after_account = (try after_reader.loadAccount(target)).?;
    try std.testing.expectEqual(@as(u64, 3), after_account.nonce);
    try std.testing.expectEqual(crypto.keccak256(&new_code), after_account.code_hash);
    try std.testing.expectEqualSlices(u8, &new_code, try after_reader.loadCode(after_account.code_hash));
}

test "BalClaimReader fails closed outside claim coverage" {
    const target = address.addr(1);
    const reads = [_]u256{3};
    const claim = [_]bal.AccountChanges{.{ .address = target, .storage_reads = &reads }};
    try bal.validate(&claim, .{});

    var view = try ClaimView.initAssumeValidated(std.testing.allocator, &claim);
    defer view.deinit(std.testing.allocator);
    var positioned = BalClaimReader.init(Reader.empty(), &view, 0);
    const state_reader = positioned.reader();

    try std.testing.expectError(
        error.BlockAccessListAccountNotCovered,
        state_reader.loadAccount(address.addr(2)),
    );
    try std.testing.expectError(
        error.BlockAccessListAccountNotCovered,
        state_reader.accountExists(address.addr(2)),
    );
    try std.testing.expectError(
        error.BlockAccessListStorageNotCovered,
        state_reader.getStorage(target, 4),
    );
    try std.testing.expectEqual(@as(u256, 0), try state_reader.getStorage(target, 3));
}

test "BalClaimReader preserves index-zero base presence and verifies delegated code" {
    const target = address.addr(1);
    const reads = [_]u256{3};
    const future_balance = [_]bal.BalanceChange{.{ .block_access_index = 2, .post_balance = 1 }};
    const claim = [_]bal.AccountChanges{.{
        .address = target,
        .storage_reads = &reads,
        .balance_changes = &future_balance,
    }};
    try bal.validate(&claim, .{});

    var view = try ClaimView.initAssumeValidated(std.testing.allocator, &claim);
    defer view.deinit(std.testing.allocator);
    const expected_code = [_]u8{0x00};
    const corrupt_code = [_]u8{0x01};
    const expected_hash = crypto.keccak256(&expected_code);
    var base = TestBase{
        .target = target,
        .account = .{},
        .code = &corrupt_code,
        .code_key = expected_hash,
    };
    var positioned = BalClaimReader.init(base.reader(), &view, 0);
    const state_reader = positioned.reader();

    try std.testing.expect(try state_reader.accountExists(target));
    try std.testing.expect((try state_reader.loadAccount(target)) != null);
    try std.testing.expectError(error.CodeHashMismatch, state_reader.loadCode(expected_hash));

    var later = BalClaimReader.init(base.reader(), &view, 1);
    try std.testing.expectError(error.PositionedAccountUnknown, later.reader().loadAccount(target));
    try std.testing.expectError(error.PositionedAccountUnknown, later.reader().accountExists(target));
    try std.testing.expectError(error.PositionedAccountUnknown, later.reader().getStorage(target, 3));
}

test "BalClaimReader storage presence is exact or explicitly unknown" {
    const target = address.addr(1);
    const clear_changes = [_]bal.StorageChange{.{ .block_access_index = 1, .new_value = 0 }};
    const set_changes = [_]bal.StorageChange{.{ .block_access_index = 1, .new_value = 12 }};
    const clear_only_slots = [_]bal.SlotChanges{.{ .slot = 1, .changes = &clear_changes }};
    const clear_and_set_slots = [_]bal.SlotChanges{
        .{ .slot = 1, .changes = &clear_changes },
        .{ .slot = 2, .changes = &set_changes },
    };
    const nonce_changes = [_]bal.NonceChange{.{ .block_access_index = 1, .new_nonce = 1 }};
    const clear_only_claim = [_]bal.AccountChanges{.{ .address = target, .storage_changes = &clear_only_slots }};
    const clear_and_set_claim = [_]bal.AccountChanges{.{
        .address = target,
        .storage_changes = &clear_and_set_slots,
        .nonce_changes = &nonce_changes,
    }};
    try bal.validate(&clear_only_claim, .{});
    try bal.validate(&clear_and_set_claim, .{});

    var clear_only_view = try ClaimView.initAssumeValidated(std.testing.allocator, &clear_only_claim);
    defer clear_only_view.deinit(std.testing.allocator);
    var clear_and_set_view = try ClaimView.initAssumeValidated(std.testing.allocator, &clear_and_set_claim);
    defer clear_and_set_view.deinit(std.testing.allocator);

    const base_storage = [_]TestStorage{
        .{ .key = 1, .value = 9 },
        .{ .key = 8, .value = 10 },
    };
    var base = TestBase{
        .target = target,
        .account = .{ .nonce = 1 },
        .storage = &base_storage,
    };

    var before_clear = BalClaimReader.init(base.reader(), &clear_only_view, 0);
    try std.testing.expectEqual(StoragePresence.nonempty, try before_clear.storagePresence(target));

    var after_clear = BalClaimReader.init(base.reader(), &clear_only_view, 1);
    try std.testing.expectEqual(StoragePresence.unknown, try after_clear.storagePresence(target));
    try std.testing.expectError(error.PositionedStorageUnknown, after_clear.reader().accountHasStorage(target));
    try std.testing.expect((try after_clear.reader().loadAccount(target)) != null);

    var after_clear_and_set = BalClaimReader.init(base.reader(), &clear_and_set_view, 1);
    try std.testing.expectEqual(StoragePresence.nonempty, try after_clear_and_set.storagePresence(target));
    try std.testing.expect(try after_clear_and_set.reader().accountExists(target));

    var empty_base = TestBase{ .target = target };
    var before_set = BalClaimReader.init(empty_base.reader(), &clear_and_set_view, 0);
    try std.testing.expectEqual(StoragePresence.empty, try before_set.storagePresence(target));
    try std.testing.expect(!(try before_set.reader().accountExists(target)));

    var after_set = BalClaimReader.init(empty_base.reader(), &clear_and_set_view, 1);
    try std.testing.expectEqual(StoragePresence.nonempty, try after_set.storagePresence(target));
    try std.testing.expect(try after_set.reader().accountExists(target));
}
