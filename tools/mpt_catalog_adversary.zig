//! Scale adversarial authenticated-catalog shapes against the guest heap.
//! Shapes are structurally canonical MPTs, not Ethereum fixed-key/account
//! semantic fixtures; they deliberately upper-bound pre-binding ingestion.

const std = @import("std");
const evmz = @import("evmz");

const heap_capacity = 16 * 1024 * 1024;
const Root = evmz.mpt.Root;

const Shape = enum {
    branch,
    embedded,
    embedded_dense,
    unreachable_bag,

    fn parse(name: []const u8) ?Shape {
        if (std.mem.eql(u8, name, "branch")) return .branch;
        if (std.mem.eql(u8, name, "embedded")) return .embedded;
        if (std.mem.eql(u8, name, "embedded-dense")) return .embedded_dense;
        if (std.mem.eql(u8, name, "unreachable")) return .unreachable_bag;
        return null;
    }

    fn label(self: Shape) []const u8 {
        return switch (self) {
            .embedded_dense => "embedded-dense",
            .unreachable_bag => "unreachable",
            else => @tagName(self),
        };
    }
};

const Case = struct {
    nodes: []const []const u8,
    root: Root,
    raw_bytes: usize,
    expected_linked: usize,
    expected_branches: usize,
};

const Measurement = struct {
    status: []const u8,
    indexed_nodes: usize = 0,
    linked_nodes: usize = 0,
    branch_nodes: usize = 0,
    node_capacity: usize = 0,
    branch_capacity: usize = 0,
    index_bytes: usize = 0,
    catalog_used_bytes: usize = 0,
    catalog_capacity_bytes: usize = 0,
    post_seal_end_bytes: usize = 0,
    peak_bytes: usize = 0,
};

pub fn main(init: std.process.Init) !void {
    const arg_allocator = init.arena.allocator();
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, arg_allocator);
    defer args.deinit();
    _ = args.next();
    const shape_name = args.next() orelse return error.MissingShape;
    const shape = Shape.parse(shape_name) orelse return error.InvalidShape;

    var stdout_buffer: [16 * 1024]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(init.io, &stdout_buffer);
    try stdout.interface.writeAll(
        "shape\tleaves\twitness_nodes\twitness_bytes\texpected_linked\t" ++
            "expected_branches\tstatus\tindexed_nodes\tlinked_nodes\tbranch_nodes\t" ++
            "node_capacity\tbranch_capacity\tindex_bytes\tcatalog_used_bytes\t" ++
            "catalog_capacity_bytes\tpost_seal_end_bytes\tpeak_bytes\n",
    );

    var count: usize = 0;
    while (args.next()) |count_z| {
        const leaf_count = try std.fmt.parseInt(usize, count_z, 10);
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const case = try generate(arena.allocator(), shape, leaf_count);
        const measured = try measure(case);
        try writeRow(&stdout.interface, shape, leaf_count, case, measured);
        count += 1;
    }
    try stdout.interface.flush();
    if (count == 0) return error.MissingLeafCount;
}

fn generate(allocator: std.mem.Allocator, shape: Shape, leaf_count: usize) !Case {
    if (leaf_count == 0 or !std.math.isPowerOfTwo(leaf_count)) return error.LeafCountMustBePowerOfTwo;
    var nodes: std.ArrayList([]const u8) = .empty;
    var hashes: std.ArrayList(Root) = .empty;
    var raw_bytes: usize = 0;

    switch (shape) {
        .branch, .unreachable_bag => for (0..leaf_count) |index| {
            const encoded = try hashedLeaf(allocator, index);
            try nodes.append(allocator, encoded);
            try hashes.append(allocator, hash(encoded));
            raw_bytes = try std.math.add(usize, raw_bytes, encoded.len);
        },
        .embedded => for (0..leaf_count) |index| {
            const encoded = try embeddedFanout(allocator, index);
            try nodes.append(allocator, encoded);
            try hashes.append(allocator, hash(encoded));
            raw_bytes = try std.math.add(usize, raw_bytes, encoded.len);
        },
        .embedded_dense => for (0..leaf_count) |index| {
            const encoded = try denseEmbeddedFanout(allocator, index);
            try nodes.append(allocator, encoded);
            try hashes.append(allocator, hash(encoded));
            raw_bytes = try std.math.add(usize, raw_bytes, encoded.len);
        },
    }

    if (shape == .unreachable_bag) return .{
        .nodes = nodes.items,
        .root = hashes.items[0],
        .raw_bytes = raw_bytes,
        .expected_linked = 1,
        .expected_branches = 0,
    };

    var level = hashes.items;
    while (level.len > 1) {
        var next: std.ArrayList(Root) = .empty;
        try next.ensureTotalCapacityPrecise(allocator, level.len / 2);
        var index: usize = 0;
        while (index < level.len) : (index += 2) {
            const encoded = try hashedBranch(allocator, level[index], level[index + 1]);
            try nodes.append(allocator, encoded);
            next.appendAssumeCapacity(hash(encoded));
            raw_bytes = try std.math.add(usize, raw_bytes, encoded.len);
        }
        level = next.items;
    }

    const expected_linked = switch (shape) {
        .branch => try std.math.sub(usize, try std.math.mul(usize, 2, leaf_count), 1),
        .embedded => try std.math.sub(usize, try std.math.mul(usize, 18, leaf_count), 1),
        .embedded_dense => try std.math.sub(usize, try std.math.mul(usize, 114, leaf_count), 1),
        .unreachable_bag => unreachable,
    };
    const expected_branches = switch (shape) {
        .branch => leaf_count - 1,
        .embedded => try std.math.sub(usize, try std.math.mul(usize, 2, leaf_count), 1),
        .embedded_dense => try std.math.sub(usize, try std.math.mul(usize, 18, leaf_count), 1),
        .unreachable_bag => unreachable,
    };
    return .{
        .nodes = nodes.items,
        .root = level[0],
        .raw_bytes = raw_bytes,
        .expected_linked = expected_linked,
        .expected_branches = expected_branches,
    };
}

fn measure(case: Case) !Measurement {
    const heap = try std.heap.page_allocator.alignedAlloc(u8, .@"16", heap_capacity);
    defer std.heap.page_allocator.free(heap);
    var metered = evmz.fixed_buffer_meter.MeteredFixedBufferAllocator.init(heap);
    const allocator = metered.allocator();
    const trie = evmz.mpt.init(allocator);

    var indexed = trie.indexNodes(case.nodes) catch |err| switch (err) {
        error.OutOfMemory => return exhausted("oom:index", &metered),
        else => return err,
    };
    defer indexed.deinit();
    const index_bytes = indexed.allocationBytes();
    var builder = trie.catalogBuilder(indexed.index()) catch |err| switch (err) {
        error.OutOfMemory => return exhaustedWithIndex("oom:builder", &metered, indexed, index_bytes),
    };
    defer builder.deinit();
    _ = builder.authenticateRoot(case.root) catch |err| switch (err) {
        error.OutOfMemory => return exhaustedWithIndex("oom:link", &metered, indexed, index_bytes),
        else => return err,
    };
    var catalog = builder.finish() catch |err| switch (err) {
        error.OutOfMemory => return exhaustedWithIndex("oom:seal", &metered, indexed, index_bytes),
        else => return err,
    };
    defer catalog.deinit();

    if (catalog.nodeCount() != case.expected_linked or catalog.branchCount() != case.expected_branches) {
        return error.UnexpectedTopology;
    }
    return .{
        .status = "ok",
        .indexed_nodes = indexed.nodeCount(),
        .linked_nodes = catalog.nodeCount(),
        .branch_nodes = catalog.branchCount(),
        .node_capacity = catalog.nodeCapacity(),
        .branch_capacity = catalog.branchCapacity(),
        .index_bytes = index_bytes,
        .catalog_used_bytes = catalog.nodeCount() * @sizeOf(evmz.mpt.CatalogNode) +
            catalog.branchCount() * @sizeOf(evmz.mpt.CatalogBranch),
        .catalog_capacity_bytes = catalog.nodeCapacity() * @sizeOf(evmz.mpt.CatalogNode) +
            catalog.branchCapacity() * @sizeOf(evmz.mpt.CatalogBranch),
        .post_seal_end_bytes = metered.fixed.end_index,
        .peak_bytes = metered.metrics().peak_used_bytes,
    };
}

fn exhausted(status: []const u8, metered: *const evmz.fixed_buffer_meter.MeteredFixedBufferAllocator) Measurement {
    return .{
        .status = status,
        .post_seal_end_bytes = metered.fixed.end_index,
        .peak_bytes = metered.metrics().peak_used_bytes,
    };
}

fn exhaustedWithIndex(
    status: []const u8,
    metered: *const evmz.fixed_buffer_meter.MeteredFixedBufferAllocator,
    indexed: *const evmz.mpt.IndexedNodes,
    index_bytes: usize,
) Measurement {
    var result = exhausted(status, metered);
    result.indexed_nodes = indexed.nodeCount();
    result.index_bytes = index_bytes;
    return result;
}

fn hashedLeaf(allocator: std.mem.Allocator, index: usize) ![]u8 {
    const encoded = try allocator.alloc(u8, 35);
    encoded[0] = 0xe2;
    encoded[1] = 0x20;
    encoded[2] = 0xa0;
    @memset(encoded[3..], 0);
    std.mem.writeInt(u64, encoded[27..35], @intCast(index + 1), .big);
    return encoded;
}

fn embeddedFanout(allocator: std.mem.Allocator, index: usize) ![]u8 {
    const encoded = try allocator.alloc(u8, 115);
    encoded[0] = 0xf8;
    encoded[1] = 0x71;
    var offset: usize = 2;
    for (0..16) |child| {
        encoded[offset] = 0xc6;
        encoded[offset + 1] = 0x20;
        encoded[offset + 2] = 0x84;
        const value = std.math.add(usize, try std.math.mul(usize, index, 16), child + 1) catch
            return error.ValueOverflow;
        std.mem.writeInt(u32, encoded[offset + 3 ..][0..4], @intCast(value), .big);
        offset += 7;
    }
    encoded[offset] = 0x80;
    std.debug.assert(offset + 1 == encoded.len);
    return encoded;
}

fn denseEmbeddedFanout(allocator: std.mem.Allocator, index: usize) ![]u8 {
    const encoded = try allocator.alloc(u8, 484);
    encoded[0] = 0xf9;
    encoded[1] = 0x01;
    encoded[2] = 0xe1;
    var offset: usize = 3;
    for (0..16) |branch| {
        encoded[offset] = 0xdd;
        offset += 1;
        for (1..7) |value| {
            encoded[offset] = 0xc2;
            const shift: std.math.Log2Int(usize) = @intCast((value - 1) * 4);
            const suffix: u8 = if (branch == 0) @intCast((index >> shift) & 0x0f) else 0;
            encoded[offset + 1] = if (branch == 0) 0x30 | suffix else 0x20;
            encoded[offset + 2] = @intCast(value);
            offset += 3;
        }
        @memset(encoded[offset..][0..11], 0x80);
        offset += 11;
    }
    encoded[offset] = 0x80;
    std.debug.assert(offset + 1 == encoded.len);
    return encoded;
}

fn hashedBranch(allocator: std.mem.Allocator, left: Root, right: Root) ![]u8 {
    const encoded = try allocator.alloc(u8, 83);
    encoded[0] = 0xf8;
    encoded[1] = 0x51;
    encoded[2] = 0xa0;
    @memcpy(encoded[3..35], &left);
    encoded[35] = 0xa0;
    @memcpy(encoded[36..68], &right);
    @memset(encoded[68..], 0x80);
    return encoded;
}

fn hash(encoded: []const u8) Root {
    return evmz.mpt.StdKeccak256Context.keccak256(.{}, encoded);
}

fn writeRow(
    writer: *std.Io.Writer,
    shape: Shape,
    leaf_count: usize,
    case: Case,
    measured: Measurement,
) !void {
    try writer.print(
        "{s}\t{}\t{}\t{}\t{}\t{}\t{s}\t{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}\n",
        .{
            shape.label(),
            leaf_count,
            case.nodes.len,
            case.raw_bytes,
            case.expected_linked,
            case.expected_branches,
            measured.status,
            measured.indexed_nodes,
            measured.linked_nodes,
            measured.branch_nodes,
            measured.node_capacity,
            measured.branch_capacity,
            measured.index_bytes,
            measured.catalog_used_bytes,
            measured.catalog_capacity_bytes,
            measured.post_seal_end_bytes,
            measured.peak_bytes,
        },
    );
}
