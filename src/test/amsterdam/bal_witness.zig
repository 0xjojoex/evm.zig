const std = @import("std");
const evmz = @import("../../evm.zig");

const bal = evmz.eth.bal;
const block_stf = evmz.eth.block_stf;
const trie = evmz.eth.trie;

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

test "BlockSTF BAL state precheck classifies a missing trie path as invalid witness" {
    const claim = [_]bal.AccountChanges{.{ .address = evmz.addr(0x7928) }};
    const encoded = try bal.encodeAlloc(std.testing.allocator, &claim);
    defer std.testing.allocator.free(encoded);

    const result = try block_stf.applyAssumeDecoded(std.testing.allocator, .{
        .revision = .amsterdam,
        .env = .{ .gas_limit = 30_000_000 },
        .state_backend = try evmz.state.Backend.fromWitness(
            std.testing.allocator,
            [_]u8{0xab} ** 32,
            &.{},
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
                .state = .fromHash(trie.empty_root_hash),
                .receipts = .fromHash(trie.empty_root_hash),
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
    const result = try block_stf.applyAssumeDecoded(std.testing.allocator, .{
        .revision = .amsterdam,
        .env = .{ .gas_limit = 30_000_000 },
        .state_backend = try evmz.state.Backend.fromWitness(
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
                .state = .fromHash(trie.empty_root_hash),
                .receipts = .fromHash(trie.empty_root_hash),
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
    const result = try block_stf.applyAssumeDecoded(std.testing.allocator, .{
        .revision = .amsterdam,
        .env = .{ .gas_limit = 30_000_000 },
        .state_backend = try evmz.state.Backend.fromWitness(
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
                .state = .fromHash(trie.empty_root_hash),
                .receipts = .fromHash(trie.empty_root_hash),
            },
        },
    });

    try std.testing.expect(preparer.called);
    try std.testing.expectEqual(@as(usize, 0), preparer.account_count);
    try std.testing.expectEqual(@as(usize, 0), preparer.storage_slot_count);
    try std.testing.expectEqual(block_stf.Status.valid, result.status);
}
