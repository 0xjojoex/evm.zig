const std = @import("std");
const evmz = @import("evmz");

const Executor = evmz.Executor;
const Host = evmz.Host;

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const sender = evmz.addr(0xaaaa);
    const contract = evmz.addr(0xbbbb);
    const gas_limit: u64 = 100_000;
    const tx_context = txContext(sender, gas_limit);

    var executor = Executor.init(allocator, .{
        .spec = .cancun,
    });
    defer executor.deinit();

    const sender_account = try executor.getOrCreateAccount(sender);
    sender_account.balance = 1_000_000;

    const contract_account = try executor.getOrCreateAccount(contract);
    try contract_account.setCode(allocator, &.{
        0x60, 0x2a, // PUSH1 42
        0x60, 0x00, // PUSH1 0
        0x55, // SSTORE
        0x60, 0x2a, // PUSH1 42
        0x60, 0x00, // PUSH1 0
        0x52, // MSTORE
        0x60, 0x20, // PUSH1 32
        0x60, 0x00, // PUSH1 0
        0xf3, // RETURN
    });

    try executor.beginTransaction(tx_context, sender, contract);
    var pre_execution = try executor.snapshot();
    defer pre_execution.deinit(allocator);

    const result = try executor.executeCallTransaction(sender, contract, &.{}, gas_limit, 0);
    if (Executor.executionRolledBack(result.status)) {
        try executor.restore(&pre_execution);
    } else {
        try executor.finalizeTransaction();
    }

    std.debug.print("status: {s}\n", .{@tagName(result.status)});
    std.debug.print("gas left: {d}\n", .{result.gas_left});
    std.debug.print("return: 0x", .{});
    printHex(result.output_data);
    std.debug.print("\n", .{});
    std.debug.print("storage[0]: {d}\n", .{executor.getAccount(contract).?.getStorage(0)});
}

fn txContext(origin: evmz.Address, gas_limit: u64) Host.TxContext {
    return .{
        .chain_id = 1,
        .gas_price = 0,
        .origin = origin,
        .coinbase = evmz.addr(0),
        .number = 0,
        .timestamp = 0,
        .gas_limit = gas_limit,
        .prev_randao = 0,
        .base_fee = 0,
        .blob_base_fee = 0,
        .blob_hashes = &.{},
    };
}

fn printHex(bytes: []const u8) void {
    for (bytes) |byte| {
        std.debug.print("{x:0>2}", .{byte});
    }
}
