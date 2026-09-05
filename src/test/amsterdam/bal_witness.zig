const std = @import("std");
const evmz = @import("../../evm.zig");

const bal = evmz.eth.bal;
const block_stf = evmz.eth.block_stf;
const trie = evmz.eth.trie;

fn leafNode(allocator: std.mem.Allocator, key: []const u8, value: []const u8) ![]u8 {
    const path = try allocator.alloc(u8, key.len + 1);
    path[0] = 0x20;
    @memcpy(path[1..], key);

    var payload = evmz.rlp.Writer.alloc(allocator);
    defer payload.deinit();
    try payload.bytes(path);
    try payload.bytes(value);

    var out = evmz.rlp.Writer.alloc(allocator);
    errdefer out.deinit();
    try out.listPayload(payload.written());
    return try out.toOwnedSlice();
}

const RecordingPreparer = struct {
    called: bool = false,
    fail: bool = false,
    account_count: usize = 0,
    storage_slot_count: usize = 0,
    first_account: ?evmz.Address = null,

    fn service(self: *RecordingPreparer) evmz.ExecutionResourcePreparer {
        return .{ .ptr = self, .vtable = &.{ .prepare = prepare } };
    }

    fn prepare(ptr: *anyopaque, plan: evmz.ExecutionResourcePlan) !void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        self.called = true;
        self.account_count = plan.state.accounts.len;
        self.storage_slot_count = plan.state.storage_slots.len;
        self.first_account = if (plan.state.accounts.len == 0) null else plan.state.accounts[0];
        if (self.fail) return error.PreparationUnavailable;
    }
};

test "BlockSTF BAL state precheck without a claim is a no-op" {
    const result = try block_stf.Exact(.amsterdam).applyAssumeDecoded(std.testing.allocator, .{
        .env = .{ .gas_limit = 30_000_000 },
        .state_backend = try evmz.Backend.fromWitness(
            std.testing.allocator,
            trie.empty_root_hash,
            &.{},
            &.{},
        ),
        .transactions = &.{},
        .precheck_block_access_list_state = true,
        .root_checks = .{
            .payload_header = .{
                .state = trie.empty_root_hash,
                .receipts = trie.empty_root_hash,
            },
        },
    });

    try std.testing.expectEqual(block_stf.Status.valid, result.status);
}

test "BlockSTF BAL state precheck classifies a missing trie path as invalid witness" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const scratch = arena.allocator();

    // The state leaf authenticates, but its storage trie is not in the witness,
    // so the declared slot has no proven path.
    const account = evmz.addr(0x7928);
    const account_key = trie.hashedAddressKey(account);
    const account_value = try trie.accountValueFrom(scratch, .{ .storage_root = [_]u8{0xab} ** 32 });
    const state_node = try leafNode(scratch, &account_key, account_value);
    const nodes = [_][]const u8{state_node};

    const claim = [_]bal.AccountChanges{.{ .address = account, .storage_reads = &.{1} }};
    const encoded = try bal.encodeAlloc(std.testing.allocator, &claim);
    defer std.testing.allocator.free(encoded);

    const result = try block_stf.Exact(.amsterdam).applyAssumeDecoded(std.testing.allocator, .{
        .env = .{ .gas_limit = 30_000_000 },
        .state_backend = try evmz.Backend.fromWitness(
            std.testing.allocator,
            evmz.crypto.keccak256(state_node),
            &nodes,
            &.{},
        ),
        .transactions = &.{},
        .block_access_list = encoded,
        .precheck_block_access_list_state = true,
        .parent_blob_gas = .{
            .parent_excess_blob_gas = 0,
            .parent_blob_gas_used = 0,
            .parent_base_fee_per_gas = 7,
        },
        .root_checks = .{
            .payload_header = .{
                .state = trie.empty_root_hash,
                .receipts = trie.empty_root_hash,
            },
        },
    });

    try std.testing.expectEqual(block_stf.Status.invalid_witness, result.status);
}

test "BlockSTF forwards the validated BAL resource plan to a successful preparer" {
    const account = evmz.addr(0x7928);
    const claim = [_]bal.AccountChanges{.{
        .address = account,
        .storage_reads = &.{7},
    }};
    const encoded = try bal.encodeAlloc(std.testing.allocator, &claim);
    defer std.testing.allocator.free(encoded);

    var preparer = RecordingPreparer{};
    const result = try block_stf.Exact(.amsterdam).applyAssumeDecoded(std.testing.allocator, .{
        .env = .{ .gas_limit = 30_000_000 },
        .state_backend = try evmz.Backend.fromWitness(
            std.testing.allocator,
            trie.empty_root_hash,
            &.{},
            &.{},
        ),
        .execution_resource_preparer = preparer.service(),
        .transactions = &.{},
        .block_access_list = encoded,
        .parent_blob_gas = .{
            .parent_excess_blob_gas = 0,
            .parent_blob_gas_used = 0,
            .parent_base_fee_per_gas = 7,
        },
        .root_checks = .{
            .payload_header = .{
                .state = trie.empty_root_hash,
                .receipts = trie.empty_root_hash,
            },
        },
    });

    try std.testing.expect(preparer.called);
    try std.testing.expectEqual(@as(usize, 1), preparer.account_count);
    try std.testing.expectEqual(@as(usize, 1), preparer.storage_slot_count);
    try std.testing.expectEqual(account, preparer.first_account.?);
    try std.testing.expectEqual(block_stf.Status.block_access_list_mismatch, result.status);
}

test "BlockSTF resource preparation failure falls back to lazy execution" {
    var preparer = RecordingPreparer{ .fail = true };
    const result = try block_stf.Exact(.amsterdam).applyAssumeDecoded(std.testing.allocator, .{
        .env = .{ .gas_limit = 30_000_000 },
        .state_backend = try evmz.Backend.fromWitness(
            std.testing.allocator,
            trie.empty_root_hash,
            &.{},
            &.{},
        ),
        .execution_resource_preparer = preparer.service(),
        .transactions = &.{},
        .block_access_list = &.{0xc0},
        .parent_blob_gas = .{
            .parent_excess_blob_gas = 0,
            .parent_blob_gas_used = 0,
            .parent_base_fee_per_gas = 7,
        },
        .root_checks = .{
            .payload_header = .{
                .state = trie.empty_root_hash,
                .receipts = trie.empty_root_hash,
            },
        },
    });

    try std.testing.expect(preparer.called);
    try std.testing.expectEqual(@as(usize, 0), preparer.account_count);
    try std.testing.expectEqual(@as(usize, 0), preparer.storage_slot_count);
    try std.testing.expectEqual(block_stf.Status.valid, result.status);
}
