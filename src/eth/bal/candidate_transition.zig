//! Owned lane transitions and their ordered candidate-state fold.
//!
//! One isolated executor produces one `LaneTransition` from its sealed
//! `ObservationsView`. BAL projection and post-state reconstruction consume
//! that same artifact. The fold stores field-level effects over an authenticated
//! base reader; it is not a committer batch and never materializes full account
//! leaves merely to preserve executor lifetime.

const std = @import("std");

const Address = @import("../../address.zig").Address;
const Host = @import("../../Host.zig");
const crypto = @import("../../crypto.zig");
const observation = @import("observation.zig");
const state = @import("../../state.zig");
const tracked_state_projector = @import("tracked_state_projector.zig");
const vm = @import("../../vm.zig");

const StorageKey = state.StorageKey;

pub const AccountDelta = struct {
    address: Address,
    reset: bool = false,
    deleted: bool = false,
    storage_wiped: bool = false,
    balance: ?u256 = null,
    nonce: ?u64 = null,
    code_hash: ?[32]u8 = null,

    fn changesAccount(self: AccountDelta) bool {
        return self.reset or self.deleted or
            self.balance != null or self.nonce != null or self.code_hash != null;
    }
};

pub const StorageDelta = struct {
    address: Address,
    key: u256,
    value: u256,
    active: bool = true,
};

pub const CodeBlob = struct {
    hash: [32]u8,
    offset: u32,
    len: u32,
};

/// Final field-level candidate state relative to one authenticated base.
pub const CandidateState = struct {
    accounts: std.ArrayList(AccountDelta) = .empty,
    storage: std.ArrayList(StorageDelta) = .empty,
    code_blobs: std.ArrayList(CodeBlob) = .empty,
    code_bytes: std.ArrayList(u8) = .empty,

    pub fn init() CandidateState {
        return .{};
    }

    pub fn deinit(self: *CandidateState, allocator: std.mem.Allocator) void {
        self.accounts.deinit(allocator);
        self.storage.deinit(allocator);
        self.code_blobs.deinit(allocator);
        self.code_bytes.deinit(allocator);
        self.* = .{};
    }

    pub fn readerOver(self: *const CandidateState, base: state.Reader) FoldedStateReader {
        return FoldedStateReader.initAssumeCanonical(base, self);
    }

    pub fn matchesChanges(
        self: *const CandidateState,
        base: state.Reader,
        changes: state.TrackedState.ChangesView,
    ) !bool {
        var account_change_count: u32 = 0;
        for (self.accounts.items) |delta| {
            if (delta.changesAccount()) account_change_count += 1;
        }
        if (account_change_count != changes.accounts.len()) return false;

        var reader = self.readerOver(base);
        const projected = reader.reader();
        var account_index: u32 = 0;
        while (account_index < changes.accounts.len()) : (account_index += 1) {
            const expected = changes.accounts.at(account_index);
            const delta = self.account(expected.address) orelse return false;
            if (!delta.changesAccount()) return false;
            const actual = try projected.loadAccount(expected.address);
            if (!std.meta.eql(expected.account, actual)) return false;
            if (expected.account) |account_value| {
                if (changes.introducedCode(account_value.code_hash)) |code| {
                    if (!std.mem.eql(u8, code.bytes, try projected.loadCode(account_value.code_hash)))
                        return false;
                }
            }
        }

        if (self.storage.items.len != changes.storage_writes.len()) return false;
        var storage_index: u32 = 0;
        while (storage_index < changes.storage_writes.len()) : (storage_index += 1) {
            const expected = changes.storage_writes.at(storage_index);
            const actual = self.storageWrite(.{
                .address = expected.address,
                .key = expected.key,
            }) orelse return false;
            if (actual.value != expected.value) return false;
        }

        var wipe_count: u32 = 0;
        for (self.accounts.items) |delta| {
            if (delta.storage_wiped) wipe_count += 1;
        }
        if (wipe_count != changes.storage_wipes.len()) return false;
        var wipe_index: u32 = 0;
        while (wipe_index < changes.storage_wipes.len()) : (wipe_index += 1) {
            const delta = self.account(changes.storage_wipes.at(wipe_index)) orelse
                return false;
            if (!delta.storage_wiped) return false;
        }
        return true;
    }

    pub fn codeBytes(self: *const CandidateState, blob: CodeBlob) []const u8 {
        const offset: usize = blob.offset;
        const len: usize = blob.len;
        std.debug.assert(offset <= self.code_bytes.items.len);
        std.debug.assert(len <= self.code_bytes.items.len - offset);
        return self.code_bytes.items[offset..][0..len];
    }

    fn account(self: *const CandidateState, target: Address) ?*const AccountDelta {
        const index = std.sort.binarySearch(
            AccountDelta,
            self.accounts.items,
            target,
            compareAccount,
        ) orelse return null;
        return &self.accounts.items[index];
    }

    fn codeBlob(self: *const CandidateState, hash: [32]u8) ?*const CodeBlob {
        const index = std.sort.binarySearch(
            CodeBlob,
            self.code_blobs.items,
            hash,
            compareCodeBlob,
        ) orelse return null;
        return &self.code_blobs.items[index];
    }

    fn storageWrite(self: *const CandidateState, key: StorageKey) ?*const StorageDelta {
        const index = std.sort.binarySearch(
            StorageDelta,
            self.storage.items,
            key,
            compareStorage,
        ) orelse return null;
        return &self.storage.items[index];
    }

    fn storageWrites(self: *const CandidateState, target: Address) []const StorageDelta {
        const start = std.sort.lowerBound(
            StorageDelta,
            self.storage.items,
            target,
            compareStorageAddress,
        );
        const end = std.sort.upperBound(
            StorageDelta,
            self.storage.items,
            target,
            compareStorageAddress,
        );
        return self.storage.items[start..end];
    }
};

/// Transaction-ordered fold over owned lane transitions.
pub const OrderedTransitionFold = struct {
    const Lifecycle = enum {
        building,
        failed,
        finished,
        taken,
    };

    pub const Error = std.mem.Allocator.Error || error{
        CodeHashMismatch,
        ConflictingCode,
        CandidateIndexOverflow,
        FoldAlreadyFinished,
        FoldFailed,
        OutOfOrderTransaction,
    };

    allocator: std.mem.Allocator,
    state: CandidateState = .{},
    account_indices: std.AutoHashMap(Address, usize),
    storage_indices: std.AutoHashMap(StorageKey, usize),
    code_indices: std.AutoHashMap([32]u8, usize),
    next_transaction_index: usize = 0,
    lifecycle: Lifecycle = .building,

    pub fn init(allocator: std.mem.Allocator) OrderedTransitionFold {
        return .{
            .allocator = allocator,
            .account_indices = .init(allocator),
            .storage_indices = .init(allocator),
            .code_indices = .init(allocator),
        };
    }

    pub fn deinit(self: *OrderedTransitionFold) void {
        self.state.deinit(self.allocator);
        self.account_indices.deinit();
        self.storage_indices.deinit();
        self.code_indices.deinit();
        self.* = undefined;
    }

    pub fn append(
        self: *OrderedTransitionFold,
        transaction_index: usize,
        transition: *const observation.LaneTransition,
    ) Error!void {
        if (transaction_index != self.next_transaction_index)
            return self.fail(error.OutOfOrderTransaction);
        try self.appendTransition(transition);
        self.next_transaction_index += 1;
    }

    pub fn appendNext(
        self: *OrderedTransitionFold,
        transition: *const observation.LaneTransition,
    ) Error!void {
        try self.append(self.next_transaction_index, transition);
    }

    pub fn appendState(self: *OrderedTransitionFold, source: *const CandidateState) Error!void {
        try self.requireBuilding();
        self.appendStateFallible(source) catch |err| return self.fail(err);
    }

    pub fn finish(self: *OrderedTransitionFold) Error!void {
        try self.requireBuilding();
        self.compactStorage();
        std.mem.sort(AccountDelta, self.state.accounts.items, {}, accountLessThan);
        std.mem.sort(StorageDelta, self.state.storage.items, {}, storageLessThan);
        std.mem.sort(CodeBlob, self.state.code_blobs.items, {}, codeBlobLessThan);
        self.lifecycle = .finished;
    }

    pub fn view(self: *const OrderedTransitionFold) *const CandidateState {
        std.debug.assert(self.lifecycle == .finished);
        return &self.state;
    }

    pub fn takeOwned(self: *OrderedTransitionFold) CandidateState {
        std.debug.assert(self.lifecycle == .finished);
        const owned = self.state;
        self.state = .{};
        self.lifecycle = .taken;
        return owned;
    }

    pub fn transactionCount(self: *const OrderedTransitionFold) usize {
        return self.next_transaction_index;
    }

    pub fn readerOver(self: *const OrderedTransitionFold, base: state.Reader) FoldedStateReader {
        return self.view().readerOver(base);
    }

    fn appendTransition(
        self: *OrderedTransitionFold,
        transition: *const observation.LaneTransition,
    ) Error!void {
        try self.requireBuilding();
        self.appendTransitionFallible(transition) catch |err| return self.fail(err);
    }

    fn appendTransitionFallible(
        self: *OrderedTransitionFold,
        transition: *const observation.LaneTransition,
    ) Error!void {
        for (transition.accounts) |account| {
            if (account.account_reset) try self.resetAccount(account.address);
            if (account.storage_wiped) try self.wipeStorage(account.address);

            if (account.balance) |balance| {
                const target = try self.mutableAccount(account.address);
                self.revive(target);
                target.balance = balance.current;
            }
            if (account.nonce) |nonce| {
                const target = try self.mutableAccount(account.address);
                self.revive(target);
                target.nonce = nonce.current;
            }
            if (account.code) |code| {
                try self.mergeCode(account.address, code.current_hash, code.current_code);
            }

            if (!account.account_deleted and !account.storage_wiped) {
                for (account.storage) |storage| {
                    if (storage.written)
                        try self.mergeStorage(account.address, storage.slot, storage.current);
                }
            }
            if (account.account_deleted) try self.deleteAccount(account.address);
        }
    }

    fn appendStateFallible(self: *OrderedTransitionFold, source: *const CandidateState) Error!void {
        for (source.accounts.items) |account| {
            if (account.reset) try self.resetAccount(account.address);
            if (account.storage_wiped) try self.wipeStorage(account.address);
            if (account.balance) |balance| {
                const target = try self.mutableAccount(account.address);
                self.revive(target);
                target.balance = balance;
            }
            if (account.nonce) |nonce| {
                const target = try self.mutableAccount(account.address);
                self.revive(target);
                target.nonce = nonce;
            }
            if (account.code_hash) |hash| {
                const bytes = if (std.mem.eql(u8, &hash, &crypto.keccak256_empty))
                    &.{}
                else blk: {
                    const blob = source.codeBlob(hash) orelse
                        return error.CodeHashMismatch;
                    break :blk source.codeBytes(blob.*);
                };
                try self.mergeCode(account.address, hash, bytes);
            }
            if (account.deleted) try self.deleteAccount(account.address);
        }
        for (source.storage.items) |storage| {
            try self.mergeStorage(storage.address, storage.key, storage.value);
        }
    }

    fn mutableAccount(self: *OrderedTransitionFold, address: Address) Error!*AccountDelta {
        if (self.account_indices.get(address)) |index|
            return &self.state.accounts.items[index];
        const index = self.state.accounts.items.len;
        try self.state.accounts.append(self.allocator, .{ .address = address });
        errdefer _ = self.state.accounts.pop();
        try self.account_indices.put(address, index);
        return &self.state.accounts.items[index];
    }

    fn resetAccount(self: *OrderedTransitionFold, address: Address) Error!void {
        const account = try self.mutableAccount(address);
        account.reset = true;
        account.deleted = false;
        account.balance = null;
        account.nonce = null;
        account.code_hash = null;
        self.clearStorage(address);
    }

    fn deleteAccount(self: *OrderedTransitionFold, address: Address) Error!void {
        const account = try self.mutableAccount(address);
        account.reset = true;
        account.deleted = true;
        account.balance = null;
        account.nonce = null;
        account.code_hash = null;
        self.clearStorage(address);
    }

    fn wipeStorage(self: *OrderedTransitionFold, address: Address) Error!void {
        const account = try self.mutableAccount(address);
        account.storage_wiped = true;
        self.clearStorage(address);
    }

    fn clearStorage(self: *OrderedTransitionFold, address: Address) void {
        for (self.state.storage.items) |*storage| {
            if (!storage.active or !std.mem.eql(u8, &storage.address, &address)) continue;
            storage.active = false;
            _ = self.storage_indices.remove(.{
                .address = storage.address,
                .key = storage.key,
            });
        }
    }

    fn revive(_: *OrderedTransitionFold, account: *AccountDelta) void {
        if (!account.deleted) return;
        account.reset = true;
        account.deleted = false;
        account.balance = null;
        account.nonce = null;
        account.code_hash = null;
    }

    fn mergeStorage(
        self: *OrderedTransitionFold,
        address: Address,
        key: u256,
        value: u256,
    ) Error!void {
        const account = try self.mutableAccount(address);
        if (account.deleted) {
            if (value == 0) return;
            self.revive(account);
        }
        const storage_key = StorageKey{ .address = address, .key = key };
        if (self.storage_indices.get(storage_key)) |index| {
            self.state.storage.items[index].value = value;
            return;
        }
        const index = self.state.storage.items.len;
        try self.state.storage.append(self.allocator, .{
            .address = address,
            .key = key,
            .value = value,
        });
        errdefer _ = self.state.storage.pop();
        try self.storage_indices.put(storage_key, index);
    }

    fn mergeCode(
        self: *OrderedTransitionFold,
        address: Address,
        hash: [32]u8,
        bytes: []const u8,
    ) Error!void {
        if (!std.mem.eql(u8, &crypto.keccak256(bytes), &hash))
            return error.CodeHashMismatch;
        if (!std.mem.eql(u8, &hash, &crypto.keccak256_empty)) {
            if (self.code_indices.get(hash)) |index| {
                if (!std.mem.eql(u8, self.state.codeBytes(self.state.code_blobs.items[index]), bytes))
                    return error.ConflictingCode;
            } else {
                const offset = std.math.cast(u32, self.state.code_bytes.items.len) orelse
                    return error.CandidateIndexOverflow;
                const len = std.math.cast(u32, bytes.len) orelse
                    return error.CandidateIndexOverflow;
                _ = std.math.add(u32, offset, len) catch
                    return error.CandidateIndexOverflow;
                try self.state.code_blobs.ensureUnusedCapacity(self.allocator, 1);
                try self.state.code_bytes.ensureUnusedCapacity(self.allocator, bytes.len);
                try self.code_indices.ensureUnusedCapacity(1);
                self.state.code_bytes.appendSliceAssumeCapacity(bytes);
                const index = self.state.code_blobs.items.len;
                self.state.code_blobs.appendAssumeCapacity(.{
                    .hash = hash,
                    .offset = offset,
                    .len = len,
                });
                self.code_indices.putAssumeCapacity(hash, index);
            }
        }
        const account = try self.mutableAccount(address);
        self.revive(account);
        account.code_hash = hash;
    }

    fn compactStorage(self: *OrderedTransitionFold) void {
        var write_index: usize = 0;
        for (self.state.storage.items) |storage| {
            if (!storage.active) continue;
            self.state.storage.items[write_index] = storage;
            write_index += 1;
        }
        self.state.storage.items.len = write_index;
    }

    fn requireBuilding(self: *const OrderedTransitionFold) Error!void {
        return switch (self.lifecycle) {
            .building => {},
            .failed => error.FoldFailed,
            .finished, .taken => error.FoldAlreadyFinished,
        };
    }

    fn fail(self: *OrderedTransitionFold, err: Error) Error {
        self.lifecycle = .failed;
        return err;
    }
};

/// Read-only candidate post-state layered over an authenticated base.
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
    candidate: *const CandidateState,
    strategy_failure: ?StrategyFailure = null,

    pub fn initAssumeCanonical(base: state.Reader, candidate: *const CandidateState) FoldedStateReader {
        return .{ .base = base, .candidate = candidate };
    }

    pub fn reader(self: *FoldedStateReader) state.Reader {
        return .{ .ptr = self, .vtable = &vtable };
    }

    pub fn storagePresence(self: *FoldedStateReader, target: Address) !StoragePresence {
        const account = self.candidate.account(target);
        if (account) |delta| {
            if (delta.deleted) return .empty;
        }

        const writes = self.candidate.storageWrites(target);
        for (writes) |write| {
            if (write.value != 0) return .nonempty;
        }
        if (account) |delta| {
            if (delta.reset or delta.storage_wiped) return .empty;
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
        return (try loadAccount(ptr, target)) != null;
    }

    fn loadAccount(ptr: *anyopaque, target: Address) !?state.Account {
        const self = context(ptr);
        const delta = self.candidate.account(target) orelse
            return self.base.loadAccount(target);
        if (delta.deleted) return null;

        const has_nonzero_storage = for (self.candidate.storageWrites(target)) |write| {
            if (write.value != 0) break true;
        } else false;
        if (!delta.changesAccount() and !has_nonzero_storage)
            return self.base.loadAccount(target);

        var account = if (delta.reset)
            state.Account{}
        else
            (try self.base.loadAccount(target)) orelse state.Account{};
        if (delta.balance) |balance| account.balance = balance;
        if (delta.nonce) |nonce| account.nonce = nonce;
        if (delta.code_hash) |hash| account.code_hash = hash;
        return account;
    }

    fn loadCode(ptr: *anyopaque, code_hash: [32]u8) ![]const u8 {
        const self = context(ptr);
        if (std.mem.eql(u8, &code_hash, &crypto.keccak256_empty)) return &.{};
        if (self.candidate.codeBlob(code_hash)) |blob|
            return self.candidate.codeBytes(blob.*);
        return self.base.vtable.loadCode(self.base.ptr, code_hash);
    }

    fn getStorage(ptr: *anyopaque, target: Address, key: u256) !u256 {
        const self = context(ptr);
        if (self.candidate.account(target)) |account| {
            if (account.deleted) return 0;
        }
        if (self.candidate.storageWrite(.{ .address = target, .key = key })) |write|
            return write.value;
        if (self.candidate.account(target)) |account| {
            if (account.reset or account.storage_wiped) return 0;
        }
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
};

/// Singular owned handoff from one isolated transaction lane.
pub const TransactionEffects = struct {
    allocator: std.mem.Allocator,
    result: vm.TxExecutionResult,
    logs: []Host.Log,
    transition: observation.LaneTransition,

    pub const Builder = struct {
        allocator: std.mem.Allocator,
        result: vm.TxExecutionResult,
        logs: []Host.Log,
        transition: observation.LaneTransition,
        finished: bool = false,

        /// Take ownership of `transition` and detach the remaining borrowed
        /// execution outputs before the pending transaction resolves.
        pub fn init(executed: anytype, transition: observation.LaneTransition) !Builder {
            const allocator = executed.allocator();
            var owned_transition = transition;
            errdefer owned_transition.deinit(allocator);
            const view = executed.view();

            const output = try allocator.dupe(u8, view.output.output);
            errdefer allocator.free(output);
            const logs = try cloneLogs(allocator, view.logs);
            errdefer deinitLogs(allocator, logs);

            var result = view.output.*;
            result.output = output;
            return .{
                .allocator = allocator,
                .result = result,
                .logs = logs,
                .transition = owned_transition,
            };
        }

        pub fn finish(self: *Builder) TransactionEffects {
            std.debug.assert(!self.finished);
            self.finished = true;
            return .{
                .allocator = self.allocator,
                .result = self.result,
                .logs = self.logs,
                .transition = self.transition,
            };
        }

        pub fn discardIfUnfinished(self: *Builder) void {
            if (!self.finished) {
                self.allocator.free(@constCast(self.result.output));
                deinitLogs(self.allocator, self.logs);
                self.transition.deinit(self.allocator);
            }
            self.* = undefined;
        }
    };

    pub fn deinit(self: *TransactionEffects) void {
        self.allocator.free(@constCast(self.result.output));
        deinitLogs(self.allocator, self.logs);
        self.transition.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn toOwnedBalShard(
        self: *const TransactionEffects,
        block_access_index: @import("model.zig").BlockAccessIndex,
    ) !@import("model.zig").Decoded {
        return self.transition.toOwnedBlockAccessList(
            self.allocator,
            block_access_index,
        );
    }
};

pub fn cloneLogs(allocator: std.mem.Allocator, source: state.TrackedState.LogView) ![]Host.Log {
    const logs = try allocator.alloc(Host.Log, source.len());
    errdefer allocator.free(logs);

    var initialized: usize = 0;
    errdefer deinitLogItems(allocator, logs[0..initialized]);
    for (logs, 0..) |*target, index| {
        const event_log = source.get(index);
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

fn compareAccount(target: Address, account: AccountDelta) std.math.Order {
    return std.mem.order(u8, &target, &account.address);
}

fn compareCodeBlob(hash: [32]u8, blob: CodeBlob) std.math.Order {
    return std.mem.order(u8, &hash, &blob.hash);
}

fn compareStorage(key: StorageKey, storage: StorageDelta) std.math.Order {
    const address_order = std.mem.order(u8, &key.address, &storage.address);
    if (address_order != .eq) return address_order;
    return std.math.order(key.key, storage.key);
}

fn compareStorageAddress(target: Address, storage: StorageDelta) std.math.Order {
    return std.mem.order(u8, &target, &storage.address);
}

fn accountLessThan(_: void, lhs: AccountDelta, rhs: AccountDelta) bool {
    return std.mem.order(u8, &lhs.address, &rhs.address) == .lt;
}

fn storageLessThan(_: void, lhs: StorageDelta, rhs: StorageDelta) bool {
    const address_order = std.mem.order(u8, &lhs.address, &rhs.address);
    if (address_order != .eq) return address_order == .lt;
    return lhs.key < rhs.key;
}

fn codeBlobLessThan(_: void, lhs: CodeBlob, rhs: CodeBlob) bool {
    return std.mem.order(u8, &lhs.hash, &rhs.hash) == .lt;
}

test "one lane transition drives BAL and candidate state" {
    const addr = @import("../../address.zig").addr;
    var tracked = state.TrackedState.init(std.testing.allocator);
    defer tracked.deinit();

    const attempt = tracked.beginObservedTransaction();
    tracked.beginScope();
    try tracked.setBalance(addr(1), 7);
    try tracked.setNonce(addr(1), 3);
    try tracked.setCode(addr(1), &.{ 0x60, 0x00 });
    _ = try tracked.setStorage(addr(1), 2, 9);
    tracked.closeScope();
    tracked.seal(attempt);

    var transition = try tracked_state_projector.materialize(
        tracked.pendingView().observations(),
        std.testing.allocator,
    );
    defer transition.deinit(std.testing.allocator);

    var shard = try transition.toOwnedBlockAccessList(std.testing.allocator, 1);
    defer shard.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), shard.accounts.len);

    var fold = OrderedTransitionFold.init(std.testing.allocator);
    defer fold.deinit();
    try fold.append(0, &transition);
    try fold.finish();

    var reader = fold.readerOver(state.Reader.empty());
    const projected = reader.reader();
    try std.testing.expectEqual(
        state.Account{
            .nonce = 3,
            .balance = 7,
            .code_hash = crypto.keccak256(&.{ 0x60, 0x00 }),
        },
        (try projected.loadAccount(addr(1))).?,
    );
    try std.testing.expectEqual(@as(u256, 9), try projected.getStorage(addr(1), 2));
}

test "candidate fold handles wipe delete and recreation" {
    const addr = @import("../../address.zig").addr;
    const target = addr(1);
    var first_accounts = [_]observation.AccountObservation{.{
        .address = target,
        .balance = .{ .original = 1, .current = 2 },
        .storage = &.{.{
            .slot = 1,
            .original = 1,
            .current = 3,
            .written = true,
        }},
    }};
    const first = observation.LaneTransition{ .accounts = &first_accounts };
    var deleted_accounts = [_]observation.AccountObservation{.{
        .address = target,
        .account_deleted = true,
        .storage_wiped = true,
    }};
    const deleted = observation.LaneTransition{ .accounts = &deleted_accounts };
    var recreated_accounts = [_]observation.AccountObservation{.{
        .address = target,
        .account_reset = true,
        .balance = .{ .original = 0, .current = 5 },
        .storage = &.{.{
            .slot = 2,
            .original = 0,
            .current = 7,
            .written = true,
        }},
    }};
    const recreated = observation.LaneTransition{ .accounts = &recreated_accounts };

    var fold = OrderedTransitionFold.init(std.testing.allocator);
    defer fold.deinit();
    try fold.append(0, &first);
    try fold.append(1, &deleted);
    try fold.append(2, &recreated);
    try fold.finish();

    var reader = fold.readerOver(state.Reader.empty());
    const projected = reader.reader();
    try std.testing.expectEqual(@as(u256, 5), (try projected.loadAccount(target)).?.balance);
    try std.testing.expectEqual(@as(u256, 0), try projected.getStorage(target, 1));
    try std.testing.expectEqual(@as(u256, 7), try projected.getStorage(target, 2));
    try std.testing.expect(try projected.accountHasStorage(target));
}

test "candidate state composition preserves empty code without a blob" {
    const addr = @import("../../address.zig").addr;
    const target = addr(1);
    var accounts = [_]observation.AccountObservation{.{
        .address = target,
        .code = .{
            .original_hash = crypto.keccak256(&.{0x00}),
            .current_hash = crypto.keccak256_empty,
            .current_code = &.{},
        },
    }};
    const transition = observation.LaneTransition{ .accounts = &accounts };

    var source_fold = OrderedTransitionFold.init(std.testing.allocator);
    defer source_fold.deinit();
    try source_fold.append(0, &transition);
    try source_fold.finish();

    var combined = OrderedTransitionFold.init(std.testing.allocator);
    defer combined.deinit();
    try combined.appendState(source_fold.view());
    try combined.finish();

    var reader = combined.readerOver(state.Reader.empty());
    try std.testing.expectEqual(
        crypto.keccak256_empty,
        (try reader.reader().loadAccount(target)).?.code_hash,
    );
}
