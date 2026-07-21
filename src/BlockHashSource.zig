//! Canonical block-history lookup for the native BLOCKHASH opcode.
//!
//! Real chain callers pass this through `Executor.Init.block_hash_source`
//! before executing transactions for a block.
//! Implement it from canonical header/block-history data: return the ancestor
//! hash for the requested block number, or `null` when the hash is unavailable.

const BlockHashSource = @This();

ptr: *anyopaque,
vtable: *const VTable,

pub const VTable = struct {
    getBlockHash: *const fn (ptr: *anyopaque, number: u64) anyerror!?u256,
};

pub fn getBlockHash(self: BlockHashSource, number: u64) !?u256 {
    return self.vtable.getBlockHash(self.ptr, number);
}

/// Block-history capability safe for overlapping calls.
///
/// The source owns synchronization and the lifetime of any backing snapshot;
/// evmz only copies this lightweight handle between candidate lanes.
pub const Concurrent = struct {
    value: BlockHashSource,

    pub fn initAssumeSafe(value: BlockHashSource) Concurrent {
        return .{ .value = value };
    }

    pub fn source(self: Concurrent) BlockHashSource {
        return self.value;
    }
};
