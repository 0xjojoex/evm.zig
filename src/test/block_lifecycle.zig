const std = @import("std");
const evmz = @import("../evm.zig");

const Address = evmz.Address;
const protocol = evmz.protocol;
const BeforeBlockContext = protocol.BeforeBlockContext;
const AfterTransactionContext = evmz.AfterTransactionContext;
const FinalizeBlockContext = evmz.FinalizeBlockContext;
const MemoryStore = evmz.state.MemoryStore;

fn VmFor(comptime block_options: evmz.eth.BlockOptions(evmz.eth.Revision)) type {
    return evmz.eth.extend(.{ .block = block_options });
}

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

const LifecycleVm = VmFor(.{
    .beforeBlock = LifecycleBlock.beforeBlock,
    .beforeTransaction = LifecycleBlock.beforeTransaction,
    .afterTransaction = LifecycleBlock.afterTransaction,
    .finalizeBlock = LifecycleBlock.finalizeBlock,
});

const RejectingBeforeTransactionBlock = struct {
    fn beforeTransaction(_: evmz.eth.Revision, _: protocol.BeforeTransactionContext) protocol.BlockSystemCalls {
        return LifecycleBlock.failingCalls();
    }
};

const RejectingBeforeTransactionVm = VmFor(.{
    .beforeTransaction = RejectingBeforeTransactionBlock.beforeTransaction,
});

const EmptyBeforeTransactionBlock = struct {
    var invocations = std.atomic.Value(usize).init(0);

    fn beforeTransaction(_: evmz.eth.Revision, _: protocol.BeforeTransactionContext) protocol.BlockSystemCalls {
        _ = invocations.fetchAdd(1, .monotonic);
        return .{};
    }
};

const EmptyBeforeTransactionVm = VmFor(.{
    .beforeTransaction = EmptyBeforeTransactionBlock.beforeTransaction,
});

const CheckpointRecorder = struct {
    events: [8]evmz.trace.CheckpointKind = undefined,
    len: usize = 0,

    fn target(self: *CheckpointRecorder) evmz.executor.CaptureStateTarget {
        return evmz.executor.CaptureStateTarget.init(self, &.{ .checkpoint = checkpoint });
    }

    fn checkpoint(ptr: *anyopaque, event: evmz.trace.Checkpoint) !void {
        const self: *CheckpointRecorder = @ptrCast(@alignCast(ptr));
        std.debug.assert(self.len < self.events.len);
        self.events[self.len] = event.kind;
        self.len += 1;
    }
};

const FailingCheckpointTarget = struct {
    fail_commit_at: usize,
    commit_count: usize = 0,

    fn target(self: *FailingCheckpointTarget) evmz.executor.CaptureStateTarget {
        return evmz.executor.CaptureStateTarget.init(self, &.{ .checkpoint = checkpoint });
    }

    fn checkpoint(ptr: *anyopaque, event: evmz.trace.Checkpoint) !void {
        const self: *FailingCheckpointTarget = @ptrCast(@alignCast(ptr));
        if (event.kind != .commit) return;
        self.commit_count += 1;
        if (self.commit_count == self.fail_commit_at) return error.TestCaptureFailure;
    }
};

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

const AtomicLifecycleVm = VmFor(.{
    .beforeBlock = AtomicLifecycleBlock.beforeBlock,
    .finalizeBlock = AtomicLifecycleBlock.finalizeBlock,
});

const FinishLifecycleBlock = struct {
    const recipient = evmz.addr(0x3001);

    fn afterTransaction(_: evmz.eth.Revision, _: AfterTransactionContext) protocol.BlockSystemCalls {
        return LifecycleBlock.calls(recipient, 9);
    }
};

const FinishLifecycleVm = VmFor(.{
    .afterTransaction = FinishLifecycleBlock.afterTransaction,
});

const RejectingAfterTransactionBlock = struct {
    fn afterTransaction(_: evmz.eth.Revision, _: AfterTransactionContext) protocol.BlockSystemCalls {
        return LifecycleBlock.failingCalls();
    }
};

const RejectingAfterTransactionVm = VmFor(.{
    .afterTransaction = RejectingAfterTransactionBlock.afterTransaction,
});

test "Sequential exposes definition-owned lifecycle phases with derived facts" {
    const sender = evmz.addr(0xaaaa);
    const recipient = evmz.addr(0xbbbb);
    var memory = MemoryStore.init(std.testing.allocator);
    defer memory.deinit();

    var sender_account = try memory.getOrCreateAccount(sender);
    sender_account.balance = 10_000_000;

    // CALLDATALOAD(0), store it at slot 0, then return the same word.
    inline for (&.{
        LifecycleBlock.before_block_address,
        LifecycleBlock.before_transaction_address,
        LifecycleBlock.after_transaction_address,
        LifecycleBlock.finalize_block_address,
    }) |address| {
        var account = try memory.getOrCreateAccount(address);
        try account.setCode(&lifecycle_code);
    }

    var executor = LifecycleVm.Executor.init(std.testing.allocator, .{
        .revision = .prague,
        .state_reader = memory.reader(),
    });
    defer executor.deinit();

    var block = try beginBlock(LifecycleVm, &executor, .{
        .number = 7,
        .timestamp = 9,
        .gas_limit = 1_000_000,
    });
    defer block.discardIfUnfinished();
    try block.beforeBlock(.{});
    try std.testing.expectEqual(@as(u256, 1), try executor.getStorage(LifecycleBlock.before_block_address, 0));

    const included = switch (try block.transact(.{
        .sender = sender,
        .to = recipient,
        .gas_limit = 300_000,
    })) {
        .included => |value| value,
        .rejected => return error.UnexpectedRejection,
    };
    _ = included.receipt;
    try block.endTransactions();
    try std.testing.expectEqual(@as(u256, 2), try executor.getStorage(LifecycleBlock.before_transaction_address, 0));
    try std.testing.expectEqual(@as(u256, 3), try executor.getStorage(LifecycleBlock.after_transaction_address, 0));

    const outputs = try block.finalizeBlock(std.testing.allocator);
    defer {
        for (outputs) |output| std.testing.allocator.free(output);
        std.testing.allocator.free(outputs);
    }
    try std.testing.expectEqual(@as(u256, 4), try executor.getStorage(LifecycleBlock.finalize_block_address, 0));
    try std.testing.expectEqual(@as(usize, 1), outputs.len);
    try std.testing.expectEqual(@as(u8, 0x99), outputs[0][0]);
    try std.testing.expectEqual(@as(u8, 4), outputs[0][32]);
    try std.testing.expectError(error.BlockAlreadyFinalized, block.finalizeBlock(std.testing.allocator));
    try std.testing.expectError(error.BlockAlreadyFinalized, block.systemCall(.{
        .sender = sender,
        .recipient = recipient,
        .gas = 100_000,
    }));
    _ = try block.finish();
}

test "Sequential does not run before-transaction hooks for rejected transactions" {
    const sender = evmz.addr(0xaaaa);
    var memory = MemoryStore.init(std.testing.allocator);
    defer memory.deinit();

    var sender_account = try memory.getOrCreateAccount(sender);
    sender_account.balance = 10_000_000;

    var executor = RejectingBeforeTransactionVm.Executor.init(std.testing.allocator, .{
        .revision = .prague,
        .state_reader = memory.reader(),
    });
    defer executor.deinit();

    var block = try beginBlock(RejectingBeforeTransactionVm, &executor, .{ .gas_limit = 1_000_000 });
    defer block.discardIfUnfinished();
    const rejected = try block.transact(.{
        .sender = sender,
        .nonce = 1,
        .to = evmz.addr(0xbbbb),
        .gas_limit = 300_000,
    });
    switch (rejected) {
        .included => {
            return error.UnexpectedExecution;
        },
        .rejected => |err| try std.testing.expectEqual(
            evmz.Evm.Rejection.nonce_too_high,
            err,
        ),
    }
}

test "Sequential failing before-transaction prelude discards the opened attempt" {
    const sender = evmz.addr(0xaaaa);
    var memory = MemoryStore.init(std.testing.allocator);
    defer memory.deinit();

    var sender_account = try memory.getOrCreateAccount(sender);
    sender_account.balance = 10_000_000;

    var executor = RejectingBeforeTransactionVm.Executor.init(std.testing.allocator, .{
        .revision = .prague,
        .state_reader = memory.reader(),
    });
    defer executor.deinit();

    var block = try beginBlock(RejectingBeforeTransactionVm, &executor, .{ .gas_limit = 1_000_000 });
    defer block.discardIfUnfinished();
    try std.testing.expectError(error.SystemCallFailed, block.transact(.{
        .sender = sender,
        .to = evmz.addr(0xbbbb),
        .gas_limit = 300_000,
    }));
    try std.testing.expect(!executor.hasCurrentTransaction());
    try std.testing.expectEqual(@as(u64, 0), (try executor.getAccountOrLoad(sender)).?.nonce);
    try std.testing.expectEqual(@as(u64, 0), (try block.progress()).tx_count);
}

test "Sequential empty before-transaction prelude adds no execution checkpoint" {
    const sender = evmz.addr(0xaaaa);
    var memory = MemoryStore.init(std.testing.allocator);
    defer memory.deinit();

    var sender_account = try memory.getOrCreateAccount(sender);
    sender_account.balance = 10_000_000;

    EmptyBeforeTransactionBlock.invocations.store(0, .monotonic);
    var recorder = CheckpointRecorder{};
    var executor = EmptyBeforeTransactionVm.Executor.init(std.testing.allocator, .{
        .revision = .amsterdam,
        .state_reader = memory.reader(),
    });
    defer executor.deinit();
    var capture = evmz.executor.CaptureContext.init(
        std.testing.allocator,
        null,
        recorder.target(),
    );
    defer capture.deinit();
    executor.setCaptureContext(&capture);
    try capture.begin();
    defer {
        if (capture.isActive()) capture.abort() catch {};
        executor.setCaptureContext(null);
    }

    var block = try beginBlock(EmptyBeforeTransactionVm, &executor, .{ .gas_limit = 1_000_000 });
    defer block.discardIfUnfinished();
    _ = switch (try block.transact(.{
        .sender = sender,
        .to = evmz.addr(0xbbbb),
        .gas_limit = 300_000,
    })) {
        .included => |included| included,
        .rejected => return error.UnexpectedRejection,
    };
    try block.endTransactions();
    _ = try capture.finish();

    try std.testing.expectEqual(@as(usize, 1), EmptyBeforeTransactionBlock.invocations.load(.monotonic));
    try std.testing.expectEqualSlices(
        evmz.trace.CheckpointKind,
        &.{ .checkpoint, .checkpoint, .commit, .commit },
        recorder.events[0..recorder.len],
    );
    _ = try block.finish();
}

test "Sequential before-transaction prelude shares one journal lifetime with payload" {
    const sender = evmz.addr(0xaaaa);
    const recipient = evmz.addr(0xbbbb);
    var memory = MemoryStore.init(std.testing.allocator);
    defer memory.deinit();

    var sender_account = try memory.getOrCreateAccount(sender);
    sender_account.balance = 10_000_000;
    var hook_account = try memory.getOrCreateAccount(LifecycleBlock.before_transaction_address);
    try hook_account.setCode(&lifecycle_code);

    var recorder = CheckpointRecorder{};
    var executor = LifecycleVm.Executor.init(std.testing.allocator, .{
        .revision = .prague,
        .state_reader = memory.reader(),
    });
    defer executor.deinit();
    var capture = evmz.executor.CaptureContext.init(
        std.testing.allocator,
        null,
        recorder.target(),
    );
    defer capture.deinit();
    executor.setCaptureContext(&capture);
    try capture.begin();
    defer {
        if (capture.isActive()) capture.abort() catch {};
        executor.setCaptureContext(null);
    }

    var block = try beginBlock(LifecycleVm, &executor, .{
        .number = 7,
        .timestamp = 9,
        .gas_limit = 1_000_000,
    });
    defer block.discardIfUnfinished();
    _ = switch (try block.transact(.{
        .sender = sender,
        .to = recipient,
        .gas_limit = 300_000,
    })) {
        .included => |included| included,
        .rejected => return error.UnexpectedRejection,
    };
    _ = try capture.finish();

    try std.testing.expectEqualSlices(
        evmz.trace.CheckpointKind,
        &.{ .checkpoint, .checkpoint, .commit, .checkpoint, .commit, .commit },
        recorder.events[0..recorder.len],
    );
    try std.testing.expectEqual(@as(u256, 2), try executor.getStorage(LifecycleBlock.before_transaction_address, 0));
    block.discardIfUnfinished();
}

test "Sequential block rejection restores before-transaction hook and payload writes" {
    const sender = evmz.addr(0xaaaa);
    const payload = evmz.addr(0xbbbb);
    var memory = MemoryStore.init(std.testing.allocator);
    defer memory.deinit();

    var sender_account = try memory.getOrCreateAccount(sender);
    sender_account.balance = 10_000_000;
    var hook_account = try memory.getOrCreateAccount(LifecycleBlock.before_transaction_address);
    try hook_account.setCode(&lifecycle_code);
    var payload_account = try memory.getOrCreateAccount(payload);
    try payload_account.setCode(&lifecycle_code);

    var executor = LifecycleVm.Executor.init(std.testing.allocator, .{
        .revision = .prague,
        .state_reader = memory.reader(),
    });
    defer executor.deinit();

    var block = try beginBlock(LifecycleVm, &executor, .{
        .number = 7,
        .timestamp = 9,
        .gas_limit = 1_000_000,
    });
    defer block.discardIfUnfinished();
    block.block.state.block_gas = evmz.transaction.BlockGas.legacy(std.math.maxInt(u64));

    var input = [_]u8{0} ** 32;
    input[31] = 5;
    try std.testing.expectError(error.BlockGasExceeded, block.transact(.{
        .sender = sender,
        .to = payload,
        .input = &input,
        .gas_limit = 300_000,
    }));

    try std.testing.expectEqual(@as(u256, 0), try executor.getStorage(LifecycleBlock.before_transaction_address, 0));
    try std.testing.expectEqual(@as(u256, 0), try executor.getStorage(payload, 0));
    const progress = try block.progress();
    try std.testing.expectEqual(@as(u64, 0), progress.tx_count);
    try std.testing.expectEqual(std.math.maxInt(u64), progress.block_gas.total);
}

test "Sequential discard restores included hook and payload without allocating" {
    const sender = evmz.addr(0xaaaa);
    const payload = evmz.addr(0xbbbb);
    var memory = MemoryStore.init(std.testing.allocator);
    defer memory.deinit();

    var sender_account = try memory.getOrCreateAccount(sender);
    sender_account.balance = 10_000_000;
    var hook_account = try memory.getOrCreateAccount(LifecycleBlock.before_transaction_address);
    try hook_account.setCode(&lifecycle_code);
    var payload_account = try memory.getOrCreateAccount(payload);
    try payload_account.setCode(&lifecycle_code);

    var failing_allocator = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var executor = LifecycleVm.Executor.init(failing_allocator.allocator(), .{
        .revision = .prague,
        .state_reader = memory.reader(),
    });
    defer executor.deinit();

    var block = try beginBlock(LifecycleVm, &executor, .{
        .number = 7,
        .timestamp = 9,
        .gas_limit = 1_000_000,
    });
    defer block.discardIfUnfinished();
    var input = [_]u8{0} ** 32;
    input[31] = 5;
    const included = switch (try block.transact(.{
        .sender = sender,
        .to = payload,
        .input = &input,
        .gas_limit = 300_000,
    })) {
        .included => |value| value,
        .rejected => return error.UnexpectedRejection,
    };
    const receipt = included.receipt;
    try std.testing.expectEqual(receipt.gas_used, receipt.cumulative_gas_used);
    try std.testing.expectEqual(@as(u64, 1), (try block.progress()).tx_count);

    failing_allocator.fail_index = failing_allocator.alloc_index;
    block.discardIfUnfinished();
    try std.testing.expect(!failing_allocator.has_induced_failure);
    failing_allocator.fail_index = std.math.maxInt(usize);

    try std.testing.expectEqual(@as(u256, 0), try executor.getStorage(LifecycleBlock.before_transaction_address, 0));
    try std.testing.expectEqual(@as(u256, 0), try executor.getStorage(payload, 0));
    try std.testing.expectError(error.BlockExecutionFinished, block.progress());
}

test "Sequential restores a system call when outer commit observation fails" {
    const recipient = evmz.addr(0x2201);
    var memory = MemoryStore.init(std.testing.allocator);
    defer memory.deinit();
    var recipient_account = try memory.getOrCreateAccount(recipient);
    try recipient_account.setCode(&lifecycle_code);

    var executor = LifecycleVm.Executor.init(std.testing.allocator, .{
        .revision = .prague,
        .state_reader = memory.reader(),
    });
    defer executor.deinit();

    var failing = FailingCheckpointTarget{ .fail_commit_at = 2 };
    var capture = evmz.executor.CaptureContext.init(std.testing.allocator, null, failing.target());
    defer capture.deinit();
    executor.setCaptureContext(&capture);
    defer executor.setCaptureContext(null);
    try capture.begin();
    defer if (capture.isActive()) capture.abort() catch {};

    var block = try beginBlock(LifecycleVm, &executor, .{ .gas_limit = 1_000_000 });
    defer block.discardIfUnfinished();
    var input = [_]u8{0} ** 32;
    input[31] = 5;
    try std.testing.expectError(
        error.TestCaptureFailure,
        block.systemCall(.{
            .sender = evmz.eth.system_address,
            .recipient = recipient,
            .input = &input,
            .gas = 100_000,
        }),
    );
    try std.testing.expectEqual(@as(usize, 2), failing.commit_count);
    try std.testing.expectEqual(@as(u256, 0), try executor.getStorage(recipient, 0));
    const summary = try block.finish();
    try std.testing.expectEqual(@as(u64, 0), summary.gas_used);
    try std.testing.expectEqual(@as(u64, 0), summary.block_gas.total);
    try std.testing.expectEqual(@as(u64, 0), summary.tx_count);
    _ = try capture.finish();
}

test "Sequential restores included transaction progress when outer observation fails" {
    const sender = evmz.addr(0xaaaa);
    const recipient = evmz.addr(0xbbbb);
    var memory = MemoryStore.init(std.testing.allocator);
    defer memory.deinit();
    var sender_account = try memory.getOrCreateAccount(sender);
    sender_account.balance = 10_000_000;
    var hook_account = try memory.getOrCreateAccount(LifecycleBlock.before_transaction_address);
    try hook_account.setCode(&lifecycle_code);

    var executor = LifecycleVm.Executor.init(std.testing.allocator, .{
        .revision = .prague,
        .state_reader = memory.reader(),
    });
    defer executor.deinit();

    var failing = FailingCheckpointTarget{ .fail_commit_at = 3 };
    var capture = evmz.executor.CaptureContext.init(std.testing.allocator, null, failing.target());
    defer capture.deinit();
    executor.setCaptureContext(&capture);
    defer executor.setCaptureContext(null);
    try capture.begin();
    defer if (capture.isActive()) capture.abort() catch {};

    var block = try beginBlock(LifecycleVm, &executor, .{
        .number = 7,
        .timestamp = 9,
        .gas_limit = 1_000_000,
    });
    defer block.discardIfUnfinished();
    // Type-erased capture/provider failures are normalized at the public
    // transaction boundary while the rollback behavior remains unchanged.
    try std.testing.expectError(error.InfrastructureFailure, block.transact(.{
        .sender = sender,
        .to = recipient,
        .gas_limit = 300_000,
    }));
    try std.testing.expectEqual(@as(usize, 3), failing.commit_count);
    try std.testing.expectEqual(@as(u256, 0), try executor.getStorage(LifecycleBlock.before_transaction_address, 0));
    try std.testing.expectEqual(@as(u64, 0), (try executor.getAccountOrLoad(sender)).?.nonce);
    const summary = try block.finish();
    try std.testing.expectEqual(@as(u64, 0), summary.gas_used);
    try std.testing.expectEqual(@as(u64, 0), summary.block_gas.total);
    try std.testing.expectEqual(@as(u64, 0), summary.tx_count);
    _ = try capture.finish();
}

test "block lifecycle hook batches restore earlier calls when a later call fails" {
    var memory = MemoryStore.init(std.testing.allocator);
    defer memory.deinit();
    var recipient = try memory.getOrCreateAccount(AtomicLifecycleBlock.recipient);
    try recipient.setCode(&lifecycle_code);

    var executor = AtomicLifecycleVm.Executor.init(std.testing.allocator, .{
        .revision = .prague,
        .state_reader = memory.reader(),
    });
    defer executor.deinit();

    var block = try beginBlock(AtomicLifecycleVm, &executor, .{ .gas_limit = 1_000_000 });
    defer block.discardIfUnfinished();
    try std.testing.expectError(error.SystemCallFailed, block.beforeBlock(.{}));
    try std.testing.expectEqual(@as(u256, 0), try executor.getStorage(AtomicLifecycleBlock.recipient, 0));

    try std.testing.expectError(error.SystemCallFailed, block.finalizeBlock(std.testing.allocator));
    try std.testing.expectEqual(@as(u256, 0), try executor.getStorage(AtomicLifecycleBlock.recipient, 0));
}

test "Sequential finish flushes the final included transaction after hook" {
    const sender = evmz.addr(0xaaaa);
    var memory = MemoryStore.init(std.testing.allocator);
    defer memory.deinit();
    var sender_account = try memory.getOrCreateAccount(sender);
    sender_account.balance = 10_000_000;
    var hook_account = try memory.getOrCreateAccount(FinishLifecycleBlock.recipient);
    try hook_account.setCode(&lifecycle_code);

    var executor = FinishLifecycleVm.Executor.init(std.testing.allocator, .{
        .revision = .prague,
        .state_reader = memory.reader(),
    });
    defer executor.deinit();

    var block = try beginBlock(FinishLifecycleVm, &executor, .{ .gas_limit = 1_000_000 });
    defer block.discardIfUnfinished();
    _ = switch (try block.transact(.{
        .sender = sender,
        .to = evmz.addr(0xbbbb),
        .gas_limit = 300_000,
    })) {
        .included => |included| included,
        .rejected => return error.UnexpectedRejection,
    };

    const summary = try block.finish();
    try std.testing.expectEqual(@as(u64, 1), summary.tx_count);
    try std.testing.expectEqual(@as(u256, 9), try executor.getStorage(FinishLifecycleBlock.recipient, 0));
}

test "Sequential next transaction stops when the previous after hook fails" {
    const sender = evmz.addr(0xaaaa);
    const recipient = evmz.addr(0xbbbb);
    var memory = MemoryStore.init(std.testing.allocator);
    defer memory.deinit();
    var sender_account = try memory.getOrCreateAccount(sender);
    sender_account.balance = 10_000_000;

    var executor = RejectingAfterTransactionVm.Executor.init(std.testing.allocator, .{
        .revision = .prague,
        .state_reader = memory.reader(),
    });
    defer executor.deinit();

    var block = try beginBlock(RejectingAfterTransactionVm, &executor, .{ .gas_limit = 1_000_000 });
    defer block.discardIfUnfinished();
    _ = switch (try block.transact(.{
        .sender = sender,
        .to = recipient,
        .gas_limit = 100_000,
    })) {
        .included => |included| included,
        .rejected => return error.UnexpectedRejection,
    };

    try std.testing.expectError(error.SystemCallFailed, block.transact(.{
        .sender = sender,
        .nonce = 1,
        .to = recipient,
        .gas_limit = 100_000,
    }));
    try std.testing.expectEqual(@as(u64, 1), (try block.progress()).tx_count);
    try std.testing.expectEqual(@as(u64, 1), (try executor.getAccountOrLoad(sender)).?.nonce);

    block.discardIfUnfinished();
    try std.testing.expectEqual(@as(u64, 0), (try executor.getAccountOrLoad(sender)).?.nonce);
}

test "one Executor admits only one active Sequential" {
    var executor = evmz.Evm.Executor.init(std.testing.allocator, .{ .revision = .amsterdam });
    defer executor.deinit();

    var block = try beginBlock(evmz.Evm, &executor, .{ .gas_limit = 1_000_000 });
    defer block.discardIfUnfinished();
    var vm = evmz.Evm.init(&executor);

    try std.testing.expectError(
        error.BlockExecutionActive,
        beginBlock(evmz.Evm, &executor, .{ .gas_limit = 1_000_000 }),
    );
    try std.testing.expectError(
        error.BlockExecutionActive,
        vm.transact(.{
            .env = .{ .gas_limit = 1_000_000 },
            .tx = .{
                .sender = evmz.addr(0xaaaa),
                .to = evmz.addr(0xbbbb),
                .gas_limit = 21_000,
            },
        }),
    );
    try std.testing.expectError(
        error.BlockExecutionActive,
        executor.reset(.{ .revision = .amsterdam }),
    );
}

test "independent Executors admit independent Sequential lifetimes" {
    var first_executor = evmz.Evm.Executor.init(std.testing.allocator, .{ .revision = .amsterdam });
    defer first_executor.deinit();
    var second_executor = evmz.Evm.Executor.init(std.testing.allocator, .{ .revision = .amsterdam });
    defer second_executor.deinit();

    var first = try beginBlock(evmz.Evm, &first_executor, .{ .gas_limit = 1_000_000 });
    defer first.discardIfUnfinished();
    var second = try beginBlock(evmz.Evm, &second_executor, .{ .gas_limit = 1_000_000 });
    defer second.discardIfUnfinished();

    try std.testing.expectEqual(@as(u64, 0), (try first.progress()).tx_count);
    try std.testing.expectEqual(@as(u64, 0), (try second.progress()).tx_count);
}

test "stale Sequential copy cannot resolve a later generation" {
    var executor = evmz.Evm.Executor.init(std.testing.allocator, .{ .revision = .amsterdam });
    defer executor.deinit();

    var first = try beginBlock(evmz.Evm, &executor, .{ .gas_limit = 1_000_000 });
    var stale = first;
    first.discardIfUnfinished();

    var second = try beginBlock(evmz.Evm, &executor, .{ .gas_limit = 1_000_000 });
    defer second.discardIfUnfinished();
    stale.discardIfUnfinished();

    try std.testing.expectError(error.StaleBlockExecution, stale.progress());
    try std.testing.expectEqual(@as(u64, 0), (try second.progress()).tx_count);
}

fn beginBlock(comptime Engine: type, executor: *Engine.Executor, env: evmz.Env) !Engine.Sequential {
    return Engine.Sequential.init(
        executor,
        .{ .env = env },
    );
}
