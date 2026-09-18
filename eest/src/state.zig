const std = @import("std");
const evmz = @import("evmz");
const fixture_common = @import("fixtures");
const statetest = @import("statetest");
const tx_validation = @import("tx_validation.zig");

const JsonValue = fixture_common.JsonValue;

const asArray = fixture_common.asArray;
const asObject = fixture_common.asObject;
const jsonString = fixture_common.jsonString;
const parseAddress = fixture_common.parseAddress;
const parseBytesFromValue = fixture_common.parseBytesFromValue;
const parseFork = fixture_common.parseStateFork;
const parseHexInt = fixture_common.parseHexInt;
const parseU256FromValue = fixture_common.parseU256FromValue;
const parseU64FromValue = fixture_common.parseU64FromValue;
const rejectUnknownKeys = fixture_common.rejectUnknownKeys;

pub const Options = struct {
    fork_filter: ?[]const u8 = null,
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
    state_root_mismatch,
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

fn runSlice(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    options: Options,
) !Summary {
    var parsed = try std.json.parseFromSlice(JsonValue, allocator, bytes, .{
        .parse_numbers = false,
    });
    defer parsed.deinit();

    var root = asObject(parsed.value) orelse return error.ExpectedObject;
    var summary = Summary{};
    var it = root.iterator();
    while (it.next()) |entry| {
        summary.add(runCase(allocator, entry.key_ptr.*, entry.value_ptr.*, options));
    }

    return summary;
}

/// Runs one top-level state fixture selected by its exact EEST id.
/// File discovery and selection belong to the caller.
pub fn runCase(
    allocator: std.mem.Allocator,
    test_name: []const u8,
    fixture: std.json.Value,
    options: Options,
) Summary {
    var summary = Summary{ .fixtures = 1 };
    runFixture(allocator, test_name, fixture, options, &summary) catch |err| {
        summary.vectors += 1;
        summary.countFail(switch (err) {
            error.UnsupportedFixtureKey => .unsupported_fixture_key,
            else => .malformed_fixture,
        });
    };
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
    try rejectUnknownKeys(&fixture_obj, &.{ "env", "pre", "transaction", "post", "config", "_info", "out" });
    var post_obj = asObject(fixture_obj.get("post") orelse return error.MalformedFixture) orelse return error.MalformedFixture;

    var fork_it = post_obj.iterator();
    while (fork_it.next()) |fork_entry| {
        const fork_name = fork_entry.key_ptr.*;
        if (options.fork_filter) |filter| {
            if (!std.ascii.eqlIgnoreCase(fork_name, filter)) continue;
        }

        const vectors = asArray(fork_entry.value_ptr.*) orelse return error.MalformedFixture;
        const revision = parseFork(fork_name) orelse {
            for (vectors.items) |_| {
                summary.vectors += 1;
                summary.countFail(.unsupported_fork);
            }
            continue;
        };

        switch (revision) {
            inline else => |exact_revision| try runForkVectors(
                exact_revision,
                allocator,
                &fixture_obj,
                vectors,
                summary,
                fork_name,
            ),
        }
    }
}

fn runForkVectors(
    comptime revision: evmz.eth.Revision,
    allocator: std.mem.Allocator,
    fixture: *const std.json.ObjectMap,
    vectors: std.json.Array,
    summary: *Summary,
    /// The `post` key naming this fork; several BPO forks share one revision.
    fork_name: []const u8,
) !void {
    for (vectors.items) |post| {
        summary.vectors += 1;
        runVectorExact(revision, allocator, fixture, post, summary, fork_name) catch |err| {
            summary.countFail(switch (err) {
                error.UnsupportedFixtureKey => .unsupported_fixture_key,
                else => .malformed_fixture,
            });
        };
    }
}

fn runVectorExact(
    comptime revision: evmz.eth.Revision,
    allocator: std.mem.Allocator,
    fixture: *const std.json.ObjectMap,
    post: JsonValue,
    summary: *Summary,
    fork_name: []const u8,
) !void {
    const post_obj = asObject(post) orelse return error.MalformedFixture;
    try rejectUnknownKeys(&post_obj, &.{ "hash", "logs", "receipt", "txbytes", "indexes", "state", "expectException" });
    const expected_exception = if (post_obj.get("expectException")) |value|
        jsonString(value) orelse return error.MalformedFixture
    else
        null;

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const vector = statetest.parseVector(revision, arena.allocator(), fixture, &post_obj, fork_name) catch |err| {
        if (err == error.MissingSender) {
            summary.countFail(.missing_sender);
            return;
        }
        return err;
    };
    const pre = vector.pre;
    const vm_env = vector.env;
    if (expected_exception) |expected| {
        if (try serializedTransactionExceptionMatches(allocator, &post_obj, expected)) {
            var host = try statetest.Host(revision, false).init(allocator, &pre, vm_env);
            defer host.deinit();
            try finishPostAssertions(allocator, fixture, &post_obj, &host, 1, null, summary);
            return;
        }
    }
    if (vector.tx.chain_id) |tx_chain_id| {
        if (tx_chain_id != vm_env.chain_id) {
            var host = try statetest.Host(revision, false).init(allocator, &pre, vm_env);
            defer host.deinit();
            if (expected_exception) |expected| {
                if (tx_validation.exceptionNameMatches("TransactionException.INVALID_CHAINID", expected)) {
                    try finishPostAssertions(allocator, fixture, &post_obj, &host, 1, null, summary);
                } else {
                    summary.countFail(.expected_transaction_exception);
                }
            } else {
                summary.countFail(.unexpected_status);
            }
            return;
        }
    }

    var host = try statetest.Host(revision, false).init(allocator, &pre, vm_env);
    defer host.deinit();
    const result = try host.transact(vector.tx, null);
    try finishVectorResult(allocator, fixture, &post_obj, &host, result, expected_exception, summary);
}

fn serializedTransactionExceptionMatches(
    allocator: std.mem.Allocator,
    post_obj: *const std.json.ObjectMap,
    expected: []const u8,
) !bool {
    if (!tx_validation.exceptionNameMatches("TransactionException.INVALID_SIGNATURE_VRS", expected)) return false;

    const value = post_obj.get("txbytes") orelse return false;
    const tx_bytes = try parseBytesFromValue(allocator, value);
    defer allocator.free(tx_bytes);

    return tx_validation.serializedSignatureExceptionMatches(allocator, tx_bytes, expected);
}

fn finishVectorResult(
    allocator: std.mem.Allocator,
    fixture: *const std.json.ObjectMap,
    post_obj: *const std.json.ObjectMap,
    host: anytype,
    result: anytype,
    expected_exception: ?[]const u8,
    summary: *Summary,
) !void {
    if (expected_exception) |expected| {
        switch (result) {
            .rejected => |err| if (tx_validation.validationErrorMatchesEest(err, expected)) {
                try finishPostAssertions(allocator, fixture, post_obj, host, 1, null, summary);
                return;
            },
            .executed => {},
        }
        summary.countFail(.expected_transaction_exception);
        return;
    }

    switch (result) {
        .rejected => |err| {
            summary.countFail(validationFailReason(err));
            return;
        },
        .executed => |executed| try finishPostAssertions(allocator, fixture, post_obj, host, 0, executed.output, summary),
    }
}

fn validationFailReason(err: evmz.eth.transaction_validation.ValidationError) FailReason {
    return switch (err) {
        .nonce_too_low, .nonce_too_high => .transaction_nonce_mismatch,
        else => .unexpected_status,
    };
}

fn finishPostAssertions(
    allocator: std.mem.Allocator,
    fixture: *const std.json.ObjectMap,
    post_obj: *const std.json.ObjectMap,
    host: anytype,
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

    if (post_obj.get("hash")) |expected_hash_value| {
        const expected_hash = try parseBytesFromValue(allocator, expected_hash_value);
        defer allocator.free(expected_hash);
        if (expected_hash.len != 32) return error.MalformedFixture;
        const actual_hash = try host.stateRoot(allocator);
        compared_fields += 1;
        if (!std.mem.eql(u8, &actual_hash, expected_hash)) {
            summary.countFail(.state_root_mismatch);
            return;
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
    return post_obj.get("logs") != null or post_obj.get("receipt") != null or post_obj.get("txbytes") != null;
}

fn comparePostState(
    allocator: std.mem.Allocator,
    host: anytype,
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

const parseFixtureConfig = fixture_common.parseFixtureConfig;

test "EEST fixture config selects Amsterdam blob params" {
    const fixture =
        \\{
        \\  "config": {
        \\    "network": "Amsterdam",
        \\    "chainId": "0x2a",
        \\    "blobSchedule": {
        \\      "Cancun": {"target": "0x03", "max": "0x06", "baseFeeUpdateFraction": "0x01"},
        \\      "Prague": {"target": "0x06", "max": "0x09", "baseFeeUpdateFraction": "0x02"},
        \\      "Osaka": {"target": "0x09", "max": "0x0c", "baseFeeUpdateFraction": "0x03"},
        \\      "Amsterdam": {"target": "0x0c", "max": "0x0f", "baseFeeUpdateFraction": "0x04"},
        \\      "BPO1": {"target": "0x0f", "max": "0x12", "baseFeeUpdateFraction": "0x05"},
        \\      "BPO2": {"target": "0x12", "max": "0x15", "baseFeeUpdateFraction": "0x06"}
        \\    }
        \\  }
        \\}
    ;
    const parsed = try std.json.parseFromSlice(JsonValue, std.testing.allocator, fixture, .{});
    defer parsed.deinit();
    const obj = asObject(parsed.value) orelse return error.MalformedFixture;

    // No name: the revision cascade still picks the newest entry it can carry.
    const osaka = try parseFixtureConfig(&obj, .osaka, null);
    try std.testing.expectEqual(@as(u64, 9), osaka.blob_params.?.target);
    try std.testing.expectEqual(@as(u64, 12), osaka.blob_params.?.max);

    const amsterdam = try parseFixtureConfig(&obj, .amsterdam, null);
    try std.testing.expectEqual(@as(u256, 42), amsterdam.chain_id);
    try std.testing.expectEqual(@as(u64, 12), amsterdam.blob_params.?.target);
    try std.testing.expectEqual(@as(u64, 15), amsterdam.blob_params.?.max);

    // A BPO fork runs Osaka rules, so the revision cannot distinguish it. The
    // declared fork name must select the BPO entry rather than Osaka's.
    const bpo2 = try parseFixtureConfig(&obj, .osaka, "BPO2");
    try std.testing.expectEqual(@as(u64, 18), bpo2.blob_params.?.target);
    try std.testing.expectEqual(@as(u64, 21), bpo2.blob_params.?.max);
    try std.testing.expectEqual(@as(u256, 6), bpo2.blob_params.?.base_fee_update_fraction);

    const bpo1 = try parseFixtureConfig(&obj, .osaka, "BPO1");
    try std.testing.expectEqual(@as(u64, 15), bpo1.blob_params.?.target);
    try std.testing.expectEqual(@as(u256, 5), bpo1.blob_params.?.base_fee_update_fraction);

    // An unknown name (transition network) falls back, never fails.
    const transition = try parseFixtureConfig(&obj, .osaka, "OsakaToBPO1AtTime15k");
    try std.testing.expectEqual(@as(u64, 9), transition.blob_params.?.target);
}

test "EEST fork parser maps BPO names onto Osaka execution" {
    try std.testing.expectEqual(evmz.eth.Revision.osaka, fixture_common.parseStateFork("BPO1"));
    try std.testing.expectEqual(evmz.eth.Revision.osaka, fixture_common.parseStateFork("BPO2"));
}

test "EEST env parser reads Amsterdam slotNumber" {
    const fixture =
        \\{
        \\  "currentNumber": "0x01",
        \\  "slotNumber": "0x1234"
        \\}
    ;
    const parsed = try std.json.parseFromSlice(JsonValue, std.testing.allocator, fixture, .{});
    defer parsed.deinit();
    const env = asObject(parsed.value) orelse return error.MalformedFixture;

    const parsed_env = try statetest.parseEnv(.amsterdam, &env, .{});
    try std.testing.expectEqual(@as(u64, 1), parsed_env.number);
    try std.testing.expectEqual(@as(u64, 0x1234), parsed_env.slot_number);
}

test "EEST state block hash source uses state-test convention hashes" {
    const source = statetest.BlockHashSource.source();

    var expected_zero: [32]u8 = undefined;
    std.crypto.hash.sha3.Keccak256.hash("0", &expected_zero, .{});
    try std.testing.expectEqual(evmz.uint256.fromBytes32(&expected_zero), (try source.getBlockHash(0)).?);

    var expected_ancestor: [32]u8 = undefined;
    std.crypto.hash.sha3.Keccak256.hash("255", &expected_ancestor, .{});
    try std.testing.expectEqual(evmz.uint256.fromBytes32(&expected_ancestor), (try source.getBlockHash(255)).?);
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

test "EEST expected invalid signature is proven from serialized transaction bytes" {
    const summary = try runMinimalStateFixture(
        "",
        "0x0186a0",
        "0x",
        ",\"txbytes\":\"0xf841800a840100000094f89a03b42ea1412874da2cf1ae48956f73d0603901801b01a07fffffffffffffffffffffffffffffff5d576e7357a4501ddfe92f46681b20a1\",\"expectException\":\"TransactionException.INVALID_SIGNATURE_VRS\"",
        "\"storage\":{}",
    );
    try std.testing.expectEqual(@as(usize, 1), summary.passed);
    try std.testing.expectEqual(@as(usize, 0), summary.failed);
    try std.testing.expectEqual(@as(usize, 0), summary.unchecked);
}

fn runMinimalStateFixture(
    tx_extra: []const u8,
    gas_limit: []const u8,
    data: []const u8,
    post_extra: []const u8,
    post_account_fields: []const u8,
) !Summary {
    return runMinimalStateFixtureWithOptions(
        "0x030d40",
        tx_extra,
        gas_limit,
        data,
        post_extra,
        post_account_fields,
        .{},
    );
}

fn runMinimalStateFixtureWithOptions(
    block_gas_limit: []const u8,
    tx_extra: []const u8,
    gas_limit: []const u8,
    data: []const u8,
    post_extra: []const u8,
    post_account_fields: []const u8,
    options: Options,
) !Summary {
    const fixture = try std.fmt.allocPrint(std.testing.allocator,
        \\{{"simple_sstore":{{"env":{{"currentCoinbase":"0x0000000000000000000000000000000000000000","currentGasLimit":"{s}","currentNumber":"0x01","currentDifficulty":"0x00","currentTimestamp":"0x00","currentBaseFee":"0x00"}},"pre":{{"0x0000000000000000000000000000000000001000":{{"balance":"0x00","nonce":"0x00","code":"0x602a600055","storage":{{}}}},"0x000000000000000000000000000000000000aaaa":{{"balance":"0xffff","nonce":"0x00","code":"0x","storage":{{}}}}}},"transaction":{{"sender":"0x000000000000000000000000000000000000aaaa","to":"0x0000000000000000000000000000000000001000","gasLimit":["{s}"],"gasPrice":"0x00","value":["0x00"],"data":["{s}"]{s}}},"post":{{"Cancun":[{{"indexes":{{"data":0,"gas":0,"value":0}}{s},"state":{{"0x0000000000000000000000000000000000001000":{{{s}}}}}}}]}}}}}}
    , .{ block_gas_limit, gas_limit, data, tx_extra, post_extra, post_account_fields });
    defer std.testing.allocator.free(fixture);
    return runSlice(std.testing.allocator, fixture, options);
}

test "EEST runner handles consecutive fixtures without leaking state" {
    const fixture = try std.fmt.allocPrint(std.testing.allocator,
        \\{{"{s}":{{"env":{{"currentCoinbase":"0x0000000000000000000000000000000000000000","currentGasLimit":"0x0f4240","currentNumber":"0x01","currentDifficulty":"0x00","currentTimestamp":"0x00","currentBaseFee":"0x00"}},"pre":{{"0x0000000000000000000000000000000000001000":{{"balance":"0x00","nonce":"0x00","code":"0x60{s}600055","storage":{{}}}},"0x000000000000000000000000000000000000aaaa":{{"balance":"0xffff","nonce":"0x00","code":"0x","storage":{{}}}}}},"transaction":{{"sender":"0x000000000000000000000000000000000000aaaa","to":"0x0000000000000000000000000000000000001000","gasLimit":["0x0186a0"],"gasPrice":"0x00","value":["0x00"],"data":["0x"]}},"post":{{"Cancun":[{{"indexes":{{"data":0,"gas":0,"value":0}},"state":{{"0x0000000000000000000000000000000000001000":{{"storage":{{"0x00":"0x{s}"}}}}}}}}]}}}},"{s}":{{"env":{{"currentCoinbase":"0x0000000000000000000000000000000000000000","currentGasLimit":"0x0f4240","currentNumber":"0x02","currentDifficulty":"0x00","currentTimestamp":"0x00","currentBaseFee":"0x00"}},"pre":{{"0x0000000000000000000000000000000000001000":{{"balance":"0x00","nonce":"0x00","code":"0x60{s}600055","storage":{{}}}},"0x000000000000000000000000000000000000aaaa":{{"balance":"0xffff","nonce":"0x00","code":"0x","storage":{{}}}}}},"transaction":{{"sender":"0x000000000000000000000000000000000000aaaa","to":"0x0000000000000000000000000000000000001000","gasLimit":["0x0186a0"],"gasPrice":"0x00","value":["0x00"],"data":["0x"]}},"post":{{"Cancun":[{{"indexes":{{"data":0,"gas":0,"value":0}},"state":{{"0x0000000000000000000000000000000000001000":{{"storage":{{"0x00":"0x{s}"}}}}}}}}]}}}}}}
    , .{ "first_sstore", "2a", "2a", "second_sstore", "2b", "2b" });
    defer std.testing.allocator.free(fixture);

    const summary = try runSlice(std.testing.allocator, fixture, .{});
    try std.testing.expectEqual(@as(usize, 2), summary.fixtures);
    try std.testing.expectEqual(@as(usize, 2), summary.vectors);
    try std.testing.expectEqual(@as(usize, 2), summary.passed);
    try std.testing.expectEqual(@as(usize, 0), summary.failed);
    try std.testing.expectEqual(@as(usize, 0), summary.skipped);
    try std.testing.expectEqual(@as(usize, 0), summary.unchecked);
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

test "EEST oversized transaction nonce reaches exact-spec validation" {
    const summary = try runMinimalStateFixture(
        ",\"nonce\":\"0x010000000000000000\"",
        "0x0186a0",
        "0x",
        ",\"expectException\":\"TransactionException.NONCE_IS_MAX\"",
        "\"storage\":{}",
    );
    try std.testing.expectEqual(@as(usize, 1), summary.passed);
    try std.testing.expectEqual(@as(usize, 0), summary.failed);
    try std.testing.expectEqual(@as(usize, 0), summary.unchecked);
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
        ",\"logs\":\"0x00\",\"receipt\":{},\"txbytes\":\"0x00\"",
        "\"storage\":{\"0x00\":\"0x2a\"}",
    );
    try std.testing.expectEqual(@as(usize, 1), summary.passed);
    try std.testing.expectEqual(@as(usize, 0), summary.failed);
    try std.testing.expectEqual(@as(usize, 0), summary.unchecked);
}

test "EEST post hash compares the canonical MPT state root" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const scratch = arena.allocator();

    const storage_key = evmz.eth.trie.hashedStorageKey(0);
    const storage_value = try evmz.eth.trie.storageValue(scratch, 42);
    const storage_root = try evmz.eth.trie.root(scratch, &.{.{ .key = &storage_key, .value = storage_value }});

    const contract_key = evmz.eth.trie.hashedAddressKey(evmz.addr(0x1000));
    const contract_value = try evmz.eth.trie.accountValueFrom(scratch, .{
        .storage_root = storage_root,
        .code_hash = evmz.crypto.keccak256(&.{ 0x60, 0x2a, 0x60, 0x00, 0x55 }),
    });
    const sender_key = evmz.eth.trie.hashedAddressKey(evmz.addr(0xaaaa));
    const sender_value = try evmz.eth.trie.accountValueFrom(scratch, .{
        .nonce = 1,
        .balance = 0xffff,
    });
    const expected_root = try evmz.eth.trie.root(scratch, &.{
        .{ .key = &contract_key, .value = contract_value },
        .{ .key = &sender_key, .value = sender_value },
    });
    const root_hex = std.fmt.bytesToHex(expected_root, .lower);
    const post_extra = try std.fmt.allocPrint(scratch, ",\"hash\":\"0x{s}\"", .{&root_hex});

    const summary = try runMinimalStateFixture(
        "",
        "0x0186a0",
        "0x",
        post_extra,
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
        \\        "logs": "0x00",
        \\        "receipt": {},
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

test "EEST still checks output when using tool-owned execution" {
    const fixture =
        \\{"empty_call":{"env":{"currentGasLimit":"0x100000"},
        \\"pre":{"0x000000000000000000000000000000000000aaaa":{"balance":"0xffff","nonce":"0x0","code":"0x","storage":{}}},
        \\"transaction":{"sender":"0x000000000000000000000000000000000000aaaa","to":"0x000000000000000000000000000000000000bbbb","gasLimit":["0x186a0"],"gasPrice":"0x0","value":["0x0"],"data":["0x"]},
        \\"out":"0x01","post":{"Cancun":[{"indexes":{"data":0,"gas":0,"value":0}}]}}}
    ;
    const summary = try runSlice(std.testing.allocator, fixture, .{});
    try std.testing.expectEqual(@as(usize, 1), summary.failed);
    try std.testing.expectEqual(@as(usize, 1), summary.fail_reasons[@intFromEnum(FailReason.output_mismatch)]);
}
