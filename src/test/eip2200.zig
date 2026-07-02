const std = @import("std");
const evmz = @import("../evm.zig");

const Host = evmz.Host;
const Interpreter = evmz.Interpreter;
const Opcode = evmz.Opcode;
const t = evmz.t;

const Eip2200Vector = struct {
    code: []const u8,
    gas_used: i64,
    refund: i64,
    original: u256,
    final: u256,
};

test "EIP-2200 official SSTORE gas/refund vectors" {
    const vectors = [_]Eip2200Vector{
        .{ .code = "60006000556000600055", .gas_used = 1612, .refund = 0, .original = 0, .final = 0 },
        .{ .code = "60006000556001600055", .gas_used = 20812, .refund = 0, .original = 0, .final = 1 },
        .{ .code = "60016000556000600055", .gas_used = 20812, .refund = 19200, .original = 0, .final = 0 },
        .{ .code = "60016000556002600055", .gas_used = 20812, .refund = 0, .original = 0, .final = 2 },
        .{ .code = "60016000556001600055", .gas_used = 20812, .refund = 0, .original = 0, .final = 1 },
        .{ .code = "60006000556000600055", .gas_used = 5812, .refund = 15000, .original = 1, .final = 0 },
        .{ .code = "60006000556001600055", .gas_used = 5812, .refund = 4200, .original = 1, .final = 1 },
        .{ .code = "60006000556002600055", .gas_used = 5812, .refund = 0, .original = 1, .final = 2 },
        .{ .code = "60026000556000600055", .gas_used = 5812, .refund = 15000, .original = 1, .final = 0 },
        .{ .code = "60026000556003600055", .gas_used = 5812, .refund = 0, .original = 1, .final = 3 },
        .{ .code = "60026000556001600055", .gas_used = 5812, .refund = 4200, .original = 1, .final = 1 },
        .{ .code = "60026000556002600055", .gas_used = 5812, .refund = 0, .original = 1, .final = 2 },
        .{ .code = "60016000556000600055", .gas_used = 5812, .refund = 15000, .original = 1, .final = 0 },
        .{ .code = "60016000556002600055", .gas_used = 5812, .refund = 0, .original = 1, .final = 2 },
        .{ .code = "60016000556001600055", .gas_used = 1612, .refund = 0, .original = 1, .final = 1 },
        .{ .code = "600160005560006000556001600055", .gas_used = 40818, .refund = 19200, .original = 0, .final = 1 },
        .{ .code = "600060005560016000556000600055", .gas_used = 10818, .refund = 19200, .original = 1, .final = 0 },
    };

    for (vectors) |vector| {
        const result = try runSstoreVector(vector.code, vector.original, .istanbul);
        try std.testing.expectEqual(Interpreter.Status.success, result.status);
        try std.testing.expectEqual(vector.gas_used, test_gas - result.gas_left);
        try std.testing.expectEqual(vector.refund, result.gas_refund);
        try std.testing.expectEqual(vector.final, result.final_storage);
    }
}

test "EIP-2200 child frame refunds merge only from committed frames" {
    var frame = try testingFrame();
    defer frame.deinit();

    try frame.frame.resumeCallResult(.{
        .gas_limit = 50,
        .out_offset = 0,
        .out_size = 0,
    }, .{
        .status = .success,
        .output_data = &.{},
        .gas_left = 30,
        .gas_refund = 4_800,
    });
    try std.testing.expectEqual(@as(i64, 80), frame.frame.gas_left);
    try std.testing.expectEqual(@as(i64, 4_800), frame.frame.gas_refund);

    try frame.frame.resumeCreateResult(.{ .gas_limit = 10 }, .{
        .status = .success,
        .output_data = &.{},
        .gas_left = 4,
        .gas_refund = 7,
        .address = evmz.addr(0xbeef),
    });
    try std.testing.expectEqual(@as(i64, 74), frame.frame.gas_left);
    try std.testing.expectEqual(@as(i64, 4_807), frame.frame.gas_refund);

    try frame.frame.resumeCallResult(.{
        .gas_limit = 10,
        .out_offset = 0,
        .out_size = 0,
    }, .{
        .status = .revert,
        .output_data = &.{},
        .gas_left = 8,
        .gas_refund = 99,
    });
    try std.testing.expectEqual(@as(i64, 72), frame.frame.gas_left);
    try std.testing.expectEqual(@as(i64, 4_807), frame.frame.gas_refund);
}

test "EIP-2200 reverted frames discard local refund counter" {
    var frame = try testingFrame();
    defer frame.deinit();

    frame.frame.gas_refund = 4_800;
    frame.frame.status = .revert;

    const result = frame.frame.getResult();
    try std.testing.expectEqual(Interpreter.Status.revert, result.status);
    try std.testing.expectEqual(@as(i64, 0), result.gas_refund);
}

const test_gas: i64 = 100_000;

const SstoreResult = struct {
    status: Interpreter.Status,
    gas_left: i64,
    gas_refund: i64,
    final_storage: u256,
};

fn runSstoreVector(hex_code: []const u8, original: u256, spec: evmz.Spec) !SstoreResult {
    var code_buf: [32]u8 = undefined;
    const code = try std.fmt.hexToBytes(&code_buf, hex_code);

    var mock_host = t.MockHost.init(std.testing.allocator, null);
    defer mock_host.deinit();
    try mock_host.seedStorage(0, original);
    var host = mock_host.host();
    var msg = t.defaultMessage();
    msg.gas = test_gas;

    const result = try t.runBytecodeWithHost(&host, &msg, code, spec);
    return .{
        .status = result.status,
        .gas_left = result.gas_left,
        .gas_refund = result.gas_refund,
        .final_storage = mock_host.storageValue(0),
    };
}

fn testingFrame() !Interpreter.OwnedCallFrame {
    const code = [_]u8{@intFromEnum(Opcode.STOP)};
    var host: Host = undefined;
    const msg = Host.Message{
        .depth = 0,
        .kind = .call,
        .gas = 100,
        .recipient = evmz.addr(0),
        .sender = evmz.addr(0),
        .input_data = &.{},
        .value = 0,
    };

    return Interpreter.OwnedCallFrame.init(std.testing.allocator, .{
        .host = &host,
        .msg = &msg,
        .code = &code,
        .spec = .latest,
    });
}
