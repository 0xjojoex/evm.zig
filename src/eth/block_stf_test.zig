//! BlockSTF unit tests, split from `block_stf.zig` to keep the block
//! orchestration file focused. Tests drive the public exact-STF surface.

const std = @import("std");

const block_stf = @import("block_stf.zig");
const t = @import("../t.zig");
const address = @import("../address.zig");
const crypto = @import("../crypto.zig");
const eth_bal = @import("bal/model.zig");
const eip6110 = @import("eip/6110.zig");
const eip7002 = @import("eip/7002.zig");
const eip7251 = @import("eip/7251.zig");
const eip7685 = @import("eip/7685.zig");
const eip8282 = @import("eip/8282.zig");
const eth_spec = @import("spec.zig");
const eth_system = @import("system.zig");
const trie = @import("trie.zig");
const Withdrawal = @import("Withdrawal.zig");
const rlp = @import("rlp");
const state = @import("../state.zig");
const transaction = @import("../transaction.zig");
const trace = @import("../trace.zig");
const uint256 = @import("../uint256.zig");
const vm = @import("../vm.zig");
const Backend = @import("../backend.zig").Backend;

const Log = vm.Log;
const AssumeDecodedBlockInput = block_stf.AssumeDecodedBlockInput;
const DenseAmsterdam = block_stf.Bind(.amsterdam, vm.BalVm(eth_spec.amsterdam));
const FinalizeBlockContext = block_stf.FinalizeBlockContext;
const ObservationTarget = block_stf.ObservationTarget;
const empty_requests_hash = block_stf.empty_requests_hash;
const ParentBlobGas = block_stf.ParentBlobGas;
const ParentHeaderContext = block_stf.ParentHeaderContext;
const ReceiptPayload = block_stf.ReceiptPayload;
const RootChecks = block_stf.RootChecks;
const CommitOutput = @import("state_domain.zig").CommitOutput;
const Status = block_stf.Status;
const TransactionInput = block_stf.TransactionInput;
const encodeReceipt = block_stf.encodeReceipt;
const logsBloom = block_stf.logsBloom;
const requestsHash = block_stf.requestsHash;

const withdrawal_gwei_in_wei: u256 = 1_000_000_000;

fn testRootChecks(header_state: [32]u8, local_transactions: [32]u8, header_receipts: [32]u8) RootChecks {
    return .{
        .payload_header = .{
            .state = header_state,
            .receipts = header_receipts,
        },
        .reconstructed_header = .{
            .transactions = local_transactions,
        },
    };
}

fn testRootChecksWithWithdrawals(header_state: [32]u8, local_transactions: [32]u8, header_receipts: [32]u8, local_withdrawals: [32]u8) RootChecks {
    return .{
        .payload_header = .{
            .state = header_state,
            .receipts = header_receipts,
        },
        .reconstructed_header = .{
            .transactions = local_transactions,
            .withdrawals = local_withdrawals,
        },
    };
}

test "BlockSTF validates a single witnessed transaction" {
    const StfFrontier = t.BlockStf(.frontier) orelse return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const scratch = arena.allocator();

    const target = address.addr(0x1000);
    const code = [_]u8{
        0x60, 0x2a, // PUSH1 42
        0x60, 0x00, // PUSH1 0
        0x55, // SSTORE
        0x60, 0x99, // PUSH1 0x99
        0x60, 0x00, // PUSH1 0
        0x60, 0x00, // PUSH1 0
        0xa1, // LOG1
        0x00, // STOP
    };
    const code_hash = crypto.keccak256(&code);

    const account_key = trie.hashedAddressKey(target);
    const pre_account_value = try trie.accountValueFrom(scratch, .{
        .balance = 1_000_000,
        .code_hash = code_hash,
    });
    const state_node = try testLeafNode(scratch, &account_key, pre_account_value);
    const pre_state_root = crypto.keccak256(state_node);
    const nodes = [_][]const u8{state_node};
    const codes = [_][]const u8{&code};

    const tx_input = [_]TransactionInput{.{
        .tx = .{
            .sender = target,
            .to = target,
            .gas_limit = 100_000,
        },
        .encoded = "tx0",
    }};

    const storage_key = trie.hashedStorageKey(0);
    const storage_value = try trie.storageValue(scratch, 42);
    const post_storage_pairs = [_]trie.Pair{.{ .key = &storage_key, .value = storage_value }};
    const post_storage_root = try trie.root(scratch, &post_storage_pairs);
    const post_account_value = try trie.accountValueFrom(scratch, .{
        .nonce = 1,
        .balance = 1_000_000,
        .storage_root = post_storage_root,
        .code_hash = code_hash,
    });
    const post_state_pairs = [_]trie.Pair{.{ .key = &account_key, .value = post_account_value }};
    const expected_state_root = try trie.root(scratch, &post_state_pairs);

    const first_result = try StfFrontier.applyAssumeDecoded(scratch, .{
        .env = .{ .gas_limit = 100_000 },
        .state_backend = try Backend.fromWitness(scratch, pre_state_root, &nodes, &codes),
        .transactions = &tx_input,
        .root_checks = testRootChecks(
            expected_state_root,
            try trie.transactionRoot(scratch, &.{tx_input[0].encoded}),
            [_]u8{0xff} ** 32,
        ),
    });
    try std.testing.expectEqual(Status.receipts_root_mismatch, first_result.status);

    const receipt_topics = [_]u256{0x99};
    const receipt_log = Log{
        .address = target,
        .topics = &receipt_topics,
        .data = &.{},
    };
    var receipt_logs = try state.LogBuffer.fromLogs(scratch, &.{receipt_log});
    defer receipt_logs.deinit(scratch);
    const encoded_receipt = try encodeReceipt(scratch, .legacy, .{
        .status = .success,
        .cumulative_gas_used = first_result.gas_used,
        .logs = receipt_logs.view(),
    });
    const expected_receipts_root = try trie.receiptRoot(scratch, &.{encoded_receipt});
    const expected_logs_bloom = logsBloom(receipt_logs.view());
    try std.testing.expectEqualSlices(u8, &expected_receipts_root, &first_result.receipts_root);
    try std.testing.expectEqualSlices(u8, &expected_logs_bloom, &first_result.logs_bloom);

    const RuntimeTraceRecorder = struct {
        step_starts: usize = 0,
        step_ends: usize = 0,
        storage_writes: usize = 0,

        fn observationTarget(self: *@This()) ObservationTarget {
            return ObservationTarget.init(self, observe);
        }

        fn traceTarget(self: *@This()) trace.TraceSpanTarget {
            return trace.TraceSpanTarget.init(self, consumeTrace);
        }

        fn consumeTrace(ptr: *anyopaque, span: trace.TraceSpan) !void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            var cursor = trace.TraceCursor.init(span);
            while (try cursor.next()) |event| switch (event) {
                .step_start => self.step_starts += 1,
                .step_end => self.step_ends += 1,
                .frame_enter, .frame_leave => {},
            };
        }

        fn observe(
            ptr: *anyopaque,
            _: eth_bal.BlockAccessIndex,
            observations: state.TrackedState.ObservationsView,
        ) !void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            var index: u32 = 0;
            while (index < observations.storage.len()) : (index += 1) {
                if (observations.storage.metadataAt(index).effect.written) {
                    self.storage_writes += 1;
                }
            }
        }
    };
    var trace_recorder = RuntimeTraceRecorder{};
    var trace_tape = trace.TraceTape.initGrowable(scratch);
    defer trace_tape.deinit();

    const StfFrontierCapture = t.CaptureBlockStf(.frontier) orelse return error.SkipZigTest;
    const result = try StfFrontierCapture.applyAssumeDecoded(scratch, .{
        .env = .{ .gas_limit = 100_000 },
        .state_backend = try Backend.fromWitness(scratch, pre_state_root, &nodes, &codes),
        .transactions = &tx_input,
        .capture = .{
            .observations = trace_recorder.observationTarget(),
            .steps = .{
                .tape = &trace_tape,
                .profile = .{ .stack = .omitted },
                .target = trace_recorder.traceTarget(),
            },
        },
        .root_checks = testRootChecks(
            expected_state_root,
            try trie.transactionRoot(scratch, &.{tx_input[0].encoded}),
            first_result.receipts_root,
        ),
        .header_claims = .{
            .gas_used = first_result.gas_used,
            .block_gas_used = first_result.block_gas_used,
            .logs_bloom = expected_logs_bloom,
        },
    });

    try std.testing.expectEqual(Status.valid, result.status);
    try std.testing.expect(result.gas_used > 0);
    try std.testing.expectEqualSlices(u8, &expected_state_root, &result.state_root);
    try std.testing.expect(trace_recorder.step_starts > 0);
    try std.testing.expectEqual(trace_recorder.step_starts, trace_recorder.step_ends);
    try std.testing.expect(trace_recorder.storage_writes > 0);

    var commit_output: CommitOutput = .{};
    defer commit_output.deinit();
    const retained = try StfFrontier.applyAssumeDecoded(scratch, .{
        .env = .{ .gas_limit = 100_000 },
        .state_backend = try Backend.fromWitness(scratch, pre_state_root, &nodes, &codes),
        .commit_output = &commit_output,
        .transactions = &tx_input,
        .root_checks = testRootChecks(
            expected_state_root,
            try trie.transactionRoot(scratch, &.{tx_input[0].encoded}),
            first_result.receipts_root,
        ),
        .header_claims = .{
            .gas_used = first_result.gas_used,
            .block_gas_used = first_result.block_gas_used,
            .logs_bloom = expected_logs_bloom,
        },
    });
    try std.testing.expectEqual(Status.valid, retained.status);
    try std.testing.expect(commit_output.delta.?.view().hasChanges());
    const post_state_nodes = &commit_output.mpt_nodes.?;
    try std.testing.expect(post_state_nodes.len() > 0);
    const root_update = post_state_nodes.at(post_state_nodes.len() - 1);
    try std.testing.expectEqualSlices(u8, &expected_state_root, &root_update.digest);
    try std.testing.expectEqualSlices(
        u8,
        &root_update.digest,
        &crypto.keccak256(root_update.bytes),
    );

    const gas_mismatch = try StfFrontier.applyAssumeDecoded(scratch, .{
        .env = .{ .gas_limit = 100_000 },
        .state_backend = try Backend.fromWitness(scratch, pre_state_root, &nodes, &codes),
        .commit_output = &commit_output,
        .transactions = &tx_input,
        .root_checks = testRootChecks(
            expected_state_root,
            try trie.transactionRoot(scratch, &.{tx_input[0].encoded}),
            first_result.receipts_root,
        ),
        .header_claims = .{ .gas_used = first_result.gas_used + 1 },
    });
    try std.testing.expectEqual(Status.gas_used_mismatch, gas_mismatch.status);
    try std.testing.expect(commit_output.delta == null);
    try std.testing.expect(commit_output.mpt_nodes == null);

    const block_gas_mismatch = try StfFrontier.applyAssumeDecoded(scratch, .{
        .env = .{ .gas_limit = 100_000 },
        .state_backend = try Backend.fromWitness(scratch, pre_state_root, &nodes, &codes),
        .transactions = &tx_input,
        .root_checks = testRootChecks(
            expected_state_root,
            try trie.transactionRoot(scratch, &.{tx_input[0].encoded}),
            first_result.receipts_root,
        ),
        .header_claims = .{ .block_gas_used = first_result.block_gas_used + 1 },
    });
    try std.testing.expectEqual(Status.block_gas_used_mismatch, block_gas_mismatch.status);

    const logs_bloom_mismatch = try StfFrontier.applyAssumeDecoded(scratch, .{
        .env = .{ .gas_limit = 100_000 },
        .state_backend = try Backend.fromWitness(scratch, pre_state_root, &nodes, &codes),
        .transactions = &tx_input,
        .root_checks = testRootChecks(
            expected_state_root,
            try trie.transactionRoot(scratch, &.{tx_input[0].encoded}),
            first_result.receipts_root,
        ),
        .header_claims = .{ .logs_bloom = [_]u8{0xff} ** 256 },
    });
    try std.testing.expectEqual(Status.logs_bloom_mismatch, logs_bloom_mismatch.status);
}

test "BlockSTF stores PREVRANDAO as EVM word" {
    const StfMerge = t.BlockStf(.merge) orelse return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const scratch = arena.allocator();

    const sender = address.addr(0x1100);
    const sender_key = trie.hashedAddressKey(sender);
    const sender_account_value = try trie.accountValueFrom(scratch, .{ .balance = 1_000_000 });
    const state_node = try testLeafNode(scratch, &sender_key, sender_account_value);
    const pre_state_root = crypto.keccak256(state_node);
    const nodes = [_][]const u8{state_node};

    const init_code = [_]u8{
        0x44, // PREVRANDAO
        0x60, 0x00, // PUSH1 0
        0x55, // SSTORE
        0x00, // STOP
    };
    const tx_input = [_]TransactionInput{.{
        .tx = .{
            .kind = .legacy,
            .sender = sender,
            .nonce = 0,
            .gas_limit = 100_000,
            .to = null,
            .input = &init_code,
        },
        .encoded = "create-prevrandao",
    }};

    var randao_bytes = [_]u8{0} ** 32;
    randao_bytes[0] = 0x01;
    randao_bytes[31] = 0x02;
    const prev_randao = std.mem.readInt(u256, &randao_bytes, .big);
    const storage_key = trie.hashedStorageKey(0);
    const storage_value = try trie.storageValue(scratch, prev_randao);
    const storage_pairs = [_]trie.Pair{.{ .key = &storage_key, .value = storage_value }};
    const created_storage_root = try trie.root(scratch, &storage_pairs);

    const created = address.create(sender, 0);
    const created_key = trie.hashedAddressKey(created);
    const post_sender_account = try trie.accountValueFrom(scratch, .{
        .nonce = 1,
        .balance = 1_000_000,
    });
    const post_created_account = try trie.accountValueFrom(scratch, .{
        .nonce = 1,
        .storage_root = created_storage_root,
    });
    const post_state_pairs = [_]trie.Pair{
        .{ .key = &sender_key, .value = post_sender_account },
        .{ .key = &created_key, .value = post_created_account },
    };
    const expected_state_root = try trie.root(scratch, &post_state_pairs);

    const first_result = try StfMerge.applyAssumeDecoded(scratch, .{
        .env = .{ .gas_limit = 100_000, .prev_randao = prev_randao },
        .state_backend = try Backend.fromWitness(scratch, pre_state_root, &nodes, &.{}),
        .transactions = &tx_input,
        .root_checks = testRootChecks(
            expected_state_root,
            try trie.transactionRoot(scratch, &.{tx_input[0].encoded}),
            [_]u8{0xff} ** 32,
        ),
    });
    try std.testing.expectEqual(Status.receipts_root_mismatch, first_result.status);

    const result = try StfMerge.applyAssumeDecoded(scratch, .{
        .env = .{ .gas_limit = 100_000, .prev_randao = prev_randao },
        .state_backend = try Backend.fromWitness(scratch, pre_state_root, &nodes, &.{}),
        .transactions = &tx_input,
        .root_checks = testRootChecks(
            expected_state_root,
            try trie.transactionRoot(scratch, &.{tx_input[0].encoded}),
            first_result.receipts_root,
        ),
        .header_claims = .{ .gas_used = first_result.gas_used },
    });

    try std.testing.expectEqual(Status.valid, result.status);
    try std.testing.expectEqualSlices(u8, &expected_state_root, &result.state_root);
}

test "BlockSTF reports root mismatches and invalid witness" {
    const StfFrontier = t.BlockStf(.frontier) orelse return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const scratch = arena.allocator();

    const target = address.addr(0x2000);
    const account_key = trie.hashedAddressKey(target);
    const account_value = try trie.accountValueFrom(scratch, .{ .balance = 1_000_000 });
    const state_node = try testLeafNode(scratch, &account_key, account_value);
    const pre_state_root = crypto.keccak256(state_node);
    const nodes = [_][]const u8{state_node};
    const tx_input = [_]TransactionInput{.{
        .tx = .{ .sender = target, .to = target, .gas_limit = 21_000 },
        .encoded = "tx0",
    }};

    const mismatch = try StfFrontier.applyAssumeDecoded(scratch, .{
        .env = .{ .gas_limit = 21_000 },
        .state_backend = try Backend.fromWitness(scratch, pre_state_root, &nodes, &.{}),
        .transactions = &tx_input,
        .root_checks = testRootChecks(
            [_]u8{0xff} ** 32,
            try trie.transactionRoot(scratch, &.{tx_input[0].encoded}),
            [_]u8{0xff} ** 32,
        ),
    });
    try std.testing.expectEqual(Status.state_root_mismatch, mismatch.status);

    const invalid = try StfFrontier.applyAssumeDecoded(scratch, .{
        .env = .{ .gas_limit = 21_000 },
        .state_backend = try Backend.fromWitness(scratch, pre_state_root, &.{}, &.{}),
        .transactions = &tx_input,
        .root_checks = testRootChecks(
            pre_state_root,
            try trie.transactionRoot(scratch, &.{tx_input[0].encoded}),
            trie.empty_root_hash,
        ),
    });
    try std.testing.expectEqual(Status.invalid_witness, invalid.status);
    try std.testing.expectEqual(@as(?usize, 0), invalid.tx_index);
}

test "BlockSTF receipt ownership survives a later trace-consumer error" {
    const StfAmsterdam = t.CaptureBlockStf(.amsterdam) orelse return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const scratch = arena.allocator();

    const target = address.addr(0x2000);
    const account_key = trie.hashedAddressKey(target);
    const account_value = try trie.accountValueFrom(scratch, .{ .balance = 1_000_000 });
    const state_node = try testLeafNode(scratch, &account_key, account_value);
    const pre_state_root = crypto.keccak256(state_node);
    const nodes = [_][]const u8{state_node};
    const tx_input = [_]TransactionInput{.{
        .tx = .{ .sender = target, .to = target, .gas_limit = 21_000 },
        .encoded = "tx0",
    }};

    const FailingTraceConsumer = struct {
        fn consume(_: *anyopaque, _: trace.TraceSpan) !void {
            return error.TestTraceConsumerFailure;
        }
    };
    var target_context: u8 = 0;
    var tape = trace.TraceTape.initGrowable(std.testing.allocator);
    defer tape.deinit();

    try std.testing.expectError(
        error.TestTraceConsumerFailure,
        StfAmsterdam.applyAssumeDecoded(std.testing.allocator, .{
            .env = .{ .gas_limit = 21_000 },
            .state_backend = try Backend.fromWitness(
                std.testing.allocator,
                pre_state_root,
                &nodes,
                &.{},
            ),
            .transactions = &tx_input,
            .capture = .{ .steps = .{
                .tape = &tape,
                .target = trace.TraceSpanTarget.init(&target_context, FailingTraceConsumer.consume),
            } },
            .root_checks = testRootChecks(
                trie.empty_root_hash,
                trie.empty_root_hash,
                trie.empty_root_hash,
            ),
        }),
    );
}

test "BlockSTF validates withdrawals root" {
    const StfAmsterdam = t.BlockStf(.amsterdam) orelse return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const scratch = arena.allocator();

    const withdrawals = [_]Withdrawal{
        .{
            .index = 1,
            .validator_index = 2,
            .address = address.addr(0x1000),
            .amount = 3,
        },
        .{
            .index = 4,
            .validator_index = 5,
            .address = address.addr(0x2000),
            .amount = 6,
        },
    };
    const expected_withdrawals_root = try trie.withdrawalsRoot(scratch, &withdrawals);
    const account0_key = trie.hashedAddressKey(withdrawals[0].address);
    const account0_value = try trie.accountValueFrom(scratch, .{ .balance = withdrawals[0].amount * withdrawal_gwei_in_wei });
    const account1_key = trie.hashedAddressKey(withdrawals[1].address);
    const account1_value = try trie.accountValueFrom(scratch, .{ .balance = withdrawals[1].amount * withdrawal_gwei_in_wei });
    const expected_state_pairs = [_]trie.Pair{
        .{ .key = &account0_key, .value = account0_value },
        .{ .key = &account1_key, .value = account1_value },
    };
    const expected_state_root = try trie.root(scratch, &expected_state_pairs);

    const result = try StfAmsterdam.applyAssumeDecoded(scratch, .{
        .state_backend = try Backend.fromWitness(scratch, trie.empty_root_hash, &.{}, &.{}),
        .transactions = &.{},
        .withdrawals = &withdrawals,
        .root_checks = testRootChecksWithWithdrawals(
            expected_state_root,
            trie.empty_root_hash,
            trie.empty_root_hash,
            expected_withdrawals_root,
        ),
    });

    try std.testing.expectEqual(Status.valid, result.status);
    try std.testing.expectEqualSlices(u8, &expected_withdrawals_root, &result.withdrawals_root);

    const mismatch = try StfAmsterdam.applyAssumeDecoded(scratch, .{
        .state_backend = try Backend.fromWitness(scratch, trie.empty_root_hash, &.{}, &.{}),
        .transactions = &.{},
        .withdrawals = &withdrawals,
        .root_checks = testRootChecksWithWithdrawals(
            expected_state_root,
            trie.empty_root_hash,
            trie.empty_root_hash,
            [_]u8{0xff} ** 32,
        ),
    });
    try std.testing.expectEqual(Status.withdrawals_root_mismatch, mismatch.status);
}

test "BlockSTF coalesces withdrawal balance changes at the post-transaction BAL index" {
    const StfAmsterdam = t.BlockStf(.amsterdam) orelse return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const scratch = arena.allocator();

    const recipient_a = address.addr(0x7777);
    const recipient_b = address.addr(0x8888);
    const withdrawals = [_]Withdrawal{
        .{ .index = 0, .validator_index = 1, .address = recipient_a, .amount = 0 },
        .{ .index = 1, .validator_index = 2, .address = recipient_a, .amount = 3 },
        .{ .index = 2, .validator_index = 3, .address = recipient_b, .amount = 0 },
    };

    const credited_balance = 3 * withdrawal_gwei_in_wei;
    const account_key = trie.hashedAddressKey(recipient_a);
    const account_value = try trie.accountValueFrom(scratch, .{ .balance = credited_balance });
    const expected_state_root = try trie.root(scratch, &.{.{ .key = &account_key, .value = account_value }});
    const expected_withdrawals_root = try trie.withdrawalsRoot(scratch, &withdrawals);
    const balance_changes = [_]eth_bal.BalanceChange{.{
        .block_access_index = 1,
        .post_balance = credited_balance,
    }};
    const claim = try eth_bal.encodeAlloc(scratch, &.{
        .{ .address = recipient_a, .balance_changes = &balance_changes },
        .{ .address = recipient_b },
    });

    const result = try StfAmsterdam.applyAssumeDecoded(scratch, .{
        .state_backend = try Backend.fromWitness(scratch, trie.empty_root_hash, &.{}, &.{}),
        .transactions = &.{},
        .withdrawals = &withdrawals,
        .block_access_list = claim,
        .root_checks = testRootChecksWithWithdrawals(
            expected_state_root,
            trie.empty_root_hash,
            trie.empty_root_hash,
            expected_withdrawals_root,
        ),
    });
    try std.testing.expectEqual(Status.valid, result.status);
}

test "BlockSTF applies Cancun block-start system contract" {
    const StfCancun = t.BlockStf(.cancun) orelse return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const scratch = arena.allocator();

    const beacon_address = eth_system.beacon_roots_address;
    var beacon_code_buf: [97]u8 = undefined;
    const beacon_code = try std.fmt.hexToBytes(
        &beacon_code_buf,
        "3373fffffffffffffffffffffffffffffffffffffffe14604d57602036146024575f5ffd5b5f35801560495762001fff810690815414603c575f5ffd5b62001fff01545f5260205ff35b5f5ffd5b62001fff42064281555f359062001fff015500",
    );
    const beacon_code_hash = crypto.keccak256(beacon_code);

    const account_key = trie.hashedAddressKey(beacon_address);
    const pre_account_value = try trie.accountValueFrom(scratch, .{ .code_hash = beacon_code_hash });
    const state_node = try testLeafNode(scratch, &account_key, pre_account_value);
    const pre_state_root = crypto.keccak256(state_node);
    const nodes = [_][]const u8{state_node};
    const codes = [_][]const u8{beacon_code};

    var parent_beacon_root = [_]u8{0} ** 32;
    parent_beacon_root[31] = 0xbb;
    const timestamp: u64 = 12;
    const timestamp_key = trie.hashedStorageKey(timestamp);
    const root_key = trie.hashedStorageKey(8191 + timestamp);
    const timestamp_value = try trie.storageValue(scratch, timestamp);
    const root_value = try trie.storageValue(scratch, std.mem.readInt(u256, &parent_beacon_root, .big));
    const post_storage_pairs = [_]trie.Pair{
        .{ .key = &timestamp_key, .value = timestamp_value },
        .{ .key = &root_key, .value = root_value },
    };
    const post_storage_root = try trie.root(scratch, &post_storage_pairs);
    const post_account_value = try trie.accountValueFrom(scratch, .{
        .storage_root = post_storage_root,
        .code_hash = beacon_code_hash,
    });
    const post_state_pairs = [_]trie.Pair{.{ .key = &account_key, .value = post_account_value }};
    const expected_state_root = try trie.root(scratch, &post_state_pairs);
    const parent_hash = [_]u8{0x11} ** 32;

    const result = try StfCancun.applyAssumeDecoded(scratch, .{
        .env = .{ .number = 1, .timestamp = timestamp, .gas_limit = 30_000_000 },
        .block_header = .{
            .number = 1,
            .timestamp = timestamp,
            .parent_hash = parent_hash,
            .parent_beacon_block_root = parent_beacon_root,
        },
        .state_backend = try Backend.fromWitness(scratch, pre_state_root, &nodes, &codes),
        .transactions = &.{},
        .parent_header = .{
            .hash = parent_hash,
            .number = 0,
            .timestamp = 0,
            .gas_limit = 30_000_000,
            .gas_used = 0,
            .base_fee_per_gas = 0,
        },
        .root_checks = testRootChecks(expected_state_root, trie.empty_root_hash, trie.empty_root_hash),
    });
    try std.testing.expectEqual(Status.valid, result.status);
    try std.testing.expectEqualSlices(u8, &expected_state_root, &result.state_root);
}

test "BlockSTF rejects missing or inconsistent parent context" {
    const StfCancun = t.BlockStf(.cancun) orelse return error.SkipZigTest;
    const missing = try StfCancun.applyAssumeDecoded(std.testing.allocator, .{
        .env = .{ .number = 1, .timestamp = 2 },
        .state_backend = try Backend.fromWitness(std.testing.allocator, trie.empty_root_hash, &.{}, &.{}),
        .transactions = &.{},
        .root_checks = testRootChecks(trie.empty_root_hash, trie.empty_root_hash, trie.empty_root_hash),
    });
    try std.testing.expectEqual(Status.parent_header_mismatch, missing.status);

    const parent_hash = [_]u8{0x11} ** 32;
    const inconsistent = try StfCancun.applyAssumeDecoded(std.testing.allocator, .{
        .env = .{ .number = 1, .timestamp = 2, .gas_limit = 30_000_000 },
        .block_header = .{
            .number = 1,
            .timestamp = 3,
            .parent_hash = parent_hash,
            .parent_beacon_block_root = [_]u8{0} ** 32,
        },
        .state_backend = try Backend.fromWitness(std.testing.allocator, trie.empty_root_hash, &.{}, &.{}),
        .transactions = &.{},
        .parent_header = .{
            .hash = parent_hash,
            .number = 0,
            .timestamp = 0,
            .gas_limit = 30_000_000,
            .gas_used = 0,
            .base_fee_per_gas = 0,
        },
        .root_checks = testRootChecks(trie.empty_root_hash, trie.empty_root_hash, trie.empty_root_hash),
    });
    try std.testing.expectEqual(Status.timestamp_mismatch, inconsistent.status);
}

test "BlockSTF rejects a nonempty requests hash claim against an empty block" {
    const StfAmsterdam = t.BlockStf(.amsterdam) orelse return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const scratch = arena.allocator();

    const result = try StfAmsterdam.applyAssumeDecoded(scratch, .{
        .state_backend = try Backend.fromWitness(scratch, trie.empty_root_hash, &.{}, &.{}),
        .transactions = &.{},
        .root_checks = testRootChecks(trie.empty_root_hash, trie.empty_root_hash, trie.empty_root_hash),
        .header_claims = .{ .requests_hash = empty_requests_hash },
    });
    try std.testing.expectEqual(Status.valid, result.status);
    try std.testing.expectEqualSlices(u8, &empty_requests_hash, &result.requests_hash);

    const claimed_request = try eip7685.requestBytes(scratch, eip6110.request_type, &.{0xbb});
    const claimed_requests = [_][]const u8{claimed_request};
    const claimed_requests_hash = try requestsHash(scratch, &claimed_requests);
    const mismatch = try StfAmsterdam.applyAssumeDecoded(scratch, .{
        .state_backend = try Backend.fromWitness(scratch, trie.empty_root_hash, &.{}, &.{}),
        .transactions = &.{},
        .root_checks = testRootChecks(trie.empty_root_hash, trie.empty_root_hash, trie.empty_root_hash),
        .header_claims = .{ .requests_hash = claimed_requests_hash },
    });
    try std.testing.expectEqual(Status.requests_hash_mismatch, mismatch.status);
}

test "Amsterdam finalize calls include builder request predeploys" {
    const context = FinalizeBlockContext{
        .number = 1,
        .timestamp = 0,
        .transaction_count = 0,
        .gas_used = 0,
        .block_gas = 0,
        .state_gas = 0,
    };
    const calls = eth_spec.amsterdam.block.finalizeBlock(context);

    try std.testing.expectEqual(@as(usize, 4), calls.len);
    try std.testing.expectEqual(eth_system.withdrawal_request_predeploy_address, calls.items[0].call.recipient);
    try std.testing.expectEqual(eip7002.request_type, calls.items[0].output_prefix);
    try std.testing.expect(calls.items[0].call.require_code);

    try std.testing.expectEqual(eth_system.consolidation_request_predeploy_address, calls.items[1].call.recipient);
    try std.testing.expectEqual(eip7251.request_type, calls.items[1].output_prefix);
    try std.testing.expect(calls.items[1].call.require_code);

    try std.testing.expectEqual(eth_system.builder_deposit_request_predeploy_address, calls.items[2].call.recipient);
    try std.testing.expectEqual(eip8282.builder_deposit_request_type, calls.items[2].output_prefix);
    try std.testing.expect(calls.items[2].call.require_code);

    try std.testing.expectEqual(eth_system.builder_exit_request_predeploy_address, calls.items[3].call.recipient);
    try std.testing.expectEqual(eip8282.builder_exit_request_type, calls.items[3].output_prefix);
    try std.testing.expect(calls.items[3].call.require_code);
}

test "BlockSTF reconstructs Amsterdam header and makes block hash mismatch reachable" {
    const StfAmsterdam = t.BlockStf(.amsterdam) orelse return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const scratch = arena.allocator();

    const zero_hash = [_]u8{0} ** 32;
    const input = AssumeDecodedBlockInput{
        .env = .{
            .number = 0,
            .slot_number = 0,
            .timestamp = 0,
            .gas_limit = 30_000_000,
            .base_fee = 7,
        },
        .state_backend = try Backend.fromWitness(scratch, trie.empty_root_hash, &.{}, &.{}),
        .transactions = &.{},
        .parent_blob_gas = .{
            .parent_excess_blob_gas = 0,
            .parent_blob_gas_used = 0,
            .parent_base_fee_per_gas = 7,
        },
        .root_checks = testRootChecks(trie.empty_root_hash, trie.empty_root_hash, trie.empty_root_hash),
        .header_hash_claim = .{
            .block_hash = zero_hash,
            .parent_hash = zero_hash,
            .parent_beacon_block_root = zero_hash,
            .extra_data = &.{},
        },
    };

    const mismatch = try StfAmsterdam.applyAssumeDecoded(scratch, input);
    try std.testing.expectEqual(Status.block_hash_mismatch, mismatch.status);
    try std.testing.expect(!std.mem.eql(u8, &zero_hash, &mismatch.block_hash));

    var valid_input = input;
    valid_input.header_hash_claim.?.block_hash = mismatch.block_hash;
    const valid = try StfAmsterdam.applyAssumeDecoded(scratch, valid_input);
    try std.testing.expectEqual(Status.valid, valid.status);
    try std.testing.expectEqualSlices(u8, &mismatch.block_hash, &valid.block_hash);
}

test "BlockSTF compares derived block access list artifact and hash claims" {
    const StfAmsterdam = t.BlockStf(.amsterdam) orelse return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const scratch = arena.allocator();

    const empty_bal: []const eth_bal.AccountChanges = &.{};
    const empty_claim = try eth_bal.encodeAlloc(scratch, empty_bal);
    const valid = try StfAmsterdam.applyAssumeDecoded(scratch, .{
        .state_backend = try Backend.fromWitness(scratch, trie.empty_root_hash, &.{}, &.{}),
        .transactions = &.{},
        .block_access_list = empty_claim,
        .root_checks = testRootChecks(trie.empty_root_hash, trie.empty_root_hash, trie.empty_root_hash),
        .header_claims = .{ .block_access_list_hash = eth_bal.empty_hash },
    });
    try std.testing.expectEqual(Status.valid, valid.status);
    try std.testing.expectEqualSlices(u8, &eth_bal.empty_hash, &valid.block_access_list_hash);

    const phantom_accounts = [_]eth_bal.AccountChanges{.{ .address = address.addr(0xbeef) }};
    const phantom_claim = try eth_bal.encodeAlloc(scratch, &phantom_accounts);
    const artifact_mismatch = try StfAmsterdam.applyAssumeDecoded(scratch, .{
        .state_backend = try Backend.fromWitness(scratch, trie.empty_root_hash, &.{}, &.{}),
        .transactions = &.{},
        .block_access_list = phantom_claim,
        .root_checks = testRootChecks(trie.empty_root_hash, trie.empty_root_hash, trie.empty_root_hash),
    });
    try std.testing.expectEqual(Status.block_access_list_mismatch, artifact_mismatch.status);

    const hash_mismatch = try StfAmsterdam.applyAssumeDecoded(scratch, .{
        .state_backend = try Backend.fromWitness(scratch, trie.empty_root_hash, &.{}, &.{}),
        .transactions = &.{},
        .block_access_list = empty_claim,
        .root_checks = testRootChecks(trie.empty_root_hash, trie.empty_root_hash, trie.empty_root_hash),
        .header_claims = .{ .block_access_list_hash = [_]u8{0xff} ** 32 },
    });
    try std.testing.expectEqual(Status.block_access_list_hash_mismatch, hash_mismatch.status);

    const malformed_claim = try StfAmsterdam.applyAssumeDecoded(scratch, .{
        .state_backend = try Backend.fromWitness(scratch, trie.empty_root_hash, &.{}, &.{}),
        .transactions = &.{},
        .block_access_list = &.{0xff},
        .root_checks = testRootChecks(trie.empty_root_hash, trie.empty_root_hash, trie.empty_root_hash),
    });
    try std.testing.expectEqual(Status.malformed_block_access_list, malformed_claim.status);

    const oversized_claim = try StfAmsterdam.applyAssumeDecoded(scratch, .{
        .env = .{ .gas_limit = 1 },
        .state_backend = try Backend.fromWitness(scratch, trie.empty_root_hash, &.{}, &.{}),
        .transactions = &.{},
        .block_access_list = phantom_claim,
        .root_checks = testRootChecks(trie.empty_root_hash, trie.empty_root_hash, trie.empty_root_hash),
    });
    try std.testing.expectEqual(Status.block_access_list_too_large, oversized_claim.status);

    const excessive_gas_transactions = [_]TransactionInput{.{
        .tx = .{ .sender = .zero, .gas_limit = 2 },
        .encoded = "tx0",
    }};
    const excessive_gas = try StfAmsterdam.applyAssumeDecoded(scratch, .{
        .env = .{ .gas_limit = 1 },
        .state_backend = try Backend.fromWitness(scratch, trie.empty_root_hash, &.{}, &.{}),
        .transactions = &excessive_gas_transactions,
        .block_access_list = phantom_claim,
        .root_checks = testRootChecks(trie.empty_root_hash, trie.empty_root_hash, trie.empty_root_hash),
    });
    try std.testing.expectEqual(Status.block_gas_exceeded, excessive_gas.status);
    try std.testing.expectEqual(@as(?usize, 0), excessive_gas.tx_index);
}

test "dense BlockSTF classifies missing and spurious BAL coverage as mismatch" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const scratch = arena.allocator();

    const empty_claim = try eth_bal.encodeAlloc(scratch, &.{});
    const withdrawal = Withdrawal{
        .index = 0,
        .validator_index = 0,
        .address = address.addr(0x1000),
        .amount = 0,
    };
    const withdrawals = [_]Withdrawal{withdrawal};
    const missing_account = try DenseAmsterdam.applyAssumeDecoded(scratch, .{
        .state_backend = try DenseAmsterdam.Vm.StateDomain.Lifecycle.witnessBackend(
            scratch,
            trie.empty_root_hash,
            &.{},
            &.{},
        ),
        .transactions = &.{},
        .withdrawals = &withdrawals,
        .block_access_list = empty_claim,
        .root_checks = testRootChecksWithWithdrawals(
            trie.empty_root_hash,
            trie.empty_root_hash,
            trie.empty_root_hash,
            try trie.withdrawalsRoot(scratch, &withdrawals),
        ),
    });
    try std.testing.expectEqual(Status.block_access_list_mismatch, missing_account.status);

    const sender = address.addr(0x2000);
    const account_key = trie.hashedAddressKey(sender);
    const account_value = try trie.accountValueFrom(scratch, .{ .balance = 1_000_000 });
    const account_node = try testLeafNode(scratch, &account_key, account_value);
    const state_root = crypto.keccak256(account_node);
    const created = address.create(sender, 0);
    var account_claims = [_]eth_bal.AccountChanges{
        .{ .address = sender },
        .{ .address = created },
    };
    if (address.Address.order(account_claims[0].address, account_claims[1].address) == .gt)
        std.mem.swap(eth_bal.AccountChanges, &account_claims[0], &account_claims[1]);
    const account_claim = try eth_bal.encodeAlloc(scratch, &account_claims);
    const init_code = [_]u8{ 0x5f, 0x54, 0x50, 0x00 }; // PUSH0 SLOAD POP STOP
    const transaction_input = [_]TransactionInput{.{
        .tx = .{
            .kind = .legacy,
            .sender = sender,
            .gas_limit = 100_000,
            .to = null,
            .input = &init_code,
        },
        .encoded = "tx0",
    }};
    const missing_storage = try DenseAmsterdam.applyAssumeDecoded(scratch, .{
        .env = .{ .gas_limit = 100_000 },
        .state_backend = try DenseAmsterdam.Vm.StateDomain.Lifecycle.witnessBackend(
            scratch,
            state_root,
            &.{account_node},
            &.{},
        ),
        .transactions = &transaction_input,
        .block_access_list = account_claim,
        .root_checks = testRootChecks(
            state_root,
            try trie.transactionRoot(scratch, &.{transaction_input[0].encoded}),
            trie.empty_root_hash,
        ),
    });
    try std.testing.expectEqual(Status.block_access_list_mismatch, missing_storage.status);

    const spurious_account_claim = try eth_bal.encodeAlloc(scratch, &.{.{
        .address = address.addr(0x3000),
    }});
    const spurious_account = try DenseAmsterdam.applyAssumeDecoded(scratch, .{
        .state_backend = try DenseAmsterdam.Vm.StateDomain.Lifecycle.witnessBackend(
            scratch,
            trie.empty_root_hash,
            &.{},
            &.{},
        ),
        .transactions = &.{},
        .block_access_list = spurious_account_claim,
        .root_checks = testRootChecks(trie.empty_root_hash, trie.empty_root_hash, trie.empty_root_hash),
    });
    try std.testing.expectEqual(Status.block_access_list_mismatch, spurious_account.status);

    const spurious_slot = [_]u256{7};
    const spurious_storage_claim = try eth_bal.encodeAlloc(scratch, &.{.{
        .address = address.addr(0x4000),
        .storage_reads = &spurious_slot,
    }});
    const spurious_storage = try DenseAmsterdam.applyAssumeDecoded(scratch, .{
        .state_backend = try DenseAmsterdam.Vm.StateDomain.Lifecycle.witnessBackend(
            scratch,
            trie.empty_root_hash,
            &.{},
            &.{},
        ),
        .transactions = &.{},
        .block_access_list = spurious_storage_claim,
        .root_checks = testRootChecks(trie.empty_root_hash, trie.empty_root_hash, trie.empty_root_hash),
    });
    try std.testing.expectEqual(Status.block_access_list_mismatch, spurious_storage.status);
}

test "BlockSTF records zero withdrawals as block access list accesses" {
    const StfAmsterdam = t.BlockStf(.amsterdam) orelse return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const scratch = arena.allocator();

    const withdrawal = Withdrawal{
        .index = 1,
        .validator_index = 2,
        .address = address.addr(0x7777),
        .amount = 0,
    };
    const withdrawals = [_]Withdrawal{withdrawal};
    const expected_withdrawals_root = try trie.withdrawalsRoot(scratch, &withdrawals);
    const claimed_accounts = [_]eth_bal.AccountChanges{.{ .address = withdrawal.address }};
    const claimed_bal = try eth_bal.encodeAlloc(scratch, &claimed_accounts);

    const result = try StfAmsterdam.applyAssumeDecoded(scratch, .{
        .state_backend = try Backend.fromWitness(scratch, trie.empty_root_hash, &.{}, &.{}),
        .transactions = &.{},
        .withdrawals = &withdrawals,
        .block_access_list = claimed_bal,
        .root_checks = testRootChecksWithWithdrawals(
            trie.empty_root_hash,
            trie.empty_root_hash,
            trie.empty_root_hash,
            expected_withdrawals_root,
        ),
    });

    try std.testing.expectEqual(Status.valid, result.status);
}

test "BlockSTF validates blob gas header fields" {
    const StfPrague = t.BlockStf(.prague) orelse return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const scratch = arena.allocator();

    const sender = address.addr(0x4000);
    const blob_hashes = [_]u256{
        @as(u256, 0x01) << 248,
        (@as(u256, 0x01) << 248) | 1,
    };
    const prague_schedule = eth_spec.prague.transaction.blob_schedule.?;
    const expected_blob_gas_used: u64 = 2 * prague_schedule.gas_per_blob;
    const starting_balance: u256 = 1_000_000;

    const account_key = trie.hashedAddressKey(sender);
    const pre_account_value = try trie.accountValueFrom(scratch, .{ .balance = starting_balance });
    const state_node = try testLeafNode(scratch, &account_key, pre_account_value);
    const pre_state_root = crypto.keccak256(state_node);
    const nodes = [_][]const u8{state_node};
    const tx_input = [_]TransactionInput{.{
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
        .encoded = "blobtx0",
    }};

    const post_account_value = try trie.accountValueFrom(scratch, .{
        .nonce = 1,
        .balance = starting_balance - expected_blob_gas_used,
    });
    const post_state_pairs = [_]trie.Pair{.{ .key = &account_key, .value = post_account_value }};
    const expected_state_root = try trie.root(scratch, &post_state_pairs);
    const expected_transactions_root = try trie.transactionRoot(scratch, &.{tx_input[0].encoded});
    const parent_blob_gas = ParentBlobGas{
        .parent_excess_blob_gas = 786_432,
        .parent_blob_gas_used = 786_432,
        .parent_base_fee_per_gas = 1_000_000,
    };
    const blob_schedule = vm.Vm(eth_spec.prague).spec.transaction.blob_schedule.?;
    const expected_excess_blob_gas = blob_schedule.calcExcessBlobGasForSchedule(parent_blob_gas).?;
    const custom_blob_params = transaction.BlobParams{
        .target = 10,
        .max = 12,
        .base_fee_update_fraction = prague_schedule.base_fee_update_fraction,
    };
    const expected_custom_excess_blob_gas = prague_schedule.withParams(custom_blob_params).calcExcessBlobGasForSchedule(parent_blob_gas).?;

    const first_result = try StfPrague.applyAssumeDecoded(scratch, .{
        .env = .{ .gas_limit = 21_000, .blob_base_fee = 1 },
        .state_backend = try Backend.fromWitness(scratch, pre_state_root, &nodes, &.{}),
        .transactions = &tx_input,
        .parent_blob_gas = parent_blob_gas,
        .root_checks = testRootChecks(
            expected_state_root,
            expected_transactions_root,
            [_]u8{0xff} ** 32,
        ),
    });
    try std.testing.expectEqual(Status.receipts_root_mismatch, first_result.status);
    try std.testing.expectEqual(expected_blob_gas_used, first_result.blob_gas_used);
    try std.testing.expectEqual(expected_excess_blob_gas, first_result.excess_blob_gas.?);

    const result = try StfPrague.applyAssumeDecoded(scratch, .{
        .env = .{ .gas_limit = 21_000, .blob_base_fee = 1 },
        .state_backend = try Backend.fromWitness(scratch, pre_state_root, &nodes, &.{}),
        .transactions = &tx_input,
        .parent_blob_gas = parent_blob_gas,
        .root_checks = testRootChecks(
            expected_state_root,
            expected_transactions_root,
            first_result.receipts_root,
        ),
        .header_claims = .{
            .blob_gas_used = expected_blob_gas_used,
            .excess_blob_gas = expected_excess_blob_gas,
        },
    });
    try std.testing.expectEqual(Status.valid, result.status);

    const custom_schedule_result = try StfPrague.applyAssumeDecoded(scratch, .{
        .env = .{ .gas_limit = 21_000, .blob_base_fee = 1, .blob_params = custom_blob_params },
        .state_backend = try Backend.fromWitness(scratch, pre_state_root, &nodes, &.{}),
        .transactions = &tx_input,
        .parent_blob_gas = parent_blob_gas,
        .root_checks = testRootChecks(
            expected_state_root,
            expected_transactions_root,
            first_result.receipts_root,
        ),
        .header_claims = .{
            .blob_gas_used = expected_blob_gas_used,
            .excess_blob_gas = expected_custom_excess_blob_gas,
        },
    });
    try std.testing.expectEqual(Status.valid, custom_schedule_result.status);
    try std.testing.expect(expected_custom_excess_blob_gas != expected_excess_blob_gas);

    const blob_gas_mismatch = try StfPrague.applyAssumeDecoded(scratch, .{
        .env = .{ .gas_limit = 21_000, .blob_base_fee = 1 },
        .state_backend = try Backend.fromWitness(scratch, pre_state_root, &nodes, &.{}),
        .transactions = &tx_input,
        .parent_blob_gas = parent_blob_gas,
        .root_checks = testRootChecks(
            expected_state_root,
            expected_transactions_root,
            first_result.receipts_root,
        ),
        .header_claims = .{ .blob_gas_used = expected_blob_gas_used + 1 },
    });
    try std.testing.expectEqual(Status.blob_gas_used_mismatch, blob_gas_mismatch.status);

    const excess_blob_gas_mismatch = try StfPrague.applyAssumeDecoded(scratch, .{
        .env = .{ .gas_limit = 21_000, .blob_base_fee = 1 },
        .state_backend = try Backend.fromWitness(scratch, pre_state_root, &nodes, &.{}),
        .transactions = &tx_input,
        .parent_blob_gas = parent_blob_gas,
        .root_checks = testRootChecks(
            expected_state_root,
            expected_transactions_root,
            first_result.receipts_root,
        ),
        .header_claims = .{ .excess_blob_gas = expected_excess_blob_gas + 1 },
    });
    try std.testing.expectEqual(Status.excess_blob_gas_mismatch, excess_blob_gas_mismatch.status);
}

test "BlockSTF rejects cumulative blob gas above the block params cap" {
    const StfCancun = t.BlockStf(.cancun) orelse return error.SkipZigTest;
    const StfShanghai = t.BlockStf(.shanghai) orelse return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const scratch = arena.allocator();

    const sender = address.addr(0x4001);
    const first_blob_hashes = [_]u256{
        @as(u256, 0x01) << 248,
        (@as(u256, 0x01) << 248) | 1,
        (@as(u256, 0x01) << 248) | 2,
        (@as(u256, 0x01) << 248) | 3,
        (@as(u256, 0x01) << 248) | 4,
        (@as(u256, 0x01) << 248) | 5,
    };
    const second_blob_hashes = [_]u256{(@as(u256, 0x01) << 248) | 6};
    const oversized_blob_hashes = [_]u256{
        @as(u256, 0x01) << 248,
        (@as(u256, 0x01) << 248) | 1,
        (@as(u256, 0x01) << 248) | 2,
        (@as(u256, 0x01) << 248) | 3,
        (@as(u256, 0x01) << 248) | 4,
        (@as(u256, 0x01) << 248) | 5,
        (@as(u256, 0x01) << 248) | 6,
    };
    const account_key = trie.hashedAddressKey(sender);
    const pre_account_value = try trie.accountValueFrom(scratch, .{ .balance = 2_000_000 });
    const state_node = try testLeafNode(scratch, &account_key, pre_account_value);
    const pre_state_root = crypto.keccak256(state_node);
    const nodes = [_][]const u8{state_node};
    const transactions = [_]TransactionInput{
        .{
            .tx = .{
                .kind = .blob,
                .sender = sender,
                .to = sender,
                .gas_limit = 21_000,
                .max_fee_per_gas = 0,
                .max_priority_fee_per_gas = 0,
                .max_fee_per_blob_gas = 1,
                .blob_hashes = &first_blob_hashes,
            },
            .encoded = "blobtx0",
        },
        .{
            .tx = .{
                .kind = .blob,
                .sender = sender,
                .to = sender,
                .gas_limit = 21_000,
                .max_fee_per_gas = 0,
                .max_priority_fee_per_gas = 0,
                .max_fee_per_blob_gas = 1,
                .blob_hashes = &second_blob_hashes,
            },
            .encoded = "blobtx1",
        },
    };
    const oversized_transactions = [_]TransactionInput{.{
        .tx = .{
            .kind = .blob,
            .sender = sender,
            .to = sender,
            .gas_limit = 21_000,
            .max_fee_per_gas = 0,
            .max_priority_fee_per_gas = 0,
            .max_fee_per_blob_gas = 1,
            .blob_hashes = &oversized_blob_hashes,
        },
        .encoded = "oversized-blobtx",
    }};

    const oversized_result = try StfCancun.applyAssumeDecoded(scratch, .{
        .env = .{ .gas_limit = 21_000, .blob_base_fee = 1 },
        .state_backend = try Backend.fromWitness(scratch, pre_state_root, &nodes, &.{}),
        .transactions = &oversized_transactions,
        .root_checks = testRootChecks(trie.empty_root_hash, trie.empty_root_hash, trie.empty_root_hash),
    });
    try std.testing.expectEqual(Status.blob_gas_limit_exceeded, oversized_result.status);
    try std.testing.expectEqual(@as(?usize, 0), oversized_result.tx_index);
    try std.testing.expectEqual(@as(u64, 0), oversized_result.blob_gas_used);

    const pre_cancun_result = try StfShanghai.applyAssumeDecoded(scratch, .{
        .env = .{ .gas_limit = 21_000 },
        .state_backend = try Backend.fromWitness(scratch, pre_state_root, &nodes, &.{}),
        .transactions = &oversized_transactions,
        .root_checks = testRootChecks(trie.empty_root_hash, trie.empty_root_hash, trie.empty_root_hash),
    });
    try std.testing.expectEqual(Status.transaction_rejected, pre_cancun_result.status);
    try std.testing.expectEqual(@as(?usize, 0), pre_cancun_result.tx_index);
    try std.testing.expectEqual(
        transaction.validation.ValidationError.type_3_tx_pre_fork,
        pre_cancun_result.transaction_rejection,
    );

    const cancun_schedule = eth_spec.cancun.transaction.blob_schedule.?;
    const custom_blob_params = transaction.BlobParams{
        .target = cancun_schedule.target,
        .max = 1,
        .base_fee_update_fraction = cancun_schedule.base_fee_update_fraction,
    };
    const custom_schedule_result = try StfCancun.applyAssumeDecoded(scratch, .{
        .env = .{ .gas_limit = 21_000, .blob_base_fee = 1, .blob_params = custom_blob_params },
        .state_backend = try Backend.fromWitness(scratch, pre_state_root, &nodes, &.{}),
        .transactions = transactions[0..1],
        .root_checks = testRootChecks(trie.empty_root_hash, trie.empty_root_hash, trie.empty_root_hash),
    });
    try std.testing.expectEqual(Status.blob_gas_limit_exceeded, custom_schedule_result.status);
    try std.testing.expectEqual(@as(?usize, 0), custom_schedule_result.tx_index);

    const result = try StfCancun.applyAssumeDecoded(scratch, .{
        .env = .{ .gas_limit = 42_000, .blob_base_fee = 1 },
        .state_backend = try Backend.fromWitness(scratch, pre_state_root, &nodes, &.{}),
        .transactions = &transactions,
        .root_checks = testRootChecks(trie.empty_root_hash, trie.empty_root_hash, trie.empty_root_hash),
    });

    try std.testing.expectEqual(Status.blob_gas_limit_exceeded, result.status);
    try std.testing.expectEqual(@as(?usize, 1), result.tx_index);
    try std.testing.expectEqual(cancun_schedule.max * cancun_schedule.gas_per_blob, result.blob_gas_used);
}

test "BlockSTF applies withdrawals to state balances" {
    const StfShanghai = t.BlockStf(.shanghai) orelse return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const scratch = arena.allocator();

    const recipient = address.addr(0x1234);
    const withdrawals = [_]Withdrawal{.{
        .index = 0,
        .validator_index = 1,
        .address = recipient,
        .amount = 3,
    }};
    const credited_balance: u256 = 3 * withdrawal_gwei_in_wei;
    const account_key = trie.hashedAddressKey(recipient);
    const account_value = try trie.accountValueFrom(scratch, .{ .balance = credited_balance });
    const expected_state_pairs = [_]trie.Pair{.{ .key = &account_key, .value = account_value }};
    const expected_state_root = try trie.root(scratch, &expected_state_pairs);
    const expected_withdrawals_root = try trie.withdrawalsRoot(scratch, &withdrawals);

    const result = try StfShanghai.applyAssumeDecoded(scratch, .{
        .state_backend = try Backend.fromWitness(scratch, trie.empty_root_hash, &.{}, &.{}),
        .transactions = &.{},
        .withdrawals = &withdrawals,
        .root_checks = testRootChecksWithWithdrawals(
            expected_state_root,
            trie.empty_root_hash,
            trie.empty_root_hash,
            expected_withdrawals_root,
        ),
    });
    try std.testing.expectEqual(Status.valid, result.status);
    try std.testing.expectEqualSlices(u8, &expected_state_root, &result.state_root);

    const mutated_withdrawals = [_]Withdrawal{.{
        .index = withdrawals[0].index,
        .validator_index = withdrawals[0].validator_index,
        .address = withdrawals[0].address,
        .amount = withdrawals[0].amount + 1,
    }};
    const mutated_withdrawals_root = try trie.withdrawalsRoot(scratch, &mutated_withdrawals);
    const mutated = try StfShanghai.applyAssumeDecoded(scratch, .{
        .state_backend = try Backend.fromWitness(scratch, trie.empty_root_hash, &.{}, &.{}),
        .transactions = &.{},
        .withdrawals = &mutated_withdrawals,
        .root_checks = testRootChecksWithWithdrawals(
            expected_state_root,
            trie.empty_root_hash,
            trie.empty_root_hash,
            mutated_withdrawals_root,
        ),
    });
    try std.testing.expectEqual(Status.state_root_mismatch, mutated.status);
}

test "BlockSTF rejects fork-inactive body fields before state access" {
    const StfMerge = t.BlockStf(.merge) orelse return error.SkipZigTest;
    const StfPrague = t.BlockStf(.prague) orelse return error.SkipZigTest;
    const StfShanghai = t.BlockStf(.shanghai) orelse return error.SkipZigTest;
    const withdrawal = Withdrawal{
        .index = 0,
        .validator_index = 0,
        .address = address.addr(0x1234),
        .amount = 1,
    };
    const roots = testRootChecks(trie.empty_root_hash, trie.empty_root_hash, trie.empty_root_hash);

    const pre_shanghai = try StfMerge.applyAssumeDecoded(std.testing.allocator, .{
        .state_backend = try Backend.fromWitness(std.testing.allocator, trie.empty_root_hash, &.{}, &.{}),
        .transactions = &.{},
        .withdrawals = &.{withdrawal},
        .root_checks = roots,
    });
    try std.testing.expectEqual(Status.invalid_block_body, pre_shanghai.status);

    const pre_cancun = try StfShanghai.applyAssumeDecoded(std.testing.allocator, .{
        .state_backend = try Backend.fromWitness(std.testing.allocator, trie.empty_root_hash, &.{}, &.{}),
        .transactions = &.{},
        .parent_blob_gas = .{
            .parent_excess_blob_gas = 0,
            .parent_blob_gas_used = 0,
            .parent_base_fee_per_gas = 0,
        },
        .root_checks = roots,
    });
    try std.testing.expectEqual(Status.invalid_block_body, pre_cancun.status);

    const pre_amsterdam = try StfPrague.applyAssumeDecoded(std.testing.allocator, .{
        .state_backend = try Backend.fromWitness(std.testing.allocator, trie.empty_root_hash, &.{}, &.{}),
        .transactions = &.{},
        .block_access_list = &.{},
        .root_checks = roots,
    });
    try std.testing.expectEqual(Status.invalid_block_body, pre_amsterdam.status);

    // A differential request is diagnostic, not a body field. A mixed-fork
    // verifier supplies one for every block, so a pre-Amsterdam block must stay
    // valid and simply report `.not_run`.
    var report = block_stf.BalDifferentialReport{};
    const pre_amsterdam_differential = try StfPrague.applyAssumeDecoded(std.testing.allocator, .{
        .state_backend = try Backend.fromWitness(std.testing.allocator, trie.empty_root_hash, &.{}, &.{}),
        .transactions = &.{},
        .bal_differential = &report,
        .root_checks = roots,
    });
    try std.testing.expectEqual(Status.valid, pre_amsterdam_differential.status);
    try std.testing.expectEqual(block_stf.BalDifferentialStatus.not_run, report.status);
}

test "stateless receipt encoder writes consensus receipt rlp" {
    var counted = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const legacy_before = counted.alloc_index;
    const encoded = try encodeReceipt(counted.allocator(), .legacy, .{
        .status = .success,
        .cumulative_gas_used = 21_000,
    });
    defer counted.allocator().free(encoded);

    try std.testing.expectEqual(legacy_before + 1, counted.alloc_index);
    try expectHex(encoded, "f9010801825208b9010000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000c0");

    const typed_before = counted.alloc_index;
    const typed = try encodeReceipt(counted.allocator(), .dynamic_fee, .{
        .status = .success,
        .cumulative_gas_used = 21_000,
    });
    defer counted.allocator().free(typed);
    try std.testing.expectEqual(typed_before + 1, counted.alloc_index);
    try std.testing.expectEqual(@as(u8, 0x02), typed[0]);
    try std.testing.expectEqualSlices(u8, encoded, typed[1..]);
}

test "stateless receipt encoder includes logs and bloom" {
    const target = address.addr(0x3000);
    const topics = [_]u256{0x1234};
    const event_log = Log{
        .address = target,
        .topics = &topics,
        .data = &.{ 0xab, 0xcd },
    };
    var event_logs = try state.LogBuffer.fromLogs(std.testing.allocator, &.{event_log});
    defer event_logs.deinit(std.testing.allocator);
    var counted = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const before = counted.alloc_index;
    const encoded = try encodeReceipt(counted.allocator(), .legacy, .{
        .status = .revert,
        .cumulative_gas_used = 30_000,
        .logs = event_logs.view(),
    });
    defer counted.allocator().free(encoded);

    // Materializing the packed rows into `[]Log` for the RLP schema is the
    // second allocation; the encoded receipt is the first.
    try std.testing.expectEqual(before + 2, counted.alloc_index);
    var raw = rlp.Cursor.init(encoded);
    var raw_receipt = try raw.nextList();
    try raw.expectDone();
    _ = try raw_receipt.nextInt(u8);
    _ = try raw_receipt.nextInt(u64);
    _ = try raw_receipt.nextBytesExact(256);
    var raw_logs = try raw_receipt.nextList();
    var raw_log = try raw_logs.nextList();
    try std.testing.expectEqualSlices(u8, target.asBytes(), try raw_log.nextBytesExact(20));
    var raw_topics = try raw_log.nextList();
    const expected_topic = uint256.toBytes32(topics[0]);
    try std.testing.expectEqualSlices(u8, &expected_topic, try raw_topics.nextBytesExact(32));
    try raw_topics.expectDone();
    try std.testing.expectEqualSlices(u8, &.{ 0xab, 0xcd }, try raw_log.nextBytes());
    try raw_log.expectDone();
    try raw_logs.expectDone();
    try raw_receipt.expectDone();

    var decoded = try rlp.decodeAlloc(ReceiptPayload, std.testing.allocator, encoded);
    defer rlp.deinit(ReceiptPayload, std.testing.allocator, &decoded);
    try std.testing.expectEqual(@as(u8, 0), decoded.status);
    try std.testing.expectEqual(@as(u64, 30_000), decoded.cumulative_gas_used);
    try std.testing.expect(!std.mem.allEqual(u8, &decoded.logs_bloom, 0));
    try std.testing.expectEqual(@as(usize, 1), decoded.logs.len);
    try std.testing.expectEqual(target, decoded.logs[0].address);
    try std.testing.expectEqualSlices(u256, &topics, decoded.logs[0].topics);
    try std.testing.expectEqualSlices(u8, &.{ 0xab, 0xcd }, decoded.logs[0].data);
}

test "stateless receipt schema enforces the EVM log topic limit" {
    // Built as views rather than through `LogBuffer.append`, which rejects a
    // fifth topic itself. The subject here is the wire schema's independent
    // limit, so the buffer's guard must not stand in for it.
    const rows = [_]state.LogBuffer.Row{.{
        .address = address.addr(0x3000),
        .topics = .init(0, 4),
        .data = .{},
    }};
    const accepted_topics = [_]u256{ 1, 2, 3, 4 };
    const accepted = try encodeReceipt(std.testing.allocator, .legacy, .{
        .status = .success,
        .logs = .{ .rows = &rows, .topics = &accepted_topics, .data = &.{} },
    });
    defer std.testing.allocator.free(accepted);

    const rejected_rows = [_]state.LogBuffer.Row{.{
        .address = address.addr(0x3000),
        .topics = .init(0, 5),
        .data = .{},
    }};
    const rejected_topics = [_]u256{ 1, 2, 3, 4, 5 };
    try std.testing.expectError(error.ListLimitExceeded, encodeReceipt(std.testing.allocator, .legacy, .{
        .status = .success,
        .logs = .{ .rows = &rejected_rows, .topics = &rejected_topics, .data = &.{} },
    }));
}

test "stateless receipt typed decode cleans nested allocation failures" {
    const Harness = struct {
        fn run(allocator: std.mem.Allocator) !void {
            const topics = [_]u256{ 1, 2 };
            const logs = [_]Log{.{
                .address = address.addr(0x3000),
                .topics = &topics,
                .data = &.{ 0xab, 0xcd },
            }};
            // Allocation-free so the injected failure index still targets the
            // decode path this test is about.
            const rows = [_]state.LogBuffer.Row{.{
                .address = address.addr(0x3000),
                .topics = .init(0, 2),
                .data = .init(0, 2),
            }};
            const payload: ReceiptPayload = .{
                .status = 1,
                .cumulative_gas_used = 21_000,
                .logs_bloom = logsBloom(.{
                    .rows = &rows,
                    .topics = &topics,
                    .data = &.{ 0xab, 0xcd },
                }),
                .logs = &logs,
            };
            var out: [512]u8 = undefined;
            const encoded = try rlp.encode(ReceiptPayload, &out, &payload);
            var decoded = try rlp.decodeAlloc(ReceiptPayload, allocator, encoded);
            defer rlp.deinit(ReceiptPayload, allocator, &decoded);
            try std.testing.expectEqualSlices(u256, &topics, decoded.logs[0].topics);
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Harness.run, .{});
}

fn testLeafNode(allocator: std.mem.Allocator, key: []const u8, value: []const u8) ![]u8 {
    var payload = rlp.Writer.alloc(allocator);
    defer payload.deinit();
    try payload.bytes(try testCompactPath(allocator, key));
    try payload.bytes(value);

    var out = rlp.Writer.alloc(allocator);
    errdefer out.deinit();
    try out.listPayload(payload.written());
    return try writerOwned(&out);
}

fn testCompactPath(allocator: std.mem.Allocator, key: []const u8) ![]u8 {
    const out = try allocator.alloc(u8, key.len + 1);
    out[0] = 0x20;
    @memcpy(out[1..], key);
    return out;
}

fn writerOwned(writer: *rlp.Writer) std.mem.Allocator.Error![]u8 {
    return writer.toOwnedSlice() catch |err| switch (err) {
        error.BorrowedWriter => unreachable,
        error.OutOfMemory => return error.OutOfMemory,
    };
}

fn expectHex(actual: []const u8, expected_hex: []const u8) !void {
    if (std.mem.startsWith(u8, expected_hex, "f9010801825208b90100") and std.mem.endsWith(u8, expected_hex, "c0")) {
        try std.testing.expectEqual(@as(usize, 267), actual.len);
        try std.testing.expectEqualSlices(u8, &.{ 0xf9, 0x01, 0x08, 0x01, 0x82, 0x52, 0x08, 0xb9, 0x01, 0x00 }, actual[0..10]);
        try std.testing.expect(std.mem.allEqual(u8, actual[10..266], 0));
        try std.testing.expectEqual(@as(u8, 0xc0), actual[266]);
        return;
    }
    const expected = try std.testing.allocator.alloc(u8, expected_hex.len / 2);
    defer std.testing.allocator.free(expected);
    _ = try std.fmt.hexToBytes(expected, expected_hex);
    try std.testing.expectEqualSlices(u8, expected, actual);
}
