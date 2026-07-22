const std = @import("std");
const evmz = @import("../evm.zig");

const Address = evmz.Address;
const Host = evmz.Host;
const Interpreter = evmz.interpreter;
const context_adapter = @import("context.zig");

pub const BeforeBlockContext = evmz.protocol.BeforeBlockContext;
pub const BeforeTransactionContext = evmz.protocol.BeforeTransactionContext;
pub const AfterTransactionContext = evmz.protocol.AfterTransactionContext;
pub const FinalizeBlockContext = evmz.protocol.FinalizeBlockContext;

/// Applies before-block system contract calls:
/// - EIP-4788 stores the parent beacon block root from Cancun onward.
/// - EIP-2935 stores the previous block hash from Prague onward.
pub fn applyBeforeBlock(block_policy: anytype, executor: anytype, tx_context: Host.TxContext, context: BeforeBlockContext) !void {
    const calls = block_policy.beforeBlock(executor.revision(), context);
    try applySystemCalls(executor, tx_context, &calls);
}

/// Execute a before-transaction batch inside the transaction program's outer
/// journal attempt. Each call keeps its own execution checkpoint, while any
/// later hook/payload/inclusion failure discards the complete attempt.
pub fn applyBeforeTransactionPrelude(
    block_policy: anytype,
    prelude: anytype,
    tx_context: Host.TxContext,
    context: BeforeTransactionContext,
) @TypeOf(prelude).Error!void {
    const calls = block_policy.beforeTransaction(try prelude.revision(), context);
    for (calls.slice()) |*call| {
        try callSystemContractInPrelude(
            prelude,
            tx_context,
            call.sender,
            call.recipient,
            call.input.slice(),
            call.gas,
            call.state_gas,
            call.require_code,
        );
    }
}

pub fn applyAfterTransaction(block_policy: anytype, executor: anytype, tx_context: Host.TxContext, context: AfterTransactionContext) !void {
    const calls = block_policy.afterTransaction(executor.revision(), context);
    try applySystemCalls(executor, tx_context, &calls);
}

pub fn applyFinalizeBlock(
    block_policy: anytype,
    executor: anytype,
    tx_context: Host.TxContext,
    allocator: std.mem.Allocator,
    context: FinalizeBlockContext,
) ![]const []const u8 {
    const calls = block_policy.finalizeBlock(executor.revision(), context);

    var out: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (out.items) |request| allocator.free(request);
        out.deinit(allocator);
    }
    try out.ensureTotalCapacity(allocator, calls.slice().len);
    if (calls.slice().len == 0) return try out.toOwnedSlice(allocator);

    var phase_start = try executor.snapshot();
    defer phase_start.deinit(executor.allocator);
    try executor.traceSnapshotLifecycle(.checkpoint, &phase_start);
    var phase_open = true;
    errdefer if (phase_open) {
        executor.traceSnapshotLifecycle(.revert, &phase_start) catch {};
        executor.restore(&phase_start) catch {};
    };

    for (calls.slice()) |*finalize_call| {
        const call = &finalize_call.call;
        const request = try callRequestSystemContract(
            executor,
            tx_context,
            allocator,
            call.sender,
            call.recipient,
            call.input.slice(),
            call.gas,
            call.state_gas,
            finalize_call.output_prefix,
            call.require_code,
        );
        if (request) |typed_request| out.appendAssumeCapacity(typed_request);
    }

    const owned = try out.toOwnedSlice(allocator);
    errdefer {
        for (owned) |request| allocator.free(request);
        allocator.free(owned);
    }
    try executor.traceSnapshotLifecycle(.commit, &phase_start);
    phase_open = false;
    return owned;
}

fn applySystemCalls(executor: anytype, tx_context: Host.TxContext, calls: *const evmz.protocol.BlockSystemCalls) !void {
    if (calls.slice().len == 0) return;

    var phase_start = try executor.snapshot();
    defer phase_start.deinit(executor.allocator);
    try executor.traceSnapshotLifecycle(.checkpoint, &phase_start);
    var phase_open = true;
    errdefer if (phase_open) {
        executor.traceSnapshotLifecycle(.revert, &phase_start) catch {};
        executor.restore(&phase_start) catch {};
    };

    for (calls.slice()) |*call| {
        try callSystemContract(
            executor,
            tx_context,
            call.sender,
            call.recipient,
            call.input.slice(),
            call.gas,
            call.state_gas,
            call.require_code,
        );
    }

    try executor.traceSnapshotLifecycle(.commit, &phase_start);
    phase_open = false;
}

fn callSystemContract(
    executor: anytype,
    tx_context: Host.TxContext,
    sender: Address,
    recipient: Address,
    input: []const u8,
    gas: u64,
    state_gas: u64,
    require_code: bool,
) !void {
    const has_code = (try executor.getCode(recipient)).len != 0;
    if (!has_code and require_code) return error.SystemCallFailed;
    const result = try executor.executeSystemCall(tx_context, sender, recipient, input, .{
        .regular_left = gas,
        .reservoir = state_gas,
    });
    if (has_code and result.status != .success) return error.SystemCallFailed;
}

fn callSystemContractInPrelude(
    prelude: anytype,
    tx_context: Host.TxContext,
    sender: Address,
    recipient: Address,
    input: []const u8,
    gas: u64,
    state_gas: u64,
    require_code: bool,
) @TypeOf(prelude).Error!void {
    const has_code = (try prelude.code(recipient)).len != 0;
    if (!has_code and require_code) return error.SystemCallFailed;

    const result = try prelude.executeRequest(.{
        .context = context_adapter.fromHost(tx_context),
        .message = .{ .call = .{
            .sender = sender,
            .recipient = recipient,
            .input = input,
        } },
        .gas = .{
            .regular_left = gas,
            .reservoir = state_gas,
        },
    });
    if (has_code and result.status != .success) return error.SystemCallFailed;
}

fn callRequestSystemContract(
    executor: anytype,
    tx_context: Host.TxContext,
    allocator: std.mem.Allocator,
    sender: Address,
    recipient: Address,
    input: []const u8,
    gas: u64,
    state_gas: u64,
    request_type: u8,
    require_code: bool,
) !?[]const u8 {
    const has_code = (try executor.getCode(recipient)).len != 0;
    if (!has_code and require_code) return error.SystemCallFailed;
    const result = try executor.executeSystemCall(tx_context, sender, recipient, input, .{
        .regular_left = gas,
        .reservoir = state_gas,
    });
    if (has_code and result.status != .success) return error.SystemCallFailed;
    if (!has_code or result.output_data.len == 0) return null;

    const request_len = std.math.add(usize, result.output_data.len, 1) catch return error.OutOfMemory;
    const request = try allocator.alloc(u8, request_len);
    request[0] = request_type;
    @memcpy(request[1..], result.output_data);
    return request;
}

test "before block calls Prague and Cancun system contracts" {
    const ethereum = evmz.eth;

    const Executor = evmz.Executor;
    var executor = Executor.init(std.testing.allocator, .{
        .revision = .prague,
    });
    defer executor.deinit();

    var history_code_buf: [83]u8 = undefined;
    const history_code = try std.fmt.hexToBytes(
        &history_code_buf,
        "3373fffffffffffffffffffffffffffffffffffffffe14604657602036036042575f35600143038111604257611fff81430311604257611fff9006545f5260205ff35b5f5ffd5b5f35611fff60014303065500",
    );
    var beacon_code_buf: [97]u8 = undefined;
    const beacon_code = try std.fmt.hexToBytes(
        &beacon_code_buf,
        "3373fffffffffffffffffffffffffffffffffffffffe14604d57602036146024575f5ffd5b5f35801560495762001fff810690815414603c575f5ffd5b62001fff01545f5260205ff35b5f5ffd5b62001fff42064281555f359062001fff015500",
    );

    try executor.state.setCode(ethereum.history_storage_address, history_code);
    try executor.state.setCode(ethereum.beacon_roots_address, beacon_code);

    var parent_hash = [_]u8{0} ** 32;
    parent_hash[31] = 0xaa;
    var beacon_root = [_]u8{0} ** 32;
    beacon_root[31] = 0xbb;

    const tx_context = testTxContext();
    const calls = evmz.Evm.block_policy.beforeBlock(.prague, .{
        .number = 1,
        .timestamp = 12,
        .parent_hash = parent_hash,
        .parent_beacon_block_root = beacon_root,
    });
    for (calls.slice()) |call| {
        try std.testing.expectEqualSlices(u8, &ethereum.system_address, &call.sender);
        try std.testing.expectEqual(@as(u64, 0), call.state_gas);
    }

    const amsterdam_calls = evmz.Evm.block_policy.beforeBlock(.amsterdam, .{
        .number = 1,
        .timestamp = 12,
        .parent_hash = parent_hash,
        .parent_beacon_block_root = beacon_root,
    });
    for (amsterdam_calls.slice()) |call| {
        try std.testing.expectEqual(ethereum.system_call_state_gas, call.state_gas);
    }

    try applyBeforeBlock(&evmz.Evm.block_policy, &executor, tx_context, .{
        .number = 1,
        .timestamp = 12,
        .parent_hash = parent_hash,
        .parent_beacon_block_root = beacon_root,
    });

    try std.testing.expectEqual(@as(u256, 0xaa), try executor.getStorage(ethereum.history_storage_address, 0));
    try std.testing.expectEqual(@as(u256, 12), try executor.getStorage(ethereum.beacon_roots_address, 12));
    try std.testing.expectEqual(@as(u256, 0xbb), try executor.getStorage(ethereum.beacon_roots_address, 8191 + 12));

    try std.testing.expectEqual(Interpreter.Status.success, (try executor.executeSystemCall(
        tx_context,
        ethereum.system_address,
        evmz.addr(0x1234),
        &parent_hash,
        .legacy(ethereum.system_call_gas),
    )).status);
}

test "Amsterdam block hook executes state growth from the system-call reservoir" {
    const ethereum = evmz.eth;
    const ReservoirBlock = struct {
        const recipient = evmz.addr(0x8037);

        fn beforeBlock(revision: ethereum.Revision, _: BeforeBlockContext) evmz.protocol.BlockSystemCalls {
            var calls = evmz.protocol.BlockSystemCalls{};
            if (revision.isImpl(.amsterdam)) {
                calls.append(.{
                    .sender = ethereum.system_address,
                    .recipient = recipient,
                    .gas = 20_000,
                    .state_gas = ethereum.transaction.amsterdam_storage_set_state_gas,
                    .require_code = true,
                });
            }
            return calls;
        }
    };
    const Family = evmz.eth.extend(.{
        .block = .{ .beforeBlock = ReservoirBlock.beforeBlock },
    });

    var executor = evmz.Executor.init(std.testing.allocator, .{ .revision = .amsterdam });
    defer executor.deinit();
    try executor.state.setCode(ReservoirBlock.recipient, &.{
        0x60, 0x01, // PUSH1 1
        0x5f, // PUSH0
        0x55, // SSTORE
        0x00, // STOP
    });

    try applyBeforeBlock(&Family.block_policy, &executor, testTxContext(), .{
        .number = 1,
        .timestamp = 12,
    });
    try std.testing.expectEqual(@as(u256, 1), try executor.getStorage(ReservoirBlock.recipient, 0));
}

test "finalize block copies successful system contract output into typed requests" {
    const ethereum = evmz.eth;

    const RequestBlock = struct {
        const recipient = evmz.addr(0x7002);

        pub fn finalizeBlock(revision: ethereum.Revision, _: FinalizeBlockContext) evmz.protocol.FinalizeSystemCalls {
            var calls = evmz.protocol.FinalizeSystemCalls{};
            if (revision.isImpl(.prague)) {
                calls.append(.{
                    .call = .{
                        .sender = ethereum.system_address,
                        .recipient = recipient,
                        .gas = ethereum.system_call_gas,
                    },
                    .output_prefix = 0x01,
                });
            }
            return calls;
        }
    };

    const Family = evmz.eth.extend(.{
        .block = .{ .finalizeBlock = RequestBlock.finalizeBlock },
    });
    const Executor = evmz.Executor;
    var executor = Executor.init(std.testing.allocator, .{
        .revision = .prague,
    });
    defer executor.deinit();

    const request_code = [_]u8{
        0x61, 0xaa, 0xbb, // PUSH2 0xaabb
        0x60, 0x00, // PUSH1 0
        0x52, // MSTORE
        0x60, 0x02, // PUSH1 2
        0x60, 0x1e, // PUSH1 30
        0xf3, // RETURN
    };
    try executor.state.setCode(RequestBlock.recipient, &request_code);

    const requests = try applyFinalizeBlock(&Family.block_policy, &executor, testTxContext(), std.testing.allocator, .{
        .number = 1,
        .timestamp = 12,
        .transaction_count = 0,
        .gas_used = 0,
        .block_gas = 0,
        .state_gas = 0,
    });
    defer {
        for (requests) |request| std.testing.allocator.free(request);
        std.testing.allocator.free(requests);
    }

    try std.testing.expectEqual(@as(usize, 1), requests.len);
    try std.testing.expectEqualSlices(u8, &.{ 0x01, 0xaa, 0xbb }, requests[0]);
}

test "finalize block rejects missing required system contract code" {
    const ethereum = evmz.eth;

    const RequiredBlock = struct {
        pub fn finalizeBlock(revision: ethereum.Revision, _: FinalizeBlockContext) evmz.protocol.FinalizeSystemCalls {
            var calls = evmz.protocol.FinalizeSystemCalls{};
            if (revision.isImpl(.prague)) {
                calls.append(.{
                    .call = .{
                        .sender = ethereum.system_address,
                        .recipient = evmz.addr(0x7002),
                        .gas = ethereum.system_call_gas,
                        .require_code = true,
                    },
                    .output_prefix = 0x01,
                });
            }
            return calls;
        }
    };

    const Family = evmz.eth.extend(.{
        .block = .{ .finalizeBlock = RequiredBlock.finalizeBlock },
    });
    const Executor = evmz.Executor;
    var executor = Executor.init(std.testing.allocator, .{
        .revision = .prague,
    });
    defer executor.deinit();

    try std.testing.expectError(error.SystemCallFailed, applyFinalizeBlock(&Family.block_policy, &executor, testTxContext(), std.testing.allocator, .{
        .number = 1,
        .timestamp = 12,
        .transaction_count = 0,
        .gas_used = 0,
        .block_gas = 0,
        .state_gas = 0,
    }));
}

fn testTxContext() Host.TxContext {
    return .{
        .chain_id = 1,
        .gas_price = 0,
        .origin = evmz.addr(0),
        .coinbase = evmz.addr(0),
        .number = 1,
        .timestamp = 12,
        .gas_limit = 0,
        .prev_randao = 0,
        .base_fee = 0,
        .blob_base_fee = 0,
        .blob_hashes = &.{},
    };
}
