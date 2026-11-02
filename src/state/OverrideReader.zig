//! A state `Reader` that answers some accounts from caller overrides and the
//! rest from a parent reader: the parent state of a simulation with
//! `eth_call`-style state overrides (Geth's `stateOverrides`).
//!
//! Overrides are parent values to everything above the reader: the world
//! admits them like any load, so observations, the journal and the changes
//! views treat them as the state execution started from, and an override is
//! never itself a change. A root committed over them is not a chain root.
//!
//! Per account, each part is optional:
//!
//! - `balance`, `nonce` and `code` replace that field; the others come from
//!   the parent. With all three set the parent account is never asked for.
//! - `storage` `.replace` is the whole storage (Geth's `state`): the listed
//!   slots, every other slot zero, and the parent never asked for a slot.
//! - `storage` `.patch` sets the listed slots over the parent's (Geth's
//!   `stateDiff`).
//!
//! The lists are caller-owned and scanned; nothing is allocated. They must
//! outlive every reader handle, and override code every load of it.

const std = @import("std");

const crypto = @import("../crypto.zig");
const Address = @import("../address.zig").Address;
const Account = @import("./Account.zig");
const Reader = @import("./Reader.zig");

const OverrideReader = @This();

parent: Reader,
overrides: []const Override,

pub const Override = struct {
    address: Address,
    balance: ?u256 = null,
    nonce: ?u64 = null,
    code: ?Code = null,
    storage: Storage = .inherit,

    pub const Storage = union(enum) {
        inherit,
        /// The whole storage: these slots, every other slot zero.
        replace: []const Slot,
        /// These slots over the parent's.
        patch: []const Slot,
    };

    /// Whether every account field is overridden, so the parent account is
    /// not needed.
    pub fn replacesAccount(override: Override) bool {
        return override.balance != null and override.nonce != null and override.code != null;
    }

    /// The account execution starts from, over the parent's (`null` absent).
    /// An override of no field leaves the parent's as it is; any field starts
    /// an absent account from zero, as Geth does.
    pub fn account(override: Override, parent: ?Account) ?Account {
        if (override.balance == null and override.nonce == null and override.code == null) {
            return parent;
        }
        var value = parent orelse Account{};
        if (override.balance) |balance| value.balance = balance;
        if (override.nonce) |nonce| value.nonce = nonce;
        if (override.code) |code| value.code_hash = code.hash;
        return value;
    }

    /// The slot's value under the override, or null where the parent's
    /// stands.
    pub fn storageValue(override: Override, key: u256) ?u256 {
        const slots = switch (override.storage) {
            .inherit => return null,
            .replace, .patch => |slots| slots,
        };
        for (slots) |slot| if (slot.key == key) return slot.value;
        return if (override.storage == .replace) 0 else null;
    }
};

pub const Slot = struct {
    key: u256,
    value: u256,
};

pub const Code = struct {
    bytes: []const u8,
    /// keccak256 of `bytes`. Build with `init`: loads trust it unchecked.
    hash: [32]u8,

    pub fn init(bytes: []const u8) Code {
        return .{ .bytes = bytes, .hash = crypto.keccak256(bytes) };
    }
};

/// Overrides over `parent`. An address listed twice, or a slot listed twice
/// for one account, is `InvalidOverride`.
pub fn init(parent: Reader, overrides: []const Override) error{InvalidOverride}!OverrideReader {
    for (overrides, 0..) |override, index| {
        for (overrides[0..index]) |earlier| {
            if (earlier.address.eql(override.address)) return error.InvalidOverride;
        }
        const slots = switch (override.storage) {
            .inherit => continue,
            .replace, .patch => |slots| slots,
        };
        for (slots, 0..) |slot, slot_index| {
            for (slots[0..slot_index]) |earlier| {
                if (earlier.key == slot.key) return error.InvalidOverride;
            }
        }
    }
    return .{ .parent = parent, .overrides = overrides };
}

/// The reader. `self` must not move while it is in use. Code is validated
/// as the parent's is: override code was hashed by `Code.init`.
pub fn reader(self: *const OverrideReader) Reader {
    const vtable = if (self.parent.vtable.loadCodeValidatesHash) &validated else &unvalidated;
    return .{ .ptr = @constCast(self), .vtable = vtable };
}

/// The override for `address`, if any.
pub fn find(self: *const OverrideReader, address: Address) ?*const Override {
    for (self.overrides) |*override| if (override.address.eql(address)) return override;
    return null;
}

const validated: Reader.VTable = .{
    .loadAccount = loadAccount,
    .loadCode = loadCode,
    .loadCodeValidatesHash = true,
    .getStorage = getStorage,
};

const unvalidated: Reader.VTable = .{
    .loadAccount = loadAccount,
    .loadCode = loadCode,
    .getStorage = getStorage,
};

fn loadAccount(ptr: *anyopaque, address: Address) anyerror!?Account {
    const self: *const OverrideReader = @ptrCast(@alignCast(ptr));
    const override = self.find(address) orelse return self.parent.loadAccount(address);
    if (override.replacesAccount()) return override.account(null);
    return override.account(try self.parent.loadAccount(address));
}

fn loadCode(ptr: *anyopaque, code_hash: [32]u8) anyerror![]const u8 {
    const self: *const OverrideReader = @ptrCast(@alignCast(ptr));
    for (self.overrides) |override| {
        const code = override.code orelse continue;
        if (std.mem.eql(u8, &code.hash, &code_hash)) return code.bytes;
    }
    // The outer `Reader.loadCode` validates by this reader's flag, which is
    // the parent's.
    return self.parent.vtable.loadCode(self.parent.ptr, code_hash);
}

fn getStorage(ptr: *anyopaque, address: Address, key: u256) anyerror!u256 {
    const self: *const OverrideReader = @ptrCast(@alignCast(ptr));
    if (self.find(address)) |override| {
        if (override.storageValue(key)) |value| return value;
    }
    return self.parent.getStorage(address, key);
}

const testing = std.testing;
const MemoryStore = @import("./MemoryStore.zig");

/// Above the precompiles, so a call runs its code.
const holder: Address = .addr(0xc0de);

/// A `MemoryStore` reader that counts what it was asked.
const Counting = struct {
    store: MemoryStore,
    accounts: u32 = 0,
    codes: u32 = 0,
    slots: u32 = 0,

    fn init(counting: *Counting) !void {
        counting.* = .{ .store = .init(testing.allocator) };
        errdefer counting.store.deinit();
        const held = try counting.store.getOrCreateAccount(holder);
        held.account.nonce = 4;
        held.account.balance = 100;
        try held.storage.put(0, 3);
        try held.storage.put(1, 5);
        try held.setCode(&.{ 0x60, 0x00 });
    }

    fn reader(counting: *Counting) Reader {
        return .{ .ptr = counting, .vtable = &.{
            .loadAccount = countAccount,
            .loadCode = countCode,
            .getStorage = countStorage,
        } };
    }

    fn of(ptr: *anyopaque) *Counting {
        return @ptrCast(@alignCast(ptr));
    }

    fn countAccount(ptr: *anyopaque, address: Address) anyerror!?Account {
        of(ptr).accounts += 1;
        return of(ptr).store.reader().loadAccount(address);
    }

    fn countCode(ptr: *anyopaque, code_hash: [32]u8) anyerror![]const u8 {
        of(ptr).codes += 1;
        return of(ptr).store.reader().loadCode(code_hash);
    }

    fn countStorage(ptr: *anyopaque, address: Address, key: u256) anyerror!u256 {
        of(ptr).slots += 1;
        return of(ptr).store.reader().getStorage(address, key);
    }
};

test "account fields replace the parent's; all three spare the parent" {
    var parent: Counting = undefined;
    try parent.init();
    defer parent.store.deinit();
    const code: Code = .init(&.{ 0x60, 0x01 });
    const overrides = [_]Override{
        .{ .address = holder, .balance = 7 },
        .{ .address = .addr(2), .nonce = 9 },
        .{ .address = .addr(3), .balance = 1, .nonce = 2, .code = code },
        .{ .address = .addr(4), .storage = .{ .patch = &.{.{ .key = 0, .value = 1 }} } },
    };
    const self: OverrideReader = try .init(parent.reader(), &overrides);
    const state = self.reader();

    // The balance only; nonce and code are the parent's.
    const held = (try state.loadAccount(holder)).?;
    try testing.expectEqual(@as(u256, 7), held.balance);
    try testing.expectEqual(@as(u64, 4), held.nonce);
    try testing.expectEqual(crypto.keccak256(&.{ 0x60, 0x00 }), held.code_hash);
    try testing.expectEqual(@as(u32, 1), parent.accounts);
    // An absent account starts from zero.
    try testing.expectEqual(Account{ .nonce = 9 }, (try state.loadAccount(.addr(2))).?);
    try testing.expectEqual(@as(u32, 2), parent.accounts);
    // In full: the parent is not asked.
    const synthetic = (try state.loadAccount(.addr(3))).?;
    try testing.expectEqual(Account{ .balance = 1, .nonce = 2, .code_hash = code.hash }, synthetic);
    try testing.expectEqual(@as(u32, 2), parent.accounts);
    // Storage alone leaves an absent account absent.
    try testing.expectEqual(@as(?Account, null), try state.loadAccount(.addr(4)));
    try testing.expectEqual(@as(?Account, null), try state.loadAccount(.addr(5)));

    // Override code by its hash, the parent's by its own.
    try testing.expectEqualSlices(u8, code.bytes, try state.loadCode(code.hash));
    try testing.expectEqual(@as(u32, 0), parent.codes);
    try testing.expectEqualSlices(u8, &.{ 0x60, 0x00 }, try state.loadCode(held.code_hash));
    try testing.expectEqual(@as(u32, 1), parent.codes);
}

test "replaced storage never asks the parent; patched storage asks for the rest" {
    var parent: Counting = undefined;
    try parent.init();
    defer parent.store.deinit();
    const slots = [_]Slot{.{ .key = 0, .value = 7 }};
    for ([_]Override.Storage{ .inherit, .{ .replace = &slots }, .{ .patch = &slots } }) |storage| {
        parent.slots = 0;
        const overrides = [_]Override{.{ .address = holder, .storage = storage }};
        const self: OverrideReader = try .init(parent.reader(), &overrides);
        const state = self.reader();
        const expected: [2]u256, const asked: u32 = switch (storage) {
            .inherit => .{ .{ 3, 5 }, 2 },
            // Slot 1 is not listed: zero, though the parent holds 5.
            .replace => .{ .{ 7, 0 }, 0 },
            .patch => .{ .{ 7, 5 }, 1 },
        };
        try testing.expectEqual(expected[0], try state.getStorage(holder, 0));
        try testing.expectEqual(expected[1], try state.getStorage(holder, 1));
        try testing.expectEqual(asked, parent.slots);
        // Another account's storage is the parent's.
        try testing.expectEqual(@as(u256, 0), try state.getStorage(.addr(2), 0));
        try testing.expectEqual(asked + 1, parent.slots);
    }
}

test "an address or a slot listed twice is invalid" {
    const parent: Reader = .empty();
    const twice = [_]Override{ .{ .address = holder, .balance = 1 }, .{ .address = holder } };
    try testing.expectError(error.InvalidOverride, OverrideReader.init(parent, &twice));
    const slots = [_]Slot{ .{ .key = 4, .value = 1 }, .{ .key = 4, .value = 2 } };
    for ([_]Override.Storage{ .{ .replace = &slots }, .{ .patch = &slots } }) |storage| {
        const overrides = [_]Override{.{ .address = holder, .storage = storage }};
        try testing.expectError(error.InvalidOverride, OverrideReader.init(parent, &overrides));
    }
    // The same slot under two accounts is fine.
    const apart = [_]Override{
        .{ .address = holder, .storage = .{ .patch = slots[0..1] } },
        .{ .address = .addr(2), .storage = .{ .patch = slots[0..1] } },
    };
    _ = try OverrideReader.init(parent, &apart);
}

test "execution starts from the overrides" {
    const evmz = @import("../evm.zig");
    const Latest = evmz.t.Vm(.latest).?;
    var parent: Counting = undefined;
    try parent.init();
    defer parent.store.deinit();
    // Returns slots 0 and 1.
    const code: Code = .init(&.{
        0x60, 0x00, 0x54, 0x60, 0x00, 0x52, // MSTORE(0, SLOAD(0))
        0x60, 0x01, 0x54, 0x60, 0x20, 0x52, // MSTORE(32, SLOAD(1))
        0x60, 0x40, 0x60, 0x00, 0xf3, // RETURN(0, 64)
    });
    const overrides = [_]Override{.{
        .address = holder,
        .code = code,
        .storage = .{ .replace = &.{.{ .key = 0, .value = 7 }} },
    }};
    const self: OverrideReader = try .init(parent.reader(), &overrides);
    const init_options: Latest.Executor.Init = .{ .state = .{ .reader = self.reader() } };
    var executor = Latest.Executor.init(testing.allocator, init_options);
    defer executor.deinit();
    const sender: Address = .addr(9);
    try executor.beginTransaction(evmz.t.defaultExecutionContext(sender, 100_000), sender, holder);
    const message: evmz.execution.Message = .{ .call = .{
        .sender = sender,
        .recipient = holder,
        .input = &.{},
    } };
    const result = try executor.executeMessage(message, .legacy(100_000));
    try testing.expectEqual(evmz.execution.Status.success, result.status());
    var expected: [64]u8 = @splat(0);
    expected[31] = 7;
    try testing.expectEqualSlices(u8, &expected, result.output_data);
    // The parent's balance and nonce stand under the new code.
    try testing.expectEqual(@as(u256, 100), try executor.getBalance(holder));
    try testing.expectEqual(@as(u32, 0), parent.slots);
    try testing.expectEqual(@as(u32, 0), parent.codes);
}
