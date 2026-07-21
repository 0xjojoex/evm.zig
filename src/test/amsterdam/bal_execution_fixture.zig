const evmz = @import("../../evm.zig");

const block_stf = evmz.eth.block_stf;

pub const coinbase = evmz.addr(0);
pub const sender = evmz.addr(0x1000);
pub const target = evmz.addr(0x2000);
pub const sender_start_balance: u256 = 1_000_000;
pub const transfer_value: u256 = 1;
pub const storage_slot: u256 = 2;

const target_code = [_]u8{
    0x36, // CALLDATASIZE
    0x15, // ISZERO
    0x60, 0x0b, // PUSH1 read
    0x57, // JUMPI
    0x60, 0x07, // PUSH1 7
    0x60, 0x02, // PUSH1 slot 2
    0x55, // SSTORE
    0x00, // STOP
    0x5b, // read: JUMPDEST
    0x60, 0x02, // PUSH1 slot 2
    0x54, // SLOAD
    0x5f, // PUSH0
    0x52, // MSTORE
    0x60, 0x20, // PUSH1 32
    0x5f, // PUSH0
    0xf3, // RETURN
};

pub const transactions = [_]block_stf.TransactionInput{
    block_stf.TransactionInput.initAssumeDecoded(.{
        .sender = sender,
        .nonce = 0,
        .gas_limit = 1_000_000,
        .to = target,
        .value = transfer_value,
        .input = &.{1},
    }, "bal-differential-write-tx"),
    block_stf.TransactionInput.initAssumeDecoded(.{
        .sender = sender,
        .nonce = 1,
        .gas_limit = 1_000_000,
        .to = target,
        .value = transfer_value,
    }, "bal-differential-read-tx"),
};

pub fn initState(store: *evmz.state.MemoryStore) !void {
    const sender_account = try store.getOrCreateAccount(sender);
    sender_account.balance = sender_start_balance;
    const target_account = try store.getOrCreateAccount(target);
    try target_account.setCode(&target_code);
}
