//! General State Test execution with observed EIP-3155 output.
const std = @import("std");
const evmz = @import("evmz");
const statetest = @import("statetest");
const f = statetest.fixture;

pub const usage = "usage: evmz statetest [--trace | --trace-summary] [--profile] <single-vector.json>\n";

pub fn run(init: std.process.Init, args: *std.process.Args.Iterator) !void {
    const allocator = init.arena.allocator();
    var trace: ?bool = null;
    var profile = false;
    var path: ?[]const u8 = null;
    var options = true;
    while (args.next()) |arg| {
        if (options and std.mem.eql(u8, arg, "--")) {
            options = false;
        } else if (options and (std.mem.eql(u8, arg, "--trace") or std.mem.eql(u8, arg, "--trace-summary"))) {
            if (trace != null) return error.ConflictingTraceOptions;
            trace = std.mem.eql(u8, arg, "--trace");
        } else if (options and std.mem.eql(u8, arg, "--profile")) {
            profile = true;
        } else if (options and std.mem.startsWith(u8, arg, "-")) {
            return error.UnknownOption;
        } else {
            if (path != null) return error.TooManyPaths;
            path = arg;
        }
    }
    var timing: Timing = .{ .io = init.io, .last = if (profile) std.Io.Clock.awake.now(init.io) else .{ .nanoseconds = 0 } };
    const measured: ?*Timing = if (profile) &timing else null;
    const bytes = try std.Io.Dir.cwd().readFileAlloc(init.io, path orelse return error.MissingFixture, allocator, .limited(256 * 1024 * 1024));
    if (measured) |m| m.ns.read = m.lap();
    var buffer: [8192]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(init.io, &buffer);
    try execute(allocator, bytes, trace orelse false, &stdout.interface, measured);
    if (measured) |m| m.ns.teardown += m.lap();
    try stdout.interface.flush();
    if (measured) |m| {
        m.ns.output += m.lap();
        var stderr_buffer: [1024]u8 = undefined;
        var stderr = std.Io.File.stderr().writer(init.io, &stderr_buffer);
        try std.json.Stringify.value(.{ .statetest_profile_ns = m.ns }, .{}, &stderr.interface);
        try stderr.interface.writeByte('\n');
        try stderr.interface.flush();
    }
}

// CLI wall-clock attribution only. The process arena is released after this
// report, so teardown covers host/scratch cleanup, not process-exit cleanup.
const Timing = struct {
    io: std.Io,
    last: std.Io.Timestamp,
    ns: struct {
        read: i96 = 0,
        json: i96 = 0,
        vector: i96 = 0,
        load: i96 = 0,
        transact: i96 = 0,
        root: i96 = 0,
        output: i96 = 0,
        teardown: i96 = 0,
    } = .{},

    fn lap(self: *Timing) i96 {
        const now = std.Io.Clock.awake.now(self.io);
        const elapsed = self.last.durationTo(now).toNanoseconds();
        self.last = now;
        return elapsed;
    }
};

fn execute(allocator: std.mem.Allocator, bytes: []const u8, trace: bool, out: *std.Io.Writer, timing: ?*Timing) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    const value = try std.json.parseFromSliceLeaky(std.json.Value, scratch, bytes, .{ .parse_numbers = false });
    if (timing) |m| m.ns.json = m.lap();
    var root = f.asObject(value) orelse return error.MalformedFixture;
    if (root.count() != 1) return error.ExpectedSingleTest;
    const fixture = f.asObject(root.values()[0]) orelse return error.MalformedFixture;
    try f.rejectUnknownKeys(&fixture, &.{ "env", "pre", "transaction", "post", "config", "_info", "out" });
    var forks = f.asObject(fixture.get("post") orelse return error.MalformedFixture) orelse return error.MalformedFixture;
    if (forks.count() != 1) return error.ExpectedSingleFork;
    const vectors = f.asArray(forks.values()[0]) orelse return error.MalformedFixture;
    if (vectors.items.len != 1) return error.ExpectedSingleVector;
    const post = f.asObject(vectors.items[0]) orelse return error.MalformedFixture;
    try f.rejectUnknownKeys(&post, &.{ "hash", "logs", "receipt", "txbytes", "indexes", "state", "expectException" });
    // This command executes decoded transactions. Never pretend raw envelopes
    // were validated using only fixture sender hints or expected exceptions.
    if (post.get("txbytes") != null) return error.UnsupportedSerializedTransaction;
    const tx = f.asObject(fixture.get("transaction") orelse return error.MalformedFixture) orelse return error.MalformedFixture;
    if (tx.get("authorizationList")) |value_list| {
        const list = f.asArray(value_list) orelse return error.MalformedFixture;
        for (list.items) |entry| {
            const auth = f.asObject(entry) orelse return error.MalformedFixture;
            _ = try f.parseAddressFromValue(auth.get("signer") orelse return error.MissingAuthorizationSigner);
        }
    }
    const fork_name = forks.keys()[0];
    const revision = f.parseStateFork(fork_name) orelse return error.UnsupportedFork;
    switch (revision) {
        inline else => |exact| {
            const vector = try statetest.parseVector(exact, scratch, &fixture, &post, fork_name);
            if (timing) |m| m.ns.vector = m.lap();
            if (trace) {
                try observe(exact, true, allocator, vector, fork_name, out, timing);
            } else {
                try observe(exact, false, allocator, vector, fork_name, out, timing);
            }
        },
    }
}

fn observe(
    comptime revision: evmz.eth.Revision,
    comptime trace: bool,
    allocator: std.mem.Allocator,
    vector: statetest.Vector,
    fork_name: []const u8,
    out: *std.Io.Writer,
    timing: ?*Timing,
) !void {
    var host = try statetest.Host(revision, trace).init(allocator, &vector.pre, vector.env);
    defer host.deinit();
    if (timing) |m| m.ns.load = m.lap();
    const result = try host.transact(vector.tx, if (trace) out else null);
    if (timing) |m| m.ns.transact = m.lap();
    const root = try host.stateRoot(allocator);
    if (timing) |m| m.ns.root = m.lap();
    switch (result) {
        .executed => |executed| try evmz.trace.eip3155.writeSummary(out, .{
            .state_root = root,
            .output = executed.output,
            .gas_used = executed.gas.used,
            .pass = executed.status == .success,
            .fork = fork_name,
        }),
        .rejected => |reason| try out.print("{{\"stateRoot\":\"0x{x}\",\"rejected\":\"{s}\"}}\n", .{ root, @tagName(reason) }),
    }
    if (timing) |m| m.ns.output = m.lap();
}

const test_fixture = @embedFile("testdata/storage.json");

test "observation ignores expected assertions and trace preserves root" {
    var plain = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer plain.deinit();
    try execute(std.testing.allocator, test_fixture, false, &plain.writer, null);
    var traced = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer traced.deinit();
    try execute(std.testing.allocator, test_fixture, true, &traced.writer, null);
    try std.testing.expect(std.mem.indexOf(u8, traced.written(), "\"op\":85") != null);
    try std.testing.expect(std.mem.endsWith(u8, traced.written(), plain.written()));
    try std.testing.expect(std.mem.indexOf(u8, plain.written(), "0x" ++ "0" ** 64) == null);

    const changed = try std.mem.replaceOwned(u8, std.testing.allocator, test_fixture, "\"hash\":", "\"expectException\":\"TransactionException.INVALID_CHAINID\",\"hash\":");
    defer std.testing.allocator.free(changed);
    var other = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer other.deinit();
    try execute(std.testing.allocator, changed, false, &other.writer, null);
    try std.testing.expectEqualStrings(plain.written(), other.written());
}

test "rejection emits unchanged root in both modes" {
    const rejected = try std.mem.replaceOwned(u8, std.testing.allocator, test_fixture, "0x186a0", "0x100");
    defer std.testing.allocator.free(rejected);
    var plain = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer plain.deinit();
    try execute(std.testing.allocator, rejected, false, &plain.writer, null);
    var traced = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer traced.deinit();
    try execute(std.testing.allocator, rejected, true, &traced.writer, null);
    try std.testing.expectEqualStrings(plain.written(), traced.written());
    try std.testing.expect(std.mem.indexOf(u8, plain.written(), "\"rejected\":") != null);
}

test "observation rejects serialized envelopes and ambiguous selection" {
    const serialized = try std.mem.replaceOwned(u8, std.testing.allocator, test_fixture, "\"indexes\":", "\"txbytes\":\"0x\",\"indexes\":");
    defer std.testing.allocator.free(serialized);
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();
    try std.testing.expectError(error.UnsupportedSerializedTransaction, execute(std.testing.allocator, serialized, false, &output.writer, null));
    try std.testing.expectError(error.ExpectedSingleTest, execute(std.testing.allocator, "{}", true, &output.writer, null));
    try std.testing.expectEqual(@as(usize, 0), output.written().len);
}
