//! EEST transaction fixtures exercise serialized ingress without an account state.
const std = @import("std");
const evmz = @import("evmz");
const fixtures = @import("fixtures");
const tx_validation = @import("tx_validation.zig");
const rlp = evmz.rlp;

pub fn runCase(allocator: std.mem.Allocator, fixture: std.json.Value) !void {
    const object = fixtures.asObject(fixture) orelse return error.MalformedFixture;
    try fixtures.rejectUnknownKeys(&object, &.{ "result", "txbytes", "_info" });
    const bytes = try fixtures.parseBytesFromValue(allocator, object.get("txbytes") orelse return error.MalformedFixture);
    defer allocator.free(bytes);
    var results = fixtures.asObject(object.get("result") orelse return error.MalformedFixture) orelse return error.MalformedFixture;
    if (results.count() == 0) return error.EmptyResults;
    var it = results.iterator();
    while (it.next()) |entry| {
        const revision = fixtures.parseStateFork(entry.key_ptr.*) orelse return error.UnsupportedFork;
        const expected = fixtures.asObject(entry.value_ptr.*) orelse return error.MalformedFixture;
        try fixtures.rejectUnknownKeys(&expected, &.{ "exception", "hash", "sender", "intrinsicGas" });
        switch (revision) {
            inline else => |exact| try runResult(exact, allocator, bytes, &expected),
        }
    }
}

fn runResult(
    comptime revision: evmz.eth.Revision,
    allocator: std.mem.Allocator,
    bytes: []const u8,
    expected: *const std.json.ObjectMap,
) !void {
    const spec = evmz.eth.specAt(revision);
    const expected_exception = if (expected.get("exception")) |value|
        if (value == .null) null else fixtures.jsonString(value) orelse return error.MalformedFixture
    else
        null;
    // Exercise production decoding before applying stricter admission policy.
    var decoded = evmz.transaction.raw.decodeRaw(allocator, bytes) catch |err| {
        if (err == error.OutOfMemory) return err;
        const actual = decodeExceptionName(revision, bytes, err) orelse return err;
        if (expected_exception) |exception| {
            if (tx_validation.exceptionNameMatches(actual, exception)) return;
            return error.ExceptionMismatch;
        }
        return error.UnexpectedDecodeRejection;
    };
    defer decoded.deinit(allocator);
    const tx = decoded.tx;
    const validation = evmz.transaction.validation.Runtime(spec){};
    // Transaction fixtures have no allocation or block environment. Supply
    // sufficient funds and the encoded nonce to isolate envelope policy.
    const validation_input = evmz.transaction.validation.ValidationInput{
        .kind = tx.kind,
        .chain_id = tx.chain_id,
        .is_create = tx.to == null,
        .is_self_transfer = if (tx.to) |to| to.eql(tx.sender) else false,
        .gas_limit = tx.gas_limit,
        .input = tx.input,
        .value = tx.value,
        .gas_price = tx.gas_price,
        .max_fee_per_gas = tx.max_fee_per_gas,
        .max_priority_fee_per_gas = tx.max_priority_fee_per_gas,
        .max_fee_per_blob_gas = tx.max_fee_per_blob_gas,
        .authorization_count = tx.authorization_count orelse tx.authorization_list.len,
        .access_list_counts = evmz.transaction.accessListCounts(tx.access_list),
        .blob_hashes = tx.blob_hashes,
        .tx_nonce = evmz.transaction.validation.classifyTransactionNonce(tx.nonce),
        .sender_nonce = std.math.cast(u64, tx.nonce orelse 0) orelse 0,
        .sender_balance = std.math.maxInt(u256),
    };
    const actual_exception: ?[]const u8 = if (tx.kind == .legacy and tx.chain_id != null and !revision.isImpl(.spurious_dragon))
        "TransactionException.INVALID_SIGNATURE_VRS"
    else if ((tx.nonce orelse 0) > std.math.maxInt(u64))
        "TransactionException.NONCE_OVERFLOW"
    else if (validation.validate(validation_input)) |err|
        tx_validation.eestExceptionName(err)
    else if (tx.kind == .legacy or tx.kind == .set_code)
        if (evmz.transaction.envelope.Exact(spec.transaction).classifyRawTransaction(bytes)) |err|
            tx_validation.rawEestExceptionName(err)
        else
            null
    else
        null;
    if (expected_exception) |exception| {
        if (actual_exception) |actual| {
            if (tx_validation.exceptionNameMatches(actual, exception)) return;
            return error.ExceptionMismatch;
        }
        return error.ExpectedRejection;
    }
    if (actual_exception != null) return error.UnexpectedValidationRejection;
    const hash = try fixtures.parseBytesFromValue(allocator, expected.get("hash") orelse return error.MalformedFixture);
    defer allocator.free(hash);
    if (!std.mem.eql(u8, &evmz.crypto.keccak256(bytes), hash)) return error.HashMismatch;
    const sender = try fixtures.parseAddressFromValue(expected.get("sender") orelse return error.MalformedFixture);
    if (!std.meta.eql(sender, tx.sender)) return error.SenderMismatch;
    const gas = try validation.gasPlan(validation_input);
    const intrinsic = try fixtures.parseU64FromValue(expected.get("intrinsicGas") orelse return error.MalformedFixture);
    if (gas.intrinsic_gas != intrinsic) return error.IntrinsicGasMismatch;
}

fn decodeExceptionName(comptime revision: evmz.eth.Revision, bytes: []const u8, err: anyerror) ?[]const u8 {
    if (bytes.len != 0 and bytes[0] == 0x04) {
        // Signature recovery precedes authorization policy in the raw decoder.
        if (err == error.InvalidSignature or err == error.UnsupportedLegacyV)
            return "TransactionException.INVALID_SIGNATURE_VRS";
        if (evmz.transaction.envelope.Exact(evmz.eth.specAt(revision).transaction).classifyRawTransaction(bytes)) |classified| {
            // A short tuple can shift a wide r/s value into the parity slot.
            // EEST names the tuple shape error before the incidental width error.
            if (classified == .type_4_invalid_authority_signature and !authorizationTupleShapeValid(bytes))
                return "TransactionException.TYPE_4_INVALID_AUTHORIZATION_FORMAT";
            return tx_validation.rawEestExceptionName(classified);
        }
    }
    // Diagnose RLP field context only after the production decoder rejected it.
    // This translates its generic parse errors into EEST's field-specific names.
    if (bytes.len != 0 and bytes[0] >= 0xc0) {
        if (legacyRlpException(bytes)) |name| return name;
    }
    return switch (err) {
        error.InvalidSignature, error.UnsupportedLegacyV => "TransactionException.INVALID_SIGNATURE_VRS",
        error.UnsupportedTransactionType => "TransactionException.TYPE_NOT_SUPPORTED",
        error.InvalidTransactionEnvelope => "TransactionException.RLP_INVALID_HEADER",
        error.EmptyTransaction => "TransactionException.RLP_ERROR_EOF",
        else => null,
    };
}

fn authorizationTupleShapeValid(bytes: []const u8) bool {
    var cursor = rlp.Cursor.init(bytes[1..]);
    var fields = cursor.nextList() catch return false;
    for (0..9) |_| _ = fields.next() catch return false;
    var list = fields.nextList() catch return false;
    while (!list.isDone()) {
        var tuple = list.nextList() catch return false;
        for (0..6) |_| _ = tuple.next() catch return false;
        tuple.expectDone() catch return false;
    }
    return true;
}

fn legacyRlpException(bytes: []const u8) ?[]const u8 {
    var cursor = rlp.Cursor.init(bytes);
    var fields = cursor.nextList() catch |err| return rlpException(err);
    cursor.expectDone() catch return "TransactionException.RLP_ERROR_SIZE";
    inline for (.{ "NONCE", "GASPRICE", "GASLIMIT", "TO", "VALUE", "DATA", "V", "R", "S" }, 0..) |field, index| {
        if (fields.isDone()) return "TransactionException.RLP_TOO_FEW_ELEMENTS";
        const item = fields.next() catch |err| {
            if (err == error.NonCanonicalLength or err == error.NonCanonicalSingleByte)
                return "TransactionException.RLP_LEADING_ZEROS_" ++ field ++ "_SIZE";
            return rlpException(err);
        };
        const invalid = switch (index) {
            6 => "TransactionException.INVALID_SIGNATURE_VRS",
            7 => "TransactionException.RLP_INVALID_SIGNATURE_R",
            8 => "TransactionException.RLP_INVALID_SIGNATURE_S",
            else => "TransactionException.RLP_INVALID_" ++ field,
        };
        if (index == 3 or index == 5) {
            const value = item.asBytes() catch return invalid;
            if (index == 3 and value.len != 0 and value.len != 20)
                return if (value.len < 20) "TransactionException.ADDRESS_TOO_SHORT" else "TransactionException.ADDRESS_TOO_LONG";
        } else {
            _ = item.asInt(if (index == 2) u64 else u256) catch |err| return switch (err) {
                error.NonCanonicalInteger => "TransactionException.RLP_LEADING_ZEROS_" ++ field,
                error.IntTooLarge => if (index == 4) "TransactionException.VALUE_OVERFLOW" else invalid,
                else => invalid,
            };
        }
    }
    return if (!fields.isDone()) "TransactionException.RLP_TOO_MANY_ELEMENTS" else null;
}

fn rlpException(err: rlp.ParseError) ?[]const u8 {
    return switch (err) {
        error.InputTooShort => "TransactionException.RLP_ERROR_EOF",
        error.NonCanonicalLength => "TransactionException.RLP_ERROR_SIZE_LEADING_ZEROS",
        error.ExpectedList => "TransactionException.RLP_INVALID_HEADER",
        error.TrailingBytes => "TransactionException.RLP_ERROR_SIZE",
        else => null,
    };
}

test "transaction fixtures require exact rejection" {
    const fixture =
        \\{"result":{"Prague":{"intrinsicGas":"0x00","exception":"TransactionException.INVALID_SIGNATURE_VRS"}},
        \\ "txbytes":"0xf841800a840100000094f89a03b42ea1412874da2cf1ae48956f73d0603901801b01a07fffffffffffffffffffffffffffffff5d576e7357a4501ddfe92f46681b20a1"}
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, fixture, .{});
    defer parsed.deinit();
    try runCase(std.testing.allocator, parsed.value);
    var result = parsed.value.object.getPtr("result").?.object.getPtr("Prague").?;
    result.object.getPtr("exception").?.* = .{ .string = "TransactionException.TYPE_4_INVALID_AUTHORIZATION_FORMAT" };
    try std.testing.expectError(error.ExceptionMismatch, runCase(std.testing.allocator, parsed.value));
}

test "raw decoding and BlockSTF reject authorization parity overflow" {
    const fixture =
        \\{"result":{"Prague":{"intrinsicGas":"0x00","exception":"TransactionException.TYPE_4_INVALID_AUTHORITY_SIGNATURE"}},
        \\ "txbytes":"0x04f88101808007830186a09400000000000000000000000000000000000000008080c0dddc0194000000000000000000000000000000000000000180820100010180a0c67bada22ec2c348bb27e2e5245ba33552253aae2f6584f5f38f31c80c260cf3a057c3f5ec591bbfc911e7d1bf5f9b0792bbbac8a33269cd97e86ad8f043b887c0"}
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, fixture, .{});
    defer parsed.deinit();
    const bytes = try fixtures.parseBytesFromValue(std.testing.allocator, parsed.value.object.get("txbytes").?);
    defer std.testing.allocator.free(bytes);
    try std.testing.expectError(error.IntTooLarge, evmz.transaction.raw.decodeRaw(std.testing.allocator, bytes));
    const batch = [_][]const u8{bytes};
    try std.testing.expectError(error.IntTooLarge, evmz.transaction.raw.decodeRawBatch(std.testing.allocator, &batch));
    const Latest = evmz.t.BlockStf(.latest).?;
    var memory = evmz.state.MemoryStore.init(std.testing.allocator);
    defer memory.deinit();
    try std.testing.expectError(error.IntTooLarge, Latest.produce(std.testing.allocator, .{
        .state_backend = evmz.Backend.fromMemoryStore(&memory),
        .transactions = &batch,
    }));
    try std.testing.expectError(error.IntTooLarge, Latest.apply(std.testing.allocator, .{
        .state_backend = evmz.Backend.fromMemoryStore(&memory),
        .transactions = &batch,
        .root_checks = .{ .payload_header = .{
            .state = evmz.eth.trie.empty_root_hash,
            .receipts = evmz.eth.trie.empty_root_hash,
        } },
    }));
    try runCase(std.testing.allocator, parsed.value);
}

test "transaction fixture compares hash sender and intrinsic gas" {
    const fixture =
        \\{"result":{"Prague":{"hash":"0x5be02ea9c507ca3d18ad9175fa92462ea91f8e015b36626a73be3477854be6bd",
        \\ "intrinsicGas":"0x5208","sender":"0xf6c3a9edc1afa0ad5b720e4d42e1437c43d3b3ff"}},
        \\ "txbytes":"0xf85f800a82753094c0f6dc9e5836f54caadbf59cc69346c508e1992b018026a05620163c1c60b8e79c827610d50d89a9dbff17febe1e604c539f902de467f68da010bb198840c4c29c297d4b36b0c6d057cfa5df4d5b01ef8ab4e3ae12c1ccde59"}
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, fixture, .{});
    defer parsed.deinit();
    try runCase(std.testing.allocator, parsed.value);
    const result = parsed.value.object.getPtr("result").?.object.getPtr("Prague").?;
    inline for (.{ "hash", "sender", "intrinsicGas" }, .{ "0x00", "0x0000000000000000000000000000000000000000", "0x01" }, .{ error.HashMismatch, error.SenderMismatch, error.IntrinsicGasMismatch }) |field, replacement, err| {
        const value = result.object.getPtr(field).?;
        const original = value.*;
        value.* = .{ .string = replacement };
        try std.testing.expectError(err, runCase(std.testing.allocator, parsed.value));
        value.* = original;
    }
    _ = result.object.swapRemove("sender");
    try std.testing.expectError(error.MalformedFixture, runCase(std.testing.allocator, parsed.value));
}

test "transaction diagnostics preserve raw signature failure before authorization policy" {
    const hex = "04e5018080078407270e0094f89a03b42ea1412874da2cf1ae48956f73d060390180c0c0220101";
    var bytes: [hex.len / 2]u8 = undefined;
    _ = try std.fmt.hexToBytes(&bytes, hex);
    var expected = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, "{\"exception\":\"TransactionException.INVALID_SIGNATURE_VRS\"}", .{});
    defer expected.deinit();
    try runResult(.latest, std.testing.allocator, &bytes, &expected.value.object);
}

test "transaction fixtures preserve self-transfer gas and accept typed envelopes" {
    const cases = .{
        .{
            .hex = "f860800a830186a0947e5f4552091a69125d5dfcb7b8c2659029395bdf808025a07c40b40f82d6974875ff5d57c1767cb6e5b34ff1617faeaa4081ec8b844b18f3a00ba6f032842a77951581bc7302eb801870896387d466231131ad8be6e995cbf1",
            .hash = "7b20b07240771a53515ac76da2d545ebba55004636849db9cbf02aa643478e92",
            .self_transfer = true,
        },
        .{
            .hex = "02f86301800a14830186a09400000000000000000000000000000000000010008080c080a0794a747474c631cf36a69ad7ec5a78e703dfc000a9d959ce0fd68b1040b9cac6a07ad6faca76839437d8ca6f68c7e67d5837adc38d396bccdbb89cdd07a3460780",
            .hash = "73d4f3bd04b0d88efbe4dba597defccfb65108193ca61bf50ba8005da790be50",
            .self_transfer = false,
        },
    };
    inline for (cases) |case| {
        var bytes: [case.hex.len / 2]u8 = undefined;
        _ = try std.fmt.hexToBytes(&bytes, case.hex);
        const gas = try (evmz.transaction.GasRuntime(evmz.eth.latest){}).intrinsicGasForTransaction(&.{}, .{
            .is_self_transfer = case.self_transfer,
        });
        const json = try std.fmt.allocPrint(std.testing.allocator,
            \\{{"hash":"0x{s}","sender":"0x7e5f4552091a69125d5dfcb7b8c2659029395bdf","intrinsicGas":"0x{x}"}}
        , .{ case.hash, gas });
        defer std.testing.allocator.free(json);
        var expected = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json, .{});
        defer expected.deinit();
        try runResult(.latest, std.testing.allocator, &bytes, &expected.value.object);
        if (case.self_transfer) {
            // EIP-155 protected v is invalid before Spurious Dragon.
            expected.value.object.clearRetainingCapacity();
            try expected.value.object.put(expected.arena.allocator(), "exception", .{
                .string = "TransactionException.INVALID_SIGNATURE_VRS",
            });
            try runResult(.frontier, std.testing.allocator, &bytes, &expected.value.object);
        }
    }
}

test "transaction admission rejects an invalid authority that block decoding skips" {
    const hex = "04f87f01800a14830186a09400000000000000000000000000000000000010008080c0dbda019400000000000000000000000000000000000000018080800101a0e3762158ac254bb765142a64ca246e52c7d7c0a3eca5c3364d66e54819be0b15a077bf1d5eb5ec66ebfe06f51d4e04d0735f6737b407d1d7ad81b04041159a30d1";
    var bytes: [hex.len / 2]u8 = undefined;
    _ = try std.fmt.hexToBytes(&bytes, hex);
    var decoded = try evmz.transaction.raw.decodeRaw(std.testing.allocator, &bytes);
    defer decoded.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), decoded.tx.authorization_list.len);
    try std.testing.expectEqual(@as(?usize, 1), decoded.tx.authorization_count);
    var expected = try std.json.parseFromSlice(std.json.Value, std.testing.allocator,
        \\{"exception":"TransactionException.TYPE_4_INVALID_AUTHORITY_SIGNATURE"}
    , .{});
    defer expected.deinit();
    try runResult(.latest, std.testing.allocator, &bytes, &expected.value.object);
}
