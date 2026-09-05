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
fn abandon(state: *OpenState) void {
    if (!state.transaction_active) return;
    if (state.scopeActive()) state.closeScope();
    state.discard(state.active_attempt_id.?);
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

    const attempt = state.beginTransaction();
    state.beginScope();
    _ = try state.getBalance(word(1));
    _ = try state.loadStorage(word(1), 2);
    try state.warmAccount(word(2));
    state.closeScope();
    state.seal(attempt);
    state.discard(attempt);

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

    const attempt = state.beginTransaction();
    state.beginScope();
    try std.testing.expectError(error.ReaderUnavailable, state.getBalance(word(1)));
    try std.testing.expect(state.world.findAccount(word(1)) == null);
    backing.fail_loads = false;
    try std.testing.expectEqual(@as(u256, 10), try state.getBalance(word(1)));
    backing.fail_loads = true;
    try std.testing.expectError(error.ReaderUnavailable, state.getStorage(word(1), 2));
    try std.testing.expect(state.world.findStorage(row(&state, addr(1)), 2) == null);
    state.closeScope();
    state.seal(attempt);
    state.discard(attempt);
}

test "gas-only storage access warms without loading or observing a row" {
    var backing = TestReader{};
    var state = initState(std.testing.allocator, backing.reader());
    defer state.deinit();
    defer abandon(&state);

    const attempt = state.beginObservedTransaction();
    state.beginScope();
    try std.testing.expectEqual(.cold, try state.accessStorage(word(1), 2));
    try std.testing.expect(state.isStorageWarm(word(1), 2));
    try std.testing.expect(state.world.findAccount(word(1)) == null);
    try std.testing.expectEqual(@as(usize, 0), state.observed_storage.items.len);

    const loaded = try state.loadStorage(word(1), 2);
    try std.testing.expectEqual(.warm, loaded.access_status);
    state.closeScope();
    state.seal(attempt);

    const storage = state.pendingView().observations().storage;
    try std.testing.expectEqual(@as(u32, 1), storage.len());
    const metadata = storage.metadataAt(0);
    try std.testing.expectEqual(addr(1), metadata.address);
    try std.testing.expectEqual(@as(u256, 2), metadata.key);
    try std.testing.expect(metadata.observation.value_read);
    try std.testing.expect(!metadata.effect.written);
    const fact = storage.at(0).?;
    try std.testing.expectEqual(@as(u256, 7), fact.original);
    try std.testing.expectEqual(@as(u256, 7), fact.current);
}

test "rows survive scope rollback while current mutations revert" {
    var backing = TestReader{};
    var state = initState(std.testing.allocator, backing.reader());
    defer state.deinit();
    defer abandon(&state);

    _ = state.beginObservedTransaction();
    state.beginScope();
    const checkpoint = state.checkpoint();

    const loaded = try state.loadStorage(word(1), 2);
    try std.testing.expectEqual(@as(u256, 7), loaded.value);
    try std.testing.expectEqual(.cold, loaded.access_status);
    try std.testing.expectEqual(.modified, try state.setStorage(word(1), 2, 9));
    state.revertToCheckpoint(checkpoint);

    const id = slot(&state, addr(1), 2);
    const storage_row = state.world.storageRow(id);
    try std.testing.expectEqual(@as(u256, 7), storage_row.transaction_original);
    try std.testing.expectEqual(@as(u256, 7), storage_row.current);
    const observed = state.observed_storage.items[storage_row.observation_index];
    try std.testing.expect(observed.observation.accessed);
    try std.testing.expect(observed.observation.value_read);
    try std.testing.expect(!observed.effect.written);
    try std.testing.expect(!storage_row.flags.block_dirty);
    try std.testing.expect(!state.storageWarm(id));
}

test "execution original refreshes across scopes while transaction original remains" {
    var backing = TestReader{};
    var state = initState(std.testing.allocator, backing.reader());
    defer state.deinit();
    defer abandon(&state);

    const attempt = state.beginTransaction();
    state.beginScope();
    try std.testing.expectEqual(.modified, try state.setStorage(word(1), 2, 9));
    state.closeScope();

    state.beginScope();
    try std.testing.expectEqual(@as(u256, 9), try state.originalStorage(word(1), 2));
    try std.testing.expectEqual(.modified, try state.setStorage(word(1), 2, 11));
    const storage_row = state.world.storageRow(slot(&state, addr(1), 2));
    try std.testing.expectEqual(@as(u256, 7), storage_row.transaction_original);
    try std.testing.expectEqual(@as(u256, 11), storage_row.current);
    state.closeScope();

    state.seal(attempt);
    state.retain(attempt);
    try std.testing.expectEqual(@as(u64, 1), state.accepted_generation);
    try std.testing.expectEqual(@as(u256, 11), try state.getStorage(word(1), 2));
}

test "discard drops account writes without advancing accepted generation" {
    var backing = TestReader{};
    var state = initState(std.testing.allocator, backing.reader());
    defer state.deinit();
    defer abandon(&state);

    const attempt = state.beginTransaction();
    state.beginScope();
    try std.testing.expectEqual(@as(u256, 10), try state.getBalance(word(1)));
    try state.setBalance(word(1), 99);
    try std.testing.expectEqual(@as(u256, 99), try state.getBalance(word(1)));
    state.closeScope();
    state.seal(attempt);
    state.discard(attempt);

    try std.testing.expectEqual(@as(u64, 0), state.accepted_generation);
    const next = state.beginTransaction();
    state.beginScope();
    try std.testing.expectEqual(@as(u256, 10), try state.getBalance(word(1)));
    state.closeScope();
    state.seal(next);
    state.discard(next);
}

test "access hints reserve the block-lifetime row maps" {
    var state = initState(std.testing.allocator, null);
    defer state.deinit();
    defer abandon(&state);

    try state.reserveAcceptedAccessHint(.{ .accounts = 9, .storage_keys = 17 });
    try std.testing.expect(state.world.accounts.capacity() >= 9);
    try std.testing.expect(state.world.storage.capacity() >= 17);

    const attempt = state.beginTransaction();
    try state.reserveAccessHint(.{ .accounts = 33, .storage_keys = 1 });
    try std.testing.expect(state.world.accounts.capacity() >= 33);
    state.seal(attempt);
    state.discard(attempt);
}

test "retained account writes advance accepted state" {
    var backing = TestReader{};
    var state = initState(std.testing.allocator, backing.reader());
    defer state.deinit();
    defer abandon(&state);

    const attempt = state.beginObservedTransaction();
    state.beginScope();
    // A write of the value already held is not a write and not an access.
    try state.setBalance(word(1), 10);
    const unchanged = state.world.accountRow(row(&state, addr(1)));
    try std.testing.expectEqual(@as(usize, 0), state.observed_accounts.items.len);
    try std.testing.expect(!unchanged.flags.block_dirty);

    try state.setBalance(word(1), 99);
    try state.setNonce(word(1), 8);
    state.closeScope();
    state.seal(attempt);
    state.retain(attempt);

    try std.testing.expectEqual(@as(u64, 1), state.accepted_generation);
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

    const attempt = state.beginTransaction();
    state.beginScope();
    try state.setBalance(word(1), 99);
    try std.testing.expectEqual(.modified, try state.setStorage(word(1), 2, 9));
    try state.setCode(word(1), &.{0xaa});
    try state.setBalance(word(2), 88);
    try std.testing.expectEqual(.added, try state.setStorage(word(2), 3, 8));
    try state.setCode(word(2), &.{0xbb});
    state.closeScope();
    state.seal(attempt);

    failing_allocator.fail_index = failing_allocator.alloc_index;
    state.retain(attempt);

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

    _ = state.beginTransaction();
    state.beginScope();
    const checkpoint = state.checkpoint();
    try state.setNonce(word(1), 8);
    state.revertToCheckpoint(checkpoint);

    const account_row = state.world.accountRow(row(&state, addr(1)));
    try std.testing.expectEqual(@as(u64, 3), account_row.current.?.nonce);
    try std.testing.expect(!account_row.flags.block_dirty);
    try std.testing.expectEqual(@as(u64, 3), try state.getNonce(word(1)));
    try std.testing.expectEqual(@as(usize, 1), state.observed_accounts.items.len);
}

test "transient state and owned logs follow checkpoint rollback" {
    var state = initState(std.testing.allocator, null);
    defer state.deinit();
    defer abandon(&state);

    _ = state.beginTransaction();
    state.beginScope();
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

    _ = state.beginTransaction();
    state.beginScope();
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

    _ = state.beginTransaction();
    state.beginScope();
    const checkpoint = state.checkpoint();

    try std.testing.expectEqual(.cold, try state.accessAccount(word(1)));
    try state.setBalance(word(1), 99);
    try std.testing.expectEqual(.modified, try state.setStorage(word(1), 2, 9));
    try state.setTransientStorage(word(1), 4, 12);

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

    _ = state.beginTransaction();
    state.beginScope();

    try std.testing.expectEqual(.modified, try state.setStorage(word(1), 2, 9));
    try std.testing.expect(!state.isStorageWarm(word(1), 2));
    try std.testing.expectEqual(.cold, try state.accessStorage(word(1), 2));
    try std.testing.expect(state.isStorageWarm(word(1), 2));
    state.closeScope();
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

    const attempt = state.beginTransaction();
    state.beginScope();
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

    state.closeScope();
    state.seal(attempt);
    state.discard(attempt);
}

test "discarded code is reintroduced by a retained branch and then cleared" {
    const replacement_code = [_]u8{ 0x60, 0x02, 0x00 };
    const replacement_hash = crypto.keccak256(&replacement_code);
    var backing = TestReader{};
    var state = initState(std.testing.allocator, backing.reader());
    defer state.deinit();
    defer abandon(&state);

    const discarded = state.beginTransaction();
    state.beginScope();
    try state.setCode(word(1), &replacement_code);
    state.closeScope();
    state.seal(discarded);
    state.discard(discarded);
    try std.testing.expect(state.code.lookup(replacement_hash) == null);

    const retained = state.beginTransaction();
    state.beginScope();
    try std.testing.expectEqualSlices(u8, &.{}, try state.getCode(word(1)));
    try state.setCode(word(1), &replacement_code);
    state.closeScope();
    state.seal(retained);
    state.retain(retained);
    try std.testing.expect(state.acceptedView().changes().introducedCode(replacement_hash) != null);
    try std.testing.expectEqualSlices(u8, &replacement_code, try state.getCode(word(1)));
    try std.testing.expect(try state.accountHasCode(word(1)));

    const cleared = state.beginTransaction();
    state.beginScope();
    try state.clearCode(word(1));
    state.closeScope();
    state.seal(cleared);
    state.retain(cleared);
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

    const attempt = state.beginObservedTransaction();
    state.beginScope();
    try state.setCode(word(2), &code);
    try std.testing.expectEqualSlices(u8, &code, try state.getCode(word(2)));
    state.closeScope();
    state.seal(attempt);
    try std.testing.expect(state.pendingView().changes().introducedCode(code_hash) == null);
    try std.testing.expectEqualSlices(u8, &code, state.pendingView().observations().code(code_hash).?.bytes);
    state.retain(attempt);
    try std.testing.expectEqual(@as(usize, 0), state.code.introducedLen());
}

test "pending and accepted views expose the sealed transaction" {
    var state = initState(std.testing.allocator, null);
    defer state.deinit();
    defer abandon(&state);

    const attempt = state.beginTransaction();
    state.beginScope();
    const topics = [_]u256{7};
    try state.emitLog(.{
        .address = addr(1),
        .topics = &topics,
        .data = &.{0xaa},
    });
    try state.setBalance(word(1), 9);
    state.closeScope();
    state.seal(attempt);

    const pending = state.pendingView();
    try std.testing.expectEqual(@as(u64, 0), state.accepted_generation);
    try std.testing.expectEqual(@as(usize, 1), pending.logs().len());
    const event_log = pending.logs().get(0);
    try std.testing.expectEqual(addr(1), event_log.address);
    try std.testing.expectEqualSlices(u256, &topics, event_log.topics);
    try std.testing.expectEqualSlices(u8, &.{0xaa}, event_log.data);

    state.retain(attempt);
    const accepted = state.acceptedView();
    try std.testing.expectEqual(@as(u64, 1), state.accepted_generation);
    try std.testing.expect(accepted.hasChanges());
    try std.testing.expectEqual(@as(usize, 1), state.logView().len());
    try std.testing.expectEqual(addr(1), state.logView().get(0).address);
}

test "selfdestruct finalization deletes account and masks accepted storage" {
    var backing = TestReader{};
    var state = initState(std.testing.allocator, backing.reader());
    defer state.deinit();
    defer abandon(&state);

    const written = state.beginTransaction();
    state.beginScope();
    try std.testing.expectEqual(.modified, try state.setStorage(word(1), 2, 9));
    state.closeScope();
    state.seal(written);
    state.retain(written);
    const accepted = state.acceptedView().changes();
    try std.testing.expectEqual(@as(u32, 1), accepted.storage_writes.len());
    try std.testing.expectEqual(addr(1), accepted.storage_writes.at(0).address);
    try std.testing.expectEqual(@as(u256, 2), accepted.storage_writes.at(0).key);

    const destroyed = state.beginTransaction();
    state.beginScope();
    try state.markSelfdestructed(word(1));
    const before_finalize = state.checkpoint();
    try state.finalize(.{ .existing_account = .{
        .delete_account = true,
        .clear_storage = true,
    } });

    try std.testing.expect(state.getAccount(word(1)) == null);
    try std.testing.expectEqual(@as(u256, 0), try state.getStorage(word(1), 2));
    try std.testing.expect(!state.wasSelfdestructed(word(1)));

    state.revertToCheckpoint(before_finalize);
    try std.testing.expect(state.wasSelfdestructed(word(1)));
    try std.testing.expectEqual(@as(u256, 10), try state.getBalance(word(1)));
    try std.testing.expectEqual(@as(u256, 9), try state.getStorage(word(1), 2));

    try state.finalize(.{ .existing_account = .{
        .delete_account = true,
        .clear_storage = true,
    } });
    state.closeScope();
    state.seal(destroyed);
    state.retain(destroyed);

    try std.testing.expect(state.getAccount(word(1)) == null);
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

    const destroyed = state.beginTransaction();
    state.beginScope();
    try state.markSelfdestructed(word(1));
    try state.finalize(.{ .existing_account = .{ .clear_storage = true } });
    state.closeScope();
    state.seal(destroyed);
    state.retain(destroyed);
    try std.testing.expect(state.world.findStorage(row(&state, addr(1)), 2) == null);

    const attempt = state.beginObservedTransaction();
    state.beginScope();
    try std.testing.expectEqual(@as(u256, 0), try state.getStorage(word(1), 2));
    try std.testing.expectEqual(@as(u256, 0), try state.originalStorage(word(1), 2));
    try std.testing.expectEqual(.added, try state.setStorage(word(1), 2, 5));
    // The row carries the parent value it was admitted with; only its
    // generation hides it.
    try std.testing.expectEqual(@as(u256, 5), state.world.storageRow(slot(&state, addr(1), 2)).current);
    try std.testing.expectEqual(@as(u256, 0), state.world.storageRow(slot(&state, addr(1), 2)).transaction_original);
    state.closeScope();
    state.seal(attempt);
    const fact = state.pendingView().observations().storage.at(0).?;
    try std.testing.expectEqual(@as(u256, 0), fact.original);
    try std.testing.expectEqual(@as(u256, 5), fact.current);
    state.retain(attempt);
    try std.testing.expectEqual(@as(u32, 1), state.acceptedView().changes().storage_writes.len());
}

test "Cancun existing-account selfdestruct only clears lifecycle marker" {
    var backing = TestReader{};
    var state = initState(std.testing.allocator, backing.reader());
    defer state.deinit();
    defer abandon(&state);

    const attempt = state.beginTransaction();
    state.beginScope();
    try state.markSelfdestructed(word(1));
    try state.finalize(.{});

    try std.testing.expect(!state.wasSelfdestructed(word(1)));
    try std.testing.expectEqual(@as(u256, 10), try state.getBalance(word(1)));
    try std.testing.expectEqual(@as(u256, 7), try state.getStorage(word(1), 2));

    state.closeScope();
    state.seal(attempt);
    state.retain(attempt);
    try std.testing.expectEqual(@as(u256, 10), try state.getBalance(word(1)));
    try std.testing.expectEqual(@as(u256, 7), try state.getStorage(word(1), 2));
}

test "created-account finalization removes an empty reset account" {
    var state = initState(std.testing.allocator, null);
    defer state.deinit();
    defer abandon(&state);

    const created = state.beginTransaction();
    state.beginScope();
    try state.setNonce(word(2), 9);
    try state.setCode(word(2), &.{ 0xaa, 0xbb });
    try std.testing.expectEqual(.added, try state.setStorage(word(2), 7, 13));
    try state.markCreatedContract(word(2));
    try state.markSelfdestructed(word(2));
    try state.finalize(.{ .created_account = .{
        .clear_storage = true,
        .reset_account = true,
    } });

    try std.testing.expect(state.getAccount(word(2)) == null);
    try std.testing.expectEqualSlices(u8, &.{}, try state.getCode(word(2)));
    try std.testing.expectEqual(@as(u256, 0), try state.getStorage(word(2), 7));
    try std.testing.expect(!state.createdInTransaction(word(2)));
    try std.testing.expect(!state.wasSelfdestructed(word(2)));

    state.closeScope();
    state.seal(created);
    state.retain(created);

    const rewritten = state.beginTransaction();
    state.beginScope();
    try std.testing.expectEqual(.added, try state.setStorage(word(2), 7, 11));
    state.closeScope();
    state.seal(rewritten);
    state.retain(rewritten);

    try std.testing.expectEqual(@as(u256, 11), try state.getStorage(word(2), 7));
    try std.testing.expectEqual(@as(u256, 0), try state.getStorage(word(2), 8));
}

test "created-account finalization preserves a balance-only account" {
    var state = initState(std.testing.allocator, null);
    defer state.deinit();
    defer abandon(&state);

    _ = state.beginTransaction();
    state.beginScope();
    try state.setBalance(word(2), 1);
    try state.setNonce(word(2), 9);
    try state.setCode(word(2), &.{0xaa});
    try std.testing.expectEqual(.added, try state.setStorage(word(2), 7, 13));
    try state.markCreatedContract(word(2));
    try state.markSelfdestructed(word(2));
    try state.finalize(.{ .created_account = .{
        .clear_storage = true,
        .reset_account = true,
    } });

    const account = state.getAccount(word(2)).?;
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

    _ = state.beginTransaction();
    state.beginScope();
    try std.testing.expectEqual(@as(u256, 7), try state.getStorage(word(1), 2));
    try state.markSelfdestructed(word(1));
    const journal_len = state.journalEntryCount();

    failing_allocator.fail_index = failing_allocator.alloc_index;
    try std.testing.expectError(error.OutOfMemory, state.finalize(.{ .existing_account = .{
        .delete_account = true,
        .clear_storage = true,
    } }));

    try std.testing.expect(failing_allocator.has_induced_failure);
    try std.testing.expectEqual(journal_len, state.journalEntryCount());
    try std.testing.expect(state.wasSelfdestructed(word(1)));
    try std.testing.expectEqual(@as(u256, 10), state.getAccount(word(1)).?.balance);
    try std.testing.expectEqual(@as(u256, 7), try state.getStorage(word(1), 2));
}

test "sparse lifecycle candidates are compact and survive marker rollback" {
    var state = initState(std.testing.allocator, null);
    defer state.deinit();
    defer abandon(&state);

    _ = state.beginTransaction();
    state.beginScope();
    const checkpoint = state.checkpoint();

    try state.markCreatedContract(word(1));
    try state.markSelfdestructed(word(1));
    try std.testing.expectEqual(@as(usize, 1), state.lifecycle_accounts.items.len);

    state.revertToCheckpoint(checkpoint);
    try std.testing.expect(!state.createdInTransaction(word(1)));
    try std.testing.expect(!state.wasSelfdestructed(word(1)));
    try std.testing.expectEqual(@as(usize, 1), state.lifecycle_accounts.items.len);

    try state.markSelfdestructed(word(1));
    try std.testing.expectEqual(@as(usize, 1), state.lifecycle_accounts.items.len);
}

test "pending changes are transaction local and accepted changes accumulate" {
    var state = initState(std.testing.allocator, null);
    defer state.deinit();
    defer abandon(&state);

    const first_code = [_]u8{0xaa};
    const first_hash = crypto.keccak256(&first_code);
    const first = state.beginTransaction();
    state.beginScope();
    try state.setBalance(word(1), 11);
    try state.setCode(word(1), &first_code);
    _ = try state.setStorage(word(1), 1, 111);
    state.closeScope();
    state.seal(first);
    state.retain(first);

    const accepted_first = state.acceptedView().changes();
    try std.testing.expectEqual(@as(u32, 1), accepted_first.accounts.len());
    try std.testing.expectEqual(addr(1), accepted_first.accounts.at(0).address);
    try std.testing.expectEqual(@as(u32, 1), accepted_first.storage_writes.len());
    try std.testing.expectEqualSlices(u8, &first_code, accepted_first.introducedCode(first_hash).?.bytes);

    const second_code = [_]u8{0xbb};
    const second_hash = crypto.keccak256(&second_code);
    const second = state.beginTransaction();
    state.beginScope();
    try state.setBalance(word(2), 22);
    try state.setCode(word(2), &second_code);
    _ = try state.setStorage(word(2), 2, 222);
    state.closeScope();
    state.seal(second);

    const pending = state.pendingView().changes();
    try std.testing.expectEqual(@as(u32, 1), pending.accounts.len());
    try std.testing.expectEqual(addr(2), pending.accounts.at(0).address);
    try std.testing.expectEqual(@as(u32, 1), pending.storage_writes.len());
    try std.testing.expect(pending.introducedCode(first_hash) == null);
    try std.testing.expectEqualSlices(u8, &second_code, pending.introducedCode(second_hash).?.bytes);
    const accepted_pending = state.pendingView().accepted().changes();
    try std.testing.expectEqual(@as(u32, 1), accepted_pending.accounts.len());
    try std.testing.expectEqual(addr(1), accepted_pending.accounts.at(0).address);

    state.retain(second);
    const accepted_second = state.acceptedView().changes();
    try std.testing.expectEqual(@as(u32, 2), accepted_second.accounts.len());
    try std.testing.expectEqual(@as(u32, 2), accepted_second.storage_writes.len());
    try std.testing.expectEqualSlices(u8, &first_code, accepted_second.introducedCode(first_hash).?.bytes);
    try std.testing.expectEqualSlices(u8, &second_code, accepted_second.introducedCode(second_hash).?.bytes);
}

test "checkpoint rollback truncates dense change ids" {
    var state = initState(std.testing.allocator, null);
    defer state.deinit();
    defer abandon(&state);

    const attempt = state.beginTransaction();
    state.beginScope();
    const checkpoint = state.checkpoint();
    try state.setBalance(word(1), 1);
    _ = try state.setStorage(word(1), 1, 11);
    state.revertToCheckpoint(checkpoint);

    try state.setBalance(word(2), 2);
    _ = try state.setStorage(word(2), 2, 22);
    state.closeScope();
    state.seal(attempt);

    const changes = state.pendingView().changes();
    try std.testing.expectEqual(@as(u32, 1), changes.accounts.len());
    try std.testing.expectEqual(addr(2), changes.accounts.at(0).address);
    try std.testing.expectEqual(@as(u32, 1), changes.storage_writes.len());
    try std.testing.expectEqual(addr(2), changes.storage_writes.at(0).address);

    state.retain(attempt);
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
    const baseline = state.beginTransaction();
    state.beginScope();
    try state.setBalance(word(1), 11);
    try state.setCode(word(1), &baseline_code);
    try std.testing.expectEqual(.added, try state.setStorage(word(1), 2, 22));
    try state.emitLog(.{
        .address = addr(1),
        .topics = &.{3},
        .data = &.{0x44},
    });
    state.closeScope();
    state.seal(baseline);
    state.retain(baseline);

    var snapshot = try state.branchSnapshot();
    defer snapshot.deinit();

    const destroyed = state.beginTransaction();
    state.beginScope();
    try state.markSelfdestructed(word(1));
    try state.finalize(.{ .existing_account = .{
        .delete_account = true,
        .clear_storage = true,
    } });
    state.closeScope();
    state.seal(destroyed);
    state.retain(destroyed);
    try std.testing.expect(state.getAccount(word(1)) == null);
    try std.testing.expectEqual(@as(u32, 1), state.acceptedView().changes().storage_wipes.len());

    var first_restore = try snapshot.clone();
    defer first_restore.deinit();
    state.restoreBranch(&first_restore);
    try std.testing.expectEqual(@as(u64, 1), state.accepted_generation);
    try std.testing.expectEqual(@as(u256, 11), try state.getBalance(word(1)));
    try std.testing.expectEqual(@as(u256, 22), try state.getStorage(word(1), 2));
    try std.testing.expectEqualSlices(u8, &baseline_code, try state.getCode(word(1)));
    try std.testing.expectEqual(@as(usize, 1), state.logView().len());
    const restored_changes = state.acceptedView().changes();
    try std.testing.expectEqual(@as(u32, 0), restored_changes.storage_wipes.len());
    try std.testing.expect(restored_changes.introducedCode(baseline_hash) != null);

    const later = state.beginTransaction();
    state.beginScope();
    try state.setBalance(word(2), 33);
    _ = try state.setStorage(word(2), 9, 99);
    state.closeScope();
    state.seal(later);
    state.retain(later);
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

test "accepted branch snapshot clone failure leaves current state unchanged" {
    var failing_allocator = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var state = initState(failing_allocator.allocator(), null);
    defer state.deinit();
    defer abandon(&state);

    const baseline = state.beginTransaction();
    state.beginScope();
    try state.setBalance(word(1), 11);
    state.closeScope();
    state.seal(baseline);
    state.retain(baseline);
    var snapshot = try state.branchSnapshot();
    defer snapshot.deinit();

    const later = state.beginTransaction();
    state.beginScope();
    try state.setBalance(word(1), 22);
    state.closeScope();
    state.seal(later);
    state.retain(later);

    failing_allocator.fail_index = failing_allocator.alloc_index;
    try std.testing.expectError(error.OutOfMemory, snapshot.clone());
    try std.testing.expect(failing_allocator.has_induced_failure);
    try std.testing.expectEqual(@as(u64, 2), state.accepted_generation);
    try std.testing.expectEqual(@as(u256, 22), try state.getBalance(word(1)));

    failing_allocator.fail_index = std.math.maxInt(usize);
    var restore = try snapshot.clone();
    defer restore.deinit();
    state.restoreBranch(&restore);
    try std.testing.expectEqual(@as(u64, 1), state.accepted_generation);
    try std.testing.expectEqual(@as(u256, 11), try state.getBalance(word(1)));
}

test "accepted branch restore does not allocate after capture" {
    var failing_allocator = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var state = initState(failing_allocator.allocator(), null);
    defer state.deinit();
    defer abandon(&state);

    const baseline = state.beginTransaction();
    state.beginScope();
    try state.setBalance(word(1), 11);
    state.closeScope();
    state.seal(baseline);
    state.retain(baseline);
    var snapshot = try state.branchSnapshot();
    defer snapshot.deinit();

    const later = state.beginTransaction();
    state.beginScope();
    try state.setBalance(word(1), 22);
    try state.setBalance(word(2), 5);
    state.closeScope();
    state.seal(later);
    state.retain(later);

    failing_allocator.fail_index = failing_allocator.alloc_index;
    state.restoreBranch(&snapshot);
    try std.testing.expect(!failing_allocator.has_induced_failure);
    try std.testing.expectEqual(@as(u64, 1), state.accepted_generation);
    try std.testing.expectEqual(@as(u256, 11), try state.getBalance(word(1)));
}

test "discard accepted resets the world and invalidates earlier snapshots" {
    var backing = TestReader{};
    var state = initState(std.testing.allocator, backing.reader());
    defer state.deinit();
    defer abandon(&state);

    const attempt = state.beginTransaction();
    state.beginScope();
    try state.setBalance(word(1), 99);
    try state.setCode(word(1), &.{0xaa});
    state.closeScope();
    state.seal(attempt);
    state.retain(attempt);
    try std.testing.expect(state.acceptedView().hasChanges());

    state.discardAccepted();
    try std.testing.expect(!state.acceptedView().hasChanges());
    try std.testing.expectEqual(@as(u32, 0), state.world.accountCount());
    try std.testing.expectEqual(@as(usize, 0), state.code.introducedLen());
    try std.testing.expectEqual(@as(u256, 10), try state.getBalance(word(1)));
    try std.testing.expectEqual(@as(u64, 1), state.world_epoch);
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
            const attempt = state.beginObservedTransaction();
            state.beginScope();
            defer abandon(&state);
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
            try state.markSelfdestructed(word(3));
            state.revertToCheckpoint(nested);
            nested_active = false;
            try state.finalize(.{ .existing_account = .{ .delete_account = true, .clear_storage = true } });
            state.closeScope();
            state.seal(attempt);
            state.retain(attempt);
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Harness.run, .{});
}

test "pre-scope writes are the scope baseline and revert only with the attempt" {
    var backing = TestReader{};
    var state = initState(std.testing.allocator, backing.reader());
    defer state.deinit();
    defer abandon(&state);

    const attempt = state.beginObservedTransaction();
    try state.setBalance(word(1), 17);
    _ = try state.setStorage(word(1), 2, 9);
    try std.testing.expectEqual(@as(usize, 2), state.journalEntryCount());

    state.beginScope();
    const checkpoint = state.checkpoint();
    try state.setBalance(word(1), 99);
    _ = try state.setStorage(word(1), 2, 11);
    state.revertToCheckpoint(checkpoint);
    try std.testing.expectEqual(@as(u256, 17), try state.getBalance(word(1)));
    try std.testing.expectEqual(@as(u256, 9), try state.getStorage(word(1), 2));
    state.closeScope();
    // A second root sees the pre-scope write as its execution original.
    state.beginScope();
    try std.testing.expectEqual(@as(u256, 9), try state.originalStorage(word(1), 2));
    state.closeScope();
    state.seal(attempt);
    try std.testing.expectEqual(@as(u32, 1), state.pendingView().changes().accounts.len());
    state.discard(attempt);

    try std.testing.expectEqual(@as(u256, 10), try state.getBalance(word(1)));
    try std.testing.expectEqual(@as(u256, 7), try state.getStorage(word(1), 2));
}

test "accepted branch snapshot restores compacted storage change ids" {
    var state = initState(std.testing.allocator, null);
    defer state.deinit();
    defer abandon(&state);

    const baseline = state.beginTransaction();
    state.beginScope();
    try state.setBalance(word(1), 1);
    try state.setBalance(word(2), 1);
    try std.testing.expectEqual(.added, try state.setStorage(word(1), 1, 11));
    try std.testing.expectEqual(.added, try state.setStorage(word(2), 2, 22));
    state.closeScope();
    state.seal(baseline);
    state.retain(baseline);

    var snapshot = try state.branchSnapshot();
    defer snapshot.deinit();

    const wiped = state.beginTransaction();
    state.beginScope();
    try state.markSelfdestructed(word(1));
    try state.finalize(.{ .existing_account = .{ .clear_storage = true } });
    state.closeScope();
    state.seal(wiped);
    state.retain(wiped);

    state.restoreBranch(&snapshot);
    const changes = state.acceptedView().changes();
    try std.testing.expectEqual(@as(u32, 2), changes.storage_writes.len());
    try std.testing.expectEqual(addr(1), changes.storage_writes.at(0).address);
    try std.testing.expectEqual(@as(u256, 1), changes.storage_writes.at(0).key);
    try std.testing.expectEqual(addr(2), changes.storage_writes.at(1).address);
    try std.testing.expectEqual(@as(u256, 2), changes.storage_writes.at(1).key);
}

test "warm-only keys avoid parent I/O and preserve warmth through later row rollback" {
    var backing = TestReader{ .fail_loads = true };
    var state = initState(std.testing.allocator, backing.reader());
    defer state.deinit();
    defer abandon(&state);

    const attempt = state.beginObservedTransaction();
    state.beginScope();
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
    state.closeScope();
    state.seal(attempt);
    state.retain(attempt);

    _ = state.beginTransaction();
    state.beginScope();
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
    _ = state.beginTransaction();
    state.beginScope();

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
            const attempt = state.beginTransaction();
            state.beginScope();
            try state.setBalance(word(1), 1);
            _ = try state.setStorage(word(1), 1, 11);
            try state.wipeStorage(row(&state, addr(1)));
            _ = try state.setStorage(word(1), 2, 22);
            try state.emitLog(.{ .address = addr(1), .topics = &.{1}, .data = &.{2} });
            state.closeScope();
            state.seal(attempt);
            state.retain(attempt);
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
