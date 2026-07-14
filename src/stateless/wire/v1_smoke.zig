//! Synthetic schema-v1 inputs used by native and guest smoke tests.

const std = @import("std");

const ExecutionHeader = @import("../../eth/header.zig").ExecutionHeader;
const address = @import("../../address.zig");
const block_stf = @import("../../eth/block_stf.zig");
const crypto = @import("../../crypto.zig");
const mpt = @import("../../mpt.zig");
const rlp = @import("rlp");
const t = @import("../../t.zig");
const wire = @import("./v1.zig");

const smoke_parent_state_root = t.hexBytes("d7f8974fb5ac78d9ac099b9ad5018bedc2ce0a72dad1827a1709da30580f0544");

pub fn smokeInput(allocator: std.mem.Allocator) wire.Error!wire.StatelessInput {
    const parent_header = try smokeParentHeader(allocator);
    errdefer allocator.free(parent_header);

    const parent_headers = try allocator.alloc([]const u8, 1);
    errdefer allocator.free(parent_headers);
    parent_headers[0] = parent_header;
    const parent_hash = crypto.keccak256(parent_header);

    return smokeInputWithHeaders(allocator, parent_headers, parent_hash);
}

fn smokeInputWithHeaders(
    allocator: std.mem.Allocator,
    parent_headers: []const []const u8,
    parent_hash: [32]u8,
) wire.Error!wire.StatelessInput {
    const block_hash = (ExecutionHeader{
        .parent_hash = parent_hash,
        .coinbase = address.addr(0),
        .state_root = smoke_parent_state_root,
        .transactions_root = mpt.empty_root_hash,
        .receipts_root = mpt.empty_root_hash,
        .logs_bloom = block_stf.empty_logs_bloom,
        .number = 1,
        .gas_limit = 30_000_000,
        .gas_used = 0,
        .timestamp = 1,
        .extra_data = &.{},
        .prev_randao = [_]u8{0x22} ** 32,
        .base_fee_per_gas = 0,
    }).hash(allocator, .merge) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidHeaderWitness,
    };
    return .{
        .new_payload_request = .{ .bellatrix = .{ .execution_payload = .{
            .parent_hash = parent_hash,
            .fee_recipient = address.addr(0),
            .state_root = smoke_parent_state_root,
            .receipts_root = mpt.empty_root_hash,
            .logs_bloom = block_stf.empty_logs_bloom,
            .prev_randao = [_]u8{0x22} ** 32,
            .block_number = 1,
            .gas_limit = 30_000_000,
            .gas_used = 0,
            .timestamp = 1,
            .base_fee_per_gas = [_]u8{0} ** 32,
            .block_hash = block_hash,
        } } },
        .witness = .{ .headers = parent_headers },
        .chain_config = .{
            .chain_id = 1,
            .active_fork = .{
                .fork = .paris,
                .activation = .{ .block_number = 0 },
            },
        },
    };
}

pub fn pragueSmokeInput(
    allocator: std.mem.Allocator,
    execution_requests: wire.ExecutionRequests,
) wire.Error!wire.StatelessInput {
    const parent_header = try smokeParentHeader(allocator);
    errdefer allocator.free(parent_header);

    const parent_headers = try allocator.alloc([]const u8, 1);
    errdefer allocator.free(parent_headers);
    parent_headers[0] = parent_header;
    const parent_hash = crypto.keccak256(parent_header);

    const block_hash = (ExecutionHeader{
        .parent_hash = parent_hash,
        .coinbase = address.addr(0),
        .state_root = smoke_parent_state_root,
        .transactions_root = mpt.empty_root_hash,
        .receipts_root = mpt.empty_root_hash,
        .logs_bloom = block_stf.empty_logs_bloom,
        .number = 0,
        .gas_limit = 30_000_000,
        .gas_used = 0,
        .timestamp = 1,
        .extra_data = &.{},
        .prev_randao = [_]u8{0x22} ** 32,
        .base_fee_per_gas = 0,
        .withdrawals_root = mpt.empty_root_hash,
        .blob_gas_used = 0,
        .excess_blob_gas = 0,
        .parent_beacon_block_root = [_]u8{0} ** 32,
        .requests_hash = block_stf.empty_requests_hash,
    }).hash(allocator, .prague) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidHeaderWitness,
    };

    return .{
        .new_payload_request = .{ .electra_fulu = .{
            .execution_payload = .{
                .v2 = .{
                    .v1 = .{
                        .parent_hash = parent_hash,
                        .fee_recipient = address.addr(0),
                        .state_root = smoke_parent_state_root,
                        .receipts_root = mpt.empty_root_hash,
                        .logs_bloom = block_stf.empty_logs_bloom,
                        .prev_randao = [_]u8{0x22} ** 32,
                        .block_number = 0,
                        .gas_limit = 30_000_000,
                        .gas_used = 0,
                        .timestamp = 1,
                        .base_fee_per_gas = [_]u8{0} ** 32,
                        .block_hash = block_hash,
                    },
                    .withdrawals = &.{},
                },
                .blob_gas_used = 0,
                .excess_blob_gas = 0,
            },
            .parent_beacon_block_root = [_]u8{0} ** 32,
            .execution_requests = execution_requests,
        } },
        .witness = .{ .headers = parent_headers },
        .chain_config = .{
            .chain_id = 1,
            .active_fork = .{
                .fork = .prague,
                .activation = .{ .block_number = 0 },
            },
        },
    };
}

fn smokeParentHeader(allocator: std.mem.Allocator) wire.Error![]u8 {
    var fields = rlp.Writer.alloc(allocator);
    defer fields.deinit();
    var header = rlp.Writer.alloc(allocator);
    defer header.deinit();

    const zero_hash = [_]u8{0} ** 32;
    const zero_address = [_]u8{0} ** 20;
    const zero_bloom = [_]u8{0} ** 256;
    const uncles_hash = t.hexBytes("1dcc4de8dec75d7aab85b567b6ccd41ad312451b948a7413f0a142fd40d49347");
    const empty_trie_root = t.hexBytes("56e81f171bcc55a6ff8345e692c0f86e5b48e01b996cadc001622fb5e363b421");
    const extra_data = t.hexBytes("11bbe8db4e347b4e8c937c1c8370e4b5ed33adb3db69cbdb7a38e1e50b1b82fa");

    try writeAllocatingRlp(fields.bytes(&zero_hash));
    try writeAllocatingRlp(fields.bytes(&uncles_hash));
    try writeAllocatingRlp(fields.bytes(&zero_address));
    try writeAllocatingRlp(fields.bytes(&smoke_parent_state_root));
    try writeAllocatingRlp(fields.bytes(&empty_trie_root));
    try writeAllocatingRlp(fields.bytes(&empty_trie_root));
    try writeAllocatingRlp(fields.bytes(&zero_bloom));
    try writeAllocatingRlp(fields.int(u64, 0));
    try writeAllocatingRlp(fields.int(u64, 0));
    try writeAllocatingRlp(fields.int(u64, 30_000_000));
    try writeAllocatingRlp(fields.int(u64, 0));
    try writeAllocatingRlp(fields.int(u64, 0));
    try writeAllocatingRlp(fields.bytes(&extra_data));
    try writeAllocatingRlp(fields.bytes(&zero_hash));
    try writeAllocatingRlp(fields.bytes(&([_]u8{0} ** 8)));
    try writeAllocatingRlp(fields.int(u256, 0));
    try writeAllocatingRlp(header.listPayload(fields.written()));

    return header.toOwnedSlice() catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.BorrowedWriter => unreachable,
    };
}

fn writeAllocatingRlp(result: rlp.Writer.Error!void) wire.Error!void {
    return result catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.NoSpaceLeft => unreachable,
    };
}

pub fn smokeInputBytes(allocator: std.mem.Allocator) wire.Error![]u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const input = try smokeInput(arena.allocator());
    return input.encodeSchemaPrefixed(allocator);
}
