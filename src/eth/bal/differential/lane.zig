//! One transaction executed against one positioned BAL read view.
//!
//! A lane owns nothing the coordinator owns. It takes an immutable block
//! context plus a transaction the authoritative fold already executed, runs it
//! over `ClaimReader(base, claim, tx_index)`, and hands back BAL evidence.
//!
//! The lane compares its own result and logs against the canonical ones while
//! its executor is still alive, so a disagreement never travels. What comes
//! back is only the observed transition, which the coordinator cannot obtain
//! any other way. Lanes may therefore run concurrently; deciding what an
//! outcome means to the block belongs to `accumulator` and `runner`.

const std = @import("std");

const bal = @import("../model.zig");
const observation = @import("../observation.zig");
const ClaimView = @import("../ClaimView.zig");
const tracked_state_projector = @import("../tracked_state_projector.zig");
const prepared_code = @import("../../../prepared_code.zig");
const ClaimReader = @import("../ClaimReader.zig");
const Reader = @import("../../../state/Reader.zig");
const state = @import("../../../state.zig");
const vm = @import("../../../vm.zig");

pub fn Lane(comptime Engine: type) type {
    return struct {
        pub const ExecutionDependencies = struct {
            prepared_code_backend: ?prepared_code.Backend = null,
            block_hash_source: ?vm.BlockHashSource = null,
        };

        /// Everything a lane needs that stays constant for the whole block.
        pub const Context = struct {
            env: vm.Env,
            claim: *const ClaimView,
            /// The canonical prepared-code backend has no concurrent capability
            /// contract, so parallel lanes leave this null and prepare privately.
            prepared_code_backend: ?prepared_code.Backend = null,
            block_hash_source: ?vm.BlockHashSource = null,
        };

        /// One transaction the authoritative serial fold included, paired with
        /// the block progress it observed on either side.
        pub const Included = struct {
            transaction: Engine.Transaction,
            tx_index: usize,
            progress_before: vm.BlockResult,
            progress_after: vm.BlockResult,
            result: *const vm.TxExecutionResult,
            logs: state.LogBuffer.View,
            blob_gas_used_after: u64,
        };

        /// One transaction the authoritative serial fold refused to include.
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

        /// `Included` with every borrowed slice copied, so a staged lane
        /// survives the authoritative executor moving on.
        pub const OwnedIncluded = struct {
            transaction: Engine.Transaction,
            tx_index: usize,
            progress_before: vm.BlockResult,
            progress_after: vm.BlockResult,
            result: vm.TxExecutionResult,
            logs: state.LogBuffer,
            blob_gas_used_after: u64,

            pub fn init(allocator: std.mem.Allocator, included: Included) !OwnedIncluded {
                const output = try allocator.dupe(u8, included.result.output);
                errdefer allocator.free(output);
                // Detach the canonical logs so a staged lane survives the
                // authoritative executor moving on.
                const logs = try state.LogBuffer.fromView(allocator, included.logs);
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

            pub fn view(self: *const OwnedIncluded) Included {
                return .{
                    .transaction = self.transaction,
                    .tx_index = self.tx_index,
                    .progress_before = self.progress_before,
                    .progress_after = self.progress_after,
                    .result = &self.result,
                    .logs = self.logs.view(),
                    .blob_gas_used_after = self.blob_gas_used_after,
                };
            }
        };

        pub const Failure = struct {
            err: anyerror,
            /// Retained beside the generic executor error because executor
            /// boundaries normalize type-erased reader failures.
            strategy_failure: ?ClaimReader.StrategyFailure,
        };

        pub const Outcome = union(enum) {
            /// The lane agreed with canonical execution. Only the observed
            /// transition travels, because the coordinator already holds the
            /// canonical result and logs it was compared against.
            evidence: observation.LaneTransition,
            /// The lane executed but disagreed on result or logs.
            outcome_mismatch,
            /// The lane refused the transaction the canonical fold included.
            rejected,
            failed: Failure,

            pub fn deinit(self: *Outcome, allocator: std.mem.Allocator) void {
                switch (self.*) {
                    .evidence => |*transition| transition.deinit(allocator),
                    .outcome_mismatch, .rejected, .failed => {},
                }
            }

            pub fn isOutOfMemory(self: Outcome) bool {
                return switch (self) {
                    .failed => |failure| failure.err == error.OutOfMemory,
                    else => false,
                };
            }
        };

        /// Scoped executor for one isolated piece of block work.
        pub const CapturedExecution = struct {
            executor: Engine.Executor = undefined,

            pub fn init(
                self: *CapturedExecution,
                allocator: std.mem.Allocator,
                reader: Reader,
                dependencies: ExecutionDependencies,
            ) !void {
                self.executor = Engine.Executor.init(allocator, .{
                    .state = .{ .reader = reader },
                    .prepared_code_backend = dependencies.prepared_code_backend,
                    .block_hash_source = dependencies.block_hash_source,
                });
            }

            pub fn deinit(self: *CapturedExecution) void {
                self.executor.deinit();
                self.* = undefined;
            }
        };

        /// Sink for system-call observations at one block access index. Used by
        /// the serial block-start and block-final phases, not by lanes.
        pub const ObservationCollector = struct {
            allocator: std.mem.Allocator,
            builder: *tracked_state_projector.BlockBuilder,
            block_access_index: bal.BlockAccessIndex,

            pub fn observe(
                self: *ObservationCollector,
                transition_view: Engine.Executor.Observation,
            ) !void {
                var transition = try tracked_state_projector.materialize(
                    transition_view.observations(),
                    self.allocator,
                );
                defer transition.deinit(self.allocator);
                try self.builder.appendTransition(transition, self.block_access_index);
            }
        };

        /// Execute `included` from the position before its own writes:
        /// transaction zero reads index zero; transaction N reads through N.
        pub fn run(
            context: Context,
            allocator: std.mem.Allocator,
            base_reader: Reader,
            included: Included,
        ) Outcome {
            const block_access_index = std.math.cast(bal.BlockAccessIndex, included.tx_index) orelse
                return .{ .failed = .{
                    .err = error.BlockAccessIndexOverflow,
                    .strategy_failure = null,
                } };
            var claim_reader = ClaimReader.init(base_reader, context.claim, block_access_index);
            return runFallible(context, allocator, &claim_reader, included) catch |err|
                .{ .failed = .{
                    .err = err,
                    .strategy_failure = claim_reader.strategy_failure,
                } };
        }

        fn runFallible(
            context: Context,
            allocator: std.mem.Allocator,
            claim_reader: *ClaimReader,
            included: Included,
        ) !Outcome {
            var execution: CapturedExecution = undefined;
            try execution.init(allocator, claim_reader.reader(), .{
                .prepared_code_backend = context.prepared_code_backend,
                .block_hash_source = context.block_hash_source,
            });
            defer execution.deinit();

            var runtime = Engine.init(&execution.executor);
            const outcome = try runtime.observe().transact(.{
                .env = context.env,
                .tx = included.transaction,
                .progress = .{
                    .receipt_gas_used = included.progress_before.gas_used,
                    .block_gas = included.progress_before.block_gas,
                },
            });
            switch (outcome) {
                .rejected => return .rejected,
                .executed => |executed_value| {
                    var executed = executed_value;
                    // The lane's executor is torn down either way; nothing here
                    // needs the transaction retained past this scope.
                    defer executed.discardIfCurrent();
                    const view = executed.view();
                    if (!executionResultEqual(view.output.*, included.result.*) or
                        !logsEqual(view.logs, included.logs))
                    {
                        return .outcome_mismatch;
                    }
                    return .{ .evidence = try tracked_state_projector.materialize(
                        executed.observations(),
                        allocator,
                    ) };
                },
            }
        }
    };
}

fn executionResultEqual(expected: vm.TxExecutionResult, actual: vm.TxExecutionResult) bool {
    return expected.status == actual.status and
        std.meta.eql(expected.gas, actual.gas) and
        std.mem.eql(u8, expected.output, actual.output) and
        std.meta.eql(expected.created_address, actual.created_address);
}

fn logsEqual(expected: state.LogBuffer.View, actual: state.LogBuffer.View) bool {
    if (expected.len() != actual.len()) return false;
    for (0..expected.len()) |index| {
        const left = expected.get(index);
        const right = actual.get(index);
        if (!bal.Address.eql(left.address, right.address) or
            !std.mem.eql(u256, left.topics, right.topics) or
            !std.mem.eql(u8, left.data, right.data))
        {
            return false;
        }
    }
    return true;
}
