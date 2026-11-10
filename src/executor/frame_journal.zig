//! EIP-8141 frame journal: the transaction-scoped context of one frame
//! transaction, rolled back with the state it belongs to.
//!
//! It holds the approval context (`payer`, `sender_approved`), the frame
//! receipts, and which frame owns the outstanding state-gas charge of each
//! storage slot. Approval, attributed state gas, and ownership are journaled:
//! the executor opens, commits, and reverts a journal scope with every state
//! checkpoint, so a reverted call, frame, or atomic batch restores them
//! together with the state changes that produced them.
//!
//! Only executors whose spec activates frame transactions carry one. Its
//! storage is retained across transactions, so a transaction allocates only
//! when it outgrows every earlier one.

const std = @import("std");

const Address = @import("../address.zig").Address;
const Host = @import("../Host.zig");
const frames = @import("../transaction/frames.zig");

pub const Slot = struct {
    address: Address,
    key: u256,
};

/// Scopes nest at most one per call depth plus the transition's own frame,
/// batch, and approval checkpoints.
const max_scope_depth = @as(usize, Host.max_call_depth) + 8;

pub fn Journal(comptime params: frames.Params) type {
    return struct {
        const Self = @This();

        const Undo = union(enum) {
            owner: struct { slot: Slot, previous: ?u8 },
            state_gas: struct { frame: u8, previous: u64 },
            approval: struct { payer: ?Address, sender_approved: bool },
        };

        payer: ?Address = null,
        sender_approved: bool = false,
        /// Receipts of the current transaction's frames. Only `state_gas_used`
        /// is journaled; status, execution gas, and logs are fixed at frame exit
        /// and adjusted by the transition when an atomic batch unrolls.
        receipts: [params.max_frames]frames.Receipt = undefined,
        frame_count: u8 = 0,
        owners: std.AutoHashMapUnmanaged(Slot, u8) = .empty,
        undo: std.ArrayList(Undo) = .empty,
        marks: [max_scope_depth]u32 = undefined,
        scope_depth: usize = 0,

        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            self.owners.deinit(allocator);
            self.undo.deinit(allocator);
            self.* = undefined;
        }

        /// Start a frame transaction with `frame_count` frames. Asserts that no
        /// scope is open.
        pub fn reset(self: *Self, frame_count: u8) void {
            std.debug.assert(self.scope_depth == 0);
            std.debug.assert(frame_count <= params.max_frames);
            self.payer = null;
            self.sender_approved = false;
            self.frame_count = frame_count;
            @memset(self.receipts[0..frame_count], .{});
            self.owners.clearRetainingCapacity();
            self.undo.clearRetainingCapacity();
        }

        pub fn frameReceipts(self: *const Self) []const frames.Receipt {
            return self.receipts[0..self.frame_count];
        }

        pub fn openScope(self: *Self) void {
            std.debug.assert(self.scope_depth < max_scope_depth);
            self.marks[self.scope_depth] = @intCast(self.undo.items.len);
            self.scope_depth += 1;
        }

        /// Committed entries stay: an enclosing scope may still revert them.
        pub fn commitScope(self: *Self) void {
            self.scope_depth -= 1;
        }

        pub fn revertScope(self: *Self) void {
            self.scope_depth -= 1;
            const mark = self.marks[self.scope_depth];
            while (self.undo.items.len > mark) {
                switch (self.undo.pop().?) {
                    .owner => |entry| if (entry.previous) |owner| {
                        self.owners.putAssumeCapacity(entry.slot, owner);
                    } else {
                        _ = self.owners.remove(entry.slot);
                    },
                    .state_gas => |entry| self.receipts[entry.frame].state_gas_used = entry.previous,
                    .approval => |entry| {
                        self.payer = entry.payer;
                        self.sender_approved = entry.sender_approved;
                    },
                }
            }
        }

        /// Record `frame` as the owner of a state-gas charge for `slot`.
        pub fn chargeSlot(self: *Self, allocator: std.mem.Allocator, slot: Slot, frame: u8) !void {
            try self.undo.ensureUnusedCapacity(allocator, 1);
            const entry = try self.owners.getOrPut(allocator, slot);
            self.undo.appendAssumeCapacity(.{ .owner = .{
                .slot = slot,
                .previous = if (entry.found_existing) entry.value_ptr.* else null,
            } });
            entry.value_ptr.* = frame;
        }

        /// Release the outstanding charge for `slot` refilled by `frame`.
        /// Returns whether `frame` owns it and so takes the refill into its
        /// own pool; otherwise the owning frame's receipt gives `amount` back.
        pub fn refillSlot(
            self: *Self,
            allocator: std.mem.Allocator,
            slot: Slot,
            frame: u8,
            amount: u64,
        ) !bool {
            const owner = self.owners.get(slot) orelse return true;
            try self.undo.ensureUnusedCapacity(allocator, 2);
            self.undo.appendAssumeCapacity(.{ .owner = .{ .slot = slot, .previous = owner } });
            _ = self.owners.remove(slot);
            if (owner == frame) return true;
            std.debug.assert(owner < frame);
            const receipt = &self.receipts[owner];
            std.debug.assert(receipt.state_gas_used >= amount);
            self.undo.appendAssumeCapacity(.{ .state_gas = .{ .frame = owner, .previous = receipt.state_gas_used } });
            receipt.state_gas_used -= amount;
            return false;
        }

        /// Close `frame`'s receipt. Its state gas is journaled so an enclosing
        /// atomic batch that unrolls zeroes it.
        pub fn closeFrame(
            self: *Self,
            allocator: std.mem.Allocator,
            frame: u8,
            receipt: frames.Receipt,
        ) !void {
            try self.undo.append(allocator, .{ .state_gas = .{
                .frame = frame,
                .previous = self.receipts[frame].state_gas_used,
            } });
            self.receipts[frame] = receipt;
        }

        /// Set the approval context, journaled.
        pub fn approve(
            self: *Self,
            allocator: std.mem.Allocator,
            payer: ?Address,
            sender_approved: bool,
        ) !void {
            try self.undo.append(allocator, .{ .approval = .{
                .payer = self.payer,
                .sender_approved = self.sender_approved,
            } });
            self.payer = payer;
            self.sender_approved = sender_approved;
        }
    };
}

const test_params = @import("../eth/eip/8141.zig").params;

test "a reverted scope restores ownership, attributed state gas, and approval" {
    const allocator = std.testing.allocator;
    var journal: Journal(test_params) = .{};
    defer journal.deinit(allocator);
    journal.reset(3);
    const slot: Slot = .{ .address = .zero, .key = 7 };

    journal.openScope();
    try journal.chargeSlot(allocator, slot, 0);
    try journal.closeFrame(allocator, 0, .{ .status = .success, .state_gas_used = 100 });
    journal.commitScope();

    journal.openScope();
    try journal.approve(allocator, .zero, true);
    // Frame 2 refills frame 0's charge: frame 0's receipt pays it back and
    // frame 2's pool gets nothing.
    try std.testing.expect(!try journal.refillSlot(allocator, slot, 2, 40));
    try std.testing.expectEqual(@as(u64, 60), journal.frameReceipts()[0].state_gas_used);
    // Ownership is released: a second refill credits the current frame.
    try std.testing.expect(try journal.refillSlot(allocator, slot, 2, 40));
    journal.revertScope();

    try std.testing.expectEqual(@as(u64, 100), journal.frameReceipts()[0].state_gas_used);
    try std.testing.expectEqual(@as(?Address, null), journal.payer);
    try std.testing.expect(!journal.sender_approved);
    try std.testing.expectEqual(@as(?u8, 0), journal.owners.get(slot));
    // The owner refilling its own charge keeps its receipt.
    try std.testing.expect(try journal.refillSlot(allocator, slot, 0, 40));
    try std.testing.expectEqual(@as(u64, 100), journal.frameReceipts()[0].state_gas_used);
}
