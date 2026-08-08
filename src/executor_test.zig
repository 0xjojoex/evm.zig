//! Executor unit tests, split from `executor.zig` to keep the engine file
//! focused. Tests exercise the module-public surface plus executor-internal
//! namespaces imported directly.

const std = @import("std");

const evmz = @import("./evm.zig");
const executor_module = @import("./executor.zig");
const call_runtime = @import("./executor/call_runtime.zig");
const execution_values = @import("./execution.zig");
const trace = @import("./trace.zig");
const transaction_runtime = @import("./transaction/runtime.zig");
const uint256 = @import("./uint256.zig");
const ExactSpec = @import("./spec.zig").Spec;

const CaptureContext = executor_module.CaptureContext;
const TransactionExecutionStage = executor_module.TransactionExecutionStage;
const Address = evmz.Address;
const Host = evmz.Host;
const Interpreter = evmz.interpreter;
const TrackedState = evmz.state.TrackedState;
const prepared_code = evmz.prepared_code;
const eip7702 = executor_module.eip7702;
const ClaimPlan = @import("./eth/bal/ClaimPlan.zig").ClaimPlan;
const ParentFacts = @import("./stateless/ParentFacts.zig");

/// Standalone-message conveniences mirroring the executor's private
/// `runStandalone*` forms: explicit (context, message, gas) with default scope.
fn runStandalone(
    executor: anytype,
    context: execution_values.ExecutionContext,
    message: execution_values.Message,
    gas: execution_values.ExecutionGas,
) !Host.Result {
    return executor.executeStandalone(
        .{ .context = context, .message = message, .gas = gas },
        .{},
    );
}

fn runStandaloneObserved(
    executor: anytype,
    context: execution_values.ExecutionContext,
    message: execution_values.Message,
    gas: execution_values.ExecutionGas,
    observer: anytype,
) !Host.Result {
    return executor.observe(observer).executeStandalone(
        .{ .context = context, .message = message, .gas = gas },
        .{},
    );
}

fn beginCreateScope(
    executor: anytype,
    context: execution_values.ExecutionContext,
    create: execution_values.Create,
    gas: execution_values.ExecutionGas,
) !execution_values.EvmExecutionRequest {
    const request = execution_values.EvmExecutionRequest{
        .context = context,
        .message = .{ .create = create },
        .gas = gas,
    };
    try executor.beginMessageScope(request, .{});
    return request;
}

const testExecutionContext = evmz.t.defaultExecutionContext;

const DenseTransitionSummary = struct {
    account_changes: u32,
    storage_changes: u32,
    storage_wipes: u32,
    account_observations: u32,
    storage_observations: u32,
    introduced_code: bool,
    logs: usize,
    log_topic: u256,
    log_byte: u8,
};

const DenseTransitionObserver = struct {
    code_hash: [32]u8,
    summary: ?DenseTransitionSummary = null,

    pub fn observe(self: *@This(), observation: anytype) !void {
        const changes = observation.changes();
        const observations = observation.observations();
        const logs = observation.logs();
        self.summary = .{
            .account_changes = changes.accounts.len(),
            .storage_changes = changes.storage_writes.len(),
            .storage_wipes = changes.storage_wipes.len(),
            .account_observations = observations.accounts.len(),
            .storage_observations = observations.storage.len(),
            .introduced_code = changes.introducedCode(self.code_hash) != null,
            .logs = logs.len(),
            .log_topic = logs.get(0).topics[0],
            .log_byte = logs.get(0).data[0],
        };
    }
};

test "public executor remains bound to TrackedState" {
    const Amsterdam = evmz.t.Vm(.amsterdam) orelse return error.SkipZigTest;
    try std.testing.expect(Amsterdam.Executor.State == TrackedState);
}

test "dense Amsterdam state binds to ExecutorCore and matches checkpoint discard" {
    const Amsterdam = evmz.t.Vm(.amsterdam) orelse return error.SkipZigTest;
    const bal = @import("./eth/bal/model.zig");
    const target = evmz.addr(1);
    const storage_changes = [_]bal.StorageChange{.{ .block_access_index = 1, .new_value = 9 }};
    const slots = [_]bal.SlotChanges{.{ .slot = 7, .changes = &storage_changes }};
    const claims = [_]bal.AccountChanges{.{ .address = target, .storage_changes = &slots }};
    try bal.validate(&claims, .{ .transaction_count = 1 });
    const plan = try ClaimPlan.initAssumeValidated(std.testing.allocator, &claims);
    const account_facts = [_]ParentFacts.AccountFact{.{
        .parent = .{ .present = .{ .nonce = 1, .balance = 10 } },
    }};
    const storage_facts = [_]ParentFacts.StorageFact{.{
        .value = 3,
    }};

    var backing = evmz.state.MemoryStore.init(std.testing.allocator);
    defer backing.deinit();
    const backing_account = try backing.getOrCreateAccount(target);
    backing_account.account.nonce = 1;
    backing_account.account.balance = 10;
    try backing_account.storage.put(7, 3);

    var tracked = Amsterdam.Executor.initOwned(
        std.testing.allocator,
        Amsterdam.BlockState.initState(std.testing.allocator, backing.reader()),
        .{},
    );
    defer tracked.deinit();
    const dense_facts = try ParentFacts.initCopy(
        std.testing.allocator,
        &account_facts,
        &storage_facts,
    );
    const dense_state = try evmz.stateless.BlockState.initWithCodes(
        std.testing.allocator,
        plan,
        dense_facts,
        &.{},
    );
    const DenseEngine = @import("./vm.zig").BalStatelessVm(evmz.eth.amsterdam);
    var dense = DenseEngine.Executor.initOwned(
        std.testing.allocator,
        dense_state,
        .{},
    );
    defer dense.deinit();

    const context = testExecutionContext(target, 100_000);
    var tracked_observer = DenseTransitionObserver{ .code_hash = [_]u8{0} ** 32 };
    var dense_observer = DenseTransitionObserver{ .code_hash = [_]u8{0} ** 32 };
    const observed_tracked = tracked.observe(&tracked_observer);
    const observed_dense = dense.observe(&dense_observer);
    try observed_tracked.beginStateTransition(context);
    defer tracked.discardStateTransition();
    try observed_dense.beginStateTransition(context);
    defer dense.discardStateTransition();

    const undeclared = evmz.addr(2);
    try dense.warmAccount(undeclared);
    try dense.warmStorage(target, 8);
    try std.testing.expect(!dense.state.isAccountWarm(undeclared));
    try std.testing.expect(!dense.state.isStorageWarm(target, 8));
    try std.testing.expectError(error.UndeclaredAccount, dense.getBalance(undeclared));
    try std.testing.expectError(error.UndeclaredStorage, dense.getStorage(target, 8));
    try std.testing.expectError(error.UndeclaredAccount, dense.observeAccountAccess(undeclared));

    try std.testing.expectEqual(try tracked.getBalance(target), try dense.getBalance(target));
    try std.testing.expectEqual(try tracked.getStorage(target, 7), try dense.getStorage(target, 7));
    try tracked.addBalance(target, 5);
    try dense.addBalance(target, 5);
    try std.testing.expectEqual(try tracked.getBalance(target), try dense.getBalance(target));

    var tracked_checkpoint = tracked.checkpoint();
    defer tracked_checkpoint.deinit();
    var dense_checkpoint = dense.checkpoint();
    defer dense_checkpoint.deinit();

    const tracked_load = try tracked.state.loadStorage(target, 7);
    const dense_load = try dense.state.loadStorage(target, 7);
    try std.testing.expectEqual(tracked_load, dense_load);
    try std.testing.expectEqual(.cold, dense_load.access_status);
    try std.testing.expect(dense.state.isStorageWarm(target, 7));
    try std.testing.expectEqual(
        try tracked.state.setStorage(target, 7, 9),
        try dense.state.setStorage(target, 7, 9),
    );
    try std.testing.expectEqual(@as(u256, 9), try dense.getStorage(target, 7));

    try tracked.addBalance(target, 7);
    try dense.addBalance(target, 7);
    try std.testing.expectEqual(try tracked.getBalance(target), try dense.getBalance(target));
    tracked_checkpoint.restore();
    dense_checkpoint.restore();
    try std.testing.expectEqual(@as(u256, 15), try tracked.getBalance(target));
    try std.testing.expectEqual(try tracked.getBalance(target), try dense.getBalance(target));
    try std.testing.expectEqual(@as(u256, 3), try dense.getStorage(target, 7));
    try std.testing.expect(!dense.state.isStorageWarm(target, 7));
    try std.testing.expectEqual(.cold, (try dense.state.loadStorage(target, 7)).access_status);

    tracked.discardStateTransition();
    dense.discardStateTransition();
    try observed_tracked.beginStateTransition(context);
    try observed_dense.beginStateTransition(context);
    try std.testing.expectEqual(@as(u256, 10), try tracked.getBalance(target));
    try std.testing.expectEqual(try tracked.getBalance(target), try dense.getBalance(target));
    try std.testing.expectEqual(@as(u256, 3), try tracked.getStorage(target, 7));
    try std.testing.expectEqual(try tracked.getStorage(target, 7), try dense.getStorage(target, 7));

    const replacement_code = [_]u8{0x5f};
    const replacement_hash = evmz.crypto.keccak256(&replacement_code);
    try tracked.setCode(target, &replacement_code);
    try dense.setCode(target, &replacement_code);
    try tracked.state.setTransientStorage(target, 8, 12);
    try dense.state.setTransientStorage(target, 8, 12);
    const topics = [_]u256{7};
    const data = [_]u8{8};
    try tracked.state.emitLog(.{ .address = target, .topics = &topics, .data = &data });
    try dense.state.emitLog(.{ .address = target, .topics = &topics, .data = &data });
    _ = try tracked.state.setStorage(target, 7, 11);
    _ = try dense.state.setStorage(target, 7, 11);

    tracked_observer.code_hash = replacement_hash;
    dense_observer.code_hash = replacement_hash;
    try observed_tracked.retainStateTransition();
    try observed_dense.retainStateTransition();
    try std.testing.expectEqualDeep(tracked_observer.summary, dense_observer.summary);
    try std.testing.expectEqual(@as(usize, 1), dense.logView().len());
    const tracked_account_change = tracked.acceptedChanges().accounts.at(0);
    const dense_account_change = dense.acceptedChanges().accounts.at(0);
    try std.testing.expectEqual(tracked_account_change.address, dense_account_change.address);
    try std.testing.expectEqualDeep(tracked_account_change.account, dense_account_change.account);
    const tracked_storage_change = tracked.acceptedChanges().storage_writes.at(0);
    const dense_storage_change = dense.acceptedChanges().storage_writes.at(0);
    try std.testing.expectEqual(tracked_storage_change.address, dense_storage_change.address);
    try std.testing.expectEqual(tracked_storage_change.key, dense_storage_change.key);
    try std.testing.expectEqual(tracked_storage_change.value, dense_storage_change.value);
}

test "executor prepareBytecode eagerly analyzes jumpdests" {
    const Amsterdam = evmz.t.Vm(.amsterdam) orelse return error.SkipZigTest;
    var executor = Amsterdam.Executor.init(std.testing.allocator, .{});
    defer executor.deinit();

    const code = evmz.t.bytecode(.{ .PUSH1, .JUMPDEST, .JUMPDEST });
    var bytecode = try executor.prepareBytecode(&code);
    defer bytecode.deinit(std.testing.allocator);

    try std.testing.expect(bytecode.jumpdests.analyzed);
    try std.testing.expect(bytecode.isValidJumpDest(2));
    try std.testing.expect(!bytecode.isValidJumpDest(1));
}

test "executor executes prepared bytecode call transaction" {
    const Osaka = evmz.t.Vm(.osaka) orelse return error.SkipZigTest;
    const sender = evmz.addr(0xaaaa);
    const contract = evmz.addr(0xbbbb);
    const execution_context = testExecutionContext(sender, 100_000);
    var executor = Osaka.Executor.init(std.testing.allocator, .{});
    defer executor.deinit();

    try evmz.t.seedExecutorAccount(&executor, sender, .{ .balance = 1_000_000 });

    const code = evmz.t.bytecode(.{ .PUSH1, 0x2a, .PUSH0, .SSTORE, .STOP });
    var bytecode = try executor.prepareBytecode(&code);
    defer bytecode.deinit(std.testing.allocator);

    try executor.beginTransaction(execution_context, sender, contract);
    const result = try executor.executePreparedCallTransaction(.{
        .bytecode = bytecode.view(),
        .sender = sender,
        .recipient = contract,
        .gas = 100_000,
    });

    try std.testing.expectEqual(Interpreter.Status.success, result.status());
    try std.testing.expect(bytecode.jumpdests.analyzed);
    try std.testing.expectEqual(@as(u256, 0x2a), try executor.getStorage(contract, 0));
}

test "parent prepared view survives child admission" {
    const Osaka = evmz.t.Vm(.osaka) orelse return error.SkipZigTest;
    const sender = evmz.addr(0xaaaa);
    const contract = evmz.addr(0xbbbb);
    const target = evmz.addr(0xbeef);
    const execution_context = testExecutionContext(sender, 100_000);
    const contract_code = evmz.t.bytecode(.{
        .PUSH0, .PUSH0,  .PUSH0, .PUSH0, .PUSH0,
        .PUSH2, 0xbe,    0xef,   .GAS,   .CALL,
        .PUSH0, .SSTORE, .STOP,
    });
    const target_code = evmz.t.bytecode(.{
        .PUSH1, 0x2a,
        .PUSH0, .SSTORE,
        .STOP,
    });

    var pool = evmz.prepared_code.InMemoryPreparedPool.init(std.testing.allocator);
    defer pool.deinit();
    var executor = Osaka.Executor.init(std.testing.allocator, .{
        .prepared_code_backend = pool.backend(),
    });
    defer executor.deinit();

    try evmz.t.seedExecutorAccount(&executor, sender, .{ .balance = 1_000_000 });

    try evmz.t.seedExecutorAccount(&executor, contract, .{ .code = &contract_code });

    try evmz.t.seedExecutorAccount(&executor, target, .{ .code = &target_code });

    try executor.beginTransaction(execution_context, sender, contract);
    const first = try executor.executeCallTransaction(sender, contract, &.{}, .legacy(100_000), 0);
    executor.retainStateTransition();

    try std.testing.expectEqual(Interpreter.Status.success, first.status());
    try std.testing.expectEqual(@as(usize, 2), pool.count());
    try std.testing.expectEqual(@as(u256, 1), try executor.getStorage(contract, 0));
    try std.testing.expectEqual(@as(u256, 0x2a), try executor.getStorage(target, 0));

    try executor.beginTransaction(execution_context, sender, contract);
    const second = try executor.executeCallTransaction(sender, contract, &.{}, .legacy(100_000), 0);
    executor.retainStateTransition();

    try std.testing.expectEqual(Interpreter.Status.success, second.status());
    try std.testing.expectEqual(@as(usize, 2), pool.count());
}

test "CREATE initcode preparation remains execution-local" {
    const Osaka = evmz.t.Vm(.osaka) orelse return error.SkipZigTest;
    const sender = evmz.addr(0xaaaa);
    const execution_context = testExecutionContext(sender, 100_000);

    var pool = evmz.prepared_code.InMemoryPreparedPool.init(std.testing.allocator);
    defer pool.deinit();
    var executor = Osaka.Executor.init(std.testing.allocator, .{
        .prepared_code_backend = pool.backend(),
    });
    defer executor.deinit();

    try evmz.t.seedExecutorAccount(&executor, sender, .{ .balance = 1_000_000 });

    const request = try beginCreateScope(&executor, execution_context, .{
        .sender = sender,
        .recipient = evmz.address.create(sender, 0),
        .init_code = &.{@intFromEnum(evmz.Opcode.STOP)},
    }, .legacy(100_000));
    const result = (try executor.executeMessage(request.message, request.gas)).expectCreate();
    executor.retainStateTransition();

    try std.testing.expectEqual(Interpreter.Status.success, result.status());
    try std.testing.expectEqual(@as(usize, 0), pool.count());
}

const CacheInvalidatingTrace = struct {
    pool: *evmz.prepared_code.InMemoryPreparedPool,
    replay_cleared: bool = false,

    fn replay(self: *@This(), span: trace.TraceSpan) !void {
        var cursor = trace.TraceCursor.init(span);
        while (try cursor.next()) |event| switch (event) {
            .step_start => {
                if (self.replay_cleared) continue;
                try self.pool.clearRetainingCapacity();
                self.replay_cleared = true;
            },
            .frame_enter, .step_end, .frame_leave => {},
        };
    }
};

test "trace replay runs after prepared code leaves the live frame" {
    const Osaka = evmz.t.CaptureVm(.osaka) orelse return error.SkipZigTest;
    const sender = evmz.addr(0xaaaa);
    const contract = evmz.addr(0xbbbb);
    const code = evmz.t.bytecode(.{.STOP});

    var pool = evmz.prepared_code.InMemoryPreparedPool.init(std.testing.allocator);
    defer pool.deinit();
    var executor = Osaka.Executor.init(std.testing.allocator, .{
        .prepared_code_backend = pool.backend(),
    });
    defer executor.deinit();

    try evmz.t.seedExecutorAccount(&executor, sender, .{ .balance = 1_000_000 });

    try evmz.t.seedExecutorAccount(&executor, contract, .{ .code = &code });

    const code_view = try executor.state.getCodeView(contract);
    _ = try pool.getOrPrepare(code_view.code_hash, code_view.bytes);

    var recorder = CacheInvalidatingTrace{ .pool = &pool };
    var tape = trace.TraceTape.initGrowable(std.testing.allocator);
    defer tape.deinit();
    var capture = CaptureContext.init(std.testing.allocator, .{ .tape = &tape });
    defer capture.deinit();
    try capture.begin();
    var capture_open = true;
    defer {
        if (capture_open) capture.abort() catch {};
    }

    try executor.capture(&capture).beginTransaction(
        testExecutionContext(sender, 100_000),
        sender,
        contract,
    );
    const result = try executor.executeCallTransaction(sender, contract, &.{}, .legacy(100_000), 0);
    executor.retainStateTransition();

    const span = (try capture.finish()).?;
    capture_open = false;
    try recorder.replay(span);
    try tape.resolve(span);

    try std.testing.expectEqual(Interpreter.Status.success, result.status());
    try std.testing.expect(recorder.replay_cleared);
    try std.testing.expectEqual(@as(usize, 0), pool.count());
}

test "reset reuses caller-owned prepared artifacts through the supplied backend" {
    const Osaka = evmz.t.Vm(.osaka) orelse return error.SkipZigTest;
    const contract = evmz.addr(0xc0de);
    const code = evmz.t.bytecode(.{.STOP});
    const code_hash = evmz.crypto.keccak256(&code);

    var pool = evmz.prepared_code.InMemoryPreparedPool.init(std.testing.allocator);
    defer pool.deinit();
    var executor = Osaka.Executor.init(std.testing.allocator, .{
        .prepared_code_backend = pool.backend(),
    });
    defer executor.deinit();

    const prepared = try pool.getOrPrepare(code_hash, &code);
    try executor.reset(.{
        .prepared_code_backend = pool.backend(),
    });
    try evmz.t.seedExecutorAccount(&executor, contract, .{ .code = &code });
    try executor.beginStateTransition(testExecutionContext(contract, 100_000));
    defer executor.discardStateTransition();

    executor.beginPreparedCodeExecution();
    defer executor.endPreparedCodeExecution();
    const resolved = try call_runtime.bind(Osaka.Executor).resolveExecutionCode(&executor, contract);

    try std.testing.expectEqual(prepared.bytes.ptr, resolved.bytes.ptr);
    try std.testing.expectEqual(@as(usize, 1), pool.count());
}

test "prepared execution follows current code hash without owning public code reads" {
    const Osaka = evmz.t.Vm(.osaka) orelse return error.SkipZigTest;
    const contract = evmz.addr(0xc0de);
    const original_code = evmz.t.bytecode(.{ .PUSH0, .STOP });
    const replacement_code = evmz.t.bytecode(.{ .PUSH1, 0x2a, .STOP });

    var pool = evmz.prepared_code.InMemoryPreparedPool.init(std.testing.allocator);
    defer pool.deinit();
    var executor = Osaka.Executor.init(std.testing.allocator, .{
        .prepared_code_backend = pool.backend(),
    });
    defer executor.deinit();

    try evmz.t.seedExecutorAccount(&executor, contract, .{ .code = &original_code });
    try executor.beginStateTransition(testExecutionContext(contract, 100_000));
    defer executor.discardStateTransition();

    executor.beginPreparedCodeExecution();
    var prepared_execution_open = true;
    errdefer if (prepared_execution_open) executor.endPreparedCodeExecution();
    const original_execution = try call_runtime.bind(Osaka.Executor).resolveExecutionCode(&executor, contract);
    const original_prepared = original_execution;
    const public_original = try executor.getCode(contract);
    try std.testing.expect(original_prepared.bytes.ptr != public_original.ptr);
    try std.testing.expectEqualSlices(u8, &original_code, public_original);

    try executor.state.setCode(contract, &replacement_code);
    const replacement_execution = try call_runtime.bind(Osaka.Executor).resolveExecutionCode(&executor, contract);
    try std.testing.expect(replacement_execution.bytes.ptr != original_prepared.bytes.ptr);
    try std.testing.expectEqualSlices(u8, &replacement_code, replacement_execution.bytes);
    const public_replacement = try executor.getCode(contract);
    try std.testing.expectEqualSlices(u8, &replacement_code, public_replacement);

    executor.endPreparedCodeExecution();
    prepared_execution_open = false;
    executor.retainStateTransition();
    try pool.clearRetainingCapacity();
    try std.testing.expectEqualSlices(u8, &replacement_code, public_replacement);
    try std.testing.expectEqualSlices(u8, &replacement_code, try executor.getCode(contract));
}

test "prepared caches cannot satisfy code omitted from the active witness" {
    const Osaka = evmz.t.Vm(.osaka) orelse return error.SkipZigTest;
    const TestTrie = struct {
        fn leafNode(allocator: std.mem.Allocator, key: []const u8, value: []const u8) ![]u8 {
            const path = try allocator.alloc(u8, key.len + 1);
            path[0] = 0x20;
            @memcpy(path[1..], key);

            var payload = evmz.rlp.Writer.alloc(allocator);
            defer payload.deinit();
            try payload.bytes(path);
            try payload.bytes(value);

            var out = evmz.rlp.Writer.alloc(allocator);
            errdefer out.deinit();
            try out.listPayload(payload.written());
            return try out.toOwnedSlice();
        }
    };
    const target = evmz.addr(0x3000);
    const account_key = evmz.eth.trie.hashedAddressKey(target);

    {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const scratch = arena.allocator();
        const code = [_]u8{@intFromEnum(evmz.Opcode.STOP)};
        const code_hash = evmz.crypto.keccak256(&code);
        const account_value = try evmz.eth.trie.accountValueFrom(scratch, .{ .code_hash = code_hash });
        const state_node = try TestTrie.leafNode(scratch, &account_key, account_value);
        const nodes = [_][]const u8{state_node};
        const indexed = try evmz.eth.trie.indexNodes(scratch, &nodes);
        var witness = try evmz.stateless.WitnessReader.Indexed.init(
            scratch,
            evmz.crypto.keccak256(state_node),
            indexed,
            &.{},
        );
        defer witness.deinit();

        var pool = evmz.prepared_code.InMemoryPreparedPool.init(std.testing.allocator);
        defer pool.deinit();
        var executor = Osaka.Executor.init(std.testing.allocator, .{
            .state_reader = witness.reader(),
            .prepared_code_backend = pool.backend(),
        });
        defer executor.deinit();

        _ = try pool.getOrPrepare(code_hash, &code);
        try std.testing.expectError(
            error.InvalidWitness,
            call_runtime.bind(Osaka.Executor).resolveExecutionCode(&executor, target),
        );
    }

    {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const scratch = arena.allocator();
        const system_prepared_code = @import("./eth/system_prepared_code.zig");
        const code_hash = evmz.crypto.keccak256(&system_prepared_code.beacon_roots_code);
        const account_value = try evmz.eth.trie.accountValueFrom(scratch, .{ .code_hash = code_hash });
        const state_node = try TestTrie.leafNode(scratch, &account_key, account_value);
        const nodes = [_][]const u8{state_node};
        const indexed = try evmz.eth.trie.indexNodes(scratch, &nodes);
        var witness = try evmz.stateless.WitnessReader.Indexed.init(
            scratch,
            evmz.crypto.keccak256(state_node),
            indexed,
            &.{},
        );
        defer witness.deinit();

        var executor = Osaka.Executor.init(std.testing.allocator, .{
            .state_reader = witness.reader(),
            .prepared_code_backend = system_prepared_code.backend(),
        });
        defer executor.deinit();

        try std.testing.expectError(
            error.InvalidWitness,
            executor.executeSystemCall(
                testExecutionContext(evmz.addr(1), 100_000),
                evmz.addr(1),
                target,
                &.{},
                .legacy(100_000),
            ),
        );
    }
}

test "executor executeMessage dispatches top-level call" {
    const Osaka = evmz.t.Vm(.osaka) orelse return error.SkipZigTest;
    const sender = evmz.addr(0xaaaa);
    const contract = evmz.addr(0xbbbb);
    const execution_context = testExecutionContext(sender, 100_000);
    var executor = Osaka.Executor.init(std.testing.allocator, .{});
    defer executor.deinit();

    try evmz.t.seedExecutorAccount(&executor, sender, .{ .balance = 1_000_000 });

    try evmz.t.seedExecutorAccount(&executor, contract, .{ .code = &.{ 0x60, 0x2a, 0x5f, 0x55, 0x00 } });

    try executor.beginTransaction(execution_context, sender, contract);
    const result = (try executor.executeMessage(.{ .call = .{
        .sender = sender,
        .recipient = contract,
    } }, .legacy(100_000))).expectCall();

    try std.testing.expectEqual(Interpreter.Status.success, result.status());
    try std.testing.expectEqual(@as(u256, 0x2a), try executor.getStorage(contract, 0));
}

test "system call preserves parent stack across nested frame growth" {
    const Cancun = evmz.t.Vm(.cancun) orelse return error.SkipZigTest;
    const sender = evmz.addr(0x1111);
    const parent = evmz.addr(0xaaaa);
    const child = evmz.addr(0xbbbb);
    var executor = Cancun.Executor.init(std.testing.allocator, .{});
    defer executor.deinit();

    try evmz.t.seedExecutorAccount(&executor, parent, .{ .code = &evmz.t.bytecode(.{
        .PUSH1,  0x7b,
        .PUSH0,  .PUSH0,
        .PUSH0,  .PUSH0,
        .PUSH0,  .PUSH2,
        0xbb,    0xbb,
        .PUSH2,  0xff,
        0xff,    .CALL,
        .POP,    .PUSH0,
        .SSTORE, .STOP,
    }) });

    try evmz.t.seedExecutorAccount(&executor, child, .{ .code = &evmz.t.bytecode(.{
        .PUSH1,  0x2a,
        .PUSH1,  0x01,
        .SSTORE, .STOP,
    }) });

    const result = try executor.executeSystemCall(
        testExecutionContext(sender, 200_000),
        sender,
        parent,
        &.{},
        .legacy(200_000),
    );

    try std.testing.expectEqual(Interpreter.Status.success, result.status());
    try std.testing.expectEqual(@as(u256, 0x7b), try executor.getStorage(parent, 0));
    try std.testing.expectEqual(@as(u256, 0x2a), try executor.getStorage(child, 1));
}

test "exact spec drives call base gas" {
    if (comptime !evmz.t.forkEnabled(.frontier)) return error.SkipZigTest;
    const Frontier = evmz.t.Vm(.frontier) orelse return error.SkipZigTest;
    const ExpensiveCall = evmz.t.CustomVm(.frontier, .{
        .call = .{ .base_gas = evmz.eth.frontier.call.base_gas + 5 },
    }) orelse return error.SkipZigTest;

    const default_gas_left = try executeNestedBalanceCall(Frontier.specification);
    const custom_gas_left = try executeNestedBalanceCall(ExpensiveCall.specification);

    try std.testing.expectEqual(default_gas_left - 5, custom_gas_left);
}

test "exact spec drives top-level delegated account access" {
    const Prague = evmz.t.Vm(.prague) orelse return error.SkipZigTest;
    const overrides = struct {
        fn topLevelDelegatedAccountAccess(
            input: evmz.execution.TopLevelDelegatedAccountAccessInput,
        ) ?evmz.execution.DelegatedAccountAccess {
            _ = input;
            return .{ .status = .cold, .gas = 7 };
        }
    };
    const ExpensiveTopLevelDelegatedAccess = evmz.t.CustomVm(.prague, .{
        .call = .{ .topLevelDelegatedAccountAccess = overrides.topLevelDelegatedAccountAccess },
    }) orelse return error.SkipZigTest;

    const default_gas_left = try executeTopLevelDelegatedCall(Prague.specification);
    const custom_gas_left = try executeTopLevelDelegatedCall(ExpensiveTopLevelDelegatedAccess.specification);

    try std.testing.expectEqual(default_gas_left - 7, custom_gas_left);
}

test "top-level delegated target is a semantic account access" {
    const Amsterdam = evmz.t.Vm(.amsterdam) orelse return error.SkipZigTest;
    const sender = evmz.addr(0x1111);
    const authority = evmz.addr(0x2222);
    const target = evmz.addr(0x3333);
    const Observer = struct {
        target: Address,
        found: bool = false,

        pub fn observe(self: *@This(), observation: anytype) !void {
            const accounts = observation.observations().accounts;
            var index: u32 = 0;
            while (index < accounts.len()) : (index += 1) {
                const fact = accounts.at(index);
                if (std.mem.eql(u8, &fact.address, &self.target)) {
                    try std.testing.expect(fact.observation.semantic_access);
                    self.found = true;
                }
            }
        }
    };

    var observer = Observer{ .target = target };
    var executor = Amsterdam.Executor.init(std.testing.allocator, .{});
    defer executor.deinit();
    try putFundedSender(&executor, sender);

    var delegation_code: [eip7702.delegation_code_len]u8 = undefined;
    eip7702.writeDelegationCode(&delegation_code, target);
    try evmz.t.seedExecutorAccount(&executor, authority, .{ .code = &delegation_code });
    try evmz.t.seedExecutorAccount(&executor, target, .{ .code = &.{evmz.Opcode.STOP.toByte()} });

    const result = (try runStandaloneObserved(
        &executor,
        testExecutionContext(sender, 100_000),
        .{ .call = .{
            .sender = sender,
            .recipient = authority,
        } },
        .legacy(100_000),
        &observer,
    )).expectCall();

    try std.testing.expectEqual(Interpreter.Status.success, result.status());
    try std.testing.expect(observer.found);
}

test "delegated target is observed before insufficient call balance" {
    const Amsterdam = evmz.t.Vm(.amsterdam) orelse return error.SkipZigTest;
    const sender = evmz.addr(0x1111);
    const parent = evmz.addr(0x2222);
    const authority = evmz.addr(0x3333);
    const target = evmz.addr(0x4444);
    const Observer = struct {
        target: Address,
        found: bool = false,

        pub fn observe(self: *@This(), observation: anytype) !void {
            const accounts = observation.observations().accounts;
            var index: u32 = 0;
            while (index < accounts.len()) : (index += 1) {
                const fact = accounts.at(index);
                if (!std.mem.eql(u8, &fact.address, &self.target)) continue;
                try std.testing.expect(fact.observation.semantic_access);
                try std.testing.expect(fact.observation.code_read);
                self.found = true;
            }
        }
    };

    var observer = Observer{ .target = target };
    var executor = Amsterdam.Executor.init(std.testing.allocator, .{});
    defer executor.deinit();
    try putFundedSender(&executor, sender);

    const parent_code = evmz.t.bytecode(.{
        .PUSH0, .PUSH0, .PUSH0, .PUSH0, .PUSH1, 0x01, .PUSH2, 0x33, 0x33, .GAS, .CALL, .STOP,
    });
    var delegation_code: [eip7702.delegation_code_len]u8 = undefined;
    eip7702.writeDelegationCode(&delegation_code, target);
    try evmz.t.seedExecutorAccount(&executor, parent, .{ .code = &parent_code });
    try evmz.t.seedExecutorAccount(&executor, authority, .{ .code = &delegation_code });
    try evmz.t.seedExecutorAccount(&executor, target, .{ .code = &.{evmz.Opcode.STOP.toByte()} });

    const result = (try runStandaloneObserved(
        &executor,
        testExecutionContext(sender, 100_000),
        .{ .call = .{
            .sender = sender,
            .recipient = parent,
        } },
        .legacy(100_000),
        &observer,
    )).expectCall();

    try std.testing.expectEqual(Interpreter.Status.success, result.status());
    try std.testing.expect(observer.found);
}

test "top-level call code resolution reuses one traced view" {
    const Prague = evmz.t.Vm(.prague) orelse return error.SkipZigTest;
    const sender = evmz.addr(0x1111);
    const recipient = evmz.addr(0x2222);
    var observations = CodeObservation{
        .required = recipient,
        .expected_code_reads = 1,
    };
    var executor = Prague.Executor.init(std.testing.allocator, .{});
    defer executor.deinit();
    try putFundedSender(&executor, sender);

    try evmz.t.seedExecutorAccount(&executor, recipient, .{ .code = &.{evmz.Opcode.STOP.toByte()} });

    const result = (try runStandaloneObserved(
        &executor,
        testExecutionContext(sender, 100_000),
        .{ .call = .{
            .sender = sender,
            .recipient = recipient,
        } },
        .legacy(100_000),
        &observations,
    )).expectCall();

    try std.testing.expectEqual(Interpreter.Status.success, result.status());
    try std.testing.expectEqual(@as(usize, 1), observations.calls);
}

test "top-level delegated access failure does not read target code" {
    const overrides = struct {
        fn topLevelDelegatedAccountAccess(
            input: evmz.execution.TopLevelDelegatedAccountAccessInput,
        ) ?evmz.execution.DelegatedAccountAccess {
            _ = input;
            return .{ .status = .cold, .gas = 100_001 };
        }
    };
    const ExpensiveTopLevelDelegatedAccess = evmz.t.CustomVm(.prague, .{
        .call = .{ .topLevelDelegatedAccountAccess = overrides.topLevelDelegatedAccountAccess },
    }) orelse return error.SkipZigTest;
    const ExpensiveExecutor = ExpensiveTopLevelDelegatedAccess.Executor;
    const sender = evmz.addr(0x1111);
    const authority = evmz.addr(0x2222);
    const target = evmz.addr(0x3333);
    var observations = CodeObservation{
        .required = authority,
        .forbidden = target,
        .expected_code_reads = 1,
    };
    var executor = ExpensiveExecutor.init(std.testing.allocator, .{});
    defer executor.deinit();
    try putFundedSender(&executor, sender);

    var delegation_code: [eip7702.delegation_code_len]u8 = undefined;
    eip7702.writeDelegationCode(&delegation_code, target);
    try evmz.t.seedExecutorAccount(&executor, authority, .{ .code = &delegation_code });

    try evmz.t.seedExecutorAccount(&executor, target, .{ .code = &.{evmz.Opcode.STOP.toByte()} });

    const result = (try runStandaloneObserved(
        &executor,
        testExecutionContext(sender, 100_000),
        .{ .call = .{
            .sender = sender,
            .recipient = authority,
        } },
        .legacy(100_000),
        &observations,
    )).expectCall();

    try std.testing.expectEqual(Interpreter.Status.out_of_gas, result.status());
    try std.testing.expectEqual(@as(usize, 1), observations.calls);
}

test "exact spec drives top-frame value transfer state gas" {
    const Prague = evmz.t.Vm(.prague) orelse return error.SkipZigTest;
    const overrides = struct {
        fn topFrameValueTransferStateGas(
            input: evmz.execution.TopFrameValueTransferInput,
        ) i64 {
            return if (input.creates_account) 9 else 0;
        }
    };
    const ExpensiveTopFrameValueTransfer = evmz.t.CustomVm(.prague, .{
        .call = .{ .topFrameValueTransferStateGas = overrides.topFrameValueTransferStateGas },
    }) orelse return error.SkipZigTest;

    const default_result = try executeTopFrameValueTransfer(Prague.specification);
    const custom_result = try executeTopFrameValueTransfer(ExpensiveTopFrameValueTransfer.specification);

    try std.testing.expectEqual(default_result.gas_left - 9, custom_result.gas_left);
    try std.testing.expectEqual(@as(i64, 9), custom_result.state_gas_spent);
    try std.testing.expectEqual(@as(i64, 9), custom_result.state_gas_from_gas_left);
}

test "exact spec drives empty call recipient touching" {
    const SpuriousDragon = evmz.t.Vm(.spurious_dragon) orelse return error.SkipZigTest;
    const TouchEmptyCallRecipient = evmz.t.CustomVm(.spurious_dragon, .{
        .call = .{ .touches_empty_recipient = true },
    }) orelse return error.SkipZigTest;

    try std.testing.expect(!try emptyCallRecipientMaterialized(SpuriousDragon.specification));
    try std.testing.expect(try emptyCallRecipientMaterialized(TouchEmptyCallRecipient.specification));
}

test "exact spec drives child call gas forwarding" {
    const Frontier = evmz.t.Vm(.frontier) orelse return error.SkipZigTest;
    const overrides = struct {
        fn childGas(input: evmz.execution.ChildGasInput) evmz.execution.ChildGas {
            _ = input;
            return .{ .gas = 0 };
        }
    };
    const ZeroChildGas = evmz.t.CustomVm(.frontier, .{
        .call = .{ .childGas = overrides.childGas },
    }) orelse return error.SkipZigTest;

    try std.testing.expectEqual(@as(u256, 1), try executeCallResultStore(Frontier.specification));
    try std.testing.expectEqual(@as(u256, 0), try executeCallResultStore(ZeroChildGas.specification));
}

test "exact spec drives create initcode word gas" {
    const Cancun = evmz.t.Vm(.cancun) orelse return error.SkipZigTest;
    const overrides = struct {
        fn createInitCodeWordGas(is_create2: bool) i64 {
            _ = is_create2;
            return 1_000_000;
        }
    };
    const ExpensiveCreateInitCode = evmz.t.CustomVm(.cancun, .{
        .create = .{ .initcodeWordGas = overrides.createInitCodeWordGas },
    }) orelse return error.SkipZigTest;

    try std.testing.expectEqual(Interpreter.Status.success, try executeCreateOpcodeStatus(Cancun.specification));
    try std.testing.expectEqual(Interpreter.Status.out_of_gas, try executeCreateOpcodeStatus(ExpensiveCreateInitCode.specification));
}

fn executeCreateOpcodeStatus(comptime spec: ExactSpec) !Interpreter.Status {
    const sender = evmz.addr(0x1111);
    const contract = evmz.addr(0xaaaa);
    const code = evmz.t.bytecode(.{
        .PUSH7, 0x36,    .PUSH0, .MSTORE8, 0x60,   0x01, .PUSH0, .RETURN,
        .PUSH0, .MSTORE, .PUSH1, 0x07,     .PUSH1, 0x19, .PUSH0, .CREATE,
        .STOP,
    });

    const Exec = executor_module.ExecutorType(spec, TrackedState, .{});
    var executor = Exec.init(std.testing.allocator, .{});
    defer executor.deinit();
    try putFundedSender(&executor, sender);

    try evmz.t.seedExecutorAccount(&executor, contract, .{ .code = &code });

    return (try runStandalone(&executor, testExecutionContext(sender, 100_000), .{ .call = .{
        .sender = sender,
        .recipient = contract,
    } }, .legacy(100_000))).expectCall().status();
}

fn executeCallResultStore(comptime spec: ExactSpec) !u256 {
    const sender = evmz.addr(0x1111);
    const parent = evmz.addr(0xaaaa);
    const target = evmz.addr(0xbbbb);
    const Exec = executor_module.ExecutorType(spec, TrackedState, .{});
    var executor = Exec.init(std.testing.allocator, .{});
    defer executor.deinit();

    try putFundedSender(&executor, sender);

    try evmz.t.seedExecutorAccount(&executor, target, .{ .code = &evmz.t.bytecode(.{ .PUSH1, 0x00, .BALANCE, .STOP }) });

    const parent_code = evmz.t.bytecode(.{
        .PUSH1, 0x00,   .PUSH1, 0x00,    .PUSH1, 0x00,   .PUSH1, 0x00,
        .PUSH1, 0x00,   .PUSH2, 0xbb,    0xbb,   .PUSH2, 0xff,   0xff,
        .CALL,  .PUSH1, 0x00,   .SSTORE, .STOP,
    });
    try evmz.t.seedExecutorAccount(&executor, parent, .{ .code = &parent_code });

    const result = (try runStandalone(&executor, testExecutionContext(sender, 100_000), .{ .call = .{
        .sender = sender,
        .recipient = parent,
    } }, .legacy(100_000))).expectCall();

    try std.testing.expectEqual(Interpreter.Status.success, result.status());
    return executor.getStorage(parent, 0);
}

fn executeTopLevelDelegatedCall(comptime spec: ExactSpec) !i64 {
    const sender = evmz.addr(0x1111);
    const authority = evmz.addr(0x2222);
    const target = evmz.addr(0x3333);
    const execution_context = testExecutionContext(sender, 100_000);

    const Exec = executor_module.ExecutorType(spec, TrackedState, .{});
    var executor = Exec.init(std.testing.allocator, .{});
    defer executor.deinit();
    try putFundedSender(&executor, sender);

    var delegation_code: [eip7702.delegation_code_len]u8 = undefined;
    eip7702.writeDelegationCode(&delegation_code, target);
    try evmz.t.seedExecutorAccount(&executor, authority, .{ .code = &delegation_code });

    try evmz.t.seedExecutorAccount(&executor, target, .{ .code = &.{evmz.Opcode.STOP.toByte()} });

    const result = (try runStandalone(&executor, execution_context, .{ .call = .{
        .sender = sender,
        .recipient = authority,
    } }, .legacy(100_000))).expectCall();

    try std.testing.expectEqual(Interpreter.Status.success, result.status());
    return result.gas_left;
}

const CodeObservation = struct {
    required: Address,
    forbidden: ?Address = null,
    expected_code_reads: u32,
    calls: usize = 0,

    pub fn observe(
        self: *@This(),
        observation: anytype,
    ) !void {
        self.calls += 1;
        const view = observation.observations();
        var code_reads: u32 = 0;
        var required_found = false;
        var index: u32 = 0;
        while (index < view.accounts.len()) : (index += 1) {
            const fact = view.accounts.at(index);
            if (!fact.observation.code_read) continue;
            code_reads += 1;
            if (std.mem.eql(u8, &fact.address, &self.required)) {
                required_found = true;
            }
            if (self.forbidden) |forbidden| {
                try std.testing.expect(!std.mem.eql(u8, &fact.address, &forbidden));
            }
        }

        try std.testing.expect(required_found);
        try std.testing.expectEqual(self.expected_code_reads, code_reads);
    }
};

const TopFrameValueTransferResult = struct {
    gas_left: i64,
    state_gas_spent: i64,
    state_gas_from_gas_left: i64,
};

fn executeTopFrameValueTransfer(comptime spec: ExactSpec) !TopFrameValueTransferResult {
    const sender = evmz.addr(0x1111);
    const recipient = evmz.addr(0x2222);
    const execution_context = testExecutionContext(sender, 100_000);

    const Exec = executor_module.ExecutorType(spec, TrackedState, .{});
    var executor = Exec.init(std.testing.allocator, .{});
    defer executor.deinit();
    try putFundedSender(&executor, sender);

    const result = (try runStandalone(&executor, execution_context, .{ .call = .{
        .sender = sender,
        .recipient = recipient,
        .value = 1,
    } }, .legacy(100_000))).expectCall();

    try std.testing.expectEqual(Interpreter.Status.success, result.status());
    return .{
        .gas_left = result.gas_left,
        .state_gas_spent = result.state_gas_spent,
        .state_gas_from_gas_left = result.state_gas_from_gas_left,
    };
}

fn emptyCallRecipientMaterialized(comptime spec: ExactSpec) !bool {
    const sender = evmz.addr(0x1111);
    const contract = evmz.addr(0x2222);
    const recipient = evmz.addr(0x3333);
    const execution_context = testExecutionContext(sender, 100_000);
    const code = evmz.t.bytecode(.{
        .PUSH1, 0x00,
        .PUSH1, 0x00,
        .PUSH1, 0x00,
        .PUSH1, 0x00,
        .PUSH1, 0x00,
        .PUSH2, 0x33,
        0x33,   .PUSH2,
        0x27,   0x10,
        .CALL,  .POP,
        .STOP,
    });

    const Exec = executor_module.ExecutorType(spec, TrackedState, .{});
    var executor = Exec.init(std.testing.allocator, .{});
    defer executor.deinit();
    try putFundedSender(&executor, sender);

    try evmz.t.seedExecutorAccount(&executor, contract, .{ .code = &code });

    const result = (try runStandalone(&executor, execution_context, .{ .call = .{
        .sender = sender,
        .recipient = contract,
    } }, .legacy(100_000))).expectCall();

    try std.testing.expectEqual(Interpreter.Status.success, result.status());
    return executor.state.accountExists(recipient);
}

fn executeNestedBalanceCall(comptime spec: ExactSpec) !i64 {
    const Exec = executor_module.ExecutorType(spec, TrackedState, .{});
    const sender = evmz.addr(0x1111);
    const parent = evmz.addr(0xaaaa);
    const target = evmz.addr(0xbbbb);
    var executor = Exec.init(std.testing.allocator, .{});
    defer executor.deinit();

    try evmz.t.seedExecutorAccount(&executor, sender, .{ .balance = 1_000_000 });

    try evmz.t.seedExecutorAccount(&executor, target, .{ .code = &evmz.t.bytecode(.{ .PUSH1, 0x00, .BALANCE, .STOP }) });

    const parent_code = evmz.t.bytecode(.{
        .PUSH1, 0x00,  .PUSH1, 0x00, .PUSH1, 0x00,   .PUSH1, 0x00,
        .PUSH1, 0x00,  .PUSH2, 0xbb, 0xbb,   .PUSH2, 0xff,   0xff,
        .CALL,  .STOP,
    });
    var bytecode = try executor.prepareBytecode(&parent_code);
    defer bytecode.deinit(std.testing.allocator);

    try executor.beginTransaction(testExecutionContext(sender, 100_000), sender, parent);
    const result = try executor.executePreparedCallTransaction(.{
        .bytecode = bytecode.view(),
        .sender = sender,
        .recipient = parent,
        .gas = 100_000,
    });

    try std.testing.expectEqual(Interpreter.Status.success, result.status());
    return result.gas_left;
}

test "recursive call bomb unwinds with iterative call runtime" {
    const Cancun = evmz.t.Vm(.cancun) orelse return error.SkipZigTest;
    const sender = evmz.addr(0x371c4d94cf9ed2e0cde964a748609b7c46ec3811);
    const contract = evmz.addr(0xd83874a1c62a78b10ae86b27b59b21c4d34f6d30);
    const execution_context = testExecutionContext(sender, 1_000_000);
    var executor = Cancun.Executor.init(std.testing.allocator, .{});
    defer executor.deinit();

    try evmz.t.seedExecutorAccount(&executor, sender, .{ .balance = 1_000_000_000_000_000_000 });

    const code = evmz.t.bytecode(.{
        .PUSH1,  0x01,
        .PUSH1,  0x00,
        .SLOAD,  .ADD,
        .PUSH1,  0x00,
        .SSTORE, .PUSH1,
        0x00,    .PUSH1,
        0x00,    .PUSH1,
        0x00,    .PUSH1,
        0x00,    .PUSH1,
        0x00,    .ADDRESS,
        .PUSH1,  0xe0,
        .GAS,    .SUB,
        .CALL,   .PUSH1,
        0x01,    .SSTORE,
        .STOP,
    });
    try evmz.t.seedExecutorAccount(&executor, contract, .{ .balance = 20_000_000, .code = &code });

    var bytecode = try executor.prepareBytecode(&code);
    defer bytecode.deinit(std.testing.allocator);

    try executor.beginTransaction(execution_context, sender, contract);
    const result = try executor.executePreparedCallTransaction(.{
        .bytecode = bytecode.view(),
        .sender = sender,
        .recipient = contract,
        .gas = 979_000,
        .value = 100_000,
    });

    try std.testing.expectEqual(Interpreter.Status.success, result.status());
    try std.testing.expectEqual(@as(u256, 0x12), try executor.getStorage(contract, 0));
    try std.testing.expectEqual(@as(u256, 1), try executor.getStorage(contract, 1));
}

test "iterative call runtime preserves precompile output" {
    const Cancun = evmz.t.Vm(.cancun) orelse return error.SkipZigTest;
    const sender = evmz.addr(0x371c4d94cf9ed2e0cde964a748609b7c46ec3811);
    const contract = evmz.addr(0xd83874a1c62a78b10ae86b27b59b21c4d34f6d30);
    const execution_context = testExecutionContext(sender, 100_000);
    var executor = Cancun.Executor.init(std.testing.allocator, .{});
    defer executor.deinit();

    try evmz.t.seedExecutorAccount(&executor, sender, .{ .balance = 1_000_000_000_000_000_000 });

    const code = evmz.t.bytecode(.{
        .PUSH1,  0x2a,
        .PUSH1,  0x00,
        .MSTORE, .PUSH1,
        0x20,    .PUSH1,
        0x00,    .PUSH1,
        0x20,    .PUSH1,
        0x00,    .PUSH1,
        0x00,    .PUSH1,
        0x04,    .PUSH2,
        0x27,    0x10,
        .CALL,   .POP,
        .PUSH1,  0x20,
        .PUSH1,  0x00,
        .RETURN,
    });
    try evmz.t.seedExecutorAccount(&executor, contract, .{ .code = &code });

    var bytecode = try executor.prepareBytecode(&code);
    defer bytecode.deinit(std.testing.allocator);

    try executor.beginTransaction(execution_context, sender, contract);
    const result = try executor.executePreparedCallTransaction(.{
        .bytecode = bytecode.view(),
        .sender = sender,
        .recipient = contract,
        .gas = 90_000,
        .value = 0,
    });

    var expected: [32]u8 = .{0} ** 32;
    expected[31] = 0x2a;
    try std.testing.expectEqual(Interpreter.Status.success, result.status());
    try std.testing.expectEqualSlices(u8, &expected, result.output_data);
}

test "top-level call transaction executes precompile recipient" {
    const Cancun = evmz.t.Vm(.cancun) orelse return error.SkipZigTest;
    const sender = evmz.addr(0x371c4d94cf9ed2e0cde964a748609b7c46ec3811);
    const precompile = evmz.precompile.Contract.identity.toAddress();
    const execution_context = testExecutionContext(sender, 100_000);
    const input = [_]u8{ 0xde, 0xad };
    var executor = Cancun.Executor.init(std.testing.allocator, .{});
    defer executor.deinit();

    try evmz.t.seedExecutorAccount(&executor, sender, .{ .balance = 1_000_000 });

    try executor.beginTransaction(execution_context, sender, precompile);
    const result = try executor.executeCallTransaction(sender, precompile, &input, .legacy(1000), 7);

    try std.testing.expectEqual(Interpreter.Status.success, result.status());
    try std.testing.expectEqual(@as(i64, 982), result.gas_left);
    try std.testing.expectEqualSlices(u8, &input, result.output_data);
    try std.testing.expectEqual(@as(u256, 999_993), executor.getAccount(sender).?.balance);
    try std.testing.expectEqual(@as(u256, 7), executor.getAccount(precompile).?.balance);
}

test "legacy precompile calls materialize touched empty account until Spurious Dragon" {
    const Frontier = evmz.t.Vm(.frontier) orelse return error.SkipZigTest;
    const SpuriousDragon = evmz.t.Vm(.spurious_dragon) orelse return error.SkipZigTest;
    try expectLegacyPrecompileCall(Frontier, true, 64_922);
    try expectLegacyPrecompileCall(SpuriousDragon, false, 89_262);
}

fn expectLegacyPrecompileCall(
    comptime ExactVm: type,
    materialized: bool,
    gas_left: i64,
) !void {
    const sender = evmz.addr(0x371c4d94cf9ed2e0cde964a748609b7c46ec3811);
    const contract = evmz.addr(0xd83874a1c62a78b10ae86b27b59b21c4d34f6d30);
    const precompile = evmz.precompile.Contract.identity.toAddress();
    const code = evmz.t.bytecode(.{
        .PUSH1, 0x00,
        .PUSH1, 0x00,
        .PUSH1, 0x00,
        .PUSH1, 0x00,
        .PUSH1, 0x00,
        .PUSH1, 0x04,
        .PUSH2, 0x27,
        0x10,   .CALL,
        .POP,   .STOP,
    });
    const execution_context = testExecutionContext(sender, 100_000);
    var executor = ExactVm.Executor.init(std.testing.allocator, .{});
    defer executor.deinit();

    try evmz.t.seedExecutorAccount(&executor, sender, .{ .balance = 1_000_000_000_000_000_000 });

    try evmz.t.seedExecutorAccount(&executor, contract, .{ .code = &code });

    var bytecode = try executor.prepareBytecode(&code);
    defer bytecode.deinit(std.testing.allocator);

    try executor.beginTransaction(execution_context, sender, contract);
    const result = try executor.executePreparedCallTransaction(.{
        .bytecode = bytecode.view(),
        .sender = sender,
        .recipient = contract,
        .gas = 90_000,
        .value = 0,
    });

    try std.testing.expectEqual(Interpreter.Status.success, result.status());
    try std.testing.expectEqual(gas_left, result.gas_left);
    try std.testing.expectEqual(materialized, executor.getAccount(precompile) != null);
}

test "prepared call transaction calls to empty account succeed" {
    const Cancun = evmz.t.Vm(.cancun) orelse return error.SkipZigTest;
    const sender = evmz.addr(0x371c4d94cf9ed2e0cde964a748609b7c46ec3811);
    const contract = evmz.addr(0xd83874a1c62a78b10ae86b27b59b21c4d34f6d30);
    const execution_context = testExecutionContext(sender, 100_000);
    const code = evmz.t.bytecode(.{
        .PUSH1, 0x00,
        .PUSH1, 0x00,
        .PUSH1, 0x00,
        .PUSH1, 0x00,
        .PUSH1, 0x00,
        .PUSH2, 0x12,
        0x34,   .GAS,
        .CALL,  .PUSH1,
        0x00,   .SSTORE,
        .STOP,
    });

    var executor = Cancun.Executor.init(std.testing.allocator, .{});
    defer executor.deinit();

    try evmz.t.seedExecutorAccount(&executor, sender, .{ .balance = 1_000_000_000_000_000_000 });

    try evmz.t.seedExecutorAccount(&executor, contract, .{ .code = &code });

    var bytecode = try executor.prepareBytecode(&code);
    defer bytecode.deinit(std.testing.allocator);

    try executor.beginTransaction(execution_context, sender, contract);
    const result = try executor.executePreparedCallTransaction(.{
        .bytecode = bytecode.view(),
        .sender = sender,
        .recipient = contract,
        .gas = 90_000,
        .value = 0,
    });

    try std.testing.expectEqual(Interpreter.Status.success, result.status());
    try std.testing.expectEqual(@as(u256, 1), try executor.getStorage(contract, 0));
}

test "iterative CALLCODE writes target code in caller storage" {
    const Cancun = evmz.t.Vm(.cancun) orelse return error.SkipZigTest;
    const sender = evmz.addr(0x371c4d94cf9ed2e0cde964a748609b7c46ec3811);
    const contract = evmz.addr(0xd83874a1c62a78b10ae86b27b59b21c4d34f6d30);
    const target = evmz.addr(0xbeef);
    const execution_context = testExecutionContext(sender, 100_000);
    const code = evmz.t.bytecode(.{
        .PUSH0, .PUSH0, .PUSH0, .PUSH0, .PUSH0,
        .PUSH2, 0xbe,   0xef,   .GAS,   .CALLCODE,
        .STOP,
    });
    const target_code = evmz.t.bytecode(.{
        .PUSH1, 0xcc,
        .PUSH0, .SSTORE,
        .STOP,
    });

    var executor = Cancun.Executor.init(std.testing.allocator, .{});
    defer executor.deinit();

    try evmz.t.seedExecutorAccount(&executor, sender, .{ .balance = 1_000_000_000_000_000_000 });

    try evmz.t.seedExecutorAccount(&executor, contract, .{ .code = &code });

    try evmz.t.seedExecutorAccount(&executor, target, .{ .code = &target_code });

    var bytecode = try executor.prepareBytecode(&code);
    defer bytecode.deinit(std.testing.allocator);

    try executor.beginTransaction(execution_context, sender, contract);
    const result = try executor.executePreparedCallTransaction(.{
        .bytecode = bytecode.view(),
        .sender = sender,
        .recipient = contract,
        .gas = 120_000,
        .value = 0,
    });

    try std.testing.expectEqual(Interpreter.Status.success, result.status());
    try std.testing.expectEqual(@as(u256, 0xcc), try executor.getStorage(contract, 0));
    try std.testing.expectEqual(@as(u256, 0), try executor.getStorage(target, 0));
}

test "iterative DELEGATECALL preserves parent call value" {
    const Cancun = evmz.t.Vm(.cancun) orelse return error.SkipZigTest;
    const sender = evmz.addr(0x371c4d94cf9ed2e0cde964a748609b7c46ec3811);
    const contract = evmz.addr(0xd83874a1c62a78b10ae86b27b59b21c4d34f6d30);
    const target = evmz.addr(0xbeef);
    const execution_context = testExecutionContext(sender, 100_000);
    const code = evmz.t.bytecode(.{
        .PUSH0,        .PUSH0, .PUSH0, .PUSH0,
        .PUSH2,        0xbe,   0xef,   .GAS,
        .DELEGATECALL, .STOP,
    });
    const target_code = evmz.t.bytecode(.{
        .CALLVALUE,
        .PUSH0,
        .SSTORE,
        .STOP,
    });

    var executor = Cancun.Executor.init(std.testing.allocator, .{});
    defer executor.deinit();

    try evmz.t.seedExecutorAccount(&executor, sender, .{ .balance = 1_000_000_000_000_000_000 });

    try evmz.t.seedExecutorAccount(&executor, contract, .{ .code = &code });

    try evmz.t.seedExecutorAccount(&executor, target, .{ .code = &target_code });

    var bytecode = try executor.prepareBytecode(&code);
    defer bytecode.deinit(std.testing.allocator);

    try executor.beginTransaction(execution_context, sender, contract);
    const result = try executor.executePreparedCallTransaction(.{
        .bytecode = bytecode.view(),
        .sender = sender,
        .recipient = contract,
        .gas = 120_000,
        .value = 0x2a,
    });

    try std.testing.expectEqual(Interpreter.Status.success, result.status());
    try std.testing.expectEqual(@as(u256, 0x2a), try executor.getStorage(contract, 0));
    try std.testing.expectEqual(@as(u256, 0), try executor.getStorage(target, 0));
}

test "iterative STATICCALL failure resumes parent with zero result" {
    const Cancun = evmz.t.Vm(.cancun) orelse return error.SkipZigTest;
    const sender = evmz.addr(0x371c4d94cf9ed2e0cde964a748609b7c46ec3811);
    const contract = evmz.addr(0xd83874a1c62a78b10ae86b27b59b21c4d34f6d30);
    const target = evmz.addr(0xbeef);
    const execution_context = testExecutionContext(sender, 100_000);
    const code = evmz.t.bytecode(.{
        .PUSH0, .PUSH0,  .PUSH0,      .PUSH0,
        .PUSH2, 0xbe,    0xef,        .PUSH2,
        0x27,   0x10,    .STATICCALL, .PUSH1,
        0x01,   .SSTORE, .STOP,
    });
    const target_code = evmz.t.bytecode(.{
        .PUSH1, 0xdd,
        .PUSH0, .SSTORE,
        .STOP,
    });

    var executor = Cancun.Executor.init(std.testing.allocator, .{});
    defer executor.deinit();

    try evmz.t.seedExecutorAccount(&executor, sender, .{ .balance = 1_000_000_000_000_000_000 });

    var contract_account = evmz.state.MemoryAccount.init(std.testing.allocator);
    try contract_account.setCode(&code);
    try contract_account.storage.put(1, 0x99);
    try executor.state.seedAccount(contract, contract_account);

    try evmz.t.seedExecutorAccount(&executor, target, .{ .code = &target_code });

    var bytecode = try executor.prepareBytecode(&code);
    defer bytecode.deinit(std.testing.allocator);

    try executor.beginTransaction(execution_context, sender, contract);
    const result = try executor.executePreparedCallTransaction(.{
        .bytecode = bytecode.view(),
        .sender = sender,
        .recipient = contract,
        .gas = 120_000,
        .value = 0,
    });

    try std.testing.expectEqual(Interpreter.Status.success, result.status());
    try std.testing.expectEqual(@as(u256, 0), try executor.getStorage(contract, 1));
    try std.testing.expectEqual(@as(u256, 0), try executor.getStorage(target, 0));
}

test "prepared call transaction create opcodes deploy code" {
    const Cancun = evmz.t.Vm(.cancun) orelse return error.SkipZigTest;
    const sender = evmz.addr(0x371c4d94cf9ed2e0cde964a748609b7c46ec3811);
    const contract = evmz.addr(0xd83874a1c62a78b10ae86b27b59b21c4d34f6d30);
    const execution_context = testExecutionContext(sender, 100_000);
    const init_code = [_]u8{ 0x36, 0x5f, 0x53, 0x60, 0x01, 0x5f, 0xf3 };
    const create_address = evmz.address.create(contract, 0);
    const create2_address = evmz.address.create2(contract, 0x2a, &init_code);
    const code = evmz.t.bytecode(.{
        .PUSH7, 0x36,     .PUSH0, .MSTORE8, 0x60,    0x01,  .PUSH0, .RETURN,
        .PUSH0, .MSTORE,  .PUSH1, 0x07,     .PUSH1,  0x19,  .PUSH0, .CREATE,
        .PUSH0, .SSTORE,  .PUSH1, 0x2a,     .PUSH1,  0x07,  .PUSH1, 0x19,
        .PUSH0, .CREATE2, .PUSH1, 0x01,     .SSTORE, .STOP,
    });

    var executor = Cancun.Executor.init(std.testing.allocator, .{});
    defer executor.deinit();

    try evmz.t.seedExecutorAccount(&executor, sender, .{ .balance = 1_000_000_000_000_000_000 });

    try evmz.t.seedExecutorAccount(&executor, contract, .{ .code = &code });

    var bytecode = try executor.prepareBytecode(&code);
    defer bytecode.deinit(std.testing.allocator);

    try executor.beginTransaction(execution_context, sender, contract);
    const result = try executor.executePreparedCallTransaction(.{
        .bytecode = bytecode.view(),
        .sender = sender,
        .recipient = contract,
        .gas = 300_000,
        .value = 0,
    });

    try std.testing.expectEqual(Interpreter.Status.success, result.status());
    try std.testing.expectEqual(evmz.address.toU256(create_address), try executor.getStorage(contract, 0));
    try std.testing.expectEqual(evmz.address.toU256(create2_address), try executor.getStorage(contract, 1));
    try std.testing.expectEqualSlices(u8, &.{0x00}, try executor.getCode(create_address));
    try std.testing.expectEqualSlices(u8, &.{0x00}, try executor.getCode(create2_address));
}

test "CREATE2 insufficient balance does not bump creator nonce" {
    const Cancun = evmz.t.Vm(.cancun) orelse return error.SkipZigTest;
    const sender = evmz.addr(0x0343505c9f9bda06ff73c96183434ffd23442073);
    const contract = evmz.addr(0xbba624a7e00e22fd18816e2e0e1f4f396ce3409c);
    const execution_context = testExecutionContext(sender, 100_000);
    const create2_address = evmz.address.create2(contract, 0, &.{});
    const code = evmz.t.bytecode(.{
        .PUSH0, .PUSH0, .PUSH0, .GAS, .CREATE2, .STOP,
    });

    var executor = Cancun.Executor.init(std.testing.allocator, .{});
    defer executor.deinit();

    try evmz.t.seedExecutorAccount(&executor, sender, .{ .balance = 1_000_000 });

    try evmz.t.seedExecutorAccount(&executor, contract, .{ .nonce = 1, .code = &code });

    var bytecode = try executor.prepareBytecode(&code);
    defer bytecode.deinit(std.testing.allocator);

    try executor.beginTransaction(execution_context, sender, contract);
    const result = try executor.executePreparedCallTransaction(.{
        .bytecode = bytecode.view(),
        .sender = sender,
        .recipient = contract,
        .gas = 100_000,
        .value = 0,
    });

    try std.testing.expectEqual(Interpreter.Status.success, result.status());
    try std.testing.expectEqual(@as(u64, 1), executor.getAccount(contract).?.nonce);
    try std.testing.expect(!executor.state.isAccountWarm(create2_address));
}

test "captured runtime records nested call and create frames without generic stepping" {
    const Cancun = evmz.t.CaptureVm(.cancun) orelse return error.SkipZigTest;
    const sender = evmz.addr(0x371c4d94cf9ed2e0cde964a748609b7c46ec3811);
    const contract = evmz.addr(0xd83874a1c62a78b10ae86b27b59b21c4d34f6d30);
    const child = evmz.addr(0x1234);
    const execution_context = testExecutionContext(sender, 100_000);
    const create_address = evmz.address.create(contract, 0);
    const code = evmz.t.bytecode(.{
        .PUSH0, .PUSH0, .PUSH0,  .PUSH0, .PUSH0,  .PUSH2, 0x12,     0x34,
        .GAS,   .CALL,  .POP,    .PUSH7, 0x36,    .PUSH0, .MSTORE8, 0x60,
        0x01,   .PUSH0, .RETURN, .PUSH0, .MSTORE, .PUSH1, 0x07,     .PUSH1,
        0x19,   .PUSH0, .CREATE, .STOP,
    });

    var tape = trace.TraceTape.initGrowable(std.testing.allocator);
    defer tape.deinit();
    var capture = CaptureContext.init(std.testing.allocator, .{ .tape = &tape });
    defer capture.deinit();
    var executor = Cancun.Executor.init(std.testing.allocator, .{});
    defer executor.deinit();
    try evmz.t.seedExecutorAccount(&executor, sender, .{ .balance = 1_000_000_000_000_000_000 });

    try evmz.t.seedExecutorAccount(&executor, contract, .{ .code = &code });

    try evmz.t.seedExecutorAccount(&executor, child, .{ .code = &.{@intFromEnum(evmz.Opcode.STOP)} });

    var bytecode = try executor.prepareBytecode(&code);
    defer bytecode.deinit(std.testing.allocator);

    try capture.begin();
    errdefer capture.abort() catch {};
    try executor.capture(&capture).beginTransaction(execution_context, sender, contract);
    const result = try executor.executePreparedCallTransaction(.{
        .bytecode = bytecode.view(),
        .sender = sender,
        .recipient = contract,
        .gas = 300_000,
        .value = 0,
    });
    const span = (try capture.finish()).?;
    defer tape.resolve(span) catch unreachable;

    try std.testing.expectEqual(Interpreter.Status.success, result.status());
    try std.testing.expectEqual(@as(usize, 3), span.frames.len);
    try std.testing.expectEqual(trace.TraceFrameKind.root, span.frames[0].kind);
    try std.testing.expectEqual(@as(?u32, 0), span.frames[1].parent_frame_id);
    try std.testing.expectEqual(trace.TraceFrameKind.call, span.frames[1].kind);
    try std.testing.expectEqual(@as(?u32, 0), span.frames[2].parent_frame_id);
    try std.testing.expectEqual(trace.TraceFrameKind.create, span.frames[2].kind);
    for (span.frames) |frame_row| {
        try std.testing.expectEqual(trace.TraceFrameOutcome.success, frame_row.outcome);
    }

    var call_index: ?usize = null;
    var call_child_index: ?usize = null;
    var create_index: ?usize = null;
    var create_child_index: ?usize = null;
    for (span.steps, 0..) |step, index| {
        if (step.frame_id == 0 and step.opcode == @intFromEnum(evmz.Opcode.CALL)) call_index = index;
        if (step.frame_id == 1) call_child_index = index;
        if (step.frame_id == 0 and step.opcode == @intFromEnum(evmz.Opcode.CREATE)) create_index = index;
        if (step.frame_id == 2) create_child_index = index;
    }
    try std.testing.expect(call_index.? < call_child_index.?);
    try std.testing.expect(create_index.? < create_child_index.?);
    try std.testing.expect(span.steps[call_index.?].pc_next > span.steps[call_index.?].pc);
    try std.testing.expect(span.steps[create_index.?].pc_next > span.steps[create_index.?].pc);

    var replay = StepOrderRecorder{};
    try replay.consume(span);
    const replay_call_start = replay.firstIndex(.start, .CALL, 0).?;
    const replay_call_end = replay.firstIndex(.end, .CALL, 0).?;
    try std.testing.expect(replay.hasDepthStartBetween(1, replay_call_start, replay_call_end));
    try std.testing.expectEqual(@as(u256, 1), replay.events[replay_call_end].stack_top.?);
    const replay_create_start = replay.firstIndex(.start, .CREATE, 0).?;
    const replay_create_end = replay.firstIndex(.end, .CREATE, 0).?;
    try std.testing.expect(replay.hasDepthStartBetween(1, replay_create_start, replay_create_end));
    try std.testing.expectEqual(evmz.address.toU256(create_address), replay.events[replay_create_end].stack_top.?);
}

test "captured span is inspectable before executed transaction resolution" {
    const Osaka = evmz.t.CaptureVm(.osaka) orelse return error.SkipZigTest;
    const sender = evmz.addr(0xaaaa);
    const contract = evmz.addr(0xbbbb);
    const execution_context = testExecutionContext(sender, 100_000);
    var executor = Osaka.Executor.init(std.testing.allocator, .{});
    defer executor.deinit();

    try evmz.t.seedExecutorAccount(&executor, sender, .{ .balance = 1_000_000 });
    try evmz.t.seedExecutorAccount(&executor, contract, .{ .code = &.{ 0x60, 0x2a, 0x5f, 0x55, 0x00 } });

    var tape = trace.TraceTape.initGrowable(std.testing.allocator);
    defer tape.deinit();
    var capture = CaptureContext.init(std.testing.allocator, .{ .tape = &tape });
    defer capture.deinit();
    const request_value = execution_values.EvmExecutionRequest{
        .context = execution_context,
        .message = .{ .call = .{
            .sender = sender,
            .recipient = contract,
        } },
        .gas = .legacy(100_000),
    };
    try capture.begin();
    try transaction_runtime.begin(&executor, .{ .captured = &capture });
    errdefer transaction_runtime.discard(&executor);
    try transaction_runtime.beginExecution(&executor, request_value, .{});
    defer if (executor.hasCurrentTransaction()) transaction_runtime.discard(&executor);
    const result = try executor.executeTransactionRequest(request_value);
    try std.testing.expectEqual(Interpreter.Status.success, result.status());
    const executed = Osaka.Executor.Executed(void){
        .executor = &executor,
        .generation = transaction_runtime.finish(&executor),
        .output_value = {},
    };
    defer executed.discardIfCurrent();

    const span = (try capture.finish()).?;
    try std.testing.expect(span.steps.len > 0);
    try std.testing.expectEqual(@as(u8, @intFromEnum(evmz.Opcode.SSTORE)), span.steps[2].opcode);
    try std.testing.expectEqual(@as(u256, 0x2a), try executor.getStorage(contract, 0));

    executed.discard();
    try std.testing.expectEqual(@as(u256, 0), try executor.getStorage(contract, 0));
    try tape.resolve(span);
}

test "active transaction owns rollback before pending state" {
    const Cancun = evmz.t.Vm(.cancun) orelse return error.SkipZigTest;
    const sender = evmz.addr(0xaaaa);
    const recipient = evmz.addr(0xbbbb);
    const request = execution_values.EvmExecutionRequest{
        .context = .{
            .chain = .{ .chain_id = 1 },
            .transaction = .{ .origin = sender },
        },
        .message = .{ .call = .{
            .sender = sender,
            .recipient = recipient,
        } },
        .gas = .legacy(100_000),
    };
    var executor = Cancun.Executor.init(std.testing.allocator, .{});
    defer executor.deinit();

    try transaction_runtime.begin(&executor, .normal);
    errdefer transaction_runtime.discard(&executor);
    try transaction_runtime.beginExecution(&executor, request, .{});
    const first_generation = executor.transaction_runtime_state.?.generation;
    try executor.state.addBalance(sender, 9);
    try std.testing.expectEqual(@as(u256, 9), try executor.getBalance(sender));

    transaction_runtime.discard(&executor);
    try std.testing.expectEqual(@as(u256, 0), try executor.getBalance(sender));
    try std.testing.expect(!executor.hasCurrentTransaction());

    try transaction_runtime.begin(&executor, .normal);
    errdefer transaction_runtime.discard(&executor);
    try transaction_runtime.beginExecution(&executor, request, .{});
    defer transaction_runtime.discard(&executor);
    try std.testing.expect(first_generation != executor.transaction_runtime_state.?.generation);
}

test "active transaction finishes into pending state" {
    const Cancun = evmz.t.Vm(.cancun) orelse return error.SkipZigTest;
    const sender = evmz.addr(0xaaaa);
    const recipient = evmz.addr(0xbbbb);
    const request = execution_values.EvmExecutionRequest{
        .context = .{
            .chain = .{ .chain_id = 1 },
            .transaction = .{ .origin = sender },
        },
        .message = .{ .call = .{
            .sender = sender,
            .recipient = recipient,
        } },
        .gas = .legacy(100_000),
    };
    var executor = Cancun.Executor.init(std.testing.allocator, .{});
    defer executor.deinit();

    try transaction_runtime.begin(&executor, .normal);
    errdefer transaction_runtime.discard(&executor);
    try transaction_runtime.beginExecution(&executor, request, .{});
    try executor.state.addBalance(sender, 7);
    const executed = Cancun.Executor.Executed(void){
        .executor = &executor,
        .generation = transaction_runtime.finish(&executor),
        .output_value = {},
    };
    executed.retain();
    try std.testing.expectEqual(@as(u256, 7), try executor.getBalance(sender));
    try std.testing.expect(!executor.hasCurrentTransaction());
}

test "transaction nonce advancement survives payload rollback" {
    const Cancun = evmz.t.Vm(.cancun) orelse return error.SkipZigTest;
    const sender = evmz.addr(0xaaaa);
    const contract = evmz.addr(0xbbbb);
    const request = execution_values.EvmExecutionRequest{
        .context = .{
            .chain = .{ .chain_id = 1 },
            .transaction = .{ .origin = sender },
        },
        .message = .{ .call = .{
            .sender = sender,
            .recipient = contract,
        } },
        .gas = .legacy(100_000),
    };
    var executor = Cancun.Executor.init(std.testing.allocator, .{});
    defer executor.deinit();

    try evmz.t.seedExecutorAccount(&executor, sender, .{ .nonce = 7 });
    const revert_code = evmz.t.bytecode(.{
        .PUSH0, .PUSH0, .REVERT,
    });
    try evmz.t.seedExecutorAccount(&executor, contract, .{ .code = &revert_code });

    try transaction_runtime.begin(&executor, .normal);
    defer if (executor.hasCurrentTransaction()) transaction_runtime.discard(&executor);
    try transaction_runtime.beginExecution(&executor, request, .{});
    try executor.advanceTransactionNonce(request.message);
    const outcome = try transaction_runtime.runPayload(&executor, request);
    try std.testing.expectEqual(Interpreter.Status.revert, outcome.result.status());
    try std.testing.expectEqual(@as(u64, 8), (try executor.transactionAccountSummary(sender)).?.nonce);

    const executed = Cancun.Executor.Executed(void){
        .executor = &executor,
        .generation = transaction_runtime.finish(&executor),
        .output_value = {},
    };
    executed.retain();
    try std.testing.expectEqual(@as(u64, 8), (try executor.getAccountOrLoad(sender)).?.nonce);
}

test "transaction nonce advancement remains recorded for the runtime" {
    const Cancun = evmz.t.Vm(.cancun) orelse return error.SkipZigTest;
    const sender = evmz.addr(0xaaaa);
    const recipient = evmz.addr(0xbbbb);
    const request = execution_values.EvmExecutionRequest{
        .context = .{
            .chain = .{ .chain_id = 1 },
            .transaction = .{ .origin = sender },
        },
        .message = .{ .call = .{
            .sender = sender,
            .recipient = recipient,
        } },
        .gas = .legacy(100_000),
    };
    var executor = Cancun.Executor.init(std.testing.allocator, .{});
    defer executor.deinit();

    try evmz.t.seedExecutorAccount(&executor, sender, .{ .nonce = 7 });

    try transaction_runtime.begin(&executor, .normal);
    try transaction_runtime.beginExecution(&executor, request, .{});
    try executor.advanceTransactionNonce(request.message);
    try std.testing.expect(executor.transaction_runtime_state.?.nonce_advanced);
    try std.testing.expectEqual(@as(u64, 8), (try executor.transactionAccountSummary(sender)).?.nonce);
    transaction_runtime.discard(&executor);

    try transaction_runtime.begin(&executor, .normal);
    defer transaction_runtime.discard(&executor);
    try transaction_runtime.beginExecution(&executor, request, .{});
    try executor.advanceTransactionNonce(request.message);
    try std.testing.expectEqual(@as(u64, 8), (try executor.transactionAccountSummary(sender)).?.nonce);
}

test "transaction nonce advancement selects the root create entry" {
    const Cancun = evmz.t.Vm(.cancun) orelse return error.SkipZigTest;
    const sender = evmz.addr(0xaaaa);
    const recipient = evmz.address.create(sender, 7);
    const request = execution_values.EvmExecutionRequest{
        .context = .{
            .chain = .{ .chain_id = 1 },
            .transaction = .{ .origin = sender },
        },
        .message = .{
            .create = .{
                .sender = sender,
                .recipient = recipient,
                // PUSH0 PUSH0 RETURN deploys empty runtime code.
                .init_code = &.{ 0x5f, 0x5f, 0xf3 },
            },
        },
        .gas = .legacy(100_000),
    };
    var executor = Cancun.Executor.init(std.testing.allocator, .{});
    defer executor.deinit();

    try evmz.t.seedExecutorAccount(&executor, sender, .{ .nonce = 7 });

    try transaction_runtime.begin(&executor, .normal);
    defer if (executor.hasCurrentTransaction()) transaction_runtime.discard(&executor);
    try transaction_runtime.beginExecution(&executor, request, .{});
    try executor.advanceTransactionNonce(request.message);
    const outcome = try transaction_runtime.runPayload(&executor, request);
    try std.testing.expectEqual(Interpreter.Status.success, outcome.result.status());
    try std.testing.expectEqual(@as(u64, 8), (try executor.transactionAccountSummary(sender)).?.nonce);

    try executor.finalizeTransactionState();
    const executed = Cancun.Executor.Executed(void){
        .executor = &executor,
        .generation = transaction_runtime.finish(&executor),
        .output_value = {},
    };
    executed.retain();
    try std.testing.expectEqual(@as(u64, 8), (try executor.getAccountOrLoad(sender)).?.nonce);
}

test "transaction nonce advancement leaves max-nonce acceptance to policy" {
    const Cancun = evmz.t.Vm(.cancun) orelse return error.SkipZigTest;
    const sender = evmz.addr(0xaaaa);
    const max_nonce = std.math.maxInt(u64);
    const recipient = evmz.address.create(sender, max_nonce);
    const request = execution_values.EvmExecutionRequest{
        .context = .{
            .chain = .{ .chain_id = 1 },
            .transaction = .{ .origin = sender },
        },
        .message = .{
            .create = .{
                .sender = sender,
                .recipient = recipient,
                .init_code = &.{ 0x5f, 0x5f, 0xf3 },
            },
        },
        .gas = .legacy(100_000),
    };
    var executor = Cancun.Executor.init(std.testing.allocator, .{});
    defer executor.deinit();

    try evmz.t.seedExecutorAccount(&executor, sender, .{ .nonce = max_nonce });

    try transaction_runtime.begin(&executor, .normal);
    defer if (executor.hasCurrentTransaction()) transaction_runtime.discard(&executor);
    try transaction_runtime.beginExecution(&executor, request, .{});
    try executor.advanceTransactionNonce(request.message);
    const outcome = try transaction_runtime.runPayload(&executor, request);
    try std.testing.expectEqual(Interpreter.Status.success, outcome.result.status());
    try std.testing.expectEqual(max_nonce, (try executor.transactionAccountSummary(sender)).?.nonce);

    try executor.finalizeTransactionState();
    const executed = Cancun.Executor.Executed(void){
        .executor = &executor,
        .generation = transaction_runtime.finish(&executor),
        .output_value = {},
    };
    executed.retain();
    try std.testing.expectEqual(max_nonce, (try executor.getAccountOrLoad(sender)).?.nonce);
}

test "transaction payload resolves only its inner checkpoint" {
    const Cancun = evmz.t.Vm(.cancun) orelse return error.SkipZigTest;
    const sender = evmz.addr(0xaaaa);
    const contract = evmz.addr(0xbbbb);
    const request = execution_values.EvmExecutionRequest{
        .context = .{
            .chain = .{ .chain_id = 1 },
            .transaction = .{ .origin = sender },
        },
        .message = .{ .call = .{
            .sender = sender,
            .recipient = contract,
        } },
        .gas = .legacy(100_000),
    };

    {
        var executor = Cancun.Executor.init(std.testing.allocator, .{});
        defer executor.deinit();

        const revert_code = evmz.t.bytecode(.{
            .PUSH1, 0x2a,   .PUSH0,  .SSTORE,
            .PUSH0, .PUSH0, .REVERT,
        });
        try evmz.t.seedExecutorAccount(&executor, contract, .{ .code = &revert_code });

        try transaction_runtime.begin(&executor, .normal);
        defer if (executor.hasCurrentTransaction()) transaction_runtime.discard(&executor);
        try executor.state.addBalance(sender, 7);
        try transaction_runtime.beginExecution(&executor, request, .{});

        var preparation_checkpoint = executor.checkpoint();
        defer preparation_checkpoint.deinit();
        try executor.state.addBalance(sender, 5);

        const outcome = try transaction_runtime.runPayload(&executor, request);
        try std.testing.expectEqual(TransactionExecutionStage.payload, outcome.stage);
        try std.testing.expectEqual(Interpreter.Status.revert, outcome.result.status());
        try std.testing.expectEqual(@as(u256, 0), try executor.getStorage(contract, 0));
        try std.testing.expectEqual(@as(u256, 12), try executor.getBalance(sender));

        preparation_checkpoint.commit();
        const executed = Cancun.Executor.Executed(void){
            .executor = &executor,
            .generation = transaction_runtime.finish(&executor),
            .output_value = {},
        };
        executed.retain();
        try std.testing.expectEqual(@as(u256, 12), try executor.getBalance(sender));
    }

    {
        var executor = Cancun.Executor.init(std.testing.allocator, .{});
        defer executor.deinit();

        const success_code = evmz.t.bytecode(.{
            .PUSH1, 0x2a, .PUSH0, .SSTORE, .STOP,
        });
        try evmz.t.seedExecutorAccount(&executor, contract, .{ .code = &success_code });

        try transaction_runtime.begin(&executor, .normal);
        defer if (executor.hasCurrentTransaction()) transaction_runtime.discard(&executor);
        try executor.state.addBalance(sender, 7);
        try transaction_runtime.beginExecution(&executor, request, .{});

        const outcome = try transaction_runtime.runPayload(&executor, request);
        try std.testing.expectEqual(TransactionExecutionStage.payload, outcome.stage);
        try std.testing.expectEqual(Interpreter.Status.success, outcome.result.status());
        try std.testing.expectEqual(@as(u256, 0x2a), try executor.getStorage(contract, 0));
        try std.testing.expectEqual(@as(u256, 7), try executor.getBalance(sender));

        try executor.finalizeTransactionState();
        const executed = Cancun.Executor.Executed(void){
            .executor = &executor,
            .generation = transaction_runtime.finish(&executor),
            .output_value = {},
        };
        executed.retain();
        try std.testing.expectEqual(@as(u256, 0x2a), try executor.getStorage(contract, 0));
    }
}

test "rollback transaction restores branch checkpoint and closes execution context" {
    const Berlin = evmz.t.Vm(.berlin) orelse return error.SkipZigTest;
    const sender = evmz.addr(0xaaaa);
    const contract = evmz.addr(0xbbbb);
    const execution_context = testExecutionContext(sender, 100_000);
    var executor = Berlin.Executor.init(std.testing.allocator, .{});
    defer executor.deinit();

    try evmz.t.seedExecutorAccount(&executor, contract, .{});

    try executor.beginTransaction(execution_context, sender, contract);
    var pre_execution = try executor.branchCheckpoint();
    defer pre_execution.deinit();

    try std.testing.expectEqual(Host.StorageStatus.added, try executor.state.setStorage(contract, 7, 2));
    try std.testing.expectEqual(@as(u256, 2), try executor.getStorage(contract, 7));

    executor.rollbackTransaction(&pre_execution);

    try std.testing.expectEqual(@as(u256, 0), try executor.getStorage(contract, 7));
    try std.testing.expectEqual(@as(usize, 0), executor.state.journalEntryCount());
    try std.testing.expect(executor.execution_context == null);
}

test "executor executes top-level create transaction" {
    const Berlin = evmz.t.Vm(.berlin) orelse return error.SkipZigTest;
    const sender = evmz.addr(0xaaaa);
    const execution_context = testExecutionContext(sender, 100_000);
    var executor = Berlin.Executor.init(std.testing.allocator, .{});
    defer executor.deinit();

    try evmz.t.seedExecutorAccount(&executor, sender, .{ .balance = 1_000_000 });

    const init_code = &.{ 0x60, 0x00, 0x60, 0x00, 0x53, 0x60, 0x01, 0x60, 0x00, 0xf3 };
    const create_address = evmz.address.create(sender, 0);

    const request = try beginCreateScope(&executor, execution_context, .{
        .sender = sender,
        .recipient = create_address,
        .init_code = init_code,
    }, .legacy(100_000));
    const result = (try executor.executeMessage(request.message, request.gas)).expectCreate();

    try std.testing.expectEqual(Interpreter.Status.success, result.status());
    try std.testing.expectEqualSlices(u8, &create_address, &result.address);
    try std.testing.expectEqual(@as(u64, 1), executor.getAccount(sender).?.nonce);
    try std.testing.expectEqualSlices(u8, &.{0x00}, try executor.getCode(create_address));
}

fn expectTransferLog(event_log: Host.Log, from: Address, to: Address, amount: u256) !void {
    try std.testing.expectEqualSlices(u8, &evmz.eth.system_address, &event_log.address);
    try std.testing.expectEqual(@as(usize, 3), event_log.topics.len);
    try std.testing.expectEqual(evmz.eth.value_transfer_log_topic, event_log.topics[0]);
    try std.testing.expectEqual(evmz.address.toU256(from), event_log.topics[1]);
    try std.testing.expectEqual(evmz.address.toU256(to), event_log.topics[2]);
    try std.testing.expectEqual(@as(usize, 32), event_log.data.len);
    var expected_data: [32]u8 = undefined;
    std.mem.writeInt(u256, &expected_data, amount, .big);
    try std.testing.expectEqualSlices(u8, &expected_data, event_log.data);
}

test "Amsterdam value transaction emits transfer log" {
    const Amsterdam = evmz.t.Vm(.amsterdam) orelse return error.SkipZigTest;
    const sender = evmz.addr(0xaaaa);
    const recipient = evmz.addr(0xbbbb);
    var executor = Amsterdam.Executor.init(std.testing.allocator, .{});
    defer executor.deinit();

    try evmz.t.seedExecutorAccount(&executor, sender, .{ .balance = 1_000_000 });

    try executor.beginTransaction(testExecutionContext(sender, 100_000), sender, recipient);
    const result = try executor.executeCallTransaction(sender, recipient, &.{}, .{
        .regular_left = 50_000,
        .reservoir = evmz.eth.transaction.amsterdam_new_account_state_gas,
    }, 7);

    try std.testing.expectEqual(Interpreter.Status.success, result.status());
    try std.testing.expectEqual(@as(usize, 1), executor.logView().len());
    try expectTransferLog(executor.logView().get(0), sender, recipient, 7);
}

test "Osaka value transaction does not emit transfer log" {
    const Osaka = evmz.t.Vm(.osaka) orelse return error.SkipZigTest;
    const sender = evmz.addr(0xaaaa);
    const recipient = evmz.addr(0xbbbb);
    var executor = Osaka.Executor.init(std.testing.allocator, .{});
    defer executor.deinit();

    try evmz.t.seedExecutorAccount(&executor, sender, .{ .balance = 1_000_000 });

    try executor.beginTransaction(testExecutionContext(sender, 100_000), sender, recipient);
    const result = try executor.executeCallTransaction(sender, recipient, &.{}, .legacy(50_000), 7);

    try std.testing.expectEqual(Interpreter.Status.success, result.status());
    try std.testing.expectEqual(@as(usize, 0), executor.logView().len());
}

test "Amsterdam nested CALL transfer log rolls back on revert" {
    const Amsterdam = evmz.t.Vm(.amsterdam) orelse return error.SkipZigTest;
    const sender = evmz.addr(0xaaaa);
    const contract = evmz.addr(0xbbbb);
    const recipient = evmz.addr(0xcccc);
    const code = evmz.t.bytecode(.{
        .PUSH0, .PUSH0, .PUSH0,  .PUSH0, .PUSH1, 0x07, .PUSH2, 0xcc, 0xcc, .PUSH2, 0x27, 0x10, .CALL,
        .PUSH0, .PUSH0, .REVERT,
    });

    var executor = Amsterdam.Executor.init(std.testing.allocator, .{});
    defer executor.deinit();

    try evmz.t.seedExecutorAccount(&executor, sender, .{ .balance = 1_000_000 });

    try evmz.t.seedExecutorAccount(&executor, contract, .{ .balance = 100, .code = &code });

    const result = (try runStandalone(&executor, testExecutionContext(sender, 100_000), .{ .call = .{
        .sender = sender,
        .recipient = contract,
    } }, .{
        .regular_left = 90_000,
        .reservoir = evmz.eth.transaction.amsterdam_new_account_state_gas,
    })).expectCall();

    try std.testing.expectEqual(Interpreter.Status.revert, result.status());
    try std.testing.expectEqual(@as(usize, 0), executor.logView().len());
    try std.testing.expectEqual(@as(u256, 0), try executor.state.getBalance(recipient));
}

test "Amsterdam CREATE endowment emits transfer log" {
    const Amsterdam = evmz.t.Vm(.amsterdam) orelse return error.SkipZigTest;
    const sender = evmz.addr(0xaaaa);
    const contract = evmz.addr(0xbbbb);
    const create_address = evmz.address.create(contract, 0);
    const code = evmz.t.bytecode(.{
        .PUSH1, 0x00, .PUSH1, 0x00, .PUSH1, 0x07, .CREATE, .POP, .STOP,
    });

    var executor = Amsterdam.Executor.init(std.testing.allocator, .{});
    defer executor.deinit();

    try evmz.t.seedExecutorAccount(&executor, sender, .{ .balance = 1_000_000 });

    try evmz.t.seedExecutorAccount(&executor, contract, .{ .balance = 100, .code = &code });

    try executor.beginTransaction(testExecutionContext(sender, 100_000), sender, contract);
    const result = try executor.executeCallTransaction(sender, contract, &.{}, .{
        .regular_left = 90_000,
        .reservoir = evmz.eth.transaction.amsterdam_new_account_state_gas,
    }, 0);

    try std.testing.expectEqual(Interpreter.Status.success, result.status());
    try std.testing.expectEqual(@as(usize, 1), executor.logView().len());
    try expectTransferLog(executor.logView().get(0), contract, create_address, 7);
}

test "Amsterdam SELFDESTRUCT transfer emits transfer log" {
    const Amsterdam = evmz.t.Vm(.amsterdam) orelse return error.SkipZigTest;
    const sender = evmz.addr(0xaaaa);
    const contract = evmz.addr(0xbbbb);
    const beneficiary = evmz.addr(0xcccc);
    const code = evmz.t.bytecode(.{ .PUSH2, 0xcc, 0xcc, .SELFDESTRUCT });

    var executor = Amsterdam.Executor.init(std.testing.allocator, .{});
    defer executor.deinit();

    try evmz.t.seedExecutorAccount(&executor, sender, .{ .balance = 1_000_000 });

    try evmz.t.seedExecutorAccount(&executor, contract, .{ .balance = 7, .code = &code });

    try executor.beginTransaction(testExecutionContext(sender, 100_000), sender, contract);
    const result = try executor.executeCallTransaction(sender, contract, &.{}, .{
        .regular_left = 90_000,
        .reservoir = evmz.eth.transaction.amsterdam_new_account_state_gas,
    }, 0);

    try std.testing.expectEqual(Interpreter.Status.success, result.status());
    try std.testing.expectEqual(@as(usize, 1), executor.logView().len());
    try expectTransferLog(executor.logView().get(0), contract, beneficiary, 7);
}

fn initCodeReturningRuntimeSize(size: u32) [6]u8 {
    return .{
        evmz.Opcode.PUSH3.toByte(),
        @as(u8, @intCast(size >> 16)),
        @as(u8, @intCast((size >> 8) & 0xff)),
        @as(u8, @intCast(size & 0xff)),
        evmz.Opcode.PUSH0.toByte(),
        evmz.Opcode.RETURN.toByte(),
    };
}

fn putFundedSender(executor: anytype, sender: Address) !void {
    try evmz.t.seedExecutorAccount(executor, sender, .{ .balance = 100_000_000 });
}

test "Amsterdam raises create runtime code size limit" {
    if (comptime !evmz.t.forkEnabled(.osaka)) return error.SkipZigTest;
    const Amsterdam = evmz.t.Vm(.amsterdam) orelse return error.SkipZigTest;
    const Osaka = evmz.t.Vm(.osaka) orelse return error.SkipZigTest;
    const sender = evmz.addr(0xaaaa);
    const execution_context = testExecutionContext(sender, 20_000_000);
    const default_max_code_size = evmz.eth.osaka.create.code_size_limit.?;
    const oversized_osaka = initCodeReturningRuntimeSize(default_max_code_size + 1);
    const oversized_amsterdam = initCodeReturningRuntimeSize(evmz.eth.amsterdam.create.code_size_limit.? + 1);

    var osaka = Osaka.Executor.init(std.testing.allocator, .{});
    defer osaka.deinit();
    try putFundedSender(&osaka, sender);

    const osaka_result = (try runStandalone(&osaka, execution_context, .{ .create = .{
        .sender = sender,
        .recipient = evmz.address.create(sender, 0),
        .init_code = &oversized_osaka,
    } }, .legacy(20_000_000))).expectCreate();
    try std.testing.expectEqual(Interpreter.Status.out_of_gas, osaka_result.status());
    try std.testing.expectEqual(evmz.execution.TerminalCause.max_code_size_exceeded, osaka_result.outcome.cause);
    try std.testing.expectEqual(evmz.execution.FrameHalt.success, osaka_result.frame_halt.?);
    try std.testing.expect(osaka_result.checkpoint_reverted);

    var amsterdam = Amsterdam.Executor.init(std.testing.allocator, .{});
    defer amsterdam.deinit();
    try putFundedSender(&amsterdam, sender);

    const amsterdam_result = (try runStandalone(&amsterdam, execution_context, .{ .create = .{
        .sender = sender,
        .recipient = evmz.address.create(sender, 0),
        .init_code = &oversized_osaka,
    } }, .{
        .regular_left = 20_000_000,
        .reservoir = evmz.eth.transaction.amsterdam_new_account_state_gas + (default_max_code_size + 1) * evmz.eth.transaction.amsterdam_cost_per_state_byte,
    })).expectCreate();
    try std.testing.expectEqual(Interpreter.Status.success, amsterdam_result.status());
    try std.testing.expectEqualSlices(u8, &evmz.address.create(sender, 0), &amsterdam_result.address);
    try std.testing.expectEqual(@as(usize, default_max_code_size + 1), (try amsterdam.getCode(amsterdam_result.address)).len);

    var amsterdam_over = Amsterdam.Executor.init(std.testing.allocator, .{});
    defer amsterdam_over.deinit();
    try putFundedSender(&amsterdam_over, sender);

    const amsterdam_over_result = (try runStandalone(&amsterdam_over, execution_context, .{ .create = .{
        .sender = sender,
        .recipient = evmz.address.create(sender, 0),
        .init_code = &oversized_amsterdam,
    } }, .legacy(20_000_000))).expectCreate();
    try std.testing.expectEqual(Interpreter.Status.out_of_gas, amsterdam_over_result.status());
    try std.testing.expectEqual(evmz.execution.TerminalCause.max_code_size_exceeded, amsterdam_over_result.outcome.cause);
    try std.testing.expect(amsterdam_over_result.checkpoint_reverted);
}

test "exact spec drives create runtime code size limit" {
    const Tiny = evmz.t.CustomVm(.shanghai, .{
        .create = .{ .code_size_limit = .{ .replace = 1 } },
    }) orelse return error.SkipZigTest;
    const sender = evmz.addr(0xaaaa);
    const execution_context = testExecutionContext(sender, 100_000);
    const two_byte_runtime = initCodeReturningRuntimeSize(2);

    var executor = Tiny.Executor.init(std.testing.allocator, .{});
    defer executor.deinit();
    try putFundedSender(&executor, sender);

    const result = (try runStandalone(&executor, execution_context, .{ .create = .{
        .sender = sender,
        .recipient = evmz.address.create(sender, 0),
        .init_code = &two_byte_runtime,
    } }, .legacy(100_000))).expectCreate();
    try std.testing.expectEqual(Interpreter.Status.out_of_gas, result.status());
    try std.testing.expectEqual(evmz.execution.TerminalCause.max_code_size_exceeded, result.outcome.cause);
    try std.testing.expect(result.checkpoint_reverted);
}

test "exact spec drives create runtime prefix rejection" {
    const Shanghai = evmz.t.Vm(.shanghai) orelse return error.SkipZigTest;
    const overrides = struct {
        fn rejectsCreateCode(code: []const u8) bool {
            _ = code;
            return false;
        }
    };
    const AllowEf = evmz.t.CustomVm(.shanghai, .{
        .create = .{ .rejectsCode = overrides.rejectsCreateCode },
    }) orelse return error.SkipZigTest;
    const sender = evmz.addr(0xaaaa);
    const execution_context = testExecutionContext(sender, 100_000);
    const init_code = evmz.t.bytecode(.{
        .PUSH1, 0xef, .PUSH0, .MSTORE8,
        .PUSH1, 0x01, .PUSH0, .RETURN,
    });

    var default_executor = Shanghai.Executor.init(std.testing.allocator, .{});
    defer default_executor.deinit();
    try putFundedSender(&default_executor, sender);

    const default_result = (try runStandalone(&default_executor, execution_context, .{ .create = .{
        .sender = sender,
        .recipient = evmz.address.create(sender, 0),
        .init_code = &init_code,
    } }, .legacy(100_000))).expectCreate();
    try std.testing.expectEqual(Interpreter.Status.invalid, default_result.status());
    try std.testing.expectEqual(evmz.execution.TerminalCause.invalid_code, default_result.outcome.cause);
    try std.testing.expect(default_result.checkpoint_reverted);

    var custom_executor = AllowEf.Executor.init(std.testing.allocator, .{});
    defer custom_executor.deinit();
    try putFundedSender(&custom_executor, sender);

    const custom_result = (try runStandalone(&custom_executor, execution_context, .{ .create = .{
        .sender = sender,
        .recipient = evmz.address.create(sender, 0),
        .init_code = &init_code,
    } }, .legacy(100_000))).expectCreate();
    try std.testing.expectEqual(Interpreter.Status.success, custom_result.status());
    try std.testing.expectEqualSlices(u8, &.{0xef}, try custom_executor.getCode(custom_result.address));
}

test "exact spec drives create deposit gas" {
    const Shanghai = evmz.t.Vm(.shanghai) orelse return error.SkipZigTest;
    const overrides = struct {
        fn createDepositRegularGas(runtime_size: i64) ?i64 {
            _ = runtime_size;
            return 1_000_000;
        }
    };
    const ExpensiveDeposit = evmz.t.CustomVm(.shanghai, .{
        .create = .{ .depositRegularGas = overrides.createDepositRegularGas },
    }) orelse return error.SkipZigTest;
    const sender = evmz.addr(0xaaaa);
    const execution_context = testExecutionContext(sender, 100_000);
    const init_code = initCodeReturningRuntimeSize(1);

    var default_executor = Shanghai.Executor.init(std.testing.allocator, .{});
    defer default_executor.deinit();
    try putFundedSender(&default_executor, sender);

    const default_result = (try runStandalone(&default_executor, execution_context, .{ .create = .{
        .sender = sender,
        .recipient = evmz.address.create(sender, 0),
        .init_code = &init_code,
    } }, .legacy(100_000))).expectCreate();
    try std.testing.expectEqual(Interpreter.Status.success, default_result.status());
    try std.testing.expectEqual(@as(usize, 1), (try default_executor.getCode(default_result.address)).len);

    var custom_executor = ExpensiveDeposit.Executor.init(std.testing.allocator, .{});
    defer custom_executor.deinit();
    try putFundedSender(&custom_executor, sender);

    const custom_result = (try runStandalone(&custom_executor, execution_context, .{ .create = .{
        .sender = sender,
        .recipient = evmz.address.create(sender, 0),
        .init_code = &init_code,
    } }, .legacy(100_000))).expectCreate();
    try std.testing.expectEqual(Interpreter.Status.out_of_gas, custom_result.status());
    try std.testing.expectEqual(evmz.execution.TerminalCause.code_store_out_of_gas, custom_result.outcome.cause);
    try std.testing.expect(custom_result.checkpoint_reverted);
}

test "exact spec drives created account initial nonce" {
    const NonceSeven = evmz.t.CustomVm(.shanghai, .{
        .create = .{ .initial_nonce = 7 },
    }) orelse return error.SkipZigTest;
    const sender = evmz.addr(0xaaaa);
    const execution_context = testExecutionContext(sender, 100_000);
    const init_code = initCodeReturningRuntimeSize(1);

    var executor = NonceSeven.Executor.init(std.testing.allocator, .{});
    defer executor.deinit();
    try putFundedSender(&executor, sender);

    const result = (try runStandalone(&executor, execution_context, .{ .create = .{
        .sender = sender,
        .recipient = evmz.address.create(sender, 0),
        .init_code = &init_code,
    } }, .legacy(100_000))).expectCreate();
    try std.testing.expectEqual(Interpreter.Status.success, result.status());
    try std.testing.expectEqual(@as(u64, 7), executor.getAccount(result.address).?.nonce);
}

test "exact spec drives precompile warm access" {
    const Berlin = evmz.t.Vm(.berlin) orelse return error.SkipZigTest;
    const NoPrecompiles = struct {
        pub const Entry = evmz.eth.precompile.Entry;

        pub fn resolve(target: Address) ?Entry {
            _ = target;
            return null;
        }

        pub fn active(target: Address) bool {
            _ = target;
            return false;
        }

        pub fn execute(
            entry: Entry,
            call: evmz.execution.PrecompileCall,
        ) evmz.precompile.Error!evmz.execution.PrecompileOutcome {
            _ = entry;
            _ = call;
            return error.NotImplemented;
        }
    };
    const NoPrecompile = evmz.t.CustomVm(.berlin, .{
        .precompile = NoPrecompiles,
    }) orelse return error.SkipZigTest;
    const precompile_address = evmz.addr(0x01);

    var default_executor = Berlin.Executor.init(std.testing.allocator, .{});
    defer default_executor.deinit();
    try default_executor.beginStateTransition(testExecutionContext(precompile_address, 100_000));
    defer default_executor.discardStateTransition();
    var default_host = default_executor.host();
    try std.testing.expectEqual(Host.AccessStatus.warm, try default_host.accessAccount(precompile_address));

    var custom_executor = NoPrecompile.Executor.init(std.testing.allocator, .{});
    defer custom_executor.deinit();
    try custom_executor.beginStateTransition(testExecutionContext(precompile_address, 100_000));
    defer custom_executor.discardStateTransition();
    var custom_host = custom_executor.host();
    try std.testing.expectEqual(Host.AccessStatus.cold, try custom_host.accessAccount(precompile_address));
}

test "exact spec drives precompile execution" {
    const CustomPrecompileOverrides = struct {
        const custom_address = evmz.addr(0x1234);

        pub const Precompile = struct {
            pub const Entry = enum { custom };

            pub fn resolve(target: Address) ?Entry {
                if (!std.mem.eql(u8, &target, &custom_address)) return null;
                return .custom;
            }

            pub fn active(target: Address) bool {
                return resolve(target) != null;
            }

            pub fn execute(
                entry: Entry,
                call: evmz.execution.PrecompileCall,
            ) evmz.precompile.Error!evmz.execution.PrecompileOutcome {
                _ = entry;
                return .{ .result = .{
                    .status = .success,
                    .output_data = try call.allocator.dupe(u8, &.{0xaa}),
                    .gas_left = call.message.gas - 7,
                } };
            }
        };
    };
    const CustomPrecompile = evmz.t.CustomVm(.cancun, .{
        .precompile = CustomPrecompileOverrides.Precompile,
    }) orelse return error.SkipZigTest;
    const sender = evmz.addr(0xaaaa);
    const execution_context = testExecutionContext(sender, 100_000);

    var executor = CustomPrecompile.Executor.init(std.testing.allocator, .{});
    defer executor.deinit();
    try putFundedSender(&executor, sender);

    const result = (try runStandalone(&executor, execution_context, .{ .call = .{
        .sender = sender,
        .recipient = CustomPrecompileOverrides.custom_address,
        .input = &.{0xbb},
    } }, .legacy(1_000))).expectCall();

    try std.testing.expectEqual(Interpreter.Status.success, result.status());
    try std.testing.expectEqual(@as(i64, 993), result.gas_left);
    try std.testing.expectEqualSlices(u8, &.{0xaa}, result.output_data);
}

test "exact spec drives selfdestruct host policy" {
    const overrides = struct {
        fn selfDestructPolicy(
            input: evmz.execution.SelfDestructPolicyInput,
        ) evmz.execution.SelfDestructPolicy {
            _ = input;
            return .{
                .clear_balance = false,
                .reset_nonce = false,
                .mark_selfdestructed = false,
            };
        }
    };
    const KeepSelfDestructBalance = evmz.t.CustomVm(.cancun, .{
        .self_destruct = .{
            .policy = overrides.selfDestructPolicy,
            .refund_gas = 7,
        },
    }) orelse return error.SkipZigTest;
    const sender = evmz.addr(0xaaaa);
    const contract = evmz.addr(0xbbbb);
    const beneficiary = evmz.addr(0xcccc);
    const code = evmz.t.bytecode(.{ .PUSH2, 0xcc, 0xcc, .SELFDESTRUCT });

    var executor = KeepSelfDestructBalance.Executor.init(std.testing.allocator, .{});
    defer executor.deinit();
    try putFundedSender(&executor, sender);

    try evmz.t.seedExecutorAccount(&executor, contract, .{ .balance = 7, .code = &code });

    try evmz.t.seedExecutorAccount(&executor, beneficiary, .{});

    const result = (try runStandalone(&executor, testExecutionContext(sender, 100_000), .{ .call = .{
        .sender = sender,
        .recipient = contract,
    } }, .legacy(100_000))).expectCall();

    try std.testing.expectEqual(Interpreter.Status.success, result.status());
    try std.testing.expectEqual(@as(i64, 7), result.gas_refund);
    try std.testing.expectEqual(@as(u256, 7), executor.getAccount(contract).?.balance);
    try std.testing.expectEqual(@as(u256, 7), executor.getAccount(beneficiary).?.balance);
    try std.testing.expect(!executor.state.wasSelfdestructed(contract));
}

test "create warms created address from Berlin" {
    const Berlin = evmz.t.Vm(.berlin) orelse return error.SkipZigTest;
    const sender = evmz.addr(0xaaaa);
    const execution_context = testExecutionContext(sender, 100_000);
    var executor = Berlin.Executor.init(std.testing.allocator, .{});
    defer executor.deinit();

    try evmz.t.seedExecutorAccount(&executor, sender, .{ .balance = 1_000_000 });

    const init_code = &.{ 0x60, 0x00, 0x60, 0x00, 0xf3 };
    const create_address = evmz.address.create(sender, 0);
    const request = try beginCreateScope(&executor, execution_context, .{
        .sender = sender,
        .recipient = create_address,
        .init_code = init_code,
    }, .legacy(100_000));
    const result = (try executor.executeMessage(request.message, request.gas)).expectCreate();

    try std.testing.expectEqual(Interpreter.Status.success, result.status());
    try std.testing.expect(executor.state.isAccountWarm(create_address));
}

test "callcode with insufficient balance leaves caller storage unchanged" {
    const Berlin = evmz.t.Vm(.berlin) orelse return error.SkipZigTest;
    const caller = evmz.addr(0xaaaa);
    const target = evmz.addr(0xbbbb);
    const execution_context = testExecutionContext(caller, 100_000);
    var executor = Berlin.Executor.init(std.testing.allocator, .{});
    defer executor.deinit();

    try evmz.t.seedExecutorAccount(&executor, caller, .{ .balance = 0 });

    try evmz.t.seedExecutorAccount(&executor, target, .{ .code = &.{ 0x60, 0x11, 0x60, 0x64, 0x55, 0x00 } });

    try executor.beginTransaction(execution_context, caller, caller);
    defer executor.discardStateTransition();
    const result = (try executeHostCall(&executor, .{
        .depth = 1,
        .kind = .callcode,
        .gas = 100_000,
        .recipient = caller,
        .sender = caller,
        .input_data = &.{},
        .value = 1,
        .code_address = target,
    })).expectCall();

    try std.testing.expectEqual(Interpreter.Status.invalid, result.status());
    try std.testing.expectEqual(@as(i64, 100_000), result.gas_left);
    try std.testing.expectEqual(@as(u256, 0), try executor.getStorage(caller, 0x64));
}

test "create address collision preserves nonce and warmth outside payload rollback" {
    const Berlin = evmz.t.Vm(.berlin) orelse return error.SkipZigTest;
    const sender = evmz.addr(0xaaaa);
    const execution_context = testExecutionContext(sender, 100_000);
    var executor = Berlin.Executor.init(std.testing.allocator, .{});
    defer executor.deinit();

    try evmz.t.seedExecutorAccount(&executor, sender, .{ .balance = 1 });

    const create_address = evmz.address.create(sender, 0);
    try evmz.t.seedExecutorAccount(&executor, create_address, .{ .nonce = 1 });

    const request = try beginCreateScope(&executor, execution_context, .{
        .sender = sender,
        .recipient = create_address,
        .init_code = &.{0x00},
        .value = 1,
    }, .legacy(100_000));
    defer executor.discardStateTransition();
    const result = (try executor.executeMessage(request.message, request.gas)).expectCreate();

    try std.testing.expectEqual(Interpreter.Status.invalid, result.status());
    try std.testing.expectEqual(@as(u64, 1), executor.getAccount(sender).?.nonce);
    try std.testing.expect(executor.state.isAccountWarm(create_address));
}

test "create observes the computed address only after preflight validation" {
    // EIP-7928 includes a CREATE/CREATE2 target "only once the EVM accesses the
    // computed address". Amsterdam EELS `generic_create` aborts on the
    // balance/nonce/depth preflight before `accessed_addresses.add`, so a
    // preflight rejection must not emit a BAL access for the attempted address.
    try std.testing.expect(!try createObservesTarget(0));
    try std.testing.expect(try createObservesTarget(1));
}

fn createObservesTarget(creator_balance: u256) !bool {
    const Amsterdam = evmz.t.Vm(.amsterdam) orelse return error.SkipZigTest;
    const sender = evmz.addr(0x1111);
    const contract = evmz.addr(0xaaaa);
    const creator_nonce: u64 = 1;

    const Observer = struct {
        target: Address,
        found: bool = false,

        pub fn observe(self: *@This(), observation: anytype) !void {
            const accounts = observation.observations().accounts;
            var index: u32 = 0;
            while (index < accounts.len()) : (index += 1) {
                if (std.mem.eql(u8, &accounts.at(index).address, &self.target))
                    self.found = true;
            }
        }
    };

    var observer = Observer{ .target = evmz.address.create(contract, creator_nonce) };
    var executor = Amsterdam.Executor.init(std.testing.allocator, .{});
    defer executor.deinit();
    try putFundedSender(&executor, sender);

    // CREATE(value = 1, offset = 0, size = 0)
    const code = evmz.t.bytecode(.{
        .PUSH1, 0x00, .PUSH1, 0x00, .PUSH1, 0x01, .CREATE, .STOP,
    });
    try evmz.t.seedExecutorAccount(&executor, contract, .{
        .code = &code,
        .nonce = creator_nonce,
        .balance = creator_balance,
    });

    const result = (try runStandaloneObserved(
        &executor,
        testExecutionContext(sender, 100_000),
        .{ .call = .{ .sender = sender, .recipient = contract } },
        .{
            .regular_left = 1_000_000,
            .reservoir = evmz.eth.transaction.amsterdam_new_account_state_gas,
        },
        &observer,
    )).expectCall();

    try std.testing.expectEqual(Interpreter.Status.success, result.status());
    return observer.found;
}

test "call-like message at max depth still executes in recipient storage" {
    const Frontier = evmz.t.Vm(.frontier) orelse return error.SkipZigTest;
    const caller = evmz.addr(0xaaaa);
    const target = evmz.addr(0xbbbb);
    const execution_context = testExecutionContext(caller, 100_000);
    var executor = Frontier.Executor.init(std.testing.allocator, .{});
    defer executor.deinit();

    try evmz.t.seedExecutorAccount(&executor, caller, .{ .balance = 1_000_000 });

    try evmz.t.seedExecutorAccount(&executor, target, .{});

    inline for (.{ Host.CallKind.callcode, Host.CallKind.delegatecall }, 0..) |kind, slot| {
        try executor.beginTransaction(execution_context, caller, caller);
        try executor.state.setCode(target, &.{ 0x60, 0x2a, 0x60, @intCast(slot), 0x55, 0x00 });
        const result = (try executeHostCall(&executor, .{
            .depth = Host.max_call_depth,
            .kind = kind,
            .gas = 100_000,
            .recipient = caller,
            .sender = caller,
            .input_data = &.{},
            .value = 0,
            .code_address = target,
        })).expectCall();

        try std.testing.expectEqual(Interpreter.Status.success, result.status());
        try std.testing.expectEqual(@as(u256, 0x2a), try executor.getStorage(caller, slot));
        executor.retainStateTransition();
    }
}

test "value call at max depth returns stipend without child execution" {
    const Berlin = evmz.t.Vm(.berlin) orelse return error.SkipZigTest;
    const caller = evmz.addr(0xaaaa);
    const contract = evmz.addr(0xbbbb);
    const execution_context = testExecutionContext(caller, 100_000);
    var executor = Berlin.Executor.init(std.testing.allocator, .{});
    defer executor.deinit();

    try evmz.t.seedExecutorAccount(&executor, caller, .{ .balance = 1_000_000 });

    const code = evmz.t.bytecode(.{
        .PUSH1, 0x00,
        .PUSH1, 0x00,
        .PUSH1, 0x00,
        .PUSH1, 0x00,
        .PUSH1, 0x01,
        .PUSH2, 0xbb,
        0xbb,   .PUSH1,
        0x00,   .CALL,
        .STOP,
    });
    try evmz.t.seedExecutorAccount(&executor, contract, .{ .code = &code });

    try executor.beginTransaction(execution_context, caller, contract);
    const result = (try executeHostCall(&executor, .{
        .depth = Host.max_call_depth,
        .kind = .call,
        .gas = 100_000,
        .recipient = contract,
        .sender = caller,
        .input_data = &.{},
        .value = 0,
        .code_address = contract,
    })).expectCall();

    try std.testing.expectEqual(Interpreter.Status.success, result.status());
    try std.testing.expectEqual(@as(i64, 93_179), result.gas_left);
    try std.testing.expectEqual(@as(u256, 0), executor.getAccount(contract).?.balance);
}

test "Amsterdam value call at max depth refills new-account state gas" {
    const Amsterdam = evmz.t.Vm(.amsterdam) orelse return error.SkipZigTest;
    const caller = evmz.addr(0xaaaa);
    const contract = evmz.addr(0xbbbb);
    const recipient = evmz.addr(0xcccc);
    const execution_context = testExecutionContext(caller, 300_000);
    var executor = Amsterdam.Executor.init(std.testing.allocator, .{});
    defer executor.deinit();

    try evmz.t.seedExecutorAccount(&executor, caller, .{ .balance = 1_000_000 });

    const code = evmz.t.bytecode(.{
        .PUSH1, 0x00,
        .PUSH1, 0x00,
        .PUSH1, 0x00,
        .PUSH1, 0x00,
        .PUSH1, 0x01,
        .PUSH2, 0xcc,
        0xcc,   .PUSH2,
        0x27,   0x10,
        .CALL,  .STOP,
    });
    try evmz.t.seedExecutorAccount(&executor, contract, .{ .balance = 1, .code = &code });

    try executor.beginTransaction(execution_context, caller, contract);
    const result = (try executeHostCall(&executor, .{
        .depth = Host.max_call_depth,
        .kind = .call,
        .gas = 100_000,
        .gas_reservoir = evmz.eth.transaction.amsterdam_new_account_state_gas,
        .recipient = contract,
        .sender = caller,
        .input_data = &.{},
        .value = 0,
        .code_address = contract,
    })).expectCall();

    try std.testing.expectEqual(Interpreter.Status.success, result.status());
    try std.testing.expectEqual(@as(i64, evmz.eth.transaction.amsterdam_new_account_state_gas), result.gas_reservoir);
    try std.testing.expectEqual(@as(i64, 0), result.state_gas_spent);
    try std.testing.expect(!try executor.state.accountExists(recipient));
}

test "Amsterdam create at max depth refills new-account state gas" {
    const Amsterdam = evmz.t.Vm(.amsterdam) orelse return error.SkipZigTest;
    const caller = evmz.addr(0xaaaa);
    const contract = evmz.addr(0xbbbb);
    const execution_context = testExecutionContext(caller, 300_000);
    var executor = Amsterdam.Executor.init(std.testing.allocator, .{});
    defer executor.deinit();

    try evmz.t.seedExecutorAccount(&executor, caller, .{ .balance = 1_000_000 });

    const code = evmz.t.bytecode(.{ .PUSH0, .PUSH0, .PUSH0, .CREATE, .STOP });
    try evmz.t.seedExecutorAccount(&executor, contract, .{ .code = &code });

    try executor.beginTransaction(execution_context, caller, contract);
    const result = (try executeHostCall(&executor, .{
        .depth = Host.max_call_depth,
        .kind = .call,
        .gas = 100_000,
        .gas_reservoir = evmz.eth.transaction.amsterdam_new_account_state_gas,
        .recipient = contract,
        .sender = caller,
        .input_data = &.{},
        .value = 0,
        .code_address = contract,
    })).expectCall();

    try std.testing.expectEqual(Interpreter.Status.success, result.status());
    try std.testing.expectEqual(@as(i64, evmz.eth.transaction.amsterdam_new_account_state_gas), result.gas_reservoir);
    try std.testing.expectEqual(@as(i64, 0), result.state_gas_spent);
    try std.testing.expectEqual(@as(u64, 0), executor.getAccount(contract).?.nonce);
}

test "exceptional child call rolls back storage via checkpoint" {
    const Berlin = evmz.t.Vm(.berlin) orelse return error.SkipZigTest;
    const caller = evmz.addr(0xaaaa);
    const target = evmz.addr(0xbbbb);
    const execution_context = testExecutionContext(caller, 100_000);
    var executor = Berlin.Executor.init(std.testing.allocator, .{});
    defer executor.deinit();

    try evmz.t.seedExecutorAccount(&executor, caller, .{ .balance = 1_000_000 });

    try evmz.t.seedExecutorAccount(&executor, target, .{ .code = &.{ 0x60, 0x11, 0x60, 0x64, 0x55, 0xfe } });

    try executor.beginTransaction(execution_context, caller, caller);
    const result = (try executeHostCall(&executor, .{
        .depth = 1,
        .kind = .call,
        .gas = 100_000,
        .recipient = target,
        .sender = caller,
        .input_data = &.{},
        .value = 0,
        .code_address = target,
    })).expectCall();

    try std.testing.expectEqual(Interpreter.Status.invalid, result.status());
    try std.testing.expectEqual(@as(i64, 0), result.gas_left);
    try std.testing.expectEqual(@as(u256, 0), try executor.state.getStorage(target, 0x64));
}

test "contract creation rejects EF-prefixed runtime code from London" {
    const London = evmz.t.Vm(.london) orelse return error.SkipZigTest;
    const sender = evmz.addr(0xaaaa);
    const execution_context = testExecutionContext(sender, 100_000);
    var executor = London.Executor.init(std.testing.allocator, .{});
    defer executor.deinit();

    try evmz.t.seedExecutorAccount(&executor, sender, .{ .balance = 1_000_000 });

    const init_code = &.{ 0x60, 0xef, 0x60, 0x00, 0x53, 0x60, 0x10, 0x60, 0x00, 0xf3 };
    const create_address = evmz.address.create(sender, 0);
    const request = try beginCreateScope(&executor, execution_context, .{
        .sender = sender,
        .recipient = create_address,
        .init_code = init_code,
    }, .legacy(100_000));
    const result = (try executor.executeMessage(request.message, request.gas)).expectCreate();

    try std.testing.expectEqual(Interpreter.Status.invalid, result.status());
    try std.testing.expectEqual(@as(i64, 0), result.gas_left);
    try std.testing.expectEqual(@as(u64, 1), executor.getAccount(sender).?.nonce);
    try std.testing.expect(executor.getAccount(create_address) == null);
    try std.testing.expect(executor.state.isAccountWarm(create_address));
}

test "selfdestruct charges new-account cost for nonzero balance" {
    const Cancun = evmz.t.Vm(.cancun) orelse return error.SkipZigTest;
    const sender = evmz.addr(0xaaaa);
    const contract = evmz.addr(0xbbbb);
    const execution_context = testExecutionContext(sender, 100_000);
    var executor = Cancun.Executor.init(std.testing.allocator, .{});
    defer executor.deinit();

    try evmz.t.seedExecutorAccount(&executor, sender, .{ .balance = 1_000_000 });

    try evmz.t.seedExecutorAccount(&executor, contract, .{ .balance = 1, .code = &.{ 0x5f, 0xff } });

    try executor.beginTransaction(execution_context, sender, contract);
    const result = try executor.executeCallTransaction(sender, contract, &.{}, .legacy(100_000), 0);

    try std.testing.expectEqual(Interpreter.Status.success, result.status());
    // Raw message scope omits family semantics: the zero beneficiary is cold
    // unless the transaction program supplies Ethereum's coinbase warm-up.
    try std.testing.expectEqual(@as(i64, 67_398), result.gas_left);
}

test "TangerineWhistle selfdestruct charges new-account cost without balance transfer" {
    const SpuriousDragon = evmz.t.Vm(.spurious_dragon) orelse return error.SkipZigTest;
    const TangerineWhistle = evmz.t.Vm(.tangerine_whistle) orelse return error.SkipZigTest;
    try expectEmptySelfDestructGas(TangerineWhistle, 69_997);
    try expectEmptySelfDestructGas(SpuriousDragon, 94_997);
}

fn expectEmptySelfDestructGas(comptime ExactVm: type, expected_gas_left: i64) !void {
    const sender = evmz.addr(0xaaaa);
    const contract = evmz.addr(0xbbbb);
    const code = evmz.t.bytecode(.{ .PUSH1, 0x00, .SELFDESTRUCT });
    const execution_context = testExecutionContext(sender, 100_000);
    var executor = ExactVm.Executor.init(std.testing.allocator, .{});
    defer executor.deinit();

    try evmz.t.seedExecutorAccount(&executor, sender, .{ .balance = 1_000_000 });

    try evmz.t.seedExecutorAccount(&executor, contract, .{ .code = &code });

    try executor.beginTransaction(execution_context, sender, contract);
    const result = try executor.executeCallTransaction(sender, contract, &.{}, .legacy(100_000), 0);

    try std.testing.expectEqual(Interpreter.Status.success, result.status());
    try std.testing.expectEqual(expected_gas_left, result.gas_left);
}

test "SELFDESTRUCT refund is removed at London" {
    const Berlin = evmz.t.Vm(.berlin) orelse return error.SkipZigTest;
    const London = evmz.t.Vm(.london) orelse return error.SkipZigTest;
    try expectSelfDestructRefund(Berlin, 24_000);
    try expectSelfDestructRefund(London, 0);
}

fn expectSelfDestructRefund(comptime ExactVm: type, expected_refund: i64) !void {
    const sender = evmz.addr(0xaaaa);
    const contract = evmz.addr(0xbbbb);
    const code = evmz.t.bytecode(.{ .PUSH1, 0x00, .SELFDESTRUCT });
    const execution_context = testExecutionContext(sender, 100_000);
    var executor = ExactVm.Executor.init(std.testing.allocator, .{});
    defer executor.deinit();

    try evmz.t.seedExecutorAccount(&executor, sender, .{ .balance = 1_000_000 });

    try evmz.t.seedExecutorAccount(&executor, contract, .{ .code = &code });

    try executor.beginTransaction(execution_context, sender, contract);
    const result = try executor.executeCallTransaction(sender, contract, &.{}, .legacy(100_000), 0);

    try std.testing.expectEqual(Interpreter.Status.success, result.status());
    try std.testing.expectEqual(expected_refund, result.gas_refund);
}

test "active precompiles are warm but not existing state accounts" {
    const Berlin = evmz.t.Vm(.berlin) orelse return error.SkipZigTest;
    const precompile_address = evmz.addr(2);
    var executor = Berlin.Executor.init(std.testing.allocator, .{});
    defer executor.deinit();

    var host_iface = executor.host();
    try std.testing.expect(!try host_iface.accountExists(precompile_address));
    try std.testing.expectEqual(Host.AccessStatus.warm, try host_iface.accessAccount(precompile_address));
    try std.testing.expectEqual(@as(u256, 0), try host_iface.getCodeHash(precompile_address));

    // Alive, so the address is a real state account: an EIP-161-empty one is
    // dead and would still report zero.
    try evmz.t.seedExecutorAccount(&executor, precompile_address, .{ .balance = 1 });
    try std.testing.expectEqual(uint256.fromBytes32(&evmz.crypto.keccak256_empty), try host_iface.getCodeHash(precompile_address));
}

test "delegated precompile targets are warm" {
    const Amsterdam = evmz.t.Vm(.amsterdam) orelse return error.SkipZigTest;
    const Prague = evmz.t.Vm(.prague) orelse return error.SkipZigTest;
    try expectDelegatedPrecompileWarm(Prague);
    try expectDelegatedPrecompileWarm(Amsterdam);
}

fn expectDelegatedPrecompileWarm(comptime ExactVm: type) !void {
    const authority = evmz.addr(0xbbbb);
    const precompile_address = evmz.addr(2);
    var executor = ExactVm.Executor.init(std.testing.allocator, .{});
    defer executor.deinit();

    var code: [eip7702.delegation_code_len]u8 = undefined;
    eip7702.writeDelegationCode(&code, precompile_address);
    try evmz.t.seedExecutorAccount(&executor, authority, .{ .code = &code });

    var host_iface = executor.host();
    try std.testing.expectEqual(Host.AccessStatus.warm, (try host_iface.accessDelegatedAccount(authority)).?);
}

test "sealed observations expose storage state without a trace tape" {
    const Berlin = evmz.t.Vm(.berlin) orelse return error.SkipZigTest;
    const sender = evmz.addr(0xaaaa);
    const contract = evmz.addr(0xbbbb);
    const execution_context = testExecutionContext(sender, 100_000);

    const StorageObserver = struct {
        address: Address,
        key: u256,
        expected: u256,
        calls: usize = 0,

        pub fn observe(self: *@This(), observation: anytype) !void {
            self.calls += 1;
            const storage = observation.observations().storage;
            var index: u32 = 0;
            while (index < storage.len()) : (index += 1) {
                const fact = storage.at(index) orelse continue;
                if (!std.mem.eql(u8, &fact.address, &self.address) or fact.key != self.key) continue;
                try std.testing.expect(fact.observation.value_read);
                try std.testing.expect(fact.effect.written);
                try std.testing.expectEqual(@as(u256, 0), fact.original);
                try std.testing.expectEqual(self.expected, fact.current);
                return;
            }
            return error.ExpectedStorageObservationMissing;
        }
    };
    var observations = StorageObserver{
        .address = contract,
        .key = 0,
        .expected = 42,
    };
    var executor = Berlin.Executor.init(std.testing.allocator, .{});
    defer executor.deinit();

    try evmz.t.seedExecutorAccount(&executor, sender, .{ .balance = 1_000_000 });

    try evmz.t.seedExecutorAccount(&executor, contract, .{
        .code = &.{
            0x60, 0x2a, // PUSH1 42
            0x60, 0x00, // PUSH1 0
            0x55, // SSTORE
            0x00, // STOP
        },
    });
    const observed = executor.observe(&observations);
    try observed.beginTransaction(execution_context, sender, contract);
    defer executor.discardStateTransition();
    const result = try executor.executeCallTransaction(sender, contract, &.{}, .legacy(100_000), 0);
    try observed.retainStateTransition();

    try std.testing.expectEqual(Interpreter.Status.success, result.status());
    try std.testing.expectEqual(@as(usize, 1), observations.calls);
}

const StepEventKind = enum {
    start,
    end,
};

const StepOrderRecorder = struct {
    const Event = struct {
        kind: StepEventKind,
        opcode: u8,
        depth: u16,
        stack_top: ?u256 = null,
    };

    events: [128]Event = undefined,
    len: usize = 0,

    fn consume(self: *StepOrderRecorder, span: trace.TraceSpan) !void {
        var cursor = trace.TraceCursor.init(span);
        while (try cursor.next()) |event| switch (event) {
            .step_start => |view| self.append(.{
                .kind = .start,
                .opcode = view.row.opcode,
                .depth = view.frame.depth,
            }),
            .step_end => |view| self.append(.{
                .kind = .end,
                .opcode = view.row.opcode,
                .depth = view.frame.depth,
                .stack_top = if (view.state.stack.?.len == 0)
                    null
                else
                    view.state.stack.?[view.state.stack.?.len - 1],
            }),
            .frame_enter, .frame_leave => {},
        };
    }

    fn firstIndex(self: *const StepOrderRecorder, kind: StepEventKind, opcode: evmz.Opcode, depth: u16) ?usize {
        for (self.events[0..self.len], 0..) |event, index| {
            if (event.kind == kind and event.opcode == @intFromEnum(opcode) and event.depth == depth) return index;
        }
        return null;
    }

    fn hasDepthStartBetween(self: *const StepOrderRecorder, depth: u16, start_index: usize, end_index: usize) bool {
        for (self.events[start_index + 1 .. end_index]) |event| {
            if (event.kind == .start and event.depth == depth) return true;
        }
        return false;
    }

    fn append(self: *StepOrderRecorder, event: Event) void {
        std.debug.assert(self.len < self.events.len);
        self.events[self.len] = event;
        self.len += 1;
    }
};

fn executeHostCall(executor: anytype, msg: Host.Message) !Host.Result {
    var host_iface = executor.host();
    return host_iface.call(msg);
}

test "EIP-161 empty accounts do not exist from Spurious Dragon on" {
    const Cancun = evmz.t.Vm(.cancun) orelse return error.SkipZigTest;
    const sender = evmz.addr(0x1111);
    const probe = evmz.addr(0xaaaa);
    const seeded_empty = evmz.addr(0x00e0);

    // PUSH2 0x00e0, EXTCODEHASH, PUSH0, SSTORE, STOP
    const probe_code = evmz.t.bytecode(.{
        .PUSH2, 0x00,
        0xe0,   .EXTCODEHASH,
        .PUSH0, .SSTORE,
        .STOP,
    });

    // A reader may hand back an EIP-161-empty account: `MemoryStore` does it
    // for any address a fixture seeds without fields. EIP-1052 requires zero
    // for such an account, not the hash of empty code.
    {
        var executor = Cancun.Executor.init(std.testing.allocator, .{});
        defer executor.deinit();
        try evmz.t.seedExecutorAccount(&executor, seeded_empty, .{});
        try evmz.t.seedExecutorAccount(&executor, probe, .{ .code = &probe_code });
        _ = try executor.executeSystemCall(
            testExecutionContext(sender, 200_000),
            sender,
            probe,
            &.{},
            .legacy(200_000),
        );
        try std.testing.expectEqual(@as(u256, 0), try executor.getStorage(probe, 0));
        try std.testing.expect(!try executor.state.accountExists(seeded_empty));
    }

    // Alive through balance alone: an ordinary codeless account still reports
    // the empty-code hash.
    {
        var executor = Cancun.Executor.init(std.testing.allocator, .{});
        defer executor.deinit();
        try evmz.t.seedExecutorAccount(&executor, seeded_empty, .{ .balance = 1 });
        try evmz.t.seedExecutorAccount(&executor, probe, .{ .code = &probe_code });
        _ = try executor.executeSystemCall(
            testExecutionContext(sender, 200_000),
            sender,
            probe,
            &.{},
            .legacy(200_000),
        );
        try std.testing.expectEqual(
            @as(u256, std.mem.readInt(u256, &evmz.crypto.keccak256_empty, .big)),
            try executor.getStorage(probe, 0),
        );
    }
}

test "pre-Spurious-Dragon retains empty accounts as real state" {
    const TangerineWhistle = evmz.t.Vm(.tangerine_whistle) orelse return error.SkipZigTest;
    const seeded_empty = evmz.addr(0x00e0);
    var executor = TangerineWhistle.Executor.init(std.testing.allocator, .{});
    defer executor.deinit();
    try executor.reset(.{});
    try std.testing.expect(executor.state.retains_empty_accounts);
    executor.discardAccepted();
    try std.testing.expect(executor.state.retains_empty_accounts);
    try evmz.t.seedExecutorAccount(&executor, seeded_empty, .{});

    const attempt = executor.state.beginTransaction();
    executor.state.beginScope();
    defer {
        executor.state.closeScope();
        executor.state.seal(attempt);
        executor.state.discard(attempt);
    }
    try std.testing.expect(try executor.state.accountExists(seeded_empty));
}

test "EIP-7610 storage-only accounts collide even though EIP-161 calls them dead" {
    const London = evmz.t.Vm(.london) orelse return error.SkipZigTest;
    const target = evmz.addr(0x7610);
    var executor = London.Executor.init(std.testing.allocator, .{});
    defer executor.deinit();

    // Zero nonce, zero balance, no code, but storage: EIP-161 emptiness ignores
    // storage, so this reads as absent, while the state trie still keeps the
    // leaf because its storage root is non-empty.
    var seeded = evmz.state.MemoryAccount.init(std.testing.allocator);
    try seeded.storage.put(1, 1);
    try executor.state.seedAccount(target, seeded);

    const attempt = executor.state.beginTransaction();
    executor.state.beginScope();
    defer {
        executor.state.closeScope();
        executor.state.seal(attempt);
        executor.state.discard(attempt);
    }
    // Dead for existence, code hash, and CALL gas; still present for the
    // EIP-7610 creation predicate. `expectCreationCollision` in call_runtime
    // covers the collision itself across every revision.
    try std.testing.expect(!try executor.state.accountExists(target));
    try std.testing.expectEqual(@as(u256, 0), try executor.state.getCodeHash(target));
    try std.testing.expect(try executor.state.accountHasStorage(target));
}
