//! evmz-owned blockchain fixture decoding and block execution.
const std = @import("std");
const evmz = @import("evmz");
const bal_fixture = @import("block_access_list.zig");
const fixture_common = @import("fixtures");

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

pub const fixtures = fixture_common;

/// A linear post-Merge chain. Fixture JSON is borrowed for the session lifetime.
/// Rejected blocks leave the committed state, parent, and BLOCKHASH history intact.
pub const Session = struct {
    allocator: std.mem.Allocator,
    fixture_object: JsonObject,
    revision: evmz.eth.Revision,
    store: evmz.state.MemoryStore,
    block_hashes: FixtureBlockHashes,
    parent: ParentContext,

    pub fn init(allocator: std.mem.Allocator, object: JsonObject) !Session {
        const revision = try fixtureRevision(&object);
        const pre = asObject(object.get("pre") orelse return error.MalformedFixture) orelse return error.MalformedFixture;
        const genesis = asObject(object.get("genesisBlockHeader") orelse return error.MalformedFixture) orelse return error.MalformedFixture;
        var store = evmz.state.MemoryStore.init(allocator);
        errdefer store.deinit();
        try seedMemoryStore(allocator, &store, &pre);
        const expected = try hashField(&genesis, "stateRoot");
        const actual = try store.stateRoot(allocator);
        if (!std.mem.eql(u8, &expected, &actual)) return error.PreStateRootMismatch;
        const parent = try parentFromGenesis(&genesis);
        var hashes = FixtureBlockHashes.init(allocator);
        errdefer hashes.deinit();
        try hashes.put(parent.number, parent.hash);
        return .{ .allocator = allocator, .fixture_object = object, .revision = revision, .store = store, .block_hashes = hashes, .parent = parent };
    }

    pub fn deinit(self: *Session) void {
        self.block_hashes.deinit();
        self.store.deinit();
        self.* = undefined;
    }

    pub fn apply(self: *Session, comptime trace: bool, source: BlockSource, entry: *const JsonObject, capture: ?block_stf.ExecutionCapture) !block_stf.Result {
        return runBlock(trace, self.allocator, self.revision, source, &self.fixture_object, entry, &self.store, &self.block_hashes, &self.parent, capture);
    }

    pub fn stateRoot(self: *Session) ![32]u8 {
        return self.store.stateRoot(self.allocator);
    }
};

pub const BlockSource = enum { payload, block_body };

fn validateBlockSize(revision: evmz.eth.Revision, encoded_len: usize) !void {
    if (revision.isImpl(.osaka) and encoded_len > 1 << 23) return error.BlockRlpTooLarge;
}

/// Only protocol/input errors are block rejections. Allocation and execution
/// infrastructure failures must propagate to the caller.
pub fn isBlockRejection(err: anyerror) bool {
    return switch (err) {
        error.ParentHashMismatch, error.BlockNumberMismatch, error.BlobGasOverflow, error.ExtraDataTooLong, error.HeaderSurfaceMismatch, error.InvalidBlockEncoding, error.BlockRlpTooLarge, error.InvalidSignature, error.UnsupportedLegacyV, error.EmptyTransaction, error.InvalidTransactionEnvelope, error.InvalidTransactionFormat, error.UnsupportedTransactionType, error.Overflow => true,
        else => blk: {
            inline for (@typeInfo(evmz.rlp.ParseError).error_set.?) |field| {
                if (err == @field(anyerror, field.name)) break :blk true;
            }
            break :blk false;
        },
    };
}

fn runBlock(
    comptime trace: bool,
    allocator: std.mem.Allocator,
    revision: evmz.eth.Revision,
    source: BlockSource,
    fixture: *const JsonObject,
    entry: *const JsonObject,
    store: *evmz.state.MemoryStore,
    block_hashes: *FixtureBlockHashes,
    parent: *ParentContext,
    capture: ?block_stf.ExecutionCapture,
) !block_stf.Result {
    return switch (revision) {
        inline else => |exact_revision| blk: {
            if (comptime !exact_revision.isImpl(.merge)) return error.UnsupportedFork;
            break :blk switch (source) {
                .payload => runPayloadExact(
                    exact_revision,
                    trace,
                    allocator,
                    fixture,
                    entry,
                    store,
                    block_hashes,
                    parent,
                    capture,
                ),
                .block_body => runBlockBodyExact(
                    exact_revision,
                    trace,
                    allocator,
                    fixture,
                    entry,
                    store,
                    block_hashes,
                    parent,
                    capture,
                ),
            };
        },
    };
}

fn runPayloadExact(
    comptime revision: evmz.eth.Revision,
    comptime trace: bool,
    allocator: std.mem.Allocator,
    fixture: *const JsonObject,
    entry: *const JsonObject,
    store: *evmz.state.MemoryStore,
    block_hashes: *FixtureBlockHashes,
    parent: *ParentContext,
    capture: ?block_stf.ExecutionCapture,
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

    const next_parent = try parentFromPayload(&payload);
    const block_header = block_stf.BlockHeader{
        .number = payload_number,
        .timestamp = try u64Field(&payload, "timestamp"),
        .parent_hash = payload_parent_hash,
        .parent_beacon_block_root = try parentBeaconBlockRoot(params),
    };

    // Reserve before execution so committing the head cannot allocate.
    try block_hashes.entries.ensureUnusedCapacity(allocator, 1);
    const block_hash_source = block_hashes.source();
    const result = try block_stf.Bind(revision, evmz.VmWithOptions(evmz.eth.specAt(revision), .{ .step_capture = trace })).applyAssumeDecoded(scratch, .{
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
        .capture = capture,
    });

    if (result.status == .valid) {
        parent.* = next_parent;
        parent.hash = result.block_hash;
        block_hashes.entries.appendAssumeCapacity(.{ .number = parent.number, .hash = parent.hash });
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
    comptime trace: bool,
    allocator: std.mem.Allocator,
    fixture: *const JsonObject,
    entry: *const JsonObject,
    store: *evmz.state.MemoryStore,
    block_hashes: *FixtureBlockHashes,
    parent: *ParentContext,
    capture: ?block_stf.ExecutionCapture,
) !block_stf.Result {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();

    const block_rlp = try parseBytesFromValue(scratch, entry.get("rlp") orelse return error.MalformedFixture);
    try validateBlockSize(revision, block_rlp.len);
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

    // Reserve before execution so committing the head cannot allocate.
    try block_hashes.entries.ensureUnusedCapacity(allocator, 1);
    const block_hash_source = block_hashes.source();
    const result = try block_stf.Bind(revision, evmz.VmWithOptions(evmz.eth.specAt(revision), .{ .step_capture = trace })).applyAssumeDecoded(scratch, .{
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
        .capture = capture,
    });

    if (result.status == .valid) {
        parent.* = parentFromExecutionHeader(header.*, body.header_hash);
        block_hashes.entries.appendAssumeCapacity(.{ .number = parent.number, .hash = parent.hash });
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
    if (!std.mem.eql(u8, &header_hash, &canonical_hash)) return error.InvalidBlockEncoding;

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

test "block RLP size limit activates at Osaka" {
    try validateBlockSize(.osaka, 1 << 23);
    try std.testing.expectError(error.BlockRlpTooLarge, validateBlockSize(.osaka, (1 << 23) + 1));
    try validateBlockSize(.prague, (1 << 23) + 1);
}
