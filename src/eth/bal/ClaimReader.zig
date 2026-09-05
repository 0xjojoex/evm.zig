//! Positioned `StateReader` adapter over a validated EIP-7928 claim.
//!
//! Covered account and storage reads see the latest claim value at or before
//! `block_access_index`, falling back to authenticated pre-state when no claim
//! write applies yet. Reads outside claim coverage fail closed.
//!
//! Positioned fields are exactly parent state overridden by the latest claim
//! post-value at or before the index. Presence follows EIP-161 aliveness -
//! nonzero nonce, nonzero balance, or non-empty code - because from Amsterdam
//! no legacy empty account survives and none can be created. `EXTCODEHASH` and
//! `EXTCODESIZE` already treat absent and EIP-161-empty accounts identically,
//! so the claim never needs an indexed lifecycle fact to separate them.
//!
//! This lane is speculative: its output is gated by the observed BAL hash
//! matching the claimed BAL commitment and by the block's roots. A claim that
//! violates these Amsterdam invariants can only produce a mismatch, never a
//! false accept.

const std = @import("std");

const address = @import("../../address.zig");
const bal = @import("./model.zig");
const ClaimView = @import("./ClaimView.zig");
const crypto = @import("../../crypto.zig");
const Account = @import("../../state/Account.zig");
const Reader = @import("../../state/Reader.zig");

const Address = address.Address;
const ClaimReader = @This();

pub const Error = error{
    BlockAccessListAccountNotCovered,
    BlockAccessListStorageNotCovered,
};

/// Detailed cause retained beside the generic executor strategy failure.
pub const StrategyFailure = enum {
    account_not_covered,
    storage_not_covered,
};

base: Reader,
claim: *const ClaimView,
block_access_index: bal.BlockAccessIndex,
strategy_failure: ?StrategyFailure = null,

pub fn init(base: Reader, claim: *const ClaimView, block_access_index: bal.BlockAccessIndex) ClaimReader {
    return .{
        .base = base,
        .claim = claim,
        .block_access_index = block_access_index,
    };
}

pub fn reader(self: *ClaimReader) Reader {
    return .{ .ptr = self, .vtable = &vtable };
}

const vtable = Reader.VTable{
    .loadAccount = loadAccount,
    .loadCode = loadCode,
    .getStorage = getStorage,
};

fn context(ptr: *anyopaque) *ClaimReader {
    return @ptrCast(@alignCast(ptr));
}

fn loadAccount(ptr: *anyopaque, target: Address) !?Account {
    return loadPositionedAccount(context(ptr), target);
}

fn loadPositionedAccount(self: *ClaimReader, target: Address) !?Account {
    const account_cursor = self.claim.account(target) orelse return self.fail(.account_not_covered);
    return self.loadPositionedAccountFor(target, account_cursor);
}

fn loadPositionedAccountFor(self: *ClaimReader, target: Address, account_cursor: ClaimView.AccountCursor) !?Account {
    const balance = account_cursor.balanceAt(self.block_access_index);
    const nonce = account_cursor.nonceAt(self.block_access_index);
    const code = account_cursor.codeAt(self.block_access_index);

    const base_account = if (balance != null and nonce != null and code != null)
        null
    else
        try self.base.loadAccount(target);
    var positioned_account = base_account orelse Account{};
    if (balance) |value| positioned_account.balance = value;
    if (nonce) |value| positioned_account.nonce = value;
    if (code) |value| positioned_account.code_hash = value.hash;

    // EIP-161 emptiness is the whole rule, and storage plays no part in it. It
    // holds whether the claim drove the fields to zero or parent state was
    // already that way, because the executor resolves an empty account to
    // absent on every fork that has no empty accounts.
    return if (accountAlive(positioned_account)) positioned_account else null;
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

fn fail(self: *ClaimReader, failure: StrategyFailure) Error {
    self.strategy_failure = failure;
    return switch (failure) {
        .account_not_covered => error.BlockAccessListAccountNotCovered,
        .storage_not_covered => error.BlockAccessListStorageNotCovered,
    };
}

fn accountAlive(account: Account) bool {
    return account.nonce != 0 or
        account.balance != 0 or
        !std.mem.eql(u8, &account.code_hash, &crypto.keccak256_empty);
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
            .loadAccount = testLoadAccount,
            .loadCode = testLoadCode,
            .getStorage = testGetStorage,
        } };
    }

    fn from(ptr: *anyopaque) *TestBase {
        return @ptrCast(@alignCast(ptr));
    }

    fn testLoadAccount(ptr: *anyopaque, target: Address) !?Account {
        const self = from(ptr);
        if (!Address.eql(self.target, target)) return null;
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
        if (!Address.eql(self.target, target)) return 0;
        for (self.storage) |entry| {
            if (entry.key == key) return entry.value;
        }
        return 0;
    }
};

test "ClaimReader resolves positioned account code and storage" {
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

    var before = ClaimReader.init(base.reader(), &view, 0);
    const before_reader = before.reader();
    const before_account = (try before_reader.loadAccount(target)).?;
    try std.testing.expectEqual(@as(u64, 1), before_account.nonce);
    try std.testing.expectEqual(@as(u256, 10), before_account.balance);
    try std.testing.expectEqual(@as(u256, 5), try before_reader.getStorage(target, 2));
    try std.testing.expectEqual(@as(u256, 9), try before_reader.getStorage(target, 3));
    try std.testing.expectEqualSlices(u8, &old_code, try before_reader.loadCode(before_account.code_hash));

    var after_balance = ClaimReader.init(base.reader(), &view, 1);
    const after_balance_reader = after_balance.reader();
    const middle_account = (try after_balance_reader.loadAccount(target)).?;
    try std.testing.expectEqual(@as(u64, 1), middle_account.nonce);
    try std.testing.expectEqual(@as(u256, 20), middle_account.balance);
    try std.testing.expectEqual(@as(u256, 7), try after_balance_reader.getStorage(target, 2));

    var after_all = ClaimReader.init(base.reader(), &view, 2);
    const after_reader = after_all.reader();
    const after_account = (try after_reader.loadAccount(target)).?;
    try std.testing.expectEqual(@as(u64, 3), after_account.nonce);
    try std.testing.expectEqual(crypto.keccak256(&new_code), after_account.code_hash);
    try std.testing.expectEqualSlices(u8, &new_code, try after_reader.loadCode(after_account.code_hash));
}

test "ClaimReader fails closed outside claim coverage" {
    const target = address.addr(1);
    const reads = [_]u256{3};
    const claim = [_]bal.AccountChanges{.{ .address = target, .storage_reads = &reads }};
    try bal.validate(&claim, .{});

    var view = try ClaimView.initAssumeValidated(std.testing.allocator, &claim);
    defer view.deinit(std.testing.allocator);
    var positioned = ClaimReader.init(Reader.empty(), &view, 0);
    const state_reader = positioned.reader();

    try std.testing.expectError(
        error.BlockAccessListAccountNotCovered,
        state_reader.loadAccount(address.addr(2)),
    );
    try std.testing.expectError(
        error.BlockAccessListStorageNotCovered,
        state_reader.getStorage(target, 4),
    );
    try std.testing.expectEqual(@as(u256, 0), try state_reader.getStorage(target, 3));
}

test "ClaimReader keeps an untouched base leaf and verifies delegated code" {
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
        .account = .{ .balance = 5 },
        .code = &corrupt_code,
        .code_key = expected_hash,
    };
    var positioned = ClaimReader.init(base.reader(), &view, 0);
    const state_reader = positioned.reader();

    try std.testing.expectEqual(@as(u256, 5), (try state_reader.loadAccount(target)).?.balance);
    try std.testing.expectError(error.CodeHashMismatch, state_reader.loadCode(expected_hash));

    // No claim field applies before index 2, so the base leaf stays visible
    // instead of becoming an unresolvable lifecycle question.
    var later = ClaimReader.init(base.reader(), &view, 1);
    try std.testing.expectEqual(@as(u256, 5), (try later.reader().loadAccount(target)).?.balance);
    try std.testing.expectEqual(@as(u256, 0), try later.reader().getStorage(target, 3));
}

test "ClaimReader resolves an emptied account to absent" {
    const target = address.addr(1);
    const balance_changes = [_]bal.BalanceChange{.{ .block_access_index = 1, .post_balance = 0 }};
    const nonce_changes = [_]bal.NonceChange{.{ .block_access_index = 1, .new_nonce = 0 }};
    const code_changes = [_]bal.CodeChange{.{ .block_access_index = 1, .new_code = &.{} }};
    const claim = [_]bal.AccountChanges{.{
        .address = target,
        .balance_changes = &balance_changes,
        .nonce_changes = &nonce_changes,
        .code_changes = &code_changes,
    }};
    try bal.validate(&claim, .{});

    var view = try ClaimView.initAssumeValidated(std.testing.allocator, &claim);
    defer view.deinit(std.testing.allocator);
    var base = TestBase{
        .target = target,
        .account = .{ .nonce = 3, .balance = 10 },
    };

    var before = ClaimReader.init(base.reader(), &view, 0);
    try std.testing.expect((try before.reader().loadAccount(target)) != null);

    var after = ClaimReader.init(base.reader(), &view, 1);
    try std.testing.expectEqual(@as(?Account, null), try after.reader().loadAccount(target));
}

test "ClaimReader resolves an untouched empty leaf to absent" {
    const target = address.addr(1);
    const reads = [_]u256{3};
    const claim = [_]bal.AccountChanges{.{ .address = target, .storage_reads = &reads }};
    try bal.validate(&claim, .{});

    var view = try ClaimView.initAssumeValidated(std.testing.allocator, &claim);
    defer view.deinit(std.testing.allocator);

    // A seeded EIP-161-empty leaf reads as absent here for the same reason it
    // does through `OpenWorld`: from Spurious Dragon on there is no such
    // account. The two must agree, because `account_exists` drives new-account
    // gas and a disagreement would surface as a lane mismatch on gas alone.
    var empty_leaf = TestBase{ .target = target, .account = .{} };
    var over_empty = ClaimReader.init(empty_leaf.reader(), &view, 1);
    try std.testing.expectEqual(@as(?Account, null), try over_empty.reader().loadAccount(target));

    var absent = TestBase{ .target = target };
    var over_absent = ClaimReader.init(absent.reader(), &view, 1);
    try std.testing.expectEqual(@as(?Account, null), try over_absent.reader().loadAccount(target));
}
