//! Standalone MPT package test root.

comptime {
    _ = @import("src/test.zig");
    _ = @import("src/keyed_test.zig");
}
