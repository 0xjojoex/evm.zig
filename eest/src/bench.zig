const std = @import("std");
const evmz = @import("evmz");
const evmone_bench = @import("bench_evmone.zig");
const fixture_common = @import("fixture.zig");

const Address = evmz.Address;
const Executor = evmz.Executor;
const Host = evmz.Host;
const Interpreter = evmz.Interpreter;
const JsonValue = fixture_common.JsonValue;
const transaction = evmz.transaction;

const asArray = fixture_common.asArray;
const asObject = fixture_common.asObject;
const authorizationListLen = fixture_common.authorizationListLen;
const jsonString = fixture_common.jsonString;
const parseAccessListEntry = fixture_common.parseAccessListEntry;
const parseAddress = fixture_common.parseAddress;
const parseAddressFromValue = fixture_common.parseAddressFromValue;
const parseBlobHashes = fixture_common.parseBlobHashes;
const parseBytesFromValue = fixture_common.parseBytesFromValue;
const parseFork = fixture_common.parseBenchmarkFork;
const parseHashFromValue = fixture_common.parseHashFromValue;
const parseHexInt = fixture_common.parseHexInt;
const parseU256FromValue = fixture_common.parseU256FromValue;
const parseU64FromValue = fixture_common.parseU64FromValue;
const seedMemoryBackend = fixture_common.seedMemoryBackend;
const strip0x = fixture_common.strip0x;

pub const Options = struct {
    iterations: usize = 10,
    warmups: usize = 1,
    test_filter: ?[]const u8 = null,
    match_filters: []const []const u8 = &.{},
    max_tests: ?usize = null,
    list_only: bool = false,
    emit_results: bool = false,
    engine: Engine = .evmz,
};

pub const Engine = enum {
    evmz,
    evmone_baseline,
    evmone_advanced,

    pub fn label(self: Engine) []const u8 {
        return switch (self) {
            .evmz => "evmz",
            .evmone_baseline => "evmone-baseline",
            .evmone_advanced => "evmone-advanced",
        };
    }
};

pub const SkipReason = enum(u8) {
    unsupported_fork,
    malformed_fixture,
    create_transaction,
    missing_sender,
    expected_exception,
    missing_post_state,
    unchecked_post_state,
};

pub const FailReason = enum(u8) {
    code_mismatch,
    storage_mismatch,
};

pub const Summary = struct {
    files: usize = 0,
    fixtures: usize = 0,
    benchmarked: usize = 0,
    failed: usize = 0,
    skipped: usize = 0,
    transactions: usize = 0,
    gas_used: u64 = 0,
    elapsed_ns: u64 = 0,
    vm_elapsed_ns: u64 = 0,
    fail_reasons: [std.meta.fields(FailReason).len]usize = [_]usize{0} ** std.meta.fields(FailReason).len,
    skip_reasons: [std.meta.fields(SkipReason).len]usize = [_]usize{0} ** std.meta.fields(SkipReason).len,

    pub fn add(self: *Summary, other: Summary) void {
        self.files += other.files;
        self.fixtures += other.fixtures;
        self.benchmarked += other.benchmarked;
        self.failed += other.failed;
        self.skipped += other.skipped;
        self.transactions += other.transactions;
        self.gas_used += other.gas_used;
        self.elapsed_ns += other.elapsed_ns;
        self.vm_elapsed_ns += other.vm_elapsed_ns;
        for (&self.fail_reasons, other.fail_reasons) |*target, value| {
            target.* += value;
        }
        for (&self.skip_reasons, other.skip_reasons) |*target, value| {
            target.* += value;
        }
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

const ExecuteStats = struct {
    tx_count: usize = 0,
    gas_used: u64 = 0,
    vm_elapsed_ns: u64 = 0,
};

const FixtureResult = struct {
    tx_count: usize,
    gas_used: u64,
    elapsed_ns: u64,
    vm_elapsed_ns: u64,
    opcode_count: ?u64,
};

pub const SelectionLimit = struct {
    remaining: ?usize = null,

    pub fn take(self: *SelectionLimit) bool {
        if (self.remaining) |remaining| {
            if (remaining == 0) return false;
            self.remaining = remaining - 1;
        }
        return true;
    }

    pub fn exhausted(self: SelectionLimit) bool {
        return if (self.remaining) |remaining| remaining == 0 else false;
    }
};

pub fn runFile(io: std.Io, allocator: std.mem.Allocator, path: []const u8, options: Options) !Summary {
    var limit = SelectionLimit{ .remaining = options.max_tests };
    return runFileLimited(io, allocator, path, options, &limit);
}

pub fn runFileLimited(io: std.Io, allocator: std.mem.Allocator, path: []const u8, options: Options, limit: *SelectionLimit) !Summary {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(512 * 1024 * 1024));
    defer allocator.free(bytes);
    var summary = try runSliceLimited(allocator, path, bytes, options, limit);
    summary.files = 1;
    return summary;
}

pub fn runSlice(allocator: std.mem.Allocator, label: []const u8, bytes: []const u8, options: Options) !Summary {
    var limit = SelectionLimit{ .remaining = options.max_tests };
    return runSliceLimited(allocator, label, bytes, options, &limit);
}

pub fn runSliceLimited(allocator: std.mem.Allocator, label: []const u8, bytes: []const u8, options: Options, limit: *SelectionLimit) !Summary {
    if (options.iterations == 0) return error.InvalidIterations;

    var parsed = try std.json.parseFromSlice(JsonValue, allocator, bytes, .{
        .parse_numbers = false,
    });
    defer parsed.deinit();

    var root = asObject(parsed.value) orelse return error.ExpectedObject;
    var summary = Summary{};
    var it = root.iterator();
    while (it.next()) |entry| {
        const test_name = entry.key_ptr.*;
        if (!matchesTest(test_name, options)) continue;
        if (!limit.take()) break;

        summary.fixtures += 1;
        if (options.list_only) {
            if (options.emit_results) printFixtureListItem(label, test_name, entry.value_ptr.*);
            continue;
        }

        const result = runFixture(allocator, entry.value_ptr.*, options) catch |err| {
            switch (err) {
                error.UnsupportedFork => summary.countSkip(.unsupported_fork),
                error.CreateTransaction => summary.countSkip(.create_transaction),
                error.MissingSender => summary.countSkip(.missing_sender),
                error.ExpectedException => summary.countSkip(.expected_exception),
                error.MissingPostState => summary.countSkip(.missing_post_state),
                error.UncheckedPostState => summary.countSkip(.unchecked_post_state),
                error.CodeMismatch => summary.countFail(.code_mismatch),
                error.StorageMismatch => summary.countFail(.storage_mismatch),
                else => summary.countSkip(.malformed_fixture),
            }
            if (options.emit_results) {
                std.debug.print("{s}::{s}: {s}\n", .{ label, test_name, @errorName(err) });
            }
            continue;
        };

        summary.benchmarked += 1;
        summary.transactions += result.tx_count;
        summary.gas_used += result.gas_used;
        summary.elapsed_ns += result.elapsed_ns;
        summary.vm_elapsed_ns += result.vm_elapsed_ns;

        if (options.emit_results) {
            printFixtureResult(label, test_name, result, options);
        }
    }

    return summary;
}

fn matchesTest(test_name: []const u8, options: Options) bool {
    if (options.test_filter) |needle| {
        if (std.mem.indexOf(u8, test_name, needle) == null) return false;
    }
    for (options.match_filters) |needle| {
        if (std.mem.indexOf(u8, test_name, needle) == null) return false;
    }
    return true;
}

fn runFixture(allocator: std.mem.Allocator, fixture: JsonValue, options: Options) !FixtureResult {
    var fixture_obj = asObject(fixture) orelse return error.MalformedFixture;
    const spec = parseFixtureSpec(&fixture_obj) orelse return error.UnsupportedFork;
    const pre = asObject(fixture_obj.get("pre") orelse return error.MalformedFixture) orelse return error.MalformedFixture;

    var runner = try BenchmarkRunner.init(allocator, &pre, spec, options.engine);
    defer runner.deinit();
    try runner.initEngine();

    var initial_state = try runner.executor.snapshot();
    defer initial_state.deinit(allocator);

    const correctness = try runner.executeFixture(&fixture_obj);
    try comparePostState(allocator, &runner, &fixture_obj);

    for (0..options.warmups) |_| {
        try runner.executor.restore(&initial_state);
        _ = try runner.executeFixture(&fixture_obj);
    }

    var measured = ExecuteStats{};
    const start = monotonicNanos();
    for (0..options.iterations) |_| {
        try runner.executor.restore(&initial_state);
        const iteration = try runner.executeFixture(&fixture_obj);
        measured.vm_elapsed_ns += iteration.vm_elapsed_ns;
    }
    const elapsed_ns = monotonicNanos() - start;

    return .{
        .tx_count = correctness.tx_count,
        .gas_used = correctness.gas_used,
        .elapsed_ns = elapsed_ns,
        .vm_elapsed_ns = measured.vm_elapsed_ns,
        .opcode_count = opcodeCount(&fixture_obj),
    };
}

const BenchmarkRunner = struct {
    allocator: std.mem.Allocator,
    backend: *evmz.state.MemoryBackend,
    executor: Executor,
    engine: Engine,
    evmone: ?evmone_bench.Runner = null,

    fn init(allocator: std.mem.Allocator, pre: *const std.json.ObjectMap, spec: evmz.Spec, engine: Engine) !BenchmarkRunner {
        const backend = try allocator.create(evmz.state.MemoryBackend);
        errdefer allocator.destroy(backend);
        backend.* = evmz.state.MemoryBackend.init(allocator);
        errdefer backend.deinit();

        try seedMemoryBackend(allocator, backend, pre);

        return .{
            .allocator = allocator,
            .backend = backend,
            .executor = Executor.initWithBackend(allocator, emptyTxContext(), spec, backend.backend()),
            .engine = engine,
        };
    }

    fn initEngine(self: *BenchmarkRunner) !void {
        self.evmone = switch (self.engine) {
            .evmz => null,
            .evmone_baseline => try evmone_bench.Runner.init(&self.executor, .baseline),
            .evmone_advanced => try evmone_bench.Runner.init(&self.executor, .advanced),
        };
    }

    fn deinit(self: *BenchmarkRunner) void {
        if (self.evmone) |*evmone| evmone.deinit();
        self.executor.deinit();
        self.backend.deinit();
        self.allocator.destroy(self.backend);
    }

    fn executeFixture(self: *BenchmarkRunner, fixture: *const std.json.ObjectMap) !ExecuteStats {
        const blocks = asArray(fixture.get("blocks") orelse return error.MalformedFixture) orelse return error.MalformedFixture;
        var stats = ExecuteStats{};
        for (blocks.items) |block_value| {
            const block = asObject(block_value) orelse return error.MalformedFixture;
            if (block.get("expectException") != null) return error.ExpectedException;
            const header = asObject(block.get("blockHeader") orelse return error.MalformedFixture) orelse return error.MalformedFixture;
            self.executor.tx_context = try parseBlockTxContext(self.executor.spec, &header);
            try evmz.Executor.system_contracts.applyBlockStart(&self.executor, try parseBlockHeader(&header));
            const txs = asArray(block.get("transactions") orelse return error.MalformedFixture) orelse return error.MalformedFixture;
            for (txs.items) |tx_value| {
                const tx = asObject(tx_value) orelse return error.MalformedFixture;
                const tx_stats = try self.executeTransaction(&header, &tx);
                stats.tx_count += 1;
                stats.gas_used += tx_stats.gas_used;
                stats.vm_elapsed_ns += tx_stats.vm_elapsed_ns;
            }
        }
        return stats;
    }

    fn executeTransaction(
        self: *BenchmarkRunner,
        header: *const std.json.ObjectMap,
        tx: *const std.json.ObjectMap,
    ) !ExecuteStats {
        const sender = parseAddressFromValue(tx.get("sender") orelse return error.MissingSender) catch return error.MissingSender;
        const to_value = tx.get("to") orelse return error.CreateTransaction;
        const to_string = jsonString(to_value) orelse return error.CreateTransaction;
        if (strip0x(to_string).len == 0) return error.CreateTransaction;

        const recipient = try parseAddress(to_string);
        const input = try parseBytesFromValue(self.allocator, tx.get("data") orelse return error.MalformedFixture);
        defer self.allocator.free(input);
        const gas_limit = try parseU64FromValue(tx.get("gasLimit") orelse return error.MalformedFixture);
        const value = try parseU256FromValue(tx.get("value") orelse return error.MalformedFixture);
        const blob_hashes = try parseBlobHashes(self.allocator, tx);
        defer self.allocator.free(blob_hashes);

        self.executor.tx_context = try parseTxContext(self.executor.spec, header, tx, sender, blob_hashes);
        try self.executor.beginTransaction(sender, recipient);

        const access_list_counts = try accessListCounts(tx);
        const authorization_count = authorizationListLen(tx);
        const intrinsic_gas = transaction.intrinsicGas(self.executor.spec, input, authorization_count, access_list_counts) orelse std.math.maxInt(u64);
        const minimum_gas = transaction.minimumGas(self.executor.spec, input, authorization_count, access_list_counts) orelse std.math.maxInt(u64);
        const execution_gas = if (gas_limit >= minimum_gas) gas_limit - intrinsic_gas else null;

        const transaction_charged = if (execution_gas != null)
            try self.executor.chargeTransactionCosts(sender, gas_limit, value)
        else
            false;
        if (transaction_charged) {
            try self.executor.incrementNonce(sender);
            try self.processAccessList(tx);
            try self.processAuthorizationList(tx);
        }

        var pre_execution_state = try self.executor.snapshot();
        defer pre_execution_state.deinit(self.allocator);

        var result = Interpreter.Result{
            .status = .out_of_gas,
            .gas_left = 0,
            .gas_refund = 0,
            .output_data = &.{},
        };
        var vm_elapsed_ns: u64 = 0;
        if (execution_gas) |gas| {
            if (!transaction_charged) {
                result.status = .invalid;
            } else {
                const start = monotonicNanos();
                result = switch (self.engine) {
                    .evmz => try self.executor.executeCallTransaction(sender, recipient, input, gas, value),
                    .evmone_baseline, .evmone_advanced => try self.evmone.?.executeCallTransaction(sender, recipient, input, gas, value),
                };
                vm_elapsed_ns = monotonicNanos() - start;
            }
        }

        if (Executor.executionRolledBack(result.status)) {
            try self.executor.restore(&pre_execution_state);
        } else {
            try self.executor.finalizeTransaction();
        }

        const gas_left = if (result.gas_left > 0) @as(u64, @intCast(result.gas_left)) else 0;
        return .{ .tx_count = 1, .gas_used = gas_limit - @min(gas_limit, gas_left), .vm_elapsed_ns = vm_elapsed_ns };
    }

    fn processAccessList(self: *BenchmarkRunner, tx: *const std.json.ObjectMap) !void {
        const list = asArray(tx.get("accessList") orelse return) orelse return error.MalformedFixture;
        for (list.items) |item| {
            const entry = try parseAccessListEntry(item);
            try self.executor.warmAccessListAddress(entry.address);
            for (entry.storage_keys.items) |key_value| {
                const key = try parseU256FromValue(key_value);
                try self.executor.warmAccessListStorage(entry.address, key);
            }
        }
    }

    fn processAuthorizationList(self: *BenchmarkRunner, tx: *const std.json.ObjectMap) !void {
        if (!self.executor.spec.isImpl(.prague)) return;
        const list = asArray(tx.get("authorizationList") orelse return) orelse return error.MalformedFixture;
        for (list.items) |item| {
            const auth = asObject(item) orelse continue;
            const y_parity = parseU256FromValue(auth.get("yParity") orelse auth.get("v") orelse continue) catch continue;
            const legacy_v = if (auth.get("v")) |value| parseU256FromValue(value) catch continue else null;
            const r = parseU256FromValue(auth.get("r") orelse continue) catch continue;
            const s = parseU256FromValue(auth.get("s") orelse continue) catch continue;
            const chain_id = parseU256FromValue(auth.get("chainId") orelse continue) catch continue;
            const target = parseAddressFromValue(auth.get("address") orelse continue) catch continue;
            const signer = parseAddressFromValue(auth.get("signer") orelse continue) catch continue;
            const nonce_value = parseU256FromValue(auth.get("nonce") orelse continue) catch continue;
            const nonce = std.math.cast(u64, nonce_value) orelse continue;
            try self.executor.applyAuthorizationTuple(.{
                .chain_id = chain_id,
                .target = target,
                .signer = signer,
                .nonce = nonce,
                .y_parity = y_parity,
                .legacy_v = legacy_v,
                .r = r,
                .s = s,
            });
        }
    }
};

fn comparePostState(
    allocator: std.mem.Allocator,
    runner: *BenchmarkRunner,
    fixture: *const std.json.ObjectMap,
) !void {
    const post_value = fixture.get("postState") orelse fixture.get("post") orelse return error.MissingPostState;
    var post = asObject(post_value) orelse return error.MalformedFixture;
    var compared_fields: usize = 0;
    var account_it = post.iterator();
    while (account_it.next()) |account_entry| {
        const address = try parseAddress(account_entry.key_ptr.*);
        const expected_account = asObject(account_entry.value_ptr.*) orelse return error.MalformedFixture;
        const actual = try runner.executor.getAccountOrLoad(address);

        if (expected_account.get("code")) |code_value| {
            const expected_code = try parseBytesFromValue(allocator, code_value);
            defer allocator.free(expected_code);
            const actual_code = if (actual) |account| account.code else &.{};
            compared_fields += 1;
            if (!std.mem.eql(u8, actual_code, expected_code)) return error.CodeMismatch;
        }

        if (expected_account.get("storage")) |storage_value| {
            var expected_storage = asObject(storage_value) orelse return error.MalformedFixture;
            var storage_it = expected_storage.iterator();
            while (storage_it.next()) |slot_entry| {
                const key = try parseHexInt(u256, slot_entry.key_ptr.*);
                const expected_value = try parseU256FromValue(slot_entry.value_ptr.*);
                const actual_value = if (actual) |account| account.getStorage(key) else 0;
                compared_fields += 1;
                if (actual_value != expected_value) return error.StorageMismatch;
            }
        }
    }

    if (compared_fields == 0) return error.UncheckedPostState;
}

fn parseTxContext(
    spec: evmz.Spec,
    header: *const std.json.ObjectMap,
    tx: *const std.json.ObjectMap,
    sender: Address,
    blob_hashes: []const u256,
) !Host.TxContext {
    const base_fee = if (header.get("baseFeePerGas")) |value| try parseU256FromValue(value) else 0;
    const gas_price = if (tx.get("gasPrice")) |value|
        try parseU256FromValue(value)
    else if (tx.get("maxFeePerGas")) |value| blk: {
        const max_fee = try parseU256FromValue(value);
        const priority_fee = if (tx.get("maxPriorityFeePerGas")) |priority| try parseU256FromValue(priority) else 0;
        const effective_tip = std.math.add(u256, base_fee, priority_fee) catch std.math.maxInt(u256);
        break :blk @min(max_fee, effective_tip);
    } else 0;

    return Host.TxContext{
        .chain_id = if (tx.get("chainId")) |value| try parseU256FromValue(value) else 1,
        .gas_price = gas_price,
        .origin = sender,
        .coinbase = if (header.get("coinbase")) |value| try parseAddressFromValue(value) else evmz.addr(0),
        .number = if (header.get("number")) |value| try parseU64FromValue(value) else 0,
        .timestamp = if (header.get("timestamp")) |value| try parseU64FromValue(value) else 0,
        .gas_limit = if (header.get("gasLimit")) |value| try parseU64FromValue(value) else 0,
        .prev_randao = if (header.get("mixHash")) |value| try parseU256FromValue(value) else 0,
        .base_fee = base_fee,
        .blob_base_fee = try parseBlobBaseFee(spec, header),
        .blob_hashes = blob_hashes,
    };
}

fn parseBlockTxContext(spec: evmz.Spec, header: *const std.json.ObjectMap) !Host.TxContext {
    const base_fee = if (header.get("baseFeePerGas")) |value| try parseU256FromValue(value) else 0;
    return Host.TxContext{
        .chain_id = 1,
        .gas_price = 0,
        .origin = evmz.addr(0),
        .coinbase = if (header.get("coinbase")) |value| try parseAddressFromValue(value) else evmz.addr(0),
        .number = if (header.get("number")) |value| try parseU64FromValue(value) else 0,
        .timestamp = if (header.get("timestamp")) |value| try parseU64FromValue(value) else 0,
        .gas_limit = if (header.get("gasLimit")) |value| try parseU64FromValue(value) else 0,
        .prev_randao = if (header.get("mixHash")) |value| try parseU256FromValue(value) else 0,
        .base_fee = base_fee,
        .blob_base_fee = try parseBlobBaseFee(spec, header),
        .blob_hashes = &.{},
    };
}

fn parseBlockHeader(header: *const std.json.ObjectMap) !evmz.Executor.system_contracts.BlockHeader {
    return .{
        .number = if (header.get("number")) |value| try parseU64FromValue(value) else 0,
        .timestamp = if (header.get("timestamp")) |value| try parseU64FromValue(value) else 0,
        .parent_hash = if (header.get("parentHash")) |value| try parseHashFromValue(value) else null,
        .parent_beacon_block_root = if (header.get("parentBeaconBlockRoot")) |value| try parseHashFromValue(value) else null,
    };
}

fn parseBlobBaseFee(spec: evmz.Spec, header: *const std.json.ObjectMap) !u256 {
    const excess_blob_gas = if (header.get("excessBlobGas")) |value| try parseU256FromValue(value) else return 0;
    return transaction.blobBaseFeeForSpec(spec, excess_blob_gas) orelse error.Overflow;
}

fn emptyTxContext() Host.TxContext {
    return .{
        .chain_id = 1,
        .gas_price = 0,
        .origin = evmz.addr(0),
        .coinbase = evmz.addr(0),
        .number = 0,
        .timestamp = 0,
        .gas_limit = 0,
        .prev_randao = 0,
        .base_fee = 0,
        .blob_base_fee = 0,
        .blob_hashes = &.{},
    };
}

fn accessListCounts(tx: *const std.json.ObjectMap) !transaction.AccessListCounts {
    var result = transaction.AccessListCounts{};
    const list = asArray(tx.get("accessList") orelse return result) orelse return error.MalformedFixture;
    for (list.items) |item| {
        const entry = try parseAccessListEntry(item);
        result.addresses = std.math.add(usize, result.addresses, 1) catch return error.Overflow;
        for (entry.storage_keys.items) |key_value| {
            _ = try parseU256FromValue(key_value);
            result.storage_keys = std.math.add(usize, result.storage_keys, 1) catch return error.Overflow;
        }
    }
    return result;
}

fn parseFixtureSpec(fixture: *const std.json.ObjectMap) ?evmz.Spec {
    if (fixture.get("network")) |network| {
        if (jsonString(network)) |name| return parseFork(name);
    }
    if (fixture.get("config")) |config_value| {
        const config = asObject(config_value) orelse return null;
        if (config.get("network")) |network| {
            if (jsonString(network)) |name| return parseFork(name);
        }
    }
    return null;
}

fn opcodeCount(fixture: *const std.json.ObjectMap) ?u64 {
    const info = fixture.get("_info") orelse return null;
    return findCount(info);
}

fn findCount(value: JsonValue) ?u64 {
    switch (value) {
        .object => |object| {
            var it = object.iterator();
            while (it.next()) |entry| {
                if (std.ascii.eqlIgnoreCase(entry.key_ptr.*, "opcode_count") or
                    std.ascii.eqlIgnoreCase(entry.key_ptr.*, "opcodeCount"))
                {
                    if (countValue(entry.value_ptr.*)) |count| return count;
                }
                if (findCount(entry.value_ptr.*)) |count| return count;
            }
        },
        .array => |array| {
            for (array.items) |item| {
                if (findCount(item)) |count| return count;
            }
        },
        else => {},
    }
    return null;
}

fn countValue(value: JsonValue) ?u64 {
    if (parseU64Loose(value)) |count| return count;

    var total: u64 = 0;
    var found = false;
    switch (value) {
        .object => |object| {
            var it = object.iterator();
            while (it.next()) |entry| {
                if (countValue(entry.value_ptr.*)) |count| {
                    total = std.math.add(u64, total, count) catch return null;
                    found = true;
                }
            }
        },
        .array => |array| {
            for (array.items) |item| {
                if (countValue(item)) |count| {
                    total = std.math.add(u64, total, count) catch return null;
                    found = true;
                }
            }
        },
        else => {},
    }
    return if (found) total else null;
}

fn parseU64Loose(value: JsonValue) ?u64 {
    return switch (value) {
        .integer => |int| if (int >= 0) @as(u64, @intCast(int)) else null,
        .number_string => |string| parseAnyU64(string) catch null,
        .string => |string| parseAnyU64(string) catch null,
        else => null,
    };
}

fn parseAnyU64(string: []const u8) !u64 {
    const body = strip0x(string);
    if (body.len == 0) return 0;
    if (body.len != string.len) return std.fmt.parseInt(u64, body, 16);
    return std.fmt.parseInt(u64, body, 10);
}

fn monotonicNanos() u64 {
    var ts: std.c.timespec = undefined;
    if (std.c.clock_gettime(.MONOTONIC, &ts) != 0) @panic("clock_gettime failed");
    const sec = @as(u64, @intCast(ts.sec));
    const nsec = @as(u64, @intCast(ts.nsec));
    return sec * std.time.ns_per_s + nsec;
}

fn printFixtureResult(label: []const u8, test_name: []const u8, result: FixtureResult, options: Options) void {
    std.debug.print(
        "{s}::{s}: engine={s} txs={d} gas_used={d} iterations={d} elapsed_ns={d}",
        .{
            label,
            test_name,
            options.engine.label(),
            result.tx_count,
            result.gas_used,
            options.iterations,
            result.elapsed_ns,
        },
    );
    printThroughput(result.gas_used, result.elapsed_ns, options.iterations);
    std.debug.print(" vm_elapsed_ns={d}", .{result.vm_elapsed_ns});
    printVmThroughput(result.gas_used, result.vm_elapsed_ns, options.iterations);
    if (result.opcode_count) |count| {
        std.debug.print(" opcode_count={d}", .{count});
    } else {
        std.debug.print(" opcode_count=unknown", .{});
    }
    std.debug.print("\n", .{});
}

fn printFixtureListItem(label: []const u8, test_name: []const u8, fixture: JsonValue) void {
    std.debug.print("{s}::{s}", .{ label, test_name });
    if (asObject(fixture)) |fixture_obj| {
        if (opcodeCount(&fixture_obj)) |count| {
            std.debug.print(" opcode_count={d}", .{count});
        }
    }
    std.debug.print("\n", .{});
}

pub fn printThroughput(gas_used: u64, elapsed_ns: u64, iterations: usize) void {
    const measured_gas_used = measuredGasUsed(gas_used, iterations);
    if (milliMgasPerSecond(gas_used, elapsed_ns, iterations)) |milli_mgas_per_s| {
        std.debug.print(
            " measured_gas_used={d} mgas_per_s={d}.{d:0>3}",
            .{ measured_gas_used, milli_mgas_per_s / 1000, milli_mgas_per_s % 1000 },
        );
    } else {
        std.debug.print(" measured_gas_used={d} mgas_per_s=unknown", .{measured_gas_used});
    }
}

pub fn printVmThroughput(gas_used: u64, elapsed_ns: u64, iterations: usize) void {
    if (milliMgasPerSecond(gas_used, elapsed_ns, iterations)) |milli_mgas_per_s| {
        std.debug.print(
            " vm_mgas_per_s={d}.{d:0>3}",
            .{ milli_mgas_per_s / 1000, milli_mgas_per_s % 1000 },
        );
    } else {
        std.debug.print(" vm_mgas_per_s=unknown", .{});
    }
}

pub fn measuredGasUsed(gas_used: u64, iterations: usize) u128 {
    return @as(u128, gas_used) * @as(u128, iterations);
}

pub fn milliMgasPerSecond(gas_used: u64, elapsed_ns: u64, iterations: usize) ?u128 {
    if (elapsed_ns == 0) {
        return null;
    }

    return measuredGasUsed(gas_used, iterations) * 1_000_000 / elapsed_ns;
}

test "throughput includes measured iterations" {
    try std.testing.expectEqual(@as(u128, 200), measuredGasUsed(100, 2));
    try std.testing.expectEqual(@as(?u128, 20_000), milliMgasPerSecond(100, 10_000, 2));
    try std.testing.expectEqual(@as(?u128, null), milliMgasPerSecond(100, 0, 2));
}

test "benchmark listing respects match filters and max tests" {
    const fixture =
        \\{
        \\  "case_opcode_MSTORE_offset_0": {
        \\    "_info": { "opcode_count": 11 }
        \\  },
        \\  "case_opcode_MSTORE_offset_1": {
        \\    "_info": { "opcode_count": 13 }
        \\  },
        \\  "case_opcode_MLOAD_offset_0": {
        \\    "_info": { "opcode_count": 17 }
        \\  }
        \\}
    ;
    const filters = [_][]const u8{ "opcode_MSTORE", "offset_0" };

    const summary = try runSlice(std.testing.allocator, "fixture.json", fixture, .{
        .match_filters = filters[0..],
        .max_tests = 1,
        .list_only = true,
    });
    try std.testing.expectEqual(@as(usize, 1), summary.fixtures);
    try std.testing.expectEqual(@as(usize, 0), summary.benchmarked);
    try std.testing.expectEqual(@as(usize, 0), summary.failed);
    try std.testing.expectEqual(@as(usize, 0), summary.skipped);
}

test "runs a minimal EEST benchmark blockchain fixture" {
    const fixture =
        \\{
        \\  "bench_sstore": {
        \\    "network": "Prague",
        \\    "_info": { "opcode_count": 5 },
        \\    "pre": {
        \\      "0x0000000000000000000000000000000000001000": {
        \\        "balance": "0x00",
        \\        "nonce": "0x00",
        \\        "code": "0x602a600055",
        \\        "storage": {}
        \\      },
        \\      "0x000000000000000000000000000000000000aaaa": {
        \\        "balance": "0xffffffffffff",
        \\        "nonce": "0x00",
        \\        "code": "0x",
        \\        "storage": {}
        \\      }
        \\    },
        \\    "blocks": [{
        \\      "blockHeader": {
        \\        "coinbase": "0x0000000000000000000000000000000000000000",
        \\        "gasLimit": "0x030d40",
        \\        "number": "0x01",
        \\        "timestamp": "0x00",
        \\        "baseFeePerGas": "0x00",
        \\        "mixHash": "0x00"
        \\      },
        \\      "transactions": [{
        \\        "sender": "0x000000000000000000000000000000000000aaaa",
        \\        "to": "0x0000000000000000000000000000000000001000",
        \\        "gasLimit": "0x0186a0",
        \\        "gasPrice": "0x00",
        \\        "value": "0x00",
        \\        "data": "0x"
        \\      }]
        \\    }],
        \\    "postState": {
        \\      "0x0000000000000000000000000000000000001000": {
        \\        "storage": { "0x00": "0x2a" }
        \\      }
        \\    }
        \\  }
        \\}
    ;

    const summary = try runSlice(std.testing.allocator, "fixture.json", fixture, .{
        .iterations = 2,
        .warmups = 1,
    });
    try std.testing.expectEqual(@as(usize, 1), summary.fixtures);
    try std.testing.expectEqual(@as(usize, 1), summary.benchmarked);
    try std.testing.expectEqual(@as(usize, 1), summary.transactions);
    try std.testing.expectEqual(@as(usize, 0), summary.failed);
    try std.testing.expectEqual(@as(usize, 0), summary.skipped);

    const evmone_summary = try runSlice(std.testing.allocator, "fixture.json", fixture, .{
        .iterations = 1,
        .warmups = 0,
        .engine = .evmone_advanced,
    });
    try std.testing.expectEqual(@as(usize, 1), evmone_summary.fixtures);
    try std.testing.expectEqual(@as(usize, 1), evmone_summary.benchmarked);
    try std.testing.expectEqual(@as(usize, 1), evmone_summary.transactions);
    try std.testing.expectEqual(@as(usize, 0), evmone_summary.failed);
    try std.testing.expectEqual(@as(usize, 0), evmone_summary.skipped);
}

test "evmone benchmark host supports CREATE callbacks" {
    const fixture =
        \\{
        \\  "bench_create": {
        \\    "network": "Prague",
        \\    "_info": { "opcode_count": 8 },
        \\    "pre": {
        \\      "0x0000000000000000000000000000000000001000": {
        \\        "balance": "0x00",
        \\        "nonce": "0x00",
        \\        "code": "0x600160006000f0151560005500",
        \\        "storage": {}
        \\      },
        \\      "0x000000000000000000000000000000000000aaaa": {
        \\        "balance": "0xffffffffffff",
        \\        "nonce": "0x00",
        \\        "code": "0x",
        \\        "storage": {}
        \\      }
        \\    },
        \\    "blocks": [{
        \\      "blockHeader": {
        \\        "coinbase": "0x0000000000000000000000000000000000000000",
        \\        "gasLimit": "0x030d40",
        \\        "number": "0x01",
        \\        "timestamp": "0x00",
        \\        "baseFeePerGas": "0x00",
        \\        "mixHash": "0x00"
        \\      },
        \\      "transactions": [{
        \\        "sender": "0x000000000000000000000000000000000000aaaa",
        \\        "to": "0x0000000000000000000000000000000000001000",
        \\        "gasLimit": "0x030d40",
        \\        "gasPrice": "0x00",
        \\        "value": "0x00",
        \\        "data": "0x"
        \\      }]
        \\    }],
        \\    "postState": {
        \\      "0x0000000000000000000000000000000000001000": {
        \\        "storage": { "0x00": "0x01" }
        \\      }
        \\    }
        \\  }
        \\}
    ;

    const summary = try runSlice(std.testing.allocator, "fixture.json", fixture, .{
        .iterations = 1,
        .warmups = 0,
        .engine = .evmone_advanced,
    });
    try std.testing.expectEqual(@as(usize, 1), summary.fixtures);
    try std.testing.expectEqual(@as(usize, 1), summary.benchmarked);
    try std.testing.expectEqual(@as(usize, 1), summary.transactions);
    try std.testing.expectEqual(@as(usize, 0), summary.failed);
    try std.testing.expectEqual(@as(usize, 0), summary.skipped);
}
