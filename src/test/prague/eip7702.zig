const std = @import("std");
const evmz = @import("../../evm.zig");

const transaction = evmz.transaction;

test "Prague ordinary transactions warm the delegated destination target" {
    const Prague = evmz.t.Vm(.prague) orelse return error.SkipZigTest;

    inline for (.{
        transaction.TxKind.legacy,
        transaction.TxKind.access_list,
        transaction.TxKind.dynamic_fee,
    }) |kind| {
        try expectDelegatedTargetWarm(Prague, kind);
    }
}

fn expectDelegatedTargetWarm(comptime ExactVm: type, comptime kind: transaction.TxKind) !void {
    const sender = evmz.addr(0x1111);
    const destination = evmz.addr(0x2222);
    const implementation = evmz.addr(0x3333);
    var executor = ExactVm.Executor.init(std.testing.allocator, .{});
    defer executor.deinit();

    try evmz.t.seedExecutorAccount(&executor, sender, .{ .balance = 1_000_000 });

    var delegation_code: [evmz.eip7702.delegation_code_len]u8 = undefined;
    evmz.eip7702.writeDelegationCode(&delegation_code, implementation);
    try evmz.t.seedExecutorAccount(&executor, destination, .{ .code = &delegation_code });

    var implementation_code: [23]u8 = undefined;
    implementation_code[0] = evmz.Opcode.PUSH20.toByte();
    @memcpy(implementation_code[1..21], implementation.asBytes());
    implementation_code[21] = evmz.Opcode.BALANCE.toByte();
    implementation_code[22] = evmz.Opcode.STOP.toByte();
    try evmz.t.seedExecutorAccount(&executor, implementation, .{ .code = &implementation_code });

    const outcome = try ExactVm.Advanced.transact(&executor, .{
        .env = .{ .gas_limit = 100_000 },
        .tx = .{
            .kind = kind,
            .sender = sender,
            .to = destination,
            .gas_limit = 100_000,
            .gas_price = 1,
            .max_fee_per_gas = 1,
            .max_priority_fee_per_gas = 0,
        },
    });
    const executed = switch (outcome) {
        .executed => |value| value,
        .rejected => return error.UnexpectedRejection,
    };
    defer executed.discardIfCurrent();

    try std.testing.expectEqual(evmz.TxStatus.success, executed.result().status);
    try std.testing.expectEqual(@as(u64, 21_103), executed.result().gas.used);
}
