const std = @import("std");
const evmz = @import("../evm.zig");
const Host = @import("../Host.zig");
const trace = @import("../trace.zig");
const capture_context = @import("../executor/capture_context.zig");
const CaptureContext = capture_context.Context;
const Address = evmz.Address;
const AccountState = @import("./Account.zig");
const MemoryAccount = @import("./MemoryAccount.zig");
const storage = @import("./storage.zig");
const StorageKey = storage.Key;
const StateReader = @import("./Reader.zig");
const MemoryStore = @import("./MemoryStore.zig");
const Overlay = @import("./Overlay.zig");

const EthereumFinalizer = struct {
    revision: evmz.Evm.ExecutionProtocol.Revision,

    pub fn selfDestructFinalization(
        self: @This(),
        created_in_transaction: bool,
    ) evmz.protocol.SelfDestructFinalization {
        return evmz.Evm.ExecutionProtocol.self_destruct.selfDestructFinalization(self.revision, created_in_transaction);
    }
};

fn ethereumFinalizer(revision: evmz.Evm.ExecutionProtocol.Revision) EthereumFinalizer {
    return .{ .revision = revision };
}

test "snapshot restores accounts and warm state" {
    var overlay = Overlay.init(std.testing.allocator);
    defer overlay.deinit();

    const test_address = evmz.addr(1);
    var account = try overlay.getOrCreateAccount(test_address);
    account.balance = 7;
    try overlay.warm_accounts.put(test_address, {});

    var snapshot_state = try overlay.snapshot();
    defer snapshot_state.deinit(std.testing.allocator);

    account = try overlay.getOrCreateAccount(test_address);
    account.balance = 9;
    overlay.warm_accounts.clearRetainingCapacity();

    try overlay.restore(&snapshot_state);
    try std.testing.expectEqual(@as(u256, 7), overlay.getAccount(test_address).?.balance);
    try std.testing.expect(overlay.warm_accounts.contains(test_address));
}

test "snapshot restore drops warm state added after the snapshot" {
    var overlay = Overlay.init(std.testing.allocator);
    defer overlay.deinit();

    const warm_before = evmz.addr(1);
    const warm_after = evmz.addr(2);
    try overlay.warm_accounts.put(warm_before, {});
    try overlay.warmStorage(warm_before, 1);

    var snapshot_state = try overlay.snapshot();
    defer snapshot_state.deinit(std.testing.allocator);

    try overlay.warm_accounts.put(warm_after, {});
    try overlay.warmStorage(warm_after, 2);

    try overlay.restore(&snapshot_state);
    try std.testing.expect(overlay.warm_accounts.contains(warm_before));
    try std.testing.expect(!overlay.warm_accounts.contains(warm_after));
    try std.testing.expect(overlay.isStorageWarm(warm_before, 1));
    try std.testing.expect(!overlay.isStorageWarm(warm_after, 2));
}

test "snapshot restore preserves authoritative fused storage slots" {
    var overlay = Overlay.init(std.testing.allocator);
    defer overlay.deinit();

    const address = evmz.addr(1);
    const key = 7;
    overlay.beginTransaction();
    try std.testing.expectEqual(Host.AccessStatus.cold, (try overlay.storeStorage(address, key, 1)).access_status);

    var snapshot_state = try overlay.snapshot();
    defer snapshot_state.deinit(std.testing.allocator);

    try std.testing.expectEqual(Host.StorageStatus.assigned, (try overlay.storeStorage(address, key, 1)).storage_status);
    try std.testing.expectEqual(Host.StorageStatus.assigned, (try overlay.storeStorage(address, key, 2)).storage_status);
    try std.testing.expectEqual(@as(u256, 2), try overlay.getStorage(address, key));

    try overlay.restore(&snapshot_state);
    try std.testing.expectEqual(@as(usize, 1), overlay.storage_slots.count());
    try std.testing.expect(overlay.storage_slots.get(.{ .address = address, .key = key }).?.dirty);
    try std.testing.expect(!overlay.storage_overlay.contains(.{ .address = address, .key = key }));
    try std.testing.expectEqual(@as(u256, 1), try overlay.getStorage(address, key));
}

test "journal checkpoint reverts storage and preserves original storage" {
    var overlay = Overlay.init(std.testing.allocator);
    defer overlay.deinit();

    const address = evmz.addr(0xbeef);
    const key = 7;
    var account = MemoryAccount.init(std.testing.allocator);
    try account.storage.put(key, 1);
    try overlay.seedAccount(address, account);

    overlay.beginTransaction();
    const checkpoint_state = try overlay.checkpoint();

    try std.testing.expectEqual(Host.StorageStatus.modified, try overlay.setStorage(address, key, 2));
    try std.testing.expectEqual(@as(u256, 2), try overlay.getStorage(address, key));

    try overlay.revertToCheckpoint(checkpoint_state);
    try std.testing.expectEqual(@as(u256, 1), try overlay.getStorage(address, key));
    try std.testing.expectEqual(@as(u256, 1), try overlay.getStorage(address, key));
    try std.testing.expect(!overlay.storage_overlay.contains(.{ .address = address, .key = key }));
    try std.testing.expectEqual(@as(usize, 1), overlay.originalStorageCount());
    try std.testing.expectEqual(@as(u256, 1), overlay.storage_slots.get(.{ .address = address, .key = key }).?.original);
}

test "storage slots hold dirty truth until transaction close" {
    var overlay = Overlay.init(std.testing.allocator);
    defer overlay.deinit();

    const address = evmz.addr(0xbeef);
    const key = 7;
    var account = MemoryAccount.init(std.testing.allocator);
    try account.storage.put(key, 1);
    try overlay.seedAccount(address, account);

    overlay.beginTransaction();
    try std.testing.expectEqual(Host.StorageStatus.modified, try overlay.setStorage(address, key, 2));

    try std.testing.expectEqual(@as(u256, 2), try overlay.getStorage(address, key));
    try std.testing.expectEqual(@as(u256, 1), overlay.seeded_storage.get(.{ .address = address, .key = key }).?);
    try std.testing.expect(!overlay.storage_overlay.contains(.{ .address = address, .key = key }));
    const slot = overlay.storage_slots.get(.{ .address = address, .key = key }).?;
    try std.testing.expect(slot.dirty);
    try std.testing.expectEqual(@as(u256, 2), slot.current);
}

test "unchanged dirty storage write does not journal again" {
    var overlay = Overlay.init(std.testing.allocator);
    defer overlay.deinit();

    const address = evmz.addr(0xbeef);
    const key = 7;

    overlay.beginTransaction();
    try std.testing.expectEqual(Host.StorageStatus.added, try overlay.setStorage(address, key, 2));
    const journal_len = overlay.journal.len();

    try std.testing.expectEqual(Host.StorageStatus.assigned, try overlay.setStorage(address, key, 2));
    try std.testing.expectEqual(journal_len, overlay.journal.len());
    try std.testing.expect(!overlay.storage_overlay.contains(.{ .address = address, .key = key }));
    try std.testing.expectEqual(@as(u256, 2), overlay.storage_slots.get(.{ .address = address, .key = key }).?.current);
}

test "unchanged storage write does not journal or dirty overlay" {
    var overlay = Overlay.init(std.testing.allocator);
    defer overlay.deinit();

    const address = evmz.addr(0xbeef);
    const key = 7;
    var account = MemoryAccount.init(std.testing.allocator);
    try account.storage.put(key, 1);
    try overlay.seedAccount(address, account);

    overlay.beginTransaction();
    try std.testing.expectEqual(Host.StorageStatus.assigned, try overlay.setStorage(address, key, 1));

    try std.testing.expectEqual(@as(usize, 0), overlay.journal.len());
    try std.testing.expect(!overlay.storage_overlay.contains(.{ .address = address, .key = key }));
    try std.testing.expectEqual(@as(usize, 1), overlay.originalStorageCount());
    try std.testing.expectEqual(@as(u256, 1), overlay.storage_slots.get(.{ .address = address, .key = key }).?.original);
}

test "transaction close clears tx-local state but keeps surviving overlay writes" {
    var overlay = Overlay.init(std.testing.allocator);
    defer overlay.deinit();

    const address = evmz.addr(0xbeef);
    const key = 7;
    const topic = [_]u256{42};
    const data = [_]u8{0xaa};

    overlay.beginTransaction();
    try overlay.warmAccount(address);
    try overlay.warmStorage(address, key);
    try overlay.setTransientStorage(address, key, 99);
    try std.testing.expectEqual(Host.StorageStatus.added, try overlay.setStorage(address, key, 2));
    try overlay.emitLog(.{
        .address = address,
        .topics = &topic,
        .data = &data,
    });

    try std.testing.expect(overlay.journal.len() > 0);
    try std.testing.expectEqual(@as(u256, 2), try overlay.getStorage(address, key));

    overlay.closeTransaction();

    try std.testing.expectEqual(@as(usize, 0), overlay.journal.len());
    try std.testing.expectEqual(@as(usize, 0), overlay.warm_accounts.count());
    try std.testing.expectEqual(@as(usize, 0), overlay.warmStorageCount());
    try std.testing.expectEqual(@as(usize, 0), overlay.transient_storage.count());
    try std.testing.expectEqual(@as(usize, 0), overlay.originalStorageCount());
    try std.testing.expectEqual(@as(usize, 1), overlay.logs.items.len);
    try std.testing.expectEqual(@as(u256, 2), try overlay.getStorage(address, key));

    overlay.beginTransaction();
    try std.testing.expectEqual(@as(usize, 0), overlay.logs.items.len);
    try std.testing.expectEqual(@as(u256, 2), try overlay.getStorage(address, key));
}

test "fused storage slots share value warmth and original across rollback and transaction close" {
    var overlay = Overlay.init(std.testing.allocator);
    defer overlay.deinit();

    const address = evmz.addr(0xbeef);
    const key = 7;
    const storage_key = StorageKey{ .address = address, .key = key };
    var account = MemoryAccount.init(std.testing.allocator);
    try account.storage.put(key, 1);
    try overlay.seedAccount(address, account);

    overlay.beginTransaction();
    const checkpoint_state = try overlay.checkpoint();

    const cold_load = try overlay.loadStorage(address, key);
    try std.testing.expectEqual(Host.AccessStatus.cold, cold_load.access_status);
    try std.testing.expectEqual(@as(u256, 1), cold_load.value);
    try std.testing.expectEqual(Host.AccessStatus.warm, (try overlay.loadStorage(address, key)).access_status);

    const write = try overlay.storeStorage(address, key, 2);
    try std.testing.expectEqual(Host.AccessStatus.warm, write.access_status);
    try std.testing.expectEqual(Host.StorageStatus.modified, write.storage_status);
    try std.testing.expectEqual(@as(u256, 2), try overlay.getStorage(address, key));

    try overlay.revertToCheckpoint(checkpoint_state);
    try std.testing.expect(!overlay.isStorageWarm(storage_key.address, storage_key.key));
    try std.testing.expect(overlay.storage_slots.contains(storage_key));
    try std.testing.expect(overlay.storage_slots.get(storage_key).?.original_recorded);
    try std.testing.expectEqual(@as(u256, 1), try overlay.getStorage(address, key));

    try std.testing.expectEqual(Host.AccessStatus.cold, (try overlay.storeStorage(address, key, 2)).access_status);
    overlay.closeTransaction();
    try std.testing.expectEqual(@as(usize, 0), overlay.storage_slots.count());

    overlay.beginTransaction();
    const next_transaction = try overlay.loadStorage(address, key);
    try std.testing.expectEqual(Host.AccessStatus.cold, next_transaction.access_status);
    try std.testing.expectEqual(@as(u256, 2), next_transaction.value);
    try std.testing.expectEqual(@as(u256, 2), overlay.storage_slots.get(storage_key).?.original);
}

test "execution scopes retain writes but reset transaction-local storage state" {
    var overlay = Overlay.init(std.testing.allocator);
    defer overlay.deinit();

    const address = evmz.addr(0xbeef);
    const key = 7;
    const storage_key = StorageKey{ .address = address, .key = key };
    var account = MemoryAccount.init(std.testing.allocator);
    try account.storage.put(key, 1);
    try overlay.seedAccount(address, account);

    const transaction_checkpoint = try overlay.checkpoint();

    const prelude_journal_start = overlay.beginExecutionScope();
    try std.testing.expectEqual(Host.AccessStatus.cold, (try overlay.storeStorage(address, key, 2)).access_status);
    try overlay.setTransientStorage(address, key, 9);
    try overlay.closeExecutionScope(prelude_journal_start);

    try std.testing.expectEqual(@as(u256, 2), try overlay.getStorage(address, key));
    try std.testing.expectEqual(@as(usize, 0), overlay.storage_slots.count());
    try std.testing.expectEqual(@as(usize, 0), overlay.warmStorageCount());
    try std.testing.expectEqual(@as(usize, 0), overlay.originalStorageCount());
    try std.testing.expectEqual(@as(usize, 0), overlay.transient_storage.count());

    const payload_journal_start = overlay.beginExecutionScope();
    const payload_load = try overlay.loadStorage(address, key);
    try std.testing.expectEqual(Host.AccessStatus.cold, payload_load.access_status);
    try std.testing.expectEqual(@as(u256, 2), payload_load.value);
    try std.testing.expectEqual(@as(u256, 2), overlay.storage_slots.get(storage_key).?.original);
    try std.testing.expectEqual(@as(u256, 0), try overlay.getTransientStorage(address, key));
    try std.testing.expectEqual(Host.StorageStatus.modified, try overlay.setStorage(address, key, 3));
    try overlay.closeExecutionScope(payload_journal_start);

    try std.testing.expectEqual(@as(u256, 3), try overlay.getStorage(address, key));
    try overlay.revertToCheckpoint(transaction_checkpoint);
    try std.testing.expect(!overlay.storage_overlay.contains(storage_key));
    try std.testing.expectEqual(@as(u256, 1), try overlay.getStorage(address, key));
}

test "fused storage writes merge into accepted overlay only when transaction closes" {
    var overlay = Overlay.init(std.testing.allocator);
    defer overlay.deinit();

    const address = evmz.addr(0xbeef);
    const key = 7;
    const storage_key = StorageKey{ .address = address, .key = key };

    overlay.beginTransaction();
    const write = try overlay.storeStorage(address, key, 2);
    try std.testing.expectEqual(Host.StorageStatus.added, write.storage_status);
    try std.testing.expect(!overlay.storage_overlay.contains(storage_key));
    try std.testing.expectEqual(@as(usize, 1), overlay.pending_storage_overlay_entries);
    try std.testing.expectEqual(@as(u256, 2), try overlay.getStorage(address, key));

    var pending_delta = try overlay.changeset();
    defer pending_delta.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), pending_delta.storage_writes.items.len);
    try std.testing.expectEqual(@as(u256, 2), pending_delta.storage_writes.items[0].value);

    overlay.closeTransaction();
    try std.testing.expectEqual(@as(usize, 0), overlay.pending_storage_overlay_entries);
    try std.testing.expectEqual(@as(u256, 2), overlay.storage_overlay.get(storage_key).?);
}

test "reverted fused storage write releases pending overlay reservation" {
    var overlay = Overlay.init(std.testing.allocator);
    defer overlay.deinit();

    const address = evmz.addr(0xbeef);
    const key = 7;
    const storage_key = StorageKey{ .address = address, .key = key };

    overlay.beginTransaction();
    const checkpoint_state = try overlay.checkpoint();
    _ = try overlay.storeStorage(address, key, 2);
    try std.testing.expectEqual(@as(usize, 1), overlay.pending_storage_overlay_entries);

    try overlay.revertToCheckpoint(checkpoint_state);
    try std.testing.expectEqual(@as(usize, 0), overlay.pending_storage_overlay_entries);
    try std.testing.expect(!overlay.storage_overlay.contains(storage_key));

    overlay.closeTransaction();
    try std.testing.expect(!overlay.storage_overlay.contains(storage_key));
}

test "fused storage reserves an allocation-free accepted-overlay merge" {
    var failing_allocator = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var overlay = Overlay.init(failing_allocator.allocator());
    defer overlay.deinit();

    overlay.beginTransaction();
    _ = try overlay.storeStorage(evmz.addr(0xbeef), 7, 2);

    failing_allocator.fail_index = failing_allocator.alloc_index;
    overlay.closeTransaction();
    try std.testing.expect(!failing_allocator.has_induced_failure);
    try std.testing.expectEqual(@as(u256, 2), overlay.storage_overlay.get(.{
        .address = evmz.addr(0xbeef),
        .key = 7,
    }).?);
}

test "journal checkpoint reverts transient storage warm state and logs" {
    var overlay = Overlay.init(std.testing.allocator);
    defer overlay.deinit();

    const warm_before = evmz.addr(1);
    const warm_after = evmz.addr(2);
    const storage_key = StorageKey{ .address = warm_after, .key = 3 };
    const topic = [_]u256{42};
    const data = [_]u8{0xaa};

    overlay.beginTransaction();
    try overlay.warmAccount(warm_before);
    const checkpoint_state = try overlay.checkpoint();

    try overlay.warmAccount(warm_before);
    try overlay.warmAccount(warm_after);
    try overlay.warmStorage(storage_key.address, storage_key.key);
    try overlay.setTransientStorage(warm_after, storage_key.key, 99);
    try overlay.emitLog(.{
        .address = warm_after,
        .topics = &topic,
        .data = &data,
    });

    try std.testing.expect(overlay.warm_accounts.contains(warm_after));
    try std.testing.expect(overlay.isStorageWarm(storage_key.address, storage_key.key));
    try std.testing.expectEqual(@as(u256, 99), try overlay.getTransientStorage(warm_after, storage_key.key));
    try std.testing.expectEqual(@as(usize, 1), overlay.logs.items.len);

    try overlay.revertToCheckpoint(checkpoint_state);
    try std.testing.expect(overlay.warm_accounts.contains(warm_before));
    try std.testing.expect(!overlay.warm_accounts.contains(warm_after));
    try std.testing.expect(!overlay.isStorageWarm(storage_key.address, storage_key.key));
    try std.testing.expectEqual(@as(u256, 0), try overlay.getTransientStorage(warm_after, storage_key.key));
    try std.testing.expectEqual(@as(usize, 0), overlay.logs.items.len);
}

test "transient storage allocation failure leaves journal and state unchanged" {
    var failing_allocator = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var overlay = Overlay.init(failing_allocator.allocator());
    defer overlay.deinit();
    try overlay.configureJournalEntries(1);

    failing_allocator.fail_index = failing_allocator.alloc_index;
    try std.testing.expectError(
        error.OutOfMemory,
        overlay.setTransientStorage(evmz.addr(1), 1, 99),
    );

    try std.testing.expect(failing_allocator.has_induced_failure);
    try std.testing.expectEqual(@as(usize, 0), overlay.journal.len());
    try std.testing.expectEqual(@as(usize, 0), overlay.transient_storage.count());
    try std.testing.expectEqual(@as(u256, 0), try overlay.getTransientStorage(evmz.addr(1), 1));
}

test "bounded logs copy into fixed storage and rollback" {
    var overlay = Overlay.init(std.testing.allocator);
    defer overlay.deinit();
    try overlay.configureLogResources(.{ .entries = 2, .data_bytes = 3 });

    const address = evmz.addr(0xbeef);
    const topics = [_]u256{ 1, 2 };
    const data = [_]u8{ 0xaa, 0xbb };

    overlay.beginTransaction();
    const checkpoint_state = try overlay.checkpoint();
    try overlay.emitLog(.{
        .address = address,
        .topics = &topics,
        .data = &data,
    });

    try std.testing.expectEqual(@as(usize, 1), overlay.logs.items.len);
    try std.testing.expectEqualSlices(u256, &topics, overlay.logs.items[0].topics);
    try std.testing.expectEqualSlices(u8, &data, overlay.logs.items[0].data);
    try std.testing.expectEqual(@as(usize, 1), overlay.bounded_log_topics.items.len);
    try std.testing.expectEqual(@as(usize, 2), overlay.bounded_log_data.items.len);

    try overlay.revertToCheckpoint(checkpoint_state);
    try std.testing.expectEqual(@as(usize, 0), overlay.logs.items.len);
    try std.testing.expectEqual(@as(usize, 0), overlay.bounded_log_topics.items.len);
    try std.testing.expectEqual(@as(usize, 0), overlay.bounded_log_data.items.len);
}

test "bounded logs report capacity exhaustion" {
    var overlay = Overlay.init(std.testing.allocator);
    defer overlay.deinit();
    try overlay.configureLogResources(.{ .entries = 1, .data_bytes = 1 });

    const address = evmz.addr(0xbeef);
    const topic = [_]u256{42};
    const data = [_]u8{0xaa};
    try overlay.emitLog(.{
        .address = address,
        .topics = &topic,
        .data = &data,
    });
    try std.testing.expectError(error.LogCapacityExceeded, overlay.emitLog(.{
        .address = address,
        .topics = &topic,
        .data = &.{},
    }));
    try std.testing.expectError(error.LogDataCapacityExceeded, blk: {
        var fresh = Overlay.init(std.testing.allocator);
        defer fresh.deinit();
        try fresh.configureLogResources(.{ .entries = 1, .data_bytes = 1 });
        break :blk fresh.emitLog(.{
            .address = address,
            .topics = &topic,
            .data = &[_]u8{ 0xaa, 0xbb },
        });
    });
    try std.testing.expectError(error.LogTopicCapacityExceeded, blk: {
        var fresh = Overlay.init(std.testing.allocator);
        defer fresh.deinit();
        try fresh.configureLogResources(.{ .entries = 1, .data_bytes = 0 });
        const too_many_topics = [_]u256{ 1, 2, 3, 4, 5 };
        break :blk fresh.emitLog(.{
            .address = address,
            .topics = &too_many_topics,
            .data = &.{},
        });
    });
}

test "bounded journal rows report capacity exhaustion" {
    var overlay = Overlay.init(std.testing.allocator);
    defer overlay.deinit();
    try overlay.configureJournalEntries(1);

    overlay.beginTransaction();
    try overlay.warmAccount(evmz.addr(1));
    try std.testing.expectError(error.JournalCapacityExceeded, overlay.warmAccount(evmz.addr(2)));

    overlay.closeTransaction();
    try overlay.warmAccount(evmz.addr(3));
}

test "bounded warm access sets report capacity exhaustion" {
    var overlay = Overlay.init(std.testing.allocator);
    defer overlay.deinit();
    try overlay.configureJournalEntries(4);
    try overlay.configureAccessResources(.{ .accounts = 1, .storage_keys = 1 });

    overlay.beginTransaction();
    try overlay.warmAccount(evmz.addr(1));
    try std.testing.expectError(error.WarmAccountCapacityExceeded, overlay.warmAccount(evmz.addr(2)));

    try overlay.warmStorage(evmz.addr(1), 1);
    try std.testing.expectError(error.WarmStorageCapacityExceeded, overlay.warmStorage(evmz.addr(1), 2));

    overlay.closeTransaction();
    try overlay.warmAccount(evmz.addr(3));
    try overlay.warmStorage(evmz.addr(3), 3);
}

test "bounded fused storage lookup removes rejected cache insertion" {
    var overlay = Overlay.init(std.testing.allocator);
    defer overlay.deinit();
    try overlay.configureJournalEntries(4);
    try overlay.configureAccessResources(.{ .accounts = 0, .storage_keys = 1 });

    overlay.beginTransaction();
    try std.testing.expectEqual(Host.AccessStatus.cold, (try overlay.loadStorage(evmz.addr(1), 1)).access_status);
    try std.testing.expectError(error.WarmStorageCapacityExceeded, overlay.loadStorage(evmz.addr(1), 2));
    try std.testing.expectEqual(@as(u32, 1), overlay.storage_slots.count());
    try std.testing.expect(overlay.storage_slots.contains(.{ .address = evmz.addr(1), .key = 1 }));
}

test "bounded fused storage write respects accepted overlay capacity" {
    var overlay = Overlay.init(std.testing.allocator);
    defer overlay.deinit();
    try overlay.configureJournalEntries(8);
    try overlay.configureAccessResources(.{ .accounts = 0, .storage_keys = 1 });
    try overlay.configureStateResources(.{
        .accounts = 1,
        .original_storage_entries = 1,
        .storage_overlay_entries = 0,
    });

    overlay.beginTransaction();
    try std.testing.expectError(
        error.StorageOverlayCapacityExceeded,
        overlay.storeStorage(evmz.addr(1), 1, 1),
    );
    try std.testing.expectEqual(@as(usize, 0), overlay.pending_storage_overlay_entries);
    try std.testing.expectEqual(@as(usize, 0), overlay.storage_overlay.count());
    try std.testing.expectEqual(@as(u256, 0), try overlay.getStorage(evmz.addr(1), 1));
}

test "failed shared slot reservation does not publish bounded policy" {
    var access_allocator = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var access_overlay = Overlay.init(access_allocator.allocator());
    defer access_overlay.deinit();
    try access_overlay.warm_accounts.ensureTotalCapacity(1);

    access_allocator.fail_index = access_allocator.alloc_index;
    try std.testing.expectError(
        error.OutOfMemory,
        access_overlay.configureAccessResources(.{ .accounts = 0, .storage_keys = 1 }),
    );
    try std.testing.expect(access_overlay.access_resources == null);

    var state_allocator = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var state_overlay = Overlay.init(state_allocator.allocator());
    defer state_overlay.deinit();
    try state_overlay.configureStateResources(.{});

    state_allocator.fail_index = state_allocator.alloc_index;
    try std.testing.expectError(
        error.OutOfMemory,
        state_overlay.configureStateResources(.{ .original_storage_entries = 2 }),
    );
    try std.testing.expectEqual(@as(usize, 0), state_overlay.state_resources.?.original_storage_entries);
}

test "shared slot map remains growable when only one storage policy is bounded" {
    var access_bounded = Overlay.init(std.testing.allocator);
    defer access_bounded.deinit();
    try access_bounded.configureAccessResources(.{ .accounts = 0, .storage_keys = 1 });
    access_bounded.beginTransaction();

    _ = try access_bounded.originalStorage(evmz.addr(1), 1);
    _ = try access_bounded.originalStorage(evmz.addr(1), 2);
    const access_bounded_capacity = access_bounded.storage_slots.capacity();
    try access_bounded.warmStorage(evmz.addr(1), 3);
    try std.testing.expect(access_bounded.storage_slots.capacity() > access_bounded_capacity);
    try std.testing.expectEqual(@as(usize, 1), access_bounded.warmStorageCount());
    try std.testing.expectEqual(@as(usize, 2), access_bounded.originalStorageCount());

    var state_bounded = Overlay.init(std.testing.allocator);
    defer state_bounded.deinit();
    try state_bounded.configureStateResources(.{ .original_storage_entries = 1 });
    state_bounded.beginTransaction();

    try state_bounded.warmStorage(evmz.addr(2), 1);
    try state_bounded.warmStorage(evmz.addr(2), 2);
    const state_bounded_capacity = state_bounded.storage_slots.capacity();
    _ = try state_bounded.originalStorage(evmz.addr(2), 3);
    try std.testing.expect(state_bounded.storage_slots.capacity() > state_bounded_capacity);
    try std.testing.expectEqual(@as(usize, 2), state_bounded.warmStorageCount());
    try std.testing.expectEqual(@as(usize, 1), state_bounded.originalStorageCount());
}

test "warm access reserve hint does not enable capacity errors" {
    var overlay = Overlay.init(std.testing.allocator);
    defer overlay.deinit();

    try overlay.reserveAccessHint(.{ .accounts = 1, .storage_keys = 1 });
    try std.testing.expectEqual(@as(u32, 1), overlay.warm_accounts.capacity());
    try std.testing.expectEqual(@as(u32, 1), overlay.storage_slots.capacity());

    overlay.beginTransaction();
    try overlay.warmAccount(evmz.addr(1));
    try overlay.warmAccount(evmz.addr(2));
    try overlay.warmStorage(evmz.addr(1), 1);
    try overlay.warmStorage(evmz.addr(1), 2);

    try std.testing.expectEqual(@as(u32, 2), overlay.warm_accounts.count());
    try std.testing.expectEqual(@as(usize, 2), overlay.warmStorageCount());
}

test "warm access reserve hint includes existing warm entries" {
    var overlay = Overlay.init(std.testing.allocator);
    defer overlay.deinit();

    try overlay.reserveAccessHint(.{ .accounts = 8, .storage_keys = 8 });
    overlay.beginTransaction();
    for (0..8) |index| {
        try overlay.warmAccount(evmz.addr(@as(u160, @intCast(index + 1))));
        try overlay.warmStorage(evmz.addr(1), @intCast(index + 1));
    }

    const account_capacity = overlay.warm_accounts.capacity();
    const storage_capacity = overlay.storage_slots.capacity();
    try std.testing.expectEqual(@as(u32, 8), account_capacity);
    try std.testing.expectEqual(@as(u32, 8), storage_capacity);

    try overlay.reserveAccessHint(.{ .accounts = 1, .storage_keys = 1 });
    try std.testing.expect(overlay.warm_accounts.capacity() >= 9);
    try std.testing.expect(overlay.storage_slots.capacity() >= 9);

    const reserved_account_capacity = overlay.warm_accounts.capacity();
    const reserved_storage_capacity = overlay.storage_slots.capacity();
    try overlay.warmAccount(evmz.addr(9));
    try overlay.warmStorage(evmz.addr(1), 9);
    try std.testing.expectEqual(@as(u32, 9), overlay.warm_accounts.count());
    try std.testing.expectEqual(@as(usize, 9), overlay.warmStorageCount());
    try std.testing.expectEqual(reserved_account_capacity, overlay.warm_accounts.capacity());
    try std.testing.expectEqual(reserved_storage_capacity, overlay.storage_slots.capacity());
}

test "warm access reserve hint does not relax bounded policy" {
    var overlay = Overlay.init(std.testing.allocator);
    defer overlay.deinit();
    try overlay.configureJournalEntries(4);
    try overlay.configureAccessResources(.{ .accounts = 1, .storage_keys = 1 });

    try overlay.reserveAccessHint(.{ .accounts = 8, .storage_keys = 8 });

    overlay.beginTransaction();
    try overlay.warmAccount(evmz.addr(1));
    try std.testing.expectError(error.WarmAccountCapacityExceeded, overlay.warmAccount(evmz.addr(2)));

    try overlay.warmStorage(evmz.addr(1), 1);
    try std.testing.expectError(error.WarmStorageCapacityExceeded, overlay.warmStorage(evmz.addr(1), 2));
}

test "bounded transient storage reports unique-entry capacity exhaustion" {
    var overlay = Overlay.init(std.testing.allocator);
    defer overlay.deinit();
    try overlay.configureJournalEntries(8);
    try overlay.configureTransientStorageEntries(1);

    overlay.beginTransaction();
    try overlay.setTransientStorage(evmz.addr(1), 1, 11);
    try overlay.setTransientStorage(evmz.addr(1), 1, 12);
    try std.testing.expectEqual(@as(usize, 1), overlay.transient_storage.count());
    try std.testing.expectEqual(@as(u256, 12), try overlay.getTransientStorage(evmz.addr(1), 1));
    const journal_len = overlay.journal.len();
    try std.testing.expectError(
        error.TransientStorageCapacityExceeded,
        overlay.setTransientStorage(evmz.addr(1), 2, 22),
    );
    try std.testing.expectEqual(journal_len, overlay.journal.len());
    try std.testing.expectEqual(@as(usize, 1), overlay.transient_storage.count());
    try std.testing.expectEqual(@as(u256, 12), try overlay.getTransientStorage(evmz.addr(1), 1));
    try std.testing.expectEqual(@as(u256, 0), try overlay.getTransientStorage(evmz.addr(1), 2));

    overlay.closeTransaction();
    try overlay.setTransientStorage(evmz.addr(2), 1, 33);
    try std.testing.expectEqual(@as(usize, 1), overlay.transient_storage.count());
}

test "bounded state resources report account capacity exhaustion" {
    var overlay = Overlay.init(std.testing.allocator);
    defer overlay.deinit();
    try overlay.configureJournalEntries(4);
    try overlay.configureStateResources(.{ .accounts = 1 });

    _ = try overlay.getOrCreateAccount(evmz.addr(1));
    try std.testing.expectError(error.AccountCapacityExceeded, overlay.getOrCreateAccount(evmz.addr(2)));
    try std.testing.expectEqual(@as(usize, 1), overlay.accounts.count());
}

test "bounded code cache deduplicates hashes and reports capacity exhaustion" {
    var overlay = Overlay.init(std.testing.allocator);
    defer overlay.deinit();
    try overlay.configureStateResources(.{
        .accounts = 3,
        .code_entries = 1,
        .code_bytes = 1,
    });

    var first = MemoryAccount.init(std.testing.allocator);
    try first.setCode(&.{0xaa});
    try overlay.seedAccount(evmz.addr(1), first);

    var shared = MemoryAccount.init(std.testing.allocator);
    try shared.setCode(&.{0xaa});
    try overlay.seedAccount(evmz.addr(2), shared);

    try std.testing.expectEqual(@as(usize, 1), overlay.code_cache.count());
    try std.testing.expectEqual(@as(usize, 1), overlay.code_bytes_used);

    var overflow = MemoryAccount.init(std.testing.allocator);
    try overflow.setCode(&.{0xbb});
    try std.testing.expectError(
        error.CodeCacheEntryCapacityExceeded,
        overlay.seedAccount(evmz.addr(3), overflow),
    );
    try std.testing.expectEqual(@as(usize, 1), overlay.code_cache.count());
    try std.testing.expectEqual(@as(usize, 1), overlay.code_bytes_used);
}

test "bounded code cache reports byte capacity exhaustion atomically" {
    var overlay = Overlay.init(std.testing.allocator);
    defer overlay.deinit();
    try overlay.configureStateResources(.{
        .accounts = 1,
        .code_entries = 1,
        .code_bytes = 1,
    });

    var account = MemoryAccount.init(std.testing.allocator);
    try account.setCode(&.{ 0xaa, 0xbb });
    try std.testing.expectError(
        error.CodeCacheByteCapacityExceeded,
        overlay.seedAccount(evmz.addr(1), account),
    );
    try std.testing.expectEqual(@as(usize, 0), overlay.code_cache.count());
    try std.testing.expectEqual(@as(usize, 0), overlay.code_bytes_used);
    try std.testing.expectEqual(@as(usize, 0), overlay.accounts.count());
}

test "overlay seed rejects empty code with non-empty explicit hash" {
    var overlay = Overlay.init(std.testing.allocator);
    defer overlay.deinit();

    var account = MemoryAccount.init(std.testing.allocator);
    account.code_hash = [_]u8{0xaa} ** 32;

    try std.testing.expectError(
        error.CodeHashMismatch,
        overlay.seedAccount(evmz.addr(1), account),
    );
    try std.testing.expectEqual(@as(usize, 0), overlay.accounts.count());
    try std.testing.expectEqual(@as(usize, 0), overlay.code_cache.count());
    try std.testing.expectEqual(@as(usize, 0), overlay.seeded_storage.count());
}

test "bounded code cache requires entry and byte limits together" {
    var overlay = Overlay.init(std.testing.allocator);
    defer overlay.deinit();
    try std.testing.expectError(
        error.InvalidCodeResources,
        overlay.configureStateResources(.{ .code_entries = 1 }),
    );
    try std.testing.expectError(
        error.InvalidCodeResources,
        overlay.configureStateResources(.{ .code_bytes = 1 }),
    );
}

test "account reseeding replaces separately stored code and storage" {
    var overlay = Overlay.init(std.testing.allocator);
    defer overlay.deinit();
    const address = evmz.addr(0x5eed);

    var first = MemoryAccount.init(std.testing.allocator);
    try first.setCode(&.{0xaa});
    try first.storage.put(1, 11);
    try first.storage.put(2, 22);
    try overlay.seedAccount(address, first);

    var replacement = MemoryAccount.init(std.testing.allocator);
    try replacement.setCode(&.{0xbb});
    try replacement.storage.put(2, 222);
    try overlay.seedAccount(address, replacement);

    try std.testing.expectEqualSlices(u8, &.{0xbb}, try overlay.getCode(address));
    try std.testing.expectEqual(@as(u256, 0), try overlay.getStorage(address, 1));
    try std.testing.expectEqual(@as(u256, 222), try overlay.getStorage(address, 2));
}

test "bounded state resources report storage map capacity exhaustion" {
    var overlay = Overlay.init(std.testing.allocator);
    defer overlay.deinit();
    try overlay.configureJournalEntries(8);
    try overlay.configureStateResources(.{
        .accounts = 1,
        .original_storage_entries = 2,
        .storage_overlay_entries = 1,
    });

    const address = evmz.addr(0xbeef);
    _ = try overlay.getOrCreateAccount(address);
    overlay.beginTransaction();

    try std.testing.expectEqual(Host.StorageStatus.added, try overlay.setStorage(address, 1, 11));
    try std.testing.expectEqual(Host.StorageStatus.assigned, try overlay.setStorage(address, 1, 12));
    try std.testing.expectError(error.StorageOverlayCapacityExceeded, overlay.setStorage(address, 2, 22));
    try std.testing.expectEqual(@as(usize, 0), overlay.storage_overlay.count());
    try std.testing.expectEqual(@as(usize, 1), overlay.pending_storage_overlay_entries);
    try std.testing.expect(!overlay.storage_overlay.contains(.{ .address = address, .key = 2 }));
    try std.testing.expectEqual(@as(usize, 1), overlay.originalStorageCount());
    try std.testing.expect(!overlay.storage_slots.contains(.{ .address = address, .key = 2 }));

    var original_limited = Overlay.init(std.testing.allocator);
    defer original_limited.deinit();
    try original_limited.configureJournalEntries(8);
    try original_limited.configureStateResources(.{
        .accounts = 1,
        .original_storage_entries = 1,
        .storage_overlay_entries = 2,
    });
    _ = try original_limited.getOrCreateAccount(address);
    original_limited.beginTransaction();
    try std.testing.expectEqual(Host.StorageStatus.added, try original_limited.setStorage(address, 1, 11));
    try std.testing.expectEqual(Host.StorageStatus.assigned, try original_limited.setStorage(address, 1, 12));
    try std.testing.expectError(error.OriginalStorageCapacityExceeded, original_limited.setStorage(address, 2, 22));
    try std.testing.expectEqual(@as(usize, 1), original_limited.originalStorageCount());
    try std.testing.expectEqual(@as(usize, 0), original_limited.storage_overlay.count());
    try std.testing.expectEqual(@as(usize, 1), original_limited.pending_storage_overlay_entries);
}

test "bounded state resource failure rolls back newly created balance account" {
    var overlay = Overlay.init(std.testing.allocator);
    defer overlay.deinit();
    try overlay.configureJournalEntries(8);
    try overlay.configureStateResources(.{
        .accounts = 1,
        .dirty_accounts = 0,
    });

    const address = evmz.addr(0xbeef);
    try std.testing.expectError(error.DirtyAccountCapacityExceeded, overlay.setBalance(address, 1));
    try std.testing.expect(overlay.getAccount(address) == null);
    try std.testing.expectEqual(@as(usize, 0), overlay.accounts.count());
    try std.testing.expectEqual(@as(usize, 0), overlay.journal.len());
}

test "bounded state resource failure rolls back newly created storage account" {
    var overlay = Overlay.init(std.testing.allocator);
    defer overlay.deinit();
    try overlay.configureJournalEntries(8);
    try overlay.configureStateResources(.{
        .accounts = 1,
        .original_storage_entries = 1,
        .storage_overlay_entries = 0,
    });

    const address = evmz.addr(0xcafe);
    try std.testing.expectError(error.StorageOverlayCapacityExceeded, overlay.setStorage(address, 1, 11));
    try std.testing.expect(overlay.getAccount(address) == null);
    try std.testing.expectEqual(@as(usize, 0), overlay.accounts.count());
    try std.testing.expectEqual(@as(usize, 0), overlay.originalStorageCount());
    try std.testing.expectEqual(@as(usize, 0), overlay.storage_overlay.count());
    try std.testing.expectEqual(@as(usize, 0), overlay.journal.len());
}

test "bounded state resource failure rolls back code ownership" {
    var overlay = Overlay.init(std.testing.allocator);
    defer overlay.deinit();
    try overlay.configureJournalEntries(8);
    try overlay.configureStateResources(.{
        .accounts = 1,
        .dirty_accounts = 0,
    });

    const address = evmz.addr(0xc0de);
    var account = MemoryAccount.init(std.testing.allocator);
    try account.setCode(&.{0xaa});
    try overlay.seedAccount(address, account);
    overlay.closeTransaction();

    try std.testing.expectError(error.DirtyAccountCapacityExceeded, overlay.setCode(address, &.{0xbb}));
    try std.testing.expectEqualSlices(u8, &.{0xaa}, try overlay.getCode(address));
    try std.testing.expectEqual(@as(usize, 0), overlay.journal.len());
}

test "bounded state resources report marker capacity exhaustion" {
    var overlay = Overlay.init(std.testing.allocator);
    defer overlay.deinit();
    try overlay.configureJournalEntries(16);
    try overlay.configureStateResources(.{
        .accounts = 2,
        .created_contracts = 1,
        .selfdestructed_accounts = 1,
        .dirty_accounts = 1,
    });

    const first = evmz.addr(1);
    const second = evmz.addr(2);
    try overlay.markCreatedContract(first);
    try std.testing.expectError(error.CreatedContractCapacityExceeded, overlay.markCreatedContract(second));
    try overlay.markSelfdestructed(first);
    try std.testing.expectError(error.SelfdestructCapacityExceeded, overlay.markSelfdestructed(second));

    _ = try overlay.getOrCreateAccount(first);
    _ = try overlay.getOrCreateAccount(second);
    try overlay.setBalance(first, 1);
    try std.testing.expectError(error.DirtyAccountCapacityExceeded, overlay.setBalance(second, 1));
    try std.testing.expectEqual(@as(usize, 1), overlay.dirty_accounts.count());
}

test "bounded account touch rolls back materialization when dirty capacity is exhausted" {
    var overlay = Overlay.init(std.testing.allocator);
    defer overlay.deinit();
    try overlay.configureJournalEntries(4);
    try overlay.configureStateResources(.{
        .accounts = 1,
        .dirty_accounts = 0,
    });

    const address = evmz.addr(0xc01d);
    try std.testing.expectError(error.DirtyAccountCapacityExceeded, overlay.touchAccount(address));
    try std.testing.expect(overlay.getAccount(address) == null);
    try std.testing.expectEqual(@as(usize, 0), overlay.journal.len());
}

test "bounded state resources report deleted account capacity exhaustion" {
    var overlay = Overlay.init(std.testing.allocator);
    defer overlay.deinit();
    try overlay.configureJournalEntries(16);
    try overlay.configureStateResources(.{
        .accounts = 1,
        .selfdestructed_accounts = 1,
        .deleted_accounts = 0,
    });

    const address = evmz.addr(0xdead);
    _ = try overlay.getOrCreateAccount(address);
    try overlay.markSelfdestructed(address);
    const Finalizer = struct {
        pub fn selfDestructFinalization(_: @This(), created_in_transaction: bool) evmz.protocol.SelfDestructFinalization {
            return evmz.eth.system.SelfDestruct.selfDestructFinalization(.london, created_in_transaction);
        }
    };
    try std.testing.expectError(error.DeletedAccountCapacityExceeded, overlay.finalizeTransaction(Finalizer{}));
    try std.testing.expectEqual(@as(usize, 0), overlay.deleted_accounts.count());
}

test "journal checkpoint restores existing account fields" {
    var overlay = Overlay.init(std.testing.allocator);
    defer overlay.deinit();

    const address = evmz.addr(0xcafe);
    var account = MemoryAccount.init(std.testing.allocator);
    account.balance = 5;
    account.nonce = 1;
    try account.setCode(&.{0xaa});
    try overlay.seedAccount(address, account);

    overlay.beginTransaction();
    const checkpoint_state = try overlay.checkpoint();

    try overlay.setBalance(address, 9);
    try overlay.setNonce(address, 2);
    try overlay.setCode(address, &.{ 0xbb, 0xcc });

    try overlay.revertToCheckpoint(checkpoint_state);
    const restored = overlay.getAccount(address).?;
    try std.testing.expectEqual(@as(u256, 5), restored.balance);
    try std.testing.expectEqual(@as(u64, 1), restored.nonce);
    try std.testing.expectEqualSlices(u8, &.{0xaa}, try overlay.getCode(address));
}

test "journal checkpoint restores code without allocating" {
    var overlay = Overlay.init(std.testing.allocator);
    defer overlay.deinit();

    const address = evmz.addr(0xc0de);
    var account = MemoryAccount.init(std.testing.allocator);
    try account.setCode(&.{0xaa});
    try overlay.seedAccount(address, account);

    overlay.beginTransaction();
    const checkpoint_state = try overlay.checkpoint();

    try overlay.setCode(address, &.{ 0xbb, 0xcc });

    var failing_allocator = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    overlay.allocator = failing_allocator.allocator();

    try overlay.revertToCheckpoint(checkpoint_state);

    try std.testing.expect(!failing_allocator.has_induced_failure);
    try std.testing.expectEqualSlices(u8, &.{0xaa}, try overlay.getCode(address));
}

test "reverted code change restores hash and keeps immutable cache entry" {
    var overlay = Overlay.init(std.testing.allocator);
    defer overlay.deinit();

    const address = evmz.addr(0xc0de);
    var account = MemoryAccount.init(std.testing.allocator);
    try account.setCode(&.{0xaa});
    try overlay.seedAccount(address, account);

    overlay.beginTransaction();
    const checkpoint_state = try overlay.checkpoint();
    try overlay.setCode(address, &.{0xbb});
    try overlay.revertToCheckpoint(checkpoint_state);

    try std.testing.expectEqualSlices(u8, &.{0xaa}, try overlay.getCode(address));
    try std.testing.expectEqual(@as(usize, 2), overlay.code_cache.count());

    var delta = try overlay.changeset();
    defer delta.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), delta.account_updates.items.len);
    try std.testing.expectEqual(@as(usize, 0), delta.code_inserts.items.len);
}

test "journal checkpoint removes newly created account and markers" {
    var overlay = Overlay.init(std.testing.allocator);
    defer overlay.deinit();

    const address = evmz.addr(0xcafe);
    overlay.beginTransaction();
    const checkpoint_state = try overlay.checkpoint();

    try overlay.addBalance(address, 10);
    try overlay.setNonce(address, 3);
    try overlay.setCode(address, &.{0xaa});
    try overlay.markCreatedContract(address);
    try overlay.markSelfdestructed(address);

    try std.testing.expect(overlay.getAccount(address) != null);
    try std.testing.expect(overlay.created_contracts.contains(address));
    try std.testing.expect(overlay.selfdestructed_accounts.contains(address));

    try overlay.revertToCheckpoint(checkpoint_state);
    try std.testing.expect(overlay.getAccount(address) == null);
    try std.testing.expect(!overlay.created_contracts.contains(address));
    try std.testing.expect(!overlay.selfdestructed_accounts.contains(address));
}

test "balance credit rejects overflow without changing state" {
    var overlay = Overlay.init(std.testing.allocator);
    defer overlay.deinit();

    const address = evmz.addr(0xcafe);
    try overlay.setBalance(address, std.math.maxInt(u256));

    try std.testing.expectError(error.BalanceOverflow, overlay.addBalance(address, 1));
    try std.testing.expectEqual(std.math.maxInt(u256), try overlay.getBalance(address));
}

test "journal checkpoint restores deleted-account marker on revived account" {
    var overlay = Overlay.init(std.testing.allocator);
    defer overlay.deinit();

    const address = evmz.addr(0xd1ed);
    try overlay.deleted_accounts.put(address, {});

    overlay.beginTransaction();
    const checkpoint_state = try overlay.checkpoint();

    _ = try overlay.getOrCreateAccount(address);
    try std.testing.expect(overlay.getAccount(address) != null);
    try std.testing.expect(!overlay.deleted_accounts.contains(address));

    try overlay.revertToCheckpoint(checkpoint_state);
    try std.testing.expect(overlay.getAccount(address) == null);
    try std.testing.expect(overlay.deleted_accounts.contains(address));
}

test "journal checkpoint reverts finalized selfdestruct cleanup" {
    var overlay = Overlay.init(std.testing.allocator);
    defer overlay.deinit();

    const address = evmz.addr(0xdead);
    const other_created = evmz.addr(0xbeef);
    const key = StorageKey{ .address = address, .key = 7 };
    var account = MemoryAccount.init(std.testing.allocator);
    account.balance = 5;
    account.nonce = 1;
    try account.setCode(&.{0xaa});
    try account.storage.put(key.key, 9);
    try overlay.seedAccount(address, account);
    try overlay.storage_overlay.put(key, 10);
    try overlay.markSelfdestructed(address);
    try overlay.markCreatedContract(other_created);

    const checkpoint_state = try overlay.checkpoint();
    try overlay.finalizeTransaction(ethereumFinalizer(.london));

    try std.testing.expect(overlay.getAccount(address) == null);
    try std.testing.expect(!overlay.storage_overlay.contains(key));
    try std.testing.expect(overlay.deleted_accounts.contains(address));
    try std.testing.expect(!overlay.selfdestructed_accounts.contains(address));
    try std.testing.expect(!overlay.created_contracts.contains(other_created));

    try overlay.revertToCheckpoint(checkpoint_state);
    const restored = overlay.getAccount(address).?;
    try std.testing.expectEqual(@as(u256, 5), restored.balance);
    try std.testing.expectEqual(@as(u64, 1), restored.nonce);
    try std.testing.expectEqualSlices(u8, &.{0xaa}, try overlay.getCode(address));
    try std.testing.expectEqual(@as(u256, 9), overlay.seeded_storage.get(key).?);
    try std.testing.expectEqual(@as(u256, 10), overlay.storage_overlay.get(key).?);
    try std.testing.expect(!overlay.deleted_accounts.contains(address));
    try std.testing.expect(overlay.selfdestructed_accounts.contains(address));
    try std.testing.expect(overlay.created_contracts.contains(other_created));
}

test "journal checkpoint restores removed state without allocating" {
    var overlay = Overlay.init(std.testing.allocator);
    defer overlay.deinit();

    const deleted_address = evmz.addr(0xd1ed);
    const destroyed_address = evmz.addr(0xdead);
    const created_address = evmz.addr(0xbeef);
    const key = StorageKey{ .address = destroyed_address, .key = 7 };

    try overlay.deleted_accounts.put(deleted_address, {});
    var account = MemoryAccount.init(std.testing.allocator);
    account.balance = 5;
    try account.storage.put(key.key, 9);
    try overlay.seedAccount(destroyed_address, account);
    try overlay.storage_overlay.put(key, 10);
    try overlay.markSelfdestructed(destroyed_address);
    try overlay.markCreatedContract(created_address);

    const checkpoint_state = try overlay.checkpoint();
    _ = try overlay.getOrCreateAccount(deleted_address);
    try overlay.finalizeTransaction(ethereumFinalizer(.london));

    var failing_allocator = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    overlay.allocator = failing_allocator.allocator();
    try overlay.revertToCheckpoint(checkpoint_state);

    try std.testing.expect(!failing_allocator.has_induced_failure);
    try std.testing.expect(overlay.getAccount(deleted_address) == null);
    try std.testing.expect(overlay.deleted_accounts.contains(deleted_address));
    try std.testing.expect(overlay.getAccount(destroyed_address) != null);
    try std.testing.expectEqual(@as(u256, 10), overlay.storage_overlay.get(key).?);
    try std.testing.expect(overlay.selfdestructed_accounts.contains(destroyed_address));
    try std.testing.expect(overlay.created_contracts.contains(created_address));
}

test "journal rollback removes transaction cache loads before restoring accounts" {
    const destroyed_address = evmz.addr(0xdead);
    const fee_recipient = evmz.addr(0xfee);
    var store = MemoryStore.init(std.testing.allocator);
    defer store.deinit();
    (try store.getOrCreateAccount(destroyed_address)).balance = 5;
    (try store.getOrCreateAccount(fee_recipient)).balance = 7;

    var overlay = Overlay.initWithStateReader(std.testing.allocator, store.reader());
    defer overlay.deinit();
    try overlay.configureJournalEntries(16);
    try overlay.configureStateResources(.{
        .accounts = 1,
        .selfdestructed_accounts = 1,
        .deleted_accounts = 1,
    });

    try std.testing.expect((try overlay.getAccountOrLoad(destroyed_address)) != null);
    overlay.beginTransaction();
    const checkpoint_state = try overlay.checkpoint();
    try overlay.markSelfdestructed(destroyed_address);
    try overlay.finalizeTransaction(ethereumFinalizer(.london));
    try std.testing.expect((try overlay.getAccountOrLoad(fee_recipient)) != null);
    try std.testing.expectEqual(@as(usize, 1), overlay.accounts.count());

    var failing_allocator = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    overlay.allocator = failing_allocator.allocator();
    try overlay.revertToCheckpoint(checkpoint_state);

    try std.testing.expect(!failing_allocator.has_induced_failure);
    try std.testing.expect(overlay.getAccount(destroyed_address) != null);
    try std.testing.expect(overlay.getAccount(fee_recipient) == null);
    try std.testing.expectEqual(@as(usize, 1), overlay.accounts.count());
    try std.testing.expect(!overlay.deleted_accounts.contains(destroyed_address));
    try std.testing.expect(!overlay.selfdestructed_accounts.contains(destroyed_address));
}

test "finalization error rolls back mutations into the enclosing journal" {
    var overlay = Overlay.init(std.testing.allocator);
    defer overlay.deinit();
    try overlay.configureJournalEntries(6);
    try overlay.configureStateResources(.{
        .accounts = 1,
        .created_contracts = 1,
        .selfdestructed_accounts = 1,
        .dirty_accounts = 1,
    });

    const address = evmz.addr(0xdead);
    var account = MemoryAccount.init(std.testing.allocator);
    account.nonce = 9;
    try account.setCode(&.{0xaa});
    try overlay.seedAccount(address, account);

    overlay.beginTransaction();
    try overlay.markSelfdestructed(address);
    try overlay.markCreatedContract(address);
    const journal_len = overlay.journal.len();

    try std.testing.expectError(
        error.JournalCapacityExceeded,
        overlay.finalizeTransaction(ethereumFinalizer(.amsterdam)),
    );

    try std.testing.expectEqual(journal_len, overlay.journal.len());
    try std.testing.expectEqual(@as(u64, 9), overlay.getAccount(address).?.nonce);
    try std.testing.expectEqualSlices(u8, &.{0xaa}, try overlay.getCode(address));
    try std.testing.expect(overlay.selfdestructed_accounts.contains(address));
    try std.testing.expect(overlay.created_contracts.contains(address));
}

test "journal checkpoint reverts Cancun skipped selfdestruct marker clearing" {
    var overlay = Overlay.init(std.testing.allocator);
    defer overlay.deinit();

    const address = evmz.addr(0xcaca);
    _ = try overlay.getOrCreateAccount(address);
    try overlay.markSelfdestructed(address);

    const checkpoint_state = try overlay.checkpoint();
    try overlay.finalizeTransaction(ethereumFinalizer(.cancun));

    try std.testing.expect(overlay.getAccount(address) != null);
    try std.testing.expect(!overlay.deleted_accounts.contains(address));
    try std.testing.expect(!overlay.selfdestructed_accounts.contains(address));

    try overlay.revertToCheckpoint(checkpoint_state);
    try std.testing.expect(overlay.getAccount(address) != null);
    try std.testing.expect(!overlay.deleted_accounts.contains(address));
    try std.testing.expect(overlay.selfdestructed_accounts.contains(address));
}

test "selfdestruct finalization policy comes from comptime protocol" {
    const CustomFinalizer = struct {
        pub fn selfDestructFinalization(
            self: @This(),
            created_in_transaction: bool,
        ) evmz.protocol.SelfDestructFinalization {
            _ = self;
            _ = created_in_transaction;
            return .{
                .clear_storage = true,
                .reset_account = true,
            };
        }
    };

    var overlay = Overlay.init(std.testing.allocator);
    defer overlay.deinit();

    const address = evmz.addr(0xf17a);
    const key = StorageKey{ .address = address, .key = 7 };
    var account = MemoryAccount.init(std.testing.allocator);
    account.nonce = 3;
    try account.setCode(&.{0xaa});
    try overlay.seedAccount(address, account);
    try overlay.storage_overlay.put(key, 10);
    try overlay.markSelfdestructed(address);

    try overlay.finalizeTransaction(CustomFinalizer{});

    const finalized = overlay.getAccount(address).?;
    try std.testing.expectEqual(@as(u64, 0), finalized.nonce);
    try std.testing.expectEqualSlices(u8, &.{}, try overlay.getCode(address));
    try std.testing.expect(!overlay.storage_overlay.contains(key));
    try std.testing.expect(!overlay.deleted_accounts.contains(address));
    try std.testing.expect(!overlay.selfdestructed_accounts.contains(address));
}

test "storage clear discards transaction-local dirty slots and rolls back" {
    var overlay = Overlay.init(std.testing.allocator);
    defer overlay.deinit();

    const address = evmz.addr(0xa57e);
    const key = StorageKey{ .address = address, .key = 7 };
    _ = try overlay.getOrCreateAccount(address);
    overlay.beginTransaction();
    try overlay.markCreatedContract(address);
    try std.testing.expectEqual(Host.StorageStatus.added, try overlay.setStorage(address, key.key, 9));
    try overlay.markSelfdestructed(address);

    const checkpoint_state = try overlay.checkpoint();
    try overlay.finalizeTransaction(ethereumFinalizer(.amsterdam));

    try std.testing.expectEqual(@as(u256, 0), try overlay.getStorage(address, key.key));
    try std.testing.expect(!overlay.storage_slots.get(key).?.dirty);
    try std.testing.expectEqual(@as(usize, 0), overlay.pending_storage_overlay_entries);

    try overlay.revertToCheckpoint(checkpoint_state);
    try std.testing.expectEqual(@as(u256, 9), try overlay.getStorage(address, key.key));
    try std.testing.expect(overlay.storage_slots.get(key).?.dirty);
    try std.testing.expectEqual(@as(usize, 1), overlay.pending_storage_overlay_entries);

    try overlay.finalizeTransaction(ethereumFinalizer(.amsterdam));
    overlay.closeTransaction();
    try std.testing.expect(!overlay.storage_overlay.contains(key));
    try std.testing.expectEqual(@as(u256, 0), try overlay.getStorage(address, key.key));
}

test "partial storage clear failure restores all transaction-local slots" {
    const ClearStorageFinalizer = struct {
        pub fn selfDestructFinalization(_: @This(), _: bool) evmz.protocol.SelfDestructFinalization {
            return .{ .clear_storage = true };
        }
    };

    var overlay = Overlay.init(std.testing.allocator);
    defer overlay.deinit();

    const address = evmz.addr(0xc1ea);
    const first = StorageKey{ .address = address, .key = 1 };
    const second = StorageKey{ .address = address, .key = 2 };
    overlay.beginTransaction();
    try std.testing.expectEqual(Host.StorageStatus.added, try overlay.setStorage(address, first.key, 9));
    try std.testing.expectEqual(Host.StorageStatus.added, try overlay.setStorage(address, second.key, 10));
    try overlay.markSelfdestructed(address);

    const setup_journal_len = overlay.journal.len();
    const journal_limit = setup_journal_len + 2;
    try overlay.journal.items.ensureTotalCapacityPrecise(std.testing.allocator, journal_limit);
    overlay.journal.capacity_limit = journal_limit;

    try std.testing.expectError(
        error.JournalCapacityExceeded,
        overlay.finalizeTransaction(ClearStorageFinalizer{}),
    );

    try std.testing.expectEqual(setup_journal_len, overlay.journal.len());
    try std.testing.expectEqual(@as(u256, 9), try overlay.getStorage(address, first.key));
    try std.testing.expectEqual(@as(u256, 10), try overlay.getStorage(address, second.key));
    try std.testing.expect(overlay.storage_slots.get(first).?.dirty);
    try std.testing.expect(overlay.storage_slots.get(second).?.dirty);
    try std.testing.expectEqual(@as(usize, 2), overlay.pending_storage_overlay_entries);
    try std.testing.expect(overlay.selfdestructed_accounts.contains(address));
}

test "changeset emits sorted account updates and storage writes" {
    var overlay = Overlay.init(std.testing.allocator);
    defer overlay.deinit();

    const high_address = evmz.addr(0x20);
    const low_address = evmz.addr(0x10);

    try overlay.setBalance(high_address, 20);
    try overlay.setBalance(low_address, 10);
    try overlay.setNonce(low_address, 1);
    try overlay.setCode(low_address, &.{0xaa});
    try std.testing.expectEqual(Host.StorageStatus.added, try overlay.setStorage(high_address, 2, 22));
    try std.testing.expectEqual(Host.StorageStatus.added, try overlay.setStorage(low_address, 1, 11));

    var delta = try overlay.changeset();
    defer delta.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), delta.account_updates.items.len);
    try std.testing.expectEqualSlices(u8, &low_address, &delta.account_updates.items[0].address);
    try std.testing.expectEqualSlices(u8, &high_address, &delta.account_updates.items[1].address);
    try std.testing.expectEqual(@as(u64, 1), delta.account_updates.items[0].nonce);
    try std.testing.expectEqual(@as(u256, 10), delta.account_updates.items[0].balance);
    try std.testing.expectEqual(@as(usize, 1), delta.code_inserts.items.len);
    try std.testing.expectEqualSlices(u8, &.{0xaa}, delta.code_inserts.items[0].code);

    try std.testing.expectEqual(@as(usize, 2), delta.storage_writes.items.len);
    try std.testing.expectEqualSlices(u8, &low_address, &delta.storage_writes.items[0].address);
    try std.testing.expectEqual(@as(u256, 1), delta.storage_writes.items[0].key);
    try std.testing.expectEqual(@as(u256, 11), delta.storage_writes.items[0].value);
    try std.testing.expectEqualSlices(u8, &high_address, &delta.storage_writes.items[1].address);
}

test "changeset skips read-only loaded accounts" {
    const address = evmz.addr(0xabc);
    var memory = MemoryStore.init(std.testing.allocator);
    defer memory.deinit();

    var account = try memory.getOrCreateAccount(address);
    account.balance = 5;
    account.nonce = 1;
    try account.setCode(&.{0x5f});

    var overlay = Overlay.initWithStateReader(std.testing.allocator, memory.reader());
    defer overlay.deinit();

    try std.testing.expectEqual(@as(u256, 5), try overlay.getBalance(address));
    try std.testing.expectEqualSlices(u8, &.{0x5f}, try overlay.getCode(address));

    var delta = try overlay.changeset();
    defer delta.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 0), delta.account_updates.items.len);
    try std.testing.expectEqual(@as(usize, 0), delta.account_deletes.items.len);
    try std.testing.expectEqual(@as(usize, 0), delta.storage_writes.items.len);
}

test "balance-only changeset preserves non-materialized code hash" {
    const address = evmz.addr(0xabc);
    const code = [_]u8{0x5f};
    var memory = MemoryStore.init(std.testing.allocator);
    defer memory.deinit();

    var account = try memory.getOrCreateAccount(address);
    account.balance = 5;
    try account.setCode(&code);

    var overlay = Overlay.initWithStateReader(std.testing.allocator, memory.reader());
    defer overlay.deinit();

    try overlay.setBalance(address, 7);

    var delta = try overlay.changeset();
    defer delta.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), delta.account_updates.items.len);
    const update = delta.account_updates.items[0];
    try std.testing.expectEqualSlices(u8, &address, &update.address);
    try std.testing.expectEqual(@as(u64, 0), update.nonce);
    try std.testing.expectEqual(@as(u256, 7), update.balance);
    try std.testing.expectEqual(@as(usize, 0), delta.code_inserts.items.len);
    try std.testing.expectEqualSlices(u8, &evmz.crypto.keccak256(&code), &update.code_hash);
}

test "code hash accessors preserve non-materialized account code" {
    const address = evmz.addr(0xabc);
    const code = [_]u8{0x5f};
    const code_hash = evmz.crypto.keccak256(&code);
    var memory = MemoryStore.init(std.testing.allocator);
    defer memory.deinit();

    var account = try memory.getOrCreateAccount(address);
    try account.setCode(&code);

    var overlay = Overlay.initWithStateReader(std.testing.allocator, memory.reader());
    defer overlay.deinit();

    try std.testing.expectEqual(std.mem.readInt(u256, &code_hash, .big), try overlay.getCodeHash(address));
    try std.testing.expect(try overlay.accountHasCode(address));

    const loaded_summary = overlay.getAccount(address).?;
    try std.testing.expectEqualSlices(u8, &code_hash, &loaded_summary.code_hash);
}

test "checkpoint reverts dirty account marker introduced after checkpoint" {
    const address = evmz.addr(0xabc);
    var memory = MemoryStore.init(std.testing.allocator);
    defer memory.deinit();

    var account = try memory.getOrCreateAccount(address);
    account.balance = 5;

    var overlay = Overlay.initWithStateReader(std.testing.allocator, memory.reader());
    defer overlay.deinit();

    overlay.beginTransaction();
    try std.testing.expectEqual(@as(u256, 5), try overlay.getBalance(address));
    const checkpoint_state = try overlay.checkpoint();

    try overlay.setBalance(address, 7);
    try std.testing.expect(overlay.dirty_accounts.contains(address));

    try overlay.revertToCheckpoint(checkpoint_state);

    try std.testing.expectEqual(@as(u256, 5), try overlay.getBalance(address));
    try std.testing.expect(!overlay.dirty_accounts.contains(address));

    var delta = try overlay.changeset();
    defer delta.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), delta.account_updates.items.len);
}

test "checkpoint preserves dirty account marker that predates checkpoint" {
    const address = evmz.addr(0xabc);
    var overlay = Overlay.init(std.testing.allocator);
    defer overlay.deinit();

    overlay.beginTransaction();
    try overlay.setBalance(address, 5);
    try std.testing.expect(overlay.dirty_accounts.contains(address));
    const checkpoint_state = try overlay.checkpoint();

    try overlay.setNonce(address, 7);
    try overlay.revertToCheckpoint(checkpoint_state);

    try std.testing.expect(overlay.dirty_accounts.contains(address));

    var delta = try overlay.changeset();
    defer delta.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), delta.account_updates.items.len);
    try std.testing.expectEqualSlices(u8, &address, &delta.account_updates.items[0].address);
    try std.testing.expectEqual(@as(u256, 5), delta.account_updates.items[0].balance);
    try std.testing.expectEqual(@as(u64, 0), delta.account_updates.items[0].nonce);
}

test "changeset emits finalized account deletes without deleted storage writes" {
    var overlay = Overlay.init(std.testing.allocator);
    defer overlay.deinit();

    const address = evmz.addr(0xd1e);
    const key = StorageKey{ .address = address, .key = 7 };
    var account = try overlay.getOrCreateAccount(address);
    account.balance = 1;
    try overlay.storage_overlay.put(key, 9);
    try overlay.markSelfdestructed(address);

    try overlay.finalizeTransaction(ethereumFinalizer(.london));

    var delta = try overlay.changeset();
    defer delta.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 0), delta.account_updates.items.len);
    try std.testing.expectEqual(@as(usize, 1), delta.account_deletes.items.len);
    try std.testing.expectEqualSlices(u8, &address, &delta.account_deletes.items[0]);
    try std.testing.expectEqual(@as(usize, 0), delta.storage_writes.items.len);
}

const TestStateReader = struct {
    address: Address,
    key: u256,
    value: u256,
    balance: u256,
    load_count: usize = 0,
    storage_reads: usize = 0,
    overlay: ?*Overlay = null,
    require_warm_storage: bool = false,

    fn reader(self: *TestStateReader) StateReader {
        return .{ .ptr = self, .vtable = &.{
            .accountExists = readerAccountExists,
            .loadAccount = readerLoadAccount,
            .loadCode = readerLoadCode,
            .getStorage = readerGetStorage,
            .accountHasStorage = readerAccountHasStorage,
        } };
    }

    fn readerAccountExists(ptr: *anyopaque, address: Address) !bool {
        const self: *TestStateReader = @ptrCast(@alignCast(ptr));
        return std.mem.eql(u8, &self.address, &address);
    }

    fn readerLoadAccount(ptr: *anyopaque, address: Address) !?AccountState {
        const self: *TestStateReader = @ptrCast(@alignCast(ptr));
        if (!std.mem.eql(u8, &self.address, &address)) return null;
        self.load_count += 1;
        return .{
            .balance = self.balance,
            .code_hash = evmz.crypto.keccak256(&.{0x5f}),
        };
    }

    fn readerLoadCode(ptr: *anyopaque, hash: [32]u8) ![]const u8 {
        _ = ptr;
        if (!std.mem.eql(u8, &hash, &evmz.crypto.keccak256(&.{0x5f}))) return error.MissingCode;
        return &.{0x5f};
    }

    fn readerGetStorage(ptr: *anyopaque, address: Address, key: u256) !u256 {
        const self: *TestStateReader = @ptrCast(@alignCast(ptr));
        self.storage_reads += 1;
        if (self.require_warm_storage) {
            const overlay = self.overlay orelse return error.MissingOverlay;
            if (!overlay.isStorageWarm(address, key)) {
                return error.StorageReadBeforeWarmAccess;
            }
        }
        if (std.mem.eql(u8, &self.address, &address) and key == self.key) return self.value;
        return 0;
    }

    fn readerAccountHasStorage(ptr: *anyopaque, address: Address) !bool {
        const self: *TestStateReader = @ptrCast(@alignCast(ptr));
        return std.mem.eql(u8, &self.address, &address) and self.value != 0;
    }
};

test "fused storage lookup warms before reading backing state" {
    const address = evmz.addr(0xbeef);
    var reader = TestStateReader{
        .address = address,
        .key = 7,
        .value = 0xab,
        .balance = 0,
        .require_warm_storage = true,
    };
    var overlay = Overlay.initWithStateReader(std.testing.allocator, reader.reader());
    defer overlay.deinit();
    reader.overlay = &overlay;

    overlay.beginTransaction();
    const result = try overlay.loadStorage(address, 7);
    try std.testing.expectEqual(Host.AccessStatus.cold, result.access_status);
    try std.testing.expectEqual(@as(u256, 0xab), result.value);
    try std.testing.expectEqual(@as(usize, 1), reader.storage_reads);
}

test "access-list storage warming defers the backing read" {
    const address = evmz.addr(0xbeef);
    var reader = TestStateReader{
        .address = address,
        .key = 7,
        .value = 0xab,
        .balance = 0,
        .require_warm_storage = true,
    };
    var overlay = Overlay.initWithStateReader(std.testing.allocator, reader.reader());
    defer overlay.deinit();
    reader.overlay = &overlay;

    overlay.beginTransaction();
    try overlay.warmStorage(address, 7);
    try std.testing.expectEqual(@as(usize, 0), reader.storage_reads);

    const result = try overlay.loadStorage(address, 7);
    try std.testing.expectEqual(Host.AccessStatus.warm, result.access_status);
    try std.testing.expectEqual(@as(u256, 0xab), result.value);
    try std.testing.expectEqual(@as(usize, 1), reader.storage_reads);
}

test "state reader loads account and storage lazily" {
    const address = evmz.addr(0xbeef);
    var reader = TestStateReader{
        .address = address,
        .key = 7,
        .value = 0xab,
        .balance = 0x1234,
    };
    var overlay = Overlay.initWithStateReader(std.testing.allocator, reader.reader());
    defer overlay.deinit();

    try std.testing.expect(try overlay.accountExists(address));
    try std.testing.expectEqual(@as(u256, 0x1234), try overlay.getBalance(address));
    try std.testing.expectEqualSlices(u8, &.{0x5f}, try overlay.getCode(address));
    try std.testing.expectEqual(@as(u256, 0xab), try overlay.getStorage(address, 7));
    try std.testing.expectEqual(@as(usize, 1), reader.load_count);
    try std.testing.expectEqual(@as(usize, 1), reader.storage_reads);
}

test "zero storage write masks state reader value" {
    const address = evmz.addr(0xbeef);
    var reader = TestStateReader{
        .address = address,
        .key = 7,
        .value = 0xab,
        .balance = 0,
    };
    var overlay = Overlay.initWithStateReader(std.testing.allocator, reader.reader());
    defer overlay.deinit();

    overlay.beginTransaction();
    try std.testing.expectEqual(Host.StorageStatus.deleted, try overlay.setStorage(address, 7, 0));
    try std.testing.expectEqual(@as(u256, 0), try overlay.getStorage(address, 7));
    try std.testing.expectEqual(@as(usize, 1), reader.storage_reads);
}

test "trace sink receives state and checkpoint events" {
    const address = evmz.addr(0xabc);
    var overlay = Overlay.init(std.testing.allocator);
    defer overlay.deinit();

    var recorder = StateEventRecorder{};
    var sink = recorder.sink();
    var context = CaptureContext.init(std.testing.allocator, null, capture_context.stateTargetForSink(&sink));
    defer context.deinit();
    overlay.capture_context = &context;
    try context.begin();
    defer {
        if (context.isActive()) context.abort() catch {};
        overlay.capture_context = null;
    }
    overlay.trace_depth = 4;

    overlay.beginTransaction();
    const checkpoint_state = try overlay.checkpoint();
    try std.testing.expectEqual(@as(u256, 0), try overlay.getBalance(address));
    try std.testing.expectEqual(Host.StorageStatus.added, try overlay.setStorage(address, 1, 2));
    try overlay.commitCheckpoint(checkpoint_state);

    try std.testing.expectEqual(@as(u8, 2), recorder.checkpoints);
    try std.testing.expectEqual(trace.CheckpointKind.checkpoint, recorder.first_checkpoint_tag);
    try std.testing.expectEqual(trace.CheckpointKind.commit, recorder.last_checkpoint_tag);
    try std.testing.expectEqual(@as(u16, 4), recorder.last_checkpoint_depth);
    try std.testing.expect(recorder.reads >= 2);
    try std.testing.expect(recorder.writes >= 1);
    try std.testing.expectEqual(trace.StateReadKind.balance, recorder.first_read_tag);
    try std.testing.expectEqual(trace.StateWriteKind.storage, recorder.last_write_tag);
    try std.testing.expectEqual(@as(u16, 4), recorder.last_write_depth);
    try std.testing.expectEqual(@as(u256, 2), recorder.last_write_value);
    _ = try context.finish();
}

test "fallible capture target rolls back the failed state mutation" {
    const FailingTarget = struct {
        fn target(self: *@This()) capture_context.StateTarget {
            return capture_context.StateTarget.init(self, &.{ .state_write = stateWrite });
        }

        fn stateWrite(_: *anyopaque, _: trace.StateWrite) !void {
            return error.TestCaptureFailure;
        }
    };

    const address = evmz.addr(0xabc);
    var overlay = Overlay.init(std.testing.allocator);
    defer overlay.deinit();
    try overlay.setBalance(address, 5);
    const journal_len = overlay.journal.len();

    var failing = FailingTarget{};
    var context = CaptureContext.init(std.testing.allocator, null, failing.target());
    defer context.deinit();
    overlay.capture_context = &context;
    try context.begin();
    defer {
        if (context.isActive()) context.abort() catch {};
        overlay.capture_context = null;
    }

    try std.testing.expectError(error.TestCaptureFailure, overlay.setBalance(address, 9));
    try std.testing.expectEqual(@as(u256, 5), try overlay.getBalance(address));
    try std.testing.expectEqual(journal_len, overlay.journal.len());

    const code = [_]u8{ 0x60, 0x00 };
    try std.testing.expectError(error.TestCaptureFailure, overlay.setCode(address, &code));
    try std.testing.expectEqualSlices(u8, &.{}, try overlay.getCode(address));
    try std.testing.expectEqual(@as(u32, 0), overlay.code_cache.count());
    try std.testing.expectEqual(@as(usize, 0), overlay.code_bytes_used);
    _ = try context.finish();
}

const StateEventRecorder = struct {
    reads: u8 = 0,
    writes: u8 = 0,
    checkpoints: u8 = 0,
    first_read_tag: trace.StateReadKind = .balance,
    last_write_tag: trace.StateWriteKind = .balance,
    last_write_depth: u16 = 0,
    last_write_value: u256 = 0,
    first_checkpoint_tag: trace.CheckpointKind = .checkpoint,
    last_checkpoint_tag: trace.CheckpointKind = .checkpoint,
    last_checkpoint_depth: u16 = 0,

    fn sink(self: *StateEventRecorder) trace.Sink {
        return trace.Sink.init(self, .{
            .state_read = trace.StateReadKinds.initMany(&.{ .balance, .storage }),
            .state_write = trace.StateWriteKinds.initMany(&.{.storage}),
            .checkpoint = trace.CheckpointFields.full,
        }, &.{
            .stateRead = stateRead,
            .stateWrite = stateWrite,
            .checkpoint = checkpointEvent,
        });
    }

    fn stateRead(ptr: *anyopaque, event: trace.StateRead) void {
        const self: *StateEventRecorder = @ptrCast(@alignCast(ptr));
        if (self.reads == 0) self.first_read_tag = std.meta.activeTag(event);
        self.reads += 1;
    }

    fn stateWrite(ptr: *anyopaque, event: trace.StateWrite) void {
        const self: *StateEventRecorder = @ptrCast(@alignCast(ptr));
        self.last_write_tag = std.meta.activeTag(event);
        self.last_write_depth = event.depth();
        self.last_write_value = switch (event) {
            .balance => |payload| payload.value,
            .nonce => |payload| payload.value,
            .storage => |payload| payload.value,
            .transient_storage => |payload| payload.value,
            else => 0,
        };
        self.writes += 1;
    }

    fn checkpointEvent(ptr: *anyopaque, event: trace.Checkpoint) void {
        const self: *StateEventRecorder = @ptrCast(@alignCast(ptr));
        if (self.checkpoints == 0) self.first_checkpoint_tag = event.kind;
        self.last_checkpoint_tag = event.kind;
        self.last_checkpoint_depth = event.depth;
        self.checkpoints += 1;
    }
};
