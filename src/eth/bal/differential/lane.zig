//! One transaction executed against one positioned BAL read view.
//!
//! A lane owns nothing the coordinator owns. It takes an immutable block
//! context plus a transaction the authoritative fold already executed, runs it
//! over `BalClaimReader(base, claim, tx_index)`, and hands back a detached
//! `TransactionEffects`. Lanes may therefore run concurrently; deciding what a
//! result means belongs to `accumulator` and `runner`.

const std = @import("std");

const Host = @import("../../../Host.zig");
const bal = @import("../model.zig");
const ClaimView = @import("../ClaimView.zig");
const candidate_transition = @import("../candidate_transition.zig");
const tracked_state_projector = @import("../tracked_state_projector.zig");
const prepared_code = @import("../../../prepared_code.zig");
const BalClaimReader = @import("../../../state/BalClaimReader.zig");
const Reader = @import("../../../state/Reader.zig");
const state = @import("../../../state.zig");
const vm = @import("../../../vm.zig");

pub fn Lane(comptime Engine: type) type {
    return struct {
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
            logs: state.TrackedState.LogView,
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
            logs: []Host.Log,
            blob_gas_used_after: u64,

            pub fn init(allocator: std.mem.Allocator, included: Included) !OwnedIncluded {
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

            pub fn view(self: *const OwnedIncluded) Included {
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

        pub const Failure = struct {
            err: anyerror,
            /// Retained beside the generic executor error because executor
            /// boundaries normalize type-erased reader failures.
            strategy_failure: ?BalClaimReader.StrategyFailure,
        };

        pub const Outcome = union(enum) {
            effects: candidate_transition.TransactionEffects,
            rejected,
            failed: Failure,

            pub fn deinit(self: *Outcome) void {
                switch (self.*) {
                    .effects => |*effects| effects.deinit(),
                    .rejected, .failed => {},
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
                options: Engine.Executor.Init,
            ) !void {
                self.executor = Engine.Executor.init(allocator, options);
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
                pending: Engine.Executor.State.PendingView,
            ) !void {
                var transition = try tracked_state_projector.materialize(
                    pending.observations(),
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
            var claim_reader = BalClaimReader.init(base_reader, context.claim, block_access_index);
            const effects = runFallible(context, allocator, &claim_reader, included) catch |err|
                return .{ .failed = .{
                    .err = err,
                    .strategy_failure = claim_reader.strategy_failure,
                } };
            return if (effects) |owned| .{ .effects = owned } else .rejected;
        }

        fn runFallible(
            context: Context,
            allocator: std.mem.Allocator,
            claim_reader: *BalClaimReader,
            included: Included,
        ) !?candidate_transition.TransactionEffects {
            var execution: CapturedExecution = undefined;
            try execution.init(allocator, .{
                .state_reader = claim_reader.reader(),
                .prepared_code_backend = context.prepared_code_backend,
                .block_hash_source = context.block_hash_source,
            });
            defer execution.deinit();

            var runtime = Engine.init(&execution.executor);
            const outcome = try runtime.transactObserved(.{
                .env = context.env,
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
                    executed.retain();
                    return effects_builder.finish();
                },
            }
        }
    };
}
