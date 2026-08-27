//! Standalone `stdx` test root. Tests live beside their implementations.

comptime {
    _ = @import("RewindableRegion.zig");
    _ = @import("range.zig");
}
