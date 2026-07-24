//! Opt-in candidate execution over positioned BAL reads.
//!
//! This lane never owns canonical block state. Block-start work runs serially
//! over the authenticated base, each transaction executes in an isolated lane
//! over `BalClaimReader(base, claim, tx_index)`, and block-final work runs
//! serially over the folded candidate post-state. Transaction lanes may run in
//! caller-owned `std.Io` concurrency, but only the coordinator mutates folds or
//! report state. The first ambiguity, coverage failure, or mismatch disables
//! the complete claim lane; callers continue only on their independently owned
//! canonical reader.

const std = @import("std");

const Config = @import("../../ExecutionConfig.zig");
const Executor = @import("../../executor.zig");
const Host = @import("../../Host.zig");
const bal = @import("model.zig");
const ShardFold = @import("shard_fold.zig").ShardFold;
const ClaimView = @import("ClaimView.zig");
const batch_scheduler = @import("../../io/batch_scheduler.zig");
const lane_batch = @import("lane_batch.zig");
const candidate_transition = @import("candidate_transition.zig");
const tracked_state_projector = @import("tracked_state_projector.zig");
const prepared_code = @import("../../prepared_code.zig");
const BalClaimReader = @import("../../state/BalClaimReader.zig");
const Reader = @import("../../state/Reader.zig");
const state = @import("../../state.zig");
const vm = @import("../../vm.zig");

pub const Status = enum {
    not_run,
    outcomes_matched,
    candidate_matched,
    rejection_matched,
    matched,
    fallback_positioned_account,
    fallback_positioned_storage,
    fallback_folded_state_storage,
    fallback_parallel_runtime,
    diagnostic_failure,
    claim_account_not_covered,
    claim_storage_not_covered,
    claim_import_failed,
    outcome_mismatch,
    transition_fold_mismatch,
    candidate_artifact_mismatch,
    candidate_rejection_mismatch,
    unsupported_before_transaction_hooks,
    unsupported_after_transaction_hooks,

    pub fn isFallback(self: Status) bool {
        return switch (self) {
            .fallback_positioned_account,
            .fallback_positioned_storage,
            .fallback_folded_state_storage,
            .fallback_parallel_runtime,
            .unsupported_before_transaction_hooks,
            .unsupported_after_transaction_hooks,
            => true,
            else => false,
        };
    }

    pub fn isMismatch(self: Status) bool {
        return switch (self) {
            .claim_account_not_covered,
            .claim_storage_not_covered,
            .claim_import_failed,
            .outcome_mismatch,
            .transition_fold_mismatch,
            .candidate_artifact_mismatch,
            .candidate_rejection_mismatch,
            .diagnostic_failure,
            => true,
            else => false,
        };
    }
};

pub const ParallelSubmission = batch_scheduler.Submission;

pub const ParallelFallback = enum {
    concurrent_state_reader_unavailable,
    concurrent_block_hash_source_unavailable,
    lane_storage_unavailable,
    concurrency_unavailable,
    lane_out_of_memory,
};

/// Internal capability bundle supplied by BlockSTF after it validates the
/// caller's public parallel resources.
pub const ParallelExecution = struct {
    io: std.Io,
    submission: ParallelSubmission,
    max_in_flight: usize,
    /// Must be safe for overlapping allocations from separate lane arenas.
    lane_allocator: std.mem.Allocator,
    state_reader: Reader,
    block_hash_source: ?vm.BlockHashSource,
};

/// Caller-owned diagnostic output. `mismatch_writer` is optional and receives
/// the final expected-vs-observed per-account BAL diff from `BlockSTF`.
pub const Report = struct {
    status: Status = .not_run,
    tx_index: ?usize = null,
    diagnostic_error: ?anyerror = null,
    mismatch_writer: ?*std.Io.Writer = null,
    mismatch_write_failed: bool = false,
    folded_transactions: usize = 0,
    parallel_fallback: ?ParallelFallback = null,
    parallel_batches: usize = 0,
    parallel_submitted_lanes: usize = 0,
    /// Largest number of lanes submitted as one batch. This does not claim
    /// that the selected `std.Io` runtime executed those lanes concurrently.
    parallel_max_batch_size: usize = 0,

    pub fn reset(self: *Report) void {
        const writer = self.mismatch_writer;
        self.* = .{ .mismatch_writer = writer };
    }
};

pub fn Runner(comptime Engine: type, comptime Operations: type) type {
    return struct {
        const Self = @This();

        allocator: std.mem.Allocator,
        config: Config,
        env: vm.Env,
        lifecycle_tx_context: Host.TxContext,
        base_reader: Reader,
        prepared_code_backend: ?prepared_code.Backend,
        block_hash_source: ?vm.BlockHashSource,
        claim: *const ClaimView,
        report: *Report,
        transition_fold: candidate_transition.OrderedTransitionFold,
        bal_shard_fold: ShardFold,
        progress: vm.BlockResult = .{},
        encoded_receipts: std.ArrayList([]const u8) = .empty,
        deposit_request_data: std.ArrayList(u8) = .empty,
        block_logs_bloom: [256]u8 = [_]u8{0} ** 256,
        blob_gas_used: u64 = 0,
        pre_state: ?candidate_transition.CandidateState = null,
        claim_executor: ?Engine.Executor = null,
        parallel_batch: ?LaneBatch = null,
        active: bool = true,

        pub const Included = struct {
            transaction: Engine.Transaction,
            tx_index: usize,
            progress_before: vm.BlockResult,
            progress_after: vm.BlockResult,
            result: *const vm.TxExecutionResult,
            logs: state.TrackedState.LogView,
            blob_gas_used_after: u64,
        };

        pub const Rejected = struct {
            pub const Kind = enum {
                transaction,
                block_gas,
                blob_gas,
            };

            kind: Kind,
            transaction: Engine.Transaction,
            tx_index: usize,
            progress_before: vm.BlockResult,
            blob_gas_used_before: u64,
        };

        const OwnedIncluded = struct {
            transaction: Engine.Transaction,
            tx_index: usize,
            progress_before: vm.BlockResult,
            progress_after: vm.BlockResult,
            result: vm.TxExecutionResult,
            logs: []Host.Log,
            blob_gas_used_after: u64,

            fn init(allocator: std.mem.Allocator, included: Included) !OwnedIncluded {
                const output = try allocator.dupe(u8, included.result.output);
                errdefer allocator.free(output);
                const logs = try candidate_transition.cloneLogs(allocator, included.logs);
                var result = included.result.*;
                result.output = output;
                return .{
                    .transaction = included.transaction,
                    .tx_index = included.tx_index,
                    .progress_before = included.progress_before,
                    .progress_after = included.progress_after,
                    .result = result,
                    .logs = logs,
                    .blob_gas_used_after = included.blob_gas_used_after,
                };
            }

            fn view(self: *const OwnedIncluded) Included {
                return .{
                    .transaction = self.transaction,
                    .tx_index = self.tx_index,
                    .progress_before = self.progress_before,
                    .progress_after = self.progress_after,
                    .result = &self.result,
                    .logs = .fromSlice(self.logs),
                    .blob_gas_used_after = self.blob_gas_used_after,
                };
            }
        };

        pub const Artifacts = struct {
            state: candidate_transition.CandidateState,
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
                self.state.deinit(allocator);
                Operations.freeCandidateRequests(allocator, self.requests);
                allocator.free(self.encoded_block_access_list);
                self.* = undefined;
            }
        };

        pub fn init(
            allocator: std.mem.Allocator,
            config: Config,
            env: vm.Env,
            lifecycle_tx_context: Host.TxContext,
            base_reader: Reader,
            prepared_code_backend: ?prepared_code.Backend,
            block_hash_source: ?vm.BlockHashSource,
            claim: *const ClaimView,
            report: *Report,
            parallel_execution: ?ParallelExecution,
        ) Self {
            var self: Self = .{
                .allocator = allocator,
                .config = config,
                .env = env,
                .lifecycle_tx_context = lifecycle_tx_context,
                .base_reader = base_reader,
                .prepared_code_backend = prepared_code_backend,
                .block_hash_source = block_hash_source,
                .claim = claim,
                .report = report,
                .transition_fold = candidate_transition.OrderedTransitionFold.init(allocator),
                .bal_shard_fold = ShardFold.init(allocator),
            };
            if (parallel_execution) |execution| {
                self.parallel_batch = LaneBatch.init(
                    allocator,
                    execution.lane_allocator,
                    execution.io,
                    execution.submission,
                    execution.state_reader,
                    execution.block_hash_source,
                    execution.max_in_flight,
                    .{},
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
            if (self.claim_executor) |*executor| executor.deinit();
            if (self.pre_state) |*candidate| candidate.deinit(self.allocator);
            for (self.encoded_receipts.items) |encoded| self.allocator.free(encoded);
            self.encoded_receipts.deinit(self.allocator);
            self.deposit_request_data.deinit(self.allocator);
            self.bal_shard_fold.deinit();
            self.transition_fold.deinit();
            self.claim_executor = null;
        }

        /// Run the serial block-start shard over the authenticated base. This
        /// is deliberately independent from positioned transaction readers.
        pub fn verifyBeforeBlock(
            self: *Self,
            header: ?Operations.BlockHeader,
        ) void {
            if (!self.active) return;
            self.verifyBeforeBlockFallible(header) catch |err| {
                self.stopForCandidateError(err, 0);
            };
        }

        fn verifyBeforeBlockFallible(
            self: *Self,
            header: ?Operations.BlockHeader,
        ) !void {
            var execution: CapturedExecution = undefined;
            try execution.init(self.allocator, .{
                .state_reader = self.base_reader,
                .prepared_code_backend = self.prepared_code_backend,
                .block_hash_source = self.block_hash_source,
                .config = self.config,
            });
            defer execution.deinit();

            var observation_builder =
                tracked_state_projector.BlockBuilder.init(self.allocator);
            defer observation_builder.deinit();
            var state_fold = candidate_transition.OrderedTransitionFold.init(self.allocator);
            defer state_fold.deinit();
            var observation_collector = ObservationCollector{
                .allocator = self.allocator,
                .builder = &observation_builder,
                .state_fold = &state_fold,
                .block_access_index = 0,
            };
            if (header) |context| {
                try Executor.system_contracts.applyBeforeBlockObserved(
                    &execution.executor,
                    self.lifecycle_tx_context,
                    context,
                    &observation_collector,
                );
            }
            var shard = try observation_builder.finish();
            defer shard.deinit(self.allocator);
            try self.bal_shard_fold.append(shard.accounts);

            try state_fold.finish();
            std.debug.assert(self.pre_state == null);
            self.pre_state = state_fold.takeOwned();
        }

        const LaneFailure = struct {
            err: anyerror,
            strategy_failure: ?BalClaimReader.StrategyFailure,
        };

        const LaneOutcome = union(enum) {
            effects: candidate_transition.TransactionEffects,
            rejected,
            failed: LaneFailure,
        };

        const ObservationCollector = struct {
            allocator: std.mem.Allocator,
            builder: *tracked_state_projector.BlockBuilder,
            state_fold: ?*candidate_transition.OrderedTransitionFold = null,
            block_access_index: bal.BlockAccessIndex,

            pub fn observe(
                self: *ObservationCollector,
                pending: Engine.Executor.State.PendingView,
            ) !void {
                var transition = try tracked_state_projector.materialize(
                    pending.observations(),
                    self.allocator,
                );
                defer transition.deinit(self.allocator);
                try self.builder.appendTransition(transition, self.block_access_index);
                if (self.state_fold) |fold| try fold.appendNext(&transition);
            }
        };

        const CapturedExecution = struct {
            executor: Engine.Executor = undefined,

            fn init(
                self: *CapturedExecution,
                allocator: std.mem.Allocator,
                options: Engine.Executor.Init,
            ) !void {
                self.executor = Engine.Executor.init(allocator, options);
            }

            fn deinit(self: *CapturedExecution) void {
                self.executor.deinit();
                self.* = undefined;
            }
        };

        const LaneBatchCallbacks = struct {
            pub fn cloneItem(allocator: std.mem.Allocator, included: Included) !OwnedIncluded {
                return OwnedIncluded.init(allocator, included);
            }

            pub fn deinitOutcome(outcome: *LaneOutcome) void {
                switch (outcome.*) {
                    .effects => |*effects| effects.deinit(),
                    .rejected, .failed => {},
                }
            }

            pub fn run(
                runner: *const Self,
                allocator: std.mem.Allocator,
                base_reader: Reader,
                block_hash_source: ?vm.BlockHashSource,
                expected: *const OwnedIncluded,
            ) LaneOutcome {
                return runner.runLane(
                    allocator,
                    base_reader,
                    // The canonical prepared-code backend has no concurrent
                    // capability contract. Parallel lanes prepare privately.
                    null,
                    block_hash_source,
                    expected.view(),
                );
            }

            pub fn accept(
                runner: *Self,
                expected: *const OwnedIncluded,
                outcome: *LaneOutcome,
            ) void {
                const included = expected.view();
                if (runner.active and outcomeIsOutOfMemory(outcome.*))
                    runner.stopParallel(.lane_out_of_memory, included.tx_index, error.OutOfMemory)
                else
                    runner.acceptOutcome(included, outcome);
            }

            pub fn progress(runner: *const Self) vm.BlockResult {
                return runner.progress;
            }
        };

        const LaneBatch = lane_batch.Batch(
            Self,
            Included,
            OwnedIncluded,
            LaneOutcome,
            vm.BlockResult,
            LaneBatchCallbacks,
        );

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
            if (!self.validateIncludedBoundary(included, self.progress)) return;
            var outcome = self.runLane(
                self.allocator,
                self.base_reader,
                self.prepared_code_backend,
                self.block_hash_source,
                included,
            );
            switch (outcome) {
                .effects => |*effects| {
                    defer effects.deinit();
                    self.acceptLane(included, effects);
                },
                .rejected => self.stop(.outcome_mismatch, included.tx_index, null),
                .failed => |failure| self.stopForError(
                    failure.err,
                    included.tx_index,
                    failure.strategy_failure,
                ),
            }
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

        /// Execute one full bounded batch, then accept each detached result in
        /// transaction order. `async` may execute inline; `concurrent` must
        /// overlap or the complete diagnostic candidate falls back.
        fn flushPending(self: *Self) std.Io.Cancelable!void {
            const batch = if (self.parallel_batch) |*value| value else return;
            if (!batch.isEnabled() or !batch.hasPending()) return;

            const batch_result = try batch.flush(self);
            const submitted = switch (batch_result) {
                .completed => |count| count,
                .concurrency_unavailable => |unavailable| {
                    const tx_index = unavailable.failed.tx_index;
                    self.report.parallel_submitted_lanes += unavailable.submitted;
                    self.report.parallel_max_batch_size = @max(
                        self.report.parallel_max_batch_size,
                        unavailable.submitted,
                    );
                    self.discardPending();
                    self.stopParallel(
                        .concurrency_unavailable,
                        tx_index,
                        error.ConcurrencyUnavailable,
                    );
                    return;
                },
            };
            self.report.parallel_batches += 1;
            self.report.parallel_submitted_lanes += submitted;
            self.report.parallel_max_batch_size = @max(
                self.report.parallel_max_batch_size,
                submitted,
            );
        }

        fn acceptOutcome(self: *Self, included: Included, outcome: *LaneOutcome) void {
            if (!self.active) return;
            switch (outcome.*) {
                .effects => |*effects| self.acceptLane(included, effects),
                .rejected => self.stop(.outcome_mismatch, included.tx_index, null),
                .failed => |failure| self.stopForError(
                    failure.err,
                    included.tx_index,
                    failure.strategy_failure,
                ),
            }
        }

        fn outcomeIsOutOfMemory(outcome: LaneOutcome) bool {
            return switch (outcome) {
                .failed => |failure| failure.err == error.OutOfMemory,
                else => false,
            };
        }

        fn discardPending(self: *Self) void {
            const batch = if (self.parallel_batch) |*value| value else return;
            batch.discard(self.progress);
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

        fn runLane(
            self: *const Self,
            allocator: std.mem.Allocator,
            base_reader: Reader,
            candidate_prepared_code_backend: ?prepared_code.Backend,
            candidate_block_hash_source: ?vm.BlockHashSource,
            included: Included,
        ) LaneOutcome {
            // A transaction executes from the position before its writes:
            // transaction zero reads index zero; transaction N reads through N.
            const block_access_index = std.math.cast(bal.BlockAccessIndex, included.tx_index) orelse
                return .{ .failed = .{
                    .err = error.BlockAccessIndexOverflow,
                    .strategy_failure = null,
                } };
            var claim_reader = BalClaimReader.init(base_reader, self.claim, block_access_index);
            const effects = self.runLaneFallible(
                allocator,
                &claim_reader,
                candidate_prepared_code_backend,
                candidate_block_hash_source,
                included,
            ) catch |err| return .{ .failed = .{
                .err = err,
                .strategy_failure = claim_reader.strategy_failure,
            } };
            return if (effects) |owned| .{ .effects = owned } else .rejected;
        }

        fn runLaneFallible(
            self: *const Self,
            allocator: std.mem.Allocator,
            claim_reader: *BalClaimReader,
            candidate_prepared_code_backend: ?prepared_code.Backend,
            candidate_block_hash_source: ?vm.BlockHashSource,
            included: Included,
        ) !?candidate_transition.TransactionEffects {
            var execution: CapturedExecution = undefined;
            try execution.init(allocator, .{
                .state_reader = claim_reader.reader(),
                .prepared_code_backend = candidate_prepared_code_backend,
                .block_hash_source = candidate_block_hash_source,
                .config = self.config,
            });
            defer execution.deinit();

            var runtime = Engine.init(&execution.executor);
            const outcome = try runtime.transactObserved(.{
                .env = self.env,
                .tx = included.transaction,
                .progress = .{
                    .receipt_gas_used = included.progress_before.gas_used,
                    .block_gas = included.progress_before.block_gas,
                },
            });
            switch (outcome) {
                .rejected => return null,
                .executed => |executed_value| {
                    var executed = executed_value;
                    defer executed.discardIfCurrent();
                    var effects_builder = try candidate_transition.TransactionEffects.Builder.init(
                        executed,
                        try tracked_state_projector.materialize(
                            executed.observations(),
                            allocator,
                        ),
                    );
                    defer effects_builder.discardIfUnfinished();
                    try executed.retain();
                    return effects_builder.finish();
                },
            }
        }

        fn acceptLane(
            self: *Self,
            included: Included,
            effects: *const candidate_transition.TransactionEffects,
        ) void {
            if (!self.active) return;
            self.acceptLaneFallible(included, effects) catch |err|
                self.stopForCandidateError(err, included.tx_index);
        }

        fn acceptLaneFallible(
            self: *Self,
            included: Included,
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
            self.report.folded_transactions = self.transition_fold.transactionCount();

            const write_index = std.math.add(usize, included.tx_index, 1) catch
                return error.BlockAccessIndexOverflow;
            const transaction_write_index = std.math.cast(bal.BlockAccessIndex, write_index) orelse
                return error.BlockAccessIndexOverflow;
            var shard = try effects.toOwnedBalShard(transaction_write_index);
            defer shard.deinit(effects.allocator);
            try self.bal_shard_fold.append(shard.accounts);

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

        /// Replay only the authoritative serial fold's first failing
        /// transaction boundary. Earlier included lanes have already advanced
        /// `progress`; no post-state artifact exists for a rejected block.
        pub fn verifyRejected(self: *Self, rejected: Rejected) std.Io.Cancelable!void {
            try self.flushPending();
            if (!self.active) return;
            self.verifyRejectedFallible(rejected) catch |err|
                self.stopForCandidateError(err, rejected.tx_index);
        }

        fn verifyRejectedFallible(self: *Self, rejected: Rejected) !void {
            const candidate_tx_index = std.math.cast(usize, self.progress.tx_count) orelse
                return error.BlockAccessIndexOverflow;
            if (candidate_tx_index != rejected.tx_index) {
                return error.CandidateRejectionMismatch;
            }
            if (!std.meta.eql(self.progress, rejected.progress_before) or
                self.blob_gas_used != rejected.blob_gas_used_before)
            {
                return error.CandidateRejectionMismatch;
            }

            if (rejected.kind == .blob_gas) {
                const admission = self.blobGasAdmission(rejected.transaction) catch |err| switch (err) {
                    error.BlobGasOverflow => return error.CandidateRejectionMismatch,
                    else => return err,
                };
                self.finishRejected(admission.exceeds_limit, rejected.tx_index);
                return;
            }

            const before_calls = Engine.specification.block.beforeTransaction(.{
                .number = self.env.number,
                .timestamp = self.env.timestamp,
                .transaction_index = self.progress.tx_count,
            });
            if (before_calls.slice().len != 0) {
                return error.UnsupportedBeforeTransactionHooks;
            }

            const block_access_index = std.math.cast(bal.BlockAccessIndex, candidate_tx_index) orelse
                return error.BlockAccessIndexOverflow;
            var claim_reader = BalClaimReader.init(self.base_reader, self.claim, block_access_index);
            const executor_options: Engine.Executor.Init = .{
                .state_reader = claim_reader.reader(),
                .prepared_code_backend = self.prepared_code_backend,
                .block_hash_source = self.block_hash_source,
                .config = self.config,
            };
            self.verifyRejectedAgainstClaim(rejected, executor_options) catch |err| {
                self.stopForRejectedError(err, rejected.tx_index, claim_reader.strategy_failure);
            };
        }

        fn verifyRejectedAgainstClaim(
            self: *Self,
            rejected: Rejected,
            executor_options: Engine.Executor.Init,
        ) !void {
            if (self.claim_executor) |*executor|
                try executor.reset(executor_options)
            else
                self.claim_executor = Engine.Executor.init(self.allocator, executor_options);

            var runtime = Engine.init(&self.claim_executor.?);
            const outcome = try runtime.transact(.{
                .env = self.env,
                .tx = rejected.transaction,
                .progress = .{
                    .receipt_gas_used = self.progress.gas_used,
                    .block_gas = self.progress.block_gas,
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
                        try executionExceedsBlockGas(self.env, self.progress, view.output.*),
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
                self.transition_fold.finish() catch |err| {
                    self.stop(.diagnostic_failure, self.transition_fold.transactionCount(), err);
                    return;
                };
                const transaction_count = std.math.cast(
                    bal.BlockAccessIndex,
                    self.transition_fold.transactionCount(),
                ) orelse {
                    self.stop(.diagnostic_failure, self.transition_fold.transactionCount(), error.BlockAccessIndexOverflow);
                    return;
                };
                if (!candidateStateMatchesTransactionDelta(
                    self.transition_fold.view(),
                    self.claim,
                    transaction_count,
                )) {
                    self.stop(.transition_fold_mismatch, self.transition_fold.transactionCount(), null);
                    return;
                }
                self.report.status = .outcomes_matched;
            }
            self.active = false;
        }

        /// Reconstitute the complete candidate state, run block-final work
        /// serially over it, and return independently assembled artifacts.
        /// The caller remains responsible for exact comparison with canonical
        /// serial output; this method never commits candidate state.
        pub fn finishCandidate(
            self: *Self,
            withdrawals: []const Operations.Withdrawal,
        ) ?Artifacts {
            if (self.report.status != .outcomes_matched) return null;
            return self.finishCandidateFallible(withdrawals) catch |err| {
                self.stopForCandidateError(err, self.transition_fold.transactionCount());
                return null;
            };
        }

        fn finishCandidateFallible(
            self: *Self,
            withdrawals: []const Operations.Withdrawal,
        ) !Artifacts {
            const pre_state = if (self.pre_state) |*candidate|
                candidate
            else
                return error.CandidateBeforeBlockNotRun;

            var pre_reader = pre_state.readerOver(self.base_reader);
            var transaction_reader = self.transition_fold.view().readerOver(pre_reader.reader());
            const transaction_count = std.math.cast(
                bal.BlockAccessIndex,
                self.transition_fold.transactionCount(),
            ) orelse return error.BlockAccessIndexOverflow;
            const post_execution_index = try bal.postExecutionSystemIndex(transaction_count);
            var execution: CapturedExecution = undefined;
            try execution.init(self.allocator, .{
                .state_reader = transaction_reader.reader(),
                .prepared_code_backend = self.prepared_code_backend,
                .block_hash_source = self.block_hash_source,
                .config = self.config,
            });
            defer execution.deinit();

            var observation_builder =
                tracked_state_projector.BlockBuilder.init(self.allocator);
            defer observation_builder.deinit();
            var post_state_fold = candidate_transition.OrderedTransitionFold.init(self.allocator);
            defer post_state_fold.deinit();
            var observation_collector = ObservationCollector{
                .allocator = self.allocator,
                .builder = &observation_builder,
                .state_fold = &post_state_fold,
                .block_access_index = post_execution_index,
            };
            Operations.applyCandidateWithdrawals(
                &execution.executor,
                self.lifecycle_tx_context,
                withdrawals,
                &observation_collector,
            ) catch |err|
                return preserveFoldedStateError(
                    err,
                    transaction_reader.strategy_failure orelse pre_reader.strategy_failure,
                );
            const requests = Operations.deriveCandidateRequests(
                self.allocator,
                &execution.executor,
                self.env,
                self.progress,
                self.deposit_request_data.items,
                &observation_collector,
            ) catch |err| return preserveFoldedStateError(
                err,
                transaction_reader.strategy_failure orelse pre_reader.strategy_failure,
            );
            errdefer Operations.freeCandidateRequests(self.allocator, requests);
            const requests_hash = try Operations.candidateRequestsHash(self.allocator, requests);

            var post_shard = try observation_builder.finish();
            defer post_shard.deinit(self.allocator);
            try self.bal_shard_fold.append(post_shard.accounts);

            try post_state_fold.finish();
            var full_fold = candidate_transition.OrderedTransitionFold.init(self.allocator);
            defer full_fold.deinit();
            try full_fold.appendState(pre_state);
            try full_fold.appendState(self.transition_fold.view());
            try full_fold.appendState(post_state_fold.view());
            try full_fold.finish();
            var full_state = full_fold.takeOwned();
            errdefer full_state.deinit(self.allocator);

            var decoded_bal = try self.bal_shard_fold.finish();
            defer decoded_bal.deinit(self.allocator);
            const encoded_bal = try bal.encodeAlloc(self.allocator, decoded_bal.accounts);
            errdefer self.allocator.free(encoded_bal);

            return .{
                .state = full_state,
                .gas_used = self.progress.gas_used,
                .block_gas_used = self.progress.block_gas.total,
                .block_state_gas_used = self.progress.block_gas.state,
                .receipts_root = try Operations.candidateReceiptsRoot(self.allocator, self.encoded_receipts.items),
                .encoded_receipts = self.encoded_receipts.items,
                .logs_bloom = self.block_logs_bloom,
                .blob_gas_used = self.blob_gas_used,
                .requests = requests,
                .requests_hash = requests_hash,
                .encoded_block_access_list = encoded_bal,
            };
        }

        fn stopForError(
            self: *Self,
            err: anyerror,
            tx_index: usize,
            strategy_failure: ?BalClaimReader.StrategyFailure,
        ) void {
            self.stop(statusForError(err, strategy_failure), tx_index, err);
        }

        fn stopForCandidateError(self: *Self, err: anyerror, tx_index: usize) void {
            self.stop(
                statusForCandidateError(err),
                tx_index,
                if (candidateErrorIsSemantic(err)) null else err,
            );
        }

        fn stopForRejectedError(
            self: *Self,
            err: anyerror,
            tx_index: usize,
            strategy_failure: ?BalClaimReader.StrategyFailure,
        ) void {
            if (candidateErrorIsSemantic(err))
                self.stopForCandidateError(err, tx_index)
            else
                self.stopForError(err, tx_index, strategy_failure);
        }

        const BlobGasAdmission = struct {
            next: u64,
            exceeds_limit: bool,
        };

        fn blobGasAdmission(self: *const Self, tx: Engine.Transaction) anyerror!BlobGasAdmission {
            const transaction_blob_gas = try Operations.candidateTransactionBlobGasUsed(
                self.env.blob_schedule,
                tx,
            );
            const next = std.math.add(u64, self.blob_gas_used, transaction_blob_gas) catch
                return error.BlobGasOverflow;
            const limit = try Operations.candidateBlockBlobGasLimit(
                self.env.blob_schedule,
            );
            return .{ .next = next, .exceeds_limit = next > limit };
        }

        fn stop(self: *Self, status: Status, tx_index: usize, err: ?anyerror) void {
            self.report.status = status;
            self.report.tx_index = tx_index;
            self.report.diagnostic_error = err;
            self.active = false;
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

/// One-sided diagnostic over the same field-level shape used by BAL. Exact
/// observed-vs-claimed BAL bytes remain the soundness gate in both directions.
fn candidateStateMatchesTransactionDelta(
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

fn advanceProgress(
    env: vm.Env,
    progress: vm.BlockResult,
    result: vm.TxExecutionResult,
) !vm.BlockResult {
    var next = progress;
    // Match the authoritative block program: either receipt-gas or
    // dimensional block-gas overflow is a block-gas admission rejection.
    next.gas_used = std.math.add(u64, next.gas_used, result.gas.used) catch return error.BlockGasExceeded;
    next.block_gas = next.block_gas.add(result.gas.block) catch return error.BlockGasExceeded;
    if (!next.block_gas.withinLimit(env.gas_limit)) return error.BlockGasExceeded;
    next.tx_count = std.math.add(u64, next.tx_count, 1) catch return error.BlockProgressOverflow;
    return next;
}

fn executionExceedsBlockGas(
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

fn statusForError(err: anyerror, strategy_failure: ?BalClaimReader.StrategyFailure) Status {
    if (err == error.StateReaderStrategyFailure) {
        const failure = strategy_failure orelse return .diagnostic_failure;
        return switch (failure) {
            .positioned_account_unknown => .fallback_positioned_account,
            .positioned_storage_unknown => .fallback_positioned_storage,
            .account_not_covered => .claim_account_not_covered,
            .storage_not_covered => .claim_storage_not_covered,
        };
    }
    return .diagnostic_failure;
}

fn statusForCandidateError(err: anyerror) Status {
    return switch (err) {
        error.OutcomeMismatch => .outcome_mismatch,
        error.CandidateArtifactMismatch => .candidate_artifact_mismatch,
        error.CandidateRejectionMismatch => .candidate_rejection_mismatch,
        error.UnsupportedBeforeTransactionHooks => .unsupported_before_transaction_hooks,
        error.UnsupportedAfterTransactionHooks => .unsupported_after_transaction_hooks,
        error.FoldedStateStorageUnknown => .fallback_folded_state_storage,
        else => .diagnostic_failure,
    };
}

fn candidateErrorIsSemantic(err: anyerror) bool {
    return switch (err) {
        error.OutcomeMismatch,
        error.CandidateArtifactMismatch,
        error.CandidateRejectionMismatch,
        error.UnsupportedBeforeTransactionHooks,
        error.UnsupportedAfterTransactionHooks,
        => true,
        else => false,
    };
}

/// Executor boundaries normalize type-erased reader failures. Restore the one
/// strategy detail owned by the folded reader so ambiguity remains a fallback
/// rather than becoming a fatal diagnostic mismatch.
fn preserveFoldedStateError(
    err: anyerror,
    strategy_failure: ?candidate_transition.FoldedStateReader.StrategyFailure,
) anyerror {
    if (err == error.StateReaderStrategyFailure and
        strategy_failure == .storage_presence_unknown)
    {
        return error.FoldedStateStorageUnknown;
    }
    return err;
}

test "BAL differential status classifies whole-lane fallback and mismatch" {
    try std.testing.expect(Status.fallback_positioned_account.isFallback());
    try std.testing.expect(Status.fallback_positioned_storage.isFallback());
    try std.testing.expect(Status.fallback_folded_state_storage.isFallback());
    try std.testing.expect(Status.fallback_parallel_runtime.isFallback());
    try std.testing.expect(Status.diagnostic_failure.isMismatch());
    try std.testing.expect(Status.claim_account_not_covered.isMismatch());
    try std.testing.expect(Status.claim_storage_not_covered.isMismatch());
    try std.testing.expect(Status.outcome_mismatch.isMismatch());
    try std.testing.expect(Status.transition_fold_mismatch.isMismatch());
    try std.testing.expect(Status.candidate_artifact_mismatch.isMismatch());
    try std.testing.expect(Status.candidate_rejection_mismatch.isMismatch());
    try std.testing.expect(!Status.matched.isFallback());
    try std.testing.expect(!Status.matched.isMismatch());
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
    try std.testing.expect(try executionExceedsBlockGas(
        .{ .gas_limit = 20 },
        progress,
        result,
    ));
    try std.testing.expect(!try executionExceedsBlockGas(
        .{ .gas_limit = 21 },
        progress,
        result,
    ));

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
        executionExceedsBlockGas(
            .{},
            .{ .tx_count = std.math.maxInt(u64) },
            count_overflow,
        ),
    );
}

test "BAL strategy errors preserve differential policy" {
    try std.testing.expectEqual(Status.fallback_positioned_account, statusForError(error.StateReaderStrategyFailure, .positioned_account_unknown));
    try std.testing.expectEqual(Status.fallback_positioned_storage, statusForError(error.StateReaderStrategyFailure, .positioned_storage_unknown));
    try std.testing.expectEqual(Status.claim_account_not_covered, statusForError(error.StateReaderStrategyFailure, .account_not_covered));
    try std.testing.expectEqual(Status.claim_storage_not_covered, statusForError(error.StateReaderStrategyFailure, .storage_not_covered));
    try std.testing.expectEqual(Status.diagnostic_failure, statusForError(error.StateReaderStrategyFailure, null));
    try std.testing.expectEqual(Status.diagnostic_failure, statusForError(error.ProviderSpecificFailure, null));
}

test "folded state reader normalization preserves fallback policy" {
    const restored = preserveFoldedStateError(
        error.StateReaderStrategyFailure,
        .storage_presence_unknown,
    );
    try std.testing.expectEqual(error.FoldedStateStorageUnknown, restored);
    try std.testing.expectEqual(
        Status.fallback_folded_state_storage,
        statusForCandidateError(restored),
    );
    try std.testing.expectEqual(
        error.StateReaderStrategyFailure,
        preserveFoldedStateError(error.StateReaderStrategyFailure, null),
    );
}
