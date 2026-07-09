//! Stack Machine for the EVM
const std = @import("std");

/// The max stack size is 1024.
pub const capacity = 1024;
pub const Storage = [capacity]u256;

/// Stack is a view over caller-owned 256-bit word storage.
slots: *Storage = undefined,
len: usize = 0,

const Stack = @This();

inline fn swapSlot(a: *u256, b: *u256) void {
    const tmp = a.*;
    a.* = b.*;
    b.* = tmp;
}

fn PopN(comptime n: usize) type {
    if (n == 0) {
        @compileError("PopN requires at least one value");
    }
    return std.meta.Tuple(&([_]type{u256} ** n));
}

pub const Error = error{
    StackOverflow,
    StackUnderflow,
};

pub fn init(storage: *Storage) Stack {
    return .{ .slots = storage, .len = 0 };
}

pub fn push(self: *Stack, value: u256) Error!void {
    if (self.len >= capacity) {
        return Error.StackOverflow;
    }
    self.slots[self.len] = value;
    self.len += 1;
}

pub inline fn pushUnchecked(self: *Stack, value: u256) void {
    std.debug.assert(self.len < capacity);
    self.slots[self.len] = value;
    self.len += 1;
}

pub inline fn replaceTop(self: *Stack, value: u256) Error!void {
    if (self.len == 0) {
        return Error.StackUnderflow;
    }
    self.replaceTopUnchecked(value);
}

pub inline fn replaceTopUnchecked(self: *Stack, value: u256) void {
    std.debug.assert(self.len != 0);
    self.slots[self.len - 1] = value;
}

pub inline fn pop(self: *Stack) Error!u256 {
    if (self.len == 0) {
        return Error.StackUnderflow;
    }
    self.len -= 1;
    return self.slots[self.len];
}

pub inline fn popN(self: *Stack, comptime n: usize) Error!PopN(n) {
    if (self.len < n) {
        return Error.StackUnderflow;
    }
    self.len -= n;

    var values: PopN(n) = undefined;
    inline for (0..n) |i| {
        values[i] = self.slots[self.len + n - 1 - i];
    }
    return values;
}

pub fn peek(self: *Stack) ?u256 {
    return self.peekN(1);
}

/// Swap the nth element from the top of the stack with the top element
pub inline fn swap(self: *Stack, comptime n: usize) Error!void {
    if (self.len <= n) {
        return Error.StackUnderflow;
    }

    const target = self.len - 1 - n;
    swapSlot(&self.slots[target], &self.slots[self.len - 1]);
}

pub inline fn swapDepth(self: *Stack, n: usize) Error!void {
    if (self.len <= n) {
        return Error.StackUnderflow;
    }

    const target = self.len - 1 - n;
    swapSlot(&self.slots[target], &self.slots[self.len - 1]);
}

/// Duplicate the nth element from the top of the stack
pub fn dup(self: *Stack, comptime n: usize) Error!void {
    if (self.len < n) {
        return Error.StackUnderflow;
    }
    try self.push(self.slots[self.len - n]);
}

pub fn dupDepth(self: *Stack, n: usize) Error!void {
    if (self.len < n) {
        return Error.StackUnderflow;
    }
    try self.push(self.slots[self.len - n]);
}

pub inline fn exchangeDepths(self: *Stack, n: usize, m: usize) Error!void {
    if (self.len <= n or self.len <= m) {
        return Error.StackUnderflow;
    }

    swapSlot(&self.slots[self.len - 1 - n], &self.slots[self.len - 1 - m]);
}

pub fn peekN(self: *Stack, n: usize) ?u256 {
    if (self.len < n) {
        return null;
    }
    return self.slots[self.len - n];
}

pub fn asSlice(self: *const Stack) []const u256 {
    return self.slots[0..self.len];
}

pub fn dump(self: *const Stack) void {
    std.debug.print("--\n", .{});
    std.debug.print("Stack ({d}):\n", .{self.len});
    var i: usize = self.len;
    while (i > 0) {
        i -= 1;
        std.debug.print("{x}\n", .{self.slots[i]});
    }
    std.debug.print("--\n", .{});
}

const testing = std.testing;

test "push pop and peek use the top stack slot" {
    var storage: Storage = undefined;
    var stack = Stack.init(&storage);

    try testing.expectEqual(null, stack.peek());

    try stack.push(1);
    try stack.push(2);
    try stack.push(3);
    try testing.expectEqual(@as(usize, 3), stack.len);
    try testing.expectEqual(@as(u256, 3), stack.peek().?);
    try testing.expectEqual(@as(u256, 3), stack.peekN(1).?);
    try testing.expectEqual(@as(u256, 2), stack.peekN(2).?);
    try testing.expectEqual(@as(u256, 1), stack.peekN(3).?);
    try testing.expectEqual(null, stack.peekN(4));

    try testing.expectEqual(@as(u256, 3), try stack.pop());
    try testing.expectEqual(@as(u256, 2), try stack.pop());
    try testing.expectEqual(@as(u256, 1), try stack.pop());
    try testing.expectEqual(@as(usize, 0), stack.len);
    try testing.expectEqual(null, stack.peek());
    try testing.expectError(Error.StackUnderflow, stack.pop());
}

test "replaceTop updates the current top slot" {
    var storage: Storage = undefined;
    var stack = Stack.init(&storage);

    try testing.expectError(Error.StackUnderflow, stack.replaceTop(1));

    try stack.push(1);
    try stack.push(2);
    try stack.replaceTop(3);

    try testing.expectEqual(@as(usize, 2), stack.len);
    try testing.expectEqual(@as(u256, 3), stack.peek().?);
    try testing.expectEqual(@as(u256, 1), stack.peekN(2).?);
}

test "popN checks underflow and preserves repeated-pop operand order" {
    {
        var storage: Storage = undefined;
        var stack = Stack.init(&storage);

        try testing.expectError(Error.StackUnderflow, stack.popN(2));

        try stack.push(1);
        try testing.expectError(Error.StackUnderflow, stack.popN(2));

        try stack.push(2);
        try stack.push(3);

        const top, const next = try stack.popN(2);
        try testing.expectEqual(@as(u256, 3), top);
        try testing.expectEqual(@as(u256, 2), next);
        try testing.expectEqual(@as(usize, 1), stack.len);
        try testing.expectEqual(@as(u256, 1), stack.peek().?);
    }

    {
        var storage: Storage = undefined;
        var stack = Stack.init(&storage);

        try testing.expectError(Error.StackUnderflow, stack.popN(3));

        try stack.push(1);
        try stack.push(2);
        try testing.expectError(Error.StackUnderflow, stack.popN(3));

        try stack.push(3);
        try stack.push(4);
        try stack.push(5);

        const top, const next, const third = try stack.popN(3);
        try testing.expectEqual(@as(u256, 5), top);
        try testing.expectEqual(@as(u256, 4), next);
        try testing.expectEqual(@as(u256, 3), third);
        try testing.expectEqual(@as(usize, 2), stack.len);
        try testing.expectEqual(@as(u256, 2), stack.peek().?);
    }

    {
        var storage: Storage = undefined;
        var stack = Stack.init(&storage);

        for (1..8) |value| {
            try stack.push(@intCast(value));
        }

        const p4_0, const p4_1, const p4_2, const p4_3 = try stack.popN(4);
        try testing.expectEqual(@as(u256, 7), p4_0);
        try testing.expectEqual(@as(u256, 6), p4_1);
        try testing.expectEqual(@as(u256, 5), p4_2);
        try testing.expectEqual(@as(u256, 4), p4_3);
        try testing.expectEqual(@as(usize, 3), stack.len);

        try stack.push(4);
        try stack.push(5);
        try stack.push(6);

        const p6_0, const p6_1, const p6_2, const p6_3, const p6_4, const p6_5 = try stack.popN(6);
        try testing.expectEqual(@as(u256, 6), p6_0);
        try testing.expectEqual(@as(u256, 5), p6_1);
        try testing.expectEqual(@as(u256, 4), p6_2);
        try testing.expectEqual(@as(u256, 3), p6_3);
        try testing.expectEqual(@as(u256, 2), p6_4);
        try testing.expectEqual(@as(u256, 1), p6_5);
        try testing.expectEqual(@as(usize, 0), stack.len);
    }
}

test "swap checks depth before computing target slot" {
    var storage: Storage = undefined;
    var stack = Stack.init(&storage);

    try testing.expectError(Error.StackUnderflow, stack.swap(1));
    try stack.push(1);
    try testing.expectError(Error.StackUnderflow, stack.swap(1));

    try stack.push(2);
    try stack.swap(1);
    try testing.expectEqual(@as(u256, 1), stack.peek().?);
}

test "runtime-depth swaps exchange stack slots" {
    var storage: Storage = undefined;
    var stack = Stack.init(&storage);

    try stack.push(1);
    try stack.push(2);
    try stack.push(3);
    try stack.push(4);

    try stack.swapDepth(2);
    try testing.expectEqual(@as(u256, 2), stack.peek().?);
    try testing.expectEqual(@as(u256, 4), stack.peekN(3).?);

    try stack.exchangeDepths(0, 3);
    try testing.expectEqual(@as(u256, 1), stack.peek().?);
    try testing.expectEqual(@as(u256, 2), stack.peekN(4).?);

    try testing.expectError(Error.StackUnderflow, stack.swapDepth(4));
    try testing.expectError(Error.StackUnderflow, stack.exchangeDepths(0, 4));
}
