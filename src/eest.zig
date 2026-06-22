const std = @import("std");
const evmz = @import("evm.zig");

const Address = evmz.Address;
const Host = evmz.Host;
const Interpreter = evmz.Interpreter;
const JsonValue = std.json.Value;

pub const Options = struct {
    fork_filter: ?[]const u8 = null,
    test_filter: ?[]const u8 = null,
};

pub const SkipReason = enum(u8) {
    unsupported_fork,
    malformed_fixture,
    create_transaction,
    missing_sender,
    expected_transaction_exception,
    access_list,
};

pub const FailReason = enum(u8) {
    unexpected_status,
    output_mismatch,
    code_mismatch,
    storage_mismatch,
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
    skip_reasons: [std.meta.fields(SkipReason).len]usize = [_]usize{0} ** std.meta.fields(SkipReason).len,
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
        for (&self.skip_reasons, other.skip_reasons) |*target, value| {
            target.* += value;
        }
        for (&self.unchecked_reasons, other.unchecked_reasons) |*target, value| {
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
            summary.countSkip(.malformed_fixture);
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
                summary.countSkip(.unsupported_fork);
            }
            continue;
        };

        for (vectors.items) |post| {
            summary.vectors += 1;
            runVector(allocator, &fixture_obj, post, spec, summary) catch {
                summary.countSkip(.malformed_fixture);
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
    if (post_obj.get("expectException") != null) {
        summary.countSkip(.expected_transaction_exception);
        return;
    }

    const tx = asObject(fixture.get("transaction") orelse return error.MalformedFixture) orelse return error.MalformedFixture;
    const env = asObject(fixture.get("env") orelse return error.MalformedFixture) orelse return error.MalformedFixture;
    const pre = asObject(fixture.get("pre") orelse return error.MalformedFixture) orelse return error.MalformedFixture;
    const indexes = asObject(post_obj.get("indexes") orelse return error.MalformedFixture) orelse return error.MalformedFixture;

    const data_index = try jsonIndex(indexes.get("data") orelse return error.MalformedFixture);
    const gas_index = try jsonIndex(indexes.get("gas") orelse return error.MalformedFixture);
    const value_index = try jsonIndex(indexes.get("value") orelse return error.MalformedFixture);

    const to_string = jsonString(tx.get("to") orelse return error.MalformedFixture) orelse return error.MalformedFixture;
    if (strip0x(to_string).len == 0) {
        summary.countSkip(.create_transaction);
        return;
    }

    const sender_string = jsonString(tx.get("sender") orelse {
        summary.countSkip(.missing_sender);
        return;
    }) orelse return error.MalformedFixture;

    if (hasSelectedAccessList(&tx, data_index)) {
        summary.countSkip(.access_list);
        return;
    }

    const recipient = try parseAddress(to_string);
    const sender = try parseAddress(sender_string);
    const input = try selectedBytes(allocator, &tx, "data", data_index);
    defer allocator.free(input);

    const gas_limit = try selectedU64(&tx, "gasLimit", gas_index);
    const value = try selectedU256(&tx, "value", value_index);
    const blob_hashes = try parseBlobHashes(allocator, &tx);
    defer allocator.free(blob_hashes);

    const tx_context = try parseTxContext(&env, &tx, sender, blob_hashes);

    var host = try FixtureHost.init(allocator, &pre, tx_context, spec, sender, recipient);
    defer host.deinit();
    var pre_execution_state = try host.snapshot();
    defer pre_execution_state.deinit(allocator);

    var host_iface = host.host();
    const code = host.getCode(recipient);
    const message = Host.Message{
        .depth = 0,
        .kind = .call,
        .gas = @intCast(gas_limit),
        .recipient = recipient,
        .sender = sender,
        .input_data = input,
        .value = value,
        .code_address = recipient,
    };

    var interpreter = Interpreter.init(allocator, &host_iface, &message, code, spec);
    defer interpreter.deinit();

    const result = interpreter.execute();
    if (executionRolledBack(result.status)) {
        try host.restore(&pre_execution_state);
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

fn executionRolledBack(status: Interpreter.Status) bool {
    return switch (status) {
        .success => false,
        .revert, .invalid, .out_of_gas => true,
        .running => unreachable,
    };
}

fn hasSelectedAccessList(tx: *const std.json.ObjectMap, index: usize) bool {
    const access_lists_value = tx.get("accessLists") orelse return false;
    const access_lists = asArray(access_lists_value) orelse return true;
    if (index >= access_lists.items.len) return true;
    const selected = asArray(access_lists.items[index]) orelse return true;
    return selected.items.len > 0;
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
        const actual = host.getAccount(address);

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
    env: *const std.json.ObjectMap,
    tx: *const std.json.ObjectMap,
    sender: Address,
    blob_hashes: []const u256,
) !Host.TxContext {
    const gas_price = if (tx.get("gasPrice")) |v|
        try parseU256FromValue(v)
    else if (tx.get("maxFeePerGas")) |v|
        try parseU256FromValue(v)
    else
        0;

    return Host.TxContext{
        .chain_id = if (env.get("currentChainId")) |v| try parseU256FromValue(v) else 1,
        .gas_price = gas_price,
        .origin = sender,
        .coinbase = if (env.get("currentCoinbase")) |v| try parseAddressFromValue(v) else evmz.addr(0),
        .number = if (env.get("currentNumber")) |v| try parseU64FromValue(v) else 0,
        .timestamp = if (env.get("currentTimestamp")) |v| try parseU64FromValue(v) else 0,
        .gas_limit = if (env.get("currentGasLimit")) |v| try parseU64FromValue(v) else 0,
        .prev_randao = if (env.get("currentRandom")) |v| try parseU256FromValue(v) else if (env.get("currentDifficulty")) |v| try parseU256FromValue(v) else 0,
        .base_fee = if (env.get("currentBaseFee")) |v| try parseU256FromValue(v) else 0,
        .blob_base_fee = if (env.get("currentBlobBaseFee")) |v| try parseU256FromValue(v) else 0,
        .blob_hashes = blob_hashes,
    };
}

fn parseBlobHashes(allocator: std.mem.Allocator, tx: *const std.json.ObjectMap) ![]u256 {
    const value = tx.get("blobVersionedHashes") orelse return &.{};
    const hashes = asArray(value) orelse return error.MalformedFixture;
    const result = try allocator.alloc(u256, hashes.items.len);
    errdefer allocator.free(result);
    for (hashes.items, 0..) |hash, i| {
        result[i] = try parseU256FromValue(hash);
    }
    return result;
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

const FixtureHost = struct {
    allocator: std.mem.Allocator,
    accounts: std.AutoHashMap(Address, AccountState),
    warm_accounts: std.AutoHashMap(Address, void),
    warm_storage: std.AutoHashMap(StorageKey, void),
    transient_storage: std.AutoHashMap(StorageKey, u256),
    logs: std.ArrayList(Host.Log),
    tx_context: Host.TxContext,
    spec: evmz.Spec,
    last_call_output: []u8 = &.{},

    const Self = @This();

    fn init(
        allocator: std.mem.Allocator,
        pre: *const std.json.ObjectMap,
        tx_context: Host.TxContext,
        spec: evmz.Spec,
        sender: Address,
        recipient: Address,
    ) !Self {
        var self = Self{
            .allocator = allocator,
            .accounts = std.AutoHashMap(Address, AccountState).init(allocator),
            .warm_accounts = std.AutoHashMap(Address, void).init(allocator),
            .warm_storage = std.AutoHashMap(StorageKey, void).init(allocator),
            .transient_storage = std.AutoHashMap(StorageKey, u256).init(allocator),
            .logs = .empty,
            .tx_context = tx_context,
            .spec = spec,
        };
        errdefer self.deinit();

        var account_it = pre.iterator();
        while (account_it.next()) |entry| {
            const address = try parseAddress(entry.key_ptr.*);
            const account_obj = asObject(entry.value_ptr.*) orelse return error.MalformedFixture;
            var account = try AccountState.fromJson(allocator, &account_obj);
            errdefer account.deinit(allocator);
            try self.accounts.put(address, account);
        }

        try self.warm_accounts.put(sender, {});
        try self.warm_accounts.put(recipient, {});
        if (spec.isImpl(.shanghai)) {
            try self.warm_accounts.put(tx_context.coinbase, {});
        }

        return self;
    }

    fn deinit(self: *Self) void {
        var account_it = self.accounts.valueIterator();
        while (account_it.next()) |account| {
            account.deinit(self.allocator);
        }
        self.accounts.deinit();
        self.warm_accounts.deinit();
        self.warm_storage.deinit();
        self.transient_storage.deinit();
        self.logs.deinit(self.allocator);
        self.allocator.free(self.last_call_output);
    }

    fn host(self: *Self) Host {
        return Host{ .ptr = self, .vtable = &.{
            .call = call,
            .accountExists = accountExists,
            .getBalance = getBalance,
            .copyCode = copyCode,
            .getCodeSize = getCodeSize,
            .getCodeHash = getCodeHash,
            .getStorage = getStorage,
            .setStorage = setStorage,
            .emitLog = emitLog,
            .getBlockHash = getBlockHash,
            .selfDestruct = selfDestruct,
            .accessStorage = accessStorage,
            .accessAccount = accessAccount,
            .getTxContext = getTxContext,
            .getTransientStorage = getTransientStorage,
            .setTransientStorage = setTransientStorage,
        } };
    }

    fn getAccount(self: *Self, address: Address) ?*AccountState {
        return self.accounts.getPtr(address);
    }

    fn snapshot(self: *Self) !Snapshot {
        var result = Snapshot{
            .accounts = std.AutoHashMap(Address, AccountState).init(self.allocator),
            .transient_storage = std.AutoHashMap(StorageKey, u256).init(self.allocator),
            .logs_len = self.logs.items.len,
        };
        errdefer result.deinit(self.allocator);

        var account_it = self.accounts.iterator();
        while (account_it.next()) |entry| {
            var account = try entry.value_ptr.clone(self.allocator);
            errdefer account.deinit(self.allocator);
            try result.accounts.put(entry.key_ptr.*, account);
        }

        var transient_it = self.transient_storage.iterator();
        while (transient_it.next()) |entry| {
            try result.transient_storage.put(entry.key_ptr.*, entry.value_ptr.*);
        }

        return result;
    }

    fn restore(self: *Self, snapshot_state: *Snapshot) !void {
        self.clearAccounts();
        self.transient_storage.clearRetainingCapacity();
        self.logs.items.len = snapshot_state.logs_len;

        var account_it = snapshot_state.accounts.iterator();
        while (account_it.next()) |entry| {
            var account = try entry.value_ptr.clone(self.allocator);
            errdefer account.deinit(self.allocator);
            try self.accounts.put(entry.key_ptr.*, account);
        }

        var transient_it = snapshot_state.transient_storage.iterator();
        while (transient_it.next()) |entry| {
            try self.transient_storage.put(entry.key_ptr.*, entry.value_ptr.*);
        }
    }

    fn clearAccounts(self: *Self) void {
        var account_it = self.accounts.valueIterator();
        while (account_it.next()) |account| {
            account.deinit(self.allocator);
        }
        self.accounts.clearRetainingCapacity();
    }

    fn getCode(self: *Self, address: Address) []const u8 {
        const account = self.accounts.getPtr(address) orelse return &.{};
        return account.code;
    }

    fn accountExists(ptr: *anyopaque, address: Address) !bool {
        const self: *Self = @ptrCast(@alignCast(ptr));
        return self.accounts.contains(address);
    }

    fn getBalance(ptr: *anyopaque, address: Address) !u256 {
        const self: *Self = @ptrCast(@alignCast(ptr));
        const account = self.accounts.getPtr(address) orelse return 0;
        return account.balance;
    }

    fn getStorage(ptr: *anyopaque, address: Address, key: u256) ?u256 {
        const self: *Self = @ptrCast(@alignCast(ptr));
        const account = self.accounts.getPtr(address) orelse return null;
        return account.getStorage(key);
    }

    fn setStorage(ptr: *anyopaque, address: Address, key: u256, value: u256) !Host.StorageStatus {
        const self: *Self = @ptrCast(@alignCast(ptr));
        var account = try self.getOrCreateAccount(address);
        const previous = account.getStorage(key);
        if (value == 0) {
            _ = account.storage.remove(key);
        } else {
            try account.storage.put(key, value);
        }
        return storageStatus(previous, value);
    }

    fn getCodeSize(ptr: *anyopaque, address: Address) !u256 {
        const self: *Self = @ptrCast(@alignCast(ptr));
        return self.getCode(address).len;
    }

    fn getCodeHash(ptr: *anyopaque, address: Address) !u256 {
        const self: *Self = @ptrCast(@alignCast(ptr));
        const account = self.accounts.getPtr(address) orelse return 0;
        if (account.code.len == 0) return evmz.empty_code_hash;
        var result: [32]u8 = undefined;
        std.crypto.hash.sha3.Keccak256.hash(account.code, &result, .{});
        return std.mem.readInt(u256, &result, .big);
    }

    fn copyCode(ptr: *anyopaque, address: Address, code_offset: usize, buffer_data: []u8) !usize {
        const self: *Self = @ptrCast(@alignCast(ptr));
        const code = self.getCode(address);
        if (code_offset >= code.len) return 0;
        const size = @min(buffer_data.len, code.len - code_offset);
        @memcpy(buffer_data[0..size], code[code_offset .. code_offset + size]);
        return size;
    }

    fn emitLog(ptr: *anyopaque, address: Address, topics: []const u256, data: []const u8) !void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        try self.logs.append(self.allocator, .{
            .address = address,
            .topics = topics,
            .data = data,
        });
    }

    fn getBlockHash(ptr: *anyopaque, number: u256) !u256 {
        _ = ptr;
        _ = number;
        return 0;
    }

    fn getTxContext(ptr: *anyopaque) !Host.TxContext {
        const self: *Self = @ptrCast(@alignCast(ptr));
        return self.tx_context;
    }

    fn accessAccount(ptr: *anyopaque, address: Address) !Host.AccessStatus {
        const self: *Self = @ptrCast(@alignCast(ptr));
        if (self.warm_accounts.contains(address)) return .warm;
        try self.warm_accounts.put(address, {});
        return .cold;
    }

    fn accessStorage(ptr: *anyopaque, address: Address, key: u256) !Host.AccessStatus {
        const self: *Self = @ptrCast(@alignCast(ptr));
        const storage_key = StorageKey{ .address = address, .key = key };
        if (self.warm_storage.contains(storage_key)) return .warm;
        try self.warm_storage.put(storage_key, {});
        return .cold;
    }

    fn call(ptr: *anyopaque, msg: Host.Message) !Host.Result {
        const self: *Self = @ptrCast(@alignCast(ptr));
        self.allocator.free(self.last_call_output);
        self.last_call_output = &.{};

        if (msg.kind == .create or msg.kind == .create2) {
            return .{
                .status = .invalid,
                .output_data = &.{},
                .gas_left = 0,
                .gas_refund = 0,
                .create_address = evmz.addr(0),
            };
        }

        var host_iface = self.host();
        const code = self.getCode(msg.code_address);
        var interpreter = Interpreter.init(self.allocator, &host_iface, &msg, code, self.spec);
        defer interpreter.deinit();
        const result = interpreter.execute();

        self.last_call_output = try self.allocator.dupe(u8, result.output_data);
        return .{
            .status = result.status,
            .output_data = self.last_call_output,
            .gas_left = result.gas_left,
            .gas_refund = result.gas_refund,
            .create_address = evmz.addr(0),
        };
    }

    fn selfDestruct(ptr: *anyopaque, address: Address, beneficiary: Address) !bool {
        const self: *Self = @ptrCast(@alignCast(ptr));
        const balance = try getBalance(ptr, address);
        const beneficiary_account = try self.getOrCreateAccount(beneficiary);
        beneficiary_account.balance += balance;
        if (self.accounts.fetchRemove(address)) |removed| {
            var account = removed.value;
            account.deinit(self.allocator);
        }
        return false;
    }

    fn getTransientStorage(ptr: *anyopaque, address: Address, key: u256) ?u256 {
        const self: *Self = @ptrCast(@alignCast(ptr));
        return self.transient_storage.get(.{ .address = address, .key = key });
    }

    fn setTransientStorage(ptr: *anyopaque, address: Address, key: u256, value: u256) !void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        const storage_key = StorageKey{ .address = address, .key = key };
        if (value == 0) {
            _ = self.transient_storage.remove(storage_key);
        } else {
            try self.transient_storage.put(storage_key, value);
        }
    }

    fn getOrCreateAccount(self: *Self, address: Address) !*AccountState {
        if (!self.accounts.contains(address)) {
            try self.accounts.put(address, AccountState.init(self.allocator));
        }
        return self.accounts.getPtr(address).?;
    }

    const Snapshot = struct {
        accounts: std.AutoHashMap(Address, AccountState),
        transient_storage: std.AutoHashMap(StorageKey, u256),
        logs_len: usize,

        fn deinit(self: *Snapshot, allocator: std.mem.Allocator) void {
            var account_it = self.accounts.valueIterator();
            while (account_it.next()) |account| {
                account.deinit(allocator);
            }
            self.accounts.deinit();
            self.transient_storage.deinit();
        }
    };
};

const AccountState = struct {
    balance: u256 = 0,
    code: []u8 = &.{},
    storage: std.AutoHashMap(u256, u256),

    fn init(allocator: std.mem.Allocator) AccountState {
        return .{
            .storage = std.AutoHashMap(u256, u256).init(allocator),
        };
    }

    fn fromJson(allocator: std.mem.Allocator, account: *const std.json.ObjectMap) !AccountState {
        var self = AccountState.init(allocator);
        errdefer self.deinit(allocator);

        self.balance = if (account.get("balance")) |value| try parseU256FromValue(value) else 0;
        if (account.get("code")) |value| {
            self.code = try parseBytesFromValue(allocator, value);
        }

        if (account.get("storage")) |storage_value| {
            var storage = asObject(storage_value) orelse return error.MalformedFixture;
            var it = storage.iterator();
            while (it.next()) |entry| {
                const key = try parseHexInt(u256, entry.key_ptr.*);
                const value = try parseU256FromValue(entry.value_ptr.*);
                if (value != 0) {
                    try self.storage.put(key, value);
                }
            }
        }

        return self;
    }

    fn deinit(self: *AccountState, allocator: std.mem.Allocator) void {
        allocator.free(self.code);
        self.storage.deinit();
    }

    fn clone(self: *const AccountState, allocator: std.mem.Allocator) !AccountState {
        var result = AccountState.init(allocator);
        errdefer result.deinit(allocator);

        result.balance = self.balance;
        result.code = try allocator.dupe(u8, self.code);

        var storage = self.storage;
        var storage_it = storage.iterator();
        while (storage_it.next()) |entry| {
            try result.storage.put(entry.key_ptr.*, entry.value_ptr.*);
        }

        return result;
    }

    fn getStorage(self: *AccountState, key: u256) u256 {
        return self.storage.get(key) orelse 0;
    }
};

const StorageKey = struct {
    address: Address,
    key: u256,
};

fn storageStatus(previous: ?u256, next: u256) Host.StorageStatus {
    const prev = previous orelse 0;
    if (prev == next) return .assigned;
    if (prev == 0 and next != 0) return .added;
    if (prev != 0 and next == 0) return .deleted;
    return .modified;
}

fn parseFork(name: []const u8) ?evmz.Spec {
    if (std.ascii.eqlIgnoreCase(name, "Frontier")) return .frontier;
    if (std.ascii.eqlIgnoreCase(name, "Homestead")) return .homestead;
    if (std.ascii.eqlIgnoreCase(name, "EIP150")) return .tangerine_whistle;
    if (std.ascii.eqlIgnoreCase(name, "TangerineWhistle")) return .tangerine_whistle;
    if (std.ascii.eqlIgnoreCase(name, "EIP158")) return .spurious_dragon;
    if (std.ascii.eqlIgnoreCase(name, "SpuriousDragon")) return .spurious_dragon;
    if (std.ascii.eqlIgnoreCase(name, "Byzantium")) return .byzantium;
    if (std.ascii.eqlIgnoreCase(name, "Constantinople")) return .constantinople;
    if (std.ascii.eqlIgnoreCase(name, "Petersburg")) return .petersburg;
    if (std.ascii.eqlIgnoreCase(name, "Istanbul")) return .istanbul;
    if (std.ascii.eqlIgnoreCase(name, "Berlin")) return .berlin;
    if (std.ascii.eqlIgnoreCase(name, "London")) return .london;
    if (std.ascii.eqlIgnoreCase(name, "Paris")) return .merge;
    if (std.ascii.eqlIgnoreCase(name, "Merge")) return .merge;
    if (std.ascii.eqlIgnoreCase(name, "Shanghai")) return .shanghai;
    if (std.ascii.eqlIgnoreCase(name, "Cancun")) return .cancun;
    if (std.ascii.eqlIgnoreCase(name, "Prague")) return .prague;
    return null;
}

fn asObject(value: JsonValue) ?std.json.ObjectMap {
    return switch (value) {
        .object => |object| object,
        else => null,
    };
}

fn asArray(value: JsonValue) ?std.json.Array {
    return switch (value) {
        .array => |array| array,
        else => null,
    };
}

fn jsonString(value: JsonValue) ?[]const u8 {
    return switch (value) {
        .string => |string| string,
        .number_string => |string| string,
        else => null,
    };
}

fn jsonIndex(value: JsonValue) !usize {
    return switch (value) {
        .integer => |int| std.math.cast(usize, int) orelse error.Overflow,
        .number_string => |string| try std.fmt.parseInt(usize, string, 10),
        else => error.MalformedFixture,
    };
}

fn parseAddressFromValue(value: JsonValue) !Address {
    const string = jsonString(value) orelse return error.MalformedFixture;
    return parseAddress(string);
}

fn parseU256FromValue(value: JsonValue) !u256 {
    const string = jsonString(value) orelse return error.MalformedFixture;
    return parseHexInt(u256, string);
}

fn parseU64FromValue(value: JsonValue) !u64 {
    const string = jsonString(value) orelse return error.MalformedFixture;
    return parseHexInt(u64, string);
}

fn parseBytesFromValue(allocator: std.mem.Allocator, value: JsonValue) ![]u8 {
    const string = jsonString(value) orelse return error.MalformedFixture;
    return parseBytes(allocator, string);
}

fn parseHexInt(comptime T: type, string: []const u8) !T {
    const hex = strip0x(string);
    if (hex.len == 0) return 0;
    return std.fmt.parseInt(T, hex, 16);
}

fn parseAddress(string: []const u8) !Address {
    const hex = strip0x(string);
    if (hex.len != 40) return error.InvalidAddress;

    var address: Address = undefined;
    try parseHexInto(hex, &address);
    return address;
}

fn parseBytes(allocator: std.mem.Allocator, string: []const u8) ![]u8 {
    const hex = strip0x(string);
    if (hex.len % 2 != 0) return error.InvalidHex;
    const out = try allocator.alloc(u8, hex.len / 2);
    errdefer allocator.free(out);
    try parseHexInto(hex, out);
    return out;
}

fn parseHexInto(hex: []const u8, out: []u8) !void {
    if (hex.len != out.len * 2) return error.InvalidHex;
    for (out, 0..) |*byte, i| {
        byte.* = (try hexDigit(hex[i * 2]) << 4) | try hexDigit(hex[i * 2 + 1]);
    }
}

fn hexDigit(char: u8) !u8 {
    return switch (char) {
        '0'...'9' => char - '0',
        'a'...'f' => char - 'a' + 10,
        'A'...'F' => char - 'A' + 10,
        else => error.InvalidHex,
    };
}

fn strip0x(string: []const u8) []const u8 {
    if (std.mem.startsWith(u8, string, "0x") or std.mem.startsWith(u8, string, "0X")) {
        return string[2..];
    }
    return string;
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
