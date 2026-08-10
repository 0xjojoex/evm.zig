const std = @import("std");

const address = @import("../../address.zig");
const block_stf = @import("../../eth/block_stf.zig");
const smoke = @import("./v1_smoke.zig");
const schema = @import("./schema.zig");
const ssz = @import("ssz");
const transaction_signing = @import("../../transaction/signing.zig");
const wire = @import("./v1.zig");

test "stateless wire v1 smoke validates and returns SSZ output" {
    const input_bytes = try smoke.smokeInputBytes(std.testing.allocator);
    defer std.testing.allocator.free(input_bytes);

    const native_result = try wire.validateStatelessResultBytes(std.testing.allocator, input_bytes);
    try std.testing.expectEqual(block_stf.Status.valid, native_result.status);

    const output_bytes = try wire.validateStatelessBytesReusable(std.testing.allocator, input_bytes);
    defer std.testing.allocator.free(output_bytes);

    const result = try wire.StatelessValidationResult.decode(std.testing.allocator, output_bytes);
    try std.testing.expect(result.successful_validation);
    try std.testing.expectEqual(@as(u64, 1), result.chain_config.chain_id);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const input = try wire.StatelessInput.decodeSchemaPrefixed(arena.allocator(), input_bytes);
    try std.testing.expectEqualSlices(u8, &(try input.new_payload_request.hashTreeRoot(arena.allocator())), &result.new_payload_request_root);
}

test "stateless wire v1 rejects a mutated payload block hash" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const scratch = arena.allocator();

    var input = try smoke.smokeInput(scratch);
    input.new_payload_request.amsterdam.execution_payload.v3.v2.v1.block_hash[0] ^= 1;
    const input_bytes = try input.encodeSchemaPrefixed(scratch);
    const result = try wire.validateStatelessResultBytes(scratch, input_bytes);
    try std.testing.expectEqual(block_stf.Status.block_hash_mismatch, result.status);
}

test "stateless wire v1 normalizes payload words with field-specific byte order" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const scratch = arena.allocator();

    var input = try smoke.smokeInput(scratch);
    var bytes = [_]u8{0} ** 32;
    bytes[0] = 0x01;
    bytes[31] = 0x02;
    input.new_payload_request.amsterdam.execution_payload.v3.v2.v1.prev_randao = bytes;
    input.new_payload_request.amsterdam.execution_payload.v3.v2.v1.base_fee_per_gas = bytes;

    const normalized = try wire.normalize(scratch, input);
    try std.testing.expectEqual((@as(u256, 0x01) << 248) | 0x02, normalized.block.prev_randao);
    try std.testing.expectEqual((@as(u256, 0x02) << 248) | 0x01, normalized.block.base_fee_per_gas);
}

test "stateless wire v1 decodes and authenticates public-key inputs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const scratch = arena.allocator();

    var input = try smoke.smokeInput(scratch);
    const hints = [_][65]u8{[_]u8{0x5a} ** 65};
    input.public_keys = &hints;
    const encoded = try input.encodeSchemaPrefixed(scratch);
    const decoded = try wire.StatelessInput.decodeSchemaPrefixed(scratch, encoded);
    try std.testing.expectEqual(@as(usize, 1), decoded.public_keys.len);

    const result = try wire.validateStatelessResultBytes(scratch, encoded);
    try std.testing.expectEqual(block_stf.Status.invalid_witness, result.status);
}

test "stateless wire v1 reuses parity-authenticated transaction decoding" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const scratch = arena.allocator();

    const hex = "f86c098504a817c800825208943535353535353535353535353535353535353535880de0b6b3a76400008025a028ef61340bd939bc2195fe537567866003e1a15d3c71ff63e1590620aa636276a067cbe9d8997f761aecb703304b3800ccf555c9f3dc64214b297fb1966a3b6d83";
    var encoded: [hex.len / 2]u8 = undefined;
    _ = try std.fmt.hexToBytes(&encoded, hex);
    const recovered = try transaction_signing.recoverSender(scratch, &encoded);

    var input = try smoke.smokeInput(scratch);
    const transactions = [_][]const u8{&encoded};
    const public_keys = [_][65]u8{recovered.public_key};
    input.new_payload_request.amsterdam.execution_payload.v3.v2.v1.transactions = &transactions;
    input.public_keys = &public_keys;

    const normalized = try wire.normalize(scratch, input);
    try std.testing.expectEqual(@as(usize, 1), normalized.block.transactions.len);
    try std.testing.expectEqualSlices(u8, &encoded, normalized.block.transactions[0].encoded);
    try std.testing.expectEqualSlices(u8, &recovered.sender, &normalized.block.transactions[0].tx.sender);

    var opposite_parity = encoded;
    try std.testing.expectEqual(@as(u8, 0x25), opposite_parity[43]);
    opposite_parity[43] = 0x26;
    const opposite_key = (try transaction_signing.recoverSender(scratch, &opposite_parity)).public_key;
    input.public_keys = &[_][65]u8{opposite_key};
    try std.testing.expectError(error.InvalidPublicKey, wire.normalize(scratch, input));
}

test "stateless wire v1 declares Amsterdam semantics at its type boundary" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const scratch = arena.allocator();

    const input = try smoke.amsterdamSmokeInput(scratch, .{});
    const normalized = try wire.normalize(scratch, input);
    try std.testing.expectEqual(.amsterdam, wire.revision);
    try std.testing.expect(normalized.blob_params == null);
}

test "stateless wire v1 validates chain configuration after decoding" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var input = try smoke.smokeInput(arena.allocator());
    input.chain_config.active_fork.activation.timestamp = std.math.maxInt(u64);
    const encoded = try input.encodeSchemaPrefixed(std.testing.allocator);
    defer std.testing.allocator.free(encoded);

    var decoded = try wire.StatelessInput.decodeSchemaPrefixed(std.testing.allocator, encoded);
    defer decoded.deinit(std.testing.allocator);
    try std.testing.expectError(
        error.InactiveForkConfig,
        wire.normalize(std.testing.allocator, decoded),
    );

    const output = try wire.validateStatelessBytesReusable(std.testing.allocator, encoded);
    defer std.testing.allocator.free(output);
    const result = try wire.StatelessValidationResult.decode(std.testing.allocator, output);
    const request_root = try input.new_payload_request.hashTreeRoot(std.testing.allocator);
    try std.testing.expectEqualSlices(u8, &request_root, &result.new_payload_request_root);
    try std.testing.expect(!result.successful_validation);
}

test "stateless wire v1 exposes successful decode ownership cleanup" {
    const encoded = try smoke.smokeInputBytes(std.testing.allocator);
    defer std.testing.allocator.free(encoded);
    var decoded = try wire.StatelessInput.decodeSchemaPrefixed(std.testing.allocator, encoded);
    defer decoded.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u64, 1), decoded.chain_config.chain_id);
}

test "stateless wire v1 rejects unknown schema ids" {
    var input_bytes = try smoke.smokeInputBytes(std.testing.allocator);
    defer std.testing.allocator.free(input_bytes);

    // Known fork, unimplemented payload revision.
    input_bytes[1] = 0x02;
    try std.testing.expectError(error.UnsupportedSchemaId, wire.StatelessInput.decodeSchemaPrefixed(std.testing.allocator, input_bytes));

    // Known fork this build does not decode, then a fork index that does not exist.
    input_bytes[0] = @intFromEnum(wire.ProtocolFork.osaka);
    input_bytes[1] = wire.schema_revision;
    try std.testing.expectError(error.UnsupportedFork, wire.StatelessInput.decodeSchemaPrefixed(std.testing.allocator, input_bytes));
    input_bytes[0] = 0xff;
    try std.testing.expectError(error.UnsupportedFork, wire.StatelessInput.decodeSchemaPrefixed(std.testing.allocator, input_bytes));

    try std.testing.expectError(error.MissingSchemaId, wire.StatelessInput.decodeSchemaPrefixed(std.testing.allocator, input_bytes[0..1]));
}

test "stateless wire v1 schema id packs fork index and revision" {
    try std.testing.expectEqual(@as(u16, 0x1501), wire.schema_id);
    try std.testing.expectEqual(wire.ProtocolFork.amsterdam, wire.schema_fork);
    try std.testing.expectEqual(wire.schema_id, schema.id(wire.schema_fork, wire.schema_revision));
    try std.testing.expectEqual(@as(u16, 0x0e01), schema.id(.paris, 0x01));
}

test "stateless wire v1 enforces witness resource bounds before execution" {
    const oversized_code = [_]u8{0} ** ((1 << 16) + 1);
    const codes = [_][]const u8{&oversized_code};
    const witness = wire.ExecutionWitness{ .codes = &codes };
    try std.testing.expectError(error.InvalidListLength, witness.encode(std.testing.allocator));

    const TestWitness = struct {
        state: []const []const u8,
        codes: []const []const u8,
        headers: []const []const u8,
    };
    const TestWitnessSsz = ssz.Container(TestWitness, .{
        .state = ssz.ListOf(ssz.ByteList(1 << 10), 1 << 22),
        .codes = ssz.ListOf(ssz.ByteList(1 << 16), 1 << 18),
        .headers = ssz.ListOf(ssz.ByteList(1 << 10), 257),
    });
    const headers = [_][]const u8{&.{}} ** 257;
    const encoded = try ssz.encodeAlloc(TestWitnessSsz, std.testing.allocator, .{
        .state = &.{},
        .codes = &.{},
        .headers = &headers,
    });
    defer std.testing.allocator.free(encoded);
    try std.testing.expectError(error.InvalidListLength, wire.ExecutionWitness.decode(std.testing.allocator, encoded));
}

test "stateless wire v1 rejects oversized withdrawals before allocation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const input = try smoke.amsterdamSmokeInput(arena.allocator(), .{});
    var payload = switch (input.new_payload_request) {
        .amsterdam => |request| request.execution_payload.v3,
        else => unreachable,
    };
    payload.v2.withdrawals = &.{};
    const valid = try payload.encode(std.testing.allocator);
    defer std.testing.allocator.free(valid);
    const encoded = try std.testing.allocator.alloc(u8, valid.len + 17 * ssz.encodedSize(wire.Withdrawal));
    defer std.testing.allocator.free(encoded);
    @memcpy(encoded[0..valid.len], valid);
    @memset(encoded[valid.len..], 0);

    var no_memory: [0]u8 = .{};
    var fixed = std.heap.FixedBufferAllocator.init(&no_memory);
    try std.testing.expectError(error.InvalidListLength, wire.ExecutionPayloadV3.decode(fixed.allocator(), encoded));
}

test "stateless wire v1 rejects oversized execution request families before allocation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const scratch = arena.allocator();

    const deposits = try scratch.alloc(wire.DepositRequest, 8193);
    @memset(deposits, std.mem.zeroes(wire.DepositRequest));
    try expectOversizedExecutionRequestsRejected(.{ .deposits = deposits });

    const withdrawals = try scratch.alloc(wire.WithdrawalRequest, 17);
    @memset(withdrawals, std.mem.zeroes(wire.WithdrawalRequest));
    try expectOversizedExecutionRequestsRejected(.{ .withdrawals = withdrawals });

    const consolidations = try scratch.alloc(wire.ConsolidationRequest, 3);
    @memset(consolidations, std.mem.zeroes(wire.ConsolidationRequest));
    try expectOversizedExecutionRequestsRejected(.{ .consolidations = consolidations });

    const builder_deposits = try scratch.alloc(wire.BuilderDepositRequest, 65);
    @memset(builder_deposits, std.mem.zeroes(wire.BuilderDepositRequest));
    try expectOversizedExecutionRequestsRejected(.{ .builder_deposits = builder_deposits });

    const builder_exits = try scratch.alloc(wire.BuilderExitRequest, 17);
    @memset(builder_exits, std.mem.zeroes(wire.BuilderExitRequest));
    try expectOversizedExecutionRequestsRejected(.{ .builder_exits = builder_exits });
}

test "stateless wire v1 bounded fixed struct lists preserve valid bytes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const scratch = arena.allocator();

    var input = try smoke.amsterdamSmokeInput(scratch, .{});
    var request = switch (input.new_payload_request) {
        .amsterdam => |value| value,
        else => unreachable,
    };
    const withdrawals = [_]wire.Withdrawal{std.mem.zeroes(wire.Withdrawal)};
    const deposits = [_]wire.DepositRequest{std.mem.zeroes(wire.DepositRequest)};
    const withdrawal_requests = [_]wire.WithdrawalRequest{std.mem.zeroes(wire.WithdrawalRequest)};
    const consolidations = [_]wire.ConsolidationRequest{std.mem.zeroes(wire.ConsolidationRequest)};
    const builder_deposits = [_]wire.BuilderDepositRequest{std.mem.zeroes(wire.BuilderDepositRequest)};
    const builder_exits = [_]wire.BuilderExitRequest{std.mem.zeroes(wire.BuilderExitRequest)};
    request.execution_payload.v3.v2.withdrawals = &withdrawals;
    request.execution_requests = .{
        .deposits = &deposits,
        .withdrawals = &withdrawal_requests,
        .consolidations = &consolidations,
        .builder_deposits = &builder_deposits,
        .builder_exits = &builder_exits,
    };
    input.new_payload_request = .{ .amsterdam = request };

    const encoded = try input.encodeSchemaPrefixed(scratch);
    const decoded = try wire.StatelessInput.decodeSchemaPrefixed(scratch, encoded);
    const reencoded = try decoded.encodeSchemaPrefixed(scratch);
    try std.testing.expectEqualSlices(u8, encoded, reencoded);
}

test "stateless wire v1 schema owns the Amsterdam payload request shape" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const scratch = arena.allocator();

    const input = try smoke.amsterdamSmokeInput(scratch, .{});
    const encoded = try input.encodeSchemaPrefixed(scratch);
    const decoded = try wire.StatelessInput.decodeSchemaPrefixed(scratch, encoded);
    switch (decoded.new_payload_request) {
        .amsterdam => {},
        else => return error.TestUnexpectedResult,
    }
}

test "stateless wire v1 rejects request claims not derived by BlockSTF" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const scratch = arena.allocator();

    const empty_input = try smoke.amsterdamSmokeInput(scratch, .{});
    const empty_bytes = try empty_input.encodeSchemaPrefixed(scratch);
    const empty_result = try wire.validateStatelessResultBytes(scratch, empty_bytes);
    try std.testing.expectEqual(block_stf.Status.valid, empty_result.status);

    const withdrawal_requests = [_]wire.WithdrawalRequest{.{
        .source_address = address.addr(0x7002),
        .validator_pubkey = [_]u8{0x11} ** 48,
        .amount = 1,
    }};
    const claimed_request_input = try smoke.amsterdamSmokeInput(scratch, .{
        .withdrawals = &withdrawal_requests,
    });
    const claimed_request_bytes = try claimed_request_input.encodeSchemaPrefixed(scratch);
    const claimed_request_result = try wire.validateStatelessResultBytes(scratch, claimed_request_bytes);
    try std.testing.expectEqual(block_stf.Status.requests_hash_mismatch, claimed_request_result.status);
}

test "stateless wire v1 returns failure result for malformed guest input" {
    const malformed_inputs = [_][]const u8{
        &.{},
        &.{0x00},
        &.{ 0x00, 0x02 },
    };

    for (malformed_inputs) |input_bytes| {
        const output_bytes = try wire.validateStatelessBytesReusable(std.testing.allocator, input_bytes);
        defer std.testing.allocator.free(output_bytes);

        const result = try wire.StatelessValidationResult.decode(std.testing.allocator, output_bytes);
        try std.testing.expect(!result.successful_validation);
        try std.testing.expectEqualSlices(u8, &([_]u8{0} ** 32), &result.new_payload_request_root);
        try std.testing.expectEqual(@as(u64, 0), result.chain_config.chain_id);
        try std.testing.expectEqual(@as(?u64, null), result.chain_config.active_fork.activation.block_number);
        try std.testing.expectEqual(@as(?u64, null), result.chain_config.active_fork.activation.timestamp);
    }
}

test "stateless wire v1 protocol fork values match tests-zkevm v0.6.2" {
    try std.testing.expectEqual(wire.ProtocolFork.paris, try wire.ProtocolFork.fromInt(0x0e));
    try std.testing.expectEqual(wire.ProtocolFork.amsterdam, try wire.ProtocolFork.fromInt(0x15));
    try std.testing.expectError(error.UnsupportedFork, wire.ProtocolFork.fromInt(0));
    try std.testing.expectError(error.UnsupportedFork, wire.ProtocolFork.fromInt(0x16));
}

test "stateless wire v1 ChainConfig owns its activation-only schema" {
    const configs = [_]wire.ChainConfig{
        .{
            .chain_id = 1,
            .active_fork = .{
                .activation = .{},
            },
        },
        .{
            .chain_id = 2,
            .active_fork = .{
                .activation = .{
                    .block_number = 42,
                    .timestamp = 1_234,
                },
            },
        },
    };

    for (configs) |config| {
        const encoded = try ssz.encodeAlloc(wire.ChainConfig.Ssz, std.testing.allocator, config);
        defer std.testing.allocator.free(encoded);
        try std.testing.expectEqualDeep(config, try wire.ChainConfig.Ssz.decode(encoded));
    }
}

fn expectOversizedExecutionRequestsRejected(requests: wire.ExecutionRequests) !void {
    const TestRequestsSsz = ssz.Container(wire.ExecutionRequests, .{
        .deposits = ssz.List(wire.DepositRequest, 8193),
        .withdrawals = ssz.List(wire.WithdrawalRequest, 17),
        .consolidations = ssz.List(wire.ConsolidationRequest, 3),
        .builder_deposits = ssz.List(wire.BuilderDepositRequest, 65),
        .builder_exits = ssz.List(wire.BuilderExitRequest, 17),
    });
    const encoded = try ssz.encodeAlloc(TestRequestsSsz, std.testing.allocator, requests);
    defer std.testing.allocator.free(encoded);

    var no_memory: [0]u8 = .{};
    var fixed = std.heap.FixedBufferAllocator.init(&no_memory);
    try std.testing.expectError(error.InvalidListLength, wire.ExecutionRequests.decode(fixed.allocator(), encoded));
}
