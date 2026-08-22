test {
    _ = @import("main.zig");
    _ = @import("fixture_pool.zig");
    _ = @import("guest_evidence.zig");
    _ = @import("lock.zig");
    _ = @import("runner.zig");
    _ = @import("state.zig");
    _ = @import("stateless.zig");
    _ = @import("stateless_mutation.zig");
    _ = @import("stateless_executor.zig");
    _ = @import("stateless_metrics.zig");
    _ = @import("block_stf.zig");
    _ = @import("cmd/direct.zig");
    _ = @import("cmd/statetest.zig");
    _ = @import("cmd/blocktest.zig");
}
