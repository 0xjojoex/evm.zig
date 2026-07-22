const std = @import("std");
const evmz = @import("../evm.zig");

const Address = evmz.Address;
const DefaultVm = evmz.Evm;
const MemoryStore = evmz.state.MemoryStore;
const Transaction = evmz.Transaction;
const TxResult = evmz.transaction.TransactOutcome(evmz.TxExecutionResult, DefaultVm.Rejection);
const TxStatus = evmz.TxStatus;
const transaction = evmz.transaction;

const block_gas_limit: u64 = 300_000;
const sender = evmz.addr(0xaaaa);
const default_contract = evmz.addr(0xbbbb);

const ExactEvm = evmz.Evm;
const block_bound: ExactEvm.BlockBound = .{ .max_block_gas = block_gas_limit };

const TxCase = struct {
    name: []const u8,
    revision: evmz.eth.Revision,
    kind: transaction.TxKind = .legacy,
    to: ?Address = default_contract,
    code: []const u8 = &.{},
    input: []const u8 = &.{},
    access_list: []const transaction.AccessListEntry = &.{},
    expected_status: TxStatus,
};

const BlockRun = struct {
    accepted: usize,
    rejected: bool,
    block_gas_used: u64,
};

fn transact(
    comptime Engine: type,
    executor: *Engine.Executor,
    input: Engine.TransactInput,
) Engine.Error!Engine.Outcome {
    var runtime = Engine.init(executor);
    return runtime.transact(input);
}

test "gas bound checkpoint mapped tx resources fail by semantic gas not capacity" {
    const log_loop = evmz.t.bytecode(.{
        .JUMPDEST, .PUSH0, .PUSH0, .LOG0,
        .PUSH1,    0x00,   .JUMP,
    });
    try expectTxCase(.{
        .name = "log0 loop",
        .revision = .osaka,
        .code = &log_loop,
        .expected_status = .out_of_gas,
    });

    const tstore_loop = evmz.t.bytecode(.{
        .JUMPDEST, .PUSH1, 0x01,  .PUSH0, .TSTORE,
        .PUSH1,    0x00,   .JUMP,
    });
    try expectTxCase(.{
        .name = "tstore journal loop",
        .revision = .cancun,
        .code = &tstore_loop,
        .expected_status = .out_of_gas,
    });

    const selfdestruct_code = evmz.t.bytecode(.{ .PUSH2, 0xcc, 0xcc, .SELFDESTRUCT });
    try expectTxCase(.{
        .name = "selfdestruct marker",
        .revision = .osaka,
        .code = &selfdestruct_code,
        .expected_status = .success,
    });

    const create_init_code = evmz.t.bytecode(.{
        .PUSH1, 0x00, .PUSH1, 0x00, .MSTORE,
        .PUSH1, 0x01, .PUSH1, 0x00, .RETURN,
    });
    try expectTxCase(.{
        .name = "contract creation marker",
        .revision = .osaka,
        .to = null,
        .input = &create_init_code,
        .expected_status = .success,
    });

    const storage_keys = [_]u256{ 1, 2, 3 };
    const access_list = [_]transaction.AccessListEntry{
        .{ .address = evmz.addr(0x1001), .storage_keys = &storage_keys },
        .{ .address = evmz.addr(0x1002), .storage_keys = &storage_keys },
        .{ .address = evmz.addr(0x1003), .storage_keys = &storage_keys },
        .{ .address = evmz.addr(0x1004), .storage_keys = &storage_keys },
        .{ .address = evmz.addr(0x1005), .storage_keys = &storage_keys },
        .{ .address = evmz.addr(0x1006), .storage_keys = &storage_keys },
    };
    try expectTxCase(.{
        .name = "access list warm set",
        .revision = .osaka,
        .kind = .access_list,
        .access_list = &access_list,
        .expected_status = .success,
    });
}

test "gas bound checkpoint block overlay fails by block gas not capacity" {
    const growable = runGrowableStorageOverlayBlock() catch |err| return failCapacity("growable storage overlay block", err);
    const bounded = runExactStorageOverlayBlock() catch |err| return failCapacity("exact storage overlay block", err);

    try std.testing.expect(growable.accepted > 0);
    try std.testing.expect(growable.rejected);
    try std.testing.expectEqual(growable.accepted, bounded.accepted);
    try std.testing.expectEqual(growable.rejected, bounded.rejected);
    try std.testing.expectEqual(growable.block_gas_used, bounded.block_gas_used);
}

test "gas bound checkpoint documents byte caps still unmodeled" {
    const resources = try ExactEvm.boundedRuntimeResources(.osaka, block_bound);

    try std.testing.expect(resources.logs != null);
    try std.testing.expect(resources.journal_entries != null);
    try std.testing.expect(resources.access != null);
    try std.testing.expect(resources.state != null);
    try std.testing.expect(resources.transient_storage_entries != null);

    try std.testing.expectEqual(@as(?usize, null), resources.memory_bytes_per_frame);
    try std.testing.expectEqual(@as(?usize, null), resources.io_bytes_per_frame);
    try std.testing.expectEqual(@as(?usize, null), resources.scratch_bytes_per_frame);
    try std.testing.expectEqual(@as(?usize, null), resources.result_bytes);
}

test "runtime block bound rejects a zero gas envelope" {
    try std.testing.expectError(
        error.InvalidBlockGasBound,
        ExactEvm.boundedRuntimeResources(.osaka, .{ .max_block_gas = 0 }),
    );
}

test "gas-derived executor capacity locks resources to the initialized revision" {
    var executor = try ExactEvm.initBoundExecutor(std.testing.allocator, .{
        .revision = .cancun,
    }, block_bound);
    defer executor.deinit();

    try std.testing.expectError(
        error.RuntimeResourcesLocked,
        executor.reset(.{
            .revision = .osaka,
        }),
    );
}

test "gas-derived executor capacity validates bound block transactions" {
    var executor = try ExactEvm.initBoundExecutor(std.testing.allocator, .{
        .revision = .osaka,
    }, block_bound);
    defer executor.deinit();

    const tx: Transaction = .{
        .sender = sender,
        .to = default_contract,
        .gas_limit = 21_000,
    };
    var zero_limit = try ExactEvm.BlockExecution.init(&executor, .{});
    try std.testing.expectError(error.InvalidBlockGasLimit, zero_limit.transact(tx));
    zero_limit.discardIfUnfinished();

    var excessive_limit = try ExactEvm.BlockExecution.init(&executor, .{
        .gas_limit = block_gas_limit + 1,
    });
    try std.testing.expectError(
        error.BlockGasLimitExceedsBound,
        excessive_limit.transact(tx),
    );
    excessive_limit.discardIfUnfinished();

    var block = try ExactEvm.BlockExecution.init(&executor, .{
        .gas_limit = block_gas_limit,
    });
    block.discardIfUnfinished();
}

test "gas-derived executor capacity validates one-shot transaction environment" {
    var memory = MemoryStore.init(std.testing.allocator);
    defer memory.deinit();
    var sender_account = try memory.getOrCreateAccount(sender);
    sender_account.balance = 1_000_000;

    var executor = try ExactEvm.initBoundExecutor(std.testing.allocator, .{
        .revision = .osaka,
        .state_reader = memory.reader(),
    }, block_bound);
    defer executor.deinit();

    const tx: Transaction = .{
        .sender = sender,
        .to = default_contract,
        .gas_limit = 21_000,
    };
    try std.testing.expectError(
        error.InvalidBlockGasLimit,
        transact(ExactEvm, &executor, .{ .env = .{}, .tx = tx }),
    );
    try std.testing.expectError(
        error.BlockGasLimitExceedsBound,
        transact(ExactEvm, &executor, .{
            .env = .{ .gas_limit = block_gas_limit + 1 },
            .tx = tx,
        }),
    );
    const outcome = try transact(ExactEvm, &executor, .{
        .env = .{ .gas_limit = block_gas_limit },
        .tx = tx,
    });
    switch (outcome) {
        .executed => |executed| try executed.discard(),
        .rejected => return error.UnexpectedRejection,
    }
}

fn expectTxCase(case: TxCase) !void {
    const growable = runGrowableTx(case) catch |err| return failCapacity(case.name, err);
    const bounded = runExactTx(case) catch |err| return failCapacity(case.name, err);
    const growable_executed = try expectExecuted(growable);
    const bounded_executed = try expectExecuted(bounded);

    try std.testing.expectEqual(case.expected_status, growable_executed.status);
    try std.testing.expectEqual(growable_executed.status, bounded_executed.status);
}

fn runGrowableTx(case: TxCase) !TxResult {
    var memory = MemoryStore.init(std.testing.allocator);
    defer memory.deinit();
    try seedSenderAndCode(&memory, case.to, case.code);

    var executor = DefaultVm.Executor.init(std.testing.allocator, .{
        .revision = case.revision,
        .state_reader = memory.reader(),
    });
    defer executor.deinit();

    var block = try DefaultVm.BlockExecution.init(&executor, .{
        .gas_limit = block_gas_limit,
    });
    defer block.discardIfUnfinished();
    const outcome = try block.transact(txFromCase(case));
    return switch (outcome) {
        .included => |included| blk: {
            _ = try block.finish();
            break :blk .{ .executed = included.result };
        },
        .rejected => |err| .{ .rejected = err },
    };
}

fn runExactTx(case: TxCase) !TxResult {
    var memory = MemoryStore.init(std.testing.allocator);
    defer memory.deinit();
    try seedSenderAndCode(&memory, case.to, case.code);

    var executor = try ExactEvm.initBoundExecutor(std.testing.allocator, .{
        .revision = case.revision,
        .state_reader = memory.reader(),
    }, block_bound);
    defer executor.deinit();

    var block = try ExactEvm.BlockExecution.init(&executor, .{
        .gas_limit = block_gas_limit,
    });
    defer block.discardIfUnfinished();
    const outcome = try block.transact(txFromCase(case));
    return switch (outcome) {
        .included => |included| blk: {
            _ = try block.finish();
            break :blk .{ .executed = included.result };
        },
        .rejected => |err| .{ .rejected = err },
    };
}

fn txFromCase(case: TxCase) Transaction {
    return .{
        .kind = case.kind,
        .sender = sender,
        .to = case.to,
        .gas_limit = block_gas_limit,
        .input = case.input,
        .access_list = case.access_list,
    };
}

fn seedSenderAndCode(memory: *MemoryStore, maybe_contract: ?Address, code: []const u8) !void {
    var sender_account = try memory.getOrCreateAccount(sender);
    sender_account.balance = 1_000_000_000;
    if (maybe_contract) |contract| {
        if (code.len != 0) {
            var contract_account = try memory.getOrCreateAccount(contract);
            try contract_account.setCode(code);
        }
    }
}

fn runGrowableStorageOverlayBlock() !BlockRun {
    var memory = MemoryStore.init(std.testing.allocator);
    defer memory.deinit();
    try seedStorageOverlayBlock(&memory);

    var executor = DefaultVm.Executor.init(std.testing.allocator, .{
        .revision = .osaka,
        .state_reader = memory.reader(),
    });
    defer executor.deinit();

    var block = try DefaultVm.BlockExecution.init(&executor, .{
        .gas_limit = block_gas_limit,
    });
    defer block.discardIfUnfinished();
    return runStorageOverlayBlock(&block);
}

fn runExactStorageOverlayBlock() !BlockRun {
    var memory = MemoryStore.init(std.testing.allocator);
    defer memory.deinit();
    try seedStorageOverlayBlock(&memory);

    var executor = try ExactEvm.initBoundExecutor(std.testing.allocator, .{
        .revision = .osaka,
        .state_reader = memory.reader(),
    }, block_bound);
    defer executor.deinit();

    var block = try ExactEvm.BlockExecution.init(&executor, .{
        .gas_limit = block_gas_limit,
    });
    defer block.discardIfUnfinished();
    return runStorageOverlayBlock(&block);
}

fn seedStorageOverlayBlock(memory: *MemoryStore) !void {
    var sender_account = try memory.getOrCreateAccount(sender);
    sender_account.balance = 1_000_000_000;
    const write_code = evmz.t.bytecode(.{ .PUSH1, 0x01, .PUSH0, .SSTORE, .STOP });
    for (0..16) |index| {
        var account = try memory.getOrCreateAccount(contractAddress(index));
        try account.setCode(&write_code);
    }
}

fn runStorageOverlayBlock(block: anytype) !BlockRun {
    var accepted: usize = 0;
    var rejected = false;
    for (0..16) |index| {
        const result = block.transact(.{
            .sender = sender,
            .to = contractAddress(index),
            .gas_limit = 80_000,
        }) catch |err| switch (err) {
            error.BlockGasExceeded => {
                rejected = true;
                break;
            },
            else => return err,
        };
        switch (result) {
            .included => |included| {
                switch (included.result.status) {
                    .success => accepted += 1,
                    else => try std.testing.expect(false),
                }
            },
            .rejected => |err| {
                try std.testing.expectEqual(DefaultVm.Rejection.gas_allowance_exceeded, err);
                rejected = true;
                break;
            },
        }
    }
    const summary = try block.finish();
    return .{
        .accepted = accepted,
        .rejected = rejected,
        .block_gas_used = summary.block_gas.total,
    };
}

fn expectExecuted(result: TxResult) !evmz.TxExecutionResult {
    return switch (result) {
        .executed => |executed| executed,
        .rejected => error.UnexpectedRejection,
    };
}

fn contractAddress(index: usize) Address {
    const narrowed: u160 = @intCast(index);
    return evmz.addr(@as(u160, 0x1000) + narrowed);
}

fn failCapacity(name: []const u8, err: anyerror) anyerror {
    if (isCapacityError(err)) {
        std.debug.print("gas bound checkpoint capacity escaped before semantic gas result: {s}: {s}\n", .{ name, @errorName(err) });
        return error.GasBoundCheckpointCapacityError;
    }
    return err;
}

fn isCapacityError(err: anyerror) bool {
    return switch (err) {
        error.AccountCapacityExceeded,
        error.OriginalStorageCapacityExceeded,
        error.StorageOverlayCapacityExceeded,
        error.WarmAccountCapacityExceeded,
        error.WarmStorageCapacityExceeded,
        error.TransientStorageCapacityExceeded,
        error.LogCapacityExceeded,
        error.LogDataCapacityExceeded,
        error.LogTopicCapacityExceeded,
        error.JournalCapacityExceeded,
        error.CreatedContractCapacityExceeded,
        error.SelfdestructCapacityExceeded,
        error.DeletedAccountCapacityExceeded,
        error.DirtyAccountCapacityExceeded,
        error.FrameCapacityExceeded,
        error.FrameIoCapacityExceeded,
        error.ResultOutputCapacityExceeded,
        error.OutOfMemory,
        => true,
        else => false,
    };
}
