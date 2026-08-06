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
const Status = report_types.Status;
const ParallelExecution = report_types.ParallelExecution;

pub fn Observer(comptime Engine: type, comptime Operations: type) type {
    return struct {
        const Self = @This();
        const Runner = runner_types.Runner(Engine, Operations);

        const Artifacts = Runner.Artifacts;

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
            const runner = if (self.runner) |*value| value else return false;
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

        /// Compare candidate outcome-derived BAL evidence and block accounting
        /// against the authoritative serial artifacts. This does not compute
        /// an independent candidate post-state root.
        pub fn compareBlock(self: *Self, canonical: Comparison) void {
            const candidate = if (self.candidate) |*value| value else return;
            self.report.status = comparisonStatus(candidate.*, canonical);
            if (self.report.status == .candidate_artifact_mismatch) {
                self.report.tx_index = canonical.transaction_count;
            }
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

        comptime {
            assertArtifactComparisonSchema(Artifacts, Comparison);
        }
    };
}

fn comparisonStatus(candidate: anytype, canonical: anytype) Status {
    comptime assertArtifactComparisonSchema(@TypeOf(candidate), @TypeOf(canonical));
    inline for (@typeInfo(@TypeOf(candidate)).@"struct".fields) |field| {
        if (!artifactFieldMatches(
            field.name,
            @field(candidate, field.name),
            @field(canonical, field.name),
        )) return .candidate_artifact_mismatch;
    }
    return if (canonical.block_access_list_matched) .matched else .candidate_matched;
}

fn assertArtifactComparisonSchema(comptime Candidate: type, comptime Canonical: type) void {
    for (@typeInfo(Candidate).@"struct".fields) |field| {
        if (!@hasField(Canonical, field.name)) {
            @compileError("candidate artifact missing from comparison: " ++ field.name);
        }
    }
    for (@typeInfo(Canonical).@"struct".fields) |field| {
        if (!@hasField(Candidate, field.name) and !isComparisonMetadata(field.name)) {
            @compileError("comparison field is neither an artifact nor metadata: " ++ field.name);
        }
    }
}

fn isComparisonMetadata(comptime name: []const u8) bool {
    return std.mem.eql(u8, name, "block_access_list_matched") or
        std.mem.eql(u8, name, "transaction_count");
}

fn artifactFieldMatches(comptime name: []const u8, candidate: anytype, canonical: anytype) bool {
    if (comptime std.mem.eql(u8, name, "encoded_receipts") or
        std.mem.eql(u8, name, "requests"))
    {
        return byteSlicesEqual(candidate, canonical);
    }
    if (comptime std.mem.eql(u8, name, "receipts_root") or
        std.mem.eql(u8, name, "logs_bloom") or
        std.mem.eql(u8, name, "requests_hash"))
    {
        return std.mem.eql(u8, &candidate, &canonical);
    }
    if (comptime std.mem.eql(u8, name, "encoded_block_access_list")) {
        return std.mem.eql(u8, candidate, canonical);
    }
    return candidate == canonical;
}

fn byteSlicesEqual(left: []const []const u8, right: []const []const u8) bool {
    if (left.len != right.len) return false;
    for (left, right) |left_item, right_item| {
        if (!std.mem.eql(u8, left_item, right_item)) return false;
    }
    return true;
}

test "candidate comparison checks every artifact field" {
    const Candidate = struct {
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
    };
    const Canonical = struct {
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
    };

    var candidate_receipt = [_]u8{ 0x01, 0x02 };
    var canonical_receipt = candidate_receipt;
    const candidate_receipts = [_][]const u8{&candidate_receipt};
    const canonical_receipts = [_][]const u8{&canonical_receipt};
    var candidate_request = [_]u8{ 0x03, 0x04 };
    var canonical_request = candidate_request;
    const candidate_requests = [_][]const u8{&candidate_request};
    const canonical_requests = [_][]const u8{&canonical_request};
    var candidate_bal = [_]u8{ 0xc1, 0x80 };
    var canonical_bal = candidate_bal;

    var candidate = Candidate{
        .gas_used = 1,
        .block_gas_used = 2,
        .block_state_gas_used = 3,
        .blob_gas_used = 4,
        .receipts_root = [_]u8{0x11} ** 32,
        .logs_bloom = [_]u8{0x22} ** 256,
        .requests_hash = [_]u8{0x33} ** 32,
        .encoded_receipts = &candidate_receipts,
        .requests = &candidate_requests,
        .encoded_block_access_list = &candidate_bal,
    };
    var canonical = Canonical{
        .gas_used = candidate.gas_used,
        .block_gas_used = candidate.block_gas_used,
        .block_state_gas_used = candidate.block_state_gas_used,
        .blob_gas_used = candidate.blob_gas_used,
        .receipts_root = candidate.receipts_root,
        .logs_bloom = candidate.logs_bloom,
        .requests_hash = candidate.requests_hash,
        .encoded_receipts = &canonical_receipts,
        .requests = &canonical_requests,
        .encoded_block_access_list = &canonical_bal,
        .block_access_list_matched = true,
    };
    try std.testing.expectEqual(Status.matched, comparisonStatus(candidate, canonical));

    candidate.gas_used += 1;
    try std.testing.expectEqual(Status.candidate_artifact_mismatch, comparisonStatus(candidate, canonical));
    candidate.gas_used -= 1;
    candidate.block_gas_used += 1;
    try std.testing.expectEqual(Status.candidate_artifact_mismatch, comparisonStatus(candidate, canonical));
    candidate.block_gas_used -= 1;
    candidate.block_state_gas_used += 1;
    try std.testing.expectEqual(Status.candidate_artifact_mismatch, comparisonStatus(candidate, canonical));
    candidate.block_state_gas_used -= 1;
    candidate.blob_gas_used += 1;
    try std.testing.expectEqual(Status.candidate_artifact_mismatch, comparisonStatus(candidate, canonical));
    candidate.blob_gas_used -= 1;

    candidate.receipts_root[0] ^= 1;
    try std.testing.expectEqual(Status.candidate_artifact_mismatch, comparisonStatus(candidate, canonical));
    candidate.receipts_root[0] ^= 1;
    candidate.logs_bloom[0] ^= 1;
    try std.testing.expectEqual(Status.candidate_artifact_mismatch, comparisonStatus(candidate, canonical));
    candidate.logs_bloom[0] ^= 1;
    candidate.requests_hash[0] ^= 1;
    try std.testing.expectEqual(Status.candidate_artifact_mismatch, comparisonStatus(candidate, canonical));
    candidate.requests_hash[0] ^= 1;

    candidate_receipt[0] ^= 1;
    try std.testing.expectEqual(Status.candidate_artifact_mismatch, comparisonStatus(candidate, canonical));
    candidate_receipt[0] ^= 1;
    candidate_request[0] ^= 1;
    try std.testing.expectEqual(Status.candidate_artifact_mismatch, comparisonStatus(candidate, canonical));
    candidate_request[0] ^= 1;
    candidate_bal[0] ^= 1;
    try std.testing.expectEqual(Status.candidate_artifact_mismatch, comparisonStatus(candidate, canonical));
    candidate_bal[0] ^= 1;

    canonical.block_access_list_matched = false;
    try std.testing.expectEqual(Status.candidate_matched, comparisonStatus(candidate, canonical));
}
