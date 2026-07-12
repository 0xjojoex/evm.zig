const std = @import("std");
const evmz = @import("../evm.zig");

const Address = evmz.Address;
const protocol = evmz.protocol;
const BeforeBlockContext = protocol.BeforeBlockContext;
const AfterTransactionContext = evmz.vm.AfterTransactionContext;
const FinalizeBlockContext = evmz.vm.FinalizeBlockContext;
const MemoryStore = evmz.state.MemoryStore;

const lifecycle_code = [_]u8{
    0x5f, 0x35, 0x80, 0x5f, 0x55,
    0x5f, 0x52, 0x60, 0x20, 0x5f,
    0xf3,
};

const LifecycleBlock = struct {
    const before_block_address = evmz.addr(0x1001);
    const before_transaction_address = evmz.addr(0x1002);
    const after_transaction_address = evmz.addr(0x1003);
    const finalize_block_address = evmz.addr(0x1004);

    fn beforeBlock(_: evmz.eth.Revision, context: BeforeBlockContext) protocol.BlockSystemCalls {
        if (context.number != 7 or context.timestamp != 9) return failingCalls();
        return calls(before_block_address, 1);
    }

    fn beforeTransaction(_: evmz.eth.Revision, context: protocol.BeforeTransactionContext) protocol.BlockSystemCalls {
        if (context.number != 7 or context.timestamp != 9) return failingCalls();
        return calls(before_transaction_address, std.math.cast(u8, context.transaction_index + 2) orelse 0xff);
    }

    fn afterTransaction(_: evmz.eth.Revision, context: AfterTransactionContext) protocol.BlockSystemCalls {
        if (context.number != 7 or
            context.timestamp != 9 or
            context.status != .success or
            context.gas_used == 0 or
            context.cumulative_gas_used != context.gas_used or
            context.cumulative_block_gas == 0)
        {
            return failingCalls();
        }
        return calls(after_transaction_address, std.math.cast(u8, context.transaction_index + 3) orelse 0xff);
    }

    fn finalizeBlock(_: evmz.eth.Revision, context: FinalizeBlockContext) protocol.FinalizeSystemCalls {
        var result = protocol.FinalizeSystemCalls{};
        if (context.number != 7 or
            context.timestamp != 9 or
            context.transaction_count != 1 or
            context.gas_used == 0 or
            context.block_gas == 0)
        {
            result.append(.{ .call = failingCall(), .output_prefix = 0xff });
            return result;
        }
        result.append(.{
            .call = systemCall(finalize_block_address, 4),
            .output_prefix = 0x99,
        });
        return result;
    }

    fn calls(recipient: Address, marker: u8) protocol.BlockSystemCalls {
        var result = protocol.BlockSystemCalls{};
        result.append(systemCall(recipient, marker));
        return result;
    }

    fn failingCalls() protocol.BlockSystemCalls {
        var result = protocol.BlockSystemCalls{};
        result.append(failingCall());
        return result;
    }

    fn systemCall(recipient: Address, marker: u8) protocol.BlockSystemCall {
        var input = [_]u8{0} ** 32;
        input[31] = marker;
        return .{
            .sender = evmz.eth.system_address,
            .recipient = recipient,
            .input = .{ .word = input },
            .gas = 100_000,
            .require_code = true,
        };
    }

    fn failingCall() protocol.BlockSystemCall {
        return .{
            .sender = evmz.eth.system_address,
            .recipient = evmz.addr(0xffff),
            .gas = 100_000,
            .require_code = true,
        };
    }
};

const LifecycleDefinition = evmz.eth.define(.{
    .block = .{
        .beforeBlock = LifecycleBlock.beforeBlock,
        .beforeTransaction = LifecycleBlock.beforeTransaction,
        .afterTransaction = LifecycleBlock.afterTransaction,
        .finalizeBlock = LifecycleBlock.finalizeBlock,
    },
});
const LifecycleVm = evmz.Vm(evmz.eth.Revision, LifecycleDefinition, .{});

const RejectingBeforeTransactionBlock = struct {
    fn beforeTransaction(_: evmz.eth.Revision, _: protocol.BeforeTransactionContext) protocol.BlockSystemCalls {
        return LifecycleBlock.failingCalls();
    }
};

const RejectingBeforeTransactionDefinition = evmz.eth.define(.{
    .block = .{ .beforeTransaction = RejectingBeforeTransactionBlock.beforeTransaction },
});
const RejectingBeforeTransactionVm = evmz.Vm(evmz.eth.Revision, RejectingBeforeTransactionDefinition, .{});

const AtomicLifecycleBlock = struct {
    const recipient = evmz.addr(0x2001);

    fn beforeBlock(_: evmz.eth.Revision, _: BeforeBlockContext) protocol.BlockSystemCalls {
        var result = protocol.BlockSystemCalls{};
        result.append(LifecycleBlock.systemCall(recipient, 7));
        result.append(LifecycleBlock.failingCall());
        return result;
    }

    fn finalizeBlock(_: evmz.eth.Revision, _: FinalizeBlockContext) protocol.FinalizeSystemCalls {
        var result = protocol.FinalizeSystemCalls{};
        result.append(.{
            .call = LifecycleBlock.systemCall(recipient, 8),
            .output_prefix = 0x99,
        });
        result.append(.{
            .call = LifecycleBlock.failingCall(),
            .output_prefix = 0xff,
        });
        return result;
    }
};

const AtomicLifecycleDefinition = evmz.eth.define(.{ .block = .{
    .beforeBlock = AtomicLifecycleBlock.beforeBlock,
    .finalizeBlock = AtomicLifecycleBlock.finalizeBlock,
} });
const AtomicLifecycleVm = evmz.Vm(evmz.eth.Revision, AtomicLifecycleDefinition, .{});

const FinishLifecycleBlock = struct {
    const recipient = evmz.addr(0x3001);

    fn afterTransaction(_: evmz.eth.Revision, _: AfterTransactionContext) protocol.BlockSystemCalls {
        return LifecycleBlock.calls(recipient, 9);
    }
};

const FinishLifecycleDefinition = evmz.eth.define(.{
    .block = .{ .afterTransaction = FinishLifecycleBlock.afterTransaction },
});
const FinishLifecycleVm = evmz.Vm(evmz.eth.Revision, FinishLifecycleDefinition, .{});

test "BlockSession exposes definition-owned lifecycle phases with derived facts" {
    const sender = evmz.addr(0xaaaa);
    const recipient = evmz.addr(0xbbbb);
    var memory = MemoryStore.init(std.testing.allocator);
    defer memory.deinit();

    var sender_account = try memory.getOrCreateAccount(sender);
    sender_account.balance = 10_000_000;

    var vm = LifecycleVm.init(std.testing.allocator, .{
        .revision = .prague,
        .state_reader = memory.reader(),
    });
    defer vm.deinit();

    // CALLDATALOAD(0), store it at slot 0, then return the same word.
    try vm.executor.state.setCode(LifecycleBlock.before_block_address, &lifecycle_code);
    try vm.executor.state.setCode(LifecycleBlock.before_transaction_address, &lifecycle_code);
    try vm.executor.state.setCode(LifecycleBlock.after_transaction_address, &lifecycle_code);
    try vm.executor.state.setCode(LifecycleBlock.finalize_block_address, &lifecycle_code);

    var block = try vm.beginBlock(.{
        .number = 7,
        .timestamp = 9,
        .gas_limit = 1_000_000,
    });
    try block.beforeBlock(.{});
    try std.testing.expectEqual(@as(u256, 1), try vm.getStorage(LifecycleBlock.before_block_address, 0));

    const executed = switch (try block.transact(.{
        .sender = sender,
        .to = recipient,
        .gas_limit = 300_000,
    })) {
        .executed => |result| result,
        .rejected => return error.UnexpectedRejection,
    };
    try std.testing.expectEqual(@as(u256, 2), try vm.getStorage(LifecycleBlock.before_transaction_address, 0));

    _ = block.receipt(executed);
    try block.afterTransaction();
    try std.testing.expectEqual(@as(u256, 3), try vm.getStorage(LifecycleBlock.after_transaction_address, 0));

    const outputs = try block.finalizeBlock(std.testing.allocator);
    defer {
        for (outputs) |output| std.testing.allocator.free(output);
        std.testing.allocator.free(outputs);
    }
    try std.testing.expectEqual(@as(u256, 4), try vm.getStorage(LifecycleBlock.finalize_block_address, 0));
    try std.testing.expectEqual(@as(usize, 1), outputs.len);
    try std.testing.expectEqual(@as(u8, 0x99), outputs[0][0]);
    try std.testing.expectEqual(@as(u8, 4), outputs[0][32]);
}

test "BlockSession does not run before-transaction hooks for rejected transactions" {
    const sender = evmz.addr(0xaaaa);
    var memory = MemoryStore.init(std.testing.allocator);
    defer memory.deinit();

    var sender_account = try memory.getOrCreateAccount(sender);
    sender_account.balance = 10_000_000;

    var vm = RejectingBeforeTransactionVm.init(std.testing.allocator, .{
        .revision = .prague,
        .state_reader = memory.reader(),
    });
    defer vm.deinit();

    var block = try vm.beginBlock(.{ .gas_limit = 1_000_000 });
    const rejected = try block.transact(.{
        .sender = sender,
        .nonce = 1,
        .to = evmz.addr(0xbbbb),
        .gas_limit = 300_000,
    });
    switch (rejected) {
        .executed => return error.UnexpectedExecution,
        .rejected => |err| try std.testing.expectEqual(
            evmz.Evm.Protocol.Transaction.ValidationError.nonce_mismatch,
            err,
        ),
    }
}

test "block lifecycle hook batches restore earlier calls when a later call fails" {
    var vm = AtomicLifecycleVm.init(std.testing.allocator, .{ .revision = .prague });
    defer vm.deinit();
    try vm.executor.state.setCode(AtomicLifecycleBlock.recipient, &lifecycle_code);

    var block = try vm.beginBlock(.{ .gas_limit = 1_000_000 });
    try std.testing.expectError(error.SystemCallFailed, block.beforeBlock(.{}));
    try std.testing.expectEqual(@as(u256, 0), try vm.getStorage(AtomicLifecycleBlock.recipient, 0));

    try std.testing.expectError(error.SystemCallFailed, block.finalizeBlock(std.testing.allocator));
    try std.testing.expectEqual(@as(u256, 0), try vm.getStorage(AtomicLifecycleBlock.recipient, 0));
}

test "BlockSession finish flushes the pending after-transaction phase" {
    const sender = evmz.addr(0xaaaa);
    var memory = MemoryStore.init(std.testing.allocator);
    defer memory.deinit();
    var sender_account = try memory.getOrCreateAccount(sender);
    sender_account.balance = 10_000_000;

    var vm = FinishLifecycleVm.init(std.testing.allocator, .{
        .revision = .prague,
        .state_reader = memory.reader(),
    });
    defer vm.deinit();
    try vm.executor.state.setCode(FinishLifecycleBlock.recipient, &lifecycle_code);

    var block = try vm.beginBlock(.{ .gas_limit = 1_000_000 });
    _ = switch (try block.transact(.{
        .sender = sender,
        .to = evmz.addr(0xbbbb),
        .gas_limit = 300_000,
    })) {
        .executed => |result| result,
        .rejected => return error.UnexpectedRejection,
    };

    const summary = try block.finish();
    try std.testing.expectEqual(@as(u64, 1), summary.tx_count);
    try std.testing.expectEqual(@as(u256, 9), try vm.getStorage(FinishLifecycleBlock.recipient, 0));
}
