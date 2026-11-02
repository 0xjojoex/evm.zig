const evmz = @import("../../evm.zig");
const std = @import("std");

test "MSTORE charges once across growth, unaligned growth, and an expanded overwrite" {
    const Latest = evmz.t.CaptureVm(.latest).?;
    const Opcode = evmz.opcode.Opcode;
    const code = evmz.t.bytecode(.{
        .MSTORE, .PUSH1, 0xbb,   .PUSH1, 0x01,    .MSTORE,
        .PUSH1,  0xcc,   .PUSH1, 0x01,   .MSTORE, .STOP,
    });
    inline for (.{ false, true }) |captured| {
        var mock_host = evmz.t.MockHost.init(std.testing.allocator, null);
        defer mock_host.deinit();
        var host = mock_host.host();
        var msg = evmz.t.defaultMessage();
        var frame = try Latest.Interpreter.OwnedCallFrame.init(std.testing.allocator, .{
            .host = &host,
            .msg = &msg,
            .execution_context = &mock_host.execution_context,
            .source = .{ .code = &code },
        });
        defer frame.deinit();
        const expansion_gas = frame.frame.memory.planExpansion(1, 32).?.cost;
        const mstore_gas = Latest.spec.instruction.entry(@backingInt(Opcode.MSTORE)).info.static_gas;
        const push_gas = Latest.spec.instruction.entry(@backingInt(Opcode.PUSH1)).info.static_gas;
        const stop_gas = Latest.spec.instruction.entry(@backingInt(Opcode.STOP)).info.static_gas;
        frame.frame.stack.push(0xaa);
        frame.frame.stack.push(0);
        var interpreter = frame.interpreter();
        var tape = evmz.trace.TraceTape.initGrowable(std.testing.allocator);
        defer tape.deinit();
        const result = if (captured) blk: {
            const execution = try interpreter.capture(&tape, .{});
            defer tape.resolve(execution.span) catch unreachable;
            break :blk execution.result;
        } else try interpreter.execute();
        try std.testing.expectEqual(evmz.interpreter.Status.success, result.status());
        try std.testing.expectEqual(msg.gas - expansion_gas - 3 * mstore_gas - 4 * push_gas - stop_gas, result.gas_left);
        try std.testing.expectEqual(@as(usize, 64), frame.frame.memory.len());
        try std.testing.expectEqual(@as(u256, 0xcc), frame.frame.memory.read(1));
        try std.testing.expectEqual(@as(u16, 0), frame.frame.stack.len);
    }
}

test "MSTORE overwrites already expanded memory" {
    try evmz.t.expectLatestForkBytecodeStackTop(.{
        .PUSH1,  0xaa,
        .PUSH1,  0x00,
        .MSTORE, .PUSH1,
        0xbb,    .PUSH1,
        0x00,    .MSTORE,
        .PUSH1,  0x00,
        .MLOAD,
    }, 0xbb);
}

test "MCOPY is only enabled from Cancun" {
    try evmz.t.expectBytecodeStatusByRevision(.{ .PUSH0, .PUSH0, .PUSH0, .MCOPY }, .shanghai, .invalid);
    try evmz.t.expectBytecodeStatusByRevision(.{ .PUSH0, .PUSH0, .PUSH0, .MCOPY }, .cancun, .success);
}

test "MCOPY zero length ignores out of bounds offsets" {
    try evmz.t.expectLatestForkBytecodeStatus(
        .{
            .PUSH0, .PUSH0, .PUSH32,
            0xff,   0xff,   0xff,
            0xff,   0xff,   0xff,
            0xff,   0xff,   0xff,
            0xff,   0xff,   0xff,
            0xff,   0xff,   0xff,
            0xff,   0xff,   0xff,
            0xff,   0xff,   0xff,
            0xff,   0xff,   0xff,
            0xff,   0xff,   0xff,
            0xff,   0xff,   0xff,
            0xff,   0xff,   .MCOPY,
        },
        .success,
    );
}
