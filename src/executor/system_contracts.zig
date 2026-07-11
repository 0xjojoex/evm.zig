const std = @import("std");
const evmz = @import("../evm.zig");

const Address = evmz.Address;
const Host = evmz.Host;
const Interpreter = evmz.interpreter;

/// Header fields needed by block-start system contract hooks.
pub const BlockHeader = evmz.protocol.interface.BlockStartContext;

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

fn callSystemContract(
    executor: anytype,
    tx_context: Host.TxContext,
    sender: Address,
    recipient: Address,
    input: *const [32]u8,
    gas: u64,
) !void {
    const has_code = (try executor.getCode(recipient)).len != 0;
    const result = try executor.executeSystemCall(tx_context, sender, recipient, input, gas);
    if (has_code and result.status != .success) return error.SystemCallFailed;
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

    var history_account = try executor.getOrCreateAccount(ethereum.history_storage_address);
    try history_account.setCode(std.testing.allocator, history_code);
    var beacon_account = try executor.getOrCreateAccount(ethereum.beacon_roots_address);
    try beacon_account.setCode(std.testing.allocator, beacon_code);

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
