const std = @import("std");
const evmz = @import("evmz");
const fixture_common = @import("fixture.zig");

const JsonArray = std.json.Array;
const JsonObject = std.json.ObjectMap;
const JsonValue = fixture_common.JsonValue;
const block_stf = evmz.eth.block_stf;
const bal = evmz.eth.bal;
const crypto = evmz.crypto;
const mpt = evmz.mpt;
const rlp = evmz.rlp;

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
const strip0x = fixture_common.strip0x;

pub const ExpectedStatus = block_stf.Status;

pub const Options = struct {
    test_filter: ?[]const u8 = null,
    limit: usize = 0,
    verbose: bool = false,
    expected_exceptions_only: bool = false,
};

pub const SkipReason = enum(u8) {
    expected_exception,
    missing_execution_witness,
    non_genesis_parent,
    unsupported_transaction_type,
    unsupported_checkpoint_trace,
    unsupported_fork,
};

pub const FailReason = enum(u8) {
    malformed_fixture,
    validation_error,
    unexpected_status,
    parent_hash_mismatch,
};

pub const ExpectedExceptionSummary = struct {
    total: usize = 0,
    rejected: usize = 0,
    accepted: usize = 0,
    adapter_errors: usize = 0,
    skipped: usize = 0,
    decoded_views: usize = 0,
    rejected_statuses: [std.meta.fields(ExpectedStatus).len]usize = [_]usize{0} ** std.meta.fields(ExpectedStatus).len,

    pub fn evaluated(self: ExpectedExceptionSummary) usize {
        return self.rejected + self.accepted;
    }

    fn add(self: *ExpectedExceptionSummary, other: ExpectedExceptionSummary) void {
        self.total += other.total;
        self.rejected += other.rejected;
        self.accepted += other.accepted;
        self.adapter_errors += other.adapter_errors;
        self.skipped += other.skipped;
        self.decoded_views += other.decoded_views;
        for (&self.rejected_statuses, other.rejected_statuses) |*target, value| target.* += value;
    }

    fn countResult(self: *ExpectedExceptionSummary, status: ExpectedStatus) void {
        if (status == .valid) {
            self.accepted += 1;
            return;
        }
        self.rejected += 1;
        self.rejected_statuses[@intFromEnum(status)] += 1;
    }
};

pub const Summary = struct {
    files: usize = 0,
    fixtures: usize = 0,
    passed: usize = 0,
    failed: usize = 0,
    skipped: usize = 0,
    skip_reasons: [std.meta.fields(SkipReason).len]usize = [_]usize{0} ** std.meta.fields(SkipReason).len,
    fail_reasons: [std.meta.fields(FailReason).len]usize = [_]usize{0} ** std.meta.fields(FailReason).len,
    expected: ExpectedExceptionSummary = .{},

    pub fn add(self: *Summary, other: Summary) void {
        self.files += other.files;
        self.fixtures += other.fixtures;
        self.passed += other.passed;
        self.failed += other.failed;
        self.skipped += other.skipped;
        for (&self.skip_reasons, other.skip_reasons) |*target, value| target.* += value;
        for (&self.fail_reasons, other.fail_reasons) |*target, value| target.* += value;
        self.expected.add(other.expected);
    }

    fn countSkip(self: *Summary, reason: SkipReason) void {
        self.skipped += 1;
        self.skip_reasons[@intFromEnum(reason)] += 1;
    }

    fn countFail(self: *Summary, reason: FailReason) void {
        self.failed += 1;
        self.fail_reasons[@intFromEnum(reason)] += 1;
    }
};

pub fn runFile(io: std.Io, allocator: std.mem.Allocator, path: []const u8, options: Options) !Summary {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(512 * 1024 * 1024));
    defer allocator.free(bytes);
    var summary = try runSlice(allocator, bytes, options, path);
    summary.files = 1;
    return summary;
}

pub fn runSlice(allocator: std.mem.Allocator, bytes: []const u8, options: Options, path: []const u8) !Summary {
    var parsed = try std.json.parseFromSlice(JsonValue, allocator, bytes, .{ .parse_numbers = false });
    defer parsed.deinit();

    var root = asObject(parsed.value) orelse return error.ExpectedObject;
    var summary = Summary{};
    var it = root.iterator();
    while (it.next()) |entry| {
        const test_name = entry.key_ptr.*;
        if (options.test_filter) |needle| {
            if (std.mem.indexOf(u8, test_name, needle) == null) continue;
        }
        try runFixture(allocator, path, test_name, entry.value_ptr.*, options, &summary);
        if (options.limit > 0 and summary.fixtures >= options.limit) break;
    }
    return summary;
}

fn runFixture(
    allocator: std.mem.Allocator,
    path: []const u8,
    test_name: []const u8,
    fixture: JsonValue,
    options: Options,
    summary: *Summary,
) !void {
    const fixture_object = asObject(fixture) orelse {
        summary.countFail(.malformed_fixture);
        return;
    };
    const blocks = asArray(fixture_object.get("blocks") orelse {
        summary.countFail(.malformed_fixture);
        return;
    }) orelse {
        summary.countFail(.malformed_fixture);
        return;
    };

    for (blocks.items, 0..) |block_value, block_index| {
        if (options.limit > 0 and summary.fixtures >= options.limit) return;
        const block = asObject(block_value) orelse {
            summary.countFail(.malformed_fixture);
            continue;
        };
        const expected_exception = block.get("expectException");
        if (options.expected_exceptions_only) {
            if (expected_exception == null) continue;
            summary.expected.total += 1;
        } else if (expected_exception != null) {
            summary.countSkip(.expected_exception);
            continue;
        }
        const expected_label = if (expected_exception) |value| jsonString(value) orelse "<non-string>" else null;
        var decoded_block: ?JsonObject = null;
        if (expected_label != null) {
            if (block.get("rlp_decoded")) |value| {
                decoded_block = asObject(value) orelse {
                    summary.expected.adapter_errors += 1;
                    if (options.verbose) std.debug.print("  expected {s} block={} adapter error=MalformedDecodedBlock\n", .{ test_name, block_index });
                    continue;
                };
                summary.expected.decoded_views += 1;
            }
        }
        const execution_block = if (decoded_block) |*decoded| decoded else &block;
        if (block.get("executionWitness") == null) {
            if (expected_label != null) summary.expected.skipped += 1;
            summary.countSkip(.missing_execution_witness);
            continue;
        }
        const transactions_value = execution_block.get("transactions") orelse {
            if (expected_label) |label| {
                summary.expected.adapter_errors += 1;
                if (options.verbose) std.debug.print("  expected {s} block={} adapter error=MissingTransactions label={s}\n", .{ test_name, block_index, label });
                continue;
            }
            return error.MalformedFixture;
        };
        const transactions = asArray(transactions_value) orelse {
            if (expected_label) |label| {
                summary.expected.adapter_errors += 1;
                if (options.verbose) std.debug.print("  expected {s} block={} adapter error=MalformedTransactions label={s}\n", .{ test_name, block_index, label });
                continue;
            }
            return error.MalformedFixture;
        };
        if (hasUnsupportedTransactions(transactions) catch |err| {
            if (expected_label) |label| {
                summary.expected.adapter_errors += 1;
                if (options.verbose) std.debug.print("  expected {s} block={} adapter error={s} label={s}\n", .{ test_name, block_index, @errorName(err), label });
            } else {
                summary.countFail(if (err == error.MalformedFixture) .malformed_fixture else .validation_error);
            }
            continue;
        }) {
            if (expected_label != null) summary.expected.skipped += 1;
            summary.countSkip(.unsupported_transaction_type);
            continue;
        }
        _ = fixtureRevision(&fixture_object) catch {
            if (expected_label != null) summary.expected.skipped += 1;
            summary.countSkip(.unsupported_fork);
            continue;
        };

        const block_header_value = execution_block.get("blockHeader") orelse {
            if (expected_label) |label| {
                summary.expected.adapter_errors += 1;
                if (options.verbose) std.debug.print("  expected {s} block={} adapter error=MissingBlockHeader label={s}\n", .{ test_name, block_index, label });
                continue;
            }
            return error.MalformedFixture;
        };
        const block_header = asObject(block_header_value) orelse {
            if (expected_label) |label| {
                summary.expected.adapter_errors += 1;
                if (options.verbose) std.debug.print("  expected {s} block={} adapter error=MalformedBlockHeader label={s}\n", .{ test_name, block_index, label });
                continue;
            }
            return error.MalformedFixture;
        };
        const number = try u64Field(&block_header, "number");
        if (number > 1) {
            if (expected_label != null) summary.expected.skipped += 1;
            summary.countSkip(.non_genesis_parent);
            continue;
        }

        summary.fixtures += 1;
        const result = runBlock(allocator, &fixture_object, &block, execution_block) catch |err| {
            if (err == error.UnsupportedTransactionType or err == error.CheckpointMismatch) {
                summary.fixtures -= 1;
                if (expected_label != null) summary.expected.skipped += 1;
                summary.countSkip(if (err == error.UnsupportedTransactionType) .unsupported_transaction_type else .unsupported_checkpoint_trace);
                continue;
            }
            if (expected_label) |label| {
                summary.expected.adapter_errors += 1;
                if (options.verbose) std.debug.print("  expected {s} block={} adapter error={s} label={s}\n", .{ test_name, block_index, @errorName(err), label });
                continue;
            }
            if (err == error.ParentHashMismatch) {
                summary.countFail(.parent_hash_mismatch);
                continue;
            }
            if (options.verbose) std.debug.print("  {s} block={} validation error: {s}\n", .{ test_name, block_index, @errorName(err) });
            summary.countFail(if (err == error.MalformedFixture) .malformed_fixture else .validation_error);
            continue;
        };
        if (expected_label) |label| {
            summary.expected.countResult(result.status);
            if (options.verbose) std.debug.print("  expected {s} block={} status={s} label={s}\n", .{ test_name, block_index, @tagName(result.status), label });
            continue;
        }
        if (result.status != .valid) {
            if (options.verbose) {
                std.debug.print("  {s} block={} status={s}\n", .{ test_name, block_index, @tagName(result.status) });
                std.debug.print("    state={x} receipts={x} requests={x} bal={x}\n", .{
                    result.state_root,
                    result.receipts_root,
                    result.requests_hash,
                    result.block_access_list_hash,
                });
            }
            summary.countFail(.unexpected_status);
            continue;
        }
        if (options.verbose) std.debug.print("  pass {s} block={}\n", .{ test_name, block_index });
        _ = path;
        summary.passed += 1;
    }
}

fn runBlock(
    allocator: std.mem.Allocator,
    fixture: *const JsonObject,
    fixture_block: *const JsonObject,
    block: *const JsonObject,
) !block_stf.Result {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();

    const revision = try fixtureRevision(fixture);
    const fixture_config = try parseFixtureConfig(fixture, revision);
    const genesis_header = asObject(fixture.get("genesisBlockHeader") orelse return error.MalformedFixture) orelse return error.MalformedFixture;
    const block_header = asObject(block.get("blockHeader") orelse return error.MalformedFixture) orelse return error.MalformedFixture;
    const witness = asObject(fixture_block.get("executionWitness") orelse return error.MalformedFixture) orelse return error.MalformedFixture;
    const number = try u64Field(&block_header, "number");
    const parent_hash = try hashField(&block_header, "parentHash");
    const genesis_number = try u64Field(&genesis_header, "number");
    const genesis_hash = try hashField(&genesis_header, "hash");
    try validateFixtureParent(genesis_number, genesis_hash, number, parent_hash);
    var parent_source = FixtureParentSource{ .number = genesis_number, .hash = genesis_hash };
    const block_hash_source = parent_source.source();

    const witness_nodes = try parseByteList(scratch, asArray(witness.get("state") orelse return error.MalformedFixture) orelse return error.MalformedFixture);
    const code_bytes = try parseByteList(scratch, asArray(witness.get("codes") orelse return error.MalformedFixture) orelse return error.MalformedFixture);
    const codes = try witnessCodes(scratch, code_bytes);
    const transactions = try parseTransactions(scratch, asArray(block.get("transactions") orelse return error.MalformedFixture) orelse return error.MalformedFixture);
    const withdrawals = if (revision.isImpl(.shanghai))
        try parseWithdrawals(scratch, asArray(block.get("withdrawals") orelse return error.MalformedFixture) orelse return error.MalformedFixture)
    else
        &.{};
    const encoded_bal = if (revision.isImpl(.amsterdam)) try encodeBlockAccessListClaim(scratch, block) else null;
    if (revision.isImpl(.amsterdam)) {
        const expected_bal_hash = try hashField(&block_header, "blockAccessListHash");
        const actual_bal_hash = crypto.keccak256(encoded_bal.?);
        if (!std.mem.eql(u8, &expected_bal_hash, &actual_bal_hash)) return error.MalformedFixture;
    }

    return try block_stf.apply(scratch, .{
        .revision = revision,
        .env = .{
            .chain_id = fixture_config.chain_id,
            .coinbase = try addressField(&block_header, "coinbase"),
            .number = try u64Field(&block_header, "number"),
            .slot_number = try optionalU64Field(&block_header, "slotNumber") orelse 0,
            .timestamp = try u64Field(&block_header, "timestamp"),
            .gas_limit = try u64Field(&block_header, "gasLimit"),
            .prev_randao = try u256HashField(&block_header, "mixHash"),
            .base_fee = try optionalU256Field(&block_header, "baseFeePerGas") orelse 0,
            .blob_base_fee = try blobBaseFee(
                revision,
                fixture_config.blob_schedule,
                try optionalU256Field(&block_header, "excessBlobGas"),
            ),
            .blob_schedule = fixture_config.blob_schedule,
        },
        .block_hash_source = block_hash_source,
        .block_header = .{
            .number = number,
            .timestamp = try u64Field(&block_header, "timestamp"),
            .parent_hash = parent_hash,
            .parent_beacon_block_root = try optionalHashField(&block_header, "parentBeaconBlockRoot"),
        },
        .state_backend = evmz.state.Backend.fromWitness(
            try hashField(&genesis_header, "stateRoot"),
            witness_nodes,
            codes,
        ),
        .transactions = transactions,
        .withdrawals = withdrawals,
        .parent_header = .{
            .hash = genesis_hash,
            .number = genesis_number,
            .timestamp = try u64Field(&genesis_header, "timestamp"),
            .gas_limit = try u64Field(&genesis_header, "gasLimit"),
            .gas_used = try u64Field(&genesis_header, "gasUsed"),
            .base_fee_per_gas = try optionalU256Field(&genesis_header, "baseFeePerGas") orelse 0,
            .blob_gas_used = try optionalU64Field(&genesis_header, "blobGasUsed") orelse 0,
            .excess_blob_gas = try optionalU64Field(&genesis_header, "excessBlobGas") orelse 0,
        },
        .block_access_list = encoded_bal,
        .root_checks = .{
            .payload_header = .{
                .state = block_stf.payloadHeaderRoot(try hashField(&block_header, "stateRoot")),
                .receipts = block_stf.payloadHeaderRoot(try hashField(&block_header, "receiptTrie")),
            },
            .reconstructed_header = .{
                .transactions = block_stf.reconstructedHeaderRoot(try hashField(&block_header, "transactionsTrie")),
                .withdrawals = if (revision.isImpl(.shanghai))
                    block_stf.reconstructedHeaderRoot(try hashField(&block_header, "withdrawalsRoot"))
                else
                    null,
            },
        },
        .header_claims = .{
            .block_gas_used = try optionalU64Field(&block_header, "gasUsed"),
            .logs_bloom = try bloomField(scratch, &block_header, "bloom"),
            .blob_gas_used = try optionalU64Field(&block_header, "blobGasUsed"),
            .excess_blob_gas = try optionalU256Field(&block_header, "excessBlobGas"),
            .requests_hash = try optionalHashField(&block_header, "requestsHash"),
            .block_access_list_hash = try optionalHashField(&block_header, "blockAccessListHash"),
        },
        .header_hash_claim = .{
            .block_hash = try hashField(&block_header, "hash"),
            .parent_hash = parent_hash,
            .parent_beacon_block_root = try optionalHashField(&block_header, "parentBeaconBlockRoot"),
            .extra_data = try parseBytesFromValue(scratch, block_header.get("extraData") orelse return error.MalformedFixture),
        },
    });
}

const FixtureParentSource = struct {
    number: u64,
    hash: [32]u8,

    fn source(self: *FixtureParentSource) evmz.BlockHashSource {
        return .{ .ptr = self, .vtable = &.{
            .getBlockHash = getBlockHash,
        } };
    }

    fn getBlockHash(ptr: *anyopaque, number: u64) !?u256 {
        const self: *FixtureParentSource = @ptrCast(@alignCast(ptr));
        if (number != self.number) return null;
        return evmz.uint256.fromBytes32(&self.hash);
    }
};

fn validateFixtureParent(genesis_number: u64, genesis_hash: [32]u8, number: u64, parent_hash: [32]u8) !void {
    const expected_number = std.math.add(u64, genesis_number, 1) catch return error.ParentHashMismatch;
    if (number != expected_number or !std.mem.eql(u8, &parent_hash, &genesis_hash)) return error.ParentHashMismatch;
}

fn fixtureRevision(fixture: *const JsonObject) !evmz.eth.Revision {
    const network = jsonString(fixture.get("network") orelse return error.MalformedFixture) orelse return error.MalformedFixture;
    return parseStateFork(network) orelse error.UnsupportedFork;
}

fn blobBaseFee(
    revision: evmz.eth.Revision,
    blob_schedule: ?evmz.transaction.BlobSchedule,
    excess_blob_gas: ?u256,
) !u256 {
    if (!revision.isImpl(.cancun)) return 0;
    const schedule = blob_schedule orelse evmz.eth.Protocol.Transaction.blobSchedule(revision) orelse return 0;
    return evmz.transaction.blobBaseFeeForSchedule(schedule, excess_blob_gas orelse 0) orelse error.BlobGasOverflow;
}

fn parseByteList(allocator: std.mem.Allocator, array: JsonArray) ![]const []const u8 {
    const out = try allocator.alloc([]const u8, array.items.len);
    for (out, array.items) |*target, value| {
        target.* = try parseBytesFromValue(allocator, value);
    }
    return out;
}

fn witnessCodes(allocator: std.mem.Allocator, codes: []const []const u8) ![]const evmz.state.WitnessStateReader.Code {
    const out = try allocator.alloc(evmz.state.WitnessStateReader.Code, codes.len);
    for (out, codes) |*item, code| item.* = .{ .hash = mpt.codeHash(code), .bytes = code };
    return out;
}

fn hasUnsupportedTransactions(array: JsonArray) !bool {
    for (array.items) |value| {
        const object = asObject(value) orelse return error.MalformedFixture;
        const kind = transactionKind(&object) catch |err| switch (err) {
            error.UnsupportedTransactionType => return true,
            else => return err,
        };
        if (kind != .legacy) return true;
    }
    return false;
}

fn parseTransactions(allocator: std.mem.Allocator, array: JsonArray) ![]const block_stf.TransactionInput {
    const out = try allocator.alloc(block_stf.TransactionInput, array.items.len);
    for (out, array.items) |*target, value| {
        const object = asObject(value) orelse return error.MalformedFixture;
        target.* = try parseLegacyTransaction(allocator, &object);
    }
    return out;
}

fn parseLegacyTransaction(allocator: std.mem.Allocator, object: *const JsonObject) !block_stf.TransactionInput {
    if (try transactionKind(object) != .legacy) return error.UnsupportedTransactionType;

    const input = try parseBytesFromValue(allocator, object.get("data") orelse return error.MalformedFixture);
    const recipient = try transactionRecipient(object);
    const gas_price = try u256FieldAny(object, &.{ "gasPrice", "gas_price" });
    const gas_limit = try u64FieldAny(object, &.{ "gasLimit", "gas_limit" });
    const value = try u256FieldAny(object, &.{"value"});
    const nonce = try u64FieldAny(object, &.{"nonce"});
    const encoded = try encodeLegacyTransaction(allocator, object, nonce, gas_price, gas_limit, recipient, value, input);

    return .{
        .tx = try evmz.stateless.tx.decodeRaw(allocator, encoded),
        .encoded = encoded,
    };
}

fn transactionKind(object: *const JsonObject) !evmz.transaction.TxKind {
    const raw_type = if (object.get("type")) |value| try parseU64FromValue(value) else 0;
    return switch (raw_type) {
        0 => .legacy,
        1 => .access_list,
        2 => .dynamic_fee,
        3 => .blob,
        4 => .set_code,
        else => error.UnsupportedTransactionType,
    };
}

fn transactionRecipient(object: *const JsonObject) !?evmz.Address {
    const to_string = jsonString(object.get("to") orelse return error.MalformedFixture) orelse return error.MalformedFixture;
    if (strip0x(to_string).len == 0) return null;
    return try parseAddressFromValue(object.get("to").?);
}

fn encodeLegacyTransaction(
    allocator: std.mem.Allocator,
    object: *const JsonObject,
    nonce: u64,
    gas_price: u256,
    gas_limit: u64,
    recipient: ?evmz.Address,
    value: u256,
    input: []const u8,
) ![]const u8 {
    var fields = rlp.Writer.alloc(allocator);
    defer fields.deinit();

    try fields.int(u64, nonce);
    try fields.int(u256, gas_price);
    try fields.int(u64, gas_limit);
    if (recipient) |to| {
        try fields.bytes(&to);
    } else {
        try fields.bytes(&.{});
    }
    try fields.int(u256, value);
    try fields.bytes(input);
    try fields.int(u256, try u256FieldAny(object, &.{"v"}));
    try fields.int(u256, try u256FieldAny(object, &.{"r"}));
    try fields.int(u256, try u256FieldAny(object, &.{"s"}));

    var out = rlp.Writer.alloc(allocator);
    errdefer out.deinit();
    try out.list(fields.written());
    return try out.toOwnedSlice();
}

fn parseWithdrawals(allocator: std.mem.Allocator, array: JsonArray) ![]const mpt.Withdrawal {
    const out = try allocator.alloc(mpt.Withdrawal, array.items.len);
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

fn encodeBlockAccessListClaim(allocator: std.mem.Allocator, block: *const JsonObject) ![]const u8 {
    const array = asArray(block.get("blockAccessList") orelse return error.MalformedFixture) orelse return error.MalformedFixture;
    const accounts = try parseBlockAccessList(allocator, array);
    return try bal.encodeAlloc(allocator, accounts);
}

fn parseBlockAccessList(allocator: std.mem.Allocator, array: JsonArray) ![]const bal.AccountChanges {
    const out = try allocator.alloc(bal.AccountChanges, array.items.len);
    for (out, array.items) |*target, value| {
        const object = asObject(value) orelse return error.MalformedFixture;
        target.* = .{
            .address = try addressField(&object, "address"),
            .storage_changes = try parseStorageChanges(allocator, optionalArrayField(&object, "storageChanges")),
            .storage_reads = try parseU256List(allocator, optionalArrayField(&object, "storageReads")),
            .balance_changes = try parseBalanceChanges(allocator, optionalArrayField(&object, "balanceChanges")),
            .nonce_changes = try parseNonceChanges(allocator, optionalArrayField(&object, "nonceChanges")),
            .code_changes = try parseCodeChanges(allocator, optionalArrayField(&object, "codeChanges")),
        };
    }
    return out;
}

fn parseStorageChanges(allocator: std.mem.Allocator, maybe_array: ?JsonArray) ![]const bal.SlotChanges {
    const array = maybe_array orelse return &.{};
    const out = try allocator.alloc(bal.SlotChanges, array.items.len);
    for (out, array.items) |*target, value| {
        const object = asObject(value) orelse return error.MalformedFixture;
        target.* = .{
            .slot = try u256FieldAny(&object, &.{ "slot", "key" }),
            .changes = try parseStorageChangeList(allocator, try arrayFieldAny(&object, &.{ "slotChanges", "storageChanges", "changes" })),
        };
    }
    return out;
}

fn parseStorageChangeList(allocator: std.mem.Allocator, array: JsonArray) ![]const bal.StorageChange {
    const out = try allocator.alloc(bal.StorageChange, array.items.len);
    for (out, array.items) |*target, value| {
        const object = asObject(value) orelse return error.MalformedFixture;
        target.* = .{
            .block_access_index = try blockAccessIndexField(&object),
            .new_value = try u256FieldAny(&object, &.{ "newValue", "new_value", "postValue", "post_value", "value" }),
        };
    }
    return out;
}

fn parseU256List(allocator: std.mem.Allocator, maybe_array: ?JsonArray) ![]const u256 {
    const array = maybe_array orelse return &.{};
    const out = try allocator.alloc(u256, array.items.len);
    for (out, array.items) |*target, value| target.* = try parseU256FromValue(value);
    return out;
}

fn parseBalanceChanges(allocator: std.mem.Allocator, maybe_array: ?JsonArray) ![]const bal.BalanceChange {
    const array = maybe_array orelse return &.{};
    const out = try allocator.alloc(bal.BalanceChange, array.items.len);
    for (out, array.items) |*target, value| {
        const object = asObject(value) orelse return error.MalformedFixture;
        target.* = .{
            .block_access_index = try blockAccessIndexField(&object),
            .post_balance = try u256FieldAny(&object, &.{ "postBalance", "post_balance", "value" }),
        };
    }
    return out;
}

fn parseNonceChanges(allocator: std.mem.Allocator, maybe_array: ?JsonArray) ![]const bal.NonceChange {
    const array = maybe_array orelse return &.{};
    const out = try allocator.alloc(bal.NonceChange, array.items.len);
    for (out, array.items) |*target, value| {
        const object = asObject(value) orelse return error.MalformedFixture;
        target.* = .{
            .block_access_index = try blockAccessIndexField(&object),
            .new_nonce = try u64FieldAny(&object, &.{ "newNonce", "new_nonce", "postNonce", "post_nonce", "value" }),
        };
    }
    return out;
}

fn parseCodeChanges(allocator: std.mem.Allocator, maybe_array: ?JsonArray) ![]const bal.CodeChange {
    const array = maybe_array orelse return &.{};
    const out = try allocator.alloc(bal.CodeChange, array.items.len);
    for (out, array.items) |*target, value| {
        const object = asObject(value) orelse return error.MalformedFixture;
        target.* = .{
            .block_access_index = try blockAccessIndexField(&object),
            .new_code = try parseBytesFromValue(allocator, fieldAny(&object, &.{ "newCode", "new_code", "value" })),
        };
    }
    return out;
}

fn blockAccessIndexField(object: *const JsonObject) !bal.BlockAccessIndex {
    const raw = try u64FieldAny(object, &.{ "blockAccessIndex", "block_access_index", "index" });
    return std.math.cast(bal.BlockAccessIndex, raw) orelse error.MalformedFixture;
}

fn optionalArrayField(object: *const JsonObject, name: []const u8) ?JsonArray {
    const value = object.get(name) orelse return null;
    return asArray(value) orelse null;
}

fn arrayFieldAny(object: *const JsonObject, names: []const []const u8) !JsonArray {
    return asArray(fieldAny(object, names)) orelse error.MalformedFixture;
}

fn fieldAny(object: *const JsonObject, names: []const []const u8) JsonValue {
    for (names) |name| {
        if (object.get(name)) |value| return value;
    }
    return .null;
}

fn hashField(object: *const JsonObject, name: []const u8) ![32]u8 {
    return parseHashFromValue(object.get(name) orelse return error.MalformedFixture);
}

fn optionalHashField(object: *const JsonObject, name: []const u8) !?[32]u8 {
    if (object.get(name)) |value| return try parseHashFromValue(value);
    return null;
}

fn addressField(object: *const JsonObject, name: []const u8) !evmz.Address {
    return parseAddressFromValue(object.get(name) orelse return error.MalformedFixture);
}

fn u64Field(object: *const JsonObject, name: []const u8) !u64 {
    return parseU64FromValue(object.get(name) orelse return error.MalformedFixture);
}

fn optionalU64Field(object: *const JsonObject, name: []const u8) !?u64 {
    if (object.get(name)) |value| return try parseU64FromValue(value);
    return null;
}

fn u64FieldAny(object: *const JsonObject, names: []const []const u8) !u64 {
    return parseU64FromValue(fieldAny(object, names));
}

fn u256FieldAny(object: *const JsonObject, names: []const []const u8) !u256 {
    return parseU256FromValue(fieldAny(object, names));
}

fn optionalU256Field(object: *const JsonObject, name: []const u8) !?u256 {
    if (object.get(name)) |value| return try parseU256FromValue(value);
    return null;
}

fn u256HashField(object: *const JsonObject, name: []const u8) !u256 {
    const hash = try hashField(object, name);
    return std.mem.readInt(u256, &hash, .big);
}

fn bloomField(allocator: std.mem.Allocator, object: *const JsonObject, name: []const u8) ![256]u8 {
    const bytes = try parseBytesFromValue(allocator, object.get(name) orelse return error.MalformedFixture);
    if (bytes.len != 256) return error.MalformedFixture;
    var out: [256]u8 = undefined;
    @memcpy(&out, bytes);
    return out;
}

test "stateless BlockSTF EEST runner validates a witness-backed empty Cancun block" {
    const empty_root = mpt.empty_root_hash;
    const block_hash = try (evmz.eth.ExecutionHeader{
        .parent_hash = [_]u8{0} ** 32,
        .coinbase = [_]u8{0} ** 20,
        .state_root = empty_root,
        .transactions_root = empty_root,
        .receipts_root = empty_root,
        .logs_bloom = block_stf.empty_logs_bloom,
        .number = 1,
        .gas_limit = 5000,
        .gas_used = 0,
        .timestamp = 1,
        .extra_data = &.{},
        .prev_randao = [_]u8{0} ** 32,
        .base_fee_per_gas = 0,
        .withdrawals_root = empty_root,
        .blob_gas_used = 0,
        .excess_blob_gas = 0,
        .parent_beacon_block_root = [_]u8{0} ** 32,
    }).hash(std.testing.allocator, .cancun);
    const block_hash_hex = std.fmt.bytesToHex(block_hash, .lower);
    const template =
        \\{
        \\  "smoke": {
        \\    "network": "Cancun",
        \\    "config": {"chainid": "0x01"},
        \\    "genesisBlockHeader": {
        \\      "number": "0x00",
        \\      "hash": "0x0000000000000000000000000000000000000000000000000000000000000000",
        \\      "stateRoot": "0x56e81f171bcc55a6ff8345e692c0f86e5b48e01b996cadc001622fb5e363b421",
        \\      "gasLimit": "0x1388",
        \\      "gasUsed": "0x00",
        \\      "timestamp": "0x00",
        \\      "baseFeePerGas": "0x00",
        \\      "blobGasUsed": "0x00",
        \\      "excessBlobGas": "0x00"
        \\    },
        \\    "blocks": [{
        \\      "executionWitness": {"state": [], "codes": [], "headers": []},
        \\      "transactions": [],
        \\      "withdrawals": [],
        \\      "blockHeader": {
        \\        "hash": "0x$BLOCK_HASH",
        \\        "parentHash": "0x0000000000000000000000000000000000000000000000000000000000000000",
        \\        "coinbase": "0x0000000000000000000000000000000000000000",
        \\        "stateRoot": "0x56e81f171bcc55a6ff8345e692c0f86e5b48e01b996cadc001622fb5e363b421",
        \\        "transactionsTrie": "0x56e81f171bcc55a6ff8345e692c0f86e5b48e01b996cadc001622fb5e363b421",
        \\        "receiptTrie": "0x56e81f171bcc55a6ff8345e692c0f86e5b48e01b996cadc001622fb5e363b421",
        \\        "withdrawalsRoot": "0x56e81f171bcc55a6ff8345e692c0f86e5b48e01b996cadc001622fb5e363b421",
        \\        "bloom": "0x00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000",
        \\        "number": "0x01",
        \\        "gasLimit": "0x1388",
        \\        "gasUsed": "0x00",
        \\        "timestamp": "0x01",
        \\        "extraData": "0x",
        \\        "mixHash": "0x0000000000000000000000000000000000000000000000000000000000000000",
        \\        "baseFeePerGas": "0x00",
        \\        "blobGasUsed": "0x00",
        \\        "excessBlobGas": "0x00",
        \\        "parentBeaconBlockRoot": "0x0000000000000000000000000000000000000000000000000000000000000000"
        \\      }
        \\    }]
        \\  }
        \\}
    ;

    const fixture = try std.mem.replaceOwned(u8, std.testing.allocator, template, "$BLOCK_HASH", &block_hash_hex);
    defer std.testing.allocator.free(fixture);

    const summary = try runSlice(std.testing.allocator, fixture, .{}, "smoke.json");
    try std.testing.expectEqual(@as(usize, 1), summary.fixtures);
    try std.testing.expectEqual(@as(usize, 1), summary.passed);
    try std.testing.expectEqual(@as(usize, 0), summary.failed);

    const expected_fixture = try std.mem.replaceOwned(
        u8,
        std.testing.allocator,
        fixture,
        "\"blocks\": [{",
        "\"blocks\": [{\"expectException\": \"diagnostic-only\",",
    );
    defer std.testing.allocator.free(expected_fixture);

    const accepted = try runSlice(std.testing.allocator, expected_fixture, .{ .expected_exceptions_only = true }, "expected-smoke.json");
    try std.testing.expectEqual(@as(usize, 1), accepted.expected.total);
    try std.testing.expectEqual(@as(usize, 1), accepted.expected.evaluated());
    try std.testing.expectEqual(@as(usize, 1), accepted.expected.accepted);
    try std.testing.expectEqual(@as(usize, 0), accepted.failed);

    const rejected_fixture = try std.mem.replaceOwned(
        u8,
        std.testing.allocator,
        expected_fixture,
        "\"timestamp\": \"0x01\"",
        "\"timestamp\": \"0x00\"",
    );
    defer std.testing.allocator.free(rejected_fixture);

    const rejected = try runSlice(std.testing.allocator, rejected_fixture, .{ .expected_exceptions_only = true }, "rejected-smoke.json");
    try std.testing.expectEqual(@as(usize, 1), rejected.expected.total);
    try std.testing.expectEqual(@as(usize, 1), rejected.expected.rejected);
    try std.testing.expectEqual(@as(usize, 1), rejected.expected.rejected_statuses[@intFromEnum(ExpectedStatus.timestamp_mismatch)]);
    try std.testing.expectEqual(@as(usize, 0), rejected.failed);
}

test "stateless BlockSTF EEST runner requires the genesis child" {
    const genesis_hash = [_]u8{0x11} ** 32;
    try validateFixtureParent(0, genesis_hash, 1, genesis_hash);
    try std.testing.expectError(error.ParentHashMismatch, validateFixtureParent(0, genesis_hash, 0, genesis_hash));
    try std.testing.expectError(error.ParentHashMismatch, validateFixtureParent(0, genesis_hash, 1, [_]u8{0x22} ** 32));
}

test "stateless BlockSTF EEST runner recovers legacy sender from signed bytes" {
    const fixture_transaction =
        \\{
        \\  "type": "0x00",
        \\  "sender": "0x1111111111111111111111111111111111111111",
        \\  "nonce": "0x09",
        \\  "gasPrice": "0x04a817c800",
        \\  "gasLimit": "0x5208",
        \\  "to": "0x3535353535353535353535353535353535353535",
        \\  "value": "0x0de0b6b3a7640000",
        \\  "data": "0x",
        \\  "v": "0x25",
        \\  "r": "0x28ef61340bd939bc2195fe537567866003e1a15d3c71ff63e1590620aa636276",
        \\  "s": "0x67cbe9d8997f761aecb703304b3800ccf555c9f3dc64214b297fb1966a3b6d83"
        \\}
    ;
    var parsed = try std.json.parseFromSlice(JsonValue, std.testing.allocator, fixture_transaction, .{ .parse_numbers = false });
    defer parsed.deinit();
    var object = asObject(parsed.value) orelse return error.ExpectedObject;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const transaction = try parseLegacyTransaction(arena.allocator(), &object);

    var expected_sender: evmz.Address = undefined;
    _ = try std.fmt.hexToBytes(&expected_sender, "9d8a62f656a8d1615c1294fd71e9cfb3e4855a4f");
    const fixture_sender = try addressField(&object, "sender");
    try std.testing.expectEqual(expected_sender, transaction.tx.sender);
    try std.testing.expect(!std.mem.eql(u8, &fixture_sender, &transaction.tx.sender));
}

test "stateless BlockSTF EEST runner parses postNonce block access list changes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const scratch = arena.allocator();

    const block =
        \\{
        \\  "blockAccessList": [{
        \\    "address": "0x0000000000000000000000000000000000001000",
        \\    "nonceChanges": [{"blockAccessIndex": "0x01", "postNonce": "0x02"}],
        \\    "balanceChanges": [],
        \\    "codeChanges": [],
        \\    "storageChanges": [],
        \\    "storageReads": []
        \\  }]
        \\}
    ;

    var parsed = try std.json.parseFromSlice(JsonValue, std.testing.allocator, block, .{ .parse_numbers = false });
    defer parsed.deinit();
    var block_object = asObject(parsed.value) orelse return error.ExpectedObject;

    const encoded = try encodeBlockAccessListClaim(scratch, &block_object);

    var decoded = try bal.decode(std.testing.allocator, encoded);
    defer decoded.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), decoded.accounts.len);
    try std.testing.expectEqual(@as(usize, 1), decoded.accounts[0].nonce_changes.len);
    try std.testing.expectEqual(@as(bal.BlockAccessIndex, 1), decoded.accounts[0].nonce_changes[0].block_access_index);
    try std.testing.expectEqual(@as(u64, 2), decoded.accounts[0].nonce_changes[0].new_nonce);
}
