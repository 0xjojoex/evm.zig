//! Ethereum block state-transition orchestration above the engine's bound
//! block program.
//!
//! This module owns block-level lifecycle policy: system-contract hooks,
//! transaction folding, withdrawal credits, root/commitment assembly, and
//! compare-vs-claim mismatch taxonomy. Stateless guests are callers of this
//! layer; they do not own Ethereum block semantics.

const std = @import("std");

const Executor = @import("../executor.zig");
const address = @import("../address.zig");
const crypto = @import("../crypto.zig");
const eth_bal = @import("bal/model.zig");
const bal_differential = @import("bal/differential.zig");
const differential_executor = @import("bal/differential/block_executor.zig");
const tracked_state_projector = @import("bal/tracked_state_projector.zig");
const block_admission = @import("block_admission.zig");
const block_capture = @import("block_capture.zig");
const block_rules = @import("block_rules.zig");
const eth_receipt = @import("receipt.zig");
const execution = @import("../execution.zig");
const execution_resources = @import("../execution/resources.zig");
const eip6110 = @import("eip/6110.zig");
const eip7685 = @import("eip/7685.zig");
const eth_spec = @import("spec.zig");
const trie = @import("trie.zig");
const prepared_code = @import("../prepared_code.zig");
const Withdrawal = @import("Withdrawal.zig");
const Revision = @import("revision.zig").Revision;
const transaction = @import("../transaction.zig");
const trace = @import("../trace.zig");
const vm = @import("../vm.zig");
const Backend = @import("../backend.zig").Backend;

pub const BlockHeader = Executor.system_contracts.BeforeBlockContext;
pub const FinalizeBlockContext = Executor.system_contracts.FinalizeBlockContext;
pub const ParentBlobGas = transaction.ExcessBlobGasInput;
pub const BalDifferentialReport = bal_differential.Report;
pub const BalDifferentialStatus = bal_differential.Status;
pub const ParallelFallback = bal_differential.ParallelFallback;
const Env = vm.Env;
const BlockHashSource = vm.BlockHashSource;
const TxReceiptView = vm.TxReceiptView;
const Log = vm.Log;
const TxStatus = vm.TxStatus;

pub const ParallelStrategy = differential_executor.Strategy;
pub const ParallelResources = differential_executor.Resources;

pub const TransactionInput = struct {
    tx: transaction.Transaction,
    encoded: []const u8,

    /// Construct an ingress value when a trusted adapter has already decoded
    /// `encoded` into `tx`. This does not prove that both representations
    /// describe the same transaction; prefer the raw-byte `produce` API when
    /// the bytes are not already inside a trusted boundary.
    pub fn initAssumeDecoded(tx: transaction.Transaction, encoded: []const u8) TransactionInput {
        return .{ .tx = tx, .encoded = encoded };
    }
};

pub const ExecutionCapture = block_capture.Execution;
pub const ObservationTarget = block_capture.ObservationTarget;

/// Consensus root claims, grouped structurally by provenance so every
/// comparison visibly pairs one execution-derived root with one independent
/// claim. `payload_header` roots are carried directly by execution-payload or
/// header fields; `reconstructed_header` roots only exist after independently
/// reconstructing or reading the current execution header.
pub const RootChecks = struct {
    payload_header: struct {
        state: [32]u8,
        receipts: [32]u8,
    },
    reconstructed_header: struct {
        transactions: ?[32]u8 = null,
        withdrawals: ?[32]u8 = null,
    } = .{},
};

/// Header scalar/commitment claims compared against execution-derived outputs.
pub const HeaderClaims = struct {
    gas_used: ?u64 = null,
    block_gas_used: ?u64 = null,
    block_state_gas_used: ?u64 = null,
    logs_bloom: ?[256]u8 = null,
    blob_gas_used: ?u64 = null,
    excess_blob_gas: ?u256 = null,
    requests_hash: ?[32]u8 = null,
    block_access_list_hash: ?[32]u8 = null,
};

/// Claimed block hash plus the payload-only material needed to reconstruct it.
/// All roots, bloom, blob gas, requests, and BAL commitments come from
/// execution-derived `Result` fields rather than payload copies.
pub const HeaderHashClaim = struct {
    block_hash: [32]u8,
    parent_hash: [32]u8,
    parent_beacon_block_root: ?[32]u8 = null,
    extra_data: []const u8,
};

/// Canonical parent-header facts needed to validate child header rules.
pub const ParentHeaderContext = struct {
    hash: [32]u8,
    number: u64,
    timestamp: u64,
    gas_limit: u64,
    gas_used: u64,
    base_fee_per_gas: u256,
    blob_gas_used: u64 = 0,
    excess_blob_gas: u64 = 0,

    fn blobGasInput(self: ParentHeaderContext) ParentBlobGas {
        return .{
            .parent_excess_blob_gas = self.excess_blob_gas,
            .parent_blob_gas_used = self.blob_gas_used,
            .parent_base_fee_per_gas = self.base_fee_per_gas,
        };
    }
};

fn BlockInputType(comptime Transactions: type) type {
    return struct {
        env: Env = .{},
        block_hash_source: ?BlockHashSource = null,
        block_header: ?BlockHeader = null,
        state_backend: Backend,
        /// Caller-owned prepared-artifact service; not part of the VM resource bound.
        prepared_code_backend: ?prepared_code.Backend = null,
        /// Optional caller-owned service for the validated BAL-derived resource
        /// plan. Failure falls back to authoritative lazy reads and has no
        /// consensus meaning.
        execution_resource_preparer: ?execution_resources.Preparer = null,
        transactions: Transactions,
        withdrawals: []const Withdrawal = &.{},
        parent_header: ?ParentHeaderContext = null,
        parent_blob_gas: ?ParentBlobGas = null,
        block_access_list: ?[]const u8 = null,
        root_checks: RootChecks,
        header_claims: HeaderClaims = .{},
        header_hash_claim: ?HeaderHashClaim = null,
        capture: ?ExecutionCapture = null,
        /// Optional diagnostic lane. It never supplies canonical block state.
        bal_differential: ?*BalDifferentialReport = null,
        /// Synchronously prove every BAL-declared account/storage path is readable.
        /// This is independent from resource preparation and never changes
        /// transaction warm/cold gas semantics.
        precheck_block_access_list_state: bool = false,
    };
}

/// Checked validation input. Transactions are canonical raw envelopes decoded
/// once inside `apply`, then the same bytes feed the transaction trie.
pub const BlockInput = BlockInputType([]const []const u8);

/// Trusted-adapter validation input. Every decoded transaction must match its
/// encoded envelope; `applyAssumeDecoded` deliberately does not prove this.
pub const AssumeDecodedBlockInput = BlockInputType([]const TransactionInput);

/// Internal to `eth/`: shared by the differential block executor.
pub fn assumeDecodedBlockInput(
    input: BlockInput,
    state_backend: Backend,
    transactions: []const TransactionInput,
) AssumeDecodedBlockInput {
    return .{
        .env = input.env,
        .block_hash_source = input.block_hash_source,
        .block_header = input.block_header,
        .state_backend = state_backend,
        .prepared_code_backend = input.prepared_code_backend,
        .execution_resource_preparer = input.execution_resource_preparer,
        .transactions = transactions,
        .withdrawals = input.withdrawals,
        .parent_header = input.parent_header,
        .parent_blob_gas = input.parent_blob_gas,
        .block_access_list = input.block_access_list,
        .root_checks = input.root_checks,
        .header_claims = input.header_claims,
        .header_hash_claim = input.header_hash_claim,
        .capture = input.capture,
        .bal_differential = input.bal_differential,
        .precheck_block_access_list_state = input.precheck_block_access_list_state,
    };
}

/// Internal to `eth/`: shared by the differential block executor.
pub fn resetBalReport(input: AssumeDecodedBlockInput) void {
    if (input.bal_differential) |report| report.reset();
}

/// Everything validation judges a completed execution against. Production
/// never constructs this type; that impossibility replaces the old fold-mode
/// asserts.
pub const Claims = struct {
    root_checks: RootChecks,
    header: HeaderClaims = .{},
    header_hash: ?HeaderHashClaim = null,
};

/// Internal to `eth/`: shared by the differential block executor.
pub fn validationClaims(input: AssumeDecodedBlockInput) Claims {
    return .{
        .root_checks = input.root_checks,
        .header = input.header_claims,
        .header_hash = input.header_hash_claim,
    };
}

fn ProduceInputType(comptime Transactions: type) type {
    return struct {
        env: Env = .{},
        block_hash_source: ?BlockHashSource = null,
        block_header: ?BlockHeader = null,
        state_backend: Backend,
        /// Caller-owned prepared-artifact service; not part of the VM resource bound.
        prepared_code_backend: ?prepared_code.Backend = null,
        transactions: Transactions,
        withdrawals: []const Withdrawal = &.{},
        parent_header: ?ParentHeaderContext = null,
        parent_blob_gas: ?ParentBlobGas = null,
        capture: ?ExecutionCapture = null,
    };
}

/// Checked claim-free block-building input. Transactions are canonical raw
/// envelopes; `produce` decodes each once and uses that value for execution
/// while retaining the same bytes for the transaction trie.
pub const ProduceInput = ProduceInputType([]const []const u8);

/// Trusted-adapter block-building input. The caller must maintain the invariant
/// that every decoded transaction matches its encoded envelope.
pub const AssumeDecodedProduceInput = ProduceInputType([]const TransactionInput);

pub const Status = enum {
    valid,
    invalid_witness,
    invalid_block_body,
    header_surface_mismatch,
    invalid_requests,
    system_contract_failed,
    transaction_rejected,
    block_gas_exceeded,
    blob_gas_limit_exceeded,
    parent_header_mismatch,
    parent_hash_mismatch,
    block_number_mismatch,
    timestamp_mismatch,
    gas_limit_mismatch,
    base_fee_mismatch,
    invalid_block_access_list,
    block_access_list_too_large,
    state_root_mismatch,
    transactions_root_mismatch,
    receipts_root_mismatch,
    withdrawals_root_mismatch,
    gas_used_mismatch,
    block_gas_used_mismatch,
    block_state_gas_used_mismatch,
    logs_bloom_mismatch,
    blob_gas_used_mismatch,
    excess_blob_gas_mismatch,
    requests_hash_mismatch,
    block_access_list_mismatch,
    block_access_list_hash_mismatch,
    block_hash_mismatch,
};

pub const Result = struct {
    status: Status,
    tx_index: ?usize = null,
    gas_used: u64 = 0,
    block_gas_used: u64 = 0,
    block_state_gas_used: u64 = 0,
    state_root: [32]u8 = trie.empty_root_hash,
    transactions_root: [32]u8 = trie.empty_root_hash,
    receipts_root: [32]u8 = trie.empty_root_hash,
    withdrawals_root: [32]u8 = trie.empty_root_hash,
    logs_bloom: [256]u8 = empty_logs_bloom,
    blob_gas_used: u64 = 0,
    excess_blob_gas: ?u256 = null,
    requests_hash: [32]u8 = empty_requests_hash,
    block_access_list_hash: [32]u8 = eth_bal.empty_hash,
    block_hash: [32]u8 = [_]u8{0} ** 32,
};

/// Execution-derived block fields available before complete header material is
/// supplied. In particular this deliberately has no block hash.
pub const DerivedBlockOutput = struct {
    gas_used: u64,
    block_gas_used: u64,
    block_state_gas_used: u64,
    state_root: [32]u8,
    transactions_root: [32]u8,
    receipts_root: [32]u8,
    withdrawals_root: [32]u8,
    logs_bloom: [256]u8,
    blob_gas_used: u64,
    excess_blob_gas: ?u256,
    requests_hash: [32]u8,
    block_access_list_hash: [32]u8,

    fn fromResult(result: Result) DerivedBlockOutput {
        std.debug.assert(result.status == .valid);
        return .{
            .gas_used = result.gas_used,
            .block_gas_used = result.block_gas_used,
            .block_state_gas_used = result.block_state_gas_used,
            .state_root = result.state_root,
            .transactions_root = result.transactions_root,
            .receipts_root = result.receipts_root,
            .withdrawals_root = result.withdrawals_root,
            .logs_bloom = result.logs_bloom,
            .blob_gas_used = result.blob_gas_used,
            .excess_blob_gas = result.excess_blob_gas,
            .requests_hash = result.requests_hash,
            .block_access_list_hash = result.block_access_list_hash,
        };
    }
};

/// Successful builder artifact. `encoded_block_access_list` is the exact
/// canonical RLP byte string transported in the Amsterdam execution payload.
pub const ProducedBlock = struct {
    output: DerivedBlockOutput,
    encoded_block_access_list: []u8,

    pub fn deinit(self: *ProducedBlock, allocator: std.mem.Allocator) void {
        allocator.free(self.encoded_block_access_list);
        self.* = undefined;
    }
};

/// A rejected candidate carries no BAL bytes, making it impossible to confuse
/// failure with a successfully produced empty BAL (`0xc0`).
pub const ProduceOutcome = union(enum) {
    produced: ProducedBlock,
    rejected: Result,

    pub fn deinit(self: *ProduceOutcome, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .produced => |*produced| produced.deinit(allocator),
            .rejected => {},
        }
        self.* = undefined;
    }
};

pub const empty_logs_bloom = eth_receipt.empty_logs_bloom;
pub const empty_requests_hash = eip7685.empty_requests_hash;
pub const requestsHash = eip7685.requestsHash;

/// Internal to `eth/`: shared by the differential block executor.
pub fn lifecycleExecutionContext(env: Env) execution.ExecutionContext {
    return env.executionContext(.{ .origin = address.addr(0) });
}

/// Exact Ethereum block-STF namespace for one named fork.
///
/// Header rules use `revision`; execution semantics come from the complete
/// resolved spec compiled into the default engine. Custom chains or non-default
/// compile options supply their own engine through `Bind`.
pub fn Exact(comptime revision: Revision) type {
    return Bind(revision, vm.Vm(eth_spec.specAt(revision)));
}

/// Bind a named header lineage to an already-compiled execution engine.
///
/// Compile options never thread through this layer; they are closed inside
/// `ExactVm` and only read back as `compile_options`.
pub fn Bind(comptime revision: Revision, comptime ExactVm: type) type {
    // Header shape is revision-owned while execution reads the spec, so the two
    // must agree or a block would record no access list yet still owe the
    // header an access-list hash. Catch that when the engine is bound.
    if (ExactVm.specification.block.block_access_list != revision.isImpl(.amsterdam)) {
        @compileError("engine spec block_access_list disagrees with the " ++
            @tagName(revision) ++ " header lineage");
    }
    const BlockInputAlias = BlockInput;
    const AssumeDecodedBlockInputAlias = AssumeDecodedBlockInput;
    const ProduceInputAlias = ProduceInput;
    const AssumeDecodedProduceInputAlias = AssumeDecodedProduceInput;
    const block_access_list_enabled = ExactVm.specification.block.block_access_list;
    const bal_production_enabled = block_access_list_enabled and
        ExactVm.BlockState.supports_block_production;
    const bal_differential_enabled = block_access_list_enabled and
        ExactVm.BlockState.supports_external_observation_capture;
    const Producer = struct {
        fn produce(allocator: std.mem.Allocator, input: ProduceInputAlias) !ProduceOutcome {
            try requireCaptureSupport(ExactVm.BlockState, ExactVm.compile_options, input.capture);
            return produceExact(revision, ExactVm, allocator, input);
        }

        fn produceAssumeDecoded(
            allocator: std.mem.Allocator,
            input: AssumeDecodedProduceInputAlias,
        ) !ProduceOutcome {
            try requireCaptureSupport(ExactVm.BlockState, ExactVm.compile_options, input.capture);
            return produceAssumeDecodedExact(revision, ExactVm, allocator, input);
        }
    };

    return struct {
        pub const fork = revision;
        pub const specification = ExactVm.specification;
        pub const compile_options = ExactVm.compile_options;
        pub const Vm = ExactVm;
        pub const BlockInput = BlockInputAlias;
        pub const AssumeDecodedBlockInput = AssumeDecodedBlockInputAlias;
        pub const ProduceInput = ProduceInputAlias;
        pub const AssumeDecodedProduceInput = AssumeDecodedProduceInputAlias;
        /// Dense state is already bound to the accepted claim and therefore
        /// cannot run the tracked-state differential lane.
        pub const BalExecutor = if (bal_differential_enabled)
            differential_executor.Executor(revision, ExactVm)
        else
            struct {};
        /// Current production returns a canonical BAL artifact, so both the
        /// Ethereum spec and the selected state model must support that path.
        pub const produce = if (bal_production_enabled)
            Producer.produce
        else
            struct {};
        pub const produceAssumeDecoded = if (bal_production_enabled)
            Producer.produceAssumeDecoded
        else
            struct {};

        pub fn apply(allocator: std.mem.Allocator, input: BlockInputAlias) !Result {
            try requireCaptureSupport(ExactVm.BlockState, compile_options, input.capture);
            try requireDifferentialSupport(ExactVm.BlockState, input.bal_differential);
            return applyExact(revision, ExactVm, allocator, input);
        }

        pub fn applyAssumeDecoded(
            allocator: std.mem.Allocator,
            input: AssumeDecodedBlockInputAlias,
        ) !Result {
            try requireCaptureSupport(ExactVm.BlockState, compile_options, input.capture);
            try requireDifferentialSupport(ExactVm.BlockState, input.bal_differential);
            return applyAssumeDecodedExact(revision, ExactVm, allocator, input);
        }
    };
}

fn requireStepCaptureSupport(
    comptime options: vm.CompileOptions,
    capture: ?ExecutionCapture,
) !void {
    if (!options.step_capture and capture != null and capture.?.steps != null)
        return error.StepCaptureUnavailable;
}

fn requireCaptureSupport(
    comptime BlockState: type,
    comptime options: vm.CompileOptions,
    capture: ?ExecutionCapture,
) !void {
    try requireStepCaptureSupport(options, capture);
    if (!BlockState.supports_external_observation_capture and
        capture != null and capture.?.observations != null)
    {
        return error.ObservationCaptureUnavailable;
    }
}

fn requireDifferentialSupport(
    comptime BlockState: type,
    differential: ?*BalDifferentialReport,
) !void {
    if (!BlockState.supports_external_observation_capture and differential != null)
        return error.BalDifferentialUnavailable;
}

test "slim exact STF rejects unavailable step capture" {
    const Sink = struct {
        fn consume(_: *anyopaque, _: trace.TraceSpan) !void {}
    };

    var sink: u8 = 0;
    var tape = trace.TraceTape.initGrowable(std.testing.allocator);
    defer tape.deinit();
    const capture = ExecutionCapture{ .steps = .{
        .tape = &tape,
        .target = trace.TraceSpanTarget.init(&sink, Sink.consume),
    } };

    try std.testing.expectError(
        error.StepCaptureUnavailable,
        requireStepCaptureSupport(.{}, capture),
    );
    try requireStepCaptureSupport(.{ .step_capture = true }, capture);
    try requireStepCaptureSupport(.{}, null);
}

/// Decode raw transaction envelopes once, then validate one block transition
/// against payload/header claims. Ownership of `input.state_backend` transfers
/// to this call and is released on every path, including decode failure.
fn applyExact(
    comptime revision: Revision,
    comptime Engine: type,
    allocator: std.mem.Allocator,
    input: BlockInput,
) !Result {
    var state_backend = input.state_backend;

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const transactions = decodeRawTransactions(arena.allocator(), input.transactions) catch |err| {
        state_backend.deinit();
        return err;
    };

    // Ownership transfers here; `applyAssumeDecoded` releases the backend on
    // both success and error paths.
    return applyAssumeDecodedExact(
        revision,
        Engine,
        allocator,
        assumeDecodedBlockInput(input, state_backend, transactions),
    );
}

/// Validate values decoded by a trusted adapter. The caller must maintain the
/// encoded/decoded transaction invariant. Ownership of `input.state_backend`
/// transfers to this call and is released on every path.
fn applyAssumeDecodedExact(
    comptime revision: Revision,
    comptime Engine: type,
    allocator: std.mem.Allocator,
    input: AssumeDecodedBlockInput,
) !Result {
    resetBalReport(input);
    const result = (if (comptime Engine.specification.block.block_access_list and
        Engine.BlockState.supports_external_observation_capture)
    blk: {
        if (input.bal_differential) |report| {
            var observer = differential_executor.Observer(revision, Engine).init(
                allocator,
                input.env,
                lifecycleExecutionContext(input.env),
                input.prepared_code_backend,
                input.block_hash_source,
                report,
                null,
            );
            defer observer.deinit();
            break :blk applyExecution(
                revision,
                Engine,
                allocator,
                input,
                validationClaims(input),
                &observer,
            );
        }
        const observer = {};
        break :blk applyExecution(
            revision,
            Engine,
            allocator,
            input,
            validationClaims(input),
            observer,
        );
    } else blk: {
        if (comptime Engine.specification.block.block_access_list) {
            std.debug.assert(input.bal_differential == null);
        }
        const observer = {};
        break :blk applyExecution(
            revision,
            Engine,
            allocator,
            input,
            validationClaims(input),
            observer,
        );
    }) catch |err| switch (Executor.errors.normalize(err)) {
        error.StateReaderStrategyFailure => Result{ .status = .block_access_list_mismatch },
        else => return err,
    };
    return result;
}

/// Decode raw transaction envelopes once, then build one Amsterdam block.
/// A rejected candidate never owns BAL bytes. Ownership of
/// `input.state_backend` transfers to this call, including decode failures.
fn produceExact(
    comptime revision: Revision,
    comptime Engine: type,
    allocator: std.mem.Allocator,
    input: ProduceInput,
) !ProduceOutcome {
    var state_backend = input.state_backend;

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    const transactions = decodeRawTransactions(scratch, input.transactions) catch |err| {
        state_backend.deinit();
        return err;
    };

    // Ownership transfers here; `produceAssumeDecoded` releases the backend.
    return produceAssumeDecodedExact(revision, Engine, allocator, .{
        .env = input.env,
        .block_hash_source = input.block_hash_source,
        .block_header = input.block_header,
        .state_backend = state_backend,
        .prepared_code_backend = input.prepared_code_backend,
        .transactions = transactions,
        .withdrawals = input.withdrawals,
        .parent_header = input.parent_header,
        .parent_blob_gas = input.parent_blob_gas,
        .capture = input.capture,
    });
}

/// Build one Amsterdam block from transaction values decoded by a trusted
/// adapter. This skips the encoded/decoded consistency check; callers should
/// use `produce` for untrusted raw envelopes. Ownership of
/// `input.state_backend` transfers to this call.
fn produceAssumeDecodedExact(
    comptime revision: Revision,
    comptime Engine: type,
    allocator: std.mem.Allocator,
    input: AssumeDecodedProduceInput,
) !ProduceOutcome {
    comptime {
        std.debug.assert(Engine.specification.block.block_access_list);
        std.debug.assert(Engine.BlockState.supports_block_production);
    }

    const observer = {};
    return produceExecution(revision, Engine, allocator, .{
        .env = input.env,
        .block_hash_source = input.block_hash_source,
        .block_header = input.block_header,
        .state_backend = input.state_backend,
        .prepared_code_backend = input.prepared_code_backend,
        .transactions = input.transactions,
        .withdrawals = input.withdrawals,
        .parent_header = input.parent_header,
        .parent_blob_gas = input.parent_blob_gas,
        .capture = input.capture,
    }, observer);
}

/// Block-execution accumulation state: lives from before transaction 0 until
/// block finalization consumes it into commitments.
const BlockAccumulator = struct {
    allocator: std.mem.Allocator,
    encoded_receipts: std.ArrayList([]const u8) = .empty,
    deposit_request_data: std.ArrayList(u8) = .empty,
    logs_bloom: [256]u8 = empty_logs_bloom,
    blob_gas_used: u64 = 0,
    blob_gas_limit: u64,

    fn deinit(self: *BlockAccumulator) void {
        for (self.encoded_receipts.items) |encoded_receipt| self.allocator.free(encoded_receipt);
        self.encoded_receipts.deinit(self.allocator);
        self.deposit_request_data.deinit(self.allocator);
        self.* = undefined;
    }
};

/// Terminal mid-fold Result carrying the block progress at the stop point.
fn foldedResult(status: Status, tx_index: usize, progress: vm.BlockResult, requests_hash: [32]u8) Result {
    return .{
        .status = status,
        .tx_index = tx_index,
        .gas_used = progress.gas_used,
        .block_gas_used = progress.block_gas.total,
        .block_state_gas_used = progress.block_gas.state,
        .requests_hash = requests_hash,
    };
}

/// Adapter required by BlockExecution's observation capability. Consensus BAL
/// recording and optional external diagnostics remain separate authorities.
fn StateObservationSink(comptime BlockState: type) type {
    return struct {
        consensus_bal: ?*tracked_state_projector.BlockBuilder,
        external_target: ?ObservationTarget,
        block_access_index: eth_bal.BlockAccessIndex = 0,

        pub fn observe(
            self: *@This(),
            observation: anytype,
        ) !void {
            const observations = observation.observations();
            if (self.consensus_bal) |builder| {
                try builder.append(observations, self.block_access_index);
            }
            if (self.external_target) |target| {
                try BlockState.consumeObservationTarget(
                    target,
                    self.block_access_index,
                    observations,
                );
            }
        }
    };
}

/// Loop-invariant borrows for the per-transaction fold. Everything here is
/// pinned in `executeBlock`'s frame and outlives every transaction.
fn PayloadFold(comptime revision: Revision, comptime Engine: type) type {
    return struct {
        allocator: std.mem.Allocator,
        env: Env,
        block: *Engine.BlockExecution,
        executor: *Engine.Executor,
        collector: *StateObservationSink(Engine.BlockState),
        step_capture: *block_capture.StepScope,
        observe_state: bool,

        /// One payload transaction in invariant order: step-trace begin, blob
        /// budget, execution, diagnostics, accumulation, after-transaction
        /// system calls, step-trace finish. Returns the terminal Result when
        /// the block must stop at this transaction, null to continue.
        /// Inline: this is the fold's hot loop body; an outlined call plus
        /// context copy costs measurable guest steps per transaction.
        inline fn executePayloadTransaction(
            self: *const @This(),
            entry: TransactionInput,
            tx_index: usize,
            accumulated: *BlockAccumulator,
            requests_hash: [32]u8,
            observer: anytype,
        ) !?Result {
            const allocator = self.allocator;
            var step_span = try self.step_capture.beginTransaction();
            defer if (step_span) |*span| span.abort();

            self.collector.block_access_index =
                try eth_bal.transactionIndex(try block_admission.transactionCount(tx_index));
            const tx_blob_gas_used = try transactionBlobGasUsed(revision, Engine, entry.tx);
            const next_blob_gas_used = std.math.add(u64, accumulated.blob_gas_used, tx_blob_gas_used) catch return error.BlobGasOverflow;
            if (next_blob_gas_used > accumulated.blob_gas_limit) {
                const progress = self.block.progress();
                if (comptime @TypeOf(observer) != void) {
                    try observer.rejected(.{
                        .kind = .blob_gas,
                        .transaction = entry.tx,
                        .tx_index = tx_index,
                        .progress_before = progress,
                        .blob_gas_used_before = accumulated.blob_gas_used,
                    });
                }
                var result = foldedResult(.blob_gas_limit_exceeded, tx_index, progress, requests_hash);
                result.blob_gas_used = accumulated.blob_gas_used;
                return result;
            }
            const progress_before = self.block.progress();
            const tx_result = transactPayload(
                Engine,
                self.block,
                self.env,
                entry.tx,
                if (self.step_capture.active())
                    .{ .steps = self.step_capture.contextPtr() }
                else if (self.observe_state)
                    .observations
                else
                    .normal,
                self.collector,
            ) catch |err| switch (err) {
                error.InvalidWitness => return Result{ .status = .invalid_witness, .tx_index = tx_index },
                error.BlockGasExceeded => {
                    const progress = self.block.progress();
                    if (comptime @TypeOf(observer) != void) {
                        try observer.rejected(.{
                            .kind = .block_gas,
                            .transaction = entry.tx,
                            .tx_index = tx_index,
                            .progress_before = progress_before,
                            .blob_gas_used_before = accumulated.blob_gas_used,
                        });
                    }
                    return foldedResult(.block_gas_exceeded, tx_index, progress, requests_hash);
                },
                else => return err,
            };
            const included = switch (tx_result) {
                .included => |value| value,
                .rejected => {
                    const progress = self.block.progress();
                    if (comptime @TypeOf(observer) != void) {
                        try observer.rejected(.{
                            .kind = .transaction,
                            .transaction = entry.tx,
                            .tx_index = tx_index,
                            .progress_before = progress_before,
                            .blob_gas_used_before = accumulated.blob_gas_used,
                        });
                    }
                    return foldedResult(.transaction_rejected, tx_index, progress, requests_hash);
                },
            };
            const receipt = included.receipt;
            const progress_after = self.block.progress();
            if (comptime @TypeOf(observer) != void) {
                try observer.included(.{
                    .transaction = entry.tx,
                    .tx_index = tx_index,
                    .progress_before = progress_before,
                    .progress_after = progress_after,
                    .result = &included.result,
                    .logs = receipt.logs,
                    .blob_gas_used_after = next_blob_gas_used,
                });
            }
            eth_receipt.mergeLogsBloom(&accumulated.logs_bloom, eth_receipt.logsBloom(receipt.logs));
            if (revision.isImpl(.prague)) {
                eip6110.appendRequestDataFromLogs(allocator, &accumulated.deposit_request_data, receipt.logs) catch |err| switch (err) {
                    error.InvalidRequest => return foldedResult(.invalid_requests, tx_index, self.block.progress(), requests_hash),
                    else => return err,
                };
            }
            accumulated.blob_gas_used = next_blob_gas_used;
            const encoded_receipt = try eth_receipt.encodeView(allocator, entry.tx.kind, receipt);
            accumulated.encoded_receipts.append(allocator, encoded_receipt) catch |err| {
                allocator.free(encoded_receipt);
                return err;
            };
            const after_context: Executor.system_contracts.AfterTransactionContext = .{
                .number = self.env.number,
                .timestamp = self.env.timestamp,
                .transaction_index = progress_after.tx_count - 1,
                .status = receipt.status,
                .gas_used = receipt.gas_used,
                .cumulative_gas_used = progress_after.gas_used,
                .cumulative_block_gas = progress_after.block_gas.total,
                .cumulative_state_gas = progress_after.block_gas.state,
            };
            const after_result = if (self.step_capture.active())
                Executor.system_contracts.applyAfterTransactionCaptured(
                    self.executor,
                    lifecycleExecutionContext(self.env),
                    after_context,
                    self.step_capture.contextPtr(),
                    self.collector,
                )
            else if (self.observe_state)
                Executor.system_contracts.applyAfterTransactionObserved(
                    self.executor,
                    lifecycleExecutionContext(self.env),
                    after_context,
                    self.collector,
                )
            else
                Executor.system_contracts.applyAfterTransaction(
                    self.executor,
                    lifecycleExecutionContext(self.env),
                    after_context,
                );
            after_result catch |err| switch (err) {
                error.InvalidWitness => return Result{ .status = .invalid_witness, .tx_index = tx_index },
                error.SystemCallFailed => return Result{ .status = .system_contract_failed, .tx_index = tx_index },
                else => return err,
            };

            if (step_span) |*span| try span.finish();
            return null;
        }
    };
}

/// Private owner of one admitted backend and its unresolved execution result.
/// It never escapes BlockSTF: callers execute, compare or produce, then commit
/// while the Executor remains pinned in this stack frame.
fn BlockRun(comptime Engine: type) type {
    return struct {
        const Self = @This();

        allocator: std.mem.Allocator,
        state_backend: Backend,
        executor: ?Engine.Executor = null,
        encoded_block_access_list: ?[]u8 = null,
        block_access_list_mismatch: bool = false,
        candidate_ready: bool = false,
        committed: bool = false,

        fn init(
            allocator: std.mem.Allocator,
            state_backend: Backend,
        ) Self {
            return .{
                .allocator = allocator,
                .state_backend = state_backend,
            };
        }

        fn deinit(self: *Self) void {
            if (self.encoded_block_access_list) |encoded| self.allocator.free(encoded);
            if (self.executor) |*executor| executor.deinit();
            self.state_backend.deinit();
            self.* = undefined;
        }

        fn commit(self: *Self) !void {
            std.debug.assert(self.candidate_ready);
            std.debug.assert(!self.committed);
            const executor = &self.executor.?;
            try Engine.BlockState.commit(&self.state_backend, executor.acceptedView());
            self.committed = true;
        }

        fn takeEncodedBlockAccessList(self: *Self) []u8 {
            std.debug.assert(self.candidate_ready);
            std.debug.assert(self.committed);
            const encoded = self.encoded_block_access_list orelse unreachable;
            self.encoded_block_access_list = null;
            return encoded;
        }
    };
}

/// Execute, compare, and commit one validation input while the unresolved
/// candidate remains private to this stack frame. Internal to `eth/`: public
/// only for the differential block executor.
pub fn applyExecution(
    comptime revision: Revision,
    comptime Engine: type,
    allocator: std.mem.Allocator,
    input: anytype,
    claims: Claims,
    observer: anytype,
) !Result {
    var run = BlockRun(Engine).init(allocator, input.state_backend);
    defer run.deinit();

    if (!block_rules.blockBodyValid(
        revision,
        Engine.specification.block.block_access_list,
        input,
        claims,
    )) return .{ .status = .invalid_block_body };

    var result = try executeBlock(revision, Engine, allocator, input, &run, observer);
    if (result.status != .valid) return result;

    var block_hash_mismatch = false;
    if (claims.header_hash) |claim| {
        result.block_hash = block_rules.reconstructHeaderHash(
            revision,
            allocator,
            input,
            result,
            claim,
        ) catch |err| switch (err) {
            error.ExtraDataTooLong,
            error.HeaderSurfaceMismatch,
            error.InvalidHeaderReconstruction,
            => return .{ .status = .header_surface_mismatch },
            else => return err,
        };
        block_hash_mismatch = !std.mem.eql(u8, &result.block_hash, &claim.block_hash);
    }
    result.status = block_rules.compareBlock(
        result,
        claims,
        run.block_access_list_mismatch,
        block_hash_mismatch,
    );
    if (result.status == .valid) try run.commit();
    return result;
}

fn produceExecution(
    comptime revision: Revision,
    comptime Engine: type,
    allocator: std.mem.Allocator,
    input: anytype,
    observer: anytype,
) !ProduceOutcome {
    var run = BlockRun(Engine).init(allocator, input.state_backend);
    defer run.deinit();

    if (!block_rules.blockBodyValid(
        revision,
        Engine.specification.block.block_access_list,
        input,
        null,
    )) return .{ .rejected = .{ .status = .invalid_block_body } };

    const result = try executeBlock(revision, Engine, allocator, input, &run, observer);
    if (result.status != .valid) return .{ .rejected = result };

    try run.commit();
    return .{ .produced = .{
        .output = DerivedBlockOutput.fromResult(result),
        .encoded_block_access_list = run.takeEncodedBlockAccessList(),
    } };
}

/// Shared authoritative serial transition for validation and block production.
/// It derives an unresolved candidate but neither judges claims nor commits it.
fn executeBlock(
    comptime revision: Revision,
    comptime Engine: type,
    allocator: std.mem.Allocator,
    input: anytype,
    run: *BlockRun(Engine),
    observer: anytype,
) !Result {
    // One spec fact gates the header field, observation recording, claim
    // verification, and the candidate lane.
    const block_access_list_enabled = Engine.specification.block.block_access_list;
    const block_access_list = if (comptime @hasField(@TypeOf(input), "block_access_list"))
        input.block_access_list
    else
        null;
    const validates_block_access_list = @hasField(@TypeOf(input), "block_access_list");
    const resource_preparer = if (comptime @hasField(@TypeOf(input), "execution_resource_preparer"))
        input.execution_resource_preparer
    else
        null;
    const precheck_claim_state = if (comptime @hasField(@TypeOf(input), "precheck_block_access_list_state"))
        input.precheck_block_access_list_state
    else
        false;
    if (block_rules.parentHeaderStatus(revision, input)) |status| return .{ .status = status };
    if (!block_rules.blockContextValid(revision, input)) return .{ .status = .header_surface_mismatch };

    var computed_requests_hash = empty_requests_hash;
    var computed_block_access_list_hash = eth_bal.empty_hash;
    var block_access_list_mismatch = false;
    const block_access_transaction_count = try block_admission.transactionCount(input.transactions.len);

    var bal_claim = block_admission.Claim.decode(
        allocator,
        block_access_list,
        block_access_transaction_count,
        input.env.gas_limit,
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.BlockAccessListTooLarge => return .{ .status = .block_access_list_too_large },
        error.InvalidBlockAccessList => return .{ .status = .invalid_block_access_list },
    };
    defer bal_claim.deinit(allocator);
    try bal_claim.prepareResources(allocator, resource_preparer);

    if (comptime @TypeOf(observer) != void) {
        if (bal_claim.accounts()) |claimed_accounts| {
            observer.claimDecoded(claimed_accounts, run.state_backend.reader());
        }
    }

    var observed_block_access_list: ?eth_bal.Decoded = null;
    defer if (observed_block_access_list) |*decoded| decoded.deinit(allocator);
    var observed_block_access_list_encoded: ?[]u8 = null;
    defer if (observed_block_access_list_encoded) |encoded| allocator.free(encoded);

    const executor_state = Engine.BlockState.admit(allocator, .{
        .backend = &run.state_backend,
        .validated_claim = bal_claim.accounts(),
        .precheck_claim_state = precheck_claim_state,
    }) catch |err| switch (err) {
        error.InvalidBlockAccessList => return .{ .status = .invalid_block_access_list },
        error.InvalidWitness => return .{ .status = .invalid_witness },
        else => return err,
    };
    run.executor = Engine.Executor.init(allocator, .{
        .state = executor_state,
        .services = .{
            .prepared_code_backend = input.prepared_code_backend,
            .block_hash_source = input.block_hash_source,
        },
    });
    const executor = &run.executor.?;
    if (bal_claim.counts) |counts| {
        // Capacity is advisory; it must not change block validity on allocation failure.
        executor.reserveAcceptedAccessHint(.{
            .accounts = counts.accounts,
            .storage_keys = counts.storage_read_keys + counts.storage_write_keys,
        }) catch {};
    }

    var consensus_bal = tracked_state_projector.BlockBuilder.init(allocator);
    defer consensus_bal.deinit();
    var observation_sink = StateObservationSink(Engine.BlockState){
        .consensus_bal = if (block_access_list_enabled) &consensus_bal else null,
        .external_target = if (input.capture) |capture| capture.observations else null,
    };
    const observe_state = block_access_list_enabled or observation_sink.external_target != null;
    var step_capture = block_capture.StepScope.init(allocator, input.capture);
    defer step_capture.deinit();
    try step_capture.beginBlock();

    var block = try Engine.BlockExecution.init(
        executor,
        input.env,
    );
    defer block.discardIfUnfinished();

    if (input.block_header) |header| {
        observation_sink.block_access_index = 0;
        const context: Executor.system_contracts.BeforeBlockContext = .{
            .number = input.env.number,
            .timestamp = input.env.timestamp,
            .parent_hash = header.parent_hash,
            .parent_beacon_block_root = header.parent_beacon_block_root,
        };
        const before_result = if (observe_state)
            Executor.system_contracts.applyBeforeBlockObserved(
                executor,
                lifecycleExecutionContext(input.env),
                context,
                &observation_sink,
            )
        else
            Executor.system_contracts.applyBeforeBlock(
                executor,
                lifecycleExecutionContext(input.env),
                context,
            );
        before_result catch |err| switch (err) {
            error.InvalidWitness => return .{ .status = .invalid_witness },
            error.SystemCallFailed => return .{ .status = .system_contract_failed },
            else => return err,
        };
    }
    if (comptime @TypeOf(observer) != void) observer.beforeBlock(input.block_header);

    var accumulated = BlockAccumulator{
        .allocator = allocator,
        .blob_gas_limit = try blockBlobGasLimit(revision, Engine, input.env.blob_params),
    };
    defer accumulated.deinit();

    const fold = PayloadFold(revision, Engine){
        .allocator = allocator,
        .env = input.env,
        .block = &block,
        .executor = executor,
        .collector = &observation_sink,
        .step_capture = &step_capture,
        .observe_state = observe_state,
    };
    for (input.transactions, 0..) |entry, tx_index| {
        if (try fold.executePayloadTransaction(
            entry,
            tx_index,
            &accumulated,
            computed_requests_hash,
            observer,
        )) |terminal| return terminal;
    }
    if (comptime @TypeOf(observer) != void) try observer.finish();

    const effective_parent_blob_gas = if (revision.isImpl(.cancun))
        if (input.parent_header) |parent_header| parent_header.blobGasInput() else input.parent_blob_gas
    else
        input.parent_blob_gas;

    const excess_blob_gas = blk: {
        if (effective_parent_blob_gas) |parent_blob_gas| {
            if (input.env.blob_params) |params| {
                const schedule = effectiveBlobSchedule(Engine, params) orelse return error.BlobGasOverflow;
                break :blk schedule.calcExcessBlobGasForSchedule(parent_blob_gas) orelse return error.BlobGasOverflow;
            } else {
                break :blk calcProtocolExcessBlobGas(Engine, parent_blob_gas) orelse return error.BlobGasOverflow;
            }
        } else {
            break :blk null;
        }
    };

    observation_sink.block_access_index =
        try eth_bal.postExecutionSystemIndex(block_access_transaction_count);
    const withdrawals_result = if (observe_state)
        applyWithdrawals(
            executor,
            lifecycleExecutionContext(input.env),
            input.withdrawals,
            &observation_sink,
        )
    else
        applyWithdrawals(
            executor,
            lifecycleExecutionContext(input.env),
            input.withdrawals,
            {},
        );
    withdrawals_result catch |err| {
        return switch (Executor.errors.normalize(err)) {
            error.InvalidWitness => .{ .status = .invalid_witness },
            else => |normalized| normalized,
        };
    };

    const derived_requests_result = if (observe_state)
        deriveRequests(
            allocator,
            executor,
            input.env,
            block.progress(),
            accumulated.deposit_request_data.items,
            &observation_sink,
        )
    else
        deriveRequests(
            allocator,
            executor,
            input.env,
            block.progress(),
            accumulated.deposit_request_data.items,
            {},
        );
    const derived_requests = derived_requests_result catch |err| {
        return switch (Executor.errors.normalize(err)) {
            error.InvalidWitness => .{ .status = .invalid_witness },
            error.SystemCallFailed => .{ .status = .system_contract_failed },
            else => |normalized| normalized,
        };
    };
    defer freeRequests(allocator, derived_requests);

    computed_requests_hash = requestsHash(allocator, derived_requests) catch |err| switch (err) {
        error.InvalidRequest => return .{ .status = .invalid_requests },
        else => return err,
    };

    try step_capture.finishBlock();
    if (block_access_list_enabled) {
        const claim_verified_without_artifact = if (comptime validates_block_access_list and
            @TypeOf(observer) == void)
        blk: {
            const expected = bal_claim.accounts() orelse break :blk false;
            if (!try consensus_bal.matchesClaim(expected)) break :blk false;
            computed_block_access_list_hash = crypto.keccak256(block_access_list.?);
            break :blk true;
        } else false;

        if (claim_verified_without_artifact) {
            // The admitted canonical claim is the observed BAL; validation
            // needs its commitment but owns no produced artifact.
        } else {
            observed_block_access_list = consensus_bal.finish() catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return err,
            };
            // BlockBuilder emits canonical structure; only its consensus item budget remains.
            block_admission.validateCounts(eth_bal.count(observed_block_access_list.?.accounts), input.env.gas_limit) catch |err| switch (err) {
                error.BlockAccessListGasLimitExceeded => return .{ .status = .block_access_list_too_large },
                else => return err,
            };

            var needs_encoded_block_access_list = !validates_block_access_list or
                @TypeOf(observer) != void;
            if (block_access_list) |encoded_claim| {
                if (!eth_bal.eql(bal_claim.accounts().?, observed_block_access_list.?.accounts)) {
                    block_access_list_mismatch = true;
                    needs_encoded_block_access_list = true;
                    if (comptime @TypeOf(observer) != void) {
                        observer.blockAccessListMismatch(
                            bal_claim.accounts().?,
                            observed_block_access_list.?.accounts,
                        );
                    }
                } else if (!needs_encoded_block_access_list) {
                    computed_block_access_list_hash = crypto.keccak256(encoded_claim);
                }
            } else {
                needs_encoded_block_access_list = true;
            }
            if (needs_encoded_block_access_list) {
                observed_block_access_list_encoded = try eth_bal.encodeAlloc(
                    allocator,
                    observed_block_access_list.?.accounts,
                );
                computed_block_access_list_hash = crypto.keccak256(observed_block_access_list_encoded.?);
            }
        }
    }
    if (comptime @TypeOf(observer) != void) observer.finishCandidate(input.withdrawals);

    const block_result = block.finish();
    const accepted_state = executor.acceptedView();

    const result = Result{
        .status = .valid,
        .gas_used = block_result.gas_used,
        .block_gas_used = block_result.block_gas.total,
        .block_state_gas_used = block_result.block_gas.state,
        .state_root = Engine.BlockState.stateRoot(
            allocator,
            &run.state_backend,
            accepted_state,
        ) catch |err| switch (err) {
            error.InvalidWitness => return .{ .status = .invalid_witness },
            else => return err,
        },
        .transactions_root = try transactionRoot(allocator, input.transactions),
        .receipts_root = try trie.receiptRoot(allocator, accumulated.encoded_receipts.items),
        .withdrawals_root = try trie.withdrawalsRoot(allocator, input.withdrawals),
        .logs_bloom = accumulated.logs_bloom,
        .blob_gas_used = accumulated.blob_gas_used,
        .excess_blob_gas = excess_blob_gas,
        .requests_hash = computed_requests_hash,
        .block_access_list_hash = computed_block_access_list_hash,
    };

    if (comptime @TypeOf(observer) != void) {
        observer.compareBlock(.{
            .gas_used = result.gas_used,
            .block_gas_used = result.block_gas_used,
            .block_state_gas_used = result.block_state_gas_used,
            .blob_gas_used = result.blob_gas_used,
            .receipts_root = result.receipts_root,
            .logs_bloom = result.logs_bloom,
            .requests_hash = result.requests_hash,
            .encoded_receipts = accumulated.encoded_receipts.items,
            .requests = derived_requests,
            .encoded_block_access_list = observed_block_access_list_encoded orelse &.{},
            .block_access_list_matched = !block_access_list_mismatch,
            .transaction_count = input.transactions.len,
        });
    }

    run.block_access_list_mismatch = block_access_list_mismatch;
    if (comptime !validates_block_access_list) {
        run.encoded_block_access_list = observed_block_access_list_encoded;
        observed_block_access_list_encoded = null;
    }
    run.candidate_ready = true;
    return result;
}

/// Keep a spec-owned before-transaction batch in the same rollback
/// domain as the payload transaction. Ethereum currently emits no such calls,
/// but the family STF preserves the hook's atomic contract for future forks.
const PayloadCapture = union(enum) {
    normal,
    observations,
    steps: *Executor.CaptureContext,
};

fn transactPayload(
    comptime Engine: type,
    block: *Engine.BlockExecution,
    env: Env,
    tx_value: Engine.Transaction,
    capture: PayloadCapture,
    observer: anytype,
) !Engine.BlockExecution.Outcome {
    const progress = block.progress();
    const PayloadPrelude = struct {
        env: Env,
        transaction_index: u64,

        pub fn run(
            self: *@This(),
            prelude: Engine.BlockExecution.PreludeContext,
        ) Engine.BlockExecution.PreludeContext.Error!void {
            try Executor.system_contracts.applyBeforeTransactionPrelude(
                prelude,
                lifecycleExecutionContext(self.env),
                .{
                    .number = self.env.number,
                    .timestamp = self.env.timestamp,
                    .transaction_index = self.transaction_index,
                },
            );
        }
    };
    var prelude = PayloadPrelude{
        .env = env,
        .transaction_index = progress.tx_count,
    };
    return switch (capture) {
        .normal => block.transactWithPrelude(
            tx_value,
            Engine.BlockExecution.Prelude.init(&prelude),
        ),
        .observations => block.observe(observer).transactWithPrelude(
            tx_value,
            Engine.BlockExecution.Prelude.init(&prelude),
        ),
        .steps => |context| block.capture(context, observer).transactWithPrelude(
            tx_value,
            Engine.BlockExecution.Prelude.init(&prelude),
        ),
    };
}

fn transactionRoot(allocator: std.mem.Allocator, transactions: []const TransactionInput) ![32]u8 {
    var encoded: std.ArrayList([]const u8) = .empty;
    defer encoded.deinit(allocator);
    try encoded.ensureTotalCapacity(allocator, transactions.len);
    for (transactions) |entry| encoded.appendAssumeCapacity(entry.encoded);
    return try trie.transactionRoot(allocator, encoded.items);
}

/// Internal to `eth/`: shared by the differential block executor.
pub fn decodeRawTransactions(
    allocator: std.mem.Allocator,
    raw_transactions: []const []const u8,
) ![]const TransactionInput {
    const transactions = try allocator.alloc(TransactionInput, raw_transactions.len);
    for (transactions, raw_transactions) |*decoded, encoded| {
        decoded.* = TransactionInput.initAssumeDecoded(
            try transaction.raw.decodeRaw(allocator, encoded),
            encoded,
        );
    }
    return transactions;
}

const withdrawal_gwei_in_wei: u256 = 1_000_000_000;

/// Internal to `eth/`: shared with the BAL candidate lane. `observer` selects
/// the instrumentation at comptime: a state-observation collector, or `{}`
/// for unobserved execution.
pub fn applyWithdrawals(
    executor: anytype,
    execution_context: execution.ExecutionContext,
    withdrawals: []const Withdrawal,
    observer: anytype,
) !void {
    if (withdrawals.len == 0) return;
    const observed = comptime @TypeOf(observer) != void;
    const scope = if (comptime observed) executor.observe(observer) else executor;
    try scope.beginStateTransition(execution_context);
    errdefer executor.discardStateTransition();
    for (withdrawals) |withdrawal| {
        if (comptime observed) try executor.observeAccountAccess(withdrawal.address);
        const amount_wei = std.math.mul(u256, withdrawal.amount, withdrawal_gwei_in_wei) catch
            return error.WithdrawalBalanceOverflow;
        executor.addBalance(withdrawal.address, amount_wei) catch |err| switch (err) {
            error.BalanceOverflow => return error.WithdrawalBalanceOverflow,
            else => return err,
        };
    }
    try scope.commitTransaction();
}

/// Internal to `eth/`: shared with the BAL candidate lane. `observer` selects
/// the instrumentation at comptime: a state-observation collector, or `{}`
/// for unobserved execution.
pub fn deriveRequests(
    allocator: std.mem.Allocator,
    executor: anytype,
    env: Env,
    progress: vm.BlockResult,
    deposit_request_data: []const u8,
    observer: anytype,
) ![]const []const u8 {
    var requests: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (requests.items) |request| allocator.free(request);
        requests.deinit(allocator);
    }

    if (deposit_request_data.len != 0) {
        const deposit_request = try eip7685.requestBytes(allocator, eip6110.request_type, deposit_request_data);
        var deposit_request_owned = true;
        errdefer if (deposit_request_owned) allocator.free(deposit_request);
        try requests.append(allocator, deposit_request);
        deposit_request_owned = false;
    }

    const finalize_context: FinalizeBlockContext = .{
        .number = env.number,
        .timestamp = env.timestamp,
        .transaction_count = progress.tx_count,
        .gas_used = progress.gas_used,
        .block_gas = progress.block_gas.total,
        .state_gas = progress.block_gas.state,
    };
    const block_end_requests = if (comptime @TypeOf(observer) != void)
        try Executor.system_contracts.applyFinalizeBlockObserved(
            executor,
            lifecycleExecutionContext(env),
            allocator,
            finalize_context,
            observer,
        )
    else
        try Executor.system_contracts.applyFinalizeBlock(
            executor,
            lifecycleExecutionContext(env),
            allocator,
            finalize_context,
        );
    var moved_block_end_requests = false;
    errdefer if (!moved_block_end_requests) freeRequests(allocator, block_end_requests);
    try requests.appendSlice(allocator, block_end_requests);
    moved_block_end_requests = true;
    allocator.free(block_end_requests);

    return try requests.toOwnedSlice(allocator);
}

/// Internal to `eth/`: shared with the BAL candidate lane.
pub fn freeRequests(allocator: std.mem.Allocator, requests: []const []const u8) void {
    for (requests) |request| allocator.free(request);
    allocator.free(requests);
}

/// Internal to `eth/`: shared with the BAL candidate lane.
pub fn transactionBlobGasUsed(
    comptime revision: Revision,
    comptime Engine: type,
    tx: transaction.Transaction,
) !u64 {
    if (tx.kind != .blob or !revision.isImpl(.cancun)) return 0;
    const blob_count = std.math.cast(u64, tx.blob_hashes.len) orelse return error.BlobGasOverflow;
    const schedule = Engine.specification.transaction.blob_schedule orelse return error.BlobGasOverflow;
    const gas_per_blob = schedule.gas_per_blob;
    return std.math.mul(u64, blob_count, gas_per_blob) catch error.BlobGasOverflow;
}

/// Internal to `eth/`: shared with the BAL candidate lane.
pub fn blockBlobGasLimit(
    comptime revision: Revision,
    comptime Engine: type,
    blob_params: ?transaction.BlobParams,
) !u64 {
    if (!revision.isImpl(.cancun)) return 0;
    const schedule = effectiveBlobScheduleOptional(Engine, blob_params) orelse return error.BlobGasOverflow;
    return std.math.mul(u64, schedule.max, schedule.gas_per_blob) catch error.BlobGasOverflow;
}

fn calcProtocolExcessBlobGas(comptime Engine: type, input: ParentBlobGas) ?u256 {
    const schedule = Engine.specification.transaction.blob_schedule orelse return 0;
    return schedule.calcExcessBlobGasForSchedule(input);
}

fn effectiveBlobSchedule(comptime Engine: type, params: transaction.BlobParams) ?transaction.BlobSchedule {
    const schedule = Engine.specification.transaction.blob_schedule orelse return null;
    return schedule.withParams(params);
}

fn effectiveBlobScheduleOptional(comptime Engine: type, params: ?transaction.BlobParams) ?transaction.BlobSchedule {
    const schedule = Engine.specification.transaction.blob_schedule orelse return null;
    return if (params) |value| schedule.withParams(value) else schedule;
}

pub const ReceiptPayload = eth_receipt.Payload;
pub const encodeReceipt = eth_receipt.encode;
pub const logsBloom = eth_receipt.logsBloom;

test {
    _ = @import("./block_stf_test.zig");
    _ = block_rules;
    _ = eth_receipt;
    _ = differential_executor;
}
