const std = @import("std");
const evmz = @import("../evm.zig");
const cases = @import("call_fixture_cases.zig");
const geth_projection = @import("geth_calltracer_projection.zig");

const MemoryAccount = evmz.state.MemoryAccount;

const CaptureHarness = struct {
    arena: evmz.trace.CallArena,
    context: evmz.executor.CaptureContext,

    fn init(self: *CaptureHarness) void {
        self.* = .{
            .arena = evmz.trace.CallArena.init(std.testing.allocator),
            .context = undefined,
        };
        self.context = evmz.executor.CaptureContext.initWithCalls(
            std.testing.allocator,
            null,
            .{ .arena = &self.arena },
        );
    }

    fn finish(self: *CaptureHarness) !evmz.trace.CallSpan {
        _ = try self.context.finish();
        return self.arena.latest().?;
    }

    fn deinit(self: *CaptureHarness) void {
        self.context.deinit();
        self.arena.deinit();
        self.* = undefined;
    }
};

test "curated call fixtures satisfy compact client-independent expectations" {
    // The per-case fork gate resolves revisions from strings at comptime.
    @setEvalBranchQuota(10_000);
    var skipped_any = false;
    inline for (cases.all) |case| {
        errdefer std.log.err("call fixture failed: {s}", .{case.id});
        if (comptime caseForkEnabled(case)) try runCase(case) else skipped_any = true;
    }
    // Partial coverage reports as a skip so a narrowed fork set never reads
    // as a full pass; ci's `all` lane runs every case.
    if (skipped_any) return error.SkipZigTest;
}

// Comptime-only; matches field names directly because `std.meta.stringToEnum`
// builds a comptime StaticStringMap too heavy for this eval scope.
fn caseForkEnabled(comptime case: cases.Case) bool {
    for (@typeInfo(evmz.eth.Revision).@"enum".fields) |field| {
        if (std.mem.eql(u8, field.name, case.fork))
            return evmz.t.forkEnabled(@field(evmz.eth.Revision, field.name));
    }
    // Unknown fork strings fall through to `runCase`, which reports them.
    return true;
}

test "transaction validation rejection produces no call frame" {
    const Cancun = evmz.t.Vm(.cancun) orelse return error.SkipZigTest;
    const sender = evmz.addr(0xaaaa);
    const recipient = evmz.addr(0xbbbb);

    var executor = Cancun.Executor.init(std.testing.allocator, .{});
    defer executor.deinit();
    try seedAccount(&executor, sender, 10_000_000, 0, &.{});

    var capture: CaptureHarness = undefined;
    capture.init();
    defer capture.deinit();
    try capture.context.begin();
    errdefer capture.context.abort() catch {};

    const outcome = try Cancun.Advanced.capture(&executor, &capture.context).transact(.{
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
            Cancun.Rejection.intrinsic_gas_too_low,
            reason,
        ),
    }

    const span = try capture.finish();
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
    const Default = (evmz.t.Vm(.cancun) orelse return error.SkipZigTest).Executor;
    const sender = evmz.addr(0xaaaa);
    const recursive = evmz.addr(0x1000);
    const gas: u64 = @intCast(std.math.maxInt(i64));
    const recursive_code = evmz.t.bytecode(.{
        .PUSH0, .PUSH0, .PUSH0, .PUSH0, .PUSH0,
        .PUSH2, 0x10,   0x00,   .GAS,   .CALL,
        .POP,   .STOP,
    });

    var executor = Default.init(std.testing.allocator, .{});
    defer executor.deinit();
    try seedAccount(&executor, sender, 10_000_000, 0, &.{});
    try seedAccount(&executor, recursive, 0, 0, &recursive_code);

    var capture: CaptureHarness = undefined;
    capture.init();
    defer capture.deinit();
    try capture.context.begin();
    errdefer capture.context.abort() catch {};

    const result = (try executor.capture(&capture.context).execute(
        evmz.t.defaultExecutionContext(sender, gas),
        .{ .call = .{ .sender = sender, .recipient = recursive } },
        .legacy(gas),
    ));
    const span = try capture.finish();

    try std.testing.expectEqual(evmz.interpreter.Status.success, result.status());
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

fn runCase(comptime case: cases.Case) !void {
    const revision = comptime std.meta.stringToEnum(evmz.eth.Revision, case.fork) orelse
        return error.UnknownOracleRevision;
    const ExactVm = evmz.Vm(evmz.eth.specAt(revision));
    const sender = try evmz.Address.fromHex(cases.sender);
    const recipient = try evmz.Address.fromHex(case.recipient);

    var executor = ExactVm.Executor.init(std.testing.allocator, .{});
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
            try evmz.Address.fromHex(account.address),
            try parseHexInt(u256, account.balance),
            account.nonce,
            code,
        );
    }

    var capture: CaptureHarness = undefined;
    capture.init();
    defer capture.deinit();
    try capture.context.begin();
    errdefer capture.context.abort() catch {};

    _ = try executor.capture(&capture.context).execute(
        evmz.t.defaultExecutionContext(sender, case.gas),
        .{ .call = .{
            .sender = sender,
            .recipient = recipient,
            .value = try parseHexInt(u256, case.value),
        } },
        .legacy(case.gas),
    );
    const span = try capture.finish();

    try std.testing.expectEqual(case.expected_rows.len, span.rows.len);
    for (span.rows, case.expected_rows) |row, expected| {
        const status = std.meta.stringToEnum(evmz.trace.CallStatus, @tagName(expected.status)) orelse
            return error.UnknownOracleStatus;
        try std.testing.expectEqual(status, row.status);
        try std.testing.expectEqual(expected.checkpoint_reverted, row.checkpointReverted());

        const expected_created = if (expected.created_address) |address|
            try evmz.Address.fromHex(address)
        else
            null;
        try std.testing.expectEqual(expected_created, row.createdAddress());

        if (expected.attempted_to) |address| {
            try std.testing.expectEqual(try evmz.Address.fromHex(address), row.to);
        }
    }
}

fn seedAccount(
    executor: anytype,
    address: evmz.Address,
    balance: u256,
    nonce: u64,
    code: []const u8,
) !void {
    var account = MemoryAccount.init(std.testing.allocator);
    account.account.balance = balance;
    account.account.nonce = nonce;
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
