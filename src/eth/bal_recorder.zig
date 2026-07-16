//! BAL recorder fed by the captured runtime's fallible state target.

const std = @import("std");
const bal = @import("bal.zig");
const trace = @import("../trace.zig");
const address = @import("../address.zig");
const CaptureStateTarget = @import("../executor/capture_context.zig").StateTarget;
const crypto = @import("../crypto.zig");

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
        for (self.events.items) |*event| event.deinit(self.allocator);
        self.events.deinit(self.allocator);
        self.checkpoints.deinit(self.allocator);
        self.* = init(self.allocator);
    }

    pub fn setBlockAccessIndex(self: *Recorder, block_access_index: bal.BlockAccessIndex) void {
        self.block_access_index = block_access_index;
    }

    pub fn stateTarget(self: *Recorder) CaptureStateTarget {
        return CaptureStateTarget.init(self, &.{
            .account_access = captureAccountAccess,
            .state_read = captureStateRead,
            .state_write = captureStateWrite,
            .checkpoint = captureCheckpoint,
        });
    }

    pub fn accountAccess(self: *Recorder, event: trace.AccountAccess) !void {
        self.recordAccountAccess(event.address) catch |err| return self.captureFailure(err);
    }

    pub fn stateRead(self: *Recorder, event: trace.StateRead) !void {
        switch (event) {
            .storage => |storage_read| self.recordStorageRead(storage_read) catch |err| {
                return self.captureFailure(err);
            },
            else => {},
        }
    }

    pub fn stateWrite(self: *Recorder, event: trace.StateWrite) !void {
        switch (event) {
            .storage => |storage_write| self.recordStorageWrite(storage_write) catch |err| {
                return self.captureFailure(err);
            },
            .balance => |balance_write| self.recordBalanceWrite(balance_write) catch |err| {
                return self.captureFailure(err);
            },
            .nonce => |nonce_write| self.recordNonceWrite(nonce_write) catch |err| {
                return self.captureFailure(err);
            },
            .code => |code_write| self.recordCodeWrite(code_write) catch |err| {
                return self.captureFailure(err);
            },
            else => {},
        }
    }

    pub fn checkpoint(self: *Recorder, event: trace.Checkpoint) !void {
        self.recordCheckpoint(event) catch |err| return self.captureFailure(err);
    }

    pub fn failureCause(self: *const Recorder) ?anyerror {
        return self.failure;
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

    pub fn recordCodeWrite(self: *Recorder, event: trace.CodeWrite) !void {
        try self.recordAccountAccess(event.address);
        const new_code = try self.allocator.dupe(u8, event.code);
        var new_code_owned = true;
        errdefer if (new_code_owned) self.allocator.free(new_code);

        try self.append(.{ .code_write = .{
            .block_access_index = self.block_access_index,
            .address = event.address,
            .previous_hash = event.previous_hash,
            .new_code = new_code,
            .sequence = self.nextSequence(),
        } });
        new_code_owned = false;
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
                .code_write => |code_write| {
                    if (!code_write.active) continue;
                    const builder = try accountBuilderFor(allocator, &builders, &builder_indices, code_write.address);
                    try builder.code_writes.append(allocator, code_write);
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

    fn captureFailure(self: *Recorder, err: anyerror) anyerror {
        self.failure = err;
        return err;
    }

    fn captureAccountAccess(ptr: *anyopaque, event: trace.AccountAccess) !void {
        const self: *Recorder = @ptrCast(@alignCast(ptr));
        try self.accountAccess(event);
    }

    fn captureStateRead(ptr: *anyopaque, event: trace.StateRead) !void {
        const self: *Recorder = @ptrCast(@alignCast(ptr));
        try self.stateRead(event);
    }

    fn captureStateWrite(ptr: *anyopaque, event: trace.StateWrite) !void {
        const self: *Recorder = @ptrCast(@alignCast(ptr));
        try self.stateWrite(event);
    }

    fn captureCheckpoint(ptr: *anyopaque, event: trace.Checkpoint) !void {
        const self: *Recorder = @ptrCast(@alignCast(ptr));
        try self.checkpoint(event);
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

const CodeWrite = struct {
    block_access_index: bal.BlockAccessIndex,
    address: bal.Address,
    previous_hash: [32]u8,
    new_code: []const u8,
    sequence: usize,
    active: bool = true,
};

const Event = union(enum) {
    account_access: bal.Address,
    storage_read: StorageRead,
    storage_write: StorageWrite,
    balance_write: BalanceWrite,
    nonce_write: NonceWrite,
    code_write: CodeWrite,

    fn deactivateWrite(self: *Event) void {
        switch (self.*) {
            .storage_write => |*write| write.active = false,
            .balance_write => |*write| write.active = false,
            .nonce_write => |*write| write.active = false,
            .code_write => |*write| write.active = false,
            else => {},
        }
    }

    fn deinit(self: *Event, allocator: Allocator) void {
        switch (self.*) {
            .code_write => |write| allocator.free(@constCast(write.new_code)),
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
    code_writes: std.ArrayList(CodeWrite) = .empty,

    fn deinit(self: *AccountBuilder, allocator: Allocator) void {
        self.storage_reads.deinit(allocator);
        self.storage_writes.deinit(allocator);
        self.balance_writes.deinit(allocator);
        self.nonce_writes.deinit(allocator);
        self.code_writes.deinit(allocator);
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
        account.code_changes = try self.toOwnedCodeChanges(allocator);
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

    fn toOwnedCodeChanges(self: *AccountBuilder, allocator: Allocator) ![]bal.CodeChange {
        std.mem.sort(CodeWrite, self.code_writes.items, {}, codeWriteLessThan);

        var changes: std.ArrayList(bal.CodeChange) = .empty;
        errdefer {
            for (changes.items) |change| allocator.free(@constCast(change.new_code));
            changes.deinit(allocator);
        }

        var index: usize = 0;
        while (index < self.code_writes.items.len) {
            const block_access_index = self.code_writes.items[index].block_access_index;
            const first = self.code_writes.items[index];
            var last = self.code_writes.items[index];
            index += 1;
            while (index < self.code_writes.items.len and self.code_writes.items[index].block_access_index == block_access_index) {
                last = self.code_writes.items[index];
                index += 1;
            }
            const final_hash = crypto.keccak256(last.new_code);
            if (std.mem.eql(u8, &final_hash, &first.previous_hash)) continue;

            const new_code = try allocator.dupe(u8, last.new_code);
            errdefer allocator.free(new_code);
            try changes.append(allocator, .{
                .block_access_index = block_access_index,
                .new_code = new_code,
            });
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
    for (account.code_changes) |change| allocator.free(@constCast(change.new_code));
    if (account.code_changes.len > 0) allocator.free(account.code_changes);
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

fn codeWriteLessThan(_: void, lhs: CodeWrite, rhs: CodeWrite) bool {
    if (lhs.block_access_index != rhs.block_access_index) return lhs.block_access_index < rhs.block_access_index;
    return lhs.sequence < rhs.sequence;
}

fn u256LessThan(_: void, lhs: u256, rhs: u256) bool {
    return lhs < rhs;
}

test "BAL recorder exposes one fallible captured state target" {
    var recorder = Recorder.init(std.testing.allocator);
    defer recorder.deinit();

    const target = recorder.stateTarget();
    try target.accountAccess(.{ .address = address.addr(1) });
    try std.testing.expectEqual(@as(usize, 1), recorder.events.items.len);
}

test "BAL recorder owns and coalesces code changes per block access index" {
    var recorder = Recorder.init(std.testing.allocator);
    defer recorder.deinit();

    const changed = address.addr(6);
    var first_code = [_]u8{ 0x60, 0x00 };
    var final_code = [_]u8{ 0x60, 0x01 };
    const first_hash = crypto.keccak256(&first_code);
    const final_hash = crypto.keccak256(&final_code);

    recorder.setBlockAccessIndex(1);
    try recorder.stateWrite(.{ .code = .{
        .address = changed,
        .previous_hash = crypto.keccak256_empty,
        .size = first_code.len,
        .code = &first_code,
    } });
    try recorder.stateWrite(.{ .code = .{
        .address = changed,
        .previous_hash = first_hash,
        .size = final_code.len,
        .code = &final_code,
    } });
    @memset(&first_code, 0xff);
    @memset(&final_code, 0xff);

    recorder.setBlockAccessIndex(2);
    try recorder.stateWrite(.{ .code = .{
        .address = changed,
        .previous_hash = final_hash,
        .size = 1,
        .code = &.{0x00},
    } });

    var observed = try recorder.toOwnedBlockAccessList(std.testing.allocator);
    defer observed.deinit(std.testing.allocator);

    try bal.validate(observed.accounts, .{ .transaction_count = 2 });
    try std.testing.expectEqual(@as(usize, 1), observed.accounts.len);
    try std.testing.expectEqual(@as(usize, 2), observed.accounts[0].code_changes.len);
    try std.testing.expectEqual(@as(bal.BlockAccessIndex, 1), observed.accounts[0].code_changes[0].block_access_index);
    try std.testing.expectEqualSlices(u8, &.{ 0x60, 0x01 }, observed.accounts[0].code_changes[0].new_code);
    try std.testing.expectEqual(@as(bal.BlockAccessIndex, 2), observed.accounts[0].code_changes[1].block_access_index);
    try std.testing.expectEqualSlices(u8, &.{0x00}, observed.accounts[0].code_changes[1].new_code);
}

test "BAL recorder omits same-index no-op code writes" {
    var recorder = Recorder.init(std.testing.allocator);
    defer recorder.deinit();

    const changed = address.addr(7);
    recorder.setBlockAccessIndex(1);
    try recorder.stateWrite(.{ .code = .{
        .address = changed,
        .previous_hash = crypto.keccak256_empty,
        .size = 0,
        .code = &.{},
    } });
    try recorder.stateWrite(.{ .code = .{
        .address = changed,
        .previous_hash = crypto.keccak256_empty,
        .size = 0,
        .code = &.{},
    } });

    var observed = try recorder.toOwnedBlockAccessList(std.testing.allocator);
    defer observed.deinit(std.testing.allocator);

    try bal.validate(observed.accounts, .{ .transaction_count = 1 });
    try std.testing.expectEqual(@as(usize, 1), observed.accounts.len);
    try std.testing.expectEqual(@as(usize, 0), observed.accounts[0].code_changes.len);
}

test "BAL recorder builds canonical observed storage balance and nonce changes" {
    var recorder = Recorder.init(std.testing.allocator);
    defer recorder.deinit();

    const written = address.addr(1);
    const read_only = address.addr(2);

    recorder.setBlockAccessIndex(1);
    try recorder.stateWrite(.{ .storage = .{
        .address = written,
        .key = 1,
        .previous = 0,
        .value = 2,
    } });
    try recorder.stateWrite(.{ .storage = .{
        .address = written,
        .key = 1,
        .previous = 2,
        .value = 3,
    } });
    try recorder.stateWrite(.{ .balance = .{
        .address = written,
        .previous = 0,
        .value = 9,
    } });
    try recorder.stateRead(.{ .storage = .{
        .address = written,
        .key = 1,
        .value = 3,
    } });
    try recorder.stateRead(.{ .storage = .{
        .address = read_only,
        .key = 4,
        .value = 5,
    } });

    recorder.setBlockAccessIndex(2);
    try recorder.stateWrite(.{ .nonce = .{
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

    const accessed = address.addr(3);
    try recorder.accountAccess(.{ .address = accessed });

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

    const accessed = address.addr(4);
    recorder.setBlockAccessIndex(1);
    try recorder.stateWrite(.{ .storage = .{ .address = accessed, .key = 7, .previous = 0, .value = 1 } });
    try recorder.stateWrite(.{ .storage = .{ .address = accessed, .key = 7, .previous = 1, .value = 0 } });
    try recorder.stateWrite(.{ .balance = .{ .address = accessed, .previous = 5, .value = 9 } });
    try recorder.stateWrite(.{ .balance = .{ .address = accessed, .previous = 9, .value = 5 } });
    try recorder.stateWrite(.{ .nonce = .{ .address = accessed, .previous = 2, .value = 3 } });
    try recorder.stateWrite(.{ .nonce = .{ .address = accessed, .previous = 3, .value = 2 } });

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

    const accessed = address.addr(5);
    recorder.setBlockAccessIndex(1);
    try recorder.checkpoint(.{ .kind = .checkpoint, .depth = 1, .journal_len = 2, .logs_len = 0 });
    try recorder.stateWrite(.{ .storage = .{ .address = accessed, .key = 8, .previous = 0, .value = 1 } });
    try recorder.stateWrite(.{ .balance = .{ .address = accessed, .previous = 5, .value = 6 } });
    try recorder.stateWrite(.{ .code = .{
        .address = accessed,
        .previous_hash = crypto.keccak256_empty,
        .size = 2,
        .code = &.{ 0x60, 0x00 },
    } });
    try recorder.checkpoint(.{ .kind = .revert, .depth = 1, .journal_len = 2, .logs_len = 0 });

    var observed = try recorder.toOwnedBlockAccessList(std.testing.allocator);
    defer observed.deinit(std.testing.allocator);

    try bal.validate(observed.accounts, .{ .transaction_count = 1 });
    try std.testing.expectEqual(@as(usize, 1), observed.accounts.len);
    try std.testing.expectEqual(@as(usize, 0), observed.accounts[0].storage_changes.len);
    try std.testing.expectEqualSlices(u256, &.{8}, observed.accounts[0].storage_reads);
    try std.testing.expectEqual(@as(usize, 0), observed.accounts[0].balance_changes.len);
    try std.testing.expectEqual(@as(usize, 0), observed.accounts[0].code_changes.len);
}
