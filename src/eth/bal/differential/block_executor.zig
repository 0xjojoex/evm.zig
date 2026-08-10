//! Single-use BAL parallel block executor and the candidate-lane operations
//! adapter.
//!
//! This file owns the concurrency-facing surface of the differential lane:
//! caller-bound runtime resources, submission strategy, and the operations
//! table that lets candidate lanes reuse the exact consensus encodings of the
//! serial block STF. The serial fold itself stays in `block_stf`.

const std = @import("std");

const block_stf = @import("../../block_stf.zig");
const eip6110 = @import("../../eip/6110.zig");
const observer_types = @import("observer.zig");
const receipt = @import("../../receipt.zig");
const report_types = @import("report.zig");
const trie = @import("../../trie.zig");
const execution = @import("../../../execution.zig");
const state = @import("../../../state.zig");
const transaction = @import("../../../transaction.zig");
const vm = @import("../../../vm.zig");
const Revision = @import("../../revision.zig").Revision;

const BlockHashSource = vm.BlockHashSource;

pub const Strategy = struct {
    /// Maximum candidate transactions retained and submitted in one batch.
    /// `1` exercises identical ownership and ordering without overlap.
    max_in_flight: usize,
    submission: Submission = .async,

    pub const Submission = report_types.ParallelSubmission;

    pub fn assertRequest(self: Strategy, report: ?*report_types.Report) void {
        std.debug.assert(self.max_in_flight > 0);
        std.debug.assert(report != null);
    }
};

pub const Resources = struct {
    /// Backing allocator for isolated growable task arenas. It must support
    /// overlapping allocation calls made by the supplied `std.Io` runtime.
    lane_allocator: std.mem.Allocator,
    /// Frozen concurrent view of the canonical authenticated pre-state. Null
    /// explicitly falls back to authoritative serial execution.
    state_reader: ?state.ConcurrentReader = null,
    /// Frozen concurrent BLOCKHASH source when the canonical input has one.
    block_hash_source: ?BlockHashSource.Concurrent = null,
};

pub fn Operations(
    comptime revision: Revision,
    comptime Engine: type,
) type {
    return struct {
        pub const BlockHeader = block_stf.BlockHeader;
        pub const Withdrawal = @import("../../Withdrawal.zig");

        pub fn appendCandidateDepositRequestData(
            allocator: std.mem.Allocator,
            output: *std.ArrayList(u8),
            logs: state.LogBuffer.View,
        ) !void {
            if (revision.isImpl(.prague))
                try eip6110.appendRequestDataFromLogs(allocator, output, logs);
        }

        pub fn encodeCandidateReceipt(
            allocator: std.mem.Allocator,
            kind: transaction.TxKind,
            receipt_view: vm.TxReceiptView,
        ) ![]u8 {
            return receipt.encode(allocator, kind, receipt_view);
        }

        pub fn candidateLogsBloom(logs: state.LogBuffer.View) [256]u8 {
            return receipt.logsBloom(logs);
        }

        pub fn mergeCandidateLogsBloom(target: *[256]u8, source: [256]u8) void {
            receipt.mergeLogsBloom(target, source);
        }

        pub fn applyCandidateWithdrawals(
            executor: *Engine.Executor,
            execution_context: execution.ExecutionContext,
            withdrawals: []const @import("../../Withdrawal.zig"),
            observer: anytype,
        ) !void {
            try block_stf.applyWithdrawals(executor, execution_context, withdrawals, observer);
        }

        pub fn deriveCandidateRequests(
            allocator: std.mem.Allocator,
            executor: *Engine.Executor,
            env: vm.Env,
            progress: vm.BlockResult,
            deposit_request_data: []const u8,
            observer: anytype,
        ) ![]const []const u8 {
            return block_stf.deriveRequests(
                allocator,
                executor,
                env,
                progress,
                deposit_request_data,
                observer,
            );
        }

        pub fn freeCandidateRequests(allocator: std.mem.Allocator, requests: []const []const u8) void {
            block_stf.freeRequests(allocator, requests);
        }

        pub fn candidateRequestsHash(allocator: std.mem.Allocator, requests: []const []const u8) ![32]u8 {
            return block_stf.requestsHash(allocator, requests);
        }

        pub fn candidateReceiptsRoot(allocator: std.mem.Allocator, receipts: []const []const u8) ![32]u8 {
            return trie.receiptRoot(allocator, receipts);
        }

        pub fn candidateTransactionBlobGasUsed(tx: transaction.Transaction) !u64 {
            return block_stf.transactionBlobGasUsed(revision, Engine, tx);
        }

        pub fn candidateBlockBlobGasLimit(
            blob_params: ?transaction.BlobParams,
        ) !u64 {
            return block_stf.blockBlobGasLimit(revision, Engine, blob_params);
        }
    };
}

pub fn Observer(comptime revision: Revision, comptime Engine: type) type {
    return observer_types.Observer(
        Engine,
        Operations(revision, Engine),
    );
}

/// Single-use BAL parallel block executor bound to caller-owned runtime
/// capabilities.
///
/// `io` and all borrowed input slices must remain valid through `run`. The
/// executor takes ownership of `input.state_backend`: `run` releases it on
/// every result, while `deinit` releases it when execution never starts.
/// Scheduling the whole `run` call through another task is valid, but the
/// caller must join or cancel that task before calling `deinit`.
pub fn Executor(comptime revision: Revision, comptime Engine: type) type {
    if (!Engine.specification.block.block_access_list) {
        @compileError("BalExecutor requires a fork that commits to an EIP-7928 block access list; " ++
            @tagName(revision) ++ " does not");
    }
    return struct {
        const Self = @This();

        io: std.Io,
        allocator: std.mem.Allocator,
        input: Input,
        strategy: Strategy,
        resources: Resources,
        lifecycle: Lifecycle = .ready,

        const Input = union(enum) {
            checked: block_stf.BlockInput,
            assume_decoded: block_stf.AssumeDecodedBlockInput,
        };

        const Lifecycle = enum {
            ready,
            running,
            finished,
        };

        /// Bind checked raw transaction input to the caller's I/O runtime.
        pub fn init(
            io: std.Io,
            allocator: std.mem.Allocator,
            input: block_stf.BlockInput,
            strategy: Strategy,
            resources: Resources,
        ) Self {
            strategy.assertRequest(input.bal_differential);
            return .{
                .io = io,
                .allocator = allocator,
                .input = .{ .checked = input },
                .strategy = strategy,
                .resources = resources,
            };
        }

        /// Bind values decoded by a trusted adapter to the caller's I/O runtime.
        pub fn initAssumeDecoded(
            io: std.Io,
            allocator: std.mem.Allocator,
            input: block_stf.AssumeDecodedBlockInput,
            strategy: Strategy,
            resources: Resources,
        ) Self {
            strategy.assertRequest(input.bal_differential);
            return .{
                .io = io,
                .allocator = allocator,
                .input = .{ .assume_decoded = input },
                .strategy = strategy,
                .resources = resources,
            };
        }

        /// Execute and join all private candidate work before returning.
        pub fn run(self: *Self) !block_stf.Result {
            std.debug.assert(self.lifecycle == .ready);
            self.lifecycle = .running;
            defer self.lifecycle = .finished;

            return switch (self.input) {
                .checked => |input| self.runChecked(input),
                .assume_decoded => |input| self.runAssumeDecoded(input),
            };
        }

        fn runChecked(self: *const Self, input: block_stf.BlockInput) !block_stf.Result {
            var state_backend = input.state_backend;
            var arena = std.heap.ArenaAllocator.init(self.allocator);
            defer arena.deinit();
            const transactions = block_stf.decodeRawTransactions(arena.allocator(), input.transactions) catch |err| {
                state_backend.deinit();
                return err;
            };
            return self.runAssumeDecoded(block_stf.assumeDecodedBlockInput(
                input,
                state_backend,
                transactions,
            ));
        }

        fn runAssumeDecoded(self: *const Self, input: block_stf.AssumeDecodedBlockInput) !block_stf.Result {
            block_stf.resetBalReport(input);
            var observer = Observer(revision, Engine).init(
                self.allocator,
                input.env,
                block_stf.lifecycleExecutionContext(input.env),
                input.prepared_code_backend,
                input.block_hash_source,
                input.bal_differential.?,
                self.parallelExecution(input),
            );
            defer observer.deinit();
            return block_stf.executeBlock(
                revision,
                Engine,
                self.allocator,
                block_stf.executionInput(input),
                .{ .validate = block_stf.validationClaims(input) },
                &observer,
            );
        }

        fn parallelExecution(
            self: *const Self,
            input: block_stf.AssumeDecodedBlockInput,
        ) ?report_types.ParallelExecution {
            const report = input.bal_differential.?;
            const concurrent_reader = self.resources.state_reader orelse {
                report.parallel_fallback = .concurrent_state_reader_unavailable;
                return null;
            };
            if (input.block_hash_source != null and self.resources.block_hash_source == null) {
                report.parallel_fallback = .concurrent_block_hash_source_unavailable;
                return null;
            }
            return .{
                .io = self.io,
                .submission = self.strategy.submission,
                .max_in_flight = self.strategy.max_in_flight,
                .lane_allocator = self.resources.lane_allocator,
                .state_reader = concurrent_reader.reader(),
                .block_hash_source = if (input.block_hash_source != null)
                    self.resources.block_hash_source.?.source()
                else
                    null,
            };
        }

        /// Release a transferred backend when `run` was never called.
        pub fn deinit(self: *Self) void {
            std.debug.assert(self.lifecycle != .running);
            if (self.lifecycle == .ready) {
                switch (self.input) {
                    .checked => self.input.checked.state_backend.deinit(),
                    .assume_decoded => self.input.assume_decoded.state_backend.deinit(),
                }
            }
            self.* = undefined;
        }
    };
}
