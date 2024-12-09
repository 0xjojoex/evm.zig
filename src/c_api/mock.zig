const evmc = @cImport({
    @cInclude("evmc.h");
});
const std = @import("std");
const t = @import("../t.zig");
const host2c = @import("host2c.zig");

pub const MockHostContext = extern struct {
    mock_host: *t.MockHost,

    const Self = @This();

    fn deinit(prt: *anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(prt));
        // self.mock_host.deinit();
        _ = self;
    }

    pub fn fromContext(context: ?*evmc.evmc_host_context) ?*host2c.HostContext {
        if (context == null) return null;
        return @ptrCast(@alignCast(context));
    }

    pub fn toContext(self: *Self) host2c.HostContext {
        var host = self.mock_host.host();
        return host2c.HostContext{
            .ptr = self,
            .host = &host,
            .vtable = &.{
                .deinit = deinit,
            },
        };
    }
};
