const std = @import("std");
const evmz = @import("../evm.zig");

const Address = evmz.Address;
const Host = evmz.Host;
const Interpreter = evmz.interpreter;

/// Header fields needed by block-start system contract hooks.
pub const BlockHeader = evmz.protocol.interface.BlockStartContext;
pub const BlockEndContext = evmz.protocol.interface.BlockEndContext;

/// Applies block-start system contract calls:
/// - EIP-4788 stores the parent beacon block root from Cancun onward.
/// - EIP-2935 stores the previous block hash from Prague onward.
pub fn applyBlockStart(executor: anytype, tx_context: Host.TxContext, header: BlockHeader) !void {
    const Protocol = @TypeOf(executor.*).Protocol;
    const calls = Protocol.block.blockStartSystemCalls(executor.revision(), header);
    for (calls.slice()) |call| {
        try callSystemContract(executor, tx_context, call.sender, call.recipient, &call.input, call.gas);
    }
}

pub fn applyBlockEnd(
    executor: anytype,
    tx_context: Host.TxContext,
    allocator: std.mem.Allocator,
    context: BlockEndContext,
) ![]const []const u8 {
    const Protocol = @TypeOf(executor.*).Protocol;
    const calls = Protocol.block.blockEndSystemCalls(executor.revision(), context);

    var out: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (out.items) |request| allocator.free(request);
        out.deinit(allocator);
    }
    try out.ensureTotalCapacity(allocator, calls.slice().len);

    for (calls.slice()) |call| {
        const request = try callRequestSystemContract(
            executor,
            tx_context,
            allocator,
            call.sender,
            call.recipient,
            call.input,
            call.gas,
            call.request_type,
            call.require_code,
        );
        if (request) |typed_request| out.appendAssumeCapacity(typed_request);
    }

    return try out.toOwnedSlice(allocator);
}

fn callSystemContract(
    executor: anytype,
    tx_context: Host.TxContext,
    sender: Address,
    recipient: Address,
    input: []const u8,
    gas: u64,
) !void {
    const has_code = (try executor.getCode(recipient)).len != 0;
    const result = try executor.executeSystemCall(tx_context, sender, recipient, input, gas);
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
    request_type: u8,
    require_code: bool,
) !?[]const u8 {
    const has_code = (try executor.getCode(recipient)).len != 0;
    if (!has_code and require_code) return error.SystemCallFailed;
    const result = try executor.executeSystemCall(tx_context, sender, recipient, input, gas);
    if (has_code and result.status != .success) return error.SystemCallFailed;
    if (!has_code or result.output_data.len == 0) return null;

    const request_len = std.math.add(usize, result.output_data.len, 1) catch return error.OutOfMemory;
    const request = try allocator.alloc(u8, request_len);
    request[0] = request_type;
    @memcpy(request[1..], result.output_data);
    return request;
}

test "block start calls Prague and Cancun system contracts" {
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
    const calls = evmz.Evm.Protocol.block.blockStartSystemCalls(.prague, .{
        .number = 1,
        .timestamp = 12,
        .parent_hash = parent_hash,
        .parent_beacon_block_root = beacon_root,
    });
    for (calls.slice()) |call| {
        try std.testing.expectEqualSlices(u8, &ethereum.system_address, &call.sender);
    }

    try applyBlockStart(&executor, tx_context, .{
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
        ethereum.system_call_gas,
    )).status);
}

test "block end copies successful system contract output into typed requests" {
    const ethereum = evmz.eth;

    const RequestBlock = struct {
        const recipient = evmz.addr(0x7002);

        pub fn blockEndSystemCalls(revision: ethereum.Revision, _: BlockEndContext) evmz.protocol.interface.BlockEndSystemCalls {
            var calls = evmz.protocol.interface.BlockEndSystemCalls{};
            if (revision.isImpl(.prague)) {
                calls.append(.{
                    .sender = ethereum.system_address,
                    .recipient = recipient,
                    .gas = ethereum.system_call_gas,
                    .request_type = 0x01,
                });
            }
            return calls;
        }
    };

    const RequestProtocol = evmz.protocol.Protocol(evmz.eth.define(.{
        .block = .{ .blockEndSystemCalls = RequestBlock.blockEndSystemCalls },
    }), .all);
    const Executor = evmz.executor.Executor(RequestProtocol);
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

    const requests = try applyBlockEnd(&executor, testTxContext(), std.testing.allocator, .{
        .number = 1,
        .timestamp = 12,
    });
    defer {
        for (requests) |request| std.testing.allocator.free(request);
        std.testing.allocator.free(requests);
    }

    try std.testing.expectEqual(@as(usize, 1), requests.len);
    try std.testing.expectEqualSlices(u8, &.{ 0x01, 0xaa, 0xbb }, requests[0]);
}

test "block end rejects missing required system contract code" {
    const ethereum = evmz.eth;

    const RequiredBlock = struct {
        pub fn blockEndSystemCalls(revision: ethereum.Revision, _: BlockEndContext) evmz.protocol.interface.BlockEndSystemCalls {
            var calls = evmz.protocol.interface.BlockEndSystemCalls{};
            if (revision.isImpl(.prague)) {
                calls.append(.{
                    .sender = ethereum.system_address,
                    .recipient = evmz.addr(0x7002),
                    .gas = ethereum.system_call_gas,
                    .request_type = 0x01,
                    .require_code = true,
                });
            }
            return calls;
        }
    };

    const RequiredProtocol = evmz.protocol.Protocol(evmz.eth.define(.{
        .block = .{ .blockEndSystemCalls = RequiredBlock.blockEndSystemCalls },
    }), .all);
    const Executor = evmz.executor.Executor(RequiredProtocol);
    var executor = Executor.init(std.testing.allocator, .{
        .revision = .prague,
    });
    defer executor.deinit();

    try std.testing.expectError(error.SystemCallFailed, applyBlockEnd(&executor, testTxContext(), std.testing.allocator, .{
        .number = 1,
        .timestamp = 12,
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
