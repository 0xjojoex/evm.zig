//! Opcode-visible values for one EVM call tree.

const std = @import("std");

const Address = @import("../address.zig").Address;

pub const ChainEnvironment = struct {
    /// Required: a default would silently choose one family's chain identity.
    chain_id: u256,
};

pub const BlockEnvironment = struct {
    coinbase: Address = std.mem.zeroes(Address),
    number: u64 = 0,
    slot_number: u64 = 0,
    timestamp: u64 = 0,
    /// Opcode-visible block gas limit, not the message execution budget.
    gas_limit: u64 = 0,
    difficulty_or_prev_randao: u256 = 0,
    base_fee: u256 = 0,
    blob_base_fee: u256 = 0,
};

pub const TransactionEnvironment = struct {
    origin: Address,
    gas_price: u256 = 0,
    blob_hashes: []const u256 = &.{},
};

pub const ExecutionContext = struct {
    pub const Chain = ChainEnvironment;
    pub const Block = BlockEnvironment;
    pub const Transaction = TransactionEnvironment;

    chain: ChainEnvironment,
    block: BlockEnvironment = .{},
    transaction: TransactionEnvironment,

    pub fn eql(a: ExecutionContext, b: ExecutionContext) bool {
        var a_transaction = a.transaction;
        var b_transaction = b.transaction;
        a_transaction.blob_hashes = &.{};
        b_transaction.blob_hashes = &.{};

        return std.meta.eql(a.chain, b.chain) and
            std.meta.eql(a.block, b.block) and
            std.meta.eql(a_transaction, b_transaction) and
            std.mem.eql(u256, a.transaction.blob_hashes, b.transaction.blob_hashes);
    }
};

test "execution context equality compares borrowed blob values" {
    const a_hashes = [_]u256{ 41, 43 };
    var b_hashes = [_]u256{ 41, 43 };
    const a: ExecutionContext = .{
        .chain = .{ .chain_id = 7 },
        .transaction = .{ .origin = [_]u8{0x11} ** 20, .blob_hashes = &a_hashes },
    };
    var b = a;
    b.transaction.blob_hashes = &b_hashes;

    try std.testing.expect(a.eql(b));
    b_hashes[1] = 44;
    try std.testing.expect(!a.eql(b));
    b_hashes[1] = 43;
    b.chain.chain_id = 8;
    try std.testing.expect(!a.eql(b));
}
