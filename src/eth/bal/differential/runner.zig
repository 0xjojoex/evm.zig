//! Candidate block lifecycle over positioned BAL reads.
//!
//! This lane never owns canonical block state. Block-start work runs serially
//! over the authenticated base, each transaction runs in an isolated `lane`
//! over `ClaimReader(base, claim, tx_index)`, and block-final work runs
//! serially over `ClaimReader(base, claim, transaction_count)`, which is
//! already parent state plus every write through the last transaction. Only
//! the coordinator mutates `accumulator` state. The first coverage failure or mismatch disables the
//! complete claim lane; callers continue on their independently owned canonical
//! reader.
//!
//! Runner owns lifecycle and status alone: lane execution lives in `lane`,
//! ordered accumulation in `accumulator`, and every concurrency assumption in
//! `schedule`.

const std = @import("std");

const Executor = @import("../../../executor.zig");
const bal = @import("../model.zig");
const ClaimView = @import("../ClaimView.zig");
const tracked_state_projector = @import("../tracked_state_projector.zig");
const accumulator_types = @import("accumulator.zig");
const lane_types = @import("lane.zig");
const report_types = @import("report.zig");
const schedule_types = @import("schedule.zig");
const execution_values = @import("../../../execution.zig");
const prepared_code = @import("../../../prepared_code.zig");
const ClaimReader = @import("../ClaimReader.zig");
const Reader = @import("../../../state/Reader.zig");
const vm = @import("../../../vm.zig");

const Report = report_types.Report;
const Status = report_types.Status;
const ParallelExecution = report_types.ParallelExecution;
const ParallelFallback = report_types.ParallelFallback;

pub fn Runner(comptime Engine: type, comptime Operations: type) type {
    return struct {
        const Self = @This();
        const Lane = lane_types.Lane(Engine);
        const Accumulator = accumulator_types.Accumulator(Engine, Operations);
        const Schedule = schedule_types.Schedule(Engine, Self);

        pub const Included = Lane.Included;
        pub const Rejected = Lane.Rejected;

        allocator: std.mem.Allocator,
        env: vm.Env,
        lifecycle_execution_context: execution_values.ExecutionContext,
        base_reader: Reader,
        prepared_code_backend: ?prepared_code.Backend,
        block_hash_source: ?vm.BlockHashSource,
        claim: *const ClaimView,
        report: *Report,
        accumulator: Accumulator,
        parallel_batch: ?Schedule = null,
        active: bool = true,

        pub const Artifacts = struct {
            gas_used: u64,
            block_gas_used: u64,
            block_state_gas_used: u64,
            receipts_root: [32]u8,
            /// Borrowed from the runner until its deinit.
            encoded_receipts: []const []const u8,
            logs_bloom: [256]u8,
            blob_gas_used: u64,
            requests: []const []const u8,
            requests_hash: [32]u8,
            encoded_block_access_list: []u8,

            pub fn deinit(self: *Artifacts, allocator: std.mem.Allocator) void {
                Operations.freeCandidateRequests(allocator, self.requests);
                allocator.free(self.encoded_block_access_list);
                self.* = undefined;
            }
        };

        pub fn init(
            allocator: std.mem.Allocator,
            env: vm.Env,
            lifecycle_execution_context: execution_values.ExecutionContext,
            base_reader: Reader,
            prepared_code_backend: ?prepared_code.Backend,
            block_hash_source: ?vm.BlockHashSource,
            claim: *const ClaimView,
            report: *Report,
            parallel_execution: ?ParallelExecution,
        ) Self {
            var self: Self = .{
                .allocator = allocator,
                .env = env,
                .lifecycle_execution_context = lifecycle_execution_context,
                .base_reader = base_reader,
                .prepared_code_backend = prepared_code_backend,
                .block_hash_source = block_hash_source,
                .claim = claim,
                .report = report,
                .accumulator = Accumulator.init(allocator, env),
            };
            if (parallel_execution) |execution| {
                self.parallel_batch = Schedule.init(
                    allocator,
                    report,
                    execution,
                    self.laneContext(),
                ) catch {
                    report.parallel_fallback = .lane_storage_unavailable;
                    return self;
                };
            }
            return self;
        }

        pub fn deinit(self: *Self) void {
            self.discardPending();
            if (self.parallel_batch) |*batch| batch.deinit();
            self.accumulator.deinit();
        }

        fn laneContext(self: *const Self) Lane.Context {
            return .{
                .env = self.env,
                .claim = self.claim,
                .prepared_code_backend = self.prepared_code_backend,
                .block_hash_source = self.block_hash_source,
            };
        }

        /// Run the serial block-start shard over the authenticated base. This
        /// is deliberately independent from positioned transaction readers.
        pub fn verifyBeforeBlock(self: *Self, header: ?Operations.BlockHeader) void {
            if (!self.active) return;
            self.verifyBeforeBlockFallible(header) catch |err| {
                self.stopForCandidateError(err, 0);
            };
        }

        fn verifyBeforeBlockFallible(self: *Self, header: ?Operations.BlockHeader) !void {
            var execution: Lane.CapturedExecution = undefined;
            try execution.init(self.allocator, self.base_reader, .{
                .prepared_code_backend = self.prepared_code_backend,
                .block_hash_source = self.block_hash_source,
            });
            defer execution.deinit();

            var observation_builder = tracked_state_projector.BlockBuilder.init(self.allocator);
            defer observation_builder.deinit();
            var observation_collector = Lane.ObservationCollector{
                .allocator = self.allocator,
                .builder = &observation_builder,
                .block_access_index = 0,
            };
            if (header) |context| {
                try Executor.system_contracts.applyBeforeBlockObserved(
                    &execution.executor,
                    self.lifecycle_execution_context,
                    context,
                    &observation_collector,
                );
            }
            var shard = try observation_builder.finish();
            defer shard.deinit(self.allocator);
            try self.accumulator.appendShard(shard.accounts);
        }

        pub fn verifyIncluded(self: *Self, included: Included) std.Io.Cancelable!void {
            if (!self.active) return;
            if (self.parallel_batch) |*batch| {
                if (batch.isEnabled()) {
                    if (!self.validateIncludedBoundary(included, batch.expectedProgress())) {
                        self.discardPending();
                        return;
                    }
                    batch.stage(included, included.progress_after) catch {
                        self.discardPending();
                        self.stopParallel(.lane_out_of_memory, included.tx_index, error.OutOfMemory);
                        return;
                    };
                    if (batch.isFull()) try self.flushPending();
                    return;
                }
            }
            self.verifyIncludedSerial(included);
        }

        fn verifyIncludedSerial(self: *Self, included: Included) void {
            if (!self.validateIncludedBoundary(included, self.accumulator.progress)) return;
            var outcome = Lane.run(
                self.laneContext(),
                self.allocator,
                self.base_reader,
                included,
            );
            defer outcome.deinit(self.allocator);
            self.acceptOutcome(included, &outcome);
        }

        fn validateIncludedBoundary(
            self: *Self,
            included: Included,
            expected_progress: vm.BlockResult,
        ) bool {
            if (!self.active) return false;
            if (!std.meta.eql(expected_progress, included.progress_before)) {
                self.stop(.candidate_artifact_mismatch, included.tx_index, null);
                return false;
            }
            const before_calls = Engine.specification.block.beforeTransaction(.{
                .number = self.env.number,
                .timestamp = self.env.timestamp,
                .transaction_index = expected_progress.tx_count,
            });
            if (before_calls.slice().len != 0) {
                self.stop(.unsupported_before_transaction_hooks, included.tx_index, null);
                return false;
            }
            return true;
        }

        fn flushPending(self: *Self) std.Io.Cancelable!void {
            const batch = if (self.parallel_batch) |*value| value else return;
            if (!batch.isEnabled() or !batch.hasPending()) return;
            const unavailable_tx_index = try batch.flush(self) orelse return;
            self.discardPending();
            self.stopParallel(
                .concurrency_unavailable,
                unavailable_tx_index,
                error.ConcurrencyUnavailable,
            );
        }

        /// Called by `Schedule` for each completed lane, in transaction order.
        pub fn acceptLaneOutcome(
            self: *Self,
            expected: *const Lane.OwnedIncluded,
            outcome: *Lane.Outcome,
        ) void {
            const included = expected.view();
            if (self.active and outcome.isOutOfMemory()) {
                self.stopParallel(.lane_out_of_memory, included.tx_index, error.OutOfMemory);
                return;
            }
            self.acceptOutcome(included, outcome);
        }

        /// Called by `Schedule` to resynchronize its staging boundary.
        pub fn laneProgress(self: *const Self) vm.BlockResult {
            return self.accumulator.progress;
        }

        fn acceptOutcome(self: *Self, included: Included, outcome: *Lane.Outcome) void {
            if (!self.active) return;
            switch (outcome.*) {
                .evidence => |*transition| self.accumulator.accept(included, transition) catch |err| {
                    self.stopForCandidateError(err, included.tx_index);
                    return;
                },
                .outcome_mismatch, .rejected => return self.stop(.outcome_mismatch, included.tx_index, null),
                .failed => |failure| return self.stopForError(
                    failure.err,
                    included.tx_index,
                    failure.strategy_failure,
                ),
            }
            self.report.folded_transactions = self.accumulator.transactionCount();
        }

        fn discardPending(self: *Self) void {
            const batch = if (self.parallel_batch) |*value| value else return;
            batch.discard(self.accumulator.progress);
        }

        fn stopParallel(
            self: *Self,
            reason: ParallelFallback,
            tx_index: usize,
            err: ?anyerror,
        ) void {
            self.parallel_batch.?.disable();
            if (self.report.parallel_fallback == null) self.report.parallel_fallback = reason;
            self.stop(.fallback_parallel_runtime, tx_index, err);
        }

        /// Replay only the authoritative serial fold's first failing
        /// transaction boundary. Earlier included lanes have already advanced
        /// progress; no post-state artifact exists for a rejected block.
        pub fn verifyRejected(self: *Self, rejected: Rejected) std.Io.Cancelable!void {
            try self.flushPending();
            if (!self.active) return;
            self.verifyRejectedFallible(rejected) catch |err|
                self.stopForCandidateError(err, rejected.tx_index);
        }

        fn verifyRejectedFallible(self: *Self, rejected: Rejected) !void {
            const progress = self.accumulator.progress;
            const candidate_tx_index = std.math.cast(usize, progress.tx_count) orelse
                return error.BlockAccessIndexOverflow;
            if (candidate_tx_index != rejected.tx_index) {
                return error.CandidateRejectionMismatch;
            }
            if (!std.meta.eql(progress, rejected.progress_before) or
                self.accumulator.blob_gas_used != rejected.blob_gas_used_before)
            {
                return error.CandidateRejectionMismatch;
            }

            if (rejected.kind == .blob_gas) {
                const admission = self.accumulator.blobGasAdmission(rejected.transaction) catch |err| switch (err) {
                    error.BlobGasOverflow => return error.CandidateRejectionMismatch,
                    else => return err,
                };
                self.finishRejected(admission.exceeds_limit, rejected.tx_index);
                return;
            }

            const before_calls = Engine.specification.block.beforeTransaction(.{
                .number = self.env.number,
                .timestamp = self.env.timestamp,
                .transaction_index = progress.tx_count,
            });
            if (before_calls.slice().len != 0) {
                return error.UnsupportedBeforeTransactionHooks;
            }

            const block_access_index = std.math.cast(bal.BlockAccessIndex, candidate_tx_index) orelse
                return error.BlockAccessIndexOverflow;
            var claim_reader = ClaimReader.init(self.base_reader, self.claim, block_access_index);
            const dependencies: Lane.ExecutionDependencies = .{
                .prepared_code_backend = self.prepared_code_backend,
                .block_hash_source = self.block_hash_source,
            };
            self.verifyRejectedAgainstClaim(rejected, claim_reader.reader(), dependencies) catch |err| {
                self.stopForRejectedError(err, rejected.tx_index, claim_reader.strategy_failure);
            };
        }

        fn verifyRejectedAgainstClaim(
            self: *Self,
            rejected: Rejected,
            reader: Reader,
            dependencies: Lane.ExecutionDependencies,
        ) !void {
            var executor = Engine.Executor.init(self.allocator, .{
                .state = .{ .reader = reader },
                .prepared_code_backend = dependencies.prepared_code_backend,
                .block_hash_source = dependencies.block_hash_source,
            });
            defer executor.deinit();

            const progress = self.accumulator.progress;
            const outcome = try Engine.Advanced.transact(&executor, .{
                .env = self.env,
                .tx = rejected.transaction,
                .progress = .{
                    .receipt_gas_used = progress.gas_used,
                    .block_gas = progress.block_gas,
                },
            });

            switch (outcome) {
                .rejected => self.finishRejected(
                    rejected.kind == .transaction,
                    rejected.tx_index,
                ),
                .executed => |executed_value| {
                    var executed = executed_value;
                    defer executed.discardIfCurrent();
                    if (rejected.kind != .block_gas) {
                        return error.CandidateRejectionMismatch;
                    }
                    const view = executed.view();
                    self.finishRejected(
                        try accumulator_types.executionExceedsBlockGas(
                            self.env,
                            progress,
                            view.output.*,
                        ),
                        rejected.tx_index,
                    );
                },
            }
        }

        fn finishRejected(self: *Self, matched: bool, tx_index: usize) void {
            self.report.status = if (matched) .rejection_matched else .candidate_rejection_mismatch;
            self.report.tx_index = tx_index;
            self.active = false;
        }

        pub fn finish(self: *Self) std.Io.Cancelable!void {
            try self.flushPending();
            if (self.active) {
                self.report.status = .outcomes_matched;
            }
            self.active = false;
        }

        /// Run block-final work over the claim-positioned view and return the
        /// independently assembled block artifacts. The caller remains
        /// responsible for exact comparison with canonical serial output.
        pub fn finishCandidate(
            self: *Self,
            withdrawals: []const Operations.Withdrawal,
        ) ?Artifacts {
            if (self.report.status != .outcomes_matched) return null;
            return self.finishCandidateFallible(withdrawals) catch |err| {
                self.stopForCandidateError(err, self.accumulator.transactionCount());
                return null;
            };
        }

        fn finishCandidateFallible(
            self: *Self,
            withdrawals: []const Operations.Withdrawal,
        ) !Artifacts {
            const transaction_count = std.math.cast(
                bal.BlockAccessIndex,
                self.accumulator.transactionCount(),
            ) orelse return error.BlockAccessIndexOverflow;
            const post_execution_index = try bal.postExecutionSystemIndex(transaction_count);

            // Reading the claim through the last transaction index already means
            // parent state, plus the block-start writes at index zero, plus every
            // transaction write. Rebuilding that view by folding observed
            // transitions produced the same thing at the cost of a whole
            // candidate-state layer.
            var post_reader = ClaimReader.init(self.base_reader, self.claim, transaction_count);
            var execution: Lane.CapturedExecution = undefined;
            try execution.init(self.allocator, post_reader.reader(), .{
                .prepared_code_backend = self.prepared_code_backend,
                .block_hash_source = self.block_hash_source,
            });
            defer execution.deinit();

            var observation_builder = tracked_state_projector.BlockBuilder.init(self.allocator);
            defer observation_builder.deinit();
            var observation_collector = Lane.ObservationCollector{
                .allocator = self.allocator,
                .builder = &observation_builder,
                .block_access_index = post_execution_index,
            };
            try Operations.applyCandidateWithdrawals(
                &execution.executor,
                self.lifecycle_execution_context,
                withdrawals,
                &observation_collector,
            );
            const requests = try Operations.deriveCandidateRequests(
                self.allocator,
                &execution.executor,
                self.env,
                self.accumulator.progress,
                self.accumulator.deposit_request_data.items,
                &observation_collector,
            );
            errdefer Operations.freeCandidateRequests(self.allocator, requests);
            const requests_hash = try Operations.candidateRequestsHash(self.allocator, requests);

            var post_shard = try observation_builder.finish();
            defer post_shard.deinit(self.allocator);
            try self.accumulator.appendShard(post_shard.accounts);

            var decoded_bal = try self.accumulator.bal_shard_fold.finish();
            defer decoded_bal.deinit(self.allocator);
            const encoded_bal = try bal.encodeAlloc(self.allocator, decoded_bal.accounts);
            errdefer self.allocator.free(encoded_bal);

            const progress = self.accumulator.progress;
            return .{
                .gas_used = progress.gas_used,
                .block_gas_used = progress.block_gas.total,
                .block_state_gas_used = progress.block_gas.state,
                .receipts_root = try Operations.candidateReceiptsRoot(
                    self.allocator,
                    self.accumulator.encoded_receipts.items,
                ),
                .encoded_receipts = self.accumulator.encoded_receipts.items,
                .logs_bloom = self.accumulator.block_logs_bloom,
                .blob_gas_used = self.accumulator.blob_gas_used,
                .requests = requests,
                .requests_hash = requests_hash,
                .encoded_block_access_list = encoded_bal,
            };
        }

        fn stopForError(
            self: *Self,
            err: anyerror,
            tx_index: usize,
            strategy_failure: ?ClaimReader.StrategyFailure,
        ) void {
            self.stop(report_types.statusForError(err, strategy_failure), tx_index, err);
        }

        fn stopForCandidateError(self: *Self, err: anyerror, tx_index: usize) void {
            self.stop(
                report_types.statusForCandidateError(err),
                tx_index,
                if (report_types.candidateErrorIsSemantic(err)) null else err,
            );
        }

        fn stopForRejectedError(
            self: *Self,
            err: anyerror,
            tx_index: usize,
            strategy_failure: ?ClaimReader.StrategyFailure,
        ) void {
            if (report_types.candidateErrorIsSemantic(err))
                self.stopForCandidateError(err, tx_index)
            else
                self.stopForError(err, tx_index, strategy_failure);
        }

        fn stop(self: *Self, status: Status, tx_index: usize, err: ?anyerror) void {
            self.report.status = status;
            self.report.tx_index = tx_index;
            self.report.diagnostic_error = err;
            self.active = false;
        }
    };
}
