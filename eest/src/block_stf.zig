const std = @import("std");
const evmz = @import("evmz");
const bal_fixture = @import("block_access_list_fixture.zig");
const fixture_common = @import("fixture.zig");
const tx_validation = @import("tx_validation.zig");

const JsonArray = std.json.Array;
const JsonObject = std.json.ObjectMap;
const JsonValue = fixture_common.JsonValue;
const block_stf = evmz.eth.block_stf;

const asArray = fixture_common.asArray;
const asObject = fixture_common.asObject;
const jsonString = fixture_common.jsonString;
const parseAddressFromValue = fixture_common.parseAddressFromValue;
const parseBytesFromValue = fixture_common.parseBytesFromValue;
const parseHashFromValue = fixture_common.parseHashFromValue;
const parseFixtureConfig = fixture_common.parseFixtureConfig;
const parseStateFork = fixture_common.parseStateFork;
const parseU256FromValue = fixture_common.parseU256FromValue;
const parseU64FromValue = fixture_common.parseU64FromValue;
const seedMemoryStore = fixture_common.seedMemoryStore;

pub const SkipReason = enum(u8) {
    expected_exception,
    unsupported_fork,
    unsupported_transaction_type,
    unsupported_payload_shape,
};

pub const FailReason = enum(u8) {
    malformed_fixture,
    validation_error,
    unexpected_status,
    parent_hash_mismatch,
    block_number_mismatch,
    blob_versioned_hashes_mismatch,
    pre_state_root_mismatch,
    expected_exception_mismatch,
};

pub const Summary = struct {
    fixtures: usize = 0,
    passed: usize = 0,
    failed: usize = 0,
    skipped: usize = 0,
    skip_reasons: [std.meta.fields(SkipReason).len]usize = [_]usize{0} ** std.meta.fields(SkipReason).len,
    fail_reasons: [std.meta.fields(FailReason).len]usize = [_]usize{0} ** std.meta.fields(FailReason).len,

    fn countSkip(self: *Summary, reason: SkipReason) void {
        self.skipped += 1;
        self.skip_reasons[@intFromEnum(reason)] += 1;
    }

    fn countFail(self: *Summary, reason: FailReason) void {
        self.failed += 1;
        self.fail_reasons[@intFromEnum(reason)] += 1;
    }
};

fn runSlice(allocator: std.mem.Allocator, bytes: []const u8) !Summary {
    var parsed = try std.json.parseFromSlice(JsonValue, allocator, bytes, .{ .parse_numbers = false });
    defer parsed.deinit();

    var root = asObject(parsed.value) orelse return error.ExpectedObject;
    var summary = Summary{};
    var it = root.iterator();
    while (it.next()) |entry| {
        try runFixture(allocator, entry.value_ptr.*, .all, &summary);
    }
    return summary;
}

/// Runs one top-level blockchain fixture selected by its exact EEST id.
/// File discovery and selection belong to the caller.
pub fn runCase(
    allocator: std.mem.Allocator,
    fixture: std.json.Value,
) !Summary {
    var summary = Summary{};
    const fixture_object = asObject(fixture) orelse {
        summary.countFail(.malformed_fixture);
        return summary;
    };
    if (fixture_object.get("blocks") == null) {
        summary.countFail(.malformed_fixture);
        return summary;
    }
    try runFixture(allocator, fixture, .blocks_only, &summary);
    return summary;
}

const FixtureMode = enum { all, blocks_only };

fn runFixture(
    allocator: std.mem.Allocator,
    fixture: JsonValue,
    mode: FixtureMode,
    summary: *Summary,
) !void {
    const fixture_object = asObject(fixture) orelse {
        summary.countFail(.malformed_fixture);
        return;
    };
    const revision = fixtureRevision(&fixture_object) catch {
        summary.countSkip(.unsupported_fork);
        return;
    };
    const pre = asObject(fixture_object.get("pre") orelse {
        summary.countFail(.malformed_fixture);
        return;
    }) orelse {
        summary.countFail(.malformed_fixture);
        return;
    };
    const genesis_header = asObject(fixture_object.get("genesisBlockHeader") orelse {
        summary.countFail(.malformed_fixture);
        return;
    }) orelse {
        summary.countFail(.malformed_fixture);
        return;
    };

    var store = evmz.state.MemoryStore.init(allocator);
    defer store.deinit();
    seedMemoryStore(allocator, &store, &pre) catch {
        summary.countFail(.malformed_fixture);
        return;
    };

    const expected_pre_state_root = hashField(&genesis_header, "stateRoot") catch {
        summary.countFail(.malformed_fixture);
        return;
    };
    const actual_pre_state_root = store.stateRoot(allocator) catch {
        summary.countFail(.validation_error);
        return;
    };
    if (!std.mem.eql(u8, &expected_pre_state_root, &actual_pre_state_root)) {
        summary.countFail(.pre_state_root_mismatch);
        return;
    }

    var block_hashes = FixtureBlockHashes.init(allocator);
    defer block_hashes.deinit();
    var parent = parentFromGenesis(&genesis_header) catch {
        summary.countFail(.malformed_fixture);
        return;
    };
    block_hashes.put(parent.number, parent.hash) catch {
        summary.countFail(.validation_error);
        return;
    };

    if (mode == .all) {
        if (fixture_object.get("engineNewPayloads")) |payloads_value| {
            const payloads = asArray(payloads_value) orelse {
                summary.countFail(.malformed_fixture);
                return;
            };
            for (payloads.items) |entry_value| {
                try runBlockEntry(allocator, revision, .payload, &fixture_object, entry_value, summary, &store, &block_hashes, &parent);
            }
        }
    }

    if (mode == .all) {
        if (fixture_object.get("syncPayload")) |sync_value| {
            try runBlockEntry(allocator, revision, .payload, &fixture_object, sync_value, summary, &store, &block_hashes, &parent);
        }
    }

    // Regular `blockchain_tests` carry consensus blocks rather than engine
    // payloads. Without this the whole track fell through both branches above
    // and was counted nowhere, so a green run proved nothing at block level.
    if (fixture_object.get("blocks")) |blocks_value| {
        const blocks = asArray(blocks_value) orelse {
            summary.countFail(.malformed_fixture);
            return;
        };
        for (blocks.items) |entry_value| {
            try runBlockEntry(allocator, revision, .block_body, &fixture_object, entry_value, summary, &store, &block_hashes, &parent);
        }
    }
}

/// Which body shape a fixture presents one block in.
///
/// `engineNewPayloads` and `syncPayload` carry an engine execution payload with
/// its fields already decomposed. Regular `blockchain_tests` carry the consensus
/// block instead: a decomposed `blockHeader` beside the block's own RLP, which
/// is the only place the raw transactions exist.
const BlockSource = enum {
    payload,
    block_body,
};

fn runBlockEntry(
    allocator: std.mem.Allocator,
    revision: evmz.eth.Revision,
    source: BlockSource,
    fixture: *const JsonObject,
    entry_value: JsonValue,
    summary: *Summary,
    store: *evmz.state.MemoryStore,
    block_hashes: *FixtureBlockHashes,
    parent: *ParentContext,
) !void {
    const entry = asObject(entry_value) orelse {
        summary.countFail(.malformed_fixture);
        return;
    };
    if (entry.get("errorCode") != null or entry.get("validationError") != null) {
        summary.countSkip(.expected_exception);
        return;
    }
    const expected_exception = if (entry.get("expectException")) |value|
        jsonString(value) orelse {
            summary.countFail(.malformed_fixture);
            return;
        }
    else
        null;
    if (expected_exception != null and source != .block_body) {
        summary.countSkip(.expected_exception);
        return;
    }

    summary.fixtures += 1;
    if (expected_exception) |expected| {
        const serialized_match = blockBodySerializedExceptionMatches(allocator, &entry, expected) catch {
            summary.countFail(.malformed_fixture);
            return;
        };
        if (serialized_match) {
            summary.passed += 1;
            return;
        }
    }
    const result = runBlock(
        allocator,
        revision,
        source,
        fixture,
        &entry,
        store,
        block_hashes,
        parent,
        null,
    ) catch |err| {
        if (expected_exception) |expected| {
            if (expectedAdapterErrorMatches(err, expected)) {
                summary.passed += 1;
                return;
            }
        }
        if (err == error.ParentHashMismatch) {
            summary.countFail(.parent_hash_mismatch);
            return;
        }
        if (err == error.BlockNumberMismatch) {
            summary.countFail(.block_number_mismatch);
            return;
        }
        if (err == error.UnsupportedTransactionType) {
            summary.countSkip(.unsupported_transaction_type);
            return;
        }
        if (err == error.UnsupportedPayloadShape) {
            summary.countSkip(.unsupported_payload_shape);
            return;
        }
        if (err == error.BlobVersionedHashesMismatch) {
            summary.countFail(.blob_versioned_hashes_mismatch);
            return;
        }
        summary.countFail(if (err == error.MalformedFixture) .malformed_fixture else .validation_error);
        return;
    };
    if (expected_exception) |expected| {
        if (expectedExceptionMatches(result, expected)) {
            summary.passed += 1;
        } else {
            summary.countFail(.expected_exception_mismatch);
        }
        return;
    }
    if (result.status != .valid) {
        summary.countFail(.unexpected_status);
        return;
    }
    summary.passed += 1;
}

fn expectedExceptionMatches(result: block_stf.Result, expected: []const u8) bool {
    if (result.status == .transaction_rejected) {
        const rejection = result.transaction_rejection orelse return false;
        return tx_validation.validationErrorMatchesEest(rejection, expected);
    }
    if (result.status == .blob_gas_limit_exceeded and tx_validation.exceptionNameMatches(
        "TransactionException.TYPE_3_TX_MAX_BLOB_GAS_ALLOWANCE_EXCEEDED",
        expected,
    )) return true;
    if (result.status == .block_gas_exceeded and tx_validation.exceptionNameMatches(
        "TransactionException.GAS_ALLOWANCE_EXCEEDED",
        expected,
    )) return true;
    if (result.status == .malformed_block_access_list and tx_validation.exceptionNameMatches(
        "BlockException.INVALID_BLOCK_ACCESS_LIST",
        expected,
    )) return true;
    const name = switch (result.status) {
        .invalid_block_body => "BlockException.INCORRECT_BLOCK_FORMAT",
        .header_surface_mismatch => "BlockException.INCORRECT_BLOCK_FORMAT",
        .invalid_deposit_event_layout => "BlockException.INVALID_DEPOSIT_EVENT_LAYOUT",
        .invalid_requests, .requests_hash_mismatch => "BlockException.INVALID_REQUESTS",
        .system_contract_failed => "BlockException.SYSTEM_CONTRACT_CALL_FAILED",
        .block_gas_exceeded => "BlockException.GAS_USED_OVERFLOW",
        .blob_gas_limit_exceeded => "BlockException.BLOB_GAS_USED_ABOVE_LIMIT",
        .parent_hash_mismatch, .parent_header_mismatch => "BlockException.UNKNOWN_PARENT",
        .block_number_mismatch => "BlockException.INVALID_BLOCK_NUMBER",
        .timestamp_mismatch => "BlockException.INVALID_BLOCK_TIMESTAMP_OLDER_THAN_PARENT",
        .gas_limit_mismatch => "BlockException.INVALID_GASLIMIT",
        .base_fee_mismatch => "BlockException.INVALID_BASEFEE_PER_GAS",
        .malformed_block_access_list => "BlockException.INCORRECT_BLOCK_FORMAT",
        .invalid_block_access_list, .block_access_list_mismatch => "BlockException.INVALID_BLOCK_ACCESS_LIST",
        .block_access_list_too_large => "BlockException.BLOCK_ACCESS_LIST_GAS_LIMIT_EXCEEDED",
        .state_root_mismatch => "BlockException.INVALID_STATE_ROOT",
        .transactions_root_mismatch => "BlockException.INVALID_TRANSACTIONS_ROOT",
        .receipts_root_mismatch => "BlockException.INVALID_RECEIPTS_ROOT",
        .withdrawals_root_mismatch => "BlockException.INVALID_WITHDRAWALS_ROOT",
        .gas_used_mismatch, .block_gas_used_mismatch, .block_state_gas_used_mismatch => "BlockException.INVALID_GAS_USED",
        .logs_bloom_mismatch => "BlockException.INVALID_LOG_BLOOM",
        .blob_gas_used_mismatch => "BlockException.INCORRECT_BLOB_GAS_USED",
        .excess_blob_gas_mismatch => "BlockException.INCORRECT_EXCESS_BLOB_GAS",
        .block_access_list_hash_mismatch => "BlockException.INVALID_BAL_HASH",
        .block_hash_mismatch => "BlockException.INVALID_BLOCK_HASH",
        .valid, .invalid_witness, .transaction_rejected => return false,
    };
    return tx_validation.exceptionNameMatches(name, expected);
}

fn expectedAdapterErrorMatches(err: anyerror, expected: []const u8) bool {
    const name = switch (err) {
        error.BlobGasOverflow => "BlockException.INCORRECT_EXCESS_BLOB_GAS",
        error.ExtraDataTooLong => "BlockException.EXTRA_DATA_TOO_BIG",
        error.HeaderSurfaceMismatch => "BlockException.INCORRECT_BLOCK_FORMAT",
        error.InputTooShort => "BlockException.RLP_STRUCTURES_ENCODING",
        else => return false,
    };
    return tx_validation.exceptionNameMatches(name, expected);
}

fn blockBodySerializedExceptionMatches(
    allocator: std.mem.Allocator,
    entry: *const JsonObject,
    expected: []const u8,
) !bool {
    const signature_expected = tx_validation.exceptionNameMatches("TransactionException.INVALID_SIGNATURE_VRS", expected);
    const size_expected = tx_validation.exceptionNameMatches("BlockException.RLP_BLOCK_LIMIT_EXCEEDED", expected);
    if (!signature_expected and !size_expected) return false;

    const block_rlp = try parseBytesFromValue(allocator, entry.get("rlp") orelse return error.MalformedFixture);
    defer allocator.free(block_rlp);
    if (blockRlpSizeExceptionMatches(block_rlp.len, expected)) return true;
    if (!signature_expected) return false;

    var block_cursor = evmz.rlp.Cursor.init(block_rlp);
    var body = try block_cursor.nextList();
    try block_cursor.expectDone();
    _ = try body.next();
    var transactions = try body.nextList();
    while (!transactions.isDone()) {
        const item = try transactions.next();
        const raw = switch (item.kind()) {
            .list => item.encoded(),
            .bytes => try item.asBytes(),
        };
        if (tx_validation.serializedSignatureExceptionMatches(allocator, raw, expected)) return true;
    }
    return false;
}

fn blockRlpSizeExceptionMatches(encoded_len: usize, expected: []const u8) bool {
    const max_block_rlp_size = 1 << 23;
    return encoded_len > max_block_rlp_size and
        tx_validation.exceptionNameMatches("BlockException.RLP_BLOCK_LIMIT_EXCEEDED", expected);
}

fn runBlock(
    allocator: std.mem.Allocator,
    revision: evmz.eth.Revision,
    source: BlockSource,
    fixture: *const JsonObject,
    entry: *const JsonObject,
    store: *evmz.state.MemoryStore,
    block_hashes: *FixtureBlockHashes,
    parent: *ParentContext,
    bal_report: ?*block_stf.BalDifferentialReport,
) !block_stf.Result {
    return switch (revision) {
        inline else => |exact_revision| switch (source) {
            .payload => runPayloadExact(
                exact_revision,
                allocator,
                fixture,
                entry,
                store,
                block_hashes,
                parent,
                bal_report,
            ),
            .block_body => runBlockBodyExact(
                exact_revision,
                allocator,
                fixture,
                entry,
                store,
                block_hashes,
                parent,
                bal_report,
            ),
        },
    };
}

fn runPayloadExact(
    comptime revision: evmz.eth.Revision,
    allocator: std.mem.Allocator,
    fixture: *const JsonObject,
    entry: *const JsonObject,
    store: *evmz.state.MemoryStore,
    block_hashes: *FixtureBlockHashes,
    parent: *ParentContext,
    bal_report: ?*block_stf.BalDifferentialReport,
) !block_stf.Result {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();

    const params = asArray(entry.get("params") orelse return error.MalformedFixture) orelse return error.MalformedFixture;
    if (params.items.len == 0) return error.UnsupportedPayloadShape;
    const payload = asObject(params.items[0]) orelse return error.MalformedFixture;
    const payload_parent_hash = try hashField(&payload, "parentHash");
    if (!std.mem.eql(u8, &payload_parent_hash, &parent.hash)) return error.ParentHashMismatch;
    const payload_number = try u64Field(&payload, "blockNumber");
    try validateChildNumber(parent.number, payload_number);

    const fixture_config = try parseFixtureConfig(fixture, revision, fixture_common.fixtureForkName(fixture));
    var decoded_transactions = try parseTransactions(scratch, asArray(payload.get("transactions") orelse return error.MalformedFixture) orelse return error.MalformedFixture);
    defer decoded_transactions.deinit(scratch);
    try validateBlobVersionedHashes(revision, params, decoded_transactions.transactions);
    const withdrawals = if (revision.isImpl(.shanghai))
        try parseWithdrawals(scratch, asArray(payload.get("withdrawals") orelse return error.MalformedFixture) orelse return error.MalformedFixture)
    else
        &.{};
    const block_access_list = if (payload.get("blockAccessList")) |value|
        try parseBytesFromValue(scratch, value)
    else
        null;
    const requests_hash = try requestClaimsHash(scratch, revision, params);
    const excess_blob_gas = try optionalU256Field(&payload, "excessBlobGas");

    const block_header = block_stf.BlockHeader{
        .number = payload_number,
        .timestamp = try u64Field(&payload, "timestamp"),
        .parent_hash = payload_parent_hash,
        .parent_beacon_block_root = try parentBeaconBlockRoot(params),
    };

    const block_hash_source = block_hashes.source();
    const result = try block_stf.Exact(revision).applyAssumeDecoded(scratch, .{
        .env = .{
            .chain_id = fixture_config.chain_id,
            .coinbase = try addressField(&payload, "feeRecipient"),
            .number = payload_number,
            .slot_number = try optionalU64Field(&payload, "slotNumber") orelse 0,
            .timestamp = try u64Field(&payload, "timestamp"),
            .gas_limit = try u64Field(&payload, "gasLimit"),
            .prev_randao = try u256HashField(&payload, "prevRandao"),
            .base_fee = try optionalU256Field(&payload, "baseFeePerGas") orelse 0,
            .blob_base_fee = fixture_common.blobBaseFee(
                revision,
                fixture_config.blob_params,
                excess_blob_gas orelse 0,
            ) orelse return error.BlobGasOverflow,
            .blob_params = fixture_config.blob_params,
        },
        .block_hash_source = block_hash_source,
        .block_header = block_header,
        .state_backend = .fromMemoryStore(store),
        .transactions = decoded_transactions.transactions,
        .withdrawals = withdrawals,
        .parent_header = parent.headerContext(),
        .block_access_list = block_access_list,
        .root_checks = .{
            .payload_header = .{
                .state = try hashField(&payload, "stateRoot"),
                .receipts = try hashField(&payload, "receiptsRoot"),
            },
        },
        .header_claims = .{
            .gas_used = if (revision.isImpl(.amsterdam)) null else try optionalU64Field(&payload, "gasUsed"),
            .block_gas_used = if (revision.isImpl(.amsterdam)) try optionalU64Field(&payload, "gasUsed") else null,
            .logs_bloom = try bloomField(scratch, &payload, "logsBloom"),
            .blob_gas_used = try optionalU64Field(&payload, "blobGasUsed"),
            .excess_blob_gas = excess_blob_gas,
            .requests_hash = requests_hash,
        },
        .header_hash_claim = if (revision.isImpl(.merge)) .{
            .block_hash = try hashField(&payload, "blockHash"),
            .parent_hash = payload_parent_hash,
            .parent_beacon_block_root = block_header.parent_beacon_block_root,
            .extra_data = try parseBytesFromValue(scratch, payload.get("extraData") orelse return error.MalformedFixture),
        } else null,
        .bal_differential = bal_report,
    });

    if (result.status == .valid) {
        parent.* = try parentFromPayload(&payload);
        parent.hash = result.block_hash;
        try block_hashes.put(parent.number, parent.hash);
    }

    return result;
}

/// Run one consensus block from a regular `blockchain_tests` fixture.
///
/// The raw block RLP is the authority for the header, transactions, and
/// withdrawals. This also lets invalid-block fixtures omit their convenience
/// `blockHeader` projection without changing the execution path.
fn runBlockBodyExact(
    comptime revision: evmz.eth.Revision,
    allocator: std.mem.Allocator,
    fixture: *const JsonObject,
    entry: *const JsonObject,
    store: *evmz.state.MemoryStore,
    block_hashes: *FixtureBlockHashes,
    parent: *ParentContext,
    bal_report: ?*block_stf.BalDifferentialReport,
) !block_stf.Result {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();

    const block_rlp = try parseBytesFromValue(scratch, entry.get("rlp") orelse return error.MalformedFixture);
    var body = try parseBlockBody(revision, scratch, block_rlp);
    defer body.deinit(scratch);
    const header = &body.header;
    if (!std.mem.eql(u8, &header.parent_hash, &parent.hash)) return error.ParentHashMismatch;
    try validateChildNumber(parent.number, header.number);

    const fixture_config = try parseFixtureConfig(fixture, revision, fixture_common.fixtureForkName(fixture));
    const block_access_list = if (revision.isImpl(.amsterdam)) blk: {
        if (entry.get("blockAccessList") != null) break :blk try bal_fixture.encodeClaim(scratch, entry);
        if (entry.get("rlp_decoded")) |value| {
            const decoded = asObject(value) orelse return error.MalformedFixture;
            if (decoded.get("blockAccessList") != null) break :blk try bal_fixture.encodeClaim(scratch, &decoded);
        }
        break :blk null;
    } else null;
    const excess_blob_gas: ?u256 = if (header.excess_blob_gas) |value| value else null;

    const block_header = block_stf.BlockHeader{
        .number = header.number,
        .timestamp = header.timestamp,
        .parent_hash = header.parent_hash,
        .parent_beacon_block_root = header.parent_beacon_block_root,
    };

    const block_hash_source = block_hashes.source();
    const result = try block_stf.Exact(revision).applyAssumeDecoded(scratch, .{
        .env = .{
            .chain_id = fixture_config.chain_id,
            .coinbase = header.coinbase,
            .number = header.number,
            .slot_number = header.slot_number orelse 0,
            .timestamp = header.timestamp,
            .gas_limit = header.gas_limit,
            .prev_randao = std.mem.readInt(u256, &header.prev_randao, .big),
            .base_fee = header.base_fee_per_gas orelse 0,
            .blob_base_fee = fixture_common.blobBaseFee(
                revision,
                fixture_config.blob_params,
                excess_blob_gas orelse 0,
            ) orelse return error.BlobGasOverflow,
            .blob_params = fixture_config.blob_params,
        },
        .block_hash_source = block_hash_source,
        .block_header = block_header,
        .state_backend = .fromMemoryStore(store),
        .transactions = body.transactions.transactions,
        .withdrawals = body.withdrawals,
        .parent_header = parent.headerContext(),
        .block_access_list = block_access_list,
        .root_checks = .{
            .payload_header = .{
                .state = header.state_root,
                .receipts = header.receipts_root,
            },
            .reconstructed_header = .{
                .transactions = header.transactions_root,
                .withdrawals = header.withdrawals_root,
            },
        },
        .header_claims = .{
            .gas_used = if (revision.isImpl(.amsterdam)) null else header.gas_used,
            .block_gas_used = if (revision.isImpl(.amsterdam)) header.gas_used else null,
            .logs_bloom = header.logs_bloom,
            .blob_gas_used = header.blob_gas_used,
            .excess_blob_gas = excess_blob_gas,
            .requests_hash = header.requests_hash,
            .block_access_list_hash = header.block_access_list_hash,
        },
        .header_hash_claim = if (revision.isImpl(.merge)) .{
            .block_hash = body.header_hash,
            .parent_hash = header.parent_hash,
            .parent_beacon_block_root = header.parent_beacon_block_root,
            .extra_data = header.extra_data,
        } else null,
        .bal_differential = bal_report,
    });

    if (result.status == .valid) {
        parent.* = parentFromExecutionHeader(header.*, body.header_hash);
        try block_hashes.put(parent.number, parent.hash);
    }

    return result;
}

const ParsedBlockBody = struct {
    header: evmz.eth.ExecutionHeader,
    header_hash: [32]u8,
    transactions: evmz.transaction.raw.DecodedBatch,
    withdrawals: []const evmz.eth.Withdrawal,

    fn deinit(self: *ParsedBlockBody, allocator: std.mem.Allocator) void {
        self.transactions.deinit(allocator);
        allocator.free(self.withdrawals);
        self.* = undefined;
    }
};

/// Parse one canonical consensus block `[header, transactions, ommers, ...]`.
/// Legacy transactions retain their list encoding; typed transactions retain
/// the byte-string payload `type || transaction_payload`.
fn parseBlockBody(
    comptime revision: evmz.eth.Revision,
    allocator: std.mem.Allocator,
    block_rlp: []const u8,
) !ParsedBlockBody {
    var block_cursor = evmz.rlp.Cursor.init(block_rlp);
    var body = try block_cursor.nextList();
    try block_cursor.expectDone();

    const header_item = try body.next();
    const header = try parseExecutionHeader(revision, header_item);
    const header_hash = evmz.crypto.keccak256(header_item.encoded());
    const canonical_hash = try header.hash(allocator, revision);
    if (!std.mem.eql(u8, &header_hash, &canonical_hash)) return error.MalformedFixture;

    var transactions_list = try body.nextList();

    var out: std.ArrayList([]const u8) = .empty;
    errdefer out.deinit(allocator);
    while (!transactions_list.isDone()) {
        const item = try transactions_list.next();
        const raw = switch (item.kind()) {
            .list => item.encoded(),
            .bytes => try item.asBytes(),
        };
        try out.append(allocator, raw);
    }
    const raw_transactions = try out.toOwnedSlice(allocator);
    defer allocator.free(raw_transactions);
    var decoded_transactions = try evmz.transaction.raw.decodeRawBatch(allocator, raw_transactions);
    errdefer decoded_transactions.deinit(allocator);

    var ommers = try body.nextList();
    try ommers.expectDone();
    const withdrawals = if (revision.isImpl(.shanghai))
        try parseBlockBodyWithdrawals(allocator, &body)
    else
        &.{};
    errdefer if (revision.isImpl(.shanghai)) allocator.free(withdrawals);
    try body.expectDone();

    return .{
        .header = header,
        .header_hash = header_hash,
        .transactions = decoded_transactions,
        .withdrawals = withdrawals,
    };
}

fn parseExecutionHeader(
    comptime revision: evmz.eth.Revision,
    item: evmz.rlp.Item,
) !evmz.eth.ExecutionHeader {
    var fields = try item.listCursor();
    const header = evmz.eth.ExecutionHeader{
        .parent_hash = try nextFixed(&fields, 32),
        .ommers_hash = try nextFixed(&fields, 32),
        .coinbase = .fromBytes(try nextFixed(&fields, 20)),
        .state_root = try nextFixed(&fields, 32),
        .transactions_root = try nextFixed(&fields, 32),
        .receipts_root = try nextFixed(&fields, 32),
        .logs_bloom = try nextFixed(&fields, 256),
        .difficulty = try fields.nextInt(u256),
        .number = try fields.nextInt(u64),
        .gas_limit = try fields.nextInt(u64),
        .gas_used = try fields.nextInt(u64),
        .timestamp = try fields.nextInt(u64),
        .extra_data = try fields.nextBytes(),
        .prev_randao = try nextFixed(&fields, 32),
        .nonce = try nextFixed(&fields, 8),
        .base_fee_per_gas = if (revision.isImpl(.london)) try fields.nextInt(u256) else null,
        .withdrawals_root = if (revision.isImpl(.shanghai)) try nextFixed(&fields, 32) else null,
        .blob_gas_used = if (revision.isImpl(.cancun)) try fields.nextInt(u64) else null,
        .excess_blob_gas = if (revision.isImpl(.cancun)) try fields.nextInt(u64) else null,
        .parent_beacon_block_root = if (revision.isImpl(.cancun)) try nextFixed(&fields, 32) else null,
        .requests_hash = if (revision.isImpl(.prague)) try nextFixed(&fields, 32) else null,
        .block_access_list_hash = if (revision.isImpl(.amsterdam)) try nextFixed(&fields, 32) else null,
        .slot_number = if (revision.isImpl(.amsterdam)) try fields.nextInt(u64) else null,
    };
    try fields.expectDone();
    try header.validate(revision);
    return header;
}

fn nextFixed(cursor: *evmz.rlp.Cursor, comptime len: usize) ![len]u8 {
    const bytes = try cursor.nextBytesExact(len);
    return bytes[0..len].*;
}

fn parseBlockBodyWithdrawals(
    allocator: std.mem.Allocator,
    body: *evmz.rlp.Cursor,
) ![]const evmz.eth.Withdrawal {
    var list = try body.nextList();
    var out: std.ArrayList(evmz.eth.Withdrawal) = .empty;
    errdefer out.deinit(allocator);
    while (!list.isDone()) {
        var fields = try list.nextList();
        try out.append(allocator, .{
            .index = try fields.nextInt(u64),
            .validator_index = try fields.nextInt(u64),
            .address = .fromBytes(try nextFixed(&fields, 20)),
            .amount = try fields.nextInt(u64),
        });
        try fields.expectDone();
    }
    return out.toOwnedSlice(allocator);
}

fn parentFromExecutionHeader(header: evmz.eth.ExecutionHeader, hash: [32]u8) ParentContext {
    return .{
        .number = header.number,
        .hash = hash,
        .timestamp = header.timestamp,
        .gas_limit = header.gas_limit,
        .gas_used = header.gas_used,
        .excess_blob_gas = header.excess_blob_gas orelse 0,
        .blob_gas_used = header.blob_gas_used orelse 0,
        .base_fee_per_gas = header.base_fee_per_gas orelse 0,
    };
}

const ParentContext = struct {
    number: u64,
    hash: [32]u8,
    timestamp: u64,
    gas_limit: u64,
    gas_used: u64,
    excess_blob_gas: u64 = 0,
    blob_gas_used: u64 = 0,
    base_fee_per_gas: u256 = 0,

    fn headerContext(self: ParentContext) block_stf.ParentHeaderContext {
        return .{
            .hash = self.hash,
            .number = self.number,
            .timestamp = self.timestamp,
            .gas_limit = self.gas_limit,
            .gas_used = self.gas_used,
            .base_fee_per_gas = self.base_fee_per_gas,
            .blob_gas_used = self.blob_gas_used,
            .excess_blob_gas = self.excess_blob_gas,
        };
    }
};

fn validateChildNumber(parent_number: u64, child_number: u64) !void {
    const expected = std.math.add(u64, parent_number, 1) catch return error.BlockNumberMismatch;
    if (child_number != expected) return error.BlockNumberMismatch;
}

fn parentFromGenesis(header: *const JsonObject) !ParentContext {
    return .{
        .number = try u64Field(header, "number"),
        .hash = try hashField(header, "hash"),
        .timestamp = try u64Field(header, "timestamp"),
        .gas_limit = try u64Field(header, "gasLimit"),
        .gas_used = try u64Field(header, "gasUsed"),
        .excess_blob_gas = try optionalU64Field(header, "excessBlobGas") orelse 0,
        .blob_gas_used = try optionalU64Field(header, "blobGasUsed") orelse 0,
        .base_fee_per_gas = try optionalU256Field(header, "baseFeePerGas") orelse 0,
    };
}

fn parentFromPayload(payload: *const JsonObject) !ParentContext {
    return .{
        .number = try u64Field(payload, "blockNumber"),
        .hash = try hashField(payload, "blockHash"),
        .timestamp = try u64Field(payload, "timestamp"),
        .gas_limit = try u64Field(payload, "gasLimit"),
        .gas_used = try u64Field(payload, "gasUsed"),
        .excess_blob_gas = try optionalU64Field(payload, "excessBlobGas") orelse 0,
        .blob_gas_used = try optionalU64Field(payload, "blobGasUsed") orelse 0,
        .base_fee_per_gas = try optionalU256Field(payload, "baseFeePerGas") orelse 0,
    };
}

const FixtureBlockHashes = struct {
    allocator: std.mem.Allocator,
    entries: std.ArrayList(Entry),

    const Entry = struct {
        number: u64,
        hash: [32]u8,
    };

    fn init(allocator: std.mem.Allocator) FixtureBlockHashes {
        return .{
            .allocator = allocator,
            .entries = .empty,
        };
    }

    fn deinit(self: *FixtureBlockHashes) void {
        self.entries.deinit(self.allocator);
    }

    fn put(self: *FixtureBlockHashes, number: u64, hash: [32]u8) !void {
        for (self.entries.items) |*entry| {
            if (entry.number == number) {
                entry.hash = hash;
                return;
            }
        }
        try self.entries.append(self.allocator, .{ .number = number, .hash = hash });
    }

    fn source(self: *FixtureBlockHashes) evmz.BlockHashSource {
        return .{ .ptr = self, .vtable = &.{
            .getBlockHash = getBlockHash,
        } };
    }

    fn getBlockHash(ptr: *anyopaque, number: u64) !?u256 {
        const self: *FixtureBlockHashes = @ptrCast(@alignCast(ptr));
        for (self.entries.items) |entry| {
            if (entry.number == number) return evmz.uint256.fromBytes32(&entry.hash);
        }
        return null;
    }
};

fn fixtureRevision(fixture: *const JsonObject) !evmz.eth.Revision {
    const network = fixture_common.fixtureForkName(fixture) orelse return error.MalformedFixture;
    const revision = parseStateFork(network) orelse return error.UnsupportedFork;
    if (!revision.isImpl(.merge)) return error.UnsupportedFork;
    return revision;
}

fn parseTransactions(allocator: std.mem.Allocator, array: JsonArray) !evmz.transaction.raw.DecodedBatch {
    const raw_transactions = try allocator.alloc([]const u8, array.items.len);
    for (raw_transactions, array.items) |*raw, value| {
        raw.* = try parseBytesFromValue(allocator, value);
    }
    return evmz.transaction.raw.decodeRawBatch(allocator, raw_transactions);
}

fn parseWithdrawals(allocator: std.mem.Allocator, array: JsonArray) ![]const evmz.eth.Withdrawal {
    const out = try allocator.alloc(evmz.eth.Withdrawal, array.items.len);
    for (out, array.items) |*target, value| {
        const object = asObject(value) orelse return error.MalformedFixture;
        target.* = .{
            .index = try u64Field(&object, "index"),
            .validator_index = try u64FieldAny(&object, &.{ "validatorIndex", "validator_index" }),
            .address = try addressField(&object, "address"),
            .amount = try u64Field(&object, "amount"),
        };
    }
    return out;
}

fn validateBlobVersionedHashes(
    revision: evmz.eth.Revision,
    params: JsonArray,
    transactions: []const block_stf.TransactionInput,
) !void {
    if (!revision.isImpl(.cancun)) return;
    if (params.items.len < 2) return error.UnsupportedPayloadShape;
    const expected = asArray(params.items[1]) orelse return error.MalformedFixture;

    var expected_index: usize = 0;
    for (transactions) |entry| {
        for (entry.tx.blob_hashes) |actual| {
            if (expected_index >= expected.items.len) return error.BlobVersionedHashesMismatch;
            const expected_hash = try parseHashFromValue(expected.items[expected_index]);
            if (actual != std.mem.readInt(u256, &expected_hash, .big)) return error.BlobVersionedHashesMismatch;
            expected_index += 1;
        }
    }
    if (expected_index != expected.items.len) return error.BlobVersionedHashesMismatch;
}

fn requestClaimsHash(allocator: std.mem.Allocator, revision: evmz.eth.Revision, params: JsonArray) !?[32]u8 {
    if (!revision.isImpl(.prague)) return null;
    if (params.items.len < 4) return error.UnsupportedPayloadShape;
    const requests = asArray(params.items[3]) orelse return error.MalformedFixture;
    const request_bytes = try parseByteList(allocator, requests);
    return try block_stf.requestsHash(allocator, request_bytes);
}

fn parseByteList(allocator: std.mem.Allocator, array: JsonArray) ![]const []const u8 {
    const out = try allocator.alloc([]const u8, array.items.len);
    for (out, array.items) |*target, value| {
        target.* = try parseBytesFromValue(allocator, value);
    }
    return out;
}

fn parentBeaconBlockRoot(params: JsonArray) !?[32]u8 {
    if (params.items.len < 3) return null;
    return try parseHashFromValue(params.items[2]);
}

fn fieldAny(object: *const JsonObject, keys: []const []const u8) !JsonValue {
    for (keys) |key| {
        if (object.get(key)) |value| return value;
    }
    return error.MalformedFixture;
}

fn u64Field(object: *const JsonObject, key: []const u8) !u64 {
    return try parseU64FromValue(object.get(key) orelse return error.MalformedFixture);
}

fn u64FieldAny(object: *const JsonObject, keys: []const []const u8) !u64 {
    return try parseU64FromValue(try fieldAny(object, keys));
}

fn optionalU64Field(object: *const JsonObject, key: []const u8) !?u64 {
    const value = object.get(key) orelse return null;
    return try parseU64FromValue(value);
}

fn optionalU256Field(object: *const JsonObject, key: []const u8) !?u256 {
    const value = object.get(key) orelse return null;
    return try parseU256FromValue(value);
}

fn addressField(object: *const JsonObject, key: []const u8) !evmz.Address {
    return try parseAddressFromValue(object.get(key) orelse return error.MalformedFixture);
}

fn hashField(object: *const JsonObject, key: []const u8) ![32]u8 {
    return try parseHashFromValue(object.get(key) orelse return error.MalformedFixture);
}

fn u256HashField(object: *const JsonObject, key: []const u8) !u256 {
    const hash = try hashField(object, key);
    return std.mem.readInt(u256, &hash, .big);
}

fn bloomField(allocator: std.mem.Allocator, object: *const JsonObject, key: []const u8) ![256]u8 {
    const bytes = try parseBytesFromValue(allocator, object.get(key) orelse return error.MalformedFixture);
    if (bytes.len != 256) return error.MalformedFixture;
    var out: [256]u8 = undefined;
    @memcpy(&out, bytes);
    return out;
}

test "regular BlockSTF EEST runner skips pre-Merge engine payloads" {
    var zero_bloom: [514]u8 = undefined;
    @memcpy(zero_bloom[0..2], "0x");
    @memset(zero_bloom[2..], '0');

    const template =
        \\{
        \\  "empty-frontier": {
        \\    "network": "Frontier",
        \\    "config": {"chainid": "0x1"},
        \\    "pre": {},
        \\    "genesisBlockHeader": {
        \\      "number": "0x0",
        \\      "hash": "0x1111111111111111111111111111111111111111111111111111111111111111",
        \\      "stateRoot": "0x56e81f171bcc55a6ff8345e692c0f86e5b48e01b996cadc001622fb5e363b421"
        \\    },
        \\    "engineNewPayloads": [{
        \\      "params": [{
        \\        "parentHash": "0x1111111111111111111111111111111111111111111111111111111111111111",
        \\        "feeRecipient": "0x0000000000000000000000000000000000000000",
        \\        "stateRoot": "0x56e81f171bcc55a6ff8345e692c0f86e5b48e01b996cadc001622fb5e363b421",
        \\        "receiptsRoot": "0x56e81f171bcc55a6ff8345e692c0f86e5b48e01b996cadc001622fb5e363b421",
        \\        "logsBloom": "$BLOOM",
        \\        "blockNumber": "0x1",
        \\        "gasLimit": "0x100000",
        \\        "gasUsed": "0x0",
        \\        "timestamp": "0x1",
        \\        "prevRandao": "0x0000000000000000000000000000000000000000000000000000000000000000",
        \\        "baseFeePerGas": "0x0",
        \\        "blockHash": "0x2222222222222222222222222222222222222222222222222222222222222222",
        \\        "transactions": []
        \\      }]
        \\    }]
        \\  }
        \\}
    ;
    const fixture = try std.mem.replaceOwned(u8, std.testing.allocator, template, "$BLOOM", &zero_bloom);
    defer std.testing.allocator.free(fixture);

    const summary = try runSlice(std.testing.allocator, fixture);
    try std.testing.expectEqual(@as(usize, 0), summary.fixtures);
    try std.testing.expectEqual(@as(usize, 0), summary.passed);
    try std.testing.expectEqual(@as(usize, 0), summary.failed);
    try std.testing.expectEqual(@as(usize, 1), summary.skipped);
}

test "direct blockchain case does not consume Engine fixture shapes" {
    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        "{\"engineNewPayloads\":[]}",
        .{},
    );
    defer parsed.deinit();

    const summary = try runCase(std.testing.allocator, parsed.value);
    try std.testing.expectEqual(@as(usize, 0), summary.fixtures);
    try std.testing.expectEqual(@as(usize, 1), summary.failed);
    try std.testing.expectEqual(@as(usize, 1), summary.fail_reasons[@intFromEnum(FailReason.malformed_fixture)]);
}

test "regular block header parser round trips the Amsterdam RLP surface" {
    const header = evmz.eth.ExecutionHeader{
        .parent_hash = [_]u8{0x11} ** 32,
        .coinbase = .zero,
        .state_root = [_]u8{0x22} ** 32,
        .transactions_root = [_]u8{0x33} ** 32,
        .receipts_root = [_]u8{0x44} ** 32,
        .logs_bloom = [_]u8{0x55} ** 256,
        .number = 1,
        .gas_limit = 30_000_000,
        .gas_used = 21_000,
        .timestamp = 1_000,
        .extra_data = &.{0xaa},
        .prev_randao = [_]u8{0x66} ** 32,
        .base_fee_per_gas = 7,
        .withdrawals_root = [_]u8{0x77} ** 32,
        .blob_gas_used = 0,
        .excess_blob_gas = 0,
        .parent_beacon_block_root = [_]u8{0x88} ** 32,
        .requests_hash = [_]u8{0x99} ** 32,
        .block_access_list_hash = [_]u8{0xaa} ** 32,
        .slot_number = 3,
    };
    const encoded = try header.encodeAlloc(std.testing.allocator, .amsterdam);
    defer std.testing.allocator.free(encoded);

    const parsed = try parseExecutionHeader(.amsterdam, try evmz.rlp.parseExact(encoded));
    try std.testing.expectEqualDeep(header, parsed);
}

test "expected block exception requires the matching typed status" {
    try std.testing.expect(expectedExceptionMatches(.{
        .status = .transaction_rejected,
        .transaction_rejection = .initcode_size_exceeded,
    }, "TransactionException.INITCODE_SIZE_EXCEEDED"));
    try std.testing.expect(!expectedExceptionMatches(.{
        .status = .transaction_rejected,
        .transaction_rejection = .nonce_too_high,
    }, "TransactionException.INITCODE_SIZE_EXCEEDED"));
    try std.testing.expect(expectedExceptionMatches(.{
        .status = .gas_limit_mismatch,
    }, "BlockException.INVALID_GASLIMIT"));
    try std.testing.expect(expectedExceptionMatches(.{
        .status = .excess_blob_gas_mismatch,
    }, "BlockException.INCORRECT_EXCESS_BLOB_GAS"));
    try std.testing.expect(expectedExceptionMatches(.{
        .status = .invalid_deposit_event_layout,
    }, "BlockException.INVALID_DEPOSIT_EVENT_LAYOUT"));
    try std.testing.expect(expectedExceptionMatches(.{
        .status = .malformed_block_access_list,
    }, "BlockException.INCORRECT_BLOCK_FORMAT"));
    try std.testing.expect(expectedExceptionMatches(.{
        .status = .malformed_block_access_list,
    }, "BlockException.INVALID_BLOCK_ACCESS_LIST"));
    try std.testing.expect(expectedExceptionMatches(.{
        .status = .block_access_list_mismatch,
    }, "BlockException.INVALID_BLOCK_ACCESS_LIST"));
    try std.testing.expect(expectedExceptionMatches(.{
        .status = .blob_gas_limit_exceeded,
    }, "TransactionException.TYPE_3_TX_MAX_BLOB_GAS_ALLOWANCE_EXCEEDED|TransactionException.TYPE_3_TX_BLOB_COUNT_EXCEEDED"));
    try std.testing.expect(expectedExceptionMatches(.{
        .status = .block_gas_exceeded,
    }, "TransactionException.GAS_ALLOWANCE_EXCEEDED"));
    try std.testing.expect(!expectedExceptionMatches(.{
        .status = .blob_gas_limit_exceeded,
    }, "TransactionException.TYPE_3_TX_BLOB_COUNT_EXCEEDED"));
    try std.testing.expect(!expectedExceptionMatches(.{
        .status = .valid,
    }, "TransactionException.INITCODE_SIZE_EXCEEDED"));
    try std.testing.expect(expectedAdapterErrorMatches(
        error.BlobGasOverflow,
        "BlockException.INCORRECT_EXCESS_BLOB_GAS",
    ));
    try std.testing.expect(expectedAdapterErrorMatches(
        error.InputTooShort,
        "BlockException.RLP_STRUCTURES_ENCODING|TransactionException.TYPE_3_TX_WITH_FULL_BLOBS",
    ));
    try std.testing.expect(!expectedAdapterErrorMatches(
        error.InputTooShort,
        "BlockException.INCORRECT_BLOCK_FORMAT",
    ));
}

test "serialized block size uses the EIP-7934 boundary" {
    try std.testing.expect(!blockRlpSizeExceptionMatches(1 << 23, "BlockException.RLP_BLOCK_LIMIT_EXCEEDED"));
    try std.testing.expect(blockRlpSizeExceptionMatches((1 << 23) + 1, "BlockException.RLP_BLOCK_LIMIT_EXCEEDED"));
    try std.testing.expect(!blockRlpSizeExceptionMatches((1 << 23) + 1, "BlockException.INCORRECT_BLOCK_FORMAT"));
}

test "regular BlockSTF EEST runner requires consecutive child number" {
    try validateChildNumber(7, 8);
    try std.testing.expectError(error.BlockNumberMismatch, validateChildNumber(7, 7));
    try std.testing.expectError(error.BlockNumberMismatch, validateChildNumber(std.math.maxInt(u64), 0));
}

test "regular BlockSTF EEST runner validates Engine blob versioned hash claims" {
    const hash = @as(u256, 1) << 248;
    const transactions = [_]block_stf.TransactionInput{.{
        .tx = .{
            .kind = .blob,
            .sender = evmz.addr(1),
            .gas_limit = 21_000,
            .blob_hashes = &.{hash},
        },
        .encoded = &.{},
    }};

    var matching = try std.json.parseFromSlice(JsonValue, std.testing.allocator,
        \\[{}, ["0x0100000000000000000000000000000000000000000000000000000000000000"]]
    , .{ .parse_numbers = false });
    defer matching.deinit();
    try validateBlobVersionedHashes(.cancun, asArray(matching.value).?, &transactions);

    var mutated = try std.json.parseFromSlice(JsonValue, std.testing.allocator,
        \\[{}, ["0x0200000000000000000000000000000000000000000000000000000000000000"]]
    , .{ .parse_numbers = false });
    defer mutated.deinit();
    try std.testing.expectError(
        error.BlobVersionedHashesMismatch,
        validateBlobVersionedHashes(.cancun, asArray(mutated.value).?, &transactions),
    );
}
