//! Ethereum block state-transition orchestration above `Vm.BlockSession`.
//!
//! This module owns block-level lifecycle policy: system-contract hooks,
//! transaction folding, withdrawal credits, root/commitment assembly, and
//! compare-vs-claim mismatch taxonomy. Stateless guests are callers of this
//! layer; they do not own Ethereum block semantics.

const std = @import("std");

const Config = @import("../ExecutionConfig.zig");
const Executor = @import("../executor.zig");
const address = @import("../address.zig");
const crypto = @import("../crypto.zig");
const eth_bal = @import("bal.zig");
const BalRecorder = @import("bal_recorder.zig").Recorder;
const eth_header = @import("header.zig");
const eip6110 = @import("eip/6110.zig");
const eip7002 = @import("eip/7002.zig");
const eip7251 = @import("eip/7251.zig");
const eip7685 = @import("eip/7685.zig");
const eip8282 = @import("eip/8282.zig");
const eth_config = @import("config.zig");
const eth_system = @import("system.zig");
const eth_transaction = @import("transaction.zig");
const trie = @import("trie.zig");
const prepared_code = @import("../prepared_code.zig");
const Withdrawal = @import("Withdrawal.zig");
const rlp = @import("rlp");
const Revision = @import("revision.zig").Revision;
const state = @import("../state.zig");
const transaction = @import("../transaction.zig");
const trace = @import("../trace.zig");
const uint256 = @import("../uint256.zig");
const vm = @import("../vm.zig");

const definition = eth_config.define(.{});
const Vm = vm.Vm(Revision, definition, .{});
pub const Protocol = Vm.Protocol;
pub const BlockHeader = Executor.system_contracts.BeforeBlockContext;
pub const FinalizeBlockContext = Executor.system_contracts.FinalizeBlockContext;
pub const ParentBlobGas = transaction.ExcessBlobGasInput;
const EthBlob = transaction.For(Protocol).blob;
const Env = vm.Env;
const BlockHashSource = vm.BlockHashSource;
const TxReceiptView = vm.TxReceiptView;
const Log = vm.Log;
const TxStatus = vm.TxStatus;

pub const TransactionInput = struct {
    tx: Vm.Transaction,
    encoded: []const u8,
};

pub const RootSource = enum {
    execution_derived,
    payload_header_claim,
    reconstructed_header_claim,
};

pub fn SourcedRoot(comptime source: RootSource) type {
    return struct {
        pub const root_source = source;
        value: [32]u8,
    };
}

pub const PayloadHeaderRoot = SourcedRoot(.payload_header_claim);
pub const ReconstructedHeaderRoot = SourcedRoot(.reconstructed_header_claim);

pub fn payloadHeaderRoot(value: [32]u8) PayloadHeaderRoot {
    return .{ .value = value };
}

pub fn reconstructedHeaderRoot(value: [32]u8) ReconstructedHeaderRoot {
    return .{ .value = value };
}

/// Roots carried directly by execution-payload/header fields.
pub const PayloadHeaderRootClaims = struct {
    state: PayloadHeaderRoot,
    receipts: PayloadHeaderRoot,
};

/// Roots only available after reconstructing or otherwise independently reading
/// the current execution header. These are consensus claims.
pub const ReconstructedHeaderRootClaims = struct {
    transactions: ?ReconstructedHeaderRoot = null,
    withdrawals: ?ReconstructedHeaderRoot = null,
};

pub const RootChecks = struct {
    payload_header: PayloadHeaderRootClaims,
    reconstructed_header: ReconstructedHeaderRootClaims = .{},
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

/// Selects the gas value inserted into a reconstructed execution header.
/// `payload_claim` keeps block-hash validation usable while a fork's gas
/// derivation is incomplete, without presenting that scalar as STF-derived.
pub const HeaderGasUsed = union(enum) {
    execution_derived,
    payload_claim: u64,
};

/// Claimed block hash plus the payload-only material needed to reconstruct it.
/// All roots, bloom, blob gas, requests, and BAL commitments come from
/// execution-derived `Result` fields rather than payload copies.
pub const HeaderHashClaim = struct {
    block_hash: [32]u8,
    parent_hash: [32]u8,
    parent_beacon_block_root: ?[32]u8 = null,
    extra_data: []const u8,
    gas_used: HeaderGasUsed = .execution_derived,
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

pub const BlockInput = struct {
    revision: Revision = .latest,
    config: Config = .base,
    env: Env = .{},
    block_hash_source: ?BlockHashSource = null,
    block_header: ?BlockHeader = null,
    state_backend: state.Backend,
    /// Caller-owned prepared-artifact service; not part of the VM resource bound.
    prepared_code_backend: ?prepared_code.Backend = null,
    transactions: []const TransactionInput,
    withdrawals: []const Withdrawal = &.{},
    parent_header: ?ParentHeaderContext = null,
    parent_blob_gas: ?ParentBlobGas = null,
    block_access_list: ?[]const u8 = null,
    root_checks: RootChecks,
    header_claims: HeaderClaims = .{},
    header_hash_claim: ?HeaderHashClaim = null,
    trace_sink: ?*trace.Sink = null,
};

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

pub const empty_logs_bloom = [_]u8{0} ** 256;
pub const empty_requests_hash = eip7685.empty_requests_hash;
pub const requestsHash = eip7685.requestsHash;

const RootField = enum {
    state,
    transactions,
    receipts,
    withdrawals,
};

const ConsensusRootComparison = struct {
    field: RootField,
    status: Status,
    derived_source: RootSource = .execution_derived,
    claim_source: RootSource,
};

const consensus_root_comparisons = [_]ConsensusRootComparison{
    .{ .field = .state, .status = .state_root_mismatch, .claim_source = PayloadHeaderRoot.root_source },
    .{ .field = .transactions, .status = .transactions_root_mismatch, .claim_source = ReconstructedHeaderRoot.root_source },
    .{ .field = .receipts, .status = .receipts_root_mismatch, .claim_source = PayloadHeaderRoot.root_source },
    .{ .field = .withdrawals, .status = .withdrawals_root_mismatch, .claim_source = ReconstructedHeaderRoot.root_source },
};

comptime {
    for (consensus_root_comparisons) |comparison| {
        if (comparison.status == .valid) @compileError("consensus root comparison must map to a mismatch status");
        const has_execution_derived = comparison.derived_source == .execution_derived;
        const claim_is_execution_derived = comparison.claim_source == .execution_derived;
        if (has_execution_derived == claim_is_execution_derived) {
            @compileError("consensus root comparison must have exactly one execution-derived operand");
        }
    }
}

/// Execute one block transition. Ownership of `input.state_backend` transfers
/// to this call and is released on every return path.
pub fn apply(allocator: std.mem.Allocator, input: BlockInput) !Result {
    var state_backend = input.state_backend;
    defer state_backend.deinit();

    if (!blockBodyValid(input)) return .{ .status = .invalid_block_body };
    if (parentHeaderStatus(input)) |status| return .{ .status = status };
    if (!blockContextValid(input)) return .{ .status = .header_surface_mismatch };

    var computed_requests_hash = empty_requests_hash;
    var computed_block_access_list_hash = eth_bal.empty_hash;
    var block_access_list_mismatch = false;
    const record_block_access_list = input.block_access_list != null or
        input.header_claims.block_access_list_hash != null or
        input.revision.isImpl(.amsterdam);
    const block_access_transaction_count = try blockAccessTransactionCount(input.transactions.len);

    var claimed_block_access_list: ?eth_bal.Decoded = null;
    defer if (claimed_block_access_list) |*decoded| decoded.deinit(allocator);
    if (input.block_access_list) |encoded_claim| {
        var bal_budget = rlp.Budget.init(eth_bal.blockDecodeLimits(
            encoded_claim.len,
            block_access_transaction_count,
            input.env.gas_limit,
        ));
        claimed_block_access_list = eth_bal.decodeWithBudget(allocator, encoded_claim, &bal_budget) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.DecodeAllocationLimitExceeded,
            error.DecodeItemLimitExceeded,
            => return .{ .status = .block_access_list_too_large },
            else => return .{ .status = .invalid_block_access_list },
        };
        validateBlockAccessList(claimed_block_access_list.?.accounts, block_access_transaction_count, input.env.gas_limit) catch |err| switch (err) {
            error.BlockAccessListGasLimitExceeded => return .{ .status = .block_access_list_too_large },
            else => return .{ .status = .invalid_block_access_list },
        };
    }

    var observed_block_access_list: ?eth_bal.Decoded = null;
    defer if (observed_block_access_list) |*decoded| decoded.deinit(allocator);
    var observed_block_access_list_encoded: ?[]u8 = null;
    defer if (observed_block_access_list_encoded) |encoded| allocator.free(encoded);

    var evm = Vm.init(allocator, .{
        .revision = input.revision,
        .state_reader = state_backend.reader(),
        .prepared_code_backend = input.prepared_code_backend,
        .block_hash_source = input.block_hash_source,
        .env = input.env,
        .config = input.config,
    });
    defer evm.deinit();

    var recorder = BalRecorder.init(allocator);
    defer recorder.deinit();
    var recorder_sink = recorder.sink();
    var trace_fanout: TraceFanout = undefined;
    var payload_trace_sink: ?*trace.Sink = input.trace_sink;
    var fanout_sink: trace.Sink = undefined;
    if (record_block_access_list) {
        if (input.trace_sink) |caller_sink| {
            trace_fanout = .{ .first = &recorder_sink, .second = caller_sink };
            fanout_sink = trace_fanout.sink();
            payload_trace_sink = &fanout_sink;
        } else {
            payload_trace_sink = &recorder_sink;
        }
        recorder.setBlockAccessIndex(0);
        evm.executor.setTraceSink(&recorder_sink);
    }

    var block = try evm.beginBlock(input.env);
    if (input.block_header) |header| {
        block.beforeBlock(.{
            .parent_hash = header.parent_hash,
            .parent_beacon_block_root = header.parent_beacon_block_root,
        }) catch |err| switch (err) {
            error.InvalidWitness => return .{ .status = .invalid_witness },
            error.SystemCallFailed => return .{ .status = .system_contract_failed },
            else => return err,
        };
    }

    // Trace payload transactions only; block-start system contracts above seed
    // header state outside the payload transaction trace.
    evm.executor.setTraceSink(payload_trace_sink);

    var encoded_receipts: std.ArrayList([]const u8) = .empty;
    defer {
        for (encoded_receipts.items) |encoded_receipt| allocator.free(encoded_receipt);
        encoded_receipts.deinit(allocator);
    }
    var deposit_request_data: std.ArrayList(u8) = .empty;
    defer deposit_request_data.deinit(allocator);
    var block_logs_bloom = empty_logs_bloom;
    var blob_gas_used: u64 = 0;
    const blob_gas_limit = try blockBlobGasLimit(input.revision, input.env.blob_schedule);

    for (input.transactions, 0..) |entry, tx_index| {
        if (record_block_access_list) {
            recorder.setBlockAccessIndex(try eth_bal.transactionIndex(try blockAccessTransactionCount(tx_index)));
        }
        const tx_blob_gas_used = try transactionBlobGasUsed(input.revision, input.env.blob_schedule, entry.tx);
        const next_blob_gas_used = std.math.add(u64, blob_gas_used, tx_blob_gas_used) catch return error.BlobGasOverflow;
        if (next_blob_gas_used > blob_gas_limit) {
            return .{
                .status = .blob_gas_limit_exceeded,
                .tx_index = tx_index,
                .gas_used = block.gas_used,
                .block_gas_used = block.block_gas.total,
                .block_state_gas_used = block.block_gas.state,
                .blob_gas_used = blob_gas_used,
                .requests_hash = computed_requests_hash,
            };
        }
        const tx_result = block.transact(entry.tx) catch |err| switch (err) {
            error.InvalidWitness => return .{ .status = .invalid_witness, .tx_index = tx_index },
            error.BlockGasExceeded => return .{
                .status = .block_gas_exceeded,
                .tx_index = tx_index,
                .gas_used = block.gas_used,
                .block_gas_used = block.block_gas.total,
                .block_state_gas_used = block.block_gas.state,
                .requests_hash = computed_requests_hash,
            },
            else => return err,
        };
        const executed = switch (tx_result) {
            .executed => |executed| executed,
            .rejected => return .{
                .status = .transaction_rejected,
                .tx_index = tx_index,
                .gas_used = block.gas_used,
                .block_gas_used = block.block_gas.total,
                .block_state_gas_used = block.block_gas.state,
                .requests_hash = computed_requests_hash,
            },
        };
        const receipt = block.receipt(executed);
        mergeLogsBloom(&block_logs_bloom, logsBloom(receipt.logs));
        if (input.revision.isImpl(.prague)) {
            eip6110.appendRequestDataFromLogs(allocator, &deposit_request_data, receipt.logs) catch |err| switch (err) {
                error.InvalidRequest => return .{
                    .status = .invalid_requests,
                    .tx_index = tx_index,
                    .gas_used = block.gas_used,
                    .block_gas_used = block.block_gas.total,
                    .block_state_gas_used = block.block_gas.state,
                    .requests_hash = computed_requests_hash,
                },
                else => return err,
            };
        }
        blob_gas_used = next_blob_gas_used;
        const encoded_receipt = try encodeReceipt(allocator, entry.tx.kind, receipt);
        errdefer allocator.free(encoded_receipt);
        try encoded_receipts.append(allocator, encoded_receipt);
        block.afterTransaction() catch |err| switch (err) {
            error.InvalidWitness => return .{ .status = .invalid_witness, .tx_index = tx_index },
            error.SystemCallFailed => return .{ .status = .system_contract_failed, .tx_index = tx_index },
            else => return err,
        };
    }

    const effective_parent_blob_gas = if (input.revision.isImpl(.cancun))
        if (input.parent_header) |parent_header| parent_header.blobGasInput() else input.parent_blob_gas
    else
        input.parent_blob_gas;
    const excess_blob_gas = if (effective_parent_blob_gas) |parent_blob_gas|
        if (input.env.blob_schedule) |schedule|
            transaction.calcExcessBlobGasForSchedule(schedule, parent_blob_gas) orelse return error.BlobGasOverflow
        else
            EthBlob.calcExcessBlobGas(input.revision, parent_blob_gas) orelse return error.BlobGasOverflow
    else
        null;

    if (record_block_access_list) {
        recorder.setBlockAccessIndex(try eth_bal.postExecutionSystemIndex(block_access_transaction_count));
        evm.executor.setTraceSink(&recorder_sink);
        for (input.withdrawals) |withdrawal| {
            recorder.recordAccountAccess(withdrawal.address) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return err,
            };
        }
    }

    applyWithdrawals(&evm, input.withdrawals) catch |err| switch (err) {
        error.InvalidWitness => return .{ .status = .invalid_witness },
        else => return err,
    };

    // Keep payload transaction tracing scoped to payload transactions.
    evm.executor.setTraceSink(if (record_block_access_list) &recorder_sink else null);
    const derived_requests = deriveRequests(allocator, &block, deposit_request_data.items) catch |err| switch (err) {
        error.InvalidWitness => return .{ .status = .invalid_witness },
        error.SystemCallFailed => return .{ .status = .system_contract_failed },
        else => return err,
    };
    defer freeRequests(allocator, derived_requests);
    computed_requests_hash = requestsHash(allocator, derived_requests) catch |err| switch (err) {
        error.InvalidRequest => return .{ .status = .invalid_requests },
        else => return err,
    };

    if (record_block_access_list) {
        observed_block_access_list = recorder.toOwnedBlockAccessList(allocator) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return err,
        };
        validateBlockAccessList(observed_block_access_list.?.accounts, block_access_transaction_count, input.env.gas_limit) catch |err| switch (err) {
            error.BlockAccessListGasLimitExceeded => return .{ .status = .block_access_list_too_large },
            else => return err,
        };

        observed_block_access_list_encoded = try eth_bal.encodeAlloc(allocator, observed_block_access_list.?.accounts);
        computed_block_access_list_hash = crypto.keccak256(observed_block_access_list_encoded.?);
        if (input.block_access_list) |encoded_claim| {
            if (!std.mem.eql(u8, observed_block_access_list_encoded.?, encoded_claim)) block_access_list_mismatch = true;
        }
    }

    var changeset = try evm.changeset();
    defer changeset.deinit(allocator);

    var result = Result{
        .status = .valid,
        .gas_used = block.gas_used,
        .block_gas_used = block.block_gas.total,
        .block_state_gas_used = block.block_gas.state,
        .state_root = state_backend.stateRootAfterChangeset(allocator, &changeset) catch |err| switch (err) {
            error.InvalidWitness => return .{ .status = .invalid_witness },
            else => return err,
        },
        .transactions_root = try transactionRoot(allocator, input.transactions),
        .receipts_root = try trie.receiptRoot(allocator, encoded_receipts.items),
        .withdrawals_root = try trie.withdrawalsRoot(allocator, input.withdrawals),
        .logs_bloom = block_logs_bloom,
        .blob_gas_used = blob_gas_used,
        .excess_blob_gas = excess_blob_gas,
        .requests_hash = computed_requests_hash,
        .block_access_list_hash = computed_block_access_list_hash,
    };

    var block_hash_mismatch = false;
    if (input.header_hash_claim) |claim| {
        result.block_hash = reconstructHeaderHash(allocator, input, result, claim) catch |err| switch (err) {
            error.ExtraDataTooLong, error.HeaderSurfaceMismatch, error.InvalidHeaderReconstruction => return .{ .status = .header_surface_mismatch },
            else => return err,
        };
        block_hash_mismatch = !std.mem.eql(u8, &result.block_hash, &claim.block_hash);
    }

    applyConsensusRootComparisons(&result, input.root_checks);
    if (result.status == .valid and input.header_claims.gas_used != null and result.gas_used != input.header_claims.gas_used.?) result.status = .gas_used_mismatch;
    if (result.status == .valid and input.header_claims.block_gas_used != null and result.block_gas_used != input.header_claims.block_gas_used.?) result.status = .block_gas_used_mismatch;
    if (result.status == .valid and input.header_claims.block_state_gas_used != null and result.block_state_gas_used != input.header_claims.block_state_gas_used.?) result.status = .block_state_gas_used_mismatch;
    if (result.status == .valid) {
        if (input.header_claims.logs_bloom) |expected_bloom| {
            if (!std.mem.eql(u8, &result.logs_bloom, &expected_bloom)) result.status = .logs_bloom_mismatch;
        }
    }
    if (result.status == .valid and input.header_claims.blob_gas_used != null and result.blob_gas_used != input.header_claims.blob_gas_used.?) result.status = .blob_gas_used_mismatch;
    if (result.status == .valid) {
        if (input.header_claims.excess_blob_gas) |expected_excess_blob_gas| {
            if (result.excess_blob_gas == null or result.excess_blob_gas.? != expected_excess_blob_gas) result.status = .excess_blob_gas_mismatch;
        }
    }
    if (result.status == .valid) {
        if (input.header_claims.requests_hash) |expected_requests_hash| {
            if (!std.mem.eql(u8, &result.requests_hash, &expected_requests_hash)) result.status = .requests_hash_mismatch;
        }
    }
    if (result.status == .valid and block_access_list_mismatch) result.status = .block_access_list_mismatch;
    if (result.status == .valid) {
        if (input.header_claims.block_access_list_hash) |expected_block_access_list_hash| {
            if (!std.mem.eql(u8, &result.block_access_list_hash, &expected_block_access_list_hash)) result.status = .block_access_list_hash_mismatch;
        }
    }
    if (result.status == .valid and block_hash_mismatch) result.status = .block_hash_mismatch;
    if (result.status == .valid) {
        try state_backend.commit(&changeset);
    }
    return result;
}

fn blockBodyValid(input: BlockInput) bool {
    if (!input.revision.isImpl(.shanghai) and input.withdrawals.len != 0) return false;
    if (!input.revision.isImpl(.shanghai) and input.root_checks.reconstructed_header.withdrawals != null) return false;
    if (!input.revision.isImpl(.cancun)) {
        if (input.parent_blob_gas != null or
            input.header_claims.blob_gas_used != null or
            input.header_claims.excess_blob_gas != null)
        {
            return false;
        }
        if (input.block_header) |header| {
            if (header.parent_beacon_block_root != null) return false;
        }
        if (input.header_hash_claim) |claim| {
            if (claim.parent_beacon_block_root != null) return false;
        }
    }
    if (!input.revision.isImpl(.prague) and input.header_claims.requests_hash != null) return false;
    if (!input.revision.isImpl(.amsterdam) and
        (input.block_access_list != null or input.header_claims.block_access_list_hash != null))
    {
        return false;
    }
    return true;
}

fn reconstructHeaderHash(
    allocator: std.mem.Allocator,
    input: BlockInput,
    result: Result,
    claim: HeaderHashClaim,
) ![32]u8 {
    if (!input.revision.isImpl(.merge)) return error.InvalidHeaderReconstruction;
    if (input.block_header) |block_header| {
        if (block_header.number != input.env.number or block_header.timestamp != input.env.timestamp) {
            return error.InvalidHeaderReconstruction;
        }
        if (block_header.parent_hash) |parent_hash| {
            if (!std.mem.eql(u8, &parent_hash, &claim.parent_hash)) return error.InvalidHeaderReconstruction;
        }
        if (!optionalHashEqual(block_header.parent_beacon_block_root, claim.parent_beacon_block_root)) {
            return error.InvalidHeaderReconstruction;
        }
    }

    const gas_used = switch (claim.gas_used) {
        .execution_derived => result.block_gas_used,
        .payload_claim => |value| value,
    };
    const excess_blob_gas: ?u64 = if (input.revision.isImpl(.cancun))
        std.math.cast(u64, result.excess_blob_gas orelse return error.InvalidHeaderReconstruction) orelse
            return error.InvalidHeaderReconstruction
    else
        null;
    const header = eth_header.ExecutionHeader{
        .parent_hash = claim.parent_hash,
        .coinbase = input.env.coinbase,
        .state_root = result.state_root,
        .transactions_root = result.transactions_root,
        .receipts_root = result.receipts_root,
        .logs_bloom = result.logs_bloom,
        .number = input.env.number,
        .gas_limit = input.env.gas_limit,
        .gas_used = gas_used,
        .timestamp = input.env.timestamp,
        .extra_data = claim.extra_data,
        .prev_randao = uint256.toBytes32(input.env.prev_randao),
        .base_fee_per_gas = if (input.revision.isImpl(.london)) input.env.base_fee else null,
        .withdrawals_root = if (input.revision.isImpl(.shanghai)) result.withdrawals_root else null,
        .blob_gas_used = if (input.revision.isImpl(.cancun)) result.blob_gas_used else null,
        .excess_blob_gas = excess_blob_gas,
        .parent_beacon_block_root = if (input.revision.isImpl(.cancun)) claim.parent_beacon_block_root else null,
        .requests_hash = if (input.revision.isImpl(.prague)) result.requests_hash else null,
        .block_access_list_hash = if (input.revision.isImpl(.amsterdam)) result.block_access_list_hash else null,
        .slot_number = if (input.revision.isImpl(.amsterdam)) input.env.slot_number else null,
    };
    return try header.hash(allocator, input.revision);
}

fn optionalHashEqual(lhs: ?[32]u8, rhs: ?[32]u8) bool {
    if (lhs == null or rhs == null) return lhs == null and rhs == null;
    return std.mem.eql(u8, &lhs.?, &rhs.?);
}

fn applyConsensusRootComparisons(result: *Result, checks: RootChecks) void {
    inline for (consensus_root_comparisons) |comparison| {
        if (result.status != .valid) return;
        if (rootClaimValue(comparison, checks)) |expected| {
            const derived = derivedRootValue(comparison.field, result.*);
            if (!rootEqual(derived, expected)) result.status = comparison.status;
        }
    }
}

fn rootClaimValue(comptime comparison: ConsensusRootComparison, checks: RootChecks) ?[32]u8 {
    return switch (comparison.field) {
        .state => checks.payload_header.state.value,
        .transactions => if (checks.reconstructed_header.transactions) |claim| claim.value else null,
        .receipts => checks.payload_header.receipts.value,
        .withdrawals => if (checks.reconstructed_header.withdrawals) |claim| claim.value else null,
    };
}

fn derivedRootValue(field: RootField, result: Result) [32]u8 {
    return switch (field) {
        .state => result.state_root,
        .transactions => result.transactions_root,
        .receipts => result.receipts_root,
        .withdrawals => result.withdrawals_root,
    };
}

fn blockAccessTransactionCount(transaction_count: usize) !eth_bal.BlockAccessIndex {
    return std.math.cast(eth_bal.BlockAccessIndex, transaction_count) orelse error.BlockAccessIndexOverflow;
}

fn validateBlockAccessList(block_access_list: eth_bal.BlockAccessList, transaction_count: eth_bal.BlockAccessIndex, gas_limit: u64) eth_bal.ValidationError!void {
    try eth_bal.validate(block_access_list, .{ .transaction_count = transaction_count });
    if (gas_limit != 0) try eth_bal.validateGasLimit(block_access_list, gas_limit);
}

const TraceFanout = struct {
    first: *trace.Sink,
    second: *trace.Sink,

    fn sink(self: *TraceFanout) trace.Sink {
        return trace.Sink.init(self, traceEventsUnion(self.first.events, self.second.events), &.{
            .stepStart = stepStart,
            .stepEnd = stepEnd,
            .accountAccess = accountAccess,
            .stateRead = stateRead,
            .stateWrite = stateWrite,
            .checkpoint = checkpoint,
        });
    }

    fn stepStart(ptr: *anyopaque, event: trace.StepStart) void {
        const self: *TraceFanout = @ptrCast(@alignCast(ptr));
        self.first.stepStart(event);
        self.second.stepStart(event);
    }

    fn stepEnd(ptr: *anyopaque, event: trace.StepEnd) void {
        const self: *TraceFanout = @ptrCast(@alignCast(ptr));
        self.first.stepEnd(event);
        self.second.stepEnd(event);
    }

    fn accountAccess(ptr: *anyopaque, event: trace.AccountAccess) void {
        const self: *TraceFanout = @ptrCast(@alignCast(ptr));
        self.first.accountAccess(event);
        self.second.accountAccess(event);
    }

    fn stateRead(ptr: *anyopaque, event: trace.StateRead) void {
        const self: *TraceFanout = @ptrCast(@alignCast(ptr));
        self.first.stateRead(event);
        self.second.stateRead(event);
    }

    fn stateWrite(ptr: *anyopaque, event: trace.StateWrite) void {
        const self: *TraceFanout = @ptrCast(@alignCast(ptr));
        self.first.stateWrite(event);
        self.second.stateWrite(event);
    }

    fn checkpoint(ptr: *anyopaque, event: trace.Checkpoint) void {
        const self: *TraceFanout = @ptrCast(@alignCast(ptr));
        self.first.checkpoint(event);
        self.second.checkpoint(event);
    }
};

fn traceEventsUnion(lhs: trace.Events, rhs: trace.Events) trace.Events {
    return .{
        .step_start = lhs.step_start.unionWith(rhs.step_start),
        .step_end = lhs.step_end.unionWith(rhs.step_end),
        .account_access = lhs.account_access.unionWith(rhs.account_access),
        .state_read = lhs.state_read.unionWith(rhs.state_read),
        .state_write = lhs.state_write.unionWith(rhs.state_write),
        .checkpoint = lhs.checkpoint.unionWith(rhs.checkpoint),
    };
}

fn parentHeaderStatus(input: BlockInput) ?Status {
    if (!input.revision.isImpl(.merge) or input.env.number == 0) return null;

    const parent = input.parent_header orelse return .parent_header_mismatch;
    const current = input.block_header orelse return .parent_header_mismatch;
    const current_parent_hash = current.parent_hash orelse return .parent_hash_mismatch;
    if (!std.mem.eql(u8, &current_parent_hash, &parent.hash)) return .parent_hash_mismatch;
    if (current.number != input.env.number) return .block_number_mismatch;
    const expected_number = std.math.add(u64, parent.number, 1) catch return .block_number_mismatch;
    if (input.env.number != expected_number) return .block_number_mismatch;
    if (current.timestamp != input.env.timestamp) return .timestamp_mismatch;
    if (input.env.timestamp <= parent.timestamp) return .timestamp_mismatch;
    if (!gasLimitValid(input.env.gas_limit, parent.gas_limit)) return .gas_limit_mismatch;
    const expected_base_fee = expectedBaseFee(parent) orelse return .base_fee_mismatch;
    if (input.env.base_fee != expected_base_fee) return .base_fee_mismatch;
    return null;
}

const gas_limit_adjustment_factor: u64 = 1024;
const gas_limit_minimum: u64 = 5000;
const elasticity_multiplier: u64 = 2;
const base_fee_max_change_denominator: u256 = 8;

fn gasLimitValid(gas_limit: u64, parent_gas_limit: u64) bool {
    if (gas_limit < gas_limit_minimum) return false;
    const adjustment = parent_gas_limit / gas_limit_adjustment_factor;
    const upper: u128 = @as(u128, parent_gas_limit) + adjustment;
    const lower = parent_gas_limit - adjustment;
    return @as(u128, gas_limit) < upper and gas_limit > lower;
}

fn expectedBaseFee(parent: ParentHeaderContext) ?u256 {
    const target = parent.gas_limit / elasticity_multiplier;
    if (target == 0) return null;
    if (parent.gas_used == target) return parent.base_fee_per_gas;

    const gas_delta = if (parent.gas_used > target)
        parent.gas_used - target
    else
        target - parent.gas_used;
    const fee_delta_product = uint256.checkedMul(parent.base_fee_per_gas, @as(u256, gas_delta)) orelse return null;
    const target_fee_delta = @divFloor(fee_delta_product, @as(u256, target));
    var base_fee_delta = @divFloor(target_fee_delta, base_fee_max_change_denominator);

    if (parent.gas_used > target) {
        base_fee_delta = @max(base_fee_delta, 1);
        return uint256.checkedAdd(parent.base_fee_per_gas, base_fee_delta);
    }
    if (base_fee_delta > parent.base_fee_per_gas) return null;
    return parent.base_fee_per_gas - base_fee_delta;
}

fn blockContextValid(input: BlockInput) bool {
    if (input.block_header) |header| {
        if (header.number != input.env.number or header.timestamp != input.env.timestamp) return false;
    }
    if (input.env.number == 0) return true;

    if (input.revision.isImpl(.cancun)) {
        const header = input.block_header orelse return false;
        if (header.parent_beacon_block_root == null) return false;
    }
    if (input.revision.isImpl(.prague)) {
        const header = input.block_header orelse return false;
        if (header.parent_hash == null) return false;
    }
    return true;
}

fn transactionRoot(allocator: std.mem.Allocator, transactions: []const TransactionInput) ![32]u8 {
    var encoded: std.ArrayList([]const u8) = .empty;
    defer encoded.deinit(allocator);
    try encoded.ensureTotalCapacity(allocator, transactions.len);
    for (transactions) |entry| encoded.appendAssumeCapacity(entry.encoded);
    return try trie.transactionRoot(allocator, encoded.items);
}

const withdrawal_gwei_in_wei: u256 = 1_000_000_000;

fn applyWithdrawals(evm: *Vm, withdrawals: []const Withdrawal) !void {
    for (withdrawals) |withdrawal| {
        const amount_wei = std.math.mul(u256, withdrawal.amount, withdrawal_gwei_in_wei) catch return error.WithdrawalBalanceOverflow;
        evm.creditBalance(withdrawal.address, amount_wei) catch |err| switch (err) {
            error.BalanceOverflow => return error.WithdrawalBalanceOverflow,
            else => return err,
        };
    }
}

fn deriveRequests(allocator: std.mem.Allocator, block: *Vm.BlockSession, deposit_request_data: []const u8) ![]const []const u8 {
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

    const block_end_requests = try deriveFinalizeRequests(allocator, block);
    var moved_block_end_requests = false;
    errdefer if (!moved_block_end_requests) freeRequests(allocator, block_end_requests);
    try requests.appendSlice(allocator, block_end_requests);
    moved_block_end_requests = true;
    allocator.free(block_end_requests);

    return try requests.toOwnedSlice(allocator);
}

fn deriveFinalizeRequests(allocator: std.mem.Allocator, block: *Vm.BlockSession) ![]const []const u8 {
    return block.finalizeBlock(allocator);
}

fn freeRequests(allocator: std.mem.Allocator, requests: []const []const u8) void {
    for (requests) |request| allocator.free(request);
    allocator.free(requests);
}

fn transactionBlobGasUsed(revision: Revision, blob_schedule: ?transaction.BlobSchedule, tx: Vm.Transaction) !u64 {
    if (tx.kind != .blob or !revision.isImpl(.cancun)) return 0;
    const blob_count = std.math.cast(u64, tx.blob_hashes.len) orelse return error.BlobGasOverflow;
    const schedule = blob_schedule orelse eth_transaction.Transaction.blobSchedule(revision) orelse return error.BlobGasOverflow;
    const gas_per_blob = schedule.gas_per_blob;
    return std.math.mul(u64, blob_count, gas_per_blob) catch error.BlobGasOverflow;
}

fn blockBlobGasLimit(revision: Revision, blob_schedule: ?transaction.BlobSchedule) !u64 {
    if (!revision.isImpl(.cancun)) return 0;
    const schedule = blob_schedule orelse eth_transaction.Transaction.blobSchedule(revision) orelse return error.BlobGasOverflow;
    return std.math.mul(u64, schedule.max, schedule.gas_per_blob) catch error.BlobGasOverflow;
}

const TopicRlp = rlp.Mapped(u256, rlp.FixedBytes(32), struct {
    pub fn toWire(topic: u256) [32]u8 {
        return uint256.toBytes32(topic);
    }

    pub fn fromWire(encoded: [32]u8) u256 {
        return uint256.fromBytes32(&encoded);
    }
});

const LogRlp = rlp.Struct(Log, .{
    .topics = rlp.BoundedListOf(TopicRlp, 4),
});

const ReceiptPayload = struct {
    status: u8,
    cumulative_gas_used: u64,
    logs_bloom: [256]u8,
    logs: []const Log,

    pub const Rlp = rlp.Struct(@This(), .{
        .logs = rlp.ListOf(LogRlp),
    });
};

pub fn encodeReceipt(allocator: std.mem.Allocator, kind: @TypeOf(@as(Vm.Transaction, undefined).kind), receipt: TxReceiptView) ![]u8 {
    const payload: ReceiptPayload = .{
        .status = receiptStatus(receipt.status),
        .cumulative_gas_used = receipt.cumulative_gas_used,
        .logs_bloom = logsBloom(receipt.logs),
        .logs = receipt.logs,
    };
    const payload_len = try rlp.encodedLen(ReceiptPayload, &payload);
    const type_id = transactionType(kind);
    const envelope_len: usize = if (type_id == null) 0 else 1;
    const encoded_len = std.math.add(usize, envelope_len, payload_len) catch
        return error.EncodedLengthOverflow;
    const encoded = try allocator.alloc(u8, encoded_len);
    errdefer allocator.free(encoded);

    if (type_id) |id| encoded[0] = id;
    const written = try rlp.encode(ReceiptPayload, encoded[envelope_len..], &payload);
    std.debug.assert(written.len == payload_len);
    return encoded;
}

fn receiptStatus(status: TxStatus) u8 {
    return switch (status) {
        .success => 1,
        .revert, .invalid, .out_of_gas => 0,
    };
}

fn transactionType(kind: @TypeOf(@as(Vm.Transaction, undefined).kind)) ?u8 {
    return switch (kind) {
        .legacy => null,
        .access_list => 0x01,
        .dynamic_fee => 0x02,
        .blob => 0x03,
        .set_code => 0x04,
    };
}

fn logsBloom(logs: []const Log) [256]u8 {
    var bloom = [_]u8{0} ** 256;
    for (logs) |event_log| {
        addBloomEntry(&bloom, &event_log.address);
        for (event_log.topics) |topic| {
            const encoded_topic = uint256.toBytes32(topic);
            addBloomEntry(&bloom, &encoded_topic);
        }
    }
    return bloom;
}

fn mergeLogsBloom(target: *[256]u8, source: [256]u8) void {
    for (target, source) |*target_byte, source_byte| target_byte.* |= source_byte;
}

fn addBloomEntry(bloom: *[256]u8, entry: []const u8) void {
    const hash = crypto.keccak256(entry);
    inline for (.{ 0, 2, 4 }) |offset| {
        const bit_to_set: usize = ((@as(usize, hash[offset]) & 0x07) << 8) | @as(usize, hash[offset + 1]);
        const bit_index = 0x07ff - bit_to_set;
        bloom[bit_index / 8] |= @as(u8, 1) << @intCast(7 - (bit_index % 8));
    }
}

fn rootEqual(lhs: [32]u8, rhs: [32]u8) bool {
    return std.mem.eql(u8, &lhs, &rhs);
}

fn testRootChecks(header_state: [32]u8, local_transactions: [32]u8, header_receipts: [32]u8) RootChecks {
    return .{
        .payload_header = .{
            .state = payloadHeaderRoot(header_state),
            .receipts = payloadHeaderRoot(header_receipts),
        },
        .reconstructed_header = .{
            .transactions = reconstructedHeaderRoot(local_transactions),
        },
    };
}

fn testRootChecksWithWithdrawals(header_state: [32]u8, local_transactions: [32]u8, header_receipts: [32]u8, local_withdrawals: [32]u8) RootChecks {
    return .{
        .payload_header = .{
            .state = payloadHeaderRoot(header_state),
            .receipts = payloadHeaderRoot(header_receipts),
        },
        .reconstructed_header = .{
            .transactions = reconstructedHeaderRoot(local_transactions),
            .withdrawals = reconstructedHeaderRoot(local_withdrawals),
        },
    };
}

test "BlockSTF validates a single witnessed transaction" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const scratch = arena.allocator();

    const target = address.addr(0x1000);
    const code = [_]u8{
        0x60, 0x2a, // PUSH1 42
        0x60, 0x00, // PUSH1 0
        0x55, // SSTORE
        0x60, 0x99, // PUSH1 0x99
        0x60, 0x00, // PUSH1 0
        0x60, 0x00, // PUSH1 0
        0xa1, // LOG1
        0x00, // STOP
    };
    const code_hash = crypto.keccak256(&code);

    const account_key = trie.hashedAddressKey(target);
    const pre_account_value = try trie.accountValueFrom(scratch, .{
        .balance = 1_000_000,
        .code_hash = code_hash,
    });
    const state_node = try testLeafNode(scratch, &account_key, pre_account_value);
    const pre_state_root = crypto.keccak256(state_node);
    const nodes = [_][]const u8{state_node};
    const codes = [_]state.WitnessStateReader.Code{.{ .hash = code_hash, .bytes = &code }};

    const tx_input = [_]TransactionInput{.{
        .tx = .{
            .sender = target,
            .to = target,
            .gas_limit = 100_000,
        },
        .encoded = "tx0",
    }};

    const storage_key = trie.hashedStorageKey(0);
    const storage_value = try trie.storageValue(scratch, 42);
    const post_storage_pairs = [_]trie.Pair{.{ .key = &storage_key, .value = storage_value }};
    const post_storage_root = try trie.root(scratch, &post_storage_pairs);
    const post_account_value = try trie.accountValueFrom(scratch, .{
        .nonce = 1,
        .balance = 1_000_000,
        .storage_root = post_storage_root,
        .code_hash = code_hash,
    });
    const post_state_pairs = [_]trie.Pair{.{ .key = &account_key, .value = post_account_value }};
    const expected_state_root = try trie.root(scratch, &post_state_pairs);

    const first_result = try apply(scratch, .{
        .revision = .frontier,
        .env = .{ .gas_limit = 100_000 },
        .state_backend = try state.Backend.fromWitness(scratch, pre_state_root, &nodes, &codes),
        .transactions = &tx_input,
        .root_checks = testRootChecks(
            expected_state_root,
            try trie.transactionRoot(scratch, &.{tx_input[0].encoded}),
            [_]u8{0xff} ** 32,
        ),
    });
    try std.testing.expectEqual(Status.receipts_root_mismatch, first_result.status);

    const receipt_topics = [_]u256{0x99};
    const receipt_log = Log{
        .address = target,
        .topics = &receipt_topics,
        .data = &.{},
    };
    const encoded_receipt = try encodeReceipt(scratch, .legacy, .{
        .status = .success,
        .cumulative_gas_used = first_result.gas_used,
        .logs = &.{receipt_log},
    });
    const expected_receipts_root = try trie.receiptRoot(scratch, &.{encoded_receipt});
    const expected_logs_bloom = logsBloom(&.{receipt_log});
    try std.testing.expectEqualSlices(u8, &expected_receipts_root, &first_result.receipts_root);
    try std.testing.expectEqualSlices(u8, &expected_logs_bloom, &first_result.logs_bloom);

    const result = try apply(scratch, .{
        .revision = .frontier,
        .env = .{ .gas_limit = 100_000 },
        .state_backend = try state.Backend.fromWitness(scratch, pre_state_root, &nodes, &codes),
        .transactions = &tx_input,
        .root_checks = testRootChecks(
            expected_state_root,
            try trie.transactionRoot(scratch, &.{tx_input[0].encoded}),
            first_result.receipts_root,
        ),
        .header_claims = .{
            .gas_used = first_result.gas_used,
            .block_gas_used = first_result.block_gas_used,
            .logs_bloom = expected_logs_bloom,
        },
    });

    try std.testing.expectEqual(Status.valid, result.status);
    try std.testing.expect(result.gas_used > 0);
    try std.testing.expectEqualSlices(u8, &expected_state_root, &result.state_root);

    const gas_mismatch = try apply(scratch, .{
        .revision = .frontier,
        .env = .{ .gas_limit = 100_000 },
        .state_backend = try state.Backend.fromWitness(scratch, pre_state_root, &nodes, &codes),
        .transactions = &tx_input,
        .root_checks = testRootChecks(
            expected_state_root,
            try trie.transactionRoot(scratch, &.{tx_input[0].encoded}),
            first_result.receipts_root,
        ),
        .header_claims = .{ .gas_used = first_result.gas_used + 1 },
    });
    try std.testing.expectEqual(Status.gas_used_mismatch, gas_mismatch.status);

    const block_gas_mismatch = try apply(scratch, .{
        .revision = .frontier,
        .env = .{ .gas_limit = 100_000 },
        .state_backend = try state.Backend.fromWitness(scratch, pre_state_root, &nodes, &codes),
        .transactions = &tx_input,
        .root_checks = testRootChecks(
            expected_state_root,
            try trie.transactionRoot(scratch, &.{tx_input[0].encoded}),
            first_result.receipts_root,
        ),
        .header_claims = .{ .block_gas_used = first_result.block_gas_used + 1 },
    });
    try std.testing.expectEqual(Status.block_gas_used_mismatch, block_gas_mismatch.status);

    const logs_bloom_mismatch = try apply(scratch, .{
        .revision = .frontier,
        .env = .{ .gas_limit = 100_000 },
        .state_backend = try state.Backend.fromWitness(scratch, pre_state_root, &nodes, &codes),
        .transactions = &tx_input,
        .root_checks = testRootChecks(
            expected_state_root,
            try trie.transactionRoot(scratch, &.{tx_input[0].encoded}),
            first_result.receipts_root,
        ),
        .header_claims = .{ .logs_bloom = [_]u8{0xff} ** 256 },
    });
    try std.testing.expectEqual(Status.logs_bloom_mismatch, logs_bloom_mismatch.status);
}

test "BlockSTF stores PREVRANDAO as EVM word" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const scratch = arena.allocator();

    const sender = address.addr(0x1100);
    const sender_key = trie.hashedAddressKey(sender);
    const sender_account_value = try trie.accountValueFrom(scratch, .{ .balance = 1_000_000 });
    const state_node = try testLeafNode(scratch, &sender_key, sender_account_value);
    const pre_state_root = crypto.keccak256(state_node);
    const nodes = [_][]const u8{state_node};

    const init_code = [_]u8{
        0x44, // PREVRANDAO
        0x60, 0x00, // PUSH1 0
        0x55, // SSTORE
        0x00, // STOP
    };
    const tx_input = [_]TransactionInput{.{
        .tx = .{
            .kind = .legacy,
            .sender = sender,
            .nonce = 0,
            .gas_limit = 100_000,
            .to = null,
            .input = &init_code,
        },
        .encoded = "create-prevrandao",
    }};

    var randao_bytes = [_]u8{0} ** 32;
    randao_bytes[0] = 0x01;
    randao_bytes[31] = 0x02;
    const prev_randao = std.mem.readInt(u256, &randao_bytes, .big);
    const storage_key = trie.hashedStorageKey(0);
    const storage_value = try trie.storageValue(scratch, prev_randao);
    const storage_pairs = [_]trie.Pair{.{ .key = &storage_key, .value = storage_value }};
    const created_storage_root = try trie.root(scratch, &storage_pairs);

    const created = address.create(sender, 0);
    const created_key = trie.hashedAddressKey(created);
    const post_sender_account = try trie.accountValueFrom(scratch, .{
        .nonce = 1,
        .balance = 1_000_000,
    });
    const post_created_account = try trie.accountValueFrom(scratch, .{
        .nonce = 1,
        .storage_root = created_storage_root,
    });
    const post_state_pairs = [_]trie.Pair{
        .{ .key = &sender_key, .value = post_sender_account },
        .{ .key = &created_key, .value = post_created_account },
    };
    const expected_state_root = try trie.root(scratch, &post_state_pairs);

    const first_result = try apply(scratch, .{
        .revision = .merge,
        .env = .{ .gas_limit = 100_000, .prev_randao = prev_randao },
        .state_backend = try state.Backend.fromWitness(scratch, pre_state_root, &nodes, &.{}),
        .transactions = &tx_input,
        .root_checks = testRootChecks(
            expected_state_root,
            try trie.transactionRoot(scratch, &.{tx_input[0].encoded}),
            [_]u8{0xff} ** 32,
        ),
    });
    try std.testing.expectEqual(Status.receipts_root_mismatch, first_result.status);

    const result = try apply(scratch, .{
        .revision = .merge,
        .env = .{ .gas_limit = 100_000, .prev_randao = prev_randao },
        .state_backend = try state.Backend.fromWitness(scratch, pre_state_root, &nodes, &.{}),
        .transactions = &tx_input,
        .root_checks = testRootChecks(
            expected_state_root,
            try trie.transactionRoot(scratch, &.{tx_input[0].encoded}),
            first_result.receipts_root,
        ),
        .header_claims = .{ .gas_used = first_result.gas_used },
    });

    try std.testing.expectEqual(Status.valid, result.status);
    try std.testing.expectEqualSlices(u8, &expected_state_root, &result.state_root);
}

test "BlockSTF reports root mismatches and invalid witness" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const scratch = arena.allocator();

    const target = address.addr(0x2000);
    const account_key = trie.hashedAddressKey(target);
    const account_value = try trie.accountValueFrom(scratch, .{ .balance = 1_000_000 });
    const state_node = try testLeafNode(scratch, &account_key, account_value);
    const pre_state_root = crypto.keccak256(state_node);
    const nodes = [_][]const u8{state_node};
    const tx_input = [_]TransactionInput{.{
        .tx = .{ .sender = target, .to = target, .gas_limit = 21_000 },
        .encoded = "tx0",
    }};

    const mismatch = try apply(scratch, .{
        .revision = .frontier,
        .env = .{ .gas_limit = 21_000 },
        .state_backend = try state.Backend.fromWitness(scratch, pre_state_root, &nodes, &.{}),
        .transactions = &tx_input,
        .root_checks = testRootChecks(
            [_]u8{0xff} ** 32,
            try trie.transactionRoot(scratch, &.{tx_input[0].encoded}),
            [_]u8{0xff} ** 32,
        ),
    });
    try std.testing.expectEqual(Status.state_root_mismatch, mismatch.status);

    const invalid = try apply(scratch, .{
        .revision = .frontier,
        .env = .{ .gas_limit = 21_000 },
        .state_backend = try state.Backend.fromWitness(scratch, pre_state_root, &.{}, &.{}),
        .transactions = &tx_input,
        .root_checks = testRootChecks(
            pre_state_root,
            try trie.transactionRoot(scratch, &.{tx_input[0].encoded}),
            trie.empty_root_hash,
        ),
    });
    try std.testing.expectEqual(Status.invalid_witness, invalid.status);
    try std.testing.expectEqual(@as(?usize, 0), invalid.tx_index);
}

test "BlockSTF validates withdrawals root" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const scratch = arena.allocator();

    const withdrawals = [_]Withdrawal{
        .{
            .index = 1,
            .validator_index = 2,
            .address = address.addr(0x1000),
            .amount = 3,
        },
        .{
            .index = 4,
            .validator_index = 5,
            .address = address.addr(0x2000),
            .amount = 6,
        },
    };
    const expected_withdrawals_root = try trie.withdrawalsRoot(scratch, &withdrawals);
    const account0_key = trie.hashedAddressKey(withdrawals[0].address);
    const account0_value = try trie.accountValueFrom(scratch, .{ .balance = withdrawals[0].amount * withdrawal_gwei_in_wei });
    const account1_key = trie.hashedAddressKey(withdrawals[1].address);
    const account1_value = try trie.accountValueFrom(scratch, .{ .balance = withdrawals[1].amount * withdrawal_gwei_in_wei });
    const expected_state_pairs = [_]trie.Pair{
        .{ .key = &account0_key, .value = account0_value },
        .{ .key = &account1_key, .value = account1_value },
    };
    const expected_state_root = try trie.root(scratch, &expected_state_pairs);

    const result = try apply(scratch, .{
        .state_backend = try state.Backend.fromWitness(scratch, trie.empty_root_hash, &.{}, &.{}),
        .transactions = &.{},
        .withdrawals = &withdrawals,
        .root_checks = testRootChecksWithWithdrawals(
            expected_state_root,
            trie.empty_root_hash,
            trie.empty_root_hash,
            expected_withdrawals_root,
        ),
    });

    try std.testing.expectEqual(Status.valid, result.status);
    try std.testing.expectEqualSlices(u8, &expected_withdrawals_root, &result.withdrawals_root);

    const mismatch = try apply(scratch, .{
        .state_backend = try state.Backend.fromWitness(scratch, trie.empty_root_hash, &.{}, &.{}),
        .transactions = &.{},
        .withdrawals = &withdrawals,
        .root_checks = testRootChecksWithWithdrawals(
            expected_state_root,
            trie.empty_root_hash,
            trie.empty_root_hash,
            [_]u8{0xff} ** 32,
        ),
    });
    try std.testing.expectEqual(Status.withdrawals_root_mismatch, mismatch.status);
}

test "BlockSTF applies Cancun block-start system contract" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const scratch = arena.allocator();

    const beacon_address = eth_system.beacon_roots_address;
    var beacon_code_buf: [97]u8 = undefined;
    const beacon_code = try std.fmt.hexToBytes(
        &beacon_code_buf,
        "3373fffffffffffffffffffffffffffffffffffffffe14604d57602036146024575f5ffd5b5f35801560495762001fff810690815414603c575f5ffd5b62001fff01545f5260205ff35b5f5ffd5b62001fff42064281555f359062001fff015500",
    );
    const beacon_code_hash = crypto.keccak256(beacon_code);

    const account_key = trie.hashedAddressKey(beacon_address);
    const pre_account_value = try trie.accountValueFrom(scratch, .{ .code_hash = beacon_code_hash });
    const state_node = try testLeafNode(scratch, &account_key, pre_account_value);
    const pre_state_root = crypto.keccak256(state_node);
    const nodes = [_][]const u8{state_node};
    const codes = [_]state.WitnessStateReader.Code{.{ .hash = beacon_code_hash, .bytes = beacon_code }};

    var parent_beacon_root = [_]u8{0} ** 32;
    parent_beacon_root[31] = 0xbb;
    const timestamp: u64 = 12;
    const timestamp_key = trie.hashedStorageKey(timestamp);
    const root_key = trie.hashedStorageKey(8191 + timestamp);
    const timestamp_value = try trie.storageValue(scratch, timestamp);
    const root_value = try trie.storageValue(scratch, std.mem.readInt(u256, &parent_beacon_root, .big));
    const post_storage_pairs = [_]trie.Pair{
        .{ .key = &timestamp_key, .value = timestamp_value },
        .{ .key = &root_key, .value = root_value },
    };
    const post_storage_root = try trie.root(scratch, &post_storage_pairs);
    const post_account_value = try trie.accountValueFrom(scratch, .{
        .storage_root = post_storage_root,
        .code_hash = beacon_code_hash,
    });
    const post_state_pairs = [_]trie.Pair{.{ .key = &account_key, .value = post_account_value }};
    const expected_state_root = try trie.root(scratch, &post_state_pairs);
    const parent_hash = [_]u8{0x11} ** 32;

    const result = try apply(scratch, .{
        .revision = .cancun,
        .env = .{ .number = 1, .timestamp = timestamp, .gas_limit = 30_000_000 },
        .block_header = .{
            .number = 1,
            .timestamp = timestamp,
            .parent_hash = parent_hash,
            .parent_beacon_block_root = parent_beacon_root,
        },
        .state_backend = try state.Backend.fromWitness(scratch, pre_state_root, &nodes, &codes),
        .transactions = &.{},
        .parent_header = .{
            .hash = parent_hash,
            .number = 0,
            .timestamp = 0,
            .gas_limit = 30_000_000,
            .gas_used = 0,
            .base_fee_per_gas = 0,
        },
        .root_checks = testRootChecks(expected_state_root, trie.empty_root_hash, trie.empty_root_hash),
    });
    try std.testing.expectEqual(Status.valid, result.status);
    try std.testing.expectEqualSlices(u8, &expected_state_root, &result.state_root);
}

test "BlockSTF rejects missing or inconsistent parent context" {
    const missing = try apply(std.testing.allocator, .{
        .revision = .cancun,
        .env = .{ .number = 1, .timestamp = 2 },
        .state_backend = try state.Backend.fromWitness(std.testing.allocator, trie.empty_root_hash, &.{}, &.{}),
        .transactions = &.{},
        .root_checks = testRootChecks(trie.empty_root_hash, trie.empty_root_hash, trie.empty_root_hash),
    });
    try std.testing.expectEqual(Status.parent_header_mismatch, missing.status);

    const parent_hash = [_]u8{0x11} ** 32;
    const inconsistent = try apply(std.testing.allocator, .{
        .revision = .cancun,
        .env = .{ .number = 1, .timestamp = 2, .gas_limit = 30_000_000 },
        .block_header = .{
            .number = 1,
            .timestamp = 3,
            .parent_hash = parent_hash,
            .parent_beacon_block_root = [_]u8{0} ** 32,
        },
        .state_backend = try state.Backend.fromWitness(std.testing.allocator, trie.empty_root_hash, &.{}, &.{}),
        .transactions = &.{},
        .parent_header = .{
            .hash = parent_hash,
            .number = 0,
            .timestamp = 0,
            .gas_limit = 30_000_000,
            .gas_used = 0,
            .base_fee_per_gas = 0,
        },
        .root_checks = testRootChecks(trie.empty_root_hash, trie.empty_root_hash, trie.empty_root_hash),
    });
    try std.testing.expectEqual(Status.timestamp_mismatch, inconsistent.status);
}

test "BlockSTF validates parent-derived header rules before execution" {
    const parent_hash = [_]u8{0x11} ** 32;
    var input = BlockInput{
        .revision = .merge,
        .env = .{ .number = 8, .timestamp = 11, .gas_limit = 10_000_000, .base_fee = 7 },
        .block_header = .{ .number = 8, .timestamp = 11, .parent_hash = parent_hash },
        .parent_header = .{
            .hash = parent_hash,
            .number = 7,
            .timestamp = 10,
            .gas_limit = 10_000_000,
            .gas_used = 5_000_000,
            .base_fee_per_gas = 7,
        },
        .state_backend = try state.Backend.fromWitness(std.testing.allocator, trie.empty_root_hash, &.{}, &.{}),
        .transactions = &.{},
        .root_checks = testRootChecks(trie.empty_root_hash, trie.empty_root_hash, trie.empty_root_hash),
    };
    try std.testing.expectEqual(@as(?Status, null), parentHeaderStatus(input));

    input.block_header.?.parent_hash = [_]u8{0x22} ** 32;
    try std.testing.expectEqual(Status.parent_hash_mismatch, parentHeaderStatus(input).?);
    input.block_header.?.parent_hash = parent_hash;

    input.env.number = 9;
    input.block_header.?.number = 9;
    try std.testing.expectEqual(Status.block_number_mismatch, parentHeaderStatus(input).?);
    input.env.number = 8;
    input.block_header.?.number = 8;

    input.env.timestamp = 10;
    input.block_header.?.timestamp = 10;
    try std.testing.expectEqual(Status.timestamp_mismatch, parentHeaderStatus(input).?);
    input.env.timestamp = 11;
    input.block_header.?.timestamp = 11;

    input.env.gas_limit = 10_000_000 + 10_000_000 / gas_limit_adjustment_factor;
    try std.testing.expectEqual(Status.gas_limit_mismatch, parentHeaderStatus(input).?);
    input.env.gas_limit = 10_000_000;

    input.env.base_fee = 8;
    try std.testing.expectEqual(Status.base_fee_mismatch, parentHeaderStatus(input).?);
}

test "BlockSTF derives EIP-1559 base fee from parent usage" {
    const parent = ParentHeaderContext{
        .hash = [_]u8{0} ** 32,
        .number = 0,
        .timestamp = 0,
        .gas_limit = 20_000_000,
        .gas_used = 20_000_000,
        .base_fee_per_gas = 1_000_000_000,
    };
    try std.testing.expectEqual(@as(u256, 1_125_000_000), expectedBaseFee(parent).?);

    var below_target = parent;
    below_target.gas_used = 0;
    try std.testing.expectEqual(@as(u256, 875_000_000), expectedBaseFee(below_target).?);
}

test "BlockSTF makes requests_hash_mismatch reachable for each request family" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const scratch = arena.allocator();

    const result = try apply(scratch, .{
        .state_backend = try state.Backend.fromWitness(scratch, trie.empty_root_hash, &.{}, &.{}),
        .transactions = &.{},
        .root_checks = testRootChecks(trie.empty_root_hash, trie.empty_root_hash, trie.empty_root_hash),
        .header_claims = .{ .requests_hash = empty_requests_hash },
    });
    try std.testing.expectEqual(Status.valid, result.status);
    try std.testing.expectEqualSlices(u8, &empty_requests_hash, &result.requests_hash);

    const families = [_]struct {
        request_type: u8,
        payload: []const u8,
    }{
        .{ .request_type = eip6110.request_type, .payload = &.{0xbb} },
        .{ .request_type = eip7002.request_type, .payload = &.{0xaa} },
        .{ .request_type = eip7251.request_type, .payload = &.{0xcc} },
        .{ .request_type = eip8282.builder_deposit_request_type, .payload = &.{0xdd} },
        .{ .request_type = eip8282.builder_exit_request_type, .payload = &.{0xee} },
    };

    for (families) |family| {
        const claimed_request = try eip7685.requestBytes(scratch, family.request_type, family.payload);
        const claimed_requests = [_][]const u8{claimed_request};
        const claimed_requests_hash = try requestsHash(scratch, &claimed_requests);

        const mismatch = try apply(scratch, .{
            .state_backend = try state.Backend.fromWitness(scratch, trie.empty_root_hash, &.{}, &.{}),
            .transactions = &.{},
            .root_checks = testRootChecks(trie.empty_root_hash, trie.empty_root_hash, trie.empty_root_hash),
            .header_claims = .{ .requests_hash = claimed_requests_hash },
        });
        try std.testing.expectEqual(Status.requests_hash_mismatch, mismatch.status);
    }
}

test "Amsterdam finalize calls include builder request predeploys" {
    const context = FinalizeBlockContext{
        .number = 1,
        .timestamp = 0,
        .transaction_count = 0,
        .gas_used = 0,
        .block_gas = 0,
        .state_gas = 0,
    };
    const calls = eth_system.Block.finalizeBlock(.amsterdam, context);

    try std.testing.expectEqual(@as(usize, 4), calls.len);
    try std.testing.expectEqualSlices(u8, &eth_system.withdrawal_request_predeploy_address, &calls.items[0].call.recipient);
    try std.testing.expectEqual(eip7002.request_type, calls.items[0].output_prefix);
    try std.testing.expect(calls.items[0].call.require_code);

    try std.testing.expectEqualSlices(u8, &eth_system.consolidation_request_predeploy_address, &calls.items[1].call.recipient);
    try std.testing.expectEqual(eip7251.request_type, calls.items[1].output_prefix);
    try std.testing.expect(calls.items[1].call.require_code);

    try std.testing.expectEqualSlices(u8, &eth_system.builder_deposit_request_predeploy_address, &calls.items[2].call.recipient);
    try std.testing.expectEqual(eip8282.builder_deposit_request_type, calls.items[2].output_prefix);
    try std.testing.expect(calls.items[2].call.require_code);

    try std.testing.expectEqualSlices(u8, &eth_system.builder_exit_request_predeploy_address, &calls.items[3].call.recipient);
    try std.testing.expectEqual(eip8282.builder_exit_request_type, calls.items[3].output_prefix);
    try std.testing.expect(calls.items[3].call.require_code);
}

test "BlockSTF reconstructs Amsterdam header and makes block hash mismatch reachable" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const scratch = arena.allocator();

    const zero_hash = [_]u8{0} ** 32;
    const input = BlockInput{
        .revision = .amsterdam,
        .env = .{
            .number = 0,
            .slot_number = 0,
            .timestamp = 0,
            .gas_limit = 30_000_000,
            .base_fee = 7,
        },
        .state_backend = try state.Backend.fromWitness(scratch, trie.empty_root_hash, &.{}, &.{}),
        .transactions = &.{},
        .parent_blob_gas = .{
            .parent_excess_blob_gas = 0,
            .parent_blob_gas_used = 0,
            .parent_base_fee_per_gas = 7,
        },
        .root_checks = testRootChecks(trie.empty_root_hash, trie.empty_root_hash, trie.empty_root_hash),
        .header_hash_claim = .{
            .block_hash = zero_hash,
            .parent_hash = zero_hash,
            .parent_beacon_block_root = zero_hash,
            .extra_data = &.{},
        },
    };

    const mismatch = try apply(scratch, input);
    try std.testing.expectEqual(Status.block_hash_mismatch, mismatch.status);
    try std.testing.expect(!std.mem.eql(u8, &zero_hash, &mismatch.block_hash));

    var valid_input = input;
    valid_input.header_hash_claim.?.block_hash = mismatch.block_hash;
    const valid = try apply(scratch, valid_input);
    try std.testing.expectEqual(Status.valid, valid.status);
    try std.testing.expectEqualSlices(u8, &mismatch.block_hash, &valid.block_hash);
}

test "BlockSTF compares derived block access list artifact and hash claims" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const scratch = arena.allocator();

    const empty_bal: []const eth_bal.AccountChanges = &.{};
    const empty_claim = try eth_bal.encodeAlloc(scratch, empty_bal);
    const valid = try apply(scratch, .{
        .state_backend = try state.Backend.fromWitness(scratch, trie.empty_root_hash, &.{}, &.{}),
        .transactions = &.{},
        .block_access_list = empty_claim,
        .root_checks = testRootChecks(trie.empty_root_hash, trie.empty_root_hash, trie.empty_root_hash),
        .header_claims = .{ .block_access_list_hash = eth_bal.empty_hash },
    });
    try std.testing.expectEqual(Status.valid, valid.status);
    try std.testing.expectEqualSlices(u8, &eth_bal.empty_hash, &valid.block_access_list_hash);

    const phantom_accounts = [_]eth_bal.AccountChanges{.{ .address = address.addr(0xbeef) }};
    const phantom_claim = try eth_bal.encodeAlloc(scratch, &phantom_accounts);
    const artifact_mismatch = try apply(scratch, .{
        .state_backend = try state.Backend.fromWitness(scratch, trie.empty_root_hash, &.{}, &.{}),
        .transactions = &.{},
        .block_access_list = phantom_claim,
        .root_checks = testRootChecks(trie.empty_root_hash, trie.empty_root_hash, trie.empty_root_hash),
    });
    try std.testing.expectEqual(Status.block_access_list_mismatch, artifact_mismatch.status);

    const hash_mismatch = try apply(scratch, .{
        .state_backend = try state.Backend.fromWitness(scratch, trie.empty_root_hash, &.{}, &.{}),
        .transactions = &.{},
        .block_access_list = empty_claim,
        .root_checks = testRootChecks(trie.empty_root_hash, trie.empty_root_hash, trie.empty_root_hash),
        .header_claims = .{ .block_access_list_hash = [_]u8{0xff} ** 32 },
    });
    try std.testing.expectEqual(Status.block_access_list_hash_mismatch, hash_mismatch.status);

    const malformed_claim = try apply(scratch, .{
        .state_backend = try state.Backend.fromWitness(scratch, trie.empty_root_hash, &.{}, &.{}),
        .transactions = &.{},
        .block_access_list = &.{0xff},
        .root_checks = testRootChecks(trie.empty_root_hash, trie.empty_root_hash, trie.empty_root_hash),
    });
    try std.testing.expectEqual(Status.invalid_block_access_list, malformed_claim.status);

    const oversized_claim = try apply(scratch, .{
        .env = .{ .gas_limit = 1 },
        .state_backend = try state.Backend.fromWitness(scratch, trie.empty_root_hash, &.{}, &.{}),
        .transactions = &.{},
        .block_access_list = phantom_claim,
        .root_checks = testRootChecks(trie.empty_root_hash, trie.empty_root_hash, trie.empty_root_hash),
    });
    try std.testing.expectEqual(Status.block_access_list_too_large, oversized_claim.status);
}

test "BlockSTF records zero withdrawals as block access list accesses" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const scratch = arena.allocator();

    const withdrawal = Withdrawal{
        .index = 1,
        .validator_index = 2,
        .address = address.addr(0x7777),
        .amount = 0,
    };
    const withdrawals = [_]Withdrawal{withdrawal};
    const expected_withdrawals_root = try trie.withdrawalsRoot(scratch, &withdrawals);
    const claimed_accounts = [_]eth_bal.AccountChanges{.{ .address = withdrawal.address }};
    const claimed_bal = try eth_bal.encodeAlloc(scratch, &claimed_accounts);

    const result = try apply(scratch, .{
        .state_backend = try state.Backend.fromWitness(scratch, trie.empty_root_hash, &.{}, &.{}),
        .transactions = &.{},
        .withdrawals = &withdrawals,
        .block_access_list = claimed_bal,
        .root_checks = testRootChecksWithWithdrawals(
            trie.empty_root_hash,
            trie.empty_root_hash,
            trie.empty_root_hash,
            expected_withdrawals_root,
        ),
    });

    try std.testing.expectEqual(Status.valid, result.status);
}

test "BlockSTF validates blob gas header fields" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const scratch = arena.allocator();

    const sender = address.addr(0x4000);
    const blob_hashes = [_]u256{
        @as(u256, 0x01) << 248,
        (@as(u256, 0x01) << 248) | 1,
    };
    const expected_blob_gas_used: u64 = 2 * eth_transaction.Transaction.blobSchedule(.prague).?.gas_per_blob;
    const starting_balance: u256 = 1_000_000;

    const account_key = trie.hashedAddressKey(sender);
    const pre_account_value = try trie.accountValueFrom(scratch, .{ .balance = starting_balance });
    const state_node = try testLeafNode(scratch, &account_key, pre_account_value);
    const pre_state_root = crypto.keccak256(state_node);
    const nodes = [_][]const u8{state_node};
    const tx_input = [_]TransactionInput{.{
        .tx = .{
            .kind = .blob,
            .sender = sender,
            .to = sender,
            .gas_limit = 21_000,
            .max_fee_per_gas = 0,
            .max_priority_fee_per_gas = 0,
            .max_fee_per_blob_gas = 1,
            .blob_hashes = &blob_hashes,
        },
        .encoded = "blobtx0",
    }};

    const post_account_value = try trie.accountValueFrom(scratch, .{
        .nonce = 1,
        .balance = starting_balance - expected_blob_gas_used,
    });
    const post_state_pairs = [_]trie.Pair{.{ .key = &account_key, .value = post_account_value }};
    const expected_state_root = try trie.root(scratch, &post_state_pairs);
    const expected_transactions_root = try trie.transactionRoot(scratch, &.{tx_input[0].encoded});
    const parent_blob_gas = ParentBlobGas{
        .parent_excess_blob_gas = 786_432,
        .parent_blob_gas_used = 786_432,
        .parent_base_fee_per_gas = 1_000_000,
    };
    const expected_excess_blob_gas = EthBlob.calcExcessBlobGas(.prague, parent_blob_gas).?;
    var custom_blob_schedule = eth_transaction.Transaction.blobSchedule(.prague).?;
    custom_blob_schedule.target = 10;
    custom_blob_schedule.max = 12;
    const expected_custom_excess_blob_gas = transaction.calcExcessBlobGasForSchedule(custom_blob_schedule, parent_blob_gas).?;

    const first_result = try apply(scratch, .{
        .revision = .prague,
        .env = .{ .gas_limit = 21_000, .blob_base_fee = 1 },
        .state_backend = try state.Backend.fromWitness(scratch, pre_state_root, &nodes, &.{}),
        .transactions = &tx_input,
        .parent_blob_gas = parent_blob_gas,
        .root_checks = testRootChecks(
            expected_state_root,
            expected_transactions_root,
            [_]u8{0xff} ** 32,
        ),
    });
    try std.testing.expectEqual(Status.receipts_root_mismatch, first_result.status);
    try std.testing.expectEqual(expected_blob_gas_used, first_result.blob_gas_used);
    try std.testing.expectEqual(expected_excess_blob_gas, first_result.excess_blob_gas.?);

    const result = try apply(scratch, .{
        .revision = .prague,
        .env = .{ .gas_limit = 21_000, .blob_base_fee = 1 },
        .state_backend = try state.Backend.fromWitness(scratch, pre_state_root, &nodes, &.{}),
        .transactions = &tx_input,
        .parent_blob_gas = parent_blob_gas,
        .root_checks = testRootChecks(
            expected_state_root,
            expected_transactions_root,
            first_result.receipts_root,
        ),
        .header_claims = .{
            .blob_gas_used = expected_blob_gas_used,
            .excess_blob_gas = expected_excess_blob_gas,
        },
    });
    try std.testing.expectEqual(Status.valid, result.status);

    const custom_schedule_result = try apply(scratch, .{
        .revision = .prague,
        .env = .{ .gas_limit = 21_000, .blob_base_fee = 1, .blob_schedule = custom_blob_schedule },
        .state_backend = try state.Backend.fromWitness(scratch, pre_state_root, &nodes, &.{}),
        .transactions = &tx_input,
        .parent_blob_gas = parent_blob_gas,
        .root_checks = testRootChecks(
            expected_state_root,
            expected_transactions_root,
            first_result.receipts_root,
        ),
        .header_claims = .{
            .blob_gas_used = expected_blob_gas_used,
            .excess_blob_gas = expected_custom_excess_blob_gas,
        },
    });
    try std.testing.expectEqual(Status.valid, custom_schedule_result.status);
    try std.testing.expect(expected_custom_excess_blob_gas != expected_excess_blob_gas);

    const blob_gas_mismatch = try apply(scratch, .{
        .revision = .prague,
        .env = .{ .gas_limit = 21_000, .blob_base_fee = 1 },
        .state_backend = try state.Backend.fromWitness(scratch, pre_state_root, &nodes, &.{}),
        .transactions = &tx_input,
        .parent_blob_gas = parent_blob_gas,
        .root_checks = testRootChecks(
            expected_state_root,
            expected_transactions_root,
            first_result.receipts_root,
        ),
        .header_claims = .{ .blob_gas_used = expected_blob_gas_used + 1 },
    });
    try std.testing.expectEqual(Status.blob_gas_used_mismatch, blob_gas_mismatch.status);

    const excess_blob_gas_mismatch = try apply(scratch, .{
        .revision = .prague,
        .env = .{ .gas_limit = 21_000, .blob_base_fee = 1 },
        .state_backend = try state.Backend.fromWitness(scratch, pre_state_root, &nodes, &.{}),
        .transactions = &tx_input,
        .parent_blob_gas = parent_blob_gas,
        .root_checks = testRootChecks(
            expected_state_root,
            expected_transactions_root,
            first_result.receipts_root,
        ),
        .header_claims = .{ .excess_blob_gas = expected_excess_blob_gas + 1 },
    });
    try std.testing.expectEqual(Status.excess_blob_gas_mismatch, excess_blob_gas_mismatch.status);
}

test "BlockSTF rejects cumulative blob gas above the block schedule cap" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const scratch = arena.allocator();

    const sender = address.addr(0x4001);
    const first_blob_hashes = [_]u256{
        @as(u256, 0x01) << 248,
        (@as(u256, 0x01) << 248) | 1,
        (@as(u256, 0x01) << 248) | 2,
        (@as(u256, 0x01) << 248) | 3,
        (@as(u256, 0x01) << 248) | 4,
        (@as(u256, 0x01) << 248) | 5,
    };
    const second_blob_hashes = [_]u256{(@as(u256, 0x01) << 248) | 6};
    const oversized_blob_hashes = [_]u256{
        @as(u256, 0x01) << 248,
        (@as(u256, 0x01) << 248) | 1,
        (@as(u256, 0x01) << 248) | 2,
        (@as(u256, 0x01) << 248) | 3,
        (@as(u256, 0x01) << 248) | 4,
        (@as(u256, 0x01) << 248) | 5,
        (@as(u256, 0x01) << 248) | 6,
    };
    const account_key = trie.hashedAddressKey(sender);
    const pre_account_value = try trie.accountValueFrom(scratch, .{ .balance = 2_000_000 });
    const state_node = try testLeafNode(scratch, &account_key, pre_account_value);
    const pre_state_root = crypto.keccak256(state_node);
    const nodes = [_][]const u8{state_node};
    const transactions = [_]TransactionInput{
        .{
            .tx = .{
                .kind = .blob,
                .sender = sender,
                .to = sender,
                .gas_limit = 21_000,
                .max_fee_per_gas = 0,
                .max_priority_fee_per_gas = 0,
                .max_fee_per_blob_gas = 1,
                .blob_hashes = &first_blob_hashes,
            },
            .encoded = "blobtx0",
        },
        .{
            .tx = .{
                .kind = .blob,
                .sender = sender,
                .to = sender,
                .gas_limit = 21_000,
                .max_fee_per_gas = 0,
                .max_priority_fee_per_gas = 0,
                .max_fee_per_blob_gas = 1,
                .blob_hashes = &second_blob_hashes,
            },
            .encoded = "blobtx1",
        },
    };
    const oversized_transactions = [_]TransactionInput{.{
        .tx = .{
            .kind = .blob,
            .sender = sender,
            .to = sender,
            .gas_limit = 21_000,
            .max_fee_per_gas = 0,
            .max_priority_fee_per_gas = 0,
            .max_fee_per_blob_gas = 1,
            .blob_hashes = &oversized_blob_hashes,
        },
        .encoded = "oversized-blobtx",
    }};

    const oversized_result = try apply(scratch, .{
        .revision = .cancun,
        .env = .{ .gas_limit = 21_000, .blob_base_fee = 1 },
        .state_backend = try state.Backend.fromWitness(scratch, pre_state_root, &nodes, &.{}),
        .transactions = &oversized_transactions,
        .root_checks = testRootChecks(trie.empty_root_hash, trie.empty_root_hash, trie.empty_root_hash),
    });
    try std.testing.expectEqual(Status.blob_gas_limit_exceeded, oversized_result.status);
    try std.testing.expectEqual(@as(?usize, 0), oversized_result.tx_index);
    try std.testing.expectEqual(@as(u64, 0), oversized_result.blob_gas_used);

    const pre_cancun_result = try apply(scratch, .{
        .revision = .shanghai,
        .env = .{ .gas_limit = 21_000 },
        .state_backend = try state.Backend.fromWitness(scratch, pre_state_root, &nodes, &.{}),
        .transactions = &oversized_transactions,
        .root_checks = testRootChecks(trie.empty_root_hash, trie.empty_root_hash, trie.empty_root_hash),
    });
    try std.testing.expectEqual(Status.transaction_rejected, pre_cancun_result.status);
    try std.testing.expectEqual(@as(?usize, 0), pre_cancun_result.tx_index);

    var custom_schedule = eth_transaction.Transaction.blobSchedule(.cancun).?;
    custom_schedule.max = 1;
    const custom_schedule_result = try apply(scratch, .{
        .revision = .cancun,
        .env = .{ .gas_limit = 21_000, .blob_base_fee = 1, .blob_schedule = custom_schedule },
        .state_backend = try state.Backend.fromWitness(scratch, pre_state_root, &nodes, &.{}),
        .transactions = transactions[0..1],
        .root_checks = testRootChecks(trie.empty_root_hash, trie.empty_root_hash, trie.empty_root_hash),
    });
    try std.testing.expectEqual(Status.blob_gas_limit_exceeded, custom_schedule_result.status);
    try std.testing.expectEqual(@as(?usize, 0), custom_schedule_result.tx_index);

    const result = try apply(scratch, .{
        .revision = .cancun,
        .env = .{ .gas_limit = 42_000, .blob_base_fee = 1 },
        .state_backend = try state.Backend.fromWitness(scratch, pre_state_root, &nodes, &.{}),
        .transactions = &transactions,
        .root_checks = testRootChecks(trie.empty_root_hash, trie.empty_root_hash, trie.empty_root_hash),
    });

    const schedule = eth_transaction.Transaction.blobSchedule(.cancun).?;
    try std.testing.expectEqual(Status.blob_gas_limit_exceeded, result.status);
    try std.testing.expectEqual(@as(?usize, 1), result.tx_index);
    try std.testing.expectEqual(schedule.max * schedule.gas_per_blob, result.blob_gas_used);
}

test "BlockSTF applies withdrawals to state balances" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const scratch = arena.allocator();

    const recipient = address.addr(0x1234);
    const withdrawals = [_]Withdrawal{.{
        .index = 0,
        .validator_index = 1,
        .address = recipient,
        .amount = 3,
    }};
    const credited_balance: u256 = 3 * withdrawal_gwei_in_wei;
    const account_key = trie.hashedAddressKey(recipient);
    const account_value = try trie.accountValueFrom(scratch, .{ .balance = credited_balance });
    const expected_state_pairs = [_]trie.Pair{.{ .key = &account_key, .value = account_value }};
    const expected_state_root = try trie.root(scratch, &expected_state_pairs);
    const expected_withdrawals_root = try trie.withdrawalsRoot(scratch, &withdrawals);

    const result = try apply(scratch, .{
        .revision = .shanghai,
        .state_backend = try state.Backend.fromWitness(scratch, trie.empty_root_hash, &.{}, &.{}),
        .transactions = &.{},
        .withdrawals = &withdrawals,
        .root_checks = testRootChecksWithWithdrawals(
            expected_state_root,
            trie.empty_root_hash,
            trie.empty_root_hash,
            expected_withdrawals_root,
        ),
    });
    try std.testing.expectEqual(Status.valid, result.status);
    try std.testing.expectEqualSlices(u8, &expected_state_root, &result.state_root);

    const mutated_withdrawals = [_]Withdrawal{.{
        .index = withdrawals[0].index,
        .validator_index = withdrawals[0].validator_index,
        .address = withdrawals[0].address,
        .amount = withdrawals[0].amount + 1,
    }};
    const mutated_withdrawals_root = try trie.withdrawalsRoot(scratch, &mutated_withdrawals);
    const mutated = try apply(scratch, .{
        .revision = .shanghai,
        .state_backend = try state.Backend.fromWitness(scratch, trie.empty_root_hash, &.{}, &.{}),
        .transactions = &.{},
        .withdrawals = &mutated_withdrawals,
        .root_checks = testRootChecksWithWithdrawals(
            expected_state_root,
            trie.empty_root_hash,
            trie.empty_root_hash,
            mutated_withdrawals_root,
        ),
    });
    try std.testing.expectEqual(Status.state_root_mismatch, mutated.status);
}

test "BlockSTF rejects fork-inactive body fields before state access" {
    const withdrawal = Withdrawal{
        .index = 0,
        .validator_index = 0,
        .address = address.addr(0x1234),
        .amount = 1,
    };
    const roots = testRootChecks(trie.empty_root_hash, trie.empty_root_hash, trie.empty_root_hash);

    const pre_shanghai = try apply(std.testing.allocator, .{
        .revision = .merge,
        .state_backend = try state.Backend.fromWitness(std.testing.allocator, trie.empty_root_hash, &.{}, &.{}),
        .transactions = &.{},
        .withdrawals = &.{withdrawal},
        .root_checks = roots,
    });
    try std.testing.expectEqual(Status.invalid_block_body, pre_shanghai.status);

    const pre_cancun = try apply(std.testing.allocator, .{
        .revision = .shanghai,
        .state_backend = try state.Backend.fromWitness(std.testing.allocator, trie.empty_root_hash, &.{}, &.{}),
        .transactions = &.{},
        .parent_blob_gas = .{
            .parent_excess_blob_gas = 0,
            .parent_blob_gas_used = 0,
            .parent_base_fee_per_gas = 0,
        },
        .root_checks = roots,
    });
    try std.testing.expectEqual(Status.invalid_block_body, pre_cancun.status);

    const pre_amsterdam = try apply(std.testing.allocator, .{
        .revision = .prague,
        .state_backend = try state.Backend.fromWitness(std.testing.allocator, trie.empty_root_hash, &.{}, &.{}),
        .transactions = &.{},
        .block_access_list = &.{},
        .root_checks = roots,
    });
    try std.testing.expectEqual(Status.invalid_block_body, pre_amsterdam.status);
}

test "stateless receipt encoder writes consensus receipt rlp" {
    var counted = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const legacy_before = counted.alloc_index;
    const encoded = try encodeReceipt(counted.allocator(), .legacy, .{
        .status = .success,
        .cumulative_gas_used = 21_000,
    });
    defer counted.allocator().free(encoded);

    try std.testing.expectEqual(legacy_before + 1, counted.alloc_index);
    try expectHex(encoded, "f9010801825208b9010000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000c0");

    const typed_before = counted.alloc_index;
    const typed = try encodeReceipt(counted.allocator(), .dynamic_fee, .{
        .status = .success,
        .cumulative_gas_used = 21_000,
    });
    defer counted.allocator().free(typed);
    try std.testing.expectEqual(typed_before + 1, counted.alloc_index);
    try std.testing.expectEqual(@as(u8, 0x02), typed[0]);
    try std.testing.expectEqualSlices(u8, encoded, typed[1..]);
}

test "stateless receipt encoder includes logs and bloom" {
    const target = address.addr(0x3000);
    const topics = [_]u256{0x1234};
    const event_log = Log{
        .address = target,
        .topics = &topics,
        .data = &.{ 0xab, 0xcd },
    };
    var counted = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const before = counted.alloc_index;
    const encoded = try encodeReceipt(counted.allocator(), .legacy, .{
        .status = .revert,
        .cumulative_gas_used = 30_000,
        .logs = &.{event_log},
    });
    defer counted.allocator().free(encoded);

    try std.testing.expectEqual(before + 1, counted.alloc_index);
    var raw = rlp.Cursor.init(encoded);
    var raw_receipt = try raw.nextList();
    try raw.expectDone();
    _ = try raw_receipt.nextInt(u8);
    _ = try raw_receipt.nextInt(u64);
    _ = try raw_receipt.nextBytesExact(256);
    var raw_logs = try raw_receipt.nextList();
    var raw_log = try raw_logs.nextList();
    try std.testing.expectEqualSlices(u8, &target, try raw_log.nextBytesExact(20));
    var raw_topics = try raw_log.nextList();
    const expected_topic = uint256.toBytes32(topics[0]);
    try std.testing.expectEqualSlices(u8, &expected_topic, try raw_topics.nextBytesExact(32));
    try raw_topics.expectDone();
    try std.testing.expectEqualSlices(u8, &.{ 0xab, 0xcd }, try raw_log.nextBytes());
    try raw_log.expectDone();
    try raw_logs.expectDone();
    try raw_receipt.expectDone();

    var decoded = try rlp.decodeAlloc(ReceiptPayload, std.testing.allocator, encoded);
    defer rlp.deinit(ReceiptPayload, std.testing.allocator, &decoded);
    try std.testing.expectEqual(@as(u8, 0), decoded.status);
    try std.testing.expectEqual(@as(u64, 30_000), decoded.cumulative_gas_used);
    try std.testing.expect(!std.mem.allEqual(u8, &decoded.logs_bloom, 0));
    try std.testing.expectEqual(@as(usize, 1), decoded.logs.len);
    try std.testing.expectEqualSlices(u8, &target, &decoded.logs[0].address);
    try std.testing.expectEqualSlices(u256, &topics, decoded.logs[0].topics);
    try std.testing.expectEqualSlices(u8, &.{ 0xab, 0xcd }, decoded.logs[0].data);
}

test "stateless receipt schema enforces the EVM log topic limit" {
    const accepted_topics = [_]u256{ 1, 2, 3, 4 };
    const accepted = try encodeReceipt(std.testing.allocator, .legacy, .{
        .status = .success,
        .logs = &.{.{
            .address = address.addr(0x3000),
            .topics = &accepted_topics,
            .data = &.{},
        }},
    });
    defer std.testing.allocator.free(accepted);

    const rejected_topics = [_]u256{ 1, 2, 3, 4, 5 };
    try std.testing.expectError(error.ListLimitExceeded, encodeReceipt(std.testing.allocator, .legacy, .{
        .status = .success,
        .logs = &.{.{
            .address = address.addr(0x3000),
            .topics = &rejected_topics,
            .data = &.{},
        }},
    }));
}

test "stateless receipt typed decode cleans nested allocation failures" {
    const Harness = struct {
        fn run(allocator: std.mem.Allocator) !void {
            const topics = [_]u256{ 1, 2 };
            const logs = [_]Log{.{
                .address = address.addr(0x3000),
                .topics = &topics,
                .data = &.{ 0xab, 0xcd },
            }};
            const payload: ReceiptPayload = .{
                .status = 1,
                .cumulative_gas_used = 21_000,
                .logs_bloom = logsBloom(&logs),
                .logs = &logs,
            };
            var out: [512]u8 = undefined;
            const encoded = try rlp.encode(ReceiptPayload, &out, &payload);
            var decoded = try rlp.decodeAlloc(ReceiptPayload, allocator, encoded);
            defer rlp.deinit(ReceiptPayload, allocator, &decoded);
            try std.testing.expectEqualSlices(u256, &topics, decoded.logs[0].topics);
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Harness.run, .{});
}

fn testLeafNode(allocator: std.mem.Allocator, key: []const u8, value: []const u8) ![]u8 {
    var payload = rlp.Writer.alloc(allocator);
    defer payload.deinit();
    try payload.bytes(try testCompactPath(allocator, key));
    try payload.bytes(value);

    var out = rlp.Writer.alloc(allocator);
    errdefer out.deinit();
    try out.listPayload(payload.written());
    return try writerOwned(&out);
}

fn testCompactPath(allocator: std.mem.Allocator, key: []const u8) ![]u8 {
    const out = try allocator.alloc(u8, key.len + 1);
    out[0] = 0x20;
    @memcpy(out[1..], key);
    return out;
}

fn writerOwned(writer: *rlp.Writer) std.mem.Allocator.Error![]u8 {
    return writer.toOwnedSlice() catch |err| switch (err) {
        error.BorrowedWriter => unreachable,
        error.OutOfMemory => return error.OutOfMemory,
    };
}

fn expectHex(actual: []const u8, expected_hex: []const u8) !void {
    if (std.mem.startsWith(u8, expected_hex, "f9010801825208b90100") and std.mem.endsWith(u8, expected_hex, "c0")) {
        try std.testing.expectEqual(@as(usize, 267), actual.len);
        try std.testing.expectEqualSlices(u8, &.{ 0xf9, 0x01, 0x08, 0x01, 0x82, 0x52, 0x08, 0xb9, 0x01, 0x00 }, actual[0..10]);
        try std.testing.expect(std.mem.allEqual(u8, actual[10..266], 0));
        try std.testing.expectEqual(@as(u8, 0xc0), actual[266]);
        return;
    }
    const expected = try std.testing.allocator.alloc(u8, expected_hex.len / 2);
    defer std.testing.allocator.free(expected);
    _ = try std.fmt.hexToBytes(expected, expected_hex);
    try std.testing.expectEqualSlices(u8, expected, actual);
}
