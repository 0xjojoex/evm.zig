const std = @import("std");
const evmz = @import("../evm.zig");

const Executor = evmz.Executor;
const Host = evmz.Host;
const trace = evmz.trace;

test "execution checkpoints require one stable transaction scope" {
    const sender = evmz.addr(0xaaaa);
    const contract = evmz.addr(0xbbbb);
    const other = evmz.addr(0xcccc);
    var executor = Executor.init(std.testing.allocator, .{
        .revision = .berlin,
    });
    defer executor.deinit();

    try std.testing.expectError(error.MissingTransactionScope, executor.checkpoint());
    try std.testing.expectError(error.MissingTransactionScope, executor.warmAccount(other));
    try std.testing.expectError(error.MissingTransactionScope, executor.warmStorage(other, 1));
    try std.testing.expectError(error.MissingTransactionScope, executor.warmAccessList(&.{}));
    try std.testing.expectError(error.MissingTransactionScope, executor.executeMessage(.{ .call = .{
        .sender = sender,
        .recipient = contract,
        .gas = 100_000,
    } }));

    const tx_context = evmz.t.defaultTxContext(sender, 100_000);
    try executor.beginTransaction(tx_context, sender, contract);
    defer executor.closeTransaction();

    try std.testing.expectError(
        error.ActiveTransactionScope,
        executor.beginTransaction(evmz.t.defaultTxContext(other, 200_000), other, other),
    );
    var host = executor.host();
    try std.testing.expectEqual(sender, (try host.getTxContext()).origin);
    try std.testing.expect(executor.state.warm_accounts.contains(sender));
    try std.testing.expect(executor.state.warm_accounts.contains(contract));
    try std.testing.expect(!executor.state.warm_accounts.contains(other));

    var full_snapshot = try executor.snapshot();
    defer full_snapshot.deinit(std.testing.allocator);
    var checkpoint = try executor.checkpoint();
    defer checkpoint.deinit();

    try std.testing.expectError(error.ActiveExecutionCheckpoints, executor.commitTransaction());
    try std.testing.expectError(error.ActiveExecutionCheckpoints, executor.rollbackTransaction(&full_snapshot));
    try checkpoint.restore();
}

test "transaction request rejects a context different from the open scope" {
    const sender = evmz.addr(0xaaaa);
    const contract = evmz.addr(0xbbbb);
    var executor = Executor.init(std.testing.allocator, .{
        .revision = .shanghai,
    });
    defer executor.deinit();

    const original = request(sender, contract);
    try executor.beginMessageScope(original, .{});
    defer executor.closeTransaction();

    var mismatched = original;
    mismatched.context.chain.chain_id = 2;
    try std.testing.expectError(error.ExecutionContextMismatch, executor.executeTransactionRequest(mismatched));
}

test "transaction request rejects a root different from the warmed scope" {
    const sender = evmz.addr(0xaaaa);
    const contract = evmz.addr(0xbbbb);
    var executor = Executor.init(std.testing.allocator, .{
        .revision = .shanghai,
    });
    defer executor.deinit();

    const original = request(sender, contract);
    try executor.beginMessageScope(original, .{});
    defer executor.closeTransaction();

    var mismatched = original;
    mismatched.message.call.recipient = evmz.addr(0xcccc);
    try std.testing.expectError(error.ExecutionScopeRootMismatch, executor.executeTransactionRequest(mismatched));
    try std.testing.expectError(error.ExecutionScopeRootMismatch, executor.executeMessage(mismatched.message));
}

test "top-level shell rejects a root different from the warmed scope before mutation" {
    const sender = evmz.addr(0xaaaa);
    const opened_recipient = evmz.addr(0xbbbb);
    const mismatched_recipient = evmz.addr(0xcccc);
    var executor = Executor.init(std.testing.allocator, .{ .revision = .cancun });
    defer executor.deinit();

    const opened = request(sender, opened_recipient);
    try executor.beginMessageScope(opened, .{});
    defer executor.closeTransaction();

    const scope = Executor.TransactionScope{ .context = opened.context };
    const root = evmz.transaction.RootFrame{ .call = .{
        .sender = sender,
        .recipient = mismatched_recipient,
        .gas_limit = 100_000,
    } };
    try std.testing.expectError(error.ExecutionScopeRootMismatch, executor.runTopLevelTransaction(scope, root, .{
        .execution = .legacy(79_000),
        .settlement = .{
            .revision_id = evmz.protocol.revisionId(evmz.eth.Revision.cancun),
            .gas_limit = 100_000,
            .intrinsic_gas = 21_000,
            .intrinsic_state_gas = 0,
            .floor_gas = 21_000,
            .gas_price = 0,
            .priority_fee = 0,
            .fee_recipient = evmz.addr(0),
        },
    }));

    if (try executor.getAccountOrLoad(sender)) |account| {
        try std.testing.expectEqual(@as(u64, 0), account.nonce);
    }
}

test "beginMessageScope derives root identity context and neutral warmth" {
    const sender = evmz.addr(0xaaaa);
    const recipient = evmz.addr(0xbbbb);
    const coinbase = evmz.addr(0xcccc);
    const additional = evmz.addr(0xdddd);
    const cold = evmz.addr(0xeeee);
    const blob_hashes = [_]u256{ 41, 43 };
    const warm_accounts = [_]evmz.Address{additional};
    const warm_slots = [_]evmz.execution.WarmStorageSlot{.{
        .address = additional,
        .key = 47,
    }};
    const execution_context = evmz.execution.ExecutionContext{
        .chain = .{ .chain_id = 7 },
        .block = .{
            .coinbase = coinbase,
            .number = 11,
            .slot_number = 13,
            .timestamp = 17,
            .gas_limit = 19,
            .difficulty_or_prev_randao = 23,
            .base_fee = 29,
            .blob_base_fee = 31,
        },
        .transaction = .{
            .origin = sender,
            .gas_price = 37,
            .blob_hashes = &blob_hashes,
        },
    };
    var executor = Executor.init(std.testing.allocator, .{
        .revision = .shanghai,
    });
    defer executor.deinit();
    defer executor.closeTransaction();

    try executor.beginMessageScope(.{
        .context = execution_context,
        .message = .{ .call = .{
            .sender = sender,
            .recipient = recipient,
            .gas = 100_000,
        } },
    }, .{ .initial_warm_set = .{
        .accounts = &warm_accounts,
        .storage_slots = &warm_slots,
    } });

    var host = executor.host();
    try std.testing.expectEqualDeep(Host.TxContext{
        .chain_id = 7,
        .gas_price = 37,
        .origin = sender,
        .coinbase = coinbase,
        .number = 11,
        .slot_number = 13,
        .timestamp = 17,
        .gas_limit = 19,
        .prev_randao = 23,
        .base_fee = 29,
        .blob_base_fee = 31,
        .blob_hashes = &blob_hashes,
    }, try host.getTxContext());
    try std.testing.expect(executor.state.warm_accounts.contains(sender));
    try std.testing.expect(executor.state.warm_accounts.contains(recipient));
    try std.testing.expect(executor.state.warm_accounts.contains(coinbase));
    try std.testing.expect(executor.state.warm_accounts.contains(additional));
    try std.testing.expect(executor.state.isStorageWarm(additional, 47));
    try std.testing.expect(!executor.state.warm_accounts.contains(cold));

    executor.closeTransaction();
    try executor.beginMessageScope(.{
        .context = execution_context,
        .message = .{ .create = .{
            .sender = sender,
            .init_code = &.{},
            .gas = 100_000,
        } },
    }, .{});

    try std.testing.expect(executor.state.warm_accounts.contains(sender));
    try std.testing.expect(executor.state.warm_accounts.contains(coinbase));
    try std.testing.expect(!executor.state.warm_accounts.contains(recipient));
}

test "beginMessageScope closes scope when initial warming fails" {
    const sender = evmz.addr(0xaaaa);
    const recipient = evmz.addr(0xbbbb);
    const coinbase = evmz.addr(0xcccc);
    const additional = evmz.addr(0xdddd);
    var executor = Executor.init(std.testing.allocator, .{
        .revision = .shanghai,
    });
    defer executor.deinit();
    try executor.state.configureAccessResources(.{
        .accounts = 3,
        .storage_keys = 0,
    });

    try std.testing.expectError(error.WarmAccountCapacityExceeded, executor.beginMessageScope(.{
        .context = .{
            .chain = .{ .chain_id = 1 },
            .block = .{ .coinbase = coinbase },
            .transaction = .{ .origin = sender },
        },
        .message = .{ .call = .{
            .sender = sender,
            .recipient = recipient,
            .gas = 100_000,
        } },
    }, .{ .initial_warm_set = .{
        .accounts = &.{additional},
    } }));

    var host = executor.host();
    try std.testing.expectError(error.MissingTxContext, host.getTxContext());
    try std.testing.expectEqual(@as(usize, 0), executor.state.warm_accounts.count());
    try std.testing.expectEqual(@as(usize, 0), executor.state.warmStorageCount());
    try std.testing.expectEqual(@as(usize, 0), executor.state.journal.len());
}

test "execution checkpoint preserves family pre-scope writes" {
    const sender = evmz.addr(0xaaaa);
    const contract = evmz.addr(0xbbbb);
    var executor = Executor.init(std.testing.allocator, .{
        .revision = .shanghai,
    });
    defer executor.deinit();

    // OP-style family lifecycle effect: it becomes the scope's state baseline.
    try executor.state.setBalance(sender, 7);
    try executor.beginMessageScope(request(sender, contract), .{});
    defer executor.closeTransaction();

    var execution_checkpoint = try executor.checkpoint();
    defer execution_checkpoint.deinit();
    try executor.state.setBalance(sender, 9);
    try execution_checkpoint.restore();

    try std.testing.expectEqual(@as(u256, 7), executor.getAccount(sender).?.balance);
}

test "checkpoint commit retains state and restore rolls back without closing scope" {
    const sender = evmz.addr(0xaaaa);
    const contract = evmz.addr(0xbbbb);
    const additional = evmz.addr(0xcccc);
    var recorder = CheckpointRecorder{};
    var sink = recorder.sink();
    var executor = Executor.init(std.testing.allocator, .{
        .revision = .berlin,
    });
    defer executor.deinit();
    var capture = evmz.executor.CaptureContext.init(
        std.testing.allocator,
        null,
        evmz.executor.capture_context.stateTargetForSink(&sink),
    );
    defer capture.deinit();
    executor.setCaptureContext(&capture);
    try capture.begin();
    defer {
        if (capture.isActive()) capture.abort() catch {};
        executor.setCaptureContext(null);
    }
    try executor.beginTransaction(evmz.t.defaultTxContext(sender, 100_000), sender, contract);
    defer executor.closeTransaction();

    var committed = try executor.checkpoint();
    defer committed.deinit();
    _ = try executor.state.setStorage(contract, 7, 1);
    try committed.commit();

    try std.testing.expectEqual(@as(u256, 1), try executor.getStorage(contract, 7));
    var host = executor.host();
    _ = try host.getTxContext();

    var reverted = try executor.checkpoint();
    defer reverted.deinit();
    _ = try executor.state.setStorage(contract, 7, 2);
    try executor.state.warmAccount(additional);
    try executor.state.emitLog(.{
        .address = contract,
        .topics = &.{3},
        .data = &.{0x42},
    });
    try reverted.restore();
    _ = try capture.finish();

    try std.testing.expectEqual(@as(u256, 1), try executor.getStorage(contract, 7));
    try std.testing.expect(!executor.state.warm_accounts.contains(additional));
    try std.testing.expectEqual(@as(usize, 0), executor.logs().len);
    _ = try host.getTxContext();
    try std.testing.expectEqualSlices(
        trace.CheckpointKind,
        &.{ .checkpoint, .commit, .checkpoint, .revert },
        recorder.events[0..recorder.len],
    );
}

test "checkpoint enforces LIFO closure and deinit restores an open token" {
    const sender = evmz.addr(0xaaaa);
    const contract = evmz.addr(0xbbbb);
    var executor = Executor.init(std.testing.allocator, .{
        .revision = .berlin,
    });
    defer executor.deinit();
    try executor.beginTransaction(evmz.t.defaultTxContext(sender, 100_000), sender, contract);
    defer executor.closeTransaction();

    {
        var outer = try executor.checkpoint();
        defer outer.deinit();
        _ = try executor.state.setStorage(contract, 7, 1);

        var inner = try executor.checkpoint();
        defer inner.deinit();
        _ = try executor.state.setStorage(contract, 7, 2);

        try std.testing.expectError(error.CheckpointOrderViolation, outer.commit());
        try inner.restore();
        try std.testing.expectEqual(@as(u256, 1), try executor.getStorage(contract, 7));
        try std.testing.expectError(error.CheckpointClosed, inner.commit());
    }

    try std.testing.expectEqual(@as(u256, 0), try executor.getStorage(contract, 7));
}

test "stale checkpoint copy cannot close a later checkpoint" {
    const sender = evmz.addr(0xaaaa);
    const contract = evmz.addr(0xbbbb);
    var executor = Executor.init(std.testing.allocator, .{
        .revision = .berlin,
    });
    defer executor.deinit();
    try executor.beginTransaction(evmz.t.defaultTxContext(sender, 100_000), sender, contract);
    defer executor.closeTransaction();

    var first = try executor.checkpoint();
    // The rejected copy owns no allocation; it exists only to probe stale-id use.
    var stale = first;
    _ = try executor.state.setStorage(contract, 7, 1);
    try first.commit();
    first.deinit();

    var current = try executor.checkpoint();
    defer current.deinit();
    _ = try executor.state.setStorage(contract, 7, 2);

    try std.testing.expectError(error.CheckpointOrderViolation, stale.restore());
    try std.testing.expectEqual(@as(u256, 2), try executor.getStorage(contract, 7));
    try current.restore();
    try std.testing.expectEqual(@as(u256, 1), try executor.getStorage(contract, 7));
}

test "checkpoint revert balances the block access recorder" {
    const sender = evmz.addr(0xaaaa);
    const contract = evmz.addr(0xbbbb);
    var recorder = evmz.eth.bal_recorder.Recorder.init(std.testing.allocator);
    defer recorder.deinit();
    recorder.setBlockAccessIndex(1);
    var executor = Executor.init(std.testing.allocator, .{
        .revision = .amsterdam,
    });
    defer executor.deinit();
    var capture = evmz.executor.CaptureContext.init(std.testing.allocator, null, recorder.stateTarget());
    defer capture.deinit();
    executor.setCaptureContext(&capture);
    try capture.begin();
    defer {
        if (capture.isActive()) capture.abort() catch {};
        executor.setCaptureContext(null);
    }
    try executor.beginTransaction(evmz.t.defaultTxContext(sender, 100_000), sender, contract);
    defer executor.closeTransaction();

    var checkpoint = try executor.checkpoint();
    defer checkpoint.deinit();
    _ = try executor.state.setStorage(contract, 8, 1);
    try checkpoint.restore();
    _ = try capture.finish();

    var observed = try recorder.toOwnedBlockAccessList(std.testing.allocator);
    defer observed.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), observed.accounts.len);
    try std.testing.expectEqualSlices(u8, &contract, &observed.accounts[0].address);
    try std.testing.expectEqual(@as(usize, 0), observed.accounts[0].storage_changes.len);
    try std.testing.expectEqualSlices(u256, &.{8}, observed.accounts[0].storage_reads);
}

test "runStandaloneRequest owns success and revert scope lifecycles" {
    const sender = evmz.addr(0xaaaa);
    const contract = evmz.addr(0xbbbb);
    const success_code = evmz.t.bytecode(.{ .PUSH1, 0x2a, .PUSH0, .SSTORE, .STOP });
    const revert_code = evmz.t.bytecode(.{ .PUSH1, 0x2a, .PUSH0, .SSTORE, .PUSH0, .PUSH0, .REVERT });

    {
        var executor = Executor.init(std.testing.allocator, .{ .revision = .shanghai });
        defer executor.deinit();
        var account = evmz.state.MemoryAccount.init(std.testing.allocator);
        try account.setCode(&success_code);
        try executor.state.seedAccount(contract, account);

        const result = (try executor.runStandaloneRequest(request(sender, contract), .{})).expectCall();

        try std.testing.expectEqual(evmz.interpreter.Status.success, result.status);
        try std.testing.expectEqual(@as(u256, 0x2a), try executor.getStorage(contract, 0));
        var host = executor.host();
        try std.testing.expectError(error.MissingTxContext, host.getTxContext());
    }

    {
        var executor = Executor.init(std.testing.allocator, .{ .revision = .shanghai });
        defer executor.deinit();
        var account = evmz.state.MemoryAccount.init(std.testing.allocator);
        try account.setCode(&revert_code);
        try executor.state.seedAccount(contract, account);

        const result = (try executor.runStandaloneRequest(request(sender, contract), .{})).expectCall();

        try std.testing.expectEqual(evmz.interpreter.Status.revert, result.status);
        try std.testing.expectEqual(@as(u256, 0), try executor.getStorage(contract, 0));
        var host = executor.host();
        try std.testing.expectError(error.MissingTxContext, host.getTxContext());
    }
}

test "runStandaloneRequest restores and closes scope on Zig error" {
    const sender = evmz.addr(0xaaaa);
    const precompile = evmz.precompile.Contract.identity.toAddress();
    const input = [_]u8{ 0xde, 0xad };
    var recorder = CheckpointRecorder{};
    var sink = recorder.sink();
    var executor = try Executor.initWithRuntimeResources(std.testing.allocator, .{
        .revision = .cancun,
    }, .{ .bounded = .{
        .max_live_frames = 1,
        .result_bytes = input.len - 1,
    } });
    defer executor.deinit();
    try executor.state.seedAccount(sender, evmz.state.MemoryAccount.init(std.testing.allocator));
    var capture = evmz.executor.CaptureContext.init(
        std.testing.allocator,
        null,
        evmz.executor.capture_context.stateTargetForSink(&sink),
    );
    defer capture.deinit();
    executor.setCaptureContext(&capture);
    try capture.begin();
    defer {
        if (capture.isActive()) capture.abort() catch {};
        executor.setCaptureContext(null);
    }

    try std.testing.expectError(error.ResultOutputCapacityExceeded, executor.runStandaloneRequest(.{
        .context = context(sender),
        .message = .{ .call = .{
            .sender = sender,
            .recipient = precompile,
            .input = &input,
            .gas = 1_000,
        } },
    }, .{}));
    _ = try capture.finish();

    var host = executor.host();
    try std.testing.expectError(error.MissingTxContext, host.getTxContext());
    try std.testing.expectEqual(@as(usize, 0), executor.state.warm_accounts.count());
    try std.testing.expectEqual(@as(usize, 0), executor.state.warmStorageCount());
    try std.testing.expectEqual(@as(usize, 0), executor.state.journal.len());
    try std.testing.expectEqualSlices(
        trace.CheckpointKind,
        &.{ .checkpoint, .revert },
        recorder.events[0..recorder.len],
    );
}

test "bounded trace capture failure rolls back the standalone operation" {
    const sender = evmz.addr(0xaaaa);
    const contract = evmz.addr(0xbbbb);
    const code = evmz.t.bytecode(.{ .PUSH1, 0x2a, .PUSH0, .SSTORE, .STOP });
    var step_storage: [3]trace.tape.StepRow = undefined;
    var frame_storage: [1]trace.tape.FrameRow = undefined;
    var step_ref_storage: [3]trace.tape.StepTransitionRef = undefined;
    var stack_transition_storage: [3]trace.tape.StackTransition = undefined;
    var memory_transition_storage: [3]trace.tape.MemoryTransition = undefined;
    var return_data_transition_storage: [3]trace.tape.ReturnDataTransition = undefined;
    var frame_transition_storage: [1]trace.tape.FrameTransition = undefined;
    var word_storage: [3]u256 = undefined;
    var byte_storage: [0]u8 = undefined;
    var memory_write_storage: [0]trace.tape.MemoryWrite = undefined;
    var capture_frame_storage: [1]trace.TraceCapture = undefined;
    var tape = trace.TraceTape.initBounded(.{
        .table = .{
            .steps = &step_storage,
            .frames = &frame_storage,
        },
        .transitions = .{
            .step_refs = &step_ref_storage,
            .stack = &stack_transition_storage,
            .memory = &memory_transition_storage,
            .return_data = &return_data_transition_storage,
            .frames = &frame_transition_storage,
            .words = &word_storage,
            .bytes = &byte_storage,
            .memory_writes = &memory_write_storage,
        },
    });
    defer tape.deinit();

    var executor = Executor.init(std.testing.allocator, .{ .revision = .shanghai });
    defer executor.deinit();
    var account = evmz.state.MemoryAccount.init(std.testing.allocator);
    try account.setCode(&code);
    try executor.state.seedAccount(contract, account);

    var capture = evmz.executor.CaptureContext.initBounded(&capture_frame_storage, .{ .tape = &tape }, null);
    defer capture.deinit();
    executor.setCaptureContext(&capture);
    defer executor.setCaptureContext(null);
    try capture.begin();
    defer if (capture.isActive()) capture.abort() catch {};

    try std.testing.expectError(
        error.TraceCapacityExceeded,
        executor.runStandaloneRequest(request(sender, contract), .{}),
    );
    try std.testing.expectEqual(@as(u256, 0), try executor.getStorage(contract, 0));
    var host = executor.host();
    try std.testing.expectError(error.MissingTxContext, host.getTxContext());

    try capture.abort();
    try std.testing.expectEqual(@as(usize, 0), tape.stepCount());
    try std.testing.expectEqual(@as(usize, 0), tape.frameCount());
}

test "captured CALL publishes return data and parent memory output after resume" {
    const sender = evmz.addr(0xaaaa);
    const contract = evmz.addr(0xbbbb);
    const child = evmz.addr(0x1234);
    const child_code = evmz.t.bytecode(.{
        .PUSH1, 0xaa, .PUSH0, .MSTORE8, .PUSH1, 0x01, .PUSH0, .RETURN,
    });
    const code = evmz.t.bytecode(.{
        .PUSH1, 0x01, .PUSH0, .PUSH0, .PUSH0, .PUSH0,
        .PUSH2, 0x12, 0x34,   .GAS,   .CALL,  .STOP,
    });

    var executor = Executor.init(std.testing.allocator, .{ .revision = .cancun });
    defer executor.deinit();
    var account = evmz.state.MemoryAccount.init(std.testing.allocator);
    try account.setCode(&code);
    try executor.state.seedAccount(contract, account);
    var child_account = evmz.state.MemoryAccount.init(std.testing.allocator);
    try child_account.setCode(&child_code);
    try executor.state.seedAccount(child, child_account);

    var tape = trace.TraceTape.initGrowable(std.testing.allocator);
    defer tape.deinit();
    var capture = evmz.executor.CaptureContext.init(std.testing.allocator, .{
        .tape = &tape,
        .profile = .{ .memory = .writes },
    }, null);
    defer capture.deinit();
    executor.setCaptureContext(&capture);
    defer executor.setCaptureContext(null);

    try capture.begin();
    errdefer capture.abort() catch {};
    const result = try executor.runStandaloneRequest(request(sender, contract), .{});
    const span = (try capture.finish()).?;
    defer tape.resolve(span) catch unreachable;
    try std.testing.expectEqual(evmz.interpreter.Status.success, result.status());

    var call_index: ?usize = null;
    var stop_index: ?usize = null;
    for (span.steps, 0..) |row, index| {
        if (row.frame_id != 0) continue;
        if (row.opcode == @intFromEnum(evmz.Opcode.CALL)) call_index = index;
        if (row.opcode == @intFromEnum(evmz.Opcode.STOP)) stop_index = index;
    }

    const root = span.frames[0];
    const child_frame = span.frames[1];
    var cursor = trace.tape.TraceCursor.init(span);
    cursor.enterFrame(root);
    for (span.steps[0..call_index.?]) |row| cursor.finishStep(row);
    cursor.enterFrame(child_frame);
    for (span.steps[call_index.? + 1 .. stop_index.?]) |row| cursor.finishStep(row);
    cursor.finishFrame(child_frame);
    cursor.leaveFrame(child_frame);
    cursor.finishStep(span.steps[call_index.?]);

    const writes = try cursor.memoryWrites();
    try std.testing.expectEqual(@as(usize, 1), writes.len);
    try std.testing.expectEqual(@as(u32, 0), writes[0].offset);
    try std.testing.expectEqualSlices(u8, &.{0xaa}, cursor.memoryWriteBytes(writes[0]));
    try std.testing.expectEqualSlices(u8, &.{0xaa}, cursor.returnData());
}

fn request(sender: evmz.Address, recipient: evmz.Address) evmz.execution.EvmExecutionRequest {
    return .{
        .context = context(sender),
        .message = .{ .call = .{
            .sender = sender,
            .recipient = recipient,
            .gas = 100_000,
        } },
    };
}

fn context(origin: evmz.Address) evmz.execution.ExecutionContext {
    return .{
        .chain = .{ .chain_id = 1 },
        .block = .{ .gas_limit = 30_000_000 },
        .transaction = .{ .origin = origin },
    };
}

const CheckpointRecorder = struct {
    events: [8]trace.CheckpointKind = undefined,
    len: usize = 0,

    fn sink(self: *CheckpointRecorder) trace.Sink {
        return trace.Sink.init(self, .{
            .checkpoint = trace.CheckpointFields.full,
        }, &.{
            .checkpoint = checkpointEvent,
        });
    }

    fn checkpointEvent(ptr: *anyopaque, event: trace.Checkpoint) void {
        const self: *CheckpointRecorder = @ptrCast(@alignCast(ptr));
        std.debug.assert(self.len < self.events.len);
        self.events[self.len] = event.kind;
        self.len += 1;
    }
};
