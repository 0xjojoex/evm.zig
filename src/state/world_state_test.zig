//! `WorldState(OpenWorld)` through its executor surface and its row model.
//! Where a test reaches past the surface it names the invariant it checks.

const std = @import("std");
const address_mod = @import("../address.zig");
const AddressWord = address_mod.AddressWord;
const Address = address_mod.Address;
const addr = address_mod.addr;
const crypto = @import("../crypto.zig");
const uint256 = @import("../uint256.zig");
const Account = @import("./Account.zig");
const MemoryAccount = @import("./MemoryAccount.zig");
const Reader = @import("./Reader.zig");
const state_types = @import("../state.zig");
const OpenState = state_types.OpenState;
const bal = @import("../eth/bal.zig");

/// Row key for `addr(n)`; the machine keys accounts by word.
fn word(n: anytype) AddressWord {
    return .fromAddress(addr(n));
}

const TestReader = struct {
    account_address: Address = addr(1),
    account: Account = .{ .nonce = 3, .balance = 10 },
    code: []const u8 = &.{},
    storage_key: u256 = 2,
    storage_value: u256 = 7,
    fail_loads: bool = false,
    account_loads: usize = 0,
    storage_loads: usize = 0,

    fn reader(self: *@This()) Reader {
        return .{ .ptr = self, .vtable = &.{
            .loadAccount = loadAccount,
            .loadCode = loadCode,
            .getStorage = getStorage,
        } };
    }

    fn cast(ptr: *anyopaque) *@This() {
        return @ptrCast(@alignCast(ptr));
    }

    fn loadAccount(ptr: *anyopaque, address: Address) !?Account {
        const self = cast(ptr);
        self.account_loads += 1;
        if (self.fail_loads) return error.ReaderUnavailable;
        if (!Address.eql(self.account_address, address)) return null;
        return self.account;
    }

    fn loadCode(ptr: *anyopaque, hash: [32]u8) ![]const u8 {
        const code = cast(ptr).code;
        if (!std.mem.eql(u8, &crypto.keccak256(code), &hash)) return error.CodeUnavailable;
        return code;
    }

    fn getStorage(ptr: *anyopaque, address: Address, key: u256) !u256 {
        const self = cast(ptr);
        self.storage_loads += 1;
        if (self.fail_loads) return error.ReaderUnavailable;
        if (!Address.eql(self.account_address, address) or key != self.storage_key) return 0;
        return self.storage_value;
    }
};

fn initState(allocator: std.mem.Allocator, reader: ?Reader) OpenState {
    return OpenState.init(allocator, .init(allocator, reader));
}

/// Tests leave attempts open on purpose; the state itself must be closed.
fn abandon(state: anytype) void {
    if (!state.transaction_active) return;
    if (state.sessionActive()) state.closeSession();
    state.discardAttempt(state.lifetime.transaction);
}

fn row(state: *OpenState, address: Address) OpenState.AccountId {
    return state.world.findAccount(.fromAddress(address)).?;
}

fn slot(state: *OpenState, address: Address, key: u256) OpenState.StorageId {
    return state.world.findStorage(row(state, address), key).?;
}

test "rows hold real values from admission and outlive the transaction" {
    var backing = TestReader{};
    var state = initState(std.testing.allocator, backing.reader());
    defer state.deinit();
    defer abandon(&state);

    const attempt = state.beginAttempt();
    state.openSession();
    _ = try state.getBalance(word(1));
    _ = try state.loadStorage(word(1), 2);
    try state.warmAccount(word(2));
    state.closeSession();
    state.sealAttempt(attempt);
    state.discardAttempt(attempt);

    // Every attempt records observations; the discard released them.
    try std.testing.expect(!state.observed_attempt);
    try std.testing.expectEqual(@as(usize, 0), state.observed_accounts.items.len);
    // Warm-only keys need no parent row and disappear with the attempt.
    try std.testing.expect(state.world.findAccount(word(2)) == null);
    try std.testing.expectEqual(@as(u256, 10), state.world.accountRow(row(&state, addr(1))).current.?.balance);
    try std.testing.expectEqual(@as(u256, 7), state.world.storageRow(slot(&state, addr(1), 2)).current);
    try std.testing.expectEqual(@as(u32, 1), state.world.accountCount());
}

test "a failed parent load admits no row" {
    var backing = TestReader{ .fail_loads = true };
    var state = initState(std.testing.allocator, backing.reader());
    defer state.deinit();
    defer abandon(&state);

    const attempt = state.beginAttempt();
    state.openSession();
    try std.testing.expectError(error.ReaderUnavailable, state.getBalance(word(1)));
    try std.testing.expect(state.world.findAccount(word(1)) == null);
    backing.fail_loads = false;
    try std.testing.expectEqual(@as(u256, 10), try state.getBalance(word(1)));
    backing.fail_loads = true;
    try std.testing.expectError(error.ReaderUnavailable, state.getStorage(word(1), 2));
    try std.testing.expect(state.world.findStorage(row(&state, addr(1)), 2) == null);
    state.closeSession();
    state.sealAttempt(attempt);
    state.discardAttempt(attempt);
}

test "gas-only storage access warms without loading or observing a row" {
    var backing = TestReader{};
    var state = initState(std.testing.allocator, backing.reader());
    defer state.deinit();
    defer abandon(&state);

    const attempt = state.beginObservedAttempt();
    state.openSession();
    try std.testing.expectEqual(.cold, try state.accessStorage(word(1), 2));
    try std.testing.expect(state.isStorageWarm(word(1), 2));
    try std.testing.expect(state.world.findAccount(word(1)) == null);
    try std.testing.expectEqual(@as(usize, 0), state.observed_storage.items.len);

    const loaded = try state.loadStorage(word(1), 2);
    try std.testing.expectEqual(.warm, loaded.access_status);
    state.closeSession();
    state.sealAttempt(attempt);

    const storage = state.pendingView().observations().storage;
    try std.testing.expectEqual(@as(u32, 1), storage.len());
    const metadata = storage.metadataAt(0);
    try std.testing.expectEqual(addr(1), metadata.address);
    try std.testing.expectEqual(@as(u256, 2), metadata.key);
    try std.testing.expect(metadata.observation.value_read);
    try std.testing.expect(!metadata.effect.written);
    const record = storage.at(0);
    try std.testing.expectEqual(@as(u256, 7), record.original);
    try std.testing.expectEqual(@as(u256, 7), record.current);
}

test "rows survive scope rollback while current mutations revert" {
    var backing = TestReader{};
    var state = initState(std.testing.allocator, backing.reader());
    defer state.deinit();
    defer abandon(&state);

    _ = state.beginObservedAttempt();
    state.openSession();
    const checkpoint = state.checkpoint();

    const loaded = try state.loadStorage(word(1), 2);
    try std.testing.expectEqual(@as(u256, 7), loaded.value);
    try std.testing.expectEqual(.cold, loaded.access_status);
    try std.testing.expectEqual(.modified, try state.setStorage(word(1), 2, 9));
    state.revertToCheckpoint(checkpoint);

    const id = slot(&state, addr(1), 2);
    const storage_row = state.world.storageRow(id);
    try std.testing.expectEqual(@as(u256, 7), storage_row.current);
    const observed = state.observed_storage.items[storage_row.observation.index];
    try std.testing.expectEqual(@as(u256, 7), observed.original);
    try std.testing.expect(observed.observation.accessed);
    try std.testing.expect(observed.observation.value_read);
    try std.testing.expect(!observed.effect.written);
    try std.testing.expect(!storage_row.flags.block_dirty);
    try std.testing.expect(!state.isStorageWarm(word(1), 2));
}

test "execution original refreshes across sessions while transaction original remains" {
    var backing = TestReader{};
    var state = initState(std.testing.allocator, backing.reader());
    defer state.deinit();
    defer abandon(&state);

    const attempt = state.beginAttempt();
    state.openSession();
    try std.testing.expectEqual(.modified, try state.setStorage(word(1), 2, 9));
    state.closeSession();

    state.openSession();
    try std.testing.expectEqual(.modified, try state.setStorage(word(1), 2, 11));
    const storage_row = state.world.storageRow(slot(&state, addr(1), 2));
    try std.testing.expectEqual(
        @as(u256, 7),
        state.observed_storage.items[storage_row.observation.index].original,
    );
    try std.testing.expectEqual(@as(u256, 11), storage_row.current);
    state.closeSession();

    state.sealAttempt(attempt);
    state.retainAttempt(attempt);
    try std.testing.expectEqual(@as(u256, 11), try state.getStorage(word(1), 2));
}

test "discard drops account writes" {
    var backing = TestReader{};
    var state = initState(std.testing.allocator, backing.reader());
    defer state.deinit();
    defer abandon(&state);

    const attempt = state.beginAttempt();
    state.openSession();
    try std.testing.expectEqual(@as(u256, 10), try state.getBalance(word(1)));
    try state.setBalance(word(1), 99);
    try std.testing.expectEqual(@as(u256, 99), try state.getBalance(word(1)));
    state.closeSession();
    state.sealAttempt(attempt);
    state.discardAttempt(attempt);

    const next = state.beginAttempt();
    state.openSession();
    try std.testing.expectEqual(@as(u256, 10), try state.getBalance(word(1)));
    state.closeSession();
    state.sealAttempt(next);
    state.discardAttempt(next);
}

test "access hints reserve the block-lifetime row maps" {
    var state = initState(std.testing.allocator, null);
    defer state.deinit();
    defer abandon(&state);

    try state.reserveAcceptedAccessHint(.{ .accounts = 9, .storage_keys = 17 });
    try std.testing.expect(state.world.accounts.capacity() >= 9);
    try std.testing.expect(state.world.storage.capacity() >= 17);

    const attempt = state.beginAttempt();
    try state.reserveAccessHint(.{ .accounts = 33, .storage_keys = 1 });
    try std.testing.expect(state.world.accounts.capacity() >= 33);
    state.sealAttempt(attempt);
    state.discardAttempt(attempt);
}

test "retained account writes advance accepted state" {
    var backing = TestReader{};
    var state = initState(std.testing.allocator, backing.reader());
    defer state.deinit();
    defer abandon(&state);

    const attempt = state.beginObservedAttempt();
    state.openSession();
    // A write of the value already held is not a write and not an access.
    try state.setBalance(word(1), 10);
    const unchanged = state.world.accountRow(row(&state, addr(1)));
    try std.testing.expectEqual(@as(usize, 0), state.observed_accounts.items.len);
    try std.testing.expect(!unchanged.flags.block_changed);
    try std.testing.expect(!unchanged.flags.storage_dirty);

    try state.setBalance(word(1), 99);
    try state.setNonce(word(1), 8);
    state.closeSession();
    state.sealAttempt(attempt);
    state.retainAttempt(attempt);

    try std.testing.expectEqual(@as(u256, 99), try state.getBalance(word(1)));
    try std.testing.expectEqual(@as(u64, 8), try state.getNonce(word(1)));
    const changes = state.acceptedView().changes();
    try std.testing.expectEqual(@as(u32, 1), changes.accounts.len());
    try std.testing.expectEqual(addr(1), changes.accounts.at(0).address);
}

test "retain folds rows without allocation" {
    var failing_allocator = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var backing = TestReader{};
    var state = initState(failing_allocator.allocator(), backing.reader());
    defer state.deinit();
    defer abandon(&state);

    const attempt = state.beginAttempt();
    state.openSession();
    try state.setBalance(word(1), 99);
    try std.testing.expectEqual(.modified, try state.setStorage(word(1), 2, 9));
    try state.setCode(word(1), &.{0xaa});
    try state.setBalance(word(2), 88);
    try std.testing.expectEqual(.added, try state.setStorage(word(2), 3, 8));
    try state.setCode(word(2), &.{0xbb});
    state.closeSession();
    state.sealAttempt(attempt);

    failing_allocator.fail_index = failing_allocator.alloc_index;
    state.retainAttempt(attempt);

    try std.testing.expect(!failing_allocator.has_induced_failure);
    try std.testing.expectEqual(@as(u256, 99), try state.getBalance(word(1)));
    try std.testing.expectEqual(@as(u256, 9), try state.getStorage(word(1), 2));
    try std.testing.expectEqual(@as(u256, 88), try state.getBalance(word(2)));
    try std.testing.expectEqual(@as(u256, 8), try state.getStorage(word(2), 3));
}

test "account mutation rolls back but observation and row survive" {
    var backing = TestReader{};
    var state = initState(std.testing.allocator, backing.reader());
    defer state.deinit();
    defer abandon(&state);

    _ = state.beginAttempt();
    state.openSession();
    const checkpoint = state.checkpoint();
    try state.setNonce(word(1), 8);
    state.revertToCheckpoint(checkpoint);

    const account_row = state.world.accountRow(row(&state, addr(1)));
    try std.testing.expectEqual(@as(u64, 3), account_row.current.?.nonce);
    try std.testing.expect(!account_row.flags.block_changed);
    try std.testing.expect(!account_row.flags.storage_dirty);
    try std.testing.expectEqual(@as(u64, 3), try state.getNonce(word(1)));
    try std.testing.expectEqual(@as(usize, 1), state.observed_accounts.items.len);
}

test "transient state and owned logs follow checkpoint rollback" {
    var state = initState(std.testing.allocator, null);
    defer state.deinit();
    defer abandon(&state);

    _ = state.beginAttempt();
    state.openSession();
    const checkpoint = state.checkpoint();
    try state.setTransientStorage(word(1), 4, 12);
    const topics = [_]u256{ 1, 2 };
    try state.emitLog(.{ .address = addr(1), .topics = &topics, .data = "abc" });
    const large_data = [_]u8{0xbb} ** 1024;
    try state.emitLog(.{ .address = addr(2), .topics = &.{3}, .data = &large_data });

    const first_log = state.logs.rows.items[0];
    try std.testing.expectEqualSlices(
        u256,
        &topics,
        first_log.topics.slice(state.logs.topics.items),
    );
    try std.testing.expectEqualSlices(
        u8,
        "abc",
        first_log.data.slice(state.logs.data.items),
    );
    state.revertToCheckpoint(checkpoint);

    try std.testing.expectEqual(@as(u256, 0), state.getTransientStorage(word(1), 4));
    try std.testing.expectEqual(@as(u32, 1), state.transient_storage.count());
    try state.setTransientStorage(word(1), 4, 12);
    try state.setTransientStorage(word(1), 4, 0);
    try std.testing.expectEqual(@as(u256, 0), state.getTransientStorage(word(1), 4));
    try std.testing.expectEqual(@as(u32, 1), state.transient_storage.count());
    try std.testing.expectEqual(@as(usize, 0), state.logs.rows.items.len);
    try std.testing.expectEqual(@as(usize, 0), state.logs.topics.items.len);
    try std.testing.expectEqual(@as(usize, 0), state.logs.data.items.len);
}

test "transient root clear does not resurrect values through nested rollback" {
    var state = initState(std.testing.allocator, null);
    defer state.deinit();
    defer abandon(&state);

    _ = state.beginAttempt();
    state.openSession();
    const group_checkpoint = state.checkpoint();
    try state.setTransientStorage(word(1), 4, 12);
    try std.testing.expectEqual(@as(u256, 12), state.getTransientStorage(word(1), 4));

    state.clearTransientStorage();
    try std.testing.expectEqual(@as(u256, 0), state.getTransientStorage(word(1), 4));
    const root_checkpoint = state.checkpoint();
    try state.setTransientStorage(word(1), 4, 13);
    state.revertToCheckpoint(root_checkpoint);
    try std.testing.expectEqual(@as(u256, 0), state.getTransientStorage(word(1), 4));

    state.revertToCheckpoint(group_checkpoint);
    try std.testing.expectEqual(@as(u256, 0), state.getTransientStorage(word(1), 4));
    try std.testing.expectEqual(@as(usize, 0), state.journal.entries.items.len);
    try std.testing.expectEqual(@as(usize, 0), state.journal.transient.items.len);
}

test "compact journal order unwinds typed undo arenas" {
    var backing = TestReader{};
    var state = initState(std.testing.allocator, backing.reader());
    defer state.deinit();
    defer abandon(&state);

    _ = state.beginAttempt();
    state.openSession();
    const checkpoint = state.checkpoint();

    try std.testing.expectEqual(.cold, try state.accessAccount(word(1)));
    try state.setBalance(word(1), 99);
    try std.testing.expectEqual(.modified, try state.setStorage(word(1), 2, 9));
    try state.setTransientStorage(word(1), 4, 12);

    // The account undo also covers the storage-dirty flag in this scope.
    const journal = &state.journal;
    try std.testing.expectEqual(@as(usize, 4), journal.entries.items.len);
    try std.testing.expectEqual(@as(usize, 1), journal.accounts.items.len);
    try std.testing.expectEqual(@as(usize, 1), journal.storage.items.len);
    try std.testing.expectEqual(@as(usize, 1), journal.transient.items.len);

    state.revertToCheckpoint(checkpoint);
    try std.testing.expectEqual(@as(usize, 0), journal.entries.items.len);
    try std.testing.expectEqual(@as(usize, 0), journal.accounts.items.len);
    try std.testing.expectEqual(@as(usize, 0), journal.storage.items.len);
    try std.testing.expectEqual(@as(usize, 0), journal.transient.items.len);
    try std.testing.expectEqual(@as(u256, 10), try state.getBalance(word(1)));
    try std.testing.expectEqual(@as(u256, 7), try state.getStorage(word(1), 2));
    try std.testing.expect(!state.isAccountWarm(word(1)));
    try std.testing.expect(!state.isStorageWarm(word(1), 2));
    try std.testing.expectEqual(@as(u256, 0), state.getTransientStorage(word(1), 4));
}

test "direct storage writes do not warm slots" {
    var backing = TestReader{};
    var state = initState(std.testing.allocator, backing.reader());
    defer state.deinit();
    defer abandon(&state);

    _ = state.beginAttempt();
    state.openSession();

    try std.testing.expectEqual(.modified, try state.setStorage(word(1), 2, 9));
    try std.testing.expect(!state.isStorageWarm(word(1), 2));
    try std.testing.expectEqual(.cold, try state.accessStorage(word(1), 2));
    try std.testing.expect(state.isStorageWarm(word(1), 2));
    state.closeSession();
}

test "parent code cache keeps borrowed views stable across growth" {
    const original_code = [_]u8{ 0x60, 0x01, 0x00 };
    var backing = TestReader{
        .account = .{ .nonce = 3, .balance = 10, .code_hash = crypto.keccak256(&original_code) },
        .code = &original_code,
    };
    var state = initState(std.testing.allocator, backing.reader());
    defer state.deinit();
    defer abandon(&state);

    const original_view = try state.getCodeView(word(1));
    try std.testing.expectEqualSlices(u8, &original_code, original_view.bytes);
    try std.testing.expectEqual(@as(usize, 1), state.world.code.chunks.items.len);

    for (0..32) |index| {
        var seeded = MemoryAccount.init(std.testing.allocator);
        var code = [_]u8{0xaa} ** 200;
        code[0] = @intCast(index);
        try seeded.setCode(&code);
        try state.seedAccount(addr(@as(u64, @intCast(index + 2))), seeded);
    }

    try std.testing.expect(state.world.code.chunks.items.len > 1);
    try std.testing.expectEqualSlices(u8, &original_code, original_view.bytes);
    try std.testing.expectEqualSlices(u8, &original_code, try state.getCode(word(1)));
    try std.testing.expectEqual(@as(usize, 0), state.code.introducedLen());
}

test "code checkpoint rollback restores the hash and reclaims the introduction" {
    const original_code = [_]u8{ 0x60, 0x01, 0x00 };
    const replacement_code = [_]u8{ 0x60, 0x02, 0x60, 0x03, 0x00 };
    const account = Account{
        .nonce = 3,
        .balance = 10,
        .code_hash = crypto.keccak256(&original_code),
    };
    var backing = TestReader{ .account = account, .code = &original_code };
    var state = initState(std.testing.allocator, backing.reader());
    defer state.deinit();
    defer abandon(&state);

    const attempt = state.beginAttempt();
    state.openSession();
    try std.testing.expectEqualSlices(u8, &original_code, try state.getCode(word(1)));
    const checkpoint = state.checkpoint();

    try state.setCode(word(1), &replacement_code);
    const replacement_hash = crypto.keccak256(&replacement_code);
    try std.testing.expectEqual(uint256.fromBytes32(&replacement_hash), try state.getCodeHash(word(1)));
    try std.testing.expectEqualSlices(u8, &replacement_code, try state.getCode(word(1)));
    try std.testing.expectEqual(@as(usize, 1), state.code.introducedLen());

    state.revertToCheckpoint(checkpoint);
    const original_hash = crypto.keccak256(&original_code);
    try std.testing.expectEqual(uint256.fromBytes32(&original_hash), try state.getCodeHash(word(1)));
    try std.testing.expectEqualSlices(u8, &original_code, try state.getCode(word(1)));
    try std.testing.expectEqual(@as(usize, 0), state.code.introducedLen());
    try std.testing.expect(state.code.lookup(replacement_hash) == null);

    state.closeSession();
    state.sealAttempt(attempt);
    state.discardAttempt(attempt);
}

test "discarded code is reintroduced by a retained branch and then cleared" {
    const replacement_code = [_]u8{ 0x60, 0x02, 0x00 };
    const replacement_hash = crypto.keccak256(&replacement_code);
    var backing = TestReader{};
    var state = initState(std.testing.allocator, backing.reader());
    defer state.deinit();
    defer abandon(&state);

    const discarded = state.beginAttempt();
    state.openSession();
    try state.setCode(word(1), &replacement_code);
    state.closeSession();
    state.sealAttempt(discarded);
    state.discardAttempt(discarded);
    try std.testing.expect(state.code.lookup(replacement_hash) == null);

    const retained = state.beginAttempt();
    state.openSession();
    try std.testing.expectEqualSlices(u8, &.{}, try state.getCode(word(1)));
    try state.setCode(word(1), &replacement_code);
    state.closeSession();
    state.sealAttempt(retained);
    state.retainAttempt(retained);
    try std.testing.expect(state.acceptedView().changes().introducedCode(replacement_hash) != null);
    try std.testing.expectEqualSlices(u8, &replacement_code, try state.getCode(word(1)));
    try std.testing.expect(try state.accountHasCode(word(1)));

    const cleared = state.beginAttempt();
    state.openSession();
    try state.clearCode(word(1));
    state.closeSession();
    state.sealAttempt(cleared);
    state.retainAttempt(cleared);
    try std.testing.expectEqualSlices(u8, &.{}, try state.getCode(word(1)));
    try std.testing.expect(!try state.accountHasCode(word(1)));
}

test "seeded parent code is not an introduction when written back" {
    const code = [_]u8{ 0x60, 0x02, 0x00 };
    const code_hash = crypto.keccak256(&code);
    var state = initState(std.testing.allocator, null);
    defer state.deinit();
    defer abandon(&state);
    var seeded = MemoryAccount.init(std.testing.allocator);
    try seeded.setCode(&code);
    try state.seedAccount(addr(1), seeded);

    const attempt = state.beginObservedAttempt();
    state.openSession();
    try state.setCode(word(2), &code);
    try std.testing.expectEqualSlices(u8, &code, try state.getCode(word(2)));
    state.closeSession();
    state.sealAttempt(attempt);
    try std.testing.expect(state.pendingView().changes().introducedCode(code_hash) == null);
    try std.testing.expectEqualSlices(u8, &code, state.pendingView().observations().code(code_hash).?.bytes);
    state.retainAttempt(attempt);
    try std.testing.expectEqual(@as(usize, 0), state.code.introducedLen());
}

test "pending and accepted views expose the sealed transaction" {
    var state = initState(std.testing.allocator, null);
    defer state.deinit();
    defer abandon(&state);

    const attempt = state.beginAttempt();
    state.openSession();
    const topics = [_]u256{7};
    try state.emitLog(.{
        .address = addr(1),
        .topics = &topics,
        .data = &.{0xaa},
    });
    try state.setBalance(word(1), 9);
    state.closeSession();
    state.sealAttempt(attempt);

    const pending = state.pendingView();
    try std.testing.expectEqual(@as(usize, 1), pending.logs().len());
    const event_log = pending.logs().get(0);
    try std.testing.expectEqual(addr(1), event_log.address);
    try std.testing.expectEqualSlices(u256, &topics, event_log.topics);
    try std.testing.expectEqualSlices(u8, &.{0xaa}, event_log.data);

    state.retainAttempt(attempt);
    const accepted = state.acceptedView();
    try std.testing.expect(accepted.hasChanges());
    try std.testing.expectEqual(@as(usize, 1), state.logView().len());
    try std.testing.expectEqual(addr(1), state.logView().get(0).address);
}

test "selfdestruct finalization deletes account and masks accepted storage" {
    var backing = TestReader{};
    var state = initState(std.testing.allocator, backing.reader());
    defer state.deinit();
    defer abandon(&state);

    const written = state.beginAttempt();
    state.openSession();
    try std.testing.expectEqual(.modified, try state.setStorage(word(1), 2, 9));
    state.closeSession();
    state.sealAttempt(written);
    state.retainAttempt(written);
    const accepted = state.acceptedView().changes();
    try std.testing.expectEqual(@as(u32, 1), accepted.storage_writes.len());
    try std.testing.expectEqual(addr(1), accepted.storage_writes.at(0).address);
    try std.testing.expectEqual(@as(u256, 2), accepted.storage_writes.at(0).key);

    const destroyed = state.beginAttempt();
    state.openSession();
    {
        const destruction = state.checkpoint();
        errdefer state.revertToCheckpoint(destruction);
        _ = try state.applySelfDestruct(word(1), word(1), .{
            .clear_balance = false,
            .reset_nonce = false,
            .mark_selfdestructed = true,
        }, false);
        state.commitCheckpoint(destruction);
    }
    const before_finalize = state.checkpoint();
    try state.finalizeLifecycle(.{ .existing_account = .{
        .delete_account = true,
        .clear_storage = true,
    } });

    try std.testing.expect(state.cachedAccount(word(1)) == null);
    try std.testing.expectEqual(@as(u256, 0), try state.getStorage(word(1), 2));
    try std.testing.expect(!state.world.accountRow(state.world.findAccount(word(1)).?).flags.selfdestructed);

    state.revertToCheckpoint(before_finalize);
    try std.testing.expect(state.world.accountRow(state.world.findAccount(word(1)).?).flags.selfdestructed);
    try std.testing.expectEqual(@as(u256, 10), try state.getBalance(word(1)));
    try std.testing.expectEqual(@as(u256, 9), try state.getStorage(word(1), 2));

    try state.finalizeLifecycle(.{ .existing_account = .{
        .delete_account = true,
        .clear_storage = true,
    } });
    state.closeSession();
    state.sealAttempt(destroyed);
    state.retainAttempt(destroyed);

    try std.testing.expect(state.cachedAccount(word(1)) == null);
    try std.testing.expectEqual(@as(u256, 0), try state.getStorage(word(1), 2));
    const accepted_after_delete = state.acceptedView().changes();
    try std.testing.expectEqual(@as(u32, 1), accepted_after_delete.accounts.len());
    try std.testing.expect(accepted_after_delete.accounts.at(0).account == null);
    try std.testing.expectEqual(@as(u32, 1), accepted_after_delete.storage_wipes.len());
    try std.testing.expectEqual(addr(1), accepted_after_delete.storage_wipes.at(0));
    try std.testing.expectEqual(@as(u32, 0), accepted_after_delete.storage_writes.len());
}

test "slot first materialized after an accepted wipe starts from zero" {
    var backing = TestReader{ .storage_value = 10 };
    var state = initState(std.testing.allocator, backing.reader());
    defer state.deinit();
    defer abandon(&state);

    const destroyed = state.beginAttempt();
    state.openSession();
    {
        const destruction = state.checkpoint();
        errdefer state.revertToCheckpoint(destruction);
        _ = try state.applySelfDestruct(word(1), word(1), .{
            .clear_balance = false,
            .reset_nonce = false,
            .mark_selfdestructed = true,
        }, false);
        state.commitCheckpoint(destruction);
    }
    try state.finalizeLifecycle(.{ .existing_account = .{ .clear_storage = true } });
    state.closeSession();
    state.sealAttempt(destroyed);
    state.retainAttempt(destroyed);
    try std.testing.expect(state.world.findStorage(row(&state, addr(1)), 2) == null);

    const attempt = state.beginObservedAttempt();
    state.openSession();
    try std.testing.expectEqual(@as(u256, 0), try state.getStorage(word(1), 2));
    try std.testing.expectEqual(.added, try state.setStorage(word(1), 2, 5));
    // The row carries the parent value it was admitted with; only its
    // generation hides it.
    try std.testing.expectEqual(@as(u256, 5), state.world.storageRow(slot(&state, addr(1), 2)).current);
    state.closeSession();
    state.sealAttempt(attempt);
    const record = state.pendingView().observations().storage.at(0);
    try std.testing.expectEqual(@as(u256, 0), record.original);
    try std.testing.expectEqual(@as(u256, 5), record.current);
    state.retainAttempt(attempt);
    try std.testing.expectEqual(@as(u32, 1), state.acceptedView().changes().storage_writes.len());
}

test "Cancun existing-account selfdestruct only clears lifecycle marker" {
    var backing = TestReader{};
    var state = initState(std.testing.allocator, backing.reader());
    defer state.deinit();
    defer abandon(&state);

    const attempt = state.beginAttempt();
    state.openSession();
    {
        const destruction = state.checkpoint();
        errdefer state.revertToCheckpoint(destruction);
        _ = try state.applySelfDestruct(word(1), word(1), .{
            .clear_balance = false,
            .reset_nonce = false,
            .mark_selfdestructed = true,
        }, false);
        state.commitCheckpoint(destruction);
    }
    try state.finalizeLifecycle(.{});

    try std.testing.expect(!state.world.accountRow(state.world.findAccount(word(1)).?).flags.selfdestructed);
    try std.testing.expectEqual(@as(u256, 10), try state.getBalance(word(1)));
    try std.testing.expectEqual(@as(u256, 7), try state.getStorage(word(1), 2));

    state.closeSession();
    state.sealAttempt(attempt);
    state.retainAttempt(attempt);
    try std.testing.expectEqual(@as(u256, 10), try state.getBalance(word(1)));
    try std.testing.expectEqual(@as(u256, 7), try state.getStorage(word(1), 2));
}

test "created-account finalization removes an empty reset account" {
    var state = initState(std.testing.allocator, null);
    defer state.deinit();
    defer abandon(&state);

    const created = state.beginAttempt();
    state.openSession();
    const creation = state.checkpoint();
    try state.initializeContract(word(2), 9);
    state.commitCheckpoint(creation);
    try state.setCode(word(2), &.{ 0xaa, 0xbb });
    try std.testing.expectEqual(.added, try state.setStorage(word(2), 7, 13));
    {
        const destruction = state.checkpoint();
        errdefer state.revertToCheckpoint(destruction);
        _ = try state.applySelfDestruct(word(2), word(2), .{
            .clear_balance = false,
            .reset_nonce = false,
            .mark_selfdestructed = true,
        }, false);
        state.commitCheckpoint(destruction);
    }
    try state.finalizeLifecycle(.{ .created_account = .{
        .clear_storage = true,
        .reset_account = true,
    } });

    try std.testing.expect(state.cachedAccount(word(2)) == null);
    try std.testing.expectEqualSlices(u8, &.{}, try state.getCode(word(2)));
    try std.testing.expectEqual(@as(u256, 0), try state.getStorage(word(2), 7));
    try std.testing.expect(!state.createdInTransaction(word(2)));
    try std.testing.expect(!state.world.accountRow(state.world.findAccount(word(2)).?).flags.selfdestructed);

    state.closeSession();
    state.sealAttempt(created);
    state.retainAttempt(created);

    const rewritten = state.beginAttempt();
    state.openSession();
    try std.testing.expectEqual(.added, try state.setStorage(word(2), 7, 11));
    state.closeSession();
    state.sealAttempt(rewritten);
    state.retainAttempt(rewritten);

    try std.testing.expectEqual(@as(u256, 11), try state.getStorage(word(2), 7));
    try std.testing.expectEqual(@as(u256, 0), try state.getStorage(word(2), 8));
}

test "created-account finalization preserves a balance-only account" {
    var state = initState(std.testing.allocator, null);
    defer state.deinit();
    defer abandon(&state);

    _ = state.beginAttempt();
    state.openSession();
    try state.setBalance(word(2), 1);
    const creation = state.checkpoint();
    try state.initializeContract(word(2), 9);
    state.commitCheckpoint(creation);
    try state.setCode(word(2), &.{0xaa});
    try std.testing.expectEqual(.added, try state.setStorage(word(2), 7, 13));
    {
        const destruction = state.checkpoint();
        errdefer state.revertToCheckpoint(destruction);
        _ = try state.applySelfDestruct(word(2), word(2), .{
            .clear_balance = false,
            .reset_nonce = false,
            .mark_selfdestructed = true,
        }, false);
        state.commitCheckpoint(destruction);
    }
    try state.finalizeLifecycle(.{ .created_account = .{
        .clear_storage = true,
        .reset_account = true,
    } });

    const account = state.cachedAccount(word(2)).?;
    try std.testing.expectEqual(@as(u64, 0), account.nonce);
    try std.testing.expectEqual(@as(u256, 1), account.balance);
    try std.testing.expectEqualSlices(u8, &.{}, try state.getCode(word(2)));
    try std.testing.expectEqual(@as(u256, 0), try state.getStorage(word(2), 7));
}

test "finalization allocation failure preserves enclosing transaction" {
    var failing_allocator = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var backing = TestReader{};
    var state = initState(failing_allocator.allocator(), backing.reader());
    defer state.deinit();
    defer abandon(&state);

    _ = state.beginAttempt();
    state.openSession();
    try std.testing.expectEqual(@as(u256, 7), try state.getStorage(word(1), 2));
    {
        const destruction = state.checkpoint();
        errdefer state.revertToCheckpoint(destruction);
        _ = try state.applySelfDestruct(word(1), word(1), .{
            .clear_balance = false,
            .reset_nonce = false,
            .mark_selfdestructed = true,
        }, false);
        state.commitCheckpoint(destruction);
    }
    const journal_len = state.journalEntryCount();

    failing_allocator.fail_index = failing_allocator.alloc_index;
    try std.testing.expectError(error.OutOfMemory, state.finalizeLifecycle(.{ .existing_account = .{
        .delete_account = true,
        .clear_storage = true,
    } }));

    try std.testing.expect(failing_allocator.has_induced_failure);
    try std.testing.expectEqual(journal_len, state.journalEntryCount());
    try std.testing.expect(state.world.accountRow(state.world.findAccount(word(1)).?).flags.selfdestructed);
    try std.testing.expectEqual(@as(u256, 10), state.cachedAccount(word(1)).?.balance);
    try std.testing.expectEqual(@as(u256, 7), try state.getStorage(word(1), 2));
}

test "storage records keep the written value through a lifecycle wipe" {
    var backing = TestReader{ .storage_value = 10 };
    var state = initState(std.testing.allocator, backing.reader());
    defer state.deinit();
    defer abandon(&state);

    const attempt = state.beginObservedAttempt();
    state.openSession();
    try std.testing.expectEqual(.modified, try state.setStorage(word(1), 2, 5));
    try std.testing.expectEqual(.added, try state.setStorage(word(1), 3, 7));
    {
        const destruction = state.checkpoint();
        errdefer state.revertToCheckpoint(destruction);
        _ = try state.applySelfDestruct(word(1), word(1), .{
            .clear_balance = false,
            .reset_nonce = false,
            .mark_selfdestructed = true,
        }, false);
        state.commitCheckpoint(destruction);
    }
    try state.finalizeLifecycle(.{ .existing_account = .{ .clear_storage = true } });
    state.closeSession();
    state.sealAttempt(attempt);

    const storage = state.pendingView().observations().storage;
    // The wipe hides the write from execution but not from the record;
    // the account's wipe effect makes consumers read every slot.
    const hidden = storage.at(0);
    try std.testing.expectEqual(@as(u256, 10), hidden.original);
    try std.testing.expectEqual(@as(u256, 5), hidden.current);
    try std.testing.expect(hidden.effect.written);
    const rewritten = storage.at(1);
    try std.testing.expectEqual(@as(u256, 0), rewritten.original);
    try std.testing.expectEqual(@as(u256, 7), rewritten.current);
    try std.testing.expect(state.pendingView().observations().accounts.at(0).effect.storage_wiped);
}

test "lifecycle listing is per transaction" {
    var state = initState(std.testing.allocator, null);
    defer state.deinit();
    defer abandon(&state);

    const discarded = state.beginAttempt();
    state.openSession();
    {
        const destruction = state.checkpoint();
        errdefer state.revertToCheckpoint(destruction);
        _ = try state.applySelfDestruct(word(1), word(1), .{
            .clear_balance = false,
            .reset_nonce = false,
            .mark_selfdestructed = true,
        }, false);
        state.commitCheckpoint(destruction);
    }
    try std.testing.expectEqual(@as(usize, 1), state.lifecycle_accounts.items.len);
    state.closeSession();
    state.discardAttempt(discarded);
    try std.testing.expectEqual(@as(usize, 0), state.lifecycle_accounts.items.len);

    _ = state.beginAttempt();
    state.openSession();
    {
        const destruction = state.checkpoint();
        errdefer state.revertToCheckpoint(destruction);
        _ = try state.applySelfDestruct(word(1), word(1), .{
            .clear_balance = false,
            .reset_nonce = false,
            .mark_selfdestructed = true,
        }, false);
        state.commitCheckpoint(destruction);
    }
    try std.testing.expectEqual(@as(usize, 1), state.lifecycle_accounts.items.len);
}

test "sparse lifecycle candidates are compact and survive marker rollback" {
    var state = initState(std.testing.allocator, null);
    defer state.deinit();
    defer abandon(&state);

    _ = state.beginAttempt();
    state.openSession();
    const checkpoint = state.checkpoint();

    try state.initializeContract(word(1), 1);
    {
        const destruction = state.checkpoint();
        errdefer state.revertToCheckpoint(destruction);
        _ = try state.applySelfDestruct(word(1), word(1), .{
            .clear_balance = false,
            .reset_nonce = false,
            .mark_selfdestructed = true,
        }, false);
        state.commitCheckpoint(destruction);
    }
    try std.testing.expectEqual(@as(usize, 1), state.lifecycle_accounts.items.len);

    state.revertToCheckpoint(checkpoint);
    try std.testing.expect(!state.createdInTransaction(word(1)));
    try std.testing.expect(!state.world.accountRow(state.world.findAccount(word(1)).?).flags.selfdestructed);
    try std.testing.expectEqual(@as(usize, 1), state.lifecycle_accounts.items.len);

    {
        const destruction = state.checkpoint();

        errdefer state.revertToCheckpoint(destruction);

        _ = try state.applySelfDestruct(word(1), word(1), .{
            .clear_balance = false,

            .reset_nonce = false,

            .mark_selfdestructed = true,
        }, false);

        state.commitCheckpoint(destruction);
    }
    try std.testing.expectEqual(@as(usize, 1), state.lifecycle_accounts.items.len);
}

test "pending changes are transaction local and accepted changes accumulate" {
    var state = initState(std.testing.allocator, null);
    defer state.deinit();
    defer abandon(&state);

    const first_code = [_]u8{0xaa};
    const first_hash = crypto.keccak256(&first_code);
    const first = state.beginAttempt();
    state.openSession();
    try state.setBalance(word(1), 11);
    try state.setCode(word(1), &first_code);
    _ = try state.setStorage(word(1), 1, 111);
    state.closeSession();
    state.sealAttempt(first);
    state.retainAttempt(first);

    const accepted_first = state.acceptedView().changes();
    try std.testing.expectEqual(@as(u32, 1), accepted_first.accounts.len());
    try std.testing.expectEqual(addr(1), accepted_first.accounts.at(0).address);
    try std.testing.expectEqual(@as(u32, 1), accepted_first.storage_writes.len());
    try std.testing.expectEqualSlices(u8, &first_code, accepted_first.introducedCode(first_hash).?.bytes);

    const second_code = [_]u8{0xbb};
    const second_hash = crypto.keccak256(&second_code);
    const second = state.beginAttempt();
    state.openSession();
    try state.setBalance(word(2), 22);
    try state.setCode(word(2), &second_code);
    _ = try state.setStorage(word(2), 2, 222);
    state.closeSession();
    state.sealAttempt(second);

    const pending = state.pendingView().changes();
    try std.testing.expectEqual(@as(u32, 1), pending.accounts.len());
    try std.testing.expectEqual(addr(2), pending.accounts.at(0).address);
    try std.testing.expectEqual(@as(u32, 1), pending.storage_writes.len());
    try std.testing.expect(pending.introducedCode(first_hash) == null);
    try std.testing.expectEqualSlices(u8, &second_code, pending.introducedCode(second_hash).?.bytes);
    const accepted_pending = state.pendingView().accepted().changes();
    try std.testing.expectEqual(@as(u32, 1), accepted_pending.accounts.len());
    try std.testing.expectEqual(addr(1), accepted_pending.accounts.at(0).address);

    state.retainAttempt(second);
    const accepted_second = state.acceptedView().changes();
    try std.testing.expectEqual(@as(u32, 2), accepted_second.accounts.len());
    try std.testing.expectEqual(@as(u32, 2), accepted_second.storage_writes.len());
    try std.testing.expectEqualSlices(u8, &first_code, accepted_second.introducedCode(first_hash).?.bytes);
    try std.testing.expectEqualSlices(u8, &second_code, accepted_second.introducedCode(second_hash).?.bytes);
}

test "first storage undo preserves accepted baseline across scopes and attempts" {
    var state = initState(std.testing.allocator, null);
    defer state.deinit();
    defer abandon(&state);

    const first = state.beginAttempt();
    state.openSession();
    _ = try state.setStorage(word(1), 1, 11);
    _ = try state.setStorage(word(1), 2, 22);
    state.closeSession();
    state.sealAttempt(first);
    state.retainAttempt(first);

    const second = state.beginAttempt();
    state.openSession();
    // This slot's first undo occupied index 1 in the previous attempt. The new
    // journal starts empty, and observing the slot must not supply an undo.
    const loaded = try state.loadStorage(word(1), 2);
    try std.testing.expectEqual(@as(u256, 22), loaded.value);
    const outer = state.checkpoint();
    _ = try state.setStorage(word(1), 2, 33);
    const inner = state.checkpoint();
    _ = try state.setStorage(word(1), 2, 44);
    state.revertToCheckpoint(inner);
    try std.testing.expectEqual(@as(u256, 33), try state.getStorage(word(1), 2));
    state.revertToCheckpoint(outer);
    try std.testing.expectEqual(@as(u256, 22), try state.getStorage(word(1), 2));

    // Recapture after the first write was reverted, then preserve that baseline
    // when a later scope commits another write.
    _ = try state.setStorage(word(1), 2, 55);
    const committed = state.checkpoint();
    _ = try state.setStorage(word(1), 2, 66);
    state.commitCheckpoint(committed);
    state.closeSession();
    state.sealAttempt(second);

    const pending = state.pendingView().changes().storage_writes;
    try std.testing.expectEqual(@as(u32, 1), pending.len());
    try std.testing.expectEqual(@as(u256, 2), pending.at(0).key);
    try std.testing.expectEqual(@as(u256, 66), pending.at(0).value);
    const accepted = state.pendingView().accepted().changes().storage_writes;
    try std.testing.expectEqual(@as(u32, 2), accepted.len());
    try std.testing.expectEqual(@as(u256, 11), accepted.at(0).value);
    try std.testing.expectEqual(@as(u256, 2), accepted.at(1).key);
    try std.testing.expectEqual(@as(u256, 22), accepted.at(1).value);
    state.discardAttempt(second);
    try std.testing.expectEqual(@as(u256, 22), try state.getStorage(word(1), 2));
}

test "checkpoint rollback truncates dense change ids" {
    var state = initState(std.testing.allocator, null);
    defer state.deinit();
    defer abandon(&state);

    const attempt = state.beginAttempt();
    state.openSession();
    const checkpoint = state.checkpoint();
    try state.setBalance(word(1), 1);
    _ = try state.setStorage(word(1), 1, 11);
    state.revertToCheckpoint(checkpoint);

    try state.setBalance(word(2), 2);
    _ = try state.setStorage(word(2), 2, 22);
    state.closeSession();
    state.sealAttempt(attempt);

    const changes = state.pendingView().changes();
    try std.testing.expectEqual(@as(u32, 1), changes.accounts.len());
    try std.testing.expectEqual(addr(2), changes.accounts.at(0).address);
    try std.testing.expectEqual(@as(u32, 1), changes.storage_writes.len());
    try std.testing.expectEqual(addr(2), changes.storage_writes.at(0).address);

    state.retainAttempt(attempt);
    const accepted = state.acceptedView().changes();
    try std.testing.expectEqual(@as(u32, 1), accepted.accounts.len());
    try std.testing.expectEqual(@as(u32, 1), accepted.storage_writes.len());
}

test "accepted branch snapshot restores cumulative state and drops later rows" {
    var state = initState(std.testing.allocator, null);
    defer state.deinit();
    defer abandon(&state);

    const baseline_code = [_]u8{0xaa};
    const baseline_hash = crypto.keccak256(&baseline_code);
    const baseline = state.beginAttempt();
    state.openSession();
    try state.setBalance(word(1), 11);
    try state.setCode(word(1), &baseline_code);
    try std.testing.expectEqual(.added, try state.setStorage(word(1), 2, 22));
    try state.emitLog(.{
        .address = addr(1),
        .topics = &.{3},
        .data = &.{0x44},
    });
    state.closeSession();
    state.sealAttempt(baseline);
    state.retainAttempt(baseline);

    var snapshot = try state.branchSnapshot();
    defer snapshot.deinit();

    const destroyed = state.beginAttempt();
    state.openSession();
    {
        const destruction = state.checkpoint();
        errdefer state.revertToCheckpoint(destruction);
        _ = try state.applySelfDestruct(word(1), word(1), .{
            .clear_balance = false,
            .reset_nonce = false,
            .mark_selfdestructed = true,
        }, false);
        state.commitCheckpoint(destruction);
    }
    try state.finalizeLifecycle(.{ .existing_account = .{
        .delete_account = true,
        .clear_storage = true,
    } });
    state.closeSession();
    state.sealAttempt(destroyed);
    state.retainAttempt(destroyed);
    try std.testing.expect(state.cachedAccount(word(1)) == null);
    try std.testing.expectEqual(@as(u32, 1), state.acceptedView().changes().storage_wipes.len());

    var first_restore = try snapshot.clone();
    defer first_restore.deinit();
    state.restoreBranch(&first_restore);
    try std.testing.expectEqual(@as(u256, 11), try state.getBalance(word(1)));
    try std.testing.expectEqual(@as(u256, 22), try state.getStorage(word(1), 2));
    try std.testing.expectEqualSlices(u8, &baseline_code, try state.getCode(word(1)));
    try std.testing.expectEqual(@as(usize, 1), state.logView().len());
    const restored_changes = state.acceptedView().changes();
    try std.testing.expectEqual(@as(u32, 0), restored_changes.storage_wipes.len());
    try std.testing.expect(restored_changes.introducedCode(baseline_hash) != null);

    const later = state.beginAttempt();
    state.openSession();
    try state.setBalance(word(2), 33);
    _ = try state.setStorage(word(2), 9, 99);
    state.closeSession();
    state.sealAttempt(later);
    state.retainAttempt(later);
    try std.testing.expectEqual(@as(u256, 33), try state.getBalance(word(2)));
    try std.testing.expectEqual(@as(u32, 2), state.world.accountCount());

    var second_restore = try snapshot.clone();
    defer second_restore.deinit();
    state.restoreBranch(&second_restore);
    // Rows admitted after the capture die with the branch.
    try std.testing.expectEqual(@as(u32, 1), state.world.accountCount());
    try std.testing.expect(state.world.findAccount(word(2)) == null);
    try std.testing.expectEqual(@as(u256, 0), try state.getBalance(word(2)));
    try std.testing.expectEqual(@as(u256, 11), try state.getBalance(word(1)));
    try std.testing.expectEqual(@as(u32, 1), state.acceptedView().changes().accounts.len());
}

test "branch restoration discards the active attempt and preserves identity progression" {
    for ([_]bool{ false, true }) |sealed| {
        var state = initState(std.testing.allocator, null);
        defer state.deinit();
        defer abandon(&state);
        var snapshot = try state.branchSnapshot();
        defer snapshot.deinit();

        const abandoned = state.beginAttempt();
        state.openSession();
        try state.setBalance(word(1), 11);
        state.closeSession();
        if (sealed) state.sealAttempt(abandoned);
        state.restoreBranch(&snapshot);
        try std.testing.expect(!state.transaction_active);
        try std.testing.expect(!state.acceptedView().hasChanges());
        try std.testing.expectEqual(@as(u32, 0), state.world.accountCount());

        const next = state.beginAttempt();
        try std.testing.expect(next != abandoned);
        try state.setBalance(word(1), 22);
        state.sealAttempt(next);
        state.retainAttempt(next);
        try std.testing.expectEqual(@as(u256, 22), try state.getBalance(word(1)));
    }
}

test "accepted branch snapshot clone failure leaves current state unchanged" {
    var failing_allocator = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var state = initState(failing_allocator.allocator(), null);
    defer state.deinit();
    defer abandon(&state);

    const baseline = state.beginAttempt();
    state.openSession();
    try state.setBalance(word(1), 11);
    state.closeSession();
    state.sealAttempt(baseline);
    state.retainAttempt(baseline);
    var snapshot = try state.branchSnapshot();
    defer snapshot.deinit();

    const later = state.beginAttempt();
    state.openSession();
    try state.setBalance(word(1), 22);
    state.closeSession();
    state.sealAttempt(later);
    state.retainAttempt(later);

    failing_allocator.fail_index = failing_allocator.alloc_index;
    try std.testing.expectError(error.OutOfMemory, snapshot.clone());
    try std.testing.expect(failing_allocator.has_induced_failure);
    try std.testing.expectEqual(@as(u256, 22), try state.getBalance(word(1)));

    failing_allocator.fail_index = std.math.maxInt(usize);
    var restore = try snapshot.clone();
    defer restore.deinit();
    state.restoreBranch(&restore);
    try std.testing.expectEqual(@as(u256, 11), try state.getBalance(word(1)));
}

test "accepted branch restore does not allocate after capture" {
    var failing_allocator = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var state = initState(failing_allocator.allocator(), null);
    defer state.deinit();
    defer abandon(&state);

    const baseline = state.beginAttempt();
    state.openSession();
    try state.setBalance(word(1), 11);
    state.closeSession();
    state.sealAttempt(baseline);
    state.retainAttempt(baseline);
    var snapshot = try state.branchSnapshot();
    defer snapshot.deinit();

    const later = state.beginAttempt();
    state.openSession();
    try state.setBalance(word(1), 22);
    try state.setBalance(word(2), 5);
    state.closeSession();
    state.sealAttempt(later);
    state.retainAttempt(later);

    failing_allocator.fail_index = failing_allocator.alloc_index;
    state.restoreBranch(&snapshot);
    try std.testing.expect(!failing_allocator.has_induced_failure);
    try std.testing.expectEqual(@as(u256, 11), try state.getBalance(word(1)));
}

test "discard accepted resets the world and invalidates earlier snapshots" {
    var backing = TestReader{};
    var state = initState(std.testing.allocator, backing.reader());
    defer state.deinit();
    defer abandon(&state);

    const attempt = state.beginAttempt();
    state.openSession();
    try state.setBalance(word(1), 99);
    try state.setCode(word(1), &.{0xaa});
    state.closeSession();
    state.sealAttempt(attempt);
    state.retainAttempt(attempt);
    try std.testing.expect(state.acceptedView().hasChanges());

    state.discardAccepted();
    try std.testing.expect(!state.acceptedView().hasChanges());
    try std.testing.expectEqual(@as(u32, 0), state.world.accountCount());
    try std.testing.expectEqual(@as(usize, 0), state.code.introducedLen());
    try std.testing.expectEqual(@as(u256, 10), try state.getBalance(word(1)));
    try std.testing.expectEqual(@as(u64, 1), state.world_epoch);
}

test "discard accepted rewinds the clock with the rows" {
    var backing = TestReader{};
    var state = initState(std.testing.allocator, backing.reader());
    defer state.deinit();
    defer abandon(&state);

    const first = state.beginAttempt();
    state.openSession();
    try state.warmAccount(word(1));
    try std.testing.expect(state.isAccountWarm(word(1)));
    state.closeSession();
    state.sealAttempt(first);
    state.retainAttempt(first);
    try std.testing.expect(state.clock != 0);

    state.discardAccepted();
    try std.testing.expectEqual(@as(u32, 0), state.clock);

    // The root generation `first` took is reissued. The rows it stamped were
    // reset with the epoch, so the reuse cannot resurrect their warmth.
    const second = state.beginAttempt();
    state.openSession();
    try std.testing.expectEqual(first, second);
    try std.testing.expect(!state.isAccountWarm(word(1)));
}

test "seeding advances the epoch without rewinding the clock" {
    var backing = TestReader{};
    var state = initState(std.testing.allocator, backing.reader());
    defer state.deinit();
    defer abandon(&state);

    const first = state.beginAttempt();
    state.openSession();
    try state.warmAccount(word(1));
    state.closeSession();
    state.sealAttempt(first);
    state.retainAttempt(first);

    // Retain keeps the row and its warm stamp. Seeding another account bumps
    // the epoch for snapshots but must not reissue `first`: a rewound clock
    // would make the surviving stamp read as warm in the next attempt.
    var seeded = MemoryAccount.init(std.testing.allocator);
    seeded.account = .{ .balance = 5 };
    defer seeded.deinit();
    try state.seedAccount(addr(2), seeded);
    try std.testing.expect(state.clock != 0);

    const second = state.beginAttempt();
    state.openSession();
    try std.testing.expect(first != second);
    try std.testing.expect(!state.isAccountWarm(word(1)));
}

test "pre-Spurious-Dragon world keeps a loaded empty account" {
    var backing = TestReader{ .account = .{} };
    var state = initState(std.testing.allocator, backing.reader());
    defer state.deinit();
    defer abandon(&state);
    try std.testing.expect(!try state.accountExists(word(1)));
    state.world.retains_empty_accounts = true;
    state.world.resetRows();
    try std.testing.expect(try state.accountExists(word(1)));
}

test "open state transaction cleans every allocation failure" {
    const Harness = struct {
        fn run(allocator: std.mem.Allocator) !void {
            var backing = TestReader{};
            var state = initState(allocator, backing.reader());
            defer state.deinit();
            defer abandon(&state);
            const attempt = state.beginObservedAttempt();
            state.openSession();
            try state.setBalance(word(1), 4);
            try state.setCode(word(1), &.{0x5f});
            try state.setTransientStorage(word(1), 8, 12);
            try state.emitLog(.{
                .address = addr(1),
                .topics = &.{1},
                .data = &.{2},
            });
            _ = try state.getStorage(word(1), 2);
            _ = try state.getStorage(word(3), 4);
            const nested = state.checkpoint();
            var nested_active = true;
            errdefer if (nested_active) state.revertToCheckpoint(nested);
            try state.warmAccount(word(2));
            try state.warmStorage(word(2), 7);
            _ = try state.setStorage(word(1), 2, 9);
            {
                const destruction = state.checkpoint();
                errdefer state.revertToCheckpoint(destruction);
                _ = try state.applySelfDestruct(word(3), word(3), .{
                    .clear_balance = false,
                    .reset_nonce = false,
                    .mark_selfdestructed = true,
                }, false);
                state.commitCheckpoint(destruction);
            }
            state.revertToCheckpoint(nested);
            nested_active = false;
            try state.finalizeLifecycle(.{ .existing_account = .{ .delete_account = true, .clear_storage = true } });
            state.closeSession();
            state.sealAttempt(attempt);
            state.retainAttempt(attempt);
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Harness.run, .{});
}

test "pre-scope writes are the scope baseline and revert only with the attempt" {
    var backing = TestReader{};
    var state = initState(std.testing.allocator, backing.reader());
    defer state.deinit();
    defer abandon(&state);

    const attempt = state.beginObservedAttempt();
    try state.setBalance(word(1), 17);
    _ = try state.setStorage(word(1), 2, 9);
    try std.testing.expectEqual(@as(usize, 2), state.journalEntryCount());

    state.openSession();
    const checkpoint = state.checkpoint();
    try state.setBalance(word(1), 99);
    _ = try state.setStorage(word(1), 2, 11);
    state.revertToCheckpoint(checkpoint);
    try std.testing.expectEqual(@as(u256, 17), try state.getBalance(word(1)));
    try std.testing.expectEqual(@as(u256, 9), try state.getStorage(word(1), 2));
    state.closeSession();
    // A second execution session classifies against the earlier attempt write.
    state.openSession();
    const probe = state.checkpoint();
    try std.testing.expectEqual(.modified, try state.setStorage(word(1), 2, 11));
    state.revertToCheckpoint(probe);
    state.closeSession();
    state.sealAttempt(attempt);
    try std.testing.expectEqual(@as(u32, 1), state.pendingView().changes().accounts.len());
    state.discardAttempt(attempt);

    try std.testing.expectEqual(@as(u256, 10), try state.getBalance(word(1)));
    try std.testing.expectEqual(@as(u256, 7), try state.getStorage(word(1), 2));
}

test "accepted branch snapshot restores compacted storage change ids" {
    var state = initState(std.testing.allocator, null);
    defer state.deinit();
    defer abandon(&state);

    const baseline = state.beginAttempt();
    state.openSession();
    try state.setBalance(word(1), 1);
    try state.setBalance(word(2), 1);
    try std.testing.expectEqual(.added, try state.setStorage(word(1), 1, 11));
    try std.testing.expectEqual(.added, try state.setStorage(word(2), 2, 22));
    state.closeSession();
    state.sealAttempt(baseline);
    state.retainAttempt(baseline);

    var snapshot = try state.branchSnapshot();
    defer snapshot.deinit();

    const wiped = state.beginAttempt();
    state.openSession();
    {
        const destruction = state.checkpoint();
        errdefer state.revertToCheckpoint(destruction);
        _ = try state.applySelfDestruct(word(1), word(1), .{
            .clear_balance = false,
            .reset_nonce = false,
            .mark_selfdestructed = true,
        }, false);
        state.commitCheckpoint(destruction);
    }
    try state.finalizeLifecycle(.{ .existing_account = .{ .clear_storage = true } });
    state.closeSession();
    state.sealAttempt(wiped);
    state.retainAttempt(wiped);

    state.restoreBranch(&snapshot);
    const changes = state.acceptedView().changes();
    try std.testing.expectEqual(@as(u32, 2), changes.storage_writes.len());
    try std.testing.expectEqual(addr(1), changes.storage_writes.at(0).address);
    try std.testing.expectEqual(@as(u256, 1), changes.storage_writes.at(0).key);
    try std.testing.expectEqual(addr(2), changes.storage_writes.at(1).address);
    try std.testing.expectEqual(@as(u256, 2), changes.storage_writes.at(1).key);
}

test "scope revert compaction keeps the accepted prefix and deduplicates the attempt suffix" {
    var state = initState(std.testing.allocator, null);
    defer state.deinit();
    defer abandon(&state);

    const accepted = state.beginAttempt();
    state.openSession();
    try state.setBalance(word(1), 1);
    _ = try state.setStorage(word(1), 1, 11);
    state.closeSession();
    state.sealAttempt(accepted);
    state.retainAttempt(accepted);

    const reverted = state.beginAttempt();
    state.openSession();
    const scope = state.checkpoint();
    try state.setBalance(word(1), 2);
    try state.setBalance(word(2), 2);
    _ = try state.setStorage(word(1), 1, 12);
    _ = try state.setStorage(word(2), 2, 21);
    state.revertToCheckpoint(scope);
    // Redirty after the revert: each row must be listed once, prefix rows included.
    try state.setBalance(word(1), 3);
    try state.setBalance(word(2), 3);
    _ = try state.setStorage(word(1), 1, 13);
    _ = try state.setStorage(word(2), 2, 22);
    state.closeSession();
    state.sealAttempt(reverted);
    state.retainAttempt(reverted);

    const changes = state.acceptedView().changes();
    try std.testing.expectEqual(@as(u32, 2), changes.accounts.len());
    try std.testing.expectEqual(addr(1), changes.accounts.at(0).address);
    try std.testing.expectEqual(addr(2), changes.accounts.at(1).address);
    try std.testing.expectEqual(@as(u32, 2), changes.storage_writes.len());
    try std.testing.expectEqual(state_types.StorageChange{ .address = addr(1), .key = 1, .value = 13 }, changes.storage_writes.at(0));
    try std.testing.expectEqual(state_types.StorageChange{ .address = addr(2), .key = 2, .value = 22 }, changes.storage_writes.at(1));
}

test "warm-only keys avoid parent I/O and preserve warmth through later row rollback" {
    var backing = TestReader{ .fail_loads = true };
    var state = initState(std.testing.allocator, backing.reader());
    defer state.deinit();
    defer abandon(&state);

    const attempt = state.beginObservedAttempt();
    state.openSession();
    try state.warmAccount(word(1));
    try state.warmStorage(word(1), 2);
    try state.warmAccount(word(99));
    try state.warmStorage(word(99), 3);
    try std.testing.expectEqual(@as(usize, 0), backing.account_loads);
    try std.testing.expectEqual(@as(usize, 0), backing.storage_loads);
    try std.testing.expectEqual(@as(u32, 0), state.world.accountCount());
    try std.testing.expectEqual(@as(usize, 0), state.observed_accounts.items.len);
    try std.testing.expectEqual(@as(usize, 0), state.observed_storage.items.len);

    const checkpoint = state.checkpoint();
    try std.testing.expectError(error.ReaderUnavailable, state.getBalance(word(1)));
    try std.testing.expect(state.isAccountWarm(word(1)));
    backing.fail_loads = false;
    try std.testing.expectEqual(.warm, try state.accessAccount(word(1)));
    try std.testing.expectEqual(.warm, (try state.loadStorage(word(1), 2)).access_status);
    state.revertToCheckpoint(checkpoint);
    // These rows were loaded inside the reverted scope, but warmth predates it.
    try std.testing.expect(state.isAccountWarm(word(1)));
    try std.testing.expect(state.isStorageWarm(word(1), 2));
    try std.testing.expectEqual(.warm, try state.accessAccount(word(1)));
    try std.testing.expectEqual(.warm, (try state.loadStorage(word(1), 2)).access_status);
    state.closeSession();
    state.sealAttempt(attempt);
    state.retainAttempt(attempt);

    _ = state.beginAttempt();
    state.openSession();
    try std.testing.expectEqual(.cold, try state.accessAccount(word(1)));
    try std.testing.expectEqual(.cold, (try state.loadStorage(word(1), 2)).access_status);
    try std.testing.expect(!state.isAccountWarm(word(99)));
    try std.testing.expect(!state.isStorageWarm(word(99), 3));
}

test "reverting warm-only keys also makes subsequently loaded rows cold" {
    var backing = TestReader{};
    var state = initState(std.testing.allocator, backing.reader());
    defer state.deinit();
    defer abandon(&state);
    _ = state.beginAttempt();
    state.openSession();

    const checkpoint = state.checkpoint();
    try state.warmAccount(word(1));
    try state.warmStorage(word(1), 2);
    try std.testing.expectEqual(.warm, try state.accessAccount(word(1)));
    try std.testing.expectEqual(.warm, (try state.loadStorage(word(1), 2)).access_status);
    state.revertToCheckpoint(checkpoint);
    try std.testing.expect(!state.isAccountWarm(word(1)));
    try std.testing.expect(!state.isStorageWarm(word(1), 2));
    try std.testing.expectEqual(.cold, try state.accessAccount(word(1)));
    try std.testing.expectEqual(.cold, (try state.loadStorage(word(1), 2)).access_status);

    const missing = state.checkpoint();
    try state.warmAccount(word(99));
    try state.warmStorage(word(99), 3);
    state.revertToCheckpoint(missing);
    try std.testing.expect(!state.isAccountWarm(word(99)));
    try std.testing.expect(!state.isStorageWarm(word(99), 3));
    try state.warmAccount(word(99));
    try state.warmStorage(word(99), 3);
    try std.testing.expect(state.isAccountWarm(word(99)));
    try std.testing.expect(state.isStorageWarm(word(99), 3));
}

test "reseeding invalidates branch snapshots before success or partial failure" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var state = initState(failing.allocator(), null);
    defer state.deinit();

    var first = MemoryAccount.init(std.testing.allocator);
    first.account.balance = 1;
    try first.storage.put(1, 11);
    try state.seedAccount(addr(1), first);
    var snapshot = try state.branchSnapshot();
    defer snapshot.deinit();

    var second = MemoryAccount.init(std.testing.allocator);
    second.account.balance = 2;
    try second.storage.put(2, 22);
    try state.seedAccount(addr(1), second);
    try std.testing.expect(state.world_epoch != snapshot.world_epoch);
    var later = try state.branchSnapshot();
    defer later.deinit();

    var replacement = MemoryAccount.init(std.testing.allocator);
    replacement.account.balance = 3;
    for (0..32) |i| try replacement.storage.put(i, i + 1);
    failing.fail_index = failing.alloc_index;
    try std.testing.expectError(error.OutOfMemory, state.seedAccount(addr(1), replacement));
    try std.testing.expect(failing.has_induced_failure);
    try std.testing.expect(state.world_epoch != later.world_epoch);
}

test "branch snapshot capture and clone clean every allocation failure" {
    const Scenario = struct {
        fn run(allocator: std.mem.Allocator) !void {
            var state = initState(allocator, null);
            defer state.deinit();
            defer abandon(&state);
            const attempt = state.beginAttempt();
            state.openSession();
            try state.setBalance(word(1), 1);
            {
                const creation = state.checkpoint();
                errdefer state.revertToCheckpoint(creation);
                try state.initializeContract(word(1), 1);
                state.commitCheckpoint(creation);
            }
            _ = try state.setStorage(word(1), 2, 22);
            try state.emitLog(.{ .address = addr(1), .topics = &.{1}, .data = &.{2} });
            try state.finalizeLifecycle(.{});
            state.closeSession();
            state.sealAttempt(attempt);
            state.retainAttempt(attempt);
            var snapshot = try state.branchSnapshot();
            defer snapshot.deinit();
            var cloned = try snapshot.clone();
            defer cloned.deinit();
            state.restoreBranch(&cloned);
            try std.testing.expectEqual(@as(u32, 1), state.acceptedView().changes().storage_writes.len());
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Scenario.run, .{});
}

fn initCreationState(comptime closed: bool, allocator: std.mem.Allocator) !if (closed) bal.ClosedState else OpenState {
    if (closed) {
        const plan = try bal.ClaimPlan.initAssumeValidated(allocator, &.{.{
            .address = addr(1),
            .storage_reads = &.{7},
        }});
        const parent = try bal.ParentState.initCopy(allocator, &.{.{
            .parent = .{ .present = .{ .balance = 1 } },
        }}, &.{.{ .value = 10 }});
        return bal.ClosedWorld.initState(allocator, plan, parent, &.{});
    }
    var state = initState(allocator, null);
    errdefer state.deinit();
    var account = MemoryAccount.init(allocator);
    account.account.balance = 1;
    try account.storage.put(7, 10);
    try state.seedAccount(addr(1), account);
    return state;
}

fn expectCreationWrite(state: anytype, original: u256, block_access_index: u32) !void {
    const observations = state.pendingView().observations();
    const record = observations.storage.at(0);
    try std.testing.expectEqual(original, record.original);
    try std.testing.expectEqual(@as(u256, 7), record.current);
    try std.testing.expect(record.effect.written);
    try std.testing.expect(!observations.accounts.at(0).effect.storage_wiped);
    try std.testing.expectEqual(@as(u32, 1), state.pendingView().changes().storage_wipes.len());
    var builder = bal.projector.BlockBuilder.init(std.testing.allocator);
    defer builder.deinit();
    try builder.append(observations, block_access_index);
    var result = try builder.finish();
    defer result.deinit(std.testing.allocator);
    const writes = result.accounts[0].storage_changes;
    try std.testing.expectEqual(@as(usize, 1), writes.len);
    try std.testing.expectEqual(@as(u256, 7), writes[0].slot);
    try std.testing.expectEqual(@as(u256, 7), writes[0].changes[0].new_value);
}

test "contract initialization restores originals on revert and records retried writes in both worlds" {
    inline for (.{ false, true }) |closed| {
        for ([_]bool{ false, true }) |cached_original| {
            var state = try initCreationState(closed, std.testing.allocator);
            defer state.deinit();
            const attempt = state.beginObservedAttempt();
            defer abandon(&state);
            state.openSession();
            if (cached_original) {
                try std.testing.expectEqual(.assigned, try state.setStorage(word(1), 7, 10));
            }
            const creation = state.checkpoint();
            try state.initializeContract(word(1), 1);
            try std.testing.expectEqual(@as(u256, 1), try state.getBalance(word(1)));
            try std.testing.expectEqual(@as(u64, 1), state.cachedAccount(word(1)).?.nonce);
            try std.testing.expectEqual(@as(u256, 0), try state.getStorage(word(1), 7));
            try std.testing.expectEqual(.added, try state.setStorage(word(1), 7, 7));
            state.revertToCheckpoint(creation);
            try std.testing.expect(!state.createdInTransaction(word(1)));
            try std.testing.expectEqual(@as(u64, 0), state.cachedAccount(word(1)).?.nonce);
            try std.testing.expectEqual(@as(u256, 10), try state.getStorage(word(1), 7));
            const restored = state.checkpoint();
            try std.testing.expectEqual(.modified, try state.setStorage(word(1), 7, 11));
            state.revertToCheckpoint(restored);
            const retry = state.checkpoint();
            try state.initializeContract(word(1), 1);
            try std.testing.expectEqual(.added, try state.setStorage(word(1), 7, 7));
            state.commitCheckpoint(retry);
            try state.finalizeLifecycle(.{});
            state.closeSession();
            state.sealAttempt(attempt);
            try expectCreationWrite(&state, 10, 1);
        }
    }
}

test "contract initialization after accepted deletion observes the current incarnation in both worlds" {
    inline for (.{ false, true }) |closed| {
        var state = try initCreationState(closed, std.testing.allocator);
        defer state.deinit();
        const first = state.beginAttempt();
        state.openSession();
        const creation = state.checkpoint();
        try state.initializeContract(word(1), 1);
        _ = try state.setStorage(word(1), 7, 7);
        state.commitCheckpoint(creation);
        {
            const destruction = state.checkpoint();
            errdefer state.revertToCheckpoint(destruction);
            _ = try state.applySelfDestruct(word(1), word(1), .{
                .clear_balance = false,
                .reset_nonce = false,
                .mark_selfdestructed = true,
            }, false);
            state.commitCheckpoint(destruction);
        }
        try state.finalizeLifecycle(.{ .created_account = .{ .clear_storage = true, .delete_account = true } });
        state.closeSession();
        state.sealAttempt(first);
        state.retainAttempt(first);

        const next = state.beginObservedAttempt();
        defer abandon(&state);
        state.openSession();
        const reverted = state.checkpoint();
        try state.initializeContract(word(1), 1);
        // First access occurs after the second reset, over a row from the retired incarnation.
        try std.testing.expectEqual(@as(u256, 0), try state.getStorage(word(1), 7));
        _ = try state.setStorage(word(1), 7, 5);
        state.revertToCheckpoint(reverted);
        const restored = state.checkpoint();
        try std.testing.expectEqual(.added, try state.setStorage(word(1), 7, 7));
        state.revertToCheckpoint(restored);
        const retry = state.checkpoint();
        try state.initializeContract(word(1), 1);
        try std.testing.expectEqual(.added, try state.setStorage(word(1), 7, 7));
        state.commitCheckpoint(retry);
        try state.finalizeLifecycle(.{});
        state.closeSession();
        state.sealAttempt(next);
        try expectCreationWrite(&state, 0, 2);
    }
}

test "contract initialization allocation failure restores the creation checkpoint in both worlds" {
    inline for (.{ false, true }) |closed| {
        var failure_offset: usize = 0;
        while (true) : (failure_offset += 1) {
            var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
            var state = try initCreationState(closed, failing.allocator());
            defer state.deinit();
            const attempt = state.beginAttempt();
            defer abandon(&state);
            state.openSession();
            const creation = state.checkpoint();
            failing.fail_index = failing.alloc_index + failure_offset;
            const initialized = if (state.initializeContract(word(1), 1)) true else |err| failed: {
                try std.testing.expectEqual(error.OutOfMemory, err);
                break :failed false;
            };
            failing.fail_index = std.math.maxInt(usize);
            state.revertToCheckpoint(creation);
            try std.testing.expectEqual(@as(u256, 1), try state.getBalance(word(1)));
            try std.testing.expectEqual(@as(u64, 0), state.cachedAccount(word(1)).?.nonce);
            try std.testing.expectEqual(@as(u256, 10), try state.getStorage(word(1), 7));
            try std.testing.expect(!state.createdInTransaction(word(1)));
            state.closeSession();
            state.sealAttempt(attempt);
            try std.testing.expect(!state.pendingView().changes().hasChanges());
            if (initialized) {
                try std.testing.expect(failure_offset > 0);
                break;
            }
        }
    }
}
