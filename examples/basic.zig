const std = @import("std");
const evmz = @import("evmz");

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    const sender = evmz.addr(0xaaaa);
    const contract = evmz.addr(0xbbbb);
    const gas_limit: u64 = 300_000;

    var memory = evmz.state.MemoryStore.init(allocator);
    defer memory.deinit();

    const sender_account = try memory.getOrCreateAccount(sender);
    sender_account.balance = 1_000_000;

    const contract_account = try memory.getOrCreateAccount(contract);
    try contract_account.setCode(&.{
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

    var executor = evmz.Evm.Executor.init(allocator, .{
        .revision = .latest,
        .state_reader = memory.reader(),
    });
    defer executor.deinit();

    var vm = evmz.Evm.init(&executor);
    const outcome = try vm.transact(.{
        .env = .{ .gas_limit = gas_limit },
        .tx = .{
            .sender = sender,
            .to = contract,
            .gas_limit = gas_limit,
        },
    });
    const executed = switch (outcome) {
        .executed => |value| value,
        .rejected => return error.ExampleTransactionRejected,
    };
    defer executed.discardIfCurrent();
    const execution = try executed.result();
    var diff = try executed.changeset();
    defer diff.deinit(allocator);
    const stored = storageValue(&diff, contract, 0);
    if (execution.status != .success) return error.ExampleTransactionFailed;
    if (stored != 42) return error.ExampleStorageMismatch;

    std.debug.print("status: {s}\n", .{@tagName(execution.status)});
    std.debug.print("gas used: {d}\n", .{execution.gas.used});
    std.debug.print("return: 0x", .{});
    printHex(execution.output);
    std.debug.print("\n", .{});
    std.debug.print("storage[0]: {d}\n", .{stored});
}

fn printHex(bytes: []const u8) void {
    for (bytes) |byte| {
        std.debug.print("{x:0>2}", .{byte});
    }
}

fn storageValue(diff: *const evmz.state.Changeset, address: evmz.Address, key: u256) u256 {
    for (diff.storage_writes.items) |write| {
        if (std.mem.eql(u8, &write.address, &address) and write.key == key) return write.value;
    }
    return 0;
}
