//! Measure authenticated catalog shape and isolated fixed-heap demand.

const std = @import("std");
const evmz = @import("evmz");

const heap_capacity = 16 * 1024 * 1024;
const max_input_bytes: std.Io.Limit = .limited(512 * 1024 * 1024);

const Metrics = struct {
    witness_nodes: usize,
    indexed_nodes: usize,
    witness_bytes: usize,
    max_node_bytes: usize,
    state_nodes: usize,
    storage_root_claims: usize,
    storage_roots_present: usize,
    linked_nodes: usize,
    branch_nodes: usize,
    node_capacity: usize,
    branch_capacity: usize,
    index_bytes: usize,
    catalog_used_bytes: usize,
    catalog_capacity_bytes: usize,
    post_seal_end_bytes: usize,
    catalog_peak_bytes: usize,
    validation_peak_bytes: usize,
    stacked_peak_bytes: usize,
};

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, arena);
    defer args.deinit();
    _ = args.next();

    var stdout_buffer: [16 * 1024]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(init.io, &stdout_buffer);
    try stdout.interface.writeAll(
        "fixture\twitness_nodes\tindexed_nodes\twitness_bytes\tmax_node_bytes\t" ++
            "state_nodes\tstorage_root_claims\tstorage_roots_present\tlinked_nodes\t" ++
            "branch_nodes\tnode_capacity\tbranch_capacity\tindex_bytes\t" ++
            "catalog_used_bytes\tcatalog_capacity_bytes\tpost_seal_end_bytes\t" ++
            "catalog_peak_bytes\tvalidation_peak_bytes\tstacked_peak_bytes\n",
    );

    var count: usize = 0;
    while (args.next()) |path_z| {
        const path = path_z[0..path_z.len];
        const framed = try std.Io.Dir.cwd().readFileAlloc(init.io, path, arena, max_input_bytes);
        const raw = try rawInput(framed);
        const input = try evmz.stateless.wire.v1.StatelessInput.decodeSchemaPrefixed(arena, raw);
        if (input.witness.headers.len == 0) return error.MissingParentHeader;
        const state_root = try headerStateRoot(input.witness.headers[input.witness.headers.len - 1]);
        const metrics = try measure(raw, state_root, input.witness.state);
        try writeRow(&stdout.interface, std.fs.path.basename(path), metrics);
        count += 1;
    }
    try stdout.interface.flush();
    if (count == 0) return error.MissingInputPath;
}

fn measure(raw: []const u8, state_root: [32]u8, nodes: []const []const u8) !Metrics {
    const heap = try std.heap.page_allocator.alignedAlloc(u8, .@"16", heap_capacity);
    defer std.heap.page_allocator.free(heap);
    var metered = evmz.fixed_buffer_meter.MeteredFixedBufferAllocator.init(heap);
    const fixed = metered.allocator();

    var witness_bytes: usize = 0;
    var max_node_bytes: usize = 0;
    for (nodes) |encoded| {
        witness_bytes = try std.math.add(usize, witness_bytes, encoded.len);
        max_node_bytes = @max(max_node_bytes, encoded.len);
    }

    const trie = evmz.mpt.init(fixed);
    var indexed = try trie.indexNodes(nodes);
    defer indexed.deinit();
    var builder = try trie.catalogBuilder(indexed.index());
    defer builder.deinit();
    _ = try builder.authenticateRoot(state_root);

    const state_nodes = builder.nodeCount();
    var storage_root_claims: usize = 0;
    var storage_roots_present: usize = 0;
    for (0..state_nodes) |index| {
        const id: evmz.mpt.CatalogNodeId = @enumFromInt(@as(u32, @intCast(index)));
        const node = builder.node(id) orelse return error.InvalidCatalogNode;
        if (node.kind != .leaf) continue;
        const account = try evmz.eth.trie.decodeAccountValue(node.value() orelse return error.InvalidAccountLeaf);
        if (std.mem.eql(u8, &account.storage_root, &evmz.eth.trie.empty_root_hash)) continue;
        storage_root_claims += 1;
        _ = builder.authenticateRoot(account.storage_root) catch |err| switch (err) {
            error.MissingNode => continue,
            else => return err,
        };
        storage_roots_present += 1;
    }

    var catalog = try builder.finish();
    defer catalog.deinit();
    const linked_nodes = catalog.nodeCount();
    const branch_nodes = catalog.branchCount();
    const node_capacity = catalog.nodeCapacity();
    const branch_capacity = catalog.branchCapacity();
    const post_seal_end_bytes = metered.fixed.end_index;
    const catalog_peak_bytes = metered.metrics().peak_used_bytes;
    _ = try evmz.stateless.wire.v1.validateStatelessBytesOneShot(fixed, raw);
    return .{
        .witness_nodes = nodes.len,
        .indexed_nodes = indexed.nodeCount(),
        .witness_bytes = witness_bytes,
        .max_node_bytes = max_node_bytes,
        .state_nodes = state_nodes,
        .storage_root_claims = storage_root_claims,
        .storage_roots_present = storage_roots_present,
        .linked_nodes = linked_nodes,
        .branch_nodes = branch_nodes,
        .node_capacity = node_capacity,
        .branch_capacity = branch_capacity,
        .index_bytes = indexed.allocationBytes(),
        .catalog_used_bytes = linked_nodes * @sizeOf(evmz.mpt.CatalogNode) +
            branch_nodes * @sizeOf(evmz.mpt.CatalogBranch),
        .catalog_capacity_bytes = node_capacity * @sizeOf(evmz.mpt.CatalogNode) +
            branch_capacity * @sizeOf(evmz.mpt.CatalogBranch),
        .post_seal_end_bytes = post_seal_end_bytes,
        .catalog_peak_bytes = catalog_peak_bytes,
        .validation_peak_bytes = try validationPeak(raw),
        .stacked_peak_bytes = metered.metrics().peak_used_bytes,
    };
}

fn validationPeak(raw: []const u8) !usize {
    const heap = try std.heap.page_allocator.alignedAlloc(u8, .@"16", heap_capacity);
    defer std.heap.page_allocator.free(heap);
    var metered = evmz.fixed_buffer_meter.MeteredFixedBufferAllocator.init(heap);
    _ = try evmz.stateless.wire.v1.validateStatelessBytesOneShot(metered.allocator(), raw);
    return metered.metrics().peak_used_bytes;
}

fn rawInput(bytes: []const u8) ![]const u8 {
    if (hasSchema(bytes)) return bytes;
    if (bytes.len < 8) return error.InvalidInputFrame;
    const len_u64 = std.mem.readInt(u64, bytes[0..8], .little);
    const len = std.math.cast(usize, len_u64) orelse return error.InvalidInputFrame;
    if (len > bytes.len - 8) return error.InvalidInputFrame;
    const raw = bytes[8..][0..len];
    if (!hasSchema(raw)) return error.InvalidInputFrame;
    return raw;
}

fn hasSchema(bytes: []const u8) bool {
    return bytes.len >= 2 and std.mem.readInt(u16, bytes[0..2], .big) == evmz.stateless.wire.v1.schema_id;
}

fn headerStateRoot(encoded: []const u8) ![32]u8 {
    var cursor = evmz.rlp.Cursor.init(encoded);
    var fields = try cursor.nextList();
    try cursor.expectDone();
    _ = try fields.nextBytesExact(32);
    _ = try fields.nextBytesExact(32);
    _ = try fields.nextBytesExact(20);
    return (try fields.nextBytesExact(32))[0..32].*;
}

fn writeRow(writer: *std.Io.Writer, fixture: []const u8, metrics: Metrics) !void {
    try writer.print(
        "{s}\t{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}\n",
        .{
            fixture,
            metrics.witness_nodes,
            metrics.indexed_nodes,
            metrics.witness_bytes,
            metrics.max_node_bytes,
            metrics.state_nodes,
            metrics.storage_root_claims,
            metrics.storage_roots_present,
            metrics.linked_nodes,
            metrics.branch_nodes,
            metrics.node_capacity,
            metrics.branch_capacity,
            metrics.index_bytes,
            metrics.catalog_used_bytes,
            metrics.catalog_capacity_bytes,
            metrics.post_seal_end_bytes,
            metrics.catalog_peak_bytes,
            metrics.validation_peak_bytes,
            metrics.stacked_peak_bytes,
        },
    );
}
