const std = @import("std");
const Cache = @import("Cache.zig");
const Map = @import("Map.zig");

const State = @This();

local: Map,
cache_entry: ?*Cache.Entry,

pub const empty = State{
    .local = .empty,
    .cache_entry = null,
};

pub fn init(cache: ?*Cache, bytes: []const u8) !State {
    return .{
        .local = .empty,
        .cache_entry = if (cache) |jumpdest_cache| try jumpdest_cache.getOrPut(bytes) else null,
    };
}

pub fn deinit(self: *State, allocator: std.mem.Allocator) void {
    self.local.deinit(allocator);
    self.* = empty;
}

pub fn isValid(self: *State, allocator: std.mem.Allocator, bytes: []const u8, target: usize) !bool {
    if (self.cache_entry) |entry| {
        return try entry.isValid(allocator, target);
    }

    return try self.local.isValid(allocator, bytes, target);
}
