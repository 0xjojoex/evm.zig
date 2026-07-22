//! Detached transaction effects and ordered state folds for the BAL candidate lane.
//!
//! A lane executor is disposable and may be reset or destroyed as soon as one
//! transaction completes. `TransactionEffects` detaches every borrowed output
//! needed by the serial fold: result bytes, logs, the authoritative payload
//! changeset, and the index-free semantic observations used to rebuild BAL.
//! BlockSTF post-transaction hooks are deliberately not included; the ordered
//! fold still owns those semantics. A finished fold can be exposed as a
//! read-only post-state over the authenticated base so block-final work can
//! later run serially. This module does not spawn threads or own canonical
//! block state.

const std = @import("std");

const Address = @import("../../address.zig").Address;
const Host = @import("../../Host.zig");
const bal = @import("model.zig");
const bal_recorder = @import("recorder.zig");
const crypto = @import("../../crypto.zig");
const state = @import("../../state.zig");
const vm = @import("../../vm.zig");

/// Passive, transaction-ordered accumulation of detached lane changesets.
///
/// This never commits a backend. Account and storage writes use last-write-wins
/// semantics in transaction order; a later deletion removes every earlier
/// write for that account. Deletion followed by recreation is rejected because
/// the current memory and trie changeset consumers disagree on that shape.
/// The caller must discard this fold and use canonical serial execution.
///
/// `FoldAlreadyFinished`, `OutOfOrderTransaction`, and
/// `ConflictingCodeInsert` normally indicate a broken internal caller contract
/// (or an impossible Keccak collision). They remain typed errors only because
/// this diagnostic lane deliberately contains every non-consensus failure and
/// falls back without affecting the authoritative serial fold. Any failed
/// append poisons the fold: even allocation failure may occur after earlier
/// items were merged, so a failed fold can only be discarded.
pub const OrderedChangesetFold = struct {
    const StorageKey = state.StorageKey;

    const Lifecycle = enum {
        building,
        failed,
        finished,
        taken,
    };

    pub const Error = std.mem.Allocator.Error || error{
        AccountRecreationUnsupported,
        ConflictingCodeInsert,
        FoldAlreadyFinished,
        FoldFailed,
        OutOfOrderTransaction,
    };

    allocator: std.mem.Allocator,
    changeset: state.Changeset = state.Changeset.init(),
    account_update_indices: std.AutoHashMap(Address, usize),
    code_insert_indices: std.AutoHashMap([32]u8, usize),
    deleted_accounts: std.AutoHashMap(Address, void),
    storage_write_indices: std.AutoHashMap(StorageKey, usize),
    next_transaction_index: usize = 0,
    lifecycle: Lifecycle = .building,

    pub fn init(allocator: std.mem.Allocator) OrderedChangesetFold {
        return .{
            .allocator = allocator,
            .account_update_indices = .init(allocator),
            .code_insert_indices = .init(allocator),
            .deleted_accounts = .init(allocator),
            .storage_write_indices = .init(allocator),
        };
    }

    pub fn deinit(self: *OrderedChangesetFold) void {
        self.changeset.deinit(self.allocator);
        self.account_update_indices.deinit();
        self.code_insert_indices.deinit();
        self.deleted_accounts.deinit();
        self.storage_write_indices.deinit();
        self.* = undefined;
    }

    pub fn append(
        self: *OrderedChangesetFold,
        transaction_index: usize,
        lane: *const state.Changeset,
    ) Error!void {
        switch (self.lifecycle) {
            .building => {},
            .failed => return error.FoldFailed,
            .finished, .taken => return error.FoldAlreadyFinished,
        }
        self.appendFallible(transaction_index, lane) catch |err| {
            self.lifecycle = .failed;
            return err;
        };
    }

    fn appendFallible(
        self: *OrderedChangesetFold,
        transaction_index: usize,
        lane: *const state.Changeset,
    ) Error!void {
        if (transaction_index != self.next_transaction_index) return error.OutOfOrderTransaction;
        try self.validateLane(lane);

        for (lane.code_inserts.items) |insert| try self.mergeCodeInsert(lane, insert);
        for (lane.account_updates.items) |update| try self.mergeAccountUpdate(update);
        for (lane.storage_writes.items) |write| try self.mergeStorageWrite(write);
        for (lane.account_deletes.items) |address| try self.mergeAccountDelete(address);
        self.next_transaction_index += 1;
    }

    /// Freeze the fold into canonical Changeset ordering.
    pub fn finish(self: *OrderedChangesetFold) Error!void {
        switch (self.lifecycle) {
            .building => {},
            .failed => return error.FoldFailed,
            .finished, .taken => return error.FoldAlreadyFinished,
        }
        self.compactDeletedAccountWrites();
        self.compactUnusedCode();
        self.changeset.sort();
        self.lifecycle = .finished;
    }

    pub fn view(self: *const OrderedChangesetFold) *const state.Changeset {
        std.debug.assert(self.lifecycle == .finished);
        return &self.changeset;
    }

    /// Transfer the canonical folded delta to the caller. The fold remains
    /// deinitializable, but no longer owns any changeset allocations.
    pub fn takeOwned(self: *OrderedChangesetFold) state.Changeset {
        std.debug.assert(self.lifecycle == .finished);
        const owned = self.changeset;
        self.changeset = state.Changeset.init();
        self.lifecycle = .taken;
        return owned;
    }

    pub fn transactionCount(self: *const OrderedChangesetFold) usize {
        return self.next_transaction_index;
    }

    /// Borrow this finished fold as canonical state layered over `base`.
    pub fn readerOver(self: *const OrderedChangesetFold, base: state.Reader) FoldedStateReader {
        std.debug.assert(self.lifecycle == .finished);
        return FoldedStateReader.initAssumeCanonical(base, &self.changeset);
    }

    fn validateLane(self: *const OrderedChangesetFold, lane: *const state.Changeset) Error!void {
        for (lane.account_deletes.items) |deleted| {
            if (containsAccountUpdate(lane, deleted) or containsStorageWrite(lane, deleted))
                return error.AccountRecreationUnsupported;
        }
        for (lane.account_updates.items) |update| {
            if (self.deleted_accounts.contains(update.address))
                return error.AccountRecreationUnsupported;
        }
        for (lane.storage_writes.items) |write| {
            if (self.deleted_accounts.contains(write.address))
                return error.AccountRecreationUnsupported;
        }
    }

    fn mergeCodeInsert(
        self: *OrderedChangesetFold,
        lane: *const state.Changeset,
        insert: state.Changeset.CodeInsert,
    ) Error!void {
        const code = lane.codeBytes(insert);
        if (self.code_insert_indices.get(insert.code_hash)) |index| {
            if (!std.mem.eql(u8, self.changeset.codeBytes(self.changeset.code_inserts.items[index]), code))
                return error.ConflictingCodeInsert;
            return;
        }

        try self.code_insert_indices.ensureUnusedCapacity(1);
        const index = self.changeset.code_inserts.items.len;
        try self.changeset.appendCodeInsert(self.allocator, insert.code_hash, code);
        self.code_insert_indices.putAssumeCapacity(insert.code_hash, index);
    }

    fn mergeAccountUpdate(self: *OrderedChangesetFold, update: state.Changeset.AccountUpdate) Error!void {
        if (self.account_update_indices.get(update.address)) |index| {
            self.changeset.account_updates.items[index] = update;
            return;
        }
        const index = self.changeset.account_updates.items.len;
        try self.changeset.account_updates.append(self.allocator, update);
        errdefer _ = self.changeset.account_updates.pop();
        try self.account_update_indices.put(update.address, index);
    }

    fn mergeStorageWrite(self: *OrderedChangesetFold, write: state.Changeset.StorageWrite) Error!void {
        const key = StorageKey{ .address = write.address, .key = write.key };
        if (self.storage_write_indices.get(key)) |index| {
            self.changeset.storage_writes.items[index] = write;
            return;
        }
        const index = self.changeset.storage_writes.items.len;
        try self.changeset.storage_writes.append(self.allocator, write);
        errdefer _ = self.changeset.storage_writes.pop();
        try self.storage_write_indices.put(key, index);
    }

    fn mergeAccountDelete(self: *OrderedChangesetFold, address: Address) Error!void {
        if (self.deleted_accounts.contains(address)) return;
        try self.changeset.account_deletes.append(self.allocator, address);
        errdefer _ = self.changeset.account_deletes.pop();
        try self.deleted_accounts.put(address, {});
    }

    fn compactDeletedAccountWrites(self: *OrderedChangesetFold) void {
        var account_write_index: usize = 0;
        for (self.changeset.account_updates.items) |update| {
            if (self.deleted_accounts.contains(update.address)) continue;
            self.changeset.account_updates.items[account_write_index] = update;
            account_write_index += 1;
        }
        self.changeset.account_updates.items.len = account_write_index;

        var storage_write_index: usize = 0;
        for (self.changeset.storage_writes.items) |write| {
            if (self.deleted_accounts.contains(write.address)) continue;
            self.changeset.storage_writes.items[storage_write_index] = write;
            storage_write_index += 1;
        }
        self.changeset.storage_writes.items.len = storage_write_index;
    }

    fn compactUnusedCode(self: *OrderedChangesetFold) void {
        var write_index: usize = 0;
        var byte_write_index: usize = 0;
        for (self.changeset.code_inserts.items) |insert| {
            if (!self.finalStateUsesCodeHash(insert.code_hash)) continue;

            const code = self.changeset.codeBytes(insert);
            std.debug.assert(byte_write_index <= insert.code_offset);
            if (byte_write_index != insert.code_offset) {
                std.mem.copyForwards(
                    u8,
                    self.changeset.code_bytes.items[byte_write_index..][0..code.len],
                    code,
                );
            }
            self.changeset.code_inserts.items[write_index] = .{
                .code_hash = insert.code_hash,
                .code_offset = byte_write_index,
                .code_len = code.len,
            };
            write_index += 1;
            byte_write_index += code.len;
        }
        self.changeset.code_inserts.items.len = write_index;
        self.changeset.code_bytes.items.len = byte_write_index;
    }

    fn finalStateUsesCodeHash(self: *const OrderedChangesetFold, code_hash: [32]u8) bool {
        for (self.changeset.account_updates.items) |update| {
            if (std.mem.eql(u8, &update.code_hash, &code_hash)) return true;
        }
        return false;
    }
};

/// Exact equality for canonical, sorted Changesets. Code inserts compare
/// content rather than slice identity.
pub fn changesetsEqual(lhs: *const state.Changeset, rhs: *const state.Changeset) bool {
    if (lhs.account_updates.items.len != rhs.account_updates.items.len or
        !std.mem.eql(Address, lhs.account_deletes.items, rhs.account_deletes.items) or
        lhs.storage_writes.items.len != rhs.storage_writes.items.len or
        lhs.code_inserts.items.len != rhs.code_inserts.items.len)
    {
        return false;
    }
    for (lhs.account_updates.items, rhs.account_updates.items) |lhs_update, rhs_update| {
        if (!std.meta.eql(lhs_update, rhs_update)) return false;
    }
    for (lhs.storage_writes.items, rhs.storage_writes.items) |lhs_write, rhs_write| {
        if (!std.meta.eql(lhs_write, rhs_write)) return false;
    }
    for (lhs.code_inserts.items, rhs.code_inserts.items) |lhs_insert, rhs_insert| {
        if (!std.mem.eql(u8, &lhs_insert.code_hash, &rhs_insert.code_hash) or
            !std.mem.eql(u8, lhs.codeBytes(lhs_insert), rhs.codeBytes(rhs_insert)))
        {
            return false;
        }
    }
    return true;
}

/// Read-only post-state projected from one canonical ordered changeset fold.
///
/// Account metadata, code, deletes, and individual storage values are exact.
/// The changeset must be sorted, unique, and lifecycle-normalized as produced
/// by `OrderedChangesetFold.finish` or `Overlay.changeset`.
///
/// `state.Reader.accountHasStorage` is only a Boolean summary. If the fold
/// clears a nonzero pre-state slot and writes no nonzero slot, it cannot prove
/// whether untouched storage remains. That case reports
/// `FoldedStateStorageUnknown`; a candidate coordinator must fall back rather
/// than run its serial post phase over guessed state.
pub const FoldedStateReader = struct {
    pub const Error = error{FoldedStateStorageUnknown};

    pub const StoragePresence = enum {
        empty,
        nonempty,
        unknown,
    };

    pub const StrategyFailure = enum {
        storage_presence_unknown,
    };

    base: state.Reader,
    changeset: *const state.Changeset,
    strategy_failure: ?StrategyFailure = null,

    pub fn initAssumeCanonical(base: state.Reader, changeset: *const state.Changeset) FoldedStateReader {
        return .{ .base = base, .changeset = changeset };
    }

    pub fn reader(self: *FoldedStateReader) state.Reader {
        return .{ .ptr = self, .vtable = &vtable };
    }

    /// Strongest storage-presence answer available through `state.Reader`.
    pub fn storagePresence(self: *FoldedStateReader, target: Address) !StoragePresence {
        if (self.isDeleted(target)) return .empty;

        const writes = self.storageWrites(target);
        for (writes) |write| {
            if (write.value != 0) return .nonempty;
        }

        if (!try self.base.accountHasStorage(target)) return .empty;
        for (writes) |write| {
            std.debug.assert(write.value == 0);
            if (try self.base.getStorage(target, write.key) != 0) return .unknown;
        }
        return .nonempty;
    }

    const vtable = state.Reader.VTable{
        .accountExists = accountExists,
        .loadAccount = loadAccount,
        .loadCode = loadCode,
        .getStorage = getStorage,
        .accountHasStorage = accountHasStorage,
    };

    fn context(ptr: *anyopaque) *FoldedStateReader {
        return @ptrCast(@alignCast(ptr));
    }

    fn accountExists(ptr: *anyopaque, target: Address) !bool {
        const self = context(ptr);
        if (self.isDeleted(target)) return false;
        if (self.accountUpdate(target) != null) return true;
        if (try self.base.accountExists(target)) return true;
        for (self.storageWrites(target)) |write| {
            if (write.value != 0) return true;
        }
        return false;
    }

    fn loadAccount(ptr: *anyopaque, target: Address) !?state.Account {
        const self = context(ptr);
        if (self.isDeleted(target)) return null;
        if (self.accountUpdate(target)) |update| return .{
            .nonce = update.nonce,
            .balance = update.balance,
            .code_hash = update.code_hash,
        };
        if (try self.base.loadAccount(target)) |account| return account;
        for (self.storageWrites(target)) |write| {
            if (write.value != 0) return state.Account{};
        }
        return null;
    }

    fn loadCode(ptr: *anyopaque, code_hash: [32]u8) ![]const u8 {
        const self = context(ptr);
        if (std.mem.eql(u8, &code_hash, &crypto.keccak256_empty)) return &.{};
        if (self.codeInsert(code_hash)) |insert| return self.changeset.codeBytes(insert.*);

        // Delegate through the base vtable so the outer Reader performs the
        // content-hash check exactly once.
        return self.base.vtable.loadCode(self.base.ptr, code_hash);
    }

    fn getStorage(ptr: *anyopaque, target: Address, key: u256) !u256 {
        const self = context(ptr);
        if (self.isDeleted(target)) return 0;
        if (self.storageWrite(.{ .address = target, .key = key })) |write| return write.value;
        return self.base.getStorage(target, key);
    }

    fn accountHasStorage(ptr: *anyopaque, target: Address) !bool {
        const self = context(ptr);
        return switch (try self.storagePresence(target)) {
            .empty => false,
            .nonempty => true,
            .unknown => self.fail(.storage_presence_unknown),
        };
    }

    fn fail(self: *FoldedStateReader, failure: StrategyFailure) Error {
        self.strategy_failure = failure;
        return error.FoldedStateStorageUnknown;
    }

    fn accountUpdate(self: *const FoldedStateReader, target: Address) ?*const state.Changeset.AccountUpdate {
        const index = std.sort.binarySearch(
            state.Changeset.AccountUpdate,
            self.changeset.account_updates.items,
            target,
            compareAccountUpdate,
        ) orelse return null;
        return &self.changeset.account_updates.items[index];
    }

    fn codeInsert(self: *const FoldedStateReader, code_hash: [32]u8) ?*const state.Changeset.CodeInsert {
        const index = std.sort.binarySearch(
            state.Changeset.CodeInsert,
            self.changeset.code_inserts.items,
            code_hash,
            compareCodeInsert,
        ) orelse return null;
        return &self.changeset.code_inserts.items[index];
    }

    fn isDeleted(self: *const FoldedStateReader, target: Address) bool {
        return std.sort.binarySearch(
            Address,
            self.changeset.account_deletes.items,
            target,
            compareAddress,
        ) != null;
    }

    fn storageWrite(self: *const FoldedStateReader, key: state.StorageKey) ?*const state.Changeset.StorageWrite {
        const index = std.sort.binarySearch(
            state.Changeset.StorageWrite,
            self.changeset.storage_writes.items,
            key,
            compareStorageWrite,
        ) orelse return null;
        return &self.changeset.storage_writes.items[index];
    }

    fn storageWrites(self: *const FoldedStateReader, target: Address) []const state.Changeset.StorageWrite {
        const writes = self.changeset.storage_writes.items;
        const start = std.sort.lowerBound(
            state.Changeset.StorageWrite,
            writes,
            target,
            compareStorageWriteAddress,
        );
        const end = std.sort.upperBound(
            state.Changeset.StorageWrite,
            writes,
            target,
            compareStorageWriteAddress,
        );
        return writes[start..end];
    }
};

fn compareAccountUpdate(target: Address, update: state.Changeset.AccountUpdate) std.math.Order {
    return std.mem.order(u8, &target, &update.address);
}

fn compareCodeInsert(code_hash: [32]u8, insert: state.Changeset.CodeInsert) std.math.Order {
    return std.mem.order(u8, &code_hash, &insert.code_hash);
}

fn compareAddress(target: Address, address: Address) std.math.Order {
    return std.mem.order(u8, &target, &address);
}

fn compareStorageWrite(key: state.StorageKey, write: state.Changeset.StorageWrite) std.math.Order {
    const address_order = std.mem.order(u8, &key.address, &write.address);
    if (address_order != .eq) return address_order;
    return std.math.order(key.key, write.key);
}

fn compareStorageWriteAddress(target: Address, write: state.Changeset.StorageWrite) std.math.Order {
    return std.mem.order(u8, &target, &write.address);
}

fn containsAccountUpdate(changeset: *const state.Changeset, target: Address) bool {
    for (changeset.account_updates.items) |update| {
        if (std.mem.eql(u8, &update.address, &target)) return true;
    }
    return false;
}

fn containsStorageWrite(changeset: *const state.Changeset, target: Address) bool {
    for (changeset.storage_writes.items) |write| {
        if (std.mem.eql(u8, &write.address, &target)) return true;
    }
    return false;
}

/// Singular owned handoff from one isolated transaction lane.
///
/// `changeset` remains the compact state commit/root authority. `observations`
/// retains checkpoint-resolved reads, original/current values, code bytes, and
/// lifecycle facts for BAL reconstruction without inflating every committer.
pub const TransactionEffects = struct {
    allocator: std.mem.Allocator,
    result: vm.TxExecutionResult,
    logs: []Host.Log,
    changeset: state.Changeset,
    observations: bal_recorder.StateObservationDelta,

    /// Capture checkpoints close only when the execution lease is retained or
    /// discarded. Builder owns the already-detached execution values across
    /// that resolution, then seals the singular handoff with observations.
    pub const Builder = struct {
        allocator: std.mem.Allocator,
        result: vm.TxExecutionResult,
        logs: []Host.Log,
        changeset: state.Changeset,
        finished: bool = false,

        /// Copy one current execution lease into allocator-owned lane output.
        /// `executed` remains unresolved; the caller still chooses
        /// retain/discard before calling `finish`.
        pub fn init(executed: anytype) !Builder {
            const allocator = try executed.allocator();
            const view = try executed.view();

            const output = try allocator.dupe(u8, view.output.output);
            errdefer allocator.free(output);

            const logs = try cloneLogs(allocator, view.logs);
            errdefer deinitLogs(allocator, logs);

            var changeset = try executed.changeset();
            errdefer changeset.deinit(allocator);

            var result = view.output.*;
            result.output = output;
            return .{
                .allocator = allocator,
                .result = result,
                .logs = logs,
                .changeset = changeset,
            };
        }

        pub fn finish(
            self: *Builder,
            observations: bal_recorder.StateObservationDelta,
        ) TransactionEffects {
            std.debug.assert(!self.finished);
            self.finished = true;
            return .{
                .allocator = self.allocator,
                .result = self.result,
                .logs = self.logs,
                .changeset = self.changeset,
                .observations = observations,
            };
        }

        pub fn discardIfUnfinished(self: *Builder) void {
            if (!self.finished) {
                self.allocator.free(@constCast(self.result.output));
                deinitLogs(self.allocator, self.logs);
                self.changeset.deinit(self.allocator);
            }
            self.* = undefined;
        }
    };

    pub fn deinit(self: *TransactionEffects) void {
        self.allocator.free(@constCast(self.result.output));
        deinitLogs(self.allocator, self.logs);
        self.changeset.deinit(self.allocator);
        self.observations.deinit(self.allocator);
        self.* = undefined;
    }

    /// Attach the coordinator-owned transaction position to this index-free
    /// lane observation and produce an independently owned BAL shard.
    pub fn toOwnedBalShard(
        self: *const TransactionEffects,
        block_access_index: bal.BlockAccessIndex,
    ) !bal.Decoded {
        return self.observations.toOwnedBlockAccessList(self.allocator, block_access_index);
    }
};

pub fn cloneLogs(allocator: std.mem.Allocator, source: []const Host.Log) ![]Host.Log {
    const logs = try allocator.alloc(Host.Log, source.len);
    errdefer allocator.free(logs);

    var initialized: usize = 0;
    errdefer deinitLogItems(allocator, logs[0..initialized]);
    for (logs, source) |*target, event_log| {
        const topics = try allocator.dupe(u256, event_log.topics);
        errdefer allocator.free(topics);
        const data = try allocator.dupe(u8, event_log.data);
        target.* = .{
            .address = event_log.address,
            .topics = topics,
            .data = data,
        };
        initialized += 1;
    }
    return logs;
}

fn deinitLogs(allocator: std.mem.Allocator, logs: []Host.Log) void {
    deinitLogItems(allocator, logs);
    allocator.free(logs);
}

fn deinitLogItems(allocator: std.mem.Allocator, logs: []Host.Log) void {
    for (logs) |event_log| {
        allocator.free(@constCast(event_log.topics));
        allocator.free(@constCast(event_log.data));
    }
}

test "transaction effects survive mutation of executor-borrowed bytes" {
    const FakeExecuted = struct {
        result: vm.TxExecutionResult,
        logs: []const Host.Log,

        const View = struct {
            output: *const vm.TxExecutionResult,
            logs: []const Host.Log,
        };

        fn view(self: *const @This()) !View {
            return .{ .output = &self.result, .logs = self.logs };
        }

        fn allocator(_: @This()) !std.mem.Allocator {
            return std.testing.allocator;
        }

        fn changeset(_: @This()) !state.Changeset {
            return state.Changeset.init();
        }
    };

    var output = [_]u8{ 1, 2 };
    var topics = [_]u256{3};
    var data = [_]u8{4};
    var logs = [_]Host.Log{.{
        .address = [_]u8{5} ** 20,
        .topics = &topics,
        .data = &data,
    }};
    const executed = FakeExecuted{
        .result = .{ .status = .success, .output = &output },
        .logs = &logs,
    };

    var builder = try TransactionEffects.Builder.init(executed);
    defer builder.discardIfUnfinished();
    var effects = builder.finish(.{});
    defer effects.deinit();

    output[0] = 9;
    topics[0] = 10;
    data[0] = 11;
    try std.testing.expectEqualSlices(u8, &.{ 1, 2 }, effects.result.output);
    try std.testing.expectEqualSlices(u256, &.{3}, effects.logs[0].topics);
    try std.testing.expectEqualSlices(u8, &.{4}, effects.logs[0].data);
}

test "ordered changeset fold keeps latest writes in transaction order" {
    const allocator = std.testing.allocator;
    const account = [_]u8{1} ** 20;
    const code = [_]u8{ 0x60, 0x00 };
    const code_hash = crypto.keccak256(&code);

    var first = state.Changeset.init();
    defer first.deinit(allocator);
    try first.account_updates.append(allocator, .{
        .address = account,
        .nonce = 1,
        .balance = 2,
        .code_hash = code_hash,
    });
    try first.appendCodeInsert(allocator, code_hash, &code);
    try first.storage_writes.append(allocator, .{ .address = account, .key = 3, .value = 4 });

    var second = state.Changeset.init();
    defer second.deinit(allocator);
    try second.account_updates.append(allocator, .{
        .address = account,
        .nonce = 2,
        .balance = 5,
        .code_hash = code_hash,
    });
    try second.storage_writes.append(allocator, .{ .address = account, .key = 3, .value = 6 });
    try second.storage_writes.append(allocator, .{ .address = account, .key = 7, .value = 8 });

    var fold = OrderedChangesetFold.init(allocator);
    defer fold.deinit();
    try fold.append(0, &first);
    try fold.append(1, &second);
    try fold.finish();

    const merged = fold.view();
    try std.testing.expectEqual(@as(usize, 2), fold.transactionCount());
    try std.testing.expectEqual(@as(usize, 1), merged.account_updates.items.len);
    try std.testing.expectEqual(@as(u64, 2), merged.account_updates.items[0].nonce);
    try std.testing.expectEqual(@as(u256, 5), merged.account_updates.items[0].balance);
    try std.testing.expectEqual(@as(usize, 1), merged.code_inserts.items.len);
    try std.testing.expectEqualSlices(u8, &code, merged.codeBytes(merged.code_inserts.items[0]));
    try std.testing.expectEqual(@as(usize, 2), merged.storage_writes.items.len);
    try std.testing.expectEqual(@as(u256, 6), merged.storage_writes.items[0].value);
    try std.testing.expectEqual(@as(u256, 8), merged.storage_writes.items[1].value);

    var owned = fold.takeOwned();
    defer owned.deinit(allocator);
    try std.testing.expectEqual(OrderedChangesetFold.Lifecycle.taken, fold.lifecycle);
    try std.testing.expectEqualSlices(u8, &code, owned.codeBytes(owned.code_inserts.items[0]));
}

test "ordered changeset fold deletes prior writes and rejects recreation" {
    const allocator = std.testing.allocator;
    const account = [_]u8{2} ** 20;
    const code = [_]u8{0x00};
    const code_hash = crypto.keccak256(&code);

    var written = state.Changeset.init();
    defer written.deinit(allocator);
    try written.account_updates.append(allocator, .{
        .address = account,
        .nonce = 1,
        .balance = 2,
        .code_hash = code_hash,
    });
    try written.appendCodeInsert(allocator, code_hash, &code);
    try written.storage_writes.append(allocator, .{ .address = account, .key = 3, .value = 4 });

    var deleted = state.Changeset.init();
    defer deleted.deinit(allocator);
    try deleted.account_deletes.append(allocator, account);

    var recreated = state.Changeset.init();
    defer recreated.deinit(allocator);
    try recreated.account_updates.append(allocator, .{
        .address = account,
        .nonce = 1,
        .balance = 1,
        .code_hash = crypto.keccak256_empty,
    });

    var fold = OrderedChangesetFold.init(allocator);
    defer fold.deinit();
    try fold.append(0, &written);
    try fold.append(1, &deleted);
    try fold.finish();

    const merged = fold.view();
    try std.testing.expectEqual(@as(usize, 0), merged.account_updates.items.len);
    try std.testing.expectEqual(@as(usize, 0), merged.code_inserts.items.len);
    try std.testing.expectEqual(@as(usize, 1), merged.account_deletes.items.len);
    try std.testing.expectEqual(@as(usize, 0), merged.storage_writes.items.len);

    var recreation_fold = OrderedChangesetFold.init(allocator);
    defer recreation_fold.deinit();
    try recreation_fold.append(0, &written);
    try recreation_fold.append(1, &deleted);
    try std.testing.expectError(
        error.AccountRecreationUnsupported,
        recreation_fold.append(2, &recreated),
    );
    try std.testing.expectError(error.FoldFailed, recreation_fold.finish());
    try std.testing.expectError(error.FoldFailed, recreation_fold.append(2, &deleted));

    var out_of_order_fold = OrderedChangesetFold.init(allocator);
    defer out_of_order_fold.deinit();
    try std.testing.expectError(
        error.OutOfOrderTransaction,
        out_of_order_fold.append(1, &written),
    );
    try std.testing.expectError(error.FoldFailed, out_of_order_fold.finish());
}

test "ordered changeset fold compacts retained code ranges" {
    const allocator = std.testing.allocator;
    const first_account = [_]u8{0x11} ** 20;
    const third_account = [_]u8{0x33} ** 20;
    const first_code = [_]u8{0xa1};
    const dropped_code = [_]u8{ 0xb1, 0xb2 };
    const third_code = [_]u8{ 0xc1, 0xc2, 0xc3 };
    const first_hash = crypto.keccak256(&first_code);
    const dropped_hash = crypto.keccak256(&dropped_code);
    const third_hash = crypto.keccak256(&third_code);

    var lane = state.Changeset.init();
    defer lane.deinit(allocator);
    try lane.appendCodeInsert(allocator, first_hash, &first_code);
    try lane.appendCodeInsert(allocator, dropped_hash, &dropped_code);
    try lane.appendCodeInsert(allocator, third_hash, &third_code);
    try lane.account_updates.append(allocator, .{
        .address = first_account,
        .nonce = 1,
        .balance = 0,
        .code_hash = first_hash,
    });
    try lane.account_updates.append(allocator, .{
        .address = third_account,
        .nonce = 1,
        .balance = 0,
        .code_hash = third_hash,
    });

    var fold = OrderedChangesetFold.init(allocator);
    defer fold.deinit();
    try fold.append(0, &lane);
    try fold.finish();

    const merged = fold.view();
    try std.testing.expectEqual(@as(usize, 2), merged.code_inserts.items.len);
    try std.testing.expectEqualSlices(u8, &.{ 0xa1, 0xc1, 0xc2, 0xc3 }, merged.code_bytes.items);
    for (merged.code_inserts.items) |insert| {
        if (std.mem.eql(u8, &insert.code_hash, &first_hash)) {
            try std.testing.expectEqualSlices(u8, &first_code, merged.codeBytes(insert));
        } else if (std.mem.eql(u8, &insert.code_hash, &third_hash)) {
            try std.testing.expectEqualSlices(u8, &third_code, merged.codeBytes(insert));
        } else {
            return error.UnexpectedCodeInsert;
        }
    }
}

test "ordered changeset fold deduplicates equal code and rejects conflicting bytes" {
    const allocator = std.testing.allocator;
    const code_hash = [_]u8{0x42} ** 32;

    var first = state.Changeset.init();
    defer first.deinit(allocator);
    try first.appendCodeInsert(allocator, code_hash, &.{0x01});
    var equal = state.Changeset.init();
    defer equal.deinit(allocator);
    try equal.appendCodeInsert(allocator, code_hash, &.{0x01});
    var conflicting = state.Changeset.init();
    defer conflicting.deinit(allocator);
    try conflicting.appendCodeInsert(allocator, code_hash, &.{0x02});

    var deduplicated = OrderedChangesetFold.init(allocator);
    defer deduplicated.deinit();
    try deduplicated.append(0, &first);
    try deduplicated.append(1, &equal);
    try std.testing.expectEqual(@as(usize, 1), deduplicated.changeset.code_inserts.items.len);
    try std.testing.expectEqual(@as(usize, 1), deduplicated.changeset.code_bytes.items.len);

    var rejected = OrderedChangesetFold.init(allocator);
    defer rejected.deinit();
    try rejected.append(0, &first);
    try std.testing.expectError(error.ConflictingCodeInsert, rejected.append(1, &conflicting));
    try std.testing.expectError(error.FoldFailed, rejected.finish());
}

test "folded state reader matches a committed ordered changeset" {
    const allocator = std.testing.allocator;
    const updated = [_]u8{0x10} ** 20;
    const deleted = [_]u8{0x20} ** 20;
    const storage_created = [_]u8{0x30} ** 20;
    const untouched = [_]u8{0x40} ** 20;
    const absent = [_]u8{0x50} ** 20;
    const old_code = [_]u8{0x00};
    const new_code = [_]u8{ 0x60, 0x00 };
    const new_code_hash = crypto.keccak256(&new_code);

    var base = state.MemoryStore.init(allocator);
    defer base.deinit();
    {
        const account = try base.getOrCreateAccount(updated);
        account.nonce = 1;
        account.balance = 2;
        try account.setCode(&old_code);
        try account.storage.put(1, 11);
        try account.storage.put(2, 22);
    }
    {
        const account = try base.getOrCreateAccount(deleted);
        account.balance = 3;
        try account.storage.put(1, 44);
    }
    {
        const account = try base.getOrCreateAccount(untouched);
        account.balance = 5;
        try account.setCode(&old_code);
        try account.storage.put(9, 99);
    }

    var expected = try base.clone(allocator);
    defer expected.deinit();

    var lane = state.Changeset.init();
    defer lane.deinit(allocator);
    try lane.account_updates.append(allocator, .{
        .address = updated,
        .nonce = 7,
        .balance = 8,
        .code_hash = new_code_hash,
    });
    try lane.appendCodeInsert(allocator, new_code_hash, &new_code);
    try lane.account_deletes.append(allocator, deleted);
    try lane.storage_writes.append(allocator, .{ .address = updated, .key = 1, .value = 0 });
    try lane.storage_writes.append(allocator, .{ .address = updated, .key = 3, .value = 33 });
    // The changeset contract permits a nonzero storage write to materialize a
    // default account even when no account metadata update is required.
    try lane.storage_writes.append(allocator, .{ .address = storage_created, .key = 5, .value = 55 });

    var fold = OrderedChangesetFold.init(allocator);
    defer fold.deinit();
    try fold.append(0, &lane);
    try fold.finish();

    const projected_root = try base.stateRootAfterChangeset(allocator, fold.view());
    try expected.applyChangeset(fold.view());
    const committed_root = try expected.stateRoot(allocator);
    try std.testing.expectEqualSlices(u8, &committed_root, &projected_root);

    var folded_reader = fold.readerOver(base.reader());
    const projected = folded_reader.reader();
    const committed = expected.reader();
    const accounts = [_]Address{ updated, deleted, storage_created, untouched, absent };
    for (accounts) |account| {
        try std.testing.expectEqual(
            try committed.accountExists(account),
            try projected.accountExists(account),
        );
        try std.testing.expectEqual(
            try committed.loadAccount(account),
            try projected.loadAccount(account),
        );
        try std.testing.expectEqual(
            try committed.accountHasStorage(account),
            try projected.accountHasStorage(account),
        );
    }

    const storage_keys = [_]struct { address: Address, key: u256 }{
        .{ .address = updated, .key = 1 },
        .{ .address = updated, .key = 2 },
        .{ .address = updated, .key = 3 },
        .{ .address = deleted, .key = 1 },
        .{ .address = storage_created, .key = 5 },
        .{ .address = untouched, .key = 9 },
    };
    for (storage_keys) |key| {
        try std.testing.expectEqual(
            try committed.getStorage(key.address, key.key),
            try projected.getStorage(key.address, key.key),
        );
    }

    const projected_account = (try projected.loadAccount(updated)).?;
    try std.testing.expectEqualSlices(u8, &new_code, try projected.loadCode(projected_account.code_hash));
    try std.testing.expectEqualSlices(u8, &old_code, try projected.loadCode(crypto.keccak256(&old_code)));
}

test "folded state reader fails closed on ambiguous storage presence" {
    const allocator = std.testing.allocator;
    const cleared_nonzero = [_]u8{0x60} ** 20;
    const untouched_nonzero = [_]u8{0x70} ** 20;
    const empty = [_]u8{0x80} ** 20;
    const deleted = [_]u8{0x90} ** 20;

    var base = state.MemoryStore.init(allocator);
    defer base.deinit();
    {
        const account = try base.getOrCreateAccount(cleared_nonzero);
        try account.storage.put(1, 1);
        try account.storage.put(2, 2);
    }
    {
        const account = try base.getOrCreateAccount(untouched_nonzero);
        try account.storage.put(2, 2);
    }
    {
        const account = try base.getOrCreateAccount(deleted);
        try account.storage.put(1, 1);
    }

    var lane = state.Changeset.init();
    defer lane.deinit(allocator);
    try lane.storage_writes.append(allocator, .{ .address = cleared_nonzero, .key = 1, .value = 0 });
    try lane.storage_writes.append(allocator, .{ .address = untouched_nonzero, .key = 1, .value = 0 });
    try lane.storage_writes.append(allocator, .{ .address = empty, .key = 1, .value = 0 });
    try lane.account_deletes.append(allocator, deleted);

    var fold = OrderedChangesetFold.init(allocator);
    defer fold.deinit();
    try fold.append(0, &lane);
    try fold.finish();

    var folded_reader = fold.readerOver(base.reader());
    try std.testing.expectEqual(
        FoldedStateReader.StoragePresence.unknown,
        try folded_reader.storagePresence(cleared_nonzero),
    );
    try std.testing.expectEqual(
        FoldedStateReader.StoragePresence.nonempty,
        try folded_reader.storagePresence(untouched_nonzero),
    );
    try std.testing.expectEqual(
        FoldedStateReader.StoragePresence.empty,
        try folded_reader.storagePresence(empty),
    );
    try std.testing.expectEqual(
        FoldedStateReader.StoragePresence.empty,
        try folded_reader.storagePresence(deleted),
    );

    const projected = folded_reader.reader();
    try std.testing.expectEqual(@as(u256, 0), try projected.getStorage(cleared_nonzero, 1));
    try std.testing.expectEqual(@as(u256, 2), try projected.getStorage(cleared_nonzero, 2));
    try std.testing.expectError(
        error.FoldedStateStorageUnknown,
        projected.accountHasStorage(cleared_nonzero),
    );
    try std.testing.expectEqual(
        FoldedStateReader.StrategyFailure.storage_presence_unknown,
        folded_reader.strategy_failure.?,
    );
}
