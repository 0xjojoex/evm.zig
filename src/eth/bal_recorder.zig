//! Observed BAL recorder fed by state trace events.

const std = @import("std");
const bal = @import("bal.zig");
const trace = @import("../trace.zig");
const address = @import("../address.zig");

const Allocator = std.mem.Allocator;

pub const Recorder = struct {
    allocator: Allocator,
    block_access_index: bal.BlockAccessIndex = 0,
    events: std.ArrayList(Event) = .empty,
    checkpoints: std.ArrayList(CheckpointMarker) = .empty,
    next_sequence: usize = 0,
    failure: ?anyerror = null,

    pub fn init(allocator: Allocator) Recorder {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Recorder) void {
        self.events.deinit(self.allocator);
        self.checkpoints.deinit(self.allocator);
        self.* = init(self.allocator);
    }

    pub fn setBlockAccessIndex(self: *Recorder, block_access_index: bal.BlockAccessIndex) void {
        self.block_access_index = block_access_index;
    }

    pub fn sink(self: *Recorder) trace.Sink {
        return trace.Sink.init(self, .{
            .account_access = trace.AccountAccessFields.full,
            .state_read = trace.StateReadKinds.initMany(&.{.storage}),
            .state_write = trace.StateWriteKinds.initMany(&.{ .balance, .nonce, .storage }),
            .checkpoint = trace.CheckpointFields.full,
        }, &.{
            .accountAccess = accountAccess,
            .stateRead = stateRead,
            .stateWrite = stateWrite,
            .checkpoint = checkpointEvent,
        });
    }

    pub fn recordAccountAccess(self: *Recorder, account_address: bal.Address) !void {
        try self.append(.{ .account_access = account_address });
    }

    pub fn recordStorageRead(self: *Recorder, event: trace.SlotValueRead) !void {
        try self.recordAccountAccess(event.address);
        try self.append(.{ .storage_read = .{
            .address = event.address,
            .slot = event.key,
        } });
    }

    pub fn recordStorageWrite(self: *Recorder, event: trace.SlotValueWrite) !void {
        try self.recordStorageRead(.{
            .depth = event.depth,
            .address = event.address,
            .key = event.key,
            .value = event.previous,
        });
        try self.append(.{ .storage_write = .{
            .block_access_index = self.block_access_index,
            .address = event.address,
            .slot = event.key,
            .previous = event.previous,
            .value = event.value,
            .sequence = self.nextSequence(),
        } });
    }

    pub fn recordBalanceWrite(self: *Recorder, event: trace.AccountValueWrite) !void {
        try self.recordAccountAccess(event.address);
        try self.append(.{ .balance_write = .{
            .block_access_index = self.block_access_index,
            .address = event.address,
            .previous = event.previous,
            .value = event.value,
            .sequence = self.nextSequence(),
        } });
    }

    pub fn recordNonceWrite(self: *Recorder, event: trace.NonceWrite) !void {
        try self.recordAccountAccess(event.address);
        try self.append(.{ .nonce_write = .{
            .block_access_index = self.block_access_index,
            .address = event.address,
            .previous = event.previous,
            .value = event.value,
            .sequence = self.nextSequence(),
        } });
    }

    pub fn toOwnedBlockAccessList(self: *Recorder, allocator: Allocator) !bal.Decoded {
        if (self.failure) |failure| return failure;
        if (self.checkpoints.items.len != 0) return error.UnclosedCheckpoint;

        var builders: std.ArrayList(AccountBuilder) = .empty;
        defer {
            for (builders.items) |*builder| builder.deinit(allocator);
            builders.deinit(allocator);
        }
        var builder_indices = std.AutoHashMap(bal.Address, usize).init(allocator);
        defer builder_indices.deinit();

        for (self.events.items) |event| {
            switch (event) {
                .account_access => |account_address| {
                    _ = try accountBuilderFor(allocator, &builders, &builder_indices, account_address);
                },
                .storage_read => |storage_read| {
                    const builder = try accountBuilderFor(allocator, &builders, &builder_indices, storage_read.address);
                    try builder.storage_reads.append(allocator, storage_read.slot);
                },
                .storage_write => |storage_write| {
                    if (!storage_write.active) continue;
                    const builder = try accountBuilderFor(allocator, &builders, &builder_indices, storage_write.address);
                    try builder.storage_writes.append(allocator, storage_write);
                },
                .balance_write => |balance_write| {
                    if (!balance_write.active) continue;
                    const builder = try accountBuilderFor(allocator, &builders, &builder_indices, balance_write.address);
                    try builder.balance_writes.append(allocator, balance_write);
                },
                .nonce_write => |nonce_write| {
                    if (!nonce_write.active) continue;
                    const builder = try accountBuilderFor(allocator, &builders, &builder_indices, nonce_write.address);
                    try builder.nonce_writes.append(allocator, nonce_write);
                },
            }
        }

        var accounts: std.ArrayList(bal.AccountChanges) = .empty;
        errdefer {
            for (accounts.items) |*account| deinitAccount(allocator, account);
            accounts.deinit(allocator);
        }

        for (builders.items) |*builder| {
            var account = try builder.toOwnedAccount(allocator);
            errdefer deinitAccount(allocator, &account);
            try accounts.append(allocator, account);
        }

        std.mem.sort(bal.AccountChanges, accounts.items, {}, accountLessThan);
        return .{ .accounts = try accounts.toOwnedSlice(allocator) };
    }

    fn append(self: *Recorder, event: Event) !void {
        if (self.failure) |failure| return failure;
        self.events.append(self.allocator, event) catch |err| {
            self.failure = err;
            return err;
        };
    }

    fn nextSequence(self: *Recorder) usize {
        defer self.next_sequence += 1;
        return self.next_sequence;
    }

    fn recordCheckpoint(self: *Recorder, event: trace.Checkpoint) !void {
        switch (event.kind) {
            .checkpoint => try self.checkpoints.append(self.allocator, .{
                .depth = event.depth,
                .journal_len = event.journal_len,
                .logs_len = event.logs_len,
                .event_start = self.events.items.len,
            }),
            .commit => try self.closeCheckpoint(event, false),
            .revert => try self.closeCheckpoint(event, true),
        }
    }

    fn closeCheckpoint(self: *Recorder, event: trace.Checkpoint, reverted: bool) !void {
        const marker = self.checkpoints.getLastOrNull() orelse return error.UnmatchedCheckpoint;
        if (marker.depth != event.depth or
            marker.journal_len != event.journal_len or
            marker.logs_len != event.logs_len)
        {
            return error.CheckpointMismatch;
        }
        _ = self.checkpoints.pop();
        if (!reverted) return;
        for (self.events.items[marker.event_start..]) |*recorded| recorded.deactivateWrite();
    }

    fn accountAccess(ptr: *anyopaque, event: trace.AccountAccess) void {
        const self: *Recorder = @ptrCast(@alignCast(ptr));
        self.recordAccountAccess(event.address) catch |err| {
            self.failure = err;
        };
    }

    fn stateRead(ptr: *anyopaque, event: trace.StateRead) void {
        const self: *Recorder = @ptrCast(@alignCast(ptr));
        switch (event) {
            .storage => |storage_read| self.recordStorageRead(storage_read) catch |err| {
                self.failure = err;
            },
            else => {},
        }
    }

    fn stateWrite(ptr: *anyopaque, event: trace.StateWrite) void {
        const self: *Recorder = @ptrCast(@alignCast(ptr));
        switch (event) {
            .storage => |storage_write| self.recordStorageWrite(storage_write) catch |err| {
                self.failure = err;
            },
            .balance => |balance_write| self.recordBalanceWrite(balance_write) catch |err| {
                self.failure = err;
            },
            .nonce => |nonce_write| self.recordNonceWrite(nonce_write) catch |err| {
                self.failure = err;
            },
            else => {},
        }
    }

    fn checkpointEvent(ptr: *anyopaque, event: trace.Checkpoint) void {
        const self: *Recorder = @ptrCast(@alignCast(ptr));
        self.recordCheckpoint(event) catch |err| {
            self.failure = err;
        };
    }
};

const StorageRead = struct {
    address: bal.Address,
    slot: u256,
};

const StorageWrite = struct {
    block_access_index: bal.BlockAccessIndex,
    address: bal.Address,
    slot: u256,
    previous: u256,
    value: u256,
    sequence: usize,
    active: bool = true,
};

const BalanceWrite = struct {
    block_access_index: bal.BlockAccessIndex,
    address: bal.Address,
    previous: u256,
    value: u256,
    sequence: usize,
    active: bool = true,
};

const NonceWrite = struct {
    block_access_index: bal.BlockAccessIndex,
    address: bal.Address,
    previous: u64,
    value: u64,
    sequence: usize,
    active: bool = true,
};

const Event = union(enum) {
    account_access: bal.Address,
    storage_read: StorageRead,
    storage_write: StorageWrite,
    balance_write: BalanceWrite,
    nonce_write: NonceWrite,

    fn deactivateWrite(self: *Event) void {
        switch (self.*) {
            .storage_write => |*write| write.active = false,
            .balance_write => |*write| write.active = false,
            .nonce_write => |*write| write.active = false,
            else => {},
        }
    }
};

const CheckpointMarker = struct {
    depth: u16,
    journal_len: usize,
    logs_len: usize,
    event_start: usize,
};

const AccountBuilder = struct {
    address: bal.Address,
    storage_reads: std.ArrayList(u256) = .empty,
    storage_writes: std.ArrayList(StorageWrite) = .empty,
    balance_writes: std.ArrayList(BalanceWrite) = .empty,
    nonce_writes: std.ArrayList(NonceWrite) = .empty,

    fn deinit(self: *AccountBuilder, allocator: Allocator) void {
        self.storage_reads.deinit(allocator);
        self.storage_writes.deinit(allocator);
        self.balance_writes.deinit(allocator);
        self.nonce_writes.deinit(allocator);
        self.* = .{ .address = std.mem.zeroes(bal.Address) };
    }

    fn toOwnedAccount(self: *AccountBuilder, allocator: Allocator) !bal.AccountChanges {
        std.mem.sort(StorageWrite, self.storage_writes.items, {}, storageWriteLessThan);

        var account = bal.AccountChanges{ .address = self.address };
        errdefer deinitAccount(allocator, &account);

        account.storage_changes = try self.toOwnedStorageChanges(allocator);
        account.storage_reads = try self.toOwnedStorageReads(allocator, account.storage_changes);
        account.balance_changes = try self.toOwnedBalanceChanges(allocator);
        account.nonce_changes = try self.toOwnedNonceChanges(allocator);
        return account;
    }

    fn toOwnedStorageChanges(self: *AccountBuilder, allocator: Allocator) ![]bal.SlotChanges {
        var slots: std.ArrayList(bal.SlotChanges) = .empty;
        errdefer {
            for (slots.items) |slot| {
                if (slot.changes.len > 0) allocator.free(slot.changes);
            }
            slots.deinit(allocator);
        }

        var index: usize = 0;
        while (index < self.storage_writes.items.len) {
            const slot = self.storage_writes.items[index].slot;
            var changes: std.ArrayList(bal.StorageChange) = .empty;
            errdefer changes.deinit(allocator);

            while (index < self.storage_writes.items.len and self.storage_writes.items[index].slot == slot) {
                const block_access_index = self.storage_writes.items[index].block_access_index;
                const first = self.storage_writes.items[index];
                var last = self.storage_writes.items[index];
                index += 1;
                while (index < self.storage_writes.items.len and
                    self.storage_writes.items[index].slot == slot and
                    self.storage_writes.items[index].block_access_index == block_access_index)
                {
                    last = self.storage_writes.items[index];
                    index += 1;
                }
                if (last.value != first.previous) {
                    try changes.append(allocator, .{
                        .block_access_index = block_access_index,
                        .new_value = last.value,
                    });
                }
            }

            if (changes.items.len == 0) {
                changes.deinit(allocator);
                continue;
            }
            const owned_changes = try changes.toOwnedSlice(allocator);
            errdefer allocator.free(owned_changes);
            try slots.append(allocator, .{
                .slot = slot,
                .changes = owned_changes,
            });
        }

        return slots.toOwnedSlice(allocator);
    }

    fn toOwnedStorageReads(
        self: *AccountBuilder,
        allocator: Allocator,
        storage_changes: []const bal.SlotChanges,
    ) ![]u256 {
        std.mem.sort(u256, self.storage_reads.items, {}, u256LessThan);

        var reads: std.ArrayList(u256) = .empty;
        errdefer reads.deinit(allocator);
        var previous: ?u256 = null;
        var change_index: usize = 0;
        for (self.storage_reads.items) |slot| {
            if (previous != null and previous.? == slot) continue;
            previous = slot;
            while (change_index < storage_changes.len and storage_changes[change_index].slot < slot) {
                change_index += 1;
            }
            if (change_index < storage_changes.len and storage_changes[change_index].slot == slot) continue;
            try reads.append(allocator, slot);
        }
        return reads.toOwnedSlice(allocator);
    }

    fn toOwnedBalanceChanges(self: *AccountBuilder, allocator: Allocator) ![]bal.BalanceChange {
        std.mem.sort(BalanceWrite, self.balance_writes.items, {}, balanceWriteLessThan);

        var changes: std.ArrayList(bal.BalanceChange) = .empty;
        errdefer changes.deinit(allocator);
        var index: usize = 0;
        while (index < self.balance_writes.items.len) {
            const block_access_index = self.balance_writes.items[index].block_access_index;
            const first = self.balance_writes.items[index];
            var last = self.balance_writes.items[index];
            index += 1;
            while (index < self.balance_writes.items.len and self.balance_writes.items[index].block_access_index == block_access_index) {
                last = self.balance_writes.items[index];
                index += 1;
            }
            if (last.value != first.previous) {
                try changes.append(allocator, .{
                    .block_access_index = block_access_index,
                    .post_balance = last.value,
                });
            }
        }
        return changes.toOwnedSlice(allocator);
    }

    fn toOwnedNonceChanges(self: *AccountBuilder, allocator: Allocator) ![]bal.NonceChange {
        std.mem.sort(NonceWrite, self.nonce_writes.items, {}, nonceWriteLessThan);

        var changes: std.ArrayList(bal.NonceChange) = .empty;
        errdefer changes.deinit(allocator);
        var index: usize = 0;
        while (index < self.nonce_writes.items.len) {
            const block_access_index = self.nonce_writes.items[index].block_access_index;
            const first = self.nonce_writes.items[index];
            var last = self.nonce_writes.items[index];
            index += 1;
            while (index < self.nonce_writes.items.len and self.nonce_writes.items[index].block_access_index == block_access_index) {
                last = self.nonce_writes.items[index];
                index += 1;
            }
            if (last.value != first.previous) {
                try changes.append(allocator, .{
                    .block_access_index = block_access_index,
                    .new_nonce = last.value,
                });
            }
        }
        return changes.toOwnedSlice(allocator);
    }
};

fn accountBuilderFor(
    allocator: Allocator,
    builders: *std.ArrayList(AccountBuilder),
    indices: *std.AutoHashMap(bal.Address, usize),
    target: bal.Address,
) !*AccountBuilder {
    if (indices.get(target)) |index| return &builders.items[index];

    const index = builders.items.len;
    try builders.append(allocator, .{ .address = target });
    errdefer _ = builders.pop();
    try indices.put(target, index);
    return &builders.items[index];
}

fn deinitAccount(allocator: Allocator, account: *const bal.AccountChanges) void {
    for (account.storage_changes) |slot| {
        if (slot.changes.len > 0) allocator.free(slot.changes);
    }
    if (account.storage_changes.len > 0) allocator.free(account.storage_changes);
    if (account.storage_reads.len > 0) allocator.free(account.storage_reads);
    if (account.balance_changes.len > 0) allocator.free(account.balance_changes);
    if (account.nonce_changes.len > 0) allocator.free(account.nonce_changes);
}

fn accountLessThan(_: void, lhs: bal.AccountChanges, rhs: bal.AccountChanges) bool {
    return std.mem.order(u8, &lhs.address, &rhs.address) == .lt;
}

fn storageWriteLessThan(_: void, lhs: StorageWrite, rhs: StorageWrite) bool {
    if (lhs.slot != rhs.slot) return lhs.slot < rhs.slot;
    if (lhs.block_access_index != rhs.block_access_index) return lhs.block_access_index < rhs.block_access_index;
    return lhs.sequence < rhs.sequence;
}

fn balanceWriteLessThan(_: void, lhs: BalanceWrite, rhs: BalanceWrite) bool {
    if (lhs.block_access_index != rhs.block_access_index) return lhs.block_access_index < rhs.block_access_index;
    return lhs.sequence < rhs.sequence;
}

fn nonceWriteLessThan(_: void, lhs: NonceWrite, rhs: NonceWrite) bool {
    if (lhs.block_access_index != rhs.block_access_index) return lhs.block_access_index < rhs.block_access_index;
    return lhs.sequence < rhs.sequence;
}

fn u256LessThan(_: void, lhs: u256, rhs: u256) bool {
    return lhs < rhs;
}

test "BAL recorder sink declares only materializable state events" {
    var recorder = Recorder.init(std.testing.allocator);
    defer recorder.deinit();

    var sink = recorder.sink();
    try std.testing.expect(sink.wantsAccountAccess());
    try std.testing.expect(sink.wantsStateReadKind(.storage));
    try std.testing.expect(sink.wantsStateWriteKind(.storage));
    try std.testing.expect(sink.wantsStateWriteKind(.balance));
    try std.testing.expect(sink.wantsStateWriteKind(.nonce));
    try std.testing.expect(!sink.wantsStateWriteKind(.code));
    try std.testing.expect(sink.wantsCheckpoint());
}

test "BAL recorder builds canonical observed storage balance and nonce changes" {
    var recorder = Recorder.init(std.testing.allocator);
    defer recorder.deinit();
    var sink = recorder.sink();

    const written = address.addr(1);
    const read_only = address.addr(2);

    recorder.setBlockAccessIndex(1);
    sink.stateWrite(.{ .storage = .{
        .address = written,
        .key = 1,
        .previous = 0,
        .value = 2,
    } });
    sink.stateWrite(.{ .storage = .{
        .address = written,
        .key = 1,
        .previous = 2,
        .value = 3,
    } });
    sink.stateWrite(.{ .balance = .{
        .address = written,
        .previous = 0,
        .value = 9,
    } });
    sink.stateRead(.{ .storage = .{
        .address = written,
        .key = 1,
        .value = 3,
    } });
    sink.stateRead(.{ .storage = .{
        .address = read_only,
        .key = 4,
        .value = 5,
    } });

    recorder.setBlockAccessIndex(2);
    sink.stateWrite(.{ .nonce = .{
        .address = written,
        .previous = 0,
        .value = 7,
    } });

    var observed = try recorder.toOwnedBlockAccessList(std.testing.allocator);
    defer observed.deinit(std.testing.allocator);

    try bal.validate(observed.accounts, .{ .transaction_count = 1 });
    try std.testing.expectEqual(@as(usize, 2), observed.accounts.len);
    try std.testing.expectEqual(written, observed.accounts[0].address);
    try std.testing.expectEqual(@as(usize, 1), observed.accounts[0].storage_changes.len);
    try std.testing.expectEqual(@as(u256, 1), observed.accounts[0].storage_changes[0].slot);
    try std.testing.expectEqual(@as(usize, 1), observed.accounts[0].storage_changes[0].changes.len);
    try std.testing.expectEqual(bal.StorageChange{ .block_access_index = 1, .new_value = 3 }, observed.accounts[0].storage_changes[0].changes[0]);
    try std.testing.expectEqual(@as(usize, 0), observed.accounts[0].storage_reads.len);
    try std.testing.expectEqual(bal.BalanceChange{ .block_access_index = 1, .post_balance = 9 }, observed.accounts[0].balance_changes[0]);
    try std.testing.expectEqual(bal.NonceChange{ .block_access_index = 2, .new_nonce = 7 }, observed.accounts[0].nonce_changes[0]);

    try std.testing.expectEqual(read_only, observed.accounts[1].address);
    try std.testing.expectEqualSlices(u256, &.{4}, observed.accounts[1].storage_reads);
}

test "BAL recorder preserves access-only accounts" {
    var recorder = Recorder.init(std.testing.allocator);
    defer recorder.deinit();
    var sink = recorder.sink();

    const accessed = address.addr(3);
    sink.accountAccess(.{ .address = accessed });

    var observed = try recorder.toOwnedBlockAccessList(std.testing.allocator);
    defer observed.deinit(std.testing.allocator);

    try bal.validate(observed.accounts, .{});
    try std.testing.expectEqual(@as(usize, 1), observed.accounts.len);
    try std.testing.expectEqual(accessed, observed.accounts[0].address);
    try std.testing.expectEqual(@as(usize, 0), observed.accounts[0].storage_changes.len);
    try std.testing.expectEqual(@as(usize, 0), observed.accounts[0].storage_reads.len);
    try std.testing.expectEqual(@as(usize, 0), observed.accounts[0].balance_changes.len);
    try std.testing.expectEqual(@as(usize, 0), observed.accounts[0].nonce_changes.len);
}

test "BAL recorder collapses net-zero writes to accesses" {
    var recorder = Recorder.init(std.testing.allocator);
    defer recorder.deinit();
    var sink = recorder.sink();

    const accessed = address.addr(4);
    recorder.setBlockAccessIndex(1);
    sink.stateWrite(.{ .storage = .{ .address = accessed, .key = 7, .previous = 0, .value = 1 } });
    sink.stateWrite(.{ .storage = .{ .address = accessed, .key = 7, .previous = 1, .value = 0 } });
    sink.stateWrite(.{ .balance = .{ .address = accessed, .previous = 5, .value = 9 } });
    sink.stateWrite(.{ .balance = .{ .address = accessed, .previous = 9, .value = 5 } });
    sink.stateWrite(.{ .nonce = .{ .address = accessed, .previous = 2, .value = 3 } });
    sink.stateWrite(.{ .nonce = .{ .address = accessed, .previous = 3, .value = 2 } });

    var observed = try recorder.toOwnedBlockAccessList(std.testing.allocator);
    defer observed.deinit(std.testing.allocator);

    try bal.validate(observed.accounts, .{ .transaction_count = 1 });
    try std.testing.expectEqual(@as(usize, 1), observed.accounts.len);
    try std.testing.expectEqual(@as(usize, 0), observed.accounts[0].storage_changes.len);
    try std.testing.expectEqualSlices(u256, &.{7}, observed.accounts[0].storage_reads);
    try std.testing.expectEqual(@as(usize, 0), observed.accounts[0].balance_changes.len);
    try std.testing.expectEqual(@as(usize, 0), observed.accounts[0].nonce_changes.len);
}

test "BAL recorder discards reverted writes but preserves accesses" {
    var recorder = Recorder.init(std.testing.allocator);
    defer recorder.deinit();
    var sink = recorder.sink();

    const accessed = address.addr(5);
    recorder.setBlockAccessIndex(1);
    sink.checkpoint(.{ .kind = .checkpoint, .depth = 1, .journal_len = 2, .logs_len = 0 });
    sink.stateWrite(.{ .storage = .{ .address = accessed, .key = 8, .previous = 0, .value = 1 } });
    sink.stateWrite(.{ .balance = .{ .address = accessed, .previous = 5, .value = 6 } });
    sink.checkpoint(.{ .kind = .revert, .depth = 1, .journal_len = 2, .logs_len = 0 });

    var observed = try recorder.toOwnedBlockAccessList(std.testing.allocator);
    defer observed.deinit(std.testing.allocator);

    try bal.validate(observed.accounts, .{ .transaction_count = 1 });
    try std.testing.expectEqual(@as(usize, 1), observed.accounts.len);
    try std.testing.expectEqual(@as(usize, 0), observed.accounts[0].storage_changes.len);
    try std.testing.expectEqualSlices(u256, &.{8}, observed.accounts[0].storage_reads);
    try std.testing.expectEqual(@as(usize, 0), observed.accounts[0].balance_changes.len);
}
