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

const EmptyBeforeTransactionBlock = struct {
    var invocations = std.atomic.Value(usize).init(0);

    fn beforeTransaction(_: evmz.eth.Revision, _: protocol.BeforeTransactionContext) protocol.BlockSystemCalls {
        _ = invocations.fetchAdd(1, .monotonic);
        return .{};
    }
};

const EmptyBeforeTransactionDefinition = evmz.eth.define(.{
    .block = .{ .beforeTransaction = EmptyBeforeTransactionBlock.beforeTransaction },
});
const EmptyBeforeTransactionVm = evmz.Vm(evmz.eth.Revision, EmptyBeforeTransactionDefinition, .{});

const CheckpointRecorder = struct {
    events: [8]evmz.trace.CheckpointKind = undefined,
    len: usize = 0,

    fn sink(self: *CheckpointRecorder) evmz.trace.Sink {
        return evmz.trace.Sink.init(self, .{
            .checkpoint = evmz.trace.CheckpointFields.initMany(&.{.kind}),
        }, &.{ .checkpoint = checkpoint });
    }

    fn checkpoint(ptr: *anyopaque, event: evmz.trace.Checkpoint) void {
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

test "BlockSession empty before-transaction hook skips the full snapshot" {
    const sender = evmz.addr(0xaaaa);
    var memory = MemoryStore.init(std.testing.allocator);
    defer memory.deinit();

    var sender_account = try memory.getOrCreateAccount(sender);
    sender_account.balance = 10_000_000;

    EmptyBeforeTransactionBlock.invocations.store(0, .monotonic);
    var recorder = CheckpointRecorder{};
    var sink = recorder.sink();
    var vm = EmptyBeforeTransactionVm.init(std.testing.allocator, .{
        .revision = .amsterdam,
        .state_reader = memory.reader(),
    });
    defer vm.deinit();
    var capture = evmz.executor.CaptureContext.init(
        std.testing.allocator,
        null,
        evmz.executor.capture_context.stateTargetForSink(&sink),
    );
    defer capture.deinit();
    vm.executor.setCaptureContext(&capture);
    try capture.begin();
    defer {
        if (capture.isActive()) capture.abort() catch {};
        vm.executor.setCaptureContext(null);
    }

    var block = try vm.beginBlock(.{ .gas_limit = 1_000_000 });
    _ = switch (try block.transact(.{
        .sender = sender,
        .to = evmz.addr(0xbbbb),
        .gas_limit = 300_000,
    })) {
        .executed => |result| result,
        .rejected => return error.UnexpectedRejection,
    };
    _ = try capture.finish();

    try std.testing.expectEqual(@as(usize, 1), EmptyBeforeTransactionBlock.invocations.load(.monotonic));
    try std.testing.expectEqualSlices(
        evmz.trace.CheckpointKind,
        &.{ .checkpoint, .checkpoint, .commit, .commit },
        recorder.events[0..recorder.len],
    );
}

test "BlockSession block rejection restores before-transaction hook and payload writes" {
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

    var vm = LifecycleVm.init(std.testing.allocator, .{
        .revision = .prague,
        .state_reader = memory.reader(),
    });
    defer vm.deinit();

    var block = try vm.beginBlock(.{
        .number = 7,
        .timestamp = 9,
        .gas_limit = 1_000_000,
    });
    block.block_gas = evmz.transaction.BlockGas.legacy(std.math.maxInt(u64));

    var input = [_]u8{0} ** 32;
    input[31] = 5;
    try std.testing.expectError(error.BlockGasExceeded, block.transact(.{
        .sender = sender,
        .to = payload,
        .input = &input,
        .gas_limit = 300_000,
    }));

    try std.testing.expectEqual(@as(u256, 0), try vm.getStorage(LifecycleBlock.before_transaction_address, 0));
    try std.testing.expectEqual(@as(u256, 0), try vm.getStorage(payload, 0));
    try std.testing.expectEqual(@as(u64, 0), block.tx_count);
    try std.testing.expectEqual(std.math.maxInt(u64), block.block_gas.total);
}

test "BlockSession restores a system call when outer commit observation fails" {
    const recipient = evmz.addr(0x2201);
    var vm = LifecycleVm.init(std.testing.allocator, .{ .revision = .prague });
    defer vm.deinit();
    try vm.executor.state.setCode(recipient, &lifecycle_code);

    var failing = FailingCheckpointTarget{ .fail_commit_at = 2 };
    var capture = evmz.executor.CaptureContext.init(std.testing.allocator, null, failing.target());
    defer capture.deinit();
    vm.executor.setCaptureContext(&capture);
    defer vm.executor.setCaptureContext(null);
    try capture.begin();
    defer if (capture.isActive()) capture.abort() catch {};

    var block = try vm.beginBlock(.{ .gas_limit = 1_000_000 });
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
    try std.testing.expectEqual(@as(u256, 0), try vm.getStorage(recipient, 0));
    const summary = try block.finish();
    try std.testing.expectEqual(@as(u64, 0), summary.gas_used);
    try std.testing.expectEqual(@as(u64, 0), summary.block_gas.total);
    try std.testing.expectEqual(@as(u64, 0), summary.tx_count);
    _ = try capture.finish();
}

test "BlockSession restores accepted transaction progress when outer observation fails" {
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
    try vm.executor.state.setCode(LifecycleBlock.before_transaction_address, &lifecycle_code);

    var failing = FailingCheckpointTarget{ .fail_commit_at = 4 };
    var capture = evmz.executor.CaptureContext.init(std.testing.allocator, null, failing.target());
    defer capture.deinit();
    vm.executor.setCaptureContext(&capture);
    defer vm.executor.setCaptureContext(null);
    try capture.begin();
    defer if (capture.isActive()) capture.abort() catch {};

    var block = try vm.beginBlock(.{
        .number = 7,
        .timestamp = 9,
        .gas_limit = 1_000_000,
    });
    try std.testing.expectError(error.TestCaptureFailure, block.transact(.{
        .sender = sender,
        .to = recipient,
        .gas_limit = 300_000,
    }));
    try std.testing.expectEqual(@as(usize, 4), failing.commit_count);
    try std.testing.expectEqual(@as(u256, 0), try vm.getStorage(LifecycleBlock.before_transaction_address, 0));
    try std.testing.expectEqual(@as(u64, 0), vm.executor.getAccount(sender).?.nonce);
    const summary = try block.finish();
    try std.testing.expectEqual(@as(u64, 0), summary.gas_used);
    try std.testing.expectEqual(@as(u64, 0), summary.block_gas.total);
    try std.testing.expectEqual(@as(u64, 0), summary.tx_count);
    _ = try capture.finish();
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
