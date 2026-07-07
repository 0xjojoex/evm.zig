const std = @import("std");
const evmz = @import("../evm.zig");

const Address = evmz.Address;
const EthProtocol = evmz.EthProtocol;
const DefaultVm = evmz.Evm;
const MemoryStore = evmz.state.MemoryStore;
const Transaction = evmz.Transaction;
const TxResult = evmz.TxResult;
const TxStatus = evmz.TxStatus;
const transaction = evmz.transaction;

const block_gas_limit: u64 = 300_000;
const sender = evmz.addr(0xaaaa);
const default_contract = evmz.addr(0xbbbb);

const ExactVm = evmz.vm.VmWithOptions(EthProtocol, .{
    .block_policy = .{
        .resource_bound = .{
            .gas_derived = .{ .block_gas_limit = block_gas_limit },
        },
    },
});

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
    const resources = try ExactVm.boundedRuntimeResourcesForBlockPolicy(.osaka);

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

fn expectTxCase(case: TxCase) !void {
    const growable = runGrowableTx(case) catch |err| return failCapacity(case.name, err);
    const bounded = runExactTx(case) catch |err| return failCapacity(case.name, err);

    try std.testing.expectEqual(case.expected_status, growable.status);
    try std.testing.expectEqual(growable.status, bounded.status);
    try std.testing.expectEqual(growable.validation_error, bounded.validation_error);
}

fn runGrowableTx(case: TxCase) !TxResult {
    var memory = MemoryStore.init(std.testing.allocator);
    defer memory.deinit();
    try seedSenderAndCode(&memory, case.to, case.code);

    var vm = DefaultVm.init(std.testing.allocator, .{
        .revision = case.revision,
        .state_reader = memory.reader(),
    });
    defer vm.deinit();

    var block = vm.beginBlock(.{ .gas_limit = block_gas_limit });
    return block.transact(txFromCase(case));
}

fn runExactTx(case: TxCase) !TxResult {
    var memory = MemoryStore.init(std.testing.allocator);
    defer memory.deinit();
    try seedSenderAndCode(&memory, case.to, case.code);

    var vm = try ExactVm.init(std.testing.allocator, .{
        .revision = case.revision,
        .state_reader = memory.reader(),
    });
    defer vm.deinit();

    var block = vm.beginBlock(.{});
    return block.transact(txFromCase(case));
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
            try contract_account.setCode(std.testing.allocator, code);
        }
    }
}

fn runGrowableStorageOverlayBlock() !BlockRun {
    var memory = MemoryStore.init(std.testing.allocator);
    defer memory.deinit();
    try seedStorageOverlayBlock(&memory);

    var vm = DefaultVm.init(std.testing.allocator, .{
        .revision = .osaka,
        .state_reader = memory.reader(),
    });
    defer vm.deinit();

    var block = vm.beginBlock(.{ .gas_limit = block_gas_limit });
    return runStorageOverlayBlock(&block);
}

fn runExactStorageOverlayBlock() !BlockRun {
    var memory = MemoryStore.init(std.testing.allocator);
    defer memory.deinit();
    try seedStorageOverlayBlock(&memory);

    var vm = try ExactVm.init(std.testing.allocator, .{
        .revision = .osaka,
        .state_reader = memory.reader(),
    });
    defer vm.deinit();

    var block = vm.beginBlock(.{});
    return runStorageOverlayBlock(&block);
}

fn seedStorageOverlayBlock(memory: *MemoryStore) !void {
    var sender_account = try memory.getOrCreateAccount(sender);
    sender_account.balance = 1_000_000_000;
    const write_code = evmz.t.bytecode(.{ .PUSH1, 0x01, .PUSH0, .SSTORE, .STOP });
    for (0..16) |index| {
        var account = try memory.getOrCreateAccount(contractAddress(index));
        try account.setCode(std.testing.allocator, &write_code);
    }
}

fn runStorageOverlayBlock(block: anytype) !BlockRun {
    var accepted: usize = 0;
    var rejected = false;
    for (0..16) |index| {
        const result = try block.transact(.{
            .sender = sender,
            .to = contractAddress(index),
            .gas_limit = 80_000,
        });
        switch (result.status) {
            .success => accepted += 1,
            .rejected => {
                if (result.validation_error) |err| {
                    try std.testing.expectEqual(transaction.ValidationError.gas_allowance_exceeded, err);
                }
                rejected = true;
                break;
            },
            else => try std.testing.expect(false),
        }
    }
    return .{
        .accepted = accepted,
        .rejected = rejected,
        .block_gas_used = block.finish().block_gas_used,
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
