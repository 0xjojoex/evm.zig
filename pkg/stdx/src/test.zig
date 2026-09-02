//! Standalone `stdx` test root. Tests live beside their implementations.

comptime {
    _ = @import("ExactSlab.zig");
    _ = @import("ScopedArenaAllocator.zig");
    _ = @import("range.zig");
}
