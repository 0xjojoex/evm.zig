//! Hash map for retained-capacity state that must clear by live entries.

const std = @import("std");

const default_max_load_percentage = 80;

pub fn Auto(comptime K: type, comptime V: type) type {
    return WithContext(K, V, std.hash_map.AutoContext(K));
}

pub fn WithContext(comptime K: type, comptime V: type, comptime Context: type) type {
    return struct {
        const Self = @This();
        const Index = u32;
        const empty_slot: Index = 0;

        const Row = struct {
            key: K,
            value: V,
            slot: Index,
        };

        pub const Entry = struct {
            key_ptr: *K,
            value_ptr: *V,
        };

        pub const KV = struct {
            key: K,
            value: V,
        };

        pub const GetOrPutResult = struct {
            key_ptr: *K,
            value_ptr: *V,
            found_existing: bool,
        };

        pub const KeyIterator = struct {
            entries: []Row,
            index: usize = 0,

            pub fn next(self: *KeyIterator) ?*K {
                if (self.index >= self.entries.len) return null;
                defer self.index += 1;
                return &self.entries[self.index].key;
            }
        };

        pub const Iterator = struct {
            entries: []Row,
            index: usize = 0,

            pub fn next(self: *Iterator) ?Entry {
                if (self.index >= self.entries.len) return null;
                defer self.index += 1;
                return .{
                    .key_ptr = &self.entries[self.index].key,
                    .value_ptr = &self.entries[self.index].value,
                };
            }
        };

        pub const ValueIterator = struct {
            entries: []Row,
            index: usize = 0,

            pub fn next(self: *ValueIterator) ?*V {
                if (self.index >= self.entries.len) return null;
                defer self.index += 1;
                return &self.entries[self.index].value;
            }
        };

        allocator: std.mem.Allocator,
        context: Context,
        index: []Index,
        entries: []Row,
        len: Index,

        pub fn init(allocator: std.mem.Allocator) Self {
            if (@sizeOf(Context) != 0) {
                @compileError("Context must be zero-sized; add initContext if a stateful context is needed");
            }
            return .{
                .allocator = allocator,
                .context = undefined,
                .index = &.{},
                .entries = &.{},
                .len = 0,
            };
        }

        pub fn deinit(self: *Self) void {
            self.allocator.free(self.index);
            self.allocator.free(self.entries);
            self.* = init(self.allocator);
        }

        pub fn count(self: Self) Index {
            return self.len;
        }

        pub fn capacity(self: Self) Index {
            return std.math.cast(Index, self.entries.len) orelse std.math.maxInt(Index);
        }

        pub fn contains(self: Self, key: K) bool {
            return self.findSlot(key) != null;
        }

        pub fn get(self: Self, key: K) ?V {
            const slot = self.findSlot(key) orelse return null;
            return self.entries[self.index[slot] - 1].value;
        }

        pub fn getPtr(self: *Self, key: K) ?*V {
            const slot = self.findSlot(key) orelse return null;
            return &self.entries[self.index[slot] - 1].value;
        }

        pub fn keyIterator(self: *Self) KeyIterator {
            return .{ .entries = self.entries[0..self.len] };
        }

        pub fn iterator(self: *Self) Iterator {
            return .{ .entries = self.entries[0..self.len] };
        }

        pub fn valueIterator(self: *Self) ValueIterator {
            return .{ .entries = self.entries[0..self.len] };
        }

        pub fn ensureUnusedCapacity(self: *Self, additional_count: Index) !void {
            const needed = try std.math.add(Index, self.len, additional_count);
            try self.ensureTotalCapacity(needed);
        }

        pub fn ensureTotalCapacity(self: *Self, expected_count: Index) !void {
            if (expected_count <= self.entries.len and slotsCanFit(self.index.len, expected_count)) return;
            try self.realloc(expected_count);
        }

        pub fn put(self: *Self, key: K, value: V) !void {
            if (self.getPtr(key)) |existing| {
                existing.* = value;
                return;
            }
            try self.ensureUnusedCapacity(1);
            self.putAssumeCapacityNoClobber(key, value);
        }

        pub fn getOrPut(self: *Self, key: K) !GetOrPutResult {
            if (self.findSlot(key)) |slot| {
                const entry = &self.entries[self.index[slot] - 1];
                return .{
                    .key_ptr = &entry.key,
                    .value_ptr = &entry.value,
                    .found_existing = true,
                };
            }
            try self.ensureUnusedCapacity(1);
            return self.getOrPutAssumeCapacity(key);
        }

        pub fn putAssumeCapacity(self: *Self, key: K, value: V) void {
            const result = self.getOrPutAssumeCapacity(key);
            result.value_ptr.* = value;
        }

        pub fn putAssumeCapacityNoClobber(self: *Self, key: K, value: V) void {
            const result = self.getOrPutAssumeCapacity(key);
            std.debug.assert(!result.found_existing);
            result.value_ptr.* = value;
        }

        pub fn getOrPutAssumeCapacity(self: *Self, key: K) GetOrPutResult {
            std.debug.assert(self.index.len != 0);

            if (self.findSlotForInsert(key)) |slot| {
                const stored = self.index[slot];
                if (stored != empty_slot) {
                    const entry = &self.entries[stored - 1];
                    return .{
                        .key_ptr = &entry.key,
                        .value_ptr = &entry.value,
                        .found_existing = true,
                    };
                }

                std.debug.assert(self.len < self.entries.len);
                const entry_index = self.len;
                self.len += 1;
                self.index[slot] = entry_index + 1;
                self.entries[entry_index] = .{
                    .key = key,
                    .value = undefined,
                    .slot = @intCast(slot),
                };
                return .{
                    .key_ptr = &self.entries[entry_index].key,
                    .value_ptr = &self.entries[entry_index].value,
                    .found_existing = false,
                };
            }

            unreachable;
        }

        pub fn remove(self: *Self, key: K) bool {
            const slot = self.findSlot(key) orelse return false;
            self.removeSlot(slot);
            return true;
        }

        pub fn fetchRemove(self: *Self, key: K) ?KV {
            const slot = self.findSlot(key) orelse return null;
            const entry_index = self.index[slot] - 1;
            const result = KV{
                .key = self.entries[entry_index].key,
                .value = self.entries[entry_index].value,
            };
            self.removeSlot(slot);
            return result;
        }

        pub fn clearRetainingCapacity(self: *Self) void {
            for (self.entries[0..self.len]) |entry| {
                self.index[entry.slot] = empty_slot;
            }
            self.len = 0;
        }

        pub fn debugOccupiedSlots(self: Self) usize {
            var occupied: usize = 0;
            for (self.index) |slot| {
                if (slot != empty_slot) occupied += 1;
            }
            return occupied;
        }

        fn realloc(self: *Self, expected_count: Index) !void {
            const entry_capacity = expected_count;
            const slot_count = try slotCountForCapacity(entry_capacity);

            var new_index = try self.allocator.alloc(Index, slot_count);
            errdefer self.allocator.free(new_index);
            @memset(new_index, empty_slot);

            const new_entries = try self.allocator.alloc(Row, entry_capacity);
            errdefer self.allocator.free(new_entries);

            for (self.entries[0..self.len], 0..) |entry, i| {
                new_entries[i] = entry;
                const slot = findEmptySlotIn(new_index, self.context.hash(entry.key));
                new_index[slot] = @as(Index, @intCast(i)) + 1;
                new_entries[i].slot = @intCast(slot);
            }

            self.allocator.free(self.index);
            self.allocator.free(self.entries);
            self.index = new_index;
            self.entries = new_entries;
        }

        fn removeSlot(self: *Self, slot: usize) void {
            const removed_entry_index = self.index[slot] - 1;
            self.index[slot] = empty_slot;
            self.reinsertClusterAfterRemove(slot);

            const last_entry_index = self.len - 1;
            if (removed_entry_index != last_entry_index) {
                self.entries[removed_entry_index] = self.entries[last_entry_index];
                self.index[self.entries[removed_entry_index].slot] = removed_entry_index + 1;
            }
            self.len = last_entry_index;
        }

        fn reinsertClusterAfterRemove(self: *Self, removed_slot: usize) void {
            var slot = nextSlot(removed_slot, self.index.len);
            while (self.index[slot] != empty_slot) : (slot = nextSlot(slot, self.index.len)) {
                const entry_index = self.index[slot] - 1;
                self.index[slot] = empty_slot;
                const new_slot = findEmptySlotIn(self.index, self.context.hash(self.entries[entry_index].key));
                self.index[new_slot] = entry_index + 1;
                self.entries[entry_index].slot = @intCast(new_slot);
            }
        }

        fn findSlot(self: Self, key: K) ?usize {
            if (self.index.len == 0) return null;
            var slot = homeSlot(self.index.len, self.context.hash(key));
            while (self.index[slot] != empty_slot) : (slot = nextSlot(slot, self.index.len)) {
                const entry = &self.entries[self.index[slot] - 1];
                if (self.context.eql(key, entry.key)) return slot;
            }
            return null;
        }

        fn findSlotForInsert(self: Self, key: K) ?usize {
            var slot = homeSlot(self.index.len, self.context.hash(key));
            while (self.index[slot] != empty_slot) : (slot = nextSlot(slot, self.index.len)) {
                const entry = &self.entries[self.index[slot] - 1];
                if (self.context.eql(key, entry.key)) return slot;
            }
            return slot;
        }

        fn findEmptySlotIn(index: []Index, hash: u64) usize {
            var slot = homeSlot(index.len, hash);
            while (index[slot] != empty_slot) : (slot = nextSlot(slot, index.len)) {}
            return slot;
        }

        fn homeSlot(slot_count: usize, hash: u64) usize {
            std.debug.assert(slot_count != 0);
            std.debug.assert(std.math.isPowerOfTwo(slot_count));
            return @as(usize, @intCast(hash)) & (slot_count - 1);
        }

        fn nextSlot(slot: usize, slot_count: usize) usize {
            return (slot + 1) & (slot_count - 1);
        }

        fn slotsCanFit(slot_count: usize, expected_count: Index) bool {
            if (expected_count == 0) return true;
            if (slot_count == 0) return false;
            return expected_count <= slot_count * default_max_load_percentage / 100;
        }

        fn slotCountForCapacity(entry_capacity: Index) !usize {
            if (entry_capacity == 0) return 0;
            const needed = try std.math.add(
                usize,
                try std.math.divCeil(usize, @as(usize, entry_capacity) * 100, default_max_load_percentage),
                1,
            );
            return std.math.ceilPowerOfTwo(usize, needed) catch error.CapacityTooLarge;
        }
    };
}

test "touched hash map clears only live slots" {
    var map = Auto(u64, void).init(std.testing.allocator);
    defer map.deinit();

    try map.ensureTotalCapacity(1024);
    try map.put(1, {});
    try map.put(2, {});
    try std.testing.expectEqual(@as(usize, 2), map.debugOccupiedSlots());

    map.clearRetainingCapacity();
    try std.testing.expectEqual(@as(u32, 0), map.count());
    try std.testing.expectEqual(@as(usize, 0), map.debugOccupiedSlots());
    try std.testing.expect(!map.contains(1));

    try map.put(3, {});
    try std.testing.expect(map.contains(3));
    try std.testing.expectEqual(@as(usize, 1), map.debugOccupiedSlots());
}

test "touched hash map removal preserves probe clusters" {
    const BadContext = struct {
        pub fn hash(_: @This(), _: u64) u64 {
            return 0;
        }

        pub fn eql(_: @This(), a: u64, b: u64) bool {
            return a == b;
        }
    };

    var map = WithContext(u64, u64, BadContext).init(std.testing.allocator);
    defer map.deinit();

    try map.ensureTotalCapacity(8);
    for (0..6) |i| {
        try map.put(@intCast(i), @intCast(i + 100));
    }

    try std.testing.expect(map.remove(2));
    try std.testing.expect(!map.contains(2));
    try std.testing.expectEqual(@as(?u64, 100), map.get(0));
    try std.testing.expectEqual(@as(?u64, 101), map.get(1));
    try std.testing.expectEqual(@as(?u64, 103), map.get(3));
    try std.testing.expectEqual(@as(?u64, 104), map.get(4));
    try std.testing.expectEqual(@as(?u64, 105), map.get(5));

    try map.put(6, 106);
    try std.testing.expectEqual(@as(?u64, 106), map.get(6));
}
