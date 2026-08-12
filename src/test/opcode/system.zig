const std = @import("std");
const evmz = @import("../../evm.zig");
const Interpreter = @import("../../Interpreter.zig");
const system = @import("../../instruction/system.zig");

test "CREATE initcode limit is independent from transaction validation" {
    const spec = evmz.eth.cancun.extend(.{
        .transaction = .{ .max_initcode_size = 64 },
        .create = .{ .initcode_size_limit = .{ .replace = 1 } },
    });

    var mock_host = evmz.t.MockHost.init(std.testing.allocator, null);
    defer mock_host.deinit();
    var host = mock_host.host();
    var msg = evmz.t.defaultMessage();

    var frame = try Interpreter.Interpreter(spec).OwnedCallFrame.init(std.testing.allocator, .{
        .host = &host,
        .msg = &msg,
    });
    defer frame.deinit();

    // Direct handler tests must model a frame that is still executing.
    frame.frame.state = .running;
    frame.frame.stack.push(2);
    frame.frame.stack.push(0);
    frame.frame.stack.push(0);
    try system.Handlers(spec).create(frame.frame);

    try std.testing.expectEqual(Interpreter.FrameHalt.out_of_gas, frame.frame.haltReason().?);
}

test "RETURN zero length ignores oversized offset" {
    try evmz.t.expectLatestForkBytecodeStatus(.{
        .PUSH0,  .PUSH32,
        0xff,    0xff,
        0xff,    0xff,
        0xff,    0xff,
        0xff,    0xff,
        0xff,    0xff,
        0xff,    0xff,
        0xff,    0xff,
        0xff,    0xff,
        0xff,    0xff,
        0xff,    0xff,
        0xff,    0xff,
        0xff,    0xff,
        0xff,    0xff,
        0xff,    0xff,
        0xff,    0xff,
        0xff,    0xff,
        .RETURN,
    }, .success);
}
