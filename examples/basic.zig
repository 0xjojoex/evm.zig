const std = @import("std");
const evmz = @import("evmz");

const Host = evmz.Host;

pub fn main() void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};

    const bytecode: []const u8 = "\x43\x60\x00\x55\x43\x60\x00\x52\x59\x60\x00\xf3";
    const input: []const u8 = "Hello World!";
    const value: u256 = 1;
    const gas: i64 = 200000;

    var mock_host = evmz.t.MockHost.init(gpa.allocator(), null);
    var host = mock_host.host();

    const msg = Host.Message{
        .depth = 0,
        .sender = evmz.addr(123),
        .gas = gas,
        .kind = Host.CallKind.call,
        .recipient = evmz.addr(456),
        .value = value,
        .input_data = input,
        .is_static = false,
    };

    var intpr = evmz.Evm.init(gpa.allocator(), &host, &msg, bytecode, .cancun);
    defer intpr.deinit();

    std.debug.print("Executing EVM bytecode...\n", .{});
    const result = intpr.execute();
    std.debug.print("Executed EVM bytecode...\n", .{});

    std.debug.print("Result: {any}\n", .{result});
}
