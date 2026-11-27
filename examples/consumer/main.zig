//! The README's quick start, kept compiling.

const std = @import("std");
const evmz = @import("evmz");

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    // Use your own StateReader in production.
    var memory = evmz.state.MemoryStore.init(allocator);
    defer memory.deinit();

    var vm = evmz.Evm.init(allocator, .{
        .state = .{ .reader = memory.reader() },
    });
    defer vm.deinit();

    const execution = switch (try vm.transact(.{
        .env = .{ .gas_limit = 100_000 },
        .tx = .{
            .sender = evmz.addr(0xaaaa),
            .to = evmz.addr(0xbbbb),
            .gas_limit = 100_000,
        },
    })) {
        .executed => |value| value,
        .rejected => return error.TransactionRejected,
    };
    defer execution.discardIfCurrent();

    const result = execution.result();
    std.debug.print("status: {t}, gas: {}\n", .{
        result.status,
        result.gas.used,
    });

    // Commit into the VM's pending branch (otherwise `discardIfCurrent` rolls back).
    execution.accept();
}
