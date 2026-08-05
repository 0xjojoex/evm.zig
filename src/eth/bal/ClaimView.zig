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

pub const ReadSetEntry = union(enum) {
    account: Address,
    storage: StorageRead,
};

pub const InitError = Allocator.Error || delegation_code.DecodeError;

const CodeChange = struct {
    block_access_index: bal.BlockAccessIndex,
    code: Code,
};

const AccountView = struct {
    claim: *const bal.AccountChanges,
    code_changes: []const CodeChange,
};

accounts: []AccountView = &.{},
code_changes: []CodeChange = &.{},
code_by_hash: []*const CodeChange = &.{},

/// Construct over a claim already accepted by `bal.validate`.
pub fn initAssumeValidated(allocator: Allocator, block_access_list: bal.BlockAccessList) InitError!ClaimView {
    const accounts = try allocator.alloc(AccountView, block_access_list.len);
    errdefer allocator.free(accounts);

    var code_change_count: usize = 0;
    for (block_access_list) |account_claim| code_change_count += account_claim.code_changes.len;
    const code_changes = try allocator.alloc(CodeChange, code_change_count);
    errdefer allocator.free(code_changes);
    const code_by_hash = try allocator.alloc(*const CodeChange, code_change_count);
    errdefer allocator.free(code_by_hash);

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
        };
    }

    for (code_changes, 0..) |*change, index| code_by_hash[index] = change;
    std.mem.sort(*const CodeChange, code_by_hash, {}, codeHashLessThan);

    return .{
        .accounts = accounts,
        .code_changes = code_changes,
        .code_by_hash = code_by_hash,
    };
}

pub fn deinit(self: *ClaimView, allocator: Allocator) void {
    allocator.free(self.accounts);
    allocator.free(self.code_changes);
    allocator.free(self.code_by_hash);
    self.* = .{};
}

pub fn account(self: *const ClaimView, account_address: Address) ?AccountCursor {
    const account_index = self.findAccountIndex(account_address) orelse return null;
    return .{ .view = self, .account_index = account_index };
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

    fn accountView(self: AccountCursor) *const AccountView {
        return &self.view.accounts[self.account_index];
    }
};

/// Iterate the merged account/storage domain of a shape-validated claim
/// without importing positioned account fields or classifying code changes.
pub fn readSetAssumeValidated(block_access_list: bal.BlockAccessList) ReadSetIterator {
    return .{ .block_access_list = block_access_list };
}

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

    try std.testing.expect(view.account(account_address) != null);
    try std.testing.expect(view.account(address.addr(2)) == null);
    const account_cursor = view.account(account_address).?;
    try std.testing.expectEqual(StorageLookup.prestate, account_cursor.storageLookupAt(2, 0));
    try std.testing.expectEqualDeep(StorageLookup{ .value = 10 }, account_cursor.storageLookupAt(2, 1));
    try std.testing.expectEqualDeep(StorageLookup{ .value = 10 }, account_cursor.storageLookupAt(2, 2));
    try std.testing.expectEqualDeep(StorageLookup{ .value = 30 }, account_cursor.storageLookupAt(2, 3));
    try std.testing.expectEqual(StorageLookup.prestate, account_cursor.storageLookupAt(4, 3));
    try std.testing.expectEqual(StorageLookup.uncovered, account_cursor.storageLookupAt(3, 3));
    try std.testing.expectEqual(@as(?u256, null), account_cursor.balanceAt(1));
    try std.testing.expectEqual(@as(?u256, 20), account_cursor.balanceAt(2));
    try std.testing.expectEqual(@as(?u64, 7), account_cursor.nonceAt(0));

    const code = account_cursor.codeAt(3).?;
    try std.testing.expectEqualSlices(u8, &code_bytes, code.bytes);
    try std.testing.expectEqual(crypto.keccak256(&code_bytes), code.hash);
    try std.testing.expectEqual(@as(?Address, null), code.delegationTarget());
    try std.testing.expectEqualSlices(u8, &code_bytes, view.codeByHash(code.hash).?.bytes);
    try std.testing.expectEqual(@as(?Code, null), view.codeByHash([_]u8{0xff} ** 32));
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
    const code = view.account(address.addr(1)).?.codeAt(1).?;
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

    var iterator = readSetAssumeValidated(&claim);
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
            _ = view.account(address.addr(1)).?;
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Harness.run, .{});
}
