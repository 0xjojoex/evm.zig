//! Stack Machine for the EVM
const std = @import("std");

/// The max stack size is 1024.
pub const capacity = 1024;
pub const Storage = [capacity]u256;

/// Stack is an offset-indexed view over a caller-owned arena.
/// The owner must rebind `base` after arena relocation.
/// Execution semantics validate stack effects on `CallFrame`; operations here
/// assert those already-proven bounds.
base: [*]u256,
base_word: u32,
len: u16 = 0,

const Stack = @This();

comptime {
    std.debug.assert(@sizeOf(Stack) == 16);
}

pub fn init(words: []u256, base_word: u32) Stack {
    std.debug.assert(@as(usize, base_word) + capacity <= words.len);
    return .{ .base = words.ptr + base_word, .base_word = base_word };
}

/// Rebind after owner-side arena growth. Only live frames need this cold-path
/// update; stack operations retain a direct pointer to their offset range.
pub fn rebind(self: *Stack, words: []u256) void {
    std.debug.assert(@as(usize, self.base_word) + capacity <= words.len);
    self.base = words.ptr + self.base_word;
}

pub inline fn push(self: *Stack, value: u256) void {
    std.debug.assert(self.len < capacity);
    self.base[self.len] = value;
    self.len += 1;
}

pub inline fn pop(self: *Stack) u256 {
    std.debug.assert(self.len != 0);
    self.len -= 1;
    return self.base[self.len];
}

pub inline fn popN(self: *Stack, comptime n: usize) [n]u256 {
    std.debug.assert(self.len >= n);
    self.len -= n;

    var values: [n]u256 = undefined;
    inline for (0..n) |i| {
        values[i] = self.base[self.len + n - 1 - i];
    }
    return values;
}

pub fn peek(self: *Stack) ?u256 {
    return self.peekN(1);
}

/// Swap the nth element from the top of the stack with the top element
pub inline fn swap(self: *Stack, comptime n: usize) void {
    std.debug.assert(self.len > n);
    const target = self.len - 1 - n;
    std.mem.swap(u256, &self.base[target], &self.base[self.len - 1]);
}

pub inline fn swapDepth(self: *Stack, n: usize) void {
    std.debug.assert(self.len > n);
    const target = self.len - 1 - n;
    std.mem.swap(u256, &self.base[target], &self.base[self.len - 1]);
}

/// Duplicate the nth element from the top of the stack
pub fn dup(self: *Stack, comptime n: usize) void {
    std.debug.assert(self.len >= n);
    self.push(self.base[self.len - n]);
}

pub fn dupDepth(self: *Stack, n: usize) void {
    std.debug.assert(self.len >= n);
    self.push(self.base[self.len - n]);
}

pub inline fn exchangeDepths(self: *Stack, n: usize, m: usize) void {
    std.debug.assert(self.len > n and self.len > m);
    std.mem.swap(u256, &self.base[self.len - 1 - n], &self.base[self.len - 1 - m]);
}

inline fn peekN(self: *Stack, comptime n: usize) ?u256 {
    if (self.len < n) {
        return null;
    }
    return self.base[self.len - n];
}

/// Borrowed until the next synchronous host call or owner-side arena growth.
pub fn asSlice(self: *const Stack) []const u256 {
    return self.base[0..self.len];
}

const testing = std.testing;

test "arena offset selects a disjoint stack range and supports rebinding" {
    var first: [capacity * 2]u256 = @splat(0);
    var second: [capacity * 2]u256 = @splat(0);
    var lower = Stack.init(&first, 0);
    var upper = Stack.init(&first, capacity);

    lower.push(11);
    upper.push(41);
    try testing.expectEqual(@as(u256, 11), first[0]);
    try testing.expectEqual(@as(u256, 41), first[capacity]);

    second[0] = 12;
    second[capacity] = 42;
    lower.rebind(&second);
    upper.rebind(&second);
    try testing.expectEqual(@as(u256, 12), lower.peek().?);
    try testing.expectEqual(@as(u256, 42), upper.peek().?);
    try testing.expectEqual(@intFromPtr(&second[capacity]), @intFromPtr(upper.base));
}

test "push pop and peek use the top stack slot" {
    var storage: Storage = undefined;
    var stack = Stack.init(&storage, 0);

    try testing.expectEqual(null, stack.peek());

    stack.push(1);
    stack.push(2);
    stack.push(3);
    try testing.expectEqual(@as(u16, 3), stack.len);
    try testing.expectEqual(@as(u256, 3), stack.peek().?);
    try testing.expectEqual(@as(u256, 3), stack.peekN(1).?);
    try testing.expectEqual(@as(u256, 2), stack.peekN(2).?);
    try testing.expectEqual(@as(u256, 1), stack.peekN(3).?);
    try testing.expectEqual(null, stack.peekN(4));

    try testing.expectEqual(@as(u256, 3), stack.pop());
    try testing.expectEqual(@as(u256, 2), stack.pop());
    try testing.expectEqual(@as(u256, 1), stack.pop());
    try testing.expectEqual(@as(u16, 0), stack.len);
    try testing.expectEqual(null, stack.peek());
}

test "popN preserves repeated-pop operand order" {
    {
        var storage: Storage = undefined;
        var stack = Stack.init(&storage, 0);

        stack.push(1);
        stack.push(2);
        stack.push(3);

        const top, const next = stack.popN(2);
        try testing.expectEqual(@as(u256, 3), top);
        try testing.expectEqual(@as(u256, 2), next);
        try testing.expectEqual(@as(u16, 1), stack.len);
        try testing.expectEqual(@as(u256, 1), stack.peek().?);
    }

    {
        var storage: Storage = undefined;
        var stack = Stack.init(&storage, 0);

        stack.push(1);
        stack.push(2);
        stack.push(3);
        stack.push(4);
        stack.push(5);

        const top, const next, const third = stack.popN(3);
        try testing.expectEqual(@as(u256, 5), top);
        try testing.expectEqual(@as(u256, 4), next);
        try testing.expectEqual(@as(u256, 3), third);
        try testing.expectEqual(@as(u16, 2), stack.len);
        try testing.expectEqual(@as(u256, 2), stack.peek().?);
    }

    {
        var storage: Storage = undefined;
        var stack = Stack.init(&storage, 0);

        for (1..8) |value| {
            stack.push(@intCast(value));
        }

        const p4_0, const p4_1, const p4_2, const p4_3 = stack.popN(4);
        try testing.expectEqual(@as(u256, 7), p4_0);
        try testing.expectEqual(@as(u256, 6), p4_1);
        try testing.expectEqual(@as(u256, 5), p4_2);
        try testing.expectEqual(@as(u256, 4), p4_3);
        try testing.expectEqual(@as(u16, 3), stack.len);

        stack.push(4);
        stack.push(5);
        stack.push(6);

        const p6_0, const p6_1, const p6_2, const p6_3, const p6_4, const p6_5 = stack.popN(6);
        try testing.expectEqual(@as(u256, 6), p6_0);
        try testing.expectEqual(@as(u256, 5), p6_1);
        try testing.expectEqual(@as(u256, 4), p6_2);
        try testing.expectEqual(@as(u256, 3), p6_3);
        try testing.expectEqual(@as(u256, 2), p6_4);
        try testing.expectEqual(@as(u256, 1), p6_5);
        try testing.expectEqual(@as(u16, 0), stack.len);
    }
}

test "swap exchanges the selected slot" {
    var storage: Storage = undefined;
    var stack = Stack.init(&storage, 0);

    stack.push(1);
    stack.push(2);
    stack.swap(1);
    try testing.expectEqual(@as(u256, 1), stack.peek().?);
}

test "runtime-depth swaps exchange stack slots" {
    var storage: Storage = undefined;
    var stack = Stack.init(&storage, 0);

    stack.push(1);
    stack.push(2);
    stack.push(3);
    stack.push(4);

    stack.swapDepth(2);
    try testing.expectEqual(@as(u256, 2), stack.peek().?);
    try testing.expectEqual(@as(u256, 4), stack.peekN(3).?);

    stack.exchangeDepths(0, 3);
    try testing.expectEqual(@as(u256, 1), stack.peek().?);
    try testing.expectEqual(@as(u256, 2), stack.peekN(4).?);
}
