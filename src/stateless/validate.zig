//! Stateless Ethereum validation over normalized input.

const std = @import("std");

const Revision = @import("../eth/revision.zig").Revision;
const eth_spec = @import("../eth/spec.zig");
const system_prepared_code = @import("../eth/system_prepared_code.zig");
const Vm = @import("../vm.zig");
const block_stf = @import("../eth/block_stf.zig");
const crypto = @import("../crypto.zig");
const input_mod = @import("./input.zig");
const trie = @import("../eth/trie.zig");
const rlp = @import("rlp");
const state = @import("../state.zig");
const stateless_tx = @import("./tx.zig");
const transaction = @import("../transaction.zig");

pub const Error = std.mem.Allocator.Error || rlp.ParseError || trie.Error || stateless_tx.Error || error{
    MissingParentHeader,
    InvalidHeaderWitness,
    InvalidRequest,
    BlockTransitionFailed,
};

pub const Options = struct {
    /// Prove every BAL-declared account/storage path before execution. Disabled
    /// by default because witness-backed readers would otherwise traverse the
    /// same proofs again during execution.
    precheck_block_access_list_state: bool = false,
    /// Optional expected-vs-observed BAL diagnostics.
    bal_differential: ?*block_stf.BalDifferentialReport = null,
};

/// Exact stateless validator for one Ethereum revision.
///
/// Callers supporting multiple revisions dispatch to these types themselves;
/// this library never compiles or loops over a runtime fork set.
pub fn Exact(comptime revision: Revision) type {
    return ExactWithOptions(revision, .{});
}

pub fn ExactWithOptions(comptime revision: Revision, comptime compile_options: Vm.CompileOptions) type {
    const ExactBlockStf = block_stf.ExactWithOptions(revision, compile_options);

    return struct {
        pub const fork = revision;
        pub const options = compile_options;
        pub const BlockStf = ExactBlockStf;

        pub fn validate(allocator: std.mem.Allocator, input: input_mod.Input) Error!block_stf.Result {
            return validateWithOptions(allocator, input, .{});
        }

        pub fn validateWithOptions(
            allocator: std.mem.Allocator,
            input: input_mod.Input,
            validation_options: Options,
        ) Error!block_stf.Result {
            return validateWithCaptureOptions(allocator, input, null, validation_options);
        }

        pub fn validateWithCapture(
            allocator: std.mem.Allocator,
            input: input_mod.Input,
            capture: ?block_stf.ExecutionCapture,
        ) Error!block_stf.Result {
            return validateWithCaptureOptions(allocator, input, capture, .{});
        }

        pub fn validateWithCaptureOptions(
            allocator: std.mem.Allocator,
            input: input_mod.Input,
            capture: ?block_stf.ExecutionCapture,
            validation_options: Options,
        ) Error!block_stf.Result {
            var arena = std.heap.ArenaAllocator.init(allocator);
            defer arena.deinit();
            return validateWithScratchExact(
                revision,
                ExactBlockStf,
                arena.allocator(),
                input,
                capture,
                validation_options,
            );
        }

        /// Reuses a caller-owned one-shot scratch lifetime instead of nesting
        /// another arena. The caller releases all allocations together.
        pub fn validateOneShot(
            allocator: std.mem.Allocator,
            input: input_mod.Input,
        ) Error!block_stf.Result {
            return validateWithScratchExact(
                revision,
                ExactBlockStf,
                allocator,
                input,
                null,
                .{},
            );
        }
    };
}

fn validateWithScratchExact(
    comptime revision: Revision,
    comptime ExactBlockStf: type,
    allocator: std.mem.Allocator,
    input: input_mod.Input,
    capture: ?block_stf.ExecutionCapture,
    options: Options,
) Error!block_stf.Result {
    const block = input.block;
    if (!blockShapeValid(revision, block)) return .{ .status = .invalid_block_body };
    var header_chain = try HeaderChain.init(
        allocator,
        input.witness.headers,
        block.parent_hash,
        block.number,
    );
    defer header_chain.deinit(allocator);
    const parent_header = header_chain.parent();
    const codes = try witnessCodes(allocator, input.witness.codes);

    return validateExact(
        revision,
        ExactBlockStf,
        allocator,
        input,
        capture,
        options,
        &header_chain,
        parent_header,
        codes,
    );
}

fn validateExact(
    comptime revision: Revision,
    comptime ExactBlockStf: type,
    allocator: std.mem.Allocator,
    input: input_mod.Input,
    capture: ?block_stf.ExecutionCapture,
    options: Options,
    header_chain: *HeaderChain,
    parent_header: ParsedHeader,
    codes: []const state.WitnessStateReader.Code,
) Error!block_stf.Result {
    const block = input.block;
    return ExactBlockStf.applyAssumeDecoded(allocator, .{
        .env = .{
            .chain_id = input.chain_id,
            .coinbase = block.fee_recipient,
            .number = block.number,
            .slot_number = block.slot_number,
            .timestamp = block.timestamp,
            .gas_limit = block.gas_limit,
            .prev_randao = block.prev_randao,
            .base_fee = block.base_fee_per_gas,
            .blob_base_fee = try currentBlobBaseFeeExact(revision, input.blob_schedule, block),
            .blob_schedule = input.blob_schedule,
        },
        .block_hash_source = header_chain.source(),
        .block_header = .{
            .number = block.number,
            .timestamp = block.timestamp,
            .parent_hash = block.parent_hash,
            .parent_beacon_block_root = block.parent_beacon_block_root,
        },
        .state_backend = try state.Backend.fromWitness(allocator, parent_header.state_root, input.witness.state, codes),
        .prepared_code_backend = system_prepared_code.backend(),
        .transactions = block.transactions,
        .withdrawals = block.withdrawals,
        .parent_header = .{
            .hash = parent_header.hash,
            .number = parent_header.number,
            .timestamp = parent_header.timestamp,
            .gas_limit = parent_header.gas_limit,
            .gas_used = parent_header.gas_used,
            .base_fee_per_gas = parent_header.base_fee_per_gas orelse 0,
            .blob_gas_used = parent_header.blob_gas_used orelse 0,
            .excess_blob_gas = parent_header.excess_blob_gas orelse 0,
        },
        .block_access_list = if (revision.isImpl(.amsterdam)) block.block_access_list else null,
        .root_checks = .{
            .payload_header = .{
                .state = .fromHash(block.state_root),
                .receipts = .fromHash(block.receipts_root),
            },
        },
        .header_claims = .{
            .gas_used = if (revision.isImpl(.amsterdam)) null else block.gas_used,
            .block_gas_used = if (revision.isImpl(.amsterdam)) block.gas_used else null,
            .logs_bloom = block.logs_bloom,
            .blob_gas_used = block.blob_gas_used,
            .excess_blob_gas = try expectedExcessBlobGas(revision, block),
            .requests_hash = if (revision.isImpl(.prague))
                try block_stf.requestsHash(allocator, block.execution_requests)
            else
                null,
        },
        .header_hash_claim = .{
            .block_hash = block.block_hash,
            .parent_hash = block.parent_hash,
            .parent_beacon_block_root = block.parent_beacon_block_root,
            .extra_data = block.extra_data,
        },
        .capture = capture,
        .bal_differential = options.bal_differential,
        // Future optimization: verified values can seed the execution overlay
        // or reader cache, after which this can become the default without
        // repeating proof traversal. It never changes EVM warmth semantics.
        .precheck_block_access_list_state = shouldPrecheckBlockAccessListState(
            revision,
            options,
        ),
    }) catch |err| return mapBlockError(err);
}

fn shouldPrecheckBlockAccessListState(revision: Revision, options: Options) bool {
    return revision.isImpl(.amsterdam) and options.precheck_block_access_list_state;
}

fn mapBlockError(err: anyerror) Error!block_stf.Result {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.InvalidWitness => .{ .status = .invalid_witness },
        error.BlobGasOverflow,
        error.BlockAccessIndexOverflow,
        error.WithdrawalBalanceOverflow,
        => .{ .status = .invalid_block_body },
        else => error.BlockTransitionFailed,
    };
}

fn blockShapeValid(revision: Revision, block: input_mod.Block) bool {
    if (!revision.isImpl(.shanghai) and block.withdrawals.len != 0) return false;

    const has_cancun = revision.isImpl(.cancun);
    if ((block.blob_gas_used != null) != has_cancun or
        (block.excess_blob_gas != null) != has_cancun or
        (block.parent_beacon_block_root != null) != has_cancun)
    {
        return false;
    }
    if (!has_cancun and block.versioned_hashes.len != 0) return false;
    if (!revision.isImpl(.prague) and block.execution_requests.len != 0) return false;

    if (revision.isImpl(.amsterdam)) {
        if (block.block_access_list == null) return false;
    } else if (block.block_access_list != null or block.slot_number != 0) {
        return false;
    }
    return true;
}

fn currentBlobBaseFeeExact(
    comptime revision: Revision,
    blob_schedule: ?transaction.BlobSchedule,
    block: input_mod.Block,
) Error!u256 {
    if (!revision.isImpl(.cancun)) return 0;
    const excess_blob_gas = block.excess_blob_gas orelse return error.InvalidHeaderWitness;
    if (blob_schedule) |schedule| {
        return transaction.blobBaseFeeForSchedule(schedule, excess_blob_gas) orelse error.InvalidHeaderWitness;
    }
    const schedule = eth_spec.specAt(revision).transaction.blob_schedule orelse return 0;
    return transaction.blobBaseFeeForSchedule(schedule, excess_blob_gas) orelse error.InvalidHeaderWitness;
}

fn expectedExcessBlobGas(revision: Revision, block: input_mod.Block) Error!?u256 {
    if (!revision.isImpl(.cancun)) return null;
    return block.excess_blob_gas orelse error.InvalidHeaderWitness;
}

const ParsedHeader = struct {
    hash: [32]u8,
    parent_hash: [32]u8,
    state_root: [32]u8,
    number: u64,
    gas_limit: u64,
    gas_used: u64,
    timestamp: u64,
    base_fee_per_gas: ?u256 = null,
    blob_gas_used: ?u64 = null,
    excess_blob_gas: ?u64 = null,
};

const HeaderChain = struct {
    headers: []const ParsedHeader,
    current_number: u64,

    fn init(
        allocator: std.mem.Allocator,
        encoded_headers: []const []const u8,
        parent_hash: [32]u8,
        current_number: u64,
    ) Error!HeaderChain {
        if (encoded_headers.len == 0) return error.MissingParentHeader;

        // Headers ascend to the parent. Pinning the last hash and every
        // parent link authenticates the whole ancestry against the payload.
        const headers = try allocator.alloc(ParsedHeader, encoded_headers.len);
        errdefer allocator.free(headers);
        for (headers, encoded_headers) |*target, encoded| target.* = try parseHeader(encoded);
        if (!std.mem.eql(u8, &headers[headers.len - 1].hash, &parent_hash)) {
            return error.MissingParentHeader;
        }
        for (headers[1..], headers[0 .. headers.len - 1]) |child, previous| {
            if (!std.mem.eql(u8, &child.parent_hash, &previous.hash)) {
                return error.InvalidHeaderWitness;
            }
        }

        return .{ .headers = headers, .current_number = current_number };
    }

    fn deinit(self: HeaderChain, allocator: std.mem.Allocator) void {
        allocator.free(self.headers);
    }

    fn parent(self: HeaderChain) ParsedHeader {
        return self.headers[self.headers.len - 1];
    }

    fn source(self: *@This()) Vm.BlockHashSource {
        return .{ .ptr = self, .vtable = &.{
            .getBlockHash = getBlockHash,
        } };
    }

    fn getBlockHash(ptr: *anyopaque, number: u64) !?u256 {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        if (number >= self.current_number or self.current_number - number > 256) return null;
        for (self.headers) |header| {
            if (header.number != number) continue;
            return std.mem.readInt(u256, &header.hash, .big);
        }
        return error.InvalidWitness;
    }
};

fn parseHeader(encoded_header: []const u8) Error!ParsedHeader {
    var cursor = rlp.Cursor.init(encoded_header);
    var fields = try cursor.nextList();
    try cursor.expectDone();

    const parent_hash = (try fields.nextBytesExact(32))[0..32].*;
    _ = try fields.nextBytesExact(32);
    _ = try fields.nextBytesExact(20);
    const state_root = (try fields.nextBytesExact(32))[0..32].*;
    _ = try fields.nextBytesExact(32);
    _ = try fields.nextBytesExact(32);
    _ = try fields.nextBytesExact(256);
    _ = try fields.nextInt(u256);
    const number = try fields.nextInt(u64);
    const gas_limit = try fields.nextInt(u64);
    const gas_used = try fields.nextInt(u64);
    const timestamp = try fields.nextInt(u64);
    _ = try fields.nextBytes();
    _ = try fields.nextBytesExact(32);
    _ = try fields.nextBytesExact(8);

    var base_fee_per_gas: ?u256 = null;
    var blob_gas_used: ?u64 = null;
    var excess_blob_gas: ?u64 = null;
    if (!fields.isDone()) base_fee_per_gas = try fields.nextInt(u256);
    if (!fields.isDone()) _ = try fields.nextBytesExact(32);
    if (!fields.isDone()) blob_gas_used = try fields.nextInt(u64);
    if (!fields.isDone()) excess_blob_gas = try fields.nextInt(u64);

    return .{
        .hash = crypto.keccak256(encoded_header),
        .parent_hash = parent_hash,
        .state_root = state_root,
        .number = number,
        .gas_limit = gas_limit,
        .gas_used = gas_used,
        .timestamp = timestamp,
        .base_fee_per_gas = base_fee_per_gas,
        .blob_gas_used = blob_gas_used,
        .excess_blob_gas = excess_blob_gas,
    };
}

fn witnessCodes(allocator: std.mem.Allocator, codes: []const []const u8) std.mem.Allocator.Error![]const state.WitnessStateReader.Code {
    const out = try allocator.alloc(state.WitnessStateReader.Code, codes.len);
    for (out, codes) |*item, code| {
        item.* = .{ .hash = crypto.keccak256(code), .bytes = code };
    }
    return out;
}

test "normalized stateless block shape uses actual fields" {
    const base = input_mod.Block{
        .parent_hash = [_]u8{0} ** 32,
        .fee_recipient = [_]u8{0} ** 20,
        .state_root = [_]u8{0} ** 32,
        .receipts_root = [_]u8{0} ** 32,
        .logs_bloom = [_]u8{0} ** 256,
        .prev_randao = 0,
        .number = 1,
        .gas_limit = 30_000_000,
        .gas_used = 0,
        .timestamp = 1,
        .extra_data = &.{},
        .base_fee_per_gas = 1,
        .block_hash = [_]u8{0} ** 32,
    };

    try std.testing.expect(blockShapeValid(.merge, base));

    var inactive_withdrawals = base;
    inactive_withdrawals.withdrawals = &.{.{
        .index = 0,
        .validator_index = 0,
        .address = [_]u8{0} ** 20,
        .amount = 0,
    }};
    try std.testing.expect(!blockShapeValid(.merge, inactive_withdrawals));

    var premature_blob_field = base;
    premature_blob_field.blob_gas_used = 0;
    try std.testing.expect(!blockShapeValid(.shanghai, premature_blob_field));

    var cancun = base;
    cancun.blob_gas_used = 0;
    cancun.excess_blob_gas = 0;
    cancun.parent_beacon_block_root = [_]u8{0} ** 32;
    try std.testing.expect(blockShapeValid(.cancun, cancun));

    var incomplete_cancun = cancun;
    incomplete_cancun.excess_blob_gas = null;
    try std.testing.expect(!blockShapeValid(.cancun, incomplete_cancun));

    var amsterdam = cancun;
    amsterdam.block_access_list = &.{};
    try std.testing.expect(blockShapeValid(.amsterdam, amsterdam));
}

test "stateless block errors preserve witness and body taxonomy" {
    try std.testing.expectEqual(
        block_stf.Status.invalid_witness,
        (try mapBlockError(error.InvalidWitness)).status,
    );
    try std.testing.expectEqual(
        block_stf.Status.invalid_block_body,
        (try mapBlockError(error.WithdrawalBalanceOverflow)).status,
    );
    try std.testing.expectError(error.BlockTransitionFailed, mapBlockError(error.CodeUnavailable));
}

test "stateless BAL witness precheck is an explicit Amsterdam option" {
    try std.testing.expect(!shouldPrecheckBlockAccessListState(.amsterdam, .{}));
    try std.testing.expect(shouldPrecheckBlockAccessListState(.amsterdam, .{
        .precheck_block_access_list_state = true,
    }));
    try std.testing.expect(!shouldPrecheckBlockAccessListState(.prague, .{
        .precheck_block_access_list_state = true,
    }));
}

test "recent block hash lookup rejects a missing authenticated ancestor" {
    var chain = HeaderChain{
        .headers = &.{},
        .current_number = 300,
    };
    try std.testing.expectError(error.InvalidWitness, HeaderChain.getBlockHash(&chain, 299));
    try std.testing.expectEqual(@as(?u256, null), try HeaderChain.getBlockHash(&chain, 300));
    try std.testing.expectEqual(@as(?u256, null), try HeaderChain.getBlockHash(&chain, 43));
}
