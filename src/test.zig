test {
    _ = @import("./test/vm_family.zig");
    _ = @import("./test/vm_runtime.zig");
    _ = @import("./test/execution_boundary.zig");
    _ = @import("./test/call_capture.zig");
    _ = @import("./test/call_capture_oracle.zig");
    _ = @import("./test/executor_custom_handler_reentry.zig");
    _ = @import("./test/execution_precompile_runtime.zig");
    _ = @import("./test/block_lifecycle.zig");
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

test "exact spec plugs into existing runtime code" {
    const CancunVM = evmz.Vm(evmz.eth.cancun);
    const instructions = CancunVM.specification.instruction;
    const blob_base_fee = comptime instructions.entry(@intFromEnum(Opcode.BLOBBASEFEE));
    const slot_num = comptime instructions.entry(@intFromEnum(Opcode.SLOTNUM));

    try std.testing.expect(blob_base_fee.active);
    try std.testing.expect(!slot_num.active);
    try std.testing.expectEqual(evmz.eth.cancun.transaction.blob_schedule, CancunVM.specification.transaction.blob_schedule);
    try std.testing.expect(@hasDecl(CancunVM, "transact"));
    try std.testing.expect(@hasDecl(CancunVM, "BlockExecution"));
    try std.testing.expectEqual(@as(usize, 1), @typeInfo(CancunVM).@"struct".fields.len);
    try std.testing.expect(@hasField(CancunVM, "transaction_runtime"));
    try std.testing.expect(@hasDecl(CancunVM, "init"));
    try std.testing.expect(@hasDecl(CancunVM.Executor, "runStandalone"));
    try std.testing.expect(@hasDecl(CancunVM.Executor, "runStandaloneRequest"));
    try std.testing.expect(@hasDecl(CancunVM.Interpreter, "execute"));
    try std.testing.expectEqual(
        instructions.entry(@intFromEnum(Opcode.ADD)),
        CancunVM.Instruction.entry(@intFromEnum(Opcode.ADD)),
    );
    try std.testing.expectEqual(evmz.Transaction, CancunVM.Transaction);
    try std.testing.expectEqual(evmz.Evm.Executor, evmz.Executor);
    try std.testing.expectEqual(evmz.Evm.Interpreter, evmz.Interpreter);
    try std.testing.expectEqual(evmz.execution.Message, evmz.Message);
    try std.testing.expect(@hasDecl(CancunVM.Settlement, "defaultPlanFromGasPlan"));
    try std.testing.expect(@hasField(evmz.eth.Spec, "authorization"));
    try std.testing.expect(@hasField(evmz.eth.Spec, "call"));
    try std.testing.expect(@hasField(evmz.eth.Spec, "create"));
    try std.testing.expect(@hasField(evmz.eth.Spec, "storage"));
    try std.testing.expect(@hasField(evmz.eth.Spec, "self_destruct"));
    try std.testing.expect(!@hasDecl(evmz.transaction, "Settlement"));
    try std.testing.expect(!@hasDecl(evmz.transaction, "SettlementCosts"));

    var executor = CancunVM.Executor.init(std.testing.allocator, .{});
    defer executor.deinit();
    const env: evmz.Env = .{};
    const result = try executor.runStandalone(env.txContext(evmz.addr(0xaaaa), 0, 100_000, &.{}), .{
        .call = .{
            .sender = evmz.addr(0xaaaa),
            .recipient = evmz.addr(0xbbbb),
        },
    }, .legacy(100_000));
    try std.testing.expectEqual(CancunVM.Interpreter.Status.success, result.expectCall().status);
}

test "extended exact spec keeps the concrete transaction value" {
    const custom_spec = evmz.eth.cancun.extend(.{
        .transaction = .{ .total_gas_limit = .{ .replace = 42_000 } },
    });
    const CustomVm = evmz.Vm(custom_spec);

    try std.testing.expect(CustomVm.Transaction == evmz.Transaction);
    try std.testing.expectEqual(@as(?u64, 42_000), CustomVm.specification.transaction.total_gas_limit);
}

test "table tier replaces complete instruction and precompile bindings" {
    const OsakaPrecompiles = evmz.precompile.Exact(evmz.eth.precompile.osaka_config);
    const table_spec = evmz.eth.cancun.extend(.{
        .instruction = evmz.eth.osaka.instruction,
        .precompile = OsakaPrecompiles,
    });
    const TableVm = evmz.Vm(table_spec);

    comptime {
        std.debug.assert(TableVm.specification.precompile == OsakaPrecompiles);
        std.debug.assert(TableVm.specification.instruction.entry(@intFromEnum(Opcode.CLZ)).active);
        std.debug.assert(OsakaPrecompiles.active(evmz.precompile.Contract.p256verify.toAddress()));
    }
}

test "semantic types live with their engine domains" {
    try std.testing.expect(!@hasDecl(evmz, "protocol"));
    try std.testing.expect(evmz.spec.Spec == evmz.eth.Spec);
    try std.testing.expect(@hasDecl(evmz.eth.system, "BlockSystemCall"));
    try std.testing.expect(@hasDecl(evmz.execution, "ChildGasInput"));
    try std.testing.expect(@hasDecl(evmz.instruction, "Target"));
    try std.testing.expect(@hasDecl(evmz.transaction, "FloorGasInput"));
}

test "fork selection resolves one complete exact spec" {
    try std.testing.expectEqual(evmz.eth.cancun.transaction.blob_schedule, evmz.eth.specAt(.cancun).transaction.blob_schedule);
    try std.testing.expectEqual(evmz.eth.amsterdam.transaction.max_initcode_size, evmz.eth.specAt(.amsterdam).transaction.max_initcode_size);
    try std.testing.expect(evmz.Vm(evmz.eth.cancun) != evmz.Vm(evmz.eth.amsterdam));
}

test "Vm binds executor and transaction program to one exact spec" {
    const Osaka = evmz.Vm(evmz.eth.osaka);
    comptime {
        std.debug.assert(!@hasField(Osaka.Executor, "revision_id"));
        std.debug.assert(!@hasField(Osaka.Executor.Init, "revision"));
        std.debug.assert(Osaka.Executor.specification.call.base_gas == evmz.eth.osaka.call.base_gas);
    }

    var executor = Osaka.Executor.init(std.testing.allocator, .{});
    defer executor.deinit();
    try std.testing.expectEqual(
        @as(i64, 100),
        Osaka.Instruction.entry(@intFromEnum(Opcode.BALANCE)).static_gas,
    );
}

test "exact spec drives create deposit through the real executor" {
    const Expensive = struct {
        fn depositRegularGas(_: i64) ?i64 {
            return 1_000_000;
        }
    };
    const Shanghai = evmz.Vm(evmz.eth.shanghai);
    const ExpensiveShanghai = evmz.Vm(evmz.eth.shanghai.extend(.{
        .create = .{ .depositRegularGas = Expensive.depositRegularGas },
    }));
    const sender = evmz.addr(0xaaaa);
    const init_code = [_]u8{
        Opcode.PUSH3.toByte(), 0,                      0, 1,
        Opcode.PUSH0.toByte(), Opcode.RETURN.toByte(),
    };
    const tx_context = (evmz.Env{ .gas_limit = 100_000 }).txContext(sender, 0, 100_000, &.{});

    var standard = Shanghai.Executor.init(std.testing.allocator, .{});
    defer standard.deinit();
    var standard_sender = evmz.state.MemoryAccount.init(std.testing.allocator);
    standard_sender.balance = 100_000_000;
    try standard.state.seedAccount(sender, standard_sender);
    const standard_result = (try standard.runStandalone(tx_context, .{ .create = .{
        .sender = sender,
        .recipient = evmz.address.create(sender, 0),
        .init_code = &init_code,
    } }, .legacy(100_000))).expectCreate();
    try std.testing.expectEqual(Shanghai.Interpreter.Status.success, standard_result.status);

    var expensive = ExpensiveShanghai.Executor.init(std.testing.allocator, .{});
    defer expensive.deinit();
    var expensive_sender = evmz.state.MemoryAccount.init(std.testing.allocator);
    expensive_sender.balance = 100_000_000;
    try expensive.state.seedAccount(sender, expensive_sender);
    const expensive_result = (try expensive.runStandalone(tx_context, .{ .create = .{
        .sender = sender,
        .recipient = evmz.address.create(sender, 0),
        .init_code = &init_code,
    } }, .legacy(100_000))).expectCreate();
    try std.testing.expectEqual(ExpensiveShanghai.Interpreter.Status.out_of_gas, expensive_result.status);
    try std.testing.expectEqual(evmz.execution.TerminalCause.code_store_out_of_gas, expensive_result.cause.?);
    try std.testing.expect(expensive_result.checkpoint_reverted);
}

test "all Ethereum forks instantiate as exact VM types" {
    @setEvalBranchQuota(100_000);
    inline for (std.enums.values(evmz.eth.Revision)) |revision| {
        const Fork = evmz.Vm(evmz.eth.specAt(revision));
        comptime {
            std.debug.assert(!@hasField(Fork.Executor.Init, "revision"));
            std.debug.assert(Fork.specification.create.deposit_regular_gas_oog_commits ==
                evmz.eth.specAt(revision).create.deposit_regular_gas_oog_commits);
        }
        _ = Fork.Executor;
        _ = Fork.Transaction;
        _ = Fork.BlockExecution;
    }
}
