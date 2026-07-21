const std = @import("std");
const evmz = @import("../../evm.zig");

const bal = evmz.eth.bal;
const block_stf = evmz.eth.block_stf;
const trie = evmz.eth.trie;
const fixture = @import("bal_execution_fixture.zig");
const bal_parallel = @import("bal_parallel_test_support.zig");

const coinbase = fixture.coinbase;
const sender = fixture.sender;
const target = fixture.target;
const sender_start_balance = fixture.sender_start_balance;
const transfer_value = fixture.transfer_value;
const storage_slot = fixture.storage_slot;
const txs = fixture.transactions;

test "BlockSTF BAL differential contains hostile claims without output divergence" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const scratch = arena.allocator();

    var pre_state = evmz.state.MemoryStore.init(std.testing.allocator);
    defer pre_state.deinit();
    try fixture.initState(&pre_state);

    const tx_root = try trie.transactionRoot(scratch, &.{ txs[0].encoded, txs[1].encoded });
    const baseline = try block_stf.applyAssumeDecoded(scratch, blockInput(
        &pre_state,
        null,
        roots([_]u8{0xff} ** 32, tx_root, [_]u8{0xff} ** 32),
        null,
    ));
    try std.testing.expectEqual(block_stf.Status.state_root_mismatch, baseline.status);

    const sender_balance_changes = [_]bal.BalanceChange{
        .{ .block_access_index = 1, .post_balance = sender_start_balance - transfer_value },
        .{ .block_access_index = 2, .post_balance = sender_start_balance - 2 * transfer_value },
    };
    const sender_nonce_changes = [_]bal.NonceChange{
        .{ .block_access_index = 1, .new_nonce = 1 },
        .{ .block_access_index = 2, .new_nonce = 2 },
    };
    const target_balance_changes = [_]bal.BalanceChange{
        .{ .block_access_index = 1, .post_balance = transfer_value },
        .{ .block_access_index = 2, .post_balance = 2 * transfer_value },
    };
    const target_storage_value_changes = [_]bal.StorageChange{.{
        .block_access_index = 1,
        .new_value = 7,
    }};
    const target_storage_changes = [_]bal.SlotChanges{.{
        .slot = storage_slot,
        .changes = &target_storage_value_changes,
    }};
    const correct_claim = [_]bal.AccountChanges{
        .{ .address = coinbase },
        .{
            .address = sender,
            .balance_changes = &sender_balance_changes,
            .nonce_changes = &sender_nonce_changes,
        },
        .{
            .address = target,
            .storage_changes = &target_storage_changes,
            .balance_changes = &target_balance_changes,
        },
    };
    const expected_roots = roots(baseline.state_root, tx_root, baseline.receipts_root);

    var correct_store = try pre_state.clone(std.testing.allocator);
    defer correct_store.deinit();
    var correct_output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer correct_output.deinit();
    var correct_report = bal.Report{ .mismatch_writer = &correct_output.writer };
    const correct_encoded = try bal.encodeAlloc(scratch, &correct_claim);
    const correct = try block_stf.applyAssumeDecoded(scratch, blockInput(
        &correct_store,
        correct_encoded,
        expected_roots,
        &correct_report,
    ));
    if (correct.status != .valid) std.debug.print("synthetic BAL claim drift:\n{s}", .{correct_output.written()});
    try std.testing.expectEqual(block_stf.Status.valid, correct.status);
    try std.testing.expectEqual(bal.DifferentialStatus.matched, correct_report.status);
    try std.testing.expectEqual(@as(usize, txs.len), correct_report.folded_transactions);
    try std.testing.expectEqualSlices(u8, &baseline.block_access_list_hash, &correct.block_access_list_hash);

    const unused = evmz.addr(0x500);
    const overdeclared_claim = [_]bal.AccountChanges{
        correct_claim[0],
        .{ .address = unused },
        correct_claim[1],
        correct_claim[2],
    };
    var overdeclared_store = try pre_state.clone(std.testing.allocator);
    defer overdeclared_store.deinit();
    var overdeclared_report = bal.Report{};
    const overdeclared = try block_stf.applyAssumeDecoded(scratch, blockInput(
        &overdeclared_store,
        try bal.encodeAlloc(scratch, &overdeclared_claim),
        expected_roots,
        &overdeclared_report,
    ));
    try expectContainedMismatch(
        baseline,
        overdeclared,
        overdeclared_report,
        .candidate_matched,
    );

    var prechecked_store = try pre_state.clone(std.testing.allocator);
    defer prechecked_store.deinit();
    var prechecked_input = blockInput(
        &prechecked_store,
        correct_encoded,
        expected_roots,
        null,
    );
    prechecked_input.precheck_block_access_list_state = true;
    const prechecked = try block_stf.applyAssumeDecoded(scratch, prechecked_input);
    try std.testing.expectEqual(block_stf.Status.valid, prechecked.status);
    try std.testing.expectEqual(correct.gas_used, prechecked.gas_used);
    try std.testing.expectEqual(correct.block_gas_used, prechecked.block_gas_used);
    try std.testing.expectEqualSlices(u8, &correct.state_root, &prechecked.state_root);
    try std.testing.expectEqualSlices(u8, &correct.receipts_root, &prechecked.receipts_root);

    const dropped_storage_claim = [_]bal.AccountChanges{
        correct_claim[0],
        correct_claim[1],
        .{
            .address = target,
            .balance_changes = &target_balance_changes,
        },
    };
    var dropped_store = try pre_state.clone(std.testing.allocator);
    defer dropped_store.deinit();
    var dropped_output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer dropped_output.deinit();
    var dropped_report = bal.Report{ .mismatch_writer = &dropped_output.writer };
    const dropped = try block_stf.applyAssumeDecoded(scratch, blockInput(
        &dropped_store,
        try bal.encodeAlloc(scratch, &dropped_storage_claim),
        expected_roots,
        &dropped_report,
    ));
    try expectContainedMismatch(
        baseline,
        dropped,
        dropped_report,
        .claim_storage_not_covered,
    );
    try std.testing.expect(std.mem.indexOf(u8, dropped_output.written(), "storage_writes=[0x2={1:0x7}]") != null);

    const shifted_storage_value_changes = [_]bal.StorageChange{.{
        .block_access_index = 2,
        .new_value = 7,
    }};
    const shifted_storage_changes = [_]bal.SlotChanges{.{
        .slot = storage_slot,
        .changes = &shifted_storage_value_changes,
    }};
    const shifted_claim = [_]bal.AccountChanges{
        correct_claim[0],
        correct_claim[1],
        .{
            .address = target,
            .storage_changes = &shifted_storage_changes,
            .balance_changes = &target_balance_changes,
        },
    };
    var shifted_store = try pre_state.clone(std.testing.allocator);
    defer shifted_store.deinit();
    var shifted_report = bal.Report{};
    const shifted = try block_stf.applyAssumeDecoded(scratch, blockInput(
        &shifted_store,
        try bal.encodeAlloc(scratch, &shifted_claim),
        expected_roots,
        &shifted_report,
    ));
    try expectContainedMismatch(baseline, shifted, shifted_report, .outcome_mismatch);

    const lied_target_balance = [_]bal.BalanceChange{ .{
        .block_access_index = 1,
        .post_balance = transfer_value,
    }, .{
        .block_access_index = 2,
        .post_balance = 2 * transfer_value + 1,
    } };
    const lied_claim = [_]bal.AccountChanges{
        correct_claim[0],
        correct_claim[1],
        .{
            .address = target,
            .storage_changes = &target_storage_changes,
            .balance_changes = &lied_target_balance,
        },
    };
    var lied_store = try pre_state.clone(std.testing.allocator);
    defer lied_store.deinit();
    var lied_report = bal.Report{};
    const lied = try block_stf.applyAssumeDecoded(scratch, blockInput(
        &lied_store,
        try bal.encodeAlloc(scratch, &lied_claim),
        expected_roots,
        &lied_report,
    ));
    try expectContainedMismatch(baseline, lied, lied_report, .changeset_fold_mismatch);

    const lied_storage_value_changes = [_]bal.StorageChange{
        .{ .block_access_index = 1, .new_value = 7 },
        .{ .block_access_index = 2, .new_value = 8 },
    };
    const lied_storage_changes = [_]bal.SlotChanges{.{
        .slot = storage_slot,
        .changes = &lied_storage_value_changes,
    }};
    const lied_storage_claim = [_]bal.AccountChanges{
        correct_claim[0],
        correct_claim[1],
        .{
            .address = target,
            .storage_changes = &lied_storage_changes,
            .balance_changes = &target_balance_changes,
        },
    };
    var lied_storage_store = try pre_state.clone(std.testing.allocator);
    defer lied_storage_store.deinit();
    var lied_storage_report = bal.Report{};
    const lied_storage = try block_stf.applyAssumeDecoded(scratch, blockInput(
        &lied_storage_store,
        try bal.encodeAlloc(scratch, &lied_storage_claim),
        expected_roots,
        &lied_storage_report,
    ));
    try expectContainedMismatch(
        baseline,
        lied_storage,
        lied_storage_report,
        .changeset_fold_mismatch,
    );

    // Fold verification is intentionally claim-subset-only: omitting target
    // balance changes does not affect outputs/logs and passes that local
    // check. Whole-candidate reconstruction is two-sided, so the missing
    // intermediate balance makes its final changeset diverge from serial.
    const underdeclared_claim = [_]bal.AccountChanges{
        correct_claim[0],
        correct_claim[1],
        .{
            .address = target,
            .storage_changes = &target_storage_changes,
        },
    };
    var underdeclared_store = try pre_state.clone(std.testing.allocator);
    defer underdeclared_store.deinit();
    var underdeclared_report = bal.Report{};
    const underdeclared = try block_stf.applyAssumeDecoded(scratch, blockInput(
        &underdeclared_store,
        try bal.encodeAlloc(scratch, &underdeclared_claim),
        expected_roots,
        &underdeclared_report,
    ));
    try expectContainedMismatch(
        baseline,
        underdeclared,
        underdeclared_report,
        .candidate_artifact_mismatch,
    );
}

test "BlockSTF BAL differential matches first rejected transaction and blob cap" {
    const sender_balance_changes = [_]bal.BalanceChange{.{
        .block_access_index = 1,
        .post_balance = sender_start_balance - transfer_value,
    }};
    const sender_nonce_changes = [_]bal.NonceChange{.{
        .block_access_index = 1,
        .new_nonce = 1,
    }};
    const target_balance_changes = [_]bal.BalanceChange{.{
        .block_access_index = 1,
        .post_balance = transfer_value,
    }};
    const target_storage_value_changes = [_]bal.StorageChange{.{
        .block_access_index = 1,
        .new_value = 7,
    }};
    const target_storage_changes = [_]bal.SlotChanges{.{
        .slot = storage_slot,
        .changes = &target_storage_value_changes,
    }};
    const claim = [_]bal.AccountChanges{
        .{ .address = coinbase },
        .{
            .address = sender,
            .balance_changes = &sender_balance_changes,
            .nonce_changes = &sender_nonce_changes,
        },
        .{
            .address = target,
            .storage_changes = &target_storage_changes,
            .balance_changes = &target_balance_changes,
        },
    };

    var rejected_second = txs[1];
    rejected_second.tx.nonce = 9;
    const transactions = [_]block_stf.TransactionInput{ txs[0], rejected_second };
    var rejected_store = evmz.state.MemoryStore.init(std.testing.allocator);
    defer rejected_store.deinit();
    try fixture.initState(&rejected_store);
    const encoded_claim = try bal.encodeAlloc(std.testing.allocator, &claim);
    defer std.testing.allocator.free(encoded_claim);
    var rejected_report = bal.Report{};
    const rejected = try block_stf.applyAssumeDecoded(std.testing.allocator, .{
        .revision = .amsterdam,
        .env = .{ .gas_limit = 2_000_000 },
        .state_backend = rejected_store.backend(),
        .transactions = &transactions,
        .block_access_list = encoded_claim,
        .root_checks = roots(trie.empty_root_hash, trie.empty_root_hash, trie.empty_root_hash),
        .bal_differential = &rejected_report,
    });
    try std.testing.expectEqual(block_stf.Status.transaction_rejected, rejected.status);
    try std.testing.expectEqual(@as(?usize, 1), rejected.tx_index);
    try std.testing.expectEqual(bal.DifferentialStatus.rejection_matched, rejected_report.status);
    try std.testing.expectEqual(@as(?usize, 1), rejected_report.tx_index);
    try std.testing.expectEqual(@as(usize, 1), rejected_report.folded_transactions);
    // The successful prefix is speculative until the complete block is
    // accepted. Rejecting transaction one must roll transaction zero back.
    try std.testing.expectEqual(@as(u64, 0), rejected_store.getAccount(sender).?.nonce);
    try std.testing.expectEqual(sender_start_balance, rejected_store.getAccount(sender).?.balance);
    try std.testing.expectEqual(@as(u256, 0), rejected_store.getAccount(target).?.balance);
    try std.testing.expectEqual(@as(u256, 0), rejected_store.getAccount(target).?.getStorage(storage_slot));

    var parallel_rejected_store = evmz.state.MemoryStore.init(std.testing.allocator);
    defer parallel_rejected_store.deinit();
    try fixture.initState(&parallel_rejected_store);
    const parallel_rejected_reader = parallel_rejected_store.concurrentReader();
    var parallel_rejected_report = bal.Report{};
    const parallel_rejected = try bal_parallel.applyAssumeDecoded(
        std.testing.io,
        std.testing.allocator,
        .{
            .revision = .amsterdam,
            .env = .{ .gas_limit = 2_000_000 },
            .state_backend = parallel_rejected_store.backend(),
            .transactions = &transactions,
            .block_access_list = encoded_claim,
            .root_checks = roots(trie.empty_root_hash, trie.empty_root_hash, trie.empty_root_hash),
            .bal_differential = &parallel_rejected_report,
        },
        .{ .max_in_flight = 2 },
        .{
            .lane_allocator = std.heap.smp_allocator,
            .state_reader = parallel_rejected_reader,
        },
    );
    try std.testing.expectEqual(block_stf.Status.transaction_rejected, parallel_rejected.status);
    try std.testing.expectEqual(
        bal.DifferentialStatus.rejection_matched,
        parallel_rejected_report.status,
    );
    try std.testing.expectEqual(@as(usize, 1), parallel_rejected_report.parallel_submitted_lanes);
    try std.testing.expectEqual(@as(usize, 1), parallel_rejected_report.folded_transactions);
    try std.testing.expectEqual(@as(u64, 0), parallel_rejected_store.getAccount(sender).?.nonce);
    try std.testing.expectEqual(@as(u256, 0), parallel_rejected_store.getAccount(target).?.getStorage(storage_slot));

    const lied_sender_nonce_changes = [_]bal.NonceChange{.{
        .block_access_index = 1,
        .new_nonce = 9,
    }};
    const lied_claim = [_]bal.AccountChanges{
        claim[0],
        .{
            .address = sender,
            .balance_changes = &sender_balance_changes,
            .nonce_changes = &lied_sender_nonce_changes,
        },
        claim[2],
    };
    var lied_store = evmz.state.MemoryStore.init(std.testing.allocator);
    defer lied_store.deinit();
    try fixture.initState(&lied_store);
    const lied_encoded_claim = try bal.encodeAlloc(std.testing.allocator, &lied_claim);
    defer std.testing.allocator.free(lied_encoded_claim);
    var lied_report = bal.Report{};
    const lied_rejected = try block_stf.applyAssumeDecoded(std.testing.allocator, .{
        .revision = .amsterdam,
        .env = .{ .gas_limit = 2_000_000 },
        .state_backend = lied_store.backend(),
        .transactions = &transactions,
        .block_access_list = lied_encoded_claim,
        .root_checks = roots(trie.empty_root_hash, trie.empty_root_hash, trie.empty_root_hash),
        .bal_differential = &lied_report,
    });
    try std.testing.expectEqual(block_stf.Status.transaction_rejected, lied_rejected.status);
    try std.testing.expectEqual(bal.DifferentialStatus.candidate_rejection_mismatch, lied_report.status);
    try std.testing.expectEqual(@as(?usize, 1), lied_report.tx_index);

    const blob_hashes = [_]u256{
        @as(u256, 0x01) << 248,
        (@as(u256, 0x01) << 248) | 1,
    };
    const oversized_blob_transactions = [_]block_stf.TransactionInput{.{
        .tx = .{
            .kind = .blob,
            .sender = sender,
            .to = sender,
            .gas_limit = 21_000,
            .max_fee_per_gas = 0,
            .max_priority_fee_per_gas = 0,
            .max_fee_per_blob_gas = 1,
            .blob_hashes = &blob_hashes,
        },
        .encoded = "oversized-amsterdam-blob",
    }};
    var blob_store = evmz.state.MemoryStore.init(std.testing.allocator);
    defer blob_store.deinit();
    const empty_claim = try bal.encodeAlloc(std.testing.allocator, &.{});
    defer std.testing.allocator.free(empty_claim);
    var blob_schedule = evmz.eth.transaction.Transaction.blobSchedule(.amsterdam).?;
    blob_schedule.max = 1;
    var blob_report = bal.Report{};
    const blob_rejected = try block_stf.applyAssumeDecoded(std.testing.allocator, .{
        .revision = .amsterdam,
        .env = .{
            .gas_limit = 21_000,
            .blob_base_fee = 1,
            .blob_schedule = blob_schedule,
        },
        .state_backend = blob_store.backend(),
        .transactions = &oversized_blob_transactions,
        .block_access_list = empty_claim,
        .root_checks = roots(trie.empty_root_hash, trie.empty_root_hash, trie.empty_root_hash),
        .bal_differential = &blob_report,
    });
    try std.testing.expectEqual(block_stf.Status.blob_gas_limit_exceeded, blob_rejected.status);
    try std.testing.expectEqual(@as(?usize, 0), blob_rejected.tx_index);
    try std.testing.expectEqual(bal.DifferentialStatus.rejection_matched, blob_report.status);
    try std.testing.expectEqual(@as(?usize, 0), blob_report.tx_index);
    try std.testing.expect(blob_store.getAccount(sender) == null);
}

fn blockInput(
    store: *evmz.state.MemoryStore,
    encoded_claim: ?[]const u8,
    root_checks: block_stf.RootChecks,
    report: ?*bal.Report,
) block_stf.AssumeDecodedBlockInput {
    return .{
        .revision = .amsterdam,
        .env = .{ .gas_limit = 2_000_000 },
        .state_backend = store.backend(),
        .transactions = &txs,
        .block_access_list = encoded_claim,
        .root_checks = root_checks,
        .bal_differential = report,
    };
}

fn roots(state_root: [32]u8, transactions_root: [32]u8, receipts_root: [32]u8) block_stf.RootChecks {
    return .{
        .payload_header = .{
            .state = .fromHash(state_root),
            .receipts = .fromHash(receipts_root),
        },
        .reconstructed_header = .{
            .transactions = .fromHash(transactions_root),
        },
    };
}

fn expectContainedMismatch(
    baseline: block_stf.Result,
    result: block_stf.Result,
    report: bal.Report,
    expected_differential: bal.DifferentialStatus,
) !void {
    try std.testing.expectEqual(block_stf.Status.block_access_list_mismatch, result.status);
    try std.testing.expectEqual(expected_differential, report.status);
    try std.testing.expectEqualSlices(u8, &baseline.state_root, &result.state_root);
    try std.testing.expectEqualSlices(u8, &baseline.receipts_root, &result.receipts_root);
    try std.testing.expectEqual(baseline.gas_used, result.gas_used);
    try std.testing.expectEqual(baseline.block_gas_used, result.block_gas_used);
}
