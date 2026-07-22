const std = @import("std");
const evmz = @import("../evm.zig");
const cases = @import("call_fixture_cases.zig");
const geth_projection = @import("geth_calltracer_projection.zig");

const Default = evmz.Evm.Executor;
const MemoryAccount = evmz.state.MemoryAccount;

const CaptureHarness = struct {
    arena: evmz.trace.CallArena,
    context: evmz.executor.CaptureContext,

    fn init(self: *CaptureHarness, executor: *Default) void {
        self.* = .{
            .arena = evmz.trace.CallArena.init(std.testing.allocator),
            .context = undefined,
        };
        self.context = evmz.executor.CaptureContext.initWithCalls(
            std.testing.allocator,
            null,
            .{ .arena = &self.arena },
            null,
        );
        executor.setCaptureContext(&self.context);
    }

    fn finish(self: *CaptureHarness, executor: *Default) !evmz.trace.CallSpan {
        _ = try self.context.finish();
        executor.setCaptureContext(null);
        return self.arena.latest().?;
    }

    fn deinit(self: *CaptureHarness, executor: *Default) void {
        if (executor.capture_context != null) executor.setCaptureContext(null);
        self.context.deinit();
        self.arena.deinit();
        self.* = undefined;
    }
};

test "curated call fixtures satisfy compact neutral expectations" {
    for (cases.all) |case| {
        errdefer std.log.err("call fixture failed: {s}", .{case.id});
        try runCase(case);
    }
}

test "transaction validation rejection produces no call frame" {
    const sender = evmz.addr(0xaaaa);
    const recipient = evmz.addr(0xbbbb);

    var executor = Default.init(std.testing.allocator, .{ .revision = .cancun });
    defer executor.deinit();
    try seedAccount(&executor, sender, 10_000_000, 0, &.{});

    var capture: CaptureHarness = undefined;
    capture.init(&executor);
    defer capture.deinit(&executor);
    try capture.context.begin();
    errdefer capture.context.abort() catch {};

    var vm = evmz.Evm.init(&executor);
    const outcome = try vm.transact(.{
        .env = .{ .gas_limit = 1_000_000 },
        .tx = .{
            .sender = sender,
            .to = recipient,
            .gas_limit = 20_999,
        },
    });
    switch (outcome) {
        .executed => |executed| {
            executed.discardIfCurrent();
            return error.UnexpectedExecution;
        },
        .rejected => |reason| try std.testing.expectEqual(
            evmz.Evm.Rejection.intrinsic_gas_too_low,
            reason,
        ),
    }

    const span = try capture.finish(&executor);
    try std.testing.expectEqual(@as(usize, 0), span.rows.len);
    try std.testing.expectEqual(@as(usize, 0), span.bytes.len);
    try std.testing.expect(!executor.hasCurrentTransaction());

    var projected: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer projected.deinit();
    try std.testing.expectError(
        error.InvalidCallSpan,
        geth_projection.writeGeth(
            std.testing.allocator,
            &projected.writer,
            span,
            .{},
            .{},
        ),
    );
    try std.testing.expectEqual(@as(usize, 0), projected.written().len);
}

test "generated depth-limit tree and nested projection cross 1000 frames" {
    const sender = evmz.addr(0xaaaa);
    const recursive = evmz.addr(0x1000);
    const gas: u64 = @intCast(std.math.maxInt(i64));
    const recursive_code = evmz.t.bytecode(.{
        .PUSH0, .PUSH0, .PUSH0, .PUSH0, .PUSH0,
        .PUSH2, 0x10,   0x00,   .GAS,   .CALL,
        .POP,   .STOP,
    });

    var executor = Default.init(std.testing.allocator, .{ .revision = .cancun });
    defer executor.deinit();
    try seedAccount(&executor, sender, 10_000_000, 0, &.{});
    try seedAccount(&executor, recursive, 0, 0, &recursive_code);

    var capture: CaptureHarness = undefined;
    capture.init(&executor);
    defer capture.deinit(&executor);
    try capture.context.begin();
    errdefer capture.context.abort() catch {};

    const result = (try executor.runStandalone(
        evmz.t.defaultTxContext(sender, gas),
        .{ .call = .{ .sender = sender, .recipient = recursive } },
        .legacy(gas),
    )).expectCall();
    const span = try capture.finish(&executor);

    try std.testing.expectEqual(evmz.interpreter.Status.success, result.status);
    try std.testing.expectEqual(@as(usize, evmz.Host.max_call_depth) + 2, span.rows.len);
    for (span.rows, 0..) |row, row_index| {
        try std.testing.expectEqual(@as(u16, @intCast(row_index)), row.depth);
        try std.testing.expectEqual(
            if (row_index == 0) @as(?u32, null) else @as(?u32, @intCast(row_index - 1)),
            row.parent_index,
        );
        try std.testing.expectEqual(@as(u32, 0), row.child_ordinal);
        try std.testing.expectEqual(
            if (row_index + 1 == span.rows.len)
                evmz.trace.CallStatus.call_depth_exceeded
            else
                evmz.trace.CallStatus.success,
            row.status,
        );
    }

    var projected: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer projected.deinit();
    try geth_projection.writeGeth(
        std.testing.allocator,
        &projected.writer,
        span,
        .{},
        .{},
    );
    try std.testing.expectEqual(
        span.rows.len,
        std.mem.count(u8, projected.written(), "\"type\":\"CALL\""),
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        std.mem.count(u8, projected.written(), "\"error\":\"max call depth exceeded\""),
    );
    try std.testing.expectEqual(@as(usize, 203_956), projected.written().len);
    try std.testing.expectEqualSlices(
        u8,
        &evmz.t.hexBytes("4ac1996f78a3551be76511c1e9bfdc29b8dc571a450a0c2ea416cac8847cb25e"),
        &evmz.crypto.sha256(projected.written()),
    );
}

fn runCase(case: cases.Case) !void {
    const revision = std.meta.stringToEnum(evmz.eth.Revision, case.fork) orelse
        return error.UnknownOracleRevision;
    const sender = try evmz.address.fromHex(cases.sender);
    const recipient = try evmz.address.fromHex(case.recipient);

    var executor = Default.init(std.testing.allocator, .{ .revision = revision });
    defer executor.deinit();
    try seedAccount(
        &executor,
        sender,
        try parseHexInt(u256, case.sender_balance),
        0,
        &.{},
    );
    for (case.accounts) |account| {
        const code = try decodeHexAlloc(account.code);
        defer std.testing.allocator.free(code);
        try seedAccount(
            &executor,
            try evmz.address.fromHex(account.address),
            try parseHexInt(u256, account.balance),
            account.nonce,
            code,
        );
    }

    var capture: CaptureHarness = undefined;
    capture.init(&executor);
    defer capture.deinit(&executor);
    try capture.context.begin();
    errdefer capture.context.abort() catch {};

    _ = try executor.runStandalone(
        evmz.t.defaultTxContext(sender, case.gas),
        .{ .call = .{
            .sender = sender,
            .recipient = recipient,
            .value = try parseHexInt(u256, case.value),
        } },
        .legacy(case.gas),
    );
    const span = try capture.finish(&executor);

    try std.testing.expectEqual(case.expected_rows.len, span.rows.len);
    for (span.rows, case.expected_rows) |row, expected| {
        const status = std.meta.stringToEnum(evmz.trace.CallStatus, @tagName(expected.status)) orelse
            return error.UnknownOracleStatus;
        try std.testing.expectEqual(status, row.status);
        try std.testing.expectEqual(expected.checkpoint_reverted, row.checkpointReverted());

        const expected_created = if (expected.created_address) |address|
            try evmz.address.fromHex(address)
        else
            null;
        try std.testing.expectEqual(expected_created, row.createdAddress());

        if (expected.attempted_to) |address| {
            try std.testing.expectEqual(try evmz.address.fromHex(address), row.to);
        }
    }
}

fn seedAccount(
    executor: *Default,
    address: evmz.Address,
    balance: u256,
    nonce: u64,
    code: []const u8,
) !void {
    var account = MemoryAccount.init(std.testing.allocator);
    account.balance = balance;
    account.nonce = nonce;
    try account.setCode(code);
    try executor.state.seedAccount(address, account);
}

fn parseHexInt(comptime T: type, value: []const u8) !T {
    const body = if (std.mem.startsWith(u8, value, "0x")) value[2..] else value;
    if (body.len == 0) return 0;
    return std.fmt.parseInt(T, body, 16);
}

fn decodeHexAlloc(value: []const u8) ![]u8 {
    const body = if (std.mem.startsWith(u8, value, "0x")) value[2..] else value;
    if (body.len % 2 != 0) return error.InvalidOracleHexLength;
    const bytes = try std.testing.allocator.alloc(u8, body.len / 2);
    errdefer std.testing.allocator.free(bytes);
    _ = try std.fmt.hexToBytes(bytes, body);
    return bytes;
}
