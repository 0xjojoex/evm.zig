const std = @import("std");
const evmz = @import("evmz");
const fixture_common = @import("fixture.zig");

const JsonArray = std.json.Array;
const JsonObject = std.json.ObjectMap;
const JsonValue = fixture_common.JsonValue;
const block_stf = evmz.eth.block_stf;
const trie = evmz.eth.trie;

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

pub const Options = struct {
    test_filter: ?[]const u8 = null,
    limit: usize = 0,
    verbose: bool = false,
    bal_differential: bool = false,
};

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
    bal_differential_mismatch,
};

pub const UncheckedReason = enum(u8) {
    bal_differential_fallback,
};

pub const Summary = struct {
    files: usize = 0,
    fixtures: usize = 0,
    passed: usize = 0,
    failed: usize = 0,
    skipped: usize = 0,
    unchecked: usize = 0,
    skip_reasons: [std.meta.fields(SkipReason).len]usize = [_]usize{0} ** std.meta.fields(SkipReason).len,
    fail_reasons: [std.meta.fields(FailReason).len]usize = [_]usize{0} ** std.meta.fields(FailReason).len,
    unchecked_reasons: [std.meta.fields(UncheckedReason).len]usize = [_]usize{0} ** std.meta.fields(UncheckedReason).len,

    pub fn add(self: *Summary, other: Summary) void {
        self.files += other.files;
        self.fixtures += other.fixtures;
        self.passed += other.passed;
        self.failed += other.failed;
        self.skipped += other.skipped;
        self.unchecked += other.unchecked;
        for (&self.skip_reasons, other.skip_reasons) |*target, value| target.* += value;
        for (&self.fail_reasons, other.fail_reasons) |*target, value| target.* += value;
        for (&self.unchecked_reasons, other.unchecked_reasons) |*target, value| target.* += value;
    }

    fn countSkip(self: *Summary, reason: SkipReason) void {
        self.skipped += 1;
        self.skip_reasons[@intFromEnum(reason)] += 1;
    }

    fn countFail(self: *Summary, reason: FailReason) void {
        self.failed += 1;
        self.fail_reasons[@intFromEnum(reason)] += 1;
    }

    fn countUnchecked(self: *Summary, reason: UncheckedReason) void {
        self.unchecked += 1;
        self.unchecked_reasons[@intFromEnum(reason)] += 1;
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
        if (options.verbose) {
            std.debug.print("  {s} pre-state root mismatch expected={x} actual={x}\n", .{ test_name, expected_pre_state_root, actual_pre_state_root });
        }
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

    if (fixture_object.get("engineNewPayloads")) |payloads_value| {
        const payloads = asArray(payloads_value) orelse {
            summary.countFail(.malformed_fixture);
            return;
        };
        for (payloads.items, 0..) |entry_value, block_index| {
            if (options.limit > 0 and summary.fixtures >= options.limit) return;
            try runPayloadEntry(allocator, path, test_name, block_index, revision, &fixture_object, entry_value, options, summary, &store, &block_hashes, &parent);
        }
    }

    if (fixture_object.get("syncPayload")) |sync_value| {
        if (options.limit > 0 and summary.fixtures >= options.limit) return;
        try runPayloadEntry(allocator, path, test_name, summary.fixtures, revision, &fixture_object, sync_value, options, summary, &store, &block_hashes, &parent);
    }
}

fn runPayloadEntry(
    allocator: std.mem.Allocator,
    path: []const u8,
    test_name: []const u8,
    block_index: usize,
    revision: evmz.eth.Revision,
    fixture: *const JsonObject,
    entry_value: JsonValue,
    options: Options,
    summary: *Summary,
    store: *evmz.state.MemoryStore,
    block_hashes: *FixtureBlockHashes,
    parent: *ParentContext,
) !void {
    const entry = asObject(entry_value) orelse {
        summary.countFail(.malformed_fixture);
        return;
    };
    if (entry.get("expectException") != null or entry.get("errorCode") != null or entry.get("validationError") != null) {
        summary.countSkip(.expected_exception);
        return;
    }

    summary.fixtures += 1;
    var bal_diff_buffer: [64 * 1024]u8 = undefined;
    var bal_diff_writer: std.Io.Writer = .fixed(&bal_diff_buffer);
    var bal_report = block_stf.BalDifferentialReport{
        .mismatch_writer = if (options.bal_differential) &bal_diff_writer else null,
    };
    const result = runPayload(
        allocator,
        revision,
        fixture,
        &entry,
        store,
        block_hashes,
        parent,
        if (options.bal_differential) &bal_report else null,
    ) catch |err| {
        if (err == error.ParentHashMismatch) {
            if (options.verbose) std.debug.print("  {s} block={} parent hash mismatch\n", .{ test_name, block_index });
            summary.countFail(.parent_hash_mismatch);
            return;
        }
        if (err == error.BlockNumberMismatch) {
            if (options.verbose) std.debug.print("  {s} block={} block number mismatch\n", .{ test_name, block_index });
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
        if (options.verbose) std.debug.print("  {s} block={} validation error: {s}\n", .{ test_name, block_index, @errorName(err) });
        summary.countFail(if (err == error.MalformedFixture) .malformed_fixture else .validation_error);
        return;
    };
    if (bal_diff_writer.buffered().len != 0) {
        std.debug.print("  {s} block={} BAL diff:\n{s}", .{ test_name, block_index, bal_diff_writer.buffered() });
    }
    if (bal_report.mismatch_write_failed) {
        std.debug.print("  {s} block={} BAL diff truncated at 64 KiB\n", .{ test_name, block_index });
    }
    if (result.status != .valid) {
        if (options.verbose) {
            std.debug.print("  {s} block={} status={s}\n", .{ test_name, block_index, @tagName(result.status) });
            std.debug.print("    state={x} receipts={x} requests={x} bal={x} block={x}\n", .{
                result.state_root,
                result.receipts_root,
                result.requests_hash,
                result.block_access_list_hash,
                result.block_hash,
            });
            std.debug.print("    gas={} block_gas={} state_gas={}\n", .{ result.gas_used, result.block_gas_used, result.block_state_gas_used });
        }
        summary.countFail(.unexpected_status);
        return;
    }

    if (options.bal_differential and revision.isImpl(.amsterdam)) {
        if (!bal_report.status.isFallback() and bal_report.status != .matched) {
            std.debug.print("  {s} block={} BAL differential={s} tx={?}\n", .{
                test_name,
                block_index,
                @tagName(bal_report.status),
                bal_report.tx_index,
            });
            summary.countFail(.bal_differential_mismatch);
            return;
        }
        if (bal_report.status.isFallback()) {
            if (options.verbose) {
                std.debug.print("  {s} block={} BAL differential fallback={s} tx={?} error={s}\n", .{
                    test_name,
                    block_index,
                    @tagName(bal_report.status),
                    bal_report.tx_index,
                    if (bal_report.diagnostic_error) |err| @errorName(err) else "none",
                });
            }
            summary.countUnchecked(.bal_differential_fallback);
        }
    }

    if (options.verbose) std.debug.print("  pass {s} block={}\n", .{ test_name, block_index });
    _ = path;
    summary.passed += 1;
}

fn runPayload(
    allocator: std.mem.Allocator,
    revision: evmz.eth.Revision,
    fixture: *const JsonObject,
    entry: *const JsonObject,
    store: *evmz.state.MemoryStore,
    block_hashes: *FixtureBlockHashes,
    parent: *ParentContext,
    bal_report: ?*block_stf.BalDifferentialReport,
) !block_stf.Result {
    return switch (revision) {
        inline else => |exact_revision| runPayloadExact(
            exact_revision,
            allocator,
            fixture,
            entry,
            store,
            block_hashes,
            parent,
            bal_report,
        ),
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

    const fixture_config = try parseFixtureConfig(fixture, revision);
    const transactions = try parseTransactions(scratch, asArray(payload.get("transactions") orelse return error.MalformedFixture) orelse return error.MalformedFixture);
    try validateBlobVersionedHashes(revision, params, transactions);
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
            .blob_base_fee = try blobBaseFee(revision, fixture_config.blob_schedule, excess_blob_gas),
            .blob_schedule = fixture_config.blob_schedule,
        },
        .block_hash_source = block_hash_source,
        .block_header = block_header,
        .state_backend = store.backend(),
        .transactions = transactions,
        .withdrawals = withdrawals,
        .parent_header = parent.headerContext(),
        .block_access_list = block_access_list,
        .root_checks = .{
            .payload_header = .{
                .state = .fromHash(try hashField(&payload, "stateRoot")),
                .receipts = .fromHash(try hashField(&payload, "receiptsRoot")),
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
    const network = jsonString(fixture.get("network") orelse return error.MalformedFixture) orelse return error.MalformedFixture;
    const revision = parseStateFork(network) orelse return error.UnsupportedFork;
    if (!revision.isImpl(.merge)) return error.UnsupportedFork;
    return revision;
}

fn parseTransactions(allocator: std.mem.Allocator, array: JsonArray) ![]const block_stf.TransactionInput {
    const out = try allocator.alloc(block_stf.TransactionInput, array.items.len);
    for (out, array.items) |*target, value| {
        const raw = try parseBytesFromValue(allocator, value);
        target.* = .{
            .tx = evmz.stateless.tx.decodeRaw(allocator, raw) catch |err| switch (err) {
                error.UnsupportedTransactionType => return error.UnsupportedTransactionType,
                else => return err,
            },
            .encoded = raw,
        };
    }
    return out;
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

fn blobBaseFee(
    comptime revision: evmz.eth.Revision,
    blob_schedule: ?evmz.transaction.BlobSchedule,
    excess_blob_gas: ?u256,
) !u256 {
    if (!revision.isImpl(.cancun)) return 0;
    const schedule = blob_schedule orelse evmz.eth.specAt(revision).transaction.blob_schedule orelse return 0;
    return evmz.transaction.blobBaseFeeForSchedule(schedule, excess_blob_gas orelse 0) orelse error.BlobGasOverflow;
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

    const summary = try runSlice(std.testing.allocator, fixture, .{}, "inline");
    try std.testing.expectEqual(@as(usize, 0), summary.fixtures);
    try std.testing.expectEqual(@as(usize, 0), summary.passed);
    try std.testing.expectEqual(@as(usize, 0), summary.failed);
    try std.testing.expectEqual(@as(usize, 1), summary.skipped);
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
