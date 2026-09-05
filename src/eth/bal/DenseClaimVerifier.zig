//! Claim-aware BAL verification over dense stateless observation IDs.
//!
//! The admitted BAL already fixes account/slot identity and canonical order.
//! Observations arrive in increasing `BlockAccessIndex`, so validation needs
//! neither address/slot maps nor a second canonical sort: seen bits validate
//! reads while monotonic cursors validate indexed changes.

const std = @import("std");

const ClaimPlan = @import("ClaimPlan.zig").ClaimPlan;
const AccountId = @import("ClaimPlan.zig").AccountId;
const StorageId = @import("ClaimPlan.zig").StorageId;
const bal = @import("model.zig");
const observation = @import("observation.zig");
const Account = @import("../../state/Account.zig");

const Allocator = std.mem.Allocator;
const DenseClaimVerifier = @This();

pub const Error = Allocator.Error || error{
    IncompleteStorageObservation,
    ObservationCodeUnavailable,
};

const ExpectedStorage = union(enum) {
    read,
    write: u32,
};

const AccountState = struct {
    seen: bool = false,
    balance_cursor: u32 = 0,
    nonce_cursor: u32 = 0,
    code_cursor: u32 = 0,
    active_generation: u32 = 0,
};

const StorageState = struct {
    expected: ExpectedStorage,
    seen: bool = false,
    change_cursor: u32 = 0,
    active_generation: u32 = 0,
};

const ActiveAccount = struct {
    balance: ?observation.ValueObservation = null,
    nonce: ?observation.NonceObservation = null,
    code: ?observation.CodeObservation = null,
    storage_wiped: bool = false,
};

const ActiveStorage = struct {
    original: u256,
    current: u256,
};

comptime {
    std.debug.assert(@sizeOf(AccountState) <= 20);
    std.debug.assert(@sizeOf(StorageState) <= 20);
    std.debug.assert(@sizeOf(ActiveAccount) <= 208);
    std.debug.assert(@sizeOf(ActiveStorage) <= 64);
}

allocator: Allocator,
plan: *const ClaimPlan,
expected: bal.BlockAccessList,
accounts: []AccountState,
storage: []StorageState,
active_accounts: []ActiveAccount,
active_storage: []ActiveStorage,
active_account_ids: std.ArrayList(AccountId),
active_storage_ids: std.ArrayList(StorageId),
active_index: ?bal.BlockAccessIndex = null,
active_generation: u32 = 0,
mismatch: bool = false,
finished: bool = false,

pub fn init(
    allocator: Allocator,
    plan: *const ClaimPlan,
    expected: bal.BlockAccessList,
) Allocator.Error!DenseClaimVerifier {
    std.debug.assert(expected.len == plan.accountCount());
    const accounts = try allocator.alloc(AccountState, plan.accountCount());
    errdefer allocator.free(accounts);
    @memset(accounts, .{});
    const storage = try allocator.alloc(StorageState, plan.storageCount());
    errdefer allocator.free(storage);
    const active_accounts = try allocator.alloc(ActiveAccount, plan.accountCount());
    errdefer allocator.free(active_accounts);
    const active_storage = try allocator.alloc(ActiveStorage, plan.storageCount());
    errdefer allocator.free(active_storage);
    var active_account_ids = try std.ArrayList(AccountId).initCapacity(allocator, plan.accountCount());
    errdefer active_account_ids.deinit(allocator);
    var active_storage_ids = try std.ArrayList(StorageId).initCapacity(allocator, plan.storageCount());
    errdefer active_storage_ids.deinit(allocator);

    for (expected, 0..) |account, account_index| {
        const account_id: AccountId = @enumFromInt(account_index);
        std.debug.assert(bal.Address.eql(account.address, plan.accountAddress(account_id)));
        const range = plan.accountStorageRange(account_id);
        var read_index: usize = 0;
        var write_index: usize = 0;
        for (range.start..range.end()) |storage_index| {
            const storage_id: StorageId = @enumFromInt(storage_index);
            const slot = plan.storageSlot(storage_id);
            const has_read = read_index < account.storage_reads.len;
            const has_write = write_index < account.storage_changes.len;
            if (has_read and (!has_write or account.storage_reads[read_index] < account.storage_changes[write_index].slot)) {
                std.debug.assert(account.storage_reads[read_index] == slot);
                storage[storage_index] = .{ .expected = .read };
                read_index += 1;
            } else {
                std.debug.assert(has_write and account.storage_changes[write_index].slot == slot);
                storage[storage_index] = .{ .expected = .{ .write = @intCast(write_index) } };
                write_index += 1;
            }
        }
        std.debug.assert(read_index == account.storage_reads.len);
        std.debug.assert(write_index == account.storage_changes.len);
    }

    return .{
        .allocator = allocator,
        .plan = plan,
        .expected = expected,
        .accounts = accounts,
        .storage = storage,
        .active_accounts = active_accounts,
        .active_storage = active_storage,
        .active_account_ids = active_account_ids,
        .active_storage_ids = active_storage_ids,
    };
}

pub fn deinit(self: *DenseClaimVerifier) void {
    self.active_storage_ids.deinit(self.allocator);
    self.active_account_ids.deinit(self.allocator);
    self.allocator.free(self.active_storage);
    self.allocator.free(self.active_accounts);
    self.allocator.free(self.storage);
    self.allocator.free(self.accounts);
    self.* = undefined;
}

pub fn append(
    self: *DenseClaimVerifier,
    view: anytype,
    block_access_index: bal.BlockAccessIndex,
) Error!void {
    std.debug.assert(!self.finished);
    if (self.active_index) |current| {
        std.debug.assert(block_access_index >= current);
        if (block_access_index != current) self.flush();
    }
    if (self.active_index == null) {
        self.active_generation +%= 1;
        std.debug.assert(self.active_generation != 0);
        self.active_index = block_access_index;
    }

    var account_index: u32 = 0;
    while (account_index < view.accounts.len()) : (account_index += 1) {
        const fact = view.accounts.at(account_index);
        const fields = try observation.accountFields(view, fact) orelse continue;
        const id = view.accounts.idAt(account_index);
        const index = @intFromEnum(id);
        const state = &self.accounts[index];
        if (state.active_generation != self.active_generation) {
            state.active_generation = self.active_generation;
            self.active_accounts[index] = .{};
            self.active_account_ids.appendAssumeCapacity(id);
        }
        const active = &self.active_accounts[index];
        if (fields.balance) |field| {
            if (active.balance) |*value| {
                value.current = field.current;
            } else {
                active.balance = field;
            }
        }
        if (fields.nonce) |field| {
            if (active.nonce) |*value| {
                value.current = field.current;
            } else {
                active.nonce = field;
            }
        }
        if (fields.code) |field| {
            if (active.code) |*value| {
                value.current_hash = field.current_hash;
                value.current_code = field.current_code;
            } else {
                active.code = field;
            }
        }
        active.storage_wiped = active.storage_wiped or fields.storage_wiped;
    }

    var storage_index: u32 = 0;
    while (storage_index < view.storage.len()) : (storage_index += 1) {
        const metadata = view.storage.metadataAt(storage_index);
        if (!metadata.observation.value_read and !metadata.effect.written) continue;
        const fact = view.storage.at(storage_index) orelse
            return error.IncompleteStorageObservation;
        const id = view.storage.idAt(storage_index);
        const index = @intFromEnum(id);
        const state = &self.storage[index];
        if (state.active_generation != self.active_generation) {
            state.active_generation = self.active_generation;
            self.active_storage[index] = .{
                .original = fact.original,
                .current = fact.current,
            };
            self.active_storage_ids.appendAssumeCapacity(id);
        } else {
            self.active_storage[index].current = fact.current;
        }
    }
}

pub fn matchesClaim(self: *DenseClaimVerifier) !bool {
    std.debug.assert(!self.finished);
    self.flush();
    self.finished = true;
    if (self.mismatch) return false;
    for (self.accounts, self.expected) |state, expected| {
        if (!state.seen or
            state.balance_cursor != expected.balance_changes.len or
            state.nonce_cursor != expected.nonce_changes.len or
            state.code_cursor != expected.code_changes.len)
        {
            return false;
        }
    }
    for (self.storage, 0..) |state, storage_index| {
        if (!state.seen) return false;
        switch (state.expected) {
            .read => {},
            .write => |write_index| {
                const storage_id: StorageId = @enumFromInt(storage_index);
                const account_id = self.plan.storageAccount(storage_id);
                const expected = self.expected[@intFromEnum(account_id)].storage_changes[write_index];
                if (state.change_cursor != expected.changes.len) return false;
            },
        }
    }
    return true;
}

fn flush(self: *DenseClaimVerifier) void {
    const block_access_index = self.active_index orelse return;

    for (self.active_account_ids.items) |id| {
        const index = @intFromEnum(id);
        const active = self.active_accounts[index];
        const state = &self.accounts[index];
        state.seen = true;
        if (active.balance) |value| if (value.original != value.current)
            self.expectBalance(id, block_access_index, value.current);
        if (active.nonce) |value| if (value.original != value.current)
            self.expectNonce(id, block_access_index, value.current);
        if (active.code) |value| if (!std.mem.eql(u8, &value.original_hash, &value.current_hash))
            self.expectCode(id, block_access_index, value.current_code);
    }

    for (self.active_storage_ids.items) |id| {
        const index = @intFromEnum(id);
        const account_id = self.plan.storageAccount(id);
        self.accounts[@intFromEnum(account_id)].seen = true;
        const account_wiped = self.accounts[@intFromEnum(account_id)].active_generation == self.active_generation and
            self.active_accounts[@intFromEnum(account_id)].storage_wiped;
        const active = self.active_storage[index];
        const actual_read = observation.storageIsRead(
            account_wiped,
            active.original,
            active.current,
        );
        const state = &self.storage[index];
        state.seen = true;
        switch (state.expected) {
            .read => {
                if (!actual_read) self.mismatch = true;
            },
            .write => |write_index| if (!actual_read) {
                const expected = self.expected[@intFromEnum(account_id)].storage_changes[write_index].changes;
                const cursor = state.change_cursor;
                if (cursor >= expected.len or
                    expected[cursor].block_access_index != block_access_index or
                    expected[cursor].new_value != active.current)
                {
                    self.mismatch = true;
                } else {
                    state.change_cursor += 1;
                }
            },
        }
    }

    self.active_account_ids.clearRetainingCapacity();
    self.active_storage_ids.clearRetainingCapacity();
    self.active_index = null;
}

fn expectBalance(
    self: *DenseClaimVerifier,
    id: AccountId,
    block_access_index: bal.BlockAccessIndex,
    value: u256,
) void {
    const index = @intFromEnum(id);
    const state = &self.accounts[index];
    const expected = self.expected[index].balance_changes;
    const cursor = state.balance_cursor;
    if (cursor >= expected.len or
        expected[cursor].block_access_index != block_access_index or
        expected[cursor].post_balance != value)
    {
        self.mismatch = true;
    } else {
        state.balance_cursor += 1;
    }
}

fn expectNonce(
    self: *DenseClaimVerifier,
    id: AccountId,
    block_access_index: bal.BlockAccessIndex,
    value: u64,
) void {
    const index = @intFromEnum(id);
    const state = &self.accounts[index];
    const expected = self.expected[index].nonce_changes;
    const cursor = state.nonce_cursor;
    if (cursor >= expected.len or
        expected[cursor].block_access_index != block_access_index or
        expected[cursor].new_nonce != value)
    {
        self.mismatch = true;
    } else {
        state.nonce_cursor += 1;
    }
}

fn expectCode(
    self: *DenseClaimVerifier,
    id: AccountId,
    block_access_index: bal.BlockAccessIndex,
    value: []const u8,
) void {
    const index = @intFromEnum(id);
    const state = &self.accounts[index];
    const expected = self.expected[index].code_changes;
    const cursor = state.code_cursor;
    if (cursor >= expected.len or
        expected[cursor].block_access_index != block_access_index or
        !std.mem.eql(u8, expected[cursor].new_code, value))
    {
        self.mismatch = true;
    } else {
        state.code_cursor += 1;
    }
}

const TestAccountObservation = struct {
    semantic_access: bool = false,
};

const TestAccountEffect = struct {
    balance_written: bool = false,
    nonce_written: bool = false,
    code_written: bool = false,
    storage_wiped: bool = false,

    pub fn any(self: TestAccountEffect) bool {
        return self.balance_written or self.nonce_written or
            self.code_written or self.storage_wiped;
    }
};

const TestStorageObservation = struct {
    value_read: bool = false,
};

const TestStorageEffect = struct {
    written: bool = false,
};

const TestAccountFact = struct {
    address: bal.Address,
    original: ?Account,
    current: ?Account,
    observation: TestAccountObservation = .{},
    effect: TestAccountEffect = .{},
};

const TestStorageFact = struct {
    address: bal.Address,
    key: u256,
    original: u256,
    current: u256,
    observation: TestStorageObservation = .{},
    effect: TestStorageEffect = .{},
};

const TestAccountEntry = struct {
    id: AccountId,
    fact: TestAccountFact,
};

const TestStorageEntry = struct {
    id: StorageId,
    fact: TestStorageFact,
};

const TestView = struct {
    const Accounts = struct {
        items: []const TestAccountEntry,

        pub fn len(self: Accounts) u32 {
            return @intCast(self.items.len);
        }

        pub fn at(self: Accounts, index: u32) TestAccountFact {
            return self.items[index].fact;
        }

        pub fn idAt(self: Accounts, index: u32) AccountId {
            return self.items[index].id;
        }
    };

    const Storage = struct {
        items: []const TestStorageEntry,

        pub fn len(self: Storage) u32 {
            return @intCast(self.items.len);
        }

        pub fn at(self: Storage, index: u32) ?TestStorageFact {
            return self.items[index].fact;
        }

        pub fn idAt(self: Storage, index: u32) StorageId {
            return self.items[index].id;
        }

        pub fn metadataAt(self: Storage, index: u32) TestStorageFact {
            return self.items[index].fact;
        }
    };

    const CodeView = struct { bytes: []const u8 };

    accounts: Accounts,
    storage: Storage,
    code_hash: ?[32]u8 = null,
    code_bytes: []const u8 = &.{},

    fn init(
        accounts: []const TestAccountEntry,
        storage: []const TestStorageEntry,
    ) TestView {
        return .{
            .accounts = .{ .items = accounts },
            .storage = .{ .items = storage },
        };
    }

    fn initWithCode(
        accounts: []const TestAccountEntry,
        storage: []const TestStorageEntry,
        code_hash: [32]u8,
        code_bytes: []const u8,
    ) TestView {
        return .{
            .accounts = .{ .items = accounts },
            .storage = .{ .items = storage },
            .code_hash = code_hash,
            .code_bytes = code_bytes,
        };
    }

    pub fn code(self: TestView, hash: [32]u8) ?CodeView {
        if (self.code_hash == null or
            !std.mem.eql(u8, &self.code_hash.?, &hash)) return null;
        return .{ .bytes = self.code_bytes };
    }
};

const TestBatch = struct {
    block_access_index: bal.BlockAccessIndex,
    view: TestView,
};

fn expectMatchesGeneric(
    expected_result: bool,
    claim: bal.BlockAccessList,
    batches: []const TestBatch,
) !void {
    const Projector = @import("projector.zig");
    const allocator = std.testing.allocator;
    try bal.validate(claim, .{ .transaction_count = 4 });
    var plan = try ClaimPlan.initAssumeValidated(allocator, claim);
    defer plan.deinit(allocator);
    var dense = try DenseClaimVerifier.init(allocator, &plan, claim);
    defer dense.deinit();
    var generic = Projector.BlockBuilder.init(allocator);
    defer generic.deinit();

    for (batches) |batch| {
        try dense.append(batch.view, batch.block_access_index);
        try generic.append(batch.view, batch.block_access_index);
    }
    try std.testing.expectEqual(expected_result, try dense.matchesClaim());
    try std.testing.expectEqual(expected_result, try generic.matchesClaim(claim));
}

test "dense claim verification matches generic coalescing and mutation rejection" {
    var address = bal.Address.fromBytes(@splat(0));
    address.bytes[bal.Address.len - 1] = 1;
    const storage_changes = [_]bal.StorageChange{
        .{ .block_access_index = 1, .new_value = 9 },
        .{ .block_access_index = 3, .new_value = 11 },
    };
    const slots = [_]bal.SlotChanges{.{ .slot = 7, .changes = &storage_changes }};
    const reads = [_]u256{ 5, 8 };
    const balance_changes = [_]bal.BalanceChange{
        .{ .block_access_index = 1, .post_balance = 100 },
        .{ .block_access_index = 3, .post_balance = 120 },
    };
    const nonce_changes = [_]bal.NonceChange{
        .{ .block_access_index = 3, .new_nonce = 1 },
        .{ .block_access_index = 4, .new_nonce = 2 },
    };
    const code_a = [_]u8{ 0x60, 0x01 };
    const code_b = [_]u8{ 0x60, 0x02 };
    const code_hash_a = [_]u8{0xa1} ** 32;
    const code_hash_b = [_]u8{0xb2} ** 32;
    const code_changes = [_]bal.CodeChange{.{
        .block_access_index = 3,
        .new_code = &code_b,
    }};
    const claim = [_]bal.AccountChanges{.{
        .address = address,
        .storage_changes = &slots,
        .storage_reads = &reads,
        .balance_changes = &balance_changes,
        .nonce_changes = &nonce_changes,
        .code_changes = &code_changes,
    }};

    const account_id: AccountId = @enumFromInt(0);
    const read_five: StorageId = @enumFromInt(0);
    const write_seven: StorageId = @enumFromInt(1);
    const read_eight: StorageId = @enumFromInt(2);
    const first_accounts = [_]TestAccountEntry{.{
        .id = account_id,
        .fact = .{
            .address = address,
            .original = .{},
            .current = .{ .balance = 100 },
            .observation = .{ .semantic_access = true },
            .effect = .{ .balance_written = true },
        },
    }};
    const first_storage = [_]TestStorageEntry{
        .{ .id = read_five, .fact = .{
            .address = address,
            .key = 5,
            .original = 4,
            .current = 4,
            .observation = .{ .value_read = true },
        } },
        .{ .id = write_seven, .fact = .{
            .address = address,
            .key = 7,
            .original = 0,
            .current = 9,
            .effect = .{ .written = true },
        } },
    };
    const third_accounts_a = [_]TestAccountEntry{.{
        .id = account_id,
        .fact = .{
            .address = address,
            .original = .{ .balance = 100 },
            .current = .{ .balance = 110, .code_hash = code_hash_a },
            .effect = .{ .balance_written = true, .code_written = true },
        },
    }};
    const third_storage_a = [_]TestStorageEntry{.{
        .id = write_seven,
        .fact = .{
            .address = address,
            .key = 7,
            .original = 9,
            .current = 10,
            .effect = .{ .written = true },
        },
    }};
    const third_accounts_b = [_]TestAccountEntry{.{
        .id = account_id,
        .fact = .{
            .address = address,
            .original = .{ .balance = 110, .code_hash = code_hash_a },
            .current = .{ .balance = 120, .nonce = 1, .code_hash = code_hash_b },
            .effect = .{ .balance_written = true, .nonce_written = true, .code_written = true },
        },
    }};
    const third_storage_b = [_]TestStorageEntry{.{
        .id = write_seven,
        .fact = .{
            .address = address,
            .key = 7,
            .original = 10,
            .current = 11,
            .effect = .{ .written = true },
        },
    }};
    const fourth_accounts = [_]TestAccountEntry{.{
        .id = account_id,
        .fact = .{
            .address = address,
            .original = .{ .balance = 120, .nonce = 1 },
            .current = .{ .balance = 120, .nonce = 2 },
            .effect = .{ .nonce_written = true },
        },
    }};
    const wipe_accounts = [_]TestAccountEntry{.{
        .id = account_id,
        .fact = .{
            .address = address,
            .original = .{ .balance = 120, .nonce = 2 },
            .current = .{},
            .effect = .{ .storage_wiped = true },
        },
    }};
    const wipe_storage = [_]TestStorageEntry{.{
        .id = read_eight,
        .fact = .{
            .address = address,
            .key = 8,
            .original = 4,
            .current = 0,
            .effect = .{ .written = true },
        },
    }};
    const batches = [_]TestBatch{
        .{ .block_access_index = 1, .view = .init(&first_accounts, &first_storage) },
        .{ .block_access_index = 3, .view = .initWithCode(&third_accounts_a, &third_storage_a, code_hash_a, &code_a) },
        .{ .block_access_index = 3, .view = .initWithCode(&third_accounts_b, &third_storage_b, code_hash_b, &code_b) },
        .{ .block_access_index = 4, .view = .init(&fourth_accounts, &.{}) },
        .{ .block_access_index = 4, .view = .init(&wipe_accounts, &wipe_storage) },
    };
    try expectMatchesGeneric(true, &claim, &batches);

    const wrong_changes = [_]bal.StorageChange{
        .{ .block_access_index = 1, .new_value = 9 },
        .{ .block_access_index = 3, .new_value = 12 },
    };
    const wrong_slots = [_]bal.SlotChanges{.{ .slot = 7, .changes = &wrong_changes }};
    const wrong_claim = [_]bal.AccountChanges{.{
        .address = address,
        .storage_changes = &wrong_slots,
        .storage_reads = &reads,
        .balance_changes = &balance_changes,
        .nonce_changes = &nonce_changes,
        .code_changes = &code_changes,
    }};
    try expectMatchesGeneric(false, &wrong_claim, &batches);

    const wrong_code = [_]u8{ 0x60, 0x03 };
    const wrong_code_changes = [_]bal.CodeChange{.{
        .block_access_index = 3,
        .new_code = &wrong_code,
    }};
    const wrong_code_claim = [_]bal.AccountChanges{.{
        .address = address,
        .storage_changes = &slots,
        .storage_reads = &reads,
        .balance_changes = &balance_changes,
        .nonce_changes = &nonce_changes,
        .code_changes = &wrong_code_changes,
    }};
    try expectMatchesGeneric(false, &wrong_code_claim, &batches);
}

test "dense claim verifier cleans every allocation failure position" {
    const changes = [_]bal.StorageChange{.{ .block_access_index = 1, .new_value = 1 }};
    const slots = [_]bal.SlotChanges{.{ .slot = 2, .changes = &changes }};
    const claim = [_]bal.AccountChanges{.{
        .address = bal.Address.fromBytes(@splat(1)),
        .storage_changes = &slots,
        .storage_reads = &.{3},
    }};
    var plan = try ClaimPlan.initAssumeValidated(std.testing.allocator, &claim);
    defer plan.deinit(std.testing.allocator);

    const Harness = struct {
        fn run(
            allocator: Allocator,
            claim_plan: *const ClaimPlan,
            expected: bal.BlockAccessList,
        ) !void {
            var verifier = try DenseClaimVerifier.init(allocator, claim_plan, expected);
            defer verifier.deinit();
        }
    };
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        Harness.run,
        .{ &plan, &claim },
    );
}
