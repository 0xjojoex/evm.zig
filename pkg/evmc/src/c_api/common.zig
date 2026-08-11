pub const evmc = @cImport({
    @cInclude("evmz/evmc_zig.h");
});
const std = @import("std");
const evmz = @import("evmz");

comptime {
    std.debug.assert(evmc.EVMC_ABI_VERSION == 18);
}

pub fn toEvmcAddress(addr: ?evmz.Address) evmc.evmc_address {
    return evmc.evmc_address{
        .bytes = if (addr) |a| a.bytes else evmz.addr(0).bytes,
    };
}

pub fn fromEvmcAddress(addr: evmc.evmc_address) evmz.Address {
    return .fromBytes(addr.bytes);
}

pub fn fromEvmcAddressWord(addr: evmc.evmc_address) evmz.AddressWord {
    return .fromAddress(fromEvmcAddress(addr));
}

pub fn fromEvmcBytes32(b: evmc.evmc_bytes32) u256 {
    return std.mem.readInt(u256, &b.bytes, .big);
}

pub const max_blob_hashes: usize = @intCast(evmz.eth.amsterdam.transaction.blob_schedule.?.max);

pub fn toEvmcBytes32(value: ?u256) evmc.evmc_bytes32 {
    var result = std.mem.zeroes(evmc.evmc_bytes32);
    std.mem.writeInt(u256, &result.bytes, value orelse 0, .big);
    return result;
}

pub fn callKindFromEvmc(kind: evmc.evmc_call_kind) !evmz.Host.CallKind {
    return switch (kind) {
        evmc.EVMC_CALL => .call,
        evmc.EVMC_DELEGATECALL => .delegatecall,
        evmc.EVMC_CALLCODE => .callcode,
        evmc.EVMC_CREATE => .create,
        evmc.EVMC_CREATE2 => .create2,
        else => error.InvalidCallKind,
    };
}

pub fn callKindToEvmc(kind: evmz.Host.CallKind) evmc.evmc_call_kind {
    return switch (kind) {
        .call, .staticcall => evmc.EVMC_CALL,
        .delegatecall => evmc.EVMC_DELEGATECALL,
        .callcode => evmc.EVMC_CALLCODE,
        .create => evmc.EVMC_CREATE,
        .create2 => evmc.EVMC_CREATE2,
    };
}

pub fn statusCodeFromOutcome(outcome: evmz.execution.ExecutionOutcome) evmc.evmc_status_code {
    return switch (outcome.status) {
        .success => evmc.EVMC_SUCCESS,
        .revert => evmc.EVMC_REVERT,
        .out_of_gas => evmc.EVMC_OUT_OF_GAS,
        .invalid => switch (outcome.cause) {
            .invalid_opcode => evmc.EVMC_INVALID_INSTRUCTION,
            .stack_underflow => evmc.EVMC_STACK_UNDERFLOW,
            .stack_overflow => evmc.EVMC_STACK_OVERFLOW,
            .invalid_jump => evmc.EVMC_BAD_JUMP_DESTINATION,
            .write_protection => evmc.EVMC_STATIC_MODE_VIOLATION,
            .return_data_out_of_bounds => evmc.EVMC_INVALID_MEMORY_ACCESS,
            .call_depth_exceeded => evmc.EVMC_CALL_DEPTH_EXCEEDED,
            .insufficient_balance => evmc.EVMC_INSUFFICIENT_BALANCE,
            .max_code_size_exceeded, .invalid_code => evmc.EVMC_CONTRACT_VALIDATION_FAILURE,
            .none,
            .revert,
            .out_of_gas,
            .invalid,
            .nonce_overflow,
            .contract_address_collision,
            .code_store_out_of_gas,
            => evmc.EVMC_FAILURE,
        },
    };
}

test "EVMC exports STATICCALL as CALL plus the static flag" {
    const expected: @TypeOf(callKindToEvmc(.staticcall)) = @intCast(evmc.EVMC_CALL);
    try std.testing.expectEqual(expected, callKindToEvmc(.staticcall));
}

test "EVMC status projection preserves precise execution causes" {
    const cases = [_]struct {
        outcome: evmz.execution.ExecutionOutcome,
        expected: evmc.evmc_status_code,
    }{
        .{ .outcome = .{ .status = .invalid, .cause = .invalid_opcode }, .expected = evmc.EVMC_INVALID_INSTRUCTION },
        .{ .outcome = .{ .status = .invalid, .cause = .stack_underflow }, .expected = evmc.EVMC_STACK_UNDERFLOW },
        .{ .outcome = .{ .status = .invalid, .cause = .stack_overflow }, .expected = evmc.EVMC_STACK_OVERFLOW },
        .{ .outcome = .{ .status = .invalid, .cause = .invalid_jump }, .expected = evmc.EVMC_BAD_JUMP_DESTINATION },
        .{ .outcome = .{ .status = .invalid, .cause = .write_protection }, .expected = evmc.EVMC_STATIC_MODE_VIOLATION },
        .{ .outcome = .{ .status = .invalid, .cause = .return_data_out_of_bounds }, .expected = evmc.EVMC_INVALID_MEMORY_ACCESS },
        .{ .outcome = .{ .status = .invalid, .cause = .call_depth_exceeded }, .expected = evmc.EVMC_CALL_DEPTH_EXCEEDED },
        .{ .outcome = .{ .status = .invalid, .cause = .insufficient_balance }, .expected = evmc.EVMC_INSUFFICIENT_BALANCE },
        .{ .outcome = .{ .status = .invalid, .cause = .invalid_code }, .expected = evmc.EVMC_CONTRACT_VALIDATION_FAILURE },
        // The final status owns fork-specific interpretation of this cause.
        .{ .outcome = .{ .status = .success, .cause = .code_store_out_of_gas }, .expected = evmc.EVMC_SUCCESS },
        .{ .outcome = .{ .status = .out_of_gas, .cause = .code_store_out_of_gas }, .expected = evmc.EVMC_OUT_OF_GAS },
    };
    for (cases) |case| {
        try std.testing.expectEqual(case.expected, statusCodeFromOutcome(case.outcome));
    }
}

pub fn evmcInputData(input_data: [*c]const u8, input_size: usize) ![]const u8 {
    if (input_size == 0) return &.{};
    if (input_data == null) return error.InvalidInputData;
    return input_data[0..input_size];
}

pub fn fromEvmcBlobHashes(tx_context: evmc.evmc_tx_context, scratch: []u256) ![]const u256 {
    if (tx_context.blob_hashes_count == 0) return &.{};
    if (tx_context.blob_hashes == null) return error.InvalidBlobHashes;
    if (tx_context.blob_hashes_count > scratch.len) return error.TooManyBlobHashes;

    const out = scratch[0..tx_context.blob_hashes_count];
    for (out, 0..) |*hash, i| {
        hash.* = fromEvmcBytes32(tx_context.blob_hashes[i]);
    }
    return out;
}

pub fn toEvmcBlobHashes(blob_hashes: []const u256, scratch: []evmc.evmc_bytes32) ![]const evmc.evmc_bytes32 {
    if (blob_hashes.len == 0) return &.{};
    if (blob_hashes.len > scratch.len) return error.TooManyBlobHashes;

    const out = scratch[0..blob_hashes.len];
    for (blob_hashes, out) |hash, *evmc_hash| {
        evmc_hash.* = toEvmcBytes32(hash);
    }
    return out;
}

pub fn fromEvmcTxContext(tx_context: evmc.evmc_tx_context, blob_hashes: []u256) !evmz.execution.ExecutionContext {
    return .{
        .chain = .{ .chain_id = fromEvmcBytes32(tx_context.chain_id) },
        .block = .{
            .base_fee = fromEvmcBytes32(tx_context.block_base_fee),
            .blob_base_fee = fromEvmcBytes32(tx_context.blob_base_fee),
            .coinbase = fromEvmcAddress(tx_context.block_coinbase),
            .gas_limit = try castNonNegative(u64, tx_context.block_gas_limit),
            .number = try castNonNegative(u64, tx_context.block_number),
            .slot_number = @intCast(tx_context.block_slot_number),
            .difficulty_or_prev_randao = fromEvmcBytes32(tx_context.block_prev_randao),
            .timestamp = try castNonNegative(u64, tx_context.block_timestamp),
        },
        .transaction = .{
            .blob_hashes = try fromEvmcBlobHashes(tx_context, blob_hashes),
            .gas_price = fromEvmcBytes32(tx_context.tx_gas_price),
            .origin = fromEvmcAddress(tx_context.tx_origin),
        },
    };
}

fn castNonNegative(comptime T: type, value: anytype) !T {
    return std.math.cast(T, value) orelse error.InvalidTxContext;
}
