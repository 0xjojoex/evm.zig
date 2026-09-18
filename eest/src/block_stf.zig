const std = @import("std");
const evmz = @import("evmz");
const blocktest = @import("blocktest");
const fixture_common = @import("fixtures");
const tx_validation = @import("tx_validation.zig");

const JsonValue = fixture_common.JsonValue;
const block_stf = evmz.eth.block_stf;

const asArray = fixture_common.asArray;
const asObject = fixture_common.asObject;
const jsonString = fixture_common.jsonString;

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
    var session = blocktest.Session.init(allocator, fixture_object) catch |err| {
        switch (err) {
            error.UnsupportedFork => summary.countSkip(.unsupported_fork),
            error.PreStateRootMismatch => summary.countFail(.pre_state_root_mismatch),
            error.OutOfMemory => return err,
            else => summary.countFail(.malformed_fixture),
        }
        return;
    };
    defer session.deinit();

    if (mode == .all) {
        if (fixture_object.get("engineNewPayloads")) |payloads_value| {
            const payloads = asArray(payloads_value) orelse {
                summary.countFail(.malformed_fixture);
                return;
            };
            for (payloads.items) |entry_value| {
                try runBlockEntry(&session, .payload, entry_value, summary);
            }
        }
    }

    if (mode == .all) {
        if (fixture_object.get("syncPayload")) |sync_value| {
            try runBlockEntry(&session, .payload, sync_value, summary);
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
            try runBlockEntry(&session, .block_body, entry_value, summary);
        }
    }
}

fn runBlockEntry(
    session: *blocktest.Session,
    source: blocktest.BlockSource,
    entry_value: JsonValue,
    summary: *Summary,
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
    const result = session.apply(false, source, &entry, null) catch |err| {
        if (err == error.OutOfMemory) return err;
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
        error.ParentHashMismatch => "BlockException.UNKNOWN_PARENT",
        error.BlockNumberMismatch => "BlockException.INVALID_BLOCK_NUMBER",
        error.BlobGasOverflow => "BlockException.INCORRECT_EXCESS_BLOB_GAS",
        error.ExtraDataTooLong => "BlockException.EXTRA_DATA_TOO_BIG",
        error.HeaderSurfaceMismatch => "BlockException.INCORRECT_BLOCK_FORMAT",
        error.BlockRlpTooLarge => "BlockException.RLP_BLOCK_LIMIT_EXCEEDED",
        error.InvalidSignature, error.UnsupportedLegacyV => "TransactionException.INVALID_SIGNATURE_VRS",
        error.InputTooShort => "BlockException.RLP_STRUCTURES_ENCODING",
        else => return false,
    };
    return tx_validation.exceptionNameMatches(name, expected);
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

test "block expectations compare actual ingress errors" {
    try std.testing.expect(expectedAdapterErrorMatches(error.InvalidSignature, "TransactionException.INVALID_SIGNATURE_VRS"));
    try std.testing.expect(expectedAdapterErrorMatches(error.BlockRlpTooLarge, "BlockException.RLP_BLOCK_LIMIT_EXCEEDED"));
    try std.testing.expect(expectedAdapterErrorMatches(error.ParentHashMismatch, "BlockException.UNKNOWN_PARENT"));
    try std.testing.expect(expectedAdapterErrorMatches(error.BlockNumberMismatch, "BlockException.INVALID_BLOCK_NUMBER"));
    try std.testing.expect(!expectedAdapterErrorMatches(error.InvalidSignature, "BlockException.INVALID_STATE_ROOT"));
    try std.testing.expect(!expectedAdapterErrorMatches(error.OutOfMemory, "BlockException.RLP_BLOCK_LIMIT_EXCEEDED"));
}
