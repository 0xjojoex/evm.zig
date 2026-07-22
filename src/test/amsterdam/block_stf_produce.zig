const std = @import("std");
const evmz = @import("../../evm.zig");

const bal = evmz.eth.bal;
const block_stf = evmz.eth.block_stf;
const state = evmz.state;
const Withdrawal = evmz.eth.Withdrawal;
const fixture = @import("bal_execution_fixture.zig");
const bal_parallel = @import("bal_parallel_test_support.zig");

const withdrawal_gwei_in_wei: u256 = 1_000_000_000;
const recipient = evmz.addr(0x7928);
const withdrawal = Withdrawal{
    .index = 1,
    .validator_index = 2,
    .address = recipient,
    .amount = 1,
};

const StateCaptureCounter = struct {
    account_accesses: usize = 0,
    reads: usize = 0,
    writes: usize = 0,
    checkpoints: usize = 0,

    fn target(self: *StateCaptureCounter) evmz.executor.CaptureStateTarget {
        return .init(self, &.{
            .account_access = accountAccess,
            .state_read = stateRead,
            .state_write = stateWrite,
            .checkpoint = checkpoint,
        });
    }

    fn accountAccess(ptr: *anyopaque, _: evmz.trace.AccountAccess) !void {
        const self: *StateCaptureCounter = @ptrCast(@alignCast(ptr));
        self.account_accesses += 1;
    }

    fn stateRead(ptr: *anyopaque, _: evmz.trace.StateRead) !void {
        const self: *StateCaptureCounter = @ptrCast(@alignCast(ptr));
        self.reads += 1;
    }

    fn stateWrite(ptr: *anyopaque, _: evmz.trace.StateWrite) !void {
        const self: *StateCaptureCounter = @ptrCast(@alignCast(ptr));
        self.writes += 1;
    }

    fn checkpoint(ptr: *anyopaque, _: evmz.trace.Checkpoint) !void {
        const self: *StateCaptureCounter = @ptrCast(@alignCast(ptr));
        self.checkpoints += 1;
    }
};

const CountingBlockHashSource = struct {
    calls: std.atomic.Value(usize) = .init(0),

    fn source(self: *CountingBlockHashSource) evmz.BlockHashSource {
        return .{ .ptr = self, .vtable = &.{ .getBlockHash = getBlockHash } };
    }

    fn getBlockHash(ptr: *anyopaque, _: u64) !?u256 {
        const self: *CountingBlockHashSource = @ptrCast(@alignCast(ptr));
        _ = self.calls.fetchAdd(1, .monotonic);
        return 0x1234;
    }
};

test "BlockSTF produce returns the owned canonical empty BAL" {
    try std.testing.expect(!@hasField(block_stf.DerivedBlockOutput, "block_hash"));

    var outcome = try block_stf.produce(std.testing.allocator, .{
        .revision = .amsterdam,
        .env = blockEnv(30_000_000),
        .state_backend = try state.Backend.fromWitness(
            std.testing.allocator,
            evmz.eth.trie.empty_root_hash,
            &.{},
            &.{},
        ),
        .transactions = &.{},
        .parent_blob_gas = parentBlobGas(),
    });
    defer outcome.deinit(std.testing.allocator);

    const produced = switch (outcome) {
        .produced => |*value| value,
        .rejected => |result| {
            std.debug.print("unexpected produce rejection: {s}\n", .{@tagName(result.status)});
            return error.TestUnexpectedResult;
        },
    };
    try std.testing.expectEqualSlices(u8, &.{0xc0}, produced.encoded_block_access_list);
    try std.testing.expectEqualSlices(u8, &bal.empty_hash, &produced.output.block_access_list_hash);
}

test "BlockSTF produced BAL round trips through compare mode" {
    const withdrawals = [_]Withdrawal{withdrawal};
    var producer_state = state.MemoryStore.init(std.testing.allocator);
    defer producer_state.deinit();

    var outcome = try block_stf.produce(std.testing.allocator, .{
        .revision = .amsterdam,
        .env = blockEnv(30_000_000),
        .state_backend = producer_state.backend(),
        .transactions = &.{},
        .withdrawals = &withdrawals,
        .parent_blob_gas = parentBlobGas(),
    });
    defer outcome.deinit(std.testing.allocator);

    const produced = switch (outcome) {
        .produced => |*value| value,
        .rejected => |result| {
            std.debug.print("unexpected produce rejection: {s}\n", .{@tagName(result.status)});
            return error.TestUnexpectedResult;
        },
    };
    try std.testing.expectEqual(
        withdrawal_gwei_in_wei,
        producer_state.getAccount(recipient).?.balance,
    );
    try std.testing.expectEqualSlices(
        u8,
        &evmz.crypto.keccak256(produced.encoded_block_access_list),
        &produced.output.block_access_list_hash,
    );

    const expected_changes = [_]bal.BalanceChange{.{
        .block_access_index = 1,
        .post_balance = withdrawal_gwei_in_wei,
    }};
    const expected_accounts = [_]bal.AccountChanges{.{
        .address = recipient,
        .balance_changes = &expected_changes,
    }};
    const expected_encoded = try bal.encodeAlloc(std.testing.allocator, &expected_accounts);
    defer std.testing.allocator.free(expected_encoded);
    try std.testing.expectEqualSlices(u8, expected_encoded, produced.encoded_block_access_list);

    var verifier_state = state.MemoryStore.init(std.testing.allocator);
    defer verifier_state.deinit();
    var differential_report = bal.Report{};
    const verified = try block_stf.applyAssumeDecoded(std.testing.allocator, .{
        .revision = .amsterdam,
        .env = blockEnv(30_000_000),
        .state_backend = verifier_state.backend(),
        .transactions = &.{},
        .withdrawals = &withdrawals,
        .parent_blob_gas = parentBlobGas(),
        .block_access_list = produced.encoded_block_access_list,
        .root_checks = rootChecks(produced.output),
        .header_claims = .{
            .block_access_list_hash = produced.output.block_access_list_hash,
        },
        .bal_differential = &differential_report,
    });
    try std.testing.expectEqual(block_stf.Status.valid, verified.status);
    try std.testing.expectEqual(bal.DifferentialStatus.matched, differential_report.status);
    try std.testing.expectEqual(
        withdrawal_gwei_in_wei,
        verifier_state.getAccount(recipient).?.balance,
    );
}

test "BlockSTF checked produce and apply decode raw bytes once for execution and trie root" {
    const hex = "f86c098504a817c800825208943535353535353535353535353535353535353535880de0b6b3a76400008025a028ef61340bd939bc2195fe537567866003e1a15d3c71ff63e1590620aa636276a067cbe9d8997f761aecb703304b3800ccf555c9f3dc64214b297fb1966a3b6d83";
    var encoded: [hex.len / 2]u8 = undefined;
    _ = try std.fmt.hexToBytes(&encoded, hex);
    const decoded = try evmz.transaction.raw.decodeRaw(std.testing.allocator, &encoded);

    var memory = state.MemoryStore.init(std.testing.allocator);
    defer memory.deinit();
    const sender_account = try memory.getOrCreateAccount(decoded.sender);
    sender_account.nonce = @intCast(decoded.nonce.?);
    sender_account.balance = decoded.value +
        @as(u256, decoded.gas_limit) * decoded.gas_price + 1;
    const target = decoded.to.?;
    _ = try memory.getOrCreateAccount(target);
    var verifier_state = try memory.clone(std.testing.allocator);
    defer verifier_state.deinit();
    var parallel_verifier_state = try memory.clone(std.testing.allocator);
    defer parallel_verifier_state.deinit();
    const raw_transactions = [_][]const u8{&encoded};

    var outcome = try block_stf.produce(std.testing.allocator, .{
        .revision = .amsterdam,
        .env = blockEnv(30_000_000),
        .state_backend = memory.backend(),
        .transactions = &raw_transactions,
        .parent_blob_gas = parentBlobGas(),
    });
    defer outcome.deinit(std.testing.allocator);

    const produced = switch (outcome) {
        .produced => |*value| value,
        .rejected => |result| {
            std.debug.print("unexpected produce rejection: {s}\n", .{@tagName(result.status)});
            return error.TestUnexpectedResult;
        },
    };
    const expected_root = try evmz.eth.trie.transactionRoot(
        std.testing.allocator,
        &raw_transactions,
    );
    try std.testing.expectEqualSlices(u8, &expected_root, &produced.output.transactions_root);
    try std.testing.expectEqual(@as(u64, 10), memory.getAccount(decoded.sender).?.nonce);
    try std.testing.expectEqual(decoded.value, memory.getAccount(target).?.balance);

    const verified = try block_stf.apply(std.testing.allocator, .{
        .revision = .amsterdam,
        .env = blockEnv(30_000_000),
        .state_backend = verifier_state.backend(),
        .transactions = &raw_transactions,
        .parent_blob_gas = parentBlobGas(),
        .block_access_list = produced.encoded_block_access_list,
        .root_checks = rootChecks(produced.output),
        .header_claims = .{ .block_access_list_hash = produced.output.block_access_list_hash },
    });
    try std.testing.expectEqual(block_stf.Status.valid, verified.status);
    try std.testing.expectEqualSlices(u8, &expected_root, &verified.transactions_root);
    try std.testing.expectEqual(@as(u64, 10), verifier_state.getAccount(decoded.sender).?.nonce);
    try std.testing.expectEqual(decoded.value, verifier_state.getAccount(target).?.balance);

    const parallel_reader = parallel_verifier_state.concurrentReader();
    var parallel_report = bal.Report{};
    const parallel_verified = try bal_parallel.apply(
        std.testing.io,
        std.testing.allocator,
        .{
            .revision = .amsterdam,
            .env = blockEnv(30_000_000),
            .state_backend = parallel_verifier_state.backend(),
            .transactions = &raw_transactions,
            .parent_blob_gas = parentBlobGas(),
            .block_access_list = produced.encoded_block_access_list,
            .root_checks = rootChecks(produced.output),
            .header_claims = .{ .block_access_list_hash = produced.output.block_access_list_hash },
            .bal_differential = &parallel_report,
        },
        .{ .max_in_flight = 1 },
        .{
            .lane_allocator = std.heap.smp_allocator,
            .state_reader = parallel_reader,
        },
    );
    try std.testing.expectEqual(block_stf.Status.valid, parallel_verified.status);
    try std.testing.expectEqual(bal.DifferentialStatus.matched, parallel_report.status);
    try std.testing.expectEqual(@as(usize, 1), parallel_report.parallel_submitted_lanes);
    try std.testing.expectEqualSlices(u8, &expected_root, &parallel_verified.transactions_root);
    try std.testing.expectEqual(@as(u64, 10), parallel_verifier_state.getAccount(decoded.sender).?.nonce);
    try std.testing.expectEqual(decoded.value, parallel_verifier_state.getAccount(target).?.balance);
}

test "BlockSTF parallel raw API owns decode failure cleanup" {
    const empty_roots: block_stf.RootChecks = .{ .payload_header = .{
        .state = .fromHash(evmz.eth.trie.empty_root_hash),
        .receipts = .fromHash(evmz.eth.trie.empty_root_hash),
    } };
    var report = bal.Report{};
    const invalid_raw = [_][]const u8{"not an RLP transaction"};
    try std.testing.expectError(
        error.UnsupportedTransactionType,
        bal_parallel.apply(
            std.testing.io,
            std.testing.allocator,
            .{
                .revision = .amsterdam,
                .state_backend = try state.Backend.fromWitness(
                    std.testing.allocator,
                    evmz.eth.trie.empty_root_hash,
                    &.{},
                    &.{},
                ),
                .transactions = &invalid_raw,
                .root_checks = empty_roots,
                .bal_differential = &report,
            },
            .{ .max_in_flight = 1 },
            .{ .lane_allocator = std.testing.allocator },
        ),
    );
}

test "BlockSTF parallel lane ignores BLOCKHASH capability absent from canonical input" {
    const sender = evmz.addr(0xb100);
    const target = evmz.addr(0xb200);
    const target_code = [_]u8{
        0x5f, // PUSH0 previous block number
        0x40, // BLOCKHASH
        0x5f, // PUSH0 storage key
        0x55, // SSTORE
        0x00, // STOP
    };
    const transactions = [_]block_stf.TransactionInput{
        block_stf.TransactionInput.initAssumeDecoded(.{
            .sender = sender,
            .nonce = 0,
            .gas_limit = 1_000_000,
            .to = target,
        }, "parallel-blockhash-gate"),
    };

    var producer_state = state.MemoryStore.init(std.testing.allocator);
    defer producer_state.deinit();
    (try producer_state.getOrCreateAccount(sender)).balance = 1_000_000;
    try (try producer_state.getOrCreateAccount(target)).setCode(&target_code);
    // Keep Amsterdam lifecycle calls valid without adding their unrelated
    // storage behavior to this BLOCKHASH capability test.
    for ([_]evmz.Address{
        evmz.eth.beacon_roots_address,
        evmz.eth.history_storage_address,
        evmz.eth.withdrawal_request_predeploy_address,
        evmz.eth.consolidation_request_predeploy_address,
        evmz.eth.builder_deposit_request_predeploy_address,
        evmz.eth.builder_exit_request_predeploy_address,
    }) |predeploy| {
        try (try producer_state.getOrCreateAccount(predeploy)).setCode(&.{0x00});
    }
    var verifier_state = try producer_state.clone(std.testing.allocator);
    defer verifier_state.deinit();

    const parent_hash = [_]u8{0x11} ** 32;
    const parent_beacon_block_root = [_]u8{0x22} ** 32;
    const env: evmz.Env = .{ .number = 1, .timestamp = 1, .gas_limit = 2_000_000 };
    const header: block_stf.BlockHeader = .{
        .number = env.number,
        .timestamp = env.timestamp,
        .parent_hash = parent_hash,
        .parent_beacon_block_root = parent_beacon_block_root,
    };
    const parent: block_stf.ParentHeaderContext = .{
        .hash = parent_hash,
        .number = 0,
        .timestamp = 0,
        .gas_limit = env.gas_limit,
        .gas_used = 0,
        .base_fee_per_gas = 0,
    };

    var outcome = try block_stf.produceAssumeDecoded(std.testing.allocator, .{
        .revision = .amsterdam,
        .env = env,
        .block_header = header,
        .state_backend = producer_state.backend(),
        .transactions = &transactions,
        .parent_header = parent,
    });
    defer outcome.deinit(std.testing.allocator);
    const produced = switch (outcome) {
        .produced => |*value| value,
        .rejected => |result| {
            std.debug.print("unexpected BLOCKHASH fixture rejection: {s}\n", .{@tagName(result.status)});
            return error.TestUnexpectedResult;
        },
    };

    const concurrent_reader = verifier_state.concurrentReader();
    var extra_source = CountingBlockHashSource{};
    var report = bal.Report{};
    const verified = try bal_parallel.applyAssumeDecoded(
        std.testing.io,
        std.testing.allocator,
        .{
            .revision = .amsterdam,
            .env = env,
            .block_header = header,
            .state_backend = verifier_state.backend(),
            .transactions = &transactions,
            .parent_header = parent,
            .block_access_list = produced.encoded_block_access_list,
            .root_checks = rootChecks(produced.output),
            .header_claims = .{
                .block_access_list_hash = produced.output.block_access_list_hash,
            },
            .bal_differential = &report,
        },
        .{ .max_in_flight = 1 },
        .{
            .lane_allocator = std.heap.smp_allocator,
            .state_reader = concurrent_reader,
            .block_hash_source = .initAssumeSafe(extra_source.source()),
        },
    );
    try std.testing.expectEqual(block_stf.Status.valid, verified.status);
    try std.testing.expectEqual(bal.DifferentialStatus.matched, report.status);
    try std.testing.expectEqual(@as(usize, 0), extra_source.calls.load(.monotonic));
}

test "BlockSTF produce folds the two-transaction BAL differential fixture" {
    var producer_state = state.MemoryStore.init(std.testing.allocator);
    defer producer_state.deinit();
    try fixture.initState(&producer_state);

    var outcome = try block_stf.produceAssumeDecoded(std.testing.allocator, .{
        .revision = .amsterdam,
        .env = .{ .gas_limit = 2_000_000 },
        .state_backend = producer_state.backend(),
        .transactions = &fixture.transactions,
        .parent_blob_gas = parentBlobGas(),
    });
    defer outcome.deinit(std.testing.allocator);

    const produced = switch (outcome) {
        .produced => |*value| value,
        .rejected => |result| {
            std.debug.print("unexpected produce rejection: {s}\n", .{@tagName(result.status)});
            return error.TestUnexpectedResult;
        },
    };
    try std.testing.expect(!std.mem.eql(
        u8,
        &.{0xc0},
        produced.encoded_block_access_list,
    ));
    try std.testing.expectEqualSlices(
        u8,
        &evmz.crypto.keccak256(produced.encoded_block_access_list),
        &produced.output.block_access_list_hash,
    );

    var verifier_state = state.MemoryStore.init(std.testing.allocator);
    defer verifier_state.deinit();
    try fixture.initState(&verifier_state);
    var differential_report = bal.Report{};
    const verified = try block_stf.applyAssumeDecoded(std.testing.allocator, .{
        .revision = .amsterdam,
        .env = .{ .gas_limit = 2_000_000 },
        .state_backend = verifier_state.backend(),
        .transactions = &fixture.transactions,
        .parent_blob_gas = parentBlobGas(),
        .block_access_list = produced.encoded_block_access_list,
        .root_checks = rootChecks(produced.output),
        .header_claims = .{
            .block_access_list_hash = produced.output.block_access_list_hash,
        },
        .bal_differential = &differential_report,
    });
    try std.testing.expectEqual(block_stf.Status.valid, verified.status);
    try std.testing.expectEqual(bal.DifferentialStatus.matched, differential_report.status);
    try std.testing.expectEqualSlices(u8, &produced.output.state_root, &verified.state_root);
    try std.testing.expectEqualSlices(u8, &produced.output.receipts_root, &verified.receipts_root);
}

test "BlockSTF parallel BAL lane preserves serial truth across strategies" {
    var producer_state = state.MemoryStore.init(std.testing.allocator);
    defer producer_state.deinit();
    try fixture.initState(&producer_state);

    var outcome = try block_stf.produceAssumeDecoded(std.testing.allocator, .{
        .revision = .amsterdam,
        .env = .{ .gas_limit = 2_000_000 },
        .state_backend = producer_state.backend(),
        .transactions = &fixture.transactions,
        .parent_blob_gas = parentBlobGas(),
    });
    defer outcome.deinit(std.testing.allocator);
    const produced = switch (outcome) {
        .produced => |*value| value,
        .rejected => return error.TestUnexpectedResult,
    };

    var serial_capture_state = state.MemoryStore.init(std.testing.allocator);
    defer serial_capture_state.deinit();
    try fixture.initState(&serial_capture_state);
    var serial_capture = StateCaptureCounter{};
    var serial_capture_report = bal.Report{};
    const serial_capture_result = try block_stf.applyAssumeDecoded(std.testing.allocator, .{
        .revision = .amsterdam,
        .env = .{ .gas_limit = 2_000_000 },
        .state_backend = serial_capture_state.backend(),
        .transactions = &fixture.transactions,
        .parent_blob_gas = parentBlobGas(),
        .block_access_list = produced.encoded_block_access_list,
        .root_checks = rootChecks(produced.output),
        .header_claims = .{
            .block_access_list_hash = produced.output.block_access_list_hash,
        },
        .capture = .{ .state_target = serial_capture.target() },
        .bal_differential = &serial_capture_report,
    });
    try std.testing.expectEqual(block_stf.Status.valid, serial_capture_result.status);
    var parallel_capture = StateCaptureCounter{};

    for ([_]usize{ 2, 1 }) |max_in_flight| {
        var verifier_state = state.MemoryStore.init(std.testing.allocator);
        defer verifier_state.deinit();
        try fixture.initState(&verifier_state);
        const concurrent_reader = verifier_state.concurrentReader();
        var report = bal.Report{};
        const verified = try bal_parallel.applyAssumeDecoded(
            std.testing.io,
            std.testing.allocator,
            .{
                .revision = .amsterdam,
                .env = .{ .gas_limit = 2_000_000 },
                .state_backend = verifier_state.backend(),
                .transactions = &fixture.transactions,
                .parent_blob_gas = parentBlobGas(),
                .block_access_list = produced.encoded_block_access_list,
                .root_checks = rootChecks(produced.output),
                .header_claims = .{
                    .block_access_list_hash = produced.output.block_access_list_hash,
                },
                .capture = if (max_in_flight == 2)
                    .{ .state_target = parallel_capture.target() }
                else
                    null,
                .bal_differential = &report,
            },
            .{ .max_in_flight = max_in_flight },
            .{
                .lane_allocator = std.heap.smp_allocator,
                .state_reader = concurrent_reader,
            },
        );
        try std.testing.expectEqual(block_stf.Status.valid, verified.status);
        try std.testing.expectEqual(bal.DifferentialStatus.matched, report.status);
        try std.testing.expectEqual(@as(?bal.ParallelFallback, null), report.parallel_fallback);
        try std.testing.expectEqual(@as(usize, fixture.transactions.len), report.parallel_submitted_lanes);
        try std.testing.expectEqual(@min(max_in_flight, fixture.transactions.len), report.parallel_max_batch_size);
        try std.testing.expectEqual(
            std.math.divCeil(usize, fixture.transactions.len, max_in_flight) catch unreachable,
            report.parallel_batches,
        );
        try std.testing.expectEqualSlices(u8, &produced.output.state_root, &verified.state_root);
        try std.testing.expectEqualSlices(u8, &produced.output.receipts_root, &verified.receipts_root);
    }
    try std.testing.expectEqual(serial_capture, parallel_capture);

    var fallback_state = state.MemoryStore.init(std.testing.allocator);
    defer fallback_state.deinit();
    try fixture.initState(&fallback_state);
    var fallback_report = bal.Report{};
    const fallback = try bal_parallel.applyAssumeDecoded(
        std.testing.io,
        std.testing.allocator,
        .{
            .revision = .amsterdam,
            .env = .{ .gas_limit = 2_000_000 },
            .state_backend = fallback_state.backend(),
            .transactions = &fixture.transactions,
            .parent_blob_gas = parentBlobGas(),
            .block_access_list = produced.encoded_block_access_list,
            .root_checks = rootChecks(produced.output),
            .header_claims = .{
                .block_access_list_hash = produced.output.block_access_list_hash,
            },
            .bal_differential = &fallback_report,
        },
        .{ .max_in_flight = 2 },
        .{ .lane_allocator = std.heap.smp_allocator },
    );
    try std.testing.expectEqual(block_stf.Status.valid, fallback.status);
    try std.testing.expectEqual(bal.DifferentialStatus.matched, fallback_report.status);
    try std.testing.expectEqual(
        bal.ParallelFallback.concurrent_state_reader_unavailable,
        fallback_report.parallel_fallback.?,
    );
    try std.testing.expectEqual(@as(usize, 0), fallback_report.parallel_submitted_lanes);

    var concurrent_state = state.MemoryStore.init(std.testing.allocator);
    defer concurrent_state.deinit();
    try fixture.initState(&concurrent_state);
    const concurrent_reader = concurrent_state.concurrentReader();
    var concurrent_report = bal.Report{};
    const concurrent = try bal_parallel.applyAssumeDecoded(
        std.testing.io,
        std.testing.allocator,
        .{
            .revision = .amsterdam,
            .env = .{ .gas_limit = 2_000_000 },
            .state_backend = concurrent_state.backend(),
            .transactions = &fixture.transactions,
            .parent_blob_gas = parentBlobGas(),
            .block_access_list = produced.encoded_block_access_list,
            .root_checks = rootChecks(produced.output),
            .header_claims = .{
                .block_access_list_hash = produced.output.block_access_list_hash,
            },
            .bal_differential = &concurrent_report,
        },
        .{ .max_in_flight = 2, .submission = .concurrent },
        .{
            .lane_allocator = std.heap.smp_allocator,
            .state_reader = concurrent_reader,
        },
    );
    try std.testing.expectEqual(block_stf.Status.valid, concurrent.status);
    if (concurrent_report.parallel_fallback) |reason| {
        try std.testing.expectEqual(bal.ParallelFallback.concurrency_unavailable, reason);
        try std.testing.expectEqual(
            bal.DifferentialStatus.fallback_parallel_runtime,
            concurrent_report.status,
        );
    } else {
        try std.testing.expectEqual(bal.DifferentialStatus.matched, concurrent_report.status);
        try std.testing.expectEqual(@as(usize, fixture.transactions.len), concurrent_report.parallel_submitted_lanes);
    }
    try std.testing.expectEqualSlices(u8, &produced.output.state_root, &concurrent.state_root);
    try std.testing.expectEqualSlices(u8, &produced.output.receipts_root, &concurrent.receipts_root);

    var oom_transactions = fixture.transactions;
    oom_transactions[1].tx.input = &.{1};
    oom_transactions[1].encoded = "bal-differential-second-write-tx";

    var oom_producer_state = state.MemoryStore.init(std.testing.allocator);
    defer oom_producer_state.deinit();
    try fixture.initState(&oom_producer_state);
    var oom_outcome = try block_stf.produceAssumeDecoded(std.testing.allocator, .{
        .revision = .amsterdam,
        .env = .{ .gas_limit = 2_000_000 },
        .state_backend = oom_producer_state.backend(),
        .transactions = &oom_transactions,
        .parent_blob_gas = parentBlobGas(),
    });
    defer oom_outcome.deinit(std.testing.allocator);
    const oom_produced = switch (oom_outcome) {
        .produced => |*value| value,
        .rejected => return error.TestUnexpectedResult,
    };

    // Both authoritative results have empty output/logs, so staging needs no
    // lane allocation. The 256-byte cap is first encountered inside each
    // submitted task, proving one lane OOM does not leave its sibling undrained.
    var limited_lanes: std.heap.DebugAllocator(.{ .enable_memory_limit = true }) = .init;
    defer std.testing.expect(limited_lanes.deinit() == .ok) catch @panic("lane allocator leak");
    limited_lanes.requested_memory_limit = 256;
    var oom_state = state.MemoryStore.init(std.testing.allocator);
    defer oom_state.deinit();
    try fixture.initState(&oom_state);
    const oom_reader = oom_state.concurrentReader();
    var oom_report = bal.Report{};
    const oom_result = try bal_parallel.applyAssumeDecoded(
        std.testing.io,
        std.testing.allocator,
        .{
            .revision = .amsterdam,
            .env = .{ .gas_limit = 2_000_000 },
            .state_backend = oom_state.backend(),
            .transactions = &oom_transactions,
            .parent_blob_gas = parentBlobGas(),
            .block_access_list = oom_produced.encoded_block_access_list,
            .root_checks = rootChecks(oom_produced.output),
            .header_claims = .{
                .block_access_list_hash = oom_produced.output.block_access_list_hash,
            },
            .bal_differential = &oom_report,
        },
        .{ .max_in_flight = 2 },
        .{
            .lane_allocator = limited_lanes.allocator(),
            .state_reader = oom_reader,
        },
    );
    try std.testing.expectEqual(block_stf.Status.valid, oom_result.status);
    try std.testing.expectEqual(
        bal.DifferentialStatus.fallback_parallel_runtime,
        oom_report.status,
    );
    try std.testing.expectEqual(
        bal.ParallelFallback.lane_out_of_memory,
        oom_report.parallel_fallback.?,
    );
    try std.testing.expectEqual(error.OutOfMemory, oom_report.diagnostic_error.?);
    try std.testing.expectEqual(@as(usize, oom_transactions.len), oom_report.parallel_submitted_lanes);
    try std.testing.expectEqual(@as(usize, 1), oom_report.parallel_batches);
    try std.testing.expectEqualSlices(u8, &oom_produced.output.state_root, &oom_result.state_root);
    try std.testing.expectEqualSlices(u8, &oom_produced.output.receipts_root, &oom_result.receipts_root);
}

test "BlockSTF BAL differential reconstructs serial block-start system calls" {
    var beacon_code_buf: [97]u8 = undefined;
    const beacon_code = try std.fmt.hexToBytes(
        &beacon_code_buf,
        "3373fffffffffffffffffffffffffffffffffffffffe14604d57602036146024575f5ffd5b5f35801560495762001fff810690815414603c575f5ffd5b62001fff01545f5260205ff35b5f5ffd5b62001fff42064281555f359062001fff015500",
    );
    var history_code_buf: [83]u8 = undefined;
    const history_code = try std.fmt.hexToBytes(
        &history_code_buf,
        "3373fffffffffffffffffffffffffffffffffffffffe14604657602036036042575f35600143038111604257611fff81430311604257611fff9006545f5260205ff35b5f5ffd5b5f35611fff60014303065500",
    );

    var producer_state = state.MemoryStore.init(std.testing.allocator);
    defer producer_state.deinit();
    try (try producer_state.getOrCreateAccount(evmz.eth.beacon_roots_address)).setCode(beacon_code);
    try (try producer_state.getOrCreateAccount(evmz.eth.history_storage_address)).setCode(history_code);
    for ([_]evmz.Address{
        evmz.eth.withdrawal_request_predeploy_address,
        evmz.eth.consolidation_request_predeploy_address,
        evmz.eth.builder_deposit_request_predeploy_address,
        evmz.eth.builder_exit_request_predeploy_address,
    }) |predeploy| {
        try (try producer_state.getOrCreateAccount(predeploy)).setCode(&.{0x00});
    }
    var verifier_state = try producer_state.clone(std.testing.allocator);
    defer verifier_state.deinit();

    var parent_hash = [_]u8{0x11} ** 32;
    parent_hash[31] = 0x22;
    var beacon_root = [_]u8{0x33} ** 32;
    beacon_root[31] = 0x44;
    const env: evmz.Env = .{
        .number = 1,
        .timestamp = 12,
        .gas_limit = 30_000_000,
    };
    const header: block_stf.BlockHeader = .{
        .number = env.number,
        .timestamp = env.timestamp,
        .parent_hash = parent_hash,
        .parent_beacon_block_root = beacon_root,
    };
    const parent: block_stf.ParentHeaderContext = .{
        .hash = parent_hash,
        .number = 0,
        .timestamp = 0,
        .gas_limit = env.gas_limit,
        .gas_used = 0,
        .base_fee_per_gas = 0,
    };

    var outcome = try block_stf.produce(std.testing.allocator, .{
        .revision = .amsterdam,
        .env = env,
        .block_header = header,
        .state_backend = producer_state.backend(),
        .transactions = &.{},
        .parent_header = parent,
    });
    defer outcome.deinit(std.testing.allocator);
    const produced = switch (outcome) {
        .produced => |*value| value,
        .rejected => |result| {
            std.debug.print("unexpected block-start produce rejection: {s}\n", .{@tagName(result.status)});
            return error.TestUnexpectedResult;
        },
    };

    var report = bal.Report{};
    const verified = try block_stf.applyAssumeDecoded(std.testing.allocator, .{
        .revision = .amsterdam,
        .env = env,
        .block_header = header,
        .state_backend = verifier_state.backend(),
        .transactions = &.{},
        .parent_header = parent,
        .block_access_list = produced.encoded_block_access_list,
        .root_checks = rootChecks(produced.output),
        .header_claims = .{ .block_access_list_hash = produced.output.block_access_list_hash },
        .bal_differential = &report,
    });
    try std.testing.expectEqual(block_stf.Status.valid, verified.status);
    try std.testing.expectEqual(bal.DifferentialStatus.matched, report.status);
}

test "BlockSTF produce rejects an oversized BAL without artifact or commit" {
    const withdrawals = [_]Withdrawal{withdrawal};
    var memory = state.MemoryStore.init(std.testing.allocator);
    defer memory.deinit();

    var outcome = try block_stf.produce(std.testing.allocator, .{
        .revision = .amsterdam,
        .env = blockEnv(bal.item_cost - 1),
        .state_backend = memory.backend(),
        .transactions = &.{},
        .withdrawals = &withdrawals,
        .parent_blob_gas = parentBlobGas(),
    });
    defer outcome.deinit(std.testing.allocator);

    switch (outcome) {
        .produced => return error.TestUnexpectedResult,
        .rejected => |result| try std.testing.expectEqual(
            block_stf.Status.block_access_list_too_large,
            result.status,
        ),
    }
    try std.testing.expect(memory.getAccount(recipient) == null);
}

test "BlockSTF produce rejects pre-Amsterdam candidates without an artifact" {
    var outcome = try block_stf.produce(std.testing.allocator, .{
        .revision = .prague,
        .state_backend = try state.Backend.fromWitness(
            std.testing.allocator,
            evmz.eth.trie.empty_root_hash,
            &.{},
            &.{},
        ),
        .transactions = &.{},
    });
    defer outcome.deinit(std.testing.allocator);

    switch (outcome) {
        .produced => return error.TestUnexpectedResult,
        .rejected => |result| try std.testing.expectEqual(
            block_stf.Status.invalid_block_body,
            result.status,
        ),
    }
}

fn blockEnv(gas_limit: u64) evmz.Env {
    return .{
        .number = 0,
        .slot_number = 0,
        .timestamp = 0,
        .gas_limit = gas_limit,
        .base_fee = 7,
    };
}

fn parentBlobGas() block_stf.ParentBlobGas {
    return .{
        .parent_excess_blob_gas = 0,
        .parent_blob_gas_used = 0,
        .parent_base_fee_per_gas = 7,
    };
}

fn rootChecks(output: block_stf.DerivedBlockOutput) block_stf.RootChecks {
    return .{
        .payload_header = .{
            .state = .fromHash(output.state_root),
            .receipts = .fromHash(output.receipts_root),
        },
        .reconstructed_header = .{
            .transactions = .fromHash(output.transactions_root),
            .withdrawals = .fromHash(output.withdrawals_root),
        },
    };
}
