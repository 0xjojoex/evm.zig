const std = @import("std");
const ssz = @import("../lib.zig");
const codec = @import("../codec.zig");
const Error = @import("../error.zig").Error;
const hash_context = @import("hash_context.zig");
const merkle = @import("tree.zig");
const schema_meta = @import("../schema_meta.zig");
const schema_limit = @import("../schema_limit.zig");
const union_codec = @import("../union/tagged_union.zig");

pub const Root = merkle.Root;
pub const TreePath = merkle.TreePath;
pub const TreeNode = merkle.TreeNode;

/// Build an SSZ Merkleizer backed by a caller-supplied SHA-256 implementation.
///
/// `HashContext` may carry runtime provider state and must expose
/// `hash64(self, *const [64]u8) [32]u8`. This is the entry point for zkVM,
/// accelerated, or otherwise non-stdlib SHA-256 providers.
pub fn Merkleizer(comptime HashContext: type) type {
    comptime hash_context.assertHashContext(HashContext);
    return struct {
        const Self = @This();

        context: HashContext,

        /// Bind this Merkleizer to a concrete hash-provider context.
        pub fn init(context: HashContext) Self {
            return .{ .context = context };
        }

        /// Compute the canonical SSZ hash-tree-root with this hash provider.
        pub fn hashTreeRoot(self: Self, comptime Codec: type, value: Codec.Value) Error!Root {
            return hashTreeRootWith(self.context, Codec, value);
        }

        /// Compute the canonical root with this hash provider while reporting
        /// sparse tree nodes in post-order.
        ///
        /// The visitor owns all node retention, caching, and persistence. Path
        /// pointers are valid only for the duration of each visitor call.
        pub fn walkTree(
            self: Self,
            comptime Codec: type,
            value: Codec.Value,
            visitor: anytype,
        ) merkle.VisitorWalkError(@TypeOf(visitor))!Root {
            return walkTreeWith(self.context, Codec, value, visitor);
        }
    };
}

/// Compute the canonical SSZ hash-tree-root using `std.crypto` SHA-256.
///
/// Use `Merkleizer(CustomSha256Context).hashTreeRoot` when hashing must be
/// supplied by a zkVM, accelerator, or another external provider.
pub fn hashTreeRoot(comptime Codec: type, value: Codec.Value) Error!Root {
    return Merkleizer(hash_context.StdSha256Context).init(.{}).hashTreeRoot(Codec, value);
}

/// Walk the canonical sparse SSZ tree using `std.crypto` SHA-256.
///
/// Nodes are reported in post-order and the final root is returned. The
/// visitor owns all retained tree state. Use
/// `Merkleizer(CustomSha256Context).walkTree` for a custom hash provider.
pub fn walkTree(
    comptime Codec: type,
    value: Codec.Value,
    visitor: anytype,
) merkle.VisitorWalkError(@TypeOf(visitor))!Root {
    return Merkleizer(hash_context.StdSha256Context).init(.{}).walkTree(Codec, value, visitor);
}

fn hashTreeRootWith(context: anytype, comptime Codec: type, value: Codec.Value) Error!Root {
    var visitor = merkle.NullTreeVisitor{};
    return walkTreeWith(context, Codec, value, &visitor);
}

fn walkTreeWith(
    context: anytype,
    comptime Codec: type,
    value: Codec.Value,
    visitor: anytype,
) merkle.VisitorWalkError(@TypeOf(visitor))!Root {
    const Visitor = merkle.visitorType(@TypeOf(visitor));
    const Walker = merkle.TreeWalker(@TypeOf(context), Visitor);
    var walker = Walker.init(context, visitor);
    var path = TreePath.root();
    return hashTreeRootWalk(Walker, &walker, &path, Codec, value);
}

fn hashTreeRootWalk(
    comptime Walker: type,
    walker: *Walker,
    path: *const TreePath,
    comptime Codec: type,
    value: Codec.Value,
) Walker.WalkError!Root {
    comptime codec.assertCodec(Codec);
    if (comptime @hasDecl(Codec, "wire_codec")) {
        return hashTreeRootWalk(Walker, walker, path, Codec.wire_codec, Codec.toWire(value));
    }
    return switch (Codec.kind) {
        .basic => hashBasic(Walker, walker, path, Codec, value),
        .vector => hashVector(Walker, walker, path, Codec, value),
        .list => hashList(Walker, walker, path, Codec, value),
        .progressive_list => hashProgressiveList(Walker, walker, path, Codec, value),
        .bitvector => hashBitvector(Walker, walker, path, Codec, value),
        .bitlist => hashBitlist(Walker, walker, path, Codec, value),
        .progressive_bitlist => hashProgressiveBitlist(Walker, walker, path, Codec, value),
        .container => hashContainer(Walker, walker, path, Codec, value),
        .progressive_container => hashProgressiveContainer(Walker, walker, path, Codec, value),
        .union_type => hashUnion(Walker, walker, path, Codec, value),
        .compatible_union => hashCompatibleUnion(Walker, walker, path, Codec, value),
    };
}

fn hashBasic(
    comptime Walker: type,
    walker: *Walker,
    path: *const TreePath,
    comptime Codec: type,
    value: Codec.Value,
) Walker.WalkError!Root {
    const size = Codec.fixed_size.?;
    if (size > 32) @compileError("SSZ basic values must fit in one chunk");
    var root = merkle.zero;
    _ = try Codec.encode(root[0..size], value);
    return walker.leaf(path, root);
}

fn hashVector(
    comptime Walker: type,
    walker: *Walker,
    path: *const TreePath,
    comptime Codec: type,
    value: Codec.Value,
) Walker.WalkError!Root {
    const ElementCodec = schema_meta.vectorElementCodec(Codec);
    const length = comptime schema_meta.vectorLength(Codec);
    if (value.len != length) return error.InvalidByteLength;
    if (ElementCodec.kind == .basic) {
        const source = BasicSource(Walker, ElementCodec, Codec.Value){ .walker = walker, .values = &value };
        return walker.merkleizeSource(source, declaredBasicChunkLimit(length, ElementCodec.fixed_size.?), path);
    }
    const source = CompositeSource(Walker, ElementCodec, Codec.Value){ .walker = walker, .values = &value };
    return walker.merkleizeSource(source, length, path);
}

fn hashList(
    comptime Walker: type,
    walker: *Walker,
    path: *const TreePath,
    comptime Codec: type,
    value: Codec.Value,
) Walker.WalkError!Root {
    if (comptime @typeInfo(Codec.Value) == .optional) {
        return hashOptionalList(Walker, walker, path, Codec, value);
    }

    const ElementCodec = Codec.element_codec;
    const limit = Codec.max_length.?;
    if (schema_limit.exceededBy(value.len, limit)) return error.ListLimitExceeded;
    var data_path = path.child(.left);

    const root = if (ElementCodec.kind == .basic) blk: {
        const source = BasicSource(Walker, ElementCodec, Codec.Value){ .walker = walker, .values = &value };
        break :blk try walker.merkleizeSource(
            source,
            declaredBasicChunkLimit(limit, ElementCodec.fixed_size.?),
            &data_path,
        );
    } else blk: {
        const source = CompositeSource(Walker, ElementCodec, Codec.Value){ .walker = walker, .values = &value };
        break :blk try walker.merkleizeSource(source, limit, &data_path);
    };
    return walker.mixInLength(path, root, value.len);
}

fn hashOptionalList(
    comptime Walker: type,
    walker: *Walker,
    path: *const TreePath,
    comptime Codec: type,
    value: Codec.Value,
) Walker.WalkError!Root {
    if (Codec.max_length.? != 1) @compileError("optional SSZ list representation requires limit 1");
    const ElementCodec = Codec.element_codec;
    var data_path = path.child(.left);
    const root = if (value) |element|
        try hashTreeRootWalk(Walker, walker, &data_path, ElementCodec, element)
    else
        try walker.zeroSubtree(&data_path, 0, merkle.zero);
    return walker.mixInLength(path, root, if (value == null) 0 else 1);
}

fn hashProgressiveList(
    comptime Walker: type,
    walker: *Walker,
    path: *const TreePath,
    comptime Codec: type,
    value: Codec.Value,
) Walker.WalkError!Root {
    const ElementCodec = Codec.element_codec;
    var data_path = path.child(.left);
    const root = if (ElementCodec.kind == .basic) blk: {
        const source = BasicSource(Walker, ElementCodec, Codec.Value){ .walker = walker, .values = &value };
        break :blk try walker.merkleizeProgressiveSource(source, &data_path);
    } else blk: {
        const source = CompositeSource(Walker, ElementCodec, Codec.Value){ .walker = walker, .values = &value };
        break :blk try walker.merkleizeProgressiveSource(source, &data_path);
    };
    return walker.mixInLength(path, root, value.len);
}

fn hashBitvector(
    comptime Walker: type,
    walker: *Walker,
    path: *const TreePath,
    comptime Codec: type,
    value: Codec.Value,
) Walker.WalkError!Root {
    const source = BitSource(Walker, Codec.Value){ .walker = walker, .values = &value };
    return walker.merkleizeSource(source, declaredBitChunkLimit(Codec.length), path);
}

fn hashBitlist(
    comptime Walker: type,
    walker: *Walker,
    path: *const TreePath,
    comptime Codec: type,
    value: Codec.Value,
) Walker.WalkError!Root {
    const limit = Codec.max_length.?;
    if (schema_limit.exceededBy(value.len, limit)) return error.ListLimitExceeded;
    var data_path = path.child(.left);
    const source = BitSource(Walker, Codec.Value){ .walker = walker, .values = &value };
    const root = try walker.merkleizeSource(source, declaredBitChunkLimit(limit), &data_path);
    return walker.mixInLength(path, root, value.len);
}

fn hashProgressiveBitlist(
    comptime Walker: type,
    walker: *Walker,
    path: *const TreePath,
    comptime Codec: type,
    value: Codec.Value,
) Walker.WalkError!Root {
    var data_path = path.child(.left);
    const source = BitSource(Walker, @TypeOf(value)){ .walker = walker, .values = &value };
    const root = try walker.merkleizeProgressiveSource(source, &data_path);
    return walker.mixInLength(path, root, value.len);
}

fn hashContainer(
    comptime Walker: type,
    walker: *Walker,
    path: *const TreePath,
    comptime Codec: type,
    value: Codec.Value,
) Walker.WalkError!Root {
    const source = ContainerSource(Walker, Codec){ .walker = walker, .value = &value };
    return walker.merkleizeSource(source, @typeInfo(Codec.Value).@"struct".fields.len, path);
}

fn hashProgressiveContainer(
    comptime Walker: type,
    walker: *Walker,
    path: *const TreePath,
    comptime Codec: type,
    value: Codec.Value,
) Walker.WalkError!Root {
    var data_path = path.child(.left);
    const source = ProgressiveContainerSource(Walker, Codec){ .walker = walker, .value = &value };
    const root = try walker.merkleizeProgressiveSource(source, &data_path);
    return walker.mixInActiveFields(path, root, Codec.active_fields[0..]);
}

fn ProgressiveContainerSource(comptime Walker: type, comptime Codec: type) type {
    return struct {
        walker: *Walker,
        value: *const Codec.Value,

        pub fn count(_: @This()) Walker.WalkError!usize {
            return Codec.active_fields.len;
        }

        pub fn leaf(self: @This(), index: usize, path: *const TreePath) Walker.WalkError!Root {
            const fields = @typeInfo(Codec.Value).@"struct".fields;
            comptime var field_index: usize = 0;
            inline for (Codec.active_fields, 0..) |active, position| {
                if (index == position) {
                    if (!active) return self.walker.leaf(path, merkle.zero);
                    const field = fields[field_index];
                    const FieldCodec = schema_meta.containerFieldCodec(Codec, field.name, field.type);
                    return hashTreeRootWalk(Walker, self.walker, path, FieldCodec, @field(self.value.*, field.name));
                }
                if (active) field_index += 1;
            }
            unreachable;
        }
    };
}

fn hashUnion(
    comptime Walker: type,
    walker: *Walker,
    path: *const TreePath,
    comptime Codec: type,
    value: Codec.Value,
) Walker.WalkError!Root {
    if (comptime @typeInfo(Codec.Value) == .optional) {
        return hashOptionalUnion(Walker, walker, path, Codec, value);
    }

    const fields = @typeInfo(Codec.Value).@"union".fields;
    const Tag = @typeInfo(Codec.Value).@"union".tag_type.?;
    const active = std.meta.activeTag(value);
    inline for (fields, 0..) |field, selector| {
        if (active == @field(Tag, field.name)) {
            const OptionCodec = Codec.OptionCodec(field.name, field.type);
            var value_path = path.child(.left);
            const root = if (OptionCodec == union_codec.None)
                try walker.leaf(&value_path, merkle.zero)
            else
                try hashTreeRootWalk(Walker, walker, &value_path, OptionCodec, @field(value, field.name));
            return walker.mixInSelector(path, root, @intCast(selector));
        }
    }
    unreachable;
}

fn hashOptionalUnion(
    comptime Walker: type,
    walker: *Walker,
    path: *const TreePath,
    comptime Codec: type,
    value: Codec.Value,
) Walker.WalkError!Root {
    var value_path = path.child(.left);
    const root = if (value) |payload|
        try hashTreeRootWalk(Walker, walker, &value_path, Codec.value_codec, payload)
    else
        try walker.leaf(&value_path, merkle.zero);
    return walker.mixInSelector(path, root, if (value == null) 0 else 1);
}

fn hashCompatibleUnion(
    comptime Walker: type,
    walker: *Walker,
    path: *const TreePath,
    comptime Codec: type,
    value: Codec.Value,
) Walker.WalkError!Root {
    const fields = @typeInfo(Codec.Value).@"union".fields;
    const Tag = @typeInfo(Codec.Value).@"union".tag_type.?;
    const active = std.meta.activeTag(value);
    inline for (fields) |field| {
        if (active == @field(Tag, field.name)) {
            const OptionCodec = Codec.OptionCodec(field.name, field.type);
            const selector: u8 = @intCast(@field(Codec.union_options, field.name).selector);
            var value_path = path.child(.left);
            const root = try hashTreeRootWalk(Walker, walker, &value_path, OptionCodec, @field(value, field.name));
            return walker.mixInSelector(path, root, selector);
        }
    }
    unreachable;
}

fn BasicSource(comptime Walker: type, comptime ElementCodec: type, comptime Values: type) type {
    const element_size = ElementCodec.fixed_size.?;
    if (ElementCodec.kind != .basic) @compileError("SSZ basic source requires basic elements");
    if (element_size == 0 or element_size > 32 or 32 % element_size != 0) {
        @compileError("SSZ basic element size must divide one chunk");
    }
    const elements_per_chunk = 32 / element_size;

    return struct {
        walker: *Walker,
        values: *const Values,

        pub fn count(self: @This()) Walker.WalkError!usize {
            return basicChunkCount(self.values.*.len, element_size);
        }

        pub fn leaf(self: @This(), chunk_index: usize, path: *const TreePath) Walker.WalkError!Root {
            var root = merkle.zero;
            const first = chunk_index * elements_per_chunk;
            // The merkleizer only requests chunks within count(), so first is in range.
            std.debug.assert(first < self.values.*.len);
            const end = first + @min(elements_per_chunk, self.values.*.len - first);
            for (self.values.*[first..end], 0..) |value, index| {
                const start = index * element_size;
                _ = try ElementCodec.encode(root[start .. start + element_size], value);
            }
            return self.walker.leaf(path, root);
        }
    };
}

fn BitSource(comptime Walker: type, comptime Values: type) type {
    return struct {
        walker: *Walker,
        values: *const Values,

        pub fn count(self: @This()) Walker.WalkError!usize {
            return bitChunkCount(self.values.*.len);
        }

        pub fn leaf(self: @This(), chunk_index: usize, path: *const TreePath) Walker.WalkError!Root {
            var root = merkle.zero;
            const first = chunk_index * 256;
            // The merkleizer only requests chunks within count(), so first is in range.
            std.debug.assert(first < self.values.*.len);
            const end = first + @min(256, self.values.*.len - first);
            for (self.values.*[first..end], 0..) |bit, index| {
                if (bit) root[index / 8] |= @as(u8, 1) << @intCast(index % 8);
            }
            return self.walker.leaf(path, root);
        }
    };
}

fn CompositeSource(comptime Walker: type, comptime ElementCodec: type, comptime Values: type) type {
    return struct {
        walker: *Walker,
        values: *const Values,

        pub fn count(self: @This()) Walker.WalkError!usize {
            return self.values.*.len;
        }

        pub fn leaf(self: @This(), index: usize, path: *const TreePath) Walker.WalkError!Root {
            return hashTreeRootWalk(Walker, self.walker, path, ElementCodec, self.values.*[index]);
        }
    };
}

fn ContainerSource(comptime Walker: type, comptime Codec: type) type {
    return struct {
        walker: *Walker,
        value: *const Codec.Value,

        pub fn count(_: @This()) Walker.WalkError!usize {
            return @typeInfo(Codec.Value).@"struct".fields.len;
        }

        pub fn leaf(self: @This(), index: usize, path: *const TreePath) Walker.WalkError!Root {
            inline for (@typeInfo(Codec.Value).@"struct".fields, 0..) |field, field_index| {
                if (index == field_index) {
                    const FieldCodec = schema_meta.containerFieldCodec(Codec, field.name, field.type);
                    return hashTreeRootWalk(Walker, self.walker, path, FieldCodec, @field(self.value.*, field.name));
                }
            }
            unreachable;
        }
    };
}

fn basicChunkCount(item_count: usize, element_size: usize) Error!usize {
    const byte_count = std.math.mul(usize, item_count, element_size) catch
        return error.EncodedLengthOverflow;
    return if (byte_count == 0) 0 else (byte_count - 1) / 32 + 1;
}

fn bitChunkCount(bit_count: usize) usize {
    return if (bit_count == 0) 0 else (bit_count - 1) / 256 + 1;
}

fn declaredBasicChunkLimit(
    comptime item_limit: comptime_int,
    comptime element_size: usize,
) comptime_int {
    comptime schema_limit.assertValid(item_limit);
    const schema_element_size: comptime_int = element_size;
    const byte_limit = item_limit * schema_element_size;
    return if (byte_limit == 0) 0 else @divFloor(byte_limit - 1, 32) + 1;
}

fn declaredBitChunkLimit(comptime bit_limit: comptime_int) comptime_int {
    comptime schema_limit.assertValid(bit_limit);
    return if (bit_limit == 0) 0 else @divFloor(bit_limit - 1, 256) + 1;
}

test "SSZ sparse high-limit list HTR reuses zero roots" {
    const CountingContext = struct {
        calls: *usize,

        pub fn hash64(self: @This(), input: *const [64]u8) Root {
            self.calls.* += 1;
            return (hash_context.StdSha256Context{}).hash64(input);
        }
    };
    const Values = @import("../list/fixed_list.zig").List(u64, @as(usize, 1) << 40);
    const values = [_]u64{1};
    var calls: usize = 0;

    _ = try hashTreeRootWith(CountingContext{ .calls = &calls }, Values, &values);

    // Thirty-eight populated-path branches plus the length mix-in.
    try std.testing.expectEqual(@as(usize, 39), calls);
}

test "SSZ ByteList HTR preserves an abstract schema capacity" {
    const Bytes = ssz.ByteList(1 << 120);
    const value = "abc";

    var expected = merkle.zero;
    @memcpy(expected[0..value.len], value);
    var zero_at_depth = merkle.zero;
    // ByteList packs 32 bytes per chunk, so a 2^120 byte limit has depth 115.
    for (0..115) |_| {
        expected = merkle.hashPair(expected, zero_at_depth);
        zero_at_depth = merkle.hashPair(zero_at_depth, zero_at_depth);
    }
    expected = merkle.mixInLength(expected, value.len);

    try std.testing.expectEqual(expected, try ssz.hashTreeRoot(Bytes, value));
}

test "SSZ hashTreeRoot mixes ordinary union selectors" {
    const Choice = union(enum) {
        none: void,
        number: u16,
    };
    const ChoiceSsz = ssz.Union(Choice, .{ .none = ssz.None });

    var input = [_]u8{0} ** 64;
    var expected_none: ssz.Root = undefined;
    std.crypto.hash.sha2.Sha256.hash(&input, &expected_none, .{});
    try std.testing.expectEqual(
        expected_none,
        try ssz.hashTreeRoot(ChoiceSsz, .{ .none = {} }),
    );

    input[0] = 0x34;
    input[1] = 0x12;
    input[32] = 1;
    var expected_number: ssz.Root = undefined;
    std.crypto.hash.sha2.Sha256.hash(&input, &expected_number, .{});
    try std.testing.expectEqual(
        expected_number,
        try ssz.hashTreeRoot(ChoiceSsz, .{ .number = 0x1234 }),
    );

    const values = [_]u16{ 1, 2 };
    try std.testing.expectError(
        error.ListLimitExceeded,
        ssz.hashTreeRoot(ssz.List(u16, 1), &values),
    );
}

test "SSZ hashTreeRoot rejects short slice-backed vectors" {
    const Pair = ssz.VectorSliceOf(ssz.Fixed(u16), 2);
    const short = [_]u16{7};
    try std.testing.expectError(error.InvalidByteLength, ssz.hashTreeRoot(Pair, &short));

    const Envelope = struct { pair: Pair.Value };
    const EnvelopeSsz = ssz.Container(Envelope, .{ .pair = Pair });
    try std.testing.expectError(
        error.InvalidByteLength,
        ssz.hashTreeRoot(EnvelopeSsz, .{ .pair = &short }),
    );
}

test "SSZ Merkleizer carries a stateful SHA-256 implementation context" {
    const Value = struct {
        first: u64,
        second: u64,

        pub const Ssz = ssz.Container(@This(), .{});
    };
    const value = Value{ .first = 1, .second = 2 };
    var calls: usize = 0;
    const counting = ssz.Merkleizer(CountingSha256Context).init(.{ .calls = &calls });

    try std.testing.expectEqual(
        try ssz.hashTreeRoot(Value.Ssz, value),
        try counting.hashTreeRoot(Value.Ssz, value),
    );
    try std.testing.expectEqual(@as(usize, 1), calls);
}

test "SSZ Merkleizer propagates its context through every composite path" {
    const Pair = struct {
        left: u16,
        right: u16,

        pub const Ssz = ssz.Container(@This(), .{});
    };
    const Choice = union(enum) {
        number: u16,
        pair: Pair,
    };
    const ChoiceSsz = ssz.Union(Choice, .{ .pair = Pair.Ssz });
    const Sparse = struct {
        first: u16,
        second: u16,
    };
    const SparseSsz = ssz.ProgressiveContainer(
        Sparse,
        [_]bool{ true, false, true },
        .{},
    );
    const pair_values = [_]Pair{.{ .left = 1, .right = 2 }};
    const numbers = [_]u16{7};
    const bits = [_]bool{true};
    var calls: usize = 0;
    const counting = ssz.Merkleizer(CountingSha256Context).init(.{ .calls = &calls });

    _ = try counting.hashTreeRoot(ssz.List(u16, 64), &numbers);
    try std.testing.expectEqual(@as(usize, 3), calls);

    calls = 0;
    _ = try counting.hashTreeRoot(ssz.ListOf(Pair.Ssz, 2), &pair_values);
    try std.testing.expectEqual(@as(usize, 3), calls);

    calls = 0;
    _ = try counting.hashTreeRoot(ssz.ProgressiveList(u16), &numbers);
    try std.testing.expectEqual(@as(usize, 2), calls);

    calls = 0;
    _ = try counting.hashTreeRoot(ssz.Bitlist(512), &bits);
    try std.testing.expectEqual(@as(usize, 2), calls);

    calls = 0;
    _ = try counting.hashTreeRoot(ChoiceSsz, .{ .pair = pair_values[0] });
    try std.testing.expectEqual(@as(usize, 2), calls);

    calls = 0;
    _ = try counting.hashTreeRoot(SparseSsz, .{ .first = 1, .second = 2 });
    try std.testing.expectEqual(@as(usize, 5), calls);
}

test "SSZ walkTree exposes one sparse canonical node per path" {
    const Item = struct {
        id: u16,
        active: bool,

        pub const Ssz = ssz.Container(@This(), .{});
    };
    const Payload = struct {
        items: []const Item,
        choice: ?u16,

        pub const Ssz = ssz.Container(@This(), .{
            .items = ssz.ListOf(Item.Ssz, 4),
        });
    };
    const Record = struct {
        generalized_index: u256,
        node: TreeNode,
    };
    const Collector = struct {
        pub const Error = error{
            DuplicateNode,
            InvalidBranch,
            MissingChild,
            PathTooDeep,
            TooManyNodes,
        };

        records: [32]Record = undefined,
        len: usize = 0,

        pub fn visit(self: *@This(), path: *const TreePath, node: TreeNode) @This().Error!void {
            const generalized_index = path.generalizedIndex() orelse return error.PathTooDeep;
            for (self.records[0..self.len]) |record| {
                if (record.generalized_index == generalized_index) return error.DuplicateNode;
            }
            switch (node.kind) {
                .branch => {
                    const left = self.find(generalized_index * 2) orelse return error.MissingChild;
                    const right = self.find(generalized_index * 2 + 1) orelse return error.MissingChild;
                    const expected = merkle.hashPair(left.root, right.root);
                    if (!std.mem.eql(u8, &expected, &node.root)) return error.InvalidBranch;
                },
                else => {},
            }
            if (self.len == self.records.len) return error.TooManyNodes;
            self.records[self.len] = .{ .generalized_index = generalized_index, .node = node };
            self.len += 1;
        }

        fn find(self: *const @This(), generalized_index: u256) ?TreeNode {
            for (self.records[0..self.len]) |record| {
                if (record.generalized_index == generalized_index) return record.node;
            }
            return null;
        }
    };
    const items = [_]Item{
        .{ .id = 1, .active = true },
        .{ .id = 2, .active = false },
    };
    const value = Payload{ .items = &items, .choice = 7 };
    var collector = Collector{};

    const walked_root = try ssz.walkTree(Payload.Ssz, value, &collector);
    try std.testing.expectEqual(try ssz.hashTreeRoot(Payload.Ssz, value), walked_root);
    try std.testing.expectEqual(walked_root, collector.find(1).?.root);

    const list_length = collector.find(5).?;
    try std.testing.expectEqual(@as(u8, 2), list_length.root[0]);
    try std.testing.expectEqual(TreeNode.Kind.leaf, list_length.kind);

    const union_selector = collector.find(7).?;
    try std.testing.expectEqual(@as(u8, 1), union_selector.root[0]);
    try std.testing.expectEqual(TreeNode.Kind.leaf, union_selector.kind);

    const empty_half = collector.find(9).?;
    switch (empty_half.kind) {
        .zero_subtree => |depth| try std.testing.expectEqual(@as(usize, 1), depth),
        else => return error.TestUnexpectedResult,
    }
}

test "SSZ walkTree propagates visitor errors" {
    const StopVisitor = struct {
        pub const Error = error{Stop};

        pub fn visit(_: *@This(), _: *const TreePath, _: TreeNode) @This().Error!void {
            return error.Stop;
        }
    };
    var visitor = StopVisitor{};

    try std.testing.expectError(error.Stop, ssz.walkTree(ssz.Fixed(u64), 1, &visitor));
}

const CountingSha256Context = struct {
    calls: *usize,

    pub fn hash64(self: @This(), input: *const [64]u8) ssz.Root {
        self.calls.* += 1;
        return (ssz.StdSha256Context{}).hash64(input);
    }
};
