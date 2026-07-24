//! Default in-memory implementation of the prepared-code backend.
//!
//! Entries are allocated separately from the map so live pointers remain
//! stable while the map grows. Multiple preparation keys can coexist, allowing
//! one caller-owned pool to survive VM reset and configuration changes.
//!
//! This is an explicitly growable, single-execution-lane convenience preset
//! for tests, demos, and simple embeddings. It is not synchronized and has no
//! eviction budget. Production clients should provide a backend with their own
//! concurrency, persistence, and capacity policy.

const std = @import("std");
const Backend = @import("Backend.zig");
const PreparationKey = Backend.PreparationKey;
const Bytecode = @import("../code/Bytecode.zig");
const crypto = @import("../crypto.zig");

const InMemoryPreparedPool = @This();
const CacheKey = [34]u8;

const Entry = struct {
    bytecode: Bytecode,
};

allocator: std.mem.Allocator,
entries: std.AutoHashMap(CacheKey, *Entry),
active_executions: usize = 0,
/// Sum of semantic bytecode lengths, excluding padding and metadata.
retained_code_bytes: usize = 0,

pub fn init(allocator: std.mem.Allocator) InMemoryPreparedPool {
    return .{
        .allocator = allocator,
        .entries = std.AutoHashMap(CacheKey, *Entry).init(allocator),
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

pub fn get(self: *InMemoryPreparedPool, key: PreparationKey, code_hash: [32]u8) ?*const Bytecode {
    const entry = self.entries.get(cacheKey(key, code_hash)) orelse return null;
    return &entry.bytecode;
}

pub fn getOrPrepare(
    self: *InMemoryPreparedPool,
    key: PreparationKey,
    expected_hash: [32]u8,
    raw_code: []const u8,
) !*const Bytecode {
    if (self.get(key, expected_hash)) |prepared| return prepared;

    const actual_hash = crypto.keccak256(raw_code);
    if (!std.mem.eql(u8, &actual_hash, &expected_hash)) return error.CodeHashMismatch;
    const new_retained_code_bytes = std.math.add(
        usize,
        self.retained_code_bytes,
        raw_code.len,
    ) catch return error.OutOfMemory;

    const entry = try self.allocator.create(Entry);
    errdefer self.allocator.destroy(entry);
    entry.* = .{
        .bytecode = try Bytecode.prepare(self.allocator, raw_code, key.config),
    };
    errdefer entry.bytecode.deinit(self.allocator);

    try self.entries.putNoClobber(cacheKey(key, expected_hash), entry);
    self.retained_code_bytes = new_retained_code_bytes;
    return &entry.bytecode;
}

pub fn count(self: *const InMemoryPreparedPool) usize {
    return self.entries.count();
}

pub fn retainedCodeBytes(self: *const InMemoryPreparedPool) usize {
    return self.retained_code_bytes;
}

pub fn clearRetainingCapacity(self: *InMemoryPreparedPool) !void {
    if (self.hasActiveExecution()) return error.ActivePreparedCodeExecution;
    self.clearEntriesRetainingCapacity();
}

fn clearEntriesRetainingCapacity(self: *InMemoryPreparedPool) void {
    var values = self.entries.valueIterator();
    while (values.next()) |entry_ptr| {
        const entry = entry_ptr.*;
        entry.bytecode.deinit(self.allocator);
        self.allocator.destroy(entry);
    }
    self.entries.clearRetainingCapacity();
    self.retained_code_bytes = 0;
}

fn cacheKey(key: PreparationKey, code_hash: [32]u8) CacheKey {
    var result: CacheKey = undefined;
    result[0] = @intFromEnum(key.config.preprocessing);
    result[1] = @intFromEnum(key.config.jumpdest_strategy);
    @memcpy(result[2..], &code_hash);
    return result;
}

const backend_vtable = Backend.VTable{
    .beginExecution = backendBeginExecution,
    .endExecution = backendEndExecution,
    .lookup = backendLookup,
    .admit = backendAdmit,
};

fn backendBeginExecution(ptr: *anyopaque, key: PreparationKey) !void {
    _ = key;
    const self: *InMemoryPreparedPool = @ptrCast(@alignCast(ptr));
    self.beginExecution();
}

fn backendEndExecution(ptr: *anyopaque) void {
    const self: *InMemoryPreparedPool = @ptrCast(@alignCast(ptr));
    self.endExecution();
}

fn backendLookup(ptr: *anyopaque, key: PreparationKey, code_hash: [32]u8) !?*const Bytecode {
    const self: *InMemoryPreparedPool = @ptrCast(@alignCast(ptr));
    return self.get(key, code_hash);
}

fn backendAdmit(ptr: *anyopaque, key: PreparationKey, code_hash: [32]u8, raw_code: []const u8) !?*const Bytecode {
    const self: *InMemoryPreparedPool = @ptrCast(@alignCast(ptr));
    return try self.getOrPrepare(key, code_hash, raw_code);
}

const base_key = PreparationKey{ .config = .base };

test "wrong hash rejects admission atomically" {
    var pool = InMemoryPreparedPool.init(std.testing.allocator);
    defer pool.deinit();

    const raw_code = [_]u8{ 0x60, 0x01, 0x00 };
    const wrong_hash = [_]u8{0xff} ** 32;
    try std.testing.expectError(error.CodeHashMismatch, pool.getOrPrepare(base_key, wrong_hash, &raw_code));
    try std.testing.expectEqual(@as(usize, 0), pool.count());
    try std.testing.expectEqual(@as(usize, 0), pool.retainedCodeBytes());
}

test "prepared bytecode owns source bytes" {
    var pool = InMemoryPreparedPool.init(std.testing.allocator);
    defer pool.deinit();

    var raw_code = [_]u8{ 0x60, 0x01, 0x00 };
    const original = raw_code;
    const code_hash = crypto.keccak256(&raw_code);
    const prepared = try pool.getOrPrepare(base_key, code_hash, &raw_code);

    try std.testing.expect(prepared.bytes.ptr != raw_code[0..].ptr);
    @memset(&raw_code, 0xff);
    try std.testing.expectEqualSlices(u8, &original, prepared.bytes);
    try std.testing.expectEqual(prepared, try pool.getOrPrepare(base_key, code_hash, &raw_code));
}

test "prepared pointers remain stable while map grows" {
    var pool = InMemoryPreparedPool.init(std.testing.allocator);
    defer pool.deinit();

    const anchor_code = [_]u8{ 0x60, 0x01, 0x5b, 0x00 };
    const anchor_hash = crypto.keccak256(&anchor_code);
    const anchor = try pool.getOrPrepare(base_key, anchor_hash, &anchor_code);

    for (0..256) |index| {
        var code: [9]u8 = undefined;
        std.mem.writeInt(u64, code[0..8], @intCast(index), .big);
        code[8] = 0x00;
        _ = try pool.getOrPrepare(base_key, crypto.keccak256(&code), &code);
    }

    try std.testing.expectEqual(@as(usize, 257), pool.count());
    try std.testing.expectEqual(anchor, pool.get(base_key, anchor_hash).?);
    try std.testing.expectEqualSlices(u8, &anchor_code, anchor.bytes);
}

test "preparation keys isolate retained configurations" {
    var pool = InMemoryPreparedPool.init(std.testing.allocator);
    defer pool.deinit();

    const code = [_]u8{ 0x5b, 0x00 };
    const code_hash = crypto.keccak256(&code);
    const scalar = try pool.getOrPrepare(.{
        .config = .base,
    }, code_hash, &code);
    const simd = try pool.getOrPrepare(.{
        .config = .{ .jumpdest_strategy = .simd_bitmask },
    }, code_hash, &code);

    try std.testing.expect(scalar != simd);
    try std.testing.expect(scalar.jumpdests.analyzed);
    try std.testing.expectEqual(@import("../ExecutionConfig.zig").JumpDestStrategy.scalar_bitmask, scalar.jumpdests.strategy);
    try std.testing.expectEqual(@import("../ExecutionConfig.zig").JumpDestStrategy.simd_bitmask, simd.jumpdests.strategy);
}

test "active execution rejects invalidation" {
    var pool = InMemoryPreparedPool.init(std.testing.allocator);
    defer pool.deinit();

    const code = [_]u8{0x00};
    _ = try pool.getOrPrepare(base_key, crypto.keccak256(&code), &code);
    pool.beginExecution();
    try std.testing.expectError(error.ActivePreparedCodeExecution, pool.clearRetainingCapacity());
    pool.endExecution();
    try pool.clearRetainingCapacity();
    try std.testing.expectEqual(@as(usize, 0), pool.count());
}
