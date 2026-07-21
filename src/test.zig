test {
    _ = @import("./test/execution_boundary.zig");
    _ = @import("./test/execution_precompile_runtime.zig");
    _ = @import("./test/block_lifecycle.zig");
    _ = @import("./test/gas_bound_checkpoint.zig");
    _ = @import("./test/block_stf_cases.zig");
    _ = @import("./test/mpt_package_test.zig");
    _ = @import("./test/eip2200.zig");
    _ = @import("./test/amsterdam/eip2780.zig");
    _ = @import("./test/amsterdam/bal_fixtures.zig");
    _ = @import("./test/amsterdam/bal_differential.zig");
    _ = @import("./test/amsterdam/bal_witness.zig");
    _ = @import("./test/amsterdam/block_stf_produce.zig");
    _ = @import("./test/amsterdam/eip8037.zig");
    _ = @import("./test/amsterdam/eip8038.zig");
    _ = @import("./test/amsterdam/transaction_preparation.zig");
}

const std = @import("std");
const evmz = @import("evm.zig");
const Opcode = evmz.Opcode;

test "protocol definition plugs into existing runtime code" {
    const CancunVM = evmz.EvmWith(.{
        .support = evmz.Evm.Support.at(.cancun),
    });
    const Cancun = CancunVM.ExecutionProtocol;

    try std.testing.expectEqual(evmz.protocol.Resolution.always, Cancun.Instruction.availability(Cancun.Instruction.fromByte(@intFromEnum(Opcode.BLOBBASEFEE))));
    try std.testing.expectEqual(evmz.protocol.Resolution.never, Cancun.Instruction.availability(Cancun.Instruction.fromByte(@intFromEnum(Opcode.SLOTNUM))));
    try std.testing.expect(Cancun.support.min == .cancun);
    try std.testing.expect(Cancun.support.max == .cancun);
    try std.testing.expect(Cancun.hot_cold_dispatch_enabled);
    try std.testing.expect(@hasDecl(CancunVM, "transact"));
    try std.testing.expect(@hasDecl(CancunVM, "BlockExecution"));
    try std.testing.expect(@hasDecl(evmz.eth, "BlockSTF"));
    try std.testing.expectEqual(@as(usize, 1), @typeInfo(CancunVM).@"struct".fields.len);
    try std.testing.expect(@hasField(CancunVM, "transaction_runtime"));
    try std.testing.expect(@hasDecl(CancunVM, "init"));
    try std.testing.expect(@hasDecl(CancunVM.Executor, "runStandalone"));
    try std.testing.expect(@hasDecl(CancunVM.Executor, "runStandaloneRequest"));
    try std.testing.expect(@hasDecl(CancunVM.Interpreter, "execute"));
    try std.testing.expectEqual(Cancun.Revision, CancunVM.Revision);
    try std.testing.expectEqual(Cancun.Instruction.Value, CancunVM.Instruction.Value);
    try std.testing.expectEqual(
        Cancun.Instruction.entry(Cancun.Instruction.fromByte(@intFromEnum(Opcode.ADD))),
        CancunVM.Instruction.entry(CancunVM.Instruction.fromByte(@intFromEnum(Opcode.ADD))),
    );
    try std.testing.expectEqual(CancunVM.TransactionProtocol.Tx.Value, CancunVM.Transaction);
    try std.testing.expectEqual(CancunVM.TransactionProtocol.Tx.View, CancunVM.TransactionView);
    try std.testing.expectEqual(CancunVM.TransactionProtocol.Tx.ValidationError, CancunVM.Rejection);
    try std.testing.expectEqual(evmz.Evm.Executor, evmz.Executor);
    try std.testing.expectEqual(evmz.Evm.Interpreter, evmz.Interpreter);
    try std.testing.expectEqual(evmz.vm.OptionsFor(evmz.eth.execution_definition), evmz.Evm.Options);
    try std.testing.expectEqual(evmz.Evm.ExecutionProtocol.Support, evmz.Evm.Support);
    try std.testing.expectEqual(evmz.eth.Revision, evmz.Evm.BaseRevision);
    try std.testing.expectEqual(evmz.eth.Revision.cancun, evmz.Evm.baseRevision(.cancun));
    try std.testing.expectEqual(evmz.Evm, evmz.EvmWith(.{}));
    try std.testing.expectEqual(evmz.execution.Message, evmz.Message);
    try std.testing.expect(@hasDecl(evmz.Evm.TransactionProtocol.Settlement, "Plan"));
    try std.testing.expect(@hasDecl(evmz.Evm.TransactionProtocol.Settlement, "Costs"));
    try std.testing.expect(@hasDecl(evmz.Evm.TransactionProtocol, "authorization"));
    try std.testing.expect(@hasDecl(evmz.Evm.ExecutionProtocol, "call"));
    try std.testing.expect(@hasDecl(evmz.Evm.ExecutionProtocol, "create"));
    try std.testing.expect(@hasDecl(evmz.Evm.ExecutionProtocol, "storage"));
    try std.testing.expect(@hasDecl(evmz.Evm.ExecutionProtocol, "self_destruct"));
    try std.testing.expect(!@hasDecl(evmz.Evm.TransactionProtocol, "Authorization"));
    try std.testing.expect(!@hasDecl(evmz.Evm.ExecutionProtocol, "Call"));
    try std.testing.expect(!@hasDecl(evmz.Evm.ExecutionProtocol, "Create"));
    try std.testing.expect(!@hasDecl(evmz.Evm.ExecutionProtocol, "Storage"));
    try std.testing.expect(!@hasDecl(evmz.Evm.ExecutionProtocol, "SelfDestruct"));
    try std.testing.expect(!@hasDecl(evmz.transaction, "Settlement"));
    try std.testing.expect(!@hasDecl(evmz.transaction, "SettlementCosts"));

    var executor = CancunVM.Executor.init(std.testing.allocator, .{ .revision = .cancun });
    defer executor.deinit();
    const env: evmz.vm.Env = .{};
    const result = try executor.runStandalone(env.txContext(evmz.addr(0xaaaa), 0, 100_000, &.{}), .{
        .call = .{
            .sender = evmz.addr(0xaaaa),
            .recipient = evmz.addr(0xbbbb),
        },
    }, .legacy(100_000));
    try std.testing.expectEqual(CancunVM.Interpreter.Status.success, result.expectCall().status);
}

test "decomposed definitions keep the concrete engine transaction value" {
    const CustomExecution = comptime evmz.eth.defineExecution(.{ .name = "custom-semantics" });
    const CustomVm = evmz.Vm(
        evmz.eth.Revision,
        CustomExecution,
        evmz.eth.transaction_definition,
        evmz.eth.block_definition,
        .{ .support = .{ .min = .cancun, .max = .cancun } },
    );

    try std.testing.expect(CustomVm.Transaction == evmz.Transaction);
    try std.testing.expect(CustomVm.TransactionView == evmz.transaction.TransactionView);
    try std.testing.expect(CustomVm.TransactionProtocol.Tx.Value == evmz.Transaction);
    try std.testing.expect(!@hasDecl(evmz.vm, "ResolvedVm"));
}

test "protocol surface flattens semantic types and hides validation" {
    try std.testing.expect(!@hasDecl(evmz.protocol, "types"));
    try std.testing.expect(@hasDecl(evmz.protocol, "BlockSystemCall"));
    try std.testing.expect(@hasDecl(evmz.protocol, "ChildGasInput"));
    try std.testing.expect(@hasDecl(evmz.transaction, "FloorGasInput"));
    try std.testing.expect(!@hasDecl(evmz.protocol, "validate"));
    try std.testing.expect(!@hasDecl(evmz.protocol, "interface"));
}

test "typed Evm support options resolve the protocol window" {
    const SinceCancun = evmz.EvmWith(.{ .support = evmz.Evm.Support.since(.cancun) });
    const ThroughCancun = evmz.EvmWith(.{ .support = evmz.Evm.Support.through(.cancun) });
    const LondonToCancun = evmz.EvmWith(.{ .support = .{
        .min = .london,
        .max = .cancun,
    } });

    try std.testing.expectEqual(evmz.Evm, evmz.Vm(
        evmz.eth.Revision,
        evmz.eth.execution_definition,
        evmz.eth.transaction_definition,
        evmz.eth.block_definition,
        .{},
    ));
    try std.testing.expectEqual(evmz.eth.Revision.cancun, SinceCancun.ExecutionProtocol.support.min);
    try std.testing.expectEqual(evmz.Evm.Support.all.max, SinceCancun.ExecutionProtocol.support.max);
    try std.testing.expectEqual(evmz.Evm.Support.all.min, ThroughCancun.ExecutionProtocol.support.min);
    try std.testing.expectEqual(evmz.eth.Revision.cancun, ThroughCancun.ExecutionProtocol.support.max);
    try std.testing.expectEqual(evmz.eth.Revision.london, LondonToCancun.ExecutionProtocol.support.min);
    try std.testing.expectEqual(evmz.eth.Revision.cancun, LondonToCancun.ExecutionProtocol.support.max);
}
