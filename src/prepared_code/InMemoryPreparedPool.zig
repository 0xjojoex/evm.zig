//! Default in-memory implementation of the prepared-code backend.
//!
//! The map owns prepared bytecode and returns non-owning views. Moving map
//! entries does not move their separately allocated code or jumpdest storage.
//! Prepared artifacts are keyed only by code hash; the builder strategy does
//! not change the resulting artifact.
//!
//! This is an explicitly growable, single-execution-lane convenience preset
//! for tests, demos, and simple embeddings. It is not synchronized and has no
//! eviction budget. Production clients should provide a backend with their own
//! concurrency, persistence, and capacity policy.

const std = @import("std");
const Backend = @import("Backend.zig");
const Bytecode = @import("../code/Bytecode.zig");
const crypto = @import("../crypto.zig");

const InMemoryPreparedPool = @This();

allocator: std.mem.Allocator,
entries: std.AutoHashMap([32]u8, Bytecode),
active_executions: usize = 0,
/// Sum of semantic bytecode lengths, excluding padding and jumpdest maps.
retained_code_bytes: usize = 0,

pub fn init(allocator: std.mem.Allocator) InMemoryPreparedPool {
    return .{
        .allocator = allocator,
        .entries = std.AutoHashMap([32]u8, Bytecode).init(allocator),
    };
}

pub fn backend(self: *InMemoryPreparedPool) Backend {
    return .{ .ptr = self, .vtable = &backend_vtable };
}

pub fn deinit(self: *InMemoryPreparedPool) void {
    std.debug.assert(!self.hasActiveExecution());
    self.clearEntriesRetainingCapacity();
    self.entries.deinit();
    self.* = undefined;
}

pub fn beginExecution(self: *InMemoryPreparedPool) void {
    self.active_executions = std.math.add(usize, self.active_executions, 1) catch
        @panic("prepared-code execution depth overflow");
}

pub fn endExecution(self: *InMemoryPreparedPool) void {
    std.debug.assert(self.active_executions > 0);
    self.active_executions -= 1;
}

pub fn hasActiveExecution(self: *const InMemoryPreparedPool) bool {
    return self.active_executions != 0;
}

pub fn get(self: *InMemoryPreparedPool, code_hash: [32]u8) ?Bytecode.View {
    const bytecode = self.entries.getPtr(code_hash) orelse return null;
    return bytecode.view();
}

pub fn getOrPrepare(
    self: *InMemoryPreparedPool,
    expected_hash: [32]u8,
    raw_code: []const u8,
) !Bytecode.View {
    if (self.get(expected_hash)) |prepared| return prepared;

    const actual_hash = crypto.keccak256(raw_code);
    if (!std.mem.eql(u8, &actual_hash, &expected_hash)) return error.CodeHashMismatch;
    const new_retained_code_bytes = std.math.add(
        usize,
        self.retained_code_bytes,
        raw_code.len,
    ) catch return error.OutOfMemory;

    var bytecode = try Bytecode.init(self.allocator, raw_code);
    errdefer bytecode.deinit(self.allocator);
    const view = bytecode.view();
    try self.entries.putNoClobber(expected_hash, bytecode);
    self.retained_code_bytes = new_retained_code_bytes;
    return view;
}

pub fn count(self: *const InMemoryPreparedPool) usize {
    return self.entries.count();
}

pub fn clearRetainingCapacity(self: *InMemoryPreparedPool) !void {
    if (self.hasActiveExecution()) return error.ActivePreparedCodeExecution;
    self.clearEntriesRetainingCapacity();
}

fn clearEntriesRetainingCapacity(self: *InMemoryPreparedPool) void {
    var values = self.entries.valueIterator();
    while (values.next()) |bytecode| {
        bytecode.deinit(self.allocator);
    }
    self.entries.clearRetainingCapacity();
    self.retained_code_bytes = 0;
}

const backend_vtable = Backend.VTable{
    .beginExecution = backendBeginExecution,
    .endExecution = backendEndExecution,
    .lookup = backendLookup,
    .admit = backendAdmit,
};

fn backendBeginExecution(ptr: *anyopaque) !void {
    const self: *InMemoryPreparedPool = @ptrCast(@alignCast(ptr));
    self.beginExecution();
}

fn backendEndExecution(ptr: *anyopaque) void {
    const self: *InMemoryPreparedPool = @ptrCast(@alignCast(ptr));
    self.endExecution();
}

fn backendLookup(ptr: *anyopaque, code_hash: [32]u8) !?Bytecode.View {
    const self: *InMemoryPreparedPool = @ptrCast(@alignCast(ptr));
    return self.get(code_hash);
}

fn backendAdmit(ptr: *anyopaque, code_hash: [32]u8, raw_code: []const u8) !?Bytecode.View {
    const self: *InMemoryPreparedPool = @ptrCast(@alignCast(ptr));
    return try self.getOrPrepare(code_hash, raw_code);
}

test "wrong hash rejects admission atomically" {
    var pool = InMemoryPreparedPool.init(std.testing.allocator);
    defer pool.deinit();

    const raw_code = [_]u8{ 0x60, 0x01, 0x00 };
    const wrong_hash = [_]u8{0xff} ** 32;
    try std.testing.expectError(error.CodeHashMismatch, pool.getOrPrepare(wrong_hash, &raw_code));
    try std.testing.expectEqual(@as(usize, 0), pool.count());
    try std.testing.expectEqual(@as(usize, 0), pool.retained_code_bytes);
}

test "prepared bytecode owns source bytes" {
    var pool = InMemoryPreparedPool.init(std.testing.allocator);
    defer pool.deinit();

    var raw_code = [_]u8{ 0x60, 0x01, 0x00 };
    const original = raw_code;
    const code_hash = crypto.keccak256(&raw_code);
    const prepared = try pool.getOrPrepare(code_hash, &raw_code);

    try std.testing.expect(prepared.bytes.ptr != raw_code[0..].ptr);
    @memset(&raw_code, 0xff);
    try std.testing.expectEqualSlices(u8, &original, prepared.bytes);
}

test "prepared views remain valid while map grows" {
    var pool = InMemoryPreparedPool.init(std.testing.allocator);
    defer pool.deinit();

    const anchor_code = [_]u8{ 0x60, 0x01, 0x5b, 0x00 };
    const anchor_hash = crypto.keccak256(&anchor_code);
    const anchor = try pool.getOrPrepare(anchor_hash, &anchor_code);

    for (0..256) |index| {
        var code: [9]u8 = undefined;
        std.mem.writeInt(u64, code[0..8], @intCast(index), .big);
        code[8] = 0x00;
        _ = try pool.getOrPrepare(crypto.keccak256(&code), &code);
    }

    try std.testing.expectEqual(@as(usize, 257), pool.count());
    try std.testing.expectEqual(anchor.bytes.ptr, pool.get(anchor_hash).?.bytes.ptr);
    try std.testing.expectEqualSlices(u8, &anchor_code, anchor.bytes);
}

test "repeated preparation shares one retained artifact" {
    var pool = InMemoryPreparedPool.init(std.testing.allocator);
    defer pool.deinit();

    const code = [_]u8{ 0x5b, 0x00 };
    const code_hash = crypto.keccak256(&code);
    const first = try pool.getOrPrepare(code_hash, &code);
    const second = try pool.getOrPrepare(code_hash, &code);

    try std.testing.expectEqual(first.bytes.ptr, second.bytes.ptr);
    try std.testing.expectEqual(@as(usize, 1), pool.count());
}

test "active execution rejects invalidation" {
    var pool = InMemoryPreparedPool.init(std.testing.allocator);
    defer pool.deinit();

    const code = [_]u8{0x00};
    _ = try pool.getOrPrepare(crypto.keccak256(&code), &code);
    pool.beginExecution();
    try std.testing.expectError(error.ActivePreparedCodeExecution, pool.clearRetainingCapacity());
    pool.endExecution();
    try pool.clearRetainingCapacity();
    try std.testing.expectEqual(@as(usize, 0), pool.count());
}
