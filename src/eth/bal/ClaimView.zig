//! Indexed, read-only projection over a validated EIP-7928 claim.
//!
//! `ClaimView` borrows the claim and owns only lookup metadata plus classified,
//! hash-cached code changes. The claim must outlive the view and remain
//! immutable. Callers must validate canonical BAL shape before construction.

const std = @import("std");
const address = @import("../../address.zig");
const bal = @import("model.zig");
const delegation_code = @import("../../code/eip7702.zig");
const crypto = @import("../../crypto.zig");

const Allocator = std.mem.Allocator;
const ClaimView = @This();

pub const Address = address.Address;

pub const CodeKind = union(enum) {
    raw,
    delegation: Address,
};

pub const Code = struct {
    bytes: []const u8,
    hash: [32]u8,
    kind: CodeKind,

    pub fn delegationTarget(self: Code) ?Address {
        return switch (self.kind) {
            .raw => null,
            .delegation => |target| target,
        };
    }
};

pub const StorageRead = struct {
    address: Address,
    slot: u256,
};

pub const StorageLookup = union(enum) {
    uncovered,
    prestate,
    value: u256,
};

pub const PositionedStorageWrite = struct {
    slot: u256,
    value: u256,
};

pub const ReadSetEntry = union(enum) {
    account: Address,
    storage: StorageRead,
};

pub const FinalAccountFields = struct {
    address: Address,
    balance: ?u256 = null,
    nonce: ?u64 = null,
    code: ?Code = null,
};

pub const FinalStorageWrite = struct {
    address: Address,
    slot: u256,
    value: u256,
};

pub const InitError = Allocator.Error || delegation_code.DecodeError;

const CodeChange = struct {
    block_access_index: bal.BlockAccessIndex,
    code: Code,
};

const AccountView = struct {
    claim: *const bal.AccountChanges,
    code_changes: []const CodeChange,
    first_storage_change_index: ?bal.BlockAccessIndex,
};

accounts: []AccountView = &.{},
code_changes: []CodeChange = &.{},
code_by_hash: []*const CodeChange = &.{},
block_access_list: bal.BlockAccessList = &.{},

/// Construct over a claim already accepted by `bal.validate`.
pub fn initAssumeValidated(allocator: Allocator, block_access_list: bal.BlockAccessList) InitError!ClaimView {
    var accounts: []AccountView = &.{};
    if (block_access_list.len != 0) accounts = try allocator.alloc(AccountView, block_access_list.len);
    errdefer if (accounts.len != 0) allocator.free(accounts);

    var code_change_count: usize = 0;
    for (block_access_list) |account_claim| code_change_count += account_claim.code_changes.len;
    var code_changes: []CodeChange = &.{};
    if (code_change_count != 0) code_changes = try allocator.alloc(CodeChange, code_change_count);
    errdefer if (code_changes.len != 0) allocator.free(code_changes);
    var code_by_hash: []*const CodeChange = &.{};
    if (code_change_count != 0) code_by_hash = try allocator.alloc(*const CodeChange, code_change_count);
    errdefer if (code_by_hash.len != 0) allocator.free(code_by_hash);

    var code_index: usize = 0;
    for (block_access_list, 0..) |*account_claim, account_index| {
        const first_code_index = code_index;
        for (account_claim.code_changes) |change| {
            code_changes[code_index] = .{
                .block_access_index = change.block_access_index,
                .code = try decodeCode(change.new_code),
            };
            code_index += 1;
        }
        accounts[account_index] = .{
            .claim = account_claim,
            .code_changes = code_changes[first_code_index..code_index],
            .first_storage_change_index = firstStorageChangeIndex(account_claim.storage_changes),
        };
    }

    for (code_changes, 0..) |*change, index| code_by_hash[index] = change;
    std.mem.sort(*const CodeChange, code_by_hash, {}, codeHashLessThan);

    return .{
        .accounts = accounts,
        .code_changes = code_changes,
        .code_by_hash = code_by_hash,
        .block_access_list = block_access_list,
    };
}

pub fn deinit(self: *ClaimView, allocator: Allocator) void {
    if (self.accounts.len != 0) allocator.free(self.accounts);
    if (self.code_changes.len != 0) allocator.free(self.code_changes);
    if (self.code_by_hash.len != 0) allocator.free(self.code_by_hash);
    self.* = .{};
}

pub fn account(self: *const ClaimView, account_address: Address) ?AccountCursor {
    const account_index = self.findAccountIndex(account_address) orelse return null;
    return .{ .view = self, .account_index = account_index };
}

pub fn containsAccount(self: *const ClaimView, account_address: Address) bool {
    return self.account(account_address) != null;
}

pub fn containsStorage(self: *const ClaimView, account_address: Address, slot: u256) bool {
    const account_cursor = self.account(account_address) orelse return false;
    return account_cursor.storageLookupAt(slot, 0) != .uncovered;
}

/// Latest declared storage value whose block access index is at most `index`.
/// `null` means the claim has no applicable write; use `containsStorage` to
/// distinguish covered pre-state reads from uncovered slots.
pub fn storageAt(self: *const ClaimView, account_address: Address, slot: u256, index: bal.BlockAccessIndex) ?u256 {
    const account_cursor = self.account(account_address) orelse return null;
    return switch (account_cursor.storageLookupAt(slot, index)) {
        .value => |value| value,
        .uncovered, .prestate => null,
    };
}

pub fn balanceAt(self: *const ClaimView, account_address: Address, index: bal.BlockAccessIndex) ?u256 {
    const account_cursor = self.account(account_address) orelse return null;
    return account_cursor.balanceAt(index);
}

pub fn nonceAt(self: *const ClaimView, account_address: Address, index: bal.BlockAccessIndex) ?u64 {
    const account_cursor = self.account(account_address) orelse return null;
    return account_cursor.nonceAt(index);
}

pub fn codeAt(self: *const ClaimView, account_address: Address, index: bal.BlockAccessIndex) ?Code {
    const account_cursor = self.account(account_address) orelse return null;
    return account_cursor.codeAt(index);
}

/// Find code introduced anywhere in the claim by its cached content hash.
pub fn codeByHash(self: *const ClaimView, hash: [32]u8) ?Code {
    const index = std.sort.binarySearch(*const CodeChange, self.code_by_hash, hash, compareCodeHash) orelse return null;
    return self.code_by_hash[index].code;
}

pub const AccountCursor = struct {
    view: *const ClaimView,
    account_index: usize,

    pub fn storageLookupAt(self: AccountCursor, slot: u256, index: bal.BlockAccessIndex) StorageLookup {
        const account_view = self.accountView();
        if (findSlotChanges(account_view.claim.storage_changes, slot)) |slot_changes| {
            const change = latestChange(bal.StorageChange, slot_changes.changes, index) orelse return .prestate;
            return .{ .value = change.new_value };
        }
        if (containsSlot(account_view.claim.storage_reads, slot)) return .prestate;
        return .uncovered;
    }

    pub fn balanceAt(self: AccountCursor, index: bal.BlockAccessIndex) ?u256 {
        const change = latestChange(bal.BalanceChange, self.accountView().claim.balance_changes, index) orelse return null;
        return change.post_balance;
    }

    pub fn nonceAt(self: AccountCursor, index: bal.BlockAccessIndex) ?u64 {
        const change = latestChange(bal.NonceChange, self.accountView().claim.nonce_changes, index) orelse return null;
        return change.new_nonce;
    }

    pub fn codeAt(self: AccountCursor, index: bal.BlockAccessIndex) ?Code {
        const change = latestChange(CodeChange, self.accountView().code_changes, index) orelse return null;
        return change.code;
    }

    pub fn storageWritesAt(self: AccountCursor, index: bal.BlockAccessIndex) PositionedStorageWriteIterator {
        return .{
            .storage_changes = self.accountView().claim.storage_changes,
            .block_access_index = index,
        };
    }

    pub fn hasStorageWriteAt(self: AccountCursor, index: bal.BlockAccessIndex) bool {
        const first = self.accountView().first_storage_change_index orelse return false;
        return first <= index;
    }

    fn accountView(self: AccountCursor) *const AccountView {
        return &self.view.accounts[self.account_index];
    }
};

fn firstStorageChangeIndex(storage_changes: []const bal.SlotChanges) ?bal.BlockAccessIndex {
    var first: ?bal.BlockAccessIndex = null;
    for (storage_changes) |slot| {
        const index = slot.changes[0].block_access_index;
        first = if (first) |current| @min(current, index) else index;
    }
    return first;
}

pub const PositionedStorageWriteIterator = struct {
    storage_changes: []const bal.SlotChanges,
    block_access_index: bal.BlockAccessIndex,
    slot_index: usize = 0,

    pub fn next(self: *PositionedStorageWriteIterator) ?PositionedStorageWrite {
        while (self.slot_index < self.storage_changes.len) {
            const slot_changes = self.storage_changes[self.slot_index];
            self.slot_index += 1;
            const change = latestChange(bal.StorageChange, slot_changes.changes, self.block_access_index) orelse continue;
            return .{ .slot = slot_changes.slot, .value = change.new_value };
        }
        return null;
    }
};

pub fn readSet(self: *const ClaimView) ReadSetIterator {
    return readSetAssumeValidated(self.block_access_list);
}

/// Iterate the merged account/storage domain of a shape-validated claim
/// without importing positioned account fields or classifying code changes.
pub fn readSetAssumeValidated(block_access_list: bal.BlockAccessList) ReadSetIterator {
    return .{ .block_access_list = block_access_list };
}

/// Zero-allocation final field projection, not `state.Changeset`.
///
/// BAL account changes are field-partial, so completing an account update or
/// deciding account deletion still requires authenticated pre-state and final
/// storage-root truth. Code bytes remain borrowed from the source claim.
pub fn finalDelta(self: *const ClaimView) FinalDelta {
    return .{ .view = self };
}

/// Zero-allocation projection of writes attributed to transaction indices
/// `1...transaction_count`. Index-zero setup and post-transaction system writes
/// are excluded because the detached transaction fold does not own them.
pub fn transactionDelta(self: *const ClaimView, transaction_count: bal.BlockAccessIndex) TransactionDelta {
    return .{ .view = self, .transaction_count = transaction_count };
}

pub const TransactionDelta = struct {
    view: *const ClaimView,
    transaction_count: bal.BlockAccessIndex,

    pub fn accountFields(self: TransactionDelta) TransactionAccountFieldsIterator {
        return .{ .view = self.view, .transaction_count = self.transaction_count };
    }

    pub fn storageWrites(self: TransactionDelta) TransactionStorageWriteIterator {
        return .{ .view = self.view, .transaction_count = self.transaction_count };
    }
};

pub const TransactionAccountFieldsIterator = struct {
    view: *const ClaimView,
    transaction_count: bal.BlockAccessIndex,
    account_index: usize = 0,

    pub fn next(self: *TransactionAccountFieldsIterator) ?FinalAccountFields {
        while (self.account_index < self.view.accounts.len) {
            const account_view = self.view.accounts[self.account_index];
            self.account_index += 1;
            const account_claim = account_view.claim;
            const balance_change = latestTransactionChange(bal.BalanceChange, account_claim.balance_changes, self.transaction_count);
            const nonce_change = latestTransactionChange(bal.NonceChange, account_claim.nonce_changes, self.transaction_count);
            const code_change = latestTransactionChange(CodeChange, account_view.code_changes, self.transaction_count);
            if (balance_change == null and nonce_change == null and code_change == null) continue;
            return .{
                .address = account_claim.address,
                .balance = if (balance_change) |change| change.post_balance else null,
                .nonce = if (nonce_change) |change| change.new_nonce else null,
                .code = if (code_change) |change| change.code else null,
            };
        }
        return null;
    }
};

pub const TransactionStorageWriteIterator = struct {
    view: *const ClaimView,
    transaction_count: bal.BlockAccessIndex,
    account_index: usize = 0,
    slot_index: usize = 0,

    pub fn next(self: *TransactionStorageWriteIterator) ?FinalStorageWrite {
        while (self.account_index < self.view.accounts.len) {
            const account_claim = self.view.accounts[self.account_index].claim;
            while (self.slot_index < account_claim.storage_changes.len) {
                const slot_changes = account_claim.storage_changes[self.slot_index];
                self.slot_index += 1;
                const change = latestTransactionChange(
                    bal.StorageChange,
                    slot_changes.changes,
                    self.transaction_count,
                ) orelse continue;
                return .{
                    .address = account_claim.address,
                    .slot = slot_changes.slot,
                    .value = change.new_value,
                };
            }
            self.account_index += 1;
            self.slot_index = 0;
        }
        return null;
    }
};

pub const FinalDelta = struct {
    view: *const ClaimView,

    pub fn accountFields(self: FinalDelta) FinalAccountFieldsIterator {
        return .{ .view = self.view };
    }

    pub fn storageWrites(self: FinalDelta) FinalStorageWriteIterator {
        return .{ .view = self.view };
    }
};

pub const FinalAccountFieldsIterator = struct {
    view: *const ClaimView,
    account_index: usize = 0,

    pub fn next(self: *FinalAccountFieldsIterator) ?FinalAccountFields {
        while (self.account_index < self.view.accounts.len) {
            const account_view = self.view.accounts[self.account_index];
            self.account_index += 1;
            const account_claim = account_view.claim;
            if (!hasAccountFieldChanges(account_claim)) continue;
            return .{
                .address = account_claim.address,
                .balance = if (account_claim.balance_changes.len != 0)
                    account_claim.balance_changes[account_claim.balance_changes.len - 1].post_balance
                else
                    null,
                .nonce = if (account_claim.nonce_changes.len != 0)
                    account_claim.nonce_changes[account_claim.nonce_changes.len - 1].new_nonce
                else
                    null,
                .code = if (account_view.code_changes.len != 0)
                    account_view.code_changes[account_view.code_changes.len - 1].code
                else
                    null,
            };
        }
        return null;
    }
};

pub const FinalStorageWriteIterator = struct {
    view: *const ClaimView,
    account_index: usize = 0,
    slot_index: usize = 0,

    pub fn next(self: *FinalStorageWriteIterator) ?FinalStorageWrite {
        while (self.account_index < self.view.accounts.len) {
            const account_claim = self.view.accounts[self.account_index].claim;
            if (self.slot_index < account_claim.storage_changes.len) {
                const slot_changes = account_claim.storage_changes[self.slot_index];
                self.slot_index += 1;
                return .{
                    .address = account_claim.address,
                    .slot = slot_changes.slot,
                    .value = slot_changes.changes[slot_changes.changes.len - 1].new_value,
                };
            }
            self.account_index += 1;
            self.slot_index = 0;
        }
        return null;
    }
};

pub const ReadSetIterator = struct {
    block_access_list: bal.BlockAccessList,
    account_index: usize = 0,
    emitted_account: bool = false,
    storage_change_index: usize = 0,
    storage_read_index: usize = 0,

    pub fn next(self: *ReadSetIterator) ?ReadSetEntry {
        while (self.account_index < self.block_access_list.len) {
            const account_claim = &self.block_access_list[self.account_index];
            if (!self.emitted_account) {
                self.emitted_account = true;
                return .{ .account = account_claim.address };
            }

            const has_change = self.storage_change_index < account_claim.storage_changes.len;
            const has_read = self.storage_read_index < account_claim.storage_reads.len;
            if (has_change or has_read) {
                const slot = if (!has_read or
                    (has_change and account_claim.storage_changes[self.storage_change_index].slot < account_claim.storage_reads[self.storage_read_index]))
                slot: {
                    const value = account_claim.storage_changes[self.storage_change_index].slot;
                    self.storage_change_index += 1;
                    break :slot value;
                } else slot: {
                    const value = account_claim.storage_reads[self.storage_read_index];
                    self.storage_read_index += 1;
                    break :slot value;
                };
                return .{ .storage = .{ .address = account_claim.address, .slot = slot } };
            }

            self.account_index += 1;
            self.emitted_account = false;
            self.storage_change_index = 0;
            self.storage_read_index = 0;
        }
        return null;
    }
};

fn findAccountIndex(self: *const ClaimView, account_address: Address) ?usize {
    return std.sort.binarySearch(AccountView, self.accounts, account_address, compareAccount);
}

fn findSlotChanges(changes: []const bal.SlotChanges, slot: u256) ?*const bal.SlotChanges {
    const index = std.sort.binarySearch(bal.SlotChanges, changes, slot, compareSlotChanges) orelse return null;
    return &changes[index];
}

fn containsSlot(slots: []const u256, slot: u256) bool {
    return std.sort.binarySearch(u256, slots, slot, compareSlot) != null;
}

fn latestChange(comptime Change: type, changes: []const Change, index: bal.BlockAccessIndex) ?*const Change {
    const after = std.sort.upperBound(Change, changes, index, struct {
        fn compare(context: bal.BlockAccessIndex, item: Change) std.math.Order {
            return std.math.order(context, item.block_access_index);
        }
    }.compare);
    return if (after == 0) null else &changes[after - 1];
}

fn latestTransactionChange(
    comptime Change: type,
    changes: []const Change,
    transaction_count: bal.BlockAccessIndex,
) ?*const Change {
    if (transaction_count == 0) return null;
    const change = latestChange(Change, changes, transaction_count) orelse return null;
    return if (change.block_access_index == 0) null else change;
}

fn decodeCode(bytes: []const u8) InitError!Code {
    const target = try delegation_code.decodeDelegation(bytes);

    return .{
        .bytes = bytes,
        .hash = crypto.keccak256(bytes),
        .kind = if (target) |value| .{ .delegation = value } else .raw,
    };
}

fn compareAccount(context: Address, item: AccountView) std.math.Order {
    return std.mem.order(u8, &context, &item.claim.address);
}

fn compareSlotChanges(context: u256, item: bal.SlotChanges) std.math.Order {
    return compareSlot(context, item.slot);
}

fn compareSlot(context: u256, item: u256) std.math.Order {
    if (context < item) return .lt;
    if (context > item) return .gt;
    return .eq;
}

fn codeHashLessThan(_: void, left: *const CodeChange, right: *const CodeChange) bool {
    return std.mem.order(u8, &left.code.hash, &right.code.hash) == .lt;
}

fn compareCodeHash(context: [32]u8, item: *const CodeChange) std.math.Order {
    return std.mem.order(u8, &context, &item.code.hash);
}

fn hasAccountFieldChanges(account_claim: *const bal.AccountChanges) bool {
    return account_claim.balance_changes.len != 0 or
        account_claim.nonce_changes.len != 0 or
        account_claim.code_changes.len != 0;
}

test "ClaimView resolves latest declared values and coverage" {
    const account_address = address.addr(1);
    const storage_changes = [_]bal.StorageChange{
        .{ .block_access_index = 1, .new_value = 10 },
        .{ .block_access_index = 3, .new_value = 30 },
    };
    const slots = [_]bal.SlotChanges{.{ .slot = 2, .changes = &storage_changes }};
    const storage_reads = [_]u256{4};
    const balance_changes = [_]bal.BalanceChange{.{ .block_access_index = 2, .post_balance = 20 }};
    const nonce_changes = [_]bal.NonceChange{.{ .block_access_index = 0, .new_nonce = 7 }};
    const code_bytes = [_]u8{ 0x60, 0x00 };
    const code_changes = [_]bal.CodeChange{.{ .block_access_index = 3, .new_code = &code_bytes }};
    const claim = [_]bal.AccountChanges{.{
        .address = account_address,
        .storage_changes = &slots,
        .storage_reads = &storage_reads,
        .balance_changes = &balance_changes,
        .nonce_changes = &nonce_changes,
        .code_changes = &code_changes,
    }};
    try bal.validate(&claim, .{});

    var view = try ClaimView.initAssumeValidated(std.testing.allocator, &claim);
    defer view.deinit(std.testing.allocator);

    try std.testing.expect(view.containsAccount(account_address));
    try std.testing.expect(!view.containsAccount(address.addr(2)));
    try std.testing.expect(view.containsStorage(account_address, 2));
    try std.testing.expect(view.containsStorage(account_address, 4));
    try std.testing.expect(!view.containsStorage(account_address, 3));
    try std.testing.expectEqual(@as(?u256, null), view.storageAt(account_address, 2, 0));
    try std.testing.expectEqual(@as(?u256, 10), view.storageAt(account_address, 2, 1));
    try std.testing.expectEqual(@as(?u256, 10), view.storageAt(account_address, 2, 2));
    try std.testing.expectEqual(@as(?u256, 30), view.storageAt(account_address, 2, 3));
    try std.testing.expectEqual(@as(?u256, null), view.storageAt(account_address, 4, 3));
    try std.testing.expectEqual(@as(?u256, null), view.balanceAt(account_address, 1));
    try std.testing.expectEqual(@as(?u256, 20), view.balanceAt(account_address, 2));
    try std.testing.expectEqual(@as(?u64, 7), view.nonceAt(account_address, 0));

    const code = view.codeAt(account_address, 3).?;
    try std.testing.expectEqualSlices(u8, &code_bytes, code.bytes);
    try std.testing.expectEqual(crypto.keccak256(&code_bytes), code.hash);
    try std.testing.expectEqual(@as(?Address, null), code.delegationTarget());
    try std.testing.expectEqualSlices(u8, &code_bytes, view.codeByHash(code.hash).?.bytes);
    try std.testing.expectEqual(@as(?Code, null), view.codeByHash([_]u8{0xff} ** 32));

    const account_cursor = view.account(account_address).?;
    try std.testing.expectEqual(StorageLookup.prestate, account_cursor.storageLookupAt(2, 0));
    try std.testing.expectEqualDeep(StorageLookup{ .value = 10 }, account_cursor.storageLookupAt(2, 1));
    try std.testing.expectEqual(StorageLookup.uncovered, account_cursor.storageLookupAt(3, 3));
    var positioned_writes = account_cursor.storageWritesAt(2);
    try std.testing.expectEqualDeep(PositionedStorageWrite{ .slot = 2, .value = 10 }, positioned_writes.next().?);
    try std.testing.expectEqual(@as(?PositionedStorageWrite, null), positioned_writes.next());
}

test "ClaimView imports EIP-7702 code strictly and caches its target" {
    const malformed_length = [_]u8{ 0xef, 0x01, 0x00 };
    const malformed_length_changes = [_]bal.CodeChange{.{ .block_access_index = 1, .new_code = &malformed_length }};
    const malformed_length_claim = [_]bal.AccountChanges{.{
        .address = address.addr(1),
        .code_changes = &malformed_length_changes,
    }};
    try std.testing.expectError(
        error.InvalidDelegationLength,
        ClaimView.initAssumeValidated(std.testing.allocator, &malformed_length_claim),
    );

    var unsupported_version = [_]u8{0} ** delegation_code.delegation_code_len;
    unsupported_version[0] = 0xef;
    unsupported_version[1] = 0x01;
    unsupported_version[2] = 0x01;
    const unsupported_version_changes = [_]bal.CodeChange{.{ .block_access_index = 1, .new_code = &unsupported_version }};
    const unsupported_version_claim = [_]bal.AccountChanges{.{
        .address = address.addr(1),
        .code_changes = &unsupported_version_changes,
    }};
    try std.testing.expectError(
        error.UnsupportedDelegationVersion,
        ClaimView.initAssumeValidated(std.testing.allocator, &unsupported_version_claim),
    );

    const target = address.addr(0x1234);
    var delegation = [_]u8{0} ** delegation_code.delegation_code_len;
    delegation_code.writeDelegationCode(&delegation, target);
    const delegation_changes = [_]bal.CodeChange{.{ .block_access_index = 1, .new_code = &delegation }};
    const claim = [_]bal.AccountChanges{.{
        .address = address.addr(1),
        .code_changes = &delegation_changes,
    }};

    var view = try ClaimView.initAssumeValidated(std.testing.allocator, &claim);
    defer view.deinit(std.testing.allocator);
    const code = view.codeAt(address.addr(1), 1).?;
    try std.testing.expectEqual(target, code.delegationTarget().?);
    try std.testing.expectEqual(crypto.keccak256(&delegation), code.hash);
}

test "ClaimView readSet merges canonical account and storage coverage" {
    const first_storage_changes = [_]bal.StorageChange{.{ .block_access_index = 1, .new_value = 10 }};
    const first_slots = [_]bal.SlotChanges{
        .{ .slot = 1, .changes = &first_storage_changes },
        .{ .slot = 5, .changes = &first_storage_changes },
    };
    const first_reads = [_]u256{ 2, 4 };
    const second_reads = [_]u256{7};
    const claim = [_]bal.AccountChanges{
        .{
            .address = address.addr(1),
            .storage_changes = &first_slots,
            .storage_reads = &first_reads,
        },
        .{
            .address = address.addr(2),
            .storage_reads = &second_reads,
        },
    };
    try bal.validate(&claim, .{});

    var view = try ClaimView.initAssumeValidated(std.testing.allocator, &claim);
    defer view.deinit(std.testing.allocator);
    var iterator = view.readSet();
    const expected = [_]ReadSetEntry{
        .{ .account = address.addr(1) },
        .{ .storage = .{ .address = address.addr(1), .slot = 1 } },
        .{ .storage = .{ .address = address.addr(1), .slot = 2 } },
        .{ .storage = .{ .address = address.addr(1), .slot = 4 } },
        .{ .storage = .{ .address = address.addr(1), .slot = 5 } },
        .{ .account = address.addr(2) },
        .{ .storage = .{ .address = address.addr(2), .slot = 7 } },
    };
    for (expected) |entry| try std.testing.expectEqualDeep(entry, iterator.next().?);
    try std.testing.expectEqual(@as(?ReadSetEntry, null), iterator.next());
}

test "ClaimView finalDelta iterates only final claim-native field values" {
    const first_storage_changes = [_]bal.StorageChange{
        .{ .block_access_index = 1, .new_value = 10 },
        .{ .block_access_index = 2, .new_value = 20 },
    };
    const second_storage_changes = [_]bal.StorageChange{.{ .block_access_index = 2, .new_value = 30 }};
    const first_slots = [_]bal.SlotChanges{
        .{ .slot = 1, .changes = &first_storage_changes },
        .{ .slot = 2, .changes = &second_storage_changes },
    };
    const balance_changes = [_]bal.BalanceChange{
        .{ .block_access_index = 1, .post_balance = 10 },
        .{ .block_access_index = 2, .post_balance = 20 },
        .{ .block_access_index = 3, .post_balance = 30 },
    };
    const nonce_changes = [_]bal.NonceChange{.{ .block_access_index = 0, .new_nonce = 7 }};
    const second_slots = [_]bal.SlotChanges{.{ .slot = 3, .changes = &second_storage_changes }};
    const claim = [_]bal.AccountChanges{
        .{
            .address = address.addr(1),
            .storage_changes = &first_slots,
            .balance_changes = &balance_changes,
            .nonce_changes = &nonce_changes,
        },
        .{
            .address = address.addr(2),
            .storage_changes = &second_slots,
        },
    };
    try bal.validate(&claim, .{});

    var view = try ClaimView.initAssumeValidated(std.testing.allocator, &claim);
    defer view.deinit(std.testing.allocator);
    const final = view.finalDelta();
    var account_fields = final.accountFields();
    const first_account = account_fields.next().?;
    try std.testing.expectEqual(address.addr(1), first_account.address);
    try std.testing.expectEqual(@as(?u256, 30), first_account.balance);
    try std.testing.expectEqual(@as(?u64, 7), first_account.nonce);
    try std.testing.expectEqual(@as(?FinalAccountFields, null), account_fields.next());

    var storage_writes = final.storageWrites();
    try std.testing.expectEqualDeep(
        FinalStorageWrite{ .address = address.addr(1), .slot = 1, .value = 20 },
        storage_writes.next().?,
    );
    try std.testing.expectEqualDeep(
        FinalStorageWrite{ .address = address.addr(1), .slot = 2, .value = 30 },
        storage_writes.next().?,
    );
    try std.testing.expectEqualDeep(
        FinalStorageWrite{ .address = address.addr(2), .slot = 3, .value = 30 },
        storage_writes.next().?,
    );
    try std.testing.expectEqual(@as(?FinalStorageWrite, null), storage_writes.next());

    const first_transaction = view.transactionDelta(1);
    var transaction_accounts = first_transaction.accountFields();
    try std.testing.expectEqualDeep(
        FinalAccountFields{ .address = address.addr(1), .balance = 10 },
        transaction_accounts.next().?,
    );
    try std.testing.expectEqual(@as(?FinalAccountFields, null), transaction_accounts.next());
    var transaction_storage = first_transaction.storageWrites();
    try std.testing.expectEqualDeep(
        FinalStorageWrite{ .address = address.addr(1), .slot = 1, .value = 10 },
        transaction_storage.next().?,
    );
    try std.testing.expectEqual(@as(?FinalStorageWrite, null), transaction_storage.next());

    var no_transactions = view.transactionDelta(0).accountFields();
    try std.testing.expectEqual(@as(?FinalAccountFields, null), no_transactions.next());
}

test "ClaimView cleans every allocation failure position" {
    const Harness = struct {
        fn run(allocator: Allocator) !void {
            const storage_changes = [_]bal.StorageChange{.{ .block_access_index = 1, .new_value = 10 }};
            const slots = [_]bal.SlotChanges{.{ .slot = 1, .changes = &storage_changes }};
            const code_bytes = [_]u8{0x00};
            const code_changes = [_]bal.CodeChange{.{ .block_access_index = 1, .new_code = &code_bytes }};
            const claim = [_]bal.AccountChanges{.{
                .address = address.addr(1),
                .storage_changes = &slots,
                .code_changes = &code_changes,
            }};
            var view = try ClaimView.initAssumeValidated(allocator, &claim);
            defer view.deinit(allocator);
            _ = view.finalDelta();
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Harness.run, .{});
}
