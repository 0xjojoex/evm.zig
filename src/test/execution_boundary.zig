const std = @import("std");
const evmz = @import("../evm.zig");

const trace = evmz.trace;
const transaction_runtime = @import("../transaction/runtime.zig");

test "execution resource plan and preparer have nominal root aliases" {
    try std.testing.expectEqual(evmz.execution_resources.Plan, evmz.ExecutionResourcePlan);
    try std.testing.expectEqual(evmz.execution_resources.Preparer, evmz.ExecutionResourcePreparer);
}

test "execution resource interfaces omit legacy prefetch and verify hooks" {
    try std.testing.expect(!@hasDecl(evmz.StateReader, "prefetch"));
    try std.testing.expect(!@hasDecl(evmz.ExecutionResourcePreparer, "verify"));
}

test "Executor observation boundary hides StateModel pending views" {
    const Executor = (evmz.t.Vm(.berlin) orelse return error.SkipZigTest).Executor;
    const Executed = Executor.Executed(void);

    try std.testing.expect(@hasDecl(Executor, "Observation"));
    try std.testing.expect(@hasDecl(Executed, "observation"));
    try std.testing.expect(!@hasDecl(Executed, "pendingView"));
}

test "discarding a manual state transition rolls back its mutations" {
    const BerlinExecutor = (evmz.t.Vm(.berlin) orelse return error.SkipZigTest).Executor;
    const account = evmz.addr(0xaaaa);
    var executor = BerlinExecutor.init(std.testing.allocator, .{ .state = .{} });
    defer executor.deinit();

    try executor.beginStateTransition(evmz.t.defaultExecutionContext(account, 100_000));
    try executor.addBalance(account, 7);
    try std.testing.expectEqual(@as(u256, 7), try executor.getBalance(account));

    executor.discardStateTransition();
    executor.discardStateTransition();
    try std.testing.expectEqual(@as(u256, 0), try executor.getBalance(account));
    try std.testing.expect(!executor.acceptedView().hasChanges());
}

test "execution checkpoints stay inside one stable transaction scope" {
    const BerlinExecutor = (evmz.t.Vm(.berlin) orelse return error.SkipZigTest).Executor;
    const sender = evmz.addr(0xaaaa);
    const contract = evmz.addr(0xbbbb);
    const other = evmz.addr(0xcccc);
    const reverted = evmz.addr(0xdddd);
    var executor = BerlinExecutor.init(std.testing.allocator, .{ .state = .{} });
    defer executor.deinit();

    const execution_context = evmz.t.defaultExecutionContext(sender, 100_000);
    try executor.beginTransaction(execution_context, sender, contract);
    defer executor.discardStateTransition();

    try executor.warmAccount(other);
    try executor.warmStorage(other, 1);
    var host = executor.host();
    try std.testing.expectEqual(sender, (try host.getExecutionContext()).transaction.origin);
    try std.testing.expect(executor.state.isAccountWarm(sender));
    try std.testing.expect(executor.state.isAccountWarm(contract));
    try std.testing.expect(executor.state.isAccountWarm(other));

    var checkpoint = executor.checkpoint();
    defer checkpoint.deinit();
    try executor.warmAccount(reverted);
    try executor.addBalance(reverted, 7);
    checkpoint.restore();

    try std.testing.expectEqual(sender, (try host.getExecutionContext()).transaction.origin);
    try std.testing.expect(executor.state.isAccountWarm(other));
    try std.testing.expect(!executor.state.isAccountWarm(reverted));
    try std.testing.expectEqual(@as(u256, 0), try executor.getBalance(reverted));
}

test "beginMessageScope derives root identity context and raw warmth" {
    const ShanghaiExecutor = (evmz.t.Vm(.shanghai) orelse return error.SkipZigTest).Executor;
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
    var executor = ShanghaiExecutor.init(std.testing.allocator, .{ .state = .{} });
    defer executor.deinit();
    defer executor.discardStateTransition();

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
    try std.testing.expectEqualDeep(execution_context, try host.getExecutionContext());
    try std.testing.expect(executor.state.isAccountWarm(sender));
    try std.testing.expect(executor.state.isAccountWarm(recipient));
    try std.testing.expect(!executor.state.isAccountWarm(coinbase));
    try std.testing.expect(executor.state.isAccountWarm(additional));
    try std.testing.expect(executor.state.isStorageWarm(additional, 47));
    try std.testing.expect(!executor.state.isAccountWarm(cold));

    executor.discardStateTransition();
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

test "execution checkpoint preserves family pre-scope writes" {
    const ShanghaiExecutor = (evmz.t.Vm(.shanghai) orelse return error.SkipZigTest).Executor;
    const sender = evmz.addr(0xaaaa);
    const contract = evmz.addr(0xbbbb);
    var executor = ShanghaiExecutor.init(std.testing.allocator, .{ .state = .{} });
    defer executor.deinit();

    try transaction_runtime.begin(&executor, .normal);
    defer if (executor.hasCurrentTransaction()) transaction_runtime.discard(&executor);

    // OP-style family lifecycle effect: it becomes the payload scope's state baseline.
    try executor.state.setBalance(sender, 7);
    try transaction_runtime.beginExecution(&executor, request(sender, contract), .{});

    var execution_checkpoint = executor.checkpoint();
    defer execution_checkpoint.deinit();
    try executor.state.setBalance(sender, 9);
    execution_checkpoint.restore();

    try std.testing.expectEqual(@as(u256, 7), executor.getAccount(sender).?.balance);
    const executed = ShanghaiExecutor.Executed(void){
        .executor = &executor,
        .generation = transaction_runtime.finish(&executor),
        .output_value = {},
    };
    executed.retain();
}

test "checkpoint commit retains state and restore rolls back without closing scope" {
    const BerlinExecutor = (evmz.t.Vm(.berlin) orelse return error.SkipZigTest).Executor;
    const sender = evmz.addr(0xaaaa);
    const contract = evmz.addr(0xbbbb);
    const additional = evmz.addr(0xcccc);
    const Observer = struct {
        contract: evmz.Address,
        found: bool = false,

        pub fn observe(self: *@This(), observation: BerlinExecutor.Observation) !void {
            const storage = observation.observations().storage;
            var index: u32 = 0;
            while (index < storage.len()) : (index += 1) {
                const fact = storage.at(index) orelse continue;
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
    var executor = BerlinExecutor.init(std.testing.allocator, .{ .state = .{} });
    defer executor.deinit();
    const observed = executor.observe(&observations);
    try observed.beginTransaction(
        evmz.t.defaultExecutionContext(sender, 100_000),
        sender,
        contract,
    );
    defer executor.discardStateTransition();

    var committed = executor.checkpoint();
    defer committed.deinit();
    _ = try executor.state.setStorage(contract, 7, 1);
    committed.commit();

    try std.testing.expectEqual(@as(u256, 1), try executor.getStorage(contract, 7));
    var host = executor.host();
    _ = try host.getExecutionContext();

    var reverted = executor.checkpoint();
    defer reverted.deinit();
    _ = try executor.state.setStorage(contract, 7, 2);
    try executor.state.warmAccount(additional);
    try executor.state.emitLog(.{
        .address = contract,
        .topics = &.{3},
        .data = &.{0x42},
    });
    reverted.restore();

    try std.testing.expectEqual(@as(u256, 1), try executor.getStorage(contract, 7));
    try std.testing.expect(!executor.state.isAccountWarm(additional));
    try std.testing.expectEqual(@as(usize, 0), executor.logView().len());
    _ = try host.getExecutionContext();
    try observed.retainStateTransition();
    try std.testing.expect(observations.found);
}

test "checkpoint nests LIFO and deinit restores an open token" {
    const BerlinExecutor = (evmz.t.Vm(.berlin) orelse return error.SkipZigTest).Executor;
    const sender = evmz.addr(0xaaaa);
    const contract = evmz.addr(0xbbbb);
    var executor = BerlinExecutor.init(std.testing.allocator, .{ .state = .{} });
    defer executor.deinit();
    try executor.beginTransaction(evmz.t.defaultExecutionContext(sender, 100_000), sender, contract);
    defer executor.discardStateTransition();

    {
        var outer = executor.checkpoint();
        defer outer.deinit();
        _ = try executor.state.setStorage(contract, 7, 1);

        var inner = executor.checkpoint();
        defer inner.deinit();
        _ = try executor.state.setStorage(contract, 7, 2);

        inner.restore();
        try std.testing.expectEqual(@as(u256, 1), try executor.getStorage(contract, 7));
    }

    try std.testing.expectEqual(@as(u256, 0), try executor.getStorage(contract, 7));
}

test "successive checkpoints receive distinct ids" {
    const BerlinExecutor = (evmz.t.Vm(.berlin) orelse return error.SkipZigTest).Executor;
    const sender = evmz.addr(0xaaaa);
    const contract = evmz.addr(0xbbbb);
    var executor = BerlinExecutor.init(std.testing.allocator, .{ .state = .{} });
    defer executor.deinit();
    try executor.beginTransaction(evmz.t.defaultExecutionContext(sender, 100_000), sender, contract);
    defer executor.discardStateTransition();

    var first = executor.checkpoint();
    const first_id = first.id;
    _ = try executor.state.setStorage(contract, 7, 1);
    first.commit();
    first.deinit();

    var current = executor.checkpoint();
    defer current.deinit();
    try std.testing.expect(first_id != current.id);
    _ = try executor.state.setStorage(contract, 7, 2);

    try std.testing.expectEqual(@as(u256, 2), try executor.getStorage(contract, 7));
    current.restore();
    try std.testing.expectEqual(@as(u256, 1), try executor.getStorage(contract, 7));
}

test "checkpoint revert preserves reads without retaining storage effects" {
    const AmsterdamExecutor = (evmz.t.Vm(.amsterdam) orelse return error.SkipZigTest).Executor;
    const sender = evmz.addr(0xaaaa);
    const contract = evmz.addr(0xbbbb);
    const Observer = struct {
        contract: evmz.Address,
        found: bool = false,

        pub fn observe(self: *@This(), observation: AmsterdamExecutor.Observation) !void {
            const storage = observation.observations().storage;
            var index: u32 = 0;
            while (index < storage.len()) : (index += 1) {
                const fact = storage.at(index) orelse continue;
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
    var executor = AmsterdamExecutor.init(std.testing.allocator, .{ .state = .{} });
    defer executor.deinit();
    const observed = executor.observe(&observations);
    try observed.beginTransaction(
        evmz.t.defaultExecutionContext(sender, 100_000),
        sender,
        contract,
    );
    defer executor.discardStateTransition();

    var checkpoint = executor.checkpoint();
    defer checkpoint.deinit();
    _ = try executor.state.setStorage(contract, 8, 1);
    checkpoint.restore();
    try observed.retainStateTransition();
    try std.testing.expect(observations.found);
}

test "executeStandalone owns success and revert scope lifecycles" {
    const ShanghaiExecutor = (evmz.t.Vm(.shanghai) orelse return error.SkipZigTest).Executor;
    const sender = evmz.addr(0xaaaa);
    const contract = evmz.addr(0xbbbb);
    const success_code = evmz.t.bytecode(.{ .PUSH1, 0x2a, .PUSH0, .SSTORE, .STOP });
    const revert_code = evmz.t.bytecode(.{ .PUSH1, 0x2a, .PUSH0, .SSTORE, .PUSH0, .PUSH0, .REVERT });

    {
        var executor = ShanghaiExecutor.init(std.testing.allocator, .{ .state = .{} });
        defer executor.deinit();
        try evmz.t.seedExecutorAccount(&executor, contract, .{ .code = &success_code });

        const result = (try executor.executeStandalone(request(sender, contract), .{})).expectCall();

        try std.testing.expectEqual(evmz.interpreter.Status.success, result.status());
        try std.testing.expectEqual(@as(u256, 0x2a), try executor.getStorage(contract, 0));
        try std.testing.expect(executor.execution_context == null);
    }

    {
        var executor = ShanghaiExecutor.init(std.testing.allocator, .{ .state = .{} });
        defer executor.deinit();
        try evmz.t.seedExecutorAccount(&executor, contract, .{ .code = &revert_code });

        const result = (try executor.executeStandalone(request(sender, contract), .{})).expectCall();

        try std.testing.expectEqual(evmz.interpreter.Status.revert, result.status());
        try std.testing.expectEqual(@as(u256, 0), try executor.getStorage(contract, 0));
        try std.testing.expect(executor.execution_context == null);
    }
}

test "bounded trace capture failure rolls back the standalone operation" {
    const ShanghaiExecutor = (evmz.t.CaptureVm(.shanghai) orelse return error.SkipZigTest).Executor;
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

    var executor = ShanghaiExecutor.init(std.testing.allocator, .{ .state = .{} });
    defer executor.deinit();
    try evmz.t.seedExecutorAccount(&executor, contract, .{ .code = &code });

    var capture = evmz.executor.CaptureContext.initBounded(&capture_frame_storage, .{ .tape = &tape });
    defer capture.deinit();
    try capture.begin();
    defer if (capture.isActive()) capture.abort() catch {};

    const request_value = request(sender, contract);
    try std.testing.expectError(
        error.TraceCapacityExceeded,
        executor.capture(&capture).execute(
            request_value.context,
            request_value.message,
            request_value.gas,
        ),
    );
    try std.testing.expectEqual(@as(u256, 0), try executor.getStorage(contract, 0));
    try std.testing.expect(executor.execution_context == null);

    try capture.abort();
    try std.testing.expectEqual(@as(usize, 0), tape.stepCount());
    try std.testing.expectEqual(@as(usize, 0), tape.frameCount());
}

test "captured CALL publishes return data and parent memory output after resume" {
    const CancunExecutor = (evmz.t.CaptureVm(.cancun) orelse return error.SkipZigTest).Executor;
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

    var executor = CancunExecutor.init(std.testing.allocator, .{ .state = .{} });
    defer executor.deinit();
    try evmz.t.seedExecutorAccount(&executor, contract, .{ .code = &code });
    try evmz.t.seedExecutorAccount(&executor, child, .{ .code = &child_code });

    var tape = trace.TraceTape.initGrowable(std.testing.allocator);
    defer tape.deinit();
    var capture = evmz.executor.CaptureContext.init(std.testing.allocator, .{
        .tape = &tape,
        .profile = .{ .memory = .writes },
    });
    defer capture.deinit();
    try capture.begin();
    errdefer capture.abort() catch {};
    const request_value = request(sender, contract);
    const result = try executor.capture(&capture).execute(
        request_value.context,
        request_value.message,
        request_value.gas,
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
    const CancunExecutor = (evmz.t.Vm(.cancun) orelse return error.SkipZigTest).Executor;
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

    var executor = CancunExecutor.init(std.testing.allocator, .{ .state = .{} });
    defer executor.deinit();
    try evmz.t.seedExecutorAccount(&executor, contract, .{ .code = &code });

    const result = (try executor.executeStandalone(request(sender, contract), .{})).expectCall();
    try std.testing.expectEqual(evmz.interpreter.Status.success, result.status());
    try std.testing.expectEqualSlices(u8, &.{0xaa}, result.output_data);
    try std.testing.expect(result.output_data.ptr == executor.lastOutputData().ptr);
}

fn request(sender: evmz.Address, recipient: evmz.Address) evmz.execution.EvmExecutionRequest {
    return .{
        .context = evmz.t.defaultExecutionContext(sender, 30_000_000),
        .message = .{ .call = .{
            .sender = sender,
            .recipient = recipient,
        } },
        .gas = .legacy(100_000),
    };
}
