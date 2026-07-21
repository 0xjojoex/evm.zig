//! BAL-derived execution-resource planning and state-path probing.
//!
//! This walks the same merged account/storage domain as `ClaimView.readSet`.
//! BAL supplies the plan; caller-owned preparation services decide how to
//! hydrate it. State probing remains separate and authoritative. Neither path
//! alters EVM transaction warmth or gas accounting. EIP-7928 does not
//! enumerate every pre-state code body execution may load, so a successful
//! state probe does not prove full witness completeness.

const std = @import("std");

const address = @import("../../address.zig");
const bal = @import("model.zig");
const bal_view = @import("ClaimView.zig");
const crypto = @import("../../crypto.zig");
const execution_resources = @import("../../execution_resources.zig");
const state = @import("../../state.zig");

const Allocator = std.mem.Allocator;
const Address = address.Address;

/// Caller-owned materialization of the execution-resource plan derived from a
/// shape-validated BAL. `resources` borrows the allocations owned here.
pub const OwnedPlan = struct {
    resources: execution_resources.Plan,

    pub fn deinit(self: *OwnedPlan, allocator: Allocator) void {
        if (self.resources.state.accounts.len != 0) allocator.free(self.resources.state.accounts);
        if (self.resources.state.storage_slots.len != 0) allocator.free(self.resources.state.storage_slots);
        self.* = undefined;
    }
};

/// Materialize the source-neutral merged state domain of a shape-validated
/// BAL. This does not fetch or verify any resource.
pub fn planAllocAssumeValidated(
    allocator: Allocator,
    block_access_list: bal.BlockAccessList,
) Allocator.Error!OwnedPlan {
    const counts = bal.count(block_access_list);

    var accounts: []Address = &.{};
    if (counts.accounts != 0) accounts = try allocator.alloc(Address, counts.accounts);
    errdefer if (accounts.len != 0) allocator.free(accounts);

    const storage_count = counts.storage_read_keys + counts.storage_write_keys;
    var storage_slots: []execution_resources.StorageSlot = &.{};
    if (storage_count != 0) storage_slots = try allocator.alloc(execution_resources.StorageSlot, storage_count);
    errdefer if (storage_slots.len != 0) allocator.free(storage_slots);

    var account_index: usize = 0;
    var storage_index: usize = 0;
    var read_set = bal_view.readSetAssumeValidated(block_access_list);
    while (read_set.next()) |entry| switch (entry) {
        .account => |account_address| {
            accounts[account_index] = account_address;
            account_index += 1;
        },
        .storage => |storage| {
            storage_slots[storage_index] = .{ .address = storage.address, .key = storage.slot };
            storage_index += 1;
        },
    };
    std.debug.assert(account_index == accounts.len);
    std.debug.assert(storage_index == storage_slots.len);

    return .{ .resources = .{ .state = .{
        .accounts = accounts,
        .storage_slots = storage_slots,
    } } };
}

/// Synchronously prove that the canonical reader can serve every BAL-declared
/// account/storage path. Preparation success is not consulted here.
pub fn probeState(reader: state.Reader, domain: execution_resources.StateReadDomain) !void {
    for (domain.accounts) |account_address| _ = try reader.loadAccount(account_address);
    for (domain.storage_slots) |slot| _ = try reader.getStorage(slot.address, slot.key);
}

const ProbeReader = struct {
    loaded_accounts: [2]Address = undefined,
    loaded_account_count: usize = 0,
    loaded_slots: [3]execution_resources.StorageSlot = undefined,
    loaded_slot_count: usize = 0,
    fail_account: ?Address = null,

    fn reader(self: *ProbeReader) state.Reader {
        return .{ .ptr = self, .vtable = &.{
            .accountExists = accountExists,
            .loadAccount = loadAccount,
            .loadCode = loadCode,
            .getStorage = getStorage,
            .accountHasStorage = accountHasStorage,
        } };
    }

    fn context(ptr: *anyopaque) *ProbeReader {
        return @ptrCast(@alignCast(ptr));
    }

    fn accountExists(ptr: *anyopaque, account_address: Address) !bool {
        _ = ptr;
        _ = account_address;
        return false;
    }

    fn loadAccount(ptr: *anyopaque, account_address: Address) !?state.Account {
        const self = context(ptr);
        if (self.fail_account) |failed| {
            if (std.mem.eql(u8, &failed, &account_address)) return error.InvalidWitness;
        }
        self.loaded_accounts[self.loaded_account_count] = account_address;
        self.loaded_account_count += 1;
        return null;
    }

    fn loadCode(ptr: *anyopaque, code_hash: [32]u8) ![]const u8 {
        _ = ptr;
        if (std.mem.eql(u8, &code_hash, &crypto.keccak256_empty)) return &.{};
        return error.CodeUnavailable;
    }

    fn getStorage(ptr: *anyopaque, account_address: Address, key: u256) !u256 {
        const self = context(ptr);
        self.loaded_slots[self.loaded_slot_count] = .{ .address = account_address, .key = key };
        self.loaded_slot_count += 1;
        return 0;
    }

    fn accountHasStorage(ptr: *anyopaque, account_address: Address) !bool {
        _ = ptr;
        _ = account_address;
        return false;
    }
};

test "BAL supplies a source-neutral plan that the state reader can probe" {
    const first = address.addr(1);
    const second = address.addr(2);
    const changes = [_]bal.StorageChange{.{ .block_access_index = 1, .new_value = 9 }};
    const changed_slots = [_]bal.SlotChanges{
        .{ .slot = 1, .changes = &changes },
        .{ .slot = 5, .changes = &changes },
    };
    const claim = [_]bal.AccountChanges{
        .{
            .address = first,
            .storage_changes = &changed_slots,
            .storage_reads = &.{3},
        },
        .{ .address = second },
    };

    var probe = ProbeReader{};
    var owned_plan = try planAllocAssumeValidated(std.testing.allocator, &claim);
    defer owned_plan.deinit(std.testing.allocator);
    try probeState(probe.reader(), owned_plan.resources.state);

    try std.testing.expectEqualSlices(Address, &.{ first, second }, owned_plan.resources.state.accounts);
    const expected_slots = [_]execution_resources.StorageSlot{
        .{ .address = first, .key = 1 },
        .{ .address = first, .key = 3 },
        .{ .address = first, .key = 5 },
    };
    try std.testing.expectEqualDeep(expected_slots[0..], owned_plan.resources.state.storage_slots);
    try std.testing.expectEqualSlices(Address, &.{ first, second }, probe.loaded_accounts[0..2]);
    try std.testing.expectEqualDeep(
        owned_plan.resources.state.storage_slots,
        probe.loaded_slots[0..probe.loaded_slot_count],
    );
}

test "BAL witness precheck fails before execution when a state path is unavailable" {
    const target = address.addr(3);
    const claim = [_]bal.AccountChanges{.{ .address = target }};
    var probe = ProbeReader{ .fail_account = target };
    var owned_plan = try planAllocAssumeValidated(std.testing.allocator, &claim);
    defer owned_plan.deinit(std.testing.allocator);

    try std.testing.expectError(
        error.InvalidWitness,
        probeState(probe.reader(), owned_plan.resources.state),
    );
    try std.testing.expectEqual(@as(usize, 0), probe.loaded_slot_count);
}
