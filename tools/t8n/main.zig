//! execution-specs transition-tool adapter for evmz.

const std = @import("std");
const evmz = @import("evmz");
const callframes = @import("callframes.zig");

const Allocator = std.mem.Allocator;
const Revision = evmz.eth.Revision;
const TxKind = evmz.transaction.TxKind;
const Writer = evmz.rlp.Writer;
const block_stf = evmz.eth.block_stf;
const system_contracts = evmz.executor.system_contracts;
const eql = std.mem.eql;

/// Forks the tool accepts. `--state.fork` matches these tags; Paris is `merge`.
const forks = [_]Revision{ .merge, .shanghai, .cancun, .prague, .osaka, .amsterdam };

const Options = struct {
    input_alloc: []const u8 = "alloc.json",
    input_env: []const u8 = "env.json",
    input_txs: []const u8 = "txs.json",
    output_alloc: []const u8 = "alloc.json",
    output_result: []const u8 = "result.json",
    output_body: ?[]const u8 = null,
    output_basedir: []const u8 = ".",
    fork: Revision = .merge,
    chain_id: u256 = 1,
    reward: i256 = 0,
    state_test: bool = false,
    trace_callframes: bool = false,
};

const Inputs = struct {
    alloc: []const u8,
    env: []const u8,
    txs: []const u8,
};

pub fn main(init: std.process.Init) void {
    run(init) catch |err| {
        const code = exitCode(err);
        std.debug.print("ERROR({d}): {s}\n", .{ code, @errorName(err) });
        std.process.exit(code);
    };
}

fn run(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const options = try parseOptions(init, arena) orelse return;
    const inputs: Inputs = .{
        .alloc = try readInput(arena, init.io, options.input_alloc),
        .env = try readInput(arena, init.io, options.input_env),
        .txs = try readInput(arena, init.io, options.input_txs),
    };
    try writeOutputs(arena, init.io, options, try transition(arena, options, inputs));
}

/// Returns null after serving `--help` or `--version`.
fn parseOptions(init: std.process.Init, allocator: Allocator) !?Options {
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, allocator);
    _ = args.next();

    var options: Options = .{};
    while (args.next()) |arg| {
        if (eql(u8, arg, "--help") or eql(u8, arg, "-h")) {
            try printUsage(init.io);
            return null;
        }
        if (eql(u8, arg, "--version")) {
            try printVersion(init.io);
            return null;
        }
        if (eql(u8, arg, "--trace.callframes")) {
            options.trace_callframes = true;
            continue;
        }
        if (eql(u8, arg, "--state-test")) {
            options.state_test = true;
            continue;
        }

        const split = std.mem.indexOfScalar(u8, arg, '=') orelse arg.len;
        const name = arg[0..split];
        const value: []const u8 = if (split < arg.len) arg[split + 1 ..] else args.next() orelse "";
        if (value.len == 0) return error.InvalidConfiguration;
        if (eql(u8, name, "--input.alloc")) {
            options.input_alloc = value;
        } else if (eql(u8, name, "--input.env")) {
            options.input_env = value;
        } else if (eql(u8, name, "--input.txs")) {
            options.input_txs = value;
        } else if (eql(u8, name, "--output.alloc")) {
            options.output_alloc = value;
        } else if (eql(u8, name, "--output.result")) {
            options.output_result = value;
        } else if (eql(u8, name, "--output.body")) {
            options.output_body = value;
        } else if (eql(u8, name, "--output.basedir")) {
            options.output_basedir = value;
        } else if (eql(u8, name, "--state.fork")) {
            options.fork = parseFork(value) orelse return error.InvalidConfiguration;
        } else if (eql(u8, name, "--state.chainid")) {
            options.chain_id = std.fmt.parseInt(u256, value, 0) catch
                return error.InvalidConfiguration;
            if (options.chain_id == 0) return error.InvalidConfiguration;
        } else if (eql(u8, name, "--state.reward")) {
            options.reward = std.fmt.parseInt(i256, value, 0) catch
                return error.InvalidConfiguration;
            if (options.reward != -1 and options.reward != 0) return error.InvalidConfiguration;
        } else {
            return error.InvalidConfiguration;
        }
    }

    for ([_][]const u8{ options.input_alloc, options.input_env, options.input_txs }) |path| {
        if (eql(u8, path, "stdin")) return error.InvalidConfiguration;
    }

    for ([_][]const u8{
        options.output_alloc,
        options.output_result,
        options.output_body orelse "",
    }) |path| {
        if (eql(u8, path, "stderr")) return error.InvalidConfiguration;
    }

    return options;
}

fn parseFork(name: []const u8) ?Revision {
    if (std.ascii.eqlIgnoreCase(name, "Paris")) return .merge;
    for (forks) |fork| {
        if (std.ascii.eqlIgnoreCase(name, @tagName(fork))) return fork;
    }
    return null;
}

fn transition(allocator: Allocator, options: Options, inputs: Inputs) !Documents {
    const alloc = try parseJson(AllocInput, allocator, inputs.alloc);
    const env = try parseJson(EnvInput, allocator, inputs.env);
    const txs = try parseJson([]const TransactionInput, allocator, inputs.txs);

    var store = evmz.state.MemoryStore.init(allocator);
    seedState(allocator, &store, alloc) catch |err| return classify(err, error.InvalidInput);
    const candidates = parseTransactions(allocator, txs, options.chain_id) catch |err|
        return classify(err, error.InvalidInput);
    inline for (forks) |fork| {
        if (fork == options.fork) return executeFork(fork, allocator, options, &store, env, candidates);
    }
    unreachable;
}

/// `env.json` as EEST and geth emit it; the trailing group is accepted and unused.
const EnvInput = struct {
    currentCoinbase: AddressHex,
    currentGasLimit: Quantity,
    currentNumber: Quantity,
    currentTimestamp: Quantity,
    currentRandom: Quantity,
    currentBaseFee: ?Quantity = null,
    currentExcessBlobGas: ?Quantity = null,
    currentBlobGasUsed: ?Quantity = null,
    slotNumber: ?Quantity = null,
    parentBaseFee: ?Quantity = null,
    parentGasUsed: ?Quantity = null,
    parentGasLimit: ?Quantity = null,
    parentExcessBlobGas: ?Quantity = null,
    parentBlobGasUsed: ?Quantity = null,
    parentBeaconBlockRoot: ?Hash = null,
    blockHashes: std.json.ArrayHashMap(Hash) = .{},
    ommers: []const Hash = &.{},
    withdrawals: ?[]const WithdrawalInput = null,
    currentDifficulty: ?Quantity = null,
    parentDifficulty: ?Quantity = null,
    parentTimestamp: ?Quantity = null,
    parentSlotNumber: ?Quantity = null,
    parentUncleHash: ?Hash = null,
    parentHash: ?Hash = null,
    previousHash: ?Hash = null,
    blockAccessListHash: ?Hash = null,
    blockAccessLists: ?Hex = null,
};

const WithdrawalInput = struct {
    index: Quantity,
    validatorIndex: Quantity,
    address: AddressHex,
    amount: Quantity,
};

const AllocInput = std.json.ArrayHashMap(AccountInput);

const AccountInput = struct {
    balance: Quantity = .zero,
    nonce: Quantity = .zero,
    /// Mutable because `MemoryAccount.adoptCode` takes ownership.
    code: ?HexOf([]u8) = null,
    storage: std.json.ArrayHashMap(Quantity) = .{},
    secretKey: ?Hash = null,
};

/// When `type` is absent, the fee and list fields present select the kind.
const TransactionInput = struct {
    type: ?Quantity = null,
    chainId: ?Quantity = null,
    nonce: Quantity = .zero,
    gasPrice: ?Quantity = null,
    maxPriorityFeePerGas: ?Quantity = null,
    maxFeePerGas: ?Quantity = null,
    gas: Quantity = .{ .value = 21_000 },
    to: ?Recipient = null,
    value: Quantity = .zero,
    input: ?Hex = null,
    data: ?Hex = null,
    accessList: ?[]const AccessListInput = null,
    maxFeePerBlobGas: ?Quantity = null,
    blobVersionedHashes: ?[]const Hash = null,
    authorizationList: ?[]const AuthorizationInput = null,
    v: Quantity = .zero,
    r: Quantity = .zero,
    s: Quantity = .zero,
    sender: ?AddressHex = null,
    secretKey: ?Hash = null,
    rlpOverride: ?Hex = null,
};

const AccessListInput = struct {
    address: AddressHex,
    storageKeys: []const Hash,
};

const AuthorizationInput = struct {
    chainId: Quantity = .zero,
    address: AddressHex,
    nonce: Quantity = .zero,
    v: ?Quantity = null,
    yParity: ?Quantity = null,
    r: ?Quantity = null,
    s: ?Quantity = null,
    signer: ?AddressHex = null,
    secretKey: ?Hash = null,
};

/// Transaction `to`; `""` and `null` both mean contract creation.
const Recipient = struct {
    address: ?evmz.Address,

    pub fn jsonParse(allocator: Allocator, source: anytype, options: std.json.ParseOptions) !Recipient {
        const text = try textToken(allocator, source, options);
        if (text.len == 0) return .{ .address = null };
        return .{ .address = evmz.Address.fromHex(text) catch return error.InvalidCharacter };
    }
};

const BlockHashes = struct {
    current_number: u64,
    values: std.AutoHashMap(u64, u256),
    parent_hash: ?[32]u8 = null,

    fn source(self: *BlockHashes) evmz.BlockHashSource {
        return .{ .ptr = self, .vtable = &.{ .getBlockHash = getBlockHash } };
    }

    fn getBlockHash(ptr: *anyopaque, number: u64) !?u256 {
        const self: *BlockHashes = @ptrCast(@alignCast(ptr));
        if (number >= self.current_number or self.current_number - number > 256) return null;
        return self.values.get(number) orelse error.MissingBlockHash;
    }
};

const Environment = struct {
    env: evmz.Env,
    block_hashes: BlockHashes,
    withdrawals: []const evmz.eth.Withdrawal,
    parent_beacon_block_root: ?[32]u8,
    excess_blob_gas: ?u256,
};

fn parseEnvironment(
    comptime revision: Revision,
    allocator: Allocator,
    input: EnvInput,
    chain_id: u256,
) !Environment {
    const number = try input.currentNumber.narrow(u64);
    const base_fee = if (input.currentBaseFee) |fee|
        fee.value
    else
        evmz.eth.block_rules.nextBaseFee(
            try (input.parentGasLimit orelse return error.InvalidInput).narrow(u64),
            try (input.parentGasUsed orelse return error.InvalidInput).narrow(u64),
            (input.parentBaseFee orelse return error.InvalidInput).value,
        ) orelse return error.InvalidInput;
    if (input.ommers.len != 0) return error.InvalidConfiguration;
    const withdrawals = input.withdrawals orelse &.{};
    if (!revision.isImpl(.shanghai) and withdrawals.len != 0) return error.InvalidConfiguration;

    var excess_blob_gas: ?u256 = null;
    var blob_base_fee: u256 = 0;
    if (revision.isImpl(.cancun)) {
        const schedule = evmz.eth.specAt(revision).transaction.blob_schedule orelse
            return error.InvalidConfiguration;
        excess_blob_gas = if (input.currentExcessBlobGas) |excess|
            excess.value
        else
            schedule.calcExcessBlobGasForSchedule(.{
                .parent_excess_blob_gas = if (input.parentExcessBlobGas) |v| v.value else 0,
                .parent_blob_gas_used = if (input.parentBlobGasUsed) |v| v.value else 0,
                .parent_base_fee_per_gas = if (input.parentBaseFee) |v| v.value else 0,
            }) orelse return error.InvalidInput;
        blob_base_fee = schedule.blobBaseFeeForSchedule(excess_blob_gas.?) orelse
            return error.InvalidInput;
    } else if (input.parentBeaconBlockRoot != null or input.currentExcessBlobGas != null or
        input.currentBlobGasUsed != null or input.parentExcessBlobGas != null or
        input.parentBlobGasUsed != null)
    {
        return error.InvalidConfiguration;
    }

    return .{
        .env = .{
            .chain_id = chain_id,
            .coinbase = .fromBytes(input.currentCoinbase.bytes),
            .number = number,
            .slot_number = if (input.slotNumber) |slot| try slot.narrow(u64) else 0,
            .timestamp = try input.currentTimestamp.narrow(u64),
            .gas_limit = try input.currentGasLimit.narrow(u64),
            .prev_randao = input.currentRandom.value,
            .base_fee = base_fee,
            .blob_base_fee = blob_base_fee,
        },
        .block_hashes = try parseBlockHashes(allocator, input.blockHashes, number),
        .withdrawals = try parseWithdrawals(allocator, withdrawals),
        .parent_beacon_block_root = if (input.parentBeaconBlockRoot) |root| root.bytes else null,
        .excess_blob_gas = excess_blob_gas,
    };
}

fn parseBlockHashes(
    allocator: Allocator,
    input: std.json.ArrayHashMap(Hash),
    current_number: u64,
) !BlockHashes {
    var result: BlockHashes = .{ .current_number = current_number, .values = .init(allocator) };
    var iterator = input.map.iterator();
    while (iterator.next()) |entry| {
        const number = std.math.cast(u64, try parseQuantityText(entry.key_ptr.*)) orelse
            return error.InvalidInput;
        const hash = entry.value_ptr.bytes;
        try result.values.put(number, std.mem.readInt(u256, &hash, .big));
        if (number < current_number and number + 1 == current_number) result.parent_hash = hash;
    }
    return result;
}

fn parseWithdrawals(
    allocator: Allocator,
    input: []const WithdrawalInput,
) ![]const evmz.eth.Withdrawal {
    const withdrawals = try allocator.alloc(evmz.eth.Withdrawal, input.len);
    for (input, withdrawals) |item, *withdrawal| withdrawal.* = .{
        .index = try item.index.narrow(u64),
        .validator_index = try item.validatorIndex.narrow(u64),
        .address = .fromBytes(item.address.bytes),
        .amount = try item.amount.narrow(u64),
    };
    return withdrawals;
}

// -- State --------------------------------------------------------------------

fn seedState(allocator: Allocator, store: *evmz.state.MemoryStore, alloc: AllocInput) !void {
    var iterator = alloc.map.iterator();
    while (iterator.next()) |entry| {
        const address = try evmz.Address.fromHex(entry.key_ptr.*);
        const input = entry.value_ptr.*;
        var account = evmz.state.MemoryAccount.init(allocator);
        account.account.balance = input.balance.value;
        account.account.nonce = try input.nonce.narrow(u64);
        if (input.code) |code| account.adoptCode(code.bytes);
        var slots = input.storage.map.iterator();
        while (slots.next()) |slot| {
            const stored = slot.value_ptr.value;
            if (stored != 0) try account.storage.put(try parseQuantityText(slot.key_ptr.*), stored);
        }
        try store.putAccount(address, &account);
    }
}

fn allocDocument(allocator: Allocator, store: *evmz.state.MemoryStore) !Alloc {
    var alloc: Alloc = .{};
    var accounts = store.accounts.iterator();
    while (accounts.next()) |entry| {
        const account = entry.value_ptr;
        var storage: std.json.ArrayHashMap(Hash) = .{};
        var slots = account.storage.iterator();
        while (slots.next()) |slot| {
            if (slot.value_ptr.* == 0) continue;
            try storage.map.put(
                allocator,
                try hexAlloc(allocator, &evmz.uint256.toBytes32(slot.key_ptr.*)),
                .{ .bytes = evmz.uint256.toBytes32(slot.value_ptr.*) },
            );
        }
        try alloc.map.put(allocator, try hexAlloc(allocator, entry.key_ptr.asBytes()), .{
            .balance = quantity(account.account.balance),
            .nonce = if (account.account.nonce != 0) quantity(account.account.nonce) else null,
            .code = if (account.code.len != 0) Hex{ .bytes = account.code } else null,
            .storage = if (storage.map.count() != 0) storage else null,
        });
    }
    return alloc;
}

// -- Transactions -------------------------------------------------------------

const Signature = struct {
    y_parity: u8,
    r: u256,
    s: u256,
};

const EncodedTransaction = struct {
    value: evmz.transaction.Transaction,
    bytes: []const u8,
};

const Candidate = union(enum) {
    ready: EncodedTransaction,
    rejected: []const u8,
};

fn parseTransactions(
    allocator: Allocator,
    input: []const TransactionInput,
    default_chain_id: u256,
) ![]Candidate {
    const candidates = try allocator.alloc(Candidate, input.len);
    for (input, candidates) |tx, *candidate| {
        const bytes = encodeTransaction(allocator, tx, default_chain_id) catch |err| switch (err) {
            error.UnsupportedTransactionType => {
                candidate.* = .{ .rejected = "TransactionException.TYPE_NOT_SUPPORTED" };
                continue;
            },
            else => return err,
        };
        candidate.* = if (evmz.transaction.raw.decodeRaw(allocator, bytes)) |decoded|
            .{ .ready = .{ .value = decoded.tx, .bytes = bytes } }
        else |err|
            .{ .rejected = rawTransactionError(err) };
    }
    return candidates;
}

fn encodeTransaction(allocator: Allocator, tx: TransactionInput, default_chain_id: u256) ![]const u8 {
    const kind = try transactionKind(tx);
    const forbidden = switch (kind) {
        .legacy => tx.accessList != null or tx.maxFeePerGas != null or tx.maxPriorityFeePerGas != null,
        .access_list => tx.maxFeePerGas != null or tx.maxPriorityFeePerGas != null,
        .dynamic_fee => tx.gasPrice != null,
        .blob => tx.gasPrice != null or tx.authorizationList != null,
        .set_code => tx.gasPrice != null or tx.maxFeePerBlobGas != null or tx.blobVersionedHashes != null,
    };
    if (forbidden) return error.InvalidInput;

    const chain_id = if (tx.chainId) |v| v.value else default_chain_id;
    var payload = Writer.alloc(allocator);
    if (kind != .legacy) try payload.int(u256, chain_id);
    try payload.int(u256, tx.nonce.value);
    switch (kind) {
        .legacy, .access_list => try payload.int(u256, if (tx.gasPrice) |v| v.value else 10),
        else => {
            try payload.int(u256, if (tx.maxPriorityFeePerGas) |v| v.value else 0);
            try payload.int(u256, if (tx.maxFeePerGas) |v| v.value else 7);
        },
    }
    try payload.int(u64, try tx.gas.narrow(u64));
    const to = if (tx.to) |recipient| recipient.address else null;
    try payload.bytes(if (to) |address| address.asBytes() else &.{});
    try payload.int(u256, tx.value.value);
    try payload.bytes(try transactionInput(tx));
    if (kind != .legacy) try writeAccessList(&payload, tx.accessList orelse &.{});
    if (kind == .blob) {
        try payload.int(u256, if (tx.maxFeePerBlobGas) |v| v.value else 1);
        try writeHashList(&payload, tx.blobVersionedHashes orelse return error.InvalidInput);
    }
    if (kind == .set_code) {
        const authorizations = tx.authorizationList orelse return error.InvalidInput;
        try writeAuthorizationList(allocator, &payload, authorizations);
    }

    var v = tx.v.value;
    var signature = Signature{ .y_parity = 0, .r = tx.r.value, .s = tx.s.value };
    if (tx.secretKey) |secret_key| {
        if (v == 0 and signature.r == 0 and signature.s == 0) {
            signature = try signTransaction(allocator, kind, chain_id, payload.written(), secret_key.bytes);
            v = if (kind == .legacy)
                try protectedLegacyV(chain_id, signature.y_parity)
            else
                signature.y_parity;
        }
    }
    try payload.int(u256, v);
    try payload.int(u256, signature.r);
    try payload.int(u256, signature.s);
    return envelope(allocator, kind, payload.written());
}

fn transactionKind(tx: TransactionInput) !TxKind {
    const type_id: u8 = if (tx.type) |value|
        try value.narrow(u8)
    else if (tx.authorizationList != null)
        4
    else if (tx.maxFeePerBlobGas != null or tx.blobVersionedHashes != null)
        3
    else if (tx.maxFeePerGas != null or tx.maxPriorityFeePerGas != null)
        2
    else if (tx.accessList != null)
        1
    else
        0;
    return switch (type_id) {
        0 => .legacy,
        1 => .access_list,
        2 => .dynamic_fee,
        3 => .blob,
        4 => .set_code,
        else => error.UnsupportedTransactionType,
    };
}

fn typeId(kind: TxKind) ?u8 {
    return switch (kind) {
        .legacy => null,
        .access_list => 1,
        .dynamic_fee => 2,
        .blob => 3,
        .set_code => 4,
    };
}

fn transactionInput(tx: TransactionInput) ![]const u8 {
    if (tx.input) |input| {
        if (tx.data) |data| if (!eql(u8, input.bytes, data.bytes)) return error.InvalidInput;
        return input.bytes;
    }
    return if (tx.data) |data| data.bytes else &.{};
}

/// RLP list frame around `payload`, behind the EIP-2718 type byte for typed kinds.
fn envelope(allocator: Allocator, kind: TxKind, payload: []const u8) ![]u8 {
    var out = Writer.alloc(allocator);
    if (typeId(kind)) |id| try out.appendSlice(&.{id});
    try out.listPayload(payload);
    return out.toOwnedSlice();
}

/// Frame everything written since `start` as one RLP list.
fn closeList(writer: *Writer, start: usize) !void {
    var prefix: [evmz.rlp.max_length_prefix_bytes]u8 = undefined;
    const header = evmz.rlp.listPrefix(&prefix, writer.written().len - start);
    try writer.allocating.out.insertSlice(writer.allocating.allocator, start, header);
}

fn writeAccessList(writer: *Writer, entries: []const AccessListInput) !void {
    const start = writer.written().len;
    for (entries) |entry| {
        const entry_start = writer.written().len;
        try writer.bytes(&entry.address.bytes);
        const keys_start = writer.written().len;
        for (entry.storageKeys) |key| try writer.bytes(&key.bytes);
        try closeList(writer, keys_start);
        try closeList(writer, entry_start);
    }
    try closeList(writer, start);
}

fn writeHashList(writer: *Writer, hashes: []const Hash) !void {
    const start = writer.written().len;
    for (hashes) |hash| try writer.bytes(&hash.bytes);
    try closeList(writer, start);
}

fn writeAuthorizationList(
    allocator: Allocator,
    writer: *Writer,
    authorizations: []const AuthorizationInput,
) !void {
    const start = writer.written().len;
    for (authorizations) |authorization| {
        const entry_start = writer.written().len;
        try writer.int(u256, authorization.chainId.value);
        try writer.bytes(&authorization.address.bytes);
        try writer.int(u64, try authorization.nonce.narrow(u64));
        const signature = if (authorization.secretKey) |secret_key| blk: {
            // EIP-7702 signs the magic byte followed by the unsigned tuple as a list.
            var message = Writer.alloc(allocator);
            try message.appendSlice(&.{evmz.transaction.signing.set_code_authorization_magic});
            try message.listPayload(writer.written()[entry_start..]);
            break :blk try signHash(secret_key.bytes, evmz.crypto.keccak256(message.written()));
        } else try authorizationSignature(authorization);
        try writer.int(u8, signature.y_parity);
        try writer.int(u256, signature.r);
        try writer.int(u256, signature.s);
        try closeList(writer, entry_start);
    }
    try closeList(writer, start);
}

fn authorizationSignature(authorization: AuthorizationInput) !Signature {
    const y_parity = authorization.yParity;
    const v = authorization.v;
    if (y_parity != null and v != null and y_parity.?.value != v.?.value) return error.InvalidInput;
    return .{
        .y_parity = try (y_parity orelse (v orelse return error.InvalidInput)).narrow(u8),
        .r = (authorization.r orelse return error.InvalidInput).value,
        .s = (authorization.s orelse return error.InvalidInput).value,
    };
}

fn signTransaction(
    allocator: Allocator,
    kind: TxKind,
    chain_id: u256,
    unsigned: []const u8,
    secret_key: [32]u8,
) !Signature {
    var payload = Writer.alloc(allocator);
    try payload.appendSlice(unsigned);
    if (kind == .legacy) {
        try payload.int(u256, chain_id);
        try payload.int(u8, 0);
        try payload.int(u8, 0);
    }
    const message = try envelope(allocator, kind, payload.written());
    return signHash(secret_key, evmz.crypto.keccak256(message));
}

fn protectedLegacyV(chain_id: u256, y_parity: u8) !u256 {
    const doubled = std.math.mul(u256, chain_id, 2) catch return error.InvalidInput;
    return std.math.add(u256, doubled, 35 + @as(u256, y_parity)) catch error.InvalidInput;
}

fn signHash(secret_key: [32]u8, message_hash: [32]u8) !Signature {
    const Curve = std.crypto.ecc.Secp256k1;
    const Scalar = Curve.scalar.Scalar;
    const secret = Scalar.fromBytes(secret_key, .big) catch return error.InvalidInput;
    if (secret.isZero()) return error.InvalidInput;
    const nonce = deterministicNonce(secret_key, message_hash);
    const point = (Curve.basePoint.mul(nonce.toBytes(.big), .big) catch
        return error.InvalidInput).affineCoordinates();
    var expanded_x = [_]u8{0} ** 48;
    @memcpy(expanded_x[16..], &point.x.toBytes(.big));
    const r = Scalar.fromBytes48(expanded_x, .big);
    var expanded_hash = [_]u8{0} ** 64;
    @memcpy(expanded_hash[32..], &message_hash);
    const z = Scalar.fromBytes64(expanded_hash, .big);
    const s = nonce.invert().mul(z.add(r.mul(secret)));
    if (r.isZero() or s.isZero()) return error.InvalidInput;

    var signature = Signature{
        .y_parity = @intFromBool(point.y.isOdd()),
        .r = std.mem.readInt(u256, &r.toBytes(.big), .big),
        .s = std.mem.readInt(u256, &s.toBytes(.big), .big),
    };
    // Canonical low-s negates the nonce point, which flips its y parity.
    if (signature.s > evmz.eip7702.secp256k1_half_n) {
        signature.s = evmz.eip7702.secp256k1n - signature.s;
        signature.y_parity ^= 1;
    }
    return signature;
}

/// RFC 6979 nonce over HMAC-SHA256, matching the reference signers byte for byte.
fn deterministicNonce(
    secret_key: [32]u8,
    message_hash: [32]u8,
) std.crypto.ecc.Secp256k1.scalar.Scalar {
    const Hmac = std.crypto.auth.hmac.sha2.HmacSha256;
    const Scalar = std.crypto.ecc.Secp256k1.scalar.Scalar;
    var key = [_]u8{0} ** 32;
    var value = [_]u8{1} ** 32;
    var seed: [97]u8 = undefined;
    @memcpy(seed[0..32], &value);
    seed[32] = 0;
    @memcpy(seed[33..65], &secret_key);
    @memcpy(seed[65..97], &message_hash);
    Hmac.create(&key, &seed, &key);
    Hmac.create(&value, &value, &key);
    seed[32] = 1;
    @memcpy(seed[0..32], &value);
    Hmac.create(&key, &seed, &key);
    Hmac.create(&value, &value, &key);

    while (true) {
        Hmac.create(&value, &value, &key);
        if (Scalar.fromBytes(value, .big)) |candidate| {
            if (!candidate.isZero()) return candidate;
        } else |_| {}
        var retry: [33]u8 = undefined;
        @memcpy(retry[0..32], &value);
        retry[32] = 0;
        Hmac.create(&key, &retry, &key);
        Hmac.create(&value, &value, &key);
    }
}

const BalCollector = struct {
    builder: *evmz.eth.bal.projector.BlockBuilder,
    block_access_index: evmz.eth.bal.BlockAccessIndex = 0,

    pub fn observe(self: *BalCollector, observation: anytype) !void {
        try self.builder.append(observation.observations(), self.block_access_index);
    }
};

const Submitted = struct {
    index: usize,
    bytes: []const u8,
};

fn executeFork(
    comptime revision: Revision,
    allocator: Allocator,
    options: Options,
    store: *evmz.state.MemoryStore,
    env_input: EnvInput,
    candidates: []const Candidate,
) !Documents {
    const Engine = evmz.Vm(evmz.eth.specAt(revision));
    const produces_bal = comptime revision.isImpl(.amsterdam);
    const state_test = options.state_test;
    const tracing = options.trace_callframes;
    var environment = try parseEnvironment(revision, allocator, env_input, options.chain_id);
    const env = environment.env;
    const context = block_stf.lifecycleExecutionContext(env);

    var executor = Engine.Executor.init(allocator, .{
        .state = .{ .reader = store.reader() },
        .block_hash_source = environment.block_hashes.source(),
    });
    var block = try Engine.BlockExecution.init(&executor, env);
    defer block.discardIfUnfinished();
    var call_arena = evmz.trace.CallArena.init(allocator);
    var capture = evmz.executor.CaptureContext.initWithCalls(allocator, null, .{ .arena = &call_arena });
    var bal_builder = evmz.eth.bal.projector.BlockBuilder.init(allocator);
    var bal_collector = BalCollector{ .builder = &bal_builder };
    const observer = if (produces_bal) &bal_collector else {};

    if (!state_test) {
        const calls = Engine.spec.block.beforeBlock(.{
            .number = env.number,
            .timestamp = env.timestamp,
            .parent_hash = environment.block_hashes.parent_hash,
            .parent_beacon_block_root = environment.parent_beacon_block_root,
        });
        try applySystemCalls(&executor, context, calls.slice(), observer);
    }

    var body: std.ArrayList([]const u8) = .empty;
    var trie: std.ArrayList(Submitted) = .empty;
    var encoded_receipts: std.ArrayList([]const u8) = .empty;
    var receipts: std.ArrayList(Receipt) = .empty;
    var rejected: std.ArrayList(Rejected) = .empty;
    var traces: std.ArrayList(Trace) = .empty;
    var logs_bloom = evmz.eth.receipt.empty_logs_bloom;
    var logs_rlp = Writer.alloc(allocator);
    var log_index: usize = 0;
    var blob_gas_used: u64 = 0;
    const blob_gas_limit = try block_stf.blockBlobGasLimit(revision, Engine, env.blob_params);
    var deposit_request_data: std.ArrayList(u8) = .empty;
    var invalid_deposit_event_layout = false;

    for (candidates, 0..) |candidate, index| {
        const ready = switch (candidate) {
            .rejected => |message| {
                try rejected.append(allocator, .{ .index = index, .@"error" = message });
                continue;
            },
            .ready => |value| value,
        };
        try body.append(allocator, ready.bytes);
        // The reference tool rejects pre-fork types before touching the
        // transaction trie; every later rejection happens after the insert.
        if (!Engine.spec.transaction.active_kinds.contains(ready.value.kind)) {
            try rejected.append(allocator, .{
                .index = index,
                .@"error" = preForkTransactionError(ready.value.kind),
            });
            continue;
        }
        try trie.append(allocator, .{ .index = index, .bytes = ready.bytes });
        const tx_blob_gas = try block_stf.transactionBlobGasUsed(revision, Engine, &ready.value);
        const next_blob_gas = std.math.add(u64, blob_gas_used, tx_blob_gas) catch std.math.maxInt(u64);
        if (next_blob_gas > blob_gas_limit) {
            try rejected.append(allocator, .{
                .index = index,
                .@"error" = "TransactionException.TYPE_3_TX_MAX_BLOB_GAS_ALLOWANCE_EXCEEDED",
            });
            continue;
        }
        if (produces_bal) {
            bal_collector.block_access_index = try evmz.eth.bal.transactionIndex(@intCast(index));
        }
        if (tracing) try capture.begin();
        const outcome = transactPayload(
            Engine,
            &block,
            env,
            &ready.value,
            if (tracing) &capture else null,
            observer,
        ) catch |err| {
            if (err != error.BlockGasExceeded) return err;
            if (tracing) try capture.abort();
            try rejected.append(allocator, .{
                .index = index,
                .@"error" = "TransactionException.GAS_ALLOWANCE_EXCEEDED",
            });
            continue;
        };
        const included = switch (outcome) {
            .included => |value| value,
            .rejected => |reason| {
                if (tracing) try capture.abort();
                try rejected.append(allocator, .{
                    .index = index,
                    .@"error" = validationErrorName(reason),
                });
                continue;
            },
        };
        if (tracing) {
            _ = try capture.finish();
            try traces.append(allocator, .{
                .name = try std.fmt.allocPrint(allocator, "trace-{d}-0x{x}.jsonl", .{
                    index,
                    evmz.crypto.keccak256(ready.bytes),
                }),
                .bytes = try callframes.encode(allocator, call_arena.latest().?),
            });
        }
        blob_gas_used = next_blob_gas;
        if (!state_test and revision.isImpl(.prague) and !invalid_deposit_event_layout) {
            evmz.eth.eip6110.appendRequestDataFromLogs(
                allocator,
                &deposit_request_data,
                included.receipt.logs,
            ) catch |err| switch (err) {
                error.InvalidRequest => invalid_deposit_event_layout = true,
                else => return err,
            };
        }

        const bloom = evmz.eth.receipt.logsBloom(included.receipt.logs);
        evmz.eth.receipt.mergeLogsBloom(&logs_bloom, bloom);
        try writeLogs(&logs_rlp, included.receipt.logs);
        try encoded_receipts.append(allocator, try evmz.eth.receipt.encodeView(
            allocator,
            ready.value.kind,
            included.receipt,
            &bloom,
        ));
        try receipts.append(allocator, try receiptDocument(
            allocator,
            included.receipt,
            bloom,
            ready,
            index,
            env,
            log_index,
            tx_blob_gas,
        ));
        log_index += included.receipt.logs.len();
        if (!state_test) {
            const progress = block.progress();
            const calls = Engine.spec.block.afterTransaction(.{
                .number = env.number,
                .timestamp = env.timestamp,
                .transaction_index = progress.tx_count - 1,
                .status = included.receipt.status,
                .gas_used = included.receipt.gas_used,
                .cumulative_gas_used = progress.gas_used,
                .cumulative_block_gas = progress.block_gas.total,
                .cumulative_state_gas = progress.block_gas.state,
            });
            try applySystemCalls(&executor, context, calls.slice(), observer);
        }
    }

    if (!state_test) {
        if (produces_bal) {
            bal_collector.block_access_index = try evmz.eth.bal.postExecutionSystemIndex(
                @intCast(candidates.len),
            );
        }
        try block_stf.applyWithdrawals(&executor, context, environment.withdrawals, observer);
        try applyReward(&executor, context, env.coinbase, options.reward, observer);
    }
    const finalize_progress = block.progress();
    const finalize_calls = Engine.spec.block.finalizeBlock(.{
        .number = env.number,
        .timestamp = env.timestamp,
        .transaction_count = finalize_progress.tx_count,
        .gas_used = finalize_progress.gas_used,
        .block_gas = finalize_progress.block_gas.total,
        .state_gas = finalize_progress.block_gas.state,
    });
    var block_exception: ?[]const u8 = if (invalid_deposit_event_layout)
        "BlockException.INVALID_DEPOSIT_EVENT_LAYOUT"
    else
        null;
    var requests: []const []const u8 = &.{};
    if (!state_test and block_exception == null) {
        for (finalize_calls.slice()) |call| {
            if (call.call.require_code and !try executor.accountHasCode(call.call.recipient)) {
                block_exception = "BlockException.SYSTEM_CONTRACT_EMPTY";
                break;
            }
        }
        if (block_exception == null) {
            requests = block_stf.deriveRequests(
                allocator,
                &executor,
                context,
                deposit_request_data.items,
                finalize_calls.slice(),
                observer,
            ) catch |err| switch (err) {
                error.SystemCallFailed => blk: {
                    block_exception = "BlockException.SYSTEM_CONTRACT_CALL_FAILED";
                    break :blk &.{};
                },
                else => return err,
            };
        }
    }
    var block_access_list: ?[]const u8 = null;
    if (produces_bal) {
        block_access_list = if (state_test or block_exception != null) &.{0xc0} else blk: {
            const decoded = try bal_builder.finish();
            evmz.eth.bal.validateGasLimit(decoded.accounts, env.gas_limit) catch |err| switch (err) {
                error.BlockAccessListGasLimitExceeded => {
                    block_exception = "BlockException.BLOCK_ACCESS_LIST_GAS_LIMIT_EXCEEDED";
                },
                else => return err,
            };
            break :blk try evmz.eth.bal.encodeAlloc(allocator, decoded.accounts);
        };
    }

    const progress = block.finish();
    const delta = try evmz.state.StateDelta.init(allocator, executor.acceptedChanges());
    try store.committer().commit(delta.view());
    if (options.reward == 0) {
        if (store.getAccount(env.coinbase)) |coinbase| {
            if (coinbase.account.isEip161Empty()) _ = store.removeAccount(env.coinbase);
        }
    }
    try closeList(&logs_rlp, 0);
    const request_documents = try allocator.alloc(Hex, requests.len);
    for (request_documents, requests) |*document, request| document.* = .{ .bytes = request };

    return .{
        .alloc = try allocDocument(allocator, store),
        .result = .{
            .stateRoot = .{ .bytes = try store.stateRootWithOptions(allocator, .{ .empty_accounts = .include }) },
            .txRoot = .{ .bytes = try transactionRoot(allocator, trie.items) },
            .receiptsRoot = .{ .bytes = try evmz.eth.trie.receiptRoot(allocator, encoded_receipts.items) },
            .logsHash = .{ .bytes = evmz.crypto.keccak256(logs_rlp.written()) },
            .logsBloom = .{ .bytes = logs_bloom },
            .receipts = receipts.items,
            .rejected = if (rejected.items.len != 0) rejected.items else null,
            .gasUsed = quantity(progress.block_gas.total),
            .currentBaseFee = quantity(env.base_fee),
            .withdrawalsRoot = if (revision.isImpl(.shanghai))
                Hash{ .bytes = try evmz.eth.trie.withdrawalsRoot(allocator, environment.withdrawals) }
            else
                null,
            .currentExcessBlobGas = if (environment.excess_blob_gas) |excess| quantity(excess) else null,
            .blobGasUsed = if (revision.isImpl(.cancun)) quantity(blob_gas_used) else null,
            .requests = if (revision.isImpl(.prague)) request_documents else null,
            .requestsHash = if (revision.isImpl(.prague))
                Hash{ .bytes = try block_stf.requestsHash(allocator, requests) }
            else
                null,
            .blockAccessList = if (block_access_list) |bytes| Hex{ .bytes = bytes } else null,
            .blockAccessListHash = if (block_access_list) |bytes|
                Hash{ .bytes = evmz.crypto.keccak256(bytes) }
            else
                null,
            .blockException = block_exception,
        },
        .body = .{ .bytes = try encodeBody(allocator, body.items) },
        .traces = traces.items,
    };
}

/// The two lifecycle wrappers in `system_contracts` differ only by observer.
fn applySystemCalls(
    executor: anytype,
    context: evmz.execution.ExecutionContext,
    calls: []const evmz.block.lifecycle.BlockSystemCall,
    observer: anytype,
) !void {
    if (comptime @TypeOf(observer) == void) {
        return system_contracts.applyBeforeBlock(executor, context, calls);
    }
    return system_contracts.applyBeforeBlockObserved(executor, context, calls, observer);
}

fn applyReward(
    executor: anytype,
    context: evmz.execution.ExecutionContext,
    coinbase: evmz.Address,
    reward: i256,
    observer: anytype,
) !void {
    if (reward == -1) return;
    std.debug.assert(reward == 0);
    const scope = if (comptime @TypeOf(observer) != void) executor.observe(observer) else executor;
    try scope.beginStateTransition(context);
    errdefer executor.discardStateTransition();
    try executor.touchAccount(coinbase);
    try scope.commitTransaction();
}

fn transactPayload(
    comptime Engine: type,
    block: *Engine.BlockExecution,
    env: evmz.Env,
    transaction: *const Engine.Transaction,
    capture: ?*evmz.executor.CaptureContext,
    observer: anytype,
) !Engine.BlockExecution.Outcome {
    const PayloadPrelude = struct {
        env: evmz.Env,
        transaction_index: u64,

        pub fn run(
            self: *@This(),
            prelude: Engine.BlockExecution.PreludeContext,
        ) Engine.BlockExecution.PreludeContext.Error!void {
            const calls = Engine.spec.block.beforeTransaction(.{
                .number = self.env.number,
                .timestamp = self.env.timestamp,
                .transaction_index = self.transaction_index,
            });
            try system_contracts.applyPreludeSystemCalls(
                prelude,
                block_stf.lifecycleExecutionContext(self.env),
                calls.slice(),
            );
        }
    };
    var payload_prelude = PayloadPrelude{ .env = env, .transaction_index = block.progress().tx_count };
    const prelude = Engine.BlockExecution.Prelude.init(&payload_prelude);
    if (capture) |context| return block.capture(context, observer).transactWithPrelude(transaction, prelude);
    if (comptime @TypeOf(observer) == void) return block.transactWithPrelude(transaction, prelude);
    return block.observe(observer).transactWithPrelude(transaction, prelude);
}

fn writeLogs(writer: *Writer, logs: evmz.state.LogBuffer.View) !void {
    for (0..logs.len()) |index| {
        const event = logs.get(index);
        const start = writer.written().len;
        try writer.bytes(event.address.asBytes());
        const topics_start = writer.written().len;
        for (event.topics) |topic| try writer.bytes(&evmz.uint256.toBytes32(topic));
        try closeList(writer, topics_start);
        try writer.bytes(event.data);
        try closeList(writer, start);
    }
}

fn transactionRoot(allocator: Allocator, transactions: []const Submitted) ![32]u8 {
    if (transactions.len == 0) return evmz.eth.trie.empty_root_hash;
    const pairs = try allocator.alloc(evmz.eth.trie.Pair, transactions.len);
    const keys = try allocator.alloc([1 + @sizeOf(usize)]u8, transactions.len);
    for (transactions, pairs, keys) |transaction, *pair, *key| {
        pair.* = .{
            .key = try evmz.rlp.encode(usize, key, transaction.index),
            .value = transaction.bytes,
        };
    }
    return evmz.eth.trie.root(allocator, pairs);
}

fn encodeBody(allocator: Allocator, transactions: []const []const u8) ![]u8 {
    var body = Writer.alloc(allocator);
    for (transactions) |bytes| {
        if (bytes[0] >= 0xc0) try body.raw(try evmz.rlp.parseExact(bytes)) else try body.bytes(bytes);
    }
    try closeList(&body, 0);
    return body.toOwnedSlice();
}

fn preForkTransactionError(kind: TxKind) []const u8 {
    return switch (kind) {
        .legacy => unreachable,
        .access_list => "TransactionException.TYPE_1_TX_PRE_FORK",
        .dynamic_fee => "TransactionException.TYPE_2_TX_PRE_FORK",
        .blob => "TransactionException.TYPE_3_TX_PRE_FORK",
        .set_code => "TransactionException.TYPE_4_TX_PRE_FORK",
    };
}

fn validationErrorName(reason: evmz.eth.transaction_validation.ValidationError) []const u8 {
    return switch (reason) {
        .intrinsic_gas_too_low => "TransactionException.INTRINSIC_GAS_TOO_LOW",
        .intrinsic_gas_below_floor_gas_cost => "TransactionException.INTRINSIC_GAS_BELOW_FLOOR_GAS_COST",
        .insufficient_account_funds => "TransactionException.INSUFFICIENT_ACCOUNT_FUNDS",
        .insufficient_max_fee_per_gas => "TransactionException.INSUFFICIENT_MAX_FEE_PER_GAS",
        .priority_greater_than_max_fee_per_gas => "TransactionException.PRIORITY_GREATER_THAN_MAX_FEE_PER_GAS",
        .insufficient_max_fee_per_blob_gas => "TransactionException.INSUFFICIENT_MAX_FEE_PER_BLOB_GAS",
        .gas_limit_exceeds_maximum => "TransactionException.GAS_LIMIT_EXCEEDS_MAXIMUM",
        .gas_allowance_exceeded => "TransactionException.GAS_ALLOWANCE_EXCEEDED",
        .nonce_is_max => "TransactionException.NONCE_IS_MAX",
        .nonce_too_low => "TransactionException.NONCE_MISMATCH_TOO_LOW",
        .nonce_too_high => "TransactionException.NONCE_MISMATCH_TOO_HIGH",
        .type_1_tx_pre_fork => "TransactionException.TYPE_1_TX_PRE_FORK",
        .type_2_tx_pre_fork => "TransactionException.TYPE_2_TX_PRE_FORK",
        .type_3_tx_pre_fork => "TransactionException.TYPE_3_TX_PRE_FORK",
        .type_4_tx_pre_fork => "TransactionException.TYPE_4_TX_PRE_FORK",
        .type_3_tx_contract_creation => "TransactionException.TYPE_3_TX_CONTRACT_CREATION",
        .type_3_tx_zero_blobs => "TransactionException.TYPE_3_TX_ZERO_BLOBS",
        .type_3_tx_blob_count_exceeded => "TransactionException.TYPE_3_TX_BLOB_COUNT_EXCEEDED",
        .type_3_tx_max_blob_gas_allowance_exceeded => "TransactionException.TYPE_3_TX_MAX_BLOB_GAS_ALLOWANCE_EXCEEDED",
        .type_3_tx_invalid_blob_versioned_hash => "TransactionException.TYPE_3_TX_INVALID_BLOB_VERSIONED_HASH",
        .initcode_size_exceeded => "TransactionException.INITCODE_SIZE_EXCEEDED",
        .sender_not_eoa => "TransactionException.SENDER_NOT_EOA",
        .type_4_empty_authorization_list => "TransactionException.TYPE_4_EMPTY_AUTHORIZATION_LIST",
        .type_4_tx_contract_creation => "TransactionException.TYPE_4_TX_CONTRACT_CREATION",
        .invalid_chain_id => "TransactionException.INVALID_CHAINID",
    };
}

fn rawTransactionError(err: anyerror) []const u8 {
    return switch (err) {
        error.InvalidSignature, error.UnsupportedLegacyV => "TransactionException.INVALID_SIGNATURE_VRS",
        error.UnsupportedTransactionType => "TransactionException.TYPE_NOT_SUPPORTED",
        else => "TransactionException.INVALID_TRANSACTION_FORMAT",
    };
}

// -- Output documents ---------------------------------------------------------

/// JSON string of `0x` plus lowercase hex; `T` is a byte slice or byte array.
fn HexOf(comptime T: type) type {
    return struct {
        bytes: T,

        pub fn jsonStringify(self: @This(), jw: anytype) !void {
            const bytes: []const u8 = self.bytes[0..];
            try jw.print("\"0x{x}\"", .{bytes});
        }

        pub fn jsonParse(allocator: Allocator, source: anytype, options: std.json.ParseOptions) !@This() {
            const body = stripHexPrefix(try textToken(allocator, source, options));
            var self: @This() = undefined;
            const bytes: []u8 = if (@typeInfo(T) == .pointer)
                try allocator.alloc(u8, body.len / 2)
            else
                &self.bytes;
            if (bytes.len * 2 != body.len) return error.LengthMismatch;
            _ = std.fmt.hexToBytes(bytes, body) catch return error.InvalidCharacter;
            if (@typeInfo(T) == .pointer) self.bytes = bytes;
            return self;
        }
    };
}

const Hex = HexOf([]const u8);
const Hash = HexOf([32]u8);
const AddressHex = HexOf([20]u8);
const Bloom = HexOf([256]u8);

const Quantity = struct {
    value: u256,

    pub const zero: Quantity = .{ .value = 0 };

    pub fn jsonStringify(self: Quantity, jw: anytype) !void {
        try jw.print("\"0x{x}\"", .{self.value});
    }

    pub fn jsonParse(allocator: Allocator, source: anytype, options: std.json.ParseOptions) !Quantity {
        return .{ .value = try parseQuantityText(try textToken(allocator, source, options)) };
    }

    fn narrow(self: Quantity, comptime T: type) !T {
        return std.math.cast(T, self.value) orelse error.InvalidInput;
    }
};

fn quantity(value: anytype) Quantity {
    return .{ .value = value };
}

fn hexAlloc(allocator: Allocator, bytes: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator, "0x{x}", .{bytes});
}

const Alloc = std.json.ArrayHashMap(Account);

const Account = struct {
    balance: Quantity,
    nonce: ?Quantity,
    code: ?Hex,
    storage: ?std.json.ArrayHashMap(Hash),
};

/// Null-valued optional fields are omitted from the serialized result.
const Result = struct {
    stateRoot: Hash,
    txRoot: Hash,
    receiptsRoot: Hash,
    logsHash: Hash,
    logsBloom: Bloom,
    receipts: []const Receipt,
    rejected: ?[]const Rejected,
    gasUsed: Quantity,
    currentBaseFee: Quantity,
    withdrawalsRoot: ?Hash,
    currentExcessBlobGas: ?Quantity,
    blobGasUsed: ?Quantity,
    requests: ?[]const Hex,
    requestsHash: ?Hash,
    blockAccessList: ?Hex,
    blockAccessListHash: ?Hash,
    blockException: ?[]const u8,
};

const Rejected = struct {
    index: usize,
    @"error": []const u8,
};

const Receipt = struct {
    root: []const u8 = "0x",
    status: []const u8,
    cumulativeGasUsed: Quantity,
    logsBloom: Bloom,
    logs: []const Log,
    transactionHash: Hash,
    contractAddress: AddressHex,
    gasUsed: Quantity,
    blockHash: Hash,
    blockNumber: Quantity,
    transactionIndex: Quantity,
    type: ?[]const u8,
    blobGasUsed: ?Quantity,
    blobGasPrice: ?Quantity,
};

const Log = struct {
    address: AddressHex,
    topics: []const Hash,
    data: Hex,
    blockNumber: Quantity,
    transactionHash: Hash,
    transactionIndex: Quantity,
    blockHash: Hash,
    logIndex: Quantity,
    removed: bool = false,
    blockTimestamp: Quantity,
};

const Trace = struct {
    name: []const u8,
    bytes: []const u8,
};

const Documents = struct {
    alloc: Alloc,
    result: Result,
    body: Hex,
    traces: []const Trace,
};

fn receiptDocument(
    allocator: Allocator,
    receipt: anytype,
    bloom: [256]u8,
    transaction: EncodedTransaction,
    index: usize,
    env: evmz.Env,
    first_log_index: usize,
    blob_gas_used: u64,
) !Receipt {
    const block_hash = [_]u8{ 0x13, 0x37 } ++ [_]u8{0} ** 30;
    const transaction_hash = evmz.crypto.keccak256(transaction.bytes);
    const logs = try allocator.alloc(Log, receipt.logs.len());
    for (logs, 0..) |*log, offset| {
        const event = receipt.logs.get(offset);
        const topics = try allocator.alloc(Hash, event.topics.len);
        for (topics, event.topics) |*topic, value| topic.* = .{ .bytes = evmz.uint256.toBytes32(value) };
        log.* = .{
            .address = .{ .bytes = event.address.bytes },
            .topics = topics,
            .data = .{ .bytes = try allocator.dupe(u8, event.data) },
            .blockNumber = quantity(env.number),
            .transactionHash = .{ .bytes = transaction_hash },
            .transactionIndex = quantity(index),
            .blockHash = .{ .bytes = block_hash },
            .logIndex = quantity(first_log_index + offset),
            .blockTimestamp = quantity(env.timestamp),
        };
    }
    const kind = transaction.value.kind;
    return .{
        .status = switch (receipt.status) {
            .success => "0x1",
            .revert, .invalid, .out_of_gas => "0x0",
        },
        .cumulativeGasUsed = quantity(receipt.cumulative_gas_used),
        .logsBloom = .{ .bytes = bloom },
        .logs = logs,
        .transactionHash = .{ .bytes = transaction_hash },
        .contractAddress = .{
            .bytes = if (receipt.created_address) |created| created.bytes else [_]u8{0} ** 20,
        },
        .gasUsed = quantity(receipt.gas_used),
        .blockHash = .{ .bytes = block_hash },
        .blockNumber = quantity(env.number),
        .transactionIndex = quantity(index),
        .type = switch (kind) {
            .legacy => null,
            .access_list => "0x1",
            .dynamic_fee => "0x2",
            .blob => "0x3",
            .set_code => "0x4",
        },
        .blobGasUsed = if (kind == .blob) quantity(blob_gas_used) else null,
        .blobGasPrice = if (kind == .blob) quantity(env.blob_base_fee) else null,
    };
}

fn serialize(allocator: Allocator, value: anytype) ![]const u8 {
    return std.json.Stringify.valueAlloc(allocator, value, .{ .emit_null_optional_fields = false });
}

fn writeOutputs(allocator: Allocator, io: std.Io, options: Options, documents: Documents) !void {
    std.Io.Dir.cwd().createDirPath(io, options.output_basedir) catch return error.InputOutput;

    // Like the reference tools, everything routed to stdout is one keyed object.
    var stdout_object: struct { alloc: ?Alloc = null, result: ?Result = null, body: ?Hex = null } = .{};
    if (eql(u8, options.output_alloc, "stdout")) {
        stdout_object.alloc = documents.alloc;
    } else {
        try writeFile(allocator, io, options, options.output_alloc, try serialize(allocator, documents.alloc));
    }
    if (eql(u8, options.output_result, "stdout")) {
        stdout_object.result = documents.result;
    } else {
        try writeFile(allocator, io, options, options.output_result, try serialize(allocator, documents.result));
    }
    if (options.output_body) |destination| {
        if (eql(u8, destination, "stdout")) {
            stdout_object.body = documents.body;
        } else {
            try writeFile(allocator, io, options, destination, try serialize(allocator, documents.body));
        }
    }
    if (stdout_object.alloc != null or stdout_object.result != null or stdout_object.body != null) {
        var buffer: [16 * 1024]u8 = undefined;
        var stdout = std.Io.File.stdout().writerStreaming(io, &buffer);
        stdout.interface.print("{s}\n", .{try serialize(allocator, stdout_object)}) catch
            return error.InputOutput;
        stdout.interface.flush() catch return error.InputOutput;
    }
    for (documents.traces) |trace| try writeFile(allocator, io, options, trace.name, trace.bytes);
}

fn writeFile(
    allocator: Allocator,
    io: std.Io,
    options: Options,
    destination: []const u8,
    bytes: []const u8,
) !void {
    const path = if (std.fs.path.isAbsolute(destination))
        destination
    else
        try std.fs.path.join(allocator, &.{ options.output_basedir, destination });
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = bytes }) catch
        return error.InputOutput;
}

fn readInput(allocator: Allocator, io: std.Io, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .unlimited) catch |err|
        return classify(err, error.InputOutput);
}

fn printUsage(io: std.Io) !void {
    const text =
        \\usage: evmz-t8n [options]
        \\
        \\  --input.alloc <path>       pre-state alloc JSON
        \\  --input.env <path>         block environment JSON
        \\  --input.txs <path>         transaction array JSON
        \\  --output.alloc <path>      post-state alloc JSON
        \\  --output.result <path>     transition result JSON
        \\  --output.body <path>       accepted transaction body
        \\  --output.basedir <path>    base directory for relative outputs
        \\  --state.fork <name>        Paris through Amsterdam
        \\  --state.chainid <id>       positive chain ID
        \\  --state.reward <-1|0>      disabled or zero reward
        \\  --state-test               skip block-level system operations
        \\  --trace.callframes         call-frame JSONL per accepted transaction
        \\  -h, --help
        \\  --version
        \\
    ;
    var buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(io, &buffer);
    try stdout.interface.writeAll(text);
    try stdout.interface.flush();
}

fn printVersion(io: std.Io) !void {
    var buffer: [128]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(io, &buffer);
    try stdout.interface.print("evmz-t8n 0.0.0 (zig {s})\n", .{@import("builtin").zig_version_string});
    try stdout.interface.flush();
}

fn parseJson(comptime T: type, allocator: Allocator, bytes: []const u8) !T {
    return std.json.parseFromSliceLeaky(T, allocator, bytes, .{}) catch |err|
        return classify(err, error.InvalidInput);
}

/// Next scalar token as text; bare numbers qualify so quantities need not be quoted.
fn textToken(allocator: Allocator, source: anytype, options: std.json.ParseOptions) ![]const u8 {
    return switch (try source.nextAllocMax(allocator, .alloc_if_needed, options.max_value_len.?)) {
        inline .number, .allocated_number, .string, .allocated_string => |text| text,
        else => error.UnexpectedToken,
    };
}

/// `0x` hex or bare decimal, the way geth reads quantities; a bare `0x` is zero.
fn parseQuantityText(text: []const u8) !u256 {
    const body = stripHexPrefix(text);
    if (body.len == text.len) return std.fmt.parseInt(u256, text, 10) catch error.InvalidNumber;
    if (body.len == 0) return 0;
    return std.fmt.parseInt(u256, body, 16) catch error.InvalidNumber;
}

fn stripHexPrefix(text: []const u8) []const u8 {
    if (std.mem.startsWith(u8, text, "0x") or std.mem.startsWith(u8, text, "0X")) return text[2..];
    return text;
}

/// Collapse every failure except allocation into one exit-code class.
fn classify(err: anyerror, class: anyerror) anyerror {
    return if (err == error.OutOfMemory) err else class;
}

fn exitCode(err: anyerror) u8 {
    return switch (err) {
        error.InvalidConfiguration => 3,
        error.MissingBlockHash => 4,
        error.InvalidInput => 10,
        error.InputOutput => 11,
        else => 2,
    };
}
