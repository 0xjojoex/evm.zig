//! Deterministic per-account diagnostics for an expected and observed BAL.

const std = @import("std");

const bal = @import("model.zig");
const crypto = @import("../../crypto.zig");

pub const Diff = struct {
    expected: bal.BlockAccessList,
    actual: bal.BlockAccessList,

    pub fn format(self: Diff, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        var expected_index: usize = 0;
        var actual_index: usize = 0;
        while (expected_index < self.expected.len or actual_index < self.actual.len) {
            const expected_account: ?*const bal.AccountChanges = if (expected_index < self.expected.len) &self.expected[expected_index] else null;
            const actual_account: ?*const bal.AccountChanges = if (actual_index < self.actual.len) &self.actual[actual_index] else null;
            const order = if (expected_account == null)
                std.math.Order.gt
            else if (actual_account == null)
                std.math.Order.lt
            else
                std.mem.order(u8, &expected_account.?.address, &actual_account.?.address);

            switch (order) {
                .eq => {
                    if (!accountEqual(expected_account.?.*, actual_account.?.*)) {
                        try writeAccountDiff(writer, expected_account, actual_account);
                    }
                    expected_index += 1;
                    actual_index += 1;
                },
                .lt => {
                    try writeAccountDiff(writer, expected_account, null);
                    expected_index += 1;
                },
                .gt => {
                    try writeAccountDiff(writer, null, actual_account);
                    actual_index += 1;
                },
            }
        }
    }
};

fn writeAccountDiff(
    writer: *std.Io.Writer,
    expected: ?*const bal.AccountChanges,
    actual: ?*const bal.AccountChanges,
) std.Io.Writer.Error!void {
    const account_address = if (expected) |account| account.address else actual.?.address;
    try writer.print("account 0x{x}\n", .{account_address});
    try writeAccount(writer, "expected", expected);
    try writeAccount(writer, "actual", actual);
}

fn writeAccount(
    writer: *std.Io.Writer,
    label: []const u8,
    account: ?*const bal.AccountChanges,
) std.Io.Writer.Error!void {
    try writer.print("  {s}", .{label});
    const value = account orelse {
        try writer.writeAll(" <missing>\n");
        return;
    };

    try writer.writeAll(" balance=");
    try writeBalanceChanges(writer, value.balance_changes);
    try writer.writeAll(" nonce=");
    try writeNonceChanges(writer, value.nonce_changes);
    try writer.writeAll(" code=");
    try writeCodeChanges(writer, value.code_changes);
    try writer.writeAll(" storage_writes=");
    try writeStorageChanges(writer, value.storage_changes);
    try writer.writeAll(" storage_reads=");
    try writeWords(writer, value.storage_reads);
    try writer.writeByte('\n');
}

fn writeBalanceChanges(writer: *std.Io.Writer, changes: []const bal.BalanceChange) std.Io.Writer.Error!void {
    try writer.writeByte('[');
    for (changes, 0..) |change, index| {
        if (index != 0) try writer.writeAll(", ");
        try writer.print("{}:0x{x}", .{ change.block_access_index, change.post_balance });
    }
    try writer.writeByte(']');
}

fn writeNonceChanges(writer: *std.Io.Writer, changes: []const bal.NonceChange) std.Io.Writer.Error!void {
    try writer.writeByte('[');
    for (changes, 0..) |change, index| {
        if (index != 0) try writer.writeAll(", ");
        try writer.print("{}:{}", .{ change.block_access_index, change.new_nonce });
    }
    try writer.writeByte(']');
}

fn writeCodeChanges(writer: *std.Io.Writer, changes: []const bal.CodeChange) std.Io.Writer.Error!void {
    try writer.writeByte('[');
    for (changes, 0..) |change, index| {
        if (index != 0) try writer.writeAll(", ");
        try writer.print("{}:0x{x}/{}B", .{
            change.block_access_index,
            crypto.keccak256(change.new_code),
            change.new_code.len,
        });
    }
    try writer.writeByte(']');
}

fn writeStorageChanges(writer: *std.Io.Writer, slots: []const bal.SlotChanges) std.Io.Writer.Error!void {
    try writer.writeByte('[');
    for (slots, 0..) |slot, slot_index| {
        if (slot_index != 0) try writer.writeAll(", ");
        try writer.print("0x{x}={{", .{slot.slot});
        for (slot.changes, 0..) |change, change_index| {
            if (change_index != 0) try writer.writeAll(", ");
            try writer.print("{}:0x{x}", .{ change.block_access_index, change.new_value });
        }
        try writer.writeByte('}');
    }
    try writer.writeByte(']');
}

fn writeWords(writer: *std.Io.Writer, words: []const u256) std.Io.Writer.Error!void {
    try writer.writeByte('[');
    for (words, 0..) |word, index| {
        if (index != 0) try writer.writeAll(", ");
        try writer.print("0x{x}", .{word});
    }
    try writer.writeByte(']');
}

fn accountEqual(expected: bal.AccountChanges, actual: bal.AccountChanges) bool {
    return std.mem.eql(u8, &expected.address, &actual.address) and
        storageChangesEqual(expected.storage_changes, actual.storage_changes) and
        std.mem.eql(u256, expected.storage_reads, actual.storage_reads) and
        slicesEqual(bal.BalanceChange, expected.balance_changes, actual.balance_changes) and
        slicesEqual(bal.NonceChange, expected.nonce_changes, actual.nonce_changes) and
        codeChangesEqual(expected.code_changes, actual.code_changes);
}

fn storageChangesEqual(expected: []const bal.SlotChanges, actual: []const bal.SlotChanges) bool {
    if (expected.len != actual.len) return false;
    for (expected, actual) |expected_slot, actual_slot| {
        if (expected_slot.slot != actual_slot.slot or
            !slicesEqual(bal.StorageChange, expected_slot.changes, actual_slot.changes))
        {
            return false;
        }
    }
    return true;
}

fn slicesEqual(comptime T: type, expected: []const T, actual: []const T) bool {
    if (expected.len != actual.len) return false;
    for (expected, actual) |expected_change, actual_change| {
        if (!std.meta.eql(expected_change, actual_change)) return false;
    }
    return true;
}

fn codeChangesEqual(expected: []const bal.CodeChange, actual: []const bal.CodeChange) bool {
    if (expected.len != actual.len) return false;
    for (expected, actual) |expected_change, actual_change| {
        if (expected_change.block_access_index != actual_change.block_access_index or
            !std.mem.eql(u8, expected_change.new_code, actual_change.new_code))
        {
            return false;
        }
    }
    return true;
}

test "BAL diff reports only changed accounts" {
    const first = [_]bal.BalanceChange{.{ .block_access_index = 1, .post_balance = 7 }};
    const changed = [_]bal.BalanceChange{.{ .block_access_index = 1, .post_balance = 8 }};
    const reads = [_]u256{2};
    const expected = [_]bal.AccountChanges{
        .{ .address = @import("../../address.zig").addr(1), .balance_changes = &first },
        .{ .address = @import("../../address.zig").addr(3), .storage_reads = &reads },
    };
    const actual = [_]bal.AccountChanges{
        .{ .address = @import("../../address.zig").addr(1), .balance_changes = &changed },
        .{ .address = @import("../../address.zig").addr(2) },
    };

    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try output.writer.print("{f}", .{Diff{ .expected = &expected, .actual = &actual }});

    try std.testing.expect(std.mem.indexOf(u8, output.written(), "account 0x0000000000000000000000000000000000000001") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "expected balance=[1:0x7]") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "actual balance=[1:0x8]") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "account 0x0000000000000000000000000000000000000002") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "account 0x0000000000000000000000000000000000000003") != null);
}

test "BAL diff is empty for equal claims" {
    const claim = [_]bal.AccountChanges{.{ .address = @import("../../address.zig").addr(1) }};
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try output.writer.print("{f}", .{Diff{ .expected = &claim, .actual = &claim }});
    try std.testing.expectEqual(@as(usize, 0), output.written().len);
}
