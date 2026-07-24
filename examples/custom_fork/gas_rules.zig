//! Semantic function overrides: most spec fields are resolved `*const fn`
//! policies rather than enum-switched revisions. Replacing one swaps the
//! whole rule — here calldata becomes free while every other Cancun rule
//! stays untouched.

const std = @import("std");
const evmz = @import("evmz");
const harness = @import("harness.zig");

const rules = struct {
    fn freeCalldata(input: []const u8) ?u64 {
        _ = input;
        return 0;
    }
};

pub const free_calldata_cancun = evmz.eth.cancun.extend(.{
    .transaction = .{ .calldataGas = rules.freeCalldata },
});

const CustomVm = evmz.Vm(free_calldata_cancun);
const CancunVm = evmz.Vm(evmz.eth.cancun);

const sender = evmz.addr(0xaaaa);
const recipient = evmz.addr(0xbbbb);
/// 256 nonzero bytes: 16 gas each under stock Cancun, free under the fork.
const calldata = [_]u8{0xff} ** 256;

fn send(comptime VmType: type, allocator: std.mem.Allocator) !harness.Result {
    return harness.transact(VmType, allocator, .{
        .accounts = &.{.{ .address = sender, .balance = 1_000_000 }},
        .sender = sender,
        .to = recipient,
        .input = &calldata,
        .gas_limit = 100_000,
    });
}

pub fn run(allocator: std.mem.Allocator) !void {
    const custom = try send(CustomVm, allocator);
    defer custom.deinit(allocator);
    const stock = try send(CancunVm, allocator);
    defer stock.deinit(allocator);

    std.debug.print(
        "free-calldata cancun: gas {d} vs stock {d} for {d} calldata bytes\n",
        .{ custom.gas_used, stock.gas_used, calldata.len },
    );

    if (custom.status != .success or stock.status != .success) return error.ExampleTransferFailed;
    if (custom.gas_used >= stock.gas_used) return error.ExampleCalldataStillPriced;
}

test "overridden calldata pricing removes exactly the per-byte cost" {
    const custom = try send(CustomVm, std.testing.allocator);
    defer custom.deinit(std.testing.allocator);
    const stock = try send(CancunVm, std.testing.allocator);
    defer stock.deinit(std.testing.allocator);

    try std.testing.expectEqual(evmz.TxStatus.success, custom.status);
    try std.testing.expectEqual(evmz.TxStatus.success, stock.status);
    // Stock Cancun charges 16 gas per nonzero calldata byte; the fork none.
    try std.testing.expectEqual(@as(u64, 16 * calldata.len), stock.gas_used - custom.gas_used);
}
