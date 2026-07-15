const std = @import("std");
const evmz = @import("../../evm.zig");

const Address = evmz.Address;
const Protocol = evmz.Evm.Protocol;
const transaction = evmz.transaction;

const PreparationReadProbe = struct {
    const Read = enum {
        account_summary,
        code,
    };

    summary: ?transaction.PreparationAccount = null,
    code_bytes: []const u8 = &.{},
    fail_account_summary: bool = false,
    fail_code: bool = false,
    reads: [4]Read = undefined,
    read_count: usize = 0,

    fn access(self: *PreparationReadProbe) transaction.PreparationStateAccess {
        return .{
            .ptr = self,
            .vtable = &vtable,
        };
    }

    fn resetReads(self: *PreparationReadProbe) void {
        self.read_count = 0;
    }

    fn expectReads(self: *const PreparationReadProbe, expected: []const Read) !void {
        try std.testing.expectEqualSlices(Read, expected, self.reads[0..self.read_count]);
    }

    fn record(self: *PreparationReadProbe, read: Read) void {
        self.reads[self.read_count] = read;
        self.read_count += 1;
    }

    const vtable = transaction.PreparationStateAccess.VTable{
        .accountSummary = accountSummary,
        .code = code,
    };

    fn accountSummary(ptr: *anyopaque, account_address: Address) !?transaction.PreparationAccount {
        _ = account_address;
        const self: *PreparationReadProbe = @ptrCast(@alignCast(ptr));
        self.record(.account_summary);
        if (self.fail_account_summary) return error.InvalidWitness;
        return self.summary;
    }

    fn code(ptr: *anyopaque, account_address: Address, expected_hash: [32]u8) ![]const u8 {
        _ = account_address;
        _ = expected_hash;
        const self: *PreparationReadProbe = @ptrCast(@alignCast(ptr));
        self.record(.code);
        if (self.fail_code) return error.InvalidWitness;
        return self.code_bytes;
    }
};

test "Amsterdam prepare rejects max transaction nonce before sender account read" {
    var probe = PreparationReadProbe{ .fail_account_summary = true };
    const result = try prepare(&probe, .{
        .sender = evmz.addr(0xaaaa),
        .nonce = std.math.maxInt(u64),
        .to = evmz.addr(0xbbbb),
        .gas_limit = 30_000,
        .gas_price = 1,
    }, .{});

    try std.testing.expectEqual(Protocol.Transaction.ValidationError.nonce_is_max, try rejected(result));
    try probe.expectReads(&.{});
}

test "Amsterdam prepare reads sender before post-account max fee rejection" {
    var probe = PreparationReadProbe{ .fail_account_summary = true };
    try std.testing.expectError(error.InvalidWitness, prepare(&probe, .{
        .kind = .dynamic_fee,
        .sender = evmz.addr(0xaaaa),
        .nonce = 0,
        .to = evmz.addr(0xbbbb),
        .gas_limit = 30_000,
        .max_fee_per_gas = 0,
        .max_priority_fee_per_gas = 0,
    }, .{ .base_fee = 1 }));
    try probe.expectReads(&.{.account_summary});
}

test "Amsterdam prepare reads sender code only after nonce and funds checks" {
    var probe = PreparationReadProbe{
        .summary = .{
            .nonce = 0,
            .balance = 30_000,
            .code_hash = [_]u8{0xaa} ** 32,
        },
        .fail_code = true,
    };

    const nonce_mismatch = try prepare(&probe, .{
        .sender = evmz.addr(0xaaaa),
        .nonce = 1,
        .to = evmz.addr(0xbbbb),
        .gas_limit = 30_000,
        .gas_price = 1,
    }, .{});
    try std.testing.expectEqual(Protocol.Transaction.ValidationError.nonce_mismatch, try rejected(nonce_mismatch));
    try probe.expectReads(&.{.account_summary});

    probe.resetReads();
    probe.summary.?.balance = 29_999;
    const insufficient_funds = try prepare(&probe, .{
        .sender = evmz.addr(0xaaaa),
        .nonce = 0,
        .to = evmz.addr(0xbbbb),
        .gas_limit = 30_000,
        .gas_price = 1,
    }, .{});
    try std.testing.expectEqual(Protocol.Transaction.ValidationError.insufficient_account_funds, try rejected(insufficient_funds));
    try probe.expectReads(&.{.account_summary});

    probe.resetReads();
    probe.summary.?.balance = 30_000;
    try std.testing.expectError(error.InvalidWitness, prepare(&probe, .{
        .sender = evmz.addr(0xaaaa),
        .nonce = 0,
        .to = evmz.addr(0xbbbb),
        .gas_limit = 30_000,
        .gas_price = 1,
    }, .{}));
    try probe.expectReads(&.{ .account_summary, .code });
}

test "Amsterdam prepare skips sender code read for canonical empty code hash" {
    var probe = PreparationReadProbe{
        .summary = .{
            .nonce = 0,
            .balance = 30_000,
            .code_hash = evmz.crypto.keccak256_empty,
        },
        .fail_code = true,
    };

    const result = try prepare(&probe, .{
        .sender = evmz.addr(0xaaaa),
        .nonce = 0,
        .to = evmz.addr(0xbbbb),
        .gas_limit = 30_000,
        .gas_price = 1,
    }, .{});

    switch (result) {
        .executable => {},
        .rejected => return error.UnexpectedRejection,
    }
    try probe.expectReads(&.{.account_summary});
}

test "prepare accepts delegation-shaped sender code only after EIP-7702 activates" {
    var delegation_code: [evmz.eth.eip7702.delegation_code_len]u8 = undefined;
    evmz.eip7702.writeDelegationCode(&delegation_code, evmz.addr(0xdddd));

    var probe = PreparationReadProbe{
        .summary = .{
            .nonce = 0,
            .balance = 30_000,
            .code_hash = evmz.crypto.keccak256(&delegation_code),
        },
        .code_bytes = &delegation_code,
    };
    const value = Protocol.Transaction.Value{
        .sender = evmz.addr(0xaaaa),
        .nonce = 0,
        .to = evmz.addr(0xbbbb),
        .gas_limit = 30_000,
        .gas_price = 1,
    };

    const cancun = try prepare(&probe, value, .{ .revision = .cancun });
    try std.testing.expectEqual(Protocol.Transaction.ValidationError.sender_not_eoa, try rejected(cancun));
    try probe.expectReads(&.{ .account_summary, .code });

    probe.resetReads();
    const prague = try prepare(&probe, value, .{ .revision = .prague });
    switch (prague) {
        .executable => {},
        .rejected => return error.UnexpectedRejection,
    }
    try probe.expectReads(&.{ .account_summary, .code });
}

fn prepare(
    probe: *PreparationReadProbe,
    value: Protocol.Transaction.Value,
    env_overrides: struct {
        revision: Protocol.Revision = .amsterdam,
        base_fee: u256 = 0,
    },
) !transaction.PrepareResult(Protocol) {
    return Protocol.Transaction.prepare(Protocol, .{
        .revision = env_overrides.revision,
        .tx = value,
        .env = .{
            .coinbase = evmz.addr(0xcccc),
            .gas_limit = 1_000_000,
            .base_fee = env_overrides.base_fee,
        },
        .state = probe.access(),
    });
}

fn rejected(result: transaction.PrepareResult(Protocol)) !Protocol.Transaction.ValidationError {
    return switch (result) {
        .rejected => |reason| reason,
        .executable => error.UnexpectedExecutableTransaction,
    };
}
