const std = @import("std");
const evmz = @import("../evm.zig");

const BerlinExecutor = evmz.Vm(evmz.eth.berlin).Executor;
const ShanghaiExecutor = evmz.Vm(evmz.eth.shanghai).Executor;
const CancunExecutor = evmz.Vm(evmz.eth.cancun).Executor;
const AmsterdamExecutor = evmz.Vm(evmz.eth.amsterdam).Executor;
const Host = evmz.Host;
const trace = evmz.trace;

test "execution resource plan and preparer have nominal root aliases" {
    try std.testing.expectEqual(evmz.execution_resources.Plan, evmz.ExecutionResourcePlan);
    try std.testing.expectEqual(evmz.execution_resources.Preparer, evmz.ExecutionResourcePreparer);
    try std.testing.expect(!@hasDecl(evmz.StateReader, "prefetch"));
    try std.testing.expect(!@hasDecl(evmz.ExecutionResourcePreparer, "verify"));
}

test "execution checkpoints require one stable transaction scope" {
    const sender = evmz.addr(0xaaaa);
    const contract = evmz.addr(0xbbbb);
    const other = evmz.addr(0xcccc);
    var executor = BerlinExecutor.init(std.testing.allocator, .{});
    defer executor.deinit();

    try std.testing.expectError(error.MissingTransactionScope, executor.checkpoint());
    try std.testing.expectError(error.MissingTransactionScope, executor.warmAccount(other));
    try std.testing.expectError(error.MissingTransactionScope, executor.warmStorage(other, 1));
    try std.testing.expectError(error.MissingTransactionScope, executor.executeMessage(.{ .call = .{
        .sender = sender,
        .recipient = contract,
    } }, .legacy(100_000)));

    const tx_context = evmz.t.defaultTxContext(sender, 100_000);
    try executor.beginTransaction(tx_context, sender, contract);
    defer executor.closeTransaction();

    try std.testing.expectError(
        error.ActiveTransactionScope,
        executor.beginTransaction(evmz.t.defaultTxContext(other, 200_000), other, other),
    );
    var host = executor.host();
    try std.testing.expectEqual(sender, (try host.getTxContext()).origin);
    try std.testing.expect(executor.state.isAccountWarm(sender));
    try std.testing.expect(executor.state.isAccountWarm(contract));
    try std.testing.expect(!executor.state.isAccountWarm(other));

    var full_snapshot = try executor.branchCheckpoint();
    defer full_snapshot.deinit();
    var checkpoint = try executor.checkpoint();
    defer checkpoint.deinit();

    try std.testing.expectError(error.ActiveExecutionCheckpoints, executor.commitTransaction());
    try std.testing.expectError(error.ActiveExecutionCheckpoints, executor.rollbackTransaction(&full_snapshot));
    try checkpoint.restore();
}

test "transaction request rejects a context different from the open scope" {
    const sender = evmz.addr(0xaaaa);
    const contract = evmz.addr(0xbbbb);
    var executor = ShanghaiExecutor.init(std.testing.allocator, .{});
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
    var executor = ShanghaiExecutor.init(std.testing.allocator, .{});
    defer executor.deinit();

    const original = request(sender, contract);
    try executor.beginMessageScope(original, .{});
    defer executor.closeTransaction();

    var mismatched = original;
    mismatched.message.call.recipient = evmz.addr(0xcccc);
    try std.testing.expectError(error.ExecutionScopeRootMismatch, executor.executeTransactionRequest(mismatched));
    try std.testing.expectError(error.ExecutionScopeRootMismatch, executor.executeMessage(mismatched.message, mismatched.gas));
}

test "beginMessageScope derives root identity context and raw warmth" {
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
    var executor = ShanghaiExecutor.init(std.testing.allocator, .{});
    defer executor.deinit();
    defer executor.closeTransaction();

    try executor.beginMessageScope(.{
        .context = execution_context,
        .message = .{ .call = .{
            .sender = sender,
            .recipient = recipient,
        } },
        .gas = .legacy(100_000),
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
    try std.testing.expect(executor.state.isAccountWarm(sender));
    try std.testing.expect(executor.state.isAccountWarm(recipient));
    try std.testing.expect(!executor.state.isAccountWarm(coinbase));
    try std.testing.expect(executor.state.isAccountWarm(additional));
    try std.testing.expect(executor.state.isStorageWarm(additional, 47));
    try std.testing.expect(!executor.state.isAccountWarm(cold));

    executor.closeTransaction();
    try executor.beginMessageScope(.{
        .context = execution_context,
        .message = .{ .create = .{
            .sender = sender,
            .recipient = evmz.address.create(sender, 0),
            .init_code = &.{},
        } },
        .gas = .legacy(100_000),
    }, .{});

    try std.testing.expect(executor.state.isAccountWarm(sender));
    try std.testing.expect(!executor.state.isAccountWarm(coinbase));
    try std.testing.expect(!executor.state.isAccountWarm(recipient));
}

test "beginMessageScope closes scope when initial warming fails" {
    // TrackedState resource limits are intentionally deferred.
    return error.SkipZigTest;
}

test "execution checkpoint preserves family pre-scope writes" {
    const sender = evmz.addr(0xaaaa);
    const contract = evmz.addr(0xbbbb);
    var executor = ShanghaiExecutor.init(std.testing.allocator, .{});
    defer executor.deinit();

    var attempt = try executor.beginTransactionAttemptLifetime();
    defer attempt.discardIfCurrent();

    // OP-style family lifecycle effect: it becomes the payload scope's state baseline.
    try executor.state.setBalance(sender, 7);
    try attempt.beginExecution(request(sender, contract), .{});

    var execution_checkpoint = try executor.checkpoint();
    defer execution_checkpoint.deinit();
    try executor.state.setBalance(sender, 9);
    try execution_checkpoint.restore();

    try std.testing.expectEqual(@as(u256, 7), executor.getAccount(sender).?.balance);
    const pending = attempt.finish();
    try pending.retain();
}

test "checkpoint commit retains state and restore rolls back without closing scope" {
    const sender = evmz.addr(0xaaaa);
    const contract = evmz.addr(0xbbbb);
    const additional = evmz.addr(0xcccc);
    const Observer = struct {
        contract: evmz.Address,
        found: bool = false,

        pub fn observe(self: *@This(), pending: evmz.state.TrackedState.PendingView) !void {
            const storage = pending.observations().storage;
            var index: u32 = 0;
            while (index < storage.len()) : (index += 1) {
                const fact = storage.at(index);
                if (!std.mem.eql(u8, &fact.address, &self.contract) or fact.key != 7) continue;
                try std.testing.expectEqual(@as(u256, 0), fact.original);
                try std.testing.expectEqual(@as(u256, 1), fact.current);
                try std.testing.expect(fact.effect.written);
                self.found = true;
                return;
            }
        }
    };
    var observations = Observer{ .contract = contract };
    var executor = BerlinExecutor.init(std.testing.allocator, .{});
    defer executor.deinit();
    try executor.beginObservedTransaction(
        evmz.t.defaultTxContext(sender, 100_000),
        sender,
        contract,
    );
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

    try std.testing.expectEqual(@as(u256, 1), try executor.getStorage(contract, 7));
    try std.testing.expect(!executor.state.isAccountWarm(additional));
    try std.testing.expectEqual(@as(usize, 0), executor.logs().len());
    _ = try host.getTxContext();
    try executor.closeTransactionObserved(&observations);
    try std.testing.expect(observations.found);
}

test "checkpoint nests LIFO and deinit restores an open token" {
    const sender = evmz.addr(0xaaaa);
    const contract = evmz.addr(0xbbbb);
    var executor = BerlinExecutor.init(std.testing.allocator, .{});
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

        try inner.restore();
        try std.testing.expectEqual(@as(u256, 1), try executor.getStorage(contract, 7));
    }

    try std.testing.expectEqual(@as(u256, 0), try executor.getStorage(contract, 7));
}

test "successive checkpoints receive distinct ids" {
    const sender = evmz.addr(0xaaaa);
    const contract = evmz.addr(0xbbbb);
    var executor = BerlinExecutor.init(std.testing.allocator, .{});
    defer executor.deinit();
    try executor.beginTransaction(evmz.t.defaultTxContext(sender, 100_000), sender, contract);
    defer executor.closeTransaction();

    var first = try executor.checkpoint();
    const first_id = first.id;
    _ = try executor.state.setStorage(contract, 7, 1);
    try first.commit();
    first.deinit();

    var current = try executor.checkpoint();
    defer current.deinit();
    try std.testing.expect(first_id != current.id);
    _ = try executor.state.setStorage(contract, 7, 2);

    try std.testing.expectEqual(@as(u256, 2), try executor.getStorage(contract, 7));
    try current.restore();
    try std.testing.expectEqual(@as(u256, 1), try executor.getStorage(contract, 7));
}

test "checkpoint revert preserves reads without retaining storage effects" {
    const sender = evmz.addr(0xaaaa);
    const contract = evmz.addr(0xbbbb);
    const Observer = struct {
        contract: evmz.Address,
        found: bool = false,

        pub fn observe(self: *@This(), pending: evmz.state.TrackedState.PendingView) !void {
            const storage = pending.observations().storage;
            var index: u32 = 0;
            while (index < storage.len()) : (index += 1) {
                const fact = storage.at(index);
                if (!std.mem.eql(u8, &fact.address, &self.contract) or fact.key != 8) continue;
                try std.testing.expect(fact.observation.value_read);
                try std.testing.expect(!fact.effect.written);
                try std.testing.expectEqual(fact.original, fact.current);
                self.found = true;
                return;
            }
        }
    };
    var observations = Observer{ .contract = contract };
    var executor = AmsterdamExecutor.init(std.testing.allocator, .{});
    defer executor.deinit();
    try executor.beginObservedTransaction(
        evmz.t.defaultTxContext(sender, 100_000),
        sender,
        contract,
    );
    defer executor.closeTransaction();

    var checkpoint = try executor.checkpoint();
    defer checkpoint.deinit();
    _ = try executor.state.setStorage(contract, 8, 1);
    try checkpoint.restore();
    try executor.closeTransactionObserved(&observations);
    try std.testing.expect(observations.found);
}

test "runStandaloneRequest owns success and revert scope lifecycles" {
    const sender = evmz.addr(0xaaaa);
    const contract = evmz.addr(0xbbbb);
    const success_code = evmz.t.bytecode(.{ .PUSH1, 0x2a, .PUSH0, .SSTORE, .STOP });
    const revert_code = evmz.t.bytecode(.{ .PUSH1, 0x2a, .PUSH0, .SSTORE, .PUSH0, .PUSH0, .REVERT });

    {
        var executor = ShanghaiExecutor.init(std.testing.allocator, .{});
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
        var executor = ShanghaiExecutor.init(std.testing.allocator, .{});
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

    var executor = ShanghaiExecutor.init(std.testing.allocator, .{});
    defer executor.deinit();
    var account = evmz.state.MemoryAccount.init(std.testing.allocator);
    try account.setCode(&code);
    try executor.state.seedAccount(contract, account);

    var capture = evmz.executor.CaptureContext.initBounded(&capture_frame_storage, .{ .tape = &tape });
    defer capture.deinit();
    try capture.begin();
    defer if (capture.isActive()) capture.abort() catch {};

    try std.testing.expectError(
        error.TraceCapacityExceeded,
        executor.runStandaloneCapturedRequest(
            request(sender, contract),
            .{},
            &capture,
        ),
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

    var executor = CancunExecutor.init(std.testing.allocator, .{});
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
    });
    defer capture.deinit();
    try capture.begin();
    errdefer capture.abort() catch {};
    const result = try executor.runStandaloneCapturedRequest(
        request(sender, contract),
        .{},
        &capture,
    );
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

test "nested CREATE revert output survives child frame release" {
    const sender = evmz.addr(0xaaaa);
    const contract = evmz.addr(0xbbbb);
    const code = evmz.t.bytecode(.{
        // Copy the appended eight-byte initcode into memory and execute it.
        .PUSH1,          0x08,   .PUSH1,  0x13,            .PUSH0,          .CODECOPY,
        .PUSH1,          0x08,   .PUSH0,  .PUSH0,          .CREATE,         .POP,
        // Return the reverted child's payload from the parent frame.
        .RETURNDATASIZE, .PUSH0, .PUSH0,  .RETURNDATACOPY, .RETURNDATASIZE, .PUSH0,
        .RETURN,
        // Child initcode: write 0xaa, then REVERT with that one byte.
                .PUSH1, 0xaa,    .PUSH0,          .MSTORE8,        .PUSH1,
        0x01,            .PUSH0, .REVERT,
    });

    var executor = CancunExecutor.init(std.testing.allocator, .{});
    defer executor.deinit();
    var account = evmz.state.MemoryAccount.init(std.testing.allocator);
    try account.setCode(&code);
    try executor.state.seedAccount(contract, account);

    const result = (try executor.runStandaloneRequest(request(sender, contract), .{})).expectCall();
    try std.testing.expectEqual(evmz.interpreter.Status.success, result.status);
    try std.testing.expectEqualSlices(u8, &.{0xaa}, result.output_data);
    try std.testing.expect(result.output_data.ptr == executor.lastOutputData().ptr);
}

fn request(sender: evmz.Address, recipient: evmz.Address) evmz.execution.EvmExecutionRequest {
    return .{
        .context = context(sender),
        .message = .{ .call = .{
            .sender = sender,
            .recipient = recipient,
        } },
        .gas = .legacy(100_000),
    };
}

fn context(origin: evmz.Address) evmz.execution.ExecutionContext {
    return .{
        .chain = .{ .chain_id = 1 },
        .block = .{ .gas_limit = 30_000_000 },
        .transaction = .{ .origin = origin },
    };
}
