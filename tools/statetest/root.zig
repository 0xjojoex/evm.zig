const std = @import("std");
const evmz = @import("evmz");
pub const fixture = @import("fixtures");
const fixture_common = fixture;

const Address = evmz.Address;
const JsonValue = fixture_common.JsonValue;
const transaction = evmz.transaction;

const asArray = fixture_common.asArray;
const asObject = fixture_common.asObject;
const jsonString = fixture_common.jsonString;
const parseAddress = fixture_common.parseAddress;
const parseAddressFromValue = fixture_common.parseAddressFromValue;
const parseBlobHashes = fixture_common.parseBlobHashes;
const parseBytesFromValue = fixture_common.parseBytesFromValue;
const parseTransactionAccessList = fixture_common.parseTransactionAccessList;
const parseTransactionAuthorizationList = fixture_common.parseTransactionAuthorizationList;
const parseU256FromValue = fixture_common.parseU256FromValue;
const parseU64FromValue = fixture_common.parseU64FromValue;
const rejectUnknownKeys = fixture_common.rejectUnknownKeys;
const seedMemoryStore = fixture_common.seedMemoryStore;
const strip0x = fixture_common.strip0x;

/// Parsed vector borrows JSON and allocates into the caller's per-vector arena.
/// Keep both alive until execution and output consumption finish.
pub const Vector = struct {
    tx: evmz.Transaction,
    env: evmz.Env,
    pre: std.json.ObjectMap,
};

pub fn parseVector(
    comptime revision: evmz.eth.Revision,
    allocator: std.mem.Allocator,
    document: *const std.json.ObjectMap,
    post: *const std.json.ObjectMap,
    fork_name: []const u8,
) !Vector {
    const tx = asObject(document.get("transaction") orelse return error.MalformedFixture) orelse return error.MalformedFixture;
    const env = asObject(document.get("env") orelse return error.MalformedFixture) orelse return error.MalformedFixture;
    const pre = asObject(document.get("pre") orelse return error.MalformedFixture) orelse return error.MalformedFixture;
    const indexes = asObject(post.get("indexes") orelse return error.MalformedFixture) orelse return error.MalformedFixture;
    try rejectUnknownKeys(&tx, &.{
        "nonce",
        "chainId",
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
        "slotNumber",
        "currentExcessBlobGas",
        "currentBlobBaseFee",
        "currentChainId",
        "previousHash",
    });
    try rejectUnknownKeys(&indexes, &.{ "data", "gas", "value" });
    const config = try parseFixtureConfig(document, revision, fork_name);

    const data_index = try jsonIndex(indexes.get("data") orelse return error.MalformedFixture);
    const gas_index = try jsonIndex(indexes.get("gas") orelse return error.MalformedFixture);
    const value_index = try jsonIndex(indexes.get("value") orelse return error.MalformedFixture);

    const to_string = jsonString(tx.get("to") orelse return error.MalformedFixture) orelse return error.MalformedFixture;
    const is_create = strip0x(to_string).len == 0;

    const sender_string = jsonString(tx.get("sender") orelse return error.MissingSender) orelse return error.MalformedFixture;

    const sender = try parseAddress(sender_string);
    const input = try selectedBytes(allocator, &tx, "data", data_index);

    const selected_access_list = try selectedAccessList(&tx, data_index);
    const access_list = if (selected_access_list) |list|
        try parseTransactionAccessList(allocator, list)
    else
        fixture_common.ParsedAccessList{};

    const authorization_list = try parseTransactionAuthorizationList(allocator, &tx, .ignore_malformed_list);

    const gas_limit = try selectedU64(&tx, "gasLimit", gas_index);
    const value = try selectedU256(&tx, "value", value_index);
    const blob_hashes = try parseBlobHashes(allocator, &tx);

    const recipient = if (is_create) null else try parseAddress(to_string);
    const vm_env = try parseEnv(revision, &env, config);
    const public_tx = evmz.Transaction{
        .kind = inferTxKind(&tx, selected_access_list != null),
        .sender = sender,
        .chain_id = try optionalU256(&tx, "chainId"),
        .nonce = try optionalU256(&tx, "nonce"),
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

    return .{ .tx = public_tx, .env = vm_env, .pre = pre };
}

fn selectedAccessList(tx: *const std.json.ObjectMap, index: usize) !?std.json.Array {
    const access_lists_value = tx.get("accessLists") orelse return null;
    const access_lists = asArray(access_lists_value) orelse return error.MalformedFixture;
    if (index >= access_lists.items.len) return error.MalformedFixture;
    if (access_lists.items[index] == .null) return null;
    return asArray(access_lists.items[index]) orelse return error.MalformedFixture;
}

const FixtureConfig = fixture_common.FixtureConfig;
const parseFixtureConfig = fixture_common.parseFixtureConfig;

pub fn parseEnv(
    comptime revision: evmz.eth.Revision,
    env: *const std.json.ObjectMap,
    config: FixtureConfig,
) !evmz.Env {
    const base_fee = if (env.get("currentBaseFee")) |v| try parseU256FromValue(v) else 0;
    return .{
        .chain_id = if (env.get("currentChainId")) |v| try parseU256FromValue(v) else config.chain_id,
        .coinbase = if (env.get("currentCoinbase")) |v| try parseAddressFromValue(v) else evmz.addr(0),
        .number = if (env.get("currentNumber")) |v| try parseU64FromValue(v) else 0,
        .slot_number = if (env.get("slotNumber")) |v| try parseU64FromValue(v) else 0,
        .timestamp = if (env.get("currentTimestamp")) |v| try parseU64FromValue(v) else 0,
        .gas_limit = if (env.get("currentGasLimit")) |v| try parseU64FromValue(v) else 0,
        .prev_randao = if (env.get("currentRandom")) |v| try parseU256FromValue(v) else if (env.get("currentDifficulty")) |v| try parseU256FromValue(v) else 0,
        .base_fee = base_fee,
        .blob_base_fee = try parseBlobBaseFee(revision, env, config),
        .blob_params = config.blob_params,
    };
}

fn parseBlobBaseFee(
    comptime revision: evmz.eth.Revision,
    env: *const std.json.ObjectMap,
    config: FixtureConfig,
) !u256 {
    if (env.get("currentBlobBaseFee")) |value| return parseU256FromValue(value);
    const excess_blob_gas = if (env.get("currentExcessBlobGas")) |value| try parseU256FromValue(value) else 0;
    return fixture_common.blobBaseFee(revision, config.blob_params, excess_blob_gas) orelse error.Overflow;
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

fn inferTxKind(tx: *const std.json.ObjectMap, has_access_list: bool) transaction.TxKind {
    if (tx.get("authorizationList") != null) return .set_code;
    if (tx.get("blobVersionedHashes") != null or tx.get("maxFeePerBlobGas") != null) return .blob;
    if (tx.get("maxFeePerGas") != null or tx.get("maxPriorityFeePerGas") != null) return .dynamic_fee;
    if (has_access_list) return .access_list;
    return .legacy;
}

fn jsonIndex(value: JsonValue) !usize {
    return switch (value) {
        .integer => |int| std.math.cast(usize, int) orelse error.Overflow,
        .number_string => |string| try std.fmt.parseInt(usize, string, 10),
        else => error.MalformedFixture,
    };
}

pub fn Host(comptime revision: evmz.eth.Revision, comptime trace: bool) type {
    const ExactVm = evmz.VmWithOptions(evmz.eth.specAt(revision), .{ .step_capture = trace });
    const TxResult = transaction.TransactOutcomeType(evmz.TxExecutionResult, ExactVm.Rejection);

    return struct {
        allocator: std.mem.Allocator,
        store: *evmz.state.MemoryStore,
        executor: ExactVm.Executor,
        env: evmz.Env,

        const Self = @This();

        pub fn init(
            allocator: std.mem.Allocator,
            pre: *const std.json.ObjectMap,
            env: evmz.Env,
        ) !Self {
            const store = try allocator.create(evmz.state.MemoryStore);
            errdefer allocator.destroy(store);
            store.* = evmz.state.MemoryStore.init(allocator);
            errdefer store.deinit();

            try seedMemoryStore(allocator, store, pre);

            var executor = ExactVm.Executor.init(allocator, .{
                .state = .{ .reader = store.reader() },
                .block_hash_source = BlockHashSource.source(),
            });
            errdefer executor.deinit();

            return .{
                .allocator = allocator,
                .store = store,
                .executor = executor,
                .env = env,
            };
        }

        pub fn deinit(self: *Self) void {
            self.executor.deinit();
            self.store.deinit();
            self.allocator.destroy(self.store);
        }

        pub fn getAccount(self: *Self, address: Address) !?evmz.AccountView {
            return accountView(&self.executor, address);
        }

        pub fn getStorage(self: *Self, address: Address, key: u256) !u256 {
            return self.executor.getStorage(address, key);
        }

        pub fn transact(self: *Self, tx: evmz.Transaction, out: ?*std.Io.Writer) !TxResult {
            var block = try ExactVm.BlockExecution.init(
                &self.executor,
                self.env,
            );
            defer block.discardIfUnfinished();
            const outcome = if (comptime trace) blk: {
                var tape = evmz.trace.TraceTape.initGrowable(self.allocator);
                defer tape.deinit();
                var capture = evmz.executor.CaptureContext.init(self.allocator, .{
                    .tape = &tape,
                    .profile = evmz.trace.eip3155.capture_profile,
                });
                defer capture.deinit();
                try capture.begin();
                errdefer capture.abort() catch {};
                const outcome = try block.capture(&capture, {}).transact(tx);
                const span = (try capture.finish()).?;
                defer tape.resolve(span) catch unreachable;
                try evmz.trace.eip3155.writeSteps(out.?, span);
                break :blk outcome;
            } else try block.transact(tx);
            return switch (outcome) {
                .included => |included| blk: {
                    _ = block.finish();
                    break :blk .{ .executed = included.result };
                },
                .rejected => |err| .{ .rejected = err },
            };
        }

        pub fn stateRoot(self: *Self, allocator: std.mem.Allocator) ![32]u8 {
            // Same fork boundary the executor reads for account existence, so
            // take it from the same fact rather than restating the revision.
            var delta = try evmz.state.StateDelta.init(allocator, self.executor.acceptedChanges());
            defer delta.deinit();
            return self.store.stateRootAfterChangesWithOptions(allocator, delta.view(), .{
                .empty_accounts = if (ExactVm.spec.retains_empty_accounts) .include else .omit,
            });
        }
    };
}

fn accountView(executor: anytype, address: Address) !?evmz.AccountView {
    const account = try executor.getAccount(address) orelse return null;
    return .{
        .nonce = account.nonce,
        .balance = account.balance,
        .code = try executor.getCode(address),
    };
}

pub const BlockHashSource = struct {
    var anchor: u8 = 0;

    pub fn source() evmz.BlockHashSource {
        return .{ .ptr = &anchor, .vtable = &.{
            .getBlockHash = getBlockHash,
        } };
    }

    pub fn getBlockHash(_: *anyopaque, number: u64) !?u256 {
        var decimal: [20]u8 = undefined;
        const input = try std.fmt.bufPrint(&decimal, "{d}", .{number});
        var hash: [32]u8 = undefined;
        std.crypto.hash.sha3.Keccak256.hash(input, &hash, .{});
        return evmz.uint256.fromBytes32(&hash);
    }
};
