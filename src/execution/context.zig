//! Opcode-visible values for one EVM call tree.
//!
//! The `*Environment` suffix is reserved for the three structs below, so a name
//! ending in `Environment` always means "a slice of the opcode-visible context."
//! Everything a caller supplies about a block, including values no opcode reads,
//! is `transaction.Env`; `Env.executionContext` is the narrowing between them.

const std = @import("std");

const Address = @import("../address.zig").Address;

pub const ChainEnvironment = struct {
    /// Required: a default would silently choose one family's chain identity.
    chain_id: u256,
};

/// Spec `BlockEnvironment`, minus `block_hashes`: BLOCKHASH resolves through the
/// `BlockHashSource` capability rather than a value copied into every call tree.
pub const BlockEnvironment = struct {
    coinbase: Address = std.mem.zeroes(Address),
    number: u64 = 0,
    slot_number: u64 = 0,
    timestamp: u64 = 0,
    /// GASLIMIT. The block's limit, never a message or transaction gas budget.
    gas_limit: u64 = 0,
    /// PREVRANDAO post-merge; pre-merge callers place the block difficulty here.
    difficulty_or_prev_randao: u256 = 0,
    base_fee: u256 = 0,
    /// Blob gas price already derived from the block's excess blob gas.
    blob_base_fee: u256 = 0,
};

/// Spec `TransactionEnvironment`, narrowed to what opcodes read.
///
/// The spec's `gas` field is the top frame's budget, carried here by
/// `EvmExecutionRequest.gas`; access lists and authorizations are transaction
/// accounting and live in `TransactionScope`.
pub const TransactionEnvironment = struct {
    origin: Address,
    /// GASPRICE: the effective gas price, not the transaction's max fee.
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

    /// Borrowed fields compared by value, not by identity. Every slice field in
    /// this context must be listed here and handled in `eql`; the structural test
    /// below fails to compile when a new one is added without that.
    const value_compared_slices = [_][]const u8{"blob_hashes"};

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

test "every borrowed execution context field is compared by value" {
    // std.meta.eql compares a slice as `ptr == ptr and len == len`, so a slice
    // field left to it makes two value-identical contexts unequal, and the
    // executor rejects a reopened scope with ExecutionContextMismatch.
    inline for (.{ ChainEnvironment, BlockEnvironment, TransactionEnvironment }) |Environment| {
        inline for (std.meta.fields(Environment)) |field| {
            const info = @typeInfo(field.type);
            if (info != .pointer or info.pointer.size != .slice) continue;
            comptime var handled = false;
            inline for (ExecutionContext.value_compared_slices) |name| {
                if (comptime std.mem.eql(u8, name, field.name)) handled = true;
            }
            if (!handled) @compileError(
                "ExecutionContext.eql would compare " ++ @typeName(Environment) ++ "." ++
                    field.name ++ " by pointer identity; compare it by value in eql",
            );
        }
    }
}

test "execution context equality compares borrowed blob values" {
    const a_hashes = [_]u256{ 41, 43 };
    var b_hashes = [_]u256{ 41, 43 };
    const a: ExecutionContext = .{
        .chain = .{ .chain_id = 7 },
        .transaction = .{ .origin = Address.fromBytes([_]u8{0x11} ** 20), .blob_hashes = &a_hashes },
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
