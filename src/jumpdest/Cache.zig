const std = @import("std");
const JumpDestMap = @import("Map.zig");
const Opcode = @import("../opcode.zig").Opcode;

const JumpDestCache = @This();

const max_entries = 64;
const max_cached_code_bytes = 4 * 1024 * 1024;
const min_cached_code_bytes = 64;
const cache_admission_sample_bytes = 64;
const jumpdest_opcode = @intFromEnum(Opcode.JUMPDEST);
const push1_opcode = @intFromEnum(Opcode.PUSH1);
const push32_opcode = @intFromEnum(Opcode.PUSH32);

pub const Entry = struct {
    hash: u64,
    bytes: []u8,
    map: JumpDestMap,

    pub fn isValid(self: *Entry, allocator: std.mem.Allocator, target: usize) !bool {
        return self.map.isValid(allocator, self.bytes, target);
    }

    fn deinit(self: *Entry, allocator: std.mem.Allocator) void {
        allocator.free(self.bytes);
        self.map.deinit(allocator);
        self.* = undefined;
    }
};

allocator: std.mem.Allocator,
entries: [max_entries]Entry,
len: usize,
cached_code_bytes: usize,

pub fn init(allocator: std.mem.Allocator) JumpDestCache {
    return .{
        .allocator = allocator,
        .entries = undefined,
        .len = 0,
        .cached_code_bytes = 0,
    };
}

pub fn deinit(self: *JumpDestCache) void {
    for (self.entries[0..self.len]) |*entry| {
        entry.deinit(self.allocator);
    }
    self.* = undefined;
}

pub fn accepts(bytes: []const u8) bool {
    return bytes.len >= min_cached_code_bytes and shouldCacheContent(bytes);
}

pub fn isValid(self: *JumpDestCache, bytes: []const u8, target: usize) !?bool {
    if (target >= bytes.len or bytes[target] != jumpdest_opcode) {
        return false;
    }
    const entry = try self.getOrPut(bytes) orelse return null;
    return try entry.isValid(self.allocator, target);
}

pub fn getOrPut(self: *JumpDestCache, bytes: []const u8) !?*Entry {
    if (!accepts(bytes)) return null;

    const hash = std.hash.Wyhash.hash(0, bytes);
    if (self.find(hash, bytes)) |entry| return entry;
    if (!self.canAdd(bytes.len)) return null;
    return try self.putNew(hash, bytes);
}

fn canAdd(self: *const JumpDestCache, byte_len: usize) bool {
    if (self.len >= max_entries) return false;
    if (byte_len > max_cached_code_bytes - self.cached_code_bytes) return false;
    return true;
}

fn shouldCacheContent(bytes: []const u8) bool {
    const sample_len = @min(bytes.len, cache_admission_sample_bytes);
    var interesting: usize = 0;
    for (bytes[0..sample_len]) |byte| {
        interesting += @intFromBool(byte == jumpdest_opcode or isPush(byte));
    }
    return interesting > sample_len / 4;
}

fn isPush(opcode: u8) bool {
    return opcode >= push1_opcode and opcode <= push32_opcode;
}

fn find(self: *JumpDestCache, hash: u64, bytes: []const u8) ?*Entry {
    for (self.entries[0..self.len]) |*entry| {
        if (entry.hash == hash and std.mem.eql(u8, entry.bytes, bytes)) {
            return entry;
        }
    }
    return null;
}

fn putNew(self: *JumpDestCache, hash: u64, bytes: []const u8) !*Entry {
    const owned = try self.allocator.dupe(u8, bytes);
    errdefer self.allocator.free(owned);

    const entry = &self.entries[self.len];
    entry.* = .{
        .hash = hash,
        .bytes = owned,
        .map = .empty,
    };
    self.len += 1;
    self.cached_code_bytes += owned.len;
    return entry;
}

test "jumpdest cache reuses analysis by bytecode content" {
    var cache = JumpDestCache.init(std.testing.allocator);
    defer cache.deinit();

    const bytecode = [_]u8{ 0x60, 0x5b, 0x5b };

    try std.testing.expectEqual(@as(?bool, null), try cache.isValid(&bytecode, 1));
    try std.testing.expectEqual(@as(?bool, null), try cache.isValid(&bytecode, 2));
}

test "jumpdest cache caches larger bytecode" {
    var cache = JumpDestCache.init(std.testing.allocator);
    defer cache.deinit();

    var bytecode = [_]u8{@intFromEnum(Opcode.JUMPDEST)} ** min_cached_code_bytes;

    try std.testing.expectEqual(@as(?bool, true), try cache.isValid(&bytecode, min_cached_code_bytes - 1));
    try std.testing.expectEqual(@as(usize, 1), cache.len);
    try std.testing.expectEqual(@as(?bool, true), try cache.isValid(&bytecode, min_cached_code_bytes - 1));
    try std.testing.expectEqual(@as(usize, 1), cache.len);
}

test "jumpdest cache skips sparse bytecode" {
    var cache = JumpDestCache.init(std.testing.allocator);
    defer cache.deinit();

    var bytecode = [_]u8{0} ** min_cached_code_bytes;
    bytecode[min_cached_code_bytes - 1] = @intFromEnum(Opcode.JUMPDEST);

    try std.testing.expectEqual(@as(?bool, null), try cache.isValid(&bytecode, min_cached_code_bytes - 1));
    try std.testing.expectEqual(@as(usize, 0), cache.len);
}
