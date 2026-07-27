test {
    // Stage 0: the debug lane is reachable for tests but is
    // deliberately not exported from `evm.zig` or `Vm(spec)` yet.
    _ = @import("./debug.zig");
    _ = @import("./test/vm_family.zig");
    _ = @import("./test/vm_runtime.zig");
    _ = @import("./test/execution_boundary.zig");
    _ = @import("./test/call_capture.zig");
    _ = @import("./test/call_capture_oracle.zig");
    _ = @import("./test/executor_custom_handler_reentry.zig");
    _ = @import("./test/execution_precompile_runtime.zig");
    _ = @import("./test/block_lifecycle.zig");
    _ = @import("./test/mpt_package_test.zig");
    _ = @import("./test/eip2200.zig");
    _ = @import("./test/amsterdam/eip2780.zig");
    _ = @import("./test/amsterdam/bal_fixtures.zig");
    _ = @import("./test/amsterdam/bal_differential.zig");
    _ = @import("./test/amsterdam/bal_witness.zig");
    _ = @import("./test/amsterdam/block_stf_produce.zig");
    _ = @import("./test/amsterdam/eip8037.zig");
    _ = @import("./test/amsterdam/eip8038.zig");
    _ = @import("./test/amsterdam/transaction_preparation.zig");
}
