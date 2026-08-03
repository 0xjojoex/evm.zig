//! Everything the coordinator accumulates from accepted transactions.
//!
//! Lanes may finish in any order, but they are accepted here strictly in
//! transaction order, so this is the one place that advances block progress and
//! appends to the receipt, bloom, request, and BAL folds. A lane has already
//! established that its result and logs match canonical, so the canonical ones
//! are used here; what remains to check is the block-level accounting.

const std = @import("std");

const bal = @import("../model.zig");
const ShardFold = @import("../shard_fold.zig").ShardFold;
const observation = @import("../observation.zig");
const lane = @import("lane.zig");
const vm = @import("../../../vm.zig");

pub fn Accumulator(comptime Engine: type, comptime Operations: type) type {
    const Lane = lane.Lane(Engine);

    return struct {
        const Self = @This();

        allocator: std.mem.Allocator,
        env: vm.Env,
        progress: vm.BlockResult = .{},
        blob_gas_used: u64 = 0,
        bal_shard_fold: ShardFold,
        transaction_count: usize = 0,
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
                .bal_shard_fold = ShardFold.init(allocator),
            };
        }

        pub fn deinit(self: *Self) void {
            for (self.encoded_receipts.items) |encoded| self.allocator.free(encoded);
            self.encoded_receipts.deinit(self.allocator);
            self.deposit_request_data.deinit(self.allocator);
            self.bal_shard_fold.deinit();
        }

        pub fn transactionCount(self: *const Self) usize {
            return self.transaction_count;
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
            transition: *const observation.LaneTransition,
        ) !void {
            const next_progress = advanceProgress(self.env, self.progress, included.result.*) catch {
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
                .status = included.result.status,
                .gas_used = included.result.gas.used,
                .cumulative_gas_used = next_progress.gas_used,
                .cumulative_block_gas = next_progress.block_gas.total,
                .cumulative_state_gas = next_progress.block_gas.state,
            });
            if (after_calls.slice().len != 0) {
                return error.UnsupportedAfterTransactionHooks;
            }
            if (included.tx_index != self.transaction_count) return error.OutOfOrderTransaction;
            self.transaction_count += 1;

            const write_index = std.math.add(usize, included.tx_index, 1) catch
                return error.BlockAccessIndexOverflow;
            const transaction_write_index = std.math.cast(bal.BlockAccessIndex, write_index) orelse
                return error.BlockAccessIndexOverflow;
            // Fold the detached observations straight into the block shard.
            // Materializing an intermediate per-transaction BAL only to append
            // and free it duplicated every code body a second time.
            for (transition.accounts) |account| {
                try self.bal_shard_fold.appendObservation(account, transaction_write_index);
            }

            const receipt: vm.TxReceiptView = .{
                .status = included.result.status,
                .gas_used = included.result.gas.used,
                .cumulative_gas_used = next_progress.gas_used,
                .created_address = included.result.created_address,
                .logs = included.logs,
            };
            try Operations.appendCandidateDepositRequestData(
                self.allocator,
                &self.deposit_request_data,
                included.logs,
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
                Operations.candidateLogsBloom(included.logs),
            );
            self.progress = next_progress;
            self.blob_gas_used = blob_admission.next;
        }

        pub fn blobGasAdmission(self: *const Self, tx: Engine.Transaction) anyerror!BlobGasAdmission {
            const transaction_blob_gas = try Operations.candidateTransactionBlobGasUsed(tx);
            const next = std.math.add(u64, self.blob_gas_used, transaction_blob_gas) catch
                return error.BlobGasOverflow;
            const limit = try Operations.candidateBlockBlobGasLimit(self.env.blob_params);
            return .{ .next = next, .exceeds_limit = next > limit };
        }
    };
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
