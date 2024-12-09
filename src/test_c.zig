const t = @import("t.zig");
const std = @import("std");

const evmz = @import("./evm.zig");

fn create_host() void {
    var mock_host = t.MockHost.init(std.heap.c_allocator, null);
    const host = mock_host.host();
    std.debug.print("host: {any}\n", .{host.accountExists(evmz.addr(0))});
}

test "create_host" {
    create_host();
}
