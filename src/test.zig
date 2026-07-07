test {
    _ = @import("./test/gas_bound_checkpoint.zig");
    _ = @import("./test/eip2200.zig");
    _ = @import("./test/amsterdam/eip2780.zig");
    _ = @import("./test/amsterdam/eip8037.zig");
    _ = @import("./test/amsterdam/eip8038.zig");
}

const std = @import("std");
const evmz = @import("evm.zig");
const Opcode = evmz.Opcode;

test "protocol definition plugs into existing runtime code" {
    const Cancun = evmz.eth.fork(.cancun);

    try std.testing.expectEqual(evmz.protocol.Resolution.always, Cancun.Instruction.availability(Cancun.Instruction.fromByte(@intFromEnum(Opcode.BLOBBASEFEE))));
    try std.testing.expectEqual(evmz.protocol.Resolution.never, Cancun.Instruction.availability(Cancun.Instruction.fromByte(@intFromEnum(Opcode.SLOTNUM))));
    try std.testing.expect(Cancun.support.min == .cancun);
    try std.testing.expect(Cancun.support.max == .cancun);
    try std.testing.expect(Cancun.hot_cold_dispatch_enabled);
    try std.testing.expect(@hasDecl(evmz.Vm(Cancun), "transact"));
    try std.testing.expect(@hasDecl(evmz.Executor(Cancun), "runStandalone"));
    try std.testing.expect(@hasDecl(evmz.Interpreter.For(Cancun), "execute"));

    var evm = evmz.Vm(Cancun).init(std.testing.allocator, .{ .revision = .cancun });
    defer evm.deinit();

    const result = try evm.executor.runStandalone(evm.env.txContext(evmz.addr(0xaaaa), 0, 100_000, &.{}), .{
        .call = .{
            .sender = evmz.addr(0xaaaa),
            .recipient = evmz.addr(0xbbbb),
            .gas = 100_000,
        },
    });
    try std.testing.expectEqual(evmz.Interpreter.Status.success, result.expectCall().status);
}
