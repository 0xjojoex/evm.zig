//! Block-lifecycle hook vocabulary.
//!
//! The contexts a spec is handed at each block hook point, and the bounded
//! system-call lists it returns. Concrete chain folds live with their chain
//! code; this module holds only the values they exchange with BlockSTF.

const std = @import("std");

const Address = @import("../address.zig").Address;
const execution = @import("../execution.zig");

pub const BeforeBlockContext = struct {
    number: u64,
    timestamp: u64,
    parent_hash: ?[32]u8 = null,
    parent_beacon_block_root: ?[32]u8 = null,
};

pub const BlockHookInput = union(enum) {
    none,
    word: [32]u8,
    bytes: []const u8,

    pub fn slice(self: *const BlockHookInput) []const u8 {
        return switch (self.*) {
            .none => &.{},
            .word => |*word| word,
            .bytes => |bytes| bytes,
        };
    }
};

pub const BlockSystemCall = struct {
    sender: Address,
    recipient: Address,
    input: BlockHookInput = .none,
    gas: u64,
    state_gas: u64 = 0,
    require_code: bool = false,
};

pub const BlockSystemCalls = struct {
    pub const capacity = 4;

    items: [capacity]BlockSystemCall = undefined,
    len: usize = 0,

    pub fn append(self: *BlockSystemCalls, call: BlockSystemCall) void {
        std.debug.assert(self.len < capacity);
        self.items[self.len] = call;
        self.len += 1;
    }

    pub fn slice(self: *const BlockSystemCalls) []const BlockSystemCall {
        return self.items[0..self.len];
    }
};

pub const BeforeTransactionContext = struct {
    number: u64,
    timestamp: u64,
    transaction_index: u64,
};

pub const AfterTransactionContext = struct {
    number: u64,
    timestamp: u64,
    transaction_index: u64,
    status: execution.Status,
    gas_used: u64,
    cumulative_gas_used: u64,
    cumulative_block_gas: u64,
    cumulative_state_gas: u64,
};

pub const FinalizeBlockContext = struct {
    number: u64,
    timestamp: u64,
    transaction_count: u64,
    gas_used: u64,
    block_gas: u64,
    state_gas: u64,
};

pub const FinalizeSystemCall = struct {
    call: BlockSystemCall,
    output_prefix: u8,
};

pub const FinalizeSystemCalls = struct {
    pub const capacity = 4;

    items: [capacity]FinalizeSystemCall = undefined,
    len: usize = 0,

    pub fn append(self: *FinalizeSystemCalls, call: FinalizeSystemCall) void {
        std.debug.assert(self.len < capacity);
        self.items[self.len] = call;
        self.len += 1;
    }

    pub fn slice(self: *const FinalizeSystemCalls) []const FinalizeSystemCall {
        return self.items[0..self.len];
    }
};

test "block hook collections preserve insertion order" {
    const first_sender = Address.fromBytes([_]u8{0x11} ** 20);
    const first_recipient = Address.fromBytes([_]u8{0x22} ** 20);
    const second_sender = Address.fromBytes([_]u8{0x33} ** 20);
    const second_recipient = Address.fromBytes([_]u8{0x44} ** 20);
    var calls = BlockSystemCalls{};
    calls.append(.{ .sender = first_sender, .recipient = first_recipient, .gas = 7 });
    calls.append(.{ .sender = second_sender, .recipient = second_recipient, .gas = 11 });

    try std.testing.expectEqual(@as(usize, 2), calls.slice().len);
    try std.testing.expectEqual(first_sender, calls.slice()[0].sender);
    try std.testing.expectEqual(first_recipient, calls.slice()[0].recipient);
    try std.testing.expectEqual(second_sender, calls.slice()[1].sender);
    try std.testing.expectEqual(second_recipient, calls.slice()[1].recipient);
}
