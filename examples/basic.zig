const std = @import("std");
const evmz = @import("evmz");

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    const sender = evmz.addr(0xaaaa);
    const contract = evmz.addr(0xbbbb);
    const gas_limit: u64 = 100_000;

    var memory = evmz.state.MemoryStore.init(allocator);
    defer memory.deinit();

    const sender_account = try memory.getOrCreateAccount(sender);
    sender_account.balance = 1_000_000;

    const contract_account = try memory.getOrCreateAccount(contract);
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

    var vm = evmz.Vm.init(allocator, .{
        .spec = .latest,
        .state_reader = memory.reader(),
        .env = .{ .gas_limit = gas_limit },
    });
    defer vm.deinit();

    const result = try vm.transact(.{
        .sender = sender,
        .to = contract,
        .gas_limit = gas_limit,
    });
    var diff = try vm.changeset();
    defer diff.deinit(allocator);

    std.debug.print("status: {s}\n", .{@tagName(result.status)});
    std.debug.print("gas used: {d}\n", .{result.gas_used});
    std.debug.print("return: 0x", .{});
    printHex(result.output);
    std.debug.print("\n", .{});
    std.debug.print("storage[0]: {d}\n", .{storageValue(&diff, contract, 0)});
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
