const std = @import("std");
const evmz = @import("evmz");
const fixture_common = @import("fixture.zig");
const tx_validation = @import("tx_validation.zig");

const Address = evmz.Address;
const Host = evmz.Host;
const Interpreter = evmz.Interpreter;
const JsonValue = fixture_common.JsonValue;
const transaction = evmz.transaction;
const Executor = evmz.Executor;
const AccountState = evmz.state.AccountState;

const asArray = fixture_common.asArray;
const asObject = fixture_common.asObject;
const authorizationListLen = fixture_common.authorizationListLen;
const jsonString = fixture_common.jsonString;
const parseAccessListEntry = fixture_common.parseAccessListEntry;
const parseAddress = fixture_common.parseAddress;
const parseAddressFromValue = fixture_common.parseAddressFromValue;
const parseBlobHashes = fixture_common.parseBlobHashes;
const parseBytesFromValue = fixture_common.parseBytesFromValue;
const parseFork = fixture_common.parseStateFork;
const parseHexInt = fixture_common.parseHexInt;
const parseU256FromValue = fixture_common.parseU256FromValue;
const parseU64FromValue = fixture_common.parseU64FromValue;
const seedMemoryBackend = fixture_common.seedMemoryBackend;
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
};

pub const UncheckedReason = enum(u8) {
    missing_post_state,
    no_comparable_fields,
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
        runFixture(allocator, test_name, entry.value_ptr.*, options, &summary) catch {
            summary.vectors += 1;
            summary.countFail(.malformed_fixture);
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
            runVector(allocator, &fixture_obj, post, spec, summary) catch {
                summary.countFail(.malformed_fixture);
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
    const expected_exception = if (post_obj.get("expectException")) |value|
        jsonString(value) orelse return error.MalformedFixture
    else
        null;

    const tx = asObject(fixture.get("transaction") orelse return error.MalformedFixture) orelse return error.MalformedFixture;
    const env = asObject(fixture.get("env") orelse return error.MalformedFixture) orelse return error.MalformedFixture;
    const pre = asObject(fixture.get("pre") orelse return error.MalformedFixture) orelse return error.MalformedFixture;
    const indexes = asObject(post_obj.get("indexes") orelse return error.MalformedFixture) orelse return error.MalformedFixture;

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

    const authorization_count = authorizationListLen(&tx);
    const access_list_counts = try selectedAccessListCounts(&tx, data_index);
    const gas_limit = try selectedU64(&tx, "gasLimit", gas_index);
    const intrinsic_options = transaction.IntrinsicGasOptions{
        .authorization_count = authorization_count,
        .access_list_counts = access_list_counts,
        .is_create = is_create,
    };
    const intrinsic_gas = transaction.intrinsicGasForTransaction(spec, input, intrinsic_options) orelse std.math.maxInt(u64);
    const minimum_gas = transaction.minimumGasForTransaction(spec, input, intrinsic_options) orelse std.math.maxInt(u64);
    const execution_gas = if (gas_limit >= minimum_gas) gas_limit - intrinsic_gas else null;
    const value = try selectedU256(&tx, "value", value_index);
    const blob_hashes = try parseBlobHashes(allocator, &tx);
    defer allocator.free(blob_hashes);
    const base_fee = if (env.get("currentBaseFee")) |v| try parseU256FromValue(v) else 0;
    const blob_base_fee = try parseBlobBaseFee(spec, &env);
    const sender_state = try senderValidationState(&pre, sender);
    const validation_error = transaction.validate(.{
        .spec = spec,
        .kind = inferTxKind(&tx),
        .is_create = is_create,
        .gas_limit = gas_limit,
        .input = input,
        .value = value,
        .gas_price = try optionalU256(&tx, "gasPrice") orelse 0,
        .base_fee = base_fee,
        .block_gas_limit = if (env.get("currentGasLimit")) |v| try parseU64FromValue(v) else 0,
        .blob_base_fee = blob_base_fee,
        .max_fee_per_gas = try optionalU256(&tx, "maxFeePerGas"),
        .max_priority_fee_per_gas = try optionalU256(&tx, "maxPriorityFeePerGas"),
        .max_fee_per_blob_gas = try optionalU256(&tx, "maxFeePerBlobGas"),
        .sender_balance = sender_state.balance,
        .sender_nonce = sender_state.nonce,
        .sender_code_kind = sender_state.code_kind,
        .authorization_count = authorization_count,
        .access_list_counts = access_list_counts,
        .blob_hashes = blob_hashes,
    });
    if (expected_exception) |expected| {
        if (validation_error) |err| {
            if (tx_validation.validationErrorMatchesEest(err, expected)) {
                summary.passed += 1;
                return;
            }
        }
        summary.countFail(.expected_transaction_exception);
        return;
    }
    if (validation_error != null) {
        summary.countFail(.unexpected_status);
        return;
    }
    const recipient = if (is_create) null else try parseAddress(to_string);
    const tx_context = try parseTxContext(spec, &env, &tx, sender, blob_hashes);

    var host = try FixtureHost.init(allocator, &pre, tx_context, spec, sender, recipient);
    defer host.deinit();
    const transaction_charged = if (execution_gas != null)
        try host.chargeTransactionCosts(sender, gas_limit, value)
    else
        false;
    if (transaction_charged) {
        if (!is_create) {
            try host.incrementNonce(sender);
        }
        try host.processAccessList(&tx, data_index);
        try host.processAuthorizationList(&tx);
    }
    var pre_execution_state = try host.snapshot();
    defer pre_execution_state.deinit(allocator);

    var result = Interpreter.Result{
        .status = .out_of_gas,
        .gas_left = 0,
        .gas_refund = 0,
        .output_data = &.{},
    };
    if (execution_gas) |gas| {
        if (!transaction_charged) {
            result.status = .invalid;
        } else if (is_create) {
            result = try host.executeCreateTransaction(sender, input, gas, value);
        } else {
            result = try host.executeCallTransaction(sender, recipient.?, input, gas, value);
        }
    }
    if (Executor.executionRolledBack(result.status)) {
        try host.restore(&pre_execution_state);
        if (is_create and transaction_charged) {
            try host.incrementNonce(sender);
        }
    } else {
        try host.finalizeTransaction();
    }

    var compared_fields: usize = 0;
    if (fixture.get("out")) |expected_out| {
        const expected = try parseBytesFromValue(allocator, expected_out);
        defer allocator.free(expected);
        compared_fields += 1;
        if (!std.mem.eql(u8, result.output_data, expected)) {
            summary.countFail(.output_mismatch);
            return;
        }
    }

    const state_value = post_obj.get("state") orelse {
        if (compared_fields == 0) {
            summary.countUnchecked(.missing_post_state);
        } else {
            summary.passed += 1;
        }
        return;
    };
    const state = asObject(state_value) orelse return error.MalformedFixture;
    if (try comparePostState(allocator, &host, &state, &compared_fields)) |reason| {
        summary.countFail(reason);
        return;
    }

    if (compared_fields == 0) {
        summary.countUnchecked(.no_comparable_fields);
    } else {
        summary.passed += 1;
    }
}

fn selectedAccessListCounts(tx: *const std.json.ObjectMap, index: usize) !transaction.AccessListCounts {
    var result = transaction.AccessListCounts{};
    const selected = try selectedAccessList(tx, index) orelse return result;
    for (selected.items) |item| {
        const entry = try parseAccessListEntry(item);
        result.addresses = std.math.add(usize, result.addresses, 1) catch return error.Overflow;
        for (entry.storage_keys.items) |key_value| {
            _ = try parseU256FromValue(key_value);
            result.storage_keys = std.math.add(usize, result.storage_keys, 1) catch return error.Overflow;
        }
    }
    return result;
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
        const actual = try host.getAccount(address);

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
                const actual_value = if (actual) |account| account.getStorage(key) else 0;
                compared_fields.* += 1;
                if (actual_value != expected_value) return .storage_mismatch;
            }
        }
    }

    return null;
}

fn parseTxContext(
    spec: evmz.Spec,
    env: *const std.json.ObjectMap,
    tx: *const std.json.ObjectMap,
    sender: Address,
    blob_hashes: []const u256,
) !Host.TxContext {
    const base_fee = if (env.get("currentBaseFee")) |v| try parseU256FromValue(v) else 0;
    const gas_price = if (tx.get("gasPrice")) |v|
        try parseU256FromValue(v)
    else if (tx.get("maxFeePerGas")) |v| blk: {
        const max_fee = try parseU256FromValue(v);
        const priority_fee = if (tx.get("maxPriorityFeePerGas")) |priority| try parseU256FromValue(priority) else 0;
        const effective_tip = std.math.add(u256, base_fee, priority_fee) catch std.math.maxInt(u256);
        break :blk @min(max_fee, effective_tip);
    } else 0;

    return Host.TxContext{
        .chain_id = if (env.get("currentChainId")) |v| try parseU256FromValue(v) else 1,
        .gas_price = gas_price,
        .origin = sender,
        .coinbase = if (env.get("currentCoinbase")) |v| try parseAddressFromValue(v) else evmz.addr(0),
        .number = if (env.get("currentNumber")) |v| try parseU64FromValue(v) else 0,
        .timestamp = if (env.get("currentTimestamp")) |v| try parseU64FromValue(v) else 0,
        .gas_limit = if (env.get("currentGasLimit")) |v| try parseU64FromValue(v) else 0,
        .prev_randao = if (env.get("currentRandom")) |v| try parseU256FromValue(v) else if (env.get("currentDifficulty")) |v| try parseU256FromValue(v) else 0,
        .base_fee = base_fee,
        .blob_base_fee = try parseBlobBaseFee(spec, env),
        .blob_hashes = blob_hashes,
    };
}

fn parseBlobBaseFee(spec: evmz.Spec, env: *const std.json.ObjectMap) !u256 {
    if (env.get("currentBlobBaseFee")) |value| return parseU256FromValue(value);
    const excess_blob_gas = if (env.get("currentExcessBlobGas")) |value| try parseU256FromValue(value) else 0;
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

fn inferTxKind(tx: *const std.json.ObjectMap) transaction.TxKind {
    if (tx.get("authorizationList") != null) return .set_code;
    if (tx.get("blobVersionedHashes") != null or tx.get("maxFeePerBlobGas") != null) return .blob;
    if (tx.get("maxFeePerGas") != null or tx.get("maxPriorityFeePerGas") != null) return .dynamic_fee;
    if (tx.get("accessLists") != null) return .access_list;
    return .legacy;
}

const SenderValidationState = struct {
    balance: u256 = 0,
    nonce: u64 = 0,
    code_kind: transaction.SenderCodeKind = .empty,
};

fn senderValidationState(pre: *const std.json.ObjectMap, sender: Address) !SenderValidationState {
    var it = pre.iterator();
    while (it.next()) |entry| {
        const address = try parseAddress(entry.key_ptr.*);
        if (!std.mem.eql(u8, &address, &sender)) continue;

        const account = asObject(entry.value_ptr.*) orelse return error.MalformedFixture;
        return .{
            .balance = if (account.get("balance")) |value| try parseU256FromValue(value) else 0,
            .nonce = if (account.get("nonce")) |value| try parseU64FromValue(value) else 0,
            .code_kind = if (account.get("code")) |value| try senderCodeKindFromValue(value) else .empty,
        };
    }
    return .{};
}

fn senderCodeKindFromValue(value: JsonValue) !transaction.SenderCodeKind {
    const string = jsonString(value) orelse return error.MalformedFixture;
    const hex = strip0x(string);
    if (hex.len == 0) return .empty;
    if (isDelegationCodeHex(hex)) return .delegation;
    return .non_delegating;
}

fn isDelegationCodeHex(hex: []const u8) bool {
    if (hex.len != Executor.eip7702.delegation_code_len * 2) return false;
    const designator = Executor.eip7702.delegation_designator;
    for (designator, 0..) |byte, i| {
        const high = std.fmt.charToDigit(hex[i * 2], 16) catch return false;
        const low = std.fmt.charToDigit(hex[i * 2 + 1], 16) catch return false;
        if (((high << 4) | low) != byte) return false;
    }
    return true;
}

const FixtureHost = struct {
    allocator: std.mem.Allocator,
    backend: *evmz.state.MemoryBackend,
    executor: Executor,

    const Self = @This();

    fn init(
        allocator: std.mem.Allocator,
        pre: *const std.json.ObjectMap,
        tx_context: Host.TxContext,
        spec: evmz.Spec,
        sender: Address,
        recipient: ?Address,
    ) !Self {
        const backend = try allocator.create(evmz.state.MemoryBackend);
        errdefer allocator.destroy(backend);
        backend.* = evmz.state.MemoryBackend.init(allocator);
        errdefer backend.deinit();

        try seedMemoryBackend(allocator, backend, pre);

        var executor = Executor.init(allocator, .{
            .spec = spec,
            .backend = backend.backend(),
        });
        errdefer executor.deinit();

        if (recipient) |address| {
            try executor.beginTransaction(tx_context, sender, address);
        } else {
            try executor.beginCreateTransaction(tx_context, sender);
        }

        return .{
            .allocator = allocator,
            .backend = backend,
            .executor = executor,
        };
    }

    fn deinit(self: *Self) void {
        self.executor.deinit();
        self.backend.deinit();
        self.allocator.destroy(self.backend);
    }

    fn getAccount(self: *Self, address: Address) !?*AccountState {
        return self.executor.getAccountOrLoad(address);
    }

    fn snapshot(self: *Self) !Executor.Snapshot {
        return self.executor.snapshot();
    }

    fn restore(self: *Self, snapshot_state: *Executor.Snapshot) !void {
        try self.executor.restore(snapshot_state);
    }

    fn finalizeTransaction(self: *Self) !void {
        try self.executor.finalizeTransaction();
    }

    fn incrementNonce(self: *Self, address: Address) !void {
        try self.executor.incrementNonce(address);
    }

    fn chargeTransactionCosts(self: *Self, sender: Address, gas_limit: u64, value: u256) !bool {
        return self.executor.chargeTransactionCosts(sender, gas_limit, value);
    }

    fn executeCallTransaction(
        self: *Self,
        sender: Address,
        recipient: Address,
        input: []const u8,
        gas: u64,
        value: u256,
    ) !Interpreter.Result {
        return self.executor.executeCallTransaction(sender, recipient, input, gas, value);
    }

    fn executeCreateTransaction(
        self: *Self,
        sender: Address,
        init_code: []const u8,
        gas: u64,
        value: u256,
    ) !Interpreter.Result {
        const result = (try self.executor.executeCreateTransaction(sender, init_code, gas, value)).expectCreate();
        return .{
            .status = result.status,
            .gas_left = result.gas_left,
            .gas_refund = result.gas_refund,
            .output_data = self.executor.last_call_output,
        };
    }

    fn processAccessList(self: *Self, tx: *const std.json.ObjectMap, index: usize) !void {
        const selected = try selectedAccessList(tx, index) orelse return;
        for (selected.items) |item| {
            const entry = try parseAccessListEntry(item);
            try self.executor.warmAccessListAddress(entry.address);
            for (entry.storage_keys.items) |key_value| {
                const key = try parseU256FromValue(key_value);
                try self.executor.warmAccessListStorage(entry.address, key);
            }
        }
    }

    fn processAuthorizationList(self: *Self, tx: *const std.json.ObjectMap) !void {
        if (!self.executor.spec.isImpl(.prague)) return;
        const list_value = tx.get("authorizationList") orelse return;
        const list = asArray(list_value) orelse return;
        for (list.items) |item| {
            const auth = asObject(item) orelse continue;
            try self.processAuthorizationTuple(&auth);
        }
    }

    fn processAuthorizationTuple(self: *Self, auth: *const std.json.ObjectMap) !void {
        const y_parity = parseU256FromValue(auth.get("yParity") orelse auth.get("v") orelse return) catch return;
        const legacy_v = if (auth.get("v")) |value| parseU256FromValue(value) catch return else null;
        const r = parseU256FromValue(auth.get("r") orelse return) catch return;
        const s = parseU256FromValue(auth.get("s") orelse return) catch return;
        const chain_id = parseU256FromValue(auth.get("chainId") orelse return) catch return;
        const target = parseAddressFromValue(auth.get("address") orelse return) catch return;
        const signer = parseAddressFromValue(auth.get("signer") orelse return) catch return;
        const nonce_value = parseU256FromValue(auth.get("nonce") orelse return) catch return;
        const nonce = std.math.cast(u64, nonce_value) orelse return;

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
