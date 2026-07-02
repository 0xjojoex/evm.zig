const std = @import("std");
const evmz = @import("evmz");
const fixture_common = @import("fixture.zig");
const tx_validation = @import("tx_validation.zig");

const Address = evmz.Address;
const JsonValue = fixture_common.JsonValue;
const transaction = evmz.transaction;
const Vm = evmz.Vm;

const asArray = fixture_common.asArray;
const asObject = fixture_common.asObject;
const jsonString = fixture_common.jsonString;
const parseAddress = fixture_common.parseAddress;
const parseAddressFromValue = fixture_common.parseAddressFromValue;
const parseBlobHashes = fixture_common.parseBlobHashes;
const parseBytesFromValue = fixture_common.parseBytesFromValue;
const parseFork = fixture_common.parseStateFork;
const parseTransactionAccessList = fixture_common.parseTransactionAccessList;
const parseTransactionAuthorizationList = fixture_common.parseTransactionAuthorizationList;
const parseHexInt = fixture_common.parseHexInt;
const parseU256FromValue = fixture_common.parseU256FromValue;
const parseU64FromValue = fixture_common.parseU64FromValue;
const rejectUnknownKeys = fixture_common.rejectUnknownKeys;
const seedMemoryStore = fixture_common.seedMemoryStore;
const strip0x = fixture_common.strip0x;

pub const Options = struct {
    fork_filter: ?[]const u8 = null,
    test_filter: ?[]const u8 = null,
};

pub const FailReason = enum(u8) {
    unsupported_fork,
    malformed_fixture,
    missing_sender,
    unexpected_status,
    output_mismatch,
    code_mismatch,
    storage_mismatch,
    expected_transaction_exception,
    transaction_nonce_mismatch,
    balance_mismatch,
    nonce_mismatch,
    unsupported_fixture_key,
};

pub const UncheckedReason = enum(u8) {
    missing_post_state,
    no_comparable_fields,
    unsupported_assertion_fields,
};

pub const Summary = struct {
    fixtures: usize = 0,
    vectors: usize = 0,
    passed: usize = 0,
    failed: usize = 0,
    skipped: usize = 0,
    unchecked: usize = 0,
    fail_reasons: [std.meta.fields(FailReason).len]usize = [_]usize{0} ** std.meta.fields(FailReason).len,
    unchecked_reasons: [std.meta.fields(UncheckedReason).len]usize = [_]usize{0} ** std.meta.fields(UncheckedReason).len,

    pub fn add(self: *Summary, other: Summary) void {
        self.fixtures += other.fixtures;
        self.vectors += other.vectors;
        self.passed += other.passed;
        self.failed += other.failed;
        self.skipped += other.skipped;
        self.unchecked += other.unchecked;
        for (&self.fail_reasons, other.fail_reasons) |*target, value| {
            target.* += value;
        }
        for (&self.unchecked_reasons, other.unchecked_reasons) |*target, value| {
            target.* += value;
        }
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
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(256 * 1024 * 1024));
    defer allocator.free(bytes);
    return runSlice(allocator, bytes, options);
}

pub fn runSlice(allocator: std.mem.Allocator, bytes: []const u8, options: Options) !Summary {
    var parsed = try std.json.parseFromSlice(JsonValue, allocator, bytes, .{
        .parse_numbers = false,
    });
    defer parsed.deinit();

    var root = asObject(parsed.value) orelse return error.ExpectedObject;
    var summary = Summary{};
    var it = root.iterator();
    while (it.next()) |entry| {
        const test_name = entry.key_ptr.*;
        if (options.test_filter) |needle| {
            if (std.mem.indexOf(u8, test_name, needle) == null) continue;
        }

        summary.fixtures += 1;
        runFixture(allocator, test_name, entry.value_ptr.*, options, &summary) catch |err| {
            summary.vectors += 1;
            summary.countFail(switch (err) {
                error.UnsupportedFixtureKey => .unsupported_fixture_key,
                else => .malformed_fixture,
            });
        };
    }

    return summary;
}

fn runFixture(
    allocator: std.mem.Allocator,
    test_name: []const u8,
    fixture: JsonValue,
    options: Options,
    summary: *Summary,
) !void {
    _ = test_name;

    var fixture_obj = asObject(fixture) orelse return error.MalformedFixture;
    try rejectUnknownKeys(&fixture_obj, &.{ "env", "pre", "transaction", "post", "config", "_info" });
    var post_obj = asObject(fixture_obj.get("post") orelse return error.MalformedFixture) orelse return error.MalformedFixture;

    var fork_it = post_obj.iterator();
    while (fork_it.next()) |fork_entry| {
        const fork_name = fork_entry.key_ptr.*;
        if (options.fork_filter) |filter| {
            if (!std.ascii.eqlIgnoreCase(fork_name, filter)) continue;
        }

        const vectors = asArray(fork_entry.value_ptr.*) orelse return error.MalformedFixture;
        const spec = parseFork(fork_name) orelse {
            for (vectors.items) |_| {
                summary.vectors += 1;
                summary.countFail(.unsupported_fork);
            }
            continue;
        };

        for (vectors.items) |post| {
            summary.vectors += 1;
            runVector(allocator, &fixture_obj, post, spec, summary) catch |err| {
                summary.countFail(switch (err) {
                    error.UnsupportedFixtureKey => .unsupported_fixture_key,
                    else => .malformed_fixture,
                });
            };
        }
    }
}

fn runVector(
    allocator: std.mem.Allocator,
    fixture: *const std.json.ObjectMap,
    post: JsonValue,
    spec: evmz.Spec,
    summary: *Summary,
) !void {
    const post_obj = asObject(post) orelse return error.MalformedFixture;
    try rejectUnknownKeys(&post_obj, &.{ "hash", "logs", "txbytes", "indexes", "state", "expectException" });
    const expected_exception = if (post_obj.get("expectException")) |value|
        jsonString(value) orelse return error.MalformedFixture
    else
        null;

    const tx = asObject(fixture.get("transaction") orelse return error.MalformedFixture) orelse return error.MalformedFixture;
    const env = asObject(fixture.get("env") orelse return error.MalformedFixture) orelse return error.MalformedFixture;
    const pre = asObject(fixture.get("pre") orelse return error.MalformedFixture) orelse return error.MalformedFixture;
    const indexes = asObject(post_obj.get("indexes") orelse return error.MalformedFixture) orelse return error.MalformedFixture;
    try rejectUnknownKeys(&tx, &.{
        "nonce",
        "gasLimit",
        "to",
        "value",
        "data",
        "sender",
        "secretKey",
        "gasPrice",
        "accessLists",
        "maxPriorityFeePerGas",
        "maxFeePerGas",
        "maxFeePerBlobGas",
        "blobVersionedHashes",
        "authorizationList",
    });
    try rejectUnknownKeys(&env, &.{
        "currentCoinbase",
        "currentGasLimit",
        "currentNumber",
        "currentTimestamp",
        "currentDifficulty",
        "currentBaseFee",
        "currentRandom",
        "currentExcessBlobGas",
        "currentBlobBaseFee",
        "currentChainId",
    });
    try rejectUnknownKeys(&indexes, &.{ "data", "gas", "value" });
    const config = try parseFixtureConfig(fixture, spec);

    const data_index = try jsonIndex(indexes.get("data") orelse return error.MalformedFixture);
    const gas_index = try jsonIndex(indexes.get("gas") orelse return error.MalformedFixture);
    const value_index = try jsonIndex(indexes.get("value") orelse return error.MalformedFixture);

    const to_string = jsonString(tx.get("to") orelse return error.MalformedFixture) orelse return error.MalformedFixture;
    const is_create = strip0x(to_string).len == 0;

    const sender_string = jsonString(tx.get("sender") orelse {
        summary.countFail(.missing_sender);
        return;
    }) orelse return error.MalformedFixture;

    const sender = try parseAddress(sender_string);
    const input = try selectedBytes(allocator, &tx, "data", data_index);
    defer allocator.free(input);
    var access_list = if (try selectedAccessList(&tx, data_index)) |list|
        try parseTransactionAccessList(allocator, list)
    else
        fixture_common.ParsedAccessList{};
    defer access_list.deinit(allocator);
    var authorization_list = try parseTransactionAuthorizationList(allocator, &tx, .ignore_malformed_list);
    defer authorization_list.deinit(allocator);

    const gas_limit = try selectedU64(&tx, "gasLimit", gas_index);
    const value = try selectedU256(&tx, "value", value_index);
    const blob_hashes = try parseBlobHashes(allocator, &tx);
    defer allocator.free(blob_hashes);
    const recipient = if (is_create) null else try parseAddress(to_string);
    const vm_env = try parseVmEnv(spec, &env, config);
    const public_tx = Vm.Transaction{
        .kind = inferTxKind(&tx),
        .sender = sender,
        .nonce = try optionalU64(&tx, "nonce"),
        .gas_limit = gas_limit,
        .to = recipient,
        .input = input,
        .value = value,
        .max_fee_per_gas = try optionalU256(&tx, "maxFeePerGas"),
        .max_priority_fee_per_gas = try optionalU256(&tx, "maxPriorityFeePerGas"),
        .max_fee_per_blob_gas = try optionalU256(&tx, "maxFeePerBlobGas"),
        .gas_price = try optionalU256(&tx, "gasPrice") orelse 0,
        .blob_hashes = blob_hashes,
        .access_list = access_list.entries,
        .authorization_list = authorization_list.entries,
        .authorization_count = authorization_list.count,
    };

    var host = try FixtureHost.init(allocator, &pre, vm_env, spec);
    defer host.deinit();

    const result = try host.transact(public_tx);

    if (expected_exception) |expected| {
        if (result.validation_error) |err| {
            if (tx_validation.validationErrorMatchesEest(err, expected)) {
                try finishPostAssertions(allocator, fixture, &post_obj, &host, 1, null, summary);
                return;
            }
        }
        summary.countFail(.expected_transaction_exception);
        return;
    }
    if (result.validation_error) |err| {
        summary.countFail(validationFailReason(err));
        return;
    }

    try finishPostAssertions(allocator, fixture, &post_obj, &host, 0, result.output, summary);
}

fn validationFailReason(err: transaction.ValidationError) FailReason {
    return switch (err) {
        .nonce_mismatch => .transaction_nonce_mismatch,
        else => .unexpected_status,
    };
}

fn finishPostAssertions(
    allocator: std.mem.Allocator,
    fixture: *const std.json.ObjectMap,
    post_obj: *const std.json.ObjectMap,
    host: *FixtureHost,
    initial_compared_fields: usize,
    output: ?[]const u8,
    summary: *Summary,
) !void {
    var compared_fields: usize = initial_compared_fields;
    if (output) |actual_output| {
        if (fixture.get("out")) |expected_out| {
            const expected = try parseBytesFromValue(allocator, expected_out);
            defer allocator.free(expected);
            compared_fields += 1;
            if (!std.mem.eql(u8, actual_output, expected)) {
                summary.countFail(.output_mismatch);
                return;
            }
        }
    }

    const state_value = post_obj.get("state") orelse {
        if (compared_fields > 0) {
            summary.passed += 1;
        } else if (hasUnsupportedPostAssertions(post_obj)) {
            summary.countUnchecked(.unsupported_assertion_fields);
        } else {
            summary.countUnchecked(.missing_post_state);
        }
        return;
    };
    const state = asObject(state_value) orelse return error.MalformedFixture;
    if (try comparePostState(allocator, host, &state, &compared_fields)) |reason| {
        summary.countFail(reason);
        return;
    }

    if (compared_fields > 0) {
        summary.passed += 1;
    } else if (hasUnsupportedPostAssertions(post_obj)) {
        summary.countUnchecked(.unsupported_assertion_fields);
    } else {
        summary.countUnchecked(.no_comparable_fields);
    }
}

fn hasUnsupportedPostAssertions(post_obj: *const std.json.ObjectMap) bool {
    return post_obj.get("hash") != null or post_obj.get("logs") != null or post_obj.get("txbytes") != null;
}

fn selectedAccessList(tx: *const std.json.ObjectMap, index: usize) !?std.json.Array {
    const access_lists_value = tx.get("accessLists") orelse return null;
    const access_lists = asArray(access_lists_value) orelse return error.MalformedFixture;
    if (index >= access_lists.items.len) return error.MalformedFixture;
    return asArray(access_lists.items[index]) orelse return error.MalformedFixture;
}

fn comparePostState(
    allocator: std.mem.Allocator,
    host: *FixtureHost,
    expected_state: *const std.json.ObjectMap,
    compared_fields: *usize,
) !?FailReason {
    var state = expected_state.*;
    var account_it = state.iterator();
    while (account_it.next()) |account_entry| {
        const address = try parseAddress(account_entry.key_ptr.*);
        const expected_account = asObject(account_entry.value_ptr.*) orelse return error.MalformedFixture;
        try rejectUnknownKeys(&expected_account, &.{ "balance", "nonce", "code", "storage" });
        const actual = try host.getAccount(address);

        if (expected_account.get("balance")) |balance_value| {
            const expected_balance = try parseU256FromValue(balance_value);
            const actual_balance = if (actual) |account| account.balance else 0;
            compared_fields.* += 1;
            if (actual_balance != expected_balance) return .balance_mismatch;
        }

        if (expected_account.get("nonce")) |nonce_value| {
            const expected_nonce = try parseU64FromValue(nonce_value);
            const actual_nonce = if (actual) |account| account.nonce else 0;
            compared_fields.* += 1;
            if (actual_nonce != expected_nonce) return .nonce_mismatch;
        }

        if (expected_account.get("code")) |code_value| {
            const expected_code = try parseBytesFromValue(allocator, code_value);
            defer allocator.free(expected_code);
            const actual_code = if (actual) |account| account.code else &.{};
            compared_fields.* += 1;
            if (!std.mem.eql(u8, actual_code, expected_code)) return .code_mismatch;
        }

        if (expected_account.get("storage")) |storage_value| {
            var expected_storage = asObject(storage_value) orelse return error.MalformedFixture;
            var storage_it = expected_storage.iterator();
            while (storage_it.next()) |slot_entry| {
                const key = try parseHexInt(u256, slot_entry.key_ptr.*);
                const expected_value = try parseU256FromValue(slot_entry.value_ptr.*);
                const actual_value = try host.getStorage(address, key);
                compared_fields.* += 1;
                if (actual_value != expected_value) return .storage_mismatch;
            }
        }
    }

    return null;
}

const FixtureConfig = struct {
    chain_id: u256 = 1,
    blob_schedule: ?transaction.BlobSchedule = null,
};

fn parseFixtureConfig(fixture: *const std.json.ObjectMap, spec: evmz.Spec) !FixtureConfig {
    const config_value = fixture.get("config") orelse return .{};
    const config = asObject(config_value) orelse return error.MalformedFixture;
    try rejectUnknownKeys(&config, &.{ "chainid", "blobSchedule" });

    var result = FixtureConfig{
        .chain_id = if (config.get("chainid")) |value| try parseU256FromValue(value) else 1,
    };

    if (config.get("blobSchedule")) |schedule_value| {
        const schedules = asObject(schedule_value) orelse return error.MalformedFixture;
        try rejectUnknownKeys(&schedules, &.{ "Cancun", "Prague" });
        const schedule_key: ?[]const u8 = if (spec.isImpl(.prague))
            "Prague"
        else if (spec.isImpl(.cancun))
            "Cancun"
        else
            null;
        if (schedule_key) |key| {
            if (schedules.get(key)) |value| {
                result.blob_schedule = try parseBlobSchedule(value);
            }
        }
    }

    return result;
}

fn parseBlobSchedule(value: JsonValue) !transaction.BlobSchedule {
    const schedule = asObject(value) orelse return error.MalformedFixture;
    try rejectUnknownKeys(&schedule, &.{ "target", "max", "baseFeeUpdateFraction" });
    return .{
        .target = try parseU64FromValue(schedule.get("target") orelse return error.MalformedFixture),
        .max = try parseU64FromValue(schedule.get("max") orelse return error.MalformedFixture),
        .base_fee_update_fraction = try parseU256FromValue(schedule.get("baseFeeUpdateFraction") orelse return error.MalformedFixture),
    };
}

fn parseVmEnv(
    spec: evmz.Spec,
    env: *const std.json.ObjectMap,
    config: FixtureConfig,
) !Vm.Env {
    const base_fee = if (env.get("currentBaseFee")) |v| try parseU256FromValue(v) else 0;
    return .{
        .chain_id = if (env.get("currentChainId")) |v| try parseU256FromValue(v) else config.chain_id,
        .coinbase = if (env.get("currentCoinbase")) |v| try parseAddressFromValue(v) else evmz.addr(0),
        .number = if (env.get("currentNumber")) |v| try parseU64FromValue(v) else 0,
        .timestamp = if (env.get("currentTimestamp")) |v| try parseU64FromValue(v) else 0,
        .gas_limit = if (env.get("currentGasLimit")) |v| try parseU64FromValue(v) else 0,
        .prev_randao = if (env.get("currentRandom")) |v| try parseU256FromValue(v) else if (env.get("currentDifficulty")) |v| try parseU256FromValue(v) else 0,
        .base_fee = base_fee,
        .blob_base_fee = try parseBlobBaseFee(spec, env, config),
    };
}

fn parseBlobBaseFee(spec: evmz.Spec, env: *const std.json.ObjectMap, config: FixtureConfig) !u256 {
    if (env.get("currentBlobBaseFee")) |value| return parseU256FromValue(value);
    const excess_blob_gas = if (env.get("currentExcessBlobGas")) |value| try parseU256FromValue(value) else 0;
    if (config.blob_schedule) |schedule| {
        return transaction.blobBaseFeeForSchedule(schedule, excess_blob_gas) orelse error.Overflow;
    }
    return transaction.blobBaseFeeForSpec(spec, excess_blob_gas) orelse error.Overflow;
}

fn selectedU256(tx: *const std.json.ObjectMap, key: []const u8, index: usize) !u256 {
    const array = asArray(tx.get(key) orelse return error.MalformedFixture) orelse return error.MalformedFixture;
    if (index >= array.items.len) return error.MalformedFixture;
    return parseU256FromValue(array.items[index]);
}

fn selectedU64(tx: *const std.json.ObjectMap, key: []const u8, index: usize) !u64 {
    const value = try selectedU256(tx, key, index);
    return std.math.cast(u64, value) orelse error.Overflow;
}

fn selectedBytes(allocator: std.mem.Allocator, tx: *const std.json.ObjectMap, key: []const u8, index: usize) ![]u8 {
    const array = asArray(tx.get(key) orelse return error.MalformedFixture) orelse return error.MalformedFixture;
    if (index >= array.items.len) return error.MalformedFixture;
    return parseBytesFromValue(allocator, array.items[index]);
}

fn optionalU256(tx: *const std.json.ObjectMap, key: []const u8) !?u256 {
    const value = tx.get(key) orelse return null;
    return try parseU256FromValue(value);
}

fn optionalU64(tx: *const std.json.ObjectMap, key: []const u8) !?u64 {
    const value = tx.get(key) orelse return null;
    return try parseU64FromValue(value);
}

fn inferTxKind(tx: *const std.json.ObjectMap) transaction.TxKind {
    if (tx.get("authorizationList") != null) return .set_code;
    if (tx.get("blobVersionedHashes") != null or tx.get("maxFeePerBlobGas") != null) return .blob;
    if (tx.get("maxFeePerGas") != null or tx.get("maxPriorityFeePerGas") != null) return .dynamic_fee;
    if (tx.get("accessLists") != null) return .access_list;
    return .legacy;
}

const FixtureHost = struct {
    allocator: std.mem.Allocator,
    store: *evmz.state.MemoryStore,
    vm: Vm,

    const Self = @This();

    fn init(
        allocator: std.mem.Allocator,
        pre: *const std.json.ObjectMap,
        env: Vm.Env,
        spec: evmz.Spec,
    ) !Self {
        const store = try allocator.create(evmz.state.MemoryStore);
        errdefer allocator.destroy(store);
        store.* = evmz.state.MemoryStore.init(allocator);
        errdefer store.deinit();

        try seedMemoryStore(allocator, store, pre);

        var vm = Vm.init(allocator, .{
            .spec = spec,
            .state_reader = store.reader(),
            .env = env,
        });
        errdefer vm.deinit();

        return .{
            .allocator = allocator,
            .store = store,
            .vm = vm,
        };
    }

    fn deinit(self: *Self) void {
        self.vm.deinit();
        self.store.deinit();
        self.allocator.destroy(self.store);
    }

    fn getAccount(self: *Self, address: Address) !?Vm.AccountView {
        return self.vm.getAccount(address);
    }

    fn getStorage(self: *Self, address: Address, key: u256) !u256 {
        return self.vm.getStorage(address, key);
    }

    fn transact(self: *Self, tx: Vm.Transaction) !Vm.TxResult {
        return self.vm.transact(tx);
    }
};

fn jsonIndex(value: JsonValue) !usize {
    return switch (value) {
        .integer => |int| std.math.cast(usize, int) orelse error.Overflow,
        .number_string => |string| try std.fmt.parseInt(usize, string, 10),
        else => error.MalformedFixture,
    };
}

test "runs a minimal EEST state fixture subset" {
    const fixture =
        \\{
        \\  "simple_sstore": {
        \\    "env": {
        \\      "currentCoinbase": "0x0000000000000000000000000000000000000000",
        \\      "currentGasLimit": "0x030d40",
        \\      "currentNumber": "0x01",
        \\      "currentDifficulty": "0x00",
        \\      "currentTimestamp": "0x00",
        \\      "currentBaseFee": "0x00"
        \\    },
        \\    "pre": {
        \\      "0x0000000000000000000000000000000000001000": {
        \\        "balance": "0x00",
        \\        "nonce": "0x00",
        \\        "code": "0x602a600055",
        \\        "storage": {}
        \\      },
        \\      "0x000000000000000000000000000000000000aaaa": {
        \\        "balance": "0xffff",
        \\        "nonce": "0x00",
        \\        "code": "0x",
        \\        "storage": {}
        \\      }
        \\    },
        \\    "transaction": {
        \\      "sender": "0x000000000000000000000000000000000000aaaa",
        \\      "to": "0x0000000000000000000000000000000000001000",
        \\      "gasLimit": ["0x0186a0"],
        \\      "gasPrice": "0x00",
        \\      "value": ["0x00"],
        \\      "data": ["0x"]
        \\    },
        \\    "post": {
        \\      "Cancun": [{
        \\        "indexes": { "data": 0, "gas": 0, "value": 0 },
        \\        "state": {
        \\          "0x0000000000000000000000000000000000001000": {
        \\            "storage": { "0x00": "0x2a" }
        \\          }
        \\        }
        \\      }]
        \\    }
        \\  }
        \\}
    ;

    const summary = try runSlice(std.testing.allocator, fixture, .{});
    try std.testing.expectEqual(@as(usize, 1), summary.fixtures);
    try std.testing.expectEqual(@as(usize, 1), summary.vectors);
    try std.testing.expectEqual(@as(usize, 1), summary.passed);
    try std.testing.expectEqual(@as(usize, 0), summary.failed);
    try std.testing.expectEqual(@as(usize, 0), summary.skipped);
    try std.testing.expectEqual(@as(usize, 0), summary.unchecked);
}

test "EEST transaction intrinsic gas is removed before execution" {
    const fixture =
        \\{
        \\  "intrinsic_gas_blocks_execution": {
        \\    "env": {
        \\      "currentCoinbase": "0x0000000000000000000000000000000000000000",
        \\      "currentGasLimit": "0x030d40",
        \\      "currentNumber": "0x01",
        \\      "currentDifficulty": "0x00",
        \\      "currentTimestamp": "0x00",
        \\      "currentBaseFee": "0x00"
        \\    },
        \\    "pre": {
        \\      "0x0000000000000000000000000000000000001000": {
        \\        "balance": "0x00",
        \\        "nonce": "0x00",
        \\        "code": "0x6001600055",
        \\        "storage": {}
        \\      },
        \\      "0x000000000000000000000000000000000000aaaa": {
        \\        "balance": "0xffff",
        \\        "nonce": "0x00",
        \\        "code": "0x",
        \\        "storage": {}
        \\      }
        \\    },
        \\    "transaction": {
        \\      "sender": "0x000000000000000000000000000000000000aaaa",
        \\      "to": "0x0000000000000000000000000000000000001000",
        \\      "gasLimit": ["0x5218"],
        \\      "gasPrice": "0x00",
        \\      "value": ["0x00"],
        \\      "data": ["0xff"]
        \\    },
        \\    "post": {
        \\      "Cancun": [{
        \\        "indexes": { "data": 0, "gas": 0, "value": 0 },
        \\        "state": {
        \\          "0x0000000000000000000000000000000000001000": {
        \\            "storage": { "0x00": "0x00" }
        \\          }
        \\        }
        \\      }]
        \\    }
        \\  }
        \\}
    ;

    const summary = try runSlice(std.testing.allocator, fixture, .{});
    try std.testing.expectEqual(@as(usize, 1), summary.fixtures);
    try std.testing.expectEqual(@as(usize, 1), summary.vectors);
    try std.testing.expectEqual(@as(usize, 1), summary.passed);
    try std.testing.expectEqual(@as(usize, 0), summary.failed);
    try std.testing.expectEqual(@as(usize, 0), summary.skipped);
    try std.testing.expectEqual(@as(usize, 0), summary.unchecked);
}

test "EEST expected transaction validation exception passes" {
    const fixture =
        \\{
        \\  "intrinsic_gas_exception": {
        \\    "env": {
        \\      "currentCoinbase": "0x0000000000000000000000000000000000000000",
        \\      "currentGasLimit": "0x030d40",
        \\      "currentNumber": "0x01",
        \\      "currentDifficulty": "0x00",
        \\      "currentTimestamp": "0x00",
        \\      "currentBaseFee": "0x00"
        \\    },
        \\    "pre": {
        \\      "0x0000000000000000000000000000000000001000": {
        \\        "balance": "0x00",
        \\        "nonce": "0x00",
        \\        "code": "0x00",
        \\        "storage": {}
        \\      },
        \\      "0x000000000000000000000000000000000000aaaa": {
        \\        "balance": "0xffff",
        \\        "nonce": "0x00",
        \\        "code": "0x",
        \\        "storage": {}
        \\      }
        \\    },
        \\    "transaction": {
        \\      "sender": "0x000000000000000000000000000000000000aaaa",
        \\      "to": "0x0000000000000000000000000000000000001000",
        \\      "gasLimit": ["0x5208"],
        \\      "gasPrice": "0x00",
        \\      "value": ["0x00"],
        \\      "data": ["0xff"]
        \\    },
        \\    "post": {
        \\      "Cancun": [{
        \\        "indexes": { "data": 0, "gas": 0, "value": 0 },
        \\        "expectException": "TransactionException.INTRINSIC_GAS_TOO_LOW"
        \\      }]
        \\    }
        \\  }
        \\}
    ;

    const summary = try runSlice(std.testing.allocator, fixture, .{});
    try std.testing.expectEqual(@as(usize, 1), summary.fixtures);
    try std.testing.expectEqual(@as(usize, 1), summary.vectors);
    try std.testing.expectEqual(@as(usize, 1), summary.passed);
    try std.testing.expectEqual(@as(usize, 0), summary.failed);
    try std.testing.expectEqual(@as(usize, 0), summary.skipped);
    try std.testing.expectEqual(@as(usize, 0), summary.unchecked);
}

fn runMinimalStateFixture(
    tx_extra: []const u8,
    gas_limit: []const u8,
    data: []const u8,
    post_extra: []const u8,
    post_account_fields: []const u8,
) !Summary {
    const fixture = try std.fmt.allocPrint(std.testing.allocator,
        \\{{"simple_sstore":{{"env":{{"currentCoinbase":"0x0000000000000000000000000000000000000000","currentGasLimit":"0x030d40","currentNumber":"0x01","currentDifficulty":"0x00","currentTimestamp":"0x00","currentBaseFee":"0x00"}},"pre":{{"0x0000000000000000000000000000000000001000":{{"balance":"0x00","nonce":"0x00","code":"0x602a600055","storage":{{}}}},"0x000000000000000000000000000000000000aaaa":{{"balance":"0xffff","nonce":"0x00","code":"0x","storage":{{}}}}}},"transaction":{{"sender":"0x000000000000000000000000000000000000aaaa","to":"0x0000000000000000000000000000000000001000","gasLimit":["{s}"],"gasPrice":"0x00","value":["0x00"],"data":["{s}"]{s}}},"post":{{"Cancun":[{{"indexes":{{"data":0,"gas":0,"value":0}}{s},"state":{{"0x0000000000000000000000000000000000001000":{{{s}}}}}}}]}}}}}}
    , .{ gas_limit, data, tx_extra, post_extra, post_account_fields });
    defer std.testing.allocator.free(fixture);
    return runSlice(std.testing.allocator, fixture, .{});
}

test "EEST transaction nonce mismatch fails" {
    const summary = try runMinimalStateFixture(
        ",\"nonce\":\"0x01\"",
        "0x0186a0",
        "0x",
        "",
        "\"storage\":{\"0x00\":\"0x2a\"}",
    );
    try std.testing.expectEqual(@as(usize, 1), summary.failed);
    try std.testing.expectEqual(@as(usize, 1), summary.fail_reasons[@intFromEnum(FailReason.transaction_nonce_mismatch)]);
}

test "EEST post balance and nonce mismatches fail" {
    const balance = try runMinimalStateFixture("", "0x0186a0", "0x", "", "\"balance\":\"0x01\"");
    try std.testing.expectEqual(@as(usize, 1), balance.failed);
    try std.testing.expectEqual(@as(usize, 1), balance.fail_reasons[@intFromEnum(FailReason.balance_mismatch)]);

    const nonce = try runMinimalStateFixture("", "0x0186a0", "0x", "", "\"nonce\":\"0x01\"");
    try std.testing.expectEqual(@as(usize, 1), nonce.failed);
    try std.testing.expectEqual(@as(usize, 1), nonce.fail_reasons[@intFromEnum(FailReason.nonce_mismatch)]);
}

test "EEST unsupported assertion fields do not block comparable post state" {
    const summary = try runMinimalStateFixture(
        "",
        "0x0186a0",
        "0x",
        ",\"hash\":\"0x00\",\"logs\":\"0x00\",\"txbytes\":\"0x00\"",
        "\"storage\":{\"0x00\":\"0x2a\"}",
    );
    try std.testing.expectEqual(@as(usize, 1), summary.passed);
    try std.testing.expectEqual(@as(usize, 0), summary.failed);
    try std.testing.expectEqual(@as(usize, 0), summary.unchecked);
}

test "EEST unsupported-only assertion fields are unchecked" {
    const fixture =
        \\{
        \\  "unsupported_only": {
        \\    "env": {
        \\      "currentCoinbase": "0x0000000000000000000000000000000000000000",
        \\      "currentGasLimit": "0x030d40",
        \\      "currentNumber": "0x01",
        \\      "currentDifficulty": "0x00",
        \\      "currentTimestamp": "0x00",
        \\      "currentBaseFee": "0x00"
        \\    },
        \\    "pre": {
        \\      "0x000000000000000000000000000000000000aaaa": {
        \\        "balance": "0xffff",
        \\        "nonce": "0x00",
        \\        "code": "0x",
        \\        "storage": {}
        \\      }
        \\    },
        \\    "transaction": {
        \\      "sender": "0x000000000000000000000000000000000000aaaa",
        \\      "to": "0x0000000000000000000000000000000000001000",
        \\      "gasLimit": ["0x0186a0"],
        \\      "gasPrice": "0x00",
        \\      "value": ["0x00"],
        \\      "data": ["0x"]
        \\    },
        \\    "post": {
        \\      "Cancun": [{
        \\        "indexes": {"data": 0, "gas": 0, "value": 0},
        \\        "hash": "0x00",
        \\        "logs": "0x00",
        \\        "txbytes": "0x00"
        \\      }]
        \\    }
        \\  }
        \\}
    ;

    const summary = try runSlice(std.testing.allocator, fixture, .{});
    try std.testing.expectEqual(@as(usize, 0), summary.passed);
    try std.testing.expectEqual(@as(usize, 0), summary.failed);
    try std.testing.expectEqual(@as(usize, 1), summary.unchecked);
    try std.testing.expectEqual(@as(usize, 1), summary.unchecked_reasons[@intFromEnum(UncheckedReason.unsupported_assertion_fields)]);
}

test "EEST unknown post account key fails" {
    const summary = try runMinimalStateFixture("", "0x0186a0", "0x", "", "\"storage\":{},\"mystery\":\"0x00\"");
    try std.testing.expectEqual(@as(usize, 1), summary.failed);
    try std.testing.expectEqual(@as(usize, 1), summary.fail_reasons[@intFromEnum(FailReason.unsupported_fixture_key)]);
}

test "EEST expected exception still compares post state" {
    const summary = try runMinimalStateFixture(
        "",
        "0x5208",
        "0xff",
        ",\"expectException\":\"TransactionException.INTRINSIC_GAS_TOO_LOW\"",
        "\"balance\":\"0x01\"",
    );
    try std.testing.expectEqual(@as(usize, 1), summary.failed);
    try std.testing.expectEqual(@as(usize, 1), summary.fail_reasons[@intFromEnum(FailReason.balance_mismatch)]);
}

test "EEST child revert rolls back transient storage" {
    const fixture =
        \\{
        \\  "delegatecall_tstore_revert": {
        \\    "env": {
        \\      "currentCoinbase": "0x0000000000000000000000000000000000000000",
        \\      "currentGasLimit": "0x030d40",
        \\      "currentNumber": "0x01",
        \\      "currentDifficulty": "0x00",
        \\      "currentTimestamp": "0x00",
        \\      "currentBaseFee": "0x00"
        \\    },
        \\    "pre": {
        \\      "0x0000000000000000000000000000000000001000": {
        \\        "balance": "0x00",
        \\        "nonce": "0x00",
        \\        "code": "0x600060006000600073000000000000000000000000000000000000200061fffff45060005c600055",
        \\        "storage": {}
        \\      },
        \\      "0x0000000000000000000000000000000000002000": {
        \\        "balance": "0x00",
        \\        "nonce": "0x00",
        \\        "code": "0x600160005d60006000fd",
        \\        "storage": {}
        \\      },
        \\      "0x000000000000000000000000000000000000aaaa": {
        \\        "balance": "0xffff",
        \\        "nonce": "0x00",
        \\        "code": "0x",
        \\        "storage": {}
        \\      }
        \\    },
        \\    "transaction": {
        \\      "sender": "0x000000000000000000000000000000000000aaaa",
        \\      "to": "0x0000000000000000000000000000000000001000",
        \\      "gasLimit": ["0x0186a0"],
        \\      "gasPrice": "0x00",
        \\      "value": ["0x00"],
        \\      "data": ["0x"]
        \\    },
        \\    "post": {
        \\      "Cancun": [{
        \\        "indexes": { "data": 0, "gas": 0, "value": 0 },
        \\        "state": {
        \\          "0x0000000000000000000000000000000000001000": {
        \\            "storage": { "0x00": "0x00" }
        \\          }
        \\        }
        \\      }]
        \\    }
        \\  }
        \\}
    ;

    const summary = try runSlice(std.testing.allocator, fixture, .{});
    try std.testing.expectEqual(@as(usize, 1), summary.fixtures);
    try std.testing.expectEqual(@as(usize, 1), summary.vectors);
    try std.testing.expectEqual(@as(usize, 1), summary.passed);
    try std.testing.expectEqual(@as(usize, 0), summary.failed);
    try std.testing.expectEqual(@as(usize, 0), summary.skipped);
    try std.testing.expectEqual(@as(usize, 0), summary.unchecked);
}

test "EEST successful create leaves empty return data" {
    const fixture =
        \\{
        \\  "create_success_empty_returndata": {
        \\    "env": {
        \\      "currentCoinbase": "0x0000000000000000000000000000000000000000",
        \\      "currentGasLimit": "0x030d40",
        \\      "currentNumber": "0x01",
        \\      "currentDifficulty": "0x00",
        \\      "currentTimestamp": "0x00",
        \\      "currentBaseFee": "0x00"
        \\    },
        \\    "pre": {
        \\      "0x0000000000000000000000000000000000001000": {
        \\        "balance": "0xffff",
        \\        "nonce": "0x01",
        \\        "code": "0x3660006000373660006000f03d600055",
        \\        "storage": {}
        \\      },
        \\      "0x000000000000000000000000000000000000aaaa": {
        \\        "balance": "0xffff",
        \\        "nonce": "0x00",
        \\        "code": "0x",
        \\        "storage": {}
        \\      }
        \\    },
        \\    "transaction": {
        \\      "sender": "0x000000000000000000000000000000000000aaaa",
        \\      "to": "0x0000000000000000000000000000000000001000",
        \\      "gasLimit": ["0x0186a0"],
        \\      "gasPrice": "0x00",
        \\      "value": ["0x00"],
        \\      "data": ["0x600060005360016000f3"]
        \\    },
        \\    "post": {
        \\      "Berlin": [{
        \\        "indexes": { "data": 0, "gas": 0, "value": 0 },
        \\        "state": {
        \\          "0x0000000000000000000000000000000000001000": {
        \\            "storage": { "0x00": "0x00" }
        \\          }
        \\        }
        \\      }]
        \\    }
        \\  }
        \\}
    ;

    const summary = try runSlice(std.testing.allocator, fixture, .{});
    try std.testing.expectEqual(@as(usize, 1), summary.fixtures);
    try std.testing.expectEqual(@as(usize, 1), summary.vectors);
    try std.testing.expectEqual(@as(usize, 1), summary.passed);
    try std.testing.expectEqual(@as(usize, 0), summary.failed);
    try std.testing.expectEqual(@as(usize, 0), summary.skipped);
    try std.testing.expectEqual(@as(usize, 0), summary.unchecked);
}

test "EEST create STOP does not install child call return data" {
    const fixture =
        \\{
        \\  "create_stop_after_child_call": {
        \\    "env": {
        \\      "currentCoinbase": "0x0000000000000000000000000000000000000000",
        \\      "currentGasLimit": "0x030d40",
        \\      "currentNumber": "0x01",
        \\      "currentDifficulty": "0x00",
        \\      "currentTimestamp": "0x00",
        \\      "currentBaseFee": "0x00"
        \\    },
        \\    "pre": {
        \\      "0x0000000000000000000000000000000000001000": {
        \\        "balance": "0xffff",
        \\        "nonce": "0x01",
        \\        "code": "0x3660006000373660006000f05000",
        \\        "storage": {}
        \\      },
        \\      "0x000000000000000000000000000000000000aaaa": {
        \\        "balance": "0xffff",
        \\        "nonce": "0x00",
        \\        "code": "0x",
        \\        "storage": {}
        \\      }
        \\    },
        \\    "transaction": {
        \\      "sender": "0x000000000000000000000000000000000000aaaa",
        \\      "to": "0x0000000000000000000000000000000000001000",
        \\      "gasLimit": ["0x0186a0"],
        \\      "gasPrice": "0x00",
        \\      "value": ["0x00"],
        \\      "data": ["0x61abcd600052600260006002601e6000600461fffff100"]
        \\    },
        \\    "post": {
        \\      "Berlin": [{
        \\        "indexes": { "data": 0, "gas": 0, "value": 0 },
        \\        "state": {
        \\          "0x5bafcc0c93ecd8022925d7fd89da1c6250850e19": {
        \\            "code": "0x"
        \\          }
        \\        }
        \\      }]
        \\    }
        \\  }
        \\}
    ;

    const summary = try runSlice(std.testing.allocator, fixture, .{});
    try std.testing.expectEqual(@as(usize, 1), summary.fixtures);
    try std.testing.expectEqual(@as(usize, 1), summary.vectors);
    try std.testing.expectEqual(@as(usize, 1), summary.passed);
    try std.testing.expectEqual(@as(usize, 0), summary.failed);
    try std.testing.expectEqual(@as(usize, 0), summary.skipped);
    try std.testing.expectEqual(@as(usize, 0), summary.unchecked);
}

test "EEST state comparison accepts rolled back execution failure" {
    const fixture =
        \\{
        \\  "sstore_then_stack_underflow": {
        \\    "env": {
        \\      "currentCoinbase": "0x0000000000000000000000000000000000000000",
        \\      "currentGasLimit": "0x030d40",
        \\      "currentNumber": "0x01",
        \\      "currentDifficulty": "0x00",
        \\      "currentTimestamp": "0x00",
        \\      "currentBaseFee": "0x00"
        \\    },
        \\    "pre": {
        \\      "0x0000000000000000000000000000000000001000": {
        \\        "balance": "0x00",
        \\        "nonce": "0x00",
        \\        "code": "0x600160005550",
        \\        "storage": { "0x00": "0x2a" }
        \\      },
        \\      "0x000000000000000000000000000000000000aaaa": {
        \\        "balance": "0xffff",
        \\        "nonce": "0x00",
        \\        "code": "0x",
        \\        "storage": {}
        \\      }
        \\    },
        \\    "transaction": {
        \\      "sender": "0x000000000000000000000000000000000000aaaa",
        \\      "to": "0x0000000000000000000000000000000000001000",
        \\      "gasLimit": ["0x0186a0"],
        \\      "gasPrice": "0x00",
        \\      "value": ["0x00"],
        \\      "data": ["0x"]
        \\    },
        \\    "post": {
        \\      "Cancun": [{
        \\        "indexes": { "data": 0, "gas": 0, "value": 0 },
        \\        "state": {
        \\          "0x0000000000000000000000000000000000001000": {
        \\            "storage": { "0x00": "0x2a" }
        \\          }
        \\        }
        \\      }]
        \\    }
        \\  }
        \\}
    ;

    const summary = try runSlice(std.testing.allocator, fixture, .{});
    try std.testing.expectEqual(@as(usize, 1), summary.fixtures);
    try std.testing.expectEqual(@as(usize, 1), summary.vectors);
    try std.testing.expectEqual(@as(usize, 1), summary.passed);
    try std.testing.expectEqual(@as(usize, 0), summary.failed);
    try std.testing.expectEqual(@as(usize, 0), summary.skipped);
    try std.testing.expectEqual(@as(usize, 0), summary.unchecked);
}
