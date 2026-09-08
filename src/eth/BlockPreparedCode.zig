//! Block-lifetime prepared-code cache layered over the static system artifacts.
//!
//! Witness code is prepared once per block per code instead of once per
//! transaction touch; admission re-verifies the hash before retention. System
//! contract hashes keep resolving from the comptime artifacts even when the
//! witness omits their bytes.
//!
//! Dense slots cache the latest hash and view for each state `CodeRef`.
//! Hits avoid hashing; misses reuse or prepare an artifact in the shared
//! hash-keyed pool. The pool owns one artifact per hash until block teardown,
//! so reassigning a ref after rollback neither duplicates code nor invalidates
//! views held by active executions. Pool admission remains hash-keyed and does
//! not provide an adversarial probe bound.

const std = @import("std");
const Backend = @import("../prepared_code/Backend.zig");
const InMemoryPreparedPool = @import("../prepared_code/InMemoryPreparedPool.zig");
const Bytecode = @import("../code/Bytecode.zig");
const CodeRef = @import("../state.zig").CodeRef;
const crypto = @import("../crypto.zig");
const system_prepared_code = @import("system_prepared_code.zig");

const BlockPreparedCode = @This();

/// One dense slot. The hash is checked on every hit: an introduced index is
/// reassigned to different bytes after a revert, and the old artifact must
/// stay alive because a memo in an active execution may still point at it.
const IndexedEntry = struct {
    hash: [32]u8,
    view: Bytecode.View,
};

allocator: std.mem.Allocator,
/// Owns all dynamic artifacts, including views cached in `indexed`.
pool: InMemoryPreparedPool,
indexed: std.ArrayList(?IndexedEntry) = .empty,

pub fn init(allocator: std.mem.Allocator) BlockPreparedCode {
    return .{ .allocator = allocator, .pool = InMemoryPreparedPool.init(allocator) };
}

pub fn deinit(self: *BlockPreparedCode) void {
    self.pool.deinit();
    self.indexed.deinit(self.allocator);
    self.* = undefined;
}

pub fn backend(self: *BlockPreparedCode) Backend {
    return .{ .ptr = self, .vtable = &vtable };
}

fn getIndexed(self: *const BlockPreparedCode, index: u32, code_hash: [32]u8) ?Bytecode.View {
    if (index >= self.indexed.items.len) return null;
    const entry = self.indexed.items[index] orelse return null;
    if (!std.mem.eql(u8, &entry.hash, &code_hash)) return null;
    return entry.view;
}

fn prepareIndexed(
    self: *BlockPreparedCode,
    index: u32,
    code_hash: [32]u8,
    raw_code: []const u8,
) !Bytecode.View {
    if (self.getIndexed(index, code_hash)) |prepared| return prepared;
    if (index >= CodeRef.max_indexed) return error.ResourceLimitExceeded;

    const slot: usize = index;
    if (slot >= self.indexed.items.len) {
        try self.indexed.ensureTotalCapacity(self.allocator, slot + 1);
        self.indexed.appendNTimesAssumeCapacity(null, slot + 1 - self.indexed.items.len);
    }

    // A system contract's bytes arrive through the witness like any other
    // parent code, but its artifact is comptime-prepared: seed the slot from
    // the static table instead of hashing and analysing the bytes again. The
    // hash matched a compile-time constant, so no re-verification is needed.
    if (try system_prepared_code.backend().lookup(code_hash)) |static_view| {
        self.indexed.items[slot] = .{ .hash = code_hash, .view = static_view };
        return static_view;
    }

    const view = try self.pool.getOrPrepare(code_hash, raw_code);
    self.indexed.items[slot] = .{ .hash = code_hash, .view = view };
    return view;
}

const vtable = Backend.VTable{
    .beginExecution = beginExecution,
    .endExecution = endExecution,
    .lookup = lookup,
    .admit = admit,
    .lookupIndexed = lookupIndexed,
    .admitIndexed = admitIndexed,
};

fn beginExecution(ptr: *anyopaque) !void {
    const self: *BlockPreparedCode = @ptrCast(@alignCast(ptr));
    self.pool.beginExecution();
}

fn endExecution(ptr: *anyopaque) void {
    const self: *BlockPreparedCode = @ptrCast(@alignCast(ptr));
    self.pool.endExecution();
}

fn lookup(ptr: *anyopaque, code_hash: [32]u8) !?Bytecode.View {
    const self: *BlockPreparedCode = @ptrCast(@alignCast(ptr));
    if (try system_prepared_code.backend().lookup(code_hash)) |view| return view;
    return self.pool.get(code_hash);
}

fn admit(ptr: *anyopaque, code_hash: [32]u8, raw_code: []const u8) !?Bytecode.View {
    const self: *BlockPreparedCode = @ptrCast(@alignCast(ptr));
    return try self.pool.getOrPrepare(code_hash, raw_code);
}

fn lookupIndexed(ptr: *anyopaque, index: u32, code_hash: [32]u8) ?Bytecode.View {
    const self: *BlockPreparedCode = @ptrCast(@alignCast(ptr));
    return self.getIndexed(index, code_hash);
}

fn admitIndexed(ptr: *anyopaque, index: u32, code_hash: [32]u8, raw_code: []const u8) !?Bytecode.View {
    const self: *BlockPreparedCode = @ptrCast(@alignCast(ptr));
    return try self.prepareIndexed(index, code_hash, raw_code);
}

test "system hashes resolve statically without admission" {
    var block_pool = BlockPreparedCode.init(std.testing.allocator);
    defer block_pool.deinit();

    const view = (try block_pool.backend().lookup(
        crypto.keccak256(&system_prepared_code.beacon_roots_code),
    )).?;
    try std.testing.expectEqualSlices(u8, &system_prepared_code.beacon_roots_code, view.bytes);
    try std.testing.expectEqual(@as(usize, 0), block_pool.pool.count());
}

test "admitted code is retained across execution scopes" {
    var block_pool = BlockPreparedCode.init(std.testing.allocator);
    defer block_pool.deinit();
    const be = block_pool.backend();

    const raw_code = [_]u8{ 0x60, 0x01, 0x5b, 0x00 };
    const code_hash = crypto.keccak256(&raw_code);

    try be.beginExecution();
    try std.testing.expectEqual(@as(?Bytecode.View, null), try be.lookup(code_hash));
    const admitted = (try be.admit(code_hash, &raw_code)).?;
    be.endExecution();

    try be.beginExecution();
    const retained = (try be.lookup(code_hash)).?;
    be.endExecution();

    try std.testing.expectEqual(admitted.bytes.ptr, retained.bytes.ptr);
    try std.testing.expectEqual(@as(usize, 1), block_pool.pool.count());
}

test "indexed lane caches dense slots over the shared artifact pool" {
    var block_pool = BlockPreparedCode.init(std.testing.allocator);
    defer block_pool.deinit();
    const be = block_pool.backend();
    try std.testing.expect(be.supportsIndexed());

    const raw_code = [_]u8{ 0x60, 0x01, 0x5b, 0x00 };
    const code_hash = crypto.keccak256(&raw_code);

    try be.beginExecution();
    try std.testing.expectEqual(@as(?Bytecode.View, null), be.lookupIndexed(7, code_hash));
    const admitted = (try be.admitIndexed(7, code_hash, &raw_code)).?;
    be.endExecution();

    try be.beginExecution();
    const retained = be.lookupIndexed(7, code_hash).?;
    be.endExecution();
    try std.testing.expectEqual(admitted.bytes.ptr, retained.bytes.ptr);

    // Other dense slots are empty, but hash lookup finds the shared owner.
    try std.testing.expectEqual(@as(?Bytecode.View, null), be.lookupIndexed(3, code_hash));
    try std.testing.expectEqual(@as(?Bytecode.View, null), be.lookupIndexed(8, code_hash));
    try std.testing.expectEqual(admitted.bytes.ptr, (try be.lookup(code_hash)).?.bytes.ptr);
    const other_slot = (try be.admitIndexed(8, code_hash, &raw_code)).?;
    try std.testing.expectEqual(admitted.bytes.ptr, other_slot.bytes.ptr);
    try std.testing.expectEqual(@as(usize, 1), block_pool.pool.count());
}

test "indexed slot reassigned after a revert serves the new bytes and keeps the old artifact alive" {
    var block_pool = BlockPreparedCode.init(std.testing.allocator);
    defer block_pool.deinit();
    const be = block_pool.backend();

    const first_code = [_]u8{ 0x60, 0x01, 0x00 };
    const second_code = [_]u8{ 0x60, 0x02, 0x00 };
    const first_hash = crypto.keccak256(&first_code);
    const second_hash = crypto.keccak256(&second_code);

    const first = (try be.admitIndexed(0, first_hash, &first_code)).?;
    // The revert-and-recreate shape: the same dense index now names other bytes.
    try std.testing.expectEqual(@as(?Bytecode.View, null), be.lookupIndexed(0, second_hash));
    const second = (try be.admitIndexed(0, second_hash, &second_code)).?;
    try std.testing.expect(first.bytes.ptr != second.bytes.ptr);
    try std.testing.expectEqualSlices(u8, &first_code, first.bytes);
    try std.testing.expectEqualSlices(u8, &second_code, second.bytes);
    try std.testing.expectEqual(@as(?Bytecode.View, null), be.lookupIndexed(0, first_hash));
    try std.testing.expectEqual(second.bytes.ptr, be.lookupIndexed(0, second_hash).?.bytes.ptr);
    try std.testing.expectEqual(@as(usize, 2), block_pool.pool.count());
}

test "indexed lane seeds system contract slots from the static artifacts" {
    var block_pool = BlockPreparedCode.init(std.testing.allocator);
    defer block_pool.deinit();
    const be = block_pool.backend();

    const code_hash = crypto.keccak256(&system_prepared_code.beacon_roots_code);
    const static_view = (try system_prepared_code.backend().lookup(code_hash)).?;
    const admitted = (try be.admitIndexed(4, code_hash, &system_prepared_code.beacon_roots_code)).?;
    try std.testing.expectEqual(static_view.bytes.ptr, admitted.bytes.ptr);
    try std.testing.expectEqual(static_view.bytes.ptr, be.lookupIndexed(4, code_hash).?.bytes.ptr);
    try std.testing.expectEqual(@as(usize, 0), block_pool.pool.count());
}

test "indexed admission rejects a wrong hash atomically" {
    var block_pool = BlockPreparedCode.init(std.testing.allocator);
    defer block_pool.deinit();
    const be = block_pool.backend();

    const raw_code = [_]u8{ 0x60, 0x01, 0x00 };
    const wrong_hash = [_]u8{0xff} ** 32;
    try std.testing.expectError(error.CodeHashMismatch, be.admitIndexed(2, wrong_hash, &raw_code));
    try std.testing.expectEqual(@as(usize, 0), block_pool.pool.count());
    try std.testing.expectEqual(@as(?Bytecode.View, null), be.lookupIndexed(2, wrong_hash));

    const code_hash = crypto.keccak256(&raw_code);
    const retained = (try be.admitIndexed(2, code_hash, &raw_code)).?;
    try std.testing.expectError(error.CodeHashMismatch, be.admitIndexed(2, wrong_hash, &raw_code));
    try std.testing.expectEqual(retained.bytes.ptr, be.lookupIndexed(2, code_hash).?.bytes.ptr);
    try std.testing.expectEqual(@as(usize, 1), block_pool.pool.count());
    try std.testing.expectEqual(raw_code.len, block_pool.pool.retained_code_bytes);
}

test "reverted code refs reuse retained artifacts across executions" {
    const CodeStore = @import("bal/claim_artifacts.zig").CodeStore;
    const Execution = @import("../prepared_code/Execution.zig");
    var store = try CodeStore.init(std.testing.allocator, &.{});
    defer store.deinit(std.testing.allocator);
    var block_pool = BlockPreparedCode.init(std.testing.allocator);
    defer block_pool.deinit();

    const codes = [_][24_576]u8{ @splat(0x00), @splat(0x5b) };
    var retained: [2]Bytecode.View = undefined;
    for (0..100) |iteration| {
        const which = iteration % codes.len;
        const cached = try store.cacheIntroduced(std.testing.allocator, &codes[which]);
        try std.testing.expectEqual(CodeRef.fromIndex(0), cached.ref);
        var execution = Execution.init(std.testing.allocator, block_pool.backend());
        defer execution.deinit();
        const prepared = try execution.resolve(
            cached.view.code_hash,
            cached.view.bytes,
            @intFromEnum(cached.ref),
            .{},
        );
        if (iteration < codes.len) {
            retained[which] = prepared;
        } else {
            try std.testing.expectEqual(retained[which].bytes.ptr, prepared.bytes.ptr);
            try std.testing.expectEqual(retained[which].jumpdest_masks, prepared.jumpdest_masks);
        }
        // Rollback releases the state's raw bytes, even while execution views live.
        store.truncateIntroduced(std.testing.allocator, 0);
        try std.testing.expectEqualSlices(u8, &codes[which], prepared.bytes);
    }
    for (retained, codes) |view, code| try std.testing.expectEqualSlices(u8, &code, view.bytes);
    try std.testing.expectEqual(@as(usize, 2), block_pool.pool.count());
    try std.testing.expectEqual(@as(usize, 49_152), block_pool.pool.retained_code_bytes);
}

test "indexed admission reuses code first admitted by hash" {
    var block_pool = BlockPreparedCode.init(std.testing.allocator);
    defer block_pool.deinit();
    const be = block_pool.backend();
    const raw_code = [_]u8{ 0x60, 0x01, 0x5b, 0x00 };
    const code_hash = crypto.keccak256(&raw_code);
    const by_hash = (try be.admit(code_hash, &raw_code)).?;
    const by_index = (try be.admitIndexed(0, code_hash, &raw_code)).?;
    try std.testing.expectEqual(by_hash.bytes.ptr, by_index.bytes.ptr);
    try std.testing.expectEqual(by_hash.jumpdest_masks, by_index.jumpdest_masks);
    try std.testing.expectEqual(@as(usize, 1), block_pool.pool.count());
}
