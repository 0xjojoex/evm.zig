//! Typed decoder context and caller-owned resource budget.

const std = @import("std");
const raw = @import("raw.zig");

pub const Error = raw.ParseError || error{
    DecodeAllocationLimitExceeded,
    DecodeDepthLimitExceeded,
    DecodeItemLimitExceeded,
};

pub const Limits = struct {
    max_depth: usize = std.math.maxInt(usize),
    max_items: usize = std.math.maxInt(usize),
    max_allocated_bytes: usize = std.math.maxInt(usize),

    pub const unlimited: Limits = .{};
};

pub const Budget = struct {
    limits: Limits,
    visited_items: usize = 0,
    allocated_bytes: usize = 0,

    pub fn init(limits: Limits) Budget {
        return .{ .limits = limits };
    }

    pub fn unlimited() Budget {
        return init(.unlimited);
    }

    pub fn ensureItems(self: Budget, additional: usize) Error!void {
        const total = std.math.add(usize, self.visited_items, additional) catch
            return error.DecodeItemLimitExceeded;
        if (total > self.limits.max_items) return error.DecodeItemLimitExceeded;
    }

    pub fn ensureAllocation(self: Budget, bytes: usize) Error!void {
        const total = std.math.add(usize, self.allocated_bytes, bytes) catch
            return error.DecodeAllocationLimitExceeded;
        if (total > self.limits.max_allocated_bytes) {
            return error.DecodeAllocationLimitExceeded;
        }
    }

    pub fn commitAllocation(self: *Budget, bytes: usize) void {
        self.allocated_bytes = std.math.add(usize, self.allocated_bytes, bytes) catch
            unreachable;
    }

    pub fn commitItems(self: *Budget, additional: usize) Error!void {
        try self.ensureItems(additional);
        self.visited_items += additional;
    }

    fn visitItem(self: *Budget) Error!void {
        try self.commitItems(1);
    }
};

pub const Decoder = struct {
    cursor: raw.Cursor,
    budget: *Budget,
    depth: usize = 0,

    pub fn init(input: []const u8, budget: *Budget) Decoder {
        return .{ .cursor = raw.Cursor.init(input), .budget = budget };
    }

    pub fn fromCursor(cursor: raw.Cursor, budget: *Budget, depth: usize) Decoder {
        return .{ .cursor = cursor, .budget = budget, .depth = depth };
    }

    pub fn isDone(self: Decoder) bool {
        return self.cursor.isDone();
    }

    pub fn expectDone(self: Decoder) Error!void {
        return self.cursor.expectDone();
    }

    pub fn next(self: *Decoder) Error!raw.Item {
        const value = try self.cursor.next();
        try self.budget.visitItem();
        return value;
    }

    pub fn nextBytes(self: *Decoder) Error![]const u8 {
        return (try self.next()).asBytes();
    }

    pub fn nextBytesExact(self: *Decoder, len: usize) Error![]const u8 {
        return (try self.next()).asBytesExact(len);
    }

    pub fn nextInt(self: *Decoder, comptime T: type) Error!T {
        return (try self.next()).asInt(T);
    }

    pub fn nextList(self: *Decoder) Error!Decoder {
        const item = try self.next();
        const child_cursor = try item.listCursor();
        const child_depth = std.math.add(usize, self.depth, 1) catch
            return error.DecodeDepthLimitExceeded;
        if (child_depth > self.budget.limits.max_depth) {
            return error.DecodeDepthLimitExceeded;
        }
        return fromCursor(child_cursor, self.budget, child_depth);
    }
};
