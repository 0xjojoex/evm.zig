const std = @import("std");
const Error = @import("../error.zig").Error;
const hash_context = @import("hash_context.zig");
const schema_limit = @import("../schema_limit.zig");
const precomputed_zero_roots = @import("zero_roots.zig");

pub const Root = [32]u8;
pub const zero = [_]u8{0} ** 32;
const DefaultContext = hash_context.StdSha256Context;
pub const precomputed_zero_root_count = precomputed_zero_roots.count;
pub const zero_roots = precomputed_zero_roots.roots;

pub const TreePath = struct {
    pub const Direction = enum(u1) {
        left,
        right,
    };

    parent: ?*const TreePath,
    direction: ?Direction,
    depth: usize,

    pub fn root() TreePath {
        return .{ .parent = null, .direction = null, .depth = 0 };
    }

    pub fn child(self: *const TreePath, direction: Direction) TreePath {
        return .{ .parent = self, .direction = direction, .depth = self.depth + 1 };
    }

    /// Return the generalized index when the path fits in 256 bits.
    pub fn generalizedIndex(self: *const TreePath) ?u256 {
        if (self.depth >= 256) return null;
        const parent = self.parent orelse return 1;
        const parent_index = parent.generalizedIndex() orelse return null;
        return (parent_index << 1) | @intFromEnum(self.direction.?);
    }

    /// Iterate directions from the current node back toward the root.
    pub fn reverseIterator(self: *const TreePath) ReverseIterator {
        return .{ .current = self };
    }

    pub const ReverseIterator = struct {
        current: ?*const TreePath,

        pub fn next(self: *ReverseIterator) ?Direction {
            const current = self.current orelse return null;
            const direction = current.direction orelse {
                self.current = null;
                return null;
            };
            self.current = current.parent;
            return direction;
        }
    };
};

pub const TreeNode = struct {
    pub const Kind = union(enum) {
        leaf,
        branch,
        zero_subtree: usize,
    };

    root: Root,
    kind: Kind,
};

/// A no-op visitor used by one-shot hash-tree-root computation.
pub const NullTreeVisitor = struct {
    pub const Error = error{};

    pub fn visit(_: *@This(), _: *const TreePath, _: TreeNode) @This().Error!void {}
};

pub fn visitorType(comptime VisitorPointer: type) type {
    const pointer = switch (@typeInfo(VisitorPointer)) {
        .pointer => |value| value,
        else => @compileError("SSZ tree visitor must be passed by pointer"),
    };
    if (pointer.size != .one or pointer.is_const) {
        @compileError("SSZ tree visitor must be a mutable single-item pointer");
    }
    return pointer.child;
}

pub fn assertTreeVisitor(comptime Visitor: type) void {
    if (!@hasDecl(Visitor, "Error") or @TypeOf(Visitor.Error) != type) {
        @compileError("SSZ tree visitor must expose an Error error set");
    }
    if (!std.meta.hasFn(Visitor, "visit")) {
        @compileError("SSZ tree visitor must provide visit(self, path, node)");
    }
    const Expected = fn (*Visitor, *const TreePath, TreeNode) Visitor.Error!void;
    if (@TypeOf(Visitor.visit) != Expected) {
        @compileError("SSZ tree visitor visit has an invalid signature");
    }
}

pub fn VisitorWalkError(comptime VisitorPointer: type) type {
    const Visitor = visitorType(VisitorPointer);
    comptime assertTreeVisitor(Visitor);
    return Error || Visitor.Error;
}

/// Merkleize chunks, optionally padding to a compile-time schema capacity.
pub fn merkleize(chunks: []const Root, comptime limit: ?comptime_int) Error!Root {
    return merkleizeWith(DefaultContext{}, chunks, limit);
}

pub fn merkleizeWith(context: anytype, chunks: []const Root, comptime limit: ?comptime_int) Error!Root {
    const source = RootSource{ .chunks = chunks };
    if (limit) |capacity| return merkleizeSourceWith(context, source, capacity);
    return merkleizeActualSourceWith(context, source);
}

/// Merkleize chunks using progressive groups of 1, 4, 16, ... leaves.
pub fn merkleizeProgressive(chunks: []const Root) Error!Root {
    return merkleizeProgressiveWith(DefaultContext{}, chunks);
}

pub fn merkleizeProgressiveWith(context: anytype, chunks: []const Root) Error!Root {
    return merkleizeProgressiveSourceWith(context, RootSource{ .chunks = chunks });
}

/// Merkleize leaves produced on demand by a source exposing `count` and `leaf`.
/// Empty subtrees share one lazily populated zero-root cache per traversal.
pub fn merkleizeSourceWith(context: anytype, source: anytype, comptime limit: comptime_int) Error!Root {
    var visitor = NullTreeVisitor{};
    var walker = TreeWalker(@TypeOf(context), NullTreeVisitor).init(context, &visitor);
    var path = TreePath.root();
    const adapter = SourceAdapter(@TypeOf(walker), @TypeOf(source)){
        .walker = &walker,
        .source = source,
    };
    return walker.merkleizeSource(adapter, limit, &path);
}

fn merkleizeActualSourceWith(context: anytype, source: anytype) Error!Root {
    var visitor = NullTreeVisitor{};
    var walker = TreeWalker(@TypeOf(context), NullTreeVisitor).init(context, &visitor);
    var path = TreePath.root();
    const adapter = SourceAdapter(@TypeOf(walker), @TypeOf(source)){
        .walker = &walker,
        .source = source,
    };
    return walker.merkleizeActualSource(adapter, &path);
}

/// Merkleize source leaves using progressive groups of 1, 4, 16, ... leaves.
pub fn merkleizeProgressiveSourceWith(context: anytype, source: anytype) Error!Root {
    var visitor = NullTreeVisitor{};
    var walker = TreeWalker(@TypeOf(context), NullTreeVisitor).init(context, &visitor);
    var path = TreePath.root();
    const adapter = SourceAdapter(@TypeOf(walker), @TypeOf(source)){
        .walker = &walker,
        .source = source,
    };
    return walker.merkleizeProgressiveSource(adapter, &path);
}

pub fn mixInLength(root: Root, length: usize) Root {
    return mixInLengthWith(DefaultContext{}, root, length);
}

pub fn mixInLengthWith(context: anytype, root: Root, length: usize) Root {
    var length_root = zero;
    std.mem.writeInt(u256, &length_root, @intCast(length), .little);
    return hashPairWith(context, root, length_root);
}

pub fn mixInSelector(root: Root, selector: u8) Root {
    return mixInSelectorWith(DefaultContext{}, root, selector);
}

pub fn mixInSelectorWith(context: anytype, root: Root, selector: u8) Root {
    var selector_root = zero;
    selector_root[0] = selector;
    return hashPairWith(context, root, selector_root);
}

pub fn mixInActiveFields(root: Root, active_fields: []const bool) Root {
    return mixInActiveFieldsWith(DefaultContext{}, root, active_fields);
}

pub fn mixInActiveFieldsWith(context: anytype, root: Root, active_fields: []const bool) Root {
    std.debug.assert(active_fields.len <= 256);
    var fields_root = zero;
    for (active_fields, 0..) |active, index| {
        if (active) fields_root[index / 8] |= @as(u8, 1) << @intCast(index % 8);
    }
    return hashPairWith(context, root, fields_root);
}

pub fn hashPair(left: Root, right: Root) Root {
    return hashPairWith(DefaultContext{}, left, right);
}

pub fn hashPairWith(context: anytype, left: Root, right: Root) Root {
    comptime hash_context.assertHashContext(@TypeOf(context));
    var input: [64]u8 = undefined;
    @memcpy(input[0..32], &left);
    @memcpy(input[32..64], &right);
    return context.hash64(&input);
}

pub fn zeroHash(depth: usize) Root {
    return zeroHashWith(DefaultContext{}, depth);
}

pub fn zeroHashWith(context: anytype, depth: usize) Root {
    var zero_hashes = ZeroHashes(@TypeOf(context)).init(context);
    return zero_hashes.at(depth);
}

/// Return the binary-tree depth implied by an arbitrary SSZ schema capacity.
pub fn declaredTreeDepth(comptime capacity: comptime_int) comptime_int {
    comptime schema_limit.assertValid(capacity);
    if (capacity <= 1) return 0;

    comptime var remaining: comptime_int = capacity - 1;
    comptime var depth: comptime_int = 0;
    inline while (remaining != 0) : (remaining >>= 1) {
        depth += 1;
    }
    return depth;
}

pub fn nextPowerOfTwo(value: usize) Error!usize {
    if (value <= 1) return 1;
    const shift = @bitSizeOf(usize) - @clz(value - 1);
    if (shift >= @bitSizeOf(usize)) return error.EncodedLengthOverflow;
    return @as(usize, 1) << @intCast(shift);
}

pub fn treeDepth(power_of_two: usize) usize {
    std.debug.assert(power_of_two != 0 and std.math.isPowerOfTwo(power_of_two));
    return @intCast(@ctz(power_of_two));
}

fn actualTreeDepth(count: usize) usize {
    if (count <= 1) return 0;
    return @bitSizeOf(usize) - @as(usize, @intCast(@clz(count - 1)));
}

const RootSource = struct {
    chunks: []const Root,

    fn count(self: @This()) Error!usize {
        return self.chunks.len;
    }

    fn leaf(self: @This(), index: usize) Error!Root {
        return self.chunks[index];
    }
};

fn ZeroHashes(comptime Context: type) type {
    return struct {
        context: Context,
        extension_root: Root,
        extension_depth: usize,

        fn init(context: Context) @This() {
            return .{
                .context = context,
                .extension_root = zero_roots[zero_roots.len - 1],
                .extension_depth = zero_roots.len - 1,
            };
        }

        fn at(self: *@This(), depth: usize) Root {
            if (depth < zero_roots.len) return zero_roots[depth];

            if (depth < self.extension_depth) {
                var root = zero_roots[zero_roots.len - 1];
                for (zero_roots.len - 1..depth) |_| root = hashPairWith(self.context, root, root);
                return root;
            }
            while (self.extension_depth < depth) {
                self.extension_root = hashPairWith(self.context, self.extension_root, self.extension_root);
                self.extension_depth += 1;
            }
            return self.extension_root;
        }
    };
}

/// Canonical sparse Merkle traversal with caller-owned node retention.
pub fn TreeWalker(comptime Context: type, comptime Visitor: type) type {
    comptime hash_context.assertHashContext(Context);
    comptime assertTreeVisitor(Visitor);

    return struct {
        const Self = @This();

        pub const WalkError = Error || Visitor.Error;

        context: Context,
        visitor: *Visitor,

        pub fn init(context: Context, visitor: *Visitor) Self {
            return .{ .context = context, .visitor = visitor };
        }

        pub fn leaf(self: *Self, path: *const TreePath, root: Root) WalkError!Root {
            try self.visitor.visit(path, .{ .root = root, .kind = .leaf });
            return root;
        }

        pub fn zeroSubtree(self: *Self, path: *const TreePath, depth: usize, root: Root) WalkError!Root {
            try self.visitor.visit(path, .{ .root = root, .kind = .{ .zero_subtree = depth } });
            return root;
        }

        pub fn branch(self: *Self, path: *const TreePath, left: Root, right: Root) WalkError!Root {
            const root = hashPairWith(self.context, left, right);
            try self.visitor.visit(path, .{ .root = root, .kind = .branch });
            return root;
        }

        pub fn merkleizeSource(
            self: *Self,
            source: anytype,
            comptime limit: comptime_int,
            path: *const TreePath,
        ) WalkError!Root {
            const count = try source.count();
            if (schema_limit.exceededBy(count, limit)) return error.ListLimitExceeded;
            const depth: usize = @intCast(declaredTreeDepth(limit));
            return self.merkleizeSourceAtDepth(source, count, depth, path);
        }

        fn merkleizeActualSource(self: *Self, source: anytype, path: *const TreePath) WalkError!Root {
            const count = try source.count();
            return self.merkleizeSourceAtDepth(source, count, actualTreeDepth(count), path);
        }

        fn merkleizeSourceAtDepth(
            self: *Self,
            source: anytype,
            count: usize,
            depth: usize,
            path: *const TreePath,
        ) WalkError!Root {
            var zero_hashes = ZeroHashes(Context).init(self.context);
            return self.merkleizeSourceDepth(
                source,
                count,
                0,
                depth,
                &zero_hashes,
                path,
            );
        }

        pub fn merkleizeProgressiveSource(self: *Self, source: anytype, path: *const TreePath) WalkError!Root {
            var zero_hashes = ZeroHashes(Context).init(self.context);
            return self.merkleizeProgressiveSourceRange(
                source,
                try source.count(),
                0,
                1,
                &zero_hashes,
                path,
            );
        }

        pub fn mixInLength(self: *Self, path: *const TreePath, left: Root, length: usize) WalkError!Root {
            var right = zero;
            std.mem.writeInt(u256, &right, @intCast(length), .little);
            return self.mixIn(path, left, right);
        }

        pub fn mixInSelector(self: *Self, path: *const TreePath, left: Root, selector: u8) WalkError!Root {
            var right = zero;
            right[0] = selector;
            return self.mixIn(path, left, right);
        }

        pub fn mixInActiveFields(self: *Self, path: *const TreePath, left: Root, active_fields: []const bool) WalkError!Root {
            std.debug.assert(active_fields.len <= 256);
            var right = zero;
            for (active_fields, 0..) |active, index| {
                if (active) right[index / 8] |= @as(u8, 1) << @intCast(index % 8);
            }
            return self.mixIn(path, left, right);
        }

        fn mixIn(self: *Self, path: *const TreePath, left: Root, right: Root) WalkError!Root {
            var right_path = path.child(.right);
            _ = try self.leaf(&right_path, right);
            return self.branch(path, left, right);
        }

        fn merkleizeSourceDepth(
            self: *Self,
            source: anytype,
            count: usize,
            start: usize,
            depth: usize,
            zero_hashes: *ZeroHashes(Context),
            path: *const TreePath,
        ) WalkError!Root {
            if (start >= count) return self.zeroSubtree(path, depth, zero_hashes.at(depth));
            if (depth == 0) return source.leaf(start, path);

            var left_path = path.child(.left);
            var right_path = path.child(.right);
            const child_depth = depth - 1;
            const left = try self.merkleizeSourceDepth(
                source,
                count,
                start,
                child_depth,
                zero_hashes,
                &left_path,
            );
            const right = if (child_depth >= @bitSizeOf(usize))
                try self.zeroSubtree(&right_path, child_depth, zero_hashes.at(child_depth))
            else blk: {
                const half = @as(usize, 1) << @intCast(child_depth);
                const right_start = std.math.add(usize, start, half) catch {
                    break :blk try self.zeroSubtree(&right_path, child_depth, zero_hashes.at(child_depth));
                };
                break :blk try self.merkleizeSourceDepth(
                    source,
                    count,
                    right_start,
                    child_depth,
                    zero_hashes,
                    &right_path,
                );
            };
            return self.branch(path, left, right);
        }

        fn merkleizeProgressiveSourceRange(
            self: *Self,
            source: anytype,
            count: usize,
            start: usize,
            num_leaves: usize,
            zero_hashes: *ZeroHashes(Context),
            path: *const TreePath,
        ) WalkError!Root {
            if (start >= count) return self.zeroSubtree(path, 0, zero);

            var left_path = path.child(.left);
            const left = try self.merkleizeSourceDepth(
                source,
                count,
                start,
                treeDepth(num_leaves),
                zero_hashes,
                &left_path,
            );
            const next_start = std.math.add(usize, start, num_leaves) catch
                return error.EncodedLengthOverflow;
            var right_path = path.child(.right);
            const right = if (next_start >= count)
                try self.zeroSubtree(&right_path, 0, zero)
            else blk: {
                const next_leaves = std.math.mul(usize, num_leaves, 4) catch
                    return error.EncodedLengthOverflow;
                break :blk try self.merkleizeProgressiveSourceRange(
                    source,
                    count,
                    next_start,
                    next_leaves,
                    zero_hashes,
                    &right_path,
                );
            };
            return self.branch(path, left, right);
        }
    };
}

fn SourceAdapter(comptime Walker: type, comptime Source: type) type {
    return struct {
        walker: *Walker,
        source: Source,

        pub fn count(self: @This()) Walker.WalkError!usize {
            return self.source.count();
        }

        pub fn leaf(self: @This(), index: usize, path: *const TreePath) Walker.WalkError!Root {
            return self.walker.leaf(path, try self.source.leaf(index));
        }
    };
}

test "SSZ ordinary Merkleization pads to its declared limit" {
    var first = zero;
    first[0] = 1;
    const chunks = [_]Root{first};

    try std.testing.expectEqual(first, try merkleize(&chunks, null));
    try std.testing.expectEqual(hashPair(first, zero), try merkleize(&chunks, 2));
    try std.testing.expectError(error.ListLimitExceeded, merkleize(&chunks, 0));
}

test "SSZ progressive Merkleization grows to the right" {
    var first = zero;
    first[0] = 1;
    const chunks = [_]Root{first};

    try std.testing.expectEqual(hashPair(first, zero), try merkleizeProgressive(&chunks));
    try std.testing.expectEqual(zero, try merkleizeProgressive(&.{}));
}

test "SSZ precomputed zero roots form the canonical SHA-256 chain" {
    var expected = zero;
    for (zero_roots) |actual| {
        try std.testing.expectEqual(expected, actual);
        expected = hashPair(expected, expected);
    }
}

test "SSZ sparse Merkleization uses precomputed zero roots" {
    const CountingContext = struct {
        calls: *usize,

        pub fn hash64(self: @This(), input: *const [64]u8) Root {
            self.calls.* += 1;
            return (DefaultContext{}).hash64(input);
        }
    };
    var first = zero;
    first[0] = 1;
    var calls: usize = 0;

    _ = try merkleizeWith(
        CountingContext{ .calls = &calls },
        &.{first},
        @as(usize, 1) << 40,
    );

    // Only the forty populated-path branches reach the runtime hash provider.
    try std.testing.expectEqual(@as(usize, 40), calls);
}

test "SSZ declared tree depth uses arbitrary-precision capacity" {
    try std.testing.expect(comptime declaredTreeDepth(0) == 0);
    try std.testing.expect(comptime declaredTreeDepth(1) == 0);
    try std.testing.expect(comptime declaredTreeDepth(3) == 2);
    try std.testing.expect(comptime declaredTreeDepth(1 << 120) == 120);
}

test "SSZ Merkleization accepts schema capacities beyond usize" {
    var first = zero;
    first[0] = 1;

    const actual = try merkleize(&.{first}, 1 << 120);
    var expected = first;
    var zero_at_depth = zero;
    for (0..120) |_| {
        expected = hashPair(expected, zero_at_depth);
        zero_at_depth = hashPair(zero_at_depth, zero_at_depth);
    }

    try std.testing.expectEqual(expected, actual);
}

test "SSZ zero-root prefix does not cap schema depth" {
    const CountingContext = struct {
        calls: *usize,

        pub fn hash64(self: @This(), input: *const [64]u8) Root {
            self.calls.* += 1;
            return (DefaultContext{}).hash64(input);
        }
    };
    var first = zero;
    first[0] = 1;
    var calls: usize = 0;

    const actual = try merkleizeWith(
        CountingContext{ .calls = &calls },
        &.{first},
        1 << 260,
    );
    var expected = first;
    var zero_at_depth = zero;
    for (0..260) |_| {
        expected = hashPair(expected, zero_at_depth);
        zero_at_depth = hashPair(zero_at_depth, zero_at_depth);
    }

    try std.testing.expectEqual(expected, actual);
    // 260 populated-path branches plus four roots beyond the static prefix.
    try std.testing.expectEqual(@as(usize, 264), calls);
}

test "SSZ Merkle mix-ins use zero-padded right chunks" {
    var value = zero;
    value[0] = 1;

    var length = zero;
    length[0] = 3;
    try std.testing.expectEqual(hashPair(value, length), mixInLength(value, 3));

    var fields = zero;
    fields[0] = 0b0000_0101;
    try std.testing.expectEqual(
        hashPair(value, fields),
        mixInActiveFields(value, &.{ true, false, true }),
    );
}

test "SSZ TreePath supports generalized indices and arbitrary-depth copying" {
    var root_path = TreePath.root();
    var left_path = root_path.child(.left);
    var right_path = left_path.child(.right);

    try std.testing.expectEqual(@as(?u256, 5), right_path.generalizedIndex());
    var directions = right_path.reverseIterator();
    try std.testing.expectEqual(TreePath.Direction.right, directions.next().?);
    try std.testing.expectEqual(TreePath.Direction.left, directions.next().?);
    try std.testing.expectEqual(@as(?TreePath.Direction, null), directions.next());

    var deep: [257]TreePath = undefined;
    deep[0] = TreePath.root();
    for (deep[1..], 1..) |*path, index| path.* = deep[index - 1].child(.left);
    try std.testing.expectEqual(@as(?u256, null), deep[256].generalizedIndex());
}
