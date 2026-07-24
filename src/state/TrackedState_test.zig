const std = @import("std");
const addr = @import("../address.zig").addr;
const crypto = @import("../crypto.zig");
const uint256 = @import("../uint256.zig");
const Account = @import("./Account.zig");
const Reader = @import("./Reader.zig");
const TrackedState = @import("./TrackedState.zig");

const TestReader = struct {
    account_address: @import("../address.zig").Address = addr(1),
    account: Account = .{ .nonce = 3, .balance = 10 },
    code: []const u8 = &.{},
    storage_key: u256 = 2,
    storage_value: u256 = 7,

    fn reader(self: *@This()) Reader {
        return .{ .ptr = self, .vtable = &.{
            .accountExists = accountExists,
            .loadAccount = loadAccount,
            .loadCode = loadCode,
            .getStorage = getStorage,
            .accountHasStorage = accountHasStorage,
        } };
    }

    fn cast(ptr: *anyopaque) *@This() {
        return @ptrCast(@alignCast(ptr));
    }

    fn accountExists(ptr: *anyopaque, address: @import("../address.zig").Address) !bool {
        return std.mem.eql(u8, &cast(ptr).account_address, &address);
    }

    fn loadAccount(ptr: *anyopaque, address: @import("../address.zig").Address) !?Account {
        const self = cast(ptr);
        if (!std.mem.eql(u8, &self.account_address, &address)) return null;
        return self.account;
    }

    fn loadCode(ptr: *anyopaque, hash: [32]u8) ![]const u8 {
        const code = cast(ptr).code;
        if (!std.mem.eql(u8, &crypto.keccak256(code), &hash)) return error.CodeUnavailable;
        return code;
    }

    fn getStorage(ptr: *anyopaque, address: @import("../address.zig").Address, key: u256) !u256 {
        const self = cast(ptr);
        if (!std.mem.eql(u8, &self.account_address, &address) or key != self.storage_key) return 0;
        return self.storage_value;
    }

    fn accountHasStorage(ptr: *anyopaque, address: @import("../address.zig").Address) !bool {
        return accountExists(ptr, address);
    }
};

test "normal transaction does not materialize observation state" {
    var backing = TestReader{};
    var state = TrackedState.initWithStateReader(std.testing.allocator, backing.reader());
    defer state.deinit();

    _ = state.beginTransaction();
    state.beginScope();
    _ = try state.getBalance(addr(1));
    _ = try state.loadStorage(addr(1), 2);
    try state.setBalance(addr(1), 99);
    try std.testing.expectEqual(.modified, try state.setStorage(addr(1), 2, 9));

    const tx = &state.tx.?;
    try std.testing.expect(!tx.observe);
    try std.testing.expectEqual(@as(usize, 0), tx.observed_accounts.items.len);
    try std.testing.expectEqual(@as(usize, 0), tx.observed_storage.items.len);
    try std.testing.expectEqual(@as(usize, 0), tx.undo.account_observation_undo.items.len);
    try std.testing.expectEqual(@as(usize, 0), tx.undo.storage_observation_undo.items.len);
    try std.testing.expect(tx.accounts.get(addr(1)).?.observation_id == null);
    try std.testing.expect(tx.storage.get(.{ .address = addr(1), .key = 2 }).?.observation_id == null);
}

test "tracked rows survive scope rollback while current mutations revert" {
    var backing = TestReader{};
    var state = TrackedState.initWithStateReader(std.testing.allocator, backing.reader());
    defer state.deinit();

    _ = state.beginObservedTransaction();
    state.beginScope();
    const checkpoint = state.checkpoint();

    const loaded = try state.loadStorage(addr(1), 2);
    try std.testing.expectEqual(@as(u256, 7), loaded.value);
    try std.testing.expectEqual(.cold, loaded.access_status);
    try std.testing.expectEqual(.modified, try state.setStorage(addr(1), 2, 9));
    state.revertToCheckpoint(checkpoint);

    const row = state.tx.?.storage.get(.{ .address = addr(1), .key = 2 }).?;
    try std.testing.expectEqual(@as(?u256, 7), row.transaction_original);
    try std.testing.expectEqual(@as(?u256, 7), row.current);
    const observed = state.tx.?.observed_storage.items[@intFromEnum(row.observation_id.?)];
    try std.testing.expect(observed.observation.accessed);
    try std.testing.expect(observed.observation.value_read);
    try std.testing.expect(!row.mutation.dirty);
    const scope_row = state.tx.?.scope.storage.get(.{ .address = addr(1), .key = 2 }).?;
    try std.testing.expect(!scope_row.warm);
}

test "execution original refreshes across scopes while transaction original remains" {
    var backing = TestReader{};
    var state = TrackedState.initWithStateReader(std.testing.allocator, backing.reader());
    defer state.deinit();

    const attempt = state.beginTransaction();
    state.beginScope();
    try std.testing.expectEqual(.modified, try state.setStorage(addr(1), 2, 9));
    state.closeScope();

    state.beginScope();
    try std.testing.expectEqual(@as(u256, 9), try state.originalStorage(addr(1), 2));
    try std.testing.expectEqual(.modified, try state.setStorage(addr(1), 2, 11));
    const row = state.tx.?.storage.get(.{ .address = addr(1), .key = 2 }).?;
    try std.testing.expectEqual(@as(?u256, 7), row.transaction_original);
    try std.testing.expectEqual(@as(?u256, 11), row.current);
    state.closeScope();

    state.seal(attempt);
    state.retain(attempt);
    try std.testing.expectEqual(@as(u64, 1), state.generation);
    try std.testing.expectEqual(@as(u256, 11), try state.getStorage(addr(1), 2));
}

test "discard drops account writes without advancing accepted generation" {
    var backing = TestReader{};
    var state = TrackedState.initWithStateReader(std.testing.allocator, backing.reader());
    defer state.deinit();

    const attempt = state.beginTransaction();
    try std.testing.expectEqual(@as(u256, 10), try state.getBalance(addr(1)));
    try state.setBalance(addr(1), 99);
    try std.testing.expectEqual(@as(u256, 99), try state.getBalance(addr(1)));
    state.seal(attempt);
    state.discard(attempt);

    try std.testing.expectEqual(@as(u64, 0), state.generation);
    _ = state.beginTransaction();
    try std.testing.expectEqual(@as(u256, 10), try state.getBalance(addr(1)));
}

test "retained account writes advance accepted state" {
    var backing = TestReader{};
    var state = TrackedState.initWithStateReader(std.testing.allocator, backing.reader());
    defer state.deinit();

    const attempt = state.beginObservedTransaction();
    try state.setBalance(addr(1), 10);
    const unchanged = state.tx.?.accounts.get(addr(1)).?;
    const observed = state.tx.?.observed_accounts.items[@intFromEnum(unchanged.observation_id.?)];
    try std.testing.expect(observed.observation.value_read);
    try std.testing.expect(!unchanged.mutation.dirty);

    try state.setBalance(addr(1), 99);
    try state.setNonce(addr(1), 8);
    state.seal(attempt);
    state.retain(attempt);

    try std.testing.expectEqual(@as(u64, 1), state.generation);
    try std.testing.expectEqual(@as(u256, 99), try state.getBalance(addr(1)));
    try std.testing.expectEqual(@as(u64, 8), try state.getNonce(addr(1)));
    const changes = state.acceptedView().changes();
    try std.testing.expectEqual(@as(u32, 1), changes.accounts.len());
    try std.testing.expectEqual(addr(1), changes.accounts.at(0).address);
}

test "retain folds reserved account and storage mutations without allocation" {
    var failing_allocator = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var backing = TestReader{};
    var state = TrackedState.initWithStateReader(failing_allocator.allocator(), backing.reader());
    defer state.deinit();

    const attempt = state.beginTransaction();
    state.beginScope();
    try state.setBalance(addr(1), 99);
    try std.testing.expectEqual(.modified, try state.setStorage(addr(1), 2, 9));
    try state.setCode(addr(1), &.{0xaa});
    try state.setBalance(addr(2), 88);
    try std.testing.expectEqual(.added, try state.setStorage(addr(2), 3, 8));
    try state.setCode(addr(2), &.{0xbb});
    state.closeScope();
    state.seal(attempt);

    failing_allocator.fail_index = failing_allocator.alloc_index;
    state.retain(attempt);

    try std.testing.expect(!failing_allocator.has_induced_failure);
    try std.testing.expectEqual(@as(u256, 99), try state.getBalance(addr(1)));
    try std.testing.expectEqual(@as(u256, 9), try state.getStorage(addr(1), 2));
    try std.testing.expectEqual(@as(u256, 88), try state.getBalance(addr(2)));
    try std.testing.expectEqual(@as(u256, 8), try state.getStorage(addr(2), 3));
}

test "account mutation rolls back but observation and row survive" {
    var backing = TestReader{};
    var state = TrackedState.initWithStateReader(std.testing.allocator, backing.reader());
    defer state.deinit();

    _ = state.beginTransaction();
    state.beginScope();
    const checkpoint = state.checkpoint();
    try state.setNonce(addr(1), 8);
    state.revertToCheckpoint(checkpoint);

    const row = state.tx.?.accounts.get(addr(1)).?;
    try std.testing.expectEqual(@as(u64, 3), switch (row.current.?) {
        .loaded => |account| account.nonce,
        else => unreachable,
    });
    try std.testing.expect(!row.mutation.dirty);
    try std.testing.expectEqual(@as(u64, 3), try state.getNonce(addr(1)));
}

test "transient state and owned logs follow checkpoint rollback" {
    var state = TrackedState.init(std.testing.allocator);
    defer state.deinit();

    _ = state.beginTransaction();
    state.beginScope();
    const checkpoint = state.checkpoint();
    try state.setTransientStorage(addr(1), 4, 12);
    const topics = [_]u256{ 1, 2 };
    try state.emitLog(.{ .address = addr(1), .topics = &topics, .data = "abc" });
    const large_data = [_]u8{0xbb} ** 1024;
    try state.emitLog(.{ .address = addr(2), .topics = &.{3}, .data = &large_data });

    const first_log = state.tx.?.logs.rows.items[0];
    try std.testing.expectEqualSlices(
        u256,
        &topics,
        first_log.topics.slice(state.tx.?.logs.topics.items),
    );
    try std.testing.expectEqualSlices(
        u8,
        "abc",
        first_log.data.slice(state.tx.?.logs.data.items),
    );
    state.revertToCheckpoint(checkpoint);

    try std.testing.expectEqual(@as(u256, 0), try state.getTransientStorage(addr(1), 4));
    try std.testing.expectEqual(@as(usize, 0), state.tx.?.logs.rows.items.len);
    try std.testing.expectEqual(@as(usize, 0), state.tx.?.logs.topics.items.len);
    try std.testing.expectEqual(@as(usize, 0), state.tx.?.logs.data.items.len);
}

test "compact journal order unwinds typed undo arenas" {
    var backing = TestReader{};
    var state = TrackedState.initWithStateReader(std.testing.allocator, backing.reader());
    defer state.deinit();

    _ = state.beginTransaction();
    state.beginScope();
    const checkpoint = state.checkpoint();

    try std.testing.expectEqual(.cold, try state.accessAccount(addr(1)));
    try state.setBalance(addr(1), 99);
    try std.testing.expectEqual(.modified, try state.setStorage(addr(1), 2, 9));
    try state.setTransientStorage(addr(1), 4, 12);

    const undo = &state.tx.?.undo;
    try std.testing.expectEqual(@as(usize, 4), undo.entries.items.len);
    try std.testing.expectEqual(@as(usize, 1), undo.account_undo.items.len);
    try std.testing.expectEqual(@as(usize, 1), undo.storage_undo.items.len);
    try std.testing.expectEqual(@as(usize, 1), undo.transient_undo.items.len);

    state.revertToCheckpoint(checkpoint);
    try std.testing.expectEqual(@as(usize, 0), undo.entries.items.len);
    try std.testing.expectEqual(@as(usize, 0), undo.account_undo.items.len);
    try std.testing.expectEqual(@as(usize, 0), undo.storage_undo.items.len);
    try std.testing.expectEqual(@as(usize, 0), undo.transient_undo.items.len);
    try std.testing.expectEqual(@as(u256, 10), try state.getBalance(addr(1)));
    try std.testing.expectEqual(@as(u256, 7), try state.getStorage(addr(1), 2));
    try std.testing.expect(!state.tx.?.scope.warm_accounts.contains(addr(1)));
    try std.testing.expect(!state.tx.?.scope.storage.get(.{ .address = addr(1), .key = 2 }).?.warm);
    try std.testing.expectEqual(@as(u256, 0), try state.getTransientStorage(addr(1), 4));
}

test "direct storage writes do not warm slots" {
    var backing = TestReader{};
    var tracked = TrackedState.initWithStateReader(std.testing.allocator, backing.reader());
    defer tracked.deinit();

    _ = tracked.beginTransaction();
    tracked.beginScope();

    try std.testing.expectEqual(.modified, try tracked.setStorage(addr(1), 2, 9));
    try std.testing.expect(!tracked.isStorageWarm(addr(1), 2));
    try std.testing.expectEqual(.cold, try tracked.accessStorage(addr(1), 2));
    try std.testing.expect(tracked.isStorageWarm(addr(1), 2));
    tracked.closeScope();
}

test "tracked code cache keeps borrowed views stable across growth" {
    const original_code = [_]u8{ 0x60, 0x01, 0x00 };
    var backing = TestReader{
        .account = .{ .nonce = 3, .balance = 10, .code_hash = crypto.keccak256(&original_code) },
        .code = &original_code,
    };
    var state = TrackedState.initWithStateReader(std.testing.allocator, backing.reader());
    defer state.deinit();

    _ = state.beginTransaction();
    const original_view = try state.getCodeView(addr(1));
    try std.testing.expectEqualSlices(u8, &original_code, original_view.bytes);

    for (0..32) |index| {
        var code = [_]u8{0xaa} ** 200;
        code[0] = @intCast(index);
        try state.setCode(addr(2), &code);
    }

    try std.testing.expect(state.code.chunks.items.len > 1);
    try std.testing.expectEqualSlices(u8, &original_code, original_view.bytes);
    try std.testing.expectEqualSlices(u8, &original_code, try state.getCode(addr(1)));
}

test "code checkpoint rollback restores hash and keeps cache" {
    const original_code = [_]u8{ 0x60, 0x01, 0x00 };
    const replacement_code = [_]u8{ 0x60, 0x02, 0x60, 0x03, 0x00 };
    const account = Account{
        .nonce = 3,
        .balance = 10,
        .code_hash = crypto.keccak256(&original_code),
    };
    var backing = TestReader{ .account = account, .code = &original_code };
    var tracked = TrackedState.initWithStateReader(std.testing.allocator, backing.reader());
    defer tracked.deinit();

    const attempt = tracked.beginTransaction();
    tracked.beginScope();
    try std.testing.expectEqualSlices(u8, &original_code, try tracked.getCode(addr(1)));
    const tracked_checkpoint = tracked.checkpoint();

    try tracked.setCode(addr(1), &replacement_code);
    const replacement_hash = crypto.keccak256(&replacement_code);
    try std.testing.expectEqual(uint256.fromBytes32(&replacement_hash), try tracked.getCodeHash(addr(1)));
    try std.testing.expectEqualSlices(u8, &replacement_code, try tracked.getCode(addr(1)));

    tracked.revertToCheckpoint(tracked_checkpoint);
    const original_hash = crypto.keccak256(&original_code);
    try std.testing.expectEqual(uint256.fromBytes32(&original_hash), try tracked.getCodeHash(addr(1)));
    try std.testing.expectEqualSlices(u8, &original_code, try tracked.getCode(addr(1)));
    try std.testing.expect(tracked.code.entries.get(replacement_hash).?.introduced());

    tracked.closeScope();
    tracked.seal(attempt);
    tracked.discard(attempt);
}

test "discarded code can be reused by a retained branch and then cleared" {
    const replacement_code = [_]u8{ 0x60, 0x02, 0x00 };
    const replacement_hash = crypto.keccak256(&replacement_code);
    var backing = TestReader{};
    var state = TrackedState.initWithStateReader(std.testing.allocator, backing.reader());
    defer state.deinit();

    const discarded = state.beginTransaction();
    try state.setCode(addr(1), &replacement_code);
    state.seal(discarded);
    state.discard(discarded);
    try std.testing.expect(state.code.entries.get(replacement_hash).?.introduced());

    const retained = state.beginTransaction();
    try std.testing.expectEqualSlices(u8, &.{}, try state.getCode(addr(1)));
    try state.setCode(addr(1), &replacement_code);
    state.seal(retained);
    state.retain(retained);
    try std.testing.expect(state.accepted.introduced_code.contains(replacement_hash));
    try std.testing.expectEqualSlices(u8, &replacement_code, try state.getCode(addr(1)));
    try std.testing.expect(try state.accountHasCode(addr(1)));

    const cleared = state.beginTransaction();
    try state.clearCode(addr(1));
    state.seal(cleared);
    state.retain(cleared);
    try std.testing.expectEqualSlices(u8, &.{}, try state.getCode(addr(1)));
    try std.testing.expect(!try state.accountHasCode(addr(1)));
}

test "pending and accepted views expose native tracked state" {
    var state = TrackedState.init(std.testing.allocator);
    defer state.deinit();

    const attempt = state.beginTransaction();
    state.beginScope();
    const topics = [_]u256{7};
    try state.emitLog(.{
        .address = addr(1),
        .topics = &topics,
        .data = &.{0xaa},
    });
    try state.setBalance(addr(1), 9);
    state.closeScope();
    state.seal(attempt);

    const pending = state.pendingView();
    try std.testing.expectEqual(attempt, pending.attemptId());
    try std.testing.expectEqual(@as(u64, 0), pending.accepted().generation());
    try std.testing.expectEqual(@as(usize, 1), pending.logs().len());
    const event_log = pending.logs().get(0);
    try std.testing.expectEqual(addr(1), event_log.address);
    try std.testing.expectEqualSlices(u256, &topics, event_log.topics);
    try std.testing.expectEqualSlices(u8, &.{0xaa}, event_log.data);

    state.retain(attempt);
    const accepted = state.acceptedView();
    try std.testing.expectEqual(@as(u64, 1), accepted.generation());
    try std.testing.expect(accepted.hasChanges());
    try std.testing.expectEqual(@as(usize, 1), state.logView().len());
    try std.testing.expectEqual(addr(1), state.logView().get(0).address);
}

test "selfdestruct finalization deletes account and masks accepted storage" {
    var backing = TestReader{};
    var state = TrackedState.initWithStateReader(std.testing.allocator, backing.reader());
    defer state.deinit();

    const written = state.beginTransaction();
    state.beginScope();
    try std.testing.expectEqual(.modified, try state.setStorage(addr(1), 2, 9));
    state.closeScope();
    state.seal(written);
    state.retain(written);
    const accepted = state.acceptedView().changes();
    try std.testing.expectEqual(@as(u32, 1), accepted.storage_writes.len());
    try std.testing.expectEqual(addr(1), accepted.storage_writes.at(0).address);
    try std.testing.expectEqual(@as(u256, 2), accepted.storage_writes.at(0).key);

    const destroyed = state.beginTransaction();
    state.beginScope();
    try state.markSelfdestructed(addr(1));
    const before_finalize = state.checkpoint();
    try state.finalize(.{ .existing_account = .{
        .delete_account = true,
        .clear_storage = true,
    } });

    try std.testing.expect(state.getAccount(addr(1)) == null);
    try std.testing.expectEqual(@as(u256, 0), try state.getStorage(addr(1), 2));
    try std.testing.expect(!try state.accountHasStorage(addr(1)));
    try std.testing.expect(!state.wasSelfdestructed(addr(1)));

    state.revertToCheckpoint(before_finalize);
    try std.testing.expect(state.wasSelfdestructed(addr(1)));
    try std.testing.expectEqual(@as(u256, 10), try state.getBalance(addr(1)));
    try std.testing.expectEqual(@as(u256, 9), try state.getStorage(addr(1), 2));

    try state.finalize(.{ .existing_account = .{
        .delete_account = true,
        .clear_storage = true,
    } });
    state.closeScope();
    state.seal(destroyed);
    state.retain(destroyed);

    try std.testing.expect(state.getAccount(addr(1)) == null);
    try std.testing.expectEqual(@as(u256, 0), try state.getStorage(addr(1), 2));
    try std.testing.expect(!try state.accountHasStorage(addr(1)));
    const accepted_after_delete = state.acceptedView().changes();
    try std.testing.expectEqual(@as(u32, 1), accepted_after_delete.accounts.len());
    try std.testing.expect(accepted_after_delete.accounts.at(0).account == null);
    try std.testing.expectEqual(@as(u32, 1), accepted_after_delete.storage_wipes.len());
    try std.testing.expectEqual(addr(1), accepted_after_delete.storage_wipes.at(0));
    try std.testing.expectEqual(@as(u32, 0), accepted_after_delete.storage_writes.len());
}

test "Cancun existing-account selfdestruct only clears lifecycle marker" {
    var backing = TestReader{};
    var state = TrackedState.initWithStateReader(std.testing.allocator, backing.reader());
    defer state.deinit();

    const attempt = state.beginTransaction();
    state.beginScope();
    try state.markSelfdestructed(addr(1));
    try state.finalize(.{});

    try std.testing.expect(!state.wasSelfdestructed(addr(1)));
    try std.testing.expectEqual(@as(u256, 10), try state.getBalance(addr(1)));
    try std.testing.expectEqual(@as(u256, 7), try state.getStorage(addr(1), 2));

    state.closeScope();
    state.seal(attempt);
    state.retain(attempt);
    try std.testing.expectEqual(@as(u256, 10), try state.getBalance(addr(1)));
    try std.testing.expectEqual(@as(u256, 7), try state.getStorage(addr(1), 2));
}

test "created-account finalization resets code nonce and storage" {
    var state = TrackedState.init(std.testing.allocator);
    defer state.deinit();

    const created = state.beginTransaction();
    state.beginScope();
    try state.setNonce(addr(2), 9);
    try state.setCode(addr(2), &.{ 0xaa, 0xbb });
    try std.testing.expectEqual(.added, try state.setStorage(addr(2), 7, 13));
    try state.markCreatedContract(addr(2));
    try state.markSelfdestructed(addr(2));
    try state.finalize(.{ .created_account = .{
        .clear_storage = true,
        .reset_account = true,
    } });

    try std.testing.expect(state.getAccount(addr(2)) != null);
    try std.testing.expectEqual(@as(u64, 0), try state.getNonce(addr(2)));
    try std.testing.expectEqualSlices(u8, &.{}, try state.getCode(addr(2)));
    try std.testing.expectEqual(@as(u256, 0), try state.getStorage(addr(2), 7));
    try std.testing.expect(!state.createdInTransaction(addr(2)));
    try std.testing.expect(!state.wasSelfdestructed(addr(2)));

    state.closeScope();
    state.seal(created);
    state.retain(created);

    const rewritten = state.beginTransaction();
    state.beginScope();
    try std.testing.expectEqual(.added, try state.setStorage(addr(2), 7, 11));
    state.closeScope();
    state.seal(rewritten);
    state.retain(rewritten);

    try std.testing.expectEqual(@as(u256, 11), try state.getStorage(addr(2), 7));
    try std.testing.expectEqual(@as(u256, 0), try state.getStorage(addr(2), 8));
    try std.testing.expect(try state.accountHasStorage(addr(2)));
}

test "finalization allocation failure preserves enclosing transaction" {
    var failing_allocator = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var backing = TestReader{};
    var state = TrackedState.initWithStateReader(failing_allocator.allocator(), backing.reader());
    defer state.deinit();

    _ = state.beginTransaction();
    state.beginScope();
    try std.testing.expectEqual(@as(u256, 7), try state.getStorage(addr(1), 2));
    try state.markSelfdestructed(addr(1));
    const journal_len = state.journalEntryCount();

    failing_allocator.fail_index = failing_allocator.alloc_index;
    try std.testing.expectError(error.OutOfMemory, state.finalize(.{ .existing_account = .{
        .delete_account = true,
        .clear_storage = true,
    } }));

    try std.testing.expect(failing_allocator.has_induced_failure);
    try std.testing.expectEqual(journal_len, state.journalEntryCount());
    try std.testing.expect(state.wasSelfdestructed(addr(1)));
    try std.testing.expectEqual(@as(u256, 10), state.getAccount(addr(1)).?.balance);
    try std.testing.expectEqual(@as(u256, 7), try state.getStorage(addr(1), 2));
}

test "lifecycle candidates are compact and survive marker rollback" {
    var state = TrackedState.init(std.testing.allocator);
    defer state.deinit();

    _ = state.beginTransaction();
    state.beginScope();
    const checkpoint = state.checkpoint();

    try state.markCreatedContract(addr(1));
    try state.markSelfdestructed(addr(1));
    try std.testing.expectEqual(@as(usize, 1), state.tx.?.lifecycle_accounts.items.len);

    state.revertToCheckpoint(checkpoint);
    try std.testing.expect(!state.createdInTransaction(addr(1)));
    try std.testing.expect(!state.wasSelfdestructed(addr(1)));
    try std.testing.expectEqual(@as(usize, 1), state.tx.?.lifecycle_accounts.items.len);

    try state.markSelfdestructed(addr(1));
    try std.testing.expectEqual(@as(usize, 1), state.tx.?.lifecycle_accounts.items.len);
}

test "storage presence conservatively preserves a partially cleared base" {
    var backing = TestReader{};
    var state = TrackedState.initWithStateReader(std.testing.allocator, backing.reader());
    defer state.deinit();

    _ = state.beginTransaction();
    state.beginScope();
    try std.testing.expectEqual(.deleted, try state.setStorage(addr(1), 2, 0));

    try std.testing.expect(try state.accountHasStorage(addr(1)));
}

test "pending changes are transaction local and accepted changes accumulate" {
    var state = TrackedState.init(std.testing.allocator);
    defer state.deinit();

    const first_code = [_]u8{0xaa};
    const first_hash = crypto.keccak256(&first_code);
    const first = state.beginTransaction();
    state.beginScope();
    try state.setBalance(addr(1), 11);
    try state.setCode(addr(1), &first_code);
    _ = try state.setStorage(addr(1), 1, 111);
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
    try state.setBalance(addr(2), 22);
    try state.setCode(addr(2), &second_code);
    _ = try state.setStorage(addr(2), 2, 222);
    state.closeScope();
    state.seal(second);

    const pending = state.pendingView().changes();
    try std.testing.expectEqual(@as(u32, 1), pending.accounts.len());
    try std.testing.expectEqual(addr(2), pending.accounts.at(0).address);
    try std.testing.expectEqual(@as(u32, 1), pending.storage_writes.len());
    try std.testing.expect(pending.introducedCode(first_hash) == null);
    try std.testing.expectEqualSlices(u8, &second_code, pending.introducedCode(second_hash).?.bytes);

    state.retain(second);
    const accepted_second = state.acceptedView().changes();
    try std.testing.expectEqual(@as(u32, 2), accepted_second.accounts.len());
    try std.testing.expectEqual(@as(u32, 2), accepted_second.storage_writes.len());
    try std.testing.expectEqualSlices(u8, &first_code, accepted_second.introducedCode(first_hash).?.bytes);
    try std.testing.expectEqualSlices(u8, &second_code, accepted_second.introducedCode(second_hash).?.bytes);
}

test "checkpoint rollback truncates dense change ids" {
    var state = TrackedState.init(std.testing.allocator);
    defer state.deinit();

    const attempt = state.beginTransaction();
    state.beginScope();
    const checkpoint = state.checkpoint();
    try state.setBalance(addr(1), 1);
    _ = try state.setStorage(addr(1), 1, 11);
    state.revertToCheckpoint(checkpoint);

    try state.setBalance(addr(2), 2);
    _ = try state.setStorage(addr(2), 2, 22);
    state.closeScope();
    state.seal(attempt);

    const changes = state.pendingView().changes();
    try std.testing.expectEqual(@as(u32, 1), changes.accounts.len());
    try std.testing.expectEqual(addr(2), changes.accounts.at(0).address);
    try std.testing.expectEqual(@as(u32, 1), changes.storage_writes.len());
    try std.testing.expectEqual(addr(2), changes.storage_writes.at(0).address);
}

test "accepted branch checkpoint restores cumulative state and is reusable" {
    var state = TrackedState.init(std.testing.allocator);
    defer state.deinit();

    const baseline_code = [_]u8{0xaa};
    const baseline_hash = crypto.keccak256(&baseline_code);
    const baseline = state.beginTransaction();
    state.beginScope();
    try state.setBalance(addr(1), 11);
    try state.setCode(addr(1), &baseline_code);
    try std.testing.expectEqual(.added, try state.setStorage(addr(1), 2, 22));
    try state.emitLog(.{
        .address = addr(1),
        .topics = &.{3},
        .data = &.{0x44},
    });
    state.closeScope();
    state.seal(baseline);
    state.retain(baseline);

    var checkpoint_state = try state.branchCheckpoint();
    defer checkpoint_state.deinit();

    const destroyed = state.beginTransaction();
    state.beginScope();
    try state.markSelfdestructed(addr(1));
    try state.finalize(.{ .existing_account = .{
        .delete_account = true,
        .clear_storage = true,
    } });
    state.closeScope();
    state.seal(destroyed);
    state.retain(destroyed);
    try std.testing.expect(state.getAccount(addr(1)) == null);
    try std.testing.expectEqual(@as(u32, 1), state.acceptedView().changes().storage_wipes.len());

    var first_restore = try checkpoint_state.clone();
    defer first_restore.deinit();
    state.restoreBranch(&first_restore);
    try std.testing.expectEqual(@as(u64, 1), state.acceptedView().generation());
    try std.testing.expectEqual(@as(u256, 11), try state.getBalance(addr(1)));
    try std.testing.expectEqual(@as(u256, 22), try state.getStorage(addr(1), 2));
    try std.testing.expectEqualSlices(u8, &baseline_code, try state.getCode(addr(1)));
    try std.testing.expectEqual(@as(usize, 1), state.logView().len());
    const restored_changes = state.acceptedView().changes();
    try std.testing.expectEqual(@as(u32, 0), restored_changes.storage_wipes.len());
    try std.testing.expect(restored_changes.introducedCode(baseline_hash) != null);

    const later = state.beginTransaction();
    state.beginScope();
    try state.setBalance(addr(2), 33);
    state.closeScope();
    state.seal(later);
    state.retain(later);
    try std.testing.expectEqual(@as(u256, 33), try state.getBalance(addr(2)));

    var second_restore = try checkpoint_state.clone();
    defer second_restore.deinit();
    state.restoreBranch(&second_restore);
    try std.testing.expectEqual(@as(u256, 0), try state.getBalance(addr(2)));
    try std.testing.expectEqual(@as(u256, 11), try state.getBalance(addr(1)));
}

test "transaction branch checkpoint reuses the scope journal" {
    var state = TrackedState.init(std.testing.allocator);
    defer state.deinit();

    const attempt = state.beginTransaction();
    state.beginScope();
    try state.setBalance(addr(1), 11);
    try state.emitLog(.{
        .address = addr(1),
        .topics = &.{1},
        .data = &.{0x11},
    });

    var checkpoint_state = try state.branchCheckpoint();
    defer checkpoint_state.deinit();
    try state.setBalance(addr(1), 22);
    try std.testing.expectEqual(.added, try state.setStorage(addr(1), 2, 33));
    try state.emitLog(.{
        .address = addr(1),
        .topics = &.{2},
        .data = &.{0x22},
    });

    state.restoreBranch(&checkpoint_state);
    try std.testing.expectEqual(@as(u256, 11), try state.getBalance(addr(1)));
    try std.testing.expectEqual(@as(u256, 0), try state.getStorage(addr(1), 2));
    try std.testing.expectEqual(@as(usize, 1), state.logView().len());

    state.closeScope();
    state.seal(attempt);
    state.retain(attempt);
    const changes = state.acceptedView().changes();
    try std.testing.expectEqual(@as(u32, 1), changes.accounts.len());
    try std.testing.expectEqual(@as(u256, 11), changes.accounts.at(0).account.?.balance);
    try std.testing.expectEqual(@as(u32, 0), changes.storage_writes.len());
}

test "accepted branch checkpoint clone failure leaves current state unchanged" {
    var failing_allocator = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var state = TrackedState.init(failing_allocator.allocator());
    defer state.deinit();

    const baseline = state.beginTransaction();
    state.beginScope();
    try state.setBalance(addr(1), 11);
    state.closeScope();
    state.seal(baseline);
    state.retain(baseline);
    var checkpoint_state = try state.branchCheckpoint();
    defer checkpoint_state.deinit();

    const later = state.beginTransaction();
    state.beginScope();
    try state.setBalance(addr(1), 22);
    state.closeScope();
    state.seal(later);
    state.retain(later);

    failing_allocator.fail_index = failing_allocator.alloc_index;
    try std.testing.expectError(error.OutOfMemory, checkpoint_state.clone());
    try std.testing.expect(failing_allocator.has_induced_failure);
    try std.testing.expectEqual(@as(u64, 2), state.acceptedView().generation());
    try std.testing.expectEqual(@as(u256, 22), try state.getBalance(addr(1)));

    failing_allocator.fail_index = std.math.maxInt(usize);
    var restore = try checkpoint_state.clone();
    defer restore.deinit();
    state.restoreBranch(&restore);
    try std.testing.expectEqual(@as(u64, 1), state.acceptedView().generation());
    try std.testing.expectEqual(@as(u256, 11), try state.getBalance(addr(1)));
}

test "accepted branch restore does not allocate after capture" {
    var failing_allocator = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var state = TrackedState.init(failing_allocator.allocator());
    defer state.deinit();

    const baseline = state.beginTransaction();
    state.beginScope();
    try state.setBalance(addr(1), 11);
    state.closeScope();
    state.seal(baseline);
    state.retain(baseline);
    var checkpoint_state = try state.branchCheckpoint();
    defer checkpoint_state.deinit();

    const later = state.beginTransaction();
    state.beginScope();
    try state.setBalance(addr(1), 22);
    state.closeScope();
    state.seal(later);
    state.retain(later);

    failing_allocator.fail_index = failing_allocator.alloc_index;
    state.restoreBranch(&checkpoint_state);
    try std.testing.expect(!failing_allocator.has_induced_failure);
    try std.testing.expectEqual(@as(u64, 1), state.acceptedView().generation());
    try std.testing.expectEqual(@as(u256, 11), try state.getBalance(addr(1)));
}
