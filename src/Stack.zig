//! Stack Machine for the EVM
const std = @import("std");

const _debug: bool = false;

/// The max stack size is 1024.
pub const capacity = 1024;

/// The stack is an array of 1024 256-bit words
stacks: [capacity]u256 = undefined,
len: usize = 0,

const Self = @This();

pub const Error = error{
    StackOverflow,
    StackUnderflow,
};

pub fn init() Self {
    return .{
        .stacks = undefined,
        .len = 0,
    };
}

pub fn push(self: *Self, value: u256) Error!void {
    if (self.len >= capacity) {
        return Error.StackOverflow;
    }
    self.stacks[self.len] = value;
    self.len += 1;
    if (_debug) {
        self.dump();
    }
}

pub fn pushN(self: *Self, comptime n: usize, values: [n]u256) Error!void {
    if (self.len + values.len > capacity) {
        return Error.StackOverflow;
    }
    inline for (values) |value| {
        self.len += 1;
        self.stacks[self.len] = value;
    }

    if (_debug) {
        self.dump();
    }
}

pub fn pop(self: *Self) Error!u256 {
    if (self.len == 0) {
        return Error.StackUnderflow;
    }
    self.len -= 1;
    return self.stacks[self.len];
}

pub fn peek(self: *Self) ?u256 {
    return self.stacks[self.len];
}

/// Swap the nth element from the top of the stack with the top element
pub fn swap(self: *Self, comptime n: usize) Error!void {
    const target = self.len - 1 - n;

    if (self.len < target) {
        return Error.StackUnderflow;
    }

    std.mem.swap(u256, &self.stacks[target], &self.stacks[self.len - 1]);
}

/// Duplicate the nth element from the top of the stack
pub fn dup(self: *Self, comptime n: usize) Error!void {
    if (self.len < n) {
        return Error.StackUnderflow;
    }
    try self.push(self.stacks[self.len - n]);
}

pub fn peekN(self: *Self, n: usize) ?u256 {
    if (self.len < n) {
        return null;
    }
    return self.stacks[self.len - n];
}

pub fn dump(self: *const Self) void {
    std.debug.print("--\n", .{});
    std.debug.print("Stack ({d}):\n", .{self.len});
    var i: usize = self.len;
    while (i > 0) {
        i -= 1;
        std.debug.print("{x}\n", .{self.stacks[i]});
    }
    std.debug.print("--\n", .{});
}

const testing = std.testing;

test Self {
    var stack = Self.init();

    try stack.push(1);
    try testing.expect(stack.len == 1);
    try stack.push(2);
    try stack.push(3);
    try stack.push(5);
    try testing.expect(stack.len == 4);

    _ = try stack.pop();
    try testing.expect(stack.len == 3);

    const values = [_]u256{ 1, 2, 3, 4, 5 };
    try stack.pushN(5, values);
    try testing.expect(stack.len == 8);

    const last = stack.peek().?;
    try testing.expect(last == 5);
    const last2 = stack.peekN(1).?;
    try testing.expect(last2 == 4);
}
