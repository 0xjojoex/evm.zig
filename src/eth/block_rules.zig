//! Pure Ethereum block body/header validity rules and consensus claim
//! comparisons.
//!
//! Every function here reads inputs and execution-derived outputs; none of
//! them execute anything or touch state. `block_stf` composes these rules
//! around the authoritative fold.

const std = @import("std");

const block_stf = @import("block_stf.zig");
const eth_header = @import("header.zig");
const trie = @import("trie.zig");
const uint256 = @import("../uint256.zig");
const Backend = @import("../backend.zig").Backend;
const Revision = @import("revision.zig").Revision;

const Claims = block_stf.Claims;
const ExecutionInput = block_stf.ExecutionInput;
const HeaderClaims = block_stf.HeaderClaims;
const HeaderHashClaim = block_stf.HeaderHashClaim;
const ParentHeaderContext = block_stf.ParentHeaderContext;
const Result = block_stf.Result;
const RootChecks = block_stf.RootChecks;
const Status = block_stf.Status;

pub fn blockBodyValid(
    comptime revision: Revision,
    comptime block_access_list: bool,
    input: ExecutionInput,
    claims: ?Claims,
) bool {
    // TODO: spec-icfy after moving block_stf out of eth
    const header_claims: HeaderClaims = if (claims) |claim_set| claim_set.header else .{};
    if (!revision.isImpl(.shanghai) and input.withdrawals.len != 0) return false;
    if (!revision.isImpl(.shanghai)) {
        if (claims) |claim_set| {
            if (claim_set.root_checks.reconstructed_header.withdrawals != null) return false;
        }
    }
    if (!revision.isImpl(.cancun)) {
        if (input.parent_blob_gas != null or
            header_claims.blob_gas_used != null or
            header_claims.excess_blob_gas != null)
        {
            return false;
        }
        if (input.block_header) |header| {
            if (header.parent_beacon_block_root != null) return false;
        }
        if (claims) |claim_set| {
            if (claim_set.header_hash) |claim| {
                if (claim.parent_beacon_block_root != null) return false;
            }
        }
    }
    if (!revision.isImpl(.prague) and header_claims.requests_hash != null) return false;
    // Only payload and header fields decide validity. `bal_differential` is a
    // caller-owned diagnostic pointer: a mixed-fork verifier supplies it for
    // every block and reads `.not_run` back on the forks that have no list.
    if (!block_access_list and
        (input.block_access_list != null or
            header_claims.block_access_list_hash != null))
    {
        return false;
    }
    return true;
}

pub fn parentHeaderStatus(comptime revision: Revision, input: ExecutionInput) ?Status {
    if (!revision.isImpl(.merge) or input.env.number == 0) return null;

    const parent = input.parent_header orelse return .parent_header_mismatch;
    const current = input.block_header orelse return .parent_header_mismatch;
    const current_parent_hash = current.parent_hash orelse return .parent_hash_mismatch;
    if (!std.mem.eql(u8, &current_parent_hash, &parent.hash)) return .parent_hash_mismatch;
    if (current.number != input.env.number) return .block_number_mismatch;
    const expected_number = std.math.add(u64, parent.number, 1) catch return .block_number_mismatch;
    if (input.env.number != expected_number) return .block_number_mismatch;
    if (current.timestamp != input.env.timestamp) return .timestamp_mismatch;
    if (input.env.timestamp <= parent.timestamp) return .timestamp_mismatch;
    if (!gasLimitValid(input.env.gas_limit, parent.gas_limit)) return .gas_limit_mismatch;
    const expected_base_fee = expectedBaseFee(parent) orelse return .base_fee_mismatch;
    if (input.env.base_fee != expected_base_fee) return .base_fee_mismatch;
    return null;
}

const gas_limit_adjustment_factor: u64 = 1024;
const gas_limit_minimum: u64 = 5000;
const elasticity_multiplier: u64 = 2;
const base_fee_max_change_denominator: u256 = 8;

fn gasLimitValid(gas_limit: u64, parent_gas_limit: u64) bool {
    if (gas_limit < gas_limit_minimum) return false;
    const adjustment = parent_gas_limit / gas_limit_adjustment_factor;
    const upper: u128 = @as(u128, parent_gas_limit) + adjustment;
    const lower = parent_gas_limit - adjustment;
    return @as(u128, gas_limit) < upper and gas_limit > lower;
}

fn expectedBaseFee(parent: ParentHeaderContext) ?u256 {
    const target = parent.gas_limit / elasticity_multiplier;
    if (target == 0) return null;
    if (parent.gas_used == target) return parent.base_fee_per_gas;

    const gas_delta = if (parent.gas_used > target)
        parent.gas_used - target
    else
        target - parent.gas_used;
    const fee_delta_product = uint256.checkedMul(parent.base_fee_per_gas, @as(u256, gas_delta)) orelse return null;
    const target_fee_delta = @divFloor(fee_delta_product, @as(u256, target));
    var base_fee_delta = @divFloor(target_fee_delta, base_fee_max_change_denominator);

    if (parent.gas_used > target) {
        base_fee_delta = @max(base_fee_delta, 1);
        return uint256.checkedAdd(parent.base_fee_per_gas, base_fee_delta);
    }
    if (base_fee_delta > parent.base_fee_per_gas) return null;
    return parent.base_fee_per_gas - base_fee_delta;
}

pub fn blockContextValid(comptime revision: Revision, input: ExecutionInput) bool {
    if (input.block_header) |header| {
        if (header.number != input.env.number or header.timestamp != input.env.timestamp) return false;
    }
    if (input.env.number == 0) return true;

    if (revision.isImpl(.cancun)) {
        const header = input.block_header orelse return false;
        if (header.parent_beacon_block_root == null) return false;
    }
    if (revision.isImpl(.prague)) {
        const header = input.block_header orelse return false;
        if (header.parent_hash == null) return false;
    }
    return true;
}

pub fn reconstructHeaderHash(
    comptime revision: Revision,
    allocator: std.mem.Allocator,
    input: ExecutionInput,
    result: Result,
    claim: HeaderHashClaim,
) ![32]u8 {
    if (!revision.isImpl(.merge)) return error.InvalidHeaderReconstruction;
    if (input.block_header) |block_header| {
        if (block_header.number != input.env.number or block_header.timestamp != input.env.timestamp) {
            return error.InvalidHeaderReconstruction;
        }
        if (block_header.parent_hash) |parent_hash| {
            if (!std.mem.eql(u8, &parent_hash, &claim.parent_hash)) return error.InvalidHeaderReconstruction;
        }
        if (!optionalHashEqual(block_header.parent_beacon_block_root, claim.parent_beacon_block_root)) {
            return error.InvalidHeaderReconstruction;
        }
    }

    const excess_blob_gas: ?u64 = if (revision.isImpl(.cancun))
        std.math.cast(u64, result.excess_blob_gas orelse return error.InvalidHeaderReconstruction) orelse
            return error.InvalidHeaderReconstruction
    else
        null;
    const header = eth_header.ExecutionHeader{
        .parent_hash = claim.parent_hash,
        .coinbase = input.env.coinbase,
        .state_root = result.state_root,
        .transactions_root = result.transactions_root,
        .receipts_root = result.receipts_root,
        .logs_bloom = result.logs_bloom,
        .number = input.env.number,
        .gas_limit = input.env.gas_limit,
        .gas_used = result.block_gas_used,
        .timestamp = input.env.timestamp,
        .extra_data = claim.extra_data,
        .prev_randao = uint256.toBytes32(input.env.prev_randao),
        .base_fee_per_gas = if (revision.isImpl(.london)) input.env.base_fee else null,
        .withdrawals_root = if (revision.isImpl(.shanghai)) result.withdrawals_root else null,
        .blob_gas_used = if (revision.isImpl(.cancun)) result.blob_gas_used else null,
        .excess_blob_gas = excess_blob_gas,
        .parent_beacon_block_root = if (revision.isImpl(.cancun)) claim.parent_beacon_block_root else null,
        .requests_hash = if (revision.isImpl(.prague)) result.requests_hash else null,
        .block_access_list_hash = if (revision.isImpl(.amsterdam)) result.block_access_list_hash else null,
        .slot_number = if (revision.isImpl(.amsterdam)) input.env.slot_number else null,
    };
    return try header.hash(allocator, revision);
}

fn optionalHashEqual(lhs: ?[32]u8, rhs: ?[32]u8) bool {
    if (lhs == null or rhs == null) return lhs == null and rhs == null;
    return std.mem.eql(u8, &lhs.?, &rhs.?);
}

/// Comparison order defines rejection precedence. Every check pairs one
/// execution-derived root with one claim; the provenance is visible in the
/// claim path (`payload_header` vs `reconstructed_header`).
fn compareRoots(result: Result, checks: RootChecks) ?Status {
    if (!hashEqual(result.state_root, checks.payload_header.state)) return .state_root_mismatch;
    if (checks.reconstructed_header.transactions) |expected| {
        if (!hashEqual(result.transactions_root, expected)) return .transactions_root_mismatch;
    }
    if (!hashEqual(result.receipts_root, checks.payload_header.receipts)) return .receipts_root_mismatch;
    if (checks.reconstructed_header.withdrawals) |expected| {
        if (!hashEqual(result.withdrawals_root, expected)) return .withdrawals_root_mismatch;
    }
    return null;
}

/// Judge one completed execution against the full claim set. Sequential on
/// purpose: comparison order defines which mismatch a multiply-wrong block
/// reports.
pub fn compareBlock(
    result: Result,
    claims: Claims,
    block_access_list_mismatch: bool,
    block_hash_mismatch: bool,
) Status {
    std.debug.assert(result.status == .valid);
    if (compareRoots(result, claims.root_checks)) |status| return status;
    const header = claims.header;
    if (header.gas_used) |expected| {
        if (result.gas_used != expected) return .gas_used_mismatch;
    }
    if (header.block_gas_used) |expected| {
        if (result.block_gas_used != expected) return .block_gas_used_mismatch;
    }
    if (header.block_state_gas_used) |expected| {
        if (result.block_state_gas_used != expected) return .block_state_gas_used_mismatch;
    }
    if (header.logs_bloom) |expected| {
        if (!std.mem.eql(u8, &result.logs_bloom, &expected)) return .logs_bloom_mismatch;
    }
    if (header.blob_gas_used) |expected| {
        if (result.blob_gas_used != expected) return .blob_gas_used_mismatch;
    }
    if (header.excess_blob_gas) |expected| {
        if (result.excess_blob_gas == null or result.excess_blob_gas.? != expected) return .excess_blob_gas_mismatch;
    }
    if (header.requests_hash) |expected| {
        if (!hashEqual(result.requests_hash, expected)) return .requests_hash_mismatch;
    }
    if (block_access_list_mismatch) return .block_access_list_mismatch;
    if (header.block_access_list_hash) |expected| {
        if (!hashEqual(result.block_access_list_hash, expected)) return .block_access_list_hash_mismatch;
    }
    if (block_hash_mismatch) return .block_hash_mismatch;
    return .valid;
}

fn hashEqual(lhs: [32]u8, rhs: [32]u8) bool {
    return std.mem.eql(u8, &lhs, &rhs);
}

test "BlockSTF validates parent-derived header rules before execution" {
    const parent_hash = [_]u8{0x11} ** 32;
    var input = ExecutionInput{
        .env = .{ .number = 8, .timestamp = 11, .gas_limit = 10_000_000, .base_fee = 7 },
        .block_header = .{ .number = 8, .timestamp = 11, .parent_hash = parent_hash },
        .parent_header = .{
            .hash = parent_hash,
            .number = 7,
            .timestamp = 10,
            .gas_limit = 10_000_000,
            .gas_used = 5_000_000,
            .base_fee_per_gas = 7,
        },
        .state_backend = try Backend.fromWitness(std.testing.allocator, trie.empty_root_hash, &.{}, &.{}),
        .transactions = &.{},
    };
    try std.testing.expectEqual(@as(?Status, null), parentHeaderStatus(.merge, input));

    input.block_header.?.parent_hash = [_]u8{0x22} ** 32;
    try std.testing.expectEqual(Status.parent_hash_mismatch, parentHeaderStatus(.merge, input).?);
    input.block_header.?.parent_hash = parent_hash;

    input.env.number = 9;
    input.block_header.?.number = 9;
    try std.testing.expectEqual(Status.block_number_mismatch, parentHeaderStatus(.merge, input).?);
    input.env.number = 8;
    input.block_header.?.number = 8;

    input.env.timestamp = 10;
    input.block_header.?.timestamp = 10;
    try std.testing.expectEqual(Status.timestamp_mismatch, parentHeaderStatus(.merge, input).?);
    input.env.timestamp = 11;
    input.block_header.?.timestamp = 11;

    input.env.gas_limit = 10_000_000 + 10_000_000 / gas_limit_adjustment_factor;
    try std.testing.expectEqual(Status.gas_limit_mismatch, parentHeaderStatus(.merge, input).?);
    input.env.gas_limit = 10_000_000;

    input.env.base_fee = 8;
    try std.testing.expectEqual(Status.base_fee_mismatch, parentHeaderStatus(.merge, input).?);
}

test "BlockSTF derives EIP-1559 base fee from parent usage" {
    const parent = ParentHeaderContext{
        .hash = [_]u8{0} ** 32,
        .number = 0,
        .timestamp = 0,
        .gas_limit = 20_000_000,
        .gas_used = 20_000_000,
        .base_fee_per_gas = 1_000_000_000,
    };
    try std.testing.expectEqual(@as(u256, 1_125_000_000), expectedBaseFee(parent).?);

    var below_target = parent;
    below_target.gas_used = 0;
    try std.testing.expectEqual(@as(u256, 875_000_000), expectedBaseFee(below_target).?);
}
