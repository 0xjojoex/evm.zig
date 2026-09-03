//! Owned block-final state changes, independent of the commitment tree.
//!
//! Execution representations project their accepted branch into this value.
//! MPT, PBT, databases, and followers consume it without retaining execution
//! state, journals, BAL IDs, or commitment-specific topology.

const std = @import("std");

const Address = @import("../address.zig").Address;
const state = @import("../state.zig");

const Allocator = std.mem.Allocator;
const AccountChange = state.AccountChange;
const StorageChange = state.StorageChange;
const CodeView = state.CodeView;

pub const Code = struct {
    code_hash: [32]u8,
    bytes: []u8,
};

const StateDelta = @This();

allocator: Allocator,
accounts: []AccountChange = &.{},
storage_writes: []StorageChange = &.{},
storage_wipes: []Address = &.{},
codes: []Code = &.{},

pub fn init(allocator: Allocator, changes: anytype) Allocator.Error!StateDelta {
    const accounts = try allocator.alloc(AccountChange, changes.accounts.len());
    errdefer allocator.free(accounts);
    const storage_writes = try allocator.alloc(StorageChange, changes.storage_writes.len());
    errdefer allocator.free(storage_writes);
    const storage_wipes = try allocator.alloc(Address, changes.storage_wipes.len());
    errdefer allocator.free(storage_wipes);

    for (accounts, 0..) |*target, index| {
        const change = changes.accounts.at(@intCast(index));
        target.* = .{ .address = change.address, .account = change.account };
    }
    for (storage_writes, 0..) |*target, index| {
        const change = changes.storage_writes.at(@intCast(index));
        target.* = .{
            .address = change.address,
            .key = change.key,
            .value = change.value,
        };
    }
    for (storage_wipes, 0..) |*target, index| {
        target.* = changes.storage_wipes.at(@intCast(index));
    }

    var codes: std.ArrayList(Code) = .empty;
    errdefer {
        for (codes.items) |code| allocator.free(code.bytes);
        codes.deinit(allocator);
    }
    for (accounts) |change| {
        const account = change.account orelse continue;
        const code = changes.introducedCode(account.code_hash) orelse continue;
        if (containsCode(codes.items, code.code_hash)) continue;
        const bytes = try allocator.dupe(u8, code.bytes);
        codes.append(allocator, .{
            .code_hash = code.code_hash,
            .bytes = bytes,
        }) catch |err| {
            allocator.free(bytes);
            return err;
        };
    }

    return .{
        .allocator = allocator,
        .accounts = accounts,
        .storage_writes = storage_writes,
        .storage_wipes = storage_wipes,
        .codes = try codes.toOwnedSlice(allocator),
    };
}

pub fn deinit(self: *StateDelta) void {
    for (self.codes) |code| self.allocator.free(code.bytes);
    self.allocator.free(self.codes);
    self.allocator.free(self.storage_wipes);
    self.allocator.free(self.storage_writes);
    self.allocator.free(self.accounts);
    self.* = undefined;
}

pub fn view(self: *const StateDelta) View {
    return .{
        .accounts = .{ .items = self.accounts },
        .storage_writes = .{ .items = self.storage_writes },
        .storage_wipes = .{ .items = self.storage_wipes },
        .codes = self.codes,
    };
}

pub const View = struct {
    accounts: AccountChanges,
    storage_writes: StorageChanges,
    storage_wipes: StorageWipes,
    codes: []const Code,

    pub fn introducedCode(self: View, code_hash: [32]u8) ?CodeView {
        for (self.codes) |code| {
            if (std.mem.eql(u8, &code.code_hash, &code_hash)) return .{
                .code_hash = code.code_hash,
                .bytes = code.bytes,
            };
        }
        return null;
    }

    pub fn hasChanges(self: View) bool {
        return self.accounts.len() != 0 or
            self.storage_writes.len() != 0 or
            self.storage_wipes.len() != 0;
    }
};

pub const AccountChanges = struct {
    items: []const AccountChange,

    pub fn len(self: AccountChanges) u32 {
        return @intCast(self.items.len);
    }

    pub fn at(self: AccountChanges, index: u32) AccountChange {
        return self.items[index];
    }
};

pub const StorageChanges = struct {
    items: []const StorageChange,

    pub fn len(self: StorageChanges) u32 {
        return @intCast(self.items.len);
    }

    pub fn at(self: StorageChanges, index: u32) StorageChange {
        return self.items[index];
    }
};

pub const StorageWipes = struct {
    items: []const Address,

    pub fn len(self: StorageWipes) u32 {
        return @intCast(self.items.len);
    }

    pub fn at(self: StorageWipes, index: u32) Address {
        return self.items[index];
    }
};

fn containsCode(codes: []const Code, code_hash: [32]u8) bool {
    for (codes) |code| {
        if (std.mem.eql(u8, &code.code_hash, &code_hash)) return true;
    }
    return false;
}

test "owned delta detaches values and introduced code" {
    const Changes = struct {
        const Accounts = struct {
            pub fn len(_: @This()) u32 {
                return 1;
            }
            pub fn at(_: @This(), _: u32) AccountChange {
                return .{
                    .address = .addr(0x1234),
                    .account = .{ .code_hash = [_]u8{0xab} ** 32 },
                };
            }
        };
        const Storage = struct {
            pub fn len(_: @This()) u32 {
                return 1;
            }
            pub fn at(_: @This(), _: u32) StorageChange {
                return .{ .address = .addr(0x1234), .key = 7, .value = 9 };
            }
        };
        const Wipes = struct {
            pub fn len(_: @This()) u32 {
                return 1;
            }
            pub fn at(_: @This(), _: u32) Address {
                return .addr(0x1234);
            }
        };

        accounts: Accounts = .{},
        storage_writes: Storage = .{},
        storage_wipes: Wipes = .{},

        pub fn introducedCode(_: @This(), hash: [32]u8) ?CodeView {
            const code_hash = [_]u8{0xab} ** 32;
            if (!std.mem.eql(u8, &hash, &code_hash)) return null;
            return .{ .code_hash = code_hash, .bytes = &.{ 0x60, 0x00 } };
        }
    };

    var delta = try StateDelta.init(std.testing.allocator, Changes{});
    defer delta.deinit();
    const value = delta.view();
    try std.testing.expectEqual(@as(u32, 1), value.accounts.len());
    try std.testing.expectEqual(@as(u256, 9), value.storage_writes.at(0).value);
    try std.testing.expectEqualSlices(u8, &.{ 0x60, 0x00 }, value.codes[0].bytes);
}
