//! Block-lifetime prepared-code cache layered over the static system artifacts.
//!
//! Witness code is prepared once per block per code hash instead of once per
//! transaction touch; admission re-verifies the hash before retention. System
//! contract hashes keep resolving from the comptime artifacts even when the
//! witness omits their bytes.

const std = @import("std");
const Backend = @import("../prepared_code/Backend.zig");
const InMemoryPreparedPool = @import("../prepared_code/InMemoryPreparedPool.zig");
const Bytecode = @import("../code/Bytecode.zig");
const system_prepared_code = @import("system_prepared_code.zig");

const BlockPreparedCode = @This();

pool: InMemoryPreparedPool,

pub fn init(allocator: std.mem.Allocator) BlockPreparedCode {
    return .{ .pool = InMemoryPreparedPool.init(allocator) };
}

pub fn deinit(self: *BlockPreparedCode) void {
    self.pool.deinit();
}

pub fn backend(self: *BlockPreparedCode) Backend {
    return .{ .ptr = self, .vtable = &vtable };
}

const vtable = Backend.VTable{
    .beginExecution = beginExecution,
    .endExecution = endExecution,
    .lookup = lookup,
    .admit = admit,
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

const crypto = @import("../crypto.zig");

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

test "admission rejects code that does not match its hash" {
    var block_pool = BlockPreparedCode.init(std.testing.allocator);
    defer block_pool.deinit();

    const raw_code = [_]u8{ 0x60, 0x01, 0x00 };
    try std.testing.expectError(
        error.CodeHashMismatch,
        block_pool.backend().admit([_]u8{0xff} ** 32, &raw_code),
    );
}
