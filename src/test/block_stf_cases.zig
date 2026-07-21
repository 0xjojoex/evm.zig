const std = @import("std");
const evmz = @import("../evm.zig");

const JsonArray = std.json.Array;
const JsonObject = std.json.ObjectMap;
const JsonValue = std.json.Value;

const address = evmz.address;
const bal = evmz.eth.bal;
const block_stf = evmz.eth.block_stf;
const trie = evmz.eth.trie;

const cases_json = @embedFile("fixtures/block_stf/cases.json");
const withdrawal_gwei_in_wei: u256 = 1_000_000_000;

test "BlockSTF semantic fixture corpus maps to adapter contract" {
    var parsed = try std.json.parseFromSlice(JsonValue, std.testing.allocator, cases_json, .{
        .parse_numbers = false,
    });
    defer parsed.deinit();

    var root = try expectObject(parsed.value);
    try std.testing.expectEqualStrings("evmz/block-stf-semantic-fixture/v1", try stringField(&root, "schema"));

    var defaults = try expectObject(try field(&root, "defaults"));
    try std.testing.expectEqualStrings("amsterdam", try stringField(&defaults, "fork"));
    try std.testing.expectEqualStrings("mutate_exactly_one_side_and_freeze_the_other", try stringField(&defaults, "comparison_rule"));

    const phase_order = try expectArray(try field(&defaults, "phase_order"));
    try expectStringArray(phase_order, &.{
        "pre_system",
        "transactions",
        "withdrawals",
        "post_system",
        "derive_commitments",
        "compare_or_commit",
    });

    var indexing = try expectObject(try field(&defaults, "indexing"));
    try std.testing.expectEqualStrings("0", try stringField(&indexing, "pre_system"));
    try std.testing.expectEqualStrings("one_based_position", try stringField(&indexing, "transaction"));
    try std.testing.expectEqualStrings("transaction_count_plus_one", try stringField(&indexing, "post_system"));

    const cases = try expectArray(try field(&root, "cases"));
    try std.testing.expectEqual(@as(usize, 24), cases.items.len);

    var mutation_count: usize = 0;
    var future_status_count: usize = 0;
    for (cases.items) |case_value| {
        var case_object = try expectObject(case_value);
        _ = try stringField(&case_object, "id");

        if (case_object.get("expect")) |expect_value| {
            future_status_count += try assertExpectStatusesKnown(expect_value);
        }
        if (case_object.get("mutations")) |mutations_value| {
            const mutations = try expectArray(mutations_value);
            mutation_count += mutations.items.len;
            for (mutations.items) |mutation_value| {
                try assertMutationStatusesKnown(mutation_value);
            }
        }
    }

    try std.testing.expectEqual(@as(usize, 31), mutation_count);
    try std.testing.expectEqual(@as(usize, 3), future_status_count);

    inline for (.{
        "empty-amsterdam-block-has-empty-requests-commitment",
        "bal-size-boundary-counts-unique-addresses-and-slots",
        "malformed-provided-bal-rejected-before-execution",
        "withdrawals-share-post-index-and-coalesce",
    }) |id| {
        _ = try caseById(cases, id);
    }

    var combined = try caseById(cases, "combined-block-lifecycle-and-commitments");
    const combined_mutations = try expectArray(try field(&combined, "mutations"));
    try std.testing.expectEqual(@as(usize, 10), combined_mutations.items.len);
}

test "BlockSTF semantic case smoke: empty Amsterdam block commitments" {
    try assertFixtureCaseExists("empty-amsterdam-block-has-empty-requests-commitment");

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const scratch = arena.allocator();

    const empty_accounts: []const bal.AccountChanges = &.{};
    const empty_claim = try bal.encodeAlloc(scratch, empty_accounts);

    const valid = try block_stf.applyAssumeDecoded(scratch, .{
        .revision = .amsterdam,
        .state_backend = try evmz.state.Backend.fromWitness(scratch, trie.empty_root_hash, &.{}, &.{}),
        .transactions = &.{},
        .block_access_list = empty_claim,
        .root_checks = testRootChecks(trie.empty_root_hash, trie.empty_root_hash, trie.empty_root_hash),
        .header_claims = .{
            .requests_hash = block_stf.empty_requests_hash,
            .block_access_list_hash = bal.empty_hash,
        },
    });
    try std.testing.expectEqual(block_stf.Status.valid, valid.status);
    try std.testing.expectEqualSlices(u8, &block_stf.empty_requests_hash, &valid.requests_hash);
    try std.testing.expectEqualSlices(u8, &bal.empty_hash, &valid.block_access_list_hash);

    var wrong_requests_hash = block_stf.empty_requests_hash;
    wrong_requests_hash[31] ^= 1;
    const mismatch = try block_stf.applyAssumeDecoded(scratch, .{
        .revision = .amsterdam,
        .state_backend = try evmz.state.Backend.fromWitness(scratch, trie.empty_root_hash, &.{}, &.{}),
        .transactions = &.{},
        .block_access_list = empty_claim,
        .root_checks = testRootChecks(trie.empty_root_hash, trie.empty_root_hash, trie.empty_root_hash),
        .header_claims = .{
            .requests_hash = wrong_requests_hash,
            .block_access_list_hash = bal.empty_hash,
        },
    });
    try std.testing.expectEqual(block_stf.Status.requests_hash_mismatch, mismatch.status);
}

test "BlockSTF semantic case smoke: provided BAL is structurally validated first" {
    try assertFixtureCaseExists("malformed-provided-bal-rejected-before-execution");

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const scratch = arena.allocator();

    const result = try block_stf.applyAssumeDecoded(scratch, .{
        .revision = .amsterdam,
        .state_backend = try evmz.state.Backend.fromWitness(scratch, trie.empty_root_hash, &.{}, &.{}),
        .transactions = &.{},
        .block_access_list = &.{0xff},
        .root_checks = testRootChecks(trie.empty_root_hash, trie.empty_root_hash, trie.empty_root_hash),
    });
    try std.testing.expectEqual(block_stf.Status.invalid_block_access_list, result.status);
}

test "BlockSTF semantic case smoke: BAL size excess maps to status" {
    try assertFixtureCaseExists("bal-size-boundary-counts-unique-addresses-and-slots");

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const scratch = arena.allocator();

    const accounts = [_]bal.AccountChanges{.{ .address = address.addr(0xbeef) }};
    const claim = try bal.encodeAlloc(scratch, &accounts);
    const result = try block_stf.applyAssumeDecoded(scratch, .{
        .revision = .amsterdam,
        .env = .{ .gas_limit = bal.item_cost - 1 },
        .state_backend = try evmz.state.Backend.fromWitness(scratch, trie.empty_root_hash, &.{}, &.{}),
        .transactions = &.{},
        .block_access_list = claim,
        .root_checks = testRootChecks(trie.empty_root_hash, trie.empty_root_hash, trie.empty_root_hash),
    });
    try std.testing.expectEqual(block_stf.Status.block_access_list_too_large, result.status);
}

test "BlockSTF semantic case smoke: withdrawals coalesce at post index" {
    try assertFixtureCaseExists("withdrawals-share-post-index-and-coalesce");

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const scratch = arena.allocator();

    const recipient_a = address.addr(0x7777);
    const recipient_b = address.addr(0x8888);
    const withdrawals = [_]evmz.eth.Withdrawal{
        .{ .index = 0, .validator_index = 1, .address = recipient_a, .amount = 0 },
        .{ .index = 1, .validator_index = 2, .address = recipient_a, .amount = 3 },
        .{ .index = 2, .validator_index = 3, .address = recipient_b, .amount = 0 },
    };

    const credited_balance = 3 * withdrawal_gwei_in_wei;
    const account_a_key = trie.hashedAddressKey(recipient_a);
    const account_a_value = try trie.accountValueFrom(scratch, .{ .balance = credited_balance });
    const expected_state_pairs = [_]trie.Pair{.{ .key = &account_a_key, .value = account_a_value }};
    const expected_state_root = try trie.root(scratch, &expected_state_pairs);
    const expected_withdrawals_root = try trie.withdrawalsRoot(scratch, &withdrawals);

    const balance_changes_a = [_]bal.BalanceChange{.{
        .block_access_index = 1,
        .post_balance = credited_balance,
    }};
    const claimed_accounts = [_]bal.AccountChanges{
        .{ .address = recipient_a, .balance_changes = &balance_changes_a },
        .{ .address = recipient_b },
    };
    const claimed_bal = try bal.encodeAlloc(scratch, &claimed_accounts);

    const result = try block_stf.applyAssumeDecoded(scratch, .{
        .revision = .amsterdam,
        .state_backend = try evmz.state.Backend.fromWitness(scratch, trie.empty_root_hash, &.{}, &.{}),
        .transactions = &.{},
        .withdrawals = &withdrawals,
        .block_access_list = claimed_bal,
        .root_checks = testRootChecksWithWithdrawals(
            expected_state_root,
            trie.empty_root_hash,
            trie.empty_root_hash,
            expected_withdrawals_root,
        ),
    });
    try std.testing.expectEqual(block_stf.Status.valid, result.status);
}

fn assertFixtureCaseExists(id: []const u8) !void {
    var parsed = try std.json.parseFromSlice(JsonValue, std.testing.allocator, cases_json, .{
        .parse_numbers = false,
    });
    defer parsed.deinit();

    var root = try expectObject(parsed.value);
    _ = try caseById(try expectArray(try field(&root, "cases")), id);
}

fn assertExpectStatusesKnown(value: JsonValue) !usize {
    var future_status_count: usize = 0;
    var expect_object = try expectObject(value);
    if (expect_object.get("status")) |status_value| {
        if (try assertStatusKnown(jsonString(status_value) orelse return error.MalformedFixture)) {
            future_status_count += 1;
        }
    }
    if (expect_object.get("assertions")) |assertions_value| {
        const assertions = try expectArray(assertions_value);
        for (assertions.items) |assertion_value| {
            var assertion = try expectObject(assertion_value);
            const kind = try stringField(&assertion, "kind");
            if (std.mem.eql(u8, kind, "status_category")) {
                if (try assertStatusKnown(try stringField(&assertion, "value"))) {
                    future_status_count += 1;
                }
            }
        }
    }
    return future_status_count;
}

fn assertMutationStatusesKnown(value: JsonValue) !void {
    var mutation = try expectObject(value);
    if (mutation.get("expect_status")) |status_value| {
        _ = try assertStatusKnown(jsonString(status_value) orelse return error.MalformedFixture);
    }
    if (mutation.get("expect_status_any")) |statuses_value| {
        const statuses = try expectArray(statuses_value);
        for (statuses.items) |status_value| {
            _ = try assertStatusKnown(jsonString(status_value) orelse return error.MalformedFixture);
        }
    }
}

fn assertStatusKnown(name: []const u8) !bool {
    if (concreteStatus(name) != null) return false;
    if (futureStatusCategory(name)) return true;
    return error.UnknownBlockStfStatusCategory;
}

fn concreteStatus(name: []const u8) ?block_stf.Status {
    const mappings = [_]struct {
        name: []const u8,
        status: block_stf.Status,
    }{
        .{ .name = "state_root_mismatch", .status = .state_root_mismatch },
        .{ .name = "transactions_root_mismatch", .status = .transactions_root_mismatch },
        .{ .name = "receipts_root_mismatch", .status = .receipts_root_mismatch },
        .{ .name = "withdrawals_root_mismatch", .status = .withdrawals_root_mismatch },
        .{ .name = "requests_hash_mismatch", .status = .requests_hash_mismatch },
        .{ .name = "block_access_list_mismatch", .status = .block_access_list_mismatch },
        .{ .name = "block_access_list_hash_mismatch", .status = .block_access_list_hash_mismatch },
        .{ .name = "invalid_block_access_list", .status = .invalid_block_access_list },
        .{ .name = "block_access_list_too_large", .status = .block_access_list_too_large },
    };

    for (mappings) |mapping| {
        if (std.mem.eql(u8, mapping.name, name)) return mapping.status;
    }
    return null;
}

fn futureStatusCategory(name: []const u8) bool {
    return std.mem.eql(u8, name, "invalid_deposit_event") or
        std.mem.eql(u8, name, "withdrawal_system_call_failure") or
        std.mem.eql(u8, name, "consolidation_system_call_failure");
}

fn caseById(cases: JsonArray, id: []const u8) !JsonObject {
    for (cases.items) |case_value| {
        var case_object = try expectObject(case_value);
        if (std.mem.eql(u8, try stringField(&case_object, "id"), id)) return case_object;
    }
    return error.MissingFixtureCase;
}

fn testRootChecks(header_state: [32]u8, header_transactions: [32]u8, header_receipts: [32]u8) block_stf.RootChecks {
    return testRootChecksWithWithdrawals(header_state, header_transactions, header_receipts, trie.empty_root_hash);
}

fn testRootChecksWithWithdrawals(header_state: [32]u8, header_transactions: [32]u8, header_receipts: [32]u8, header_withdrawals: [32]u8) block_stf.RootChecks {
    return .{
        .payload_header = .{
            .state = .fromHash(header_state),
            .receipts = .fromHash(header_receipts),
        },
        .reconstructed_header = .{
            .transactions = .fromHash(header_transactions),
            .withdrawals = .fromHash(header_withdrawals),
        },
    };
}

fn expectStringArray(array: JsonArray, expected: []const []const u8) !void {
    try std.testing.expectEqual(expected.len, array.items.len);
    for (expected, 0..) |expected_item, index| {
        try std.testing.expectEqualStrings(expected_item, jsonString(array.items[index]) orelse return error.MalformedFixture);
    }
}

fn field(object: *const JsonObject, name: []const u8) !JsonValue {
    return object.get(name) orelse error.MalformedFixture;
}

fn stringField(object: *const JsonObject, name: []const u8) ![]const u8 {
    return jsonString(try field(object, name)) orelse error.MalformedFixture;
}

fn expectObject(value: JsonValue) !JsonObject {
    return switch (value) {
        .object => |object| object,
        else => error.MalformedFixture,
    };
}

fn expectArray(value: JsonValue) !JsonArray {
    return switch (value) {
        .array => |array| array,
        else => error.MalformedFixture,
    };
}

fn jsonString(value: JsonValue) ?[]const u8 {
    return switch (value) {
        .string => |string| string,
        .number_string => |string| string,
        else => null,
    };
}
