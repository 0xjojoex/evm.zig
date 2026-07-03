const std = @import("std");
const evmz = @import("../evm.zig");
const t = @import("../t.zig");
const host2c = @import("host2c.zig");
const common = @import("common.zig");
const evmc = common.evmc;

pub const MockHostContext = struct {
    mock_host: t.MockHost,
    host: evmz.Host,
    host_context: host2c.HostContext,
    blob_hashes: [common.max_blob_hashes]u256,

    const Self = @This();

    pub fn create(tx_context: ?evmc.evmc_tx_context) !*Self {
        const self = try std.heap.c_allocator.create(Self);
        const native_tx_context = if (tx_context) |ctx|
            try common.fromEvmcTxContext(ctx, &self.blob_hashes)
        else
            null;
        self.mock_host = t.MockHost.init(std.heap.c_allocator, native_tx_context);
        self.host = self.mock_host.host();
        self.host_context = host2c.HostContext{
            .ptr = self,
            .host = &self.host,
            .blob_hashes = undefined,
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
