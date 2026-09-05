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
    try std.testing.expectEqual(@as(u64, 1), result.chain_id);
    try std.testing.expectEqual(wire.schema_id, result.schema_id);

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

    var normalized = try wire.normalize(scratch, input);
    defer normalized.deinit(scratch);
    try std.testing.expectEqual((@as(u256, 0x01) << 248) | 0x02, normalized.input.block.prev_randao);
    try std.testing.expectEqual((@as(u256, 0x02) << 248) | 0x01, normalized.input.block.base_fee_per_gas);
}

test "stateless wire v1 derives the normalized requests hash" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const scratch = arena.allocator();

    var normalized = try wire.normalize(scratch, try smoke.smokeInput(scratch));
    defer normalized.deinit(scratch);
    const requests_hash = normalized.input.block.requests_hash orelse
        return error.TestUnexpectedResult;
    try std.testing.expectEqualSlices(
        u8,
        &block_stf.empty_requests_hash,
        &requests_hash,
    );
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

    var normalized = try wire.normalize(scratch, input);
    defer normalized.deinit(scratch);
    try std.testing.expectEqual(@as(usize, 1), normalized.input.block.transactions.len);
    try std.testing.expectEqualSlices(u8, &encoded, normalized.input.block.transactions[0].encoded);
    try std.testing.expectEqual(recovered.sender, normalized.input.block.transactions[0].tx.sender);

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
    var normalized = try wire.normalize(scratch, input);
    defer normalized.deinit(scratch);
    try std.testing.expectEqual(.amsterdam, wire.revision);
    try std.testing.expect(normalized.input.blob_params == null);
}

test "stateless wire v1 carries chain id without host-supplied fork configuration" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var input = try smoke.smokeInput(arena.allocator());
    input.chain_id = 42;
    const encoded = try input.encodeSchemaPrefixed(std.testing.allocator);
    defer std.testing.allocator.free(encoded);

    var decoded = try wire.StatelessInput.decodeSchemaPrefixed(std.testing.allocator, encoded);
    defer decoded.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u64, 42), decoded.chain_id);
    var normalized = try wire.normalize(std.testing.allocator, decoded);
    defer normalized.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u256, 42), normalized.chain_id);
}

test "stateless wire v1 exposes successful decode ownership cleanup" {
    const encoded = try smoke.smokeInputBytes(std.testing.allocator);
    defer std.testing.allocator.free(encoded);
    var decoded = try wire.StatelessInput.decodeSchemaPrefixed(std.testing.allocator, encoded);
    defer decoded.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u64, 1), decoded.chain_id);
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

test "stateless wire v1 accepts progressive withdrawals beyond the former local limit" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const scratch = arena.allocator();

    const input = try smoke.amsterdamSmokeInput(scratch, .{});
    var payload = switch (input.new_payload_request) {
        .amsterdam => |request| request.execution_payload.v3,
        else => unreachable,
    };
    const withdrawals = try scratch.alloc(wire.Withdrawal, 17);
    @memset(withdrawals, std.mem.zeroes(wire.Withdrawal));
    payload.v2.withdrawals = withdrawals;
    const encoded = try payload.encode(scratch);
    const decoded = try wire.ExecutionPayloadV3.decode(scratch, encoded);
    try std.testing.expectEqual(@as(usize, 17), decoded.v2.withdrawals.len);
}

test "stateless wire v1 accepts progressive request families beyond former local limits" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const scratch = arena.allocator();

    const builder_deposits = try scratch.alloc(wire.BuilderDepositRequest, 65);
    @memset(builder_deposits, std.mem.zeroes(wire.BuilderDepositRequest));
    const builder_exits = try scratch.alloc(wire.BuilderExitRequest, 17);
    @memset(builder_exits, std.mem.zeroes(wire.BuilderExitRequest));
    const requests = wire.ExecutionRequests{
        .builder_deposits = builder_deposits,
        .builder_exits = builder_exits,
    };
    const encoded = try requests.encode(scratch);
    const decoded = try wire.ExecutionRequests.decode(scratch, encoded);
    try std.testing.expectEqual(@as(usize, 65), decoded.builder_deposits.len);
    try std.testing.expectEqual(@as(usize, 17), decoded.builder_exits.len);
}

test "stateless wire v1 progressive collections preserve valid bytes" {
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
        try std.testing.expectEqual(@as(u64, 0), result.chain_id);
        try std.testing.expectEqual(@as(u16, 0), result.schema_id);
    }
}

test "stateless wire v1 rejects noncanonical SSZ before allocation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    var input = try smoke.smokeInput(scratch);
    input.witness.state = &.{"node"};
    const canonical = try input.encodeSchemaPrefixed(scratch);
    _ = try wire.StatelessInput.decodeSchemaPrefixed(scratch, canonical);

    // Exercise the guest's borrowed decoder and the public owning decoder.
    const Mutation = enum { top_level_gap, nested_gap, zero_state_offset, zero_header_offset };
    for (std.enums.values(Mutation)) |mutation| {
        const bytes = try scratch.alloc(u8, canonical.len + @as(usize, switch (mutation) {
            .top_level_gap, .nested_gap => 1,
            else => 0,
        }));
        @memcpy(bytes[0..canonical.len], canonical);
        switch (mutation) {
            .top_level_gap => {
                // Schema prefix, then request offset, witness offset, chain ID,
                // and public-key offset: the exact upstream #3531 mutation.
                for ([_]usize{ 2, 6, 18 }) |offset| {
                    const field = bytes[offset..][0..4];
                    std.mem.writeInt(u32, field, std.mem.readInt(u32, field, .little) + 1, .little);
                }
                bytes[canonical.len] = 0xff;
            },
            .nested_gap => {
                const witness = wire.schema_id_size + std.mem.readInt(u32, bytes[6..10], .little);
                const witness_end = wire.schema_id_size + std.mem.readInt(u32, bytes[18..22], .little);
                @memmove(bytes[witness_end + 1 ..], canonical[witness_end..]);
                bytes[witness_end] = 0xff;
                for ([_]usize{ 0, 4, 8 }) |offset| {
                    const field = bytes[witness + offset ..][0..4];
                    std.mem.writeInt(u32, field, std.mem.readInt(u32, field, .little) + 1, .little);
                }
                std.mem.writeInt(u32, bytes[18..22], @intCast(witness_end + 1 - wire.schema_id_size), .little);
            },
            .zero_state_offset, .zero_header_offset => {
                const witness = wire.schema_id_size + std.mem.readInt(u32, bytes[6..10], .little);
                // State is a progressive list; headers are a bounded list.
                const offset: usize = if (mutation == .zero_state_offset) 0 else 8;
                const list = witness + std.mem.readInt(u32, bytes[witness + offset ..][0..4], .little);
                std.mem.writeInt(u32, bytes[list..][0..4], 0, .little);
            },
        }
        try std.testing.expectError(error.InvalidFirstOffset, wire.StatelessInput.decodeSchemaPrefixed(std.testing.failing_allocator, bytes));
        const output = try wire.validateStatelessBytes(scratch, bytes);
        try std.testing.expectEqualSlices(u8, &([_]u8{0} ** 43), output);
    }
}

test "stateless wire v1 request root failure returns the complete sentinel" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    var input = try smoke.smokeInput(scratch);
    input.new_payload_request.amsterdam.execution_payload.v3.v2.v1.extra_data = &([_]u8{0} ** 33);

    // A typed input can exceed the SSZ bound and fail the actual root computation.
    try std.testing.expectError(error.InvalidListLength, input.new_payload_request.hashTreeRoot(scratch));
    const result = try wire.validateStateless(scratch, input);
    try std.testing.expectEqualSlices(u8, &([_]u8{0} ** 43), try result.encode(scratch));
}

test "stateless wire v1 validation failure preserves the input commitment" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    var input = try smoke.smokeInput(scratch);
    input.new_payload_request.amsterdam.execution_payload.v3.v2.v1.block_hash[0] ^= 1;
    const bytes = try input.encodeSchemaPrefixed(scratch);
    const output = try wire.validateStatelessBytes(scratch, bytes);
    const result = try wire.StatelessValidationResult.decode(scratch, output);
    try std.testing.expectEqualDeep(wire.StatelessValidationResult{
        .new_payload_request_root = try input.new_payload_request.hashTreeRoot(scratch),
        .successful_validation = false,
        .chain_id = input.chain_id,
        .schema_id = wire.schema_id,
    }, result);
}

test "stateless wire v1 protocol fork values match tests-zkevm v0.8.0" {
    try std.testing.expectEqual(wire.ProtocolFork.paris, try wire.ProtocolFork.fromInt(0x0e));
    try std.testing.expectEqual(wire.ProtocolFork.amsterdam, try wire.ProtocolFork.fromInt(0x15));
    try std.testing.expectError(error.UnsupportedFork, wire.ProtocolFork.fromInt(0));
    try std.testing.expectError(error.UnsupportedFork, wire.ProtocolFork.fromInt(0x16));
}

test "stateless wire v1 output exposes chain and full schema id" {
    const result = wire.StatelessValidationResult{
        .new_payload_request_root = [_]u8{0xaa} ** 32,
        .successful_validation = true,
        .chain_id = 1,
        .schema_id = wire.schema_id,
    };
    const encoded = try result.encode(std.testing.allocator);
    defer std.testing.allocator.free(encoded);
    try std.testing.expectEqual(@as(usize, 43), encoded.len);
    try std.testing.expectEqualDeep(result, try wire.StatelessValidationResult.decode(std.testing.allocator, encoded));
}
