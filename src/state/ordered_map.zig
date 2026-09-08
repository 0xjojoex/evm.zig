//! Ordered map over a height-balanced (AVL) tree in one dense node arena.
//!
//! Guarantees logarithmic lookup and insertion regardless of key order
//! indexes survive backing-array growth.
//!
//! Deliberately small API, mirroring the subset of `sparse_hash_map` the
//! state machine uses: `get`, `ensureUnusedCapacity` + `putAssumeCapacity`,
//! `count`, `clearRetainingCapacity`, `allocationBytes`.

const std = @import("std");

pub fn OrderedMap(
    comptime K: type,
    comptime V: type,
    comptime orderFn: fn (K, K) std.math.Order,
) type {
    return struct {
        const Self = @This();
        const none: u32 = std.math.maxInt(u32);

        const Node = struct {
            key: K,
            value: V,
            left: u32,
            right: u32,
            height: u8,
        };

        allocator: std.mem.Allocator,
        nodes: std.ArrayList(Node) = .empty,
        root: u32 = none,

        pub fn init(allocator: std.mem.Allocator) Self {
            return .{ .allocator = allocator };
        }

        pub fn deinit(self: *Self) void {
            self.nodes.deinit(self.allocator);
            self.* = undefined;
        }

        pub fn count(self: *const Self) usize {
            return self.nodes.items.len;
        }

        pub fn allocationBytes(self: *const Self) usize {
            return self.nodes.capacity * @sizeOf(Node);
        }

        pub fn clearRetainingCapacity(self: *Self) void {
            self.nodes.clearRetainingCapacity();
            self.root = none;
        }

        pub fn get(self: *const Self, key: K) ?V {
            var index = self.root;
            while (index != none) {
                const node = &self.nodes.items[index];
                switch (orderFn(key, node.key)) {
                    .eq => return node.value,
                    .lt => index = node.left,
                    .gt => index = node.right,
                }
            }
            return null;
        }

        pub fn ensureUnusedCapacity(self: *Self, additional: usize) std.mem.Allocator.Error!void {
            try self.nodes.ensureUnusedCapacity(self.allocator, additional);
        }

        /// Insert or overwrite. Asserts one free node of capacity for the
        /// insert case.
        pub fn putAssumeCapacity(self: *Self, key: K, value: V) void {
            var index = self.root;
            while (index != none) {
                const node = &self.nodes.items[index];
                switch (orderFn(key, node.key)) {
                    .eq => {
                        node.value = value;
                        return;
                    },
                    .lt => index = node.left,
                    .gt => index = node.right,
                }
            }
            std.debug.assert(self.nodes.items.len < self.nodes.capacity);
            std.debug.assert(self.nodes.items.len < none);
            const fresh: u32 = @intCast(self.nodes.items.len);
            self.nodes.appendAssumeCapacity(.{
                .key = key,
                .value = value,
                .left = none,
                .right = none,
                .height = 1,
            });
            self.root = self.insertBalanced(self.root, fresh);
        }

        /// Rebuild the path from `index` down to where `fresh` belongs. The key
        /// is known absent, so this only descends and rebalances.
        fn insertBalanced(self: *Self, index: u32, fresh: u32) u32 {
            if (index == none) return fresh;
            const nodes = self.nodes.items;
            switch (orderFn(nodes[fresh].key, nodes[index].key)) {
                .lt => nodes[index].left = self.insertBalanced(nodes[index].left, fresh),
                .gt => nodes[index].right = self.insertBalanced(nodes[index].right, fresh),
                .eq => unreachable,
            }
            return self.rebalance(index);
        }

        fn height(self: *const Self, index: u32) u8 {
            return if (index == none) 0 else self.nodes.items[index].height;
        }

        fn refreshHeight(self: *Self, index: u32) void {
            const node = &self.nodes.items[index];
            node.height = 1 + @max(self.height(node.left), self.height(node.right));
        }

        fn balanceFactor(self: *const Self, index: u32) i16 {
            const node = &self.nodes.items[index];
            return @as(i16, self.height(node.left)) - @as(i16, self.height(node.right));
        }

        fn rotateRight(self: *Self, index: u32) u32 {
            const nodes = self.nodes.items;
            const pivot = nodes[index].left;
            nodes[index].left = nodes[pivot].right;
            nodes[pivot].right = index;
            self.refreshHeight(index);
            self.refreshHeight(pivot);
            return pivot;
        }

        fn rotateLeft(self: *Self, index: u32) u32 {
            const nodes = self.nodes.items;
            const pivot = nodes[index].right;
            nodes[index].right = nodes[pivot].left;
            nodes[pivot].left = index;
            self.refreshHeight(index);
            self.refreshHeight(pivot);
            return pivot;
        }

        fn rebalance(self: *Self, index: u32) u32 {
            self.refreshHeight(index);
            const balance = self.balanceFactor(index);
            if (balance > 1) {
                const nodes = self.nodes.items;
                if (self.balanceFactor(nodes[index].left) < 0) {
                    nodes[index].left = self.rotateLeft(nodes[index].left);
                }
                return self.rotateRight(index);
            }
            if (balance < -1) {
                const nodes = self.nodes.items;
                if (self.balanceFactor(nodes[index].right) > 0) {
                    nodes[index].right = self.rotateRight(nodes[index].right);
                }
                return self.rotateLeft(index);
            }
            return index;
        }

        /// Test hook: root height, which AVL bounds by ~1.44 log2(n + 2).
        pub fn rootHeight(self: *const Self) u8 {
            return self.height(self.root);
        }
    };
}

fn orderU64(a: u64, b: u64) std.math.Order {
    return std.math.order(a, b);
}

const TestMap = OrderedMap(u64, u64, orderU64);

test "ordered map matches a hash-map oracle under random puts and overwrites" {
    var map = TestMap.init(std.testing.allocator);
    defer map.deinit();
    var oracle = std.AutoHashMap(u64, u64).init(std.testing.allocator);
    defer oracle.deinit();

    var prng = std.Random.DefaultPrng.init(0x0ed);
    const random = prng.random();
    for (0..20_000) |round| {
        const key = random.uintLessThan(u64, 4_096);
        const value: u64 = round;
        try map.ensureUnusedCapacity(1);
        map.putAssumeCapacity(key, value);
        try oracle.put(key, value);
        try std.testing.expectEqual(@as(?u64, value), map.get(key));
    }
    try std.testing.expectEqual(oracle.count(), map.count());
    var entries = oracle.iterator();
    while (entries.next()) |entry| {
        try std.testing.expectEqual(@as(?u64, entry.value_ptr.*), map.get(entry.key_ptr.*));
    }
    try std.testing.expectEqual(@as(?u64, null), map.get(5_000));
}

test "ordered map stays logarithmic on sorted and adversarial insertion orders" {
    var map = TestMap.init(std.testing.allocator);
    defer map.deinit();
    const n = 65_536;
    try map.ensureUnusedCapacity(n);
    for (0..n) |key| map.putAssumeCapacity(key, key);
    try std.testing.expect(map.rootHeight() <= 24);
    for (0..n) |key| try std.testing.expectEqual(@as(?u64, key), map.get(key));

    map.clearRetainingCapacity();
    try std.testing.expectEqual(@as(usize, 0), map.count());
    try std.testing.expectEqual(@as(?u64, null), map.get(1));
    var key: u64 = n;
    while (key > 0) : (key -= 1) map.putAssumeCapacity(key, key * 2);
    try std.testing.expect(map.rootHeight() <= 24);
    try std.testing.expectEqual(@as(?u64, 84), map.get(42));
}
