//! Non-semantic resources that may be prepared before EVM execution.
//!
//! A plan describes external resources, not transaction validity, gas warmth,
//! or proof correctness. Preparation may populate database caches, fetch remote
//! data, or build disposable artifacts. Authoritative readers and artifact
//! owners still verify the values they return, and execution must remain
//! correct when preparation is absent or incomplete.

const Address = @import("./address.zig").Address;

/// One canonical storage path that execution may read.
pub const StorageSlot = struct {
    address: Address,
    key: u256,
};

/// Borrowed canonical state paths that may be loaded ahead of execution.
pub const StateReadDomain = struct {
    accounts: []const Address = &.{},
    storage_slots: []const StorageSlot = &.{},
};

/// Source-independent, borrowed description of resources useful for execution.
///
/// BAL is one possible producer. Witness manifests and schedulers may produce
/// or merge plans without changing executor semantics. Future resource kinds
/// belong here only when their identity can be expressed independently from a
/// particular database, proof format, decompressor, or compiler backend.
pub const Plan = struct {
    state: StateReadDomain = .{},
};

/// Caller-owned service for preparing the resources described by a `Plan`.
///
/// The slices in `Plan` are borrowed for the duration of `prepare`. A returned
/// error describes preparation availability only; it does not establish that
/// the block, transaction, witness, or prepared artifact is invalid. The
/// orchestration layer chooses whether to retry, fall back to lazy execution,
/// or surface an availability failure.
pub const Preparer = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        prepare: *const fn (ptr: *anyopaque, plan: Plan) anyerror!void,
    };

    pub fn prepare(self: Preparer, plan: Plan) !void {
        return self.vtable.prepare(self.ptr, plan);
    }
};

test "execution resource preparer receives a borrowed source-independent plan" {
    const address = @import("./address.zig");
    const Probe = struct {
        account: Address = [_]u8{0} ** 20,
        slot: StorageSlot = .{ .address = [_]u8{0} ** 20, .key = 0 },

        fn prepare(ptr: *anyopaque, plan: Plan) !void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.account = plan.state.accounts[0];
            self.slot = plan.state.storage_slots[0];
        }
    };

    var probe = Probe{};
    const preparer = Preparer{ .ptr = &probe, .vtable = &.{
        .prepare = Probe.prepare,
    } };
    try preparer.prepare(.{ .state = .{
        .accounts = &.{address.addr(1)},
        .storage_slots = &.{.{ .address = address.addr(2), .key = 3 }},
    } });

    try @import("std").testing.expectEqual(address.addr(1), probe.account);
    try @import("std").testing.expectEqualDeep(
        StorageSlot{ .address = address.addr(2), .key = 3 },
        probe.slot,
    );
}
