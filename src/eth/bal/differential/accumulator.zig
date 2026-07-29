//! Everything the coordinator accumulates from accepted transactions.
//!
//! Lanes may finish in any order, but they are accepted here strictly in
//! transaction order, so this is the one place that advances block progress and
//! appends to the receipt, bloom, request, BAL, and candidate-state folds. It
//! decides only whether a lane agrees with the authoritative fold; what a
//! disagreement means to the block is `runner`'s call.

const std = @import("std");

const Host = @import("../../../Host.zig");
const bal = @import("../model.zig");
const ClaimView = @import("../ClaimView.zig");
const ShardFold = @import("../shard_fold.zig").ShardFold;
const candidate_transition = @import("../candidate_transition.zig");
const lane = @import("lane.zig");
const state = @import("../../../state.zig");
const vm = @import("../../../vm.zig");

pub fn Accumulator(comptime Engine: type, comptime Operations: type) type {
    const Lane = lane.Lane(Engine);

    return struct {
        const Self = @This();

        allocator: std.mem.Allocator,
        env: vm.Env,
        progress: vm.BlockResult = .{},
        blob_gas_used: u64 = 0,
        transition_fold: candidate_transition.OrderedTransitionFold,
        bal_shard_fold: ShardFold,
        encoded_receipts: std.ArrayList([]const u8) = .empty,
        deposit_request_data: std.ArrayList(u8) = .empty,
        block_logs_bloom: [256]u8 = [_]u8{0} ** 256,

        pub const BlobGasAdmission = struct {
            next: u64,
            exceeds_limit: bool,
        };

        pub fn init(allocator: std.mem.Allocator, env: vm.Env) Self {
            return .{
                .allocator = allocator,
                .env = env,
                .transition_fold = candidate_transition.OrderedTransitionFold.init(allocator),
                .bal_shard_fold = ShardFold.init(allocator),
            };
        }

        pub fn deinit(self: *Self) void {
            for (self.encoded_receipts.items) |encoded| self.allocator.free(encoded);
            self.encoded_receipts.deinit(self.allocator);
            self.deposit_request_data.deinit(self.allocator);
            self.bal_shard_fold.deinit();
            self.transition_fold.deinit();
        }

        pub fn transactionCount(self: *const Self) usize {
            return self.transition_fold.transactionCount();
        }

        /// Fold one already-built BAL shard from a serial block phase.
        pub fn appendShard(self: *Self, accounts: bal.BlockAccessList) !void {
            try self.bal_shard_fold.append(accounts);
        }

        /// Accept one lane in transaction order. Returns a semantic error when
        /// the lane disagrees with the authoritative fold; on success every
        /// accumulator field has advanced past this transaction.
        pub fn accept(
            self: *Self,
            included: Lane.Included,
            effects: *const candidate_transition.TransactionEffects,
        ) !void {
            if (!executionResultEqual(effects.result, included.result.*) or
                !logsEqual(effects.logs, included.logs))
            {
                return error.OutcomeMismatch;
            }
            const next_progress = advanceProgress(self.env, self.progress, effects.result) catch {
                return error.CandidateArtifactMismatch;
            };
            const blob_admission = self.blobGasAdmission(included.transaction) catch |err| switch (err) {
                error.BlobGasOverflow => return error.CandidateArtifactMismatch,
                else => return err,
            };
            if (!std.meta.eql(next_progress, included.progress_after) or
                blob_admission.exceeds_limit or
                blob_admission.next != included.blob_gas_used_after)
            {
                return error.CandidateArtifactMismatch;
            }
            const after_calls = Engine.specification.block.afterTransaction(.{
                .number = self.env.number,
                .timestamp = self.env.timestamp,
                .transaction_index = next_progress.tx_count - 1,
                .status = effects.result.status,
                .gas_used = effects.result.gas.used,
                .cumulative_gas_used = next_progress.gas_used,
                .cumulative_block_gas = next_progress.block_gas.total,
                .cumulative_state_gas = next_progress.block_gas.state,
            });
            if (after_calls.slice().len != 0) {
                return error.UnsupportedAfterTransactionHooks;
            }
            try self.transition_fold.append(included.tx_index, &effects.transition);

            const write_index = std.math.add(usize, included.tx_index, 1) catch
                return error.BlockAccessIndexOverflow;
            const transaction_write_index = std.math.cast(bal.BlockAccessIndex, write_index) orelse
                return error.BlockAccessIndexOverflow;
            // Fold the detached observations straight into the block shard.
            // Materializing an intermediate per-transaction BAL only to append
            // and free it duplicated every code body a second time.
            for (effects.transition.accounts) |account| {
                try self.bal_shard_fold.appendObservation(account, transaction_write_index);
            }

            const receipt: vm.TxReceiptView = .{
                .status = effects.result.status,
                .gas_used = effects.result.gas.used,
                .cumulative_gas_used = next_progress.gas_used,
                .created_address = effects.result.created_address,
                .logs = .fromSlice(effects.logs),
            };
            try Operations.appendCandidateDepositRequestData(
                self.allocator,
                &self.deposit_request_data,
                effects.logs,
            );
            const encoded_receipt = try Operations.encodeCandidateReceipt(
                self.allocator,
                included.transaction.kind,
                receipt,
            );
            errdefer self.allocator.free(encoded_receipt);
            try self.encoded_receipts.append(self.allocator, encoded_receipt);
            Operations.mergeCandidateLogsBloom(
                &self.block_logs_bloom,
                Operations.candidateLogsBloom(effects.logs),
            );
            self.progress = next_progress;
            self.blob_gas_used = blob_admission.next;
        }

        pub fn blobGasAdmission(self: *const Self, tx: Engine.Transaction) anyerror!BlobGasAdmission {
            const transaction_blob_gas = try Operations.candidateTransactionBlobGasUsed(
                self.env.blob_schedule,
                tx,
            );
            const next = std.math.add(u64, self.blob_gas_used, transaction_blob_gas) catch
                return error.BlobGasOverflow;
            const limit = try Operations.candidateBlockBlobGasLimit(self.env.blob_schedule);
            return .{ .next = next, .exceeds_limit = next > limit };
        }

        /// Seal the transaction-phase folds and confirm the candidate's own
        /// field-level state agrees with what the claim attributes to
        /// transaction indices. Exact observed-versus-claimed BAL bytes remain
        /// the soundness gate in both directions; this is one-sided.
        pub fn finishTransactions(self: *Self, claim: *const ClaimView) !void {
            try self.transition_fold.finish();
            const transaction_count = std.math.cast(
                bal.BlockAccessIndex,
                self.transactionCount(),
            ) orelse return error.BlockAccessIndexOverflow;
            if (!matchesTransactionDelta(self.transition_fold.view(), claim, transaction_count)) {
                return error.TransitionFoldMismatch;
            }
        }

        pub fn transactionState(self: *const Self) *const candidate_transition.CandidateState {
            return self.transition_fold.view();
        }
    };
}

fn executionResultEqual(expected: vm.TxExecutionResult, actual: vm.TxExecutionResult) bool {
    return expected.status == actual.status and
        std.meta.eql(expected.gas, actual.gas) and
        std.mem.eql(u8, expected.output, actual.output) and
        std.meta.eql(expected.created_address, actual.created_address);
}

fn logsEqual(expected: []const Host.Log, actual: state.TrackedState.LogView) bool {
    if (expected.len != actual.len()) return false;
    for (expected, 0..) |expected_log, index| {
        const actual_log = actual.get(index);
        if (!std.mem.eql(u8, &expected_log.address, &actual_log.address) or
            !std.mem.eql(u256, expected_log.topics, actual_log.topics) or
            !std.mem.eql(u8, expected_log.data, actual_log.data))
        {
            return false;
        }
    }
    return true;
}

fn matchesTransactionDelta(
    candidate: *const candidate_transition.CandidateState,
    claim: *const ClaimView,
    transaction_count: bal.BlockAccessIndex,
) bool {
    var account_index: usize = 0;
    var account_fields = claim.transactionDelta(transaction_count).accountFields();
    while (account_fields.next()) |expected| {
        while (account_index < candidate.accounts.items.len and
            std.mem.order(u8, &candidate.accounts.items[account_index].address, &expected.address) == .lt)
        {
            account_index += 1;
        }
        if (account_index == candidate.accounts.items.len) return false;
        const actual = candidate.accounts.items[account_index];
        if (!std.mem.eql(u8, &actual.address, &expected.address)) return false;
        if (expected.balance) |balance| if (actual.balance == null or actual.balance.? != balance) return false;
        if (expected.nonce) |nonce| if (actual.nonce == null or actual.nonce.? != nonce) return false;
        if (expected.code) |code| {
            if (actual.code_hash == null or
                !std.mem.eql(u8, &actual.code_hash.?, &code.hash))
            {
                return false;
            }
        }
    }

    var storage_index: usize = 0;
    var storage_writes = claim.transactionDelta(transaction_count).storageWrites();
    while (storage_writes.next()) |expected| {
        while (storage_index < candidate.storage.items.len and
            storageWriteBefore(candidate.storage.items[storage_index], expected))
        {
            storage_index += 1;
        }
        if (storage_index == candidate.storage.items.len) return false;
        const actual = candidate.storage.items[storage_index];
        if (!std.mem.eql(u8, &actual.address, &expected.address) or
            actual.key != expected.slot or actual.value != expected.value)
        {
            return false;
        }
    }
    return true;
}

fn storageWriteBefore(
    actual: candidate_transition.StorageDelta,
    expected: ClaimView.FinalStorageWrite,
) bool {
    const address_order = std.mem.order(u8, &actual.address, &expected.address);
    if (address_order != .eq) return address_order == .lt;
    return actual.key < expected.slot;
}

/// Match the authoritative block program: either receipt-gas or dimensional
/// block-gas overflow is a block-gas admission rejection.
pub fn advanceProgress(
    env: vm.Env,
    progress: vm.BlockResult,
    result: vm.TxExecutionResult,
) !vm.BlockResult {
    var next = progress;
    next.gas_used = std.math.add(u64, next.gas_used, result.gas.used) catch return error.BlockGasExceeded;
    next.block_gas = next.block_gas.add(result.gas.block) catch return error.BlockGasExceeded;
    if (!next.block_gas.withinLimit(env.gas_limit)) return error.BlockGasExceeded;
    next.tx_count = std.math.add(u64, next.tx_count, 1) catch return error.BlockProgressOverflow;
    return next;
}

pub fn executionExceedsBlockGas(
    env: vm.Env,
    progress: vm.BlockResult,
    result: vm.TxExecutionResult,
) !bool {
    _ = advanceProgress(env, progress, result) catch |err| switch (err) {
        error.BlockGasExceeded => return true,
        else => return err,
    };
    return false;
}

test "candidate block-gas admission detects the serial overflow boundary" {
    const progress: vm.BlockResult = .{
        .gas_used = 20,
        .block_gas = .{ .total = 20, .regular = 20 },
        .tx_count = 1,
    };
    const result: vm.TxExecutionResult = .{
        .status = .success,
        .gas = .{
            .used = 1,
            .block = .{ .total = 1, .regular = 1 },
        },
    };
    try std.testing.expect(try executionExceedsBlockGas(.{ .gas_limit = 20 }, progress, result));
    try std.testing.expect(!try executionExceedsBlockGas(.{ .gas_limit = 21 }, progress, result));

    var receipt_overflow = result;
    receipt_overflow.gas.used = 1;
    try std.testing.expect(try executionExceedsBlockGas(
        .{},
        .{ .gas_used = std.math.maxInt(u64) },
        receipt_overflow,
    ));

    var block_overflow = result;
    block_overflow.gas.used = 0;
    block_overflow.gas.block = .{ .total = 1, .regular = 1 };
    try std.testing.expect(try executionExceedsBlockGas(
        .{},
        .{ .block_gas = .{ .total = std.math.maxInt(u64), .regular = std.math.maxInt(u64) } },
        block_overflow,
    ));

    var count_overflow = result;
    count_overflow.gas.used = 0;
    count_overflow.gas.block = .{};
    try std.testing.expectError(
        error.BlockProgressOverflow,
        executionExceedsBlockGas(.{}, .{ .tx_count = std.math.maxInt(u64) }, count_overflow),
    );
}
