test {
    _ = @import("./test/gas_bound_checkpoint.zig");
    _ = @import("./test/eip2200.zig");
    _ = @import("./test/amsterdam/eip2780.zig");
    _ = @import("./test/amsterdam/bal_fixtures.zig");
    _ = @import("./test/amsterdam/eip8037.zig");
    _ = @import("./test/amsterdam/eip8038.zig");
}

const std = @import("std");
const evmz = @import("evm.zig");
const Opcode = evmz.Opcode;

test "protocol definition plugs into existing runtime code" {
    const CancunVM = evmz.EvmWith(.{
        .support = evmz.Evm.Support.at(.cancun),
    });
    const Cancun = CancunVM.Protocol;

    try std.testing.expectEqual(evmz.protocol.Resolution.always, Cancun.Instruction.availability(Cancun.Instruction.fromByte(@intFromEnum(Opcode.BLOBBASEFEE))));
    try std.testing.expectEqual(evmz.protocol.Resolution.never, Cancun.Instruction.availability(Cancun.Instruction.fromByte(@intFromEnum(Opcode.SLOTNUM))));
    try std.testing.expect(Cancun.support.min == .cancun);
    try std.testing.expect(Cancun.support.max == .cancun);
    try std.testing.expect(Cancun.hot_cold_dispatch_enabled);
    try std.testing.expect(@hasDecl(CancunVM, "transact"));
    try std.testing.expect(@hasDecl(CancunVM.Executor, "runStandalone"));
    try std.testing.expect(@hasDecl(CancunVM.Interpreter, "execute"));
    try std.testing.expectEqual(Cancun.Revision, CancunVM.Revision);
    try std.testing.expectEqual(Cancun.Transaction.Value, CancunVM.Transaction);
    try std.testing.expectEqual(Cancun.Transaction.View, CancunVM.TransactionView);
    try std.testing.expectEqual(Cancun.Transaction.ValidationError, CancunVM.ValidationError);
    try std.testing.expectEqual(evmz.Evm.Executor, evmz.Executor);
    try std.testing.expectEqual(evmz.Evm.Interpreter, evmz.Interpreter);
    try std.testing.expectEqual(evmz.vm.OptionsFor(evmz.eth.definition), evmz.Evm.Options);
    try std.testing.expectEqual(evmz.Evm.Protocol.Support, evmz.Evm.Support);
    try std.testing.expectEqual(evmz.Evm, evmz.EvmWith(.{}));

    var evm = CancunVM.init(std.testing.allocator, .{ .revision = .cancun });
    defer evm.deinit();

    const result = try evm.executor.runStandalone(evm.env.txContext(evmz.addr(0xaaaa), 0, 100_000, &.{}), .{
        .call = .{
            .sender = evmz.addr(0xaaaa),
            .recipient = evmz.addr(0xbbbb),
            .gas = 100_000,
        },
    });
    try std.testing.expectEqual(CancunVM.Interpreter.Status.success, result.expectCall().status);
}

test "typed Evm support options resolve the protocol window" {
    const SinceCancun = evmz.EvmWith(.{ .support = evmz.Evm.Support.since(.cancun) });
    const ThroughCancun = evmz.EvmWith(.{ .support = evmz.Evm.Support.through(.cancun) });
    const LondonToCancun = evmz.EvmWith(.{ .support = .{
        .min = .london,
        .max = .cancun,
    } });

    try std.testing.expectEqual(evmz.Evm, evmz.Vm(evmz.eth.Revision, evmz.eth.definition, .{}));
    try std.testing.expectEqual(evmz.eth.Revision.cancun, SinceCancun.Protocol.support.min);
    try std.testing.expectEqual(evmz.Evm.Support.all.max, SinceCancun.Protocol.support.max);
    try std.testing.expectEqual(evmz.Evm.Support.all.min, ThroughCancun.Protocol.support.min);
    try std.testing.expectEqual(evmz.eth.Revision.cancun, ThroughCancun.Protocol.support.max);
    try std.testing.expectEqual(evmz.eth.Revision.london, LondonToCancun.Protocol.support.min);
    try std.testing.expectEqual(evmz.eth.Revision.cancun, LondonToCancun.Protocol.support.max);
}
