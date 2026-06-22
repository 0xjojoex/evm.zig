const std = @import("std");
const evmz = @import("../evm.zig");
const t = @import("../t.zig");
const host2c = @import("host2c.zig");
const evmc = @import("common.zig").evmc;

pub const MockHostContext = struct {
    mock_host: t.MockHost,
    host: evmz.Host,
    host_context: host2c.HostContext,

    const Self = @This();

    pub fn create(tx_context: ?evmz.Host.TxContext) !*Self {
        const self = try std.heap.c_allocator.create(Self);
        self.mock_host = t.MockHost.init(std.heap.c_allocator, tx_context);
        self.host = self.mock_host.host();
        self.host_context = host2c.HostContext{
            .ptr = self,
            .host = &self.host,
            .vtable = &.{
                .deinit = deinit,
            },
        };
        return self;
    }

    fn deinit(prt: *anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(prt));
        self.mock_host.deinit();
        std.heap.c_allocator.destroy(self);
    }

    pub fn fromContext(context: ?*evmc.evmc_host_context) ?*Self {
        const host_context = host2c.HostContext.fromContext(context) orelse return null;
        return @ptrCast(@alignCast(host_context.ptr));
    }

    pub fn toContext(self: *Self) ?*evmc.evmc_host_context {
        return self.host_context.toContext();
    }
};
