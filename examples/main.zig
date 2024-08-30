const std = @import("std");
const evmz = @import("evmz");

const Host = evmz.Host;

pub fn main() !void {
    try simple();
}

fn simple() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};

    var buf: [1024]u8 = undefined;
    const bytecode = try std.fmt.hexToBytes(&buf, "6311223344");

    var mock_host = evmz.t.MockHost.init(gpa.allocator(), null);
    var host = mock_host.host();

    const msg = Host.Message{
        .depth = 0,
        .sender = evmz.addr(0),
        .gas = 50000,
        .kind = Host.CallKind.call,
        .recipient = evmz.addr(0),
        .value = 0,
        .input_data = &.{},
        .is_static = false,
    };

    var intpr = evmz.Evm.init(gpa.allocator(), &host, &msg, bytecode);

    defer intpr.deinit();

    const result = intpr.execute();

    std.debug.print("Result: {any}\n", .{result});
}
