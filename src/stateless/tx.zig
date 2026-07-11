const std = @import("std");

const Evm = @import("../evm.zig").Evm;
const rlp = @import("../rlp.zig");
const transaction = @import("../transaction.zig");
const transaction_envelope = @import("../transaction/envelope.zig");
const transaction_signing = @import("../transaction/signing.zig");

const Address = @import("../address.zig").Address;

pub const Error = std.mem.Allocator.Error || rlp.Error || transaction_signing.SenderRecoveryError || error{
    InvalidTransactionEnvelope,
    InvalidTransactionFormat,
    UnsupportedTransactionType,
};

pub fn decodeRaw(allocator: std.mem.Allocator, bytes: []const u8) Error!Evm.Transaction {
    const sender = (try transaction_signing.recoverSender(allocator, bytes)).sender;
    const envelope = try transaction_envelope.decodeEnvelope(bytes);
    return switch (envelope) {
        .legacy => |legacy| decodeLegacy(allocator, legacy, sender),
        .typed => |typed| decodeTyped(allocator, typed, sender),
    };
}

fn decodeLegacy(allocator: std.mem.Allocator, bytes: []const u8, sender: Address) Error!Evm.Transaction {
    var cursor = rlp.Cursor.init(bytes);
    var fields = try cursor.nextList();
    try cursor.expectDone();

    const nonce = try fields.nextInt(u64);
    const gas_price = try fields.nextInt(u256);
    const gas_limit = try fields.nextInt(u64);
    const to = try nextTo(&fields);
    const value = try fields.nextInt(u256);
    const input = try fields.nextBytes();
    _ = try fields.nextInt(u256);
    _ = try fields.nextInt(u256);
    _ = try fields.nextInt(u256);
    try fields.expectDone();

    _ = allocator;
    return .{
        .kind = .legacy,
        .sender = sender,
        .nonce = nonce,
        .gas_limit = gas_limit,
        .to = to,
        .value = value,
        .input = input,
        .gas_price = gas_price,
    };
}

fn decodeTyped(allocator: std.mem.Allocator, typed: transaction_envelope.TypedEnvelope, sender: Address) Error!Evm.Transaction {
    var cursor = rlp.Cursor.init(typed.payload);
    var fields = try cursor.nextList();
    try cursor.expectDone();

    return switch (typed.type_id) {
        0x01 => decodeAccessList(allocator, &fields, sender),
        0x02 => decodeDynamicFee(allocator, &fields, sender),
        0x03 => decodeBlob(allocator, &fields, sender),
        transaction_envelope.set_code_transaction_type => decodeSetCode(allocator, &fields, sender),
        else => error.UnsupportedTransactionType,
    };
}

fn decodeAccessList(allocator: std.mem.Allocator, fields: *rlp.Cursor, sender: Address) Error!Evm.Transaction {
    _ = try fields.nextInt(u256);
    const nonce = try fields.nextInt(u64);
    const gas_price = try fields.nextInt(u256);
    const gas_limit = try fields.nextInt(u64);
    const to = try nextTo(fields);
    const value = try fields.nextInt(u256);
    const input = try fields.nextBytes();
    const access_list = try nextAccessList(allocator, fields);
    _ = try fields.nextInt(u256);
    _ = try fields.nextInt(u256);
    _ = try fields.nextInt(u256);
    try fields.expectDone();

    return .{
        .kind = .access_list,
        .sender = sender,
        .nonce = nonce,
        .gas_limit = gas_limit,
        .to = to,
        .value = value,
        .input = input,
        .gas_price = gas_price,
        .access_list = access_list,
    };
}

fn decodeDynamicFee(allocator: std.mem.Allocator, fields: *rlp.Cursor, sender: Address) Error!Evm.Transaction {
    _ = try fields.nextInt(u256);
    const nonce = try fields.nextInt(u64);
    const max_priority_fee_per_gas = try fields.nextInt(u256);
    const max_fee_per_gas = try fields.nextInt(u256);
    const gas_limit = try fields.nextInt(u64);
    const to = try nextTo(fields);
    const value = try fields.nextInt(u256);
    const input = try fields.nextBytes();
    const access_list = try nextAccessList(allocator, fields);
    _ = try fields.nextInt(u256);
    _ = try fields.nextInt(u256);
    _ = try fields.nextInt(u256);
    try fields.expectDone();

    return .{
        .kind = .dynamic_fee,
        .sender = sender,
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

fn decodeBlob(allocator: std.mem.Allocator, fields: *rlp.Cursor, sender: Address) Error!Evm.Transaction {
    _ = try fields.nextInt(u256);
    const nonce = try fields.nextInt(u64);
    const max_priority_fee_per_gas = try fields.nextInt(u256);
    const max_fee_per_gas = try fields.nextInt(u256);
    const gas_limit = try fields.nextInt(u64);
    const to = try nextTo(fields);
    const value = try fields.nextInt(u256);
    const input = try fields.nextBytes();
    const access_list = try nextAccessList(allocator, fields);
    const max_fee_per_blob_gas = try fields.nextInt(u256);
    const blob_hashes = try nextHashList(allocator, fields);
    _ = try fields.nextInt(u256);
    _ = try fields.nextInt(u256);
    _ = try fields.nextInt(u256);
    try fields.expectDone();

    return .{
        .kind = .blob,
        .sender = sender,
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

fn decodeSetCode(allocator: std.mem.Allocator, fields: *rlp.Cursor, sender: Address) Error!Evm.Transaction {
    _ = try fields.nextInt(u256);
    const nonce = try fields.nextInt(u64);
    const max_priority_fee_per_gas = try fields.nextInt(u256);
    const max_fee_per_gas = try fields.nextInt(u256);
    const gas_limit = try fields.nextInt(u64);
    const to = try nextTo(fields);
    const value = try fields.nextInt(u256);
    const input = try fields.nextBytes();
    const access_list = try nextAccessList(allocator, fields);
    const authorization_list = try nextAuthorizationList(allocator, fields);
    _ = try fields.nextInt(u256);
    _ = try fields.nextInt(u256);
    _ = try fields.nextInt(u256);
    try fields.expectDone();

    return .{
        .kind = .set_code,
        .sender = sender,
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
        20 => bytes[0..20].*,
        else => error.InvalidTransactionFormat,
    };
}

fn nextAccessList(allocator: std.mem.Allocator, fields: *rlp.Cursor) Error![]const transaction.AccessListEntry {
    var list = try fields.nextList();
    var entries: std.ArrayList(transaction.AccessListEntry) = .empty;
    errdefer entries.deinit(allocator);

    while (!list.isDone()) {
        var entry = try list.nextList();
        const entry_address = (try entry.nextBytesExact(20))[0..20].*;
        var keys_cursor = try entry.nextList();
        var keys: std.ArrayList(u256) = .empty;
        errdefer keys.deinit(allocator);
        while (!keys_cursor.isDone()) {
            keys.append(allocator, readWord(try keys_cursor.nextBytesExact(32))) catch |err| return err;
        }
        try keys_cursor.expectDone();
        try entry.expectDone();
        entries.append(allocator, .{
            .address = entry_address,
            .storage_keys = try keys.toOwnedSlice(allocator),
        }) catch |err| return err;
    }
    try list.expectDone();
    return entries.toOwnedSlice(allocator);
}

fn nextHashList(allocator: std.mem.Allocator, fields: *rlp.Cursor) Error![]const u256 {
    var list = try fields.nextList();
    var hashes: std.ArrayList(u256) = .empty;
    errdefer hashes.deinit(allocator);
    while (!list.isDone()) {
        hashes.append(allocator, readWord(try list.nextBytesExact(32))) catch |err| return err;
    }
    try list.expectDone();
    return hashes.toOwnedSlice(allocator);
}

const ParsedAuthorizationList = struct {
    entries: []const transaction.AuthorizationTuple,
    count: usize,
};

fn nextAuthorizationList(allocator: std.mem.Allocator, fields: *rlp.Cursor) Error!ParsedAuthorizationList {
    var list = try fields.nextList();
    var entries: std.ArrayList(transaction.AuthorizationTuple) = .empty;
    errdefer entries.deinit(allocator);
    var count: usize = 0;

    while (!list.isDone()) {
        count += 1;
        var tuple = try list.nextList();
        const chain_id = try tuple.nextInt(u256);
        const target = (try tuple.nextBytesExact(20))[0..20].*;
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
        entries.append(allocator, .{
            .chain_id = chain_id,
            .target = target,
            .signer = signer,
            .nonce = nonce,
            .y_parity = y_parity,
            .legacy_v = null,
            .r = r,
            .s = s,
        }) catch |err| return err;
    }
    try list.expectDone();
    return .{
        .entries = entries.toOwnedSlice(allocator) catch |err| return err,
        .count = count,
    };
}

fn readWord(bytes: []const u8) u256 {
    return std.mem.readInt(u256, bytes[0..32], .big);
}

test "raw stateless tx decoder parses EIP-155 legacy transaction" {
    const hex = "f86c098504a817c800825208943535353535353535353535353535353535353535880de0b6b3a76400008025a028ef61340bd939bc2195fe537567866003e1a15d3c71ff63e1590620aa636276a067cbe9d8997f761aecb703304b3800ccf555c9f3dc64214b297fb1966a3b6d83";
    var bytes: [hex.len / 2]u8 = undefined;
    _ = try std.fmt.hexToBytes(&bytes, hex);

    const tx = try decodeRaw(std.testing.allocator, &bytes);
    try std.testing.expectEqual(transaction.TxKind.legacy, tx.kind);
    try std.testing.expectEqual(@as(u64, 9), tx.nonce.?);
    try std.testing.expectEqual(@as(u64, 21_000), tx.gas_limit);
    try std.testing.expectEqual(@as(u256, 20_000_000_000), tx.gas_price);
    try std.testing.expectEqual(@as(u256, 1_000_000_000_000_000_000), tx.value);
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
    try tuple.list(tuple_fields.written());
    try list.list(tuple.written());

    var cursor = rlp.Cursor.init(list.written());
    const parsed = try nextAuthorizationList(allocator, &cursor);
    defer allocator.free(parsed.entries);
    try cursor.expectDone();

    try std.testing.expectEqual(@as(usize, 1), parsed.count);
    try std.testing.expectEqual(@as(usize, 0), parsed.entries.len);
}
