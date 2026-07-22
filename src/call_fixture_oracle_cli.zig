//! Executable module-root shim; CLI implementation lives under `cli/`.

const oracle = @import("cli/call_fixture_oracle.zig");

pub fn main(init: @import("std").process.Init) !void {
    return oracle.main(init);
}
