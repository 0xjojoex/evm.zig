const std = @import("std");

const eth_spec = @import("../../eth/spec.zig");
const address = @import("../../address.zig");
const block_stf = @import("../../eth/block_stf.zig");
const smoke = @import("./v1_smoke.zig");
const ssz = @import("ssz");
const wire = @import("./v1.zig");

test "stateless wire v1 smoke validates and returns SSZ output" {
    const input_bytes = try smoke.smokeInputBytes(std.testing.allocator);
    defer std.testing.allocator.free(input_bytes);

    const native_result = try wire.validateStatelessResultBytes(std.testing.allocator, input_bytes);
    try std.testing.expectEqual(block_stf.Status.valid, native_result.status);

    const output_bytes = try wire.validateStatelessBytes(std.testing.allocator, input_bytes);
    defer std.testing.allocator.free(output_bytes);

    const result = try wire.StatelessValidationResult.decode(std.testing.allocator, output_bytes);
    try std.testing.expect(result.successful_validation);
    try std.testing.expectEqual(wire.ProtocolFork.paris, result.chain_config.active_fork.fork);

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
    input.new_payload_request.bellatrix.execution_payload.block_hash[0] ^= 1;
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
    input.new_payload_request.bellatrix.execution_payload.prev_randao = bytes;
    input.new_payload_request.bellatrix.execution_payload.base_fee_per_gas = bytes;

    const normalized = try wire.normalize(scratch, input);
    try std.testing.expectEqual((@as(u256, 0x01) << 248) | 0x02, normalized.block.prev_randao);
    try std.testing.expectEqual((@as(u256, 0x02) << 248) | 0x01, normalized.block.base_fee_per_gas);
}

test "stateless wire v1 decodes but does not trust public-key hints" {
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
    try std.testing.expectEqual(block_stf.Status.valid, result.status);
}

test "stateless wire v1 normalizes fork blob schedule metadata" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const scratch = arena.allocator();

    var input = try smoke.pragueSmokeInput(scratch, .{});
    input.chain_config.active_fork.blob_schedule = .{
        .target = 7,
        .max = 8,
        .base_fee_update_fraction = 123_456,
    };

    const normalized = try wire.normalize(scratch, input);
    const schedule = normalized.blob_schedule.?;
    try std.testing.expectEqual(@as(u64, 7), schedule.target);
    try std.testing.expectEqual(@as(u64, 8), schedule.max);
    try std.testing.expectEqual(@as(u256, 123_456), schedule.base_fee_update_fraction);
    try std.testing.expectEqual(eth_spec.prague.transaction.blob_schedule.?.gas_per_blob, schedule.gas_per_blob);
}

test "stateless wire v1 rejects a payload shape from another fork" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const scratch = arena.allocator();

    var input = try smoke.smokeInput(scratch);
    input.chain_config.active_fork.fork = .amsterdam;
    try std.testing.expectError(error.InvalidPayloadForFork, wire.normalize(scratch, input));
}

test "stateless wire v1 releases decoded ownership when chain validation fails" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var input = try smoke.smokeInput(arena.allocator());
    input.chain_config.active_fork.activation.timestamp = std.math.maxInt(u64);
    const encoded = try input.encodeSchemaPrefixed(std.testing.allocator);
    defer std.testing.allocator.free(encoded);

    try std.testing.expectError(
        error.InactiveForkConfig,
        wire.StatelessInput.decodeSchemaPrefixed(std.testing.allocator, encoded),
    );
}

test "stateless wire v1 exposes successful decode ownership cleanup" {
    const encoded = try smoke.smokeInputBytes(std.testing.allocator);
    defer std.testing.allocator.free(encoded);
    var decoded = try wire.StatelessInput.decodeSchemaPrefixed(std.testing.allocator, encoded);
    defer decoded.deinit(std.testing.allocator);

    try std.testing.expectEqual(wire.ProtocolFork.paris, decoded.chain_config.active_fork.fork);
}

test "stateless wire v1 rejects unknown schema ids" {
    var input_bytes = try smoke.smokeInputBytes(std.testing.allocator);
    defer std.testing.allocator.free(input_bytes);
    input_bytes[1] = 0x02;
    try std.testing.expectError(error.UnsupportedSchemaId, wire.StatelessInput.decodeSchemaPrefixed(std.testing.allocator, input_bytes));
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

    const input = try smoke.pragueSmokeInput(arena.allocator(), .{});
    var payload = switch (input.new_payload_request) {
        .electra_fulu => |request| request.execution_payload,
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
}

test "stateless wire v1 bounded fixed struct lists preserve valid bytes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const scratch = arena.allocator();

    var input = try smoke.pragueSmokeInput(scratch, .{});
    var request = switch (input.new_payload_request) {
        .electra_fulu => |value| value,
        else => unreachable,
    };
    const withdrawals = [_]wire.Withdrawal{std.mem.zeroes(wire.Withdrawal)};
    const deposits = [_]wire.DepositRequest{std.mem.zeroes(wire.DepositRequest)};
    const withdrawal_requests = [_]wire.WithdrawalRequest{std.mem.zeroes(wire.WithdrawalRequest)};
    const consolidations = [_]wire.ConsolidationRequest{std.mem.zeroes(wire.ConsolidationRequest)};
    request.execution_payload.v2.withdrawals = &withdrawals;
    request.execution_requests = .{
        .deposits = &deposits,
        .withdrawals = &withdrawal_requests,
        .consolidations = &consolidations,
    };
    input.new_payload_request = .{ .electra_fulu = request };

    const encoded = try input.encodeSchemaPrefixed(scratch);
    const decoded = try wire.StatelessInput.decodeSchemaPrefixed(scratch, encoded);
    const reencoded = try decoded.encodeSchemaPrefixed(scratch);
    try std.testing.expectEqualSlices(u8, encoded, reencoded);
}

test "stateless wire v1 decodes fork-specific payload request shapes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const scratch = arena.allocator();

    const input = try smoke.pragueSmokeInput(scratch, .{});
    const request_bytes = try input.new_payload_request.encode(scratch);

    const prague = try wire.NewPayloadRequest.decode(scratch, .prague, request_bytes);
    switch (prague) {
        .electra_fulu => {},
        else => return error.TestUnexpectedResult,
    }

    const osaka = try wire.NewPayloadRequest.decode(scratch, .osaka, request_bytes);
    switch (osaka) {
        .electra_fulu => {},
        else => return error.TestUnexpectedResult,
    }

    const electra = switch (input.new_payload_request) {
        .electra_fulu => |request| request,
        else => unreachable,
    };
    const amsterdam_request = wire.NewPayloadRequest{ .amsterdam = .{
        .execution_payload = .{
            .v3 = electra.execution_payload,
            .block_access_list = &.{},
            .slot_number = 1,
        },
        .versioned_hashes = electra.versioned_hashes,
        .parent_beacon_block_root = electra.parent_beacon_block_root,
        .execution_requests = electra.execution_requests,
    } };
    const amsterdam_bytes = try amsterdam_request.encode(scratch);
    const amsterdam = try wire.NewPayloadRequest.decode(scratch, .amsterdam, amsterdam_bytes);
    switch (amsterdam) {
        .amsterdam => {},
        else => return error.TestUnexpectedResult,
    }

    try std.testing.expectError(error.InvalidByteLength, wire.NewPayloadRequest.decode(scratch, .prague, &.{}));
    try std.testing.expectError(error.UnsupportedFork, wire.NewPayloadRequest.decode(scratch, .bpo1, request_bytes));
    try std.testing.expectError(error.UnsupportedFork, wire.NewPayloadRequest.decode(scratch, .bpo2, request_bytes));
    try std.testing.expectError(error.InvalidByteLength, wire.NewPayloadRequest.decode(scratch, .amsterdam, request_bytes));
}

test "stateless wire v1 rejects request claims not derived by BlockSTF" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const scratch = arena.allocator();

    const empty_input = try smoke.pragueSmokeInput(scratch, .{});
    const empty_bytes = try empty_input.encodeSchemaPrefixed(scratch);
    const empty_result = try wire.validateStatelessResultBytes(scratch, empty_bytes);
    try std.testing.expectEqual(block_stf.Status.valid, empty_result.status);

    const withdrawal_requests = [_]wire.WithdrawalRequest{.{
        .source_address = address.addr(0x7002),
        .validator_pubkey = [_]u8{0x11} ** 48,
        .amount = 1,
    }};
    const claimed_request_input = try smoke.pragueSmokeInput(scratch, .{
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
        const output_bytes = try wire.validateStatelessBytes(std.testing.allocator, input_bytes);
        defer std.testing.allocator.free(output_bytes);

        const result = try wire.StatelessValidationResult.decode(std.testing.allocator, output_bytes);
        try std.testing.expect(!result.successful_validation);
        try std.testing.expectEqualSlices(u8, &([_]u8{0} ** 32), &result.new_payload_request_root);
        try std.testing.expectEqual(@as(u64, 0), result.chain_config.chain_id);
        try std.testing.expectEqual(wire.ProtocolFork.frontier, result.chain_config.active_fork.fork);
    }
}

test "stateless wire v1 fork values match tests-zkevm v0.5" {
    try std.testing.expectEqual(wire.ProtocolFork.paris, try wire.ProtocolFork.fromInt(13));
    try std.testing.expectEqual(wire.ProtocolFork.amsterdam, try wire.ProtocolFork.fromInt(20));
    try std.testing.expectError(error.UnsupportedFork, wire.ProtocolFork.fromInt(24));
}

test "stateless wire v1 ChainConfig owns its enum and optional-list schema" {
    const configs = [_]wire.ChainConfig{
        .{
            .chain_id = 1,
            .active_fork = .{
                .fork = .paris,
                .activation = .{},
            },
        },
        .{
            .chain_id = 2,
            .active_fork = .{
                .fork = .amsterdam,
                .activation = .{
                    .block_number = 42,
                    .timestamp = 1_234,
                },
                .blob_schedule = .{
                    .target = 6,
                    .max = 9,
                    .base_fee_update_fraction = 500_771,
                },
            },
        },
    };

    for (configs) |config| {
        const encoded = try ssz.encodeAlloc(wire.ChainConfig.Ssz, std.testing.allocator, config);
        defer std.testing.allocator.free(encoded);
        try std.testing.expectEqualDeep(config, try wire.ChainConfig.Ssz.decode(encoded));
    }

    const encoded = try ssz.encodeAlloc(wire.ChainConfig.Ssz, std.testing.allocator, configs[0]);
    defer std.testing.allocator.free(encoded);
    std.mem.writeInt(u64, encoded[12..20], 24, .little);
    try std.testing.expectError(error.InvalidEnumValue, wire.ChainConfig.Ssz.decode(encoded));
}

fn expectOversizedExecutionRequestsRejected(requests: wire.ExecutionRequests) !void {
    const TestRequestsSsz = ssz.Container(wire.ExecutionRequests, .{
        .deposits = ssz.List(wire.DepositRequest, 8193),
        .withdrawals = ssz.List(wire.WithdrawalRequest, 17),
        .consolidations = ssz.List(wire.ConsolidationRequest, 3),
    });
    const encoded = try ssz.encodeAlloc(TestRequestsSsz, std.testing.allocator, requests);
    defer std.testing.allocator.free(encoded);

    var no_memory: [0]u8 = .{};
    var fixed = std.heap.FixedBufferAllocator.init(&no_memory);
    try std.testing.expectError(error.InvalidListLength, wire.ExecutionRequests.decode(fixed.allocator(), encoded));
}
