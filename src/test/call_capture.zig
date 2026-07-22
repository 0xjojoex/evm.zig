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

test {
    _ = @import("geth_calltracer_projection.zig");
}

test "call capture exports neutral primitives without a client projection" {
    try std.testing.expect(@hasDecl(evmz.trace, "CallArena"));
    try std.testing.expect(@hasDecl(evmz.trace, "CallSpan"));
    try std.testing.expect(@hasDecl(evmz.trace, "CallRow"));
    try std.testing.expect(@hasDecl(evmz.trace, "CallKind"));
    try std.testing.expect(@hasDecl(evmz.trace, "CallStatus"));
    try std.testing.expect(!@hasDecl(evmz.trace, "call_projection"));
    try std.testing.expect(!@hasDecl(evmz.trace, "geth_calltracer"));
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
    try std.testing.expectEqual(evmz.trace.CallStatus.insufficient_balance, span.rows[1].status);
    try std.testing.expectEqual(@as(i64, 0), span.rows[1].gas_used);
    try std.testing.expectEqual(child, span.rows[1].to);
}

test "root insufficient-balance capture preserves unspent gas" {
    const sender = evmz.addr(0xaaaa);
    const code_recipient = evmz.addr(0x1000);
    const precompile_recipient = evmz.addr(0x0004);
    const gas: u64 = 200_000;

    for ([_]evmz.Address{ code_recipient, precompile_recipient }) |recipient| {
        var executor = Default.init(std.testing.allocator, .{ .revision = .cancun });
        defer executor.deinit();
        try seedCode(&executor, code_recipient, &.{@intFromEnum(evmz.Opcode.STOP)}, 0);

        var capture: CaptureHarness = undefined;
        capture.init(&executor);
        defer capture.deinit(&executor);
        try capture.context.begin();
        errdefer capture.context.abort() catch {};

        const result = (try executor.runStandalone(
            evmz.t.defaultTxContext(sender, gas),
            .{ .call = .{
                .sender = sender,
                .recipient = recipient,
                .value = 1,
            } },
            .legacy(gas),
        )).expectCall();
        const span = try capture.finish(&executor);

        try std.testing.expectEqual(evmz.interpreter.Status.invalid, result.status);
        try std.testing.expectEqual(evmz.execution.TerminalCause.insufficient_balance, result.cause.?);
        try std.testing.expectEqual(@as(i64, gas), result.gas_left);
        try std.testing.expectEqual(@as(usize, 1), span.rows.len);
        try std.testing.expectEqual(evmz.trace.CallStatus.insufficient_balance, span.rows[0].status);
        try std.testing.expectEqual(@as(i64, 0), span.rows[0].gas_used);
        try std.testing.expect(!span.rows[0].checkpointReverted());
    }
}

test "call capture retains immediate depth-limit cause" {
    const sender = evmz.addr(0xaaaa);
    const child = evmz.addr(0x1234);

    var executor = Default.init(std.testing.allocator, .{ .revision = .cancun });
    defer executor.deinit();

    var capture: CaptureHarness = undefined;
    capture.init(&executor);
    defer capture.deinit(&executor);
    try capture.context.begin();
    errdefer capture.context.abort() catch {};

    var host = executor.host();
    const result = (try host.call(.{
        .depth = evmz.Host.max_call_depth + 1,
        .kind = .call,
        .gas = 20_000,
        .recipient = child,
        .sender = sender,
        .input_data = &.{},
        .value = 0,
        .code_address = child,
    })).expectCall();
    const span = try capture.finish(&executor);

    try std.testing.expectEqual(evmz.interpreter.Status.invalid, result.status);
    try std.testing.expectEqual(evmz.execution.TerminalCause.call_depth_exceeded, result.cause.?);
    try std.testing.expectEqual(@as(usize, 1), span.rows.len);
    try std.testing.expectEqual(evmz.trace.CallStatus.call_depth_exceeded, span.rows[0].status);
    try std.testing.expectEqual(@as(i64, 0), span.rows[0].gas_used);
}

test "call capture retains opcode-local CALL depth attempt" {
    const sender = evmz.addr(0xaaaa);
    const root = evmz.addr(0x1000);
    const child = evmz.addr(0x1234);
    const root_code = evmz.t.bytecode(.{
        .PUSH0, .PUSH0, .PUSH0, .PUSH0, .PUSH0,
        .PUSH2, 0x12,   0x34,   .GAS,   .CALL,
        .POP,   .STOP,
    });

    var executor = Default.init(std.testing.allocator, .{ .revision = .cancun });
    defer executor.deinit();
    try seedCode(&executor, root, &root_code, 0);

    var capture: CaptureHarness = undefined;
    capture.init(&executor);
    defer capture.deinit(&executor);
    try capture.context.begin();
    errdefer capture.context.abort() catch {};

    var host = executor.host();
    const result = (try host.call(.{
        .depth = evmz.Host.max_call_depth,
        .kind = .call,
        .gas = 200_000,
        .recipient = root,
        .sender = sender,
        .input_data = &.{},
        .value = 0,
        .code_address = root,
    })).expectCall();
    const span = try capture.finish(&executor);

    try std.testing.expectEqual(evmz.interpreter.Status.success, result.status);
    try std.testing.expectEqual(@as(usize, 2), span.rows.len);
    try std.testing.expectEqual(@as(?u32, 0), span.rows[1].parent_index);
    try std.testing.expectEqual(evmz.Host.max_call_depth + 1, span.rows[1].depth);
    try std.testing.expectEqual(evmz.trace.CallKind.call, span.rows[1].kind);
    try std.testing.expectEqual(evmz.trace.CallStatus.call_depth_exceeded, span.rows[1].status);
    try std.testing.expectEqual(@as(i64, 0), span.rows[1].gas_used);
    try std.testing.expectEqual(child, span.rows[1].to);
}

test "call capture retains opcode-local CREATE precheck attempts" {
    const sender = evmz.addr(0xaaaa);
    const root = evmz.addr(0x1000);
    const create_zero = evmz.t.bytecode(.{
        .PUSH0, .PUSH0, .PUSH0, .CREATE, .POP, .STOP,
    });
    const create2_value = evmz.t.bytecode(.{
        .PUSH0, .PUSH0, .PUSH0, .PUSH1, 0x01, .CREATE2, .POP, .STOP,
    });

    const Case = struct {
        name: []const u8,
        code: []const u8,
        depth: u16,
        nonce: u64,
        balance: u256,
        kind: evmz.trace.CallKind,
        status: evmz.trace.CallStatus,
        target: evmz.Address,
    };
    const max_nonce = std.math.maxInt(u64);
    const cases = [_]Case{
        .{
            .name = "CREATE depth",
            .code = &create_zero,
            .depth = evmz.Host.max_call_depth,
            .nonce = 7,
            .balance = 0,
            .kind = .create,
            .status = .call_depth_exceeded,
            .target = evmz.address.create(root, 7),
        },
        .{
            .name = "CREATE2 balance",
            .code = &create2_value,
            .depth = 0,
            .nonce = 7,
            .balance = 0,
            .kind = .create2,
            .status = .insufficient_balance,
            .target = evmz.address.create2(root, 0, &.{}),
        },
        .{
            .name = "CREATE nonce",
            .code = &create_zero,
            .depth = 0,
            .nonce = max_nonce,
            .balance = 0,
            .kind = .create,
            .status = .nonce_overflow,
            .target = evmz.address.create(root, max_nonce),
        },
    };

    for (cases) |case| {
        errdefer std.log.err("opcode-local create case failed: {s}", .{case.name});

        var executor = Default.init(std.testing.allocator, .{ .revision = .cancun });
        defer executor.deinit();

        var root_account = MemoryAccount.init(std.testing.allocator);
        root_account.nonce = case.nonce;
        root_account.balance = case.balance;
        try root_account.setCode(case.code);
        try executor.state.seedAccount(root, root_account);

        var capture: CaptureHarness = undefined;
        capture.init(&executor);
        defer capture.deinit(&executor);
        try capture.context.begin();
        errdefer capture.context.abort() catch {};

        var host = executor.host();
        const result = (try host.call(.{
            .depth = case.depth,
            .kind = .call,
            .gas = 200_000,
            .recipient = root,
            .sender = sender,
            .input_data = &.{},
            .value = 0,
            .code_address = root,
        })).expectCall();
        const span = try capture.finish(&executor);

        try std.testing.expectEqual(evmz.interpreter.Status.success, result.status);
        try std.testing.expectEqual(@as(usize, 2), span.rows.len);
        try std.testing.expectEqual(@as(?u32, 0), span.rows[1].parent_index);
        try std.testing.expectEqual(case.kind, span.rows[1].kind);
        try std.testing.expectEqual(case.status, span.rows[1].status);
        try std.testing.expectEqual(@as(i64, 0), span.rows[1].gas_used);
        try std.testing.expectEqual(case.target, span.rows[1].to);
        try std.testing.expectEqual(case.nonce, executor.getAccount(root).?.nonce);
        try std.testing.expect(!executor.state.warm_accounts.contains(case.target));
    }
}

test "call capture distinguishes CREATE collision from rollback" {
    const sender = evmz.addr(0xaaaa);
    const root = evmz.addr(0x1000);
    const root_nonce = 7;
    const target = evmz.address.create(root, root_nonce);
    const root_code = evmz.t.bytecode(.{
        .PUSH0, .PUSH0, .PUSH0, .CREATE, .POP, .STOP,
    });

    var executor = Default.init(std.testing.allocator, .{ .revision = .cancun });
    defer executor.deinit();

    var root_account = MemoryAccount.init(std.testing.allocator);
    root_account.nonce = root_nonce;
    try root_account.setCode(&root_code);
    try executor.state.seedAccount(root, root_account);

    var target_account = MemoryAccount.init(std.testing.allocator);
    target_account.nonce = 1;
    try executor.state.seedAccount(target, target_account);

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
    try std.testing.expectEqual(evmz.trace.CallStatus.contract_address_collision, span.rows[1].status);
    try std.testing.expect(!span.rows[1].checkpointReverted());
    try std.testing.expectEqual(@as(?evmz.Address, null), span.rows[1].createdAddress());
    try std.testing.expectEqual(target, span.rows[1].to);
    try std.testing.expectEqual(@as(u64, root_nonce + 1), executor.getAccount(root).?.nonce);
    try std.testing.expectEqual(@as(u64, 1), executor.getAccount(target).?.nonce);
}

test "call capture retains invalid deployed code and local rollback" {
    const sender = evmz.addr(0xaaaa);
    const root = evmz.addr(0x1000);
    const target = evmz.address.create(root, 0);
    const init_code_len = 8;
    const init_code_offset = 13;
    const root_code = evmz.t.bytecode(.{
        .PUSH1, init_code_len, .PUSH1,  init_code_offset, .PUSH0,   .CODECOPY,
        .PUSH1, init_code_len, .PUSH0,  .PUSH0,           .CREATE,  .POP,
        .STOP,  .PUSH1,        0xef,    .PUSH0,           .MSTORE8, .PUSH1,
        0x01,   .PUSH0,        .RETURN,
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
    try std.testing.expectEqual(evmz.trace.CallStatus.invalid_code, span.rows[1].status);
    try std.testing.expect(span.rows[1].checkpointReverted());
    try std.testing.expectEqual(@as(?evmz.Address, null), span.rows[1].createdAddress());
    try std.testing.expectEqual(target, span.rows[1].to);
    try std.testing.expect(executor.getAccount(target) == null);
}

test "call capture retains Frontier committed code-store out-of-gas" {
    const sender = evmz.addr(0xaaaa);
    const target = evmz.address.create(sender, 0);
    const init_code = evmz.t.bytecode(.{
        .PUSH1, 0x01, .PUSH1, 0x00, .RETURN,
    });

    var executor = Default.init(std.testing.allocator, .{ .revision = .frontier });
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
        evmz.t.defaultTxContext(sender, 100),
        .{ .create = .{
            .sender = sender,
            .recipient = target,
            .init_code = &init_code,
        } },
        .legacy(100),
    )).expectCreate();
    const span = try capture.finish(&executor);

    try std.testing.expectEqual(evmz.interpreter.Status.success, result.status);
    try std.testing.expectEqual(evmz.execution.TerminalCause.code_store_out_of_gas, result.cause.?);
    try std.testing.expect(!result.checkpoint_reverted);
    try std.testing.expectEqual(@as(usize, 1), span.rows.len);
    try std.testing.expectEqual(evmz.trace.CallStatus.code_store_out_of_gas_committed, span.rows[0].status);
    try std.testing.expect(!span.rows[0].checkpointReverted());
    try std.testing.expectEqual(@as(?evmz.Address, target), span.rows[0].createdAddress());
    try std.testing.expectEqual(@as(usize, 0), (try executor.getCode(target)).len);
}

test "call capture retains pinned Geth v1.17.4 frame error categories" {
    const sender = evmz.addr(0xaaaa);
    const root = evmz.addr(0x1000);
    const invalid_opcode = [_]u8{0x0c};
    const stack_underflow = [_]u8{evmz.Opcode.ADD.toByte()};
    const invalid_jump = evmz.t.bytecode(.{ .PUSH0, .JUMP });
    const return_data_out_of_bounds = evmz.t.bytecode(.{
        .PUSH1,          0x01,
        .PUSH0,          .PUSH0,
        .RETURNDATACOPY,
    });
    const stack_overflow = [_]u8{evmz.Opcode.PUSH0.toByte()} ** 1025;

    const Case = struct {
        name: []const u8,
        code: []const u8,
        cause: evmz.execution.TerminalCause,
        call_status: evmz.trace.CallStatus,
    };
    const cases = [_]Case{
        .{ .name = "invalid opcode", .code = &invalid_opcode, .cause = .invalid_opcode, .call_status = .invalid_opcode },
        .{ .name = "stack underflow", .code = &stack_underflow, .cause = .stack_underflow, .call_status = .stack_underflow },
        .{ .name = "stack overflow", .code = &stack_overflow, .cause = .stack_overflow, .call_status = .stack_overflow },
        .{ .name = "invalid jump", .code = &invalid_jump, .cause = .invalid_jump, .call_status = .invalid_jump },
        .{ .name = "return data out of bounds", .code = &return_data_out_of_bounds, .cause = .return_data_out_of_bounds, .call_status = .return_data_out_of_bounds },
    };

    for (cases) |case| {
        errdefer std.log.err("pinned call error case failed: {s}", .{case.name});

        var executor = Default.init(std.testing.allocator, .{ .revision = .cancun });
        defer executor.deinit();
        try seedCode(&executor, root, case.code, 0);

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

        try std.testing.expectEqual(evmz.interpreter.Status.invalid, result.status);
        try std.testing.expectEqual(case.cause, result.cause.?);
        try std.testing.expectEqual(@as(usize, 1), span.rows.len);
        try std.testing.expectEqual(case.call_status, span.rows[0].status);
    }
}

test "call capture retains pinned write-protection category" {
    const sender = evmz.addr(0xaaaa);
    const root = evmz.addr(0x1000);
    const child = evmz.addr(0x1234);
    const root_code = evmz.t.bytecode(.{
        .PUSH0,      .PUSH0, .PUSH0, .PUSH0,
        .PUSH2,      0x12,   0x34,   .GAS,
        .STATICCALL, .POP,   .STOP,
    });
    const child_code = evmz.t.bytecode(.{.SSTORE});

    var executor = Default.init(std.testing.allocator, .{ .revision = .cancun });
    defer executor.deinit();
    try seedCode(&executor, root, &root_code, 0);
    try seedCode(&executor, child, &child_code, 0);

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
    try std.testing.expectEqual(evmz.trace.CallStatus.write_protection, span.rows[1].status);
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
