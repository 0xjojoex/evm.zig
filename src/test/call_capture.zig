const std = @import("std");
const evmz = @import("../evm.zig");

const CaptureContext = evmz.executor.CaptureContext;
const Default = evmz.Evm.Executor;
const MemoryAccount = evmz.state.MemoryAccount;

const CaptureHarness = struct {
    arena: evmz.trace.CallArena,
    context: CaptureContext,

    fn init(self: *CaptureHarness, executor: *Default) void {
        self.* = .{
            .arena = evmz.trace.CallArena.init(std.testing.allocator),
            .context = undefined,
        };
        self.context = CaptureContext.initWithCalls(
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

fn seedCode(executor: *Default, address: evmz.Address, code: []const u8, balance: u256) !void {
    var account = MemoryAccount.init(std.testing.allocator);
    account.balance = balance;
    try account.setCode(code);
    try executor.state.seedAccount(address, account);
}

test "call capture distinguishes STATICCALL from inherited-static CALL" {
    const sender = evmz.addr(0xaaaa);
    const root = evmz.addr(0x1000);
    const child = evmz.addr(0x1234);
    const grandchild = evmz.addr(0x5678);
    const root_input = [_]u8{ 0xaa, 0xbb };

    const root_code = evmz.t.bytecode(.{
        .PUSH0,      .PUSH0, .PUSH0, .PUSH0,
        .PUSH2,      0x12,   0x34,   .GAS,
        .STATICCALL, .POP,   .STOP,
    });
    const child_code = evmz.t.bytecode(.{
        .PUSH0, .PUSH0, .PUSH0, .PUSH0, .PUSH0,
        .PUSH2, 0x56,   0x78,   .GAS,   .CALL,
        .POP,   .STOP,
    });

    var executor = Default.init(std.testing.allocator, .{ .revision = .cancun });
    defer executor.deinit();
    try seedCode(&executor, root, &root_code, 0);
    try seedCode(&executor, child, &child_code, 0);
    try seedCode(&executor, grandchild, &.{@intFromEnum(evmz.Opcode.STOP)}, 0);

    var capture: CaptureHarness = undefined;
    capture.init(&executor);
    defer capture.deinit(&executor);
    try capture.context.begin();
    errdefer capture.context.abort() catch {};

    const result = (try executor.runStandalone(
        evmz.t.defaultTxContext(sender, 300_000),
        .{ .call = .{ .sender = sender, .recipient = root, .input = &root_input } },
        .legacy(300_000),
    )).expectCall();
    const span = try capture.finish(&executor);

    try std.testing.expectEqual(evmz.interpreter.Status.success, result.status);
    try std.testing.expectEqual(@as(usize, 3), span.rows.len);
    try std.testing.expectEqual(evmz.trace.CallKind.call, span.rows[0].kind);
    try std.testing.expectEqual(evmz.trace.CallKind.staticcall, span.rows[1].kind);
    try std.testing.expectEqual(evmz.trace.CallKind.call, span.rows[2].kind);
    try std.testing.expectEqual(@as(?u32, null), span.rows[0].parent_index);
    try std.testing.expectEqual(@as(?u32, 0), span.rows[1].parent_index);
    try std.testing.expectEqual(@as(?u32, 1), span.rows[2].parent_index);
    try std.testing.expectEqualSlices(u8, &root_input, span.input(span.rows[0]));
}

test "call capture closes an immediate insufficient-balance call" {
    const sender = evmz.addr(0xaaaa);
    const root = evmz.addr(0x1000);
    const child = evmz.addr(0x1234);
    const root_code = evmz.t.bytecode(.{
        .PUSH0, .PUSH0, .PUSH0, .PUSH0,
        .PUSH1, 0x01,   .PUSH2, 0x12,
        0x34,   .GAS,   .CALL,  .POP,
        .STOP,
    });

    var executor = Default.init(std.testing.allocator, .{ .revision = .cancun });
    defer executor.deinit();
    try seedCode(&executor, root, &root_code, 0);

    var capture: CaptureHarness = undefined;
    capture.init(&executor);
    defer capture.deinit(&executor);
    try capture.context.begin();
    errdefer capture.context.abort() catch {};

    const result = (try executor.runStandalone(
        evmz.t.defaultTxContext(sender, 200_000),
        .{ .call = .{ .sender = sender, .recipient = root } },
        .legacy(200_000),
    )).expectCall();
    const span = try capture.finish(&executor);

    try std.testing.expectEqual(evmz.interpreter.Status.success, result.status);
    try std.testing.expectEqual(@as(usize, 2), span.rows.len);
    try std.testing.expectEqual(evmz.trace.CallStatus.invalid, span.rows[1].status);
    try std.testing.expectEqual(child, span.rows[1].to);
}

test "call capture records SELFDESTRUCT as a semantic child" {
    const sender = evmz.addr(0xaaaa);
    const root = evmz.addr(0x1000);
    const beneficiary = evmz.addr(0xbeef);
    const root_code = evmz.t.bytecode(.{
        .PUSH2, 0xbe, 0xef, .SELFDESTRUCT,
    });

    var executor = Default.init(std.testing.allocator, .{ .revision = .cancun });
    defer executor.deinit();
    try seedCode(&executor, root, &root_code, 9);

    var capture: CaptureHarness = undefined;
    capture.init(&executor);
    defer capture.deinit(&executor);
    try capture.context.begin();
    errdefer capture.context.abort() catch {};

    _ = try executor.runStandalone(
        evmz.t.defaultTxContext(sender, 100_000),
        .{ .call = .{ .sender = sender, .recipient = root } },
        .legacy(100_000),
    );
    const span = try capture.finish(&executor);

    try std.testing.expectEqual(@as(usize, 2), span.rows.len);
    try std.testing.expectEqual(evmz.trace.CallKind.selfdestruct, span.rows[1].kind);
    try std.testing.expectEqual(@as(?u32, 0), span.rows[1].parent_index);
    try std.testing.expectEqual(@as(u16, 1), span.rows[1].depth);
    try std.testing.expectEqual(root, span.rows[1].from);
    try std.testing.expectEqual(beneficiary, span.rows[1].to);
    try std.testing.expectEqual(@as(u256, 9), span.rows[1].value);
}

test "root CREATE capture closes after runtime-code finalization" {
    const sender = evmz.addr(0xaaaa);
    const created = evmz.addr(0x1234);
    const init_code = evmz.t.bytecode(.{
        .PUSH0,  .PUSH0, .MSTORE8,
        .PUSH1,  0x01,   .PUSH0,
        .RETURN,
    });

    var executor = Default.init(std.testing.allocator, .{ .revision = .cancun });
    defer executor.deinit();
    var sender_account = MemoryAccount.init(std.testing.allocator);
    sender_account.balance = 1_000_000;
    try executor.state.seedAccount(sender, sender_account);

    var capture: CaptureHarness = undefined;
    capture.init(&executor);
    defer capture.deinit(&executor);
    try capture.context.begin();
    errdefer capture.context.abort() catch {};

    const result = (try executor.runStandalone(
        evmz.t.defaultTxContext(sender, 200_000),
        .{ .create = .{
            .sender = sender,
            .recipient = created,
            .init_code = &init_code,
        } },
        .legacy(200_000),
    )).expectCreate();
    const span = try capture.finish(&executor);

    try std.testing.expectEqual(evmz.interpreter.Status.success, result.status);
    try std.testing.expectEqual(@as(usize, 1), span.rows.len);
    try std.testing.expectEqual(evmz.trace.CallKind.create, span.rows[0].kind);
    try std.testing.expectEqual(evmz.trace.CallStatus.success, span.rows[0].status);
    try std.testing.expectEqual(created, span.rows[0].to);
    try std.testing.expectEqualSlices(u8, &init_code, span.input(span.rows[0]));
    try std.testing.expectEqualSlices(u8, &.{0x00}, span.output(span.rows[0]));
    try std.testing.expectEqualSlices(u8, &.{0x00}, try executor.getCode(created));
}
