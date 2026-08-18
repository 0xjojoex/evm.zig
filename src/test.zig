test {
    // Stage 0: the debug lane is reachable for tests but is
    // deliberately not exported from `evm.zig` or `Vm(spec)` yet.
    _ = @import("./debug.zig");
    // Only debug_cli consumes the disassembler, and that binary is not part of
    // the test build, so nothing else reaches these tests.
    _ = @import("./instruction/disassemble.zig");
    _ = @import("./test/vm_family.zig");
    _ = @import("./test/vm_runtime.zig");
    _ = @import("./test/execution_boundary.zig");
    _ = @import("./test/call_capture.zig");
    _ = @import("./test/call_capture_oracle.zig");
    _ = @import("./test/executor_custom_handler_reentry.zig");
    _ = @import("./test/execution_reentrant_native_contract.zig");
    _ = @import("./test/mpt_package_test.zig");
    _ = @import("./eth/trie_test.zig");
    _ = @import("./test/eip2200.zig");
    // Opcode semantics are tested against bytecode, independently of which
    // dispatcher implements them. No production module imports these.
    _ = @import("./test/opcode/arithmetic.zig");
    _ = @import("./test/opcode/environment.zig");
    _ = @import("./test/opcode/flow.zig");
    _ = @import("./test/opcode/logic.zig");
    _ = @import("./test/opcode/memory.zig");
    _ = @import("./test/opcode/stack.zig");
    _ = @import("./test/opcode/storage.zig");
    _ = @import("./test/gas_table.zig");
    _ = @import("./test/opcode/system.zig");
    _ = @import("./test/prague/eip7702.zig");
    _ = @import("./test/amsterdam/eip2780.zig");
    _ = @import("./test/amsterdam/bal_fixtures.zig");
    _ = @import("./test/amsterdam/bal_differential.zig");
    _ = @import("./test/amsterdam/bal_witness.zig");
    _ = @import("./test/amsterdam/bal_recorder_oracle.zig");
    _ = @import("./test/amsterdam/block_stf_produce.zig");
    _ = @import("./test/amsterdam/eip8037.zig");
    _ = @import("./test/amsterdam/eip8038.zig");
    _ = @import("./test/amsterdam/transaction_preparation.zig");
}
