const std = @import("std");
const evmz = @import("evmz");
const evmone_bench = @import("bench_evmone.zig");
const fixture_common = @import("fixture.zig");

const Address = evmz.Address;
const Host = evmz.Host;
const Interpreter = evmz.Interpreter;
const JsonValue = fixture_common.JsonValue;
const transaction = evmz.transaction;
const EthProtocol = evmz.EthProtocol;
const Executor = evmz.Executor(EthProtocol);
const tx_protocol = transaction.For(EthProtocol);

const asArray = fixture_common.asArray;
const asObject = fixture_common.asObject;
const jsonString = fixture_common.jsonString;
const parseAddress = fixture_common.parseAddress;
const parseAddressFromValue = fixture_common.parseAddressFromValue;
const parseBlobHashes = fixture_common.parseBlobHashes;
const parseBytesFromValue = fixture_common.parseBytesFromValue;
const parseFork = fixture_common.parseBenchmarkFork;
const parseHashFromValue = fixture_common.parseHashFromValue;
const parseHexInt = fixture_common.parseHexInt;
const parseTransactionAccessListFromValue = fixture_common.parseTransactionAccessListFromValue;
const parseTransactionAuthorizationList = fixture_common.parseTransactionAuthorizationList;
const parseU256FromValue = fixture_common.parseU256FromValue;
const parseU64FromValue = fixture_common.parseU64FromValue;
const rejectUnknownKeys = fixture_common.rejectUnknownKeys;
const seedMemoryStore = fixture_common.seedMemoryStore;
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
    missing_sender,
    expected_exception,
    missing_post_state,
    unchecked_post_state,
};

pub const FailReason = enum(u8) {
    code_mismatch,
    storage_mismatch,
    balance_mismatch,
    nonce_mismatch,
    transaction_nonce_mismatch,
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
                error.MissingSender => summary.countSkip(.missing_sender),
                error.ExpectedException => summary.countSkip(.expected_exception),
                error.MissingPostState => summary.countSkip(.missing_post_state),
                error.UncheckedPostState => summary.countSkip(.unchecked_post_state),
                error.CodeMismatch => summary.countFail(.code_mismatch),
                error.StorageMismatch => summary.countFail(.storage_mismatch),
                error.BalanceMismatch => summary.countFail(.balance_mismatch),
                error.NonceMismatch => summary.countFail(.nonce_mismatch),
                error.TransactionNonceMismatch => summary.countFail(.transaction_nonce_mismatch),
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
    const revision = parseFixtureSpec(&fixture_obj) orelse return error.UnsupportedFork;
    const pre = asObject(fixture_obj.get("pre") orelse return error.MalformedFixture) orelse return error.MalformedFixture;

    var runner = try BenchmarkRunner.init(allocator, &pre, revision, options.engine);
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
    store: *evmz.state.MemoryStore,
    executor: Executor,
    engine: Engine,
    evmone: ?evmone_bench.Runner = null,

    fn init(allocator: std.mem.Allocator, pre: *const std.json.ObjectMap, revision: evmz.eth.Revision, engine: Engine) !BenchmarkRunner {
        const store = try allocator.create(evmz.state.MemoryStore);
        errdefer allocator.destroy(store);
        store.* = evmz.state.MemoryStore.init(allocator);
        errdefer store.deinit();

        try seedMemoryStore(allocator, store, pre);

        return .{
            .allocator = allocator,
            .store = store,
            .executor = Executor.init(allocator, .{
                .revision = revision,
                .state_reader = store.reader(),
            }),
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
        self.store.deinit();
        self.allocator.destroy(self.store);
    }

    fn executeFixture(self: *BenchmarkRunner, fixture: *const std.json.ObjectMap) !ExecuteStats {
        const blocks = asArray(fixture.get("blocks") orelse return error.MalformedFixture) orelse return error.MalformedFixture;
        var stats = ExecuteStats{};
        for (blocks.items) |block_value| {
            const block = asObject(block_value) orelse return error.MalformedFixture;
            if (block.get("expectException") != null) return error.ExpectedException;
            const header = asObject(block.get("blockHeader") orelse return error.MalformedFixture) orelse return error.MalformedFixture;
            const revision = self.executor.revision();
            try evmz.executor.system_contracts.applyBlockStart(
                &self.executor,
                try parseBlockTxContext(revision, &header),
                try parseBlockHeader(&header),
            );
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
        const to_string = jsonString(tx.get("to") orelse return error.MalformedFixture) orelse return error.MalformedFixture;
        const is_create = strip0x(to_string).len == 0;
        const recipient = if (is_create) null else try parseAddress(to_string);
        const input = try parseBytesFromValue(self.allocator, tx.get("data") orelse return error.MalformedFixture);
        defer self.allocator.free(input);
        const gas_limit = try parseU64FromValue(tx.get("gasLimit") orelse return error.MalformedFixture);
        const value = try parseU256FromValue(tx.get("value") orelse return error.MalformedFixture);
        var access_list = try parseTransactionAccessListFromValue(self.allocator, tx.get("accessList"));
        defer access_list.deinit(self.allocator);
        var authorization_list = try parseTransactionAuthorizationList(self.allocator, tx, .error_malformed_list);
        defer authorization_list.deinit(self.allocator);
        const root = if (is_create)
            transaction.RootFrame{ .create = .{
                .sender = sender,
                .init_code = input,
                .gas_limit = gas_limit,
                .value = value,
            } }
        else
            transaction.RootFrame{ .call = .{
                .sender = sender,
                .recipient = recipient.?,
                .input = input,
                .gas_limit = gas_limit,
                .value = value,
            } };
        const blob_hashes = try parseBlobHashes(self.allocator, tx);
        defer self.allocator.free(blob_hashes);
        if (tx.get("nonce")) |nonce_value| {
            const tx_nonce = try parseU64FromValue(nonce_value);
            const sender_account = try self.executor.getAccountOrLoad(sender);
            const sender_nonce = if (sender_account) |account| account.nonce else 0;
            if (sender_nonce != tx_nonce) return error.TransactionNonceMismatch;
        }
        const is_self_transfer = !is_create and std.mem.eql(u8, &sender, &recipient.?);
        const creates_account = if (!is_create and value != 0 and !is_self_transfer)
            (try self.executor.getAccountOrLoad(recipient.?)) == null
        else
            false;

        const revision = self.executor.revision();
        const tx_context = try parseTxContext(revision, header, tx, sender, blob_hashes);
        const scope = Executor.transactionScope(tx_context, .{
            .access_list = access_list.entries,
            .authorization_list = authorization_list.entries,
            .authorization_count = authorization_list.count,
        });
        try self.executor.beginTransactionScope(scope, root);
        errdefer self.executor.closeTransaction();

        const access_list_counts = transaction.accessListCounts(access_list.entries);
        const intrinsic_options = transaction.IntrinsicGasOptions{
            .authorization_count = authorization_list.count,
            .access_list_counts = access_list_counts,
            .is_create = is_create,
            .value = value,
            .is_self_transfer = is_self_transfer,
            .creates_account = creates_account,
        };
        const gas_plan = tx_protocol.gas.gasPlan(revision, input, gas_limit, intrinsic_options);
        const base_fee = if (header.get("baseFeePerGas")) |base_fee_value| try parseU256FromValue(base_fee_value) else 0;
        const settlement = try transactionSettlement(
            revision,
            tx,
            sender,
            gas_limit,
            gas_plan,
            value,
            tx_context.gas_price,
            tx_context.coinbase,
            base_fee,
            tx_context.blob_base_fee,
            tx_context.blob_hashes.len,
        );

        var timed_engine = TimedTransactionEngine{ .runner = self };
        const result = try self.executor.runTopLevelTransactionWithEngine(scope, root, .{
            .execution = gas_plan.execution,
            .settlement = settlement,
        }, timed_engine.engine());

        const costs = try tx_protocol.settlement.planCosts(settlement, .{
            .gas_left = result.gas_left,
            .gas_refund = result.gas_refund,
            .gas_reservoir = result.gas_reservoir,
            .state_gas_spent = result.state_gas_spent,
        });
        return .{ .tx_count = 1, .gas_used = costs.gas.used, .vm_elapsed_ns = timed_engine.elapsed_ns };
    }

    const TimedTransactionEngine = struct {
        runner: *BenchmarkRunner,
        elapsed_ns: u64 = 0,

        fn engine(self: *TimedTransactionEngine) Executor.TransactionEngine {
            return .{ .ptr = self, .execute = execute };
        }

        fn execute(
            ptr: ?*anyopaque,
            executor: *Executor,
            tx: transaction.RootFrame,
            gas: transaction.ExecutionGas,
        ) !Interpreter.Result {
            const self: *TimedTransactionEngine = @ptrCast(@alignCast(ptr.?));
            const start = monotonicNanos();
            const result = switch (self.runner.engine) {
                .evmz => try executor.executeTransactionMessage(tx, gas),
                .evmone_baseline, .evmone_advanced => switch (tx) {
                    .call => |call_tx| try self.runner.evmone.?.executeCallTransaction(
                        call_tx.sender,
                        call_tx.recipient,
                        call_tx.input,
                        gas.regular_left,
                        call_tx.value,
                    ),
                    .create => |create_tx| try self.runner.evmone.?.executeCreateTransaction(
                        create_tx.sender,
                        create_tx.init_code,
                        gas.regular_left,
                        create_tx.value,
                    ),
                },
            };
            self.elapsed_ns += monotonicNanos() - start;
            return result;
        }
    };
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
        try rejectUnknownKeys(&expected_account, &.{ "balance", "nonce", "code", "storage" });
        const actual = try runner.executor.getAccountOrLoad(address);

        if (expected_account.get("balance")) |balance_value| {
            const expected_balance = try parseU256FromValue(balance_value);
            const actual_balance = if (actual) |account| account.balance else 0;
            compared_fields += 1;
            if (actual_balance != expected_balance) return error.BalanceMismatch;
        }

        if (expected_account.get("nonce")) |nonce_value| {
            const expected_nonce = try parseU64FromValue(nonce_value);
            const actual_nonce = if (actual) |account| account.nonce else 0;
            compared_fields += 1;
            if (actual_nonce != expected_nonce) return error.NonceMismatch;
        }

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
                const actual_value = try runner.executor.getStorage(address, key);
                compared_fields += 1;
                if (actual_value != expected_value) return error.StorageMismatch;
            }
        }
    }

    if (compared_fields == 0) return error.UncheckedPostState;
}

fn transactionSettlement(
    revision: evmz.eth.Revision,
    tx: *const std.json.ObjectMap,
    sender: Address,
    gas_limit: u64,
    gas_plan: transaction.GasPlan,
    value: u256,
    gas_price: u256,
    coinbase: Address,
    base_fee: u256,
    blob_base_fee: u256,
    blob_count: usize,
) !transaction.Settlement {
    return tx_protocol.settlement.settlementFromGasPlan(revision, gas_limit, gas_plan, .{
        .gas_price = gas_price,
        .priority_fee = tx_protocol.settlement.effectivePriorityFee(revision, .{
            .gas_price = gas_price,
            .base_fee = base_fee,
            .max_fee_per_gas = if (tx.get("maxFeePerGas")) |field_value| try parseU256FromValue(field_value) else null,
            .max_priority_fee_per_gas = if (tx.get("maxPriorityFeePerGas")) |field_value| try parseU256FromValue(field_value) else null,
        }),
        .coinbase = coinbase,
        .payer = sender,
        .value = value,
        .blob_base_fee = blob_base_fee,
        .blob_count = blob_count,
    });
}

fn parseTxContext(
    revision: evmz.eth.Revision,
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
        .blob_base_fee = try parseBlobBaseFee(revision, header),
        .blob_hashes = blob_hashes,
    };
}

fn parseBlockTxContext(revision: evmz.eth.Revision, header: *const std.json.ObjectMap) !Host.TxContext {
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
        .blob_base_fee = try parseBlobBaseFee(revision, header),
        .blob_hashes = &.{},
    };
}

fn parseBlockHeader(header: *const std.json.ObjectMap) !evmz.executor.system_contracts.BlockHeader {
    return .{
        .number = if (header.get("number")) |value| try parseU64FromValue(value) else 0,
        .timestamp = if (header.get("timestamp")) |value| try parseU64FromValue(value) else 0,
        .parent_hash = if (header.get("parentHash")) |value| try parseHashFromValue(value) else null,
        .parent_beacon_block_root = if (header.get("parentBeaconBlockRoot")) |value| try parseHashFromValue(value) else null,
    };
}

fn parseBlobBaseFee(revision: evmz.eth.Revision, header: *const std.json.ObjectMap) !u256 {
    const excess_blob_gas = if (header.get("excessBlobGas")) |value| try parseU256FromValue(value) else return 0;
    return tx_protocol.blob.blobBaseFeeForRevision(revision, excess_blob_gas) orelse error.Overflow;
}

fn parseFixtureSpec(fixture: *const std.json.ObjectMap) ?evmz.eth.Revision {
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

fn runMinimalBenchmarkFixture(tx_extra: []const u8, post_account_fields: []const u8) !Summary {
    const fixture = try std.mem.concat(std.testing.allocator, u8, &.{
        "{\"bench_stop\":{\"network\":\"Prague\",\"_info\":{\"opcode_count\":1},\"pre\":{\"0x0000000000000000000000000000000000001000\":{\"balance\":\"0x00\",\"nonce\":\"0x00\",\"code\":\"0x00\",\"storage\":{}},\"0x000000000000000000000000000000000000aaaa\":{\"balance\":\"0xffffffffffff\",\"nonce\":\"0x00\",\"code\":\"0x\",\"storage\":{}}},\"blocks\":[{\"blockHeader\":{\"coinbase\":\"0x0000000000000000000000000000000000000000\",\"gasLimit\":\"0x030d40\",\"number\":\"0x01\",\"timestamp\":\"0x00\",\"baseFeePerGas\":\"0x00\",\"mixHash\":\"0x00\"},\"transactions\":[{\"sender\":\"0x000000000000000000000000000000000000aaaa\",\"to\":\"0x0000000000000000000000000000000000001000\",\"gasLimit\":\"0x0186a0\",\"gasPrice\":\"0x00\",\"value\":\"0x00\",\"data\":\"0x\"",
        tx_extra,
        "}]}],\"postState\":{\"0x0000000000000000000000000000000000001000\":{",
        post_account_fields,
        "}}}}",
    });
    defer std.testing.allocator.free(fixture);
    return runSlice(std.testing.allocator, "fixture.json", fixture, .{ .iterations = 1, .warmups = 0 });
}

test "benchmark transaction nonce mismatch fails" {
    const summary = try runMinimalBenchmarkFixture(",\"nonce\":\"0x01\"", "\"code\":\"0x00\"");
    try std.testing.expectEqual(@as(usize, 1), summary.failed);
    try std.testing.expectEqual(@as(usize, 1), summary.fail_reasons[@intFromEnum(FailReason.transaction_nonce_mismatch)]);
}

test "benchmark post balance and nonce mismatches fail" {
    const balance = try runMinimalBenchmarkFixture("", "\"balance\":\"0x01\"");
    try std.testing.expectEqual(@as(usize, 1), balance.failed);
    try std.testing.expectEqual(@as(usize, 1), balance.fail_reasons[@intFromEnum(FailReason.balance_mismatch)]);

    const nonce = try runMinimalBenchmarkFixture("", "\"nonce\":\"0x01\"");
    try std.testing.expectEqual(@as(usize, 1), nonce.failed);
    try std.testing.expectEqual(@as(usize, 1), nonce.fail_reasons[@intFromEnum(FailReason.nonce_mismatch)]);
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

test "runs a top-level CREATE benchmark transaction" {
    const sender = evmz.addr(0xaaaa);
    const created = evmz.address.create(sender, 0);
    var created_buf: [42]u8 = undefined;
    const created_hex = try formatAddressHex(&created_buf, created);
    const fixture = try std.fmt.allocPrint(std.testing.allocator,
        \\{{
        \\  "bench_top_level_create": {{
        \\    "network": "Prague",
        \\    "_info": {{ "opcode_count": 5 }},
        \\    "pre": {{
        \\      "0x000000000000000000000000000000000000aaaa": {{
        \\        "balance": "0xffffffffffff",
        \\        "nonce": "0x00",
        \\        "code": "0x",
        \\        "storage": {{}}
        \\      }}
        \\    }},
        \\    "blocks": [{{
        \\      "blockHeader": {{
        \\        "coinbase": "0x0000000000000000000000000000000000000000",
        \\        "gasLimit": "0x030d40",
        \\        "number": "0x01",
        \\        "timestamp": "0x00",
        \\        "baseFeePerGas": "0x00",
        \\        "mixHash": "0x00"
        \\      }},
        \\      "transactions": [{{
        \\        "sender": "0x000000000000000000000000000000000000aaaa",
        \\        "to": "0x",
        \\        "gasLimit": "0x030d40",
        \\        "gasPrice": "0x00",
        \\        "value": "0x00",
        \\        "data": "0x600060005360016000f3"
        \\      }}]
        \\    }}],
        \\    "postState": {{
        \\      "{s}": {{
        \\        "code": "0x00"
        \\      }}
        \\    }}
        \\  }}
        \\}}
    , .{created_hex});
    defer std.testing.allocator.free(fixture);

    for ([_]Engine{ .evmz, .evmone_advanced }) |engine| {
        const summary = try runSlice(std.testing.allocator, "fixture.json", fixture, .{
            .iterations = 1,
            .warmups = 0,
            .engine = engine,
        });
        try std.testing.expectEqual(@as(usize, 1), summary.fixtures);
        try std.testing.expectEqual(@as(usize, 1), summary.benchmarked);
        try std.testing.expectEqual(@as(usize, 1), summary.transactions);
        try std.testing.expectEqual(@as(usize, 0), summary.failed);
        try std.testing.expectEqual(@as(usize, 0), summary.skipped);
    }
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

fn formatAddressHex(buffer: *[42]u8, address: Address) ![]const u8 {
    const hex = std.fmt.bytesToHex(address, .lower);
    return std.fmt.bufPrint(buffer, "0x{s}", .{&hex});
}
