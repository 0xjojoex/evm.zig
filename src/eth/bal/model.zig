//! EIP-7928 Block-Level Access List model and canonical RLP form.

const std = @import("std");
const address = @import("../../address.zig");
const crypto = @import("../../crypto.zig");
const rlp = @import("rlp");
const t = @import("../../t.zig");

const Allocator = std.mem.Allocator;

pub const Address = address.Address;
pub const BlockAccessIndex = u32;
pub const item_cost: u64 = 2_000;

/// keccak256(rlp.encode([]))
pub const empty_hash = [_]u8{
    0x1d, 0xcc, 0x4d, 0xe8, 0xde, 0xc7, 0x5d, 0x7a,
    0xab, 0x85, 0xb5, 0x67, 0xb6, 0xcc, 0xd4, 0x1a,
    0xd3, 0x12, 0x45, 0x1b, 0x94, 0x8a, 0x74, 0x13,
    0xf0, 0xa1, 0x42, 0xfd, 0x40, 0xd4, 0x93, 0x47,
};

pub const StorageChange = struct {
    block_access_index: BlockAccessIndex,
    new_value: u256,
};

pub const BalanceChange = struct {
    block_access_index: BlockAccessIndex,
    post_balance: u256,
};

pub const NonceChange = struct {
    block_access_index: BlockAccessIndex,
    new_nonce: u64,
};

pub const CodeChange = struct {
    block_access_index: BlockAccessIndex,
    new_code: []const u8,
};

pub const SlotChanges = struct {
    slot: u256,
    changes: []const StorageChange,
};

pub const AccountChanges = struct {
    address: Address,
    storage_changes: []const SlotChanges = &.{},
    storage_reads: []const u256 = &.{},
    balance_changes: []const BalanceChange = &.{},
    nonce_changes: []const NonceChange = &.{},
    code_changes: []const CodeChange = &.{},
};

pub const BlockAccessList = []const AccountChanges;
const max_rlp_depth: usize = 6;

pub const ValidationOptions = struct {
    transaction_count: ?BlockAccessIndex = null,
};

pub const ValidationError = error{
    AccountsOutOfOrder,
    DuplicateAccount,
    StorageChangesOutOfOrder,
    DuplicateStorageChangeSlot,
    EmptySlotChanges,
    StorageChangeIndicesOutOfOrder,
    DuplicateStorageChangeIndex,
    StorageReadsOutOfOrder,
    DuplicateStorageRead,
    StorageReadAlsoWritten,
    BalanceChangeIndicesOutOfOrder,
    DuplicateBalanceChangeIndex,
    NonceChangeIndicesOutOfOrder,
    DuplicateNonceChangeIndex,
    CodeChangeIndicesOutOfOrder,
    DuplicateCodeChangeIndex,
    BlockAccessIndexOutOfRange,
    BlockAccessListGasLimitExceeded,
};

pub const Counts = struct {
    accounts: usize = 0,
    storage_read_keys: usize = 0,
    storage_write_keys: usize = 0,
    storage_write_changes: usize = 0,
    balance_changes: usize = 0,
    nonce_changes: usize = 0,
    code_changes: usize = 0,
    code_bytes: usize = 0,
    max_block_access_index: ?BlockAccessIndex = null,

    pub fn blockAccessItems(self: Counts) usize {
        return self.accounts + self.storage_read_keys + self.storage_write_keys;
    }
};

pub const IndexResources = struct {
    block_access_index: BlockAccessIndex,
    storage_write_keys: usize = 0,
    changed_accounts: usize = 0,
};

pub const IndexResourceMaxima = struct {
    storage_write_keys: usize = 0,
    changed_accounts: usize = 0,
};

pub const IndexResourcePlan = struct {
    resources: []IndexResources = &.{},

    pub fn deinit(self: *IndexResourcePlan, allocator: Allocator) void {
        if (self.resources.len > 0) allocator.free(self.resources);
        self.* = .{};
    }

    pub fn maxima(self: IndexResourcePlan) IndexResourceMaxima {
        var result = IndexResourceMaxima{};
        for (self.resources) |entry| {
            result.storage_write_keys = @max(result.storage_write_keys, entry.storage_write_keys);
            result.changed_accounts = @max(result.changed_accounts, entry.changed_accounts);
        }
        return result;
    }
};

pub const Decoded = struct {
    accounts: []AccountChanges = &.{},

    pub fn deinit(self: *Decoded, allocator: Allocator) void {
        for (self.accounts) |*account| deinitAccount(allocator, account);
        allocator.free(self.accounts);
        self.* = .{};
    }
};

pub const IndexError = error{BlockAccessIndexOverflow};

pub fn transactionIndex(zero_based_tx_index: BlockAccessIndex) IndexError!BlockAccessIndex {
    return std.math.add(BlockAccessIndex, zero_based_tx_index, 1) catch error.BlockAccessIndexOverflow;
}

pub fn postExecutionSystemIndex(transaction_count: BlockAccessIndex) IndexError!BlockAccessIndex {
    return std.math.add(BlockAccessIndex, transaction_count, 1) catch error.BlockAccessIndexOverflow;
}

pub fn count(block_access_list: BlockAccessList) Counts {
    var result = Counts{ .accounts = block_access_list.len };
    for (block_access_list) |account| {
        result.storage_read_keys += account.storage_reads.len;
        result.storage_write_keys += account.storage_changes.len;
        for (account.storage_changes) |slot| {
            result.storage_write_changes += slot.changes.len;
            for (slot.changes) |change| updateMaxIndex(&result, change.block_access_index);
        }
        result.balance_changes += account.balance_changes.len;
        for (account.balance_changes) |change| updateMaxIndex(&result, change.block_access_index);
        result.nonce_changes += account.nonce_changes.len;
        for (account.nonce_changes) |change| updateMaxIndex(&result, change.block_access_index);
        result.code_changes += account.code_changes.len;
        for (account.code_changes) |change| {
            result.code_bytes += change.new_code.len;
            updateMaxIndex(&result, change.block_access_index);
        }
    }
    return result;
}

/// Derive per-`BlockAccessIndex` resource shape from BAL changes.
///
/// BAL storage reads are not indexed, so this planner only covers transaction-
/// lived resources that can be proven from change indices. It expects callers to
/// validate canonical BAL shape before relying on the result.
pub fn planIndexResources(allocator: Allocator, block_access_list: BlockAccessList) Allocator.Error!IndexResourcePlan {
    var storage_events: std.ArrayList(IndexEvent) = .empty;
    defer storage_events.deinit(allocator);
    var account_events: std.ArrayList(IndexAddressEvent) = .empty;
    defer account_events.deinit(allocator);

    for (block_access_list) |account| {
        for (account.storage_changes) |slot| {
            for (slot.changes) |change| {
                try storage_events.append(allocator, .{ .block_access_index = change.block_access_index });
                try account_events.append(allocator, .{
                    .block_access_index = change.block_access_index,
                    .address = account.address,
                });
            }
        }
        for (account.balance_changes) |change| {
            try account_events.append(allocator, .{
                .block_access_index = change.block_access_index,
                .address = account.address,
            });
        }
        for (account.nonce_changes) |change| {
            try account_events.append(allocator, .{
                .block_access_index = change.block_access_index,
                .address = account.address,
            });
        }
        for (account.code_changes) |change| {
            try account_events.append(allocator, .{
                .block_access_index = change.block_access_index,
                .address = account.address,
            });
        }
    }

    std.mem.sort(IndexEvent, storage_events.items, {}, indexEventLessThan);
    std.mem.sort(IndexAddressEvent, account_events.items, {}, indexAddressEventLessThan);

    var resources: std.ArrayList(IndexResources) = .empty;
    errdefer resources.deinit(allocator);

    var storage_index: usize = 0;
    var account_index: usize = 0;
    while (storage_index < storage_events.items.len or account_index < account_events.items.len) {
        const next_storage = if (storage_index < storage_events.items.len) storage_events.items[storage_index].block_access_index else null;
        const next_account = if (account_index < account_events.items.len) account_events.items[account_index].block_access_index else null;
        const block_access_index = nextIndex(next_storage, next_account);

        var entry = IndexResources{ .block_access_index = block_access_index };
        while (storage_index < storage_events.items.len and storage_events.items[storage_index].block_access_index == block_access_index) {
            entry.storage_write_keys += 1;
            storage_index += 1;
        }

        var previous_account: ?Address = null;
        while (account_index < account_events.items.len and account_events.items[account_index].block_access_index == block_access_index) {
            const account = account_events.items[account_index].address;
            if (previous_account == null or !std.mem.eql(u8, &previous_account.?, &account)) {
                entry.changed_accounts += 1;
                previous_account = account;
            }
            account_index += 1;
        }

        try resources.append(allocator, entry);
    }

    return .{ .resources = try resources.toOwnedSlice(allocator) };
}

pub fn validate(block_access_list: BlockAccessList, options: ValidationOptions) ValidationError!void {
    for (block_access_list, 0..) |account, index| {
        if (index != 0) {
            const previous = block_access_list[index - 1].address;
            switch (std.mem.order(u8, &previous, &account.address)) {
                .lt => {},
                .eq => return error.DuplicateAccount,
                .gt => return error.AccountsOutOfOrder,
            }
        }
        try validateAccount(account, options);
    }
}

const IndexEvent = struct {
    block_access_index: BlockAccessIndex,
};

const IndexAddressEvent = struct {
    block_access_index: BlockAccessIndex,
    address: Address,
};

fn indexEventLessThan(_: void, lhs: IndexEvent, rhs: IndexEvent) bool {
    return lhs.block_access_index < rhs.block_access_index;
}

fn indexAddressEventLessThan(_: void, lhs: IndexAddressEvent, rhs: IndexAddressEvent) bool {
    if (lhs.block_access_index != rhs.block_access_index) return lhs.block_access_index < rhs.block_access_index;
    return std.mem.order(u8, &lhs.address, &rhs.address) == .lt;
}

fn nextIndex(lhs: ?BlockAccessIndex, rhs: ?BlockAccessIndex) BlockAccessIndex {
    if (lhs) |left| {
        if (rhs) |right| return @min(left, right);
        return left;
    }
    return rhs.?;
}

pub fn validateGasLimit(block_access_list: BlockAccessList, block_gas_limit: u64) ValidationError!void {
    const max_items = block_gas_limit / item_cost;
    const item_count = count(block_access_list).blockAccessItems();
    if (item_count > max_items) return error.BlockAccessListGasLimitExceeded;
}

pub fn encodeAlloc(
    allocator: Allocator,
    block_access_list: BlockAccessList,
) (rlp.EncodeError || Allocator.Error)![]u8 {
    return rlp.encodeAlloc(BlockAccessList, allocator, block_access_list);
}

pub fn hash(allocator: Allocator, block_access_list: BlockAccessList) (rlp.EncodeError || Allocator.Error)![32]u8 {
    const encoded = try encodeAlloc(allocator, block_access_list);
    defer allocator.free(encoded);
    return crypto.keccak256(encoded);
}

pub fn decode(allocator: Allocator, encoded: []const u8) (Allocator.Error || rlp.DecodeError)!Decoded {
    var budget = rlp.Budget.init(inputDecodeLimits(encoded.len));
    return decodeWithBudget(allocator, encoded, &budget);
}

pub fn decodeWithBudget(
    allocator: Allocator,
    encoded: []const u8,
    budget: *rlp.Budget,
) (Allocator.Error || rlp.DecodeError)!Decoded {
    var accounts = try rlp.decodeAllocWithBudget(BlockAccessList, allocator, encoded, budget);
    errdefer rlp.deinit(BlockAccessList, allocator, &accounts);
    try copyCodeBytes(allocator, @constCast(accounts), budget);
    return .{ .accounts = @constCast(accounts) };
}

/// Finite fallback for callers without exact spec context.
fn inputDecodeLimits(encoded_len: usize) rlp.Limits {
    return .{
        .max_depth = max_rlp_depth,
        .max_items = encoded_len,
        .max_allocated_bytes = saturatingMul(encoded_len, max_aggregate_value_size + 1),
    };
}

/// Pre-materialization envelope derived from block gas, transaction indices,
/// and encoded byte length. Semantic ordering and uniqueness remain in
/// `validate`; this bounds work before those checks run.
pub fn blockDecodeLimits(
    encoded_len: usize,
    transaction_count: BlockAccessIndex,
    block_gas_limit: u64,
) rlp.Limits {
    const input_limits = inputDecodeLimits(encoded_len);
    if (block_gas_limit == 0) return input_limits;
    const access_items = std.math.cast(usize, block_gas_limit / item_cost) orelse
        std.math.maxInt(usize);
    const index_values = saturatingAdd(@as(usize, transaction_count), 2);
    const indexed_entries = saturatingMul(access_items, index_values);

    const item_limit = saturatingAdd(
        1,
        saturatingAdd(saturatingMul(access_items, 11), saturatingMul(indexed_entries, 12)),
    );
    const aggregate_per_access = @sizeOf(AccountChanges) + @sizeOf(SlotChanges) + @sizeOf(u256);
    const aggregate_per_index = @sizeOf(StorageChange) +
        @sizeOf(BalanceChange) +
        @sizeOf(NonceChange) +
        @sizeOf(CodeChange);
    const allocation_limit = saturatingAdd(
        encoded_len,
        saturatingAdd(
            saturatingMul(access_items, aggregate_per_access),
            saturatingMul(indexed_entries, aggregate_per_index),
        ),
    );

    return .{
        .max_depth = max_rlp_depth,
        .max_items = @min(input_limits.max_items, item_limit),
        .max_allocated_bytes = @min(input_limits.max_allocated_bytes, allocation_limit),
    };
}

fn validateAccount(account: AccountChanges, options: ValidationOptions) ValidationError!void {
    for (account.storage_changes, 0..) |slot, index| {
        if (slot.changes.len == 0) return error.EmptySlotChanges;
        if (index != 0) {
            const previous = account.storage_changes[index - 1].slot;
            if (previous == slot.slot) return error.DuplicateStorageChangeSlot;
            if (previous > slot.slot) return error.StorageChangesOutOfOrder;
        }
        try validateIndexList(StorageChange, slot.changes, options, .storage);
    }

    for (account.storage_reads, 0..) |slot, index| {
        if (index != 0) {
            const previous = account.storage_reads[index - 1];
            if (previous == slot) return error.DuplicateStorageRead;
            if (previous > slot) return error.StorageReadsOutOfOrder;
        }
    }
    try validateNoStorageReadWriteOverlap(account.storage_changes, account.storage_reads);

    try validateIndexList(BalanceChange, account.balance_changes, options, .balance);
    try validateIndexList(NonceChange, account.nonce_changes, options, .nonce);
    try validateIndexList(CodeChange, account.code_changes, options, .code);
}

const IndexedListKind = enum {
    storage,
    balance,
    nonce,
    code,
};

fn validateIndexList(comptime T: type, changes: []const T, options: ValidationOptions, kind: IndexedListKind) ValidationError!void {
    for (changes, 0..) |change, index| {
        const change_index = change.block_access_index;
        if (options.transaction_count) |transaction_count| {
            const max_index = postExecutionSystemIndex(transaction_count) catch return error.BlockAccessIndexOutOfRange;
            if (change_index > max_index) return error.BlockAccessIndexOutOfRange;
        }
        if (index == 0) continue;
        const previous = changes[index - 1].block_access_index;
        if (previous == change_index) {
            return switch (kind) {
                .storage => error.DuplicateStorageChangeIndex,
                .balance => error.DuplicateBalanceChangeIndex,
                .nonce => error.DuplicateNonceChangeIndex,
                .code => error.DuplicateCodeChangeIndex,
            };
        }
        if (previous > change_index) {
            return switch (kind) {
                .storage => error.StorageChangeIndicesOutOfOrder,
                .balance => error.BalanceChangeIndicesOutOfOrder,
                .nonce => error.NonceChangeIndicesOutOfOrder,
                .code => error.CodeChangeIndicesOutOfOrder,
            };
        }
    }
}

fn validateNoStorageReadWriteOverlap(storage_changes: []const SlotChanges, storage_reads: []const u256) ValidationError!void {
    var change_index: usize = 0;
    var read_index: usize = 0;
    while (change_index < storage_changes.len and read_index < storage_reads.len) {
        const changed_slot = storage_changes[change_index].slot;
        const read_slot = storage_reads[read_index];
        if (changed_slot == read_slot) return error.StorageReadAlsoWritten;
        if (changed_slot < read_slot) {
            change_index += 1;
        } else {
            read_index += 1;
        }
    }
}

fn updateMaxIndex(counts_value: *Counts, block_access_index: BlockAccessIndex) void {
    if (counts_value.max_block_access_index) |current| {
        if (block_access_index > current) counts_value.max_block_access_index = block_access_index;
    } else {
        counts_value.max_block_access_index = block_access_index;
    }
}

fn copyCodeBytes(
    allocator: Allocator,
    accounts: []AccountChanges,
    budget: *rlp.Budget,
) (Allocator.Error || rlp.DecodeError)!void {
    var account_index: usize = 0;
    var code_index: usize = 0;
    errdefer {
        for (accounts[0..account_index]) |account| {
            for (account.code_changes) |change| allocator.free(@constCast(change.new_code));
        }
        if (account_index < accounts.len) {
            for (accounts[account_index].code_changes[0..code_index]) |change| {
                allocator.free(@constCast(change.new_code));
            }
        }
    }

    while (account_index < accounts.len) : (account_index += 1) {
        const changes = @constCast(accounts[account_index].code_changes);
        code_index = 0;
        while (code_index < changes.len) : (code_index += 1) {
            try budget.ensureAllocation(changes[code_index].new_code.len);
            const owned = try allocator.dupe(u8, changes[code_index].new_code);
            budget.commitAllocation(owned.len);
            changes[code_index].new_code = owned;
        }
    }
}

const max_aggregate_value_size = blk: {
    var maximum: usize = 0;
    for (.{ AccountChanges, SlotChanges, StorageChange, BalanceChange, NonceChange, CodeChange, u256 }) |T| {
        maximum = @max(maximum, @sizeOf(T));
    }
    break :blk maximum;
};

fn saturatingAdd(lhs: usize, rhs: usize) usize {
    return std.math.add(usize, lhs, rhs) catch std.math.maxInt(usize);
}

fn saturatingMul(lhs: usize, rhs: usize) usize {
    return std.math.mul(usize, lhs, rhs) catch std.math.maxInt(usize);
}

fn deinitAccount(allocator: Allocator, account: *AccountChanges) void {
    for (account.storage_changes) |slot| allocator.free(@constCast(slot.changes));
    allocator.free(@constCast(account.storage_changes));
    allocator.free(@constCast(account.storage_reads));
    allocator.free(@constCast(account.balance_changes));
    allocator.free(@constCast(account.nonce_changes));
    for (account.code_changes) |change| allocator.free(@constCast(change.new_code));
    allocator.free(@constCast(account.code_changes));
    account.* = .{ .address = undefined };
}

const sample_storage_reads = [_]u256{5};
const sample_storage_change_rows = [_]StorageChange{.{
    .block_access_index = 1,
    .new_value = 0x42,
}};
const sample_slot_changes = [_]SlotChanges{.{
    .slot = 2,
    .changes = &sample_storage_change_rows,
}};
const sample_balance_changes = [_]BalanceChange{.{
    .block_access_index = 1,
    .post_balance = 100,
}};
const sample_nonce_changes = [_]NonceChange{.{
    .block_access_index = 1,
    .new_nonce = 7,
}};
const sample_code_changes = [_]CodeChange{.{
    .block_access_index = 2,
    .new_code = &.{ 0x60, 0x00, 0x56 },
}};
const sample_accounts = [_]AccountChanges{
    .{
        .address = address.addr(0x1000),
        .balance_changes = &sample_balance_changes,
        .nonce_changes = &sample_nonce_changes,
    },
    .{
        .address = address.addr(0x2000),
        .storage_changes = &sample_slot_changes,
        .storage_reads = &sample_storage_reads,
        .code_changes = &sample_code_changes,
    },
};

fn sampleBlockAccessList() BlockAccessList {
    return &sample_accounts;
}

test "BAL empty list has the EIP-7928 empty hash" {
    const encoded = try encodeAlloc(std.testing.allocator, &.{});
    defer std.testing.allocator.free(encoded);

    try t.expectHex(encoded, "c0");
    const empty = try hash(std.testing.allocator, &.{});
    try std.testing.expectEqualSlices(u8, &empty_hash, &empty);
}

test "BAL RLP round trips model data" {
    const input = sampleBlockAccessList();
    try validate(input, .{ .transaction_count = 2 });

    const encoded = try encodeAlloc(std.testing.allocator, input);
    defer std.testing.allocator.free(encoded);

    var decoded = try decode(std.testing.allocator, encoded);
    defer decoded.deinit(std.testing.allocator);
    try validate(decoded.accounts, .{ .transaction_count = 2 });

    try std.testing.expectEqual(@as(usize, 2), decoded.accounts.len);
    try std.testing.expectEqualSlices(u8, &address.addr(0x1000), &decoded.accounts[0].address);
    try std.testing.expectEqual(@as(u256, 100), decoded.accounts[0].balance_changes[0].post_balance);
    try std.testing.expectEqual(@as(u64, 7), decoded.accounts[0].nonce_changes[0].new_nonce);
    try std.testing.expectEqual(@as(u256, 2), decoded.accounts[1].storage_changes[0].slot);
    try std.testing.expectEqual(@as(u256, 0x42), decoded.accounts[1].storage_changes[0].changes[0].new_value);
    try std.testing.expectEqualSlices(u8, &.{ 0x60, 0x00, 0x56 }, decoded.accounts[1].code_changes[0].new_code);
}

test "BAL typed codec writes directly and encodeAlloc allocates once" {
    const input = sampleBlockAccessList();
    var direct_buffer: [512]u8 = undefined;
    const direct = try rlp.encode(BlockAccessList, &direct_buffer, input);

    var counted = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const before = counted.alloc_index;
    const allocated = try encodeAlloc(counted.allocator(), input);
    defer counted.allocator().free(allocated);

    try std.testing.expectEqual(before + 1, counted.alloc_index);
    try std.testing.expectEqualSlices(u8, direct, allocated);
}

test "BAL typed decode applies block-derived budget before materialization" {
    const input = sampleBlockAccessList();
    const encoded = try encodeAlloc(std.testing.allocator, input);
    defer std.testing.allocator.free(encoded);

    var valid_budget = rlp.Budget.init(blockDecodeLimits(encoded.len, 2, 8_000));
    var decoded = try decodeWithBudget(std.testing.allocator, encoded, &valid_budget);
    defer decoded.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), decoded.accounts.len);
    try std.testing.expect(valid_budget.allocated_bytes > 0);

    var too_small = rlp.Budget.init(blockDecodeLimits(encoded.len, 2, 1));
    try std.testing.expectError(
        error.DecodeItemLimitExceeded,
        decodeWithBudget(std.testing.allocator, encoded, &too_small),
    );
}

test "BAL typed decode cleans every allocation failure position" {
    const Harness = struct {
        fn run(allocator: Allocator) !void {
            const encoded = try encodeAlloc(std.testing.allocator, sampleBlockAccessList());
            defer std.testing.allocator.free(encoded);
            var decoded = try decode(allocator, encoded);
            defer decoded.deinit(allocator);
            try std.testing.expectEqual(@as(usize, 2), decoded.accounts.len);
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Harness.run, .{});
}

test "BAL decode frees an account rejected for trailing fields" {
    var code_change_payload = rlp.Writer.alloc(std.testing.allocator);
    defer code_change_payload.deinit();
    try code_change_payload.int(BlockAccessIndex, 1);
    try code_change_payload.bytes(&.{0x60});

    var code_changes_payload = rlp.Writer.alloc(std.testing.allocator);
    defer code_changes_payload.deinit();
    try code_changes_payload.listPayload(code_change_payload.written());

    var account_payload = rlp.Writer.alloc(std.testing.allocator);
    defer account_payload.deinit();
    try account_payload.bytes(&address.addr(1));
    inline for (0..4) |_| try account_payload.listPayload(&.{});
    try account_payload.listPayload(code_changes_payload.written());
    try account_payload.listPayload(&.{}); // Trailing seventh account field.

    var account = rlp.Writer.alloc(std.testing.allocator);
    defer account.deinit();
    try account.listPayload(account_payload.written());

    var encoded = rlp.Writer.alloc(std.testing.allocator);
    defer encoded.deinit();
    try encoded.listPayload(account.written());

    try std.testing.expectError(error.TrailingBytes, decode(std.testing.allocator, encoded.written()));
}

test "BAL count helper summarizes declared shape" {
    const counted = count(sampleBlockAccessList());

    try std.testing.expectEqual(@as(usize, 2), counted.accounts);
    try std.testing.expectEqual(@as(usize, 1), counted.storage_read_keys);
    try std.testing.expectEqual(@as(usize, 1), counted.storage_write_keys);
    try std.testing.expectEqual(@as(usize, 1), counted.storage_write_changes);
    try std.testing.expectEqual(@as(usize, 1), counted.balance_changes);
    try std.testing.expectEqual(@as(usize, 1), counted.nonce_changes);
    try std.testing.expectEqual(@as(usize, 1), counted.code_changes);
    try std.testing.expectEqual(@as(usize, 3), counted.code_bytes);
    try std.testing.expectEqual(@as(usize, 4), counted.blockAccessItems());
    try std.testing.expectEqual(@as(?BlockAccessIndex, 2), counted.max_block_access_index);
}

test "BAL per-index planner derives transaction-lived maxima" {
    const accounts = [_]AccountChanges{
        .{
            .address = address.addr(1),
            .storage_changes = &.{
                .{ .slot = 1, .changes = &.{
                    .{ .block_access_index = 1, .new_value = 11 },
                    .{ .block_access_index = 3, .new_value = 13 },
                } },
                .{ .slot = 2, .changes = &.{
                    .{ .block_access_index = 1, .new_value = 21 },
                } },
            },
            .balance_changes = &.{
                .{ .block_access_index = 1, .post_balance = 100 },
            },
            .nonce_changes = &.{
                .{ .block_access_index = 2, .new_nonce = 7 },
            },
        },
        .{
            .address = address.addr(2),
            .balance_changes = &.{
                .{ .block_access_index = 1, .post_balance = 200 },
            },
        },
    };

    var plan = try planIndexResources(std.testing.allocator, &accounts);
    defer plan.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 3), plan.resources.len);
    try std.testing.expectEqual(IndexResources{ .block_access_index = 1, .storage_write_keys = 2, .changed_accounts = 2 }, plan.resources[0]);
    try std.testing.expectEqual(IndexResources{ .block_access_index = 2, .storage_write_keys = 0, .changed_accounts = 1 }, plan.resources[1]);
    try std.testing.expectEqual(IndexResources{ .block_access_index = 3, .storage_write_keys = 1, .changed_accounts = 1 }, plan.resources[2]);

    const maxima = plan.maxima();
    try std.testing.expectEqual(@as(usize, 2), maxima.storage_write_keys);
    try std.testing.expectEqual(@as(usize, 2), maxima.changed_accounts);
}

test "BAL validation rejects non-canonical account and storage ordering" {
    const accounts = [_]AccountChanges{
        .{ .address = address.addr(2) },
        .{ .address = address.addr(1) },
    };
    try std.testing.expectError(error.AccountsOutOfOrder, validate(&accounts, .{}));

    const duplicated = [_]AccountChanges{
        .{ .address = address.addr(1) },
        .{ .address = address.addr(1) },
    };
    try std.testing.expectError(error.DuplicateAccount, validate(&duplicated, .{}));

    const reads = [_]u256{ 8, 7 };
    const bad_reads = [_]AccountChanges{.{
        .address = address.addr(1),
        .storage_reads = &reads,
    }};
    try std.testing.expectError(error.StorageReadsOutOfOrder, validate(&bad_reads, .{}));
}

test "BAL validation rejects duplicate storage read and write declarations" {
    const changes = [_]StorageChange{.{
        .block_access_index = 1,
        .new_value = 10,
    }};
    const slots = [_]SlotChanges{.{
        .slot = 9,
        .changes = &changes,
    }};
    const reads = [_]u256{9};
    const accounts = [_]AccountChanges{.{
        .address = address.addr(1),
        .storage_changes = &slots,
        .storage_reads = &reads,
    }};

    try std.testing.expectError(error.StorageReadAlsoWritten, validate(&accounts, .{}));
}

test "BAL validation accepts interleaved disjoint storage reads and writes" {
    const change = [_]StorageChange{.{
        .block_access_index = 1,
        .new_value = 10,
    }};
    const slots = [_]SlotChanges{
        .{ .slot = 1, .changes = &change },
        .{ .slot = 3, .changes = &change },
    };
    const reads = [_]u256{ 2, 4 };
    const accounts = [_]AccountChanges{.{
        .address = address.addr(1),
        .storage_changes = &slots,
        .storage_reads = &reads,
    }};

    try validate(&accounts, .{});
}

test "BAL validation rejects duplicate and out-of-range change indices" {
    const balances = [_]BalanceChange{
        .{ .block_access_index = 1, .post_balance = 1 },
        .{ .block_access_index = 1, .post_balance = 2 },
    };
    const duplicate = [_]AccountChanges{.{
        .address = address.addr(1),
        .balance_changes = &balances,
    }};
    try std.testing.expectError(error.DuplicateBalanceChangeIndex, validate(&duplicate, .{}));

    const nonces = [_]NonceChange{.{
        .block_access_index = 4,
        .new_nonce = 1,
    }};
    const out_of_range = [_]AccountChanges{.{
        .address = address.addr(1),
        .nonce_changes = &nonces,
    }};
    try std.testing.expectError(error.BlockAccessIndexOutOfRange, validate(&out_of_range, .{ .transaction_count = 2 }));
}

test "BAL validation rejects empty slot changes and gas-limit overflow" {
    const slots = [_]SlotChanges{.{
        .slot = 1,
        .changes = &.{},
    }};
    const empty_slot = [_]AccountChanges{.{
        .address = address.addr(1),
        .storage_changes = &slots,
    }};
    try std.testing.expectError(error.EmptySlotChanges, validate(&empty_slot, .{}));

    const reads = [_]u256{ 1, 2 };
    const too_many_items = [_]AccountChanges{.{
        .address = address.addr(1),
        .storage_reads = &reads,
    }};
    try std.testing.expectError(error.BlockAccessListGasLimitExceeded, validateGasLimit(&too_many_items, 4_000));
}

test "BAL block access index helpers encode EIP positions" {
    try std.testing.expectEqual(@as(BlockAccessIndex, 1), try transactionIndex(0));
    try std.testing.expectEqual(@as(BlockAccessIndex, 3), try postExecutionSystemIndex(2));
    try std.testing.expectError(error.BlockAccessIndexOverflow, transactionIndex(std.math.maxInt(BlockAccessIndex)));
    try std.testing.expectError(error.BlockAccessIndexOverflow, postExecutionSystemIndex(std.math.maxInt(BlockAccessIndex)));
}

test "BAL storage key integers use compact RLP form" {
    const changes = [_]StorageChange{.{
        .block_access_index = 1,
        .new_value = 0,
    }};
    const slots = [_]SlotChanges{.{
        .slot = 1,
        .changes = &changes,
    }};
    const accounts = [_]AccountChanges{.{
        .address = address.addr(1),
        .storage_changes = &slots,
    }};
    const encoded = try encodeAlloc(std.testing.allocator, &accounts);
    defer std.testing.allocator.free(encoded);

    // Address + six fields. The slot key `1` is encoded as one byte, not 32 bytes.
    try std.testing.expect(std.mem.indexOf(u8, encoded, &[_]u8{ 0xc5, 0x01, 0xc3, 0xc2, 0x01, 0x80 }) != null);
}
