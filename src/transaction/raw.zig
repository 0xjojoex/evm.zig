const std = @import("std");

const ExactSlab = @import("stdx").ExactSlab;
const rlp = @import("rlp");
const transaction = @import("types.zig");
const transaction_envelope = @import("envelope.zig");
const transaction_signing = @import("signing.zig");

const Address = @import("../address.zig").Address;

pub const Error = std.mem.Allocator.Error || rlp.ParseError || transaction_signing.SenderRecoveryError || error{
    InvalidTransactionEnvelope,
    InvalidTransactionFormat,
    UnsupportedTransactionType,
} || error{Overflow};

const Counts = struct {
    access_entries: usize = 0,
    storage_keys: usize = 0,
    blob_hashes: usize = 0,
    authorizations: usize = 0,

    fn add(self: *Counts, other: Counts) Error!void {
        self.access_entries = try std.math.add(usize, self.access_entries, other.access_entries);
        self.storage_keys = try std.math.add(usize, self.storage_keys, other.storage_keys);
        self.blob_hashes = try std.math.add(usize, self.blob_hashes, other.blob_hashes);
        self.authorizations = try std.math.add(usize, self.authorizations, other.authorizations);
    }
};

const Storage = struct {
    slab: ExactSlab,
    transactions: []transaction.DecodedTransaction,
    access_entries: []transaction.AccessListEntry,
    storage_keys: []u256,
    blob_hashes: []u256,
    authorizations: []transaction.AuthorizationTuple,

    fn init(allocator: std.mem.Allocator, transaction_count: usize, counts: Counts) Error!Storage {
        var slab_len: usize = 0;
        slab_len = try ExactSlab.reserve(transaction.DecodedTransaction, slab_len, transaction_count);
        slab_len = try ExactSlab.reserve(transaction.AccessListEntry, slab_len, counts.access_entries);
        slab_len = try ExactSlab.reserve(u256, slab_len, counts.storage_keys);
        slab_len = try ExactSlab.reserve(u256, slab_len, counts.blob_hashes);
        slab_len = try ExactSlab.reserve(transaction.AuthorizationTuple, slab_len, counts.authorizations);

        var slab = try ExactSlab.init(allocator, slab_len);
        return .{
            .slab = slab,
            .transactions = slab.take(transaction.DecodedTransaction, transaction_count),
            .access_entries = slab.take(transaction.AccessListEntry, counts.access_entries),
            .storage_keys = slab.take(u256, counts.storage_keys),
            .blob_hashes = slab.take(u256, counts.blob_hashes),
            .authorizations = slab.take(transaction.AuthorizationTuple, counts.authorizations),
        };
    }

    fn deinit(self: *Storage, allocator: std.mem.Allocator) void {
        self.slab.deinit(allocator);
        self.* = undefined;
    }
};

/// One decoded transaction and the flat storage backing its nested slices.
/// `encoded` and `tx.input` borrow the caller's raw envelope.
pub const Decoded = struct {
    tx: transaction.Transaction,
    encoded: []const u8,
    storage: Storage,

    pub fn deinit(self: *Decoded, allocator: std.mem.Allocator) void {
        self.storage.deinit(allocator);
        self.* = undefined;
    }
};

/// Block-lifetime owner for raw transaction decoding. Every nested transaction
/// slice points into one of these exact flat buffers.
pub const DecodedBatch = struct {
    transactions: []transaction.DecodedTransaction,
    storage: Storage,

    pub fn deinit(self: *DecodedBatch, allocator: std.mem.Allocator) void {
        self.storage.deinit(allocator);
        self.* = undefined;
    }
};

pub fn decodeRaw(allocator: std.mem.Allocator, bytes: []const u8) Error!Decoded {
    const sender = (try transaction_signing.recoverSender(allocator, bytes)).sender;
    return decodeRawAssumeSender(allocator, bytes, sender);
}

/// Decode an envelope whose sender was already authenticated by a trusted
/// ingress adapter. The caller must bind `sender` to this exact signed payload.
pub fn decodeRawAssumeSender(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    sender: Address,
) Error!Decoded {
    var storage = try Storage.init(allocator, 0, try inspectRaw(bytes));
    errdefer storage.deinit(allocator);
    var fill = Fill.init(&storage);
    const tx = try decodeRawInto(bytes, sender, &fill);
    try fill.expectDone();
    return .{ .tx = tx, .encoded = bytes, .storage = storage };
}

/// Decode a block of envelopes with ordinary signature recovery.
pub fn decodeRawBatch(
    allocator: std.mem.Allocator,
    raw_transactions: []const []const u8,
) Error!DecodedBatch {
    return decodeRawBatchWith(allocator, raw_transactions, RecoverSender{});
}

/// Decode a block with a caller-owned sender authenticator. `resolver` must
/// expose `resolve(allocator, index, encoded) !Address`.
pub fn decodeRawBatchWith(
    allocator: std.mem.Allocator,
    raw_transactions: []const []const u8,
    resolver: anytype,
) !DecodedBatch {
    var counts: Counts = .{};
    for (raw_transactions) |encoded| try counts.add(try inspectRaw(encoded));

    var storage = try Storage.init(allocator, raw_transactions.len, counts);
    errdefer storage.deinit(allocator);

    var fill = Fill.init(&storage);
    for (storage.transactions, raw_transactions, 0..) |*target, encoded, index| {
        const sender = try resolver.resolve(allocator, index, encoded);
        target.* = .initAssumeDecoded(try decodeRawInto(encoded, sender, &fill), encoded);
    }
    try fill.expectDone();
    return .{ .transactions = storage.transactions, .storage = storage };
}

const RecoverSender = struct {
    fn resolve(
        _: RecoverSender,
        allocator: std.mem.Allocator,
        _: usize,
        encoded: []const u8,
    ) Error!Address {
        return (try transaction_signing.recoverSender(allocator, encoded)).sender;
    }
};

fn decodeRawInto(bytes: []const u8, sender: Address, fill: *Fill) Error!transaction.Transaction {
    const envelope = try transaction_envelope.decodeEnvelope(bytes);
    return switch (envelope) {
        .legacy => |legacy| decodeLegacy(legacy, sender),
        .typed => |typed| decodeTyped(typed, sender, fill),
    };
}

fn decodeLegacy(bytes: []const u8, sender: Address) Error!transaction.Transaction {
    var cursor = rlp.Cursor.init(bytes);
    var fields = try cursor.nextList();
    try cursor.expectDone();

    const nonce = try fields.nextInt(u256);
    const gas_price = try fields.nextInt(u256);
    const gas_limit = try fields.nextInt(u64);
    const to = try nextTo(&fields);
    const value = try fields.nextInt(u256);
    const input = try fields.nextBytes();
    const v = try fields.nextInt(u256);
    _ = try fields.nextInt(u256);
    _ = try fields.nextInt(u256);
    try fields.expectDone();

    return .{
        .kind = .legacy,
        .sender = sender,
        .chain_id = if (v >= 35) (v - 35) / 2 else null,
        .nonce = nonce,
        .gas_limit = gas_limit,
        .to = to,
        .value = value,
        .input = input,
        .gas_price = gas_price,
    };
}

fn decodeTyped(typed: transaction_envelope.TypedEnvelope, sender: Address, fill: *Fill) Error!transaction.Transaction {
    var cursor = rlp.Cursor.init(typed.payload);
    var fields = try cursor.nextList();
    try cursor.expectDone();

    return switch (typed.type_id) {
        0x01 => decodeAccessList(&fields, sender, fill),
        0x02 => decodeDynamicFee(&fields, sender, fill),
        0x03 => decodeBlob(&fields, sender, fill),
        transaction_envelope.set_code_transaction_type => decodeSetCode(&fields, sender, fill),
        else => error.UnsupportedTransactionType,
    };
}

fn decodeAccessList(fields: *rlp.Cursor, sender: Address, fill: *Fill) Error!transaction.Transaction {
    const chain_id = try fields.nextInt(u256);
    const nonce = try fields.nextInt(u256);
    const gas_price = try fields.nextInt(u256);
    const gas_limit = try fields.nextInt(u64);
    const to = try nextTo(fields);
    const value = try fields.nextInt(u256);
    const input = try fields.nextBytes();
    const access_list = try fill.nextAccessList(fields);
    _ = try fields.nextInt(u256);
    _ = try fields.nextInt(u256);
    _ = try fields.nextInt(u256);
    try fields.expectDone();

    return .{
        .kind = .access_list,
        .sender = sender,
        .chain_id = chain_id,
        .nonce = nonce,
        .gas_limit = gas_limit,
        .to = to,
        .value = value,
        .input = input,
        .gas_price = gas_price,
        .access_list = access_list,
    };
}

fn decodeDynamicFee(fields: *rlp.Cursor, sender: Address, fill: *Fill) Error!transaction.Transaction {
    const chain_id = try fields.nextInt(u256);
    const nonce = try fields.nextInt(u256);
    const max_priority_fee_per_gas = try fields.nextInt(u256);
    const max_fee_per_gas = try fields.nextInt(u256);
    const gas_limit = try fields.nextInt(u64);
    const to = try nextTo(fields);
    const value = try fields.nextInt(u256);
    const input = try fields.nextBytes();
    const access_list = try fill.nextAccessList(fields);
    _ = try fields.nextInt(u256);
    _ = try fields.nextInt(u256);
    _ = try fields.nextInt(u256);
    try fields.expectDone();

    return .{
        .kind = .dynamic_fee,
        .sender = sender,
        .chain_id = chain_id,
        .nonce = nonce,
        .gas_limit = gas_limit,
        .to = to,
        .value = value,
        .input = input,
        .max_fee_per_gas = max_fee_per_gas,
        .max_priority_fee_per_gas = max_priority_fee_per_gas,
        .access_list = access_list,
    };
}

fn decodeBlob(fields: *rlp.Cursor, sender: Address, fill: *Fill) Error!transaction.Transaction {
    const chain_id = try fields.nextInt(u256);
    const nonce = try fields.nextInt(u256);
    const max_priority_fee_per_gas = try fields.nextInt(u256);
    const max_fee_per_gas = try fields.nextInt(u256);
    const gas_limit = try fields.nextInt(u64);
    const to = try nextTo(fields);
    const value = try fields.nextInt(u256);
    const input = try fields.nextBytes();
    const access_list = try fill.nextAccessList(fields);
    const max_fee_per_blob_gas = try fields.nextInt(u256);
    const blob_hashes = try fill.nextHashList(fields);
    _ = try fields.nextInt(u256);
    _ = try fields.nextInt(u256);
    _ = try fields.nextInt(u256);
    try fields.expectDone();

    return .{
        .kind = .blob,
        .sender = sender,
        .chain_id = chain_id,
        .nonce = nonce,
        .gas_limit = gas_limit,
        .to = to,
        .value = value,
        .input = input,
        .max_fee_per_gas = max_fee_per_gas,
        .max_priority_fee_per_gas = max_priority_fee_per_gas,
        .max_fee_per_blob_gas = max_fee_per_blob_gas,
        .blob_hashes = blob_hashes,
        .access_list = access_list,
    };
}

fn decodeSetCode(fields: *rlp.Cursor, sender: Address, fill: *Fill) Error!transaction.Transaction {
    const chain_id = try fields.nextInt(u256);
    const nonce = try fields.nextInt(u256);
    const max_priority_fee_per_gas = try fields.nextInt(u256);
    const max_fee_per_gas = try fields.nextInt(u256);
    const gas_limit = try fields.nextInt(u64);
    const to = try nextTo(fields);
    const value = try fields.nextInt(u256);
    const input = try fields.nextBytes();
    const access_list = try fill.nextAccessList(fields);
    const authorization_list = try fill.nextAuthorizationList(fields);
    _ = try fields.nextInt(u256);
    _ = try fields.nextInt(u256);
    _ = try fields.nextInt(u256);
    try fields.expectDone();

    return .{
        .kind = .set_code,
        .sender = sender,
        .chain_id = chain_id,
        .nonce = nonce,
        .gas_limit = gas_limit,
        .to = to,
        .value = value,
        .input = input,
        .max_fee_per_gas = max_fee_per_gas,
        .max_priority_fee_per_gas = max_priority_fee_per_gas,
        .access_list = access_list,
        .authorization_list = authorization_list.entries,
        .authorization_count = authorization_list.count,
    };
}

fn nextTo(fields: *rlp.Cursor) Error!?Address {
    const bytes = try fields.nextBytes();
    return switch (bytes.len) {
        0 => null,
        20 => Address.fromBytes(bytes[0..20].*),
        else => error.InvalidTransactionFormat,
    };
}

const ParsedAuthorizationList = struct {
    entries: []const transaction.AuthorizationTuple,
    count: usize,
};

const Fill = struct {
    storage: *Storage,
    access_entries: usize = 0,
    storage_keys: usize = 0,
    blob_hashes: usize = 0,
    authorizations: usize = 0,

    fn init(storage: *Storage) Fill {
        return .{ .storage = storage };
    }

    fn expectDone(self: Fill) Error!void {
        if (self.access_entries != self.storage.access_entries.len or
            self.storage_keys != self.storage.storage_keys.len or
            self.blob_hashes != self.storage.blob_hashes.len)
            return error.InvalidTransactionFormat;
        if (self.authorizations > self.storage.authorizations.len)
            return error.InvalidTransactionFormat;
    }

    fn nextAccessList(self: *Fill, fields: *rlp.Cursor) Error![]const transaction.AccessListEntry {
        var list = try fields.nextList();
        const entries_start = self.access_entries;
        while (!list.isDone()) {
            if (self.access_entries >= self.storage.access_entries.len)
                return error.InvalidTransactionFormat;
            var entry = try list.nextList();
            const entry_address = Address.fromBytes((try entry.nextBytesExact(20))[0..20].*);
            var keys_cursor = try entry.nextList();
            const keys_start = self.storage_keys;
            while (!keys_cursor.isDone()) {
                if (self.storage_keys >= self.storage.storage_keys.len)
                    return error.InvalidTransactionFormat;
                self.storage.storage_keys[self.storage_keys] = readWord(try keys_cursor.nextBytesExact(32));
                self.storage_keys += 1;
            }
            try keys_cursor.expectDone();
            try entry.expectDone();
            self.storage.access_entries[self.access_entries] = .{
                .address = entry_address,
                .storage_keys = self.storage.storage_keys[keys_start..self.storage_keys],
            };
            self.access_entries += 1;
        }
        try list.expectDone();
        return self.storage.access_entries[entries_start..self.access_entries];
    }

    fn nextHashList(self: *Fill, fields: *rlp.Cursor) Error![]const u256 {
        var list = try fields.nextList();
        const start = self.blob_hashes;
        while (!list.isDone()) {
            if (self.blob_hashes >= self.storage.blob_hashes.len)
                return error.InvalidTransactionFormat;
            self.storage.blob_hashes[self.blob_hashes] = readWord(try list.nextBytesExact(32));
            self.blob_hashes += 1;
        }
        try list.expectDone();
        return self.storage.blob_hashes[start..self.blob_hashes];
    }

    // The guest pays a full secp recovery for tuples it will discard. Count raw
    // tuples in the first pass, but recover only once while filling.
    fn nextAuthorizationList(self: *Fill, fields: *rlp.Cursor) Error!ParsedAuthorizationList {
        var list = try fields.nextList();
        const start = self.authorizations;
        var count: usize = 0;
        while (!list.isDone()) {
            count = try std.math.add(usize, count, 1);
            var tuple = try list.nextList();
            const chain_id = try tuple.nextInt(u256);
            const target = Address.fromBytes((try tuple.nextBytesExact(20))[0..20].*);
            const nonce = try tuple.nextInt(u64);
            const y_parity = try tuple.nextInt(u256);
            const r = try tuple.nextInt(u256);
            const s = try tuple.nextInt(u256);
            try tuple.expectDone();
            const signer = transaction_signing.recoverAuthorizationSigner(
                chain_id,
                target,
                nonce,
                y_parity,
                r,
                s,
            ) catch |err| switch (err) {
                error.InvalidSignature => continue,
                else => return err,
            };
            if (self.authorizations >= self.storage.authorizations.len)
                return error.InvalidTransactionFormat;
            self.storage.authorizations[self.authorizations] = .{
                .chain_id = chain_id,
                .target = target,
                .signer = signer,
                .nonce = nonce,
                .y_parity = y_parity,
                .legacy_v = null,
                .r = r,
                .s = s,
            };
            self.authorizations += 1;
        }
        try list.expectDone();
        return .{
            .entries = self.storage.authorizations[start..self.authorizations],
            .count = count,
        };
    }
};

fn inspectRaw(bytes: []const u8) Error!Counts {
    const envelope = try transaction_envelope.decodeEnvelope(bytes);
    return switch (envelope) {
        .legacy => .{},
        .typed => |typed| inspectTyped(typed),
    };
}

fn inspectTyped(typed: transaction_envelope.TypedEnvelope) Error!Counts {
    const field_count: usize = switch (typed.type_id) {
        0x01 => 11,
        0x02 => 12,
        0x03 => 14,
        transaction_envelope.set_code_transaction_type => 13,
        else => return error.UnsupportedTransactionType,
    };
    var cursor = rlp.Cursor.init(typed.payload);
    var fields = try cursor.nextList();
    try cursor.expectDone();
    var counts: Counts = .{};
    for (0..field_count) |index| {
        const item = try fields.next();
        if (index == 7 and typed.type_id == 0x01 or
            index == 8 and typed.type_id != 0x01)
        {
            const access = try inspectAccessList(item);
            counts.access_entries = access.access_entries;
            counts.storage_keys = access.storage_keys;
        } else if (typed.type_id == 0x03 and index == 10) {
            counts.blob_hashes = try inspectFixedList(item, 32);
        } else if (typed.type_id == transaction_envelope.set_code_transaction_type and index == 9) {
            counts.authorizations = try inspectLists(item);
        }
    }
    try fields.expectDone();
    return counts;
}

fn inspectAccessList(item: rlp.Item) Error!Counts {
    var list = try item.listCursor();
    var counts: Counts = .{};
    while (!list.isDone()) {
        var entry = try list.nextList();
        _ = try entry.nextBytesExact(20);
        var keys = try entry.nextList();
        while (!keys.isDone()) {
            _ = try keys.nextBytesExact(32);
            counts.storage_keys = try std.math.add(usize, counts.storage_keys, 1);
        }
        try keys.expectDone();
        try entry.expectDone();
        counts.access_entries = try std.math.add(usize, counts.access_entries, 1);
    }
    try list.expectDone();
    return counts;
}

fn inspectFixedList(item: rlp.Item, len: usize) Error!usize {
    var list = try item.listCursor();
    var count: usize = 0;
    while (!list.isDone()) {
        _ = try list.nextBytesExact(len);
        count = try std.math.add(usize, count, 1);
    }
    try list.expectDone();
    return count;
}

fn inspectLists(item: rlp.Item) Error!usize {
    var list = try item.listCursor();
    var count: usize = 0;
    while (!list.isDone()) {
        _ = try list.nextList();
        count = try std.math.add(usize, count, 1);
    }
    try list.expectDone();
    return count;
}

fn readWord(bytes: []const u8) u256 {
    return std.mem.readInt(u256, bytes[0..32], .big);
}

test "raw stateless tx decoder parses EIP-155 legacy transaction" {
    const hex = "f86c098504a817c800825208943535353535353535353535353535353535353535880de0b6b3a76400008025a028ef61340bd939bc2195fe537567866003e1a15d3c71ff63e1590620aa636276a067cbe9d8997f761aecb703304b3800ccf555c9f3dc64214b297fb1966a3b6d83";
    var bytes: [hex.len / 2]u8 = undefined;
    _ = try std.fmt.hexToBytes(&bytes, hex);

    var decoded = try decodeRaw(std.testing.allocator, &bytes);
    defer decoded.deinit(std.testing.allocator);
    const tx = decoded.tx;
    try std.testing.expectEqual(transaction.TxKind.legacy, tx.kind);
    try std.testing.expectEqual(@as(u256, 9), tx.nonce.?);
    try std.testing.expectEqual(@as(u64, 21_000), tx.gas_limit);
    try std.testing.expectEqual(@as(u256, 20_000_000_000), tx.gas_price);
    try std.testing.expectEqual(@as(u256, 1_000_000_000_000_000_000), tx.value);
}

test "raw stateless tx decoder preserves oversized nonce for validation" {
    const hex = "f86a890100000000000000000a840100000094c0f6dc9e5836f54caadbf59cc69346c508e1992b80801ba0cd04d88708bbad530786430987e9667cba97f605f4819110969e251ef1eeb93aa040f1a49cc61090cefdfdea2f53a8db89c229fad178f469a86dcebefe63e56fbc";
    var bytes: [hex.len / 2]u8 = undefined;
    _ = try std.fmt.hexToBytes(&bytes, hex);

    var decoded = try decodeRaw(std.testing.allocator, &bytes);
    defer decoded.deinit(std.testing.allocator);
    const tx = decoded.tx;
    try std.testing.expectEqual(@as(u256, 1) << 64, tx.nonce.?);
}

test "raw stateless tx decoder counts but skips unrecoverable authorization tuples" {
    const allocator = std.testing.allocator;
    var tuple_fields = rlp.Writer.alloc(allocator);
    defer tuple_fields.deinit();
    var tuple = rlp.Writer.alloc(allocator);
    defer tuple.deinit();
    var list = rlp.Writer.alloc(allocator);
    defer list.deinit();

    try tuple_fields.int(u8, 1);
    try tuple_fields.bytes(&([_]u8{0x11} ** 20));
    try tuple_fields.int(u64, 0);
    try tuple_fields.int(u8, 0);
    try tuple_fields.int(u8, 0);
    try tuple_fields.int(u8, 1);
    try tuple.listPayload(tuple_fields.written());
    try list.listPayload(tuple.written());

    var storage = try Storage.init(allocator, 0, .{ .authorizations = 1 });
    defer storage.deinit(allocator);
    var fill = Fill.init(&storage);
    var cursor = rlp.Cursor.init(list.written());
    const parsed = try fill.nextAuthorizationList(&cursor);
    try cursor.expectDone();

    try std.testing.expectEqual(@as(usize, 1), parsed.count);
    try std.testing.expectEqual(@as(usize, 0), parsed.entries.len);
}

test "raw stateless tx decoder releases flat nested storage" {
    const encoded = try dynamicFeeTransactionForTest(std.testing.allocator, false);
    defer std.testing.allocator.free(encoded);

    var backing: [4096]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&backing);
    const prefix = try fixed.allocator().alloc(u8, 1);
    var decoded = try decodeRawAssumeSender(fixed.allocator(), encoded, Address.zero);

    try std.testing.expectEqual(@as(usize, 1), decoded.tx.access_list.len);
    try std.testing.expectEqual(@as(usize, 1), decoded.tx.access_list[0].storage_keys.len);
    try std.testing.expect(fixed.end_index > prefix.len);
    decoded.deinit(fixed.allocator());
    try std.testing.expectEqual(prefix.len, fixed.end_index);
    fixed.allocator().free(prefix);
    try std.testing.expectEqual(@as(usize, 0), fixed.end_index);
}

test "raw stateless tx decoder rolls back nested storage after fill error" {
    const encoded = try dynamicFeeTransactionForTest(std.testing.allocator, true);
    defer std.testing.allocator.free(encoded);

    var backing: [4096]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&backing);
    const prefix = try fixed.allocator().alloc(u8, 1);
    try std.testing.expectError(
        error.NonCanonicalInteger,
        decodeRawAssumeSender(fixed.allocator(), encoded, Address.zero),
    );
    try std.testing.expectEqual(prefix.len, fixed.end_index);
    fixed.allocator().free(prefix);
    try std.testing.expectEqual(@as(usize, 0), fixed.end_index);
}

test "raw stateless tx batch rolls back after a later transaction fails" {
    const valid = try dynamicFeeTransactionForTest(std.testing.allocator, false);
    defer std.testing.allocator.free(valid);
    const malformed = try dynamicFeeTransactionForTest(std.testing.allocator, true);
    defer std.testing.allocator.free(malformed);
    const raw_transactions = [_][]const u8{ valid, malformed };

    var backing: [8192]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&backing);
    const prefix = try fixed.allocator().alloc(u8, 1);
    try std.testing.expectError(
        error.NonCanonicalInteger,
        decodeRawBatchWith(fixed.allocator(), &raw_transactions, AssumeSender{}),
    );
    try std.testing.expectEqual(prefix.len, fixed.end_index);
    fixed.allocator().free(prefix);
    try std.testing.expectEqual(@as(usize, 0), fixed.end_index);
}

test "raw stateless tx batch cleans every allocation failure" {
    const encoded = try dynamicFeeTransactionForTest(std.testing.allocator, false);
    defer std.testing.allocator.free(encoded);
    const raw_transactions = [_][]const u8{encoded};

    const Harness = struct {
        fn run(allocator: std.mem.Allocator, raws: []const []const u8) !void {
            var decoded = try decodeRawBatchWith(allocator, raws, AssumeSender{});
            defer decoded.deinit(allocator);
            try std.testing.expectEqual(@as(usize, 1), decoded.transactions[0].tx.access_list.len);
        }
    };
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        Harness.run,
        .{&raw_transactions},
    );
}

const AssumeSender = struct {
    pub fn resolve(
        _: AssumeSender,
        _: std.mem.Allocator,
        _: usize,
        _: []const u8,
    ) Error!Address {
        return Address.zero;
    }
};

fn dynamicFeeTransactionForTest(allocator: std.mem.Allocator, malformed_y_parity: bool) ![]u8 {
    var storage_keys = rlp.Writer.alloc(allocator);
    defer storage_keys.deinit();
    try storage_keys.bytes(&([_]u8{0x22} ** 32));

    var access_entry = rlp.Writer.alloc(allocator);
    defer access_entry.deinit();
    try access_entry.bytes(&([_]u8{0x11} ** 20));
    try access_entry.listPayload(storage_keys.written());

    var access_list = rlp.Writer.alloc(allocator);
    defer access_list.deinit();
    try access_list.listPayload(access_entry.written());

    var fields = rlp.Writer.alloc(allocator);
    defer fields.deinit();
    try fields.int(u8, 1); // chain id
    try fields.int(u8, 0); // nonce
    try fields.int(u8, 1); // max priority fee
    try fields.int(u8, 2); // max fee
    try fields.int(u64, 21_000);
    try fields.bytes(&([_]u8{0x33} ** 20));
    try fields.int(u8, 0); // value
    try fields.bytes(&.{}); // input
    try fields.listPayload(access_list.written());
    if (malformed_y_parity)
        try fields.bytes(&.{0})
    else
        try fields.int(u8, 0);
    try fields.int(u8, 1);
    try fields.int(u8, 1);

    var payload = rlp.Writer.alloc(allocator);
    defer payload.deinit();
    try payload.listPayload(fields.written());

    const out = try allocator.alloc(u8, payload.written().len + 1);
    out[0] = 0x02;
    @memcpy(out[1..], payload.written());
    return out;
}
