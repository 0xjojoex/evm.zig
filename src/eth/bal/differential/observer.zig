//! The candidate lane packaged as a serial-block observer.
//!
//! `BlockSTF` runs serially and reports its boundaries to an observer. This is
//! the only real implementation, so everything the candidate lane needs - the
//! claim projection, the runner, the produced artifacts - is owned here rather
//! than spread through the serial fold. The serial path itself knows nothing
//! about positioned reads, lanes, or concurrency.

const std = @import("std");

const ClaimView = @import("../ClaimView.zig");
const bal = @import("../model.zig");
const runner_types = @import("runner.zig");
const report_types = @import("report.zig");
const execution_values = @import("../../../execution.zig");
const prepared_code = @import("../../../prepared_code.zig");
const Reader = @import("../../../state/Reader.zig");
const vm = @import("../../../vm.zig");

const Report = report_types.Report;
const ParallelExecution = report_types.ParallelExecution;

pub fn Observer(comptime Engine: type, comptime Operations: type) type {
    return struct {
        const Self = @This();
        const Runner = runner_types.Runner(Engine, Operations);

        pub const Artifacts = Runner.Artifacts;

        allocator: std.mem.Allocator,
        env: vm.Env,
        lifecycle_execution_context: execution_values.ExecutionContext,
        prepared_code_backend: ?prepared_code.Backend,
        block_hash_source: ?vm.BlockHashSource,
        report: *Report,
        parallel_execution: ?ParallelExecution,
        /// Borrowed by `runner`, so this must not move once `claimDecoded` has
        /// run. The serial fold only ever holds a pointer to the observer.
        view: ?ClaimView = null,
        runner: ?Runner = null,
        candidate: ?Artifacts = null,

        pub fn init(
            allocator: std.mem.Allocator,
            env: vm.Env,
            lifecycle_execution_context: execution_values.ExecutionContext,
            prepared_code_backend: ?prepared_code.Backend,
            block_hash_source: ?vm.BlockHashSource,
            report: *Report,
            parallel_execution: ?ParallelExecution,
        ) Self {
            return .{
                .allocator = allocator,
                .env = env,
                .lifecycle_execution_context = lifecycle_execution_context,
                .prepared_code_backend = prepared_code_backend,
                .block_hash_source = block_hash_source,
                .report = report,
                .parallel_execution = parallel_execution,
            };
        }

        pub fn deinit(self: *Self) void {
            if (self.candidate) |*candidate| candidate.deinit(self.allocator);
            if (self.runner) |*value| value.deinit();
            if (self.view) |*value| value.deinit(self.allocator);
            self.* = undefined;
        }

        /// A lane only runs once a shape-validated claim exists to read from.
        /// The reader is borrowed from the serial fold's own state backend,
        /// which outlives every lane.
        pub fn claimDecoded(self: *Self, accounts: bal.BlockAccessList, base_reader: Reader) void {
            std.debug.assert(self.runner == null);
            self.view = ClaimView.initAssumeValidated(self.allocator, accounts) catch |err| {
                self.report.status = if (err == error.OutOfMemory)
                    .diagnostic_failure
                else
                    .claim_import_failed;
                self.report.diagnostic_error = err;
                return;
            };
            self.runner = Runner.init(
                self.allocator,
                self.env,
                self.lifecycle_execution_context,
                base_reader,
                self.prepared_code_backend,
                self.block_hash_source,
                &self.view.?,
                self.report,
                self.parallel_execution,
            );
        }

        pub fn isActive(self: *const Self) bool {
            const runner = self.runner orelse return false;
            return runner.active;
        }

        pub fn beforeBlock(self: *Self, header: anytype) void {
            const runner = if (self.runner) |*value| value else return;
            runner.verifyBeforeBlock(header);
        }

        pub fn included(self: *Self, value: Runner.Included) std.Io.Cancelable!void {
            const runner = if (self.runner) |*target| target else return;
            try runner.verifyIncluded(value);
        }

        pub fn rejected(self: *Self, value: Runner.Rejected) std.Io.Cancelable!void {
            const runner = if (self.runner) |*target| target else return;
            try runner.verifyRejected(value);
        }

        pub fn finish(self: *Self) std.Io.Cancelable!void {
            const runner = if (self.runner) |*value| value else return;
            try runner.finish();
        }

        pub fn finishCandidate(self: *Self, withdrawals: []const Operations.Withdrawal) void {
            const runner = if (self.runner) |*value| value else return;
            self.candidate = runner.finishCandidate(withdrawals);
        }

        /// Compare the independently assembled candidate block against the
        /// authoritative serial one. Exact observed-versus-claimed BAL bytes
        /// already pin every write, so this checks the derived commitments.
        pub fn compareBlock(self: *Self, canonical: Comparison) void {
            const candidate = if (self.candidate) |*value| value else return;
            const matched = candidate.gas_used == canonical.gas_used and
                candidate.block_gas_used == canonical.block_gas_used and
                candidate.block_state_gas_used == canonical.block_state_gas_used and
                candidate.blob_gas_used == canonical.blob_gas_used and
                std.mem.eql(u8, &candidate.receipts_root, &canonical.receipts_root) and
                std.mem.eql(u8, &candidate.logs_bloom, &canonical.logs_bloom) and
                std.mem.eql(u8, &candidate.requests_hash, &canonical.requests_hash) and
                byteSlicesEqual(candidate.encoded_receipts, canonical.encoded_receipts) and
                byteSlicesEqual(candidate.requests, canonical.requests) and
                std.mem.eql(u8, candidate.encoded_block_access_list, canonical.encoded_block_access_list);

            self.report.status = if (matched) .candidate_matched else .candidate_artifact_mismatch;
            if (!matched) {
                self.report.tx_index = canonical.transaction_count;
                return;
            }
            if (canonical.block_access_list_matched) self.report.status = .matched;
        }

        pub const Comparison = struct {
            gas_used: u64,
            block_gas_used: u64,
            block_state_gas_used: u64,
            blob_gas_used: u64,
            receipts_root: [32]u8,
            logs_bloom: [256]u8,
            requests_hash: [32]u8,
            encoded_receipts: []const []const u8,
            requests: []const []const u8,
            encoded_block_access_list: []const u8,
            block_access_list_matched: bool,
            transaction_count: usize,
        };
    };
}

fn byteSlicesEqual(left: []const []const u8, right: []const []const u8) bool {
    if (left.len != right.len) return false;
    for (left, right) |left_item, right_item| {
        if (!std.mem.eql(u8, left_item, right_item)) return false;
    }
    return true;
}
