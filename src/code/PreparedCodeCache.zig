//! Owned cache of validated, execution-ready bytecode.
//!
//! Entries are allocated separately from the hash map so pointers handed to
//! live call frames remain stable when the map grows. Raw code is copied by
//! `Bytecode.initWithConfig`; callers do not need to keep source bytes alive.

const std = @import("std");
const Bytecode = @import("Bytecode.zig");
const crypto = @import("../crypto.zig");
const ExecutionConfig = @import("../ExecutionConfig.zig");

const PreparedCodeCache = @This();

const Entry = struct {
    bytecode: Bytecode,
};

allocator: std.mem.Allocator,
config: ExecutionConfig,
entries: std.AutoHashMap([32]u8, *Entry),
/// Prevents invalidation while executor frames may retain entry pointers.
active_executions: usize = 0,
/// Sum of semantic bytecode lengths. This deliberately excludes zero padding,
/// jump metadata, entry objects, and hash-map capacity.
retained_code_bytes: usize = 0,

pub fn init(allocator: std.mem.Allocator, config: ExecutionConfig) PreparedCodeCache {
    return .{
        .allocator = allocator,
        .config = preparedConfig(config),
        .entries = std.AutoHashMap([32]u8, *Entry).init(allocator),
    };
}

/// Pin all cache entries for one complete executor operation.
///
/// Nested execution is supported. Invalidating operations reject while any
/// pin is active, covering frames that live outside the iterative frame stack.
pub fn beginExecution(self: *PreparedCodeCache) void {
    self.active_executions = std.math.add(usize, self.active_executions, 1) catch
        @panic("prepared-code execution depth overflow");
}

pub fn endExecution(self: *PreparedCodeCache) void {
    std.debug.assert(self.active_executions > 0);
    self.active_executions -= 1;
}

pub fn hasActiveExecution(self: *const PreparedCodeCache) bool {
    return self.active_executions != 0;
}

/// Returns a validated prepared entry, if present.
///
/// The returned pointer remains valid until `clearRetainingCapacity` or
/// `deinit`. In particular, inserting more entries cannot move it.
pub fn get(self: *PreparedCodeCache, code_hash: [32]u8) ?*Bytecode {
    const entry = self.entries.get(code_hash) orelse return null;
    return &entry.bytecode;
}

/// Returns an existing prepared entry or validates and owns `raw_code`.
///
/// The hash is computed only on cache admission. A hit trusts the invariant
/// established by the original insertion and does not inspect `raw_code`.
pub fn getOrPrepare(
    self: *PreparedCodeCache,
    expected_hash: [32]u8,
    raw_code: []const u8,
) !*Bytecode {
    if (self.get(expected_hash)) |prepared| return prepared;

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
        .bytecode = try Bytecode.initWithConfig(self.allocator, raw_code, self.config),
    };
    errdefer entry.bytecode.deinit(self.allocator);

    try self.entries.putNoClobber(expected_hash, entry);
    self.retained_code_bytes = new_retained_code_bytes;
    return &entry.bytecode;
}

pub fn count(self: *const PreparedCodeCache) usize {
    return self.entries.count();
}

/// Sum of the original semantic code lengths retained by cache entries.
pub fn retainedCodeBytes(self: *const PreparedCodeCache) usize {
    return self.retained_code_bytes;
}

/// Invalidates all returned pointers, retains hash-map capacity, and applies
/// `new_config` to subsequent cache admissions.
pub fn clearRetainingCapacity(
    self: *PreparedCodeCache,
    new_config: ExecutionConfig,
) !void {
    if (self.hasActiveExecution()) return error.ActivePreparedCodeExecution;
    self.clearEntriesRetainingCapacity();
    self.config = preparedConfig(new_config);
}

pub fn deinit(self: *PreparedCodeCache) void {
    std.debug.assert(!self.hasActiveExecution());
    self.clearEntriesRetainingCapacity();
    self.entries.deinit();
    self.* = undefined;
}

/// Cached bytecode is always execution-ready. `.none` remains valid for
/// transient preparation, but cache admission eagerly builds jump metadata so
/// a retained entry cannot allocate on its first JUMP in bounded execution.
fn preparedConfig(config: ExecutionConfig) ExecutionConfig {
    var result = config;
    if (result.preprocessing == .none) result.preprocessing = .jumpdest;
    return result;
}

fn clearEntriesRetainingCapacity(self: *PreparedCodeCache) void {
    var values = self.entries.valueIterator();
    while (values.next()) |entry_ptr| {
        const entry = entry_ptr.*;
        entry.bytecode.deinit(self.allocator);
        self.allocator.destroy(entry);
    }
    self.entries.clearRetainingCapacity();
    self.retained_code_bytes = 0;
}

test "wrong hash rejects admission atomically" {
    var cache = PreparedCodeCache.init(std.testing.allocator, .base);
    defer cache.deinit();

    const raw_code = [_]u8{ 0x60, 0x01, 0x00 };
    const wrong_hash = [_]u8{0xff} ** 32;
    try std.testing.expectError(
        error.CodeHashMismatch,
        cache.getOrPrepare(wrong_hash, &raw_code),
    );

    try std.testing.expectEqual(@as(usize, 0), cache.count());
    try std.testing.expectEqual(@as(usize, 0), cache.retainedCodeBytes());
    try std.testing.expect(cache.get(wrong_hash) == null);
}

test "prepared bytecode owns its source bytes" {
    var cache = PreparedCodeCache.init(std.testing.allocator, .base);
    defer cache.deinit();

    var raw_code = [_]u8{ 0x60, 0x01, 0x00 };
    const original = raw_code;
    const code_hash = crypto.keccak256(&raw_code);
    const prepared = try cache.getOrPrepare(code_hash, &raw_code);

    try std.testing.expect(prepared.bytes.ptr != raw_code[0..].ptr);
    @memset(&raw_code, 0xff);
    try std.testing.expectEqualSlices(u8, &original, prepared.bytes);
    try std.testing.expectEqual(original.len, cache.retainedCodeBytes());

    // Hits trust the validated entry rather than rehashing caller bytes.
    try std.testing.expectEqual(prepared, try cache.getOrPrepare(code_hash, &raw_code));
}

test "prepared pointers remain stable while the map grows" {
    var cache = PreparedCodeCache.init(std.testing.allocator, .base);
    defer cache.deinit();

    const anchor_code = [_]u8{ 0x60, 0x01, 0x5b, 0x00 };
    const anchor_hash = crypto.keccak256(&anchor_code);
    const anchor = try cache.getOrPrepare(anchor_hash, &anchor_code);
    const anchor_bytes_ptr = anchor.bytes.ptr;

    for (0..256) |index| {
        var code: [9]u8 = undefined;
        std.mem.writeInt(u64, code[0..8], @intCast(index), .big);
        code[8] = 0x00;
        const code_hash = crypto.keccak256(&code);
        _ = try cache.getOrPrepare(code_hash, &code);
    }

    try std.testing.expectEqual(@as(usize, 257), cache.count());
    try std.testing.expectEqual(anchor, cache.get(anchor_hash).?);
    try std.testing.expectEqual(anchor_bytes_ptr, anchor.bytes.ptr);
    try std.testing.expectEqualSlices(u8, &anchor_code, anchor.bytes);
}

test "cache admissions eagerly build jump metadata and clear updates config" {
    var cache = PreparedCodeCache.init(std.testing.allocator, .{ .preprocessing = .none });
    defer cache.deinit();

    const first_code = [_]u8{ 0x5b, 0x00 };
    const first = try cache.getOrPrepare(crypto.keccak256(&first_code), &first_code);
    try std.testing.expect(first.jumpdests.analyzed);
    try std.testing.expectEqual(ExecutionConfig.JumpDestStrategy.scalar_bitmask, first.jumpdests.strategy);

    try cache.clearRetainingCapacity(.{ .jumpdest_strategy = .simd_bitmask });
    try std.testing.expectEqual(@as(usize, 0), cache.count());
    try std.testing.expectEqual(@as(usize, 0), cache.retainedCodeBytes());

    const second_code = [_]u8{ 0x60, 0x00, 0x5b };
    const second = try cache.getOrPrepare(crypto.keccak256(&second_code), &second_code);
    try std.testing.expect(second.jumpdests.analyzed);
    try std.testing.expectEqual(
        ExecutionConfig.JumpDestStrategy.simd_bitmask,
        second.jumpdests.strategy,
    );
}

test "active execution rejects cache invalidation" {
    var cache = PreparedCodeCache.init(std.testing.allocator, .base);
    defer cache.deinit();

    const code = [_]u8{0x00};
    _ = try cache.getOrPrepare(crypto.keccak256(&code), &code);

    cache.beginExecution();
    try std.testing.expectError(
        error.ActivePreparedCodeExecution,
        cache.clearRetainingCapacity(.base),
    );
    try std.testing.expectEqual(@as(usize, 1), cache.count());
    cache.endExecution();

    try cache.clearRetainingCapacity(.base);
    try std.testing.expectEqual(@as(usize, 0), cache.count());
}
