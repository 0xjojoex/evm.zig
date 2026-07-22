const std = @import("std");
const evmz = @import("evmz");
const t = evmz.t;
const host2c = @import("host2c.zig");
const common = @import("common.zig");
const evmc = common.evmc;

pub const MockHostContext = struct {
    allocator: std.mem.Allocator,
    mock_host: t.MockHost,
    host: evmz.Host,
    host_context: host2c.HostContext,
    blob_hashes: [common.max_blob_hashes]u256,

    const Self = @This();

    pub fn create(tx_context: ?evmc.evmc_tx_context) !*Self {
        return createWithAllocator(std.heap.c_allocator, tx_context);
    }

    fn createWithAllocator(allocator: std.mem.Allocator, tx_context: ?evmc.evmc_tx_context) !*Self {
        const self = try allocator.create(Self);
        errdefer allocator.destroy(self);
        const native_tx_context = if (tx_context) |ctx|
            try common.fromEvmcTxContext(ctx, &self.blob_hashes)
        else
            null;
        self.allocator = allocator;
        self.mock_host = t.MockHost.init(allocator, native_tx_context);
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
        const allocator = self.allocator;
        self.mock_host.deinit();
        allocator.destroy(self);
    }

    pub fn fromContext(context: ?*evmc.evmc_host_context) ?*Self {
        const host_context = host2c.HostContext.fromContext(context) orelse return null;
        return @ptrCast(@alignCast(host_context.ptr));
    }

    pub fn toContext(self: *Self) ?*evmc.evmc_host_context {
        return self.host_context.toContext();
    }
};

test "mock host creation frees its allocation when tx context conversion fails" {
    var tx_context = std.mem.zeroes(evmc.evmc_tx_context);
    tx_context.blob_hashes_count = 1;
    try std.testing.expectError(
        error.InvalidBlobHashes,
        MockHostContext.createWithAllocator(std.testing.allocator, tx_context),
    );
}
