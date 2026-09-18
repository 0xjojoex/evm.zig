//! Consensus block execution with observed acceptance, state, and EIP-3155 output.
const std = @import("std");
const evmz = @import("evmz");
const blocktest = @import("blocktest");
const f = blocktest.fixtures;

pub const usage = "usage: evmz blocktest [--trace | --trace-summary] [--run EXACT_ID] <blockchain.json>\n";

pub fn run(init: std.process.Init, args: *std.process.Args.Iterator) !void {
    const allocator = init.arena.allocator();
    var trace: ?bool = null;
    var selected: ?[]const u8 = null;
    var path: ?[]const u8 = null;
    var options = true;
    while (args.next()) |arg| {
        if (options and std.mem.eql(u8, arg, "--")) {
            options = false;
        } else if (options and (std.mem.eql(u8, arg, "--trace") or std.mem.eql(u8, arg, "--trace-summary"))) {
            if (trace != null) return error.ConflictingTraceOptions;
            trace = std.mem.eql(u8, arg, "--trace");
        } else if (options and std.mem.eql(u8, arg, "--run")) {
            if (selected != null) return error.DuplicateSelection;
            selected = args.next() orelse return error.MissingTestId;
        } else if (options and std.mem.startsWith(u8, arg, "-")) {
            return error.UnknownOption;
        } else {
            if (path != null) return error.TooManyPaths;
            path = arg;
        }
    }
    const bytes = try std.Io.Dir.cwd().readFileAlloc(init.io, path orelse return error.MissingFixture, allocator, .limited(256 * 1024 * 1024));
    var buffer: [8192]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(init.io, &buffer);
    try execute(allocator, bytes, selected, trace orelse false, &stdout.interface);
    try stdout.interface.flush();
}

fn execute(allocator: std.mem.Allocator, bytes: []const u8, selected: ?[]const u8, trace: bool, out: *std.Io.Writer) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    const value = try std.json.parseFromSliceLeaky(std.json.Value, scratch, bytes, .{ .parse_numbers = false });
    const root = f.asObject(value) orelse return error.MalformedFixture;
    const chosen = if (selected) |id| root.get(id) orelse return error.TestNotFound else blk: {
        if (root.count() != 1) return error.ExpectedSingleTest;
        break :blk root.values()[0];
    };
    const fixture = f.asObject(chosen) orelse return error.MalformedFixture;
    const blocks = f.asArray(fixture.get("blocks") orelse return error.MalformedFixture) orelse return error.MalformedFixture;
    var session = try blocktest.Session.init(allocator, fixture);
    defer session.deinit();
    for (blocks.items, 0..) |value_entry, index| {
        const entry = f.asObject(value_entry) orelse return error.MalformedFixture;
        if (trace) {
            try observe(true, &session, &entry, index, out);
        } else {
            try observe(false, &session, &entry, index, out);
        }
    }
    const state_root = try session.stateRoot();
    try out.print("{{\"stateRoot\":\"0x{x}\",\"headHash\":\"0x{x}\",\"headNumber\":{d}}}\n", .{ state_root, session.parent.hash, session.parent.number });
}

fn observe(comptime trace: bool, session: *blocktest.Session, entry: *const std.json.ObjectMap, index: usize, out: *std.Io.Writer) !void {
    const result = if (trace) blk: {
        var tape = evmz.trace.TraceTape.initGrowable(session.allocator);
        defer tape.deinit();
        var sink = TraceSink{ .out = out, .block = index };
        break :blk session.apply(true, .block_body, entry, .{ .steps = .{
            .tape = &tape,
            .profile = evmz.trace.eip3155.capture_profile,
            .target = .init(&sink, TraceSink.consume),
        } });
    } else session.apply(false, .block_body, entry, null);
    const observed = result catch |err| {
        if (!blocktest.isBlockRejection(err)) return err;
        try writeBlock(out, session, index, "rejected", @errorName(err));
        return;
    };
    try writeBlock(out, session, index, @tagName(observed.status), if (observed.transaction_rejection) |reason| @tagName(reason) else null);
}

fn writeBlock(out: *std.Io.Writer, session: *blocktest.Session, index: usize, status: []const u8, rejection: ?[]const u8) !void {
    const root = try session.stateRoot();
    try out.print("{{\"block\":{d},\"status\":\"{s}\",\"stateRoot\":\"0x{x}\",\"headHash\":\"0x{x}\",\"headNumber\":{d}", .{ index, status, root, session.parent.hash, session.parent.number });
    if (rejection) |reason| try out.print(",\"rejection\":\"{s}\"", .{reason});
    try out.writeAll("}\n");
}

const TraceSink = struct {
    out: *std.Io.Writer,
    block: usize,
    transaction: usize = 0,

    fn consume(ptr: *anyopaque, span: evmz.trace.TraceSpan) !void {
        const self: *TraceSink = @ptrCast(@alignCast(ptr));
        try self.out.print("{{\"block\":{d},\"transaction\":{d}}}\n", .{ self.block, self.transaction });
        try evmz.trace.eip3155.writeSteps(self.out, span);
        self.transaction += 1;
    }
};

const test_fixture = @embedFile("testdata/chain.json");

test "rejected block preserves state and parent for a valid sibling and child" {
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, test_fixture, .{ .parse_numbers = false });
    defer parsed.deinit();
    const fixture = f.asObject(f.asObject(parsed.value).?.values()[0]).?;
    const blocks = f.asArray(fixture.get("blocks").?).?;
    var session = try blocktest.Session.init(std.testing.allocator, fixture);
    defer session.deinit();
    const initial_root = try session.stateRoot();
    const initial_parent = session.parent;
    const rejected = f.asObject(blocks.items[0]).?;
    const result = try session.apply(false, .block_body, &rejected, null);
    try std.testing.expectEqual(.state_root_mismatch, result.status);
    try std.testing.expectEqual(initial_root, try session.stateRoot());
    try std.testing.expectEqualDeep(initial_parent, session.parent);
    for (blocks.items[1..]) |value| {
        const entry = f.asObject(value).?;
        const accepted = try session.apply(false, .block_body, &entry, null);
        try std.testing.expectEqual(.valid, accepted.status);
    }
    try std.testing.expectEqual(@as(u64, 2), session.parent.number);
    try std.testing.expectEqual(try f.parseHashFromValue(fixture.get("lastblockhash").?), session.parent.hash);
}

test "block observation ignores expectations and trace preserves observed results" {
    var plain = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer plain.deinit();
    try execute(std.testing.allocator, test_fixture, null, false, &plain.writer);
    var traced = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer traced.deinit();
    try execute(std.testing.allocator, test_fixture, null, true, &traced.writer);
    try std.testing.expect(std.mem.indexOf(u8, traced.written(), "\"op\":85") != null);
    var lines = std.mem.splitScalar(u8, plain.written(), '\n');
    while (lines.next()) |line| {
        if (line.len != 0) try std.testing.expect(std.mem.indexOf(u8, traced.written(), line) != null);
    }
    const changed = try std.mem.replaceOwned(u8, std.testing.allocator, test_fixture, "BlockException.INVALID_STATE_ROOT", "BlockException.INVALID_GASLIMIT");
    defer std.testing.allocator.free(changed);
    var other = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer other.deinit();
    try execute(std.testing.allocator, changed, "rollback_then_children", false, &other.writer);
    try std.testing.expectEqualStrings(plain.written(), other.written());
}

test "raw block decoding rejects without changing the committed head" {
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, test_fixture, .{ .parse_numbers = false });
    defer parsed.deinit();
    const fixture = f.asObject(f.asObject(parsed.value).?.values()[0]).?;
    var session = try blocktest.Session.init(std.testing.allocator, fixture);
    defer session.deinit();
    const root = try session.stateRoot();
    const head = session.parent;
    var bad = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, "{\"rlp\":\"0x\"}", .{});
    defer bad.deinit();
    const entry = f.asObject(bad.value).?;
    try std.testing.expectError(error.InputTooShort, session.apply(false, .block_body, &entry, null));
    try std.testing.expectEqual(root, try session.stateRoot());
    try std.testing.expectEqualDeep(head, session.parent);
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();
    try observe(false, &session, &entry, 0, &output.writer);
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "\"rejection\":\"InputTooShort\"") != null);
    try std.testing.expect(!blocktest.isBlockRejection(error.OutOfMemory));
    try std.testing.expect(!blocktest.isBlockRejection(error.WriteFailed));
    try std.testing.expect(!blocktest.isBlockRejection(error.MalformedFixture));
}

test "block selection and unsupported input fail explicitly" {
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();
    try std.testing.expectError(error.ExpectedSingleTest, execute(std.testing.allocator, "{}", null, false, &output.writer));
    try std.testing.expectError(error.TestNotFound, execute(std.testing.allocator, test_fixture, "missing", false, &output.writer));
    try std.testing.expectError(error.MalformedFixture, execute(std.testing.allocator, "{\"engine\":{\"engineNewPayloads\":[]}}", null, false, &output.writer));
    const frontier = try std.mem.replaceOwned(u8, std.testing.allocator, test_fixture, "Cancun", "Frontier");
    defer std.testing.allocator.free(frontier);
    try std.testing.expectError(error.UnsupportedFork, execute(std.testing.allocator, frontier, null, false, &output.writer));
    try std.testing.expectEqual(@as(usize, 0), output.written().len);
}

test "invalid raw signature is rejected without expectation metadata" {
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, test_fixture, .{ .parse_numbers = false });
    defer parsed.deinit();
    const fixture = f.asObject(f.asObject(parsed.value).?.values()[0]).?;
    var entry = f.asObject(f.asArray(fixture.get("blocks").?).?.items[1]).?;
    const raw = try f.parseBytesFromValue(std.testing.allocator, entry.get("rlp").?);
    defer std.testing.allocator.free(raw);
    var cursor = evmz.rlp.Cursor.init(raw);
    var body = try cursor.nextList();
    _ = try body.next();
    var transactions = try body.nextList();
    var tx = try transactions.nextList();
    for (0..7) |_| _ = try tx.next();
    const r = try tx.nextBytesExact(32);
    const offset = @intFromPtr(r.ptr) - @intFromPtr(raw.ptr);
    @memset(raw[offset..][0..32], 0xff);
    const encoded = try std.fmt.allocPrint(std.testing.allocator, "0x{x}", .{raw});
    defer std.testing.allocator.free(encoded);
    // Replace an existing value without transferring ownership to parsed JSON.
    entry.getPtr("rlp").?.* = .{ .string = encoded };
    var session = try blocktest.Session.init(std.testing.allocator, fixture);
    defer session.deinit();
    const root = try session.stateRoot();
    try std.testing.expectError(error.InvalidSignature, session.apply(false, .block_body, &entry, null));
    try std.testing.expectEqual(root, try session.stateRoot());
    try std.testing.expectEqual(@as(u64, 0), session.parent.number);
}
