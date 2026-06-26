const std = @import("std");
const evmz = @import("../evm.zig");

const Address = evmz.Address;
const Executor = evmz.Executor;
const Interpreter = evmz.Interpreter;

/// EIP-4788 and EIP-2935 system caller address.
/// https://eips.ethereum.org/EIPS/eip-4788
/// https://eips.ethereum.org/EIPS/eip-2935
pub const system_address = evmz.addr(0xfffffffffffffffffffffffffffffffffffffffe);
/// EIP-4788 beacon block root history contract.
/// https://eips.ethereum.org/EIPS/eip-4788
pub const beacon_roots_address = evmz.addr(0x000f3df6d732807ef1319fb7b8bb8522d0beac02);
/// EIP-2935 historical block hash storage contract.
/// https://eips.ethereum.org/EIPS/eip-2935
pub const history_storage_address = evmz.addr(0x0000f90827f1c53a10cb7a02335b175320002935);
/// Gas limit used by EIP system calls.
pub const system_call_gas: u64 = 30_000_000;

/// Header fields needed by block-start system contract hooks.
pub const BlockHeader = struct {
    number: u64,
    timestamp: u64,
    parent_hash: ?[32]u8 = null,
    parent_beacon_block_root: ?[32]u8 = null,
};

/// Applies block-start system contract calls:
/// - EIP-4788 stores the parent beacon block root from Cancun onward.
/// - EIP-2935 stores the previous block hash from Prague onward.
pub fn applyBlockStart(executor: *Executor, header: BlockHeader) !void {
    if (executor.spec.isImpl(.cancun) and header.number > 0) {
        if (header.parent_beacon_block_root) |root| {
            try callSystemContract(executor, beacon_roots_address, &root);
        }
    }

    if (executor.spec.isImpl(.prague) and header.number > 0) {
        if (header.parent_hash) |hash| {
            try callSystemContract(executor, history_storage_address, &hash);
        }
    }
}

fn callSystemContract(executor: *Executor, recipient: Address, input: *const [32]u8) !void {
    const has_code = (try executor.getCode(recipient)).len != 0;
    const result = try executor.executeSystemCall(system_address, recipient, input, system_call_gas);
    if (has_code and result.status != .success) return error.SystemCallFailed;
}

test "block start calls Prague and Cancun system contracts" {
    var executor = Executor.init(std.testing.allocator, .{
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
    }, .prague);
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

    var history_account = try executor.getOrCreateAccount(history_storage_address);
    try history_account.setCode(std.testing.allocator, history_code);
    var beacon_account = try executor.getOrCreateAccount(beacon_roots_address);
    try beacon_account.setCode(std.testing.allocator, beacon_code);

    var parent_hash = [_]u8{0} ** 32;
    parent_hash[31] = 0xaa;
    var beacon_root = [_]u8{0} ** 32;
    beacon_root[31] = 0xbb;

    try applyBlockStart(&executor, .{
        .number = 1,
        .timestamp = 12,
        .parent_hash = parent_hash,
        .parent_beacon_block_root = beacon_root,
    });

    try std.testing.expectEqual(@as(u256, 0xaa), executor.getAccount(history_storage_address).?.getStorage(0));
    try std.testing.expectEqual(@as(u256, 12), executor.getAccount(beacon_roots_address).?.getStorage(12));
    try std.testing.expectEqual(@as(u256, 0xbb), executor.getAccount(beacon_roots_address).?.getStorage(8191 + 12));

    try std.testing.expectEqual(Interpreter.Status.success, (try executor.executeSystemCall(
        system_address,
        evmz.addr(0x1234),
        &parent_hash,
        system_call_gas,
    )).status);
}
